// 观看统计页（WatchStatsPage）单测：53 周热力网格构建 / 月份标签 /
// 时长文案 / 数据编码墨**相对制**配色（v2.17.16：最长日→最深，其余按比例
// 连续渐变，无固定分档；P1.5：墨色跟随配色配方；S6：最深档改用
// AppPalette.inkDeco，保证与纸底 ≥ 3:1 的图形对比度）/ 总览在热力下方 /
// 设置区内联 / 点日期格进入该日历史页；另有页面冒烟（空态 / 有数据热力卡出现）。
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
import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_theme.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/ink_recipes.dart';
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

  group('相对配色（v2.17.16 相对制 + P1.5 跟随配色配方）', () {
    test('默认配方主墨 #002FA7 + 无观看极浅墨底 + 渐变起点主墨稀释底', () {
      final p = AppPalette.fallback; // = 真机默认配方 klein_clay
      expect(p.ink, const Color(0xFF002FA7));
      expect(p.accent, const Color(0xFFC65F38));
      // 无观看格：主墨 6% 融进纸底（P1 手写 #EBEEF5 → 现值 #EBEEF2，仅个位数差）
      // 注：alphaBlend/lerp 结果是浮点通道，比色用 toARGB32() 取整后比
      expect(heatNoWatchColorOf(p).toARGB32(), 0xFFEBEEF2);
      // 渐变起点 = 主墨 12% 稀释底（P1 手写 #D5E5FF → 现值 #DCE2ED）
      expect(p.inkWash.toARGB32(), 0xFFDCE2ED);
    });

    test('heatColorForIntensity：≤0=极浅底、≥1=最深档 inkDeco、中间连续插值', () {
      final p = AppPalette.fallback;
      final none = heatNoWatchColorOf(p);
      final low = p.inkWash; // 渐变起点（主墨浅档）
      final high = p.inkDeco; // 最强 = 数据编码最深档（默认配方 = 原墨）
      expect(heatColorForIntensity(0, p), none);
      expect(heatColorForIntensity(-1, p), none);
      expect(heatColorForIntensity(1, p), high);
      expect(heatColorForIntensity(5, p), high);
      // 0.5 应等于 Color.lerp(起点浅档, 最深档 inkDeco, 0.5) 的插值结果
      // （Flutter 新版 lerp 走更精确的宽色域插值，不等于逐通道均值，直接对比实现）
      final mid = Color.lerp(low, high, 0.5)!;
      expect(heatColorForIntensity(0.5, p), mid);
      // 中间色在两端之间、且不是任一端（确有渐变）
      expect(mid, isNot(low));
      expect(mid, isNot(high));
      // 单调：三个通道都介于起点与主墨之间
      expect(mid.r, inInclusiveRange(high.r, low.r));
      expect(mid.g, inInclusiveRange(high.g, low.g));
      expect(mid.b, inInclusiveRange(high.b, low.b));
      // 强度 0.75 明显比 0.5 深（红通道降、蓝通道升方向相反，用红通道比较）
      final q3 = heatColorForIntensity(0.75, p);
      expect(q3.r, lessThan(mid.r));
    });

    test('两端贴合：1% 几乎=起点浅档，99% 几乎=最深档（连续无跳档断层）', () {
      final p = AppPalette.fallback;
      final nearLow = heatColorForIntensity(0.01, p);
      final nearHigh = heatColorForIntensity(0.99, p);
      // 低强度贴近起点浅档（红通道高 ≈0.86），高强度贴近最深档（红通道近 0）
      expect(nearLow.r, closeTo(p.inkWash.r, 0.05));
      expect(nearHigh.r, closeTo(p.inkDeco.r, 0.05));
      expect(nearLow.r - nearHigh.r, greaterThan(0.7));
    });

    test('换配方：最深档 = 该配方 inkDeco（原墨达标则同值）、极浅底随主墨'
        '（不是写死克莱因蓝）', () {
      final cobalt =
          AppPalette.fromRecipe(inkRecipeById('cobalt_terracotta')!);
      expect(cobalt.ink, const Color(0xFF2148B8));
      // 钴蓝原墨 vs 纸底本就 ≥ 3:1 → inkDeco 零漂移，最深档 = 原墨
      expect(cobalt.inkDeco, cobalt.ink);
      expect(heatColorForIntensity(1, cobalt), cobalt.inkDeco);
      expect(heatColorForIntensity(0, cobalt), heatNoWatchColorOf(cobalt));
      expect(
        heatNoWatchColorOf(cobalt),
        isNot(heatNoWatchColorOf(AppPalette.fallback)),
      );
    });

    test('浅墨配方（粉蓝）：最深档不再用原墨而是压深的 inkDeco，'
        '与纸底 ≥ 3:1 的图形对比度（S6）', () {
      final powder =
          AppPalette.fromRecipe(inkRecipeById('powder_blue_signal_red')!);
      // 原墨 #9EB8D3 直接当最深档只有 ≈1.96:1，深浅读不出来
      expect(contrastRatio(powder.ink, kPaper), lessThan(kMinContrastGraphic));
      expect(powder.inkDeco, isNot(powder.ink));
      expect(
        contrastRatio(powder.inkDeco, kPaper),
        greaterThanOrEqualTo(kMinContrastGraphic),
      );
      // 最深档确实更深（亮度更低）→ 「颜色越深观看越久」的刻度成立
      expect(
        relativeLuminance(powder.inkDeco),
        lessThan(relativeLuminance(powder.ink)),
      );
      expect(heatColorForIntensity(1, powder), powder.inkDeco);
      // 相对色阶仍单调：中间档介于浅档与最深档之间
      final mid = heatColorForIntensity(0.5, powder);
      expect(mid, Color.lerp(powder.inkWash, powder.inkDeco, 0.5));
      expect(mid, isNot(powder.inkWash));
      expect(mid, isNot(powder.inkDeco));
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

  group('总览在热力下方 + 点日进历史 + 设置区内联（v2.17.10；v2.19.0「个人」页）',
      () {
    testWidgets('设置区追加在统计内容之后（统计在上、设置在下，同一滚动流）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WatchStatsPage(
            stats: WatchStats(),
            settingsSection: const Text('设置区标记'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 页面固定标题条「观看统计」在最上（不在滚动流里）
      expect(find.text('观看统计'), findsOneWidget);
      // 同一 ListView 里：总览（统计内容）在设置区之前
      expect(find.text('观看总览'), findsOneWidget);
      expect(find.text('设置区标记'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('观看总览')).dy,
        lessThan(tester.getTopLeft(find.text('设置区标记')).dy),
      );
    });

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
        headingSubtitle: '集中设置区（「个人」页底部内联组件）',
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

  group('P1.5 热力色跟随配色配方（主题真的传到格子上）', () {
    testWidgets('换配方（钴蓝 · 陶土）后：最强格 = 该配方 inkDeco，今天格描边同色',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final stats = WatchStats();
      final now = DateTime.now();
      await stats.record(3600, at: now); // 今天 = 窗口内最长 → 最强格
      final recipe = inkRecipeById('cobalt_terracotta')!;
      final palette = AppPalette.fromRecipe(recipe);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(recipe),
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();

      final todayKey = WatchStats.dateKey(now);
      final cell = tester.widget<Container>(
        find.descendant(
          of: find.byKey(ValueKey('heatcell-$todayKey')),
          matching: find.byType(Container),
        ),
      );
      final deco = cell.decoration as BoxDecoration;
      // 钴蓝原墨本就达标 → inkDeco = 原墨 #2148B8（零漂移）
      expect(
        deco.color,
        palette.inkDeco,
        reason: '最强格 = 该配方 inkDeco（钴蓝下 = 原墨）',
      );
      expect(
        (deco.border as Border).top.color,
        palette.inkDeco.withValues(alpha: .9),
        reason: '今天格描边 = inkDeco',
      );
    });

    testWidgets('浅墨配方（粉蓝 · 信号红）下最强格明显比原墨深（3:1 可读）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final stats = WatchStats();
      final now = DateTime.now();
      await stats.record(3600, at: now);
      final recipe = inkRecipeById('powder_blue_signal_red')!;
      final palette = AppPalette.fromRecipe(recipe);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(recipe),
        home: Scaffold(body: WatchStatsPage(stats: stats)),
      ));
      await tester.pumpAndSettle();

      final todayKey = WatchStats.dateKey(now);
      final cell = tester.widget<Container>(
        find.descendant(
          of: find.byKey(ValueKey('heatcell-$todayKey')),
          matching: find.byType(Container),
        ),
      );
      final deco = cell.decoration as BoxDecoration;
      expect(deco.color, palette.inkDeco);
      expect(deco.color, isNot(palette.ink)); // 不再是那个读不出来的浅墨
      expect(
        contrastRatio(deco.color!, kPaper),
        greaterThanOrEqualTo(kMinContrastGraphic),
      );
    });
  });
}
