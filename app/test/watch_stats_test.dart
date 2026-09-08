// WatchStats（每日观看时长记录）单元测试。
// - shared_preferences.setMockInitialValues 注入内存存储，不碰原生插件
// - 记录累加 / 跨日（clock 注入）/ streak / 400 天裁剪 / 损坏容错 /
//   纯函数（delta 累计排除跳变、watchLevel 分级）
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/watch_stats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯函数 accumulateWatchMs（播放页累计口径）', () {
    test('正常连续播放的增量（500ms tick）全部累计', () {
      final deltas = List.filled(20, 500); // 10s
      expect(WatchStats.accumulateWatchMs(deltas), 10000);
    });

    test('排除 0（暂停/缓冲停住）、负数（回退/seek 后退）、超阈值（seek 前进）', () {
      // 0 不累计；-3000（快退）不计；+3000（快进 3 秒）在阈值内会被计入，
      // 播放页在 seek 后重置基线避免误计 —— 纯函数只保证口径：>5000 大跳不计
      expect(
        WatchStats.accumulateWatchMs([500, 0, 500, -3000, 500, 6000, 500]),
        2000,
      );
    });

    test('5000ms 边界：恰好等于阈值计入，超过不计', () {
      expect(WatchStats.accumulateWatchMs([5000]), 5000);
      expect(WatchStats.accumulateWatchMs([5001]), 0);
      expect(
        WatchStats.accumulateWatchMs([5000, 5001, 1]),
        5001,
      );
    });

    test('空序列 / 全为跳变 → 0', () {
      expect(WatchStats.accumulateWatchMs([]), 0);
      expect(WatchStats.accumulateWatchMs([60000, -100, 0]), 0);
    });
  });

  group('纯函数 watchLevel（蓝阶分级）', () {
    test('0 秒 = 0（无观看）；>0 按分钟分 5 档', () {
      expect(WatchStats.watchLevel(0), 0);
      // <5 分钟 → 1
      expect(WatchStats.watchLevel(1), 1);
      expect(WatchStats.watchLevel(299), 1);
      // 5-15 分钟 → 2
      expect(WatchStats.watchLevel(300), 2);
      expect(WatchStats.watchLevel(899), 2);
      // 15-30 分钟 → 3
      expect(WatchStats.watchLevel(900), 3);
      expect(WatchStats.watchLevel(1799), 3);
      // 30-60 分钟 → 4
      expect(WatchStats.watchLevel(1800), 4);
      expect(WatchStats.watchLevel(3599), 4);
      // ≥60 分钟 → 5
      expect(WatchStats.watchLevel(3600), 5);
      expect(WatchStats.watchLevel(99999), 5);
    });
  });

  group('纯函数 dateKey / dateOfKey', () {
    test('往返一致（含个位月/日补零）', () {
      final d = DateTime(2026, 9, 8);
      expect(WatchStats.dateKey(d), '2026-09-08');
      expect(WatchStats.dateOfKey('2026-09-08'), DateTime(2026, 9, 8));
      expect(WatchStats.dateKey(DateTime(2026, 1, 3)), '2026-01-03');
      expect(WatchStats.dateOfKey('2026-01-03'), DateTime(2026, 1, 3));
    });

    test('脏键返回 null（格式错 / 非法日期 / 越界进位）', () {
      expect(WatchStats.dateOfKey('2026-9-8'), isNull);
      expect(WatchStats.dateOfKey('2026/09/08'), isNull);
      expect(WatchStats.dateOfKey(''), isNull);
      expect(WatchStats.dateOfKey('2026-02-30'), isNull); // Dart 会进位 → 拒
      expect(WatchStats.dateOfKey('not-a-date'), isNull);
    });
  });

  group('countStreak（最长连续观看天数）', () {
    test('空 / 全 0 → 0', () {
      expect(WatchStats.countStreak({}), 0);
      expect(WatchStats.countStreak({'2026-09-01': 0}), 0);
    });

    test('连续段取最长（含今天断档不影响历史最长）', () {
      const days = {
        '2026-09-01': 100,
        '2026-09-02': 100,
        '2026-09-03': 100,
        '2026-09-05': 100,
        '2026-09-06': 100,
        '2026-09-07': 100,
        '2026-09-08': 100, // 今天有 → 当前 4 连；最长仍是前面 3? 不，5-8 是 4 天
        '2026-08-20': 100, // 更早孤立一天
        '2026-08-21': 100,
      };
      // 最长段：9/5-9/8 共 4 天；8/20-8/21 2 天；9/1-9/3 3 天
      expect(WatchStats.countStreak(days), 4);
    });

    test('乱序键（Map 无序）不影响结果', () {
      const days = {
        '2026-09-03': 100,
        '2026-09-01': 100,
        '2026-09-02': 100,
        '2026-09-05': 100,
        '2026-09-04': 100,
      };
      expect(WatchStats.countStreak(days), 5);
    });
  });

  group('prune（保留近 maxDays 天裁剪）', () {
    final now = DateTime(2026, 9, 8);
    test('早于保留窗口的键被裁剪，窗口内保留', () {
      final days = {
        '2025-01-01': 60, // 太旧
        '2025-08-04': 60, // 窗口前 1 天（窗口起点 = 今天-399 天 = 2025-08-05）
        '2025-08-05': 60, // 窗口第一天
        '2026-09-08': 60, // 今天
      };
      final pruned = WatchStats.prune(days, now: now);
      // 保留窗口 = 2026-09-08 - 399 天 = 2025-08-05 起，共 400 天
      expect(pruned.keys, contains('2025-08-05'));
      expect(pruned.keys, contains('2026-09-08'));
      expect(pruned.keys, isNot(contains('2025-08-04')));
      expect(pruned.keys, isNot(contains('2025-01-01')));
    });

    test('脏键 / 0 值 / 负数 / 未来日期剔除', () {
      final days = {
        'garbage': 60,
        '2026-09-01': 0,
        '2026-09-02': -5,
        '2026-09-09': 60, // 未来（今天 9/8 之后）
        '2026-09-08': 60,
      };
      final pruned = WatchStats.prune(days, now: now);
      expect(pruned, {'2026-09-08': 60});
    });

    test('恰好保留 maxDays 个不同日期', () {
      final days = <String, int>{};
      final start = now.subtract(const Duration(days: WatchStats.maxDays - 1));
      for (var i = 0; i < 500; i++) {
        days[WatchStats.dateKey(start.add(Duration(days: i)))] = 10;
      }
      final pruned = WatchStats.prune(days, now: now);
      expect(pruned.length, WatchStats.maxDays);
      expect(
        pruned.keys.first.compareTo(WatchStats.dateKey(start)),
        greaterThanOrEqualTo(0),
      );
    });
  });

  group('record / 统计（shared_preferences mock）', () {
    test('record 累加到今天；连续两次相加', () async {
      SharedPreferences.setMockInitialValues({});
      final s = WatchStats();
      await s.ensureLoaded();
      await s.record(30);
      await s.record(45);
      final key = WatchStats.dateKey(DateTime.now());
      expect(s.days[key], 75);
      expect(s.totalSeconds, 75);
    });

    test('record 可指定日期（跨日写入）', () async {
      SharedPreferences.setMockInitialValues({});
      final s = WatchStats();
      await s.ensureLoaded();
      await s.record(100, at: DateTime(2026, 9, 7));
      await s.record(50, at: DateTime(2026, 9, 8));
      expect(s.days['2026-09-07'], 100);
      expect(s.days['2026-09-08'], 50);
      expect(s.activeDays, 2);
    });

    test('clock 注入模拟跨日：今天秒数随日期切到新一天', () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime(2026, 9, 7, 23, 59);
      final s = WatchStats()..clock = () => now;
      await s.ensureLoaded();
      await s.record(100); // 记到 9/7
      now = DateTime(2026, 9, 8, 0, 1); // 跨日
      await s.record(200); // 记到 9/8
      expect(s.days['2026-09-07'], 100);
      expect(s.days['2026-09-08'], 200);
      expect(s.todaySeconds, 200);
      expect(s.totalSeconds, 300);
    });

    test('weekSeconds：周一起算到今天', () async {
      SharedPreferences.setMockInitialValues({});
      // 2026-09-08 是周二 → 本周一 9/7、周二 9/8；上周日 9/6 不计
      final s = WatchStats()..clock = () => DateTime(2026, 9, 8, 12);
      await s.ensureLoaded();
      await s.record(100, at: DateTime(2026, 9, 6)); // 上周日
      await s.record(100, at: DateTime(2026, 9, 7)); // 周一
      await s.record(100, at: DateTime(2026, 9, 8)); // 周二（今天）
      expect(s.weekSeconds, 200);
    });

    test('持久化：新实例 load 后读到同一份数据（模拟重启）', () async {
      SharedPreferences.setMockInitialValues({});
      final a = WatchStats();
      await a.ensureLoaded();
      await a.record(60, at: DateTime(2026, 9, 8));

      final b = WatchStats(); // 新实例 = 新进程
      await b.ensureLoaded();
      expect(b.days['2026-09-08'], 60);

      // 底层就是 JSON 对象
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(WatchStats.storageKey), contains('2026-09-08'));
    });

    test('数据损坏（非 JSON）→ load 为空，record 后自愈可读', () async {
      SharedPreferences.setMockInitialValues({
        WatchStats.storageKey: 'garbage{{',
      });
      final s = WatchStats();
      await s.ensureLoaded();
      expect(s.days, isEmpty);
      expect(s.totalSeconds, 0);

      await s.record(30, at: DateTime(2026, 9, 8));
      expect(s.days['2026-09-08'], 30);

      final fresh = WatchStats();
      await fresh.ensureLoaded();
      expect(fresh.days['2026-09-08'], 30);
    });

    test('脏记录（负秒/非数字/非法键/超窗口）load 时清理回写', () async {
      SharedPreferences.setMockInitialValues({
        WatchStats.storageKey:
            '{"2026-09-07":-5,"2026-09-08":60,"bad":99,'
            '"2026-09-08":120}',
      });
      final s = WatchStats();
      await s.ensureLoaded();
      // 同键后者覆盖 120；bad/负秒剔除
      expect(s.days['2026-09-08'], 120);
      expect(s.days.containsKey('bad'), isFalse);
      expect(s.days.containsKey('2026-09-07'), isFalse);
      expect(s.activeDays, 1);
    });

    test('record 0 / 负数直接忽略', () async {
      SharedPreferences.setMockInitialValues({});
      final s = WatchStats();
      await s.ensureLoaded();
      await s.record(0);
      await s.record(-10);
      expect(s.days, isEmpty);
      expect(s.activeDays, 0);
    });
  });
}
