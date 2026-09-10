// 配色派生 + 无障碍对比度护栏（P1.5）单测：
// - WCAG 工具（relativeLuminance / contrastRatio）的基准值
// - 10 套配方全部合规：onInk/inkFill、onAccent/accentFill ≥ 4.5:1，
//   纸上文字 inkText ≥ 4.5:1，容器底文字 inkDeep/accentDeep ≥ 4.5:1，
//   数据编码/图形墨 inkDeco vs 纸底 ≥ 3:1（S6 图形对比度护栏）
// - 浅墨（粉蓝 / 薄荷绿 / 橘 / 青 / 植物绿）被护栏压深成「纸上可读的墨」
// - adjustForContrast：已达标原样返回；不达标自动调明暗（合成中间灰用例）
// - 默认配方（克莱因蓝 · 陶土）：ink 原墨零漂移；点缀墨的「实心底」这对
//   按护栏微调（白字 3.95:1 不达标 → 黑字 + 提亮到 4.5:1）
// - copyWith / lerp / 主题挂载（context.palette + 触摸目标）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/theme_store.dart';
import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_theme.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/ink_recipes.dart';

/// 原墨直接写在纸上不达标（< 4.5:1）的 5 套浅墨配方。
const lightInkIds = [
  'powder_blue_signal_red',
  'botanical_green_oxblood',
  'mint_green_warm_charcoal',
  'cyan_brick_red',
  'tangerine_slate_blue',
];

/// 主色通道（0=R / 1=G / 2=B）：用来粗验「只压明度、不换色相家族」。
int _dominantChannel(Color c) {
  final v = [c.r, c.g, c.b];
  var idx = 0;
  for (var i = 1; i < 3; i++) {
    if (v[i] > v[idx]) idx = i;
  }
  return idx;
}

void main() {
  group('WCAG 工具（app_tokens）', () {
    test('relativeLuminance：黑 0 / 白 1 / 纸白 ≈ 0.954', () {
      expect(relativeLuminance(Colors.black), closeTo(0.0, 0.001));
      expect(relativeLuminance(Colors.white), closeTo(1.0, 0.001));
      expect(relativeLuminance(kPaper), closeTo(0.9541, 0.01));
    });

    test('contrastRatio：同色 1、黑白 ≈ 21、与顺序无关', () {
      expect(contrastRatio(kPaper, kPaper), closeTo(1.0, 0.001));
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21.0, 0.1));
      expect(
        contrastRatio(Colors.black, Colors.white),
        closeTo(contrastRatio(Colors.white, Colors.black), 0.0001),
      );
      // 近黑墨 vs 纸白：17:1 级（正文绰绰有余）
      expect(contrastRatio(kInkBlack, kPaper), greaterThan(15));
    });
  });

  group('adjustForContrast 护栏', () {
    test('已达标 → 原样返回（默认配方主墨/语义色不动）', () {
      expect(adjustForContrast(kInkKlein, kPaper), kInkKlein);
      expect(adjustForContrast(kError, kPaper), kError);
    });

    test('不达标 → 自动压深直到 ≥ 4.5:1（合成中间灰用例）', () {
      const midGray = Color(0xFF767676); // 与纸白仅 ≈4.2:1，正文不达标
      expect(contrastRatio(midGray, kPaper), lessThan(kMinContrastBody));
      final fixed = adjustForContrast(midGray, kPaper);
      expect(fixed, isNot(midGray));
      expect(
        contrastRatio(fixed, kPaper),
        greaterThanOrEqualTo(kMinContrastBody),
      );
      // 只压明度、保持中性灰（三通道仍相等），且只会更暗
      expect(fixed.r, closeTo(fixed.g, 0.001));
      expect(fixed.g, closeTo(fixed.b, 0.001));
      expect(relativeLuminance(fixed), lessThan(relativeLuminance(midGray)));
    });
  });

  group('10 套配方全部满足对比度门槛（无障碍护栏）', () {
    test('onInk / inkFill ≥ 4.5:1（实心填充底 + 其上的字）', () {
      for (final r in kInkRecipes) {
        final p = AppPalette.fromRecipe(r);
        expect(
          contrastRatio(p.onInk, p.inkFill),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '${r.id} onInk vs inkFill',
        );
      }
    });

    test('onAccent / accentFill ≥ 4.5:1（点缀墨实心底 + 其上的字）', () {
      for (final r in kInkRecipes) {
        final p = AppPalette.fromRecipe(r);
        expect(
          contrastRatio(p.onAccent, p.accentFill),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '${r.id} onAccent vs accentFill',
        );
      }
    });

    test('inkText 在纸底与浅底上都 ≥ 4.5:1（链接 / 按钮文案 / 图标）', () {
      for (final r in kInkRecipes) {
        final p = AppPalette.fromRecipe(r);
        expect(
          contrastRatio(p.inkText, kPaper),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '${r.id} inkText vs kPaper',
        );
        expect(
          contrastRatio(p.inkText, p.inkWash),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '${r.id} inkText vs inkWash',
        );
      }
    });

    test('inkDeep / accentDeep 在各自浅底上 ≥ 4.5:1（容器底文字）', () {
      for (final r in kInkRecipes) {
        final p = AppPalette.fromRecipe(r);
        expect(
          contrastRatio(p.inkDeep, p.inkWash),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '${r.id} inkDeep vs inkWash',
        );
        expect(
          contrastRatio(p.accentDeep, p.accentWash),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '${r.id} accentDeep vs accentWash',
        );
      }
    });

    // S6 护栏：热力图/图表这类**数据编码**图形元素用 inkDeco，要求与纸底
    // ≥ 3:1（WCAG 非文字元素），否则「颜色越深观看越久」的刻度读不出来。
    test('inkDeco vs kPaper ≥ 3:1（数据编码/图形的非文字对比度）', () {
      for (final r in kInkRecipes) {
        final p = AppPalette.fromRecipe(r);
        expect(
          contrastRatio(p.inkDeco, kPaper),
          greaterThanOrEqualTo(kMinContrastGraphic),
          reason: '${r.id} inkDeco vs kPaper',
        );
      }
    });

    test('inkDeco 只压深、不换色相：达标配方零漂移，浅墨才被压深', () {
      for (final r in kInkRecipes) {
        final p = AppPalette.fromRecipe(r);
        if (contrastRatio(r.ink, kPaper) >= kMinContrastGraphic) {
          // 原墨本就达标 → inkDeco = 原墨（克莱因蓝等 5 套观感零漂移）
          expect(p.inkDeco, r.ink, reason: '${r.id} 零漂移');
        } else {
          // 浅墨 → 压深，且比原墨更暗（仍与纸同色相家族）
          expect(p.inkDeco, isNot(r.ink), reason: '${r.id} 应被压深');
          expect(
            relativeLuminance(p.inkDeco),
            lessThan(relativeLuminance(r.ink)),
            reason: '${r.id} 压深方向',
          );
          expect(
            contrastRatio(p.inkDeco, kPaper),
            lessThan(kMinContrastBody),
            reason: '${r.id} 图形档只需 3:1，不应被压到正文级 4.5:1',
          );
        }
      }
    });
  });

  group('浅墨被压深（mono-color 的浅墨不能再当纸上文字）', () {
    test('浅墨原墨 vs 纸 < 4.5:1 → inkText 与 ink 不同且达标、色相家族不变', () {
      for (final id in lightInkIds) {
        final recipe = inkRecipeById(id)!;
        final p = AppPalette.fromRecipe(recipe);
        expect(
          contrastRatio(p.ink, kPaper),
          lessThan(kMinContrastBody),
          reason: '$id 原墨本来就该不达标（这正是要列出清单的原因）',
        );
        expect(p.inkText, isNot(p.ink), reason: '$id inkText 应被压深');
        expect(
          contrastRatio(p.inkText, kPaper),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '$id inkText 压深后达标',
        );
        expect(
          _dominantChannel(p.inkText),
          _dominantChannel(p.ink),
          reason: '$id 压深只动明度，主色通道不变（不换色相家族）',
        );
        expect(
          relativeLuminance(p.inkText),
          lessThan(relativeLuminance(p.ink)),
          reason: '$id 只往深压',
        );
      }
    });

    test('填充底：原墨已达标就原样保留，否则按需微调（始终 ≥ 4.5:1）', () {
      for (final id in lightInkIds) {
        final p = AppPalette.fromRecipe(inkRecipeById(id)!);
        expect(
          contrastRatio(p.onInk, p.inkFill),
          greaterThanOrEqualTo(kMinContrastBody),
          reason: '$id 填充底必须达标',
        );
        if (contrastRatio(p.ink, p.onInk) >= kMinContrastBody) {
          // 能不动就不动：保住 mono-color 原墨观感
          expect(p.inkFill, p.ink, reason: '$id 原墨做底已达标');
        } else {
          expect(p.inkFill, isNot(p.ink), reason: '$id 原墨做底不达标需微调');
          expect(
            _dominantChannel(p.inkFill),
            _dominantChannel(p.ink),
            reason: '$id 微调只动明度',
          );
        }
      }
    });
  });

  group('默认配方（克莱因蓝 · 陶土）', () {
    test('主墨四档同为原墨 #002FA7（P1 观感零漂移）', () {
      final p = AppPalette.fallback;
      expect(p.ink, const Color(0xFF002FA7));
      expect(p.inkText, p.ink);
      expect(p.inkFill, p.ink);
      expect(p.inkDeco, p.ink); // 原墨 vs 纸 ≈10:1 ≥ 3:1 → 图形档也不动
      expect(p.onInk, kPaper); // 深墨配纸白字（≈10:1）
    });

    test('点缀墨原色照抄配方表；只有「实心底」这对按护栏微调', () {
      final p = AppPalette.fallback;
      expect(p.accent, const Color(0xFFC65F38));
      // 陶土上白字仅 ≈3.95:1、黑字 ≈4.44:1 → 选黑字，再把底提亮到刚好 4.5
      expect(p.onAccent, kInkBlack);
      expect(p.accentFill, isNot(p.accent));
      expect(
        contrastRatio(p.onAccent, p.accentFill),
        greaterThanOrEqualTo(kMinContrastBody),
      );
      // 提亮只动明度（色相基本不变：陶土 → 淡一点的陶土）
      expect(
        HSVColor.fromColor(p.accentFill).hue,
        closeTo(HSVColor.fromColor(p.accent).hue, 8),
      );
    });

    test('派生值 = P1 记录值（deep / wash）', () {
      final p = AppPalette.fallback;
      expect(p.inkDeep.toARGB32(), 0xFF07287D);
      expect(p.inkWash.toARGB32(), 0xFFDCE2ED);
      expect(p.accentDeep.toARGB32(), 0xFF914A30);
      expect(p.accentWash.toARGB32(), 0xFFF2E3DA);
    });

    test('fallback = fromRecipe(默认配方)', () {
      final p = AppPalette.fallback;
      final again = AppPalette.fromRecipe(kDefaultInkRecipe);
      expect(p.ink, again.ink);
      expect(p.inkText, again.inkText);
      expect(p.inkDeep, again.inkDeep);
      expect(p.accentWash, again.accentWash);
      expect(p.onAccent, again.onAccent);
    });
  });

  group('AppPalette 基础行为（copyWith / lerp / 主题挂载）', () {
    test('copyWith 只改指定字段', () {
      final p = AppPalette.fallback;
      final q = p.copyWith(ink: Colors.pink);
      expect(q.ink, Colors.pink);
      expect(q.inkDeco, p.inkDeco);
      expect(q.inkText, p.inkText);
      expect(q.onInk, p.onInk);
    });

    test('lerp：t=0 还原本色，t=0.5 在两端之间（AnimatedTheme 换色平滑）', () {
      final a = AppPalette.fallback;
      final b = AppPalette.fromRecipe(inkRecipeById('cobalt_terracotta')!);
      final at0 = a.lerp(b, 0);
      expect(at0.ink, a.ink);
      expect(at0.inkWash, a.inkWash);
      final mid = a.lerp(b, 0.5);
      expect(mid.ink, Color.lerp(a.ink, b.ink, 0.5));
      expect(mid.inkDeco, Color.lerp(a.inkDeco, b.inkDeco, 0.5));
      expect(mid.onAccent, Color.lerp(a.onAccent, b.onAccent, 0.5));
    });

    test('lerp 传入 null → 原样返回（不崩）', () {
      expect(AppPalette.fallback.lerp(null, 0.5).ink, kInkKlein);
    });
  });

  group('主题装配（extensions / 触摸目标 / 密度）', () {
    test('buildAppTheme 把 palette 挂到 extensions，并钉住无障碍尺寸', () {
      final theme = buildAppTheme();
      expect(theme.extension<AppPalette>()?.ink, kInkKlein);
      expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(theme.visualDensity, VisualDensity.standard);
      // 实心按钮底用合规填充色；文字按钮坐在纸上用可读墨
      expect(
        theme.filledButtonTheme.style?.backgroundColor?.resolve(<WidgetState>{}),
        AppPalette.fallback.inkFill,
      );
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve(<WidgetState>{}),
        AppPalette.fallback.inkText,
      );
    });

    test('换配方：主题里的实心底/可读墨跟着换', () {
      final recipe = inkRecipeById('mint_green_warm_charcoal')!;
      final theme = buildAppTheme(recipe);
      final p = AppPalette.fromRecipe(recipe);
      expect(theme.extension<AppPalette>()?.ink, const Color(0xFF5EB783));
      expect(theme.colorScheme.primary, p.inkText);
      expect(
        theme.filledButtonTheme.style?.backgroundColor?.resolve(<WidgetState>{}),
        p.inkFill,
      );
    });

    test('AppBar 有底部 1px kRule 描边（与页面同底材时的分隔，S1）', () {
      final theme = buildAppTheme();
      final shape = theme.appBarTheme.shape;
      expect(shape, isA<Border>());
      final border = shape! as Border;
      // 只有底边有描边：这是「层级靠细线、不靠阴影」的落地
      expect(border.top, BorderSide.none);
      expect(border.bottom.color, kRule);
      expect(border.bottom.width, 1);
      // 不依赖 M3 的滚动 tint（elevation 钉 0 + surfaceTint 透明）
      expect(theme.appBarTheme.elevation, 0);
      expect(theme.appBarTheme.scrolledUnderElevation, 0);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    });

    testWidgets('无本 App 主题时 context.palette 兜底默认配方（widget 单测安全）',
        (tester) async {
      late AppPalette seen;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          seen = context.palette;
          return const SizedBox();
        }),
      ));
      expect(seen.ink, const Color(0xFF002FA7));
      expect(seen.inkFill, AppPalette.fallback.inkFill);
    });

    testWidgets('带本 App 主题时 context.palette = 当前配方', (tester) async {
      late AppPalette seen;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(inkRecipeById('tangerine_slate_blue')!),
        home: Builder(builder: (context) {
          seen = context.palette;
          return const SizedBox();
        }),
      ));
      expect(seen.ink, const Color(0xFFE46C2D));
      expect(seen.accent, const Color(0xFF4773A5));
    });

    testWidgets('换配色时 MaterialApp 重建但路由栈保留（弹层不会被打回）',
        (tester) async {
      // 与 main.dart 同构：ListenableBuilder 包 MaterialApp
      SharedPreferences.setMockInitialValues({});
      ThemeStore.instance.resetForTest();
      addTearDown(ThemeStore.instance.resetForTest);

      await tester.pumpWidget(ListenableBuilder(
        listenable: ThemeStore.instance,
        builder: (context, _) => MaterialApp(
          theme: buildAppTheme(ThemeStore.instance.recipe),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const Text('弹层内容'),
                  ),
                  child: const Text('打开弹层'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开弹层'));
      await tester.pumpAndSettle();
      expect(find.text('弹层内容'), findsOneWidget);

      // 弹层开着时换配色：主题换掉，但弹层（路由栈）保留
      await ThemeStore.instance.select('mint_green_warm_charcoal');
      await tester.pumpAndSettle();

      expect(find.text('弹层内容'), findsOneWidget);
      final ctx = tester.element(find.text('弹层内容'));
      expect(
        Theme.of(ctx).extension<AppPalette>()?.ink,
        const Color(0xFF5EB783),
      );
    });
  });
}
