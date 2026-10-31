import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/ink_recipes.dart';

/// 配色主题存储（单例）：shared_preferences 存**单个配方 id**
/// （key = [storageKey]），不存色值本身——色值以 `theme/ink_recipes.dart`
/// 的配方表为准，后续调整色值不需要迁移已存数据。
///
/// v2.57.0 起同一个 store 还存**明暗模式**（key = [modeStorageKey]，
/// `light` / `dark` / `system`，默认 `light`）：两者合起来才是"主题"，
/// 且 `main.dart` 本来就在监听本 store 重建 [MaterialApp]——
/// 分到第二个 store 只会多一条通知链。
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

  /// 明暗模式的存储 key（v2.57.0，值是 `light` / `dark` / `system`）。
  static const String modeStorageKey = 'ui:theme_mode';

  /// 全局单例。
  static final ThemeStore instance = ThemeStore._();

  ThemeStore._();

  InkRecipe _recipe = kDefaultInkRecipe;

  /// 明暗模式（v2.57.0）：**默认 light**——不改老用户观感。
  ThemeMode _themeMode = ThemeMode.light;

  /// 当前配色配方。
  InkRecipe get recipe => _recipe;

  /// 当前明暗模式（[ThemeMode.light] / [ThemeMode.dark] / [ThemeMode.system]）。
  ///
  /// 为什么存在这里而不是 `UiPrefsStore`：本 store 的语义就是「主题」（墨色 +
  /// 明暗），`main.dart` 已经在监听它重建 `MaterialApp`；放进 `UiPrefsStore`
  /// 只会让"换主题"多走一条通知链，还要在 main 里再挂一个 ListenableBuilder。
  ThemeMode get themeMode => _themeMode;

  /// 模式的中文短名（设置页按钮 / 测试断言共用，改文案只改这一处）。
  String get themeModeLabel => themeModeLabelOf(_themeMode);

  /// [ThemeMode] → 中文短名。
  static String themeModeLabelOf(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  /// 持久化用的稳定 id（**不要**改，否则老用户已存的选择会失效）。
  static String themeModeId(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  /// id → [ThemeMode]；不认识（旧版本残留 / 手工改坏）→ null，调用方回默认。
  static ThemeMode? themeModeById(String? id) {
    switch (id) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return null;
    }
  }

  /// 启动时读一次已保存的配方**与明暗模式**；无记录 / id 不认识 / 读取异常 →
  /// 默认配方 + 浅色。
  ///
  /// 读到的值与当前一致时不发通知（避免首帧后无谓重建）。
  Future<void> ensureLoaded() async {
    var next = kDefaultInkRecipe;
    var nextMode = ThemeMode.light;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(storageKey);
      if (id != null && id.isNotEmpty) {
        next = inkRecipeById(id) ?? kDefaultInkRecipe;
      }
      nextMode =
          themeModeById(prefs.getString(modeStorageKey)) ?? ThemeMode.light;
    } catch (_) {
      // 存储异常：按默认配方 + 浅色启动，不抛
      next = kDefaultInkRecipe;
      nextMode = ThemeMode.light;
    }
    if (next.id == _recipe.id && nextMode == _themeMode) return;
    _recipe = next;
    _themeMode = nextMode;
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

  /// 切换明暗模式（v2.57.0）：立即生效并持久化，写失败静默。
  ///
  /// 立即生效靠 `notifyListeners` → `main.dart` 重建 `MaterialApp`
  /// （`theme` / `darkTheme` / `themeMode` 一起换），不需要重启。
  Future<void> selectThemeMode(ThemeMode mode) async {
    if (_themeMode != mode) {
      _themeMode = mode;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(modeStorageKey, themeModeId(mode));
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 测试用：把内存态重置回去（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest([InkRecipe? recipe, ThemeMode? themeMode]) {
    _recipe = recipe ?? kDefaultInkRecipe;
    _themeMode = themeMode ?? ThemeMode.light;
  }
}
