// fmtRelativeTime 单元测试（lib/utils/relative_time.dart）：
// - 覆盖 刚刚 / 分钟前 / 小时前 / 天前 / 月前 / 绝对日期 六档
// - 分档边界：59s / 60s / 59min / 60min / 23h / 24h / 29d / 30d / 364d / 365d
// - 未来时间（时钟回拨）不出现负数
// - ★ 回归红线：'30 分钟前' / '3 小时前'（历史页测试的断言文案，逐字一致）
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/relative_time.dart';

void main() {
  // 固定「现在」，避免测试跨秒抖动
  final now = DateTime(2026, 9, 10, 12, 0, 0);

  String fmt(Duration ago) => fmtRelativeTime(now.subtract(ago), now: now);

  group('相对时间分档', () {
    test('★ 回归：30 分钟前 / 3 小时前（逐字与旧实现一致）', () {
      expect(fmt(const Duration(minutes: 30)), '30 分钟前');
      expect(fmt(const Duration(hours: 3)), '3 小时前');
    });

    test('刚刚（< 60 秒）', () {
      expect(fmt(Duration.zero), '刚刚');
      expect(fmt(const Duration(seconds: 1)), '刚刚');
      expect(fmt(const Duration(seconds: 59)), '刚刚');
    });

    test('N 分钟前（60 秒 ~ 59 分钟）', () {
      expect(fmt(const Duration(seconds: 60)), '1 分钟前');
      expect(fmt(const Duration(minutes: 5)), '5 分钟前');
      expect(fmt(const Duration(minutes: 59)), '59 分钟前');
    });

    test('N 小时前（60 分钟 ~ 23 小时）', () {
      expect(fmt(const Duration(minutes: 60)), '1 小时前');
      expect(fmt(const Duration(hours: 1, minutes: 59)), '1 小时前');
      expect(fmt(const Duration(hours: 23)), '23 小时前');
    });

    test('N 天前（24 小时 ~ 29 天）', () {
      expect(fmt(const Duration(hours: 24)), '1 天前');
      expect(fmt(const Duration(days: 1)), '1 天前');
      expect(fmt(const Duration(days: 5)), '5 天前');
      expect(fmt(const Duration(days: 29)), '29 天前');
    });

    test('N 个月前（30 天 ~ 364 天，按 30 天折算）', () {
      expect(fmt(const Duration(days: 30)), '1 个月前');
      expect(fmt(const Duration(days: 59)), '1 个月前');
      expect(fmt(const Duration(days: 60)), '2 个月前');
      expect(fmt(const Duration(days: 364)), '12 个月前');
    });

    test('绝对日期 yyyy-MM-dd（≥ 365 天）', () {
      expect(fmt(const Duration(days: 365)), '2025-09-10');
      expect(fmtRelativeTime(DateTime(2020, 3, 5), now: now), '2020-03-05');
      expect(fmtRelativeTime(DateTime(2019, 12, 31), now: now), '2019-12-31');
    });

    test('未来时间（时钟回拨）按「刚刚」处理，不出负数', () {
      expect(fmtRelativeTime(now.add(const Duration(hours: 2)), now: now),
          '刚刚');
    });

    test('now 缺省 = DateTime.now（注入只影响分档判定）', () {
      // 1 秒钟前一定是「刚刚」，不依赖固定 now
      expect(
        fmtRelativeTime(
          DateTime.now().subtract(const Duration(seconds: 1)),
        ),
        '刚刚',
      );
    });
  });
}
