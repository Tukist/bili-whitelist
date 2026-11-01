import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/bilibili_api.dart';
import '../cache/playback_progress.dart';
import '../models/whitelist_video.dart';
import 'history_store.dart';
import 'service_locator.dart';

/// B 站观看历史同步（v2.57.0+）：读 `x/web-interface/history/cursor`，
/// 解析成 [RemoteHistoryItem]，映射成 [HistoryEntry] 并入本机历史。
///
/// ## 为什么单独一层，而不是塞进 `BiliApi`
/// [BiliApi] 负责"把一条请求发出去 + 把业务码翻译成可读异常"；这里负责
/// 「游标翻页策略 / 字段映射到 [HistoryEntry] / 并入本机历史」。
/// 后者全是**纯逻辑**（可注入假的 fetch 函数与假的时钟单测），前者需要网络与
/// 登录态。混在一起就只能靠 mock 整条 HTTP 才能测合并规则。
///
/// ## 产品约束（v2.57.0 定稿：**账号历史里的所有视频都进本机历史**）
/// 用户原话：「所有视频都需要进历史记录」。所以读方向**不再按白名单过滤**：
/// 非白名单的普通投稿照收，历史页只给它标一个「未在白名单」（仍可点播）。
/// 白名单在这里只剩两个用途：① 标题/封面/UP 主/分 P 的**元信息优先取它那份**
/// （字段最全）；② 决定条目要不要挂「未在白名单」标记。判定集中在
/// [BiliHistorySyncService.sync] 的循环里。
///
/// ## 丢弃的条目（**只丢在本 App 播放器里没有对应物的**）
/// - `business` 不是 `archive`（番剧 pgc / 直播 live / 专栏 article 等）：
///   播放器只认 bvid + cid 的普通投稿；
/// - `bvid` 为空（番剧项的 bvid 实测是空串，改给 epid）：没有 bvid 就没有
///   可播对象，也进不了本机历史的去重主键；
/// - `view_at <= 0`：没有观看时间，排序与"最近看过"都无从谈起；
/// - **非白名单且 `cid <= 0`**：认不出分 P，点开也取不到流（白名单条目的
///   cid 可以从白名单那份补，不受这条限制）。
///
/// ## 接口形状说明（v2.57.0 探针）
/// - 匿名直连 → `{"code":-101,"message":"账号未登录"}`（**实测**，未带凭据）；
///   → 所以读方向必须登录，未登录给可读提示，不发请求。
/// - 字段名来自 `bilibili-API-collect` 的 `docs/historytoview/history.md`
///   （**文档**，本机无凭据无法实测登录态的返回体）。

/// 同步分页上限（页）。
///
/// 3 页 × 每页 30 条 = 90 条，够覆盖"最近一段时间"；不设上限的话
/// 1000 条历史要 34 次请求，对一个"顺手同步"的入口太重，也更容易撞风控。
const int kHistorySyncMaxPages = 3;

/// 同步每页条数（文档：`ps` 默认 20、**上限 30**）。
const int kHistorySyncPageSize = 30;

/// 进历史页**自动**同步的最小间隔（v2.59.0）。
///
/// 为什么是 10 分钟：
/// - 自动同步的诉求是"PC 上刚看的视频，切到手机就能看到"。用户在两个设备之间
///   切换通常以分钟计，10 分钟的窗口足以覆盖，而 1~2 分钟的窗口会在用户反复
///   切底部导航时把请求打成刷接口；
/// - 一次自动同步 = 最多 3 次历史请求 + 一次白名单同步，成本不低，
///   而 B 站历史本身也不是秒级实时的（播放心跳 15s、落库还有延迟）。
///
/// 手动点按钮与下拉刷新**不受这个间隔限制**（用户明确要求刷新）。
const Duration kHistoryAutoSyncInterval = Duration(minutes: 10);

/// 未登录时历史页给的一行说明（v2.59.0；自动同步在这种情况下**一个请求都不发**）。
const String kHistoryLoginRequiredHint = '登录后可同步 B 站历史';

/// 进历史页时"要不要真的跑一次自动同步"（v2.59.0，纯函数，可单测）。
///
/// 判定顺序即语义：
/// 1. [force]（下拉刷新 / 手动按钮）→ 只看登录态，不看节流；
/// 2. 未登录 → 不跑（连历史 cursor 那一次都不发，避免每次都换一个 -101 回来）；
/// 3. 距**上次成功**不足 [minInterval] → 跳过；
/// 4. 距**上次尝试**（成功或失败）不足 [minInterval] → 跳过。
///
/// 第 4 条是必需的不是保险：一次失败不会更新"上次成功"，若只按成功时间节流，
/// 同步失败 → 页面 reload → 又判定"该同步" → 再失败……变成死循环刷接口。
/// 把"尝试"也计入，失败后同样安静 10 分钟，用户下次进页面再试。
bool shouldAutoSyncHistory({
  required DateTime? lastSyncAt,
  required DateTime? lastAttemptAt,
  required DateTime now,
  Duration minInterval = kHistoryAutoSyncInterval,
  bool force = false,
  bool loggedIn = true,
}) {
  if (!loggedIn) return false;
  if (force) return true;
  bool tooSoon(DateTime? at) =>
      at != null && now.difference(at) < minInterval;
  if (tooSoon(lastSyncAt)) return false;
  if (tooSoon(lastAttemptAt)) return false;
  return true;
}

/// 远程历史里的一条（`data.list[]` 的解析结果；只保留读方向用得上的字段）。
///
/// 容错原则：**任何字段缺失/脏类型都不抛**，缺了就用"未知"（0 / 空串）——
/// 接口一处改名不能把整次同步打挂（丢了元信息还有 bvid 可用白名单兜底）。
@immutable
class RemoteHistoryItem {
  /// 稿件 bvid（`history.bvid`；番剧/直播/专栏为空串）。
  final String bvid;

  /// `history.oid`（archive 时 = 稿件 aid，pgc 时 = 剧集 oid）。
  final int oid;

  /// `history.epid`（番剧集 id；普通稿件为 0）。
  final int epId;

  /// `history.cid`（**分 P 的 cid**，用来判定"这是第几 P"）。
  final int cid;

  /// `history.page`（分 P 序号）。
  ///
  /// ⚠️ **推断**：文档只写"分 P 序号"、没写 1 基还是 0 基；样本文档里
  /// 番剧/专栏都是 0，普通单 P 稿件应为 1。因此映射时优先用 [cid] 去白名单
  /// 的 `pages` 里对下标（可验证），只有对不上才退回 `page - 1`（见
  /// [resolvePageIndex]）。
  final int page;

  /// `history.business`（`archive` / `pgc` / `live` / `article` …）。
  final String business;

  /// `title`（已去掉 B 站可能夹带的高亮标签）。
  final String title;

  /// 封面：`cover` 非空优先，否则取 `covers[0]`（文档示例里两处都可能为空）。
  final String cover;

  /// `author_name`（UP 主名；番剧/专栏可能为空）。
  final String upName;

  /// `duration`（**秒**；未知 = 0）。
  final int durationSec;

  /// `progress`（**秒**；文档与实测样本都是秒级）。
  final int progressSec;

  /// `view_at`（**秒级** Unix 时间戳；文档明确是时间戳，非毫秒）。
  final int viewAtSec;

  const RemoteHistoryItem({
    required this.bvid,
    required this.oid,
    required this.epId,
    required this.cid,
    required this.page,
    required this.business,
    required this.title,
    required this.cover,
    required this.upName,
    required this.durationSec,
    required this.progressSec,
    required this.viewAtSec,
  });

  /// 是否是"普通稿件"（只有这类能对上白名单的 bvid）。
  ///
  /// 空 business 也放行：有的历史项不下发该字段，靠 bvid 是否为空兜底。
  bool get isArchive => business.isEmpty || business == 'archive';

  /// 能被并入本机历史的最小条件：有 bvid + 是普通稿件 + 看过时间有效。
  bool get isUsable => isArchive && bvid.isNotEmpty && viewAtSec > 0;

  @override
  String toString() => 'RemoteHistoryItem($bvid p=$page cid=$cid '
      'biz=$business view_at=$viewAtSec progress=$progressSec)';
}

/// 一页（或一次）游标响应：条目 + 下一页游标。
@immutable
class RemoteHistoryPage {
  final List<RemoteHistoryItem> items;

  /// `data.cursor.max` / `view_at` / `business`（原样回填取下一页）。
  final int cursorMax;
  final int cursorViewAt;
  final String cursorBusiness;

  const RemoteHistoryPage({
    required this.items,
    required this.cursorMax,
    required this.cursorViewAt,
    required this.cursorBusiness,
  });

  static const RemoteHistoryPage empty = RemoteHistoryPage(
    items: [],
    cursorMax: 0,
    cursorViewAt: 0,
    cursorBusiness: '',
  );

  /// 游标是否可用（三项全空 = 服务端没给，翻页必须停）。
  bool get hasCursor =>
      cursorMax > 0 || cursorViewAt > 0 || cursorBusiness.isNotEmpty;
}

/// 去掉 B 站标题里可能夹带的尖括号标签（搜索结果高亮用的 `<em class="keyword">`）。
///
/// 历史接口一般不带，但标题是要原样显示在历史卡上的文本，廉价兜一层。
String stripBiliHighlight(String raw) {
  if (!raw.contains('<')) return raw;
  return raw.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

int _intOf(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

/// 解析一页历史响应（`data` 对象；纯函数，可单测）。
///
/// 容错：`list` 缺失/非数组 → 空页；单条脏数据（不是 Map）→ 跳过该条，
/// **不影响同页其它条**（历史是"能显示多少算多少"的列表，不是强一致数据）。
RemoteHistoryPage parseHistoryCursor(Map<String, dynamic>? data) {
  if (data == null) return RemoteHistoryPage.empty;
  final cursor = data['cursor'];
  final cm = cursor is Map ? cursor : const {};
  final rawList = data['list'];
  final items = <RemoteHistoryItem>[];
  if (rawList is List) {
    for (final e in rawList) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final hist = m['history'] is Map
          ? Map<String, dynamic>.from(m['history'] as Map)
          : const <String, dynamic>{};
      final covers = m['covers'];
      var cover = (m['cover'] as String?) ?? '';
      if (cover.isEmpty && covers is List && covers.isNotEmpty) {
        final first = covers.first;
        if (first is String) cover = first;
      }
      items.add(RemoteHistoryItem(
        bvid: (hist['bvid'] as String?) ?? '',
        oid: _intOf(hist['oid']),
        epId: _intOf(hist['epid']),
        cid: _intOf(hist['cid']),
        page: _intOf(hist['page']),
        business: (hist['business'] as String?) ?? '',
        title: stripBiliHighlight((m['title'] as String?) ?? ''),
        cover: cover,
        upName: (m['author_name'] as String?) ?? '',
        durationSec: _intOf(m['duration']),
        progressSec: _intOf(m['progress']),
        viewAtSec: _intOf(m['view_at']),
      ));
    }
  }
  return RemoteHistoryPage(
    items: items,
    cursorMax: _intOf(cm['max']),
    cursorViewAt: _intOf(cm['view_at']),
    cursorBusiness: (cm['business'] as String?) ?? '',
  );
}

/// 远程条目 → 本机 [HistoryEntry] 的分 P 下标（0 基）。
///
/// 规则（**优先可验证的那条**）：
/// 1. 白名单视频有 [WhitelistVideo.pages] 且 [cid] > 0 → 用 cid 找同下标
///    （cid 是唯一标识，不依赖"page 是 1 基"这个推断）；
/// 2. 找不到（或没有分 P 列表）→ `page - 1`（文档说 page 是"分 P 序号"，
///    推断为 1 基；0/负数按 0 处理）；
/// 3. 结果夹到 `[0, pages.length-1]`，防脏 page 越界点开一个不存在的一集。
int resolvePageIndex({
  required RemoteHistoryItem item,
  required WhitelistVideo video,
}) {
  final pages = video.pages;
  if (pages != null && pages.isNotEmpty) {
    if (item.cid > 0) {
      for (var i = 0; i < pages.length; i++) {
        if (pages[i].cid == item.cid) return i;
      }
    }
    final guess = item.page > 0 ? item.page - 1 : 0;
    return guess < 0 ? 0 : (guess >= pages.length ? pages.length - 1 : guess);
  }
  // 没有分 P 列表 = 白名单只记了顶层 cid（单 P 视频 / 旧数据）：**一律 0**。
  // 不按 `page-1` 猜：猜出一个几号的"分 P"，播放页却没有分 P 列表可对，
  // 反而会把一条播放不了的记录摆在历史里（多 P 视频的 pages 由播放页
  // onPrepared 后补进历史条目，那时才谈得上区分第几集）。
  return 0;
}

/// 同步结果（含"扫了多少 / 收了多少 / 跳过多少"这种必须能说清楚的数字）。
@immutable
class HistorySyncOutcome {
  final bool ok;

  /// 实际扫过的远程条数（多页累加）。
  final int scanned;

  /// 被并入本机历史的条数（白名单内外都算）。
  final int kept;

  /// **无法在本 App 播放**而跳过的条数（番剧 / 直播 / 专栏 / 空 bvid /
  /// 无观看时间 / 非白名单且认不出 cid）。
  final int dropped;

  /// [kept] 里**不在白名单**的条数（历史页给它们标「未在白名单」）。
  final int notInWhitelist;

  /// 并入时新增 / 更新的条数。
  final int added;
  final int updated;

  /// 本次有多少条远程进度被写进**本机进度记忆**（v2.59.0，跨端续播）。
  /// 只用于日志与测试；界面文案不显示它（用户不关心这个数字）。
  final int adoptedProgress;

  /// 本次同步的完成时间（失败 = null）。
  final DateTime? lastSyncAt;

  /// 失败原因（可读中文；成功 = null）。
  final String? error;

  const HistorySyncOutcome({
    required this.ok,
    required this.scanned,
    required this.kept,
    required this.dropped,
    required this.added,
    required this.updated,
    this.notInWhitelist = 0,
    this.adoptedProgress = 0,
    this.lastSyncAt,
    this.error,
  });

  const HistorySyncOutcome.failure(String message)
      : ok = false,
        scanned = 0,
        kept = 0,
        dropped = 0,
        notInWhitelist = 0,
        added = 0,
        updated = 0,
        adoptedProgress = 0,
        lastSyncAt = null,
        error = message;

  /// 底部提示条文案。
  ///
  /// v2.57.0 调整：非白名单条目**不再被忽略**（全部进历史），所以提示里
  /// 说的是「其中多少条不在白名单」，而不是「忽略多少条」。
  String get summary {
    if (kept == 0) {
      return scanned == 0
          ? 'B 站账号里最近没有观看记录'
          : 'B 站历史里没有能在这里播放的条目'
              '（已跳过 $dropped 条：番剧 / 直播 / 专栏等）';
    }
    final parts = <String>['已同步 $kept 条 B 站历史'];
    if (added > 0) parts.add('新增 $added');
    if (updated > 0) parts.add('更新 $updated');
    if (notInWhitelist > 0) parts.add('其中 $notInWhitelist 条不在白名单');
    if (dropped > 0) parts.add('跳过 $dropped 条无法播放的');
    return parts.join(' · ');
  }
}

/// 把异常翻译成用户能读懂的失败原因（未登录 / 风控 / 网络 / 其它）。
///
/// 只映射"有把握"的码；其余优先用接口自己的中文 message（比我们编的准）。
String historySyncErrorText(Object error) {
  if (error is BiliApiException) {
    return switch (error.code) {
      -101 => '未登录或登录已失效，请先登录 B 站账号',
      -412 => '被 B 站风控拦截，请稍后再试',
      -352 || -509 => '请求过于频繁，请稍后再试',
      _ => error.message.isEmpty ? '同步失败（code=${error.code}）' : error.message,
    };
  }
  // WbiKeyUnavailableException 等 DioException 子类都落到这里（网络层失败）
  if (error is DioException) return '网络请求失败，请检查网络后重试';
  return '同步失败：$error';
}

/// 同步服务：游标翻页 → 映射（白名单只补元信息）→ 并入本机历史 → 记同步时间。
///
/// 依赖全部可注入（[fetchPage] / [whitelist] / [store] / [now]），单测不发网络。
class BiliHistorySyncService {
  /// 取一页历史（真实实现 = [BiliApi.fetchHistoryCursor]）。
  final Future<Map<String, dynamic>> Function({
    int? max,
    int? viewAt,
    String? business,
    int ps,
  }) fetchPage;

  /// 取当前白名单（真实实现 = 同步服务 Gist → Lan → 缓存 那条回退链）。
  final Future<WhitelistData> Function() whitelist;

  final HistoryStore store;
  final DateTime Function() now;

  BiliHistorySyncService({
    BiliApi? api,
    Future<Map<String, dynamic>> Function({
      int? max,
      int? viewAt,
      String? business,
      int ps,
    })? fetchPage,
    Future<WhitelistData> Function()? whitelist,
    HistoryStore? store,
    DateTime Function()? now,
  })  : fetchPage = fetchPage ??
            ((api ?? BiliApi()).fetchHistoryCursor),
        whitelist = whitelist ??
            (() async => (await ServiceLocator.syncService.sync()).data),
        store = store ?? HistoryStore.instance,
        now = now ?? DateTime.now;

  /// 执行一次同步。**永不抛**：所有失败都折成 [HistorySyncOutcome.failure]。
  Future<HistorySyncOutcome> sync({int maxPages = kHistorySyncMaxPages}) async {
    try {
      final WhitelistData data;
      try {
        data = await whitelist();
      } catch (e) {
        // 白名单读不出来 → 元信息补不全、"在不在白名单"也说不准（会把所有条目
        // 都误标成「未在白名单」）。宁可明确说一次读取失败，也不要静默降级：
        // 用户点一次重试就能解决，而误标会一直留在列表里。（这条与"未登录 /
        // 网络 / 风控"是不同的失败，文案分开。）
        debugPrint('[bili_history] 白名单读取失败: $e');
        return const HistorySyncOutcome.failure(
            '白名单读取失败（请检查网络或重新导入白名单）');
      }
      final byBvid = <String, WhitelistVideo>{};
      for (final v in data.videos) {
        if (v.bvid.isNotEmpty) byBvid.putIfAbsent(v.bvid, () => v);
      }
      // 白名单为空**不是**失败（v2.57.0 调整）：账号历史里的所有视频都要进
      // 本机历史，只是全部会挂上「未在白名单」标记。
      final pages = await _collectPages(maxPages: maxPages);
      final mapped = <HistoryEntry>[];
      var notInWhitelist = 0;
      // 丢弃分类计数（只进日志：排查"为什么这条没进来"时不用猜）
      var dropOtherBusiness = 0;
      var dropNoBvid = 0;
      var dropNoViewAt = 0;
      var dropNoCid = 0;
      for (final item in pages) {
        if (!item.isUsable) {
          if (!item.isArchive) {
            dropOtherBusiness++; // 番剧 pgc / 直播 live / 专栏 article 等
          } else if (item.bvid.isEmpty) {
            dropNoBvid++; // 脏条目：没有 bvid 就没有可播对象
          } else {
            dropNoViewAt++; // 没有观看时间 → 排序与"最近看过"都无从谈起
          }
          continue;
        }
        final video = byBvid[item.bvid];
        // 非白名单条目靠远程自己的 cid 播放；认不出 cid 的条目点开也取不到流，
        // 不进历史（白名单条目的 cid 可以从白名单那份补，不受这条限制）
        if (video == null && item.cid <= 0) {
          dropNoCid++;
          continue;
        }
        if (video == null) notInWhitelist++;
        mapped.add(entryFromRemote(item: item, video: video));
      }
      final dropped =
          dropOtherBusiness + dropNoBvid + dropNoViewAt + dropNoCid;
      final merged = await store.mergeRemote(mapped);
      final adopted = await _adoptRemoteProgress(merged.remoteProgressWinners);
      final at = now();
      await store.saveLastSyncAt(at);
      debugPrint('[bili_history] 同步完成 扫描=${pages.length} '
          '保留=${mapped.length}（不在白名单=$notInWhitelist） '
          '丢弃=$dropped［其它业务=$dropOtherBusiness 空bvid=$dropNoBvid '
          '无观看时间=$dropNoViewAt 无cid=$dropNoCid］ '
          '新增=${merged.added} 更新=${merged.updated} 进度落本机=$adopted');
      return HistorySyncOutcome(
        ok: true,
        scanned: pages.length,
        kept: mapped.length,
        dropped: dropped,
        notInWhitelist: notInWhitelist,
        added: merged.added,
        updated: merged.updated,
        adoptedProgress: adopted,
        lastSyncAt: at,
      );
    } on BiliApiException catch (e) {
      debugPrint('[bili_history] 同步失败 code=${e.code} ${e.message}');
      return HistorySyncOutcome.failure(historySyncErrorText(e));
    } catch (e) {
      debugPrint('[bili_history] 同步失败: $e');
      return HistorySyncOutcome.failure(historySyncErrorText(e));
    }
  }

  /// 把"远程进度更近"的条目写进**本机进度记忆**（v2.59.0，跨端续播）。
  ///
  /// 为什么在这里做而不是在历史页做：写进来的目的不是"历史页显示得对"
  /// （那由历史表自己的 `positionMs` 负责），而是让**任何入口**（白名单 /
  /// 合集 / 搜索 / UP 主页）点开这一集都能续播 —— 那些入口读的是
  /// `PlaybackProgress`，与历史表无关。
  ///
  /// 写哪些由 [shouldAdoptRemoteProgress] 判（本机更近的一次绝不被覆盖）。
  /// **失败静默**：进度记忆是锦上添花（历史表已经合并成功），不该因为
  /// shared_preferences 抽风让整次同步看起来失败。
  Future<int> _adoptRemoteProgress(List<HistoryEntry> winners) async {
    if (winners.isEmpty) return 0;
    try {
      final progress = await PlaybackProgress.load();
      for (final e in winners) {
        await progress.saveProgress(e.bvid, e.pageIndex, e.positionMs);
      }
      debugPrint('[bili_history] 远程进度落本机 ${winners.length} 条：'
          '${winners.map((e) => '${e.bvid}#${e.pageIndex}=${e.positionMs}ms').join(', ')}');
      return winners.length;
    } catch (e) {
      // 写进度失败：只影响"续播位置"，不影响历史表本身
      debugPrint('[bili_history] 远程进度落本机失败（静默）: $e');
      return 0;
    }
  }

  /// 游标翻页（最多 [maxPages] 页），任一页失败就**整次失败**。
  ///
  /// 为什么中途失败不"用已有部分继续"：同步是"把账号历史并进本机"的幂等
  /// 操作，半截结果 + 声称成功会让用户以为已经全了；把已拿到的部分丢了再让
  /// 用户重试一次，代价只是几秒，语义上干净得多。
  Future<List<RemoteHistoryItem>> _collectPages({
    required int maxPages,
  }) async {
    final all = <RemoteHistoryItem>[];
    int? max;
    int? viewAt;
    String? business;
    for (var page = 0; page < maxPages; page++) {
      final data = await fetchPage(
        max: max,
        viewAt: viewAt,
        business: business,
        ps: kHistorySyncPageSize,
      );
      final parsed = parseHistoryCursor(data);
      if (parsed.items.isEmpty) break; // 到底了
      all.addAll(parsed.items);
      if (!parsed.hasCursor) break;
      // 游标没前进（接口异常/服务端兜底）→ 必须停，否则会无限翻同一页
      if (parsed.cursorMax == max &&
          parsed.cursorViewAt == viewAt &&
          parsed.cursorBusiness == business) {
        debugPrint('[bili_history] 游标未前进，停止翻页');
        break;
      }
      max = parsed.cursorMax;
      viewAt = parsed.cursorViewAt;
      business = parsed.cursorBusiness;
    }
    return all;
  }
}

/// 远程条目（+ 可选的白名单元信息）→ 本机历史条目（纯函数，可单测）。
///
/// [video] 非空 = 这个 bvid 在白名单里；null = 不在（v2.57.0 起这类条目也进
/// 历史，见文件头的产品约束）。
///
/// 元信息**优先用白名单那份**（标题/封面/UP 主/时长/分 P 列表）：白名单是
/// 用户在 App 里看到的那一份，和本机历史条目字段完全对齐；远程那份只兜底
/// （标题为空时用）。这样同一个视频在两边的展示不会因为"哪来的"而变样。
///
/// 非白名单条目**全部用远程字段补齐**（`title` / `cover` / `author_name` /
/// `duration` / `history.cid|page`）——播放页只要 bvid + cid 就能取流，
/// 不需要它在白名单里（搜索页/评论跳转那条链路本来就是这么播的）。
/// 这类条目的 `pages` 留 null（远程只给了"这一集"，没有整份分 P 列表；
/// 给个假列表反而会让选集的集数/时长全错），`pageIndex` 按 [RemoteHistoryItem.page]
/// 推断为 `page-1`，播放页拿 `initialPageIndex` 时会自己去补真列表。
///
/// 进度/观看时间**一律取远程**：这条记录的来源就是远程。
HistoryEntry entryFromRemote({
  required RemoteHistoryItem item,
  WhitelistVideo? video,
}) {
  final pageIndex = video != null
      ? resolvePageIndex(item: item, video: video)
      // 没有白名单分 P 列表可对：page 是"分 P 序号"（推断 1 基），
      // 0/负数按第 0 集处理
      : (item.page > 0 ? item.page - 1 : 0);
  final pages = video?.pages;
  final localDurationMs = (pages != null &&
          pageIndex < pages.length &&
          pages[pageIndex].duration > 0)
      ? pages[pageIndex].duration * 1000
      : (video?.duration ?? 0) * 1000;
  final localCid = pages != null && pageIndex < pages.length
      ? pages[pageIndex].cid
      : (video?.cid ?? 0);
  return HistoryEntry(
    // 非白名单走远程的 bvid（调用方已保证非空）
    bvid: video?.bvid ?? item.bvid,
    pageIndex: pageIndex,
    cid: item.cid > 0 ? item.cid : localCid,
    title: (video != null && video.title.isNotEmpty) ? video.title : item.title,
    cover: (video != null && video.cover.isNotEmpty) ? video.cover : item.cover,
    upName:
        (video != null && video.upName.isNotEmpty) ? video.upName : item.upName,
    durationMs: localDurationMs > 0 ? localDurationMs : item.durationSec * 1000,
    positionMs: item.progressSec > 0 ? item.progressSec * 1000 : 0,
    watchedAt: DateTime.fromMillisecondsSinceEpoch(item.viewAtSec * 1000),
    pages: pages,
    pubdate: video?.pubdate,
    source: HistorySource.bilibili,
    // 标记影响 UI（历史页「未在白名单」），也是合并时"以远程为准"的字段
    inWhitelist: video != null,
  );
}
