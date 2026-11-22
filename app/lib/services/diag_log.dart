import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';
import '../utils/log_redact.dart' as redact;

/// 本地诊断日志：环形落盘 + 一键导出（v2.67.0）。
///
/// ## 为什么要做（以及为什么不做成 logger 包）
///
/// 全 App 有 556 处 `debugPrint`（164 个文件，其中 492 处自带 `[tag]` 前缀），
/// 用户报障时只能靠连 USB 抓 logcat。与其逐处改成 `logger.xxx`（一次改动
/// 556 个调用点、还得引一个包），不如**在 `main()` 里把 `debugPrint` 本身换掉**：
/// [install] 把旧的 `debugPrint` 存起来，[write] 内部**先回调旧实现**（logcat /
/// IDE 控制台照旧，`wrapWidth` 语义不变），再顺手落一份盘。这样 556 处调用点
/// **一个字都不用改**，将来新写的 `debugPrint` 也自动被收编。
///
/// ⚠️ sink **只能在 `main()` 里装**：`test/playview_api_test.dart` 与
/// `test/update_service_test.dart` 会在用例里临时替换 `debugPrint` 来捕获
/// 日志并断言内容。如果库加载期就劫持，那些用例会拿到一份被改过的实现，
/// 断言全废。所以本文件不做任何静态初始化副作用，[install] 只由 `main()` 调。
///
/// ## 落盘参数（每一条都有代价理由）
///
/// - **单文件 512KB**：一次导出/分享要过系统分享面板（微信对文件大小有上限），
///   512KB 的纯文本够放上万行日志，也远小于任何分享通道的限制。
/// - **保留最近 4 份（约 2MB）**：够覆盖"今天出问题 → 明天想起来报障"的场景，
///   再多只是占用户存储。
/// - **目录总大小 5MB**：给"跨天多份 + 导出 zip + 原生崩溃文件"留余量；
///   真超了按修改时间删最旧（当前正在写的那个永远不删）。
/// - **同一 `(tag, 前 80 字)` 1 秒内只写一条并计数**：播放循环、信箱遍历这类
///   逻辑一秒能刷几十条同样的日志，不去重的话 512KB 十秒就滚完，真正有用的
///   那条早被轮转掉了。
/// - **攒批 64 条 / 2 秒**：`debugPrint` 是热路径（滚动时一帧好几条），每条都
///   同步 `writeAsStringSync` 会掉帧。崩溃路径例外： [flushSync] 立刻落盘。
///
/// ## 失败约定
///
/// 日志**永远不许影响 App**：目录不可写、磁盘满、文件被删、编码异常 —— 全部
/// 静默吞掉（[write] 里只回调旧 `debugPrint`，副作用一律在 try 里）。
class DiagLog {
  DiagLog._();

  /// 单个日志文件的上限（字节）。超了就轮转。
  static const int maxFileBytes = 512 * 1024;

  /// 日志目录里最多保留几份 `diag-*.log`（含当前正在写的那份）。
  static const int maxFiles = 4;

  /// 日志目录总大小上限（字节）。超了按修改时间删最旧。
  static const int maxDirBytes = 5 * 1024 * 1024;

  /// 去重窗口：同一 `(tag, 前缀)` 在这个窗口内只落一条。
  static const Duration dedupeWindow = Duration(seconds: 1);

  /// 去重用的前缀长度（"前 80 字"）。
  static const int dedupePrefixLength = 80;

  /// 攒到多少条就立刻 flush。
  static const int flushBatchSize = 64;

  /// 攒批的最长等待时间（到点就 flush，不必等满一批）。
  static const Duration flushInterval = Duration(seconds: 2);

  /// 单条日志的最大长度（字符）。超长截断：一整个 stack trace 顶进来也不至于
  /// 把 512KB 一口气吃掉。
  static const int maxLineLength = 8000;

  /// [recentLines] 在内存里保留的最近条数。
  static const int recentCapacity = 200;

  /// 测试注入：日志根目录（null → path_provider 的应用支持目录）。
  /// 与 `DownloadManager` / `UpdateService` / `CollectionCoverStore` 同一条约定。
  static Directory? rootDirOverride;

  /// 总开关（用户/测试可关掉落盘；关掉后只保留旧的 `debugPrint` 行为）。
  static bool enabled = true;

  // ---- 安装态 ----
  static DebugPrintCallback? _previous;
  static bool _installed = false;

  // ---- 落盘态 ----
  static Directory? _logDirCache;
  static Future<Directory>? _rootFuture;
  static final List<String> _pending = <String>[];
  static final List<String> _recent = <String>[];
  static Timer? _flushTimer;

  // ---- 去重态 ----
  static String? _lastKey;
  static DateTime? _lastAt;
  static int _duplicateCount = 0;

  /// 是否已经接管了 `debugPrint`（测试用）。
  static bool get isInstalled => _installed;

  /// 接管 `debugPrint`（**只由 `main()` 调用**，见类注释）。
  ///
  /// - 重复调用直接返回：绝不叠套（否则同一条日志会被写两遍、旧实现被回调
  ///   两遍）。
  /// - 返回的 Future 在日志目录解析完成时完成 —— `main()` 里 `await` 一手，
  ///   之后任何一条日志（包括紧跟着的崩溃）都有确定的落盘路径。目录解析失败
  ///   也只让这个 Future 正常完成（落盘退化成静默丢弃）。
  static Future<void> install({Directory? rootDir}) async {
    if (_installed) return;
    _installed = true;
    _previous = debugPrint;
    debugPrint = write;
    rootDirOverride ??= rootDir;
    try {
      // 2s 上限：path_provider 的通道在某些环境（无插件的测试宿主 / 异常 ROM）
      // 上会**永不返回**，`main()` 里是 `await` 的 —— 不能让它卡住首帧。
      await _logDir().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 目录拿不到：后续 flush 静默失败，App 照常跑
    }
  }

  /// 接管后的 `debugPrint` 实现。
  ///
  /// 第一件事永远是**回调旧实现**：logcat / IDE 控制台的行为、`wrapWidth`
  /// 的折行语义、`debugPrintThrottled` 的节流都与接管前完全一致 —— 接管只是
  /// "顺手多写一个文件"，不改任何已有输出。
  static void write(String? message, {int? wrapWidth}) {
    _previous?.call(message, wrapWidth: wrapWidth);
    if (!enabled || message == null || message.isEmpty) return;
    try {
      _enqueue(message);
    } catch (_) {
      // 日志写不进去绝不影响 App
    }
  }

  /// 记一条结构化错误（崩溃入口用），**同步落盘**。
  ///
  /// 走 [_enqueue] 而非 [write]：崩溃时不必再往控制台打一遍（[FlutterError
  /// .presentError] / 系统已经打过），但去重、脱敏、单行长度限制都照旧。
  static void recordError(
    String tag,
    Object error, {
    StackTrace? stack,
  }) {
    if (!enabled) return;
    try {
      final buf = StringBuffer('[crash:$tag] $error');
      if (stack != null) {
        buf
          ..writeln()
          ..write(stack);
      }
      _enqueue(buf.toString());
      flushSync();
    } catch (_) {
      // 静默
    }
  }

  /// 把缓冲区里的日志立刻写盘（**同步**，崩溃路径专用）。
  ///
  /// 为什么必须有同步版本：Dart 的未捕获异常在 `runZonedGuarded` /
  /// `PlatformDispatcher.onError` 之后就依赖进程还活着；异步 flush 可能永远
  /// 排不上队（系统随后杀进程）。这里是唯一的"一定要落下去"的时刻。
  static void flushSync() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;
    final lines = List<String>.of(_pending);
    _pending.clear();
    try {
      final dir = _logDirSync;
      if (dir == null) return;
      final now = DateTime.now();
      final payload = '${lines.join('\n')}\n';
      final bytes = utf8.encode(payload).length;
      _rotateIfNeeded(dir, now, bytes);
      final active = File(_activePathFor(dir, now));
      if (!active.parent.existsSync()) {
        active.parent.createSync(recursive: true);
      }
      active.writeAsStringSync(payload, mode: FileMode.append, flush: true);
      _pruneDir(dir, keep: active.path);
    } catch (_) {
      // 静默：磁盘满 / 目录被删 / 权限异常都不许冒泡
    }
  }

  /// 内存里最近的 [n] 条日志（导出/调试用；不含已滚出内存的老日志）。
  static List<String> recentLines(int n) {
    if (n <= 0 || _recent.isEmpty) return const <String>[];
    final start = _recent.length > n ? _recent.length - n : 0;
    return List<String>.unmodifiable(_recent.sublist(start));
  }

  /// 当前正在写的日志文件路径；日志目录还没解析出来 → null。
  static String? logFilePath() {
    final dir = _logDirSync;
    if (dir == null) return null;
    return _activePathFor(dir, DateTime.now());
  }

  /// 把 `logs/` 下的日志 + `meta.txt` 打成一个 zip，返回 zip 路径；失败 → null。
  ///
  /// 为什么打 zip 而不是逐个分享：微信/QQ/邮件对"多个附件"的体验都不好，
  /// 一个 zip 点一次就发出去了；`meta.txt` 里放版本/机型/时间范围，省得
  /// 开发者反复问"你什么手机什么版本"。
  static Future<String?> exportBundle() async {
    try {
      flushSync();
      // 2s 上限（与 [install] 同一个理由）：path_provider 的通道卡住时，
      // 导出按钮不能永远停在「正在打包…」—— 超时按「没有可导出日志」返回 null。
      final dir = _logDirSync ??
          await _logDir().timeout(const Duration(seconds: 2));
      if (!dir.existsSync()) return null;

      final files = _logFiles(dir);
      if (files.isEmpty) return null;

      final archive = Archive();
      var lineCount = 0;
      DateTime? first;
      DateTime? last;
      var totalBytes = 0;
      for (final f in files) {
        final bytes = f.readAsBytesSync();
        archive.addFile(ArchiveFile(_baseName(f.path), bytes.length, bytes));
        totalBytes += bytes.length;
        final stat = f.statSync();
        final modified = stat.modified;
        if (first == null || modified.isBefore(first)) first = modified;
        if (last == null || modified.isAfter(last)) last = modified;
        lineCount += const LineSplitter()
            .convert(utf8.decode(bytes, allowMalformed: true))
            .where((l) => l.trim().isNotEmpty)
            .length;
      }

      final meta = utf8.encode(await _metaText(
        files: files.length,
        lineCount: lineCount,
        totalBytes: totalBytes,
        first: first,
        last: last,
      ));
      archive.addFile(ArchiveFile('meta.txt', meta.length, meta));

      final zipped = ZipEncoder().encode(archive);
      if (zipped == null) return null;

      final outDir = Directory('${dir.path}/export');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final out = File('${outDir.path}/diag-${_stampForName(DateTime.now())}.zip');
      out.writeAsBytesSync(zipped, flush: true);
      _pruneExports(outDir);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// 把原生 handler 写的 `<filesDir>/logs/native-crash-*.txt` 合入 diag 日志
  /// 后删掉，避免碎片文件一堆（v2.67.0）。
  ///
  /// 为什么在 Dart 侧合并：原生崩溃文件与 Dart 日志在同一个目录下
  /// （`getApplicationSupportDirectory()` 在 Android 上就是 `filesDir`），
  /// Dart 能直接读写，不必为一个"搬文件"的动作再开一条通道。
  static Future<int> mergeNativeCrashes() async {
    try {
      final dir = _logDirSync ?? await _logDir();
      if (!dir.existsSync()) return 0;
      var merged = 0;
      final entries = dir.listSync();
      for (final e in entries) {
        if (e is! File) continue;
        final name = _baseName(e.path);
        if (!name.startsWith('native-crash-') || !name.endsWith('.txt')) continue;
        try {
          final text = e.readAsStringSync();
          _pending.add(
            '${_timestamp(DateTime.now())} [crash:native] 原生崩溃记录 $name',
          );
          for (final line in const LineSplitter().convert(text)) {
            if (line.trim().isEmpty) continue;
            _pending.add(_formatBody(line, DateTime.now()));
          }
          e.deleteSync();
          merged++;
        } catch (_) {
          // 单个文件读不动就跳过，绝不因为一个碎片文件拖住启动
        }
      }
      if (merged > 0) flushSync();
      return merged;
    } catch (_) {
      return 0;
    }
  }

  /// 测试用：恢复到"没接管过"的初始态（含注入根目录与所有内存态）。
  @visibleForTesting
  static void resetForTest() {
    if (_installed) {
      final prev = _previous;
      if (prev != null && debugPrint == write) debugPrint = prev;
    }
    _installed = false;
    _previous = null;
    _logDirCache = null;
    _rootFuture = null;
    _pending.clear();
    _recent.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _lastKey = null;
    _lastAt = null;
    _duplicateCount = 0;
    rootDirOverride = null;
    enabled = true;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 目录句柄（同步版）：测试注入优先，否则用 [install] 解析出来的缓存。
  static Directory? get _logDirSync {
    final override = rootDirOverride;
    if (override != null) return Directory('${override.path}/logs');
    return _logDirCache;
  }

  /// 解析日志目录并缓存（异步版，只走 path_provider）。
  static Future<Directory> _logDir() async {
    final override = rootDirOverride;
    if (override != null) {
      final dir = Directory('${override.path}/logs');
      _logDirCache = dir;
      return dir;
    }
    final cached = _logDirCache;
    if (cached != null) return cached;
    final root = await (_rootFuture ??= getApplicationSupportDirectory());
    final dir = Directory('${root.path}/logs');
    _logDirCache = dir;
    return dir;
  }

  /// 收一条日志：解析 tag → 去重 → 脱敏 → 入缓冲 → 触发攒批 flush。
  static void _enqueue(String message) {
    final now = DateTime.now();
    final tag = _tagOf(message);
    final prefix = message.length > dedupePrefixLength
        ? message.substring(0, dedupePrefixLength)
        : message;
    final key = '$tag\u0000$prefix';

    if (key == _lastKey &&
        _lastAt != null &&
        now.difference(_lastAt!) < dedupeWindow) {
      _duplicateCount++;
      return;
    }

    // 上一条被压掉的重复次数，作为一行标记补上（否则读者会以为日志断了）
    if (_duplicateCount > 0) {
      _push(
        '${_timestamp(now)} [dedupe] 上一条在 1 秒内重复 $_duplicateCount 次，已省略',
      );
    }
    _lastKey = key;
    _lastAt = now;
    _duplicateCount = 0;

    _push(_formatBody(message, now));

    if (_pending.length >= flushBatchSize) {
      flushSync();
    } else {
      _flushTimer ??= Timer(flushInterval, () {
        _flushTimer = null;
        flushSync();
      });
    }
  }

  /// 一条完整的落盘行：`HH:mm:ss.SSS <脱敏后的正文>`。
  static String _formatBody(String message, DateTime now) {
    var body = redact.sanitizeLogText(message);
    if (body.length > maxLineLength) {
      body = '${body.substring(0, maxLineLength)}…（已截断）';
    }
    // 多行消息（stack trace）：只给首行加时间前缀，后续行原样保留 ——
    // stack trace 的缩进是它可读性的一半，别为了对齐把它改坏。
    final lines = const LineSplitter().convert(body);
    if (lines.length <= 1) return '${_timestamp(now)} $body';
    final head = '${_timestamp(now)} ${lines.first}';
    return [head, ...lines.skip(1)].join('\n');
  }

  static void _push(String line) {
    _pending.add(line);
    _recent.add(line);
    if (_recent.length > recentCapacity) _recent.removeAt(0);
  }

  /// 从消息前缀 `[xxx]` 解析 tag；没有就用 `app`。
  static String _tagOf(String message) {
    final m = RegExp(r'^\s*\[([^\]\n]{1,32})\]').firstMatch(message);
    return m != null ? m[1]! : 'app';
  }

  /// 单文件超过 512KB → 轮转：最旧的删掉，其余序号 +1，当前文件变 `.1`。
  static void _rotateIfNeeded(Directory dir, DateTime now, int incoming) {
    final active = File(_activePathFor(dir, now));
    final size = active.existsSync() ? active.lengthSync() : 0;
    if (size == 0 || size + incoming <= maxFileBytes) return;
    final base = _baseNameWithoutExt(active.path);
    for (var i = maxFiles - 1; i >= 1; i--) {
      final src = File('${dir.path}/$base.$i.log');
      if (!src.existsSync()) continue;
      if (i == maxFiles - 1) {
        src.deleteSync();
      } else {
        src.renameSync('${dir.path}/$base.${i + 1}.log');
      }
    }
    active.renameSync('${dir.path}/$base.1.log');
  }

  /// 份数上限（4 份）+ 目录总量上限（5MB）；[keep] 是当前活跃文件，永不删。
  static void _pruneDir(Directory dir, {String? keep}) {
    final files = <File>[];
    try {
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = _baseName(e.path);
        if (name.startsWith('diag-') && name.endsWith('.log')) files.add(e);
      }
    } catch (_) {
      return;
    }
    try {
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    } catch (_) {
      return;
    }
    // 跨越多个自然日时也可能攒出多于 4 份 → 按修改时间删最旧
    while (files.length > maxFiles) {
      final victim = files.first;
      if (keep != null && victim.path == keep) break;
      try {
        victim.deleteSync();
        files.removeAt(0);
      } catch (_) {
        break;
      }
    }
    var total = 0;
    for (final f in files) {
      try {
        total += f.lengthSync();
      } catch (_) {
        // 单个文件 stat 失败：不参与总量计算
      }
    }
    while (total > maxDirBytes && files.length > 1) {
      final victim = files.first;
      if (keep != null && victim.path == keep) break;
      final len = victim.existsSync() ? victim.lengthSync() : 0;
      try {
        victim.deleteSync();
        files.removeAt(0);
        total -= len;
      } catch (_) {
        break;
      }
    }
  }

  /// 导出目录只留最近 3 个 zip（每次导出都留一份会悄悄吃掉存储）。
  static void _pruneExports(Directory outDir) {
    try {
      final zips = outDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList()
        ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      while (zips.length > 3) {
        zips.removeAt(0).deleteSync();
      }
    } catch (_) {
      // 静默：清理失败不影响本次导出
    }
  }

  static List<File> _logFiles(Directory dir) {
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) =>
              _baseName(f.path).startsWith('diag-') &&
              f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      return files;
    } catch (_) {
      return const <File>[];
    }
  }

  /// `meta.txt`：App 版本、系统/机型、时间范围、日志条数（导出时随 zip 一起
  /// 发给开发者，省掉一问一答）。
  static Future<String> _metaText({
    required int files,
    required int lineCount,
    required int totalBytes,
    DateTime? first,
    DateTime? last,
  }) async {
    var version = kAppVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) version = info.version;
    } catch (_) {
      // 测试环境无原生通道 → 退回 config.dart 的兜底版本号
    }
    final buf = StringBuffer()
      ..writeln('amoTV 诊断日志')
      ..writeln('App 版本：$version')
      ..writeln('系统：${await _deviceLine()}')
      ..writeln('导出时间：${_stampForName(DateTime.now())}')
      ..writeln('日志文件数：$files')
      ..writeln('日志条数（非空行）：$lineCount')
      ..writeln('日志总大小：$totalBytes 字节')
      ..writeln('最早写入：${first == null ? '—' : _stampForName(first)}')
      ..writeln('最后写入：${last == null ? '—' : _stampForName(last)}')
      ..writeln('')
      ..writeln('说明：日志已自动脱敏 —— URL 只留 host+path，')
      ..writeln('token / SESSDATA / 手机号等换成 <已脱敏> 占位符。');
    return buf.toString();
  }

  /// Android 机型 / 版本（原生 `DiagInfoPlugin`）；通道不可用 → dart:io 的系统
  /// 版本串（测试 / 非 Android 平台）。
  static Future<String> _deviceLine() async {
    try {
      final map = await const MethodChannel('bili_whitelist/diag')
          .invokeMethod<Map<Object?, Object?>>('deviceInfo');
      if (map != null && map.isNotEmpty) {
        final manufacturer = '${map['manufacturer'] ?? ''}'.trim();
        final model = '${map['model'] ?? ''}'.trim();
        final release = '${map['release'] ?? ''}'.trim();
        final sdk = '${map['sdkInt'] ?? ''}'.trim();
        final made = '$manufacturer $model'.trim();
        return 'Android $release (API $sdk) · $made';
      }
    } catch (_) {
      // 静默：非 Android / 测试环境
    }
    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }

  static String _activePathFor(Directory dir, DateTime now) =>
      '${dir.path}/diag-${_dateStamp(now)}.log';

  /// `YYYYMMDD`（日志文件名里的那一天）。
  static String _dateStamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';

  /// `YYYYMMDD-HHmmss`（导出文件名 / meta 里的时间）。
  static String _stampForName(DateTime t) =>
      '${_dateStamp(t)}-'
      '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}';

  /// `HH:mm:ss.SSS`（单行时间前缀）。
  static String _timestamp(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  /// 取文件名。**两种分隔符都要认**：`path_provider` 给的是系统分隔符，
  /// 而本文件内部用 `/` 拼路径，Windows 上会出现 `C:\a\logs/diag-x.log`。
  static String _baseName(String path) {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    final i = slash > backslash ? slash : backslash;
    return i < 0 ? path : path.substring(i + 1);
  }

  /// `xxx/diag-20261122.log` → `diag-20261122`（轮转序号插在 `.log` 之前）。
  static String _baseNameWithoutExt(String path) {
    final name = _baseName(path);
    return name.endsWith('.log') ? name.substring(0, name.length - 4) : name;
  }
}
