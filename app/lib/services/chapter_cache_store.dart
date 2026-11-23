/// 章节正文离线缓存（C 批新增）。
///
/// ## 目录布局
/// ```
/// <ApplicationSupport>/reader/cache/<bookKey 的哈希>/manifest.json
/// <ApplicationSupport>/reader/cache/<bookKey 的哈希>/0.txt
/// ```
/// 与 `logs/` / `collection_covers/` / `video_cache/` 同一条既有约定：根目录走
/// `getApplicationSupportDirectory()`，测试用 `rootDirOverride` 注入临时目录。
///
/// ## 为什么目录名用哈希，而不是把 URL 原样（或清洗后）当目录名
/// 章节详情页地址是 `https://host/path?id=1&x=2` 这种形态，直接当目录名会遇到
/// 三类问题：
/// 1. **非法字符**：`?` `:` `*` `&` 在 Windows 上是保留/非法字符，`%` 与中文在
///    不同文件系统上的归一化规则也不一致；
/// 2. **长度**：Windows 单段/整条路径有 255/260 字符上限，URL 可以任意长；
/// 3. **一对多**：`replaceAll(非法字符, '_')` 会把不同 URL 洗成同一个名字
///    （`/a?b=1` 与 `/a?b=2` 都变 `/a_b_1`），两本书的章节会混在同一个目录里。
///
/// 哈希（64 位、16 位小写十六进制）一次解决全部三点：定长、只含 `[0-9a-f]`、
/// 稳定（同一 URL 永远同一个目录，删书 / 清空 / 重进都对得上）。碰撞概率按
/// 生日界算，1000 本书约 2.7e-14 —— 且真撞了也只是两本书共用缓存，读的时候
/// 还有「章节地址校验」兜底（见下），不会读错正文。
///
/// ## 为什么每章一条 `url`
/// 缓存的文件名是 `<章下标>.txt`，而目录（TOC）可能在书源规则改版后重排：
/// 第 12 章从「第12章 风起」变成「第12章 云涌」，下标没变、内容全错。所以
/// 清单里每章都存一份**写入时的章节地址**，读取时要求 `url` 一致 —— 不一致
/// 就当未命中（宁可多抓一次网络，不可把别的章塞给用户）。
///
/// ## 为什么写文件要「先 .tmp 再 rename」
/// 缓存写入发生在阅读 / 批量缓存时，随时可能被系统杀掉进程或断电。直接
/// `writeAsString` 到目标文件，写一半被杀会留下半截正文 —— 而读取侧只判断
/// 「文件存在」，于是用户看到的是**截断的章节**，还要等到重新缓存才能修好，
/// 比没有缓存更糟。`.tmp` + 同目录 `rename` 在文件系统层面是原子替换：要么
/// 旧内容，要么新内容，永远不会是「一半」。
///
/// ## 为什么超上限要明确拒绝，而不是悄悄丢掉最旧的一章
/// 静默淘汰会让「已缓存 N 章」这个数字骗人（用户以为整本在手，飞机上翻到
/// 中间没内容，且不知道是哪一章没）。这里一律返回带原因的失败结果，由调用方
/// 决定是提示用户清理，还是停下来不再打网络。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'book_rule/legado_compat.dart' show normalizeUrl;

/// 一章要写进缓存的内容。
class ChapterCacheEntry {
  /// 章节名（清单里记一份，便于将来做「已缓存目录」而不必再读正文）。
  final String name;

  /// 章节页地址（读取时校验用，见类注释「每章一条 url」）。
  final String url;

  /// 清洗后的正文（段落之间 `\n`）。
  final String body;

  const ChapterCacheEntry({
    required this.name,
    this.url = '',
    required this.body,
  });
}

/// 清单里的一条章节记录。
class CachedChapter {
  final String name;
  final String url;
  final int bytes;

  /// 写入时间（epoch 毫秒）。
  final int savedAt;

  const CachedChapter({
    this.name = '',
    this.url = '',
    this.bytes = 0,
    this.savedAt = 0,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'bytes': bytes,
        'savedAt': savedAt,
      };

  factory CachedChapter.fromJson(Map<String, dynamic> json) => CachedChapter(
        name: _asString(json['name']),
        url: _asString(json['url']),
        bytes: _asInt(json['bytes']),
        savedAt: _asInt(json['savedAt']),
      );
}

/// 一本书的缓存清单（`manifest.json`）。
class ChapterCacheManifest {
  final String bookName;
  final String sourceName;
  final String detailUrl;

  /// 目录总章数（0 = 写入时还不知道目录）。
  final int totalChapters;

  /// `章下标 → 记录`。
  final Map<int, CachedChapter> cached;

  /// 最近一次写入时间（epoch 毫秒）。
  final int updatedAt;

  const ChapterCacheManifest({
    this.bookName = '',
    this.sourceName = '',
    this.detailUrl = '',
    this.totalChapters = 0,
    this.cached = const {},
    this.updatedAt = 0,
  });

  int get cachedChapters => cached.length;

  /// 清单记录的总字节数（**以清单为准**，见 [ChapterCacheStore.stats]）。
  int get bytes => cached.values.fold(0, (sum, e) => sum + e.bytes);

  Map<String, dynamic> toJson() => {
        'bookName': bookName,
        'sourceName': sourceName,
        'detailUrl': detailUrl,
        'totalChapters': totalChapters,
        'cached': {
          for (final e in cached.entries) '${e.key}': e.value.toJson(),
        },
        'updatedAt': updatedAt,
      };

  /// 宽容解析：坏字段走默认值，坏条目逐条跳过（**绝不抛**）。
  factory ChapterCacheManifest.fromJson(Map<String, dynamic> json) {
    final cached = <int, CachedChapter>{};
    final raw = json['cached'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final index = int.tryParse(e.key.toString().trim());
        if (index == null || index < 0 || e.value is! Map) continue;
        cached[index] = CachedChapter.fromJson({
          for (final kv in (e.value as Map).entries) kv.key.toString(): kv.value,
        });
      }
    }
    return ChapterCacheManifest(
      bookName: _asString(json['bookName']),
      sourceName: _asString(json['sourceName']),
      detailUrl: _asString(json['detailUrl']),
      totalChapters: _asInt(json['totalChapters']),
      cached: cached,
      updatedAt: _asInt(json['updatedAt']),
    );
  }

  ChapterCacheManifest copyWith({
    String? bookName,
    String? sourceName,
    String? detailUrl,
    int? totalChapters,
    Map<int, CachedChapter>? cached,
    int? updatedAt,
  }) =>
      ChapterCacheManifest(
        bookName: bookName ?? this.bookName,
        sourceName: sourceName ?? this.sourceName,
        detailUrl: detailUrl ?? this.detailUrl,
        totalChapters: totalChapters ?? this.totalChapters,
        cached: cached ?? this.cached,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 缓存统计（书架 / 详情页展示「已缓存 N/M 章」）。
class CacheStats {
  final int cachedChapters;
  final int totalChapters;
  final int bytes;

  const CacheStats({
    this.cachedChapters = 0,
    this.totalChapters = 0,
    this.bytes = 0,
  });

  static const CacheStats empty = CacheStats();

  bool get hasCache => cachedChapters > 0;

  /// 「已缓存 N/M 章」（M 未知时只报已缓存的章数）。
  String get label => totalChapters > 0
      ? '已缓存 $cachedChapters/$totalChapters 章'
      : '已缓存 $cachedChapters 章';
}

/// 写缓存被拒绝的原因。
enum CacheSaveFailure {
  /// 书的唯一键为空（详情地址都拿不到，没法落盘）。
  emptyBookKey,

  /// 章下标非法（负数）。
  invalidIndex,

  /// 单本章数 / 单本大小 / 缓存总大小到顶。
  quota,

  /// 目录不可用 / 写盘失败 / 超时。
  io,
}

/// [ChapterCacheStore.saveChapter] 的结果。
///
/// 为什么不是裸 `bool`：调用方要给用户一句**具体**的原因（「单本已缓存 1000 章」
/// 与「缓存总量到 200 MB，请清理」对用户是两件事）。静默返回 false 等于让
/// 「缓存失败」变成用户看不见的黑洞。
class ChapterCacheSave {
  final bool ok;
  final CacheSaveFailure? failure;

  /// 给用户看的一句话（失败时必有）。
  final String? message;

  const ChapterCacheSave.ok()
      : ok = true,
        failure = null,
        message = null;

  const ChapterCacheSave.rejected(this.failure, this.message) : ok = false;
}

/// 章节正文缓存。
class ChapterCacheStore {
  /// 单本最多缓存多少章。
  static const int defaultMaxBookChapters = 1000;

  /// 单本缓存上限（字节）。一章正文通常几十 KB，20MB 够放几千章；设上限是
  /// 防止「缓存整本」在上万章的书上把手机存储吃光。
  static const int defaultMaxBookBytes = 20 * 1024 * 1024;

  /// 缓存目录总上限（字节）。
  static const int defaultMaxTotalBytes = 200 * 1024 * 1024;

  /// `path_provider` 的通道在个别 ROM / 测试宿主上会永不返回 —— 与
  /// `DiagLog` 一样给 2 秒上限，拿不到就按「本地存储不可用」处理。
  static const Duration rootTimeout = Duration(seconds: 2);

  /// 是否跑在 `flutter test` 里（`flutter test` 会给测试进程设这个环境变量）。
  ///
  /// 测试宿主没有 path_provider 实现，`getApplicationSupportDirectory()` 的
  /// 请求**永远不回**：加超时会在用例结束后留下一个定时器（flutter_test 直接
  /// 判定失败），不加超时又会让页面挂在 `await` 上。所以测试环境干脆不碰通道
  /// （[rootDirOverride] 注入的临时目录不受影响），当作「本地存储不可用」。
  static bool get isTestHost => Platform.environment['FLUTTER_TEST'] == 'true';

  /// 全局单例（阅读页 / 详情页 / 书架共用一份）。
  static final ChapterCacheStore instance = ChapterCacheStore();

  final int maxBookChapters;
  final int maxBookBytes;
  final int maxTotalBytes;

  /// 测试注入：缓存根目录的**上一级**（实际目录是 `<它>/reader/cache`）。
  Directory? rootDirOverride;

  ChapterCacheStore({
    this.maxBookChapters = defaultMaxBookChapters,
    this.maxBookBytes = defaultMaxBookBytes,
    this.maxTotalBytes = defaultMaxTotalBytes,
  });

  // ---- 目录缓存 ----
  Directory? _rootCache;
  Future<Directory>? _rootFuture;

  /// 缓存目录总大小（懒算一次，之后按写入 / 删除增量维护）。null = 还没算过。
  ///
  /// 为什么不在每次写入时全盘扫一遍：一本 1000 章的书会把「每写一章扫一遍」
  /// 放大成 50 万次 stat，慢到界面能感觉到。增量维护 + 首次懒算够用，代价是
  /// **用户手动删过 App 外部文件后数字可能偏大** —— 这只影响「是否还允许继续
  /// 缓存」这一个软门槛，下次进程重启就会重新算准。
  int? _totalBytes;

  /// 写操作的串行锁（清单是「读 → 改 → 写」，并发写会互相覆盖）。
  Future<void> _tail = Future<void>.value();

  // ==================== 对外 API ====================

  /// 写一章（覆盖同下标的旧内容）。
  ///
  /// 原子写、上限校验、清单累加都在这里做；任何异常都折成
  /// [ChapterCacheSave] 的失败结果，**不抛**。
  Future<ChapterCacheSave> saveChapter(
    String bookKey,
    int index,
    ChapterCacheEntry entry, {
    String bookName = '',
    String sourceName = '',
    String detailUrl = '',
    int totalChapters = 0,
  }) async {
    final key = bookKey.trim();
    if (key.isEmpty) {
      return const ChapterCacheSave.rejected(
        CacheSaveFailure.emptyBookKey,
        '这本书没有可用的地址，无法缓存',
      );
    }
    if (index < 0) {
      return const ChapterCacheSave.rejected(
        CacheSaveFailure.invalidIndex,
        '章节下标非法，无法缓存',
      );
    }
    if (index >= maxBookChapters) {
      return ChapterCacheSave.rejected(
        CacheSaveFailure.quota,
        '这本已到单本上限（$maxBookChapters 章），后面的章不再缓存',
      );
    }

    return _serialize(() async {
      try {
        final root = await _root();
        if (root == null) {
          return const ChapterCacheSave.rejected(
            CacheSaveFailure.io,
            '本地存储不可用，缓存已跳过',
          );
        }
        final dir = _bookDir(root, key);
        final manifest = await _readManifest(key) ?? ChapterCacheManifest(
          detailUrl: detailUrl.isEmpty ? key : detailUrl,
        );

        final bodyBytes = utf8.encode(entry.body).length;
        final previous = manifest.cached[index];
        final bookBytes = manifest.bytes - (previous?.bytes ?? 0) + bodyBytes;
        final isNewChapter = previous == null;

        if (isNewChapter && manifest.cachedChapters >= maxBookChapters) {
          return ChapterCacheSave.rejected(
            CacheSaveFailure.quota,
            '这本已缓存 ${manifest.cachedChapters} 章（上限 $maxBookChapters 章），'
                '不再继续缓存',
          );
        }
        if (bookBytes > maxBookBytes) {
          return ChapterCacheSave.rejected(
            CacheSaveFailure.quota,
            '这本缓存已达单本上限（${_mb(maxBookBytes)} MB），不再继续缓存',
          );
        }
        final total = await _currentTotalBytes(root);
        if (total + bodyBytes > maxTotalBytes) {
          return ChapterCacheSave.rejected(
            CacheSaveFailure.quota,
            '缓存总大小已达 ${_mb(maxTotalBytes)} MB，'
                '请到书架移除已读完的书、或清理缓存后再试',
          );
        }

        // 原子写：先 .tmp 再 rename（见类注释）
        await _atomicWrite(File('${dir.path}/$index.txt'), entry.body);

        final next = manifest.copyWith(
          bookName: bookName.trim().isEmpty ? manifest.bookName : bookName.trim(),
          sourceName:
              sourceName.trim().isEmpty ? manifest.sourceName : sourceName.trim(),
          detailUrl:
              detailUrl.trim().isEmpty ? manifest.detailUrl : detailUrl.trim(),
          totalChapters: totalChapters > 0 ? totalChapters : manifest.totalChapters,
          cached: {
            ...manifest.cached,
            index: CachedChapter(
              name: entry.name,
              url: entry.url,
              bytes: bodyBytes,
              savedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          },
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _writeManifest(root, key, next);

        _totalBytes = total - (previous?.bytes ?? 0) + bodyBytes;
        return const ChapterCacheSave.ok();
      } catch (_) {
        return const ChapterCacheSave.rejected(
          CacheSaveFailure.io,
          '写缓存失败（存储不可用或空间不足）',
        );
      }
    });
  }

  /// 读一章正文；没缓存 / url 对不上 / 文件读不动 → null（当未命中处理）。
  ///
  /// [chapterUrl] 传当前目录里的章节地址：与清单记录的不一致就返回 null ——
  /// 规则改版导致目录重排时，按 index 硬读会读到**别的章**。
  Future<String?> readChapter(
    String bookKey,
    int index, {
    String? chapterUrl,
  }) async {
    final key = bookKey.trim();
    if (key.isEmpty || index < 0) return null;
    try {
      final root = await _root();
      if (root == null) return null;
      // 没有清单就没有可校验的 url → 一律当未命中（宁可不读，不读错）
      final manifest = await _readManifest(key);
      final entry = manifest?.cached[index];
      if (entry == null) return null;
      final expected = chapterUrl?.trim() ?? '';
      if (expected.isNotEmpty &&
          !_sameUrl(entry.url, expected)) {
        return null;
      }
      final file = File('${_bookDir(root, key).path}/$index.txt');
      if (!file.existsSync()) return null;
      final text = await file.readAsString();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// 读清单；没有 / 坏 JSON → null。
  Future<ChapterCacheManifest?> readManifest(String bookKey) =>
      _readManifest(bookKey.trim());

  /// 统计（书架 / 详情页展示用）。没有缓存 → [CacheStats.empty]。
  ///
  /// 数字**以清单为准**：清单是写文件成功之后才更新的，所以它只会「少报」，
  /// 不会把不存在的章报成已缓存。反过来按磁盘文件数统计，会把被外部清掉的
  /// 残片也算进去（用户以为能离线读，实际打开是空的）。
  Future<CacheStats> stats(String bookKey) async {
    final key = bookKey.trim();
    if (key.isEmpty) return CacheStats.empty;
    try {
      final manifest = await _readManifest(key);
      if (manifest == null || manifest.cached.isEmpty) return CacheStats.empty;
      return CacheStats(
        cachedChapters: manifest.cachedChapters,
        totalChapters: manifest.totalChapters,
        bytes: manifest.bytes,
      );
    } catch (_) {
      return CacheStats.empty;
    }
  }

  /// 删掉一本书的全部缓存（幂等）。
  Future<void> removeBook(String bookKey) async {
    final key = bookKey.trim();
    if (key.isEmpty) return;
    await _serialize(() async {
      try {
        final root = await _root();
        if (root == null) return;
        final dir = _bookDir(root, key);
        if (dir.existsSync()) await dir.delete(recursive: true);
        // 具体删了多少字节不细算（目录可能已被外部改过）→ 让下次重算
        _totalBytes = null;
      } catch (_) {
        // 静默：删不掉也不影响阅读
      }
    });
  }

  /// 清空整个缓存目录（幂等）。
  Future<void> clearAll() async {
    await _serialize(() async {
      try {
        final root = await _root();
        if (root == null) return;
        if (root.existsSync()) await root.delete(recursive: true);
        _totalBytes = 0;
        _rootCache = null;
      } catch (_) {
        // 静默
      }
    });
  }

  // ==================== 内部实现 ====================

  Future<Directory?> _root() async {
    final override = rootDirOverride;
    if (override != null) {
      return Directory('${override.path}/reader/cache');
    }
    // 测试宿主没有 path_provider 实现（见 [isTestHost]）：别去碰通道，直接降级
    if (isTestHost) return null;
    final cached = _rootCache;
    if (cached != null) return cached;
    try {
      final support = await (_rootFuture ??= getApplicationSupportDirectory())
          .timeout(rootTimeout);
      final dir = Directory('${support.path}/reader/cache');
      _rootCache = dir;
      return dir;
    } catch (_) {
      // 通道卡住 / 没有插件：整体降级为「缓存不可用」，不影响在线阅读
      _rootFuture = null;
      return null;
    }
  }

  Directory _bookDir(Directory root, String bookKey) =>
      Directory('${root.path}/${cacheDirNameFor(bookKey)}');

  Future<ChapterCacheManifest?> _readManifest(String bookKey) async {
    if (bookKey.isEmpty) return null;
    try {
      final root = await _root();
      if (root == null) return null;
      final file = File('${_bookDir(root, bookKey).path}/manifest.json');
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return ChapterCacheManifest.fromJson({
        for (final kv in decoded.entries) kv.key.toString(): kv.value,
      });
    } catch (_) {
      // 坏 JSON / 半截清单：当没有清单（下次写入会重建）
      return null;
    }
  }

  Future<void> _writeManifest(
    Directory root,
    String bookKey,
    ChapterCacheManifest manifest,
  ) async {
    final file = File('${_bookDir(root, bookKey).path}/manifest.json');
    await _atomicWrite(file, jsonEncode(manifest.toJson()));
  }

  /// 原子写：`<目标>.tmp` 写完再 rename 覆盖目标。
  ///
  /// rename 在同一目录内是原子替换（Android / Windows 上都是），所以读取侧
  /// 永远看到完整内容。失败时**删掉 .tmp**，不给用户留一堆残片。
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
        // 连残片都删不掉：不覆盖原始错误
      }
      rethrow;
    }
  }

  Future<int> _currentTotalBytes(Directory root) async {
    final cached = _totalBytes;
    if (cached != null) return cached;
    var total = 0;
    try {
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          total += await e.length();
        } catch (_) {
          // 单个文件 stat 失败：不参与总量
        }
      }
    } catch (_) {
      // 目录还不存在 = 0 字节
    }
    _totalBytes = total;
    return total;
  }

  /// 串行执行写操作（清单的「读 → 改 → 写」不能并发）。
  Future<T> _serialize<T>(Future<T> Function() op) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }
}

/// 书籍唯一键 → 缓存目录名（64 位哈希的 16 位小写十六进制）。
///
/// 两种混合函数并联（FNV-1a + djb2）：单一 32 位哈希在几千本书时碰撞概率
/// 还不可忽略，并联两条不同族的哈希凑成 64 位，代价只是每字节多一次乘加。
String cacheDirNameFor(String bookKey) {
  final raw = bookKey.trim();
  if (raw.isEmpty) return '';
  final bytes = utf8.encode(raw);
  var fnv = 0x811c9dc5;
  var djb = 5381;
  for (final byte in bytes) {
    fnv = ((fnv ^ byte) * 0x01000193) & 0xFFFFFFFF;
    djb = ((djb * 33) + byte) & 0xFFFFFFFF;
  }
  return fnv.toRadixString(16).padLeft(8, '0') +
      djb.toRadixString(16).padLeft(8, '0');
}

/// 两份章节地址是否指向同一页（归一化后比较，吃掉 `&amp;` / 尾斜杠差异）。
bool _sameUrl(String a, String b) {
  final left = normalizeUrl(a, '');
  final right = normalizeUrl(b, '');
  if (left.isEmpty || right.isEmpty) return false;
  return left == right;
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

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
