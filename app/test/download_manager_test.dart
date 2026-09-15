// DownloadManager 单元测试：缓存索引读写 / isCached / delete / 清理 /
// 失败清理半成品 / 串行队列 / mp4 单流降级 / 下载全部 P。
// - 不访问真实网络：取流与下载都注入 fake（内存写文件）
// - 用临时目录作根目录，不依赖 path_provider 原生插件
import 'dart:async';
import 'dart:convert';
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

/// 多档音频的取流 fake：**高档在前**（与 B 站实测的顺序不稳定一致），
/// 第三条没有码率信息（验证「缺码率不参与比较」）。
PlayUrlFetcher _multiAudioFetcher() {
  return ({required String bvid, required int cid}) async {
    return const PlayUrlResult(
      quality: 80,
      dashVideoUrls: ['http://fake.bilivideo.com/video.m4s'],
      dashAudioUrls: [
        'http://fake.bilivideo.com/a134.m4s',
        'http://fake.bilivideo.com/a64.m4s',
        'http://fake.bilivideo.com/a-unknown.m4s',
      ],
      dashAudioIds: [30232, 30216, 30280],
      dashAudioBandwidths: [134000, 64000, 0],
    );
  };
}

/// 没有任何码率信息的取流 fake（旧解析/第三方响应）：退回第一条。
PlayUrlFetcher _noBandwidthFetcher() {
  return ({required String bvid, required int cid}) async {
    return const PlayUrlResult(
      quality: 80,
      dashVideoUrls: ['http://fake.bilivideo.com/video.m4s'],
      dashAudioUrls: [
        'http://fake.bilivideo.com/first.m4s',
        'http://fake.bilivideo.com/second.m4s',
      ],
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

  // ---------------------------------------------------------------------------
  // v2.29.0：仅音频缓存 / 音频档位选择 / 旧索引兼容 / 占用与回收
  // ---------------------------------------------------------------------------

  group('仅缓存音频（audioOnly）', () {
    test('只请求音频流、不写视频文件，索引 videoPath 空 + audioOnly true', () async {
      final dl = _FakeDownloader();
      final m = buildManager(dl: dl);

      await m.downloadVideo(_video(bvid: 'BV1audio'), 0, audioOnly: true);

      expect(dl.urls, ['http://fake.bilivideo.com/audio.m4s'],
          reason: '仅音频：一次请求，只要音频流');
      final c = m.getCached('BV1audio', 0)!;
      expect(c.audioOnly, isTrue);
      expect(c.videoPath, isEmpty, reason: '仅音频缓存不存在视频文件');
      expect(c.audioPath, endsWith('BV1audio_p1.audio.m4s'));
      expect(c.sizeBytes, 1000, reason: '只算音频大小');
      expect(await File(c.audioPath).exists(), isTrue);
      // 目录里只能有音频那一个文件（没有视频、没有 .part）
      final files = Directory('${tmp.path}/video_cache')
          .listSync()
          .map((e) => e.path.split(RegExp(r'[/\\]')).last)
          .toList();
      expect(files, ['BV1audio_p1.audio.m4s']);
      // cid / 时长也落进索引（离线页构造 WhitelistVideo 要用）
      expect(c.cid, 100);
      expect(c.durationMs, 60000);
    });

    test('音频档位挑 bandwidth 最小的一条（顺序不可信）', () async {
      final dl = _FakeDownloader();
      final m = buildManager(fetcher: _multiAudioFetcher(), dl: dl);

      await m.downloadVideo(_video(), 0, audioOnly: true);

      expect(dl.urls, ['http://fake.bilivideo.com/a64.m4s'],
          reason: '134kbps 在列表首位，但 64kbps 才是最小档');
    });

    test('音频码率信息缺失 → 退回第一条（与改动前一致）', () async {
      final dl = _FakeDownloader();
      final m = buildManager(fetcher: _noBandwidthFetcher(), dl: dl);

      await m.downloadVideo(_video(), 0, audioOnly: true);

      expect(dl.urls, ['http://fake.bilivideo.com/first.m4s']);
    });

    test('下载全部 P 也可以只要音频', () async {
      final dl = _FakeDownloader();
      final m = buildManager(dl: dl);

      await m.downloadAllPages(_multiPageVideo(), audioOnly: true);

      expect(m.cachedCount('BV1multi'), 3);
      expect(m.getCachedList().every((c) => c.audioOnly), isTrue);
      expect(dl.urls.length, 3, reason: '3 集 × 1 条音频流');
      // 只请求音频流（注意宿主名 bilivideo.com 里也含 "video"，
      // 不能用 contains('video') 判定）
      expect(dl.urls.toSet(), {'http://fake.bilivideo.com/audio.m4s'});
    });

    test('视频没有音频流 → 仅音频下载失败且不写索引', () async {
      final m = buildManager(fetcher: _mp4Fetcher());

      await expectLater(
        m.downloadVideo(_video(), 0, audioOnly: true),
        throwsA(isA<StateError>()),
      );
      expect(m.isCached('BV1test', 0), isFalse);
      expect(m.tasks.value['BV1test#0']!.status, DownloadStatus.failed);
    });

    test('整段缓存过的集改成仅音频：旧的 .video.m4s 当场删掉', () async {
      final m = buildManager();
      await m.downloadVideo(_video(), 0);
      final videoPath = m.getCached('BV1test', 0)!.videoPath;
      expect(await File(videoPath).exists(), isTrue);

      await m.downloadVideo(_video(), 0, audioOnly: true);

      final c = m.getCached('BV1test', 0)!;
      expect(c.audioOnly, isTrue);
      expect(await File(videoPath).exists(), isFalse,
          reason: '覆盖式重下：不再被索引引用的视频文件必须清掉');
      expect(c.sizeBytes, 1000);
    });

    test('删除仅音频缓存不报错（videoPath 为空是正常态）', () async {
      final m = buildManager();
      await m.downloadVideo(_video(), 0, audioOnly: true);
      final audioPath = m.getCached('BV1test', 0)!.audioPath;

      await m.deleteCache('BV1test', 0);

      expect(m.getCached('BV1test', 0), isNull);
      expect(await File(audioPath).exists(), isFalse);
      expect(m.totalCacheSize(), 0);
    });

    test('混合状态（整段 + 仅音频）：总大小 / 单删 / 全清都正确', () async {
      final m = buildManager();
      await m.downloadVideo(_video(bvid: 'BV1full'), 0); // 1000 + 1000
      await m.downloadVideo(_video(bvid: 'BV1only'), 0, audioOnly: true); // 1000

      expect(m.totalCacheSize(), 3000);
      final onlyAudio = m.getCached('BV1only', 0)!;
      expect(m.cachedAllAudioOnly('BV1only'), isTrue);
      expect(m.cachedAllAudioOnly('BV1full'), isFalse);
      expect(m.cachedAllAudioOnly('BV1missing'), isFalse);

      await m.deleteCache('BV1only', 0);
      expect(m.totalCacheSize(), 2000);
      expect(await File(onlyAudio.audioPath).exists(), isFalse);

      await m.cleanAllCache();
      expect(m.getCachedList(), isEmpty);
      expect(m.totalCacheSize(), 0);
      final leftover = Directory('${tmp.path}/video_cache').listSync();
      expect(leftover, isEmpty, reason: '全清后媒体目录不应残留文件');
    });
  });

  group('旧索引兼容（v2.28 及以前没有 audioOnly/cid/durationMs）', () {
    test('缺字段按默认值读：audioOnly false / cid 0 / durationMs 0', () async {
      // 手工写一份旧格式索引（只有 v2.28 及以前的字段）
      final mediaDir = Directory('${tmp.path}/video_cache');
      await mediaDir.create(recursive: true);
      final video = File('${mediaDir.path}/BV1legacy_p1.video.m4s');
      final audio = File('${mediaDir.path}/BV1legacy_p1.audio.m4s');
      await video.writeAsBytes(List.filled(10, 1));
      await audio.writeAsBytes(List.filled(10, 1));
      await File('${tmp.path}/cache_index.json').writeAsString(jsonEncode({
        'version': 1,
        'items': [
          {
            'bvid': 'BV1legacy',
            'title': '旧索引',
            'cover': '',
            'pageIndex': 0,
            'partTitle': '',
            'videoPath': video.path,
            'audioPath': audio.path,
            'sizeBytes': 20,
            'cachedAt': '2026-01-01T00:00:00.000Z',
            'upName': 'up主',
          },
        ],
      }));

      final m = buildManager();
      await m.init();

      final c = m.getCached('BV1legacy', 0)!;
      expect(c.audioOnly, isFalse, reason: '旧索引没有该字段 → 默认 false（有画面）');
      expect(c.cid, 0);
      expect(c.durationMs, 0);
      expect(m.isCached('BV1legacy', 0), isTrue);
      expect(c.playablePath, video.path, reason: '非仅音频 → 离线源就是视频文件');
      // 旧索引条目照常可删（v2.29 的清理路径不会回退）
      await m.deleteCache('BV1legacy', 0);
      expect(m.getCachedList(), isEmpty);
    });

    test('索引里的 sizeBytes 记 0（旧脏数据）也不影响展示兜底', () async {
      final c = CachedVideo.fromJson({
        'bvid': 'BV1x',
        'videoPath': '/tmp/v.m4s',
        'audioPath': '',
        'cachedAt': 'not-a-date',
      });
      expect(c.sizeBytes, 0);
      expect(c.pageIndex, 0);
      expect(c.audioOnly, isFalse);
      // cachedAt 解析失败 → 退回 now（不抛），照旧可读
      expect(c.cachedAt.year, greaterThan(2000));
    });
  });

  group('占用统计与回收（diskUsage / reclaimOrphans）', () {
    test('分项占用：媒体（索引内）+ 中转音频 + 残留，各自独立计数', () async {
      final m = buildManager();
      await m.downloadVideo(_video(), 0); // video_cache 1000 + 1000
      final mediaDir = Directory('${tmp.path}/video_cache');
      // 残留：一个孤儿文件 + 一个 .part
      await File('${mediaDir.path}/BV1ghost_p1.video.m4s')
          .writeAsBytes(List.filled(300, 1));
      await File('${mediaDir.path}/BV1half_p1.audio.m4s.part')
          .writeAsBytes(List.filled(100, 1));
      // 中转音频（audio_tmp：转写的临时 m4s + 16k wav）
      final tmpDir = Directory('${tmp.path}/audio_tmp');
      await tmpDir.create(recursive: true);
      await File('${tmpDir.path}/BV1test_0.m4s').writeAsBytes(List.filled(200, 1));
      await File('${tmpDir.path}/BV1test_0_16k.wav')
          .writeAsBytes(List.filled(600, 1));

      final usage = await m.diskUsage();

      expect(usage.mediaBytes, 2000);
      expect(usage.tmpAudioBytes, 800);
      expect(usage.orphanBytes, 400);
      expect(usage.orphanCount, 2);
      expect(usage.totalBytes, 3200);
      expect(usage.hasOrphans, isTrue);
      expect(usage.hasTmpAudio, isTrue);
    });

    test('reclaimOrphans：删孤儿与 .part，不删索引内文件、不动 audio_tmp', () async {
      final m = buildManager();
      await m.downloadVideo(_video(), 0);
      final c = m.getCached('BV1test', 0)!;
      final mediaDir = Directory('${tmp.path}/video_cache');
      final ghost = File('${mediaDir.path}/BV1ghost_p1.video.m4s');
      final part = File('${mediaDir.path}/BV1half_p1.audio.m4s.part');
      await ghost.writeAsBytes(List.filled(300, 1));
      await part.writeAsBytes(List.filled(100, 1));
      final tmpDir = Directory('${tmp.path}/audio_tmp');
      await tmpDir.create(recursive: true);
      final tmpAudio = File('${tmpDir.path}/BV1test_0.m4s');
      await tmpAudio.writeAsBytes(List.filled(200, 1));

      final result = await m.reclaimOrphans();

      expect(result.files, 2);
      expect(result.bytes, 400);
      expect(await ghost.exists(), isFalse);
      expect(await part.exists(), isFalse, reason: '崩溃留下的 .part 必须能回收');
      expect(await File(c.videoPath).exists(), isTrue, reason: '索引内文件不能删');
      expect(await File(c.audioPath).exists(), isTrue);
      expect(await tmpAudio.exists(), isTrue, reason: 'audio_tmp 不归它管');
      expect(m.getCachedList().length, 1, reason: '索引不受影响');

      // 幂等：没有残留时返回 0，不误删任何东西
      final again = await m.reclaimOrphans();
      expect(again.files, 0);
      expect(await File(c.videoPath).exists(), isTrue);
    });

    test('仅音频条目（videoPath 空）不产生「假孤儿」', () async {
      final m = buildManager();
      await m.downloadVideo(_video(), 0, audioOnly: true);

      final usage = await m.diskUsage();

      expect(usage.mediaBytes, 1000);
      expect(usage.orphanCount, 0, reason: '空 videoPath 不能被当成孤儿路径');
      final result = await m.reclaimOrphans();
      expect(result.files, 0);
      expect(m.isCached('BV1test', 0), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // v2.29.0：启动预热（main() 里 unawaited 调一次 init）——幂等 + 失败静默
  // ---------------------------------------------------------------------------

  group('init() 供启动预热复用：幂等 + 失败静默', () {
    test('幂等：重复 init 只读一次盘（预热先跑过，页面再 init 不会重读）', () async {
      await manager.downloadVideo(_video(), 0); // 落一份索引到磁盘

      final fresh = buildManager(); // 同根目录的新实例（索引还没进内存）
      await fresh.init();
      expect(fresh.getCachedList(), hasLength(1), reason: '第一次 init 读到索引');

      // 把盘上的索引改成「空的/坏掉的」：第二次 init 若真的重读，列表就会变空
      await File('${tmp.path}/cache_index.json').writeAsString('{"items": []}');
      await fresh.init();

      expect(fresh.getCachedList(), hasLength(1),
          reason: '第二次 init 应直接返回（幂等），以内存为准');
    });

    test('失败静默：索引损坏 / 读不到都不抛，按空索引处理', () async {
      // 索引文件内容不是合法 JSON（写坏/断电截断的现场）
      await File('${tmp.path}/cache_index.json').writeAsString('{这不是 JSON');
      await expectLater(manager.init(), completes);
      expect(manager.getCachedList(), isEmpty);

      // 根目录指向一个不存在的路径（取不到应用目录的等价现场）：同样不抛
      final broken = DownloadManager(
        rootDir: Directory('${tmp.path}/nope/deeper'),
        betweenTasks: Duration.zero,
        retryDelay: Duration.zero,
      );
      await expectLater(broken.init(), completes);
      expect(broken.getCachedList(), isEmpty);
    });
  });
}
