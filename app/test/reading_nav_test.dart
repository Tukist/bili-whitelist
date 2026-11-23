// 底部导航「阅读」入口 + 下标错位回归测试（v2.69.0）。
//
// 本文件取代原 `schedule_nav_test.dart`：底部导航第 3 项由「日程」换成
// 「阅读」，原日程页迁到「个人 → 设置 → 打开日程」。**覆盖项一条没减**，
// 只把「日程」的认同锚点换成了「阅读」的，并新增一条「日程入口仍在、
// 点进去还是原来那套网格」的迁移回归（原文件里的日程断言不能就这么没了）。
//
// 本轮改动最容易翻车的地方 = **换页签导致的错位**：日程/阅读都在下标 2，
// 历史(3)/个人(4) 不能被带偏。这里把 5 个目的地**逐个点一遍**并断言落到了
// 各自该落的页面，任何漏改（NavigationBar 顺序 / PageView 顺序 /
// _reloadTab 分支）都会在这里炸出来。
//
// 页面的身份锚点（各自独有、不在别处出现的文案）：
// - 合集首页：合集卡 / 「未分类」
// - 推荐：页内标题「推荐」+ 空历史文案「先看几个视频，这里会生成你的兴趣标签」
// - 阅读：页内计数行「已导入 0 个书源」+ 书架空态「书架还是空的」
// - 历史：「暂无历史记录」空态
// - 个人：「底部导航「个人」· …」标题条
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/book_source_page.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/pages/reading_page.dart';
import 'package:bili_whitelist_app/pages/schedule_page.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 假同步服务：返回固定数据，不触发任何原生插件/网络。
class _FakeSyncService extends WhitelistSyncService {
  final WhitelistData data;

  _FakeSyncService(this.data) : super(dio: Dio());

  @override
  Future<SyncResult> sync() async => SyncResult(
    data: data,
    sourceName: 'fake',
    fetchedAt: DateTime(2026, 1, 1),
    fromNetwork: false,
  );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 一张有 1 个视频的白名单（首页的「未分类」卡是 `_hasData` 为真时才铺的，
/// 空数据首页走的是空态，所以这里必须给点内容才能锚定"这是首页"）。
WhitelistData _data() => WhitelistData(
  version: WhitelistData.currentVersion,
  updatedAt: '2026-08-20T00:00:00Z',
  videos: const [
    WhitelistVideo(
      bvid: 'BV1test',
      cid: 100,
      title: '测试视频',
      cover: '',
      duration: 90,
      upName: 'UP主',
      addedAt: '2026-08-01T00:00:00Z',
    ),
  ],
);

Future<void> _pumpHome(WidgetTester tester, WhitelistData data) async {
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(
    MaterialApp(
      // 测试环境没有 WebView 原生通道，真推登录页会 assert → 注入替身
      home: PlaylistPage(openLogin: (context, {banner}) async {}),
    ),
  );
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump();
}

/// 底部导航 5 个目的地的 tooltip（**按 tooltip 点，不按 label 文字点**：
/// 「阅读」「历史」这些词在页面内容里也会出现，按文字点会撞到两个匹配）。
const Map<String, String> kTabTooltip = {
  '合集': '合集（白名单视频）',
  // v2.68.0：第 2 项由「UP 主」换成「推荐」（UP 主管理迁到设置区）
  '推荐': '推荐（按你的兴趣标签）',
  // v2.69.0：第 3 项由「日程」换成「阅读」（日程迁到设置区）
  '阅读': '阅读（书架与书源）',
  '历史': '历史记录',
  '个人': '个人（观看统计 / 设置）',
};

/// 点底部导航第 [label] 个目的地。
Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip(kTabTooltip[label]!));
  await tester.pumpAndSettle();
}

int _selectedIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

/// 阅读页的唯一锚点（书架空态主文案，别处不会出现）。
const String kReadingEmptyTitle = '书架还是空的';

BookSource _src(String name, {bool enabled = true}) => BookSource(
  name: name,
  baseUrl: 'https://$name.example',
  enabled: enabled,
  search: const SearchRule(url: '/s?q={{key}}', list: '.item'),
  toc: const TocRule(list: '.ch', name: '.cn', urlSel: '.cu'),
  content: const ContentRule(text: '#content'),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('底部导航结构', () {
    testWidgets('5 个目的地，「阅读」在「推荐」与「历史」之间（第 3 位）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      final labels = [
        for (final d in nav.destinations) (d as NavigationDestination).label,
      ];
      expect(labels, ['合集', '推荐', '阅读', '历史', '个人']);
      expect(labels.indexOf('阅读'), 2);
      expect(labels.indexOf('阅读'), greaterThan(labels.indexOf('推荐')));
      expect(labels.indexOf('阅读'), lessThan(labels.indexOf('历史')));

      // 图标与选中态：阅读用摊开的书图标，不与既有 4 个撞脸
      final reading = nav.destinations[2] as NavigationDestination;
      expect((reading.icon as Icon).icon, Icons.auto_stories_outlined);
      expect(reading.tooltip, '阅读（书架与书源）');
      // 起始选中态仍是首页（PageController(initialPage: 0)）
      expect(nav.selectedIndex, 0);
    });

    testWidgets('图标各不相同（5 个不重复）', (tester) async {
      await _pumpHome(tester, WhitelistData.empty());
      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      final icons = [
        for (final d in nav.destinations)
          ((d as NavigationDestination).icon as Icon).icon,
      ];
      expect(icons.toSet().length, 5);
    });

    testWidgets('页脚文案列的就是当前 5 个页签（含「阅读」不含「日程」）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());
      expect(
        find.textContaining('底部导航切换：合集 / 推荐 / 阅读 / 历史 / 个人'),
        findsOneWidget,
      );
      expect(find.textContaining('合集 / 推荐 / 日程'), findsNothing);
    });
  });

  group('★ 下标错位回归：每个目的地都落到该落的页面', () {
    testWidgets('点「阅读」→ 进阅读页（不是历史、不是推荐）', (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '阅读');

      expect(find.byType(ReadingPage), findsOneWidget);
      // 书架空态真的上屏了（R1 没有书架数据，这里是诚实的空态）
      expect(find.text(kReadingEmptyTitle), findsOneWidget);
      expect(find.text('导入书源后，在搜索里找书加入书架'), findsOneWidget);
      // 书源计数行读了真实的存储：空存储 = 0
      expect(find.text('已导入 0 个书源'), findsOneWidget);
      // 没有被历史页 / 推荐页的空态串台
      expect(find.text('暂无历史记录'), findsNothing);
      expect(find.text('先看几个视频，这里会生成你的兴趣标签'), findsNothing);
      expect(_selectedIndex(tester), 2);
    });

    testWidgets('阅读页「书源管理」入口能进书源页并返回（页内真入口）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '阅读');
      await tester.tap(find.text('书源管理'));
      await tester.pumpAndSettle();

      // 管理页是独立 Scaffold 路由
      expect(find.byType(BookSourcePage), findsOneWidget);
      expect(find.text('还没有书源'), findsOneWidget);
      expect(find.text('粘贴 legado 格式的书源 JSON 导入'), findsOneWidget);

      // 返回阅读页：页签仍停在第 3 项
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ReadingPage), findsOneWidget);
      expect(_selectedIndex(tester), 2);
    });

    testWidgets('切回阅读页会重读书源条数（_reloadTab → ReadingPageState.reload）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());
      await _tapTab(tester, '阅读');
      expect(find.text('已导入 0 个书源'), findsOneWidget);

      // 模拟「用户在别处导入了两个源」（这里直接写存储，等价于书源页导入完）
      await BookSourceStore.instance.upsertAll([
        _src('甲的源'),
        _src('乙的源', enabled: false),
      ]);

      // 切走再切回来：靠 _reloadTab 的重读把新数字显示出来
      await _tapTab(tester, '历史');
      await _tapTab(tester, '阅读');
      expect(find.text('已导入 2 个书源（启用 1 个）'), findsOneWidget);
    });

    testWidgets('点「历史」→ 仍是历史页（历史页下标 2 → 3 的回归）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '历史');

      expect(find.text('暂无历史记录'), findsOneWidget);
      expect(_selectedIndex(tester), 3);
      // 阅读页的空态不在屏上（说明没被错位地当成历史页）
      expect(find.text(kReadingEmptyTitle), findsNothing);
    });

    testWidgets('点「个人」→ 仍是个人页（下标 3 → 4 的回归）', (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '个人');

      expect(
        find.text('底部导航「个人」· 点日期格看当天观看历史，设置在本页下方'),
        findsOneWidget,
      );
      expect(_selectedIndex(tester), 4);
      expect(find.text('暂无历史记录'), findsNothing);
    });

    testWidgets('点「推荐」→ 进推荐页（下标不变 = 1）', (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '推荐');

      expect(_selectedIndex(tester), 1);
      // 本机没有观看历史 → 推荐页给「先看几个视频」那一种空态（不触网）
      expect(find.text('先看几个视频，这里会生成你的兴趣标签'), findsOneWidget);
      // 原「UP 主」页的内容不再挂在这一页上（迁到设置区的全屏页）
      expect(find.text('导入我的 UP'), findsNothing);
      expect(find.text('还没有白名单 UP 主'), findsNothing);
    });

    testWidgets('点「合集」→ 回首页（下标 0 不变）', (tester) async {
      await _pumpHome(tester, _data());

      await _tapTab(tester, '阅读');
      await _tapTab(tester, '合集');

      expect(_selectedIndex(tester), 0);
      expect(find.text('未分类'), findsOneWidget, reason: '首页固定有「未分类」卡');
      expect(find.text(kReadingEmptyTitle), findsNothing);
    });

    testWidgets('5 个目的地逐个走一遍，索引与页面一一对应（无错位）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      // (label, 期望 selectedIndex)
      const order = [
        ('合集', 0),
        ('推荐', 1),
        ('阅读', 2),
        ('历史', 3),
        ('个人', 4),
      ];
      for (final (label, index) in order) {
        await _tapTab(tester, label);
        expect(_selectedIndex(tester), index,
            reason: '点「$label」后 selectedIndex 应为 $index');
      }
      // 再倒着走一遍，确认来回都稳
      for (final (label, index) in order.reversed) {
        await _tapTab(tester, label);
        expect(_selectedIndex(tester), index,
            reason: '倒序点「$label」后 selectedIndex 应为 $index');
      }
    });

    testWidgets('横向滑动 PageView 也能到阅读页（滑动落页同步导航高亮）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(_selectedIndex(tester), 2);
      expect(find.text(kReadingEmptyTitle), findsOneWidget);
    });
  });

  // ==================== 日程迁移回归（原页签的等价覆盖） ====================
  group('日程迁到「个人 → 设置 → 打开日程」后功能仍在', () {
    /// 滚到设置区里某个文案露出来（设置区在同一页滚动流底部）。
    Future<void> scrollToText(WidgetTester tester, String text) async {
      for (var i = 0; i < 12 && find.text(text).evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      expect(find.text(text), findsWidgets, reason: '设置区里应有「$text」');
    }

    testWidgets('设置区有「打开日程」入口，点进去还是原来那张可编辑网格',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());
      await _tapTab(tester, '个人');
      await scrollToText(tester, '打开日程');

      final entry = find.ancestor(
        of: find.text('打开日程'),
        // OutlinedButton.icon 返回私有子类，find.byType 精确匹配不到
        matching: find.byWidgetPredicate((w) => w is OutlinedButton),
      );
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      // 独立路由：有 Scaffold + AppBar 标题「日程」
      expect(find.byType(SchedulePage), findsOneWidget);
      expect(find.widgetWithText(AppBar, '日程'), findsOneWidget);
      // 原页面的内容照旧：副标题 + 默认 3 列 × 8 行网格 + 末格
      expect(find.text('点格子改文字与底色 · 长按格子向右/下拖可整片填充'), findsOneWidget);
      final state = tester.state<SchedulePageState>(find.byType(SchedulePage));
      expect(state.debugData.columns.length, 3);
      expect(state.debugData.rows.length, 8);
      expect(find.byKey(const ValueKey('schedule-cell-7-2')), findsOneWidget);

      // 返回后回到个人页（不是回到首页/阅读）
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 4);
    });
  });

  group('阅读数据不与白名单/Gist 混流', () {
    testWidgets('阅读页只读本地 reader: 键，且不会再自动铺日程表', (tester) async {
      final fake = _FakeSyncService(WhitelistData.empty());
      ServiceLocator.overrideSyncService(fake);
      await tester.pumpWidget(
        MaterialApp(home: PlaylistPage(openLogin: (c, {banner}) async {})),
      );
      await tester.pump();
      await tester.pump();

      await _tapTab(tester, '阅读');
      expect(find.byType(ReadingPage), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      // 日程页已不在 PageView 里 → 启动/切页都**不该**再往 schedule: 键写默认表
      // （原 schedule_nav_test 断言的是"切到日程页会铺表"，页面搬走之后这条
      //  断言反过来才有意义：不该在用户没打开日程时偷偷写盘）
      expect(
        prefs.getKeys().where((k) => k.startsWith('schedule:')),
        isEmpty,
      );
      // 阅读页本身只读不写：还没导入书源，就不该有 reader: 键
      expect(
        prefs.getKeys().where((k) => k.startsWith('reader:')),
        isEmpty,
      );
      // 白名单结构一个字节都没被碰过
      expect(fake.data.videos, isEmpty);
      expect(fake.data.upowners, isEmpty);
      expect(fake.data.collections, isEmpty);
    });

    testWidgets('已导入的书源条数来自本地 reader:sources（真读存储，不造假）',
        (tester) async {
      // 预置两个源（等价于上一次运行导入过）
      await BookSourceStore.instance.upsertAll([
        _src('甲'),
        _src('乙', enabled: false),
      ]);
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '阅读');
      expect(find.text('已导入 2 个书源（启用 1 个）'), findsOneWidget);
    });
  });
}
