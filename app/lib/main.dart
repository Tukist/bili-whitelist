import 'package:flutter/material.dart';

import 'pages/playlist_page.dart';

void main() {
  runApp(const BiliWhitelistApp());
}

/// B 站白名单点播 App。
///
/// 防短视频成瘾设计：首页只有白名单视频列表，无任何增删白名单入口；
/// 播放页 M3 实现。
/// 登录（解锁 1080P）：v2.16.18 起启动自动处理——已登录静默恢复（距过期
/// < 7 天自动续期），未登录自动进入登录页引导；次级入口在管理面板
/// （齿轮 →「B 站账号」登录/重新登录），首页不再有常驻登录按钮。
class BiliWhitelistApp extends StatelessWidget {
  const BiliWhitelistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '白名单点播',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00A1D6)),
        useMaterial3: true,
      ),
      home: const PlaylistPage(),
    );
  }
}
