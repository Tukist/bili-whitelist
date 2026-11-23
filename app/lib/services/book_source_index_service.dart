/// 书源索引下载（R3 新增）：把「每行一个 .json 地址」的索引文本，变成一份
/// 可筛选、可挑选的 [BookSource] 列表。
///
/// ## 为什么要有这一层
/// R1 只认得出索引链接（存进 `reader:index_urls`）却不去下载；用户手里那 4 个
/// `legado.aoaostar.com/sources/*.json` 装着 6000+ 个源 —— 让人一条条粘进
/// 剪贴板是不现实的。这一层负责：**串行下载 → 解码 → 复用 R1 的解析器 →
/// 去重 → 标注 needsJs**，UI 只做展示与挑选。
///
/// ## 四个关键取舍
/// 1. **串行、不并发**：单个文件最大 21MB，4 个一起下会在手机上同时压进
///    80MB+ 的字节缓冲，低端机直接 OOM。串行慢一点，但内存峰值只有一个文件。
/// 2. **单文件 25MB 上限**：书源索引正常在几千 KB 量级，25MB 已经能装下
///    「6174 个源的完整 raw」；再大基本是下载到了 HTML 错误页 / 打包站，
///    读进内存只会白白吃 RAM。超限**直接跳过**（先看 `Content-Length`，
///    服务器不报这个头就边读边数），并且把原因写进结果 —— 不静默丢。
/// 3. **解析复用 `parseBookSourceText`**：书源 JSON 的坑（括号配对、混排说明
///    文字、legado 字段映射）R1 已经踩平了，这里再写一套必然与「从剪贴板
///    导入」给出不同结果。本服务只在解析前**展开一层信封**（见
///    [expandBookSourceEnvelope]），不改解析器语义。
/// 4. **[fetchIndexes] 永不抛异常**：下载是「一堆可能失败的 IO」，一个坏链接
///    不该让整个页面报错 —— 每个 URL 的成败都落在 [IndexUrlOutcome] 里。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/book_source.dart';
import '../utils/book_source_import.dart';
import 'book_rule/legado_compat.dart';
import 'book_source_store.dart';

/// 单个索引文件的大小上限（25MB）。
///
/// 取值理由见文件头第 2 条：正常索引远小于它，超过基本是「下到别的东西了」。
const int kBookSourceIndexMaxBytes = 25 * 1024 * 1024;

/// 连接 / 等响应头 / 下载途中两包之间的超时。
///
/// **不是「整次下载必须在 15 秒内完成」**：21MB 文件在慢网上本来就要几分钟，
/// 卡死总时长会把正常的大文件误杀。15 秒是「对方没动静了」的判定。
const Duration kBookSourceIndexTimeout = Duration(seconds: 15);

/// 抓索引用的桌面 Chrome UA（与 `book_rule/rule_engine.dart` 的
/// [kRuleDesktopUA] 同口径，但不在本文件 import 那个模块 —— 它会牵进
/// webview_flutter，索引下载是纯 HTTP，不该有这层依赖）。
const String kBookSourceIndexUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 单个索引链接的结果状态。
enum IndexUrlStatus {
  /// 下载并解析成功（哪怕里面 0 条可用，只要文件本身没问题也算 ok）。
  ok,

  /// 失败：网络 / HTTP 错误码 / 超时 / 内容不是合法 JSON。
  failed,

  /// 跳过：超出大小上限（没读进内存）。
  skipped,
}

/// 一个索引链接的下场（UI 逐行展示「哪个成功了、哪个为什么没成」）。
class IndexUrlOutcome {
  final String url;
  final IndexUrlStatus status;

  /// 这次从这个 URL 解析出多少个**可用**书源（已去重）。
  final int count;

  /// 给人看的一句话（失败 / 跳过时必填；成功时可能是「疑似非 UTF-8」这类告警）。
  final String message;

  const IndexUrlOutcome({
    required this.url,
    required this.status,
    this.count = 0,
    this.message = '',
  });

  bool get isOk => status == IndexUrlStatus.ok;
  bool get isFailed => status == IndexUrlStatus.failed;
  bool get isSkipped => status == IndexUrlStatus.skipped;

  @override
  String toString() => 'IndexUrlOutcome($status, $count, $url)';
}

/// 整批索引下载的结果。
class BookSourceIndexResult {
  /// 全部书源（跨文件已按 name 去重，保留先出现的）。
  final List<BookSource> sources;

  /// 每个 URL 的下场（顺序与入参一致）。
  final List<IndexUrlOutcome> outcomes;

  /// 需要 JS 的书源 key 集合（[usesJs] 在下载时算一次）。
  ///
  /// 为什么预先算好而不是 UI 里现算：选择页要在 6000+ 条上做「只看不需要 JS
  /// 的」过滤，而 [usesJs] 会递归扫整份 raw JSON —— 放进 build 里就是每帧
  /// 几千次递归。下载时算一次，UI 只做 [Set.contains]。
  final Set<String> jsKeys;

  const BookSourceIndexResult({
    this.sources = const [],
    this.outcomes = const [],
    this.jsKeys = const {},
  });

  /// 该源要不要 JS（本版跑不了）。
  bool needsJs(BookSource source) => jsKeys.contains(source.key);

  /// 需要 JS 的源数量。
  int get jsCount => jsKeys.length;

  /// 失败的链接（含超限跳过），UI 逐条列原因。
  List<IndexUrlOutcome> get problems => [
        for (final o in outcomes)
          if (!o.isOk) o,
      ];

  /// 一句汇总（页面顶部那行字）。
  ///
  /// 例：`共 6174 个源（其中 1263 个需 JS，本版跑不了）· 失败 1 个：响应超时`
  String get summary {
    if (outcomes.isEmpty && sources.isEmpty) return '还没有下载索引';
    final buffer = StringBuffer('共 ${sources.length} 个源');
    if (jsCount > 0) {
      buffer.write('（其中 $jsCount 个需 JS，本版跑不了）');
    }
    final failed = [for (final o in outcomes) if (o.isFailed) o];
    if (failed.isNotEmpty) {
      buffer.write('· 失败 ${failed.length} 个：${failed.first.message}');
    }
    final skipped = [for (final o in outcomes) if (o.isSkipped) o];
    if (skipped.isNotEmpty) {
      buffer.write('· 跳过 ${skipped.length} 个超大文件');
    }
    return buffer.toString();
  }
}

/// 索引下载服务。
class BookSourceIndexService {
  /// 干净的网络客户端：不注入全局 Cookie / 全局头（见 [BookSourceStore] 类注释
  /// 里「书源是阅读器的私货」的同一思路 —— 索引站不需要 B 站登录态）。
  final Dio _dio;

  /// 单文件上限（测试可传小值，免得真造 25MB 字节）。
  final int maxBytes;

  /// 每次下载最多吃进内存的字节数（= [maxBytes]）。
  BookSourceIndexService({Dio? dio, this.maxBytes = kBookSourceIndexMaxBytes})
      : _dio = dio ?? _buildDio();

  static Dio _buildDio() => Dio(BaseOptions(
        connectTimeout: kBookSourceIndexTimeout,
        receiveTimeout: kBookSourceIndexTimeout,
        // 重定向：索引站常把 http 跳到 https / 换个 CDN 路径
        followRedirects: true,
        maxRedirects: 5,
      ));

  /// 逐个下载并解析 [urls]；`urls` 为 null 时读 store 里的 `reader:index_urls`。
  ///
  /// [onProgress] 在**每个 URL 开始前**回调一次 `(已完成数, 总数)`，结束时再补
  /// 一次 `(total, total)` —— 页面据此显示「正在下载 2/4…」。
  ///
  /// **永不抛异常**：连「读 store 都失败」也退化成「没有任何链接」。
  Future<BookSourceIndexResult> fetchIndexes({
    List<String>? urls,
    void Function(int done, int total)? onProgress,
  }) async {
    var targets = <String>[];
    try {
      final raw = urls ?? await BookSourceStore.instance.getIndexUrls();
      targets = [
        for (final u in raw)
          if (u.trim().isNotEmpty) u.trim(),
      ];
    } catch (_) {
      targets = const [];
    }
    if (targets.isEmpty) return const BookSourceIndexResult();

    final outcomes = <IndexUrlOutcome>[];
    final merged = <BookSource>[];
    final seen = <String>{};

    for (var i = 0; i < targets.length; i++) {
      onProgress?.call(i, targets.length);
      // 串行：await 到底再下一个（见文件头第 1 条）
      final one = await _fetchOne(targets[i]);
      outcomes.add(one.outcome);
      // 跨文件去重：**先出现的赢**（先下到的索引文件保持权威，不让后面
      // 文件里的同名旧条目把前面覆盖掉）
      for (final source in one.sources) {
        if (seen.add(source.key)) merged.add(source);
      }
    }
    onProgress?.call(targets.length, targets.length);

    final jsKeys = <String>{};
    for (final source in merged) {
      if (_safeNeedsJs(source)) jsKeys.add(source.key);
    }
    return BookSourceIndexResult(
      sources: merged,
      outcomes: outcomes,
      jsKeys: jsKeys,
    );
  }

  // ==================== 内部：单个 URL ====================

  Future<_SingleOutcome> _fetchOne(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return _SingleOutcome.failed(url, '不是有效的 http(s) 地址');
    }

    // ---- 发请求（要的是流，不是一次性读进内存） ----
    Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'User-Agent': kBookSourceIndexUA,
            'Accept': 'application/json,text/plain,*/*',
          },
        ),
      );
    } on DioException catch (e) {
      return _SingleOutcome.failed(url, _describeDio(e));
    } catch (e) {
      return _SingleOutcome.failed(url, '请求失败（${e.runtimeType}）');
    }

    final body = response.data;
    if (body == null) return _SingleOutcome.failed(url, '服务器没有返回内容');

    // ---- 先看 Content-Length：超限就不读 body ----
    final declared = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (exceedsMaxBytes(declared, maxBytes: maxBytes)) {
      await _discard(body.stream);
      final mb = _mbText(declared!);
      return _SingleOutcome.skipped(
        url,
        '文件 $mb 超过 ${_mbText(maxBytes)} 上限，已跳过（没有下载内容）',
      );
    }

    // ---- 读字节（服务器不报长度时边读边数，超了立刻停） ----
    final builder = BytesBuilder(copy: false);
    var received = 0;
    try {
      // 单包超时：对方 15 秒不给下一段数据就当成断流
      await for (final chunk in body.stream.timeout(kBookSourceIndexTimeout)) {
        received += chunk.length;
        if (exceedsMaxBytes(received, maxBytes: maxBytes)) {
          builder.clear();
          return _SingleOutcome.skipped(
            url,
            '内容超过 ${_mbText(maxBytes)} 上限（读到 ${_mbText(received)} 仍未结束），已跳过',
          );
        }
        builder.add(chunk);
      }
    } on TimeoutException {
      return _SingleOutcome.failed(url, '下载超时（${kBookSourceIndexTimeout.inSeconds} 秒没有新数据）');
    } catch (e) {
      return _SingleOutcome.failed(url, '下载中断（${e.runtimeType}）');
    }

    final bytes = builder.takeBytes();
    if (bytes.isEmpty) return _SingleOutcome.failed(url, '内容是空的');

    // ---- 解码：UTF-8 强解（allowMalformed 保证不抛）+ 去 BOM ----
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (text.trim().isEmpty) return _SingleOutcome.failed(url, '内容是空的');

    final warnings = <String>[];
    if (!looksLikeUtf8(text)) {
      // 继续解析：utf8 强解的替换符会让 JSON 里个别书名变乱码，但结构还是
      // 好的 —— 能导入一部分总比整份丢掉强，所以只告警不失败
      warnings.add('疑似非 UTF-8 编码，部分文字可能是乱码');
    }

    // ---- 解析：包一层的信封先展开，再交给 R1 的解析器 ----
    final expanded = expandBookSourceEnvelope(text);
    final parsed = parseBookSourceText(expanded ?? text);
    if (parsed.sources.isEmpty) {
      final reason = parsed.errors.isEmpty
          ? '没有识别到书源 JSON'
          : parsed.errors.first;
      return _SingleOutcome.failed(url, reason);
    }

    // 文件内的同名已由解析器合并（后出现者胜 —— 用户把新版贴在后面时期望
    // 生效的是新版）；这里再过一次 dedupeByName 是幂等操作，真正起作用的
    // 「先出现的赢」发生在跨文件合并（见 fetchIndexes 里的 seen 集合）。
    final sources = dedupeByName(parsed.sources);
    final message = warnings.isEmpty ? '' : warnings.join('；');
    return _SingleOutcome(
      sources: sources,
      outcome: IndexUrlOutcome(
        url: url,
        status: IndexUrlStatus.ok,
        count: sources.length,
        message: message,
      ),
    );
  }

  /// 丢掉一个不打算解析的响应体（关掉连接，别把 21MB 白读进来）。
  Future<void> _discard(Stream<List<int>> stream) async {
    try {
      await stream.listen(null).cancel();
    } catch (_) {
      // 取消失败（连接已经断了）不影响结论
    }
  }

  bool _safeNeedsJs(BookSource source) {
    try {
      return usesJs(source);
    } catch (_) {
      // raw 里有畸形结构之类：宁可当成「可能要 JS」，也不要让整批崩掉
      return true;
    }
  }
}

/// 一个 URL 的中间结果（sources 给调用方合并，outcome 给 UI 展示）。
class _SingleOutcome {
  final List<BookSource> sources;
  final IndexUrlOutcome outcome;

  const _SingleOutcome({this.sources = const [], required this.outcome});

  factory _SingleOutcome.failed(String url, String message) => _SingleOutcome(
        outcome: IndexUrlOutcome(
          url: url,
          status: IndexUrlStatus.failed,
          message: message,
        ),
      );

  factory _SingleOutcome.skipped(String url, String message) => _SingleOutcome(
        outcome: IndexUrlOutcome(
          url: url,
          status: IndexUrlStatus.skipped,
          message: message,
        ),
      );
}

// ==================== 纯函数（可单独单测） ====================

/// 按 name（大小写不敏感）去重，**保留先出现的**。
///
/// 为什么是「先出现的赢」而不是解析器那条「后出现的赢」：跨文件合并时，
/// 先下到的索引文件是用户排序里的第一份，让它当权威；后面的文件里有同名
/// 条目只当成重复，不去覆盖。
List<BookSource> dedupeByName(List<BookSource> sources) {
  final seen = <String>{};
  final out = <BookSource>[];
  for (final source in sources) {
    if (seen.add(source.key)) out.add(source);
  }
  return out;
}

/// 字节长度是否超过上限（null = 服务器没报 `Content-Length`，不能据此判断）。
bool exceedsMaxBytes(int? byteLength, {int maxBytes = kBookSourceIndexMaxBytes}) {
  if (byteLength == null) return false;
  return byteLength > maxBytes;
}

/// 解码出来的文本像不像 UTF-8。
///
/// 判据：UTF-8 强解失败的位置会变成替换符 `U+FFFD`。偶尔一个（文件里某个
/// 书名用了别的编码）不算事；**占比超过 1%** 才说明整份文件的编码就不对
/// （GBK 中文按 UTF-8 解几乎是 100% 替换符）。
bool looksLikeUtf8(String text) {
  if (text.isEmpty) return true;
  var bad = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0xFFFD) bad++;
  }
  if (bad == 0) return true;
  return bad / text.length < 0.01;
}

/// 索引文件可能是「书源数组」/「包了一层 `{"sources":[…]}`」/「单个书源」。
///
/// 前两种要交给 [parseBookSourceText]，但它把顶层对象当成**一个**书源
/// （`{"sources":[…]}` 会被判成「第 1 项缺少书源名」）。所以在**本服务里**
/// 先把信封拆成数组的 JSON 文本再喂过去 —— 不改解析器语义，R1 的三种入口
/// （剪贴板 / 文件 / 链接）行为一个字都不变。
///
/// 返回 null = 不是「带列表的信封」，调用方直接拿原文去解析。
String? expandBookSourceEnvelope(String text) {
  final snippet = extractFirstJsonSnippet(text);
  if (snippet == null) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(snippet.text);
  } catch (_) {
    return null; // 让解析器去给人话（它带行号/列号）
  }
  if (decoded is! Map) return null;
  final list = _envelopeList(decoded);
  if (list == null) return null;
  try {
    return jsonEncode(list);
  } catch (_) {
    return null;
  }
}

/// 信封里那个「列表」：先按常见键名找，找不到再看有没有哪个键的值是
/// 「书源对象组成的数组」（`{"bookSources":[…],"version":3}` 这种）。
List<Object?>? _envelopeList(Map<dynamic, dynamic> map) {
  const keys = ['sources', 'booksources', 'books', 'data', 'list', 'items'];
  for (final entry in map.entries) {
    final name = entry.key.toString().toLowerCase();
    if (!keys.contains(name)) continue;
    if (entry.value is List) return (entry.value as List).cast<Object?>();
    // `{"data":{"sources":[…]}}`：再下探一层
    if (entry.value is Map) {
      final nested = _envelopeList(entry.value as Map);
      if (nested != null) return nested;
    }
  }
  for (final entry in map.entries) {
    final value = entry.value;
    if (value is! List || value.isEmpty) continue;
    final first = value.first;
    if (first is! Map) continue;
    final map0 = {
      for (final kv in first.entries) kv.key.toString(): kv.value,
    };
    if (BookSource.looksLikeLegado(map0) || map0.containsKey('name')) {
      return value.cast<Object?>();
    }
  }
  return null;
}

/// DioException → 一句人话。
String _describeDio(DioException e) {
  final status = e.response?.statusCode;
  if (status != null) {
    return '服务器返回 HTTP $status';
  }
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
      return '连接超时（${kBookSourceIndexTimeout.inSeconds} 秒）';
    case DioExceptionType.sendTimeout:
      return '发送超时';
    case DioExceptionType.receiveTimeout:
      return '响应超时（${kBookSourceIndexTimeout.inSeconds} 秒）';
    case DioExceptionType.badCertificate:
      return '证书校验失败';
    case DioExceptionType.cancel:
      return '请求已取消';
    case DioExceptionType.connectionError:
      return '连不上服务器';
    case DioExceptionType.badResponse:
      return '服务器响应异常';
    case DioExceptionType.transformTimeout:
      return '解析响应超时';
    case DioExceptionType.unknown:
      return '网络错误（${e.message ?? e.error?.runtimeType ?? '未知'}）';
  }
}

/// 字节数 → 「12.3 MB」。
String _mbText(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
