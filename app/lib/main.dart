import 'package:flutter/material.dart';

import 'pages/playlist_page.dart';

/// 全局路由观察者（v2.17.1+）：播放页 [RouteAware] 订阅它，感知「自己上面
/// 又叠了一个新的播放页」→ 暂停当前播放（防双音轨）并记进度，返回时恢复
/// 续播（见 player_page.dart 的 didPushNext / didPopNext）。判定依据是
/// push PlayerPage 的路由统一带 [RouteSettings.name] = 'player'
/// （[kPlayerRouteName]，见 player_page.dart）。
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

void main() {
  runApp(const BiliWhitelistApp());
}

/// B 站白名单点播 App。
///
/// 防短视频成瘾设计：首页只有白名单视频列表，无任何增删白名单入口；
/// 播放页 M3 实现。
/// 登录（解锁 1080P）：v2.16.18 起启动自动处理——已登录静默恢复（距过期
/// < 续期阈值自动续期：有 refresh_token 15 天提前续期 / 无则 7 天，
/// v2.16.21 分档，续期成功保存新会话长期保持），未登录/彻底过期自动进入
/// 登录页引导一次（可关闭：关闭=匿名，首页与播放页有明确「未登录仅 720P，
/// 去登录解锁 1080P」提示入口）；次级入口在管理面板（齿轮 →「B 站账号」
/// 登录/重新登录），首页不再有常驻登录按钮。
class BiliWhitelistApp extends StatelessWidget {
  const BiliWhitelistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '白名单点播',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [routeObserver],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00A1D6)),
        useMaterial3: true,
      ),
      home: const PlaylistPage(),
    );
  }
}
