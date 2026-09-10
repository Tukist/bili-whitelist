// StaggeredEntrance / StaggeredListScope / EntranceLedger 测试
// （lib/widgets/staggered_entrance.dart）：
// - 关动效 → 直接是 child（树里无 FadeTransition / Transform / Opacity）
// - 开动效 → 动画期有飞行层，pumpAndSettle 后包裹层被卸载
// - 记账不重播（同账本同 entryKey 的新 element 不再动画）；不同 entryKey 会动画
// - generation 变化 → 宿主换新账本 → 允许重播一次
// - 动画期内点击不被阻断（飞行只管 opacity + translate，没有 IgnorePointer）
// - maxIndex 延迟封顶；动画中途卸载时 ticker 正常释放
// - 无 scope 单独用时照常播放
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/staggered_entrance.dart';

const _dur = Duration(milliseconds: 100);
const _step = Duration(milliseconds: 20);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
    ),
  );
}

Future<void> _pumpScoped(
  WidgetTester tester, {
  required Object generation,
  required EntranceLedger ledger,
  required Widget child,
}) async {
  await _pump(
    tester,
    StaggeredListScope(
      generation: generation,
      ledger: ledger,
      child: child,
    ),
  );
}

Finder _in(Finder matching) => find.descendant(
      of: find.byType(StaggeredEntrance),
      matching: matching,
    );

/// 当前飞行进度（没有飞行层 = 1.0）
double _opacity(WidgetTester tester) {
  final fades = tester
      .widgetList<FadeTransition>(_in(find.byType(FadeTransition)))
      .toList(growable: false);
  return fades.isEmpty ? 1.0 : fades.first.opacity.value;
}

void main() {
  setUp(() => MotionControl.enabled = false);
  tearDown(MotionControl.reset);

  group('EntranceLedger', () {
    test('claim：首次 true 并记账，之后 false；clear 后可再claim', () {
      final ledger = EntranceLedger();
      expect(ledger.size, 0);
      expect(ledger.claim('a'), isTrue);
      expect(ledger.claim('a'), isFalse);
      expect(ledger.claim('b'), isTrue);
      expect(ledger.size, 2);
      ledger.clear();
      expect(ledger.size, 0);
      expect(ledger.claim('a'), isTrue);
    });
  });

  group('StaggeredListScope', () {
    test('generation / 账本变化都要通知依赖者', () {
      final ledger = EntranceLedger();
      StaggeredListScope scope(Object gen, EntranceLedger l) =>
          StaggeredListScope(
            generation: gen,
            ledger: l,
            child: const SizedBox.shrink(),
          );

      final old = scope('g1', ledger);
      expect(scope('g1', ledger).updateShouldNotify(old), isFalse);
      expect(scope('g2', ledger).updateShouldNotify(old), isTrue,
          reason: 'generation 变 → 必须重建');
      expect(scope('g1', EntranceLedger()).updateShouldNotify(old), isTrue,
          reason: '账本换新 → 必须重建');
    });

    testWidgets('maybeOf：无 scope → null；有 scope → 拿到同一个账本', (tester) async {
      StaggeredListScope? found;
      await _pump(
        tester,
        Builder(builder: (c) {
          found = StaggeredListScope.maybeOf(c);
          return const SizedBox.shrink();
        }),
      );
      expect(found, isNull);

      final ledger = EntranceLedger();
      await _pumpScoped(
        tester,
        generation: 'g1',
        ledger: ledger,
        child: Builder(builder: (c) {
          found = StaggeredListScope.maybeOf(c);
          return const SizedBox.shrink();
        }),
      );
      expect(found, isNotNull);
      expect(identical(found!.ledger, ledger), isTrue);
    });
  });

  group('关动效', () {
    testWidgets('直接是 child：无 FadeTransition / Transform / Opacity', (tester) async {
      await _pump(
        tester,
        const StaggeredEntrance(
          entryKey: 'a',
          enabled: false,
          child: Text('条目'),
        ),
      );
      await tester.pump();

      expect(find.text('条目'), findsOneWidget);
      expect(_in(find.byType(FadeTransition)), findsNothing);
      expect(_in(find.byType(Transform)), findsNothing);
      expect(_in(find.byType(Opacity)), findsNothing);
    });

    testWidgets('MotionControl.enabled = false 走同一条退化路径', (tester) async {
      MotionControl.enabled = false;
      await _pump(
        tester,
        const StaggeredEntrance(entryKey: 'a', child: Text('条目')),
      );
      await tester.pump();

      expect(find.text('条目'), findsOneWidget);
      expect(_in(find.byType(FadeTransition)), findsNothing);
    });
  });

  group('开动效', () {
    testWidgets('动画期有飞行层；settle 后包裹层卸载', (tester) async {
      MotionControl.enabled = true;
      await _pump(
        tester,
        const StaggeredEntrance(
          entryKey: 'a',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pump();

      expect(_in(find.byType(FadeTransition)), findsOneWidget);
      expect(_in(find.byType(Transform)), findsOneWidget);

      await tester.pumpAndSettle();
      // 归零：树里不留残余包裹层（拖拽/长按命中测试回到干净状态）
      expect(_in(find.byType(FadeTransition)), findsNothing);
      expect(_in(find.byType(Transform)), findsNothing);
      expect(find.text('条目'), findsOneWidget);
      expect(_opacity(tester), 1.0);
    });

    testWidgets('无 scope 单独用：照常播放', (tester) async {
      MotionControl.enabled = true;
      await _pump(
        tester,
        const StaggeredEntrance(
          entryKey: 'a',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pump();

      expect(_in(find.byType(FadeTransition)), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_in(find.byType(FadeTransition)), findsNothing);
    });

    testWidgets('index 越大越晚起步', (tester) async {
      MotionControl.enabled = true;
      const first = StaggeredEntrance(
        key: ValueKey('i0'),
        entryKey: 'i0',
        step: _step,
        duration: _dur,
        child: Text('条目'),
      );
      const later = StaggeredEntrance(
        key: ValueKey('i3'),
        entryKey: 'i3',
        index: 3,
        step: _step,
        duration: _dur,
        child: Text('条目'),
      );

      await _pump(tester, first);
      await tester.pump(const Duration(milliseconds: 30));
      final op0 = _opacity(tester);

      await _pump(tester, later);
      await tester.pump(const Duration(milliseconds: 30));
      final op3 = _opacity(tester);

      expect(op3, lessThan(op0));
      await tester.pumpAndSettle();
    });
  });

  group('记账（不重播 / 允许重播）', () {
    testWidgets('同账本同 entryKey：首演动画，重建不重播', (tester) async {
      MotionControl.enabled = true;
      final ledger = EntranceLedger();

      await _pumpScoped(
        tester,
        generation: 'g1',
        ledger: ledger,
        child: const StaggeredEntrance(
          key: ValueKey('first'),
          entryKey: 'v1',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pump();
      expect(_in(find.byType(FadeTransition)), findsOneWidget, reason: '首演');
      await tester.pumpAndSettle();
      expect(ledger.size, 1);

      // 换 key = 新 element（等价于列表回收后重建）
      await _pumpScoped(
        tester,
        generation: 'g1',
        ledger: ledger,
        child: const StaggeredEntrance(
          key: ValueKey('second'),
          entryKey: 'v1',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pump();
      expect(_in(find.byType(FadeTransition)), findsNothing, reason: '演过了');
      expect(find.text('条目'), findsOneWidget);
    });

    testWidgets('不同 entryKey：照样动画', (tester) async {
      MotionControl.enabled = true;
      final ledger = EntranceLedger();

      await _pumpScoped(
        tester,
        generation: 'g1',
        ledger: ledger,
        child: const StaggeredEntrance(
          key: ValueKey('first'),
          entryKey: 'v1',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pumpAndSettle();

      await _pumpScoped(
        tester,
        generation: 'g1',
        ledger: ledger,
        child: const StaggeredEntrance(
          key: ValueKey('second'),
          entryKey: 'v2',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pump();
      expect(_in(find.byType(FadeTransition)), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('generation 变化 → 宿主换新账本 → 同 entryKey 允许重播一次', (tester) async {
      MotionControl.enabled = true;
      final first = EntranceLedger();

      await _pumpScoped(
        tester,
        generation: 'bvid_1',
        ledger: first,
        child: const StaggeredEntrance(
          key: ValueKey('bvid_1'),
          entryKey: 'v1',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pumpAndSettle();
      expect(first.size, 1);

      // 重新加载 / 换 bvid：generation 变，宿主给一本新账（列表也随之重建，
      // 所以 element 是新的 —— 记账只在 element 首次挂载时读一次）
      final second = EntranceLedger();
      await _pumpScoped(
        tester,
        generation: 'bvid_2',
        ledger: second,
        child: const StaggeredEntrance(
          key: ValueKey('bvid_2'),
          entryKey: 'v1',
          duration: _dur,
          child: Text('条目'),
        ),
      );
      await tester.pump();
      expect(_in(find.byType(FadeTransition)), findsOneWidget, reason: '换数据源可再演一次');
      await tester.pumpAndSettle();
    });
  });

  group('交互与生命周期', () {
    testWidgets('动画期内点击不被阻断', (tester) async {
      MotionControl.enabled = true;
      var taps = 0;
      await _pump(
        tester,
        StaggeredEntrance(
          entryKey: 'a',
          duration: const Duration(milliseconds: 300),
          child: GestureDetector(
            onTap: () => taps++,
            child: const SizedBox(
              width: 200,
              height: 60,
              child: Center(child: Text('点我')),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30)); // 飞行中

      expect(_in(find.byType(FadeTransition)), findsOneWidget);
      await tester.tap(find.text('点我'));
      await tester.pump();
      expect(taps, 1, reason: '飞行只管 opacity + translate，不加 IgnorePointer');
      await tester.pumpAndSettle();
    });

    testWidgets('maxIndex 封顶：index=100 与 index=maxIndex 进度一致', (tester) async {
      MotionControl.enabled = true;
      const maxIndex = 5;

      await _pump(
        tester,
        const StaggeredEntrance(
          key: ValueKey('at_max'),
          entryKey: 'at_max',
          index: maxIndex,
          step: _step,
          duration: _dur,
          maxIndex: maxIndex,
          child: Text('条目'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final capped = _opacity(tester);

      await _pump(
        tester,
        const StaggeredEntrance(
          key: ValueKey('huge'),
          entryKey: 'huge',
          index: 100,
          step: _step,
          duration: _dur,
          maxIndex: maxIndex,
          child: Text('条目'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final huge = _opacity(tester);

      expect(capped, greaterThan(0));
      expect(capped, lessThan(1));
      // 延迟 = step × min(index, maxIndex) → 两者同进度
      expect(huge, moreOrLessEquals(capped, epsilon: 1e-6));
      await tester.pumpAndSettle();
    });

    testWidgets('动画中途卸载：ticker 正常释放，不抛异常', (tester) async {
      MotionControl.enabled = true;
      await _pump(
        tester,
        const StaggeredEntrance(
          entryKey: 'a',
          duration: Duration(seconds: 5),
          child: Text('条目'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(_in(find.byType(FadeTransition)), findsOneWidget);

      // 卸载（等价于列表滚出屏幕后被回收）
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pump();

      expect(find.byType(StaggeredEntrance), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
