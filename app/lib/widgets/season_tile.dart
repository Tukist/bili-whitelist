/// 合集页的「整季卡」（v2.41.0+）：把同一部番的 N 集折成**一张卡**。
///
/// 用户原话（v2.37.0 那批只修了"上下集乱跳"，这一半一直欠着）：
/// 「不要让收藏一个剧或者番的时候需要把每集都收藏。现在比如说在アニメ合集
/// 里面一个 43 集的高达…」——43 集逐集平铺，收藏一部番等于收藏 43 条。
///
/// 本组件只负责**画**一张卡；**哪些集属于同一季、什么时候折**全在合集页
/// （collection_page 的 `buildCollectionListRows`）里算。
///
/// 形态与 [VideoTile] 刻意保持同一套块化语言（[ListTile] + [CoverHero] +
/// 圆角描边 + 同样的内边距），差别只有三处：
/// - 封面角标从「共 N 集」换成 **「整季」**（告诉用户这是一张**折叠卡**，
///   而不是一条名字叫"XX 第一季"的视频）；
/// - 副信息行 = **`N 集 · 已看 X/N`**（复用 collection_stats 的口径）；
/// - 尾部给一个 `unfold_more` 图标（提示"点开还能选集"），多选模式下换成
///   勾选框（与 [VideoTile] 一致）。
///
/// 封面取**该季第一集**的（正序第一集 = 第 1 话），标题取**季名**；但这块
/// 封面**不参与 Hero 飞行**（[CoverHero] 的 tag 传 null）——理由见 build 里
/// 那段注释（展开态季头与「第 1 话」同屏，两个同 tag 的 Hero 会直接抛）。
///
/// 点卡片 → 宿主弹「选集」层；长按 → 进入多选并**整体选中这一季**（见
/// collection_page 的说明）。本组件不含任何手势逻辑（左滑由宿主的
/// [SwipeActionBox] 包在外面），只把回调交出去。
library;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'cover_hero.dart';
import 'cover_image.dart';

/// 一张「整季卡」。
class SeasonTile extends StatelessWidget {
  /// 季名（如 `是，大臣 第一季`）——就是折叠前每集标题里 `第N话` 之前那段。
  final String seasonName;

  /// 该季的集数（= 折叠进去的视频条数）。
  final int episodeCount;

  /// 其中**已看**的集数（口径见 [watchedVideoCount]；0 ≤ watched ≤ episodeCount）。
  final int watchedCount;

  /// 封面（取该季第一集的封面；空串 → [CoverImage] 的占位）。
  final String cover;

  final bool selectMode;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const SeasonTile({
    super.key,
    required this.seasonName,
    required this.episodeCount,
    required this.watchedCount,
    this.cover = '',
    this.selectMode = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
  });

  /// 副信息行文案：`N 集 · 已看 X/N`。
  ///
  /// 抽成静态纯函数（与 [fmtVideoSubtitle] 同一条理由）：这行是测试的
  /// **逐字符**锚点，直接断言比 pump 一棵树便宜得多。
  static String subtitleOf(int episodeCount, int watchedCount) {
    // 越界防御：调用方算错也不显示「已看 5/3」这种读不通的文案
    final watched = watchedCount.clamp(0, episodeCount);
    return '$episodeCount 集 · 已看 $watched/$episodeCount';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ⚠️ 整季卡的封面**刻意不参与 Hero 飞行**（`CoverHero(tag: null)` → 一个
    // Hero 节点都不建）：
    // - 点它不是进播放页（是选集弹层），Hero 本来就没有飞行终点；
    // - 更要紧的是**展开态**：季头与「第 1 话」同屏，两者封面是同一张图、
    //   若都用 `coverHeroTag(第1话的 bvid)` 就会在同一个 PageRoute 子树里出现
    //   两个同 tag 的 Hero → 框架直接抛 "multiple heroes that share the same
    //   tag"（真机上就是整页红屏）。
    final coverBox = CoverHero(
      tag: null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kRadiusSm),
        child: Stack(
          children: [
            CoverImage(cover: cover),
            // 「整季」角标（封面左上角，位置与 VideoTile 的「已缓存」角标一致）：
            // 折叠卡与逐集卡外形几乎一样，不给个标记用户会以为这是"第 0 集"
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: kInkBlack.withValues(alpha: .88),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text(
                  '整季',
                  style: TextStyle(color: kPaper, fontSize: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    // 多选模式下整块关掉 Hero（与 [VideoTile] 同一条：多选/拖拽期间条目会进
    // overlay，Hero 还配对会飞出"残影封面"）。本卡本来就没有 Hero 节点，
    // 这一层是照抄 VideoTile 的结构，保证两种卡在树里的层级一致。
    return HeroMode(
      enabled: !selectMode,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        // 与 VideoTile **同一套外形**（圆角描边 + 纸底 + 同样的内边距）：
        // 折叠卡与逐集卡在列表里是邻居，外形一旦不同就会显得"少了点什么"
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
          side: const BorderSide(color: kRuleStrong),
        ),
        tileColor: kPaper,
        contentPadding:
            const EdgeInsets.fromLTRB(kSpace8, kSpace4, kSpace8, kSpace4),
        leading: selectMode
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onTap?.call(),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  coverBox,
                ],
              )
            : coverBox,
        title: Text(
          seasonName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          // 与 VideoTile 的标题同一档语汇（14/w500），不用 ExpandableText：
          // 季名通常比集标题短，多一个展开入口反而多一棵子树
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          subtitleOf(episodeCount, watchedCount),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: selectMode
            ? null
            : Icon(
                Icons.unfold_more,
                size: 20,
                color: theme.colorScheme.outline,
              ),
      ),
    );
  }
}
