// 直播弹幕测试用的**共享替身与帧构造器**（非 test 文件，故不以下划线命名也可，
// 但按项目习惯仍以 `_` 前缀标注"辅助"）：被 test/live_danmaku_test.dart 与
// test/live_danmaku_page_test.dart 共同引用，避免两份假 socket 漂移。
//
// 关键点：帧**在测试里独立构造**（自己写 16 字节大端头 + ZLibCodec().encode），
// 不复用生产代码的 buildLivePacket——否则生产和测试会一起错。
// 不访问真实网络。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/live_danmaku_client.dart';
import 'package:bili_whitelist_app/models/live_danmaku.dart';

/// 协议头长度（测试侧独立常量，故意不复用生产常量）。
const int kTestHeaderLen = 16;

// ---------------------------------------------------------------------------
// 帧构造器
// ---------------------------------------------------------------------------

/// 组一个测试帧：16 字节大端头 + body。
///
/// [headerLen] / [packetLen] 可覆盖，用来构造**非法帧**：
/// - `headerLen: 12` → 头长小于固定 16（应被安全丢弃）
/// - `packetLen: xxx` 比实际大 → 截断帧（应被安全丢弃）
Uint8List livePacketRaw(
  int operation,
  Uint8List body, {
  int protoVer = 0,
  int headerLen = kTestHeaderLen,
  int? packetLen,
}) {
  final total = kTestHeaderLen + body.length;
  final out = Uint8List(total);
  final view = ByteData.sublistView(out);
  view.setUint32(0, packetLen ?? total, Endian.big);
  view.setUint16(4, headerLen, Endian.big);
  view.setUint16(6, protoVer, Endian.big);
  view.setUint32(8, operation, Endian.big);
  view.setUint32(12, 1, Endian.big);
  out.setRange(kTestHeaderLen, total, body);
  return out;
}

Uint8List _jsonBytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// `operation=5` + `protoVer=0` 的明文 JSON 包。
Uint8List jsonMessageFrame(Map<String, dynamic> json) =>
    livePacketRaw(5, _jsonBytes(json));

/// `operation=5` + `protoVer=2` 的 zlib 包：body 是**带 zlib 头**的压缩流
/// （实测格式，`ZLibCodec()` 默认就能解）。
Uint8List zlibMessageFrame(Uint8List inner) => livePacketRaw(
      5,
      Uint8List.fromList(ZLibCodec().encode(inner)),
      protoVer: 2,
    );

/// 把若干帧**拼成一个 WS 帧**（真实情况：服务端会把同一批消息打在一个帧里）。
Uint8List concatFrames(List<Uint8List> frames) {
  final total = frames.fold<int>(0, (s, f) => s + f.length);
  final out = Uint8List(total);
  var offset = 0;
  for (final f in frames) {
    out.setRange(offset, offset + f.length, f);
    offset += f.length;
  }
  return out;
}

/// 认证回复帧（`operation=8`，`{"code":0}`）。
///
/// ⚠️ 包头 `protoVer` 默认 **1**，这是**真机抓到的实测报文**（服务端按客户端
/// 包头的编码位回声，见 `lib/api/live_danmaku_client.dart` 里 `_handleLiveBody`
/// 的说明）。早先这里臆造了 `protoVer=0`，恰好绕过了「只认 0」的守卫 → 单测
/// 全绿而真机必挂（认证回复被整包丢掉，状态永远 connecting）。**不要改回 0**。
Uint8List authReplyFrame({int code = 0, int protoVer = 1}) =>
    livePacketRaw(8, _jsonBytes({'code': code}), protoVer: protoVer);

/// 心跳回复帧（`operation=3`，body 4 字节人气值）。
Uint8List heartbeatReplyFrame({int popularity = 6666}) {
  final body = Uint8List(4);
  ByteData.sublistView(body).setUint32(0, popularity, Endian.big);
  return livePacketRaw(3, body);
}

/// 一条 `DANMU_MSG` 的明文 JSON（字段位置按实测：见 live_danmaku.dart 字段表）。
///
/// `info` 造足 18 个元素（与实测一致），前 5 个是解析要用的：
/// `[0][1]`=模式 `[0][3]`=颜色 `[1]`=文本 `[2][0]`=uid `[2][1]`=用户名。
Map<String, dynamic> danmuMsgJson({
  String text = '活了',
  int mode = 1,
  int color = 16777215,
  int uid = 0,
  String uname = '远***',
  String cmd = 'DANMU_MSG',
}) {
  return {
    'cmd': cmd,
    'info': [
      [0, mode, 25, color, 1757740000000, 0, 0, '', 0],
      text,
      [uid, uname, 0, 0, 0, 10000, 1, ''],
      <Object?>[], // 粉丝牌（无）
      [0, 0, 1, ''],
      [0, 0, 10000, 1, ''],
      0,
      0,
      <Object?>[],
      {'ts': 1757740000, 'ct': 'x'},
      0,
      0,
      <Object?>[],
      <Object?>[],
      <Object?>[],
      <Object?>[],
      0,
      0,
    ],
  };
}

/// 取一个包的 `operation`（测试侧独立读头，用来断言发出去的包是什么）。
int packetOperation(List<int> packet) =>
    ByteData.sublistView(Uint8List.fromList(packet)).getUint32(8, Endian.big);

/// 取一个包的头部 `protoVer`。
int packetProtoVer(List<int> packet) =>
    ByteData.sublistView(Uint8List.fromList(packet)).getUint16(6, Endian.big);

/// 取一个包的 body（跳过 16 字节头）。
Uint8List packetBody(List<int> packet) =>
    Uint8List.fromList(packet.sublist(kTestHeaderLen));

/// 解一个包的 JSON body。
Map<String, dynamic> packetJson(List<int> packet) =>
    jsonDecode(utf8.decode(packetBody(packet))) as Map<String, dynamic>;

// ---------------------------------------------------------------------------
// 假 WS
// ---------------------------------------------------------------------------

/// 假 [LiveSocket]：帧从测试推、发出的包被记下来。
class FakeLiveSocket implements LiveSocket {
  final StreamController<Uint8List> _controller = StreamController<Uint8List>();

  /// 服务层发出的全部包（顺序 = 发送顺序）。
  final List<List<int>> sent = [];

  bool closed = false;

  @override
  Stream<Uint8List> get frames => _controller.stream;

  @override
  void send(List<int> data) {
    if (closed) throw StateError('send on closed socket');
    sent.add(List<int>.of(data));
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  /// 推一帧给服务层。
  void push(Uint8List frame) {
    if (!_controller.isClosed) _controller.add(frame);
  }

  /// 模拟服务端断开（触发 `onDone`）。
  void drop() {
    if (!_controller.isClosed) _controller.close();
  }

  /// 已发出的某类包计数（`operation`）。
  int sentCount(int operation) =>
      sent.where((p) => packetOperation(p) == operation).length;
}

/// 假连接器工厂：记录连过哪些地址、按 host 决定是否抛（host 兜底用例）。
class FakeSocketFactory {
  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];
  final List<FakeLiveSocket> sockets = [];

  /// 这些 host 一律连接失败（验证「host_list 逐个兜底」）。
  final Set<String> failHosts = {};

  int get calls => uris.length;

  FakeLiveSocket get last => sockets.last;

  Future<LiveSocket> connect(Uri uri, Map<String, String> headers) async {
    uris.add(uri);
    this.headers.add(headers);
    if (failHosts.contains(uri.host)) {
      throw StateError('连接被拒: $uri');
    }
    final socket = FakeLiveSocket();
    sockets.add(socket);
    return socket;
  }
}

/// 假 [BiliApi]：只把弹幕服务器信息做成可控（其余接口测试不碰）。
class FakeLiveDanmakuApi extends BiliApi {
  FakeLiveDanmakuApi({this.hosts, this.tokenPrefix = 'tok'});

  /// null = 取信息失败（返回 null 不抛，与真实实现一致）。
  List<LiveDanmuHost>? hosts;

  /// token 前缀 + 调用序号 → 每次调用 token 都不同（用来断言"重连重取了 token"）。
  String tokenPrefix;

  /// 认证 uid（0 = 匿名，实测可收弹幕）。
  int uid = 0;

  int calls = 0;

  @override
  Future<LiveDanmuInfo?> fetchLiveDanmuInfo(int roomId) async {
    calls++;
    final h = hosts;
    if (h == null) return null;
    return LiveDanmuInfo(token: '$tokenPrefix$calls', hosts: h, uid: uid);
  }
}

/// 默认一条弹幕服务器信息（单个 host）。
List<LiveDanmuHost> liveHosts([List<String> names = const ['h1']]) => [
      for (final n in names)
        LiveDanmuHost(host: n, wssPort: 2245, wsPort: 2244),
    ];

/// 排空事件队列若干轮（让 `await` 链跑完）。
///
/// 用零延时 Future 循环：既能冲刷微任务，也能跑掉 `Timer(0)` 级别的短定时器，
/// 不需要引入 fake_async（避免新增依赖 / 额外的 lint 牵连）。
Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
