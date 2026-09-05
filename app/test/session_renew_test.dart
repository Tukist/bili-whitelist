// BiliApi.refreshSession（x/passport-login/web/cookie/refresh 自动续期）单测
// （mock dio adapter，不访问真实网络）：
// - 缺 csrf/refresh_token → missingCredentials（不发网络请求）
// - 续期成功：Set-Cookie 下发新 SESSDATA/bili_jct（响应体兜底 data.sessdata/
//   data.bili_jct 也覆盖）→ 新会话入库（sessdata/jct/refresh_token 全更新），
//   返回 renewed
// - refresh_token 失效（业务码 -101）→ tokenInvalid，storage 不动
// - code=0 但新旧会话都拿不到 → tokenInvalid（异常响应）
// - 网络异常 → networkError，storage 不动（下次启动再试，不打扰）
//
// 启动引导语义（会话失效 → 自动重登 / 保留现会话）在 playlist_page
// _handleSessionOnStart（见 auto_login_test.dart widget 用例）消费此分类。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

/// 内存版 secure storage（同 auto_login_test / pgc_playurl_api_test）。
Map<String, String> _store = {};

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
      default:
        return null;
    }
  });
}

/// 可控响应的 adapter：返回预置 body + 额外响应头（set-cookie），
/// 或按需抛网络异常（模拟断网）。
class _RefreshAdapter implements HttpClientAdapter {
  final Map<String, Object> body;
  final Map<String, List<String>> responseHeaders;
  final List<RequestOptions> requests = [];

  _RefreshAdapter({
    this.body = const {'code': 0},
    this.responseHeaders = const {},
  });

  /// 抛 DioException（网络失败）的实例。
  _RefreshAdapter.networkError()
      : body = const {},
        responseHeaders = const {};

  bool get throwNetwork => body.isEmpty && responseHeaders.isEmpty;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (throwNetwork) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
        ...responseHeaders,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store = {};
    _mockSecureStorage();
  });

  const refreshPath = '/x/passport-login/web/cookie/refresh';

  group('refreshSession 续期结果分类', () {
    test('缺 csrf/refresh_token → missingCredentials（不发网络请求）', () async {
      _store['bili_sessdata'] = '12345,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final adapter = _RefreshAdapter();
      final result = await _api(adapter).refreshSession();

      expect(result, SessionRenewResult.missingCredentials);
      expect(adapter.requests, isEmpty); // 没发任何请求
      expect(_store['bili_sessdata'],
          '12345,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); // storage 不动
    });

    test('续期成功（Set-Cookie 新 SESSDATA/bili_jct + body 新 refresh_token）'
        '→ renewed 且新会话全入库', () async {
      _store['bili_sessdata'] = 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      _store['bili_jct'] = 'old_jct';
      _store['bili_refresh_token'] = 'old_refresh_token';
      final adapter = _RefreshAdapter(
        body: {
          'code': 0,
          'data': {'refresh_token': 'new_refresh_token'},
        },
        responseHeaders: {
          'set-cookie': [
            'SESSDATA=new_sessdata; Path=/; Max-Age=2592000; HttpOnly',
            'bili_jct=new_jct; Path=/; HttpOnly',
          ],
        },
      );

      final result = await _api(adapter).refreshSession();

      expect(result, SessionRenewResult.renewed);
      // 请求体：csrf=旧 bili_jct + refresh_token=旧刷新口令
      final req = adapter.requests
          .lastWhere((p) => p.path == refreshPath); // 前面还有 spi 指纹请求
      expect(req.path, refreshPath);
      expect((req.data as Map)['csrf'], 'old_jct');
      expect((req.data as Map)['refresh_token'], 'old_refresh_token');
      // 新会话已保存（sessdata/jct/refresh_token 全更新，旧值作废）
      expect(_store['bili_sessdata'], 'new_sessdata');
      expect(_store['bili_jct'], 'new_jct');
      expect(_store['bili_refresh_token'], 'new_refresh_token');
    });

    test('续期成功（响应体兜底：无 Set-Cookie，data.sessdata/bili_jct/'
        'refresh_token）→ renewed 且新会话全入库', () async {
      _store['bili_sessdata'] = 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      _store['bili_jct'] = 'old_jct';
      _store['bili_refresh_token'] = 'old_refresh_token';
      final adapter = _RefreshAdapter(
        body: {
          'code': 0,
          'data': {
            'sessdata': 'body_sessdata',
            'bili_jct': 'body_jct',
            'refresh_token': 'body_rt',
          },
        },
      );

      final result = await _api(adapter).refreshSession();

      expect(result, SessionRenewResult.renewed);
      expect(_store['bili_sessdata'], 'body_sessdata');
      expect(_store['bili_jct'], 'body_jct');
      expect(_store['bili_refresh_token'], 'body_rt');
    });

    test('refresh_token 失效（接口 -101）→ tokenInvalid，storage 不动', () async {
      _store['bili_sessdata'] = 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      _store['bili_jct'] = 'old_jct';
      _store['bili_refresh_token'] = 'dead_refresh_token';
      final adapter = _RefreshAdapter(
        body: {
          'code': -101,
          'message': '账号未登录',
        },
      );

      final result = await _api(adapter).refreshSession();

      expect(result, SessionRenewResult.tokenInvalid);
      expect(_store['bili_sessdata'], 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(_store['bili_jct'], 'old_jct');
      expect(_store['bili_refresh_token'], 'dead_refresh_token');
    });

    test('code=0 但新旧会话都拿不到（异常响应）→ tokenInvalid', () async {
      _store['bili_sessdata'] = 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      _store['bili_jct'] = 'old_jct';
      _store['bili_refresh_token'] = 'old_refresh_token';
      final adapter = _RefreshAdapter(
        body: {
          'code': 0,
          'message': '0',
          'data': {'refresh_token': 'new_rt'}, // 只有新口令，没有新会话
        },
      );

      final result = await _api(adapter).refreshSession();

      expect(result, SessionRenewResult.tokenInvalid);
      // 未拿到新会话前绝不覆盖旧凭据（避免把仍可用的 SESSDATA 弄丢）
      expect(_store['bili_sessdata'], isNotNull);
    });

    test('网络异常 → networkError，storage 不动（下次启动再试，不打扰）',
        () async {
      _store['bili_sessdata'] = 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      _store['bili_jct'] = 'old_jct';
      _store['bili_refresh_token'] = 'old_refresh_token';
      final adapter = _RefreshAdapter.networkError();

      final result = await _api(adapter).refreshSession();

      expect(result, SessionRenewResult.networkError);
      expect(_store['bili_sessdata'], 'old,9999999999,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(_store['bili_jct'], 'old_jct');
      expect(_store['bili_refresh_token'], 'old_refresh_token');
    });
  });

  group('会话凭据辅助', () {
    test('hasRefreshToken：有/无 refresh_token', () async {
      final api = _api(_RefreshAdapter());
      expect(await api.hasRefreshToken(), isFalse);
      _store['bili_refresh_token'] = '';
      expect(await api.hasRefreshToken(), isFalse); // 空串 = 无
      _store['bili_refresh_token'] = 'rt_abc';
      expect(await api.hasRefreshToken(), isTrue);
    });
  });
}
