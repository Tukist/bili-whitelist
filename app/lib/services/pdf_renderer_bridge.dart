/// PDF 页渲染的原生封装（v2.74.0）。
///
/// ## 为什么要有这一层抽象
/// 本地书 PDF 的「页」= 一张渲染出来的图片，渲染只能由 Android 的 `PdfRenderer`
/// 完成（见 `PdfRenderPlugin.kt`）。如果 parser / store / 阅读页直接调
/// `MethodChannel`，这三层就都没法在 `flutter test` 里跑了 —— 测试宿主没有原生
/// 实现，通道会直接 `MissingPluginException`。抽成 [PdfRendererBridge] 之后：
/// - 生产走 [NativePdfRenderer]（一个 MethodChannel 薄封装）；
/// - 测试注入假实现（几行代码就能造出「3 页、第一页 595×842」的假文档）。
///
/// ## 为什么渲染结果只回路径
/// 一张书页位图 5~7MB，走通道要整份拷贝；而 `Image.file` 本来是 Flutter 图片
/// 缓存的正常入口（它自己按可用内存淘汰）。所以原生把 PNG 写进
/// `<filesDir>/reader/pdfcache/<bookId>/<页号>@<宽度>.png`，这里只传路径与尺寸。
///
/// ## 错误文案
/// 原生的错误码到中文的映射**只在这一层**做（与 `local_book_import_service`
/// 对 FilePicker 错误码的做法一致）：上层拿到的永远是能直接显示的一句话。
library;

import 'package:flutter/services.dart';

import 'pdf_cache_policy.dart';

/// 渲染宽度上限：比这更宽只是浪费内存（8MB 位图预算下实际可用宽度 ≈ 1200）。
const int kPdfMaxRenderWidth = 2048;

/// 渲染宽度下限（太窄看不清）。
const int kPdfMinRenderWidth = 320;

/// 默认渲染宽度。
///
/// 为什么是固定值而不是「屏幕物理宽度」：同一页在不同宽度下会各渲染一份缓存，
/// 旋转屏幕就翻倍；而 1080 已经覆盖绝大多数手机（1080~1440 物理宽），
/// 显示时由 `BoxFit.fitWidth` 缩放，肉眼看不出差别。取舍写在这里，别在页面里
/// 再算一遍。
const int kPdfDefaultRenderWidth = 1080;

/// 一次 `openPdf` 的结果（页数 + 第一页尺寸）。
class PdfDocumentInfo {
  final int pageCount;

  /// 第一页的尺寸（PDF 的点，72dpi）。只用于算长宽比。
  final int width;
  final int height;

  const PdfDocumentInfo({
    required this.pageCount,
    this.width = 0,
    this.height = 0,
  });
}

/// 一页的渲染结果（落盘的 PNG）。
class PdfRenderedPage {
  /// PNG 的绝对路径（`Image.file` 直接用）。
  final String path;

  /// 位图实际像素尺寸（按原始页面比例缩放过）。
  final int width;
  final int height;

  /// 文件字节数（诊断用）。
  final int bytes;

  const PdfRenderedPage({
    required this.path,
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
  });

  double get aspectRatio => height <= 0 ? 0 : width / height;

  @override
  String toString() => 'PdfRenderedPage($path, ${width}x$height, $bytes B)';
}

/// 渲染失败：[message] 是**可以直接显示给用户**的一句中文。
class PdfRenderException implements Exception {
  final String message;

  /// 原生错误码（诊断 / 测试断言用；UI 只用 [message]）。
  final String? code;

  const PdfRenderException(this.message, {this.code});

  @override
  String toString() => message;
}

/// 原生 PDF 能力（可注入假实现）。
abstract class PdfRendererBridge {
  /// 打开文档读页数与首开尺寸。失败抛 [PdfRenderException]。
  Future<PdfDocumentInfo> open(String path);

  /// 渲染第一页的封面（PNG 字节，很小）。失败返回 null（封面不是必需品）。
  Future<Uint8List?> renderCover(String path, {int widthPx = 400});

  /// 渲染第 [index] 页到缓存目录，返回文件路径。
  ///
  /// [cacheKey] 是缓存子目录名（用书籍 id），同一页同宽度第二次调用直接命中。
  Future<PdfRenderedPage> renderPage({
    required String path,
    required int index,
    int widthPx = kPdfDefaultRenderWidth,
    required String cacheKey,
  });

  /// 删掉一本书的渲染缓存，返回删了几个文件。
  Future<int> clearCache(String cacheKey);

  /// 缓存目录里的所有文件（淘汰策略的输入）。
  Future<List<PdfCacheFile>> cacheFiles();

  /// 按路径删缓存文件，返回删了几个。
  Future<int> deleteCacheFiles(List<String> paths);
}

/// 生产实现：`bili_whitelist/pdf` 通道（`PdfRenderPlugin.kt`）。
class NativePdfRenderer implements PdfRendererBridge {
  static const MethodChannel channel = MethodChannel('bili_whitelist/pdf');

  static final NativePdfRenderer instance = NativePdfRenderer();

  const NativePdfRenderer();

  @override
  Future<PdfDocumentInfo> open(String path) async {
    final raw = await _invoke('openPdf', {'path': path});
    if (raw is! Map) {
      throw const PdfRenderException('读取 PDF 失败（返回的数据不对）');
    }
    return PdfDocumentInfo(
      pageCount: _asInt(raw['pageCount']),
      width: _asInt(raw['width']),
      height: _asInt(raw['height']),
    );
  }

  @override
  Future<Uint8List?> renderCover(String path, {int widthPx = 400}) async {
    try {
      final raw = await _invoke('renderCover', {
        'path': path,
        'targetWidthPx': _clampWidth(widthPx),
      });
      if (raw is! Map) return null;
      final bytes = raw['bytes'];
      if (bytes is Uint8List) return bytes;
      if (bytes is List) {
        return Uint8List.fromList([for (final b in bytes) if (b is int) b]);
      }
      return null;
    } on PdfRenderException {
      // 封面只是装饰：渲染失败就当没有，不拖累整本书导入
      return null;
    }
  }

  @override
  Future<PdfRenderedPage> renderPage({
    required String path,
    required int index,
    int widthPx = kPdfDefaultRenderWidth,
    required String cacheKey,
  }) async {
    final raw = await _invoke('renderPage', {
      'path': path,
      'index': index,
      'targetWidthPx': _clampWidth(widthPx),
      'cacheKey': cacheKey,
    });
    if (raw is! Map) {
      throw const PdfRenderException('这一页渲染失败（返回的数据不对）');
    }
    final out = raw['path'];
    if (out is! String || out.trim().isEmpty) {
      throw const PdfRenderException('这一页渲染失败（没拿到图片路径）');
    }
    return PdfRenderedPage(
      path: out,
      width: _asInt(raw['width']),
      height: _asInt(raw['height']),
      bytes: _asInt(raw['bytes']),
    );
  }

  @override
  Future<int> clearCache(String cacheKey) async {
    try {
      final raw = await _invoke('clearCache', {'cacheKey': cacheKey});
      return _asInt(raw);
    } on PdfRenderException {
      return 0; // 清缓存失败不该拦住「删书」
    }
  }

  @override
  Future<List<PdfCacheFile>> cacheFiles() async {
    try {
      final raw = await _invoke('cacheFiles', const {});
      if (raw is! List) return const [];
      final out = <PdfCacheFile>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final path = e['path'];
        if (path is! String || path.isEmpty) continue;
        out.add(PdfCacheFile(
          path: path,
          bookKey: e['bookKey'] is String ? e['bookKey'] as String : '',
          bytes: _asInt(e['bytes']),
          modifiedMs: _asInt(e['modified']),
        ));
      }
      return out;
    } on PdfRenderException {
      return const [];
    }
  }

  @override
  Future<int> deleteCacheFiles(List<String> paths) async {
    if (paths.isEmpty) return 0;
    try {
      final raw = await _invoke('deleteCacheFiles', {'paths': paths});
      return _asInt(raw);
    } on PdfRenderException {
      return 0;
    }
  }

  /// 通道调用 + 异常归一（**错误码 → 中文只在这里做一处**）。
  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw const PdfRenderException(
        '当前版本不支持读取 PDF（原生模块未注册）',
        code: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (e) {
      throw PdfRenderException(
        _messageForError(e.code, e.message),
        code: e.code,
      );
    } on PdfRenderException {
      rethrow;
    } catch (e) {
      throw PdfRenderException('PDF 渲染失败（${e.runtimeType}）');
    }
  }

  static String _messageForError(String code, String? detail) {
    switch (code) {
      case 'FILE_NOT_FOUND':
        return 'PDF 文件不在了（可能被清理或删除了）';
      case 'NOT_PDF':
        return '这不是有效的 PDF 文件（可能已损坏）';
      case 'ENCRYPTED':
        return 'PDF 有密码保护，暂不支持';
      case 'PAGE_OUT_OF_RANGE':
        return detail == null || detail.isEmpty ? '页号越界' : detail;
      case 'RENDER_FAILED':
        return detail == null || detail.isEmpty ? '这一页渲染失败' : detail;
      default:
        return detail == null || detail.isEmpty ? 'PDF 渲染失败' : detail;
    }
  }

  static int _clampWidth(int width) =>
      width.clamp(kPdfMinRenderWidth, kPdfMaxRenderWidth);
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}
