/// 中国移动**掌厅网页**（`wx.10086.cn`）余量数据的解析（v2.54.0）。
///
/// ## 这一层干什么、不干什么
///
/// 用户要求「不要手动录入，App 自己去读」。取数路线（抗变化优先）：
/// - **C（首选）**：在 App 内 WebView 打开掌厅页面，注入 JS 钩住
///   `fetch` / `XMLHttpRequest`，把命中的原始响应体回传 → **本文件**负责
///   解密 + 解析成结构化读数（[parsePlanBody]）；
/// - **B（降级）**：C 拿不到响应时，读 `document.body.innerText` 用正则抠
///   「通用/定向/其他/总」的已用/剩余（[parsePageText]）；
/// - **D（兜底）**：B 也失败 → 只把页面呈现给用户，App 不解析（界面给一句
///   可读的原因 + 「打开掌厅页面」的出口，用户自己看数字，仍可用手动录入）。
///
/// ⚠️ **这是非官方接口**：掌厅页面自己调的接口没有公开文档、没有签名（纯靠
/// Cookie），字段与页面文案都可能随时改。所以：
/// - 每条失败路径都返回**可读的中文原因**（不静默、不抛到界面）；
/// - 任何一项读不到就是 `null`（**绝不用 0 冒充"没用流量"**）；
/// - 界面上必须写"非官方、可能失效、以运营商账单为准"。
///
/// ## 加密（两份独立开源实现一致，可信）
///
/// 接口响应是 `AES-128-CBC / PKCS7`，`key = 1234123412ABCDEF`、
/// `iv = ABCDEF1234123412`（这两个值是**网页自己 JS 里的常量**、开源客户端里
/// 也是明文，不是本 App 的秘密）。判定规则见 [looksLikeCipherHex]：
/// 去空白后长度 ≥ 32、长度是 32 的整数倍、且全是 hex → 当密文解；
/// 否则按明文 JSON 处理。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'cmcc_aes.dart';

// ---------------------------------------------------------------------------
// 常量（页面 / 接口 / 文案）
// ---------------------------------------------------------------------------

/// 掌厅登录页（用户在这里手动登录一次：手机号 + 短信验证码，可能弹滑块）。
const String kCmccLoginUrl = 'https://wx.10086.cn/website/bind/bindAccount/new';

/// 登录后的个人首页（打开后页面自己会去调余量接口）。
const String kCmccHomeUrl = 'https://wx.10086.cn/website/spa/main/newHome';

/// AES-128 key（16 字节 ASCII；来自页面自身 JS，非本 App 的秘密）。
const String kCmccAesKey = '1234123412ABCDEF';

/// AES-128 CBC 的 IV（16 字节 ASCII）。
const String kCmccAesIv = 'ABCDEF1234123412';

/// 关切的接口名（**只用来筛选要回传哪条响应**；不自己拼 URL —— 页面自己会调，
/// 这样页面改路径/加参数都不用动 App）。
const List<String> kCmccWantedApis = [
  'getNewMarginInfo',
  'fareBalance',
  'accountFeeBalanceQuery',
  'getMainPlan',
];

/// 余量数据在响应里的字段名（`data.resultData` 下的四个节点）。
const String kCmccKeyGeneral = 'planRemian'; // 通用流量
const String kCmccKeyDirectional = 'directionalFlowInfo'; // 定向流量
const String kCmccKeyOther = 'otherRemian'; // 其他 / 区域
const String kCmccKeyTotal = 'totalInfo'; // 总流量

/// 单位码 → 中文标签（`01` 分钟、`02` 条、`03` MB、`04` GB）。
const Map<String, String> kCmccUnitLabels = {
  '01': '分钟',
  '02': '条',
  '03': 'MB',
  '04': 'GB',
};

/// 余量节点的常见容器名（四个节点通常都挂在这层里面）。
const List<String> kCmccFlowWrappers = [
  'planRemianFlowInfo',
  'flowInfo',
  'marginInfo',
];

// ---- 页面文案（**每个都按非空白字符 ≤ 42 钉住**，见 test/cmcc_plan_test.dart）----

/// 分组标题。
const String kCmccGroup = '中国移动掌厅（实验）';

/// 一句话说清"非官方、可能失效、以账单为准"。
const String kCmccIntro = '非官方接口，可能失效；数字以运营商账单为准。';

/// 未登录态。
const String kCmccStateLoggedOut = '未登录';

/// 已登录态。
const String kCmccStateLoggedIn = '已登录';

/// 登录态失效（失效要用户重新收短信，App 不代收、不代发）。
const String kCmccStateNeedRelogin = '需要重新登录';

/// 定向流量读不到时的如实说明（**不许显示 0 冒充**）。
const String kCmccNoDirectional = '掌厅没给定向流量读数。';

/// 登录说明：手动登录，App 不代填、不代发验证码。
const String kCmccLoginHint = '在掌厅页面里自己填手机号和验证码；App 不代填、不代发。';

/// 手动兜底仍在的说明。
const String kCmccManualFallback = '读不到时，上面的「手动录入」仍然可用。';

/// C 路线失败的可读原因。
const String kCmccFailNoResponse = '没抓到掌厅的余量接口响应。';

/// C 路线解密失败的可读原因。
const String kCmccFailDecrypt = '抓到响应了，但解不开（key/IV 或格式可能变了）。';

/// 字段缺失（通用流量）。
const String kCmccFailNoGeneral = '响应里没有通用流量读数（字段缺失）。';

/// 单位不认识。
const String kCmccFailUnknownUnit = '通用流量的单位码不认识，不敢换算。';

/// B 路线失败的可读原因。
const String kCmccFailNoText = '页面文字里也没认出通用流量。';

/// 运营商侧维护中。
const String kCmccFailMaintenance = '运营商侧在维护（掌厅自己这么说的），稍后再试。';

/// 页面还是登录页。
const String kCmccFailNeedLogin = '页面还在登录页：请先在里面登录。';

/// 页面既不像登录页也不像首页。
const String kCmccFailUnknownPage = '页面既不像登录页也不像首页。';

// ---------------------------------------------------------------------------
// 单位与数值
// ---------------------------------------------------------------------------

/// 单位码 `03`（MB）→ GB 的换算系数（运营商计费按 1024 进制）。
const double kCmccMbPerGb = 1024;

/// 原始数值 + 单位码 → **GB**（认不出单位 / 单位不是流量 → null）。
///
/// 单位码：`01` 分钟、`02` 条、`03` MB、`04` GB。通话/短信的单位不是流量，
/// 换算成 GB 没有意义 → 返回 null（调用方据此说"读不到/不是流量"）。
double? cmccToGb(num? value, String? unitRaw) {
  if (value == null) return null;
  final unit = unitRaw?.trim();
  switch (unit) {
    case '04':
      return value.toDouble();
    case '03':
      return value.toDouble() / kCmccMbPerGb;
    default:
      return null;
  }
}

/// 一个余量节点（通用 / 定向 / 其他 / 总 通用一个结构）。
///
/// 四个数任意一个缺失就是 `null`（**不补 0**）；整节点"全是 0 或没有数"视作
/// **没给读数**（[isBlank]），界面据此显示"掌厅没给定向流量读数"。
class CmccQuota {
  /// 原始数值（未换算；单位见 [unitRaw]）。
  final double? used;
  final double? remain;
  final double? total;

  /// 单位码原文（`01`..`04`，认不出的码原样留着）。
  final String? unitRaw;

  const CmccQuota({this.used, this.remain, this.total, this.unitRaw});

  /// 单位中文（认不出 → null）。
  String? get unitLabel => unitRaw == null ? null : kCmccUnitLabels[unitRaw];

  /// 这个节点的单位是不是**流量**（GB / MB）。
  bool get isData => unitRaw == '03' || unitRaw == '04';

  /// 已用（GB；单位不是流量或没数 → null）。
  double? get usedGb => isData ? cmccToGb(used, unitRaw) : null;

  /// 剩余（GB）。
  double? get remainGb => isData ? cmccToGb(remain, unitRaw) : null;

  /// 总量（GB）。
  double? get totalGb => isData ? cmccToGb(total, unitRaw) : null;

  /// 一个数都没有。
  bool get isEmpty => used == null && remain == null && total == null;

  /// **没给读数**：一个数都没有，或三个数都是 0。
  ///
  /// 用"全 0 → 没给"这条规矩是产品要求：掌厅对"没有定向流量套餐"的号会回
  /// `0/0/0`，界面上显示成"已用 0.00 GB"会让人以为"我有定向流量但没用"。
  bool get isBlank {
    if (isEmpty) return true;
    final u = used ?? 0, r = remain ?? 0, t = total ?? 0;
    return u == 0 && r == 0 && t == 0;
  }

  /// 能不能拿到"已用 GB"（喂差值算法需要的就这一个数）。
  bool get hasUsedGb => usedGb != null;

  @override
  String toString() => 'CmccQuota(used=$used, remain=$remain, total=$total, '
      'unit=$unitRaw)';
}

/// 一次掌厅读数（结构化）。
class CmccReading {
  /// 通用流量（**必需**：读不到就没有读数）。
  final CmccQuota general;

  /// 定向流量（null = 掌厅没给读数）。
  final CmccQuota? directional;

  /// 其他 / 区域流量（null = 掌厅没给读数）。
  final CmccQuota? other;

  /// 总流量（null = 掌厅没给读数）。
  final CmccQuota? total;

  /// 数据来自哪条路线（C = 接口响应、B = 页面文字），界面据此标注来源。
  final CmccReadingSource source;

  const CmccReading({
    required this.general,
    this.directional,
    this.other,
    this.total,
    this.source = CmccReadingSource.api,
  });

  /// 喂给「流量计量」差值算法的那一个数：**通用流量已用（GB）**。
  double? get generalUsedGb => general.usedGb;
}

/// 读数来自哪条路线。
enum CmccReadingSource {
  /// C：钩到接口响应（最可信，结构化字段）。
  api,

  /// B：从页面文字里正则抠的（可能被文案变化打断）。
  pageText,
}

/// 解析结果：要么有读数、要么有一句可读的原因（两者不会同时有）。
class CmccParseResult {
  final CmccReading? reading;
  final String? error;

  const CmccParseResult.ok(CmccReading this.reading) : error = null;

  const CmccParseResult.failed(String this.error) : reading = null;

  bool get isOk => reading != null;
}

// ---------------------------------------------------------------------------
// C 路线：解密 + 解析接口响应
// ---------------------------------------------------------------------------

/// 响应体 → 明文（密文则解密；明文原样返回）。
///
/// 密文解不开时抛 [FormatException]（上层转成 [kCmccFailDecrypt] 那句人话）。
String decryptCmccPayload(String body) {
  final s = body.trim();
  if (!looksLikeCipherHex(s)) return s;
  final plain = aes128CbcDecrypt(
    Uint8List.fromList(ascii.encode(kCmccAesKey)),
    Uint8List.fromList(ascii.encode(kCmccAesIv)),
    hexToBytes(s),
  );
  return utf8.decode(plain, allowMalformed: true);
}

/// 从响应体里抽出"可能是载荷"的候选串（**按可信度排序**）。
///
/// 掌厅的返回形状不止一种（有的客户端拿到整个 body 就是 hex 密文，有的是
/// `{"data":"<hex>"}` 这种包了一层）。与其赌一种，不如都试一遍：
/// 明文 body 本身 + 顶层 JSON 里的每个字符串值。
List<String> cmccPayloadCandidates(String body) {
  final raw = body.trim();
  final out = <String>[raw];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is String) {
      for (final s in cmccPayloadCandidates(decoded)) {
        if (!out.contains(s)) out.add(s);
      }
    } else if (decoded is Map) {
      for (final v in decoded.values) {
        if (v is String && v.trim().isNotEmpty && !out.contains(v.trim())) {
          out.add(v.trim());
        }
      }
    }
  } catch (_) {
    // 不是 JSON（例如整段 hex）→ 就只有 raw 一个候选
  }
  return out;
}

/// 解析 **C 路线**的接口响应（先按规则解密，再读 `data.resultData` 的字段）。
///
/// 失败时给的一句原因能区分"没解不开"和"解开了但没这个字段"——用户看到的
/// 提示不同，排查时也一眼看得出是 key/IV 变了还是字段变了。
CmccParseResult parsePlanBody(String body) {
  if (body.trim().isEmpty) return const CmccParseResult.failed(kCmccFailNoResponse);
  var sawCipher = false;
  var decryptFailed = false;
  var jsonFailed = false;
  var sawJson = false;
  String? lastError;
  for (final candidate in cmccPayloadCandidates(body)) {
    String plain;
    if (looksLikeCipherHex(candidate)) {
      sawCipher = true;
      try {
        plain = decryptCmccPayload(candidate);
      } catch (_) {
        decryptFailed = true;
        continue;
      }
    } else {
      plain = candidate;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(plain);
    } catch (_) {
      jsonFailed = true;
      continue;
    }
    if (decoded is! Map) {
      jsonFailed = true;
      continue;
    }
    sawJson = true;
    final result = _readingFromJson(decoded);
    if (result.reading != null) return CmccParseResult.ok(result.reading!);
    // 记住第一句具体原因（通常是 body 本身的解析结果），别用笼统的话盖掉它
    lastError ??= result.error;
  }
  if (sawCipher && decryptFailed) {
    return const CmccParseResult.failed(kCmccFailDecrypt);
  }
  if (!sawJson && jsonFailed) {
    return const CmccParseResult.failed('响应的 JSON 结构看不懂。');
  }
  return CmccParseResult.failed(lastError ?? kCmccFailNoGeneral);
}

/// 从解出来的 JSON 里取读数；取不到就带上一句**具体**原因。
_CmccScopeParse _readingFromJson(Map<Object?, Object?> root) {
  final scope = _resultScope(root);

  final generalNode = _findQuota(scope, kCmccFlowWrappers, kCmccKeyGeneral);
  if (generalNode == null || generalNode.isBlank) {
    return const _CmccScopeParse.failed(kCmccFailNoGeneral);
  }
  if (generalNode.usedGb == null) {
    // 有数字但单位不是流量（01 分钟 / 02 条）或单位码认不出 → 说清是单位的问题
    return const _CmccScopeParse.failed(kCmccFailUnknownUnit);
  }
  return _CmccScopeParse.ok(CmccReading(
    general: generalNode,
    directional: _optQuota(scope, kCmccKeyDirectional),
    other: _optQuota(scope, kCmccKeyOther),
    total: _optQuota(scope, kCmccKeyTotal),
    source: CmccReadingSource.api,
  ));
}

/// 一层 JSON 的解析结果（读数 / 一句具体原因）。
class _CmccScopeParse {
  final CmccReading? reading;
  final String? error;

  const _CmccScopeParse.ok(CmccReading this.reading) : error = null;

  const _CmccScopeParse.failed(String this.error) : reading = null;
}

/// 找到真正挂着余量字段的那一层。
///
/// 实测的形状是 `data.resultData`（也可能某天变成 `resultData` 直挂、或
/// `data` 下直接给字段），所以**逐层往下走**最多 4 层，而不是赌一种。
Map<Object?, Object?> _resultScope(Map<Object?, Object?> root) {
  var scope = root;
  for (var i = 0; i < 4; i++) {
    final deeper = _findMap(scope, const ['resultData']) ??
        _findMap(scope, const ['data']);
    if (deeper == null) break;
    scope = deeper;
  }
  return scope;
}

/// 在 [scope] 里找通用流量节点：先按 [wrappers] 找容器、再按 [key] 找节点，
/// 也容忍"节点直接挂在 scope 上"。
CmccQuota? _findQuota(
    Map<Object?, Object?> scope, List<String> wrappers, String key) {
  final direct = _toQuota(scope[key]);
  if (direct != null) return direct;
  for (final wrap in wrappers) {
    final inner = scope[wrap];
    if (inner is Map) {
      final q = _toQuota(inner[key]);
      if (q != null) return q;
    }
  }
  return null;
}

/// 可选的节点（定向/其他/总）：没有、或者"没给读数"（全 0）→ null。
///
/// 同样是"容器里也找一遍"：调研给的形状里，定向/其他/总 跟通用是**同一个容器
/// （`planRemianFlowInfo`）下的兄弟节点**，只在 scope 上找会全漏。
CmccQuota? _optQuota(Map<Object?, Object?> scope, String key) {
  final q = _findQuota(scope, kCmccFlowWrappers, key);
  if (q == null || q.isBlank) return null;
  return q;
}

/// 深度优先找一个 key（`resultData` 可能挂在 `data` 下，也可能在根上）。
Map<Object?, Object?>? _findMap(Map<Object?, Object?> root, List<String> keys) {
  for (final k in keys) {
    final v = root[k];
    if (v is Map) return v.cast<Object?, Object?>();
  }
  return null;
}

/// 任意形状 → [CmccQuota]（不是 Map 或三个数全缺 → null）。
CmccQuota? _toQuota(Object? raw) {
  if (raw is! Map) return null;
  final q = CmccQuota(
    used: _num(raw['usedNum']),
    remain: _num(raw['remainNum']),
    total: _num(raw['sumNum']),
    unitRaw: _unit(raw['unit']),
  );
  return q.isEmpty ? null : q;
}

/// 数值字段容错：数字 / 数字字符串（可能带单位后缀或空格）。
double? _num(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    final s = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }
  return null;
}

/// 单位字段：`04` / `"04"` / `4` 都收，统一成两位码。
String? _unit(Object? raw) {
  if (raw is num) return raw.toInt().toString().padLeft(2, '0');
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final n = int.tryParse(s);
    return n == null ? s : n.toString().padLeft(2, '0');
  }
  return null;
}

// ---------------------------------------------------------------------------
// B 路线：从页面文字里抠数字
// ---------------------------------------------------------------------------

/// 页面上表示"已用 / 剩余 / 总量"的字样（正则用；顺序即优先级）。
const List<String> kCmccUsedWords = ['已用', '已使用', '使用量', '已用量'];
const List<String> kCmccRemainWords = ['剩余', '余量', '可用', '还可'];
const List<String> kCmccTotalWords = ['总量', '总共', '合计', '总计'];

/// 页面上通用 / 定向 / 其他 / 总 的字样（正则用）。
const String kCmccWordGeneral = '通用';
const String kCmccWordDirectional = '定向';
const String kCmccWordOther = '其他';
const String kCmccWordTotal = '总';

/// **B 路线**：从页面可见文字里抠出读数。
///
/// 只在 C 拿不到响应时走。识别范围刻意保守：
/// - 只认带单位（GB/MB/G/M）的数字，不认裸数字（页面上裸数字太多，认了就是瞎猜）；
/// - 「通用」那一段必须有"已用"（或者同时有"总量"和"剩余"→ 相减推算）；
/// - 抠不到 → 失败并给可读原因（[kCmccFailNoText]），**不猜**。
CmccParseResult parsePageText(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return const CmccParseResult.failed(kCmccFailNoText);

  final generalWindow = _windowFor(flat, kCmccWordGeneral);
  final general = _quotaFromWindow(generalWindow);
  if (general == null || general.usedGb == null) {
    return const CmccParseResult.failed(kCmccFailNoText);
  }
  CmccQuota? opt(String word) {
    final q = _quotaFromWindow(_windowFor(flat, word));
    return (q == null || q.isBlank) ? null : q;
  }

  return CmccParseResult.ok(CmccReading(
    general: general,
    directional: opt(kCmccWordDirectional),
    other: opt(kCmccWordOther),
    total: _totalWindow(flat) ?? opt('总流量'),
    source: CmccReadingSource.pageText,
  ));
}

/// 取"某个词"到"下一个词"（或窗口上限）之间的那段文字。
String _windowFor(String flat, String word) {
  final start = flat.indexOf(word);
  if (start < 0) return '';
  var end = flat.length;
  for (final other in const [
    kCmccWordGeneral,
    kCmccWordDirectional,
    kCmccWordOther,
    '话费',
    '语音',
    '短信',
  ]) {
    if (other == word) continue;
    final at = flat.indexOf(other, start + word.length);
    if (at >= 0 && at < end) end = at;
  }
  // 窗口上限 60 字：够放下"已用 6.05GB 剩余 73.95GB"，不至于串到别的区块
  if (end - start > 60) end = start + 60;
  return flat.substring(start, end);
}

/// 在窗口里找「已用 / 剩余 / 总量」三个数（都带单位才认）。
///
/// B 路线抠出来的数**一律先归一到 GB**再存（所以单位码固定写 `04`）：
/// 页面可能混合写着「总量 80GB / 已用 2048MB」，只有先把两个数放到同一单位，
/// 「总量 − 剩余」这种推算才是对的。
CmccQuota? _quotaFromWindow(String window) {
  if (window.isEmpty) return null;
  final used = _pickGb(window, kCmccUsedWords);
  final remain = _pickGb(window, kCmccRemainWords);
  final total = _pickGb(window, kCmccTotalWords);
  var u = used;
  // 没有"已用"但给了"总量 + 剩余" → 相减推算（如实按 GB 记）
  if (u == null && total != null && remain != null) u = total - remain;
  if (u == null && total == null && remain == null) return null;
  final q = CmccQuota(used: u, remain: remain, total: total, unitRaw: '04');
  return q.isEmpty ? null : q;
}

/// 总流量窗口：页面常写「总流量」而不是"总的余量节点"，单独捞一次。
CmccQuota? _totalWindow(String flat) {
  for (final word in const ['总流量', '合计流量', '总用量']) {
    final q = _quotaFromWindow(_windowFor(flat, word));
    if (q != null && !q.isBlank) return q;
  }
  return null;
}

/// 在窗口里找词后紧跟的数字 + 单位（`已用 6.05GB` / `已用：6.05 GB`），
/// 返回**换算成 GB 的数值**；找不到 → null。
double? _pickGb(String window, List<String> words) {
  for (final word in words) {
    final at = window.indexOf(word);
    if (at < 0) continue;
    final tail = window.substring(at + word.length, window.length);
    final m = RegExp(r'[^0-9]{0,4}?([0-9]+(?:\.[0-9]+)?)\s*(GB|Gb|gb|G|MB|Mb|mb|M)')
        .firstMatch(tail);
    if (m == null) continue;
    final value = double.tryParse(m.group(1)!);
    if (value == null) continue;
    final isMb = m.group(2)!.toUpperCase().startsWith('M');
    return isMb ? value / kCmccMbPerGb : value;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 页面分类（登录页 / 维护中 / 首页 / 不认识）
// ---------------------------------------------------------------------------

/// 页面当前处在什么状态。
enum CmccPageKind {
  /// 还是登录页（要点手机号验证码那一步）。
  login,

  /// 运营商侧维护中（掌厅自己弹的公告）。
  maintenance,

  /// 登录后的首页（含余量数据）。
  home,

  /// 不认识（既不像登录页也不像首页）。
  unknown,
}

/// 登录页特征词。
const List<String> kCmccLoginMarkers = ['获取验证码', '验证码登录', '请登录', '立即登录'];

/// 维护提示特征词。
const List<String> kCmccMaintenanceMarkers = ['系统优化升级', '升级公告', '正在维护'];

/// 登录后首页特征词（**登录成功判据**）。
const List<String> kCmccHomeMarkers = ['话费余额', '余额', '套餐', '余量', '退出', '我的'];

/// 判定页面处于哪个状态。
///
/// 顺序是**登录页 → 维护 → 首页**：登录页上出现"余额/我的"这类词的可能是
/// 页面底部的营销文案，先判登录页最不容易误判；维护提示通常在首页主内容区，
/// 排在首页判据前。误判也不会把人堵死——界面一直有「打开掌厅页面」这个出口
/// （路线 D），用户能自己看页面。
CmccPageKind classifyCmccPage(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return CmccPageKind.unknown;
  bool has(List<String> words) => words.any(flat.contains);
  if (has(kCmccLoginMarkers)) return CmccPageKind.login;
  if (has(kCmccMaintenanceMarkers)) return CmccPageKind.maintenance;
  if (has(kCmccHomeMarkers)) return CmccPageKind.home;
  return CmccPageKind.unknown;
}

/// 页面状态 → 一句给用户看的话（可读的原因，不静默）。
String cmccKindMessage(CmccPageKind kind) {
  switch (kind) {
    case CmccPageKind.login:
      return kCmccFailNeedLogin;
    case CmccPageKind.maintenance:
      return kCmccFailMaintenance;
    case CmccPageKind.home:
      return '页面已加载，正在读数字…';
    case CmccPageKind.unknown:
      return kCmccFailUnknownPage;
  }
}

// ---------------------------------------------------------------------------
// 会话失效判定
// ---------------------------------------------------------------------------

/// 「这条响应 / 这段文字说明会话没了」的特征词。
///
/// 刻意收得很窄：只认明确的"未登录"字样，不认"登录"（首页页头就有"登录/退出"
/// 之类字样，认了会误判成失效 → 平白让用户去重收一次短信）。
const List<String> kCmccSessionExpiredMarkers = [
  '未登录',
  '请登录',
  '登录已过期',
  '重新登录',
  '会话已失效',
  'sessionId无效',
  'SESSIONID无效',
];

/// 会话是不是失效了（纯函数）。
///
/// 命中 → 上层**停止自动轮询**、只提示用户重登（绝不代发验证码，见
/// `cmcc_poll_policy.dart` 与 `lib/pages/cmcc_page.dart`）。
bool looksLikeSessionExpired(String bodyOrText) {
  if (bodyOrText.isEmpty) return false;
  for (final marker in kCmccSessionExpiredMarkers) {
    if (bodyOrText.contains(marker)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// 手机号脱敏
// ---------------------------------------------------------------------------

/// 手机号 → 尾号 4 位（`****1234`）；不是 11 位手机号 → null。
///
/// **日志与界面只用这个函数的结果**：全号只进 secure storage，不落日志、
/// 不落 SharedPreferences（见 `cmcc_session_store.dart`）。
String? cmccPhoneTail(String? phone) {
  final s = phone?.replaceAll(RegExp(r'\D'), '') ?? '';
  if (s.length < 4) return null;
  return '****${s.substring(s.length - 4)}';
}
