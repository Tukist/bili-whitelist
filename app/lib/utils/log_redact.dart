/// 日志脱敏（v2.67.0）：所有要落盘 / 要给人看的日志文本都先过这里。
///
/// ## 为什么搬到 `utils/`
///
/// 这套规则原本长在 `services/update_service.dart` 里（v2.46.0，只因最早是
/// 「更新下载地址带 `X-Amz-Signature`」这一个场景逼出来的）。v2.67.0 起日志
/// 要**全量落盘 + 一键导出给开发者**，脱敏不再是更新业务的内务，而是所有日志
/// 的公共前置步骤 —— 所以搬到 utils，更新侧保留同名静态方法做 delegate
/// （`UpdateService.maskUrlForLog` / `sanitizeLogText`，老调用点与老单测零改动）。
///
/// ## 两类脱敏，两种力度
///
/// - [maskUrlForLog]：**一个 URL** 只留 `host + path`。query 里可能有
///   `X-Amz-Signature`（GitHub 302 到签名 CDN 的下载凭据）、`deadline` +
///   `sign`（B 站字幕 / 播放地址的时效签名）—— 这类凭据一旦漏进日志就**收不
///   回来**，所以整条 query 直接丢掉，不做"挑几个参数打码"的聪明事。
/// - [sanitizeLogText]：**一整段文本**先把其中每个 URL 按上面的规则截短，再把
///   常见凭据形态换成占位符（保留键名，便于识别是哪一类）。
///
/// 占位符统一写成 `<已脱敏>`，前面保留键名（`SESSDATA=<已脱敏>`）：
/// 排查时"这里原本是 SESSDATA"是有用信息，值本身不是。
library;

/// 日志用 URL 脱敏：**只留 host + path**（行为与 v2.46.0 逐字一致）。
///
/// 为什么必须脱敏：私有仓库的下载地址是 GitHub 302 到签名 CDN，
/// `?X-Amz-Signature=…` 这类下载凭据就在 query 里 —— 完整 URL 落日志等于把
/// 下载凭据写进 logcat。B 站的字幕 / 播放地址同理（`deadline` + `sign`）。
///
/// - 空串 → `(空 URL)`（不是空串：日志里要能看出"这里有个 URL，但是空的"）
/// - 不像 URL（没有 scheme 或没有 host）→ `<非绝对 URL，已省略>`
String maskUrlForLog(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '(空 URL)';
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return '<非绝对 URL，已省略>';
  return '${uri.host}${uri.path}';
}

/// 具名凭据：`键=值` / `键: 值` / JSON 的 `"键":"值"` → 值换成 `<已脱敏>`。
///
/// 覆盖的是本项目真正会碰到的几类，而不是"所有像密钥的东西"：
/// - B 站登录态：`SESSDATA` / `bili_jct`（CSRF）/ `csrf` / `access_key` /
///   `access_token` / `refresh_token` / `bili_ticket`
/// - B 站接口签名时效：`deadline` / `sign`
/// - 对象存储签名：`X-Amz-Signature`（必须排在 `sign` 之前，或者说 `\bsign=`
///   本身就不会命中 `Signature`，两条并存没问题）
///
/// `\b` 前缀避免把 `design=`、`xsrf=` 之类误认成凭据；分隔符 `[:=]` 同时覆盖
/// query / cookie 串、`键: 值` 这种手写形态，键名两侧允许成对的引号（JSON）。
/// 值到 `&` `;` 空白 引号 逗号为止（query / cookie 串 / 请求头三种常见分隔符）。
/// 回填时原样保留"引号 + 分隔符"（[RegExpMatch.group] 2），所以
/// `"a":"b"` → `"a":"<已脱敏>"` 依旧是合法 JSON。
final RegExp _credentialPattern = RegExp(
  r'''\b(SESSDATA|bili_jct|csrf|access_key|access_token|refresh_token|bili_ticket|deadline|sign|X-Amz-Signature)(["']?\s*[:=]\s*["']?)([^&;\s,"']+)''',
  caseSensitive: false,
);

/// 搜索词：`keyword=xxx` / `key_word: xxx` → 键名留下，值打码。
///
/// 搜索结果页会把用户搜的词原样打进日志（`searchLive keyword=… page=…`），
/// 这些日志会长期留在手机上、还随 zip 导出 —— 搜索词能反推用户在关注什么，
/// 属于不该落盘的个人信息。值一直吃到行尾或 `&` / `;` / `,` / 引号为止，但
/// **遇到下一个 `键=`**（`page=2` 这类）就收手，别把后面的排查信息一起吃掉。
final RegExp _keywordPattern = RegExp(
  r'''\b(keyword|key_word)(["']?\s*[:=]\s*["']?)(.*?)(?=\s+[A-Za-z_][A-Za-z0-9_]*\s*[:=]|[,;&"']|\n|$)''',
  caseSensitive: false,
);

/// 手机号：11 位、1 开头、第二位 3~9（大陆手机号形态）。
///
/// 前后都不许还有数字：`(^|[^0-9])` 当前置边界，`(?![0-9])` 当后置边界 ——
/// 这样 13 位时间戳、`BV` 号里的数字串都不会被误伤（宁可少打码，不可把
/// 排查用的数字全抹掉）。
final RegExp _phonePattern = RegExp(r'(^|[^0-9])(1[3-9][0-9]{9})(?![0-9])');

/// 日志文本脱敏（v2.67.0 扩表；v2.46.0 的两条行为逐字不变）。
///
/// 顺序是有讲究的：
/// 1. **先截 URL** —— query 里的凭据随整条 query 一起消失，后面几条规则就
///    不会在已经被截短的文本上白跑；
/// 2. **再 Authorization 头**（整段替换，避免把 `Bearer` 后的值当成普通单词）；
/// 3. 然后 `Bearer`（Authorization 之外的出错路径也会单带一段 Bearer token）；
/// 4. 具名凭据（`键=值` / `键: 值` / JSON）；
/// 5. 搜索词（`keyword=` / `key_word=`）—— 能反推用户在关注什么，不落盘；
/// 6. GitHub token 形态（`ghp_…` / `github_pat_…`）—— 这条必须**单独留**：
///    `token=ghp_xxx` 里没有上面任何一个键名，老单测钉的就是它；
/// 7. 最后手机号（纯数字，放最后不影响前面任何规则）。
///
/// `null` → `—`（不是字符串 `"null"`：日志里要能一眼分清"没有值"和"值是
/// null 这两个字"）。
String sanitizeLogText(Object? raw) {
  if (raw == null) return '—';
  var text = raw.toString();
  text = text.replaceAllMapped(
    RegExp(r'''https?://[^\s"'<>]+'''),
    (m) => maskUrlForLog(m[0]!),
  );
  text = text.replaceAllMapped(
    // `(?:\w+\s+)?` 吃掉 scheme（`Bearer abc` / `Basic dXNlcjpwYXNz`）：
    // 只吃 `\S+` 的话 scheme 会被当成凭据本身，真 token 留在原地。
    // 键名按原文大小写回填（排查时 `authorization` / `Authorization` 都可能出现）。
    RegExp(
      "(Authorization)\\s*:\\s*(?:\\w+\\s+)?[^\\s,;\"']+",
      caseSensitive: false,
    ),
    (m) => '${m[1]}: <已脱敏>',
  );
  text = text.replaceAll(
    RegExp(r'Bearer\s+\S+', caseSensitive: false),
    'Bearer <已脱敏>',
  );
  text = text.replaceAllMapped(
    _credentialPattern,
    // 分隔符（含 JSON 的引号）原样回填：`SESSDATA=abc` → `SESSDATA=<已脱敏>`，
    // `"SESSDATA":"abc"` → `"SESSDATA":"<已脱敏>"`（两边引号仍在，JSON 不坏）。
    (m) => '${m[1]}${m[2]}<已脱敏>',
  );
  text = text.replaceAllMapped(
    _keywordPattern,
    (m) => '${m[1]}${m[2]}<已脱敏>',
  );
  text = text.replaceAll(
    RegExp(r'gh[a-z]*_[A-Za-z0-9_]{20,}'),
    '<token 已脱敏>',
  );
  text = text.replaceAllMapped(
    _phonePattern,
    (m) => '${m[1]}<手机号已脱敏>',
  );
  return text;
}
