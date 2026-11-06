// 热度曲线密度算法单测（v2.61.0+，纯函数，无 Flutter / 网络）：
// - 分桶：按 10s 一桶计数（含边界：t=0 / t 落在桶首 / 末尾桶）
// - 平滑：半径 1 的三桶滑动平均，边缘按实际窗口数取均值（不拉向 0）
// - 归一化：除以最大值 → 0..1，峰值恒为 1
// - 空输入 / 时长为 0 / 单桶 / 超长视频（桶数封顶）/ 脏时间 / 全零 → 不画线
// - 切 P 语义：同一批弹幕换 duration（新集时长）→ 桶数随之变化
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/danmaku.dart';
import 'package:bili_whitelist_app/services/heat_curve.dart';

/// 造一条弹幕（渲染无关字段给常量）。
Danmaku _dm(double timeSec) => Danmaku(
      timeSec: timeSec,
      mode: 1,
      fontSize: 25,
      color: 0xFFFFFF,
      text: 't=$timeSec',
    );

void main() {
  group('不画线（返回 null）', () {
    test('弹幕为空 → null', () {
      expect(buildHeatCurve(const [], durationMs: 60000), isNull);
    });

    test('时长为 0 / 负数（onPrepared 还没回来）→ null', () {
      expect(buildHeatCurve([_dm(1)], durationMs: 0), isNull);
      expect(buildHeatCurve([_dm(1)], durationMs: -5), isNull);
    });

    test('单桶（时长 <= 一桶）→ null（一个点画不出线，不画平线）', () {
      // 10s 视频 / 10s 一桶 = 1 桶
      expect(buildHeatCurve([_dm(1), _dm(2)], durationMs: 10000), isNull);
      expect(buildHeatCurve([_dm(1)], durationMs: 3000), isNull);
    });

    test('弹幕全是脏时间（负数 / 超时长）→ null（不造片尾尖峰）', () {
      final list = [_dm(-1), _dm(999), _dm(double.nan)];
      expect(buildHeatCurve(list, durationMs: 60000), isNull);
    });

    test('桶数上限小于 2 → null（调用方传错也不崩）', () {
      expect(
        buildHeatCurve([_dm(1)], durationMs: 60000, maxBuckets: 1),
        isNull,
      );
    });
  });

  group('分桶与平滑', () {
    test('60s / 10s 一桶 = 6 桶，计数与平滑值逐项正确', () {
      // 桶计数：[2, 1, 0, 0, 0, 1]
      final list = [_dm(0), _dm(5), _dm(15), _dm(55)];
      final curve = buildHeatCurve(list, durationMs: 60000)!;

      expect(curve.values, hasLength(6));
      expect(curve.bucketSec, 10, reason: '常规视频用默认桶宽');
      expect(curve.durationMs, 60000);
      // 平滑后：[1.5, 1.0, 1/3, 0, 1/3, 0.5] → 除以 1.5
      expect(curve.values[0], closeTo(1.0, 1e-9));
      expect(curve.values[1], closeTo(2 / 3, 1e-9));
      expect(curve.values[2], closeTo(2 / 9, 1e-9));
      expect(curve.values[3], closeTo(0, 1e-9));
      expect(curve.values[4], closeTo(2 / 9, 1e-9));
      expect(curve.values[5], closeTo(1 / 3, 1e-9));
    });

    test('平滑半径 0 → 不做平滑（原样归一化）', () {
      final list = [_dm(0), _dm(1), _dm(15)];
      final curve = buildHeatCurve(list, durationMs: 60000, smoothRadius: 0)!;
      // 计数 [2,1,0,0,0,0] → /2
      expect(curve.values[0], closeTo(1.0, 1e-9));
      expect(curve.values[1], closeTo(0.5, 1e-9));
      expect(curve.values[2], closeTo(0, 1e-9));
    });

    test('尖峰被平滑摊到相邻桶（平滑真的生效）', () {
      // 全部弹幕挤在第 3 桶（20..30s）
      final list = [for (var i = 0; i < 10; i++) _dm(21 + i * 0.5)];
      final curve = buildHeatCurve(list, durationMs: 60000)!;
      expect(curve.values[2], closeTo(1.0, 1e-9), reason: '峰值桶');
      expect(curve.values[1], greaterThan(0), reason: '左邻桶被摊到');
      expect(curve.values[3], greaterThan(0), reason: '右邻桶被摊到');
      expect(curve.values[0], closeTo(0, 1e-9), reason: '隔一桶仍为 0');
      expect(curve.values[5], closeTo(0, 1e-9));
    });

    test('边缘平滑按实际窗口数取均值（片头不被拉向 0）', () {
      // 每桶各 1 条 → 平滑后处处 1（边缘若除以固定 3 会变成 2/3）
      final list = [for (var i = 0; i < 6; i++) _dm(i * 10 + 1)];
      final curve = buildHeatCurve(list, durationMs: 60000)!;
      for (final v in curve.values) {
        expect(v, closeTo(1.0, 1e-9));
      }
    });

    test('归一化：所有值 0..1，且最大值恰为 1', () {
      final list = [for (var i = 0; i < 40; i++) _dm(i * 1.3)];
      final curve = buildHeatCurve(list, durationMs: 60000)!;
      expect(curve.values.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-9));
      for (final v in curve.values) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('恰好落在时长上的弹幕不计入（不造片尾尖峰）', () {
      final list = [_dm(5), _dm(60)];
      final curve = buildHeatCurve(list, durationMs: 60000)!;
      expect(curve.values[5], closeTo(0, 1e-9),
          reason: 't=60 已到片尾外，不能落进最后一桶');
    });
  });

  group('超长视频与切 P', () {
    test('10 小时视频桶数封顶 600，桶宽自动放宽到 60s', () {
      const durationMs = 10 * 3600 * 1000; // 36,000,000ms
      final list = [for (var i = 0; i < 100; i++) _dm(i * 300.0)];
      final curve = buildHeatCurve(list, durationMs: durationMs)!;

      expect(curve.values, hasLength(600));
      expect(curve.bucketSec, closeTo(60, 1e-9));
    });

    test('超长视频依然保持 0..1 归一化，且点数恒定', () {
      const durationMs = 24 * 3600 * 1000;
      final list = [for (var i = 0; i < 50; i++) _dm(i * 1000.0)];
      final curve = buildHeatCurve(list, durationMs: durationMs)!;
      expect(curve.values.length, kHeatMaxBuckets);
      expect(curve.values.reduce((a, b) => a > b ? a : b),
          closeTo(1.0, 1e-9));
    });

    test('切 P = 换时长 → 桶数与时长随之变化（曲线按当前集重算）', () {
      final list = [_dm(0), _dm(5), _dm(15), _dm(25)];
      final p1 = buildHeatCurve(list, durationMs: 60000)!;
      final p2 = buildHeatCurve(list, durationMs: 120000)!;

      expect(p1.values, hasLength(6));
      expect(p2.values, hasLength(12));
      expect(p2.durationMs, 120000);
      expect(p1.values, isNot(equals(p2.values)),
          reason: '同一批弹幕换了时长，曲线必须不同（重新分桶）');
    });
  });

  test('isDrawable：至少 2 个点才画', () {
    final curve = buildHeatCurve([_dm(1), _dm(15)], durationMs: 60000)!;
    expect(curve.isDrawable, isTrue);
    expect(
      const HeatCurve(values: [1.0], bucketSec: 10, durationMs: 10000)
          .isDrawable,
      isFalse,
    );
  });
}
