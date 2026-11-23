import 'package:flutter/services.dart';

/// 「从手机里挑一个文本文件」的**原生选文件通道**封装（v2.70.0，书源导入用）。
///
/// 对应原生 `FilePickerPlugin.kt`（MethodChannel `bili_whitelist/files`）：
/// 拉起系统文件选择器（Android SAF 的 `ACTION_OPEN_DOCUMENT`，MIME 收窄到
/// json / 纯文本 / octet-stream），原生侧把选中文件的**文本内容**回传
/// （**不回路径** —— SAF 给的 content:// URI 只有拿到临时读权限的那个进程能用，
/// Android 10+ 分区存储下也没有可用的绝对路径）。
///
/// 与 `ImagePickService` / `ScheduleImportService` 完全同一套约定：
/// - **不引新依赖**，沿用仓库既有的「MainActivity 手动注册 MethodChannel」做法；
/// - **不加任何权限**：用户自己点选，App 只拿到那一个文件的临时读权限；
/// - 四种结果分开：**用户取消**（[FileImportResult.isCancelled]，页面什么都不做）、
///   成功（[FileImportResult.file]）、失败（[FileImportResult.error] 是一句
///   能直接显示的中文）。**永不抛异常到界面**。
///
/// 原生侧错误码 → 中文文案的映射只在这里做一处，页面对错误码零感知。
class PickedTextFile {
  /// 文件名（只用于提示：`sources.json`）。
  final String name;

  /// 文件全文（已按 UTF-8 解码、已去掉 BOM）。
  final String content;

  const PickedTextFile({required this.name, required this.content});

  /// 空文件 / 全是空白：调用方据此给「这个文件是空的」，而不是丢给 JSON 解析器
  /// 报一句「没有找到书源 JSON」。
  bool get isBlank => content.trim().isEmpty;

  @override
  String toString() => 'PickedTextFile("$name", ${content.length} chars)';
}

/// 一次选文件的结果（成功 / 取消 / 失败三态互斥）。
class FileImportResult {
  /// 选中的文件（取消或失败时 null）。
  final PickedTextFile? file;

  /// 面向用户的中文错误（null = 没出错）。
  final String? error;

  const FileImportResult({this.file, this.error});

  /// 用户取消选择。
  const FileImportResult.cancelled() : this();

  bool get isCancelled => file == null && error == null;

  bool get isOk => file != null && error == null;
}

/// 去掉 UTF-8 BOM（`\uFEFF`）。
///
/// 为什么单独抽成纯函数：Windows 记事本 / 部分导出工具写的 .json 会带 BOM，
/// BOM 留着会让 `jsonDecode` 在第一个字符就报「格式不正确」，而用户看到的
/// 文件内容好好的 —— 这是最难自查的一类失败。原生侧已经去过一次，这里再做
/// 一次是防御（通道那头将来改坏也不让 BOM 进解析器）。
String stripUtf8Bom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

/// 文件大小上限 8 MB（与原生侧 `FilePickerPlugin.MAX_BYTES` 保持一致）。
///
/// 为什么要有上限：整份文本会被读进内存再丢给 JSON 解析器，书源文件正常只有
/// 几十 KB ~ 一两 MB；真选了 50 MB 的日志文件，App 会先卡死再 OOM。
const int maxImportFileBytes = 8 * 1024 * 1024;

/// 超限时给用户看的一句话（页脚单测直接断言这句）。
String fileTooLargeMessage() =>
    '文件太大（超过 ${maxImportFileBytes ~/ (1024 * 1024)} MB），'
    '书源文件一般只有几十 KB，请确认选的是书源文件';

/// 选文件服务。
///
/// **测试可以不注入替身**：直接 mock `bili_whitelist/files` 这条 MethodChannel
/// 就能模拟「选中 / 取消 / 失败」三种结果（见 `test/file_import_service_test.dart`），
/// 与 `collection_cover_pick_test.dart` 同一条路子。
class FileImportService {
  static const MethodChannel channel = MethodChannel('bili_whitelist/files');

  const FileImportService();

  /// 拉起系统文件选择器挑一个文本文件。**永不抛**。
  Future<FileImportResult> pickTextFile() async {
    Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>('pickTextFile');
    } on PlatformException catch (e) {
      return FileImportResult(error: _messageForError(e.code, e.message));
    } on MissingPluginException {
      // 非 Android（或没注册插件）：给一句人话，不要抛到页面
      return const FileImportResult(error: '当前版本不支持从文件导入');
    } catch (_) {
      return const FileImportResult(error: '选择文件失败，请重试');
    }
    if (raw == null) return const FileImportResult.cancelled();
    if (raw is! Map) {
      return const FileImportResult(error: '选择文件失败：返回的数据不对');
    }
    final content = raw['content'];
    if (content is! String) {
      return const FileImportResult(error: '选择文件失败：没读到文件内容');
    }
    // 原生已经拦过一次大小；这里再按 sizeBytes 拦一次：通道那头将来若把上限
    // 改坏，这行保证「页面不会拿到一份超限的巨型字符串」这条不变量。
    final size = raw['sizeBytes'];
    if (size is int && size > maxImportFileBytes) {
      return FileImportResult(error: fileTooLargeMessage());
    }
    return FileImportResult(
      file: PickedTextFile(
        name: raw['name'] is String ? raw['name'] as String : '',
        content: stripUtf8Bom(content),
      ),
    );
  }

  /// 原生错误码 → 一句话。**映射只在这里做一处**。
  static String _messageForError(String code, String? detail) {
    switch (code) {
      case 'FILE_TOO_LARGE':
        return fileTooLargeMessage();
      case 'BAD_ENCODING':
        return detail == null || detail.isEmpty
            ? '这个文件不是 UTF-8 编码，请另存为 UTF-8 后再导入'
            : detail;
      case 'BUSY':
        return '上一次选择还没结束，稍等一下再试';
      case 'NO_PICKER':
        return '系统里没有可用的文件选择器';
      case 'READ_FAILED':
        return detail == null || detail.isEmpty ? '读取文件失败' : detail;
      default:
        return '选择文件失败${detail == null || detail.isEmpty ? '' : '：$detail'}';
    }
  }
}
