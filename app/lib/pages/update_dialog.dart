/// 应用内版本更新弹窗（M1.4）。
///
/// - 三态：Ready / Downloading / Failed
/// - 强制更新模式（[UpdateInfo.isMandatory]）：[PopScope] 屏蔽返回；只显示「立即更新」按钮
/// - changelog 渲染：解析 markdown 简单行（标题 + 列表），固定 240px 高度内
///   不够时外层 ListView 滚动
/// - 下载中：底部 LinearProgressIndicator + 百分比 + 「取消下载」（取消/失败都
///   保留 .part 进度，下次点「立即更新/重试」从断点自动续传）
/// - 下载完成：自动 dismiss + [ApkInstallerChannel.install] 触发系统安装
///
/// 归因分离（v2.46.0）：**下载**与**安装**是两件事、两套文案、两个重试动作。
/// 历史 bug：两者塞在同一个 try 里，安装阶段被系统拦下（原生报
/// `INSTALL_FAILED`）也显示成「下载失败：…未知错误」，用户根本没法判断问题出
/// 在网络还是出在手机上。现在 [_FailStage] 分开记录阶段：安装失败的文案是
/// 「安装失败：<原生原因>」，并单独给「重试安装」（只重发 Intent）与
/// 「重新下载」两个动作。
///
/// - **复用已下好的 APK**（v2.46.0）：下载前先问 [UpdateService.existingApk]，
///   合格就直接装 —— 不为一个已经躺在磁盘上的 68MB 文件再下一次；只有用户主动
///   点「重新下载」才绕过复用（[_ignoreExistingApk] 生效到下次下载成功为止）。
/// - **「安装未知应用」权限前置检查**（v2.46.0）：Android 8+ 系统里该开关关着时
///   原生 `startActivity` 必然被拦，先问 [ApkInstallerChannel.canInstallUnknownApps]，
///   未开启就不调用安装，直接给引导文案 + 「去开启」（跳
///   `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`）。
/// - 日志（v2.46.0）：全程 `[update]` 前缀 debugPrint（阶段 / 归因 / 异常类型 +
///   原始 message）；URL 与 token 走 [UpdateService.sanitizeLogText] 脱敏。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/update_info.dart';
import '../services/apk_installer.dart';
import '../services/update_service.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  final UpdateService service;
  final ApkInstallerChannel installer;

  const UpdateDialog({
    super.key,
    required this.info,
    required this.service,
    required this.installer,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

enum _Status { ready, downloading, failed }

/// 失败发生在哪一步：**下载** 还是 **安装**。
///
/// 决定三件事：错误文案（安装阶段的失败必须说「安装失败」，不能笼统甩「下载失败」）、
/// 主按钮语义（重试下载 / 只重发安装 Intent）、以及要不要显示「重新下载」
/// （只有安装阶段才有意义 —— 文件本来就已经下好了）。
enum _FailStage { download, install }

class _UpdateDialogState extends State<UpdateDialog> {
  _Status _status = _Status.ready;
  _FailStage _failStage = _FailStage.download;
  double _progress = 0.0;
  String? _error;
  CancelToken? _cancelToken;

  /// 「安装未知应用」权限未开启（或安装被系统以此为由拒绝）→ 显示引导 + 「去开启」。
  bool _needUnknownSources = false;

  /// 用户主动点了「重新下载」：忽略已下好的 APK。一直生效到某次下载成功为止，
  /// 免得「重下失败 → 点重试 → 又复用回上一份（可能有问题的）旧文件」。
  bool _ignoreExistingApk = false;

  /// 「安装未知应用」未开启时的引导文案。
  static const String _unknownSourcesHint =
      '安装被系统拦截：需要先允许 amoTV「安装未知应用」'
      '（设置 → 应用 → 特殊应用权限 → 安装未知应用）。'
      '开启后回到本页点「重试安装」即可，已经下好的安装包不用重下';

  /// 当前 App 版本号（异步加载）。失败时用 '旧版' 占位。
  String _currentVersion = '当前版本';

  bool get _mandatory => widget.info.isMandatory(0); // 首版：code 未知，用 0 兜底判定

  @override
  void initState() {
    super.initState();
    _loadCurrentVersion();
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _currentVersion = 'v${pkg.version}');
    } catch (_) {
      // 测试环境 / 原生通道异常：保持占位
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel('dialog disposed');
    super.dispose();
  }

  /// 开始（或重试）更新：复用已下好的 APK → 下载 → 安装。
  ///
  /// [redownload]=true 是用户主动「重新下载」（安装失败文案旁那个按钮）：
  /// 跳过复用、强制整包重下。
  Future<void> _startDownload({bool redownload = false}) async {
    setState(() {
      _status = _Status.downloading;
      _failStage = _FailStage.download;
      _progress = 0;
      _error = null;
      _needUnknownSources = false;
      if (redownload) _ignoreExistingApk = true;
    });
    _cancelToken = CancelToken();
    String path;
    try {
      path = await _obtainApk();
    } on UpdateException catch (e) {
      // 下载阶段失败：文案用 service 给的友好中文（阶段归因明确是「下载」）
      debugPrint('[update] 下载阶段失败（业务）：${e.message}');
      if (!mounted) return;
      setState(() {
        _status = _Status.failed;
        _failStage = _FailStage.download;
        _error = e.message;
      });
      return;
    } catch (e) {
      debugPrint('[update] 下载阶段失败（意外异常）${e.runtimeType}：'
          '${UpdateService.sanitizeLogText(e)}');
      if (!mounted) return;
      setState(() {
        _status = _Status.failed;
        _failStage = _FailStage.download;
        _error = '下载失败：$e';
      });
      return;
    } finally {
      _cancelToken = null;
    }
    await _installApk(path);
  }

  /// 取 APK 路径：已有合格文件且非「重新下载」→ 直接复用（完全不触网）。
  Future<String> _obtainApk() async {
    if (!_ignoreExistingApk) {
      final ready = await widget.service.existingApk(widget.info);
      if (ready != null) return ready;
    }
    final path = await widget.service.download(
      widget.info,
      onProgress: (p) {
        if (!mounted) return;
        setState(() => _progress = p);
      },
      cancelToken: _cancelToken,
    );
    _ignoreExistingApk = false; // 这份是新下的完整文件，之后的失败重试可以复用
    return path;
  }

  /// 触发系统安装（含「安装未知应用」权限前置检查 + 安装阶段失败归因）。
  Future<void> _installApk(String path) async {
    if (!await _ensureUnknownSourcesAllowed()) return;
    try {
      debugPrint('[update] 触发系统安装：${_fileLabel(path)}');
      await widget.installer.install(path);
      if (!mounted) return;
      debugPrint('[update] 安装 Intent 已交给系统安装器');
      Navigator.of(context).pop();
    } catch (e) {
      // 原生 ApkInstaller.kt 给的原因（INSTALL_FAILED / NOT_FOUND 的 message）
      // 如实透出：用户要能分辨「网络下载有问题」还是「安装这一步有问题」。
      final detail = _installErrorDetail(e);
      final blocked = e is PlatformException && e.code == kNeedUnknownSourcesCode;
      debugPrint('[update] 安装阶段失败 ${e.runtimeType} '
          'code=${e is PlatformException ? e.code : '—'}：$detail');
      if (!mounted) return;
      setState(() {
        _status = _Status.failed;
        _failStage = _FailStage.install;
        _needUnknownSources = blocked;
        _error = blocked ? '$_unknownSourcesHint（系统安装器拒绝了本次安装）'
                         : '安装失败：$detail';
      });
    }
  }

  /// 「安装未知应用」权限前置检查（Android 8+ `canRequestPackageInstalls`）。
  ///
  /// 未开启时**不调用安装**（原生 `startActivity` 必然被系统拦，报出来的错也
  /// 说不清原因），直接把「要去开哪个开关 + 一键跳过去」摆给用户。
  /// 查询本身失败（原生没实现该方法 / 测试环境无通道）按「允许」处理 —— 把用户
  /// 堵在门外比让系统安装器自己拦更糟。
  Future<bool> _ensureUnknownSourcesAllowed() async {
    bool allowed;
    try {
      allowed = await widget.installer.canInstallUnknownApps();
    } catch (e) {
      debugPrint('[update] 查询「安装未知应用」权限失败（按允许处理）：'
          '${UpdateService.sanitizeLogText(e)}');
      allowed = true;
    }
    if (allowed) return true;
    debugPrint('[update] 「安装未知应用」权限未开启 → 不调用安装，改为引导去系统设置');
    if (!mounted) return false;
    setState(() {
      _status = _Status.failed;
      _failStage = _FailStage.install;
      _needUnknownSources = true;
      _error = _unknownSourcesHint;
    });
    return false;
  }

  /// 跳系统「安装未知应用」设置页（带本应用包名直达）。
  Future<void> _openUnknownSourcesSettings() async {
    debugPrint('[update] 跳转「安装未知应用」系统设置页');
    try {
      await widget.installer.openUnknownSourcesSettings();
    } catch (e) {
      debugPrint('[update] 跳设置页失败：${UpdateService.sanitizeLogText(e)}');
      if (!mounted) return;
      setState(() {
        _error = '打开系统设置失败，请手动到「设置 → 应用 → amoTV → '
            '安装未知应用」里允许后再点「重试安装」';
      });
    }
  }

  /// 失败态主按钮：安装阶段且手上还有合格 APK → 只重发安装 Intent（不重下）；
  /// 其余情况走重新下载。
  Future<void> _retry() async {
    if (_failStage == _FailStage.install) {
      // 复用判定再核对一次（文件可能已被系统清理工具删掉）→ 还在就直接装。
      final ready = await widget.service.existingApk(widget.info);
      if (ready != null) {
        debugPrint('[update] 重试安装：复用已下好的安装包，不重新下载');
        await _installApk(ready);
        return;
      }
      debugPrint('[update] 已下好的安装包不在了（或没通过校验），改为重新下载');
    }
    await _startDownload();
  }

  /// 安装异常 → 用户可读原因。PlatformException 透出原生 message
  /// （ApkInstaller.kt 的 INSTALL_FAILED / NOT_FOUND 文案），其余给类型兜底。
  String _installErrorDetail(Object e) {
    if (e is MissingPluginException) return '当前系统未注册安装通道';
    if (e is PlatformException) {
      final msg = (e.message ?? '').trim();
      if (msg.isNotEmpty) return msg;
      return e.code.isEmpty ? '系统安装器未能启动' : '系统安装器未能启动（${e.code}）';
    }
    return '${e.runtimeType}: $e';
  }

  /// 日志用文件标识：只取文件名（绝对路径冗长且不含信息量）。
  String _fileLabel(String path) => path.split(RegExp(r'[/\\]')).last;

  void _cancelDownload() {
    _cancelToken?.cancel('user canceled');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.info;
    return PopScope(
      canPop: !_mandatory && _status != _Status.downloading,
      child: AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本 $_currentVersion（更新后大小约 ${_fmtSize(info.size)}）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (info.changelog.trim().isNotEmpty) ...[
                Text('更新内容', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 240),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: _ChangelogView(markdown: info.changelog),
                ),
              ],
              if (_status == _Status.downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                const SizedBox(height: 6),
                Text(
                  '下载中… ${(_progress * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (_status == _Status.failed) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error ?? '更新失败',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: _buildActions(theme),
      ),
    );
  }

  List<Widget> _buildActions(ThemeData theme) {
    switch (_status) {
      case _Status.ready:
        if (_mandatory) {
          return [
            FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.system_update_alt, size: 18),
              label: const Text('立即更新'),
            ),
          ];
        }
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('立即更新'),
          ),
        ];
      case _Status.downloading:
        return [
          TextButton(
            onPressed: _cancelDownload,
            child: const Text('取消下载'),
          ),
        ];
      case _Status.failed:
        final installStage = _failStage == _FailStage.install;
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          // 安装阶段失败 → 安装包已经下好了，默认行为就是不重下；真想重下走这个
          // 明确入口（权限没开时不给，那时候该做的是去开开关）。
          if (installStage && !_needUnknownSources)
            TextButton(
              onPressed: () => _startDownload(redownload: true),
              child: const Text('重新下载'),
            ),
          if (_needUnknownSources)
            FilledButton.icon(
              onPressed: _openUnknownSourcesSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('去开启'),
            ),
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(installStage ? '重试安装' : '重试'),
          ),
        ];
    }
  }

  String _fmtSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${units[i]}';
  }
}

/// 极简 changelog 渲染：识别 `# / ## / - list` 行。
///
/// 完整 markdown 解析（flutter_markdown）依赖较大，这里手写够用：
/// - 空行分段
/// - `#` 标题加粗
/// - `- ` 列表项前加 • 符号
/// - 其他按原文
class _ChangelogView extends StatelessWidget {
  final String markdown;
  const _ChangelogView({required this.markdown});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = markdown.split('\n');
    final widgets = <Widget>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }
      if (line.startsWith('# ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            line.substring(2),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ));
      } else if (line.startsWith('## ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(
            line.substring(3),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ));
      } else if (line.startsWith('- ')) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('•  '),
              Expanded(child: Text(line.substring(2), style: theme.textTheme.bodySmall)),
            ],
          ),
        ));
      } else {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(line, style: theme.textTheme.bodySmall),
        ));
      }
    }
    return ListView(
      shrinkWrap: true,
      children: widgets,
    );
  }
}
