/// 本地书籍存储（E1：把手机里的 `.txt` 变成书架上一本可读的书）。
///
/// ## 目录布局
/// ```
/// <ApplicationSupport>/reader/local/<bookId>/book.txt      ← 解码后的全文
/// <ApplicationSupport>/reader/local/<bookId>/manifest.json ← 书信息 + 章节偏移
/// ```
/// 与 `reader/cache/`（章节离线缓存）同一条既有约定：根目录走
/// `getApplicationSupportDirectory()`，测试用 [LocalBookStore.rootDirOverride]
/// 注入临时目录。**不要把书放进 shared_preferences**：一本 5MB 的小说塞进
/// prefs 会让整个 App 每次 `getInstance()` 都变慢，而且 Android 上 prefs 的
/// XML 是有大小软上限的。
///
/// ## 为什么正文只存一份，章节只存偏移
/// 章节切分（[splitTxtChapters]）给出的是字符偏移。如果把每章切开各存一个
/// 文件，一本 3000 章的书就是 3000 个文件（单目录文件数过多、每次导入要写
/// 3000 次）；如果按章做 JSON 数组，整本书的正文会被转义（引号、换行）后
/// 膨胀 10% 以上，还不如直接存原文。所以：**一份 book.txt + 一份偏移表**，
/// 读第 N 章 = 读全文 + `substring(start, end)`。
///
/// ## 唯一键 `local:<bookId>`（全项目识别本地书的约定）
/// 书架的 `ShelfBook.detailUrl` 是书的唯一键（见 `bookshelf_store.dart`）。
/// 本地书没有详情页地址，约定用伪 URL **`local:<bookId>`**：
/// - `normalizeUrl` 只改写 http(s)，`local:` 原样保留 → 与网络书不冲突；
/// - 任何拿到 `ShelfBook` 的地方用 [isLocalBookUrl] 就能分流到本 store；
/// - `bookId` 只含 `[0-9a-f]`（见 [localBookIdFor]），不会引出路径问题。
///
/// ## 幂等与覆盖
/// `bookId` 由「文件名 + 内容长度 + 内容指纹」决定，**不含导入时间**：
/// 同一本书重复导入会命中同一个 id，直接覆盖（用户改了错别字再导一次，
/// 不该在书架上多出一本）。反之，同一文件名但内容变了，就是另一本书。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../utils/txt_chapter_splitter.dart';
import 'chapter_cache_store.dart' show cacheDirNameFor;

/// 本地书的书架伪 URL 前缀。
///
/// **改这个常量等于让所有已导入的本地书从书架消失**（书架的键是它拼出来的），
/// 别改。
const String kLocalBookUrlPrefix = 'local:';

/// 本地书在书架里显示的来源名（与网络书源区分）。
const String kLocalBookSourceName = '本地文件';

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

/// 本地书 id：文件名 + 内容长度 + 采样指纹的 64 位哈希（16 位小写十六进制）。
///
/// 为什么不用「文件名」直接当目录名：文件名可能含中文、空格、`?`（Windows
/// 非法）、可能超长；不同目录下同名文件还会互相覆盖。哈希之后定长、
/// 只含 `[0-9a-f]`，且**同一份内容永远同一个 id**（幂等覆盖，见文件头）。
///
/// 为什么指纹只采样头 / 中 / 尾各 2048 字：整本 5MB 做一次全量哈希要多花
/// 几十毫秒且没有收益 —— id 只需要在「用户自己的书架」范围内不撞车，
/// 而「同名 + 同长度 + 头中尾都一样」基本就是同一本书。
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

/// 清单里的一章（只有偏移，没有正文）。
class LocalChapter {
  final String title;
  final int start;
  final int end;

  const LocalChapter({required this.title, required this.start, required this.end});

  int get length => end - start;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  factory LocalChapter.fromJson(Map<String, dynamic> json) => LocalChapter(
        title: _asString(json['title']),
        start: _asInt(json['start']),
        end: _asInt(json['end']),
      );
}

/// 一本本地书（= manifest.json 的内存形态）。
class LocalBook {
  final String id;
  final String name;
  final String author;

  /// 格式：目前只有 `txt`（EPUB 留 E3）。
  final String format;

  /// 解码用的编码（`utf-8` / `gbk` / `utf-16le` …，见 `utils/text_decoding.dart`）。
  final String encoding;

  final List<LocalChapter> chapters;

  /// 原始文件字节数（不是 book.txt 的大小）。
  final int sizeBytes;

  /// 导入时间（epoch 毫秒）。
  final int importedAt;

  const LocalBook({
    required this.id,
    required this.name,
    this.author = '',
    this.format = 'txt',
    this.encoding = 'utf-8',
    this.chapters = const [],
    this.sizeBytes = 0,
    this.importedAt = 0,
  });

  /// 书架里的唯一键（`local:<id>`）。
  String get detailUrl => localBookDetailUrl(id);

  int get chapterCount => chapters.length;

  LocalChapter? chapterAt(int index) =>
      index >= 0 && index < chapters.length ? chapters[index] : null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'author': author,
        'format': format,
        'encoding': encoding,
        'chapters': [for (final c in chapters) c.toJson()],
        'sizeBytes': sizeBytes,
        'importedAt': importedAt,
      };

  /// 宽容解析：坏字段走默认值，坏章节逐条跳过（**绝不抛**）。
  factory LocalBook.fromJson(Map<String, dynamic> json) {
    final chapters = <LocalChapter>[];
    final raw = json['chapters'];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final c = LocalChapter.fromJson({
          for (final kv in e.entries) kv.key.toString(): kv.value,
        });
        if (c.title.trim().isEmpty || c.end <= c.start) continue;
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

  static final LocalBookStore instance = LocalBookStore();

  /// 测试注入：support 目录的替身（实际目录是 `<它>/reader/local`）。
  Directory? rootDirOverride;

  LocalBookStore();

  Directory? _rootCache;
  Future<Directory>? _rootFuture;

  /// 最近读过的一本（单条缓存）：阅读页连续翻章时不必每章重读 5MB 文件。
  String? _lastTextId;
  String? _lastText;

  /// 写操作串行化（清单 + 正文成对写，并发会互相盖）。
  Future<void> _tail = Future<void>.value();

  // ==================== 对外 API ====================

  /// 导入一本 TXT。
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
    final id = localBookIdFor(title, text);
    final slices = splitTxtChapters(text, maxChapters: maxChapters);
    if (slices.isEmpty) return null;

    final book = LocalBook(
      id: id,
      name: title,
      author: author.trim(),
      format: 'txt',
      encoding: encoding,
      chapters: [
        for (final s in slices)
          LocalChapter(title: s.title, start: s.start, end: s.end),
      ],
      sizeBytes: sizeBytes > 0 ? sizeBytes : utf8.encode(text).length,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    );

    final ok = await _serialize(() async {
      try {
        final root = await _root();
        if (root == null) return false;
        final dir = Directory('${root.path}/$id');
        await dir.create(recursive: true);
        // 先写正文再写清单：清单是「这本书可读」的唯一凭据，
        // 顺序反过来的话，写正文失败会留下一本有目录但读不出内容的书。
        await _atomicWrite(File('${dir.path}/book.txt'), text);
        await _atomicWrite(
          File('${dir.path}/manifest.json'),
          jsonEncode(book.toJson()),
        );
        _lastTextId = id;
        _lastText = text;
        return true;
      } catch (_) {
        return false;
      }
    });
    return ok ? book : null;
  }

  /// 所有本地书（按导入时间倒序；坏清单逐本跳过）。
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
  /// 偏移在 manifest 里可能被外部改坏（手改、旧版本 bug），所以读完正文后
  /// 还要夹一次 —— 宁可返回 null（页面显示「本章读取失败」），也不要把
  /// 越界偏移导致的半截字符串当成正文。
  Future<String?> readChapter(String id, int index) async {
    final key = id.trim();
    if (key.isEmpty || index < 0) return null;
    final book = await getBook(key);
    if (book == null) return null;
    final chapter = book.chapterAt(index);
    if (chapter == null) return null;
    final text = await _readText(key);
    if (text == null) return null;
    final start = chapter.start.clamp(0, text.length);
    final end = chapter.end.clamp(start, text.length);
    if (end <= start) return null;
    final body = text.substring(start, end);
    return body.trim().isEmpty ? null : body;
  }

  /// 删掉一本（幂等：不存在也算成功）。
  Future<bool> removeBook(String id) async {
    final key = id.trim();
    if (key.isEmpty) return false;
    return _serialize(() async {
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
  }

  /// 统计（书架顶部「本地书 N 本 · x MB」用）。
  ///
  /// 数字以清单为准：清单是正文写成功之后才写的，所以只会少报，不会把
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

  Future<LocalBook?> _readManifest(Directory dir) async {
    try {
      final file = File('${dir.path}/manifest.json');
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final book = LocalBook.fromJson({
        for (final kv in decoded.entries) kv.key.toString(): kv.value,
      });
      // 清单里的 id 必须是目录名：不一致说明目录被外部改过 / 复制过，
      // 按目录名纠正（否则书架上的 `local:<id>` 会指向不存在的目录）。
      final id = dir.path.replaceAll('\\', '/').split('/').last;
      if (book.name.trim().isEmpty || book.chapters.isEmpty) return null;
      return LocalBook(
        id: id.isEmpty ? book.id : id,
        name: book.name,
        author: book.author,
        format: book.format,
        encoding: book.encoding,
        chapters: book.chapters,
        sizeBytes: book.sizeBytes,
        importedAt: book.importedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// 读正文（带单条缓存；文件被外部删掉时清缓存并返回 null）。
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

  Future<T> _serialize<T>(Future<T> Function() op) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }
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
