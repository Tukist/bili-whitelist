// 电脑端（估算）时长并入热力图（v2.66.0）· 展示层测试：
// 每日总值 = 本机实测 + 电脑端估算；只有电脑端的那天也出现在热力里；
// 每日详情页显示「本机 … · 电脑端（估算）…」并标"估算"；颜色按总和走既有
// 相对色阶（不另造一套）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/daily_history_page.dart';
import 'package:bili_whitelist_app/pages/watch_stats_page.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/services/remote_watch_stats.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';
import 'package:bili_whitelist_app/theme/app_palette.dart';

RemoteWatchStats _pcStore() {
  final s = RemoteWatchStats();
  s.clock = () => DateTime.now();
  return s;
}

RemoteWatchSample _sample(DateTime local, int seconds, {String bvid = 'BV1'}) =>
    RemoteWatchSample(
      bvid: bvid,
      pageIndex: 0,
      viewAtSec: local.millisecondsSinceEpoch ~/ 1000,
      seconds: seconds,
    );

HistoryEntry _entry(String bvid, DateTime watchedAt) => HistoryEntry(
      bvid: bvid,
      pageIndex: 0,
      cid: 100,
      title: '标题',
      cover: '',
      upName: 'UP主',
      durationMs: 120000,
      positionMs: 30000,
      watchedAt: watchedAt,
    );

/// 取热力格的底色（格子 key 挂在 GestureDetector 上，Container 是它的子节点）。
Color? _cellColor(WidgetTester tester, String dateKey) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byKey(ValueKey('heatcell-$dateKey')),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration as BoxDecoration).color;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dailyWatchSplitText（详情页拆分文案）', () {
    test('本机 + 电脑端都写清，并标明电脑端是估算', () {
      expect(
        dailyWatchSplitText(localSeconds: 2520, remoteSeconds: 1080),
        '本机 42 分钟 · 电脑端（估算）18 分钟',
      );
    });

    test('电脑端为 0（估算不出来）→ 显示 —，不编数', () {
      expect(
        dailyWatchSplitText(localSeconds: 300, remoteSeconds: 0),
        '本机 5 分钟 · 电脑端（估算）—',
      );
    });

    test('只有电脑端数据（本机 0）→ 本机如实写 0 秒', () {
      expect(
        dailyWatchSplitText(localSeconds: 0, remoteSeconds: 1080),
        '本机 0 秒 · 电脑端（估算）18 分钟',
      );
    });
  });

  group('热力图合并（总值 = 本机 + 电脑端，颜色按总和）', () {
    final today = DateTime(2026, 9, 8, 20);

    test('合并后的秒数进格子；只有电脑端的那天也有秒数', () {
      final merged = mergeDailySeconds(
        {'2026-09-08': 600},
        {'2026-09-08': 600, '2026-09-01': 1800},
      );
      final grid = buildHeatmapGrid(merged, today);
      final cells = <String, int>{};
      for (final col in grid) {
        for (final c in col) {
          if (c != null) cells[WatchStats.dateKey(c.date)] = c.seconds;
        }
      }
      expect(cells['2026-09-08'], 1200, reason: '本机 600 + 电脑端 600');
      expect(cells['2026-09-01'], 1800, reason: '只有电脑端的那天也要出现在热力里');
      expect(maxDaySecondsOfGrid(grid), 1800);
    });

    test('同样本机 600 的两天：电脑端补了 600 的那天明显更深', () {
      final local = {'2026-09-08': 600, '2026-09-07': 600};
      final merged = mergeDailySeconds(local, {'2026-09-08': 600});
      final max = maxDaySecondsOfGrid(buildHeatmapGrid(merged, today));
      final palette = AppPalette.fallback;
      final deep = heatColorForIntensity(
        WatchStats.relativeIntensity(merged['2026-09-08']!, max),
        palette,
      );
      final shallow = heatColorForIntensity(
        WatchStats.relativeIntensity(merged['2026-09-07']!, max),
        palette,
      );
      expect(deep, isNot(shallow), reason: '颜色深浅按总和算');
      expect(deep, palette.inkDeco, reason: '合并后最长的那天 = 最深档');
    });
  });

  group('WatchStatsPage：热力含电脑端', () {
    testWidgets('只有电脑端数据的一天也画进热力（不是空态）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final stats = WatchStats();
      await stats.record(600, at: now); // 本机今天 10 分钟
      final remote = _pcStore();
      final remoteOnlyDay = now.subtract(const Duration(days: 3));
      await remote.recordAll([
        _sample(now, 600, bvid: 'BVtoday'), // 今天电脑端也 10 分钟
        _sample(remoteOnlyDay, 1800, bvid: 'BVold'), // 只有电脑端
      ]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats, remote: remote)),
      ));
      await tester.pumpAndSettle();

      // 有数据 → 不是空态卡；并且明确写了"含电脑端观看（估算）"
      expect(find.text('开始观看后这里会生成你的观看热力'), findsNothing);
      expect(find.textContaining('含电脑端观看'), findsOneWidget);
      expect(find.textContaining('估算'), findsWidgets);

      // 颜色按总和：今天 = 1200 / 最长 1800 → 中间档；只有电脑端那天 = 最深档
      final palette = AppPalette.fallback;
      expect(
        _cellColor(tester, WatchStats.dateKey(now)),
        heatColorForIntensity(1200 / 1800, palette),
      );
      expect(
        _cellColor(tester, WatchStats.dateKey(remoteOnlyDay)),
        palette.inkDeco,
        reason: '只有电脑端的那天也按总和着色（当天最长 → 最深）',
      );
    });

    testWidgets('总览数字也含电脑端（今日/累计与热力一致）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final stats = WatchStats(); // 本机没有任何记录
      final remote = _pcStore();
      await remote.recordAll([_sample(now, 1800)]);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats, remote: remote)),
      ));
      await tester.pumpAndSettle();

      // 30 分钟 → 总览卡显示「30 分钟」（本机 0 也说 30，因为热力图是合并口径；
      // 总览卡是 Text.rich，按富文本匹配）
      expect(find.textContaining('30', findRichText: true), findsWidgets);
      expect(find.textContaining('分钟'), findsWidgets);
      expect(find.text('开始观看后这里会生成你的观看热力'), findsNothing);
    });
  });

  group('DailyHistoryPage：当天时长拆分', () {
    testWidgets('本机 + 电脑端都显示，且注明电脑端是估算', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final stats = WatchStats();
      await stats.record(2520, at: now); // 42 分钟
      final remote = _pcStore();
      await remote.recordAll([_sample(now, 1080)]); // 18 分钟
      await HistoryStore.instance
          .addOrUpdate(_entry('BV1', now)); // 有条目 → 走列表分支

      await tester.pumpWidget(MaterialApp(
        home: DailyHistoryPage(date: now, stats: stats, remote: remote),
      ));
      await tester.pumpAndSettle();

      expect(find.text('当天观看时长'), findsOneWidget);
      expect(
        find.text('本机 42 分钟 · 电脑端（估算）18 分钟'),
        findsOneWidget,
      );
      expect(find.textContaining('电脑端为估算'), findsOneWidget);
    });

    testWidgets('只有电脑端、没有本机历史条目 → 显示拆分 + 说明（不是空态白屏）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      final remote = _pcStore();
      await remote.recordAll([_sample(now, 900)]); // 15 分钟，只有电脑端

      await tester.pumpWidget(MaterialApp(
        home: DailyHistoryPage(date: now, remote: remote, stats: WatchStats()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('本机 0 秒 · 电脑端（估算）15 分钟'), findsOneWidget);
      expect(find.textContaining('当天没有本机观看记录'), findsOneWidget);
      expect(find.text('该日无观看记录'), findsNothing);
    });

    testWidgets('两个来源都没有数据 → 保持原空态（不摆 0）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final day = DateTime(2026, 9, 8);

      await tester.pumpWidget(MaterialApp(
        home: DailyHistoryPage(
          date: day,
          stats: WatchStats(),
          remote: _pcStore(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('该日无观看记录'), findsOneWidget);
      expect(find.text('当天观看时长'), findsNothing);
    });
  });
}
