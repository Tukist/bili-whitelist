/// 独立评论区页面（v2.17.0+ 改为薄壳：列表/数据/条目逻辑统一在
/// [CommentListView]（widgets/comment_list.dart），播放页竖屏内嵌与本站共用
/// 一份实现，避免维护两份）。
///
/// 本页职责仅剩：Scaffold + AppBar「评论 N」标题，正文交给
/// [CommentListView]（置顶/分页/楼中楼/图片放大保存/链接跳转见其文档）。
///
/// 评论内视频链接（v2.17.1+ 跳转语义，阶段 B）：
/// - 播放页打开本站（传 [CommentPage.onNavigateToVideo]）→ 点视频链接时
///   先 pop 本站回播放页（薄壳在栈中移出，让播放页重新成为顶层），再回调
///   播放页 push 新播放页——新播放页叠上时旧页经 RouteAware（路由名
///   'player'）自动暂停防双音轨，返回后旧页恢复续播；
/// - 无回调（本站独立打开，当前无任何入口会这样——只有播放页会 push 本站）
///   → CommentListView 兜底直接 push 新 PlayerPage（说明：若真有宿主播放页
///   在下方且未传回调，兜底叠页不会触发旧页暂停，仍有双音轨隐患；取舍：
///   本站入口唯一且必传回调，兜底仅供防御/未来独立入口）。
///
/// 只读：本页不做任何点赞/发评论等写操作。aid 解析失败 / 首屏失败均给
/// 重试入口。
library;

import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../widgets/comment_list.dart';

class CommentPage extends StatefulWidget {
  final WhitelistVideo video;

  /// 可选：外部已解析好的 aid（如播放页已有 view 数据），省一次请求。
  final int? initialAid;

  /// 可选：评论内视频链接的回调（v2.16.23+ 换源回调 → v2.17.1+ 改为跳转
  /// 回调 [CommentPage.onNavigateToVideo]）。
  ///
  /// 由播放页传入（评论页叠在播放页上打开时）：点视频链接 → **先 pop 本站
  /// 回播放页**，再回调播放页 push 新播放页（播放页 RouteAware 自动暂停旧
  /// 页防双音轨，返回后续播；语义见 player_page._openVideoInNewPlayer）。
  /// 为 null（评论页从其他入口独立打开，当前无此场景）→ CommentListView
  /// 兜底 push 新 PlayerPage 预览播放。
  final void Function(WhitelistVideo video)? onNavigateToVideo;

  const CommentPage({
    super.key,
    required this.video,
    this.initialAid,
    this.onNavigateToVideo,
  });

  @override
  State<CommentPage> createState() => _CommentPageState();
}

class _CommentPageState extends State<CommentPage> {
  /// 评论总数（标题「评论 N」用；由列表 onCountChanged 回报）。
  int _total = 0;

  /// 视频链接跳转包装（v2.17.1+ 语义）：
  /// 1. 先 pop 本站（薄壳移出栈 → 下方播放页 P 重新成为顶层）；
  /// 2. 再回调宿主 P「push 新播放页」——P2 叠上时 P 经 didPushNext 自动
  ///    暂停并记进度（无双音轨）；P2 返回 → P didPopNext 恢复续播。
  /// 顺序不能反：若先 push P2 再 pop 本站，P 不会收到 didPushNext（P2 叠在
  /// C 上而非 P 上），且本站 pop 会让 P 误触发 didPopNext → P 未停即出声。
  void _onOpenVideo(WhitelistVideo video) {
    final onNav = widget.onNavigateToVideo;
    if (onNav == null) return;
    debugPrint('[comment_page] 评论链接 bvid=${video.bvid} → '
        '先关本页，再交由播放页 push 新播放页');
    if (mounted) Navigator.of(context).pop();
    onNav(video);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? '评论 $_total' : '评论'),
        centerTitle: false,
      ),
      body: CommentListView(
        video: widget.video,
        initialAid: widget.initialAid,
        // 有宿主回调才包装（无回调 → 列表兜底 push 新 PlayerPage）
        onOpenVideo: widget.onNavigateToVideo == null ? null : _onOpenVideo,
        showCountHeader: false, // AppBar 已有「评论 N」标题，列表内不重复
        onCountChanged: (n) {
          if (mounted && n != _total) setState(() => _total = n);
        },
      ),
    );
  }
}
