/// 加载文案的**逐字淡入 + 上浮**特效（块化批次 0）。
///
/// ⚠️ 用途边界（硬约束）：**只用于新增的副文案**（空态/加载态/错误态里
/// 新写的那几句），绝不套在既有主文案上 —— 那些文案是页面测试
/// `find.text('...')` 的断言锚点，拆成逐字 widget 后断言会全部失效。
///
/// 设计要点：
/// - 逐字用 `String.runes`（`dart:core`，零依赖；CJK / emoji 按码点切）；
/// - **一个** [AnimationController] + 每字一个 [Interval]，不是每字一个
///   controller（否则一句 20 字就是 20 个 ticker）；
/// - 不动 `letterSpacing`：字距一变整句都会 reflow，字会在句里左右乱跳，
///   看起来像 bug；
/// - 无障碍：逐字 widget 会拆出 N 个语义节点（读屏会一个字一个字念），
///   所以逐字部分整体 [ExcludeSemantics]，外层补一个 [Semantics] 读整句。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';

/// 超过这个字数 → 换用 [kCopyCharStepDense]（密集步进）
const int _kDenseCharCount = 30;

/// 逐字特效的总时长上限（ms）：**只对已降级的长句生效**。
/// 常规步进（24ms）下 22 字的句子天然就是 ~704ms，不该被改；
/// 这个上限是给"超长文案 + dense 步进"兜底的，保证再长也不拖成长镜头。
const int _kTotalCapMs = 700;

/// 加载文案逐字入场。
///
/// ```dart
/// AnimatedCopyLine(
///   text: '人生有时就得管没有肉的青椒肉丝，叫青椒肉丝。',
///   keywords: const ['青椒肉丝'],
/// )
/// ```
class AnimatedCopyLine extends StatefulWidget {
  const AnimatedCopyLine({
    super.key,
    required this.text,
    this.style,
    this.keywords = const <String>[],
    this.step = kCopyCharStep,
    this.charDur = kCopyCharDur,
    this.risePx = kCopyCharRisePx,
    this.enabled,
  });

  /// 整句文案（逐字路径下**不会**整串出现在一个 `Text` 里，
  /// 所以只有[enabled] = false 时 `find.text(text)` 才命中）
  final String text;

  /// 默认 [kTypeBodyS] + [kInkGray70]
  final TextStyle? style;

  /// 关键词（用 [AppPalette.inkDeep] 上色；同一支墨的深一档）
  final List<String> keywords;

  /// 相邻字步进
  final Duration step;

  /// 单字入场时长
  final Duration charDur;

  /// 单字起始下移量（px）
  final double risePx;

  /// null → 读 [MotionControl.of]；false → 退化成单个 [Text]
  final bool? enabled;

  @override
  State<AnimatedCopyLine> createState() => _AnimatedCopyLineState();
}

class _AnimatedCopyLineState extends State<AnimatedCopyLine>
    // 文案变化时要重建 controller（见 didUpdateWidget）→ 一个 State 生命周期内
    // 可能创建多个 ticker，必须用 TickerProviderStateMixin（Single 只允许一次）。
    with TickerProviderStateMixin {
  AnimationController? _c;
  List<CurvedAnimation>? _chars;

  /// 生效开关（首帧前解析一次）
  bool _enabled = false;
  bool _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 同 StaggeredEntrance：不在 initState 里查 MotionControl.of（它走
    // MediaQuery.of，initState 里查祖先会抛断言）。didChangeDependencies
    // 在首帧前同步执行，够用。
    if (_armed) return;
    _armed = true;
    _enabled = widget.enabled ?? MotionControl.of(context);
    if (!_enabled) return; // 退化路径：连 controller 都不建
    _buildController();
  }

  @override
  void didUpdateWidget(covariant AnimatedCopyLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文案/节奏换了 → 重建 controller（时长是按字数算出来的，沿用旧时长
    // 会让 Interval 越界）。这里**不再查 context**（复用首帧解析的
    // _enabled），didUpdateWidget 里做祖先查找是自找麻烦。
    if (!_enabled) return;
    if (oldWidget.text == widget.text &&
        oldWidget.step == widget.step &&
        oldWidget.charDur == widget.charDur) {
      return;
    }
    _disposeController();
    _buildController();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    final chars = _chars;
    if (chars != null) {
      for (final a in chars) {
        a.dispose();
      }
      _chars = null;
    }
    _c?.dispose();
    _c = null;
  }

  void _buildController() {
    final n = widget.text.runes.length;
    final int charDurMs = math.max(1, widget.charDur.inMilliseconds);
    // 长句降级：步进减半，整句才不会拖成长镜头
    final dense = n > _kDenseCharCount;
    int stepMs =
        dense ? kCopyCharStepDense.inMilliseconds : widget.step.inMilliseconds;
    // ⚠️ math.max 的结果直接当乘数会被推断成 num（`num operator *` 传下去的
    // 上下文类型就是 num）→ 先落到 int 变量，再参与算术。
    final int gap = math.max(0, n - 1);
    int totalMs = stepMs * gap + charDurMs;
    if (dense && n > 1 && totalMs > _kTotalCapMs && charDurMs < _kTotalCapMs) {
      // 降级后还是超过上限（超长句）→ 把步进等比压到刚好卡在上限
      stepMs = math.max(1, (_kTotalCapMs - charDurMs) ~/ gap);
      totalMs = stepMs * gap + charDurMs;
    }

    final c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
    _c = c;
    if (n > 0) {
      // 每字一个 Interval：第 i 个字在 [i*step, i*step + charDur] 里走完
      _chars = List<CurvedAnimation>.generate(n, (i) {
        final begin = (i * stepMs) / totalMs;
        final end = math.min(1.0, ((i * stepMs) + charDurMs) / totalMs);
        return CurvedAnimation(
          parent: c,
          curve: Interval(begin, math.max(begin + 1e-6, end), curve: kCurveOut),
        );
      });
    }
    c.forward();
  }

  /// 关键词 → 逐**码点**的着色掩码（与 [String.runes] 对齐，emoji 也不会错位）
  static List<bool> _highlightMask(List<int> runes, List<String> keywords) {
    final mask = List<bool>.filled(runes.length, false);
    for (final kw in keywords) {
      final k = kw.runes.toList(growable: false);
      if (k.isEmpty || k.length > runes.length) continue;
      for (var i = 0; i + k.length <= runes.length; i++) {
        var hit = true;
        for (var j = 0; j < k.length; j++) {
          if (runes[i + j] != k[j]) {
            hit = false;
            break;
          }
        }
        if (!hit) continue;
        for (var j = 0; j < k.length; j++) {
          mask[i + j] = true;
        }
      }
    }
    return mask;
  }

  @override
  Widget build(BuildContext context) {
    // 退化路径：单个 Text（测试里 find.text(整串) 照样命中；读屏也正常）
    final chars = _chars;
    final runes = widget.text.runes.toList(growable: false);
    if (!_enabled || chars == null || chars.length != runes.length) {
      return Text(widget.text, style: widget.style);
    }

    final base = widget.style ?? kTypeBodyS.copyWith(color: kInkGray70);
    final inkDeep = context.palette.inkDeep;
    final mask = _highlightMask(runes, widget.keywords);

    return Semantics(
      // 逐字节点被 ExcludeSemantics 挡掉了 → 这里补整句，读屏念一遍整句
      label: widget.text,
      child: ExcludeSemantics(
        // Wrap 而不是 Row/RichText：长句可换行，且逐字 widget 能各自动
        child: Wrap(
          alignment: WrapAlignment.center,
          children: [
            for (var i = 0; i < runes.length; i++)
              AnimatedBuilder(
                animation: chars[i],
                builder: (_, __) {
                  final t = chars[i].value;
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, widget.risePx * (1 - t)),
                      // 特效路径才用 Text.rich（关键词上色走 span style）
                      child: Text.rich(
                        TextSpan(
                          text: String.fromCharCode(runes[i]),
                          style: mask[i]
                              ? base.copyWith(color: inkDeep)
                              : base,
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
