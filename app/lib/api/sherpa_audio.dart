/// sherpa 流式转写用音频准备：B 站 m4s 音频 → 16kHz 单声道 wav。
///
/// 流程：
/// 1. [SherpaAudioSource.getAudioPath] 拿 m4s 音频路径（离线缓存优先，
///    否则临时下载 dash.audio 流，带 Referer/UA）；
/// 2. ffmpeg-kit（`ffmpeg_kit_flutter_new_min`）转码：
///    `ffmpeg -y -i in.m4s -ar 16000 -ac 1 -f wav out.wav`（预处理几秒完成）；
/// 3. 输出到与 m4s 同目录的 `<bvid>_<pageIndex>_16k.wav`，已存在则直接复用
///    （幂等，避免重试时重复转码）。
///
/// wav 转码是转写前的预处理，转写时按块流式读该 wav（见 RealtimeTranscriber）。
/// 失败抛 [SherpaAudioException]（中文提示，区分音频获取/ffmpeg 转码）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../cache/download_manager.dart';
import '../config.dart';
import '../models/whitelist_video.dart';
import 'bilibili_api.dart';

/// 音频获取错误（message 可直接展示给用户）。
class AudioSourceException implements Exception {
  final String message;

  const AudioSourceException(this.message);

  @override
  String toString() => 'AudioSourceException: $message';
}

/// 转写音频获取服务。
///
/// 依赖注入与 [DownloadManager] 同风格：默认实现走真实网络
/// （[BiliApi.fetchPlayUrl] + 独立 dio 下载，带 Referer/UA），
/// 测试可注入 fake（不碰真实网络/插件）。
class SherpaAudioSource {
  SherpaAudioSource({
    DownloadManager? downloadManager,
    PlayUrlFetcher? fetchPlayUrl,
    FileDownloader? downloadFile,
    Directory? rootDir,
  })  : _manager = downloadManager ?? DownloadManager.instance,
        _fetchOverride = fetchPlayUrl,
        _downloadOverride = downloadFile,
        _rootDirOverride = rootDir;

  /// 临时音频目录名（应用支持目录下）。
  static const String tmpDirName = 'audio_tmp';

  final DownloadManager _manager;
  final PlayUrlFetcher? _fetchOverride;
  final FileDownloader? _downloadOverride;
  final Directory? _rootDirOverride;

  BiliApi? _api;

  Future<Directory> _rootDir() async =>
      _rootDirOverride ?? await getApplicationSupportDirectory();

  Future<Directory> _audioTmpDir() async {
    final dir = Directory('${(await _rootDir()).path}/$tmpDirName');
    await dir.create(recursive: true);
    return dir;
  }

  /// 当前集音频文件路径：
  /// 1. 离线缓存优先：`DownloadManager` 缓存记录在册且 audio.m4s 文件
  ///    真实存在 → 直接复用（不重复下载）；
  /// 2. 否则临时下载当前集 DASH 音频流（fnval=16 的 dash.audio[0]，
  ///    带 Referer/UA）到 `<root>/audio_tmp/<bvid>_<pageIndex>.m4s`；
  /// 3. 失败抛 [AudioSourceException]（中文提示，区分网络/业务/写入）。
  Future<String> getAudioPath(WhitelistVideo video, int pageIndex) async {
    // 1) 离线缓存优先：索引在册 + audioPath 非空 + 文件真实存在
    final cached = _manager.getCached(video.bvid, pageIndex);
    if (cached != null && cached.audioPath.isNotEmpty) {
      final f = File(cached.audioPath);
      try {
        if (await f.exists() && await f.length() > 0) {
          debugPrint('[sherpa_audio] 复用离线缓存音频 ${cached.audioPath}');
          return cached.audioPath;
        }
      } catch (_) {
        // 缓存文件读取异常 → 走临时下载
      }
    }

    // 2) 临时下载当前集 audio 流（fnval=16 的 dash.audio[0]）
    final cid = _cidOf(video, pageIndex);
    PlayUrlResult result;
    try {
      result = await _fetchPlayUrl(bvid: video.bvid, cid: cid);
    } on BiliApiException catch (e) {
      throw AudioSourceException('音频流获取失败：${e.message}');
    } on DioException catch (e) {
      throw AudioSourceException(
        '音频流获取失败：网络异常（${e.message ?? e.type.name}），请稍后重试',
      );
    } catch (e) {
      throw AudioSourceException('音频流获取失败（$e）');
    }
    if (result.dashAudioUrls.isEmpty) {
      throw const AudioSourceException('该视频没有可用的音频流（可能被限流，请稍后重试）');
    }

    final url = result.dashAudioUrls.first;
    final dir = await _audioTmpDir();
    final target = '${dir.path}/${video.bvid}_$pageIndex.m4s';
    final targetFile = File(target);
    // 已临时下载过则直接复用（幂等，避免转写重试时重复下载）
    try {
      if (await targetFile.exists() && await targetFile.length() > 0) {
        debugPrint('[sherpa_audio] 复用临时音频 $target');
        return target;
      }
    } catch (_) {
      // 文件读取异常 → 重新下载
    }

    try {
      await _downloadFile(url, target, null);
    } on DioException catch (e) {
      throw AudioSourceException(
        '音频下载失败：网络异常（${e.message ?? e.type.name}），请稍后重试',
      );
    } catch (e) {
      throw AudioSourceException('音频下载失败（$e）');
    }
    try {
      if (!await targetFile.exists() || await targetFile.length() == 0) {
        throw const AudioSourceException('音频下载失败：文件为空');
      }
    } on AudioSourceException {
      rethrow;
    } catch (e) {
      throw AudioSourceException('音频下载失败（$e）');
    }
    debugPrint('[sherpa_audio] 临时音频下载完成 $target');
    return target;
  }

  PlayUrlFetcher get _fetchPlayUrl => _fetchOverride ?? _defaultFetchPlayUrl;
  FileDownloader get _downloadFile => _downloadOverride ?? _defaultDownloadFile;

  /// 默认取流：DASH（fnval=16）拿 audio 流。
  Future<PlayUrlResult> _defaultFetchPlayUrl({
    required String bvid,
    required int cid,
  }) async {
    final api = _api ??= BiliApi();
    return api.fetchPlayUrl(bvid: bvid, cid: cid, qn: 80, fnval: 16);
  }

  /// 默认下载：独立 dio，仅 Referer + 浏览器 UA（与离线缓存下载同策略）。
  Future<void> _defaultDownloadFile(
    String url,
    String savePath,
    DownloadProgressCallback? onProgress,
  ) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 3),
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

  /// 分 P cid：多 P 取 pages[pageIndex]，否则用视频主 cid。
  int _cidOf(WhitelistVideo video, int pageIndex) {
    final pages = video.pages;
    if (pages != null && pages.isNotEmpty && pageIndex < pages.length) {
      return pages[pageIndex].cid;
    }
    return video.cid;
  }
}

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
/// 依赖注入与 [SherpaAudioSource] 同风格：默认实现走真实音频获取 + ffmpeg-kit，
/// 测试可注入 fake（不碰真实网络/原生 ffmpeg）。
class SherpaAudioPreparer {
  SherpaAudioPreparer({
    SherpaAudioSource? audioSource,
    FfmpegRunner? runFfmpeg,
  })  : _audioSource = audioSource ?? SherpaAudioSource(),
        _ffmpegOverride = runFfmpeg;

  final SherpaAudioSource _audioSource;
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
  /// （显式 pcm_s16le，保证输出 16-bit PCM wav）。
  ///
  /// 仅真机/模拟器调用（ffmpeg-kit 是原生插件）；单测注入 fake 不会走到这里。
  Future<bool> _defaultFfmpeg(String input, String output) async {
    final session = await FFmpegKit.execute(
        '-y -i "$input" -ar 16000 -ac 1 -c:a pcm_s16le -f wav "$output"');
    final code = await session.getReturnCode();
    return ReturnCode.isSuccess(code);
  }
}
