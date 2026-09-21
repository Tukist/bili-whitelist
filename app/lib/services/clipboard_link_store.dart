/// 冷启动「读剪贴板」相关设置的本地存储（v2.35.0）。
///
/// 两个 key 分开存、互不影响：
/// - [enabledKey]：开关（**默认开**——用户明确要"进软件就播我复制的那个"）。
///   关掉后冷启动**连剪贴板都不读**（不读 = 不存在，最干净）。
/// - [lastKeyStorageKey]：上一次已经处理过的**链接原文**（见
///   [ClipboardLinkStore.lastHandledKey]），保证"同一个链接只跳一次"。
///
/// 读写风格沿用 [ThemeStore] / [InboxCardStyleStore]：`ensureLoaded` 幂等、
/// 读/写失败一律静默降级（读失败 = 默认值，写失败 = 本次内存生效、下次启动
/// 回到上次成功保存的值），不崩、不影响启动。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 冷启动剪贴板开播的本地存储（单例）。
class ClipboardLinkStore extends ChangeNotifier {
  /// 开关存储 key（bool；缺省/读失败 = true，默认开）。
  static const String enabledKey = 'ui:clipboard_open_enabled';

  /// 上次处理过的链接原文存储 key（string）。
  static const String lastKeyStorageKey = 'ui:clipboard_open_last_url';

  /// 全局单例（启动流程读、设置页写）。
  static final ClipboardLinkStore instance = ClipboardLinkStore._();

  ClipboardLinkStore._();

  bool _enabled = true;
  String _lastKey = '';
  bool _loaded = false;

  /// 开关是否打开（默认 true）。
  bool get enabled => _enabled;

  /// 上一次已经开播过的链接原文（空串 = 还没处理过任何链接）。
  ///
  /// 存**链接原文**而不是只有 bvid：用户没重新复制过内容时，剪贴板里躺着的是
  /// 同一段字符串——这正是"每次开 App 都跳同一个视频"的那种烦人情形；而他
  /// 重新复制了一次（哪怕还是同一个视频、换了分享来源）说明这次是有意为之，
  /// 该跳就跳。
  String get lastHandledKey => _lastKey;

  /// 启动时读一次；幂等（重复调用只在首次真正读盘，之后直接返回）。
  ///
  /// 读失败 → 一律回默认（开关开、无记录），不抛。读到与当前一致时不发通知。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    var enabled = true;
    var last = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(enabledKey) ?? true;
      last = prefs.getString(lastKeyStorageKey) ?? '';
    } catch (_) {
      // 存储异常：按默认值启动
      enabled = true;
      last = '';
    }
    _loaded = true;
    if (enabled == _enabled && last == _lastKey) return;
    _enabled = enabled;
    _lastKey = last;
    notifyListeners();
  }

  /// 开关：立即生效（`notifyListeners` → 设置页开关跟着走）并持久化。
  Future<void> setEnabled(bool value) async {
    if (_enabled != value) {
      _enabled = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, value);
    } catch (_) {
      // 写入失败静默（本次已生效，下次启动回到上次成功保存的值）
    }
  }

  /// 记下"这条链接已经处理过"。写失败静默（本次进程内仍然生效）。
  Future<void> markHandled(String key) async {
    if (key.isEmpty) return;
    _lastKey = key;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(lastKeyStorageKey, key);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 测试用：重置内存态（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest({bool? enabled, String? lastHandledKey, bool loaded = false}) {
    _enabled = enabled ?? true;
    _lastKey = lastHandledKey ?? '';
    _loaded = loaded;
  }
}
