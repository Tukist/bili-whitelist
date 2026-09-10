import 'package:flutter/material.dart';

/// 双墨配色配方表（P1.5）。
///
/// 来源：mono-color-skill（https://github.com/yanliudesign/mono-color-skill）
/// 的 README「Two-ink recipes」双色配方 + `design-system/colors.json`。
/// 色值**逐字照抄**，不要在这里调整/微调任何十六进制值。
///
/// 语义约定（沿用 P1 设计语言）：一套配方只有两墨——
/// - [InkRecipe.ink]（主墨）承担**观看**语义：品牌、导航选中、主按钮、
///   热力图、观看进度、链接；
/// - [InkRecipe.accent]（点缀墨）承担**时间与新鲜度**语义：「N 天前更新」
///   角标、未读数/未读点等。
///
/// 底材（纸）本版固定为 [kPaper]，不随配方变化，故不做底材选择器。
class InkRecipe {
  /// 稳定 id（持久化用）：**不要**随后续改名而变更，否则用户已存的选择会失效。
  final String id;

  /// 中文显示名。
  final String label;

  /// 英文原名（副标题 / 工具提示）。
  final String labelEn;

  /// 主墨（观看）。
  final Color ink;

  /// 点缀墨（时间 / 新鲜度）。
  final Color accent;

  const InkRecipe({
    required this.id,
    required this.label,
    required this.labelEn,
    required this.ink,
    required this.accent,
  });
}

/// 默认配色 = P1 现状（克莱因蓝 · 陶土）。**色值不可改**，
/// 保证开箱即用的观感与 P1 一致。
const kDefaultInkRecipe = InkRecipe(
  id: 'klein_clay',
  label: '克莱因蓝 · 陶土',
  labelEn: 'Klein Blue · Terracotta',
  ink: Color(0xFF002FA7),
  accent: Color(0xFFC65F38),
);

/// 全部可选配色：**首位 = 默认**（[kDefaultInkRecipe]），其余按官方配方表顺序。
const kInkRecipes = <InkRecipe>[
  kDefaultInkRecipe,
  InkRecipe(
    id: 'powder_blue_signal_red',
    label: '粉蓝 · 信号红',
    labelEn: 'Powder Blue · Signal Red',
    ink: Color(0xFF9EB8D3),
    accent: Color(0xFFC83232),
  ),
  InkRecipe(
    id: 'cobalt_terracotta',
    label: '钴蓝 · 陶土',
    labelEn: 'Cobalt · Terracotta',
    ink: Color(0xFF2148B8),
    accent: Color(0xFFC65F38),
  ),
  InkRecipe(
    id: 'botanical_green_oxblood',
    label: '植物绿 · 牛血红',
    labelEn: 'Botanical Green · Oxblood',
    ink: Color(0xFF008A4B),
    accent: Color(0xFF8F3434),
  ),
  InkRecipe(
    id: 'charcoal_signal_red',
    label: '炭黑 · 信号红',
    labelEn: 'Charcoal · Signal Red',
    ink: Color(0xFF30343A),
    accent: Color(0xFFC83232),
  ),
  InkRecipe(
    id: 'electric_blue_carbon',
    label: '电光蓝 · 碳黑',
    labelEn: 'Electric Blue · Carbon',
    ink: Color(0xFF173AE3),
    accent: Color(0xFF242321),
  ),
  InkRecipe(
    id: 'mint_green_warm_charcoal',
    label: '薄荷绿 · 暖炭',
    labelEn: 'Mint Green · Warm Charcoal',
    ink: Color(0xFF5EB783),
    accent: Color(0xFF302D2E),
  ),
  InkRecipe(
    id: 'ultramarine_safety_orange',
    label: '群青 · 安全橙',
    labelEn: 'Ultramarine · Safety Orange',
    ink: Color(0xFF263E99),
    accent: Color(0xFFE55D2B),
  ),
  InkRecipe(
    id: 'cyan_brick_red',
    label: '青色 · 砖红',
    labelEn: 'Cyan · Brick Red',
    ink: Color(0xFF159DDA),
    accent: Color(0xFFB64032),
  ),
  InkRecipe(
    id: 'tangerine_slate_blue',
    label: '橘 · 板岩蓝',
    labelEn: 'Tangerine · Slate Blue',
    ink: Color(0xFFE46C2D),
    accent: Color(0xFF4773A5),
  ),
];

/// 按 id 查配方（纯函数）；查不到返回 null（调用方回退 [kDefaultInkRecipe]）。
InkRecipe? inkRecipeById(String id) {
  for (final r in kInkRecipes) {
    if (r.id == id) return r;
  }
  return null;
}
