/// 进度条上方的「热度高潮线」绘制层（v2.61.0+，v2.62.0 改贝塞尔曲线）。
///
/// 只画一条极细的填充曲线（+ 1px 顶边），数据来自 [HeatCurve]（弹幕密度，
/// 算法见 `lib/services/heat_curve.dart`）。
///
/// ## 为什么是独立 widget 且必须 `IgnorePointer`
/// 这一层**叠在进度条的命中带里**（进度条行高 40，轨道在正中，曲线占上方
/// 那十几像素）。任何可命中控件都会抢走水平拖动/点按——所以：
/// - 整层包 [IgnorePointer]：命中一律穿透给下层的 `GestureDetector`，
///   拖动 / 点按跳转 / 缩略图预览气泡的语义一个字节都不变；
/// - 不注册任何手势、不加 `Semantics` 节点（纯装饰，读屏不该读到它）。
///
/// ## 为什么是曲线（v2.62.0）
/// v2.61.0 是逐点 `lineTo` 的折线：桶一多就是一圈小棱角，放大看是锯齿。
/// 现在每两个采样点之间铺一段**三次贝塞尔**，控制点由 Catmull-Rom
/// 切线推出（[heatCurveCubics]）：曲线**严格穿过每个采样点**（不像二次贝塞尔
/// 那样把峰磨圆），同时在采样点处切线连续（C1），看起来就是一条光滑的线。
///
/// ## 样式
/// 颜色全部走 token（[kInkClay] 点缀墨 = 「热度」这一类"新鲜/时效"信息），
/// 不写死色值：填充 28% + 顶边 72%，压在本 App 播放页恒定的深色底栏遮罩
/// （black54 渐变）上，浅色画面与夜间模式下都能读出来，且不抢已播段与柄。
library;

import 'package:flutter/material.dart';

import '../services/heat_curve.dart';
import '../theme/app_tokens.dart';

/// 曲线带顶部留 1px，避免顶边线贴着裁切边界被切掉一半。
const double kHeatCurvePadTop = 1;

/// 一段三次贝塞尔：从 [start] 到 [end]，[c1] / [c2] 是两个控制点。
///
/// 抽成公开的纯函数产物（[heatCurveCubics]）是为了**可测**：
/// `Path` 一旦交给 Canvas 就没法再查它到底是直线还是曲线，而这里的段结构
/// 能直接断言「每段都有两个控制点、且段端点落回采样点」。
@immutable
class HeatCurveCubic {
  final Offset start;
  final Offset c1;
  final Offset c2;
  final Offset end;

  const HeatCurveCubic({
    required this.start,
    required this.c1,
    required this.c2,
    required this.end,
  });

  @override
  String toString() => 'HeatCurveCubic($start, $c1, $c2, $end)';
}

/// 把归一化后的热度值铺成一条光滑曲线（Catmull-Rom 转三次贝塞尔）。
///
/// - 采样点 `(x_i, y_i)`：x 按桶数等分整条带；y = `padTop + usableH*(1-v)`；
/// - 第 i 段（p1=[start]、p2=[end]）的切线取相邻两点的割线：
///   `c1 = p1 + (p2 - p0)/6`、`c2 = p2 - (p3 - p1)/6`（p0/p3 首尾各夹到端点，
///   即"端点切线退化"——片头片尾不会甩出画外）；
/// - 控制点的 y 夹在带内：Catmull-Rom 在陡变处会过冲，夹一下保证曲线不出带
///   （填充路径闭合到带底，一旦出带就被裁切出硬边）。
///
/// 不足 2 个点 / 尺寸非法 → 空列表（调用方据此不画）。
List<HeatCurveCubic> heatCurveCubics(
  List<double> values,
  Size size, {
  double padTop = kHeatCurvePadTop,
}) {
  if (values.length < 2 || size.width <= 0 || size.height <= 0) {
    return const [];
  }
  final usableH = size.height - padTop;
  if (usableH <= 0) return const [];
  final stepX = size.width / (values.length - 1);
  final top = padTop;
  final bottom = size.height;

  final pts = List<Offset>.generate(values.length, (i) {
    final v = values[i].clamp(0.0, 1.0);
    return Offset(i * stepX, padTop + usableH * (1 - v));
  });

  double clampY(double y) => y < top ? top : (y > bottom ? bottom : y);

  final out = <HeatCurveCubic>[];
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = pts[i == 0 ? 0 : i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = pts[i + 2 >= pts.length ? pts.length - 1 : i + 2];

    final c1 = Offset(
      p1.dx + (p2.dx - p0.dx) / 6,
      clampY(p1.dy + (p2.dy - p0.dy) / 6),
    );
    final c2 = Offset(
      p2.dx - (p3.dx - p1.dx) / 6,
      clampY(p2.dy - (p3.dy - p1.dy) / 6),
    );
    out.add(HeatCurveCubic(start: p1, c1: c1, c2: c2, end: p2));
  }
  return out;
}

/// 热度曲线层。`curve == null` / 不足以成线时**不占位、不画**（返回空盒子）。
class HeatCurveBar extends StatelessWidget {
  /// 已算好的曲线（null = 数据未就绪 → 不画线）。
  final HeatCurve? curve;

  /// 测试锚点（挂在播放页进度条内的那一个实例上）。
  static const Key widgetKey = ValueKey('player-heat-curve');

  const HeatCurveBar({super.key, required this.curve});

  @override
  Widget build(BuildContext context) {
    final c = curve;
    if (c == null || !c.isDrawable) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _HeatCurvePainter(c),
        // 由父层 SizedBox/Positioned 给定尺寸（进度条内的固定高度带）
        size: Size.infinite,
      ),
    );
  }
}

class _HeatCurvePainter extends CustomPainter {
  final HeatCurve curve;

  const _HeatCurvePainter(this.curve);

  @override
  void paint(Canvas canvas, Size size) {
    final segments = heatCurveCubics(curve.values, size);
    if (segments.isEmpty) return;

    final line = Path()..moveTo(segments.first.start.dx, segments.first.start.dy);
    for (final s in segments) {
      line.cubicTo(s.c1.dx, s.c1.dy, s.c2.dx, s.c2.dy, s.end.dx, s.end.dy);
    }

    // 填充（曲线 → 底边闭合）：低透明度，压在轨道上方不抢戏
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..style = PaintingStyle.fill
        ..color = kInkClay.withValues(alpha: 0.28),
    );

    // 顶边 1px：让曲线在浅色画面上也有形状（填充本身太淡）
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeJoin = StrokeJoin.round
        ..color = kInkClay.withValues(alpha: 0.72),
    );
  }

  @override
  bool shouldRepaint(_HeatCurvePainter old) => !identical(old.curve, curve);
}
