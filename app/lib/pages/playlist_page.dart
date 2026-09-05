import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../api/translate_api.dart';
import '../cache/download_manager.dart';
import '../config.dart';
import '../models/update_info.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/apk_installer.dart';
import '../services/service_locator.dart';
import '../services/update_service.dart';
import '../services/update_storage.dart';
import '../services/whitelist_writer.dart';
import '../utils/import_parser.dart';
import '../widgets/pgc_import_dialog.dart';
import 'collection_page.dart';
import 'history_page.dart';
import 'inbox_page.dart';
import 'login_page.dart';
import 'search_page.dart';
import 'update_dialog.dart';
import 'upowner_page.dart';

/// 唯一首页：合集卡片视图（两级导航第一级）。
///
/// - 每张卡片 = 一个合集（合集名 + 视频数 + 代表视觉）；「未分类」固定一张卡片
/// - 点卡片 → [CollectionPage] 合集视频列表页（两级导航第二级）；
///   长按/多选/移动/删除等管理操作迁移到合集页
/// - 卡片封面带防盗链头（Referer + 浏览器 UA，与 [CoverImage] 同约定）
/// - 下拉刷新触发重新同步；AppBar 下方显示缓存数据时间
/// - **新增白名单的入口**：导入（解析 B 站分享链接/文本，与电脑端油猴脚本
///   等价）+ 搜索页「加入」（搜 B 站全网后一键加入，M7）
/// - 管理功能仅限：新建/重命名/删除合集、移动/删除视频（防沉迷原则不变）
/// - 右上角搜索入口：B 站全网搜索 + 白名单内过滤两个 Tab
/// - 右上角导入入口：粘贴分享链接/文本（视频 BV/b23.tv 短链/完整链接；
///   番剧/电影 ep|ss 链接与 b23 番剧短码 → 整季逐集加入白名单，v2.16.2）
/// - 右上角管理入口：GitHub token/gist_id 配置 + 新建合集 + 合集管理
///   + 缓存管理 + 翻译服务配置 + **B 站账号**（登录/重新登录，v2.16.18）
/// - **启动自动登录**（v2.16.18，取代原右上角常驻登录按钮）：
///   SESSDATA 有效 → 静默恢复（不弹界面）；距过期 < 7 天 → refresh_token
///   静默续期；无 SESSDATA / 彻底过期 → 自动进入登录页引导登录一次；
///   登录成功自动保存，之后每次进入静默恢复
/// - **主页 PageView 三页**（初始停在主页合集页，左右滑动切换）：
///   右滑 → 历史记录页（播放历史，点击续播；顶部历史图标可直达）；
///   左滑 → 白名单 UP 主管理页
class PlaylistPage extends StatefulWidget {
  /// 测试注入：Gist 写操作替身（默认用真实实现）。
  /// 拖动排序/导入等写操作统一走 [GithubApi.saveToGist]。
  final GithubApi? github;

  /// 测试注入：登录页导航替身（默认推真实 [LoginPage]）。
  /// 无会话/会话过期自动引导与管理面板「登录/重新登录」统一走这里，
  /// 测试可注入替身记录"请求了登录"而不真推 LoginPage（WebView 构造
  /// 在测试环境会 assert 平台未注册）。
  final Future<void> Function(BuildContext context, {String? banner})?
      openLogin;

  const PlaylistPage({super.key, this.github, this.openLogin});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  WhitelistData _data = WhitelistData.empty();
  DateTime? _fetchedAt;
  String? _sourceName;
  String? _error;
  bool _syncing = false;
  late final GithubApi _github = widget.github ?? GithubApi();

  /// 白名单写入服务：导入 / 搜索「加入」共用（构造视频 + 查重 + 写 Gist）。
  final WhitelistWriter _writer = WhitelistWriter();

  /// 底部显示的版本号：优先 package_info_plus 读 Android versionName，
  /// 异常（测试环境无原生通道）时回退 config.dart 的 kAppVersion。
  String _version = kAppVersion;

  /// 信箱未读数（顶部 AppBar 红点用；0 = 不显示红点）。
  int _inboxUnseen = 0;

  /// 应用内版本更新服务（T3）。懒加载：仅首次检查时构造。
  UpdateService? _updateService;

  /// 启动 5s 后静默检查版本更新（T3）。
  Timer? _startupUpdateTimer;

  /// 启动 5 秒后触发信箱检查的定时器（dispose 时取消，避免测试报错）。
  Timer? _inboxCheckTimer;

  bool get _hasData => _data.videos.isNotEmpty;

  /// 主页 PageView（三页：历史记录 / 合集主页 / UP 主管理），初始停在主页。
  final PageController _pageController = PageController(initialPage: 1);

  /// 历史页 State 的全局 key：切到历史页时刷新数据（PageView 相邻页存活，
  /// 用户可能刚从别处播放回来，需要重新读表）。
  final GlobalKey<HistoryPageState> _historyKey = GlobalKey<HistoryPageState>();

  /// 顶部历史图标入口：动画切到历史页（第 0 页）。
  void _goToHistory() {
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 自动登录是否已引导（本次进程只自动引导一次，避免循环/重复弹页）。
  bool _autoLoginGuided = false;

  @override
  void initState() {
    super.initState();
    _load();
    _handleSessionOnStart();
    _loadVersion();
    // 启动 5s 后静默检查更新 + 信箱检查；两者都失败静默不打扰。
    _refreshInboxCount();
    _scheduleInboxCheck();
    _startupUpdateTimer = Timer(const Duration(seconds: 5), () {
      _silentCheckUpdate();
    });
  }

  @override
  void dispose() {
    _startupUpdateTimer?.cancel();
    _inboxCheckTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// 读取 App 版本号（插件方案，与 pubspec.yaml version 单源）。
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted && info.version.isNotEmpty) {
        setState(() => _version = info.version);
      }
    } catch (_) {
      // 无原生插件通道（测试环境等）时保持 kAppVersion 兜底值
    }
  }

  /// 启动自动登录（v2.16.18，App 启动 / 首页 initState 即触发，不依赖按钮）：
  ///
  /// - SESSDATA 有效（距过期 ≥ 7 天）→ 静默恢复，不弹任何界面；
  /// - 距过期 < 7 天（含已过期）→ 用 refresh_token 静默续期，成功即静默；
  ///   续期失败且**已过期** → 自动进入登录页引导重新登录；
  ///   续期失败但未过期 → 保留现会话（不打扰，过期时由下次启动引导）；
  /// - 无 SESSDATA（首次使用 / 已登出）→ 自动进入登录页引导登录一次
  ///   （提示条说明「登录后自动保存、下次进入自动恢复」）；
  /// - 存储读取异常（原生插件缺失 / Keystore 故障）→ 静默跳过，不误导登录。
  ///
  /// 决策映射抽成 [planSessionStart]（纯函数，见 bilibili_api.dart，可单测）。
  Future<void> _handleSessionOnStart() async {
    final api = BiliApi();
    Duration? remain;
    try {
      remain = await api.remainingSession();
    } catch (e) {
      // 测试环境无 secure storage 原生插件等：静默，不引导登录
      debugPrint('[session] 读取登录态失败，静默跳过自动登录: $e');
      return;
    }
    switch (planSessionStart(remain)) {
      case SessionStartAction.autoLogin:
        debugPrint('[session] 启动检查：无 SESSDATA → 自动进入登录页');
        await _guideAutoLogin();
      case SessionStartAction.refresh:
        bool renewed = false;
        try {
          renewed = await api.refreshSession();
        } catch (_) {
          renewed = false; // 网络/续期异常按失败处理
        }
        if (renewed) {
          debugPrint('[session] SESSDATA 距过期<7天，静默续期成功');
          return;
        }
        // 续期失败：已过期 → 会话彻底失效，先清失效凭据（避免残留过期
        // SESSDATA 被播放取流等请求注入 → 服务端 -101 拒绝），再引导重登
        if (remain != null && remain.isNegative) {
          debugPrint('[session] 会话已过期且续期失败 → 清除失效会话并引导重新登录');
          try {
            await api.clearSession();
          } catch (_) {
            // 存储异常静默：引导登录不受影响
          }
          await _guideAutoLogin();
        } else {
          debugPrint('[session] 距过期<7天但续期失败（未过期，保留现会话）');
        }
      case SessionStartAction.silent:
        debugPrint('[session] 启动检查：会话有效（≥7天），静默恢复');
    }
  }

  /// 自动引导进入登录页（本次进程只触发一次；等首帧结束再导航）。
  Future<void> _guideAutoLogin() async {
    if (_autoLoginGuided) return;
    _autoLoginGuided = true;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      debugPrint('[session] 打开登录页（自动引导）');
      _openLogin(context, banner: kAutoLoginBanner);
    });
  }

  /// 获取（或懒构造）UpdateService。
  ///
  /// tokenProvider 接 GitHub 配置里已存的 token：仓库是私有的，
  /// Release 元数据与 APK 资产下载都需要带它鉴权。
  Future<UpdateService> _ensureUpdateService() async {
    if (_updateService != null) return _updateService!;
    final prefs = await SharedPreferences.getInstance();
    _updateService = UpdateService(
      storage: UpdateStorage(prefs),
      tokenProvider: () => _github.getToken(),
    );
    return _updateService!;
  }

  /// 启动静默检查（T3）：节流 24h；失败静默；有新版且非强制 → 弹 UpdateDialog。
  Future<void> _silentCheckUpdate() async {
    try {
      final svc = await _ensureUpdateService();
      final info = await svc.check();
      if (info == null || !mounted) return;
      if (info.isMandatory(0)) return; // 强制更新走单独通道（首版不启用）
      _showUpdateDialog(info);
    } catch (_) {
      // 启动检查失败一律静默，不打扰用户。
    }
  }

  /// 管理面板「检查更新」按钮调用：force=true 跳过节流。
  Future<void> _manualCheckUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final svc = await _ensureUpdateService();
      final info = await svc.check(force: true);
      if (!mounted) return;
      if (info == null) {
        // 已是最新：用 PackageInfo 读当前 version 显示
        final current = _version;
        messenger.showSnackBar(SnackBar(content: Text('已是最新 v$current')));
        return;
      }
      _showUpdateDialog(info);
    } on UpdateException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('检查更新失败：$e')));
    }
  }

  /// 弹出更新对话框。
  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(
        info: info,
        service: _updateService!,
        installer: ApkInstallerChannel(),
      ),
    );
  }

  /// 启动后立即读一次信箱未读数（仅本地缓存，不触网），让红点尽快可见。
  Future<void> _refreshInboxCount() async {
    try {
      final n = await ServiceLocator.inboxService.getUnseenCount();
      if (!mounted) return;
      setState(() => _inboxUnseen = n);
    } catch (_) {
      // inbox 静默失败不阻塞首页
    }
  }

  /// 启动 5 秒后触发一次信箱检查（带 30min 节流，重复启动不会连发）。
  /// 静默失败不提示；与 T3 启动检查风格一致。
  void _scheduleInboxCheck() {
    _inboxCheckTimer?.cancel();
    _inboxCheckTimer = Timer(const Duration(seconds: 5), () async {
      if (!mounted) return;
      try {
        final result = await ServiceLocator.inboxService.checkAll();
        if (!mounted) return;
        setState(() => _inboxUnseen = result.unseen);
      } catch (e) {
        debugPrint('[inbox] 启动检查失败: $e');
      }
    });
  }

  /// 跳到 InboxPage；返回时重新读未读数（用户可能已点过「全部标记已读」）。
  Future<void> _openInbox() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const InboxPage()));
    if (mounted) await _refreshInboxCount();
  }

  /// 读取本地缓存 + 尝试网络同步（两者并行，UI 立即展示缓存）。
  Future<void> _load() async {
    setState(() => _syncing = true);
    try {
      final result = await ServiceLocator.syncService.sync();
      if (mounted) {
        setState(() {
          _data = result.data;
          _fetchedAt = result.fetchedAt;
          _sourceName = result.sourceName;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '同步失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 管理写操作：内存副本 → saveToGist 成功 → 写本地缓存 → 刷新 UI；
  // 失败只提示、不动内存与本地缓存。防沉迷：新增视频入口只有「导入」（与电脑端等价）。
  // ---------------------------------------------------------------------------

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 统一落库：先校验配置，再写 Gist，成功后写本地缓存并刷新。
  Future<void> _saveAndRefresh(WhitelistData next) async {
    try {
      if (!await _github.hasConfig()) {
        _showSnack('请先到右上角管理入口配置 GitHub token 与 Gist ID');
        return;
      }
      final ok = await _github.saveToGist(next);
      if (!ok) {
        _showSnack('保存到 Gist 失败，请重试');
        return;
      }
      await ServiceLocator.syncService.saveToCache(next);
      if (mounted) {
        setState(() {
          _data = next;
        });
      }
      _showSnack('已保存');
    } on GithubApiException catch (e) {
      _showSnack('保存失败：${e.message}');
    } catch (e) {
      _showSnack('保存失败：$e');
    }
  }

  /// 新建合集：去重后写入 collections → 持久化。
  Future<void> _createCollection(String name) async {
    name = name.trim();
    if (name.isEmpty) {
      _showSnack('请输入合集名称');
      return;
    }
    if (name == kUncategorizedLabel) {
      _showSnack('合集名不能为「$kUncategorizedLabel」');
      return;
    }
    if (_data.collections.any((c) => c.name == name)) {
      _showSnack('合集「$name」已存在');
      return;
    }
    final next = _data.copyWith(
      collections: [
        ..._data.collections,
        CollectionInfo(name: name, createdAt: DateTime.now().toIso8601String()),
      ],
    );
    await _saveAndRefresh(next);
  }

  /// 打开导入对话框（解析分享链接 → 加入白名单）。
  void _openImport() {
    showDialog<void>(
      context: context,
      builder: (_) => _ImportDialog(onImport: _importVideo),
    );
  }

  /// 导入入口（普通视频 + 番剧/电影共用）。
  ///
  /// 先试番剧引用解析（本地正则命中 ep/ss 链接、裸号；b23 番剧短码
  /// `b23.tv/ep|ss<id>` 无需网络）——命中 → 整季逐集导入；
  /// 其余（BV/普通视频链接/随机 b23 短码）→ 原有单视频流程。
  Future<void> _importVideo(String input) async {
    PgcRef? pgc;
    try {
      pgc = await parsePgcRef(input);
    } on ImportParseException catch (e) {
      _showSnack(e.message);
      return;
    }
    if (pgc != null) {
      await _importPgcSeason(pgc);
      return;
    }
    await _importSingleVideo(input);
  }

  /// 番剧/电影整季导入：拉整季 → 逐集写白名单（addVideo 按 bvid 查重自动跳过）。
  ///
  /// 逻辑与进度 UI 抽到 [runPgcSeasonImport]（与搜索页 media 结果导入共用，
  /// v2.16.5+），此处只负责把解析出的 ep/ss 引用转成参数，导入完成后刷新列表。
  Future<void> _importPgcSeason(PgcRef ref) async {
    await runPgcSeasonImport(
      context: context,
      writer: _writer,
      configHint: '请先到右上角管理入口配置 GitHub token 与 Gist ID',
      epId: ref.kind == PgcKind.ep ? ref.id : null,
      seasonId: ref.kind == PgcKind.ss ? ref.id : null,
      onDone: (_) async => _load(),
    );
  }

  /// 单视频导入（原流程）：解析 BV → 取元数据 → 写 Gist（按 bvid 查重）。
  Future<void> _importSingleVideo(String input) async {
    // 1) 解析出 bvid（短链会发一次重定向请求）
    final String bvid;
    try {
      bvid = await parseBvid(input);
    } on ImportParseException catch (e) {
      _showSnack(e.message);
      return;
    }
    debugPrint('[import] parseBvid -> $bvid');

    // 2) 配置门禁：未配置 token/gist_id 时提前引导，避免浪费 B 站接口调用
    if (!await _github.hasConfig()) {
      _showSnack('请先到右上角管理入口配置 GitHub token 与 Gist ID');
      return;
    }

    // 3) 取视频元数据 → 查重 → 写 Gist（共用 WhitelistWriter）
    final AddResult result;
    try {
      result = await _writer.addByBvid(bvid);
    } on BiliApiException catch (e) {
      _showSnack('获取视频信息失败：${e.message}');
      return;
    } on DioException {
      _showSnack('网络请求失败，请检查网络后重试');
      return;
    } on GithubApiException catch (e) {
      _showSnack('导入失败：${e.message}');
      return;
    }
    if (!result.added) {
      _showSnack(result.message);
      return;
    }
    final video = result.video!;
    final next = result.data!;
    final displayTitle = video.title.isEmpty ? video.bvid : video.title;
    debugPrint('[import] 已写入 Gist + 本地缓存: $bvid');
    if (mounted) {
      setState(() {
        _data = next;
      });
    }
    final multi = countLinkTokens(input) > 1;
    _showSnack('已导入：$displayTitle${multi ? '（检测到多个链接，仅导入第一个）' : ''}');
  }

  /// 打开搜索页（B 站全网搜索 + 白名单内过滤两个 Tab）。
  ///
  /// 搜索页「加入」会写 Gist，返回后重新同步一次，保证列表立即反映新增。
  Future<void> _openSearch({int initialTab = 0}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(initialTab: initialTab),
      ),
    );
    if (mounted) _load();
  }

  /// 打开管理面板（GitHub 配置 + B 站账号 + 新建合集 + 合集管理 + 缓存管理
  /// + 翻译服务 + 检查更新）。
  void _openManage() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ManageSheet(
        github: _github,
        onCollectionCreated: _createCollection,
        onManageCollections: _openCollectionManage,
        onCheckUpdate: _manualCheckUpdate,
        // 次级「登录 / 重新登录」入口：面板内按钮先 pop 自身，再推登录页
        onLogin: () {
          if (mounted) _openLogin(context);
        },
      ),
    );
  }

  /// 打开合集管理面板（列出合集 + 重命名/删除）。
  void _openCollectionManage() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CollectionManageSheet(
        // 每次 setState 时重新从页面拉取最新合集列表（操作成功后即时刷新）
        collectionsOf: () => _data.collections,
        countOf: (name) =>
            _data.videos.where((v) => v.collection == name).length,
        onRename: _renameCollection,
        onDelete: _deleteCollection,
      ),
    );
  }

  /// 重命名合集：校验（保留名/重名）→ 同步引用 → 落库刷新。
  Future<void> _renameCollection(String oldName, String newName) async {
    final neu = newName.trim();
    if (neu == oldName) {
      _showSnack('新旧名相同，未改动');
      return;
    }
    if (neu == kUncategorizedLabel) {
      _showSnack('合集名不能为「$kUncategorizedLabel」');
      return;
    }
    try {
      final next = renameCollection(_data, oldName, neu);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message);
    }
  }

  /// 删除合集：定义移除 + 视频回未分类（不删视频）→ 落库刷新。
  Future<void> _deleteCollection(String name) async {
    try {
      final next = deleteCollection(_data, name);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message);
    }
  }

  // ---------------------------------------------------------------------------
  // 合集卡片数据：collections 数组顺序即展示顺序；「未分类」固定最后一张。
  // ---------------------------------------------------------------------------

  /// 卡片数据（构造时一次性生成，卡片本身是静态展示）。
  List<({String name, int count, String cover})> _cards() {
    final cards = <({String name, int count, String cover})>[];
    for (final c in _data.collections) {
      final vids = _data.sortedVideos(c.name);
      cards.add((
        name: c.name,
        count: vids.length,
        cover: vids.isNotEmpty ? vids.first.cover : '',
      ));
    }
    // 「未分类」固定卡片：始终显示（含 0 个），让用户知道新导入视频的默认归处
    final uncategorized = _data.sortedVideos('');
    cards.add((
      name: kUncategorizedLabel,
      count: uncategorized.length,
      cover: uncategorized.isNotEmpty ? uncategorized.first.cover : '',
    ));
    return cards;
  }

  /// 打开合集视频列表页（两级导航第二级）。
  void _openCollection(String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionPage(
          collectionName: name == kUncategorizedLabel ? '' : name,
          data: _data,
          saveAndRefresh: _saveAndRefresh,
        ),
      ),
    );
  }

  /// 打开白名单 UP 主详情页；返回 true 时刷新首页数据。
  Future<void> _openUpowner(Upowner up) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            UpownerPage(mid: up.mid, initial: up, isInWhitelist: true),
      ),
    );
    if (changed == true && mounted) _load();
  }

  /// 从首页 UP 管理页移除白名单 UP 主。
  Future<void> _removeUpowner(Upowner up) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('从白名单移除「${up.name}」？'),
        content: const Text('移除后将不再检查该 UP 主的新视频，不影响已加入的白名单视频。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('移除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = removeUpowner(_data, up.mid);
    if (identical(next, _data)) {
      _showSnack('UP 主不在白名单中');
      return;
    }
    await _saveAndRefresh(next);
  }

  /// 合集拖动排序：重排 collections（未分类固定最后、不可拖）→ 落库。
  ///
  /// 拖拽只影响 [WhitelistData.collections] 顺序，视频归属不变。
  /// 保存失败时不 setState：ReorderableListView 的显示顺序由数据驱动，
  /// 数据未变 → 列表视觉自动回弹原顺序（失败回滚，不破坏数据）。
  void _onReorderCollections(int oldIndex, int newIndex) {
    final total = _data.collections.length; // 卡片总长 = total + 1（未分类最后）
    if (oldIndex < 0 || oldIndex >= total) return; // 未分类不可拖
    if (newIndex > total) newIndex = total; // 最多拖到未分类之前
    if (newIndex > oldIndex) newIndex -= 1;
    final names = [for (final c in _data.collections) c.name];
    final moved = names.removeAt(oldIndex);
    names.insert(newIndex, moved);
    final next = reorderCollections(_data, names);
    if (identical(next.collections, _data.collections)) return; // 拖回原位
    unawaited(_saveAndRefresh(next));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = _hasData
        ? _cards()
        : const <({String name, int count, String cover})>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('白名单点播'),
        actions: [
          // 历史记录入口：右滑可到历史页，图标直达
          IconButton(
            tooltip: '历史记录',
            icon: const Icon(Icons.history),
            onPressed: _goToHistory,
          ),
          // 信箱入口：未读 > 0 时图标右上角显示小红点
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: '信箱（白名单 UP 主新视频）',
                icon: const Icon(Icons.inbox_outlined),
                onPressed: _openInbox,
              ),
              if (_inboxUnseen > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _inboxUnseen > 99 ? '99+' : '$_inboxUnseen',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: '搜索（B 站全网 + 白名单内 + UP 主）',
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
          IconButton(
            tooltip: '导入视频',
            icon: const Icon(Icons.add_link),
            onPressed: _openImport,
          ),
          IconButton(
            tooltip: '管理（GitHub 配置 / 合集 / B 站账号）',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openManage,
          ),
        ],
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          // 切到历史页时重新读取（播放返回/时间推移后列表可能已变化）
          if (index == 0) _historyKey.currentState?.reload();
        },
        children: [
          HistoryPage(key: _historyKey),
          _buildCollectionHome(theme, cards),
          _UpownerManagePage(
            upowners: _data.upowners,
            syncing: _syncing,
            onRefresh: _load,
            onSearch: () => _openSearch(initialTab: 2),
            onOpen: _openUpowner,
            onRemove: _removeUpowner,
          ),
        ],
      ),
    );
  }

  Widget _buildCollectionHome(
    ThemeData theme,
    List<({String name, int count, String cover})> cards,
  ) {
    return Column(
      children: [
        _CacheBar(
          fetchedAt: _fetchedAt,
          sourceName: _sourceName,
          error: _error,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _hasData
                ? ReorderableListView.builder(
                    padding: const EdgeInsets.all(12),
                    physics: const AlwaysScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: cards.length,
                    onReorder: _onReorderCollections,
                    itemBuilder: (context, i) {
                      final card = cards[i];
                      final isUncategorized = card.name == kUncategorizedLabel;
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey(card.name),
                        index: i,
                        enabled: !isUncategorized,
                        child: _CollectionCard(
                          name: card.name,
                          count: card.count,
                          cover: card.cover,
                          draggable: !isUncategorized,
                          onTap: () => _openCollection(card.name),
                        ),
                      );
                    },
                  )
                : _EmptyView(syncing: _syncing),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'v$_version · 左右滑动切换合集 / 历史 / UP 主',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }

  /// 打开登录页（WebView 短信登录）。
  ///
  /// [banner]：登录页顶部提示条文案——仅「自动引导登录」时传入
  /// （[kAutoLoginBanner]），说明登录态会自动保存、下次进入自动恢复；
  /// 管理面板手动「登录/重新登录」不传（页面本身即自解释）。
  ///
  /// 测试可注入 [widget.openLogin] 替身（不真推含 WebView 的登录页）。
  Future<void> _openLogin(BuildContext context, {String? banner}) async {
    if (!mounted) return;
    final injected = widget.openLogin;
    if (injected != null) {
      await injected(context, banner: banner);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LoginPage(banner: banner)),
    );
  }
}

/// 首页右滑第二页：白名单 UP 主管理。
class _UpownerManagePage extends StatelessWidget {
  final List<Upowner> upowners;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final VoidCallback onSearch;
  final void Function(Upowner upowner) onOpen;
  final void Function(Upowner upowner) onRemove;

  const _UpownerManagePage({
    required this.upowners,
    required this.syncing,
    required this.onRefresh,
    required this.onSearch,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: .4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('白名单 UP 主', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '右滑到这里管理已加入的 UP 主',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: onSearch,
                icon: const Icon(Icons.person_search, size: 18),
                label: const Text('搜索 UP 主'),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: upowners.isEmpty
                ? _EmptyUpownerList(syncing: syncing, onSearch: onSearch)
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: upowners.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final up = upowners[i];
                      return _UpownerManageTile(
                        upowner: up,
                        onTap: () => onOpen(up),
                        onRemove: () => onRemove(up),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _EmptyUpownerList extends StatelessWidget {
  final bool syncing;
  final VoidCallback onSearch;

  const _EmptyUpownerList({required this.syncing, required this.onSearch});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          syncing ? Icons.sync : Icons.person_search,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Center(child: Text(syncing ? '正在同步白名单…' : '还没有白名单 UP 主')),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            onPressed: onSearch,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('搜索并加入 UP 主'),
          ),
        ),
      ],
    );
  }
}

class _UpownerManageTile extends StatelessWidget {
  final Upowner upowner;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _UpownerManageTile({
    required this.upowner,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: _UpownerAvatar(upowner: upowner),
        title: Text(
          upowner.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          _fmtUpownerMeta(upowner),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: IconButton(
          tooltip: '移除 UP 主',
          icon: const Icon(Icons.bookmark_remove_outlined),
          onPressed: onRemove,
        ),
      ),
    );
  }
}

class _UpownerAvatar extends StatelessWidget {
  final Upowner upowner;

  const _UpownerAvatar({required this.upowner});

  @override
  Widget build(BuildContext context) {
    if (upowner.face.isEmpty) return _placeholder(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Image.network(
        upowner.face,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        headers: {'User-Agent': kBrowserUA, 'Referer': kBiliReferer},
        errorBuilder: (_, __, ___) => _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final theme = Theme.of(context);
    final initial = upowner.name.isNotEmpty
        ? upowner.name.characters.first
        : '?';
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

String _fmtUpownerMeta(Upowner upowner) {
  final fans = upowner.fans;
  final fansText = fans == null
      ? '— 粉丝'
      : fans >= 100000000
      ? '${_trimNumber(fans / 100000000)}亿 粉丝'
      : fans >= 10000
      ? '${_trimNumber(fans / 10000)}万 粉丝'
      : '$fans 粉丝';
  final date = upowner.addedAt.toLocal();
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$fansText · 加入于 ${date.year}-$m-$d';
}

String _trimNumber(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 合集卡片（行式）：左侧代表视觉（封面 / 渐变底 + 图标），
/// 右侧合集名 + 视频数，尾部拖动手柄提示（未分类不可拖不显示）。
class _CollectionCard extends StatelessWidget {
  final String name;
  final int count;
  final String cover; // 该合集首个视频封面（无视频/未分类 → 空串走图标）
  final bool draggable; // 是否可拖动（未分类固定最后，不可拖）
  final VoidCallback onTap;

  const _CollectionCard({
    required this.name,
    required this.count,
    required this.cover,
    required this.draggable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUncategorized = name == kUncategorizedLabel;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // 代表视觉：未分类用固定渐变+图标；合集优先展示首个视频封面
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: cover.isNotEmpty && !isUncategorized
                      ? Image.network(
                          cover,
                          fit: BoxFit.cover,
                          // 与 CoverImage 一致：必须带防盗链头，否则 B 站图床 403
                          headers: {
                            'User-Agent': kBrowserUA,
                            'Referer': kBiliReferer,
                          },
                          errorBuilder: (_, __, ___) =>
                              _coverPlaceholder(context),
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return _coverPlaceholder(context);
                          },
                        )
                      : _coverPlaceholder(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count 个视频',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 拖动手柄提示（可拖动的合集才显示；未分类不可拖）
              if (draggable)
                Icon(
                  Icons.drag_indicator,
                  size: 20,
                  color: theme.colorScheme.outline.withValues(alpha: .55),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片视觉占位：渐变底 + 图标（未分类用 inbox，合集无封面用 video_library）。
  Widget _coverPlaceholder(BuildContext context) {
    final theme = Theme.of(context);
    final isUncategorized = name == kUncategorizedLabel;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.secondaryContainer,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          isUncategorized ? Icons.inbox_outlined : Icons.video_library_outlined,
          size: 32,
          color: theme.colorScheme.onSecondaryContainer.withValues(alpha: .55),
        ),
      ),
    );
  }
}

/// 导入对话框：多行输入框粘贴 B 站分享链接/文本，确认后交回页面执行导入。
class _ImportDialog extends StatefulWidget {
  final Future<void> Function(String text) onImport;

  const _ImportDialog({required this.onImport});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _ctrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _submitting = true);
    try {
      await widget.onImport(text);
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入视频'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            enabled: !_submitting,
            decoration: const InputDecoration(
              hintText: '粘贴 B 站分享链接：视频 BV，或番剧/电影链接',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '视频 → 单条加入；番剧/电影 → 整季逐集加入白名单'
            '（如 bangumi/play/ep98603、b23.tv/ss5800）。会员集可导入，播放时提示',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('导入'),
        ),
      ],
    );
  }
}

/// 缓存数据条（时间 + 来源 + 错误提示）。
class _CacheBar extends StatelessWidget {
  final DateTime? fetchedAt;
  final String? sourceName;
  final String? error;

  const _CacheBar({this.fetchedAt, this.sourceName, this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget content;
    if (error != null) {
      content = Text(
        error!,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    } else if (fetchedAt != null) {
      content = Text(
        '数据时间 ${_fmt(fetchedAt!)}（来源: ${sourceName ?? '?'}）',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    } else {
      content = Text('暂无数据，下拉刷新同步', style: theme.textTheme.bodySmall);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
      child: content,
    );
  }
}

/// 空态视图（首次启动且无缓存/同步失败）。
class _EmptyView extends StatelessWidget {
  final bool syncing;

  const _EmptyView({required this.syncing});

  @override
  Widget build(BuildContext context) {
    final message = syncing ? '正在同步白名单…' : '白名单为空\n下拉刷新重新同步';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          syncing ? Icons.sync : Icons.inbox_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Center(child: Text(message)),
      ],
    );
  }
}

/// 合集管理面板（BottomSheet）：列出所有合集（名字 + 视频数），
/// 每个合集可重命名 / 删除。
///
/// - 数据不持有快照：通过 [collectionsOf] / [countOf] 每次从页面拉取最新值，
///   操作成功后内部 setState 重拉，列表即时反映页面 `_data`
/// - [onRename] / [onDelete] 交回页面统一走「写 Gist → 缓存 → 刷新」
class _CollectionManageSheet extends StatefulWidget {
  final List<CollectionInfo> Function() collectionsOf;
  final int Function(String name) countOf;
  final Future<void> Function(String oldName, String newName) onRename;
  final Future<void> Function(String name) onDelete;

  const _CollectionManageSheet({
    required this.collectionsOf,
    required this.countOf,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_CollectionManageSheet> createState() => _CollectionManageSheetState();
}

class _CollectionManageSheetState extends State<_CollectionManageSheet> {
  /// 重命名对话框：预填旧名 → 确定后回调页面。
  Future<void> _rename(CollectionInfo collection) async {
    final ctrl = TextEditingController(text: collection.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('重命名合集「${collection.name}」'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新合集名称',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(dialogCtx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName == null || !mounted) return;
    await widget.onRename(collection.name, newName);
    if (mounted) setState(() {}); // 重拉合集列表（页面 _data 已更新）
  }

  /// 删除确认对话框：提示该合集下 N 个视频将移回未分类。
  Future<void> _delete(CollectionInfo collection) async {
    final count = widget.countOf(collection.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('删除合集「${collection.name}」'),
        content: Text(
          '确定删除合集「${collection.name}」吗？\n'
          '该合集下 $count 个视频将移回未分类（视频本身不会被删除）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDelete(collection.name);
    if (mounted) setState(() {}); // 重拉合集列表
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final collections = widget.collectionsOf();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .55,
      minChildSize: .35,
      maxChildSize: .85,
      builder: (_, scrollCtrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('合集管理', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '重命名会同步更新该合集下所有视频；删除会把视频移回未分类（不删视频）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (collections.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无合集')),
                  ),
                for (final c in collections)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(c.name),
                    subtitle: Text('${widget.countOf(c.name)} 个视频'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '重命名',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _rename(c),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: theme.colorScheme.error,
                          ),
                          onPressed: () => _delete(c),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(DateTime t) => t.toLocal().toString().substring(0, 16);

/// 管理面板（BottomSheet）：GitHub token/gist_id 配置 + 新建合集。
///
/// - 配置读写走 [GithubApi]（flutter_secure_storage，仅存本机）
/// - 新建合集通过 [onCollectionCreated] 交回页面统一走「写 Gist → 缓存 → 刷新」
class _ManageSheet extends StatefulWidget {
  final GithubApi github;
  final Future<void> Function(String name) onCollectionCreated;
  final VoidCallback onManageCollections; // 打开合集管理面板（重命名/删除）
  final VoidCallback onCheckUpdate; // M1.2 检查更新入口
  final VoidCallback onLogin; // B 站账号：面板关闭后推登录页（登录/重新登录）

  const _ManageSheet({
    required this.github,
    required this.onCollectionCreated,
    required this.onManageCollections,
    required this.onCheckUpdate,
    required this.onLogin,
  });

  @override
  State<_ManageSheet> createState() => _ManageSheetState();
}

/// B 站账号登录态（管理面板顶部状态展示）。
enum _AccountState { loading, loggedIn, expired, none }

class _ManageSheetState extends State<_ManageSheet> {
  final _tokenCtrl = TextEditingController();
  final _gistCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loadingConfig = true;
  bool _savingConfig = false;
  bool _creating = false;
  bool _obscureToken = true;

  /// B 站账号状态（读取 secure storage 的 SESSDATA 剩余有效期判断）。
  _AccountState _account = _AccountState.loading;

  /// SESSDATA 剩余有效期（-1 秒 = 刚过期；仅展示用，不涉及具体凭据内容）。
  Duration? _accountRemain;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _loadAccount();
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _gistCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  /// 读取 B 站账号登录态（只判断有无/有效期，不读取任何凭据值）。
  Future<void> _loadAccount() async {
    _AccountState next;
    Duration? remain;
    try {
      remain = await BiliApi().remainingSession();
      if (remain == null) {
        next = _AccountState.none;
      } else if (remain.isNegative) {
        next = _AccountState.expired;
      } else {
        next = _AccountState.loggedIn;
      }
    } catch (_) {
      next = _AccountState.none; // 存储异常按未登录展示（可手动进登录页）
    }
    if (!mounted) return;
    setState(() {
      _account = next;
      _accountRemain = remain;
    });
  }

  /// 账号区块标题行说明文案（不涉及具体凭据）。
  String get _accountTitle {
    switch (_account) {
      case _AccountState.loading:
        return '正在检查 B 站账号…';
      case _AccountState.loggedIn:
        final remain = _accountRemain;
        final near = remain != null && remain < const Duration(days: 7);
        return '已登录：B 站账号已连接（1080P 已解锁${near ? '，将自动续期' : ''}）';
      case _AccountState.expired:
        return '登录已过期：重新登录后恢复 1080P';
      case _AccountState.none:
        return '未登录：登录后可解锁 1080P（登录一次，之后每次进入自动恢复）';
    }
  }

  /// 账号区块按钮文案（登录 / 重新登录共用同一 WebView 登录页）。
  String get _accountActionLabel =>
      _account == _AccountState.loggedIn ? '重新登录' : '登录';

  Future<void> _loadConfig() async {
    try {
      final token = await widget.github.getToken();
      final gistId = await widget.github.getGistId();
      if (mounted) {
        _tokenCtrl.text = token ?? '';
        _gistCtrl.text = gistId ?? '';
        setState(() => _loadingConfig = false);
      }
    } catch (_) {
      // 读取失败（如存储异常）不阻塞面板使用
      if (mounted) setState(() => _loadingConfig = false);
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _savingConfig = true);
    try {
      await widget.github.setToken(_tokenCtrl.text.trim());
      await widget.github.setGistId(_gistCtrl.text.trim());
      if (mounted) {
        _showSnack('GitHub 配置已保存（仅存本机）');
      }
    } catch (_) {
      if (mounted) _showSnack('配置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingConfig = false);
    }
  }

  Future<void> _createCollection() async {
    setState(() => _creating = true);
    try {
      await widget.onCollectionCreated(_nameCtrl.text);
      // 页面统一提示成败；创建成功后清空输入框
      if (mounted && _nameCtrl.text.trim().isNotEmpty) {
        _nameCtrl.clear();
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      // 键盘弹起时把内容顶上去（isScrollControlled + viewInsets）
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('管理', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '管理功能只允许：新建 / 重命名 / 删除合集，移动 / 删除视频。'
              '新增白名单走右上角「导入」或「搜索」入口（加入前会查重）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // ---- B 站账号（自动登录的次级入口：登录 / 重新登录）----
            Text('B 站账号', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              _accountTitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                // 关闭面板再推登录页（与「检查更新」同模式，干净上下文）
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onLogin();
                },
                icon: Icon(
                  _account == _AccountState.loggedIn
                      ? Icons.person_outline
                      : Icons.login,
                  size: 18,
                ),
                label: Text(_accountActionLabel),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- GitHub 配置 ----
            Text('GitHub 配置', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '用于把管理操作写入 Gist：token 需 gist 权限，仅保存在本机安全存储。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenCtrl,
              obscureText: _obscureToken,
              enabled: !_loadingConfig,
              decoration: InputDecoration(
                labelText: 'GitHub Token',
                hintText: 'ghp_xxx / github_pat_xxx',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscureToken ? '显示 Token' : '隐藏 Token',
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _gistCtrl,
              enabled: !_loadingConfig,
              decoration: const InputDecoration(
                labelText: 'Gist ID',
                hintText: 'gist 网址末尾的 32 位 ID',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _savingConfig ? null : _saveConfig,
                icon: _savingConfig
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: Text(_savingConfig ? '保存中…' : '保存配置'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 新建合集 ----
            Text('新建合集', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '合集名称',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _createCollection(),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _creating ? null : _createCollection,
                icon: _creating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(_creating ? '创建中…' : '新建合集'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 合集管理（重命名 / 删除）----
            Text('合集管理', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '重命名会同步更新该合集下所有视频；删除会把视频移回未分类（不删视频）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.onManageCollections,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('管理合集'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 离线缓存管理 ----
            Text('离线缓存', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '下载过的视频缓存在本机，断网也能播放；大小只受手机存储限制。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openCacheManage(context),
                icon: const Icon(Icons.video_library_outlined, size: 18),
                label: const Text('缓存管理'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 翻译服务配置 ----
            Text('翻译服务', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'OpenAI 兼容翻译服务，用于字幕副字幕翻译（「翻译（中文）」）；'
              'key 仅存本机，可留空=不启用翻译。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _showTranslateConfig(context),
                icon: const Icon(Icons.translate, size: 18),
                label: const Text('翻译服务配置'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 版本更新 ----
            Text('版本更新', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '手动检查 GitHub Releases：发现新版本弹窗 → 下载 → 一键安装。'
              '启动 5s 后也会自动静默检查（24h 节流）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  // 关闭面板再检查，让 SnackBar / Dialog 显示在干净上下文。
                  Navigator.of(context).pop();
                  widget.onCheckUpdate();
                },
                icon: const Icon(Icons.system_update_alt_outlined, size: 18),
                label: const Text('检查更新'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openCacheManage(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _CacheManageSheet(),
    );
  }

  /// 打开翻译服务配置弹窗（base_url / api_key / model）。
  Future<void> _showTranslateConfig(BuildContext context) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TranslateConfigDialog(api: TranslateApi()),
    );
    if (saved == true && context.mounted) _showSnack('翻译服务配置已保存（仅存本机）');
  }
}

/// 翻译服务配置弹窗：base_url / api_key / model 三个输入框。
///
/// - 打开时回填已保存的配置（无配置时给默认 base_url / model）
/// - key 用密码框（默认隐藏）；保存走 [TranslateApi.saveConfig]
///   （secure storage，仅存本机；任一项留空 = 不启用翻译）
/// - 保存成功 pop(true)，管理面板提示「已保存（仅存本机）」
class _TranslateConfigDialog extends StatefulWidget {
  final TranslateApi api;

  const _TranslateConfigDialog({required this.api});

  @override
  State<_TranslateConfigDialog> createState() => _TranslateConfigDialogState();
}

class _TranslateConfigDialogState extends State<_TranslateConfigDialog> {
  final _baseUrlCtrl = TextEditingController(text: 'https://api.deepseek.com');
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController(text: 'deepseek-chat');
  bool _loading = true;
  bool _saving = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cfg = await widget.api.loadConfig();
      if (mounted && cfg != null) {
        _baseUrlCtrl.text = cfg.baseUrl;
        _apiKeyCtrl.text = cfg.apiKey;
        _modelCtrl.text = cfg.model;
      }
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      // 读取失败（如存储异常）不阻塞配置使用
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.api.saveConfig(
        baseUrl: _baseUrlCtrl.text,
        apiKey: _apiKeyCtrl.text,
        model: _modelCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('翻译配置保存失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('翻译服务'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'OpenAI 兼容翻译服务，用于字幕副字幕翻译；'
              'key 仅存本机，可留空=不启用翻译。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlCtrl,
              enabled: !_loading,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.deepseek.com',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyCtrl,
              enabled: !_loading,
              obscureText: _obscureKey,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-xxx（留空=不启用翻译）',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscureKey ? '显示 Key' : '隐藏 Key',
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _modelCtrl,
              enabled: !_loading,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'deepseek-chat',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

/// 缓存管理面板（BottomSheet）：列出已缓存视频（标题 + 集 + 大小）、
/// 删除单个、总大小显示、清空缓存（确认）。
///
/// - 监听 [DownloadManager.cached]，下载完成/删除后即时刷新
/// - 删除单集/清空缓存交回 DownloadManager（删文件 + 索引）
class _CacheManageSheet extends StatefulWidget {
  const _CacheManageSheet();

  @override
  State<_CacheManageSheet> createState() => _CacheManageSheetState();
}

class _CacheManageSheetState extends State<_CacheManageSheet> {
  final DownloadManager _downloads = DownloadManager.instance;

  @override
  void initState() {
    super.initState();
    _downloads.cached.addListener(_onChanged);
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 删除单个缓存（确认对话框）。
  Future<void> _deleteOne(CachedVideo c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除缓存'),
        content: Text('确定删除《${c.title}》${_partLabel(c)}的缓存吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.deleteCache(c.bvid, c.pageIndex);
    _showSnack('已删除缓存');
  }

  /// 清空全部缓存（确认对话框）。
  Future<void> _clearAll() async {
    final total = _downloads.getCachedList().length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清空缓存'),
        content: Text(
          '确定清空全部 $total 个视频的缓存吗？'
          '将删除所有已下载的视频文件（${fmtBytes(_downloads.totalCacheSize())}），'
          '离线将无法播放。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.cleanAllCache();
    _showSnack('已清空缓存');
  }

  /// 缓存条目副标题：`第 N 集 · part标题 · 大小`；单 P 简化为 `大小`。
  String _partLabel(CachedVideo c) {
    final label = c.partTitle.isEmpty ? '' : '· ${c.partTitle}';
    return c.pageIndex > 0 ? '第 ${c.pageIndex + 1} 集$label' : label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _downloads.getCachedList();
    final total = _downloads.totalCacheSize();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .6,
      minChildSize: .35,
      maxChildSize: .9,
      builder: (_, scrollCtrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('缓存管理', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              items.isEmpty
                  ? '暂无缓存视频（在播放页点「下载」即可离线观看）'
                  : '共 ${items.length} 个视频 · ${fmtBytes(total)}'
                        '（下载中的任务不会显示在列表里）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无缓存'),
                    ),
                  )
                : ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final c in items)
                        ListTile(
                          leading: const Icon(
                            Icons.check_circle_outline,
                            color: Color(0xFF0A7A4A),
                          ),
                          title: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _partLabel(c).isEmpty
                                ? fmtBytes(c.sizeBytes)
                                : '${_partLabel(c)} · ${fmtBytes(c.sizeBytes)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '删除缓存',
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: theme.colorScheme.error,
                            ),
                            onPressed: () => _deleteOne(c),
                          ),
                        ),
                    ],
                  ),
          ),
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _clearAll,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('清空缓存'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
