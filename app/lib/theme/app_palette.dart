import 'package:flutter/material.dart';

import 'app_tokens.dart';
import 'ink_recipes.dart';

/// 从候选前景里挑与 [background] 对比度最高的那个（平手时取靠前的）。
/// 默认候选 = 纸白 / 近黑（全库只有这两种「墨上的字」）。
Color highestContrastOn(
  Color background, {
  List<Color> candidates = const [kPaper, kInkBlack],
}) {
  var best = candidates.first;
  var bestRatio = contrastRatio(best, background);
  for (final c in candidates.skip(1)) {
    final r = contrastRatio(c, background);
    if (r > bestRatio) {
      best = c;
      bestRatio = r;
    }
  }
  return best;
}

/// 把 [color] 的明暗调到与 [other] 达到 [target] 对比度（**保持色相**：
/// 只朝近黑 / 纸白方向插值，不改 hue）。
///
/// - 已达标 → 原样返回（默认配方下多数墨都在此列，观感不变）
/// - 未达标 → 朝「对比度更高」的那一端逐档插值（每档 5%，最多 20 档）
///
/// 用于把 mono-color 里偏浅的墨（粉蓝 / 薄荷绿 / 橘 …）自动压成
/// 「纸上的可读文字色」或「合规的实心填充底」。
Color adjustForContrast(
  Color color,
  Color other, {
  double target = kMinContrastBody,
}) {
  if (contrastRatio(color, other) >= target) return color;
  // 往哪端走：取极端值下对比度更高的那端（纸白 or 近黑）
  final toward = contrastRatio(kPaper, other) >= contrastRatio(kInkBlack, other)
      ? kPaper
      : kInkBlack;
  for (var step = 1; step <= 20; step++) {
    final candidate = Color.lerp(color, toward, step * 0.05)!;
    if (contrastRatio(candidate, other) >= target) return candidate;
  }
  return toward; // 兜底：纯纸白 / 近黑（≈21:1，必达标）
}

/// 图形 / 非文字 UI 元素的最低对比度门槛（WCAG 2.1 AA 非文字对比度 3:1）。
///
/// 用于**数据编码**类用途（热力图色阶、图表色块、图形描边）：这类元素本身
/// 承载信息（深浅 = 量级），必须能被读出来，但不像正文那样要求 4.5:1。
/// 见 [AppPalette.inkDeco]。
const kMinContrastGraphic = 3.0;

/// 运行时配色（从 [InkRecipe] 派生），挂在 `ThemeData.extensions` 上。
///
/// 页面取「墨」色一律走 `context.palette`（见 [AppPaletteX]），不要写颜色
/// 字面量、也不要用 `colorScheme.*` 去取精确色：
/// - 真实 App 里 `MaterialApp.theme` 带本扩展 → 拿到当前配方；
/// - widget 单测常见 `pumpWidget(MaterialApp(home: XxxPage()))`（不带本 App
///   主题）→ 兜底 [AppPalette.fallback] = 默认克莱因蓝 · 陶土，与真机默认
///   观感一致，断言不会因测试环境取不到主题而漂移。
///
/// **同一个墨按用途分四档**（mono-color 的墨偏浅时会不达 WCAG 门槛，故拆开）：
/// - [ink]：配方原墨，用于**保真装饰**——大面积色块、品牌视觉、需要「所见即
///   配方原色」的地方（不做压深，换配方即时反映原设计色）；
/// - [inkDeco]：**数据编码/图形**专用档（热力图深度、图表色阶、今日格描边），
///   保证与 [kPaper] ≥ 3:1（WCAG 2.1 对图形/非文字元素的要求，见
///   [kMinContrastGraphic]）——深浅要能被肉眼读出，浅墨配方下会比 [ink]
///   明显更深；
/// - [inkFill]：**实心填充底**（主按钮等），保证 [onInk] 在其上 ≥ 4.5:1；
/// - [inkText]：**纸 / 浅底上的文字与图标**（链接、按钮文案、导航图标），
///   保证 ≥ 4.5:1（比 wash 更亮的纸底自动满足）。
/// 默认配方（克莱因蓝）四档同值 = 原墨，观感与 P1 完全一致。
///
/// 取舍（S6）：[ink] 与 [inkDeco] 是「色彩保真 vs 图表可读性」的取舍。
/// 一旦某个用途承载**信息**（如热力格深浅 = 观看时长），就选可读性优先，
/// 用 [inkDeco]；纯装饰（不需要读出量级）才用原墨 [ink]。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  /// 配方原墨（保真装饰：品牌视觉、大片色块；不做对比度压深）。
  final Color ink;

  /// 数据编码 / 图形专用墨：保证与 [kPaper] ≥ [kMinContrastGraphic]（3:1）。
  /// 已达标时 = [ink]（零漂移）；浅墨配方会被压深到刚达标。
  final Color inkDeco;

  /// 实心填充底（主按钮等）：保证 [onInk] 在其上 ≥ 4.5:1。
  final Color inkFill;

  /// 纸 / 浅底上的文字与图标色：保证 ≥ 4.5:1（对比 [kPaper] 与 [inkWash]）。
  final Color inkText;

  /// 主墨加深：容器底（[inkWash]）上的文字 / 按下态，
  /// 保证对比度 ≥ 4.5:1（FilledButton.tonal 的 label 走这条）。
  final Color inkDeep;

  /// 主墨 12% 稀释底：选中底 / 徽标底 / 热力浅档。
  final Color inkWash;

  /// [inkFill] 上的文字 / 图标色（按实测对比度选纸白或近黑）。
  final Color onInk;

  /// 点缀墨原色（时间与新鲜度）。
  final Color accent;

  /// 点缀墨实心填充底：保证 [onAccent] 在其上 ≥ 4.5:1。
  final Color accentFill;

  /// 点缀墨加深：点缀容器底（[accentWash]）上的文字，≥ 4.5:1。
  final Color accentDeep;

  /// 点缀墨 15% 稀释底：角标底。
  final Color accentWash;

  /// [accentFill] 上的文字 / 图标色（按实测对比度选纸白或近黑）。
  final Color onAccent;

  const AppPalette({
    required this.ink,
    required this.inkDeco,
    required this.inkFill,
    required this.inkText,
    required this.inkDeep,
    required this.inkWash,
    required this.onInk,
    required this.accent,
    required this.accentFill,
    required this.accentDeep,
    required this.accentWash,
    required this.onAccent,
  });

  /// 从配方派生。所有派生都走统一公式（不为默认配方写特例）：
  /// 「文字 / 实心底」用途过 [adjustForContrast] 的 4.5:1 护栏，
  /// 「数据编码 / 图形」用途（[inkDeco]）过 [kMinContrastGraphic] 的 3:1 护栏。
  factory AppPalette.fromRecipe(InkRecipe recipe) {
    final ink = recipe.ink;
    final accent = recipe.accent;
    final inkWash = Color.alphaBlend(ink.withValues(alpha: 0.12), kPaper);
    final accentWash = Color.alphaBlend(accent.withValues(alpha: 0.15), kPaper);
    final onInk = highestContrastOn(ink);
    final onAccent = highestContrastOn(accent);
    return AppPalette(
      ink: ink,
      // 数据编码/图形档：与纸底 ≥ 3:1。原墨已达标（克莱因蓝等 5 套）→ 零漂移；
      // 浅墨（粉蓝/薄荷绿/橘/青色/植物绿）→ 压深到刚达标，深浅才读得出来。
      inkDeco: adjustForContrast(ink, kPaper, target: kMinContrastGraphic),
      // 实心填充底：先把「底上的字」选好，再反过来保证底够深/够浅
      inkFill: adjustForContrast(ink, onInk),
      // 纸/wash 上的文字图标：inkWash 比纸暗 → 对它达标即两处都达标
      inkText: adjustForContrast(ink, inkWash),
      inkDeep: adjustForContrast(Color.lerp(ink, kInkBlack, 0.3)!, inkWash),
      inkWash: inkWash,
      onInk: onInk,
      accent: accent,
      accentFill: adjustForContrast(accent, onAccent),
      accentDeep:
          adjustForContrast(Color.lerp(accent, kInkBlack, 0.3)!, accentWash),
      accentWash: accentWash,
      onAccent: onAccent,
    );
  }

  /// 兜底配色（默认配方）。widget 单测不带本 App 主题时靠它，
  /// 保证取到的墨色 = 真机默认配方的墨色。
  static final AppPalette fallback = AppPalette.fromRecipe(kDefaultInkRecipe);

  /// 取当前配色（无扩展 → [fallback]）。
  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? fallback;

  @override
  AppPalette copyWith({
    Color? ink,
    Color? inkDeco,
    Color? inkFill,
    Color? inkText,
    Color? inkDeep,
    Color? inkWash,
    Color? onInk,
    Color? accent,
    Color? accentFill,
    Color? accentDeep,
    Color? accentWash,
    Color? onAccent,
  }) {
    return AppPalette(
      ink: ink ?? this.ink,
      inkDeco: inkDeco ?? this.inkDeco,
      inkFill: inkFill ?? this.inkFill,
      inkText: inkText ?? this.inkText,
      inkDeep: inkDeep ?? this.inkDeep,
      inkWash: inkWash ?? this.inkWash,
      onInk: onInk ?? this.onInk,
      accent: accent ?? this.accent,
      accentFill: accentFill ?? this.accentFill,
      accentDeep: accentDeep ?? this.accentDeep,
      accentWash: accentWash ?? this.accentWash,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  /// 逐通道插值：`MaterialApp` 的 AnimatedTheme 换主题时靠它做平滑过渡。
  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      ink: Color.lerp(ink, other.ink, t)!,
      inkDeco: Color.lerp(inkDeco, other.inkDeco, t)!,
      inkFill: Color.lerp(inkFill, other.inkFill, t)!,
      inkText: Color.lerp(inkText, other.inkText, t)!,
      inkDeep: Color.lerp(inkDeep, other.inkDeep, t)!,
      inkWash: Color.lerp(inkWash, other.inkWash, t)!,
      onInk: Color.lerp(onInk, other.onInk, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentFill: Color.lerp(accentFill, other.accentFill, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
      accentWash: Color.lerp(accentWash, other.accentWash, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
    );
  }
}

/// 便捷取色：`context.palette.ink`。
extension AppPaletteX on BuildContext {
  AppPalette get palette => AppPalette.of(this);
}
