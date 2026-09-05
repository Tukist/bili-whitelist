// BiliApi 番剧（pgc/bangumi）接口单元测试（mock dio）：
// - fetchPgcSeason：请求参数（ep_id/season_id）、result 包装层解析
//   （duration 毫秒→秒、badge 判会员）、登录态 Cookie 注入
// - 错误分类：-404 剧不存在 / -412 风控 / 其他业务码 / result 缺失 / 网络失败
// 不访问真实网络。
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

/// 与 pgc_probe 实拍一致的结构（小林家的龙女仆 ss5800 前 2 集特征）。
Map<String, dynamic> _seasonBody({int code = 0, bool withResult = true}) => {
      'code': code,
      'message': code == 0 ? 'success' : '业务错误',
      if (withResult)
        'result': {
          'title': '小林家的龙女仆',
          'cover': 'http://i0.hdslb.com/bfs/bangumi/image/c72a95.png',
          'season_id': 5800,
          'episodes': [
            {
              'ep_id': 98603,
              'aid': 7961887,
              'cid': 481327329,
              'bvid': 'BV1gs411h7DE',
              'title': '1',
              'long_title': '史上最强女仆、托尔！',
              'cover': 'http://i0.hdslb.com/bfs/archive/a.jpg',
              'badge': '',
              'duration': 1377000, // 毫秒 → 1377 秒
              'pub_time': 1484067600, // Unix 秒（单位与普通 view data.pubdate 一致）
            },
            {
              'ep_id': 98604,
              'aid': 8084513,
              'cid': 491364306,
              'bvid': 'BV1Us411h7E4',
              'title': '2',
              'long_title': '第二头龙、康娜！',
              'cover': 'http://i0.hdslb.com/bfs/archive/b.jpg',
              'badge': '会员',
              'duration': 1397000,
              'pub_time': 1484672400,
            },
            {
              // 无 bvid 的脏条目（预告/占位）应被丢弃
              'ep_id': 99999,
              'aid': 0,
              'cid': 0,
              'bvid': '',
              'title': '预告',
              'long_title': '',
              'badge': '',
              'duration': 0,
            },
          ],
        },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  group('fetchPgcSeason', () {
    test('ep_id 请求参数 + result 解析（毫秒换算/badge 判定/脏条目过滤）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/view/web/season': _seasonBody,
      });
      final api = _api(adapter);

      final season = await api.fetchPgcSeason(epId: 98603);

      final req = adapter.requests
          .lastWhere((r) => r.path == '/pgc/view/web/season');
      expect(req.queryParameters['ep_id'], '98603');
      expect(req.queryParameters.containsKey('season_id'), isFalse);

      expect(season.title, '小林家的龙女仆');
      expect(season.cover, 'http://i0.hdslb.com/bfs/bangumi/image/c72a95.png');
      expect(season.seasonId, 5800);
      expect(season.episodes, hasLength(2)); // 无 bvid 脏条目被丢弃
      final free = season.episodes[0];
      expect(free.epId, 98603);
      expect(free.bvid, 'BV1gs411h7DE');
      expect(free.cid, 481327329);
      expect(free.durationSec, 1377); // 1377000 毫秒 → 秒
      expect(free.isVipOrPay, isFalse);
      // pub_time 已是 Unix 秒 → 不做毫秒换算（与 duration 不同单位）
      expect(free.pubTimeSec, 1484067600);
      final vip = season.episodes[1];
      expect(vip.isVipOrPay, isTrue);
      expect(vip.badge, '会员');
      expect(vip.durationSec, 1397);
      expect(vip.pubTimeSec, 1484672400);
      expect(season.vipCount, 1);
      expect(season.hasVipOrPay, isTrue);
    });

    test('season_id 请求参数', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/view/web/season': _seasonBody,
      });
      await _api(adapter).fetchPgcSeason(seasonId: 5800);

      final req = adapter.requests
          .lastWhere((r) => r.path == '/pgc/view/web/season');
      expect(req.queryParameters['season_id'], '5800');
      expect(req.queryParameters.containsKey('ep_id'), isFalse);
    });

    test('登录态存在时注入 SESSDATA（含 buvid 指纹 Cookie）', () async {
      _store['bili_sessdata'] = 'sessdata_test_value';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/view/web/season': _seasonBody,
      });
      await _api(adapter).fetchPgcSeason(epId: 98603);

      final req = adapter.requests
          .lastWhere((r) => r.path == '/pgc/view/web/season');
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('SESSDATA=sessdata_test_value'));
    });

    test('两个参数都为空 → ArgumentError', () {
      expect(
        () => _api(_RoutingAdapter({})).fetchPgcSeason(),
        throwsArgumentError,
      );
    });

    test('code=-404 → BiliApiException(-404) 剧集不存在', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/view/web/season': () => {
              'code': -404,
              'message': '啥都木有',
            },
      });
      expect(
        () => _api(adapter).fetchPgcSeason(epId: 123456),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -404)
            .having((e) => e.message, 'message', contains('不存在'))),
      );
    });

    test('code=-412 → BiliApiException(-412) 风控', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/view/web/season': () => {
              'code': -412,
              'message': '请求被拦截',
            },
      });
      expect(
        () => _api(adapter).fetchPgcSeason(seasonId: 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', contains('风控'))),
      );
    });

    test('code=0 但 result 缺失 → BiliApiException(-404)', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/pgc/view/web/season': () => {
              'code': 0,
              'message': 'success',
            },
      });
      expect(
        () => _api(adapter).fetchPgcSeason(epId: 1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -404)),
      );
    });

    test('网络连接失败 → 抛 DioException', () {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).fetchPgcSeason(epId: 1),
        throwsA(isA<DioException>()),
      );
    });
  });
}
