import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/bilibili_api.dart';

/// 登录页 WebView 专用移动 UA（仅影响登录页，不动 API 层的 kBrowserUA）。
///
/// B 站登录页是同一套 SPA（passport-pc），前端按 UA 响应式渲染：
/// - 桌面 UA → 桌面版布局，默认展示"扫码登录"，短信/密码 tab 折叠隐藏，
///   手机上既扫不了码也找不到短信入口；
/// - 移动 UA → 移动版布局，主入口即"手机号 + 验证码登录"，短信验证码直接可见。
///
/// 故登录页必须用移动 UA（与本 App 实际运行环境一致），扫码方案不适用于
/// 没有装 B 站 App 的用户。API 层的 kBrowserUA 保持不变（防盗链必需）。
const String kLoginMobileUA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 '
    'Build/TQ3A.230805.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36';

/// 内嵌 B 站官方登录页（WebView 登录，M4 替代原扫码登录）。
///
/// 加载 https://passport.bilibili.com/login，用户在页面内用**短信验证码**
/// （或账号密码）登录。登录态提取链路：
///
/// 1. 原生 `CookieManager`（MethodChannel `bili_whitelist/cookie`）读 HttpOnly
///    cookie —— SESSDATA/bili_jct 是 HttpOnly，JS 读不到，必须走原生侧；
///    cookie 串里出现 SESSDATA 即判定登录成功。
/// 2. `runJavaScript` 遍历页面 localStorage 找 refresh_token（社区文档记录
///    的 key 是 `ac_time_value`，未实测到则以兜底遍历长串代替）。
/// 3. 全部存入 flutter_secure_storage（沿用 M0 起的
///    bili_sessdata / bili_jct / bili_refresh_token 三个 key）后自动返回。
///
/// refresh_token 没抓到也不阻塞登录：自动续期会退化为"到期重新登录"。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  /// 原生 cookie 读取通道（见 MainActivity.setupCookieChannel）。
  static const _cookieChannel = MethodChannel('bili_whitelist/cookie');

  final BiliApi _api = BiliApi();

  WebViewController? _controller;
  double _progress = 0;
  Timer? _pollTimer;

  /// 已处理过的 SESSDATA，防止重复保存/重复 pop。
  String? _handledSessdata;

  @override
  void initState() {
    super.initState();
    _initWebView();
    // 定时轮询兜底：登录成功后不一定触发 onPageFinished（如仅 Set-Cookie 不跳页）
    _pollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _checkLogin());
    // 通道自检（一次性）：确认原生 CookieManager 通道可用，便于排查登录检测链路
    WidgetsBinding.instance.addPostFrameCallback((_) => _selfCheckChannel());
  }

  /// 自检 cookie 通道并打日志（仅诊断用，不影响功能）。
  Future<void> _selfCheckChannel() async {
    try {
      final raw = await _cookieChannel.invokeMethod<String>('getCookies', {
        'url': 'https://www.bilibili.com/',
      });
      debugPrint('[login] cookie channel ok, len=${raw?.length ?? 0}');
    } catch (e) {
      debugPrint('[login] cookie channel FAILED: $e');
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _initWebView() async {
    final controller = WebViewController()
      // JS 开启：短信验证码 / 滑块风控都需要
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // 移动 UA：让 B 站渲染移动版登录页，主入口即"手机号+验证码登录"。
      // 桌面 UA 会渲染桌面版（默认扫码登录），短信入口折叠隐藏，用户扫不了码
      // （未装 B 站 App）也找不到短信登录 → 必须用移动 UA。
      // 此 UA 仅作用于本 WebView，API 层 kBrowserUA（防盗链）不受影响。
      ..setUserAgent(kLoginMobileUA)
      ..setNavigationDelegate(
        NavigationDelegate(
          // 加载进度（顶部进度条）
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100);
          },
          // 只放行 http/https（登录页会跳 passport.bilibili.com / www.bilibili.com，
          // 滑块资源来自 geetest.com 等，一律放行）；其余 scheme 拦截
          onNavigationRequest: (request) {
            final scheme = Uri.tryParse(request.url)?.scheme;
            if (scheme == 'http' || scheme == 'https') {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          // 页面加载完成时立刻查一次登录态（比轮询更及时）
          onPageFinished: (_) => _checkLogin(),
        ),
      )
      ..loadRequest(Uri.parse('https://passport.bilibili.com/login'));
    _controller = controller;
    if (mounted) setState(() {});
  }

  // -------------------------------------------------------------------------
  // 登录态检测与提取
  // -------------------------------------------------------------------------

  /// 读 WebView cookie 判断登录是否成功；成功后提取登录态并返回。
  Future<void> _checkLogin() async {
    if (_controller == null) return;
    String cookies;
    try {
      cookies = await _cookieChannel.invokeMethod<String>('getCookies', {
        'url': 'https://www.bilibili.com/',
      }) ??
          '';
    } catch (_) {
      return; // 原生通道未就绪（如测试环境），静默等待
    }
    if (cookies.isEmpty) return;

    String? sessdata;
    String? biliJct;
    for (final pair in cookies.split(';')) {
      final kv = pair.trim().split('=');
      if (kv.length != 2) continue;
      if (kv[0] == 'SESSDATA' && sessdata == null) sessdata = kv[1];
      if (kv[0] == 'bili_jct' && biliJct == null) biliJct = kv[1];
    }
    if (sessdata == null || sessdata.isEmpty) return; // 还没登录成功
    if (sessdata == _handledSessdata) return; // 已处理过

    _handledSessdata = sessdata;
    _pollTimer?.cancel();
    final refreshToken = await _extractRefreshToken();
    try {
      await _api.saveSession(
        sessdata: sessdata,
        biliJct: biliJct ?? '',
        refreshToken: refreshToken ?? '',
      );
    } catch (e) {
      // 保存失败（如 secure storage 底层异常）：绝不能让本次登录静默丢失——
      // 重置"已处理"标记并恢复轮询，下一次检测（1s 后）自动重试保存；
      // WebView 里的登录态还在，重试通常一次即成功。不弹"登录成功"。
      debugPrint('[login] saveSession FAILED, will retry: $e');
      _handledSessdata = null;
      _pollTimer = Timer.periodic(
          const Duration(seconds: 1), (_) => _checkLogin());
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登录成功，已解锁 1080P 清晰度')),
    );
    Navigator.of(context).pop(true);
  }

  /// 遍历 WebView 页面 localStorage 提取 refresh_token。
  ///
  /// B 站 web 登录成功后会把持久化刷新口令放在 localStorage，社区记录
  /// （bilibili-API-collect）的 key 是 `ac_time_value`；此处先按已知 key 查，
  /// 兜底遍历所有值找形似 token 的长串。找不到返回 null（续期退化为重登）。
  Future<String?> _extractRefreshToken() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final raw = await controller.runJavaScriptReturningResult('''
        (() => {
          try {
            const out = {};
            for (let i = 0; i < localStorage.length; i++) {
              const k = localStorage.key(i);
              const v = localStorage.getItem(k);
              if (v) out[k] = v;
            }
            return JSON.stringify(out);
          } catch (e) {
            return '{}';
          }
        })()
      ''');
      final map = _parseJsJson(raw);
      for (final key in const ['ac_time_value', 'refresh_token', 'access_token']) {
        final v = map[key];
        if (v is String && v.isNotEmpty && _looksLikeToken(v)) return v;
      }
      // 兜底：遍历找形似 token 的长串
      for (final entry in map.entries) {
        final v = entry.value;
        if (v is String && v.length >= 16 && _looksLikeToken(v)) return v;
      }
    } catch (_) {
      // 页面可能已跳走 / 跨域读不到，静默忽略
    }
    return null;
  }

  /// 粗略判断一个值是否形似 token：32 位 hex 或 >=24 位字母数字串。
  static bool _looksLikeToken(String v) {
    if (v.length < 16) return false;
    if (RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(v)) return true;
    if (RegExp(r'^[A-Za-z0-9_\-\.]{24,}$').hasMatch(v)) return true;
    return false;
  }

  /// 解析 `runJavaScriptReturningResult` 返回的 JSON。
  ///
  /// Android 侧对 JS 字符串结果会再包一层 JSON 引号，最多剥两层。
  static Map<String, dynamic> _parseJsJson(Object? raw) {
    var s = raw is String ? raw.trim() : '';
    for (var i = 0; i < 2; i++) {
      if (s.startsWith('{')) {
        try {
          final decoded = jsonDecode(s);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
        return const {};
      }
      try {
        final inner = jsonDecode(s);
        if (inner is String) {
          s = inner.trim();
          continue;
        }
        if (inner is Map<String, dynamic>) return inner;
      } catch (_) {}
      break;
    }
    return const {};
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录'),
        // 默认返回箭头即"关闭/返回"按钮（未登录直接退出也可）
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: LinearProgressIndicator(
            value: _progress >= 1 ? null : _progress,
            minHeight: 2,
            backgroundColor: Colors.transparent,
          ),
        ),
      ),
      body: controller == null
          ? const Center(child: CircularProgressIndicator())
          : WebViewWidget(controller: controller),
    );
  }
}
