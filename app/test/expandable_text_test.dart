// ExpandableText（长文本折叠 + 展开/收起）组件测试（v2.17.3+）：
// - 短正文（不超 foldLines 行）→ 全文展示、无「展开」按钮
// - 长正文 → 折叠省略 + 「展开」；点开展开全文 + 「收起」；再点收起复原
// - 纯文本形态（完整态 SelectableText）/ 富文本形态（链接混排 Text.rich）
//   两套渲染路径各自验证折叠展开
// - maxExpandedHeight 封顶（超长正文展开不爆布局）
//
// 测试环境字体为等宽测试字体（每字符宽 = fontSize），宽度与字号给定即可
// 确定每行字符数，折叠判定稳定可复现。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/widgets/expandable_text.dart';

/// 固定宽度宿主：宽 240，字号 12 → 每行 20 字（测试字体等宽）。
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 240, child: child),
        ),
      ),
    );

const _style = TextStyle(fontSize: 12, height: 1.4);

String _longText(int perLine, int lines) =>
    List.generate(lines, (i) => '行${i}_${'字' * perLine}').join('\n');

void main() {
  group('ExpandableText 纯文本形态', () {
    testWidgets('短正文（不超 foldLines）→ 全文展示、无展开按钮', (tester) async {
      // 240/12 = 20 字/行，正文 40 字 = 2 行 ≤ foldLines 2 → 不折叠
      final short = '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十';
      await tester.pumpWidget(_host(
        ExpandableText(text: short, style: _style, foldLines: 2),
      ));
      expect(find.text('展开'), findsNothing);
      expect(find.text('收起'), findsNothing);
      expect(find.textContaining('一二三四五六七八九十'), findsWidgets);
    });

    testWidgets('长正文 → 折叠省略 + 展开；点开展开全文 + 收起；再点复原',
        (tester) async {
      // 每行 20 字 × 6 行 = 6 行 > foldLines 2 → 折叠
      final long = _longText(20, 6);
      await tester.pumpWidget(_host(
        ExpandableText(text: long, style: _style, foldLines: 2),
      ));

      // 折叠态：出现「展开」；正文退化为 Text(maxLines=2)+ellipsis，
      // 不再是 SelectableText（find.textContaining 匹配的是逻辑全文，
      // 截断是绘制层效果，用 widget 类型/参数断言折叠态更可靠）
      expect(find.text('展开'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      final folded = tester.widgetList<Text>(find.byType(Text)).firstWhere(
          (t) => t.textSpan == null && t.data != null,
          orElse: () => fail('未找到折叠态 Text'));
      expect(folded.maxLines, 2);

      // 点「展开」→ 恢复 SelectableText 全文 + 「收起」
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      final expanded =
          tester.widget<SelectableText>(find.byType(SelectableText));
      expect(expanded.data, contains('行5_'));

      // 再点「收起」→ 恢复折叠
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('maxExpandedHeight 封顶：超长正文展开不爆布局、收起仍可用',
        (tester) async {
      // 50 行正文远超封顶高度 → 展开态内部滚动
      final huge = _longText(20, 50);
      await tester.pumpWidget(_host(
        ExpandableText(
          text: huge,
          style: _style,
          foldLines: 2,
          maxExpandedHeight: 80,
          selectable: false,
        ),
      ));
      expect(find.text('展开'), findsOneWidget);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // 无 RenderFlex 溢出
      expect(find.text('收起'), findsOneWidget);
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);
    });
  });

  group('ExpandableText 富文本形态（链接混排）', () {
    testWidgets('长富文本折叠展开；展开后链接混排全文恢复', (tester) async {
      // 正文 = 大量纯文本 + 链接段，排版超 foldLines 2 行
      const head = '前缀纯文本，很长很长很长很长很长很长很长很长很长很长很长很长的描述';
      const tail = '后缀文本，很长很长很长很长很长很长很长很长很长很长很长很长的描述';
      String onTap = '';
      final children = <TextSpan>[
        const TextSpan(text: head),
        TextSpan(
          text: 'https://www.bilibili.com/video/BV1xx411c7mD',
          style: const TextStyle(color: Colors.blue),
          recognizer: TapGestureRecognizer()
            ..onTap = () => onTap = '视频链接被点击',
        ),
        const TextSpan(text: tail),
      ];
      await tester.pumpWidget(_host(
        ExpandableText(
          text: '$head https://www.bilibili.com/video/BV1xx411c7mD $tail',
          style: _style,
          foldLines: 2,
          richChildren: children,
          copyTip: '已复制',
        ),
      ));
      // 折叠态：有「展开」；富文本正文为 Text.rich(maxLines=2, ellipsis)
      //（find.textContaining 匹配的是逻辑全文，截断是绘制层效果，用
      // maxLines 参数断言折叠态更可靠）
      expect(find.text('展开'), findsOneWidget);
      final foldedRich = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.textSpan != null,
              orElse: () => fail('未找到折叠态富文本 Text'));
      expect(foldedRich.maxLines, 2);

      // 展开 → 富文本全文（Text.rich 不带 maxLines）+ 「收起」
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      final expandedRich = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere((t) => t.textSpan != null,
              orElse: () => fail('未找到展开态富文本 Text'));
      expect(expandedRich.maxLines, isNull);

      // 展开态点链接段 → recognizer 回调（折叠后恢复完整 RichText 仍可点）
      await tester.tap(find.textContaining('https://www.bilibili.com',
          findRichText: true));
      await tester.pump();
      expect(onTap, '视频链接被点击');

      // 收起复原
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);
    });
  });
}
