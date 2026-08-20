import 'package:flutter/material.dart';

import 'pages/playlist_page.dart';

void main() {
  runApp(const BiliWhitelistApp());
}

/// B 站白名单点播 App。
///
/// 防短视频成瘾设计：首页只有白名单视频列表，无任何增删白名单入口；
/// 登录页从首页右上角进入（解锁 1080P）；播放页 M3 实现。
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
