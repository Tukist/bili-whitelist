import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 播放进度记忆：按 (bvid, pageIndex) 分别记住上次播放位置（毫秒）。
/// 纯本地存储（shared_preferences），**不入 Gist、跨设备不同步**——符合预期。
///
/// 存储方案：每个 (bvid, pageIndex) 一个独立 key（前缀 `playback_progress:`，
/// 值形如 `playback_progress:BV1xxx_0`），value 为 JSON 字符串
/// `{"positionMs": 12345}`。独立 key 使各视频读写互不影响、无需整表重写；
/// JSON 值便于将来扩展字段（如保存时间、倍速）。
///
/// 用法：
/// ```dart
/// final store = await PlaybackProgress.load();  // 每次进入播放页加载一次
/// final ms = store.getProgress(bvid, pageIndex);
/// await store.saveProgress(bvid, pageIndex, 12345);
/// await store.clearProgress(bvid, pageIndex);   // 观看完成时调用
/// ```
class PlaybackProgress {
  static const String _prefix = 'playback_progress:';

  /// 每次进入播放页时加载一次（获取 SharedPreferences 实例）。
  static Future<PlaybackProgress> load() async {
    final prefs = await SharedPreferences.getInstance();
    return PlaybackProgress._(prefs);
  }

  final SharedPreferences _prefs;

  PlaybackProgress._(this._prefs);

  /// key：`playback_progress:<bvid>_<pageIndex>`。
  /// B 站 bvid 恒为 `BV1...` 格式（不含下划线），用 `_` 连接无歧义。
  String _key(String bvid, int pageIndex) => '$_prefix${bvid}_$pageIndex';

  /// 读取保存的播放位置（毫秒）；无记忆 / 数据损坏返回 null。
  int? getProgress(String bvid, int pageIndex) {
    final raw = _prefs.getString(_key(bvid, pageIndex));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return (map['positionMs'] as num?)?.toInt();
    } catch (_) {
      // 数据损坏视为无记忆（不崩溃、不影响播放）
      return null;
    }
  }

  /// 保存播放位置（毫秒）。
  Future<void> saveProgress(String bvid, int pageIndex, int ms) async {
    await _prefs.setString(
        _key(bvid, pageIndex), jsonEncode({'positionMs': ms}));
  }

  /// 清除播放位置（观看完成时调用，下次从头播）。
  Future<void> clearProgress(String bvid, int pageIndex) async {
    await _prefs.remove(_key(bvid, pageIndex));
  }
}
