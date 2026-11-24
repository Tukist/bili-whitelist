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
/// ## 网页编码的判定口径（v2.75.0）
/// 中文书站大量是 GBK，而 `dart:convert` 只有 UTF-8。以前这里一律按 UTF-8
/// 强解，配置了 `charset: gbk` 的源照旧满屏 `��`。现在改成交给
/// `utils/text_decoding.dart` 的 [decodeTextBytes]（本地书导入用的是同一套，
/// **不写第二份判定**）：
///
/// 顺序：BOM → UTF-16 → **严格 UTF-8** → UTF-8 只坏 ≤1% 字节 → GBK → 兜底。
///
/// 为什么严格 UTF-8 排在「书源声明的 gbk」前面：声明经常是错的（站点改版只改
/// 了输出没改 `<meta>`），而真 GBK 文本几乎不可能同时是合法 UTF-8。反过来的
/// 错误（声明 utf-8 实际 GBK）由严格解码必然失败接住，落到 GBK 码表。
///
/// 提示（charsetHint）的来源优先级：**HTTP 响应头的 charset > 书源的
/// `charset` 字段**。响应头是站点自己在这次响应里说的，比书源作者抄来的
/// 声明更贴近事实；两者都错时自动判定会纠正（见上）。
///
/// 判定结果带出两个只读事实：
/// - [lastDecodeEncoding]：实际用的编码（`utf-8` / `gbk` / `utf-8-malformed`…），
///   UI 用它显示「编码：GBK」这种小字；
/// - [lastDecodeWarning]：人话告警（疑似 GBK 自动纠正 / 解完仍有乱码），
///   搜索页分组小字与正文 `warning` 都用它。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../utils/text_decoding.dart';
import 'js_builder.dart';
import 'js_rule.dart';
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

/// 静态 JS 规则（`@js:` / `<js>`）的执行超时。
///
/// 为什么比页面求值（8 秒）短得多：用户脚本只做字符串变换，正常几十毫秒。
/// 超过 3 秒基本只有一种情况 —— 死循环（`while(true)` / 巨型正则）。
/// 超时后要**重载空白页**把脚本一起杀掉（见 [WebViewRuleEngine._killScript]），
/// 否则那个死循环会一直占着渲染线程，后面所有求值都排队排到天荒地老。
const Duration kRuleJsTimeout = Duration(seconds: 3);

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
  /// 最近一次 [fetchHtml] 的解码告警（「疑似 GBK 已自动纠正」/「解完仍有乱码」）；
  /// 没有问题为 null。
  ///
  /// 为什么挂在实例上而不是返回值里：接口签名由调用方定死（改签名会牵连
  /// 搜索服务的错误分类），而解码告警是**提示性**信息，副作用式带出最省事。
  /// 注意它是「最近一次」：多页抓取时要**每抓完一页就当场收下**，否则后一页
  /// 成功就把前一页的告警盖掉了（`book_content_service` / `book_detail_service`
  /// 都是这么做的）。
  String? lastDecodeWarning;

  /// 最近一次 [fetchHtml] **实际使用**的编码（`utf-8` / `gbk` /
  /// `utf-8-malformed` / `utf-16le`…）；还没抓过为 null。
  ///
  /// 与 [lastDecodeWarning] 分开的原因：GBK 是正常结果、不是告警（声明对了就
  /// 该安静），可 UI 仍要能说「编码：GBK」，否则用户不知道这页是怎么解的。
  String? lastDecodeEncoding;

  /// 抓网页正文。
  ///
  /// [charset] 是书源声明的编码（默认 `utf-8`），只当**提示**用：
  /// 优先级是 `响应头 charset` > [charset] > 自动判定，判定顺序见文件头。
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
  ///
  /// 字段规则是**静态可跑**的 JS（[SelectorValue.isStaticJsRunnable]）时，
  /// I3b 起会真的执行（逐节点）；[bindings] 是脚本可见的绑定（见
  /// `js_rule.dart` 的 `jsBindings`）。
  Future<List<String?>> queryFields({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required SelectorValue? fieldSelector,
    Map<String, String> bindings = const {},
  });

  /// 一次取多列（搜索结果页要 6 个字段，逐字段往返会慢 6 倍）。
  ///
  /// 默认实现：选择器字段逐字段调 [queryFields]，JS 字段走 [queryJsField]。
  /// [WebViewRuleEngine] 覆写成**单次**页面加载 + 单次 JS 往返（混合脚本，
  /// 见 `js_builder.dart` 的 `buildQueryFieldsMixedJs`）。
  Future<Map<String, List<String?>>> queryFieldMap({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required Map<String, SelectorValue?> fields,
    Map<String, String> bindings = const {},
  }) async {
    final selectorFields = <String, SelectorValue?>{};
    final jsFields = <String, SelectorValue>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value != null && value.kind == SelectorKind.js) {
        jsFields[entry.key] = value;
      } else {
        selectorFields[entry.key] = value;
      }
    }
    final out = <String, List<String?>>{};
    if (selectorFields.isNotEmpty) {
      out.addAll(await queryFieldMapSelectors(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        fields: selectorFields,
      ));
    }
    if (jsFields.isEmpty) return out;
    // 行数取已有列的最大长度：JS 字段本身取不出「有几行」—— 节点只有 DOM 知道。
    var rows = 0;
    for (final column in out.values) {
      if (column.length > rows) rows = column.length;
    }
    for (final entry in jsFields.entries) {
      out[entry.key] = await queryJsField(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        field: entry.value,
        bindings: bindings,
        rowCount: rows,
      );
    }
    return out;
  }

  /// 只跑**选择器字段**的多列求值（JS 字段已由 [queryFieldMap] 摘出去）。
  ///
  /// 默认实现逐字段调 [queryFields]（对假引擎 / 简易实现够用）；
  /// [WebViewRuleEngine] 覆写成单次往返。
  Future<Map<String, List<String?>>> queryFieldMapSelectors({
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

  /// 跑一条**静态 JS 字段**（逐行）。
  ///
  /// 默认实现没有 DOM，只能整页跑一次再把值广播到 [rowCount] 行 ——
  /// 只服务假引擎 / 无 WebView 环境（真实现覆写成逐节点，见
  /// `buildQueryFieldsMixedJs`）。
  Future<List<String?>> queryJsField({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required SelectorValue field,
    Map<String, String> bindings = const {},
    int rowCount = 1,
  }) async {
    final info = field.jsInfo;
    if (info == null || !info.runnable) {
      throw RuleEngineException(
        field.isEmpty ? RuleErrorKind.empty : RuleErrorKind.unsupported,
        '字段规则需要本版不支持的 JS 能力（${field.raw}）',
      );
    }
    final value = await evalJsRule(
      script: info.script,
      bindings: bindings,
      base: field.baseSelector,
      asExpression: info.form == JsRuleForm.template,
    );
    return List<String?>.filled(rowCount < 1 ? 1 : rowCount, value);
  }

  /// 正文抽取：先删 [removeSelectors] 命中的节点，再取 [textSelector]
  /// 命中节点（没命中则整页 body）的**innerHTML**。
  ///
  /// 为什么返回值是 HTML 而不是纯文本：段落还原（`<br>` / 块级边界 → 换行）
  /// 放在 Dart 侧做纯函数（`restoreParagraphs`），才能被单测覆盖到每一种
  /// 策略；在 JS 里做就只能靠真机肉眼验。删节点与取内容必须在**同一次**
  /// 页面载入里完成（见 `buildExtractHtmlJs` 的注释）。
  ///
  /// I3b：`textSelector` 是**静态可跑的 JS**（`content.text = 'div.c@html@js:…'`）
  /// 时，先按前置选择器取 innerHTML 当 `result`，再在同一个 IIFE 里跑脚本；
  /// [bindings] 是脚本绑定。
  ///
  /// 默认实现直接报「不支持」：只有 [WebViewRuleEngine] 有真实 DOM。
  Future<String> extractHtml({
    required String html,
    required String baseUrl,
    List<String> removeSelectors = const [],
    required SelectorValue textSelector,
    Map<String, String> bindings = const {},
  }) async {
    throw const RuleEngineException(
      RuleErrorKind.unsupported,
      '当前引擎不支持正文抽取（缺少 WebView）',
    );
  }

  /// 静态 JS 规则执行（I3a）：在**当前已载入的页面**上跑一段书源脚本，
  /// 返回脚本最后读到的 `result`（null = 脚本把结果置空了）。
  ///
  /// ## 为什么是「当前页面」而不是「给一段 HTML」
  /// legado 的 `@js:` 规则是**同步语义**：它默认自己在一个已解析的文档上跑，
  /// `result` 是上一步取到的值。本版沿用这个语义 —— 调用方先跑选择器求值
  /// （页面已经载入），紧接着调这里做变换。重新 `loadHtmlString` 一次既慢，
  /// 又会让「上一步取到的 DOM 状态」丢掉。列表字段的**逐行**语义由
  /// [queryJsField] / `queryFieldMap` 负责，这里只是单值版本。
  ///
  /// [base] 是「先取再变换」里的前置选择器（`@css:.a@js:…`），非空时会先在
  /// 当前页面上取值作为脚本的 `result` 初值。
  ///
  /// [bindings] 是脚本可见的绑定（`book` / `source` / `baseUrl` / `key` /
  /// `page` / `chapter` / `title`，见 `js_rule.dart` 的 `jsBindings`）。
  /// [asExpression]：`{{…}}` 模板把正文当表达式求值。
  ///
  /// **安全**：脚本里出现白名单外的 API（`java.ajax` / `Packages.` /
  /// `fetch` …）直接抛 unsupported，不去碰页面；执行超时视为失败并终止脚本。
  /// 默认实现报「不支持」（假引擎 / 无 WebView 环境）。
  Future<String?> evalJsRule({
    required String script,
    required Map<String, String> bindings,
    SelectorValue? base,
    bool asExpression = false,
  }) async {
    throw const RuleEngineException(
      RuleErrorKind.unsupported,
      '当前引擎不支持执行书源 JS（缺少 WebView）',
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

/// 把 `<base href>` 注入 HTML 头部（求值前必须做）。///
/// 为什么注入而不是只依赖 `loadHtmlString(baseUrl:)`：后者在部分 Android
/// WebView 版本上不会真正更新 `document.baseURI`，结果就是相对链接被解成
/// `about:blank` 下的相对路径 —— `new URL(v, document.baseURI)` 拿到一堆
/// 没有域名的假地址。自己塞一个 `<base>` 是确定有效的。
///
/// 注意：我们插在 `<head>` 的**最前面**，所以优先于页面自带的 `<base>`
/// （浏览器只认第一个）。这是有意的：相对链接应该按「我们抓它时的那个 URL」
/// 解析，而不是页面自己声明的（那可能指向 CDN / 镜像站）。
String injectBaseHref(String html, String baseUrl) =>
    _injectHeadTag(html, baseUrl.trim().isEmpty
        ? null
        : '<base href="${_escapeAttr(baseUrl.trim())}">');

/// 给这一份 HTML 打一个**载页标记**（`<meta name="amotv-load" content="token">`）。
///
/// 为什么需要它（v2.78.0 实机踩到）：`loadHtmlString` 的 Future 在**平台调用
/// 返回**时就完成了，此时新文档还没 commit —— 立刻轮询 `document.readyState`
/// 读到的可能是**上一页**（甚至是超时后那张空白页）的 complete，于是「页面
/// 好了」被误判，后续选择器在旧 DOM 上跑，整源取到一堆错值。
/// 打标记之后，只有「标记 = 本次 token」才认这一页。
String injectLoadMarker(String html, String token) =>
    _injectHeadTag(html, '<meta name="amotv-load" content="$token">');

/// 把 [tag]（`<base>` / `<meta …>`）插到 `<head>` 最前面（没有 head 就造一个）。
String _injectHeadTag(String html, String? tag) {
  if (tag == null) return html;
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

/// 书源 JS 的安全门（纯函数，可单测）：脚本里还有禁用 API 就抛。
///
/// 为什么抽成顶层函数而不是写在 [WebViewRuleEngine.evalJsRule] 里：
/// `flutter test` 里建不出 WebView，写在引擎里就只能靠肉眼审；
/// 抽出来之后「拦什么、报什么话」能被单测钉死（见 `book_rule_engine_test.dart`）。
/// 判定本身在 `js_rule.dart`（白名单只有一份）。
void checkJsRuleAllowed(String script) {
  final blocked = blockedApisIn(script);
  if (blocked.isNotEmpty) {
    throw RuleEngineException(
      RuleErrorKind.unsupported,
      blockedApisMessage(blocked),
    );
  }
  // 同步死循环会把整个 WebView（全 App 共用）卡死，超时之后连空白页都排不进去
  // —— 只能在执行前拦住（见 `js_rule.dart` 的 hasObviousDeadLoop）。
  if (hasObviousDeadLoop(script)) {
    throw const RuleEngineException(
      RuleErrorKind.unsupported,
      '这条规则里有死循环（while(true) / for(;;)），本版不执行',
    );
  }
}

/// 从 HTTP `Content-Type` 里抠出 charset（拿不到 / 写的是别名都返回原样字符串）。
///
/// 为什么单列一个函数：响应头才是「站点这次真的用什么编码」的第一手证据，
/// 而书源的 `charset` 字段是书源作者手抄的（经常抄错，改了站点没改声明）。
/// 这段解析很碎（引号可有可无、后面还可能跟 `;` 与别的参数），单独放出来
/// 才好用单测钉住。
String? parseHeaderCharset(String? contentType) {
  if (contentType == null || contentType.trim().isEmpty) return null;
  final match = RegExp(
    r'charset\s*=\s*"?([^";,\s]+)',
    caseSensitive: false,
  ).firstMatch(contentType);
  final value = match?.group(1)?.trim();
  if (value == null || value.isEmpty) return null;
  return value;
}

/// 「解完仍有乱码」的告警文案。
///
/// 抽成常量不是为了省字符，而是 [decodeNoteFor] 要**区分两种告警**：这句是
/// 坏消息（正文可能缺字），另一句「疑似 GBK」其实是好消息（以前满屏 `��`，
/// 现在能读了）。两边各写一份字面量，改文案时一定会漏掉一处。
const String kDecodeGarbledWarning = '解码后仍有乱码，正文可能不完整';

/// 「疑似 GBK、已自动纠正」的告警文案（见 [kDecodeGarbledWarning] 的说明）。
const String kDecodeGbkGuessWarning = '这个书源疑似 GBK，已按 GBK 解码';

/// 解码结果 → 给人看的一句告警；没问题返回 null。
///
/// 两条文案分开是有意的：
/// - 「疑似 GBK」是**好消息**（以前满屏 `��`，现在能读了），所以要说是「已按
///   GBK 解码」而不是「有乱码」。站点自己声明了 GBK 就不提示 —— 声明对了是
///   正常情况，不该在每次搜索都刷一行字；
/// - 「仍有乱码」才是坏消息：解完还剩一堆 U+FFFD，说明站点多半是繁中 / 日文
///   等本版还没接的编码，正文可能缺字。
String? decodeWarningFor(DecodedText decoded, {String? charsetHint}) {
  if (decoded.isMostlyGarbage) return kDecodeGarbledWarning;
  if (decoded.encoding == 'gbk' && !isGbkCharset(charsetHint)) {
    return kDecodeGbkGuessWarning;
  }
  return null;
}

/// 解码事实 → 搜索页分组标题下的一行小字（`null` = 什么都不显示）。
///
/// 为什么要压缩成这么短：这是「该源这次是怎么解的」的旁注，不是错误。
/// 每行都写「本页按 xxx 解码，替换字符比例 0.3%」只会把结果列表挤满；
/// 用户真正需要区分的是三种情况：正常 UTF-8（不显示）、GBK（可能值得知道）、
/// 有乱码（可能读不全）。
///
/// **「疑似 GBK」不写成「仍有乱码」**：自动判定成功是好消息，标成乱码会让
/// 用户以为这本书读不了（实机上第一次就踩了这个坑）。
String? decodeNoteFor(String? encoding, String? warning) {
  final isGbk = (encoding ?? '').toLowerCase() == 'gbk';
  final garbled = warning == kDecodeGarbledWarning;
  if (garbled) return isGbk ? '编码：GBK（仍有乱码）' : '解码有乱码';
  return isGbk ? '编码：GBK' : null;
}

/// WebView 实现：隐藏 controller 当执行器，Dio 负责抓网页。
///
/// 用法：调用方把 [buildHost] 返回的 widget 挂在 `Offstage` /
/// `SizedBox.shrink` 里（WebView 必须进 widget 树才会真正创建原生视图），
/// 然后调 [fetchHtml] / [queryFields]。
class WebViewRuleEngine extends BookRuleEngine {
  WebViewRuleEngine({WebViewController? controller, Dio? dio})
      : _controller = controller,
        _dio = dio ??
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
            ));

  final Dio _dio;
  WebViewController? _controller;

  /// 真 controller，**按需创建**。
  ///
  /// 为什么懒建（v2.75.0）：`fetchHtml` 只走 Dio，一个 WebView 都不需要，而
  /// `WebViewController()` 在 `flutter test` 里构造即抛。以前在构造函数里就建，
  /// 结果是「解码逻辑根本测不了」—— 为了验一行 GBK 字节得先开一个 WebView。
  /// 懒建之后单测能注入假 Dio 直接验 `fetchHtml`；真机上首页 `buildHost()`
  /// 会立刻把它建出来，行为与之前一致。
  WebViewController get _web => _controller ??= _buildController();

  /// 串行队列尾（见文件头「串行求值」）。
  Future<void> _tail = Future<void>.value();

  /// 当前页的「加载完成」信号（每次求值换一个新的）。
  Completer<String>? _pageDone;

  /// 载页代次：`reset()` 之后旧的那次轮询要立刻退出（见 [_waitUntilParsed]）。
  int _loadToken = 0;

  bool _disposed = false;

  /// 当前页面是否已经载入完成。
  ///
  /// 为什么要有这个标记（I3a）：[evalJsRule] **不重新载页**，它复用上一次
  /// 选择器求值留下的 DOM。没有页面可复用时必须明确报错，而不是在
  /// `about:blank` 上跑脚本然后返回一个看起来正常的空值。
  bool _pageLoaded = false;

  /// 正在跑书源 JS：期间一律禁止导航（脚本里 `location.href=…` 会被拦）。
  bool _jsRuleRunning = false;

  /// ⚠️ 这里刻意**新建**一个干净的 Dio：`BiliApi` 的 Dio 带 B 站定制的
  /// baseUrl / Referer / Cookie，拿它请求第三方站点既会带上不该带的凭据，
  /// 也会被站点当成盗链拒绝。
  /// 建 controller（实例方法：导航回调要写 [_pageDone]，顶层函数碰不到实例字段）。
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
          // 跑书源 JS 期间**一律**不放行：白名单已经拦了网络 API，但脚本仍可能
          // 用 `location.href` 把页面顶走 —— 页面一走，后面的求值全错。
          if (_jsRuleRunning) return NavigationDecision.prevent;
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
    return WebViewWidget(controller: _web);
  }

  /// 真 controller（调试 / 未来要给页面绑定进度时用）。
  ///
  /// 懒建意味着在 `buildHost()` 之前它是 null —— 调用方要判空。
  WebViewController? get controller => _controller;

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String charset = 'utf-8',
  }) async {
    _ensureAlive();
    lastDecodeWarning = null;
    lastDecodeEncoding = null;
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
    // 交给统一的解码判定（`utils/text_decoding.dart`，与本地 TXT 导入同一套）。
    // 编码提示的优先级：响应头 charset > 书源声明 —— 响应头是站点在这次响应里
    // 自己说的，比书源作者抄来的声明更贴近事实。
    final headerCharset = parseHeaderCharset(
      resp.headers.value(Headers.contentTypeHeader),
    );
    final hint = headerCharset ?? charset;
    final decoded = decodeTextBytes(bytes, charsetHint: hint);
    lastDecodeEncoding = decoded.encoding;
    lastDecodeWarning = decodeWarningFor(decoded, charsetHint: hint);
    return decoded.text;
  }

  @override
  Future<List<String?>> queryFields({
    required String html,
    required String baseUrl,
    required SelectorValue listSelector,
    required SelectorValue? fieldSelector,
    Map<String, String> bindings = const {},
  }) async {
    _ensureAlive();
    // 静态 JS 字段：交给混合求值（逐节点跑脚本），不按选择器查
    if (fieldSelector != null && fieldSelector.kind == SelectorKind.js) {
      final map = await queryFieldMap(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        fields: {'__field': fieldSelector},
        bindings: bindings,
      );
      return map['__field'] ?? const [];
    }
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
    Map<String, String> bindings = const {},
  }) async {
    _ensureAlive();
    _checkSelectors(listSelector, null);
    if (fields.isEmpty) return const {};
    final selectorFields = <String, SelectorValue?>{};
    final jsFields = <String, SelectorValue>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value != null && value.kind == SelectorKind.js) {
        // 跑不了的 JS 字段：**在载页之前**就说清楚（省一次注定失败的抓取）
        if (!value.isStaticJsRunnable) {
          throw RuleEngineException(
            RuleErrorKind.unsupported,
            _selectorMessage(value, '字段规则'),
          );
        }
        jsFields[entry.key] = value;
      } else {
        selectorFields[entry.key] = value;
      }
    }
    // 一次求值里取完所有列（选择器 + 逐行 JS），页面只载入一次 ——
    // 逐字段载页是 6 倍等待，逐行 evalJsRule 是 N 倍往返。
    final raw = await _serial(() async {
      await _loadPage(html: html, baseUrl: baseUrl);
      final js = buildQueryFieldsMixedJs(
        listSelector: listSelector,
        selectorFields: selectorFields,
        jsFields: jsFields,
        bindings: bindings,
      );
      if (jsFields.isEmpty) return _runJsRaw(js);
      // 有用户脚本 → 按书源 JS 的口径执行：3 秒超时 + 期间禁止导航，
      // 超时重载空白页把死循环顶掉（见 kRuleJsTimeout）。
      _jsRuleRunning = true;
      try {
        return await _runJsOnPage(js, timeout: kRuleJsTimeout, killOnTimeout: true);
      } finally {
        _jsRuleRunning = false;
      }
    });
    final decoded = _decodeJson(raw, '字段结果');
    if (decoded is! Map) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '页面返回的字段结果不是对象，可能页面结构与书源规则不符',
      );
    }
    for (final line in _stringListOf(decoded['logs'])) {
      debugPrint('[书源 JS] $line');
    }
    for (final line in _stringListOf(decoded['warnings'])) {
      debugPrint('[书源 JS 告警] $line');
    }
    // 某个字段「一行都没取到且有报错」→ 明确说是 JS 炸了，而不是静默空列
    // （静默空值是本模块历史上最难查的一类问题）。
    final errors = <String, String>{};
    final rawErrors = decoded['errors'];
    if (rawErrors is List) {
      for (final item in rawErrors) {
        if (item is! Map) continue;
        final field = '${item['field']}';
        errors.putIfAbsent(field, () => '${item['error']}');
      }
    }
    final columns = decoded['fields'] is Map ? decoded['fields'] as Map : decoded;
    final out = <String, List<String?>>{};
    for (final entry in fields.entries) {
      final list = columns[entry.key];
      final values = list is List
          ? [for (final v in list) v?.toString()]
          : <String?>[];
      final hasValue =
          values.any((v) => v != null && v.trim().isNotEmpty);
      final jsError = errors[entry.key];
      if (!hasValue && jsError != null) {
        throw RuleEngineException(
          RuleErrorKind.unsupported,
          '字段「${entry.key}」的 JS 规则执行失败：$jsError',
        );
      }
      out[entry.key] = values;
    }
    return out;
  }

  @override
  Future<String> extractHtml({
    required String html,
    required String baseUrl,
    List<String> removeSelectors = const [],
    required SelectorValue textSelector,
    Map<String, String> bindings = const {},
  }) async {
    _ensureAlive();
    final isJs = textSelector.kind == SelectorKind.js;
    if (isJs) {
      if (!textSelector.isStaticJsRunnable) {
        throw RuleEngineException(
          RuleErrorKind.unsupported,
          _selectorMessage(textSelector, '正文规则'),
        );
      }
    } else if (!textSelector.isEmpty) {
      // 正文规则为空是「取整页」的合法写法（少数站点整页只有正文），
      // 但写了却不可执行（语法错）就必须说清楚，不能静默回空。
      _checkSelectors(textSelector, null);
    }
    final info = textSelector.jsInfo;
    final raw = await _serial(() async {
      if (!isJs) {
        return _evalJs(
          html: html,
          baseUrl: baseUrl,
          js: buildExtractHtmlJs(
            removeSelectors: removeSelectors,
            textSelector: textSelector,
          ),
        );
      }
      // 正文规则本身是 JS：同一个 IIFE 里「删节点 → 取值 → 跑脚本」，
      // 跑脚本这一步同样按书源 JS 的口径限时（死循环要能被顶掉）。
      await _loadPage(html: html, baseUrl: baseUrl);
      _jsRuleRunning = true;
      try {
        return await _runJsOnPage(
          buildExtractHtmlWithJsJs(
            removeSelectors: removeSelectors,
            base: textSelector.baseSelector,
            script: info!.script,
            bindings: bindings,
            asExpression: info.form == JsRuleForm.template,
          ),
          timeout: kRuleJsTimeout,
          killOnTimeout: true,
        );
      } finally {
        _jsRuleRunning = false;
      }
    });
    if (isJs) {
      final run = parseJsRunOutput(raw);
      for (final line in run.logs) {
        debugPrint('[书源 JS] $line');
      }
      if (!run.ok) {
        throw RuleEngineException(
          RuleErrorKind.unsupported,
          '正文 JS 规则执行失败：${run.error}',
        );
      }
      final htmlOut = run.value ?? '';
      if (htmlOut.trim().isEmpty) {
        throw const RuleEngineException(
          RuleErrorKind.empty,
          '正文是空的：正文 JS 规则返回了空值',
        );
      }
      return htmlOut;
    }
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
  Future<String?> evalJsRule({
    required String script,
    required Map<String, String> bindings,
    SelectorValue? base,
    bool asExpression = false,
  }) async {
    _ensureAlive();
    // 第三道门（解析阶段是第一道、白名单本身是第二道）：脚本里只要还有
    // 禁用 API 就直接拒，连页面都不碰。调用方即使漏了 SelectorValue 判定，
    // 也不会把 `java.ajax(...)` 送进 WebView。
    checkJsRuleAllowed(script);
    return _serial(() async {
      _ensureAlive();
      if (_controller == null || !_pageLoaded) {
        throw const RuleEngineException(
          RuleErrorKind.unsupported,
          'JS 规则要复用已载入的页面：当前页面还没载入，先跑一次选择器求值再执行 JS',
        );
      }
      String? initial;
      if (base != null) {
        if (base.kind == SelectorKind.js) {
          throw RuleEngineException(
            RuleErrorKind.unsupported,
            'JS 前置选择器本身也是 JS（${base.raw}），本版不支持嵌套',
          );
        }
        if (!base.isRunnable) {
          throw RuleEngineException(
            base.isEmpty ? RuleErrorKind.empty : RuleErrorKind.unsupported,
            _selectorMessage(base, 'JS 前置选择器'),
          );
        }
        initial = await _valueOnCurrentPage(base);
      }
      _jsRuleRunning = true;
      Object? raw;
      try {
        raw = await _runJsOnPage(
          buildJsRunnerScript(
            script: script,
            bindings: bindings,
            initialResult: initial,
            asExpression: asExpression,
          ),
          timeout: kRuleJsTimeout,
          killOnTimeout: true,
        );
      } finally {
        _jsRuleRunning = false;
      }
      final out = parseJsRunOutput(raw);
      for (final line in out.logs) {
        debugPrint('[书源 JS] $line');
      }
      for (final warning in out.warnings) {
        debugPrint('[书源 JS 告警] $warning');
      }
      if (!out.ok) {
        throw RuleEngineException(
          RuleErrorKind.unsupported,
          'JS 规则执行失败：${out.error}',
        );
      }
      return out.value;
    });
  }

  /// 在当前页面上跑一次「取值」脚本，返回第一个非空值（JS 前置选择器用）。
  ///
  /// 复用 [buildQueryFieldsJs]（`fieldSelector: null` = 取节点自身的值），
  /// 所以前置选择器的语法与普通规则完全一致，不用写第二套解析。
  Future<String?> _valueOnCurrentPage(SelectorValue base) async {
    final raw = await _runJsOnPage(buildQueryFieldsJs(base, null));
    final values = _decodeValueList(raw);
    for (final v in values) {
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  /// 在当前页面上跑一段 JS，返回**原始**结果。
  ///
  /// 与 [_evalJs] 的区别：不载页。书源 JS 必须复用已载入的 DOM（见
  /// [evalJsRule] 的说明）；顺带也让「先取值再变换」这条链只付一次载页成本。
  ///
  /// [timeout] 非空时超时即失败；[killOnTimeout] 为真时还会重载空白页
  /// （见 [kRuleJsTimeout] 与 [_killScript]）。
  Future<Object?> _runJsOnPage(
    String js, {
    Duration? timeout,
    bool killOnTimeout = false,
  }) async {
    _ensureAlive();
    final c = _web;
    Future<Object?> run;
    try {
      run = c.runJavaScriptReturningResult(js);
    } catch (e) {
      throw RuleEngineException(
        RuleErrorKind.unsupported,
        '页面脚本执行失败（${e.runtimeType}），可能是 WebView 拒绝执行',
      );
    }
    if (timeout == null) return run;
    try {
      return await run.timeout(timeout);
    } on TimeoutException {
      if (killOnTimeout) await _killScript();
      throw RuleEngineException(
        RuleErrorKind.timeout,
        'JS 规则执行超过 ${timeout.inSeconds} 秒，已终止（脚本里可能有死循环）',
      );
    }
  }

  /// 用空白页顶掉当前页面，把还挂在渲染线程上的脚本一起终止。
  ///
  /// 为什么必须做：`runJavaScriptReturningResult` 的 Future 超时了，但脚本
  /// 本身还在跑（`while(true)` 不会因为 Dart 侧不 await 就停下）。不换页的话
  /// 这个 WebView 之后的每一次求值都会排在它后面，整条搜索卡死。
  /// 载入空白页是唯一能强制中断同步脚本的办法。
  Future<void> _killScript() async {
    _pageLoaded = false;
    try {
      await _web
          .loadHtmlString('', baseUrl: null)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // 杀页面失败不改变错误语义：调用方拿到的是「超时」，不是「杀失败」
    }
  }

  @override
  void reset() {
    // 只把「正在等页面加载」的那次求值叫醒：不清 `_tail`，因为排队中的
    // 任务各自持有自己的 gate（`_serial` 的 finally 会放行下一个），
    // 硬清队列反而会让等待者永远挂住。
    // v2.78.0 起载页是轮询 readyState，代次 +1 让那条轮询立刻退出。
    _loadToken++;
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
    await _loadPage(html: html, baseUrl: baseUrl);
    return _runJsRaw(js);
  }

  /// 只载页（I3b 拆出来：混合求值要先载页，再按「是否含用户脚本」决定
  /// 要不要加超时与禁导航）。
  ///
  /// ## 为什么不再死等 `onPageFinished`（v2.78.0）
  /// `onPageFinished` 要等**全部子资源**（外链 jQuery / 封面图 / 统计脚本）。
  /// 真实书站的搜索页普遍挂 `https://libs.baidu.com/jquery/...` 这类外链，
  /// 本机网络下经常 8 秒都等不到 → 整源报「页面在 8 秒内没有加载完成」。
  /// I3b 之前这类源被「有 JS 就不跑」直接跳过，问题被掩盖；接线之后它就成了
  /// **主线失败原因**（实机实测：阅友小说、零零小说都卡在这一步）。
  ///
  /// 现在改成轮询 `document.readyState`：`complete` 立刻放行；如果 2.5 秒后
  /// 已经是 `interactive`（HTML 解析完了、外链资源还在下载），也放行 ——
  /// 我们只需要 DOM，不需要等图片字节。真·白屏 / 解析卡死仍按 8 秒超时。
  Future<void> _loadPage({
    required String html,
    required String baseUrl,
  }) async {
    _ensureAlive();
    if (html.trim().isEmpty) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '抓到的网页是空的：站点可能返回了空页或拦截了请求',
      );
    }
    final c = _web;
    final done = Completer<String>();
    _pageDone = done;
    _pageLoaded = false;
    _loadToken++;
    final token = _loadToken;
    try {
      await c.loadHtmlString(
        injectLoadMarker(injectBaseHref(html, baseUrl), '$token'),
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
      await _waitUntilParsed(done, token);
    } finally {
      _pageDone = null;
    }
    // 页面就绪：之后的 evalJsRule 可以复用它（不重新载页，见 evalJsRule 说明）
    _pageLoaded = true;
  }

  /// 等页面「能用」（见 [_loadPage] 的说明）。
  ///
  /// [done] 是 `onPageFinished` 的信号，只用来**提前**放行（它是 complete 的
  /// 权威信号）与接住导航失败；超时语义与旧版一致（8 秒）。
  ///
  /// 判定「是不是**这一页**」靠 [_loadPage] 注入的 `amotv-load` 标记：标记
  /// 对不上就说明新文档还没 commit（读到的 complete 属于上一页），继续等。
  Future<void> _waitUntilParsed(Completer<String> done, int token) async {
    final started = DateTime.now();
    const graceForSubresources = Duration(milliseconds: 2500);
    final probe = '(function(){var m=document.querySelector('
        '\'meta[name="amotv-load"]\');return JSON.stringify({'
        't: m ? m.getAttribute("content") : "", s: document.readyState});})()';
    while (true) {
      if (token != _loadToken) {
        throw const RuleEngineException(
          RuleErrorKind.unsupported,
          '页面已离开，本次求值已取消',
        );
      }
      if (done.isCompleted) {
        // 导航失败会在这里带出 networkError
        await done.future;
        return;
      }
      var state = '';
      var marker = '';
      try {
        final raw = _unwrapJsValue(await _web.runJavaScriptReturningResult(probe));
        if (raw is String) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            marker = '${decoded['t'] ?? ''}';
            state = '${decoded['s'] ?? ''}'.toLowerCase();
          }
        } else if (raw is Map) {
          marker = '${raw['t'] ?? ''}';
          state = '${raw['s'] ?? ''}'.toLowerCase();
        }
      } catch (_) {
        // 文档还没建好：下一轮再问
      }
      if (marker == '$token') {
        if (state == 'complete') return;
        final elapsed = DateTime.now().difference(started);
        if (state == 'interactive' && elapsed >= graceForSubresources) return;
      }
      if (DateTime.now().difference(started) >= kRulePageTimeout) {
        throw const RuleEngineException(
          RuleErrorKind.timeout,
          '页面在 8 秒内没有加载完成，可能是网页太大或站点脚本卡住了',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// 在**已载入**的页面上跑一段脚本（不载页、不限时）。
  Future<Object?> _runJsRaw(String js) async {
    try {
      return await _web.runJavaScriptReturningResult(js);
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
      // I3b 起分两种：静态可跑的不该走到这里；跑不了的要说清缺什么能力，
      // 否则用户只看到「需要 JS」却不知道该改哪一段。
      if (v.blockedApis.isNotEmpty) {
        return '$what的 JS 规则用了本版不支持的接口：'
            '${v.blockedApis.join('、')}（${v.raw}）';
      }
      final why = v.jsInfo?.summary ?? '本版暂不支持';
      return '$what的 JS 规则跑不了：$why（${v.raw}）';
    case kSelectorReasonEmpty:
      return '$what是空的';
    case kSelectorReasonTextFilter:
      return '$what用了 text. 按文字筛元素（${v.raw}），写法有误';
    case kSelectorReasonInterleave:
      return '$what用了 %% 交叉合并（${v.raw}），写法有误';
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

/// 取 JS 载荷里的 `logs` / `warnings` 列表（坏数据一律当空，不让它崩）。
List<String> _stringListOf(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final v in raw)
      if (v != null) v.toString(),
  ];
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
  FakeRuleEngine({
    this.onFetch,
    this.onQuery,
    this.onQueryMap,
    this.onExtractHtml,
    this.onEvalJs,
  });

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

  /// 静态 JS 规则执行（I3a；默认抛「不支持」，I3b 接服务后由用例注入）。
  ///
  /// 返回值语义与真引擎一致：脚本的 `result` 字符串，null = 结果为空。
  /// 四种情况（成功 / 返回 null / 脚本报错 / 超时）都靠这个回调模拟，
  /// 这样搜索编排的用例不必开 WebView。
  final Future<String?> Function(
    String script,
    Map<String, String> bindings,
    SelectorValue? base,
  )? onEvalJs;

  /// 已执行的 JS 规则次数与脚本（测试断言「哪条规则被送进沙箱」）。
  int jsRuleCount = 0;
  final List<String> jsRuleScripts = [];

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
    Map<String, String> bindings = const {},
  }) async {
    queryCount++;
    // JS 字段走 onEvalJs（`onQuery` 只服务选择器；混在一起两边都验不准）
    if (fieldSelector != null && fieldSelector.kind == SelectorKind.js) {
      return queryJsField(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        field: fieldSelector,
        bindings: bindings,
      );
    }
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
    Map<String, String> bindings = const {},
  }) async {
    if (onQueryMap == null) {
      return super.queryFieldMap(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        fields: fields,
        bindings: bindings,
      );
    }
    // 选择器字段交给注入的回调，JS 字段交给 onEvalJs —— 与真引擎的分工一致
    final selectorFields = <String, SelectorValue?>{};
    final jsFields = <String, SelectorValue>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value != null && value.kind == SelectorKind.js) {
        jsFields[entry.key] = value;
      } else {
        selectorFields[entry.key] = value;
      }
    }
    final out = <String, List<String?>>{};
    if (selectorFields.isNotEmpty) {
      queryCount++;
      out.addAll(await onQueryMap!(html, listSelector, selectorFields));
    }
    if (jsFields.isEmpty) return out;
    var rows = 0;
    for (final column in out.values) {
      if (column.length > rows) rows = column.length;
    }
    for (final entry in jsFields.entries) {
      out[entry.key] = await queryJsField(
        html: html,
        baseUrl: baseUrl,
        listSelector: listSelector,
        field: entry.value,
        bindings: bindings,
        rowCount: rows,
      );
    }
    return out;
  }

  @override
  Future<String> extractHtml({
    required String html,
    required String baseUrl,
    List<String> removeSelectors = const [],
    required SelectorValue textSelector,
    Map<String, String> bindings = const {},
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
  Future<String?> evalJsRule({
    required String script,
    required Map<String, String> bindings,
    SelectorValue? base,
    bool asExpression = false,
  }) async {
    jsRuleCount++;
    jsRuleScripts.add(asExpression ? '{{$script}}' : script);
    if (onEvalJs != null) {
      return await onEvalJs!(script, bindings, base);
    }
    throw const RuleEngineException(
      RuleErrorKind.unsupported,
      '假引擎没有配置 JS 规则执行',
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
