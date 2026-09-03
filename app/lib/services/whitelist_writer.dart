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

/// 整季（番剧/电影）导入结果汇总（v2.16.5+，首页与搜索页共用）。
class PgcImportSummary {
  /// 拉到的整季信息（标题/封面/季内集数等，结果反馈用）。
  final PgcSeason season;

  /// 本季新增集数。
  final int added;

  /// 已在白名单被跳过的集数。
  final int skipped;

  /// 是否中途中断（保存失败/网络失败，未跑完全季）。
  final bool interrupted;

  /// 中断原因（[interrupted] 为 true 时有值：网络请求失败 / 保存失败原因）。
  final String interruptReason;

  const PgcImportSummary({
    required this.season,
    required this.added,
    required this.skipped,
    required this.interrupted,
    this.interruptReason = '',
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

  /// B 站 API（番剧整季拉取用；测试可注入 mock）。
  final BiliApi api;

  WhitelistWriter({GithubApi? github, BiliApi? api})
    : github = github ?? GithubApi(),
      api = api ?? BiliApi();

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

  // ---------------------------------------------------------------------------
  // 番剧 / 电影（pgc）整季导入：单集 → WhitelistVideo 的纯构造（可单测）
  // ---------------------------------------------------------------------------

  /// 番剧单集标题里的集数标签：纯数字集数 → 「第X话」，其余原样。
  ///
  /// 例：`1` → `第1话`；`14(OVA)` → `14(OVA)`；空 → 空串。
  static String episodeLabelOf(String epTitle) {
    final t = epTitle.trim();
    if (t.isEmpty) return '';
    final n = int.tryParse(t);
    return (n != null && n > 0) ? '第$t话' : t;
  }

  /// 番剧单集 → 完整标题：`剧名 + 集数标签 + 副标题`。
  ///
  /// 例：`小林家的龙女仆 第1话 史上最强女仆、托尔！`。
  /// 副标题与剧名/集数重复时不重复拼接（电影等单集场景防「电影名 正片 电影名」）。
  static String pgcEpisodeTitle(PgcSeason season, PgcEpisode ep) {
    final label = episodeLabelOf(ep.title);
    final parts = <String>[
      season.title,
      if (label.isNotEmpty) label,
    ];
    final long = ep.longTitle.trim();
    if (long.isNotEmpty &&
        long != season.title &&
        long != label &&
        long != ep.title) {
      parts.add(long);
    }
    return parts.join(' ');
  }

  /// 番剧单集 → [WhitelistVideo]（整季逐集导入用）。
  ///
  /// - 标题 = 剧名 + 第X话 + 副标题（见 [pgcEpisodeTitle]）
  /// - up_name = `番剧/官方`；collection 空（未分类）；pages = 该集单 P；
  ///   epId = 该集 ep_id（播放会员集时据此回退 pgc 取流）
  ///   added_at = [now]（可注入测试用，缺省当前 UTC）
  static WhitelistVideo videoFromPgcEpisode(
    PgcSeason season,
    PgcEpisode ep, {
    DateTime? now,
  }) {
    final label = episodeLabelOf(ep.title);
    final long = ep.longTitle.trim();
    final part = [if (label.isNotEmpty) label, if (long.isNotEmpty) long]
        .join(' ');
    return WhitelistVideo(
      bvid: ep.bvid,
      cid: ep.cid,
      title: pgcEpisodeTitle(season, ep),
      cover: ep.cover,
      duration: ep.durationSec,
      upName: '番剧/官方',
      addedAt: (now ?? DateTime.now()).toUtc().toIso8601String(),
      pages: [PageInfo(cid: ep.cid, part: part, duration: ep.durationSec)],
      collection: '',
      // ep_id 脏数据（0）不写入，视为无 epId 的普通视频
      epId: ep.epId > 0 ? ep.epId : null,
    );
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
  // 番剧/电影整季导入（v2.16.5+）：首页「导入链接」与搜索页「media 结果导入」
  // 共用。拉整季 + 逐集 [addVideo]，纯逻辑无 UI（进度经回调上报）
  // ---------------------------------------------------------------------------

  /// 番剧/电影整季导入：拉整季信息 → 逐集 [addVideo] 写白名单
  /// （addVideo 内部按 bvid 查重，已在白名单的集自动跳过）。
  ///
  /// [epId]/[seasonId] 二选一（语义同 [BiliApi.fetchPgcSeason]）。
  /// [onProgress] 可选：每集写盘前后回调进度文案（UI 进度框用）。
  ///
  /// 异常契约（调用方 UI 据此分类提示）：
  /// - 拉整季阶段：B 站失败抛 [BiliApiException]、网络失败抛 [DioException]
  ///   （此时未写任何 Gist）
  /// - 逐集写盘阶段失败不抛：中断并汇总到 [PgcImportSummary.interrupted] /
  ///   [PgcImportSummary.interruptReason]（已写集数见 [PgcImportSummary.added]）
  Future<PgcImportSummary> importPgcSeason({
    int? epId,
    int? seasonId,
    void Function(String status)? onProgress,
  }) async {
    // 1) 拉整季（ep/ss 引用都返回全季 episodes 列表）
    final season = await api.fetchPgcSeason(epId: epId, seasonId: seasonId);
    final eps = season.episodes;
    if (eps.isEmpty) {
      return PgcImportSummary(
        season: season,
        added: 0,
        skipped: 0,
        interrupted: false,
      );
    }
    onProgress?.call('准备导入「${season.title}」，共 ${eps.length} 集…');

    // 2) 逐集构造 WhitelistVideo 并写入（每集独立拉 Gist 查重 + 追加）
    var added = 0, skipped = 0;
    var interrupted = false;
    var interruptReason = '';
    for (var i = 0; i < eps.length; i++) {
      final ep = eps[i];
      if (ep.bvid.isEmpty) continue; // 防御：无 bvid 的脏条目跳过
      final video = videoFromPgcEpisode(season, ep);
      onProgress?.call('导入中 ${i + 1}/${eps.length}：${video.title}');
      try {
        final result = await addVideo(video);
        if (result.added) {
          added++;
        } else if (result.message.contains('已在白名单')) {
          skipped++;
        } else {
          // 保存失败等非重复原因 → 中断（其余集不写）
          interrupted = true;
          interruptReason = result.message;
          break;
        }
      } on DioException {
        interrupted = true;
        interruptReason = '网络请求失败';
        break;
      } on GithubApiException catch (e) {
        interrupted = true;
        interruptReason = e.message;
        break;
      }
    }
    return PgcImportSummary(
      season: season,
      added: added,
      skipped: skipped,
      interrupted: interrupted,
      interruptReason: interruptReason,
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

  /// 合集内视频重排（拖拽排序用）：把 [newOrderBvids]（该合集视频的新展示
  /// 顺序，bvid 列表）映射为 order = 0..n-1，写回该合集所有视频。
  ///
  /// 策略（简单方案）：只把本合集的视频 order 重排为「连续区间 0..n-1」，
  /// 其他合集视频的 order 一律不动。跨合集的全局 order 可能重叠/乱序，
  /// 但展示一律经 `sortedVideos(collection)` 按合集过滤后再排序，
  /// 因此本合集内顺序正确、各合集互不影响，满足拖拽排序需求。
  /// [collectionName] 空串 = 未分类。
  static WhitelistData reorderVideosInCollection(
    WhitelistData data,
    String collectionName,
    List<String> newOrderBvids,
  ) {
    if (newOrderBvids.isEmpty) return data;
    final orderOf = {
      for (var i = 0; i < newOrderBvids.length; i++) newOrderBvids[i]: i,
    };
    return data.copyWith(
      videos: [
        for (final v in data.videos)
          v.collection == collectionName
              ? v.copyWith(order: orderOf[v.bvid] ?? v.order)
              : v,
      ],
    );
  }
}
