// AddSuccessButton / AddSuccessCheck 测试（lib/widgets/add_success_button.dart）：
// - 三态渲染与可点性：idle（「加入」+ 可点）/ loading（14px 内联转圈 + 不可点）/
//   added（勾 +「已加入」+ 不可点）—— **文案逐字**断言（既有测试的锚点，
//   见 lib/pages/search_page.dart 里调用点的注释）
// - 关动效（`flutter test` 默认 MotionControl.enabled=false）：从 idle 变 added
//   时树里没有波纹动效层，且**零 ticker**（transientCallbackCount == 0），
//   既有测试的 pumpAndSettle 不会被卡住
// - 开动效：同上翻转 → 波纹层出现（有 ticker）→ pumpAndSettle 后卸载并归零
// - 只在「非 added → added」这一步演：新挂载即 added（列表重建）不演
// - onPressed 只在 idle 下生效
// - 动效播放中被打断（回到 idle / 系统切「减少动画」）不留残余层
// - AddSuccessCheck 尺寸正确；AddSuccessSnackContent 装进真 SnackBar 排得下
//   （首页「已导入：…」提示条用的就是它，文案逐字不改）
// 注：loading 态里有无限循环的 CircularProgressIndicator，**不能** pumpAndSettle
// （会等到超时），只 pump。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/add_success_button.dart';

/// 宿主：用一个 [ValueNotifier] 驱动 state —— 翻转状态时走的是同一个 element
/// （`didUpdateWidget`），跟真实列表里的路径一致。
Future<void> _pump(
  WidgetTester tester,
  ValueNotifier<AddState> state, {
  VoidCallback? onPressed,
  String idleLabel = '加入',
  String addedLabel = '已加入',
  bool compact = false,
  bool useTonal = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<AddState>(
            valueListenable: state,
            builder: (_, s, __) => AddSuccessButton(
              state: s,
              idleLabel: idleLabel,
              addedLabel: addedLabel,
              onPressed: onPressed,
              compact: compact,
              useTonal: useTonal,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 波纹动效层是否在树上（关动效时应当恒为 false）
bool _motionLayer(WidgetTester tester) =>
    tester.any(find.byKey(kAddSuccessMotionKey));

/// 当前活着的 ticker 数（0 = 树里没有任何在跑的动画）
int _tickers(WidgetTester tester) => tester.binding.transientCallbackCount;

FilledButton _shell(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byType(FilledButton));

void main() {
  // flutter test 环境下 MotionControl.enabled 默认已是 false（见 motion_control.dart），
  // 这里显式钉住，避免受别的测试污染；用完 reset 回默认值。
  setUp(() => MotionControl.enabled = false);
  tearDown(MotionControl.reset);

  group('三态渲染', () {
    testWidgets('idle：文案逐字「加入」+ 可点；没有转圈、没有动效层', (tester) async {
      var taps = 0;
      await _pump(tester, ValueNotifier(AddState.idle), onPressed: () => taps++);
      await tester.pumpAndSettle();

      expect(find.text('加入'), findsOneWidget);
      expect(find.text('已加入'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_motionLayer(tester), isFalse);
      expect(_shell(tester).onPressed, isNotNull);
      expect(_tickers(tester), 0);
      // 触摸目标 ≥48dp（主题 materialTapTargetSize.padded → _InputPadding 撑开命中区）
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.text('加入'));
      expect(taps, 1);
      await tester.pumpAndSettle(); // 等水波纹收干净
      expect(_tickers(tester), 0);
    });

    testWidgets('loading：14px 内联转圈 + 不可点（文案让位）', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        ValueNotifier(AddState.loading),
        onPressed: () => taps++,
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // 内联转圈的尺寸与既有观感一致（14×14）
      expect(
        tester.getSize(find.byType(CircularProgressIndicator)),
        const Size(14, 14),
      );
      expect(find.text('加入'), findsNothing);
      expect(find.text('已加入'), findsNothing);
      expect(_motionLayer(tester), isFalse);
      expect(_shell(tester).onPressed, isNull);

      await tester.tap(find.byType(FilledButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('added：勾 + 文案逐字「已加入」+ 不可点（静态态，不带动效）',
        (tester) async {
      var taps = 0;
      await _pump(tester, ValueNotifier(AddState.added), onPressed: () => taps++);
      await tester.pumpAndSettle();

      expect(find.text('已加入'), findsOneWidget);
      expect(find.text('加入'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 新挂载即 added = 静态态（即使开了动效也不演，见下面那条用例）
      expect(_motionLayer(tester), isFalse);
      expect(_shell(tester).onPressed, isNull);

      await tester.tap(find.byType(FilledButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('自定义文案（番剧「导入 / 已导入」）+ compact / useTonal 冒烟',
        (tester) async {
      var taps = 0;
      final state = ValueNotifier(AddState.idle);
      await _pump(
        tester,
        state,
        idleLabel: '导入',
        addedLabel: '已导入',
        onPressed: () => taps++,
        compact: true,
        useTonal: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('导入'), findsOneWidget);
      // compact 只收视觉内边距，命中区仍 ≥48dp
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('导入'));
      expect(taps, 1);

      state.value = AddState.added;
      await tester.pumpAndSettle();
      expect(find.text('已导入'), findsOneWidget);
      expect(_motionLayer(tester), isFalse); // 关动效
    });
  });

  group('成功动效 · 关（flutter test 默认）', () {
    testWidgets('idle → added：不建动效层、零 ticker，pumpAndSettle 立即收敛',
        (tester) async {
      final state = ValueNotifier(AddState.idle);
      await _pump(tester, state);
      await tester.pumpAndSettle();
      expect(_tickers(tester), 0);

      state.value = AddState.added;
      await tester.pump();

      // 文案立刻到位（逐字锚点），但树里没有任何动效层
      expect(find.text('已加入'), findsOneWidget);
      expect(_motionLayer(tester), isFalse);
      expect(_tickers(tester), 0, reason: '关动效 = 连 AnimationController 都不建');

      await tester.pumpAndSettle(); // 若真建了 ticker，这里会等到超时
      expect(_motionLayer(tester), isFalse);
      expect(_tickers(tester), 0);
    });
  });

  group('成功动效 · 开', () {
    testWidgets('idle → added：动效层出现 → pumpAndSettle 后卸载并归零',
        (tester) async {
      MotionControl.enabled = true;
      final state = ValueNotifier(AddState.idle);
      await _pump(tester, state);
      await tester.pumpAndSettle();
      expect(_motionLayer(tester), isFalse);

      state.value = AddState.added;
      await tester.pump();

      expect(_motionLayer(tester), isTrue);
      expect(_tickers(tester), greaterThan(0), reason: '一次性动画在跑');
      // 动效期内文案也在（不靠"用勾顶替文案"来表达状态）
      expect(find.text('已加入'), findsOneWidget);
      expect(_shell(tester).onPressed, isNull);

      await tester.pumpAndSettle();
      expect(_motionLayer(tester), isFalse, reason: '播完卸载动效层');
      expect(_tickers(tester), 0);
      expect(find.text('已加入'), findsOneWidget);
    });

    testWidgets('新挂载就是 added（列表重建）→ 不演', (tester) async {
      MotionControl.enabled = true;
      await _pump(tester, ValueNotifier(AddState.added));
      await tester.pump();
      expect(find.text('已加入'), findsOneWidget);
      expect(_motionLayer(tester), isFalse);
      expect(_tickers(tester), 0);
    });

    testWidgets('动效播放中回到 idle（加入失败）→ 残余动效层被收掉', (tester) async {
      MotionControl.enabled = true;
      final state = ValueNotifier(AddState.idle);
      await _pump(tester, state);
      await tester.pump();

      state.value = AddState.added;
      await tester.pump();
      expect(_motionLayer(tester), isTrue);

      state.value = AddState.idle; // 失败回退
      await tester.pump();
      expect(_motionLayer(tester), isFalse);
      expect(find.text('加入'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(_tickers(tester), 0);
    });

    testWidgets('播放途中系统切成「减少动画」→ 立刻收尾', (tester) async {
      MotionControl.enabled = true;
      final state = ValueNotifier(AddState.idle);
      final reduce = ValueNotifier(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: reduce,
              builder: (context, r, __) => MediaQuery(
                // 只改 disableAnimations，其余沿用外层真值（size/padding…）
                data: MediaQuery.of(context).copyWith(disableAnimations: r),
                child: ValueListenableBuilder<AddState>(
                  valueListenable: state,
                  builder: (_, s, __) => AddSuccessButton(state: s),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      state.value = AddState.added;
      await tester.pump();
      expect(_motionLayer(tester), isTrue);

      reduce.value = true; // 系统开启「减少动画」
      await tester.pump();

      expect(_motionLayer(tester), isFalse);
      expect(find.text('已加入'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_tickers(tester), 0);
    });
  });

  group('AddSuccessCheck（静态勾，SnackBar 复用）', () {
    testWidgets('按给定尺寸画出勾，不带动效', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: AddSuccessCheck(color: kPaper, size: 24),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AddSuccessCheck), findsOneWidget);
      expect(tester.getSize(find.byType(AddSuccessCheck)), const Size(24, 24));
      expect(
        find.descendant(
          of: find.byType(AddSuccessCheck),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      expect(_tickers(tester), 0, reason: '静态勾不建 ticker');
    });

    testWidgets('装进真 SnackBar：文案逐字 + 勾画得出来（宽度有界、不炸布局）',
        (tester) async {
      // 首页「已导入：…」那条提示用的就是 [AddSuccessSnackContent]，
      // 这里把它塞进真 SnackBar，验证 Row + Expanded 在提示条里排得下去。
      const message = '已导入：测试视频';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: AddSuccessSnackContent(message: message)),
                ),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump(); // 弹出
      await tester.pump(const Duration(milliseconds: 300)); // 入场动画

      expect(tester.takeException(), isNull); // 无 unbounded 宽度之类布局异常
      expect(find.text(message), findsOneWidget); // 文案逐字
      expect(find.byType(AddSuccessCheck), findsOneWidget);
      expect(tester.getSize(find.byType(AddSuccessCheck)), const Size(24, 24));

      // 让它到点自己收起：测试结束时不留下悬挂的自动关闭计时器
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      expect(_tickers(tester), 0);
    });
  });
}
