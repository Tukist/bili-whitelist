// 观看统计页（WatchStatsPage）纯函数单测：53 周热力网格构建 /
// 月份标签 / 时长文案；另有页面冒烟（空态 / 有数据热力卡出现）。
// - 网格函数不碰插件，直接断言数据结构
// - 页面冒烟用 shared_preferences mock + 注入 stats 实例
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/watch_stats_page.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildHeatmapGrid（53 周 × 7 行网格）', () {
    final today = DateTime(2026, 9, 8); // 周二

    test('列数 53、每列 7 行（周一..周日）、首列周一是 heatGridStart', () {
      final grid = buildHeatmapGrid(const {}, today);
      expect(grid.length, 53);
      for (final col in grid) {
        expect(col.length, 7);
      }
      expect(grid.first.first!.date, heatGridStart(today));
      expect(grid.first.first!.date.weekday, DateTime.monday);
    });

    test('今天在最右列且行号 = 周几-1；超过今天的未来格为 null', () {
      final grid = buildHeatmapGrid(const {}, today);
      // 最右列 = 本周一..周日
      final rightCol = grid.last;
      // 周二 = row1 是今天，有格子；周三..周日（row2..6）是未来 → null
      expect(rightCol[1], isNotNull);
      expect(rightCol[1]!.date, DateTime(2026, 9, 8));
      expect(rightCol[2], isNull);
      expect(rightCol[6], isNull);
    });

    test('秒数正确落格 & level 与 watchLevel 一致', () {
      const days = {
        '2026-09-08': 60, // 今天 1 分钟
        '2026-09-07': 300, // 本周一 5 分钟
        '2025-09-08': 7200, // 一年前某天 ≥60 分钟（深蓝）
      };
      final grid = buildHeatmapGrid(days, today);
      final todayCell = grid.last[1]!;
      expect(todayCell.seconds, 60);
      expect(todayCell.level, WatchStats.watchLevel(60)); // 1
      final mondayCell = grid.last[0]!;
      expect(mondayCell.seconds, 300);
      expect(mondayCell.level, 2);

      // 2025-09-08 是 52 周前同周几？2026-09-08 - 364 天 = 2025-09-09?
      // 直接找它：date 遍历最稳
      HeatCell? found;
      for (final col in grid) {
        for (final c in col) {
          if (c != null && c.date == DateTime(2025, 9, 8)) found = c;
        }
      }
      expect(found, isNotNull);
      expect(found!.level, 5);
    });

    test('无记录的天 = level 0 灰格（仍有日期）', () {
      final grid = buildHeatmapGrid(const {}, today);
      final yesterday = grid.last[0]!; // 本周一无记录
      expect(yesterday.level, 0);
      expect(yesterday.seconds, 0);
    });
  });

  group('buildHeatMonthLabels', () {
    test('覆盖展示范围，含今天的月份，且不越界', () {
      final today = DateTime(2026, 9, 8);
      final labels = buildHeatMonthLabels(heatGridStart(today), today);
      expect(labels, isNotEmpty);
      expect(labels.last.text, '9月');
      for (final l in labels) {
        expect(l.col, inInclusiveRange(0, 52));
      }
      // 标签不重复
      final texts = labels.map((l) => l.text).toSet();
      expect(texts.length, labels.length);
    });
  });

  group('formatWatchDuration', () {
    test('秒/分钟/小时/天 文案', () {
      expect(formatWatchDuration(0), '0 秒');
      expect(formatWatchDuration(45), '45 秒');
      expect(formatWatchDuration(300), '5 分钟');
      expect(formatWatchDuration(3660), '1 小时 1 分');
      expect(formatWatchDuration(7200), '2 小时');
      expect(formatWatchDuration(90000), '1 天 1 小时');
    });
  });

  group('WatchStatsPage 冒烟', () {
    testWidgets('无数据：总览 0 + 空态文案', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: WatchStats())),
      ));
      await tester.pumpAndSettle();
      expect(find.text('观看统计'), findsOneWidget);
      expect(find.text('今日观看'), findsOneWidget);
      expect(find.text('开始观看后这里会生成你的观看热力'), findsOneWidget);
    });

    testWidgets('有数据：显示观看热力卡与点击详情行提示', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final stats = WatchStats();
      // 今天 + 昨天 + 前几天：数据足够热力卡进入渲染分支
      final now = DateTime.now();
      await stats.record(3600, at: now); // 今天 1 小时 → 深蓝
      await stats.record(600, at: now.subtract(const Duration(days: 1)));
      await stats.record(100, at: now.subtract(const Duration(days: 2)));
      await stats.record(50, at: now.subtract(const Duration(days: 3)));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('观看热力 · 最近 53 周'), findsOneWidget);
      expect(find.textContaining('天有观看记录'), findsOneWidget);
      // 蓝色系图例存在（少/多 + 档位说明）
      expect(find.textContaining('档位：'), findsOneWidget);
      // 空态消失
      expect(find.text('开始观看后这里会生成你的观看热力'), findsNothing);
    });
  });
}
