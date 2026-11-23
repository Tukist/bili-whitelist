// legado 兼容层测试（R2）：usesJs 判定 + URL 归一化。
//
// 这两件事都不是「锦上添花」：
// - usesJs 判错（把普通源判成 JS 源）会让**所有源**都搜不出东西；
// - normalizeUrl 判错会让源内去重失效（同一本书显示两遍）或让详情页跳不过去。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_rule/legado_compat.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

/// 造一个最小书源（规则串按需覆盖）。
BookSource _source({
  String baseUrl = 'https://a.example',
  String searchUrl = '/search?q={{key}}',
  String list = '@css:.book',
  String name = '@css:.title',
  String detailUrl = '@css:a@href',
  String? tocUrl,
  String contentText = '@css:.content',
  Map<String, dynamic>? raw,
}) =>
    BookSource(
      name: 's',
      baseUrl: baseUrl,
      search: SearchRule(
        url: searchUrl,
        list: list,
        name: name,
        detailUrl: detailUrl,
      ),
      toc: TocRule(url: tocUrl),
      content: ContentRule(text: contentText),
      raw: raw,
    );

void main() {
  group('legadoSelector', () {
    test('class. 简写转 CSS', () {
      final v = legadoSelector('class.book-item');
      expect(v.kind, SelectorKind.css);
      expect(v.query, '.book-item');
    });

    test('@css: / @XPath: 前缀去掉', () {
      expect(legadoSelector('@css:.a@href').query, '.a');
      expect(legadoSelector('@css:.a@href').attr, 'href');
      expect(legadoSelector('@XPath://div/a').kind, SelectorKind.xpath);
    });

    test('空规则仍是 none（不报错）', () {
      expect(legadoSelector(null).kind, SelectorKind.none);
      expect(legadoSelector('  ').kind, SelectorKind.none);
    });

    test('&& 组合运算符按「并列」解析（v2.77.0 设计契约变更）', () {
      // v2.76.0 及以前这里断言 unsupported（理由：当 CSS 硬跑会静默返回空）。
      // 用真实语料量过之后改成真支持：`&&` 出现在 622 个源（25.1%），
      // 语义在 legado 源码里是明确的「并列」——两支各自取值后按 \n 拼接。
      // 契约变更点：原来「判死」的源现在能跑，所以断言从 unsupported 改成
      // 「两支都在 concat 里」。仍然不支持的 `%%` 由 selector.dart 报出来。
      final v = legadoSelector('@css:div.book && @css:span.title');
      expect(v.kind, SelectorKind.css);
      expect(v.query, 'div.book');
      expect(v.concat.length, 1);
      expect(v.concat.single.kind, SelectorKind.css);
      expect(v.isRunnable, isTrue);
    });

    test('%% 仍然是「语法不支持」，且与「需要 JS」分开报', () {
      final v = legadoSelector('@css:div.book %% @css:span.title');
      expect(v.kind, SelectorKind.unsupported);
      expect(v.reason, kSelectorReasonInterleave);
      expect(v.needsJs, isFalse);
    });

    test('正则里的 && 不受影响', () {
      expect(legadoSelector(r'regex:a&&b').kind, SelectorKind.regex);
    });
  });

  group('usesJs', () {
    test('普通源（含 {{key}} / {{page}} 占位符）不需要 JS', () {
      final s = _source(tocUrl: '/toc?page={{page}}');
      expect(usesJs(s), isFalse);
    });

    test('选择器里写 <js> 判 JS', () {
      expect(usesJs(_source(name: '<js>java.getString("a")</js>')), isTrue);
    });

    test('@js: 判 JS', () {
      expect(usesJs(_source(contentText: '@js:result.replace("a","b")')), isTrue);
    });

    test('搜索地址里的非占位符 {{…}} 判 JS', () {
      expect(usesJs(_source(searchUrl: '/s?q={{book.name}}')), isTrue);
    });

    test('raw 里的 JS 规则也判得到（本模型没映射成字段的那些）', () {
      // 设计契约变更（I1）：这条原来用 checkKeyWord 断言「判 JS」。新口径下
      // checkKeyWord 属于**本版不执行**的字段（搜索接口根本不看它），所以
      // 有 JS 也不该把整源判死 —— 换成真的会执行的 bookList 来断言。
      final s = _source(raw: {
        'ruleSearch': {'bookList': '@js:java.getString("list")'},
      });
      expect(usesJs(s), isTrue);
      expect(jsUsageOf(s).executedFields, ['search.list']);
    });

    test('只在 checkKeyWord 里写 JS 不判死（本版不执行该字段）', () {
      final s = _source(raw: {
        'ruleSearch': {'checkKeyWord': '<js>x</js>'},
      });
      expect(usesJs(s), isFalse);
      final usage = jsUsageOf(s);
      expect(usage.executedJs, isFalse);
      expect(usage.unexecutedJs, isTrue);
      expect(usage.canRun, isTrue);
      expect(usage.executedFields, isEmpty);
    });

    test('发现页 / 登录页 / 初始化里的 JS 不影响搜索', () {
      final s = _source(raw: {
        'exploreUrl': '发现@js:java.ajax(...)',
        'loginUrl': 'https://a.example/login?<js>x</js>',
        'init': '@js:java.put("k","v")',
        'preUpdateJs': '@js:1',
        'ruleExplore': {'bookList': '@js:java.getString("list")'},
      });
      expect(usesJs(s), isFalse);
      expect(jsUsageOf(s).unexecutedJs, isTrue);
      // 这些脚本就算调了网络也不该出现在 blockedApis 里：我们不执行它们
      expect(jsUsageOf(s).blockedApis, isEmpty);
    });

    test('执行字段的脚本 API 会列进 blockedApis（本版一个 JS 都不跑）', () {
      final s = _source(
        name: '<js>java.ajax("/api?q=" + key)</js>',
        contentText: '@js:java.getElements("a")',
      );
      final usage = jsUsageOf(s);
      expect(usage.executedJs, isTrue);
      expect(usage.canRun, isFalse);
      expect(usage.executedFields, containsAll(['search.name', 'content.text']));
      expect(usage.blockedApis, containsAll(['java.ajax', 'java.getElements']));
    });

    test('raw 里只有占位符不判 JS', () {
      final s = _source(raw: {
        'searchUrl': '/s?q={{key}}&page={{page}}',
      });
      expect(usesJs(s), isFalse);
    });

    test('{{baseUrl}} 是占位符，不判 JS（legado 生态偶见）', () {
      final s = _source(searchUrl: '{{baseUrl}}/search?q={{key}}');
      expect(usesJs(s), isFalse);
      expect(
        usesJs(_source(raw: {'searchUrl': '{{baseUrl}}/s?q={{key}}'})),
        isFalse,
      );
    });

    test('bookSourceComment 里写 @js: 不判 JS（说明性字段不参与判定）', () {
      final s = _source(raw: {
        // 备注里提一句「这条用 @js: 洗过」很常见，扫它会把普通源误判成 JS
        'bookSourceComment': '2024-01 修：原来正文要 @js: 才干净，现在纯 CSS 就够',
        'bookSourceName': '某站',
        'bookSourceGroup': '@js: 分组名里的字样也不算',
        'bookSourceVersion': '<js>x</js>',
        'bookSourceUrl': 'https://a.example',
        'searchUrl': '/s?q={{key}}',
      });
      expect(usesJs(s), isFalse);
    });

    test('真规则里的 @js: 仍判 JS（说明性字段的豁免不外溢）', () {
      final s = _source(raw: {
        'bookSourceComment': '普通备注',
        'searchUrl': '/s?q={{key}}',
        'ruleSearch': {'bookList': '@js:java.getString("list")'},
      });
      expect(usesJs(s), isTrue);
    });

    test('详情 / 目录 / 正文规则里的 JS 也会被抓到', () {
      final s = BookSource(
        name: 's',
        baseUrl: 'https://a.example',
        search: const SearchRule(url: '/s?q={{key}}', list: '@css:.book'),
        detail: const DetailRule(name: '@css:h1', wordCount: '<js>x</js>'),
        toc: const TocRule(list: '@css:dd a', name: '@text'),
        content: const ContentRule(text: '@css:.content'),
      );
      expect(usesJs(s), isTrue);
    });
  });

  group('真实语料回归（I1 抽样：手机小说下载网的原始规则）', () {
    // 这条源是 `app/tools/js_rule_audit.dart` 抽样里 `jsInUnexecutedField`
    // 的代表：`ruleBookInfo.init` 里写了 org.jsoup + java.ajax（旧版据此整源
    // 判死），而搜索 / 目录 / 正文全是普通 CSS。规则串是原始 JSON 里抄的，
    // 不是编的。
    final source = BookSource(
      name: '手机小说下载网',
      baseUrl: 'http://www.xiaxs.la',
      search: const SearchRule(
        url: 'http://www.xiaxs.la/search.php?s=&searchkey={{key}}',
        list: '.listBox ul li',
        name: 'a@text##全集',
        detailUrl: 'a@href',
        cover: 'img@src',
        author: 'em@text',
      ),
      toc: const TocRule(list: '.pc_list a', name: 'text'),
      content: const ContentRule(text: '#content1@html'),
      raw: {
        'bookSourceName': '手机小说下载网',
        'searchUrl': 'http://www.xiaxs.la/search.php?s=&searchkey={{key}}',
        'ruleSearch': {
          'bookList': '.listBox ul li',
          'name': 'a@text##全集',
          'bookUrl': 'a@href',
        },
        'ruleBookInfo': {
          'init': '<js>\n'
              'var act=org.jsoup.Jsoup.parse(result).select(".downButton").attr("href");\n'
              'var url = "http://www.xiaxs.la"+act;\n'
              'java.put("url",url);\n'
              'java.ajax(url)</js>\n',
        },
        'ruleToc': {'chapterList': '.pc_list a'},
        'ruleContent': {'content': '#content1@html'},
      },
    );

    test('init 里的网络调用不判死，也不算拦路石', () {
      final usage = jsUsageOf(source);
      expect(usage.executedJs, isFalse);
      expect(usage.unexecutedJs, isTrue);
      expect(usage.executedFields, isEmpty);
      // init 里的 java.ajax / org.jsoup / java.put 我们根本不执行 → 不该出现
      expect(usage.blockedApis, isEmpty);
      expect(usesJs(source), isFalse);
    });

    test('搜索 / 目录 / 正文规则都落在本版支持的语法里', () {
      for (final rule in [
        source.search.list,
        source.search.name,
        source.search.detailUrl,
        source.search.cover,
        source.search.author,
        source.toc.list,
        source.content.text,
      ]) {
        final value = legadoSelector(rule);
        expect(value.isRunnable, isTrue, reason: '这条规则跑不了：$rule');
      }
    });
  });

  group('normalizeUrl', () {
    test('站内相对路径按 baseUrl 补全', () {
      expect(
        normalizeUrl('/book/1', 'https://a.example/search?q=x'),
        'https://a.example/book/1',
      );
    });

    test('相对路径按 base 所在目录解析', () {
      expect(
        normalizeUrl('a/b.html', 'https://a.example/dir/page'),
        'https://a.example/dir/a/b.html',
      );
    });

    test('去尾斜杠', () {
      expect(normalizeUrl('https://a.example/book/1/', ''), 'https://a.example/book/1');
      expect(normalizeUrl('https://a.example/', ''), 'https://a.example');
    });

    test('同站 http 统一升级成 https', () {
      expect(
        normalizeUrl('http://a.example/book', 'https://a.example'),
        'https://a.example/book',
      );
    });

    test('异站不动协议（别把别人的 http 硬改成 https）', () {
      expect(
        normalizeUrl('http://b.example/book', 'https://a.example'),
        'http://b.example/book',
      );
    });

    test('协议相对地址补协议', () {
      expect(
        normalizeUrl('//cdn.a.example/x', 'https://a.example'),
        'https://cdn.a.example/x',
      );
      expect(
        normalizeUrl('//cdn.a.example/x', 'http://a.example'),
        'http://cdn.a.example/x',
      );
    });

    test('去首尾空白', () {
      expect(normalizeUrl('  http://a.example  ', ''), 'http://a.example');
    });

    test('空串返回空串', () {
      expect(normalizeUrl('', 'https://a.example'), '');
      expect(normalizeUrl('   ', 'https://a.example'), '');
    });

    test('查询串保留、fragment 丢掉', () {
      expect(
        normalizeUrl('/book/1?from=list#chapter-3', 'https://a.example'),
        'https://a.example/book/1?from=list',
      );
    });

    test('只有查询串时挂在 base 路径上', () {
      expect(
        normalizeUrl('?page=2', 'https://a.example/list'),
        'https://a.example/list?page=2',
      );
    });

    test('HTML 实体 &amp; 还原', () {
      expect(
        normalizeUrl('/x?a=1&amp;b=2', 'https://a.example'),
        'https://a.example/x?a=1&b=2',
      );
    });

    test('非 http(s) 协议原样返回', () {
      expect(
        normalizeUrl('javascript:void(0)', 'https://a.example'),
        'javascript:void(0)',
      );
      expect(normalizeUrl('mailto:a@b.com', ''), 'mailto:a@b.com');
    });

    test('baseUrl 本身不可用（没有协议）时不做猜测', () {
      expect(normalizeUrl('/book/1', 'a.example'), '/book/1');
    });

    test('幂等：归一化两次结果不变', () {
      const cases = [
        'https://a.example/book/1/',
        'http://a.example/book',
        '/book/2?x=1#y',
      ];
      for (final raw in cases) {
        final once = normalizeUrl(raw, 'https://a.example');
        expect(normalizeUrl(once, 'https://a.example'), once, reason: raw);
      }
    });
  });
}
