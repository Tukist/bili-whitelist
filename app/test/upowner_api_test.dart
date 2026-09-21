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

  /// path → **按顺序消费**的响应队列（队首优先，用完后回落 [handlers]）。
  ///
  /// 用来造「第 1 次失败、第 2 次成功」这种一次性响应（-412 自愈、取 key
  /// 失败后重新尝试等），只靠静态 handlers 造不出来。
  final Map<String, List<Map<String, dynamic> Function()>> queue;

  _RoutingAdapter(this.handlers, {Map<String, List<Map<String, dynamic> Function()>>? queue})
    : queue = queue ?? const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final pending = queue[options.path];
    if (pending != null && pending.isNotEmpty) {
      final next = pending.removeAt(0);
      return ResponseBody.fromString(
        jsonEncode(next()),
        200,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
      );
    }
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
  num? play = 999, // null = 响应里不带 play（测缺省）
}) => {
  'bvid': bvid,
  'title': title,
  'length': length,
  'author': author,
  'pic': pic,
  'mid': 100,
  'created': created,
  if (play != null) 'play': play,
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

/// `seasons_series_list` 响应（一条合集；合集接口不带 WBI 签名）。
Map<String, dynamic> _seasonsSeriesBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'items_lists': {
      'page': {'page_num': 1, 'page_size': 20, 'total': 1},
      'seasons_list': [
        {
          'meta': {
            'season_id': 1001,
            'name': '合集·A',
            'cover': '',
            'description': '',
            'total': 3,
          },
        },
      ],
      'series_list': <Map<String, dynamic>>[],
    },
  },
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

    // 播放量（v2.37.0，用户需求「视频卡片加播放量」）：vlist 里本来就有
    // `play`，但 _videoFromVlist 以前**拿到了却丢掉**，现在写进 view。
    test('vlist 的 play → view（播放量）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo(play: 123456)], count: 1),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos.first.view, 123456);
    });

    test('vlist 的 play = 0 → view = 0（真·零播放，不是「未知」）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo(play: 0)], count: 1),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos.first.view, 0);
    });

    test('vlist 缺 play / 脏值 → view = null（卡片不显示播放量这一段）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () =>
            _videoListBody(vlist: [_oneVideo(play: null)], count: 1),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos.first.view, isNull);
    });

    test('元数据接口的 duration/title/view 一起落到同一条上（不串字段）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(
          vlist: [
            _oneVideo(bvid: 'BV1', title: '视频一', length: '3:20', play: 10),
            _oneVideo(bvid: 'BV2', title: '视频二', length: '1:02:03', play: 20),
          ],
          count: 2,
        ),
      });
      final page = await _api(adapter).fetchUpownerVideos(1);
      expect(page.videos.map((v) => v.title).toList(), ['视频一', '视频二']);
      expect(page.videos.map((v) => v.duration).toList(), [200, 3723]);
      expect(page.videos.map((v) => v.view).toList(), [10, 20]);
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

  // -------------------------------------------------------------------------
  // v2.47.0：UP 主页首屏这条链的风控自愈 + spi/nav 在途去重
  // （用户报「进 UP 主页经常网络请求失败，重试几次才正常 / 粉丝数读不到」）
  // -------------------------------------------------------------------------

  group('UP 主页风控自愈（-412 刷 WBI key 重签重试）', () {
    test('fetchUpownerVideos 首次 -412 → 刷 key 重签重试后成功（不再直接抛）',
        () async {
      final adapter = _RoutingAdapter(
        {
          '/x/frontend/finger/spi': _spiBody,
          '/x/web-interface/nav': _navBody,
          '/x/space/wbi/arc/search': () =>
              _videoListBody(vlist: [_oneVideo(bvid: 'BVok')]),
        },
        queue: {
          // 第一次 arc/search 回 -412（key 过期），之后回落正常响应
          '/x/space/wbi/arc/search': [() => _videoListBody(code: -412)],
        },
      );
      final page = await _api(adapter).fetchUpownerVideos(100);

      expect(page.videos.single.bvid, 'BVok', reason: '-412 应自愈成成功');
      expect(
        adapter.requests.where((r) => r.path == '/x/space/wbi/arc/search').length,
        2,
        reason: '首次 -412 → 重签重试一次（共 2 次请求）',
      );
      expect(
        adapter.requests.where((r) => r.path == '/x/web-interface/nav').length,
        2,
        reason: '刷新 WBI key = 再取一次 nav（首次那份 key 已过期）',
      );
    });

    test('fetchUpownerVideos 刷 key 后仍 -412 → 抛风控文案（分类不退化）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(code: -412),
      });
      await expectLater(
        _api(adapter).fetchUpownerVideos(100),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -412)
              .having((e) => e.message, 'message', contains('风控')),
        ),
      );
      expect(
        adapter.requests.where((r) => r.path == '/x/space/wbi/arc/search').length,
        2,
        reason: '重试一次后仍 -412 才抛（不是一上来就抛）',
      );
    });

    test('fetchUpownerInfo 首次 -412 → 刷 key 重签重试后成功', () async {
      final adapter = _RoutingAdapter(
        {
          '/x/frontend/finger/spi': _spiBody,
          '/x/web-interface/nav': _navBody,
          '/x/space/wbi/acc/info': () => _upownerInfoBody(name: '自愈成功'),
        },
        queue: {
          '/x/space/wbi/acc/info': [() => _upownerInfoBody(code: -412)],
        },
      );
      final info = await _api(adapter).fetchUpownerInfo(100);
      expect(info.name, '自愈成功');
      expect(
        adapter.requests.where((r) => r.path == '/x/space/wbi/acc/info').length,
        2,
      );
    });

    test('fetchUpownerFollower 首次 -412 → 短退避重试后成功（本接口无 WBI 签名，'
        '不刷 key）', () async {
      final adapter = _RoutingAdapter(
        {
          '/x/frontend/finger/spi': _spiBody,
          '/x/relation/stat': () => {
            'code': 0,
            'message': 'OK',
            'data': {'mid': 546195, 'follower': 20766601},
          },
        },
        queue: {
          '/x/relation/stat': [
            () => {'code': -412, 'message': '风控校验失败', 'data': {}},
          ],
        },
      );
      final fans = await _api(adapter).fetchUpownerFollower(546195);
      expect(fans, 20766601, reason: '-412 应退避重试后自愈');
      expect(
        adapter.requests.where((r) => r.path == '/x/relation/stat').length,
        2,
        reason: '退避重试一次（共 2 次请求）',
      );
      expect(
        adapter.requests.where((r) => r.path == '/x/web-interface/nav').length,
        0,
        reason: 'relation/stat 不带 WBI 签名 → 不该为了它去刷 key（无谓请求）',
      );
    });

    test('fetchUpownerFollower 一直 -412 → 重试后仍抛风控文案（不吞错）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/relation/stat': () =>
            {'code': -412, 'message': '风控校验失败', 'data': {}},
      });
      await expectLater(
        _api(adapter).fetchUpownerFollower(1),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -412)
              .having((e) => e.message, 'message', contains('风控')),
        ),
      );
      expect(
        adapter.requests.where((r) => r.path == '/x/relation/stat').length,
        2,
        reason: '只多试 1 次（重试本身也计入频率，不能堆量）',
      );
    });

    test('fetchUpownerCollections 首次 -412 → 短退避重试后成功（无 WBI 签名）',
        () async {
      final adapter = _RoutingAdapter(
        {
          '/x/frontend/finger/spi': _spiBody,
          '/x/polymer/web-space/seasons_series_list': () =>
              _seasonsSeriesBody(),
        },
        queue: {
          '/x/polymer/web-space/seasons_series_list': [
            () => {'code': -412, 'message': '风控校验失败', 'data': {}},
          ],
        },
      );
      final r = await _api(adapter).fetchUpownerCollections(1);
      expect(r.seasons.single.id, 1001);
      expect(
        adapter.requests
            .where((r) => r.path == '/x/polymer/web-space/seasons_series_list')
            .length,
        2,
      );
      expect(
        adapter.requests.where((r) => r.path == '/x/web-interface/nav').length,
        0,
        reason: '合集接口无签名 → 不刷 key，只退避重发',
      );
    });
  });

  group('spi / nav 在途请求去重（一次进页各只打 1 次）', () {
    test('并发两条链（视频 + 详情）→ spi 与 nav 各只请求 1 次', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(vlist: [_oneVideo()]),
        '/x/space/wbi/acc/info': () => _upownerInfoBody(),
      });
      final api = _api(adapter);
      // 与页面 initState 同款：几条链同时起跑
      final results = await Future.wait([
        api.fetchUpownerVideos(100),
        api.fetchUpownerInfo(100),
      ]);
      expect(results, hasLength(2));

      int count(String path) =>
          adapter.requests.where((r) => r.path == path).length;
      expect(count('/x/frontend/finger/spi'), 1,
          reason: '进页瞬间多条链共用同一次 spi（以前是 2~3 次）');
      expect(count('/x/web-interface/nav'), 1,
          reason: '进页瞬间多条链共用同一次 nav（以前是 2 次）');
    });

    test('nav 三次并发（视频/详情/合集）也只打 1 次 nav', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/space/wbi/arc/search': () => _videoListBody(vlist: [_oneVideo()]),
        '/x/space/wbi/acc/info': () => _upownerInfoBody(),
        '/x/polymer/web-space/seasons_series_list': () => _seasonsSeriesBody(),
      });
      final api = _api(adapter);
      await Future.wait([
        api.fetchUpownerVideos(100),
        api.fetchUpownerInfo(100),
        api.fetchUpownerCollections(100),
      ]);
      expect(
        adapter.requests.where((r) => r.path == '/x/web-interface/nav').length,
        1,
      );
      expect(
        adapter.requests.where((r) => r.path == '/x/frontend/finger/spi').length,
        1,
      );
    });

    test('nav 没给 wbi_img → 抛 WbiKeyUnavailableException（仍可当 DioException '
        '捕获，老分支不破）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': () => {'code': -101, 'data': {}},
        '/x/space/wbi/acc/info': () => _upownerInfoBody(),
      });
      Object? caught;
      try {
        await _api(adapter).fetchUpownerInfo(100);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<WbiKeyUnavailableException>());
      expect(caught, isA<DioException>(),
          reason: '继承 DioException：既有 on DioException 兜底分支行为不变');
    });

    test('nav 失败不缓存：下一次调用会重新取 key（第 2 次拿到就成功）',
        () async {
      final adapter = _RoutingAdapter(
        {
          '/x/frontend/finger/spi': _spiBody,
          '/x/web-interface/nav': _navBody,
          '/x/space/wbi/acc/info': () => _upownerInfoBody(name: '第二次成功'),
        },
        queue: {
          // 第一次 nav 服务端风控降级：JSON 里没有 wbi_img
          '/x/web-interface/nav': [() => {'code': -101, 'data': {}}],
        },
      );
      final api = _api(adapter);
      await expectLater(
        api.fetchUpownerInfo(100),
        throwsA(isA<WbiKeyUnavailableException>()),
      );
      final info = await api.fetchUpownerInfo(100);
      expect(info.name, '第二次成功', reason: '失败的 nav 不该被当成「已缓存」');
      expect(
        adapter.requests.where((r) => r.path == '/x/web-interface/nav').length,
        2,
      );
    });

    test('spi 失败不缓存：下一次调用会重新取指纹，成功后请求带上 buvid Cookie',
        () async {
      final adapter = _RoutingAdapter(
        {
          '/x/frontend/finger/spi': _spiBody,
          '/x/relation/stat': () => {
            'code': 0,
            'message': 'OK',
            'data': {'mid': 1, 'follower': 7},
          },
        },
        queue: {
          // 第一次 spi 直接 404（拿不到指纹）
          '/x/frontend/finger/spi': [
            () => {'code': -1, 'message': 'spi 挂了'},
          ],
        },
      );
      final api = _api(adapter);
      await api.fetchUpownerFollower(1);
      await api.fetchUpownerFollower(1);
      expect(
        adapter.requests.where((r) => r.path == '/x/frontend/finger/spi').length,
        2,
        reason: '指纹失败不缓存 → 第二次调用重新尝试',
      );
      final last =
          adapter.requests.lastWhere((r) => r.path == '/x/relation/stat');
      expect(last.headers['Cookie'], contains('buvid3=buvid3test'));
    });
  });
}
