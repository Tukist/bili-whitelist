/// 白名单「数据新鲜度」门禁（v2.43.0）。
///
/// ## 为什么必须要有这道门禁
/// v2.35.0 起管理写操作是**乐观更新 + 后台整份 PATCH**：界面立刻生效，落库
/// 时把**内存里的整份快照**覆盖到 Gist。这在「内存快照 = 远端最新」时没问题；
/// 但同步源顺序是 `Gist → Lan → local → cache`，**离线冷启动会落到 local
/// （本地手动导入的静态快照）/ cache（上次同步的副本）**——那是**某个过去
/// 时刻**的数据。用户在这种状态下改任何东西（新建合集 / 移动视频 / 重命名 /
/// 删除），落库都会把整份**陈旧数据**覆盖到远端：他在别处（网页版、电脑端、
/// 另一台设备）刚做的改动会被**静默**抹掉——"静默"这两个字是重点，界面会
/// 显示"我做成了"，本地也落盘了，没有任何一处会告诉他远端被写旧了。
///
/// ## 为什么判据是「来源 + updated_at」，而不是文件时间
/// - `whitelist_local.json` 的文件 mtime = 用户**导入那一刻**，不代表数据本身
///   何时更新；`whitelist_cache.json` 的 mtime = **上次同步那一刻**。拿文件时间
///   比大小只会得到"缓存永远比导入文件新"这种假结论（实测里 `local` 显示的
///   就是几周前的旧内容）。
/// - 数据自己带着权威的新鲜度字段 `updated_at`（PC 端 `whitelist.py` 写入，
///   [WhitelistData.updatedAt]），所以**选源**比它、"是否落后"也比它：
///   离线时在 local / cache 之间选 `updated_at` 更新的那一份，再拿它与
///   「最近一次成功同步到的 updated_at」（shared_preferences 里记着）比——
///   相等就说明这份离线快照**等于**已知最新，不算落后；不等才拦。
///
/// ## 只有**确证**陈旧才拦
/// 默认不拦：未加载过数据、或来源是测试替身（`sourceName` 不是四个真实源）
/// 时 [isStale] 恒为 false。门禁的职责是挡住**已经证实的覆盖风险**，不是给
/// 既有流程新加一道可能失败的门——误拦的代价是用户白点一次，误放的代价是
/// 用户的数据被静默写没，两者不对称，所以判据要"证据确凿"。
library;

/// 陈旧快照下写操作被拦时给用户看的那句话（唯一出口，别在别处另写一份）。
///
/// 文案要点：说清**为什么**（离线旧快照会覆盖云端较新的数据）、**不是你的
/// 操作错了**（是本地这份数据旧）、**怎么继续**（先同步再改）。
const String kStaleSnapshotWriteBlockedMessage =
    '当前显示的是离线保存的本地快照（可能已过期）。为避免把这份旧数据整份覆盖到云端较新的白名单上，'
    '这次修改没有保存。请先联网同步一次，成功后再操作。';

/// 陈旧快照下的**常驻**提示语（首页 / 合集页顶部的横幅，v2.44.0）。
///
/// 与 [kStaleSnapshotWriteBlockedMessage] 是一对：那句是"你刚做的修改没保存"
/// （用户动手的那一刻弹一次），这句是"你现在看的就是旧数据"（一直挂在顶上，
/// 直到真的同步成功）。两句都只说一件事：**离线旧快照不代表云端现状**。
const String kStaleSnapshotBannerMessage =
    '当前显示的是离线保存的旧快照（可能已过期），这里的修改不会保存。'
    '点「立即同步」拉取最新白名单。';

/// 白名单数据新鲜度状态（进程内单例）。
///
/// 生产路径上由 [WhitelistSyncService.sync] 每次同步后打标；页面拿到
/// [SyncResult] 后也会打一次（覆盖测试替身直接改写 `sync()` 的路径）。
class WhitelistFreshness {
  WhitelistFreshness._();

  /// 全局单例（全 App 共用一个"当前展示的数据新不新"的判断）。
  static final WhitelistFreshness instance = WhitelistFreshness._();

  /// 当前展示的数据是否被**确证**为陈旧（离线快照且落后于已知最新）。
  bool _stale = false;

  /// 最近一次打标的来源（gist / lan / local / cache；测试替身为其它值）。
  String? _sourceName;

  bool get isStale => _stale;

  /// 最近一次数据来源（诊断/测试断言用）。
  String? get sourceName => _sourceName;

  /// 写操作被拦的原因；null = 可以写。**写入口一律读这个**（而不是自己
  /// 判 [isStale]），保证提示文案只有一处。
  String? get writeBlockReason =>
      _stale ? kStaleSnapshotWriteBlockedMessage : null;

  /// 记下「当前展示的数据来自哪、新不新」。
  ///
  /// [stale] 由 [WhitelistSyncService.sync] 算好（它手上有缓存文件与
  /// 「已知最新」两个证据）；页面拿 [SyncResult] 转手打标，不做二次判断——
  /// 判据只能有一份，否则迟早出现"页面说能写、服务说不能写"的鬼故事。
  void markSync({required String sourceName, required bool stale}) {
    _sourceName = sourceName;
    _stale = stale;
  }

  /// 确证「远端权威数据已经拿到手」→ 解除陈旧态。
  ///
  /// 用在 read-modify-write 型写入器（[WhitelistWriter] / [UpownerWriter]）：
  /// 它们先 GET 远端整份、再改、再 PATCH，所以**只要那次 GET 成功**，写出去的
  /// baseline 就是远端最新，不存在"拿本地旧快照覆盖"的问题。此时陈旧态
  /// 已经不成立，必须解掉——否则用户明明在线（GET 都成功了）却被门禁挡着。
  void confirmRemote() {
    _stale = false;
  }

  /// 测试用：把门禁重置成"未加载过数据"（默认不拦）。
  void resetForTest() {
    _stale = false;
    _sourceName = null;
  }

  /// 测试用：直接置为陈旧态。
  void markStaleForTest({String sourceName = 'local'}) {
    _sourceName = sourceName;
    _stale = true;
  }

  // ---------------------------------------------------------------------------
  // 新鲜度比较（纯函数，选源与"是否落后"共用同一套解析规则）
  // ---------------------------------------------------------------------------

  /// 比较两份数据的 `updated_at` 新鲜度（**选源**用）：>0 = [a] 更新，
  /// <0 = [b] 更新，**0 = 无从比较**（调用方按既有顺序兜底，别在这里猜）。
  ///
  /// 规则（顺序即优先级）：
  /// - 两边都能解析成时间 → 比时间（同一时刻也返回 0：内容应一致，不值得挑）；
  /// - 只有一边能解析 → 能解析的那边胜（**有明确时间戳的胜过没有的**：旧版数据
  ///   可能没写 `updated_at`，那种数据无从证明自己更新）；
  /// - 都解析不了 → 0（不猜）。
  static int compareUpdatedAt(String a, String b) {
    final ta = DateTime.tryParse(a.trim());
    final tb = DateTime.tryParse(b.trim());
    if (ta != null && tb != null) {
      if (ta.isAfter(tb)) return 1;
      if (ta.isBefore(tb)) return -1;
      return 0;
    }
    if (ta != null) return 1;
    if (tb != null) return -1;
    return 0;
  }

  /// [dataUpdatedAt] 是否**落后**于已知最新 [knownLatest]（判定陈旧用）。
  ///
  /// 保守规则：`knownLatest` 为空（从没成功同步过，无从证明这份快照是最新）
  /// 或时间都解析不出来且字符串也不同 → 一律算落后。宁可多拦一次（用户点一下
  /// 同步），也不放一次可能静默覆盖用户数据的写。
  static bool isBehind(String dataUpdatedAt, String? knownLatest) {
    final latest = (knownLatest ?? '').trim();
    if (latest.isEmpty) return true;
    final a = DateTime.tryParse(dataUpdatedAt.trim());
    final b = DateTime.tryParse(latest);
    if (a != null && b != null) return a.isBefore(b);
    return dataUpdatedAt.trim() != latest;
  }
}
