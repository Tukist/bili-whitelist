// 热度曲线密度算法单测（v2.61.0+，v2.62.0 按新算法重写）：
// - 分桶：按 5s 一桶计数（含边界：t=0 / t 落在桶首 / 末尾桶）
// - 平滑：高斯核（σ=1.2 桶、半径 3 桶），边缘按实际存在的桶归一化（不拉向 0）
// - 拉伸：P5 抬底、P98 封顶、分母带 0.20*peak 下限 → 背景沉底、峰值顶格
// - 伽马 1.6 → 中间段再压一档（"梯度被拉开"就在这里）
// - 空输入 / 时长为 0 / 单桶 / 超长视频（桶数封顶）/ 脏时间 / 全零 / 完全平齐 → 不画线
// - 切 P 语义：同一批弹幕换 duration（新集时长）→ 桶数随之变化
//
// ## v2.62.0 为什么改了这批断言（逐条理由见各用例的 `v2.62.0:` 注释）
// 用户反馈「热度线不够光滑、梯度太小、总体太平」，算法从
// 「10s 桶 + 3 桶平均 + 除以最大值」换成
// 「5s 桶 + 高斯平滑 + P5/P98 拉伸 + 伽马」，于是：
// - 桶数翻倍（10s → 5s），所有"6 桶"之类的形状断言都要按 12 桶重写；
// - 数值不再是"计数 ÷ 最大值"能心算出来的，改成断言**性质**（峰值 1、
//   单调、对称、峰宽、差分方差、背景与峰值的落差），比钉死小数更抗调参。
import 'dart:math' as math;

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

/// 按「每桶几条」造弹幕：第 i 桶塞 n 条，均匀铺在桶内。
List<Danmaku> _fromCounts(List<int> counts, {double step = 5}) {
  final out = <Danmaku>[];
  for (var i = 0; i < counts.length; i++) {
    final n = counts[i];
    for (var j = 0; j < n; j++) {
      out.add(_dm(i * step + (j + 0.5) * step / n));
    }
  }
  return out;
}

/// 相邻点差分的平方均值（"平滑不平滑"的量化指标：越小越光滑）。
double _diffVar(List<double> v) {
  var sum = 0.0;
  for (var i = 1; i < v.length; i++) {
    final d = v[i] - v[i - 1];
    sum += d * d;
  }
  return sum / (v.length - 1);
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

int _argMax(List<double> v) {
  var k = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[k]) k = i;
  }
  return k;
}

/// v2.61.0 的显示映射（10s 一桶 + 半径 1 的三桶平均 + 除以最大值）。
///
/// 只在测试里留作**对照组**：用来证明「梯度确实被拉开了」不是自说自话
/// （同一份输入，老映射 peak - median = 0.54，新映射 = 1.00）。
List<double> _legacyV261(List<int> counts5s) {
  final c10 = [
    for (var i = 0; i < counts5s.length ~/ 2; i++)
      counts5s[2 * i] + counts5s[2 * i + 1]
  ];
  final smoothed = <double>[];
  for (var i = 0; i < c10.length; i++) {
    final from = math.max(0, i - 1);
    final to = math.min(c10.length - 1, i + 1);
    var sum = 0;
    for (var j = from; j <= to; j++) {
      sum += c10[j];
    }
    smoothed.add(sum / (to - from + 1));
  }
  final max = smoothed.reduce(math.max);
  return [for (final v in smoothed) v / max];
}

void main() {
  group('不画线（返回 null）', () {
    test('弹幕为空 → null', () {
      expect(buildHeatCurve(const [], durationMs: 60000), isNull);
    });

    test('时长为 0 / 负数（onPrepared 还没回来）→ null', () {
      expect(buildHeatCurve([_dm(1)], durationMs: 0), isNull);
      expect(buildHeatCurve([_dm(1)], durationMs: -5), isNull);
    });

    test('单桶（时长 <= 一桶 = 5s）→ null（一个点画不出线，不画平线）', () {
      // v2.62.0：桶宽 10s → 5s，判定阈值随之从"20s"变成"5s"。
      // 行为没变（只有 1 个桶才不画），变的是这个门槛落在哪。
      expect(buildHeatCurve([_dm(1), _dm(2)], durationMs: 5000), isNull);
      expect(buildHeatCurve([_dm(1)], durationMs: 3000), isNull);
      // 5.1s → 2 桶 → 能画（证明门槛真的在"1 桶"而不是别的数）
      expect(buildHeatCurve([_dm(1), _dm(4)], durationMs: 5100), isNotNull);
    });

    test('弹幕全是脏时间（负数 / 超时长 / NaN）→ null（不造片尾尖峰）', () {
      final list = [_dm(-1), _dm(999), _dm(double.nan)];
      expect(buildHeatCurve(list, durationMs: 60000), isNull);
    });

    test('桶数上限小于 2 → null（调用方传错也不崩）', () {
      expect(
        buildHeatCurve([_dm(1)], durationMs: 60000, maxBuckets: 1),
        isNull,
      );
    });

    // v2.62.0 新增：拉伸会把"有起伏"放大，那么"没起伏"就必须明确不画，
    // 否则会出现一条贴底的假线（用户看不出这是"没有高潮"还是"数据没来"）。
    test('密度完全平齐（每桶一样多）→ null（没有高潮可画）', () {
      final flat = [for (var i = 0; i < 6; i++) _dm(i * 5 + 1)];
      expect(buildHeatCurve(flat, durationMs: 30000), isNull);
    });
  });

  group('分桶（5s 一桶）', () {
    test('60s → 12 桶，桶宽 5s', () {
      final curve = buildHeatCurve([_dm(1), _dm(30)], durationMs: 60000)!;
      // v2.62.0：10s 一桶的 6 桶 → 5s 一桶的 12 桶（点更多才够光滑）
      expect(curve.values, hasLength(12));
      expect(curve.bucketSec, 5);
      expect(curve.durationMs, 60000);
    });

    test('桶边界：t=5 归第 1 桶，t=4.9 归第 0 桶', () {
      // 单条弹幕的峰值桶 = 它所在的桶（断言 argmax 而不是绝对数值，
      // 因为数值已经被拉伸/伽马改造成非线性的了）
      expect(_argMax(buildHeatCurve([_dm(5)], durationMs: 60000)!.values), 1);
      expect(_argMax(buildHeatCurve([_dm(4.9)], durationMs: 60000)!.values), 0);
      expect(_argMax(buildHeatCurve([_dm(0)], durationMs: 60000)!.values), 0);
    });

    test('恰好落在时长上的弹幕不计入（不造片尾尖峰）', () {
      // t == duration 是片尾外（[0, duration) 半开区间）→ 一条都不剩 → null
      expect(buildHeatCurve([_dm(60)], durationMs: 60000), isNull);
      expect(_argMax(buildHeatCurve([_dm(59.9)], durationMs: 60000)!.values), 11);
    });
  });

  group('平滑与峰形', () {
    test('heatSmooth：常数输入 → 常数输出（边缘不塌向 0）', () {
      // v2.62.0：老用例是"每桶 1 条 → 整条 1.0"，但新算法把"完全平齐"
      // 判成 null（没有高潮）。同样的意图（边缘不能被拉向 0）改成直接测
      // 平滑器：常数序列平滑后必须还是常数。
      for (final v in heatSmooth(const [3, 3, 3, 3, 3])) {
        expect(v, closeTo(3, 1e-9));
      }
    });

    test('heatSmooth：单点脉冲 → 中心最高、左右对称、远处归零', () {
      final s = heatSmooth(const [0, 0, 0, 1, 0, 0, 0]);
      expect(s[3], closeTo(s.reduce(math.max), 1e-12));
      expect(s[3], greaterThan(s[2]));
      expect(s[3], greaterThan(s[4]));
      expect(s[2], closeTo(s[4], 1e-12), reason: '对称');
      expect(s[1], closeTo(s[5], 1e-12));
      expect(s[0], closeTo(s[6], 1e-12));
      expect(s[0], lessThan(0.05), reason: '半径 3 桶之外基本为 0');
    });

    test('尖峰被摊到相邻桶，但峰形还在（没被抹成缓坡）', () {
      // 10 条全挤在第 4 桶（20..25s）；60s / 5s = 12 桶
      final list = [for (var i = 0; i < 10; i++) _dm(21 + i * 0.3)];
      final values = buildHeatCurve(list, durationMs: 60000)!.values;

      expect(values[4], closeTo(1.0, 1e-9), reason: '峰值桶仍是顶格');
      expect(values[3], greaterThan(0), reason: '左邻桶被摊到');
      expect(values[5], greaterThan(0), reason: '右邻桶被摊到');
      expect(values[3], closeTo(values[5], 1e-6), reason: '单峰左右对称');
      // 峰宽：±1 桶仍在半高以上，±2 桶已落到半高以下 —— 高斯核没有把峰抹平
      expect(values[3], greaterThan(0.5));
      expect(values[5], greaterThan(0.5));
      expect(values[2], lessThan(0.5));
      expect(values[6], lessThan(0.5));
      expect(values[0], closeTo(0, 1e-9), reason: '远离尖峰的桶沉到底');
      expect(values[11], closeTo(0, 1e-9));
    });

    test('输出范围：所有值 0..1，且峰值恰为 1', () {
      final list = [for (var i = 0; i < 40; i++) _dm(i * 1.3)];
      final curve = buildHeatCurve(list, durationMs: 60000)!;
      expect(curve.values.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-9));
      for (final v in curve.values) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('梯度被拉开（v2.62.0 重点）', () {
    /// 一条 20 分钟的视频：背景 6~7 条/桶、两段副歌 10~11 条/桶、
    /// 中段一个 35 秒的高潮 14 条/桶 —— 就是用户说的"密度本来就比较均匀"。
    List<int> peakishCounts() => [
          for (var i = 0; i < 240; i++)
            if (i >= 118 && i < 125)
              14
            else if ((i >= 60 && i < 100) || (i >= 150 && i < 190))
              10 + (i % 2)
            else
              6 + (i % 2)
        ];

    test('单峰视频：峰值归一化到 1，且与背景的落差 ≥ 0.6', () {
      final counts = peakishCounts();
      final values = buildHeatCurve(
        _fromCounts(counts),
        durationMs: 20 * 60 * 1000,
      )!
          .values;

      final peak = values.reduce(math.max);
      final diff = peak - _median(values);
      expect(peak, closeTo(1.0, 1e-9), reason: '峰值顶格');
      expect(diff, greaterThanOrEqualTo(0.6),
          reason: '中位数要被压到底 → 梯度拉开（实测 1.0000）');
      expect(_median(values), lessThan(0.05), reason: '背景接近底部');
    });

    test('同一份输入：老映射（除以最大值）明显更平', () {
      // 这是"改前 vs 改后"的量化证据：老映射 peak - median ≈ 0.54，
      // 新映射 ≈ 1.00。不写死小数，只断言"新的至少拉开 0.3 以上"。
      final counts = peakishCounts();
      final legacy = _legacyV261(counts);
      final legacyDiff = legacy.reduce(math.max) - _median(legacy);

      final values = buildHeatCurve(
        _fromCounts(counts),
        durationMs: 20 * 60 * 1000,
      )!
          .values;
      final newDiff = values.reduce(math.max) - _median(values);

      expect(legacyDiff, lessThan(0.6),
          reason: '改前的映射：peak≈1、median≈0.46 → 落差只有 0.54');
      expect(newDiff, greaterThan(legacyDiff + 0.3),
          reason: '改后落差比改前多 0.3 以上（梯度被拉开）');
    });

    test('平滑度：同一份输入，平滑后的相邻差分平方均值 < 未平滑的一半', () {
      final counts = peakishCounts();
      final list = _fromCounts(counts);
      final smooth = buildHeatCurve(list, durationMs: 20 * 60 * 1000)!;
      final raw =
          buildHeatCurve(list, durationMs: 20 * 60 * 1000, smoothSigma: 0)!;

      final smoothVar = _diffVar(smooth.values);
      final rawVar = _diffVar(raw.values);
      expect(smoothVar, lessThan(rawVar * 0.5),
          reason: '实测 smooth/raw ≈ 0.30；阈值给到 0.5 留余量');
    });

    test('平坦视频不放大噪声：峰值抬不起来（改前恒为 1.0）', () {
      // 每桶 3~5 条的纯抖动（没有真正的高潮）。老映射除以最大值 →
      // 抖动的最高点 = 1.0，整条线撑满；新算法的 0.20*peak 分母下限
      // 会把这种"没起伏"的曲线压在底部，不把 1 条弹幕的随机差放大成一座山。
      final noise = [for (var i = 0; i < 240; i++) 3 + ((i * 11) % 3)];
      final values =
          buildHeatCurve(_fromCounts(noise), durationMs: 20 * 60 * 1000)!
              .values;
      expect(values.reduce(math.max), lessThan(0.3),
          reason: '实测 0.163 —— 密度平齐就不硬凑一个满高的"假峰"');
      expect(_legacyV261(noise).reduce(math.max), closeTo(1.0, 1e-9),
          reason: '对照：老映射会把同样的抖动撑到顶格');
    });
  });

  group('单调性与超长视频', () {
    test('输入单调递增 → 输出单调（高斯核 + 单调映射，容差 1e-9）', () {
      // 每桶弹幕数 0,1,2,…,39（200s / 5s = 40 桶）
      final list = _fromCounts([for (var i = 0; i < 40; i++) i]);
      final values = buildHeatCurve(list, durationMs: 200000)!.values;
      var worst = 0.0;
      for (var i = 1; i < values.length; i++) {
        final d = values[i] - values[i - 1];
        if (d < worst) worst = d;
      }
      expect(worst, greaterThanOrEqualTo(-1e-9),
          reason: '只允许浮点级回撤，不允许真的往下掉');
      expect(values.last, greaterThan(values.first));
      expect(values.last, closeTo(1.0, 1e-9));
    });

    test('10 小时视频桶数封顶 600，桶宽自动放宽到 60s', () {
      const durationMs = 10 * 3600 * 1000; // 36,000,000ms
      final list = [for (var i = 0; i < 100; i++) _dm(i * 300.0)];
      final curve = buildHeatCurve(list, durationMs: durationMs)!;

      expect(curve.values, hasLength(600));
      expect(curve.bucketSec, closeTo(60, 1e-9));
    });

    test('超长视频依然保持 0..1，且点数恒定', () {
      const durationMs = 24 * 3600 * 1000;
      final list = [for (var i = 0; i < 50; i++) _dm(i * 1000.0)];
      final curve = buildHeatCurve(list, durationMs: durationMs)!;
      expect(curve.values.length, kHeatMaxBuckets);
      expect(curve.values.reduce((a, b) => a > b ? a : b),
          closeTo(1.0, 1e-9));
      for (final v in curve.values) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('切 P = 换时长 → 桶数与时长随之变化（曲线按当前集重算）', () {
      final list = [_dm(0), _dm(5), _dm(15), _dm(25)];
      final p1 = buildHeatCurve(list, durationMs: 60000)!;
      final p2 = buildHeatCurve(list, durationMs: 120000)!;

      // v2.62.0：6/12 桶 → 12/24 桶（桶宽减半），意图不变
      expect(p1.values, hasLength(12));
      expect(p2.values, hasLength(24));
      expect(p2.durationMs, 120000);
      expect(p1.values, isNot(equals(p2.values)),
          reason: '同一批弹幕换了时长，曲线必须不同（重新分桶）');
    });
  });

  test('isDrawable：至少 2 个点才画', () {
    final curve = buildHeatCurve([_dm(1), _dm(15)], durationMs: 60000)!;
    expect(curve.isDrawable, isTrue);
    expect(
      const HeatCurve(values: [1.0], bucketSec: 5, durationMs: 5000)
          .isDrawable,
      isFalse,
    );
  });
}
