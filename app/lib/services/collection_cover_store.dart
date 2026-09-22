import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/whitelist_video.dart';

/// 「从相册选的本机封面」（v2.50.0）：**图片文件 + 合集路径 → 文件名 的映射**。
///
/// ## 为什么本机封面不能进 Gist
///
/// 白名单整份存 GitHub Gist 的一个文本 JSON 里，**每一次写操作都 PATCH 整份**
/// （改个合集名都要重传全部内容）。图片转 base64 进去会让每次写入膨胀到十几 MB
/// （过不了 Gist 单文件上限），本地绝对路径同样不行（换设备 / 重装后失效，
/// 而白名单是跟着 Gist 走的跨设备数据）。所以本机封面**完全走本地**：
///
/// - 图片文件：`<ApplicationSupport>/collection_covers/<时间戳>.<扩展名>`
///   （与 `video_cache/` / `updates/` / `audio_tmp/` 同一条既有约定）；
/// - 映射：shared_preferences 里**一个 key** 存整张 JSON 表
///   （`合集完整路径 → 文件名`），不进 Gist、不发任何网络请求；
/// - Gist 里的 `cover` 字段语义**完全不变**（仍是可同步的 URL）；
/// - 渲染优先级：**本机封面 > Gist `cover` > 合集内首个视频封面 > 占位**
///   （见 `playlist_page.dart` 的 `_cards()` 与 `collection_page.dart` 的
///   `_subCard()`）。
///
/// 存的是**文件名**而不是绝对路径：Android 上 `files/` 目录在重装 / 迁移后
/// 可能变（备份恢复、用户换存储），文件名 + 现算的根目录才不会因路径漂移而
/// 集体失效。
///
/// ## 元数据搬迁（这是本类最容易漏的一环）
///
/// 合集的身份 = **完整路径字符串**（[kCollectionSep]），而本机封面的 key 用的
/// 也是这个路径 —— 所以**任何改路径的操作都必须同步搬 key**
/// （[rebaseLocalCovers]，删除合集还要 [removeLocalCover] 连文件一起清）。
/// 落点（6 处，页面层调用）：
/// - 首页：`_renameCollection` / `_deleteCollection` / `_moveCollectionUnder`；
/// - 合集页：`_renameSubCollection` / `_deleteSubCollection` / `_moveSubCollection`。
/// 同级重排（[reorderCollections]）不改任何路径 → **不需要搬迁**（顺序变了而已）。
///
/// 读失败 / 存储异常一律静默降级（返回 null / 不动内存），与 [ThemeStore] /
/// [SearchHistoryStore] 同风格：本机封面是锦上添花，不该因为本地存储出问题
/// 让合集列表打不开。
class CollectionCoverStore {
  /// shared_preferences 存储 key（值为一个 JSON 对象：`{"合集路径": "文件名"}`）。
  static const String storageKey = 'collection_covers';

  /// 图片文件目录名（`<ApplicationSupport>/collection_covers/`）。
  static const String dirName = 'collection_covers';

  /// 全局单例（页面直接用它取当前映射）。
  static final CollectionCoverStore instance = CollectionCoverStore._();

  CollectionCoverStore._();

  /// 测试注入：根目录（null → path_provider 的应用支持目录）。
  ///
  /// 与 `DownloadManager` / `UpdateService` 的 `rootDirOverride` 同一条约定：
  /// widget / 单元测试里给一个临时目录就能真跑「写文件 → 读回来」，
  /// 不必依赖原生插件。
  @visibleForTesting
  Directory? rootDirOverride;

  /// 合集路径 → 图片文件名（内存态，[ensureLoaded] 之后以它为准）。
  Map<String, String> _byPath = {};

  /// 解析出来的根目录（拿不到 → null：本机封面功能整体不可用，不影响其它）。
  Directory? _root;

  /// 首次加载的 future（并发调用共享同一次读取）。
  Future<void>? _loading;

  @visibleForTesting
  Map<String, String> get debugMapping => Map.unmodifiable(_byPath);

  /// 读一次映射（幂等；并发调用共享同一次加载）。
  ///
  /// 页面在 `initState` 里 `unawaited(...)` 调用即可，读完 [notifyListeners] 不
  /// 需要 —— 页面自己 `setState` 刷新一次就行（本类故意**不是**
  /// [ChangeNotifier]：只有合集页 / 首页两处消费，一个全局通知器反而是多余
  /// 的耦合）。
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    // 先定根目录：拿不到（原生插件缺失 / 测试环境）就当作「没有本机封面」，
    // 但**映射照样读**——换设备恢复备份后根目录会变，映射本身仍有效。
    try {
      _root = rootDirOverride ?? await getApplicationSupportDirectory();
    } catch (_) {
      _root = rootDirOverride;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      // 脏数据（手改坏的 JSON、非字符串值、空文件名）一律丢掉，不让它炸掉
      _byPath = {
        for (final e in decoded.entries)
          if (e.key is String &&
              e.value is String &&
              (e.value as String).isNotEmpty)
            e.key as String: e.value as String,
      };
    } catch (_) {
      _byPath = {};
    }
  }

  /// 合集 [collectionPath] 的本机封面**绝对路径**；没有 / 文件已不在 → null。
  ///
  /// 「映射在但文件没了」（用户清过 App 缓存、手动删了文件）返回 null ——
  /// 调用方据此回落到 Gist `cover`，而不是画一块空白。
  ///
  /// 同步：卡片在 `build` 里逐张问它（几十次 `existsSync` 是微秒级的，
  /// 比为此把整份数据做成异步的代价小得多）。
  String? localCoverPath(String collectionPath) {
    final p = normalizeCollectionPath(collectionPath);
    if (p.isEmpty) return null;
    final name = _byPath[p];
    if (name == null) return null;
    final root = _rootOrOverride;
    if (root == null) return null;
    final file = File('${root.path}/$dirName/$name');
    return file.existsSync() ? file.path : null;
  }

  /// 根目录：测试注入优先，其次 [initState] 阶段解析出来的那个。
  Directory? get _rootOrOverride => rootDirOverride ?? _root;

  /// 存一张本机封面（覆盖该合集已有的那张）：写文件 → 换映射 → 删旧文件。
  ///
  /// 返回新文件名（失败 → null，调用方按「没存上」处理，不崩）。
  /// [fileName] 只用来取扩展名（相册给的显示名；`Image.file` 按内容识别格式，
  /// 扩展名只是为了文件管理器里看着正常）。
  Future<String?> saveLocalCover(
    String collectionPath,
    Uint8List bytes, {
    String fileName = '',
  }) async {
    final p = normalizeCollectionPath(collectionPath);
    if (p.isEmpty || bytes.isEmpty) return null;
    await ensureLoaded();
    final root = _rootOrOverride;
    if (root == null) return null;
    try {
      final dir = Directory('${root.path}/$dirName');
      dir.createSync(recursive: true);
      final old = _byPath[p];
      // 文件名带微秒时间戳：同名覆盖不会串台，也不需要先删旧文件
      final name = '${DateTime.now().microsecondsSinceEpoch}'
          '${_extensionOf(fileName)}';
      // 文件读写刻意用**同步** API（`writeAsBytesSync` / `deleteSync`）：
      // 上限 10 MB 的一次性写入在这条路径上是几十毫秒的事，而异步 I/O 在
      // `flutter test` 的 fake-async 环境里**永远不会完成**（真实事件循环不
      // 转），那样 widget 测试就没法真跑「选图 → 保存」这条链路，只能整条打桩
      // —— 而这条链路恰恰是本次新增的、最该被真跑一遍的部分。
      File('${dir.path}/$name').writeAsBytesSync(bytes, flush: true);
      _byPath[p] = name;
      await _persist();
      // 旧文件已经没人引用了 → 顺手删掉（失败不影响本次保存）
      if (old != null && old != name) {
        try {
          File('${dir.path}/$old').deleteSync();
        } catch (_) {}
      }
      return name;
    } catch (_) {
      return null;
    }
  }

  /// 移除 [collectionPath] 的本机封面（映射 + 文件）。
  ///
  /// 移除后卡片自然回落到 Gist `cover`（URL 字段一直没动过，所以「先选本机图
  /// 再移除」不会把用户填的 URL 一起弄丢）。
  ///
  /// **同步**（内存 + 文件；prefs 落盘后台做，失败静默）：调用它的地方都是
  /// 「删合集 / 关对话框」这类紧接着还要刷新界面、弹提示的流程，中间插一个
  /// 网络无关的 await 只会让提示晚到（`flutter test` 的 fake-async 下异步 I/O
  /// 更是永远不返回）。根目录还没解析出来时（理论上只有页面首帧前才会发生）
  /// 只丢映射、文件留成孤儿——下次启动 `ensureLoaded` 也不会再引用它。
  void removeLocalCover(String collectionPath) {
    final p = normalizeCollectionPath(collectionPath);
    if (p.isEmpty) return;
    final name = _byPath.remove(p);
    if (name == null) return;
    unawaited(_persist());
    final root = _rootOrOverride;
    if (root == null) return;
    try {
      File('${root.path}/$dirName/$name').deleteSync();
    } catch (_) {
      // 文件已经不在 / 删不掉：映射已经没了，卡片会回落 URL，无需打扰用户
    }
  }

  /// 路径搬迁：把 `[from]` 自身（[includeSelf] 时）与它**所有子孙**的映射，
  /// 按前缀换成 `[to]`。
  ///
  /// 三种场景共用同一套前缀替换（与模型层 `_rebasePath` 完全同规则）：
  /// - **重命名**：`动画` → `番剧`（自身 + 子孙）；`动画` → `番剧` 时
  ///   `动画/2024冬` → `番剧/2024冬`；
  /// - **移动**（嵌套到别的合集 / 移回顶层）：`动画` → `音乐/动画`；
  /// - **删除**：[includeSelf] = false —— 被删的那个合集的封面要**丢掉**
  ///   （见 [removeLocalCover]），它的子孙则上提一级（`甲/乙/丙` → `甲/丙`）。
  ///
  /// [to] 为空串 = 收到顶层（`甲/乙` → `乙`）。没有一条映射命中时什么都不做
  /// （不产生一次无谓的 prefs 写入）。
  ///
  /// **同步**（只改内存映射；prefs 落盘后台做，失败静默）：调用它的地方紧跟
  /// 着就要弹「已移动 / 已改名」提示并刷新界面，不该为一个本机映射多欠一次
  /// await。前提是 [ensureLoaded] 已经跑过（页面 `initState` 就发起，用户来得及
  /// 操作时必然已加载完）；还没加载完时映射表为空 → 本次搬迁是空操作，
  /// 不会写坏任何东西。
  void rebaseLocalCovers(
    String from,
    String to, {
    bool includeSelf = true,
  }) {
    final f = normalizeCollectionPath(from);
    if (f.isEmpty) return;
    final t = normalizeCollectionPath(to);
    if (_byPath.isEmpty) return;
    final next = <String, String>{};
    var changed = false;
    for (final e in _byPath.entries) {
      final key = e.key;
      final isSelf = key == f;
      final isUnder = key.startsWith('$f$kCollectionSep');
      if (!isSelf && !isUnder) {
        next[key] = e.value;
        continue;
      }
      changed = true;
      if (isSelf) {
        // 被删掉的合集：映射直接丢弃（includeSelf=false）；否则换成新路径
        if (includeSelf && t.isNotEmpty) next[t] = e.value;
        continue;
      }
      final tail = key.substring(f.length); // 以 `/` 开头的一段，如 `/2024冬`
      if (t.isEmpty) {
        // 收到顶层：去掉那一个分隔符，`甲/乙/丙` → `丙`
        final top = tail.substring(1);
        if (top.isNotEmpty) next[top] = e.value;
      } else {
        next['$t$tail'] = e.value;
      }
    }
    if (!changed) return;
    _byPath = next;
    unawaited(_persist());
  }

  /// 测试用：清回「没加载过」的初始态（含 [rootDirOverride]）。
  @visibleForTesting
  void resetForTest() {
    _byPath = {};
    _root = null;
    _loading = null;
    rootDirOverride = null;
  }

  /// 落盘映射（失败静默：本次内存已生效，下次启动回到上次成功保存的值）。
  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(_byPath));
    } catch (_) {}
  }

  /// 从相册给的显示名里取扩展名；不认识就 `.jpg`（缺省扩展名，看图工具友好）。
  static String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '.jpg';
    final ext = fileName.substring(dot + 1).toLowerCase();
    const known = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'};
    return known.contains(ext) ? '.$ext' : '.jpg';
  }
}
