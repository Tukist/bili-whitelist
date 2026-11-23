/// 「导入本地书」的编排（E1 v2.72 起；E3 v2.73 起按格式分派）。
///
/// 流程固定成一条流水线，**全在这一层**，页面只负责「点按钮 → 转圈 → 看一句话」：
/// 原生选文件 → 读字节 → `LocalBookParsers.dispatcher` 按扩展名选解析器
/// → 解析（TXT 解码切章 / EPUB 解压取 spine / PDF 读页数并按页渲染封面）
/// → 落盘（[LocalBookStore]）
/// → 上书架（[BookshelfStore]，`sourceName: 本地文件`、`detailUrl: local:<id>`）
/// → 删掉原生留下的临时文件。
///
/// ## 为什么编排要单独成 service，而不是写在页面的 onPressed 里
/// 1. **可测**：选文件那条通道可以用 `TestDefaultBinaryMessenger` 模拟，
///    落盘用临时目录，整条链路（含 GBK、含 EPUB）能在 `flutter test` 里跑通；
/// 2. **可复用**：将来的详情页 / 「重新导入」和书架页用的是同一套；
/// 3. **错误文案只有一处**：原生错误码 + 各解析器的异常 → 一句中文，
///    页面不需要认识任何 code，也不认识任何格式。
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

import 'bookshelf_store.dart';
import 'local_book_parser.dart';
import 'local_book_store.dart';

/// 选中的文件（原生回传的路径信息）。
class PickedBookFile {
  /// 文件名（含扩展名，`斗破苍穹.txt`）。
  final String name;

  /// App 私有目录里的绝对路径（原生已把内容拷好）。
  final String path;

  /// 字节数（原生实际拷了多少）。
  final int sizeBytes;

  /// 扩展名（小写、不含点；`txt` / `epub` / `pdf` / 空串）。
  final String ext;

  const PickedBookFile({
    required this.name,
    required this.path,
    this.sizeBytes = 0,
    this.ext = '',
  });

  /// 书名（去掉扩展名；页面提示用，真正的清洗在 `LocalBookStore` 里）。
  String get bookName => titleFromFileName(name);

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

  /// 导入过程中被跳过的章节数（EPUB 缺章时有值，用于给用户一句提醒）。
  final int skippedChapters;

  /// 用户取消（页面什么都不做）。
  final bool cancelled;

  const LocalBookImportResult._({
    this.book,
    this.error,
    this.warning,
    this.skippedChapters = 0,
    this.cancelled = false,
  });

  const LocalBookImportResult.success(
    LocalBook book, {
    String? warning,
    int skippedChapters = 0,
  }) : this._(
          book: book,
          warning: warning,
          skippedChapters: skippedChapters,
        );

  const LocalBookImportResult.failed(String error) : this._(error: error);

  const LocalBookImportResult.cancel() : this._(cancelled: true);

  bool get isOk => book != null;
}

/// TXT 导入上限（= [TxtBookParser.maxBytes]）。
///
/// 原生那条通道允许 100MB（EPUB 就是那么大，解压时按需读取），但 TXT 是
/// **整本读进内存再解码**的：GBK 解出来是 UTF-16 字符串，内存占用约为文件
/// 字节数的 2 倍，切章还要再扫一遍。32MB 的文件在低端机上已经要占 100MB
/// 上下的峰值，再大就不是「导入慢」而是「直接 OOM」了。
const int maxTxtImportBytes = TxtBookParser.defaultMaxBytes;

/// 原生允许的硬上限（与 `FilePickerPlugin.MAX_BOOK_BYTES` 保持一致）。
const int maxPickedBookBytes = 100 * 1024 * 1024;

/// 选文件 + 导入的服务。
class LocalBookImportService {
  /// 与 `FilePickerPlugin.kt` 同名通道（`pickBookFile` 是新增方法）。
  static const MethodChannel channel = MethodChannel('bili_whitelist/files');

  final LocalBookStore? bookStore;
  final BookshelfStore? shelfStore;

  /// 测试注入：解析器分派（默认 [LocalBookParsers.dispatcher]）。
  ///
  /// 只在测试里用（例如验证「不支持格式」的文案），生产一律走默认。
  final LocalBookParser? Function(String ext, String fileName)? parserOverride;

  const LocalBookImportService({
    this.bookStore,
    this.shelfStore,
    this.parserOverride,
  });

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
    final ext = _extOf(file);
    final parser = _parserFor(ext, file.name);
    if (parser == null) {
      unawaited(_deleteQuietly(file.path));
      return LocalBookImportResult.failed(
        LocalBookParsers.unsupportedMessage(ext),
      );
    }
    // 先按原生上报的大小拦一道：不该先把 100MB 读进内存再报错。
    if (file.sizeBytes > parser.maxBytes) {
      unawaited(_deleteQuietly(file.path));
      return LocalBookImportResult.failed(_tooLargeMessage(parser));
    }
    try {
      // PDF 这类「必须拿到原文件」的格式直接走路径：把 100MB 读进内存再写回
      // 临时文件是白搬两遍（`PdfRenderer` 只认文件描述符）。
      final fileParser = parser is FileBasedLocalBookParser ? parser : null;
      if (fileParser != null) {
        if (!File(file.path).existsSync()) {
          return const LocalBookImportResult.failed(
            '读取文件失败（文件可能已被移走）',
          );
        }
        final realSize =
            file.sizeBytes > 0 ? file.sizeBytes : _lengthQuietly(file.path);
        return await _importParsed(
          parser: parser,
          name: file.name,
          realSize: realSize,
          parse: () => fileParser.parseFile(
            file.path,
            fileName: file.name,
            sizeBytes: realSize,
          ),
        );
      }
      final bytes = await readPickedBytes(file, limit: parser.maxBytes);
      if (bytes == null) {
        return const LocalBookImportResult.failed('读取文件失败（文件可能已被移走）');
      }
      return await importBytes(
        name: file.name,
        bytes: bytes,
        sizeBytes: file.sizeBytes > 0 ? file.sizeBytes : bytes.length,
        ext: ext,
      );
    } finally {
      // 原生拷进来的临时文件用完就删：它和最终落盘的内容是重复的，
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

  /// 读原生拷好的文件字节；读不动 / 超过 [limit] → null。
  ///
  /// 分两层拦：先按 `sizeBytes` / 文件长度拦超限（省一次内存分配），
  /// 再用 [limit] 兜一次（原生上报的大小可能是 0 或不准）。
  Future<List<int>?> readPickedBytes(
    PickedBookFile file, {
    int limit = maxTxtImportBytes,
  }) async {
    try {
      final f = File(file.path);
      if (!f.existsSync()) return null;
      final len = await f.length();
      if (len > limit) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 从内存字节导入（按 [ext] / 文件名分派 → 解析 → 落盘 → 上书架）。
  /// **永不抛**。
  Future<LocalBookImportResult> importBytes({
    required String name,
    required List<int> bytes,
    int sizeBytes = 0,
    String? charsetHint,
    String? ext,
  }) async {
    if (bytes.isEmpty) {
      return const LocalBookImportResult.failed('这个文件是空的');
    }
    final realExt = _normalizeExt(ext ?? _extOfName(name));
    final parser = _parserFor(realExt, name);
    if (parser == null) {
      return LocalBookImportResult.failed(
        LocalBookParsers.unsupportedMessage(realExt),
      );
    }
    final realSize = sizeBytes > 0 ? sizeBytes : bytes.length;
    if (realSize > parser.maxBytes) {
      return LocalBookImportResult.failed(_tooLargeMessage(parser));
    }
    return _importParsed(
      parser: parser,
      name: name,
      realSize: realSize,
      parse: () => parser.parse(
        Uint8List.fromList(bytes),
        fileName: name,
        charsetHint: charsetHint,
      ),
    );
  }

  /// 解析 + 落盘 + 上书架的公共段（[parse] 由调用方给：字节路径或文件路径）。
  Future<LocalBookImportResult> _importParsed({
    required LocalBookParser parser,
    required String name,
    required int realSize,
    required Future<ParsedLocalBook> Function() parse,
  }) async {
    final ParsedLocalBook parsed;
    try {
      parsed = await parse();
    } on LocalBookParseException catch (e) {
      // 解析器给的已经是「给用户看的那句话」，原样用
      return LocalBookImportResult.failed(e.message);
    } catch (_) {
      // 解析器内部没兜住的意外（不该发生）：不要给用户看堆栈
      return LocalBookImportResult.failed(
        '这个文件解析失败（${parser.format.toUpperCase()} 文件可能已损坏）',
      );
    }

    if (parsed.chapters.isEmpty) {
      return const LocalBookImportResult.failed('文件里没有可读的正文');
    }
    // 上限按**落盘的文本量**算（EPUB 是压缩包，原始字节数说明不了问题；
    // PDF 是图片页，文本量恒为 0，页数上限由解析器把关）
    if (parsed.totalChars > LocalBookStore.maxTextChars) {
      final mb = (LocalBookStore.maxTextChars / (1024 * 1024)).toStringAsFixed(0);
      return LocalBookImportResult.failed(
        '这本书的正文有 ${(parsed.totalChars / (1024 * 1024)).toStringAsFixed(1)}M 字，'
        '超过 ${mb}M 字上限，暂时不支持',
      );
    }

    final book = await _books.importParsedBook(
      name: name,
      author: parsed.author,
      format: parsed.format,
      encoding: parsed.meta['encoding'] ?? 'utf-8',
      chapters: parsed.chapters,
      coverBytes: parsed.coverBytes,
      sizeBytes: realSize,
      idSeed: parsed.idSeed,
      // PDF：原文件要跟着书落盘（阅读时按页渲染），其它格式是空串
      sourcePath: parsed.sourcePath,
      pageWidth: parsed.pageWidth,
      pageHeight: parsed.pageHeight,
    );
    if (book == null) {
      return const LocalBookImportResult.failed('保存失败（本地存储不可用或空间不足）');
    }

    final skipped = parsed.warnings.length;
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
        skippedChapters: skipped,
      );
    }
    return LocalBookImportResult.success(book, skippedChapters: skipped);
  }

  /// 取解析器：[parserOverride] 优先（测试），否则走全局分派表。
  LocalBookParser? _parserFor(String ext, String fileName) {
    final override = parserOverride;
    if (override != null) return override(ext, fileName);
    return LocalBookParsers.dispatcher(ext, fileName: fileName);
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

  /// 超上限的中文（TXT 说得细一点：用户能做的是拆书；EPUB 就是太大）。
  static String _tooLargeMessage(LocalBookParser parser) {
    if (parser.format == 'txt') {
      return '这个 TXT 有 ${(maxTxtImportBytes / (1024 * 1024)).toStringAsFixed(0)} MB 以上，'
          '暂时不支持（解码要占用两三倍内存），请先拆分再导入';
    }
    return '文件太大（超过 ${(parser.maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB）';
  }

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

/// 扩展名归一（小写、去点、去空白）。
String _normalizeExt(String ext) => ext.trim().toLowerCase().replaceAll('.', '');

/// 文件名 → 扩展名（大小写无关；没有扩展名 → 空串）。
String _extOfName(String name) {
  final trimmed = name.trim();
  final i = trimmed.lastIndexOf('.');
  if (i <= 0 || i == trimmed.length - 1) return '';
  return _normalizeExt(trimmed.substring(i + 1));
}

/// 选中的文件 → 扩展名：原生报的优先，它没报就退回文件名。
String _extOf(PickedBookFile file) {
  final fromNative = _normalizeExt(file.ext);
  if (fromNative.isNotEmpty) return fromNative;
  return _extOfName(file.name);
}

/// 文件字节数（拿不到 → 0）。PDF 走路径解析时用它补一个真实大小。
int _lengthQuietly(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}
