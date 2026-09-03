// BiliApi.fetchPgcPlayUrl（番剧/电影单集取流 pgc/player/web/playurl）单测
// （mock dio，不访问真实网络）：
// - 请求参数：ep_id / qn / fnval / fourk
// - ⚠️ pgc 接口包装层是 `result`（非普通接口的 `data`）——2026-09 实测定案
// - 解析：durl（mp4 单流）/ dash 双流与普通 playurl 同构；is_preview 试看标志
// - 登录态注入：存在 SESSDATA 时带进 Cookie（含 buvid 指纹）
// - 错误分类：-404 剧集不可播放 / -10403 未登录非大会员 / -412 风控 /
//   code=0 空 result（v_voucher 限流特征 → -352）/ 其他业务码 / 网络失败
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

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
      default:
        return null;
    }
  });
}

/// 按路径路由的 fake adapter：记录请求，返回预置 body。
class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];

  _RoutingAdapter(this.handlers);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final handler = handlers[options.path];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(handler()),
      200,
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

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

/// 会员集匿名试看响应（与 2026-09 实测 ep98604 同构：包装层 `result`、
/// is_preview=1、type=MP4 走 durl[]）。
Map<String, dynamic> _previewBody() => {
      'code': 0,
      'message': 'success',
      'result': {
        'quality': 416,
        'format': 'mp4',
        'is_preview': 1,
        'type': 'MP4',
        'durl': [
          {
            'size': 45642307,
            'length': 360109,
            'url': 'https://upos-sz-mirrorcos.bilivideo.com/preview.mp4',
          },
        ],
      },
    };

/// 免费集完整 DASH 响应（is_preview=0，dash.video[]/audio[] 与普通 playurl 同构）。
Map<String, dynamic> _dashBody({int isPreview = 0}) => {
      'code': 0,
      'message': 'success',
      'result': {
        'quality': 80,
        'format': 'dash',
        'is_preview': isPreview,
        'type': 'DASH',
        'dash': {
          'video': [
            {'baseUrl': 'https://upos.bilivideo.com/video.m4s'},
            {'baseUrl': 'https://upos.bilivideo.com/video2.m4s'},
          ],
          'audio': [
            {'baseUrl': 'https://upos.bilivideo.com/audio.m4s'},
          ],
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  group('fetchPgcPlayUrl 请求参数', () {
    test('ep_id/qn/fnval/fourk 参数 + 路径（无需 WBI 签名）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': _dashBody,
      });
      final api = _api(adapter);

      final r = await api.fetchPgcPlayUrl(98604, qn: 80, fnval: 16);

      expect(r, isA<PgcPlayUrlResult>());
      final req = adapter.requests
          .lastWhere((p) => p.path == '/pgc/player/web/playurl');
      expect(req.queryParameters['ep_id'], '98604');
      expect(req.queryParameters['qn'], '80');
      expect(req.queryParameters['fnval'], '16');
      expect(req.queryParameters['fourk'], '1');
    });

    test('登录态存在时注入 SESSDATA（含 buvid 指纹 Cookie）', () async {
      _store['bili_sessdata'] = 'sessdata_pgc_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': _dashBody,
      });
      await _api(adapter).fetchPgcPlayUrl(98603);

      final req = adapter.requests
          .lastWhere((p) => p.path == '/pgc/player/web/playurl');
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('SESSDATA=sessdata_pgc_test'));
    });

    test('未登录不注入 SESSDATA（保持匿名，仅 buvid 指纹）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': _dashBody,
      });
      await _api(adapter).fetchPgcPlayUrl(98603);

      final req = adapter.requests
          .lastWhere((p) => p.path == '/pgc/player/web/playurl');
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, isNot(contains('SESSDATA=')));
    });
  });

  group('fetchPgcPlayUrl 解析（包装层 result）', () {
    test('dash 双流 + is_preview=0 → 完整流（可播放）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': _dashBody,
      });
      final r = await _api(adapter).fetchPgcPlayUrl(98603);

      expect(r.isPreview, isFalse);
      expect(r.hasStream, isTrue);
      expect(r.quality, 80);
      expect(r.dashVideoUrls, hasLength(2));
      expect(r.dashAudioUrls, hasLength(1));
      expect(r.dashVideoUrls.first,
          'https://upos.bilivideo.com/video.m4s');
      // PgcPlayUrlResult 与普通 PlayUrlResult 同构：播放器可直接复用
      expect(r, isA<PlayUrlResult>());
    });

    test('会员集试看：is_preview=1 + durl mp4 → isPreview=true（不视为完整流）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': _previewBody,
      });
      final r = await _api(adapter).fetchPgcPlayUrl(98604);

      expect(r.isPreview, isTrue); // 试看流标志（播放页据此不播、提示大会员）
      expect(r.hasStream, isTrue); // 但流本体存在（试看可用），决策在播放页
      expect(r.mp4Url, isNotNull);
      expect(r.dashVideoUrls, isEmpty);
      expect(r.dashAudioUrls, isEmpty);
    });

    test('is_preview 缺省（旧响应）→ isPreview=false', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': () => {
              'code': 0,
              'message': 'success',
              'result': {
                'quality': 64,
                'format': 'dash',
                'dash': {
                  'video': [
                    {'baseUrl': 'https://upos.bilivideo.com/v.m4s'},
                  ],
                  'audio': [
                    {'baseUrl': 'https://upos.bilivideo.com/a.m4s'},
                  ],
                },
              },
            },
      });
      final r = await _api(adapter).fetchPgcPlayUrl(98603);
      expect(r.isPreview, isFalse);
    });
  });

  group('fetchPgcPlayUrl 错误分类', () {
    test('code=-404 → BiliApiException(-404) 不可播放', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': () => {
              'code': -404,
              'message': '啥都木有', // 实测无效 ep 的返回
            },
      });
      expect(
        () => _api(adapter).fetchPgcPlayUrl(99999999),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -404)
            .having((e) => e.message, 'message', contains('不可播放'))),
      );
    });

    test('code=-10403 → BiliApiException(-10403) 提示登录大会员', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': () => {
              'code': -10403,
              'message': '大会员专享',
            },
      });
      expect(
        () => _api(adapter).fetchPgcPlayUrl(98604),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -10403)
            .having((e) => e.message, 'message', contains('大会员'))),
      );
    });

    test('code=-412 → BiliApiException(-412) 风控', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': () => {
              'code': -412,
              'message': '请求被拦截',
            },
      });
      expect(
        () => _api(adapter).fetchPgcPlayUrl(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', contains('风控'))),
      );
    });

    test('code=0 但 result 为空（限流特征）→ BiliApiException(-352)', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': () => {
              'code': 0,
              'message': 'success',
              'result': {'v_voucher': 'x'},
            },
      });
      expect(
        () => _api(adapter).fetchPgcPlayUrl(98603),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -352)
            .having((e) => e.message, 'message', contains('限流'))),
      );
    });

    test('其他业务码 → BiliApiException（带接口 message）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/player/web/playurl': () => {
              'code': -400,
              'message': '请求错误',
            },
      });
      expect(
        () => _api(adapter).fetchPgcPlayUrl(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -400)
            .having((e) => e.message, 'message', contains('请求错误'))),
      );
    });

    test('网络连接失败 → 抛 DioException', () {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).fetchPgcPlayUrl(98603),
        throwsA(isA<DioException>()),
      );
    });
  });
}
