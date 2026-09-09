import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每日观看时长记录（本地，不入 Gist、不跨设备，同 [HistoryStore] 介质）。
///
/// - 键格式：**本地日期** `yyyy-MM-dd`（如 `2026-09-08`），一天一个值（秒）。
///   跨日观看自动落到"观看发生的那天"（播放页每次 [record] 用当前本地日期）。
/// - 数据来源：播放页在**真实播放**（playing、非 seek/缓冲跳变）时按位置增量
///   累计秒数，约每 10s 批量 [record] 一次落盘（见 player_page 接入）。
/// - 持久化：shared_preferences 单 key JSON 对象 `{date: 秒}`；
///   保留近 [maxDays] 天（默认 400，覆盖热力图 53 周 = 371 天），
///   每次写盘裁剪更早的旧数据，避免无限增长。
/// - 损坏容错：解析失败 / 脏键 / 非正数一律跳过或视为空，不崩溃不影响播放。
///
/// 提供只读统计（基于内存表，先用 [ensureLoaded]）：[todaySeconds] /
/// [weekSeconds]（周一起算）/ [totalSeconds] / [activeDays]（有观看的天数）/
/// [longestStreakDays]（最长连续有观看的天数）。
///
/// 便于单测：日期用可注入的 [clock]（模拟跨日），纯函数独立成静态方法
/// （[dateKey]/[relativeIntensity]/[accumulateWatchMs]/[countStreak]）。
class WatchStats extends ChangeNotifier {
  WatchStats();

  /// 全局单例（播放页累计写入与统计页读取共用同一份）。
  static final WatchStats instance = WatchStats();

  /// 保留的最大天数（近 400 天；超出裁剪最早，保证 shared_preferences 不膨胀）。
  static const int maxDays = 400;

  /// shared_preferences 存储 key（JSON 对象 {yyyy-MM-dd: 观看秒}）。
  static const String storageKey = 'watch_stats:days';

  /// 单次 tick 位置增量阈值（毫秒）：0 < Δ ≤ 5000 视为正常播放连续前进；
  /// 更大 = seek/换集/断点续播跳变，不计观看（纯函数默认值，见
  /// [accumulateWatchMs]）。
  static const int maxTickDeltaMs = 5000;

  /// 当前日期来源（默认系统本地时间；测试注入固定时钟模拟跨日）。
  DateTime Function() clock = DateTime.now;

  Map<String, int> _days = {};
  bool _loaded = false;

  /// 写盘串行队列尾巴：record 高频调用时逐次排队，全量快照覆盖写，最终一致。
  Future<void> _writeTail = Future<void>.value();

  /// 内存表是否已从本地加载。
  bool get isLoaded => _loaded;

  /// 已加载数据的只读快照 {yyyy-MM-dd: 秒}（请先 await [ensureLoaded]）。
  Map<String, int> get days => Map.unmodifiable(_days);

  // -------------------------------------------------------------------------
  // 纯函数（独立可测）
  // -------------------------------------------------------------------------

  /// 本地日期 → `yyyy-MM-dd` 键。
  static String dateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// `yyyy-MM-dd` → 当日 0 点本地 DateTime；格式非法或非法日期
  /// （如 2026-02-30，Dart 会做进位归一）返回 null（脏数据跳过）。
  static DateTime? dateOfKey(String key) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(key);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    final dt = DateTime(y, mo, d);
    // DateTime 对越界日（如 2 月 30）会进位归一 → 回读不等说明是脏键
    if (dt.year != y || dt.month != mo || dt.day != d) return null;
    return dt;
  }

  /// 相对强度（纯函数，v2.17.16 相对配色用）：某日观看秒 / 窗口内最长单日
  /// 秒，截断到 [0,1]——0 = 无观看（或窗口内没有任何观看，[maxSeconds]<=0
  /// 视为 0，避免除零）；1 = 当天就是窗口内最长的一天。热力格按此连续
  /// 渐变着色（不再固定时间分档），图例/单测共用。
  static double relativeIntensity(int daySeconds, int maxSeconds) {
    if (maxSeconds <= 0 || daySeconds <= 0) return 0;
    final v = daySeconds / maxSeconds;
    return v > 1 ? 1 : v;
  }

  /// 累计观看毫秒的纯函数：输入每次 tick 的位置增量（ms），只累计
  /// `0 < Δ ≤ [maxDeltaMs]` 的增量（≤0 = 暂停/缓冲停住，> 阈值 = seek/跳变，
  /// 都不算真实观看）；返回应记的观看毫秒总和。播放页 _tick 接入与单测共用。
  static int accumulateWatchMs(
    List<int> deltas, {
    int maxDeltaMs = maxTickDeltaMs,
  }) {
    var total = 0;
    for (final d in deltas) {
      if (d > 0 && d <= maxDeltaMs) total += d;
    }
    return total;
  }

  /// 最长连续「有观看」的天数（纯函数）：把 {date: 秒} 的日期升序排好后数
  /// 连续不中断的段数，取最大；秒 ≤ 0 的键视为无观看。无任何观看记录返回 0。
  static int countStreak(Map<String, int> days) {
    if (days.isEmpty) return 0;
    final dates = <DateTime>[];
    for (final e in days.entries) {
      final d = dateOfKey(e.key);
      if (d != null && e.value > 0) dates.add(d);
    }
    if (dates.isEmpty) return 0;
    dates.sort();
    var best = 1;
    var run = 1;
    for (var i = 1; i < dates.length; i++) {
      final gap = dates[i].difference(dates[i - 1]).inDays;
      if (gap == 1) {
        run += 1;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    return best;
  }

  /// 保留近 [maxDays] 天（含 [now] 当天）的裁剪（纯函数）；脏键一并剔除。
  static Map<String, int> prune(
    Map<String, int> days, {
    int maxDays = WatchStats.maxDays,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final todayKey = dateKey(today);
    final floor =
        DateTime(today.year, today.month, today.day - (maxDays - 1));
    final floorKey = dateKey(floor);
    final out = <String, int>{};
    for (final e in days.entries) {
      final key = e.key;
      final d = dateOfKey(key);
      final v = e.value;
      // 键非法 / 秒数非正 / 早于保留窗口 → 丢弃
      if (d == null || v <= 0) continue;
      if (key.compareTo(floorKey) < 0) continue;
      if (key.compareTo(todayKey) > 0) continue; // 未来日期（时钟回拨等）丢弃
      out[key] = v;
    }
    return out;
  }

  /// 某天（本地）观看秒数；该天无记录返回 0。需先 [ensureLoaded]。
  int secondsOf(DateTime day) => _days[dateKey(day)] ?? 0;

  /// 今天（[clock]）观看秒数。
  int get todaySeconds {
    final today = clock();
    return _days[dateKey(today)] ?? 0;
  }

  /// 本周（周一起到今天的 [clock]）观看秒数。
  int get weekSeconds {
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    final monday = today.subtract(Duration(days: today.weekday - 1));
    var sum = 0;
    for (var d = monday;
        !d.isAfter(today);
        d = d.add(const Duration(days: 1))) {
      sum += _days[dateKey(d)] ?? 0;
    }
    return sum;
  }

  /// 累计观看秒数（全部保留记录）。
  int get totalSeconds {
    var sum = 0;
    for (final v in _days.values) {
      sum += v;
    }
    return sum;
  }

  /// 有观看记录的天数。
  int get activeDays => _days.length;

  /// 最长连续有观看的天数（streak；跨保留窗口边界的旧连续可能被 [maxDays]
  /// 截断，见类注释）。
  int get longestStreakDays => countStreak(_days);

  // -------------------------------------------------------------------------
  // 加载 / 写入
  // -------------------------------------------------------------------------

  /// 从 shared_preferences 加载（首次进入 App 后由统计页/播放页惰性触发）；
  /// 已加载过则直接返回。读取/解析失败视为空数据，不崩溃。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  /// 强制重新加载（供播放页首次记录前同步底层最新值 / 测试用）。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      Map<String, dynamic> parsed = const {};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          parsed = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      }
      final cleaned = <String, int>{};
      for (final e in parsed.entries) {
        final v = e.value is num ? (e.value as num).toInt() : 0;
        if (v > 0 && dateOfKey(e.key) != null) cleaned[e.key] = v;
      }
      final pruned = prune(cleaned);
      _days = pruned;
      // 解析/裁剪后有变化 → 回写一次，顺手清理损坏数据与过期键
      if (cleaned.length != pruned.length || cleaned.length != parsed.length) {
        await _persistNow();
      }
    } catch (_) {
      // 数据损坏 / 读取失败：视为空（不崩溃、不影响主流程）
      _days = {};
    }
    _loaded = true;
    notifyListeners();
  }

  /// 给某天累加观看秒数（默认当前本地日期，测试可传 [at] 或改 [clock]）。
  /// 秒数 ≤ 0 直接忽略。更新内存表后异步串行写盘（全量快照，最终一致）。
  Future<void> record(int seconds, {DateTime? at}) async {
    if (seconds <= 0) return;
    // 首次 record 前先加载底层（防止内存空表直接写盘把历史日期清掉）
    if (!_loaded) await load();
    final day = at ?? clock();
    final key = dateKey(day);
    _days[key] = (_days[key] ?? 0) + seconds;
    _pruneSelf();
    notifyListeners();
    // 排队写盘（serialize；失败静默，不影响播放主流程）
    _writeTail = _writeTail.then((_) => _persistNow()).catchError((_) {});
    await _writeTail;
  }

  /// 按 [maxDays] 裁剪内存表（只保留近 maxDays 天）。
  void _pruneSelf() {
    final pruned = prune(_days);
    if (pruned.length != _days.length) _days = pruned;
  }

  /// 实际写盘：把当前内存全量表序列化写入 shared_preferences。
  Future<void> _persistNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(_days));
    } catch (_) {
      // 写入失败（存储异常等）：静默跳过，下次 record 再试
    }
  }
}
