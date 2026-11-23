// 详情 + 目录服务测试（R3）。
//
// 全部用 FakeRuleEngine：`flutter test` 没有 WebView，而这里要验的是编排
// ——详情字段合并、目录倒序、分卷归属、分页去重、单页失败 partial、
// 以及「详情页挂了也只是 warning，不抛到 UI」。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

BookSource _source({DetailRule? detail, required TocRule toc}) => BookSource(
      name: '源A',
      baseUrl: 'https://x.example',
      search: const SearchRule(url: '/s?q={{key}}', list: '.b'),
      detail: detail,
      toc: toc,
      content: const ContentRule(text: '#content'),
    );

void main() {
  group('详情字段', () {
    test('规则里写了才抓；缺的字段不报错；倒序目录生效', () async {
      Map<String, SelectorValue?>? detailFields;
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'PAGE',
        onQueryMap: (html, list, fields) async {
          if (list.query == 'body') {
            detailFields = fields;
            return {
              'name': ['书名'],
              'author': ['作者'],
              'cover': ['https://x.example/c.jpg'],
              'intro': [' 简介 文本 '],
              'category': ['玄幻'],
            };
          }
          return {
            'name': ['第1章', '第2章', '第3章'],
            'url': [
              'https://x.example/1',
              'https://x.example/2',
              'https://x.example/3',
            ],
          };
        },
      );
      final source = _source(
        detail: const DetailRule(
          name: '@css:h1',
          author: '#author',
          cover: 'img@src',
          intro: '#intro',
          category: '#kind',
          // status / wordCount 没写 → 不抓
        ),
        toc: const TocRule(
          list: '.ch',
          name: '',
          urlSel: 'a@href',
          reversed: true,
        ),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(result.info.name, '书名');
      expect(result.info.author, '作者');
      expect(result.info.cover, 'https://x.example/c.jpg');
      expect(result.info.intro, '简介 文本'); // 折叠空白
      expect(result.info.category, '玄幻');
      expect(result.info.status, ''); // 没规则 → 空，不是报错
      expect(result.info.wordCount, '');
      // 只抓写了规则的字段
      expect(detailFields!.containsKey('status'), isFalse);
      expect(detailFields!.containsKey('wordCount'), isFalse);
      // 倒序
      expect(
        result.chapters.map((c) => c.name).toList(),
        ['第3章', '第2章', '第1章'],
      );
      // 详情页与目录页同址 → 只抓一次
      expect(engine.fetchedUrls.length, 1);
      expect(result.warning, isNull);
    });

    test('详情页挂了：保留搜索结果信息 + warning，不抛异常', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async {
          throw const RuleEngineException(RuleErrorKind.network, '站点连不上');
        },
      );
      final source = _source(
        detail: const DetailRule(name: '@css:h1'),
        toc: const TocRule(list: '.ch', urlSel: 'a@href'),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
        seed: const BookDetailInfo(name: '搜索结果里的书名', author: '作者'),
      );

      expect(result.info.name, '搜索结果里的书名');
      expect(result.info.author, '作者');
      expect(result.chapters, isEmpty);
      expect(result.warning, contains('详情页没取到'));
      expect(result.warning, contains('目录页没取到'));
    });
  });

  group('分卷', () {
    const volumeToc = TocRule(
      url: 'https://x.example/toc',
      list: '.ch',
      urlSel: 'a@href',
      volume: VolumeRule(list: '.vol', name: '.vname', chapters: '.ch'),
    );

    test('按卷分组，章节归属各自的卷', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'TOC',
        onQueryMap: (html, list, fields) async {
          if (html == 'TOC') {
            // 平铺兜底列表（有分卷时会被 volumes 覆盖）
            return {
              'name': ['平铺章节'],
              'url': ['https://x.example/flat'],
            };
          }
          if (html.contains('v1')) {
            return {
              'name': ['一 1', '一 2'],
              'url': ['https://x.example/1', 'https://x.example/2'],
            };
          }
          return {
            'name': ['二 1'],
            'url': ['https://x.example/3'],
          };
        },
        onQuery: (html, list, field) async {
          // volume.list 的两次查询：先卷名，再每卷 innerHTML
          if (field != null && field.attr == 'html') {
            return ['<div id="v1"></div>', '<div id="v2"></div>'];
          }
          return ['第一卷', '第二卷'];
        },
      );
      final source = _source(toc: volumeToc);

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(result.volumeFallback, isFalse);
      expect(result.volumes, isNotNull);
      expect(result.volumes!.length, 2);
      expect(result.volumes![0].name, '第一卷');
      expect(
        result.volumes![0].chapters.map((c) => c.name).toList(),
        ['一 1', '一 2'],
      );
      expect(result.volumes![1].chapters.single.name, '二 1');
      // 平铺列表被分卷列表替换（不是两套混在一起）
      expect(result.chapters.length, 3);
    });

    test('分卷规则取不到 → 退化成平铺并记 volumeFallback', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'TOC',
        onQueryMap: (html, list, fields) async => {
          'name': ['第1章'],
          'url': ['https://x.example/1'],
        },
        onQuery: (html, list, field) async => const <String?>[],
      );
      final source = _source(toc: volumeToc);

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(result.volumes, isNull);
      expect(result.volumeFallback, isTrue);
      expect(result.chapters.single.name, '第1章');
      expect(result.warning, contains('分卷'));
    });
  });

  group('目录分页', () {
    test('逐页取、按 URL 去重保序；某页失败保留已取到的并标 partial', () async {
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          if (url.contains('p=3')) {
            throw const RuleEngineException(RuleErrorKind.timeout, '第三页超时');
          }
          return url.contains('p=2') ? 'TOC2' : 'TOC1';
        },
        onQueryMap: (html, list, fields) async {
          if (html == 'TOC1') {
            return {
              'name': ['第1章', '第2章'],
              'url': ['https://x.example/1', 'https://x.example/2'],
            };
          }
          // 第 2 页重复了第 2 章（置顶位），并带来第 3 章
          return {
            'name': ['第2章', '第3章'],
            'url': ['https://x.example/2', 'https://x.example/3'],
          };
        },
      );
      final source = _source(
        toc: const TocRule(
          url: 'https://x.example/toc',
          pages: 'https://x.example/toc?p={{page}}',
          list: '.ch',
          urlSel: 'a@href',
          maxPages: 3,
        ),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(
        result.chapters.map((c) => c.name).toList(),
        ['第1章', '第2章', '第3章'],
      );
      expect(result.partial, isTrue);
      expect(result.warning, contains('第 3 页'));
      // 第 1、2、3 页都试过（第 3 页失败）
      expect(engine.fetchedUrls.length, 3);
    });

    test('分页规则没有页码占位符 → 只取第一页并明说', () async {
      var fetches = 0;
      final engine = FakeRuleEngine(
        onFetch: (_) async {
          fetches++;
          return 'TOC';
        },
        onQueryMap: (html, list, fields) async => {
          'name': ['第1章'],
          'url': ['https://x.example/1'],
        },
      );
      final source = _source(
        toc: const TocRule(
          url: 'https://x.example/toc',
          pages: 'https://x.example/toc-next',
          list: '.ch',
          urlSel: 'a@href',
          maxPages: 5,
        ),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(fetches, 1);
      expect(result.chapters.length, 1);
      expect(result.warning, contains('页码占位符'));
    });
  });

  group('容错', () {
    test('目录规则是 JS → 明确说不支持，chapters 为空', () async {
      final engine = FakeRuleEngine(onFetch: (_) async => 'PAGE');
      final source = _source(
        toc: const TocRule(list: '<js>x</js>', urlSel: 'a@href'),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(result.chapters, isEmpty);
      expect(result.warning, contains('JS'));
    });

    test('目录规则为空 → 只给一句说明', () async {
      final engine = FakeRuleEngine(onFetch: (_) async => 'PAGE');
      final source = _source(toc: const TocRule());

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(result.chapters, isEmpty);
      expect(result.warning, contains('目录规则'));
    });
  });
}
