/// 内置书源（原「示例书源」，F2 起扩成一份精选清单）。
///
/// ## 为什么要有它
/// 用户从索引里导进来的几千个源大多已经失效，或者依赖 `@js`（本版跑不了）。
/// 结果就是「一个能搜到书的源都没有」—— 用户分不清是自己不会用，还是这功能
/// 废了。内置几条**真能用**的源，一键就能试出整条链路（搜索 → 详情 → 目录 →
/// 正文），也给规则引擎一个能端到端验证的靶子（单测只能验证生成的 JS 文本，
/// 验证不了 WebView 里真实跑出来的结果）。
///
/// ## 收录标准（三条都要满足）
/// 1. **合法**：公共领域 / 开放许可的站点，不接盗版站与聚合爬站；
/// 2. **不用 JS**：服务端渲染的 HTML，CSS 选择器够用（本版跑不了 `@js`）；
/// 3. **选择器经过实测**：每条规则都先 `curl` 抓真实页面、再对着 HTML 写，
///    不是照印象编的。站点改版后选择器会失效 —— **改之前必须重新抓一遍页面**。
///
/// ## 当前清单（2 条）
/// | 源 | 站点 | 覆盖 |
/// |---|---|---|
/// | 维基文库（中文经典） | `zh.wikisource.org` | 四大名著、史书、诸子、诗词等中文古籍 |
/// | 标准电子书（示例） | `standardebooks.org` | 公共领域英文经典（校对过的排版） |
///
/// ### 实测证据（2026-11-23，桌面 UA，`curl` 抓真页 + 选择器点数）
/// **维基文库**
/// - 搜索页 `…/w/index.php?search=三国演义&ns0=1&fulltext=1`：`ul.mw-search-results >
///   li.mw-search-result` 命中 **20** 条（一页 20 条），`div.mw-search-result-heading a`
///   20 条，正文摘要 `div.searchresult` 20 条；加上 `:not([title*="/"])` 过滤掉
///   章节子页面后仍是 20 条（这一页没有子页面结果）。
/// - 图书页 `…/wiki/三國演義`：`#firstHeading` = 「三國演義」；
///   `a[href^="/wiki/Author:"]` 命中 1 条（羅貫中）；
///   `ul li a[title*="/"]` 命中 **123** 条（序 / 凡例 / 第一回…第一百二十回）。
///   同一条规则在 紅樓夢 命中 120 条、西遊記 100 条、論語 23 条。
/// - 章节页 `…/wiki/三國演義/第001回`：`div.mw-content-ltr.mw-parser-output` 命中
///   1 个（唯一的正文容器；**不能只写 `.mw-parser-output`**，页面顶部还有一个小
///   指示器 div 用了同一个 class，`querySelector` 会先命中那个空壳）；
///   待删节点 `.ws-header` ×2、`.ws-footer` ×2。
///   紅樓夢 章节页没有 ws-header/ws-footer，但有 `sup.reference` ×8、
///   `ol.references` ×1、`div.licenseContainer` ×1、`div.licensetpl` ×1。
/// - **注意**：`zh.wikisource.org` 的证书在本机 `curl`（schannel）里报
///   `SEC_E_UNTRUSTED_ROOT`，只能 `-k` 抓；部分书名（如「史記」）会被中间设备
///   直接 403。这两件事都跟 App 无关（Android 走系统 CA），但也说明这站的可用性
///   会随网络环境变化 —— 所以才需要「书源可用性检测」那套东西。
///
/// **标准电子书**
/// - 搜索页 `…/ebooks?query=alice`：`ol.ebooks-list > li` 命中 **12** 条；
///   书名 `p:not(.author) a span[property="schema:name"]`、作者
///   `p.author span[property="schema:name"]` 各 12 条。
/// - 详情页：`h1[property="schema:name"]` ×1、`a[property="schema:author"]
///   span[property="schema:name"]` ×1、`meta[property="schema:image"]` ×1、
///   `div[property="schema:description"] p` ×2、`meta[property="schema:wordCount"]`
///   = 26738、`ul.tags li a` = Children’s / Fiction。
/// - 目录页（详情页地址 + `/text`）：`nav#toc a[href*="chapter"]` 命中 **12** 条。
/// - 章节页（`…/text/chapter-1`）：`main section` ×1，`main section > hgroup:first-child`
///   ×1（章首标题块，要删）。
///
/// ### 评估过但**没有**收进来的
/// - **Project Gutenberg**（`www.gutenberg.org`）：公共领域首选，但实测整站返回
///   **HTTP 503**（带 `Retry-After` 的维护页），搜索/详情/正文全部不可访问。
///   恢复后可以按同一套位置补一条，现在写进去只会给用户一个「搜不到书」的源。
/// - **en.wikisource.org**：结构同中文站，版本页（如 `Pride and Prejudice (1817)`）
///   的目录用同一条 `ul li a[title*="/"]` 能命中 61 条；但每章页顶部有一大段导航
///   （← 上级 / sister projects / Listen to this text / 页码），要额外写几条清洗
///   规则，而且英文已经有 Standard Ebooks，暂不重复收录。
/// - **ctext.org**（中国哲学书电子化计划）：搜索页返回 Cloudflare Turnstile
///   验证页（HTTP 200 但正文只有「Checking the security of your connection…」），
///   本版拿不到结果。
/// - **Z-Library / 各类「笔趣阁」聚合站**：盗版，按项目边界明确不接。
library;

import '../../models/book_source.dart';

/// 内置书源清单（书源管理页「添加内置书源」一键导入的就是这几条）。
///
/// 常量名沿用 `kExampleBookSources`：页面与测试都按这个名字引用，改名的收益
/// 只是好看一点，代价是几十处引用跟着动 —— 语义上它现在就是「内置书源」。
const List<BookSource> kExampleBookSources = [
  // ==================== 中文经典：维基文库 ====================
  BookSource(
    schemaVersion: 1,
    name: '维基文库（中文经典）',
    version: '2026-11',
    author: 'Wikimedia',
    baseUrl: 'https://zh.wikisource.org',
    charset: 'utf-8',
    enabled: true,
    search: SearchRule(
      // 必须带 `fulltext=1`：不带的话，关键词恰好等于某个页面标题时 MediaWiki
      // 会直接 302 跳到那个页面，我们拿到的是图书页而不是搜索结果列表，
      // 列表选择器一条都命不中（表现就是「搜得到却显示 0 条」）。
      // `ns0=1` 限定正文命名空间，排掉 Author: / Portal: / Category: 那些页面。
      url: '/w/index.php?search={{key}}&ns0=1&fulltext=1',
      // 结果列表：<ul class="mw-search-results"><li class="mw-search-result …">
      list: '@css:ul.mw-search-results > li.mw-search-result',
      // 结果里既有「图书页」（三國演義）也有「章节页」（三國演義/第001回）。
      // 章节页点进去没有目录（它本身就是一章），所以用 `:not([title*="/"])`
      // 只留图书页 —— 维基文库的子页面标题里一定带 `/`。
      name: '@css:div.mw-search-result-heading a:not([title*="/"])',
      // 搜索摘要（高亮词包在 span 里，取文本即可）
      intro: '@css:div.searchresult',
      detailUrl: '@css:div.mw-search-result-heading a:not([title*="/"])@href',
      // 搜索结果里没有作者/封面：留空 = 这两列不抓（不是规则写坏）。
      author: '',
      cover: '',
    ),
    detail: DetailRule(
      // 页面大标题：<h1 id="firstHeading">三國演義</h1>
      name: '@css:#firstHeading',
      // 作者在页首信息框里，链到 Author: 命名空间
      // （<a href="/wiki/Author:羅貫中">羅貫中</a>）；一部书有多个作者时取第一个。
      author: '@css:a[href^="/wiki/Author:"]',
      // 简介 / 分类各家写法不一（有的在表格里、有的没有），不猜 —— 留空。
    ),
    toc: TocRule(
      // 目录就在图书页自己身上（不用另抓一页）。写 `@detailUrl` 而不是留空，
      // 是为了把「目录页 = 详情页」这件事显式表达出来。
      url: '@detailUrl',
      // 图书页的目录是 <ul><li><a title="三國演義/第001回">第一回</a>
      // 子页面链接的 title 一定含 `/`，用它把「相关导览 / 姊妹项目 / 分类」
      // 那些站内链接排除掉（实测：三國演義 123、紅樓夢 120、西遊記 100、論語 23）。
      list: '@css:ul li a[title*="/"]',
      name: '@text',
      urlSel: '@href',
    ),
    content: ContentRule(
      // 正文容器：<div id="mw-content-text"><div class="mw-content-ltr
      // mw-parser-output">…</div></div>。
      // **必须带上 `mw-content-ltr`**：页面顶部还有一个只带 `mw-parser-output`
      // 的指示器 div（正文质量图标），只用 class 名会先命中那个空壳。
      text: '@css:div.mw-content-ltr.mw-parser-output',
      remove: [
        // 三國演義 这类套了「古籍」模板的章节页：页首导航/书名条 + 页尾翻页条
        '.ws-header',
        '.ws-footer',
        // 紅樓夢 这类直接排版的章节页：脚注角标 [1] 与脚注列表
        'sup.reference',
        'ol.references',
        // 页尾的版权横幅（「此清朝作品在全世界都属于公有领域…」）
        'div.licenseContainer',
        'div.licensetpl',
      ],
      // 正文逐段 <p>；`br` 策略会把诗行里的软换行也当段落，所以用 block。
      paragraphBreak: 'block',
    ),
  ),

  // ==================== 英文经典：Standard Ebooks ====================
  BookSource(
    schemaVersion: 1,
    name: '标准电子书（示例）',
    version: '2026-11',
    author: 'Standard Ebooks',
    baseUrl: 'https://standardebooks.org',
    charset: 'utf-8',
    enabled: true,
    search: SearchRule(
      // 站点搜索是 query 参数：/ebooks?query=alice
      url: '/ebooks?query={{key}}',
      // 结果列表：<ol class="ebooks-list grid"> 下的每个 <li>（一页 12 条）
      list: '@css:ol.ebooks-list > li',
      // 书名在 li 里第一个 <p> 的 <span property="schema:name"> 上；
      // 作者那个 <p> 带 class="author"，用 :not() 排掉，免得两个字段互相串。
      name: '@css:p:not(.author) a span[property="schema:name"]',
      author: '@css:p.author span[property="schema:name"]',
      // 封面是相对路径（/images/covers/…），引擎会按文档 base 转绝对
      cover: '@css:div.thumbnail-container img@src',
      detailUrl: '@css:p:not(.author) a@href',
    ),
    detail: DetailRule(
      name: '@css:h1[property="schema:name"]',
      author: '@css:a[property="schema:author"] span[property="schema:name"]',
      // 取 meta 的 content：站点在这里给的是**绝对**地址，省一次拼路径。
      // 注意取值后缀要写 `@attr:content` —— 裸 `@content` 不在后缀白名单里，
      // 会被当成 CSS 选择器的一部分，最后静默取不到值。
      cover: '@css:meta[property="schema:image"]@attr:content',
      intro: '@css:div[property="schema:description"] p',
      // wordCount 是纯数字（26738），展示层自行加单位
      wordCount: '@css:meta[property="schema:wordCount"]@attr:content',
      category: '@css:ul.tags li a',
    ),
    toc: TocRule(
      // 详情页是 /ebooks/<作者>/<书名>[/<译者>]，目录页是在同一地址后接 /text。
      // 不同书多不多一段译者由站点决定，写死路径会漏，必须用模板拼接。
      url: '@detailUrl/text',
      // 目录页里 nav#toc 下所有指向正文章节的链接。用 href*=chapter 过滤
      // 掉 titlepage / imprint / colophon 这些前后附件 —— 它们点进去没有正文。
      // Alice 那种把章节再套一层 <ol> 的书，这个选择器同样命中（后代选择器）。
      list: '@css:nav#toc a[href*="chapter"]',
      // 链接文字就是章名（如 “I: Down the Rabbit-Hole”）
      name: '@text',
      urlSel: '@href',
    ),
    content: ContentRule(
      // 章节页只有一个正文 section：<main><section id="chapter-N">…
      text: '@css:main section',
      // 章首的标题块要去掉：阅读页自己会显示章名，正文里再重复一遍很吵，
      // 而且「I」这种罗马数字单独占一行看起来像乱码。
      // 站点有两种写法，必须都覆盖（实测：Alice 用 hgroup，The Time Machine
      // 直接把 <h2> 放在 section 下）。用 :first-child 限定在章首，
      // 免得把正文里可能出现的 <h2>（分节标题）一起删掉。
      remove: [
        'main section > hgroup:first-child',
        'main section > h2:first-child',
      ],
      // 正文是逐段 <p>，不是 <br> 分段 —— 用 block 才不会被压成一坨
      paragraphBreak: 'block',
    ),
  ),
];
