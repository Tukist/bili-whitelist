// 收藏夹三级浏览入口 widget 测试（v2.17.7+）：
// - 首页固定「收藏夹」卡：空名单也显示；未登录点击 → 提示 + 引导登录（不进
//   总览页）；已登录点击 → push FavoritesPage
// - FavoritesPage（第二层）：登录门禁（无 SESSDATA → 去登录引导；list-all
//   -101 会话失效 → 去登录引导）；列表渲染（名称 + N 个视频）；空态；点收藏
//   夹 → FavoriteVideosPage（第三层）
// - FavoriteVideosPage（第三层）：列表渲染 + 上拉翻页（hasMore）；点视频 →
//   fetchVideoMeta 补全 → openPlayer 回调收到完整视频（不 push 真实播放页）；
//   失效条目（view 62002）→ snack 提示并跳过（不回调）；空态
// 不访问真实网络（BiliApi 注入路由 mock adapter）；不构建真实 LoginPage /
// PlayerPage（注入 openLogin / openPlayer 替身）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart'
    hide FavoriteVideosPage;
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/favorite_videos_page.dart';
import 'package:bili_whitelist_app/pages/favorites_page.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存版 secure storage。
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

class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 按 path 路由的 BiliApi mock adapter（记录全部请求；nav/list-all/
/// resource-list/view 由 handler 提供响应体）。
class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function(RequestOptions options)>
      handlers;
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
    return ResponseBody.fromString(
      jsonEncode(
        handler?.call(options) ??
            {'code': -1, 'message': 'no handler: ${options.path}'},
      ),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// nav 响应：code=0 登录态（带 mid 供 fetchMyFavorites 拿 up_mid；带 wbi_img
/// 供 view 接口的 WBI 签名）。
Map<String, dynamic> _navBody() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'isLogin': true,
        'mid': 123456,
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

/// 收藏夹列表响应。
Map<String, dynamic> _foldersBody(List<Map<String, dynamic>> list) => {
      'code': 0,
      'message': 'success',
      'data': {'list': list},
    };

Map<String, dynamic> _folder(int mediaId, String title, int count) => {
      'media_id': mediaId,
      'title': title,
      'media_count': count,
      'cover': '',
    };

/// 夹内视频页响应（medias + count + has_more）。
Map<String, dynamic> _favPageBody(
  List<Map<String, dynamic>> medias, {
  required bool hasMore,
}) =>
    {
      'code': 0,
      'message': 'success',
      'data': {
        'count': medias.length,
        'has_more': hasMore,
        'medias': medias,
      },
    };

Map<String, dynamic> _favMedia(String bvid, String title, {int duration = 300}) =>
    {
      'id': 1,
      'type': 2, // 视频
      'bvid': bvid,
      'cid': 1,
      'title': title,
      'cover': '',
      'upper': {'mid': 1, 'name': 'UP甲'},
      'duration': duration,
      'pubtime': 1589627926,
    };

/// view 接口 data（videoFromMeta 用字段）。
Map<String, dynamic> _viewData(String bvid) => {
      'bvid': bvid,
      'cid': 1001,
      'title': '详情$bvid',
      'pic': '',
      'duration': 300,
      'owner': {'mid': 1, 'name': 'UP甲'},
      'pages': [
        {'cid': 1001, 'part': 'P1', 'duration': 300},
      ],
      'pubdate': 1589627926,
      'desc': '简介$bvid',
    };

BiliApi _makeApi(_RoutingAdapter adapter) => BiliApi(
      dio: Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()))
        ..httpClientAdapter = adapter,
    );

/// 未失效会话（30 天后过期）写入存储。
void _seedValidSession() {
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    ServiceLocator.overrideSyncService(_FakeSyncService());
  });

  group('首页固定「收藏夹」卡', () {
    testWidgets('未登录：空名单也显示收藏夹卡；点击 → 提示 + 引导登录，不进总览',
        (tester) async {
      var loginCalls = 0;
      Future<void> openLoginSpy(BuildContext context, {String? banner}) async {
        loginCalls++;
      }

      await tester.pumpWidget(
        MaterialApp(home: PlaylistPage(openLogin: openLoginSpy)),
      );
      await tester.pump(); // 启动自动登录：无会话 → 引导（替身记录一次）
      await tester.pump();

      // 固定「收藏夹」卡：图标标题 + 副标（即使白名单为空也显示）
      expect(find.text('收藏夹'), findsOneWidget);
      expect(find.text('我的 B 站收藏'), findsOneWidget);

      // 点击 → 未登录：snack 提示需登录 + 引导登录；不进收藏夹总览页
      await tester.tap(find.text('收藏夹'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('收藏夹浏览需要登录 B 站账号（收藏夹属于个人账号数据）'),
          findsOneWidget);
      expect(loginCalls, greaterThanOrEqualTo(2)); // 启动自动引导 1 次 + 本次 1 次
      expect(find.byType(FavoritesPage), findsNothing);
    });

    testWidgets('已登录：点击收藏夹卡 → push 收藏夹总览页', (tester) async {
      _seedValidSession(); // 已登录 → 启动静默恢复，不引导
      var loginCalls = 0;
      Future<void> openLoginSpy(BuildContext context, {String? banner}) async {
        loginCalls++;
      }

      await tester.pumpWidget(
        MaterialApp(home: PlaylistPage(openLogin: openLoginSpy)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('收藏夹'), findsOneWidget);

      await tester.tap(find.text('收藏夹'));
      await tester.pump(); // 进总览页（无 SESSDATA 门禁拦不住 → push）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(FavoritesPage), findsOneWidget);
      expect(loginCalls, 0); // 已登录：无需引导登录
    });
  });

  group('FavoritesPage（收藏夹总览）', () {
    testWidgets('渲染我的收藏夹：名称 + N 个视频', (tester) async {
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/folder/created/list-all': (_) => _foldersBody([
              _folder(111, '我的测试夹', 2),
              _folder(222, '默认收藏夹', 5),
            ]),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoritesPage(
            api: _makeApi(adapter),
            openLogin: (context, {banner}) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('我的测试夹'), findsOneWidget);
      expect(find.text('默认收藏夹'), findsOneWidget);
      expect(find.text('2 个视频'), findsOneWidget);
      expect(find.text('5 个视频'), findsOneWidget);
      // 请求带了自己的 mid（nav 拿）
      final req = adapter.requests.firstWhere(
          (r) => r.path == '/x/v3/fav/folder/created/list-all');
      expect((req.queryParameters['up_mid'] as String?), '123456');
    });

    testWidgets('无 SESSDATA → 去登录引导；点「去登录」调登录替身（保持匿名则留在引导）',
        (tester) async {
      var loginCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: FavoritesPage(
            api: _makeApi(_RoutingAdapter({})),
            openLogin: (context, {banner}) async => loginCalls++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏夹属于个人账号数据，需先登录 B 站账号'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);

      await tester.tap(find.text('去登录'));
      await tester.pumpAndSettle();
      expect(loginCalls, 1);
      // 登录替身未真的登录 → 仍停留在去登录引导
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('会话失效（list-all 返回 -101）→ 去登录引导', (tester) async {
      // 有 SESSDATA 但已失效
      _store['bili_sessdata'] = '12345,1700000000,${'b' * 32}';
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/folder/created/list-all': (_) => {
              'code': -101,
              'message': '登录已失效，请重新登录',
            },
      });
      await tester.pumpWidget(
        MaterialApp(home: FavoritesPage(api: _makeApi(adapter))),
      );
      await tester.pumpAndSettle();
      expect(find.text('登录已失效，请重新登录后继续浏览收藏夹'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('收藏夹为空 → 空态文案', (tester) async {
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/folder/created/list-all': (_) => _foldersBody([]),
      });
      await tester.pumpWidget(
        MaterialApp(home: FavoritesPage(api: _makeApi(adapter))),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有收藏夹'), findsOneWidget);
    });

    testWidgets('点某收藏夹 → 夹内视频页；点视频 → view 补全 → 播放回调；'
        '失效条目 62002 → 提示跳过不回调', (tester) async {
      _seedValidSession();
      final played = <WhitelistVideo>[];
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/folder/created/list-all': (_) => _foldersBody([
              _folder(111, '收藏夹A', 2),
            ]),
        '/x/v3/fav/resource/list': (_) => _favPageBody(
              [
                _favMedia('BV-A', '收藏视频A'),
                _favMedia('BV-B', '收藏视频B'),
              ],
              hasMore: false,
            ),
        '/x/web-interface/view': (o) {
          final bvid = o.queryParameters['bvid'] as String? ?? '';
          if (bvid == 'BV-B') {
            return {
              'code': 62002, // 稿件已失效
              'message': '稿件已失效',
            };
          }
          return {'code': 0, 'data': _viewData(bvid)};
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoritesPage(
            api: _makeApi(adapter),
            openLogin: (context, {banner}) async {},
            openPlayer: (context, video) async => played.add(video),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 第一层卡片 → 点收藏夹 → 第三层视频列表
      await tester.tap(find.text('收藏夹A'));
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteVideosPage), findsOneWidget);
      expect(find.text('收藏视频A'), findsOneWidget);
      expect(find.text('收藏视频B'), findsOneWidget);

      // 点正常视频 → fetchVideoMeta 补全 → 播放回调（收到完整 video，未真推播放页）
      await tester.tap(find.text('收藏视频A'));
      await tester.pumpAndSettle();
      expect(played, hasLength(1));
      final video = played.single;
      expect(video.bvid, 'BV-A');
      expect(video.cid, 1001); // view 补齐
      expect(video.title, '详情BV-A');
      expect(video.desc, '简介BV-A');
      expect(find.byType(FavoriteVideosPage), findsOneWidget); // 仍在列表页
      expect(find.text('详情BV-A'), findsNothing);

      // 点失效视频 → snack 提示跳过，不触发播放回调
      await tester.tap(find.text('收藏视频B'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('该视频已失效或不可播放（62002），已跳过'), findsOneWidget);
      expect(played, hasLength(1));
    });
  });

  group('FavoriteVideosPage（夹内视频）', () {
    testWidgets('分页：滚到底自动加载下一页（hasMore）→ 追加 + 「没有更多了」',
        (tester) async {
      _seedValidSession();
      final page1 = [
        for (var i = 1; i <= 20; i++) _favMedia('BV-p1-$i', '收藏视频第$i页1'),
      ];
      final page2 = [_favMedia('BV-p2-21', '收藏视频第21页2')];
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (o) {
          final pn = int.tryParse(o.queryParameters['pn'] as String? ?? '1') ??
              1;
          return pn == 1
              ? _favPageBody(page1, hasMore: true)
              : _favPageBody(page2, hasMore: false);
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '分页夹',
            api: _makeApi(adapter),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏视频第1页1'), findsOneWidget);

      // 滚到底（内容超一屏 → 触发上拉加载）
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pumpAndSettle();

      final pages = adapter.requests
          .where((r) => r.path == '/x/v3/fav/resource/list')
          .toList();
      expect(pages.length, 2); // 第二页已请求
      expect(pages.last.queryParameters['pn'], '2');
      expect(find.text('收藏视频第21页2'), findsOneWidget);
      // 再滚一段让尾部占位进入视口（hasMore=false → 「没有更多了」）
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('没有更多了'), findsOneWidget);
    });

    testWidgets('夹内没有视频 → 空态（注明非视频内容不展示）', (tester) async {
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (_) => _favPageBody([], hasMore: false),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '空夹',
            api: _makeApi(adapter),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('这个收藏夹还没有视频'), findsOneWidget);
    });
  });
}
