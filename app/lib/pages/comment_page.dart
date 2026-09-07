/// 独立评论区页面（v2.17.0+ 改为薄壳：列表/数据/条目逻辑统一在
/// [CommentListView]（widgets/comment_list.dart），播放页竖屏内嵌与本站共用
/// 一份实现，避免维护两份）。
///
/// 本页职责仅剩：Scaffold + AppBar「评论 N」标题，正文交给
/// [CommentListView]（置顶/分页/楼中楼/图片放大保存/链接跳转见其文档）。
///
/// 评论内视频链接（防双音轨）：
/// - 播放页打开本站（传 [CommentPage.onOpenVideoPreview]）→ 点视频链接
///   回调播放页当前实例换源（停旧播新）后 pop 回播放页；
/// - 本站独立打开（无回调）→ 兜底 push 新 PlayerPage 预览（旧行为）。
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

  /// 可选：评论内视频链接的回调（v2.16.23+）。
  ///
  /// 由播放页传入（评论页叠在播放页上打开时）：点视频链接 → 回调把链接
  /// 视频交给播放页**当前实例换源**（停旧播新）后 pop 本页回播放页观看，
  /// 避免旧实现 push 第二个 PlayerPage 造成双音轨。
  /// 为 null（评论页从其他入口独立打开）→ 保持旧行为 push 新 PlayerPage
  /// 预览播放。
  final void Function(WhitelistVideo video)? onOpenVideoPreview;

  const CommentPage({
    super.key,
    required this.video,
    this.initialAid,
    this.onOpenVideoPreview,
  });

  @override
  State<CommentPage> createState() => _CommentPageState();
}

class _CommentPageState extends State<CommentPage> {
  /// 评论总数（标题「评论 N」用；由列表 onCountChanged 回报）。
  int _total = 0;

  /// 视频链接回调包装：宿主换源后 pop 本页回播放页（旧行为；列表本身
  /// 不 pop，内嵌场景无 pop）。
  void _onOpenVideo(WhitelistVideo video) {
    final onOpen = widget.onOpenVideoPreview;
    if (onOpen == null) return;
    onOpen(video);
    if (mounted) Navigator.of(context).pop();
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
        onOpenVideo: widget.onOpenVideoPreview == null ? null : _onOpenVideo,
        showCountHeader: false, // AppBar 已有「评论 N」标题，列表内不重复
        onCountChanged: (n) {
          if (mounted && n != _total) setState(() => _total = n);
        },
      ),
    );
  }
}
