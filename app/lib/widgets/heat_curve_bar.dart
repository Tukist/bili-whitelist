/// 进度条上方的「热度高潮线」绘制层（v2.61.0+）。
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
/// ## 样式
/// 颜色全部走 token（[kInkClay] 点缀墨 = 「热度」这一类"新鲜/时效"信息），
/// 不写死色值：填充 28% + 顶边 72%，压在本 App 播放页恒定的深色底栏遮罩
/// （black54 渐变）上，浅色画面与夜间模式下都能读出来，且不抢已播段与柄。
library;

import 'package:flutter/material.dart';

import '../services/heat_curve.dart';
import '../theme/app_tokens.dart';

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

  /// 顶部留 1px，避免顶边线贴着裁切边界被切掉一半。
  static const double _padTop = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final values = curve.values;
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;

    final usableH = size.height - _padTop;
    if (usableH <= 0) return;
    final stepX = size.width / (values.length - 1);
    double yOf(double v) =>
        _padTop + usableH * (1 - v.clamp(0.0, 1.0));

    final line = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = yOf(values[i]);
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
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
