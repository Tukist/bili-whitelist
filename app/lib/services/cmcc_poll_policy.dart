/// 掌厅抓取的**轮询 / 退避策略**（v2.54.0，纯函数，测试直接钉）。
///
/// ## 为什么单独一个文件、为什么全是纯函数
///
/// 「多久查一次」这件事直接关系到**会不会把用户号段搞进风控**：掌厅的短信
/// 验证码下发有限流，接口也不是设计给第三方轮询的。所以策略必须是**能单测的
/// 纯函数**（不是散在 Widget 里的 `Timer` 参数），任何人都能一眼看出：
/// - 正常 **30 分钟**一次；
/// - 失败退避 **5 分钟**；
/// - 连续失败 **3 次**退到 **1 小时**；
/// - **需要重新登录** → **停止自动轮询**（重新收短信验证码只能由用户本人操作，
///   App 不代发）；
/// - 任何情况下间隔**不短于 5 分钟**（[kCmccMinInterval]，[clampCmccInterval]
///   把它钉死，写错配置也退不回去）。
///
/// 落地位置见 `lib/pages/cmcc_page.dart`（页面活着的时候按计划起下一次；
/// 页面关掉就停——这是 WebView 抓取路线的硬约束，见那个文件的说明）。
library;

/// 正常节奏：30 分钟一次（用户要求：后台定时 30 分钟）。
const Duration kCmccPollInterval = Duration(minutes: 30);

/// 失败退避：5 分钟。
const Duration kCmccRetryBackoff = Duration(minutes: 5);

/// 连续失败多次后的长退避：1 小时。
const Duration kCmccLongBackoff = Duration(hours: 1);

/// 连续失败几次退到 [kCmccLongBackoff]。
const int kCmccFailuresBeforeLongBackoff = 3;

/// **硬下限**：任何自动查询间隔都不得短于 5 分钟。
///
/// 用户明确要求"绝不短于 5 分钟轮询"；这条下限由 [clampCmccInterval] 强制，
/// 不依赖各处调用点自觉。
const Duration kCmccMinInterval = Duration(minutes: 5);

/// 下一次自动查询该怎么排。
class CmccPollPlan {
  /// 还要不要自动轮询。
  final bool poll;

  /// 下次间隔（[poll] 为 false 时是 null）。
  final Duration? delay;

  /// 面向用户 / 日志的一句话（说明为什么是这个间隔）。
  final String reason;

  const CmccPollPlan({required this.poll, this.delay, required this.reason});
}

/// 把间隔钉在 [kCmccMinInterval] 之上（写错了也退不回去）。
Duration clampCmccInterval(Duration d) =>
    d < kCmccMinInterval ? kCmccMinInterval : d;

/// 按"连续失败次数 + 是否需要重新登录"算下一次轮询计划。
///
/// - `needsRelogin` 优先：**停止轮询**（[CmccPollPlan.poll] = false）；
/// - 0 次失败 → 30 分钟；1~2 次 → 5 分钟；≥3 次 → 1 小时；
/// - 所有返回的间隔都过一遍 [clampCmccInterval]。
CmccPollPlan cmccNextPollPlan({
  required int consecutiveFailures,
  required bool needsRelogin,
}) {
  if (needsRelogin) {
    return const CmccPollPlan(
      poll: false,
      reason: '登录态失效：自动轮询已停止，请你自己收短信重新登录。',
    );
  }
  final n = consecutiveFailures < 0 ? 0 : consecutiveFailures;
  if (n == 0) {
    return CmccPollPlan(
      poll: true,
      delay: clampCmccInterval(kCmccPollInterval),
      reason: '正常：每 30 分钟读一次。',
    );
  }
  if (n < kCmccFailuresBeforeLongBackoff) {
    return CmccPollPlan(
      poll: true,
      delay: clampCmccInterval(kCmccRetryBackoff),
      reason: '上次没读成，$n 次失败：5 分钟后重试。',
    );
  }
  return CmccPollPlan(
    poll: true,
    delay: clampCmccInterval(kCmccLongBackoff),
    reason: '连续 $n 次没读成：退到 1 小时后重试。',
  );
}

/// 失败一次的累计计数（超过阈值就停在阈值上，避免数字无限涨）。
int cmccBumpFailures(int current) {
  final n = current < 0 ? 0 : current;
  final next = n + 1;
  return next > kCmccFailuresBeforeLongBackoff ? kCmccFailuresBeforeLongBackoff : next;
}

/// 成功一次后清零。
int cmccResetFailures() => 0;
