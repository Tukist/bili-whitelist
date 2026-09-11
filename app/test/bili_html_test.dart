// 专栏正文 HTML 解析/渲染单测（`lib/utils/bili_html.dart`）。
//
// 覆盖：
// - 标签解析：p / br / img / h1-h3 / blockquote / strong / em / a / ul-li /
//   figure-figcaption（结构断言走 parseBiliHtml 的节点树）
// - 未知标签降级：div / span / 自定义标签 → **剥壳留文**（内容不丢）
// - HTML 实体：命名（&amp; &nbsp; &mdash; …）+ 数字（&#39; / &#x4E2D;），
//   表外实体原样保留
// - 畸形输入不崩：空串 / 纯文本 / 只有标签 / 未闭合 / 嵌套错乱 / 没有 '>' 的
//   裸 '<' / 超长文本
// - 危险输入：<script> / <style> 连内容一起丢弃（不上屏、不当文本）
// - 渲染：段落/标题/引用块（AppBlock reply）/列表标记/图注/图片（宽高比 +
//   可点 → 回传图集与下标）/链接（下划线 + 回调）/换行
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/bili_html.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';

/// 取顶层节点的标签序列（方便断言结构）。
List<String> _tags(List<HtmlNode> nodes) => [
      for (final n in nodes)
        if (n is HtmlElement) n.tag,
    ];

/// 取元素 [el] 下第一个 [tag] 名字的子元素（找不到 → null）。
HtmlElement? _child(HtmlElement el, String tag) {
  for (final c in el.children) {
    if (c is HtmlElement && c.tag == tag) return c;
  }
  return null;
}

/// 取节点树里所有纯文本（拼接，便于断言"内容没丢"）。
String _allText(List<HtmlNode> nodes) {
  final buf = StringBuffer();
  void walk(List<HtmlNode> list) {
    for (final n in list) {
      if (n is HtmlText) {
        buf.write(n.text);
      } else if (n is HtmlElement) {
        walk(n.children);
      }
    }
  }

  walk(nodes);
  return buf.toString();
}

/// 渲染一段 HTML（宽 400 的容器，模拟手机阅读页宽度）。
Future<void> _pumpHtml(
  WidgetTester tester,
  String html, {
  void Function(List<String> urls, int index)? onImageTap,
  ValueChanged<String>? onLinkTap,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: BiliHtmlView.fromHtml(
            html,
            onImageTap: onImageTap,
            onLinkTap: onLinkTap,
          ),
        ),
      ),
    ),
  ));
}

/// 测试环境里图床请求一律 400（flutter_test 固定行为）→ 图片加载失败是
/// **预期内**的（渲染侧有 errorBuilder 兜底）；把已上报的异常取走。
void _drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

void main() {
  group('parseBiliHtml：标签结构', () {
    test('p / h1-h3 / blockquote / ul-li / figure-figcaption / img / br', () {
      final nodes = parseBiliHtml(
        '<p>段落</p>'
        '<h1>大标题</h1><h2>中标题</h2><h3>小标题</h3>'
        '<blockquote>引文</blockquote>'
        '<ul><li>甲</li><li>乙</li></ul>'
        '<figure><img src="//i0.hdslb.com/a.jpg">'
        '<figcaption>图注</figcaption></figure>'
        '<p>上<br>下</p>',
      );
      expect(_tags(nodes), [
        'p', 'h1', 'h2', 'h3', 'blockquote', 'ul', 'figure', 'p',
      ]);

      final ul = nodes[5] as HtmlElement;
      expect(_tags(ul.children), ['li', 'li']);
      expect(_allText(ul.children), '甲乙');

      final figure = nodes[6] as HtmlElement;
      final img = _child(figure, 'img');
      expect(img, isNotNull);
      expect(img!.attrs['src'], '//i0.hdslb.com/a.jpg');
      expect(_child(figure, 'figcaption'), isNotNull);

      final lastP = nodes[7] as HtmlElement;
      expect(_tags(lastP.children), ['br']);
      expect(_allText(lastP.children), '上下');
    });

    test('行内标签：strong / b / em / i / a(href) 原样入树', () {
      final nodes = parseBiliHtml(
        '<p><strong>粗</strong><b>也粗</b><em>斜</em><i>也斜</i>'
        '<a href="https://space.bilibili.com/123">链接</a></p>',
      );
      final p = nodes.single as HtmlElement;
      expect(_tags(p.children), ['strong', 'b', 'em', 'i', 'a']);
      final a = _child(p, 'a')!;
      expect(a.attrs['href'], 'https://space.bilibili.com/123');
      expect(_allText(p.children), '粗也粗斜也斜链接');
    });

    test('自闭合与 void 元素不入栈（后面的兄弟节点不会被吞进去）', () {
      final nodes = parseBiliHtml('<img src="//a/b.jpg" /><br><hr><p>后</p>');
      expect(_tags(nodes), ['img', 'br', 'hr', 'p']);
      expect(_allText([nodes.last]), '后');
    });

    test('属性解析：带引号 / 不带引号 / 实体 / 大小写', () {
      final nodes = parseBiliHtml(
        "<IMG SRC=\"//i0.hdslb.com/a.jpg\" WIDTH=100 HEIGHT='50' "
        'alt="a&amp;b">',
      );
      final img = nodes.single as HtmlElement;
      expect(img.tag, 'img');
      expect(img.attrs['width'], '100');
      expect(img.attrs['height'], '50');
      expect(img.attrs['alt'], 'a&b');
    });
  });

  group('parseBiliHtml：降级与安全', () {
    test('未知标签剥壳留文（div / span / 自定义标签内容都不丢）', () {
      final nodes = parseBiliHtml(
        '<div><span>一</span></div><my-tag>二</my-tag><p>三</p>',
      );
      // 标签本身保留在树里（渲染时才剥壳），关键是文本一字不少
      expect(_allText(nodes), '一二三');
      expect(nodes.last, isA<HtmlElement>());
      expect((nodes.last as HtmlElement).tag, 'p');
    });

    test('<script> / <style> 连内容一起丢弃（脚本不进树、不上屏）', () {
      final nodes = parseBiliHtml(
        '<p>正文</p><script>alert("x")</script>'
        '<style>.a{color:red}</style><p>结尾</p>',
      );
      expect(_tags(nodes), ['p', 'p']);
      expect(_allText(nodes), '正文结尾');
    });

    test('未闭合的 <script> → 其后全部丢弃（不泄漏到正文）', () {
      final nodes = parseBiliHtml('<p>正文</p><script>alert("x")');
      expect(_allText(nodes), '正文');
    });

    test('注释 / doctype / 处理指令整段丢弃', () {
      final nodes = parseBiliHtml(
        '<!-- 注释不该上屏 --><!DOCTYPE html><?xml version="1.0"?><p>正文</p>',
      );
      expect(_allText(nodes), '正文');
    });

    test('畸形输入不崩：空串 / 纯文本 / 只有标签 / 裸 < / 未闭合', () {
      expect(parseBiliHtml(''), isEmpty);
      expect(_allText(parseBiliHtml('纯文本')), '纯文本');
      expect(_tags(parseBiliHtml('<br><hr><img src="x">')), ['br', 'hr', 'img']);
      // 没有 '>' 的裸 '<'：按纯文本吃下，不抛
      expect(_allText(parseBiliHtml('a< b')), 'a< b');
      expect(_allText(parseBiliHtml('<p>未闭合')), '未闭合');
      // 嵌套错乱（<b><i>x</b></i>）：按"就近闭合"收口 → b 里裹着 i
      final mismatched = parseBiliHtml('<b><i>嵌套</b></i>');
      expect(_tags(mismatched), ['b']);
      expect(_tags((mismatched.single as HtmlElement).children), ['i']);
      expect(_allText(mismatched), '嵌套');
      // 多出来的闭合标签 / 空标签：忽略，不影响后续
      expect(_tags(parseBiliHtml('</p><p>a</p><>')), ['p']);
    });

    test('未闭合块级标签的隐式收口（<p>a<p>b → 两个兄弟段落）', () {
      final nodes = parseBiliHtml('<p>一<p>二<p>三');
      expect(_tags(nodes), ['p', 'p', 'p']);
      expect(_allText(nodes), '一二三');
      expect(_allText([nodes.first]), '一', reason: '不会把后面的吞进第一个');
    });

    test('超长文本（5 万字）不崩、内容完整', () {
      final html = '<p>${'啊' * 50000}</p>';
      final nodes = parseBiliHtml(html);
      expect(_allText(nodes).length, 50000);
    });
  });

  group('实体解码与空白处理', () {
    test('命名实体 + 数字实体 + 表外实体原样保留', () {
      expect(decodeHtmlEntities('a&amp;b'), 'a&b');
      expect(decodeHtmlEntities('&lt;b&gt;'), '<b>');
      expect(decodeHtmlEntities('&quot;引号&quot;'), '"引号"');
      expect(decodeHtmlEntities('&#39;'), "'");
      expect(decodeHtmlEntities('&nbsp;'), '\u00a0');
      expect(decodeHtmlEntities('&mdash;&hellip;'), '—…');
      expect(decodeHtmlEntities('&#x4E2D;&#25991;'), '中文');
      expect(decodeHtmlEntities('&unknown;'), '&unknown;', reason: '表外实体不猜');
      expect(decodeHtmlEntities('&#xD800;'), '&#xD800;', reason: '代理区码点拒绝');
      expect(decodeHtmlEntities('5 > 3 且 3 &lt; 5'), '5 > 3 且 3 < 5');
    });

    test('文本里的连续空格/制表折叠，换行保留（纯文本专栏靠换行分段）', () {
      final nodes = parseBiliHtml('<p>a   b\tc</p><p>第一行\n第二行</p>');
      expect(_allText([nodes.first]), 'a b c');
      expect(_allText([nodes.last]), '第一行\n第二行');
    });

    test('块之间的缩进换行（只有空白的文本节点）不产出段落', () async {
      final nodes = parseBiliHtml('<p>a</p>\n   \n<p>b</p>\n');
      expect(_tags(nodes), ['p', 'p']);
    });
  });

  group('图片收集', () {
    test('按文档顺序收集、归一化 https、不去重', () {
      final nodes = parseBiliHtml(
        '<p>x</p><img src="//i0.hdslb.com/a.jpg">'
        '<figure><img src="http://i0.hdslb.com/b.jpg"></figure>'
        '<img src="//i0.hdslb.com/a.jpg">',
      );
      expect(collectBiliHtmlImageUrls(nodes), [
        'https://i0.hdslb.com/a.jpg',
        'https://i0.hdslb.com/b.jpg',
        'https://i0.hdslb.com/a.jpg',
      ]);
    });

    test('src 优先，缺失时退回 data-src（懒加载形态）', () {
      final nodes = parseBiliHtml(
        '<img data-src="//i0.hdslb.com/lazy.jpg"><img src="">',
      );
      expect(collectBiliHtmlImageUrls(nodes), ['https://i0.hdslb.com/lazy.jpg']);
    });
  });

  group('渲染', () {
    testWidgets('段落 / 标题 / 引用块 / 列表 / 图注 都上屏', (tester) async {
      await _pumpHtml(
        tester,
        '<p>一段正文</p><h2>章节标题</h2><blockquote>引用的话</blockquote>'
        '<ul><li>第一项</li><li>第二项</li></ul>'
        '<figure><img src="//i0.hdslb.com/a.jpg"><figcaption>配图说明</figcaption>'
        '</figure>',
      );
      expect(find.text('一段正文'), findsOneWidget);
      expect(find.text('章节标题'), findsOneWidget);
      expect(find.text('引用的话'), findsOneWidget);
      expect(find.text('第一项'), findsOneWidget);
      expect(find.text('第二项'), findsOneWidget);
      expect(find.text('•'), findsNWidgets(2), reason: '无序列表标记');
      expect(find.text('配图说明'), findsOneWidget);
      // 引用块走项目「块」的语言（AppBlock 的 reply 规格）
      final quote = tester.widget<AppBlock>(
        find.byType(AppBlock).first,
      );
      expect(quote.variant, AppBlockVariant.reply);
      _drainImageErrors(tester);
    });

    testWidgets('未知标签剥壳留文（div / span / 自定义标签文字照常显示）',
        (tester) async {
      await _pumpHtml(
        tester,
        '<div><span>容器里的字</span></div><foo-bar>自定义标签里的字</foo-bar>',
      );
      expect(find.text('容器里的字'), findsOneWidget);
      expect(find.text('自定义标签里的字'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('实体解码上屏；<script> 内容不显示', (tester) async {
      await _pumpHtml(
        tester,
        '<p>a&amp;b&nbsp;c&#39;d</p><script>alert("危险")</script>',
      );
      expect(find.text('a&b\u00a0c\'d'), findsOneWidget);
      expect(find.textContaining('alert'), findsNothing);
      expect(find.textContaining('危险'), findsNothing);
    });

    testWidgets('strong / em / br 的行内样式与换行', (tester) async {
      await _pumpHtml(
        tester,
        '<p><strong>粗体</strong>与<em>斜体</em><br>换行后</p>',
      );
      // 同一段落的行内内容合成一个 Text.rich：纯文本含换行
      final text = tester.widget<Text>(find.byType(Text).first);
      final plain = text.textSpan!.toPlainText();
      expect(plain, contains('粗体'));
      expect(plain, contains('斜体'));
      expect(plain, contains('\n换行后'));
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(
        spans.firstWhere((s) => s.text == '粗体').style?.fontWeight,
        FontWeight.w700,
      );
      expect(
        spans.firstWhere((s) => s.text == '斜体').style?.fontStyle,
        FontStyle.italic,
      );
    });

    testWidgets('链接：主墨下划线 + 点击回调带原始 href', (tester) async {
      String? tapped;
      await _pumpHtml(
        tester,
        '<p>见<a href="https://space.bilibili.com/123">我的主页</a>。</p>',
        onLinkTap: (url) => tapped = url,
      );
      final text = tester.widget<Text>(find.byType(Text).first);
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      final link = spans.firstWhere((s) => s.text == '我的主页');
      expect(link.style?.decoration, TextDecoration.underline);
      expect(link.recognizer, isNotNull);

      (link.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();
      expect(tapped, 'https://space.bilibili.com/123');

      // 无 onLinkTap 时不挂手势（链接退化成普通文字）
      await _pumpHtml(tester, '<p><a href="https://x.com">x</a></p>');
      final plain = tester.widget<Text>(find.byType(Text).first);
      final s = (plain.textSpan! as TextSpan).children!.cast<TextSpan>().single;
      expect(s.recognizer, isNull);
    });

    testWidgets('图片：按 <img> 宽高预留比例（防跳动）、可点回传图集与下标',
        (tester) async {
      List<String>? urls;
      int? index;
      await _pumpHtml(
        tester,
        '<p>前<img src="//i0.hdslb.com/a.jpg" width="100" height="100">后</p>'
        '<img src="//i0.hdslb.com/b.jpg">',
        onImageTap: (u, i) {
          urls = u;
          index = i;
        },
      );
      expect(find.text('前'), findsOneWidget);
      expect(find.text('后'), findsOneWidget);
      final ratios = tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((w) => w.aspectRatio)
          .toList();
      expect(ratios, [1.0, 16 / 9], reason: '第一张用 img 的 1:1，第二张默认 16:9');

      await tester.tap(find.byType(GestureDetector).last, warnIfMissed: false);
      await tester.pump();
      expect(urls, [
        'https://i0.hdslb.com/a.jpg',
        'https://i0.hdslb.com/b.jpg',
      ]);
      expect(index, 1);
      _drainImageErrors(tester);
    });

    testWidgets('图片点击按文档顺序认领下标（同图重复出现也各占一位）',
        (tester) async {
      final taps = <int>[];
      await _pumpHtml(
        tester,
        '<img src="//i0.hdslb.com/same.jpg">'
        '<img src="//i0.hdslb.com/same.jpg">',
        onImageTap: (u, i) => taps.add(i),
      );
      final gestures = find.byType(GestureDetector);
      expect(gestures, findsNWidgets(2));
      await tester.tap(gestures.first, warnIfMissed: false);
      await tester.pump();
      _drainImageErrors(tester);
      expect(taps, [0]);
    });

    testWidgets('畸形 / 危险 / 空 HTML 渲染不崩', (tester) async {
      for (final html in <String>[
        '',
        '<p>未闭合<b>粗',
        '<p>一<p>二</p>',
        '<div><span>乱',
        '<script>alert(1)',
        '<!-- 只有注释 -->',
        'a< b< c',
        '<blockquote><ul><li>嵌套乱',
      ]) {
        await _pumpHtml(tester, html);
        _drainImageErrors(tester);
        expect(tester.takeException(), isNull, reason: '输入：$html');
      }
    });
  });
}
