// 搜索 / 信箱 / UP 主 / 关注导入 / 统计族页面的「列表项交错入场 + 整页加载态」
// 测试（块化与动效系统 批次 4）：
// - 关动效（`flutter test` 环境默认）：列表项仍包在 [StaggeredEntrance] 里，
//   但树里**没有** FadeTransition 飞行层 —— 形态/命中测试不变
// - 开动效（显式 `MotionControl.enabled = true`）：首屏逐条推入（动画期有飞行
//   层），`pumpAndSettle` 后包裹层卸载；已记账的条目被回收重建时**不重播**
// - 整页加载态 = [AppLoadingHero]（SmokeSilhouette 剪影 + 加载闲话），不是裸转圈
// - 列表底部翻页 = 小剪影（56）+ footer 闲话，不是裸转圈
// - `RefreshIndicator` 宿主页（信箱）在加载态下**仍能下拉刷新**
//   （AppLoadingHero 传了 `scrollable: true`）
// - 统计页不是列表 → 只换加载态，**不做**交错入场
//
// 接口全部走内存替身（不触网 / 不触原生插件）；用 [Completer] 当「闸门」把页面
// 钉在加载态，避免依赖「微任务跑多快」的不确定时序。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/search_result.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/followings_import_page.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/pages/watch_stats_page.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/loading_copy.dart';
import 'package:bili_whitelist_app/services/search_history_store.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';
import 'package:bili_whitelist_app/widgets/inbox_swipe_card.dart';
import 'package:bili_whitelist_app/widgets/smoke_silhouette.dart';
import 'package:bili_whitelist_app/widgets/staggered_entrance.dart';

// ---------------------------------------------------------------------------
// 测试替身（全部内存态）
// ---------------------------------------------------------------------------

SearchResult _video(int i) => SearchResult(
      bvid: 'BV$i',
      title: '测试视频 $i',
      cover: '',
      author: 'UP$i',
      durationSec: 60,
      playCount: 100,
      pubDate: 1700000000,
    );

Upowner _up(int mid) => Upowner(
      mid: mid,
      name: 'UP$mid',
      face: '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

WhitelistVideo _wlVideo(int i) => WhitelistVideo(
      bvid: 'BV$i',
      cid: 0,
      title: '测试视频 $i',
      cover: '',
      duration: 60,
      upName: 'UP',
      addedAt: '2026-01-01T00:00:00.000Z',
    );

/// 假 B 站接口：立即返回内存数据；`xxxGate` 非空时对应请求挂起
/// （把页面钉在加载态）；`xxxHasMore` 控制是否还有下一页（翻页 footer 用）。
class _FakeBiliApi extends BiliApi {
  _FakeBiliApi({
    this.videos = const [],
    this.upownerResults = const [],
    this.upownerVideos = const [],
    this.collections = const [],
    this.followings = const [],
    this.videoHasMore = false,
    this.upownerHasMore = false,
    this.followingsHasMore = false,
    this.seasonHasMore = false,
  });

  final List<SearchResult> videos;
  final List<Upowner> upownerResults;
  final List<WhitelistVideo> upownerVideos;
  final List<UpownerCollection> collections;
  final List<Upowner> followings;
  final bool videoHasMore;
  final bool upownerHasMore;
  final bool followingsHasMore;
  final bool seasonHasMore;

  Completer<void>? videoGate;
  Completer<void>? videoPage2Gate;
  Completer<void>? mediaGate;
  Completer<void>? upownerPage2Gate;
  Completer<void>? upownerVideosGate;
  Completer<void>? followingsGate;
  Completer<void>? followingsPage2Gate;
  Completer<void>? seasonGate;
  Completer<void>? seasonPage2Gate;
  int followingsCalls = 0;

  Future<T> _gated<T>(Completer<void>? gate, T value) async {
    if (gate != null) await gate.future;
    return value;
  }

  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async {
    if (page > 1) {
      await _gated(videoPage2Gate, null);
      return const SearchPageResult(results: [], totalCount: 0, hasMore: false);
    }
    await _gated(videoGate, null);
    return SearchPageResult(
      results: videos,
      totalCount: videos.length,
      hasMore: videoHasMore,
    );
  }

  @override
  Future<SearchUpownerResult> searchUpowner(
    String keyword, {
    int page = 1,
  }) async {
    if (page > 1) {
      await _gated(upownerPage2Gate, null);
      return const SearchUpownerResult(
        upowners: [],
        totalCount: 0,
        hasMore: false,
      );
    }
    return SearchUpownerResult(
      upowners: upownerResults,
      totalCount: upownerResults.length,
      hasMore: upownerHasMore,
    );
  }

  @override
  Future<UpownerVideosPage> fetchUpownerVideos(
    int mid, {
    int pn = 1,
    int ps = 20,
    String order = 'pubdate',
    String keyword = '',
  }) async =>
      _gated(
        upownerVideosGate,
        UpownerVideosPage(
          videos: upownerVideos,
          totalCount: upownerVideos.length,
          hasMore: false,
        ),
      );

  @override
  Future<MediaSearchPageResult> searchMedia(
    String keyword, {
    required String searchType,
    int page = 1,
  }) async {
    await _gated(mediaGate, null);
    return const MediaSearchPageResult(
      results: [],
      totalCount: 0,
      hasMore: false,
    );
  }

  @override
  Future<UpownerInfo> fetchUpownerInfo(int mid) async =>
      UpownerInfo(name: 'UP$mid', face: '', fans: 1, sign: '');

  @override
  Future<int> fetchUpownerFollower(int mid) async => 1;

  @override
  Future<UpownerCollectionsResult> fetchUpownerCollections(
    int mid, {
    int pageNum = 1,
    int pageSize = 20,
  }) async =>
      UpownerCollectionsResult(seasons: collections, series: const []);

  @override
  Future<UpownerVideosPage> fetchSeasonArchives(
    int seasonId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    if (page > 1) {
      await _gated(seasonPage2Gate, null);
      return const UpownerVideosPage(videos: [], totalCount: 0, hasMore: false);
    }
    return _gated(
      seasonGate,
      UpownerVideosPage(
        videos: upownerVideos,
        totalCount: upownerVideos.length,
        hasMore: seasonHasMore,
      ),
    );
  }

  @override
  Future<FollowingsPage> fetchFollowingsOfMine({
    int pn = 1,
    int ps = 20,
  }) async {
    followingsCalls++;
    if (pn > 1) {
      await _gated(followingsPage2Gate, null);
      return const FollowingsPage(upowners: [], totalCount: 0, hasMore: false);
    }
    await _gated(followingsGate, null);
    return FollowingsPage(
      upowners: followings,
      totalCount: followings.length,
      hasMore: followingsHasMore,
    );
  }
}

/// 假白名单同步服务：固定空白名单（不触原生插件 / 网络）。
class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<SyncResult> sync() async => SyncResult(
        data: const WhitelistData(
          version: WhitelistData.currentVersion,
          updatedAt: '2026-09-09T00:00:00Z',
          videos: [],
        ),
        sourceName: 'fake',
        fetchedAt: DateTime(2026, 9, 9),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 假信箱服务：`getItems` 立即返回；`checkGate` 非空时 `checkAll` 挂起；
/// `failChecks > 0` 时 `checkAll` 抛 [DioException]（模拟网络失败，每抛一次自减）。
class _FakeInboxService extends InboxService {
  _FakeInboxService(this.items, {this.failChecks = 0});

  final List<InboxItem> items;
  int failChecks;
  Completer<void>? checkGate;
  int checkCalls = 0;

  @override
  Future<List<InboxItem>> getItems() async => items;

  @override
  Future<InboxCheckResult> checkAll({bool force = false}) async {
    checkCalls++;
    if (failChecks > 0) {
      failChecks--;
      throw DioException(requestOptions: RequestOptions(path: '/x/inbox'));
    }
    final gate = checkGate;
    if (gate != null) await gate.future;
    return InboxCheckResult(total: 0, unseen: items.length, items: items);
  }

  @override
  Future<void> markAllRead() async {}
}

/// 假 GitHub 接口（关注导入页只用 hasConfig / fetchFromGist）。
class _FakeGithubApi extends GithubApi {
  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() async => WhitelistData.empty();
}

/// 闸门版统计源：`ensureLoaded` 由 [gate] 控制 → 稳定停在首帧加载态。
class _GatedWatchStats extends WatchStats {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> ensureLoaded() async {
    await gate.future;
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// [StaggeredEntrance] 内部的匹配（飞行包裹层只出现在它里面）。
Finder _inStagger(Finder matching) => find.descendant(
      of: find.byType(StaggeredEntrance),
      matching: matching,
    );

List<String> _entryKeys(WidgetTester tester) => tester
    .widgetList<StaggeredEntrance>(find.byType(StaggeredEntrance))
    .map((e) => e.entryKey)
    .toList();

/// pump 搜索页（Tab0 = 全部 B 站），等白名单同步 + 历史加载完成。
Future<void> _pumpSearch(WidgetTester tester, BiliApi api) async {
  await tester.pumpWidget(MaterialApp(
    home: SearchPage(
      syncService: _FakeSyncService(),
      historyStore: SearchHistoryStore(),
      api: api,
    ),
  ));
  await tester.pumpAndSettle();
}

/// 输入关键词并等过防抖窗口（600ms）→ 自动搜索开跑。
///
/// 刻意走防抖路径而不是点搜索按钮：按钮路径会额外记一条搜索历史，防抖是
/// 搜索页最常用入口，且一次性 Timer 触发后不再残留计时器。
Future<void> _searchByDebounce(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, '测试');
  await tester.pump(); // onChanged → 起防抖
  await tester.pump(const Duration(milliseconds: 700)); // 防抖到期 → 发起搜索
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiCopyStore.instance.resetForTest();
    MotionControl.reset(); // 测试环境默认 = false（关动效）
  });
  tearDown(MotionControl.reset);

  // -------------------------------------------------------------------------
  // 搜索页（视频结果 Tab）
  // -------------------------------------------------------------------------

  group('搜索页 · 交错入场', () {
    testWidgets('关动效：列表项直接是 child（无飞行层），entryKey = bvid',
        (tester) async {
      final api = _FakeBiliApi(videos: [_video(1), _video(2), _video(3)]);
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester);
      await tester.pumpAndSettle();

      expect(find.byType(StaggeredEntrance), findsNWidgets(3));
      expect(find.byType(StaggeredListScope), findsOneWidget);
      // 关动效 → 树里连包裹层都不建
      expect(_inStagger(find.byType(FadeTransition)), findsNothing);
      // entryKey 用数据稳定标识（不是下标）
      expect(_entryKeys(tester), ['bvid:BV1', 'bvid:BV2', 'bvid:BV3']);
    });

    testWidgets('开动效：动画期有飞行层 → settle 后卸载；回收再挂载不重播',
        (tester) async {
      MotionControl.enabled = true;
      final api = _FakeBiliApi(
        videos: [for (var i = 1; i <= 12; i++) _video(i)],
      );
      api.videoGate = Completer<void>(); // 先把页面钉在加载态
      // ★ 首屏还是「搜索前空态」= AppStateView(empty.search)，里面那张细线插画
      //   现在是无限 ticker（与 AppLoadingHero 的剪影同理）→ 开着动效就没法
      //   pumpAndSettle。首帧先按静态挂载，结果列表上场前再开动效；
      //   本用例要验的是**条目交错入场**，它的包裹层在结果到达时才挂载。
      MotionControl.enabled = false;
      await _pumpSearch(tester, api);
      MotionControl.enabled = true;
      await tester.enterText(find.byType(TextField).first, '测试');
      await tester.pump(); // onChanged → 起防抖
      await tester.pump(const Duration(milliseconds: 700)); // 防抖到期

      // 发起搜索的第一帧 = 整页加载态（顺带验证加载态组件）
      expect(find.byType(AppLoadingHero), findsOneWidget);

      // 结果到达 → 列表 + 入场飞行层
      api.videoGate!.complete();
      await tester.pump();
      expect(_inStagger(find.byType(FadeTransition)), findsWidgets);

      // 有限 ticker（Interval 延迟，不是 Future.delayed）→ 必然收敛
      await tester.pumpAndSettle();
      expect(_inStagger(find.byType(FadeTransition)), findsNothing,
          reason: '动画结束即卸载飞行包裹层');
      // ListView 懒加载：只建可视区的项（12 条不可能全在屏上）
      expect(find.byType(StaggeredEntrance), findsAtLeastNWidgets(6));

      // 滚走再滚回：旧元素被回收后重新挂载 → 账本认账，不重播
      await tester.drag(find.byType(ListView), const Offset(0, -900));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_inStagger(find.byType(FadeTransition)), findsNothing,
          reason: '同一个 entryKey 演过了就不再演');
      await tester.pumpAndSettle();
    });
  });

  group('搜索页 · 加载态', () {
    testWidgets('搜索中：AppLoadingHero（剪影 + 闲话），不是转圈', (tester) async {
      final api = _FakeBiliApi(videos: [_video(1)]);
      api.videoGate = Completer<void>();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester);

      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).seed,
        'search.video',
      );
      // seed 决定副文案（确定性 → 可断言）
      expect(
        find.text(loadingCopyFor(pool: kLoadingPoolPage, seed: 'search.video')),
        findsOneWidget,
      );

      api.videoGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AppLoadingHero), findsNothing);
      expect(find.text('测试视频 1'), findsOneWidget);
    });

    testWidgets('没有更多：脚部文案保持（不是剪影）', (tester) async {
      final api = _FakeBiliApi(videos: [_video(1)]);
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester);
      await tester.pumpAndSettle();

      expect(find.text('没有更多了'), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('翻页 footer：小剪影 + footer 闲话（视频列表）', (tester) async {
      final api = _FakeBiliApi(
        videos: [for (var i = 1; i <= 20; i++) _video(i)],
        videoHasMore: true,
      );
      api.videoPage2Gate = Completer<void>();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester);
      await tester.pumpAndSettle();

      // 滚到底 → 触发翻页（page=2 挂起）→ 脚部换成剪影 + 闲话
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(
        find.text(loadingCopyFor(pool: kLoadingPoolFooter, seed: 'search.video')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '翻页脚部不再用裸转圈');

      api.videoPage2Gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('番剧/影视搜索中：AppLoadingHero（seed = search.media）', (tester) async {
      final api = _FakeBiliApi();
      api.mediaGate = Completer<void>();
      await _pumpSearch(tester, api);

      // 切到「番剧」范围 → 输关键词走防抖 → media 搜索挂起
      await tester.tap(find.text('番剧'));
      await tester.pumpAndSettle();
      await _searchByDebounce(tester);

      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).seed,
        'search.media',
      );
      // 番剧空态文案锚点不变
      api.mediaGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('没有找到相关番剧，换个关键词试试'),
        findsOneWidget,
      );
      // 空态统一到 AppStateView（动态范围名走 title 直给）+ 细线插画
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.title, '没有找到相关番剧，换个关键词试试');
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'search.media.result',
      );
    });

    testWidgets('翻页 footer：小剪影 + footer 闲话（UP 主列表）', (tester) async {
      final api = _FakeBiliApi(
        upownerResults: [for (var i = 1; i <= 20; i++) _up(i)],
        upownerHasMore: true,
      );
      api.upownerPage2Gate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: SearchPage(
          initialTab: 2, // 「搜索 UP 主」
          syncService: _FakeSyncService(),
          historyStore: SearchHistoryStore(),
          api: api,
        ),
      ));
      await tester.pumpAndSettle();
      await _searchByDebounce(tester);
      await tester.pumpAndSettle();
      expect(find.byType(StaggeredEntrance), findsWidgets);

      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(
        find.text(
          loadingCopyFor(pool: kLoadingPoolFooter, seed: 'search.upowner'),
        ),
        findsOneWidget,
      );

      api.upownerPage2Gate!.complete();
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  // 信箱页（RefreshIndicator 宿主）
  // -------------------------------------------------------------------------

  group('信箱页', () {
    InboxItem item(int i) => InboxItem(
          upMid: i,
          upName: 'UP$i',
          upFace: '',
          bvid: 'BV$i',
          title: '新视频 $i',
          cover: '',
          duration: 60,
          pubDate: 1700000000,
        );

    testWidgets('首屏加载：scrollable 的 AppLoadingHero，且仍能下拉刷新',
        (tester) async {
      final service = _FakeInboxService(const []);
      service.checkGate = Completer<void>();
      ServiceLocator.overrideInboxService(service);

      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pump();

      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).scrollable,
        isTrue,
        reason: '宿主是 RefreshIndicator → 必须 scrollable 才能下拉',
      );
      // scrollable: true 的形态 = ListView(AlwaysScrollableScrollPhysics)
      expect(
        tester.widget<ListView>(find.byType(ListView)).physics,
        isA<AlwaysScrollableScrollPhysics>(),
      );

      // ★ 加载态下仍能下拉刷新：fling 下来 → onRefresh 再跑一次
      expect(service.checkCalls, 1);
      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // 滚回顶部 + 指示器就位
      expect(service.checkCalls, 2, reason: '加载态下下拉刷新必须仍生效');

      service.checkGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('有条目：卡片栈逐条入场（entryKey = bvid）', (tester) async {
      final service = _FakeInboxService([item(1), item(2)]);
      ServiceLocator.overrideInboxService(service);

      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();

      // 卡片栈只挂「当前 + 下一张」两张卡（不是长列表）：两张都在树里
      expect(find.byType(StaggeredEntrance), findsNWidgets(2));
      // ★ 顺序 = Stack 的绘制顺序（自下而上）：下层（下一张）在前、顶层在后，
      //   顶层才盖得住下层、只露出下移的那一角。entryKey 仍是 `bvid:<bvid>`。
      expect(_entryKeys(tester), ['bvid:BV2', 'bvid:BV1']);
      // 语义断言：队首（最新）是顶层卡片，下一张在下层
      final cards =
          tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).toList();
      expect(cards.length, 2);
      expect(cards.first.item.bvid, 'BV2', reason: '下层 = 下一张');
      expect(cards.last.item.bvid, 'BV1', reason: '顶层 = 队首（最新）');
      expect(find.text('新视频 1'), findsOneWidget);
      expect(find.byType(AppLoadingHero), findsNothing);
    });

    testWidgets('空态文案不变（入队容器不动），且统一走 AppStateView', (tester) async {
      ServiceLocator.overrideInboxService(_FakeInboxService(const []));
      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('暂未有白名单 UP 主的新视频'),
        findsOneWidget,
      );
      expect(find.byType(StaggeredEntrance), findsNothing);

      // 空态统一到 AppStateView：copyId 走 UiCopyStore（逐字不变）+ 细线插画
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.inbox');
      expect(state.scrollable, isTrue, reason: '宿主是 RefreshIndicator → 必须可滚动');
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'inbox',
      );
    });

    testWidgets('首屏失败 → AppErrorView（本轮补上「重试」）；点重试重新 check',
        (tester) async {
      // 第 1 次 checkAll 抛网络错误 → 错误态；重试后成功
      final service = _FakeInboxService(const [], failChecks: 1);
      ServiceLocator.overrideInboxService(service);

      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorView), findsOneWidget);
      expect(
        tester.widget<AppErrorView>(find.byType(AppErrorView)).scrollable,
        isTrue,
        reason: '宿主是 RefreshIndicator → 错误态也要能下拉',
      );
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'inbox',
      );
      // ★ 旧版错误态**没有**重试按钮（只能下拉刷新）→ 本轮补齐
      expect(find.text('重试'), findsOneWidget);
      expect(service.checkCalls, 1);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(service.checkCalls, 2, reason: '点「重试」必须重新 check');
      expect(find.byType(AppErrorView), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // UP 主页
  // -------------------------------------------------------------------------

  group('UP 主页', () {
    testWidgets('视频列表：逐条入场，entryKey = bvid；空态文案不变', (tester) async {
      final api = _FakeBiliApi(
        upownerVideos: [_wlVideo(1), _wlVideo(2)],
      );
      await tester.pumpWidget(MaterialApp(
        home: UpownerPage(mid: 100, api: api),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(StaggeredEntrance), findsNWidgets(2));
      expect(_entryKeys(tester), ['bvid:BV1', 'bvid:BV2']);
      expect(
        tester
            .widgetList<StaggeredEntrance>(find.byType(StaggeredEntrance))
            .map((e) => e.index)
            .toList(),
        [0, 1],
      );
    });

    testWidgets('空列表：文案「暂无视频」不变，且不建 scope', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: UpownerPage(mid: 100, api: _FakeBiliApi()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('暂无视频'), findsOneWidget);
      expect(find.byType(StaggeredEntrance), findsNothing);

      // 空态统一到 AppStateView：copyId = empty.upowner_videos + 细线插画
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.upowner_videos');
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'upowner.videos',
      );
    });

    testWidgets('首屏拉视频中：AppLoadingHero（seed = upowner.videos）',
        (tester) async {
      final api = _FakeBiliApi(upownerVideos: [_wlVideo(1)]);
      api.upownerVideosGate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: UpownerPage(mid: 100, api: api),
      ));
      await tester.pump();

      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).seed,
        'upowner.videos',
      );

      api.upownerVideosGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(StaggeredEntrance), findsOneWidget);
    });

    testWidgets('合集视图加载态 seed 与「全部视频」不同（两处等待不串味）',
        (tester) async {
      final api = _FakeBiliApi(
        upownerVideos: [_wlVideo(1)],
        collections: const [
          UpownerCollection(
            id: 7,
            name: '合集·测试',
            cover: '',
            description: '',
            total: 1,
            creator: '',
            kind: UpownerCollectionKind.season,
          ),
        ],
      );
      api.seasonGate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: UpownerPage(mid: 100, api: api),
      ));
      await tester.pumpAndSettle();
      expect(_entryKeys(tester), ['bvid:BV1']);

      // 点合集 chip → 内容区动画滑到合集分区 → 合集视频列表加载中 →
      // 另一套 seed 的加载态。
      // 注意这里要 pump 两帧：切分区是 PageView 的横滑动画（kDurBase），
      // 第一帧只是让动画起步、目标页还没进视口（也就还没被建出来），
      // 推到动画中段才看得到它。
      await tester.tap(find.text('合集·测试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).seed,
        'upowner.seasons',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.seasonGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(StaggeredEntrance), findsOneWidget);
    });

    testWidgets('合集列表翻页 footer：小剪影 + footer 闲话（seed = upowner.seasons）',
        (tester) async {
      final api = _FakeBiliApi(
        upownerVideos: [for (var i = 1; i <= 20; i++) _wlVideo(i)],
        seasonHasMore: true,
        collections: const [
          UpownerCollection(
            id: 7,
            name: '合集·测试',
            cover: '',
            description: '',
            total: 20,
            creator: '',
            kind: UpownerCollectionKind.season,
          ),
        ],
      );
      api.seasonPage2Gate = Completer<void>();
      await tester.pumpWidget(MaterialApp(
        home: UpownerPage(mid: 100, api: api),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('合集·测试'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump();

      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(
        find.text(
          loadingCopyFor(pool: kLoadingPoolFooter, seed: 'upowner.seasons'),
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '翻页脚部不再用裸转圈');

      api.seasonPage2Gate!.complete();
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  // 关注导入页
  // -------------------------------------------------------------------------

  group('关注导入页', () {
    testWidgets('首屏加载 = AppLoadingHero；条目入场 entryKey = mid', (tester) async {
      final api = _FakeBiliApi(followings: [_up(1), _up(2), _up(3)]);
      api.followingsGate = Completer<void>();
      final writer = UpownerWriter(github: _FakeGithubApi(), api: api);

      await tester.pumpWidget(MaterialApp(
        home: FollowingsImportPage(writer: writer, api: api),
      ));
      await tester.pump();

      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsOneWidget);
      // 底部「加入白名单（0）」按钮的内联转圈**故意保留**（操作反馈，
      // 不是等待画面）→ 加载态里应当只有它一个转圈
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: '按钮内联转圈不换剪影',
      );
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).seed,
        'followings',
      );

      api.followingsGate!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(StaggeredEntrance), findsNWidgets(3));
      expect(_entryKeys(tester), ['mid:1', 'mid:2', 'mid:3']);
      // 既有文案锚点不动
      expect(find.textContaining('B 站关注共 3 位'), findsOneWidget);
    });

    testWidgets('勾选链路照旧（全选 → 按钮文案），按钮内联转圈不动', (tester) async {
      final api = _FakeBiliApi(followings: [_up(1)]);
      final writer = UpownerWriter(github: _FakeGithubApi(), api: api);
      await tester.pumpWidget(MaterialApp(
        home: FollowingsImportPage(writer: writer, api: api),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('加入白名单（1）'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(SmokeSilhouette), findsNothing);
    });

    testWidgets('「加载更多」footer：小剪影 + footer 闲话；按钮内联转圈保留',
        (tester) async {
      final api = _FakeBiliApi(
        followings: [for (var i = 1; i <= 20; i++) _up(i)],
        followingsHasMore: true,
      );
      api.followingsPage2Gate = Completer<void>();
      final writer = UpownerWriter(github: _FakeGithubApi(), api: api);
      await tester.pumpWidget(MaterialApp(
        home: FollowingsImportPage(writer: writer, api: api),
      ));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.textContaining('加载更多'), 300);
      await tester.tap(find.textContaining('加载更多').first);
      await tester.pump();

      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(
        find.text(loadingCopyFor(pool: kLoadingPoolFooter, seed: 'followings')),
        findsOneWidget,
      );
      // 底部「加入白名单」按钮的内联转圈**故意保留**（操作反馈）
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: '按钮内联转圈不换剪影',
      );

      api.followingsPage2Gate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('已加载全部关注'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // 观看统计页
  // -------------------------------------------------------------------------

  group('观看统计页', () {
    testWidgets('首帧等待 = AppLoadingHero；不是列表 → 不做交错入场',
        (tester) async {
      final stats = _GatedWatchStats();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pump();

      expect(find.byType(AppLoadingHero), findsOneWidget);
      expect(find.byType(SmokeSilhouette), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<AppLoadingHero>(find.byType(AppLoadingHero)).seed,
        'stats',
      );
      expect(find.byType(StaggeredEntrance), findsNothing,
          reason: '统计页不是列表，不做交错入场');

      stats.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AppLoadingHero), findsNothing);
      expect(find.text('观看统计'), findsOneWidget);
      expect(find.text('观看总览'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // P4b 空态接线（AppStateView / AppErrorView）
  // -------------------------------------------------------------------------

  group('空态接线：搜索页 / 关注导入页', () {
    testWidgets('搜索页视频 Tab：搜索前提示 → AppStateView(empty.search)',
        (tester) async {
      await _pumpSearch(tester, _FakeBiliApi());

      expect(
        find.text('输入关键词，搜索 B 站全网视频\n'
            '结果可一键加入白名单（加入前会查重）'),
        findsOneWidget,
      );
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.search');
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'search.video',
      );
    });

    testWidgets('搜索页视频 Tab：无结果 → AppStateView(empty.search.result)',
        (tester) async {
      await _pumpSearch(tester, _FakeBiliApi());
      await _searchByDebounce(tester);
      await tester.pumpAndSettle();

      expect(find.text('没有找到相关视频，换个关键词试试'), findsOneWidget);
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.copyId, 'empty.search.result');
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'search.video.result',
      );
      expect(find.byType(StaggeredEntrance), findsNothing);
    });

    testWidgets('搜索页：「我的白名单」Tab 空 → AppStateView(empty.search.whitelist.filter)',
        (tester) async {
      await _pumpSearch(tester, _FakeBiliApi());
      await tester.tap(find.text('我的白名单'));
      await tester.pumpAndSettle();

      expect(find.text('白名单里没有匹配的视频'), findsOneWidget);
      expect(
        tester.widget<AppStateView>(find.byType(AppStateView)).copyId,
        'empty.search.whitelist.filter',
      );
    });

    testWidgets('关注导入页：拉不到任何关注 → AppStateView(empty.followings)',
        (tester) async {
      final api = _FakeBiliApi();
      final writer = UpownerWriter(github: _FakeGithubApi(), api: api);

      await tester.pumpWidget(MaterialApp(
        home: FollowingsImportPage(writer: writer, api: api),
      ));
      await tester.pumpAndSettle();

      // 文案锚点不变
      expect(
        find.text('这个账号还没有关注任何 UP 主\n（或关注列表未公开）'),
        findsOneWidget,
      );
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.followings');
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'followings',
      );
    });
  });
}
