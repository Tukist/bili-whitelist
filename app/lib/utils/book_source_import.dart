import 'dart:convert';

import '../models/book_source.dart';

/// 书源导入结果（纯数据，供 UI 逐项展示）。
class BookSourceImportResult {
  /// 解析成功的书源（已按 [BookSource.key] 去重）。
  final List<BookSource> sources;

  /// 人类可读的问题列表（**不是** FormatException 的原始堆栈）：
  /// 「第 3 项缺少 name，已跳过」「「Foo」覆盖了同名书源」这类直接能念给用户听的话。
  final List<String> errors;

  /// 文本里识别出的「索引链接」（一个 .json 里列着更多书源地址的那种）。
  ///
  /// R1 只识别不下载（网络抓取在 R2/R3）。
  final List<String> indexUrls;

  const BookSourceImportResult({
    this.sources = const [],
    this.errors = const [],
    this.indexUrls = const [],
  });

  bool get isEmpty => sources.isEmpty && errors.isEmpty && indexUrls.isEmpty;
}

/// 从任意文本里解析书源（**纯函数**：不碰网络、不碰 SharedPreferences）。
///
/// 支持的输入形态（都是用户真实会粘进来的东西）：
/// 1. 单个 JSON 对象 —— 一个书源；
/// 2. JSON 数组 —— 一包书源；
/// 3. 混着说明文字的粘贴内容 —— 从**第一个** `{` 或 `[` 起做括号配对，
///    取到与之配对的结尾；前后的「导入方法：1. 复制下面的内容…」直接忽略；
/// 4. 每行一个的索引链接（`https://…/bookSource.json`）—— 收进
///    [BookSourceImportResult.indexUrls]，**不算格式错误**（用户贴的就是
///    索引包，R1 没能力下载，报「格式错误」会让人以为自己做错了）；
/// 5. legado 原生书源 —— 自动识别（有 `bookSourceName`）后走
///    [BookSource.fromLegado]。
///
/// 为什么用括号配对而不是「从第一个 `{` 到最后一个 `}`」：粘贴内容末尾常带
/// 作者署名 / 免责声明 / 二维码说明，贪心截取会把 `}` 后面的文字一起卷进来
/// 变成「JSON 解析失败」，而真正的 JSON 其实好得很。
BookSourceImportResult parseBookSourceText(String text) {
  final errors = <String>[];
  var work = text;

  // ---- 第 1 步：先把索引链接摘出去 ----
  // 整行就是一个 .json 地址的才算（`详见 https://…/x.json` 这种说明文字里的
  // 链接不算，否则会把一段散文当成索引包）。
  final indexUrls = <String>[];
  final keptLines = <String>[];
  for (final line in work.split('\n')) {
    final trimmed = line.trim();
    if (_kIndexUrlPattern.hasMatch(trimmed)) {
      if (!indexUrls.contains(trimmed)) indexUrls.add(trimmed);
    } else {
      keptLines.add(line);
    }
  }
  work = keptLines.join('\n');

  // ---- 第 2 步：抠出 JSON 片段 ----
  final snippet = extractFirstJsonSnippet(work);
  if (snippet == null) {
    if (indexUrls.isEmpty) {
      // 分两种说清楚：压根没有 JSON 起点 vs 有起点但括号/引号没闭合。
      // 后者不能只说「没找到书源 JSON」——用户明明贴了个 `{`，那是在告诉他
      // 「你贴的东西我一个字都没看懂」，而真实原因是内容被截断了。
      errors.add(
        work.contains('{') || work.contains('[')
            ? 'JSON 内容不完整：括号或引号没有闭合（是不是只复制了半截？）'
            : '没有找到书源 JSON：请粘贴以 { 或 [ 开头的内容',
      );
    }
    return BookSourceImportResult(errors: errors, indexUrls: indexUrls);
  }

  // ---- 第 3 步：解析 JSON（失败时给人话） ----
  Object? decoded;
  try {
    decoded = jsonDecode(snippet.text);
  } on FormatException catch (e) {
    errors.add(_humanJsonError(e, snippet));
    return BookSourceImportResult(errors: errors, indexUrls: indexUrls);
  }

  // ---- 第 4 步：逐条转模型 ----
  final rawItems = <Object?>[];
  if (decoded is List) {
    rawItems.addAll(decoded);
  } else if (decoded is Map) {
    rawItems.add(decoded);
  } else {
    errors.add('JSON 顶层既不是对象也不是数组，无法识别为书源');
    return BookSourceImportResult(errors: errors, indexUrls: indexUrls);
  }

  final byKey = <String, BookSource>{};
  for (var i = 0; i < rawItems.length; i++) {
    final item = rawItems[i];
    if (item is! Map) {
      errors.add('第 ${i + 1} 项不是 JSON 对象，已跳过');
      continue;
    }
    final map = {
      for (final e in item.entries) e.key.toString(): e.value,
    };
    // legado 原生格式自动识别（有 bookSourceName / bookSourceUrl 就是它）
    final parsed = BookSource.looksLikeLegado(map)
        ? BookSource.fromLegado(map)
        : BookSource.fromJson(map);
    if (parsed == null) {
      errors.add('第 ${i + 1} 项缺少书源名或站点地址（name / bookSourceName），已跳过');
      continue;
    }
    if (parsed.name.isEmpty) {
      errors.add('第 ${i + 1} 项缺少书源名（name），已跳过');
      continue;
    }
    if (parsed.baseUrl.isEmpty) {
      errors.add('书源「${parsed.name}」缺少站点地址（baseUrl），已跳过');
      continue;
    }
    // 同名（大小写不敏感）后出现者覆盖先出现者 —— 用户把一个源的新版
    // 贴在旧版后面时，期望生效的是新版
    final existed = byKey.containsKey(parsed.key);
    if (existed) {
      errors.add('「${parsed.name}」覆盖了同名书源');
    }
    byKey[parsed.key] = parsed;
  }

  return BookSourceImportResult(
    sources: byKey.values.toList(),
    errors: errors,
    indexUrls: indexUrls,
  );
}

/// 抠出来的 JSON 片段（原文 + 在**去噪后文本**里的行号，用于报错定位）。
class JsonSnippet {
  final String text;

  /// 片段起始位置所在行号（1 起）。
  final int startLine;

  /// JSON 片段里第 [lineInSnippet] 行（1 起）对应的原文行号。
  int lineOf(int lineInSnippet) => startLine + lineInSnippet - 1;

  const JsonSnippet(this.text, this.startLine);
}

/// 从文本里取出**第一个** `{` 或 `[` 到与之配对的结尾（括号配对 + 跳过字符串）。
///
/// 几种必须照顾的情况：
/// - JSON 字符串里的 `}` / `]` / 花括号（比如正则规则 `"##\\{.*?\\}##"`）
///   不能当括号用 → 维护 `inString` + `escape` 状态；
/// - 第一个 `{` 出现在 `[` 之后（顶层数组）时，起点必须是 `[` → 取两者中
///   位置靠前的那个；
/// - 配对不完整（用户只粘了半截）→ 返回 null，调用方给「内容不完整」提示。
JsonSnippet? extractFirstJsonSnippet(String text) {
  final firstObj = text.indexOf('{');
  final firstArr = text.indexOf('[');
  int start;
  if (firstObj < 0 && firstArr < 0) return null;
  if (firstObj < 0 || (firstArr >= 0 && firstArr < firstObj)) {
    start = firstArr;
  } else {
    start = firstObj;
  }

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final ch = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      continue;
    }
    if (ch == '{' || ch == '[') {
      depth++;
    } else if (ch == '}' || ch == ']') {
      depth--;
      if (depth == 0) {
        return JsonSnippet(text.substring(start, i + 1), _lineOf(text, start));
      }
    }
  }
  return null;
}

/// 索引链接的识别规则：整行一个 http(s) 地址，且路径 / 查询里带 `.json`。
///
/// 为什么要求 `.json`：用户还会贴普通的网页链接（站点首页、书源仓库页），
/// 那些不是索引包；把整行任意 URL 都当索引链接会给出「已记录 N 个索引链接」
/// 的假承诺。
final RegExp _kIndexUrlPattern = RegExp(
  r'^https?://\S+\.json(\?\S*)?$',
  caseSensitive: false,
);

/// JSON 语法错误 → 人类可读的一句话（带原文行号）。
String _humanJsonError(FormatException e, JsonSnippet snippet) {
  final offset = e.offset;
  if (offset == null || offset < 0 || offset > snippet.text.length) {
    return 'JSON 格式不正确（可能是少了逗号、多了逗号或引号没闭合）';
  }
  final upto = snippet.text.substring(0, offset);
  final lineInSnippet = '\n'.allMatches(upto).length + 1;
  final col = offset - (upto.lastIndexOf('\n') + 1) + 1;
  return 'JSON 格式不正确（第 ${snippet.lineOf(lineInSnippet)} 行第 $col 个字符附近：'
      '常见原因是有个逗号多了/少了，或引号没配对）';
}

int _lineOf(String text, int index) {
  var line = 1;
  for (var i = 0; i < index && i < text.length; i++) {
    if (text[i] == '\n') line++;
  }
  return line;
}
