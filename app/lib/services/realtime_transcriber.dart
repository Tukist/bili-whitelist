/// sherpa-onnx 流式实时转写服务（单例）。
///
/// 一次流程：
/// 1. 模型：`SherpaModelManager.ensureModel`（下载/解压 8 语流式 zipformer）
/// 2. 音频：`SherpaAudioPreparer.prepareWav`（m4s → 16kHz mono wav）
/// 3. 转写：`OnlineRecognizer`（zipformer2 transducer）→ `createStream` →
///    按块（1s=16000 samples）喂 `acceptWaveform` → `decode` → `getResult`
///    实时更新 partialText → `isEndpoint` 检测句尾 → 完成句子（带时间戳）入
///    sentences → `reset` 继续；喂完 `inputFinished` 收尾
/// 4. 逐句翻译：每个完成句子立即调 [TranslateApi]（复用配置/缓存），翻译失败
///    不阻塞（translation 留空，后续可补）
///
/// 关键设计：
/// - 「实时推进」：转写处理速度决定字幕跟播速度（模拟器慢、真机 1~3s 延迟），
///   转写进度独立于播放，UI 层按播放位置显示对应句子
/// - 句子时间戳用「已喂音频秒数」推算（sherpa token 级 timestamps 以流内
///   相对位置为准，重置后归零，不适合直接当播放时间戳）
/// - 并发控制：一次一个 start，进行中再次调用抛错（拒绝并提示）
/// - 停止：`stop()` 置标志位，在块边界生效（引擎单步推理不打断）
/// - 错误分类：模型 / 音频 / 引擎分别抛中文提示异常
///   （[SherpaModelException] / [SherpaAudioException] / [RealtimeException]）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import '../api/sherpa_audio.dart';
import '../api/sherpa_model.dart';
import '../api/translate_api.dart';
import '../models/whitelist_video.dart';

/// 实时转写错误（message 可直接展示给用户）。
class RealtimeException implements Exception {
  final String message;

  const RealtimeException(this.message);

  @override
  String toString() => 'RealtimeException: $message';
}

/// 转写阶段（UI 状态机）。
enum RtStage { idle, modelDownload, audioPrep, transcribing, done, error }

/// 一条完成句子（主字幕=原文；translation=副字幕译文）。
class RealtimeSentence {
  final String text;
  final double fromTs; // 秒（已喂音频时间轴）
  final double toTs; // 秒
  String? translation; // 逐句翻译结果（翻译失败为 null，可后续补）

  RealtimeSentence({
    required this.text,
    required this.fromTs,
    required this.toTs,
    this.translation,
  });
}

// ---------------------------------------------------------------------------
// sherpa 识别器抽象（真实实现走 sherpa_onnx；测试注入 fake，不碰原生库）
// ---------------------------------------------------------------------------

/// 不透明流句柄（避免接口泄漏 sherpa_onnx 的 OnlineStream 类型）。
class RtStream {
  final int id;

  RtStream(this.id);
}

/// sherpa 流式识别器接口。
///
/// 与 sherpa_onnx `OnlineRecognizer`/`OnlineStream` 一一对应：
/// acceptWaveform / decode / getResult / isReady / isEndpoint / reset /
/// inputFinished。真实实现 [SherpaRtRecognizer]；单测注入 fake。
abstract class RtRecognizer {
  RtStream createStream();

  void acceptWaveform(RtStream stream, Float32List samples,
      {required int sampleRate});

  /// 全部音频喂完后标记输入结束（触发尾部上下文刷新）。
  void inputFinished(RtStream stream);

  /// 是否还有足够音频再解码一步。
  bool isReady(RtStream stream);

  /// 增量解码一步。
  void decode(RtStream stream);

  /// 当前识别文本（部分结果，逐句 reset 后重新积累）。
  String getText(RtStream stream);

  /// 是否检测到句尾（endpoint）。
  bool isEndpoint(RtStream stream);

  /// 句尾后重置流内部状态（下次识别重新积累）。
  void reset(RtStream stream);

  void disposeStream(RtStream stream);

  void dispose();
}

/// 识别器创建函数（可注入替身；默认走 [SherpaRtRecognizer]）。
typedef RecognizerFactory = RtRecognizer Function(SherpaModelFiles files);

/// sherpa_onnx 真实实现。
///
/// 仅真机/模拟器使用（依赖原生 .so）；单测注入 fake 不会走到这里。
class SherpaRtRecognizer implements RtRecognizer {
  SherpaRtRecognizer(SherpaModelFiles files)
      : _recognizer = _createRecognizer(files);

  final OnlineRecognizer _recognizer;
  final Map<int, OnlineStream> _streams = {};
  int _nextId = 0;

  static OnlineRecognizer _createRecognizer(SherpaModelFiles files) {
    initBindings(); // 幂等：加载 libsherpa-onnx-c-api.so
    return OnlineRecognizer(
      OnlineRecognizerConfig(
        model: OnlineModelConfig(
          transducer: OnlineTransducerModelConfig(
            encoder: files.encoder,
            decoder: files.decoder,
            joiner: files.joiner,
          ),
          tokens: files.tokens,
          modelType: 'zipformer2',
          numThreads: 2,
          provider: 'cpu',
        ),
      ),
    );
  }

  @override
  RtStream createStream() {
    final id = _nextId++;
    _streams[id] = _recognizer.createStream();
    return RtStream(id);
  }

  @override
  void acceptWaveform(RtStream stream, Float32List samples,
      {required int sampleRate}) {
    _streams[stream.id]?.acceptWaveform(samples: samples, sampleRate: sampleRate);
  }

  @override
  void inputFinished(RtStream stream) => _streams[stream.id]?.inputFinished();

  @override
  bool isReady(RtStream stream) {
    final s = _streams[stream.id];
    return s == null ? false : _recognizer.isReady(s);
  }

  @override
  void decode(RtStream stream) {
    final s = _streams[stream.id];
    if (s != null) _recognizer.decode(s);
  }

  @override
  String getText(RtStream stream) {
    final s = _streams[stream.id];
    return s == null ? '' : _recognizer.getResult(s).text;
  }

  @override
  bool isEndpoint(RtStream stream) {
    final s = _streams[stream.id];
    return s == null ? false : _recognizer.isEndpoint(s);
  }

  @override
  void reset(RtStream stream) {
    final s = _streams[stream.id];
    if (s != null) _recognizer.reset(s);
  }

  @override
  void disposeStream(RtStream stream) {
    final s = _streams.remove(stream.id);
    s?.free();
  }

  @override
  void dispose() {
    for (final s in _streams.values) {
      try {
        s.free();
      } catch (_) {}
    }
    _streams.clear();
    _recognizer.free();
  }
}

// ---------------------------------------------------------------------------
// wav 读取（16kHz 单声道 PCM16 → Float32List 块，归一化 [-1,1]）
// ---------------------------------------------------------------------------

/// 读取到的 wav 源：总样本数 + 块流。
class WavSource {
  final int totalSamples;
  final Stream<Float32List> chunks;

  WavSource({required this.totalSamples, required this.chunks});
}

/// wav 源打开函数（可注入替身；默认 [openPcm16Wav]）。
typedef WavSourceProvider = Future<WavSource> Function(
  String wavPath, {
  int chunkSamples,
});

/// 打开 16-bit PCM wav，按 [chunkSamples] 逐块产出 Float32（归一化 [-1,1]）。
///
/// 解析 RIFF chunk（支持 fmt 后带 LIST 等额外 chunk 的头部）；
/// 校验：PCM（format=1）、单声道、16kHz、16bit，不符抛 [RealtimeException]。
/// [chunkSamples] 默认 16000（1 秒）。
Future<WavSource> openPcm16Wav(
  String wavPath, {
  int chunkSamples = 16000,
}) async {
  final file = File(wavPath);
  if (!await file.exists()) {
    throw RealtimeException('音频文件不存在：$wavPath');
  }
  final raf = await file.open();
  var dataOffset = -1;
  var dataSize = 0;
  try {
    final head = ByteData.sublistView(await raf.read(12));
    if (head.lengthInBytes < 12 ||
        head.getUint32(0, Endian.big) != 0x52494646 || // 'RIFF'
        head.getUint32(8, Endian.big) != 0x57415645) {
      // 'WAVE'
      throw const RealtimeException('音频转码结果不是有效 wav 文件');
    }
    var offset = 12;
    int? fmtOffset;
    while (offset < 1 << 20) {
      await raf.setPosition(offset);
      final ch = await raf.read(8);
      if (ch.length < 8) break;
      final cb = ByteData.sublistView(ch);
      final id = String.fromCharCodes(ch.sublist(0, 4));
      final size = cb.getUint32(4, Endian.little);
      if (id == 'fmt ') fmtOffset = offset + 8;
      if (id == 'data') {
        dataOffset = offset + 8;
        dataSize = size;
        break;
      }
      offset += 8 + size + (size % 2); // chunk 2 字节对齐
    }
    if (fmtOffset == null || dataOffset < 0) {
      throw const RealtimeException('音频转码结果缺少 fmt/data chunk');
    }
    await raf.setPosition(fmtOffset);
    final fmt = ByteData.sublistView(await raf.read(16));
    final format = fmt.getUint16(0, Endian.little);
    final channels = fmt.getUint16(2, Endian.little);
    final sampleRate = fmt.getUint32(4, Endian.little);
    final bitsPerSample = fmt.getUint16(14, Endian.little);
    if (format != 1) {
      throw const RealtimeException('音频不是 PCM 格式，请重新转码');
    }
    if (channels != 1 || sampleRate != 16000) {
      throw RealtimeException('音频采样不匹配（需 16kHz 单声道）：'
          '实际 ${sampleRate}Hz/${channels}ch');
    }
    if (bitsPerSample != 16) {
      throw RealtimeException('音频位深不支持（需 16bit）：$bitsPerSample bit');
    }
  } finally {
    if (dataOffset < 0) await raf.close();
  }

  final totalSamples = dataSize ~/ 2;
  final bytesPerChunk = chunkSamples * 2;

  Stream<Float32List> chunkStream() async* {
    try {
      await raf.setPosition(dataOffset);
      var remaining = dataSize;
      final buf = Uint8List(bytesPerChunk);
      while (remaining > 0) {
        final n = remaining < bytesPerChunk ? remaining : bytesPerChunk;
        final got = await raf.readInto(buf, 0, n);
        if (got <= 0) break;
        final out = Float32List(got ~/ 2);
        final bd = ByteData.sublistView(buf, 0, got);
        for (var i = 0; i < out.length; i++) {
          out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
        }
        remaining -= got;
        yield out;
      }
    } finally {
      await raf.close();
    }
  }

  return WavSource(totalSamples: totalSamples, chunks: chunkStream());
}

// ---------------------------------------------------------------------------
// 实时转写服务（单例）
// ---------------------------------------------------------------------------

/// 逐句翻译函数（可注入替身；默认走 [TranslateApi.translateBatch]）。
///
/// 返回译文；失败返回 null（不阻塞转写，translation 留空）。
typedef SentenceTranslator = Future<String?> Function(String text);

/// sherpa 流式实时转写服务（单例）。
///
/// 状态通过 ValueNotifier 暴露（stage / progress / partialText / sentences /
/// error），UI 直接监听；句子按「已喂音频秒数」打时间戳，UI 按播放位置显示。
class RealtimeTranscriber {
  RealtimeTranscriber({
    SherpaModelManager? modelManager,
    SherpaAudioPreparer? audioPreparer,
    RecognizerFactory? recognizerFactory,
    WavSourceProvider? wavSource,
    SentenceTranslator? translate,
    this.sampleRate = 16000,
    this.chunkSamples = 16000,
  })  : _modelManager = modelManager ?? SherpaModelManager.instance,
        _audioPreparer = audioPreparer ?? SherpaAudioPreparer(),
        _recognizerFactory =
            recognizerFactory ?? ((files) => SherpaRtRecognizer(files)),
        _wavSource = wavSource ?? openPcm16Wav,
        _translate = translate ?? _defaultTranslate;

  static RealtimeTranscriber? _instance;

  /// 全局单例（UI 直接用；测试通过 [debugOverride] 替换）。
  static RealtimeTranscriber get instance => _instance ??= RealtimeTranscriber();

  /// 测试注入：替换单例实现。
  @visibleForTesting
  static void debugOverride(RealtimeTranscriber transcriber) =>
      _instance = transcriber;

  /// 测试复位：清空单例，下次取回全新实例。
  @visibleForTesting
  static void debugReset() => _instance = null;

  final SherpaModelManager _modelManager;
  final SherpaAudioPreparer _audioPreparer;
  final RecognizerFactory _recognizerFactory;
  final WavSourceProvider _wavSource;
  final SentenceTranslator _translate;

  /// 特征采样率（wav 已转 16k，固定 16000）。
  final int sampleRate;

  /// 每次喂给 ASR 的样本数（默认 16000 = 1 秒音频）。
  final int chunkSamples;

  final ValueNotifier<RtStage> stage = ValueNotifier(RtStage.idle);

  /// 整体进度 0~1（模型下载 / 音频准备；转写阶段按已处理秒数递增）。
  final ValueNotifier<double> progress = ValueNotifier(0);

  /// 当前实时部分文本（实时字幕「原文」）。
  final ValueNotifier<String> partialText = ValueNotifier('');

  /// 已完成的句子列表（主字幕=text，副字幕=translation）。
  final ValueNotifier<List<RealtimeSentence>> sentences =
      ValueNotifier(const []);

  /// 错误信息（stage=error 时有值，中文可直接展示）。
  final ValueNotifier<String?> error = ValueNotifier(null);

  bool _running = false;
  bool _stopRequested = false;

  /// 是否正在转写（UI 可据此显示状态/禁用按钮）。
  bool get isRunning => _running;

  /// 停止当前转写（标志位；在块边界生效，引擎单步推理不打断）。
  /// 停止不视为错误：stage 回到 idle，已积累的句子保留。
  void stop() => _stopRequested = true;

  /// 清除当前结果（开始新转写前 UI 可调用）。
  void clear() {
    _sentencesList.clear();
    _publishSentences();
    partialText.value = '';
    error.value = null;
    progress.value = 0;
    if (stage.value != RtStage.transcribing) stage.value = RtStage.idle;
  }

  final List<RealtimeSentence> _sentencesList = [];

  /// 开始某集实时转写（模型 → 音频 → 流式转写 + 逐句翻译）。
  ///
  /// [language] 保留参数（8 语模型自动检测语言，暂不强制指定）。
  /// 进行中再次调用抛 [RealtimeException]（拒绝并提示）。
  /// 错误（中文提示，UI 可直接展示）：
  /// - 模型下载失败 → [SherpaModelException]
  /// - 音频准备失败 → [SherpaAudioException]
  /// - 引擎初始化/运行失败 → [RealtimeException]
  Future<void> start(WhitelistVideo video, int pageIndex,
      {String? language}) async {
    if (_running) {
      throw const RealtimeException('正在实时转写，请先停止再开始');
    }
    _running = true;
    _stopRequested = false;
    _sentencesList.clear();
    _publishSentences();
    partialText.value = '';
    error.value = null;

    try {
      // 1) 模型（下载/解压/复用）
      stage.value = RtStage.modelDownload;
      progress.value = 0;
      await _modelManager.ensureModel(
        onProgress: (p) => progress.value = p,
      );
      _throwIfStopped();

      // 2) 音频（m4s → 16k mono wav）
      stage.value = RtStage.audioPrep;
      final wavPath = await _audioPreparer.prepareWav(
        video,
        pageIndex,
        onProgress: (p) => progress.value = p,
      );
      _throwIfStopped();

      // 3) 流式转写
      stage.value = RtStage.transcribing;
      final files = await _modelManager.modelFiles();
      if (files == null) {
        throw const RealtimeException('模型文件缺失，请重新下载模型');
      }
      final recognizer = _recognizerFactory(files);
      try {
        await _runStreaming(recognizer, wavPath);
      } finally {
        recognizer.dispose();
      }

      _throwIfStopped();
      stage.value = RtStage.done;
      progress.value = 1.0;
    } catch (e) {
      if (e is RealtimeStopped) {
        // 用户主动停止：不是错误，stage 回 idle，句子保留
        stage.value = RtStage.idle;
      } else {
        final message = switch (e) {
          SherpaModelException() => e.message,
          SherpaAudioException() => e.message,
          RealtimeException() => e.message,
          _ => '实时转写失败（$e）',
        };
        error.value = message;
        stage.value = RtStage.error;
        if (e is SherpaModelException ||
            e is SherpaAudioException ||
            e is RealtimeException) {
          rethrow; // 已知类型原样上抛（调用方可按类型分类处理）
        }
        throw RealtimeException(message); // 未知引擎错误包装为中文异常
      }
    } finally {
      _running = false;
      _stopRequested = false;
    }
  }

  /// 流式主循环：逐块喂 → decode → partialText → endpoint 收句 → 逐句翻译。
  Future<void> _runStreaming(RtRecognizer recognizer, String wavPath) async {
    final wav = await _wavSource(wavPath, chunkSamples: chunkSamples);
    final stream = recognizer.createStream();
    var processed = 0; // 已喂样本数（时间戳按此推算）
    var sentenceStart = 0.0; // 当前句起始秒
    final total = wav.totalSamples > 0 ? wav.totalSamples : null;

    try {
      await for (final chunk in wav.chunks) {
        _throwIfStopped();
        recognizer.acceptWaveform(
          stream,
          chunk,
          sampleRate: sampleRate,
        );
        processed += chunk.length;
        if (total != null) {
          progress.value = (processed / total).clamp(0.0, 1.0);
        }
        // 解码直到模型吃不下更多音频
        while (recognizer.isReady(stream)) {
          _throwIfStopped();
          recognizer.decode(stream);
          final text = recognizer.getText(stream).trim();
          if (text.isNotEmpty) partialText.value = text;
          if (recognizer.isEndpoint(stream)) {
            final endSec = processed / sampleRate;
            await _finalizeSentence(
              recognizer,
              stream,
              text,
              sentenceStart,
              endSec,
            );
            sentenceStart = endSec;
          }
        }
      }

      // 全部喂完：标记输入结束，让模型刷新尾部上下文
      _throwIfStopped();
      recognizer.inputFinished(stream);
      while (recognizer.isReady(stream)) {
        _throwIfStopped();
        recognizer.decode(stream);
        final text = recognizer.getText(stream).trim();
        if (text.isNotEmpty) partialText.value = text;
        if (recognizer.isEndpoint(stream)) {
          final endSec = processed / sampleRate;
          await _finalizeSentence(
            recognizer,
            stream,
            text,
            sentenceStart,
            endSec,
          );
          sentenceStart = endSec;
        }
      }

      // 兜底：尾部可能还有未收的文本（无 endpoint 也能出句）
      final tail = recognizer.getText(stream).trim();
      if (tail.isNotEmpty) {
        final last = _sentencesList.isEmpty
            ? ''
            : _sentencesList.last.text.trim();
        if (tail != last) {
          await _finalizeSentence(
            recognizer,
            stream,
            tail,
            sentenceStart,
            processed / sampleRate,
          );
        }
      }
      partialText.value = '';
    } finally {
      recognizer.disposeStream(stream);
    }
  }

  /// 收尾一个完成的句子：加入列表 + reset 流 + 异步逐句翻译。
  Future<void> _finalizeSentence(
    RtRecognizer recognizer,
    RtStream stream,
    String text,
    double fromSec,
    double toSec,
  ) async {
    if (text.trim().isEmpty) return;
    recognizer.reset(stream);
    final sentence = RealtimeSentence(
      text: text.trim(),
      fromTs: fromSec,
      toTs: toSec,
    );
    _sentencesList.add(sentence);
    _publishSentences();
    debugPrint('[realtime] 句 [$fromSec~$toSec] $text');
    // 逐句翻译：异步执行，失败不阻塞转写（translation 留空）
    unawaited(_translateSentence(sentence));
  }

  Future<void> _translateSentence(RealtimeSentence sentence) async {
    try {
      final result = await _translate(sentence.text);
      if (result != null && result.trim().isNotEmpty) {
        sentence.translation = result.trim();
        _publishSentences(); // 更新译文后通知 UI
      }
    } catch (e) {
      debugPrint('[realtime] 句子翻译失败，跳过（可后续补）：$e');
    }
  }

  void _publishSentences() {
    sentences.value = List.unmodifiable(_sentencesList);
  }

  void _throwIfStopped() {
    if (_stopRequested) throw const RealtimeStopped();
  }

  /// 默认逐句翻译：复用 [TranslateApi]（配置/缓存），单句调 translateBatch。
  static Future<String?> _defaultTranslate(String text) async {
    try {
      final list = await TranslateApi().translateBatch([text]);
      if (list.isEmpty) return null;
      return list.first;
    } catch (e) {
      debugPrint('[realtime] 默认翻译失败：$e');
      return null;
    }
  }
}

/// 内部停止标记（start 捕获后静默收尾，不设为 error）。
class RealtimeStopped implements Exception {
  const RealtimeStopped();
}
