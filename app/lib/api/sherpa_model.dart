/// sherpa-onnx 流式 ASR 模型（8 语 zipformer transducer）下载与解压管理。
///
/// - 模型包：`sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10`
///   （覆盖 阿拉伯/英/印尼/日/俄/泰/越/中 8 语，transducer 结构：
///   encoder.onnx + decoder.onnx + joiner.onnx + tokens.txt，model-type=zipformer2）。
///   官方 GitHub release 打包为 tar.bz2（约 247MB），GitHub releases 国内可达
///   （HF 不可达，故不用 hf-mirror）。
/// - 落地：应用支持目录 `<root>/sherpa/8lang/<模型名>/`（含 .onnx 与 tokens.txt），
///   tar 包先下载到 `<root>/sherpa/<包名>.tar.bz2`，解压成功后删除（省空间）。
/// - 下载：dio 全量下载带进度 0~1（响应无 Content-Length 时用 [kModelBytes] 兜底），
///   失败重试 1 次；解压用 archive 包 `extractFileToDisk`（内置 BZip2+Tar 解码）。
/// - 完整性判断：四个必需文件（encoder/decoder/joiner .onnx + tokens.txt）都存在，
///   且 encoder 文件大小 > [kMinEncoderBytes]（防半截文件/中断解压）。
/// - 错误统一抛 [SherpaModelException]（中文提示，UI 可直接展示）。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// 模型错误（message 可直接展示给用户）。
class SherpaModelException implements Exception {
  final String message;

  const SherpaModelException(this.message);

  @override
  String toString() => 'SherpaModelException: $message';
}

/// 模型文件下载函数（可注入替身；默认走 dio）。
typedef ModelFileDownloader = Future<void> Function(
  String url,
  String savePath,
  void Function(double progress)? onProgress,
);

/// tar 包解压函数（可注入替身；默认 archive 的 [extractFileToDisk]）。
typedef ArchiveExtractor = Future<void> Function(
  String tarPath,
  String destDir,
);

/// 解压后的模型文件路径集合（喂给 sherpa-onnx OnlineRecognizer）。
class SherpaModelFiles {
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;

  const SherpaModelFiles({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });
}

/// sherpa-onnx 8 语流式模型管理（单例；测试通过 [debugOverride] 替换）。
class SherpaModelManager {
  SherpaModelManager({
    Dio? dio,
    ModelFileDownloader? downloadFile,
    ArchiveExtractor? extract,
    Directory? rootDir,
    this.minModelBytes = kMinModelBytes,
    this.minEncoderBytes = kMinEncoderBytes,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 10),
              headers: {'User-Agent': kBrowserUA},
            )),
        _downloadOverride = downloadFile,
        _extractOverride = extract,
        _rootDirOverride = rootDir;

  static SherpaModelManager? _instance;

  /// 全局单例（转写服务默认使用；测试通过 [debugOverride] 替换）。
  static SherpaModelManager get instance => _instance ??= SherpaModelManager();

  /// 测试注入：替换单例实现。
  @visibleForTesting
  static void debugOverride(SherpaModelManager manager) => _instance = manager;

  /// 测试复位：清空单例，下次取回全新实例。
  @visibleForTesting
  static void debugReset() => _instance = null;

  /// 模型包文件名（GitHub asr-models release 资产名）。
  static const String modelFileName =
      'sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10.tar.bz2';

  /// 模型包下载地址（GitHub releases；2026-08 实测可达，302→release-assets）。
  static const String modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$modelFileName';

  /// 模型包完整大小（字节，约 247MB；GitHub API 实测 258999581）。
  static const int kModelBytes = 258999581;

  /// tar 包最小合理大小（小于 50MB 视为下载不完整/损坏）。
  static const int kMinModelBytes = 50 * 1024 * 1024;

  /// encoder.onnx 最小合理大小（int8 encoder 约 100MB+；小于 10MB 视为损坏）。
  static const int kMinEncoderBytes = 10 * 1024 * 1024;

  /// 模型解压根目录名（应用支持目录下）。
  static const String rootDirName = 'sherpa';

  /// 8 语模型解压子目录名。
  static const String langDirName = '8lang';

  /// 解压后的顶层目录名（tar 包内）。
  static const String modelDirName =
      'sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10';

  final Dio _dio;
  final ModelFileDownloader? _downloadOverride;
  final ArchiveExtractor? _extractOverride;
  final Directory? _rootDirOverride;

  /// 判定「tar 包完整」的最小字节数（默认 [kMinModelBytes]；测试可调小）。
  final int minModelBytes;

  /// 判定「encoder.onnx 完整」的最小字节数（默认 [kMinEncoderBytes]；测试可调小）。
  final int minEncoderBytes;

  Future<Directory> _rootDir() async =>
      _rootDirOverride ?? await getApplicationSupportDirectory();

  Future<Directory> _sherpaDir() async {
    final dir = Directory('${(await _rootDir()).path}/$rootDirName');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _langDir() async {
    final dir = Directory(
        '${(await _rootDir()).path}/$rootDirName/$langDirName');
    await dir.create(recursive: true);
    return dir;
  }

  /// 模型包 tar 文件路径。
  Future<File> _tarFile() async =>
      File('${(await _sherpaDir()).path}/$modelFileName');

  /// 模型解压目录（tar 包内顶层目录）。
  Future<Directory> _modelDir() async =>
      Directory('${(await _langDir()).path}/$modelDirName');

  /// 递归查找模型目录下的四个必需文件（按文件名前缀/后缀匹配，
  /// 兼容 `encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx` 这类长名）。
  Future<SherpaModelFiles?> _findFiles(Directory dir) async {
    final files = <File>[];
    try {
      await for (final e in dir.list(recursive: true)) {
        if (e is File) files.add(e);
      }
    } catch (_) {
      return null; // 目录不存在/读不了 → 未就绪
    }
    String? encoder, decoder, joiner, tokens;
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (name == 'tokens.txt') {
        tokens = f.path;
      } else if (name.startsWith('encoder') && name.endsWith('.onnx')) {
        encoder = f.path;
      } else if (name.startsWith('decoder') && name.endsWith('.onnx')) {
        decoder = f.path;
      } else if (name.startsWith('joiner') && name.endsWith('.onnx')) {
        joiner = f.path;
      }
    }
    if (encoder == null || decoder == null || joiner == null || tokens == null) {
      return null;
    }
    return SherpaModelFiles(
      encoder: encoder,
      decoder: decoder,
      joiner: joiner,
      tokens: tokens,
    );
  }

  /// 模型是否就绪：解压目录存在且四个必需文件齐 + encoder 大小合理。
  Future<bool> isModelReady() async {
    final files = await _findFiles(await _modelDir());
    if (files == null) return false;
    try {
      return await File(files.encoder).length() > minEncoderBytes;
    } catch (_) {
      return false;
    }
  }

  /// 模型文件集合（未就绪返回 null）。
  Future<SherpaModelFiles?> modelFiles() async {
    if (!await isModelReady()) return null;
    return _findFiles(await _modelDir());
  }

  /// 模型目录路径（未就绪返回 null；显示用）。
  Future<String?> modelDir() async {
    if (!await isModelReady()) return null;
    return (await _modelDir()).path;
  }

  /// 模型**目标**目录路径（无论是否就绪都返回；供 UI 提示用户
  /// 「手动放置模型文件到该目录」，未就绪时同样可用）。
  Future<String> targetModelDir() async => (await _modelDir()).path;

  /// 确保模型可用并返回模型目录路径。
  ///
  /// 已就绪直接返回、不重复下载；否则下载 tar.bz2（失败重试 1 次）→ 解压到
  /// `<root>/sherpa/8lang/` → 校验完整性 → 返回目录。
  /// [onProgress] 回调 0~1（下载 0~0.9，解压 0.9~1.0）。
  /// 下载/解压失败抛 [SherpaModelException]（中文提示，区分网络/解压/写入）。
  Future<String> ensureModel({ValueChanged<double>? onProgress}) async {
    final modelDirPath = (await _modelDir()).path;
    if (await isModelReady()) {
      debugPrint('[sherpa_model] 模型已就绪，跳过下载 $modelDirPath');
      onProgress?.call(1.0);
      return modelDirPath;
    }

    // 1) 下载 tar 包（进度 0 ~ 0.9，失败重试 1 次）
    final tar = await _tarFile();
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      onProgress?.call(0);
      try {
        await _downloadFile(modelUrl, tar.path, (p) {
          onProgress?.call((p * 0.9).clamp(0.0, 0.9));
        });
        if (!await _tarOk(tar)) {
          throw const SherpaModelException('模型包下载不完整，请检查网络后重试');
        }
        lastError = null;
        break;
      } on DioException catch (e) {
        lastError = SherpaModelException(
          '模型下载失败：网络异常（${e.message ?? e.type.name}），请检查网络后重试',
        );
      } catch (e) {
        lastError = e is SherpaModelException
            ? e
            : SherpaModelException('模型下载失败：写入本地失败（$e）');
      }
      await _deleteIfExists(tar.path); // 清掉半成品再重试/收尾
    }
    if (lastError != null) throw lastError;

    // 2) 解压（进度 0.9 ~ 1.0）
    try {
      onProgress?.call(0.9);
      await _extract(tar.path, (await _langDir()).path);
    } catch (e) {
      await _deleteIfExists(tar.path);
      throw SherpaModelException('模型解压失败（$e），请检查存储空间后重试');
    }
    // 解压成功删 tar 包（省 247MB 空间；失败仅 debug 提示，不影响使用）
    await _deleteIfExists(tar.path);

    // 3) 校验解压结果
    if (!await isModelReady()) {
      throw const SherpaModelException(
          '模型解压不完整，请删除应用数据后重新下载');
    }
    onProgress?.call(1.0);
    debugPrint('[sherpa_model] 模型就绪 $modelDirPath');
    return modelDirPath;
  }

  /// tar 包完整性：文件存在且大小 > minModelBytes。
  Future<bool> _tarOk(File tar) async {
    try {
      return await tar.exists() && await tar.length() > minModelBytes;
    } catch (_) {
      return false;
    }
  }

  ModelFileDownloader get _downloadFile =>
      _downloadOverride ?? _defaultDownloadFile;
  ArchiveExtractor get _extract => _extractOverride ?? _defaultExtract;

  /// 默认下载：独立 dio 全量下载，进度按字节比例回调
  /// （total 未知/chunked 时用 [kModelBytes] 兜底，保证进度仍递增）。
  Future<void> _defaultDownloadFile(
    String url,
    String savePath,
    void Function(double progress)? onProgress,
  ) async {
    await _dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        final t = total > 0 ? total : kModelBytes;
        onProgress?.call((received / t).clamp(0.0, 1.0));
      },
      options: Options(followRedirects: true), // GitHub 302 → release-assets
    );
  }

  /// 默认解压：archive 的 `extractFileToDisk`（识别 .tar.bz2，内部 BZip2+Tar）。
  Future<void> _defaultExtract(String tarPath, String destDir) async {
    await extractFileToDisk(tarPath, destDir);
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删除失败静默（残留由下次下载覆盖）
    }
  }
}
