// BiliApi 收藏夹接口单元测试（mock dio，v2.17.5+）：
// - fetchMyFavorites：登录门禁（无 SESSDATA → -101「请先登录」）、nav 拿 mid
//   （缓存）、list-all 请求参数（up_mid/pn/ps）与解析（media_id 兜底 id、
//   脏条目过滤）、错误分类（-101/-412/其他业务码/网络）
// - fetchFavoriteVideos：media_id/pn/ps/platform 参数、medias[] 解析
//   （type=2 过滤/封面协议相对/时间解析）、has_more/count 分页、错误分类
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
            'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
            'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
          },
        },
    };

/// list-all 响应（data.list[]，与 bilibili-API-collect 实测结构一致）。
Map<String, dynamic> _folderListBody({int code = 0, bool withList = true}) => {
      'code': code,
      'message': code == 0 ? 'success' : '业务错误',
      if (code == 0 && withList)
        'data': {
          'list': [
            {
              'media_id': 2670055339, // 部分时期字段为 media_id
              'fid': 2670055339,
              'title': '默认收藏夹',
              'media_count': 3,
              'cover': '//i0.hdslb.com/bfs/favicon/xxx.jpg',
            },
            {
              // 兜底字段：只有 id（无 media_id 时按 id 解析）
              'id': 42,
              'fid': 42,
              'title': '自建夹',
              'media_count': '12', // 数字串容错
              'cover': '',
            },
            {
              // 脏条目：缺 media_id/id + 空标题 → 过滤
              'fid': 999,
              'title': '',
              'media_count': 1,
            },
          ],
        },
    };

/// resource/list 响应（data.medias[]，bilibili-API-collect 实测结构）。
Map<String, dynamic> _mediaPageBody({
  int code = 0,
  bool hasMore = false,
  int count = 2,
  bool withMedias = true,
}) => {
      'code': code,
      'message': code == 0 ? 'success' : '业务错误',
      if (code == 0)
        'data': {
          'info': {'id': 2670055339},
          'count': count,
          'has_more': hasMore,
          if (withMedias)
            'medias': [
              {
                'id': 501,
                'type': 2,
                'bvid': 'BV1qF411q79g',
                'cid': 501,
                'title': '收藏视频一',
                'cover': '//i0.hdslb.com/bfs/archive/a.jpg',
                'upper': {'mid': 7, 'name': 'UP甲'},
                'duration': 138, // 秒
                'pubtime': 1589627926,
              },
              {
                // 非视频（音频/专栏等 type≠2）→ 过滤
                'id': 502,
                'type': 1,
                'bvid': 'BV1audio',
                'title': '音频条目',
                'cover': '',
                'upper': {'mid': 7, 'name': 'UP甲'},
                'duration': 60,
                'pubtime': 0,
              },
              {
                // 无 type 字段：按视频处理（脏/旧响应兼容）
                'id': 503,
                'bvid': 'BV1notype',
                'title': '无 type 视频',
                'cover': '',
                'duration': 30,
                'pubtime': 1600000000,
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

  group('fetchMyFavorites', () {
    test('无 SESSDATA → BiliApiException(-101) 请先登录（不发任何请求）',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': _folderListBody,
      });
      await expectLater(
        _api(adapter).fetchMyFavorites(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('请先登录'))),
      );
      // 登录门禁在发请求前拦截
      expect(adapter.requests, isEmpty);
    });

    test('已登录：nav 拿 mid + list-all 参数（up_mid/pn/ps）+ Cookie 注入',
        () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': _folderListBody,
      });
      final folders = await _api(adapter).fetchMyFavorites();

      final navReq = adapter.requests
          .firstWhere((r) => r.path == '/x/web-interface/nav');
      expect(navReq.headers['Cookie'], contains('SESSDATA=sess_test'));

      final listReq = adapter.requests
          .firstWhere((r) => r.path == '/x/v3/fav/folder/created/list-all');
      expect(listReq.queryParameters['up_mid'], '123456'); // nav data.mid
      expect(listReq.queryParameters['pn'], '1');
      expect(listReq.queryParameters['ps'], '20');
      expect(listReq.headers['Cookie'], contains('SESSDATA=sess_test'));

      // 解析：2 个有效夹（脏条目过滤）；id 兜底；数字串容错；封面补 https
      expect(folders, hasLength(2));
      final fav = folders[0];
      expect(fav.mediaId, 2670055339);
      expect(fav.title, '默认收藏夹');
      expect(fav.mediaCount, 3);
      expect(fav.cover, 'https://i0.hdslb.com/bfs/favicon/xxx.jpg');
      expect(folders[1].mediaId, 42);
      expect(folders[1].mediaCount, 12);
    });

    test('list-all 返回空列表 / data 缺失 → 空列表', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': () => {
              'code': 0,
              'message': 'success',
              'data': {'list': []},
            },
      });
      expect(await _api(adapter).fetchMyFavorites(), isEmpty);

      final adapter2 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': () => {
              'code': 0,
              'message': 'success',
            },
      });
      expect(await _api(adapter2).fetchMyFavorites(), isEmpty);
    });

    test('nav code=-101（cookie 失效）→ BiliApiException(-101) 登录已失效',
        () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': () => _navBody(code: -101),
      });
      await expectLater(
        _api(adapter).fetchMyFavorites(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录已失效'))),
      );
    });

    test('nav 返回 data.mid=0（匿名态）→ 视为 -101 未登录', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': () => _navBody(code: 0, mid: 0),
      });
      await expectLater(
        _api(adapter).fetchMyFavorites(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录已失效'))),
      );
    });

    test('list-all code=-101 / -412 → 分类提示', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': () => _folderListBody(code: -101),
      });
      await expectLater(
        _api(adapter).fetchMyFavorites(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录已失效'))),
      );

      final adapter412 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': () => _folderListBody(code: -412),
      });
      await expectLater(
        _api(adapter412).fetchMyFavorites(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', contains('风控'))),
      );
    });

    test('list-all 其他业务码 → 带接口 message', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/v3/fav/folder/created/list-all': () => {
              'code': -400,
              'message': '参数错误',
            },
      });
      await expectLater(
        _api(adapter).fetchMyFavorites(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -400)
            .having((e) => e.message, 'message', '参数错误')),
      );
    });

    test('网络连接失败 → 抛 DioException', () {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      _store['bili_sessdata'] = 'sess_test';
      expect(
        () => BiliApi(dio: dio).fetchMyFavorites(),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('fetchFavoriteVideos', () {
    test('请求参数（media_id/pn/ps/platform）+ 解析 + Cookie 注入', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v3/fav/resource/list': () =>
            _mediaPageBody(hasMore: true, count: 3),
      });
      final page =
          await _api(adapter).fetchFavoriteVideos(2670055339, pn: 1, ps: 20);

      final req = adapter.requests
          .firstWhere((r) => r.path == '/x/v3/fav/resource/list');
      expect(req.queryParameters['media_id'], '2670055339');
      expect(req.queryParameters['pn'], '1');
      expect(req.queryParameters['ps'], '20');
      expect(req.queryParameters['platform'], 'web');
      expect(req.headers['Cookie'], contains('SESSDATA=sess_test'));

      // type=2 与无 type 保留，type=1（音频等）过滤 → 2 条
      expect(page.videos, hasLength(2));
      final v = page.videos[0];
      expect(v.bvid, 'BV1qF411q79g');
      expect(v.title, '收藏视频一');
      expect(v.cover, 'https://i0.hdslb.com/bfs/archive/a.jpg'); // // → https
      expect(v.duration, 138);
      expect(v.pubdate, 1589627926); // pubtime → pubdate
      expect(v.upName, 'UP甲');
      expect(page.totalCount, 3);
      expect(page.hasMore, isTrue);
    });

    test('medias 缺失/空 → 空页（has_more 原样透传）', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v3/fav/resource/list': () =>
            _mediaPageBody(withMedias: false, count: 0),
      });
      final page = await _api(adapter).fetchFavoriteVideos(1);
      expect(page.videos, isEmpty);
      expect(page.hasMore, isFalse);
      expect(page.totalCount, 0);
    });

    test('code=-101 / -412 → 分类提示', () async {
      _store['bili_sessdata'] = 'sess_test';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v3/fav/resource/list': () => _mediaPageBody(code: -101),
      });
      await expectLater(
        _api(adapter).fetchFavoriteVideos(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录已失效'))),
      );

      final adapter412 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/v3/fav/resource/list': () => _mediaPageBody(code: -412),
      });
      await expectLater(
        _api(adapter412).fetchFavoriteVideos(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', contains('风控'))),
      );
    });

    test('网络连接失败 → 抛 DioException', () {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).fetchFavoriteVideos(1),
        throwsA(isA<DioException>()),
      );
    });
  });
}
