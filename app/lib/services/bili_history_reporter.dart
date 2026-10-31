import 'package:flutter/foundation.dart';

import '../api/bilibili_api.dart';

/// 播放进度 → B 站账号历史的上报器（v2.57.0+，**写方向**）。
///
/// ## 为什么单独成类而不是散在播放页
/// 播放页 1 万多行，这里要的三件事（节流、失败退避、连续失败后停手）都是
/// **状态机**，写进页面里就只能靠 pump 一个假播放器来测。抽出来后：
/// 注入假时钟 + 假 sender 就能把"开关关着零请求""每 60s 一次""失败退避后
/// 停手"这些逐条钉住（见 `test/history_write_reporter_test.dart`）。
///
/// ## 纪律（照 [UiPrefsStore.writeActionsEnabled] 那套）
/// 1. **开关关着 → 一个请求都不发**（连"要不要发"的判定都不做网络动作，
///    调用方负责在关着时连 aid 都不去取——见 player_page 的
///    `_reportHistoryProgress`）；
/// 2. **失败一律静默**：只打日志，不弹窗、不抛、不影响播放；
/// 3. **失败越多越慢，连续失败就停手**：这是"不刷接口、不招风控"的硬要求。
///    风控（-412）与未登录（-101）第一次就停手——继续发只会更糟。
class BiliHistoryReporter {
  /// 真正发请求的那一步（真实实现 = [BiliApi.reportHistory]）。
  final Future<void> Function({
    required int aid,
    required int cid,
    required int progress,
  }) send;

  /// 写历史总开关（每次判定都现读，用户在设置里一关立刻生效）。
  final bool Function() enabled;

  final DateTime Function() _now;

  /// 播放中两次上报的最小间隔（默认 60s）。
  ///
  /// 为什么是 60s：B 站网页端心跳是 15s 一次，但那是浏览器播放器的一部分；
  /// 本 App 的历史只需"大致停在哪儿"，60s 粒度已经够用户从历史卡续播。
  /// 间隔越大，一次播放产生的请求越少（风控面越小）。
  final Duration minInterval;

  /// 连续失败几次就**本次会话**不再上报。
  final int maxConsecutiveFailures;

  BiliHistoryReporter({
    required this.send,
    required this.enabled,
    DateTime Function()? now,
    this.minInterval = const Duration(seconds: 60),
    this.maxConsecutiveFailures = 3,
  }) : _now = now ?? DateTime.now;

  DateTime? _lastAttemptAt;
  DateTime? _nextAllowedAt;
  int _consecutiveFailures = 0;
  bool _stopped = false;
  bool _inflight = false;

  /// 本次会话已尝试发出的次数 / 成功次数 / 失败次数（测试与排查用）。
  int attempts = 0;
  int successes = 0;
  int failures = 0;

  /// 是否已经**停手**（未登录/风控，或连续失败到上限）。
  bool get stoppedForSession => _stopped;

  /// 是否被退避窗口挡住（下一次允许时间）。
  DateTime? get nextAllowedAt => _nextAllowedAt;

  /// 上报一次进度（**不抛**；任何异常都吃掉）。
  ///
  /// [force] = true 时**绕过节流间隔**（暂停 / 退出 / 切换分 P 的"收尾一次"），
  /// 但**不绕过**：开关关着、已停手、还在退避窗口内。三者都是"不该发"的
  /// 理由，跟"是不是收尾"无关。
  Future<HistoryReportResult> report({
    required int aid,
    required int cid,
    required int progress,
    bool force = false,
  }) async {
    if (!enabled()) return HistoryReportResult.disabled;
    if (_stopped) return HistoryReportResult.stopped;
    if (_inflight) return HistoryReportResult.busy;
    if (aid <= 0 || cid <= 0) return HistoryReportResult.invalid;
    final now = _now();
    final next = _nextAllowedAt;
    if (next != null && now.isBefore(next)) {
      return HistoryReportResult.backoff;
    }
    final last = _lastAttemptAt;
    if (!force && last != null && now.difference(last) < minInterval) {
      return HistoryReportResult.throttled;
    }
    _lastAttemptAt = now;
    _inflight = true;
    attempts++;
    try {
      final sec = progress < 0 ? 0 : progress;
      await send(aid: aid, cid: cid, progress: sec);
      successes++;
      _consecutiveFailures = 0;
      _nextAllowedAt = null;
      debugPrint('[bili_history] 上报成功 aid=$aid cid=$cid progress=${sec}s');
      return HistoryReportResult.sent;
    } catch (e) {
      failures++;
      _consecutiveFailures++;
      final code = _terminalCode(e);
      if (code != null) {
        _stopped = true;
        debugPrint('[bili_history] 上报停止（code=$code，本次会话不再上报）: $e');
        return HistoryReportResult.failedStopped;
      }
      if (_consecutiveFailures >= maxConsecutiveFailures) {
        _stopped = true;
        debugPrint('[bili_history] 连续失败 $_consecutiveFailures 次 → 本次会话停手: $e');
        return HistoryReportResult.failedStopped;
      }
      // 指数退避：60s → 120s → 240s（至少退一个最小间隔）
      final factor = 1 << (_consecutiveFailures - 1).clamp(0, 5);
      _nextAllowedAt = now.add(minInterval * factor);
      debugPrint('[bili_history] 上报失败（第 $_consecutiveFailures 次），'
          '退避到 ${_nextAllowedAt!.toIso8601String()}: $e');
      return HistoryReportResult.failed;
    } finally {
      _inflight = false;
    }
  }

  /// 这些错误码**没有重试意义**：未登录（-101）继续发只会反复失败并刷接口，
  /// 风控（-412）继续发只会更深地踩进风控。返回 null = 按普通失败退避。
  static int? _terminalCode(Object error) {
    if (error is BiliApiException) {
      if (error.code == -101 || error.code == -412) return error.code;
    }
    return null;
  }

  /// 测试用：模拟"新的一次 App 启动/新播放会话"（清掉停手与退避状态）。
  @visibleForTesting
  void resetForTest() {
    _lastAttemptAt = null;
    _nextAllowedAt = null;
    _consecutiveFailures = 0;
    _stopped = false;
    _inflight = false;
    attempts = 0;
    successes = 0;
    failures = 0;
  }
}

/// [BiliHistoryReporter.report] 的判定结果（**测试要能读出来**，所以不返回 void）。
enum HistoryReportResult {
  /// 真发出去了且成功。
  sent,

  /// 开关关着 → 一个请求都没发。
  disabled,

  /// 本次会话已停手（未登录 / 风控 / 连续失败）。
  stopped,

  /// 上一次还没回来（防并发叠请求）。
  busy,

  /// aid/cid 无效（脏数据，不发）。
  invalid,

  /// 还没到最小间隔。
  throttled,

  /// 在失败退避窗口内。
  backoff,

  /// 发了但失败（还允许下次再试）。
  failed,

  /// 发了但失败，且这次之后停手。
  failedStopped,
}

/// 播放页的「这次要不要上报」前置判定（纯函数，可单测）。
///
/// **顺序即语义**：开关先判，关着时直接返回 false —— 播放页据此**连 aid 都不去
/// 取**（取 aid 是一次 view 请求），这样"开关关着 = 一个请求都不发"才是真的，
/// 而不是"发了请求但没发上报"。
///
/// [loggedIn]（v2.57.0 调整，开关改默认开后新增）：没登录同样返回 false。
/// 这是"默认开启也绝不乱发请求"的关键一环——缺 `bili_jct` 时上报接口会在
/// **本机**抛 -101，但在这之前取 aid 已经发出一次 view 请求了；把登录态判定
/// 提到前面，等于连那次 view 都省掉。凭据由调用方从 secure storage **本地**
/// 读取（不发网络请求），见 player_page 的 `_reportHistoryProgress`。
///
/// 其它 false 的情形：
/// - [isPgc]：番剧集走另一套 pgc 参数（见 [BiliApi.reportHistory] 注释）；
/// - [cid] <= 0：分 P 都认不出来，写进去的历史会指错集；
/// - [positionMs] <= 0：还没开始看（0 秒的记录没有意义）。
bool shouldReportHistory({
  required bool enabled,
  required bool loggedIn,
  required bool isPgc,
  required int cid,
  required int positionMs,
}) {
  if (!enabled) return false;
  if (!loggedIn) return false;
  if (isPgc) return false;
  if (cid <= 0) return false;
  if (positionMs <= 0) return false;
  return true;
}
