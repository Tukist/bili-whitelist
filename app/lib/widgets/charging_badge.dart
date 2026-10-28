/// 充电专属角标（v2.55.0+）：用户需求「在封面和视频界面标注一下充电视频」。
///
/// 「充电专属 / 充电视频」= B 站需要给 UP 主充电后才能看完整内容的视频，
/// 数据来源是 view 接口的 `data.is_upower_exclusive`（实测字段，见
/// `parseViewCharging`）。
///
/// 样式为什么这么写（不新造一套颜色）：
/// - 外形**照抄** [VideoTile] 里已有的状态角标（「已缓存」/「共 N 集」）：
///   `Container` + 横向 5 / 纵向 2 内边距 + 3px 圆角 + 10px 字；
/// - 颜色走配色系统的**点缀墨角标底**：[AppPalette.accentWash] 作底 +
///   [AppPalette.accentDeep] 作字——这一对就是 design token 里为「角标」准备
///   的（见 app_palette.dart 的字段注释），10 套配色配方下都自动跟随，
///   且对比度由派生公式保证（≥ 4.5:1）。既有的两个角标是中性墨底（状态
///   语义），充电是「需要付费/受限」的提示，用点缀墨区分开、又不自创色值。
///
/// 尺寸只有一个可调项 [fontSize]（内边距按它等比算，保持 10px 时与既有
/// 角标**逐像素一致**）：列表封面用 10，播放页信息块用 11（略大一点但不抢
/// 标题）。
library;

import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// 列表封面上的角标文案（短，72×45 的封面上放得下）。
const String kChargingCoverBadgeLabel = '充电专属';

/// 播放页信息块里的标签文案（完整说法）。
const String kChargingInfoLabel = '充电专属视频';

/// 播放页信息块里标签右侧的一句短说明（讲清楚「为什么看不了」）。
const String kChargingInfoHint = '需给 UP 主充电后观看完整内容';

/// 充电专属角标：小胶囊（点缀墨 15% 稀释底 + 加深点缀墨文字）。
class ChargingBadge extends StatelessWidget {
  /// 文案（列表封面 = [kChargingCoverBadgeLabel]，播放页 = [kChargingInfoLabel]）。
  final String label;

  /// 字号；内边距按 `horizontal: fontSize/2, vertical: 2` 等比跟随，
  /// 默认 10 → 5/2（与 [VideoTile] 既有角标同一份几何）。
  final double fontSize;

  const ChargingBadge({
    super.key,
    this.label = kChargingCoverBadgeLabel,
    this.fontSize = 10,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize / 2, vertical: 2),
      decoration: BoxDecoration(
        color: palette.accentWash,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: palette.accentDeep,
          fontSize: fontSize,
          // 角标不换行：文案短，但窄封面（72dp）上留一手，免得在小字号
          // 缩放/大字体设置下把角标撑出封面
          height: 1.2,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
