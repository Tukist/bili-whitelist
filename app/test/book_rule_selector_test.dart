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

  group('JS 规则判 js（I3a 起单独一个 kind）', () {
    // 设计契约变更（I3a）：`kind` 从 `unsupported` 改为 `js` —— JS 规则是
    // **认得**的，只是执行方式不同（要进静态沙箱）。派生语义一个字没变：
    // `isUnsupported` / `needsJs` 对 js 仍然为真，所以服务层行为不变。
    test('<js>…</js>', () {
      final v = parseSelector('<js>java.getString("abc")</js>');
      expect(v.kind, SelectorKind.js);
      expect(v.reason, kSelectorReasonJs);
      expect(v.isUnsupported, isTrue);
      expect(v.needsJs, isTrue);
      // 脚本正文与拦路石都带出来了（能力判定看 jsInfo，不在这里）
      expect(v.script, 'java.getString("abc")');
      expect(v.blockedApis, contains('java.getString'));
      expect(v.isStaticJsRunnable, isFalse);
    });

    test('@js:', () {
      final v = parseSelector('@js:result.split("##")[0]');
      expect(v.needsJs, isTrue);
      expect(v.kind, SelectorKind.js);
      expect(v.script, 'result.split("##")[0]');
      expect(v.isStaticJsRunnable, isTrue);
    });

    test('{{…}} 模板', () {
      final v = parseSelector('{{book.name}}');
      expect(v.kind, SelectorKind.js);
      expect(v.reason, kSelectorReasonJs);
      expect(v.script, 'book.name');
    });

    test('带前置选择器：baseSelector 能在原页面上取值', () {
      final v = parseSelector('@css:.item@href@js:result.split("#")[0]');
      expect(v.kind, SelectorKind.js);
      expect(v.script, 'result.split("#")[0]');
      expect(v.baseSelector, isNotNull);
      expect(v.baseSelector!.kind, SelectorKind.css);
      expect(v.baseSelector!.attr, 'href');
    });

    test('回退链里只要有一段是 JS，整条都不跑', () {
      // 跑半条等于给出半真半假的结果，不如明确说不支持
      final v = parseSelector('@css:.a || <js>x</js>');
      expect(v.needsJs, isTrue);
      expect(v.kind, SelectorKind.js);
      expect(v.isStaticJsRunnable, isFalse);
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

  // ==================== v2.77.0：链式 / 索引 / 并列 / 扩展取值 ====================
  //
  // 下面每条规则串都是**真实语料里抄的**（`app/tools/js_rule_audit.dart
  // --selectors` 对 2483 个去重源的统计），不是编出来的「理想形态」。
  // 括号里是这条写法在语料里出现的串数。
  group('链式 @A@B@C（v2.77.0）', () {
    test('class.grid@tag.tr!0：先 .grid，再在其下取 tr 并跳过第一个（54 串）', () {
      final v = parseSelector('class.grid@tag.tr!0');
      expect(v.kind, SelectorKind.css);
      expect(v.query, '.grid');
      expect(v.steps.length, 1);
      expect(v.steps.first.kind, SelectorKind.css);
      expect(v.steps.first.query, 'tr');
      // `!0` 是排除第一个（跳过表头那一行），不是「取第一个」
      expect(v.steps.first.indexes, [0]);
      expect(v.steps.first.indexExclude, isTrue);
      expect(v.isRunnable, isTrue);
    });

    test('id.info@tag.p.2@text##最后更新：：链 + 索引 + 取值后缀 + 清洗（35 串）', () {
      final v = parseSelector('id.info@tag.p.2@text##最后更新：');
      expect(v.query, '#info');
      expect(v.steps.single.query, 'p');
      expect(v.steps.single.indexes, [2]);
      expect(v.steps.single.indexExclude, isFalse);
      expect(v.attr, isNull); // @text = 默认取文本
      expect(v.suffixRegex, '最后更新：');
      expect(v.suffixReplacement, isNull); // 只写正则 = 删掉匹配
    });

    test('p.1@a.0@text：两段索引各自作用在自己那一段上', () {
      final v = parseSelector('p.1@a.0@text');
      expect(v.query, 'p');
      expect(v.indexes, [1]);
      expect(v.steps.single.query, 'a');
      expect(v.steps.single.indexes, [0]);
    });

    test('id.fmimg@tag.img@src：取值后缀只作用于链尾（56 串）', () {
      final v = parseSelector('id.fmimg@tag.img@src');
      expect(v.query, '#fmimg');
      expect(v.steps.single.query, 'img');
      expect(v.attr, 'src');
    });

    test('@a@text：链首多一个 @ = 从当前节点开始（3 个源）', () {
      final v = parseSelector('@a@text');
      expect(v.kind, SelectorKind.self);
      expect(v.steps.single.query, 'a');
      expect(v.steps.single.kind, SelectorKind.css);
    });

    test('回退链的每一支各自带自己的链（21 串）', () {
      final v = parseSelector(
        'class.book-img-text@tag.li||class.book-list-wrap@class.book-list@tag.li',
      );
      expect(v.query, '.book-img-text');
      expect(v.steps.single.query, 'li');
      expect(v.fallbacks.single.query, '.book-list-wrap');
      expect(v.fallbacks.single.steps.length, 2);
      expect(v.fallbacks.single.steps.first.query, '.book-list');
      expect(v.fallbacks.single.steps.last.query, 'li');
    });

    test('链上任一段不支持 → 整条不支持（不给半真半假的结果）', () {
      // v2.78.0 契约变更：`text.作者` 这一段现在**支持**了（textFilter），
      // 所以改用一段真正不可解析的（`regex:` 后面没有正则源）验证同一条铁律。
      final v = parseSelector('class.a@regex:@text');
      expect(v.kind, SelectorKind.unsupported);
      expect(v.isRunnable, isFalse);

      // `text.` 作为链式段时是 textFilter（不再整条判死）
      final filtered = parseSelector('class.a@text.作者');
      expect(filtered.kind, SelectorKind.css);
      expect(filtered.steps.single.kind, SelectorKind.textFilter);
      expect(filtered.steps.single.query, '作者');
      expect(filtered.isRunnable, isTrue);
    });
  });

  group('索引 .N / !N（v2.77.0）', () {
    test('.N 是「选中」，!N 是「排除」—— 两者语义相反', () {
      final pick = parseSelector('tag.td.0@tag.a@href');
      expect(pick.indexes, [0]);
      expect(pick.indexExclude, isFalse);

      final skip = parseSelector('tag.tr!0');
      expect(skip.indexes, [0]);
      expect(skip.indexExclude, isTrue);
    });

    test('多索引用 : 分隔（class.listmain@dd!0:1:2 这类写法）', () {
      final v = parseSelector('class.listmain@dd!0:1:2:3');
      expect(v.steps.single.query, 'dd');
      expect(v.steps.single.indexes, [0, 1, 2, 3]);
      expect(v.steps.single.indexExclude, isTrue);
    });

    test('负数索引（从末尾数）', () {
      final v = parseSelector('div.-1');
      expect(v.query, 'div');
      expect(v.indexes, [-1]);
      expect(v.indexExclude, isFalse);
    });

    test('索引在列表规则上同样生效（class.vrResult!0）', () {
      final v = parseSelector('class.vrResult!0');
      expect(v.query, '.vrResult');
      expect(v.indexes, [0]);
      expect(v.indexExclude, isTrue);
    });

    test('索引与取值后缀共存：a.2@title（取第 3 个 a 的 title 属性）', () {
      final v = parseSelector('a.2@title');
      expect(v.query, 'a');
      expect(v.indexes, [2]);
      expect(v.attr, 'title');
    });
  });

  group('&& 并列（v2.77.0，622 个源）', () {
    test('[property=og:novel:category]@content&&[property=og:novel:status]@content', () {
      final v = parseSelector(
        '[property=og:novel:category]@content&&[property=og:novel:status]@content',
      );
      expect(v.kind, SelectorKind.css);
      expect(v.query, '[property=og:novel:category]');
      expect(v.attr, 'content');
      expect(v.concat.length, 1);
      expect(v.concat.single.query, '[property=og:novel:status]');
      expect(v.concat.single.attr, 'content');
      expect(v.isRunnable, isTrue);
    });

    test('三段并列 + 段间空格（真实语料里就这么写）', () {
      final v = parseSelector('[property=og:novel:update_time]@content&& '
          '[property=og:novel:category]@content&& '
          '[property=og:novel:status]@content');
      expect(v.concat.length, 2);
      expect(v.concat.first.query, '[property=og:novel:category]');
      expect(v.concat.last.query, '[property=og:novel:status]');
    });

    test('&& 的每一支可以带自己的链与索引', () {
      final v = parseSelector(
        'class.info@class.fix@tag.p.1@text&&class.info@class.fix@tag.p.2@text',
      );
      expect(v.query, '.info');
      expect(v.concat.single.steps.length, 2);
      expect(v.concat.single.steps.last.indexes, [2]);
    });

    test('|| 与 && 同时出现时先拆 ||（回退优先）', () {
      final v = parseSelector('class.a@text&&class.b@text||class.c@text');
      expect(v.query, '.a');
      expect(v.concat.single.query, '.b');
      expect(v.fallbacks.single.query, '.c');
    });
  });

  group('取值后缀扩展（v2.77.0）', () {
    test('@content：legado 的最后一段就是属性名（2382 串）', () {
      final v = parseSelector('[property=og:novel:book_name]@content');
      expect(v.query, '[property=og:novel:book_name]');
      expect(v.attr, 'content');
    });

    test('@ownText / @textNodes / @all 走 legado 的三个特殊取值', () {
      expect(parseSelector('class.brief@ownText').attr, 'ownText');
      expect(parseSelector('li.1@textNodes').attr, 'textNodes');
      expect(parseSelector('div.info@all').attr, 'all');
    });

    test('裸标签名不当属性，当链式段（class.txt-list@li = 取 li，347 串）', () {
      final v = parseSelector('class.txt-list@li');
      expect(v.query, '.txt-list');
      expect(v.attr, isNull);
      expect(v.steps.single.query, 'li');
    });

    test('XPath 的属性轴 /@content 不切后缀（13 串）', () {
      final v = parseSelector("//meta[@property='og:novel:book_name']/@content");
      expect(v.kind, SelectorKind.xpath);
      expect(v.query, "//meta[@property='og:novel:book_name']/@content");
      expect(v.attr, isNull);
      expect(v.steps, isEmpty);
    });

    test('##…##替换### = 只替换第一个（legado 的第四个字段）', () {
      final v =
          parseSelector(r'##data-bid="([^"]+)"##https://m.qidian.com/book/$1###');
      expect(v.kind, SelectorKind.self); // 只有清洗 → 取当前节点文本
      expect(v.suffixRegex, r'data-bid="([^"]+)"');
      expect(v.suffixReplacement, r'https://m.qidian.com/book/$1');
      expect(v.suffixReplaceFirst, isTrue);
    });
  });

  group('children（v2.77.0）', () {
    test('class.shu_cont@children = 该节点的直接子元素', () {
      final v = parseSelector('class.shu_cont@children');
      expect(v.query, '.shu_cont');
      expect(v.steps.single.kind, SelectorKind.children);
      expect(v.isRunnable, isTrue);
    });

    test('单独写 children 也是取子元素', () {
      expect(parseSelector('children').kind, SelectorKind.children);
    });
  });

  group('text. / %%：v2.78.0 起真支持', () {
    // 设计契约变更（v2.78.0）：v2.77.0 这里断言的是「kind=unsupported +
    // reason=text/interleave」。I3b 按 legado 源码把两者实现出来
    // （`getElementsContainingOwnText` / 按行交错），断言随之改成「能跑」
    // 并钉住解析结果 —— 是改写，不是删掉。
    test('text.xxx 按自身文字筛元素（36 个源）', () {
      final v = parseSelector('text.作者：@text');
      expect(v.kind, SelectorKind.textFilter);
      expect(v.query, '作者：');
      expect(v.isRunnable, isTrue);
      expect(v.needsJs, isFalse);
      // 只取第一个 `.` 之后的那一段：legado 是 `beforeRule.split(".")[1]`
      expect(parseSelector('text.a.b').query, 'a');
      // 空的 needle 是语法错，不当「筛任意文字」
      expect(parseSelector('text.').kind, SelectorKind.unsupported);
    });

    test('%% 交叉合并：其余各支挂在 interleave 上（5 个源）', () {
      final v = parseSelector('tag.td.2@tag.a@text%%tag.td.4@text');
      expect(v.kind, SelectorKind.css);
      expect(v.interleave.length, 1);
      expect(v.interleave.single.query, 'td');
      expect(v.interleave.single.indexes, [4]);
      expect(v.isRunnable, isTrue);
      // `%%` 与 `&&` 同时出现时按「先出现的那个」切（legado elementsType 口径）
      final andFirst = parseSelector('a && b %% c');
      expect(andFirst.concat.length, 1);
      expect(andFirst.interleave, isEmpty);
    });

    test('@get:{x} 依赖 java.put 的变量表 → 算「需要 JS」', () {
      final v = parseSelector('@get:{n}');
      expect(v.needsJs, isTrue);
    });
  });
}
