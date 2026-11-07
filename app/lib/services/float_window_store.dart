import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/float_window_prefs.dart';

/// 应用内浮动小窗的窗口状态存储（v2.65.0；单例，shared_preferences 存单 key JSON）。
///
/// 与 [DanmakuSettingsStore] / `LastEpisodeStore` 同风格：读/写失败静默降级
/// （读失败 = 默认窗口，写失败 = 本次内存生效、下次启动回到上次成功保存的值），
/// 数据损坏视为默认设置，不崩、不影响播放主流程。
///
/// 只存一件事：**窗口长什么样**（大小 / 位置 / 锁定）。"现在是不是小窗态"
/// 不存——每次进播放页都从大屏开始，用户点了才进小窗（免得一进页面画面就
/// 缩成一块，用户还得先找还原按钮）。
class FloatWindowStore {
  /// shared_preferences 的 key。`player:` 前缀与 `playback_progress:*` 同一族
  /// （都是播放页自己的运行时状态），与 `ui:`（用户偏好开关）区分开。
  static const String key = 'player:float_window';

  static final FloatWindowStore instance = FloatWindowStore._();

  FloatWindowStore._();

  /// 读取窗口状态；无记录 / JSON 损坏 / 读取异常 → 默认窗口（40% 宽、贴右贴顶、
  /// 未锁定）。
  Future<FloatWindowPrefs> get() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return const FloatWindowPrefs();
      return FloatWindowPrefs.fromJson(jsonDecode(raw));
    } catch (_) {
      // 存储异常 / JSON 损坏：回退默认，不抛
      return const FloatWindowPrefs();
    }
  }

  /// 保存窗口状态（fire-and-forget：写入失败静默，不影响调用方）。
  ///
  /// 调用时机只有三个：拖动结束 / 缩放结束 / 锁定切换——**不在拖动过程中**
  /// 每帧写盘（一次拖动几十次 setState，写盘一次就够了）。
  Future<void> save(FloatWindowPrefs prefs) async {
    try {
      final prefsStore = await SharedPreferences.getInstance();
      await prefsStore.setString(key, jsonEncode(prefs.toJson()));
    } catch (_) {
      // 写入失败静默（下次进小窗读不到 = 用默认，可接受）
    }
  }
}
