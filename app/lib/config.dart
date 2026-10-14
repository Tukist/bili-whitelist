/// 全局配置 —— 浏览器请求头、数据源 URL（集中管理，页面不散落硬编码）。
library;

import 'services/ui_prefs_store.dart';

/// App 版本显示兜底值（与 pubspec.yaml 的 version 主版本号保持一致）。
///
/// 正常运行时优先用 package_info_plus 读取 Android versionName（来源是
/// pubspec.yaml 的 `version:` 字段，单源）；仅当插件不可用（如测试环境/
/// 原生通道异常）时回退到本常量，保证列表页版本号始终可显示。
const String kAppVersion = '2.0.0';

/// 浏览器 User-Agent。
///
/// M0 实测（probe.md）：非浏览器 UA / 无 UA 头请求 .bilivideo.com 流或
/// i*.hdslb.com 封面会 403；必须是浏览器 UA 才能过防盗链。
const String kBrowserUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 「官方 App 特征」User-Agent（**只给视频/音频流类请求用**，v2.51.0+）。
///
/// 用途：设置页「免流兼容（实验）」开关打开时，DASH/mp4 流、直播 HLS、离线下载、
/// 语音转写的临时音频下载改用这个 UA —— 运营商若按「App 特征」判定免流范围，
/// 浏览器 UA 会被算成「网页流量」（不计入定向免流），换成带 os/model/mobi_app/
/// build/channel/innerVer 的这串才是官方 App 的样子。
///
/// ⚠️ **它只在 App 形态直链上有效**（2026-10 实测，10 组对照）：
/// - App gRPC `PlayView` 下发的直链（CDN 签名 `platform=android`）：
///   **带这串 UA + 不带 Referer** → 206；
/// - 网页/REST 接口下发的直链（签名 `platform=pc`）：带这串 UA → **403**
///   （不管带不带 Referer）。
///
/// 所以「免流兼容」开关**不是只换 UA**（v2.52.0 起）：打开后取流也改走
/// `PlayView`（见 `api/playview_api.dart`），UA 与链路配套；只换 UA 而仍用
/// 网页直链是**必然 403** 的（v2.51.x 那版就是这样，已修正）。
/// CDN 策略若再变（例如又改判 Referer/签名），这条路径会失效 → 关掉开关即可。
const String kBiliAppUA = 'Mozilla/5.0 BiliDroid/7.65.0 (bbcallen@gmail.com) '
    'os/android model/Pixel 7 mobi_app/android build/7650300 channel/bili '
    'innerVer/7650300 osVer/15 network/2';

/// 「免流兼容（实验）」此刻是否**真的在生效**（v2.51.1+）。
///
/// = 用户开着这个开关 **且** 本次运行会话还没被自动回退过
/// （[UiPrefsStore.streamCompatSessionFallback]，见那里的取舍说明）。
/// [streamUserAgent]、`player_page` 的取流链路选择一律走这个判据 ——
/// 全 App 的免流形态只此一处决定，回退因此"只回退自己这一套"。
bool streamCompatInUse() =>
    UiPrefsStore.instance.streamCompatEnabled &&
    !UiPrefsStore.instance.streamCompatSessionFallback;

/// 视频/音频**流类**请求应当使用的 User-Agent（v2.51.0+）。
///
/// 开关（[UiPrefsStore.streamCompatEnabled]，设置页「免流兼容（实验）」）关着
/// （或本次会话已自动回退，见 [streamCompatInUse]）时返回 [kBrowserUA]
/// （改动前的行为）；否则返回 [kBiliAppUA]。
///
/// **只用于流**：DASH / mp4 降级流（原生 ExoPlayer）、直播 HLS、离线缓存下载、
/// 语音转写的临时音频下载。**API 请求（[biliHeaders]）、图片请求、直播弹幕 WS、
/// 登录页 WebView 一律继续用 [kBrowserUA]** —— API 改 UA 有风控风险（实测精简头
/// 会被 -412），图片改了对免流毫无帮助（且实测非浏览器 UA 取封面会 403）。
String streamUserAgent() => streamCompatInUse() ? kBiliAppUA : kBrowserUA;

/// 视频/音频**流类**请求的完整请求头（v2.51.0+）：只有 Referer + UA，不带 cookie
/// （离线缓存下载与语音转写临时音频下载同策略，M0 实测）。
///
/// ⚠️ **v2.53.0 起这条"只按开关换 UA"的头不再用于下载**（见
/// [biliStreamHeadersFor]）：开关打开时取流已改走 App gRPC `PlayView`，它下发的
/// 直链是 `platform=android`；而这里恒定带 Referer、UA 又按开关切 —— 拿它去请求
/// 网页形态直链（`platform=pc`）配 App UA 会 **403**（v2.51.x 那个 bug）。
/// 保留它是因为它仍然是"开关 → UA"这一层语义的**可测单点**（测试直接钉住
/// Referer 恒定、UA 跟着开关走），别在下载路径上再用它。
Map<String, String> biliStreamHeaders() => {
      'User-Agent': streamUserAgent(),
      'Referer': kBiliReferer,
    };

/// 流类请求头的**按 URL 分流**版本（v2.53.0+）：与原生
/// `DashExoPlayer.networkFactoryFor(url)` 同一判据、同一套头。
///
/// 判据是 URL 里的 CDN 签名参数，**不是开关状态**：
/// - `platform=android`（官方 App 形态直链，由 `PlayView` 下发）→ 只发
///   [kBiliAppUA]、**故意不带 Referer**（带了必 403）；UA 固定用 App 特征值
///   而不看开关原值 —— 这条链的取流鉴权要的就是它，URL 本身已经是"这条链是
///   App 形态"的证据（开关可能在下载过程中被关掉，不能让它把链接搞成 403）；
/// - 其余（网页/REST/番剧链一律 `platform=pc`，直播 HLS 无该参数）→
///   浏览器 UA + [kBiliReferer]（M0 实测：非浏览器 UA 取这些链会 403）。
///
/// 为什么下载路径必须改成看 URL 而不是看开关：一次会话里两种链会并存
/// （`PlayView` 取流失败回落网页接口、番剧走 pgc 端点），按开关判会误伤
/// 其中一条（v2.51.x 的离线下载/语音转写就是这么吃到 403 的）。
Map<String, String> biliStreamHeadersFor(String url) =>
    url.contains('platform=android')
        ? {'User-Agent': kBiliAppUA}
        : {'User-Agent': kBrowserUA, 'Referer': kBiliReferer};

/// B 站 API 域名。
const String kBiliApi = 'https://api.bilibili.com';

/// B 站**直播** API 域名。
///
/// ⚠️ 直播接口（如 `room/v1/Room/getRoomInfoOld`）不在 [kBiliApi] 上：
/// 打到 `api.bilibili.com` 会 404（返回 HTML 出错页），必须用
/// `api.live.bilibili.com`（2026-09 实测：200 / code=0）。
const String kLiveApi = 'https://api.live.bilibili.com';

/// 防盗链 Referer：.bilivideo.com 流与 i*.hdslb.com 封面请求必须带。
const String kBiliReferer = 'https://www.bilibili.com/';

/// 完整浏览器请求头。
///
/// 2026-08 实测（whitelist.py 对照实验）：精简头（只带 UA+Referer）匿名请求
/// 会被 -412 拦截；补齐 Sec-Ch-Ua / Sec-Fetch-* / Accept-Language / Origin
/// 后才能正常通过。本函数与 M1 脚本 FULL_HEADERS 完全同一套头。
Map<String, String> biliHeaders() => {
      'User-Agent': kBrowserUA,
      'Referer': kBiliReferer,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,'
          'image/avif,image/webp,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Sec-Ch-Ua': '"Not/A)Brand";v="8", "Chromium";v="126", '
          '"Google Chrome";v="126"',
      'Sec-Ch-Ua-Mobile': '?0',
      'Sec-Ch-Ua-Platform': '"Windows"',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-site',
      'Origin': 'https://www.bilibili.com',
    };

/// 白名单数据源配置。
///
/// 可用 `--dart-define` 在构建/运行时覆盖，例如：
/// ```bash
/// flutter run --dart-define=GIST_URL=https://gist.githubusercontent.com/xx/raw
/// flutter build apk --dart-define=LAN_URL=http://192.168.1.5:8000/whitelist.json
/// ```
class AppConfig {
  /// GitHub Gist raw 地址（whitelist.json 同步源，M1 `python whitelist.py push` 产出）。
  static const String gistUrl = String.fromEnvironment('GIST_URL',
      defaultValue:
          'https://gist.githubusercontent.com/Tukist/73a6e23f94d55dc7a1f88e4a2a7557d5/raw/whitelist.json');

  /// PC 局域网地址（M1 `python whitelist.py serve` 产出，手机连同一 Wi-Fi 访问）。
  static const String lanUrl = String.fromEnvironment('LAN_URL',
      defaultValue: '');

  /// 本地手动导入文件相对应用文档目录的文件名（供 LocalFileSource 使用）。
  static const String localImportFileName = 'whitelist_local.json';

  /// 自动缓存文件名（SyncService 成功同步后写入）。
  static const String cacheFileName = 'whitelist_cache.json';
}
