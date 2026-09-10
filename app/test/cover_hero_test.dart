// 单测：封面 Hero 包装件（CoverHero / coverHeroTag）
//
// 覆盖点：
// - tag=null：树里连 Hero / HeroMode 都不出现（零影响保证），child 原样渲染
// - enabled=false：即使 tag 非空也不包 Hero
// - tag 非空：恰好一个 Hero，且 flightShuttleBuilder 取 to 侧 child + 0.6→1.0 淡入
// - coverHeroTag：空 bvid → null；无分集 → 'cover:BVx'；分集 → 后缀不同
// - 同树两个不同 tag 的 CoverHero 不报错
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/cover_hero.dart';

/// 作用域限定在 CoverHero 之内，避开 framework / MaterialApp 自带的无关 Hero。
Finder _heroUnder() => find.descendant(
      of: find.byType(CoverHero),
      matching: find.byType(Hero),
    );

Finder _heroModeUnder() => find.descendant(
      of: find.byType(CoverHero),
      matching: find.byType(HeroMode),
    );

void main() {
  setUp(() => MotionControl.enabled = false);
  tearDown(MotionControl.reset);

  testWidgets('tag: null → 零 Hero 节点，child 原样渲染', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CoverHero(tag: null, child: Text('封面'))),
    );

    expect(_heroUnder(), findsNothing);
    expect(_heroModeUnder(), findsNothing); // 连 HeroMode 机制都不进树
    expect(find.text('封面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabled: false → 即使 tag 非空也不包 Hero', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CoverHero(tag: 'cover:BV1', enabled: false, child: Text('封面')),
      ),
    );

    expect(_heroUnder(), findsNothing);
    expect(_heroModeUnder(), findsNothing);
    expect(find.text('封面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tag 非空 → 恰好一个 Hero，shuttle 取 to 侧 child 并带淡入', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CoverHero(tag: 'cover:BV1', child: Text('封面')),
      ),
    );

    expect(_heroUnder(), findsOneWidget);
    final hero = tester.widget<Hero>(_heroUnder());
    expect(hero.tag, 'cover:BV1');
    expect(hero.child, isA<Text>());

    // 手动驱动 shuttle builder：两端 Hero 的 BuildContext 都是 Hero 自己的
    // context（`toHeroContext.widget` 是 Hero 本身，不是它的 child）。
    final heroContext = tester.element(_heroUnder());
    final shuttle = hero.flightShuttleBuilder!(
      heroContext,
      const AlwaysStoppedAnimation<double>(0.5),
      HeroFlightDirection.push,
      heroContext,
      heroContext,
    );
    expect(shuttle, isA<FadeTransition>());
    final fade = shuttle as FadeTransition;
    expect(fade.child, isA<Text>()); // 取的是 to 侧 Hero 的 child（那份封面图）
    // 0.5 处 = 0.6 → 1.0 的中点 = 0.8：飞行中不会先全透明再"啪"地落地
    expect(fade.opacity.value, closeTo(0.8, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('同树两个不同 tag 的 CoverHero 不报错', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            CoverHero(tag: 'cover:BV1', child: Text('A')),
            CoverHero(tag: 'cover:BV2', child: Text('B')),
          ],
        ),
      ),
    );

    expect(_heroUnder(), findsNWidgets(2));
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('coverHeroTag：空 bvid → null；分集用后缀区分', () {
    expect(coverHeroTag(''), isNull);
    expect(coverHeroTag('BV1'), 'cover:BV1');
    // pageIndex = 0 是合法分集（用 == null 判定，不会被当成"没传"）
    expect(coverHeroTag('BV1', pageIndex: 0), 'cover:BV1#0');
    expect(
      coverHeroTag('BV1', pageIndex: 1),
      isNot(coverHeroTag('BV1', pageIndex: 0)),
    );
    // 无分集 vs 有分集也必须是不同 tag（否则同页两处配对会串图）
    expect(
      coverHeroTag('BV1'),
      isNot(coverHeroTag('BV1', pageIndex: 0)),
    );
    expect(coverHeroTag('BV1', pageIndex: 0), isNot(coverHeroTag('BV2', pageIndex: 0)));
  });
}
