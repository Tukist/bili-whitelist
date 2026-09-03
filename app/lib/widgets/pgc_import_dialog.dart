/// 番剧/电影「整季导入」的共用 UI 编排（v2.16.5+）。
///
/// 首页「粘贴 ep/ss 链接导入」（playlist_page）与搜索页「media 搜索结果导入」
/// （search_page）共用同一份：配置门禁 → 进度对话框 → [WhitelistWriter] 逐集
/// 写入 → 结果反馈（新增/跳过/会员提示/中断原因）。纯逻辑在
/// [WhitelistWriter.importPgcSeason]，本文件只负责对话框与提示等 UI。
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../services/whitelist_writer.dart';

/// 番剧/电影整季导入进度对话框：逐集提示「导入中 i/N」，不可点穿/返回，
/// 由 [runPgcSeasonImport] 在导入结束（成功/中断）后统一关闭。
class PgcImportDialog extends StatelessWidget {
  final ValueListenable<String> status;

  const PgcImportDialog({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('整季导入'),
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

/// 执行一次整季导入（展示进度对话框 + 结果反馈），供首页导入链接与搜索页
/// media 结果导入共用。
///
/// - [epId]/[seasonId] 二选一（语义同 [BiliApi.fetchPgcSeason]）
/// - [configHint]：未配置 GitHub token/gist_id 时的引导文案（两页各说各的入口）
/// - [onDone]：导入结束（含中断）且提示已展示后回调，页面在此刷新自身白名单
///   数据（首页重新同步列表 / 搜索页刷新「已导入」判断依据）
///
/// 反馈文案与首页 v2.16.2 原实现保持一致：新增/跳过（已在白名单）/
/// 全季含大会员/付费集的提示/中断原因。
Future<void> runPgcSeasonImport({
  required BuildContext context,
  required WhitelistWriter writer,
  required String configHint,
  int? epId,
  int? seasonId,
  Future<void> Function(PgcImportSummary summary)? onDone,
}) async {
  // 1) 配置门禁（避免拉完整季才发现没配置 token/gist_id）
  if (!await writer.hasConfig()) {
    if (!context.mounted) return;
    _snack(context, configHint);
    return;
  }
  if (!context.mounted) return;

  // 2) 进度对话框（导入期间不可点穿/返回）
  final status = ValueNotifier<String>('正在获取番剧信息…');
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PgcImportDialog(status: status),
  );

  // 3) 逐集写入（纯逻辑在 WhitelistWriter；网络/保存失败不抛，汇总到 summary）
  final PgcImportSummary summary;
  try {
    summary = await writer.importPgcSeason(
      epId: epId,
      seasonId: seasonId,
      onProgress: (s) => status.value = s,
    );
  } on BiliApiException catch (e) {
    if (context.mounted) {
      navigator.pop();
      _snack(context, '获取番剧信息失败：${e.message}');
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

  // 4) 结果反馈
  final season = summary.season;
  if (summary.interrupted) {
    _snack(context,
        '导入中断：已导入 ${summary.added} 集（${summary.interruptReason}）');
    await onDone?.call(summary);
    return;
  }
  final buf = StringBuffer('已导入 ${summary.added} 集番剧');
  if (summary.skipped > 0) buf.write('，跳过 ${summary.skipped} 集（已在白名单）');
  if (season.hasVipOrPay) {
    buf.write('；全季含 ${season.vipCount} 集大会员/付费内容，'
        '会员集播放时需大会员（免费集可直接播放）');
  }
  _snack(context, buf.toString());
  await onDone?.call(summary);
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
