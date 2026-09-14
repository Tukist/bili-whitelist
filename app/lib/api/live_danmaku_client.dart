/// 直播弹幕数据源：弹幕服务器信息（WBI 签名）+ WS 包解析 + 可注入的 WS 连接。
///
/// ## 协议（2026-09 实测确认，照抄不要重新探测）
/// - 弹幕服务器信息走 [BiliApi.fetchLiveDanmuInfo]（**必须 WBI 签名**，否则
///   一律 `code=-352`）；拿到 `token` 与 `host_list` 后才能连 WS。
/// - WS：`wss://<host>:<wss_port>/sub`，握手要带 `Origin/Referer:
///   https://live.bilibili.com`（同 [LiveDanmakuClient.wsHeaders]）+ 浏览器 UA。
/// - 所有包都是 **16 字节大端头 + body**：
///   `packetLen(u32) | headerLen(u16, 固定 16) | protoVer(u16) | operation(u32) |
///   sequence(u32)`
///   - `operation=7` 认证（客户端发，body = JSON）
///   - `operation=8` 认证回复（`{"code":0}` 才算成功）；⚠️ **包头 protoVer
///     实测是 1**（服务端按客户端包头的编码位回声），解析侧对 op=8 同时
///     容忍 0 与 1（见 [_handleLiveBody] 的注释，别改回只认 0）
///   - `operation=2` 心跳（客户端发，**body 空**）→ 服务端回 `operation=3`
///   - `operation=5` 消息包（`protoVer=2` = 压缩 body）
/// - **压缩是「带 zlib 头」的 zlib**（body 前 4 字节 `78 da`）→ 用
///   `ZLibCodec()`（默认 raw:false）能解；用 raw deflate 会失败
///   （`invalid stored block lengths`）。⚠️ **不要和 VOD 弹幕 XML 的
///   `Content-Encoding: deflate`（那个确实是 raw deflate，见
///   `bilibili_api.dart` 的弹幕接口）搞混**——两条路径的压缩格式不同。
///   稳妥做法：先带头解，失败再兜底 raw（见 [_inflateZlib]）。
/// - 解压出来的**仍是「16 字节头 + body」的包序列**（内层），必须递归拆；
///   内层 `protoVer=0` = 明文 JSON。实测本房间没有嵌套二次压缩，但递归必须留。
/// - `protoVer=0` 的**明文 JSON 包也要处理**（实测会收到 LOG_IN_NOTICE /
///   STOP_LIVE_ROOM_LIST 这类非压缩包，不能只处理压缩包）。
/// - 我们固定请求 `protoVer=2`，实测服务端按 2 返回 → **不需要 brotli、不需要
///   任何新依赖**；万一收到 `protoVer=3`（brotli）按「不支持」跳过，不为它引包。
///
/// ## 为什么要抽象 [LiveSocket]
/// 单测要覆盖「认证包内容 / 认证后立刻心跳 / 周期心跳 / 断线重连」这些时序，
/// 真连网既慢又不可控（本机 IP 还被风控过）。用一个最小接口把 WS 换成假实现，
/// 服务层就能在毫秒级假时钟下断言完整交互序列——见 [LiveSocketConnector]。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/live_danmaku.dart';
import 'bilibili_api.dart';

/// 协议固定头长度（字节）。
const int kLivePacketHeaderLen = 16;

/// `operation`：客户端心跳（body 空）。
const int kLiveOpHeartbeat = 2;

/// `operation`：心跳回复（body 4 字节人气值）。
const int kLiveOpHeartbeatReply = 3;

/// `operation`：业务消息（弹幕/礼物/进场等都在这类包里）。
const int kLiveOpMessage = 5;

/// `operation`：客户端认证。
const int kLiveOpAuth = 7;

/// `operation`：认证回复（body `{"code":0}`）。
const int kLiveOpAuthReply = 8;

/// `protoVer`：明文（body 是 JSON 或 4 字节人气值）。
const int kLiveProtoVerJson = 0;

/// `protoVer`：zlib 压缩（我们固定请求这个）。
const int kLiveProtoVerZlib = 2;

/// `protoVer`：brotli 压缩（不引依赖，收到即跳过）。
const int kLiveProtoVerBrotli = 3;

/// 认证时请求的 `protover`（**body 里的压缩协商字段**）：实测请求 2，服务端
/// 就按 2（zlib）返回，无需 brotli。
const int kLiveAuthProtoVer = 2;

/// 客户端发出包的**头部** `protoVer`（编码标识，恒 1）。
///
/// ⚠️ 别和 [kLiveAuthProtoVer] 混：头部 protoVer 描述「本包 body 怎么编码」
/// （客户端发的认证/心跳 body 一律是明文 JSON 或空，故取 1，与 B 站 web 端和
/// 主流实现一致）；body 里 JSON 的 `protover: 2` 才是**要服务端用 zlib 发消息**
/// 的协商字段。服务端对认证/心跳包不校验头部该字段，但保持与官方客户端一致
/// 更稳。
const int kLiveClientProtoVer = 1;

/// 递归拆包的最大深度（防脏数据/恶意嵌套把栈打爆；实测只有一层）。
const int _kMaxNestDepth = 4;

/// 组一个协议包：16 字节大端头 + body。
///
/// [protoVer] 是**头部编码标识**（客户端发包恒 [kLiveClientProtoVer]=1，
/// 见该常量的说明——它不是认证 body 里的压缩协商字段）。
Uint8List buildLivePacket(
  int operation, {
  Uint8List? body,
  int protoVer = kLiveClientProtoVer,
}) {
  final payload = body ?? Uint8List(0);
  final total = kLivePacketHeaderLen + payload.length;
  final out = Uint8List(total);
  final view = ByteData.sublistView(out);
  view.setUint32(0, total, Endian.big); // packetLen
  view.setUint16(4, kLivePacketHeaderLen, Endian.big); // headerLen
  view.setUint16(6, protoVer, Endian.big); // protoVer（编码标识）
  view.setUint32(8, operation, Endian.big); // operation
  view.setUint32(12, 1, Endian.big); // sequence（固定 1，服务端不看）
  out.setRange(kLivePacketHeaderLen, total, payload);
  return out;
}

/// 心跳包（`operation=2`，**body 空**）。
Uint8List buildLiveHeartbeatPacket() => buildLivePacket(kLiveOpHeartbeat);

/// 认证包（`operation=7`，body = 认证 JSON）。
///
/// [uid] 登录态填我的 mid、匿名填 0（实测 0 也能收到真实弹幕，只是用户名
/// 被服务端打码）；[token] 来自 `getDanmuInfo`（**会过期，重连要重新取**）。
Uint8List buildLiveAuthPacket({
  required int roomId,
  required String token,
  int uid = 0,
}) {
  final json = jsonEncode({
    'uid': uid,
    'roomid': roomId,
    'protover': kLiveAuthProtoVer,
    'platform': 'web',
    'type': 2,
    'key': token,
  });
  return buildLivePacket(kLiveOpAuth, body: Uint8List.fromList(utf8.encode(json)));
}

/// 拆一个 WS 帧 → 协议事件列表（**纯函数，可单测**）。
///
/// 容错（一律不抛，脏数据安全丢弃）：
/// - 一个帧里**可能拼多个包**（真实情况）→ 顺序全部拆出；
/// - 截断帧（`packetLen` 超出实际长度 / `headerLen < 16` / `packetLen` 为 0）
///   → 丢弃剩余字节并返回已解析的部分；
/// - 压缩包（`protoVer=2`）解不开 → 跳过该包（不影响同帧其它包）；
/// - `protoVer=3`（brotli）→ 跳过（不为它引依赖）。
List<LiveDanmakuEvent> parseLiveDanmakuFrames(Uint8List bytes) {
  final out = <LiveDanmakuEvent>[];
  _walkLivePackets(bytes, out, 0);
  return out;
}

/// 递归拆包：把 [data] 按「16 字节头 + body」逐包切开喂给 [_handleLiveBody]。
void _walkLivePackets(Uint8List data, List<LiveDanmakuEvent> out, int depth) {
  if (depth > _kMaxNestDepth) return;
  var offset = 0;
  while (offset + kLivePacketHeaderLen <= data.length) {
    final view = ByteData.sublistView(data);
    final packetLen = view.getUint32(offset, Endian.big);
    final headerLen = view.getUint16(offset + 4, Endian.big);
    final protoVer = view.getUint16(offset + 6, Endian.big);
    final operation = view.getUint32(offset + 8, Endian.big);
    // 非法/截断：headerLen 小于固定头（内层包也不可能更小）或包长越界
    // （含 packetLen=0）→ 剩余字节不可信，安全丢弃
    if (headerLen < kLivePacketHeaderLen ||
        packetLen < headerLen ||
        offset + packetLen > data.length) {
      debugPrint('[live_danmaku] 丢弃非法/截断包：offset=$offset '
          'packetLen=$packetLen headerLen=$headerLen 帧长=${data.length}');
      return;
    }
    final body =
        Uint8List.sublistView(data, offset + headerLen, offset + packetLen);
    _handleLiveBody(operation, protoVer, body, out, depth);
    offset += packetLen;
  }
}

/// 按「protoVer 决定编码、operation 决定语义」分派一个包的 body。
void _handleLiveBody(
  int operation,
  int protoVer,
  Uint8List body,
  List<LiveDanmakuEvent> out,
  int depth,
) {
  // 1) 压缩：解出来**仍是包序列** → 递归拆（内层 protoVer=0 才是明文）
  if (protoVer == kLiveProtoVerZlib) {
    final inflated = _inflateZlib(body);
    if (inflated == null) return; // 解不开：跳过该包，同帧其它包照常
    final before = out.length;
    _walkLivePackets(inflated, out, depth + 1);
    // 兜底：万一服务端直接塞了个 JSON 对象（实测没有，但脏数据不致命）
    if (out.length == before) {
      final json = _tryJsonMap(inflated);
      if (json != null) out.add(LiveDanmakuEvent.message(json));
    }
    return;
  }
  if (protoVer == kLiveProtoVerBrotli) {
    // 我们固定请求 protoVer=2，实测服务端按 2 返回；真收到 3 也不为它引依赖
    debugPrint('[live_danmaku] 收到 brotli（protoVer=3）包，本项目不支持 → 跳过');
    return;
  }
  // 2) 明文：按 operation 分派
  switch (operation) {
    case kLiveOpHeartbeatReply:
      // body = 4 字节大端人气值（不足 4 字节按 null，不影响弹幕）
      out.add(LiveDanmakuEvent(
        operation: operation,
        popularity:
            body.length >= 4 ? ByteData.sublistView(body).getUint32(0, Endian.big) : null,
      ));
    case kLiveOpAuthReply:
      // ⚠️ 认证回复的包头 protoVer **实测是 1**（服务端按客户端包头的编码位
      // 回声，见 [kLiveClientProtoVer]），不是 0 —— 所以这里**两种都接受**
      // （[kLiveProtoVerJson] / [kLiveClientProtoVer]）。
      // 历史教训（真机实测）：老实现要求 `protoVer == kLiveProtoVerJson`(0)，
      // 于是真机拿到的 `op=8 protoVer=1` 认证回复被整包丢掉（既不 debugPrint
      // 也不上报）→ 状态永远停在 connecting、`_onAuthReply` 里那次「认证成功
      // 后立刻发心跳」从不执行 → 60~130s 后被服务端断开并无限重连。
      // 改回「只认 0」之前先读这条。
      if (protoVer != kLiveProtoVerJson && protoVer != kLiveClientProtoVer) return;
      final authJson = _tryJsonMap(body);
      if (authJson == null) {
        // body 不是明文 JSON（理论上不会）：安全跳过，不抛
        debugPrint('[live_danmaku] 认证回复 body 非 JSON（protoVer=$protoVer '
            '长度=${body.length}）→ 跳过');
        return;
      }
      out.add(LiveDanmakuEvent(operation: operation, json: authJson));
    case kLiveOpMessage:
      if (protoVer != kLiveProtoVerJson) return;
      final json = _tryJsonMap(body);
      if (json == null) return;
      out.add(LiveDanmakuEvent.message(json));
    default:
      return; // 未知 operation：跳过
  }
}

/// 解压 zlib：**先按「带 zlib 头」解（实测格式），失败再兜底 raw deflate**。
///
/// 为什么这个顺序不能反：直播 WS 的 body 头 4 字节是 `78 da`（zlib 头），
/// 用 `ZLibCodec(raw: true)` 解会报 `invalid stored block lengths`；反过来
/// （先 raw）在真是 zlib 时必失败。两头都试一遍是零成本的稳妥做法。
Uint8List? _inflateZlib(Uint8List body) {
  try {
    return Uint8List.fromList(ZLibCodec().decode(body));
  } catch (_) {
    // 落到 raw deflate 兜底（万一某天服务端改用裸 deflate）
  }
  try {
    return Uint8List.fromList(ZLibCodec(raw: true).decode(body));
  } catch (e) {
    debugPrint('[live_danmaku] 压缩包解压失败（zlib/raw 都不行）：$e');
    return null;
  }
}

/// 宽松 JSON 解析：非 JSON / 不是对象 → null（不抛）。
Map<String, dynamic>? _tryJsonMap(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 最小 WS 抽象：只暴露服务层要用的三件事（读帧 / 发包 / 关）。
///
/// 生产实现是 [connectLiveSocket]（包一层 `dart:io` 的 `WebSocket`）；单测塞
/// 假实现即可覆盖全部时序，**不需要真连网、不需要新依赖**。
abstract class LiveSocket {
  /// 收到的二进制帧（可能是「多个包拼在一个帧里」，由
  /// [parseLiveDanmakuFrames] 拆）。
  Stream<Uint8List> get frames;

  /// 发一个已组好的协议包。
  void send(List<int> data);

  /// 主动关闭（幂等：重复调用不抛）。
  Future<void> close();
}

/// WS 连接器签名（可注入，见 [LiveSocket] 的说明）。
typedef LiveSocketConnector = Future<LiveSocket> Function(
  Uri uri,
  Map<String, String> headers,
);

/// 生产连接器：`dart:io` 的 [WebSocket]。失败**抛异常**（由服务层换 host 重试）。
Future<LiveSocket> connectLiveSocket(
  Uri uri,
  Map<String, String> headers,
) async {
  final ws = await WebSocket.connect(uri.toString(), headers: headers);
  return _IOWebSocket(ws);
}

/// `dart:io` WebSocket → [LiveSocket] 适配：把 `Stream<dynamic>`（可能是
/// String 或二进制 `List<int>`）统一成 `Stream<Uint8List>`。
class _IOWebSocket implements LiveSocket {
  _IOWebSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<Uint8List> get frames => _ws.map((event) {
        if (event is Uint8List) return event;
        if (event is List<int>) return Uint8List.fromList(event);
        return Uint8List.fromList(utf8.encode('$event'));
      });

  @override
  void send(List<int> data) => _ws.add(data);

  @override
  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {
      // 已断开：关失败无所谓（幂等）
    }
  }
}

/// 直播弹幕客户端：取弹幕服务器信息 + 按 host 建连。
///
/// 只负责「取信息」与「怎么连」，连接生命周期（认证/心跳/重连）在
/// `lib/services/live_danmaku_service.dart`——这样单元测试可以直接假造
/// [LiveSocket] 与假 [BiliApi]，不必真连网。
class LiveDanmakuClient {
  LiveDanmakuClient({BiliApi? api, LiveSocketConnector? connect})
      : _api = api ?? BiliApi(),
        _connect = connect ?? connectLiveSocket;

  final BiliApi _api;
  final LiveSocketConnector _connect;

  /// WS 握手头：浏览器 UA + 直播域 Origin/Referer（实测必须带；不带
  /// `Origin: https://live.bilibili.com` 服务端在握手期就拒）。
  static Map<String, String> wsHeaders(int roomId) => {
        ...biliHeaders(),
        'Referer': 'https://live.bilibili.com/$roomId',
        'Origin': 'https://live.bilibili.com',
      };

  /// 取弹幕服务器信息（token + host_list）。WBI 签名与直播域名由
  /// [BiliApi.fetchLiveDanmuInfo] 负责；失败返回 null（**不抛**，静默降级）。
  Future<LiveDanmuInfo?> fetchDanmuInfo(int roomId) async {
    final info = await _api.fetchLiveDanmuInfo(roomId);
    if (info == null || !info.isUsable) {
      debugPrint('[live_danmaku] room=$roomId 取弹幕服务器信息失败（静默降级）');
      return null;
    }
    debugPrint('[live_danmaku] room=$roomId 弹幕服务器信息: $info');
    return info;
  }

  /// 连一个 host（失败抛异常，由服务层换下一个 host）。
  Future<LiveSocket> connect(LiveDanmuHost host, int roomId) =>
      _connect(host.wssUri, wsHeaders(roomId));
}
