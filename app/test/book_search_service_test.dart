// 多源搜索编排测试（R2）。
//
// 引擎是假的（[FakeRuleEngine]）：`flutter test` 没有 WebView，而这里要验的
// 恰恰是「并发 / 超时 / 部分失败 / 去重 / 合并」这些**与网页无关**的逻辑。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';
import 'package:bili_whitelist_app/services/book_search_service.dart';

/// 造一个书源（规则串可按需覆盖）。
BookSource _source(
  String name, {
  String baseUrl = 'https://a.example',
  String searchUrl = '/search?q={{key}}',
  String list = '@css:.book',
  String nameRule = '@css:.title',
  String authorRule = '@css:.author',
  String coverRule = '',
  String introRule = '',
  String detailRule = '@css:a@href',
  String lastChapterRule = '',
  bool enabled = true,
  Map<String, String> headers = const {},
}) =>
    BookSource(
      name: name,
      baseUrl: baseUrl,
      enabled: enabled,
      headers: headers,
      search: SearchRule(
        url: searchUrl,
        list: list,
        name: nameRule,
        author: authorRule,
        cover: coverRule,
        intro: introRule,
        detailUrl: detailRule,
        lastChapter: lastChapterRule,
      ),
      toc: const TocRule(),
      content: const ContentRule(),
    );

void main() {
  group('分组状态', () {
    test('三源并发：第 1、3 个成功，第 2 个网络错误，互不影响', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          if (url.contains('b.example')) {
            throw const RuleEngineException(
              RuleErrorKind.network,
              '连不上 b.example',
            );
          }
          return url.contains('a.example') ? 'A' : 'C';
        },
        onQueryMap: (html, list, fields) async {
          if (html == 'A') {
            return {
              'name': ['斗罗大陆', '吞噬星空'],
              'author': ['唐家三少', '我吃西红柿'],
              'detailUrl': ['/book/1/', 'https://a.example/book/2'],
              'cover': ['/c/1.jpg', null],
              'intro': ['  一个  故事 ', null],
              'lastChapter': ['第1章', null],
            };
          }
          return {
            'name': ['斗罗大陆'],
            'author': ['唐家三少'],
            'detailUrl': ['https://c.example/book/9'],
          };
        },
      );
      final service = BookSearchService(engine: engine);
      final groups = await service.search(
        sources: [
          _source(
            'A',
            coverRule: '@css:img@src',
            introRule: '@css:.intro',
            lastChapterRule: '@css:.last',
          ),
          _source('B', baseUrl: 'https://b.example'),
          _source('C', baseUrl: 'https://c.example'),
        ],
        keyword: '斗罗',
      );

      expect(groups.length, 3);
      // 顺序与入参一致
      expect([for (final g in groups) g.sourceName], ['A', 'B', 'C']);

      expect(groups[0].status, BookSearchStatus.ok);
      expect(groups[0].items.length, 2);
      final first = groups[0].items.first;
      expect(first.name, '斗罗大陆');
      expect(first.author, '唐家三少');
      expect(first.detailUrl, 'https://a.example/book/1'); // 尾斜杠已去掉
      expect(first.cover, 'https://a.example/c/1.jpg'); // 相对转绝对
      expect(first.intro, '一个 故事'); // 内部空白折叠
      expect(first.lastChapter, '第1章');
      expect(first.sourceName, 'A');

      expect(groups[1].status, BookSearchStatus.error);
      expect(groups[1].message, contains('连不上 b.example'));
      expect(groups[1].items, isEmpty);

      expect(groups[2].status, BookSearchStatus.ok);
      expect(groups[2].items.single.detailUrl, 'https://c.example/book/9');
    });

    test('搜索地址是相对路径时按 baseUrl 补全', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': ['书'],
              'detailUrl': ['/book/1'],
            },
      );
      await BookSearchService(engine: engine).search(
        sources: [_source('A', baseUrl: 'https://a.example')],
        keyword: 'x',
      );
      expect(engine.fetchedUrls.single, startsWith('https://a.example/search'));
    });

    test('搜到 0 条 → noResult（不是 error）', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': <String?>[],
              'detailUrl': <String?>[],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('A')],
        keyword: '找不到的书',
      );
      expect(groups.single.status, BookSearchStatus.noResult);
      expect(groups.single.message, contains('找不到的书'));
    });

    test('列表有节点但都取不到详情页地址 → error（不假装「没搜到」）', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': ['书一', '书二'],
              'detailUrl': [null, ''],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('A')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.error);
      expect(groups.single.message, contains('详情页地址'));
    });

    test('停用的源连分组都不生成', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': ['书'],
              'detailUrl': ['/book/1'],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('停用的', enabled: false),
          _source('启用的'),
        ],
        keyword: 'x',
      );
      expect(groups.length, 1);
      expect(groups.single.sourceName, '启用的');
    });

    test('没有启用的源 → 空列表（不抛）', () async {
      final groups = await BookSearchService(engine: FakeRuleEngine()).search(
        sources: [_source('A', enabled: false)],
        keyword: 'x',
      );
      expect(groups, isEmpty);
    });
  });

  group('源内去重', () {
    test('同一详情页不同写法只留一条，且保序', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': ['第一本', '第一本重复', '第二本'],
              'detailUrl': [
                '/book/1/',
                'https://a.example/book/1',
                'https://a.example/book/2',
              ],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('A')],
        keyword: 'x',
      );
      final items = groups.single.items;
      expect(items.length, 2);
      expect(items[0].name, '第一本');
      expect(items[0].detailUrl, 'https://a.example/book/1');
      expect(items[1].name, '第二本');
    });
  });

  group('JS 源', () {
    test('标 unsupported 且**不发请求**', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': ['书'],
              'detailUrl': ['/book/1'],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('需要JS', nameRule: '<js>java.getString("a")</js>'),
          _source('正常'),
        ],
        keyword: 'x',
      );
      expect(groups[0].status, BookSearchStatus.unsupported);
      expect(groups[0].message, contains('JS'));
      // 只有「正常」那个源发过请求
      expect(engine.fetchedUrls.length, 1);
      expect(
        engine.fetchedUrls.where((u) => u.contains('a.example')).length,
        1,
      );
      expect(groups[1].status, BookSearchStatus.ok);
    });

    test('JSON 接口书源（@json:）标 unsupported', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => const {},
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('JSON源', list: r'@json:$.data'),
        ],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.unsupported);
      expect(groups.single.message, contains('JSON'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('需要 ajax 的源：分组带 needsAjax（健康检测据此分档）', () async {
      final engine = FakeRuleEngine(onFetch: (url) async => 'A');
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('ajax源', nameRule: '<js>java.ajax("/x")</js>')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.unsupported);
      expect(groups.single.needsAjax, isTrue);
      expect(groups.single.message, contains('java.ajax'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('搜索列表规则本身是 JS → 明确说「只能执行取到值之后的变换」', () async {
      final engine = FakeRuleEngine(onFetch: (url) async => 'A');
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('列表JS源', list: '<js>result</js>')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.unsupported);
      expect(groups.single.message, contains('列表规则是 JS'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('{{tab}} 占位符标 unsupported 且**不发请求**（不拿关键词硬填）', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'A',
        onQueryMap: (html, list, fields) async => {
              'name': ['书'],
              'detailUrl': ['/book/1'],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('页签源', searchUrl: '/search?tab={{tab}}&q={{key}}'),
          _source('正常'),
        ],
        keyword: 'x',
      );
      expect(groups[0].status, BookSearchStatus.unsupported);
      expect(groups[0].message, contains('{{tab}}'));
      // 不能落进「需要 JS」那条分支：tab 是占位符，不是 JS
      expect(groups[0].message, isNot(contains('JS')));
      // 只有「正常」那个源发过请求
      expect(engine.fetchedUrls.length, 1);
      expect(groups[1].status, BookSearchStatus.ok);
    });
  });

  group('静态 JS 接线（I3b）', () {
    // 这一组是 I3b 的核心：v2.77.0 及以前「有 JS 就不跑」，现在静态 JS 真的执行。
    test('静态 JS 字段被真正调用，绑定带 result / key / baseUrl', () async {
      final calls = <String>[];
      Map<String, String>? seenBindings;
      String? seenBase;
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async {
          // 选择器字段（name 是 JS，不在这里出现）
          expect(fields.containsKey('name'), isFalse);
          return {
            'detailUrl': ['/book/1'],
          };
        },
        onEvalJs: (script, bindings, base) async {
          calls.add(script);
          seenBindings = bindings;
          seenBase = base?.query;
          return '斗罗大陆';
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source(
            '静态JS',
            nameRule: 'class.title@text@js:result.replace(/\\s+/g, "")',
          ),
        ],
        keyword: '斗罗',
      );

      expect(groups.single.status, BookSearchStatus.ok);
      expect(groups.single.items.single.name, '斗罗大陆');
      // 脚本正文被送进沙箱（`@js:` 之后那一段）
      expect(calls.single, contains('replace'));
      // 前置选择器一起进沙箱（result 的初值来源）
      expect(seenBase, '.title');
      // 绑定：key = 关键词、baseUrl = 本次搜索页、book.origin 的站点根
      expect(seenBindings!['baseUrl'], contains('a.example'));
      expect(seenBindings!['key'], '斗罗');
      expect(seenBindings!['sourceUrl'], 'https://a.example');
    });

    test('一次搜索只载入一次页面（多字段不重复抓）', () async {
      // 抓取次数 = 页数；求值次数 = 1（选择器 + JS 一起求）。
      // 逐字段载页会让「20 个源 × 6 字段」变成 120 次载入。
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async => {
          'detailUrl': ['/book/1'],
        },
        onEvalJs: (script, bindings, base) async => '书',
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source(
            '甲',
            nameRule: 'class.title@text@js:result',
            authorRule: 'class.author@text@js:result',
          ),
        ],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.ok);
      expect(engine.fetchedUrls.length, 1);
      // 选择器那一批 1 次 + 两个 JS 字段各 1 次（假引擎没有 DOM，
      // 真引擎在混合脚本里一次求值跑完；这里钉的是「不按次数载页」）
      expect(engine.queryCount, 1);
    });

    test('被拦的 API：跳过且文案点名（不是一句「需要 JS」）', () async {
      final engine = FakeRuleEngine(onFetch: (url) async => 'PAGE');
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('毒源', coverRule: '<js>fetch("/api")</js>'),
        ],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.unsupported);
      expect(groups.single.message, contains('cover'));
      expect(groups.single.message, contains('fetch'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('text. 按文字筛元素：不再是「不支持」，照常发给引擎', () async {
      Map<String, SelectorValue?>? seen;
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async {
          seen = fields;
          return {
            'name': ['斗罗大陆'],
            'detailUrl': ['/book/1'],
          };
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('文字筛', authorRule: 'text.作者：@text')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.ok);
      expect(seen!['author']!.kind, SelectorKind.textFilter);
      expect(seen!['author']!.query, '作者：');
    });
  });

  group('请求选项与地址模板（I4）', () {
    test('POST 源：方法 / body 模板 / charset 真的传下去，结果照常解析', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async => {
          'name': ['斗罗大陆'],
          'detailUrl': ['/book/1'],
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source(
            'POST源',
            // 语料里最常见的形态：地址 + 请求选项，body 里还有关键词模板
            searchUrl: '/search.php,{"method":"POST",'
                '"body":"searchkey={{key}}&searchtype=all","charset":"gbk"}',
          ),
        ],
        keyword: '斗罗',
      );

      expect(groups.single.status, BookSearchStatus.ok);
      expect(groups.single.items.single.name, '斗罗大陆');
      final req = engine.fetchedRequests.single;
      expect(req.isPost, isTrue);
      // 地址里的选项被剥掉了，body 的模板被替换（关键词**不编码**，见
      // request_options.applyUrlPlaceholders：body 的值要原文）
      expect(req.url, 'https://a.example/search.php');
      expect(req.body, 'searchkey=斗罗&searchtype=all');
      // 选项里的 charset 作为解码提示传下去
      expect(req.charset, 'gbk');
    });

    test('选项 headers 覆盖书源级 headers（大小写不敏感，最终只剩一个键）', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['/book/1'],
        },
      );
      await BookSearchService(engine: engine).search(
        sources: [
          _source(
            '带头',
            headers: {'Referer': 'https://a.example/', 'X-Src': '1'},
            searchUrl: '/s,{"headers":{"referer":"https://m.example/"}}',
          ),
        ],
        keyword: 'x',
      );
      final req = engine.fetchedRequests.single;
      // HTTP 头名大小写不敏感：`Referer` / `referer` 只留一个键（以前两个都进
      // Dio，真正发出去哪个由底层折叠决定）。选项这次写的优先。
      expect(
        req.headers.keys.where((k) => k.toLowerCase() == 'referer').length,
        1,
      );
      expect(req.headers['referer'], 'https://m.example/');
      expect(req.headers.containsKey('Referer'), isFalse);
      expect(req.headers['X-Src'], '1');
    });

    test('地址模板里的 JS 表达式被求值后再拼地址', () async {
      final pages = <String>[];
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['/book/1'],
        },
        onEvalUrlJs: (script, bindings) async {
          // 只有空白页上能看到的上下文：baseUrl / key / page / book / source
          expect(bindings['key'], '斗罗');
          pages.add(bindings['page']!);
          if (script == 'page-1') return '${int.parse(bindings['page']!) - 1}';
          return '斗罗';
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('模板源', searchUrl: '/s?p={{page-1}}&q={{book.name}}'),
        ],
        keyword: '斗罗',
        maxPages: 2,
      );
      expect(groups.single.status, BookSearchStatus.ok);
      // 每页各求两段（页码表达式 + 书名），两页都跑
      expect(engine.urlTemplateScripts, ['page-1', 'book.name', 'page-1', 'book.name']);
      expect(pages, ['1', '1', '2', '2']);
      final urls = engine.fetchedRequests.map((r) => r.url).toList();
      expect(urls.length, 2);
      expect(urls[0], contains('p=0'));
      expect(urls[1], contains('p=1'));
      // 关键词进 query 后被 Uri 正常编码（归一化那一步做的）
      expect(urls[0], contains(Uri.encodeComponent('斗罗')));
    });

    test('地址模板求值为空 → unsupported 且不发请求（不发半截地址）', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onEvalUrlJs: (script, bindings) async => '',
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('空模板', searchUrl: '/s?q={{book.name}}')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.unsupported);
      expect(groups.single.message, contains('求值为空'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('模板里访问 document → unsupported，文案说清是能力边界', () async {
      final engine = FakeRuleEngine(onFetch: (url) async => 'PAGE');
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('页面对象', searchUrl: '/s?q={{document.title}}')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.unsupported);
      expect(groups.single.message, contains('document'));
      expect(engine.fetchedUrls, isEmpty);
    });

    test('请求选项是坏 JSON：退回整串当地址，照常发请求', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['/book/1'],
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('坏选项', searchUrl: '/s?q={{key}},{"method":POST}'),
        ],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.ok);
      // 整串当地址（这就是旧行为，不报错）
      expect(engine.fetchedRequests.single.url, contains('POST'));
    });

    // ---- 翻页部分失败：保留已拿到的结果，别整组判死 ----
    //
    // 以前第 2 页 `resolveRequestField` 失败会 `return` 一个 unsupported 分组，
    // 第 1 页明明已经拿到条目也一起丢了 —— 用户看到的是「这个源不支持」，
    // 实际上只是第 2 页的模板拼不出来。

    test('第 2 页地址拼不出来 → ok + 保留第 1 页条目 + 一行提示', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => 'PAGE',
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['/book/1'],
        },
        // 第 2 页的模板求值为空 → 拼不出地址
        onEvalUrlJs: (script, bindings) async =>
            bindings['page'] == '2' ? '' : '0',
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('翻页拼不出', searchUrl: '/s?p={{page-1}}')],
        keyword: 'x',
        maxPages: 2,
      );
      final group = groups.single;
      expect(group.status, BookSearchStatus.ok);
      expect(group.items.single.name, '书');
      expect(group.warning, contains('第 2 页'));
      expect(group.warning, contains('已保留前 1 页结果'));
      // 第 2 页没发请求（拼不出来就别发半截地址）
      expect(engine.fetchedUrls.length, 1);
    });

    test('第 2 页抓取失败 → ok + 保留第 1 页条目 + 一行提示', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          if (url.contains('p=1')) {
            throw const RuleEngineException(
              RuleErrorKind.network,
              '第 2 页连不上',
            );
          }
          return 'PAGE';
        },
        onQueryMap: (html, list, fields) async => {
          'name': ['书'],
          'detailUrl': ['/book/1'],
        },
        onEvalUrlJs: (script, bindings) async => '${int.parse(bindings['page']!) - 1}',
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('翻页断网', searchUrl: '/s?p={{page-1}}')],
        keyword: 'x',
        maxPages: 2,
      );
      final group = groups.single;
      expect(group.status, BookSearchStatus.ok);
      expect(group.items.single.name, '书');
      expect(group.warning, contains('第 2 页没取到'));
      expect(group.warning, contains('已保留前 1 页结果'));
    });
  });

  group('超时与异常', () {
    test('单源超时只影响自己', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          if (url.contains('slow.example')) {
            // 永不返回：让超时机制生效
            return Completer<String>().future;
          }
          return 'A';
        },
        onQueryMap: (html, list, fields) async => {
              'name': ['书'],
              'detailUrl': ['/book/1'],
            },
      );
      final service = BookSearchService(
        engine: engine,
        perSourceTimeout: const Duration(milliseconds: 80),
      );
      final groups = await service.search(
        sources: [
          _source('慢', baseUrl: 'https://slow.example'),
          _source('快'),
        ],
        keyword: 'x',
      );
      expect(groups[0].status, BookSearchStatus.error);
      expect(groups[0].message, contains('超时'));
      expect(groups[1].status, BookSearchStatus.ok);
    });

    test('引擎抛非异常对象也不外泄', () async {
      final engine = FakeRuleEngine(
        // 故意抛 String —— 很多第三方代码这么干
        onFetch: (url) async => throw 'boom',
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('A')],
        keyword: 'x',
      );
      expect(groups.single.status, BookSearchStatus.error);
      expect(groups.single.message, isNotNull);
    });

    test('整体永不抛异常（多个源全炸也一样）', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => throw StateError('坏掉了'),
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('A'), _source('B', baseUrl: 'https://b.example')],
        keyword: 'x',
      );
      expect(groups.length, 2);
      expect(
        groups.every((g) => g.status == BookSearchStatus.error),
        isTrue,
      );
    });
  });

  group('并发', () {
    test('8 个源同时搜索，同时在飞的不超过 4', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          inFlight--;
          return 'A';
        },
        onQueryMap: (html, list, fields) async => {
              'name': ['书'],
              'detailUrl': ['/book/1'],
            },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          for (var i = 0; i < 8; i++)
            _source('S$i', baseUrl: 'https://s$i.example'),
        ],
        keyword: 'x',
      );
      expect(groups.length, 8);
      expect(maxInFlight, lessThanOrEqualTo(4));
      // 至少真的并发过（不然就是串行实现了）
      expect(maxInFlight, greaterThan(1));
    });
  });

  group('翻页', () {
    test('maxPages=2 时两页结果合并，且按 {{page}} 拼地址', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async => url.contains('page=2') ? 'P2' : 'P1',
        onQueryMap: (html, list, fields) async => html == 'P2'
            ? {
                'name': ['第二页的书'],
                'detailUrl': ['/book/2'],
              }
            : {
                'name': ['第一页的书'],
                'detailUrl': ['/book/1'],
              },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [
          _source('A', searchUrl: '/search?q={{key}}&page={{page}}'),
        ],
        keyword: 'x',
        maxPages: 2,
      );
      expect(groups.single.items.length, 2);
      expect(
        [for (final i in groups.single.items) i.name],
        ['第一页的书', '第二页的书'],
      );
      expect(engine.fetchedUrls.length, 2);
      expect(engine.fetchedUrls[1], contains('page=2'));
    });
  });

  group('merged 合并视图', () {
    BookSearchGroup group(String source, List<String> names,
            [List<String>? authors]) =>
        BookSearchGroup(
          sourceName: source,
          status: BookSearchStatus.ok,
          items: [
            for (var i = 0; i < names.length; i++)
              BookSearchItem(
                name: names[i],
                author: authors != null && i < authors.length
                    ? authors[i]
                    : '同名作者',
                detailUrl: 'https://$source/$i',
                sourceName: source,
              ),
          ],
        );

    test('同名同作者跨源合并，sourceCount 记命中源数', () {
      final merged = mergeSearchGroups([
        group('a', ['斗罗大陆', '吞噬星空'], ['唐家三少', '我吃西红柿']),
        group('b', ['斗罗大陆'], ['唐家三少']),
        group('c', ['斗罗大陆 '], [' 唐家三少']),
      ]);
      expect(merged.length, 2);
      expect(merged[0].name, '斗罗大陆'); // 首条为主
      expect(merged[0].sourceCount, 3);
      expect(merged[1].name, '吞噬星空');
      expect(merged[1].sourceCount, 1);
    });

    test('全角 / 大小写 / 空白差异视为同一本', () {
      final merged = mergeSearchGroups([
        group('a', ['ＡＢＣ　测试'], ['Author']),
        group('b', ['abc测试'], ['author']),
      ]);
      expect(merged.length, 1);
      expect(merged.single.sourceCount, 2);
    });

    test('同一个源里两条同名只算一次源数', () {
      final merged = mergeSearchGroups([
        group('a', ['斗罗大陆', '斗罗大陆'], ['唐家三少', '唐家三少']),
      ]);
      expect(merged.single.sourceCount, 1);
    });

    test('作者不同就是两本书', () {
      final merged = mergeSearchGroups([
        group('a', ['斗罗大陆'], ['唐家三少']),
        group('b', ['斗罗大陆'], ['另一个人']),
      ]);
      expect(merged.length, 2);
    });

    test('空分组不产生条目', () {
      expect(
        mergeSearchGroups(const [
          BookSearchGroup(sourceName: 'a', status: BookSearchStatus.error),
        ]),
        isEmpty,
      );
    });

    test('服务的 merged() 与纯函数一致', () {
      final service = BookSearchService(engine: FakeRuleEngine());
      final groups = [
        group('a', ['书'], ['作者']),
        group('b', ['书'], ['作者']),
      ];
      expect(service.merged(groups).single.sourceCount, 2);
    });
  });

  group('buildSearchUrl', () {
    test('{{key}} 做 URL 编码', () {
      expect(
        buildSearchUrl('/s?q={{key}}', '斗 罗', 1),
        '/s?q=%E6%96%97%20%E7%BD%97',
      );
    });

    test('{{page}} 替换成页码，大小写与空格都容忍', () {
      expect(buildSearchUrl('/s?p={{ PAGE }}', 'x', 3), '/s?p=3');
      expect(buildSearchUrl('/s?p={{searchPage}}&q={{keyword}}', 'a', 2),
          '/s?p=2&q=a');
    });

    test('老式 %s 只替换第一个', () {
      expect(buildSearchUrl('/s?q=%s', 'ab', 1), '/s?q=ab');
      expect(buildSearchUrl('/s?q=%s&x=%s', 'ab', 1), '/s?q=ab&x=%s');
    });

    test('没有占位符就原样返回（去首尾空白）', () {
      expect(buildSearchUrl('  /s?q=固定  ', 'x', 1), '/s?q=固定');
    });

    test('{{tab}} 原样保留（页签语义，不拿关键词硬填）', () {
      expect(
        buildSearchUrl('/s?tab={{tab}}&q={{key}}', '斗罗', 1),
        '/s?tab={{tab}}&q=%E6%96%97%E7%BD%97',
      );
      // 大小写 / 空格写法也不替换
      expect(buildSearchUrl('/s?tab={{ TAB }}', 'x', 1), '/s?tab={{ TAB }}');
    });
  });

  group('解码旁注（v2.75.0）', () {
    // 旁注只是「这个源这次是怎么解的」的说明，**不许影响状态判定**：
    // GBK 解出来的结果照样是 ok，旁注只是分组标题下的一行小字。
    test('GBK 源（自动判定）：分组带「编码：GBK」，状态仍然是 ok', () async {
      final engine = _EncodingEngine(
        encoding: 'gbk',
        // 真实链路里「没声明、自动判成 GBK」一定同时带这句好消息
        decodeWarning: kDecodeGbkGuessWarning,
        onQueryMap: (html, list, fields) async => {
          'name': ['斗罗大陆'],
          'detailUrl': ['https://a.example/book/1'],
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('甲')],
        keyword: '斗罗',
      );
      expect(groups.single.status, BookSearchStatus.ok);
      expect(groups.single.items.single.name, '斗罗大陆');
      // 自动纠正成功就是「编码：GBK」，**不许**被写成「仍有乱码」
      expect(groups.single.decodeNote, '编码：GBK');
    });

    test('正常 UTF-8 源：没有旁注（不打扰用户）', () async {
      final engine = _EncodingEngine(
        encoding: 'utf-8',
        onQueryMap: (html, list, fields) async => {
          'name': ['斗罗大陆'],
          'detailUrl': ['https://a.example/book/1'],
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('甲')],
        keyword: '斗罗',
      );
      expect(groups.single.decodeNote, isNull);
    });

    test('解出乱码：旁注说「解码有乱码」，结果照常返回', () async {
      final engine = _EncodingEngine(
        encoding: 'gbk',
        decodeWarning: '解码后仍有乱码，正文可能不完整',
        onQueryMap: (html, list, fields) async => {
          'name': ['斗罗大陆'],
          'detailUrl': ['https://a.example/book/1'],
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('甲')],
        keyword: '斗罗',
      );
      expect(groups.single.status, BookSearchStatus.ok);
      expect(groups.single.decodeNote, '编码：GBK（仍有乱码）');
    });

    test('0 条结果也带旁注（用户要知道「按 GBK 解了但没这本书」）', () async {
      final engine = _EncodingEngine(
        encoding: 'gbk',
        onQueryMap: (html, list, fields) async => {
          'name': <String?>[],
          'detailUrl': <String?>[],
        },
      );
      final groups = await BookSearchService(engine: engine).search(
        sources: [_source('甲')],
        keyword: '没有的书',
      );
      expect(groups.single.status, BookSearchStatus.noResult);
      expect(groups.single.decodeNote, '编码：GBK');
    });
  });
}

/// 会「报编码事实」的假引擎：只把 `lastDecodeEncoding` / `lastDecodeWarning`
/// 摆好，求值仍走 [FakeRuleEngine] 的注入回调。
///
/// 为什么需要它：真引擎（[WebViewRuleEngine]）的解码信息是旁注字段，假引擎
/// 默认不设，搜索服务那条「抓完就收下旁注」的路就测不到。
class _EncodingEngine extends FakeRuleEngine {
  _EncodingEngine({
    required this.encoding,
    this.decodeWarning,
    super.onQueryMap,
  });

  final String? encoding;
  final String? decodeWarning;

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String charset = 'utf-8',
    String method = 'GET',
    String? body,
  }) async {
    fetchedUrls.add(url);
    // 与真实现同序：先当作「这次什么都不知道」，再按本次结果写
    lastDecodeEncoding = encoding;
    lastDecodeWarning = decodeWarning;
    if (onFetch != null) return onFetch!(url);
    return '<html></html>';
  }
}
