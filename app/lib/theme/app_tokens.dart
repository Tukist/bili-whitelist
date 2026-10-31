import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 全局设计 token（P1 视觉地基）。
///
/// 设计语言：单墨/双墨编辑印刷美学——「纸」为底材，「墨」为内容。
/// 全 App 只有两个墨色，各有固定职责，不得混用：
/// - 主墨 = [kInkKlein]（克莱因蓝）= **观看的墨**：品牌、导航选中、主按钮、
///   热力图、观看进度、链接；
/// - 点缀墨 = [kInkClay]（赤陶）= **新鲜的墨**：只表达时间与新鲜度
///   （「N 天前更新」角标、未读数/未读点、后续「新加入」标记）。
///
/// 使用约定（P1.5 起）：
/// - **墨色**（主墨 / 点缀墨及其派生）→ 一律用 `context.palette.*`
///   （见 `app_palette.dart`）：换配色配方自动跟随，且带对比度护栏；
/// - **中性 / 底材 / 语义**（本文件中段）→ 直接引用本文件的 getter（如
///   [kPaper]）：与配色配方无关，但**随浅色/深色切换**；
/// - **播放页反转底材 / 媒体遮罩**（[kPlayerPaper]、[kMediaScrim] 那一组）→
///   恒定不变（底色是画面，不是页面）；
/// - 页面里不要写 `Color(0x...)` 字面量，也不要用 `colorScheme.*` 去取精确色
///   （widget 单测不带本主题，用 colorScheme 会与真机观感不一致）。
/// 主题装配见 `app_theme.dart`。
///
/// **v2.57.0 夜间模式**：底材 / 中性墨 / 语义色**不再是一组固定常量**，而是
/// 从 [AppSurfaces] 里按「当前亮度」解析的 getter（[kPaper] 等同名 getter 的
/// 对外写法与用法完全不变，`kPaper` 仍是"页面底材"这一个语义）。
/// 理由见 [AppSurfaces] 的注释：全库 300+ 处直接引用这些 token，改成
/// `context.xxx` 会把每个调用点都改一遍；按亮度解析只需要在「换主题」这一处
/// 决定用哪套值，页面代码零改动。
///
/// 墨色（主墨 / 点缀墨）**不在这里**：它们由配方决定，见 `app_palette.dart`。

// ==================== 亮度 → 一整套底材/中性色 ====================

/// 一套「底材 / 中性墨 / 语义色」的取值。
///
/// **为什么用这个类而不是把 token 全部改成 `context.xxx`**（v2.57.0 的关键
/// 工程判断）：全库有 300+ 处直接引用 [kPaper] / [kInkBlack] / [kRule] 这类
/// token，其中不少在**没有 `BuildContext`** 的地方（静态转换函数、规格表、
/// 播放页的控制层构造）。把它们全改成 `context.surfaces.xxx` 不但要改上百个
/// 调用点，还会顺手把"这个颜色跟主题无关"的地方改出依赖。
///
/// 所以采取：**token 名字与对外用法完全不变**（`kPaper` 仍是那一个 getter），
/// 只是它背后指向的那套值由「当前亮度」决定：
/// - [buildAppTheme] 按传入的亮度**临时**安装一套（[withSurfaces]），装配完
///   就还原 —— 所以 [light]、[dark] 两套 ThemeData 各自取到正确的值；
/// - App 真正处在哪个亮度，由 `main.dart` 在每次 build 里
///   [installSurfaces] 一次，页面读 token 就是那一套。
///
/// 代价（已接受，且有兜底）：token 不是 `InheritedWidget`，**换亮度时不会自动
/// 让页面重建** → `main.dart` 换亮度后会显式把已挂载的元素标脏一次
/// （见 `theme/theme_rebuild.dart`）。换配色配方那一路本来就走
/// `Theme`/`AppPalette.lerp`，与此无关。
@immutable
class AppSurfaces {
  const AppSurfaces({
    required this.paper,
    required this.paperCool,
    required this.paperWarm,
    required this.paperRaised,
    required this.inkBlack,
    required this.inkGray70,
    required this.inkGray50,
    required this.inkGray30,
    required this.rule,
    required this.ruleStrong,
    required this.error,
    required this.success,
  });

  /// 页面 / AppBar / NavigationBar 底材
  final Color paper;

  /// 内嵌分区底 / 输入框底 / 进度轨道
  final Color paperCool;

  /// 「危险区」类分组底（克制使用）
  final Color paperWarm;

  /// 抬高底：卡片 / 对话框 / 弹层 / SnackBar
  final Color paperRaised;

  /// 主文字
  final Color inkBlack;

  /// 次要文字
  final Color inkGray70;

  /// 三级文字 / 元信息
  final Color inkGray50;

  /// 禁用文字
  final Color inkGray30;

  /// hairline 描边 / 分隔
  final Color rule;

  /// 卡片外框
  final Color ruleStrong;

  /// Signal Red
  final Color error;

  final Color success;

  /// 浅色纸面：**逐字节 = v2.55.0 的常量值**（默认路径不许漂移一分）。
  static const AppSurfaces light = AppSurfaces(
    paper: Color(0xFFFAFAF7),
    paperCool: Color(0xFFE9E9E5),
    paperWarm: Color(0xFFF5F1E8),
    // 浅色下「抬高」与页面同色：观感与 v2.55.0 完全一致，
    // 抬高级别只靠 1px 描边表达（原本就是这样）。
    paperRaised: Color(0xFFFAFAF7),
    inkBlack: Color(0xFF16181C),
    inkGray70: Color(0xFF5A5F66),
    inkGray50: Color(0xFF8A9099),
    inkGray30: Color(0xFFB9BEC5),
    rule: Color(0xFFDDDDD6),
    ruleStrong: Color(0xFFC9C9C1),
    error: Color(0xFFC83232),
    success: Color(0xFF1F7A55),
  );

  /// 暗色「夜纸」：**三层底材**，靠**层级提亮**表达高度，不用纯黑。
  ///
  /// 取值依据（参考 BewlyBewly 的暗色做法，再按本库「纸 + 墨」的观感微调）：
  /// - 层 1 [paper] `#15171C`：页面底。带一点冷调（约 hsl 226 13% 10%），
  ///   不是 `#000`——纯黑上任何描边都像"显示器漏光"，且 OLED 拖影明显；
  /// - 层 2 [paperCool] `#1E2128`：内嵌分区 / 输入框 / 回复块（比页面亮一档）；
  /// - 层 3 [paperRaised] `#23262D`：卡片 / 对话框 / 弹层 / SnackBar（最亮一档）；
  /// - [paperWarm] `#272320`：同层 3 但带暖调，给「危险区」分组用（浅色下
  ///   它也是暖米，职责不变）。
  ///
  /// 文字层级 = 夜纸白的 100 / 80 / 60 / 40%（Bewly 的文案分级思路）：
  /// [inkBlack] 100%（≈14.9:1）、[inkGray70] 80%（≈9.2:1）、
  /// [inkGray50] 60%（≈5.5:1，仍过 WCAG AA 正文 4.5:1）、
  /// [inkGray30] 40%（≈3.0:1，仅禁用态，WCAG 对禁用态不设门槛）。
  ///
  /// 描边：[rule] `#343841`（≈26% 白）、[ruleStrong] `#464B55`（≈34% 白）——
  /// 比浅色的 18% 明显更重，否则"框"在暗底上会消失。
  ///
  /// 语义色提亮到仍能过 4.5:1：[error] `#F07878`（≈6.5:1）、
  /// [success] `#45C08C`（≈7.8:1）。
  static const AppSurfaces dark = AppSurfaces(
    paper: Color(0xFF15171C),
    paperCool: Color(0xFF1E2128),
    paperWarm: Color(0xFF272320),
    paperRaised: Color(0xFF23262D),
    inkBlack: Color(0xFFE8EAED),
    inkGray70: Color(0xFFB6BAC1),
    inkGray50: Color(0xFF8A8F98),
    inkGray30: Color(0xFF5E636C),
    rule: Color(0xFF343841),
    ruleStrong: Color(0xFF464B55),
    error: Color(0xFFF07878),
    success: Color(0xFF45C08C),
  );

  /// 按亮度取一套（纯函数）。
  static AppSurfaces of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// 是不是暗色那套（以底材亮度判定，比"记一个 bool"更"笨但不会错"）。
  bool get isDark => relativeLuminance(paper) < 0.2;
}

/// 当前生效的一套（App 运行期只读它）。
AppSurfaces _surfaces = AppSurfaces.light;

/// 当前生效的一套底材/中性色（[buildAppTheme] 内部按亮度临时安装）。
AppSurfaces get appSurfaces => _surfaces;

/// 按亮度安装当前生效的一套。**幂等**；由 `main.dart` 在 build 里调。
void installSurfaces(Brightness brightness) {
  _surfaces = AppSurfaces.of(brightness);
}

/// 临时切到 [surfaces] 跑一段同步代码，跑完**还原**之前那一套。
///
/// 用于 [buildAppTheme]：装配浅色主题时不能污染运行期那套值（想浅色主题在
/// 暗色模式下被装配时也拿到浅色 token）。
T withSurfaces<T>(AppSurfaces surfaces, T Function() body) {
  final prev = _surfaces;
  _surfaces = surfaces;
  try {
    return body();
  } finally {
    _surfaces = prev;
  }
}

/// 测试用：把运行期那套恢复成浅色纸面（单例/全局态跨用例串味的兜底）。
@visibleForTesting
void resetSurfacesForTest() => _surfaces = AppSurfaces.light;

// ==================== 底材 substrate（按亮度解析） ====================

/// 页面 / AppBar / NavigationBar 底材（浅色 = 暖白，非纯白；暗色 = 夜纸）
Color get kPaper => _surfaces.paper;

/// 冷灰：输入框底、内嵌分区底、进度轨道、进度条未看段
/// （暗色 = 比夜纸亮一档的「夜纸·内容」）
Color get kPaperCool => _surfaces.paperCool;

/// 暖米：仅用于设置页「危险区」类分组底（克制使用）
/// （暗色 = 带暖调的「夜纸·暖」）
Color get kPaperWarm => _surfaces.paperWarm;

/// 「抬高」底材：卡片 / 对话框 / 底部弹层 / SnackBar。
///
/// 浅色下**恒等于 [kPaper]**（0xFFFAFAF7，逐字节与 v2.55.0 一致），所以浅色
/// 路径的观感与断言都不变；暗色下它比 [kPaper] 亮一档，用**提亮**表达「浮在
/// 页面之上」（参考 BewlyBewly：elevated 层靠抬亮度而不是加阴影）。
Color get kPaperRaised => _surfaces.paperRaised;

// ==================== 墨 ink：只有两个，各有职责 ====================

/// 主墨「观看的墨」：品牌、导航选中、主按钮、热力图、观看进度、链接
const kInkKlein = Color(0xFF002FA7); // 克莱因蓝

/// 主墨按下态 / onPrimaryContainer
const kInkKleinDeep = Color(0xFF00227A);

/// 主墨 12% 稀释：选中底 / 徽标底 / 热力最浅档
const kInkKleinWash = Color(0xFFD5E5FF);

/// 点缀墨「新鲜的墨」：固定职责 = 时间与新鲜度（「N 天前更新」角标、
/// 未读数/未读点、后续「新加入」标记）
const kInkClay = Color(0xFFC65F38); // 赤陶 Terracotta

/// 点缀 15% 稀释：角标底
const kInkClayWash = Color(0xFFF3E2DA);

// ==================== 中性墨（文字/描边） ====================

/// 主文字（暗色 = 夜纸白 100%）
Color get kInkBlack => _surfaces.inkBlack;

/// 次要文字（暗色 = 夜纸白 ~80%）
Color get kInkGray70 => _surfaces.inkGray70;

/// 三级文字/元信息（暗色 = 夜纸白 ~60%）
Color get kInkGray50 => _surfaces.inkGray50;

/// 禁用文字（暗色 = 夜纸白 ~40%）
Color get kInkGray30 => _surfaces.inkGray30;

/// hairline 描边/分隔（1px）。
///
/// ★ 暗色下**必须更重**（v2.57.0）：浅色是「纸上的浅灰线」（≈18% 墨），
/// 暗色里同样比例的线会消失在夜纸上，"框"就没了结构；故暗色取 ≈26% 白。
Color get kRule => _surfaces.rule;

/// 卡片外框（1px），暗色同样加强
Color get kRuleStrong => _surfaces.ruleStrong;

// ==================== 语义色 ====================

/// Signal Red（暗色下提亮，否则在夜纸上偏闷、对比度不足）
Color get kError => _surfaces.error;

Color get kSuccess => _surfaces.success;

// ==================== 反转底材（播放页黑底视口内） ====================

/// 媒体遮罩 / 遮罩上的字：**恒定不随明暗切换**（v2.57.0 拆分）。
///
/// 这几个 token 的底色永远是**画面**（封面图、视频纹理、直播画面），不是
/// 页面底材 —— 所以它们不能跟着 [kPaper]/[kInkBlack] 走：夜间模式下
/// [kInkBlack] 会变成夜纸白，若还拿它当"封面上的暗遮罩"，角标就会在暗色
/// 界面里变成一块**白底**（这正是夜间模式最常见的翻车点）。
///
/// [kMediaScrim] = 旧 [kInkBlack] 的固定值（0xFF16181C），遮罩底用它；
/// [kMediaInk] = 旧 [kPaper] 的固定值（0xFFFAFAF7），遮罩上的字用它。
const kMediaScrim = Color(0xFF16181C);

/// 媒体遮罩上的字/图标（恒定纸白，见 [kMediaScrim]）
const kMediaInk = Color(0xFFFAFAF7);


/// 暗底上的「纸」
const kPlayerPaper = Color(0xFFFAFAF7);

/// 开启/选中：纸白 100%
const kPlayerOn = Color(0xFFFAFAF7);

/// 次级可点：白 54%
const kPlayerOnDim = Color(0x8AFFFFFF);

/// 关闭/未选中：白 38%
const kPlayerOff = Color(0x61FFFFFF);

/// 白 24%（轨道/分隔）
const kPlayerRule = Color(0x3DFFFFFF);

// ==================== 字阶 ====================

/// 大数字（热力总览等）：等宽数字，避免数字跳动
const kTypeDisplay = TextStyle(
    fontSize: 40,
    height: 1.05,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.0,
    fontFeatures: [FontFeature.tabularFigures()]);

/// 页面标题
const kTypeTitleL = TextStyle(
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2);

/// 区块标题
const kTypeTitleM =
    TextStyle(fontSize: 16, height: 1.30, fontWeight: FontWeight.w600);

/// 小组标题
const kTypeTitleS =
    TextStyle(fontSize: 14, height: 1.30, fontWeight: FontWeight.w600);

/// 正文
const kTypeBody =
    TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w400);

/// 小正文
const kTypeBodyS =
    TextStyle(fontSize: 12, height: 1.40, fontWeight: FontWeight.w400);

/// 全大写小标签（字距放宽）
const kTypeLabel = TextStyle(
    fontSize: 11,
    height: 1.20,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6);

/// 数字（等宽），用于计数、时长、日期等
const kTypeNum = TextStyle(
    fontSize: 12,
    height: 1.20,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()]);

// ==================== 间距 ====================

const kSpace2 = 2.0, kSpace4 = 4.0, kSpace8 = 8.0, kSpace12 = 12.0,
    kSpace16 = 16.0, kSpace24 = 24.0, kSpace32 = 32.0, kSpace48 = 48.0;

/// 列表页水平边距
const kPagePadH = 16.0;

/// 空态/设置页水平边距
const kSectionPadH = 24.0;

/// 卡片内边距
const kCardPad = 12.0;

/// 列表项间距
const kListGap = 12.0;

/// 区块间距
const kBlockGap = 24.0;

/// 空态顶部留白
const kEmptyTopGap = 120.0;

// ==================== 圆角 ====================

/// 热力格、角标
const kRadiusXs = 2.0;

/// 封面缩略图
const kRadiusSm = 4.0;

/// 卡片 / 按钮 / 输入框
const kRadiusMd = 8.0;

/// 底部弹层顶角
const kRadiusLg = 20.0;

// ==================== 动效 ====================

const kDurQuick = Duration(milliseconds: 120);
const kDurBase = Duration(milliseconds: 200);
const kDurSlow = Duration(milliseconds: 320);
const kCurveOut = Cubic(0.2, 0, 0, 1);
const kCurveInOut = Cubic(0.4, 0, 0.2, 1);

// ==================== 无障碍对比度（WCAG 2.1） ====================

/// 正文 / 小图标的最低对比度门槛（WCAG 2.1 AA 正文标准 4.5:1）。
const kMinContrastBody = 4.5;

/// WCAG 相对亮度（0..1，纯函数）：
/// sRGB 通道先去 gamma（≤0.03928 走线性段），再按
/// 0.2126R + 0.7152G + 0.0722B 加权。
double relativeLuminance(Color c) {
  double linear(double channel) => channel <= 0.03928
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(c.r) +
      0.7152 * linear(c.g) +
      0.0722 * linear(c.b);
}

/// WCAG 对比度 `(L1 + 0.05) / (L2 + 0.05)`（纯函数）：
/// 与 [a]/[b] 顺序无关；同色 = 1，黑白 ≈ 21。
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
