/// 信箱卡片（Tinder 式左右滑动的「一张」）的**外壳**：
/// 定尺寸（扑克牌比例）→ 交给版式渲染（见 `inbox_card_styles.dart`）→
/// 在上面叠两个随手势渐显的浮层标记「加入」/「跳过」。
///
/// 只负责**画**，不碰手势与动画：位移、旋转、飞出/弹回都在 `inbox_page.dart`
/// 里控制（卡片跟手是「位移 + 轻微旋转」，旋转角与水平位移成正比）。
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
///   实测 ≈ 6.2:1）。不用原墨 [AppPalette.ink] 当实心底（浅墨配方下达不到）。
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

/// 信箱卡片（纯展示）：定尺寸 + 版式内容 + 手势浮层。
class InboxSwipeCard extends StatelessWidget {
  const InboxSwipeCard({
    super.key,
    required this.item,
    required this.width,
    this.style = kDefaultInboxCardStyle,
    this.likeProgress = 0,
    this.skipProgress = 0,
  });

  /// 卡片数据。
  final InboxItem item;

  /// 卡片宽度（由宿主按屏宽算好，见 `inbox_page.dart`）；
  /// 高度 = 宽 × [kInboxCardAspect]（扑克牌比例）。
  final double width;

  /// 版式（设置页可切换；见 [kInboxCardStyles]）。
  final InboxCardStyle style;

  /// 「加入」浮层渐显进度（0 = 不显示，1 = 完全显示）。
  final double likeProgress;

  /// 「跳过」浮层渐显进度。
  final double skipProgress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: inboxCardHeight(width),
      child: Stack(
        fit: StackFit.expand,
        children: [
          InboxCardStyleView(item: item, style: style, width: width),
          if (likeProgress > 0)
            _ReactionMark(
              label: '加入',
              progress: likeProgress,
              background: context.palette.inkFill,
              foreground: context.palette.onInk,
              alignment: Alignment.centerLeft,
              tilt: -kInboxSwipeMaxTilt,
            ),
          if (skipProgress > 0)
            _ReactionMark(
              label: '跳过',
              progress: skipProgress,
              background: kInkGray70,
              foreground: kPaper,
              alignment: Alignment.centerRight,
              tilt: kInboxSwipeMaxTilt,
            ),
        ],
      ),
    );
  }
}

/// 拖动浮层标记（「加入」/「跳过」）：实心底 + 一律满不透明的文字，
/// 渐显靠外层 [Opacity]（见文件头颜色说明）。
class _ReactionMark extends StatelessWidget {
  const _ReactionMark({
    required this.label,
    required this.progress,
    required this.background,
    required this.foreground,
    required this.alignment,
    required this.tilt,
  });

  final String label;
  final double progress;
  final Color background;
  final Color foreground;
  final Alignment alignment;
  final double tilt;

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
