// 静态 JS 规则内核（I3a）：分类器 / 脚本生成 / 结果解析。
//
// `flutter test` 里没有 JS 引擎，所以这里只钉**文本与纯函数**：
// - 分类器认得三种写法、能挑出前置选择器、能列出白名单外的 API；
// - 生成的 runner 脚本包含必需的结构（`result` 绑定、`try/catch`、JSON 转义）；
// - 返回载荷（含 Android 的多层引号）能解成四种状态。
//
// 白名单函数的**实算结果**不在这里验（Dart 侧没有 JS 引擎）：I3a 用 `node`
// 把生成的脚本跑了一遍，对照 `crypto` 的 md5 / base64 与真实时间戳，记录见
// DEV_CONTEXT 的 I3a 条目；这里有 node 时也可以重跑
// `dart run app/tools/js_rule_audit.dart` 之外的手工脚本（不入库）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/js_rule.dart';

void main() {
  group('classifyJsRule：三种写法', () {
    test('<js>…</js>', () {
      final info = classifyJsRule('<js>result = result + "!"</js>');
      expect(info.form, JsRuleForm.tag);
      expect(info.isJs, isTrue);
      expect(info.script, 'result = result + "!"');
      expect(info.baseSelectorRaw, isNull);
      expect(info.runnable, isTrue);
    });

    test('@js: 前缀（无前置选择器）', () {
      final info = classifyJsRule('@js:result.split("##")[0]');
      expect(info.form, JsRuleForm.prefix);
      expect(info.script, 'result.split("##")[0]');
      expect(info.baseSelectorRaw, isNull);
      expect(info.runnable, isTrue);
    });

    test('规则位置上的 {{…}} 是表达式模板', () {
      final info = classifyJsRule('{{book.name}}');
      expect(info.form, JsRuleForm.template);
      expect(info.script, 'book.name');
      expect(info.runnable, isTrue);
    });

    test('空串 / 纯空白 / 普通选择器都不是 JS', () {
      for (final raw in ['', '   ', 'class.book@text', '@css:.a@href']) {
        final info = classifyJsRule(raw);
        expect(info.isJs, isFalse, reason: raw);
        expect(info.runnable, isFalse, reason: raw);
      }
    });
  });

  group('classifyJsRule：带前置选择器', () {
    test('@css:.item@href@js:… 能拆出 base 与脚本', () {
      final info = classifyJsRule('@css:.item@href@js:result.split("#")[0]');
      expect(info.form, JsRuleForm.prefix);
      expect(info.baseSelectorRaw, '@css:.item@href');
      expect(info.script, 'result.split("#")[0]');
      expect(info.runnable, isTrue);
    });

    test('<js> 前面也允许有前置选择器', () {
      final info = classifyJsRule('class.title@text<js>result.trim()</js>');
      expect(info.form, JsRuleForm.tag);
      expect(info.baseSelectorRaw, 'class.title@text');
      expect(info.script, 'result.trim()');
    });

    test('前置选择器带 || / && 时判不可跑（半截回退链查出来是错值）', () {
      final a = classifyJsRule('@css:.a || <js>x</js>');
      expect(a.isJs, isTrue);
      expect(a.baseIsSimple, isFalse);
      expect(a.runnable, isFalse);

      final b = classifyJsRule('@css:.a && <js>x</js>');
      expect(b.runnable, isFalse);
    });

    test('模板后面还有别的文字也不跑（只看第一段表达式会漏掉后半条）', () {
      final info = classifyJsRule('{{book.name}}/extra');
      expect(info.form, JsRuleForm.template);
      expect(info.runnable, isFalse);
    });
  });

  group('classifyJsRule：白名单与拦路石', () {
    test('白名单内的函数不产生 blockedApis', () {
      final info = classifyJsRule(
        '<js>result = java.md5Encode(java.base64Decode(result))</js>',
      );
      expect(info.blockedApis, isEmpty);
      expect(info.runnable, isTrue);
    });

    test('白名单外的 java.* 逐个列出（ajax / getElements / getString）', () {
      final info = classifyJsRule(
        '@js:java.ajax("/api?q=" + java.getString("a"))',
      );
      expect(info.blockedApis, containsAll(['java.ajax', 'java.getString']));
      expect(info.needsVariables, isTrue); // getString 需要 DOM 桥
      expect(info.runnable, isFalse);
    });

    test('Packages. 与 org.jsoup 单列（大小写按腿写的原样）', () {
      final a = classifyJsRule('<js>var n = Packages.net.x.Http.get(url)</js>');
      expect(a.blockedApis, contains('Packages'));
      expect(a.runnable, isFalse);

      final b = classifyJsRule('<js>var d = org.jsoup.Jsoup.parse(html)</js>');
      expect(b.blockedApis, contains('org.jsoup'));
      expect(b.runnable, isFalse);
    });

    test('浏览器网络接口也算拦路石（fetch / XMLHttpRequest）', () {
      final a = classifyJsRule('<js>fetch("https://x.example")</js>');
      expect(a.blockedApis, contains('fetch'));

      final b = classifyJsRule('<js>new XMLHttpRequest()</js>');
      expect(b.blockedApis, contains('XMLHttpRequest'));
    });

    test('java.put / java.get 是变量表：needsVariables 且不可跑', () {
      final info = classifyJsRule('<js>java.put("k", "v"); result = "x"</js>');
      expect(info.blockedApis, contains('java.put'));
      expect(info.needsVariables, isTrue);
      expect(info.runnable, isFalse);
    });

    test('@get: / @put: 没有脚本，也算「需要 JS 但跑不了」', () {
      final info = classifyJsRule('@get:{n}');
      expect(info.form, JsRuleForm.variables);
      expect(info.needsVariables, isTrue);
      expect(info.hasScript, isFalse);
      expect(info.runnable, isFalse);
    });

    test('空脚本不可跑（`@js:` 后面什么都没有）', () {
      final info = classifyJsRule('@js:');
      expect(info.isJs, isTrue);
      expect(info.hasScript, isFalse);
      expect(info.runnable, isFalse);
    });

    test('summary 说人话（给 UI / 日志看）', () {
      expect(classifyJsRule('@js:java.ajax("x")').summary, contains('java.ajax'));
      expect(classifyJsRule('@get:{n}').summary, contains('变量表'));
      expect(classifyJsRule('<js>result + "1"</js>').summary, contains('可以静态执行'));
    });
  });

  group('blockedApisIn：只扫白名单外的', () {
    test('白名单全在内 → 空', () {
      expect(
        blockedApisIn('java.base64Encode( java.md5Encode16("x") ) '
            'java.timeFormat(1) java.htmlFormat("a") java.log(1) '
            'java.strToBytes("b") java.bytesToStr([1]) '
            'java.base64Decode("c") java.md5Encode("d")'),
        isEmpty,
      );
    });

    test('保序去重，且 java. 与空格混写也认', () {
      expect(
        blockedApisIn('java.ajax(1); java . ajax(2); java.post(3)'),
        ['java.ajax', 'java.post'],
      );
    });

    test('白名单只认函数名，不认前缀混淆（java.ajaxEncode 仍被拦）', () {
      expect(blockedApisIn('java.ajaxEncode(1)'), ['java.ajaxEncode']);
    });

    test('kBlockedJsGlobals 里的每个名字都真的能被扫出来（防两处漂移）', () {
      for (final name in kBlockedJsGlobals) {
        final sample = switch (name) {
          'XMLHttpRequest' => 'new XMLHttpRequest()',
          'WebSocket' => 'new WebSocket("ws://x")',
          'EventSource' => 'new EventSource("/s")',
          _ => '$name("/x", 1)',
        };
        expect(blockedApisIn(sample), contains(name), reason: name);
      }
    });
  });

  group('blockedApisIn：DOM 桥与没绑定的属性（v2.78.0）', () {
    // 语料统计（503 个 jsTransformOnly 源）：result.match 235 / replace 95 /
    // split 18 是字符串方法，必须放行；select 3 / parentNode 2 / text 2 /
    // attr 1 是 jsoup Element 上的操作，浏览器里没有对应物。
    test('字符串方法一律放行（拦了就白丢源）', () {
      for (final script in [
        'result.match(/(\\d+)/)[1]',
        'result.replace(/a/g, "")',
        'result.split("##")[0]',
        'result.includes("x")',
        'result.indexOf("x")',
        'result.trim()',
      ]) {
        expect(blockedApisIn(script), isEmpty, reason: script);
      }
    });

    test('result 上的 DOM 方法被点名拦下', () {
      expect(blockedApisIn('result.select("em")'), contains('result.select'));
      expect(blockedApisIn('result.parentNode()'), contains('result.parentNode'));
      expect(blockedApisIn('result.text()'), contains('result.text'));
      expect(blockedApisIn('result.attr("title")'), contains('result.attr'));
    });

    test('book / source / chapter 上没绑定的属性被拦（避免拼出 xundefined）', () {
      expect(blockedApisIn('book.name + book.origin'), isEmpty);
      expect(blockedApisIn('book.intro'), contains('book.intro'));
      expect(blockedApisIn('source.getKey()'), isEmpty);
      expect(blockedApisIn('source.getVariable("a")'),
          contains('source.getVariable'));
      expect(blockedApisIn('chapter.title'), isEmpty);
      expect(blockedApisIn('chapter.index'), contains('chapter.index'));
    });

    test('cookie / cache / eval 一律拦（legado 的存储对象与逃生门）', () {
      expect(blockedApisIn('cookie.removeCookie(url)'), contains('cookie'));
      expect(blockedApisIn('cache.put("a", "b")'), contains('cache'));
      expect(blockedApisIn('eval(String(source.bookSourceComment))'),
          contains('eval'));
    });
  });

  group('classifyJsRule：{{…}} 里是规则还是表达式（v2.78.0）', () {
    test('表达式模板可跑（book.name 不能被当成 CSS 的 div.a）', () {
      final info = classifyJsRule('{{book.name}}');
      expect(info.templateIsRule, isFalse);
      expect(info.runnable, isTrue);
      expect(classifyJsRule('{{book.name + "（完）"}}').runnable, isTrue);
      expect(classifyJsRule("{{'点击地址栏下载📥'}}").runnable, isTrue);
    });

    test('嵌套选择器规则判不可跑并说明（语料 76 个源这样写 intro）', () {
      for (final raw in [
        '{{@@id.intro@text}}',
        '{{[property="og:description"]@content}}',
        '{{class.a@tag.p@html}}',
        '{{text.字数@text}}',
        '{{##正则##替换}}',
      ]) {
        final info = classifyJsRule(raw);
        expect(info.templateIsRule, isTrue, reason: raw);
        expect(info.runnable, isFalse, reason: raw);
        expect(info.blockReason, 'templateRule', reason: raw);
        expect(info.summary, contains('嵌套选择器'));
      }
    });

    test('blockReason 给审计工具分档（ajax 由调用方按 blockedApis 再细分）', () {
      expect(classifyJsRule('@js:java.ajax("/x")').blockReason, 'api');
      expect(classifyJsRule('@get:{n}').blockReason, 'variables');
      expect(classifyJsRule('@js:').blockReason, 'empty');
      expect(classifyJsRule('@css:.a || <js>x</js>').blockReason, 'base');
      expect(classifyJsRule('@js:result + "1"').blockReason, isNull);
    });

    test('死循环脚本静态拦下（v2.78.0 实机踩到：会把整个 WebView 卡死）', () {
      for (final raw in [
        '<js>while(true){}</js>',
        '<js>while ( 1 ) { }</js>',
        '<js>for(;;){}</js>',
      ]) {
        final info = classifyJsRule(raw);
        expect(info.hasDeadLoop, isTrue, reason: raw);
        expect(info.runnable, isFalse, reason: raw);
        expect(info.blockReason, 'deadLoop', reason: raw);
        expect(info.summary, contains('死循环'), reason: raw);
      }
      expect(hasObviousDeadLoop('while(true){}'), isTrue);
      // 普通循环不误伤
      expect(classifyJsRule('<js>for(var i=0;i<3;i++){}</js>').runnable, isTrue);
      expect(
        classifyJsRule('<js>var t=Date.now(); while(Date.now()-t<200){}</js>')
            .hasDeadLoop,
        isFalse,
      );
    });
  });

  group('buildJsRunnerFactory：两种脚本形态都能跑（v2.78.0）', () {
    test('优先用 eval 取「最后一条语句的值」（legado 的脚本语义）', () {
      final js = buildJsRunnerFactory(script: "'https://m.x' + result");
      expect(js, contains('eval(__src)'));
      expect(js, contains('typeof __v === "undefined"'));
      // 表达式没赋值时也要能拿到值，退回 new Function 只是兜底
      expect(js, contains('new Function('));
    });

    test('有 return 的脚本走 new Function（eval 里 return 非法）', () {
      final js = buildJsRunnerFactory(script: 'return result + "!"');
      expect(js, contains(r'\n;\nreturn result;'));
    });
  });

  group('buildJsRunnerScript：结构', () {
    test('绑定 result / book / baseUrl / key / page，并有 try/catch', () {
      final js = buildJsRunnerScript(
        script: 'result = book.name',
        bindings: {
          'book': '书名',
          'baseUrl': 'https://a.example',
          'key': '凡人',
          'page': '2',
        },
        initialResult: '前置',
      );
      expect(js, startsWith('(function(){'));
      expect(js.trimRight(), endsWith('})();'));
      expect(js, contains('var result = "前置";'));
      expect(js, contains('var book = {"name": "书名"};'));
      expect(js, contains('var baseUrl = "https://a.example";'));
      expect(js, contains('var key = "凡人";'));
      expect(js, contains('var page = "2";'));
      expect(js, contains('try {'));
      expect(js, contains('} catch (e) {'));
      // 结果用 JSON.stringify 带回来，空值走 null 而不是空串
      expect(js, contains('JSON.stringify({ok:true, value:'));
      expect(js, contains('"undefined") ? null : String(result)'));
      expect(js, contains('JSON.stringify({ok:false, error:'));
    });

    test('initialResult 为空时绑定成 null（不是空串）', () {
      final js = buildJsRunnerScript(script: 'result = "x"', bindings: const {});
      expect(js, contains('var result = null;'));
    });

    test('脚本用 jsonEncode 拼进 new Function（引号 / 换行 / </script> 都不破坏脚本）', () {
      const script = 'result = "a\\"b" + \'\\n\' + \'</script>\'';
      final js = buildJsRunnerScript(script: script, bindings: const {});
      expect(js, contains('new Function('));
      // 脚本整体是一个 JSON 字符串字面量：引号被转义，`</script>` 原样留着
      // （我们不是拼 HTML，是 runJavaScript，不存在把标签当结束标记的问题）
      expect(js, contains(r'\"b\"'));
      expect(js, contains('</script>'));
      expect(js, contains(r'\n'));
      // 末尾自动补 return result;，且与脚本之间有一个换行（防末行注释吃掉分号）
      expect(js, contains(r'\n;\nreturn result;'));
    });

    test('模板模式把正文包成表达式', () {
      final js = buildJsRunnerScript(
        script: 'book.name + "|" + result',
        bindings: const {'book': '书名'},
        initialResult: 'v',
        asExpression: true,
      );
      expect(js, contains(r'result = (book.name + \"|\" + result);'));
    });

    test('java 对象只暴露白名单函数（ajax 之类根本没定义）', () {
      final js = buildJsRunnerScript(script: 'result = 1', bindings: const {});
      for (final name in kSupportedJavaApis) {
        expect(js, contains('$name: function('), reason: name);
      }
      expect(js, isNot(contains('ajax: function(')));
      expect(js, isNot(contains('getString: function(')));
      expect(js, isNot(contains('put: function(')));
    });

    test('非法绑定名不会拼出语法错误的脚本', () {
      final js = buildJsRunnerScript(
        script: 'result = 1',
        bindings: const {'bad name': 'x'},
      );
      expect(js, contains('var __ignored = "x";'));
    });
  });

  group('parseJsRunOutput：四种状态', () {
    test('成功（带 logs / warnings）', () {
      final out = parseJsRunOutput(
        jsonEncode({
          'ok': true,
          'value': '书名',
          'logs': ['hi'],
          'warnings': ['w'],
        }),
      );
      expect(out.ok, isTrue);
      expect(out.value, '书名');
      expect(out.error, isNull);
      expect(out.logs, ['hi']);
      expect(out.warnings, ['w']);
    });

    test('成功但结果为空：value 是 null', () {
      final out = parseJsRunOutput('{"ok":true,"value":null}');
      expect(out.ok, isTrue);
      expect(out.value, isNull);
      expect(out.logs, isEmpty);
    });

    test('脚本报错：ok=false + 原因', () {
      final out = parseJsRunOutput('{"ok":false,"error":"boom"}');
      expect(out.ok, isFalse);
      expect(out.value, isNull);
      expect(out.error, 'boom');
    });

    test('Android 的多层引号（evaluateJavascript 再编码一次）也能剥', () {
      const inner = '{"ok":true,"value":"中文"}';
      // 平台会把整段 JSON 字符串再编码一层：外面是带引号的 JSON 字符串
      final platform = jsonEncode(inner);
      final out = parseJsRunOutput(platform);
      expect(out.ok, isTrue);
      expect(out.value, '中文');
    });

    test('不是 JSON 对象时给可读错误，不抛异常', () {
      for (final raw in [null, 42, 'null', 'not json', '[]']) {
        final out = parseJsRunOutput(raw);
        expect(out.ok, isFalse, reason: '$raw');
        expect(out.error, isNotEmpty, reason: '$raw');
      }
    });

    test('ok=false 但没有 error 时给兜底文案', () {
      expect(parseJsRunOutput('{"ok":false}').error, contains('未给出原因'));
    });
  });

  group('blockedApisMessage', () {
    test('全是 java.* 时说「Java API」', () {
      expect(
        blockedApisMessage(['java.ajax', 'java.getElements']),
        '这条规则用了本版不支持的 Java API：java.ajax、java.getElements',
      );
    });

    test('含浏览器接口时说「接口」（别让用户去找不存在的 Java 函数）', () {
      final msg = blockedApisMessage(['java.ajax', 'fetch']);
      expect(msg, contains('不支持的接口'));
      expect(msg, isNot(contains('Java API')));
    });
  });

  group('白名单常量', () {
    test('只做纯函数：不含 ajax / put / get / getString / getElements', () {
      expect(kSupportedJavaApis, isNot(contains('ajax')));
      expect(kSupportedJavaApis, isNot(contains('put')));
      expect(kSupportedJavaApis, isNot(contains('get')));
      expect(kSupportedJavaApis, isNot(contains('getString')));
      expect(kSupportedJavaApis, isNot(contains('getElements')));
      // log 只记日志、不发网络，算在内
      expect(kSupportedJavaApis, contains('log'));
    });
  });
}
