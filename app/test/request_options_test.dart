// legado「地址 + 请求选项」解析与 `{{…}}` 模板求值（I4，纯函数为主）。
//
// 这一批最贵的一课是**不要把整串当 URL**：语料里 617 个 `searchUrl` 写成
// `"…?q={{key}},{"method":"POST",…}"`（另有 99 个 ,{ 后不是合法 JSON），
// 以前拼出来的地址带花括号、发出去必错。数字口径见 `docs/DEV_CONTEXT.md`
// 与 `tools/js_rule_audit.dart` 表⑨（以审计工具实跑为准）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/request_options.dart';

void main() {
  group('parseRequestSpec', () {
    test('没有选项：整串就是地址，GET', () {
      final spec = parseRequestSpec('https://a.example/search?q={{key}}');
      expect(spec.url, 'https://a.example/search?q={{key}}');
      expect(spec.method, 'GET');
      expect(spec.hasOptions, isFalse);
      expect(spec.body, isNull);
      expect(spec.headers, isEmpty);
      expect(spec.warning, isNull);
    });

    test('POST + body + charset', () {
      final spec = parseRequestSpec(
        'https://a.example/search,{"method":"POST",'
        '"body":"searchkey={{key}}&searchtype=all","charset":"gbk"}',
      );
      expect(spec.url, 'https://a.example/search');
      expect(spec.method, 'POST');
      expect(spec.isPost, isTrue);
      expect(spec.body, 'searchkey={{key}}&searchtype=all');
      expect(spec.charset, 'gbk');
      expect(spec.hasOptions, isTrue);
      expect(spec.warning, isNull);
    });

    test('method 大小写不敏感', () {
      expect(parseRequestSpec('/s,{"method":"post"}').method, 'POST');
      expect(parseRequestSpec('/s,{"method":"Post"}').method, 'POST');
      expect(parseRequestSpec('/s,{"method":"get"}').method, 'GET');
    });

    test('headers 转成 String→String（数字也收）', () {
      final spec = parseRequestSpec(
        '/s,{"headers":{"Referer":"https://a.example/","X-N":1}}',
      );
      expect(spec.headers, {'Referer': 'https://a.example/', 'X-N': '1'});
      expect(spec.method, 'GET');
    });

    test('webView / type 记录但不当真（本版忽略）', () {
      final spec = parseRequestSpec(
        '/s,{"webView":true,"type":"json","method":"GET"}',
      );
      expect(spec.webView, isTrue);
      expect(spec.type, 'json');
      expect(spec.method, 'GET');
    });

    test('URL 自身带逗号与花括号：按**最后一个** `,{` 切', () {
      final spec = parseRequestSpec(
        '/s?q=a,{"junk":1}, {"method":"POST","body":"b=1"}',
      );
      // 第一个 `,{` 后面不是合法 JSON（尾巴多了 `, {…}`），被跳过；
      // 真正切在最后一个 `, {` 上，地址里保留逗号与花括号
      expect(spec.url, '/s?q=a,{"junk":1}');
      expect(spec.method, 'POST');
      expect(spec.body, 'b=1');
    });

    test('坏 JSON：退回「整串当地址」并给 warning（不报错）', () {
      const raw = 'https://a.example/s,{"method":POST}';
      final spec = parseRequestSpec(raw);
      expect(spec.url, raw);
      expect(spec.method, 'GET');
      expect(spec.warning, contains('不是合法 JSON'));
    });

    test('不支持的方法退回 GET 并给 warning', () {
      final spec = parseRequestSpec('/s,{"method":"PUT"}');
      expect(spec.method, 'GET');
      expect(spec.warning, contains('PUT'));
    });

    test('整条地址是 JS 时不拆选项（选项可能是脚本的一部分）', () {
      const raw = r'@js:url=baseUrl+"/s?q="+key+",{""method"":""GET""}"';
      final spec = parseRequestSpec(raw);
      expect(spec.url, raw);
      expect(spec.hasOptions, isFalse);
      expect(spec.warning, isNull);
    });

    test('空串 / 空白', () {
      expect(parseRequestSpec('').url, '');
      expect(parseRequestSpec('   ').url, '');
    });
  });

  group('applyUrlPlaceholders', () {
    test('{{key}} 做 URL 编码，{{page}} 不编码', () {
      expect(
        applyUrlPlaceholders('/s?q={{key}}&p={{page}}', keyword: '斗 罗', page: 3),
        '/s?q=%E6%96%97%20%E7%BD%97&p=3',
      );
    });

    test('{{searchPage}} / {{searchKey}} 也算页码', () {
      expect(
        applyUrlPlaceholders('/s?p={{searchPage}}&s={{ searchKey }}', page: 2),
        '/s?p=2&s=2',
      );
    });

    test('{{baseUrl}} 替换成站点根（不编码）', () {
      expect(
        applyUrlPlaceholders('{{baseUrl}}/search?q={{key}}',
            keyword: 'a', baseUrl: 'https://m.example'),
        'https://m.example/search?q=a',
      );
    });

    test('%s 只替换第一个', () {
      expect(applyUrlPlaceholders('/s?q=%s&x=%s', keyword: 'ab'), '/s?q=ab&x=%s');
    });

    test('{{tab}} 原样保留（页签语义，本版不支持）', () {
      expect(
        applyUrlPlaceholders('/s?t={{tab}}&q={{key}}', keyword: 'x'),
        '/s?t={{tab}}&q=x',
      );
    });

    // ---- 请求体模板：关键词是「值本身」，不编码 ----
    //
    // JSON 体 `{"q":"{{key}}"}` 编码后会变成 `{"q":"%E6%96%97%E7%BD%97"}`，
    // 站点拿到的值是一串百分号；表单体同理。更糟的是编码后 body 变成纯 ASCII，
    // 引擎里「body 含中文 + 声明 GBK → 拒绝」的守卫永远不触发。

    test('encodeKeyword: false 时 {{key}} 保持原文（body 用）', () {
      expect(
        applyUrlPlaceholders('{"q":"{{key}}","p":{{page}}}',
            keyword: '斗 罗', page: 2, encodeKeyword: false),
        '{"q":"斗 罗","p":2}',
      );
      // 老式 %s 同样不编码
      expect(
        applyUrlPlaceholders('q=%s&x=%s', keyword: '斗罗', encodeKeyword: false),
        'q=斗罗&x=%s',
      );
    });

    test('默认（地址）仍然编码 —— 两条规则不能混', () {
      expect(
        applyUrlPlaceholders('/s?q={{key}}', keyword: '斗罗'),
        '/s?q=%E6%96%97%E7%BD%97',
      );
    });
  });

  group('applyUrlTemplate', () {
    test('JS 表达式求值后原样拼接（不编码）', () async {
      final out = await applyUrlTemplate(
        '/s?p={{page-1}}&q={{book.name}}&b={{baseUrl}}',
        baseUrl: 'https://a.example',
        page: 3,
        bindings: {'page': '3', 'book': '斗 罗'},
        evalJs: (script, bindings) async {
          expect(bindings['page'], '3');
          // `{{baseUrl}}` 是白名单占位符，不会进这里
          if (script == 'page-1') return '2';
          if (script == 'book.name') return '斗 罗';
          return '';
        },
      );
      expect(out.ok, isTrue);
      // JS 结果原样拼接（legado 也不编码），`{{baseUrl}}` 同步替换
      expect(out.url, '/s?p=2&q=斗 罗&b=https://a.example');
    });

    test('求值器缺失 → 明确报「需要执行引擎」', () async {
      final out = await applyUrlTemplate('/s?p={{page-1}}', baseUrl: '');
      expect(out.ok, isFalse);
      expect(out.error, contains('需要执行引擎'));
    });

    test('脚本访问 document → 明确说不能访问页面', () async {
      final out = await applyUrlTemplate(
        '/s?p={{document.querySelector("a")}}',
        baseUrl: '',
        evalJs: (_, __) async => 'x',
      );
      expect(out.ok, isFalse);
      expect(out.error, contains('不能访问页面'));
    });

    test('求值为空 → 报错（不发半截请求）', () async {
      final out = await applyUrlTemplate(
        '/s?p={{book.name}}',
        baseUrl: '',
        evalJs: (_, __) async => '   ',
      );
      expect(out.ok, isFalse);
      expect(out.error, contains('求值为空'));
    });

    test('求值抛异常 → 报错并带上原因', () async {
      final out = await applyUrlTemplate(
        '/s?p={{page+1}}',
        baseUrl: '',
        evalJs: (_, __) async => throw StateError('沙箱超时'),
      );
      expect(out.ok, isFalse);
      expect(out.error, contains('沙箱超时'));
    });

    test('整条地址是 <js> / @js: → 报不支持', () async {
      for (final raw in [
        '<js>baseUrl + "/s?q=" + key</js>',
        r'@js:baseUrl + "/s?q=" + key',
      ]) {
        final out = await applyUrlTemplate(raw,
            baseUrl: 'https://a.example', evalJs: (_, __) async => 'x');
        expect(out.ok, isFalse, reason: raw);
        expect(out.error, contains('整条地址是 JS'), reason: raw);
      }
    });

    test('没有模板：原样返回（只去首尾空白）', () async {
      final out = await applyUrlTemplate('  /s?q=x  ', baseUrl: '');
      expect(out.url, '/s?q=x');
    });
  });

  group('inspectUrlTemplate', () {
    test('只有占位符 → 不算 JS', () {
      final i = inspectUrlTemplate('/s?q={{key}}&p={{page}}');
      expect(i.usesJs, isFalse);
    });

    test('带请求选项的 POST 源 → 不算 JS（选项不是模板）', () {
      final i = inspectUrlTemplate(
        '/s,{"method":"POST","body":"searchkey={{key}}"}',
      );
      expect(i.usesJs, isFalse);
    });

    test('{{book.name}} 可静态跑', () {
      final i = inspectUrlTemplate('/s?q={{book.name}}');
      expect(i.usesJs, isTrue);
      expect(i.runnable, isTrue);
      expect(i.reasons, isEmpty);
    });

    test('ajax / 变量表 / DOM / JSONPath 都判不可跑，并给原因', () {
      final cases = {
        '/s?q={{java.ajax("/x?q="+key)}}': 'java.ajax',
        '/s?q={{java.put("a",1)}}': 'java.put',
        '/s?q={{document.title}}': '不能访问页面',
        r'/s?q={{$.id}}': 'JSONPath',
      };
      for (final entry in cases.entries) {
        final i = inspectUrlTemplate(entry.key);
        expect(i.usesJs, isTrue, reason: entry.key);
        expect(i.runnable, isFalse, reason: entry.key);
        expect(i.reasons.join('|'), contains(entry.value), reason: entry.key);
      }
    });

    test('请求体里的 JS 也参与判定', () {
      final i = inspectUrlTemplate(
        '/s,{"method":"POST","body":"q={{book.name}}"}',
      );
      expect(i.usesJs, isTrue);
      expect(i.runnable, isTrue);
    });
  });

  group('resolveRequestField', () {
    test('选项 + 地址与 body 两处模板都替换', () async {
      final r = await resolveRequestField(
        '/s,{"method":"POST","body":"q={{key}}&p={{page}}","headers":{"X":"1"}}',
        baseUrl: 'https://a.example',
        keyword: '斗罗',
        page: 2,
      );
      expect(r.ok, isTrue);
      expect(r.url, '/s');
      expect(r.method, 'POST');
      // body 里的关键词**不编码**（v2.79.0 修正）：表单 / JSON 的值要原文，
      // 编码成 `%E6%96%97…` 会让站点拿到字面量百分号串，还让引擎的
      // 「body 含中文 + GBK → 拒绝」守卫生效不了。
      expect(r.body, 'q=斗罗&p=2');
      expect(r.headers, {'X': '1'});
    });

    test('JSON body：{{key}} 保持原文，地址里的 {{key}} 仍编码', () async {
      final r = await resolveRequestField(
        '/api/search?q={{key}},{"method":"POST","body":"{\\"q\\":\\"{{key}}\\"}"}',
        baseUrl: 'https://a.example',
        keyword: '斗罗',
      );
      expect(r.ok, isTrue);
      expect(r.url, '/api/search?q=%E6%96%97%E7%BD%97');
      expect(r.body, '{"q":"斗罗"}');
      // body 仍是合法 JSON（content-type 判据据此选 application/json）
      expect(inferContentType(r.body), 'application/json');
    });

    test('GBK 源的 body 不再被编成纯 ASCII（引擎的守卫才看得见中文）', () async {
      final r = await resolveRequestField(
        '/s,{"method":"POST","body":"q={{key}}","charset":"gbk"}',
        baseUrl: '',
        keyword: '斗罗',
      );
      expect(r.charset, 'gbk');
      expect(r.body, 'q=斗罗');
      // 回归点：编码后 body 是纯 ASCII，`rule_engine` 的「中文 + GBK → 拒绝」
      // 守卫就永远不触发，退回「200 但 0 条」
      expect(RegExp(r'[^\x00-\x7F]').hasMatch(r.body!), isTrue);
    });

    test('地址拼不出来 → ok 为假，调用方据此不发请求', () async {
      final r = await resolveRequestField(
        '/s?q={{java.ajax("/x")}}',
        baseUrl: '',
        evalJs: (_, __) async => 'x',
      );
      expect(r.ok, isFalse);
      expect(r.error, contains('java.ajax'));
    });
  });

  group('mergeHeaders（大小写不敏感合并）', () {
    test('按小写键去重，选项优先且保留它写的大小写', () {
      final out = mergeHeaders(
        {'Referer': 'https://a.example/', 'X-Src': '1'},
        {'referer': 'https://m.example/'},
      );
      // 只剩一个 referer 键（以前两个都进 Dio，发哪个由底层决定）
      expect(out.keys.where((k) => k.toLowerCase() == 'referer').length, 1);
      expect(out['referer'], 'https://m.example/');
      expect(out.containsKey('Referer'), isFalse);
      expect(out['X-Src'], '1');
    });

    test('不冲突时就是并集；空的一侧直接返回另一侧', () {
      expect(
        mergeHeaders({'A': '1'}, {'B': '2'}),
        {'A': '1', 'B': '2'},
      );
      const base = {'A': '1'};
      expect(identical(mergeHeaders(base, const {}), base), isTrue);
    });
  });

  group('inferContentType', () {
    test('JSON body → application/json', () {
      expect(inferContentType('{"q":"x"}'), 'application/json');
      expect(inferContentType('[1,2]'), 'application/json');
    });

    test('表单串 / 空 / 半截 JSON → form-urlencoded', () {
      expect(inferContentType('q=x&p=1'), 'application/x-www-form-urlencoded');
      expect(inferContentType(''), 'application/x-www-form-urlencoded');
      expect(inferContentType(null), 'application/x-www-form-urlencoded');
      expect(inferContentType('{"q":'), 'application/x-www-form-urlencoded');
    });

    test('hasContentType 大小写不敏感', () {
      expect(hasContentType({'Content-Type': 'text/plain'}), isTrue);
      expect(hasContentType({'content-type': 'text/plain'}), isTrue);
      expect(hasContentType({'X-A': '1'}), isFalse);
    });
  });
}
