// 单测：「印刷走纸」加载画面（SmokeSilhouette / SmokeSilhouettePainter）
//
// 覆盖点：
// - animate=false：不创建 AnimationController（activeTickers 恒 0），painter 无进度源
// - animate=true：pump 后恰 1 个 ticker；pumpWidget(SizedBox) 卸载后归零（不泄漏）
// - MotionControl.enabled=false（或系统"减少动画"）：走静态路径，零 ticker
// - size <= 0 / 超大尺寸：不崩、不抛异常
// - 双色取 palette.inkDeco + palette.accent（构造 painter 直接读字段，不用 golden）
// - 默认主题（克莱因蓝 · 陶土）下 inkDeco vs 纸底 ≥ 3:1（WCAG 图形对比度护栏）
// - ★ 结构上"不可能难看"的硬性质：
//   · 静态帧不空场：t = kStaticSmokeT 时前 3 条线已落墨
//   · 构图固定：任何 t 下每条线的 y 与左端都不动，只有右端（墨量）在推进
//   · 确定性：同一个 t 两次渲染逐像素一致
//   · 尺寸降级：56px 画 3 条、160px 画 5 条（逐像素数墨带）
//   · 点缀只有一个"笔尖"（1.2 × 6 的短竖条）：领在"正在画"的那条线笔尖上；
//     都画完时停在末条右端
//   · 节奏：任意时刻至多 2 条线同时在长（读得出"一条印完再印下一条"）
//   · 收尾：整片淡到 kPressHoldAlpha 就停（不淡到 0，不闪白），最后回到空白
//
// 测试统一在 setUp 里关掉全局装饰动画；需要真动画的用例单独打开并在结束前
// 卸载 widget 树（ticker 计数必须归零，否则说明泄漏）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/smoke_silhouette.dart';

const Color _ink = Color(0xFF002FA7);
const Color _accent = Color(0xFFC65F38);

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

/// 抓一帧的像素（RGBA）。用 [RepaintBoundary.toImage] 做**强比对**：
/// 任何几何 / 墨量的差异都会落成不同的字节。
Future<Uint8List> _imageBytes(WidgetTester tester, Finder boundaryFinder) async {
  expect(boundaryFinder, findsOneWidget);
  final boundary = tester.renderObject<RenderRepaintBoundary>(boundaryFinder);
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// SmokeSilhouette 自己那层 [RepaintBoundary] 的像素。
Future<Uint8List> _silhouettePixels(WidgetTester tester) => _imageBytes(
      tester,
      find.descendant(
        of: find.byType(SmokeSilhouette),
        matching: find.byType(RepaintBoundary),
      ),
    );

/// 直接拿 painter + 指定进度/尺寸画一帧，抓像素（要验"某个 t 长什么样"时用）。
Future<Uint8List> _painterPixels(
  WidgetTester tester, {
  required double t,
  required double side,
}) async {
  final key = UniqueKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: CustomPaint(
            size: Size.square(side),
            painter: SmokeSilhouettePainter(
              ink: _ink,
              smoke: _accent,
              progress: AlwaysStoppedAnimation<double>(t),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _imageBytes(tester, find.byKey(key));
}

/// 一帧里"有墨的横向条带"数：每条 1px 线各自一条带（带间距远大于 1px，
/// 不会粘连），所以这个数就是"画了几条线"。
int _inkedBands(Uint8List rgba, int side) {
  final rows = <bool>[];
  for (var y = 0; y < side; y++) {
    var has = false;
    for (var x = 0; x < side; x++) {
      if (rgba[(y * side + x) * 4 + 3] != 0) {
        has = true;
        break;
      }
    }
    rows.add(has);
  }
  var bands = 0;
  for (var y = 0; y < rows.length; y++) {
    if (rows[y] && (y == 0 || !rows[y - 1])) bands++;
  }
  return bands;
}

/// 按几何反推"正在画"的线里 index 最小的那条（测试自己算，不把实现抄一遍）：
/// 拿 t = 0.78（本轮 5 条全部印满）时的长度当满宽，比它短的就是还在画。
/// 没有则返回 -1。
int _leadIndex(SmokeSilhouettePainter painter, double t, double side) {
  for (var i = 0; i < 5; i++) {
    final full = painter.debugLineAt(i, 0.78, side);
    if (full == null) continue; // 该尺寸档没有这条线
    final now = painter.debugLineAt(i, t, side);
    if (now == null) continue; // 还没起笔
    if (now.x1 < full.x1 - 1e-9) return i;
  }
  return -1;
}

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
    final staticPainter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
    expect(staticPainter.progress, isNull);
    expect(staticPainter.effectiveT, kStaticSmokeT);

    final livePainter = SmokeSilhouettePainter(
      ink: _ink,
      smoke: _accent,
      progress: const AlwaysStoppedAnimation<double>(0.72),
    );
    expect(livePainter.effectiveT, 0.72);

    // 颜色变 → 需要重绘；否则动画期间纯靠 listenable 驱动（零额外重绘）
    expect(livePainter.shouldRepaint(staticPainter), isTrue);
    expect(
      staticPainter.shouldRepaint(SmokeSilhouettePainter(ink: _ink, smoke: _accent)),
      isFalse,
    );
  });

  group('印刷走纸的几何（结构上不可能难看）', () {
    test('静态帧不空场：t = 0.35 时前 3 条线已落墨，第 4 条还没起笔', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      const side = 160.0;
      for (var i = 0; i < 3; i++) {
        final line = painter.debugLineAt(i, kStaticSmokeT, side);
        expect(line, isNotNull, reason: '第 $i 条线应当已经落墨（画面不空场）');
        expect(line!.x1, greaterThan(line.x0));
      }
      expect(painter.debugLineAt(3, kStaticSmokeT, side), isNull);
      expect(painter.debugLineAt(4, kStaticSmokeT, side), isNull);
      // 越界行号给 null，不抛
      expect(painter.debugLineAt(9, kStaticSmokeT, side), isNull);
    });

    test('构图固定：只有右端（墨量）在推进，y 与左端任何 t 都不动', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      const side = 160.0;
      final first = painter.debugLineAt(0, 0.05, side)!;
      var prevX1 = first.x1;
      for (final t in <double>[0.10, 0.20, 0.30, 0.34, 0.50, 0.70, 0.85]) {
        final line = painter.debugLineAt(0, t, side)!;
        expect(line.y, first.y, reason: '纵坐标必须一动不动（无 layout shift）');
        expect(line.x0, first.x0, reason: '左端固定：线是从左端"长"出来的');
        expect(line.x1, greaterThanOrEqualTo(prevX1),
            reason: '墨量只增不减（线在生长）');
        prevX1 = line.x1;
      }
      // 第 1 条在 t = 0.34 就印满了，之后长度不再变化
      expect(
        painter.debugLineAt(0, 0.34, side)!.x1,
        painter.debugLineAt(0, 0.86, side)!.x1,
      );
      // 起笔瞬间画出的那一点点：右端确实在"生长"，而不是一步到位
      expect(
        painter.debugLineAt(0, 0.05, side)!.x1,
        lessThan(painter.debugLineAt(0, 0.20, side)!.x1),
      );
    });

    test('内容盒契约：所有线落在"中间 68%"里，相邻线之间留得下 4px', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      for (final side in <double>[56, 120, 160]) {
        final box = Rect.fromLTWH(
          side * 0.16,
          side * 0.16,
          side * 0.68,
          side * 0.68,
        );
        final ys = <double>[];
        for (final t in <double>[0.0, 0.3, 0.6, 0.8]) {
          for (var i = 0; i < SmokeSilhouettePainter.lineCountFor(side); i++) {
            final line = painter.debugLineAt(i, t, side);
            if (line == null) continue;
            expect(line.x0, greaterThanOrEqualTo(box.left - 1e-9));
            expect(line.x1, lessThanOrEqualTo(box.right + 1e-9));
            expect(line.y, greaterThanOrEqualTo(box.top - 1e-9));
            expect(line.y, lessThanOrEqualTo(box.bottom + 1e-9));
            if (!ys.contains(line.y)) ys.add(line.y);
          }
        }
        ys.sort();
        for (var i = 1; i < ys.length; i++) {
          expect(ys[i] - ys[i - 1], greaterThan(4.0),
              reason: '相邻两条线至少隔 4px，1px 线不会糊成一片');
        }
      }
    });

    test('点缀只有一个"笔尖"：领在"正在画"的那条线笔尖上，且是短竖条', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      const side = 160.0;
      // 笔尖是**短竖条**（刃 / 笔尖），不是一颗要人指出来的小方点：
      // 高 > 宽，且高至少 4px（2.2px 方块在 420dpi 上只有约 5.8 设备像素，
      // 实测"要人指出来才注意得到"）。
      final nib = SmokeSilhouettePainter.nibSizeFor(side);
      expect(nib.height, greaterThan(nib.width));
      expect(nib.height, greaterThanOrEqualTo(4.0));
      final smallNib = SmokeSilhouettePainter.nibSizeFor(56);
      expect(smallNib.height, greaterThan(smallNib.width),
          reason: '小尺寸档同样是竖条，只是按比例缩小');

      // t = 0.10：index 0 正在长、index 1 还没起笔 → 笔尖跟 index 最小的那条
      final lead = _leadIndex(painter, 0.10, side);
      expect(lead, 0);
      final head = painter.debugLineAt(lead, 0.10, side)!;
      final accent = painter.debugAccentAt(0.10, side)!;
      expect(accent.cx, head.x1);
      expect(accent.cy, head.y);
      expect(accent.alpha, 1.0); // 还没进入淡出段 → 满档

      // t = 0.55：前三条已印满，领墨的是第 4 条（index 3，0.45→0.63）
      expect(_leadIndex(painter, 0.55, side), 3);

      // 一条线都不在画（>= 0.78，5 条全收笔）时：停在末条右端，墨量收敛到 0.45
      expect(_leadIndex(painter, 0.90, side), -1);
      final last = painter.debugLineAt(4, 0.90, side)!;
      final idle = painter.debugAccentAt(0.90, side)!;
      expect(idle.cx, last.x1);
      expect(idle.cy, last.y);
      expect(idle.alpha, closeTo(painter.debugFadeAt(0.90) * 0.45, 1e-9));
    });

    test('逐条印：任意时刻至多 2 条线同时在长（不再是"条形图在填充"）', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      const side = 160.0;
      final full = <double>[
        for (var i = 0; i < 5; i++) painter.debugLineAt(i, 0.99, side)!.x1,
      ];
      var maxLive = 0;
      for (var step = 0; step <= 280; step++) {
        final t = step / 280;
        var live = 0;
        for (var i = 0; i < 5; i++) {
          final now = painter.debugLineAt(i, t, side);
          if (now == null) continue; // 还没起笔
          if (now.x1 < full[i] - 1e-9) live++;
        }
        if (live > maxLive) maxLive = live;
      }
      // 旧参数（span 0.34 / step 0.13）是 3 → 读起来像均衡器；现在至多 2。
      expect(maxLive, 2, reason: '同一时刻最多 2 条在长，且只在交接的 84ms 里重叠');
    });

    test('先印满再收走：5 条线在 t = 0.78 全部收笔，t = 0.80 之后整片才淡', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      const side = 160.0;
      for (var i = 0; i < 5; i++) {
        final done = painter.debugLineAt(i, 0.78, side)!;
        final settled = painter.debugLineAt(i, 0.99, side)!;
        expect(done.x1, settled.x1, reason: '第 $i 条在 0.78 已印满');
      }
      expect(painter.debugFadeAt(0.78), 1.0);
      expect(painter.debugFadeAt(0.80), 1.0, reason: '印满后先停一息，不立刻开淡');
      expect(painter.debugFadeAt(0.86), lessThan(1.0));
    });

    test('收尾：淡到 kPressHoldAlpha 就停（不淡到 0），最后回到空白', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      expect(painter.debugFadeAt(0.0), 1.0);
      // 满墨一直保持到 5 条全印满（0.78）之后一小段（0.80 才开淡）
      expect(painter.debugFadeAt(0.79), 1.0);
      expect(painter.debugFadeAt(0.92), closeTo(kPressHoldAlpha, 1e-9));
      expect(painter.debugFadeAt(0.92), greaterThan(0.0),
          reason: '收尾不淡到 0 —— 淡到 0 会闪一下白');
      expect(painter.debugFadeAt(1.0), 0.0);
    });

    testWidgets('确定性：同一个 t 两次渲染逐像素一致（无随机、无每帧换构图）',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: SmokeSilhouette(size: 120, animate: false)),
      );
      final first = await _silhouettePixels(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        const MaterialApp(home: SmokeSilhouette(size: 120, animate: false)),
      );
      final second = await _silhouettePixels(tester);

      expect(first, orderedEquals(second));
    });

    testWidgets('静态帧画了 3 条线（逐像素数墨带），画面不空场', (tester) async {
      final rgba =
          await _painterPixels(tester, t: kStaticSmokeT, side: 160);
      expect(_inkedBands(rgba, 160), 3);
    });

    test('尺寸降级：56px 画 3 条、40px 画 2 条、160px 画 5 条', () {
      expect(SmokeSilhouettePainter.lineCountFor(160), 5);
      expect(SmokeSilhouettePainter.lineCountFor(80), 5);
      expect(SmokeSilhouettePainter.lineCountFor(79), 3);
      expect(SmokeSilhouettePainter.lineCountFor(56), 3);
      expect(SmokeSilhouettePainter.lineCountFor(48), 3);
      expect(SmokeSilhouettePainter.lineCountFor(47), 2);
    });

    testWidgets('尺寸降级（逐像素）：t = 0.72 时 160px 有 5 条墨带、56px 有 3 条',
        (tester) async {
      // 0.72 落第 5 条（0.60→0.78）的印程里 → 5 条都已有墨
      final big = await _painterPixels(tester, t: 0.72, side: 160);
      expect(_inkedBands(big, 160), 5);

      final small = await _painterPixels(tester, t: 0.72, side: 56);
      expect(_inkedBands(small, 56), 3,
          reason: '56px 档只有 3 条线（页面里的内联加载就是这一档）');
    });

    test('尺寸降级：56px 档第 4 条线不存在（几何层也不画）', () {
      final painter = SmokeSilhouettePainter(ink: _ink, smoke: _accent);
      expect(painter.debugLineAt(0, 0.55, 56), isNotNull);
      expect(painter.debugLineAt(2, 0.55, 56), isNotNull);
      expect(painter.debugLineAt(3, 0.55, 56), isNull);
    });
  });
}
