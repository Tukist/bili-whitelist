/// 规则引擎：把「抓网页 + 在真实 DOM 上跑选择器」抽成可替换的接口（R2 新增）。
///
/// ## 为什么必须是抽象接口
/// `flutter_test` 环境**没有 WebView 平台实现**（`WebViewController()`
/// 构造即抛），而搜索编排（并发、超时、去重、合并）恰恰是最需要单测的部分。
/// 所以页面/服务只依赖 [BookRuleEngine]，测试注入 [FakeRuleEngine] 就能把
/// 「4 个源并发、其中一个抛错、整体不崩」这类逻辑跑一遍。
///
/// ## 真实现为什么用 WebView 而不是自己解析 HTML
/// 书源规则是**浏览器语义**的：CSS 相对查询、XPath、`innerText`（可见文本）、
/// 相对链接转绝对。Dart 侧没有这些能力（也没有 XPath 库，且本项目**不引新
/// 依赖**），所以借 WebView 当执行器，结构照抄工程里已跑熟的
/// `CmccWebViewDriver`（`services/cmcc_capture_driver.dart`）：
/// 隐藏 controller + 导航回调 + 超时兜底。差别是这里不注入钩子脚本，
/// 而是每次求值后自己拼一段 JS（见 `js_builder.dart`）。
///
/// ## 串行求值（性能取舍得说清楚）
/// 一个引擎实例只有**一个** WebView，所以同一时刻只允许一次求值往返：两个
/// 求值交错会把彼此的页面顶掉（`loadHtmlString` 是异步的，A 刚载完 B 又载，
/// A 的 `onPageFinished` 回来时 DOM 已经是 B 的了）。因此所有求值走
/// [_serial] 排队。代价：N 个字段要 N 次往返；缓解办法是
/// [queryFieldMap] 一次取完所有列（[WebViewRuleEngine] 覆写成单次 JS）。
///
/// ## GBK 的诚实口径
/// 全项目零 GBK 处理，`dart:convert` 也没有 GBK。所以声明 `gbk` 的源**照
/// UTF-8 强解**（`allowMalformed: true`，不崩、不出异常），并把
/// 「疑似乱码」写进 [lastDecodeWarning] 由 UI 提示。宁可给用户一堆乱码 +
/// 一句实话，也不要假装成功。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'js_builder.dart';
import 'selector.dart';

/// 抓网页用的桌面 Chrome UA。
///
/// 为什么用桌面 UA：手机 UA 会拿到移动版页面（结构常常和书源规则写的那套
/// 不一样，规则匹配率暴跌），书源作者基本都按桌面版页面写规则。
const String kRuleDesktopUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 求值等待页面加载的超时。
const Duration kRulePageTimeout = Duration(seconds: 8);

/// 抓网页的超时。
const Duration kRuleFetchTimeout = Duration(seconds: 15);

/// 失败大类（UI 按这个分组显示，message 才是给人看的那句话）。
enum RuleErrorKind {
  /// 网络层：连不上、DNS、4xx/5xx、证书。
  network,

  /// 超时。
  timeout,

  /// 规则不支持（JS 规则 / 语法不认识）。
  unsupported,

  /// 拿到的内容为空 / 解析不出东西。
  empty,
}

/// 引擎失败：**永远带一句中文人话**，不让 DioException 之类冒到 UI。
class RuleEngineException implements Exception {
  final RuleErrorKind kind;

  /// 给人看的一句话（可以直接塞进 SnackBar / 分组说明）。
  final String message;

  /// HTTP 状态码（只有「站点返回了非 2xx」时才有值，其余为 null）。
  ///
  /// 为什么单独带出来而不是只写在 [message] 里：书源可用性检测要把
  /// 403 / 429 / 412 判成「被拦」、超时判成「连不上」—— 去 `message` 里
  /// 用正则抠数字既脆又难测。空值时调用方按 [kind] 兜底。
  final int? statusCode;

  const RuleEngineException(this.kind, this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// 规则引擎接口。
abstract class BookRuleEngine {
  /// 最近一次 [fetchHtml] 的解码告警（GBK 源按 UTF-8 强解的提示）；无告警为 null。
  ///
  /// 为什么挂在实例上而不是返回值里：接口签名由调用方定死（改签名会牵连
  /// 搜索服务的错误分类），而解码告警是**提示性**信息，副作用式带出最省事。
  String? lastDecodeWarning;

  /// 抓网页正文。
  ///
  /// [charset] 只支持 `utf-8` / `gbk`（后者降级为 UTF-8 强解，见文件头）。
  /// 失败抛 [RuleEngineException]（网络 / 超时 / 空内容）。
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String charset = 'utf-8',
  });

  /// 在 [html]（以 [baseUrl] 为基准）里，对 [listSelector] 命中的每个节点，
  /// 用 [fieldSelector]（相对节点）取值，返回按节点顺序的字符串列表
  /// （取不到的位置是 null）。
  ///
  /// [fieldSelector] 为 null 时取列表节点自身（用列表规则的取值后缀）。
  Future<List<String?>> queryFields({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required SelectorValue? fieldSelector,
  });

  /// 一次取多列（搜索结果页要 6 个字段，逐字段往返会慢 6 倍）。
  ///
  /// 默认实现逐字段调 [queryFields]（对假引擎 / 简易实现够用）；
  /// [WebViewRuleEngine] 覆写成**单次**页面加载 + 单次 JS 往返。
  Future<Map<String, List<String?>>> queryFieldMap({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required Map<String, SelectorValue?> fields,
  }) async {
    final out = <String, List<String?>>{};
    for (final entry in fields.entries) {
      out[entry.key] = await queryFields(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        fieldSelector: entry.value,
      );
    }
    return out;
  }

  /// 正文抽取：先删 [removeSelectors] 命中的节点，再取 [textSelector]
  /// 命中节点（没命中则整页 body）的**innerHTML**。
  ///
  /// 为什么返回值是 HTML 而不是纯文本：段落还原（`<br>` / 块级边界 → 换行）
  /// 放在 Dart 侧做纯函数（`restoreParagraphs`），才能被单测覆盖到每一种
  /// 策略；在 JS 里做就只能靠真机肉眼验。删节点与取内容必须在**同一次**
  /// 页面载入里完成（见 `buildExtractHtmlJs` 的注释）。
  ///
  /// 默认实现直接报「不支持」：只有 [WebViewRuleEngine] 有真实 DOM。
  Future<String> extractHtml({
    required String html,
    required String baseUrl,
    List<String> removeSelectors = const [],
    required SelectorValue textSelector,
  }) async {
    throw const RuleEngineException(
      RuleErrorKind.unsupported,
      '当前引擎不支持正文抽取（缺少 WebView）',
    );
  }

  /// 丢弃页面上正在等待的求值（**页面离开时调，不销毁引擎**）。
  ///
  /// 为什么不 dispose：真实现里一个引擎 = 一个 WebView，dispose 掉下一个
  /// 页面就得重建（慢、且新旧两个 WebView 会互相抢页面）。页面级取消只需要
  /// 「不再等这次结果」——默认空实现（假引擎 / 无副作用实现不需要做事）。
  void reset() {}

  /// 释放（WebView / Dio）。之后所有方法抛 [StateError]。
  Future<void> dispose();
}

/// 把 `<base href>` 注入 HTML 头部（求值前必须做）。
///
/// 为什么注入而不是只依赖 `loadHtmlString(baseUrl:)`：后者在部分 Android
/// WebView 版本上不会真正更新 `document.baseURI`，结果就是相对链接被解成
/// `about:blank` 下的相对路径 —— `new URL(v, document.baseURI)` 拿到一堆
/// 没有域名的假地址。自己塞一个 `<base>` 是确定有效的。
///
/// 注意：我们插在 `<head>` 的**最前面**，所以优先于页面自带的 `<base>`
/// （浏览器只认第一个）。这是有意的：相对链接应该按「我们抓它时的那个 URL」
/// 解析，而不是页面自己声明的（那可能指向 CDN / 镜像站）。
String injectBaseHref(String html, String baseUrl) {
  if (baseUrl.trim().isEmpty) return html;
  final tag = '<base href="${_escapeAttr(baseUrl.trim())}">';
  final lower = html.toLowerCase();

  final headAt = lower.indexOf('<head');
  if (headAt >= 0) {
    final headEnd = html.indexOf('>', headAt);
    if (headEnd > 0) {
      return '${html.substring(0, headEnd + 1)}$tag'
          '${html.substring(headEnd + 1)}';
    }
  }
  final htmlAt = lower.indexOf('<html');
  if (htmlAt >= 0) {
    final htmlEnd = html.indexOf('>', htmlAt);
    if (htmlEnd > 0) {
      return '${html.substring(0, htmlEnd + 1)}<head>$tag</head>'
          '${html.substring(htmlEnd + 1)}';
    }
  }
  // 既没有 <head> 也没有 <html>：整段当一个文档包起来
  return '<html><head>$tag</head><body>$html</body></html>';
}

String _escapeAttr(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');

/// WebView 实现：隐藏 controller 当执行器，Dio 负责抓网页。
///
/// 用法：调用方把 [buildHost] 返回的 widget 挂在 `Offstage` /
/// `SizedBox.shrink` 里（WebView 必须进 widget 树才会真正创建原生视图），
/// 然后调 [fetchHtml] / [queryFields]。
class WebViewRuleEngine extends BookRuleEngine {
  WebViewRuleEngine({WebViewController? controller, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: kRuleFetchTimeout,
              receiveTimeout: kRuleFetchTimeout,
              sendTimeout: kRuleFetchTimeout,
              followRedirects: true,
              maxRedirects: 8,
              // 抓网页要自己带响应头（部分站点靠 Accept 判机器），
              // 但**不要**带 B 站那套 Referer/Origin（见下）
              headers: const {
                'User-Agent': kRuleDesktopUA,
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'zh-CN,zh;q=0.9',
              },
            )) {
    // controller 在这里建（不能放初始化列表）：导航回调要写 [_pageDone]，
    // 静态方法碰不到实例字段
    _controller = controller ?? _buildController();
  }

  final Dio _dio;
  WebViewController? _controller;

  /// 串行队列尾（见文件头「串行求值」）。
  Future<void> _tail = Future<void>.value();

  /// 当前页的「加载完成」信号（每次求值换一个新的）。
  Completer<String>? _pageDone;

  bool _disposed = false;

  /// ⚠️ 这里刻意**新建**一个干净的 Dio：`BiliApi` 的 Dio 带 B 站定制的
  /// baseUrl / Referer / Cookie，拿它请求第三方站点既会带上不该带的凭据，
  /// 也会被站点当成盗链拒绝。
  /// 建 controller（实例方法：导航回调要写 [_pageDone]）。
  WebViewController _buildController() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kRuleDesktopUA)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          final done = _pageDone;
          if (done != null && !done.isCompleted) done.complete('ok');
        },
        onWebResourceError: (error) {
          // 只有主框架的失败才算「页面没加载出来」；图片/字体 404 不影响求值
          if (error.isForMainFrame == false) return;
          final done = _pageDone;
          if (done != null && !done.isCompleted) {
            done.completeError(RuleEngineException(
              RuleErrorKind.network,
              '页面加载失败（${error.errorCode}）：${error.description}',
            ));
          }
        },
        onNavigationRequest: (request) {
          // 只放行 http/https：`loadHtmlString` 自己不会跳，但页面里的
          // `location.href='intent://…'` / `tel:` 之类会把 WebView 交给系统
          final scheme = Uri.tryParse(request.url)?.scheme;
          return (scheme == 'http' || scheme == 'https')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ));
  }

  /// 给页面挂载用的 widget（调用方负责藏起来）。
  Widget buildHost() {
    _ensureAlive();
    return WebViewWidget(controller: _controller!);
  }

  /// 真 controller（调试 / 未来要给页面绑定进度时用）。
  WebViewController? get controller => _controller;

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String charset = 'utf-8',
  }) async {
    _ensureAlive();
    lastDecodeWarning = null;
    Response<List<int>> resp;
    try {
      resp = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            if (headers != null) ...headers,
          },
        ),
      );
    } on DioException catch (e) {
      throw RuleEngineException(
        RuleErrorKind.network,
        _humanDioError(e, url),
        // 4xx / 5xx 时 Dio 带上响应对象；连不上 / 超时没有状态码。
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      throw RuleEngineException(
        RuleErrorKind.network,
        '请求失败（${e.runtimeType}）：$url',
      );
    }

    final bytes = resp.data ?? const <int>[];
    if (bytes.isEmpty) {
      throw RuleEngineException(RuleErrorKind.empty, '站点返回了空内容：$url');
    }
    // 一律先按 UTF-8 强解（allowMalformed 保证不抛）。GBK 站点会是乱码，
    // 但**不会崩**，而且下面会把话说清楚。
    final text = utf8.decode(bytes, allowMalformed: true);
    final declared = charset.trim().toLowerCase();
    if (declared.isNotEmpty && declared != 'utf-8' && declared != 'utf8') {
      lastDecodeWarning = '该源声明编码为 $charset，本版按 UTF-8 强行解码，正文疑似乱码';
    } else if (text.contains('\uFFFD')) {
      // 声明 utf-8 但实际是别的编码（老站点常见）——强解的替换符就是证据
      lastDecodeWarning = '页面含无法解码的字符（疑似非 UTF-8 编码），部分文字可能是乱码';
    }
    return text;
  }

  @override
  Future<List<String?>> queryFields({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required SelectorValue? fieldSelector,
  }) async {
    _ensureAlive();
    _checkSelectors(listSelector, fieldSelector);
    final raw = await _serial(() async {
      final result = await _evalJs(
        html: html,
        baseUrl: baseUrl,
        js: buildQueryFieldsJs(listSelector, fieldSelector),
      );
      return result;
    });
    return _decodeValueList(raw);
  }

  @override
  Future<Map<String, List<String?>>> queryFieldMap({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required Map<String, SelectorValue?> fields,
  }) async {
    _ensureAlive();
    _checkSelectors(listSelector, null);
    if (fields.isEmpty) return const {};
    final raw = await _serial(() => _evalJs(
          html: html,
          baseUrl: baseUrl,
          js: buildQueryFieldsMultiJs(listSelector, fields),
        ));
    final decoded = _decodeJson(raw, '字段结果');
    if (decoded is! Map) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '页面返回的字段结果不是对象，可能页面结构与书源规则不符',
      );
    }
    final out = <String, List<String?>>{};
    for (final entry in fields.entries) {
      final list = decoded[entry.key];
      out[entry.key] = list is List
          ? [for (final v in list) v?.toString()]
          : List<String?>.filled(0, null);
    }
    return out;
  }

  @override
  Future<String> extractHtml({
    required String html,
    required String baseUrl,
    List<String> removeSelectors = const [],
    required SelectorValue textSelector,
  }) async {
    _ensureAlive();
    // 正文规则为空是「取整页」的合法写法（少数站点整页只有正文），
    // 但写了却不可执行（JS / 语法错）就必须说清楚，不能静默回空。
    if (!textSelector.isEmpty) _checkSelectors(textSelector, null);
    final raw = await _serial(() => _evalJs(
          html: html,
          baseUrl: baseUrl,
          js: buildExtractHtmlJs(
            removeSelectors: removeSelectors,
            textSelector: textSelector,
          ),
        ));
    final extracted = _unwrapJsString(raw);
    if (extracted.trim().isEmpty) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '正文是空的：正文规则可能没匹配到节点，或站点返回的是空页',
      );
    }
    return extracted;
  }

  @override
  void reset() {
    // 只把「正在等页面加载」的那次求值叫醒：不清 `_tail`，因为排队中的
    // 任务各自持有自己的 gate（`_serial` 的 finally 会放行下一个），
    // 硬清队列反而会让等待者永远挂住。
    final done = _pageDone;
    if (done != null && !done.isCompleted) {
      done.completeError(const RuleEngineException(
        RuleErrorKind.unsupported,
        '页面已离开，本次求值已取消',
      ));
    }
    _pageDone = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final done = _pageDone;
    if (done != null && !done.isCompleted) {
      done.completeError(StateError('规则引擎已释放'));
    }
    _pageDone = null;
    // WebViewController 没有 dispose；放掉引用即可（与 CmccWebViewDriver 同）
    _controller = null;
    _dio.close(force: true);
  }

  /// 串行化：等前一个求值结束再跑自己（见文件头「串行求值」）。
  Future<T> _serial<T>(Future<T> Function() body) async {
    final prev = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    try {
      await prev;
      return await body();
    } finally {
      gate.complete();
    }
  }

  /// 载入 HTML 并跑一段 JS，返回**原始**结果（未解包的 JS 值）。
  Future<Object?> _evalJs({
    required String html,
    required String baseUrl,
    required String js,
  }) async {
    _ensureAlive();
    if (html.trim().isEmpty) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '抓到的网页是空的：站点可能返回了空页或拦截了请求',
      );
    }
    final c = _controller;
    if (c == null) {
      throw const RuleEngineException(
        RuleErrorKind.unsupported,
        'WebView 不可用（引擎已释放）',
      );
    }
    final done = Completer<String>();
    _pageDone = done;
    try {
      await c.loadHtmlString(
        injectBaseHref(html, baseUrl),
        baseUrl: baseUrl.trim().isEmpty ? null : baseUrl.trim(),
      );
    } catch (e) {
      _pageDone = null;
      throw RuleEngineException(
        RuleErrorKind.unsupported,
        'WebView 载入网页失败（${e.runtimeType}）',
      );
    }
    try {
      await done.future.timeout(kRulePageTimeout);
    } on TimeoutException {
      throw const RuleEngineException(
        RuleErrorKind.timeout,
        '页面在 8 秒内没有加载完成，可能是网页太大或站点脚本卡住了',
      );
    } finally {
      _pageDone = null;
    }
    try {
      return await c.runJavaScriptReturningResult(js);
    } catch (e) {
      throw RuleEngineException(
        RuleErrorKind.unsupported,
        '页面脚本执行失败（${e.runtimeType}），可能是 WebView 拒绝执行',
      );
    }
  }

  /// 规则本身不可执行时**提前**报错（不用白载一次页面）。
  void _checkSelectors(SelectorValue list, SelectorValue? field) {
    if (!list.isRunnable) {
      throw RuleEngineException(
        list.isEmpty ? RuleErrorKind.empty : RuleErrorKind.unsupported,
        _selectorMessage(list, '列表规则'),
      );
    }
    if (field != null && !field.isRunnable) {
      throw RuleEngineException(
        field.isEmpty ? RuleErrorKind.empty : RuleErrorKind.unsupported,
        _selectorMessage(field, '字段规则'),
      );
    }
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('规则引擎已释放（dispose 之后不能再调用）');
  }
}

/// 一串规则不可执行时给用户看的话（带原文，方便用户去改源）。
String _selectorMessage(SelectorValue v, String what) {
  switch (v.reason) {
    case kSelectorReasonJs:
      return '$what需要 JS（${v.raw}），本版暂不支持 JS 书源';
    case kSelectorReasonEmpty:
      return '$what是空的';
    default:
      return '$what写法暂不支持（${v.raw}）';
  }
}

/// `runJavaScriptReturningResult` 的返回值解包（**剥到不是 JSON 字符串为止**）。
///
/// ## 为什么必须循环剥，不能写死「解一层 / 解两层」
/// 同一个脚本在不同平台上返回的层数不一样，这是实测出来的（不是推测）：
/// - **Android**：`evaluateJavascript` 会把字符串结果再 JSON 编码一次
///   （外面多一对引号 + `\n` / `\'` 转义），而我们的脚本自己也
///   `JSON.stringify(...)` —— 于是结果是**两层**；
/// - **iOS**：平台不额外加，只剩我们自己那一层。
///
/// 更麻烦的是第二层「可能还是字符串」也可能「已经是数组/对象」：
/// 查询类脚本 `JSON.stringify(数组)` 剥两层后是 `List`；正文脚本
/// `JSON.stringify(innerHTML)` 剥两层后是一个**普通字符串**（HTML）。
/// 所以不能按「剥固定层数」写，只能按**类型**判断：解出来还是字符串就继续剥。
///
/// 只有「以引号开头」才尝试剥：正文 HTML 以 `<` 或空白开头，剥一层后就停
/// （再 jsonDecode 一定会抛，白算一次）；数组/对象/数字/布尔则直接返回解出的值。
///
/// ## 曾经踩过的坑
/// 正文抽取原来只剥一层，结果 Android 上把 `"\n\t\t\t<p>Alice…`（带引号和
/// `\n` 转义）当正文渲染出来 —— 段落还原拿到的不是 HTML，`</p>` 一个都切不到，
/// 整章变成一坨带反斜杠的乱码。查询那条路碰巧「剥一层 + jsonDecode」= 两层，
/// 所以只有正文暴露了这个错，很容易漏。
Object? _unwrapJsValue(Object? raw, {int maxLayers = 4}) {
  if (raw == null) return null;
  // 平台已经解过（bool / num）：没有可剥的层
  if (raw is! String) return raw;
  var text = raw;
  for (var i = 0; i < maxLayers; i++) {
    // 不是 JSON 字符串就不必再试：省一次必然失败的 jsonDecode
    if (!text.trimLeft().startsWith('"')) return text;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 不是合法 JSON（比如被平台截断 / 正文本身带原始控制字符）：原样返回
      return text;
    }
    if (decoded is! String) return decoded;
    text = decoded;
  }
  return text;
}

/// JS 返回值 → 字符串（正文 / 单字段用）。
String _unwrapJsString(Object? raw) {
  final value = _unwrapJsValue(raw);
  if (value == null) return '';
  return value is String ? value : value.toString();
}

/// 把 JS 返回的 JSON 数组解成 `List<String?>`。
List<String?> _decodeValueList(Object? raw) {
  final decoded = _decodeJson(raw, '取值结果');
  if (decoded is! List) {
    throw const RuleEngineException(
      RuleErrorKind.empty,
      '页面返回的结果不是数组，可能页面结构与书源规则不符',
    );
  }
  return [for (final v in decoded) v?.toString()];
}

/// 解出 JS 返回的 JSON 值。
Object? _decodeJson(Object? raw, String what) {
  final value = _unwrapJsValue(raw);
  if (value == null) {
    throw RuleEngineException(
      RuleErrorKind.empty,
      '$what是空的：规则没有匹配到任何内容（页面结构可能已变化）',
    );
  }
  // 剥完后还是字符串：说明脚本返回的是一段 JSON 文本（我们的脚本就是这样），
  // 再解一次才是数组 / 对象。
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) {
      throw RuleEngineException(
        RuleErrorKind.empty,
        '$what是空的：规则没有匹配到任何内容（页面结构可能已变化）',
      );
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      throw RuleEngineException(
        RuleErrorKind.empty,
        '$what不是合法 JSON，可能是页面脚本被拦截或规则已失效',
      );
    }
  }
  return value;
}

/// 测试入口：把 JS 返回值（Android / iOS 两种形态）解成**调用方拿到的东西**。
///
/// 语义与 [BookRuleEngine] 里两条路一致：
/// - 查询类：剥完引号层后再解一次 JSON（数组 / 对象）；
/// - 正文类：载荷是 HTML 文本，解不出 JSON 就原样返回（这正是我们要的）。
///
/// 为什么不测私有函数：这个解包逻辑是「真机上才对」的典型 —— 单测里没有
/// WebView，只能拿两种平台形态的字符串把边界钉死。放在 lib 里加
/// `@visibleForTesting`，测试不必为了它复制一份实现。
@visibleForTesting
Object? decodeJsResultForTest(Object? raw) {
  final value = _unwrapJsValue(raw);
  if (value is! String) return value;
  final text = value.trim();
  if (text.isEmpty) return value;
  try {
    return jsonDecode(text);
  } catch (_) {
    // 正文 HTML（或以引号开头的普通文本）：解不出来就是它本身
    return value;
  }
}

/// DioException → 中文人话。
String _humanDioError(DioException e, String url) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return '连接超时（15 秒）：$url';
    case DioExceptionType.badCertificate:
      return '站点证书无效，已中止连接：$url';
    case DioExceptionType.connectionError:
      return '连不上站点（网络不可用或站点拒绝连接）：$url';
    case DioExceptionType.badResponse:
      final code = e.response?.statusCode;
      return '站点返回 $code：$url';
    case DioExceptionType.cancel:
      return '请求已取消：$url';
    case DioExceptionType.unknown:
      return '请求失败（${e.error?.runtimeType ?? '未知原因'}）：$url';
  }
}

/// 测试 / UI 预览用的假引擎：抓取与求值都由调用方注入。
///
/// 为什么放在 lib 而不是 test：R3 的页面在没有 WebView 的预览 / 空态演示里
/// 也需要一个「不会崩、给固定数据」的引擎；放 test 目录就只能测试用。
@visibleForTesting
class FakeRuleEngine extends BookRuleEngine {
  FakeRuleEngine({this.onFetch, this.onQuery, this.onQueryMap, this.onExtractHtml});

  /// 按 URL 返回网页（默认返回一段空 HTML）。
  final Future<String> Function(String url)? onFetch;

  /// 单字段求值（默认返回空列表）。
  final Future<List<String?>> Function(
    String html,
    SelectorValue listSelector,
    SelectorValue? fieldSelector,
  )? onQuery;

  /// 多字段求值（默认逐字段调 [onQuery]）。
  final Future<Map<String, List<String?>>> Function(
    String html,
    SelectorValue listSelector,
    Map<String, SelectorValue?> fields,
  )? onQueryMap;

  /// 正文抽取（默认抛「不支持」，需要正文的用例必须注入）。
  final Future<String> Function(
    String html,
    List<String> removeSelectors,
    SelectorValue textSelector,
  )? onExtractHtml;

  /// 已抓过的 URL（按调用顺序；测试用来断言「unsupported 的源没发请求」）。
  final List<String> fetchedUrls = [];

  /// 已求值的 HTML 次数。
  int queryCount = 0;

  /// dispose 次数。
  int disposeCount = 0;

  /// reset 次数（页面离开时应当 +1，且**不** dispose）。
  int resetCount = 0;

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String charset = 'utf-8',
  }) async {
    fetchedUrls.add(url);
    if (onFetch != null) return onFetch!(url);
    return '<html><head></head><body></body></html>';
  }

  @override
  Future<List<String?>> queryFields({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required SelectorValue? fieldSelector,
  }) async {
    queryCount++;
    if (onQuery != null) {
      return await onQuery!(html, listSelector, fieldSelector);
    }
    return const [];
  }

  @override
  Future<Map<String, List<String?>>> queryFieldMap({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required Map<String, SelectorValue?> fields,
  }) async {
    if (onQueryMap != null) {
      queryCount++;
      return await onQueryMap!(html, listSelector, fields);
    }
    return super.queryFieldMap(
      html: html,
      baseUrl: baseUrl,
      listSelector: listSelector,
      fields: fields,
    );
  }

  @override
  Future<String> extractHtml({
    required String html,
    required String baseUrl,
    List<String> removeSelectors = const [],
    required SelectorValue textSelector,
  }) async {
    queryCount++;
    if (onExtractHtml != null) {
      return onExtractHtml!(html, removeSelectors, textSelector);
    }
    throw const RuleEngineException(
      RuleErrorKind.unsupported,
      '假引擎没有配置正文抽取',
    );
  }

  @override
  void reset() {
    resetCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}
