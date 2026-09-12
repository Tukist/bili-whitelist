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
import 'dart:convert';

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

/// 渲染一段正文（**自动判别** HTML / Delta，走阅读页同一条路）。
Future<void> _pumpContent(
  WidgetTester tester,
  String content, {
  void Function(List<String> urls, int index)? onImageTap,
  ValueChanged<String>? onLinkTap,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 400,
          child: BiliHtmlView.fromContent(
            content,
            onImageTap: onImageTap,
            onLinkTap: onLinkTap,
          ),
        ),
      ),
    ),
  ));
}

/// 界面上**所有** [Text] 的纯文本（含 `Text.rich` 的 span）拼起来。
///
/// 用来断言"原始 JSON 没有漏到界面上"——这是本任务的核心回归点：
/// 修之前 Delta 专栏会把整段 `{"ops":…}` 当纯文本画到屏幕上。
String _screenText(WidgetTester tester) {
  final buf = StringBuffer();
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    if (t.data != null) buf.write(t.data);
    buf.write(t.textSpan?.toPlainText() ?? '');
  }
  return buf.toString();
}

/// 节点树里第一个 [tag] 元素（深度优先；找不到 → null）。
HtmlElement? _find(HtmlNode node, String tag) {
  if (node is! HtmlElement) return null;
  if (node.tag == tag) return node;
  for (final c in node.children) {
    final hit = _find(c, tag);
    if (hit != null) return hit;
  }
  return null;
}

/// 用户报告里贴出的那段真实 Delta 结构（补成全合法 JSON 的片段）。
///
/// 保留的关键点：开头的 `{"insert":"\n","attributes":{"class":"normal-img"}}`、
/// 图片 `native-image`（含 `alt`/`width`/`height`/`size`/`status`）、
/// `attributes.link` 的链接、以及散落的 `\n`。
const String _kUserDeltaSample = '{"ops":['
    '{"insert":"\\n","attributes":{"class":"normal-img"}},'
    '{"insert":{"native-image":{"alt":"read-normal-img",'
    '"url":"https://i0.hdslb.com/bfs/article/'
    '32f43892ae504c833bc8b7783996851f1069246841.jpg@progressive.webp",'
    '"width":460,"height":215,"size":64510,"status":"loaded"}}},'
    '{"insert":"\\nRT，这个游戏是个好游戏，开放世界+黑客，双重自由，推荐大家游玩…"},'
    '{"insert":"UP的讲解视频","attributes":{"link":'
    '"https://www.bilibili.com/video/BV1pw411F7VA/"}},'
    '{"insert":"\\n"}]}';

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

  // -------------------------------------------------------------------------
  // Quill Delta（新版专栏正文）
  // -------------------------------------------------------------------------

  group('parseBiliDelta：文本与分段', () {
    test('纯文本 insert → 一个 <p>', () {
      final nodes = parseBiliDelta('{"ops":[{"insert":"一段正文\\n"}]}')!;
      expect(_tags(nodes), ['p']);
      expect(_allText(nodes), '一段正文');
    });

    test('`\\n` 是分段符：一段一个 <p>，连续 `\\n\\n` 的空段不占块', () {
      final two = parseBiliDelta('{"ops":[{"insert":"第一段\\n第二段\\n"}]}')!;
      expect(_tags(two), ['p', 'p']);
      expect(_allText([two.first]), '第一段');
      expect(_allText([two.last]), '第二段');

      // 中间的空行（`\n\n`）是段落分隔，不该多出一个空段落
      final blank = parseBiliDelta('{"ops":[{"insert":"甲\\n\\n乙\\n"}]}')!;
      expect(_tags(blank), ['p', 'p']);
      expect(_allText(blank), '甲乙');

      // 跨多个 op 的文本，只要中间没有 `\n` 就仍在**同一段**
      final across = parseBiliDelta({
        'ops': [
          {'insert': '上半'},
          {'insert': '下半\n'},
        ]
      })!;
      expect(_tags(across), ['p']);
      expect(_allText(across), '上半下半');
    });

    test('空 ops / 只有换行 → 无块（不崩）', () {
      expect(parseBiliDelta('{"ops":[]}'), isEmpty);
      expect(parseBiliDelta('{"ops":[{"insert":"\\n\\n"}]}'), isEmpty);
    });
  });

  group('parseBiliDelta：块级属性（真实 cv41358718 结构）', () {
    // B 站 Delta 的约定：**块级**格式（header / list / blockquote）挂在
    // **行尾那个 `\n`** 上，不写在文本 op 上。下面就是真实结构（片段）。
    test('行尾 \\n 上的 header → h1-h6', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '背景'},
          {
            'attributes': {'header': 2},
            'insert': '\n'
          },
          {'insert': '正文一段'},
          {'insert': '\n'},
          {
            'attributes': {'header': 6},
            'insert': '\n'
          },
        ]
      })!;
      expect(_tags(nodes), ['h2', 'p']);
      expect(_allText([nodes.first]), '背景');
      expect(_allText([nodes.last]), '正文一段');
    });

    test('行尾 \\n 上的 list → ul / ol；连续项并进**同一个列表**', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '第一项'},
          {
            'attributes': {'list': 'bullet'},
            'insert': '\n'
          },
          {'insert': '第二项'},
          {
            'attributes': {'list': 'bullet'},
            'insert': '\n'
          },
          {'insert': '有序一'},
          {
            'attributes': {'list': 'ordered'},
            'insert': '\n'
          },
          {'insert': '有序二'},
          {
            'attributes': {'list': 'ordered'},
            'insert': '\n'
          },
        ]
      })!;
      expect(_tags(nodes), ['ul', 'ol'], reason: '同类型连续项合成一个列表');
      final ul = nodes.first as HtmlElement;
      expect(_tags(ul.children), ['li', 'li']);
      expect(_allText(ul.children), '第一项第二项');
      expect(_tags((nodes.last as HtmlElement).children), ['li', 'li']);
      expect(_allText((nodes.last as HtmlElement).children), '有序一有序二');
    });

    test('行尾 \\n 上的 blockquote → 引用块', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '被引用的话'},
          {
            'attributes': {'blockquote': true},
            'insert': '\n'
          },
        ]
      })!;
      expect(_tags(nodes), ['blockquote']);
      expect(_allText(nodes), '被引用的话');
    });

    test('cut-off → 分割线；卡片类 embed → 跳过（其 url 是卡片图不是链接）',
        () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '上\n'},
          {'insert': {'cut-off': {'type': 'normal', 'url': 'https://x/cut.png'}}},
          {'insert': '\n下\n'},
          {
            'insert': {
              'video-card': {
                'alt': '',
                'id': 'av99999999',
                'url': 'https://i0.hdslb.com/card.png',
                'width': 2632,
                'height': 352,
              }
            }
          },
          {
            'insert': {
              'article-card': {'id': 'cv1', 'url': 'https://i0.hdslb.com/c2.png'}
            }
          },
        ]
      })!;
      expect(_tags(nodes), ['p', 'hr', 'p'], reason: '卡片一律跳过，分割线保留');
      expect(_allText(nodes), '上下');
      expect(
        collectBiliHtmlImageUrls(nodes),
        isEmpty,
        reason: '卡片图不该被当成正文配图收进图集',
      );
    });
  });

  group('parseBiliDelta：图片', () {
    test('native-image → <img>，url / width / height / alt 都带上', () {
      final nodes = parseBiliDelta('{"ops":[{"insert":{"native-image":{'
          '"alt":"read-normal-img",'
          '"url":"https://i0.hdslb.com/bfs/article/a.jpg@progressive.webp",'
          '"width":460,"height":215,"size":64510,"status":"loaded"}}}]}')!;
      expect(_tags(nodes), ['img']);
      final img = nodes.single as HtmlElement;
      expect(
        img.attrs['src'],
        'https://i0.hdslb.com/bfs/article/a.jpg@progressive.webp',
        reason: '@progressive.webp 后缀原样保留（实测图床可直连）',
      );
      expect(img.attrs['width'], '460');
      expect(img.attrs['height'], '215');
      expect(img.attrs['alt'], 'read-normal-img');
    });

    test('Quill 标准形态 {"image": "url"} 也认；protocol-relative 归一化',
        () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': {'image': '//i0.hdslb.com/bfs/article/b.jpg'}},
        ]
      })!;
      expect(_tags(nodes), ['img']);
      expect(
        (nodes.single as HtmlElement).attrs['src'],
        'https://i0.hdslb.com/bfs/article/b.jpg',
      );
    });

    test('图片是**块级**：夹在文本之间时先把上段结算掉', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '图前\n'},
          {
            'insert': {
              'native-image': {
                'url': 'https://i0.hdslb.com/a.jpg',
                'width': 100,
                'height': 100,
              }
            }
          },
          {'insert': '\n图后\n'},
        ]
      })!;
      expect(_tags(nodes), ['p', 'img', 'p']);
      expect(_allText([nodes.first]), '图前');
      expect(_allText([nodes.last]), '图后');
    });

    test('没有 url 的 native-image → 跳过（不产出空图）', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '前'},
          {'insert': {'native-image': {'width': 10, 'height': 10}}},
          {'insert': '后'},
        ]
      })!;
      expect(_tags(nodes), ['p']);
      expect(_allText(nodes), '前后');
    });

    test('图片能被 collectBiliHtmlImageUrls 按文档顺序收到', () {
      final nodes = parseBiliDelta(jsonDecode(_kUserDeltaSample))!;
      expect(collectBiliHtmlImageUrls(nodes), [
        'https://i0.hdslb.com/bfs/article/'
            '32f43892ae504c833bc8b7783996851f1069246841.jpg@progressive.webp',
      ]);
    });
  });

  group('parseBiliDelta：行内属性与链接', () {
    test('attributes.link → <a href>（字符串与 {"url":…} 两种给法都认）', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '点我', 'attributes': {'link': 'https://www.bilibili.com/'}},
          {'insert': '也点', 'attributes': {'link': {'url': 'https://x.com/2'}}},
        ]
      })!;
      final p = nodes.single as HtmlElement;
      expect(_tags(p.children), ['a', 'a']);
      expect((p.children[0] as HtmlElement).attrs['href'],
          'https://www.bilibili.com/');
      expect((p.children[1] as HtmlElement).attrs['href'], 'https://x.com/2');
      expect(_allText(p.children), '点我也点');
    });

    test('bold / italic / strike / underline → 对应行内标签', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '粗', 'attributes': {'bold': true}},
          {'insert': '斜', 'attributes': {'italic': true}},
          {'insert': '删', 'attributes': {'strike': true}},
          {'insert': '下', 'attributes': {'underline': true}},
          // 有的客户端把布尔给成字符串 → 一样要认
          {'insert': '粗2', 'attributes': {'bold': 'true'}},
          {'insert': '普通'},
        ]
      })!;
      final p = nodes.single as HtmlElement;
      expect(_tags(p.children), ['strong', 'em', 's', 'u', 'strong']);
      expect(_allText(p.children), '粗斜删下粗2普通');
      expect(_find(p, 'strong')!.children.single, isA<HtmlText>());
    });

    test('多个属性叠加（粗 + 斜 + 链接）不丢文字', () {
      final nodes = parseBiliDelta({
        'ops': [
          {
            'insert': '全能',
            'attributes': {
              'bold': true,
              'italic': true,
              'underline': true,
              'link': 'https://x.com/3',
            },
          },
        ]
      })!;
      final p = nodes.single as HtmlElement;
      expect(_find(p, 'a'), isNotNull, reason: '链接在最内层，不能被外层吞掉');
      expect(_allText(nodes), '全能');
    });
  });

  group('parseBiliDelta：未知形态优雅降级', () {
    test('poi / video / 未知键 / 脏 op 全部不崩、不产生原始 JSON 文本', () {
      final nodes = parseBiliDelta({
        'ops': [
          {'insert': '前'},
          {'insert': {'poi': {'name': '某个地点', 'url': 'https://x.com/poi'}}},
          {'insert': {'video': {'bvid': 'BV1pw411F7VA', 'aid': 123}}},
          {'insert': {'不知道什么键': {'a': 1, 'b': [2, 3]}}},
          {'insert': 42},
          {'insert': null},
          '这不是一个对象',
          {'attributes': {'bold': true}}, // 没有 insert
          {'insert': '后'},
        ]
      })!;
      // poi 带「可读文案 + URL」→ 降级成行内链接（仍在同一段里）；其余跳过
      expect(_tags(nodes), ['p'], reason: '中间的坏 op 不该把段落切断');
      expect(_allText(nodes), '前某个地点后');
      final link = _find(nodes.single, 'a');
      expect(link, isNotNull);
      expect(link!.attrs['href'], 'https://x.com/poi');
      final screenish = _allText(nodes);
      for (final leak in ['insert', 'ops', 'poi', 'video', 'bvid', 'attributes']) {
        expect(screenish.contains(leak), isFalse, reason: '泄漏了 $leak');
      }
    });

    test('入参与畸形结构：字符串 / Map / 脏 JSON / 非 ops 结构', () {
      expect(parseBiliDelta('{"ops":[{"insert":"ok"}]}'), isNotNull);
      expect(
        parseBiliDelta(jsonDecode('{"ops":[{"insert":"ok"}]}')),
        isNotNull,
        reason: '已经解码好的 Map 也要能直接吃',
      );
      expect(parseBiliDelta('不是 JSON'), isNull);
      expect(parseBiliDelta('{这也不是 JSON'), isNull);
      expect(parseBiliDelta('{"foo":1}'), isNull);
      expect(parseBiliDelta('{"ops":"不是数组"}'), isNull);
      expect(parseBiliDelta(42), isNull);
      expect(parseBiliDelta(null), isNull);
      expect(parseBiliDelta(<String, dynamic>{}), isNull);
      expect(parseBiliDelta('[]'), isNull);
    });

    test('超长文本（5 万字）不崩、内容完整', () {
      final payload = jsonEncode({
        'ops': [
          {'insert': '啊' * 50000},
        ]
      });
      final nodes = parseBiliDelta(payload)!;
      expect(_allText(nodes).length, 50000);
    });
  });

  group('looksLikeBiliDelta / parseArticleContent：格式判别', () {
    test('looksLikeBiliDelta：`{` 开头 + 有 "ops" 才算', () {
      expect(looksLikeBiliDelta('{"ops":[{"insert":"a"}]}'), isTrue);
      expect(looksLikeBiliDelta('  \n {"ops":[]}'), isTrue);
      expect(looksLikeBiliDelta('<p>正文</p>'), isFalse);
      expect(looksLikeBiliDelta('纯文本正文'), isFalse);
      expect(looksLikeBiliDelta('{'), isFalse);
      expect(looksLikeBiliDelta('{"articles":[]}'), isFalse);
      expect(looksLikeBiliDelta(''), isFalse);
    });

    test('HTML 输入走 HTML 分支（既有行为不变）', () {
      final nodes =
          parseArticleContent('<p>段落</p><figure><img src="//a/b.jpg"></figure>');
      expect(_tags(nodes), ['p', 'figure']);
      expect(_allText(nodes), '段落');
      expect(collectBiliHtmlImageUrls(nodes), ['https://a/b.jpg']);
    });

    test('纯文本输入走 HTML 分支（原样一段文本）', () {
      final nodes = parseArticleContent('整篇纯文本\n第二行');
      expect(_tags(nodes), isEmpty);
      expect(_allText(nodes), '整篇纯文本\n第二行');
    });

    test('Delta 输入走 Delta 分支', () {
      final nodes = parseArticleContent(_kUserDeltaSample);
      expect(_tags(nodes), ['img', 'p'], reason: '不再是"整段 JSON 文本"');
    });

    test('`{` 开头但 JSON 畸形 → 退回纯文本（不抛、不崩）', () {
      final raw = '{"ops": broken, 这不是 JSON}';
      final nodes = parseArticleContent(raw);
      expect(nodes, isNotEmpty);
      expect(_allText(nodes), contains('broken'));
    });
  });

  group('渲染（Delta 正文）', () {
    testWidgets('核心回归：用户贴的真实结构 → 图片出得来、文本是文本、'
        '界面上没有原始 JSON', (tester) async {
      String? tappedLink;
      await _pumpContent(
        tester,
        _kUserDeltaSample,
        onLinkTap: (url) => tappedLink = url,
      );

      // 1) 图片真的渲染出来了（不是被当文本）
      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as NetworkImage).url,
        'https://i0.hdslb.com/bfs/article/'
            '32f43892ae504c833bc8b7783996851f1069246841.jpg@progressive.webp',
      );

      // 2) width/height 用于 AspectRatio（防加载后跳动）
      final ratios = tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((w) => w.aspectRatio)
          .toList();
      expect(ratios, [460 / 215]);

      // 3) 文本是文本，链接可点
      final screen = _screenText(tester);
      expect(
        screen,
        contains('RT，这个游戏是个好游戏，开放世界+黑客，双重自由，'
            '推荐大家游玩…UP的讲解视频'),
      );
      final link = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => (t.textSpan as TextSpan?)?.children != null)
          .expand((t) => (t.textSpan! as TextSpan).children!.cast<TextSpan>())
          .firstWhere((s) => s.text == 'UP的讲解视频');
      expect(link.style?.decoration, TextDecoration.underline);
      (link.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();
      expect(tappedLink, 'https://www.bilibili.com/video/BV1pw411F7VA/');

      // 4) **界面上绝不出现原始 JSON 片段**
      for (final leak in <String>[
        'insert', 'ops', 'native-image', 'attributes', 'progressive',
        'loaded', '"', '{', '}',
      ]) {
        expect(screen.contains(leak), isFalse, reason: '泄漏了 $leak');
      }
      _drainImageErrors(tester);
    });

    testWidgets('Delta 未知 embed / 脏 op 渲染不崩、不露 JSON', (tester) async {
      await _pumpContent(
        tester,
        jsonEncode({
          'ops': [
            {'insert': '正文一\n'},
            {'insert': {'poi': {'name': '地点', 'url': 'https://x.com/p'}}},
            {'insert': {'video': {'bvid': 'BV1pw411F7VA'}}},
            {'insert': {'未知键': {'deep': 'value'}}},
            {'insert': 7},
            'not-a-map',
            {'insert': '\n正文二\n'},
          ]
        }),
        onLinkTap: (_) {},
      );
      expect(tester.takeException(), isNull);
      final screen = _screenText(tester);
      expect(screen, contains('正文一'));
      expect(screen, contains('正文二'));
      expect(screen, contains('地点'));
      for (final leak in <String>['insert', 'ops', '未知键', 'deep', 'bvid']) {
        expect(screen.contains(leak), isFalse, reason: '泄漏了 $leak');
      }
    });

    testWidgets('Delta 标题 / 列表 / 引用块 / 分割线都上屏（复用既有渲染）',
        (tester) async {
      await _pumpContent(
        tester,
        jsonEncode({
          'ops': [
            {'insert': '章节标题'},
            {
              'attributes': {'header': 2},
              'insert': '\n'
            },
            {'insert': '列表项一'},
            {
              'attributes': {'list': 'bullet'},
              'insert': '\n'
            },
            {'insert': '列表项二'},
            {
              'attributes': {'list': 'bullet'},
              'insert': '\n'
            },
            {'insert': '被引用的话'},
            {
              'attributes': {'blockquote': true},
              'insert': '\n'
            },
            {'insert': {'cut-off': {'url': 'https://x/cut.png'}}},
            {'insert': '结尾\n'},
          ]
        }),
        onLinkTap: (_) {},
      );
      expect(tester.takeException(), isNull);
      expect(find.text('章节标题'), findsOneWidget);
      expect(find.text('列表项一'), findsOneWidget);
      expect(find.text('列表项二'), findsOneWidget);
      // 与 HTML 分支同一套视觉：列表标记来自既有 _list，"•" 每个列表项一个
      expect(find.text('•'), findsNWidgets(2));
      expect(find.text('被引用的话'), findsOneWidget);
      final quote = tester.widget<AppBlock>(find.byType(AppBlock).first);
      expect(quote.variant, AppBlockVariant.reply, reason: '引用块走「块」的语言');
      expect(find.byType(Divider), findsOneWidget, reason: 'cut-off → 分隔线');
      final screen = _screenText(tester);
      for (final leak in <String>['insert', 'ops', 'bullet', 'header', 'cut-off']) {
        expect(screen.contains(leak), isFalse, reason: '泄漏了 $leak');
      }
    });

    testWidgets('Delta 图片可点：回传图集与下标', (tester) async {
      List<String>? urls;
      int? index;
      await _pumpContent(
        tester,
        jsonEncode({
          'ops': [
            {'insert': '说明\n'},
            {
              'insert': {
                'native-image': {'url': 'https://i0.hdslb.com/a.jpg'},
              }
            },
          ]
        }),
        onImageTap: (u, i) {
          urls = u;
          index = i;
        },
      );
      await tester.tap(find.byType(GestureDetector), warnIfMissed: false);
      await tester.pump();
      _drainImageErrors(tester);
      expect(urls, ['https://i0.hdslb.com/a.jpg']);
      expect(index, 0);
    });

    testWidgets('Delta 里的图片走与 HTML 同一套占位（loading/error 两态都挂着）',
        (tester) async {
      await _pumpContent(
        tester,
        jsonEncode({
          'ops': [
            {
              'insert': {
                'native-image': {'url': 'https://i0.hdslb.com/a.jpg'},
              }
            },
          ]
        }),
      );
      final image = tester.widget<Image>(find.byType(Image));
      // 两态占位都由这两个 builder 给（与 HTML 图片同一条 `_imageBlock`）
      expect(image.loadingBuilder, isNotNull);
      expect(image.errorBuilder, isNotNull);
      // 防盗链头与 HTML 图片一致（Delta 图也是 B 站图床）
      final provider = image.image as NetworkImage;
      expect(provider.headers?['Referer'], 'https://www.bilibili.com/');
      _drainImageErrors(tester);
    });
  });
}
