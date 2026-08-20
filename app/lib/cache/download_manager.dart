import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/bilibili_api.dart';
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
  final String videoPath; // 本地视频文件绝对路径
  final String audioPath; // 本地音频文件绝对路径；单流（mp4）为空串
  final int sizeBytes; // 文件总字节数
  final DateTime cachedAt;
  final String upName;

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
  });

  factory CachedVideo.fromJson(Map<String, dynamic> json) {
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
      };

  /// 缓存键：`bvid#pageIndex`。
  static String keyOf(String bvid, int pageIndex) => '$bvid#$pageIndex';

  String get key => keyOf(bvid, pageIndex);
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

/// 视频离线缓存下载管理器（单例）。
///
/// 职责：
/// - 下载：实时取 playurl（DASH 双流 video+audio，无 DASH 降级 mp4 单流），
///   带 Referer + 浏览器 UA 下载（不带 cookie，M0 实测）；流 URL 数分钟过期
///   只影响在线取流，数据本身可下载保存
/// - 串行队列：同时只允许一个下载（B 站对高频请求风控，串行 + 任务间隔更稳），
///   单文件失败自动重试一次
/// - 持久化：媒体文件存应用文档目录 `video_cache/`，元数据 `cache_index.json`
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

  final List<({DownloadTask task, Completer<void> done, WhitelistVideo video})>
      _queue = [];
  final Map<String, Completer<void>> _completers = {};
  bool _running = false;
  bool _indexLoaded = false;

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

  /// 全部缓存记录（按缓存时间倒序）。
  List<CachedVideo> getCachedList() => List.unmodifiable(cached.value);

  /// 缓存总字节数。
  int totalCacheSize() => cached.value.fold(0, (sum, c) => sum + c.sizeBytes);

  // ---------------------------------------------------------------------------
  // 下载（串行队列）
  // ---------------------------------------------------------------------------

  /// 下载指定集：入队（已在该集的下载队列/下载中时直接返回同一 Future；
  /// 已缓存也可重新下载，会覆盖旧文件）。任务完成时 Future 正常结束，
  /// 失败时 Future 抛错（调用方可 catch 提示）。
  Future<void> downloadVideo(WhitelistVideo video, int pageIndex) {
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
    _queue.add((task: task, done: done, video: video));
    _pump();
    return done.future;
  }

  /// 下载全部 P（多 P 视频）：逐集入队（内部串行执行），全部结束后 Future
  /// 结束；任一集失败抛首个错误（其余集继续执行）。
  Future<void> downloadAllPages(WhitelistVideo video) async {
    final n = video.pageCount;
    final futures = <Future<void>>[];
    for (var i = 0; i < n; i++) {
      futures.add(downloadVideo(video, i));
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
          await _runDownload(item.video, task);
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

  /// 单集下载：取流 → 下载 video（+audio）→ 写索引。
  Future<void> _runDownload(WhitelistVideo video, DownloadTask task) async {
    final pageIndex = task.pageIndex;
    // 1) 实时取流（DASH 双流；无 DASH 降级 mp4 单流）
    final cid = _cidOf(video, pageIndex);
    final result = await _fetchPlayUrl(bvid: video.bvid, cid: cid);
    final dashVideo = result.dashVideoUrls.isNotEmpty
        ? result.dashVideoUrls.first
        : null;
    final videoUrl = dashVideo ?? result.mp4Url;
    if (videoUrl == null || videoUrl.isEmpty) {
      throw StateError('未拿到可下载的流（${video.bvid}/$cid）');
    }
    final audioUrl =
        result.dashAudioUrls.isEmpty ? null : result.dashAudioUrls.first;

    // 2) 目标文件（.part 半成品下载 → 成功后 rename；失败清理半成品）
    final mediaDir = await _mediaDir();
    final base = '${video.bvid}_p${pageIndex + 1}';
    final videoPath =
        '${mediaDir.path}/$base.${dashVideo != null ? 'video.m4s' : 'mp4'}';
    final audioPath =
        audioUrl == null ? '' : '${mediaDir.path}/$base.audio.m4s';

    // 3) 下载 video / audio（各自失败重试一次，仍失败则清理 .part）
    task.total = -1;
    task.received = 0;
    task.progress = null;
    _notifyTasks();
    await _downloadTo(videoUrl, videoPath, task);
    if (audioUrl != null) {
      await _downloadTo(audioUrl, audioPath, task);
    }

    // 4) 汇总大小 + 写索引
    final size = await File(videoPath).length() +
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
    try {
      await _downloadWithRetry(url, partPath, task);
      await File(partPath).rename(targetPath);
    } catch (_) {
      await _deleteIfExists(partPath);
      rethrow;
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

  String _partTitleOf(WhitelistVideo video, int pageIndex) {
    final pages = video.pages;
    if (pages != null && pages.isNotEmpty && pageIndex < pages.length) {
      return pages[pageIndex].part;
    }
    return '';
  }
}
