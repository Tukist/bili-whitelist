// 选择器语法测试（R2）。
//
// 被测对象是纯函数 [parseSelector]：它把用户抄来的规则串拆成结构化数据。
// 这里把「真实书源里见过的写法」尽量都过一遍 —— 解析错了，后面 JS 再多正确
// 也没用（那就是「规则看着没问题，但一句都搜不到」）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/selector.dart';

void main() {
  group('前缀识别', () {
    test('css: 与 @css: 都识别成 CSS 并去掉前缀', () {
      final a = parseSelector('css:#list dl dd a');
      expect(a.kind, SelectorKind.css);
      expect(a.query, '#list dl dd a');

      final b = parseSelector('@css:#list dl dd a');
      expect(b.kind, SelectorKind.css);
      expect(b.query, '#list dl dd a');
    });

    test('xpath 前缀三种大小写写法', () {
      for (final raw in [
        "xpath://div[@id='list']/dl/dd/a",
        "@XPath://div[@id='list']/dl/dd/a",
        "@xpath://div[@id='list']/dl/dd/a",
      ]) {
        final v = parseSelector(raw);
        expect(v.kind, SelectorKind.xpath, reason: raw);
        expect(v.query, "//div[@id='list']/dl/dd/a", reason: raw);
      }
    });

    test('无前缀但以 // 开头按 XPath 处理', () {
      final v = parseSelector("//div[@id='list']/dl/dd/a");
      expect(v.kind, SelectorKind.xpath);
      expect(v.query, "//div[@id='list']/dl/dd/a");
    });

    test('无前缀的普通串按 CSS 处理', () {
      final v = parseSelector('.book-item a');
      expect(v.kind, SelectorKind.css);
      expect(v.query, '.book-item a');
    });

    test('class. / id. / tag. 简写转成 CSS', () {
      expect(parseSelector('class.book-item').query, '.book-item');
      expect(parseSelector('class.book-item').kind, SelectorKind.css);
      expect(parseSelector('id.main').query, '#main');
      expect(parseSelector('tag.div').query, 'div');
      expect(parseSelector('tag.div').kind, SelectorKind.css);
    });

    test('regex: 保留正则原文（含反斜杠）', () {
      final v = parseSelector(r'regex:(\d+)\s*万字');
      expect(v.kind, SelectorKind.regex);
      expect(v.query, r'(\d+)\s*万字');
    });

    test('@json: 是 JSONPath，本批只解析不执行', () {
      final v = parseSelector(r'@json:$.data.books');
      expect(v.kind, SelectorKind.jsonPath);
      expect(v.query, r'$.data.books');
      // 认识但跑不了：R3 才接 JSON 接口源
      expect(v.isRunnable, isFalse);
      expect(v.needsJs, isFalse);
    });
  });

  group('取值后缀', () {
    test('默认取文本（attr 为 null）', () {
      final v = parseSelector('@css:.title');
      expect(v.attr, isNull);
      expect(v.getter, 'text');
    });

    test('@text 等价于默认', () {
      expect(parseSelector('@css:.title@text').attr, isNull);
    });

    test('@html', () {
      final v = parseSelector('@css:.intro@html');
      expect(v.query, '.intro');
      expect(v.attr, 'html');
    });

    test('@href / @src', () {
      final a = parseSelector('@css:a@href');
      expect(a.query, 'a');
      expect(a.attr, 'href');

      final b = parseSelector('@css:img@src');
      expect(b.attr, 'src');
    });

    test('@attr:NAME 只留属性名', () {
      final v = parseSelector('@css:li@attr:data-id');
      expect(v.query, 'li');
      expect(v.attr, 'data-id');
    });

    test('XPath 里的 @id / @class 不会被当成取值后缀切掉', () {
      final v = parseSelector(r"//div[@class='book'][@id='list']/a@href");
      expect(v.kind, SelectorKind.xpath);
      expect(v.query, r"//div[@class='book'][@id='list']/a");
      expect(v.attr, 'href');
    });

    test('只写后缀（@text）= 取节点自身', () {
      final v = parseSelector('@text');
      expect(v.kind, SelectorKind.self);
      expect(v.attr, isNull);
      expect(v.isRunnable, isTrue);

      final href = parseSelector('@href');
      expect(href.kind, SelectorKind.self);
      expect(href.attr, 'href');
    });

    test('简写 + 取值后缀', () {
      final v = parseSelector('class.book-item@href');
      expect(v.kind, SelectorKind.css);
      expect(v.query, '.book-item');
      expect(v.attr, 'href');
    });
  });

  group('##正则##替换', () {
    test('正则 + 替换文本', () {
      final v = parseSelector(r'@css:.title##\s+## ');
      expect(v.query, '.title');
      expect(v.suffixRegex, r'\s+');
      expect(v.suffixReplacement, ' ');
    });

    test(r'替换文本可用 $1', () {
      final v = parseSelector(r'@css:.word##(\d+)万字##$1万字');
      expect(v.suffixRegex, r'(\d+)万字');
      expect(v.suffixReplacement, r'$1万字');
    });

    test('只写正则（无替换）= 删掉匹配内容', () {
      final v = parseSelector(r'@css:.title##\(完本\)');
      expect(v.suffixRegex, r'\(完本\)');
      expect(v.suffixReplacement, isNull);
    });

    test('显式空替换与「无替换」不同', () {
      final v = parseSelector(r'@css:.title##广告##');
      expect(v.suffixReplacement, '');
    });

    test('后缀与取值后缀同时存在', () {
      final v = parseSelector(r'@css:a@href##^//##https://');
      expect(v.query, 'a');
      expect(v.attr, 'href');
      expect(v.suffixReplacement, 'https://');
    });
  });

  group('|| 回退链', () {
    test('两段回退', () {
      final v = parseSelector('@css:.a || @css:.b');
      expect(v.kind, SelectorKind.css);
      expect(v.query, '.a');
      expect(v.fallbacks.length, 1);
      expect(v.fallbacks.first.query, '.b');
    });

    test('三段回退（每段带自己的取值后缀）', () {
      final v = parseSelector('@css:.a@href || @css:.b@href || @css:.c@src');
      expect(v.fallbacks.length, 2);
      expect(v.fallbacks[0].attr, 'href');
      expect(v.fallbacks[1].attr, 'src');
      expect(v.query, '.a');
    });

    test('空分支被忽略', () {
      final v = parseSelector('.a ||  || .b');
      expect(v.fallbacks.length, 1);
      expect(v.fallbacks.first.query, '.b');
    });
  });

  group('空规则', () {
    test('null 与空白 → none（不取，不算错误）', () {
      for (final raw in [null, '', '   ', '\n\t']) {
        final v = parseSelector(raw);
        expect(v.kind, SelectorKind.none, reason: '$raw');
        expect(v.isEmpty, isTrue);
        expect(v.isUnsupported, isFalse);
      }
    });
  });

  group('JS 规则判 unsupported', () {
    test('<js>…</js>', () {
      final v = parseSelector('<js>java.getString("abc")</js>');
      expect(v.kind, SelectorKind.unsupported);
      expect(v.reason, kSelectorReasonJs);
      expect(v.needsJs, isTrue);
    });

    test('@js:', () {
      final v = parseSelector('@js:result.split("##")[0]');
      expect(v.needsJs, isTrue);
    });

    test('{{…}} 模板', () {
      final v = parseSelector('{{book.name}}');
      expect(v.kind, SelectorKind.unsupported);
      expect(v.reason, kSelectorReasonJs);
    });

    test('回退链里只要有一段是 JS，整条都不跑', () {
      // 跑半条等于给出半真半假的结果，不如明确说不支持
      final v = parseSelector('@css:.a || <js>x</js>');
      expect(v.needsJs, isTrue);
    });
  });

  group('异常与脏输入', () {
    test('含单引号的 XPath 原样保留', () {
      final v = parseSelector(r"""//div[@title="a'b"]/span""");
      expect(v.kind, SelectorKind.xpath);
      expect(v.query, r"""//div[@title="a'b"]/span""");
    });

    test('解析不出来的写法给 reason，不当异常', () {
      expect(parseSelector('css:').reason, kSelectorReasonEmpty);
      expect(parseSelector('@unknown:1').reason, kSelectorReasonSyntax);
      expect(parseSelector('@').kind, SelectorKind.unsupported);
    });

    test('任意脏输入都不抛异常', () {
      const dirty = [
        '||',
        '##',
        '@@',
        '@css:',
        'xpath:',
        '{{',
        '}}',
        '<js>',
        '@attr:',
        '\u0000\u0001',
        'css:###',
        'a || b ||',
      ];
      for (final raw in dirty) {
        // 只要求「不抛」，结果是哪个 kind 都行
        expect(() => parseSelector(raw), returnsNormally, reason: raw);
      }
    });

    test('raw 保留原文（报错时给用户看）', () {
      const raw = '  @css:.book  ';
      expect(parseSelector(raw).raw, '@css:.book');
    });
  });

  group('toString', () {
    test('调试输出带上 kind / query / getter', () {
      final s = parseSelector('@css:a@href').toString();
      expect(s, contains('css'));
      expect(s, contains('a'));
      expect(s, contains('href'));
    });
  });
}
