/// B 站收藏夹批量导入的共用 UI 编排（v2.17.5+）。
///
/// 首页导入入口 → [runFavoritesImportFlow]（配置门禁 → 登录门禁 → 拉收藏夹
/// 列表弹层 → 选夹确认 → 进度对话框 → [WhitelistWriter.importFavoriteFolder]
/// 逐视频写入 → 结果汇总反馈）。纯逻辑在 WhitelistWriter，本文件只负责
/// 对话框/弹层与提示等 UI。
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../services/whitelist_writer.dart';
import 'cover_image.dart';

/// 收藏夹导入进度对话框：逐视频提示「导入中 i/N」，不可点穿/返回，
/// 由 [runFavoritesImportFlow] 在导入结束（成功/中断）后统一关闭。
class FavoritesImportDialog extends StatelessWidget {
  final ValueListenable<String> status;

  const FavoritesImportDialog({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('收藏夹导入'),
        content: SizedBox(
          width: 280,
          child: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, value, __) => Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 执行一次收藏夹导入全流程（首页「从 B 站收藏夹导入」入口用）。
///
/// 步骤：配置门禁 → 登录门禁（未登录提示 + 引导登录）→ 拉收藏夹列表弹层 →
/// 选夹确认 → 进度对话框逐视频导入 → 结果汇总 snack。
///
/// - [configHint]：未配置 GitHub token/gist_id 时的引导文案
/// - [openLogin]：登录门禁回调——返回「登录完成后是否已登录」（页面实现：
///   推 [LoginPage] 并重查 SESSDATA；测试可注入替身）
/// - [onDone]：导入结束（含中断/空夹）且提示已展示后回调，页面在此刷新
///   自身白名单数据
///
/// 反馈文案：`已导入 X，跳过 Y（已在白名单），失败 Z`；中断 → 前缀
/// 「导入中断：已导入 X 个（原因）」。
Future<void> runFavoritesImportFlow({
  required BuildContext context,
  required WhitelistWriter writer,
  required String configHint,
  required Future<bool> Function() openLogin,
  Future<void> Function(FavoriteImportSummary summary)? onDone,
}) async {
  // 1) 配置门禁（避免拉完收藏夹才发现没配置 token/gist_id）
  if (!await writer.hasConfig()) {
    if (!context.mounted) return;
    _snack(context, configHint);
    return;
  }
  if (!context.mounted) return;

  // 2) 登录门禁：无 SESSDATA → 提示 + 引导登录（登录成功继续；保持匿名中止）
  final sessdata = await writer.api.readSessdata();
  if (sessdata == null || sessdata.isEmpty) {
    if (!context.mounted) return;
    _snack(context, '收藏夹导入需要登录 B 站账号（收藏夹属于个人账号数据）');
    final loggedIn = await openLogin();
    if (!loggedIn || !context.mounted) return; // 仍匿名 → 中止
  }
  if (!context.mounted) return;

  // 3) 拉收藏夹列表弹层（内部 loading/失败重试/空态），返回选中的收藏夹
  final folder = await showModalBottomSheet<FavoriteFolder>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _FolderPickerSheet(writer: writer),
  );
  if (folder == null || !context.mounted) return;

  // 4) 确认导入数量
  final confirmTitle = folder.title.isEmpty ? '未命名收藏夹' : folder.title;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('导入收藏夹'),
      content: Text(
        '把「$confirmTitle」中的 ${folder.mediaCount} 个视频导入白名单？\n\n'
        '已在白名单的视频自动跳过；失效（已删除/不可播放）视频自动跳过不导入。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('开始导入'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  // 5) 进度对话框 + 逐视频导入
  final status = ValueNotifier<String>('准备导入…');
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => FavoritesImportDialog(status: status),
  );

  final FavoriteImportSummary summary;
  try {
    summary = await writer.importFavoriteFolder(
      mediaId: folder.mediaId,
      folderTitle: confirmTitle,
      onProgress: (s) => status.value = s,
    );
  } on BiliApiException catch (e) {
    if (context.mounted) {
      navigator.pop();
      _snack(context, '获取收藏夹失败：${e.message}');
    }
    return;
  } on DioException {
    if (context.mounted) {
      navigator.pop();
      _snack(context, '网络请求失败，请检查网络后重试');
    }
    return;
  }
  if (!context.mounted) return;
  navigator.pop();

  // 6) 结果汇总反馈
  if (summary.interrupted) {
    _snack(
      context,
      '导入中断：已导入 ${summary.added} 个（${summary.interruptReason}）',
    );
    await onDone?.call(summary);
    return;
  }
  if (summary.total == 0) {
    _snack(context, '「$confirmTitle」没有可导入的视频');
    await onDone?.call(summary);
    return;
  }
  final buf = StringBuffer('已导入 ${summary.added}');
  if (summary.skipped > 0) buf.write('，跳过 ${summary.skipped}（已在白名单）');
  if (summary.failed > 0) buf.write('，失败 ${summary.failed}（失效/获取失败）');
  _snack(context, buf.toString());
  await onDone?.call(summary);
}

/// 收藏夹列表弹层：加载（loading）→ 展示（封面/名称/数量）→ 选中返回。
class _FolderPickerSheet extends StatefulWidget {
  final WhitelistWriter writer;

  const _FolderPickerSheet({required this.writer});

  @override
  State<_FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<_FolderPickerSheet> {
  /// null = 加载中；非空列表 = 成功；异常时记录便于展示重试。
  List<FavoriteFolder>? _folders;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 首次加载状态即默认（null）；仅重试时先复位为加载中
    if (_folders != null || _error != null) {
      setState(() {
        _folders = null;
        _error = null;
      });
    }
    try {
      final folders = await widget.writer.api.fetchMyFavorites();
      if (mounted) setState(() => _folders = folders);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.72;
    final Widget body;
    if (_error != null) {
      final message = switch (_error) {
        BiliApiException(:final code, :final message)
            when code == -101 => message,
        BiliApiException() => '获取收藏夹失败：${(_error as BiliApiException).message}',
        DioException() => '网络请求失败，请检查网络后重试',
        _ => '获取收藏夹失败，请重试',
      };
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          Icon(Icons.error_outline, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
          const SizedBox(height: 24),
        ],
      );
    } else if (_folders == null) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    } else if (_folders!.isEmpty) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          Icon(Icons.bookmark_border,
              size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '没有收藏夹。先到 B 站把想看的视频收藏一下，再来一键导入。',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
        ],
      );
    } else {
      body = Flexible(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _folders!.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final f = _folders![i];
            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CoverImage(
                  cover: f.cover,
                  width: 64,
                  height: 40,
                ),
              ),
              title: Text(
                f.title.isEmpty ? '未命名收藏夹' : f.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${f.mediaCount} 个视频',
                style: theme.textTheme.bodySmall,
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.of(context).pop(f),
            );
          },
        ),
      );
    }

    return SizedBox(
      height: maxHeight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '选择要导入的收藏夹',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Flexible(child: body),
          const SafeArea(top: false, child: SizedBox(height: 8)),
        ],
      ),
    );
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
