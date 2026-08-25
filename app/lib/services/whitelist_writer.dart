/// 白名单写入服务：把「构造视频 + 查重 + 写 Gist + 写本地缓存」抽成共用逻辑，
/// 导入（playlist_page._importVideo）与搜索页「加入」共用同一份实现，避免重复。
library;

import 'package:dio/dio.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/whitelist_video.dart';
import '../services/service_locator.dart';

/// 「加入白名单」一次操作的结果。
///
/// - [added]=true：成功新增，[data] 为新增后的完整白名单，[video] 为新增视频
/// - [added]=false：重复（已在白名单）或保存失败，[message] 可直接展示，
///   [data] 为拉取到的当前白名单（可能为 null）
class AddResult {
  final bool added;
  final WhitelistVideo? video;
  final WhitelistData? data;
  final String message;

  const AddResult({
    required this.added,
    this.video,
    this.data,
    required this.message,
  });
}

/// 白名单写入服务。
///
/// 异常契约：
/// - [addByBvid]：B 站接口失败抛 [BiliApiException]；网络失败抛 [DioException]；
///   Gist 读写失败抛 [GithubApiException]（与 playlist_page 现有分类提示一致）
/// - 纯函数（move/remove）不抛异常，返回新数据
class WhitelistWriter {
  final GithubApi github;

  WhitelistWriter({GithubApi? github}) : github = github ?? GithubApi();

  /// 配置门禁：token + gist_id 是否都已配置（写操作前调用）。
  Future<bool> hasConfig() => github.hasConfig();

  /// 从 B 站 view 接口元数据构造 [WhitelistVideo]（未分类、当前时间 added_at）。
  ///
  /// 与 playlist_page 原私有 `_videoFromMeta` 语义一致（M5 迁移到此处共用）。
  static WhitelistVideo videoFromMeta(
    Map<String, dynamic> meta, {
    required String fallbackBvid,
  }) {
    final owner = meta['owner'] as Map<String, dynamic>? ?? const {};
    final rawPages = meta['pages'] as List? ?? const [];
    final pages = rawPages
        .whereType<Map<String, dynamic>>()
        .map((p) => PageInfo(
              cid: (p['cid'] as num?)?.toInt() ?? 0,
              part: p['part'] as String? ?? '',
              duration: (p['duration'] as num?)?.toInt() ?? 0,
            ))
        .toList();
    return WhitelistVideo(
      bvid: meta['bvid'] as String? ?? fallbackBvid,
      cid: (meta['cid'] as num?)?.toInt() ?? 0,
      title: meta['title'] as String? ?? '',
      cover: meta['pic'] as String? ?? '',
      duration: (meta['duration'] as num?)?.toInt() ?? 0,
      upName: owner['name'] as String? ?? '',
      addedAt: DateTime.now().toUtc().toIso8601String(),
      pages: pages.isEmpty ? null : pages,
      collection: '',
    );
  }

  /// 按 bvid：取 B 站元数据 → 构造视频 → [addVideo]。
  ///
  /// 供「导入」与搜索页「加入」共用（一个 bvid 一个完整视频）。
  Future<AddResult> addByBvid(String bvid) async {
    final meta = await BiliApi().fetchVideoMeta(bvid);
    return addVideo(videoFromMeta(meta, fallbackBvid: bvid));
  }

  /// 把已构造好的视频加入白名单：拉当前 Gist → 按 bvid 查重 → 合并 →
  /// saveToGist → 写本地缓存。重复/失败不写盘，返回 [AddResult] 说明原因。
  Future<AddResult> addVideo(WhitelistVideo video) async {
    final current = await github.fetchFromGist();
    final existing = current?.videos ?? const <WhitelistVideo>[];
    final displayTitle = video.title.isEmpty ? video.bvid : video.title;
    if (existing.any((v) => v.bvid == video.bvid)) {
      return AddResult(
        added: false,
        video: video,
        data: current,
        message: '已在白名单：$displayTitle',
      );
    }
    final next = (current ?? WhitelistData.empty()).copyWith(
      videos: [...existing, video],
    );
    final ok = await github.saveToGist(next);
    if (!ok) {
      return AddResult(
        added: false,
        video: video,
        data: current,
        message: '保存到 Gist 失败，请重试',
      );
    }
    await ServiceLocator.syncService.saveToCache(next);
    return AddResult(
      added: true,
      video: video,
      data: next,
      message: '已加入：$displayTitle',
    );
  }

  // ---------------------------------------------------------------------------
  // 批量操作的纯函数（内存变换，返回新数据，原数据不可变；可单元测试）
  // ---------------------------------------------------------------------------

  /// 批量移动视频到指定合集（空串 = 未分类）。
  ///
  /// 白名单按 bvid 查重保证唯一，因此用 bvid 集合作为批量标识。
  static WhitelistData moveVideosToCollection(
    WhitelistData data,
    Set<String> bvids,
    String collection,
  ) {
    if (bvids.isEmpty) return data;
    return data.copyWith(
      videos: [
        for (final v in data.videos)
          bvids.contains(v.bvid) ? v.copyWith(collection: collection) : v,
      ],
    );
  }

  /// 批量移除视频（只删视频，不影响合集定义）。
  static WhitelistData removeVideos(WhitelistData data, Set<String> bvids) {
    if (bvids.isEmpty) return data;
    return data.copyWith(
      videos: data.videos.where((v) => !bvids.contains(v.bvid)).toList(),
    );
  }
}
