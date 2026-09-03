// BiliApi.searchMedia 单元测试（mock dio，v2.16.5+）：
// - 请求参数构造正确（WBI 签名 + search_type 透传 + keyword/page/page_size，
//   无 order——media 接口不支持排序）
// - media 结果解析（清洗 title / http(s) cover 补全 / badges 首个角标 /
//   styles / index_show / eps 首集 ep_id）
// - MediaSearchPageResult 字段：results / totalCount / hasMore
// - 脏条目过滤（缺 season_id / title）
// - 错误处理：-412 风控、-1200 降级、空结果（result=null / 非 List）、网络失败
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

Map<String, dynamic> _mediaSearchBody({
  int code = 0,
  Object? result,
  int? numResults,
  String message = 'OK',
}) =>
    {
      'code': code,
      'message': message,
      'data': {
        'seid': 'x',
        if (numResults != null) 'numResults': numResults,
        'result': result ?? <Map<String, dynamic>>[],
      },
    };

/// media_bangumi 实测结构的一单条（小林家的龙女仆 中配版 ss41009）。
Map<String, dynamic> _oneMedia({
  int seasonId = 41009,
  String title = '<em class="keyword">小林家的龙女仆</em> 中配版',
  String cover = 'http://i0.hdslb.com/bfs/bangumi/image/cba.jpg',
  String typeName = '番剧',
  String badge = '独家',
}) =>
    {
      'type': 'media_bangumi',
      'season_id': seasonId,
      'media_id': 28236715,
      'pgc_season_id': seasonId,
      'season_type_name': typeName,
      'title': title,
      'cover': cover,
      'areas': '日本',
      'styles': '漫画改/萌系/搞笑/日常',
      'index_show': '全14话',
      'ep_size': 14,
      'badges': [
        {
          'text': badge,
          'bg_color': '#00C0FF',
        },
      ],
      'display_info': [
        {'text': badge, 'bg_color': '#00C0FF'},
      ],
      'eps': [
        {
          'id': 466290,
          'title': '1',
          'long_title': '史上最强女仆、托尔！(毕竟是龙嘛)',
        },
      ],
      'url': 'https://www.bilibili.com/bangumi/play/ss$seasonId',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  test('searchMedia 请求参数正确（search_type 透传 + WBI + 无 order）且解析清洗',
      () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _mediaSearchBody(
            result: [_oneMedia()],
            numResults: 4,
          ),
    });
    final api = _api(adapter);

    final page =
        await api.searchMedia('小林家的龙女仆', searchType: MediaSearchTypes.bangumi);

    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['search_type'], 'media_bangumi');
    expect(req.queryParameters['keyword'], '小林家的龙女仆');
    expect(req.queryParameters['page'], '1');
    expect(req.queryParameters['page_size'], '20');
    expect(req.queryParameters['order'], isNull,
        reason: 'media 搜索不支持排序，不应带 order 参数');
    expect(req.queryParameters['w_rid'], isNotEmpty);
    expect(req.queryParameters['wts'], isNotEmpty);
    expect(req.queryParameters['dm_img_list'], '[]');

    expect(page.results, hasLength(1));
    final first = page.results.first;
    expect(first.seasonId, 41009);
    expect(first.title, '小林家的龙女仆 中配版');
    expect(first.cover, 'https://i0.hdslb.com/bfs/bangumi/image/cba.jpg',
        reason: 'http:// 封面应补全为 https://');
    expect(first.typeLabel, '番剧');
    expect(first.badge, '独家');
    expect(first.styles, '漫画改/萌系/搞笑/日常');
    expect(first.indexShow, '全14话');
    expect(first.firstEpId, 466290);
    // numResults=4 但本页只有 1 条 → 还有下一页
    expect(page.totalCount, 4);
    expect(page.hasMore, isTrue);
  });

  test('search_type=media_ft（电影）请求透传', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _mediaSearchBody(
            result: [_oneMedia(seasonId: 12548, title: '让子弹飞',
                typeName: '电影', badge: '大会员', cover: '//i0.hdslb.com/x.jpg')],
            numResults: 1,
          ),
    });
    final api = _api(adapter);

    final page = await api.searchMedia('让子弹飞', searchType: MediaSearchTypes.film);
    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['search_type'], 'media_ft');

    final first = page.results.single;
    expect(first.typeLabel, '电影');
    expect(first.badge, '大会员');
    // 以 // 开头的封面同样补 https
    expect(first.cover, 'https://i0.hdslb.com/x.jpg');
    expect(first.seasonId, 12548);
  });

  test('脏条目过滤：缺 season_id 或 title 的项被丢弃', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _mediaSearchBody(
            result: [
              _oneMedia(),
              // 无 season_id（如混入的普通 video 项）
              {'type': 'video', 'title': '某视频', 'bvid': 'BV1'},
              // 空 title
              {
                ..._oneMedia(seasonId: 999),
                'title': '',
              },
            ],
            numResults: 1,
          ),
    });
    final page = await _api(adapter)
        .searchMedia('x', searchType: MediaSearchTypes.bangumi);
    expect(page.results, hasLength(1));
    expect(page.results.single.seasonId, 41009);
  });

  test('numResults 未知 + 装满 20 条 → hasMore=true（兜底）', () async {
    final results =
        List.generate(20, (i) => _oneMedia(seasonId: 41000 + i));
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () =>
          _mediaSearchBody(result: results),
    });
    final page = await _api(adapter)
        .searchMedia('k', searchType: MediaSearchTypes.bangumi);
    expect(page.results, hasLength(20));
    expect(page.totalCount, isNull);
    expect(page.hasMore, isTrue);
  });

  test('code=0 且 result=null（电影无命中实测形态）→ 空结果不崩', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _mediaSearchBody(
            result: null,
            numResults: 0,
          ),
    });
    final page =
        await _api(adapter).searchMedia('没有的电影', searchType: MediaSearchTypes.film);
    expect(page.results, isEmpty);
    expect(page.totalCount, 0);
    expect(page.hasMore, isFalse);
  });

  test('-412 → 抛风控异常', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _mediaSearchBody(code: -412),
    });
    expect(
      () => _api(adapter)
          .searchMedia('x', searchType: MediaSearchTypes.bangumi),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -412)
          .having((e) => e.message, 'message', contains('风控'))),
    );
  });

  test('-1200 → 抛降级过滤异常（media_tv/media_doc 匿名实测码）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () =>
          _mediaSearchBody(code: -1200, message: '被降级过滤的请求'),
    });
    expect(
      () => _api(adapter).searchMedia('琅琊榜', searchType: MediaSearchTypes.tv),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -1200)
          .having((e) => e.message, 'message', contains('降级'))),
    );
  });

  test('其他业务码 → 抛带接口 message 的 BiliApiException', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () =>
          _mediaSearchBody(code: -352, message: '请求被拦截'),
    });
    expect(
      () => _api(adapter)
          .searchMedia('x', searchType: MediaSearchTypes.bangumi),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -352)
          .having((e) => e.message, 'message', '请求被拦截')),
    );
  });

  test('网络连接失败 → 抛 DioException', () async {
    final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
    dio.httpClientAdapter = _ThrowingAdapter();
    expect(
      () => BiliApi(dio: dio)
          .searchMedia('无职转生', searchType: MediaSearchTypes.bangumi),
      throwsA(isA<DioException>()),
    );
  });
}
