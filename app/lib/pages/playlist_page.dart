import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../config.dart';
import '../models/update_info.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/apk_installer.dart';
import '../services/collection_stats.dart';
import '../services/followings_auto_sync.dart';
import '../services/service_locator.dart';
import '../services/update_service.dart';
import '../services/update_storage.dart';
import '../services/upowner_writer.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../utils/import_parser.dart';
import '../utils/relative_time.dart';
import '../widgets/add_success_button.dart';
import '../widgets/app_block.dart';
import '../widgets/app_state_view.dart';
import '../widgets/favorites_import_dialog.dart';
import '../widgets/manage_panel.dart';
import '../widgets/pgc_import_dialog.dart';
import '../widgets/swipe_action_box.dart';
import 'collection_page.dart';
import 'favorites_page.dart';
import 'followings_import_page.dart';
import 'history_page.dart';
import 'inbox_page.dart';
import 'login_page.dart';
import 'search_page.dart';
import 'update_dialog.dart';
import 'upowner_page.dart';
import 'watch_stats_page.dart';

/// 唯一首页：合集卡片视图（两级导航第一级）。
///
/// - 每张卡片 = 一个合集（合集名 + 视频数 + 代表视觉）；「未分类」固定一张卡片
/// - **合集卡 = 首页视觉主角（P3）**：底板走 [AppBlock] 的 collectionCard 块化
///   规格；名称行尾挂「N 天前更新 / N 天前加入」角标（时间取自本地播放历史与
///   视频 [WhitelistVideo.pubdate]，口径见 [collectionBadgeText]）；卡片下沿
///   一条 3px 观看进度条 + 副信息行「已看 X/Y」（统计见
///   `services/collection_stats.dart`，异步加载、失败静默降级）
/// - 点卡片 → [CollectionPage] 合集视频列表页（两级导航第二级）；
///   长按/多选/移动/删除等管理操作迁移到合集页
/// - 卡片封面带防盗链头（Referer + 浏览器 UA，与 [CoverImage] 同约定）
/// - 下拉刷新触发重新同步；AppBar 下方显示缓存数据时间
/// - **新增白名单的入口**：导入（解析 B 站分享链接/文本，与电脑端油猴脚本
///   等价）+ 搜索页「加入」（搜 B 站全网后一键加入，M7）
/// - 管理功能仅限：新建/重命名/删除合集、移动/删除视频（防沉迷原则不变）；
///   **新建合集**入口常驻合集页顶部（v2.19.0 起从设置区移入合集页，
///   空态另有醒目行动按钮）
/// - **固定「收藏夹」卡（v2.17.7+）**：合集区顶部常驻入口（点开 = 我的 B 站
///   收藏夹，三级浏览：首页收藏夹卡 → 收藏夹列表 → 夹内视频直接点播，
///   白名单外可播模式，见 [FavoritesPage]/[FavoriteVideosPage]）；收藏夹属
///   个人账号数据，未登录先提示并引导登录
/// - 右上角搜索入口：B 站全网搜索 + 白名单内过滤两个 Tab
/// - 右上角导入入口：粘贴分享链接/文本（视频 BV/b23.tv 短链/完整链接；
///   番剧/电影 ep|ss 链接与 b23 番剧短码 → 整季逐集加入白名单，v2.16.2）
/// - 管理入口（v2.18.0 起不再是右上角图标）：底部导航「个人」页内的
///   **设置**区（[ManagePanel]）——GitHub token/gist_id 配置 + 合集管理
///   + 缓存管理 + 翻译服务配置 + **B 站账号**（登录/重新登录，v2.16.18）
/// - **启动自动登录（v2.16.18 起，取代原右上角常驻登录按钮）**：
///   SESSDATA 有效 → 静默恢复（不弹界面）；距过期 < 续期阈值（有
///   refresh_token 15 天 / 无则 7 天，v2.16.21 分档）→ refresh_token
///   静默续期；无 SESSDATA / 彻底过期 → 自动进入登录页引导登录一次；
///   登录成功自动保存，之后每次进入静默恢复（登录一次长期保持）。
///   登录页可关闭：关闭 = 匿名，首页/播放页给明确「未登录仅 720P，
///   去登录解锁 1080P」提示入口（v2.16.21，不默认静默降级）
/// - **底部导航 4 个目的地**（v2.19.0 起把原「统计」+「设置」合并为
///   **「个人」**；取代更早的 AppBar 历史/统计/管理三个图标；同时保留
///   PageView 左右滑动）：
///   合集(0) → UP 主管理(1) → **历史记录**(2，播放历史，点击续播) →
///   **个人**(3)：**观看统计在上**（v2.17.9+ 每日真实观看时长；v2.17.10+
///   克莱因蓝 GitHub 式热力单张大图 + 总览在热力下方 + 点日期格看当天历史）、
///   **设置在下**（与旧齿轮弹层共用 [ManagePanel]，内联嵌入不 pop 路由，
///   见 watch_stats_page.dart / widgets/manage_panel.dart）。
///   切换目的地 = animateToPage(kDurBase) + 显式幂等刷新目标页数据
///   （见 [_goToPage]/[_reloadTab]）；图标 + 文字标签常显（Material 3
///   [NavigationBar]，触摸目标 ≥ 48dp）
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

  /// UP 主写入服务：UP 管理页「导入我关注的 UP」批量加入（v2.17.12+）。
  final UpownerWriter _upwriter = UpownerWriter();

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

  /// 启动 4s 后静默执行一次「B 站关注自动同步」的定时器（dispose 取消）。
  Timer? _followingsSyncTimer;

  /// 关注自动同步是否正在执行（防启动定时器与登录成功回调并发重复同步）。
  bool _followingsSyncRunning = false;

  bool get _hasData => _data.videos.isNotEmpty;

  /// 主页 PageView（4 页：合集主页 / UP 主管理 / 历史记录 / 个人，
  /// 见 [_buildPersonalPage]），初始停在合集主页（index 0，与底部导航首项一致）。
  final PageController _pageController = PageController(initialPage: 0);

  /// 当前选中的底部导航目的地（= PageView 当前页；点导航与滑动都会同步它，
  /// 供 [NavigationBar.selectedIndex] 高亮）。
  int _tab = 0;

  /// 历史页 State 的全局 key：切到历史页时刷新数据（PageView 相邻页存活，
  /// 用户可能刚从别处播放回来，需要重新读表）。
  final GlobalKey<HistoryPageState> _historyKey = GlobalKey<HistoryPageState>();

  /// 「个人」页（内含观看统计）State 的全局 key：切到该页时刷新（播放返回/
  /// 跨日后数据可能已变；PageView 页存活时也以切页为准重读，约定同历史页）。
  final GlobalKey<WatchStatsPageState> _statsKey =
      GlobalKey<WatchStatsPageState>();

  /// 底部导航切页（幂等）：同步 [_tab] + 动画切到第 [i] 页 + 显式刷新目标页。
  ///
  /// 显式刷新必须保留：[onPageChanged] 只在滚动落页时触发，用户快速连点导航
  /// 时上一次 [animateToPage] 可能被下一次打断、回调不触发——那样历史/个人页
  /// 就会拿旧数据。刷新本身幂等（重读本地表），与回调重复调用无害。
  void _goToPage(int i) {
    if (i != _tab) setState(() => _tab = i);
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(i, duration: kDurBase, curve: kCurveOut);
    _reloadTab(i);
  }

  /// 目标页数据刷新（幂等）：历史(2) / 个人(3，观看统计) 页重读本地表；
  /// 首页(0) 重算合集统计（切回来时把「已看 X/Y」对齐刚看完的那几集）。
  void _reloadTab(int i) {
    if (i == 0) unawaited(_refreshCollectionStats());
    if (i == 2) _historyKey.currentState?.reload();
    if (i == 3) _statsKey.currentState?.reload();
  }

  /// 首页是否需要「未登录仅 720P」提示条（去登录入口，v2.16.21）：
  /// 无有效 SESSDATA（真未登录/彻底过期且引导被关闭）时为 true。
  /// 由 [_refreshLoginHint] 异步维护（登录页关闭/引导后重查），启动时先置
  /// true 再按读取结果校正，避免误显示已登录态。
  bool _showLoginHint = false;

  /// 未登录提示条文案（关闭登录页=明确匿名，不默认静默降级）。
  static const String _kLoginHintText =
      '未登录仅 720P，去登录解锁 1080P（登录一次，之后每次进入自动恢复）';

  /// 自动登录是否已引导（本次进程只自动引导一次，避免循环/重复弹页）。
  bool _autoLoginGuided = false;

  @override
  void initState() {
    super.initState();
    _load();
    _handleSessionOnStart();
    _refreshLoginHint();
    _loadVersion();
    // 启动 5s 后静默检查更新 + 信箱检查；两者都失败静默不打扰。
    _refreshInboxCount();
    _scheduleInboxCheck();
    _startupUpdateTimer = Timer(const Duration(seconds: 5), () {
      _silentCheckUpdate();
    });
    // 启动 4s 后静默执行一次「B 站关注自动同步」（登录态恢复后延迟执行，
    // 避免启动抢网络；见 _runFollowingsAutoSync / FollowingsAutoSyncService）。
    _scheduleFollowingsAutoSync();
  }

  @override
  void dispose() {
    _startupUpdateTimer?.cancel();
    _inboxCheckTimer?.cancel();
    _followingsSyncTimer?.cancel();
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

  /// 启动自动登录（v2.16.18 起，App 启动 / 首页 initState 即触发，不依赖按钮；
  /// v2.16.21 续期策略强化——「进去即登录」链路做扎实）：
  ///
  /// - SESSDATA 有效且离过期还早（≥ 续期阈值）→ 静默恢复，不弹任何界面；
  /// - 距过期 < 阈值 → 用 refresh_token **静默续期**（阈值分档：
  ///   有 refresh_token → 15 天提前续期，无 → 7 天，见 [planSessionStart]）：
  ///   - 续期成功 → 新会话已入库（用户无感），静默；
  ///   - 续期失败：按 [SessionRenewResult] 分类处理——
  ///     · 续期前**已过期**（会话彻底失效，无论何种失败原因）→ 先
  ///       `clearSession()` 清失效凭据（防残留过期 SESSDATA 被播放取流注入
  ///       → 服务端 -101 拒绝，v2.16.20），再自动引导重新登录一次；
  ///     · **未过期** → 保留现会话不打扰（SESSDATA 仍有效、1080P 继续）：
  ///       refresh_token 失效（[SessionRenewResult.tokenInvalid]）时自动续期
  ///       已不可指望，但强弹登录页会打断仍可用的会话——由播放遇 -101、
  ///       管理面板「登录将过期」与播放页临近过期横幅在会话真正失效前
  ///       引导重登；网络失败（[SessionRenewResult.networkError]）则
  ///       下次启动再试，彻底不打扰；
  /// - 无 SESSDATA（首次使用 / 已登出）→ 自动进入登录页引导登录一次
  ///   （提示条说明「登录后自动保存、下次进入自动恢复」）；登录页可关闭，
  ///   关闭 = 匿名（首页顶部给明确「未登录仅 720P」提示条入口，不默认静默）；
  /// - 存储读取异常（原生插件缺失 / Keystore 故障）→ 静默跳过，不误导登录。
  ///
  /// 决策映射抽成 [planSessionStart]（纯函数，见 bilibili_api.dart，可单测）。
  Future<void> _handleSessionOnStart() async {
    final api = BiliApi();
    Duration? remain;
    bool hasRefreshToken = false;
    try {
      remain = await api.remainingSession();
      hasRefreshToken = await api.hasRefreshToken();
    } catch (e) {
      // 测试环境无 secure storage 原生插件等：静默，不引导登录
      debugPrint('[session] 读取登录态失败，静默跳过自动登录: $e');
      return;
    }
    switch (planSessionStart(remain, hasRefreshToken: hasRefreshToken)) {
      case SessionStartAction.autoLogin:
        debugPrint('[session] 启动检查：无 SESSDATA → 自动进入登录页');
        await _guideAutoLogin();
      case SessionStartAction.refresh:
        SessionRenewResult outcome;
        try {
          outcome = await api.refreshSession();
        } catch (_) {
          outcome = SessionRenewResult.networkError; // 异常按失败处理
        }
        switch (outcome) {
          case SessionRenewResult.renewed:
            debugPrint('[session] 续期成功（新会话已保存），静默恢复');
            return;
          case SessionRenewResult.missingCredentials:
          case SessionRenewResult.tokenInvalid:
          case SessionRenewResult.networkError:
            break;
        }
        // 续期失败：已过期 → 会话彻底失效，先清失效凭据（避免残留过期
        // SESSDATA 被播放取流等请求注入 → 服务端 -101 拒绝），再引导重登
        if (remain != null && remain.isNegative) {
          debugPrint('[session] 会话已过期且续期失败'
              '（outcome=$outcome）→ 清除失效会话并引导重新登录');
          try {
            await api.clearSession();
          } catch (_) {
            // 存储异常静默：引导登录不受影响
          }
          await _guideAutoLogin();
        } else if (outcome == SessionRenewResult.tokenInvalid) {
          // refresh_token 已废但 SESSDATA 本地仍有效：保留现会话（1080P
          // 继续），不弹登录页打扰可用会话；播放 -101/临近过期提示会引导
          debugPrint('[session] 续期失败：refresh_token 失效但会话未过期'
              ' → 保留现会话（播放/临近过期时再引导重登）');
        } else {
          debugPrint('[session] 续期失败（$outcome，未过期）'
              ' → 保留现会话，下次启动再试');
        }
      case SessionStartAction.silent:
        debugPrint('[session] 启动检查：会话有效（≥续期阈值），静默恢复');
    }
  }

  /// 重查登录态并刷新首页「未登录仅 720P」提示条显隐（登录成功/清除后调用；
  /// 读取异常按未登录不显示处理，避免误提示）。
  Future<void> _refreshLoginHint() async {
    final api = BiliApi();
    bool loggedIn = false;
    try {
      final raw = await api.readSessdata();
      final expire =
          raw == null || raw.isEmpty ? null : BiliApi.sessdataExpireAt(raw);
      loggedIn = expire != null && expire.isAfter(DateTime.now());
    } catch (_) {
      // 存储异常（测试环境等）：不显示提示条，避免误导
      return;
    }
    if (mounted && _showLoginHint != !loggedIn) {
      setState(() => _showLoginHint = !loggedIn);
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

  /// 启动 4 秒后静默执行一次关注自动同步（登录态恢复后延迟执行，避免启动
  /// 抢网络；与信箱/更新检查同风格：静默，失败下次启动再试）。
  /// 详见 [FollowingsAutoSyncService] —— 未登录/未配置 GitHub/10 分钟内已
  /// 同步过都会跳过（不发请求）；有新关注加入才刷新列表。
  void _scheduleFollowingsAutoSync() {
    _followingsSyncTimer?.cancel();
    _followingsSyncTimer = Timer(const Duration(seconds: 4), () {
      unawaited(_runFollowingsAutoSync());
    });
  }

  /// 执行一次关注自动同步：B 站关注（前 200）增量加入白名单；有新加入 →
  /// 刷新数据（UP 管理页/信箱检查立即可见）。全程静默不打扰。
  Future<void> _runFollowingsAutoSync() async {
    if (_followingsSyncRunning) return;
    _followingsSyncRunning = true;
    try {
      final result = await FollowingsAutoSyncService().syncOnce();
      if (result.hasAdded && mounted) {
        debugPrint(
            '[followings-sync] 有新关注入白名单（+${result.added}），刷新列表');
        await _load();
      }
    } catch (e) {
      // 全兜底：任何异常都不打扰用户（服务内部已收敛为结果，这里再兜一层）
      debugPrint('[followings-sync] 自动同步兜底异常已忽略: $e');
    } finally {
      _followingsSyncRunning = false;
    }
  }

  /// 手动移除白名单 UP 后，把 mid 记入关注自动同步的跳过名单（避免自动
  /// 同步把用户主动移除的 UP 悄悄加回）。移除本身仍是本地操作，不阻塞。
  void _rememberManualUpownerRemoval(int mid) {
    unawaited(FollowingsAutoSyncService().rememberManualRemoval(mid));
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
        // 数据换了 → 合集卡的「已看 X/Y + N 天前更新」跟着重算。
        // 不 await：统计是本地读表，慢一点也不该拖住列表刷新。
        unawaited(_refreshCollectionStats());
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
  // 合集统计（首页合集卡的「已看 X/Y」+「N 天前更新」角标）：
  // 数据源 = 本地播放历史 [HistoryStore]，纯本地读表，不触网。
  // ---------------------------------------------------------------------------

  /// 合集名 → 统计；空 = 还没加载完（或加载失败）→ 卡片不显示角标与进度条。
  Map<String, CollectionStat> _stats = const {};

  /// 统计是否正在加载：幂等守卫。
  ///
  /// 启动 4s 后的关注自动同步、下拉刷新、UP 详情页返回都会调 [_load]，
  /// 彼此可能重叠；统计是同一份本地数据的纯计算，重复跑只会白读一次表，
  /// 这里直接跳过（结果由在跑的那次写回，数字不会闪）。
  bool _statsLoading = false;

  /// 异步刷新合集统计（失败静默降级）。
  ///
  /// 失败/异常一律吞掉：卡片退回「无角标、无进度条」的素态，绝不弹错、
  /// 绝不中断列表渲染（统计是锦上添花，不是页面可用性的前提）。
  Future<void> _refreshCollectionStats() async {
    if (_statsLoading) return;
    _statsLoading = true;
    try {
      final next = await loadCollectionStats(_data);
      if (!mounted) return;
      setState(() => _stats = next);
    } catch (e) {
      debugPrint('[collection-stats] 统计加载失败，静默降级: $e');
    } finally {
      _statsLoading = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 管理写操作：内存副本 → saveToGist 成功 → 写本地缓存 → 刷新 UI；
  // 失败只提示、不动内存与本地缓存。防沉迷：新增视频入口只有「导入」（与电脑端等价）。
  // ---------------------------------------------------------------------------

  /// 底部提示条。
  ///
  /// [ok] = true（导入成功）时首行加一个小号勾（[AddSuccessSnackContent]，
  /// 与「加入」成功动效同一个勾的形状）。**文案字符串本身不变**。
  void _showSnack(String message, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: ok
              ? AddSuccessSnackContent(message: message)
              : Text(message),
        ),
      );
  }

  /// 统一落库：先校验配置，再写 Gist，成功后写本地缓存并刷新。
  Future<void> _saveAndRefresh(WhitelistData next) async {
    try {
      if (!await _github.hasConfig()) {
        _showSnack('请先在底部导航「个人」配置 GitHub token 与 Gist ID');
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
        // 增删改（移动视频 / 新建合集 / 删除合集）会改变各合集的
        // 「总集数 → 已看 X/Y + 最近更新」→ 统计跟着重算。
        unawaited(_refreshCollectionStats());
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

  /// 打开收藏夹总览页（v2.17.7+ 首页固定「收藏夹」卡）。
  ///
  /// 登录门禁：收藏夹属个人账号数据——无 SESSDATA 先提示并引导登录（复用
  /// [_openLogin]），登录成功才进总览；有会话但已失效 → 总览页内遇 -101
  /// 会再引导重登（兜底，见 FavoritesPage）。
  Future<void> _openFavorites() async {
    Future<String?> readSess() async {
      try {
        return await _writer.api.readSessdata();
      } catch (_) {
        return null; // 存储异常按未登录（页面内仍有 -101 引导兜底）
      }
    }

    var sess = await readSess();
    if (sess == null || sess.isEmpty) {
      if (!mounted) return;
      _showSnack('收藏夹浏览需要登录 B 站账号（收藏夹属于个人账号数据）');
      await _openLogin(context);
      if (!mounted) return;
      sess = await readSess();
      if (sess == null || sess.isEmpty) return; // 仍匿名 → 中止
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const FavoritesPage()),
    );
  }

  /// 打开导入对话框（解析分享链接 → 加入白名单）。
  void _openImport() {
    showDialog<void>(
      context: context,
      builder: (_) => _ImportDialog(
        onImport: _importVideo,
        // 收藏夹批量导入入口：对话框内按钮会先关闭自身再回调（见
        // _ImportDialog 的 onImportFavorites），这里只负责拉起独立流程
        onImportFavorites: _importFromFavorites,
      ),
    );
  }

  /// 从 B 站收藏夹批量导入（v2.17.5+）：配置门禁 → 登录引导 → 收藏夹列表
  /// → 逐视频导入。UI 编排在 [runFavoritesImportFlow]（与番剧整季导入的
  /// runPgcSeasonImport 同模式），这里只负责注入登录回调与刷新列表。
  Future<void> _importFromFavorites() async {
    await runFavoritesImportFlow(
      context: context,
      writer: _writer,
      configHint: '请先在底部导航「个人」配置 GitHub token 与 Gist ID',
      openLogin: () async {
        // 引导登录（复用「B 站账号」入口同一登录页；测试注入替身）
        await _openLogin(context);
        // 登录页返回后重查：已登录 → 继续走收藏夹列表
        return (await _writer.api.readSessdata())?.isNotEmpty ?? false;
      },
      onDone: (_) async => _load(),
    );
  }

  /// 从 B 站「我关注的 UP」批量导入（v2.17.12+）：配置门禁 → 登录引导 →
  /// 勾选页（全选/取消全选，最多前 200 位）→ 批量加入白名单 UP 主。
  /// UI 编排在 [runFollowingsImportFlow]，这里只负责注入登录回调与刷新列表。
  Future<void> _importFollowings() async {
    await runFollowingsImportFlow(
      context: context,
      writer: _upwriter,
      configHint: '请先在底部导航「个人」配置 GitHub token 与 Gist ID',
      openLogin: () async {
        // 引导登录（复用「B 站账号」入口同一登录页；测试注入替身）
        await _openLogin(context);
        // 登录页返回后重查：已登录 → 继续拉关注列表
        return (await _upwriter.api.readSessdata())?.isNotEmpty ?? false;
      },
      onDone: () async => _load(),
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
      configHint: '请先在底部导航「个人」配置 GitHub token 与 Gist ID',
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
      _showSnack('请先在底部导航「个人」配置 GitHub token 与 Gist ID');
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
    _showSnack(
      '已导入：$displayTitle${multi ? '（检测到多个链接，仅导入第一个）' : ''}',
      ok: true,
    );
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

  /// 管理面板装配（v2.18.0+；v2.19.0 起内联在底部导航「个人」页）：
  /// 与（将来的）弹层宿主共用同一 [ManagePanel]（widgets/manage_panel.dart）
  /// ——这里只负责注入宿主回调（管理合集 / 检查更新 / 登录导航）。
  ///
  /// [closeBeforeNavigate]：true = 面板内点「登录 / 检查更新」先 pop 自身
  /// （弹层宿主需要干净上下文）；「个人」页是 PageView 的一页、**不是路由**，
  /// 必须传 false，否则点「登录」会把整个首页 pop 掉。
  ///
  /// 注：新建合集已移到合集页（见 [_showCreateCollectionDialog]），面板不再管。
  ManagePanel _managePanel({
    required bool closeBeforeNavigate,
    required String headingTitle,
    required String headingSubtitle,
  }) {
    return ManagePanel(
      github: _github,
      closeBeforeNavigate: closeBeforeNavigate,
      headingTitle: headingTitle,
      headingSubtitle: headingSubtitle,
      onManageCollections: _openCollectionManage,
      onCheckUpdate: _manualCheckUpdate,
      // 次级「登录 / 重新登录」入口：推登录页（测试可注入替身）
      onLogin: () {
        if (mounted) _openLogin(context);
      },
    );
  }

  /// 「新建合集」入口（合集页顶部常驻 + 空态行动按钮，v2.19.0 从设置区移入）：
  /// 弹输入框收名字，再交给 [_createCollection] 走原来的创建流程
  /// （去重 → 写 Gist → 写本地缓存 → 刷新列表，逻辑与设置页时代完全一致）。
  ///
  /// 校验失败（空名 / 重名 / 保留名）仍由 [_createCollection] 弹提示；
  /// 此时对话框已关闭，用户重新点入口填一次即可（与重命名对话框同风格）。
  Future<void> _showCreateCollectionDialog() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('新建合集'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '合集名称',
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
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null) return;
    await _createCollection(name);
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

  /// 合集卡左滑「重命名」：弹与管理面板**同一个**对话框，再走
  /// [_renameCollection]（校验 → 同步引用 → 写 Gist → 刷新）。
  Future<void> _renameCollectionFromCard(String name) async {
    final newName = await _showRenameCollectionDialog(context, name);
    if (newName == null) return;
    await _renameCollection(name, newName);
  }

  /// 合集卡左滑「删除」：弹与管理面板**同一个**确认框，再走
  /// [_deleteCollection]。视频数口径与 [_openCollectionManage] 的 `countOf` 一致。
  Future<void> _deleteCollectionFromCard(String name) async {
    final count = _data.videos.where((v) => v.collection == name).length;
    final confirmed = await _showDeleteCollectionDialog(context, name, count);
    if (confirmed != true) return;
    await _deleteCollection(name);
  }

  // ---------------------------------------------------------------------------
  // 合集卡片数据：collections 数组顺序即展示顺序；「未分类」固定最后一张。
  // ---------------------------------------------------------------------------

  /// 卡片数据（构造时一次性生成，卡片本身是静态展示）。
  ///
  /// 统计（[_CollectionCardData.stat]）按合集名从 [_stats] 取；未分类卡的
  /// key 用空串 `''`，与 [WhitelistData.sortedVideos] / [CollectionPage]
  /// 的口径一致（统计表里也是空串）。统计还没加载完时取到 null →
  /// 卡片只少一个「N 天前更新」角标和一条进度条，不影响列表渲染。
  List<_CollectionCardData> _cards() {
    final cards = <_CollectionCardData>[];
    void addCard(String name, List<WhitelistVideo> vids) {
      cards.add((
        name: name,
        count: vids.length,
        cover: vids.isNotEmpty ? vids.first.cover : '',
        stat: _stats[name == kUncategorizedLabel ? '' : name],
      ));
    }

    for (final c in _data.collections) {
      addCard(c.name, _data.sortedVideos(c.name));
    }
    // 「未分类」固定卡片：始终显示（含 0 个），让用户知道新导入视频的默认归处
    addCard(kUncategorizedLabel, _data.sortedVideos(''));
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
            child: const Text('移除', style: TextStyle(color: kError)),
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
    // 记入自动同步跳过名单：若该 UP 在 B 站仍被关注，启动自动同步不再加回
    // （"手动移除"优先于"自动同步跟随关注"）。
    _rememberManualUpownerRemoval(up.mid);
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
        : const <_CollectionCardData>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('amoTV'),
        actions: [
          // 信箱入口：未读 > 0 时图标右上角显示计数点。
          // 底色用点缀墨实心档 accentFill（= 「时间与新鲜度」语义，见
          // ink_recipes.dart 的语义约定：未读数/未读点归 accent），文字用
          // onAccent：两档都过对比度护栏，10 套配方下都跟随配色且可读。
          // 旧实现取 colorScheme.error（固定 kError），换配方时红点不变色，
          // 且把「错误」语义色当装饰色用。
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
                      color: context.palette.accentFill,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _inboxUnseen > 99 ? '99+' : '$_inboxUnseen',
                      style: TextStyle(
                        color: context.palette.onAccent,
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
        ],
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          // 滑动落页：同步导航高亮 + 重读目标页数据（点导航切页时
          // [_goToPage] 也会显式刷新一次，两处重复调用是幂等的）
          if (index != _tab) setState(() => _tab = index);
          _reloadTab(index);
        },
        children: [
          // 每页给稳定 key：启动 4s 后的静默同步 setState 会重建 PageView，
          // 无 key 时只能按 index 匹配 Element，State 可能错配/被重置
          // （「个人」页的 ManagePanel 持有输入框与账号状态）。
          _buildCollectionHome(theme, cards),
          _UpownerManagePage(
            key: const ValueKey('upowner'),
            upowners: _data.upowners,
            syncing: _syncing,
            onRefresh: _load,
            onSearch: () => _openSearch(initialTab: 2),
            onOpen: _openUpowner,
            onRemove: _removeUpowner,
            onImportFollowings: _importFollowings,
          ),
          HistoryPage(key: _historyKey),
          // 「个人」（index 3，v2.19.0 把原「统计」+「设置」合并）：观看统计
          // 在上、设置在下的同一滚动流——设置区以 [WatchStatsPage.settingsSection]
          // 交给统计页内联渲染在统计内容之后（[ManagePanel] 无滚动/无内边距，
          // 由统计页的 ListView 提供滚动与留白）。统计页 State 的全局 key
          // [_statsKey] 保留在它自己身上（切到本页时刷新统计）。
          WatchStatsPage(
            key: _statsKey,
            settingsSection: _managePanel(
              closeBeforeNavigate: false,
              headingTitle: '设置',
              headingSubtitle:
                  'GitHub 配置 / 合集管理 / 缓存 / 翻译服务 / B 站账号 集中设置区',
            ),
          ),
        ],
      ),
      // 底部导航（v2.18.0+，v2.19.0 起 4 个目的地，Material 3）：
      // 图标 + 文字标签常显（触摸目标 ≥ 48dp 由 NavigationBar +
      // materialTapTargetSize 保证）。
      // 选中态墨色与指示器底由 app_theme 的 navigationBarTheme 统一配置，
      // 页面不写死颜色；顶部 1px 描边代替阴影（层级靠细线，不靠投影）。
      // tooltip：历史记录逐字沿用旧 AppBar 图标文案（测试锚点）；
      // 「个人」= 观看统计 + 设置（v2.19.0 合并后的新语义）。
      //
      // 描边必须用**独立**的 Divider 占位绘制：`NavigationBar` 自带不透明的
      // `backgroundColor: kPaper`（见 app_theme），若像旧实现那样把描边画在
      // `DecoratedBox.decoration` 里，线画在 child **之下**会被整条盖住
      // （实测截图像素扫描找不到该线）。Divider 是兄弟节点、自己占 1px。
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, thickness: 1, color: kRule),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _goToPage,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.video_library_outlined),
                label: '合集',
                tooltip: '合集（白名单视频）',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                label: 'UP 主',
                tooltip: '白名单 UP 主',
              ),
              NavigationDestination(
                icon: Icon(Icons.history),
                label: '历史',
                tooltip: '历史记录',
              ),
              // 图标不用 person_outline（已被「UP 主」占用，避免两项混淆）
              NavigationDestination(
                icon: Icon(Icons.account_circle_outlined),
                label: '个人',
                tooltip: '个人（观看统计 / 设置）',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCollectionHome(
    ThemeData theme,
    List<_CollectionCardData> cards,
  ) {
    return Column(
      // 稳定 key：静默同步 setState 重建 PageView 时保住本页 Element/State
      key: const ValueKey('home'),
      children: [
        // 未登录提示条（v2.16.21）：登录页被关闭/从未登录时给明确匿名提示 +
        // 去登录入口，不默认静默降级；点击直达登录页（带自动保存说明 banner）
        if (_showLoginHint)
          Material(
            color: theme.colorScheme.secondaryContainer,
            child: InkWell(
              onTap: () => _openLogin(context, banner: kAutoLoginBanner),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _kLoginHintText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18, color: theme.colorScheme.primary),
                  ],
                ),
              ),
            ),
          ),
        _CacheBar(
          fetchedAt: _fetchedAt,
          sourceName: _sourceName,
          error: _error,
        ),
        // 固定「收藏夹」入口卡（v2.17.7+）：不随合集列表滚动、空名单也显示
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: _FavoritesCard(onTap: _openFavorites),
        ),
        // 「新建合集」（v2.19.0 从设置区移到合集页）：合集非空时用顶部常驻按钮
        // ——不随列表滚走，随时可点；且**不进** ReorderableListView（排序索引
        // 与长按拖拽逻辑保持不变）。描边 / 圆角 / 墨色走主题的
        // outlinedButtonTheme（1px kRule + kRadiusMd + 主墨 inkText，无阴影），
        // materialTapTargetSize.padded 保证触摸目标 ≥ 48dp。
        // 空名单时改由空态里的醒目行动按钮承担（见 _EmptyView）。
        if (_hasData)
          Padding(
            padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, 0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _showCreateCollectionDialog,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('新建合集'),
              ),
            ),
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
                          stat: card.stat,
                          draggable: !isUncategorized,
                          onTap: () => _openCollection(card.name),
                          // 「未分类」不可重命名/删除 → 不传回调 → 不启用左滑
                          onRename: isUncategorized
                              ? null
                              : () => _renameCollectionFromCard(card.name),
                          onDelete: isUncategorized
                              ? null
                              : () => _deleteCollectionFromCard(card.name),
                        ),
                      );
                    },
                  )
                : _EmptyView(
                    syncing: _syncing,
                    onCreateCollection: _showCreateCollectionDialog,
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'v$_version · 底部导航切换：合集 / UP 主 / 历史 / 个人',
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
  /// 管理面板手动「登录/重新登录」与首页未登录提示条不传 banner 时可自解释。
  ///
  /// 登录页关闭（登录成功保存后自动 pop / 用户直接返回）都会回来，随后
  /// 重查一次登录态刷新首页「未登录仅 720P」提示条——登录成功即消失、
  /// 保持匿名则保留（无需重启）。
  ///
  /// 测试可注入 [widget.openLogin] 替身（不真推含 WebView 的登录页）。
  Future<void> _openLogin(BuildContext context, {String? banner}) async {
    if (!mounted) return;
    final injected = widget.openLogin;
    if (injected != null) {
      await injected(context, banner: banner);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => LoginPage(banner: banner)),
      );
    }
    await _refreshLoginHint();
    // 登录页返回后若已登录 → 顺手触发一次关注自动同步（启动自动登录/手动
    // 登录后立即把关注同步进白名单；失败静默，且与启动定时器同服务节流
    // —— 10 分钟内不会重复执行）。
    if (!mounted) return;
    try {
      final sess = await _upwriter.api.readSessdata();
      if (sess != null && sess.isNotEmpty) {
        unawaited(_runFollowingsAutoSync());
      }
    } catch (_) {
      // 读登录态异常（测试环境无原生插件等）：跳过本次触发
    }
  }
}

/// 底部导航「UP 主」页（index 1）：白名单 UP 主管理。
class _UpownerManagePage extends StatelessWidget {
  final List<Upowner> upowners;
  final bool syncing;
  final Future<void> Function() onRefresh;
  final VoidCallback onSearch;

  /// 「导入我关注的 UP」（v2.17.12+）：把 B 站关注列表批量加入白名单。
  final VoidCallback onImportFollowings;
  final void Function(Upowner upowner) onOpen;
  final void Function(Upowner upowner) onRemove;

  const _UpownerManagePage({
    super.key,
    required this.upowners,
    required this.syncing,
    required this.onRefresh,
    required this.onSearch,
    required this.onImportFollowings,
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
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: .4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('白名单 UP 主', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '关注 UP 主 = 加入白名单；底部导航「UP 主」可管理，可移除或从 B 站关注列表批量导入',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onImportFollowings,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('导入我关注的 UP'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onSearch,
                      icon: const Icon(Icons.person_search, size: 18),
                      label: const Text('搜索 UP 主'),
                    ),
                  ),
                ],
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
                    separatorBuilder: (_, __) => const SizedBox(height: kListGap),
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

/// 首页合集卡的数据（[_PlaylistPageState._cards] 构造，卡片本身是静态展示）。
///
/// 前三项是卡片原有内容；[stat] 是 P3 新增的观看统计（已看集数 / 总集数 /
/// 最近更新时间）。统计没加载完（或加载失败）时是 null → 卡片只少一个
/// 更新时间角标和一条观看进度条，其余照常渲染。
typedef _CollectionCardData = ({
  String name,
  int count,
  String cover,
  CollectionStat? stat,
});

/// 合集卡底部观看进度条的高度（3px 细条：只表达「推进到哪儿了」）。
const double _kCollectionProgressH = 3;

/// 合集卡底部观看进度条的 key（测试锚点：`total == 0` 时整条不存在）。
///
/// 多张卡片共用同一个 key 值不会冲突（它们各自是不同 [Stack] 的孩子）。
const Key kCollectionProgressBarKey = ValueKey('collection-progress-bar');

/// 合集卡右上角「更新时间角标」的文案；取不到时间 → null（不显示角标，
/// 绝不出现「null 更新」这种）。
///
/// - `fromPubdate == true` → 「3 天前更新」（B 站真实发布时间，最可信）；
/// - `fromPubdate == false` → 「3 天前加入」（只有加入白名单的时间可兜底，
///   文案改说「加入」，不谎称「更新」）；
/// - 一年以上 → [fmtRelativeTime] 给绝对日期「2024-03-15更新」。
///
/// [now] 仅供测试注入固定的「现在」。
String? collectionBadgeText(CollectionStat? stat, {DateTime? now}) {
  final updatedAt = stat?.updatedAt;
  if (updatedAt == null) return null;
  final rel = fmtRelativeTime(updatedAt, now: now);
  return '$rel${stat!.fromPubdate ? '更新' : '加入'}';
}

/// 合集卡片（行式）：左侧代表视觉（封面 / 渐变底 + 图标），右侧合集名 +
/// 更新时间角标 + 视频数 / 观看进度，尾部拖动手柄提示（未分类不可拖不显示）。
///
/// - **左滑操作块**（v2.19.x）：整卡由 [SwipeActionBox] 包住，左滑露出
///   「重命名」「删除」；[onRename] / [onDelete] 都不传（「未分类」固定卡）
///   时左滑整块关掉（`enabled: false`，树里连手势层都没有）。「收藏夹」
///   入口卡是 [_FavoritesCard]，不经过这里。
///
/// 块化（P3「合集卡成为视觉主角」）：
/// - 底板交给 [AppBlock] 的 [AppBlockVariant.collectionCard] 规格
///   （kPaperCool 冷底 + kRuleStrong 1px 描边 + kRadiusMd 圆角 + all(10)
///   内边距），与原来的 Material 版外观等价，只是外形收敛到统一规格表；
/// - **既有文案原样保留**：`'$count 个视频'` 仍是独立的 [Text]（页面测试
///   `find.text('0 个视频')` 逐字命中），新加的「已看 X/Y」是**另一个**
///   [Text] 挂在它旁边（不拼接、不改写既有字符串）；
/// - 更新时间角标放在**名称行尾（卡片右上角）**而不是封面右上角：日期文案
///   最长会是「2024-03-15更新」这种十来字符，压在 64×64 的封面角上会盖住
///   封面、溢出到名称上；挂在名称行尾由 [Expanded] 自然让位，既不重叠
///   也不碰尾部拖拽把手；
/// - 观看进度 = 底部 3px 细条（贴卡片下沿，一眼看出推进度）+ 副信息行的
///   「已看 X/Y」文字（承载精确数字），两者都不与拖拽把手抢位置。
class _CollectionCard extends StatelessWidget {
  final String name;
  final int count;
  final String cover; // 该合集首个视频封面（无视频/未分类 → 空串走图标）
  final bool draggable; // 是否可拖动（未分类固定最后，不可拖）
  final VoidCallback onTap;

  /// 左滑「重命名」回调；null → 不启用左滑操作块（「未分类」固定卡）。
  final VoidCallback? onRename;

  /// 左滑「删除」回调；null → 不启用左滑操作块。
  final VoidCallback? onDelete;

  /// 该合集的观看统计；null = 统计未加载完（或加载失败）→ 素态显示。
  final CollectionStat? stat;

  const _CollectionCard({
    required this.name,
    required this.count,
    required this.cover,
    required this.draggable,
    required this.onTap,
    this.stat,
    this.onRename,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUncategorized = name == kUncategorizedLabel;
    final stat = this.stat;
    final total = stat?.total ?? 0;
    // 已看集数夹在 [0, total]：统计端已保证 watched <= total，这里只防脏数据
    // 把进度条比例画错（负数和 >total 都算不出合法宽度）。
    var watched = stat?.watched ?? 0;
    if (watched < 0) watched = 0;
    if (watched > total) watched = total;
    final badge = collectionBadgeText(stat);
    final showProgress = total > 0; // 0 集不画进度条（除法也没意义）

    final card = ClipRRect(
      // 圆角裁剪：底部进度条是贴卡片下沿的通栏矩形，不裁就会从卡片圆角处
      // 露出直角（[AppBlock] 只在带左竖条时才自己裁）。
      borderRadius: BorderRadius.circular(kRadiusMd),
      child: Stack(
        children: [
          AppBlock(
            variant: AppBlockVariant.collectionCard,
            child: Material(
              // 透明 Material = 只提供 ink 图层。放在 [AppBlock] **内部**是
              // 关键：块的冷底是不透明 Container，Material 若在外层，水波
              // 会被压到底色之下（完全看不见）。水波范围 = 内容区（内边距
              // 之内），整卡的拖动不受影响（拖拽监听在卡片外层）。
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
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
                                // 与 CoverImage 一致：必须带防盗链头，否则
                                // B 站图床 403
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
                          // 名称行：合集名（超长省略号）+ 右上角更新时间角标
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                              if (badge != null) ...[
                                const SizedBox(width: kSpace8),
                                _UpdateBadge(text: badge),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          // 副信息行：既有「N 个视频」+ 新增「已看 X/Y」
                          Row(
                            children: [
                              Text(
                                '$count 个视频',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (showProgress) ...[
                                const SizedBox(width: kSpace8),
                                Flexible(
                                  child: Text(
                                    '已看 $watched/$total',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: kTypeNum.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    // 拖动手柄提示（可拖动的合集才显示；未分类不可拖）
                    if (draggable)
                      Icon(
                        Icons.drag_indicator,
                        size: 20,
                        color:
                            theme.colorScheme.outline.withValues(alpha: .55),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // 底部 3px 细进度条：已看段用图形墨 [AppPalette.inkDeco]（数据编码
          // 专用档，浅墨配方下会自动压深，保证在 kPaperCool 冷底上看得见），
          // 未看段用 kRule（比冷底深一档，能看出「还剩多少」）。
          // 宽度按 flex 比例分（watched : total - watched），不用先算浮点数。
          if (showProgress)
            Positioned(
              key: kCollectionProgressBarKey,
              left: 0,
              right: 0,
              bottom: 0,
              height: _kCollectionProgressH,
              child: Row(
                children: [
                  if (watched > 0)
                    Expanded(
                      flex: watched,
                      child: ColoredBox(color: context.palette.inkDeco),
                    ),
                  if (total - watched > 0)
                    Expanded(
                      flex: total - watched,
                      child: const ColoredBox(color: kRule),
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    // 左滑操作块（v2.19.x）：只对**真实合集**启用 —— 「未分类」是不可
    // 重命名/删除的固定卡（页面不传回调 → enabled=false → 直接就是这张卡，
    // 零手势层）。「收藏夹」卡是另一个 widget，压根不经过这里。
    final canSwipe = onRename != null && onDelete != null;
    return SwipeActionBox(
      enabled: canSwipe,
      actions: [
        if (onRename != null)
          SwipeAction(
            label: '重命名',
            icon: Icons.drive_file_rename_outline,
            color: context.palette.inkFill,
            textColor: context.palette.onInk,
            onTap: onRename!,
          ),
        if (onDelete != null)
          SwipeAction(
            label: '删除',
            icon: Icons.delete_outline,
            color: kError,
            textColor: kPaper,
            onTap: onDelete!,
          ),
      ],
      child: card,
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

/// 合集卡的更新时间角标（「3 天前更新」/「3 天前加入」）。
///
/// 底色取点缀墨稀释档 [AppPalette.accentWash]、文字取 [AppPalette.accentDeep]：
/// 点缀墨（赤陶）的固定职责就是「时间与新鲜度」（角标 / 未读点，见
/// app_tokens.dart 的语义约定），这里是它最正当的用法，换配色时自动跟随。
class _UpdateBadge extends StatelessWidget {
  final String text;

  const _UpdateBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.palette.accentWash,
        borderRadius: BorderRadius.circular(kRadiusXs),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: kTypeLabel.copyWith(color: context.palette.accentDeep),
      ),
    );
  }
}

/// 首页固定「收藏夹」入口卡（v2.17.7+）：样式同合集卡（行式 + 64 视觉位，
/// 底板走 [AppBlock] 的 [AppBlockVariant.collectionCard] 规格：冷底 +
/// 1px kRuleStrong 描边 + kRadiusMd 圆角 + all(10) 内边距），但用
/// folder_special 图标 + 独立渐变与副标「我的 B 站收藏」作视觉区分；
/// 不参与拖拽排序（合集区顶部常驻，未登录/空名单也显示），也没有观看统计
/// （收藏夹是 B 站账号数据，不属于白名单）。
class _FavoritesCard extends StatelessWidget {
  final VoidCallback onTap;

  const _FavoritesCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBlock(
      variant: AppBlockVariant.collectionCard,
      child: Material(
        // 透明 Material = 仅提供 ink 图层（同合集卡：块的冷底不透明，
        // Material 必须在块内部水波才可见）
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              // 代表视觉：收藏夹专属渐变 + folder_special 图标（区别于合集封面）
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.tertiaryContainer,
                        theme.colorScheme.primaryContainer,
                      ],
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.folder_special_outlined,
                      size: 32,
                      color: theme.colorScheme
                          .onTertiaryContainer
                          .withValues(alpha: .55),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '收藏夹',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '我的 B 站收藏',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.outline.withValues(alpha: .55),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导入对话框：多行输入框粘贴 B 站分享链接/文本，确认后交回页面执行导入；
/// 下方提供「从 B 站收藏夹导入」批量入口（v2.17.5+，需登录）。
class _ImportDialog extends StatefulWidget {
  final Future<void> Function(String text) onImport;

  /// 收藏夹批量导入入口回调：按钮点击时先关闭本对话框再回调（独立流程）。
  final VoidCallback? onImportFavorites;

  const _ImportDialog({required this.onImport, this.onImportFavorites});

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
          if (widget.onImportFavorites != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                // 收藏夹属于个人账号数据：需登录（未登录会引导登录）
                icon: const Icon(Icons.bookmarks_outlined, size: 18),
                label: const Text('从 B 站收藏夹批量导入'),
                onPressed: () {
                  // 先关闭粘贴导入对话框，再走独立的收藏夹导入流程
                  Navigator.of(context).pop();
                  widget.onImportFavorites!();
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '把整个收藏夹（默认夹/自建夹）里的视频一键批量加入白名单，'
              '已在白名单的自动跳过。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
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
///
/// 两种情况画面语言不同（本轮统一）：
/// - [syncing] == true：**冷启动同步中**，整页走 [AppLoadingHero]（风衣男剪影
///   + 加载闲话），与本版本其它整页加载态同一气质；主文案「正在同步白名单…」
///   逐字保留（测试锚点），只换画面不换文案。此态**不显示「新建合集」**——
///   白名单还没同步回来，此时建合集是误导。
/// - [syncing] == false：白名单确实为空，给醒目行动按钮「新建合集」（新建合集
///   入口从设置区移到了合集页；合集非空时该入口在列表上方常驻，不重复出现在
///   这里）。主文案「白名单为空\n下拉刷新重新同步」逐字保留（widget 测试锚点）。
class _EmptyView extends StatelessWidget {
  final bool syncing;

  /// 「新建合集」回调（页面弹输入框 → 复用页面的 `_createCollection`）。
  final VoidCallback onCreateCollection;

  const _EmptyView({
    required this.syncing,
    required this.onCreateCollection,
  });

  @override
  Widget build(BuildContext context) {
    if (syncing) {
      // 宿主是 RefreshIndicator → 必须 scrollable: true 才能下拉刷新。
      return const AppLoadingHero(
        title: '正在同步白名单…',
        seed: 'playlist.sync',
        scrollable: true,
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.inbox_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        const Center(child: Text('白名单为空\n下拉刷新重新同步')),
        // 行动按钮：主按钮（FilledButton = 主墨实心底，同「搜索并加入 UP 主」
        // 空态动作），触摸目标 ≥ 48dp 由 materialTapTargetSize.padded 保证
        const SizedBox(height: kSpace16),
        Center(
          child: FilledButton.icon(
            onPressed: onCreateCollection,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('新建合集'),
          ),
        ),
      ],
    );
  }
}

/// 重命名对话框（合集卡左滑 + 管理面板**共用同一入口**）。
///
/// 只负责收名字：返回用户输入（null = 取消）；校验 / 同步引用 / 落库一律
/// 交给 [_PlaylistPageState._renameCollection]。文案逐字保留（既有测试锚点）。
Future<String?> _showRenameCollectionDialog(
  BuildContext context,
  String oldName,
) async {
  final ctrl = TextEditingController(text: oldName);
  final newName = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text('重命名合集「$oldName」'),
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
  return newName;
}

/// 删除确认对话框（合集卡左滑 + 管理面板共用）：提示该合集下 N 个视频将
/// 移回未分类。返回 true = 用户确认（null = 取消/点外部关掉）。
Future<bool?> _showDeleteCollectionDialog(
  BuildContext context,
  String name,
  int count,
) {
  return showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text('删除合集「$name」'),
      content: Text(
        '确定删除合集「$name」吗？\n'
        '该合集下 $count 个视频将移回未分类（视频本身不会被删除）。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('删除', style: TextStyle(color: kError)),
        ),
      ],
    ),
  );
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
    final newName = await _showRenameCollectionDialog(context, collection.name);
    if (newName == null || !mounted) return;
    await widget.onRename(collection.name, newName);
    if (mounted) setState(() {}); // 重拉合集列表（页面 _data 已更新）
  }

  /// 删除确认对话框：提示该合集下 N 个视频将移回未分类。
  Future<void> _delete(CollectionInfo collection) async {
    final count = widget.countOf(collection.name);
    final confirmed =
        await _showDeleteCollectionDialog(context, collection.name, count);
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


