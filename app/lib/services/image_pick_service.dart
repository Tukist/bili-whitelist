import 'package:flutter/services.dart';

/// 「从相册选一张图」的**原生选图通道**封装（v2.50.0，合集封面用）。
///
/// 对应原生 `ImagePickPlugin.kt`（MethodChannel
/// `bili_whitelist/pick_image`）：拉起系统图片选择器（Android SAF 的
/// `ACTION_OPEN_DOCUMENT` + `type=image/*`），原生侧把选中图片的**原始字节**
/// 回传（**不回路径** —— SAF 给的 content:// URI 只有拿到临时读权限的那个进程
/// 能用，Android 10+ 分区存储下也拿不到可用的绝对路径）。
///
/// 与 `ScheduleImportService` 完全同一套约定（同一个作者、同一条理由）：
/// - **不引新依赖**（不用 image_picker / file_selector，也不用自己写插件包），
///   沿用仓库既有的「MainActivity 手动注册 MethodChannel」做法；
/// - **不加任何权限**：SAF 是系统给的合法入口，用户自己点选，App 只拿到那
///   **一个**文件的临时读权限（`READ_MEDIA_IMAGES` 那一套完全不需要）；
/// - 三种结果分开：**用户取消** → [ImagePickResult.isCancelled]（页面什么都不
///   做，也不弹提示）；成功 → [ImagePickResult.bytes]；失败 →
///   [ImagePickResult.error] 是一句能直接显示的中文。
///
/// 原生侧错误码 → 文案的映射只在这里做一处，页面对错误码零感知。
class ImagePickResult {
  /// 图片原始字节（取消 / 失败时 null）。
  final Uint8List? bytes;

  /// 文件名（只用来取扩展名 + 提示，例如 `IMG_2024.jpg`）。
  final String fileName;

  /// 面向用户的中文错误（null = 没出错）。
  final String? error;

  const ImagePickResult({this.bytes, this.fileName = '', this.error});

  /// 用户取消选择。
  const ImagePickResult.cancelled() : this();

  bool get isCancelled => bytes == null && error == null;

  bool get isOk => bytes != null && error == null;

  @override
  String toString() =>
      'ImagePickResult(${bytes?.length ?? 0} bytes, "$fileName", error=$error)';
}

/// 选图服务。
///
/// **测试可以不注入替身**：直接 mock `bili_whitelist/pick_image` 这条
/// MethodChannel 就能模拟「选中 / 取消 / 失败」三种结果（见
/// `test/collection_cover_pick_test.dart`），与 `schedule_import_test.dart`
/// 同一条路子。
class ImagePickService {
  static const MethodChannel channel = MethodChannel('bili_whitelist/pick_image');

  /// 图片大小上限 10 MB（与原生侧 `ImagePickPlugin.MAX_BYTES` 保持一致）。
  ///
  /// 为什么要有上限：整张图会被原样读进内存再写进私有目录，手机相册里的
  /// RAW / 全景图动辄几十 MB，随手选一张就可能把 App 顶到 OOM。10 MB 对
  /// 「封面」这种用途极其宽裕（常见手机直出 JPG 3~8 MB）。
  static const int maxImageBytes = 10 * 1024 * 1024;

  const ImagePickService();

  /// 拉起系统图片选择器挑一张图。**永不抛**：所有异常路径都变成
  /// [ImagePickResult.error]（页面只需要一句 toast）。
  Future<ImagePickResult> pickImage() async {
    Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>('pickImage');
    } on PlatformException catch (e) {
      return ImagePickResult(error: _messageForError(e.code, e.message));
    } on MissingPluginException {
      // 非 Android（或没注册插件）：给一句人话，不要抛到页面
      return const ImagePickResult(error: '当前版本不支持从相册选图');
    } catch (_) {
      return const ImagePickResult(error: '选择图片失败，请重试');
    }
    if (raw == null) return const ImagePickResult.cancelled();
    if (raw is! Map) {
      return const ImagePickResult(error: '选择图片失败：返回的数据不对');
    }
    final bytes = raw['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) {
      return const ImagePickResult(error: '这张图是空的，读不到内容');
    }
    // 原生已经拦过一次，这里再拦一次：通道那头将来若改了上限，
    // 这行能保证「内存里不会出现超限的大数组」这条不变量。
    if (bytes.length > maxImageBytes) {
      return ImagePickResult(error: _tooLargeMessage(bytes.length));
    }
    return ImagePickResult(
      bytes: bytes,
      fileName: raw['name'] is String ? raw['name'] as String : '',
    );
  }

  static String _tooLargeMessage(int bytes) {
    final mb = bytes / (1024 * 1024);
    return '这张图 ${mb.toStringAsFixed(1)} MB，超过 '
        '${maxImageBytes ~/ (1024 * 1024)} MB 上限，请先压小一点再选';
  }

  static String _messageForError(String code, String? detail) {
    switch (code) {
      case 'FILE_TOO_LARGE':
        final size = int.tryParse(detail ?? '');
        return size != null && size > 0 && size < maxImageBytes * 10
            ? _tooLargeMessage(size)
            : '这张图超过 ${maxImageBytes ~/ (1024 * 1024)} MB 上限，'
                '请先压小一点再选';
      case 'BUSY':
        return '上一次选择还没结束，稍等一下再试';
      case 'NO_PICKER':
        return '系统里没有可用的图片选择器';
      case 'READ_FAILED':
        return '读取图片失败${detail == null || detail.isEmpty ? '' : '：$detail'}';
      default:
        return '选择图片失败${detail == null || detail.isEmpty ? '' : '：$detail'}';
    }
  }
}
