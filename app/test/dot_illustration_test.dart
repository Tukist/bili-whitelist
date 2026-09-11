// 单测：「静默构图」空态插画（DotIllustration / DotIllustrationPainter）
//
// 2.21.0 的这次重做把空态从「2–3 条随机游走线 + 骑线点 + 半调网点 = 一个画面
// 5 个独立运动事件、14s 一轮」改成了**静默构图**：一条 1px 横线 + 一片与它
// 咬在一起（左缘对着线的渐隐起点）的半调网点；全画面只有那**片网点的墨量**
// 在 ±20% 内慢速呼吸（周期 4.4s）。所以本文件的断言从"折线几何"
// （debugPolylineAt / 转角 / 线带不重叠）换成了"构图固定 + 只有那片网在起伏"。
//
// 覆盖点：
// - MotionControl.enabled=false（flutter test 默认）：不创建 AnimationController
//   （activeTickers 恒 0）、painter 无进度源、pumpAndSettle 立即收敛
// - animate:false 显式关（全局开关开着也不建 ticker）；true → false 会释放 ticker
// - MotionControl.enabled=true：恰 1 个 ticker；卸载后归零（不泄漏）
// - 确定性（硬要求）：同 seed 两次渲染**逐像素一致**；不同 seed → 不同
// - 构图固定（硬要求）：横线的两端与 y **与 t 无关**（不再每帧重新构图）
// - 构图收紧（硬要求）：网点区左缘 = 线的渐隐起点、右缘贴内容盒、纵向居中于线
//   （"两块孤立的墨"在结构上不成立）；点缀点坐在线的**收笔点**上而不是左端
// - 呼吸：整片网点的墨量 ±20%（峰峰值 ≥ 均值的 35%，旧版 ±8% 单点实测看不出）
// - 循环无突变：t 与 t+1 的墨量逐点重合（`sin(2πt)` ⇒ 天然接回）
// - 构图：横线与网点都落在内容方框（中间 68%）内
// - 参数透传：默认取 palette.inkText / palette.accent，显式传参优先
// - 健壮性：size <= 0 / NaN → 空 box 不崩；正常 size 渲染尺寸 = size
// - 纯装饰：ExcludeSemantics 包裹（读屏不读它）
// - shouldRepaint：只有颜色 / 种子 / 静态↔动画切换才需要重绘
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

/// 抓一帧的像素（RGBA）。用 [RepaintBoundary.toImage] 做**强比对**：
/// 任何几何 / 墨量的差异都会落成不同的字节。
Future<Uint8List> _pixels(WidgetTester tester) async {
  final finder = find.descendant(
    of: find.byType(DotIllustration),
    matching: find.byType(RepaintBoundary),
  );
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

DotIllustrationPainter _painter(String seed) => DotIllustrationPainter(
      seed: stableSeed(seed),
      ink: _ink,
      accent: _accent,
    );

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

  group('确定性：同 seed 同一张图', () {
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

    test('same seed → 横线几何一致；不同 seed → 几何不同', () {
      const side = 160.0;
      for (final seed in _seeds) {
        final a = _painter(seed).debugLineAt(side);
        final b = _painter(seed).debugLineAt(side);
        expect(a, isNotNull);
        expect(a!.x0, b!.x0);
        expect(a.x1, b.x1);
        expect(a.y, b.y);
      }
      final x = _painter('empty.history').debugLineAt(side)!;
      final y = _painter('empty.inbox').debugLineAt(side)!;
      expect(x == y, isFalse, reason: '不同页面的空态不该一模一样');
    });
  });

  group('静默构图：位置完全不动', () {
    test('横线两端与 y 与相位 t 无关（不重新构图、无 layout shift）', () {
      const side = 160.0;
      for (final seed in _seeds) {
        final painter = _painter(seed);
        final base = painter.debugLineAt(side)!;
        // 网点区的外框同样只由 seed 决定（这个 accessor 根本没有 t 参数）
        final patch = painter.debugHalftoneBoxAt(side)!;
        expect(_painter(seed).debugHalftoneBoxAt(side), patch);
        for (final t in <double>[0.0, 0.2, kStaticWalkT, 0.5, 0.75, 0.99]) {
          // 几何由 seed 决定、与进度无关：debugLineAt 根本不接受 t
          expect(painter.debugLineAt(side), base);
          expect(painter.debugHalftoneBoxAt(side), patch);
          // 相位只改墨量（呼吸），不改任何位置
          expect(painter.debugHalftoneAlphaAt(t), greaterThan(0.0));
          // 点缀墨钉在**线的收笔点**上（不在左端：左端第一眼像 radio button）
          final dot = painter.debugDotAt(side)!;
          expect(dot.cx, base.x1, reason: '点不移动，且坐在线的收笔点上');
          expect(dot.cy, base.y, reason: '点不移动');
          expect(dot.r, 2.2);
          expect(dot.alpha, 1.0, reason: '点缀墨不参与呼吸（呼吸交给整片网点）');
        }
      }
    });

    test('两处墨咬在一起：网点区左缘 = 线的渐隐起点、右缘贴内容盒、纵向居中于线', () {
      for (final side in <double>[72, 120, 160]) {
        final box = _contentBox(side);
        for (final seed in _seeds) {
          final painter = _painter(seed);
          final line = painter.debugLineAt(side)!;
          final patch = painter.debugHalftoneBoxAt(side)!;
          // 左缘 = 线开始变淡的地方（线上 0.55 处）→ 网点是这条线"淡出"的延伸，
          // 而不是另用一角、与线毫不相干的一小块墨
          expect(
            patch.left,
            closeTo(line.x0 + (line.x1 - line.x0) * 0.55, 1e-9),
          );
          // 线真的伸进网点区里：两块墨交叠，"隔着一大片白"在结构上不成立
          expect(patch.left, lessThan(line.x1));
          expect(patch.right, closeTo(box.right, 1e-9));
          // 纵向以线为中心 → 这块网是"这段墨化开"的那一层
          expect(patch.center.dy, closeTo(line.y, 1e-9));
          // 整块都收在内容盒里（不越界）
          expect(patch.left, greaterThan(box.left));
          expect(patch.top, greaterThanOrEqualTo(box.top));
          expect(patch.bottom, lessThanOrEqualTo(box.bottom));
        }
      }
    });

    test('横线落在内容方框（中间 68%）内，两端都收在框里', () {
      for (final side in <double>[72, 120, 160]) {
        final box = _contentBox(side);
        for (final seed in _seeds) {
          final line = _painter(seed).debugLineAt(side)!;
          expect(line.x0, greaterThanOrEqualTo(box.left));
          expect(line.x1, lessThanOrEqualTo(box.right));
          expect(line.y, greaterThanOrEqualTo(box.top));
          expect(line.y, lessThanOrEqualTo(box.bottom));
          // 端点内缩：两端都不贴框（"端点收在框内"的手感）
          expect(line.x0, greaterThan(box.left));
          expect(line.x1, lessThan(box.right));
        }
      }
    });

    testWidgets('尺寸越小照样画（72px 卡片空态不退化）', (tester) async {
      await _pump(tester, const DotIllustration(seed: 'x', size: 72));
      expect(_painterOf(tester).debugLineAt(72), isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('呼吸：整片网点的墨量（看得见的那种）', () {
    test('幅度 ±20%：峰峰值 ≥ 均值的 35%（旧的 ±8% 单点实测看不出）', () {
      for (final seed in _seeds) {
        final painter = _painter(seed);
        var maxA = 0.0;
        var minA = double.infinity;
        for (var i = 0; i <= 64; i++) {
          final a = painter.debugHalftoneAlphaAt(i / 64);
          maxA = math.max(maxA, a);
          minA = math.min(minA, a);
        }
        // 采样含 t = 0.25（波峰）与 t = 0.75（波谷）→ 这里取到的就是真极值
        expect(maxA, greaterThan(minA), reason: '网点必须真的在呼吸');
        final mid = (maxA + minA) / 2;
        expect((maxA - minA) / mid, greaterThanOrEqualTo(0.35),
            reason: '看得见：峰峰值至少是均值的 35%（±8% 落在感知阈值以下）');
        expect(minA, greaterThan(0.0), reason: '不会"呼吸到没有墨"');
        expect(maxA, lessThan(0.4), reason: '仍然是一层浅网，不呼吸成实心块');
      }
    });

    test('循环无突变：t 与 t+1 的墨量逐点重合（sin(2πt) 天然接回）', () {
      var worst = 0.0;
      for (final seed in _seeds) {
        final painter = _painter(seed);
        for (final t in <double>[0.0, 0.13, kStaticWalkT, 0.5, 0.87, 0.999]) {
          final a = painter.debugHalftoneAlphaAt(t);
          final b = painter.debugHalftoneAlphaAt(t + 1);
          worst = math.max(worst, (b - a).abs());
        }
      }
      expect(worst, lessThan(1e-9), reason: '回绕处不可能看到"唰"地跳一下');
    });

    test('呼吸曲线连续：t 走一小步 → 墨量只动一点点', () {
      var worstA = 0.0;
      for (final seed in _seeds) {
        final painter = _painter(seed);
        for (final t in <double>[0.0, 0.35, 0.62]) {
          final a = painter.debugHalftoneAlphaAt(t);
          final b = painter.debugHalftoneAlphaAt(t + 0.0005);
          worstA = math.max(worstA, (b - a).abs());
        }
      }
      expect(worstA, lessThan(0.01));
    });
  });

  group('动画真的在动（只是很轻）', () {
    testWidgets('两个时刻的帧不同 → 确实在呼吸', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, const DotIllustration(seed: 'empty.history', size: 120));
      final t0 = await _pixels(tester);

      // 1/4 周期：网点墨量从均值走到波峰，整片网的浓淡差最大
      await tester.pump(Duration(milliseconds: kBreathCycle.inMilliseconds ~/ 4));
      final t1 = await _pixels(tester);

      expect(_meanDiff(t0, t1), greaterThan(0),
          reason: '四分之一周期后那一整片网点的墨量必须变了');
      expect(_meanDiff(t0, t1), lessThan(3),
          reason: '变化仍然很轻：整幅图的平均通道差不到 3/255');

      await tester.pumpWidget(const SizedBox());
      expect(DotIllustration.activeTickers, 0);
    });

    test('painter：静态路径取 kStaticWalkT，动画路径取进度值', () {
      final staticPainter = _painter('x');
      expect(staticPainter.progress, isNull);
      expect(staticPainter.effectiveT, kStaticWalkT);

      final live = DotIllustrationPainter(
        seed: stableSeed('x'),
        ink: _ink,
        accent: _accent,
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

    test('shouldRepaint：只有颜色 / 种子 / 静态↔动画切换才重绘', () {
      final base = _painter('x');
      expect(base.shouldRepaint(_painter('x')), isFalse);
      expect(
        base.shouldRepaint(
          DotIllustrationPainter(
            seed: stableSeed('y'),
            ink: _ink,
            accent: _accent,
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
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          DotIllustrationPainter(
            seed: stableSeed('x'),
            ink: _ink,
            accent: Colors.red,
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
            progress: const AlwaysStoppedAnimation<double>(0.5),
          ),
        ),
        isTrue,
      );
    });
  });
}
