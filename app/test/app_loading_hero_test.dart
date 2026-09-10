// AppLoadingHero（lib/widgets/app_state_view.dart）组件测试：
// - 测试环境（MotionControl.enabled 默认 false）下剪影走静态帧、
//   pumpAndSettle 能收敛（无限循环动画若没关掉，这里会超时）
// - 主文案是**单一 Text**（find.text 锚点成立），默认命中「正在加载…」
// - scrollable: true → ListView + AlwaysScrollableScrollPhysics；false → 无 ListView
// - title 直给压过 copyId
// - pool + seed 决定的副文案确定性（同 seed 同一条）+ 用户覆盖立刻生效
// - MotionControl.enabled = true → 剪影 ticker 启动、卸载后归零（不泄漏）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/loading_copy.dart';
import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/animated_copy_line.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/smoke_silhouette.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

/// 当前渲染出的副文案（AnimatedCopyLine 收到的那串文本）。
String _subCopy(WidgetTester tester) =>
    tester.widget<AnimatedCopyLine>(find.byType(AnimatedCopyLine)).text;

void main() {
  setUp(() {
    // 单例文案库跨测试共享 → 每条用例先重置成出厂默认
    UiCopyStore.instance.resetForTest();
    // 每条用例从"环境默认"出发（测试环境 = false）
    MotionControl.reset();
  });
  // 不在这里复位 activeTickers：让"上一个用例漏了 ticker"暴露成下一个用例的
  // 失败，而不是被悄悄抹平（与 smoke_silhouette_test 同约定）。
  tearDown(MotionControl.reset);

  testWidgets('测试环境默认：剪影静态（零 ticker），pumpAndSettle 能收敛', (tester) async {
    expect(MotionControl.enabled, isFalse);
    await _pump(tester, const AppLoadingHero());

    expect(find.byType(SmokeSilhouette), findsOneWidget);
    expect(SmokeSilhouette.activeTickers, 0);
    // 循环动画若还在跑，这一行会一直等不到静止 → 超时
    await tester.pumpAndSettle();
    expect(SmokeSilhouette.activeTickers, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(SmokeSilhouette.activeTickers, 0);
  });

  testWidgets('主文案是单一 Text：默认命中「正在加载…」', (tester) async {
    await _pump(tester, const AppLoadingHero());

    // 主文案必须整串落在一个 Text 里，find.text 才命中（不走逐字特效）
    expect(find.text('正在加载…'), findsOneWidget);
    expect(tester.widgetList<Text>(find.text('正在加载…')).length, 1);
    // 逐字特效只承担副文案
    expect(find.byType(AnimatedCopyLine), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('title 直给压过 copyId', (tester) async {
    await _pump(tester, const AppLoadingHero(title: '正在同步白名单…'));

    expect(find.text('正在同步白名单…'), findsOneWidget);
    expect(find.text('正在加载…'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scrollable: true → ListView + AlwaysScrollableScrollPhysics',
      (tester) async {
    await _pump(tester, const AppLoadingHero(scrollable: true));

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.physics, isA<AlwaysScrollableScrollPhysics>());
    // 内容照常渲染（撑开可滚动区域的是 ListView + 顶部留白）
    expect(find.byType(SmokeSilhouette), findsOneWidget);
    expect(find.text('正在加载…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scrollable: false → 不产生 ListView（纯静态区域）', (tester) async {
    await _pump(tester, const AppLoadingHero());

    expect(find.byType(ListView), findsNothing);
    expect(find.byType(Column), findsWidgets);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shrink: true → 靠上（比居中态更靠上），且仍无 ListView', (tester) async {
    await _pump(tester, const AppLoadingHero());
    final centeredTop = tester.getTopLeft(find.byType(SmokeSilhouette)).dy;

    await _pump(tester, const AppLoadingHero(shrink: true));
    final shrunkTop = tester.getTopLeft(find.byType(SmokeSilhouette)).dy;

    expect(shrunkTop, 0);
    expect(shrunkTop, lessThan(centeredTop));
    expect(find.byType(ListView), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pool + seed 决定的副文案：同 seed 同一条，与 loadingCopyFor 一致',
      (tester) async {
    await _pump(
      tester,
      const AppLoadingHero(pool: kLoadingPoolEmpty, seed: 'empty.comment'),
    );
    final first = _subCopy(tester);
    expect(first, loadingCopyFor(pool: kLoadingPoolEmpty, seed: 'empty.comment'));
    expect(first, isNotEmpty);

    // 同 seed 重建 → 还是同一条（不闪变）
    await _pump(
      tester,
      const AppLoadingHero(pool: kLoadingPoolEmpty, seed: 'empty.comment'),
    );
    expect(_subCopy(tester), first);

    // 换池 → 副文案换成新池里的某一条（仍然由 seed 决定）
    await _pump(
      tester,
      const AppLoadingHero(pool: kLoadingPoolFooter, seed: 'empty.comment'),
    );
    final footerExpected =
        loadingCopyFor(pool: kLoadingPoolFooter, seed: 'empty.comment');
    expect(_subCopy(tester), footerExpected);
    expect(
      kLoadingPoolFooter.map((id) => UiCopyStore.instance.text(id)),
      contains(footerExpected),
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('副文案走 UiCopyStore：用户覆盖立刻生效', (tester) async {
    UiCopyStore.instance.resetForTest({'loading.line.1': '改过的闲话'});
    await _pump(
      tester,
      // 单条池 → seed 怎么算都落在这一条上
      AppLoadingHero(pool: const ['loading.line.1'], seed: 'anything'),
    );

    expect(_subCopy(tester), '改过的闲话');
    expect(find.byType(AnimatedCopyLine), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('MotionControl.enabled = true → 剪影 ticker 启动，卸载后归零',
      (tester) async {
    MotionControl.enabled = true;
    await _pump(tester, const AppLoadingHero());

    expect(SmokeSilhouette.activeTickers, 1);
    // 剪影在无限循环 → 只能 pump 固定帧，不能 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 400));
    expect(SmokeSilhouette.activeTickers, 1);

    await tester.pumpWidget(const SizedBox());
    expect(SmokeSilhouette.activeTickers, 0);
    expect(tester.takeException(), isNull);
  });
}
