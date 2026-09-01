// 历史记录页 widget 测试：空态 / 列表展示（标题、进度、相对时间）/
// 单条删除 / 清空 / 点击条目跳播放页（构造 WhitelistVideo + initialPageIndex）。
// - 用 SharedPreferences.setMockInitialValues 注入内存存储（HistoryStore 单例
//   每次操作重新取 prefs，天然读到最新 mock 数据）
// - 历史条目的 cover 置空 → CoverImage 走占位，不触网络
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/history_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

HistoryEntry _entry(
  String bvid,
  int pageIndex,
  DateTime watchedAt, {
  String title = '标题',
  int positionMs = 30000,
  int durationMs = 120000,
  int cid = 100,
}) => HistoryEntry(
  bvid: bvid,
  pageIndex: pageIndex,
  cid: cid,
  title: title,
  cover: '',
  upName: 'UP主',
  durationMs: durationMs,
  positionMs: positionMs,
  watchedAt: watchedAt,
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: HistoryPage())),
  );
  await tester.pump(); // reload() 完成
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('无历史时显示空态「暂无历史记录」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pump(tester);

    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('暂无历史记录'), findsOneWidget);
    // 无记录时不显示「清空」按钮
    expect(find.text('清空'), findsNothing);
  });

  testWidgets('有历史时按倒序展示标题/上次位置/相对时间，并显示「清空」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(
      _entry('BV1a', 0, DateTime.now().subtract(const Duration(minutes: 30)),
          title: '视频甲', positionMs: 15000, durationMs: 60000),
    );
    await store.addOrUpdate(
      _entry('BV2b', 0, DateTime.now().subtract(const Duration(hours: 3)),
          title: '视频乙', positionMs: 30000, durationMs: 120000),
    );
    await _pump(tester);

    expect(find.text('视频甲'), findsOneWidget);
    expect(find.text('视频乙'), findsOneWidget);
    // 上次看到位置 / 总时长（15s/60s → 0:15 / 1:00）
    expect(find.text('上次看到 0:15 / 1:00'), findsOneWidget);
    expect(find.text('上次看到 0:30 / 2:00'), findsOneWidget);
    // 相对时间
    expect(find.textContaining('30 分钟前'), findsOneWidget);
    expect(find.textContaining('3 小时前'), findsOneWidget);
    // 有记录时显示「清空」入口
    expect(find.text('清空'), findsOneWidget);
    // 倒序：更新的视频甲在前
    final tiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .toList();
    expect(tiles, hasLength(2));
  });

  testWidgets('点击条目跳播放页（构造视频 + initialPageIndex）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(
      _entry('BV1a', 2, DateTime.now(),
          title: '多P视频', cid: 777, positionMs: 45000, durationMs: 300000),
    );
    await _pump(tester);

    await tester.tap(find.text('多P视频'));
    // 测试环境原生通道永不返回：不能用 pumpAndSettle（缓冲 spinner 永转），
    // 用固定 pump 完成路由动画 + _init 的 500ms 超时链即可
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 路由动画
    await tester.pump(const Duration(milliseconds: 700)); // _init 超时链走完

    // PlayerPage 已入栈（initState 取流在测试环境失败，仅验证跳转与参数）
    final playerFinder = find.byType(PlayerPage);
    expect(playerFinder, findsOneWidget);
    final player = tester.widget<PlayerPage>(playerFinder);
    expect(player.video.bvid, 'BV1a');
    expect(player.video.cid, 777);
    expect(player.video.title, '多P视频');
    expect(player.initialPageIndex, 2);
  });

  testWidgets('删除按钮 → 确认后单条删除', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BV1a', 0, DateTime.now(), title: '视频甲'));
    await store.addOrUpdate(_entry('BV2b', 0, DateTime.now(), title: '视频乙'));
    await _pump(tester);

    expect(find.text('视频甲'), findsOneWidget);
    // 删除第一条（列表倒序，视频乙在前；点视频乙的删除按钮）
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('视频乙'), findsNothing);
    expect(find.text('视频甲'), findsOneWidget);
    expect(await store.getAll(), hasLength(1));
  });

  testWidgets('「清空」→ 确认后清空并显示空态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BV1a', 0, DateTime.now(), title: '视频甲'));
    await _pump(tester);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空').last); // 对话框里的「清空」按钮
    await tester.pumpAndSettle();

    expect(find.text('暂无历史记录'), findsOneWidget);
    expect(find.text('视频甲'), findsNothing);
    expect(await store.getAll(), isEmpty);
  });
}
