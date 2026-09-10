// 配色主题存储（P1.5，services/theme_store.dart）单测：
// - 默认配方 = klein_clay（P1 观感）
// - select 切换 + notifyListeners + 持久化（shared_preferences）
// - ensureLoaded 读回已存选择；无记录 / 未知 id / 存储异常 → 默认
// - select 未知 id → 回退默认（不写坏值）
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/theme_store.dart';
import 'package:bili_whitelist_app/theme/ink_recipes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 单例跨用例串味：每个用例前把内存态重置回默认
    ThemeStore.instance.resetForTest();
  });

  test('默认 = klein_clay（主墨 #002FA7 / 点缀 #C65F38）', () {
    expect(ThemeStore.instance.recipe.id, 'klein_clay');
    expect(ThemeStore.instance.recipe, kDefaultInkRecipe);
  });

  test('select：切换 + 通知监听者 + 写入 shared_preferences', () async {
    final store = ThemeStore.instance;
    var notified = 0;
    void listener() => notified++;
    store.addListener(listener);
    addTearDown(() => store.removeListener(listener));

    await store.select('cobalt_terracotta');

    expect(store.recipe.id, 'cobalt_terracotta');
    expect(store.recipe, inkRecipeById('cobalt_terracotta'));
    expect(notified, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeStore.storageKey), 'cobalt_terracotta');
  });

  test('ensureLoaded：读回上次保存的配方（模拟重启）', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ThemeStore.storageKey, 'tangerine_slate_blue');
    ThemeStore.instance.resetForTest(); // 内存态清空 = 刚启动

    await ThemeStore.instance.ensureLoaded();

    expect(ThemeStore.instance.recipe.id, 'tangerine_slate_blue');
  });

  test('ensureLoaded：无记录 → 默认，不通知（省一次无谓重建）', () async {
    final store = ThemeStore.instance;
    var notified = 0;
    void listener() => notified++;
    store.addListener(listener);
    addTearDown(() => store.removeListener(listener));

    await store.ensureLoaded();

    expect(store.recipe.id, 'klein_clay');
    expect(notified, 0);
  });

  test('ensureLoaded：id 不认识（旧版残留 / 数据损坏）→ 回退默认', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(ThemeStore.storageKey, 'no_such_recipe');
    ThemeStore.instance.resetForTest(inkRecipeById('cyan_brick_red'));

    await ThemeStore.instance.ensureLoaded();

    expect(ThemeStore.instance.recipe.id, 'klein_clay');
  });

  test('select：id 不认识 → 回退默认，且不会把坏 id 写进存储', () async {
    final store = ThemeStore.instance;
    await store.select('no_such_recipe');

    expect(store.recipe.id, 'klein_clay');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeStore.storageKey), 'klein_clay');
  });

  test('select 连续切换：以最后一次为准（持久化同步）', () async {
    final store = ThemeStore.instance;
    await store.select('mint_green_warm_charcoal');
    await store.select('charcoal_signal_red');

    expect(store.recipe.id, 'charcoal_signal_red');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(ThemeStore.storageKey), 'charcoal_signal_red');
  });
}
