// GistSource 单元测试：验证「优先实时 API、未配置/失败回退 raw + cache-buster」。
// - 不访问真实网络：raw 与 API 的 dio 都注入 fake adapter
// - secure storage 用 mock MethodChannel（内存 map），不回显任何 token 值
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存版 secure storage（对应原生 MethodChannel）。
final Map<String, String> _store = {};

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return _store[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        _store[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        _store.remove(args['key'] as String?);
        return true;
      case 'readAll':
        return Map<String, String>.from(_store);
      case 'deleteAll':
        _store.clear();
        return true;
      default:
        return null;
    }
  });
}

/// 固定响应文本的 fake adapter：记录每次请求的 options。
class _FakeAdapter implements HttpClientAdapter {
  final int statusCode;
  final String body;
  final List<RequestOptions> requests = [];

  _FakeAdapter({required this.statusCode, required this.body});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 抛连接错误的 adapter（模拟断网）。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));
  dio.httpClientAdapter = adapter;
  return dio;
}

/// 合法的 v3 白名单 JSON（raw 与 API 通用）。
const _v3Content =
    '{"version":3,"updated_at":"2026-08-20T00:00:00Z",'
    '"collections":[{"name":"动画","created_at":"2026-08-01T00:00:00Z"}],'
    '"videos":[{"bvid":"BV1","cid":1,"title":"测试视频","cover":"",'
    '"duration":60,"up_name":"up","added_at":"2026-01-01T00:00:00Z",'
    '"collection":"动画"}]}';

/// Gist raw URL（AppConfig.gistUrl 同款形态）。
const _rawUrl =
    'https://gist.githubusercontent.com/Tukist/abc123/raw/whitelist.json';

/// 组装 GistSource：raw 请求走 [rawAdapter]，实时 API 请求走 [apiAdapter]。
GistSource _source({
  required _FakeAdapter rawAdapter,
  required _FakeAdapter apiAdapter,
}) {
  return GistSource(
    url: _rawUrl,
    dio: _dio(rawAdapter),
    githubApi: GithubApi(dio: _dio(apiAdapter)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  test('已配置 token+gist_id → 优先走实时 API，raw 不被调用', () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    // raw 若被调用则返回 500，保证"绝不回退"也能被抓出
    final rawAdapter = _FakeAdapter(statusCode: 500, body: 'should not hit');
    final apiAdapter = _FakeAdapter(
      statusCode: 200,
      body: jsonEncode({
        'id': 'gist1',
        'files': {'whitelist.json': {'content': _v3Content}},
      }),
    );

    final data = await _source(rawAdapter: rawAdapter, apiAdapter: apiAdapter)
        .fetch();

    expect(data.collections.single.name, '动画');
    expect(data.videos.single.collection, '动画');
    final req = apiAdapter.requests.single;
    expect(req.path, '/gists/gist1');
    expect(req.headers['Authorization'], 'Bearer ghp_fake');
    expect(rawAdapter.requests, isEmpty, reason: 'API 成功时不应回退 raw');
  });

  test('未配置 token → 直接走 raw + cache-buster，不碰 API', () async {
    final rawAdapter = _FakeAdapter(statusCode: 200, body: _v3Content);
    final apiAdapter = _FakeAdapter(statusCode: 401, body: '{}');

    final data =
        await _source(rawAdapter: rawAdapter, apiAdapter: apiAdapter).fetch();

    expect(data.collections.single.name, '动画');
    final req = rawAdapter.requests.single;
    expect(req.uri.path, endsWith('/raw/whitelist.json'));
    expect(req.uri.queryParameters.containsKey('v'), isTrue,
        reason: 'raw 路径必须带 cache-buster');
    expect(apiAdapter.requests, isEmpty, reason: '未配置时不应尝试 API');
  });

  test('已配置但 API 401 → 回退 raw + cache-buster 成功', () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    final rawAdapter = _FakeAdapter(statusCode: 200, body: _v3Content);
    final apiAdapter = _FakeAdapter(
        statusCode: 401, body: '{"message":"Bad credentials"}');

    final data =
        await _source(rawAdapter: rawAdapter, apiAdapter: apiAdapter).fetch();

    expect(data.collections.single.name, '动画');
    expect(apiAdapter.requests.single.path, '/gists/gist1');
    expect(rawAdapter.requests.single.uri.queryParameters.containsKey('v'),
        isTrue);
  });

  test('已配置但 API 网络失败 → 回退 raw + cache-buster 成功', () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    final rawAdapter = _FakeAdapter(statusCode: 200, body: _v3Content);
    final apiDio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
    apiDio.httpClientAdapter = _ThrowingAdapter();

    final source = GistSource(
      url: _rawUrl,
      dio: _dio(rawAdapter),
      githubApi: GithubApi(dio: apiDio),
    );
    final data = await source.fetch();

    expect(data.collections.single.name, '动画');
    expect(rawAdapter.requests.single.uri.queryParameters.containsKey('v'),
        isTrue);
  });

  test('已配置但 Gist 无 whitelist.json（API 返回 null）→ 落到 raw，raw 404 抛错',
      () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    final rawAdapter =
        _FakeAdapter(statusCode: 404, body: '404: Not Found');
    final apiAdapter = _FakeAdapter(
      statusCode: 200,
      body: jsonEncode({
        'id': 'gist1',
        'files': {'other.txt': {'content': 'x'}},
      }),
    );

    // 用 expectLater + await：确保 fetch 的 Future 真正完成后才断言，
    // 否则异步匹配未执行，rawAdapter.requests 可能还是空的。
    await expectLater(
      _source(rawAdapter: rawAdapter, apiAdapter: apiAdapter).fetch(),
      throwsA(anything),
    );
    expect(rawAdapter.requests.single.uri.queryParameters.containsKey('v'),
        isTrue);
  });

  test('API 与 raw 都失败 → 抛错，由上层同步回退链接管', () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    final rawAdapter = _FakeAdapter(statusCode: 404, body: '404: Not Found');
    final apiAdapter = _FakeAdapter(statusCode: 401, body: '{}');

    await expectLater(
      _source(rawAdapter: rawAdapter, apiAdapter: apiAdapter).fetch(),
      throwsA(anything),
    );
  });
}
