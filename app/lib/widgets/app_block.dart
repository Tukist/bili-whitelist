/// 「块」——块化改造的统一外形。
///
/// 层级只用四样东西表达：**底材差 + 描边重量 + 左侧竖条 + 圆角**。
/// **不用阴影**（老 Android 上阴影会糊成灰边，与「纸 + 墨」的印刷质感相冲）。
///
/// 设计红线（改这里之前先读一遍）：
/// - **不换容器类型**：块化只是给既有 widget 加一层 `decoration`，绝不把
///   `ListTile` 换自绘 `Row`、不把单个 `Text` 拆成多个 —— 那会打断
///   页面测试里的 `find.text` / `find.byType` 断言锚点；
/// - **不新增圆角值**：只用 [kRadiusSm] / [kRadiusMd]；
/// - **颜色不写字面量**：一律走 `context.palette.*`（见 [appBlockSpec]）或
///   [app_tokens.dart] 的底材/描边常量。
library;

import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';

/// 块的语义场景。规格表见 [appBlockSpec]。
enum AppBlockVariant {
  /// 播放页视频信息块（带短竖条「起笔」）
  videoInfo,

  /// 评论主体
  comment,

  /// 楼中楼回复（冷底 + 全高竖条，表达「挂靠在某条评论下」）
  reply,

  /// 列表视频卡（内边距交给宿主 ListTile）
  videoCard,

  /// 合集 / 分区卡
  collectionCard,

  /// 设置项
  setting,
}

/// 一个块的全部外形参数。
///
/// 规格表是**唯一真相源**（[appBlockSpec]），页面不要自己拼 [AppBlockSpec]；
/// 只有「这一处确实需要微调」时才用 [AppBlock.specOverride] 覆盖一次，
/// 不要为一次性需求新增 [AppBlockVariant]。
@immutable
class AppBlockSpec {
  /// 底材色（[kPaper] / [kPaperCool] / [kPaperWarm]，不透明）
  final Color background;

  /// 四边描边色；null = 不画四边描边（层级改用竖条/底材表达）
  final Color? stroke;

  /// 描边宽度（统一 1px）
  final double strokeWidth;

  /// 圆角（只用 [kRadiusMd] = 8 / [kRadiusSm] = 4）
  final double radius;

  /// 内边距
  final EdgeInsetsGeometry padding;

  /// 左侧竖条色；null = 无竖条
  final Color? leftRule;

  /// 左侧竖条宽（2 = 全高细条 / 3 = 短条）
  final double leftRuleWidth;

  /// 左侧竖条高；null = 全高（贴齐上下边），非 null = 短条
  final double? leftRuleHeight;

  /// 短条距顶距离（[leftRuleHeight] 为 null 时忽略）
  final double leftRuleTop;

  const AppBlockSpec({
    required this.background,
    this.stroke,
    this.strokeWidth = 1,
    this.radius = kRadiusMd,
    required this.padding,
    this.leftRule,
    this.leftRuleWidth = 2,
    this.leftRuleHeight,
    this.leftRuleTop = 0,
  });
}

/// variant → 规格（**唯一的规格真相源**：换配色时竖条色自动跟随
/// `palette.inkDeco`，页面不用改一行）。
///
/// 竖条一律取 [AppPalette.inkDeco]（图形/非文字档，与纸底 ≥ 3:1）：
/// 极浅配方下它会自动压深，不会出现"看不见的竖条"。
AppBlockSpec appBlockSpec(BuildContext context, AppBlockVariant v) {
  final inkDeco = context.palette.inkDeco;
  switch (v) {
    // 播放页信息块：最强的框（它下面压着视频播放器），短竖条当「起笔」，
    // 不是挂靠级别的表达，所以用短条而不是通栏。
    case AppBlockVariant.videoInfo:
      return AppBlockSpec(
        background: kPaper,
        stroke: kRuleStrong,
        strokeWidth: 1,
        radius: kRadiusMd,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        leftRule: inkDeco,
        leftRuleWidth: 3,
        leftRuleHeight: 18,
        leftRuleTop: 10,
      );
    // 评论主体：hairline 框（评论是一大片同级的重复项，框太重会吵）。
    case AppBlockVariant.comment:
      return AppBlockSpec(
        background: kPaper,
        stroke: kRule,
        strokeWidth: 1,
        radius: kRadiusMd,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      );
    // 楼中楼：冷底 + 全高竖条 = 「我是上面那条的延续」，不需要四边框。
    case AppBlockVariant.reply:
      return AppBlockSpec(
        background: kPaperCool,
        radius: kRadiusSm,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        leftRule: inkDeco,
        leftRuleWidth: 2,
      );
    // 列表视频卡：内边距交给宿主 ListTile 自己管（它有一套 16/8 的间距体系），
    // 块只画外形，避免双层 padding 叠加后卡片变胖。
    case AppBlockVariant.videoCard:
      return AppBlockSpec(
        background: kPaper,
        stroke: kRuleStrong,
        strokeWidth: 1,
        radius: kRadiusMd,
        padding: EdgeInsets.zero,
      );
    // 合集 / 分区卡：冷底与内容卡拉开底材差，一眼看出是"另一个东西"。
    case AppBlockVariant.collectionCard:
      return AppBlockSpec(
        background: kPaperCool,
        stroke: kRuleStrong,
        strokeWidth: 1,
        radius: kRadiusMd,
        padding: const EdgeInsets.all(10),
      );
    // 设置项：横向内边距更大（16），与列表页 [kPagePadH] 对齐。
    case AppBlockVariant.setting:
      return AppBlockSpec(
        background: kPaper,
        stroke: kRuleStrong,
        strokeWidth: 1,
        radius: kRadiusMd,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      );
  }
}

/// 给 [child] 套一个「块」外形。
///
/// ```dart
/// AppBlock(
///   variant: AppBlockVariant.comment,
///   margin: const EdgeInsets.only(bottom: kListGap),
///   child: CommentRow(...), // 宿主结构原样保留
/// )
/// ```
class AppBlock extends StatelessWidget {
  const AppBlock({
    super.key,
    required this.variant,
    required this.child,
    this.specOverride,
    this.margin = EdgeInsets.zero,
  });

  final AppBlockVariant variant;

  /// 宿主内容：**原样**塞进来，不做任何包装/改写
  final Widget child;

  /// 一次性微调（不新增 variant）。为 null 时用 [appBlockSpec] 的标准规格。
  final AppBlockSpec? specOverride;

  /// 块外边距（列表间距等由调用方给，块自身不猜）
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final s = specOverride ?? appBlockSpec(context, variant);
    final hasRule = s.leftRule != null;
    return Container(
      margin: margin,
      // 有竖条时必须裁圆角：竖条是贴在左边缘的矩形，不裁就会从圆角处
      // 露出一个直角。没竖条时不开裁剪（省一次 layer，也不影响命中）。
      clipBehavior: hasRule ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: s.background,
        borderRadius: BorderRadius.circular(s.radius),
        border: s.stroke == null
            ? null
            : Border.all(color: s.stroke!, width: s.strokeWidth),
      ),
      child: !hasRule
          ? Padding(padding: s.padding, child: child)
          : Stack(
              children: [
                Padding(padding: s.padding, child: child),
                // ⚠️ 竖条必须用 Stack + Positioned，不能写成 `Border(left:)`：
                // BoxDecoration 在 border **非均匀**时（只有 left）与
                // borderRadius 互斥，Border.paint 会直接 assert
                // "A borderRadius can only be given for a uniform Border"。
                // 想要「圆角 + 单边竖条」只有这一条路。
                Positioned(
                  left: 0,
                  top: s.leftRuleHeight == null ? 0 : s.leftRuleTop,
                  bottom: s.leftRuleHeight == null ? 0 : null,
                  child: Container(
                    width: s.leftRuleWidth,
                    height: s.leftRuleHeight,
                    decoration: BoxDecoration(
                      color: s.leftRule,
                      // 只有右侧小圆角：贴住左边缘的那一侧必须是直角
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(1.5),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
