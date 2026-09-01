/// 应用内版本更新本地存储：上次检查时间（用于 24h 节流）。
///
/// 走 [SharedPreferences]，仅存一个 ISO8601 字符串键值。
library;

import 'package:shared_preferences/shared_preferences.dart';

class UpdateStorage {
  static const _kLastCheckAt = 'update:last_check_at';

  final SharedPreferences _prefs;

  UpdateStorage(this._prefs);

  Future<DateTime?> readLastCheckAt() async {
    final s = _prefs.getString(_kLastCheckAt);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  Future<void> writeLastCheckAt(DateTime t) async {
    await _prefs.setString(_kLastCheckAt, t.toIso8601String());
  }
}
