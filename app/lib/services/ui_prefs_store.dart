/// 「界面偏好」本地存储（v2.36.0 起）：底部提示条开关 [showTips]
/// （用户原话：「可以在设置里关掉底部的黑框提示」）+ v2.40.0 的**写操作总开关**
/// [writeActionsEnabled] 与**上次选的收藏夹** [favFolderId]。
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
/// ★ [showTips] **默认开**：关提示是"我想清静"的主动诉求，不该是默认预期；
/// 默认关会让用户觉得 App 坏了（点什么都没反馈）。
///
/// ★ [writeActionsEnabled] **默认关**（v2.40.0+）：见该字段的注释。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「界面偏好」存储（单例）。
class UiPrefsStore extends ChangeNotifier {
  /// 底部提示条开关的存储 key（bool；缺省/读失败 = true，默认开）。
  static const String showTipsKey = 'ui:show_tips';

  /// 写操作总开关的存储 key（bool；缺省/读失败 = false，**默认关**）。
  static const String writeActionsKey = 'ui:write_actions';

  /// 上次选的收藏夹 id 的存储 key（int；缺省/读失败 = null，没有"上次"）。
  static const String favFolderKey = 'ui:fav_folder_id';

  /// 全局单例（启动流程读、设置页写、`AppSnack` 每次弹提示前读）。
  static final UiPrefsStore instance = UiPrefsStore._();

  UiPrefsStore._();

  bool _showTips = true;
  bool _writeActionsEnabled = false;
  int? _favFolderId;
  bool _loaded = false;

  /// 是否允许弹「提示 / 成功 / 门禁」类底部提示条（默认 true）。
  ///
  /// ⚠️ **只管 info 类**：错误（[SnackKind.error]）与带撤销按钮的提示
  /// 一律不受它影响，判定集中在 `AppSnack.allows` 一处（关掉提示不该让失败
  /// 静默，也不该把"撤销"这个挽回入口一起关掉）。
  bool get showTips => _showTips;

  /// **写操作总开关**（v2.40.0+，默认 **false**）：点赞 / 投币 / 收藏三个
  /// 按钮是否出现。
  ///
  /// 为什么一个"能用的功能"要默认关：
  /// - 这三个动作**改的是用户真实的 B 站账号**（点赞进动态、收藏进收藏夹、
  ///   投币扣真硬币），而且**这个 App 在此之前的全部历史行为都是只读**——
  ///   用户装它就是为了"安静地看白名单视频"，默认多出一排能改账号状态的按钮
  ///   与该预期相悖；
  /// - 误触的代价不对称：多按一下「点赞」会通知到关注我的人，多按一下
  ///   「投币」直接扣硬币且 B 站**不支持撤回**。默认关 = 让"想写"的人自己
  ///   开一次闸，比让所有人默认承担误触风险合理；
  /// - 开关本身就是一道**知情确认**：开启前设置页那段说明写清了三个动作各
  ///   自不可逆在哪（见 manage_panel 的「写操作」分区）。
  bool get writeActionsEnabled => _writeActionsEnabled;

  /// 上次收藏到的收藏夹 id（null = 还没有"上次"）。
  ///
  /// 存在本地 prefs 而**不写进 Gist 配置**：Gist 里放的是白名单/合集这类
  /// 跨设备同步的内容；"我上次把视频收进哪个夹"是本机操作习惯，跨设备同步
  /// 反而可能指到一个别的账号的夹 id 上。
  int? get favFolderId => _favFolderId;

  /// 启动时读一次；幂等（重复调用只在首次真正读盘，之后直接返回）。
  ///
  /// 读失败 → 回默认（提示开 / 写操作关 / 无上次收藏夹），不抛。三个值里
  /// 只要有一个与当前不同就发通知。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    var showTips = true;
    var writeActions = false;
    int? favFolder;
    try {
      final prefs = await SharedPreferences.getInstance();
      showTips = prefs.getBool(showTipsKey) ?? true;
      writeActions = prefs.getBool(writeActionsKey) ?? false;
      final fav = prefs.getInt(favFolderKey);
      favFolder = (fav != null && fav > 0) ? fav : null;
    } catch (_) {
      // 存储异常：按默认值启动（提示开 / 写操作关 / 无上次收藏夹）
      showTips = true;
      writeActions = false;
      favFolder = null;
    }
    _loaded = true;
    if (showTips == _showTips &&
        writeActions == _writeActionsEnabled &&
        favFolder == _favFolderId) {
      return;
    }
    _showTips = showTips;
    _writeActionsEnabled = writeActions;
    _favFolderId = favFolder;
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

  /// 写操作总开关：语义与 [setShowTips] 完全一致（立即生效 + 静默持久化）。
  Future<void> setWriteActionsEnabled(bool value) async {
    if (_writeActionsEnabled != value) {
      _writeActionsEnabled = value;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(writeActionsKey, value);
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 记住"上次收进了哪个夹"（写失败静默，下次仍按没有"上次"处理）。
  Future<void> setFavFolderId(int? value) async {
    final next = (value != null && value > 0) ? value : null;
    if (_favFolderId != next) {
      _favFolderId = next;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next == null) {
        await prefs.remove(favFolderKey);
      } else {
        await prefs.setInt(favFolderKey, next);
      }
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 测试用：重置内存态（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest({
    bool? showTips,
    bool writeActionsEnabled = false,
    int? favFolderId,
    bool loaded = false,
  }) {
    _showTips = showTips ?? true;
    _writeActionsEnabled = writeActionsEnabled;
    _favFolderId = favFolderId;
    _loaded = loaded;
  }
}
