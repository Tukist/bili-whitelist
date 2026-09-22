import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/bilibili_api.dart';
import '../services/web_login_cookies.dart';
import '../widgets/app_state_view.dart';

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

/// 自动引导登录时的提示条文案（LoginPage 顶部，仅自动登录路径传入）：
/// 说明登录态会自动保存、之后每次进入自动恢复，避免用户误以为每次都要登录。
const String kAutoLoginBanner = '登录 B 站账号可解锁 1080P 高清（手机号+验证码）。'
    '登录后自动保存：下次进入 App 自动恢复，无需再次登录；不登录也能看（最高 720P）。';

/// 内嵌 B 站官方登录页（WebView 登录，M4 替代原扫码登录）。
///
/// 加载 https://passport.bilibili.com/login，用户在页面内用**短信验证码**
/// （或账号密码）登录。登录态提取链路：
///
/// 1. 原生 `CookieManager`（[WebLoginCookies]）读 HttpOnly cookie ——
///    SESSDATA/bili_jct 是 HttpOnly，JS 读不到，必须走原生侧；cookie 串里
///    出现 SESSDATA 后**先做服务端校验**（[BiliApi.verifySession]），服务端
///    点头才算登录成功（见 [_checkLogin] 的说明）。
/// 2. `runJavaScript` 遍历页面 localStorage 找 refresh_token（社区文档记录
///    的 key 是 `ac_time_value`，未实测到则以兜底遍历长串代替）。
/// 3. 全部存入 flutter_secure_storage（沿用 M0 起的
///    bili_sessdata / bili_jct / bili_refresh_token 三个 key）后自动返回。
///
/// refresh_token 没抓到也不阻塞登录：自动续期会退化为"到期重新登录"。
class LoginPage extends StatefulWidget {
  /// 顶部提示条（自动登录引导时传入 [kAutoLoginBanner]；手动打开不传）。
  final String? banner;

  /// 服务端校验用的接口客户端（测试注入 fake adapter 用；默认自建一个）。
  final BiliApi? api;

  /// 创建并加载 WebView 的实现（测试注入替身用）。
  ///
  /// 默认实现 = 真 `WebViewController` + 导航委托 + 加载登录页。留这个口子
  /// 是因为 `flutter_test` 环境没有 WebView 平台实现（`WebViewController()`
  /// 构造即抛），而「构造成功、但页面迟迟加载不完（渲染进程崩了）」这条路径
  /// 是本版重点修的——它必须能被测试覆盖。
  final Future<void> Function()? createWebView;

  const LoginPage({super.key, this.banner, this.api, this.createWebView});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 登录页要告诉用户、但不必打断操作的一条告警（可带一个行动按钮）。
class _LoginNotice {
  final String text;

  /// 行动按钮文案（null = 只有文字）。
  final String? actionLabel;

  /// 行动按钮回调。
  final VoidCallback? onAction;

  const _LoginNotice(this.text, {this.actionLabel, this.onAction});
}

class _LoginPageState extends State<LoginPage> {
  late final BiliApi _api = widget.api ?? BiliApi();

  WebViewController? _controller;
  double _progress = 0;
  Timer? _pollTimer;

  /// 加载看门狗：WebView 的**渲染进程崩掉时没有任何 Dart 回调**（页面就那么
  /// 白屏/停住），只能靠「迟迟等不到 onPageFinished」来判定。
  ///
  /// 真机取证（2026-09-22 21:38）：用户点「去登录」后 WebView 初始化正常
  /// （`[login] cookie channel ok, len=677`），紧接着系统日志出现
  /// `Failed to validate the certificate chain` / `net_error -202`，7 秒后
  /// `Renderer process (24871) crash detected (code -1)`。旧代码对这两件事
  /// 都没有任何处理 → 用户面对一个没有提示、不能重试的空白登录页。
  Timer? _loadWatchdog;

  /// 看门狗超时（v2.49.1+ 由 30 秒缩到 **10 秒**）。
  ///
  /// 取 10 秒的理由（只按实测到的耗时定，不凭感觉）：
  /// - 正常时这个页面几秒内就起来（模拟器实测：点开登录页到 WebView 进程/页面
  ///   开始渲染约 1.5 秒，且登录态检测在 1 秒轮询里就完成了）；
  /// - 坏掉时的**真实耗时**是 1~7 秒：真机证书错误（`net_error -202`）立刻回调、
  ///   渲染进程 7 秒内就崩；模拟器上这次也复现了渲染进程崩溃
  ///   （`Renderer process crash detected (code -1)`）；
  /// - 原来 30 秒意味着用户盯着白屏半分钟才等到一句"可能崩了"，而这半分钟里
  ///   他唯一能做的就是怀疑 App 卡死并强杀。
  /// 10 秒 = 「慢网（3G/校园网这类几秒~十几秒的页面）仍有机会自己加载完」与
  /// 「坏掉别让人干等」的折中；真等到超时也不是死路——错误页直接给「重试」与
  /// 「清除网页数据后重试」两个出口。
  static const Duration _kLoadTimeout = Duration(seconds: 10);

  /// 已处理过的 SESSDATA，防止重复保存/重复 pop、防止每秒轮询反复打服务端。
  String? _handledSessdata;

  /// 服务端校验在途（同一时刻只允许一次校验，避免 1 秒轮询叠加请求）。
  bool _verifying = false;

  /// 服务端校验**已通过**、但写盘失败时挂起的那次登录（每秒重试写盘，
  /// 不重新走服务端校验——刚验过，重验只是白打接口）。
  _PendingLogin? _pendingSave;

  /// 正在执行「清除网页数据后重试」（按钮置灰用）。
  bool _clearingWebData = false;

  /// WebView 初始化 / 页面加载失败的原因（null = 正常）。
  ///
  /// 为什么要有这个状态（v2.49.1+）：`WebViewController()` 与 `loadRequest`
  /// 在部分国产 ROM（WebView provider 被精简 / 系统组件异常）上会抛
  /// PlatformException，旧代码没有 try/catch → 页面永远停在「三颗方点」的
  /// 加载动画上，用户看到的是「点了去登录就没反应」，既不知道坏了、也没法
  /// 重试。加载期的失败（DNS/证书/连接重置/渲染进程崩溃）同理没有任何提示。
  /// 现在一律给整页错误态 + 重试按钮。
  String? _initError;

  /// 已展示的加载错误是否属于"证书问题"（文案里给"检查代理/VPN"的提示用）。
  bool _initErrorIsCert = false;

  /// 需要告诉用户、但不必打断操作的告警（null = 无）。
  ///
  /// 覆盖原先只写日志、真机上用户完全看不到的失败（v2.49.1+）：
  /// 原生 cookie 通道不可用（登录成功也检测不到）、服务端不认这份登录状态
  /// （不落盘、不返回）、校验通过但写盘失败（每秒重试却毫无提示，像卡死）。
  _LoginNotice? _notice;

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

  /// 自检 cookie 通道：可用只打日志；不可用则**明确告诉用户**。
  ///
  /// 通道不可用时用户能在 WebView 里正常登录，但 App 永远读不到 cookie、
  /// 永远不会自动返回——这种「登录了却毫无反应」必须说出来（旧代码只
  /// debugPrint，真机上不可见）。
  Future<void> _selfCheckChannel() async {
    try {
      final raw = await WebLoginCookies.read();
      debugPrint('[login] cookie channel ok, len=${raw.length}');
    } catch (e) {
      debugPrint('[login] cookie channel FAILED: ${e.runtimeType}');
      if (mounted) {
        setState(() => _notice = const _LoginNotice(
            '无法读取登录 Cookie（原生组件不可用）。登录可能不会被 App 识别，建议返回后重进本页。'));
      }
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _loadWatchdog?.cancel();
    super.dispose();
  }

  /// 启动加载看门狗（见 [_loadWatchdog] 的说明）。
  void _startWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(_kLoadTimeout, () {
      if (!mounted) return;
      // 已经有更具体的错误（构造抛异常 / 证书被拒 / 连接重置…）→ 让位：
      // "超时"这句比具体原因模糊得多，盖掉它等于把最有用的诊断信息弄丢。
      if (_initError != null) {
        debugPrint('[login] 看门狗触发，但已有具体错误，保留原提示');
        return;
      }
      // 进度已经走到 100% 却没等到 onPageFinished：页面其实渲染出来了（可能
      // 只是回调丢了），**别把用户能用的页面换成一整页错误**——只清掉看门狗。
      if (_progress >= 1) {
        debugPrint('[login] 看门狗触发但进度已 100%（页面应已渲染），不报错');
        _clearWatchdog();
        return;
      }
      // 渲染进程崩掉时不会有任何 Dart 回调，只能靠"等不到 onPageFinished"判定
      debugPrint('[login] 登录页 ${_kLoadTimeout.inSeconds} 秒仍未加载完成'
          '（progress=${_progress.toStringAsFixed(2)}）');
      setState(() => _initError =
          '登录页 ${_kLoadTimeout.inSeconds} 秒仍未加载完成（进度 ${(_progress * 100).round()}%）。'
          '可能是网络太慢，也可能是系统 WebView 组件崩了（这种会白屏或停住）。');
    });
  }

  void _clearWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
  }

  /// 重试：已有 WebView 就重新加载它（渲染进程崩溃 / 加载超时的场景），
  /// 没有（初始化就失败）才重建一个。
  Future<void> _retryInit() async {
    if (mounted) setState(() => _initError = null);
    final controller = _controller;
    if (controller != null) {
      try {
        _startWatchdog();
        await controller.reload();
        return;
      } catch (e) {
        // reload 也失败 → 落到重建流程
        debugPrint('[login] reload 失败，改为重建 WebView: $e');
      }
    }
    await _initWebView();
  }

  Future<void> _initWebView() async {
    // 看门狗在**创建之前**就起：真机上"点了去登录没反应"既可能是构造抛异常，
    // 也可能是构造/加载卡住不返回（渲染进程崩溃时一个回调都不会有），
    // 两者都要能被 10 秒后的提示兜住；已有具体错误时它在回调里自动让位。
    _startWatchdog();
    try {
      final factory = widget.createWebView;
      if (factory != null) {
        await factory();
      } else {
        await _createWebView();
      }
    } catch (e) {
      // 旧代码这里没有 try/catch：抛了就停在「三颗方点」上（看起来像卡死）。
      debugPrint('[login] WebView 初始化失败: ${e.runtimeType} $e');
      if (mounted) {
        setState(() => _initError = '登录页加载失败（${e.runtimeType}）：$e');
      }
    }
  }

  /// 「清除网页数据后重试」（v2.49.1+）：清 cookie / Web Storage / HTTP 缓存后
  /// **重建** WebView。
  ///
  /// 为什么需要它：真机上渲染进程反复崩溃（`Renderer process crash detected`）
  /// 时，App 侧能做的只有"把这块地盘清干净再起一次"——cookie、localStorage、
  /// HTTP 缓存都是可能把 WebView 拖进坏状态的持久数据。**重建而不是 reload**：
  /// 崩掉的渲染进程在同一个 WebView 实例上 reload 未必能换到一个干净的进程。
  Future<void> _clearWebDataAndRetry() async {
    if (mounted) {
      setState(() {
        _clearingWebData = true;
        _initError = null;
        _initErrorIsCert = false;
        _progress = 0;
      });
    }
    // 1) cookie + Web Storage：走原生通道（HttpOnly cookie 只有原生能清）
    try {
      await WebLoginCookies.clearAllData();
      debugPrint('[login] 已清除 WebView cookie + Web Storage');
    } catch (e) {
      debugPrint('[login] 清除 WebView 网页数据失败（通道不可用？）：${e.runtimeType}');
    }
    // 2) HTTP 缓存 + localStorage：走 webview_flutter 自己的接口（要 controller）
    final stale = _controller;
    if (stale != null) {
      try {
        await stale.clearCache();
        await stale.clearLocalStorage();
        debugPrint('[login] 已清除 WebView HTTP 缓存 + localStorage');
      } catch (e) {
        debugPrint('[login] 清理 WebView 缓存失败：${e.runtimeType}');
      }
    }
    // 3) 丢掉旧 WebView，重建一个干净的
    if (mounted) {
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    await _initWebView();
    if (mounted) setState(() => _clearingWebData = false);
  }

  Future<void> _createWebView() async {
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
          onPageFinished: (_) {
            _clearWatchdog();
            _checkLogin();
          },
          // 主框架加载失败（DNS 失败 / 证书被拒 / 连接重置…）：旧代码没有这个
          // 回调 → WebView 白屏、用户毫无提示（真机 21:38 取证里就有
          // `Failed to validate the certificate chain` + `net_error -202`）。
          // 只报主框架：子资源（图片 / CDN / 滑块）失败不影响登录，报了是噪音。
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            // 错误码 / 类型 / **主机名** / 描述全打日志（脱敏：不带 cookie、
            // 不带 token、不带 query；主机名对"是代理还是站点挂了"是关键证据）。
            // 真机取证里最缺的就是这一行：只知道"崩了"，不知道崩在哪一步。
            _logResourceError(error);
            _clearWatchdog();
            if (mounted) {
              setState(() {
                _initErrorIsCert = _looksLikeCertError(error);
                _initError = _initErrorIsCert
                    ? '登录页加载失败：证书校验不通过（${error.errorCode}）。'
                        '这通常是网络里有代理 / VPN 在替换证书——请关掉代理或 VPN 后重试。'
                    : '登录页加载失败（${error.errorCode}）：${error.description}';
              });
            }
          },
        ),
      );
    // 先把 controller 挂上再 loadRequest：万一 loadRequest 卡住不返回（渲染进程
    // 崩掉时真机上出现过），看门狗要能给出错误态、用户要能看见页面在加载
    // （旧代码把赋值放在 loadRequest 之后，卡住时 `_controller == null`，
    // 看门狗与 WebViewWidget 都无从生效，页面就一直是"三颗方点"）。
    _controller = controller;
    if (mounted) setState(() => _initError = null);
    // 看门狗已在 [_initWebView] 起好（覆盖"构造/加载卡住"两条路），这里不重复起。
    // 显式 await：`loadRequest` 抛错（系统 WebView 组件异常）要能被
    // [_initWebView] 的 try/catch 接住 → 换错误态，而不是停在加载动画
    await controller.loadRequest(Uri.parse('https://passport.bilibili.com/login'));
  }

  /// 把一次资源加载失败写进日志（脱敏）：错误码、类型、主机名、描述。
  ///
  /// **主机名不带路径**（`Uri.host`）：登录页与 API 域名的路径里可能带查询参数，
  /// 全 URL 打出来有泄凭据的风险，而排查只需要"失败发生在哪个域"。
  void _logResourceError(WebResourceError error) {
    final rawUrl = error.url ?? '';
    final host = Uri.tryParse(rawUrl)?.host ?? '(未知主机)';
    final cert = _looksLikeCertError(error);
    debugPrint('[login] 主框架加载失败 code=${error.errorCode} '
        'type=${error.errorType?.name ?? '-'} host=$host '
        'cert=${cert ? 'yes' : 'no'} desc=${error.description}'
        '${cert ? ' → 疑似代理/VPN 中间人证书，建议关掉代理/VPN 后重试' : ''}');
  }

  /// 是否像"证书校验失败"：Android 侧 HTTP 明确的 `ERR_CERT_AUTHORITY_INVALID`
  /// 是 `-202`，`errorType` 给出 `failedSslHandshake` 时同理（真机取证里
  /// 系统日志打的就是 `Failed to validate the certificate chain` + `net_error -202`）。
  ///
  /// ⚠️ 检测到证书错误时**只提示、不放行**：登录要输入手机号与验证码，放行
  /// 一个中间人证书等于把账号交出去。这里给的是"检查代理 / VPN"的操作建议。
  static bool _looksLikeCertError(WebResourceError error) =>
      error.errorType == WebResourceErrorType.failedSslHandshake ||
      error.errorCode == -202;

  // -------------------------------------------------------------------------
  // 登录态检测与提取
  // -------------------------------------------------------------------------

  /// 读 WebView cookie，**经服务端校验通过**才算登录成功；成功才提取登录态落盘返回。
  ///
  /// ★ v2.49.1+ 的核心修复：校验必须由服务端下结论。
  ///
  /// 为什么（2026-09-22 真机取证）：WebView cookie jar 里残留的**死会话**
  /// （服务端早已作废的旧 cookie）和有效会话长得一模一样，本地什么都看不出来。
  /// 老代码"读到 SESSDATA 即宣布成功"会走成这样一条死循环：
  /// 弹「登录成功」→ 落盘 → `pop(true)` → 收藏夹重载 → 服务端 -101 →
  /// 「登录已失效，请重新登录」→ 点「去登录」→ 又读到同一份残留 cookie →
  /// 又弹「登录成功」……真机截图里「登录已失效」与「登录成功」同时出现在
  /// 一屏上，就是这么来的。
  ///
  /// 现在只有 [SessionVerifyStatus.ok]（`nav` 返回 `code == 0` 且
  /// `data.isLogin == true`）才落盘 + 提示 + pop；其余一律**不落盘、不 pop、
  /// 不报成功**，留在登录页说明原因（见 [_handleVerifyFailure]）。
  ///
  /// [force]：用户点「重新校验」时为 true，绕过"这份 SESSDATA 已处理过"的
  /// 去重（否则同一份 cookie 永远不会被重试）。
  Future<void> _checkLogin({bool force = false}) async {
    // 校验已通过、只是写盘失败 → 只重试写盘（不重新打服务端）
    if (_pendingSave != null) return _retryPendingSave();
    if (_verifying) return; // 校验在途：1 秒轮询别叠加请求

    String cookies;
    try {
      cookies = await WebLoginCookies.read();
    } catch (_) {
      return; // 原生通道未就绪（如测试环境），静默等待
    }
    if (cookies.isEmpty) return;

    // 与「粘贴 Cookie 登录」共用同一套容错解析（顺序任意、大小写、换行…）
    final creds = parseBiliCookieCreds(cookies);
    final sessdata = creds.sessdata;
    if (sessdata == null || sessdata.isEmpty) return; // 还没登录成功
    if (!force && sessdata == _handledSessdata) return; // 这份已处理过（避免每秒重验）

    _verifying = true;
    _handledSessdata = sessdata;
    _pollTimer?.cancel();
    try {
      final result = await _api.verifySession(
        sessdata: sessdata,
        biliJct: creds.biliJct,
      );
      if (!mounted) return;
      if (!result.passed) {
        _handleVerifyFailure(result, sessdata);
        return;
      }
      final refreshToken = creds.refreshToken ?? await _extractRefreshToken();
      try {
        await _api.saveSession(
          sessdata: sessdata,
          biliJct: creds.biliJct ?? '',
          refreshToken: refreshToken ?? '',
        );
      } catch (e) {
        // 保存失败（如 secure storage 底层异常）：绝不能让本次登录静默丢失——
        // 挂成"待写入"，由每秒轮询重试写盘；WebView 里的登录态还在，重试通常
        // 一次即成功。不弹"登录成功"。但**必须让用户看见**（v2.49.1+）：
        // 旧代码只 debugPrint，真机上表现为"登录页一动不动、像卡死"。
        debugPrint('[login] saveSession FAILED, will retry: ${e.runtimeType}');
        _pendingSave = _PendingLogin(
          sessdata: sessdata,
          biliJct: creds.biliJct ?? '',
          refreshToken: refreshToken ?? '',
        );
        if (mounted) {
          setState(() => _notice = const _LoginNotice(
              '服务端已确认登录，但保存登录态失败，正在自动重试…（若一直失败请返回后重进本页）'));
        }
        _ensurePolling();
        return;
      }
      _finishLoginOk();
    } finally {
      _verifying = false;
    }
  }

  /// 服务端说没通过：**不落盘、不 pop、不报成功**，留在登录页说明原因。
  ///
  /// - [SessionVerifyStatus.invalid]（-101 / 服务端当匿名处理）：这份 cookie 已被
  ///   作废。顺手把 WebView 里这份**死 cookie 清掉并重载**——不清的话它一直躺在
  ///   cookie jar 里，用户重新登录时会持续读到旧值，而且 B 站自家页面也可能
  ///   因为这份 cookie 表现异常（看着像"已登录"却处处 -101）。
  /// - [SessionVerifyStatus.network] / [SessionVerifyStatus.rejected]：**结论未知**。
  ///   按本版口径一律**不给假成功**（不落盘、不 pop）：网络抖动时保存一份
  ///   "看起来对"的会话，换来的正是这次要修掉的那种死循环；宁可让用户点一次
  ///   「重新校验」。文案里说清是网络/服务端问题，并给重试入口。
  ///
  /// 两条路径都要**把轮询重新挂上**：校验开始时轮询被停掉了，而"校验没过"之后
  /// 用户还会在这个页面里继续登录——只有轮询在跑，新出现的 SESSDATA 才会被发现
  /// （登录成功后不一定触发 onPageFinished，见 `initState` 的说明）。
  void _handleVerifyFailure(SessionVerifyResult result, String sessdata) {
    debugPrint('[login] 服务端校验未通过 status=${result.status.name} '
        'code=${result.code} → 不保存、不返回');
    if (result.status != SessionVerifyStatus.invalid) {
      final text = result.status == SessionVerifyStatus.network
          ? '无法确认登录状态（网络原因：${result.message}）。'
              '为稳妥起见没有保存，请检查网络后点「重新校验」。'
          : '无法确认登录状态（服务端返回 ${result.code}：${result.message}）。'
              '为稳妥起见没有保存，请稍后点「重新校验」。';
      setState(() => _notice = _LoginNotice(
            text,
            actionLabel: '重新校验',
            onAction: _recheck,
          ));
      _ensurePolling();
      return;
    }
    setState(() => _notice = const _LoginNotice(
        '这份登录状态服务端不认（-101：已失效或已在别处退出登录），已放弃保存并清除本机这份残留，请重新完成登录。'));
    _ensurePolling();
    unawaited(_clearDeadCookiesAndReload());
  }

  /// 保证"每秒查一次登录态"的轮询在跑（[Timer.cancel] 后 `_pollTimer` 不为 null，
  /// 所以不能只用 `??=` 判断——要看 [Timer.isActive]）。
  void _ensurePolling() {
    final timer = _pollTimer;
    if (timer != null && timer.isActive) return;
    _pollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _checkLogin());
  }

  /// 用户点「重新校验」：清掉去重标记后重新走一次服务端校验。
  void _recheck() {
    if (!mounted) return;
    setState(() => _notice = null);
    _handledSessdata = null;
    unawaited(_checkLogin(force: true));
  }

  /// 清掉 WebView 里那份服务端不认的 cookie，并把登录页重新载入。
  ///
  /// 重载的理由：cookie jar 刚被我们清空，页面上那份"看着像已登录"的状态已经
  /// 与 jar 不一致（B 站页面可能据此停在奇怪的位置），重载一次回到干净的登录表单。
  /// 只在服务端明确判没时调用（见 [_handleVerifyFailure]），且同一份 SESSDATA
  /// 只会走到这里一次（[_handledSessdata] 去重）→ 不会重载循环。
  Future<void> _clearDeadCookiesAndReload() async {
    try {
      await WebLoginCookies.clear();
      debugPrint('[login] 已清空 WebView cookie（服务端不认的那份）');
    } catch (e) {
      // 清不掉就别重载：否则页面重载后 cookie 还在，看起来"什么都没发生"
      debugPrint('[login] 清空 WebView cookie 失败，跳过重载：${e.runtimeType}');
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    try {
      _startWatchdog();
      await controller.reload();
    } catch (e) {
      debugPrint('[login] 清 cookie 后重载失败：${e.runtimeType}');
    }
  }

  /// 写盘重试（[ _pendingSave ] 非空时由每秒轮询调用）。
  Future<void> _retryPendingSave() async {
    final pending = _pendingSave;
    if (pending == null || _verifying) return;
    _verifying = true;
    try {
      await _api.saveSession(
        sessdata: pending.sessdata,
        biliJct: pending.biliJct,
        refreshToken: pending.refreshToken,
      );
      _pendingSave = null;
      _pollTimer?.cancel();
      _finishLoginOk();
    } catch (e) {
      debugPrint('[login] saveSession 重试仍失败：${e.runtimeType}');
    } finally {
      _verifying = false;
    }
  }

  /// 登录成立后的收尾：提示 + 返回上一页（两个成功路径共用）。
  void _finishLoginOk() {
    if (!mounted) return;
    debugPrint('[login] 服务端校验通过 → 已保存登录态，返回上一页');
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
    final theme = Theme.of(context);
    final banner = widget.banner;
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
      body: Column(
        children: [
          // 自动登录引导提示条（手动打开登录页时无 banner 不显示）
          if (banner != null && banner.isNotEmpty)
            MaterialBanner(
              content: Text(banner, style: theme.textTheme.bodySmall),
              leading: Icon(
                Icons.info_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              actions: const [SizedBox.shrink()],
              backgroundColor: theme.colorScheme.secondaryContainer,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              dividerColor: Colors.transparent,
            ),
          // 需要告知用户的失败（原生 cookie 通道不可用 / 服务端不认这份登录状态 /
          // 校验通过但写盘失败正在重试）：旧代码这些只 debugPrint，真机上完全
          // 不可见——用户看到的是"登录了却没反应"（v2.49.1+）。用页面内提示条，
          // 不弹窗（不打断 WebView 里的登录操作）。
          if (_notice != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _notice!.text,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                        // 可行动作（如「重新校验」）：失败必须给出下一步，
                        // 否则用户只能干等轮询（这一版之前正是如此）
                        if (_notice!.actionLabel != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _notice!.onAction,
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    theme.colorScheme.onErrorContainer,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4),
                                minimumSize: const Size(0, 32),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(_notice!.actionLabel!),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            // WebView 就绪前那一块 = "整块等待"：走印刷语言的指示器
            // （`AppLoadingView` = 三颗方点），不再用 Material 转圈
            // （AppBar 底下那条 `LinearProgressIndicator` 是 WebView 自己的
            // 加载进度，属"有确定进度的等待"，保留）。
            //
            // ⚠️ WebView 初始化失败（[_initError]）时**不能**再停在方点上：
            // 那看起来和"正在加载"一模一样，用户只会以为卡死（v2.49.1+ 改为
            // 明确错误态 + 重试）。
            //
            // 错误态给**两个**出口：「重试」= 重新加载（网络抖一下就好）；
            // 「清除网页数据后重试」= 清 cookie / Web Storage / HTTP 缓存后
            // **重建** WebView（渲染进程反复崩溃、profile 疑似损坏时才需要）。
            child: _initError != null
                ? SingleChildScrollView(
                    // 错误正文 + 两个出口可能超出一屏（真机小屏也会）→ 可滚动，
                    // 而不是让 Column 溢出（溢出会把底部按钮裁掉、用户点不到）
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      children: [
                        AppErrorView(
                          message: _initError,
                          subtitle: _initErrorIsCert
                              ? '证书校验失败时无法安全登录：请检查是否开着代理 / VPN，'
                                  '关掉后点「重试」。App 不会为了"能加载"而放行无效证书。'
                              : '登录页没能加载出来（系统 WebView 组件异常时会这样）。'
                                  '点「重试」再加载一次；反复失败可点下面的'
                                  '「清除网页数据后重试」，或返回后重进本页。',
                          onRetry: _retryInit,
                          illustrationSeed: 'login',
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _clearingWebData
                                  ? null
                                  : _clearWebDataAndRetry,
                              icon: const Icon(Icons.delete_sweep_outlined,
                                  size: 18),
                              label: Text(_clearingWebData
                                  ? '正在清除…'
                                  : '清除网页数据后重试'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : controller == null
                    ? const AppLoadingView()
                    : WebViewWidget(controller: controller),
          ),
        ],
      ),
    );
  }
}

/// 服务端校验已通过、但写盘失败 → 挂起等待重试的那次登录（见 [_retryPendingSave]）。
class _PendingLogin {
  final String sessdata;
  final String biliJct;
  final String refreshToken;

  const _PendingLogin({
    required this.sessdata,
    required this.biliJct,
    required this.refreshToken,
  });
}
