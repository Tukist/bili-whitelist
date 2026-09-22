import 'dart:async';

import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../api/translate_api.dart';
import '../cache/download_manager.dart';
import '../pages/offline_page.dart';
import '../services/clipboard_link_store.dart';
import '../services/inbox_card_style_store.dart';
import '../services/theme_store.dart';
import '../services/ui_copy_store.dart';
import '../services/ui_prefs_store.dart';
import '../services/web_login_cookies.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/ink_recipes.dart';
import 'app_snack.dart';
import 'inbox_card_styles.dart';

/// 管理面板内容组件（v2.17.10+ 抽取自首页 _ManageSheet；v2.19.0 起由
/// 底部导航「个人」页内联承载）：
///
/// - **「个人」页的「设置」区**（watch_stats_page 的 settingsSection，页面
///   最下方）：直接嵌入统计页滚动流，`closeBeforeNavigate: false`
///   （面板不是路由，不能 pop）
/// - **（将来的）弹层宿主**：BottomSheet 包一层 [ManagePanel] 时传
///   `closeBeforeNavigate: true`（点「登录 / 检查更新」先关面板再让页面
///   动作，干净上下文）
///
/// 内容分区：B 站账号（登录/重新登录）→ 配色主题（P1.5 双墨配方切换）→
/// 信箱卡片样式（v2.21.0+ 多版式切换）→
/// GitHub 配置（token/gist）→ 合集管理（重命名/删除）→ 离线缓存管理 →
/// 翻译服务 → 界面文案（空态/加载/错误/页脚，可改可恢复，v2.19.0 补）→
/// 启动行为 → 界面提示 → **写操作（v2.40.0+，点赞/投币/收藏总开关，
/// v2.42.0+ 加入评论，默认关）** → 版本更新（检查更新）。面板只含内容本身（无自己的滚动/
/// 内边距），外层（弹层 or 页面滚动流）负责滚动与留白。
/// **新建合集已移到合集页**（v2.19.0），面板不再提供该分区。
///
/// 各项操作以回调交给宿主页面（管理合集、检查更新、登录页导航都依赖
/// 宿主状态），面板内部只持有配置表单与账号状态。「界面文案」是唯一
/// **不经过宿主**的分区：它自己读 [UiCopyStore]、自己弹编辑层（宿主零改动）。
class ManagePanel extends StatefulWidget {
  final GithubApi github;

  /// 「粘贴 Cookie 登录」用的接口客户端（测试注入 fake adapter 用；
  /// 默认自建一个——校验必须走真实的 B 站 `nav` 接口才算数）。
  final BiliApi? bili;

  /// 打开合集管理面板（重命名 / 删除；宿主维护合集数据）。
  final VoidCallback onManageCollections;

  /// 检查更新入口（宿主弹更新对话框）。
  final VoidCallback onCheckUpdate;

  /// B 站账号：宿主推登录页（登录 / 重新登录共用）。
  final VoidCallback onLogin;

  /// 登录态发生变化（面板里的「粘贴 Cookie 登录」成功）时通知宿主。
  ///
  /// 为什么要通知：宿主要重查一次登录态刷新它自己的「未登录仅 720P」提示条、
  /// 并触发一次关注自动同步（与「登录页返回后」的处理保持一致）；
  /// 不通知的话，用户粘贴登录成功后回到首页**仍会看到「未登录」提示条**，
  /// 直到下次冷启动。
  final VoidCallback? onSessionChanged;

  /// 宿主是否为弹层：true = 点「登录 / 检查更新」先 pop 自己再执行回调
  /// （弹层需要让 SnackBar/Dialog 显示在干净上下文）；false = 内联嵌入
  /// 页面（不是路由，不 pop）。
  final bool closeBeforeNavigate;

  /// 面板标题（弹层用「管理」；「个人」页内联用「设置」）。
  final String headingTitle;

  /// 标题下的说明文案。
  final String headingSubtitle;

  const ManagePanel({
    super.key,
    required this.github,
    this.bili,
    required this.onManageCollections,
    required this.onCheckUpdate,
    required this.onLogin,
    this.onSessionChanged,
    this.closeBeforeNavigate = false,
    this.headingTitle = '管理',
    this.headingSubtitle =
        '管理功能只允许：重命名 / 删除合集，移动 / 删除视频'
        '（新建合集在合集页顶部）。'
        '新增白名单走右上角「导入」或「搜索」入口（加入前会查重）。',
  });

  @override
  State<ManagePanel> createState() => _ManagePanelState();
}

/// B 站账号登录态（管理面板顶部状态展示）。
///
/// [storageError] 单列一项（v2.49.1+）：secure storage 读取抛异常（Keystore
/// 故障 / 原生插件缺失）与「压根没登录」是两回事，旧代码都显示成「未登录」
/// ——那会让用户以为"登一次就好"，而实际是登了也存不住，白折腾。
enum _AccountState { loading, loggedIn, expired, none, storageError }

/// 「启动时播放剪贴板里的视频」开关的 key（测试锚点；v2.35.0）。
const Key kClipboardOpenSwitchKey = Key('clipboard-open-switch');

/// 「显示底部提示条」开关的 key（测试锚点；v2.36.0）。
const Key kTipsSwitchKey = Key('ui-tips-switch');

/// 「允许点赞 / 投币 / 收藏」总开关的 key（测试锚点；v2.40.0）。
const Key kWriteActionsSwitchKey = Key('ui-write-actions-switch');

/// 「粘贴 Cookie 登录」入口按钮的 key（测试锚点；v2.49.1+）。
const Key kPasteCookieButtonKey = Key('paste-cookie-login');

/// 「退出登录」入口按钮的 key（测试锚点；v2.49.1+）。
const Key kLogoutButtonKey = Key('bili-logout');

class _ManagePanelState extends State<ManagePanel> {
  final _tokenCtrl = TextEditingController();
  final _gistCtrl = TextEditingController();
  bool _loadingConfig = true;
  bool _savingConfig = false;
  bool _obscureToken = true;

  /// B 站账号状态（读取 secure storage 的 SESSDATA 剩余有效期判断）。
  _AccountState _account = _AccountState.loading;

  /// SESSDATA 剩余有效期（-1 秒 = 刚过期；仅展示用，不涉及具体凭据内容）。
  Duration? _accountRemain;

  /// 「退出登录」正在清理中（清凭据 + 清 WebView cookie，可能跨原生通道，
  /// 期间禁用按钮防重复点）。
  bool _loggingOut = false;

  /// 本机是否有会话（含已过期那种）：决定「退出登录」入口是否出现。
  ///
  /// 只认 [loggedIn] / [expired] 两种：它们代表"有一份东西可以退"。
  /// [loading] 状态未知先不显示（避免按钮闪一下又消失）、[none]
  /// 与 [storageError] 都没有可退的会话（后者是**读不到**存储，
  /// 此时清也清不动，给按钮等于给一个按了没反应的入口）。
  bool get _hasSession =>
      _account == _AccountState.loggedIn || _account == _AccountState.expired;

  @override
  void initState() {
    super.initState();
    // 文案覆盖表是懒加载的（[UiCopyStore.text] 同步读内存、[UiCopyStore.ensureLoaded]
    // 异步读一次盘）：设置面板是唯一写入入口，顺手把盘上的覆盖读进来，
    // 免得面板里显示的是默认值而页面上已经是用户改过的文案。
    // 幂等（已加载过直接返回）、读失败在 store 内部静默，不阻塞面板。
    unawaited(UiCopyStore.instance.ensureLoaded());
    _loadConfig();
    _loadAccount();
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _gistCtrl.dispose();
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
      // 存储读取异常（Keystore 故障 / 插件缺失）：**不要显示成「未登录」**——
      // 那是"你登一次就好"的误导（v2.49.1+）。仍保留「登录」按钮可手动重试。
      next = _AccountState.storageError;
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
      case _AccountState.storageError:
        // 与「未登录」区分：这里是**读不到本机存的登录态**（系统密钥库异常），
        // 不是"没有登录态"。措辞要挡住"再登一次就好了"的误解。
        return '读取登录态失败：本机安全存储异常（系统密钥库问题）。'
            '可点「登录」重试；若一直如此，重启手机通常可恢复。';
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
      // 失败类：走 AppSnack 的 error 档 —— 关掉「界面提示」也不静默（用户
      // 以为存上了、其实没存，是最坏的一种"提示被关掉"）
      if (mounted) {
        _showSnack('配置保存失败，请重试', kind: SnackKind.error);
      }
    } finally {
      if (mounted) setState(() => _savingConfig = false);
    }
  }

  /// 设置页内的提示条入口（统一走 AppSnack，见 [AppSnack] 的说明）。
  void _showSnack(String message, {SnackKind kind = SnackKind.info}) {
    if (!mounted) return;
    AppSnack.show(context, message, kind: kind);
  }

  /// 弹层宿主：动作前先 pop 自己（登录/检查更新需干净上下文弹 UI）。
  void _maybeCloseSheet() {
    if (widget.closeBeforeNavigate) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.headingTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          widget.headingSubtitle,
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
            // 弹层内先关闭面板再推登录页（与「检查更新」同模式，干净上下文）
            onPressed: () {
              _maybeCloseSheet();
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
        const SizedBox(height: 8),
        // ---- 粘贴 Cookie 登录（v2.49.1+）：不依赖 WebView 的兜底登录路径 ----
        //
        // 为什么要有它：真机上登录页的 WebView 渲染进程每次必崩（系统日志
        // `Renderer process crash detected`），WebView 这条路直接不可用。
        // 必须留一条"不管 WebView 好坏都能登进去"的路，否则用户只能干等我们修
        // 环境问题——而那是他的手机/网络里的代理导致的。
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: kPasteCookieButtonKey,
            onPressed: _showPasteCookieDialog,
            icon: const Icon(Icons.content_paste_go, size: 18),
            label: const Text('粘贴 Cookie 登录（WebView 打不开时用）'),
          ),
        ),
        // ---- 退出登录（v2.49.1+）：只在**本机有会话**时出现 ----
        //
        // 为什么要有它：在此之前"退不出登录"——用户想换个账号 / 把凭据从
        // 这台机器上抹掉，只能去系统设置里清 App 数据（等于顺手丢掉 GitHub
        // 配置与全部本地数据）。而登录态存在两处（secure storage + WebView
        // cookie jar），**只清一处都会留下另一半**，必须由 App 一次清干净。
        //
        // 未登录 / 读不到登录态时**不显示**（而不是置灰）：那种状态下点了
        // 也没东西可退，留一个永远点不动的按钮只会让人怀疑"是不是还有残留"。
        if (_hasSession) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: kLogoutButtonKey,
              onPressed: _loggingOut ? null : _confirmLogout,
              icon: const Icon(Icons.logout, size: 18),
              label: Text(_loggingOut ? '正在退出…' : '退出登录'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // ---- 配色主题（P1.5 双墨配方切换，选中立即生效）----
        Text('配色主题', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '从双墨配方里挑一套：主墨管「观看」，点缀墨管「时间与新鲜度」。'
          '选中立即生效，仅存本机。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 按钮上的配方名要跟着当前配色走 → 单独监听 ThemeStore
        ListenableBuilder(
          listenable: ThemeStore.instance,
          builder: (context, _) => SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openThemePicker(context),
              icon: const Icon(Icons.palette_outlined, size: 18),
              label: Text(
                '配色：${ThemeStore.instance.recipe.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // ---- 信箱卡片样式（v2.21.0+：多版式，选中立即生效）----
        Text('信箱卡片样式', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '信箱页左右滑动的卡片版式：都是扑克牌比例（1:1.39），'
          '只是排版不同。选中立即生效，仅存本机。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 按钮上的当前风格名要跟着 store 走 → 单独监听 InboxCardStyleStore
        ListenableBuilder(
          listenable: InboxCardStyleStore.instance,
          builder: (context, _) => SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openCardStylePicker(context),
              icon: const Icon(Icons.style_outlined, size: 18),
              label: Text(
                '卡片样式：${InboxCardStyleStore.instance.style.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
        // ---- 合集管理（重命名 / 移动 / 删除）；新建合集在合集页（v2.19.0 移出）----
        Text('合集管理', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          // v2.30.0：「移动到其他合集」的语义是**嵌套**（源合集不被删除），
          // 这里一句话说清三个动作的后果，与合集管理面板里的说明同一口径
          '重命名会同步更新它的子合集与所有视频；移动到其他合集会把它整个'
          '（含视频与子合集）挪到目标下面，不会删除它；删除会把视频移回未分类、'
          '子合集上提一级（以上都不删视频）。',
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
        // ---- 离线缓存（v2.29.0：弹层升级成独立页，见 offline_page.dart）----
        Text('离线缓存', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '下载过的视频缓存在本机，断网也能播放；大小只受手机存储限制。'
          '「仅缓存音频」可把占用压到十分之一（无画面）。',
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
            // 文案带实时概要（N 个视频 · X）：不用点进去就知道占了多少
            label: ListenableBuilder(
              listenable: DownloadManager.instance.cached,
              builder: (context, _) {
                final items = DownloadManager.instance.getCachedList();
                return Text(items.isEmpty
                    ? '缓存管理'
                    : '缓存管理（${items.length} 个视频'
                        ' · ${fmtBytes(DownloadManager.instance.totalCacheSize())}）');
              },
            ),
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
        // ---- 界面文案（空态 / 加载 / 错误 / 页脚的可改文案）----
        Text('界面文案', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '空态、加载、错误和页脚的那几句话都能改成你自己的；'
          '改完立刻生效（所有页面同步），只存本机，随时可恢复默认。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 按钮文案要跟着覆盖条数走 → 单独监听 UiCopyStore
        ListenableBuilder(
          listenable: UiCopyStore.instance,
          builder: (context, _) {
            final n = copyOverrideCount();
            return SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key(_kCopyEditorEntryKey),
                onPressed: () => _openCopyEditor(context),
                icon: const Icon(Icons.text_fields_outlined, size: 18),
                label: Text(n == 0 ? '全部为默认' : '已自定义 $n 条'),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // ---- 启动行为（v2.35.0：剪贴板里的 B 站链接直接开播；v2.50.0 副标题压到两行）----
        Text('启动行为', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        // 两行上限：只说清「在读剪贴板」（隐私）与「仅存本机」（范围），
        // b23.tv / 分享文本那类解析细节与"只读一次"的机制留在代码与 CHANGELOG 里。
        Text(
          '冷启动时读一次剪贴板，有 B 站视频链接就直接打开播放。仅存本机。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 开关态要跟着 store 走 → 单独监听 ClipboardLinkStore
        ListenableBuilder(
          listenable: ClipboardLinkStore.instance,
          builder: (context, _) {
            final on = ClipboardLinkStore.instance.enabled;
            return SwitchListTile(
              key: kClipboardOpenSwitchKey,
              value: on,
              onChanged: (v) => ClipboardLinkStore.instance.setEnabled(v),
              contentPadding: EdgeInsets.zero,
              title: const Text('启动时播放剪贴板里的视频'),
              subtitle: Text(on
                  ? '已开启：复制一条 B 站视频链接，下次打开 App 直接播'
                  : '已关闭：冷启动不读剪贴板'),
            );
          },
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // ---- 界面提示（v2.36.0：底部提示条开关；v2.50.0 副标题压到两行）----
        Text('界面提示', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        // 两行上限：开头这句是既有用例钉着的锚点（test/ui_prefs_snack_test.dart），
        // 后半只留"错误提示 / 撤销提示一定会显示"这条不可关的例外，枚举的例子删掉。
        Text(
          '关掉后不再弹底部的提示条；错误提示与带「撤销」的提示一定会显示。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 开关态要跟着 store 走 → 单独监听 UiPrefsStore
        ListenableBuilder(
          listenable: UiPrefsStore.instance,
          builder: (context, _) {
            final on = UiPrefsStore.instance.showTips;
            return SwitchListTile(
              key: kTipsSwitchKey,
              value: on,
              onChanged: (v) => UiPrefsStore.instance.setShowTips(v),
              contentPadding: EdgeInsets.zero,
              title: const Text('显示底部提示条'),
              subtitle: Text(on
                  ? '已开启：操作结果都会用底部提示条告知'
                  : '已关闭：只剩错误提示与带「撤销」的提示'),
            );
          },
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // ---- 写操作（v2.40.0+：点赞 / 投币 / 收藏；v2.42.0+ 含评论；
        //       v2.50.0 副标题压到两行）----
        Text('写操作', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        // 两行上限：只留三条安全信息——① 作用在你的 B 站账号上；② 默认关闭；
        // ③ 投币不可撤回。评论"会立刻公开"附在括号里（这条原本也有用例钉着，
        // 见 test/write_actions_prefs_test.dart）。改账号状态的具体后果枚举、
        // "投币会再问一次 / 评论先写好再发送"的操作细节与"投稿不在这里"的
        // 免责说明都删掉了（它们在 CHANGELOG 里）。
        Text(
          '会在你的 B 站账号上点赞 / 投币 / 收藏 / 评论（会立刻公开）。'
          '默认关闭，投币不可撤回。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // 开关态要跟着 store 走 → 单独监听 UiPrefsStore
        ListenableBuilder(
          listenable: UiPrefsStore.instance,
          builder: (context, _) {
            final on = UiPrefsStore.instance.writeActionsEnabled;
            return SwitchListTile(
              key: kWriteActionsSwitchKey,
              value: on,
              onChanged: (v) =>
                  UiPrefsStore.instance.setWriteActionsEnabled(v),
              contentPadding: EdgeInsets.zero,
              title: const Text('允许点赞 / 投币 / 收藏 / 评论'),
              subtitle: Text(on
                  ? '已开启：信息块显示三个按钮，评论区可发表与回复'
                  : '已关闭：一个写操作入口都不显示'),
            );
          },
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
              // 弹层内先关面板再检查，让 SnackBar / Dialog 显示在干净上下文
              _maybeCloseSheet();
              widget.onCheckUpdate();
            },
            icon: const Icon(Icons.system_update_alt_outlined, size: 18),
            label: const Text('检查更新'),
          ),
        ),
      ],
    );
  }

  /// 打开配色主题选择器（P1.5）：列出全部双墨配方，选中立即生效并关闭弹层。
  void _openThemePicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _InkRecipeSheet(),
    );
  }

  /// 打开「信箱卡片样式」选择器（v2.21.0+）：列出全部版式（带缩略预览），
  /// 选中立即生效并关闭弹层。
  void _openCardStylePicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _InboxCardStyleSheet(),
    );
  }

  /// 打开离线缓存页（v2.29.0：原来是弹层 [_CacheManageSheet]，现为独立页）。
  ///
  /// 页面自带 Scaffold（可滚动、分组、分项占用），不再需要弹层包裹；
  /// 弹层的其余逻辑已全部搬进 `pages/offline_page.dart`，不并存两套。
  void _openCacheManage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const OfflinePage()),
    );
  }

  /// 打开界面文案编辑弹层。
  ///
  /// 弹层自己读/写 [UiCopyStore]（宿主零改动）；弹层选择「全部恢复默认」
  /// 时会连带关掉自己并回一个 [_CopyEditorResult.resetAll]——这样 SnackBar
  /// 显示在弹层关掉之后的干净上下文里（弹层开着时 SnackBar 被它盖住看不见）。
  Future<void> _openCopyEditor(BuildContext context) async {
    final result = await showModalBottomSheet<_CopyEditorResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _CopyEditorSheet(),
    );
    if (result == _CopyEditorResult.resetAll && context.mounted) {
      _showSnack('已全部恢复默认');
    }
  }

  /// 打开「粘贴 Cookie 登录」弹层（v2.49.1+）。
  ///
  /// 成功后：重读本面板的账号状态 + 通知宿主重查登录态（同 [_showTranslateConfig]
  /// 的"对话框 pop 后再提示"模式，让 SnackBar 显示在干净上下文里）。
  Future<void> _showPasteCookieDialog() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _PasteCookieDialog(api: widget.bili ?? BiliApi()),
    );
    if (saved != true || !mounted) return;
    _loadAccount();
    widget.onSessionChanged?.call();
    _showSnack('登录成功，已解锁 1080P 清晰度（仅存本机）');
  }

  /// 「退出登录」（v2.49.1+）：确认后把**两处**凭据一起清干净。
  ///
  /// 为什么两处都要清（这是这个功能最容易做错的地方）：
  /// - secure storage 那三个 key（`bili_sessdata` / `bili_jct` /
  ///   `bili_refresh_token`）是 App 自己用会话的地方；
  /// - WebView 的 cookie jar 是**同一份会话的第二处拷贝**，而且登录页是拿它
  ///   判"登录是否成功"的。只清 storage 不清它 → 用户下次打开登录页，登录页
  ///   读到这份残留 cookie → 拿去服务端校验（v2.49.1+ 的校验就是这样）→
  ///   若那份 cookie 还有效就"自动登录回去"了，退出等于没退。
  ///
  /// 顺序：先清 storage（权威那份），再清 WebView cookie。反之亦然其实都行，
  /// 但先清 storage 更安全——万一第二步的原生通道炸了，至少 App 自己的登录态
  /// 已经没了，不会出现"App 还在用旧会话、用户以为退了"。
  ///
  /// 退完**不推登录页**（那是用户的下一步选择），只把状态刷新成未登录：
  /// 重读本面板账号区 + 通知宿主（宿主重查登录态刷新首页「未登录仅 720P」
  /// 提示条，与「粘贴 Cookie 登录」成功时同一口径）。
  Future<void> _confirmLogout() async {
    // 确认框沿用项目既有样式（AlertDialog + 取消 / 危险动作红色文字）
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('退出 B 站登录？'),
        content: const Text(
          '会清除本机保存的登录凭据（SESSDATA / bili_jct / 刷新口令）'
          '以及登录页 WebView 里的 B 站 cookie。'
          '退出后收藏夹、点赞、收藏、评论都不能用，需要重新登录；'
          'GitHub 配置、白名单与离线缓存不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('退出', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loggingOut = true);
    final api = widget.bili ?? BiliApi();

    // 1) 本机凭据（三个 key）
    var storageOk = true;
    try {
      await api.clearSession();
    } catch (e) {
      // 存储异常（Keystore 故障）→ 如实告知"没退成功"，别让用户以为退了
      storageOk = false;
      debugPrint('[session] 退出登录：清本机凭据失败（${e.runtimeType}）');
    }

    // 2) WebView cookie jar 里那份
    //    这里直接调 [WebLoginCookies.clear] 而不用 [BiliApi.clearWebLoginCookies]：
    //    后者是给**错误处理路径**用的（内部吞掉异常只记日志——清理失败不该盖掉
    //    真正要报的错误码）；而退出登录是用户主动发起的动作，清没清干净必须
    //    能回报给用户，所以自己 try/catch。
    var cookieOk = true;
    try {
      await WebLoginCookies.clear();
    } catch (e) {
      cookieOk = false;
      debugPrint('[session] 退出登录：清 WebView cookie 失败（通道不可用？'
          '${e.runtimeType}）');
    }

    if (!mounted) return;
    setState(() => _loggingOut = false);
    debugPrint('[session] 退出登录完成：本机凭据已清=$storageOk，'
        'WebView cookie 已清=$cookieOk');
    // 账号区回到未登录 + 宿主刷新首页提示条（两者都不涉及具体凭据内容）
    await _loadAccount();
    if (!mounted) return;
    widget.onSessionChanged?.call();

    if (!storageOk) {
      // 失败类：走 error 档，关掉「界面提示」也不静默
      _showSnack('退出失败：本机凭据没能清除（安全存储异常），请重试',
          kind: SnackKind.error);
    } else if (!cookieOk) {
      // 本机那份已清（App 侧确实退出了），但 WebView 里可能还剩一份——
      // 登录页可能因此显示成"已登录"，必须让用户知道而不是含糊说"已退出"
      _showSnack('已退出登录，但网页数据没清干净：登录页可能仍显示旧登录状态，'
          '可在登录页用「清除网页数据后重试」',
          kind: SnackKind.error);
    } else {
      _showSnack('已退出登录（本机凭据与网页登录状态都已清除）');
    }
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

/// 「粘贴 Cookie 登录」弹窗（v2.49.1+）：不依赖 WebView 的兜底登录路径。
///
/// 为什么需要：真机登录页的 WebView 渲染进程每次必崩（见 CHANGELOG v2.49.1），
/// 只要 WebView 不可用，用户就完全没有别的入口——而 WebView 崩不崩取决于
/// 他的手机/网络环境（代理中间人证书等），App 侧修不了。于是留一条"人工搬
/// 凭据"的路：在电脑浏览器里登录 B 站后把整段 cookie 复制过来粘贴。
///
/// **必须先经服务端校验**（[BiliApi.verifySession]，与登录页同一套）：校验不
/// 通过**绝不落盘**——保存一份服务端不认的凭据，正是"每项功能都 -101 但 App
/// 说自己已登录"那种坏状态的来源。
///
/// 对话框内所有文案与错误提示都**不含任何凭据内容**（连长度都不显示）。
class _PasteCookieDialog extends StatefulWidget {
  final BiliApi api;

  const _PasteCookieDialog({required this.api});

  @override
  State<_PasteCookieDialog> createState() => _PasteCookieDialogState();
}

class _PasteCookieDialogState extends State<_PasteCookieDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  /// 需要用户看见的失败原因（null = 无；校验失败/保存失败都在这里显示，
  /// 弹窗**不关**，用户可以改一改再试）。
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // 容错解析（顺序任意、大小写、换行、多余键都认，见 parseBiliCookieCreds）
    final creds = parseBiliCookieCreds(_ctrl.text);
    if (!creds.hasSessdata) {
      setState(() => _error =
          '没找到 SESSDATA。请确认粘贴的是完整的 cookie 串（形如 '
          'SESSDATA=…; bili_jct=…），而不是只复制了其中一段。');
      return;
    }
    final sessdata = creds.sessdata!;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.api.verifySession(
      sessdata: sessdata,
      biliJct: creds.biliJct,
    );
    if (!mounted) return;
    if (!result.passed) {
      // 不通过 → 不落盘。文案按"能不能指望用户自己修"分档：
      // -101 = 凭据本身废了，只能重新弄一份；网络/风控 = 检查网络后重试。
      final String why;
      if (result.status == SessionVerifyStatus.invalid) {
        why = '这份 Cookie 服务端不认（-101：已失效 / 已在别处退出登录），'
            '没有保存。请重新获取一份再试。';
      } else if (result.status == SessionVerifyStatus.network) {
        why = '无法连接 B 站校验这份 Cookie（${result.message}），没有保存。'
            '请检查网络后重试。';
      } else {
        why = 'B 站返回 ${result.code}（${result.message}），没有保存。'
            '通常是被风控拦了，稍后再试一次。';
      }
      setState(() {
        _busy = false;
        _error = why;
      });
      return;
    }
    try {
      await widget.api.saveSession(
        sessdata: sessdata,
        biliJct: creds.biliJct ?? '',
        refreshToken: creds.refreshToken ?? '',
      );
    } catch (_) {
      setState(() {
        _busy = false;
        _error = '校验已通过，但保存到本机失败（安全存储异常），没有生效。请重试。';
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('粘贴 Cookie 登录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '在电脑浏览器里登录 B 站后，从开发者工具的 Cookie 列表里'
              '（域名 bilibili.com）把整段复制过来，粘贴到下面。\n'
              '这份字符串等同于你的登录凭据，只保存在本机、不会上传到任何地方，'
              '不要发给别人。粘贴后 App 会先向 B 站校验一次，'
              '只有确认有效的才会保存。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              enabled: !_busy,
              minLines: 3,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Cookie',
                hintText: 'SESSDATA=…; bili_jct=…; DedeUserID=…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '校验中…' : '校验并登录'),
        ),
      ],
    );
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
        // 失败类：error 档，关掉「界面提示」也不静默
        AppSnack.show(context, '翻译配置保存失败，请重试',
            kind: SnackKind.error);
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
              style: TextStyle(fontSize: 12, color: kInkGray70),
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

/// 配色主题选择弹层（P1.5）：列出全部双墨配方（首位 = 默认），
/// 每项「两个墨块 + 中文名 + 英文原名」，当前选中打勾；点击即生效并关闭。
///
/// 选项来自 `theme/ink_recipes.dart`（mono-color-skill 双色配方表）；
/// 点击调 [ThemeStore.select]（立即换墨 + 持久化），由 `main.dart` 的
/// ListenableBuilder 重建 MaterialApp。
class _InkRecipeSheet extends StatelessWidget {
  const _InkRecipeSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('配色主题', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '双墨配方：主墨 = 观看（品牌 / 导航 / 进度 / 热力），'
                  '点缀墨 = 时间与新鲜度（更新角标 / 未读点）。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 选中项打勾要跟着当前配色走 → 单独监听 ThemeStore
          Flexible(
            child: ListenableBuilder(
              listenable: ThemeStore.instance,
              builder: (context, _) {
                final currentId = ThemeStore.instance.recipe.id;
                return ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: kInkRecipes.length,
                  itemBuilder: (context, i) {
                    final recipe = kInkRecipes[i];
                    return _InkRecipeTile(
                      recipe: recipe,
                      selected: recipe.id == currentId,
                      onTap: () {
                        // 立即生效（全 App 换墨 + 持久化），再关掉弹层
                        ThemeStore.instance.select(recipe.id);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个配色选项：主墨 + 点缀墨两个墨块（左 ink 右 accent）、中文名、
/// 英文原名、当前选中打勾。
class _InkRecipeTile extends StatelessWidget {
  final InkRecipe recipe;
  final bool selected;
  final VoidCallback onTap;

  const _InkRecipeTile({
    required this.recipe,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _InkSwatch(color: recipe.ink),
          const SizedBox(width: 3),
          _InkSwatch(color: recipe.accent),
        ],
      ),
      title: Text(recipe.label, style: theme.textTheme.titleSmall),
      subtitle: Text(
        recipe.labelEn,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check, size: 20, color: context.palette.inkText)
          : null,
    );
  }
}

/// 单个墨块（圆角小方块）：加一圈淡描边，浅色墨也能看清边界与大小。
class _InkSwatch extends StatelessWidget {
  final Color color;

  const _InkSwatch({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(color: kRule.withValues(alpha: .6)),
      ),
    );
  }
}

// ==================== 信箱卡片样式（v2.21.0+） ====================
//
// 与「配色主题」同一种组织方式：选项来自 `widgets/inbox_card_styles.dart`
// 的 [kInboxCardStyles]（唯一真相源），点击调 [InboxCardStyleStore.select]
// （立即换版式 + 持久化），信箱页的 ListenableBuilder 随之重建卡片栈。
//
// 每个选项带一张**缩略预览**：直接用同一个渲染器 [InboxCardPreview]
// （内部 = [InboxCardStyleView] + FittedBox 等比缩小）→ 预览与真机一致，
// 不另画一套简图（那样迟早与真机排版脱节）。

/// 风格选项整块的 key（`inbox-card-style-option:<id>`）：测试里按 id 点选。
Key _cardStyleOptionKey(String id) => Key('inbox-card-style-option:$id');

/// 信箱卡片样式选择弹层：列出全部版式，当前选中打勾；点击即生效并关闭。
class _InboxCardStyleSheet extends StatelessWidget {
  const _InboxCardStyleSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('信箱卡片样式', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '都是扑克牌比例（宽 : 高 = 1 : 1.39），只有排版不同。'
                  '缩略图就是卡片本身等比缩小的效果。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 选中项打勾要跟着当前选择走 → 单独监听 InboxCardStyleStore
          Flexible(
            child: ListenableBuilder(
              listenable: InboxCardStyleStore.instance,
              builder: (context, _) {
                final currentId = InboxCardStyleStore.instance.styleId;
                return ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: kInboxCardStyles.length,
                  itemBuilder: (context, i) {
                    final style = kInboxCardStyles[i];
                    return _InboxCardStyleTile(
                      style: style,
                      selected: style.id == currentId,
                      onTap: () {
                        // 立即生效（信箱页换版式 + 持久化），再关掉弹层
                        InboxCardStyleStore.instance.select(style.id);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个卡片风格选项：缩略预览 + 中文名 + 一句话说明 + 当前选中打勾。
///
/// 不用 [ListTile]：它会把 leading 的高度限死在 56dp，缩略卡（≈100dp 高）
/// 会被压扁、看不出各版式的差别 → 自己排一行（行高 ≈100，触摸目标远超 48dp）。
class _InboxCardStyleTile extends StatelessWidget {
  const _InboxCardStyleTile({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final InboxCardStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: _cardStyleOptionKey(style.id),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            InboxCardPreview(style: style),
            const SizedBox(width: kSpace16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(style.label, style: theme.textTheme.titleSmall),
                  const SizedBox(height: kSpace4),
                  Text(
                    style.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: kSpace12),
            // 打勾位固定占位：选中与否文字都不跳
            SizedBox(
              width: 20,
              child: selected
                  ? Icon(Icons.check, size: 20, color: context.palette.inkText)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 界面文案编辑（v2.19.0 补） ====================
//
// 数据层（lib/services/ui_copy_store.dart）与读取接线（app_state_view /
// loading_copy）早已就位，但**设置页一直没有编辑入口**——这一节补上。
// 全部实现在 manage_panel.dart 内部（与 _TranslateConfigDialog /
// _CacheManageSheet 同一种组织方式）：面板自己读 UiCopyStore、自己弹层，
// 宿主（「个人」页 / 首页弹层）零改动。

/// 编辑入口按钮的 key（测试锚点）。
const String _kCopyEditorEntryKey = 'ui-copy-editor-entry';

/// 文案条目输入框 key（`ui-copy-field:<id>`）。
Key _copyFieldKey(String id) => Key('ui-copy-field:$id');

/// 单条「恢复默认」按钮 key（`ui-copy-reset:<id>`）。
Key _copyResetKey(String id) => Key('ui-copy-reset:$id');

/// 单条文案整块的 key（`ui-copy-item:<id>`）：测试里滚到某一条用
/// （弹层列表是懒构建的，滚到整块才能同时看到说明行、恢复默认按钮和输入框）。
Key _copyItemKey(String id) => Key('ui-copy-item:$id');

/// 弹层内滚动列表的 key（测试里定位那个 Scrollable 用）。
const Key _kCopyEditorListKey = Key('ui-copy-editor-list');

/// 已自定义条数（「已自定义 N 条」用）。
///
/// 只数**出厂表里认识的 id**：编辑器只认这些条目，未登记的野生覆盖既不会
/// 显示也不会计数（但「全部恢复默认」仍会一并清掉，见 [UiCopyStore.resetAll]）。
int copyOverrideCount() {
  var n = 0;
  for (final id in UiCopyStore.kDefaultCopies.keys) {
    if (UiCopyStore.instance.hasOverride(id)) n++;
  }
  return n;
}

/// 弹层关闭时回给宿主的信号（宿主据此提示）。
enum _CopyEditorResult {
  /// 用户点了「全部恢复默认」（覆盖已清空，宿主提示一句）。
  resetAll,
}

/// 文案编辑器的一个分组：一句话说明这个场景 + 命中它的 key 前缀。
///
/// 用**前缀**而不是逐个列 id：`empty.favorite` 一条就覆盖了收藏夹相关的
/// 四个 id，新增同类文案（如 `empty.favorite_xxx`）也会自动归组。
class _CopyGroup {
  /// 分组标题（如「空态 · 历史」）。
  final String label;

  /// 命中前缀（`startsWith` 判定，任一命中即归本组）。
  final List<String> prefixes;

  const _CopyGroup(this.label, this.prefixes);
}

/// 分组表：**顺序即展示顺序，每条 id 落进第一个命中的组**。
///
/// 前缀之间不能互相包含（如 `empty.history` 与 `empty.daily_history` 不冲突）；
/// 没被任何前缀命中的 id 会落进 [_kCopyGroupFallback]，**不会漏条目**。
const List<_CopyGroup> _kCopyGroups = <_CopyGroup>[
  _CopyGroup('空态 · 白名单 / 首页', ['empty.playlist', 'empty.syncing']),
  _CopyGroup('空态 · 合集', ['empty.collection']),
  _CopyGroup('空态 · 历史', ['empty.history', 'empty.daily_history']),
  _CopyGroup('空态 · 观看热力', ['empty.watch_heat']),
  _CopyGroup('空态 · 收藏夹', ['empty.favorite']),
  _CopyGroup('空态 · 搜索', ['empty.search']),
  _CopyGroup('空态 · 收件箱', ['empty.inbox']),
  _CopyGroup('空态 · 评论', ['empty.comment']),
  _CopyGroup('空态 · 缓存', ['empty.cache']),
  _CopyGroup('空态 · 关注导入', ['empty.followings']),
  _CopyGroup('空态 · UP 主主页', ['empty.upowner']),
  _CopyGroup('列表尾部 · 分页到底', ['footer.no_more', 'footer.hot_only']),
  _CopyGroup('列表尾部 · 加载中', ['footer.loading']),
  _CopyGroup('错误', ['error.']),
  _CopyGroup('整页加载 · 主文案', ['loading.generic']),
  _CopyGroup('整页加载 · 闲话', ['loading.line']),
  _CopyGroup('空态兜底 · 闲话', ['loading.empty']),
];

/// 兜底分组名：分组表没覆盖的 id 落这里（新增文案时不会在编辑器里消失）。
const String _kCopyGroupFallback = '其他';

/// 每条文案的「在哪儿显示」说明（编辑器里的标题行）。
///
/// 手写而不是从 id 硬拼：用户需要知道的是「历史页为空」，不是「empty.history」。
/// **表里没有的 id 回退显示 id 本身**（与 [UiCopyStore.text] 的「不认识就原样
/// 显形」一致，漏配不会静默成空白）。
const Map<String, String> _kCopyNotes = <String, String>{
  // 白名单 / 首页
  'empty.playlist': '首页白名单为空',
  'empty.playlist.sync_failed': '首页白名单同步失败（无数据时）',
  'empty.playlist.upowner': '白名单里还没有 UP 主',
  'empty.syncing': '正在同步白名单',
  // 合集
  'empty.collection': '合集页为空',
  'empty.collection.sub': '合集页为空的副文案',
  // 历史
  'empty.history': '历史页为空',
  'empty.history.sub': '历史页为空的副文案',
  'empty.daily_history': '某一天没有观看记录',
  // 观看热力
  'empty.watch_heat': '观看热力还没有数据',
  'empty.watch_heat.sub': '观看热力的副文案',
  // 收藏夹
  'empty.favorites': '收藏夹列表为空',
  'empty.favorite_videos': '收藏夹里没有视频',
  'empty.favorite_search': '收藏夹内搜索无结果',
  'empty.favorite_search.sub': '收藏夹搜索无结果的副文案',
  // 搜索
  'empty.search': '搜索页初始提示',
  'empty.search.result': '全网搜索无结果',
  'empty.search.whitelist': '搜索页白名单还没加载出来',
  'empty.search.whitelist.filter': '白名单内搜索无结果',
  'empty.search.whitelist.sync_failed': '搜索页白名单同步失败（无数据时）',
  // 收件箱
  'empty.inbox': '收件箱没有新视频',
  // 评论
  'empty.comment': '评论区为空',
  'empty.comment.sub': '评论区为空的副文案',
  // 缓存
  'empty.cache': '缓存列表为空',
  'empty.cache.sub': '缓存为空的副文案',
  'empty.cache.desc': '缓存页空态的长说明',
  // 关注导入
  'empty.followings': '关注列表为空',
  // UP 主主页
  'empty.upowner_videos': 'UP 主主页没有视频',
  'empty.upowner.season': '合集里没有视频',
  'empty.upowner.list': '列表里没有视频',
  // 列表尾部
  'footer.no_more': '列表滚到底的一句',
  'footer.hot_only': '未登录时评论区脚注',
  // 错误
  'error.generic': '网络错误兜底文案',
  // 加载
  'loading.generic': '整页加载的主文案',
  'loading.line.1': '整页加载闲话 1',
  'loading.line.2': '整页加载闲话 2',
  'loading.line.3': '整页加载闲话 3',
  'loading.line.4': '整页加载闲话 4',
  'loading.line.5': '整页加载闲话 5',
  'loading.line.6': '整页加载闲话 6',
  'loading.line.7': '整页加载闲话 7',
  'loading.line.8': '整页加载闲话 8',
  'footer.loading.1': '列表尾部加载闲话 1',
  'footer.loading.2': '列表尾部加载闲话 2',
  'footer.loading.3': '列表尾部加载闲话 3',
  'footer.loading.4': '列表尾部加载闲话 4',
  'loading.empty.1': '空态兜底闲话 1',
  'loading.empty.2': '空态兜底闲话 2',
  'loading.empty.3': '空态兜底闲话 3',
};

/// 一条文案的可读说明（没登记的 id 回退 id 本身）。
String _copyNote(String id) => _kCopyNotes[id] ?? id;

/// 按 [_kCopyGroups] 把出厂文案表分组：组内保持 `kDefaultCopies` 的声明顺序，
/// 空组不产出；没被任何前缀命中的 id 归入 [_kCopyGroupFallback]。
List<({String label, List<String> ids})> groupCopyIds() {
  final taken = <String>{};
  final out = <({String label, List<String> ids})>[];
  for (final group in _kCopyGroups) {
    final ids = <String>[
      for (final id in UiCopyStore.kDefaultCopies.keys)
        if (!taken.contains(id) && group.prefixes.any(id.startsWith)) id,
    ];
    if (ids.isEmpty) continue;
    taken.addAll(ids);
    out.add((label: group.label, ids: ids));
  }
  final rest = <String>[
    for (final id in UiCopyStore.kDefaultCopies.keys)
      if (!taken.contains(id)) id,
  ];
  if (rest.isNotEmpty) out.add((label: _kCopyGroupFallback, ids: rest));
  return out;
}

/// 界面文案编辑弹层：按场景分组列出**全部出厂文案**（约 49 条），
/// 逐条可改、可单条恢复默认；顶部可「全部恢复默认」（二次确认）。
///
/// ## 写入策略：输入框 `onChanged` 直接写，**改一个字符就全局生效**
/// [UiCopyStore.setOverride] 先改内存（`notifyListeners` → 页面与面板立刻
/// 刷新）再异步写盘，写盘失败在 store 内部静默，所以这里不防抖、不做
/// 「保存」按钮，也不怕连打（同一份 JSON 反复落盘，最终值一致）。
///
/// ## 空值 / 纯空白 = 用回默认（沿用 store 的既有语义，未改一字）
/// `setOverride` 对 trim 后为空的输入等价于 `clearOverride`，所以清空输入框
/// 就是「这条改回默认」，输入框下方会提示当前生效的默认文案是什么。
///
/// ## 控制器
/// 48 条各一个 [TextEditingController]，进弹层时一次性按当前生效文案预填并
/// 由本 State 持有到关闭（列表滚出视口再回来不会丢光标 / 丢未提交输入）。
/// 程序化改 `.text` 不触发 `onChanged`，所以「恢复默认」回填不会二次写盘。
class _CopyEditorSheet extends StatefulWidget {
  const _CopyEditorSheet();

  @override
  State<_CopyEditorSheet> createState() => _CopyEditorSheetState();
}

class _CopyEditorSheetState extends State<_CopyEditorSheet> {
  /// id → 输入框控制器（一次性建好，随弹层一起销毁）。
  late final Map<String, TextEditingController> _controllers = {
    for (final id in UiCopyStore.kDefaultCopies.keys)
      id: TextEditingController(text: UiCopyStore.instance.text(id)),
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 单条写回（空白由 store 解释成「清除覆盖」，这里不另做判断）。
  void _onChanged(String id, String value) {
    unawaited(UiCopyStore.instance.setOverride(id, value));
  }

  /// 单条恢复默认：清覆盖 → 输入框回填出厂默认（方便看到真实生效值）。
  Future<void> _resetOne(String id) async {
    await UiCopyStore.instance.clearOverride(id);
    if (!mounted) return;
    _controllers[id]?.text = UiCopyStore.instance.text(id);
  }

  /// 全部恢复默认（二次确认）→ 清空覆盖并关掉弹层，由宿主提示一句。
  Future<void> _resetAll(int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('全部恢复默认'),
        content: Text(
          '将清掉全部 $count 条自定义文案，界面回到出厂文案。这不会影响别的设置。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            // 与逐条的「恢复默认」区分开（那批按钮此时也在树里，避免歧义）
            child: const Text('全部恢复', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await UiCopyStore.instance.resetAll();
    if (!mounted) return;
    Navigator.of(context).pop(_CopyEditorResult.resetAll);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = groupCopyIds();
    return Padding(
      // 键盘弹出时把内容顶上去，正在编辑的输入框不被遮挡
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('界面文案', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '空态 / 加载 / 错误 / 页脚的那几句话，都能改成你自己的。'
                    '改完立刻生效（所有页面同步），只存本机；'
                    '输入框留空 = 这条用回出厂默认。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  // 覆盖条数 / 全部恢复默认都要跟着 store 走
                  ListenableBuilder(
                    listenable: UiCopyStore.instance,
                    builder: (context, _) {
                      final count = copyOverrideCount();
                      return TextButton.icon(
                        onPressed: count == 0 ? null : () => _resetAll(count),
                        style: TextButton.styleFrom(
                          // 触摸目标 ≥ 48dp
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: kSpace8,
                          ),
                          foregroundColor: context.palette.inkText,
                        ),
                        icon: const Icon(Icons.settings_backup_restore,
                            size: 18),
                        label: Text(
                          count == 0
                              ? '全部恢复默认（当前无自定义）'
                              : '全部恢复默认（$count 条）',
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 48 条 + 分组标题：列表自己滚，弹层高度上限 85% 屏高
            Flexible(
              child: ListenableBuilder(
                listenable: UiCopyStore.instance,
                builder: (context, _) => ListView(
                  key: _kCopyEditorListKey,
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final section in sections) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Text(
                          section.label,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: context.palette.inkText),
                        ),
                      ),
                      for (final id in section.ids)
                        _CopyItemTile(
                          key: _copyItemKey(id),
                          id: id,
                          controller: _controllers[id]!,
                          onChanged: _onChanged,
                          onReset: _resetOne,
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑器里的单条文案：说明 + id + 多行输入框（+ 被覆盖过时的「恢复默认」）。
class _CopyItemTile extends StatelessWidget {
  final String id;
  final TextEditingController controller;
  final void Function(String id, String value) onChanged;
  final void Function(String id) onReset;

  const _CopyItemTile({
    super.key,
    required this.id,
    required this.controller,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overridden = UiCopyStore.instance.hasOverride(id);
    final fallback = UiCopyStore.kDefaultCopies[id] ?? '';
    // 空输入框时提示当前生效的默认文案（多行默认压成一行，免得 helper 换行散架）
    final fallbackOneLine = fallback.replaceAll('\n', ' ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _copyNote(id),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (overridden)
                TextButton(
                  key: _copyResetKey(id),
                  onPressed: () => onReset(id),
                  style: TextButton.styleFrom(
                    // 触摸目标 ≥ 48dp
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(horizontal: kSpace8),
                    foregroundColor: context.palette.inkText,
                  ),
                  child: const Text('恢复默认'),
                ),
            ],
          ),
          Text(
            id,
            style: theme.textTheme.bodySmall?.copyWith(color: kInkGray50),
          ),
          const SizedBox(height: kSpace4),
          TextField(
            key: _copyFieldKey(id),
            controller: controller,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              helperMaxLines: 2,
              helperText: controller.text.trim().isEmpty
                  ? '留空 = 用回默认：$fallbackOneLine'
                  : null,
            ),
            onChanged: (value) => onChanged(id, value),
          ),
        ],
      ),
    );
  }
}
