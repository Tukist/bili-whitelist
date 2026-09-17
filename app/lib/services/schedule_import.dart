import 'package:flutter/services.dart';

/// 日程表「导入 Excel」的**原生选文件通道**封装（v2.34.0）。
///
/// 对应原生 `ScheduleImportPlugin.kt`（MethodChannel
/// `bili_whitelist/schedule_import`）：拉起系统文件选择器（Android SAF 的
/// `ACTION_OPEN_DOCUMENT`）让用户挑一个 `.xlsx`，原生侧把整个文件的字节
/// 回传（**不回路径**——SAF 给的 content:// URI 只有拿到临时读权限的那个
/// 进程能用，而且 Android 10+ 分区存储下拿不到可用的绝对路径）。
///
/// 三种结果分开（这是本类存在的全部意义）：
/// - **用户取消** → [ScheduleImportPick.isCancelled]，页面**什么都不做**、
///   也不弹提示（点开选择器又退出来是正常操作，弹一句"导入失败"很烦）；
/// - **成功** → [ScheduleImportPick.bytes]（原始字节，交给
///   `xlsx_reader.readXlsx` 解析）；
/// - **失败** → [ScheduleImportPick.error] 是一句能直接显示的中文。
///
/// 原生侧的错误码 → 文案的映射**只在这里**做一处，页面对错误码零感知。
class ScheduleImportPick {
  /// 文件内容（取消 / 失败时 null）。
  final Uint8List? bytes;

  /// 文件名（仅用于提示，比如「已导入 超级代办 大三上.xlsx」）。
  final String fileName;

  /// 面向用户的中文错误（null = 没出错）。
  final String? error;

  const ScheduleImportPick({this.bytes, this.fileName = '', this.error});

  /// 用户取消选择。
  const ScheduleImportPick.cancelled() : this();

  bool get isCancelled => bytes == null && error == null;

  bool get isOk => bytes != null && error == null;

  @override
  String toString() => 'ScheduleImportPick(${bytes?.length ?? 0} bytes, '
      '"$fileName", error=$error)';
}

/// 选文件服务。**留了构造函数不 const 的余地**：页面把它的实例注进来，
/// 测试可以给一个假的（见 `test/schedule_import_test.dart`），
/// 也可以只 mock MethodChannel 来验证真的发了什么调用。
class ScheduleImportService {
  static const MethodChannel channel =
      MethodChannel('bili_whitelist/schedule_import');

  /// 文件大小上限 5 MB（与原生侧 `ScheduleImportPlugin.MAX_BYTES` 保持一致）。
  ///
  /// 为什么要有上限：整份 xlsx 会被原样读进内存（zip 解压还要再放大几倍），
  /// 用户随手选一个 200MB 的表格就可能把 App 顶到 OOM。5MB 对"日程表"这种
  /// 文本表格来说极其宽裕（用户原型文件 515KB，其中 500KB 还是内嵌图片）。
  static const int maxFileBytes = 5 * 1024 * 1024;

  const ScheduleImportService();

  /// 拉起系统文件选择器挑一个 xlsx。**永不抛**：所有异常路径都变成
  /// [ScheduleImportPick.error]（页面只需要一句 toast）。
  Future<ScheduleImportPick> pickXlsx() async {
    Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>('pickXlsx');
    } on PlatformException catch (e) {
      return ScheduleImportPick(error: _messageForError(e.code, e.message));
    } on MissingPluginException {
      // 非 Android（或没注册插件）：给一句人话，不要抛到页面
      return const ScheduleImportPick(error: '当前版本不支持系统文件选择器');
    } catch (_) {
      return const ScheduleImportPick(error: '选择文件失败，请重试');
    }
    if (raw == null) return const ScheduleImportPick.cancelled();
    if (raw is! Map) {
      return const ScheduleImportPick(error: '选择文件失败：返回的数据不对');
    }
    final bytes = raw['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) {
      return const ScheduleImportPick(error: '这个文件是空的，没有内容可导入');
    }
    // 原生已经拦过一次，这里再拦一次：通道那头将来若改了上限，
    // 这行能保证"内存里不会出现超限的大数组"这条不变量。
    if (bytes.length > maxFileBytes) {
      return ScheduleImportPick(
        error: _tooLargeMessage(bytes.length),
      );
    }
    // 非 zip 的文件在解析前就能判掉（xlsx 一定是 zip）：这样"选错了文件"
    // 和"文件坏了"能给出不同的提示，用户知道该怎么办。
    if (!_looksLikeZip(bytes)) {
      return const ScheduleImportPick(
        error: '这不是一个 .xlsx 表格（Excel 2007+ 的表格才支持导入）',
      );
    }
    return ScheduleImportPick(
      bytes: bytes,
      fileName: raw['name'] is String ? raw['name'] as String : '',
    );
  }

  static bool _looksLikeZip(Uint8List b) =>
      b.length >= 4 && b[0] == 0x50 && b[1] == 0x4B && b[2] == 0x03 && b[3] == 0x04;

  static String _tooLargeMessage(int bytes) {
    final mb = bytes / (1024 * 1024);
    return '这个文件 ${mb.toStringAsFixed(1)} MB，超过 '
        '${maxFileBytes ~/ (1024 * 1024)} MB 上限，导入会占用太多内存';
  }

  static String _messageForError(String code, String? detail) {
    switch (code) {
      case 'FILE_TOO_LARGE':
        final size = int.tryParse(detail ?? '');
        return size != null && size > 0 && size < maxFileBytes * 10
            ? _tooLargeMessage(size)
            : '这个文件超过 ${maxFileBytes ~/ (1024 * 1024)} MB 上限，'
                '导入会占用太多内存';
      case 'BUSY':
        return '上一次选择还没结束，稍等一下再试';
      case 'NO_PICKER':
        return '系统里没有可用的文件选择器';
      case 'READ_FAILED':
        return '读取文件失败${detail == null || detail.isEmpty ? '' : '：$detail'}';
      default:
        return '选择文件失败${detail == null || detail.isEmpty ? '' : '：$detail'}';
    }
  }
}
