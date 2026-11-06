// BiliApi.searchArticle（专栏搜索，v2.61.0+）单元测试（mock dio，不触网）：
// - 请求参数构造（WBI 签名 + search_type=article + page/page_size/order）
// - 结果解析（cv 号 / 清洗标题 / 封面取 image_urls[0] / 阅读·点赞 / 时间）
// - 字段缺失与脏值容错（没有 image_urls、id 是字符串、view 是脏串…）
// - 风控校验（code=0 但只有 v_voucher）→ 抛异常而不是空结果
// - hasMore 两条路径 + 空结果 + 网络失败
//
// 字段全集依据 2026-11-06 匿名实测响应（见 lib/models/article_search_result.dart）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

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
  Map<String, dynamic>? extraData,
}) =>
    {
      'code': code,
      'message': code == 0 ? 'OK' : '业务错误',
      'data': {
        if (result != null) 'result': result,
        if (numResults != null) 'numResults': numResults,
        if (extraData != null) ...extraData,
      },
    };

/// 一条实测形状的专栏结果（字段名逐字取自 2026-11-06 响应）。
Map<String, dynamic> _oneResult({
  Object id = 34975835,
  String title = '<em class="keyword">原神</em>壁纸62——申鹤篇6',
  String author = '宵宫你带我走吧-代肝',
  Object view = 56494,
  Object like = 978,
  int pubTime = 1717248600,
}) =>
    {
      'author': author,
      'category_id': 8,
      'category_name': '手机游戏',
      'comment_url': '',
      'desc': '小姨ai未尝不可 看图先点赞',
      'id': id,
      'image_urls': ['//i2.hdslb.com/bfs/new_dyn/e4707b80c6.png'],
      'is_comment': 0,
      'is_fold': false,
      'is_official': false,
      'is_rk1': false,
      'like': like,
      'mid': 1177593795,
      'pub_time': pubTime,
      'pubdate': pubTime,
      'rank_index': 1,
      'rank_offset': 0,
      'reply': 18,
      'spread_id': 0,
      'sub_type': 0,
      'template_id': 4,
      'title': title,
      'type': 'article',
      'version': '',
      'view': view,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  test('请求参数：search_type=article + keyword/page/page_size/order + WBI 签名',
      () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: []),
    });

    await _api(adapter).searchArticle('原神');

    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['search_type'], 'article');
    expect(req.queryParameters['keyword'], '原神');
    expect(req.queryParameters['page'], '1');
    expect(req.queryParameters['page_size'], '20');
    expect(req.queryParameters['order'], 'totalrank');
    expect(req.queryParameters['w_rid'], isNotEmpty);
    expect(req.queryParameters['wts'], isNotEmpty);
  });

  test('分页与排序参数透传（page=2 / order=pubdate）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: []),
    });

    await _api(adapter).searchArticle('原神', page: 2, order: 'pubdate');

    final req = adapter.requests
        .lastWhere((r) => r.path == '/x/web-interface/wbi/search/type');
    expect(req.queryParameters['page'], '2');
    expect(req.queryParameters['order'], 'pubdate');
  });

  test('结果解析：cv 号 / 清洗标题 / image_urls 封面 / 阅读·点赞 / 时间', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            result: [_oneResult()],
            numResults: 1,
          ),
    });

    final page = await _api(adapter).searchArticle('原神');

    expect(page.results, hasLength(1));
    final a = page.results.single;
    expect(a.cvid, 34975835);
    expect(a.title, '原神壁纸62——申鹤篇6', reason: '<em> 高亮标签必须清洗');
    expect(a.author, '宵宫你带我走吧-代肝');
    expect(a.desc, '小姨ai未尝不可 看图先点赞');
    expect(a.cover, 'https://i2.hdslb.com/bfs/new_dyn/e4707b80c6.png',
        reason: '协议相对 URL 必须补 https:');
    expect(a.view, 56494);
    expect(a.like, 978);
    expect(a.pubDate, 1717248600);
    expect(a.category, '手机游戏');
    expect(page.totalCount, 1);
    expect(page.hasMore, isFalse);
  });

  test('字段缺失/脏值容错：无封面、id 为字符串、view 为脏串、title 缺失', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            result: [
              {
                'id': '12345',
                'title': '字符串 id 的专栏',
                'view': '很多',
                'image_urls': [],
              },
              {
                'id': 777,
                // 没有 title / desc / author / image_urls
                'view': 3,
              },
              {'id': 0, 'title': '没有 cv 号 → 丢弃'},
              {'title': 'id 缺失 → 丢弃'},
            ],
          ),
    });

    final page = await _api(adapter).searchArticle('k');

    // 没有 cv 号的两条被过滤
    expect(page.results, hasLength(2));
    final first = page.results[0];
    expect(first.cvid, 12345, reason: '字符串 id 也要能解析');
    expect(first.cover, '');
    expect(first.view, 0, reason: '脏串阅读数 → 0，不抛错');
    expect(first.author, '');
    expect(first.desc, '');
    final second = page.results[1];
    expect(second.cvid, 777);
    expect(second.title, '');
    expect(second.view, 3);
    expect(second.pubDate, 0);
  });

  test('封面兜底：image_urls 无有效项时退回 cover / pic', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            result: [
              {
                'id': 1,
                'title': 'a',
                'image_urls': [null, 42],
                'cover': '//i0.hdslb.com/bfs/cover.jpg',
              },
              {
                'id': 2,
                'title': 'b',
                'pic': 'https://i0.hdslb.com/bfs/pic.jpg',
              },
            ],
          ),
    });

    final page = await _api(adapter).searchArticle('k');
    expect(page.results[0].cover, 'https://i0.hdslb.com/bfs/cover.jpg');
    expect(page.results[1].cover, 'https://i0.hdslb.com/bfs/pic.jpg');
  });

  test('hasMore：numResults 已知且 loaded < total → true', () async {
    final results = List.generate(20, (i) => _oneResult(id: 100 + i));
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            result: results,
            numResults: 1000,
          ),
    });

    final page = await _api(adapter).searchArticle('原神');
    expect(page.results, hasLength(20));
    expect(page.totalCount, 1000);
    expect(page.hasMore, isTrue);
  });

  test('hasMore：numResults 已知且 loaded == total → false', () async {
    final results = List.generate(5, (i) => _oneResult(id: 200 + i));
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            result: results,
            numResults: 5,
          ),
    });

    final page = await _api(adapter).searchArticle('k');
    expect(page.hasMore, isFalse);
  });

  test('hasMore：numResults 缺失 + 装满 20 条 → true（兜底）', () async {
    final results = List.generate(20, (i) => _oneResult(id: 300 + i));
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(result: results),
    });

    final page = await _api(adapter).searchArticle('k');
    expect(page.totalCount, isNull);
    expect(page.hasMore, isTrue);
  });

  test('真的没结果：code=0 + result 空数组 → 空结果（不是异常）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            result: [],
            numResults: 0,
          ),
    });

    final page = await _api(adapter).searchArticle('zzz不存在的词');
    expect(page.results, isEmpty);
    expect(page.totalCount, 0);
    expect(page.hasMore, isFalse);
  });

  test('风控校验：code=0 但 data 只有 v_voucher（无 result）→ 抛可读异常', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(
            extraData: {'v_voucher': 'voucher-xxx'},
          ),
    });

    expect(
      () => _api(adapter).searchArticle('原神', page: 2),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -412)
          .having((e) => e.message, 'message', contains('风控'))),
      reason: '风控校验不能被当成「没有找到相关专栏」',
    );
  });

  test('-412 → 抛风控异常', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/web-interface/wbi/search/type': () => _searchBody(code: -412),
    });

    expect(
      () => _api(adapter).searchArticle('原神'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -412)
          .having((e) => e.message, 'message', contains('风控'))),
    );
  });

  test('网络失败 → 抛 DioException（UI 提示网络错误）', () async {
    expect(
      () => _api(_ThrowingAdapter()).searchArticle('原神'),
      throwsA(isA<DioException>()),
    );
  });
}
