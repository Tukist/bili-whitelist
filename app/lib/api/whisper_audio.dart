/// whisper 转写用音频获取：优先复用离线缓存已下载的 audio.m4s，
/// 没有则临时下载当前集的 DASH 音频流（供 whisper 转码为 wav 后转写）。
///
/// 临时音频不写入正式离线缓存（不污染 cache_index），放独立目录
/// `<应用支持目录>/audio_tmp/<bvid>_<pageIndex>.m4s`。
library;

import 'dart:io';

import 'package:dio/dio.dart';
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
class WhisperAudioSource {
  WhisperAudioSource({
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
          debugPrint('[whisper_audio] 复用离线缓存音频 ${cached.audioPath}');
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
        debugPrint('[whisper_audio] 复用临时音频 $target');
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
    debugPrint('[whisper_audio] 临时音频下载完成 $target');
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
