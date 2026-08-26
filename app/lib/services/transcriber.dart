/// whisper 本地语音转写服务（单例）。
///
/// 一次转写流程：
/// 1. 转写缓存命中 → 直接返回（同一视频同一集只转写一次）
/// 2. 模型：`WhisperModelManager.ensureModel`（下载/复用 ggml-base.bin）
/// 3. 音频：`WhisperAudioSource.getAudioPath`（离线缓存优先，否则临时下载）
/// 4. 转写：whisper_ggml 的 `WhisperController.transcribe`（内部 FFmpeg
///    自动把任意格式音频转 16k wav，segments 带 fromTs/toTs 时间戳）
/// 5. segments → `SubtitleCue` 列表 → 写转写缓存 → 返回
///
/// 并发控制：同时只允许一个转写任务，进行中再次调用抛错（拒绝并提示）。
/// 取消：`cancel()` 置标志位，在阶段边界生效（引擎内部推理不打断）。
/// 错误分类：模型下载 / 音频获取 / 转写分别抛中文提示异常
/// （[WhisperModelException] / [AudioSourceException] / [TranscribeException]）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../api/whisper_audio.dart';
import '../api/whisper_model.dart';
import '../models/subtitle.dart';
import '../models/whitelist_video.dart';
import 'transcription_cache.dart';

/// 转写错误（message 可直接展示给用户）。
class TranscribeException implements Exception {
  final String message;

  const TranscribeException(this.message);

  @override
  String toString() => 'TranscribeException: $message';
}

/// 转写执行函数（可注入替身；默认走 whisper_ggml 的 [WhisperController]）。
///
/// [audioPath] 任意格式音频文件；[language] 转写语言（'auto'/'zh' 等）；
/// [onProgress] 引擎进度回调 0~100。返回转写出的字幕条目；
/// 引擎内部失败返回 null（由调用方分类抛错）。
typedef TranscriptionRunner = Future<List<SubtitleCue>?> Function({
  required String audioPath,
  required String language,
  void Function(int percent)? onProgress,
});

/// whisper 本地转写服务（单例）。
class Transcriber {
  Transcriber({
    WhisperModelManager? modelManager,
    WhisperAudioSource? audioSource,
    TranscriptionCache? cache,
    TranscriptionRunner? transcribeOverride,
  })  : _modelManager = modelManager ?? WhisperModelManager.instance,
        _audioSource = audioSource ?? WhisperAudioSource(),
        _cache = cache ?? TranscriptionCache(),
        _transcribeOverride = transcribeOverride;

  static Transcriber? _instance;

  /// 全局单例（UI 直接用；测试通过 [debugOverride] 替换）。
  static Transcriber get instance => _instance ??= Transcriber();

  /// 测试注入：替换单例实现。
  @visibleForTesting
  static void debugOverride(Transcriber transcriber) => _instance = transcriber;

  /// 测试复位：清空单例，下次取回全新实例。
  @visibleForTesting
  static void debugReset() => _instance = null;

  final WhisperModelManager _modelManager;
  final WhisperAudioSource _audioSource;
  final TranscriptionCache _cache;
  final TranscriptionRunner? _transcribeOverride;

  bool _transcribing = false;
  bool _cancelRequested = false;

  /// 是否正在转写（UI 可据此显示状态/禁用按钮）。
  bool get isTranscribing => _transcribing;

  /// 请求取消当前转写（标志位；在阶段边界生效，引擎推理不打断）。
  void cancel() => _cancelRequested = true;

  /// 某集转写缓存（无则 null）。UI 可据此决定是否显示「本地转写」入口。
  Future<List<SubtitleCue>?> getCachedTranscription(
          String bvid, int pageIndex) =>
      _cache.getCached(bvid, pageIndex);

  /// 手动写入某集转写缓存（预留外部导入场景）。
  Future<void> saveTranscription(
          String bvid, int pageIndex, List<SubtitleCue> cues) =>
      _cache.save(bvid, pageIndex, cues);

  /// 清除某集转写缓存（「重新转写」前调用，保证下一次不命中旧结果）。
  Future<void> clearTranscription(String bvid, int pageIndex) =>
      _cache.clear(bvid, pageIndex);

  /// 转写某集：模型 → 音频 → whisper → cues → 缓存。
  ///
  /// [onProgress] 整体进度 0~1（模型下载 0~0.1，转写推理 0.1~1.0）。
  /// [language] 转写语言，默认 'auto'（自动检测）；中文视频可传 'zh'。
  ///
  /// 错误（中文提示，UI 可直接展示）：
  /// - 缓存命中 → 直接返回（不重复转写）
  /// - 转写进行中再次调用 → 抛「正在转写其他视频，请稍后再试」
  /// - 模型下载失败 → [WhisperModelException]
  /// - 音频获取失败 → [AudioSourceException]
  /// - whisper 引擎失败（返回 null / 抛异常 / 结果为空）→ [TranscribeException]
  Future<List<SubtitleCue>> transcribe(
    WhitelistVideo video,
    int pageIndex, {
    ValueChanged<double>? onProgress,
    String? language,
  }) async {
    // 1) 转写缓存命中：直接返回
    final hit = await _cache.getCached(video.bvid, pageIndex);
    if (hit != null) {
      debugPrint('[transcriber] 转写缓存命中 ${video.bvid}#$pageIndex');
      onProgress?.call(1.0);
      return hit;
    }

    // 2) 并发控制：同时只允许一个转写任务（简单：拒绝并提示）
    if (_transcribing) {
      throw const TranscribeException('正在转写其他视频，请稍后再试');
    }
    _transcribing = true;
    _cancelRequested = false;
    try {
      onProgress?.call(0.0);

      // 3) 模型（整体进度 0 ~ 0.1）
      await _modelManager.ensureModel(
        onProgress: (p) => onProgress?.call(p * 0.1),
      );
      _throwIfCanceled();

      // 4) 音频（离线缓存优先 / 临时下载）
      final audioPath = await _audioSource.getAudioPath(video, pageIndex);
      _throwIfCanceled();
      onProgress?.call(0.1);

      // 5) 转写（整体进度 0.1 ~ 1.0）：whisper 引擎 + 内部 FFmpeg 转码
      final runner = _transcribeOverride ?? _defaultRun;
      List<SubtitleCue>? cues;
      try {
        cues = await runner(
          audioPath: audioPath,
          language: language ?? 'auto',
          onProgress: (p) => onProgress?.call(0.1 + (p / 100) * 0.9),
        );
      } on TranscribeException {
        rethrow;
      } catch (e) {
        throw TranscribeException('转写失败：whisper 引擎异常（$e）');
      }
      if (cues == null) {
        throw const TranscribeException('转写失败：未能识别出字幕（音频可能无法解码）');
      }
      if (cues.isEmpty) {
        throw const TranscribeException('转写失败：未识别到任何语音内容');
      }
      _throwIfCanceled();

      // 6) 写缓存 + 清理 whisper 转码产生的临时 wav
      await _cache.save(video.bvid, pageIndex, cues);
      await _deleteWav(audioPath);
      onProgress?.call(1.0);
      return cues;
    } finally {
      _transcribing = false;
      _cancelRequested = false;
    }
  }

  /// 默认转写实现：whisper_ggml 的 `WhisperController.transcribe`。
  ///
  /// 模型路径与 [WhisperModelManager] 预下载路径一致
  /// （`<应用支持目录>/ggml-base.bin`），直接复用；`withSegments: true`
  /// 返回带时间戳的 segments。引擎内部失败返回 null（由 [transcribe] 分类抛错）。
  Future<List<SubtitleCue>?> _defaultRun({
    required String audioPath,
    required String language,
    void Function(int percent)? onProgress,
  }) async {
    final controller = WhisperController();
    final result = await controller.transcribe(
      model: WhisperModel.base,
      audioPath: audioPath,
      lang: language,
      withSegments: true,
      onProgress: onProgress,
    );
    if (result == null) return null;
    return segmentsToCues(result.transcription.segments ?? const []);
  }

  void _throwIfCanceled() {
    if (_cancelRequested) throw const TranscribeException('转写已取消');
  }

  /// 清理 whisper 转码产生的 `<音频路径>.wav`（best effort，失败静默）。
  Future<void> _deleteWav(String audioPath) async {
    try {
      final wav = File('$audioPath.wav');
      if (await wav.exists()) await wav.delete();
    } catch (_) {
      // 清理失败静默（残留 wav 由系统缓存清理兜底）
    }
  }
}

/// whisper segments → 字幕条目列表。
///
/// from/to 取秒（`Duration.inMilliseconds / 1000`，与 B 站字幕 JSON 的
/// from/to 秒单位一致）；content 去首尾空白；空文本段跳过。
List<SubtitleCue> segmentsToCues(List<WhisperTranscribeSegment> segments) {
  return [
    for (final s in segments)
      if (s.text.trim().isNotEmpty)
        SubtitleCue(
          from: s.fromTs.inMilliseconds / 1000,
          to: s.toTs.inMilliseconds / 1000,
          content: s.text.trim(),
        ),
  ];
}
