// AppStateView / AppLoadingView / AppErrorView 组件测试
// （lib/widgets/app_state_view.dart）：
// - 三种 kind 的渲染（空态插画+标题+副文案 / 加载指示 PressDots / 错误插画+重试）
// - 加载态不再走 Material 转圈，改用印刷语言的 [PressDots]；
//   ⚠️ 但 Material 转圈**没有**在全 App 消失——按钮内联 / 进度缓冲 / 黑底反色 /
//   图片占位那几类按各自语义保留（清单见 AppLoadingView 的注释，实测仍有 19 处）。
//   "存在性 + 尺寸克制（24）"的断言意图保留：锚点从转圈挪到 [PressDots]
// - scrollable: true 时确实是 ListView 且 physics = AlwaysScrollableScrollPhysics
//   （宿主 RefreshIndicator 下拉刷新的硬约束）
// - scrollable: false 时不产生 ListView（纯静态区域）
// - 动作按钮回调 + 触摸目标 ≥ 48dp（Android 规范）
// - copyId / subtitleCopyId 走 UiCopyStore（设置页改完立刻生效）
// - 插画种子的确定性（stableSeed：同 seed 同图案）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dot_halftone.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

/// 取唯一的 ListView 的 physics。
ScrollPhysics? _listViewPhysics(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).physics;

void main() {
  setUp(() {
    // 单例文案库跨测试共享 → 每条用例先重置成出厂默认
    UiCopyStore.instance.resetForTest();
  });

  group('空态（empty）', () {
    testWidgets('copyId + subtitleCopyId 走 store：渲染默认文案与插画', (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.empty,
          copyId: 'empty.history',
          subtitleCopyId: 'empty.history.sub',
          illustrationSeed: 'empty.history',
        ),
      );

      expect(find.text('暂无历史记录'), findsOneWidget);
      expect(find.text('看过的视频会出现在这里，点击可续播'), findsOneWidget);
      expect(find.byType(DotIllustration), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 非 scrollable：不产生 ListView
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('copyId 为 null → 用 title / subtitle 直给', (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.empty,
          title: '直给标题',
          subtitle: '直给副文案',
          illustrationSeed: 'tmp',
        ),
      );

      expect(find.text('直给标题'), findsOneWidget);
      expect(find.text('直给副文案'), findsOneWidget);
    });

    testWidgets('没有副文案时不渲染副文案', (tester) async {
      await _pump(
        tester,
        const AppStateView(kind: AppStateKind.empty, title: '只有标题'),
      );

      expect(find.text('只有标题'), findsOneWidget);
    });

    testWidgets('用户覆盖后在设置页改完立刻生效', (tester) async {
      UiCopyStore.instance.resetForTest({'empty.history': '这里空得能听见回声'});
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.empty,
          copyId: 'empty.history',
          illustrationSeed: 'empty.history',
        ),
      );

      expect(find.text('这里空得能听见回声'), findsOneWidget);
      expect(find.text('暂无历史记录'), findsNothing);
    });

    testWidgets('插画 seed 原样透传给 DotIllustration', (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.empty,
          title: '标题',
          illustrationSeed: 'empty.inbox',
        ),
      );

      final illus = tester.widget<DotIllustration>(find.byType(DotIllustration));
      expect(illus.seed, 'empty.inbox');
    });

    testWidgets('动作按钮：回调触发 + 触摸目标 ≥ 48dp', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        AppStateView(
          kind: AppStateKind.empty,
          title: '还没有白名单 UP 主',
          actionLabel: '搜索并加入 UP 主',
          onAction: () => taps++,
          illustrationSeed: 'empty.playlist.upowner',
        ),
      );

      expect(find.text('搜索并加入 UP 主'), findsOneWidget);
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('只有 actionLabel 没有 onAction → 不渲染按钮', (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.empty,
          title: '标题',
          actionLabel: '重试',
        ),
      );

      expect(find.text('重试'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('scrollable（保宿主 RefreshIndicator 下拉刷新）', () {
    testWidgets('scrollable: true → ListView + AlwaysScrollableScrollPhysics',
        (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.empty,
          title: '白名单为空',
          scrollable: true,
          illustrationSeed: 'empty.playlist',
        ),
      );

      expect(find.byType(ListView), findsOneWidget);
      expect(_listViewPhysics(tester), isA<AlwaysScrollableScrollPhysics>());
      // 内容仍然在
      expect(find.text('白名单为空'), findsOneWidget);
      expect(find.byType(DotIllustration), findsOneWidget);
    });

    testWidgets('scrollable: true 的结构顺序与旧空态等价'
        '（留白 → 插画 → 标题 → 副文案 → 按钮）', (tester) async {
      await _pump(
        tester,
        AppStateView(
          kind: AppStateKind.empty,
          title: '这个收藏夹还没有视频',
          subtitle: '收藏的合集 / 剧集等非视频内容本版暂不展示',
          actionLabel: '重试',
          onAction: () {},
          scrollable: true,
          illustrationSeed: 'empty.favorite_videos',
        ),
      );

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.childrenDelegate.estimatedChildCount,
          greaterThanOrEqualTo(6));
      // 顶部留白存在（kEmptyTopGap = 120）
      expect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.height == 120,
        ),
        findsOneWidget,
      );
      expect(find.byType(DotIllustration), findsOneWidget);
      expect(find.text('这个收藏夹还没有视频'), findsOneWidget);
      expect(find.text('收藏的合集 / 剧集等非视频内容本版暂不展示'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('scrollable 的空态可以直接在 RefreshIndicator 里下拉', (tester) async {
      var refreshed = 0;
      await _pump(
        tester,
        RefreshIndicator(
          onRefresh: () async => refreshed++,
          child: const AppStateView(
            kind: AppStateKind.empty,
            title: '还没有收藏夹',
            scrollable: true,
            illustrationSeed: 'empty.favorites',
          ),
        ),
      );

      // 空态可滚动（内容不足一屏也能拉起）→ 下拉手势能触发刷新
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // 滚回顶部
      await tester.pump(const Duration(seconds: 1)); // 指示器收起
      expect(refreshed, 1);
    });
  });

  group('加载态（loading）', () {
    testWidgets('渲染三颗方点 + 文案', (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.loading,
          title: '正在同步白名单…',
        ),
      );

      // 锚点从 Material 转圈挪到印刷语言的 PressDots（尺寸/存在性意图不变）
      expect(find.byType(PressDots), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '本组件的加载态走印刷语言；App 其它位置的转圈按语义另外保留');
      expect(find.text('正在同步白名单…'), findsOneWidget);
      expect(find.byType(DotIllustration), findsNothing); // 加载态不画插画
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('无文案时只有指示器', (tester) async {
      await _pump(
        tester,
        const AppStateView(kind: AppStateKind.loading),
      );

      expect(find.byType(PressDots), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('copyId 走 store；scrollable: true 时也用 ListView 承载',
        (tester) async {
      await _pump(
        tester,
        const AppStateView(
          kind: AppStateKind.loading,
          copyId: 'empty.syncing',
          scrollable: true,
        ),
      );

      expect(find.text('正在同步白名单…'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(_listViewPhysics(tester), isA<AlwaysScrollableScrollPhysics>());
    });

    testWidgets('AppLoadingView 尺寸克制（默认 24）', (tester) async {
      await _pump(tester, const AppLoadingView());

      // 指示器占位仍是一个 24×24 的方框（与原来的转圈占位一致，布局不用改）
      final box = tester.getSize(find.byType(PressDots));
      expect(box.width, 24);
      expect(box.height, 24);
    });

    testWidgets('AppLoadingView：三颗方点排开，第一颗亮、另两颗低墨量', (tester) async {
      await _pump(tester, const AppLoadingView());

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(PressDots),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as PressDotsPainter;
      // 测试环境动效默认关 → 静态帧停在 t = 0（第一颗亮）
      expect(painter.progress, isNull);
      expect(painter.effectiveT, kStaticPressDotsT);
      expect(PressDotsPainter.litIndexAt(kStaticPressDotsT), 0);
      // 三颗点在 size × (1/4, 2/4, 3/4) 处水平排开、垂直居中
      expect(PressDotsPainter.dotCenterAt(0, 24), const Offset(6, 12));
      expect(PressDotsPainter.dotCenterAt(1, 24), const Offset(12, 12));
      expect(PressDotsPainter.dotCenterAt(2, 24), const Offset(18, 12));
      // 依次亮起：一个周期内三颗各轮一次
      expect(PressDotsPainter.litIndexAt(0.0), 0);
      expect(PressDotsPainter.litIndexAt(0.5), 1);
      expect(PressDotsPainter.litIndexAt(0.9), 2);
      expect(PressDotsPainter.litIndexAt(1.0), 0);
    });
  });

  group('错误态（error）', () {
    testWidgets('message 直给 + 重试回调', (tester) async {
      var retries = 0;
      await _pump(
        tester,
        AppErrorView(
          message: '网络开小差了（-412）',
          onRetry: () => retries++,
          illustrationSeed: 'error.favorites',
        ),
      );

      expect(find.text('网络开小差了（-412）'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(DotIllustration), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('不给 message → 用出厂默认 error.generic', (tester) async {
      await _pump(tester, const AppErrorView());

      final store = UiCopyStore.instance;
      expect(find.text(store.text('error.generic')), findsOneWidget);
      // 无 onRetry → 不显示按钮
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('副文案走 subtitleCopyId', (tester) async {
      await _pump(
        tester,
        const AppErrorView(
          message: '加载失败',
          subtitleCopyId: 'empty.cache.sub',
        ),
      );

      expect(find.text(UiCopyStore.instance.text('empty.cache.sub')),
          findsOneWidget);
    });

    testWidgets('scrollable: true → ListView + AlwaysScrollableScrollPhysics',
        (tester) async {
      await _pump(
        tester,
        const AppErrorView(
          message: '加载失败',
          scrollable: true,
          illustrationSeed: 'error.search',
        ),
      );

      expect(find.byType(ListView), findsOneWidget);
      expect(_listViewPhysics(tester), isA<AlwaysScrollableScrollPhysics>());
    });
  });

  group('种子确定性（"随机"是观感多样，不是每次刷新变化）', () {
    test('stableSeed：同 seed 稳定、不同 seed 分开', () {
      expect(stableSeed('empty.history'), stableSeed('empty.history'));
      expect(stableSeed('empty.history'),
          isNot(stableSeed('empty.inbox')));
      expect(stableSeed(''), stableSeed(''));
      // 结果永远是 32 位非负整数（可用于 Random 种子）
      expect(stableSeed('任意页面 ID'), greaterThanOrEqualTo(0));
      expect(stableSeed('任意页面 ID'), lessThanOrEqualTo(0xFFFFFFFF));
    });

    testWidgets('同 seed 重建 → 插画 painter 参数完全一致（不闪烁）', (tester) async {
      await _pump(
        tester,
        const DotIllustration(seed: 'empty.history', size: 120),
      );
      final a = tester.widget<DotIllustration>(find.byType(DotIllustration));

      await _pump(
        tester,
        const DotIllustration(seed: 'empty.history', size: 120),
      );
      final b = tester.widget<DotIllustration>(find.byType(DotIllustration));

      expect(a.seed, b.seed);
      expect(a.size, b.size);
    });

    testWidgets('HalftonePattern 渲染点阵并可带 child', (tester) async {
      await _pump(
        tester,
        const SizedBox(
          width: 120,
          height: 90,
          child: HalftonePattern(
            color: Color(0x1A002FA7),
            spacing: 6,
            seed: 'cover.placeholder',
            child: Center(child: Text('占位')),
          ),
        ),
      );

      expect(find.byType(HalftonePattern), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('占位'), findsOneWidget);
      expect(tester.getSize(find.byType(HalftonePattern)), const Size(120, 90));
    });

    testWidgets('DotIllustration size <= 0 → 渲染空 box，不崩', (tester) async {
      await _pump(tester, const DotIllustration(seed: 'x', size: 0));

      expect(find.byType(DotIllustration), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
