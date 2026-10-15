/// 掌厅页面的 **JS 注入脚本 + 回传消息解析**（v2.54.0，路线 C 的实现）。
///
/// ## 注入脚本干什么
///
/// 在 WebView 里钩住 `fetch` 与 `XMLHttpRequest`，只在 URL 命中
/// [kCmccWantedApis] 时把**原始响应体**通过 JS 通道回传给 Dart（解密与解析都在
/// Dart 侧做，见 `cmcc_plan.dart`）。好处：**不用自己维护接口 URL**——页面自己
/// 会调，改路径/加参数都不用动 App。
///
/// ## ⚠️ 注入时机（现有依赖的硬限制，必须写在代码里）
///
/// 工程用的是 `webview_flutter`（4.13.1 / android 4.10.1）。它**不提供
/// document-start 注入**（没有 `addDocumentStartJavaScript` 这类能力；那个口子
/// 在 `flutter_inappwebview` 里，本版**不新增依赖**）。所以脚本只能在
/// `onPageStarted` / `onPageFinished` 里用 `runJavaScript` 塞进去，存在两个风险：
/// 1. `onPageStarted` 时文档可能正在被替换，塞进去的脚本**可能随旧文档一起丢**；
/// 2. 页面若在"脚本注入之前"就把余量接口调完了，那次响应就**钩不到**。
///
/// 应对（不指望时机完美，而是让它**必然**再发生一次）：
/// - `onPageStarted` 与 `onPageFinished` **各注入一次**（脚本幂等）；
/// - 注入后调 [kCmccPokeFunction]（`__amoTvCmccPoke`）**点一下页面里的"点击
///   刷新"**——掌厅的数据要用户点一下才出，这一下点击会让页面**重新发一次
///   余量请求**，此时钩子已经就位 → 响应必被回传；
/// - `onPageFinished` 之后再读一次 `document.body.innerText` 作 B 路线兜底，
///   即便 C 完全失手也还有 B/D。
///
/// ## 🚫 绝不自动重发短信验证码（这是安全红线，不是可选项）
///
/// 掌厅的短信验证码下发**有限流**，自动重发等于拿用户号段去撞风控。所以注入
/// 脚本**只允许点白名单文案**（[kCmccPokeTexts]：刷新类），并且**先过黑名单**
/// （[kCmccForbiddenPokeTexts]：获取验证码 / 发送验证码 / 重发 / 登录 / 退出 …，
/// 见 [cmccMayClickText]）。黑名单与白名单**都是这里的常量**，脚本由它们拼出来
/// ——测试可以断言"这两个表进了脚本""判定真的拦得住"，而不是只看注释。
///
/// 另外：App **不代填手机号、不代填验证码、不代点登录按钮**——登录必须用户
/// 自己在页面里完成（风控面前自动填表只会更容易被拦）。
library;

import 'dart:convert';

import 'cmcc_plan.dart';

/// JS 通道名（与 `WebViewController.addJavaScriptChannel` 注册的一致）。
const String kCmccChannel = 'CmccHook';

/// 脚本安装标记（幂等用；也是"注入是否成功"的探测点）。
const String kCmccHookMarker = '__amoTvCmccHook';

/// 点刷新用的函数名（注入脚本暴露给 Dart 调）。
const String kCmccPokeFunction = '__amoTvCmccPoke';

/// 让页面把可见文字回传的函数名。
const String kCmccTextFunction = '__amoTvCmccText';

/// **允许点击**的页面文案（白名单；只认刷新类）。
const List<String> kCmccPokeTexts = ['点击刷新', '刷新', '重新加载', '重新刷新'];

/// **禁止点击**的页面文案（黑名单；先过这个再看白名单）。
///
/// 每一条都是"点了会出事"的：验证码会触发限流、登录/退出会改账号状态。
const List<String> kCmccForbiddenPokeTexts = [
  '获取验证码',
  '发送验证码',
  '重新获取',
  '重发',
  '发送短信',
  '登录',
  '退出',
  '注销',
  '切换账号',
  '注销账号',
  '解绑',
];

/// 某个页面文案**允不允许**被脚本点击（纯函数，测试直接钉）。
///
/// 规则：去空白 → 空串否 → 命中任一黑名单词否 → 命中白名单词才是真。
bool cmccMayClickText(String label) {
  final t = label.replaceAll(RegExp(r'\s+'), '');
  if (t.isEmpty) return false;
  for (final deny in kCmccForbiddenPokeTexts) {
    if (t.contains(deny)) return false;
  }
  for (final allow in kCmccPokeTexts) {
    if (t.contains(allow)) return true;
  }
  return false;
}

/// 生成注入脚本（**幂等**：重复注入只刷新 poke/取文字这两个函数）。
///
/// 返回 JS 源码；用 `runJavaScript` 执行。脚本里不用 `$` 插值字符，避免与
/// Dart 的字符串插值打架。
String buildCmccHookScript() {
  final want = jsonEncode(kCmccWantedApis);
  final allow = jsonEncode(kCmccPokeTexts);
  final deny = jsonEncode(kCmccForbiddenPokeTexts);
  final channel = jsonEncode(kCmccChannel);
  return '''
(function(){
  var CH = $channel;
  var WANT = $want;
  var ALLOW = $allow;
  var DENY = $deny;
  function post(o){
    try {
      if (window[CH] && window[CH].postMessage) {
        window[CH].postMessage(JSON.stringify(o));
      }
    } catch (e) {}
  }
  function hit(u){
    u = String(u || '');
    for (var i = 0; i < WANT.length; i++) {
      if (u.indexOf(WANT[i]) >= 0) { return WANT[i]; }
    }
    return null;
  }
  function urlOf(a){
    try {
      if (!a) { return ''; }
      if (typeof a === 'string') { return a; }
      if (a.url) { return a.url; }
      return String(a);
    } catch (e) { return ''; }
  }
  function isDenied(t){
    for (var i = 0; i < DENY.length; i++) {
      if (t.indexOf(DENY[i]) >= 0) { return true; }
    }
    return false;
  }
  function isAllowed(t){
    t = (t || '').replace(/\\s+/g, '');
    if (!t) { return false; }
    if (isDenied(t)) { return false; }
    for (var i = 0; i < ALLOW.length; i++) {
      if (t.indexOf(ALLOW[i]) >= 0) { return true; }
    }
    return false;
  }
  var textOf = function(){
    try {
      var b = document.body ? (document.body.innerText || document.body.textContent) : '';
      if (!b) { b = document.documentElement ? document.documentElement.innerText : ''; }
      return b || '';
    } catch (e) { return ''; }
  };
  var poke = function(){
    var n = 0;
    try {
      var all = document.querySelectorAll('div,span,a,button,p,li,label');
      for (var i = 0; i < all.length && n < 3; i++) {
        var t = (all[i].innerText || '').trim();
        if (!t || t.length > 12) { continue; }
        if (!isAllowed(t)) { continue; }
        try { all[i].click(); n++; } catch (e) {}
      }
    } catch (e) {}
    return n;
  };
  var sendText = function(){
    post({kind: 'text', text: textOf()});
    return true;
  };
  window.__amoTvCmccPoke = poke;
  window.__amoTvCmccText = sendText;
  if (window.$kCmccHookMarker) { return 'already'; }
  window.$kCmccHookMarker = true;
  var of = window.fetch;
  if (of) {
    window.fetch = function(){
      var api = hit(urlOf(arguments[0]));
      var p = of.apply(this, arguments);
      if (!api) { return p; }
      try {
        p.then(function(r){
          try {
            r.clone().text().then(function(t){
              post({kind: 'response', api: api, body: t || ''});
            });
          } catch (e) {}
          return r;
        });
      } catch (e) {}
      return p;
    };
  }
  var oo = XMLHttpRequest.prototype.open;
  var os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(m, u){
    try { this.__amoApi = hit(u); } catch (e) {}
    return oo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(){
    try {
      var self = this;
      if (self.__amoApi) {
        self.addEventListener('load', function(){
          var t = '';
          try { t = self.responseText || ''; } catch (e) {
            try { t = JSON.stringify(self.response); } catch (e2) { t = ''; }
          }
          post({kind: 'response', api: self.__amoApi, body: t});
        });
      }
    } catch (e) {}
    return os.apply(this, arguments);
  };
  return 'installed';
})();
''';
}

/// 探测脚本是否已装（Dart 侧用它确认"注入成功"，好给用户一句准确的话）。
String buildCmccProbeScript() =>
    '!!window.$kCmccHookMarker';

/// 读页面可见文字的表达式（`runJavaScriptReturningResult` 用）。
String buildCmccTextScript() => 'window.$kCmccTextFunction();';

/// 调"点刷新"的表达式。
String buildCmccPokeScript() => 'window.$kCmccPokeFunction();';

/// 回传消息的种类。
enum CmccHookKind {
  /// 接口响应（原始 body）。
  response,

  /// 页面可见文字。
  text,
}

/// 一条回传消息（Dart 侧解析后的形态）。
class CmccHookMessage {
  final CmccHookKind kind;

  /// 命中的接口名（[CmccHookKind.response] 才有）。
  final String? api;

  /// 响应原始 body（未解密）。
  final String? body;

  /// 页面文字（[CmccHookKind.text] 才有）。
  final String? text;

  const CmccHookMessage({
    required this.kind,
    this.api,
    this.body,
    this.text,
  });

  /// 这条响应是不是我们要的那几个接口之一。
  bool get isWantedApi => api != null && kCmccWantedApis.contains(api);

  /// 响应体为空（钩子钩到了，但页面没给内容）。
  bool get isEmptyBody => (body ?? '').trim().isEmpty;

  @override
  String toString() => 'CmccHookMessage($kind, api=$api, '
      'body=${body?.length ?? 0}B, text=${text?.length ?? 0}B)';
}

/// 解析一条通道消息；不是我们认识的形状 → null（静默丢弃，不抛）。
CmccHookMessage? parseHookMessage(String raw) {
  final s = raw.trim();
  if (s.isEmpty || s.length > 2000000) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(s);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final kind = decoded['kind'];
  if (kind == 'response') {
    final api = decoded['api'];
    final body = decoded['body'];
    if (api is! String || api.isEmpty) return null;
    return CmccHookMessage(
      kind: CmccHookKind.response,
      api: api,
      body: body is String ? body : '',
    );
  }
  if (kind == 'text') {
    final text = decoded['text'];
    return CmccHookMessage(
      kind: CmccHookKind.text,
      text: text is String ? text : '',
    );
  }
  return null;
}

/// `runJavaScriptReturningResult` 的返回值解包（Android 侧会多包一层引号/转义）。
///
/// 与 `login_page.dart` 里那份同类处理同一套规矩：字符串结果被 JSON 编码过，
/// 解不出来就原样返回（宁可给用户一段带引号的文字，也不要抛异常）。
String decodeJsString(Object? raw) {
  if (raw == null) return '';
  final s = raw.toString();
  if (s.isEmpty) return '';
  try {
    final decoded = jsonDecode(s);
    if (decoded is String) return decoded;
    if (decoded is num || decoded is bool) return decoded.toString();
    return s;
  } catch (_) {
    return s;
  }
}
