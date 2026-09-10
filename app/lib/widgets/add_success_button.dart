/// 「加入白名单」按钮 + 成功确认动效（P7）。
///
/// 三态由宿主给（[AddState]），按钮只负责画：
/// - [AddState.idle]：可点，文案 [AddSuccessButton.idleLabel]（默认「加入」）；
/// - [AddState.loading]：禁用 + 内联 14px 转圈（**与既有观感一致**，
///   这是操作反馈，不是等待画面）；
/// - [AddState.added]：禁用 + 勾 + 文案 [AddSuccessButton.addedLabel]
///   （默认「已加入」）；实心底换成淡底（沿用现状：实心「加入」→
///   淡底「已加入」，见 [AddSuccessButton.useTonal]）。
///
/// 成功动效只在「非 added → added」这一步**叠加播放一次**（不是循环）：
/// - **两圈扩散环**：主墨描边圆从按钮中心向外扩，alpha 0.35 → 0；
/// - **描边生长的勾**：一条两段折线 `Path` 用 `PathMetric.extractPath`
///   按进度截取（`kDurSlow` 内画完）。
/// 两者都叠在按钮上，且整层 [ClipRRect] 跟按钮圆角裁切，不溢出。
///
/// 三条硬约束（都写进 `test/add_success_button_test.dart` 了）：
/// 1. **关动效 = 零 ticker**：[MotionControl.of] 为 false（含 `flutter test`
///    默认环境）时连 [AnimationController] 都不建 —— 不是「建了不 forward」，
///    树里也没有波纹层。既有测试的 `pumpAndSettle` 因此不会被卡住；
/// 2. **一次性**：播完（`completed`）即 `setState` 卸载波纹层，树里不留残余
///    动效层；
/// 3. **不引第三方依赖**：`CustomPainter` + `AnimationController` 足够，
///    不用 Lottie。
///
/// 颜色分工（见 `app_palette.dart` 的分档）：
/// - 扩散环是**装饰**（一次性、不承载信息）→ 配方原墨 [AppPalette.ink]；
/// - 勾是**承载「已加入」状态的图形**（动效结束后仍在树上）→
///   [AppPalette.inkText]（「纸 / 浅底上的图标」那一档，已过对比度护栏）。
///
/// 文案字符串（「加入」/「已加入」）是既有测试的锚点（如
/// `test/whitelist_writer_test.dart`、以及各页 `find.text('加入')`），
/// 调用方改文案前先看测试。
library;

import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';

/// 按钮三态。
enum AddState {
  /// 可点（「加入」）
  idle,

  /// 提交中：禁用 + 内联转圈
  loading,

  /// 已加入：禁用 + 勾 +「已加入」
  added,
}

/// 波纹动效层的 Key：**只在动效播放期间**挂在树上（播完卸载）。
///
/// 测试用它断言「动效层出现 / 卸载」，也用它断言关动效时树里干干净净。
const kAddSuccessMotionKey = ValueKey<String>('addSuccessMotion');

/// 「加入白名单」按钮：三态 + 成功时的克制确认动效。
class AddSuccessButton extends StatefulWidget {
  const AddSuccessButton({
    super.key,
    required this.state,
    this.idleLabel = '加入',
    this.addedLabel = '已加入',
    this.onPressed,
    this.compact = false,
    this.useTonal = false,
  });

  /// 当前状态（由宿主的状态机映射，按钮不自己改状态）。
  final AddState state;

  /// idle 态文案。
  final String idleLabel;

  /// added 态文案。
  final String addedLabel;

  /// idle 态点击回调；为 null → 禁用（外观仍是实心底，与 loading 区分）。
  final VoidCallback? onPressed;

  /// true → 内边距收紧（列表尾等窄位）。
  ///
  /// 触摸目标仍由主题的 `materialTapTargetSize.padded` 兜到 ≥48dp
  /// （`_InputPadding` 把命中区撑开，不放大视觉尺寸）。
  final bool compact;

  /// true → idle 态也用 `FilledButton.tonal`（次要按钮场景）。
  ///
  /// added 态**一律**走 tonal：淡底表示「已完成，不再是一个动作」。
  final bool useTonal;

  @override
  State<AddSuccessButton> createState() => _AddSuccessButtonState();
}

class _AddSuccessButtonState extends State<AddSuccessButton>
    with SingleTickerProviderStateMixin {
  /// 动效播放期间才有；关动效时**恒为 null**（零 ticker）。
  AnimationController? _c;

  /// [MotionControl.of] 的当前值（`didChangeDependencies` 里刷新）。
  bool _motion = true;

  /// 波纹动效层是否在树上（播完卸载）。
  bool _layer = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion = MotionControl.of(context);
    // 播放途中系统切成「减少动画」→ 立刻收尾。这里**故意不 setState**：
    // didChangeDependencies 之后紧跟着本次 build，直接改字段即可生效，
    // 而 setState 会撞上「build 期间 markNeedsBuild」。
    if (!_motion && _layer) {
      _c?.stop();
      _layer = false;
    }
  }

  @override
  void didUpdateWidget(AddSuccessButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有「非 added → added」这一步才演：新挂载就是 added（例如列表重建时
    // 该项本已在白名单）= 静态态，不演。
    final becameAdded =
        oldWidget.state != AddState.added && widget.state == AddState.added;
    if (!becameAdded) {
      // 回到非 added（加入失败 / 重新搜索）→ 收掉残余动效层
      if (widget.state != AddState.added && _layer) {
        _c?.stop();
        _layer = false;
      }
      return;
    }
    // 关动效：零 ticker、零波纹层（不建 controller，而不是建了不 forward）
    if (!_motion) return;
    final c = _c ?? AnimationController(vsync: this, duration: kDurSlow);
    c
      ..removeStatusListener(_onStatus)
      ..addStatusListener(_onStatus)
      ..duration = kDurSlow;
    _c = c;
    _layer = true;
    c.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    // 播完 → 卸载波纹层：树里不留动效层（勾转为静态满描边，不跳变）
    setState(() => _layer = false);
  }

  @override
  void dispose() {
    _c?.removeStatusListener(_onStatus);
    _c?.dispose();
    _c = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = _c;
    final animating = _layer && widget.state == AddState.added && c != null;
    final button = _buildButton(p, animating ? c : null);
    if (!animating) return button;
    // 波纹层叠在按钮上：IgnorePointer 让动效期内的点击语义保持原样
    // （added 态本来就禁用，这里只是不留隐患）。整层跟着按钮圆角裁切。
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRadiusMd),
      child: Stack(
        children: [
          button,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                key: kAddSuccessMotionKey,
                painter: _RipplePainter(progress: c, ink: p.ink),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// [progress] 非空 = 正在演（勾跟着生长）；空 = 静态满描边。
  Widget _buildButton(AppPalette p, Animation<double>? progress) {
    switch (widget.state) {
      case AddState.loading:
        return _shell(
          onPressed: null,
          child: const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case AddState.added:
        return _shell(
          onPressed: null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(
                  painter: _CheckPainter(progress: progress, color: p.inkText),
                ),
              ),
              const SizedBox(width: kSpace4),
              Text(widget.addedLabel),
            ],
          ),
        );
      case AddState.idle:
        return _shell(
          onPressed: widget.onPressed,
          child: Text(widget.idleLabel),
        );
    }
  }

  /// 统一的按钮外壳（两处 shell 只差 tonal / 尺寸）。
  Widget _shell({required VoidCallback? onPressed, required Widget child}) {
    // added 一律淡底：已完成 ≠ 一个还能按的动作
    final tonal = widget.useTonal || widget.state == AddState.added;
    final style = widget.compact
        // compact：内边距收紧，视觉高度 32；命中区仍由 padded 兜到 48
        ? FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace12,
              vertical: kSpace4,
            ),
            minimumSize: const Size(0, 32),
          )
        : null;
    return tonal
        ? FilledButton.tonal(onPressed: onPressed, style: style, child: child)
        : FilledButton(onPressed: onPressed, style: style, child: child);
  }
}

/// 静态的勾图标（与 [AddSuccessButton] 成功态同一个勾的形状）。
///
/// 给「小面积确认」复用：SnackBar 首行的小勾、完成提示旁的状态标记等。
/// 无声无息 —— 不带动效、不建 ticker，宿主想演就自己包一层。
class AddSuccessCheck extends StatelessWidget {
  const AddSuccessCheck({super.key, required this.color, this.size = 16});

  /// 勾的描边色。SnackBar（墨底）上用 `kPaper`，纸上用 `palette.inkText`。
  final Color color;

  /// 正方形边长；勾按 16×16 单位坐标系等比缩放。
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _CheckPainter(color: color)),
      );
}

/// 成功提示条的内容：小号勾 + 文案（给 `SnackBar` 用）。
///
/// `SnackBar` 是墨底（`kInkBlack`），勾走纸白 `kPaper` —— 配方主墨落在墨底上
/// 对比度不足 1.5:1，根本读不出来。**文案字符串不做任何改写**（调用方传进来
/// 是什么就显示什么）。
class AddSuccessSnackContent extends StatelessWidget {
  const AddSuccessSnackContent({super.key, required this.message});

  /// 原样展示的文案。
  final String message;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const AddSuccessCheck(color: kPaper, size: 24),
          const SizedBox(width: kSpace8),
          // Expanded：长文案照旧换行，不被 Row 撑爆（SnackBar 给的宽度是有限的）
          Expanded(child: Text(message)),
        ],
      );
}

/// 两圈扩散环：半径由中心向外扩大、alpha 0.35 → 0。
///
/// 只用一条 [Animation]（不建 widget），靠 `CustomPainter` 的 repaint
/// 监听逐帧重绘 —— 不掉进「每帧 setState」的反模式。
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.progress, required this.ink})
      : super(repaint: progress);

  final Animation<double> progress;

  /// 配方原墨（装饰用途，不压深）。
  final Color ink;

  /// 环数
  static const int _rings = 2;

  /// 相邻环的起步错峰（占总时长的比例）
  static const double _stagger = 0.22;

  /// 起手不透明度
  static const double _maxAlpha = 0.35;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // 半径上限取对角线一半再留一点余量：环会跑到圆角外，由外层 ClipRRect
    // 裁掉（「不溢出」靠裁切，不靠算内切）
    final maxR = size.longestSide / 2 + 2;
    final span = 1 - _stagger * (_rings - 1);
    for (var i = 0; i < _rings; i++) {
      final t = ((progress.value - i * _stagger) / span).clamp(0.0, 1.0);
      if (t <= 0) continue;
      final eased = kCurveOut.transform(t);
      canvas.drawCircle(
        center,
        maxR * eased,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ink.withValues(alpha: _maxAlpha * (1 - eased)),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.progress != progress;
}

/// 描边生长的勾：16×16 单位坐标系里的两段折线，按进度截取。
class _CheckPainter extends CustomPainter {
  /// [progress] 空 = 静态满描边（无 ticker、无 repaint 监听）。
  _CheckPainter({required this.color, this.progress}) : super(repaint: progress);

  final Color color;
  final Animation<double>? progress;

  /// 单位坐标系（16×16）：起笔 → 折点 → 收笔
  static final Path _unit = Path()
    ..moveTo(3.0, 8.6)
    ..lineTo(6.5, 11.9)
    ..lineTo(13.2, 4.4);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress?.value ?? 1.0;
    if (t <= 0) return;
    canvas.save();
    canvas.scale(size.width / 16, size.height / 16);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    if (t >= 1) {
      canvas.drawPath(_unit, paint);
    } else {
      // 描边生长：按折线总长截取到 t —— 笔尖一路画过去，不是整体淡入
      final metric = _unit.computeMetrics().first;
      canvas.drawPath(metric.extractPath(0, metric.length * t), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.progress != progress;
}
