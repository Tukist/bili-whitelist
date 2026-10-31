import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_tokens.dart';
import 'ink_recipes.dart';
import 'route_names.dart';

/// 全局主题装配（P1 视觉地基 + P1.5 配方可切换 + 无障碍对比度护栏）。
///
/// 单墨/双墨编辑印刷：底材是「纸」([kPaper] 系，**不随配方变化**、但**随明暗
/// 切换**——v2.57.0 起暗色是「夜纸」三层），内容用
/// 「墨」——主墨（观看）/ 点缀墨（新鲜度）由 [recipe] 决定，默认
/// [kDefaultInkRecipe]（克莱因蓝 · 陶土，= P1 观感）。
///
/// 颜色分两类：
/// - **墨相关**（primary/tertiary 及其 container、导航选中、按钮、滑杆、
///   输入框聚焦、chip 选中…）→ 一律取 [AppPalette] 派生色，换配方即全库变色；
/// - **中性/底材/语义**（[kInkBlack]/[kInkGray*]/[kRule*]/[kPaper*]/[kError]/
///   [kSuccess]）→ 与配方无关，但由 [AppSurfaces] 按当前亮度解析
///   （浅色 = 纸面 / 暗色 = 夜纸）；播放页反转底材 [kPlayer*] 与媒体遮罩
///   [kMediaScrim]/[kMediaInk] 恒不变。
///
/// **墨按用途选档**（见 [AppPalette] 注释）：文字/图标上纸走 `inkText`、
/// 实心填充底走 `inkFill`（配 `onInk`）、容器底文字走 `inkDeep`；
/// 只有装饰/热力/进度这类大面积用途才用配方原墨 `ink`。
///
/// 派生色同时通过 `extensions: [p]` 挂到 [ThemeData] 上，页面用
/// `context.palette.*` 取（无主题的 widget 单测会兜底默认配方，见
/// `app_palette.dart`）。
///
/// 说明：本函数只装配 `ThemeData`，**不改变任何布局/尺寸/交互**。
///
/// [brightness]（v2.57.0 夜间模式）：浅色 = 纸面（默认，逐值等于 v2.55.0），
/// 暗色 = 夜纸三层（见 [AppSurfaces.dark]）。两套 ThemeData 由 `main.dart`
/// 分别装进 `MaterialApp.theme` / `darkTheme`。
///
/// 装配期间用 [withSurfaces] 临时安装这套底材，装配完还原：本函数里的
/// [kPaper]/[kRule]… 一律取"它正在装配的那套"，而不是运行期那套 —— 于是浅色
/// 主题永远按浅色纸面派生，不会因为用户在暗色模式下而装配出暗色纸的浅色主题。
ThemeData buildAppTheme([
  InkRecipe recipe = kDefaultInkRecipe,
  Brightness brightness = Brightness.light,
]) {
  final s = AppSurfaces.of(brightness);
  return withSurfaces(s, () => _assembleAppTheme(recipe, brightness, s));
}

ThemeData _assembleAppTheme(
    InkRecipe recipe, Brightness brightness, AppSurfaces s) {
  final p = AppPalette.fromRecipe(recipe, surfaces: s);

  // 以主墨为种子生成 M3 色板，再把关键槽位显式钉到派生色/ token 上，
  // 保证「同一个语义 = 同一个颜色」，不受种子算法版本影响。
  final scheme = ColorScheme.fromSeed(seedColor: p.ink, brightness: brightness)
      .copyWith(
    // primary 在本库主要用于「纸上的链接 / 图标 / 导航选中」→ 用可读档；
    // 实心按钮底另走 filledButtonTheme 的 inkFill + onInk。
    primary: p.inkText,
    onPrimary: p.onInk,
    primaryContainer: p.inkWash,
    onPrimaryContainer: p.inkDeep,
    secondary: kInkBlack,
    // secondaryContainer / tertiaryContainer 必须显式映射：否则会落到 M3
    // 种子算法的色阶（tertiary 在 tonal spot 下会色相偏转到粉紫），
    // 首页合集封面渐变 / 收藏夹卡渐变 / 未登录提示条会露出非配方颜色。
    secondaryContainer: p.inkWash,
    onSecondaryContainer: p.inkDeep,
    tertiary: p.accentFill,
    onTertiary: p.onAccent,
    tertiaryContainer: p.accentWash,
    onTertiaryContainer: p.accentDeep,
    error: kError,
    surface: kPaper,
    onSurface: kInkBlack,
    onSurfaceVariant: kInkGray70,
    outline: kInkGray50,
    outlineVariant: kRule,
    // ★ surfaceContainerHighest 必须指向 kPaperCool：全库多处
    // `surfaceContainerHighest.withValues(alpha: ...)` 的内嵌分区底靠它取色。
    // 暗色下它是「夜纸·内容」（比页面亮一档）——内嵌分区在暗色下靠"更亮"
    // 表达凹/凸，而不是靠更暗（暗色里压暗会直接糊进页面）。
    surfaceContainerHighest: kPaperCool,
    surfaceContainerHigh: kPaperCool,
    surfaceContainer: kPaper,
    // ★ 抬高层（v2.57.0）：M3 的 BottomSheet 取这个槽位。浅色下
    // kPaperRaised == kPaper，逐值等于 v2.55.0；暗色下是最亮的夜纸层。
    surfaceContainerLow: kPaperRaised,
  );

  // 字阶：把 token 里的 8 档映射到 M3 槽位，颜色显式写死
  // （不用 onSurface 继承，避免被 colorScheme 覆盖）。
  final textTheme = TextTheme(
    displayLarge: kTypeDisplay.copyWith(color: kInkBlack),
    titleLarge: kTypeTitleL.copyWith(color: kInkBlack),
    titleMedium: kTypeTitleM.copyWith(color: kInkBlack),
    titleSmall: kTypeTitleS.copyWith(color: kInkBlack),
    bodyMedium: kTypeBody.copyWith(color: kInkBlack),
    bodySmall: kTypeBodyS.copyWith(color: kInkGray70),
    labelSmall: kTypeLabel.copyWith(color: kInkGray70),
    labelMedium: kTypeNum.copyWith(color: kInkGray70),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // 色板亮度必须显式给：只给 colorScheme 不带 brightness 时，ThemeData 会用
    // colorScheme.brightness 兜底，但明写一条让"暗色"这件事在主题上可见。
    brightness: brightness,
    // 派生色挂到主题上：页面 `context.palette.*` 取墨色（换配方自动跟随）
    extensions: [p],
    scaffoldBackgroundColor: kPaper,
    textTheme: textTheme,
    // ---- 触摸目标 / 密度（Android 无障碍）----
    // 显式钉住，不依赖平台默认值被将来改掉：
    // - padded = 交互区至少 48×48dp（Material 最小触摸目标）；
    // - visualDensity 用 standard（Android 默认），不收紧成 compact，
    //   避免把按钮/列表项压到 48dp 以下。
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: kPaper,
      foregroundColor: kInkBlack,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      // 底部 1px 描边代替阴影（层级靠细线，不靠投影）。
      // 必要：AppBar 与页面同底材 kPaper，内容滚到它下方时若没有任何分隔，
      // 标题栏与内容会糊成一片；而本主题已把 scrolledUnderElevation 钉成 0
      // 且 surfaceTint 透明，M3 的滚动 tint 不会出现，故分隔只能靠这条线，
      // 它常驻可见（不随滚动状态变化）。
      // 暗色下 kRule 已加强（见 AppSurfaces.dark 的注释），这条线才看得见。
      shape: Border(bottom: BorderSide(color: kRule, width: 1)),
      titleTextStyle: kTypeTitleL.copyWith(color: kInkBlack),
      // 系统栏图标：不钉死，交给 AppBar 按 ThemeData.brightness 自动推导
      // （暗色 → 白色图标，浅色 → 深色图标）。
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: kPaper,
      indicatorColor: p.inkWash,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? p.inkText : kInkGray50,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => kTypeLabel.copyWith(
          color:
              states.contains(WidgetState.selected) ? p.inkText : kInkGray50,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: kRule,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      // 抬高底（v2.57.0）：浅色 == kPaper（逐值不变），暗色 = 最亮那层夜纸，
      // 卡片靠"比页面稍亮 + 更强描边"浮起来（Bewly 的做法：层级靠提亮）。
      color: kPaperRaised,
      // 本版 Flutter 的 CardThemeData 没有 side 参数，卡片外框走 shape 的 side。
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        side: BorderSide(color: kRuleStrong, width: 1),
      ),
    ),
    // 实心填充底 = inkFill（保证 onInk 在其上 ≥ 4.5:1）
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.inkFill,
        foregroundColor: p.onInk,
        elevation: 0,
        textStyle: kTypeTitleS,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
      ),
    ),
    // 描边/文字按钮：label 直接坐在纸上 → 用纸上的可读墨
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.inkText,
        side: BorderSide(color: kRule),
        elevation: 0,
        textStyle: kTypeTitleS,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.inkText,
        textStyle: kTypeTitleS,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // 暗色下 = 夜纸·内容（比页面亮一档），输入框才看得出是个"槽"
      fillColor: kPaperCool,
      hintStyle: kTypeBody.copyWith(color: kInkGray50),
      labelStyle: kTypeBody.copyWith(color: kInkGray70),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: kRule),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: kRule),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: p.inkText, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: kError),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        borderSide: BorderSide(color: kError, width: 1.5),
      ),
    ),
    // 底部提示条：浅色沿用「近黑底 + 纸白字」的反转条（v2.55.0 观感不变）；
    // 暗色**不能**继续反转（那会在暗界面里弹出一条刺眼的白条），改成
    // 「抬高夜纸底 + 夜纸白字」，靠底材比页面亮一档来抢注意力。
    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      backgroundColor: s.isDark ? kPaperRaised : kInkBlack,
      contentTextStyle:
          kTypeBody.copyWith(color: s.isDark ? kInkBlack : kPaper),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
    ),
    // 对话框：不单独给 dialogTheme，走 M3 槽位 surfaceContainerHigh
    // （= kPaperCool：暗色下是「夜纸·内容」，比页面亮一档，足够分层）。
    // 不显式给 backgroundColor 的理由：给了会把浅色对话框从 kPaperCool 变成
    // kPaper，属于"默认路径漂移"，不做。
    // 滑杆坐在纸上：轨道/滑块是「非文字 UI 组件」，用纸上的可读墨
    sliderTheme: SliderThemeData(
      activeTrackColor: p.inkText,
      inactiveTrackColor: kPaperCool,
      thumbColor: p.inkText,
      overlayColor: p.inkWash,
    ),
    chipTheme: ChipThemeData(
      // 抬高底：浅色 == kPaper（逐值不变），暗色 = 最亮那层夜纸
      backgroundColor: kPaperRaised,
      selectedColor: p.inkWash,
      checkmarkColor: p.inkText,
      side: BorderSide(color: kRule),
      labelStyle: kTypeLabel.copyWith(color: kInkBlack),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusXs),
      ),
    ),
    // 转场：安静地淡入 + 3% 上滑（入场页），出场页只压暗不位移。
    // 曲线由本 builder 决定，时长沿用路由自身（**不要**在这里自定义
    // transitionDuration——总时长必须留在路由给出的 ~300ms 内）。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _QuietPageTransitionsBuilder(),
        TargetPlatform.windows: _QuietPageTransitionsBuilder(),
        TargetPlatform.linux: _QuietPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// 「安静」转场：淡入 + 轻微上滑（入场）+ 轻微压暗（出场），避免 Material
/// 默认的横向推挤感，也**不做**缩放/回弹（那是"廉价感"的来源）。
///
/// 只负责曲线，不负责时长——`PageTransitionsBuilder` 的时长由路由决定
/// （Android 约 300ms）；本 builder 里绝不自定义 `transitionDuration`。
///
/// 按路由名分流：
/// - [kPlayerRouteName]（播放页）→ **快速淡入**（35% 处就到满档、位移恒为 0）。
///   封面 Hero 飞进来时本页背景必须几乎立刻"黑好"，否则封面会漂在半个透明
///   的页面上；
/// - 其余页面 → 默认三段式（见 [buildTransitions] 内注释）。
class _QuietPageTransitionsBuilder extends PageTransitionsBuilder {
  const _QuietPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // ---- 播放页：快速淡入，位移 0 ----
    // 只淡不滑：Hero 封面已经在飞，页面再滑一下会让两个动作互相干扰。
    if (route.settings.name == kPlayerRouteName) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(0.00, 0.35, curve: kCurveOut),
        ),
        child: child,
      );
    }

    // ---- 默认：入场淡入 + 上滑，出场压暗 ----
    // 透明度在 [0.00, 0.60] 内先到位、位移走满 [0.00, 1.00] 收尾 → 读起来是
    // "落定"，不是"飘进来"。上滑量 0.030 比原来的 0.02 略强，方向感更明确。
    final incomingOpacity = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.00, 0.60, curve: kCurveOut),
    );
    final incomingSlide = Tween<Offset>(
      begin: const Offset(0, 0.030),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: animation,
      curve: const Interval(0.00, 1.00, curve: kCurveOut),
    ));
    // 出场只压暗到 0.94、**不位移**——出场页一滑就会与入场页互相"推挤"，
    // 反而更像 Material 默认那套横向推挤。
    final outgoingDim = Tween<double>(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(
        parent: secondaryAnimation,
        curve: const Interval(0.00, 1.00, curve: kCurveInOut),
      ),
    );

    return FadeTransition(
      opacity: incomingOpacity,
      child: SlideTransition(
        position: incomingSlide,
        child: FadeTransition(
          opacity: outgoingDim,
          child: child,
        ),
      ),
    );
  }
}
