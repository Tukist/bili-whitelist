// 单测：动态「随机游走细线插画」（DotIllustration / DotIllustrationPainter）
//
// 覆盖点：
// - MotionControl.enabled=false（flutter test 默认）：不创建 AnimationController
//   （activeTickers 恒 0）、painter 无进度源、pumpAndSettle 立即收敛
// - animate:false 显式关（全局开关开着也不建 ticker）；true → false 会释放 ticker
// - MotionControl.enabled=true：恰 1 个 ticker；卸载后归零（不泄漏）
// - 确定性（硬要求）：同 seed 两次渲染**逐像素一致**；折线也逐点一致；
//   不同 seed → 路径不同
// - 循环无突变（硬要求）：t 与 t+1 的折线逐点重合；t 走一小步位移 < 1px
// - 平滑（无锯齿）：相邻采样点的转角 < 50°（实测跨 12 个 seed 的 p99 ≈ 23°）
// - 构图：所有采样点都在内容方框（中间 68%）内；相邻两条线的纵向取值
//   范围**不重叠**（线条永不越出自己那条"带"）
// - 参数透传：默认取 palette.inkText / palette.accent，显式传参优先
// - 健壮性：size <= 0 / NaN → 空 box 不崩；正常 size 渲染尺寸 = size
// - 纯装饰：ExcludeSemantics 包裹（读屏不读它）
// - shouldRepaint：只有颜色 / 种子 / 线数 / 静态↔动画切换才需要重绘
//
// 测试统一在 setUp 里关掉全局装饰动画；需要真动画的用例单独打开，并在结束前
// 卸载 widget 树（ticker 计数必须归零，否则说明泄漏）。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/dot_halftone.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';

const Color _ink = Color(0xFF002FA7);
const Color _accent = Color(0xFFC65F38);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );
  await tester.pump();
}

/// 取出 DotIllustration 子树里的画笔（作用域限定在组件内，避开
/// MaterialApp / Scaffold 自带的无关 CustomPaint）。
DotIllustrationPainter _painterOf(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byType(DotIllustration),
    matching: find.byType(CustomPaint),
  );
  expect(finder, findsOneWidget);
  return tester.widget<CustomPaint>(finder).painter! as DotIllustrationPainter;
}

/// 组件自己的 RepaintBoundary（逐像素比对用）。
Finder _boundaryFinder() => find.descendant(
      of: find.byType(DotIllustration),
      matching: find.byType(RepaintBoundary),
    );

/// 抓一帧的像素（RGBA）。用 [RepaintBoundary.toImage] 做**强比对**：
/// 任何路径 / 墨量 / 渐隐的差异都会落成不同的字节。
Future<Uint8List> _pixels(WidgetTester tester) async {
  final finder = _boundaryFinder();
  expect(finder, findsOneWidget);
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// 两张图的平均通道差（0–255）。0 = 逐像素完全一致。
double _meanDiff(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

/// 内容方框：四周留白 16% ⇒ 内容只占中间约 68%（组件契约）。
Rect _contentBox(double side) => Rect.fromLTWH(
      side * 0.16,
      side * 0.16,
      side * 0.68,
      side * 0.68,
    );

const List<String> _seeds = <String>[
  'empty.history',
  'empty.inbox',
  'search.video',
  'stats.heat',
  'collection',
  'comment',
  'favorites',
  'daily_history',
];

List<DotIllustrationPainter> _painterList(
  List<String> seeds, {
  int lineCount = 3,
}) =>
    <DotIllustrationPainter>[
      for (final s in seeds)
        DotIllustrationPainter(
          seed: stableSeed(s),
          ink: _ink,
          accent: _accent,
          lineCount: lineCount,
        ),
    ];

void main() {
  setUp(() => MotionControl.enabled = false);
  // 不在这里复位 activeTickers：让"上一个用例漏了 ticker"能暴露成下一个用例的
  // 失败，而不是被悄悄抹平。每个创建了 ticker 的用例都显式卸载 widget 树。
  tearDown(MotionControl.reset);

  group('装饰性动画开关（MotionControl）', () {
    testWidgets('测试环境默认关：不建 ticker、画静态一帧、pumpAndSettle 立即收敛',
        (tester) async {
      expect(MotionControl.enabled, isFalse);
      await _pump(tester, const DotIllustration(seed: 'empty.history'));

      expect(DotIllustration.activeTickers, 0);
      final painter = _painterOf(tester);
      expect(painter.progress, isNull);
      expect(painter.effectiveT, kStaticWalkT);
      // 没有无限 ticker → settle 不会卡住
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(DotIllustration.activeTickers, 0);
    });

    testWidgets('animate: false → 即使全局开关开着也不建 ticker', (tester) async {
      MotionControl.enabled = true;
      await _pump(
        tester,
        const DotIllustration(seed: 'empty.history', animate: false),
      );

      expect(DotIllustration.activeTickers, 0);
      expect(_painterOf(tester).progress, isNull);
      expect(_painterOf(tester).effectiveT, kStaticWalkT);

      await tester.pumpWidget(const SizedBox());
      expect(DotIllustration.activeTickers, 0);
    });

    testWidgets('animate 由 true 改 false → 释放 ticker（不泄漏）', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const DotIllustration(seed: 'empty.history'));
      expect(DotIllustration.activeTickers, 1);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: DotIllustration(seed: 'empty.history', animate: false),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(DotIllustration.activeTickers, 0);
      expect(_painterOf(tester).progress, isNull);
    });

    testWidgets('开动效：1 个 ticker，跑几帧仍是同一个；卸载后归零', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const DotIllustration(seed: 'empty.history'));

      expect(DotIllustration.activeTickers, 1);
      final painter = _painterOf(tester);
      expect(painter.progress, isNotNull);
      expect(painter.progress!.value, inInclusiveRange(0.0, 1.0));

      // ★ 注意：动效开着时**不能** pumpAndSettle（无限循环 → 永远等不到静止）
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(DotIllustration.activeTickers, 1);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      expect(DotIllustration.activeTickers, 0);
    });
  });

  group('确定性：同 seed 同路径', () {
    testWidgets('同 seed 两次渲染 → 逐像素完全一致', (tester) async {
      await _pump(tester, const DotIllustration(seed: 'empty.history', size: 120));
      final first = await _pixels(tester);

      // 整树卸载再重建（全新的 State / Painter），模拟"重新打开空态页"
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, const DotIllustration(seed: 'empty.history', size: 120));
      final second = await _pixels(tester);

      expect(_meanDiff(first, second), 0,
          reason: '同一个 seed 每次渲染都必须是同一张图（不闪烁）');
    });

    testWidgets('不同 seed → 渲染结果不同', (tester) async {
      await _pump(tester, const DotIllustration(seed: 'empty.history', size: 120));
      final a = await _pixels(tester);

      await _pump(tester, const DotIllustration(seed: 'empty.inbox', size: 120));
      final b = await _pixels(tester);

      expect(_meanDiff(a, b), greaterThan(1),
          reason: '"随机"是观感多样：不同页面必须长不一样');
    });

    test('same seed → 折线逐点一致；不同 seed → 折线不同', () {
      final a = _painterList(const ['empty.history']).single;
      final b = _painterList(const ['empty.history']).single;
      final c = _painterList(const ['empty.inbox']).single;

      final pa = a.debugPolylineAt(0, kStaticWalkT, 160);
      expect(pa, isNotEmpty);
      expect(a.debugPolylineAt(0, kStaticWalkT, 160), pa);
      for (final i in <int>[0, 1, 2]) {
        expect(a.debugPolylineAt(i, kStaticWalkT, 160),
            b.debugPolylineAt(i, kStaticWalkT, 160));
      }
      expect(c.debugPolylineAt(0, kStaticWalkT, 160), isNot(pa));
      // 越界的行号给空表，不抛
      expect(a.debugPolylineAt(9, kStaticWalkT, 160), isEmpty);
    });
  });

  group('循环无突变（t 回绕不跳）', () {
    test('t 与 t+1 的折线逐点重合（相位是整数圈 ⇒ 天然接回）', () {
      var worstDelta = 0.0;
      var seen = 0;
      for (final painter in _painterList(_seeds)) {
        for (final t in <double>[0.0, 0.35, 0.72, 0.999]) {
          for (var i = 0; i < 3; i++) {
            final a = painter.debugPolylineAt(i, t, 160);
            final b = painter.debugPolylineAt(i, t + 1, 160);
            expect(a.length, b.length);
            seen += a.length;
            for (var j = 0; j < a.length; j++) {
              worstDelta = math.max(
                worstDelta,
                math.max((b[j].dx - a[j].dx).abs(), (b[j].dy - a[j].dy).abs()),
              );
            }
          }
        }
      }
      expect(seen, greaterThan(0));
      // 逐点重合到 1e-6 px 以内：回绕处不可能看到"唰"地跳一下
      expect(worstDelta, lessThan(1e-6));
    });

    test('t 走一小步 → 位移极小（连续，不是一帧一跳）', () {
      var worst = 0.0;
      for (final painter in _painterList(_seeds)) {
        final a = painter.debugPolylineAt(0, 0.35, 160);
        final b = painter.debugPolylineAt(0, 0.3505, 160);
        for (var j = 0; j < a.length; j++) {
          worst = math.max(worst, (b[j] - a[j]).distance);
        }
      }
      expect(worst, lessThan(1.0), reason: '相邻时刻的线条应当平滑接续');
    });
  });

  group('平滑与构图', () {
    test('相邻采样点转角 < 50°（实测 p99 ≈ 23°）——不是抖动的锯齿', () {
      var worst = 0.0;
      for (final painter in _painterList(_seeds)) {
        for (final side in <double>[72, 120, 160]) {
          for (final t in <double>[0.0, 0.35, 0.7]) {
            for (var i = 0; i < 3; i++) {
              final pts = painter.debugPolylineAt(i, t, side);
              for (var j = 2; j < pts.length; j++) {
                final d0 = pts[j - 1] - pts[j - 2];
                final d1 = pts[j] - pts[j - 1];
                var turn = (math.atan2(d1.dy, d1.dx) -
                        math.atan2(d0.dy, d0.dx))
                    .abs() %
                    (2 * math.pi);
                if (turn > math.pi) turn = 2 * math.pi - turn;
                worst = math.max(worst, turn * 180 / math.pi);
              }
            }
          }
        }
      }
      expect(worst, lessThan(50.0));
    });

    test('线条始终在内容方框内，且几条线互不侵占彼此那条"带"', () {
      // 不出留白框（留白 16% = "内容只占中间 68%"的硬契约）
      var worstOut = 0.0;
      // 相邻两条线在整个周期里的纵向上/下界（必须不重叠）
      var minGap = double.infinity;
      for (final painter in _painterList(_seeds)) {
        for (final side in <double>[72, 160]) {
          final box = _contentBox(side);
          final lo = List<double>.filled(3, double.infinity);
          final hi = List<double>.filled(3, -double.infinity);
          for (var step = 0; step <= 24; step++) {
            final t = step / 24;
            for (var i = 0; i < 3; i++) {
              for (final p in painter.debugPolylineAt(i, t, side)) {
                worstOut = math.max(
                  worstOut,
                  math.max(
                    math.max(box.left - p.dx, p.dx - box.right),
                    math.max(box.top - p.dy, p.dy - box.bottom),
                  ),
                );
                lo[i] = math.min(lo[i], p.dy);
                hi[i] = math.max(hi[i], p.dy);
              }
            }
          }
          // 振幅上界 ±0.94 半带高 ⇒ 线条永不越出自己那条"带"，不可能打架
          minGap = math.min(minGap, math.min(lo[1] - hi[0], lo[2] - hi[1]));
        }
      }
      expect(worstOut, lessThanOrEqualTo(0.0));
      expect(minGap, greaterThan(0.5));
    });

    testWidgets('尺寸越小线条越少（72px 用 2 条，160px 用 3 条）', (tester) async {
      await _pump(tester, const DotIllustration(seed: 'x', size: 160));
      expect(_painterOf(tester).lineCount, 3);

      await _pump(tester, const DotIllustration(seed: 'x', size: 72));
      expect(_painterOf(tester).lineCount, 2);
    });
  });

  group('动画真的在动', () {
    testWidgets('两个时刻的帧不同（且不是渐变噪声，而是整体缓慢游走）',
        (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const DotIllustration(seed: 'empty.history', size: 120));
      final t0 = await _pixels(tester);

      await tester.pump(Duration(milliseconds: kWalkCycle.inMilliseconds ~/ 4));
      final t1 = await _pixels(tester);

      expect(_meanDiff(t0, t1), greaterThan(1),
          reason: '四分之一周期后画面必须明显不同 → 线条真的在游走');

      await tester.pumpWidget(const SizedBox());
      expect(DotIllustration.activeTickers, 0);
    });

    test('painter：静态路径取 kStaticWalkT，动画路径取进度值', () {
      final staticPainter = _painterList(const ['x']).single;
      expect(staticPainter.progress, isNull);
      expect(staticPainter.effectiveT, kStaticWalkT);

      final live = DotIllustrationPainter(
        seed: stableSeed('x'),
        ink: _ink,
        accent: _accent,
        lineCount: 3,
        progress: const AlwaysStoppedAnimation<double>(0.72),
      );
      expect(live.effectiveT, 0.72);
    });
  });

  group('颜色与健壮性', () {
    testWidgets('默认取 palette.inkText / palette.accent，显式传参优先',
        (tester) async {
      AppPalette? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                seen = context.palette;
                return const Center(
                  child: DotIllustration(seed: 'empty.history'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final painter = _painterOf(tester);
      expect(seen, isNotNull);
      expect(painter.ink, seen!.inkText);
      expect(painter.accent, seen!.accent);

      await _pump(
        tester,
        const DotIllustration(
          seed: 'empty.history',
          ink: Colors.black,
          accent: Colors.red,
        ),
      );
      final overridden = _painterOf(tester);
      expect(overridden.ink, Colors.black);
      expect(overridden.accent, Colors.red);
    });

    testWidgets('size <= 0 / NaN → 渲染空 box，不崩', (tester) async {
      for (final side in <double>[0, -20, double.nan]) {
        await _pump(tester, DotIllustration(seed: 'x', size: side));
        expect(find.byType(DotIllustration), findsOneWidget);
        expect(tester.takeException(), isNull);
        // 零尺寸占位：连画笔都没建
        expect(
          find.descendant(
            of: find.byType(DotIllustration),
            matching: find.byType(CustomPaint),
          ),
          findsNothing,
        );
      }
    });

    testWidgets('正常 size → 渲染尺寸正好是 size，且整体 ExcludeSemantics',
        (tester) async {
      await _pump(tester, const DotIllustration(seed: 'x', size: 120));

      expect(tester.getSize(find.byType(DotIllustration)), const Size(120, 120));
      // 纯装饰：读屏不该读到它
      expect(
        find.descendant(
          of: find.byType(DotIllustration),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
    });

    test('shouldRepaint：只有颜色 / 种子 / 线数 / 静态↔动画切换才重绘', () {
      final base = _painterList(const ['x']).single;
      expect(base.shouldRepaint(_painterList(const ['x']).single), isFalse);
      expect(
        base.shouldRepaint(
          DotIllustrationPainter(
            seed: stableSeed('y'),
            ink: _ink,
            accent: _accent,
            lineCount: 3,
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          DotIllustrationPainter(
            seed: stableSeed('x'),
            ink: Colors.black,
            accent: _accent,
            lineCount: 3,
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          DotIllustrationPainter(
            seed: stableSeed('x'),
            ink: _ink,
            accent: _accent,
            lineCount: 2,
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          DotIllustrationPainter(
            seed: stableSeed('x'),
            ink: _ink,
            accent: _accent,
            lineCount: 3,
            progress: const AlwaysStoppedAnimation<double>(0.5),
          ),
        ),
        isTrue,
      );
    });
  });
}
