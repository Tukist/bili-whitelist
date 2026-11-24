// JS 生成测试（R2）。
//
// `flutter test` 里没有 JS 引擎可跑，所以这里只断言**生成的脚本文本**：
// 关键 API 有没有出现、选择器有没有被安全地嵌进 JSON 字面量、后缀/回退有没有
// 带到 JS 里。文本断言看着粗糙，但覆盖的恰恰是「手工拼字符串」最容易翻车的
// 地方：选择器里一个单引号就能让整段脚本语法错误、页面静默返回空。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/js_builder.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

void main() {
  group('buildQueryFieldsJs', () {
    test('CSS：用 querySelectorAll，且把两个选择器都嵌进去', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:#list dl dd'),
        parseSelector('@css:a@href'),
      );
      expect(js, contains('querySelectorAll'));
      expect(js, contains('"query":"#list dl dd"'));
      expect(js, contains('"query":"a"'));
      expect(js, contains('"attr":"href"'));
      expect(js, contains('JSON.stringify'));
      // IIFE 结构完整
      expect(js.trimLeft().startsWith('(function(){'), isTrue);
      expect(js.trimRight().endsWith('})();'), isTrue);
    });

    test('XPath：用 document.evaluate + ORDERED_NODE_SNAPSHOT_TYPE', () {
      final js = buildQueryFieldsJs(
        parseSelector("@xpath://div[@id='list']/dl/dd"),
        null,
      );
      expect(js, contains('document.evaluate'));
      expect(js, contains('XPathResult.ORDERED_NODE_SNAPSHOT_TYPE'));
      expect(js, contains('"kind":"xpath"'));
    });

    test('href / src 用 new URL(…, document.baseURI) 转绝对', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:ul li'),
        parseSelector('@css:a@href'),
      );
      expect(js, contains('new URL('));
      expect(js, contains('document.baseURI'));
    });

    test('fieldSelector 为 null 时 FIELD 是 null，取列表节点自身', () {
      final js = buildQueryFieldsJs(parseSelector('@css:dd a@text'), null);
      expect(js, contains('var FIELD = null;'));
      expect(js, contains('valueOfNode(nodes[i], LIST)'));
    });

    test('取值后缀 / ##正则##替换 / 回退链都带进 JS', () {
      final js = buildQueryFieldsJs(
        parseSelector(r'@css:.book##\s+## '),
        parseSelector('@css:.title || @css:h3'),
      );
      expect(js, contains(r'"suffixRegex":"\\s+"'));
      expect(js, contains('"suffixReplacement":" "'));
      expect(js, contains('"fallbacks":[{"kind":"css","query":"h3"'));
    });

    test('选择器含单引号：原样进 JSON 字面量，不破坏单引号字符串', () {
      // 如果用单引号拼 JS 字符串，这条规则会把整脚本弄成语法错误
      final js = buildQueryFieldsJs(
        parseSelector("xpath://div[@id='list']"),
        null,
      );
      expect(js, contains('''"query":"//div[@id='list']"'''));
    });

    test('选择器含双引号/反斜杠：由 jsonEncode 负责转义', () {
      final js = buildQueryFieldsJs(
        parseSelector(r'css:.a[title="x\y"]'),
        null,
      );
      // JS 源码里应当是 \" 与 \\（回到 JS 侧就还是原来的字符）
      expect(js, contains(r'"query":".a[title=\"x\\y\"]"'));
    });

    test(r'生成结果里没有残留的 Dart 插值（$）', () {
      // 这条防的是「JS 里写了 $ 被 Dart 吞掉」这类低级但致命的错误
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector('@css:.title'),
      );
      expect(js.contains(r'$'), isFalse);
    });

    test('JSONPath 不执行：kind 是 json，JS 侧取不到值', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector(r'@json:$.data.name'),
      );
      expect(js, contains('"kind":"json"'));
    });
  });

  // ==================== v2.77.0：链式 / 索引 / 并列 / 扩展取值 ====================
  group('buildQueryFieldsJs（v2.77.0 新语法）', () {
    test('链式与索引都写进 spec，且脚本里有 applyIndex', () {
      final js = buildQueryFieldsJs(parseSelector('class.grid@tag.tr!0'), null);
      expect(js, contains('"steps":[{"kind":"css","query":"tr"'));
      expect(js, contains('"indexes":[0]'));
      expect(js, contains('"indexExclude":true'));
      // 过滤逻辑必须真的在脚本里（否则 JSON 里写了索引也不会生效）
      expect(js, contains('function applyIndex('));
      expect(js, contains('spec.indexExclude'));
    });

    test('&& 的并列分支进 concat，取值时按换行拼', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector(
          '[property=og:novel:category]@content&&[property=og:novel:status]@content',
        ),
      );
      expect(js, contains('"concat":[{"kind":"css"'));
      expect(js, contains('"attr":"content"'));
      expect(js, contains(r"parts.join('\n')"));
    });

    test('ownText / textNodes / all 三个取值在 JS 侧有实现', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector('@css:.brief@textNodes'),
      );
      expect(js, contains('"attr":"textNodes"'));
      expect(js, contains('function textNodes('));
      expect(js, contains('function ownText('));
      expect(js, contains("g === 'all'"));
    });

    test('children 走 root.children，不用 :scope', () {
      final js =
          buildQueryFieldsJs(parseSelector('class.shu_cont@children'), null);
      expect(js, contains('"kind":"children"'));
      expect(js, contains('root.children'));
      expect(js.contains(':scope'), isFalse);
    });

    test('##…### 的「只替换一次」传到脚本里', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector(r'##b(\d+)##$1###'),
      );
      expect(js, contains('"suffixReplaceFirst":true'));
      expect(js, contains('spec.suffixReplaceFirst'));
    });
  });

  group('buildQueryFieldsMultiJs', () {
    test('一次往返取六列，字段名都在 out 里', () {
      final js = buildQueryFieldsMultiJs(
        parseSelector('@css:.book'),
        {
          'name': parseSelector('@css:.title'),
          'author': parseSelector('@css:.author'),
          'cover': parseSelector('@css:img@src'),
          'intro': null,
          'detailUrl': parseSelector('@css:a@href'),
          'lastChapter': parseSelector('@css:.last'),
        },
      );
      expect(js, contains('out["name"] = arr;'));
      expect(js, contains('out["author"] = arr;'));
      expect(js, contains('out["lastChapter"] = arr;'));
      expect(js, contains('JSON.stringify(out)'));
      // intro 没有规则 → 取节点自身
      expect(js, contains('valueOfNode(nodes[i], LIST)'));
      // 只有一次 querySelectorAll 列表调用（column 选择器在循环外声明）
      expect(js, contains('var nodes = pickNodes(LIST);'));
    });

    test('字段是 XPath 时也生成 evaluate 调用', () {
      final js = buildQueryFieldsMultiJs(
        parseSelector('@css:.book'),
        {'name': parseSelector('@xpath:.//h3')},
      );
      expect(js, contains('document.evaluate'));
      expect(js, contains('"query":".//h3"'));
    });

    // ---- v2.79.0：字段位置的绝对 XPath 必须相对化 ----
    //
    // `//x` 在 XPath 1.0 里是绝对路径，`document.evaluate(sel, node, …)` 传什么
    // 节点都不影响结果 —— 之前字段规则写 `//dt` 时，每一行都取到文档里**第一个**
    // `dt`。分卷目录的实测表现：章名规则 `//dt/text()&&a@text` 让 57 章全叫
    // 「第一卷 XXX」（第一卷的卷名被刷到每一章上）。

    test('字段里的绝对 XPath 补成相对（.//x），列表仍按整页查', () {
      final js = buildQueryFieldsMultiJs(
        parseSelector('@xpath://div[@id="list"]/dl/dd'),
        {'name': parseSelector("@xpath://dt[@class='vcss']/text()")},
      );
      // 列表规则：整页查，`//` 保持绝对
      expect(js, contains('"query":"//div[@id='));
      // 字段规则：相对每个列表节点 → `.//dt`；绝不能留成 `//dt`
      expect(js, contains('".//dt[@class='));
      expect(js, isNot(contains('"query":"//dt')));
    });

    test('单字段求值同样把绝对 XPath 变相对', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector('@xpath://h3'),
      );
      expect(js, contains('".//h3"'));
    });

    test('链式段与回退链里的绝对 XPath 也按字段位置相对化', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector('//section@xpath://a || //span'),
      );
      expect(js, contains('".//section"'));
      expect(js, contains('".//a"'));
      expect(js, contains('".//span"'));
    });

    // ---- 例外：容器本身是整篇文档时**保持绝对** ----
    //
    // 详情页拿 `@css:body` 当容器（它没有「一行一个节点」的列表概念）。作者用
    // `//meta[@property="og:image"]/@content` 取封面、`og:novel:author` 取作者
    // 是 legado 语料里的常见写法，而 `<head>` 里的 meta **不在 body 里** ——
    // 补成 `.//meta` 就永远取不到（封面 / 作者整列空掉）。

    test('容器是 body 时字段 XPath 保持绝对（<head> 里的 meta 取得到）', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:body'),
        parseSelector('//meta[@property="og:image"]/@content'),
      );
      expect(
        js,
        contains(r'"query":"//meta[@property=\"og:image\"]/@content"'),
      );
      expect(js, isNot(contains(r'"query":".//meta')));
    });

    test('容器是 html / xpath 的 //body 时同样保持绝对', () {
      for (final container in ['@css:html', '@xpath://body']) {
        final js = buildQueryFieldsJs(
          parseSelector(container),
          parseSelector('//meta[@property="og:image"]/@content'),
        );
        expect(js, contains('"query":"//meta'), reason: container);
        expect(js, isNot(contains('".//meta"')), reason: container);
      }
    });

    test('详情页走的混合求值也按容器决定是否相对化', () {
      final js = buildQueryFieldsMixedJs(
        listSelector: parseSelector('@css:body'),
        selectorFields: {
          'cover': parseSelector('//meta[@property="og:image"]/@content'),
        },
        jsFields: {
          'author': parseSelector(
            '//meta[@property="og:novel:author"]/@content@js:result',
          ),
        },
        bindings: const {},
      );
      expect(js, contains(r'"query":"//meta[@property=\"og:image\"]/@content"'));
      expect(js, isNot(contains(r'"query":".//meta')));
    });

    test('带括号的整段 XPath 原样保留（补 `.` 会变成语法错误）', () {
      final js = buildQueryFieldsJs(
        parseSelector('@css:.book'),
        parseSelector('(//div)[1]'),
      );
      expect(js, contains('"(//div)[1]"'));
    });
  });

  group('buildRemoveNodesJs', () {
    test('CSS 与 XPath 都生成删除逻辑', () {
      final js = buildRemoveNodesJs(['@css:.ad', "@xpath://div[@class='tip']"]);
      expect(js, contains('querySelectorAll'));
      expect(js, contains('document.evaluate'));
      expect(js, contains('removeChild'));
      expect(js, contains('"query":".ad"'));
    });

    test('空选择器列表也能生成合法脚本', () {
      final js = buildRemoveNodesJs([]);
      expect(js, contains('var specs = [];'));
      expect(js, contains('return removed;'));
    });
  });

  group('buildInnerTextJs', () {
    test('取第一个匹配节点的文本', () {
      final js = buildInnerTextJs('@css:.intro');
      expect(js, contains('querySelectorAll'));
      expect(js, contains('"query":".intro"'));
      expect(js, contains('JSON.stringify(v)'));
    });
  });

  group('buildExtractHtmlJs（R3 正文抽取）', () {
    test('先删节点、再取 innerHTML，两段在同一个 IIFE 里', () {
      final js = buildExtractHtmlJs(
        removeSelectors: ['@css:.ad', '.recommend'],
        textSelector: parseSelector('@css:#content'),
      );
      // 顺序即正文清洗的硬约定：删除在前
      final removeAt = js.indexOf('REMOVES[k]');
      final extractAt = js.indexOf('var nodes = queryAll(document, SPEC);');
      expect(removeAt, greaterThan(0));
      expect(extractAt, greaterThan(removeAt));
      expect(js, contains('"query":".ad"'));
      expect(js, contains('"query":"#content"'));
      expect(js, contains('node.innerHTML'));
      expect(js, contains('JSON.stringify(html)'));
    });

    test('删除规则里的空串被跳过', () {
      final js = buildExtractHtmlJs(
        removeSelectors: const ['', '   '],
        textSelector: parseSelector('#content'),
      );
      expect(js, contains('var REMOVES = [];'));
    });
  });

  group('text. / %% 进 JS 规格（v2.78.0）', () {
    test('text.xxx 生成 textFilter 规格 + ownText 判定', () {
      final js = buildQueryFieldsJs(
        parseSelector('class.item'),
        parseSelector('text.作者：@text'),
      );
      expect(js, contains('"kind":"textFilter"'));
      expect(js, contains('"query":"作者："'));
      expect(js, contains('textFilterNodes(root, spec.query)'));
      expect(js, contains('getElementsContainingOwnText'));
    });

    test('%% 生成 interleave 规格，并在 pickNodes 里按行交错', () {
      final js = buildQueryFieldsJs(
        parseSelector('tag.td.0@tag.a@text%%tag.td.2@tag.a@text'),
        null,
      );
      expect(js, contains('"interleave":[{"kind":"css"'));
      // 外层循环是**第一支**的长度（legado 同义），后面的支多出来的行丢掉
      expect(js, contains('row < lists[0].length'));
      expect(js, contains('row < lists[col].length'));
    });
  });

  group('buildQueryFieldsMixedJs（I3b：选择器 + 逐行静态 JS）', () {
    test('选择器字段与 JS 字段各占一段，返回 fields/logs/errors', () {
      final js = buildQueryFieldsMixedJs(
        listSelector: parseSelector('class.item'),
        selectorFields: {'name': parseSelector('class.title@text')},
        jsFields: {
          'cover': parseSelector('tag.a.0@href@js:"https://i"+result'),
        },
        bindings: const {'baseUrl': 'https://a.example', 'key': '凡人'},
      );
      // 选择器字段还是原来的取值路径
      expect(js, contains('out["name"] = arr;'));
      // JS 字段：工厂 + 前置选择器 + 逐节点循环
      expect(js, contains('var RUN0 = '));
      expect(js, contains('var BASE0 = {"kind":"css"'));
      expect(js, contains('v = RUN0(b0, baseUrl, book, key, page);'));
      expect(js, contains('errors.push({field: "cover"'));
      // 绑定与返回载荷
      expect(js, contains('var key = "凡人";'));
      expect(js, contains('JSON.stringify({fields: out'));
      // 页面只查一次列表
      expect('var nodes = pickNodes(LIST);'.allMatches(js).length, 1);
    });

    test('没有前置选择器时 result 取节点自身（不是 null）', () {
      final js = buildQueryFieldsMixedJs(
        listSelector: parseSelector('class.item'),
        selectorFields: const {},
        jsFields: {'name': parseSelector('@js:decodeURI(result)')},
        bindings: const {},
      );
      // 没有前置选择器 → 取节点自身，且**不做相对转绝对**（JS 的 result 初值）
      expect(js, contains('valueOfNode(nodes[i], SELF, true)'));
    });
  });

  group('buildExtractHtmlWithJsJs（正文规则是静态 JS）', () {
    test('删节点 → 取前置选择器 → 跑脚本，顺序与载荷都对', () {
      final js = buildExtractHtmlWithJsJs(
        removeSelectors: ['class.ad'],
        base: parseSelector('id.content@html'),
        script: r'result.replace(/广告/g, "")',
        bindings: const {'baseUrl': 'https://a.example'},
      );
      final removeAt = js.indexOf('REMOVES[k]');
      final takeAt = js.indexOf('var raw = BASE ? firstValue');
      expect(removeAt, greaterThan(0));
      expect(takeAt, greaterThan(removeAt));
      expect(js, contains('var RUN = '));
      expect(js, contains('JSON.stringify({ok: true, value: out'));
      // 没有前置选择器时退回整页 body
      expect(js, contains('document.body.innerHTML'));
    });
  });
}
