/// 书架 / 阅读进度 / 阅读设置（R3 新增）。
///
/// 写法照 [BookSourceStore] / `SearchHistoryStore` 的成熟套路：
/// - 单 key 存整份 JSON，天然原子，不做多 key 分片；
/// - 读失败 / 脏数据逐条跳过，**永不抛异常**；写失败静默返回 false；
/// - 上限（[maxBooks] / [maxProgress]）到了就明确拒绝或裁剪，不悄悄丢数据。
///
/// ## 为什么进度与书架分开两个 key
/// 进度是**高频写**（滚动停 1.5 秒就写一次），书架是**低频写**（加/删书）。
/// 混在一个 key 里，每滚两屏就要把整份书架 JSON 重写一遍；分开之后高频写
/// 的体量只有「最近 100 本的几行数字」。
///
/// ## 为什么书籍唯一键是 `detailUrl`
/// 书名会重名（《三体》有无数版本），作者也可能空。详情页地址是**同一本书
/// 在某一个源里的唯一坐标**；归一化（`normalizeUrl`）之后再去重，能吃掉
/// 尾斜杠、`&amp;` 这类无关差异。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'book_rule/legado_compat.dart';

/// 书架里的一本书。
class ShelfBook {
  final String name;
  final String author;
  final String cover;

  /// 来自哪个书源（换源时用来提示「这本书来自 X」）。
  final String sourceName;

  /// 详情页地址（**已归一化**，同时是唯一键）。
  final String detailUrl;

  /// 目录里最后一章的名字（未读时用来显示「共 N 章」的补充信息）。
  final String lastChapterName;

  /// 加入书架时间（epoch 毫秒；0 = 未记录）。
  final int addedAt;

  /// 最近阅读时间（epoch 毫秒；0 = 还没读过）。
  final int lastReadAt;

  /// 目录章节数（0 = 还没加载过目录）。
  final int chapterCount;

  const ShelfBook({
    required this.name,
    this.author = '',
    this.cover = '',
    this.sourceName = '',
    required this.detailUrl,
    this.lastChapterName = '',
    this.addedAt = 0,
    this.lastReadAt = 0,
    this.chapterCount = 0,
  });

  /// 唯一键（归一化后的详情页地址）。
  String get key => bookKeyFor(detailUrl);

  ShelfBook copyWith({
    String? name,
    String? author,
    String? cover,
    String? sourceName,
    String? detailUrl,
    String? lastChapterName,
    int? addedAt,
    int? lastReadAt,
    int? chapterCount,
  }) =>
      ShelfBook(
        name: name ?? this.name,
        author: author ?? this.author,
        cover: cover ?? this.cover,
        sourceName: sourceName ?? this.sourceName,
        detailUrl: detailUrl ?? this.detailUrl,
        lastChapterName: lastChapterName ?? this.lastChapterName,
        addedAt: addedAt ?? this.addedAt,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        chapterCount: chapterCount ?? this.chapterCount,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'author': author,
        'cover': cover,
        'sourceName': sourceName,
        'detailUrl': detailUrl,
        'lastChapterName': lastChapterName,
        'addedAt': addedAt,
        'lastReadAt': lastReadAt,
        'chapterCount': chapterCount,
      };

  /// 宽容解析：缺字段走默认值，书名 + 地址都空的记录由调用方过滤。
  factory ShelfBook.fromJson(Map<String, dynamic> json) => ShelfBook(
        name: _asString(json['name']),
        author: _asString(json['author']),
        cover: _asString(json['cover']),
        sourceName: _asString(json['sourceName']),
        detailUrl: _asString(json['detailUrl']),
        lastChapterName: _asString(json['lastChapterName']),
        addedAt: _asInt(json['addedAt']),
        lastReadAt: _asInt(json['lastReadAt']),
        chapterCount: _asInt(json['chapterCount']),
      );
}

/// 一本书的阅读进度。
class ReadingProgress {
  /// 章节下标（从 0 起）。
  final int chapterIndex;
  final String chapterName;
  final String chapterUrl;

  /// 页内滚动位置（重进时按它还原，越界会夹取）。**滚动模式**用它。
  final double scrollOffset;

  /// 页内页码（从 0 起）。**分页模式**用它；旧数据没有这个字段就是 0。
  ///
  /// 为什么另开字段而不是复用 [scrollOffset]：两种模式的「页内位置」量纲
  /// 完全不同（dp vs 页号），混用一个字段迟早会把 900dp 当成第 900 页。
  /// 旧字段语义保持不变，滚动模式继续只认 [scrollOffset]。
  final int pageIndex;

  /// 更新时间（epoch 毫秒）—— 裁剪「只保留最近 100 本」按它排序。
  final int updatedAt;

  const ReadingProgress({
    required this.chapterIndex,
    this.chapterName = '',
    this.chapterUrl = '',
    this.scrollOffset = 0,
    this.pageIndex = 0,
    this.updatedAt = 0,
  });

  ReadingProgress copyWith({
    int? chapterIndex,
    String? chapterName,
    String? chapterUrl,
    double? scrollOffset,
    int? pageIndex,
    int? updatedAt,
  }) =>
      ReadingProgress(
        chapterIndex: chapterIndex ?? this.chapterIndex,
        chapterName: chapterName ?? this.chapterName,
        chapterUrl: chapterUrl ?? this.chapterUrl,
        scrollOffset: scrollOffset ?? this.scrollOffset,
        pageIndex: pageIndex ?? this.pageIndex,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'chapterIndex': chapterIndex,
        'chapterName': chapterName,
        'chapterUrl': chapterUrl,
        'scrollOffset': scrollOffset,
        'pageIndex': pageIndex,
        'updatedAt': updatedAt,
      };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) =>
      ReadingProgress(
        chapterIndex: _asInt(json['chapterIndex']),
        chapterName: _asString(json['chapterName']),
        chapterUrl: _asString(json['chapterUrl']),
        scrollOffset: _asDouble(json['scrollOffset']),
        // 负数 / 脏数据夹到 0：页码为负只会在 pageIndex - 1 之类的算术里炸
        pageIndex: _asInt(json['pageIndex']).clamp(0, 1 << 30),
        updatedAt: _asInt(json['updatedAt']),
      );
}

/// 阅读设置。
class ReaderSettings {
  final double fontSize;
  final double lineHeight;

  /// 底色：`auto`（跟随 App）/ `paper`（纸黄）/ `dark`（夜墨）。
  final String theme;

  /// 翻页方式：`scroll`（上下滚动，默认）/ `paged`（左右翻页）。
  ///
  /// 只认这两个值；读到别的（手改坏的 JSON、未来版本的新模式）一律回
  /// `scroll` —— 回落方向必须选「老用户熟悉的那一种」，否则升级后页面
  /// 突然换了翻页方式，用户会以为坏了。
  final String pageMode;

  const ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.8,
    this.theme = 'auto',
    this.pageMode = 'scroll',
  });

  static const ReaderSettings defaults = ReaderSettings();

  /// 分页模式（左右翻页）。
  bool get isPaged => pageMode == 'paged';

  /// 合法翻页方式集合（读写共用一份，避免写进非法值）。
  static const Set<String> pageModes = {'scroll', 'paged'};

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    String? theme,
    String? pageMode,
  }) =>
      ReaderSettings(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        theme: theme ?? this.theme,
        pageMode: pageMode ?? this.pageMode,
      );

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'theme': theme,
        'pageMode': pageMode,
      };

  /// 宽容解析 + 夹取：手改坏的设置（比如 `fontSize: 999`）不该让阅读页
  /// 变成一页只有一个字。
  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    final size = _asDouble(json['fontSize'], 18).clamp(12.0, 32.0);
    final height = _asDouble(json['lineHeight'], 1.8).clamp(1.2, 2.6);
    final theme = _asString(json['theme'], 'auto');
    // 旧数据没有 pageMode（v2.71 及更早）→ 空串 → 回落 scroll
    final mode = _asString(json['pageMode'], 'scroll');
    return ReaderSettings(
      fontSize: size,
      lineHeight: height,
      theme: const {'auto', 'paper', 'dark'}.contains(theme) ? theme : 'auto',
      pageMode: pageModes.contains(mode) ? mode : 'scroll',
    );
  }
}

/// 书架唯一键：归一化后的详情页地址。
String bookKeyFor(String detailUrl) => normalizeUrl(detailUrl, '');

/// 书架 / 进度 / 设置存储。
class BookshelfStore {
  /// 书架最多几本（超出拒绝整次写入并返回 false，理由同 BookSourceStore：
  /// 静默截断会让用户以为书还在，实际上一本都找不回来）。
  static const int maxBooks = 500;

  /// 进度最多保留几本（按 [ReadingProgress.updatedAt] 取最近的）。
  static const int maxProgress = 100;

  static const String booksKey = 'reader:books';
  static const String progressKey = 'reader:progress';
  static const String settingsKey = 'reader:settings';

  /// 全局单例（阅读页 / 书架 / 阅读器共用一份）。
  static final BookshelfStore instance = BookshelfStore();

  BookshelfStore();

  // ==================== 书架 ====================

  /// 读取书架（存储顺序；新书在前）。
  Future<List<ShelfBook>> getBooks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = _decode(prefs.getString(booksKey));
      if (decoded is! List) return const [];
      final out = <ShelfBook>[];
      final seen = <String>{};
      for (final e in decoded) {
        if (e is! Map) continue;
        final book = ShelfBook.fromJson({
          for (final kv in e.entries) kv.key.toString(): kv.value,
        });
        // 脏数据：没有地址或没有书名的记录留着只会渲染成空白行
        if (book.name.trim().isEmpty || book.key.isEmpty) continue;
        if (!seen.add(book.key)) continue; // 同一本书只留第一条
        out.add(book);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 加入 / 更新一本（同 `detailUrl` 覆盖并保持原位置；新书插到最前）。
  ///
  /// 返回是否落盘成功；超过 [maxBooks] 拒绝写入。
  Future<bool> saveBook(ShelfBook book) async {
    final key = book.key;
    if (key.isEmpty || book.name.trim().isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await getBooks();
      final next = <ShelfBook>[];
      var hit = false;
      for (final b in current) {
        if (b.key == key) {
          hit = true;
          next.add(book.copyWith(detailUrl: key));
        } else {
          next.add(b);
        }
      }
      if (!hit) next.insert(0, book.copyWith(detailUrl: key));
      if (next.length > maxBooks) return false;
      return prefs.setString(
        booksKey,
        jsonEncode([for (final b in next) b.toJson()]),
      );
    } catch (_) {
      return false;
    }
  }

  /// 从书架删掉一本（不存在也算成功 —— 幂等）。
  Future<bool> removeBook(String detailUrl) async {
    final key = bookKeyFor(detailUrl);
    if (key.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await getBooks();
      final next = [
        for (final b in current)
          if (b.key != key) b,
      ];
      if (next.length == current.length) return true;
      return prefs.setString(
        booksKey,
        jsonEncode([for (final b in next) b.toJson()]),
      );
    } catch (_) {
      return false;
    }
  }

  // ==================== 进度 ====================

  /// 读一本书的进度（没有返回 null）。
  Future<ReadingProgress?> getProgress(String detailUrl) async {
    final key = bookKeyFor(detailUrl);
    if (key.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readProgressMap(prefs);
      return map[key];
    } catch (_) {
      return null;
    }
  }

  /// 存一本书的进度；超过 [maxProgress] 时按 `updatedAt` 只留最近的那些。
  Future<bool> saveProgress(String detailUrl, ReadingProgress progress) async {
    final key = bookKeyFor(detailUrl);
    if (key.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readProgressMap(prefs);
      map[key] = progress.updatedAt == 0
          ? progress.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch)
          : progress;
      final trimmed = _trimProgress(map, maxProgress);
      return prefs.setString(
        progressKey,
        jsonEncode({
          for (final e in trimmed.entries) e.key: e.value.toJson(),
        }),
      );
    } catch (_) {
      return false;
    }
  }

  // ==================== 设置 ====================

  Future<ReaderSettings> getSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = _decode(prefs.getString(settingsKey));
      if (decoded is! Map) return ReaderSettings.defaults;
      return ReaderSettings.fromJson({
        for (final kv in decoded.entries) kv.key.toString(): kv.value,
      });
    } catch (_) {
      return ReaderSettings.defaults;
    }
  }

  /// 写设置。`pageMode` 非法值写盘前就归一成 `scroll` —— 读侧虽然也会回落，
  /// 但不该把脏值先写进 prefs 再指望下一次读去修（读写的契约要一致）。
  Future<bool> saveSettings(ReaderSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final safe = ReaderSettings.pageModes.contains(settings.pageMode)
          ? settings
          : settings.copyWith(pageMode: 'scroll');
      return prefs.setString(settingsKey, jsonEncode(safe.toJson()));
    } catch (_) {
      return false;
    }
  }

  // ==================== 内部 ====================

  Object? _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, ReadingProgress> _readProgressMap(SharedPreferences prefs) {
    final decoded = _decode(prefs.getString(progressKey));
    if (decoded is! Map) return <String, ReadingProgress>{};
    final out = <String, ReadingProgress>{};
    for (final e in decoded.entries) {
      if (e.value is! Map) continue;
      final key = e.key.toString().trim();
      if (key.isEmpty) continue;
      out[key] = ReadingProgress.fromJson({
        for (final kv in (e.value as Map).entries) kv.key.toString(): kv.value,
      });
    }
    return out;
  }

  /// 按 `updatedAt` 倒序保留 [limit] 本（**稳定**：同时间戳按原顺序）。
  Map<String, ReadingProgress> _trimProgress(
    Map<String, ReadingProgress> map,
    int limit,
  ) {
    if (map.length <= limit) return map;
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return {for (final e in entries.take(limit)) e.key: e.value};
  }
}

// ==================== 宽容类型转换（内部） ====================

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

double _asDouble(Object? v, [double fallback = 0]) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim()) ?? fallback;
  return fallback;
}
