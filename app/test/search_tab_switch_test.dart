// 搜索页「切 Tab 自动搜 / 同 Tab+关键词只搜一次 / Tab1 绝不发请求 / 代次守卫 /
// 直播范围」widget 测试（v2.28.0+）：
// - 切到 Tab 0（全部 B 站）/ Tab 2（搜索 UP 主）且关键词非空 → **立即**补搜
//   （修「切了类别还得再点一下搜索键」）
// - 同一个「Tab + 关键词」只打一次接口：切回来直接展示已有结果
// - Tab 1（我的白名单）是本地过滤 → 切过去 / 在它上面打字都不发任何请求
// - 切 Tab 触发的搜索**不进搜索历史**（沿用「只有明确的搜索行为才记录」）
// - 代次守卫：先发的请求后到 → 丢弃，不覆盖后发请求的结果（视频 / media /
//   UP 主三个分支各一条，都在**同一个列表**里验，这样断言才真的卡得住守卫）
// - 直播范围：切 chip 即搜、结果卡片点进 LivePlayerPage（含参数与路由名）
//
// 接口全部走内存替身（不触网 / 不触原生插件）；用 [Completer] 当闸门精确控制
// 「谁先回来」，这样才能构造出「旧响应晚到」的场景。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/live_search_result.dart';
import 'package:bili_whitelist_app/models/media_search_result.dart';
import 'package:bili_whitelist_app/models/search_result.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/live_player_page.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/services/search_history_store.dart';
import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/theme/route_names.dart';

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

/// 假 B 站接口：记录每个分支被调用的关键词；`xxxGates[keyword]` 非空时该
/// 关键词的该分支请求挂起（用来构造「先发 A、后发 B、A 的响应晚到」）。
///
/// 三个分支各自返回一条带关键词的结果（标题里带上关键词），这样「列表里现在
/// 是哪一次搜索的结果」可以直接用 `find.text` 断言。
class _FakeBiliApi extends BiliApi {
  final List<String> videoKeywords = [];
  final List<String> mediaKeywords = [];
  final List<String> upownerKeywords = [];
  final List<String> liveKeywords = [];

  final Map<String, Completer<void>> videoGates = {};
  final Map<String, Completer<void>> mediaGates = {};
  final Map<String, Completer<void>> upownerGates = {};

  Future<void> _wait(Completer<void>? gate) async {
    if (gate != null) await gate.future;
  }

  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async {
    videoKeywords.add(keyword);
    await _wait(videoGates[keyword]);
    return SearchPageResult(
      results: [
        SearchResult(
          bvid: 'BV-$keyword',
          title: '视频-$keyword',
          cover: '',
          author: 'UP',
          durationSec: 60,
          playCount: 100,
          pubDate: 1700000000,
        ),
      ],
      totalCount: 1,
      hasMore: false,
    );
  }

  @override
  Future<MediaSearchPageResult> searchMedia(
    String keyword, {
    required String searchType,
    int page = 1,
  }) async {
    mediaKeywords.add(keyword);
    await _wait(mediaGates[keyword]);
    return MediaSearchPageResult(
      results: [
        MediaSearchResult(
          seasonId: keyword.hashCode.abs() + 1,
          title: '季-$keyword',
          cover: '',
          typeLabel: '番剧',
          badge: '',
          styles: '',
          indexShow: '全12话',
        ),
      ],
      totalCount: 1,
      hasMore: false,
    );
  }

  @override
  Future<SearchUpownerResult> searchUpowner(
    String keyword, {
    int page = 1,
  }) async {
    upownerKeywords.add(keyword);
    await _wait(upownerGates[keyword]);
    return SearchUpownerResult(
      upowners: [
        Upowner(
          mid: keyword.hashCode.abs() + 1,
          name: 'UP-$keyword',
          face: '',
          addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
      ],
      totalCount: 1,
      hasMore: false,
    );
  }

  @override
  Future<LiveSearchPageResult> searchLive(String keyword, {int page = 1}) async {
    liveKeywords.add(keyword);
    return const LiveSearchPageResult(
      results: [
        LiveSearchResult(
          roomId: 22747736,
          uid: 406986743,
          uname: '主播A',
          title: '直播间-游戏',
          cover: '',
          online: 445525,
          liveStatus: 1,
        ),
      ],
      totalCount: 1,
      hasMore: false,
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

/// 记录被 push 的路由（只为了拿「直播结果 push 了什么」）。
class _PushSpy extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

final _pushSpy = _PushSpy();

/// pump 搜索页（默认 Tab0 = 全部 B 站），等白名单同步 + 历史加载完成。
Future<void> _pumpSearch(
  WidgetTester tester,
  BiliApi api, {
  SearchHistoryStore? store,
  int initialTab = 0,
}) async {
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [_pushSpy],
    home: SearchPage(
      initialTab: initialTab,
      syncService: _FakeSyncService(),
      historyStore: store ?? SearchHistoryStore(),
      api: api,
    ),
  ));
  await tester.pumpAndSettle();
  // home 路由（"/"）也是 didPush 进来的，等它建完再清账 → 之后 spy 里只剩
  // 「页面自己 push 的路由」
  _pushSpy.pushed.clear();
}

/// 输入关键词并等过防抖窗口（600ms）→ 自动搜索开跑。
///
/// 刻意走防抖路径而不是点搜索按钮：按钮路径会额外记一条搜索历史，防抖是
/// 搜索页最常用入口。
Future<void> _searchByDebounce(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField).first, keyword);
  await tester.pump(); // onChanged → 起防抖
  await tester.pump(const Duration(milliseconds: 700)); // 防抖到期 → 发起搜索
  await tester.pumpAndSettle();
}

/// 点 TabBar 上的 Tab（按文字）。
Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 点搜索范围 chip（按 ChoiceChip 定位，避免与结果里的同名词撞车）。
Future<void> _tapScope(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ChoiceChip, label));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiCopyStore.instance.resetForTest();
    MotionControl.reset();
  });
  tearDown(MotionControl.reset);

  // -------------------------------------------------------------------------
  // 切 Tab 自动搜
  // -------------------------------------------------------------------------

  group('切 Tab 自动搜', () {
    testWidgets('切到「搜索 UP 主」Tab：立即用同一关键词搜一次（不必再点搜索键）',
        (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);

      // 只打字、不等防抖，直接切 Tab：切 Tab 要把这次意图接住
      await tester.enterText(find.byType(TextField).first, '词');
      await tester.pump();
      await _tapTab(tester, '搜索 UP 主');

      expect(api.upownerKeywords, ['词'], reason: '切到 Tab 2 要直接搜');
      expect(api.videoKeywords, isEmpty,
          reason: '切 Tab 时防抖取消 → 不该再按旧 Tab 补发一次视频搜索');
      expect(find.text('UP-词'), findsOneWidget);
    });

    testWidgets('切回「全部 B 站」Tab：关键词非空 → 也自动补搜', (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);

      await tester.enterText(find.byType(TextField).first, '词');
      await tester.pump();
      await _tapTab(tester, '搜索 UP 主');
      await _tapTab(tester, '全部 B 站');

      expect(api.videoKeywords, ['词'], reason: 'Tab 0 还没为「词」搜过 → 补搜');
      expect(find.text('视频-词'), findsOneWidget);
    });

    testWidgets('关键词为空时切 Tab：不发任何请求', (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);
      await _tapTab(tester, '搜索 UP 主');
      await _tapTab(tester, '全部 B 站');

      expect(api.videoKeywords, isEmpty);
      expect(api.upownerKeywords, isEmpty);
      expect(api.liveKeywords, isEmpty);
    });

    testWidgets('同一个「Tab + 关键词」不重复请求：切回来直接用已有结果',
        (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester, '词');
      expect(api.videoKeywords, ['词']);

      await _tapTab(tester, '搜索 UP 主');
      expect(api.upownerKeywords, ['词']);

      // 来回切：两个 Tab 都已经为「词」搜过 → 一次都不该再发
      await _tapTab(tester, '全部 B 站');
      await _tapTab(tester, '搜索 UP 主');
      await _tapTab(tester, '全部 B 站');

      expect(api.videoKeywords, ['词'], reason: 'Tab 0 + 「词」已搜过 → 不重复打接口');
      expect(api.upownerKeywords, ['词'], reason: 'Tab 2 + 「词」同理');
      expect(find.text('视频-词'), findsOneWidget, reason: '直接展示已有结果');
    });

    testWidgets('换了关键词后切 Tab → 按新关键词搜一次（记账是按关键词的）',
        (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester, '甲');
      await _tapTab(tester, '搜索 UP 主');
      await _tapTab(tester, '全部 B 站');
      expect(api.videoKeywords, ['甲']);

      await _searchByDebounce(tester, '乙');
      await _tapTab(tester, '搜索 UP 主');
      await _tapTab(tester, '全部 B 站');

      expect(api.videoKeywords, ['甲', '乙']);
      expect(api.upownerKeywords, ['甲', '乙']);
    });

    testWidgets('切 Tab 触发的搜索不进搜索历史', (tester) async {
      final store = SearchHistoryStore();
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api, store: store);

      await tester.enterText(find.byType(TextField).first, '词');
      await tester.pump();
      await _tapTab(tester, '搜索 UP 主');
      await _tapTab(tester, '全部 B 站');

      expect(api.videoKeywords, ['词'], reason: '先确认确实搜过了');
      expect(await store.getAll(), isEmpty,
          reason: '切 Tab 的自动重查不记历史（只有明确搜索行为才记）');
    });

    testWidgets('Tab 1「我的白名单」：切过去 + 在上面打字都不发任何请求',
        (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester, '词');
      expect(api.videoKeywords, ['词']);

      await _tapTab(tester, '我的白名单');
      expect(api.videoKeywords, ['词'], reason: '切到 Tab 1 不该发请求');

      // 在 Tab 1 上继续打字 → 只做本地过滤
      await tester.enterText(find.byType(TextField).first, '词2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(api.videoKeywords, ['词']);
      expect(api.upownerKeywords, isEmpty);
      expect(api.liveKeywords, isEmpty);
      expect(find.text('白名单里没有匹配的视频'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // 代次守卫（三个分支各一条：都在同一个列表里验，断言才真的卡得住守卫）
  // -------------------------------------------------------------------------

  group('代次守卫（过期响应不覆盖新结果）', () {
    testWidgets('视频分支：先发「甲」后发「乙」，「甲」的响应晚到 → 丢弃',
        (tester) async {
      final api = _FakeBiliApi();
      final gateA = Completer<void>();
      api.videoGates['甲'] = gateA;
      await _pumpSearch(tester, api);

      // 发「甲」（挂起不返回）
      await tester.enterText(find.byType(TextField).first, '甲');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(api.videoKeywords, ['甲']);

      // 改关键词为「乙」→ 正常返回并上屏
      await _searchByDebounce(tester, '乙');
      expect(api.videoKeywords, ['甲', '乙']);
      expect(find.text('视频-乙'), findsOneWidget);

      // 放行「甲」的旧响应：它属于已被取代的搜索 → 必须被丢弃
      gateA.complete();
      await tester.pumpAndSettle();

      expect(find.text('视频-乙'), findsOneWidget, reason: '新结果不能被旧响应冲掉');
      expect(find.text('视频-甲'), findsNothing,
          reason: '「甲」那次搜索已被代次守卫作废');
    });

    testWidgets('media 分支：先发「甲」后发「乙」，「甲」的响应晚到 → 丢弃',
        (tester) async {
      final api = _FakeBiliApi();
      final gateA = Completer<void>();
      api.mediaGates['甲'] = gateA;
      await _pumpSearch(tester, api);
      await _tapScope(tester, '番剧');

      await tester.enterText(find.byType(TextField).first, '甲');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(api.mediaKeywords, ['甲']);

      await _searchByDebounce(tester, '乙');
      expect(api.mediaKeywords, ['甲', '乙']);
      expect(find.text('季-乙'), findsOneWidget);

      gateA.complete();
      await tester.pumpAndSettle();

      expect(find.text('季-乙'), findsOneWidget);
      expect(find.text('季-甲'), findsNothing);
    });

    testWidgets('UP 主分支：先发「甲」后发「乙」，「甲」的响应晚到 → 丢弃',
        (tester) async {
      final api = _FakeBiliApi();
      final gateA = Completer<void>();
      api.upownerGates['甲'] = gateA;
      await _pumpSearch(tester, api, initialTab: 2);

      await tester.enterText(find.byType(TextField).first, '甲');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(api.upownerKeywords, ['甲']);

      await _searchByDebounce(tester, '乙');
      expect(api.upownerKeywords, ['甲', '乙']);
      expect(find.text('UP-乙'), findsOneWidget);

      gateA.complete();
      await tester.pumpAndSettle();

      expect(find.text('UP-乙'), findsOneWidget);
      expect(find.text('UP-甲'), findsNothing);
    });

    testWidgets('切搜索范围：旧范围的响应晚到，不会冒到新范围的结果区',
        (tester) async {
      final api = _FakeBiliApi();
      final gate = Completer<void>();
      api.videoGates['词'] = gate;
      await _pumpSearch(tester, api);

      await tester.enterText(find.byType(TextField).first, '词');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(api.videoKeywords, ['词']);

      // 切到「番剧」范围 → 立刻重查（media）
      await _tapScope(tester, '番剧');
      expect(api.mediaKeywords, ['词']);
      expect(find.text('季-词'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('季-词'), findsOneWidget);
      expect(find.text('视频-词'), findsNothing,
          reason: '番剧范围下不该冒出视频结果');
    });
  });

  // -------------------------------------------------------------------------
  // 直播范围
  // -------------------------------------------------------------------------

  group('直播范围', () {
    testWidgets('切到「直播」chip → 直接搜（search_type=live_room），且只第一页',
        (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester, '游戏');
      expect(api.videoKeywords, ['游戏']);

      await _tapScope(tester, '直播');

      expect(api.liveKeywords, ['游戏'], reason: '切范围即搜（既有语义）');
      expect(find.text('直播间-游戏'), findsOneWidget);
      // 直播不支持排序 → 排序 chip 行隐藏
      expect(find.text('最多播放'), findsNothing);
      // 直播只展示第 1 页 → 列表尾部没有翻页 footer
      expect(find.text('没有更多了'), findsNothing);
      // 卡片副信息行 = 主播名 · 在线人数
      expect(find.textContaining('44.6万 在线'), findsOneWidget);
    });

    testWidgets('点直播结果 → push LivePlayerPage(roomId/title/upName/upMid)'
        ' 且带播放页路由名', (tester) async {
      final api = _FakeBiliApi();
      await _pumpSearch(tester, api);
      await _searchByDebounce(tester, '游戏');
      await _tapScope(tester, '直播');
      expect(_pushSpy.pushed, isEmpty);

      await tester.tap(find.text('直播间-游戏'));

      // ⚠ 刻意**不 pump**：push 已经发生，但新路由还没被建出来。真建出来会拉起
      //   真实播放器（video_player / 通知插件），那不是本用例要验的东西。
      final route = _pushSpy.pushed.single as MaterialPageRoute<void>;
      expect(route.settings.name, kPlayerRouteName,
          reason: '借用播放页路由名换取「快速淡入」转场');
      final page = route.builder(tester.element(find.byType(SearchPage)))
          as LivePlayerPage;
      expect(page.roomId, 22747736);
      expect(page.title, '直播间-游戏');
      expect(page.upName, '主播A');
      expect(page.upMid, 406986743);
    });
  });
}
