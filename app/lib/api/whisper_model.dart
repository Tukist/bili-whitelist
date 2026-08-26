/// whisper 本地 ASR 模型（ggml-base）下载管理。
///
/// - 模型文件：应用支持目录下 `ggml-base.bin`（约 142MB）。该路径与
///   whisper_ggml 包 `WhisperController` 的默认模型路径完全一致
///   （`<应用支持目录>/ggml-base.bin`），因此预置/预下载后转写直接复用，
///   包内 `downloadModel()` 检测到文件存在也会跳过。
/// - 下载源：hf-mirror（huggingface 国内镜像，302→200 已验证可达），
///   dio 全量下载 + 失败重试 1 次，进度回调 0~1；下载完成后校验文件大小
///   （>100MB 视为完整，防止 CDN 中断留下半截文件）。
/// - 错误分类：网络失败（DioException）与磁盘写入失败分别抛
///   [WhisperModelException]（中文提示，UI 可直接展示）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// 模型下载错误（message 可直接展示给用户）。
class WhisperModelException implements Exception {
  final String message;

  const WhisperModelException(this.message);

  @override
  String toString() => 'WhisperModelException: $message';
}

/// 模型文件下载函数（可注入替身；默认走 dio）。
typedef ModelFileDownloader = Future<void> Function(
  String url,
  String savePath,
  void Function(double progress)? onProgress,
);

/// whisper 本地模型（ggml-base）管理。
class WhisperModelManager {
  WhisperModelManager({
    Dio? dio,
    ModelFileDownloader? downloadFile,
    Directory? rootDir,
    this.minModelBytes = kMinModelBytes,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 5),
              headers: {'User-Agent': kBrowserUA},
            )),
        _downloadOverride = downloadFile,
        _rootDirOverride = rootDir;

  static WhisperModelManager? _instance;

  /// 全局单例（转写服务默认使用；测试通过 [debugOverride] 替换）。
  static WhisperModelManager get instance => _instance ??= WhisperModelManager();

  /// 测试注入：替换单例实现。
  @visibleForTesting
  static void debugOverride(WhisperModelManager manager) => _instance = manager;

  /// 测试复位：清空单例，下次取回全新实例。
  @visibleForTesting
  static void debugReset() => _instance = null;

  /// 模型文件名（whisper_ggml 的 base 模型默认路径即 `<支持目录>/ggml-base.bin`）。
  static const String modelFileName = 'ggml-base.bin';

  /// 模型下载地址（hf-mirror；官方源 huggingface.co 国内不可直连）。
  static const String modelUrl =
      'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base.bin';

  /// 模型最小合理大小（base 约 142MB；小于 100MB 视为下载不完整/损坏）。
  static const int kMinModelBytes = 100 * 1024 * 1024;

  final Dio _dio;
  final ModelFileDownloader? _downloadOverride;
  final Directory? _rootDirOverride;

  /// 判定「模型可用」的最小文件大小（默认 [kMinModelBytes]；测试可调小）。
  final int minModelBytes;

  Future<Directory> _rootDir() async =>
      _rootDirOverride ?? await getApplicationSupportDirectory();

  Future<File> _modelFile() async =>
      File('${(await _rootDir()).path}/$modelFileName');

  /// 模型是否就绪：文件存在且大小合理（> minModelBytes）。
  Future<bool> isModelReady() async {
    final f = await _modelFile();
    try {
      return await f.exists() && await f.length() > minModelBytes;
    } catch (_) {
      return false; // 读取异常（权限等）视为未就绪
    }
  }

  /// 模型文件大小（字节；文件不存在/读取失败返回 0，显示用）。
  Future<int> modelSize() async {
    final f = await _modelFile();
    try {
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// 确保模型可用并返回模型文件路径。
  ///
  /// 已存在（大小合理）直接返回路径、不重复下载；否则从 [modelUrl] 全量下载
  /// （失败重试 1 次），[onProgress] 回调 0~1。
  /// 下载失败抛 [WhisperModelException]（中文提示，区分网络/磁盘）。
  Future<String> ensureModel({ValueChanged<double>? onProgress}) async {
    final file = await _modelFile();
    if (await isModelReady()) {
      debugPrint('[whisper_model] 模型已存在，跳过下载 ${file.path}');
      return file.path;
    }

    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      onProgress?.call(0);
      try {
        await _downloadFile(modelUrl, file.path, (p) {
          onProgress?.call(p.clamp(0.0, 1.0).toDouble());
        });
        // 下载完成后的完整性校验（防 CDN 中断返回半截文件）
        if (!await isModelReady()) {
          throw const WhisperModelException('模型文件下载不完整，请检查网络后重试');
        }
        debugPrint('[whisper_model] 模型下载完成 ${file.path}');
        return file.path;
      } on DioException catch (e) {
        lastError = WhisperModelException(
          '模型下载失败：网络异常（${e.message ?? e.type.name}），请检查网络后重试',
        );
      } catch (e) {
        lastError = e is WhisperModelException
            ? e
            : WhisperModelException('模型下载失败：写入本地失败（$e）');
      }
      // 清掉半成品（若有）再重试/收尾
      await _deleteIfExists(file.path);
    }
    throw lastError!;
  }

  ModelFileDownloader get _downloadFile => _downloadOverride ?? _defaultDownloadFile;

  /// 默认下载：独立 dio 全量下载，进度按字节比例回调（total 未知时不回调）。
  Future<void> _defaultDownloadFile(
    String url,
    String savePath,
    void Function(double progress)? onProgress,
  ) async {
    await _dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
      options: Options(followRedirects: true), // hf-mirror 302 → 真实文件
    );
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删除失败静默（残留半成品由下次下载覆盖）
    }
  }
}
