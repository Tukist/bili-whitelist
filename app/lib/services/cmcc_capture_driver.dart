/// 掌厅抓取的**页面驱动**抽象 + WebView 实现（v2.54.0）。
///
/// 为什么单独抽一层：抓取逻辑（C→B→D 降级、8 秒等待、3 次重试、退避）全部写在
/// `lib/pages/cmcc_page.dart` 里，而**那些逻辑必须能测**——`flutter_test` 环境
/// 没有 WebView 平台实现（`WebViewController()` 构造即抛），所以页面只依赖
/// [CmccCaptureDriver] 这个接口，测试注入替身即可完整走一遍降级链。
///
/// 真实现 [CmccWebViewDriver] 用工程既有的 `webview_flutter`（**不新增依赖**），
/// 负责：建 controller、装 JS 通道、在 `onPageStarted`/`onPageFinished` 注入
/// 钩子脚本、点「点击刷新」、读可见文字。
/// ⚠️ `webview_flutter` 没有 document-start 注入，注入时机的限制与应对写在
/// `cmcc_hook_script.dart` 的文件头（那段是这条路线最脆弱的地方，必须看）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'cmcc_hook_script.dart';

/// 掌厅页面专用的移动 UA（页面按 UA 渲染，移动版才是"手机号+验证码"入口）。
///
/// ⚠️ 只作用于掌厅这个 WebView，不动 API 层的 `kBrowserUA`（防盗链必需），
/// 也不动 B 站登录页用的 `kLoginMobileUA`。
const String kCmccMobileUA = 'Mozilla/5.0 (Linux; Android 13; Pixel 7 '
    'Build/TQ3A.230805.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Version/4.0 Chrome/126.0.0.0 Mobile Safari/537.36';

/// 页面级回调（页面把状态机挂在这上面）。
///
/// 只留两个：**注入脚本由驱动自己在 `onPageStarted`/`onPageFinished` 做**
/// （页面不需要知道注入时机这种细节），页面只关心"加载完了"和"加载坏了"。
class CmccPageBindings {
  /// 主框架加载完成（注入已完成；页面据此推进状态机 + 读文字）。
  final void Function() onPageFinished;

  /// 加载失败 / WebView 组件异常（给用户一句可读的话）。
  final void Function(String reason) onLoadError;

  const CmccPageBindings({
    required this.onPageFinished,
    required this.onLoadError,
  });
}

/// 抓取驱动接口（真实现 = [CmccWebViewDriver]；测试 = 自造替身）。
abstract class CmccCaptureDriver {
  /// 真实 WebView 的 controller（替身为 null → 页面显示占位说明，不建 WebView）。
  WebViewController? get controller;

  /// 绑定页面回调（必须在 [start] 之前调用）。
  void bind(CmccPageBindings bindings);

  /// 建 WebView / 准备替身，并加载 [url]。
  Future<void> start(String url);

  /// 重新加载当前页（第 2/3 次抓取尝试用）。
  Future<void> reload();

  /// 让页面把可见文字经通道回传（B 路线）。
  Future<void> requestText();

  /// 点页面里的「点击刷新」（白名单内的文案；见 `cmcc_hook_script.dart`）。
  Future<void> pokeRefresh();

  /// 读登录页 `#phone` 输入框的**值**（只读，绝不代填）；取不到 → null。
  Future<String?> readPhoneField();

  /// 注入的钩子脚本是否已生效。
  Future<bool> hookInstalled();

  /// 释放（页面 dispose 时调）。
  void dispose();
}

/// WebView 真实现（`webview_flutter`）。
class CmccWebViewDriver implements CmccCaptureDriver {
  /// 通道消息（原始字符串）交给页面解析。
  final void Function(String raw) onHook;

  CmccPageBindings? _bindings;
  WebViewController? _controller;

  /// 每个文档注入一次（onPageStarted 与 onPageFinished 各来一次，脚本幂等）。
  int _injectTimes = 0;

  CmccWebViewDriver({required this.onHook});

  @override
  WebViewController? get controller => _controller;

  @override
  void bind(CmccPageBindings bindings) => _bindings = bindings;

  @override
  Future<void> start(String url) async {
    final c = WebViewController()
      // JS 必须开：滑块风控要跑 JS，注入钩子也要跑 JS
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kCmccMobileUA)
      ..addJavaScriptChannel(
        kCmccChannel,
        onMessageReceived: (msg) => onHook(msg.message),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (_) {},
        // 只放行 http/https（掌厅会跳自己的域、滑块可能来自第三方域）
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme;
          return (scheme == 'http' || scheme == 'https')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageStarted: (_) {
          // 第一注入时机：这时塞进去的脚本**可能随旧文档一起丢掉**，所以
          // onPageFinished 还会再塞一次（并在塞完后点「点击刷新」逼页面重发请求）。
          // ⚠️ webview_flutter 没有 document-start 注入，这是本路线最脆弱的一环，
          // 降级链（B/D）就是为它准备的，见 `cmcc_hook_script.dart` 文件头。
          unawaited(_inject());
        },
        onPageFinished: (_) {
          // 先确保脚本装好了再通知页面（页面一收到就会点「点击刷新」，
          // 顺序反了那一下点击就白点了）
          unawaited(_finishInject());
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false) return;
          _bindings?.onLoadError('页面加载失败（${error.errorCode}）：'
              '${error.description}');
        },
      ));
    _controller = c;
    await c.loadRequest(Uri.parse(url));
  }

  /// 注入钩子脚本（幂等；失败不抛——注入失败会由降级链兜住）。
  Future<void> _inject() async {
    final c = _controller;
    if (c == null) return;
    if (_injectTimes > 20) return; // 单页最多注 20 次，不做无限注入
    _injectTimes++;
    try {
      await c.runJavaScript(buildCmccHookScript());
    } catch (e) {
      // 忽略（onPageFinished 还有第二次机会 + B/D 降级兜住），但要留日志：
      // 真机上"钩不到"和"注入失败"要能分辨
      debugPrint('[cmcc] 注入脚本失败（第 $_injectTimes 次）：${e.runtimeType}');
    }
  }

  /// 注入完成后再通知页面（顺序不能反，见 onPageFinished 里的说明）。
  Future<void> _finishInject() async {
    await _inject();
    _bindings?.onPageFinished();
  }

  @override
  Future<void> reload() async {
    _injectTimes = 0;
    try {
      await _controller?.reload();
    } catch (_) {}
  }

  @override
  Future<void> requestText() async {
    // 走通道回传（比 runJavaScriptReturningResult 更省心：不用解引号转义）
    try {
      await _controller?.runJavaScript(buildCmccTextScript());
    } catch (_) {
      // 忽略：调用方有超时，超时就按"这次没读到文字"降级
    }
  }

  @override
  Future<void> pokeRefresh() async {
    try {
      await _controller?.runJavaScript(buildCmccPokeScript());
    } catch (_) {}
  }

  /// 读登录页 `#phone` 输入框的**值**（只读；页面没这个元素就给空串）。
  ///
  /// 明确一下边界：这是**读**，不是填。App 不代填手机号/验证码，也不点登录按钮
  /// ——风控面前自动填表只会让用户更容易被拦，而且那等于替用户做了登录这件事。
  @override
  Future<String?> readPhoneField() async {
    final c = _controller;
    if (c == null) return null;
    try {
      final raw = await c.runJavaScriptReturningResult('''
(function(){
  var e = document.querySelector('#phone');
  if (!e) { return ''; }
  return String(e.value || '');
})();
''');
      return decodeJsString(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hookInstalled() async {
    final c = _controller;
    if (c == null) return false;
    try {
      final raw = await c.runJavaScriptReturningResult(buildCmccProbeScript());
      return decodeJsString(raw).trim() == 'true';
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    // WebViewController 没有 dispose；页面销毁时把引用放掉即可。
    _controller = null;
    _bindings = null;
  }
}
