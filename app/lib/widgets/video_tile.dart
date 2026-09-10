/// 共享视频列表项组件：封面 + 标题 + 时长 + UP 主 + 发布时间 +
/// 已缓存/多 P 角标（发布时间仅 pubdate 非空时展示，见 formatPubdate）。
///
/// 从 playlist_page 原私有 `_VideoTile` 抽出，首页合集视频列表页
/// （collection_page）复用同一实现，避免两份样式漂移。
library;

import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../theme/app_tokens.dart';
import 'cover_hero.dart';
import 'cover_image.dart';

/// 时长格式化：秒 → `12:34` / `1:02:03`（与 M1 脚本 fmt_duration 一致）。
String fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 单条视频：封面 + 标题 + 时长 + UP 主 + 发布时间 + 已缓存角标。
///
/// 副信息行 = `时长 · UP主 · 发布时间`（发布时间 v2.16.16+ 导入的数据才有；
/// 旧数据无 pubdate 时不显示该段，展示与旧版一致）。
/// 普通模式：点按进播放页、尾部「更多」弹管理菜单、长按进入多选模式；
/// 多选模式：左侧勾选框 + 点按/长按切换勾选。
/// 尾部可挂拖拽把手（[dragHandle]，页面用 ReorderableDragStartListener 包
/// 图标传入）：按住把手立即拖动排序，与整行长按（进入多选）互不干扰。
///
/// 块化（P0 批次 B）：外形参数直接给 [ListTile] 自己 —— **不换容器类型**，
/// 页面测试里的 `find.byType(VideoTile)` / `find.byType(ListTile)` 断言照旧
/// 命中；封面外层包 [CoverHero]（播放页封面为飞行终点，tag 由 [coverHeroTag]
/// 按 bvid 生成，空 bvid → 不产生 Hero 节点）。
class VideoTile extends StatelessWidget {
  final WhitelistVideo video;
  final int cachedCount; // 该视频已缓存的集数（0 = 未缓存）
  final bool selectMode;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onMore; // 普通模式尾部「更多」按钮（管理菜单）
  final Widget? dragHandle; // 普通模式尾部拖拽把手（多选模式不显示）

  const VideoTile({
    super.key,
    required this.video,
    this.cachedCount = 0,
    this.selectMode = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onMore,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 发布时间文本：pubdate 缺失/脏值 → 空串（不显示、不破坏旧布局）
    final pubdateText = formatPubdate(video.pubdate);
    final cover = CoverHero(
      tag: coverHeroTag(video.bvid),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kRadiusSm),
        child: Stack(
          children: [
            CoverImage(cover: video.cover),
            // 已缓存角标（封面左上角，与右下角「共 N 集」角标风格一致）：
            // 多 P 部分缓存显示 `已缓存 n/m`，全部/单 P 显示 `已缓存`
            if (cachedCount > 0)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    // 已缓存 = 状态角标：中性墨底 + 纸白字（不再是绿色）
                    color: kInkBlack.withValues(alpha: .88),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    video.isMultiPage && cachedCount < video.pageCount
                        ? '已缓存 $cachedCount/${video.pageCount}'
                        : '已缓存',
                    style: const TextStyle(color: kPaper, fontSize: 10),
                  ),
                ),
              ),
            // 多 P 视频：封面右下角「共 N 集」角标（单 P 不显示）
            if (video.isMultiPage)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: kInkBlack.withValues(alpha: .72),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '共 ${video.pageCount} 集',
                    style: const TextStyle(color: kPaper, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    // 多选模式下整块关掉 Hero：多选/拖拽期间条目会进 overlay，Hero 若还在
    // 配对会飞出「残影封面」（见 cover_hero.dart 的说明）。
    return HeroMode(
      enabled: !selectMode,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        // 卡片外形交给 ListTile 自己画（shape + tileColor），块化只加外形、
        // 不动容器类型与结构；内边距按既有 8/4 收紧，两行 tile 高度 ≥ 72dp，
        // 触摸目标达标。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
          side: const BorderSide(color: kRuleStrong),
        ),
        tileColor: kPaper,
        contentPadding: const EdgeInsets.fromLTRB(
            kSpace8, kSpace4, kSpace8, kSpace4),
        leading: selectMode
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onTap?.call(),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  cover,
                ],
              )
            : cover,
        title: Text(
          video.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          // 副信息行：时长 · UP主（· 发布时间；日期为空时与旧版逐字符一致）
          pubdateText.isEmpty
              ? '${fmtDuration(video.duration)} · ${video.upName}'
              : '${fmtDuration(video.duration)} · ${video.upName} · $pubdateText',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        // 尾部：拖拽把手（拖动画排序）+「更多」按钮（管理菜单）；多选模式不显示
        trailing: !selectMode
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dragHandle != null) dragHandle!,
                  if (onMore != null)
                    IconButton(
                      tooltip: '管理',
                      icon: const Icon(Icons.more_vert),
                      onPressed: onMore,
                    ),
                ],
              )
            : null,
      ),
    );
  }
}
