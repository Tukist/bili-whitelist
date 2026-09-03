import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/danmaku_settings.dart';

/// 弹幕显示设置存储（单例）：shared_preferences 存单 key JSON。
///
/// 与 [HistoryStore] 同风格：读/写失败静默降级（返回默认设置 / 跳过写入），
/// 数据损坏视为默认设置，不崩溃、不影响播放主流程。
class DanmakuSettingsStore {
  static const String _key = 'danmaku:settings';

  static final DanmakuSettingsStore instance = DanmakuSettingsStore._();

  DanmakuSettingsStore._();

  /// 读取弹幕设置；无记录 / JSON 损坏 / 读取异常 → 默认设置。
  Future<DanmakuSettings> get() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const DanmakuSettings();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const DanmakuSettings();
      }
      return DanmakuSettings.fromJson(decoded);
    } catch (_) {
      // 存储异常 / 数据损坏：回退默认，不抛
      return const DanmakuSettings();
    }
  }

  /// 保存弹幕设置（fire-and-forget：写入失败静默，不影响调用方）。
  Future<void> save(DanmakuSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(settings.toJson()));
    } catch (_) {
      // 写入失败静默（下次进播放页读不到 = 用默认，可接受）
    }
  }
}
