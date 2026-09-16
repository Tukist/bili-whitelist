/// 信箱卡片（Tinder 式滑动的「一张」）的**外壳**：
/// 定尺寸（扑克牌比例）→ 交给版式渲染（见 `inbox_card_styles.dart`）→
/// 在上面叠一个随手势渐显的浮层标记（四向各一个词，见 [InboxSwipeAction]）。
///
/// 只负责**画**，不碰手势与动画：位移、旋转、飞出/弹回都在 `inbox_page.dart`
/// 里控制（卡片跟手是「位移 + 轻微旋转」，旋转角与水平位移成正比 ——
/// 竖直方向也跟手，但旋转仍只看水平分量，见 [reactionVertical] 与
/// `inbox_page.dart` 的 `_offscreen`）。
///
/// ## 版式与比例（v2.21.0+）
/// - 卡面内容（封面 / 标题 / 作者 / 时长 / 时间怎么排）全部由
///   [InboxCardStyleView] 按 [InboxCardStyle] 决定，本文件**不关心**排版；
/// - 尺寸固定为 `宽 × (宽 × [kInboxCardAspect])`（扑克牌 63:88）→
///   所有版式**同尺寸**，切换风格时卡片栈不跳动，下层卡片的露出量也不受影响；
/// - 新增风格只改 `inbox_card_styles.dart`（见那里的「新增一个风格要动哪几处」）。
///
/// ## 浮层标记的颜色（硬约束）
/// - 实心底只用**已过对比度护栏**的档位：加入 = [AppPalette.inkFill]
///   （+ [AppPalette.onInk] 文字，≥ 4.5:1）；跳过 = [kInkGray70]（+ 纸白文字，
///   实测 ≈ 6.2:1）；取回 = [AppPalette.accentFill]（+ [AppPalette.onAccent]，
///   同一套护栏）；稍后 = [AppPalette.accentWash] 浅底 + [AppPalette.accentDeep]
///   文字（这一对是配色表里"容器底 / 容器底上的文字"的现成护栏组合），另加
///   1px 同色描边 —— 浅卡面上光靠浅底看不出块，描边把边界钉住。
/// - 渐显用 [Opacity] 包**满不透明**的浮层，而不是给底色乘 alpha：前者满显时
///   对比度仍是护栏值，后者会把对比度一起稀释掉。
/// - 标记叠在**整张卡片**之上（旧实现只叠在封面上；卡片变成全出血版式后，
///   只叠封面会在部分版式里露出一半，故改为整卡）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/inbox_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import 'inbox_card_styles.dart';

/// 判定「这一张算数」的水平位移比例（相对屏宽）：超过 30% 即提交。
const double kInboxSwipeThresholdRatio = 0.30;

/// 判定「甩出去」的速度阈值（px/s）：位移不够但甩得够快也算提交。
const double kInboxSwipeVelocity = 700;

/// 拖动时的最大旋转角（±12°，弧度）：旋转角 = 水平位移 / 屏宽 × 该值。
final double kInboxSwipeMaxTilt = 12 * math.pi / 180;

/// **下一张**（深度 1）的底边落在顶层卡片底边之下这么多 dp。
///
/// 卡片栈（`widgets/inbox_card_stack.dart`）用
/// `Positioned(bottom: -下移量)` 做「底边对齐」，缩放锚点取 `bottomCenter`
/// （底边不因缩放上收）→ 净露出量恒为该值，与卡片内容高度（标题 1 行 / 2 行）
/// 无关。
///
/// v2.22.0+ 起卡片栈是**多层**的（顶层 + 后 3 张，越深越小/越低/越淡），
/// 这两个常量是**深度 1** 那层的取值；更深层的取值见
/// `inbox_card_stack.dart` 的缩放/下移表（那里也复用了这两个常量，保证
/// 「下一张露多少」这一既有观感不变）。
const double kInboxStackOffset = 12;

/// **下一张**（深度 1）的缩放比例（以**底边**为锚点，底边位置不变）。
const double kInboxStackScale = 0.96;

/// 一次滑动的**行为** —— 四个方向各一个，也是浮层徽标上要显示的那个词。
///
/// ★ 竖直方向**不是**「加入 / 跳过」的镜像（v2.32.1 订正）★
/// 用户原话：「**下滑不是跳过，而是暂时不判断，先看后面的卡片，可以上滑回来**」。
/// 因此：
/// - [defer]（下滑）= **稍后**：把这一张从队首**推到队尾**，**不做任何判断**
///   （不记「已处理」、不写 Gist、不取元数据）→ 之后还能再看到它；
/// - [restore]（上滑）= **取回**：把**最近一次**被推后的那张拿回栈顶（LIFO），
///   同样不写任何东西。
///
/// ⚠️ 别再引入「上下滑对调」那种布尔开关（v2.32.0 的
/// `kInboxSwipeUpMeansLike` 就是那样，字面语义与产品意图相反，已删）：
/// 上下滑现在**不是同一对动作**，是两件不同的事。
enum InboxSwipeAction {
  /// 右滑：加入白名单（既有语义）。
  like,

  /// 左滑：跳过 —— 只记「已处理」，之后不再出现（既有语义）。
  skip,

  /// 下滑：**稍后** —— 推到队尾、不判断，之后还能再看到（可被上滑取回）。
  defer,

  /// 上滑：**取回** —— 把最近一次被「稍后」推后的那张拿回栈顶。
  restore,
}

/// 信箱卡片（纯展示）：定尺寸 + 版式内容 + 手势浮层。
class InboxSwipeCard extends StatelessWidget {
  const InboxSwipeCard({
    super.key,
    required this.item,
    required this.width,
    this.style = kDefaultInboxCardStyle,
    this.action,
    this.actionProgress = 0,
    this.reactionVertical = false,
  });

  /// 卡片数据。
  final InboxItem item;

  /// 卡片宽度（由宿主按屏宽算好，见 `inbox_page.dart`）；
  /// 高度 = 宽 × [kInboxCardAspect]（扑克牌比例）。
  final double width;

  /// 版式（设置页可切换；见 [kInboxCardStyles]）。
  final InboxCardStyle style;

  /// 这次拖动 / 飞出落在**哪个动作**上（null = 不显示浮层）。
  ///
  /// 由宿主按「方向 → 行为」的唯一映射算好（见 `inbox_page.dart` 的
  /// `_actionForEdge`）—— 本组件只按这个值决定画哪个词、用什么颜色。
  final InboxSwipeAction? action;

  /// [action] 浮层的渐显进度（0 = 不显示，1 = 完全显示）。
  final double actionProgress;

  /// 这次拖动是不是**竖直主导**的（v2.32.0+ 的上下滑手势）。
  ///
  /// 为 true 时徽标改为**居中**显示、不倾斜：徽标原来贴在左右边缘
  /// （`centerLeft` / `centerRight`），那是给左右滑看的 —— 竖着划的时候
  /// "往哪边划"的信息在竖直方向上，贴着左右边缘反而看不出反馈跟手。
  final bool reactionVertical;

  @override
  Widget build(BuildContext context) {
    final act = action;
    final mark = act == null ? null : _markFor(context, act);
    return SizedBox(
      width: width,
      height: inboxCardHeight(width),
      child: Stack(
        fit: StackFit.expand,
        children: [
          InboxCardStyleView(item: item, style: style, width: width),
          if (mark != null && actionProgress > 0)
            _ReactionMark(
              label: mark.label,
              progress: actionProgress,
              background: mark.background,
              foreground: mark.foreground,
              border: mark.border,
              // 竖直主导 → 徽标居中；水平（含静止）→ 沿用旧的贴边 + 倾斜
              alignment:
                  reactionVertical ? Alignment.center : mark.alignment,
              tilt: reactionVertical ? 0 : mark.tilt,
            ),
        ],
      ),
    );
  }
}

/// 一个动作的浮层徽标外观（文案 / 底色 / 字色 / 描边 / 摆位 / 倾斜）。
///
/// 四个词的观感**互不混淆**（既有护栏见文件头）：
/// | 动作 | 词 | 底 | 字 |
/// |------|----|----|----|
/// | [InboxSwipeAction.like] | 加入 | [AppPalette.inkFill] 实心墨 | [AppPalette.onInk] |
/// | [InboxSwipeAction.skip] | 跳过 | [kInkGray70] 实心灰 | [kPaper] |
/// | [InboxSwipeAction.restore] | 取回 | [AppPalette.accentFill] 实心点缀 | [AppPalette.onAccent] |
/// | [InboxSwipeAction.defer] | 稍后 | [AppPalette.accentWash] 浅底 | [AppPalette.accentDeep] |
///
/// 「稍后」用浅底深字（+ 同色描边）是**刻意的**：它不是一次判定，颜色上也
/// 不该和「加入 / 跳过 / 取回」三个实心"判定"标记混成一家。
class _MarkStyle {
  const _MarkStyle({
    required this.label,
    required this.background,
    required this.foreground,
    required this.alignment,
    required this.tilt,
    this.border,
  });

  final String label;
  final Color background;
  final Color foreground;
  final Alignment alignment;
  final double tilt;
  final Color? border;
}

/// 动作 → 徽标外观（颜色一律走 `context.palette`，见文件头的对比度硬约束）。
_MarkStyle _markFor(BuildContext context, InboxSwipeAction action) {
  final palette = context.palette;
  return switch (action) {
    InboxSwipeAction.like => _MarkStyle(
        label: '加入',
        background: palette.inkFill,
        foreground: palette.onInk,
        alignment: Alignment.centerLeft,
        tilt: -kInboxSwipeMaxTilt,
      ),
    InboxSwipeAction.skip => _MarkStyle(
        label: '跳过',
        background: kInkGray70,
        foreground: kPaper,
        alignment: Alignment.centerRight,
        tilt: kInboxSwipeMaxTilt,
      ),
    InboxSwipeAction.defer => _MarkStyle(
        label: '稍后',
        background: palette.accentWash,
        foreground: palette.accentDeep,
        border: palette.accentDeep,
        alignment: Alignment.center,
        tilt: 0,
      ),
    InboxSwipeAction.restore => _MarkStyle(
        label: '取回',
        background: palette.accentFill,
        foreground: palette.onAccent,
        alignment: Alignment.center,
        tilt: 0,
      ),
  };
}

/// 拖动浮层标记（「加入」/「跳过」/「稍后」/「取回」）：实心底（或浅底）+ 一律
/// 满不透明的文字，渐显靠外层 [Opacity]（见文件头颜色说明）。
class _ReactionMark extends StatelessWidget {
  const _ReactionMark({
    required this.label,
    required this.progress,
    required this.background,
    required this.foreground,
    required this.alignment,
    required this.tilt,
    this.border,
  });

  final String label;
  final double progress;
  final Color background;
  final Color foreground;
  final Alignment alignment;
  final double tilt;

  /// 描边色（null = 不描边）。只有浅底的「稍后」用：浅卡面上光靠浅底看不出块。
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(kSpace16),
        child: Opacity(
          opacity: progress.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: tilt,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace12,
                vertical: kSpace4,
              ),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(kRadiusSm),
                border: border == null
                    ? null
                    : Border.all(color: border!, width: 1),
              ),
              child: Text(
                label,
                style: kTypeTitleS.copyWith(
                  color: foreground,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
