import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';

/// 书源存储（R1 新增）：书源列表落本地 SharedPreferences，**不进 Gist**。
///
/// 为什么不进 Gist：书源是阅读器的私货（有的人一次导 200 个源），跟白名单
/// 的同步节拍完全不同；混进同一条 Gist 会让「改一个书源」触发白名单那边的
/// 冲突合并。本机独享、换机自己再导一遍，是更省事的分界。
///
/// 写法照 `services/search_history_store.dart` 的成熟套路：
/// - 单 key 存一整份 JSON（[storageKey]），**不做多 key 分片** —— 书源数量
///   有 [maxSources] 上限，一次读写整份最省事且天然原子；
/// - 读失败 / 脏数据（非对象、缺 name 或 baseUrl）逐条跳过，绝不抛异常；
/// - 写失败静默返回 false，UI 层弹提示（不该因为写盘挂了就崩页面）。
class BookSourceStore {
  /// 书源数量上限。
  ///
  /// 超出时**拒绝整次写入并返回 false**（而不是悄悄丢掉最早那条）：
  /// 用户导的是一个书源包，静默截断会让人以为导全了，而实际少了一截且
  /// 找不回来；拒绝 + 提示「上限 200」至少是可理解的失败。
  static const int maxSources = 200;

  /// shared_preferences 存储 key（JSON 数组）。
  static const String storageKey = 'reader:sources';

  /// 「待下载的索引链接」存储 key（R1 只存不下载，R2/R3 才真去拉）。
  ///
  /// 为什么单独存：用户贴进来的是「书源合集索引」（一个 .json 里列着几十个
  /// 书源地址），R1 没有网络抓取能力，但不能让这条输入凭空消失 —— 存起来，
  /// 下一版接着用。
  static const String indexUrlsKey = 'reader:index_urls';

  /// 全局单例（阅读页 / 管理页共用一份）。
  static final BookSourceStore instance = BookSourceStore();

  /// 公开构造：便于测试新建实例模拟「重启后重读同一份存储」。
  BookSourceStore();

  /// 读取全部书源（保持存储顺序）；空 / 损坏返回空列表。
  Future<List<BookSource>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _read(prefs);
    } catch (_) {
      // 读取失败（存储异常等）：视为没有书源
      return const [];
    }
  }

  /// 批量合并写入：按 [BookSource.key] 同名覆盖、新名追加；返回是否落盘成功。
  ///
  /// 合并而不是整体替换：导入通常是「再补几个源」，整体替换会把用户已有的
  /// 源清空 —— 那是不可接受的破坏性行为。要清空请逐个 [remove]。
  Future<bool> upsertAll(List<BookSource> incoming) async {
    if (incoming.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = _read(prefs);
      // 保持插入顺序：先按现有顺序走一遍，同名就地覆盖；新名追加到尾部
      final merged = <String, BookSource>{
        for (final s in current) s.key: s,
      };
      for (final s in incoming) {
        merged[s.key] = s;
      }
      final next = merged.values.toList();
      if (next.length > maxSources) return false;
      return _write(prefs, next);
    } catch (_) {
      // 写入失败（存储异常等）：静默，调用方按返回值弹提示
      return false;
    }
  }

  /// 按名字（大小写不敏感）删除一个书源；不存在也算成功（幂等）。
  Future<bool> remove(String name) async {
    final key = name.toLowerCase();
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = _read(prefs);
      final next = [
        for (final s in current)
          if (s.key != key) s,
      ];
      if (next.length == current.length) return true;
      return _write(prefs, next);
    } catch (_) {
      return false;
    }
  }

  /// 切换某个书源的启用状态；不存在返回 false。
  Future<bool> setEnabled(String name, bool enabled) async {
    final key = name.toLowerCase();
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = _read(prefs);
      var hit = false;
      final next = <BookSource>[];
      for (final s in current) {
        if (s.key == key) {
          hit = true;
          next.add(s.copyWith(enabled: enabled));
        } else {
          next.add(s);
        }
      }
      if (!hit) return false;
      return _write(prefs, next);
    } catch (_) {
      return false;
    }
  }

  /// 记录一批「索引链接」（去重、保持先后）；返回落盘是否成功。
  ///
  /// R1 只存不用：管理页在「从链接导入」里识别到索引链接时落这里，
  /// R2 实现网络下载后直接从这里接上，不会丢用户已经粘过的输入。
  Future<bool> saveIndexUrls(List<String> urls) async {
    if (urls.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getStringList(indexUrlsKey) ?? const <String>[];
      final seen = current.toSet();
      final next = [
        ...current,
        for (final u in urls)
          if (seen.add(u)) u,
      ];
      return prefs.setStringList(indexUrlsKey, next);
    } catch (_) {
      return false;
    }
  }

  /// 读回待下载的索引链接（R1 暂无消费方，留给 R2/R3）。
  Future<List<String>> getIndexUrls() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(indexUrlsKey) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  // ==================== 内部：读写 / 容错 ====================

  List<BookSource> _read(SharedPreferences prefs) {
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    final decoded = _decodeLenient(raw);
    if (decoded is! List) return const [];
    final out = <BookSource>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      final src = BookSource.fromJson({
        for (final kv in e.entries) kv.key.toString(): kv.value,
      });
      // 脏数据过滤：name / baseUrl 缺一个留着也没用 —— 没名字管理页会显示成
      // 空白行且永远匹配不到站点；没 baseUrl 的源导入后每次搜索都必然报
      // 「地址拼不出来」，等于一个只会招人烦的空壳。baseUrl 顺手 trim：
      // 手抄 JSON 里写成一串空格的同样拼不出地址。
      if (src.name.isEmpty || src.baseUrl.trim().isEmpty) continue;
      out.add(src);
    }
    return out;
  }

  /// 解析整份存储；坏数据返回 null（**不抛**）。
  Object? _decodeLenient(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _write(SharedPreferences prefs, List<BookSource> list) async {
    try {
      final encoded = jsonEncode([for (final s in list) s.toJson()]);
      return await prefs.setString(storageKey, encoded);
    } catch (_) {
      return false;
    }
  }
}
