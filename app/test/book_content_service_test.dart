// 正文服务测试（R3；v2.78.0 加「正文规则是静态 JS」）。
//
// 两件事分开验：
// 1. 段落还原 / 正则替换是**纯函数**，逐条钉死（br / block / none 三种策略、
//    换行压缩、行 trim、`$1` 分组替换、替换顺序）；
// 2. 编排层（抓取 → 删节点 → 取正文 → 替换 → 还原 → 分页）用假引擎跑，
//    验「第 2 页失败只算 partial、不丢第 1 页」与「第 1 页失败要抛给 UI」。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

BookSource _source({ContentRule content = const ContentRule(text: '#content')}) =>
    BookSource(
      name: '源A',
      baseUrl: 'https://x.example',
      search: const SearchRule(url: '/s?q={{key}}', list: '.b'),
      toc: const TocRule(list: '.ch', name: '', urlSel: 'a@href'),
      content: content,
    );

void main() {
  group('restoreParagraphs', () {
    test('br：<br> 与块级结尾都变换行', () {
      final text = restoreParagraphs('<p>第一段<br>第二行</p><p>第二段</p>', 'br');
      expect(text, '第一段\n第二行\n第二段');
    });

    test('block：只认块级结尾，<br> 退化成空格', () {
      final text =
          restoreParagraphs('<p>第一段<br>第二行</p><p>第二段</p>', 'block');
      expect(text, '第一段 第二行\n第二段');
    });

    test('none：不补换行（只有 HTML 里原本的空白）', () {
      final text = restoreParagraphs('<p>第一段</p>\n<p>第二段</p>', 'none');
      expect(text, '第一段\n第二段');
      // <br> 在 none 下也只是空格，不会凭空多一段
      expect(restoreParagraphs('a<br>b', 'none'), 'a b');
    });

    test('连续换行压缩 + 每行 trim + 去空行 + 实体解码', () {
      final text = restoreParagraphs(
        '  &nbsp;第一行 &nbsp; <br><br><br>   第二行   \r\n\r\n\r\n 第三行  ',
        'br',
      );
      expect(text, '第一行\n第二行\n第三行');
    });

    test('脚本 / 样式整段丢掉', () {
      final text = restoreParagraphs(
        '<p>正文</p><script>var a = 1;</script><style>.x{}</style>',
        'br',
      );
      expect(text, '正文');
      expect(text.contains('var a'), isFalse);
    });
  });

  group('applyReplaces', () {
    test('按顺序执行，chain 记录每一步，最后一项是最终结果', () {
      final chain = applyReplaces('aaa', const [
        ReplaceRule(regex: 'a', withText: 'b'),
        ReplaceRule(regex: 'b', withText: 'c'),
      ]);
      expect(chain.length, 3); // 原文 + 两步
      expect(chain[0], 'aaa');
      expect(chain[1], 'bbb');
      expect(chain.last, 'ccc');
    });

    test('顺序反过来结果就不同（顺序有意义，不是集合）', () {
      final chain = applyReplaces('aaa', const [
        ReplaceRule(regex: 'b', withText: 'c'),
        ReplaceRule(regex: 'a', withText: 'b'),
      ]);
      expect(chain.last, 'bbb');
    });

    test(r'$1 分组替换', () {
      final chain = applyReplaces(
        '第12章 标题',
        const [ReplaceRule(regex: r'第(\d+)章', withText: r'Chapter $1')],
      );
      expect(chain.last, 'Chapter 12 标题');
    });

    test('坏正则跳过，不影响后续规则', () {
      final chain = applyReplaces('abc', const [
        ReplaceRule(regex: '(', withText: ''),
        ReplaceRule(regex: 'b', withText: 'B'),
      ]);
      expect(chain.last, 'aBc');
    });
  });

  group('loadContent', () {
    test('清洗顺序：先删节点、再取正文、替换后还原', () async {
      List<String>? capturedRemove;
      final engine = FakeRuleEngine(
        onFetch: (_) async => '<html>page</html>',
        onExtractHtml: (html, removes, selector) async {
          capturedRemove = removes;
          // 站点常见结构：正文里带 <br> 分行，后面跟着广告残留
          return '<p>第一段</p><br>第二行{水印}';
        },
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          remove: ['#ad', '.recommend'],
          replace: [ReplaceRule(regex: r'\{水印\}', withText: '')],
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(capturedRemove, ['#ad', '.recommend']);
      expect(result.title, '第1章');
      expect(result.body, '第一段\n第二行');
      expect(result.partial, isFalse);
      expect(result.pageCount, 1);
    });

    test('分页：第 2 页失败保留第 1 页并标 partial', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          if (url.contains('p=2')) {
            throw const RuleEngineException(RuleErrorKind.network, '第二页挂了');
          }
          return '<html>p1</html>';
        },
        onExtractHtml: (_, __, ___) async => '第一页内容',
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          nextPage: 'https://x.example/c?p={{page}}',
          maxPages: 3,
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(result.body, '第一页内容');
      expect(result.partial, isTrue);
      expect(result.warning, contains('第 2 页'));
    });

    test('分页模板没有页码 → 不会重复抓同一页', () async {
      var fetches = 0;
      final engine = FakeRuleEngine(
        onFetch: (_) async {
          fetches++;
          return '<html>p</html>';
        },
        onExtractHtml: (_, __, ___) async => '正文',
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          nextPage: 'https://x.example/c',
          maxPages: 3,
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(fetches, 1);
      expect(result.pageCount, 1);
      expect(result.partial, isFalse);
    });

    test('第一页就失败 → 抛 RuleEngineException（页面据此显示错误 + 重试）',
        () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async {
          throw const RuleEngineException(RuleErrorKind.network, '连不上站点');
        },
      );
      final source = _source();

      expect(
        BookContentService(engine: engine).loadContent(
          source: source,
          chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
        ),
        throwsA(isA<RuleEngineException>()),
      );
    });

    test('正文为空 → 抛错（不假装成功给出空页）', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async => '<html></html>',
        onExtractHtml: (_, __, ___) async => '   ',
      );
      final source = _source();
      expect(
        BookContentService(engine: engine).loadContent(
          source: source,
          chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
        ),
        throwsA(isA<RuleEngineException>()),
      );
    });
  });

  group('正文规则是静态 JS（I3b）', () {
    test('JS 正文规则交给引擎（连 base 选择器一起）', () async {
      SelectorValue? seen;
      final engine = FakeRuleEngine(
        onFetch: (_) async => '<html>page</html>',
        onExtractHtml: (html, removes, selector) async {
          seen = selector;
          return '正文第一段\n正文第二段';
        },
      );
      final source = _source(
        content: const ContentRule(
          text: r'#content@html@js:result.replace(/广告/g, "")',
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(seen!.kind, SelectorKind.js);
      expect(seen!.script, contains('replace'));
      expect(seen!.baseSelector!.query, '#content');
      expect(seen!.isStaticJsRunnable, isTrue);
      expect(result.body, '正文第一段\n正文第二段');
    });

    test('正文地址是 JS 模板 → 明确报不支持（不硬拼出一串脚本源码）', () async {
      final engine = FakeRuleEngine(onFetch: (_) async => '<html>p</html>');
      final source = _source(
        content: const ContentRule(
          text: '#content',
          url: r'@js:baseUrl + "/c/" + chapter.title',
        ),
      );
      expect(
        BookContentService(engine: engine).loadContent(
          source: source,
          chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
        ),
        throwsA(isA<RuleEngineException>()),
      );
    });

    test('分页地址是 JS 模板 → 只取第一页并说明', () async {
      var fetches = 0;
      final engine = FakeRuleEngine(
        onFetch: (_) async {
          fetches++;
          return '<html>p</html>';
        },
        onExtractHtml: (_, __, ___) async => '正文',
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          nextPage: r'@js:baseUrl + "/next"',
          maxPages: 3,
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(fetches, 1);
      expect(result.warning, contains('JS 模板'));
    });

    test('正文地址是 {{…}} 表达式模板 → 求值后真的去抓（I4）', () async {
      final urls = <String>[];
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          urls.add(url);
          return '<html>p</html>';
        },
        onExtractHtml: (_, __, ___) async => '正文',
        onEvalUrlJs: (script, bindings) async {
          expect(bindings['chapterTitle'], '第1章');
          return script == 'chapter.title' ? '第1章' : '/c';
        },
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          url: '/c/{{chapter.title}}.html',
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(result.body, '正文');
      expect(urls, hasLength(1));
      expect(urls.single, contains('/c/${Uri.encodeComponent('第1章')}.html'));
    });

    test('正文地址是 POST 源：正文页也用 POST + body 抓（I4）', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async => '<html>p</html>',
        onExtractHtml: (_, __, ___) async => '正文',
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          url: '/read,{"method":"POST","body":"c={{chapterUrl}}"}',
        ),
      );

      await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      final req = engine.fetchedRequests.single;
      expect(req.isPost, isTrue);
      expect(req.url, 'https://x.example/read');
      // `@chapterUrl` / `{{chapterUrl}}` 是**模型自己的**占位符，先替换
      expect(req.body, 'c=https://x.example/1');
    });

    test('分页模板里的页码表达式（{{page}}）照常翻页', () async {
      final urls = <String>[];
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          urls.add(url);
          return '<html>p</html>';
        },
        onExtractHtml: (_, __, ___) async => '正文',
      );
      final source = _source(
        content: const ContentRule(
          text: '#content',
          nextPage: '/p/{{page}}.html',
          maxPages: 3,
        ),
      );

      final result = await BookContentService(engine: engine).loadContent(
        source: source,
        chapter: const TocChapter(name: '第1章', url: 'https://x.example/1'),
      );

      expect(result.body, contains('正文'));
      expect(urls, [
        'https://x.example/1',
        'https://x.example/p/2.html',
        'https://x.example/p/3.html',
      ]);
    });
  });
}
