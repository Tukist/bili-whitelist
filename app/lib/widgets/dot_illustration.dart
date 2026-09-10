import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import 'dot_halftone.dart';

/// 「随机细线插画」：空状态的门面（mono-color 印刷美学——留白、平面、细线）。
///
/// 按 [seed] 生成 5–9 条 1px 细线（折线 / 弧）+ 1 个点缀色小点 + 一角半调网点。
/// 线端点用小圆点收尾（细线插画的一点手感），四周留白充足：插画内容只占
/// 中间约 68% 的方框，**不填满** [size]。
///
/// **确定性**：同一个 [seed] → 同样的图案（"随机"是观感多样，不是每次刷新
/// 变化）。种子走 [stableSeed] 的稳定哈希，跨重建 / 跨运行一致，不闪烁。
///
/// 用法：按页面 ID 传 [seed]，例如 `DotIllustration(seed: 'empty.history')`；
/// 这样每个页面的空态插画各自稳定成一张「版画」，同一页刷新不变样。
class DotIllustration extends StatelessWidget {
  const DotIllustration({
    super.key,
    required this.seed,
    this.size = 160,
    this.ink,
    this.accent,
  });

  /// 图案种子（按页面 ID 传，如 `'empty.history'`）。
  final String seed;

  /// 方框边长（px）；内容约占其中 68%，其余是留白。
  final double size;

  /// 线条色；默认 [AppPalette.inkText]（已过 4.5:1 对比度护栏）。
  final Color? ink;

  /// 点缀色；默认 [AppPalette.accent]。
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    if (size <= 0) return const SizedBox.shrink();
    final inkColor = ink ?? context.palette.inkText;
    final accentColor = accent ?? context.palette.accent;
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _DotIllustrationPainter(
            seed: stableSeed(seed),
            ink: inkColor,
            accent: accentColor,
          ),
        ),
      ),
    );
  }
}

class _DotIllustrationPainter extends CustomPainter {
  const _DotIllustrationPainter({
    required this.seed,
    required this.ink,
    required this.accent,
  });

  final int seed;
  final Color ink;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 留白：内容只占中间约 68% 的方框
    final padX = size.width * 0.16;
    final padY = size.height * 0.16;
    final left = padX;
    final right = size.width - padX;
    final top = padY;
    final bottom = size.height - padY;
    final w = right - left;
    final h = bottom - top;
    if (w <= 4 || h <= 4) return;

    final rng = math.Random(seed);
    // 先铺一角的半调网点（垫在细线之下，不抢线条的清晰度）
    _paintCornerHalftone(canvas, size, rng);

    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final dot = Paint()
      ..color = ink
      ..isAntiAlias = true;

    final count = 5 + rng.nextInt(5); // 5..9 条
    final band = h / count;

    for (var i = 0; i < count; i++) {
      // 每条线在自己的横向「带」里，带内上下浮动 → 整体疏密自然
      final baseY = top + band * (i + 0.25 + rng.nextDouble() * 0.5);
      final startX = left + w * (0.02 + rng.nextDouble() * 0.12);
      final endX = right - w * (0.02 + rng.nextDouble() * 0.24);
      if (endX - startX < 8) continue;

      if (rng.nextInt(4) == 0) {
        // 约 1/4 的线改成弧：细线插画的一点脾气（仍是 1px）
        final rect = Rect.fromLTWH(startX, baseY - band * 0.55,
            endX - startX, band * 1.1);
        final start = rng.nextBool() ? math.pi : 0.0;
        canvas.drawArc(rect, start, math.pi, false, line);
        canvas.drawCircle(Offset(startX, baseY), 1.2, dot);
        canvas.drawCircle(Offset(endX, baseY), 1.2, dot);
        continue;
      }

      // 折线：2–3 段
      final segments = 2 + rng.nextInt(2);
      final stepX = (endX - startX) / segments;
      final path = Path()..moveTo(startX, baseY);
      var lastY = baseY;
      for (var s = 1; s <= segments; s++) {
        lastY = baseY + (rng.nextDouble() - 0.5) * band * 1.1;
        path.lineTo(startX + stepX * s, lastY);
      }
      canvas.drawPath(path, line);
      // 端点小圆点收尾（克制的细节，不做箭头）
      canvas.drawCircle(Offset(startX, baseY), 1.2, dot);
      canvas.drawCircle(Offset(endX, lastY), 1.2, dot);
    }

    // 1 个点缀色小点（时间 / 新鲜度的墨，只点一颗）
    final accX = left + w * (0.18 + rng.nextDouble() * 0.64);
    final accY = top + h * (0.2 + rng.nextDouble() * 0.6);
    canvas.drawCircle(Offset(accX, accY), 2.6, Paint()..color = accent);
  }

  /// 四角之一画一小片半调网点：间距 4.5、半径 ~0.9、
  /// 墨色降到 28% 不透明度，保证不与细线抢注意力。
  void _paintCornerHalftone(Canvas canvas, Size size, math.Random rng) {
    const spacing = 4.5;
    const dotR = 0.9;
    final patch = size.shortestSide * 0.30;
    if (patch < spacing * 3) return;
    final corner = rng.nextInt(4);
    final isLeft = corner == 0 || corner == 2;
    final isTop = corner < 2;
    final originX = isLeft ? 0.0 : size.width - patch;
    final originY = isTop ? 0.0 : size.height - patch;

    final paint = Paint()
      ..color = ink.withValues(alpha: 0.28)
      ..isAntiAlias = true;
    final cols = (patch / spacing).ceil();
    // 越靠近角越密：靠近页角的两行两列才画，形成「一角」的裁切感
    for (var row = 0; row < cols; row++) {
      for (var col = 0; col < cols; col++) {
        final cx = originX + spacing / 2 + col * spacing;
        final cy = originY + spacing / 2 + row * spacing;
        // 对角裁切：离角越远点越小，超出 patch 不画
        final dx = (col + 0.5) * spacing;
        final dy = (row + 0.5) * spacing;
        final t = ((dx + dy) / (patch * 1.4)).clamp(0.0, 1.0);
        final r = dotR * (1 - t * 0.7);
        if (r <= 0.15 || cx > size.width || cy > size.height) continue;
        canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotIllustrationPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.ink != ink ||
      oldDelegate.accent != accent;
}
