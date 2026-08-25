// BiliApi.searchVideo 单元测试（mock dio）：
// - 请求参数构造正确（WBI 签名参数 + search_type/keyword/page/page_size）
// - 结果解析（清洗 title / 补全 cover / 时长 / 播放量）
// - 错误处理：-412 风控、-352 限流、空结果、网络失败
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

Map<String, dynamic> _navBody() => {
      'code': -101,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

Map<String, dynamic> _searchBody({int code = 0, List? result}) => {
      'code': code,
      'message': code == 0 ? 'OK' : '业务错误',
      'data': {
        'seid': 'x',
        'result': result ?? <Map<String, dynamic>>[],
      },
    };

Map<String, dynamic> _oneResult({Object play = 179906}) => {
      'bvid': 'BV1g5411J7Lh',
      'title': '旅人の唄 - <em class="keyword">无职转生</em> OP',
      'pic': '//i0.hdslb.com/bfs/archive/a.jpg',
      'author': 'Zyglisfer',
      'duration': '4:45',
      'play': play,
      'pubdate': 1611978055,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  test('搜索请求参数构造正确（WBI 签名 + 搜索参数）且结果解析清洗', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
          result: [_oneResult(), _oneResult(play: '12.3万')]),
    });
    final api = _api(adapter);

    final results = await api.searchVideo('无职转生');

    // 请求参数断言
    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['search_type'], 'video');
    expect(req.queryParameters['keyword'], '无职转生');
    expect(req.queryParameters['page'], '1');
    expect(req.queryParameters['page_size'], '20');
    expect(req.queryParameters['w_rid'], isNotEmpty);
    expect(req.queryParameters['wts'], isNotEmpty);
    expect(req.queryParameters['dm_img_list'], '[]');

    // 结果解析断言
    expect(results, hasLength(2));
    final first = results.first;
    expect(first.bvid, 'BV1g5411J7Lh');
    expect(first.title, '旅人の唄 - 无职转生 OP');
    expect(first.cover, 'https://i0.hdslb.com/bfs/archive/a.jpg');
    expect(first.author, 'Zyglisfer');
    expect(first.durationSec, 285);
    expect(first.playCount, 179906);
    expect(first.pubDate, 1611978055);
    // 字符串播放量 "12.3万" → 123000
    expect(results[1].playCount, 123000);
  });

  test('-412 → 抛风控异常（提示稍后再搜）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(code: -412),
    });
    expect(
      () => _api(adapter).searchVideo('无职转生'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -412)
          .having((e) => e.message, 'message', contains('风控'))),
    );
  });

  test('-352 → 抛限流异常', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(code: -352),
    });
    expect(
      () => _api(adapter).searchVideo('无职转生'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -352)
          .having((e) => e.message, 'message', isNotEmpty)),
    );
  });

  test('code=0 但 result 为空数组 → 返回空列表（无结果）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: []),
    });
    expect(await _api(adapter).searchVideo('不存在的关键词'), isEmpty);
  });

  test('result 不是 List（异常结构）→ 返回空列表（不崩）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => {
            'code': 0,
            'message': 'OK',
            'data': {'result': 'not-a-list'},
          },
    });
    expect(await _api(adapter).searchVideo('x'), isEmpty);
  });

  test('网络连接失败 → 抛 DioException', () async {
    final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
    dio.httpClientAdapter = _ThrowingAdapter();
    expect(
      () => BiliApi(dio: dio).searchVideo('无职转生'),
      throwsA(isA<DioException>()),
    );
  });
}
