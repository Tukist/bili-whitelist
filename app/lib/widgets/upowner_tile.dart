/// 搜索 UP 主结果列表项：头像（圆角 24x24）+ 名字 + 认证描述 + 粉丝数 +
/// 「加入白名单」/「已加入」按钮。
///
/// 复用搜索页的视觉风格：参考 [VideoTile] 的 ListTile 结构，按钮文案 + 状态
/// 与搜索页视频结果一致（未加入 = FilledButton「加入」；已加入 =
/// FilledButton.tonal「已加入」灰态）。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/upowner.dart';

/// 搜索 UP 主结果列表项。
///
/// - [onJoin] 点「加入白名单」按钮时回调（页面层负责调用 [UpownerWriter.add]）
/// - [joining] 该 UP 主正在「加入」中（防连点；按钮置 Loading 圈）
/// - [added] 该 UP 主已在白名单（按钮显示「已加入」灰态、不可点）
class UpownerTile extends StatelessWidget {
  final Upowner upowner;
  final bool added;
  final bool joining;
  final VoidCallback? onTap; // 点整行（跳详情页用）
  final VoidCallback? onJoin;

  const UpownerTile({
    super.key,
    required this.upowner,
    this.added = false,
    this.joining = false,
    this.onTap,
    this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: _Avatar(face: upowner.face, fallback: upowner.name),
      title: Text(
        upowner.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        _fmtFans(upowner.fans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: added
          ? const FilledButton.tonal(
              onPressed: null,
              child: Text('已加入'),
            )
          : FilledButton(
              onPressed: joining ? null : onJoin,
              child: joining
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加入'),
            ),
    );
  }
}

/// 粉丝数格式化：`12345` → `1.2万`；`123456789` → `1.2亿`（尾数整则不带小数）。
String _fmtFans(int? fans) {
  if (fans == null) return '— 粉丝';
  if (fans >= 100000000) {
    final v = fans / 100000000;
    return '${_trimDot(v)}亿 粉丝';
  }
  if (fans >= 10000) {
    final v = fans / 10000;
    return '${_trimDot(v)}万 粉丝';
  }
  return '$fans 粉丝';
}

/// 去掉 `12.0` 尾部的 `.0`。
String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 头像（圆角 24x24，带 B 站防盗链头 + 加载/失败占位）。
class _Avatar extends StatelessWidget {
  final String face;
  final String fallback; // 用于 placeholder 显示名字首字

  const _Avatar({required this.face, required this.fallback});

  @override
  Widget build(BuildContext context) {
    if (face.isEmpty) return _placeholder(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Image.network(
        face,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        headers: {
          'User-Agent': kBrowserUA,
          'Referer': kBiliReferer,
        },
        errorBuilder: (_, __, ___) => _placeholder(context),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: 48,
            height: 48,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          );
        },
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    final theme = Theme.of(context);
    final initial = fallback.isNotEmpty ? fallback.characters.first : '?';
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