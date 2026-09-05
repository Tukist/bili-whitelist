import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import '../config.dart';

/// 评论图片「保存到系统相册」（v2.16.19+），对应原生
/// `GalleryController.kt`（MethodChannel `bili_whitelist/gallery`）：
///
/// 流程：Dart 侧先带浏览器 UA/Referer 下载图片字节（i0.hdslb.com 图床
/// 一般无需防盗链头，兜底带上更稳）→ 字节 + 文件名 + MIME 交给原生
/// 插入相册（API 29+ MediaStore 免权限；API 26~28 原生弹授权框，一次
/// 调用内完成）。
class GallerySaveResult {
  /// 是否保存成功。
  final bool ok;

  /// 给用户看的结果文案（成功/失败都非空）。
  final String message;

  const GallerySaveResult({required this.ok, required this.message});
}

class GallerySaver {
  static const MethodChannel _channel =
      MethodChannel('bili_whitelist/gallery');

  /// 图片下载 dio：浏览器 UA + Referer 兜底（与评论页 _imgHeaders 同源）。
  static Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: const {'User-Agent': kBrowserUA, 'Referer': kBiliReferer},
      ));

  /// 下载图片字节（原图/gif 原始字节，保存后相册里的 gif 可动）。
  static Future<Uint8List> downloadBytes(String url) async {
    final resp = await _dio().get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw DioException(
        requestOptions: resp.requestOptions,
        message: '图片内容为空',
      );
    }
    return Uint8List.fromList(data);
  }

  /// 下载并保存 URL 图片到系统相册。
  ///
  /// 成功 [GallerySaveResult.ok]=true（message 为成功提示）；失败给出
  /// 中文原因（下载失败 / 权限拒绝 / 相册写入失败等）。
  static Future<GallerySaveResult> saveUrlImage(String url) async {
    Uint8List bytes;
    try {
      bytes = await downloadBytes(url);
    } on DioException {
      return const GallerySaveResult(
        ok: false,
        message: '图片下载失败，请检查网络后重试',
      );
    }
    final ext = _extensionOf(url);
    final mime = _mimeOf(ext);
    final fileName = 'bili_comment_'
        '${DateTime.now().millisecondsSinceEpoch}_'
        '${_rand4()}.$ext';
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'saveImage',
        {'bytes': bytes, 'fileName': fileName, 'mimeType': mime},
      );
      final status = map?['status'];
      if (status == 'saved') {
        return const GallerySaveResult(ok: true, message: '已保存到系统相册');
      }
      return GallerySaveResult(ok: false, message: '保存失败（$status）');
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        return const GallerySaveResult(
          ok: false,
          message: '未授予存储权限，无法保存到相册（可在系统设置中开启后重试）',
        );
      }
      return GallerySaveResult(
        ok: false,
        message: '保存失败：${e.message ?? e.code}',
      );
    } catch (e) {
      return GallerySaveResult(ok: false, message: '保存失败：$e');
    }
  }

  /// 从 URL 提取扩展名（默认 jpg）。评论图床 URL 常带 `@…w…jpg` 之类的
  /// 缩放后缀，取最后一个 `image 扩展名` 片段。
  static String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final m = RegExp(r'\.(jpg|jpeg|png|gif|webp)', caseSensitive: false)
        .firstMatch(path.toLowerCase());
    return m?.group(1) ?? 'jpg';
  }

  static String _mimeOf(String ext) {
    if (ext == 'jpg' || ext == 'jpeg') return 'image/jpeg';
    if (ext == 'png') return 'image/png';
    if (ext == 'gif') return 'image/gif';
    if (ext == 'webp') return 'image/webp';
    return 'image/jpeg';
  }

  static String _rand4() =>
      (DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0');
}
