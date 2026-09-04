// BiliApi 评论区接口单元测试（mock dio）：
// - fetchVideoComments：请求参数（aid/mode/next）、解析（replies/top/cursor）、
//   空态（replies null/[]）、oid 不一致丢弃、12002/-412/-352/其他/网络错误
// - fetchReplyChildren：请求参数（root/pn/ps）、page.count 换算 hasMore、
//   空态
// - fetchVideoAid：meta 命中不走网络 / 走 view 补 aid / view 失败返回 null
// 不访问真实网络。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
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

/// nav 接口（WBI key 来源；view 接口带 WBI 签名需先取 key）。
Map<String, dynamic> _navBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png',
        },
      },
    };

/// 构造一条回复 JSON（与 x/v2/reply 实测字段一致；oid 属于外层条目）。
Map<String, dynamic> _replyJson({
  required int rpid,
  int root = 0,
  int parent = 0,
  int count = 0,
  int oid = 170001,
  int? like,
  String message = '前排',
  List<Map<String, dynamic>>? pictures,
  List<Map<String, dynamic>>? nested,
}) =>
    {
      'rpid': rpid,
      'oid': oid,
      'root': root,
      'parent': parent,
      'count': count,
      'like': like ?? 3,
      'ctime': 1700000000,
      'member': {
        'uname': '评论君',
        'avatar': 'http://i0.hdslb.com/bfs/face/a.jpg',
        'level_info': {'current_level': 5},
      },
      'content': {
        'message': message,
        if (pictures != null) 'pictures': pictures,
      },
      if (nested != null) 'replies': nested,
    };

Map<String, dynamic> _mainBody({
  int code = 0,
  List<Map<String, dynamic>>? replies,
  List<Map<String, dynamic>>? topReplies,
  int? next,
  bool isEnd = false,
  int? allCount,
}) =>
    {
      'code': code,
      'message': code == 0 ? 'success' : 'err',
      'data': {
        'replies': replies,
        'top_replies': topReplies,
        'cursor': {
          if (next != null) 'next': next,
          'is_end': isEnd,
          'all_count': allCount ?? (replies?.length ?? 0),
        },
      },
    };

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1test',
      cid: 1,
      title: 't',
      cover: '',
      duration: 0,
      upName: 'u',
      addedAt: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  group('fetchVideoComments', () {
    test('请求参数 aid/mode/next + 完整解析（图片/br/楼中楼预览/cursor）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => _mainBody(
              next: 15,
              isEnd: false,
              allCount: 342,
              replies: [
                _replyJson(
                  rpid: 9001,
                  count: 5,
                  message: '第一行<br />第二行 &amp; 结束',
                  pictures: [
                    {
                      'img_src': 'http://i0.hdslb.com/bfs/comment/1.jpg',
                      'img_width': 800,
                      'img_height': 600,
                      'play_gif_thumbnail': true,
                    },
                  ],
                  nested: [
                    _replyJson(
                        rpid: 9101, parent: 9001, root: 9001, message: '楼中楼1'),
                    _replyJson(
                        rpid: 9102, parent: 9001, root: 9001, message: '楼中楼2'),
                  ],
                ),
                _replyJson(rpid: 9002, count: 0, message: '无回复'),
              ],
              topReplies: [_replyJson(rpid: 8888, message: '置顶评论')],
            ),
      });
      final api = _api(adapter);

      final page = await api.fetchVideoComments(aid: 170001, next: 0);

      final req = adapter.requests
          .lastWhere((r) => r.path == '/x/v2/reply/main');
      expect(req.queryParameters['type'], '1');
      expect(req.queryParameters['oid'], '170001');
      expect(req.queryParameters['mode'], '3');
      expect(req.queryParameters['next'], '0');

      expect(page.cursorNext, 15);
      expect(page.isEnd, isFalse);
      expect(page.totalCount, 342);

      // 置顶单独列出
      expect(page.topReplies, hasLength(1));
      expect(page.topReplies.first.message, '置顶评论');

      // 根评论：正文清洗 + 图片 + 楼中楼预览
      final r = page.replies.first;
      expect(r.rpid, 9001);
      expect(r.message, '第一行\n第二行 & 结束');
      expect(r.pictures, hasLength(1));
      expect(r.pictures.first.imgSrc,
          'https://i0.hdslb.com/bfs/comment/1.jpg');
      expect(r.pictures.first.width, 800);
      expect(r.pictures.first.height, 600);
      expect(r.pictures.first.isGif, isTrue);
      expect(r.previews, hasLength(2));
      expect(r.previews[0].message, '楼中楼1');
      expect(page.replies[1].message, '无回复');
    });

    test('cursor.next 原样透传（下次请求把上游 next 传回）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () =>
            _mainBody(next: 30, replies: [_replyJson(rpid: 1)]),
      });
      final page = await _api(adapter)
          .fetchVideoComments(aid: 170001, mode: 3, next: 15);
      expect(page.cursorNext, 30);
    });

    test('登录态存在时注入 SESSDATA（含 buvid 指纹 Cookie）', () async {
      _store['bili_sessdata'] = 'sessdata_test_value';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => _mainBody(replies: []),
      });
      await _api(adapter).fetchVideoComments(aid: 170001);
      final req = adapter.requests
          .lastWhere((r) => r.path == '/x/v2/reply/main');
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('SESSDATA=sessdata_test_value'));
    });

    test('replies 为 null / 空数组 → 空态（isEnd=true 暂无）', () async {
      final adapter1 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => _mainBody(replies: null),
      });
      final page1 = await _api(adapter1).fetchVideoComments(aid: 170001);
      expect(page1.replies, isEmpty);
      expect(page1.hasAny, isFalse);
      expect(page1.isEnd, isTrue);
      expect(page1.cursorNext, 0);

      final adapter2 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => _mainBody(replies: [], isEnd: false),
      });
      final page2 = await _api(adapter2).fetchVideoComments(aid: 170001);
      expect(page2.replies, isEmpty);
      expect(page2.isEnd, isTrue); // 空页按到底处理
    });

    test('data 缺失（code=0）→ 空页', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => {'code': 0, 'message': 'success'},
      });
      final page = await _api(adapter).fetchVideoComments(aid: 170001);
      expect(page.replies, isEmpty);
      expect(page.isEnd, isTrue);
    });

    test('oid 与 aid 不一致的条目被丢弃', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => _mainBody(
              replies: [
                _replyJson(rpid: 1, oid: 170001, message: '匹配'),
                _replyJson(rpid: 2, oid: 999999, message: '脏条目应丢弃'),
                _replyJson(rpid: 3, message: '无 oid 字段保留'),
              ],
            ),
      });
      final page = await _api(adapter).fetchVideoComments(aid: 170001);
      expect(page.replies.map((r) => r.rpid).toList(), [1, 3]);
    });

    test('code=12002 → BiliApiException「评论区已关闭」', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => {
              'code': 12002,
              'message': '评论区已关闭',
            },
      });
      expect(
        () => _api(adapter).fetchVideoComments(aid: 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', 12002)
            .having((e) => e.message, 'message', contains('评论区已关闭'))),
      );
    });

    test('code=-412 / -352 → 对应风控/限流提示', () async {
      final adapter412 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => {'code': -412, 'message': '拦截'},
      });
      expect(
        () => _api(adapter412).fetchVideoComments(aid: 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', contains('风控'))),
      );

      final adapter352 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => {'code': -352, 'message': '限流'},
      });
      expect(
        () => _api(adapter352).fetchVideoComments(aid: 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -352)
            .having((e) => e.message, 'message', contains('限流'))),
      );
    });

    test('其他业务码 → 带接口 message', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/main': () => {'code': -404, 'message': '啥都木有'},
      });
      expect(
        () => _api(adapter).fetchVideoComments(aid: 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -404)
            .having((e) => e.message, 'message', '啥都木有')),
      );
    });

    test('网络连接失败 → 抛 DioException', () {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).fetchVideoComments(aid: 1),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('fetchReplyChildren', () {
    Map<String, dynamic> childrenBody({
      List<Map<String, dynamic>>? replies,
      int num = 1,
      int size = 20,
      int count = 0,
    }) =>
        {
          'code': 0,
          'message': 'success',
          'data': {
            'replies': replies,
            'page': {'num': num, 'size': size, 'count': count},
          },
        };

    test('请求参数 root/pn/ps + 解析', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/reply': () => childrenBody(
              num: 2,
              count: 45,
              replies: [
                for (var i = 0; i < 20; i++)
                  _replyJson(rpid: 1000 + i, parent: 9001, root: 9001),
              ],
            ),
      });
      final page = await _api(adapter).fetchReplyChildren(
        aid: 170001,
        root: 9001,
        pn: 2,
      );
      final req = adapter.requests
          .lastWhere((r) => r.path == '/x/v2/reply/reply');
      expect(req.queryParameters['type'], '1');
      expect(req.queryParameters['oid'], '170001');
      expect(req.queryParameters['root'], '9001');
      expect(req.queryParameters['pn'], '2');
      expect(req.queryParameters['ps'], '20');

      expect(page.replies, hasLength(20));
      expect(page.replies.first.root, 9001);
      // pn(2) × ps(20)=40 < count(45) → 还有更多
      expect(page.hasMore, isTrue);
    });

    test('hasMore = pn×ps < page.count；最后一页 false', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/reply': () => childrenBody(
              num: 3,
              count: 45,
              replies: [
                for (var i = 0; i < 5; i++)
                  _replyJson(rpid: 3000 + i, root: 9001),
              ],
            ),
      });
      final page = await _api(adapter).fetchReplyChildren(
        aid: 170001,
        root: 9001,
        pn: 3,
      );
      expect(page.hasMore, isFalse); // 3×20=60 ≥ 45 → 到底
    });

    test('replies 为空 → hasMore=false（不继续拉空页）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/reply': () => childrenBody(num: 1, count: 45),
      });
      final page = await _api(adapter)
          .fetchReplyChildren(aid: 170001, root: 9001);
      expect(page.replies, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('data 缺失 → 空页', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/reply': () => {'code': 0, 'message': 'success'},
      });
      final page = await _api(adapter)
          .fetchReplyChildren(aid: 170001, root: 1);
      expect(page.replies, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('oid 不一致条目丢弃', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v2/reply/reply': () => childrenBody(
              count: 2,
              replies: [
                _replyJson(rpid: 1, oid: 170001),
                _replyJson(rpid: 2, oid: 55555),
              ],
            ),
      });
      final page = await _api(adapter)
          .fetchReplyChildren(aid: 170001, root: 9001);
      expect(page.replies.map((r) => r.rpid).toList(), [1]);
    });
  });

  group('fetchVideoAid', () {
    test('meta 已带 aid → 直接用，不发 view 请求', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
      });
      final aid = await _api(adapter)
          .fetchVideoAid(_video(), meta: {'aid': 123456});
      expect(aid, 123456);
      expect(
        adapter.requests.any((r) => r.path == '/x/web-interface/view'),
        isFalse,
      );
    });

    test('无 meta → 走 view 接口补 aid', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody, // view 接口带 WBI 签名，先拿 key
        '/x/web-interface/view': () => {
              'code': 0,
              'message': 'success',
              'data': {'aid': 789012, 'bvid': 'BV1test'},
            },
      });
      final aid = await _api(adapter).fetchVideoAid(_video());
      expect(aid, 789012);
    });

    test('view 失败 → 返回 null（调用方提示重试）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/view': () => {'code': -404, 'message': '啥都木有'},
      });
      expect(await _api(adapter).fetchVideoAid(_video()), isNull);
    });
  });
}
