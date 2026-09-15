/// 离线缓存页（v2.29.0）：把原来「个人页 → 缓存管理弹层」升级成独立页面。
///
/// ## 为什么是独立页，而不是「专门放缓存视频的合集」
///
/// 需求原话是「增加一个集合专门用来放缓存视频」。做成白名单里的**特例合集**
/// 覆盖不到真实场景：缓存视频**不一定是白名单视频**——历史记录、搜索、收藏夹、
/// 评论列表里的视频都能进播放页并下载，这些 bvid 在 `WhitelistData.videos`
/// 里根本不存在，没有对象可以挂 `collection` 字段。而特例合集还会自动污染
/// 主页卡片、合集管理面板、统计、Gist 同步与 PC 端 CLI。所以缓存列表自成一页：
/// 数据源是 [DownloadManager] 的本地索引，与白名单互不干涉。
///
/// ## 页面内容
/// - 顶部：**分项占用**（媒体 / 转写中转音频 / 残留）+ 两个清理动作
///   （「压缩存储」这个诉求的正面回答：m4s 本身已是 H.264/AAC 有损流，
///   再压只能省 0~3%，真正的空间在这里）
/// - 列表：按 bvid 分组（同视频的多 P 归一组），每条分 P 显示大小/时间/
///   「音频」「视频」标记，可单删；页脚「清空全部」
/// - 点条目 → [PlayerPage]（用 [CachedVideo] 现场构造 [WhitelistVideo]，
///   见 [_openEntry] 的说明）
library;

import 'package:flutter/material.dart';

import '../api/sherpa_audio.dart';
import '../cache/download_manager.dart';
import '../models/whitelist_video.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_hero.dart';
import '../widgets/cover_image.dart';
import '../widgets/history_tile.dart' show HistoryTile;
import 'player_page.dart';

/// 一组同 bvid 的离线缓存（页面分组单元；纯数据，好单测）。
class OfflineGroup {
  final String bvid;
  final String title;
  final String cover;
  final String upName;

  /// 该视频已缓存的分 P（按 pageIndex 升序）。
  final List<CachedVideo> parts;

  const OfflineGroup({
    required this.bvid,
    required this.title,
    required this.cover,
    required this.upName,
    required this.parts,
  });

  /// 该视频缓存总字节（按索引记账值）。
  int get totalBytes => parts.fold(0, (sum, c) => sum + c.sizeBytes);

  /// 该视频的缓存**全是**仅音频（组头标「仅音频」用）。
  bool get allAudioOnly => parts.isNotEmpty && parts.every((c) => c.audioOnly);
}

/// 按 bvid 分组（同视频多 P 归一组）。
///
/// 纯函数（单测直接调）：组间顺序 = 各组**最新一条**的缓存时间倒序
/// （入参 [items] 已是缓存时间倒序，故按首次出现顺序即可），组内按 pageIndex
/// 升序——用户要的是「最近存的在最上面，同一视频从第 1 集往下读」。
List<OfflineGroup> groupCachedByBvid(List<CachedVideo> items) {
  final order = <String>[];
  final byBvid = <String, List<CachedVideo>>{};
  for (final c in items) {
    final bucket = byBvid.putIfAbsent(c.bvid, () {
      order.add(c.bvid);
      return <CachedVideo>[];
    });
    bucket.add(c);
  }
  return [
    for (final bvid in order)
      OfflineGroup(
        bvid: bvid,
        title: byBvid[bvid]!.first.title,
        cover: byBvid[bvid]!.first.cover,
        upName: byBvid[bvid]!.first.upName,
        parts: byBvid[bvid]!..sort((a, b) => a.pageIndex.compareTo(b.pageIndex)),
      ),
  ];
}

/// 中转音频清理按钮的 key（测试要读它的 enabled 状态；`OutlinedButton.icon`
/// 的实际类型是私有子类，`find.byType(OutlinedButton)` 匹配不到）。
const Key kCleanTmpAudioKey = Key('offline-clean-tmp-audio');

/// 回收残留文件按钮的 key（同上）。
const Key kReclaimOrphansKey = Key('offline-reclaim-orphans');

/// 离线缓存页（入口：「个人」页 → 设置 → 离线缓存）。
class OfflinePage extends StatefulWidget {
  /// 中转音频清理服务（默认自建）。
  ///
  /// 可注入的理由与 [AudioSourceException] 无关：清理要按「应用支持目录」
  /// 定位 `audio_tmp/`，而 widget 测试里没有 path_provider 原生通道 ——
  /// 测试注入带 [SherpaAudioSource.rootDir] 的实例（内存临时目录）。
  @visibleForTesting
  final SherpaAudioSource? audioSource;

  const OfflinePage({super.key, this.audioSource});

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  final DownloadManager _downloads = DownloadManager.instance;

  late final SherpaAudioSource _audio =
      widget.audioSource ?? SherpaAudioSource();

  List<CachedVideo> _items = const [];
  CacheDiskUsage _usage = const CacheDiskUsage();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // 缓存状态变化（下载完成/删除）→ 页面即时刷新
    _downloads.cached.addListener(_onCacheChanged);
    _reload();
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) _reload();
  }

  /// 重新读索引 + 重算占用（写盘统计要 await，故每次重载都重算）。
  ///
  /// 两处都**带 500ms 超时**（与 player_page 加载缓存索引同一套路）：测试
  /// 环境没有 path_provider 原生通道时平台通道的 future **永不返回**（不是
  /// 抛错，见 player_page 的注释），不设超时页面会永远停在转圈上。
  ///
  /// 另带兜底：`diskUsage()` 定位应用支持目录失败时按已加载的索引降级展示
  /// —— 列表与清理动作本身不依赖占用统计。
  Future<void> _reload() async {
    var items = const <CachedVideo>[];
    var usage = const CacheDiskUsage();
    try {
      await _downloads.init().timeout(_kLoadTimeout);
      items = _downloads.getCachedList();
      usage = await _downloads.diskUsage().timeout(_kLoadTimeout);
    } catch (_) {
      items = _downloads.getCachedList();
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _usage = usage;
      _loading = false;
    });
  }

  /// 索引/占用读取的超时预算（本地 json + 目录扫描，正常远小于它）。
  static const Duration _kLoadTimeout = Duration(milliseconds: 500);

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 播放
  // ---------------------------------------------------------------------------

  /// 点某条缓存 → 进播放页（播放页命中缓存则直接播本地文件，不请求网络）。
  ///
  /// **一律用 [CachedVideo] 现场构造 [WhitelistVideo]**，不去查白名单：
  /// 白名单数据在 `playlist_page` 的 State 里、靠 Gist 网络拉取，而本页的
  /// 使用场景恰恰是「没网 / 快到流量上限」——为了拿一个更完整的对象而让
  /// 入口在最需要它的时候失败，得不偿失；何况缓存视频本来就不都在白名单里。
  ///
  /// 不传 `pages`：合成 pages 列表需要**未缓存分 P 的 cid**（拿不到），硬填
  /// 占位会让播放页的选集菜单出现点不动的项。改用 `initialPageIndex` 直接
  /// 定位到当前分 P —— 播放页在无 pages 时不夹取该下标（见 player_page
  /// initState 的注释），缓存键 (bvid, pageIndex) 因此正好命中本条。
  void _openEntry(CachedVideo c) {
    final video = WhitelistVideo(
      bvid: c.bvid,
      cid: c.cid,
      title: c.title,
      cover: c.cover,
      duration: c.durationMs ~/ 1000,
      upName: c.upName,
      addedAt: c.cachedAt.toIso8601String(),
    );
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: kPlayerRouteName),
          builder: (_) =>
              PlayerPage(video: video, initialPageIndex: c.pageIndex),
        ))
        .then((_) => _reload()); // 返回后刷新（播放可能改了进度/写了历史）
  }

  // ---------------------------------------------------------------------------
  // 删除 / 清理
  // ---------------------------------------------------------------------------

  Future<void> _deleteOne(CachedVideo c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除缓存'),
        content: Text('确定删除《${c.title}》${_partLabel(c)}的缓存吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.deleteCache(c.bvid, c.pageIndex);
    await _reload();
    _showSnack('已删除缓存');
  }

  /// 清空全部媒体缓存（确认框里把中转音频也讲清楚：它不归这次清理管）。
  Future<void> _clearAll() async {
    final total = _items.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清空缓存'),
        content: Text(
          '确定清空全部 $total 个视频的缓存吗？'
          '将删除所有已缓存的视频/音频文件（${fmtBytes(_downloads.totalCacheSize())}），'
          '离线将无法播放。\n\n'
          '转写中转音频（${fmtBytes(_usage.tmpAudioBytes)}）不在这次清理范围内，'
          '需要的话用上方「清理中转音频」单独清。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清空', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.cleanAllCache();
    await _reload();
    _showSnack('已清空缓存');
  }

  /// 清理转写中转音频（`audio_tmp/`：临时 m4s + 16k wav）。
  Future<void> _cleanTmpAudio() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清理中转音频'),
        content: Text(
          '将删除实时转写用的中转音频（${fmtBytes(_usage.tmpAudioBytes)}，'
          '含 16k 转码 wav）。\n\n'
          '已缓存的视频/音频不受影响；下次用实时转写时需重新转码（几秒）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清理', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await _audio.cleanTmpAudio();
    await _reload();
    _showSnack(result.files == 0
        ? '没有可清理的中转音频'
        : '已清理 ${result.files} 个中转文件 · ${fmtBytes(result.bytes)}');
  }

  /// 回收 `video_cache/` 下的残留文件（`.part` / 孤儿；不动索引内的文件）。
  Future<void> _reclaimOrphans() async {
    final result = await _downloads.reclaimOrphans();
    await _reload();
    _showSnack(result.files == 0
        ? '没有需要回收的残留文件'
        : '已回收 ${result.files} 个残留文件 · ${fmtBytes(result.bytes)}');
  }

  /// 缓存条目副标题：内容行的「分 P 名」部分。
  ///
  /// 多 P 显示 `第 N 集 · 分P名`（分P名为空则只留集数）；单 P 只显示分P名
  /// （为空则整段不出现，改用视频标题兜底，见 [_buildPartTile]）。
  String _partLabel(CachedVideo c) {
    final part = c.partTitle;
    if (c.pageIndex <= 0) return part;
    return part.isEmpty
        ? '第 ${c.pageIndex + 1} 集'
        : '第 ${c.pageIndex + 1} 集 · $part';
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('离线缓存')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildUsageCard(theme),
          const Divider(height: 1),
          Expanded(
            child: _loading
                // 索引读取很快（本地 json），用轻量加载视图而不是整页 hero
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _items.isEmpty
                    ? const AppStateView(
                        kind: AppStateKind.empty,
                        copyId: 'empty.cache',
                        subtitleCopyId: 'empty.cache.sub',
                        illustrationSeed: 'cache',
                        // 本页不在 RefreshIndicator 里 → 自带滚动，撑开整块高度
                        scrollable: true,
                      )
                    : _buildList(theme),
          ),
        ],
      ),
    );
  }

  /// 顶部占用卡：分项占用 + 两个清理动作（能省空间的地方都在这）。
  Widget _buildUsageCard(ThemeData theme) {
    final usage = _usage;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          kSectionPadH, kSpace12, kSectionPadH, kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('缓存占用', style: theme.textTheme.titleMedium),
              ),
              Text(
                '合计 ${fmtBytes(usage.totalBytes)}',
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: kSpace4),
          // 分项：媒体 / 中转音频 / 残留（三条来源不同、清理入口也不同）
          Text(
            '媒体文件 ${fmtBytes(usage.mediaBytes)}（${_items.length} 个）'
            ' · 中转音频 ${fmtBytes(usage.tmpAudioBytes)}'
            '${usage.hasOrphans ? ' · 残留 ${fmtBytes(usage.orphanBytes)}' : ''}',
            style: muted,
          ),
          const SizedBox(height: kSpace8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // 没有中转音频就置灰（避免用户点了「没东西可清」还要看弹窗）
                  key: kCleanTmpAudioKey,
                  onPressed: usage.hasTmpAudio ? _cleanTmpAudio : null,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('清理中转音频'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: kSpace8),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                ),
              ),
              const SizedBox(width: kSpace8),
              Expanded(
                child: OutlinedButton.icon(
                  key: kReclaimOrphansKey,
                  onPressed: usage.hasOrphans ? _reclaimOrphans : null,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('回收残留文件'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: kSpace8),
                    textStyle: theme.textTheme.labelLarge,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 缓存列表：按 bvid 分组（组头 = 封面 + 标题 + UP + 总大小；下面是各分 P）。
  Widget _buildList(ThemeData theme) {
    final groups = groupCachedByBvid(_items);
    return ListView(
      padding: const EdgeInsets.fromLTRB(kSectionPadH, kSpace8, kSectionPadH, 24),
      children: [
        for (final g in groups) ...[
          _buildGroupHeader(theme, g),
          const SizedBox(height: kSpace4),
          for (final c in g.parts) _buildPartTile(theme, c),
          const SizedBox(height: kListGap),
        ],
        // 页脚：清空全部（带大小确认）
        OutlinedButton.icon(
          onPressed: _clearAll,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('清空全部缓存'),
        ),
      ],
    );
  }

  Widget _buildGroupHeader(ThemeData theme, OfflineGroup g) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverHero(
          tag: coverHeroTag(g.bvid),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kRadiusSm),
            child: CoverImage(cover: g.cover, width: 112, height: 63),
          ),
        ),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                g.title.isEmpty ? g.bvid : g.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: kSpace2),
              Text(
                '${g.upName} · ${g.parts.length} 个 · ${fmtBytes(g.totalBytes)}'
                '${g.allAudioOnly ? ' · 仅音频' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 单条分 P：大小 · 缓存时间 · 「音频」/「视频」标记；点条目播放、右侧删除。
  Widget _buildPartTile(ThemeData theme, CachedVideo c) {
    final label = _partLabel(c);
    final title = label.isEmpty ? (c.title.isEmpty ? c.bvid : c.title) : label;
    // 单 P 视频的 `pages[0].part` 实测就等于视频标题（真机截图里那一行明显
    // 冗余）→ 分 P 名与视频标题相同时，副信息里不再重复一遍；多 P 的
    // 「第 N 集 · 分P名」照常显示（title 行是三字集数，meta 行是分 P 名，
    // 两者本来就不是同一句）
    final repeatsTitle = label.isNotEmpty && label == c.title;
    final meta = [
      if (label.isNotEmpty && !repeatsTitle) label,
      fmtBytes(c.sizeBytes),
      HistoryTile.relativeTime(c.cachedAt.toLocal()),
      c.audioOnly ? '音频' : '视频',
    ].join(' · ');
    return ListTile(
      key: ValueKey('offline#${c.key}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: () => _openEntry(c),
      leading: Icon(
        c.audioOnly ? Icons.audiotrack_outlined : Icons.movie_outlined,
        size: 20,
        color: context.palette.inkText,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(meta, style: theme.textTheme.bodySmall),
      trailing: IconButton(
        tooltip: '删除这条缓存',
        icon: Icon(
          Icons.delete_outline,
          size: 20,
          color: theme.colorScheme.error,
        ),
        onPressed: () => _deleteOne(c),
      ),
    );
  }
}
