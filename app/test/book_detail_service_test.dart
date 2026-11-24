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
            // 分卷那次查询（v2.79.0 起卷名与卷容器同一批节点）
            if (fields.containsKey('html')) {
              return {
                'name': ['第一卷', '第二卷'],
                'html': ['<div id="v1"></div>', '<div id="v2"></div>'],
              };
            }
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

    // ---- v2.79.0：卷名与卷容器同源 + 章名不被卷名污染 ----

    /// 真实站点的分卷目录片段（wenku8 风格：`dt` 是卷名、`dd` 是章节），
    /// 只裁剪成 3 卷 6 章 —— 卷数 / 卷名 / 章节归属 / 前缀这四件事都验得到。
    const volumeHtml = [
      '<div class="volume"><dl><dt class="vcss">第一卷</dt>'
          '<dd><a href="/novel/0/718/10001.htm">琪琪</a></dd>'
          '<dd><a href="/novel/0/718/10002.htm">休息室</a></dd>'
          '<dd><a href="/novel/0/718/10003.htm">凯奈斯</a></dd></dl></div>',
      '<div class="volume"><dl><dt class="vcss">第二卷</dt>'
          '<dd><a href="/novel/0/718/20001.htm">劫机</a></dd>'
          '<dd><a href="/novel/0/718/20002.htm">哈萨维</a></dd></dl></div>',
      '<div class="volume"><dl><dt class="vcss">第三卷</dt>'
          '<dd><a href="/novel/0/718/30001.htm">终章</a></dd></dl></div>',
    ];

    test('三卷：卷名与卷容器出自同一次求值，章名不带卷名前缀', () async {
      Map<String, SelectorValue?>? volumeFields;
      var volumeQueries = 0;
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'TOC',
        onQueryMap: (html, list, fields) async {
          if (html == 'TOC') {
            // 分卷那次查询：卷名 + 每卷 innerHTML 必须**同一批节点**
            if (fields.containsKey('html')) {
              volumeQueries++;
              volumeFields = fields;
              return {
                'name': ['第一卷', '第二卷', '第三卷'],
                'html': volumeHtml,
              };
            }
            return {
              'name': ['平铺章节'],
              'url': ['https://x.example/flat'],
            };
          }
          // 卷内章节：按片段取（片段里带着自己的卷名 dt，章名规则不该碰它）
          if (html.contains('10001')) {
            return {
              'name': ['琪琪', '休息室', '凯奈斯'],
              'url': [
                'https://x.example/10001',
                'https://x.example/10002',
                'https://x.example/10003',
              ],
            };
          }
          if (html.contains('20001')) {
            return {
              'name': ['劫机', '哈萨维'],
              'url': ['https://x.example/20001', 'https://x.example/20002'],
            };
          }
          return {
            'name': ['终章'],
            'url': ['https://x.example/30001'],
          };
        },
      );
      final source = _source(toc: volumeToc);

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      // 同源：一次查询里同时取卷名与卷容器，不再靠两次求值下标对齐
      expect(volumeQueries, 1, reason: '卷名与卷容器必须同一次求值取出');
      expect(volumeFields!.keys, containsAll(<String>['name', 'html']));
      expect(result.volumeFallback, isFalse);
      expect(
        result.volumes!.map((v) => v.name).toList(),
        ['第一卷', '第二卷', '第三卷'],
      );
      expect(
        result.volumes!.map((v) => v.chapters.length).toList(),
        [3, 2, 1],
      );
      // 章名就是章名：不带任何卷名前缀（「第一卷 琪琪」是修之前的形态）
      expect(
        result.volumes!
            .expand((v) => v.chapters)
            .map((c) => c.name)
            .toList(),
        ['琪琪', '休息室', '凯奈斯', '劫机', '哈萨维', '终章'],
      );
      for (final chapter in result.volumes!.expand((v) => v.chapters)) {
        expect(chapter.name.contains('卷'), isFalse,
            reason: '章名被卷名污染：${chapter.name}');
      }
    });

    test('卷名只命中第一项 → 其余卷用「第 N 卷」占位，不把第一项刷到所有卷', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'TOC',
        onQueryMap: (html, list, fields) async {
          if (html == 'TOC') {
            if (fields.containsKey('html')) {
              // 卷名规则只在第一份节点上命中（相对求值时其余卷是 null）
              return {
                'name': ['第一卷', null, null],
                'html': volumeHtml,
              };
            }
            return {
              'name': ['平铺章节'],
              'url': ['https://x.example/flat'],
            };
          }
          if (html.contains('10001')) {
            return {
              'name': ['琪琪'],
              'url': ['https://x.example/10001'],
            };
          }
          if (html.contains('20001')) {
            return {
              'name': ['劫机'],
              'url': ['https://x.example/20001'],
            };
          }
          return {
            'name': ['终章'],
            'url': ['https://x.example/30001'],
          };
        },
      );
      final source = _source(toc: volumeToc);

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(
        result.volumes!.map((v) => v.name).toList(),
        ['第一卷', '第 2 卷', '第 3 卷'],
      );
      // 占位卷的章节照常归位，章名同样不带卷名
      expect(
        result.volumes!.map((v) => v.chapters.single.name).toList(),
        ['琪琪', '劫机', '终章'],
      );
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

  group('静态 JS 接线（I3b）', () {
    test('详情字段是静态 JS：真调用，绑定带书名 / 站点根', () async {
      final scripts = <String>[];
      Map<String, String>? seen;
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'PAGE',
        onQueryMap: (html, list, fields) async {
          if (list.query == 'body') {
            // author 是 JS 字段，不该出现在选择器回调里
            expect(fields.containsKey('author'), isFalse);
            return {'name': ['书名']};
          }
          return const {};
        },
        onEvalJs: (script, bindings, base) async {
          scripts.add(script);
          seen = bindings;
          return '唐家三少';
        },
      );
      final source = _source(
        detail: const DetailRule(
          name: '.name@text',
          author: '.author@text@js:result.trim()',
        ),
        toc: const TocRule(list: ''),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
        seed: const BookDetailInfo(name: '斗罗大陆'),
      );

      expect(result.info.author, '唐家三少');
      expect(scripts.single, contains('trim'));
      expect(seen!['book'], '斗罗大陆');
      expect(seen!['baseUrl'], 'https://x.example/book/1');
      expect(seen!['sourceUrl'], 'https://x.example');
    });

    test('章节地址是静态 JS（拼接站点前缀）→ 交给沙箱并采用返回值', () async {
      String? seenBase;
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'PAGE',
        onQueryMap: (html, list, fields) async {
          if (list.query == 'body') return const {};
          // url 是 JS 字段，不在选择器回调里
          expect(fields.containsKey('url'), isFalse);
          return {
            'name': ['第1章'],
          };
        },
        onEvalJs: (script, bindings, base) async {
          seenBase = base?.query;
          return 'https://m.example/ch/1';
        },
      );
      final source = _source(
        toc: const TocRule(
          list: '.ch',
          name: '',
          urlSel: 'a@href@js:"https://m.example"+result',
        ),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(seenBase, 'a');
      expect(result.chapters.single.url, 'https://m.example/ch/1');
      expect(result.chapters.single.name, '第1章');
    });

    test('目录地址是 JS 模板 → 明说，不硬拼脚本源码', () async {
      final engine = FakeRuleEngine(onFetch: (_) async => 'PAGE');
      final source = _source(
        toc: const TocRule(
          url: r'@js:baseUrl + "/toc"',
          list: '.ch',
          urlSel: 'a@href',
        ),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
      );

      expect(result.chapters, isEmpty);
      expect(result.warning, contains('目录地址是 JS 模板'));
    });

    test('目录地址是 {{…}} 表达式模板 → 求值后真的去抓（I4）', () async {
      final urls = <String>[];
      final engine = FakeRuleEngine(
        onFetch: (url) async {
          urls.add(url);
          return 'PAGE';
        },
        onQueryMap: (html, list, fields) async {
          if (list.query == 'body') return const {};
          return {
            'name': ['第1章'],
            'url': ['/ch/1'],
          };
        },
        onEvalUrlJs: (script, bindings) async {
          // 目录阶段的绑定：key = 书名，page = 1
          expect(bindings['key'], '斗罗大陆');
          expect(bindings['page'], '1');
          return script == 'book.name' ? '斗罗大陆' : '/toc';
        },
      );
      final source = _source(
        toc: const TocRule(
          url: '/toc/{{book.name}}',
          list: '.ch',
          urlSel: 'a@href',
        ),
      );

      final result = await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
        seed: const BookDetailInfo(name: '斗罗大陆'),
      );

      expect(result.chapters.single.name, '第1章');
      expect(result.chapters.single.url, 'https://x.example/ch/1');
      expect(urls, hasLength(1));
      expect(urls.single, contains(Uri.encodeComponent('斗罗大陆')));
    });

    test('目录地址是 POST 源：目录页也用 POST + body 抓', () async {
      final engine = FakeRuleEngine(
        onFetch: (_) async => 'PAGE',
        onQueryMap: (html, list, fields) async {
          if (list.query == 'body') return const {};
          return {
            'name': ['第1章'],
            'url': ['/ch/1'],
          };
        },
      );
      final source = _source(
        toc: const TocRule(
          url: '/toc.json,{"method":"POST","body":"id={{key}}"}',
          list: '.ch',
          urlSel: 'a@href',
        ),
      );

      await BookDetailService(engine: engine).loadDetail(
        source: source,
        detailUrl: 'https://x.example/book/1',
        seed: const BookDetailInfo(name: '斗罗'),
      );

      final req = engine.fetchedRequests.single;
      expect(req.isPost, isTrue);
      expect(req.url, 'https://x.example/toc.json');
      // body 里的关键词保持原文（v2.79.0 修正）：编码成 `%E6%96%97…` 站点拿到
      // 的是字面量百分号串，且会让「body 含中文 + GBK → 拒绝」的守卫失效。
      expect(req.body, 'id=斗罗');
    });
  });
}