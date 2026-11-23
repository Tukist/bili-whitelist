/// 内置示例书源（R3 收尾新增）。
///
/// ## 为什么要有它
/// 用户在「书源管理」里第一眼看到的是空列表，而书源 JSON 又不适合手写。
/// 内置一条**真能用**的源，既能让人一键试出整条链路（搜索 → 详情 → 目录 →
/// 正文），也让规则引擎有一个可端到端验证的靶子 —— 单测只能验证生成的 JS
/// 文本，验证不了 WebView 里真实跑出来的结果。
///
/// ## 为什么选 Standard Ebooks 而不是古登堡计划
/// 原本打算用 Project Gutenberg（`https://www.gutenberg.org`）：公共领域、
/// 无 JS、HTML 简单。但落地那天整站返回 **HTTP 503**（维护页带
/// `Retry-After: 21600`，即六小时），搜索页、详情页、正文页全部不可访问。
/// 书源里最忌讳的就是「凭记忆写选择器」——站点结构一旦对不上，用户看到的是
/// 「搜不到书」，而不是「示例源坏了」。所以换成同样满足条件的
/// **Standard Ebooks**（`https://standardebooks.org`）：
/// - 公共领域（美国版权到期的作品），站点自己提供在线阅读；
/// - 服务端渲染的纯 HTML，**不需要 JS**，规则用 CSS 选择器就够；
/// - 有稳定的 `/text` 目录页与 `/text/chapter-N` 章节页，目录/正文能分开取；
/// - HTML 是语义化的（`schema.org` 微数据），选择器写起来不依赖易变的
///   `div` 层级。
///
/// 下面每一条选择器都是**先抓真实页面、再对着 HTML 写**的，不是照着印象编的
/// （验证过程见提交说明）。改站点结构时照着同一套位置重新抓一遍即可。
///
/// ## 选择器一览（对应关系写在每条注释里）
/// | 位置 | 真实 HTML |
/// |---|---|
/// | 搜索结果项 | `<ol class="ebooks-list grid"><li typeof="schema:Book">` |
/// | 书名 | `<p><a …><span property="schema:name">书名</span></a></p>` |
/// | 作者 | `<p class="author"><a …><span property="schema:name">作者</span></a></p>` |
/// | 封面 | `<div class="thumbnail-container">…<img src="/images/covers/…jpg">` |
/// | 详情书名 | `<h1 property="schema:name">` |
/// | 详情作者 | `<a property="schema:author">…<span property="schema:name">` |
/// | 详情封面 | `<meta property="schema:image" content="…/cover.jpg">` |
/// | 简介 | `<div property="schema:description"><p>…</p>` |
/// | 字数 | `<meta property="schema:wordCount" content="26738">` |
/// | 分类 | `<ul class="tags"><li><a>Children’s</a>` |
/// | 目录页 | 详情页地址后加 `/text`（模板 `@detailUrl/text`） |
/// | 目录章节 | `<nav id="toc"><a href="text/chapter-1">I: Down the Rabbit-Hole</a>` |
/// | 正文 | `<main><section id="chapter-1">…<p>…</p></section></main>` |
library;

import '../../models/book_source.dart';

/// 内置示例书源（可一键添加到书源管理页）。
///
/// 只有一条，但刻意做成 `const List`：将来加第二条（比如古登堡计划恢复后
/// 补上）时，UI 与测试都不用改。
const List<BookSource> kExampleBookSources = [
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
