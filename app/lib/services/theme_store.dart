import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/ink_recipes.dart';

/// 配色主题存储（单例）：shared_preferences 存**单个配方 id**
/// （key = [storageKey]），不存色值本身——色值以 `theme/ink_recipes.dart`
/// 的配方表为准，后续调整色值不需要迁移已存数据。
///
/// 与 [SearchHistoryStore] / [DanmakuSettingsStore] 同风格：读/写失败静默
/// 降级（读失败 = 默认配方，写失败 = 本次内存生效但下次启动回退），
/// id 不认识（旧版本残留 / 手工改坏）也回退默认配方，不崩溃、不影响启动。
///
/// 使用时当 [ChangeNotifier] 监听（`main.dart` 用它重建 [MaterialApp]），
/// 切换配方 → 全 App 换墨。默认配方 = [kDefaultInkRecipe]（P1 观感）。
class ThemeStore extends ChangeNotifier {
  /// shared_preferences 存储 key（值为配方 id，如 `klein_clay`）。
  static const String storageKey = 'ui:theme_id';

  /// 全局单例。
  static final ThemeStore instance = ThemeStore._();

  ThemeStore._();

  InkRecipe _recipe = kDefaultInkRecipe;

  /// 当前配色配方。
  InkRecipe get recipe => _recipe;

  /// 启动时读一次已保存的配方；无记录 / id 不认识 / 读取异常 → 默认配方。
  ///
  /// 读到的配方与当前一致时不发通知（避免首帧后无谓重建）。
  Future<void> ensureLoaded() async {
    var next = kDefaultInkRecipe;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(storageKey);
      if (id != null && id.isNotEmpty) {
        next = inkRecipeById(id) ?? kDefaultInkRecipe;
      }
    } catch (_) {
      // 存储异常：按默认配方启动，不抛
      next = kDefaultInkRecipe;
    }
    if (next.id == _recipe.id) return;
    _recipe = next;
    notifyListeners();
  }

  /// 切换配色：立即生效（`notifyListeners` → MaterialApp 换主题）并持久化；
  /// id 不认识时回退默认配方（与 [ensureLoaded] 一致）。
  /// 写失败静默（本次已生效，下次启动回到上次成功保存的值）。
  Future<void> select(String recipeId) async {
    final next = inkRecipeById(recipeId) ?? kDefaultInkRecipe;
    _recipe = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, next.id);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 测试用：把内存态重置回去（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest([InkRecipe? recipe]) {
    _recipe = recipe ?? kDefaultInkRecipe;
  }
}
