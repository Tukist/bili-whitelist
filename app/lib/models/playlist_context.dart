import 'whitelist_video.dart';

/// 播放上下文：**当前播放页所属的那个有序视频列表**（同合集 / 同 UP 主页），
/// 供播放页的「上一集 / 下一集」（`PlayerPage.playlist`）使用。
///
/// 为什么是「只读快照」而不是播放队列：
/// - 顺序的唯一真相在**列表页**（合集页 [WhitelistData.sortedVideos] 的
///   「order 升序 + addedAt 倒序兜底」、UP 主页的 pubdate 序）——用户在列表
///   里看到的顺序，就是点进播放页后「下一集」的顺序，两处不会打架；播放页
///   只做「下标 ± 1」，不重排、不重新请求列表；
/// - 不引入增删 / shuffle / 循环播放：本需求只是「同合集上下集」，一个下标
///   就够；可变播放队列会带来状态同步与持久化问题，收益为零。
///
/// 本类只读、不带状态、不碰 IO（cid 补齐等由播放页自己处理）。
class PlaylistContext {
  /// 有序视频列表（下标即「第 N 集」，0 起）。
  final List<WhitelistVideo> videos;

  /// 上下文名（合集名 / UP 主名），用于「第 N/M 集」旁的来源提示；
  /// null 或空串 = 不显示。
  final String? label;

  const PlaylistContext({required this.videos, this.label});

  int get length => videos.length;

  bool get isEmpty => videos.isEmpty;
}
