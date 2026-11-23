/// 「导入本地书」的编排（E1）。
///
/// 流程固定七步，**全在这一层**，页面只负责「点按钮 → 转圈 → 看一句话」：
/// 原生选文件 → 读字节 → 解码（[decodeTextBytes]）→ 切章
/// （[splitTxtChapters]）→ 落盘（[LocalBookStore]）→ 上书架
/// （[BookshelfStore]，`sourceName: 本地文件`、`detailUrl: local:<id>`）
/// → 删掉原生留下的临时文件。
///
/// ## 为什么编排要单独成 service，而不是写在页面的 onPressed 里
/// 1. **可测**：选文件那条通道可以用 `TestDefaultBinaryMessenger` 模拟，
///    落盘用临时目录，整条链路（含 GBK）能在 `flutter test` 里跑通；
/// 2. **可复用**：E2 的详情页 / 「重新导入」和书架页用的是同一套；
/// 3. **错误文案只有一处**：原生错误码 → 中文这句话，页面不需要认识任何 code。
///
/// ## 原生为什么不把内容回传
/// 书源导入（`pickTextFile`）走的是「原生读成 String 塞进 MethodChannel」，
/// 8MB 以内没问题。本地书的上限是 100MB，走通道会：① 复制一份 100MB 的
/// 字节数组进平台消息（Android Binder 事务上限 1MB，Flutter 会走共享内存但
/// 仍要整份拷贝）；② 拿不到「按需读一部分」的能力（EPUB 只能解压读取）。
/// 所以原生只把文件**拷到 App 私有目录**并回路径，Dart 自己去读。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../utils/text_decoding.dart';
import '../utils/txt_chapter_splitter.dart';
import 'bookshelf_store.dart';
import 'local_book_store.dart';

/// 选中的文件（原生回传的路径信息）。
class PickedBookFile {
  /// 文件名（含扩展名，`斗破苍穹.txt`）。
  final String name;

  /// App 私有目录里的绝对路径（原生已把内容拷好）。
  final String path;

  /// 字节数（原生实际拷了多少）。
  final int sizeBytes;

  /// 扩展名（小写、不含点；`txt` / `epub` / 空串）。
  final String ext;

  const PickedBookFile({
    required this.name,
    required this.path,
    this.sizeBytes = 0,
    this.ext = '',
  });

  /// 书名（去掉扩展名；页面提示用，真正的清洗在 `LocalBookStore` 里）。
  String get bookName {
    final lower = name.toLowerCase();
    if (lower.endsWith('.txt')) return name.substring(0, name.length - 4);
    if (lower.endsWith('.epub')) return name.substring(0, name.length - 5);
    return name;
  }

  @override
  String toString() => 'PickedBookFile($name, $sizeBytes bytes, $path)';
}

/// 一次「选文件」的结果（成功 / 取消 / 失败三态互斥）。
class BookPickResult {
  final PickedBookFile? file;
  final String? error;

  const BookPickResult({this.file, this.error});

  const BookPickResult.cancelled() : this();

  bool get isCancelled => file == null && error == null;

  bool get isOk => file != null && error == null;
}

/// 一次导入的结果。
///
/// 为什么要区分 [book] 与 [warning]：书可能已经**成功落盘**，只是「加进书架」
/// 这一步没成（书架满了 500 本、prefs 写失败）。这时告诉用户「导入失败」是错的
/// —— 正文已经在手机上，重新加书架就行。
class LocalBookImportResult {
  /// 落盘成功的书（失败 / 取消时 null）。
  final LocalBook? book;

  /// 失败原因（一句可直接显示的中文；null = 没失败）。
  final String? error;

  /// 成功但需要提醒的事（例如「已保存，但加入书架失败」）。
  final String? warning;

  /// 用户取消（页面什么都不做）。
  final bool cancelled;

  const LocalBookImportResult._({
    this.book,
    this.error,
    this.warning,
    this.cancelled = false,
  });

  const LocalBookImportResult.success(LocalBook book, {String? warning})
      : this._(book: book, warning: warning);

  const LocalBookImportResult.failed(String error) : this._(error: error);

  const LocalBookImportResult.cancel() : this._(cancelled: true);

  bool get isOk => book != null;
}

/// TXT 导入上限 32 MB。
///
/// 原生那条通道允许 100MB（EPUB 可能真有那么大，E3 会按需解压，不需要整本
/// 进内存），但 TXT 是**整本读进内存再解码**的：GBK 解出来是 UTF-16 字符串，
/// 内存占用约为文件字节数的 2 倍，切章还要再扫一遍。32MB 的文件在低端机上
/// 已经要占 100MB 上下的峰值，再大就不是「导入慢」而是「直接 OOM」了。
/// 超过这个数的 TXT 给用户一句明确的话，比崩溃好。
const int maxTxtImportBytes = 32 * 1024 * 1024;

/// 原生允许的硬上限（与 `FilePickerPlugin.MAX_BOOK_BYTES` 保持一致）。
const int maxPickedBookBytes = 100 * 1024 * 1024;

/// 选文件 + 导入的服务。
class LocalBookImportService {
  /// 与 `FilePickerPlugin.kt` 同名通道（`pickBookFile` 是新增方法）。
  static const MethodChannel channel = MethodChannel('bili_whitelist/files');

  final LocalBookStore? bookStore;
  final BookshelfStore? shelfStore;

  const LocalBookImportService({this.bookStore, this.shelfStore});

  LocalBookStore get _books => bookStore ?? LocalBookStore.instance;
  BookshelfStore get _shelf => shelfStore ?? BookshelfStore.instance;

  /// 拉起系统文件选择器 → 导入。**永不抛**。
  Future<LocalBookImportResult> pickAndImport() async {
    final picked = await pickBookFile();
    if (picked.isCancelled) return const LocalBookImportResult.cancel();
    if (!picked.isOk) {
      return LocalBookImportResult.failed(picked.error ?? '选择文件失败');
    }
    final file = picked.file!;
    // 先按原生上报的大小拦一道：33MB 的文件不该先读进内存再报错。
    if (file.sizeBytes > maxTxtImportBytes) {
      unawaited(_deleteQuietly(file.path));
      return LocalBookImportResult.failed(_tooLargeMessage());
    }
    try {
      final bytes = await readPickedBytes(file);
      if (bytes == null) {
        return const LocalBookImportResult.failed('读取文件失败（文件可能已被移走）');
      }
      return await importBytes(
        name: file.name,
        bytes: bytes,
        sizeBytes: file.sizeBytes > 0 ? file.sizeBytes : bytes.length,
      );
    } finally {
      // 原生拷进来的临时文件用完就删：它和最终落盘的 book.txt 是重复的，
      // 一本 5MB 的书留两份纯属浪费（删不掉也不影响功能）。
      unawaited(_deleteQuietly(file.path));
    }
  }

  /// 只选文件，不导入（测试 / 将来「先预览再导入」用）。
  Future<BookPickResult> pickBookFile() async {
    Object? raw;
    try {
      raw = await channel.invokeMethod<Object?>('pickBookFile');
    } on PlatformException catch (e) {
      return BookPickResult(error: _messageForError(e.code, e.message));
    } on MissingPluginException {
      return const BookPickResult(error: '当前版本不支持导入本地书');
    } catch (_) {
      return const BookPickResult(error: '选择文件失败，请重试');
    }
    if (raw == null) return const BookPickResult.cancelled();
    if (raw is! Map) {
      return const BookPickResult(error: '选择文件失败：返回的数据不对');
    }
    final path = raw['path'];
    if (path is! String || path.trim().isEmpty) {
      return const BookPickResult(error: '选择文件失败：没拿到文件路径');
    }
    return BookPickResult(
      file: PickedBookFile(
        name: raw['name'] is String && (raw['name'] as String).trim().isNotEmpty
            ? raw['name'] as String
            : '未命名.txt',
        path: path,
        sizeBytes: raw['sizeBytes'] is int ? raw['sizeBytes'] as int : 0,
        ext: raw['ext'] is String ? (raw['ext'] as String).toLowerCase() : '',
      ),
    );
  }

  /// 读原生拷好的文件字节；读不动 → null。
  ///
  /// 分两层拦：先按 `sizeBytes` / 文件长度拦超限（省一次内存分配），
  /// 再用 [maxTxtImportBytes] 兜一次（原生上报的大小可能是 0 或不准）。
  Future<List<int>?> readPickedBytes(PickedBookFile file) async {
    try {
      final f = File(file.path);
      if (!f.existsSync()) return null;
      final len = await f.length();
      if (len > maxTxtImportBytes) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 从内存字节导入（解码 → 切章 → 落盘 → 上书架）。**永不抛**。
  Future<LocalBookImportResult> importBytes({
    required String name,
    required List<int> bytes,
    int sizeBytes = 0,
    String? charsetHint,
  }) async {
    if (bytes.isEmpty) {
      return const LocalBookImportResult.failed('这个文件是空的');
    }
    final realSize = sizeBytes > 0 ? sizeBytes : bytes.length;
    if (realSize > maxTxtImportBytes) {
      return LocalBookImportResult.failed(_tooLargeMessage());
    }

    final decoded = decodeTextBytes(bytes, charsetHint: charsetHint);
    if (decoded.isMostlyGarbage) {
      return const LocalBookImportResult.failed(
        '这个文件的编码认不出来（不是 UTF-8 / GBK / UTF-16 文本），'
        '请另存为 UTF-8 后重试',
      );
    }

    final slices = splitTxtChapters(decoded.text);
    if (slices.isEmpty || decoded.text.trim().isEmpty) {
      return const LocalBookImportResult.failed('文件里没有可读的正文');
    }

    final book = await _books.importTxt(
      name: name,
      text: decoded.text,
      encoding: decoded.encoding,
      sizeBytes: realSize,
    );
    if (book == null) {
      return const LocalBookImportResult.failed('保存失败（本地存储不可用或空间不足）');
    }

    final added = await _shelf.saveBook(ShelfBook(
      name: book.name,
      author: book.author,
      sourceName: kLocalBookSourceName,
      detailUrl: book.detailUrl,
      lastChapterName: book.chapters.isEmpty ? '' : book.chapters.last.title,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      chapterCount: book.chapterCount,
    ));
    if (!added) {
      return LocalBookImportResult.success(
        book,
        warning: '已保存到手机，但加入书架失败（书架可能已满 500 本）',
      );
    }
    return LocalBookImportResult.success(book);
  }

  /// 原生错误码 → 中文。**映射只在这里做一处**。
  static String _messageForError(String code, String? detail) {
    switch (code) {
      case 'FILE_TOO_LARGE':
        return '文件太大（超过 ${maxPickedBookBytes ~/ (1024 * 1024)} MB）';
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

  static String _tooLargeMessage() =>
      '这个 TXT 有 ${(maxTxtImportBytes / (1024 * 1024)).toStringAsFixed(0)} MB 以上，'
      '暂时不支持（解码要占用两三倍内存），请先拆分再导入';

  /// 删临时文件（失败静默）。
  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // 删不掉不影响任何功能，系统下次清理缓存时会带走
    }
  }
}
