// Transcriber 相关单元测试：转写缓存读写/损坏容错、segments→cues 转换、
// 模型 ensureModel（存在跳过/下载/失败分类）、音频路径选择（缓存优先 vs
// 临时下载）、转写编排（缓存命中/并发控制/取消/错误分类）。
//
// - 不访问真实网络、不加载原生 whisper 库：全部注入 fake + 临时目录
// - whisper_ggml 无法在单测真实跑，这里测我们自己实现的
//   转换/缓存/错误分类/编排层（构造 fake segments 数据）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_ggml/whisper_ggml.dart' show WhisperTranscribeSegment;

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/whisper_audio.dart';
import 'package:bili_whitelist_app/api/whisper_model.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/subtitle.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/transcriber.dart';
import 'package:bili_whitelist_app/services/transcription_cache.dart';

/// 单 P 视频。
WhitelistVideo _video({
  String bvid = 'BV1test',
  int cid = 100,
  List<PageInfo>? pages,
}) {
  return WhitelistVideo(
    bvid: bvid,
    cid: cid,
    title: '测试视频',
    cover: '',
    duration: 60,
    upName: 'up主',
    addedAt: '2026-01-01T00:00:00Z',
    pages: pages,
  );
}

/// 可手动放行的闸门（首个进入记录 firstEntered，供测试同步等待）。
class CompleterGate {
  final firstEntered = Completer<void>();
  Completer<void>? _gate;

  Future<void> enter() async {
    if (!firstEntered.isCompleted) firstEntered.complete();
    _gate ??= Completer<void>();
    await _gate!.future;
  }

  void open() => _gate?.complete();
}

/// 模型管理器替身：默认「就绪」，可配置 ensureModel 抛错/计数。
class _FakeModelManager extends WhisperModelManager {
  _FakeModelManager({this.ensureError}) : super();

  final WhisperModelException? ensureError;
  int ensureCalls = 0;

  @override
  Future<String> ensureModel({ValueChanged<double>? onProgress}) async {
    ensureCalls++;
    if (ensureError != null) throw ensureError!;
    return '/fake/ggml-base.bin';
  }

  @override
  Future<bool> isModelReady() async => true;
}

/// 音频源替身：固定返回 [path]，可计数。
class _FakeAudioSource extends WhisperAudioSource {
  _FakeAudioSource({required this.path}) : super(downloadManager: DownloadManager());

  final String path;
  int calls = 0;

  @override
  Future<String> getAudioPath(WhitelistVideo video, int pageIndex) async {
    calls++;
    return path;
  }
}

/// 模型下载 fake：写 [writeBytes] 字节到目标文件；[failWith] 非空则每次抛。
class _ModelDownloaderFake {
  _ModelDownloaderFake({this.failWith, this.writeBytes = 1000});

  final Object? failWith;
  final int writeBytes;
  int calls = 0;
  final List<double> progress = [];

  Future<void> call(
      String url, String savePath, void Function(double)? onProgress) async {
    calls++;
    if (failWith != null) throw failWith!;
    final f = File(savePath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List.filled(writeBytes, 1));
    onProgress?.call(1.0);
  }
}

/// 音频文件下载 fake：写 1000 字节到目标文件，可记录 URL。
class _AudioDownloaderFake {
  final List<String> urls = [];

  Future<void> call(
      String url, String savePath, DownloadProgressCallback? onProgress) async {
    urls.add(url);
    final f = File(savePath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List.filled(1000, 1));
    onProgress?.call(1000, 1000);
  }
}

/// 固定 DASH 双流的取流 fake。
PlayUrlFetcher _dashFetcher({String audioUrl = 'http://fake.bilivideo.com/audio.m4s'}) {
  return ({required String bvid, required int cid}) async {
    return PlayUrlResult(
      quality: 80,
      dashVideoUrls: const ['http://fake.bilivideo.com/video.m4s'],
      dashAudioUrls: [audioUrl],
    );
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('transcriber_test_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // 临时目录清理失败不阻塞
    }
  });

  // -------------------------------------------------------------------------
  // 转写结果缓存
  // -------------------------------------------------------------------------
  group('TranscriptionCache', () {
    test('save 后 getCached 读回一致（from/to/content）', () async {
      final cache = TranscriptionCache(rootDir: tmp);
      const cues = [
        SubtitleCue(from: 1.5, to: 3.2, content: '第一句'),
        SubtitleCue(from: 4.0, to: 6.0, content: '第二句'),
      ];

      await cache.save('BV1a', 0, cues);
      final read = await cache.getCached('BV1a', 0);

      expect(read, isNotNull);
      expect(read!.length, 2);
      expect(read[0].from, 1.5);
      expect(read[0].to, 3.2);
      expect(read[0].content, '第一句');
      expect(read[1].content, '第二句');
      // 文件落在 <root>/transcription_cache/transcription_<bvid>_<idx>.json
      final f = File('${tmp.path}/transcription_cache/transcription_BV1a_0.json');
      expect(await f.exists(), isTrue);
    });

    test('不同集互不串（bvid+pageIndex 为键）', () async {
      final cache = TranscriptionCache(rootDir: tmp);
      await cache.save('BV1a', 0, const [SubtitleCue(from: 0, to: 1, content: 'a')]);
      await cache.save('BV1a', 1, const [SubtitleCue(from: 0, to: 1, content: 'b')]);

      expect((await cache.getCached('BV1a', 0))!.single.content, 'a');
      expect((await cache.getCached('BV1a', 1))!.single.content, 'b');
      expect(await cache.getCached('BV1b', 0), isNull);
    });

    test('文件不存在 → null', () async {
      final cache = TranscriptionCache(rootDir: tmp);
      expect(await cache.getCached('BV1none', 0), isNull);
    });

    test('损坏 JSON（非法文本）→ null，不抛异常', () async {
      final f = File('${tmp.path}/transcription_cache/transcription_BV1x_0.json');
      await f.parent.create(recursive: true);
      await f.writeAsString('{{{ 不是合法 JSON');
      final cache = TranscriptionCache(rootDir: tmp);
      expect(await cache.getCached('BV1x', 0), isNull);
    });

    test('顶层非 List → null', () async {
      final f = File('${tmp.path}/transcription_cache/transcription_BV1x_0.json');
      await f.parent.create(recursive: true);
      await f.writeAsString('{"from": 1, "to": 2}');
      final cache = TranscriptionCache(rootDir: tmp);
      expect(await cache.getCached('BV1x', 0), isNull);
    });

    test('单条字段异常跳过，其余保留', () async {
      final f = File('${tmp.path}/transcription_cache/transcription_BV1x_0.json');
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode([
        {'from': 0.0, 'to': 1.0, 'content': '好'},
        {'from': 1.0, 'to': 2.0, 'content': ''}, // 空内容 → 跳过
        {'from': 'x', 'to': 2.0, 'content': '坏'}, // 类型异常 → 跳过
      ]));
      final cache = TranscriptionCache(rootDir: tmp);
      final cues = await cache.getCached('BV1x', 0);
      expect(cues!.single.content, '好');
    });

    test('空 cues 不写文件', () async {
      final cache = TranscriptionCache(rootDir: tmp);
      await cache.save('BV1e', 0, const []);
      final f = File('${tmp.path}/transcription_cache/transcription_BV1e_0.json');
      expect(await f.exists(), isFalse);
    });

    test('clear 删除缓存文件；文件不存在时静默成功', () async {
      final cache = TranscriptionCache(rootDir: tmp);
      await cache.save('BV1c', 0, const [SubtitleCue(from: 0, to: 1, content: 'a')]);
      expect(await cache.getCached('BV1c', 0), isNotNull);

      await cache.clear('BV1c', 0);
      expect(await cache.getCached('BV1c', 0), isNull);

      // 文件不存在 / 其它集不受影响
      await cache.clear('BV1c', 0);
      await cache.clear('BV1none', 5);
      expect(await cache.getCached('BV1c', 1), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // whisper segments → SubtitleCue 转换
  // -------------------------------------------------------------------------
  group('segmentsToCues', () {
    test('fromTs/toTs 毫秒 → 秒；content 去首尾空白', () {
      const segments = [
        WhisperTranscribeSegment(
          fromTs: Duration(milliseconds: 1230),
          toTs: Duration(milliseconds: 3450),
          text: ' 你好，世界 ',
        ),
      ];
      final cues = segmentsToCues(segments);
      expect(cues.single.from, 1.23);
      expect(cues.single.to, 3.45);
      expect(cues.single.content, '你好，世界');
    });

    test('空文本段跳过', () {
      const segments = [
        WhisperTranscribeSegment(
          fromTs: Duration(seconds: 1),
          toTs: Duration(seconds: 2),
          text: '有效内容',
        ),
        WhisperTranscribeSegment(
          fromTs: Duration(seconds: 2),
          toTs: Duration(seconds: 3),
          text: '   ',
        ),
      ];
      final cues = segmentsToCues(segments);
      expect(cues.single.content, '有效内容');
    });

    test('空列表 → 空列表', () {
      expect(segmentsToCues(const []), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 模型下载管理（真实 WhisperModelManager + 注入 fake 下载器 + 临时目录）
  // -------------------------------------------------------------------------
  group('WhisperModelManager', () {
    test('模型已存在且大小合理 → 跳过下载，直接返回路径，无进度回调', () async {
      final dl = _ModelDownloaderFake();
      final manager = WhisperModelManager(
        rootDir: tmp,
        downloadFile: dl.call,
        minModelBytes: 50,
      );
      final modelFile = File('${tmp.path}/ggml-base.bin');
      await modelFile.writeAsBytes(List.filled(100, 1));

      final progress = <double>[];
      final path = await manager.ensureModel(onProgress: progress.add);

      expect(path, modelFile.path);
      expect(dl.calls, 0, reason: '模型已存在不应触发下载');
      expect(progress, isEmpty);
      expect(await manager.isModelReady(), isTrue);
      expect(await manager.modelSize(), 100);
    });

    test('模型不存在 → 下载 + 大小校验 + 返回路径', () async {
      final dl = _ModelDownloaderFake(writeBytes: 100);
      final manager = WhisperModelManager(
        rootDir: tmp,
        downloadFile: dl.call,
        minModelBytes: 50,
      );

      final progress = <double>[];
      final path = await manager.ensureModel(onProgress: progress.add);

      expect(dl.calls, 1);
      expect(path, '${tmp.path}/ggml-base.bin');
      expect(await File(path).exists(), isTrue);
      expect(progress.first, 0.0);
      expect(progress.last, 1.0);
    });

    test('下载失败（网络 DioException）→ 中文网络提示，且失败重试一次', () async {
      final dl = _ModelDownloaderFake(
        failWith: DioException(
          requestOptions: RequestOptions(path: '/model'),
          message: '连接超时',
          type: DioExceptionType.connectionTimeout,
        ),
      );
      final manager = WhisperModelManager(
        rootDir: tmp,
        downloadFile: dl.call,
        minModelBytes: 50,
      );

      await expectLater(
        manager.ensureModel(),
        throwsA(isA<WhisperModelException>()
            .having((e) => e.message, 'message', contains('网络'))),
      );
      expect(dl.calls, 2, reason: '网络失败应重试一次（共 2 次）');
    });

    test('下载失败（磁盘 FileSystemException）→ 中文磁盘提示', () async {
      final dl = _ModelDownloaderFake(
        failWith: FileSystemException('磁盘已满', 'ggml-base.bin'),
      );
      final manager = WhisperModelManager(
        rootDir: tmp,
        downloadFile: dl.call,
        minModelBytes: 50,
      );

      await expectLater(
        manager.ensureModel(),
        throwsA(isA<WhisperModelException>()
            .having((e) => e.message, 'message', contains('写入本地'))),
      );
    });

    test('下载不完整（小于 minModelBytes）→ 抛「不完整」并清掉半成品', () async {
      final dl = _ModelDownloaderFake(writeBytes: 10); // 远小于 50
      final manager = WhisperModelManager(
        rootDir: tmp,
        downloadFile: dl.call,
        minModelBytes: 50,
      );

      await expectLater(
        manager.ensureModel(),
        throwsA(isA<WhisperModelException>()
            .having((e) => e.message, 'message', contains('不完整'))),
      );
      expect(dl.calls, 2, reason: '下载不完整应重试一次');
      expect(await File('${tmp.path}/ggml-base.bin').exists(), isFalse,
          reason: '失败后不应残留半成品');
    });
  });

  // -------------------------------------------------------------------------
  // 音频获取（缓存优先 vs 临时下载）
  // -------------------------------------------------------------------------
  group('WhisperAudioSource', () {
    test('离线缓存优先：已缓存 audio.m4s → 直接复用，不调取流/下载', () async {
      // 先用真实 DownloadManager（注入 fake 取流/下载）下载一集产生缓存
      final dl = _AudioDownloaderFake();
      final manager = DownloadManager(
        fetchPlayUrl: _dashFetcher(),
        downloadFile: dl.call,
        rootDir: tmp,
        betweenTasks: Duration.zero,
        retryDelay: Duration.zero,
      );
      await manager.downloadVideo(_video(), 0);
      final cached = manager.getCached('BV1test', 0)!;
      expect(cached.audioPath, isNotEmpty);

      // 取流/下载 fake 都会抛错 → 若被调用则测试失败
      final source = WhisperAudioSource(
        downloadManager: manager,
        fetchPlayUrl: ({required String bvid, required int cid}) async =>
            throw StateError('不应调用取流'),
        downloadFile: (url, savePath, onProgress) async =>
            throw StateError('不应调用下载'),
        rootDir: tmp,
      );
      final p = await source.getAudioPath(_video(), 0);
      expect(p, cached.audioPath);
      expect(await File(p).exists(), isTrue);
    });

    test('无缓存 → 临时下载 dash.audio[0] 到 audio_tmp/<bvid>_<pageIndex>.m4s',
        () async {
      var fetchedBvid = '';
      var fetchedCid = -1;
      final dl = _AudioDownloaderFake();
      final source = WhisperAudioSource(
        downloadManager: DownloadManager(rootDir: tmp),
        fetchPlayUrl: ({required String bvid, required int cid}) async {
          fetchedBvid = bvid;
          fetchedCid = cid;
          return _dashFetcher(audioUrl: 'http://fake.bilivideo.com/a.m4s')(
              bvid: bvid, cid: cid);
        },
        downloadFile: dl.call,
        rootDir: tmp,
      );

      final p = await source.getAudioPath(_video(bvid: 'BV1abc', cid: 100), 2);

      expect(fetchedBvid, 'BV1abc');
      expect(fetchedCid, 100);
      expect(p, '${tmp.path}/audio_tmp/BV1abc_2.m4s');
      expect(await File(p).exists(), isTrue);
      expect(dl.urls.single, 'http://fake.bilivideo.com/a.m4s');
    });

    test('多 P：pageIndex 命中对应分 P 的 cid', () async {
      var fetchedCid = -1;
      final source = WhisperAudioSource(
        downloadManager: DownloadManager(rootDir: tmp),
        fetchPlayUrl: ({required String bvid, required int cid}) async {
          fetchedCid = cid;
          return _dashFetcher()(bvid: bvid, cid: cid);
        },
        downloadFile: (url, savePath, onProgress) async {
          final f = File(savePath);
          await f.parent.create(recursive: true);
          await f.writeAsBytes(List.filled(1000, 1));
        },
        rootDir: tmp,
      );
      final video = _video(
        bvid: 'BV1multi',
        cid: 1000,
        pages: const [
          PageInfo(cid: 1001, part: '一', duration: 60),
          PageInfo(cid: 1002, part: '二', duration: 60),
        ],
      );

      await source.getAudioPath(video, 1);
      expect(fetchedCid, 1002, reason: '取第 2 集应用第 2 个分 P 的 cid');
    });

    test('取流返回无 audio 流 → 抛 AudioSourceException', () async {
      final source = WhisperAudioSource(
        downloadManager: DownloadManager(rootDir: tmp),
        fetchPlayUrl: ({required String bvid, required int cid}) async =>
            const PlayUrlResult(quality: 32, mp4Url: 'http://x.mp4'),
        rootDir: tmp,
      );
      await expectLater(
        source.getAudioPath(_video(), 0),
        throwsA(isA<AudioSourceException>()
            .having((e) => e.message, 'message', contains('音频流'))),
      );
    });

    test('取流网络失败 → 抛 AudioSourceException（网络提示）', () async {
      final source = WhisperAudioSource(
        downloadManager: DownloadManager(rootDir: tmp),
        fetchPlayUrl: ({required String bvid, required int cid}) async =>
            throw DioException(
          requestOptions: RequestOptions(path: '/playurl'),
          type: DioExceptionType.connectionTimeout,
        ),
        rootDir: tmp,
      );
      await expectLater(
        source.getAudioPath(_video(), 0),
        throwsA(isA<AudioSourceException>()
            .having((e) => e.message, 'message', contains('网络'))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Transcriber 编排
  // -------------------------------------------------------------------------
  group('Transcriber', () {
    const fakeAudioPath = '/fake/audio.m4s';

    Transcriber buildTranscriber({
      TranscriptionRunner? runner,
      TranscriptionCache? cache,
      _FakeModelManager? model,
      _FakeAudioSource? audio,
    }) {
      return Transcriber(
        modelManager: model ?? _FakeModelManager(),
        audioSource: audio ?? _FakeAudioSource(path: fakeAudioPath),
        cache: cache ?? TranscriptionCache(rootDir: tmp),
        transcribeOverride: runner,
      );
    }

    test('缓存命中：直接返回，不调模型/音频/转写', () async {
      final cache = TranscriptionCache(rootDir: tmp);
      await cache.save(
          'BV1hit', 0, const [SubtitleCue(from: 0, to: 1, content: '缓存')]);
      final model = _FakeModelManager();
      final audio = _FakeAudioSource(path: fakeAudioPath);
      var runnerCalled = false;
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          runnerCalled = true;
          return null;
        },
        cache: cache,
        model: model,
        audio: audio,
      );

      final cues = await t.transcribe(_video(bvid: 'BV1hit'), 0);

      expect(cues.single.content, '缓存');
      expect(runnerCalled, isFalse);
      expect(model.ensureCalls, 0);
      expect(audio.calls, 0);
    });

    test('完整流程：模型→音频→转写→cues→写缓存；二次调用命中缓存', () async {
      const segments = [
        WhisperTranscribeSegment(
          fromTs: Duration(milliseconds: 500),
          toTs: Duration(milliseconds: 1200),
          text: ' 你好 ',
        ),
        WhisperTranscribeSegment(
          fromTs: Duration(milliseconds: 1200),
          toTs: Duration(milliseconds: 2000),
          text: '世界',
        ),
      ];
      var runnerCalls = 0;
      String? runnerLanguage;
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          runnerCalls++;
          runnerLanguage = language;
          expect(audioPath, fakeAudioPath);
          return segmentsToCues(segments);
        },
      );

      final progress = <double>[];
      final cues = await t.transcribe(_video(), 0,
          language: 'zh', onProgress: progress.add);

      expect(cues.length, 2);
      expect(cues[0].from, 0.5);
      expect(cues[0].to, 1.2);
      expect(cues[0].content, '你好');
      expect(cues[1].content, '世界');
      expect(runnerCalls, 1);
      expect(runnerLanguage, 'zh');
      expect(progress.last, 1.0);

      // 转写结果已写缓存 → 第二次调用直接命中，不再转写
      final cues2 = await t.transcribe(_video(), 0);
      expect(cues2.length, 2);
      expect(runnerCalls, 1, reason: '二次调用应命中缓存，不再转写');
      expect(await t.getCachedTranscription('BV1test', 0), isNotNull);
    });

    test('clearTranscription 清缓存后重新转写（重转写流程）', () async {
      var runnerCalls = 0;
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          runnerCalls++;
          return const [SubtitleCue(from: 0, to: 1, content: '新版')];
        },
      );

      final first = await t.transcribe(_video(), 0);
      expect(first.single.content, '新版');
      expect(await t.getCachedTranscription('BV1test', 0), isNotNull);

      // 清缓存 → 再次转写不再命中旧结果（runner 重新执行）
      await t.clearTranscription('BV1test', 0);
      expect(await t.getCachedTranscription('BV1test', 0), isNull);
      final again = await t.transcribe(_video(), 0);
      expect(again.single.content, '新版');
      expect(runnerCalls, 2, reason: '清缓存后应重新转写');
    });

    test('并发控制：转写中再次调用抛「正在转写其他视频」', () async {
      final gate = CompleterGate();
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          await gate.enter();
          return segmentsToCues(const [
            WhisperTranscribeSegment(
                fromTs: Duration.zero, toTs: Duration(seconds: 1), text: 'x'),
          ]);
        },
      );

      final f1 = t.transcribe(_video(), 0);
      await gate.firstEntered.future.timeout(const Duration(seconds: 2));
      expect(t.isTranscribing, isTrue);

      await expectLater(
        t.transcribe(_video(bvid: 'BV1other'), 0),
        throwsA(isA<TranscribeException>()
            .having((e) => e.message, 'message', contains('正在转写'))),
      );

      gate.open();
      await f1;
      expect(t.isTranscribing, isFalse);
    });

    test('取消：cancel 后阶段边界抛「转写已取消」，不写缓存', () async {
      final gate = CompleterGate();
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          await gate.enter();
          return segmentsToCues(const [
            WhisperTranscribeSegment(
                fromTs: Duration.zero, toTs: Duration(seconds: 1), text: 'x'),
          ]);
        },
      );

      final f1 = t.transcribe(_video(), 0);
      await gate.firstEntered.future.timeout(const Duration(seconds: 2));
      t.cancel();
      gate.open();

      await expectLater(
        f1,
        throwsA(isA<TranscribeException>()
            .having((e) => e.message, 'message', contains('已取消'))),
      );
      expect(t.isTranscribing, isFalse);
      expect(await t.getCachedTranscription('BV1test', 0), isNull,
          reason: '取消的转写结果不应写入缓存');
    });

    test('引擎返回 null → 抛「转写失败」分类提示', () async {
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          return null;
        },
      );
      await expectLater(
        t.transcribe(_video(), 0),
        throwsA(isA<TranscribeException>()
            .having((e) => e.message, 'message', contains('转写失败'))),
      );
    });

    test('引擎抛异常 → 包装为「转写失败：whisper 引擎异常」', () async {
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          throw StateError('native crash');
        },
      );
      await expectLater(
        t.transcribe(_video(), 0),
        throwsA(isA<TranscribeException>()
            .having((e) => e.message, 'message', contains('引擎异常'))),
      );
    });

    test('引擎返回空列表 → 抛「未识别到任何语音内容」', () async {
      final t = buildTranscriber(
        runner: ({required String audioPath, required String language,
            void Function(int percent)? onProgress}) async {
          return const [];
        },
      );
      await expectLater(
        t.transcribe(_video(), 0),
        throwsA(isA<TranscribeException>()
            .having((e) => e.message, 'message', contains('未识别到'))),
      );
    });

    test('模型下载失败 → 透传 WhisperModelException（中文提示）', () async {
      final model = _FakeModelManager(
        ensureError: const WhisperModelException('模型下载失败：网络异常，请检查网络后重试'),
      );
      final t = buildTranscriber(model: model);
      await expectLater(
        t.transcribe(_video(), 0),
        throwsA(isA<WhisperModelException>()
            .having((e) => e.message, 'message', contains('模型下载失败'))),
      );
    });

    test('音频获取失败 → 透传 AudioSourceException（中文提示）', () async {
      final t = Transcriber(
        modelManager: _FakeModelManager(),
        audioSource: _FakeThrowingAudioSource(),
        cache: TranscriptionCache(rootDir: tmp),
        transcribeOverride: null,
      );
      await expectLater(
        t.transcribe(_video(), 0),
        throwsA(isA<AudioSourceException>()
            .having((e) => e.message, 'message', contains('音频流'))),
      );
    });
  });
}

/// 音频源替身：getAudioPath 恒抛 [AudioSourceException]。
class _FakeThrowingAudioSource extends WhisperAudioSource {
  _FakeThrowingAudioSource() : super(downloadManager: DownloadManager());

  @override
  Future<String> getAudioPath(WhitelistVideo video, int pageIndex) async {
    throw const AudioSourceException('音频流获取失败：网络异常，请稍后重试');
  }
}
