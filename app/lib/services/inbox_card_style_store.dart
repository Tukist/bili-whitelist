import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/inbox_card_styles.dart';

/// 信箱**卡片样式**存储（单例）：shared_preferences 存**单个风格 id**
/// （key = [storageKey]），不存排版细节本身——排版以
/// `widgets/inbox_card_styles.dart` 的 [kInboxCardStyles] 为准，
/// 以后调整某个风格的排版不需要迁移已存数据。
///
/// 与 [ThemeStore]（配色）/ [SearchHistoryStore] 同风格：读/写失败静默降级
/// （读失败 = 默认风格，写失败 = 本次内存生效但下次启动回退），
/// id 不认识（旧版本残留 / 手工改坏）也回退默认风格，不崩溃、不影响启动。
///
/// 使用时当 [ChangeNotifier] 监听（信箱页用 `ListenableBuilder` 重建卡片栈，
/// 设置页用它刷新按钮文案与勾选态）。默认风格 = [kDefaultInboxCardStyle]
/// （`classic` 经典满幅）。
class InboxCardStyleStore extends ChangeNotifier {
  /// shared_preferences 存储 key（值为风格 id，如 `polaroid`）。
  static const String storageKey = 'ui:inbox_card_style_id';

  /// 全局单例。
  static final InboxCardStyleStore instance = InboxCardStyleStore._();

  InboxCardStyleStore._();

  InboxCardStyle _style = kDefaultInboxCardStyle;

  /// 当前卡片风格。
  InboxCardStyle get style => _style;

  /// 当前风格 id。
  String get styleId => _style.id;

  /// 启动时读一次已保存的风格；无记录 / id 不认识 / 读取异常 → 默认风格。
  ///
  /// 读到的风格与当前一致时不发通知（避免首帧后无谓重建）。
  Future<void> ensureLoaded() async {
    var next = kDefaultInboxCardStyle;
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(storageKey);
      if (id != null && id.isNotEmpty) {
        next = inboxCardStyleById(id);
      }
    } catch (_) {
      // 存储异常：按默认风格启动，不抛
      next = kDefaultInboxCardStyle;
    }
    if (next.id == _style.id) return;
    _style = next;
    notifyListeners();
  }

  /// 切换风格：立即生效（`notifyListeners` → 信箱页重建卡片栈）并持久化；
  /// id 不认识时回退默认风格（与 [ensureLoaded] 一致）。
  /// 写失败静默（本次已生效，下次启动回到上次成功保存的值）。
  Future<void> select(String styleId) async {
    final next = inboxCardStyleById(styleId);
    _style = next;
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
  void resetForTest([InboxCardStyle? style]) {
    _style = style ?? kDefaultInboxCardStyle;
  }
}
