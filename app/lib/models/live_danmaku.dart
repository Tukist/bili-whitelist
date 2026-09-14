/// 直播弹幕的纯数据模型（协议载荷 + 弹幕服务器信息），无网络、无 Flutter 依赖，
/// 全部可单测。
///
/// 事实来源（2026-09 实测确认，照抄不要重新探测）：
/// - 弹幕服务器信息：`GET https://api.live.bilibili.com/xlive/web-room/v1/index/
///   getDanmuInfo`（**必须 WBI 签名**，否则一律 `code=-352`）→
///   `data.token` + `data.host_list`（见 [LiveDanmuInfo]）
/// - WS 连接：`wss://<host>:<wss_port>/sub`，包格式 = 16 字节大端头 + body
/// - `DANMU_MSG` 的 `info` 是 18 元素数组，本文件按下表取字段：
///
///   | 位置 | 含义 |
///   |---|---|
///   | `info[0][1]` | 模式（1=滚动 4=底部 5=顶部） |
///   | `info[0][3]` | 颜色（十进制，如 16777215） |
///   | `info[0][4]` | 时间戳（毫秒，**直播不用它**：没有进度轴，时间轴由进房时钟给） |
///   | `info[1]` | 弹幕文本 |
///   | `info[2][0]` | uid（匿名态为 0） |
///   | `info[2][1]` | 用户名（**匿名态被服务端打码**，实测 `远***`；登录态未验证） |
///   | `info[3]` | 粉丝牌 `[等级, 牌子名, 主播名]`，无牌子为 `[]`（不用） |
///   | `info[4][0]` | 用户等级（不用） |
///
/// 为什么单独建模型（而不是直接复用 [Danmaku]）：[Danmaku] 只有渲染需要的
/// 五个字段，直播协议里还带 uid/用户名（排障与单测要断言字段位置对不对），
/// 且它的 `timeSec` 语义是「视频时间轴秒」——直播要换算成「进房秒」，所以
/// 解析结果先落在 [LiveDanmakuMessage]，由服务层补时间轴后转 [Danmaku]。
library;

import 'danmaku.dart';

/// 直播弹幕服务器的一个接入点（`data.host_list[]` 的一项）。
///
/// `host_list` 里的项**不保证能用**（实测 `host_list[0]` 也可能连不上），
/// 调用方必须逐个兜底尝试，故这里做成有序列表由服务层轮询。
class LiveDanmuHost {
  const LiveDanmuHost({
    required this.host,
    required this.wssPort,
    required this.wsPort,
  });

  /// 主机名（不含 scheme/port，如 `tx-sh-live-comet-04.chat.bilibili.com`）。
  final String host;

  /// wss 端口（实测 2245）。
  final int wssPort;

  /// 明文 ws 端口（实测 2244；本项目只用 wss，保留字段供排障日志）。
  final int wsPort;

  /// WS 接入地址：`wss://<host>:<wss_port>/sub`。
  Uri get wssUri => Uri.parse('wss://$host:$wssPort/sub');

  /// 宽松解析：host 非空且 wss 端口有效才认（脏条目返回 null 由调用方丢弃）。
  static LiveDanmuHost? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final host = raw['host'];
    if (host is! String || host.isEmpty) return null;
    final wssPort = looseLiveInt(raw['wss_port']);
    if (wssPort == null || wssPort <= 0) return null;
    return LiveDanmuHost(
      host: host,
      wssPort: wssPort,
      wsPort: looseLiveInt(raw['ws_port']) ?? 0,
    );
  }

  @override
  String toString() => '$host:$wssPort';
}

/// 弹幕服务器信息（`getDanmuInfo` 的 `data`）。
class LiveDanmuInfo {
  const LiveDanmuInfo({
    required this.token,
    required this.hosts,
    this.uid = 0,
  });

  /// 认证用的 token（**会过期**：重连必须重新取，不要长期缓存）。
  final String token;

  /// 可接入的服务器列表（按响应顺序 = 服务端给的推荐顺序）。
  final List<LiveDanmuHost> hosts;

  /// 认证 body 里的 `uid`：登录态 = 我的 mid，匿名 = 0（实测 0 也能收到
  /// 真实弹幕，只是用户名被服务端打码）。
  final int uid;

  /// 是否可用（token 与至少一个 host 都在）。
  bool get isUsable => token.isNotEmpty && hosts.isNotEmpty;

  /// 宽松解析：token 缺失或 host_list 全脏 → null（调用方静默降级）。
  static LiveDanmuInfo? fromJson(Map<String, dynamic> data, {int uid = 0}) {
    final token = data['token'];
    if (token is! String || token.isEmpty) return null;
    final hosts = <LiveDanmuHost>[];
    final rawList = data['host_list'];
    if (rawList is List) {
      for (final raw in rawList) {
        final host = LiveDanmuHost.fromJson(raw);
        if (host != null) hosts.add(host);
      }
    }
    if (hosts.isEmpty) return null;
    return LiveDanmuInfo(token: token, hosts: hosts, uid: uid);
  }

  @override
  String toString() =>
      'LiveDanmuInfo(uid=$uid token=${token.isEmpty ? '无' : '${token.length}字符'} '
      'hosts=$hosts)';
}

/// 一条直播弹幕的协议载荷（`DANMU_MSG` 的字段提炼，见文件头字段表）。
class LiveDanmakuMessage {
  const LiveDanmakuMessage({
    required this.text,
    required this.mode,
    required this.color,
    required this.uid,
    required this.uname,
  });

  /// 弹幕文本（已 trim；空文本视为脏数据丢弃）。
  final String text;

  /// 模式：1=滚动 4=底部 5=顶部（其它值渲染层按滚动处理）。
  final int mode;

  /// 颜色（ARGB int，由协议里的十进制 RGB 补全 alpha 0xFF）。
  final int color;

  /// 发送者 uid（匿名态 0）。
  final int uid;

  /// 发送者用户名（匿名态被服务端打码，可能为空串）。
  final String uname;

  /// 弹幕模式标识串（排障日志用：`DANMU_MSG:4:0:2:2:2:0` → `DANMU_MSG`）。
  static const String cmdPrefix = 'DANMU_MSG';

  /// 从一条 WS 明文 JSON 消息解析弹幕；**不是弹幕消息 / 结构异常 → null 不抛**
  /// （实测同一批还会来 INTERACT_WORD_V2 / WATCHED_CHANGE / ONLINE_RANK_COUNT /
  /// LOG_IN_NOTICE / STOP_LIVE_ROOM_LIST 等 cmd，一律忽略即可）。
  static LiveDanmakuMessage? fromMessageJson(Map<String, dynamic> msg) {
    final cmd = msg['cmd'];
    // cmd **可能带后缀**（实测 `DANMU_MSG:4:0:2:2:2:0`）→ 必须 startsWith
    if (cmd is! String || !cmd.startsWith(cmdPrefix)) return null;
    final info = msg['info'];
    if (info is! List || info.length < 3) return null;
    final meta = info[0];
    final rawText = info[1];
    if (rawText is! String) return null;
    final text = rawText.trim();
    if (text.isEmpty) return null;
    // mode：meta[1]（缺/类型异常 → 1 滚动，与渲染层「其它值按滚动」一致）
    final mode = (meta is List && meta.length > 1)
        ? (looseLiveInt(meta[1]) ?? 1)
        : 1;
    // color：meta[3] 十进制 RGB（无 alpha）→ ARGB；缺失 → 白
    final colorRaw = (meta is List && meta.length > 3)
        ? looseLiveInt(meta[3])
        : null;
    final color = ((colorRaw ?? 0xFFFFFF) & 0xFFFFFF) | 0xFF000000;
    // 发送者：info[2] = [uid, 用户名, ...]
    final user = info[2];
    final uid = (user is List && user.isNotEmpty)
        ? (looseLiveInt(user[0]) ?? 0)
        : 0;
    final uname = (user is List && user.length > 1 && user[1] is String)
        ? user[1] as String
        : '';
    return LiveDanmakuMessage(
      text: text,
      mode: mode,
      color: color,
      uid: uid,
      uname: uname,
    );
  }

  /// 转成渲染层认识的 [Danmaku]（[timeSec] = 进房秒数，由服务层按进房时钟给）。
  ///
  /// 字号固定 25（B 站直播弹幕不带字号档；25 是 [danmakuDisplayFontSize] 的
  /// 「普通」档，与 VOD 弹幕观感一致）。
  Danmaku toDanmaku(double timeSec) => Danmaku(
        timeSec: timeSec,
        mode: mode,
        fontSize: 25,
        color: color,
        text: text,
      );

  @override
  String toString() => 'LiveDanmakuMessage($uname/$uid "$text" '
      'mode=$mode color=#${(color & 0xFFFFFF).toRadixString(16)})';
}

/// 从 WS 帧里拆出的**一个协议包**的解析结果。
class LiveDanmakuEvent {
  const LiveDanmakuEvent({
    required this.operation,
    this.json,
    this.popularity,
    this.danmaku,
  });

  /// `operation` 字段原值：5=业务消息、8=认证回复、3=心跳回复。
  final int operation;

  /// 明文 JSON（消息包 / 认证回复）；非 JSON 或解压失败为 null。
  final Map<String, dynamic>? json;

  /// 心跳回复的人气值（`operation=3` 的 body 4 字节大端；不足 4 字节为 null）。
  final int? popularity;

  /// 该包若是 `DANMU_MSG` → 解析出的弹幕载荷（其它 cmd 为 null）。
  final LiveDanmakuMessage? danmaku;

  /// 是否认证回复（`operation=8`）。
  bool get isAuthReply => operation == 8;

  /// 认证回复的业务码（`{"code":0}` 才算成功；非 JSON/缺字段 → null）。
  int? get authCode => looseLiveInt(json?['code']);

  /// 消息包（`operation=5`）构造：顺带解析弹幕（非弹幕 cmd → danmaku=null）。
  factory LiveDanmakuEvent.message(Map<String, dynamic> json) =>
      LiveDanmakuEvent(
        operation: 5,
        json: json,
        danmaku: LiveDanmakuMessage.fromMessageJson(json),
      );

  @override
  String toString() => 'LiveDanmakuEvent(op=$operation'
      '${danmaku != null ? ' $danmaku' : ''}'
      '${json != null && danmaku == null ? ' cmd=${json!['cmd']}' : ''}'
      '${popularity != null ? ' 人气=$popularity' : ''})';
}

/// 宽松取整数：num 直接转、数字串容错解析，其余（null / Map / 布尔…）→ null。
/// （协议里偶发把数字给成字符串，硬转 `as int` 会直接抛；脏响应不该让整条链路崩。）
int? looseLiveInt(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}
