import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../api/translate_api.dart';
import '../cache/download_manager.dart';

/// 管理面板内容组件（v2.17.10+ 抽取自首页 _ManageSheet，供两处共用）：
///
/// - **首页齿轮弹层**（playlist_page `_openManage`）：BottomSheet 包一层
///   [ManagePanel]，`closeBeforeNavigate: true`（点「登录 / 检查更新」先
///   关面板再让页面动作，干净上下文，行为与旧 _ManageSheet 完全一致）
/// - **观看统计页底部内联设置区**（watch_stats_page 最下方，分区标题
///   「设置」）：直接嵌入页面滚动流，`closeBeforeNavigate: false`
///   （面板不是路由，不能 pop）
///
/// 内容分区：B 站账号（登录/重新登录）→ GitHub 配置（token/gist）→
/// 新建合集 → 合集管理（重命名/删除）→ 离线缓存管理 → 翻译服务 →
/// 版本更新（检查更新）。面板只含内容本身（无自己的滚动/内边距），
/// 外层（弹层 or 页面滚动流）负责滚动与留白。
///
/// 各项操作以回调交给宿主页面（写 Gist、管理合集、检查更新、登录页
/// 导航都依赖宿主状态），面板内部只持有配置表单与账号状态。
class ManagePanel extends StatefulWidget {
  final GithubApi github;

  /// 新建合集：把输入框名字交给宿主写入（宿主提示成败）。
  final Future<void> Function(String name) onCollectionCreated;

  /// 打开合集管理面板（重命名 / 删除；宿主维护合集数据）。
  final VoidCallback onManageCollections;

  /// 检查更新入口（宿主弹更新对话框）。
  final VoidCallback onCheckUpdate;

  /// B 站账号：宿主推登录页（登录 / 重新登录共用）。
  final VoidCallback onLogin;

  /// 宿主是否为弹层：true = 点「登录 / 检查更新」先 pop 自己再执行回调
  /// （弹层需要让 SnackBar/Dialog 显示在干净上下文）；false = 内联嵌入
  /// 页面（不是路由，不 pop）。
  final bool closeBeforeNavigate;

  /// 面板标题（弹层用「管理」；统计页内联用「设置」）。
  final String headingTitle;

  /// 标题下的说明文案。
  final String headingSubtitle;

  const ManagePanel({
    super.key,
    required this.github,
    required this.onCollectionCreated,
    required this.onManageCollections,
    required this.onCheckUpdate,
    required this.onLogin,
    this.closeBeforeNavigate = false,
    this.headingTitle = '管理',
    this.headingSubtitle =
        '管理功能只允许：新建 / 重命名 / 删除合集，移动 / 删除视频。'
        '新增白名单走右上角「导入」或「搜索」入口（加入前会查重）。',
  });

  @override
  State<ManagePanel> createState() => _ManagePanelState();
}

/// B 站账号登录态（管理面板顶部状态展示）。
enum _AccountState { loading, loggedIn, expired, none }

class _ManagePanelState extends State<ManagePanel> {
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
