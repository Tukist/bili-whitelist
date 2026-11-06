// 热度曲线「绘制几何」单测（v2.62.0 新增）：
// 用户反馈「让热度线变成更加光滑的曲线」——v2.61.0 是逐点 lineTo 的折线，
// 现在每两个采样点之间铺一段三次贝塞尔（Catmull-Rom 切线）。Path 一旦交给
// Canvas 就没法再查它是直线还是曲线，所以路径构造抽成纯函数
// `heatCurveCubics`（lib/widgets/heat_curve_bar.dart），在这里断言几何：
// - 段数 = 点数-1，每段两个控制点（= 真的用 cubicTo 铺出来的曲线）
// - 段端点严格落在采样点上（曲线穿过每个桶的值，峰不会被"磨圆"偏位）
// - 段与段在连接点切线连续（C1）→ 画出来没有折角
// - 中点的实际位置偏离"两点直线"的中点（= 有曲率，不是折线）
// - 控制点不出带（填充闭合到带底，出带会被裁出硬边）
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/widgets/heat_curve_bar.dart';

/// 三次贝塞尔在参数 t 处的点。
Offset _bezier(HeatCurveCubic s, double t) {
  final u = 1 - t;
  return s.start * (u * u * u) +
      s.c1 * (3 * u * u * t) +
      s.c2 * (3 * u * t * t) +
      s.end * (t * t * t);
}

/// 三次贝塞尔在参数 t 处的切线（未归一化）。
Offset _tangent(HeatCurveCubic s, double t) {
  final u = 1 - t;
  return (s.c1 - s.start) * (3 * u * u) +
      (s.c2 - s.c1) * (6 * u * t) +
      (s.end - s.c2) * (3 * t * t);
}

void main() {
  const size = Size(400, 100);
  const padTop = 1.0;

  test('每两个采样点一段三次贝塞尔（点数-1 段，每段两个控制点）', () {
    final values = [0.0, 0.2, 0.9, 0.4, 0.1];
    final segs = heatCurveCubics(values, size);
    expect(segs, hasLength(values.length - 1));
    // 每段两端 + 两个控制点都必须是有限数（真的算出了控制点，不是退化）
    for (final s in segs) {
      for (final p in [s.start, s.c1, s.c2, s.end]) {
        expect(p.dx.isFinite && p.dy.isFinite, isTrue);
      }
    }
    // x 沿时间轴等分：第 i 段的起点就在 i 个等分处
    final stepX = size.width / (values.length - 1);
    for (var i = 0; i < segs.length; i++) {
      expect(segs[i].start.dx, closeTo(i * stepX, 1e-9));
      expect(segs[i].end.dx, closeTo((i + 1) * stepX, 1e-9));
    }
  });

  test('曲线严格穿过采样点（端点 y = padTop + 可用高 * (1-v)）', () {
    final values = [0.0, 0.25, 1.0, 0.5, 0.0];
    final segs = heatCurveCubics(values, size);
    final usableH = size.height - padTop;

    Offset pointOf(int i) => Offset(
          i * size.width / (values.length - 1),
          padTop + usableH * (1 - values[i]),
        );

    for (var i = 0; i < segs.length; i++) {
      expect((segs[i].start - pointOf(i)).distance, lessThan(1e-9),
          reason: '第 $i 段起点必须落在采样点上');
      expect((segs[i].end - pointOf(i + 1)).distance, lessThan(1e-9),
          reason: '第 $i 段终点必须落在采样点上');
    }
  });

  test('段间切线连续（C1）：连接点没有折角', () {
    // 用一条平滑起伏（不带突变，避免控制点被夹取干扰）验相切
    final values = [
      for (var i = 0; i < 12; i++) 0.5 + 0.4 * math.sin(i * math.pi / 6)
    ];
    final segs = heatCurveCubics(values, size);
    for (var i = 0; i + 1 < segs.length; i++) {
      final out = _tangent(segs[i], 1) / 3; // = end - c2
      final into = _tangent(segs[i + 1], 0) / 3; // = c1 - start
      expect((out - into).distance, lessThan(1e-9),
          reason: '第 $i 与第 ${i + 1} 段在连接点必须同切线（C1）');
    }
  });

  test('真的是曲线：中点明显偏离两点直线（不是 lineTo）', () {
    // 尖峰 [0,1,0]：直线在中点高度 50.5，贝塞尔因切线被拉向峰顶，明显更高
    final segs = heatCurveCubics(const [0.0, 1.0, 0.0], size);
    final cubicMid = _bezier(segs[0], 0.5);
    // 同一 x 处"两点直线"的高度（Catmull-Rom 的 x 不严格等参数，按 x 折算）
    final frac = (cubicMid.dx - segs[0].start.dx) /
        (segs[0].end.dx - segs[0].start.dx);
    final linearY =
        segs[0].start.dy + (segs[0].end.dy - segs[0].start.dy) * frac;

    expect((cubicMid.dy - linearY).abs(), greaterThan(2),
        reason: '偏离直线 2px 以上才算"曲线"（实测 ≈12px）');
    expect(cubicMid.dy, lessThan(linearY),
        reason: '尖峰两侧的曲线应被拉向峰顶（y 更小 = 更高）');
  });

  test('控制点 y 不出带（填充闭合到带底，出带会被裁出硬边）', () {
    // 陡变 + 尖峰最容易让 Catmull-Rom 过冲
    final segs = heatCurveCubics(
      const [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0],
      size,
    );
    for (final s in segs) {
      for (final p in [s.c1, s.c2]) {
        expect(p.dy, greaterThanOrEqualTo(padTop - 1e-9));
        expect(p.dy, lessThanOrEqualTo(size.height + 1e-9));
      }
    }
  });

  test('退化输入：少于 2 点 / 尺寸非法 → 空（调用方据此不画）', () {
    expect(heatCurveCubics(const [], size), isEmpty);
    expect(heatCurveCubics(const [0.5], size), isEmpty);
    expect(heatCurveCubics(const [0.1, 0.9], const Size(0, 100)), isEmpty);
    expect(heatCurveCubics(const [0.1, 0.9], const Size(400, 0)), isEmpty);
    // 带高只有 padTop：可用高 <= 0 → 不画
    expect(heatCurveCubics(const [0.1, 0.9], const Size(400, padTop)), isEmpty);
  });

  test('两点也能画（最少 2 点是 isDrawable 的下限）', () {
    final segs = heatCurveCubics(const [0.0, 1.0], size);
    expect(segs, hasLength(1));
    expect(segs[0].start, const Offset(0, 100));
    expect(segs[0].end, const Offset(400, 1));
  });
}
