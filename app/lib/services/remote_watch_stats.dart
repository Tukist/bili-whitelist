import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'watch_stats.dart';

/// 电脑端（B 站账号历史推算）的每日观看时长（v2.66.0，本地，不入 Gist）。
///
/// ## 为什么是"估算"而不是"统计"
/// B 站**没有**"某天看了多久"的接口。我们能拿到的只有账号历史里每条视频的
/// `progress`（上次播放到第几秒）与 `duration`（总时长），所以一条历史最多只能
/// 说明「他在那次观看里大约推进了 `min(progress, duration)` 秒」：
/// - 拖动进度条到后面再退出 → `progress` 虚高 → **偏大**；
/// - 反复看同一个视频 → B 站历史只留最近一次 → **偏小**；
/// - 同步只看最近 3 页 × 30 条 → 更早的观看**覆盖不到**。
/// 这三条是硬约束，UI 文案必须如实写"估算"，不能包装成精确统计。
///
/// ## 与 [WatchStats] 的关系（两个数**分开存**）
/// - [WatchStats] 存**本机实测**（播放页按真实播放秒数累计，见 player_page）；
/// - 本 store 只存**电脑端估算**，一天一个值；
/// - 热力图/每日详情要的是**两者之和**，由 [mergeDailySeconds] 现算，
///   不落盘"和"——和是派生值，落盘就多一份会漂移的真相。
///
/// ## 幂等（关键）
/// 同一条历史每次同步都会再拿到一次。若直接累加，同步 N 次时长就变 N 倍。
/// 因此给每条历史一个幂等键 `bvid|pageIndex|viewAtSec`：键已存在 → 跳过。
/// 键集合与天数表都落 shared_preferences，**跨会话（重启 App）同样幂等**。
///
/// 键集合有容量上限 [maxSeenKeys]（按写入顺序裁剪，**保留前部**；同步是按
/// "新 → 旧"喂入的，所以前部就是最近的）：
/// - 一次同步最多 90 条，正常用户远填不满；
/// - 万一被裁掉，某条很旧的历史再被同步到会被**重新计入一次**。这是可接受的
///   取舍：被裁掉的键对应的是 2000 条之前的历史，早已掉出同步窗口（最近 90
///   条），现实里几乎不会再出现；宁可如此，也不让 prefs 无上限膨胀。
///
/// ## 存储
/// 单 key `pc_watch_stats:state`（**一次原子写**，避免"天数写了、幂等键还没写"
/// 的撕裂导致重复计入）：
/// ```json
/// {"days": {"2026-09-08": 642}, "seen": ["BV1|0|1700000000"]}
/// ```
/// 天数保留近 [maxDays] 天，幂等键保留最近 [maxSeenKeys] 个；
/// 解析失败 / 脏键 / 非正数一律跳过，不崩溃。
class RemoteWatchStats extends ChangeNotifier {
  RemoteWatchStats();

  /// 全局单例（同步写入与统计页读取共用同一份）。
  static final RemoteWatchStats instance = RemoteWatchStats();

  /// 天数表保留窗口（与 [WatchStats.maxDays] 同口径：覆盖热力图 53 周）。
  static const int maxDays = WatchStats.maxDays;

  /// 幂等键上限（裁剪策略见类注释）。
  static const int maxSeenKeys = 2000;

  /// 存储 key（JSON 对象：`{"days": {...}, "seen": [...]}`）。
  static const String storageKey = 'pc_watch_stats:state';

  /// 当前日期来源（默认系统本地时间；测试注入固定时钟）。
  DateTime Function() clock = DateTime.now;

  Map<String, int> _days = {};
  List<String> _seen = const [];
  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// 只读快照（请先 await [ensureLoaded]）。
  Map<String, int> get days => Map.unmodifiable(_days);

  /// 已记录的幂等键（最近的在前；只读快照，测试用）。
  List<String> get seenKeys => List.unmodifiable(_seen);

  int get totalSeconds {
    var sum = 0;
    for (final v in _days.values) {
      sum += v;
    }
    return sum;
  }

  /// 某天（本地）的电脑端估算秒数；无记录 = 0。
  int secondsOf(DateTime day) => _days[WatchStats.dateKey(day)] ?? 0;

  /// 按 `yyyy-MM-dd` 键取（热力图格子用）。
  int secondsOfKey(String key) => _days[key] ?? 0;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  /// 从 shared_preferences 读天数表 + 幂等键；失败视为空（不崩溃）。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      Map<String, dynamic> state = const {};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          state = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      }
      _days = pruneDays(_readDays(state['days']), now: clock());
      _seen = trimSeenKeys(_readSeen(state['seen']));
    } catch (_) {
      _days = {};
      _seen = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// 写入一批估算样本（幂等：键已存在的不再累加）。返回本次**新增**的秒数。
  ///
  /// 失败静默返回 0：电脑端时长是锦上添花，不该让同步整体看起来失败。
  ///
  /// 落盘用**直接 await**（不排写队列）：唯一的写入者是
  /// `BiliHistorySyncService.sync`，而它被历史页的 `_syncing` 闸门挡住并发；
  /// 内存表先改完再落盘，真出现并发写也只会"后写的快照覆盖前一次"，不会丢已计入
  /// 的秒数（快照取的是当时的全量内存表）。
  Future<int> recordAll(Iterable<RemoteWatchSample> samples) async {
    if (!_loaded) await load();
    final seen = _seen.toSet();
    final fresh = <String>[];
    var added = 0;
    for (final s in samples) {
      final key = s.idempotencyKey;
      if (seen.contains(key)) continue; // 已计过（跨会话同样幂等）
      seen.add(key);
      fresh.add(key);
      _days[s.dayKey] = (_days[s.dayKey] ?? 0) + s.seconds;
      added += s.seconds;
    }
    if (fresh.isEmpty) return 0;
    // 新键在前；总量按 [maxSeenKeys] 裁剪，天数表按 [maxDays] 裁剪
    _seen = trimSeenKeys([...fresh, ..._seen]);
    _days = pruneDays(_days, now: clock());
    notifyListeners();
    await _persistNow();
    return added;
  }

  /// 清空（测试 / 用户清数据用；界面暂无入口）。
  Future<void> clear() async {
    _days = {};
    _seen = const [];
    _loaded = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {
      // 清空失败静默
    }
  }

  Future<void> _persistNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode({'days': _days, 'seen': _seen}),
      );
    } catch (_) {
      // 写失败静默：下次 recordAll 再试
    }
  }

  /// `days` 段解析（脏类型 / 非法日期 / 非正数 → 跳过）。
  Map<String, int> _readDays(Object? raw) {
    try {
      if (raw is! Map) return const {};
      final out = <String, int>{};
      raw.forEach((k, v) {
        final key = k.toString();
        final seconds = v is num ? v.toInt() : 0;
        if (seconds > 0 && WatchStats.dateOfKey(key) != null) {
          out[key] = seconds;
        }
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// `seen` 段解析（非数组 / 非字符串元素 / 空串 → 跳过）。
  List<String> _readSeen(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

/// 一条可计入的电脑端观看样本（纯数据；构造后不再改）。
@immutable
class RemoteWatchSample {
  final String bvid;

  /// 分 P 下标（与 [HistoryEntry.pageIndex] 同口径）。
  final int pageIndex;

  /// 观看时刻（秒级 Unix 时间戳，来自历史项的 `view_at`）。
  final int viewAtSec;

  /// 本次计入的估算秒数（`clamp(progress, 0, duration)`，恒 > 0）。
  final int seconds;

  const RemoteWatchSample({
    required this.bvid,
    required this.pageIndex,
    required this.viewAtSec,
    required this.seconds,
  });

  /// 幂等键：同一条历史反复同步只认第一次。
  String get idempotencyKey => '$bvid|$pageIndex|$viewAtSec';

  /// 观看时刻（**本地时区**：跨零点按本机自然日归日）。
  DateTime get viewedAt =>
      DateTime.fromMillisecondsSinceEpoch(viewAtSec * 1000);

  /// 归日键 `yyyy-MM-dd`（本机时区自然日）。
  String get dayKey => WatchStats.dateKey(viewedAt);
}

/// 单条历史的估算秒数（纯函数）：`clamp(progress, 0, duration)`。
///
/// `progress <= 0`（没进度）或 `duration <= 0`（总时长未知）→ 0 = **不编数**。
/// `progress > duration`（脏数据 / 播放器越界）→ 取 `duration`。
int estimateRemoteWatchSeconds({
  required int progressSec,
  required int durationSec,
}) {
  if (progressSec <= 0 || durationSec <= 0) return 0;
  return progressSec > durationSec ? durationSec : progressSec;
}

/// 远程条目 → 分 P 下标、以及"这次同步能计入哪些电脑端估算样本"的实现在
/// `bili_history_api.dart`（那边才认识 `RemoteHistoryItem`；本文件只管存储与
/// 纯算术，避免两个 service 互相 import 成环）。

/// 本机实测 + 电脑端估算 → 每日总值（纯函数；热力图/概览共用）。
///
/// 只为 > 0 的秒数保留键；两个表都空 → 空表。**不落盘**这个和：它是派生值。
Map<String, int> mergeDailySeconds(
  Map<String, int> local,
  Map<String, int> remote,
) {
  final out = <String, int>{};
  local.forEach((k, v) {
    if (v > 0) out[k] = v;
  });
  remote.forEach((k, v) {
    if (v <= 0) return;
    out[k] = (out[k] ?? 0) + v;
  });
  return out;
}

/// 保留近 [maxDays] 天（纯函数；脏键、非正数、未来日期丢弃）。
Map<String, int> pruneDays(
  Map<String, int> days, {
  int maxDays = RemoteWatchStats.maxDays,
  DateTime? now,
}) {
  final today = now ?? DateTime.now();
  final todayKey = WatchStats.dateKey(today);
  final floor = DateTime(today.year, today.month, today.day - (maxDays - 1));
  final floorKey = WatchStats.dateKey(floor);
  final out = <String, int>{};
  days.forEach((key, v) {
    if (v <= 0 || WatchStats.dateOfKey(key) == null) return;
    if (key.compareTo(floorKey) < 0) return;
    if (key.compareTo(todayKey) > 0) return; // 未来（时钟回拨）丢弃
    out[key] = v;
  });
  return out;
}

/// 幂等键裁剪（纯函数）：去重、保留最近的 [maxKeys] 个（顺序即"新 → 旧"）。
List<String> trimSeenKeys(
  List<String> keys, {
  int maxKeys = RemoteWatchStats.maxSeenKeys,
}) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in keys) {
    final k = raw.trim();
    if (k.isEmpty) continue;
    if (!seen.add(k)) continue;
    out.add(k);
    if (out.length >= maxKeys) break;
  }
  return out;
}
