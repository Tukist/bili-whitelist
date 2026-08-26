/// sherpa 流式转写用音频准备：B 站 m4s 音频 → 16kHz 单声道 wav。
///
/// 流程：
/// 1. 复用 [WhisperAudioSource.getAudioPath]（离线缓存优先，否则临时下载
///    dash.audio 流），拿到 m4s 音频路径；
/// 2. ffmpeg-kit（whisper_ggml 传递依赖 `ffmpeg_kit_flutter_new_min`）转码：
///    `ffmpeg -y -i in.m4s -ar 16000 -ac 1 -f wav out.wav`（预处理几秒完成）；
/// 3. 输出到与 m4s 同目录的 `<bvid>_<pageIndex>_16k.wav`，已存在则直接复用
///    （幂等，避免重试时重复转码）。
///
/// wav 转码是转写前的预处理，转写时按块流式读该 wav（见 RealtimeTranscriber）。
/// 失败抛 [SherpaAudioException]（中文提示，区分音频获取/ffmpeg 转码）。
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';

import '../models/whitelist_video.dart';
import 'whisper_audio.dart';

/// 音频准备错误（message 可直接展示给用户）。
class SherpaAudioException implements Exception {
  final String message;

  const SherpaAudioException(this.message);

  @override
  String toString() => 'SherpaAudioException: $message';
}

/// ffmpeg 转码执行函数（可注入替身；默认走 FFmpegKit.execute）。
///
/// [input] 源音频路径；[output] 目标 wav 路径。返回是否成功。
typedef FfmpegRunner = Future<bool> Function(String input, String output);

/// sherpa 流式转写音频准备服务。
///
/// 依赖注入与 [WhisperAudioSource] 同风格：默认实现走真实音频获取 + ffmpeg-kit，
/// 测试可注入 fake（不碰真实网络/原生 ffmpeg）。
class SherpaAudioPreparer {
  SherpaAudioPreparer({
    WhisperAudioSource? audioSource,
    FfmpegRunner? runFfmpeg,
  })  : _audioSource = audioSource ?? WhisperAudioSource(),
        _ffmpegOverride = runFfmpeg;

  final WhisperAudioSource _audioSource;
  final FfmpegRunner? _ffmpegOverride;

  /// 转码输出文件名后缀（16k 单声道 wav）。
  static const String wavSuffix = '_16k.wav';

  /// 把某集音频转成 16kHz 单声道 wav，返回 wav 路径。
  ///
  /// [onProgress] 回调 0~1（转码无分步进度，完成前固定 0.5，完成后 1.0）。
  /// 失败抛 [SherpaAudioException]（中文提示）。
  Future<String> prepareWav(
    WhitelistVideo video,
    int pageIndex, {
    ValueChanged<double>? onProgress,
  }) async {
    // 1) 拿 m4s 音频路径（离线缓存优先 / 临时下载）
    String m4s;
    try {
      m4s = await _audioSource.getAudioPath(video, pageIndex);
    } on AudioSourceException catch (e) {
      throw SherpaAudioException('音频准备失败：${e.message}');
    }
    onProgress?.call(0.3);

    // 2) 目标 wav 路径与 m4s 同目录（复用已转码结果）
    final wavPath = '$m4s$wavSuffix';
    final wav = File(wavPath);
    try {
      if (await wav.exists() && await wav.length() > 0) {
        debugPrint('[sherpa_audio] 复用已转码 wav $wavPath');
        onProgress?.call(1.0);
        return wavPath;
      }
    } catch (_) {
      // 文件读取异常 → 重新转码
    }

    // 3) ffmpeg 转码 16k mono wav
    onProgress?.call(0.5);
    final ok = await _runFfmpeg(m4s, wavPath);
    if (!ok) {
      throw SherpaAudioException(
          '音频转码失败：ffmpeg 返回非零退出码（音频可能无法解码）');
    }
    try {
      if (!await wav.exists() || await wav.length() == 0) {
        throw const SherpaAudioException('音频转码失败：输出 wav 为空');
      }
    } on SherpaAudioException {
      rethrow;
    } catch (e) {
      throw SherpaAudioException('音频转码失败（$e）');
    }
    onProgress?.call(1.0);
    debugPrint('[sherpa_audio] 16k wav 就绪 $wavPath');
    return wavPath;
  }

  FfmpegRunner get _runFfmpeg => _ffmpegOverride ?? _defaultFfmpeg;

  /// 默认转码：ffmpeg-kit `-y -i in -ar 16000 -ac 1 -c:a pcm_s16le -f wav out`
  /// （显式 pcm_s16le 与 whisper_ggml 同款，保证输出 16-bit PCM wav）。
  ///
  /// 仅真机/模拟器调用（ffmpeg-kit 是原生插件）；单测注入 fake 不会走到这里。
  Future<bool> _defaultFfmpeg(String input, String output) async {
    final session = await FFmpegKit.execute(
        '-y -i "$input" -ar 16000 -ac 1 -c:a pcm_s16le -f wav "$output"');
    final code = await session.getReturnCode();
    return ReturnCode.isSuccess(code);
  }
}
