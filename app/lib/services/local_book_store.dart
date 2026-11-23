/// 本地书籍存储（E1 v2.72 起；E3 v2.73 升到 schema 2）。
///
/// ## 目录布局（schema 2）
/// ```
/// <ApplicationSupport>/reader/local/<bookId>/manifest.json     ← 书信息 + 章节表
/// <ApplicationSupport>/reader/local/<bookId>/chapters/0.txt    ← 第 0 章（UTF-8 纯文本）
/// <ApplicationSupport>/reader/local/<bookId>/chapters/1.txt
/// <ApplicationSupport>/reader/local/<bookId>/cover.jpg|png     ← 有封面才有
/// <ApplicationSupport>/reader/local/<bookId>/book.pdf          ← PDF 才有（原文件）
/// ```
/// PDF 的「章」是**页**（`chapters` 里 `image` 为真、没有 `.txt`），正文靠原生
/// `PdfRenderer` 按需渲染成图片（缓存不在这个目录里，在 `<filesDir>/reader/pdfcache/`）。
/// 与 `reader/cache/`（章节离线缓存）同一条既有约定：根目录走
/// `getApplicationSupportDirectory()`，测试用 [LocalBookStore.rootDirOverride]
/// 注入临时目录。**不要把书放进 shared_preferences**：一本 5MB 的小说塞进
/// prefs 会让整个 App 每次 `getInstance()` 都变慢，而且 Android 上 prefs 的
/// XML 是有大小软上限的。
///
/// ## 为什么从「一份正文 + 字符偏移」改成「一章一个文件」
/// v1 的设计是 TXT 专用：全文只存一份 `book.txt`，章节只记 `start/end` 偏移，
/// 读第 N 章 = 读全文 + `substring`。它有两个 TXT 扛得住、EPUB 扛不住的缺陷：
/// 1. **EPUB 的正文本来就是一章一个 XHTML**，硬拼成一份全文、再记偏移，等于
///    自己发明一遍容器格式；拼出来的全文还要整份落盘（原压缩包里已经有一份）；
/// 2. 偏移是**脆的**：manifest 被外部改坏、或者书被别的东西重写过，偏移就会
///    错位，读出来是半截句子。章节独立文件没有这个耦合，坏一章只坏一章。
/// 代价是「一本 3000 章的书 = 3000 个小文件」。实测这个代价可以接受：
/// 导入是顺序写一次（几秒），读一章只是打开一个几十 KB 的文件，比读 5MB 全文
/// 再截一段还快。
///
/// ## v1 兼容：惰性迁移
/// v2.72.0 已经有人导过书，他们的目录是 `book.txt` + 带偏移的旧 manifest。
/// 读旧 manifest 时（`schema` 缺失或 != 2）**就地迁移**：按偏移切出各章写进
/// `chapters/`，最后写 schema 2 的 manifest。
/// 三条硬约束：
/// 1. **迁移失败不许让书变成读不了**。所以 manifest 是**最后**写的，且迁移
///    只在全部章节都写成功后才落新 manifest；任何一步失败就**原样返回 v1 的
///    书**（偏移还在，`readChapter` 走老的 `book.txt` 路径）—— 用户的旧书
///    最坏情况是「没升级成功」，绝不会「打不开了」。
/// 2. 迁移成功后删掉 `book.txt`：否则一本 5MB 的书要占两份，迁移就白做了。
/// 3. 迁移是**幂等**的：同一份内容反复写同样的名字，中断后重来一次就行。
///
/// ## 唯一键 `local:<bookId>`（全项目识别本地书的约定）
/// 书架的 `ShelfBook.detailUrl` 是书的唯一键（见 `bookshelf_store.dart`）。
/// 本地书没有详情页地址，约定用伪 URL **`local:<bookId>`**：
/// - `normalizeUrl` 只改写 http(s)，`local:` 原样保留 → 与网络书不冲突；
/// - 任何拿到 `ShelfBook` 的地方用 [isLocalBookUrl] 就能分流到本 store；
/// - `bookId` 只含 `[0-9a-f]`（见 [localBookIdFor]），不会引出路径问题。
///
/// ## 幂等与覆盖
/// `bookId` 由「书名 + 解析器给的 idSeed」决定，**不含导入时间**：
/// 同一本书重复导入会命中同一个 id，直接覆盖（用户改了错别字再导一次，
/// 不该在书架上多出一本）。idSeed 对 TXT 是全文、对 EPUB 是「文件名 + zip
/// 字节数 + 首 2KB」（见 `ParsedLocalBook.idSeed`）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../utils/txt_chapter_splitter.dart';
import 'chapter_cache_store.dart' show cacheDirNameFor;
import 'local_book_parser.dart';
import 'pdf_cache_policy.dart';
import 'pdf_renderer_bridge.dart';

/// 本地书的书架伪 URL 前缀。
///
/// **改这个常量等于让所有已导入的本地书从书架消失**（书架的键是它拼出来的），
/// 别改。
const String kLocalBookUrlPrefix = 'local:';

/// 本地书在书架里显示的来源名（与网络书源区分）。
const String kLocalBookSourceName = '本地文件';

/// manifest 的当前版本。读到别的值（含缺失）一律按 v1 处理并尝试迁移。
const int kLocalBookSchema = 2;

/// PDF 原文件在书籍目录里的名字（`reader/local/<id>/book.pdf`）。
///
/// 固定名字而不是沿用用户的原文件名：原文件名可能含中文 / 空格 / 超长，
/// 而这里只用得到「唯一一份原文件」这个语义，书信息在 manifest 里。
const String pdfSourceFileName = 'book.pdf';

/// 书籍 id → 书架伪 URL。
String localBookDetailUrl(String id) => '$kLocalBookUrlPrefix$id';

/// 这个地址是不是本地书（`local:<id>`）。
bool isLocalBookUrl(String url) => url.trim().startsWith(kLocalBookUrlPrefix);

/// 从 `local:<id>` 取回 id；不是本地书 / id 为空 → null。
String? localBookIdFromUrl(String url) {
  final raw = url.trim();
  if (!raw.startsWith(kLocalBookUrlPrefix)) return null;
  final id = raw.substring(kLocalBookUrlPrefix.length).trim();
  return id.isEmpty ? null : id;
}

/// 本地书 id：书名 + 指纹的 64 位哈希（16 位小写十六进制）。
///
/// 为什么不用「文件名」直接当目录名：文件名可能含中文、空格、`?`（Windows
/// 非法）、可能超长；不同目录下同名文件还会互相覆盖。哈希之后定长、
/// 只含 `[0-9a-f]`，且**同一份内容永远同一个 id**（幂等覆盖，见文件头）。
///
/// 为什么指纹只采样头 / 中 / 尾各 2048 字：整本 5MB 做一次全量哈希要多花
/// 几十毫秒且没有收益 —— id 只需要在「用户自己的书架」范围内不撞车，
/// 而「同名 + 同长度 + 头中尾都一样」基本就是同一本书。
///
/// [text] 这个名字是历史沿用（TXT 传全文）；EPUB 传的是解析器给的
/// `ParsedLocalBook.idSeed`（文件名 + zip 字节数 + 首 2KB），**两种格式共用
/// 这一个函数**，所以 id 的形态、长度、撞车概率都是同一套。
String localBookIdFor(String name, String text) {
  final head = text.length <= 2048 ? text : text.substring(0, 2048);
  final mid = text.length <= 4096
      ? ''
      : text.substring(text.length ~/ 2 - 1024, text.length ~/ 2 + 1024);
  final tail = text.length <= 2048
      ? ''
      : text.substring(text.length - 2048);
  return cacheDirNameFor('$name|${text.length}|$head|$mid|$tail');
}

/// 清单里的一章。
///
/// schema 2：只有 [title] + [file]（相对书籍目录的 `chapters/N.txt`）。
/// schema 1（旧数据）：只有 [title] + [start]/[end]（全文里的字符偏移）。
class LocalChapter {
  final String title;

  /// 章节文件的相对路径（schema 2；旧数据为空串）。
  final String file;

  /// 全文里的起始字符偏移（schema 1；schema 2 恒为 0）。
  final int start;

  /// 全文里的结束字符偏移（schema 1；schema 2 恒为 0）。
  final int end;

  /// 这一章是「图片页」（PDF）——没有文本文件，正文由渲染缓存提供。
  ///
  /// 为什么加在章节上而不是给书加一个 `isPdf` 就完事：目录 / 进度 / 阅读页都
  /// 是按章办事的，多一个 per-chapter 标记，将来「混合内容」（EPUB 里的图片页）
  /// 不用再改协议。
  final bool image;

  const LocalChapter({
    required this.title,
    this.file = '',
    this.start = 0,
    this.end = 0,
    this.image = false,
  });

  /// 是否是 schema 2 的独立章节文件。
  bool get isFileBacked => file.trim().isNotEmpty;

  int get length => isFileBacked ? 0 : end - start;

  Map<String, dynamic> toJson() {
    if (image) return {'title': title, 'image': true};
    return isFileBacked
        ? {'title': title, 'file': file}
        : {'title': title, 'start': start, 'end': end};
  }

  factory LocalChapter.fromJson(Map<String, dynamic> json) => LocalChapter(
        title: _asString(json['title']),
        file: _asString(json['file']),
        start: _asInt(json['start']),
        end: _asInt(json['end']),
        image: json['image'] == true || json['image'] == 1,
      );
}

/// 一本本地书（= manifest.json 的内存形态）。
class LocalBook {
  final String id;
  final String name;
  final String author;

  /// 格式：`txt` / `epub`（书架角标据此显示）。
  final String format;

  /// 解码用的编码（`utf-8` / `gbk` / `utf-16le` …，见 `utils/text_decoding.dart`）。
  final String encoding;

  final List<LocalChapter> chapters;

  /// 封面文件名（相对书籍目录，`cover.jpg` / `cover.png`；没有 → 空串）。
  final String coverFile;

  /// 原文件在书籍目录里的文件名（PDF 才有：`book.pdf`；其它格式空串）。
  ///
  /// 为什么 PDF 要留原文件：每页都是渲染出来的，没有原文件就没法再渲染。
  /// TXT / EPUB 解析完只剩文本，留着原文件只是白占空间。
  final String sourceFile;

  /// 首页尺寸（PDF 的点，72dpi；其它格式 0）。图片还没渲染出来时按它占位，
  /// 避免「先空白再跳高度」。
  final int pageWidth;
  final int pageHeight;

  /// 原始文件字节数（不是落盘后的大小）。
  final int sizeBytes;

  /// 导入时间（epoch 毫秒）。
  final int importedAt;

  /// 书籍目录的绝对路径（**不写进 manifest**，读盘时由 store 填上）。
  ///
  /// 为什么放在模型上：书架行要显示封面，需要 `目录/cover.jpg` 这个绝对路径，
  /// 而目录路径只有 store 知道（依赖 `path_provider`）。读 manifest 时顺手填上，
  /// 页面就不必为每一行再问一次 store。
  final String? dirPath;

  const LocalBook({
    required this.id,
    required this.name,
    this.author = '',
    this.format = 'txt',
    this.encoding = 'utf-8',
    this.chapters = const [],
    this.coverFile = '',
    this.sourceFile = '',
    this.pageWidth = 0,
    this.pageHeight = 0,
    this.sizeBytes = 0,
    this.importedAt = 0,
    this.dirPath,
  });

  /// 书架里的唯一键（`local:<id>`）。
  String get detailUrl => localBookDetailUrl(id);

  int get chapterCount => chapters.length;

  /// 封面的绝对路径；没有封面 / 不是从盘上读出来的 → null。
  String? get coverPath {
    final dir = dirPath;
    final file = coverFile.trim();
    if (dir == null || dir.isEmpty || file.isEmpty) return null;
    return '$dir/$file';
  }

  /// 原文件的绝对路径（PDF 渲染用）；没有 → null。
  String? get sourcePath {
    final dir = dirPath;
    final file = sourceFile.trim();
    if (dir == null || dir.isEmpty || file.isEmpty) return null;
    return '$dir/$file';
  }

  LocalChapter? chapterAt(int index) =>
      index >= 0 && index < chapters.length ? chapters[index] : null;

  Map<String, dynamic> toJson() => {
        'schema': kLocalBookSchema,
        'id': id,
        'name': name,
        'author': author,
        'format': format,
        'encoding': encoding,
        'chapters': [for (final c in chapters) c.toJson()],
        if (coverFile.trim().isNotEmpty) 'coverFile': coverFile,
        // PDF 专属字段：没值时**不写**，老书的 manifest 保持原样
        if (sourceFile.trim().isNotEmpty) 'sourceFile': sourceFile,
        if (pageWidth > 0) 'pageWidth': pageWidth,
        if (pageHeight > 0) 'pageHeight': pageHeight,
        'sizeBytes': sizeBytes,
        'importedAt': importedAt,
      };

  /// 宽容解析：坏字段走默认值，坏章节逐条跳过（**绝不抛**）。
  ///
  /// 章节的取舍规则分两种：schema 2 看 `file` 有没有；schema 1 看偏移是否
  /// 合法（`end > start`）。混着写（有 file 又有偏移）一律按 schema 2 处理，
  /// 因为文件比偏移更可信。
  factory LocalBook.fromJson(Map<String, dynamic> json) {
    final chapters = <LocalChapter>[];
    final raw = json['chapters'];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final c = LocalChapter.fromJson({
          for (final kv in e.entries) kv.key.toString(): kv.value,
        });
        if (c.title.trim().isEmpty) continue;
        // 图片页没有偏移也没有文件，只看 `image` 标记
        if (!c.image && !c.isFileBacked && c.end <= c.start) continue;
        chapters.add(c);
      }
    }
    return LocalBook(
      id: _asString(json['id']),
      name: _asString(json['name']),
      author: _asString(json['author']),
      format: _asString(json['format'], 'txt'),
      encoding: _asString(json['encoding'], 'utf-8'),
      chapters: chapters,
      coverFile: _asString(json['coverFile']),
      sourceFile: _asString(json['sourceFile']),
      pageWidth: _asInt(json['pageWidth']),
      pageHeight: _asInt(json['pageHeight']),
      sizeBytes: _asInt(json['sizeBytes']),
      importedAt: _asInt(json['importedAt']),
    );
  }
}

/// 本地书库统计。
class LocalBookStats {
  final int books;
  final int bytes;

  const LocalBookStats({this.books = 0, this.bytes = 0});

  static const LocalBookStats empty = LocalBookStats();

  String get label => '$books 本 · ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 本地书存储。
class LocalBookStore {
  /// `path_provider` 在测试宿主上永不返回 —— 与 `ChapterCacheStore` /
  /// `DiagLog` 一样给 2 秒上限，拿不到就按「本地存储不可用」处理。
  static const Duration rootTimeout = Duration(seconds: 2);

  /// 是否跑在 `flutter test` 里（见 `chapter_cache_store.dart` 的同类注释：
  /// 测试宿主的 path_provider 通道永不返回，碰它会让用例挂住 / 留下定时器）。
  static bool get isTestHost => Platform.environment['FLUTTER_TEST'] == 'true';

  /// 单本最多几章（与 [defaultMaxChapters] 同源：切分时就已合并到 5000 以内）。
  static const int maxChapters = defaultMaxChapters;

  /// 单本正文总量上限（按**章文字符数**累计）。
  ///
  /// 为什么按字符数而不是原文件大小：EPUB 是压缩包，20MB 的包可能解出 100MB
  /// 文本；反过来一份 30MB 的 TXT 里可能有大量换行 / 空白。真正吃内存、吃
  /// 存储的是「最终落盘的文本」，所以按它算。20M 字符 ≈ 40MB 内存（UTF-16），
  /// 比 TXT 的 32MB 原始字节上限宽松，老数据不会被这条卡住。
  static const int maxTextChars = 20 * 1024 * 1024;

  static final LocalBookStore instance = LocalBookStore();

  /// 测试注入：support 目录的替身（实际目录是 `<它>/reader/local`）。
  Directory? rootDirOverride;

  /// 测试注入：PDF 渲染桥（默认 [NativePdfRenderer.instance]）。
  ///
  /// 只有 PDF 书会用到它；TXT / EPUB 的读写路径一次都不碰（所以既有测试
  /// 不注入也照样跑）。
  PdfRendererBridge? pdfRenderer;

  /// 上一次清 PDF 渲染缓存的时间（节流，见 [_maybeSweepPdfCache]）。
  DateTime? _lastPdfSweep;

  LocalBookStore();

  Directory? _rootCache;
  Future<Directory>? _rootFuture;

  /// 最近读过的**整本正文**（只服务 v1 旧书：它们的章节还在 `book.txt` 里）。
  String? _lastTextId;
  String? _lastText;

  /// 写操作串行化（章节文件 + 清单成对写，并发会互相盖）。
  Future<void> _tail = Future<void>.value();

  // ==================== 对外 API ====================

  /// 导入一本 TXT（E1 的入口，行为与 v2.72.0 完全一致）。
  ///
  /// [text] 是**已经解码好**的全文，[name] 是显示用的书名（不含扩展名）。
  /// [sizeBytes] 是原始文件字节数（只用于展示 / 统计）。
  ///
  /// 返回落盘成功的书；目录不可用 / 写盘失败 / 文本为空 → null（**不抛**）。
  Future<LocalBook?> importTxt({
    required String name,
    required String text,
    String author = '',
    String encoding = 'utf-8',
    int sizeBytes = 0,
  }) async {
    final title = _cleanName(name);
    if (title.isEmpty || text.trim().isEmpty) return null;
    final slices = splitTxtChapters(text, maxChapters: maxChapters);
    if (slices.isEmpty) return null;

    return importParsedBook(
      name: name,
      author: author,
      format: 'txt',
      encoding: encoding,
      chapters: [
        for (final s in slices)
          ParsedChapter(title: s.title, text: text.substring(s.start, s.end)),
      ],
      sizeBytes: sizeBytes > 0 ? sizeBytes : utf8.encode(text).length,
      // 与 v1 同一个 id 规则：老用户重复导入同一本书仍然命中同一个目录
      idSeed: text,
    );
  }

  /// 导入一本已经解析好的书（TXT / EPUB / PDF 以及将来的格式都走这里）。
  ///
  /// [chapters] 的文本原样落盘（一章一个文件），[coverBytes] 有就写封面。
  /// PDF 用 [sourcePath] 把原文件拷进书籍目录（`book.pdf`），章节只有
  /// `image: true` 的占位（正文在阅读时按页渲染）。
  /// 返回落盘成功的书；目录不可用 / 超限 / 写盘失败 → null（**不抛**）。
  Future<LocalBook?> importParsedBook({
    required String name,
    required List<ParsedChapter> chapters,
    String author = '',
    String format = 'txt',
    String encoding = 'utf-8',
    Uint8List? coverBytes,
    int sizeBytes = 0,
    String idSeed = '',
    String sourcePath = '',
    int pageWidth = 0,
    int pageHeight = 0,
  }) async {
    final title = _cleanName(name);
    if (title.isEmpty) return null;

    // 空章丢掉；图片页（没有文本）按标记保留。章数超上限时**合并相邻章**
    // （与 TXT 切分同一条规则：宁可一章变长，也不能让书凭空少一半）。
    // 图片页不能合并（合并后的「一章」没有意义），所以有图片页时跳过合并。
    final cleaned = <ParsedChapter>[
      for (final c in chapters)
        if (c.imagePage || c.text.trim().isNotEmpty)
          ParsedChapter(
            title: c.title.trim().isEmpty ? '正文' : c.title.trim(),
            text: c.text,
            imagePage: c.imagePage,
          ),
    ];
    if (cleaned.isEmpty) return null;
    final hasImagePages = cleaned.any((c) => c.imagePage);
    final limited = hasImagePages
        ? cleaned
        : _mergeOverLimit(cleaned, maxChapters);

    var totalChars = 0;
    for (final c in limited) {
      totalChars += c.text.length;
    }
    if (totalChars > maxTextChars) return null;

    final id = localBookIdFor(title, idSeed);
    if (id.isEmpty) return null;

    final coverName = _coverFileName(coverBytes);
    final src = sourcePath.trim();
    final sourceName = src.isEmpty ? '' : pdfSourceFileName;
    final book = LocalBook(
      id: id,
      name: title,
      author: author.trim(),
      format: format,
      encoding: encoding,
      chapters: [
        for (var i = 0; i < limited.length; i++)
          limited[i].imagePage
              ? LocalChapter(title: limited[i].title, image: true)
              : LocalChapter(title: limited[i].title, file: 'chapters/$i.txt'),
      ],
      coverFile: coverName,
      sourceFile: sourceName,
      pageWidth: pageWidth,
      pageHeight: pageHeight,
      sizeBytes: sizeBytes > 0 ? sizeBytes : totalChars,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    );

    final ok = await _serialize(() async {
      try {
        final root = await _root();
        if (root == null) return false;
        final dir = Directory('${root.path}/$id');
        // 覆盖同名书时先清掉旧目录：新版本可能章数更少，留着旧章文件只是
        // 白占空间（清单是权威，旧文件不会被读到）。
        if (dir.existsSync()) await dir.delete(recursive: true);
        await Directory('${dir.path}/chapters').create(recursive: true);

        // 顺序：先章节文件、再封面、再原文件、**最后**写清单。清单是「这本书
        // 可读」的唯一凭据，顺序反过来会留下一本有目录但读不出内容的书。
        for (var i = 0; i < limited.length; i++) {
          if (limited[i].imagePage) continue; // 图片页没有文本文件
          await _atomicWrite(
            File('${dir.path}/chapters/$i.txt'),
            limited[i].text,
          );
        }
        if (coverBytes != null && coverName.isNotEmpty) {
          await _atomicWriteBytes(File('${dir.path}/$coverName'), coverBytes);
        }
        if (sourceName.isNotEmpty) {
          await _copyInto(File(src), File('${dir.path}/$sourceName'));
        }
        await _atomicWrite(
          File('${dir.path}/manifest.json'),
          jsonEncode(book.toJson()),
        );
        return true;
      } catch (_) {
        return false;
      }
    });
    // 覆盖导入同一本 PDF 时，旧的渲染缓存必须作废：书 id 相同 → 缓存子目录
    // 也相同，而缓存里存的是**上一版页面**的截图（idSeed 只看文件名 + 字节数，
    // 正常情况不会撞，但「撞了还显示旧内容」是最难解释的那种 bug）。
    if (ok && sourceName.isNotEmpty) await clearPdfCache(id);
    return ok ? book : null;
  }

  /// 所有本地书（按导入时间倒序；坏清单逐本跳过）。
  ///
  /// 顺带完成 v1 → v2 的惰性迁移（见文件头「v1 兼容」）。
  Future<List<LocalBook>> getBooks() async {
    try {
      final root = await _root();
      if (root == null) return const [];
      if (!root.existsSync()) return const [];
      final out = <LocalBook>[];
      for (final e in root.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final book = await _readManifest(e);
        if (book == null) continue;
        out.add(book);
      }
      out.sort((a, b) => b.importedAt.compareTo(a.importedAt));
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 读一本的清单；不存在 / 坏 JSON → null。
  Future<LocalBook?> getBook(String id) async {
    final key = id.trim();
    if (key.isEmpty) return null;
    try {
      final root = await _root();
      if (root == null) return null;
      return await _readManifest(Directory('${root.path}/$key'));
    } catch (_) {
      return null;
    }
  }

  /// 读第 [index] 章正文；越界 / 文件缺失 / 偏移非法 → null。
  ///
  /// 两种布局都支持：schema 2 直接读 `chapters/<index>.txt`；v1 旧书（迁移
  /// 失败 / 还没轮到迁移）读 `book.txt` 再按偏移切。偏移在旧 manifest 里可能
  /// 被外部改坏（手改、旧版本 bug），所以切完还要夹一次 —— 宁可返回 null
  /// （页面显示「本章读取失败」），也不要把越界偏移导致的半截字符串当成正文。
  Future<String?> readChapter(String id, int index) async {
    final key = id.trim();
    if (key.isEmpty || index < 0) return null;
    final book = await getBook(key);
    if (book == null) return null;
    final chapter = book.chapterAt(index);
    if (chapter == null) return null;

    // 图片页没有正文：PDF 的「正文」是渲染出来的图片，走 [pageImagePath]。
    // 这里返回 null 会让阅读页显示「文件丢失」——所以 loader **先**判断格式，
    // 只有非 PDF 书才会走到这一行。
    if (chapter.image) return null;

    if (chapter.isFileBacked) {
      final body = await _readChapterFile(key, chapter.file);
      if (body == null) return null;
      return body.trim().isEmpty ? null : body;
    }

    // ---- v1 旧布局：全文 + 偏移 ----
    final text = await _readText(key);
    if (text == null) return null;
    final start = chapter.start.clamp(0, text.length);
    final end = chapter.end.clamp(start, text.length);
    if (end <= start) return null;
    final body = text.substring(start, end);
    return body.trim().isEmpty ? null : body;
  }

  /// PDF 书的第 [index] 页（**惰性渲染 + 磁盘缓存**）。
  ///
  /// 返回 null 的两种情况：书不存在 / 不是 PDF 书（TXT / EPUB 走 [readChapter]）。
  /// 渲染失败抛 [PdfRenderException]，[message] 可直接显示。
  ///
  /// [widthPx] 固定成一个值（默认 1080）而不是屏幕宽度：同一页不同宽度会各
  /// 渲染一份缓存，旋转屏幕就翻倍；见 `kPdfDefaultRenderWidth` 的注释。
  Future<PdfRenderedPage?> pageImagePath(
    String id,
    int index, {
    int widthPx = kPdfDefaultRenderWidth,
  }) async {
    final key = id.trim();
    if (key.isEmpty || index < 0) return null;
    final book = await getBook(key);
    if (book == null) return null;
    if (book.format.trim().toLowerCase() != 'pdf') return null;
    if (book.chapterAt(index) == null) return null;

    final src = book.sourcePath;
    if (src == null || !File(src).existsSync()) {
      // 原文件被清理 / 目录被外部删掉：与文本书「正文文件丢失」同一类问题
      throw const PdfRenderException('PDF 原文件已丢失，可能被清理或删除了');
    }

    final page = await _pdf.renderPage(
      path: src,
      index: index,
      widthPx: widthPx,
      // 缓存子目录名就用书 id：稳定（书目录挪动也不影响），删书时同一个 key
      cacheKey: key,
    );
    // 顺手做一次缓存淘汰（节流 2 分钟，见 [_maybeSweepPdfCache]）。
    // 不 await：清理是后台事务，不该让用户多等一帧。
    unawaited(_maybeSweepPdfCache(keepPath: page.path));
    return page;
  }

  /// 删掉一本书的 PDF 渲染缓存（「删书」时调；失败静默）。
  Future<void> clearPdfCache(String id) async {
    final key = id.trim();
    if (key.isEmpty) return;
    try {
      await _pdf.clearCache(key);
    } catch (_) {
      // 缓存删不掉只是多占点空间，不影响「书已经删了」
    }
  }

  /// 删掉一本（幂等：不存在也算成功）。章节文件与封面在同一个目录里，一起没。
  ///
  /// PDF 书额外清一次渲染缓存（`<filesDir>/reader/pdfcache/<id>/`）：
  /// 那是**另一个目录**（缓存可以随时重建，不该跟着书目录一起被当成「书」），
  /// 不清的话删完书还会留下几百 MB 的 PNG。
  Future<bool> removeBook(String id) async {
    final key = id.trim();
    if (key.isEmpty) return false;
    // 删之前先看一眼格式：目录删掉之后就没人知道这本是不是 PDF 了
    final book = await getBook(key);
    final wasPdf = book?.format.trim().toLowerCase() == 'pdf';
    final ok = await _serialize(() async {
      try {
        final root = await _root();
        if (root == null) return false;
        final dir = Directory('${root.path}/$key');
        if (dir.existsSync()) await dir.delete(recursive: true);
        if (_lastTextId == key) {
          _lastTextId = null;
          _lastText = null;
        }
        return true;
      } catch (_) {
        return false;
      }
    });
    if (ok && wasPdf) await clearPdfCache(key);
    return ok;
  }

  /// 统计（书架顶部「本地书 N 本 · x MB」用）。
  ///
  /// 数字以清单为准：清单是内容写成功之后才写的，所以只会少报，不会把
  /// 半截文件报成「一本好书」。
  Future<LocalBookStats> stats() async {
    final books = await getBooks();
    if (books.isEmpty) return LocalBookStats.empty;
    return LocalBookStats(
      books: books.length,
      bytes: books.fold(0, (sum, b) => sum + b.sizeBytes),
    );
  }

  /// 清空所有本地书（调试 / 「清空本地书」用；幂等）。
  Future<void> clearAll() async {
    await _serialize(() async {
      try {
        final root = await _root();
        if (root == null) return;
        if (root.existsSync()) await root.delete(recursive: true);
        _rootCache = null;
        _lastTextId = null;
        _lastText = null;
      } catch (_) {
        // 静默：删不掉也不影响阅读
      }
    });
  }

  // ==================== 内部 ====================

  PdfRendererBridge get _pdf => pdfRenderer ?? NativePdfRenderer.instance;

  /// PDF 渲染缓存的淘汰（节流 2 分钟）。
  ///
  /// 为什么节流：`cacheFiles` 要 list 整个 `pdfcache` 目录，翻一页算一次会让
  /// 翻页变慢；2 分钟一次足够让「读着读着把手机塞满」不发生。
  /// 策略本身是纯函数（`pdf_cache_policy.dart`），这里只负责喂数据、下发删除。
  Future<void> _maybeSweepPdfCache({String? keepPath}) async {
    final now = DateTime.now();
    final last = _lastPdfSweep;
    if (last != null && now.difference(last) < const Duration(minutes: 2)) {
      return;
    }
    _lastPdfSweep = now;
    try {
      final files = await _pdf.cacheFiles();
      final doomed = planPdfCacheEviction(files, keepPath: keepPath);
      if (doomed.isNotEmpty) await _pdf.deleteCacheFiles(doomed);
    } catch (_) {
      // 清理失败不影响阅读（下次还会再试）
    }
  }

  /// 把原文件拷进书籍目录（PDF）。先写 `.tmp` 再 rename：半截 PDF 不能被当成书。
  Future<void> _copyInto(File source, File target) async {
    final tmp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      await source.copy(tmp.path);
      await tmp.rename(target.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 残片删不掉也不覆盖原始错误
      }
      rethrow;
    }
  }

  Future<Directory?> _root() async {
    final override = rootDirOverride;
    if (override != null) return Directory('${override.path}/reader/local');
    // 测试宿主没有 path_provider 实现（见 [isTestHost]）：别去碰通道
    if (isTestHost) return null;
    final cached = _rootCache;
    if (cached != null) return cached;
    try {
      final support = await (_rootFuture ??= getApplicationSupportDirectory())
          .timeout(rootTimeout);
      final dir = Directory('${support.path}/reader/local');
      _rootCache = dir;
      return dir;
    } catch (_) {
      _rootFuture = null;
      return null;
    }
  }

  /// 读一份 manifest（必要时把 v1 迁移成 v2）。
  Future<LocalBook?> _readManifest(Directory dir) async {
    try {
      final file = File('${dir.path}/manifest.json');
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final json = {
        for (final kv in decoded.entries) kv.key.toString(): kv.value,
      };
      var book = LocalBook.fromJson(json);
      // 清单里的 id 必须是目录名：不一致说明目录被外部改过 / 复制过，
      // 按目录名纠正（否则书架上的 `local:<id>` 会指向不存在的目录）。
      final dirId = _baseName(dir.path);
      if (dirId.isNotEmpty) book = _withId(book, dirId);
      if (book.name.trim().isEmpty || book.chapters.isEmpty) return null;

      final schema = _asInt(json['schema']);
      if (schema == kLocalBookSchema) return _withDir(book, dir.path);

      // schema 1（或更早）：就地迁移。失败就**原样返回旧书**（偏移仍在，
      // readChapter 继续读 book.txt），绝不让用户的书变成打不开。
      final migrated = await _migrateV1(dir, book);
      return _withDir(migrated ?? book, dir.path);
    } catch (_) {
      return null;
    }
  }

  /// v1（`book.txt` + 偏移）→ v2（`chapters/*.txt`）。成功返回迁移后的书，
  /// 失败 / 无可迁移内容返回 null（调用方保留旧书）。
  Future<LocalBook?> _migrateV1(Directory dir, LocalBook book) async {
    try {
      final txt = File('${dir.path}/book.txt');
      if (!txt.existsSync()) return null;
      final text = await txt.readAsString();
      if (text.isEmpty) return null;

      final chapters = <LocalChapter>[];
      for (var i = 0; i < book.chapters.length; i++) {
        final c = book.chapters[i];
        if (c.isFileBacked) {
          // 混了 schema 2 章节（理论上不会）：原样保留
          chapters.add(c);
          continue;
        }
        final start = c.start.clamp(0, text.length);
        final end = c.end.clamp(start, text.length);
        if (end <= start) continue; // 坏章丢掉，别写空文件
        final rel = 'chapters/$i.txt';
        await _atomicWrite(File('${dir.path}/$rel'), text.substring(start, end));
        chapters.add(LocalChapter(title: c.title, file: rel));
      }
      if (chapters.isEmpty) return null;

      final migrated = LocalBook(
        id: book.id,
        name: book.name,
        author: book.author,
        format: book.format,
        encoding: book.encoding,
        chapters: chapters,
        coverFile: book.coverFile,
        sizeBytes: book.sizeBytes,
        importedAt: book.importedAt,
      );
      // 清单最后写：写成功才算迁移完成
      await _atomicWrite(
        File('${dir.path}/manifest.json'),
        jsonEncode(migrated.toJson()),
      );
      // 迁移成功后删掉整本副本（否则一本书占两份）。删不掉也无所谓：
      // 清单已经是 v2，没人再读 book.txt。
      try {
        txt.deleteSync();
      } catch (_) {
        // 静默
      }
      return migrated;
    } catch (_) {
      // 迁移失败：不写新清单，调用方继续走 v1 读取路径
      return null;
    }
  }

  /// 读 schema 2 的章节文件（相对书籍目录；越界 / 缺失 → null）。
  Future<String?> _readChapterFile(String id, String rel) async {
    final path = rel.trim();
    // 防目录穿越：清单被手改过的话 `../` 能读到别的文件
    if (path.isEmpty || path.contains('..')) return null;
    try {
      final root = await _root();
      if (root == null) return null;
      final file = File('${root.path}/$id/${path.replaceAll('\\', '/')}');
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 读 v1 的整本正文（带单条缓存；文件被外部删掉时清缓存并返回 null）。
  Future<String?> _readText(String id) async {
    try {
      final root = await _root();
      if (root == null) return null;
      final file = File('${root.path}/$id/book.txt');
      if (_lastTextId == id && _lastText != null) {
        // 命中缓存也要确认文件还在：用户可能在文件管理器里把书删了 /
        // 系统清了数据，此时继续吐旧正文会让页面看起来「删了还能读」。
        if (file.existsSync()) return _lastText;
        _lastTextId = null;
        _lastText = null;
      }
      if (!file.existsSync()) return null;
      final text = await file.readAsString();
      _lastTextId = id;
      _lastText = text;
      return text;
    } catch (_) {
      return null;
    }
  }

  /// 原子写：先 `.tmp` 再 rename（与 `ChapterCacheStore` 同一套理由：
  /// 写一半被系统杀掉不能留下半截正文 / 半截清单）。
  Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(target.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 残片删不掉也不覆盖原始错误
      }
      rethrow;
    }
  }

  /// 原子写二进制（封面）。理由同 [_atomicWrite]。
  Future<void> _atomicWriteBytes(File target, Uint8List content) async {
    final tmp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      await tmp.writeAsBytes(content, flush: true);
      await tmp.rename(target.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 同上
      }
      rethrow;
    }
  }

  Future<T> _serialize<T>(Future<T> Function() op) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }
}

/// 章数超上限：把相邻的几章合并成一段（与 `txt_chapter_splitter` 的合并规则
/// 同口径：宁可一章变长，也不能让书凭空少一半）。
List<ParsedChapter> _mergeOverLimit(List<ParsedChapter> chapters, int max) {
  if (max <= 0 || chapters.length <= max) return chapters;
  final group = (chapters.length + max - 1) ~/ max;
  if (group <= 1) return chapters;
  final out = <ParsedChapter>[];
  for (var i = 0; i < chapters.length; i += group) {
    final last = (i + group - 1) < chapters.length ? i + group - 1 : chapters.length - 1;
    final buffer = StringBuffer();
    for (var j = i; j <= last; j++) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(chapters[j].text);
    }
    out.add(ParsedChapter(title: chapters[i].title, text: buffer.toString()));
  }
  return out;
}

/// 封面文件名的后缀按**内容**判断，不看 manifest 里写的 media-type
/// （那玩意儿经常和实际字节对不上，而解码器只认字节）。
String _coverFileName(Uint8List? bytes) {
  if (bytes == null || bytes.length < 4) return '';
  // PNG: 89 50 4E 47
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return 'cover.png';
  }
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'cover.jpg';
  }
  // 其它格式（webp / gif）Flutter 也能解，但按 .jpg 存会被解码器按扩展名
  // 误导，宁可不显示封面。
  return '';
}

LocalBook _withId(LocalBook book, String id) => LocalBook(
      id: id,
      name: book.name,
      author: book.author,
      format: book.format,
      encoding: book.encoding,
      chapters: book.chapters,
      coverFile: book.coverFile,
      sourceFile: book.sourceFile,
      pageWidth: book.pageWidth,
      pageHeight: book.pageHeight,
      sizeBytes: book.sizeBytes,
      importedAt: book.importedAt,
      dirPath: book.dirPath,
    );

LocalBook _withDir(LocalBook book, String dir) => LocalBook(
      id: book.id,
      name: book.name,
      author: book.author,
      format: book.format,
      encoding: book.encoding,
      chapters: book.chapters,
      coverFile: book.coverFile,
      sourceFile: book.sourceFile,
      pageWidth: book.pageWidth,
      pageHeight: book.pageHeight,
      sizeBytes: book.sizeBytes,
      importedAt: book.importedAt,
      dirPath: dir,
    );

String _baseName(String path) {
  final norm = path.replaceAll('\\', '/');
  final i = norm.lastIndexOf('/');
  return i < 0 ? norm : norm.substring(i + 1);
}

/// 书名清洗：去扩展名、去首尾空白、压缩内部空白。
///
/// 为什么去扩展名：书架上一行「斗破苍穹.txt」比「斗破苍穹」难看，而且用户
/// 从文件名得到的书名通常就是书名本身。`xxx.txt.txt` 只去一层，避免把
/// 书名里真的带点的书（《三体 2.黑暗森林.txt》）削掉后半截。
String _cleanName(String raw) {
  var name = raw.trim();
  final lower = name.toLowerCase();
  if (lower.endsWith('.txt')) name = name.substring(0, name.length - 4).trim();
  if (lower.endsWith('.epub')) name = name.substring(0, name.length - 5).trim();
  if (lower.endsWith('.pdf')) name = name.substring(0, name.length - 4).trim();
  if (name.isEmpty) name = raw.trim();
  return name.replaceAll(RegExp(r'\s+'), ' ');
}

String _asString(Object? v, [String fallback = '']) {
  if (v == null) return fallback;
  if (v is String) return v;
  return v.toString();
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}
