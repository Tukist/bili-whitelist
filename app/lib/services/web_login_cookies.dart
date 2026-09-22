import 'package:flutter/services.dart';

/// 登录 WebView 的 cookie / 网页数据读写（原生 `CookieManager` MethodChannel 封装）。
///
/// 为什么单独成一层（v2.49.1+）：`SESSDATA` / `bili_jct` 是 HttpOnly cookie，
/// Dart 侧（含 `webview_flutter`）读不到，只能走原生 `android.webkit.CookieManager`
/// （见 `MainActivity.setupCookieChannel`）。原先通道名与调用点散在
/// `login_page.dart` 里，而「服务端判定会话已死 → 顺手清掉 WebView 里那份残留
/// cookie」这件事发生在 `BiliApi`（登录页之外），于是把通道收敛到这里，
/// 登录页与接口层共用同一份实现、同一套日志口径。
///
/// 所有方法在原生通道不可用时**抛异常**（测试环境 / 通道未注册），
/// 由调用方决定是提示用户还是静默跳过——不在这里吞掉，否则排查时看不出
/// "到底清没清"。
class WebLoginCookies {
  WebLoginCookies._();

  /// 原生 cookie 通道（`MainActivity.setupCookieChannel`）。
  /// 公开出来是为了让测试能替身整条通道（见 `test/login_cookie_verify_test.dart`）。
  static const MethodChannel channel = MethodChannel('bili_whitelist/cookie');

  /// 读 [url] 匹配的全部 cookie 串（形如 `SESSDATA=…; bili_jct=…`）；空串 = 没有。
  static Future<String> read({String url = 'https://www.bilibili.com/'}) async {
    final raw = await channel.invokeMethod<String>('getCookies', {'url': url});
    return raw ?? '';
  }

  /// 清空 WebView 的**全部** cookie（含 HttpOnly 的 SESSDATA / bili_jct）。
  ///
  /// **全清 vs 按域清的取舍**：按域清（对每个域写一条过期 cookie）只能覆盖
  /// 可被 `setCookie` 覆盖的 cookie，HttpOnly 的那些在部分 WebView 版本上写不进去，
  /// 清不干净等于白清；而这个 WebView **只用来登 B 站登录页**，jar 里除了 B 站
  /// 自己的域（`.bilibili.com` / `passport.bilibili.com` / 滑块用的第三方域）
  /// 没有别的站点的凭据——全清的副作用就是"滑块验证码下次要重新过一遍"，
  /// 代价可接受，换来的是"死 cookie 一定被清掉"这个确定性。
  static Future<void> clear() async {
    await channel.invokeMethod<void>('clearAll');
  }

  /// 清空 WebView 的全部网页数据：cookie + Web Storage（localStorage 等）。
  ///
  /// 与 [clear] 的区别：多了 Web Storage。用于「清除网页数据后重试」——
  /// 渲染进程反复崩溃 / profile 疑似损坏时，光清 cookie 未必够。
  /// HTTP 缓存不在这里（原生 `CookieManager` 管不到），由登录页拿到
  /// `WebViewController` 后调 `clearCache()` / `clearLocalStorage()` 补上。
  static Future<void> clearAllData() async {
    await channel.invokeMethod<void>('clearAllData');
  }
}
