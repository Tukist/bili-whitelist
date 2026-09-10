// AppBlock 组件测试（lib/widgets/app_block.dart）：
// - 6 个 variant 的规格逐项断言（底色 / 描边 / 圆角 / 内边距 / 竖条宽高距顶）
// - 竖条 variant 必须 clipBehavior = Clip.antiAlias（不裁会从圆角处露直角）
// - 竖条色 = palette.inkDeco（并在浅墨配方下自动压深 / 达标 3:1）
// - 短竖条不参与布局（不撑高不撑宽）
// - specOverride 生效；child 原样渲染（find.text 命中）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/ink_recipes.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';

Future<void> _pump(WidgetTester tester, Widget child, {ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    ),
  );
  await tester.pump();
}

Finder _inside(Finder matching) =>
    find.descendant(of: find.byType(AppBlock), matching: matching);

/// 块自己的外形容器：树里第一个 Container 就是外层那个（DFS 前序）
Container _box(WidgetTester tester) =>
    tester.widget<Container>(_inside(find.byType(Container)).first);

BoxDecoration _decoration(WidgetTester tester) =>
    _box(tester).decoration! as BoxDecoration;

/// 左侧竖条容器（Stack 下唯一的 Container）
Container _rule(WidgetTester tester) => tester.widget<Container>(
      find.descendant(of: _stackFinder(), matching: find.byType(Container)),
    );

BoxDecoration _ruleDecoration(WidgetTester tester) =>
    _rule(tester).decoration! as BoxDecoration;

BuildContext _ctx(WidgetTester tester) => tester.element(find.byType(AppBlock));

/// 一条 variant 的期望规格
class _Case {
  final AppBlockVariant v;
  final Color bg;
  final Color? stroke;
  final double radius;
  final EdgeInsetsGeometry pad;

  /// null = 无竖条
  final double? ruleW;

  /// null = 全高
  final double? ruleH;
  final double? ruleTop;

  const _Case(
    this.v,
    this.bg,
    this.stroke,
    this.radius,
    this.pad, {
    this.ruleW,
    this.ruleH,
    this.ruleTop,
  });
}

const _cases = <_Case>[
  _Case(
    AppBlockVariant.videoInfo,
    kPaper,
    kRuleStrong,
    kRadiusMd,
    EdgeInsets.fromLTRB(12, 10, 12, 2),
    ruleW: 3,
    ruleH: 18,
    ruleTop: 10,
  ),
  _Case(
    AppBlockVariant.comment,
    kPaper,
    kRule,
    kRadiusMd,
    EdgeInsets.fromLTRB(12, 12, 12, 10),
  ),
  _Case(
    AppBlockVariant.reply,
    kPaperCool,
    null,
    kRadiusSm,
    EdgeInsets.fromLTRB(10, 8, 10, 8),
    ruleW: 2,
  ),
  _Case(
    AppBlockVariant.videoCard,
    kPaper,
    kRuleStrong,
    kRadiusMd,
    EdgeInsets.zero,
  ),
  _Case(
    AppBlockVariant.collectionCard,
    kPaperCool,
    kRuleStrong,
    kRadiusMd,
    EdgeInsets.all(10),
  ),
  _Case(
    AppBlockVariant.setting,
    kPaper,
    kRuleStrong,
    kRadiusMd,
    EdgeInsets.fromLTRB(16, 12, 16, 12),
  ),
];

void main() {
  group('规格表（appBlockSpec 逐项）', () {
    for (final c in _cases) {
      testWidgets('${c.v.name}：底色/描边/圆角/内边距/竖条', (tester) async {
        await _pump(
          tester,
          AppBlock(variant: c.v, child: const Text('块内容')),
        );

        final s = appBlockSpec(_ctx(tester), c.v);
        expect(s.background, c.bg, reason: '底色');
        expect(s.radius, c.radius, reason: '圆角');
        expect(s.padding, c.pad, reason: '内边距');
        if (c.stroke == null) {
          expect(s.stroke, isNull, reason: '不画四边描边');
        } else {
          expect(s.stroke, c.stroke, reason: '描边色');
          expect(s.strokeWidth, 1, reason: '描边宽统一 1px');
        }
        if (c.ruleW == null) {
          expect(s.leftRule, isNull, reason: '无竖条');
        } else {
          expect(s.leftRule, AppPalette.fallback.inkDeco, reason: '竖条墨（图形档）');
          expect(s.leftRuleWidth, c.ruleW, reason: '竖条宽');
          expect(s.leftRuleHeight, c.ruleH, reason: '竖条高（null = 全高）');
          if (c.ruleH != null) {
            expect(s.leftRuleTop, c.ruleTop, reason: '短条距顶');
          }
        }
      });
    }
  });

  group('渲染', () {
    for (final c in _cases) {
      testWidgets('${c.v.name}：decoration 与规格一致', (tester) async {
        await _pump(tester, AppBlock(variant: c.v, child: const Text('块内容')));
        final d = _decoration(tester);

        expect(d.color, c.bg);
        expect(d.borderRadius, BorderRadius.circular(c.radius));
        if (c.stroke == null) {
          expect(d.border, isNull);
        } else {
          expect(d.border, Border.all(color: c.stroke!, width: 1));
        }
        // 规格里的内边距确实有一层落在树上
        final paddings = tester
            .widgetList<Padding>(_inside(find.byType(Padding)))
            .map((p) => p.padding);
        expect(paddings.contains(c.pad), isTrue, reason: '存在规格内边距层');
      });
    }

    testWidgets('带竖条 → clipBehavior = Clip.antiAlias；不带 → Clip.none', (tester) async {
      for (final c in _cases) {
        await _pump(tester, AppBlock(variant: c.v, child: const Text('块内容')));
        expect(
          _box(tester).clipBehavior,
          c.ruleW == null ? Clip.none : Clip.antiAlias,
          reason: c.v.name,
        );
      }
    });

    testWidgets('短竖条：宽 3 × 高 18，距 Stack 顶 10，色 = palette.inkDeco', (tester) async {
      await _pump(
        tester,
        const AppBlock(variant: AppBlockVariant.videoInfo, child: Text('视频信息')),
      );

      expect(tester.getSize(_ruleFinder()), const Size(3, 18));
      final stackTop = tester.getTopLeft(_stackFinder()).dy;
      expect(tester.getTopLeft(_ruleFinder()).dy - stackTop, 10);
      expect(
        tester.getTopLeft(_ruleFinder()).dx,
        tester.getTopLeft(_stackFinder()).dx,
      );

      final d = _ruleDecoration(tester);
      expect(d.color, AppPalette.fallback.inkDeco);
      // 只有右侧小圆角：贴左边缘那侧必须是直角
      expect(
        d.borderRadius,
        const BorderRadius.horizontal(right: Radius.circular(1.5)),
      );
    });

    testWidgets('全高竖条（reply）：宽 2，上下贴齐 Stack', (tester) async {
      await _pump(
        tester,
        const AppBlock(variant: AppBlockVariant.reply, child: Text('回复内容')),
      );

      final stack = _stackFinder();
      final rule = _ruleFinder();
      final stackRect = tester.getRect(stack);
      final ruleRect = tester.getRect(rule);

      expect(ruleRect.width, 2);
      expect(ruleRect.height, stackRect.height);
      expect(ruleRect.top, stackRect.top);
      expect(ruleRect.left, stackRect.left);
      expect(_ruleDecoration(tester).color, AppPalette.fallback.inkDeco);
    });

    testWidgets('内边距真的作用到内容（comment：1px 描边 + 12/12/12/10）', (tester) async {
      await _pump(
        tester,
        const AppBlock(
          variant: AppBlockVariant.comment,
          child: SizedBox(width: 100, height: 20),
        ),
      );
      // 1 + 12 + 100 + 12 + 1 ；1 + 12 + 20 + 10 + 1
      expect(tester.getSize(find.byType(AppBlock)), const Size(126, 44));
    });

    testWidgets('短竖条不参与布局（videoInfo 不撑高不撑宽）', (tester) async {
      await _pump(
        tester,
        const AppBlock(
          variant: AppBlockVariant.videoInfo,
          child: SizedBox(width: 100, height: 20),
        ),
      );
      // 1 + 12 + 100 + 12 + 1 ；1 + 10 + 20 + 2 + 1
      expect(tester.getSize(find.byType(AppBlock)), const Size(126, 34));
    });

    testWidgets('child 原样渲染（find.text 命中）', (tester) async {
      await _pump(
        tester,
        const AppBlock(
          variant: AppBlockVariant.setting,
          child: ListTile(title: Text('设置项标题'), subtitle: Text('设置项副标题')),
        ),
      );
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('设置项标题'), findsOneWidget);
      expect(find.text('设置项副标题'), findsOneWidget);
    });

    testWidgets('margin 生效（尺寸不含外边距）', (tester) async {
      await _pump(
        tester,
        const AppBlock(
          variant: AppBlockVariant.comment,
          margin: EdgeInsets.only(left: 8, top: 4),
          child: SizedBox(width: 10, height: 10),
        ),
      );
      // Container 最外层是 margin 的 Padding → 取里层 DecoratedBox 量尺寸/位置
      final decor = find
          .descendant(
            of: find.byType(AppBlock),
            matching: find.byType(DecoratedBox),
          )
          .first;
      expect(tester.getSize(decor), const Size(36, 34)); // 1+12+10+12+1 ；1+12+10+10+1
      expect(tester.getTopLeft(decor), const Offset(8, 4));
    });
  });

  group('specOverride / 配色跟随', () {
    testWidgets('specOverride 一次性微调生效', (tester) async {
      await _pump(
        tester,
        AppBlock(
          variant: AppBlockVariant.comment,
          specOverride: const AppBlockSpec(
            background: kPaperWarm,
            stroke: kRuleStrong,
            strokeWidth: 1,
            radius: kRadiusSm,
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            leftRule: kError,
            leftRuleWidth: 3,
            leftRuleHeight: 12,
            leftRuleTop: 4,
          ),
          child: const Text('危险区'),
        ),
      );

      final d = _decoration(tester);
      expect(d.color, kPaperWarm);
      expect(d.borderRadius, BorderRadius.circular(kRadiusSm));
      expect(d.border, Border.all(color: kRuleStrong, width: 1));
      expect(_box(tester).clipBehavior, Clip.antiAlias);
      expect(tester.getSize(_ruleFinder()), const Size(3, 12));
      expect(_ruleDecoration(tester).color, kError);
    });

    testWidgets('竖条色跟随配色：浅墨配方自动压深（≠ ink，仍 ≥ 3:1）', (tester) async {
      final palette =
          AppPalette.fromRecipe(inkRecipeById('powder_blue_signal_red')!);
      await _pump(
        tester,
        const AppBlock(variant: AppBlockVariant.reply, child: Text('回复内容')),
        theme: ThemeData(extensions: [palette]),
      );

      final s = appBlockSpec(_ctx(tester), AppBlockVariant.reply);
      expect(s.leftRule, palette.inkDeco);
      expect(s.leftRule, isNot(palette.ink), reason: '粉蓝原墨太浅，应被压深');
      expect(
        contrastRatio(s.leftRule!, kPaper),
        greaterThanOrEqualTo(kMinContrastGraphic),
      );
      expect(_ruleDecoration(tester).color, palette.inkDeco);
    });
  });
}

/// 块内部的 Stack（裸 `find.byType(Stack)` 会连 MaterialApp 自己的 Stack 一起命中）
Finder _stackFinder() =>
    find.descendant(of: find.byType(AppBlock), matching: find.byType(Stack));

/// 竖条容器（本文件多处复用）
Finder _ruleFinder() =>
    find.descendant(of: _stackFinder(), matching: find.byType(Container));
