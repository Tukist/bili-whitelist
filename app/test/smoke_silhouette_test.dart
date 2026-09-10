// 单测：通用风衣男抽烟剪影（SmokeSilhouette / SmokeSilhouettePainter）
//
// 覆盖点：
// - animate=false：不创建 AnimationController（activeTickers 恒 0），painter 无进度源
// - animate=true：pump 后恰 1 个 ticker；pumpWidget(SizedBox) 卸载后归零（不泄漏）
// - MotionControl.enabled=false（或系统"减少动画"）：走静态路径，零 ticker
// - size <= 0 / 超大尺寸：不崩、不抛异常
// - 双色取 palette.inkDeco + palette.accent（构造 painter 直接读字段，不用 golden）
// - 默认主题（克莱因蓝 · 陶土）下 inkDeco vs 纸底 ≥ 3:1（WCAG 图形对比度护栏）
//
// 测试统一在 setUp 里关掉全局装饰动画；需要真动画的用例单独打开并在结束前
// 卸载 widget 树（ticker 计数必须归零，否则说明泄漏）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/smoke_silhouette.dart';

/// 取出 SmokeSilhouette 子树里的画笔（作用域限定在组件内，避开
/// MaterialApp 自带的 debug banner 等无关 CustomPaint）。
SmokeSilhouettePainter _painterOf(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byType(SmokeSilhouette),
    matching: find.byType(CustomPaint),
  );
  expect(finder, findsOneWidget);
  return tester.widget<CustomPaint>(finder).painter! as SmokeSilhouettePainter;
}

Finder _ownCustomPaint() => find.descendant(
      of: find.byType(SmokeSilhouette),
      matching: find.byType(CustomPaint),
    );

void main() {
  setUp(() => MotionControl.enabled = false);
  // 不在这里复位 activeTickers：让"上一个用例漏了 ticker"能暴露成下一个用例的
  // 失败，而不是被悄悄抹平。每个创建了 ticker 的用例都显式卸载 widget 树。
  tearDown(MotionControl.reset);

  testWidgets('animate: false → 不创建 ticker，固定画 t=0.35 那一帧', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SmokeSilhouette(animate: false)),
    );

    expect(SmokeSilhouette.activeTickers, 0);
    final painter = _painterOf(tester);
    expect(painter.progress, isNull);
    expect(painter.effectiveT, kStaticSmokeT);

    await tester.pumpWidget(const SizedBox());
    expect(SmokeSilhouette.activeTickers, 0);
  });

  testWidgets('animate: true → 1 个 ticker；卸载后归零（不泄漏）', (tester) async {
    MotionControl.enabled = true;
    await tester.pumpWidget(const MaterialApp(home: SmokeSilhouette()));

    expect(SmokeSilhouette.activeTickers, 1);
    final painter = _painterOf(tester);
    expect(painter.progress, isNotNull);
    expect(painter.progress!.value, inInclusiveRange(0.0, 1.0));

    // 跑几帧：仍是同一个 ticker（不重复创建）
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(SmokeSilhouette.activeTickers, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(SmokeSilhouette.activeTickers, 0);
  });

  testWidgets('MotionControl.enabled = false → 走静态路径（零 ticker）', (tester) async {
    // setUp 已置 false；这里显式传 animate: true，验证全局开关能压住它
    await tester.pumpWidget(
      const MaterialApp(home: SmokeSilhouette(animate: true)),
    );

    expect(SmokeSilhouette.activeTickers, 0);
    expect(_painterOf(tester).progress, isNull);
    expect(_painterOf(tester).effectiveT, kStaticSmokeT);
    expect(tester.takeException(), isNull);
  });

  testWidgets('size <= 0：不崩、不绘制，ticker 记账仍守恒', (tester) async {
    MotionControl.enabled = true;

    await tester.pumpWidget(
      const MaterialApp(home: SmokeSilhouette(size: 0)),
    );
    expect(tester.takeException(), isNull);
    expect(_ownCustomPaint(), findsNothing); // 零尺寸占位，什么都不画
    expect(SmokeSilhouette.activeTickers, 1);

    await tester.pumpWidget(
      const MaterialApp(home: SmokeSilhouette(size: -20)),
    );
    expect(tester.takeException(), isNull);
    expect(_ownCustomPaint(), findsNothing);
    expect(SmokeSilhouette.activeTickers, 1); // 同类型复用 State，不增不减

    await tester.pumpWidget(const SizedBox());
    expect(SmokeSilhouette.activeTickers, 0);
  });

  testWidgets('极端尺寸（1 / 140 / 400）都能渲染，不抛异常', (tester) async {
    for (final side in <double>[1, 140, 400]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: SmokeSilhouette(size: side, animate: false)),
        ),
      );
      expect(_ownCustomPaint(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('双色取 palette.inkDeco / palette.accent（显式传参优先）', (tester) async {
    AppPalette? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            seen = context.palette;
            return const SmokeSilhouette(animate: false);
          },
        ),
      ),
    );

    final painter = _painterOf(tester);
    expect(seen, isNotNull);
    expect(painter.ink, seen!.inkDeco); // 图形/非文字档
    expect(painter.smoke, seen!.accent); // 点缀墨 = 时间与新鲜度

    // 显式传参时以传参为准（不硬编码、也不吞掉调用方的覆盖）
    await tester.pumpWidget(
      const MaterialApp(
        home: SmokeSilhouette(
          animate: false,
          ink: Colors.black,
          smoke: Colors.red,
        ),
      ),
    );
    final overridden = _painterOf(tester);
    expect(overridden.ink, Colors.black);
    expect(overridden.smoke, Colors.red);
  });

  test('默认主题（克莱因蓝 · 陶土）：inkDeco vs 纸底 ≥ 3:1', () {
    final palette = AppPalette.fallback;
    expect(
      contrastRatio(palette.inkDeco, kPaper),
      greaterThanOrEqualTo(kMinContrastGraphic),
    );
  });

  test('painter 直接构造：静态路径取 kStaticSmokeT，动画路径取进度值', () {
    final staticPainter = SmokeSilhouettePainter(
      ink: const Color(0xFF002FA7),
      smoke: const Color(0xFFC65F38),
    );
    expect(staticPainter.progress, isNull);
    expect(staticPainter.effectiveT, kStaticSmokeT);

    final livePainter = SmokeSilhouettePainter(
      ink: const Color(0xFF002FA7),
      smoke: const Color(0xFFC65F38),
      progress: const AlwaysStoppedAnimation<double>(0.72),
    );
    expect(livePainter.effectiveT, 0.72);

    // 颜色变 → 需要重绘；否则动画期间纯靠 listenable 驱动（零额外重绘）
    expect(livePainter.shouldRepaint(staticPainter), isTrue);
    expect(
      staticPainter.shouldRepaint(
        SmokeSilhouettePainter(
          ink: const Color(0xFF002FA7),
          smoke: const Color(0xFFC65F38),
        ),
      ),
      isFalse,
    );
  });
}
