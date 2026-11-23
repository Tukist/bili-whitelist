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
}
