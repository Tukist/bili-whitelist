/// 路由名常量。放在 theme 层，供 app_theme 的转场分流与各页面共同引用。
///
/// 为什么在 theme 层：转场（`app_theme.dart` 的 pageTransitionsTheme /
/// 自定义 `PageRoute`）需要按路由名分流，若常量留在 `pages/player_page.dart`
/// 就会产生 `theme → pages` 的跨层依赖（主题反过来依赖页面，方向是错的）。
///
/// 值**不可改**：`main.dart` 的全局 [RouteObserver]（RouteAware 匹配）
/// 与各入口 push 时写的 `RouteSettings(name:)` 靠这个字符串对齐，
/// 改一个字符就会让播放页收不到 `didPopNext`（返回播放页不再续播）。
library;

/// push 新播放页的路由名（v2.17.1+，评论视频链接跳转 / 各入口统一）。
///
/// 播放页以 RouteAware（全局 routeObserver，见 `main.dart`）订阅路由：
/// `didPopNext`（本页重新成为顶层）时恢复续播。暂停不是靠 didPushNext 判定
/// （该版本 `didPushNext()` 无参、无法按路由名过滤，见 player_page 内机制
/// 取舍注释），而是由 push 新播放页的调用点在 RouteAware 之外显式执行。
const String kPlayerRouteName = 'player';

/// 图片查看页的路由名（当前无入口带 name push，先定义占位，
/// 供后续做图片 Hero / 转场分流时统一引用）。
const String kImageViewerRouteName = 'image_viewer';
