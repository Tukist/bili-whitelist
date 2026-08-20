// DownloadManager 单元测试：缓存索引读写 / isCached / delete / 清理 /
// 失败清理半成品 / 串行队列 / mp4 单流降级 / 下载全部 P。
// - 不访问真实网络：取流与下载都注入 fake（内存写文件）
// - 用临时目录作根目录，不依赖 path_provider 原生插件
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';

/// 单 P 视频（DASH 双流测试用）。
WhitelistVideo _video({
  String bvid = 'BV1test',
  int cid = 100,
  String title = '测试视频',
  List<PageInfo>? pages,
}) {
  return WhitelistVideo(
    bvid: bvid,
    cid: cid,
    title: title,
    cover: '',
    duration: 60,
    upName: 'up主',
    addedAt: '2026-01-01T00:00:00Z',
    pages: pages,
  );
}

/// 多 P 视频：3 集。
WhitelistVideo _multiPageVideo() {
  return _video(
    bvid: 'BV1multi',
    cid: 1000,
    pages: const [
      PageInfo(cid: 1001, part: '第一集', duration: 60),
      PageInfo(cid: 1002, part: '第二集', duration: 60),
      PageInfo(cid: 1003, part: '第三集', duration: 60),
    ],
  );
}

/// 固定返回 DASH 双流的取流 fake。
PlayUrlFetcher _dashFetcher() {
  return ({required String bvid, required int cid}) async {
    return const PlayUrlResult(
      quality: 80,
      dashVideoUrls: ['http://fake.bilivideo.com/video.m4s'],
      dashAudioUrls: ['http://fake.bilivideo.com/audio.m4s'],
    );
  };
}

/// 只返回 mp4 单流的取流 fake（老视频降级）。
PlayUrlFetcher _mp4Fetcher() {
  return ({required String bvid, required int cid}) async {
    return const PlayUrlResult(
      quality: 32,
      mp4Url: 'http://fake.bilivideo.com/video.mp4',
    );
  };
}

/// 可手动打开的闸门：下载器进入时阻塞，直到 [open]；首个进入记录 firstEntered，
/// 供测试同步等待「下载已启动」。
class CompleterGate {
  final firstEntered = Completer<void>();
  Completer<void>? _gate;

  Future<void> enter() async {
    if (!firstEntered.isCompleted) firstEntered.complete();
    _gate ??= Completer<void>();
    await _gate!.future;
  }

  void open() {
    _gate?.complete();
  }
}

/// 下载 fake：写 [payloadBytes] 字节到目标文件，回调进度；可指定失败的 url
/// 集合（[failUrls]）、失败次数（[failTimes] 后恢复；null = 永远失败）、
/// 阻塞闸门（[gate]）、并发监控（[maxActive]）。
class _FakeDownloader {
  /// 固定写 1000 字节（测试未覆盖场景统一用该值）。
  final int payloadBytes = 1000;
  final Set<String> failUrls;
  final int? failTimes;
  final CompleterGate? gate;
  final List<String> urls = [];
  int _fails = 0;
  int active = 0;
  int maxActive = 0;

  _FakeDownloader({
    this.failUrls = const {},
    this.failTimes,
    this.gate,
  });

  Future<void> call(
      String url, String savePath, DownloadProgressCallback? onProgress) async {
    urls.add(url);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (gate != null) await gate!.enter(); // 阻塞直到测试放行
      if (failUrls.contains(url)) {
        _fails++;
        final times = failTimes; // int? 局部提升后可与 int 比较
        if (times == null || _fails <= times) {
          throw SocketException('模拟下载失败: $url');
        }
      }
      // 先写 .part 的一半 → 回调进度 → 写满
      final f = File(savePath);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List.filled(payloadBytes ~/ 2, 1), flush: true);
      onProgress?.call(payloadBytes ~/ 2, payloadBytes);
      await f.writeAsBytes(List.filled(payloadBytes, 1), flush: true);
      onProgress?.call(payloadBytes, payloadBytes);
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late DownloadManager manager;

  DownloadManager buildManager({
    PlayUrlFetcher? fetcher,
    _FakeDownloader? dl,
  }) {
    final downloader = dl ?? _FakeDownloader();
    return DownloadManager(
      fetchPlayUrl: fetcher ?? _dashFetcher(),
      downloadFile: (url, savePath, onProgress) =>
          downloader.call(url, savePath, onProgress),
      rootDir: tmp,
      betweenTasks: Duration.zero,
      retryDelay: Duration.zero,
    );
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dm_test_');
    manager = buildManager();
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不阻塞
    }
  });

  test('下载成功：写文件 + 写索引 + isCached true + sizeBytes 正确', () async {
    await manager.downloadVideo(_video(), 0);

    expect(manager.isCached('BV1test', 0), isTrue);
    final c = manager.getCached('BV1test', 0);
    expect(c, isNotNull);
    expect(c!.videoPath, endsWith('BV1test_p1.video.m4s'));
    expect(c.audioPath, endsWith('BV1test_p1.audio.m4s'));
    expect(c.sizeBytes, 2000); // video 1000 + audio 1000
    expect(c.partTitle, '');
    expect(await File(c.videoPath).exists(), isTrue);
    expect(await File(c.audioPath).exists(), isTrue);
    // 无 .part 半成品残留
    expect(await File('${c.videoPath}.part').exists(), isFalse);
    expect(manager.totalCacheSize(), 2000);
  });

  test('索引持久化：重建 manager（同根目录）后缓存仍在', () async {
    await manager.downloadVideo(_video(), 0);

    final manager2 = buildManager();
    await manager2.init(); // 索引需显式加载
    expect(manager2.isCached('BV1test', 0), isTrue);
    expect(manager2.getCachedList().single.title, '测试视频');
  });

  test('mp4 单流降级：audioPath 为空、文件后缀 .mp4', () async {
    final m = buildManager(fetcher: _mp4Fetcher());
    await m.downloadVideo(_video(), 0);

    final c = m.getCached('BV1test', 0)!;
    expect(c.videoPath, endsWith('BV1test_p1.mp4'));
    expect(c.audioPath, isEmpty);
    expect(c.sizeBytes, 1000);
  });

  test('deleteCache：索引移除 + 文件删除 + isCached false', () async {
    await manager.downloadVideo(_video(), 0);
    final c = manager.getCached('BV1test', 0)!;

    await manager.deleteCache('BV1test', 0);

    expect(manager.isCached('BV1test', 0), isFalse);
    expect(manager.getCachedList(), isEmpty);
    expect(await File(c.videoPath).exists(), isFalse);
    expect(await File(c.audioPath).exists(), isFalse);
    expect(manager.totalCacheSize(), 0);
  });

  test('cleanAllCache：全部清理', () async {
    await manager.downloadVideo(_video(bvid: 'BV1a'), 0);
    await manager.downloadVideo(_video(bvid: 'BV1b'), 0);

    await manager.cleanAllCache();

    expect(manager.getCachedList(), isEmpty);
    expect(manager.totalCacheSize(), 0);
  });

  test('下载失败：任务 failed、清理 .part、不写索引、Future 抛错', () async {
    final failing = _FakeDownloader(
        failUrls: {'http://fake.bilivideo.com/video.m4s'}, failTimes: null);
    final m = buildManager(dl: failing);

    await expectLater(m.downloadVideo(_video(), 0), throwsA(anything));

    expect(m.isCached('BV1test', 0), isFalse);
    expect(m.getCachedList(), isEmpty);
    final task = m.tasks.value['BV1test#0'];
    expect(task!.status, DownloadStatus.failed);
    expect(task.error, contains('模拟下载失败'));
    // 半成品清理
    final dir = Directory('${tmp.path}/video_cache');
    final leftover = dir
        .listSync()
        .where((f) => f.path.endsWith('.part'))
        .toList();
    expect(leftover, isEmpty, reason: '失败后不应残留 .part 半成品');
  });

  test('失败重试一次：首次抛错第二次成功', () async {
    final flaky = _FakeDownloader(
        failTimes: 1, failUrls: {'http://fake.bilivideo.com/video.m4s'});
    final m = buildManager(dl: flaky);

    await m.downloadVideo(_video(), 0);

    expect(m.isCached('BV1test', 0), isTrue, reason: '重试一次后应成功');
    final videoCalls =
        flaky.urls.where((u) => u.contains('video.m4s')).length;
    expect(videoCalls, 2, reason: 'video 文件应下载两次（首次失败 + 重试）');
  });

  test('串行队列：同时只允许一个下载', () async {
    // 第一个下载阻塞在闸门上，第二个入队等待；断言并发数始终为 1
    final gate = CompleterGate();
    final dl = _FakeDownloader(gate: gate);
    final m = buildManager(dl: dl);

    final f1 = m.downloadVideo(_video(bvid: 'BV1a'), 0);
    final f2 = m.downloadVideo(_video(bvid: 'BV1b'), 0);

    // 等第一个下载真正启动（进入闸门阻塞）
    await gate.firstEntered.future.timeout(const Duration(seconds: 2));
    expect(dl.maxActive, 1, reason: '串行：第一个下载进行中，第二个必须排队');

    // 第二个任务此时应处于 queued（未并发）
    final t2 = m.tasks.value['BV1b#0'];
    expect(t2!.status, DownloadStatus.queued);

    gate.open();
    await f1;
    await f2;

    expect(dl.maxActive, 1, reason: '全程不应出现并发下载');
    expect(m.isCached('BV1a', 0), isTrue);
    expect(m.isCached('BV1b', 0), isTrue);
  });

  test('downloadAllPages：多 P 逐集下载全部缓存', () async {
    await manager.downloadAllPages(_multiPageVideo());

    expect(manager.cachedCount('BV1multi'), 3);
    final parts = manager.getCachedList().map((c) => c.partTitle).toSet();
    expect(parts, {'第一集', '第二集', '第三集'});
  });

  test('同集重复下载去重：下载中再次调用返回同一 Future，不重复入队', () async {
    final gate = CompleterGate();
    final dl = _FakeDownloader(gate: gate);
    final m = buildManager(dl: dl);

    final f1 = m.downloadVideo(_video(), 0);
    await gate.firstEntered.future.timeout(const Duration(seconds: 2));
    final f2 = m.downloadVideo(_video(), 0); // 下载中重复调用

    expect(identical(f1, f2), isTrue, reason: '下载中重复调用应返回同一 Future');
    gate.open();
    await f1;
    expect(dl.urls.length, 2, reason: '去重：只下载一次（video+audio）');
  });

  test('重新下载（已缓存）：任务重新入队覆盖旧文件', () async {
    await manager.downloadVideo(_video(), 0);
    final oldPath = manager.getCached('BV1test', 0)!.videoPath;

    await manager.downloadVideo(_video(), 0); // 重新下载

    expect(manager.isCached('BV1test', 0), isTrue);
    expect(manager.getCached('BV1test', 0)!.videoPath, oldPath);
  });
}
