// BiliApi.fetchFollowingsOfMine（x/relation/followings）单元测试（v2.17.12+）：
// - 登录门禁：无 SESSDATA → 抛 -101「请先登录」（不发请求）
// - nav 拿自己 mid（会话缓存：多次 fetch 只发一次 nav）→ vmid/pn/ps 参数
// - 解析：data.list[]（mid/uname/face，face // 补协议头）；缺 mid 脏条目过滤；
//   total 数字串兼容；list 缺失/非 List → 空页
// - 分页 hasMore：total 在场按 pn*ps < total；total 缺失按装满一页兜底
// - 错误分类：nav/followings code=-101（登录已失效）/-412/-352/其他业务码 →
//   BiliApiException；网络失败 → DioException 原样上抛
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

/// nav 响应：登录态（data.mid = 真实 mid）。
Map<String, dynamic> _navBody({int code = 0, int mid = 123456}) => {
      'code': code,
      'message': code == 0 ? 'success' : '错误',
      if (code == 0)
        'data': {
          'isLogin': mid > 0,
          'mid': mid,
          'wbi_img': {
            'img_url':
                'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
            'sub_url':
                'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
          },
        },
    };

/// followings 响应（data.list[] + data.total）。
Map<String, dynamic> _followingsBody({
  int code = 0,
  Object? total = 3,
  List<Map<String, dynamic>>? list,
}) =>
    {
      'code': code,
      'message': code == 0 ? 'success' : '业务错误',
      if (code == 0)
        'data': {
          if (total != null) 'total': total,
          if (list != null) 'list': list,
        },
    };

Map<String, dynamic> _up(int mid, {String? face}) => {
      'mid': mid,
      'uname': 'UP$mid',
      'face': face ?? '//i0.hdslb.com/bfs/face/$mid.jpg',
      'attribute': 6,
      'mtime': 1700000000,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    // 默认登录态（部分测试显式删除/不依赖）
    _store['bili_sessdata'] = 'sess_test';
  });

  group('fetchFollowingsOfMine', () {
    test('无 SESSDATA → 抛 -101「请先登录」，不发请求', () async {
      _store.remove('bili_sessdata'); // 未登录
      final adapter = _RoutingAdapter({
        '/x/relation/followings': () => _followingsBody(list: [_up(1)]),
      });
      final api = _api(adapter);
      await expectLater(
        api.fetchFollowingsOfMine(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('请先登录'))),
      );
      expect(adapter.requests, isEmpty);
    });

    test('登录态：nav 拿 mid（缓存）→ followings 带 vmid/pn/ps', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () =>
            _followingsBody(total: 0, list: [_up(1)]),
      });
      final api = _api(adapter);

      final page1 = await api.fetchFollowingsOfMine(pn: 1, ps: 20);
      expect(page1.upowners.single.mid, 1);
      // 第二次翻页：mid 会话缓存，不再发 nav
      await api.fetchFollowingsOfMine(pn: 2, ps: 20);

      final navCount = adapter.requests
          .where((r) => r.path == '/x/web-interface/nav')
          .length;
      expect(navCount, 1, reason: 'nav 应只发一次（mid 缓存）');

      final foll = adapter.requests
          .where((r) => r.path == '/x/relation/followings')
          .toList();
      expect(foll.length, 2);
      expect(foll[0].queryParameters['vmid'], '777');
      expect(foll[0].queryParameters['pn'], '1');
      expect(foll[0].queryParameters['ps'], '20');
      expect(foll[1].queryParameters['pn'], '2');
    });

    test('解析：face 补 https、数字串 total、脏条目（缺 mid）过滤', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () => _followingsBody(
              total: '4', // 服务端历史上 total 可能是字符串
              list: [
                _up(1001),
                {
                  'mid': 1002,
                  'uname': 'UP1002',
                  'face': 'https://i1.hdslb.com/bfs/face/1002.jpg',
                },
                {'uname': '无mid', 'face': ''}, // 缺 mid → 脏条目
                {'mid': 0, 'uname': 'mid为0', 'face': ''}, // mid=0 → 脏条目
                {'mid': 1003}, // 缺 uname/face：face 空串容忍
              ],
            ),
      });
      final api = _api(adapter);
      final page = await api.fetchFollowingsOfMine();

      expect(page.totalCount, 4);
      expect(page.upowners.length, 3);
      final u1001 = page.upowners.firstWhere((u) => u.mid == 1001);
      expect(u1001.name, 'UP1001');
      expect(u1001.face, 'https://i0.hdslb.com/bfs/face/1001.jpg'); // // → https:
      final u1002 = page.upowners.firstWhere((u) => u.mid == 1002);
      expect(u1002.face, 'https://i1.hdslb.com/bfs/face/1002.jpg'); // 原样保留
    });

    test('分页 hasMore：total 在场按 pn*ps<total；装不满/无更多为 false', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () => _followingsBody(
              total: 45,
              list: [for (var i = 1; i <= 20; i++) _up(1000 + i)],
            ),
      });
      final api = _api(adapter);
      final page = await api.fetchFollowingsOfMine(pn: 1, ps: 20);
      expect(page.upowners.length, 20);
      expect(page.hasMore, isTrue); // 20 < 45
    });

    test('mid 数字串容错（v2.17.13 修复：整批字符串 mid 不再被当脏数据丢弃）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () => _followingsBody(
              total: 2,
              list: [
                {'mid': '1001', 'uname': '串号UP', 'face': ''},
                {'mid': 'abc', 'uname': '非法串', 'face': ''}, // 非数字串 → 0 → 丢弃
              ],
            ),
      });
      final api = _api(adapter);
      final page = await api.fetchFollowingsOfMine();
      expect(page.totalCount, 2);
      expect(page.upowners.length, 1, reason: '数字串 mid 正常解析');
      expect(page.upowners.single.mid, 1001);
      expect(page.upowners.single.name, '串号UP');
    });

    test('total 缺失：装满一页 → hasMore=true；不满一页 → false', () async {
      final full = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () => _followingsBody(
              total: -1, // 接口未返回 total
              list: [for (var i = 1; i <= 20; i++) _up(2000 + i)],
            ),
      });
      final api = _api(full);
      final page = await api.fetchFollowingsOfMine();
      expect(page.totalCount, 0);
      expect(page.hasMore, isTrue); // 装满 20 → 兜底还有

      final partial = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () =>
            _followingsBody(total: -1, list: [_up(1), _up(2)]),
      });
      final api2 = _api(partial);
      final page2 = await api2.fetchFollowingsOfMine();
      expect(page2.upowners.length, 2);
      expect(page2.hasMore, isFalse);
    });

    test('data.list 缺失/非 List → 空页（不抛）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(mid: 777),
        '/x/relation/followings': () => {
              'code': 0,
              'message': 'success',
              'data': {'total': 3},
            },
      });
      final api = _api(adapter);
      final page = await api.fetchFollowingsOfMine();
      expect(page.upowners, isEmpty);
      expect(page.totalCount, 3);
      // total 在场（3）→ pn*ps = 20 已覆盖，无更多
      expect(page.hasMore, isFalse);
    });

    test('followings 业务错误分类：-101/-412/-352/其他', () async {
      for (final (code, msg, expectedMsg) in [
        (-101, '账号未登录', '登录已失效'),
        (-412, '风控', '风控'),
        (-352, '限流', '限流'),
        (-400, '参数错误', '参数错误'),
      ]) {
        final adapter = _RoutingAdapter({
          '/x/frontend/finger/spi': () => _spiBody(),
          '/x/web-interface/nav': () => _navBody(mid: 777),
          '/x/relation/followings': () =>
              {'code': code, 'message': msg},
        });
        final api = _api(adapter);
        await expectLater(
          api.fetchFollowingsOfMine(),
          throwsA(isA<BiliApiException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.message, 'message', contains(expectedMsg))),
          reason: 'code=$code',
        );
      }
    });

    test('nav code=-101（cookie 失效）→ 抛 -101「登录已失效」', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': () => _spiBody(),
        '/x/web-interface/nav': () => _navBody(code: -101),
        '/x/relation/followings': () => _followingsBody(list: [_up(1)]),
      });
      final api = _api(adapter);
      await expectLater(
        api.fetchFollowingsOfMine(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录已失效'))),
      );
    });

    test('网络失败 → DioException 原样上抛', () async {
      final api = _api(_ThrowingAdapter());
      await expectLater(api.fetchFollowingsOfMine(), throwsA(isA<DioException>()));
    });
  });
}
