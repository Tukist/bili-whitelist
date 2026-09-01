/// 应用内版本更新弹窗（M1.4）。
///
/// - 三态：Ready / Downloading / Failed
/// - 强制更新模式（[UpdateInfo.isMandatory]）：[PopScope] 屏蔽返回；只显示「立即更新」按钮
/// - changelog 渲染：解析 markdown 简单行（标题 + 列表），固定 240px 高度内
///   不够时外层 ListView 滚动
/// - 下载中：底部 LinearProgressIndicator + 百分比 + 「取消下载」（删半成品）
/// - 下载完成：自动 dismiss + [ApkInstallerChannel.install] 触发系统安装
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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

class _UpdateDialogState extends State<UpdateDialog> {
  _Status _status = _Status.ready;
  double _progress = 0.0;
  String? _error;
  CancelToken? _cancelToken;

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

  Future<void> _startDownload() async {
    setState(() {
      _status = _Status.downloading;
      _progress = 0;
      _error = null;
    });
    _cancelToken = CancelToken();
    try {
      final path = await widget.service.download(
        widget.info,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
        cancelToken: _cancelToken,
      );
      if (!mounted) return;
      // 下载完成 → 自动触发系统安装
      await widget.installer.install(path);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.failed;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _Status.failed;
        _error = '下载失败：$e';
      });
    } finally {
      _cancelToken = null;
    }
  }

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
                    _error ?? '下载失败',
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
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
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
