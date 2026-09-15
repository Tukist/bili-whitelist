import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/bilibili_api.dart';
// 中转音频目录（audio_tmp/）的路径逻辑只有 sherpa_audio 一处定义，占用统计
// 复用它的静态解析器 —— 循环 import（sherpa_audio 也 import 本文件拿
// DownloadManager）在 Dart 里合法，且这里只用它的常量与纯路径函数。
import '../api/sherpa_audio.dart';
import '../config.dart';
import '../models/whitelist_video.dart';

/// 下载进度回调：`(received, total)` 字节；total 未知（无 Content-Length）时为 -1。
typedef DownloadProgressCallback = void Function(int received, int total);

/// 取流函数：拿 DASH 双流（无 DASH 则 mp4 单流）。默认走 [BiliApi.fetchPlayUrl]，
/// 测试可注入 fake（不碰真实网络）。
typedef PlayUrlFetcher = Future<PlayUrlResult> Function({
  required String bvid,
  required int cid,
});

/// 单文件下载函数：把 [url] 下载到 [savePath]，期间回调进度。默认用独立 dio
/// （仅 Referer + 浏览器 UA、不带 cookie，M0 实测）；测试可注入 fake。
typedef FileDownloader = Future<void> Function(
  String url,
  String savePath,
  DownloadProgressCallback? onProgress,
);

/// 字节数格式化：`512 B` / `1.2 KB` / `3.4 MB` / `1.02 GB`。
String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 已缓存视频记录（cache_index.json 的一项；key = bvid + 分P索引）。
class CachedVideo {
  final String bvid;
  final String title;
  final String cover;
  final int pageIndex; // 0 基；单 P 固定 0
  final String partTitle; // 多 P 的当前集标题；单 P / 缺省为空串
  final String videoPath; // 本地视频文件绝对路径；仅音频缓存恒为空串
  final String audioPath; // 本地音频文件绝对路径；单流（mp4）为空串
  final int sizeBytes; // 文件总字节数
  final DateTime cachedAt;
  final String upName;

  /// 该集 cid（离线缓存页用它现场构造 [WhitelistVideo] → 播放/弹幕/字幕）。
  /// 旧索引没有该字段 → 0（此时离线页仍能播放缓存文件，只是拿不到弹幕字幕）。
  final int cid;

  /// 该集时长（毫秒）；0 = 未知（旧索引）。
  final int durationMs;

  /// 是否「仅音频」缓存：true 时 [videoPath] 恒为空串，只有 [audioPath]。
  ///
  /// 省空间手段：30 分钟视频「视频+音频」200~500MB，仅音频 15~36MB。
  /// 播放时把音频文件当 videoUrl 传给播放器（单流 ProgressiveMediaSource），
  /// 见 player_page 的离线分支与 CHANGELOG v2.29.0 说明。
  final bool audioOnly;

  const CachedVideo({
    required this.bvid,
    required this.title,
    required this.cover,
    required this.pageIndex,
    required this.partTitle,
    required this.videoPath,
    required this.audioPath,
    required this.sizeBytes,
    required this.cachedAt,
    required this.upName,
    this.cid = 0,
    this.durationMs = 0,
    this.audioOnly = false,
  });

  factory CachedVideo.fromJson(Map<String, dynamic> json) {
    // 音频路径空 + 索引里没有 audioOnly 标记时是否算「仅音频」？
    // **不算**：旧索引（v2.28 及以前）的 mp4 单流缓存就是 audioPath 空
    // 而 videoPath 有值，那时它是**有画面**的。判定只看显式字段。
    return CachedVideo(
      bvid: json['bvid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      partTitle: json['partTitle'] as String? ?? '',
      videoPath: json['videoPath'] as String? ?? '',
      audioPath: json['audioPath'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      cachedAt:
          DateTime.tryParse(json['cachedAt'] as String? ?? '') ?? DateTime.now(),
      upName: json['upName'] as String? ?? '',
      // v2.29.0 新增字段：旧索引缺字段一律走默认值（不升 version、不写迁移）
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      audioOnly: json['audioOnly'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'title': title,
        'cover': cover,
        'pageIndex': pageIndex,
        'partTitle': partTitle,
        'videoPath': videoPath,
        'audioPath': audioPath,
        'sizeBytes': sizeBytes,
        'cachedAt': cachedAt.toUtc().toIso8601String(),
        'upName': upName,
        'cid': cid,
        'durationMs': durationMs,
        'audioOnly': audioOnly,
      };

  /// 缓存键：`bvid#pageIndex`。
  static String keyOf(String bvid, int pageIndex) => '$bvid#$pageIndex';

  String get key => keyOf(bvid, pageIndex);

  /// 离线播放用的源文件：仅音频缓存 = 音频文件，否则 = 视频文件。
  ///
  /// 只读语义（不改任何字段），离线页与播放页共用同一口径，
  /// 避免两处各判一次 `audioOnly && videoPath.isEmpty`。
  String get playablePath => audioOnly ? audioPath : videoPath;
}

/// 单个下载任务状态。
enum DownloadStatus { queued, downloading, completed, failed }

/// 单个下载任务（供 UI 展示状态/进度；对象可变，变化时通知 [DownloadManager.tasks]）。
class DownloadTask {
  final String bvid;
  final int pageIndex;
  final String partTitle;
  DownloadStatus status;
  int received; // 当前文件已下载字节
  int total; // 当前文件总字节（未知为 -1）
  double? progress; // 0~1；total 未知时为 null（UI 显示不定进度）
  String? error; // failed 时的错误信息

  DownloadTask({
    required this.bvid,
    required this.pageIndex,
    required this.partTitle,
    this.status = DownloadStatus.queued,
    this.received = 0,
    this.total = -1,
    this.progress,
    this.error,
  });

  String get key => CachedVideo.keyOf(bvid, pageIndex);

  /// 百分比（0~100；未知进度返回 0）。
  int get percent => progress == null ? 0 : (progress! * 100).round();
}

/// 缓存磁盘占用分项（字节；[DownloadManager.diskUsage] 的返回值）。
///
/// 「分项」是刻意的：媒体文件、转写中转音频、孤儿残留三条来源不同、清理
/// 入口也不同，合成一个总数只会让用户不知道该清哪个。
class CacheDiskUsage {
  /// 索引内在册的媒体文件占用（`video_cache/`）。
  final int mediaBytes;

  /// 转写中转音频占用（`audio_tmp/`：临时 m4s + 16k 单声道 wav）。
  final int tmpAudioBytes;

  /// 不被索引引用的残留占用（`video_cache/` 下的 `.part` 与孤儿文件）。
  final int orphanBytes;

  /// 残留文件个数（UI 据此决定「回收残留文件」是否可点）。
  final int orphanCount;

  const CacheDiskUsage({
    this.mediaBytes = 0,
    this.tmpAudioBytes = 0,
    this.orphanBytes = 0,
    this.orphanCount = 0,
  });

  /// 两个缓存目录的真占用合计。
  int get totalBytes => mediaBytes + tmpAudioBytes + orphanBytes;

  /// 有可回收的残留（`.part` / 孤儿文件）→ UI 亮出「回收残留文件」。
  bool get hasOrphans => orphanCount > 0;

  /// 有可清理的中转音频 → UI 亮出「清理中转音频」。
  bool get hasTmpAudio => tmpAudioBytes > 0;
}

/// 视频离线缓存下载管理器（单例）。
///
/// 职责：
/// - 下载：实时取 playurl（DASH 双流 video+audio，无 DASH 降级 mp4 单流），
///   带 Referer + 浏览器 UA 下载（不带 cookie，M0 实测）；流 URL 数分钟过期
///   只影响在线取流，数据本身可下载保存
/// - **仅音频下载**（`audioOnly`）：只存音频流（挑最低码率档），30 分钟视频
///   从 200~500MB 降到 15~36MB；播放时把音频文件当 videoUrl 传给播放器
/// - 串行队列：同时只允许一个下载（B 站对高频请求风控，串行 + 任务间隔更稳），
///   单文件失败自动重试一次
/// - 持久化：媒体文件存应用文档目录 `video_cache/`，元数据 `cache_index.json`
/// - 占用管理：分项统计（[diskUsage]）+ 孤儿回收（[reclaimOrphans]）；
///   转写中转音频（`audio_tmp/`）的清理在 [SherpaAudioSource.cleanTmpAudio]
/// - 状态暴露：[cached]（已缓存列表）与 [tasks]（任务表，含进度）两个
///   [ValueNotifier]，UI 监听刷新；[downloadVideo] 返回的 Future 在任务完成/
///   失败时结束（失败抛错）
class DownloadManager {
  DownloadManager({
    PlayUrlFetcher? fetchPlayUrl,
    FileDownloader? downloadFile,
    Directory? rootDir,
    this.betweenTasks = const Duration(milliseconds: 800),
    this.retryDelay = const Duration(seconds: 1),
  })  : _fetchUrlOverride = fetchPlayUrl,
        _downloadOverride = downloadFile,
        _rootDirOverride = rootDir;

  static DownloadManager? _instance;

  /// 全局单例（页面直接用；测试通过 [debugOverride] 替换）。
  static DownloadManager get instance => _instance ??= DownloadManager();

  /// 测试注入：替换单例实现。
  @visibleForTesting
  static void debugOverride(DownloadManager manager) => _instance = manager;

  /// 测试复位：清空单例，下次取回全新实例。
  @visibleForTesting
  static void debugReset() => _instance = null;

  final PlayUrlFetcher? _fetchUrlOverride;
  final FileDownloader? _downloadOverride;
  final Directory? _rootDirOverride;

  /// 串行队列中相邻两个任务之间的间隔（降低风控概率；测试可传零）。
  final Duration betweenTasks;

  /// 单文件失败后的重试间隔（测试可传零）。
  final Duration retryDelay;

  BiliApi? _api; // 默认取流实现内部持有（会话内 WBI key 缓存复用）

  /// 已缓存列表（从 cache_index.json 惰性加载）。
  final ValueNotifier<List<CachedVideo>> cached = ValueNotifier(const []);

  /// 任务表：key = `bvid#pageIndex` → [DownloadTask]。
  final ValueNotifier<Map<String, DownloadTask>> tasks =
      ValueNotifier(const {});

  final List<
      ({
        DownloadTask task,
        Completer<void> done,
        WhitelistVideo video,
        bool audioOnly,
      })> _queue = [];
  final Map<String, Completer<void>> _completers = {};
  bool _running = false;
  bool _indexLoaded = false;

  /// 正在写入的路径（`.part` 与最终路径）：[reclaimOrphans] 靠它跳过在途文件，
  /// 避免「回收残留」把正在下载的半成品删掉（rename 会因此失败）。
  final Set<String> _writing = {};

  PlayUrlFetcher get _fetchPlayUrl => _fetchUrlOverride ?? _defaultFetchPlayUrl;
  FileDownloader get _downloadFile => _downloadOverride ?? _defaultDownloadFile;

  /// 初始化：加载 cache_index.json（幂等；UI 启动流程先 await 再查询缓存）。
  ///
  /// 加载完成后通过 [cached] notifier 通知（列表页可 fire-and-forget 调用，
  /// 标记会在加载完成后自动出现）。
  Future<void> init() => _loadIndex();

  /// 任务表变化通知：ValueNotifier 的 notifyListeners 受保护，通过重新赋值
  /// 触发监听（map 内容不变，仅换实例）。
  void _notifyTasks() => tasks.value = Map<String, DownloadTask>.from(tasks.value);

  // ---------------------------------------------------------------------------
  // 路径 / 索引持久化
  // ---------------------------------------------------------------------------

  /// 应用文档目录（path_provider；Android 上即 `files/` 下）。
  Future<Directory> _rootDir() async =>
      _rootDirOverride ?? await getApplicationSupportDirectory();

  /// 媒体文件目录：`<root>/video_cache/`。
  Future<Directory> _mediaDir() async {
    final dir = Directory('${(await _rootDir()).path}/video_cache');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _indexFile() async =>
      File('${(await _rootDir()).path}/cache_index.json');

  /// 惰性加载 cache_index.json（只读一次，之后以内存为准；损坏视为空）。
  Future<List<CachedVideo>> _loadIndex() async {
    if (_indexLoaded) return cached.value;
    _indexLoaded = true;
    try {
      final f = await _indexFile();
      if (!await f.exists()) return cached.value;
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, dynamic>) {
        final items = (json['items'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CachedVideo.fromJson)
            .toList()
          ..sort((a, b) => b.cachedAt.compareTo(a.cachedAt));
        cached.value = items;
      }
    } catch (_) {
      // 索引损坏/读取失败：忽略，视为空（重新下载会重建）
    }
    return cached.value;
  }

  Future<void> _saveIndex() async {
    final f = await _indexFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(
      jsonEncode({
        'version': 1,
        'items': cached.value.map((c) => c.toJson()).toList(),
      }),
      flush: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 某集是否已缓存（索引在册即视为已缓存）。
  bool isCached(String bvid, int pageIndex) => getCached(bvid, pageIndex) != null;

  /// 某集的缓存记录（无则 null）。
  CachedVideo? getCached(String bvid, int pageIndex) {
    for (final c in cached.value) {
      if (c.bvid == bvid && c.pageIndex == pageIndex) return c;
    }
    return null;
  }

  /// 某视频已缓存的集数（多 P 时列表页角标用）。
  int cachedCount(String bvid) =>
      cached.value.where((c) => c.bvid == bvid).length;

  /// 某视频已缓存的集是否**全部**是「仅音频」（列表页角标文案要区分：
  /// 点进去没有画面，不能跟整段缓存一样只写「已缓存」）；无缓存 → false。
  bool cachedAllAudioOnly(String bvid) {
    var any = false;
    for (final c in cached.value) {
      if (c.bvid != bvid) continue;
      if (!c.audioOnly) return false;
      any = true;
    }
    return any;
  }

  /// 全部缓存记录（按缓存时间倒序）。
  List<CachedVideo> getCachedList() => List.unmodifiable(cached.value);

  /// 缓存总字节数（索引记账口径；实测磁盘占用见 [diskUsage]）。
  int totalCacheSize() => cached.value.fold(0, (sum, c) => sum + c.sizeBytes);

  // ---------------------------------------------------------------------------
  // 占用统计 / 清理（「能不能压缩存储」的正面回答）
  //
  // 结论：**不做转码压缩**。缓存下来的 `.m4s` 本身就是 H.264/AAC 有损压缩流，
  // zip/tar 再压只能省 0~3%；重新转码降码率要引入 ffmpeg 到缓存链路、耗时
  // 半个视频时长、有损、失败还要清半成品。真正能省的是「只缓存音频」与
  // 「别让中转音频躺着占空间」——即本节的分项统计 + 清理动作。
  // ---------------------------------------------------------------------------

  /// 缓存磁盘占用分项（字节）。
  ///
  /// - [mediaBytes]：索引内在册的媒体文件实际字节（`video_cache/`）——
  ///   不信 `sizeBytes` 记账值（文件可能被手动删/写坏），一律现读文件长度
  /// - [tmpAudioBytes]：`audio_tmp/` 转写中转音频（实时转写用的 m4s + 16k wav，
  ///   30 分钟一集约 57MB，比音频流本体还大，且此前**没有任何删除入口**）
  /// - [orphanBytes] / [orphanCount]：`video_cache/` 下不被索引引用的残留
  ///   （下载中途崩溃、进程被杀留下的 `.part` 与孤儿文件）
  ///
  /// 合计 [totalBytes] = 三者之和（= 这两个目录真占的磁盘）。
  Future<CacheDiskUsage> diskUsage() async {
    await _loadIndex();
    final root = await _rootDir();
    final mediaDir = Directory('${root.path}/video_cache');
    final referenced = <String>{};
    var mediaBytes = 0;
    for (final c in cached.value) {
      for (final p in [c.videoPath, c.audioPath]) {
        if (p.isEmpty) continue;
        referenced.add(_normPath(p));
        mediaBytes += await _fileLength(p);
      }
    }
    var orphanBytes = 0;
    var orphanCount = 0;
    try {
      if (await mediaDir.exists()) {
        await for (final e in mediaDir.list()) {
          if (e is! File) continue;
          // 在途文件不算残留（正在下的 .part 也必须跳过，否则回收会毁掉任务）
          if (referenced.contains(_normPath(e.path))) continue;
          if (_writing.contains(e.path)) continue;
          orphanBytes += await _fileLength(e.path);
          orphanCount++;
        }
      }
    } catch (_) {
      // 目录不可读（权限/并发删除）：按已知部分返回，不抛给 UI
    }
    final tmpDir = await SherpaAudioSource.tmpAudioDir(root);
    var tmpBytes = 0;
    try {
      if (await tmpDir.exists()) {
        await for (final e in tmpDir.list()) {
          if (e is! File) continue;
          tmpBytes += await _fileLength(e.path);
        }
      }
    } catch (_) {
      // 同上
    }
    return CacheDiskUsage(
      mediaBytes: mediaBytes,
      tmpAudioBytes: tmpBytes,
      orphanBytes: orphanBytes,
      orphanCount: orphanCount,
    );
  }

  /// 回收 `video_cache/` 下不被索引引用的残留文件（含 `.part`）。
  ///
  /// **不碰**索引内的文件、**不碰**在途下载（[_writing]）、**不碰**
  /// `audio_tmp/`（那个有独立的 [SherpaAudioSource.cleanTmpAudio]）。
  /// 返回删除的文件数与字节数（UI 反馈「已回收 N 个文件 · X」）。
  Future<({int files, int bytes})> reclaimOrphans() async {
    await _loadIndex();
    final mediaDir = await _mediaDir();
    final referenced = <String>{
      for (final c in cached.value)
        for (final p in [c.videoPath, c.audioPath])
          if (p.isNotEmpty) _normPath(p),
    };
    var files = 0;
    var bytes = 0;
    try {
      await for (final e in mediaDir.list()) {
        if (e is! File) continue;
        if (referenced.contains(_normPath(e.path))) continue;
        if (_writing.contains(e.path)) continue;
        final len = await _fileLength(e.path);
        try {
          await e.delete();
          files++;
          bytes += len;
        } catch (_) {
          // 单个文件删不掉（占用中）不阻断其余回收
        }
      }
    } catch (_) {
      // 目录不可读
    }
    return (files: files, bytes: bytes);
  }

  // ---------------------------------------------------------------------------
  // 下载（串行队列）
  // ---------------------------------------------------------------------------

  /// 下载指定集：入队（已在该集的下载队列/下载中时直接返回同一 Future；
  /// 已缓存也可重新下载，会覆盖旧文件）。任务完成时 Future 正常结束，
  /// 失败时 Future 抛错（调用方可 catch 提示）。
  ///
  /// [audioOnly] = true → **只下载音频流**（挑码率最低档），索引里
  /// `videoPath` 为空串、`audioOnly` 为 true（省空间，见 [CachedVideo.audioOnly]）。
  /// 去重键仍是 `bvid#pageIndex`：同一集「整段下载中」时再点「仅缓存音频」
  /// 会复用那个在途任务（不并发、不串流），反之亦然。
  Future<void> downloadVideo(
    WhitelistVideo video,
    int pageIndex, {
    bool audioOnly = false,
  }) {
    final key = CachedVideo.keyOf(video.bvid, pageIndex);
    final inFlight = _completers[key];
    if (inFlight != null) return inFlight.future;
    final task = DownloadTask(
      bvid: video.bvid,
      pageIndex: pageIndex,
      partTitle: _partTitleOf(video, pageIndex),
    );
    final done = Completer<void>();
    _completers[key] = done;
    tasks.value = {...tasks.value, key: task};
    _queue.add((
      task: task,
      done: done,
      video: video,
      audioOnly: audioOnly,
    ));
    _pump();
    return done.future;
  }

  /// 下载全部 P（多 P 视频）：逐集入队（内部串行执行），全部结束后 Future
  /// 结束；任一集失败抛首个错误（其余集继续执行）。
  ///
  /// [audioOnly] 语义同 [downloadVideo]（全部 P 都只缓存音频）。
  Future<void> downloadAllPages(
    WhitelistVideo video, {
    bool audioOnly = false,
  }) async {
    final n = video.pageCount;
    final futures = <Future<void>>[];
    for (var i = 0; i < n; i++) {
      futures.add(downloadVideo(video, i, audioOnly: audioOnly));
    }
    await Future.wait(futures, eagerError: false);
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        final task = item.task;
        final key = task.key;
        task.status = DownloadStatus.downloading;
        _notifyTasks();
        try {
          await _runDownload(item.video, task, audioOnly: item.audioOnly);
          task.status = DownloadStatus.completed;
          if (!item.done.isCompleted) item.done.complete();
        } catch (e) {
          task.status = DownloadStatus.failed;
          task.error = '$e';
          if (!item.done.isCompleted) item.done.completeError(e);
        }
        _completers.remove(key);
        _notifyTasks();
        // 串行下载之间留间隔，降低风控概率
        if (betweenTasks > Duration.zero && _queue.isNotEmpty) {
          await Future<void>.delayed(betweenTasks);
        }
      }
    } finally {
      _running = false;
    }
  }

  /// 单集下载：取流 → 下载 video（+audio，或 audioOnly 时只下载音频）→ 写索引。
  Future<void> _runDownload(
    WhitelistVideo video,
    DownloadTask task, {
    required bool audioOnly,
  }) async {
    final pageIndex = task.pageIndex;
    // 1) 实时取流（DASH 双流；无 DASH 降级 mp4 单流）
    final cid = _cidOf(video, pageIndex);
    final result = await _fetchPlayUrl(bvid: video.bvid, cid: cid);

    // 2) 目标文件（.part 半成品下载 → 成功后 rename；失败清理半成品）
    final mediaDir = await _mediaDir();
    final base = '${video.bvid}_p${pageIndex + 1}';
    final String videoUrl;
    final String audioUrl;
    String videoPath;
    String audioPath;
    if (audioOnly) {
      // 仅音频：只挑一条音频流；videoPath 恒为空串（不存在视频文件）。
      // 档位按码率取最小（列表顺序不可信，见 pickLowestBandwidthAudio）。
      final picked = pickLowestBandwidthAudio(result);
      if (picked == null || picked.isEmpty) {
        throw StateError('该视频没有可下载的音频流（${video.bvid}/$cid）');
      }
      videoUrl = '';
      videoPath = '';
      audioUrl = picked;
      audioPath = '${mediaDir.path}/$base.audio.m4s';
    } else {
      final dashVideo = result.dashVideoUrls.isNotEmpty
          ? result.dashVideoUrls.first
          : null;
      final videoStreamUrl = dashVideo ?? result.mp4Url;
      if (videoStreamUrl == null || videoStreamUrl.isEmpty) {
        throw StateError('未拿到可下载的流（${video.bvid}/$cid）');
      }
      videoUrl = videoStreamUrl;
      videoPath =
          '${mediaDir.path}/$base.${dashVideo != null ? 'video.m4s' : 'mp4'}';
      // 整段缓存行为不变：音频仍取第一条（downmix 交给播放器）
      audioUrl =
          result.dashAudioUrls.isEmpty ? '' : result.dashAudioUrls.first;
      audioPath = audioUrl.isEmpty ? '' : '${mediaDir.path}/$base.audio.m4s';
    }

    // 3) 下载（各自失败重试一次，仍失败则清理 .part）
    task.total = -1;
    task.received = 0;
    task.progress = null;
    _notifyTasks();
    if (videoUrl.isNotEmpty) {
      await _downloadTo(videoUrl, videoPath, task);
    }
    if (audioUrl.isNotEmpty) {
      await _downloadTo(audioUrl, audioPath, task);
    }

    // 4) 覆盖式重下：旧记录的**另一个**文件（如「先整段后仅音频」留下的
    //    .video.m4s）已不再被索引引用 → 当场删掉，避免白占空间（不靠
    //    reclaimOrphans 兜底：那要用户手动点，且旧文件会一直计入占用）
    final prev = getCached(video.bvid, pageIndex);
    if (prev != null) {
      if (prev.videoPath.isNotEmpty && prev.videoPath != videoPath) {
        await _deleteIfExists(prev.videoPath);
      }
      if (prev.audioPath.isNotEmpty && prev.audioPath != audioPath) {
        await _deleteIfExists(prev.audioPath);
      }
    }

    // 5) 汇总大小 + 写索引
    final size = (videoPath.isEmpty ? 0 : await File(videoPath).length()) +
        (audioPath.isEmpty ? 0 : await File(audioPath).length());
    final entry = CachedVideo(
      bvid: video.bvid,
      title: video.title,
      cover: video.cover,
      pageIndex: pageIndex,
      partTitle: task.partTitle,
      videoPath: videoPath,
      audioPath: audioPath,
      sizeBytes: size,
      cachedAt: DateTime.now().toUtc(),
      upName: video.upName,
      cid: cid,
      durationMs: _durationMsOf(video, pageIndex),
      audioOnly: audioOnly,
    );
    cached.value = [
      entry,
      ...cached.value.where((c) => c.key != entry.key),
    ]..sort((a, b) => b.cachedAt.compareTo(a.cachedAt));
    await _saveIndex();
  }

  /// 下载到 .part 再 rename 到目标路径；失败清理 .part 并抛错。
  Future<void> _downloadTo(
      String url, String targetPath, DownloadTask task) async {
    final partPath = '$targetPath.part';
    // 登记在途路径：reclaimOrphans 据此跳过（别删正在写的半成品）
    _writing
      ..add(partPath)
      ..add(targetPath);
    try {
      await _downloadWithRetry(url, partPath, task);
      await File(partPath).rename(targetPath);
    } catch (_) {
      await _deleteIfExists(partPath);
      rethrow;
    } finally {
      _writing
        ..remove(partPath)
        ..remove(targetPath);
    }
  }

  /// 单文件下载，失败重试一次（间隔 1s）。
  Future<void> _downloadWithRetry(
      String url, String path, DownloadTask task) async {
    var attempt = 0;
    while (true) {
      try {
        await _downloadFile(url, path, (received, total) {
          task.received = received;
          if (total > 0) task.total = total;
          task.progress = task.total > 0 ? task.received / task.total : null;
          _notifyTasks();
        });
        task.progress = 1.0;
        _notifyTasks();
        return;
      } catch (e) {
        attempt++;
        if (attempt >= 2) rethrow; // 失败重试一次，仍失败抛给上层
        await _deleteIfExists(path); // 清掉半成品再重下
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 删除 / 清理
  // ---------------------------------------------------------------------------

  /// 删除某集缓存：移除索引 + 删除本地文件（文件删除失败静默）。
  Future<void> deleteCache(String bvid, int pageIndex) async {
    final target = getCached(bvid, pageIndex);
    if (target == null) return;
    cached.value =
        cached.value.where((c) => c.key != target.key).toList();
    await _saveIndex();
    await _deleteIfExists(target.videoPath);
    await _deleteIfExists(target.audioPath);
  }

  /// 清空全部缓存（确认由 UI 层负责）。
  Future<void> cleanAllCache() async {
    final items = cached.value;
    cached.value = const [];
    await _saveIndex();
    for (final c in items) {
      await _deleteIfExists(c.videoPath);
      await _deleteIfExists(c.audioPath);
    }
  }

  Future<void> _deleteIfExists(String path) async {
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删除失败静默（索引已移除，文件残留下次清理覆盖）
    }
  }

  // ---------------------------------------------------------------------------
  // 默认实现
  // ---------------------------------------------------------------------------

  /// 默认取流：DASH 双流（fnval=16），无 DASH 降级 mp4（fnval=0）。
  Future<PlayUrlResult> _defaultFetchPlayUrl({
    required String bvid,
    required int cid,
  }) async {
    final api = _api ??= BiliApi();
    var result = await api.fetchPlayUrl(bvid: bvid, cid: cid, qn: 80, fnval: 16);
    if (result.dashVideoUrls.isEmpty) {
      result = await api.fetchPlayUrl(bvid: bvid, cid: cid, qn: 80, fnval: 0);
    }
    if (!result.hasStream) {
      throw StateError('未拿到可下载的流（$bvid/$cid）');
    }
    return result;
  }

  /// 默认下载：独立 dio，仅 Referer + 浏览器 UA（不带 cookie，M0 实测）。
  Future<void> _defaultDownloadFile(
      String url, String savePath, DownloadProgressCallback? onProgress) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        headers: {
          'User-Agent': kBrowserUA,
          'Referer': kBiliReferer,
        },
      ),
    );
    await dio.download(
      url,
      savePath,
      onReceiveProgress: onProgress,
      options: Options(followRedirects: true),
    );
  }

  // ---------------------------------------------------------------------------
  // 辅助
  // ---------------------------------------------------------------------------

  int _cidOf(WhitelistVideo video, int pageIndex) {
    final pages = video.pages;
    if (pages != null && pages.isNotEmpty && pageIndex < pages.length) {
      return pages[pageIndex].cid;
    }
    return video.cid;
  }

  /// 该集时长（毫秒）：多 P 取 pages[pageIndex].duration，否则取顶层 duration。
  /// 拿不到（缺 pages / 越界）时退回顶层 duration，再没有就 0（未知）。
  int _durationMsOf(WhitelistVideo video, int pageIndex) {
    final pages = video.pages;
    if (pages != null && pages.isNotEmpty && pageIndex < pages.length) {
      final sec = pages[pageIndex].duration;
      if (sec > 0) return sec * 1000;
    }
    return video.duration > 0 ? video.duration * 1000 : 0;
  }

  String _partTitleOf(WhitelistVideo video, int pageIndex) {
    final pages = video.pages;
    if (pages != null && pages.isNotEmpty && pageIndex < pages.length) {
      return pages[pageIndex].part;
    }
    return '';
  }

  /// 路径归一（比较「索引引用的路径」与「目录里扫到的路径」时用）：
  /// Windows 上 File 的 path 与 Directory.list 的 path 可能一个反斜杠一个
  /// 正斜杠，直接字符串比较会误判成孤儿 → 全删。统一成 `\` 并去尾分隔符。
  static String _normPath(String p) =>
      p.replaceAll('/', r'\').replaceAll(RegExp(r'\\+$'), '');

  /// 文件长度；不存在/读不到 → 0（不抛）。
  static Future<int> _fileLength(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }
}
