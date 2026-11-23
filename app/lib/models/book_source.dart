/// 书源模型（R1 新增，书源式阅读器的数据底座）。
///
/// ## 为什么先有模型、后有能力
/// R1 只做「导入 / 存储 / 管理」，**规则解析、网络抓取、书架与阅读页都在
/// R2/R3**。模型先定死的好处：导入的文件格式、存储的 JSON 结构、管理页
/// 展示的字段一次成型，后面几批只往里填执行逻辑，不用回头改存储格式
/// （改格式就得写迁移，用户已经导入的源会掉）。
///
/// ## 字段口径
/// - 字段名一律**小驼峰**，[toJson] 能原样回写 —— 「导入 → 存盘 → 再导出」
///   必须字节级等价，否则用户的书源会在一次导入导出里悄悄丢字段。
/// - 只有 [name] / [baseUrl] 是必填（一个源要能区分、要有站点根）；其余都给
///   默认值，这样手写一个最小书源只要两个键。
/// - [key] 是**唯一键**：名字大小写不敏感（`Foo` 与 `foo` 视为同一个源），
///   同名导入即覆盖，见 `utils/book_source_import.dart` 的去重逻辑。
///
/// ## legado 兼容
/// [BookSource.fromLegado] 把开源阅读（legado）的 `bookSourceName` /
/// `searchUrl` / `ruleSearch.*` 这一套字段映射到本模型，并**保留原始 JSON**
/// 到 [raw]。为什么留 raw：legado 的规则表达式比本模型字段多得多
/// （`{{}}` 模板、`@css:`/`@json:`/`@XPath:` 前缀、`&&`/`||` 组合、
/// `##正则##替换` 三件套……），R1 不打算把它们拆成结构体 —— **R2 才用它**，
/// 直接把原始规则字符串交给规则引擎跑，能少掉一整层有损映射。
library;

/// 一个书源（站点）的完整定义。
///
/// 不可变 + [toJson] 往返：[BookSource.fromJson] 与 [BookSource.toJson]
/// 必须互为逆运算（[raw] 也一起存）。
class BookSource {
  /// 结构版本号：留给将来字段语义变化时做迁移（默认 1）。
  final int schemaVersion;

  /// 书源名（必填，唯一键，大小写不敏感）。
  final String name;

  /// 书源版本号（站点自己的版本串，仅展示用；默认空串）。
  final String version;

  /// 作者 / 维护者（默认空串）。
  final String author;

  /// 站点根地址（必填，例如 `https://www.example.com`）。
  final String baseUrl;

  /// 网页编码（默认 `utf-8`，可选 `gbk` —— 老站点还有 GBK）。
  final String charset;

  /// 是否启用（停用的源不参与搜索，但配置保留）。
  final bool enabled;

  /// 附加请求头（默认空表；常用于 Referer / User-Agent）。
  final Map<String, String> headers;

  /// 同一站点两次请求的最小间隔（毫秒，默认 0 = 不限速）。
  ///
  /// 为什么放在源上而不是全局：不同站点的容忍度差很远，一个硬编码的全局值
  /// 要么把宽容站点拖慢，要么把敏感站点打出 403。
  final int requestIntervalMs;

  /// 搜索规则。
  final SearchRule search;

  /// 详情页规则（可缺省：有些站点搜索结果里就给全了）。
  final DetailRule? detail;

  /// 目录（章节列表）规则。
  final TocRule toc;

  /// 正文规则。
  final ContentRule content;

  /// legado 原始 JSON（非 legado 导入的源为 null）。
  ///
  /// **R2 才用它**：legado 的规则表达式（`@css:` 前缀、`{{}}` 模板、
  /// `##正则##替换`）远超本模型的字段粒度，R1 只做有损的结构化映射用于展示，
  /// 真正执行时让规则引擎直接吃这份原始 JSON。
  final Map<String, dynamic>? raw;

  const BookSource({
    this.schemaVersion = 1,
    required this.name,
    this.version = '',
    this.author = '',
    required this.baseUrl,
    this.charset = 'utf-8',
    this.enabled = true,
    this.headers = const {},
    this.requestIntervalMs = 0,
    required this.search,
    this.detail,
    required this.toc,
    required this.content,
    this.raw,
  });

  /// 唯一键（名字小写）：同名书源比大小写不敏感，导入去重与存储合并都用它。
  String get key => name.toLowerCase();

  /// 从存储 / 导入的 JSON 解析。缺字段一律走默认值，**不抛异常**。
  ///
  /// 之所以宽容：书源是用户从网上抄来的手写 JSON，少一个 `"enabled"` 不该
  /// 让整份导入失败 —— 能用就先能用，管理页会把实际生效的值展示出来。
  factory BookSource.fromJson(Map<String, dynamic> json) {
    return BookSource(
      schemaVersion: _asInt(json['schemaVersion'], 1),
      name: _asString(json['name']),
      version: _asString(json['version']),
      author: _asString(json['author']),
      baseUrl: _asString(json['baseUrl']),
      charset: _asString(json['charset'], 'utf-8'),
      enabled: _asBool(json['enabled'], true),
      headers: _asStringMap(json['headers']),
      requestIntervalMs: _asInt(json['requestIntervalMs'], 0),
      search: SearchRule.fromJson(_asMap(json['search'])),
      detail: json['detail'] == null
          ? null
          : DetailRule.fromJson(_asMap(json['detail'])),
      toc: TocRule.fromJson(_asMap(json['toc'])),
      content: ContentRule.fromJson(_asMap(json['content'])),
      raw: json['raw'] == null ? null : _asMap(json['raw']),
    );
  }

  /// 回写 JSON：字段一个不少，保证「导入 → 存储 → 再导出」不丢信息。
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'name': name,
        'version': version,
        'author': author,
        'baseUrl': baseUrl,
        'charset': charset,
        'enabled': enabled,
        'headers': headers,
        'requestIntervalMs': requestIntervalMs,
        'search': search.toJson(),
        if (detail != null) 'detail': detail!.toJson(),
        'toc': toc.toJson(),
        'content': content.toJson(),
        // raw 只在真的有值时写出：普通源不必在存储里多一层 null
        if (raw != null) 'raw': raw,
      };

  /// 复制并改动少数字段（管理页切换启用开关时用，避免手写整份构造）。
  BookSource copyWith({bool? enabled}) => BookSource(
        schemaVersion: schemaVersion,
        name: name,
        version: version,
        author: author,
        baseUrl: baseUrl,
        charset: charset,
        enabled: enabled ?? this.enabled,
        headers: headers,
        requestIntervalMs: requestIntervalMs,
        search: search,
        detail: detail,
        toc: toc,
        content: content,
        raw: raw,
      );

  /// legado（开源阅读）书源 JSON → 本模型；认不出来（缺 name / baseUrl）返回 null。
  ///
  /// 映射表（**只取能一对一表达的部分**，其余留在 [raw] 给 R2）：
  /// - `bookSourceName` → [name]、`bookSourceUrl` → [baseUrl]
  ///   （`bookSourceGroup` / `bookSourceType` 等展示性字段忽略）
  /// - `searchUrl` → [SearchRule.url]，`ruleSearch.bookList/name/author/
  ///   coverUrl/bookUrl/intro/lastChapter` → [SearchRule] 对应字段
  /// - `ruleBookInfo.name/author/coverUrl/intro/wordCount/kind` → [DetailRule]；
  ///   `ruleBookInfo.tocUrl` → [TocRule.url]（目录页地址）。
  ///   `lastChapter` 在 legado 属于详情规则，本模型放在搜索规则里（搜索结果
  ///   就能显示最后一章），所以两边都读一次、谁有值用谁；
  ///   `canReName` / `canReName` 这类开关、`init` / `bookUrlPattern` 这类
  ///   正则留给 [raw]，本模型没有对应字段。
  /// - `ruleToc.chapterList/chapterName/chapterUrl/nextTocUrl` → [TocRule]
  /// - `ruleContent.content/nextContentUrl/title` → [ContentRule]
  ///
  /// 注意 legado 的规则串可能带 `@css:` / `@json:` / `##正则##替换` /
  /// `{{}}` 模板，这里**原样搬运**：R1 只做展示，R2 的规则引擎认得这些前缀。
  static BookSource? fromLegado(Map<String, dynamic> json) {
    final name = _asString(json['bookSourceName']);
    final baseUrl = _asString(json['bookSourceUrl']);
    if (name.isEmpty || baseUrl.isEmpty) return null;

    final ruleSearch = _asMap(json['ruleSearch']);
    final ruleBookInfo = _asMap(json['ruleBookInfo']);
    final ruleToc = _asMap(json['ruleToc']);
    final ruleContent = _asMap(json['ruleContent']);

    // legado 里「最新章节」在详情规则下；本模型放在搜索规则里（搜索结果就能
    // 显示最后一章），两边都读一次，谁有值用谁。
    final lastChapter = _firstNonEmpty([
      _asString(ruleSearch['lastChapter']),
      _asString(ruleBookInfo['lastChapter']),
    ]);

    final detailName = _asString(ruleBookInfo['name']);
    final detailAuthor = _asString(ruleBookInfo['author']);
    final detailCover = _asString(ruleBookInfo['coverUrl']);
    final detailIntro = _asString(ruleBookInfo['intro']);
    final wordCount = _asString(ruleBookInfo['wordCount']);
    final hasDetail = [
      detailName,
      detailAuthor,
      detailCover,
      detailIntro,
      wordCount,
      _asString(ruleBookInfo['kind']),
      _asString(ruleBookInfo['lastChapter']),
    ].any((s) => s.isNotEmpty);

    return BookSource(
      // legado 没有结构版本概念，本项目一律从 1 起
      schemaVersion: 1,
      name: name,
      version: _asString(json['bookSourceVersion']),
      // legado 的 bookSourceGroup 是分组（「精品」「有声」），不是作者；
      // 本模型没有分组字段，宁可留空也不把分组塞进 author 造成误解。
      author: '',
      baseUrl: baseUrl,
      charset: _asString(json['bookSourceCharset'], 'utf-8'),
      enabled: _asBool(json['enabled'], true),
      headers: _asStringMap(json['header']),
      // legado 的 respondTime 是上次响应耗时（毫秒），**不是**限速配置，
      // 别把它当 requestIntervalMs 用（那样会把一个慢站永久限速）。
      requestIntervalMs: 0,
      search: SearchRule(
        url: _asString(json['searchUrl']),
        method: 'GET',
        bodyType: 'none',
        list: _asString(ruleSearch['bookList']),
        name: _asString(ruleSearch['name']),
        author: _asString(ruleSearch['author']),
        cover: _asString(ruleSearch['coverUrl']),
        intro: _asString(ruleSearch['intro']),
        detailUrl: _asString(ruleSearch['bookUrl']),
        lastChapter: lastChapter,
      ),
      detail: hasDetail
          ? DetailRule(
              // legado 的详情页地址就是搜索结果里的 bookUrl（没有单独规则键），
              // 留 null 表示「用 search.detailUrl 跳过去」
              url: null,
              name: detailName,
              author: detailAuthor,
              cover: detailCover,
              intro: detailIntro,
              // legado 的「连载/完结」没有固定规则键（各家站点自己写），
              // 这里不猜，留 null 表示本模型没拿到 —— 猜错比空着更糟
              status: null,
              wordCount: wordCount,
              category: _asString(ruleBookInfo['kind']),
            )
          : null,
      toc: TocRule(
        url: _asString(ruleBookInfo['tocUrl']),
        pages: _asString(ruleToc['nextTocUrl']),
        list: _asString(ruleToc['chapterList']),
        name: _asString(ruleToc['chapterName']),
        urlSel: _asString(ruleToc['chapterUrl']),
        // legado 的「倒序」是目录排序开关，字段名 chapterList 侧无对应；
        // 默认正序，用户可在本模型里改。
        reversed: false,
        maxPages: 1,
      ),
      content: ContentRule(
        // 正文页地址 = 目录里拿到的章节链接，legado 没有单独的规则键
        url: null,
        title: _asString(ruleContent['title']),
        nextPage: _asString(ruleContent['nextContentUrl']),
        text: _asString(ruleContent['content']),
        // legado 的「排除节点 / 正则替换」都写在 content 规则串里（##正则##替换），
        // 不拆成结构化字段；R2 直接吃 raw 里的原始串
        remove: const [],
        replace: const [],
        maxPages: 1,
        paragraphBreak: 'br',
      ),
      raw: Map<String, dynamic>.from(json),
    );
  }

  /// 判断一份 JSON 是不是 legado 格式（有 `bookSourceName` 或 `bookSourceUrl`）。
  static bool looksLikeLegado(Map<String, dynamic> json) =>
      json.containsKey('bookSourceName') || json.containsKey('bookSourceUrl');

  @override
  String toString() => 'BookSource($name, $baseUrl, enabled=$enabled)';
}

/// 搜索规则：搜索结果列表页怎么抓。
class SearchRule {
  /// 搜索地址（可含 `{{key}}` / `%s` 之类的占位符，R2 负责替换）。
  final String url;
  final String method;

  /// 请求体类型（`none` / `form` / `json`；本模型只声明，R2 才发请求）。
  final String bodyType;

  /// 结果列表的选择器 / JSON 路径。
  final String list;
  final String name;
  final String author;
  final String cover;
  final String intro;
  final String detailUrl;

  /// 最新章节（搜索结果里显示的那一行）。
  final String lastChapter;

  /// POST 时的请求体模板（GET 时为 null）。
  final Map<String, dynamic>? body;

  const SearchRule({
    this.url = '',
    this.method = 'GET',
    this.bodyType = 'none',
    this.list = '',
    this.name = '',
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.detailUrl = '',
    this.lastChapter = '',
    this.body,
  });

  factory SearchRule.fromJson(Map<String, dynamic> json) => SearchRule(
        url: _asString(json['url']),
        method: _asString(json['method'], 'GET'),
        bodyType: _asString(json['bodyType'], 'none'),
        list: _asString(json['list']),
        name: _asString(json['name']),
        author: _asString(json['author']),
        cover: _asString(json['cover']),
        intro: _asString(json['intro']),
        detailUrl: _asString(json['detailUrl']),
        lastChapter: _asString(json['lastChapter']),
        body: json['body'] == null ? null : _asMap(json['body']),
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'method': method,
        'bodyType': bodyType,
        'list': list,
        'name': name,
        'author': author,
        'cover': cover,
        'intro': intro,
        'detailUrl': detailUrl,
        'lastChapter': lastChapter,
        if (body != null) 'body': body,
      };
}

/// 详情页规则：书名 / 作者 / 封面 / 简介 / 状态 / 字数 / 分类。
class DetailRule {
  final String? url;
  final String? name;
  final String? author;
  final String? cover;
  final String? intro;
  final String? status;
  final String? wordCount;
  final String? category;

  const DetailRule({
    this.url,
    this.name,
    this.author,
    this.cover,
    this.intro,
    this.status,
    this.wordCount,
    this.category,
  });

  factory DetailRule.fromJson(Map<String, dynamic> json) => DetailRule(
        url: json['url'] == null ? null : _asString(json['url']),
        name: json['name'] == null ? null : _asString(json['name']),
        author: json['author'] == null ? null : _asString(json['author']),
        cover: json['cover'] == null ? null : _asString(json['cover']),
        intro: json['intro'] == null ? null : _asString(json['intro']),
        status: json['status'] == null ? null : _asString(json['status']),
        wordCount:
            json['wordCount'] == null ? null : _asString(json['wordCount']),
        category: json['category'] == null ? null : _asString(json['category']),
      );

  /// 回写时**保留 null 与空串的区别**：null = 该字段本模型没定义，空串 =
  /// 定义了但规则为空（R2 要区分「不抓」与「抓不到」）。
  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (name != null) 'name': name,
        if (author != null) 'author': author,
        if (cover != null) 'cover': cover,
        if (intro != null) 'intro': intro,
        if (status != null) 'status': status,
        if (wordCount != null) 'wordCount': wordCount,
        if (category != null) 'category': category,
      };
}

/// 目录（章节列表）规则。
class TocRule {
  /// 目录页地址（空 = 用详情页地址）。
  final String? url;

  /// 分页地址规则（下一页目录）。
  final String? pages;

  /// 章节列表选择器。
  final String list;
  final String name;

  /// 章节链接选择器（相对 baseUrl 或详情页）。
  final String urlSel;

  /// 分卷规则（可缺省）。
  final VolumeRule? volume;

  /// 目录是否倒序（站点从新到旧时打开这个，阅读顺序才正）。
  final bool reversed;

  /// 目录最多翻几页（防止「下一页」永远抓不完）。
  final int maxPages;

  const TocRule({
    this.url,
    this.pages,
    this.list = '',
    this.name = '',
    this.urlSel = '',
    this.volume,
    this.reversed = false,
    this.maxPages = 1,
  });

  factory TocRule.fromJson(Map<String, dynamic> json) => TocRule(
        url: json['url'] == null ? null : _asString(json['url']),
        pages: json['pages'] == null ? null : _asString(json['pages']),
        list: _asString(json['list']),
        name: _asString(json['name']),
        urlSel: _asString(json['urlSel']),
        volume: json['volume'] == null
            ? null
            : VolumeRule.fromJson(_asMap(json['volume'])),
        reversed: _asBool(json['reversed'], false),
        maxPages: _asInt(json['maxPages'], 1),
      );

  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (pages != null) 'pages': pages,
        'list': list,
        'name': name,
        'urlSel': urlSel,
        if (volume != null) 'volume': volume!.toJson(),
        'reversed': reversed,
        'maxPages': maxPages,
      };
}

/// 分卷（目录里再分「第一卷 / 第二卷」）。
class VolumeRule {
  final String list;
  final String name;
  final String chapters;

  const VolumeRule({this.list = '', this.name = '', this.chapters = ''});

  factory VolumeRule.fromJson(Map<String, dynamic> json) => VolumeRule(
        list: _asString(json['list']),
        name: _asString(json['name']),
        chapters: _asString(json['chapters']),
      );

  Map<String, dynamic> toJson() => {
        'list': list,
        'name': name,
        'chapters': chapters,
      };
}

/// 正文规则。
class ContentRule {
  final String? url;
  final String? title;

  /// 下一页正文（分页漫画 / 长文）。
  final String? nextPage;

  /// 正文选择器。
  final String text;

  /// 需要剔除的节点选择器（广告 / 推荐位）。
  final List<String> remove;

  /// 正则替换（清洗乱码、去掉站点水印）。
  final List<ReplaceRule> replace;

  /// 正文最多翻几页。
  final int maxPages;

  /// 段落分隔用的标签（默认 `br`；有的站点用 `p`）。
  final String paragraphBreak;

  const ContentRule({
    this.url,
    this.title,
    this.nextPage,
    this.text = '',
    this.remove = const [],
    this.replace = const [],
    this.maxPages = 1,
    this.paragraphBreak = 'br',
  });

  factory ContentRule.fromJson(Map<String, dynamic> json) => ContentRule(
        url: json['url'] == null ? null : _asString(json['url']),
        title: json['title'] == null ? null : _asString(json['title']),
        nextPage: json['nextPage'] == null ? null : _asString(json['nextPage']),
        text: _asString(json['text']),
        remove: _asStringList(json['remove']),
        replace: json['replace'] is List
            ? [
                for (final e in json['replace'] as List)
                  if (e is Map) ReplaceRule.fromJson(_asMap(e)),
              ]
            : const [],
        maxPages: _asInt(json['maxPages'], 1),
        paragraphBreak: _asString(json['paragraphBreak'], 'br'),
      );

  Map<String, dynamic> toJson() => {
        if (url != null) 'url': url,
        if (title != null) 'title': title,
        if (nextPage != null) 'nextPage': nextPage,
        'text': text,
        'remove': remove,
        'replace': [for (final r in replace) r.toJson()],
        'maxPages': maxPages,
        'paragraphBreak': paragraphBreak,
      };
}

/// 一条正则替换。
///
/// 字段名为什么叫 [withText]：JSON 里叫 `"with"`，但 `with` 是 Dart 的保留字
/// （混入语法），**不能**当标识符。所以 Dart 侧叫 [withText]，读写 JSON 时
/// 映射回 `"with"` —— 往返仍然逐键等价。
class ReplaceRule {
  final String regex;
  final String withText;

  const ReplaceRule({this.regex = '', this.withText = ''});

  factory ReplaceRule.fromJson(Map<String, dynamic> json) => ReplaceRule(
        regex: _asString(json['regex']),
        withText: _asString(json['with']),
      );

  Map<String, dynamic> toJson() => {'regex': regex, 'with': withText};
}

// ==================== 宽容的类型转换（内部用） ====================

String _asString(Object? v, [String fallback = '']) {
  if (v == null) return fallback;
  if (v is String) return v;
  return v.toString();
}

int _asInt(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? fallback;
  return fallback;
}

/// 布尔宽容：JSON 里 `true` / `"true"` / `1` 都算真（手写 JSON 常见）。
bool _asBool(Object? v, bool fallback) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return fallback;
}

Map<String, dynamic> _asMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return {for (final e in v.entries) e.key.toString(): e.value};
  return const {};
}

Map<String, String> _asStringMap(Object? v) {
  if (v is! Map) return const {};
  final out = <String, String>{};
  for (final e in v.entries) {
    if (e.value == null) continue;
    out[e.key.toString()] = e.value.toString();
  }
  return out;
}

List<String> _asStringList(Object? v) {
  if (v is! List) return const [];
  return [for (final e in v) if (e != null) e.toString()];
}

String _firstNonEmpty(List<String> candidates) {
  for (final s in candidates) {
    if (s.isNotEmpty) return s;
  }
  return '';
}
