import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/motion_control.dart';
import 'dot_halftone.dart';

/// 静态帧（[DotIllustration.animate] = false，或 [MotionControl.of] 为 false）
/// 取的相位。挑 0.35 只为**不落在呼吸周期的起手相**（t = 0 处 `sin` 恰好过零，
/// 那一帧网点的墨量最低、最像"没印上"）；0.35 处墨量已经起来，画面不空场。
const double kStaticWalkT = 0.35;

/// 空态"墨还活着"的呼吸周期：4.4s。
///
/// 比加载态的 `kPressCycle`（2.8s）更慢一档：加载态"有事在做"，可以有节拍；
/// 空态"没有事在发生"，只留一点墨的生气——**慢到看不出在干活**才对。
const Duration kBreathCycle = Duration(milliseconds: 4400);

/// 网点区整体墨量的呼吸幅度（相对量）：±20%。
///
/// 上一版把幅度压在 ±8% 且只作用在一颗 2.2px 的圆点上，设备实测"肉眼基本
/// 看不出——等于一张静态图"：落在感知阈值以下的变化等于白做。现在改成**整片
/// 网点**的墨量一起呼吸（面积大，"一整片墨在变浓变淡"比"一颗小点半径变了
/// 0.3px"好认），幅度提到 ±20%（0.28 → 0.224…0.336）。
///
/// 它没有变成"加载态的循环动画"：仍然只有 1 个运动元素、构图一个像素都不动，
/// 只是那层网的亮暗在慢慢起伏（`sin(2πt)`，t 绕回 0 时逐点重合）。
const double _kBreathAmplitude = 0.20;

/// 网点区的满档墨量（相对 [ink]）：印刷的半调网点本来就该是浅的一层。
const double _kHalftoneAlpha = 0.28;

/// 网点间距 / 网点半径（px）：印刷的网点屏。
const double _kHalftoneSpacing = 4.5;
const double _kHalftoneDotR = 0.9;

/// 点缀墨圆点的半径（px）。空态用**圆点**、加载态用**短竖条**（刃 = 笔尖），
/// 两种墨的语义分工不混：圆点 = "刚落下的一点墨"，竖条 = 排版的字锤。
const double _kDotRadius = 2.2;

/// 沿线渐隐的段数（相邻段共用端点 + 1px 圆头，接缝看不出来）。
const int _kFadeBands = 4;

/// 右端（渐隐的一头）的墨量；左端满墨。
const double _kTailMinAlpha = 0.25;

/// 从这个横向比例开始向右渐隐（左侧 55% 满墨 = "刚印下的"）。
///
/// 这个位置同时是**网点区的左缘**（见 [_StillPage.patchFrac] 一路到内容盒右缘）：
/// 线"开始变淡"的地方，正是纸面"开始起网"的地方。
const double _kFadeStart = 0.55;

const double _kTwoPi = 2 * math.pi;

/// 「静默构图」空态插画：**一页还没有写上字的纸**（mono-color 印刷美学——
/// 留白、平面、1px 细线）。
///
/// ## 构图：两处墨咬在**同一个地方**，不是两块孤立的墨
/// 上一版把半调网点丢在一角、横线摆在另一处，设备实测读作"一张白纸上两个
/// 墨点，隔着一大片白，互不相关"。现在两处墨在同一段纸上：
/// - 一条 1px 横线（左端满墨 → 右端 [_kTailMinAlpha]，印刷的墨迹手感），
///   位置与两端内缩由 [seed] 一次性决定；
/// - 半调网点区**铺在这条线开始变淡的那一段**：支撑框的左缘对着线的渐隐
///   起点、右缘贴住内容盒右缘、纵向以这条线为中心；可见的那片网是框内一个
///   **各向异性的椭圆**（往左宽、往右窄、上下更窄），越靠近**线的收笔点**
///   网点越大越浓 —— 读作"这段墨横向化开了"，而不是"线旁边贴了一张坐标纸"，
///   两块墨之间也不再有任何空白。
///
/// ## 唯一会动的：整片网点的墨量
/// 那颗 [AppPalette.accent] 圆点**不动**——它是"纸上最新的一点墨"，坐在线的
/// 收笔点上（上一版坐在线的左端，实测第一眼像 radio button / 列表符号，故
/// 移到与"墨推进到哪儿"同一个方向）。
///
/// 全画面唯一在动的是**网点区的整体墨量**：`_kHalftoneAlpha × (1 ± 20%)`、
/// 周期 [kBreathCycle] = 4.4s，`sin(2πt)` 驱动（t 绕回 0 时逐点重合，循环
/// 无突变）。同一画面的运动元素只有 1 个、构图固定不动：
/// **"每帧构图都不同"在结构上不可能发生**。
///
/// ## 确定性（硬约束）
/// 所有几何参数由 [stableSeed] 播种的伪随机数**一次性生成**，不随帧变化：
/// 同一个 [seed] → 同一张图（重建 / 跨运行 / 跨平台一致）；每帧只是把固定的
/// 几何按 t 调一下那片网点的墨量。
///
/// [animate] = false，或 [MotionControl.of] 为 false（含系统"减少动画"）→
/// **不创建 AnimationController**，按 [kStaticWalkT] 画一帧（零 ticker）。
///
/// 用法：按页面 ID 传 [seed]，例如 `DotIllustration(seed: 'empty.history')`；
/// 每个页面的空态插画各自稳定成一张图，同一页刷新不变样。
class DotIllustration extends StatefulWidget {
  const DotIllustration({
    super.key,
    required this.seed,
    this.size = 160,
    this.ink,
    this.accent,
    this.animate = true,
  });

  /// 构图种子（按页面 ID 传，如 `'empty.history'`）。
  final String seed;

  /// 方框边长（px）；内容约占其中 68%，其余是留白。
  final double size;

  /// 线与网点的墨；默认 [AppPalette.inkText]（已过 4.5:1 对比度护栏）。
  final Color? ink;

  /// 点缀墨；默认 [AppPalette.accent]。只点一颗，坐在线的收笔点上（不动）。
  final Color? accent;

  /// 是否让那片网点的墨量呼吸。false → 静态一帧（t = [kStaticWalkT]），零 ticker。
  final bool animate;

  /// 当前存活的呼吸 ticker 数（**仅供测试断言不泄漏**）。
  @visibleForTesting
  static int activeTickers = 0;

  @override
  State<DotIllustration> createState() => _DotIllustrationState();
}

class _DotIllustrationState extends State<DotIllustration>
    with SingleTickerProviderStateMixin {
  /// 仅当真的要走动画路径时才非空（静态路径恒为 null → 零 ticker）。
  AnimationController? _ctl;

  /// 当前是否处于动画路径（= [_ctl] 非空）。
  bool _animating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MotionControl.of 走 MediaQuery（系统"减少动画"）→ 必须在
    // didChangeDependencies 里读，顺带把依赖登记上（系统设置变化会重新走到这里）。
    _applyMotion(widget.animate && MotionControl.of(context));
  }

  @override
  void didUpdateWidget(DotIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      _applyMotion(widget.animate && MotionControl.of(context));
    }
  }

  /// 把「是否跑动画」落到实际 ticker 上：只在状态翻转时增删，重复调用无副作用。
  void _applyMotion(bool want) {
    if (want == _animating) return;
    _animating = want;
    if (want) {
      _ctl = AnimationController(vsync: this, duration: kBreathCycle)..repeat();
      DotIllustration.activeTickers++;
      return;
    }
    final old = _ctl;
    _ctl = null;
    if (old != null) {
      old.dispose();
      DotIllustration.activeTickers--;
    }
  }

  @override
  void dispose() {
    // 卸载前走一次静态分支：统一 ticker 计数与释放，计数器必然归零。
    _applyMotion(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.size;
    // 非法尺寸：不绘制、不抛异常（父级拿到零尺寸占位）
    if (!(side > 0) || !side.isFinite) return const SizedBox.shrink();

    // 颜色一律走 palette（不硬编码）；显式传参时以传参为准。
    final ink = widget.ink ?? context.palette.inkText;
    final accent = widget.accent ?? context.palette.accent;
    final ctl = _animating ? _ctl : null;

    // 纯装饰：对无障碍树没有任何语义贡献，整体排除（读屏不读它）。
    return ExcludeSemantics(
      // RepaintBoundary：网点呼吸的每帧重绘只发生在本层，不波及父级（空态整树）。
      child: RepaintBoundary(
        child: SizedBox(
          width: side,
          height: side,
          child: CustomPaint(
            painter: DotIllustrationPainter(
              seed: stableSeed(widget.seed),
              ink: ink,
              accent: accent,
              progress: ctl,
            ),
          ),
        ),
      ),
    );
  }
}

/// 一页空白纸的静态构图参数（由 [stableSeed] 播种的伪随机数**一次性生成**）。
///
/// 抖动范围刻意小：空态要"静"，不是"随机花样"。它只负责让不同页面的空态
/// 互不相同（同 seed 恒定 ⇒ 不闪烁）。
@immutable
class _StillPage {
  const _StillPage({
    required this.yFrac,
    required this.insetL,
    required this.insetR,
    required this.patchFrac,
  });

  /// 横线在内容盒里的纵向位置（占盒高）：0.42–0.58，落在盒子的中段。
  final double yFrac;

  /// 横线左 / 右端的内缩（占内容盒宽）：端点收在框内，两端不齐才像手排的版。
  final double insetL;
  final double insetR;

  /// 网点区的边长（占内容盒宽）：右缘贴内容盒右缘、纵向以横线为中心，
  /// 所以这个值也决定网点区从横线的哪一段开始铺。
  final double patchFrac;

  /// 由 seed 一次性算出（前三个值与旧版顺序一致 ⇒ 同 seed 的横线几何不变）。
  factory _StillPage.build(int seed) {
    final rng = math.Random(seed ^ 0x5F3759DF);
    return _StillPage(
      yFrac: 0.42 + rng.nextDouble() * 0.16,
      insetL: 0.03 + rng.nextDouble() * 0.06,
      insetR: 0.05 + rng.nextDouble() * 0.09,
      patchFrac: 0.36 + rng.nextDouble() * 0.10,
    );
  }
}

/// 静默构图 + 网点呼吸的画笔。
///
/// 公开是为了让单测能直接把 [ink] / [accent] / [progress] 取出来断言
/// （不引入 golden 测试）；对调用方而言它属于实现细节，不要直接 new 它。
///
/// **每帧只 paint，不 rebuild**：动画驱动挂在 [progress]（即
/// `AnimationController`）这个 listenable 上，`paint` 时才读 `progress.value`。
/// 每帧的开销：4 次 `drawLine`（横线的墨量分段）+ 一片半调网点 + 1 个圆点，
/// **无 blur、无 Path、无渐变对象**。
class DotIllustrationPainter extends CustomPainter {
  DotIllustrationPainter({
    required this.seed,
    required this.ink,
    required this.accent,
    this.progress,
  })  : _page = _StillPage.build(seed),
        super(repaint: progress);

  /// 构图种子（[stableSeed] 之后的整数）。
  final int seed;

  /// 线与网点的墨（默认 [AppPalette.inkText]）。
  final Color ink;

  /// 点缀墨（默认 [AppPalette.accent]）；只点一颗，坐在线的收笔点上、不动。
  final Color accent;

  /// 动画进度源；**null = 静态路径**（画 [kStaticWalkT] 那一帧，零 ticker）。
  final Animation<double>? progress;

  /// 预生成的静态构图参数（构造时算一次，之后每帧只读）。
  final _StillPage _page;

  /// 当前用于绘制的相位（只用来算网点墨量的呼吸）。
  double get effectiveT => progress?.value ?? kStaticWalkT;

  /// 测试专用：方框边长 [side] 时那条横线**印满后**的两端与纵坐标（画布坐标）。
  /// 退化的尺寸返回 null。与真正绘制走同一份 [_lineAt]，不会"测的和画的不是一回事"。
  @visibleForTesting
  ({double x0, double x1, double y})? debugLineAt(double side) => _lineAt(side);

  /// 测试专用：那颗点缀圆点的中心、半径与墨量系数（[alpha] 相对 [accent]，
  /// 1.0 = 满档）。**位置与相位无关**（它不动）；退化尺寸返回 null。
  @visibleForTesting
  ({double cx, double cy, double r, double alpha})? debugDotAt(double side) =>
      _dotAt(side);

  /// 测试专用：网点区的外框（画布坐标）；退化尺寸返回 null。
  ///
  /// 用来断言"网点与线咬在一起"：左缘对着线的渐隐起点、右缘贴内容盒右缘、
  /// 纵向中心 = 线的 y。
  @visibleForTesting
  Rect? debugHalftoneBoxAt(double side) => _halftoneBoxAt(side);

  /// 测试专用：相位 [t] 时网点区的整体墨量（相对 [ink]，1.0 = 满档）。
  @visibleForTesting
  double debugHalftoneAlphaAt(double t) => _halftoneAlphaAt(t);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final side = size.shortestSide;
    if (!(side > 0)) return;
    // 留白：内容只占中间约 68% 的方框
    final box = _contentBox(side);
    if (box.width <= 4 || box.height <= 4) return;

    // 动：网点区的整体墨量（全画面唯一在动的东西）+ 静：那片网点的构图
    _paintHalftone(canvas, side, effectiveT);
    // 静：一条 1px 横线（左端满墨 → 右端渐隐），压在网点之上
    _paintStillLine(canvas, side);
    // 静：线的收笔点上那颗点缀墨
    _paintAccentDot(canvas, side);
  }

  /// 内容方框：四周留白 16% ⇒ 内容只占中间约 68%（边长 [side] 的正方形）。
  static Rect _contentBox(double side) => Rect.fromLTWH(
        side * 0.16,
        side * 0.16,
        side * 0.68,
        side * 0.68,
      );

  /// 横线印满后的两端与纵坐标（绘制与测试共用一份）；退化尺寸返回 null。
  ({double x0, double x1, double y})? _lineAt(double side) {
    if (!(side > 0) || !side.isFinite) return null;
    final box = _contentBox(side);
    if (box.width <= 4 || box.height <= 4) return null;
    final x0 = box.left + box.width * _page.insetL;
    final x1 = box.right - box.width * _page.insetR;
    if (x1 - x0 <= 4) return null;
    return (x0: x0, x1: x1, y: box.top + box.height * _page.yFrac);
  }

  /// 那颗点缀圆点（绘制与测试共用一份）：**坐在线的收笔点上、不随相位移动**。
  ({double cx, double cy, double r, double alpha})? _dotAt(double side) {
    final line = _lineAt(side);
    if (line == null) return null;
    return (cx: line.x1, cy: line.y, r: _kDotRadius, alpha: 1.0);
  }

  /// 网点区的外框（绘制与测试共用一份）；退化尺寸返回 null。
  ///
  /// 左缘 = 横线的渐隐起点（线开始变淡的地方），右缘 = 内容盒右缘，
  /// 纵向以横线为中心（并夹在内容盒内，防脏数据把它顶出去）。
  Rect? _halftoneBoxAt(double side) {
    if (!(side > 0) || !side.isFinite) return null;
    final line = _lineAt(side);
    if (line == null) return null;
    final box = _contentBox(side);
    final patch = box.width * _page.patchFrac;
    if (patch < _kHalftoneSpacing * 3) return null;
    final left = line.x0 + (line.x1 - line.x0) * _kFadeStart;
    if (left > box.right - _kHalftoneSpacing * 3) return null;
    final top = (line.y - patch / 2).clamp(box.top, box.bottom - patch);
    return Rect.fromLTWH(left, top, box.right - left, patch);
  }

  /// 网点区的整体墨量（相对 [ink]）：`_kHalftoneAlpha × (1 + A·sin(2πt))`。
  ///
  /// `sin(2πt)` ⇒ t 与 t+1 逐点重合（循环无突变）；幅度 [_kBreathAmplitude]
  /// 保证墨量恒为正（不会"呼吸到没有"）。
  double _halftoneAlphaAt(double t) =>
      _kHalftoneAlpha * (1 + _kBreathAmplitude * math.sin(_kTwoPi * t));

  /// 画那条 1px 横线：横向切成 [_kFadeBands] 段、各自一档墨量
  /// （左端满墨 → 右端 [_kTailMinAlpha]）。段间共用端点 + 1px 圆头，看不出接缝。
  void _paintStillLine(Canvas canvas, double side) {
    final line = _lineAt(side);
    if (line == null) return;
    final span = line.x1 - line.x0;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    for (var b = 0; b < _kFadeBands; b++) {
      final a = line.x0 + span * b / _kFadeBands;
      final c = line.x0 + span * (b + 1) / _kFadeBands;
      paint.color = ink.withValues(alpha: ink.a * _alphaAt((b + 0.5) / _kFadeBands));
      canvas.drawLine(Offset(a, line.y), Offset(c, line.y), paint);
    }
  }

  /// 画那颗不会动的点缀墨：位置永远在线的收笔点（"墨推进到头的那一点"）。
  void _paintAccentDot(Canvas canvas, double side) {
    final dot = _dotAt(side);
    if (dot == null) return;
    canvas.drawCircle(
      Offset(dot.cx, dot.cy),
      dot.r,
      Paint()
        ..isAntiAlias = true
        ..color = accent.withValues(alpha: accent.a * dot.alpha),
    );
  }

  /// 画那片半调网点：**越靠近线的收笔点越浓**（网点半径与墨量一起往外衰减），
  /// 于是"最浓的一点"就是线的尽头 —— 两块墨在同一个地方咬住。
  ///
  /// 衰减是**各向异性的椭圆**（不是矩形网格）：往左（沿线的渐隐段）铺得宽、
  /// 往右（纸边）收得快、上下更窄 —— 看起来是"这段墨横向化开了"，
  /// 而不是"线旁边贴了一张坐标纸"。
  ///
  /// [t] 只影响整体墨量（呼吸），不影响任何位置。
  void _paintHalftone(Canvas canvas, double side, double t) {
    final patch = _halftoneBoxAt(side);
    final line = _lineAt(side);
    if (patch == null || line == null) return;
    final base = _halftoneAlphaAt(t);
    final anchorX = line.x1;
    final anchorY = line.y;
    // 化开的半径：左宽、右窄、上下最窄（贴住线，不铺满支撑框）
    final scaleL = patch.width * 0.85;
    final scaleR = patch.width * 0.25;
    final scaleY = patch.height * 0.42;
    final paint = Paint()..isAntiAlias = true;
    final cols = (patch.width / _kHalftoneSpacing).ceil();
    final rows = (patch.height / _kHalftoneSpacing).ceil();
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final cx = patch.left + _kHalftoneSpacing / 2 + col * _kHalftoneSpacing;
        final cy = patch.top + _kHalftoneSpacing / 2 + row * _kHalftoneSpacing;
        if (cx > patch.right || cy > patch.bottom) continue;
        final dx = cx - anchorX;
        final kx = dx <= 0 ? -dx / scaleL : dx / scaleR;
        final ky = (cy - anchorY).abs() / scaleY;
        final k = math.sqrt(kx * kx + ky * ky).clamp(0.0, 1.0);
        final r = _kHalftoneDotR * (1 - k * 0.85);
        if (r <= 0.2) continue;
        paint.color = ink.withValues(alpha: ink.a * base * (1 - k * 0.75));
        canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
  }

  /// 沿线墨量：左端满墨（"刚印下的"）→ 右端渐隐。克制的一条渐变，不做发光。
  double _alphaAt(double x) {
    if (x <= _kFadeStart) return 1.0;
    final u = ((x - _kFadeStart) / (1 - _kFadeStart)).clamp(0.0, 1.0);
    return 1.0 - (1 - _kTailMinAlpha) * u;
  }

  /// 只有"颜色 / 种子变了"或"静态/动画路径切换了"才需要重绘——动画期间的重绘由
  /// [progress] 这个 listenable 驱动（每帧 `markNeedsPaint`，不 rebuild）。
  @override
  bool shouldRepaint(DotIllustrationPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.ink != ink ||
      oldDelegate.accent != accent ||
      (oldDelegate.progress == null) != (progress == null);
}
