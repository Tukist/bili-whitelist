/// 「界面偏好」本地存储（v2.36.0）：目前只有一项 —— 底部提示条开关
/// [showTips]（用户原话：「可以在设置里关掉底部的黑框提示」）。
///
/// 为什么单独开一个 store，而不是塞进 [UiCopyStore] 或 [DanmakuSettingsStore]：
/// - [UiCopyStore] 存的是「一句话被改成了什么」的**文案覆盖表**（key = 文案 id，
///   值 = 用户改的字符串），语义是"改写内容"；
/// - [DanmakuSettingsStore] 的值对象是**弹幕设置**（字号/速度/透明度…）；
/// - 这里是"界面**行为**开关"，值与上面两者都不同类 —— 混进去会让那两个
///   store 的 `resetForTest` / 序列化语义变得含糊（见 `inbox_card_style_store.dart`
///   的同类理由：单值 store 只存一个语义）。
///
/// 读写风格沿用 [ThemeStore] / [InboxCardStyleStore] / [ClipboardLinkStore]：
/// `ensureLoaded` 幂等、读/写失败一律静默降级（读失败 = 默认值，写失败 = 本次
/// 内存生效、下次启动回到上次成功保存的值），key 一律 `ui:` 前缀，
/// 不崩、不影响启动。
///
/// ★ **默认开**：关提示是"我想清静"的主动诉求，不该是默认预期；默认关会让
/// 用户觉得 App 坏了（点什么都没反馈）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「界面偏好」存储（单例）。
class UiPrefsStore extends ChangeNotifier {
  /// 底部提示条开关的存储 key（bool；缺省/读失败 = true，默认开）。
  static const String showTipsKey = 'ui:show_tips';

  /// 全局单例（启动流程读、设置页写、`AppSnack` 每次弹提示前读）。
  static final UiPrefsStore instance = UiPrefsStore._();

  UiPrefsStore._();

  bool _showTips = true;
  bool _loaded = false;

  /// 是否允许弹「提示 / 成功 / 门禁」类底部提示条（默认 true）。
  ///
  /// ⚠️ **只管 info 类**：错误（[SnackKind.error]）与带撤销按钮的提示
  /// 一律不受它影响，判定集中在 `AppSnack.allows` 一处（关掉提示不该让失败
  /// 静默，也不该把"撤销"这个挽回入口一起关掉）。
  bool get showTips => _showTips;

  /// 启动时读一次；幂等（重复调用只在首次真正读盘，之后直接返回）。
  ///
  /// 读失败 → 回默认（开），不抛。读到与当前一致时不发通知。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    var showTips = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      showTips = prefs.getBool(showTipsKey) ?? true;
    } catch (_) {
      // 存储异常：按默认值启动（开）
      showTips = true;
    }
    _loaded = true;
    if (showTips == _showTips) return;
    _showTips = showTips;
    notifyListeners();
  }

  /// 开关：立即生效（`notifyListeners` → 设置页开关跟着走）并持久化。
  /// 写失败静默（本次已生效，下次启动回到上次成功保存的值）。
  Future<void> setShowTips(bool value) async {
    if (_showTips != value) {
      _showTips = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(showTipsKey, value);
    } catch (_) {
      // 写入失败静默（本次已生效，下次启动回到上次成功保存的值）
    }
  }

  /// 测试用：重置内存态（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest({bool? showTips, bool loaded = false}) {
    _showTips = showTips ?? true;
    _loaded = loaded;
  }
}
