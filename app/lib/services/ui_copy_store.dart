import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 空态 / 加载态 / 错误态的文案库（可在设置页编辑）。
///
/// 分两层：
/// - **出厂默认** [kDefaultCopies]：与既有页面文案**逐字一致**（大量 widget
///   测试用 `find.text('暂无历史记录')` 这类断言锚定，改一个字就会红）；
/// - **用户覆盖**：shared_preferences 单 key JSON（[storageKey]），只存被改过
///   的条目，没改过的走默认。
///
/// 读取是**同步**的（[text]）：UI 里直接 `UiCopyStore.instance.text('empty.history')`
/// 不会闪一下；异步的 [ensureLoaded] 在 App 启动时调一次把覆盖读进来，
/// 读完 `notifyListeners()`，正在监听的状态组件会自己刷新。
///
/// 容错风格沿用 `services/history_store.dart` / `services/search_history_store.dart`：
/// 读失败 → 用默认、写失败 → 静默跳过，不崩、不影响主流程。
///
/// 「有趣」的余地放在**副文案**（`xxx.sub`）与插画上：主标题是测试断言锚点，
/// 必须逐字保留；副文案没有断言锚点，可以自由发挥（也激励用户去设置页改）。
class UiCopyStore extends ChangeNotifier {
  /// shared_preferences 存储 key（JSON 对象：id → 覆盖文案）。
  static const String storageKey = 'ui_copy:overrides';

  /// 全局单例（设置页写、状态组件读，共用一份）。
  static final UiCopyStore instance = UiCopyStore._();

  UiCopyStore._();

  Map<String, String> _overrides = {};
  bool _loaded = false;

  /// 出厂默认文案表。
  ///
  /// id 命名约定：`<区域>.<状态>[.<细分>]`；副文案统一是 `<主 id>.sub`。
  /// - `empty.*`：空态（**本期每个值都与既有页面文案逐字一致**）
  /// - `footer.*`：分页到底 / 列表尾部占位
  /// - `loading.*` / `error.*`：加载与错误（新增，无历史锚点，可自由发挥）
  ///
  /// 带 `.sub` 的条目是「副文案」：主标题照抄旧文案，副文案才是可以皮一下
  /// 的地方（用户也能在设置页改成自己的话）。
  static const Map<String, String> kDefaultCopies = {
    // ---------- 白名单 / 首页（playlist_page） ----------
    'empty.playlist': '白名单为空\n下拉刷新重新同步',
    'empty.playlist.upowner': '还没有白名单 UP 主',
    'empty.syncing': '正在同步白名单…',

    // ---------- 合集 ----------
    'empty.collection': '暂无合集',
    'empty.collection.sub': '新建一个合集，把想连着看的分到一起',

    // ---------- 历史 ----------
    'empty.history': '暂无历史记录',
    'empty.history.sub': '看过的视频会出现在这里，点击可续播',
    'empty.daily_history': '该日无观看记录',

    // ---------- 观看热力 ----------
    'empty.watch_heat': '开始观看后这里会生成你的观看热力',
    'empty.watch_heat.sub': '播放时按真实播放秒数累计（缓冲/跳转不计），按天本地保存',

    // ---------- 收藏夹 ----------
    'empty.favorites': '还没有收藏夹。\n在 B 站收藏想看的视频后，这里就能直接点开看',
    'empty.favorite_videos': '这个收藏夹还没有视频。\n（收藏的合集 / 剧集等非视频内容，本版暂不展示）',
    'empty.favorite_search': '未找到匹配的视频',
    'empty.favorite_search.sub': '换个关键词，或清空搜索框看全部',

    // ---------- 搜索 ----------
    'empty.search': '输入关键词，搜索 B 站全网视频\n结果可一键加入白名单（加入前会查重）',
    'empty.search.result': '没有找到相关视频，换个关键词试试',
    'empty.search.whitelist': '白名单加载失败或暂无数据\n请确认网络后重新进入搜索页',
    'empty.search.whitelist.filter': '白名单里没有匹配的视频',

    // ---------- 收件箱 ----------
    'empty.inbox': '暂未有白名单 UP 主的新视频\n在「搜索」→「搜索 UP 主」中加入 UP 主后，\nTA 发布的新视频会出现在这里',

    // ---------- 评论 ----------
    'empty.comment': '暂无评论',
    'empty.comment.sub': '第一条评论，要不要留给你？',

    // ---------- 缓存 ----------
    'empty.cache': '暂无缓存',
    'empty.cache.sub': '在播放页点「下载」，出门没网也能看',
    'empty.cache.desc': '暂无缓存视频（在播放页点「下载」即可离线观看）',

    // ---------- 关注导入 ----------
    'empty.followings': '这个账号还没有关注任何 UP 主\n（或关注列表未公开）',

    // ---------- UP 主主页 ----------
    'empty.upowner_videos': '暂无视频',
    'empty.upowner.season': '该合集暂无视频',
    'empty.upowner.list': '该列表暂无视频',

    // ---------- 列表尾部 / 分页到底 ----------
    'footer.no_more': '没有更多了',
    'footer.hot_only': '未登录仅展示热门评论，登录后可查看全部',

    // ---------- 加载 / 错误（新增文案，无历史锚点） ----------
    'loading.generic': '正在加载…',
    // 错误态兜底：与既有页面的通用网络错误文案逐字一致
    // （`favorites_page.dart` / `favorite_videos_page.dart`），
    // P4b 换成 AppErrorView 时不传 message 也保持同一句话。
    'error.generic': '网络请求失败，请检查网络后重试',

    // ---------- 加载文案池（新增；既有 loading.generic 的值 '正在加载…' 不动） ----------
    // 池的 key 清单与挑选逻辑在 `lib/services/loading_copy.dart`；
    // 这些是"等人时的一句闲话"，与上面的 loading.generic（状态说明）分工不同。
    'loading.line.1': '人生有时就得管没有肉的青椒肉丝，叫青椒肉丝。',
    'loading.line.2': '慢一点就慢一点，反正也追不上。',
    'loading.line.3': '泡面要等三分钟，这个也差不多。',
    'loading.line.4': '信号在楼下抽烟，还没上来。',
    'loading.line.5': '等它的时候，可以想想晚饭。',
    'loading.line.6': '生活总在缓冲，我们习惯了。',
    'loading.line.7': '烟抽完了，页面就来了。',
    'loading.line.8': '再等一下，就快到那个有意思的地方了。',

    'footer.loading.1': '冰箱里还有半盒酸奶，别急。',
    'footer.loading.2': '山高水长，网速有限。',
    'footer.loading.3': '先把茶泡上，回来就有了。',
    'footer.loading.4': '别催，它也在努力。',

    'loading.empty.1': '这一刻的空白，是免费的。',
    'loading.empty.2': '该来的会来，包括这个页面。',
    'loading.empty.3': '适当地发呆，是一种修养。',
  };

  /// 取文案：覆盖 → 默认 → **原样返回 id**（不认识的 id 当占位符用，
  /// 让 P4b 接线时漏配的 id 在界面上显形，而不是静默变成空白）。
  String text(String id) {
    final override = _overrides[id];
    if (override != null && override.isNotEmpty) return override;
    return kDefaultCopies[id] ?? id;
  }

  /// 是否有用户覆盖（设置页「已改」标记用）。
  bool hasOverride(String id) => (_overrides[id] ?? '').isNotEmpty;

  /// 从磁盘读一次覆盖表；重复调用只在首次真正读盘。读失败 → 视为无覆盖。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _overrides = _read(prefs);
    } catch (_) {
      // 存储异常：当作没改过，全部走默认
      _overrides = {};
    }
    _loaded = true;
    notifyListeners();
  }

  /// 改一条（[value] trim 后为空 = 删掉这条覆盖、回到默认）。
  ///
  /// 先改内存（UI 立刻生效）再写盘；写盘失败静默（下次启动回落默认，
  /// 与既有 Store 的取舍一致）。
  Future<void> setOverride(String id, String value) async {
    final v = value.trim();
    if (v.isEmpty) return clearOverride(id);
    _overrides[id] = v;
    notifyListeners();
    await _persist();
  }

  /// 删掉一条覆盖（回到出厂默认）。
  Future<void> clearOverride(String id) async {
    if (_overrides.remove(id) == null) return;
    notifyListeners();
    await _persist();
  }

  /// 清空全部覆盖（全部回到出厂默认）。
  Future<void> resetAll() async {
    _overrides = {};
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {
      // 清空失败静默
    }
  }

  /// 测试专用：重置内存状态。
  ///
  /// - 传 [overrides] → 直接当作内存覆盖（`_loaded = true`，免得随后的
  ///   读盘把它冲掉）；
  /// - 不传 → `_loaded = false`，下一次 [ensureLoaded] 会**重新读盘**，
  ///   用于验证「重启后回读同一份存储」。
  @visibleForTesting
  void resetForTest([Map<String, String>? overrides]) {
    _overrides = {...?overrides};
    _loaded = overrides != null;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(_overrides));
    } catch (_) {
      // 写入失败静默（内存里已经生效，本次会话正常）
    }
  }

  /// 读盘并清洗：非对象 / 非字符串值 / 空 id / 空文案一律丢弃。
  /// **不抛异常**（损坏数据要能自愈，否则外面的 catch 会把它吞成永久损坏）。
  Map<String, String> _read(SharedPreferences prefs) {
    final out = <String, String>{};
    try {
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return out;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return out;
      decoded.forEach((key, value) {
        if (key is! String || value is! String) return;
        final id = key.trim();
        final v = value.trim();
        if (id.isEmpty || v.isEmpty) return;
        out[id] = v;
      });
    } catch (_) {
      return {};
    }
    return out;
  }
}
