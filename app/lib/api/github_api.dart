/// GitHub Gist 配置 + 白名单读写层（App 端「管理」功能用）。
///
/// - 配置（token / gist_id）独立存 flutter_secure_storage，与登录态分开
/// - 只负责读/写 whitelist.json 这一个文件（Gist 里其他文件不动）
/// - 错误统一抛 [GithubApiException]（带用户可读 message），由 UI 层提示
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/whitelist_video.dart';

/// GitHub 写操作/配置错误：message 可直接展示给用户。
class GithubApiException implements Exception {
  final String message;
  final int? statusCode; // HTTP 状态码；网络失败为 null

  const GithubApiException(this.message, {this.statusCode});

  @override
  String toString() => 'GithubApiException: $message';
}

/// GitHub Gist API 封装：配置读写 + fetch/save whitelist.json。
class GithubApi {
  /// 配置存储 key（与登录态 SESSDATA 等分开）。
  static const String kTokenKey = 'github_token';
  static const String kGistIdKey = 'gist_id';

  static const String _fileName = 'whitelist.json';

  final Dio _dio;
  final FlutterSecureStorage _storage;

  GithubApi({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.github.com',
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Accept': 'application/vnd.github+json'},
            )),
        _storage = storage ?? const FlutterSecureStorage();

  // --- 配置读写（仅本机 secure storage，不上传任何地方） ---

  Future<String?> getToken() => _storage.read(key: kTokenKey);
  Future<void> setToken(String value) =>
      _storage.write(key: kTokenKey, value: value);
  Future<String?> getGistId() => _storage.read(key: kGistIdKey);
  Future<void> setGistId(String value) =>
      _storage.write(key: kGistIdKey, value: value);

  /// token 与 gist_id 是否都已配置（管理写操作前的门禁）。
  Future<bool> hasConfig() async {
    final token = (await getToken())?.trim() ?? '';
    final gistId = (await getGistId())?.trim() ?? '';
    return token.isNotEmpty && gistId.isNotEmpty;
  }

  // --- Gist 读写 ---

  /// 从 Gist 拉取并解析 whitelist.json → [WhitelistData]。
  ///
  /// - 未配置 token/gist_id → 抛 [GithubApiException]
  /// - Gist 存在但没有 whitelist.json 文件 → 返回 null（视为空）
  /// - 401/404/网络失败 → 抛 [GithubApiException]（带分类提示）
  Future<WhitelistData?> fetchFromGist() async {
    final (token, gistId) = await _configOrThrow();
    final resp = await _guard(
      () => _dio.get<Map<String, dynamic>>(
        '/gists/$gistId',
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
        }),
      ),
    );
    final files = resp.data?['files'] as Map? ?? const {};
    final file = files[_fileName] as Map? ?? const {};
    final content = file['content'] as String?;
    if (content == null || content.trim().isEmpty) return null;
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const GithubApiException('Gist 中 whitelist.json 内容不是合法 JSON');
    }
    return WhitelistData.fromJson(decoded);
  }

  /// 把 [wl] 规范化到 v3 后 PATCH 写回 Gist；成功返回 true。
  Future<bool> saveToGist(WhitelistData wl) async {
    final (token, gistId) = await _configOrThrow();
    final normalized = wl.normalizedForSave();
    final payload = {
      'files': {
        _fileName: {
          // 2 空格缩进，与 PC 端 whitelist.py 落盘风格一致
          'content': const JsonEncoder.withIndent('  ').convert(
            normalized.toJson(),
          ),
        },
      },
    };
    final resp = await _guard(
      () => _dio.patch<Map<String, dynamic>>(
        '/gists/$gistId',
        data: payload,
        options: Options(headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
        }),
      ),
    );
    final code = resp.statusCode;
    return code != null && code >= 200 && code < 300;
  }

  // --- 内部 ---

  /// 读取配置；缺任一 → 抛「先配置」异常。
  Future<(String, String)> _configOrThrow() async {
    final token = (await getToken())?.trim() ?? '';
    final gistId = (await getGistId())?.trim() ?? '';
    if (token.isEmpty || gistId.isEmpty) {
      throw const GithubApiException(
          '尚未配置 GitHub token 与 Gist ID，请先到右上角管理入口配置');
    }
    return (token, gistId);
  }

  /// 把 Dio 异常转成用户可读的 [GithubApiException]。
  Future<Response<T>> _guard<T>(Future<Response<T>> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
  }

  GithubApiException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) {
      return const GithubApiException(
          'GitHub token 无效或已过期，请重新配置', statusCode: 401);
    }
    if (status == 403) {
      return const GithubApiException(
          'GitHub 拒绝访问（403）：token 权限不足或请求被限流', statusCode: 403);
    }
    if (status == 404) {
      return const GithubApiException(
          'Gist 不存在：gist_id 可能填错，请检查管理页配置', statusCode: 404);
    }
    if (status != null) {
      return GithubApiException('GitHub 返回错误（HTTP $status）',
          statusCode: status);
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const GithubApiException('网络请求超时，请检查网络后重试');
      case DioExceptionType.connectionError:
        return const GithubApiException('网络连接失败，请检查网络后重试');
      default:
        return GithubApiException('网络错误：${e.message ?? e.type}');
    }
  }
}
