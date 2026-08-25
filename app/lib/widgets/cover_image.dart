/// 共享封面图组件：必须带防盗链头（Referer + 浏览器 UA），否则 B 站图床 403。
///
/// 从 playlist_page 原私有 `_CoverImage` 抽出，搜索页结果列表复用同一实现。
library;

import 'package:flutter/material.dart';

import '../config.dart';

/// 封面图（带防盗链头 + 加载/失败占位）。
class CoverImage extends StatelessWidget {
  final String cover;
  final double width;
  final double height;

  const CoverImage({
    super.key,
    required this.cover,
    this.width = 72,
    this.height = 45,
  });

  @override
  Widget build(BuildContext context) {
    if (cover.isEmpty) {
      return _placeholder(context, Icons.movie_outlined);
    }
    return Image.network(
      cover,
      width: width,
      height: height,
      fit: BoxFit.cover,
      headers: {
        'User-Agent': kBrowserUA,
        'Referer': kBiliReferer,
      },
      errorBuilder: (_, __, ___) => _placeholder(context, Icons.broken_image_outlined),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, IconData icon) {
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 20),
    );
  }
}
