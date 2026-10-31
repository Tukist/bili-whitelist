// 夜间模式（v2.57.0）测试。
//
// 覆盖四层：
// 1) **纯函数**：`highestContrastOn` 按亮度选「纸白 / 近黑」；
//    `adjustForContrast` 在暗色下是**提亮**（浅色下仍是压深）；
// 2) **取值**：夜纸三层不是纯黑且亮度递增、文字层级 100/80/60/40% 的门槛、
//    描边在暗色下更强；
// 3) **主题**：浅色主题逐值等于 v2.55.0（默认路径不许漂移）、暗色主题的关键
//    表面（Scaffold/AppBar/Card/文字）确实是暗的；
// 4) **设置与 App 级**：三态默认 light / 持久化 / 读回；App 里切深色立即生效、
//    切回浅色恢复、跟随系统按 platformBrightness 生效；
//    以及「换亮度后整棵树标脏」这个机制本身（见 `theme/theme_rebuild.dart`）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/main.dart';
import 'package:bili_whitelist_app/services/theme_store.dart';
import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_theme.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/ink_recipes.dart';
import 'package:bili_whitelist_app/theme/theme_rebuild.dart';

/// 不依赖 `Theme`、也没有 `BuildContext` 逻辑的探针：
/// 它的 `build` 只读模块级 token —— 正是"换亮度不会自动重建"的那类 widget。
class _PaperProbe extends StatelessWidget {
  const _PaperProbe();

  @override
  Widget build(BuildContext context) =>
      ColoredBox(key: const Key('paper-probe'), color: kPaper);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 全局态兜底：任何一个用例把运行期那套切成暗色，都不许串到下一个用例。
    ThemeStore.instance.resetForTest();
    resetSurfacesForTest();
  });

  tearDown(() {
    ThemeStore.instance.resetForTest();
    resetSurfacesForTest();
  });

  group('highestContrastOn：候选随亮度切换', () {
    test('浅色纸面上选近黑', () {
      final on = withSurfaces(AppSurfaces.light, () => highestContrastOn(kPaper));
      expect(on, AppSurfaces.light.inkBlack);
      expect(relativeLuminance(on), lessThan(0.1));
    });

    test('夜纸上选纸白（不是把字压成近黑）', () {
      final on = withSurfaces(AppSurfaces.dark, () => highestContrastOn(kPaper));
      expect(on, AppSurfaces.dark.inkBlack);
      expect(relativeLuminance(on), greaterThan(0.5),
          reason: '暗底上必须选亮的那端');
      expect(contrastRatio(on, AppSurfaces.dark.paper), greaterThan(7));
    });

    test('暗色下对深墨实心填充底同样选亮端', () {
      final on =
          withSurfaces(AppSurfaces.dark, () => highestContrastOn(kInkKlein));
      expect(relativeLuminance(on), greaterThan(relativeLuminance(kInkKlein)));
    });

    test('显式传 candidates 时仍按传入的候选挑（旧接口不变）', () {
      const candidates = [Color(0xFF000000), Color(0xFFFFFFFF)];
      expect(
        highestContrastOn(const Color(0xFF101010), candidates: candidates),
        const Color(0xFFFFFFFF),
      );
    });
  });

  group('adjustForContrast：暗色提亮 / 浅色压深', () {
    // 克莱因蓝：夜纸上只有约 1.4:1，必须被提亮才读得出来。
    const deepInk = kInkKlein;

    test('暗色下未达标的墨被提亮到 4.5:1（不是朝夜纸方向压暗）', () {
      final out = withSurfaces(
        AppSurfaces.dark,
        () => adjustForContrast(deepInk, kPaper),
      );
      expect(relativeLuminance(out), greaterThan(relativeLuminance(deepInk)),
          reason: '暗色下方向只能是「变亮」');
      expect(contrastRatio(out, AppSurfaces.dark.paper),
          greaterThanOrEqualTo(kMinContrastBody));
      // 色相保留：蓝仍是最大通道（没有被去色成灰/白）
      expect(out.b, greaterThanOrEqualTo(out.r));
      expect(out.b, greaterThanOrEqualTo(out.g));
      // 也没有被一口气推到纯纸白（旧逻辑那种"压成纸白"的病）
      expect(relativeLuminance(out), lessThan(0.8));
    });

    test('浅色下同一条路径仍是压深（默认观感不变）', () {
      final lightInk = inkRecipeById('powder_blue_signal_red')!.ink; // 浅粉蓝
      final out = withSurfaces(
        AppSurfaces.light,
        () => adjustForContrast(lightInk, kPaper),
      );
      expect(relativeLuminance(out), lessThan(relativeLuminance(lightInk)));
      expect(contrastRatio(out, AppSurfaces.light.paper),
          greaterThanOrEqualTo(kMinContrastBody));
    });

    test('已达标时原样返回（零漂移）', () {
      final out = withSurfaces(AppSurfaces.light, () => adjustForContrast(
            kInkKlein,
            kPaper,
            target: kMinContrastGraphic,
          ));
      expect(out, kInkKlein);
    });
  });

  group('夜纸取值：三层提亮 + 文字层级 + 描边加强', () {
    test('夜纸不是纯黑，三层亮度递增（高度靠提亮表达）', () {
      final dark = AppSurfaces.dark;
      expect(dark.paper, isNot(const Color(0xFF000000)));
      expect(relativeLuminance(dark.paper), greaterThan(0.001));
      expect(relativeLuminance(dark.paperCool),
          greaterThan(relativeLuminance(dark.paper)));
      expect(relativeLuminance(dark.paperRaised),
          greaterThan(relativeLuminance(dark.paperCool)));
      // 「抬高」层也必须是暗的（不是一按就跳成浅色卡片）
      expect(relativeLuminance(dark.paperRaised), lessThan(0.05));
    });

    test('文字层级 100/80/60/40%：前三级过 AA，禁用档只求"能看出是禁用的"', () {
      final dark = AppSurfaces.dark;
      final bg = dark.paper;
      expect(contrastRatio(dark.inkBlack, bg), greaterThanOrEqualTo(7));
      expect(contrastRatio(dark.inkGray70, bg), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(dark.inkGray50, bg), greaterThanOrEqualTo(4.5));
      expect(contrastRatio(dark.inkGray30, bg), lessThan(4.5),
          reason: '禁用档本来就是弱对比（WCAG 对禁用态不设门槛）');
      // 层级必须真的递减，否则"三级文字"在暗色里分不出来
      expect(relativeLuminance(dark.inkBlack),
          greaterThan(relativeLuminance(dark.inkGray70)));
      expect(relativeLuminance(dark.inkGray70),
          greaterThan(relativeLuminance(dark.inkGray50)));
      expect(relativeLuminance(dark.inkGray50),
          greaterThan(relativeLuminance(dark.inkGray30)));
    });

    test('语义色在夜纸上仍过 4.5:1', () {
      final dark = AppSurfaces.dark;
      expect(contrastRatio(dark.error, dark.paper),
          greaterThanOrEqualTo(kMinContrastBody));
      expect(contrastRatio(dark.success, dark.paper),
          greaterThanOrEqualTo(kMinContrastBody));
    });

    test('描边在暗色下更强（否则"框"会消失）', () {
      final lightHair = contrastRatio(
          AppSurfaces.light.rule, AppSurfaces.light.paper);
      final darkHair = contrastRatio(AppSurfaces.dark.rule, AppSurfaces.dark.paper);
      expect(darkHair, greaterThan(lightHair));
      final lightStrong = contrastRatio(
          AppSurfaces.light.ruleStrong, AppSurfaces.light.paper);
      final darkStrong =
          contrastRatio(AppSurfaces.dark.ruleStrong, AppSurfaces.dark.paper);
      expect(darkStrong, greaterThan(lightStrong));
    });

    test('浅色那套逐值等于 v2.55.0（默认路径不许漂移）', () {
      expect(AppSurfaces.light.paper, const Color(0xFFFAFAF7));
      expect(AppSurfaces.light.paperCool, const Color(0xFFE9E9E5));
      expect(AppSurfaces.light.paperWarm, const Color(0xFFF5F1E8));
      expect(AppSurfaces.light.paperRaised, const Color(0xFFFAFAF7));
      expect(AppSurfaces.light.inkBlack, const Color(0xFF16181C));
      expect(AppSurfaces.light.inkGray70, const Color(0xFF5A5F66));
      expect(AppSurfaces.light.inkGray50, const Color(0xFF8A9099));
      expect(AppSurfaces.light.inkGray30, const Color(0xFFB9BEC5));
      expect(AppSurfaces.light.rule, const Color(0xFFDDDDD6));
      expect(AppSurfaces.light.ruleStrong, const Color(0xFFC9C9C1));
      expect(AppSurfaces.light.error, const Color(0xFFC83232));
      expect(AppSurfaces.light.success, const Color(0xFF1F7A55));
    });
  });

  group('buildAppTheme：两套主题', () {
    test('浅色主题：关键槽位仍是 v2.55.0 的值', () {
      final t = buildAppTheme();
      expect(t.brightness, Brightness.light);
      expect(t.colorScheme.brightness, Brightness.light);
      expect(t.scaffoldBackgroundColor, const Color(0xFFFAFAF7));
      expect(t.appBarTheme.backgroundColor, const Color(0xFFFAFAF7));
      expect(t.cardTheme.color, const Color(0xFFFAFAF7));
      expect(t.dividerTheme.color, const Color(0xFFDDDDD6));
      expect(t.colorScheme.surface, const Color(0xFFFAFAF7));
      expect(t.colorScheme.surfaceContainerHighest, const Color(0xFFE9E9E5));
      expect(t.textTheme.bodyMedium?.color, const Color(0xFF16181C));
      expect(t.textTheme.bodySmall?.color, const Color(0xFF5A5F66));
    });

    test('暗色主题：Scaffold / AppBar / Card / Divider / 文字都换成夜纸', () {
      final t = buildAppTheme(kDefaultInkRecipe, Brightness.dark);
      expect(t.brightness, Brightness.dark);
      expect(t.colorScheme.brightness, Brightness.dark);
      for (final c in <Color>[
        t.scaffoldBackgroundColor,
        t.appBarTheme.backgroundColor!,
        t.cardTheme.color!,
      ]) {
        expect(relativeLuminance(c), lessThan(0.05),
            reason: '关键表面必须是暗的：$c');
        expect(c, isNot(const Color(0xFF000000)), reason: '不用纯黑做底');
      }
      // 文字反过来必须是亮的
      expect(relativeLuminance(t.textTheme.bodyMedium!.color!), greaterThan(0.5));
      expect(relativeLuminance(t.textTheme.bodySmall!.color!), greaterThan(0.3));
      // 描边也换了（不是浅色那条 0xFFDDDDD6）
      expect(t.dividerTheme.color, isNot(const Color(0xFFDDDDD6)));
      expect(contrastRatio(t.dividerTheme.color!, t.scaffoldBackgroundColor),
          greaterThan(1.4));
    });

    test('装配暗色主题不会污染运行期那套（仍是浅色）', () {
      expect(appSurfaces.isDark, isFalse);
      buildAppTheme(kDefaultInkRecipe, Brightness.dark);
      expect(appSurfaces.isDark, isFalse);
      expect(kPaper, const Color(0xFFFAFAF7));
      expect(kRule, const Color(0xFFDDDDD6));
    });

    test('暗色主题的调色板按夜纸派生（墨被提亮到可读）', () {
      final dark = buildAppTheme(kDefaultInkRecipe, Brightness.dark);
      final p = dark.extension<AppPalette>()!;
      expect(contrastRatio(p.inkText, AppSurfaces.dark.paper),
          greaterThanOrEqualTo(kMinContrastBody));
      expect(contrastRatio(p.onInk, p.inkFill),
          greaterThanOrEqualTo(kMinContrastBody));
      expect(contrastRatio(p.onAccent, p.accentFill),
          greaterThanOrEqualTo(kMinContrastBody));
      // 稀释底在暗色下要更浓（12% 在夜纸上几乎看不见）
      expect(relativeLuminance(p.inkWash),
          lessThan(relativeLuminance(AppSurfaces.dark.paperRaised)));
    });
  });

  group('三态持久化（默认 light）', () {
    test('出厂默认 = 浅色', () {
      expect(ThemeStore.instance.themeMode, ThemeMode.light);
      expect(ThemeStore.instance.themeModeLabel, '浅色');
    });

    test('选深色 → 立即生效 + 落盘；重启 ensureLoaded 读回深色', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ThemeStore.instance.selectThemeMode(ThemeMode.dark);
      expect(ThemeStore.instance.themeMode, ThemeMode.dark);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ThemeStore.modeStorageKey), 'dark');

      // 模拟重启：内存回到默认，再从盘上读
      ThemeStore.instance.resetForTest();
      expect(ThemeStore.instance.themeMode, ThemeMode.light);
      await ThemeStore.instance.ensureLoaded();
      expect(ThemeStore.instance.themeMode, ThemeMode.dark);
    });

    test('跟随系统同样持久化', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ThemeStore.instance.selectThemeMode(ThemeMode.system);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ThemeStore.modeStorageKey), 'system');
      ThemeStore.instance.resetForTest();
      await ThemeStore.instance.ensureLoaded();
      expect(ThemeStore.instance.themeMode, ThemeMode.system);
    });

    test('盘上是脏值 / 没有值 → 回浅色（不崩）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ThemeStore.modeStorageKey: 'unknown-mode',
      });
      ThemeStore.instance.resetForTest();
      await ThemeStore.instance.ensureLoaded();
      expect(ThemeStore.instance.themeMode, ThemeMode.light);
    });

    test('三态文案都 ≤ 42 非空白字符且互不相同', () {
      final labels = ThemeMode.values
          .map(ThemeStore.themeModeLabelOf)
          .toList(growable: false);
      for (final l in labels) {
        final nonSpace = l.replaceAll(RegExp(r'\s'), '').length;
        expect(nonSpace, lessThanOrEqualTo(42), reason: l);
        expect(l.trim(), isNotEmpty);
      }
      expect(labels.toSet().length, labels.length);
    });

    test('id 编解码可逆，未知 id 返回 null', () {
      for (final m in ThemeMode.values) {
        expect(ThemeStore.themeModeById(ThemeStore.themeModeId(m)), m);
      }
      expect(ThemeStore.themeModeById('nope'), isNull);
      expect(ThemeStore.themeModeById(null), isNull);
    });
  });

  group('整树重建机制（换亮度时页面不会自动重建的兜底）', () {
    testWidgets('markEverythingDirty 之后，只读 token 的 const 页面换成新底材',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _PaperProbe()));
      Color probeColor() =>
          tester.widget<ColoredBox>(find.byKey(const Key('paper-probe'))).color;

      expect(probeColor(), AppSurfaces.light.paper);

      // 反证：只换全局那套、不标脏 → 这个页面**不会**更新
      //（它既不依赖 Theme，widget 实例也被框架原样复用）
      installSurfaces(Brightness.dark);
      await tester.pump();
      expect(probeColor(), AppSurfaces.light.paper,
          reason: '这正是必须显式标脏的原因（见 theme_rebuild.dart）');

      // 标脏 → 下一帧重建 → 读到夜纸
      markEverythingDirty();
      await tester.pump();
      expect(probeColor(), AppSurfaces.dark.paper);
    });
  });

  group('App 级：切深色立即生效 / 切回浅色恢复 / 跟随系统', () {
    /// 取当前页面里第一个 `Scaffold` 的**实际背景色**
    /// （页面显式给了就用页面的，没给就用主题的）。
    Color scaffoldBg(WidgetTester tester) {
      final finder = find.byType(Scaffold).first;
      final w = tester.widget<Scaffold>(finder);
      final ctx = tester.element(finder);
      return w.backgroundColor ?? Theme.of(ctx).scaffoldBackgroundColor;
    }

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(const BiliWhitelistApp());
      // 首帧后允许异步同步任务抛出/被捕获（同 widget_test.dart）
      await tester.pump();
      await tester.pump();
    }

    /// 取探针页里那块 ColoredBox 的当前颜色。
    Color probeColor(WidgetTester tester) =>
        tester.widget<ColoredBox>(find.byKey(const Key('paper-probe'))).color;

    testWidgets('停在**已打开的子页面**上换主题：那一页也会换成新底材',
        (tester) async {
      // 这条钉的是 `theme/theme_rebuild.dart` 的实际价值：路由页面自身的
      // widget 实例被框架缓存，不依赖 Theme 的页面不会因换主题重建 ——
      // 没有「整树标脏」的话，用户停在设置页切主题，返回时才看到变色的怪现象。
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await pumpApp(tester);

      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(MaterialPageRoute<void>(builder: (_) => const _PaperProbe()));
      // 别用 pumpAndSettle：首页有常驻动画/轮询，等不稳
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(probeColor(tester), AppSurfaces.light.paper);

      await ThemeStore.instance.selectThemeMode(ThemeMode.dark);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(probeColor(tester), AppSurfaces.dark.paper,
          reason: '停在子页面上换主题，这一页也必须跟着换（整树标脏兜底）');
    });

    testWidgets('默认浅色 → 切深色立即变暗 → 切回浅色恢复', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await pumpApp(tester);

      // 默认仍是浅色（老用户观感不变）
      expect(relativeLuminance(scaffoldBg(tester)), greaterThan(0.5));

      await ThemeStore.instance.selectThemeMode(ThemeMode.dark);
      // AnimatedTheme 会把两套 ThemeData 插值 200ms：等它走完再断言
      // （token 是立即换的，但 `Theme.of` 要等动画收尾）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(relativeLuminance(scaffoldBg(tester)), lessThan(0.1),
          reason: '切深色后页面底材必须真的变暗（不只是主题对象变了）');
      // 标题也变亮（不是深色字压在深色底上）
      final ctx = tester.element(find.byType(Scaffold).first);
      expect(
        relativeLuminance(Theme.of(ctx).textTheme.bodyMedium!.color!),
        greaterThan(0.5),
      );

      await ThemeStore.instance.selectThemeMode(ThemeMode.light);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(relativeLuminance(scaffoldBg(tester)), greaterThan(0.5));
    });

    testWidgets('跟随系统：按 platformBrightness 生效', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await pumpApp(tester);
      await ThemeStore.instance.selectThemeMode(ThemeMode.system);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 系统浅色 → 浅色
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(relativeLuminance(scaffoldBg(tester)), greaterThan(0.5));

      // 系统深色 → 深色（不需要重启 / 不需要用户再点一次）
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(relativeLuminance(scaffoldBg(tester)), lessThan(0.1));
    });
  });
}
