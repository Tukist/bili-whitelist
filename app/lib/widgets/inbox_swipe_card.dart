/// 信箱卡片（Tinder 式左右滑动的「一张」）：封面大图 + 标题 + UP 主 + 元信息，
/// 外加两个随手势渐显的浮层标记「加入」/「跳过」。
///
/// 只负责**画**，不碰手势与动画：位移、旋转、飞出/弹回都在 `inbox_page.dart`
/// 里控制（卡片跟手是「位移 + 轻微旋转」，旋转角与水平位移成正比）。
///
/// ## 排版（自上而下）
/// `封面 16:9（kRadiusMd 圆角 + 1px 描边，ClipRRect）` → `标题（≤2 行）` →
/// `UP 头像 + 名字` → `时长 · 发布时间`。卡片整体：`kPaper` 底 +
/// 1px [kRuleStrong] 描边 + [kRadiusMd]，**无阴影**（本设计语言不用阴影）。
///
/// ## 颜色（硬约束）
/// - 实心浮层底只用**已过对比度护栏**的档位：加入 = [AppPalette.inkFill]
///   （+ [AppPalette.onInk] 文字，≥ 4.5:1）；跳过 = [kInkGray70]（+ 纸白文字，
///   实测 ≈ 6.2:1）。不用原墨 [AppPalette.ink] 当实心底（浅墨配方下达不到）。
/// - 渐显用 [Opacity] 包**满不透明**的浮层，而不是给底色乘 alpha：前者满显时
///   对比度仍是护栏值，后者会把对比度一起稀释掉。
/// - 正文/元信息一律用 [kInkGray70]（纸底 ≥ 4.5:1），不用更浅的 kInkGray50。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/inbox_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../utils/relative_time.dart';
import 'cover_image.dart';
import 'video_tile.dart' show fmtDuration;

/// 判定「这一张算数」的水平位移比例（相对屏宽）：超过 30% 即提交。
const double kInboxSwipeThresholdRatio = 0.30;

/// 判定「甩出去」的速度阈值（px/s）：位移不够但甩得够快也算提交。
const double kInboxSwipeVelocity = 700;

/// 拖动时的最大旋转角（±12°，弧度）：旋转角 = 水平位移 / 屏宽 × 该值。
final double kInboxSwipeMaxTilt = 12 * math.pi / 180;

/// 信箱卡片内容区（不含封面）的大致高度：标题 2 行 + 头像行 + 元信息行 + 内边距。
const double kInboxCardInfoH = 132;

/// 下层卡片露出的一角：它的**底边**落在顶层卡片底边之下这么多 dp。
///
/// 宿主（`inbox_page.dart`）用 `Positioned(bottom: -kInboxStackOffset)` 做
/// 「底边对齐」，缩放锚点取 `bottomCenter`（底边不因缩放上收）→ 净露出量恒为
/// 该值，与两张卡片各自的内容高度（标题 1 行 / 2 行）无关。
const double kInboxStackOffset = 12;

/// 下层卡片的缩放比例（以**底边**为锚点，底边位置不变）。
const double kInboxStackScale = 0.96;

/// 信箱卡片（纯展示）。
class InboxSwipeCard extends StatelessWidget {
  const InboxSwipeCard({
    super.key,
    required this.item,
    required this.width,
    required this.coverHeight,
    this.likeProgress = 0,
    this.skipProgress = 0,
    this.child,
  });

  /// 卡片数据。
  final InboxItem item;

  /// 卡片宽度（由宿主按屏宽算好，见 `inbox_page.dart`）。
  final double width;

  /// 封面高度（16:9 或按可用高度压扁后的值）。
  final double coverHeight;

  /// 「加入」浮层渐显进度（0 = 不显示，1 = 完全显示）。
  final double likeProgress;

  /// 「跳过」浮层渐显进度。
  final double skipProgress;

  /// 需要叠在封面上的内容（如宿主想自己放浮层）；一般不用。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final cover = CoverImage(
      cover: item.cover,
      width: width,
      height: coverHeight,
    );
    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          color: kPaper,
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(color: kRuleStrong, width: 1),
        ),
        // 封面是矩形，卡片是圆角 → 必须裁切，否则封面四角会戳出圆角外
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面固定高度（宽度由 SizedBox 撑满卡片）→ 用 SizedBox 定高，
            // CoverImage 的占位/加载态也就能填满同一块区域
            SizedBox(
              width: width,
              height: coverHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover,
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
            ),
            Padding(
              padding: const EdgeInsets.all(kCardPad),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isEmpty ? item.bvid : item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: kTypeTitleM.copyWith(color: kInkBlack),
                  ),
                  const SizedBox(height: kSpace8),
                  _upownerRow(),
                  const SizedBox(height: kSpace8),
                  _metaRow(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// UP 主行：圆形头像 + 名字（名字过长省略）。
  Widget _upownerRow() {
    return Row(
      children: [
        _Face(face: item.upFace),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Text(
            item.upName.isEmpty ? '未知 UP 主' : item.upName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: kTypeBodyS.copyWith(color: kInkGray70),
          ),
        ),
      ],
    );
  }

  /// 元信息行：时长（等宽数字）+ 发布时间（相对时间）。
  Widget _metaRow() {
    final pub = _pubDateText();
    return Row(
      children: [
        Icon(Icons.schedule, size: 14, color: kInkGray70),
        const SizedBox(width: kSpace4),
        Text(
          item.duration > 0 ? fmtDuration(item.duration) : '--:--',
          style: kTypeNum.copyWith(color: kInkGray70),
        ),
        if (pub.isNotEmpty) ...[
          const SizedBox(width: kSpace12),
          Icon(Icons.access_time, size: 14, color: kInkGray70),
          const SizedBox(width: kSpace4),
          Expanded(
            child: Text(
              pub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ),
        ],
      ],
    );
  }

  /// 发布时间 → 相对时间文案；pubDate ≤ 0（脏数据）→ 空串（不显示这一段）。
  String _pubDateText() {
    if (item.pubDate <= 0) return '';
    return fmtRelativeTime(
      DateTime.fromMillisecondsSinceEpoch(item.pubDate * 1000),
    );
  }
}

/// UP 主圆形头像：空 face / 加载失败 → 人形占位（不用封面的电影图标占位）。
class _Face extends StatelessWidget {
  const _Face({required this.face});

  final String face;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: 20,
      height: 20,
      color: kPaperCool,
      child: const Icon(Icons.person, size: 13, color: kInkGray70),
    );
    return ClipOval(
      child: SizedBox(
        width: 20,
        height: 20,
        child: face.isEmpty
            ? placeholder
            : Image.network(
                face,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
              ),
      ),
    );
  }
}

/// 拖动浮层标记（「加入」/「跳过」）：实心底 + 描边 + 一律满不透明的文字，
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
