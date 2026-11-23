// 多源搜索编排测试（R2）。
//
// 引擎是假的（[FakeRuleEngine]）：`flutter test` 没有 WebView，而这里要验的
// 恰恰是「并发 / 超时 / 部分失败 / 去重 / 合并」这些**与网页无关**的逻辑。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
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
}) =>
    BookSource(
      name: name,
      baseUrl: baseUrl,
      enabled: enabled,
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
}
