/// 本地书解析器（E3，v2.73.0）：一种格式一个 parser，统一产出「书名 / 作者 /
/// 封面 / 章节列表（标题 + 正文）」。
///
/// ## 为什么要把格式拆成 parser
/// 上层（导入编排、落盘、书架、阅读页）**只认识章节列表**，不认识 TXT 的字符
/// 偏移，也不认识 EPUB 的 zip / OPF / spine。这样再加 MOBI / AZW3 / UMD 时：
/// 写一个新的 `LocalBookParser` 实现 + 在 [LocalBookParsers.parsers] 里挂一行，
/// 存储、书架、阅读、删除这些已经踩过坑的代码一行都不用动。这是 legado / 阅读
/// 这类多格式阅读器的做法（**只借鉴结构，不抄实现**）。
///
/// ## 为什么 TXT 的解析从 `local_book_store.dart` 搬过来
/// 原来 `LocalBookStore.importTxt` 里同时干着「解码 + 切章 + 落盘」三件事，
/// 加 EPUB 时最省事的写法是在 store 里写一个 `importEpub` —— 那会让 store
/// 变成「认识所有格式」的巨类，而且每加一种格式就多一条平行分支。现在
/// store 只负责落盘与读取，解码 / 切章 / 解压全在这里。
///
/// ## 为什么不用 `xml` 包解析 OPF
/// `xml` 在本项目的 `pubspec.yaml` 里**不是直接依赖**（它是 `archive` 等带进来的
/// 间接依赖）。直接 `import 'package:xml/xml.dart'` 会触发
/// `depend_on_referenced_packages`，而本机 `flutter analyze` 默认
/// `--fatal-infos` 是开的 —— 门禁直接红。改 `pubspec.yaml` 加一行依赖属于发布
/// 流程管的东西（AGENTS.md 红线 2），本批不动。
/// 真正需要的只有「几个标签 + 几个属性」，`xlsx_reader.dart` 早在 v2.34.0 就
/// 为同一个理由手写过极简扫描器（见该文件头注释），这里沿用同一口径：
/// **按标签名扫一遍，不做完整 DOM**，并且任何畸形 XML 都不抛到上层。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/text_decoding.dart';
import '../utils/txt_chapter_splitter.dart';
import 'book_content_service.dart' show restoreParagraphs;
import 'pdf_renderer_bridge.dart';

/// 解析失败： [message] 是**可以直接显示给用户**的一句中文。
///
/// 为什么单独开一个异常类型而不是返回 null：不同格式的失败原因差很多
/// （编码认不出来 / 不是 zip / 缺 container.xml / spine 为空），而「说清是
/// 哪一步坏了」是用户唯一能据此采取行动的信息（换个文件、重新下载、另存为
/// UTF-8）。异常只在这条链路里传一层，导入编排接住后原样显示，不进日志堆栈。
class LocalBookParseException implements Exception {
  final String message;

  const LocalBookParseException(this.message);

  @override
  String toString() => message;
}

/// 解析后的一章（标题 + 已经是纯文本的正文）。
///
/// [imagePage] 为真的章（PDF 的一页）**没有正文**：内容是一张渲染出来的图片，
/// 由阅读页按「图片页」显示。这样 PDF 就能复用 TXT / EPUB 的整条链路
/// （目录 / 进度 / 书架），只在「正文从哪来」这一处不同。
class ParsedChapter {
  final String title;
  final String text;

  /// 这一章是不是「图片页」（PDF）。
  ///
  /// 默认 false，TXT / EPUB 的构造点一个字都不用改。
  final bool imagePage;

  const ParsedChapter({
    required this.title,
    required this.text,
    this.imagePage = false,
  });

  int get length => imagePage ? 0 : text.length;

  @override
  String toString() =>
      'ParsedChapter($title, ${imagePage ? '图片页' : '${text.length} chars'})';
}

/// 解析结果（所有格式的统一形态）。
class ParsedLocalBook {
  /// 书名（TXT 默认取文件名去扩展名；EPUB 取 `<dc:title>`）。
  final String title;

  /// 作者（EPUB 的 `<dc:creator>`；TXT 没有这个概念，空串）。
  final String author;

  /// 格式标识：`txt` / `epub`（写进 manifest，书架据此显示角标）。
  final String format;

  final List<ParsedChapter> chapters;

  /// 封面原图字节（可空）。落盘时由 `LocalBookStore` 判断是 jpg 还是 png。
  final Uint8List? coverBytes;

  /// 算书 id 用的种子串。
  ///
  /// 为什么需要它：书 id 必须**同一份内容重复导入命中同一个 id**（覆盖而不是
  /// 书架多一本），而不同格式的「同一份内容」不是一个东西 ——
  /// - TXT：正文全文（与 v2.72.0 的 id 规则完全一致，老用户的书不会变成两本）；
  /// - EPUB：**不能**用解压后的正文（要额外扫一遍整本、且不同版本阅读器对同一
  ///   个文件清洗结果可能不同），用「文件名 + zip 字节数 + 首 2KB」当指纹。
  /// `LocalBookStore` 拿它跑与 TXT 同一个哈希函数（[localBookIdFor]），
  /// 所以两种格式的 id 是同一家族、同样定长、同样只含 `[0-9a-f]`。
  final String idSeed;

  /// 解析过程中的非致命问题（例如某一章的文件缺失被跳过）。
  ///
  /// 为什么留着而不是只 debugPrint：用户导入一本 3000 章的书，少了一章时
  /// 目录里少了那一章，事后完全无法追查是文件坏了还是解析漏了。编排层把它
  /// 写进 diag 日志，排查时能直接看到「跳过 chapters/c12.xhtml」。
  final List<String> warnings;

  /// 调试用的元信息（语言 / 出版方 / OPF 路径等，**不做 UI**）。
  final Map<String, String> meta;

  /// 需要原样保留的源文件（PDF：`PdfRenderer` 只能读磁盘上的文件）。
  ///
  /// 空串 = 不需要（TXT / EPUB 解析完就只剩文本，原文件可以丢）。非空时
  /// `LocalBookStore.importParsedBook` 会把它拷进书籍目录（`book.pdf`），
  /// 阅读时才能按页渲染。
  final String sourcePath;

  /// 首页尺寸（PDF 的点，72dpi；其它格式为 0）。写进 manifest，供阅读页
  /// 在图片还没渲染出来时按正确比例占位（不闪、不跳）。
  final int pageWidth;
  final int pageHeight;

  const ParsedLocalBook({
    required this.title,
    this.author = '',
    required this.format,
    required this.chapters,
    this.coverBytes,
    this.idSeed = '',
    this.warnings = const [],
    this.meta = const {},
    this.sourcePath = '',
    this.pageWidth = 0,
    this.pageHeight = 0,
  });

  int get chapterCount => chapters.length;

  /// 全部章节的字符数（落的盘有多大、要不要拦上限都看它）。
  int get totalChars {
    var n = 0;
    for (final c in chapters) {
      n += c.length;
    }
    return n;
  }

  @override
  String toString() =>
      'ParsedLocalBook($format, $title, $chapterCount 章, $totalChars 字)';
}

/// 一种本地书格式的解析器。
///
/// 契约：
/// 1. [parse] **只做纯计算**（解压 / 解码 / 切章），不碰文件系统、不碰 UI；
/// 2. 失败一律抛 [LocalBookParseException]，[LocalBookParseException.message]
///    是给用户看的中文；
/// 3. 能救的就救（缺一章跳过并记 [ParsedLocalBook.warnings]），
///    **不要因为一个非关键文件坏掉就让整本书导入失败**。
abstract class LocalBookParser {
  /// 格式标识（`txt` / `epub` / `pdf`），会写进 manifest 与书架角标。
  String get format;

  /// 这种格式允许的原始文件字节上限（超过直接拒绝，不读进内存）。
  int get maxBytes;

  /// 这个文件归不归我解析。[ext] 是原生报的扩展名（小写、无点，可能为空）。
  bool canParse(String fileName, String ext);

  /// 解析。**不抛除 [LocalBookParseException] 以外的异常**（内部 catch 兜底）。
  Future<ParsedLocalBook> parse(
    Uint8List bytes, {
    required String fileName,
    String? charsetHint,
  });
}

/// 「必须拿到原文件路径」的格式（目前只有 PDF）。
///
/// 为什么单独开一个接口而不是给 [LocalBookParser] 加两个默认成员：
/// 现有实现写的是 `implements LocalBookParser`，`implements` **不继承**默认
/// 实现，加了成员就得在 TXT / EPUB 里各抄一份空实现（噪声，而且哪天忘了抄
/// 就是编译错误）。用「能力接口」的方式表达：谁真的需要文件路径就实现它，
/// 导入服务用 `is FileBasedLocalBookParser` 分流，其它格式一个字都不用改。
///
/// 为什么 PDF 必须走路径：Android 的 `PdfRenderer` 只能打开文件描述符，
/// 把 100MB 的 PDF 先读进内存再写回临时文件是白搬两遍（内存峰值也白涨）。
abstract class FileBasedLocalBookParser implements LocalBookParser {
  /// 按文件路径解析。**不抛除 [LocalBookParseException] 以外的异常**。
  Future<ParsedLocalBook> parseFile(
    String path, {
    required String fileName,
    int sizeBytes = 0,
    String? charsetHint,
  });
}

// ============================================================================
// TXT
// ============================================================================

/// TXT 解析器：解码（UTF-8 / GBK / UTF-16 自动判定）+ 中文网文切章。
///
/// 行为与 v2.72.0 的 `LocalBookStore.importTxt` **完全一致**（同一套
/// `decodeTextBytes` / `splitTxtChapters`，同一个 id 规则），既有测试钉着。
class TxtBookParser implements LocalBookParser {
  /// TXT 原始文件上限 32 MB。
  ///
  /// 原生那条通道允许 100MB，但 TXT 是**整本读进内存再解码**的：GBK 解出来是
  /// UTF-16 字符串，内存占用约为文件字节数的 2 倍，切章还要再扫一遍。32MB 的
  /// 文件在低端机上已经要占 100MB 上下的峰值，再大就不是「导入慢」而是「直接
  /// OOM」了。超过这个数给用户一句明确的话，比崩溃好。
  static const int defaultMaxBytes = 32 * 1024 * 1024;

  const TxtBookParser();

  @override
  String get format => 'txt';

  @override
  int get maxBytes => defaultMaxBytes;

  @override
  bool canParse(String fileName, String ext) {
    final e = ext.trim().toLowerCase();
    if (e.isNotEmpty) return e == 'txt';
    // 原生没报扩展名（个别文件管理器会这样）时退回文件名判断
    return fileName.trim().toLowerCase().endsWith('.txt');
  }

  @override
  Future<ParsedLocalBook> parse(
    Uint8List bytes, {
    required String fileName,
    String? charsetHint,
  }) async {
    if (bytes.isEmpty) {
      throw const LocalBookParseException('这个文件是空的');
    }
    if (bytes.length > maxBytes) {
      throw const LocalBookParseException(
        '这个 TXT 有 32 MB 以上，暂时不支持（解码要占用两三倍内存），'
        '请先拆分再导入',
      );
    }

    final decoded = decodeTextBytes(bytes, charsetHint: charsetHint);
    if (decoded.isMostlyGarbage) {
      throw const LocalBookParseException(
        '这个文件的编码认不出来（不是 UTF-8 / GBK / UTF-16 文本），'
        '请另存为 UTF-8 后重试',
      );
    }
    final text = decoded.text;
    if (text.trim().isEmpty) {
      throw const LocalBookParseException('文件里没有可读的正文');
    }

    final slices = splitTxtChapters(text);
    if (slices.isEmpty) {
      throw const LocalBookParseException('文件里没有可读的正文');
    }

    return ParsedLocalBook(
      title: titleFromFileName(fileName),
      format: format,
      chapters: [
        for (final s in slices)
          ParsedChapter(title: s.title, text: text.substring(s.start, s.end)),
      ],
      // 与 v2.72.0 完全一致：id 来自「书名 + 全文」，所以老用户已导入的书
      // 重新导入一次仍然命中同一个目录（覆盖，不新增）。
      idSeed: text,
      meta: {'encoding': decoded.encoding},
    );
  }
}

// ============================================================================
// EPUB
// ============================================================================

/// 解压上限（防 zip bomb）。
///
/// ## 为什么必须防
/// zip 的一个 entry 声明「解压后 4GB」而压缩后只有几 KB 是合法的（DEFLATE 的
/// 高压缩比），一本 200KB 的恶意 EPUB 就能让 App 在解压时 OOM 闪退。原生侧
/// 只拦了**压缩包** 100MB，拦不住解压后的膨胀。`archive` 的
/// `ZipDecoder.decodeBytes` 只解析目录、内容按需解压（`ArchiveFile.content`
/// 是 lazy 的），所以可以在**真正解压之前**用 entry 头里的 `size` 记一次账。
///
/// 上限取值的理由：单章 8MB —— 正常 XHTML 一章几十 KB，8MB 是给「整本书一个
/// 大 HTML」这种糟糕排版留的余量；全本 200MB ——超过这个数的「小说」已经不是
/// 阅读器该处理的东西了。
class EpubLimits {
  final int maxChapterBytes;
  final int maxTotalBytes;
  final int maxCoverBytes;

  const EpubLimits({
    this.maxChapterBytes = 8 * 1024 * 1024,
    this.maxTotalBytes = 200 * 1024 * 1024,
    this.maxCoverBytes = 4 * 1024 * 1024,
  });
}

/// EPUB 解析器（EPUB 2 与 EPUB 3）。
///
/// 流程（每一步失败都给一句用户能懂的话）：
/// 1. `ZipDecoder` 解压目录；
/// 2. `META-INF/container.xml` → `<rootfile full-path>` = OPF 路径；
/// 3. OPF：`<metadata>` 的 `dc:title` / `dc:creator` / `dc:language`，
///    `<manifest>` 的 id→(href, media-type)，`<spine>` 的 itemref 顺序；
/// 4. 章节标题：EPUB3 的 `nav.xhtml` → EPUB2 的 `toc.ncx` → 「第 N 章」；
/// 5. 每章 XHTML 用 [restoreParagraphs] 的 `block` 策略转纯文本（复用网络书
///    那一套正文清洗，**不写第二套**）；
/// 6. 封面：`<meta name="cover" content="id">` 或 manifest 里
///    `properties="cover-image"` 的项。
///
/// ## 为什么 spine 才是正文顺序
/// `manifest` 只是「包里有哪些文件」，它的顺序是任意的（实际文件里往往按
/// 写入顺序，甚至按名字排序）；**`spine` 才是作者声明的阅读顺序** —— 序章
/// 可以叫 `x9.xhtml`、第 1 章叫 `a1.xhtml`，按文件名排会把整本书读乱。这也是
/// 阅读器们的共识做法，别在这种地方「优化」。
class EpubBookParser implements LocalBookParser {
  final EpubLimits limits;

  const EpubBookParser({this.limits = const EpubLimits()});

  @override
  String get format => 'epub';

  /// 原始文件上限 100MB（与原生 `FilePickerPlugin.MAX_BOOK_BYTES` 一致）。
  /// 真正危险的是**解压后**的体积，那由 [limits] 把关。
  @override
  int get maxBytes => 100 * 1024 * 1024;

  @override
  bool canParse(String fileName, String ext) {
    final e = ext.trim().toLowerCase();
    if (e.isNotEmpty) return e == 'epub';
    return fileName.trim().toLowerCase().endsWith('.epub');
  }

  @override
  Future<ParsedLocalBook> parse(
    Uint8List bytes, {
    required String fileName,
    String? charsetHint,
  }) async {
    if (bytes.isEmpty) {
      throw const LocalBookParseException('这个文件是空的');
    }
    if (bytes.length > maxBytes) {
      throw const LocalBookParseException('文件太大（超过 100 MB）');
    }

    final warnings = <String>[];
    final meta = <String, String>{};

    // ---- 1. 解压目录（内容此时还没解压，见 EpubLimits 的注释）----
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const LocalBookParseException(
        '这个 EPUB 打不开（不是有效的压缩包，文件可能已损坏）',
      );
    }
    final entries = _entryIndex(archive);
    final budget = _Budget(limits.maxTotalBytes);
    if (entries.isEmpty) {
      throw const LocalBookParseException(
        '这个 EPUB 打不开（压缩包里没有文件，可能已损坏）',
      );
    }

    // ---- 2. container.xml → OPF ----
    final container = _findEntry(entries, 'META-INF/container.xml');
    if (container == null) {
      throw const LocalBookParseException(
        '这个 EPUB 缺少 META-INF/container.xml，可能不是标准的 EPUB 文件',
      );
    }
    final containerXml = _entryText(container, budget, limits);
    final opfPath = _rootfilePath(containerXml);
    if (opfPath == null || opfPath.isEmpty) {
      throw const LocalBookParseException(
        '这个 EPUB 的 container.xml 里找不到 OPF 文件路径',
      );
    }
    final opfEntry = _findEntry(entries, opfPath);
    if (opfEntry == null) {
      throw LocalBookParseException(
        '这个 EPUB 里找不到正文描述文件（$opfPath），文件可能不完整',
      );
    }
    final opfXml = _entryText(opfEntry, budget, limits);
    final opfDir = _dirOf(opfPath);
    meta['opf'] = opfPath;

    // ---- 3. OPF：metadata / manifest / spine ----
    final manifest = _parseManifest(opfXml);
    final spine = _parseSpine(opfXml);
    if (spine.isEmpty) {
      throw const LocalBookParseException(
        '这个 EPUB 没有正文章节（spine 为空），文件可能不完整',
      );
    }

    final dcTitle = _elementText(opfXml, 'title');
    final dcCreator = _elementText(opfXml, 'creator');
    final dcLang = _elementText(opfXml, 'language');
    if (dcLang.isNotEmpty) meta['language'] = dcLang;
    // 出版方唯一标识（EPUB2 是 dc:identifier，EPUB3 是 dc:identifier 或
    // meta property="dcterms:modified"），只做调试用
    final identifier = _elementText(opfXml, 'identifier');
    if (identifier.isNotEmpty) meta['identifier'] = identifier;

    // ---- 4. 目录标题（nav 优先，其次 ncx）----
    final tocByPath = <String, String>{};
    final nav = _tocFromNav(entries, manifest, opfDir, budget);
    if (nav.isNotEmpty) {
      tocByPath.addAll(nav);
      meta['toc'] = 'nav';
    } else {
      final ncx = _tocFromNcx(entries, opfXml, manifest, opfDir, budget);
      if (ncx.isNotEmpty) {
        tocByPath.addAll(ncx);
        meta['toc'] = 'ncx';
      }
    }

    // ---- 5. spine 顺序正文 ----
    final chapters = <ParsedChapter>[];
    for (final idref in spine) {
      final item = manifest[idref];
      if (item == null) {
        warnings.add('spine 里的 $idref 在 manifest 中不存在，已跳过');
        continue;
      }
      // 图片 / 音视频不该被当正文（有的 EPUB 把封面页也塞进 spine）
      final type = item.mediaType.toLowerCase();
      if (type.startsWith('image/') ||
          type.startsWith('audio/') ||
          type.startsWith('video/')) {
        continue;
      }
      final path = _resolveHref(opfDir, item.href);
      final entry = _findEntry(entries, path);
      if (entry == null) {
        // 缺一章不该让整本书导入失败：跳过 + 记账，其余章照常读
        warnings.add('章节文件缺失：$path');
        continue;
      }
      String raw;
      try {
        raw = _entryText(entry, budget, limits);
      } on LocalBookParseException {
        rethrow; // 体积超限是「整本中止」，不说谎地继续
      } catch (_) {
        warnings.add('章节解压失败：$path');
        continue;
      }
      final text = _htmlToText(raw);
      if (text.trim().isEmpty) {
        warnings.add('章节没有正文：$path');
        continue;
      }
      final tocTitle = tocByPath[path];
      chapters.add(ParsedChapter(
        title: (tocTitle != null && tocTitle.trim().isNotEmpty)
            ? tocTitle.trim()
            : '第 ${chapters.length + 1} 章',
        text: text,
      ));
    }

    if (chapters.isEmpty) {
      throw LocalBookParseException(
        warnings.isEmpty
            ? '这个 EPUB 里没有可读的正文'
            : '这个 EPUB 里没有可读的正文（${warnings.first}）',
      );
    }

    // ---- 6. 封面 ----
    final coverBytes = _readCover(entries, opfXml, manifest, opfDir, budget, limits);

    // ---- 7. id 种子：文件名 + 压缩包字节数 + 首 2KB ----
    // 不用解压后的正文：那要多扫一遍整本，而且同一本书换一个阅读器重新打包
    // 后正文清洗结果可能差几个空白 —— 对「用户自己书架内的去重」来说，
    // 「同一个文件」比「同一段文字」更贴近用户的直觉。
    final head = bytes.length <= 2048 ? bytes : bytes.sublist(0, 2048);
    final seed = 'epub|$fileName|${bytes.length}|${latin1.decode(head)}';

    final title = dcTitle.isNotEmpty ? dcTitle : titleFromFileName(fileName);
    return ParsedLocalBook(
      title: title,
      author: dcCreator,
      format: format,
      chapters: chapters,
      coverBytes: coverBytes,
      idSeed: seed,
      warnings: warnings,
      meta: meta,
    );
  }
}

// ============================================================================
// PDF
// ============================================================================

/// PDF 解析器（v2.74.0）：**不解析文字**，只读页数，把每页当成一章。
///
/// ## 为什么 PDF 不抽正文
/// 三个理由，按重要性排：
/// 1. **没有可用的纯 Dart 抽取器**：PDF 的文本是内容流里的一串绘制指令，
///    要还原「第几行、什么顺序」需要字体表 + 编码映射 + 位置启发式；引
///    pdfium / mupdf 才会准，而那属于「新增原生依赖」（本批硬约束不许），
///    也别指望 100MB 的 PDF 能被一个手写扫描器救回来；
/// 2. **扫描版 PDF（漫画 / 老书）里根本没有文字**，抽取出来只有乱码；
/// 3. 用户对「PDF」的期待本来就是**看得见的排版**：双栏、表格、图表、页码，
///    抽成纯文本反而丢了信息。
/// 所以走「下拉式漫画」路线：每页由系统渲染成图片，纵向连续滚动阅读。
/// 代价是**选不中文字**（画面是像素），写进 `docs/DEV_CONTEXT.md` 的已知坑。
///
/// ## 为什么 idSeed 是「文件名 + 字节数」
/// 与 EPUB 同一口径（见 `ParsedLocalBook.idSeed` 的注释）：不读整本内容，
/// 用「同一个文件」当同一本书。同一份 PDF 重复导入是覆盖，不是多一本。
///
/// ## 为什么需要页数上限
/// 每页都会在缓存目录里落一张 PNG（约 300KB~1MB），3000 页 ≈ 1~3GB 的渲染
/// 缓存。页数超过 [maxPages] 直接拒绝并说清，比导入完把手机塞满好。
class PdfBookParser implements FileBasedLocalBookParser {
  /// 页数上限（渲染缓存与目录体量的双重考虑，见类注释）。
  static const int defaultMaxPages = 3000;

  /// 封面渲染宽度（书架行 48×64dp，400 已经够清晰）。
  static const int coverWidthPx = 400;

  /// 原生渲染桥（测试注入假实现）。
  final PdfRendererBridge? renderer;

  final int maxPages;

  /// 测试注入：`parse(bytes)` 落临时文件要用的目录。
  ///
  /// 生产走 `getTemporaryDirectory()`；测试宿主没有 path_provider 实现（会
  /// 永不返回，见 DEV_CONTEXT 6.2），所以要么注入这个，要么直接调 [parseFile]。
  final Future<Directory?> Function()? tempDirProvider;

  const PdfBookParser({
    this.renderer,
    this.maxPages = defaultMaxPages,
    this.tempDirProvider,
  });

  PdfRendererBridge get _renderer => renderer ?? NativePdfRenderer.instance;

  @override
  String get format => 'pdf';

  /// 原始文件上限 100MB（与原生 `FilePickerPlugin.MAX_BOOK_BYTES` 一致）。
  /// PDF **整本读进内存是不必要的**：本解析器优先走 [parseFile]。
  @override
  int get maxBytes => 100 * 1024 * 1024;

  @override
  bool canParse(String fileName, String ext) {
    final e = ext.trim().toLowerCase();
    if (e.isNotEmpty) return e == 'pdf';
    return fileName.trim().toLowerCase().endsWith('.pdf');
  }

  @override
  Future<ParsedLocalBook> parse(
    Uint8List bytes, {
    required String fileName,
    String? charsetHint,
  }) async {
    if (bytes.isEmpty) {
      throw const LocalBookParseException('这个文件是空的');
    }
    if (bytes.length > maxBytes) {
      throw const LocalBookParseException('文件太大（超过 100 MB）');
    }
    final dir = await _tempDir();
    if (dir == null) {
      throw const LocalBookParseException(
        '导入 PDF 需要本地缓存目录，当前不可用（存储被占满或未授权）',
      );
    }
    final tmp = File('${dir.path}/pdf-${DateTime.now().microsecondsSinceEpoch}.pdf');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      return await parseFile(tmp.path, fileName: fileName, sizeBytes: bytes.length);
    } finally {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 临时文件删不掉留给系统清理，不影响导入结果
      }
    }
  }

  @override
  Future<ParsedLocalBook> parseFile(
    String path, {
    required String fileName,
    int sizeBytes = 0,
    String? charsetHint,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw const LocalBookParseException('PDF 文件不在了（可能被移动或删除了）');
    }
    // 先在 Dart 侧看一眼魔数：不是 PDF 时不必唤起原生（文案也更具体）
    if (!_hasPdfMagic(file)) {
      throw const LocalBookParseException(
        '这不是有效的 PDF 文件（开头没有 %PDF 标记，可能只是改了扩展名）',
      );
    }
    final length = sizeBytes > 0 ? sizeBytes : _lengthQuietly(file);
    if (length > maxBytes) {
      throw const LocalBookParseException('文件太大（超过 100 MB）');
    }

    final PdfDocumentInfo info;
    try {
      info = await _renderer.open(path);
    } on PdfRenderException catch (e) {
      // 原生的文案已经是「给用户看的那句话」（加密 / 不是 PDF / 文件不存在）
      throw LocalBookParseException(e.message);
    } catch (_) {
      throw const LocalBookParseException('读取 PDF 失败（原生模块没有响应）');
    }

    if (info.pageCount <= 0) {
      throw const LocalBookParseException('这个 PDF 里没有页面');
    }
    if (info.pageCount > maxPages) {
      throw LocalBookParseException(
        '这个 PDF 有 ${info.pageCount} 页，超过 $maxPages 页上限，暂不支持'
        '（每页要单独渲染缓存，再多会把手机塞满）',
      );
    }

    // 封面：第一页渲染成 400 宽的小图。失败就当没有（封面不是必需品），
    // 书架回退到占位图标，不能因为封面把整本书拦下。
    Uint8List? cover;
    try {
      cover = await _renderer.renderCover(path, widthPx: coverWidthPx);
    } catch (_) {
      cover = null;
    }

    return ParsedLocalBook(
      title: titleFromFileName(fileName),
      // PDF 的元信息（标题 / 作者）要解析 PDF 字典，本批不做：文件名就是书名，
      // 作者留空（书架上显示「未知作者」，与 TXT 一致）
      format: format,
      chapters: [
        for (var i = 0; i < info.pageCount; i++)
          ParsedChapter(title: '第 ${i + 1} 页', text: '', imagePage: true),
      ],
      coverBytes: cover,
      // 「同一个文件」即同一本书（与 EPUB 同一口径，见类注释）
      idSeed: 'pdf|$fileName|$length',
      // 原文件要跟着书一起落盘，否则阅读时没有东西可渲染
      sourcePath: path,
      pageWidth: info.width,
      pageHeight: info.height,
      meta: {'pages': '${info.pageCount}'},
    );
  }

  /// 临时目录（见 [tempDirProvider]）。失败 / 测试宿主 → null。
  Future<Directory?> _tempDir() async {
    final provider = tempDirProvider;
    if (provider != null) return provider();
    // 测试宿主的 path_provider 通道永不返回（DEV_CONTEXT 6.2）：
    // 这里直接早退，不碰通道。与 `LocalBookStore.isTestHost` 同一个判据。
    if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
    try {
      return await getTemporaryDirectory().timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  static bool _hasPdfMagic(File file) {
    try {
      final raf = file.openSync();
      try {
        final head = raf.readSync(5);
        return head.length == 5 &&
            head[0] == 0x25 && // %
            head[1] == 0x50 && // P
            head[2] == 0x44 && // D
            head[3] == 0x46 && // F
            head[4] == 0x2D; // -
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  static int _lengthQuietly(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }
}

/// 按扩展名挑解析器（全项目唯一的「格式 → parser」入口）。
class LocalBookParsers {
  LocalBookParsers._();

  /// 支持的解析器。**要加 MOBI / AZW3 / UMD 就在这里挂一行**，其余代码不动。
  static const List<LocalBookParser> parsers = <LocalBookParser>[
    TxtBookParser(),
    EpubBookParser(),
    PdfBookParser(),
  ];

  /// 按 [ext]（原生报的扩展名，大小写与点都容忍）选解析器；不支持 → null。
  static LocalBookParser? dispatcher(String ext, {String fileName = ''}) {
    final e = _normExt(ext);
    for (final p in parsers) {
      if (p.canParse(fileName, e)) return p;
    }
    return null;
  }

  /// 不支持的格式 → 一句可直接显示的中文。
  static String unsupportedMessage(String ext) {
    final e = _normExt(ext);
    final supported = parsers.map((p) => p.format.toUpperCase()).join(' / ');
    if (e.isEmpty) return '认不出这个文件的格式（目前支持 $supported）';
    return '暂不支持 ${e.toUpperCase()} 格式（目前支持 $supported）';
  }

  static String _normExt(String ext) =>
      ext.trim().toLowerCase().replaceAll('.', '');
}

/// 文件名 → 书名（去掉 `.txt` / `.epub` / `.pdf` 扩展名）。
///
/// 只去一层：`xxx.txt.txt` 只掉一个后缀，避免把书名里真的带点的书
/// （《三体 2.黑暗森林》）削掉后半截。
String titleFromFileName(String fileName) {
  var name = fileName.trim();
  final lower = name.toLowerCase();
  if (lower.endsWith('.txt')) name = name.substring(0, name.length - 4);
  if (lower.endsWith('.epub')) name = name.substring(0, name.length - 5);
  if (name.toLowerCase().endsWith('.pdf')) {
    name = name.substring(0, name.length - 4);
  }
  return name.trim();
}

// ============================================================================
// 内部：解压与体积预算
// ============================================================================

/// 解压预算：按 entry 头里声明的 `size` 记账，**在真正解压之前**拦住炸弹。
class _Budget {
  final int limit;
  int used = 0;

  _Budget(this.limit);

  void spend(int n) {
    used += n;
    if (used > limit) {
      final mb = (limit / (1024 * 1024)).toStringAsFixed(0);
      throw LocalBookParseException(
        '这个 EPUB 解压后体积过大（超过 $mb MB），已中止导入',
      );
    }
  }
}

/// zip 内的 entry 索引（名字归一化：`\` → `/`、去掉 `./`）。
Map<String, ArchiveFile> _entryIndex(Archive archive) {
  final out = <String, ArchiveFile>{};
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final key = _normalizePath(f.name);
    if (key.isEmpty) continue;
    out[key] = f;
  }
  return out;
}

/// 在索引里找一个 entry：先精确匹配，再忽略大小写兜一次。
///
/// 为什么容忍大小写：EPUB 规范里路径是大小写敏感的，但现实中大量书是 Windows
/// 上的工具打包的（Windows 不区分），OPF 里写 `Images/cover.jpg` 而 zip 里
/// 存的是 `images/cover.jpg` 很常见。为这种书报「文件缺失」只会让用户莫名。
ArchiveFile? _findEntry(Map<String, ArchiveFile> entries, String path) {
  final key = _normalizePath(path);
  final exact = entries[key];
  if (exact != null) return exact;
  final lower = key.toLowerCase();
  for (final e in entries.entries) {
    if (e.key.toLowerCase() == lower) return e.value;
  }
  return null;
}

/// 读一个 entry 的文本：先按 UTF-8（EPUB 规范要求 XML 是 UTF-8），
/// 解不通再走自动编码判定（有些中文书是 GBK 打包的，规范之外但很常见）。
String _entryText(ArchiveFile entry, _Budget budget, EpubLimits limits) {
  if (entry.size > limits.maxChapterBytes) {
    final mb = (limits.maxChapterBytes / (1024 * 1024)).toStringAsFixed(0);
    throw LocalBookParseException(
      '这个 EPUB 里有一章解压后超过 $mb MB，已中止导入（防止压缩炸弹）',
    );
  }
  // 先按声明大小记账：伪造的 header 也过不了总量这一关
  budget.spend(entry.size);

  final Object? content = entry.content;
  final List<int> data = content is Uint8List
      ? content
      : (content is List<int> ? content : const <int>[]);
  if (data.isEmpty) return '';

  try {
    return utf8.decode(data);
  } catch (_) {
    return decodeBytes(data);
  }
}

// ============================================================================
// 内部：OPF / NCX / nav
// ============================================================================

/// manifest 里的一项。
class _ManifestItem {
  final String href;
  final String mediaType;
  final String properties;

  const _ManifestItem({
    required this.href,
    this.mediaType = '',
    this.properties = '',
  });
}

/// `<manifest>` → id → 项。
Map<String, _ManifestItem> _parseManifest(String opf) {
  final out = <String, _ManifestItem>{};
  for (final tag in _startTags(opf)) {
    if (tag.name != 'item') continue;
    final id = tag.attrs['id'] ?? '';
    final href = tag.attrs['href'] ?? '';
    if (id.isEmpty || href.isEmpty) continue;
    out[id] = _ManifestItem(
      href: href,
      mediaType: tag.attrs['media-type'] ?? '',
      properties: tag.attrs['properties'] ?? '',
    );
  }
  return out;
}

/// `<spine>` → itemref 的 idref 列表（**顺序即正文顺序**）。
///
/// `linear="no"` 的项是脚注 / 弹窗页，不在主阅读顺序里，跳过；但万一整本
/// spine 都标了 `linear="no"`（工具打包的 bug），就退回「全都收」——
/// 有正文读总比「这本书没有章节」好。
List<String> _parseSpine(String opf) {
  final all = <String>[];
  final linear = <String>[];
  for (final tag in _startTags(opf)) {
    if (tag.name != 'itemref') continue;
    final idref = tag.attrs['idref'] ?? '';
    if (idref.isEmpty) continue;
    all.add(idref);
    if ((tag.attrs['linear'] ?? '').toLowerCase() != 'no') linear.add(idref);
  }
  return linear.isNotEmpty ? linear : all;
}

/// `container.xml` → `<rootfile full-path="...">`。
String? _rootfilePath(String containerXml) {
  for (final tag in _startTags(containerXml)) {
    if (tag.name != 'rootfile') continue;
    final path = tag.attrs['full-path'] ?? '';
    if (path.trim().isEmpty) continue;
    return _decodeHref(path);
  }
  return null;
}

/// EPUB3 的 nav：`<nav epub:type="toc">` 里的 `<a href>` → 标题。
///
/// 返回「zip 内路径 → 标题」。nav 的 href 相对 **nav 文件自己**所在目录，
/// 不是相对 OPF（两者常常同目录，但不是必然）。
Map<String, String> _tocFromNav(
  Map<String, ArchiveFile> entries,
  Map<String, _ManifestItem> manifest,
  String opfDir,
  _Budget budget,
) {
  // 找 nav 文件：优先 manifest 里 properties 含 nav 的项，其次 spine 里
  // 名字就叫 nav.xhtml 的项，最后在包里搜一遍
  String? navPath;
  for (final item in manifest.values) {
    if (item.properties.toLowerCase().contains('nav')) {
      navPath = _resolveHref(opfDir, item.href);
      break;
    }
  }
  navPath ??= _findEntry(entries, '$opfDir/nav.xhtml') != null
      ? _normalizePath('$opfDir/nav.xhtml')
      : null;
  if (navPath == null) {
    for (final key in entries.keys) {
      final lower = key.toLowerCase();
      if (lower.endsWith('/nav.xhtml') || lower == 'nav.xhtml') {
        navPath = key;
        break;
      }
    }
  }
  if (navPath == null) return const {};

  final entry = _findEntry(entries, navPath);
  if (entry == null) return const {};
  final xml = _entryText(entry, budget, const EpubLimits());

  // nav 不嵌套，取第一个声明 type="toc" 的 nav 块；没有声明就用第一个 nav
  String block = '';
  final navRe = RegExp(
    '<(?:[A-Za-z_][\\w.\\-]*:)?nav(\\s[^<>]*)?>([\\s\\S]*?)'
    '</(?:[A-Za-z_][\\w.\\-]*:)?nav\\s*>',
    caseSensitive: false,
  );
  String? firstNav;
  for (final m in navRe.allMatches(xml)) {
    final inner = m.group(2) ?? '';
    firstNav ??= inner;
    final attrs = (m.group(1) ?? '').toLowerCase();
    if (attrs.contains('toc')) {
      block = inner;
      break;
    }
  }
  if (block.isEmpty) block = firstNav ?? '';
  if (block.isEmpty) return const {};

  final out = <String, String>{};
  final navDir = _dirOf(navPath);
  final aRe = RegExp(
    '<(?:[A-Za-z_][\\w.\\-]*:)?a\\b([^<>]*)>([\\s\\S]*?)'
    '</(?:[A-Za-z_][\\w.\\-]*:)?a\\s*>',
    caseSensitive: false,
  );
  for (final m in aRe.allMatches(block)) {
    final href = _attrOf(m.group(1) ?? '', 'href');
    if (href.isEmpty) continue;
    final title = _plainText(m.group(2) ?? '');
    if (title.isEmpty) continue;
    final path = _resolveHref(navDir, href);
    // 同一文件在目录里出现多次（分卷 + 分章）时保留第一条
    out.putIfAbsent(path, () => title);
  }
  return out;
}

/// EPUB2 的 `toc.ncx`：`navMap/navPoint` 顺序里的 `navLabel/text` + `content src`。
///
/// navPoint 是**嵌套**的（分卷下面挂章），所以不能按 `</navPoint>` 切开配对
/// —— 这里改成线性扫描：每个 `navLabel` 之后遇到的第一个 `<content src>` 就是
/// 它自己的地址（父节点的 content 出现在子节点之前，顺序天然对得上）。
Map<String, String> _tocFromNcx(
  Map<String, ArchiveFile> entries,
  String opf,
  Map<String, _ManifestItem> manifest,
  String opfDir,
  _Budget budget,
) {
  // ncx 的定位：manifest 里 media-type 是 x-dtbncx+xml，或 spine 的 toc 属性
  String? ncxPath;
  for (final item in manifest.values) {
    if (item.mediaType.toLowerCase().contains('dtbncx')) {
      ncxPath = _resolveHref(opfDir, item.href);
      break;
    }
  }
  if (ncxPath == null) {
    final tocId = _spineTocId(opf);
    final item = tocId == null ? null : manifest[tocId];
    if (item != null) ncxPath = _resolveHref(opfDir, item.href);
  }
  if (ncxPath == null) {
    for (final key in entries.keys) {
      if (key.toLowerCase().endsWith('.ncx')) {
        ncxPath = key;
        break;
      }
    }
  }
  if (ncxPath == null) return const {};

  final entry = _findEntry(entries, ncxPath);
  if (entry == null) return const {};
  final xml = _entryText(entry, budget, const EpubLimits());
  final ncxDir = _dirOf(ncxPath);

  final out = <String, String>{};
  final labelRe = RegExp(
    '<(?:[A-Za-z_][\\w.\\-]*:)?navLabel\\b[^<>]*>([\\s\\S]*?)'
    '</(?:[A-Za-z_][\\w.\\-]*:)?navLabel\\s*>',
    caseSensitive: false,
  );
  final contentRe = _startTagRe;
  for (final m in labelRe.allMatches(xml)) {
    final title = _elementText(m.group(1) ?? '', 'text');
    if (title.isEmpty) continue;
    // 从 navLabel 结束后开始找本节点的 content
    final rest = xml.substring(m.end);
    String? src;
    for (final t in contentRe.allMatches(rest)) {
      final name = _localName(t.group(1) ?? '');
      if (name != 'content') continue;
      src = _attrOf(t.group(2) ?? '', 'src');
      break;
    }
    if (src == null || src.trim().isEmpty) continue;
    out.putIfAbsent(_resolveHref(ncxDir, src), () => title);
  }
  return out;
}

/// spine 的 `toc="ncx"` 属性 → manifest id。
String? _spineTocId(String opf) {
  final m = RegExp(
    '<(?:[A-Za-z_][\\w.\\-]*:)?spine\\b([^<>]*)>',
    caseSensitive: false,
  ).firstMatch(opf);
  if (m == null) return null;
  final toc = _attrOf(m.group(1) ?? '', 'toc');
  return toc.isEmpty ? null : toc;
}

/// 封面：`<meta name="cover" content="id">`（EPUB2）或
/// manifest 里 `properties="cover-image"`（EPUB3）。
Uint8List? _readCover(
  Map<String, ArchiveFile> entries,
  String opf,
  Map<String, _ManifestItem> manifest,
  String opfDir,
  _Budget budget,
  EpubLimits limits,
) {
  _ManifestItem? item;
  for (final tag in _startTags(opf)) {
    if (tag.name != 'meta') continue;
    if ((tag.attrs['name'] ?? '').toLowerCase() != 'cover') continue;
    final id = tag.attrs['content'] ?? '';
    if (id.isNotEmpty) item = manifest[id];
    if (item != null) break;
  }
  if (item == null) {
    for (final candidate in manifest.values) {
      if (candidate.properties.toLowerCase().contains('cover-image')) {
        item = candidate;
        break;
      }
    }
  }
  if (item == null) return null;

  final path = _resolveHref(opfDir, item.href);
  final entry = _findEntry(entries, path);
  if (entry == null) return null;
  // 封面是二进制（jpg / png），**不能**走文本解码：UTF-8 解一遍再编码回去
  // 会把非 UTF-8 的字节换成 U+FFFD，图片直接坏掉。这里直接取原始字节。
  if (entry.size > limits.maxCoverBytes) {
    return null; // 封面不是必需品，太大就放弃，别拖累整本书
  }
  try {
    budget.spend(entry.size);
    return _entryBytes(entry);
  } catch (_) {
    // 预算超限 / 解压失败都只是「没有封面」，不影响读书
    return null;
  }
}

/// 取 entry 的原始字节（封面这种二进制用这个，别走文本解码）。
Uint8List? _entryBytes(ArchiveFile entry) {
  final Object? content = entry.content;
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  return null;
}

// ============================================================================
// 内部：HTML → 纯文本
// ============================================================================

/// XHTML → 纯文本。
///
/// **复用** `book_content_service.restoreParagraphs(html, 'block')`：块级元素
/// 结束算段落边界、`<br>` 退化成空格、实体解码、连续空行压成一行一段 ——
/// 这套清洗在网络书正文上已经被几千个源验证过，EPUB 正文没有理由再写一套。
///
/// 唯一的预处理是去掉 `<head>`：`restoreParagraphs` 只按标签剥离，`<title>`
/// 里的文字会留在正文开头（「第一章 风起 第一章 风起 …」），必须先整块删掉。
String _htmlToText(String xhtml) {
  var s = xhtml;
  s = s.replaceAll(
    RegExp(r'<head\b[\s\S]*?</head\s*>', caseSensitive: false),
    ' ',
  );
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  s = s.replaceAll(RegExp(r'<\?[\s\S]*?\?>'), ' ');
  // 优先只取 body 内部：有些书在 body 前面还塞了 <svg> 封面之类的整段内容
  final body = RegExp(
    r'<body\b[^<>]*>([\s\S]*)</body\s*>',
    caseSensitive: false,
  ).firstMatch(s);
  if (body != null) s = body.group(1) ?? s;
  return restoreParagraphs(s, 'block').trim();
}

// ============================================================================
// 内部：极简 XML 扫描（不做 DOM，见文件头「为什么不用 xml 包」）
// ============================================================================

/// 开始标签：`<name attr="v">` / `<name ... />`。闭合标签（`</x>`）、注释
/// （`<!--`）、声明（`<?xml`）、DOCTYPE 都不会匹配上（名字首字符不合法）。
/// 属性值里的 `>` 被引号分支吃掉，不会提前截断。
final RegExp _startTagRe = RegExp(
  r'''<([A-Za-z_][\w:.\-]*)((?:[^<>"']|"[^"]*"|'[^']*')*?)(/?)>''',
);

/// 一个开始标签（名字已去掉命名空间前缀）。
class _Tag {
  final String name;
  final Map<String, String> attrs;

  const _Tag(this.name, this.attrs);
}

/// 扫出所有开始标签。属性名也去前缀（`epub:type` → `type`）。
Iterable<_Tag> _startTags(String xml) sync* {
  for (final m in _startTagRe.allMatches(xml)) {
    yield _Tag(_localName(m.group(1) ?? ''), _attrs(m.group(2) ?? ''));
  }
}

/// `epub:type` / `dc:title` → `type` / `title`。
String _localName(String raw) {
  final i = raw.lastIndexOf(':');
  return i < 0 ? raw : raw.substring(i + 1);
}

/// 属性串 → map（只收 `name="value"` / `name='value'` 形态）。
/// 属性串 → map（只收 `name="value"` / `name='value'` 形态）。
///
/// **不做 URL 解码**：href 里的 `%20` 等到 [_resolveHref] 里统一解码一次，
/// 这里也解的话 `%2520`（文件名里真的带 `%20`）会被解两次而错。
Map<String, String> _attrs(String raw) {
  final out = <String, String>{};
  final re = RegExp(r'''([A-Za-z_][\w:.\-]*)\s*=\s*("([^"]*)"|'([^']*)')''');
  for (final m in re.allMatches(raw)) {
    out[_localName(m.group(1) ?? '')] = m.group(3) ?? m.group(4) ?? '';
  }
  return out;
}

/// 从属性串里取一个属性值（没匹配到 → 空串；同样不解码，见 [_attrs]）。
String _attrOf(String rawAttrs, String name) {
  final re = RegExp('(?:^|\\s)(?:[A-Za-z_][\\w.\\-]*:)?$name\\s*=\\s*'
      '("([^"]*)"|\'([^\']*)\')', caseSensitive: false);
  final m = re.firstMatch(rawAttrs);
  if (m == null) return '';
  return (m.group(2) ?? m.group(3) ?? '');
}

/// 取第一个 `<[prefix:]name ...>inner</[prefix:]name>` 的 inner 文本。
String _elementText(String xml, String localName) {
  final re = RegExp(
    '<(?:[A-Za-z_][\\w.\\-]*:)?$localName(?:\\s[^<>]*)?>([\\s\\S]*?)'
    '</(?:[A-Za-z_][\\w.\\-]*:)?$localName\\s*>',
    caseSensitive: false,
  );
  final m = re.firstMatch(xml);
  if (m == null) return '';
  return _plainText(m.group(1) ?? '');
}

/// 标签剥离 + 实体解码 + 折叠空白（目录标题、dc:title 用）。
String _plainText(String raw) {
  final text = raw
      .replaceAll(RegExp(r'<[^<>]*>'), ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// ============================================================================
// 内部：路径
// ============================================================================

/// zip 内路径归一化：`\` → `/`、去掉空段与 `.`、吃掉 `..`。
String _normalizePath(String raw) {
  final out = <String>[];
  for (final seg in raw.replaceAll('\\', '/').split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return out.join('/');
}

/// 目录部分（`a/b/c.xhtml` → `a/b`；顶层文件 → 空串）。
String _dirOf(String path) {
  final norm = _normalizePath(path);
  final i = norm.lastIndexOf('/');
  return i < 0 ? '' : norm.substring(0, i);
}

/// 相对某目录解析 href：吃掉 `?#`、解码 `%20`、归一 `..`。
///
/// 为什么这些都要做：OPF / nav / ncx 里的 href 是 URL 形态（规范要求），
/// 而 zip 里的 entry 名是普通路径。`chapter%201.xhtml` 与 `chapter 1.xhtml`
/// 是同一个文件；`../text/ch1.xhtml` 要按所在目录归一后才能命中。
String _resolveHref(String baseDir, String href) {
  var h = _decodeHref(href);
  final cut = h.indexOf(RegExp('[?#]'));
  if (cut >= 0) h = h.substring(0, cut);
  if (h.isEmpty) return '';
  if (h.startsWith('/')) return _normalizePath(h);
  return _normalizePath(baseDir.isEmpty ? h : '$baseDir/$h');
}

/// URL 解码（`%20` → 空格）。坏序列原样返回，不抛。
String _decodeHref(String raw) {
  final s = raw.trim();
  if (s.isEmpty || !s.contains('%')) return s;
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}
