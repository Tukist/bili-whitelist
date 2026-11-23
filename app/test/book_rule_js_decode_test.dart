// JS 返回值解包测试（真机上踩出来的 bug 的回归钉）。
//
// 背景：`runJavaScriptReturningResult` 的返回层数**随平台变**——
// Android 会把字符串结果再 JSON 编码一层（外面多一对引号），我们的脚本自己
// 也 `JSON.stringify(...)`，于是 Android 上是两层、iOS 上是一层。
//
// 原来的实现只有正文抽取走「解一层」，把 `"\n\t\t\t<p>Alice…` 原样当正文
// 渲染出来（查询那条路碰巧是「解一层 + jsonDecode」= 两层，所以没暴露）。
// 这里把两种平台形态、两种载荷（数组 / HTML 字符串）都钉死。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';

void main() {
  group('decodeJsResultForTest', () {
    test('Android 双层：数组', () {
      final payload = jsonEncode(['甲', '乙', null]);
      // Android 在脚本返回值外面再套一层 JSON 编码
      final wire = jsonEncode(payload);
      expect(decodeJsResultForTest(wire), ['甲', '乙', null]);
    });

    test('iOS 单层：数组', () {
      final wire = jsonEncode(['甲', '乙', null]);
      expect(decodeJsResultForTest(wire), ['甲', '乙', null]);
    });

    test('Android 双层：HTML 字符串（正文那条路）', () {
      const html = '<p>Alice was beginning &amp; tired</p>\n<p>第二段</p>';
      final payload = jsonEncode(html); // 我们的脚本：JSON.stringify(innerHTML)
      final wire = jsonEncode(payload); // 平台再加一层
      final decoded = decodeJsResultForTest(wire);
      expect(decoded, html);
      // 关键断言：不能残留引号与 \n / \t 转义（原 bug 就是这个形态）
      expect(decoded.toString().contains(r'\n'), isFalse);
      expect(decoded.toString().startsWith('"'), isFalse);
    });

    test('iOS 单层：HTML 字符串', () {
      const html = '<p>Hello</p>';
      final wire = jsonEncode(html);
      expect(decodeJsResultForTest(wire), html);
    });

    test('JSON null → null', () {
      expect(decodeJsResultForTest('null'), isNull);
      expect(decodeJsResultForTest(jsonEncode('null')), isNull);
    });

    test('平台已经解好的 bool / num 原样返回', () {
      expect(decodeJsResultForTest(true), isTrue);
      expect(decodeJsResultForTest(42), 42);
    });

    test('不是 JSON 的文本原样返回（宁可显示原文也不吞掉）', () {
      expect(decodeJsResultForTest('plain text'), 'plain text');
      expect(decodeJsResultForTest(''), '');
    });

    test('只剥引号层，不误伤正文里的引号', () {
      const html = '<p>“Eat Me”</p>';
      final wire = jsonEncode(jsonEncode(html));
      expect(decodeJsResultForTest(wire), html);
    });
  });
}
