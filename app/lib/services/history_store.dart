import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/whitelist_video.dart';

/// 一条历史记录的**来源**（v2.57.0+，双向同步落地后才有区分）。
///
/// - [local]：只在本机 App 里看过（含 v2.57.0 之前的全部旧记录——那些记录
///   没有 `source` 字段，读出来就是这个值，老数据字节不变）；
/// - [bilibili]：只从 B 站账号历史同步进来（本机没看过；进度/时间来自远程）；
/// - [both]：两边都有过，已合并成一条（进度按"更近的那次"取舍）。
///
/// 历史卡只在**非 [local]** 时标一行来源，本机记录不比改动前多任何一个像素。
enum HistorySource {
  local,
  bilibili,
  both;

  /// 解析存储里的字符串（脏值/空 → [local]，不崩）。
  static HistorySource parse(Object? raw) {
    return switch (raw) {
      'bilibili' => HistorySource.bilibili,
      'both' => HistorySource.both,
      _ => HistorySource.local,
    };
  }

  /// 落盘用的值（[local] 不写字段，保持旧记录 JSON 形态不变）。
  String? get jsonValue => this == HistorySource.local ? null : name;
}

/// 单条播放历史（看过的视频）。
///
/// 与 [PlaybackProgress] 不同：进度记忆只存位置毫秒，历史记录还保存视频
/// 元信息（标题/封面/UP 主/时长/分 P/发布时间），用于历史页列表展示与点击续播。
class HistoryEntry {
  final String bvid;
  final int pageIndex; // 播放到第几个分 P（0 = 单 P / 第一集）
  final int cid; // 当前分 P 的 cid（续播构造 WhitelistVideo 用）
  final String title;
  final String cover;
  final String upName;
  final int durationMs; // 总时长（毫秒；播放页 onPrepared 的实际值）
  final int positionMs; // 上次播放位置（毫秒）
  final DateTime watchedAt; // 最近一次观看时间（本地时间）
  final List<PageInfo>? pages; // 分 P 列表（若有；续播保留选集 UI）

  /// 视频发布时间（Unix 秒；来自 [WhitelistVideo.pubdate]）。
  /// 旧记录 / 未知（导入数据本身没有发布时间）→ null（列表不显示该段）。
  final int? pubdate;

  /// 这条记录从哪来（v2.57.0+；旧记录读出来是 [HistorySource.local]）。
  final HistorySource source;

  /// 这条记录对应的视频**当前在不在白名单里**（v2.57.0+，默认 true）。
  ///
  /// 只有「从 B 站账号同步进来、且同步时白名单里没有这个 bvid」的条目才是
  /// false —— 历史页据此给一个「未在白名单」的轻量标记（**仍然可以点开播**：
  /// 播放页本来就支持只播不写白名单，见搜索页/评论跳转那条链路）。
  ///
  /// 为什么是落盘的快照而不是渲染时现查白名单：现查要走一次 Gist/Lan 同步链
  /// （网络 + 磁盘），为一个列表标记去拉白名单不值当；快照由**同步**那次刷新
  /// （账号历史里还在这个视频 → 下一次同步就会把标记改回来）。
  ///
  /// 默认 true（不是 false）：v2.57.0 之前的记录全都来自「播白名单里的视频」，
  /// 读出来必须一个像素都不多（见 [toJson] 不写该字段的说明）。
  final bool inWhitelist;

  const HistoryEntry({
    required this.bvid,
    required this.pageIndex,
    required this.cid,
    required this.title,
    required this.cover,
    required this.upName,
    required this.durationMs,
    required this.positionMs,
    required this.watchedAt,
    this.pages,
    this.pubdate,
    this.source = HistorySource.local,
    this.inWhitelist = true,
  });

  /// 去重主键：同一 (bvid, pageIndex) 视为同一条观看记录（覆盖更新）。
  String get key => '${bvid}_$pageIndex';

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      bvid: json['bvid'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      upName: json['upName'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      watchedAt: DateTime.tryParse(json['watchedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pages: (json['pages'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(PageInfo.fromJson)
          .toList(),
      // 旧记录无 pubdate / 脏类型 → null（不显示发布日期，不崩）
      pubdate: json['pubdate'] is num
          ? (json['pubdate'] as num).toInt()
          : null,
      // 旧记录没有 source 字段 → local（不是"来自 B 站"，只是当年没这个概念）
      source: HistorySource.parse(json['source']),
      // 旧记录没有该字段 → true（当年只有白名单里的视频会进历史）
      inWhitelist: json['inWhitelist'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'pageIndex': pageIndex,
        'cid': cid,
        'title': title,
        'cover': cover,
        'upName': upName,
        'durationMs': durationMs,
        'positionMs': positionMs,
        'watchedAt': watchedAt.toIso8601String(),
        if (pages != null)
          'pages': pages!.map((p) => p.toJson()).toList(),
        // 未知发布时间不写多余字段（旧记录形态逐字不变）
        if (pubdate != null) 'pubdate': pubdate,
        // 本机记录不写 source（v2.57.0 之前的记录 JSON 逐字不变）
        if (source.jsonValue != null) 'source': source.jsonValue,
        // 只有"不在白名单"才写（true 是隐含默认值）：旧记录形态逐字不变，
        // 视频被加回白名单后该键也会随之消失
        if (!inWhitelist) 'inWhitelist': false,
      };

  /// 复制并替换少数几个字段（合并时用；其余原样保留）。
  HistoryEntry copyWith({
    int? cid,
    String? title,
    String? cover,
    String? upName,
    int? durationMs,
    int? positionMs,
    DateTime? watchedAt,
    List<PageInfo>? pages,
    int? pubdate,
    HistorySource? source,
    bool? inWhitelist,
  }) =>
      HistoryEntry(
        bvid: bvid,
        pageIndex: pageIndex,
        cid: cid ?? this.cid,
        title: title ?? this.title,
        cover: cover ?? this.cover,
        upName: upName ?? this.upName,
        durationMs: durationMs ?? this.durationMs,
        positionMs: positionMs ?? this.positionMs,
        watchedAt: watchedAt ?? this.watchedAt,
        pages: pages ?? this.pages,
        pubdate: pubdate ?? this.pubdate,
        source: source ?? this.source,
        inWhitelist: inWhitelist ?? this.inWhitelist,
      );
}

/// 播放历史存储（单例）：本地持久化（shared_preferences 存 JSON 列表）。
///
/// 与播放进度记忆同源同存储介质（shared_preferences，不入 Gist、不跨设备），
/// 但存的是**整表一条 JSON**（单 key `history_store:entries`），因为历史页
/// 每次打开都要读全表排序展示，整表读写最简单可靠。
///
/// 规则：
/// - [addOrUpdate]：同一 (bvid, pageIndex) 覆盖（更新时间/位置），列表按
///   watchedAt 倒序，超过 [maxEntries] 条裁剪最早
/// - [mergeRemote]（v2.57.0+）：把 B 站账号历史并进来，去重/进度取舍/本机
///   独有条目不丢（规则见该方法注释）
/// - 数据损坏（JSON 解析失败）视为空历史，不崩溃
/// - 读/写失败静默降级（返回空列表 / 跳过写入），不影响播放主流程
class HistoryStore {
  /// 历史记录条数上限（超出裁剪最早）。
  ///
  /// 1000 而不是 200：首页合集卡的「已看 X/Y」直接数这张表里的
  /// (bvid, pageIndex)，上限太低会把老记录裁掉、让「已看集数」偏少
  /// （重度用户追一部 300+ 集的番就会撞上 200）。整表一条 JSON 存
  /// shared_preferences，1000 条的量级（约几百 KB）读写仍在毫秒级。
  static const int maxEntries = 1000;

  static const String _key = 'history_store:entries';

  /// 「上次从 B 站同步成功」的时间（ISO 字符串；缺省 = 从没同步过）。
  /// 与历史表分开存一个 key：它是**一次操作的元信息**，塞进表里会污染
  /// "整表就是历史条目"这个简单结构。
  static const String _lastSyncKey = 'history_store:last_sync_at';

  static final HistoryStore instance = HistoryStore._();

  HistoryStore._();

  /// 读取全部历史，按 watchedAt 倒序（最近的在前）。
  Future<List<HistoryEntry>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List;
      final entries = list
          .whereType<Map<String, dynamic>>()
          .map(HistoryEntry.fromJson)
          .where((e) => e.bvid.isNotEmpty) // 脏条目（空 bvid）跳过
          .toList();
      entries.sort(_compareWatchedAtDesc);
      return entries;
    } catch (_) {
      // 数据损坏 / 读取失败：视为空历史（不崩溃、不影响播放）
      return const [];
    }
  }

  /// 新增/更新一条历史：同 (bvid, pageIndex) 覆盖；按 watchedAt 倒序；
  /// 超出 [maxEntries] 裁剪最早的。
  ///
  /// **「不在白名单」标记不被覆盖**（v2.57.0+）：播放页写历史时无从判断白名单
  /// 归属（[HistoryEntry.inWhitelist] 默认 true），直接覆盖会让「同步进来的
  /// 非白名单条目」在播放一次之后标记凭空消失。白名单归属只由**同步**改写
  /// （见 [mergeEntry]），本机播放不改变它。
  Future<void> addOrUpdate(HistoryEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getAll();
      HistoryEntry? prev;
      for (final e in list) {
        if (e.key == entry.key) {
          prev = e;
          break;
        }
      }
      final next = <HistoryEntry>[
        prev == null
            ? entry
            : entry.copyWith(inWhitelist: prev.inWhitelist),
        ...list.where((e) => e.key != entry.key),
      ];
      next.sort(_compareWatchedAtDesc);
      final trimmed = next.length > maxEntries
          ? next.sublist(0, maxEntries)
          : next;
      await prefs.setString(
        _key,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // 写入失败（存储异常等）：静默跳过，不影响播放主流程
    }
  }

  /// 删除单条历史（按 bvid + pageIndex）。
  Future<void> remove(String bvid, int pageIndex) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getAll();
      final next =
          list.where((e) => e.key != '${bvid}_$pageIndex').toList();
      await prefs.setString(
        _key,
        jsonEncode(next.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // 删除失败静默
    }
  }

  /// 清空全部历史。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // 清空失败静默
    }
  }

  // -------------------------------------------------------------------------
  // 从 B 站账号历史合并（v2.57.0+，读方向）
  // -------------------------------------------------------------------------

  /// 把一批**远程**历史合并进本机历史（幂等；失败静默返回 0/0）。
  ///
  /// 规则（主智能体已定的取舍，改之前先读一遍）：
  /// 1. **按 `(bvid, pageIndex)` 去重**：同一条观看记录只留一条；
  /// 2. **本机独有的记录一条都不丢**：远程没有的，原样保留（包括来源仍是
  ///    [HistorySource.local]）；
  /// 3. **进度按"更近的那次"取舍**：`watchedAt` 更晚的一方决定 `positionMs`
  ///    —— 本机看得更近就用本机的进度，远程更近就用远程的 `progress`。
  ///    只看时间不看"进度更大"：看得更近不代表进度更小（可能往回拖），
  ///    "最近一次看到哪"才是要续播的位置；
  /// 4. 合并后的 `watchedAt` 取两者较晚；元信息（标题/封面/UP 主/时长/分 P）
  ///    **优先本机那份**（本机的来自白名单，字段最全），缺了才用远程的；
  /// 5. 合并成功的条目来源标 [HistorySource.both] —— UI 要能说清"这条两边
  ///    都有过"，而不是假装它只来自其中一边；
  /// 6. **白名单归属以远程为准**（v2.57.0 调整）：远程那份的
  ///    [HistoryEntry.inWhitelist] 是"本次同步时白名单里有没有它"的最新事实，
  ///    所以视频被加进白名单后标记会自动消失，被移出白名单后会自动出现。
  ///
  /// 超出 [maxEntries] 仍按 watchedAt 倒序裁最早（与 [addOrUpdate] 同口径）。
  Future<HistoryMergeResult> mergeRemote(List<HistoryEntry> remote) async {
    if (remote.isEmpty) return const HistoryMergeResult(added: 0, updated: 0);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getAll();
      final byKey = <String, HistoryEntry>{
        for (final e in list) e.key: e,
      };
      var added = 0;
      var updated = 0;
      for (final r in remote) {
        if (r.bvid.isEmpty) continue; // 脏条目（空 bvid）不进表
        final cur = byKey[r.key];
        if (cur == null) {
          byKey[r.key] = r;
          added++;
        } else {
          byKey[r.key] = mergeEntry(local: cur, remote: r);
          updated++;
        }
      }
      if (added == 0 && updated == 0) {
        return const HistoryMergeResult(added: 0, updated: 0);
      }
      final next = byKey.values.toList()..sort(_compareWatchedAtDesc);
      final trimmed =
          next.length > maxEntries ? next.sublist(0, maxEntries) : next;
      await prefs.setString(
        _key,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
      return HistoryMergeResult(added: added, updated: updated);
    } catch (_) {
      // 存储异常：静默（同步结果会显示"新增/更新 0"，不崩）
      return const HistoryMergeResult(added: 0, updated: 0);
    }
  }

  /// 单条合并（纯函数，可单测）：见 [mergeRemote] 的规则 2~6。
  static HistoryEntry mergeEntry({
    required HistoryEntry local,
    required HistoryEntry remote,
  }) {
    final remoteNewer = remote.watchedAt.isAfter(local.watchedAt);
    return local.copyWith(
      cid: remote.cid > 0 ? remote.cid : local.cid,
      title: local.title.isNotEmpty ? local.title : remote.title,
      cover: local.cover.isNotEmpty ? local.cover : remote.cover,
      upName: local.upName.isNotEmpty ? local.upName : remote.upName,
      durationMs: local.durationMs > 0 ? local.durationMs : remote.durationMs,
      // 进度与观看时间必须**同一侧**取：混着来会出现"3 分钟前看到第 40 分钟"
      // 这种用远程时间配本机进度的错位
      positionMs: remoteNewer ? remote.positionMs : local.positionMs,
      watchedAt: remoteNewer ? remote.watchedAt : local.watchedAt,
      pages: local.pages ?? remote.pages,
      pubdate: local.pubdate ?? remote.pubdate,
      source: HistorySource.both,
      // 白名单归属只信远程（见 mergeRemote 规则 6）
      inWhitelist: remote.inWhitelist,
    );
  }

  /// 上次从 B 站同步成功的时间（从没同步过 / 读失败 → null）。
  Future<DateTime?> readLastSyncAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastSyncKey);
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// 记一次同步成功的时间（写失败静默：只是界面少显示一行，不影响历史本身）。
  Future<void> saveLastSyncAt(DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastSyncKey, at.toIso8601String());
    } catch (_) {
      // 写失败静默
    }
  }

  /// watchedAt 倒序比较：解析失败（脏数据）视为最旧，排最后。
  static int _compareWatchedAtDesc(HistoryEntry a, HistoryEntry b) {
    return b.watchedAt.compareTo(a.watchedAt);
  }
}

/// 一次合并的计数（新增 / 更新；本机独有条目不参与计数）。
class HistoryMergeResult {
  final int added;
  final int updated;

  const HistoryMergeResult({required this.added, required this.updated});

  int get total => added + updated;
}
