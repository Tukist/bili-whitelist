import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/motion_control.dart';
import 'dot_halftone.dart';

/// 静态帧（[DotIllustration.animate] = false，或 [MotionControl.of] 为 false）
/// 取的游走进度。挑 0.35 只为「不落在周期的起手相」——t=0 时各谐波同时起跳，
/// 那一帧的四条线最"齐整"；0.35 看起来更像随手走出来的一段。
const double kStaticWalkT = 0.35;

/// 线上一整轮游走回到原样的时长。刻意慢：要的是「游走」不是「抖动」。
const Duration kWalkCycle = Duration(seconds: 14);

/// 每条线沿横向的剖面采样点数（= `_kFadeBands × 8 + 1`）。
/// 最高谐波 7 圈 → 每圈仍有 ~14 个采样点，单帧 3 条线合计 ~300 点；
/// 比「每帧算几千个点」低一个数量级。
const int _kProfile = 97;

/// 沿线渐隐的段数（相邻段共用端点 + 1px 圆头，接缝看不出来）。
const int _kFadeBands = 12;

/// 右端（正在淡去的一头）的墨量；左端满墨。
const double _kTailMinAlpha = 0.25;

/// 从这个横向比例开始向右渐隐（左侧 55% 满墨 = "刚写下的"）。
const double _kFadeStart = 0.55;

/// 剖面幅值占「带」高一半的比例。`< 1` 且剖面的幅值上界确定为 ±1
/// （见 [_kAmps]）→ **永不越出自己那条带**，邻居之间不会打架。
const double _kAmplitude = 0.94;

/// 粗层 / 细层的权重：粗层是大尺度蜿蜒，细层是布朗的自相似细节。
const double _kCoarseWeight = 0.65;
const double _kFineWeight = 0.35;

/// 粗层谐波次数（圈 / 线宽）：1–3 圈 = 大尺度蜿蜒。
const List<int> _kCoarseKs = <int>[1, 2, 3];

/// 细层谐波次数：4–7 圈 = 小尺度起伏。
/// **上限 7 是刻意的**：最高空间频率被钉住（一圈至少 ~14 个采样点；实测相邻
/// 采样点转角 p99 ≈ 23°、最大 45°）→ 线条读起来是连续弯的，不会出现布朗运动
/// 那种"像素级锯齿"。
const List<int> _kFineKs = <int>[4, 5, 6, 7];

const double _kTwoPi = 2 * math.pi;

/// 各谐波振幅：`∝ 1/k` —— 振幅谱 1/k 即功率谱 1/f²，正是布朗运动的频谱
/// （带限布朗 = 随机相位的正弦叠加）；再按粗 / 细层加权，最后归一化到 **Σ == 1**。
///
/// `Σ == 1` 带来一个硬保证：`|Σ aₖ·cos(·)| ≤ Σ aₖ == 1`，于是剖面的幅值上界
/// 确定为 ±1，乘上 [_kAmplitude] × 半带高之后**永远落在自己那条带里**，
/// 不需要任何裁剪（裁剪会在带边留下假的平直段）。
final List<double> _kAmps = _buildAmps();

/// 与 [_kAmps] 一一对应的谐波次数。
final List<int> _kKs = <int>[..._kCoarseKs, ..._kFineKs];

/// 与 [_kAmps] 一一对应的时间圈数：粗层 1×k、细层 2×k。
///
/// **必须是整数**——t 从 1 绕回 0 时相位要正好是 2π 的整数倍，否则会"唰"地跳一下。
/// 细层走两倍：粗细两层速度不同 ⇒ 线条一边整体漂移一边缓慢变形（不是一张图在平移）。
final List<int> _kLaps = <int>[
  for (final k in _kKs) _kCoarseKs.contains(k) ? k : 2 * k,
];

List<double> _buildAmps() {
  final raw = <double>[];
  var sum = 0.0;
  for (final k in _kKs) {
    final a = (_kCoarseKs.contains(k) ? _kCoarseWeight : _kFineWeight) / k;
    raw.add(a);
    sum += a;
  }
  return [for (final a in raw) a / sum];
}

/// 「随机游走细线插画」：空状态的门面（mono-color 印刷美学——留白、平面、细线）。
///
/// 线条在**缓慢游走**：每条线横贯自己那条"带"，垂直剖面是一条**带限布朗曲线**
/// ——随机相位的正弦叠加、振幅谱 1/k（= 功率谱 1/f²，布朗运动的频谱）。
/// 它随时间整体漂移 + 缓慢变形，看起来像一条细线在纸上慢慢走。线数压到 2–3 条
/// （原静态版是 5–9 条折线，动态版这么多会乱）+ 1 个点缀色小点 + 一角半调网点；
/// 四周留白充足：内容只占中间约 68% 的方框，**不填满** [size]。
///
/// **为什么用"噪声函数"而不是"预生成路径 + 沿路径推进"**：后者在像素级采样下
/// 会露出折角（要么锯齿、要么得再做一层曲线平滑），而且要求闭合环首尾严格相接；
/// 带限布朗是 `f(x, t)` 的解析函数，天然连续、可无限跑，还能**显式限制最高空间
/// 频率**（[`_kFineKs`] 上限 7 圈）——"曲率连续、不出锯齿"因此是构造上的保证，
/// 不是调参调出来的。算法的"随机游走"性质体现在频谱（1/f²）与随机相位上。
///
/// **确定性（硬约束）**：同一个 [seed] → 同一条剖面。谐波的初相由 [stableSeed]
/// 播种的伪随机数**一次性生成**（不是每帧 `Random()`——那会把线条闪成噪点）。
/// 每帧只是沿固定剖面推进时间参数 t，跨重建 / 跨运行一致。
///
/// **循环无突变（硬约束）**：空间相位是整圈（`k·x`，k 为整数 ⇒ x 从 0 到 1
/// 天然接回），时间相位也是整圈（`laps·t`，laps 为整数）⇒ t 从 1 绕回 0 时
/// 曲线逐点回到起点，没有任何跳变。剖面还额外乘上了沿线的"墨量衰减"
/// （左端满墨 → 右端渐隐），读起来像一支笔在慢慢写、写下的墨迹在后面淡去。
///
/// [animate] = false，或 [MotionControl.of] 为 false（含系统"减少动画"）→
/// **不创建 AnimationController**，按 [kStaticWalkT] 画一帧（零 ticker）。
///
/// 用法：按页面 ID 传 [seed]，例如 `DotIllustration(seed: 'empty.history')`；
/// 每个页面的空态插画各自稳定成一条路径，同一页刷新不变样。
class DotIllustration extends StatefulWidget {
  const DotIllustration({
    super.key,
    required this.seed,
    this.size = 160,
    this.ink,
    this.accent,
    this.animate = true,
  });

  /// 路径种子（按页面 ID 传，如 `'empty.history'`）。
  final String seed;

  /// 方框边长（px）；内容约占其中 68%，其余是留白。
  final double size;

  /// 线条色；默认 [AppPalette.inkText]（已过 4.5:1 对比度护栏）。
  final Color? ink;

  /// 点缀色；默认 [AppPalette.accent]。只点一颗，骑在第一条线上随它游走。
  final Color? accent;

  /// 是否让细线游走。false → 静态一帧（t = [kStaticWalkT]），零 ticker。
  final bool animate;

  /// 当前存活的游走 ticker 数（**仅供测试断言不泄漏**）。
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
      _ctl = AnimationController(vsync: this, duration: kWalkCycle)..repeat();
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
      // RepaintBoundary：线条每帧重绘只发生在本层，不波及父级（列表/空态整树）。
      child: RepaintBoundary(
        child: SizedBox(
          width: side,
          height: side,
          child: CustomPaint(
            painter: DotIllustrationPainter(
              seed: stableSeed(widget.seed),
              ink: ink,
              accent: accent,
              lineCount: _lineCountFor(side),
              progress: ctl,
            ),
          ),
        ),
      ),
    );
  }
}

/// 线数：原静态版是 5–9 条折线，动态版这么多会乱 → 默认 3 条；
/// 小尺寸（卡片内的 72px 空态）降到 2 条——带高不足时 3 条会挤成一团，
/// 宁可少一条也不糊。
int _lineCountFor(double side) => side >= 110 ? 3 : 2;

/// 一条游走线的静态参数。
///
/// 由 [stableSeed] 播种的伪随机数**一次性生成**，不随帧变化：每帧重新取随机数
/// 会让线条闪成噪点，那就不是"游走"而是"抖动"了。
@immutable
class _Wander {
  const _Wander({
    required this.phases,
    required this.speed,
    required this.center,
    required this.halfBand,
    required this.insetL,
    required this.insetR,
    required this.dotAt,
  });

  /// 各谐波的初相（弧度）；与 [_kKs] 一一对应。
  final List<double> phases;

  /// 这条线整体走多快（圈 / 周期），1 或 2：
  /// 几条线快慢不同更自然，且都是整数 ⇒ 回绕时相位仍落在 2π 的整数倍上。
  final int speed;

  /// 剖面中心在内容方框里的纵向位置（占方框高的比例）。
  final double center;

  /// 带高的一半（占方框高的比例）：决定这条线能游走多大振幅。
  final double halfBand;

  /// 线条左右两端的缩进（占内容宽度的比例）——沿用原静态版"端点收在框内"的手感。
  final double insetL;
  final double insetR;

  /// 点缀色小点骑在线上哪个横向位置（0–1）。
  final double dotAt;

  /// 横坐标 [x]（0–1）、进度 [t] 处的剖面值，**值域确定在 [−1, 1]**。
  ///
  /// 相位 = 空间 `k·x` 圈 + 时间 `laps·t` 圈：两者都是整数圈，
  /// 于是 x 从 0 到 1 天然接回、t 从 1 绕回 0 也逐点重合（循环无突变）。
  double valueAt(double x, double t) {
    var v = 0.0;
    for (var j = 0; j < _kKs.length; j++) {
      v += _kAmps[j] *
          math.cos(_kTwoPi * (_kKs[j] * x + _kLaps[j] * speed * t) + phases[j]);
    }
    return v;
  }
}

/// 生成 [count] 条游走线（同 seed 恒定：重建 / 跨运行都一样）。
///
/// 带的切分**不等分**（用 seed 抖一下）→ 几条线不会排成"三线谱"。
List<_Wander> _buildWanders(int seed, int count) {
  // 半调网点与游走线各用一条独立的随机流：网点那一支保持原实现的手感不变。
  final rng = math.Random(seed ^ 0x5F3759DF);
  final cuts = <double>[
    for (var i = 1; i < count; i++)
      i / count + (rng.nextDouble() - 0.5) * 0.12,
  ];
  final walks = <_Wander>[];
  for (var i = 0; i < count; i++) {
    final lo = i == 0 ? 0.0 : cuts[i - 1];
    final hi = i == count - 1 ? 1.0 : cuts[i];
    walks.add(
      _Wander(
        phases: [for (var j = 0; j < _kKs.length; j++) rng.nextDouble() * _kTwoPi],
        speed: 1 + rng.nextInt(2), // 1 或 2 圈 / 周期
        center: (lo + hi) / 2,
        halfBand: (hi - lo) / 2,
        insetL: 0.02 + rng.nextDouble() * 0.10,
        insetR: 0.02 + rng.nextDouble() * 0.10,
        dotAt: 0.52 + rng.nextDouble() * 0.22,
      ),
    );
  }
  return walks;
}

/// 游走线 + 半调网点的画笔。
///
/// 公开是为了让单测能直接把 [ink] / [accent] / [progress] 取出来断言
/// （不引入 golden 测试）；对调用方而言它属于实现细节，不要直接 new 它。
///
/// **每帧只 paint，不 rebuild**：动画驱动挂在 [progress]（即
/// `AnimationController`）这个 listenable 上，`paint` 时才读 `progress.value`。
class DotIllustrationPainter extends CustomPainter {
  DotIllustrationPainter({
    required this.seed,
    required this.ink,
    required this.accent,
    required this.lineCount,
    this.progress,
  })  : _wanders = _buildWanders(seed, lineCount),
        // 网点的"哪一角"沿用原实现的取法（同一个 Random(seed) 的第一个 nextInt）
        _halftoneCorner = math.Random(seed).nextInt(4),
        super(repaint: progress);

  /// 路径种子（[stableSeed] 之后的整数）。
  final int seed;

  /// 线条墨（默认 [AppPalette.inkText]）。
  final Color ink;

  /// 点缀墨（[AppPalette.accent]）；只点一颗，骑在第一条线上。
  final Color accent;

  /// 游走线条数（见 [_lineCountFor]）。
  final int lineCount;

  /// 动画进度源；**null = 静态路径**（画 [kStaticWalkT] 那一帧，零 ticker）。
  final Animation<double>? progress;

  /// 预生成的游走线参数（构造时算一次，之后每帧只读）。
  final List<_Wander> _wanders;

  /// 半调网点占哪一角（0–3）。
  final int _halftoneCorner;

  /// 当前用于绘制的进度。
  double get effectiveT => progress?.value ?? kStaticWalkT;

  /// 测试专用：第 [lineIndex] 条线在进度 [t]、方框边长 [side] 时的采样折线。
  ///
  /// 单测用它做**精确**断言（同 seed 同路径、t 与 t+1 逐点重合 = 循环无突变、
  /// 相邻采样点转角很小 = 曲率连续 / 无锯齿），比逐像素比对更直接、更好定位。
  /// 与真正绘制的折线出自同一个 [_polylineOf]，不会"测的和画的不是一回事"。
  @visibleForTesting
  List<Offset> debugPolylineAt(int lineIndex, double t, double side) {
    if (lineIndex < 0 || lineIndex >= _wanders.length) return const <Offset>[];
    final box = _contentBox(Size(side, side));
    if (box.width <= 4 || box.height <= 4) return const <Offset>[];
    return _polylineOf(_wanders[lineIndex], box, t);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 留白：内容只占中间约 68% 的方框（与原静态版一致）
    final box = _contentBox(size);
    if (box.width <= 4 || box.height <= 4) return;

    // 先铺一角的半调网点（静态，垫在细线之下，不抢线条的清晰度）
    _paintCornerHalftone(canvas, size);

    final t = effectiveT;
    for (var i = 0; i < _wanders.length; i++) {
      _paintWander(
        canvas,
        wander: _wanders[i],
        box: box,
        t: t,
        accentRide: i == 0,
      );
    }
  }

  /// 内容方框：四周留白 16% ⇒ 内容只占中间约 68%（与原静态版一致）。
  static Rect _contentBox(Size size) {
    final padX = size.width * 0.16;
    final padY = size.height * 0.16;
    return Rect.fromLTWH(
      padX,
      padY,
      size.width - padX * 2,
      size.height - padY * 2,
    );
  }

  /// 一条游走线在进度 [t] 时的采样折线（已映射到实际坐标）；退化尺寸返回空表。
  List<Offset> _polylineOf(_Wander wander, Rect box, double t) {
    final pts = <Offset>[];
    for (var j = 0; j < _kProfile; j++) {
      final p = _pointOn(wander, box, t, j / (_kProfile - 1));
      if (p == null) return const <Offset>[];
      pts.add(p);
    }
    return pts;
  }

  /// 一条线上横向比例 [xFrac]（0–1）处的实际坐标；退化尺寸返回 null。
  ///
  /// 折线采样与"骑在线上"的点缀色小点共用它 —— 小点必然落在线上。
  Offset? _pointOn(_Wander wander, Rect box, double t, double xFrac) {
    final x0 = box.left + box.width * wander.insetL;
    final x1 = box.right - box.width * wander.insetR;
    final span = x1 - x0;
    if (span <= 4) return null;
    final cy = box.top + box.height * wander.center;
    final amp = box.height * wander.halfBand * _kAmplitude;
    if (!(amp > 0)) return null;
    return Offset(x0 + span * xFrac, cy + amp * wander.valueAt(xFrac, t));
  }

  /// 画一条游走线：沿线取 [_kProfile] 个采样点，按"墨量从左到右衰减"分段上墨，
  /// 左端点一颗小圆点收尾。
  ///
  /// 位置完全由 [t] 决定——t 连续 ⇒ 线条连续平滑地游走；单帧每条线只算
  /// [_kProfile] 个点。
  void _paintWander(
    Canvas canvas, {
    required _Wander wander,
    required Rect box,
    required double t,
    required bool accentRide,
  }) {
    final pts = _polylineOf(wander, box, t);
    if (pts.length < 2) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // 沿线渐隐：切成若干段各自一档墨量（段间共用端点，1px 圆头看不出接缝）
    const per = (_kProfile - 1) ~/ _kFadeBands;
    for (var b = 0; b < _kFadeBands; b++) {
      paint.color = ink.withValues(alpha: ink.a * _alphaAt((b + 0.5) / _kFadeBands));
      final path = Path()..moveTo(pts[b * per].dx, pts[b * per].dy);
      for (var k = 1; k <= per; k++) {
        final p = pts[b * per + k];
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }

    // 左端点一颗小圆点（细线插画的收尾手感，不做箭头）：墨最实处就是"笔尖"
    canvas.drawCircle(
      pts.first,
      1.3,
      Paint()
        ..isAntiAlias = true
        ..color = ink,
    );

    // 1 颗点缀色小点：骑在第一条线上，随着波形游走上下起伏。
    // 与本库"点缀墨 = 时间 / 新鲜度"的分工吻合——它是线上唯一"新鲜"的一点。
    if (accentRide) {
      final p = _pointOn(wander, box, t, wander.dotAt);
      if (p != null) {
        canvas.drawCircle(
          p,
          2.2,
          Paint()
            ..isAntiAlias = true
            ..color = accent,
        );
      }
    }
  }

  /// 沿线墨量：左端满墨（"刚写下的"）→ 右端渐隐（"正在淡去的"）。
  /// 克制的一条渐变，不做发光。
  double _alphaAt(double x) {
    if (x <= _kFadeStart) return 1.0;
    final u = ((x - _kFadeStart) / (1 - _kFadeStart)).clamp(0.0, 1.0);
    return 1.0 - (1 - _kTailMinAlpha) * u;
  }

  /// 四角之一画一小片半调网点：间距 4.5、半径 ~0.9、
  /// 墨色降到 28% 不透明度，保证不与细线抢注意力。
  void _paintCornerHalftone(Canvas canvas, Size size) {
    const spacing = 4.5;
    const dotR = 0.9;
    final patch = size.shortestSide * 0.30;
    if (patch < spacing * 3) return;
    final isLeft = _halftoneCorner == 0 || _halftoneCorner == 2;
    final isTop = _halftoneCorner < 2;
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
        final k = ((dx + dy) / (patch * 1.4)).clamp(0.0, 1.0);
        final r = dotR * (1 - k * 0.7);
        if (r <= 0.15 || cx > size.width || cy > size.height) continue;
        canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
  }

  /// 只有"颜色 / 种子 / 线数变了"或"静态/动画路径切换了"才需要重绘——动画期间
  /// 的重绘由 [progress] 这个 listenable 驱动（每帧 `markNeedsPaint`，不 rebuild）。
  @override
  bool shouldRepaint(DotIllustrationPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.ink != ink ||
      oldDelegate.accent != accent ||
      oldDelegate.lineCount != lineCount ||
      (oldDelegate.progress == null) != (progress == null);
}
