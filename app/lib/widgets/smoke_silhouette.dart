/// 「印刷走纸」（Press Sweep）——加载态的等待画面。
///
/// ⚠️ **类名是历史遗留**：本组件原先画的是「通用风衣男抽烟剪影」+ 3 条烟缕。
/// 2.21.0 起改成**印刷走纸**——只有 5 条被墨填出来的文字线，
/// 一个人物、一缕烟、一次 blur 都没有了。`SmokeSilhouette` 这个名字被
/// 十几个页面与多处测试引用，故保留；文档里的"烟缕"字样一律换成"文字线"。
///
/// ## 概念
/// 一页正在被排版印刷的纸：**5 条 1px 文字线从左到右被墨填出来，一条接一条**；
/// 第 5 条印满、停一息，整片墨淡到只剩一层薄墨、再回到空白，然后重来。
/// 它同时是"进度"的隐喻——线在生长 = 事情在推进，而不是"装饰性闪烁"。
///
/// ## 为什么这样就不会难看（结构上的保证，不是调参调出来的）
/// - **构图固定**：每条线的 y 与宽度是常量表（只过一趟确定性哈希做 ±6% 抖动），
///   任何一帧都不重新构图、没有 layout shift："难看"的根源（每帧换构图）
///   在结构上不存在；
/// - **只有墨量在推进**：每帧变化的量只有"每条线画到哪"（长度）+ 整片墨量，
///   没有位移、没有漂移、没有变形；
/// - **同一时刻至多 1 个额外动体**：一枚 1.2 × 6px 的 accent **短竖条**
///   （读作刻刀的刃 / 笔尖——**是矩形不是圆点**：圆点留给空态插画那颗）
///   领在"正在画的那条线"的笔尖上；除此之外全画面静止；
/// - **节奏可读**（一轮 [kPressCycle] = 2.8s）：5 条线错峰起笔（相邻
///   [_kLineDelayStep] = 0.15 ≈ 420ms），单条 [_kLineDrawSpan] = 0.18 ≈ 504ms
///   → **任意时刻至多 2 条同时在长**，且每条线只有生命周期的前 84ms 与上一条
///   重叠（约 80% 的时间只有 1 条在长）= 读得出"一条印完再印下一条"，而不是
///   "条形图在填充"；第 5 条在 t = 0.78 收笔、满墨保持到 t = 0.80；整片墨量跑
///   t ∈ [0.80, 0.92] 从满墨淡到 [kPressHoldAlpha]，t ∈ [0.92, 1.0] 回到空白
///   —— 起承转合读得出来。
///
/// ## 绘制开销
/// 每帧 ≤ 5 条线 ×（1 段满墨 + 3 段前沿渐隐）= 20 次 `drawLine` + 1 枚笔尖条：
/// **无 blur、无 Path、无渐变对象**。"墨还湿"的柔边是用 3 段不同墨量的直线
/// 拼出来的（半调思路）——不用 `MaskFilter.blur`：blur 与本库
/// 「无阴影 / 1px 描边 / 平面印刷 / 暖白底材」的语言直接冲突，而且每帧 3 次
/// blur 是全 App 最贵的一笔开销。
///
/// ## 双色分工（沿用全库「两个墨各有职责」的约定）
/// - 文字线 = [AppPalette.inkDeco]（**图形/非文字档**，与纸底 ≥ 3:1）；
/// - 领墨的笔尖条 = [AppPalette.accent]（点缀墨职责 = **时间与新鲜度**）：
///   "现在画到哪儿"天然是时间信息，是点缀墨在本库最正当的一次用法。
///
/// ## 底材限制
/// 只能用在 [kPaper] 一类浅底材上。播放页黑底反转底材（[kPlayerPaper] 那一套）
/// 上 inkDeco 与底色对比不足甚至消失，**禁止放在播放页黑盒内部**。
///
/// ## 性能
/// 外层 [RepaintBoundary] + `CustomPainter` 挂在 `AnimationController` 的
/// listenable 上（与 `danmaku_overlay.dart` 同款模式）——每帧只 `paint` 本层，
/// 不 rebuild widget 树、不重排。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_palette.dart';
import '../theme/motion_control.dart';
import 'dot_halftone.dart' show stableSeed;

/// 静态帧（[SmokeSilhouette.animate] = false 或无 ticker 时）取的进度。
///
/// 0.35 = 第 1、2 条线已印满、第 3 条画到约 28%、后两条还没起笔：画面里明确
/// "有事正在发生"，不是一张空白纸（空场会被读成"加载卡住了"）。
const double kStaticSmokeT = 0.35;

/// 收尾段的墨量地板：整片淡下去时**不淡到 0**。
/// 淡到 0 会闪一下白（纸底突然全亮），0.12 读作"墨已经收走，纸还在"。
const double kPressHoldAlpha = 0.12;

/// 满档线数（整页加载态 160px）。
const int _kMaxLines = 5;

/// 单条线的绘制时长（周期占比）：0.18 × 2800ms ≈ 504ms。
///
/// 为什么是这个数：一条线要"看得见墨在推进"，但 5 条又必须在一个周期里印完。
/// 设错峰 [_kLineDelayStep]、单条 [_kLineDrawSpan]，则第 5 条收笔于
/// `4 × step + span`；要让它的收笔 + 整片淡出都落在周期内，须
/// `4 × step + span ≤ 0.80`。旧值 `0.34` 单条太长（952ms），逼得 step 只能
/// 到 0.13 → `span / step = 2.6` → 任意时刻 3 条同时在长，看起来像
/// "条形图/均衡器在填充"。把单条压到 0.18、错峰抬到 0.15，比值 1.2，
/// 任意时刻至多 2 条同时在长（且只在交接的 84ms 里重叠）。
const double _kLineDrawSpan = 0.18;

/// 相邻线的错峰步进（周期占比）：0.15 × 2800ms ≈ 420ms 一条接一条。
///
/// 上限被 [_kLineDrawSpan] 锁死：`step ≤ (0.80 - span) / 4`。想要更大的错峰
/// （例如 0.22 ≈ 616ms）必须同时把单条压到 0.08 ≈ 224ms 以下——那样单条太快，
/// 看不出"墨在填"。0.15 / 0.18 是这一对里"逐条读得出来"且"单条还看得清"的解。
const double _kLineDelayStep = 0.15;

/// 整片开始淡出的进度（`t ∈ [0.80, 0.92]` 从满墨淡到 [kPressHoldAlpha]）。
///
/// 0.80 落在第 5 条收笔（0.78）之后：先让"5 条全印满"这一帧真的被看到，
/// 再整片收走（旧值 0.62 会在第 5 条还在长的时候就开淡，等于第 5 条永远
/// 没被看到印满过）。
const double _kHoldStart = 0.80;

/// 淡到墨量地板的进度；`t ∈ [0.92, 1.0]` 再从地板回到全空白 → "这一轮印完了"。
const double _kHoldEnd = 0.92;

/// 前沿渐隐带长度（px）：读作"笔尖刚划过、墨还湿"。
const double _kFrontFade = 18.0;
const double _kFrontFadeSmall = 10.0;

/// 前沿渐隐的 3 段墨量：满墨 → 0.15（切成 3 段 `drawLine`，不用 blur）。
const List<double> _kFrontAlphas = <double>[1.0, 0.575, 0.15];

/// 领墨的"笔尖"尺寸（px）：**短竖条**（宽 × 高）。
///
/// 为什么不是 2.2px 的方块：2.2dp 在 420dpi 上只有约 5.8 设备像素，实测读作
/// "一颗小小的橙点"，"笔尖领着墨走"的意图传达不到（要人指出来才注意得到）。
/// 改成 1.2 × 6 的短竖条后：宽只比 1px 线粗一点（不糊住线的横断面），
/// 高 6px ≈ 15.7 设备像素，读作**刻刀的刃 / 笔尖**——立在正在画的那条线的
/// 笔尖上，像打字机的字锤。仍是矩形（**方 / 刃的语言**），不是圆点。
const double _kPressNibW = 1.2;
const double _kPressNibH = 6.0;

/// 小尺寸档（页面里的 56px 内联加载）按比例缩小，别让刃比线还显眼。
const double _kPressNibWSmall = 1.0;
const double _kPressNibHSmall = 4.0;

/// 尺寸降级阈值：`< 80` 走小尺寸档（页面里的 56px 内联加载），`< 48` 再降一档。
const double _kSmallSide = 80.0;
const double _kTinySide = 48.0;

/// 各条线的宽度（占内容盒宽）：刻意**不等分** —— 左对齐的一段参差文字。
const List<double> _kLineWidths = <double>[0.34, 0.62, 0.86, 0.72, 0.46];

/// 首条线的 y / 末条线的 y（占内容盒高的比例）；中间等距。
const double _kLineTopFrac = 0.10;
const double _kLineSpanFrac = 0.72;

/// 各条线宽度的确定性抖动（1 ± 6%）：**进程内只算一次**，恒定不变
/// → 重建 / 重绘不闪。抖动走 [stableSeed] 的确定性哈希，跨 SDK 版本一致。
final List<double> _kLineJitters = _buildLineJitters();

List<double> _buildLineJitters() {
  // 确定性伪随机（xorshift32）：只用来生成一次性常量表。
  var h = stableSeed('press.sweep');
  double next() {
    h ^= (h << 13) & 0xFFFFFFFF;
    h ^= h >> 17;
    h ^= (h << 5) & 0xFFFFFFFF;
    h &= 0xFFFFFFFF;
    return h / 0x100000000;
  }

  return [
    // 1 ± 6%：一段文字该有的参差，又不至于排成"波浪"
    for (var i = 0; i < _kMaxLines; i++) 1 + (next() * 2 - 1) * 0.06,
  ];
}

/// 加载态等待画面：一页正在被印刷的纸（见文件头）。
///
/// 几何在自定义空间里构图，按 [size] 等比缩放（改 [size] 只改大小、不改比例）。
///
/// [animate] = false 或 [MotionControl.of] 为 false → **不创建
/// AnimationController**，按 [kStaticSmokeT] 画一帧（零 ticker、零每帧开销）；
/// 无障碍设置里开了「减少动画」也走这条静态路径。
class SmokeSilhouette extends StatefulWidget {
  const SmokeSilhouette({
    super.key,
    this.size = 140,
    this.animate = true,
    this.ink,
    this.smoke,
  });

  /// 方框边长（px）。`<= 0` 时不绘制（返回零尺寸占位，不抛异常）。
  final double size;

  /// 是否让墨推进起来。false → 静态一帧（t = [kStaticSmokeT]），零 ticker。
  final bool animate;

  /// 文字线墨；默认 [AppPalette.inkDeco]（图形档，与纸底 ≥ 3:1）。
  final Color? ink;

  /// 领墨笔尖（短竖条）的墨；默认 [AppPalette.accent]（点缀墨 = 时间与新鲜度）。
  final Color? smoke;

  /// 当前存活的 ticker 数（**仅供测试断言不泄漏**）。
  @visibleForTesting
  static int activeTickers = 0;

  @override
  State<SmokeSilhouette> createState() => _SmokeSilhouetteState();
}

class _SmokeSilhouetteState extends State<SmokeSilhouette>
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
  void didUpdateWidget(SmokeSilhouette oldWidget) {
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
      _ctl = AnimationController(vsync: this, duration: kPressCycle)..repeat();
      SmokeSilhouette.activeTickers++;
      return;
    }
    final old = _ctl;
    _ctl = null;
    if (old != null) {
      old.dispose();
      SmokeSilhouette.activeTickers--;
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
    final ink = widget.ink ?? context.palette.inkDeco;
    final smoke = widget.smoke ?? context.palette.accent;
    final ctl = _animating ? _ctl : null;

    // 纯装饰：对无障碍树没有任何语义贡献，整体排除（读屏不读它）。
    return ExcludeSemantics(
      // RepaintBoundary：墨推进的每帧重绘只发生在本层，不波及父级（列表/空态整树）。
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(side),
          painter: SmokeSilhouettePainter(
            ink: ink,
            smoke: smoke,
            progress: ctl,
          ),
        ),
      ),
    );
  }
}

/// 印刷走纸的画笔。
///
/// 公开是为了让单测能直接把 [ink] / [smoke] / [progress] 取出来断言
/// （不引入 golden 测试）；对调用方而言它属于实现细节，不要直接 new 它。
///
/// **每帧只 paint，不 rebuild**：动画驱动挂在 [progress]（即
/// `AnimationController`）这个 listenable 上，`paint` 时才读 `progress.value`。
class SmokeSilhouettePainter extends CustomPainter {
  SmokeSilhouettePainter({
    required this.ink,
    required this.smoke,
    this.progress,
  }) : super(repaint: progress);

  /// 文字线墨（图形档 [AppPalette.inkDeco]）。
  final Color ink;

  /// 领墨笔尖（短竖条）的墨（点缀墨 [AppPalette.accent]）。
  final Color smoke;

  /// 动画进度源；**null = 静态路径**（画 [kStaticSmokeT] 那一帧，零 ticker）。
  final Animation<double>? progress;

  /// 当前用于绘制的进度。
  double get effectiveT => progress?.value ?? kStaticSmokeT;

  /// 该尺寸下画几条线（尺寸降级表）：
  /// - `< 48` → 2 条（极小内联位）
  /// - `< 80` → 3 条（页面里那几处 56px 内联加载）
  /// - 否则 → 5 条（整页加载态）
  @visibleForTesting
  static int lineCountFor(double side) =>
      side < _kTinySide ? 2 : (side < _kSmallSide ? 3 : _kMaxLines);

  /// 测试专用：[t] 时刻第 [index] 条线的几何；还没落墨返回 null。
  ///
  /// `(x0, x1)` 是已画出部分的左右端、`y` 是这条线的纵坐标（都在画布坐标里）。
  /// 与真正绘制走同一套 [_layoutOf] / [_drawProgressAt]，不会"测的和画的不是一回事"。
  @visibleForTesting
  ({double x0, double x1, double y})? debugLineAt(
    int index,
    double t,
    double side,
  ) =>
      _lineAt(index, t, side);

  /// 测试专用：领墨笔尖的尺寸（px，宽 × 高）——**短竖条**（刃 / 笔尖），
  /// 恒有 `height > width`。与 [paint] 共用同一份，不会"测的和画的不是一回事"。
  @visibleForTesting
  static Size nibSizeFor(double side) => side < _kSmallSide
      ? const Size(_kPressNibWSmall, _kPressNibHSmall)
      : const Size(_kPressNibW, _kPressNibH);

  /// 测试专用：领墨笔尖在 [t] 时刻的中心与墨量（已乘过整片淡出；
  /// [alpha] 是相对 [smoke] 的系数，1.0 = 满档）。笔尖尺寸见 [nibSizeFor]。
  @visibleForTesting
  ({double cx, double cy, double alpha})? debugAccentAt(double t, double side) =>
      _accentAt(t, side);

  /// 测试专用：整片墨量系数（1.0 = 满墨，[kPressHoldAlpha] = 淡到地板，0 = 空白）。
  @visibleForTesting
  double debugFadeAt(double t) => _fadeAt(t);

  /// 第 [index] 条线在 [t] 时刻的几何（绘制与测试共用一份）。
  ({double x0, double x1, double y})? _lineAt(
    int index,
    double t,
    double side,
  ) {
    final layout = _layoutOf(side);
    if (layout == null || index < 0 || index >= layout.count) return null;
    final u = _drawProgressAt(index, t);
    if (!(u > 0)) return null;
    final x0 = layout.box.left;
    return (x0: x0, x1: x0 + layout.widthAt(index) * u, y: layout.yAt(index));
  }

  /// 领墨笔尖在 [t] 时刻的中心与墨量（绘制与测试共用一份）。
  ({double cx, double cy, double alpha})? _accentAt(double t, double side) {
    final layout = _layoutOf(side);
    if (layout == null) return null;
    final fade = _fadeAt(t);
    if (fade <= 0) return null;
    final lead = _leadIndexOf(layout, t);
    if (lead != null) {
      final line = _lineAt(lead, t, side)!;
      return (cx: line.x1, cy: line.y, alpha: fade);
    }
    final last = layout.count - 1;
    return (
      cx: layout.box.left + layout.widthAt(last),
      cy: layout.yAt(last),
      alpha: fade * 0.45,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final side = math.min(size.width, size.height);
    if (!(side > 0)) return;
    // 内容盒：四周留白 16% ⇒ 内容只占中间约 68%（与空态插画同一份留白契约）
    final box = _contentBox(size);
    if (box.width <= 4 || box.height <= 4) return;

    final t = effectiveT;
    // 整片墨量：0.80 起淡、0.92 淡到地板，之后回到空白（"这一轮印完了"）
    final fade = _fadeAt(t);
    if (fade <= 0) return;

    final layout = _PressLayout(box, lineCountFor(side));
    final frontFade = side < _kSmallSide ? _kFrontFadeSmall : _kFrontFade;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (var i = 0; i < layout.count; i++) {
      final u = _drawProgressAt(i, t);
      if (!(u > 0)) continue; // 还没起笔 / 本轮不画
      final y = layout.yAt(i);
      final x0 = box.left;
      final x1 = x0 + layout.widthAt(i) * u;
      // 满墨段：笔已经划过并干透的部分
      final fadeLen = math.min(frontFade, x1 - x0);
      final solidEnd = x1 - fadeLen;
      if (solidEnd > x0) {
        paint.color = ink.withValues(alpha: ink.a * fade);
        canvas.drawLine(Offset(x0, y), Offset(solidEnd, y), paint);
      }
      // 前沿渐隐：3 段不同墨量拼出"墨还湿"的柔边（半调思路，不用 blur）
      for (var k = 0; k < _kFrontAlphas.length; k++) {
        final segStart = solidEnd + fadeLen * k / _kFrontAlphas.length;
        final segEnd = solidEnd + fadeLen * (k + 1) / _kFrontAlphas.length;
        paint.color = ink.withValues(alpha: ink.a * fade * _kFrontAlphas[k]);
        canvas.drawLine(Offset(segStart, y), Offset(segEnd, y), paint);
      }
    }

    // 点缀墨：一枚"笔尖"短竖条。同一时刻只画"正在画"的那条线里 index 最小的，
    // 立在它的笔尖上（它领着墨走）；一条线都不在画时停在最后一条线右端、
    // 墨量收敛到 0.45。
    final accent = _accentAt(t, side);
    if (accent == null) return;
    final nib = nibSizeFor(side);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(accent.cx, accent.cy),
        width: nib.width,
        height: nib.height,
      ),
      Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true
        ..color = smoke.withValues(alpha: smoke.a * accent.alpha),
    );
  }

  /// 内容方框：四周留白 16% ⇒ 内容只占中间约 68%（与 `dot_illustration.dart`
  /// 同一份留白契约）。
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

  /// 边长 [side] 下的构图（退化尺寸返回 null）。
  _PressLayout? _layoutOf(double side) {
    if (!(side > 0) || !side.isFinite) return null;
    final box = _contentBox(Size.square(side));
    if (box.width <= 4 || box.height <= 4) return null;
    return _PressLayout(box, lineCountFor(side));
  }

  /// 第 [index] 条线在 [t] 时刻画到几分（0 = 还没起笔，1 = 印满）。
  double _drawProgressAt(int index, double t) =>
      ((t - index * _kLineDelayStep) / _kLineDrawSpan).clamp(0.0, 1.0);

  /// "正在画"的线里 index 最小的那条（都画完 / 都没起笔 → null）。
  int? _leadIndexOf(_PressLayout layout, double t) {
    for (var i = 0; i < layout.count; i++) {
      final u = _drawProgressAt(i, t);
      if (u > 0 && u < 1) return i;
    }
    return null;
  }

  /// 整片墨量系数：`[0, 0.80]` 满墨 → `[0.80, 0.92]` 线性淡到 [kPressHoldAlpha]
  /// → `[0.92, 1.0]` 回到空白（形成可读的"这一轮印完了"）。
  double _fadeAt(double t) {
    if (t <= _kHoldStart) return 1.0;
    if (t <= _kHoldEnd) {
      final u = (t - _kHoldStart) / (_kHoldEnd - _kHoldStart);
      return 1.0 - (1.0 - kPressHoldAlpha) * u;
    }
    final u = ((t - _kHoldEnd) / (1.0 - _kHoldEnd)).clamp(0.0, 1.0);
    return kPressHoldAlpha * (1.0 - u);
  }

  /// 只有"颜色变了"或"静态/动画路径切换了"才需要重绘——动画期间的重绘由
  /// [progress] 这个 listenable 驱动（每帧 `markNeedsPaint`，不 rebuild）。
  /// 这里刻意**不**返回常量：颜色/路径不变时等价于 `false`（零额外重绘），
  /// 但换配色配方 / 从静态切到动画时能正确刷新（返回常量会漏掉这两种）。
  @override
  bool shouldRepaint(SmokeSilhouettePainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.smoke != smoke ||
      (oldDelegate.progress == null) != (progress == null);
}

/// 一次印刷走纸的构图（由内容盒 + 线数算出来，每帧都一样 → 位置不动）。
@immutable
class _PressLayout {
  const _PressLayout(this.box, this.count);

  /// 内容盒（中间约 68%）。
  final Rect box;

  /// 线数（见 [SmokeSilhouettePainter.lineCountFor]）。
  final int count;

  /// 相邻两条线的纵向间距（占盒高）：把 [_kLineSpanFrac] 等分。
  double get _spacing => _kLineSpanFrac / (count - 1);

  /// 第 [i] 条线的纵坐标：等距，首条在 [_kLineTopFrac]、末条在 0.82。
  double yAt(int i) => box.top + box.height * (_kLineTopFrac + _spacing * i);

  /// 第 [i] 条线的宽度（占盒宽 × 常量表的 ±6% 抖动）。
  double widthAt(int i) => box.width * _kLineWidths[i] * _kLineJitters[i];
}
