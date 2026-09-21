// 搜索页「点结果卡直接看」（v2.38.0）：
// - 视频结果卡：点整卡 → 补元数据（view 接口）→ push [PlayerPage]，**只播、
//   不写白名单**（注入记录型 GithubApi，断言一次写请求都没发、连配置门禁
//   `hasConfig` 都没查——证明点击路径根本没走到写入服务）；
// - 番剧/影视结果卡：点整卡 → 取季 → **首集** → push [PlayerPage]；
//   首集是会员集也照播（播放页自己有试看/会员提示）；取不到可播集 → 只提示；
// - 失败分类：失效条目 62002 / 其它业务码 / 网络失败 → 只提示、**不跳空白页**；
// - 尾部「加入」「导入」按钮原样（点击整卡不触发它们）。
//
// 断言方式沿用 search_tab_switch_test 的直播用例：**刻意不 pump** —— push 已经
// 发生（await tap 会冲掉微任务），但新路由还没被建出来；真建出来会拉起真实
// 播放器（video_player / 通知插件），那不是本文件要验的东西。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/live_search_result.dart';
import 'package:bili_whitelist_app/models/media_search_result.dart';
import 'package:bili_whitelist_app/models/search_result.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/services/search_history_store.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';

// ---------------------------------------------------------------------------
// 替身
// ---------------------------------------------------------------------------

/// 记录型 GithubApi：写白名单必经的三个方法都记账，绝不触网。
///
/// 本文件关心的**不是**它写了什么，而是它**一次都没被碰过** —— 所以连
/// `hasConfig`（写操作前的配置门禁）都记：搜索页「加入」的第一句就是
/// `await _writer.hasConfig()`，命中即说明点击整卡错误地走到了写入路径。
class _RecordingGithubApi extends GithubApi {
  int hasConfigCalls = 0;
  int fetchCalls = 0;
  int saveCalls = 0;
  final List<WhitelistData> saved = [];

  _RecordingGithubApi() : super(dio: Dio());

  @override
  Future<bool> hasConfig() async {
    hasConfigCalls++;
    return true;
  }

  @override
  Future<WhitelistData?> fetchFromGist() async {
    fetchCalls++;
    return null;
  }

  @override
  Future<bool> saveToGist(WhitelistData wl) async {
    saveCalls++;
    saved.add(wl);
    return true;
  }
}

/// 假 B 站接口：搜出固定的视频结果与番剧结果；view / pgc 两个详情接口可控。
class _FakeApi extends BiliApi {
  _FakeApi({this.videoError, this.season, this.seasonError});

  /// view 接口要抛的异常（null → 返回默认完整响应）。
  final BiliApiException? videoError;

  /// pgc 接口返回值（null → 用默认 2 集季）。
  final PgcSeason? season;

  /// pgc 接口要抛的异常（优先于 [season]）。
  final BiliApiException? seasonError;

  final List<int> videoMetaBvids = [];
  final List<int> pgcSeasonIds = [];

  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async =>
      SearchPageResult(
        results: [
          SearchResult(
            bvid: 'BVsearch1',
            title: '视频-$keyword',
            cover: '',
            author: '结果UP主',
            durationSec: 285,
            playCount: 12345,
            pubDate: 1682899200,
          ),
        ],
        totalCount: 1,
        hasMore: false,
      );

  @override
  Future<MediaSearchPageResult> searchMedia(
    String keyword, {
    required String searchType,
    int page = 1,
  }) async =>
      MediaSearchPageResult(
        results: [
          MediaSearchResult(
            seasonId: 555,
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

  @override
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    videoMetaBvids.add(1);
    if (videoError != null) throw videoError!;
    return {
      'bvid': bvid,
      'cid': 4242,
      'title': '视频标题（view）',
      'duration': 285,
      'desc': '简介',
      'owner': {'name': '真UP主'},
      'stat': {'view': 999},
      'pages': [
        {'cid': 4242, 'part': 'P1', 'duration': 285},
      ],
    };
  }

  @override
  Future<PgcSeason> fetchPgcSeason({int? epId, int? seasonId}) async {
    pgcSeasonIds.add(seasonId ?? -1);
    if (seasonError != null) throw seasonError!;
    if (season != null) return season!;
    return _seasonFixture();
  }
}

/// 两集季：第 1 集是**会员集**（badge = '会员'），用来验「照播首集而不是
/// 替用户挑免费集」。
PgcSeason _seasonFixture() => const PgcSeason(
  title: '季-词',
  cover: '',
  seasonId: 555,
  episodes: [
    PgcEpisode(
      epId: 101,
      aid: 1,
      cid: 1001,
      bvid: 'BVep1',
      title: '1',
      longTitle: '第一话副标题',
      cover: '',
      durationSec: 1440,
      pubTimeSec: 1700000000,
      badge: '会员',
    ),
    PgcEpisode(
      epId: 102,
      aid: 2,
      cid: 1002,
      bvid: 'BVep2',
      title: '2',
      longTitle: '第二话副标题',
      cover: '',
      durationSec: 1440,
      pubTimeSec: 1700086400,
      badge: '',
    ),
  ],
);

/// 假同步服务（不触原生插件）。
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

/// 记录被 push 的路由。
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

final _spy = _PushSpy();

/// pump 搜索页；返回记录型 GithubApi 供断言「不写白名单」。
Future<_RecordingGithubApi> _pumpSearch(
  WidgetTester tester,
  _FakeApi api,
) async {
  final github = _RecordingGithubApi();
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [_spy],
    home: SearchPage(
      syncService: _FakeSyncService(),
      historyStore: SearchHistoryStore(),
      api: api,
      // 注入写入服务替身：本文件全部用例都在断言它**没被碰过**
      writer: WhitelistWriter(github: github, api: api),
    ),
  ));
  await tester.pumpAndSettle();
  _spy.pushed.clear(); // 主页路由也是 push 进来的，清掉只留页面自己推的
  return github;
}

Future<void> _searchVideo(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField).first, keyword);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700)); // 过防抖窗口
  await tester.pumpAndSettle();
}

/// 取出唯一一条被 push 的路由，并断言它借用播放页路由名（快速淡入转场）。
MaterialPageRoute<void> _onlyPushedRoute() {
  final route = _spy.pushed.single as MaterialPageRoute<void>;
  expect(route.settings.name, kPlayerRouteName,
      reason: '与直播/收藏夹入口同一约定：借用播放页路由名换取快速淡入');
  return route;
}

/// 把路由的 builder 叫起来（**只构造 widget，不挂载**），拿到 PlayerPage。
PlayerPage _builtPlayer(WidgetTester tester, MaterialPageRoute<void> route) =>
    route.builder(tester.element(find.byType(SearchPage))) as PlayerPage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MotionControl.reset();
  });
  tearDown(MotionControl.reset);

  group('视频结果卡：点整卡直接看', () {
    testWidgets('点视频卡 → push PlayerPage（补全 cid/标题/UP主）且一次 Gist 都没写',
        (tester) async {
      final api = _FakeApi();
      final github = await _pumpSearch(tester, api);
      await _searchVideo(tester, '词');
      expect(find.text('视频-词'), findsOneWidget);

      await tester.tap(find.text('视频-词'));
      // ⚠ 刻意**不 pump**：push 已发生，但新路由还没被建（理由见文件头）

      final page = _builtPlayer(tester, _onlyPushedRoute());
      expect(page.video.bvid, 'BVsearch1');
      expect(page.video.cid, 4242, reason: '搜索结果只有 bvid → 必须补出 cid');
      expect(page.video.title, '视频标题（view）');
      expect(page.video.upName, '真UP主');
      expect(page.video.collection, '', reason: '只播不入白名单 → 不归任何合集');
      expect(api.videoMetaBvids.length, 1);

      // 「不写白名单」的硬证据：写入服务连配置门禁都没被查过
      expect(github.hasConfigCalls, 0, reason: '点整卡不该走「加入」那条写路径');
      expect(github.fetchCalls, 0);
      expect(github.saveCalls, 0);
      // 尾部「加入」按钮原样还在（点击整卡不触发它）
      expect(find.text('加入'), findsOneWidget);
    });

    testWidgets('取元数据失败（失效稿件 62002）→ 只提示，不 push', (tester) async {
      final api = _FakeApi(
        videoError: const BiliApiException(
          code: 62002,
          message: '稿件不可见',
          path: '/x/web-interface/view',
        ),
      );
      await _pumpSearch(tester, api);
      await _searchVideo(tester, '词');

      await tester.tap(find.text('视频-词'));
      await tester.pumpAndSettle();

      expect(_spy.pushed, isEmpty, reason: '失败不能跳空白播放页');
      expect(find.text('该视频已失效或不可播放（62002）'), findsOneWidget);
      expect(find.text('视频-词'), findsOneWidget, reason: '结果列表原样还在');
    });

    testWidgets('取元数据失败（其它业务码）→ 分类提示，不 push', (tester) async {
      final api = _FakeApi(
        videoError: const BiliApiException(
          code: -404,
          message: '啥都木有',
          path: '/x/web-interface/view',
        ),
      );
      await _pumpSearch(tester, api);
      await _searchVideo(tester, '词');

      await tester.tap(find.text('视频-词'));
      await tester.pumpAndSettle();

      expect(_spy.pushed, isEmpty);
      expect(find.text('获取视频信息失败：啥都木有'), findsOneWidget);
    });

    testWidgets('网络失败 → 「检查网络」提示，不 push', (tester) async {
      // 用只抛 DioException 的假接口模拟断网
      await _pumpSearch(tester, _ThrowingNetworkApi());
      await _searchVideo(tester, '词');

      await tester.tap(find.text('视频-词'));
      await tester.pumpAndSettle();

      expect(_spy.pushed, isEmpty);
      expect(find.text('网络请求失败，请检查网络后重试'), findsOneWidget);
    });
  });

  group('番剧/影视结果卡：点整卡直接看首集', () {
    testWidgets('点番剧卡 → fetchPgcSeason → 首集 → push PlayerPage（不写白名单）',
        (tester) async {
      final api = _FakeApi();
      final github = await _pumpSearch(tester, api);
      await _searchVideo(tester, '词');
      await tester.tap(find.widgetWithText(ChoiceChip, '番剧'));
      await tester.pumpAndSettle();
      expect(find.text('季-词'), findsOneWidget);

      await tester.tap(find.text('季-词'));

      final page = _builtPlayer(tester, _onlyPushedRoute());
      expect(api.pgcSeasonIds, [555], reason: '用 seasonId 取季');
      expect(page.video.bvid, 'BVep1', reason: '取**首集**，不是替用户挑免费集');
      expect(page.video.cid, 1001);
      expect(page.video.epId, 101, reason: 'epId 要写进去：会员集播放在播放页据此回退 pgc 取流');
      expect(page.video.title, '季-词 第1话 第一话副标题');
      expect(find.text('导入'), findsOneWidget, reason: '尾部「导入」按钮原样');

      expect(github.hasConfigCalls, 0, reason: '点整卡不该走「整季导入」那条写路径');
      expect(github.saveCalls, 0);
    });

    testWidgets('整季取不到可播集（episodes 为空）→ 只提示，不跳空白页', (tester) async {
      final api = _FakeApi(
        season: const PgcSeason(
          title: '季-词',
          cover: '',
          seasonId: 555,
          episodes: [],
        ),
      );
      await _pumpSearch(tester, api);
      await _searchVideo(tester, '词');
      await tester.tap(find.widgetWithText(ChoiceChip, '番剧'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('季-词'));
      await tester.pumpAndSettle();

      expect(_spy.pushed, isEmpty);
      expect(find.text('「季-词」暂时取不到可播放的剧集'), findsOneWidget);
    });

    testWidgets('取季失败（已下架 -404）→ 分类提示，不 push', (tester) async {
      final api = _FakeApi(
        seasonError: const BiliApiException(
          code: -404,
          message: '剧集不存在或已下架',
          path: '/pgc/view/web/season',
        ),
      );
      await _pumpSearch(tester, api);
      await _searchVideo(tester, '词');
      await tester.tap(find.widgetWithText(ChoiceChip, '番剧'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('季-词'));
      await tester.pumpAndSettle();

      expect(_spy.pushed, isEmpty);
      expect(find.text('获取剧集信息失败：剧集不存在或已下架'), findsOneWidget);
    });
  });

  group('卡片提示文案', () {
    testWidgets('视频卡与番剧卡都带一句「直接看 ›」（不另起一行，卡高不变）',
        (tester) async {
      await _pumpSearch(tester, _FakeApi());
      await _searchVideo(tester, '词');
      expect(find.text('直接看'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, '番剧'));
      await tester.pumpAndSettle();
      expect(find.text('直接看'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('直播卡的点击行为未被改动（那条用例在 search_tab_switch_test）',
        (tester) async {
      // 本文件只保证不把直播卡的入口碰坏：切到直播范围仍能搜出结果卡
      await _pumpSearch(tester, _LiveOnlyApi());
      await _searchVideo(tester, '游戏');
      await tester.tap(find.widgetWithText(ChoiceChip, '直播'));
      await tester.pumpAndSettle();
      expect(find.text('直播间-游戏'), findsOneWidget);
      expect(find.text('直接看'), findsNothing,
          reason: '直播卡不重复加这句（副信息行已经有主播名 · 在线人数）');
    });
  });
}

/// 只抛网络异常（DioException）的假接口：验「网络失败」这一分支。
class _ThrowingNetworkApi extends _FakeApi {
  @override
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    videoMetaBvids.add(1);
    throw DioException(requestOptions: RequestOptions(path: '/view'));
  }
}

/// 只返回一条直播结果的假接口（验直播卡不受本批次影响）。
class _LiveOnlyApi extends _FakeApi {
  @override
  Future<LiveSearchPageResult> searchLive(String keyword, {int page = 1}) async =>
      const LiveSearchPageResult(
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
