// 历史 / 收藏族页面的「列表项交错入场 + 整页加载态」测试
// （块化与动效系统：history_page / daily_history_page / favorites_page /
//  favorite_videos_page）：
// - 关动效（`flutter test` 环境默认）：条目仍包在 [StaggeredEntrance] 里，
//   但树里**没有** FadeTransition 飞行层 —— 既有形态 / 命中测试不变
// - 开动效（显式 `MotionControl.enabled = true`）：首屏条目逐项推入（动画期
//   有飞行层），`pumpAndSettle` 后包裹层卸载；已记账的条目被回收重建时不重播
// - 整页加载态已换成 [AppLoadingHero]（SmokeSilhouette 剪影），不再是裸转圈
// - `RefreshIndicator` 宿主页（收藏夹总览 / 夹内视频）在加载态下**仍能下拉刷新**
//   （AppLoadingHero 传了 `scrollable: true`，加载态也有可滚动区域）
// - 历史卡的间距改为 kListGap（12）
//
// 接口走注入的路由 mock adapter（不触网）；用 [Completer] 当"闸门"把页面钉在
// 加载态，避免依赖"微任务跑多快"的不确定时序。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart'
    hide FavoriteVideosPage;
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/daily_history_page.dart';
import 'package:bili_whitelist_app/pages/favorite_videos_page.dart';
import 'package:bili_whitelist_app/pages/favorites_page.dart';
import 'package:bili_whitelist_app/pages/history_page.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/smoke_silhouette.dart';
import 'package:bili_whitelist_app/widgets/staggered_entrance.dart';

// ---------------------------------------------------------------------------
// 测试替身：secure storage / 路由 mock adapter
// ---------------------------------------------------------------------------

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

/// 未失效会话（30 天后过期）写入存储。
void _seedValidSession() {
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
}

/// 按 path 路由的 mock adapter；[gate] 非空时每个响应先挂在那条 Future 上
/// （把页面钉在"加载中"，直到测试方 complete），不依赖真实时序。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.handlers, {this.gate});

  final Map<String, Map<String, dynamic> Function(RequestOptions options)>
      handlers;
  final List<RequestOptions> requests = [];
  final Future<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final g = gate;
    if (g != null) await g;
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

BiliApi _makeApi(_RoutingAdapter adapter) => BiliApi(
      dio: Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()))
        ..httpClientAdapter = adapter,
    );

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

Map<String, dynamic> _favMedia(String bvid, String title) => {
      'id': 1,
      'type': 2, // 视频
      'bvid': bvid,
      'cid': 1,
      'title': title,
      'cover': '',
      'upper': {'mid': 1, 'name': 'UP甲'},
      'duration': 300,
      'pubtime': 1589627926,
    };

// ---------------------------------------------------------------------------
// 断言辅助
// ---------------------------------------------------------------------------

/// 交错入场的"飞行层"（包裹在 [StaggeredEntrance] 内部的 FadeTransition）。
Finder get _flyingLayers => find.descendant(
      of: find.byType(StaggeredEntrance),
      matching: find.byType(FadeTransition),
    );

HistoryEntry _entry(
  String bvid,
  int pageIndex,
  DateTime watchedAt, {
  String title = '标题',
}) =>
    HistoryEntry(
      bvid: bvid,
      pageIndex: pageIndex,
      cid: 100,
      title: title,
      cover: '',
      upName: 'UP主',
      durationMs: 120000,
      positionMs: 30000,
      watchedAt: watchedAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    MotionControl.reset(); // 每条用例从环境默认（测试环境 = false）出发
  });
  tearDown(MotionControl.reset);

  group('交错入场：关动效形态不变', () {
    testWidgets('历史页：条目包在 StaggeredEntrance 里、无飞行层，间距 = kListGap',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = HistoryStore.instance;
      await store.addOrUpdate(_entry('BV1a', 0, DateTime.now(), title: '视频甲'));
      await store.addOrUpdate(_entry('BV2b', 1, DateTime.now(), title: '视频乙'));

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HistoryPage())),
      );
      await tester.pump(); // reload 完成

      expect(find.byType(StaggeredListScope), findsOneWidget);
      expect(find.byType(StaggeredEntrance), findsNWidgets(2));
      // 关动效 → 直接是 child：树里没有飞行层（命中测试/形态与改造前一致）
      expect(_flyingLayers, findsNothing);
      // 历史卡自带 1px 描边 → 分隔间距用 kListGap（12），不再是被挤住的 8
      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.height == kListGap),
        findsOneWidget,
      );
    });

    testWidgets('该日历史页：条目包在 StaggeredEntrance 里、无飞行层，间距 = kListGap',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final day = DateTime.now();
      final store = HistoryStore.instance;
      await store.addOrUpdate(_entry('BV1a', 0, day, title: '今天甲'));
      await store.addOrUpdate(_entry('BV2b', 0, day, title: '今天乙'));

      await tester.pumpWidget(MaterialApp(home: DailyHistoryPage(date: day)));
      await tester.pumpAndSettle();

      expect(find.byType(StaggeredEntrance), findsNWidgets(2));
      expect(_flyingLayers, findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.height == kListGap),
        findsOneWidget,
      );
    });
  });

  group('交错入场：开动效', () {
    testWidgets('该日历史页：首屏条目逐项推入 → settle 后飞行层卸载',
        (tester) async {
      MotionControl.enabled = true;
      SharedPreferences.setMockInitialValues({});
      final day = DateTime.now();
      final store = HistoryStore.instance;
      await store.addOrUpdate(_entry('BV1', 0, day, title: '甲'));
      await store.addOrUpdate(_entry('BV2', 0, day, title: '乙'));
      await store.addOrUpdate(_entry('BV3', 0, day, title: '丙'));

      await tester.pumpWidget(MaterialApp(home: DailyHistoryPage(date: day)));
      await tester.pump(); // reload 完成 → 列表上场（首帧的加载剪影随之卸载）

      expect(_flyingLayers, findsWidgets, reason: '入场中是 opacity + 平移的飞行层');

      await tester.pumpAndSettle();
      // 动画结束即卸载：树里不留残余 FadeTransition / Transform
      expect(_flyingLayers, findsNothing);
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(find.text('甲'), findsOneWidget);
    });

    testWidgets('夹内视频页：滚出去再滚回来的条目不重播入场', (tester) async {
      MotionControl.enabled = true;
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (_) => _favPageBody(
              [
                for (var i = 1; i <= 20; i++) _favMedia('BV-p1-$i', '收藏视频$i'),
              ],
              hasMore: false,
            ),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '长夹',
            api: _makeApi(adapter),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏视频1'), findsOneWidget);
      expect(_flyingLayers, findsNothing, reason: '首屏入场已演完');

      // 滚到底（前几条被 ListView 回收）再滚回顶部（重新挂载）
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 2500));
      await tester.pumpAndSettle();

      expect(find.text('收藏视频1'), findsOneWidget);
      // 记账本活在 item 之外 → 回收重建认得出"这一条演过了"，不重播
      expect(_flyingLayers, findsNothing, reason: '同账本同 entryKey 不重播');
    });
  });

  group('整页加载态', () {
    testWidgets('收藏夹总览：加载态 = 剪影 Hero，不是裸转圈', (tester) async {
      _seedValidSession();
      final gate = Completer<void>();
      final adapter = _RoutingAdapter(
        {
          '/x/web-interface/nav': (_) => _navBody(),
          '/x/v3/fav/folder/created/list-all': (_) =>
              _foldersBody([_folder(111, '夹A', 1)]),
        },
        gate: gate.future,
      );
      await tester.pumpWidget(
        MaterialApp(home: FavoritesPage(api: _makeApi(adapter))),
      );
      // 会话读完、接口挂在闸门上 → 稳定停在加载态（剪影静态帧，会收敛）
      await tester.pumpAndSettle();
      expect(
        adapter.requests,
        isNotEmpty,
        reason: '请求已在途（钉住加载态的是闸门，不是"什么都没发生"）',
      );

      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 主文案仍是单一 Text（find.text 锚点）
      expect(find.text('正在加载…'), findsOneWidget);
      // 加载态是可滚动的（宿主 RefreshIndicator 的下拉手势要它撑出来）
      expect(
        tester.widget<ListView>(find.byType(ListView)).physics,
        isA<AlwaysScrollableScrollPhysics>(),
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('夹A'), findsOneWidget);
    });

    testWidgets('收藏夹总览：加载态下仍能下拉刷新（scrollable: true 生效）',
        (tester) async {
      _seedValidSession();
      final gate = Completer<void>();
      final adapter = _RoutingAdapter(
        {
          '/x/web-interface/nav': (_) => _navBody(),
          '/x/v3/fav/folder/created/list-all': (_) =>
              _foldersBody([_folder(111, '夹A', 1)]),
        },
        gate: gate.future,
      );
      await tester.pumpWidget(
        MaterialApp(home: FavoritesPage(api: _makeApi(adapter))),
      );
      await tester.pumpAndSettle(); // 会话读完、接口挂在闸门上 → 停在加载态
      expect(find.byType(SmokeSilhouette), findsOneWidget);

      // 加载态若不可滚动，RefreshIndicator 收不到下拉手势（不会出现下拉指示器）。
      // （下拉刷新在途时 RefreshProgressIndicator 是无限动画 → 只能定长 pump）
      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget,
          reason: '加载态仍可下拉刷新');

      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('夹内视频页：首屏加载态 = 剪影 Hero，且可下拉', (tester) async {
      _seedValidSession();
      final gate = Completer<void>();
      final adapter = _RoutingAdapter(
        {
          '/x/web-interface/nav': (_) => _navBody(),
          '/x/v3/fav/resource/list': (_) =>
              _favPageBody([_favMedia('BV-1', '甲')], hasMore: false),
        },
        gate: gate.future,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '夹A',
            api: _makeApi(adapter),
          ),
        ),
      );
      await tester.pumpAndSettle(); // 会话读完 → 首屏加载态（接口挂在闸门上）

      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<ListView>(find.byType(ListView)).physics,
        isA<AlwaysScrollableScrollPhysics>(),
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('甲'), findsOneWidget);
    });
  });
}
