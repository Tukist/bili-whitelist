// 规则引擎里**可纯测**的那部分（R2）。
//
// 真 WebView 在 `flutter test` 里建不出来（`WebViewController()` 构造即抛），
// 所以引擎能被单测的只有：`<base href>` 注入（相对链接解析全靠它）和
// [FakeRuleEngine] 的默认行为（它是所有搜索测试的地基，行为不能悄悄变）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

void main() {
  group('injectBaseHref', () {
    test('有 <head> 时插在它后面（优先于页面自带的 base）', () {
      final out = injectBaseHref(
        '<html><head><title>t</title></head><body>x</body></html>',
        'https://a.example/book/1',
      );
      expect(
        out,
        startsWith('<html><head><base href="https://a.example/book/1">'),
      );
      // 原有内容一个不丢
      expect(out, contains('<title>t</title>'));
      expect(out, contains('<body>x</body>'));
    });

    test('<head> 带属性也能插对位置', () {
      final out = injectBaseHref(
        '<html><head profile="x"><meta charset="utf-8"></head></html>',
        'https://a.example/',
      );
      expect(
        out,
        contains('<head profile="x"><base href="https://a.example/">'),
      );
    });

    test('没有 <head> 但有 <html>：补一个 head', () {
      final out = injectBaseHref(
        '<html><body>hi</body></html>',
        'https://a.example',
      );
      expect(
        out,
        startsWith('<html><head><base href="https://a.example"></head>'),
      );
      expect(out, contains('<body>hi</body>'));
    });

    test('整段 HTML 碎片：包成完整文档', () {
      final out = injectBaseHref('<p>裸片段</p>', 'https://a.example');
      expect(out, contains('<base href="https://a.example">'));
      expect(out, contains('<body><p>裸片段</p></body>'));
    });

    test('baseUrl 为空：原样返回（不注入空 base）', () {
      const html = '<html><head></head></html>';
      expect(injectBaseHref(html, ''), html);
      expect(injectBaseHref(html, '   '), html);
    });

    test('baseUrl 里的引号 / & 被转义（不能破坏属性）', () {
      final out = injectBaseHref(
        '<html><head></head></html>',
        'https://a.example/x?a=1&b="2"',
      );
      expect(out, contains('href="https://a.example/x?a=1&amp;b=&quot;2&quot;"'));
    });
  });

  group('FakeRuleEngine 默认行为', () {
    test('默认抓取返回空 HTML，并记录 URL', () async {
      final engine = FakeRuleEngine();
      final html = await engine.fetchHtml('https://a.example/x');
      expect(html, contains('<html>'));
      expect(engine.fetchedUrls, ['https://a.example/x']);
    });

    test('默认求值返回空列表（不抛）', () async {
      final engine = FakeRuleEngine();
      final values = await engine.queryFields(
        html: '<html></html>',
        baseUrl: 'https://a.example',
        listSelector: parseSelector('@css:.book'),
        fieldSelector: null,
      );
      expect(values, isEmpty);
      expect(engine.queryCount, 1);
    });

    test('queryFieldMap 默认逐字段回落（每个字段一次 queryCount）', () async {
      final engine = FakeRuleEngine(
        onQuery: (html, list, field) async => ['v'],
      );
      final map = await engine.queryFieldMap(
        html: '<html></html>',
        baseUrl: 'https://a.example',
        listSelector: parseSelector('@css:.book'),
        fields: {
          'name': parseSelector('@css:.title'),
          'author': parseSelector('@css:.author'),
        },
      );
      expect(map.keys, ['name', 'author']);
      expect(map['name'], ['v']);
      expect(engine.queryCount, 2);
    });

    test('dispose 计数（页面 dispose 时能核对）', () async {
      final engine = FakeRuleEngine();
      await engine.dispose();
      expect(engine.disposeCount, 1);
    });
  });
}
