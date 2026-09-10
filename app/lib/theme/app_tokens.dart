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
/// - **中性 / 底材 / 语义 / 播放页反转底材**（本文件下半部分）→ 直接引用
///   本文件常量，与配色无关、固定不变；
/// - 页面里不要写 `Color(0x...)` 字面量，也不要用 `colorScheme.*` 去取精确色
///   （widget 单测不带本主题，用 colorScheme 会与真机观感不一致）。
/// 主题装配见 `app_theme.dart`。

// ==================== 底材 substrate ====================

/// 页面/AppBar/NavigationBar/卡片底材（暖白，非纯白）
const kPaper = Color(0xFFFAFAF7);

/// 冷灰：输入框底、内嵌分区底、进度轨道、进度条未看段
const kPaperCool = Color(0xFFE9E9E5);

/// 暖米：仅用于设置页「危险区」类分组底（克制使用）
const kPaperWarm = Color(0xFFF5F1E8);

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

/// 主文字
const kInkBlack = Color(0xFF16181C);

/// 次要文字
const kInkGray70 = Color(0xFF5A5F66);

/// 三级文字/元信息
const kInkGray50 = Color(0xFF8A9099);

/// 禁用文字
const kInkGray30 = Color(0xFFB9BEC5);

/// hairline 描边/分隔（1px）
const kRule = Color(0xFFDDDDD6);

/// 卡片外框（1px）
const kRuleStrong = Color(0xFFC9C9C1);

// ==================== 语义色 ====================

/// Signal Red
const kError = Color(0xFFC83232);

const kSuccess = Color(0xFF1F7A55);

// ==================== 反转底材（播放页黑底视口内） ====================

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
