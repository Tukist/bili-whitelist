import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 稳定字符串哈希（FNV-1a 32 位，纯函数）。
///
/// 半调网点与细线插画都要求「同一个 seed + 尺寸 → 同样的图案，重建不闪烁」，
/// 所以不用 `String.hashCode`：它在不同 Dart 版本 / 平台上不保证稳定，
/// 会把「确定性随机」变成「随 SDK 版本漂移的图案」。
int stableSeed(String seed) {
  var hash = 0x811C9DC5;
  for (final unit in seed.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// 半调网点底（mono-color 的 "halftone" 质感）。
///
/// 印刷网点的观感：等距排布的小圆点，按「墨量」从左上到右下由大变小、
/// 由密到疏，中间带一点确定性微抖动（避免机械棋盘感）。这是官方认可的
/// 质感手法，**只在「空态插画」与「封面占位」两处使用**，其余地方不用。
///
/// - 确定性：同一个 [seed] + 同一尺寸 → 同样的点阵，重建不闪烁；
///   点半径不用全局 `Random()`（那会每帧变），而是坐标整数哈希 + 平滑渐变。
/// - 性能：外面套 [RepaintBoundary]；点阵不重绘时不会跟着父级刷新。
/// - [color] 建议带低透明度（约 8%~14% 的墨），网点只做「质感」不做主体，
///   太实会盖过上面的内容。
/// - 无 [child] 时撑满父级约束（**需要有界约束**，例如放在 `Stack` /
///   `SizedBox` / `Container` 里）；要固定尺寸请自行套 `SizedBox`。
///   有 [child] 时网点画在 [child] 背后（当底纹用）。
class HalftonePattern extends StatelessWidget {
  const HalftonePattern({
    super.key,
    required this.color,
    this.spacing = 6,
    this.seed = '',
    this.child,
  });

  /// 网点色（建议带低透明度）。
  final Color color;

  /// 网点间距（px）。
  final double spacing;

  /// 决定点半径确定性变化的种子；默认 ''。
  final String seed;

  /// 网点之上的内容。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _HalftonePainter(
          color: color,
          // 间距非法（0 / 负）时回退默认，避免除零与死循环
          spacing: spacing > 0 ? spacing : 6,
          seed: stableSeed(seed),
        ),
        child: child ?? const SizedBox.expand(),
      ),
    );
  }
}

class _HalftonePainter extends CustomPainter {
  const _HalftonePainter({
    required this.color,
    required this.spacing,
    required this.seed,
  });

  final Color color;
  final double spacing;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    final cols = (size.width / spacing).ceil();
    final rows = (size.height / spacing).ceil();
    final minR = spacing * 0.05;
    final maxR = spacing * 0.42;
    // 归一化对角线：左上墨量最足（点最大）→ 右下最淡（点最小）
    final span = math.max(size.width + size.height, 1.0);

    for (var row = 0; row < rows; row++) {
      final cy = row * spacing + spacing / 2;
      if (cy > size.height) continue;
      for (var col = 0; col < cols; col++) {
        final cx = col * spacing + spacing / 2;
        if (cx > size.width) continue;
        final t = ((cx + cy) / span).clamp(0.0, 1.0);
        // 平滑渐变权重（1 → 0.25）× 确定性微抖动（0.75 → 1.0）
        final tone = (1 - t * 0.75) * (0.75 + 0.25 * _jitter(col, row));
        final r = minR + (maxR - minR) * tone;
        if (r <= 0.05) continue;
        canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
  }

  /// 坐标 → [0,1] 的确定性伪随机（整数位运算哈希，与帧无关）。
  double _jitter(int col, int row) {
    var h = seed ^ (col * 0x27D4EB2D) ^ (row * 0x165667B1);
    h &= 0xFFFFFFFF;
    h ^= h >> 15;
    h = (h * 0x2545F491) & 0xFFFFFFFF;
    h ^= h >> 13;
    return (h & 0xFFFF) / 0xFFFF;
  }

  @override
  bool shouldRepaint(_HalftonePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.spacing != spacing ||
      oldDelegate.seed != seed;
}
