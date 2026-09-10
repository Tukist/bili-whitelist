// 双墨配色配方表（P1.5，theme/ink_recipes.dart）单测：
// - 共 10 项（默认 + mono-color-skill 的 9 组双色配方）
// - id 唯一且稳定（持久化用），首位 = 默认项 klein_clay（= P1 克莱因蓝 · 陶土）
// - 每组色值与官方表逐字一致（这里写死期望值，防止有人「顺手微调」）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/ink_recipes.dart';

/// 官方配方表（README「Two-ink recipes」）：中文名 → (ink, accent)。
/// 顺序即 UI 展示顺序（默认项在最前）。
const _expected = <List<Object>>[
  ['klein_clay', '克莱因蓝 · 陶土', 0xFF002FA7, 0xFFC65F38],
  ['powder_blue_signal_red', '粉蓝 · 信号红', 0xFF9EB8D3, 0xFFC83232],
  ['cobalt_terracotta', '钴蓝 · 陶土', 0xFF2148B8, 0xFFC65F38],
  ['botanical_green_oxblood', '植物绿 · 牛血红', 0xFF008A4B, 0xFF8F3434],
  ['charcoal_signal_red', '炭黑 · 信号红', 0xFF30343A, 0xFFC83232],
  ['electric_blue_carbon', '电光蓝 · 碳黑', 0xFF173AE3, 0xFF242321],
  ['mint_green_warm_charcoal', '薄荷绿 · 暖炭', 0xFF5EB783, 0xFF302D2E],
  ['ultramarine_safety_orange', '群青 · 安全橙', 0xFF263E99, 0xFFE55D2B],
  ['cyan_brick_red', '青色 · 砖红', 0xFF159DDA, 0xFFB64032],
  ['tangerine_slate_blue', '橘 · 板岩蓝', 0xFFE46C2D, 0xFF4773A5],
];

void main() {
  group('kInkRecipes 配方表', () {
    test('共 10 项：默认 + 9 组双色配方', () {
      expect(kInkRecipes.length, 10);
      expect(_expected.length, 10);
    });

    test('首位 = 默认项（klein_clay，主墨 #002FA7 + 点缀 #C65F38）', () {
      expect(kInkRecipes.first.id, kDefaultInkRecipe.id);
      expect(kDefaultInkRecipe.id, 'klein_clay');
      expect(kDefaultInkRecipe.ink, const Color(0xFF002FA7));
      expect(kDefaultInkRecipe.accent, const Color(0xFFC65F38));
      expect(kDefaultInkRecipe.label, '克莱因蓝 · 陶土');
    });

    test('id 唯一（持久化若重名会串味）', () {
      final ids = kInkRecipes.map((r) => r.id).toSet();
      expect(ids.length, kInkRecipes.length);
    });

    test('每项色值/名称与官方配方表逐字一致（顺序也一致）', () {
      for (var i = 0; i < _expected.length; i++) {
        final e = _expected[i];
        final r = kInkRecipes[i];
        expect(r.id, e[0], reason: '第 $i 项 id');
        expect(r.label, e[1], reason: '第 $i 项中文名');
        expect(r.ink, Color(e[2] as int), reason: '${r.id} 主墨');
        expect(r.accent, Color(e[3] as int), reason: '${r.id} 点缀墨');
        expect(r.labelEn, isNotEmpty, reason: '${r.id} 英文原名');
      }
    });

    test('英文原名互相不同（UI 副标题不会撞车）', () {
      final ens = kInkRecipes.map((r) => r.labelEn).toSet();
      expect(ens.length, kInkRecipes.length);
    });
  });

  group('inkRecipeById', () {
    test('命中：按 id 取回同一项', () {
      for (final r in kInkRecipes) {
        expect(inkRecipeById(r.id)?.id, r.id);
        expect(inkRecipeById(r.id)?.ink, r.ink);
      }
    });

    test('未命中 / 空串 → null（调用方回退默认）', () {
      expect(inkRecipeById('nope'), isNull);
      expect(inkRecipeById(''), isNull);
      expect(inkRecipeById('KLEIN_CLAY'), isNull); // 大小写敏感
    });
  });
}
