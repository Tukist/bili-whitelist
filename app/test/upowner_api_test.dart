// BiliApi.searchUpowner / fetchUpownerVideos / fetchUpownerInfo 单元测试
// （mock dio）：
// - 搜索参数构造正确（search_type=bili_user + WBI 签名 + 默认 page=1）
// - searchUpowner 解析 result[] → Upowner（含 official_verify.desc 拼接、
//   头像 // 开头补 https:、mid 缺省 0）
// - fetchUpownerVideos 解析 vlist[] → WhitelistVideo（length "mm:ss" 解析、
//   pic 补全 https:、缺 cid=0）
// - fetchUpownerInfo 解析 acc/info → UpownerInfo（face 补全、sign 字段）
// - 错误处理：-412 风控、-352 限流、网络失败（复用现有 BiliApiException）
// 不访问真实网络。
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
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
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

Map<String, dynamic> _userSearchBody({
  int code = 0,
  List? result,
  int? numResults,
}) => {
  'code': code,
  'message': code == 0 ? 'OK' : '业务错误',
  'data': {
    if (numResults != null) 'numResults': numResults,
    'result': result ?? <Map<String, dynamic>>[],
  },
};

Map<String, dynamic> _oneUpowner({
  int mid = 100,
  String uname = '测试UP主',
  String upic = '//i0.hdslb.com/bfs/face/abc.jpg',
  int fans = 12345,
  int type = -1,
  String desc = '',
}) => {
  'mid': mid,
  'uname': uname,
  'upic': upic,
  'fans': fans,
  'official_verify': {'type': type, 'desc': desc},
};

Map<String, dynamic> _videoListBody({int code = 0, List? vlist, int? count}) =>
    {
      'code': code,
      'message': code == 0 ? 'OK' : '业务错误',
      'data': {
        'list': {
          if (count != null) 'count': count,
          'vlist': vlist ?? <Map<String, dynamic>>[],
        },
      },
    };

Map<String, dynamic> _oneVideo({
  String bvid = 'BV1xx',
  String title = '测试视频',
  String length = '4:45',
  String author = 'UP',
  String pic = '//i0.hdslb.com/bfs/archive/x.jpg',
  int created = 1700000000,
}) => {
  'bvid': bvid,
  'title': title,
  'length': length,
  'author': author,
  'pic': pic,
  'mid': 100,
  'created': created,
  'play': 999,
  'favorites': 11,
};

Map<String, dynamic> _upownerInfoBody({
  int code = 0,
  String name = '测试UP主',
  String face = '//i0.hdslb.com/bfs/face/y.jpg',
  int fans = 99999,
  String sign = '这是简介',
}) => {
  'code': code,
  'message': code == 0 ? 'OK' : '业务错误',
  'data': {'name': name, 'face': face, 'fans': fans, 'sign': sign},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  group('searchUpowner', () {
    test('请求参数构造正确（search_type=bili_user + 默认 page=1）'
        '且结果解析（头像补全、desc 拼接）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/wbi/search/type': () => _userSearchBody(
          result: [
            _oneUpowner(mid: 100, uname: 'A'),
            _oneUpowner(
              mid: 200,
              uname: 'B',
              type: 1,
              desc: '知名UP主',
              upic: 'https://i0.hdslb.com/bfs/face/d.jpg',
              fans: 50000,
            ),
          ],
        ),
      });
      final api = _api(adapter);

      final page = await api.searchUpowner('测试');

      // 请求参数断言
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/web-interface/wbi/search/type',
      );
      expect(req.queryParameters['search_type'], 'bili_user');
      expect(req.queryParameters['keyword'], '测试');
      expect(req.queryParameters['page'], '1');
      expect(req.queryParameters['page_size'], '20');
      expect(req.queryParameters['w_rid'], isNotEmpty);

      // 结果解析
      expect(page.upowners, hasLength(2));
      expect(page.upowners[0].mid, 100);
      expect(page.upowners[0].name, 'A');
      expect(page.upowners[0].face, 'https://i0.hdslb.com/bfs/face/abc.jpg');
      // 个人认证 type=1 desc 有 → 名字后拼 desc
      expect(page.upowners[1].name, 'B · 知名UP主');
      expect(page.upowners[1].face, 'https://i0.hdslb.com/bfs/face/d.jpg');
      expect(page.upowners[1].fans, 50000);
    });

    test('缺 mid 的脏数据被丢弃', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/wbi/search/type': () => _userSearchBody(
          result: [
            {'mid': null, 'uname': '垃圾'},
            _oneUpowner(mid: 1),
          ],
        ),
      });
      final page = await _api(adapter).searchUpowner('x');
      expect(page.upowners, hasLength(1));
      expect(page.upowners.single.mid, 1);
    });

    test('numResults 已知 → hasMore 走真实总条数判断', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/wbi/search/type': () => _userSearchBody(
          result: List.generate(20, (i) => _oneUpowner(mid: i + 1)),
          numResults: 85,
        ),
      });
      final page = await _api(adapter).searchUpowner('x');
      expect(page.hasMore, isTrue);
      expect(page.totalCount, 85);
    });

    test('numResults 未知 + 装满 20 → hasMore=true 兜底', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/wbi/search/type': () => _userSearchBody(
          result: List.generate(20, (i) => _oneUpowner(mid: i + 1)),
        ),
      });
      final page = await _api(adapter).searchUpowner('x');
      expect(page.hasMore, isTrue);
    });

    test('-412 → 抛风控异常', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/wbi/search/type': () => _userSearchBody(code: -412),
      });
      expect(
        () => _api(adapter).searchUpowner('x'),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -412)
              .having((e) => e.message, 'message', contains('风控')),
        ),
      );
    });

    test('-352 → 抛限流异常', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/web-interface/wbi/search/type': () => _userSearchBody(code: -352),
      });
      expect(
        () => _api(adapter).searchUpowner('x'),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -352)),
      );
    });

    test('网络连接失败 → 抛 DioException', () async {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).searchUpowner('x'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('fetchUpownerVideos', () {
    test('请求参数：mid/pn/ps/order + 默认 order=pubdate/ps=20', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo()], count: 1),
      });
      final api = _api(adapter);
      final page = await api.fetchUpownerVideos(12345);
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/space/wbi/arc/search',
      );
      expect(req.queryParameters['mid'], '12345');
      expect(req.queryParameters['pn'], '1');
      expect(req.queryParameters['ps'], '20');
      expect(req.queryParameters['order'], 'pubdate');
      expect(req.queryParameters['w_rid'], isNotEmpty);

      expect(page.videos, hasLength(1));
      expect(page.videos.first.bvid, 'BV1xx');
      expect(page.videos.first.title, '测试视频');
      // length "4:45" → 285 秒
      expect(page.videos.first.duration, 285);
      // pic // 开头 → 补全 https:
      expect(page.videos.first.cover, 'https://i0.hdslb.com/bfs/archive/x.jpg');
      // cid=0（详情页 view 补）
      expect(page.videos.first.cid, 0);
      expect(page.videos.first.upName, 'UP');
      expect(page.videos.first.collection, '');
      expect(page.videos.first.order, 0);
      expect(page.hasMore, isFalse);
      expect(page.totalCount, 1);
    });

    test('keyword 非空 → 带 keyword 参数；空白会 trim', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo()], count: 1),
      });
      await _api(adapter).fetchUpownerVideos(
        12345,
        pn: 2,
        order: 'click',
        keyword: '  flutter  ',
      );
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/space/wbi/arc/search',
      );
      expect(req.queryParameters['mid'], '12345');
      expect(req.queryParameters['pn'], '2');
      expect(req.queryParameters['order'], 'click');
      expect(req.queryParameters['keyword'], 'flutter');
    });

    test('请求带齐 wbi 签名（w_rid/wts）+ buvid3/4 指纹 Cookie（防风控）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(vlist: []),
      });
      await _api(adapter).fetchUpownerVideos(12345);
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/space/wbi/arc/search',
      );
      // wbi 签名参数齐全（wts 时间戳 + w_rid + dm 反风控参数）
      expect(req.queryParameters['w_rid'], isNotEmpty);
      expect(req.queryParameters['wts'], isNotEmpty);
      expect(req.queryParameters['dm_img_str'], isNotEmpty);
      // Cookie 头带 buvid3/buvid4 指纹（来自 spi 接口）
      final cookie = req.headers['Cookie'] as String? ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('buvid4=buvid4test'));
    });

    test('totalCount 优先取 data.page.count（实测字段，list.count 为 null）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => {
          'code': 0,
          'message': 'OK',
          'data': {
            'list': {
              // 真实响应 list 不含 count（只有 vlist/tlist/slist）
              'vlist': List.generate(20, (i) => _oneVideo(bvid: 'BV$i')),
            },
            'page': {'pn': 1, 'ps': 20, 'count': 673},
          },
        },
      });
      final page = await _api(adapter).fetchUpownerVideos(12345);
      expect(page.totalCount, 673);
      expect(page.hasMore, isTrue); // 已加载 20 < 673
    });

    test('page.count 缺失时回退 list.count（兼容历史响应）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo()], count: 1),
      });
      final page = await _api(adapter).fetchUpownerVideos(12345);
      expect(page.totalCount, 1);
      expect(page.hasMore, isFalse);
    });

    test('length 含小时（"1:02:03"）→ 解析为 3723 秒', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo(length: '1:02:03')], count: 1),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos.first.duration, 3723);
    });

    test('length 非法（"abc"）→ duration=0，不崩', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo(length: 'abc')]),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos.first.duration, 0);
    });

    test('count=20 + count=85 → hasMore=true（按 count 判断）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(
          vlist: List.generate(20, (i) => _oneVideo(bvid: 'BV$i')),
          count: 85,
        ),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos, hasLength(20));
      expect(page.hasMore, isTrue);
    });

    test('-412 → 抛风控异常', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(code: -412),
      });
      expect(
        () => _api(adapter).fetchUpownerVideos(1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -412)),
      );
    });

    test('-352 → 抛限流异常', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(code: -352),
      });
      expect(
        () => _api(adapter).fetchUpownerVideos(1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -352)),
      );
    });
  });

  group('fetchUpownerInfo', () {
    test('解析 acc/info：name/face 补全/fans/sign', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/acc/info': () => _upownerInfoBody(
          name: '某UP主',
          face: '//i0.hdslb.com/bfs/face/info.jpg',
          fans: 1234567,
          sign: '这是简介',
        ),
      });
      final info = await _api(adapter).fetchUpownerInfo(100);
      expect(info.name, '某UP主');
      expect(info.face, 'https://i0.hdslb.com/bfs/face/info.jpg');
      expect(info.fans, 1234567);
      expect(info.sign, '这是简介');

      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/space/wbi/acc/info',
      );
      expect(req.queryParameters['mid'], '100');
      expect(req.queryParameters['w_rid'], isNotEmpty);
    });

    test('sign 缺省空串；face 已含 https: 不重复补全', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/acc/info': () => {
          'code': 0,
          'message': 'OK',
          'data': {
            'name': 'X',
            'face': 'https://i0.hdslb.com/face.jpg',
            'fans': 0,
          },
        },
      });
      final info = await _api(adapter).fetchUpownerInfo(1);
      expect(info.sign, '');
      expect(info.face, 'https://i0.hdslb.com/face.jpg');
      expect(info.fans, 0);
    });

    test('业务 code 非 0 → 抛 BiliApiException', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/acc/info': () => _upownerInfoBody(code: -404),
      });
      expect(
        () => _api(adapter).fetchUpownerInfo(1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -404)),
      );
    });

    test('-412 → 抛风控异常', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/acc/info': () => _upownerInfoBody(code: -412),
      });
      expect(
        () => _api(adapter).fetchUpownerInfo(1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -412)),
      );
    });

    test('请求带齐 wbi 签名 + buvid3/4 指纹 Cookie（防风控）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/acc/info': () => _upownerInfoBody(),
      });
      await _api(adapter).fetchUpownerInfo(100);
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/space/wbi/acc/info',
      );
      expect(req.queryParameters['mid'], '100');
      expect(req.queryParameters['w_rid'], isNotEmpty);
      expect(req.queryParameters['wts'], isNotEmpty);
      final cookie = req.headers['Cookie'] as String? ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('buvid4=buvid4test'));
    });

    test('2026-09 实测 acc/info data 不含 fans 字段 → fans=null（不崩）',
        () async {
      // 真实响应字段：name/face/sign/level_info/...，无 fans、无 card
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/acc/info': () => {
          'code': 0,
          'message': 'OK',
          'data': {
            'name': '某UP主',
            'face': 'https://i0.hdslb.com/bfs/face/x.jpg',
            'sign': '简介',
          },
        },
      });
      final info = await _api(adapter).fetchUpownerInfo(100);
      expect(info.name, '某UP主');
      expect(info.sign, '简介');
      expect(info.fans, isNull);
    });
  });

  group('fetchUpownerFollower', () {
    Map<String, dynamic> statBody({int code = 0, int? follower}) => {
      'code': code,
      'message': code == 0 ? 'OK' : '业务错误',
      'data': {'mid': 546195, 'following': 5, 'follower': follower ?? 20766601},
    };

    test('请求 vmid 参数 + buvid Cookie；解析 data.follower', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/relation/stat': () => statBody(follower: 20766601),
      });
      final api = _api(adapter);
      final fans = await api.fetchUpownerFollower(546195);
      expect(fans, 20766601);
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/relation/stat',
      );
      expect(req.queryParameters['vmid'], '546195');
      final cookie = req.headers['Cookie'] as String? ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('buvid4=buvid4test'));
    });

    test('data.follower 缺失 → 抛异常（不返回 null 猜测值）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/relation/stat': () => {'code': 0, 'message': 'OK', 'data': {}},
      });
      expect(
        () => _api(adapter).fetchUpownerFollower(1),
        throwsA(isA<BiliApiException>()),
      );
    });

    test('-412 / 其他业务码 → 抛 BiliApiException', () async {
      for (final code in [-412, -352, -404]) {
        final adapter = _RoutingAdapter({
          '/x/frontend/finger/spi': _spiBody,
          '/x/relation/stat': () => statBody(code: code),
        });
        expect(
          () => _api(adapter).fetchUpownerFollower(1),
          throwsA(
            isA<BiliApiException>().having((e) => e.code, 'code', code),
          ),
          reason: 'code=$code 应抛 BiliApiException',
        );
      }
    });

    test('网络连接失败 → 抛 DioException', () async {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).fetchUpownerFollower(1),
        throwsA(isA<DioException>()),
      );
    });
  });
}
