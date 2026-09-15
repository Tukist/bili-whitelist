// BiliApi.searchLive 单元测试（mock dio）：
// - 请求参数构造正确（WBI 签名参数 + search_type=live_room/keyword/page/page_size）
// - 结果解析（清洗 title 高亮 / 补全 cover / online / live_status）
// - 脏数据容错（缺字段 / 类型不对 → 安全默认，不抛）
// - 过滤掉没有房间号（或标题为空）的条目
// - SearchLivePageResult 字段：results / totalCount / hasMore
// - 错误处理：-412 风控、-352 限流、空结果、result 非 List、网络失败
//
// 字段名按 2026-09-15 真实探针原文写（见 search_live_api_test 的
// `_oneLiveResult` 注释）：search_type=live 不带 `_room` 后缀时
// data.result 不是数组，必须用 live_room。
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

Map<String, dynamic> _searchBody({
  int code = 0,
  List? result,
  int? numResults,
}) =>
    {
      'code': code,
      'message': code == 0 ? 'OK' : '业务错误',
      'data': {
        'seid': 'x',
        if (numResults != null) 'numResults': numResults,
        'result': result ?? <Map<String, dynamic>>[],
      },
    };

/// 一条真实结构的直播结果（字段名 / 取值都照 2026-09-15 探针原文）。
Map<String, dynamic> _oneLiveResult({
  int roomid = 22747736,
  int uid = 406986743,
  String uname = '不死鸟总监',
  String title = '新<em class="keyword">游戏</em> 漫威金刚狼',
  String cover = '//i0.hdslb.com/bfs/live-key-frame/keyframe0915.jpg',
  int online = 445525,
  int liveStatus = 1,
}) =>
    {
      'roomid': roomid,
      'uid': uid,
      'uname': uname,
      'title': title,
      'cover': cover,
      'online': online,
      'live_status': liveStatus,
      // 探针里同条还有这些字段，本模型不取（存在也不能影响解析）
      'area': 1,
      'cate_name': '独立<em class="keyword">游戏</em>',
      'uface': '//i1.hdslb.com/bfs/face/x.jpg',
      'user_cover': '//i0.hdslb.com/bfs/live/new_room_cover/y.jpg',
      'attentions': 536866,
      'live_time': '2026-09-15 13:04:15',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  test('请求参数构造正确（search_type=live_room + WBI 签名）且结果解析清洗',
      () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
          result: [_oneLiveResult(), _oneLiveResult(roomid: 6154037)]),
    });
    final api = _api(adapter);

    final page = await api.searchLive('游戏');

    // 请求参数断言
    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['search_type'], 'live_room',
        reason: '必须是 live_room：search_type=live 实测 result 不是数组');
    expect(req.queryParameters['keyword'], '游戏');
    expect(req.queryParameters['page'], '1');
    expect(req.queryParameters['page_size'], '20');
    expect(req.queryParameters['w_rid'], isNotEmpty);
    expect(req.queryParameters['wts'], isNotEmpty);
    // 直播搜索不支持排序 → 不带 order
    expect(req.queryParameters.containsKey('order'), isFalse);

    // 结果解析断言
    expect(page.results, hasLength(2));
    final first = page.results.first;
    expect(first.roomId, 22747736);
    expect(first.uid, 406986743);
    expect(first.uname, '不死鸟总监');
    expect(first.title, '新游戏 漫威金刚狼', reason: 'em 高亮标签已清洗');
    expect(first.cover,
        'https://i0.hdslb.com/bfs/live-key-frame/keyframe0915.jpg',
        reason: '协议相对 URL 补全为 https');
    expect(first.online, 445525);
    expect(first.liveStatus, 1);
    expect(first.isLiving, isTrue);
  });

  test('page 参数透传', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: []),
    });
    await _api(adapter).searchLive('游戏', page: 2);
    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['page'], '2');
  });

  test('脏数据：缺字段 / 类型异常 → 安全默认，不抛', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: [
            {
              // roomid/uid/uname/title/cover 全缺 → 0 / 空串
              'online': '12.3万', // 脏类型（字符串）→ 0，不抛
              'live_status': null, // null → 0
            },
            {
              'roomid': 6154037,
              'title': '正常房间',
              'online': null, // null → 0
              'live_status': 2,
            },
          ]),
    });
    final page = await _api(adapter).searchLive('k');

    // 第一条 roomId=0 → 被 API 层过滤（进不去直播间）
    expect(page.results, hasLength(1));
    final only = page.results.single;
    expect(only.roomId, 6154037);
    expect(only.uid, 0);
    expect(only.uname, '');
    expect(only.cover, '');
    expect(only.online, 0, reason: '脏类型按 0 处理，不抛类型转换错误');
    expect(only.liveStatus, 2);
    expect(only.isLiving, isFalse, reason: '轮播不算在播');
  });

  test('roomid 缺失 / 标题为空的条目被丢弃（点不进直播间）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: [
            _oneLiveResult(roomid: 0),
            _oneLiveResult(title: '   '),
            _oneLiveResult(roomid: 6154037),
          ]),
    });
    final page = await _api(adapter).searchLive('k');
    expect(page.results, hasLength(1));
    expect(page.results.single.roomId, 6154037);
  });

  test('code=0 但 result 为空数组 → 返回空结果', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: []),
    });
    final page = await _api(adapter).searchLive('不存在的关键词');
    expect(page.results, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('result 不是 List（search_type=live 的实测形态）→ 空结果且不崩',
      () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => {
            'code': 0,
            'message': 'OK',
            'data': {'result': null},
          },
    });
    final page = await _api(adapter).searchLive('游戏');
    expect(page.results, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('hasMore：numResults 已知且 loaded < total → hasMore=true', () async {
    final results = [
      for (var i = 0; i < 20; i++) _oneLiveResult(roomid: 1000 + i),
    ];
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () =>
          _searchBody(result: results, numResults: 1000),
    });
    final page = await _api(adapter).searchLive('游戏');
    expect(page.results, hasLength(20));
    expect(page.totalCount, 1000);
    expect(page.hasMore, isTrue);
    // hasMore 只是接口侧的口径；UI 侧直播不做翻页（只取第 1 页）
  });

  test('-412 → 抛风控异常（提示稍后再搜）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(code: -412),
    });
    expect(
      () => _api(adapter).searchLive('游戏'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -412)
          .having((e) => e.message, 'message', contains('风控'))),
    );
  });

  test('-352 → 抛限流异常（带接口 message，不抛裸异常）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(code: -352),
    });
    expect(
      () => _api(adapter).searchLive('游戏'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -352)
          .having((e) => e.message, 'message', isNotEmpty)),
    );
  });

  test('网络连接失败 → 抛 DioException', () async {
    final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
    dio.httpClientAdapter = _ThrowingAdapter();
    expect(
      () => BiliApi(dio: dio).searchLive('游戏'),
      throwsA(isA<DioException>()),
    );
  });
}
