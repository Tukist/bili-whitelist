import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'inbox_heat.dart';

/// 信箱**排序偏好**存储（单例，v2.64.0+）：热度榜 / 最新。
///
/// 只存**一个枚举 id**（`heat` / `latest`），不存排序结果 —— 排序是纯函数
/// （`inbox_heat.dart`），以后调整公式 / 参数不需要迁移已存数据。
///
/// 读写风格沿用 [ThemeStore] / [InboxCardStyleStore] / [UiPrefsStore]：
/// `ensureLoaded` 幂等、读/写失败一律静默降级（读失败 = 默认 [InboxSortMode.heat]，
/// 写失败 = 本次内存生效、下次启动回到上次成功保存的值），id 不认识
/// （旧版本残留 / 手工改坏）也回退默认，不崩、不影响启动。
///
/// ★ **默认热度**：用户要的就是"把推荐卡牌做成热度榜"，首次启动没有记录时
/// 必须已经是热度序；「最新」是给"我就想看刚发的"那部分人的退路。
class InboxSortStore extends ChangeNotifier {
  /// shared_preferences 存储 key（值为排序 id，如 `latest`）。
  static const String storageKey = 'ui:inbox_sort_mode';

  /// 全局单例。
  static final InboxSortStore instance = InboxSortStore._();

  InboxSortStore._();

  InboxSortMode _mode = InboxSortMode.heat;

  /// 当前排序模式（默认 [InboxSortMode.heat]）。
  InboxSortMode get mode => _mode;

  /// 当前模式的存储 id（`heat` / `latest`）。
  String get modeId => _mode.name;

  /// 启动 / 首次读队列前读一次已保存的模式；无记录 / 不认识 / 读取异常 → 默认。
  ///
  /// 读到的与当前一致时不发通知（避免首帧后无谓重建）。幂等：真机上页面
  /// 每次进页都会调一次，重复调用只是再读一遍盘。
  Future<void> ensureLoaded() async {
    var next = InboxSortMode.heat;
    try {
      final prefs = await SharedPreferences.getInstance();
      next = inboxSortModeById(prefs.getString(storageKey));
    } catch (_) {
      // 存储异常：按默认（热度）启动，不抛
      next = InboxSortMode.heat;
    }
    if (next == _mode) return;
    _mode = next;
    notifyListeners();
  }

  /// 切换模式：立即生效（`notifyListeners`）+ 落盘；写失败静默。
  Future<void> select(InboxSortMode mode) async {
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, mode.name);
    } catch (_) {
      // 写入失败静默（本次已生效，下次启动回到上次成功保存的值）
    }
  }

  /// 测试用：把内存态重置回去（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest([InboxSortMode mode = InboxSortMode.heat]) {
    _mode = mode;
  }
}
