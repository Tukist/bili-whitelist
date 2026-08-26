/// sherpa 流式实时转写核心逻辑单测。
///
/// 覆盖（sherpa 真实推理依赖原生 .so，无法单测，测我们自己的
/// 状态机 / 句子积累 / 翻译调度 / 错误分类 / wav 解析）：
/// - SherpaModelManager：下载 / 已存在跳过 / 解压 / 完整性判断 / 失败重试
/// - SherpaAudioPreparer：m4s → wav 转码调用 / 复用 / 失败分类
/// - RealtimeTranscriber：状态流转 / 块循环 / 句子积累（时间戳）/ 逐句翻译 /
///   stop / 并发拒绝 / 错误分类
/// - openPcm16Wav：真实 wav 字节解析（块分割 / 采样校验）
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/sherpa_audio.dart';
import 'package:bili_whitelist_app/api/sherpa_model.dart';
import 'package:bili_whitelist_app/api/whisper_audio.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/realtime_transcriber.dart';

const _video = WhitelistVideo(
  bvid: 'BV1TEST',
  cid: 100,
  title: '测试视频',
  cover: '',
  duration: 60,
  upName: 'tester',
  addedAt: '',
);

// ---------------------------------------------------------------------------
// 工具：fake 依赖
// ---------------------------------------------------------------------------

/// 注入的假模型目录（含齐四件套，大小可控）。
class FakeModelDir {
  final Directory root; // SherpaModelManager 的 rootDirOverride
  final Directory langDir; // <root>/sherpa/8lang

  FakeModelDir(this.root)
      : langDir = Directory(
            '${root.path}/sherpa/${SherpaModelManager.langDirName}');

  /// 构造一个「模型就绪」的目录（encoder 大小 > [minEncoderBytes]）。
  Future<void> makeReady({int minEncoderBytes = 10}) async {
    final dir = Directory('${langDir.path}/${SherpaModelManager.modelDirName}');
    await dir.create(recursive: true);
    final enc = File('${dir.path}/encoder-epoch-1-avg-1-chunk-16-left-128.int8.onnx');
    await enc.writeAsBytes(List.filled(minEncoderBytes + 100, 0));
    await File('${dir.path}/decoder-epoch-1-avg-1-chunk-16-left-128.onnx')
        .writeAsBytes(List.filled(100, 0));
    await File('${dir.path}/joiner-epoch-1-avg-1-chunk-16-left-128.int8.onnx')
        .writeAsBytes(List.filled(100, 0));
    await File('${dir.path}/tokens.txt').writeAsString('0\n1\n2\n');
  }
}

/// 假识别器：按「已喂样本数」出句子，行为可控。
class FakeRtRecognizer implements RtRecognizer {
  /// 每多少样本完成一个句子（endpoint）。
  final int samplesPerSentence;

  /// 预置逐句文本（长度不足则按「句子N」自动生成）。
  final List<String>? presetTexts;

  int accepted = 0; // 累计喂入样本
  int decodeCalls = 0;
  int resetCount = 0;
  bool inputFinishedCalled = false;
  bool disposed = false;

  int _sentenceIndex = 0;
  bool _endpoint = false;
  bool _drained = true; // accept 后 false，decode 后 true（模拟单步消费）
  String _currentText = '';

  FakeRtRecognizer({required this.samplesPerSentence, this.presetTexts});

  String get _textOf =>
      (presetTexts != null && _sentenceIndex < presetTexts!.length)
          ? presetTexts![_sentenceIndex]
          : '句子${_sentenceIndex + 1}';

  @override
  RtStream createStream() => RtStream(0);

  @override
  void acceptWaveform(RtStream stream, Float32List samples,
      {required int sampleRate}) {
    accepted += samples.length;
    _drained = false;
    _currentText = _textOf;
  }

  @override
  void inputFinished(RtStream stream) {
    inputFinishedCalled = true;
    _drained = false;
  }

  @override
  bool isReady(RtStream stream) => !_drained;

  @override
  void decode(RtStream stream) {
    decodeCalls++;
    _drained = true;
    if (accepted >= samplesPerSentence * (_sentenceIndex + 1)) {
      _endpoint = true;
    }
  }

  @override
  String getText(RtStream stream) => _currentText;

  @override
  bool isEndpoint(RtStream stream) => _endpoint;

  @override
  void reset(RtStream stream) {
    _sentenceIndex++;
    _endpoint = false;
    _currentText = '';
    resetCount++;
  }

  @override
  void disposeStream(RtStream stream) {}

  @override
  void dispose() {
    disposed = true;
  }
}

/// 假 wav 源：直接给出块列表。
class FakeWavSource {
  final int totalSamples;
  final List<Float32List> chunks;

  FakeWavSource(this.totalSamples, this.chunks);

  Future<WavSource> open(String path, {int chunkSamples = 16000}) =>
      Future.value(WavSource(
        totalSamples: totalSamples,
        chunks: Stream.fromIterable(chunks),
      ));
}

/// 假音频源（WhisperAudioSource 子类，override getAudioPath）。
class FakeAudioSource extends WhisperAudioSource {
  final String path;
  final Object? error;

  FakeAudioSource(this.path, {this.error});

  @override
  Future<String> getAudioPath(WhitelistVideo video, int pageIndex) async {
    if (error != null) throw error!;
    return path;
  }
}

/// 假模型管理器（不走真实下载/解压）。
class FakeModelManager extends SherpaModelManager {
  final Object? ensureError;
  final SherpaModelFiles? files;
  int ensureCalls = 0;

  FakeModelManager({this.ensureError, this.files});

  @override
  Future<String> ensureModel({ValueChanged<double>? onProgress}) async {
    ensureCalls++;
    onProgress?.call(1.0);
    if (ensureError != null) throw ensureError!;
    return '/fake/model';
  }

  @override
  Future<SherpaModelFiles?> modelFiles() async => files;
}

// ---------------------------------------------------------------------------
// SherpaModelManager：下载 / 解压 / 完整性
// ---------------------------------------------------------------------------

void main() {
  group('SherpaModelManager', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sherpa_model_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// 构造 manager：注入 downloadFile / extract / 调小完整性阈值。
    /// 默认 downloadFile 会写一个 > minModelBytes 的 tar 文件（模拟下载完成）。
    SherpaModelManager makeManager({
      Future<void> Function(String, String, void Function(double)?)? download,
      Future<void> Function(String, String)? extract,
      Directory? rootDir,
      int minModelBytes = 10,
      int minEncoderBytes = 10,
    }) {
      return SherpaModelManager(
        downloadFile: download ??
            (url, savePath, onProgress) async {
              await File(savePath).writeAsBytes(List.filled(1000, 0));
            },
        extract: extract ??
            (tarPath, destDir) async {
              // 默认「解压」：把长名四件套写入解压目录（模拟真实 tar 结构）
              final dir = Directory(
                  '$destDir/${SherpaModelManager.modelDirName}');
              await dir.create(recursive: true);
              await File(
                      '${dir.path}/encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx')
                  .writeAsBytes(List.filled(minEncoderBytes + 100, 0));
              await File(
                      '${dir.path}/decoder-epoch-75-avg-11-chunk-16-left-128.onnx')
                  .writeAsBytes(List.filled(100, 0));
              await File(
                      '${dir.path}/joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx')
                  .writeAsBytes(List.filled(100, 0));
              await File('${dir.path}/tokens.txt').writeAsString('0\n');
            },
        rootDir: rootDir ?? tmp,
        minModelBytes: minModelBytes,
        minEncoderBytes: minEncoderBytes,
      );
    }

    test('已就绪：跳过下载直接返回目录', () async {
      final fake = FakeModelDir(tmp);
      await fake.makeReady();
      var downloaded = false;

      final m2 = SherpaModelManager(
        downloadFile: (url, savePath, onProgress) async {
          downloaded = true;
        },
        rootDir: tmp,
        minEncoderBytes: 10,
      );

      expect(await m2.isModelReady(), isTrue);
      final dir = await m2.ensureModel(onProgress: (_) {});
      expect(downloaded, isFalse);
      expect(
          dir, '${fake.langDir.path}/${SherpaModelManager.modelDirName}');
    });

    test('未就绪：下载（带进度）+ 解压 + 返回目录 + 删 tar', () async {
      final manager = makeManager();
      final progresses = <double>[];
      final tarPath = '${tmp.path}/sherpa/${SherpaModelManager.modelFileName}';

      final dir = await manager.ensureModel(
        onProgress: progresses.add,
      );

      expect(dir, contains(SherpaModelManager.modelDirName));
      expect(await manager.isModelReady(), isTrue);
      expect(await manager.modelDir(), dir);
      // 进度单调到 1.0
      expect(progresses.first, 0);
      expect(progresses.last, 1.0);
      // tar 包解压后删除
      expect(await File(tarPath).exists(), isFalse);
      // 文件用长名也能被识别（模型文件结构发现）
      final files = await manager.modelFiles();
      expect(files, isNotNull);
      expect(files!.encoder, contains('encoder'));
      expect(files.tokens, endsWith('tokens.txt'));
    });

    test('下载失败：重试 1 次后抛中文异常', () async {
      var calls = 0;
      final manager = SherpaModelManager(
        downloadFile: (url, savePath, onProgress) async {
          calls++;
          throw DioException(
              requestOptions: RequestOptions(path: url), type: DioExceptionType.connectionError);
        },
        rootDir: tmp,
        minModelBytes: 10,
      );
      await expectLater(
        manager.ensureModel(),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains('网络'))),
      );
      expect(calls, 2); // 首次 + 重试 1 次
    });

    test('下载文件过小：视为不完整抛异常', () async {
      final manager = SherpaModelManager(
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List.filled(5, 0)); // < minModelBytes
        },
        rootDir: tmp,
        minModelBytes: 100,
      );
      await expectLater(
        manager.ensureModel(),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains('不完整'))),
      );
    });

    test('解压失败：抛中文异常并清理 tar', () async {
      final manager = SherpaModelManager(
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List.filled(200, 0));
        },
        extract: (tarPath, destDir) async {
          throw const FileSystemException('disk full');
        },
        rootDir: tmp,
        minModelBytes: 100,
      );
      await expectLater(
        manager.ensureModel(),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains('解压失败'))),
      );
    });

    test('解压后缺文件：判定未就绪', () async {
      final manager = SherpaModelManager(
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List.filled(200, 0));
        },
        extract: (tarPath, destDir) async {
          // 只写 encoder + tokens，缺 decoder/joiner
          final dir =
              Directory('$destDir/${SherpaModelManager.modelDirName}');
          await dir.create(recursive: true);
          await File('${dir.path}/encoder.onnx')
              .writeAsBytes(List.filled(200, 0));
          await File('${dir.path}/tokens.txt').writeAsString('0\n');
        },
        rootDir: tmp,
        minModelBytes: 100,
        minEncoderBytes: 100,
      );
      await expectLater(
        manager.ensureModel(),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains('解压不完整'))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // SherpaAudioPreparer：m4s → wav
  // -------------------------------------------------------------------------

  group('SherpaAudioPreparer', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sherpa_audio_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('转码成功：ffmpeg 收到正确参数并返回 wav 路径', () async {
      final m4s = '${tmp.path}/BV1TEST_0.m4s';
      await File(m4s).writeAsBytes([1, 2, 3]);
      String? inArg, outArg;
      final preparer = SherpaAudioPreparer(
        audioSource: FakeAudioSource(m4s),
        runFfmpeg: (input, output) async {
          inArg = input;
          outArg = output;
          // 模拟 ffmpeg 写出 wav
          await File(output).writeAsBytes(List.filled(44, 0));
          return true;
        },
      );
      final wav = await preparer.prepareWav(_video, 0, onProgress: (_) {});
      expect(wav, '$m4s${SherpaAudioPreparer.wavSuffix}');
      expect(inArg, m4s);
      expect(outArg, wav);
    });

    test('复用已转码 wav：不调 ffmpeg', () async {
      final m4s = '${tmp.path}/BV1TEST_0.m4s';
      final wavPath = '$m4s${SherpaAudioPreparer.wavSuffix}';
      await File(m4s).writeAsBytes([1]);
      await File(wavPath).writeAsBytes(List.filled(44, 0));
      var ffmpegCalls = 0;
      final preparer = SherpaAudioPreparer(
        audioSource: FakeAudioSource(m4s),
        runFfmpeg: (input, output) async {
          ffmpegCalls++;
          return true;
        },
      );
      final wav = await preparer.prepareWav(_video, 0);
      expect(wav, wavPath);
      expect(ffmpegCalls, 0);
    });

    test('ffmpeg 非零退出：抛中文异常', () async {
      final preparer = SherpaAudioPreparer(
        audioSource: FakeAudioSource('${tmp.path}/x.m4s'),
        runFfmpeg: (input, output) async => false,
      );
      await expectLater(
        preparer.prepareWav(_video, 0),
        throwsA(isA<SherpaAudioException>()
            .having((e) => e.message, 'message', contains('转码失败'))),
      );
    });

    test('音频源失败：包装为中文异常', () async {
      final preparer = SherpaAudioPreparer(
        audioSource: FakeAudioSource('', error: AudioSourceException('网络错误')),
        runFfmpeg: (input, output) async => true,
      );
      await expectLater(
        preparer.prepareWav(_video, 0),
        throwsA(isA<SherpaAudioException>()
            .having((e) => e.message, 'message', contains('音频准备失败'))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // openPcm16Wav：真实 wav 字节解析
  // -------------------------------------------------------------------------

  group('openPcm16Wav', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sherpa_wav_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    /// 构造 16k mono 16bit PCM wav（含标准 44 字节头），data 为 0, 16384, -32768...
    Future<String> writeWav(String name, {int sampleRate = 16000}) async {
      final path = '${tmp.path}/$name';
      final samples = <int>[0, 16384, -32768, 32767];
      final data = ByteData(samples.length * 2);
      for (var i = 0; i < samples.length; i++) {
        data.setInt16(i * 2, samples[i], Endian.little);
      }
      final bytes = BytesBuilder();
      void writeStr(String s) => bytes.add(s.codeUnits);
      void writeU32(int v) {
        final bd = ByteData(4)..setUint32(0, v, Endian.little);
        bytes.add(bd.buffer.asUint8List());
      }

      void writeU16(int v) {
        final bd = ByteData(2)..setUint16(0, v, Endian.little);
        bytes.add(bd.buffer.asUint8List());
      }
      writeStr('RIFF');
      writeU32(36 + data.lengthInBytes);
      writeStr('WAVE');
      writeStr('fmt ');
      writeU32(16);
      writeU16(1); // PCM
      writeU16(1); // mono
      writeU32(sampleRate);
      writeU32(sampleRate * 2); // byte rate
      writeU16(2); // block align
      writeU16(16); // bits
      writeStr('data');
      writeU32(data.lengthInBytes);
      bytes.add(data.buffer.asUint8List());
      await File(path).writeAsBytes(bytes.toBytes());
      return path;
    }

    test('解析 16k mono wav：样本值与块分割正确', () async {
      final path = await writeWav('ok.wav');
      final src = await openPcm16Wav(path, chunkSamples: 2);
      expect(src.totalSamples, 4);
      final chunks = await src.chunks.toList();
      expect(chunks, hasLength(2)); // 4 样本 / 每块 2
      expect(chunks[0], [0.0, 0.5]); // 16384/32768
      expect(chunks[1], [-1.0, 32767 / 32768]);
    });

    test('非 16k 采样率：抛中文异常', () async {
      final path = await writeWav('bad_rate.wav', sampleRate: 8000);
      await expectLater(
        openPcm16Wav(path),
        throwsA(isA<RealtimeException>().having(
            (e) => e.message, 'message', contains('采样'))),
      );
    });

    test('非 wav 文件：抛中文异常', () async {
      final path = '${tmp.path}/bad.wav';
      await File(path).writeAsBytes(List.filled(100, 0));
      await expectLater(
        openPcm16Wav(path),
        throwsA(isA<RealtimeException>().having(
            (e) => e.message, 'message', contains('有效 wav'))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // RealtimeTranscriber：状态机 / 句子积累 / 翻译 / stop / 并发 / 错误
  // -------------------------------------------------------------------------

  group('RealtimeTranscriber', () {
    final files = const SherpaModelFiles(
      encoder: '/m/encoder.onnx',
      decoder: '/m/decoder.onnx',
      joiner: '/m/joiner.onnx',
      tokens: '/m/tokens.txt',
    );

    RealtimeTranscriber makeTranscriber({
      FakeRtRecognizer? recognizer,
      WavSourceProvider? wavSource,
      SentenceTranslator? translate,
      Object? modelError,
      Object? audioError,
    }) {
      final fake = recognizer ?? FakeRtRecognizer(samplesPerSentence: 32000);
      return RealtimeTranscriber(
        modelManager: FakeModelManager(ensureError: modelError, files: files),
        audioPreparer: SherpaAudioPreparer(
          audioSource: FakeAudioSource(
              '${Directory.systemTemp.path}/a.m4s',
              error: audioError),
          // fake ffmpeg：写一个 wav 文件模拟转码输出（prepareWav 会校验存在）
          runFfmpeg: (i, o) async {
            await File(o).writeAsBytes(List.filled(44, 0));
            return true;
          },
        ),
        recognizerFactory: (_) => fake,
        wavSource: wavSource ??
            (path, {chunkSamples = 16000}) async => FakeWavSource(
                  16000 * 3,
                  [
                    Float32List(16000),
                    Float32List(16000),
                    Float32List(16000),
                  ],
                ).open(path),
        translate: translate ?? (text) async => '译$text',
      );
    }

    test('状态流转 + 句子积累 + 逐句翻译 + 时间戳', () async {
      final recognizer = FakeRtRecognizer(
        samplesPerSentence: 32000, // 2 块一句 → 3 块共 2 句
        presetTexts: const ['你好世界', '第二句话'],
      );
      final translated = <String>[];
      final transcriber = makeTranscriber(
        recognizer: recognizer,
        translate: (text) async {
          translated.add(text);
          return '译$text';
        },
      );

      final stages = <RtStage>[];
      transcriber.stage.addListener(() => stages.add(transcriber.stage.value));
      await transcriber.start(_video, 0);

      expect(stages, [
        RtStage.modelDownload,
        RtStage.audioPrep,
        RtStage.transcribing,
        RtStage.done,
      ]);
      expect(transcriber.stage.value, RtStage.done);
      // 2 句，时间戳按已喂秒数（2 块=2s 一句）
      expect(transcriber.sentences.value, hasLength(2));
      final s1 = transcriber.sentences.value[0];
      expect(s1.text, '你好世界');
      expect(s1.fromTs, 0);
      expect(s1.toTs, 2);
      final s2 = transcriber.sentences.value[1];
      expect(s2.text, '第二句话');
      expect(s2.fromTs, 2);
      expect(s2.toTs, 3);
      // 逐句翻译被调用且写回句子
      expect(translated, ['你好世界', '第二句话']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(transcriber.sentences.value[0].translation, '译你好世界');
      expect(transcriber.sentences.value[1].translation, '译第二句话');
      // 引擎资源释放
      expect(recognizer.disposed, isTrue);
    });

    test('无 endpoint：inputFinished + 尾部兜底收句', () async {
      final recognizer = FakeRtRecognizer(samplesPerSentence: 16000 * 100);
      final transcriber = makeTranscriber(recognizer: recognizer);
      await transcriber.start(_video, 0);
      expect(recognizer.inputFinishedCalled, isTrue);
      // 无 endpoint，尾部 getText 兜底收 1 句
      expect(transcriber.sentences.value, hasLength(1));
      expect(transcriber.sentences.value.first.text, '句子1');
      expect(transcriber.stage.value, RtStage.done);
    });

    test('翻译失败不阻塞转写（translation 留空）', () async {
      final transcriber = makeTranscriber(
        recognizer: FakeRtRecognizer(samplesPerSentence: 32000),
        translate: (text) async => throw Exception('api down'),
      );
      await transcriber.start(_video, 0);
      expect(transcriber.stage.value, RtStage.done);
      expect(transcriber.sentences.value, isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final s in transcriber.sentences.value) {
        expect(s.translation, isNull);
      }
    });

    test('stop：块边界生效，stage 回 idle 且句子保留', () async {
      final controller = StreamController<Float32List>();
      final transcriber = makeTranscriber(
        recognizer: FakeRtRecognizer(samplesPerSentence: 16000 * 1000),
        wavSource: (path, {chunkSamples = 16000}) async => WavSource(
          totalSamples: 16000 * 1000,
          chunks: controller.stream,
        ),
      );
      final future = transcriber.start(_video, 0);
      // 等进入 transcribing（模型/音频都是 fake 立即返回）
      await _waitStage(transcriber, RtStage.transcribing);
      transcriber.stop();
      controller.add(Float32List(16000));
      await controller.close();
      await future; // 不抛错
      expect(transcriber.stage.value, RtStage.idle);
      expect(transcriber.isRunning, isFalse);
      // 停止前的句子保留（无 endpoint → 0 句，但若停止前已有句则保留）
    });

    test('并发：进行中再次 start 拒绝', () async {
      final gate = Completer<void>();
      final transcriber = RealtimeTranscriber(
        modelManager: _GatedModelManager(gate, files: files),
        audioPreparer: SherpaAudioPreparer(
          audioSource:
              FakeAudioSource('${Directory.systemTemp.path}/a.m4s'),
          runFfmpeg: (i, o) async => true,
        ),
        recognizerFactory: (_) => FakeRtRecognizer(samplesPerSentence: 32000),
        wavSource: (path, {chunkSamples = 16000}) async =>
            FakeWavSource(0, []).open(path),
        translate: (text) async => null,
      );
      final first = transcriber.start(_video, 0); // 挂起在模型阶段
      await _waitStage(transcriber, RtStage.modelDownload);
      await expectLater(
        transcriber.start(_video, 0),
        throwsA(isA<RealtimeException>()
            .having((e) => e.message, 'message', contains('正在实时转写'))),
      );
      gate.complete();
      await first;
    });

    test('模型下载失败：stage=error + 中文错误 + rethrow', () async {
      final transcriber = makeTranscriber(
        modelError: const SherpaModelException('模型下载失败：网络异常'),
      );
      await expectLater(
        transcriber.start(_video, 0),
        throwsA(isA<SherpaModelException>()),
      );
      expect(transcriber.stage.value, RtStage.error);
      expect(transcriber.error.value, contains('模型下载失败'));
    });

    test('音频准备失败：stage=error + 中文错误', () async {
      final transcriber = makeTranscriber(
        audioError: const AudioSourceException('音频流获取失败'),
      );
      await expectLater(
        transcriber.start(_video, 0),
        throwsA(isA<SherpaAudioException>()),
      );
      expect(transcriber.stage.value, RtStage.error);
      expect(transcriber.error.value, contains('音频准备失败'));
    });

    test('引擎初始化失败：包装为中文异常', () async {
      final transcriber = RealtimeTranscriber(
        modelManager: FakeModelManager(files: files),
        audioPreparer: SherpaAudioPreparer(
          audioSource:
              FakeAudioSource('${Directory.systemTemp.path}/a.m4s'),
          runFfmpeg: (i, o) async {
            await File(o).writeAsBytes(List.filled(44, 0));
            return true;
          },
        ),
        recognizerFactory: (_) => throw StateError('so not found'),
        wavSource: (path, {chunkSamples = 16000}) async =>
            FakeWavSource(0, []).open(path),
        translate: (text) async => null,
      );
      await expectLater(
        transcriber.start(_video, 0),
        throwsA(isA<RealtimeException>()
            .having((e) => e.message, 'message', contains('实时转写失败'))),
      );
      expect(transcriber.stage.value, RtStage.error);
    });
  });
}

/// 轮询等待 stage 到达目标（fake 依赖都是立即返回，最多几轮）。
Future<void> _waitStage(RealtimeTranscriber t, RtStage target) async {
  for (var i = 0; i < 100; i++) {
    if (t.stage.value == target) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('未到达阶段 $target（当前 ${t.stage.value}）');
}

/// 挂起在 ensureModel 的假模型管理器（测并发用）。
class _GatedModelManager extends FakeModelManager {
  final Completer<void> gate;

  _GatedModelManager(this.gate, {required super.files});

  @override
  Future<String> ensureModel({ValueChanged<double>? onProgress}) async {
    onProgress?.call(0.5);
    await gate.future;
    return '/fake/model';
  }
}
