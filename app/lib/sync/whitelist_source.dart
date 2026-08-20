import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/github_api.dart';
import '../config.dart';
import '../models/whitelist_video.dart';

/// 白名单数据源抽象。
///
/// 各实现负责从自己的来源拉取并解析 [WhitelistData]；失败抛异常，
/// 由上层 [WhitelistSyncService] 按序回退。
abstract class WhitelistSource {
  String get name;
  Future<WhitelistData> fetch();
}

/// 数据源：GitHub Gist（优先实时 API，回退公开 raw URL）。
///
/// - 管理面板已配置 token + gist_id → 走 `api.github.com` 实时 API：
///   PATCH 写操作后立即可见，没有 CDN 缓存问题
/// - 未配置（纯只读用户）/ 实时 API 失败 → 回退公开 raw URL，并追加
///   cache-buster（`?v=<毫秒时间戳>`）尽力绕开 `gist.githubusercontent.com`
///   的边缘缓存（该缓存导致"新建合集后下拉刷新合集消失"）
class GistSource extends WhitelistSource {
  final String url;
  final Dio dio;
  final GithubApi? _githubApi;

  GistSource({required this.url, Dio? dio, GithubApi? githubApi})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Accept': 'application/json'},
            )),
        _githubApi = githubApi;

  @override
  String get name => 'gist';

  @override
  Future<WhitelistData> fetch() async {
    if (url.isEmpty) {
      throw const FormatException('gistUrl 未配置');
    }
    // 优先实时 API：管理面板配置过 token + gist_id 时走 api.github.com。
    // Gist 公开 raw URL 有 GitHub CDN 边缘缓存，管理操作（PATCH）成功后
    // 1~5 分钟里 raw 仍返回旧数据 → 下拉刷新会"丢"刚新建的合集；
    // API 路径是实时权威数据，与写操作保持一致。
    final api = _githubApi ?? GithubApi();
    if (await _apiConfigured(api)) {
      try {
        final data = await api.fetchFromGist();
        if (data != null) return data;
        // Gist 存在但无 whitelist.json（异常态）→ 交给 raw 路径自然报错
      } on GithubApiException {
        // 实时 API 失败（401/404/403/网络）→ 回退公开 raw + cache-buster
      }
    }
    // 回退/只读路径：公开 raw URL + cache-buster（尽力绕开 CDN 边缘缓存）。
    // ⚠ Gist raw 端点返回的 Content-Type 是 text/plain（实测），dio 默认只在
    // JSON MIME 时才自动 jsonDecode，否则把原始文本当 String 返回，导致
    // `get<Map<String, dynamic>>` 泛型转换抛
    // `type 'String' is not a subtype of type 'Map<String,dynamic>?'`。
    // 因此这里显式拿原始文本，自己 jsonDecode + 类型检查，和本地文件源一致。
    final resp = await dio.get<String>(
      _withCacheBuster(url),
      options: Options(responseType: ResponseType.plain),
    );
    final raw = resp.data;
    if (raw == null || raw.trim().isEmpty) {
      throw const FormatException('gist 返回内容为空');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('gist 返回内容不是合法 JSON 对象');
    }
    return WhitelistData.fromJson(decoded);
  }

  /// secure storage 是否可用且已配置；不可用（如测试环境无原生插件）→ 视为
  /// 未配置，直接走 raw 路径，不阻塞同步。
  Future<bool> _apiConfigured(GithubApi api) async {
    try {
      return await api.hasConfig();
    } catch (_) {
      return false;
    }
  }

  /// raw URL 追加 cache-buster：`?v=<毫秒时间戳>`（每次刷新都不同，尽力
  /// 绕开 CDN 边缘缓存）。URL 已有 query 时改用 `&` 拼接。
  static String _withCacheBuster(String rawUrl) {
    final sep = rawUrl.contains('?') ? '&' : '?';
    return '$rawUrl${sep}v=${DateTime.now().millisecondsSinceEpoch}';
  }
}

/// 数据源：PC 局域网 HTTP 服务（M1 `python whitelist.py serve` 产出）。
class LanSource extends WhitelistSource {
  final String url;
  final Dio dio;

  LanSource({required this.url, Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'Accept': 'application/json'},
            ));

  @override
  String get name => 'lan';

  @override
  Future<WhitelistData> fetch() async {
    if (url.isEmpty) {
      throw const FormatException('lanUrl 未配置');
    }
    // 同 GistSource：LAN serve 的 Content-Type 不一定是 JSON MIME，
    // 统一显式拿原始文本再手动解析，避免 dio 泛型转换踩类型坑。
    final resp = await dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final raw = resp.data;
    if (raw == null || raw.trim().isEmpty) {
      throw const FormatException('局域网源返回内容为空');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('局域网源返回内容不是合法 JSON 对象');
    }
    return WhitelistData.fromJson(decoded);
  }
}

/// 数据源：本地手动导入文件（应用文档目录下的 `whitelist_local.json`）。
class LocalFileSource extends WhitelistSource {
  /// 非 final：SyncService 在首次 sync 时惰性绑定路径。
  File file;

  LocalFileSource({required this.file});

  @override
  String get name => 'local';

  @override
  Future<WhitelistData> fetch() async {
    if (!await file.exists()) {
      throw const FileSystemException('本地导入文件不存在');
    }
    final content = await file.readAsString();
    final json = jsonDecode(content);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('本地导入文件不是合法 JSON 对象');
    }
    return WhitelistData.fromJson(json);
  }
}

/// 数据源：本地自动缓存（上次成功同步的副本，含 fetched_at）。
class CacheSource extends WhitelistSource {
  /// 非 final：SyncService 在首次 sync 时惰性绑定路径。
  File file;

  CacheSource({required this.file});

  @override
  String get name => 'cache';

  @override
  Future<WhitelistData> fetch() async {
    if (!await file.exists()) {
      throw const FileSystemException('本地缓存不存在');
    }
    final content = await file.readAsString();
    final json = jsonDecode(content);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('本地缓存文件不是合法 JSON 对象');
    }
    return WhitelistData.fromJson(json['data'] as Map<String, dynamic>? ?? {});
  }
}

/// 一次同步的结果。
class SyncResult {
  final WhitelistData data;

  /// 实际生效的数据源名称（gist / lan / local / cache）。
  final String sourceName;

  /// 缓存数据获取时间（缓存源时来自文件里的 fetched_at；网络源为本次同步时间）。
  final DateTime fetchedAt;

  /// 是否发生了网络同步（gist/lan 成功）。
  final bool fromNetwork;

  const SyncResult({
    required this.data,
    required this.sourceName,
    required this.fetchedAt,
    required this.fromNetwork,
  });
}

/// 白名单同步服务：Gist → Lan → 本地导入文件 → 本地缓存，按序回退。
///
/// - 网络源（Gist/Lan）成功后把结果写入本地缓存文件（记录 fetched_at），
///   下次启动即使没网也能展示最近一次数据。
/// - 任何单个源失败都不会崩溃，自动尝试下一个源。
class WhitelistSyncService {
  final GistSource _gistSource;
  final LanSource _lanSource;
  final LocalFileSource _localSource;
  final CacheSource _cacheSource;

  WhitelistSyncService({Dio? dio, GithubApi? githubApi})
      : _gistSource =
            GistSource(url: AppConfig.gistUrl, dio: dio, githubApi: githubApi),
        _lanSource = LanSource(url: AppConfig.lanUrl, dio: dio),
        _localSource = LocalFileSource(file: File('')),
        _cacheSource = CacheSource(file: File('')) {
    // 文件路径依赖应用文档目录，构造时无法解析，首用前惰性绑定
  }

  /// 按序回退同步：Gist → Lan → 本地导入文件 → 本地缓存。
  ///
  /// 网络源成功后写入本地缓存；全部失败抛出最后一次异常。
  Future<SyncResult> sync() async {
    final dir = await _bindFiles();
    final now = DateTime.now();

    // 1) Gist
    if (AppConfig.gistUrl.isNotEmpty) {
      try {
        final data = await _gistSource.fetch();
        return await _cacheNetworkResult(
            data, 'gist', now, dir.cacheFile, now);
      } catch (e) {
        _log('gist 源失败: $e');
      }
    }
    // 2) LAN
    if (AppConfig.lanUrl.isNotEmpty) {
      try {
        final data = await _lanSource.fetch();
        return await _cacheNetworkResult(
            data, 'lan', now, dir.cacheFile, now);
      } catch (e) {
        _log('lan 源失败: $e');
      }
    }
    // 3) 本地导入文件
    try {
      final data = await _localSource.fetch();
      return SyncResult(
        data: data,
        sourceName: 'local',
        fetchedAt: now,
        fromNetwork: false,
      );
    } catch (e) {
      _log('local 源失败: $e');
    }
    // 4) 本地缓存（含 fetched_at）
    try {
      final meta = await _readCacheMeta(dir.cacheFile);
      final data = await _cacheSource.fetch();
      return SyncResult(
        data: data,
        sourceName: 'cache',
        fetchedAt: meta.fetchedAt ?? now,
        fromNetwork: false,
      );
    } catch (e) {
      _log('cache 源失败: $e');
    }
    throw StateError('所有白名单源都不可用（gist/lan/local/cache 全失败）');
  }

  /// 读取缓存文件并附带 fetched_at 元信息。
  Future<({DateTime? fetchedAt})> _readCacheMeta(File file) async {
    if (!await file.exists()) return (fetchedAt: null);
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) return (fetchedAt: null);
    final raw = json['fetched_at'] as String?;
    return (fetchedAt: raw == null ? null : DateTime.tryParse(raw));
  }

  /// 网络源成功后：写入缓存文件 + 记录 fetched_at 到 shared_preferences。
  Future<SyncResult> _cacheNetworkResult(
    WhitelistData data,
    String sourceName,
    DateTime fetchedAt,
    File cacheFile,
    DateTime now,
  ) async {
    await cacheFile.writeAsString(
      jsonEncode({
        'fetched_at': now.toIso8601String(),
        'data': data.toJson(),
      }),
      flush: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('whitelist_fetched_at', now.toIso8601String());
    return SyncResult(
      data: data,
      sourceName: sourceName,
      fetchedAt: now,
      fromNetwork: true,
    );
  }

  /// 管理写操作成功后，把最新数据写入本地缓存（与网络同步落盘同构）。
  ///
  /// 与 [_cacheNetworkResult] 的区别：不返回 SyncResult、不标记网络来源，
  /// 仅保证下次启动/刷新能用上最新数据。
  Future<void> saveToCache(WhitelistData data) async {
    final dir = await _bindFiles();
    final now = DateTime.now();
    await dir.cacheFile.writeAsString(
      jsonEncode({
        'fetched_at': now.toIso8601String(),
        'data': data.toJson(),
      }),
      flush: true,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('whitelist_fetched_at', now.toIso8601String());
  }

  /// 惰性绑定应用文档目录下的缓存文件与导入文件路径。
  Future<({File cacheFile, File localFile})> _bindFiles() async {
    final dir = await getApplicationSupportDirectory();
    final cacheFile = File('${dir.path}/${AppConfig.cacheFileName}');
    final localFile = File('${dir.path}/${AppConfig.localImportFileName}');
    _localSource.file = localFile;
    _cacheSource.file = cacheFile;
    return (cacheFile: cacheFile, localFile: localFile);
  }

  void _log(String message) {
    // 调试日志；后续可接统一的日志系统
    // ignore: avoid_print
    print('[sync] $message');
  }
}
