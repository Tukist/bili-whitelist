/// 通用风衣男抽烟剪影（**非任何具体角色**）。
///
/// ⚠️ **版权边界（本仓库是公开 GitHub 仓库，必须守住）**：
/// 本组件只画「一个人站在夜里抽一支烟」的**通用气质**——帽檐、帽顶、肩线、
/// 风衣下摆、持烟的手。**不得**添加任何指向具体角色的可识别特征：
/// 不画头发/发丝、不画眼睛或义眼、不画面部细节、不出现特定服装配色、
/// 不出现角色名/作品名/台词。凡是想"再像一点"的改动，都是把通用剪影变成
/// 侵权复刻，请先停下来重新评估。
///
/// 双色分工（沿用全库「两个墨各有职责」的约定）：
/// - 剪影 = [AppPalette.inkDeco]（**图形/非文字档**，与纸底 ≥ 3:1）；
/// - 烟 = [AppPalette.accent]（点缀墨职责 = **时间与新鲜度**；烟 = 燃烧/流逝，
///   语义天然吻合，是点缀墨在本库最正当的一次用法）。
///
/// **底材限制**：只能用在 [kPaper] 一类浅底材上。播放页黑底反转底材
/// （[kPlayerPaper] 那一套）上 inkDeco 与底色对比不足甚至消失，
/// **禁止放在播放页黑盒内部**。
///
/// 性能：外层 [RepaintBoundary] + `CustomPainter` 挂在
/// `AnimationController` 的 listenable 上（与 `danmaku_overlay.dart` 同款
/// 模式）——每帧只 `paint` 本层，不 rebuild widget 树、不重排。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_palette.dart';
import '../theme/motion_control.dart';
import 'dot_halftone.dart' show stableSeed;

/// 静态帧（[SmokeSilhouette.animate] = false 或无 ticker 时）取的进度：
/// 0.35 是「一支烟正在中途」——烟缕已升起一段、还看得见，不留空场。
const double kStaticSmokeT = 0.35;

/// 烟缕从生成到长成的时间占比：`u < 0.12` 是生成段（半径 0 → r0、alpha 0 → 0.55）。
const double _kBirthEnd = 0.12;

/// 烟缕开始渐隐的进度（`u > 0.55` 起 alpha 0.55 → 0，线性）。
const double _kFadeStart = 0.55;

/// 烟缕峰值 alpha（生成段的终点，也是渐隐段的起点）。
const double _kSmokePeakAlpha = 0.55;

/// 烟缕上升总位移（归一化 100×100 空间里的单位）。
const double _kSmokeRise = 46.0;

/// 烟缕横向摆动的最大幅度（归一化单位，乘 swayGain = u 后生效）。
const double _kSmokeSway = 7.0;

/// 烟头在归一化空间里的位置（烟缕从这里升起）。
const double _kTipX = 84.5;
const double _kTipY = 56.0;

/// 一条烟缕的确定性参数（由 [stableSeed]`('smoke')` 的表给出，**不随帧变化**，
/// 否则烟会闪成噪点）。
@immutable
class SmokeBand {
  const SmokeBand({
    required this.phase,
    required this.swayFreq,
    required this.swayPhase,
    required this.growScale,
    required this.driftX,
  });

  /// 生命周期相位偏移：三条错开出发，画面里始终有烟。
  final double phase;

  /// 横向摆动频率（圈 / 生命周期）。
  final double swayFreq;

  /// 横向摆动初相（弧度）。
  final double swayPhase;

  /// 膨胀系数（1 ± 18%）：三条烟缕粗细各异，不像同一个模子刻的。
  final double growScale;

  /// 整体横向漂移（归一化单位）：让三条不在同一条竖线上。
  final double driftX;
}

/// 三条烟缕的参数表（**进程内只算一次**，恒定不变 → 重建/重绘不闪烁）。
///
/// 基值（相位 0.00/0.37/0.71、摆频 1.4/1.7/1.15）刻意**非等分**：等分相位会让
/// 三条烟缕的生成/渐隐同一拍，看上去像"节拍器"而不是烟。抖动部分走
/// [stableSeed] 的确定性哈希，跨 SDK 版本 / 跨平台一致。
final List<SmokeBand> _kSmokeBands = _buildSmokeBands();

List<SmokeBand> _buildSmokeBands() {
  // 确定性伪随机（xorshift32）：只用来生成一次性常量表，成功后不再被调用。
  var h = stableSeed('smoke');
  double next() {
    h ^= (h << 13) & 0xFFFFFFFF;
    h ^= h >> 17;
    h ^= (h << 5) & 0xFFFFFFFF;
    h &= 0xFFFFFFFF;
    return h / 0x100000000;
  }

  const phases = <double>[0.00, 0.37, 0.71];
  const freqs = <double>[1.4, 1.7, 1.15];
  return [
    for (var i = 0; i < phases.length; i++)
      SmokeBand(
        phase: phases[i],
        swayFreq: freqs[i],
        swayPhase: next() * 2 * math.pi,
        growScale: 1 - 0.18 + next() * 0.36, // 1 ± 18%
        driftX: (next() - 0.5) * 6.0, // ±3 归一化单位
      ),
  ];
}

/// 风衣男抽烟剪影（见文件头版权边界：**通用形象，不指向任何具体角色**）。
///
/// 剪影几何在归一化 100×100 空间构图，整体按 [size] 等比缩放（构图与尺寸
/// 解耦：改 [size] 只改大小、不改比例）。
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

  /// 是否让烟缕动起来。false → 静态一帧（t = [kStaticSmokeT]），零 ticker。
  final bool animate;

  /// 剪影色；默认 [AppPalette.inkDeco]（图形档，与纸底 ≥ 3:1）。
  final Color? ink;

  /// 烟色；默认 [AppPalette.accent]（点缀墨 = 时间与新鲜度）。
  final Color? smoke;

  /// 当前存活的烟缕 ticker 数（**仅供测试断言不泄漏**）。
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
      _ctl = AnimationController(vsync: this, duration: kSmokeCycle)..repeat();
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
      // RepaintBoundary：烟缕每帧重绘只发生在本层，不波及父级（列表/空态整树）。
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

/// 剪影 + 烟缕的画笔。
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

  /// 剪影墨（图形档 [AppPalette.inkDeco]）。
  final Color ink;

  /// 烟墨（点缀墨 [AppPalette.accent]）。
  final Color smoke;

  /// 动画进度源；**null = 静态路径**（画 [kStaticSmokeT] 那一帧，零 ticker）。
  final Animation<double>? progress;

  /// 当前用于绘制的进度。
  double get effectiveT => progress?.value ?? kStaticSmokeT;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // 归一化 100×100 → size：构图与尺寸解耦（同一份几何，任意尺寸等比）。
    final s = math.min(size.width, size.height) / 100.0;
    if (!(s > 0)) return;
    canvas.save();
    canvas.scale(s);
    _paintSilhouette(canvas);
    // 烟缕后画（压在最上层）：烟头亮点的"燃着"感不被任何实体压住。
    _paintSmoke(canvas);
    canvas.restore();
  }

  /// 剪影本体：外轮廓**一律填充**（`PaintingStyle.fill`）——填充边界干净、
  /// 没有描边的膨胀感，才叫"剪影"。只有手臂与烟两支细杆用描边。
  void _paintSilhouette(Canvas canvas) {
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = ink
      ..isAntiAlias = true;

    // ---- 风衣主体（一环闭合轮廓；上直下曲：上半身直线、下摆外扩） ----
    // evenOdd + 两个内嵌三角负形 = 下摆开衩 + 翻领，不用额外 mask。
    final coat = Path()..fillType = PathFillType.evenOdd;
    coat.moveTo(33, 40);
    coat.quadraticBezierTo(24, 60, 26, 82); // 左身外缘（左下摆外扩到 x=26）
    coat.lineTo(42, 83);
    coat.lineTo(66, 83);
    coat.lineTo(70, 88); // 右下摆外扩尖
    coat.lineTo(70, 84);
    coat.quadraticBezierTo(72, 62, 63, 40); // 右身外缘（反向回到右肩）
    coat.close();
    // 负形 1：下摆开衩（x≈52 竖缝）——风衣感的来源
    coat.moveTo(50, 80);
    coat.lineTo(54, 80);
    coat.lineTo(52, 88);
    coat.close();
    // 负形 2：翻领 V 口——暗示"穿了件有领子的衣服"，不画任何细节
    coat.moveTo(44, 40);
    coat.lineTo(48, 48);
    coat.lineTo(52, 40);
    coat.close();
    canvas.drawPath(coat, fill);

    // ---- 帽檐（直线折线，不用弧：直线硬 = 冷）----
    // 微上翘的檐尖（(52,26) 高于两端）给一点"痞"，但不构成任何角色特征。
    final brim = Path()
      ..moveTo(30, 30)
      ..lineTo(52, 26)
      ..lineTo(70, 31)
      ..lineTo(68, 35)
      ..close();
    canvas.drawPath(brim, fill);

    // ---- 帽顶（极小梯形）----
    // 只到帽冠为止：**不画发丝**，这是去角色化的关键一笔。
    final crown = Path()
      ..moveTo(40, 28)
      ..lineTo(58, 26)
      ..lineTo(60, 20)
      ..lineTo(42, 22)
      ..close();
    canvas.drawPath(crown, fill);

    // ---- 肩线（6px 圆头描边）----
    // 控制点下沉 3px（y=41 低于两端 38）= 肩的松弛感，不是军装式平肩。
    final shoulder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = ink
      ..isAntiAlias = true;
    final shoulderPath = Path()
      ..moveTo(30, 38)
      ..quadraticBezierTo(48, 41, 66, 38);
    canvas.drawPath(shoulderPath, shoulder);

    // ---- 手臂（6px 细杆，从风衣里探出）----
    // 只画一根杆 + 一个圆手：表达"持"的语义，不画手指细节。
    final arm = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = ink
      ..isAntiAlias = true;
    canvas.drawLine(const Offset(60, 52), const Offset(74, 60), arm);
    canvas.drawCircle(const Offset(74, 60), 3.4, fill); // 手

    // ---- 烟（1.6px 描边 + 圆头）----
    // 「细线 vs 大块实体」的反差就是一支烟的存在感：线一定要细。
    final cigarette = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = smoke.withValues(alpha: smoke.a * 0.85)
      ..isAntiAlias = true;
    canvas.drawLine(const Offset(76, 59), const Offset(_kTipX, _kTipY),
        cigarette);

    // ---- 烟头（实心小圆，满档 alpha）----
    // 同色但更实 → 读作"燃着"。全图唯一的满档亮点，视线落点在这里。
    canvas.drawCircle(
      const Offset(_kTipX, _kTipY),
      2.2,
      Paint()
        ..style = PaintingStyle.fill
        ..color = smoke
        ..isAntiAlias = true,
    );
  }

  /// 烟缕：确定性"粒子带"（不是真粒子系统——固定 3 条，参数表恒不变）。
  ///
  /// 单条生命周期（`u = (t + phase) % 1`）：
  /// - 生成 `u < 0.12`：半径 `0 → r0`、alpha `0 → 0.55`；`r0 = 1.2 + 0.9×band`
  /// - 上升：`y = y0 − 46 × kCurveSmokeRise.transform(u)`（起步快、末端几乎停滞）
  /// - 横摆：`x = x0 + 7 × u × sin(2π(swayFreq×u + swayPhase))`（越低越不晃）
  /// - 膨胀：`r = r0 × (1 + 2.2u) × growScale`
  /// - 渐隐：`u > 0.55` 起 alpha 线性降到 0
  ///
  /// **柔边是"烟"而非"一串球"的关键**：每团都过
  /// `MaskFilter.blur(BlurStyle.normal, r×0.6)`。
  void _paintSmoke(Canvas canvas) {
    final t = effectiveT;
    for (var band = 0; band < _kSmokeBands.length; band++) {
      final b = _kSmokeBands[band];
      final r0 = 1.2 + 0.9 * band;
      final u = (t + b.phase) % 1.0;

      final birth = (u / _kBirthEnd).clamp(0.0, 1.0);
      final fade = u <= _kFadeStart
          ? 1.0
          : (1.0 - (u - _kFadeStart) / (1.0 - _kFadeStart)).clamp(0.0, 1.0);
      final alpha = _kSmokePeakAlpha * birth * fade;
      if (alpha <= 0.002) continue; // 生成前一瞬 / 消散后：不画

      final r = r0 * (1 + 2.2 * u) * birth * b.growScale;
      if (!(r > 0.05)) continue;

      final x = _kTipX +
          b.driftX +
          _kSmokeSway * u * math.sin(2 * math.pi * (b.swayFreq * u + b.swayPhase));
      final y = _kTipY - _kSmokeRise * kCurveSmokeRise.transform(u);

      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = smoke.withValues(alpha: smoke.a * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.6)
          ..isAntiAlias = true,
      );
    }
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
