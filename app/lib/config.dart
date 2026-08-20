/// 全局配置 —— 浏览器请求头、数据源 URL（集中管理，页面不散落硬编码）。
library;

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

/// B 站 API 域名。
const String kBiliApi = 'https://api.bilibili.com';

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
