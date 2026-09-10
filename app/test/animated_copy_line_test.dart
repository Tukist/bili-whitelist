// AnimatedCopyLine 测试（lib/widgets/animated_copy_line.dart）：
// - 关动效 → 退化成单个 Text，整串能被 find.text 命中
// - 开动效 → 逐字 widget（Opacity 数量 == 码点数），且整串不再是一个 Text
// - pumpAndSettle 能收敛（总时长有限，不是无限 ticker）
// - 长句（>30 字）自动降级成 dense 步进；超长句总时长仍封顶 ~700ms
// - keywords 上色不崩、仍收敛；逐字路径语义只读整句（读屏不会一个字一个字念）
// - 文案在动画中被换掉 → 按新字数重建，不崩
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_motion.dart';
import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/animated_copy_line.dart';

const _sentence = '人生有时就得管没有肉的青椒肉丝，叫青椒肉丝。';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );
}

Finder _in(Finder matching) => find.descendant(
      of: find.byType(AnimatedCopyLine),
      matching: matching,
    );

List<Opacity> _chars(WidgetTester tester) =>
    tester.widgetList<Opacity>(_in(find.byType(Opacity))).toList(growable: false);

/// 最后一个字的当前透明度（没有逐字层 = 1.0）
double _lastOpacity(WidgetTester tester) {
  final chars = _chars(tester);
  return chars.isEmpty ? 1.0 : chars.last.opacity;
}

/// 逐字特效的实测总时长（5ms 一格，直到最后一个字到位）。
/// 用来断言「dense 降级」与「总时长封顶」这两件看不见的事。
Future<int> _measureTotalMs(WidgetTester tester) async {
  var elapsed = 0;
  const tick = 5;
  while (elapsed < 3000) {
    await tester.pump(const Duration(milliseconds: tick));
    elapsed += tick;
    if (_lastOpacity(tester) >= 1.0) break;
  }
  return elapsed;
}

void main() {
  setUp(() => MotionControl.enabled = false);
  tearDown(MotionControl.reset);

  group('关动效（退化路径）', () {
    testWidgets('单个 Text，整串命中，无逐字/语义包裹层', (tester) async {
      await _pump(tester, const AnimatedCopyLine(text: _sentence));

      expect(find.text(_sentence), findsOneWidget);
      expect(_in(find.byType(Opacity)), findsNothing);
      // 逐字路径才会加 ExcludeSemantics；退化路径的 Text 自己也不带
      // （裸 find.byType 会命中 MaterialApp 的 ModalBarrier）
      expect(_in(find.byType(ExcludeSemantics)), findsNothing);
    });

    testWidgets('style 原样透给那个 Text', (tester) async {
      await _pump(
        tester,
        const AnimatedCopyLine(
          text: _sentence,
          style: TextStyle(fontSize: 30, color: kError),
        ),
      );

      final text = tester.widget<Text>(find.text(_sentence));
      expect(text.style?.fontSize, 30);
      expect(text.style?.color, kError);
    });
  });

  group('逐字特效', () {
    testWidgets('每字一个 Opacity（数量 == 码点数）', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const AnimatedCopyLine(text: _sentence));
      await tester.pump(const Duration(milliseconds: 20));

      expect(_chars(tester).length, _sentence.runes.length);
      // 特效路径**没有**整串 Text —— 这正是它不能套既有主文案的原因
      expect(find.text(_sentence), findsNothing);
      expect(_in(find.byType(ExcludeSemantics)), findsOneWidget);

      await tester.pumpAndSettle();
    });

    testWidgets('pumpAndSettle 收敛，结束后每字到位', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const AnimatedCopyLine(text: _sentence));
      await tester.pump(const Duration(milliseconds: 20));

      // 有限时长 → 必然收敛（不会像无限动画那样 timeout）
      await tester.pumpAndSettle();
      expect(_chars(tester).every((o) => o.opacity == 1.0), isTrue);
    });

    testWidgets('逐字路径语义只读整句（读屏不会一个字一个字念）', (tester) async {
      MotionControl.enabled = true;
      final handle = tester.ensureSemantics();
      await _pump(tester, const AnimatedCopyLine(text: _sentence));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.bySemanticsLabel(_sentence), findsAtLeastNWidgets(1));
      expect(_in(find.byType(ExcludeSemantics)), findsOneWidget);

      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('文案在动画中被换掉 → 按新字数重建，不崩', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const AnimatedCopyLine(text: '短句。'));
      await tester.pump(const Duration(milliseconds: 30));

      await _pump(tester, const AnimatedCopyLine(text: _sentence));
      await tester.pump(const Duration(milliseconds: 10));

      expect(_chars(tester).length, _sentence.runes.length);
      await tester.pumpAndSettle();
    });
  });

  group('总时长（降级与封顶）', () {
    testWidgets('短句：总时长 = step × (n-1) + charDur', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const AnimatedCopyLine(text: _sentence));

      final n = _sentence.runes.length; // 22 字，不触发 dense
      expect(n, lessThanOrEqualTo(30));
      final expected = kCopyCharStep.inMilliseconds * (n - 1) +
          kCopyCharDur.inMilliseconds;
      final measured = await _measureTotalMs(tester);
      expect(measured, inInclusiveRange(expected - 5, expected + 5));
    });

    testWidgets('长句（>30 字）：降级成 dense 步进', (tester) async {
      MotionControl.enabled = true;
      final long = '青椒肉丝' * 8; // 32 字
      await _pump(tester, AnimatedCopyLine(text: long));

      final n = long.runes.length;
      expect(n, greaterThan(30));
      final expected = kCopyCharStepDense.inMilliseconds * (n - 1) +
          kCopyCharDur.inMilliseconds;
      // dense 一定比常规步进快
      expect(expected,
          lessThan(kCopyCharStep.inMilliseconds * (n - 1) + kCopyCharDur.inMilliseconds));

      final measured = await _measureTotalMs(tester);
      expect(measured, inInclusiveRange(expected - 5, expected + 5));
    });

    testWidgets('超长句：总时长仍封顶在 ~700ms', (tester) async {
      MotionControl.enabled = true;
      final veryLong =
          '人生有时就得管没有肉的青椒肉丝，叫青椒肉丝，还得趁热吃才不辜负这一锅烟火气。' * 4;
      expect(veryLong.runes.length, greaterThan(60));
      await _pump(tester, AnimatedCopyLine(text: veryLong));

      final measured = await _measureTotalMs(tester);
      expect(measured, lessThanOrEqualTo(705));
      expect(measured, greaterThan(600));
    });
  });

  group('关键词上色', () {
    testWidgets('命中关键词的字用 inkDeep，其余用默认灰，且能收敛', (tester) async {
      MotionControl.enabled = true;
      await _pump(
        tester,
        const AnimatedCopyLine(
          text: _sentence,
          keywords: <String>['青椒肉丝'],
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      final colors = <Color?>{};
      for (final text in tester.widgetList<Text>(_in(find.byType(Text)))) {
        final span = text.textSpan;
        if (span is TextSpan) colors.add(span.style?.color);
      }
      expect(colors, contains(kInkGray70), reason: '非关键词用默认灰');
      expect(colors, contains(AppPalette.fallback.inkDeep),
          reason: '关键词用同一支墨的深一档');

      await tester.pumpAndSettle();
      expect(_chars(tester).every((o) => o.opacity == 1.0), isTrue);
    });

    testWidgets('关键词为空 / 不存在于文案：不崩', (tester) async {
      MotionControl.enabled = true;
      await _pump(
        tester,
        const AnimatedCopyLine(
          text: _sentence,
          keywords: <String>['不存在的词', ''],
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));

      expect(_chars(tester).length, _sentence.runes.length);
      await tester.pumpAndSettle();
    });
  });
}
