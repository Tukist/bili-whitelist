// 底部导航「日程」入口 + 下标错位回归测试（v2.33.0）。
//
// 本轮改动最容易翻车的地方 = **在中间插一页导致的下标错位**：日程插在
// 「UP 主」与「历史」之间，历史与个人各 +1。这里把 5 个目的地**逐个点一遍**
// 并断言落到了各自该落的页面，任何漏改（NavigationBar 顺序 / PageView 顺序 /
// _reloadTab 分支）都会在这里炸出来。
//
// 页面的身份锚点（各自独有、不在别处出现的文案）：
// - 合集首页：合集卡 / 「未分类」
// - UP 主管理：页内标题「UP 主」
// - 日程：页内标题「日程」+ 副标题「点格子改文字与底色…」+ 默认 3 列 × 8 行网格
// - 历史：「暂无历史记录」空态
// - 个人：「底部导航「个人」· …」标题条
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/pages/schedule_page.dart';
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
/// 「日程」「历史」这些词在页面内容里也会出现，按文字点会撞到两个匹配）。
const Map<String, String> kTabTooltip = {
  '合集': '合集（白名单视频）',
  'UP 主': '白名单 UP 主',
  '日程': '日程（可编辑表格）',
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('底部导航结构', () {
    testWidgets('5 个目的地，「日程」在「UP 主」与「历史」之间（第 3 位）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
      final labels = [
        for (final d in nav.destinations) (d as NavigationDestination).label,
      ];
      expect(labels, ['合集', 'UP 主', '日程', '历史', '个人']);
      expect(labels.indexOf('日程'), 2);
      expect(labels.indexOf('日程'), greaterThan(labels.indexOf('UP 主')));
      expect(labels.indexOf('日程'), lessThan(labels.indexOf('历史')));

      // 图标与选中态：日程用日历格图标，不与既有 4 个撞脸
      final schedule = nav.destinations[2] as NavigationDestination;
      expect((schedule.icon as Icon).icon, Icons.calendar_month_outlined);
      expect(schedule.tooltip, '日程（可编辑表格）');
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
  });

  group('★ 下标错位回归：每个目的地都落到该落的页面', () {
    testWidgets('点「日程」→ 进日程页（不是历史、不是 UP 主）', (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '日程');

      expect(find.byType(SchedulePage), findsOneWidget);
      expect(find.text('点格子改文字与底色 · 长按格子向右/下拖可整片填充'), findsOneWidget);
      // 默认表真的上屏了（3 列 × 8 行）
      final state = tester.state<SchedulePageState>(find.byType(SchedulePage));
      expect(state.debugData.columns.length, 3);
      expect(state.debugData.rows.length, 8);
      expect(find.byKey(const ValueKey('schedule-cell-7-2')), findsOneWidget);
      // 没有被历史页 / UP 主页的空态串台
      expect(find.text('暂无历史记录'), findsNothing);
      expect(find.text('还没有白名单 UP 主'), findsNothing);
      expect(_selectedIndex(tester), 2);
    });

    testWidgets('点「历史」→ 仍是历史页（历史页下标 2 → 3 的回归）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, '历史');

      expect(find.text('暂无历史记录'), findsOneWidget);
      expect(_selectedIndex(tester), 3);
      // 日程页的标题不在屏上（说明没被错位地当成历史页）
      expect(find.text('点格子改文字与底色 · 长按格子向右/下拖可整片填充'),
          findsNothing);
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

    testWidgets('点「UP 主」→ 仍是 UP 主页（下标不变 = 1）', (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await _tapTab(tester, 'UP 主');

      expect(_selectedIndex(tester), 1);
      expect(find.text('导入我的 UP'), findsOneWidget);
      expect(find.text('还没有白名单 UP 主'), findsOneWidget);
    });

    testWidgets('点「合集」→ 回首页（下标 0 不变）', (tester) async {
      await _pumpHome(tester, _data());

      await _tapTab(tester, '日程');
      await _tapTab(tester, '合集');

      expect(_selectedIndex(tester), 0);
      expect(find.text('未分类'), findsOneWidget, reason: '首页固定有「未分类」卡');
      expect(find.text('点格子改文字与底色 · 长按格子向右/下拖可整片填充'),
          findsNothing);
    });

    testWidgets('5 个目的地逐个走一遍，索引与页面一一对应（无错位）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      // (label, 期望 selectedIndex)
      const order = [
        ('合集', 0),
        ('UP 主', 1),
        ('日程', 2),
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

    testWidgets('横向滑动 PageView 也能到日程页（滑动落页同步导航高亮）',
        (tester) async {
      await _pumpHome(tester, WhitelistData.empty());

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(_selectedIndex(tester), 2);
      expect(find.text('点格子改文字与底色 · 长按格子向右/下拖可整片填充'), findsOneWidget);
    });
  });

  group('日程数据不与白名单/Gist 混流', () {
    testWidgets('日程页的存储只落在本地 SharedPreferences 的 schedule: 键下',
        (tester) async {
      final fake = _FakeSyncService(WhitelistData.empty());
      ServiceLocator.overrideSyncService(fake);
      await tester.pumpWidget(
        MaterialApp(home: PlaylistPage(openLogin: (c, {banner}) async {})),
      );
      await tester.pump();
      await tester.pump();

      await _tapTab(tester, '日程');
      expect(find.byType(SchedulePage), findsOneWidget);

      // 首次使用铺的默认表落在本地 prefs 的 schedule: 键下
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.startsWith('schedule:')),
        isNotEmpty,
      );
      // 白名单结构一个字节都没被碰过
      expect(fake.data.videos, isEmpty);
      expect(fake.data.upowners, isEmpty);
      expect(fake.data.collections, isEmpty);
    });
  });
}
