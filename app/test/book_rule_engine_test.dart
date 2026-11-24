// 规则引擎里**可纯测**的那部分（R2 / v2.75.0）。
//
// 真 WebView 在 `flutter test` 里建不出来（`WebViewController()` 构造即抛），
// 所以能被单测的是三块：
// - `<base href>` 注入（相对链接解析全靠它）；
// - [FakeRuleEngine] 的默认行为（它是所有搜索测试的地基，行为不能悄悄变）；
// - `fetchHtml` 的**解码判定**（v2.75.0 起 controller 懒建 + Dio 可注入，
//   所以能拿假适配器吐 GBK 字节，直接断言「字节 → 中文」这条路）。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

/// 假 Dio 适配器：不回真网络，直接吐死字节 + 指定响应头。
///
/// 为什么不用 `flutter_test` 的网络 mock：我们要的是「响应头 + 字节」这两样
/// 原样进 `fetchHtml`，适配器是最贴身的一层，超时 / 重定向这些行为也一起保留。
class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes, {this.contentType});

  final List<int> bytes;

  /// `Content-Type` 响应头的值（null = 不下发这个头）。
  final String? contentType;

  /// 被请求过的 URL（按调用顺序）。
  final List<String> urls = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    urls.add(options.uri.toString());
    return ResponseBody.fromBytes(
      bytes,
      200,
      statusMessage: 'OK',
      headers: {
        if (contentType != null) Headers.contentTypeHeader: [contentType!],
      },
    );
  }
}

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

  group('fetchHtml 的编码判定（v2.75.0）', () {
    // 夹具一律字节字面量：'你好' 的 GBK 是 C4 E3 BA C3、UTF-8 是 E4 BD A0 E5 A5
    // BD。Dart 没有 GBK 编码器（这正是本地书那条路必须有码表的原因），
    // 所以 GBK 侧只能写字面量，不能「源码写中文再 encode」。
    const gbkNiHao = [0xC4, 0xE3, 0xBA, 0xC3];
    const utf8NiHao = [0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD];

    WebViewRuleEngine engineFor(_BytesAdapter adapter) {
      final dio = Dio()..httpClientAdapter = adapter;
      return WebViewRuleEngine(dio: dio);
    }

    test('GBK 字节 + 源声明 gbk：解出中文，编码 gbk，不报乱码', () async {
      final adapter = _BytesAdapter(gbkNiHao);
      final engine = engineFor(adapter);
      final html = await engine.fetchHtml(
        'https://gbk.example/',
        charset: 'gbk',
      );
      expect(html, '你好');
      expect(engine.lastDecodeEncoding, 'gbk');
      expect(engine.lastDecodeWarning, isNull);
      expect(adapter.urls, ['https://gbk.example/']);
      await engine.dispose();
    });

    test('GBK 字节 + 源声明 utf-8（声明错了）：自动纠正并给提示', () async {
      final engine = engineFor(_BytesAdapter(gbkNiHao));
      final html = await engine.fetchHtml(
        'https://x.example/',
        charset: 'utf-8',
      );
      expect(html, '你好');
      expect(engine.lastDecodeEncoding, 'gbk');
      expect(engine.lastDecodeWarning, contains('疑似 GBK'));
      await engine.dispose();
    });

    test('UTF-8 字节 + 源声明 gbk（声明错了）：按 UTF-8 解，且安静', () async {
      final engine = engineFor(_BytesAdapter(utf8NiHao));
      final html = await engine.fetchHtml(
        'https://x.example/',
        charset: 'gbk',
      );
      expect(html, '你好');
      expect(engine.lastDecodeEncoding, 'utf-8');
      // 声明写错了但纠正对了：这时候不该吓用户说「有乱码」
      expect(engine.lastDecodeWarning, isNull);
      await engine.dispose();
    });

    test('响应头 charset 优先于书源声明（站点自己说的更可信）', () async {
      final adapter = _BytesAdapter(
        gbkNiHao,
        contentType: 'text/html; charset=gbk',
      );
      final engine = engineFor(adapter);
      // 书源写 utf-8、响应头写 gbk：按 gbk 解，而且「已声明」所以不提示
      final html = await engine.fetchHtml(
        'https://x.example/',
        charset: 'utf-8',
      );
      expect(html, '你好');
      expect(engine.lastDecodeEncoding, 'gbk');
      expect(engine.lastDecodeWarning, isNull);
      await engine.dispose();
    });

    test('响应头写 utf-8 但字节是 GBK：自动判定仍然救回来', () async {
      final adapter = _BytesAdapter(
        gbkNiHao,
        contentType: 'text/html; charset=utf-8',
      );
      final engine = engineFor(adapter);
      final html = await engine.fetchHtml(
        'https://x.example/',
        charset: 'utf-8',
      );
      expect(html, '你好');
      expect(engine.lastDecodeEncoding, 'gbk');
      expect(engine.lastDecodeWarning, contains('疑似 GBK'));
      await engine.dispose();
    });

    test('解完仍是一堆 U+FFFD：给「正文可能不完整」的告警', () async {
      final engine = engineFor(_BytesAdapter([0xFF, 0xFF, 0xFF, 0xFF]));
      final html = await engine.fetchHtml('https://x.example/');
      expect(html.contains('\uFFFD'), isTrue);
      expect(engine.lastDecodeWarning, '解码后仍有乱码，正文可能不完整');
      await engine.dispose();
    });

    test('空响应仍然抛 empty（既有行为不变）', () async {
      final engine = engineFor(_BytesAdapter(const []));
      await expectLater(
        engine.fetchHtml('https://x.example/'),
        throwsA(
          isA<RuleEngineException>()
              .having((e) => e.kind, 'kind', RuleErrorKind.empty),
        ),
      );
      await engine.dispose();
    });
  });

  group('parseHeaderCharset / decodeNoteFor（纯函数）', () {
    test('Content-Type 的各种写法都能抠出 charset', () {
      expect(parseHeaderCharset('text/html; charset=gbk'), 'gbk');
      expect(parseHeaderCharset('text/html; charset="GB2312"'), 'GB2312');
      expect(parseHeaderCharset('text/html;charset=UTF-8; foo=bar'), 'UTF-8');
      expect(parseHeaderCharset('Text/HTML; Charset = gb18030'), 'gb18030');
      expect(parseHeaderCharset('text/html'), isNull);
      expect(parseHeaderCharset('   '), isNull);
      expect(parseHeaderCharset(null), isNull);
    });

    test('分组小字：正常 UTF-8 不显示，GBK 与乱码各有一句', () {
      expect(decodeNoteFor('utf-8', null), isNull);
      expect(decodeNoteFor(null, null), isNull);
      expect(decodeNoteFor('gbk', null), '编码：GBK');
      // 「疑似 GBK」是自动纠正成功的**好消息**：不能写成「仍有乱码」
      // （实机第一次就是这么错的：GBK 页面明明正常显示，小字却吓人）
      expect(decodeNoteFor('gbk', kDecodeGbkGuessWarning), '编码：GBK');
      expect(decodeNoteFor('utf-8', kDecodeGarbledWarning), '解码有乱码');
      expect(decodeNoteFor('gbk', kDecodeGarbledWarning), '编码：GBK（仍有乱码）');
      // 文案常量与 decodeWarningFor 的产出必须一致（改一处漏另一处就会静默变回旧行为）
      expect(kDecodeGarbledWarning, '解码后仍有乱码，正文可能不完整');
      expect(kDecodeGbkGuessWarning, '这个书源疑似 GBK，已按 GBK 解码');
    });
  });

  group('evalJsRule（I3a 静态 JS 内核）', () {
    test('默认实现（假引擎）报 unsupported，并把脚本记下来', () async {
      final engine = FakeRuleEngine();
      await expectLater(
        engine.evalJsRule(script: 'result = "x"', bindings: const {}),
        throwsA(
          isA<RuleEngineException>()
              .having((e) => e.kind, 'kind', RuleErrorKind.unsupported),
        ),
      );
      expect(engine.jsRuleCount, 1);
      expect(engine.jsRuleScripts, ['result = "x"']);
    });

    test('四态①：成功返回脚本结果', () async {
      final engine = FakeRuleEngine(
        onEvalJs: (script, bindings, base) async => '${bindings['key']}-已洗',
      );
      final value = await engine.evalJsRule(
        script: 'result + "已洗"',
        bindings: const {'key': '凡人'},
        base: parseSelector('@css:.name@text'),
      );
      expect(value, '凡人-已洗');
    });

    test('四态②：脚本把 result 置空 → 返回 null（不是空串）', () async {
      final engine = FakeRuleEngine(onEvalJs: (_, __, ___) async => null);
      expect(
        await engine.evalJsRule(script: 'result = null', bindings: const {}),
        isNull,
      );
    });

    test('四态③：脚本报错 → 抛 unsupported，消息里有人话原因', () async {
      final engine = FakeRuleEngine(
        onEvalJs: (_, __, ___) async => throw const RuleEngineException(
          RuleErrorKind.unsupported,
          'JS 规则执行失败：boom',
        ),
      );
      await expectLater(
        engine.evalJsRule(script: 'throw new Error("boom")', bindings: const {}),
        throwsA(
          isA<RuleEngineException>()
              .having((e) => e.kind, 'kind', RuleErrorKind.unsupported)
              .having((e) => e.message, 'message', contains('boom')),
        ),
      );
    });

    test('四态④：超时 → 抛 timeout（超时值 3 秒）', () async {
      expect(kRuleJsTimeout, const Duration(seconds: 3));
      final engine = FakeRuleEngine(
        onEvalJs: (_, __, ___) async => throw const RuleEngineException(
          RuleErrorKind.timeout,
          'JS 规则执行超过 3 秒，已终止（脚本里可能有死循环）',
        ),
      );
      await expectLater(
        engine.evalJsRule(script: 'while(true){}', bindings: const {}),
        throwsA(
          isA<RuleEngineException>()
              .having((e) => e.kind, 'kind', RuleErrorKind.timeout),
        ),
      );
    });
  });

  group('checkJsRuleAllowed（纯函数层的安全门）', () {
    test('白名单内的脚本放行（含 log / md5 / timeFormat）', () {
      for (final script in [
        'result = result.trim()',
        'result = java.md5Encode(result)',
        'java.log(result); result = java.timeFormat(1, "yyyy-MM-dd")',
        'result = java.base64Decode(java.base64Encode(result))',
      ]) {
        expect(() => checkJsRuleAllowed(script), returnsNormally, reason: script);
      }
    });

    test('网络 / 控制类 API 一律拒绝，消息点名具体函数', () {
      final cases = {
        'result = java.ajax("/x")': 'java.ajax',
        'result = java.post("/x", "a=1")': 'java.post',
        'result = java.connect("/x")': 'java.connect',
        'result = java.startBrowserAwait(url)': 'java.startBrowserAwait',
        'result = Packages.net.x.Http.get(u)': 'Packages',
        'result = org.jsoup.Jsoup.parse(html)': 'org.jsoup',
        'result = fetch("/x")': 'fetch',
        'result = new XMLHttpRequest()': 'XMLHttpRequest',
      };
      for (final entry in cases.entries) {
        expect(
          () => checkJsRuleAllowed(entry.key),
          throwsA(
            isA<RuleEngineException>()
                .having((e) => e.kind, 'kind', RuleErrorKind.unsupported)
                .having((e) => e.message, 'message', contains(entry.value)),
          ),
          reason: entry.key,
        );
      }
    });

    test('java.put / getString 也拒绝（变量表 / DOM 桥本批没有）', () {
      for (final name in ['java.put', 'java.get', 'java.getString']) {
        expect(
          () => checkJsRuleAllowed('result = $name("k")'),
          throwsA(
            isA<RuleEngineException>()
                .having((e) => e.message, 'message', contains(name)),
          ),
          reason: name,
        );
      }
    });
  });
}
