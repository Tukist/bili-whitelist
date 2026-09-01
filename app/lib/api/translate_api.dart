/// OpenAI 兼容翻译服务：字幕副字幕「翻译（中文）」用的配置 + 批量翻译 + 本地缓存。
///
/// - 配置（base_url / api_key / model）存 flutter_secure_storage，key 前缀
///   `translate_`，与登录态、GitHub 配置分开；key 仅存本机
/// - 翻译调 `{baseUrl}/v1/chat/completions`（POST + Authorization Bearer），
///   每批最多 [batchSize] 条字幕一次请求；回复按行逐条对应
/// - 译文按 (bvid, cid, 主字幕 lan) 落到应用支持目录 JSON 文件，
///   同一视频同一轨道只翻译一次（切集/重进直接命中缓存）
/// - 错误统一抛 [TranslateApiException]（带用户可读 message），由 UI 层提示
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../services/secure_store.dart';

/// 翻译服务错误：message 可直接展示给用户。
class TranslateApiException implements Exception {
  final String message;
  final int? statusCode; // HTTP 状态码；网络失败为 null

  const TranslateApiException(this.message, {this.statusCode});

  @override
  String toString() => 'TranslateApiException: $message';
}

/// 翻译服务配置（OpenAI 兼容）。
class TranslateConfig {
  /// 服务地址（如 `https://api.deepseek.com`）。
  final String baseUrl;

  /// API key（仅存本机 secure storage）。
  final String apiKey;

  /// 模型名（如 `deepseek-chat`）。
  final String model;

  const TranslateConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });
}

/// 翻译服务封装：配置读写 + 批量翻译 + 译文文件缓存。
class TranslateApi {
  /// 配置存储 key（前缀 translate_，与登录态 / GitHub 配置分开）。
  static const String kBaseUrlKey = 'translate_base_url';
  static const String kApiKeyKey = 'translate_api_key';
  static const String kModelKey = 'translate_model';

  /// 单次请求的字幕条数上限（过长分批，避免超出模型上下文）。
  static const int batchSize = 20;

  /// 系统提示：逐条翻译成简体中文、逐条对应、只输出结果。
  static const String systemPrompt =
      '把用户给出的每条字幕逐条翻译成简体中文，逐条对应输出，'
      '只输出翻译结果，每行一条，不要序号和解释';

  final Dio _dio;
  final FlutterSecureStorage _storage;
  final Directory? _cacheDirOverride;

  TranslateApi({
    Dio? dio,
    FlutterSecureStorage? storage,
    Directory? cacheDirOverride,
  })  : _dio = dio ??
            Dio(BaseOptions(
              // 翻译请求超时 30s（连接超时 10s + 接收超时 30s）
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            )),
        // vivo 等国产 ROM 兼容：显式 AndroidOptions（见 services/secure_store.dart）
        _storage = storage ?? createSecureStorage(),
        _cacheDirOverride = cacheDirOverride;

  // -------------------------------------------------------------------------
  // 配置读写（仅本机 secure storage）
  // -------------------------------------------------------------------------

  /// 保存配置：任一项留空即视为未启用（保存后 [hasConfig] 为 false）。
  Future<void> saveConfig({
    String baseUrl = '',
    String apiKey = '',
    String model = '',
  }) async {
    await _storage.write(key: kBaseUrlKey, value: baseUrl.trim());
    await _storage.write(key: kApiKeyKey, value: apiKey.trim());
    await _storage.write(key: kModelKey, value: model.trim());
  }

  /// 读取配置；任一字段为空 → null（未配置/未启用）。
  Future<TranslateConfig?> loadConfig() async {
    final baseUrl = (await _storage.read(key: kBaseUrlKey))?.trim() ?? '';
    final apiKey = (await _storage.read(key: kApiKeyKey))?.trim() ?? '';
    final model = (await _storage.read(key: kModelKey))?.trim() ?? '';
    if (baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) return null;
    return TranslateConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);
  }

  /// 是否已配置翻译服务（字幕面板「翻译（中文）」的门禁）。
  Future<bool> hasConfig() async => (await loadConfig()) != null;

  // -------------------------------------------------------------------------
  // 批量翻译
  // -------------------------------------------------------------------------

  /// 批量翻译 [texts]，逐条对应返回译文（长度与 [texts] 一致）。
  ///
  /// - 每次最多 [batchSize] 条，超出自动分批串行请求
  /// - [progress]：每完成一批把「已翻译条数」写入 notifier（总数 = texts.length，
  ///   调用方已知），供 UI 显示「翻译中 x/y」
  /// - 回复解析容错：行数不足补原文、多出的行截断、带序号的行剥离序号
  /// - 未配置 / 401 / 超时 / 断网 → 抛 [TranslateApiException]（中文 message）
  Future<List<String>> translateBatch(
    List<String> texts, {
    ValueNotifier<int>? progress,
  }) async {
    final config = await loadConfig();
    if (config == null) {
      throw const TranslateApiException('未配置翻译服务，请到管理面板配置');
    }
    if (texts.isEmpty) return const [];

    // 去掉 base_url 尾部多余的 /，拼 /v1/chat/completions
    final baseUrl = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final url = '$baseUrl/v1/chat/completions';
    final results = <String>[];

    for (var start = 0; start < texts.length; start += batchSize) {
      final end = start + batchSize > texts.length ? texts.length : start + batchSize;
      final batch = texts.sublist(start, end);
      final content = [
        for (var i = 0; i < batch.length; i++) '${i + 1}. ${batch[i]}',
      ].join('\n');
      debugPrint('[translate] 批次 ${start + 1}~$end/${texts.length} '
          'url=$url model=${config.model}');
      try {
        final resp = await _dio.post<Map<String, dynamic>>(
          url,
          data: {
            'model': config.model,
            'stream': false,
            'messages': [
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': content},
            ],
          },
          options: Options(
            headers: {'Authorization': 'Bearer ${config.apiKey}'},
          ),
        );
        results.addAll(_parseReply(resp.data, batch));
      } on DioException catch (e) {
        throw _mapDioError(e);
      }
      progress?.value = end;
    }
    return results;
  }

  /// 解析 chat.completions 回复 → 与 [batch] 逐条对应的译文列表。
  ///
  /// 容错：choices 缺失/内容非字符串/为空 → 抛异常；
  /// 行数不足补原文、多出的行截断、行首序号（`1.`/`1、` 等）剥离。
  List<String> _parseReply(Map<String, dynamic>? data, List<String> batch) {
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const TranslateApiException(
          '翻译服务响应格式异常，请检查服务地址与模型名');
    }
    final message = choices.first['message'];
    final content = (message is Map<String, dynamic>) ? message['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw const TranslateApiException('翻译服务返回内容为空');
    }
    final lines = content
        .split('\n')
        .map((l) => l
            .trim()
            .replaceFirst(RegExp(r'^\d+[.、:)\s]+'), '')
            .trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // 逐条对应：行数不足补原文；多出的行截断
    return [
      for (var i = 0; i < batch.length; i++)
        i < lines.length ? lines[i] : batch[i],
    ];
  }

  /// 把 Dio 异常转成用户可读的 [TranslateApiException]。
  TranslateApiException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) {
      return const TranslateApiException(
          '翻译 API key 无效或已过期，请重新配置', statusCode: 401);
    }
    if (status != null) {
      return TranslateApiException('翻译服务返回错误（HTTP $status）',
          statusCode: status);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const TranslateApiException('翻译请求超时，请检查网络后重试');
      case DioExceptionType.connectionError:
        return const TranslateApiException('网络连接失败，请检查网络后重试');
      default:
        return TranslateApiException('翻译请求失败：${e.message ?? e.type}');
    }
  }

  // -------------------------------------------------------------------------
  // 本地缓存（同一视频同一轨道只翻译一次）
  // -------------------------------------------------------------------------

  /// 缓存目录（path_provider 应用支持目录；测试可注入覆盖）。
  Future<Directory> _cacheDir() async {
    final dir = _cacheDirOverride;
    if (dir != null) return dir;
    return getApplicationSupportDirectory();
  }

  /// 缓存文件：`<cache_dir>/subtitle_translation_<bvid>_<cid>_<lan>.json`。
  Future<File> _cacheFile(String bvid, int cid, String lan) async {
    final dir = await _cacheDir();
    final file = File('${dir.path}/subtitle_translation_${bvid}_${cid}_$lan.json');
    await file.parent.create(recursive: true);
    return file;
  }

  /// 读取缓存译文（按 cue 顺序的数组）；无缓存 / 数据损坏 → null。
  Future<List<String>?> getCachedTranslation(
      String bvid, int cid, String lan) async {
    try {
      final f = await _cacheFile(bvid, cid, lan);
      if (!await f.exists()) return null;
      final root = jsonDecode(await f.readAsString());
      if (root is! Map<String, dynamic>) return null;
      final items = root['items'];
      if (items is! List) return null;
      return items.map((e) => e is String ? e : '').toList();
    } catch (_) {
      // 损坏视为无缓存（重新翻译会覆盖）
      return null;
    }
  }

  /// 保存译文缓存（写失败不影响翻译结果展示，静默忽略）。
  Future<void> saveTranslation(
      String bvid, int cid, String lan, List<String> list) async {
    try {
      final f = await _cacheFile(bvid, cid, lan);
      await f.writeAsString(jsonEncode({'items': list}));
    } catch (e) {
      debugPrint('[translate] 缓存写失败 $bvid/$cid/$lan: $e');
    }
  }
}
