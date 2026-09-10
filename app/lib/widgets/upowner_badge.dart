/// 播放页竖屏信息行的 UP 主入口（阶段 C，仿 B 站）：圆形头像 + 名字，
/// 整块可点 → 进 UP 主主页（[UpownerPage]）。
///
/// - [face] 为空 / 加载失败 → 圆形占位（名字首字，B 站默认头像观感）
/// - [onTap] 为 null → 纯展示不可点（保留头像+名，无点击水波纹）
/// - 头像/名字带防 B 站图床防盗链头（Referer + 浏览器 UA，见 [CoverImage]）
///
/// 番剧（带 epId）等「无 UP 主页入口」场景由调用方决定是否渲染本组件
/// （player_page 对番剧走剧集标签分支、不渲染本组件）。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../theme/app_tokens.dart';

/// UP 主入口：圆形头像（默认 32px）+ 名字（可点）。
class UpownerBadge extends StatelessWidget {
  /// UP 主名字（view 接口 owner.name 拉取成功则覆盖 up_name 展示）。
  final String name;

  /// 头像 URL（view 接口 owner.face）；空 / 加载失败 → 首字圆形占位。
  final String? face;

  /// 点击回调（进 UP 主页）；null → 纯展示不可点。
  final VoidCallback? onTap;

  /// 头像直径（信息行用小号 32，紧凑不喧宾夺主）。
  final double avatarSize;

  const UpownerBadge({
    super.key,
    required this.name,
    this.face,
    this.onTap,
    this.avatarSize = 32,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: const ValueKey('upowner-badge'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(avatarSize / 2),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoundAvatar(
              key: const ValueKey('upowner-badge-avatar'),
              face: face,
              fallback: name,
              size: avatarSize,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                key: const ValueKey('upowner-badge-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: onTap == null
                      ? kInkGray50
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形头像：face 为空 / 加载失败 → 首字圆形占位。
class _RoundAvatar extends StatelessWidget {
  final String? face;
  final String fallback;
  final double size;

  const _RoundAvatar({
    super.key,
    required this.face,
    required this.fallback,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final url = face;
    if (url == null || url.isEmpty) return _placeholder(context);
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        headers: {
          'User-Agent': kBrowserUA,
          'Referer': kBiliReferer,
        },
        errorBuilder: (_, __, ___) => _placeholder(context),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: size,
            height: size,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          );
        },
      ),
    );
  }

  /// 占位：圆形浅底 + 名字首字（无名字 → '?'）。
  Widget _placeholder(BuildContext context) {
    final theme = Theme.of(context);
    final initial = fallback.isNotEmpty ? fallback.characters.first : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: theme.textTheme.labelMedium?.copyWith(
          fontSize: size * 0.42,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
