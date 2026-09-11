// 通用「左滑露出操作块」组件测试（SwipeActionBox）：
// - enabled:false → 直接就是 child（树里没有 Stack / 手势层）
// - 左滑露出操作块；过半吸附、不足回位；右滑收回
// - 点操作块 → 回调一次 + 自动收回
// - 已露出时点卡片本体 → 只收回，**不**透传给 child 的 onTap
// - 触摸目标 ≥ 48dp；小位移（5px）不触发
// - 关动效（测试默认）走无 controller 路径：零 ticker；开动效 → 补间收敛
// - 跨卡联动：同屏只允许一张露出（滑开 B → A 自动收回）
// - 列表一滚就收回；卸载时清空「当前打开者」的静态引用
// - 操作块区只裁右外缘圆角，左缘直角 + 同色补角垫片（卡片圆角处不留背景缝）
// 全部走 MaterialApp + 定宽 SizedBox，不依赖任何原生插件。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/swipe_action_box.dart';

/// 测试用单块宽度：2 × 76 = 152（与合集卡一致）。
const double _kW = 76;

/// 全露后的总位移（px）。
const double _kTravel = _kW * 2;

/// 量触摸目标要用的经典尺寸。
const double _kMinTapTarget = 48;

/// 挂一个定宽 300 的 SwipeActionBox；child 是 84 高、可点的「卡片」。
///
/// 每次操作块 / 卡片被点都往 [calls] 追加自己的名字，用来断言
/// 「回调几次」与「有没有误触」。
Future<void> _pump(
  WidgetTester tester, {
  required bool enabled,
  List<String>? calls,
}) async {
  final log = calls ?? <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: SwipeActionBox(
              enabled: enabled,
              actionWidth: _kW,
              actions: [
                SwipeAction(
                  label: '重命名',
                  icon: Icons.drive_file_rename_outline,
                  color: const Color(0xFF002FA7),
                  onTap: () => log.add('rename'),
                ),
                SwipeAction(
                  label: '删除',
                  icon: Icons.delete_outline,
                  color: const Color(0xFFC83232),
                  onTap: () => log.add('delete'),
                ),
              ],
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => log.add('child'),
                child: const SizedBox(
                  height: 84,
                  child: ColoredBox(
                    color: Color(0xFFE9E9E5),
                    child: Center(child: Text('卡片')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 抓手点：卡片**在宿主盒子内**可见的那一段（左侧 40px 处）。
///
/// 不能用 `find.text('卡片')` 的中心：露出后卡片被左移，文字中心会跑到
/// 宿主盒子左边之外（那里不可命中，手势根本不成立）。
Offset _grabPoint(WidgetTester tester) {
  final r = tester.getRect(find.byType(SwipeActionBox));
  return Offset(r.left + 40, r.center.dy);
}

/// 同 [_grabPoint]，但按 key（`box-A` / `box-B`）挑其中一张 —— 同屏多张卡时用。
Offset _grabPointOf(WidgetTester tester, String tag) {
  final r = tester.getRect(find.byKey(ValueKey<String>('box-$tag')));
  return Offset(r.left + 40, r.center.dy);
}

/// 一屏两张卡：A 在上、B 在下，各有自己的操作块标签（`重命名A` / `删除A`）。
///
/// - [scrollable] = false → 普通 [Column]：验「跨卡联动」；
/// - [scrollable] = true → 放进够长的 [ListView]（两张 400 高的格子 + 尾巴，
///   视口 600 → 真滚得动）：验「列表一滚就收回」。
Future<void> _pumpPair(
  WidgetTester tester, {
  bool scrollable = false,
  List<String>? calls,
}) async {
  final log = calls ?? <String>[];

  Widget card(String tag) => Center(
        child: SizedBox(
          width: 300,
          child: SwipeActionBox(
            key: ValueKey<String>('box-$tag'),
            actionWidth: _kW,
            actions: [
              SwipeAction(
                label: '重命名$tag',
                icon: Icons.drive_file_rename_outline,
                color: const Color(0xFF002FA7),
                onTap: () => log.add('rename$tag'),
              ),
              SwipeAction(
                label: '删除$tag',
                icon: Icons.delete_outline,
                color: const Color(0xFFC83232),
                onTap: () => log.add('delete$tag'),
              ),
            ],
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => log.add('child$tag'),
              child: SizedBox(
                height: 84,
                child: ColoredBox(
                  color: const Color(0xFFE9E9E5),
                  child: Center(child: Text('卡片$tag')),
                ),
              ),
            ),
          ),
        ),
      );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: scrollable
            ? ListView(
                children: [
                  SizedBox(height: 400, child: card('A')),
                  SizedBox(height: 400, child: card('B')),
                  const SizedBox(height: 400, child: Center(child: Text('尾巴'))),
                ],
              )
            : Column(
                children: [
                  SizedBox(height: 200, child: card('A')),
                  const SizedBox(height: 24),
                  SizedBox(height: 200, child: card('B')),
                ],
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 左滑 / 右滑：按下 → 分步移动（每步都带时间戳，速度可控）→ 抬起 → settle。
///
/// 速度 ≈ `|dx| / (steps * stepMs)` px/s：
/// - 单步大步（默认 steps=1, stepMs=16）→ 上万 px/s = 甩动；
/// - 多步小步（如 4 × 10px / 100ms = 100px/s）→ 慢拖，按位移比例吸附。
///
/// [at] 默认 [_grabPoint]（全屏只有一张卡时用）；多张卡时传 [_grabPointOf]。
Future<void> _swipe(
  WidgetTester tester,
  double dx, {
  int steps = 1,
  int stepMs = 16,
  Offset? at,
}) async {
  final g = await tester.startGesture(at ?? _grabPoint(tester));
  await tester.pump(Duration(milliseconds: stepMs));
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(dx / steps, 0));
    await tester.pump(Duration(milliseconds: stepMs));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  // 跨卡「当前打开者」是模块级静态引用（见 [SwipeActionBox.resetForTest]）：
  // 每个用例前清一次，免得上一个用例的引用串到下一个（项目约定，同
  // `MotionControl.reset()`）。
  setUp(SwipeActionBox.resetForTest);

  group('SwipeActionBox · enabled=false', () {
    testWidgets('直接就是 child：树里没有 Stack / 操作块 / ticker',
        (tester) async {
      await _pump(tester, enabled: false);

      expect(find.text('卡片'), findsOneWidget); // child 原样在树上
      // 没有任何自建布局层（我们的 Stack / 操作块都不该存在）
      expect(
        find.descendant(
          of: find.byType(SwipeActionBox),
          matching: find.byType(Stack),
        ),
        findsNothing,
      );
      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);

      // 左滑也不会露出任何东西
      await _swipe(tester, -200);
      expect(find.text('重命名'), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('SwipeActionBox · 露出与收回', () {
    testWidgets('左滑过半 → 露出「重命名」「删除」', (tester) async {
      await _pump(tester, enabled: true);
      expect(find.text('重命名'), findsNothing); // 合上时不在树上

      await _swipe(tester, -160);

      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('小位移（5px）不触发露出', (tester) async {
      await _pump(tester, enabled: true);

      final g = await tester.startGesture(tester.getCenter(find.text('卡片')));
      await tester.pump(const Duration(milliseconds: 16));
      await g.moveBy(const Offset(-5, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await g.up();
      await tester.pumpAndSettle();

      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('左滑不足一半 → 松手吸附回位（收回）', (tester) async {
      await _pump(tester, enabled: true);

      // 40px / 152 ≈ 0.26 → 不足一半；慢拖（10px/100ms = 100px/s）不构成甩动
      await _swipe(tester, -40, steps: 4, stepMs: 100);

      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('已露出时右滑 → 收回', (tester) async {
      await _pump(tester, enabled: true);
      await _swipe(tester, -160);
      expect(find.text('重命名'), findsOneWidget);

      await _swipe(tester, 160);

      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('已露出时点卡片本体 → 只收回，不透传 child.onTap',
        (tester) async {
      final calls = <String>[];
      await _pump(tester, enabled: true, calls: calls);
      await _swipe(tester, -160);
      expect(find.text('重命名'), findsOneWidget);

      // 卡片可见区的左半部分（右侧 152px 被操作块区占用）
      final box = tester.getRect(find.byType(SwipeActionBox));
      await tester.tapAt(Offset(box.left + 40, box.center.dy));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('child')), reason: '挡板必须拦住这次点击');
      expect(calls, isNot(contains('rename')));
      expect(calls, isNot(contains('delete')));
      expect(find.text('重命名'), findsNothing, reason: '点一下就收回');
    });
  });

  group('SwipeActionBox · 点操作块', () {
    testWidgets('点「重命名」→ 回调一次且自动收回', (tester) async {
      final calls = <String>[];
      await _pump(tester, enabled: true, calls: calls);
      await _swipe(tester, -160);

      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      expect(calls.where((c) => c == 'rename').length, 1);
      expect(calls, isNot(contains('child')), reason: '不该穿到卡片本体');
      expect(find.text('重命名'), findsNothing, reason: '点完自动收回');
    });

    testWidgets('点「删除」→ 回调一次且自动收回', (tester) async {
      final calls = <String>[];
      await _pump(tester, enabled: true, calls: calls);
      await _swipe(tester, -160);

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(calls.where((c) => c == 'delete').length, 1);
      expect(calls, isNot(contains('child')));
      expect(find.text('删除'), findsNothing, reason: '点完自动收回');
    });

    testWidgets('操作块触摸目标 ≥ 48dp', (tester) async {
      await _pump(tester, enabled: true);
      await _swipe(tester, -160);

      for (final label in ['重命名', '删除']) {
        final size =
            tester.getSize(find.byKey(SwipeActionBox.actionKey(label)));
        expect(size.width, greaterThanOrEqualTo(_kMinTapTarget),
            reason: '$label 宽');
        expect(size.height, greaterThanOrEqualTo(_kMinTapTarget),
            reason: '$label 高');
      }
    });
  });

  group('SwipeActionBox · 动效开关', () {
    testWidgets('关动效（测试默认）：零 ticker，位移即时生效', (tester) async {
      MotionControl.enabled = false; // 测试环境默认即 false，显式声明意图
      addTearDown(MotionControl.reset);

      await _pump(tester, enabled: true);

      final g = await tester.startGesture(tester.getCenter(find.text('卡片')));
      await tester.pump(const Duration(milliseconds: 16));
      await g.moveBy(const Offset(-160, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await g.up();
      await tester.pump(); // 只 pump 一帧（不 settle）：无 controller 也不需要等

      expect(find.text('重命名'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0, reason: '零 ticker');

      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);
    });

    testWidgets('开动效：松手后补间把卡片推到底，pumpAndSettle 收敛',
        (tester) async {
      MotionControl.enabled = true;
      addTearDown(MotionControl.reset);

      await _pump(tester, enabled: true);

      // 慢拖 120px（≈0.79 过半 → 吸附到全露）；慢 → 不构成甩动
      final g = await tester.startGesture(tester.getCenter(find.text('卡片')));
      await tester.pump(const Duration(milliseconds: 60));
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await g.up();
      await tester.pump(); // 补间刚起步

      final during = tester.getTopLeft(find.text('卡片')).dx;
      await tester.pumpAndSettle();
      final after = tester.getTopLeft(find.text('卡片')).dx;

      expect(after, lessThan(during), reason: '补间把卡片继续推向左');
      // 松手在 120px（慢拖 4×30），补间补足到全露 152px → 再走 ~32px
      expect(during - after, closeTo(_kTravel - 120, 8),
          reason: '补间补足剩余位移');
      expect(find.text('重命名'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0, reason: 'settle 后静止');
    });
  });

  group('SwipeActionBox · 跨卡联动（同屏只允许一张露出）', () {
    testWidgets('滑开 A 后再滑开 B → A 自动收回，B 露出', (tester) async {
      await _pumpPair(tester);
      final aRest = tester.getTopLeft(find.text('卡片A')).dx;

      await _swipe(tester, -160, at: _grabPointOf(tester, 'A'));
      expect(find.text('重命名A'), findsOneWidget);
      expect(find.text('删除A'), findsOneWidget);
      expect(find.text('重命名B'), findsNothing);

      await _swipe(tester, -160, at: _grabPointOf(tester, 'B'));

      expect(find.text('重命名B'), findsOneWidget, reason: 'B 露出');
      expect(find.text('删除B'), findsOneWidget);
      expect(find.text('重命名A'), findsNothing, reason: 'A 必须自动收回');
      expect(find.text('删除A'), findsNothing);
      expect(tester.getTopLeft(find.text('卡片A')).dx, aRest,
          reason: 'A 的位移归零（卡片回到原位）');
    });

    testWidgets('按到别的卡上（只按下不滑）→ 已露出的 A 收回', (tester) async {
      await _pumpPair(tester);
      await _swipe(tester, -160, at: _grabPointOf(tester, 'A'));
      expect(find.text('重命名A'), findsOneWidget);

      // 只按下再抬起（等价于「点了另一张卡」）：A 不能还挂着
      final g = await tester.startGesture(_grabPointOf(tester, 'B'));
      await tester.pump(const Duration(milliseconds: 16));
      await g.up();
      await tester.pumpAndSettle();

      expect(find.text('重命名A'), findsNothing, reason: '一按到别的卡就收回');
      expect(find.text('重命名B'), findsNothing, reason: 'B 自己没被滑开');
    });

    testWidgets('起手滑 B 但不足一半 → A 先收回，B 自己回位', (tester) async {
      await _pumpPair(tester);
      await _swipe(tester, -160, at: _grabPointOf(tester, 'A'));
      expect(find.text('重命名A'), findsOneWidget);

      // 40px / 152 ≈ 0.26 → 不足一半；慢拖（10px/100ms = 100px/s）不构成甩动
      await _swipe(tester, -40,
          steps: 4, stepMs: 100, at: _grabPointOf(tester, 'B'));

      expect(find.text('重命名B'), findsNothing, reason: 'B 不足一半 → 回位');
      expect(find.text('重命名A'), findsNothing, reason: 'A 已经先收回了');
    });
  });

  group('SwipeActionBox · 滚动收回', () {
    testWidgets('列表一滚 → 已露出的卡收回', (tester) async {
      await _pumpPair(tester, scrollable: true);

      await _swipe(tester, -160, at: _grabPointOf(tester, 'A'));
      expect(find.text('重命名A'), findsOneWidget);
      final restY = tester.getTopLeft(find.text('卡片A')).dy;

      // 竖向拖列表：起点落在两张卡之间的空白处（不碰卡片自己的横向手势）
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('卡片A')).dy, lessThan(restY),
          reason: '列表确实滚动了（否则这条用例什么也没验到）');
      expect(find.text('重命名A'), findsNothing, reason: '一滚就收回');
      expect(find.text('删除A'), findsNothing);
    });
  });

  group('SwipeActionBox · 全局状态清理', () {
    testWidgets('打开状态下卸载 → 静态引用不悬空，新卡照常打开', (tester) async {
      await _pump(tester, enabled: true);
      await _swipe(tester, -160);
      expect(find.text('重命名'), findsOneWidget);

      // 整棵树卸掉：若静态引用还指着这个已 dispose 的 State，下一张卡
      // 一开就会去 setState 它 → 直接抛（本用例的断言会跟着红）
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      await _pump(tester, enabled: true);
      await _swipe(tester, -160);

      expect(tester.takeException(), isNull);
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('resetForTest 可重复调用，清理后新卡正常', (tester) async {
      await _pump(tester, enabled: true);
      await _swipe(tester, -160);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      SwipeActionBox.resetForTest(); // 幂等：清空后再清一次也不炸
      SwipeActionBox.resetForTest();

      await _pump(tester, enabled: true);
      await _swipe(tester, -160);
      expect(find.text('重命名'), findsOneWidget);
    });
  });

  group('SwipeActionBox · 右圆角补角', () {
    testWidgets('合上时不建操作块区 / 补角垫片', (tester) async {
      await _pump(tester, enabled: true);

      expect(find.byKey(SwipeActionBox.actionAreaKey), findsNothing);
      expect(find.byKey(SwipeActionBox.cornerFillKey), findsNothing);
    });

    testWidgets('操作块区只裁右外缘圆角、左缘直角 + 同色垫片垫到卡片圆角底下',
        (tester) async {
      await _pump(tester, enabled: true);
      await _swipe(tester, -160);

      final area = tester.widget<ClipRRect>(
        find.byKey(SwipeActionBox.actionAreaKey),
      );
      final br = area.borderRadius.resolve(TextDirection.ltr);
      expect(br.topRight, Radius.circular(kRadiusMd), reason: '右外缘仍是块化圆角');
      expect(br.bottomRight, Radius.circular(kRadiusMd));
      expect(br.topLeft, Radius.zero,
          reason: '左缘必须直角：圆角的话卡片右圆角缺口里露的还是背景色');
      expect(br.bottomLeft, Radius.zero);

      // 垫片：宽度 = 卡片圆角半径，颜色 = 最左块（也就是贴着卡片的那块）
      final fill = find.byKey(SwipeActionBox.cornerFillKey);
      expect(tester.getSize(fill).width, kRadiusMd);
      expect(tester.widget<ColoredBox>(fill).color, const Color(0xFF002FA7));

      // 几何：块区右端贴宿主右缘，左端比「两个块」再宽一个 kRadiusMd ——
      // 多出来的这一条正好垫在卡片右圆角底下（全露时卡片右缘 = 块区左端
      // + kRadiusMd），缺口里透出来的是块色，不是背景。
      final hostRect = tester.getRect(find.byType(SwipeActionBox));
      final areaRect = tester.getRect(find.byKey(SwipeActionBox.actionAreaKey));
      expect(areaRect.right, closeTo(hostRect.right, .01));
      expect(areaRect.width, closeTo(_kTravel + kRadiusMd, .01));
      expect(
        hostRect.right - _kTravel,
        closeTo(areaRect.left + kRadiusMd, .01),
        reason: '卡片右缘（全露）比块区左端正好多一个圆角半径',
      );
    });

    testWidgets('像素级：卡片右圆角缺口里透出的是块色，不是背景色', (tester) async {
      final boundaryKey = GlobalKey();
      const inkColor = Color(0xFF002FA7);
      const cardColor = Color(0xFFE9E9E5);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 300,
                  child: SwipeActionBox(
                    actionWidth: _kW,
                    actions: [
                      SwipeAction(
                        label: '重命名',
                        icon: Icons.drive_file_rename_outline,
                        color: inkColor,
                        onTap: () {},
                      ),
                    ],
                    // 卡片照真实合集卡的样子带 kRadiusMd 圆角（缺口就是这么来的）
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(kRadiusMd),
                      child: const SizedBox(
                        height: 84,
                        child: ColoredBox(
                          color: cardColor,
                          child: Center(child: Text('卡片')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _swipe(tester, -160); // 单块 76 < 160 → 甩到底，全露

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      final origin = tester.getTopLeft(find.byKey(boundaryKey));
      final box = tester.getRect(find.byType(SwipeActionBox));
      // 全露后卡片右缘 = box 右缘 - 单块宽；取它右上圆角缺口里的一像素
      // （缺口 = 以 (cardRight-8, top+8) 为心、半径 8 的圆之外那一角）。
      // 这张图只包含本组件自己的绘制 → 「没画东西」= 真机上透出页面背景色。
      final cardRight = box.right - _kW;
      final probes = <String, Offset>{
        '缺口': Offset(cardRight - 1, box.top + 1),
        // 对照组：圆角内侧，这里应该还是卡片自己的底色（证明坐标没跑偏）
        '卡片右缘内侧': Offset(cardRight - kRadiusMd - 2, box.top + 1),
      };

      final read = <String, Color>{};
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        for (final e in probes.entries) {
          final x = (e.value.dx - origin.dx).round();
          final y = (e.value.dy - origin.dy).round();
          final i = (y * image.width + x) * 4;
          read[e.key] = Color.fromARGB(
            data.getUint8(i + 3), // a
            data.getUint8(i), // r
            data.getUint8(i + 1), // g
            data.getUint8(i + 2), // b
          );
        }
        image.dispose();
      });

      expect(read['缺口'], inkColor,
          reason: '卡片右圆角缺口里必须是块色（透明 = 真机上透出页面背景，就是那道缝）');
      expect(read['卡片右缘内侧'], cardColor, reason: '圆角内侧照旧是卡片本体');
    });
  });
}
