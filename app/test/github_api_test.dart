// GithubApi（Gist 读写层）单元测试：
// - 配置读写走 flutter_secure_storage MethodChannel（mock 成内存 map）
// - HTTP 用注入的 fake HttpClientAdapter，验证请求头/Body 与错误分类
// - 不访问真实网络、不回显任何 token 值
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';

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
        final value = args['value'] as String? ?? '';
        _store[key] = value;
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

/// 固定响应的 fake adapter：记录每次请求的 options，返回预置 body。
class _FakeAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, dynamic> Function() bodyBuilder;
  final List<RequestOptions> requests = [];

  _FakeAdapter({required this.statusCode, required this.bodyBuilder});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(bodyBuilder()),
      statusCode,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

GithubApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  return GithubApi(dio: dio);
}

const _v3GistContent =
    '{"version":3,"updated_at":"2026-08-20T00:00:00Z",'
    '"collections":[{"name":"动画","created_at":"2026-08-01T00:00:00Z"}],'
    '"videos":[{"bvid":"BV1","cid":1,"title":"测试视频","cover":"",'
    '"duration":60,"up_name":"up","added_at":"2026-01-01T00:00:00Z",'
    '"collection":"动画"}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  test('未配置 token/gist_id 时抛「先配置」异常', () async {
    final api = _api(_FakeAdapter(statusCode: 200, bodyBuilder: () => <String, dynamic>{}));
    expect(
      () => api.fetchFromGist(),
      throwsA(isA<GithubApiException>()
          .having((e) => e.message, 'message', contains('尚未配置'))),
    );
    final wl = WhitelistData.empty();
    expect(
      () => api.saveToGist(wl),
      throwsA(isA<GithubApiException>()),
    );
  });

  test('fetchFromGist 成功解析 v3 数据（Bearer 头 + Accept）', () async {
    final adapter = _FakeAdapter(
      statusCode: 200,
      bodyBuilder: () => {
        'id': 'gist1',
        'files': {
          'whitelist.json': {'content': _v3GistContent},
        },
      },
    );
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';

    final api = _api(adapter);
    final data = await api.fetchFromGist();

    expect(data, isNotNull);
    expect(data!.collections.single.name, '动画');
    expect(data.videos.single.collection, '动画');
    final req = adapter.requests.single;
    expect(req.path, '/gists/gist1');
    expect(req.headers['Authorization'], 'Bearer ghp_fake');
    expect(req.headers['Accept'], contains('github'));
  });

  test('gist 无 whitelist.json 文件时返回 null（不抛错）', () async {
    final adapter = _FakeAdapter(
      statusCode: 200,
      bodyBuilder: () => {
        'id': 'gist1',
        'files': {'other.txt': {'content': 'x'}},
      },
    );
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    expect(await _api(adapter).fetchFromGist(), isNull);
  });

  test('401 → token 无效分类；404 → gist 不存在分类', () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';

    final api401 = _api(_FakeAdapter(
        statusCode: 401, bodyBuilder: () => {'message': 'Bad credentials'}));
    expect(
      () => api401.fetchFromGist(),
      throwsA(isA<GithubApiException>()
          .having((e) => e.statusCode, 'statusCode', 401)
          .having((e) => e.message, 'message', contains('token'))),
    );

    final api404 = _api(_FakeAdapter(
        statusCode: 404, bodyBuilder: () => {'message': 'Not Found'}));
    expect(
      () => api404.fetchFromGist(),
      throwsA(isA<GithubApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', contains('Gist 不存在'))),
    );
  });

  test('网络连接失败 → 网络错误分类', () async {
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';
    final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
    dio.httpClientAdapter = _ThrowingAdapter();
    final api = GithubApi(dio: dio);
    expect(
      () => api.fetchFromGist(),
      throwsA(isA<GithubApiException>()
          .having((e) => e.statusCode, 'statusCode', isNull)
          .having((e) => e.message, 'message', contains('网络'))),
    );
  });

  test('saveToGist：PATCH + Bearer 头，content 为 2 空格缩进的 v3 JSON，返回 true',
      () async {
    final adapter = _FakeAdapter(
      statusCode: 200,
      bodyBuilder: () => {
        'id': 'gist1',
        'files': {
          'whitelist.json': {'content': _v3GistContent},
        },
      },
    );
    _store[GithubApi.kTokenKey] = 'ghp_fake';
    _store[GithubApi.kGistIdKey] = 'gist1';

    // 用 v2 数据保存 → 应被规范化成 v3 再写
    final v2 = WhitelistData.fromJson({
      'version': 2,
      'videos': [
        {
          'bvid': 'BV1',
          'cid': 1,
          'title': '测试视频',
          'cover': '',
          'duration': 60,
          'up_name': 'up',
          'added_at': '2026-01-01T00:00:00Z',
        },
      ],
    });

    final ok = await _api(adapter).saveToGist(v2);
    expect(ok, isTrue);

    final req = adapter.requests.single;
    expect(req.method, 'PATCH');
    expect(req.path, '/gists/gist1');
    expect(req.headers['Authorization'], 'Bearer ghp_fake');

    final payload = req.data as Map;
    final content =
        (payload['files'] as Map)['whitelist.json'] as Map;
    final raw = content['content'] as String;
    final parsed = jsonDecode(raw) as Map<String, dynamic>;
    expect(parsed['version'], 3); // 保存统一 v3
    expect(parsed.containsKey('collections'), isTrue);
    expect((parsed['videos'] as List).first as Map, contains('collection'));
    // 2 空格缩进（dart jsonEncode indent:2 输出逐层 2 空格）
    expect(raw.contains('\n  "version": 3'), isTrue);
  });
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
