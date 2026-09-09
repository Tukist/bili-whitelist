// 观看统计页（WatchStatsPage）单测：53 周热力网格构建 / 月份标签 /
// 时长文案 / 克莱因蓝**相对制**配色（v2.17.16：最长日→最深，其余按比例
// 连续渐变，无固定分档）/ 总览在热力下方 / 设置区内联 /
// 点日期格进入该日历史页；另有页面冒烟（空态 / 有数据热力卡出现）。
// - 网格函数不碰插件，直接断言数据结构
// - 页面冒烟用 shared_preferences mock + 注入 stats 实例
// - 点日进历史需要 HistoryStore 预置该日条目（SharedPreferences mock）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/pages/daily_history_page.dart';
import 'package:bili_whitelist_app/pages/watch_stats_page.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

/// 构造一条历史（cover 置空 → CoverImage 占位不触网络）。
HistoryEntry _entry(
  String bvid,
  DateTime watchedAt, {
  String title = '标题',
  int positionMs = 30000,
  int durationMs = 120000,
}) => HistoryEntry(
      bvid: bvid,
      pageIndex: 0,
      cid: 100,
      title: title,
      cover: '',
      upName: 'UP主',
      durationMs: durationMs,
      positionMs: positionMs,
      watchedAt: watchedAt,
    );

/// 纵向滚动列表直到 [finder] 出现（设置区在页底，需要滚动）。
Future<void> _scrollTo(
  WidgetTester tester,
  Finder finder, {
  int maxTries = 10,
}) async {
  for (var i = 0; i < maxTries && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  expect(finder, findsWidgets);
}

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

    test('秒数正确落格（level 概念已移除，v2.17.16 相对制渲染时算强度）', () {
      const days = {
        '2026-09-08': 60, // 今天 1 分钟
        '2026-09-07': 300, // 本周一 5 分钟
        '2025-09-08': 7200, // 一年前某天 2 小时
      };
      final grid = buildHeatmapGrid(days, today);
      final todayCell = grid.last[1]!;
      expect(todayCell.seconds, 60);
      final mondayCell = grid.last[0]!;
      expect(mondayCell.seconds, 300);

      HeatCell? found;
      for (final col in grid) {
        for (final c in col) {
          if (c != null && c.date == DateTime(2025, 9, 8)) found = c;
        }
      }
      expect(found, isNotNull);
      expect(found!.seconds, 7200);
    });

    test('无记录的天 = 0 秒格子（渲染侧给浅底；仍有日期）', () {
      final grid = buildHeatmapGrid(const {}, today);
      final yesterday = grid.last[0]!; // 本周一无记录
      expect(yesterday.seconds, 0);
    });

    test('maxDaySecondsOfGrid：窗口内最长单日秒（相对配色基准）', () {
      final grid = buildHeatmapGrid(const {
        '2026-09-08': 60,
        '2026-09-07': 7200, // 最长
        '2025-09-08': 300,
      }, today);
      expect(maxDaySecondsOfGrid(grid), 7200);
    });

    test('maxDaySecondsOfGrid：全 0 / 空 → 0（防御，页面空态分支已挡）', () {
      expect(maxDaySecondsOfGrid(buildHeatmapGrid(const {}, today)), 0);
      final allZero = buildHeatmapGrid(const {}, today);
      for (final col in allZero) {
        for (var r = 0; r < col.length; r++) {
          col[r] = HeatCell(date: today, seconds: 0);
        }
      }
      expect(maxDaySecondsOfGrid(allZero), 0);
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

  group('相对配色（v2.17.16：克莱因蓝连续渐变，无固定分档）', () {
    test('主色 #002FA7 + 无观看浅近白底 #EBEEF5 + 渐变起点浅蓝 #D5E5FF', () {
      expect(kKleinBlue, const Color(0xFF002FA7));
      expect(kHeatNoWatchColor, const Color(0xFFEBEEF5));
      expect(kHeatLowColor, const Color(0xFFD5E5FF));
    });

    test('heatColorForIntensity：≤0=浅底、≥1=克莱因蓝、中间连续插值', () {
      expect(heatColorForIntensity(0), kHeatNoWatchColor);
      expect(heatColorForIntensity(-1), kHeatNoWatchColor);
      expect(heatColorForIntensity(1), kKleinBlue);
      expect(heatColorForIntensity(5), kKleinBlue);
      // 0.5 应等于 Color.lerp(起点浅蓝, 克莱因蓝, 0.5) 的插值结果
      // （Flutter 新版 lerp 走更精确的宽色域插值，不等于逐通道均值，直接对比实现）
      final mid = Color.lerp(kHeatLowColor, kKleinBlue, 0.5)!;
      expect(heatColorForIntensity(0.5), mid);
      // 中间色在两端之间、且不是任一端（确有渐变）
      expect(mid, isNot(kHeatLowColor));
      expect(mid, isNot(kKleinBlue));
      // 单调：三个通道都介于起点与克莱因蓝之间（0 <= 红 <= 213 等）
      expect(mid.r, inInclusiveRange(kKleinBlue.r, kHeatLowColor.r));
      expect(mid.g, inInclusiveRange(kKleinBlue.g, kHeatLowColor.g));
      expect(mid.b, inInclusiveRange(kKleinBlue.b, kHeatLowColor.b));
      // 强度 0.75 明显比 0.5 深（红通道降、蓝通道升方向相反，用红通道比较）
      final q3 = heatColorForIntensity(0.75);
      expect(q3.r, lessThan(mid.r));
    });

    test('两端贴合：1% 几乎=起点浅蓝，99% 几乎=克莱因蓝（连续无跳档断层）', () {
      final nearLow = heatColorForIntensity(0.01);
      final nearHigh = heatColorForIntensity(0.99);
      // 低强度贴近起点浅蓝（红通道高 ≈0.83），高强度贴近克莱因蓝（红通道近 0）
      expect(nearLow.r, closeTo(kHeatLowColor.r, 0.05));
      expect(nearHigh.r, closeTo(kKleinBlue.r, 0.05));
      expect(nearLow.r - nearHigh.r, greaterThan(0.7));
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
      final now = DateTime.now();
      await stats.record(3600, at: now); // 今天 1 小时 → 克莱因蓝
      await stats.record(600, at: now.subtract(const Duration(days: 1)));
      await stats.record(100, at: now.subtract(const Duration(days: 2)));
      await stats.record(50, at: now.subtract(const Duration(days: 3)));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('观看热力 · 最近 53 周'), findsOneWidget);
      expect(find.textContaining('天有观看记录'), findsOneWidget);
      // v2.17.16 相对制图例说明（不再有固定档位文案）
      expect(find.textContaining('相对色阶'), findsOneWidget);
      expect(find.textContaining('档位：'), findsNothing);
      expect(find.text('开始观看后这里会生成你的观看热力'), findsNothing);
    });
  });

  group('总览在热力下方 + 点日进历史 + 设置区内联（v2.17.10）', () {
    testWidgets('总览统计（观看总览）渲染在热力卡下方', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final stats = WatchStats();
      await stats.record(1800, at: DateTime.now());

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();

      final heat = tester.getTopLeft(find.text('观看热力 · 最近 53 周'));
      final overview = tester.getTopLeft(find.text('观看总览'));
      final today = tester.getTopLeft(find.text('今日观看'));
      expect(heat.dy, lessThan(overview.dy));
      expect(overview.dy, lessThan(today.dy));
    });

    testWidgets('点有观看的日期格 → 推该日历史页并列出当天条目（不含他日）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final now = DateTime.now();
      // 观看时长：今天有记录（热力有数据）
      final stats = WatchStats();
      await stats.record(7200, at: now);
      // 历史：今天一条 + 昨天一条（该日页应只显示今天的）
      final store = HistoryStore.instance;
      await store.addOrUpdate(_entry('BVtoday', now, title: '今天看的视频'));
      await store.addOrUpdate(_entry(
        'BVyest',
        now.subtract(const Duration(days: 1)),
        title: '昨天看的视频',
      ));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();

      // 点今天的热力格（今天在最右列，锚定后可见）
      final todayKey = WatchStats.dateKey(now);
      final cell = find.byKey(ValueKey('heatcell-$todayKey'));
      expect(cell, findsOneWidget);
      await tester.tap(cell);
      await tester.pumpAndSettle();

      // 进入该日历史页：只列今天的
      expect(find.byType(DailyHistoryPage), findsOneWidget);
      expect(find.text('今天看的视频'), findsOneWidget);
      expect(find.text('昨天看的视频'), findsNothing);
    });

    testWidgets('点格进入该日历史页：当天无历史记录显示空态', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final stats = WatchStats();
      final now = DateTime.now();
      await stats.record(300, at: now); // 观看时长有，但历史表为空

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();

      final todayKey = WatchStats.dateKey(now);
      await tester.tap(find.byKey(ValueKey('heatcell-$todayKey')));
      await tester.pumpAndSettle();

      expect(find.byType(DailyHistoryPage), findsOneWidget);
      expect(find.text('该日无观看记录'), findsOneWidget);
    });

    testWidgets('settingsSection 内联渲染在页底（标题「设置」+ 管理分区）',
        (tester) async {
      // secure storage mock：让 ManagePanel 的账号/GitHub 配置读取可用
      final store = <String, String>{};
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'read':
            return store[args['key'] as String?];
          case 'write':
            final key = args['key'] as String?;
            if (key == null) return false;
            store[key] = args['value'] as String? ?? '';
            return true;
          case 'delete':
            store.remove(args['key'] as String?);
            return true;
          default:
            return null;
        }
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      SharedPreferences.setMockInitialValues({});

      final panel = ManagePanel(
        github: GithubApi(),
        closeBeforeNavigate: false,
        headingTitle: '设置',
        headingSubtitle: '集中设置区（与首页齿轮为同一组件）',
        onCollectionCreated: (_) async {},
        onManageCollections: () {},
        onCheckUpdate: () {},
        onLogin: () {},
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(settingsSection: panel)),
      ));
      await tester.pumpAndSettle();

      // 无观看数据时也在页底提供设置区（滚动到底可见）
      await _scrollTo(tester, find.text('设置'));
      expect(find.text('B 站账号'), findsOneWidget);
      await _scrollTo(tester, find.text('GitHub 配置'));
      expect(find.text('保存配置'), findsOneWidget);
      await _scrollTo(tester, find.text('版本更新'));
      expect(find.text('检查更新'), findsOneWidget);
    });
  });
}
