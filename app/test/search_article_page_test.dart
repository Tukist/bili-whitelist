// 搜索页「专栏」范围（v2.61.0+）widget 测试：
// - 范围 chip 里有「专栏」；切过去即搜（search_type=article），排序 chip 照常
//   显示（实测专栏接口支持 order —— 不隐藏真功能，也不给假档位）
// - 列表项：清洗后的标题 / 作者 · 阅读 · 日期 / 摘要；无封面走占位图
// - 点结果卡 → push 既有专栏阅读页 [ArticlePage]，参数是 cv 号 + 标题 + 同一
//   个注入的 api（**不新写阅读页**）
// - 分页：底部触底追加 page=2，按 cv 号去重，到底显示「没有更多了」
// - 空态 / 失败态（含风控文案）互不串味
//
// 接口全部走内存替身（不触网）；push 断言沿用 search_tab_switch_test 的直播
// 用例：**刻意不 pump**，只从路由里取出 widget 检查参数（真建出来会拉专栏
// 正文 + 评论，那不是本用例要验的东西）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/article_search_result.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/article_page.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/services/search_history_store.dart';
import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';

// ---------------------------------------------------------------------------
// 替身
// ---------------------------------------------------------------------------

/// 假 B 站接口：专栏分支可编程（分页数据 / 异常），并记录每次请求的参数。
class _FakeBiliApi extends BiliApi {
  /// 记录到的请求（keyword, page, order）。
  final List<({String keyword, int page, String order})> articleCalls = [];

  /// 第 N 页返回的结果；null = 用默认（3 条 / 无更多）。
  final Map<int, List<ArticleSearchResult>> pages = {};

  /// 请求时要抛的异常（null = 不抛）。
  BiliApiException? error;

  /// 每页是否还有更多（缺省按 [pages] 里有没有下一页判断）。
  bool? hasMoreOverride;

  @override
  Future<ArticleSearchPageResult> searchArticle(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async {
    articleCalls.add((keyword: keyword, page: page, order: order));
    if (error != null) throw error!;
    final list = pages[page] ?? _defaultPage(page, keyword);
    final hasMore = hasMoreOverride ?? pages.containsKey(page + 1);
    return ArticleSearchPageResult(
      results: list,
      totalCount: 99,
      hasMore: hasMore,
    );
  }

  static List<ArticleSearchResult> _defaultPage(int page, String keyword) => [
        for (var i = 0; i < 3; i++)
          ArticleSearchResult(
            cvid: page * 100 + i,
            title: '专栏-$keyword-$page-$i',
            desc: '摘要 $page-$i',
            author: '作者$page$i',
            cover: '',
            view: 12345,
            like: 10,
            pubDate: 1717248600,
            category: '手机游戏',
          ),
      ];

  // 其它分支不该被点到：真的被调到时直接判失败（返回空结果即可，
  // 断言层看 articleCalls / 结果文本）。
  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async =>
      const SearchPageResult(results: [], totalCount: 0, hasMore: false);
}

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

class _PushSpy extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

final _pushSpy = _PushSpy();

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Future<void> _pumpSearch(WidgetTester tester, BiliApi api) async {
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: [_pushSpy],
    home: SearchPage(
      syncService: _FakeSyncService(),
      historyStore: SearchHistoryStore(),
      api: api,
    ),
  ));
  await tester.pumpAndSettle();
  _pushSpy.pushed.clear();
}

/// 输入关键词并等过防抖（600ms）。
Future<void> _searchByDebounce(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField).first, keyword);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
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

  testWidgets('范围 chip 有「专栏」；切过去即按 search_type=article 搜索',
      (tester) async {
    final api = _FakeBiliApi();
    await _pumpSearch(tester, api);

    // 视频范围先搜一次（同时验证切范围会重查）
    await _searchByDebounce(tester, '原神');
    expect(api.articleCalls, isEmpty, reason: '视频范围不该打专栏接口');

    expect(find.widgetWithText(ChoiceChip, '专栏'), findsOneWidget);

    await _tapScope(tester, '专栏');

    expect(api.articleCalls, hasLength(1));
    expect(api.articleCalls.single.keyword, '原神');
    expect(api.articleCalls.single.page, 1);
    expect(api.articleCalls.single.order, 'totalrank');
    // 列表出来了（标题带关键词）
    expect(find.text('专栏-原神-1-0'), findsOneWidget);
  });

  testWidgets('专栏范围照常显示排序 chip 且切换会带 order 重查（实测支持）',
      (tester) async {
    final api = _FakeBiliApi();
    await _pumpSearch(tester, api);
    await _searchByDebounce(tester, '原神');
    await _tapScope(tester, '专栏');

    // 排序行在（不是假功能：接口实测支持 order）
    expect(find.widgetWithText(ChoiceChip, '最多播放'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '最新发布'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '最多播放'));
    await tester.pumpAndSettle();

    expect(api.articleCalls, hasLength(2));
    expect(api.articleCalls.last.order, 'click', reason: 'order 要透传给接口');
    expect(api.articleCalls.last.page, 1, reason: '换排序 = 从第 1 页重查');
  });

  testWidgets('列表项：标题 / 作者 · 阅读 / 摘要', (tester) async {
    final api = _FakeBiliApi();
    await _pumpSearch(tester, api);
    await _searchByDebounce(tester, '原神');
    await _tapScope(tester, '专栏');

    expect(find.text('专栏-原神-1-0'), findsOneWidget);
    // 副信息行：作者 · 1.2万 阅读 · 日期（1.2万 = 12345 的既有格式）
    expect(find.textContaining('作者10'), findsOneWidget);
    expect(find.textContaining('1.2万 阅读'), findsWidgets);
    expect(find.text('摘要 1-0'), findsOneWidget);
  });

  testWidgets('点结果卡 → push ArticlePage(cvid/initialTitle/api)，不写白名单',
      (tester) async {
    final api = _FakeBiliApi();
    await _pumpSearch(tester, api);
    await _searchByDebounce(tester, '原神');
    await _tapScope(tester, '专栏');

    await tester.tap(find.text('专栏-原神-1-0'));

    // 刻意不 pump：push 已发生，新路由还没建（建出来会拉正文/评论）
    final route = _pushSpy.pushed.single as MaterialPageRoute<void>;
    final page =
        route.builder(tester.element(find.byType(SearchPage))) as ArticlePage;
    expect(page.cvid, 100, reason: 'cv 号来自搜索结果的 id');
    expect(page.initialTitle, '专栏-原神-1-0');
    expect(page.api, same(api), reason: '复用本页会话（同一个注入替身）');
  });

  testWidgets('上拉触底 → 追加 page=2 并按 cv 号去重，到底显示「没有更多了」',
      (tester) async {
    final api = _FakeBiliApi();
    // 第 1 页给 20 条（撑出滚动范围），第 2 页给 3 条（其中 1 条与第 1 页
    // 重复，用来验去重）
    api.pages[1] = [
      for (var i = 0; i < 20; i++)
        ArticleSearchResult(
          cvid: 1000 + i,
          title: '第1页-$i',
          desc: '',
          author: 'A',
          cover: '',
          view: 1,
          like: 0,
          pubDate: 0,
          category: '',
        ),
    ];
    api.pages[2] = [
      ArticleSearchResult(
        cvid: 1000, // 与第 1 页重复 → 必须被丢弃
        title: '重复条目',
        desc: '',
        author: 'A',
        cover: '',
        view: 1,
        like: 0,
        pubDate: 0,
        category: '',
      ),
      for (var i = 0; i < 2; i++)
        ArticleSearchResult(
          cvid: 2000 + i,
          title: '第2页-$i',
          desc: '',
          author: 'B',
          cover: '',
          view: 1,
          like: 0,
          pubDate: 0,
          category: '',
        ),
    ];

    await _pumpSearch(tester, api);
    await _searchByDebounce(tester, '原神');
    await _tapScope(tester, '专栏');
    expect(api.articleCalls, hasLength(1));

    // 上拉触底（距底部 ≤200px 触发）
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(api.articleCalls.map((c) => c.page), [1, 2],
        reason: '触底只翻一页，且 page 递增');
    expect(find.text('第2页-0'), findsOneWidget);
    expect(find.text('重复条目'), findsNothing, reason: '按 cv 号去重');

    // 第 2 页之后 hasMore=false → 底部「没有更多了」
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(api.articleCalls, hasLength(2), reason: '没有更多了就别再请求');
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('空结果 → 「没有找到相关专栏」（不是失败态）', (tester) async {
    final api = _FakeBiliApi();
    api.pages[1] = const [];
    await _pumpSearch(tester, api);
    await _searchByDebounce(tester, 'zzz');
    await _tapScope(tester, '专栏');

    expect(find.text('没有找到相关专栏，换个关键词试试'), findsOneWidget);
    expect(find.textContaining('搜索失败'), findsNothing);
  });

  testWidgets('风控/接口失败 → 失败态 + 重试，且不冒充空态', (tester) async {
    final api = _FakeBiliApi();
    api.error = const BiliApiException(
      code: -412,
      message: '专栏搜索触发风控校验，请稍后重试',
      path: '/x/web-interface/wbi/search/type',
    );
    await _pumpSearch(tester, api);
    await _searchByDebounce(tester, '原神');
    await _tapScope(tester, '专栏');

    expect(find.textContaining('专栏搜索触发风控校验'), findsOneWidget);
    expect(find.text('没有找到相关专栏，换个关键词试试'), findsNothing,
        reason: '风控不能被渲染成「没有相关专栏」');

    // 重试按钮：清掉异常后再点 → 出结果
    api.error = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('专栏-原神-1-0'), findsOneWidget);
  });
}
