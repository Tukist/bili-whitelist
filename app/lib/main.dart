import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/playlist_page.dart';
import 'services/inbox_card_style_store.dart';
import 'services/theme_store.dart';
import 'theme/app_theme.dart';

/// 全局路由观察者（v2.17.1+）：播放页 [RouteAware] 订阅它，感知「自己上面
/// 又叠了一个新的播放页」→ 暂停当前播放（防双音轨）并记进度，返回时恢复
/// 续播（见 player_page.dart 的 didPushNext / didPopNext）。判定依据是
/// push PlayerPage 的路由统一带 [RouteSettings.name] = 'player'
/// （[kPlayerRouteName]，常量定义在 `lib/theme/route_names.dart`；
/// player_page.dart 只做 export 转发）。
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

void main() {
  // 读已保存的配色配方（P1.5）：必须在 runApp 前确保 binding 就绪
  // （SharedPreferences 走平台通道）。读到非默认配方时会 notifyListeners，
  // 首帧即用用户选的墨色，不闪默认色。
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(ThemeStore.instance.ensureLoaded());
  // 读已保存的**信箱卡片样式**（v2.21.0+）：同上，首帧即用用户选的版式，
  // 不先闪一下默认版式。store 内部读失败静默（回退默认）。
  unawaited(InboxCardStyleStore.instance.ensureLoaded());
  runApp(const BiliWhitelistApp());
}

/// amoTV —— B 站白名单点播 App。
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
    // 监听配色 store（P1.5）：换配方 → 重建 MaterialApp → AnimatedTheme
    // 按 AppPalette.lerp 平滑过渡，全 App 换墨。
    return ListenableBuilder(
      listenable: ThemeStore.instance,
      builder: (context, _) => MaterialApp(
        title: 'amoTV',
        debugShowCheckedModeBanner: false,
        navigatorObservers: [routeObserver],
        // 全局主题（P1 视觉地基 + P1.5 配方）：单墨/双墨编辑印刷，见 lib/theme/。
        theme: buildAppTheme(ThemeStore.instance.recipe),
        // 只做浅色纸面，不跟随系统深色（暗底只存在于播放视口内）。
        themeMode: ThemeMode.light,
        home: const PlaylistPage(),
      ),
    );
  }
}
