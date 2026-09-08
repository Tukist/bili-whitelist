// 该日历史页（DailyHistoryPage）测试：日期过滤纯函数 + 页面渲染
// （只显示该日条目 / 空态「该日无观看记录」/ 点击条目跳播放页续播）。
// - HistoryStore 用 SharedPreferences mock 注入
// - 条目 cover 置空 → CoverImage 占位不触网络
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/daily_history_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

HistoryEntry _entry(
  String bvid,
  DateTime watchedAt, {
  String title = '标题',
  int pageIndex = 0,
  int cid = 100,
  int positionMs = 30000,
  int durationMs = 120000,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('historyEntriesOnDay（按本地日期过滤，纯函数）', () {
    final day = DateTime(2026, 9, 8, 12, 30); // 当天任意时刻
    final sameDay = [
      _entry('BV1', DateTime(2026, 9, 8, 0, 1), title: '当天0点'),
      _entry('BV2', DateTime(2026, 9, 8, 23, 59), title: '当天23:59'),
    ];
    final otherDays = [
      _entry('BV3', DateTime(2026, 9, 7, 23, 59), title: '前一天23:59'),
      _entry('BV4', DateTime(2026, 9, 9, 0, 1), title: '后一天0点'),
      _entry('BV5', DateTime(2025, 1, 1, 12, 0), title: '一年前'),
    ];

    test('只保留当天（yyyy-MM-dd 一致），跨日 0 点分界正确', () {
      final hit = historyEntriesOnDay([...otherDays, ...sameDay], day);
      expect(hit.map((e) => e.title), ['当天0点', '当天23:59']);
      expect(historyWatchedOnDay(_entry('BVx', DateTime(2026, 9, 8, 23, 59)),
          day), isTrue);
      expect(historyWatchedOnDay(
          _entry('BVx', DateTime(2026, 9, 9, 0, 1)), day), isFalse);
    });

    test('空输入/当天无记录 → 空列表', () {
      expect(historyEntriesOnDay(const [], day), isEmpty);
      expect(historyEntriesOnDay(otherDays, day), isEmpty);
    });
  });

  group('DailyHistoryPage 页面', () {
    final day = DateTime.now(); // 以"今天"为页（热力点今日格场景）

    testWidgets('只显示该日历史条目（标题/进度行），不含其他日', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = HistoryStore.instance;
      await store.addOrUpdate(
          _entry('BV1', day, title: '今天看的甲', positionMs: 15000));
      await store.addOrUpdate(_entry(
          'BV2', day.subtract(const Duration(days: 1)),
          title: '昨天看的乙'));
      await store.addOrUpdate(_entry(
          'BV3', day.add(const Duration(days: 1)),
          title: '明天看的丙'));

      await tester.pumpWidget(
        MaterialApp(home: DailyHistoryPage(date: day)),
      );
      await tester.pumpAndSettle();

      expect(find.text('今天看的甲'), findsOneWidget);
      expect(find.text('上次看到 0:15 / 2:00'), findsOneWidget);
      expect(find.text('昨天看的乙'), findsNothing);
      expect(find.text('明天看的丙'), findsNothing);
    });

    testWidgets('当天无记录 → 空态「该日无观看记录」+ 日期', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(home: DailyHistoryPage(date: DateTime(2026, 9, 8))),
      );
      await tester.pumpAndSettle();

      expect(find.text('该日无观看记录'), findsOneWidget);
      expect(find.text('2026-09-08'), findsOneWidget);
    });

    testWidgets('点击条目 → 跳播放页（构造视频 + initialPageIndex）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = HistoryStore.instance;
      await store.addOrUpdate(_entry('BV1a', day,
          title: '多P视频', pageIndex: 2, cid: 777, positionMs: 45000));

      await tester.pumpWidget(
        MaterialApp(home: DailyHistoryPage(date: day)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('多P视频'));
      // 测试环境原生通道永不返回：固定 pump 完成路由动画 + _init 超时链
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 700));

      final playerFinder = find.byType(PlayerPage);
      expect(playerFinder, findsOneWidget);
      final player = tester.widget<PlayerPage>(playerFinder);
      expect(player.video.bvid, 'BV1a');
      expect(player.video.cid, 777);
      expect(player.initialPageIndex, 2);
    });
  });
}
