import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/bilibili_api.dart';
import '../models/whitelist_video.dart';

/// B 站「稍后再看」：**账号那份为准**的读 + 加 + 删（v2.58.0+）。
///
/// ## 为什么没有"本地副本"
/// 产品口径（用户要的「双向同步」）= 这个列表**始终就是账号里那份**：
/// App 只读它、只往它里加一条/删一条，不在本机另存一份。理由是别让两边打架：
/// 一旦本地也存，用户在网页端加/删之后，App 那份立刻是错的，而"谁赢了"这种
/// 冲突没有任何便宜又正确的收敛办法（时间戳？手动合并？都过重）。
/// 所以：**打开页面重新拉一次**就是同步，没有定时轮询、没有后台对账。
///
/// ## 接口形状（2026-11 探针；每条都标出处）
///
/// | 动作 | 端点 | 参数 |
/// |------|------|------|
/// | 读全量 | `GET /x/v2/history/toview` | 无（**没有** `pn`/`ps`） |
/// | 加入 | `POST /x/v2/history/toview/add` | `aid` **或** `bvid` + `csrf` |
/// | 移除 | `POST /x/v2/history/toview/del` | `aid` + `csrf` |
///
/// - **实测**（2026-11，本机匿名直连、不带任何凭据、带浏览器头与 Referer）：
///   - `GET .../toview` → `{"code":-101,"message":"账号未登录"}`；
///   - `POST .../toview/add`（`aid=170001`）→ 同上 -101；
///   - `POST .../toview/del`（`aid=170001&csrf=x`）→ 同上 -101。
///   → 三条都**必须登录**；未登录给可读提示，且读方向在发请求前就在本机拦下
///   （见 [BiliApi.fetchToViewList]）。真·登录态的返回体**本机无凭据，未实测**。
/// - **文档**（`bilibili-API-collect` 的 `docs/historytoview/toview.md`，本机
///   raw.githubusercontent 被墙，走 GitHub API 取的同一份文件）：
///   - 列表：`data{count, list[]}`；条目字段 `aid` / `bvid` / `cid` / `title` /
///     `pic` / `duration`（秒，全部分 P 总时长）/ `progress`（秒）/ `add_at`
///     （时间戳）/ `owner{mid,name}` / `page{cid,page,part}` / `videos`（分 P
///     总数）/ `count`（分 P 数，非投稿视频无此项）；
///   - 加入：`aid` 与 `bvid` **任选一个**，`csrf` 必要；错误码 `0` / `-101`
///     / `-111` / `-400` / **`90001` 列表已满** / **`90003` 稿件已删除**；
///     文档另注明「最多添加 100 个视频」；
///   - 移除：`aid` 单条，或 `viewed=true` 删所有已看过的（本版**不接**批量）；
///   - 清空：`POST .../toview/clear`（本版**不接**：一次抹掉全部，误触代价太大）。
/// - **推断**（无凭据无法实测，代码里都做了容错）：
///   - **不分页**：文档没有分页参数，加上 100 条上限，一次 GET 即全量。若真机
///     上 `data.count > list.length`，页面照实说明"只拿到 N 条"，不假装全了；
///   - `page.page` 是**1 基**的分 P 序号（文档只写"分 P 序号"）；解析成 0 基
///     下标时 `-1` 并夹到 ≥0；
///   - `cid` 有个别条目为 0（文档示例里就有一条 `"cid": 0`）→ 用
///     `page.cid` 兜底；两者都没有时播放页会自己按 bvid 补元数据，不影响点播；
///   - **要不要 `buvid3`**：文档对这三条没提（一键三连那种才明说"需验证
///     `buvid3`"）。本 App 的 [_injectAuth] 本来就会带上 buvid3/buvid4 指纹，
///     这条不做额外处理；
///   - **重复加入**的行为未实测（文档没有"已存在"码）→ 只认 `code=0` 为成功，
///     不做"看起来像成功"的猜测。
///
/// ## 不做的事
/// - **不自动轮询**、不在后台对账：这是"用户点开才拉"的列表；
/// - **不做本地存档**（见上）；
/// - **不改白名单**：加入稍后再看不写 Gist、不动白名单那份数据。

/// 稍后再看条目（`data.list[]` 的解析结果）。
///
/// 容错原则与 [RemoteHistoryItem] 一致：**任何字段缺失/脏类型都不抛**，缺了
/// 就用"未知"（0 / 空串）——接口一处改名不能把整页打挂。
@immutable
class ToViewItem {
  /// 稿件 avid（**移除时唯一的凭据**；`del` 只认 aid）。
  final int aid;

  /// 稿件 bvid（点播用；理论上必有，脏数据可能为空）。
  final String bvid;

  /// 分 P 的 cid（点播用；0 = 未知，播放页会自己补元数据）。
  final int cid;

  /// 分 P 序号（**推断 1 基**，见文件头；0 = 未知）。
  final int page;

  /// 分 P 总数（`videos` 优先，退 `count`；0 = 未知）。
  final int pageCount;

  /// 标题（已去掉可能夹带的高亮标签）。
  final String title;

  /// 封面（`pic`）。
  final String cover;

  /// UP 主名（`owner.name`）。
  final String upName;

  /// 全部分 P 的总时长（**秒**；未知 = 0）。
  final int durationSec;

  /// 上次看到的位置（**秒**；0 = 还没看过）。
  final int progressSec;

  /// 加入稍后再看的时间（**秒级 Unix 时间戳**；0 = 未知）。
  final int addAtSec;

  const ToViewItem({
    required this.aid,
    required this.bvid,
    required this.cid,
    required this.page,
    required this.pageCount,
    required this.title,
    required this.cover,
    required this.upName,
    required this.durationSec,
    required this.progressSec,
    required this.addAtSec,
  });

  /// 播放页要的分 P 下标（0 基）：`page - 1`，未知/脏值一律 0。
  int get pageIndex => page > 0 ? page - 1 : 0;

  /// 有没有"上次看到的位置"可展示（0 = 没看过 / 未知）。
  bool get hasProgress => progressSec > 0;

  /// 能不能点播（有 bvid 才有可播对象）。
  bool get canPlay => bvid.isNotEmpty;

  /// 能不能移除（`del` 只认 aid）。
  bool get canRemove => aid > 0;

  /// 加入时间的可显示值（0/脏值 → null，调用方整段不显示）。
  DateTime? get addedAt {
    if (addAtSec <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(addAtSec * 1000);
  }

  @override
  String toString() =>
      'ToViewItem($bvid aid=$aid p=$page progress=$progressSec '
      'add_at=$addAtSec)';
}

/// 一次读全量的结果（条目 + 服务端说的总数）。
@immutable
class ToViewList {
  final List<ToViewItem> items;

  /// `data.count`（服务端说的总数；列表为空时 0）。
  ///
  /// 与 `items.length` 不等 = 服务端只下发了一部分（[truncated]）：页面照实
  /// 说明，不假装已拿全（推断部分见文件头）。
  final int count;

  const ToViewList({required this.items, required this.count});

  static const ToViewList empty = ToViewList(items: [], count: 0);

  /// 服务端说有更多条目，但这次没下发（超过单次返回上限 / 逐页下发的未来形态）。
  bool get truncated => count > items.length;
}

int _intOf(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

String _strOf(Object? raw) {
  if (raw is String) return raw;
  return '';
}

/// 去掉 B 站标题里可能夹带的尖括号标签（复用历史那条同款规则），并清两端空白。
String _stripTags(String raw) {
  if (!raw.contains('<')) return raw.trim();
  return raw.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

/// 解析稍后再看列表响应（`data` 对象；纯函数，可单测）。
///
/// 容错：
/// - `data` 为 null / 不是 Map → 空列表；
/// - `list` 缺失 / 非数组 → 空列表；
/// - 单条不是 Map → 跳过该条，**不影响同页其它条**；
/// - **`bvid` 与 `aid` 都拿不到** → 跳过：既播不了也删不掉，留着只能让人点了
///   没反应（这是唯一会"丢条目"的情形，其余脏字段都按 0/空串保留）。
ToViewList parseToViewList(Map<String, dynamic>? data) {
  if (data == null) return ToViewList.empty;
  final rawList = data['list'];
  final items = <ToViewItem>[];
  if (rawList is List) {
    for (final e in rawList) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final owner = m['owner'] is Map
          ? Map<String, dynamic>.from(m['owner'] as Map)
          : const <String, dynamic>{};
      final page = m['page'] is Map
          ? Map<String, dynamic>.from(m['page'] as Map)
          : const <String, dynamic>{};
      final aid = _intOf(m['aid']);
      final bvid = _strOf(m['bvid']);
      if (aid <= 0 && bvid.isEmpty) {
        debugPrint('[bili_toview] 跳过一条既无 aid 又无 bvid 的记录');
        continue;
      }
      // cid：顶层的优先，个别条目顶层给 0（文档示例里就有）→ 用 page.cid 兜底
      final topCid = _intOf(m['cid']);
      final pageCid = _intOf(page['cid']);
      // 分 P 总数：videos 是"稿件分P总数"，count 是"稿件分P数"（非投稿视频无此项）
      final videos = _intOf(m['videos']);
      final counts = _intOf(m['count']);
      items.add(ToViewItem(
        aid: aid,
        bvid: bvid,
        cid: topCid > 0 ? topCid : pageCid,
        page: _intOf(page['page']),
        pageCount: videos > 0 ? videos : counts,
        title: _stripTags(_strOf(m['title'])),
        cover: _strOf(m['pic']),
        upName: _strOf(owner['name']),
        durationSec: _intOf(m['duration']),
        progressSec: _intOf(m['progress']),
        addAtSec: _intOf(m['add_at']),
      ));
    }
  }
  final count = _intOf(data['count']);
  return ToViewList(items: items, count: count > 0 ? count : items.length);
}

/// 稍后再看的异常 → 用户能读懂的失败原因（未登录 / 风控 / 网络 / 其它）。
///
/// 与 [historySyncErrorText] 同款分层；稍后再看多两个**文档专属码**
/// （90001 列表满 / 90003 稿件已删除）——[BiliApi._throwWriteError] 已经把
/// 它们翻成中文，这里的 default 分支会原样用它。
String toViewErrorText(Object error) {
  if (error is BiliApiException) {
    return switch (error.code) {
      -101 => '未登录或登录已失效，请先登录 B 站账号',
      -412 => '被 B 站风控拦截，请稍后再试',
      -352 || -509 => '请求过于频繁，请稍后再试',
      _ => error.message.isEmpty
          ? '稍后再看操作失败（code=${error.code}）'
          : error.message,
    };
  }
  // WbiKeyUnavailableException 等 DioException 子类都落到这里（网络层失败）
  if (error is DioException) return '网络请求失败，请检查网络后重试';
  return '稍后再看操作失败：$error';
}

/// 读一次全量的结果（`ok=false` 时 [items] 必为空，[error] 必有值）。
@immutable
class ToViewLoadResult {
  final bool ok;
  final List<ToViewItem> items;
  final int count;
  final String? error;

  const ToViewLoadResult({
    required this.ok,
    required this.items,
    required this.count,
    this.error,
  });

  const ToViewLoadResult.failure(String message)
      : ok = false,
        items = const [],
        count = 0,
        error = message;

  /// 服务端说有更多条目但这次没下发（页面照实提醒）。
  bool get truncated => count > items.length;
}

/// 一次写动作（加入 / 移除）的结果。
///
/// 为什么不用 `bool`：失败必须带**可读原因**（未登录 / 风控 / 列表满…），
/// 而"没收到响应"与"服务端拒绝"是两回事，不能都折成一个 false。
@immutable
class ToViewActionResult {
  final bool ok;
  final String? error;

  const ToViewActionResult.ok()
      : ok = true,
        error = null;

  const ToViewActionResult.failure(String message)
      : ok = false,
        error = message;
}

/// 稍后再看服务：把 [BiliApi] 的三个调用包成"永不抛 + 结果带可读原因"。
///
/// 依赖全部可注入（[fetchList] / [add] / [remove]），单测不发网络。
class BiliToViewService {
  /// 读全量（真实实现 = [BiliApi.fetchToViewList]）。
  final Future<Map<String, dynamic>> Function() fetchList;

  /// 加入（真实实现 = [BiliApi.addToView]）。
  final Future<void> Function({int? aid, String? bvid}) add;

  /// 移除（真实实现 = [BiliApi.delFromView]，只认 aid）。
  final Future<void> Function(int aid) remove;

  /// 生产构造：三条默认实现共用**同一个** [BiliApi]（会话内的 buvid 指纹 /
  /// WBI key 缓存都在它身上，各建一个等于每次请求都从零拿一次指纹）。
  factory BiliToViewService({
    BiliApi? api,
    Future<Map<String, dynamic>> Function()? fetchList,
    Future<void> Function({int? aid, String? bvid})? add,
    Future<void> Function(int aid)? remove,
  }) {
    final a = api ?? BiliApi();
    return BiliToViewService._(
      fetchList: fetchList ?? a.fetchToViewList,
      add: add ?? a.addToView,
      // `delFromView({required int aid})` 是具名参数，包一层适配位置参数
      remove: remove ?? ((aid) => a.delFromView(aid: aid)),
    );
  }

  const BiliToViewService._({
    required this.fetchList,
    required this.add,
    required this.remove,
  });

  /// 拉一次全量。**永不抛**：失败折成 [ToViewLoadResult.failure]。
  Future<ToViewLoadResult> load() async {
    try {
      final data = await fetchList();
      final parsed = parseToViewList(data);
      debugPrint('[bili_toview] 拉取成功 条目=${parsed.items.length} '
          'count=${parsed.count}');
      return ToViewLoadResult(
        ok: true,
        items: parsed.items,
        count: parsed.count,
      );
    } catch (e) {
      debugPrint('[bili_toview] 拉取失败: $e');
      return ToViewLoadResult.failure(toViewErrorText(e));
    }
  }

  /// 加入一条（[aid] / [bvid] 至少给一个）。**永不抛**。
  Future<ToViewActionResult> addVideo({int? aid, String? bvid}) async {
    if ((aid == null || aid <= 0) && (bvid == null || bvid.isEmpty)) {
      return const ToViewActionResult.failure('缺少稿件 id，无法加入稍后再看');
    }
    try {
      await add(aid: aid, bvid: bvid);
      debugPrint('[bili_toview] 已加入 aid=$aid bvid=$bvid');
      return const ToViewActionResult.ok();
    } catch (e) {
      debugPrint('[bili_toview] 加入失败: $e');
      return ToViewActionResult.failure(toViewErrorText(e));
    }
  }

  /// 移除一条（只认 aid）。**永不抛**。
  Future<ToViewActionResult> removeItem(int aid) async {
    if (aid <= 0) {
      return const ToViewActionResult.failure('这条记录缺少稿件 id（aid），'
          '无法从稍后再看移除');
    }
    try {
      await remove(aid);
      debugPrint('[bili_toview] 已移除 aid=$aid');
      return const ToViewActionResult.ok();
    } catch (e) {
      debugPrint('[bili_toview] 移除失败: $e');
      return ToViewActionResult.failure(toViewErrorText(e));
    }
  }
}

/// 稍后再看条目 → 可播放的 [WhitelistVideo]（纯函数，可单测）。
///
/// 为什么条目能直接当 [WhitelistVideo] 用：播放页本来只认 bvid + cid（搜索页 /
/// 评论跳转 / 历史页那条链路都是这么播的，**不写白名单**）。远程只给了"这一
/// 集"、没有整份分 P 列表，所以 `pages` 留 null —— 给个假列表反而会让集数 /
/// 单集时长全错；播放页拿 `initialPageIndex` 时会自己去补真列表。
///
/// `addedAt` 用加入稍后再看的时间填：它不是白名单的"加入时间"，但这条链路上
/// 唯一会读它的地方只是展示，填真实时间比留空更不容易出现"1970 年"。
WhitelistVideo videoFromToViewItem(ToViewItem item) => WhitelistVideo(
      bvid: item.bvid,
      cid: item.cid,
      title: item.title,
      cover: item.cover,
      duration: item.durationSec,
      upName: item.upName,
      addedAt: item.addedAt?.toIso8601String() ?? '',
      pages: null,
    );
