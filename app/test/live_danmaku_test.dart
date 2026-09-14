// 直播弹幕（v2.27.0+）单测：**包解析纯函数** + **服务层连接生命周期**。
//
// 覆盖（对应验收清单）：
// - 解析：单包明文（protover=0）/ 单包 zlib（protover=2）/ 一个 WS 帧里多个包 /
//   **认证回复（op=8）的包头 protover=1（真机实测）与 0 都要认** /
//   嵌套包（解压出来又是包序列）/ 非法与截断帧（不抛，安全丢弃）/
//   `cmd` 带后缀（`DANMU_MSG:4:0:2:2:2:0`）/ 非弹幕 cmd 忽略 /
//   `DANMU_MSG` 结构异常不抛；另覆盖「裸 deflate 兜底」与「protover=3 跳过」。
// - 服务层（注入假 socket / 假 BiliApi）：认证包内容（body protover=2 + roomid +
//   key + uid）、**认证成功后立刻发心跳**、周期心跳、弹幕回调带进房秒数、
//   `onDone` → 重连并**重新取 token**、host 兜底、pause/resume、
//   取信息失败静默降级（重试用尽 → unavailable）、dispose 后无后台活动。
//
// 全部离线：不连真实网络、不打真实接口。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/live_danmaku_client.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/danmaku.dart';
import 'package:bili_whitelist_app/services/live_danmaku_service.dart';

import 'live_danmaku_fakes.dart';

// ---------------------------------------------------------------------------
// 假 HTTP（校验 getDanmuInfo 的 host / 参数 / 请求头；不联网）
// ---------------------------------------------------------------------------

/// 按路径给响应队列的假 adapter（同一路径多次请求按顺序取，越界取最后一个）。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handlers);

  final Map<String, List<Map<String, dynamic>> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];
  final Map<String, int> _hits = {};

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.uri.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final h = handlers[options.uri.path] ?? handlers[options.path];
    if (h == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.uri.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    final list = h(options);
    final index = _hits.update(options.uri.path, (v) => v + 1, ifAbsent: () => 0);
    final body = list[index < list.length ? index : list.length - 1];
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const String _kNavPath = '/x/web-interface/nav';
const String _kDanmuInfoPath = '/xlive/web-room/v1/index/getDanmuInfo';

/// nav 响应：wbi keys（img_url/sub_url 的文件名即 key）+ 匿名 mid=0。
Map<String, dynamic> _navBody() => {
      'code': 0,
      'data': {
        'mid': 0, // 匿名：_ensureMyMid 会抛 -101 → fetchMyMidOrZero 兜 0
        'wbi_img': {
          'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

Map<String, dynamic> _danmuInfoBody({
  int code = 0,
  List<Map<String, dynamic>>? hosts,
  String token = 'LIVE-TOKEN',
  int extraIndex = 0,
}) =>
    {
      'code': code,
      if (code != 0) 'message': '风控',
      'data': {
        'token': token,
        'host_list': hosts ??
            [
              {
                'host': 'tx-sh-live-comet-04.chat.bilibili.com',
                'port': 2243,
                'wss_port': 2245,
                'ws_port': 2244,
              },
              {
                'host': 'tx-sh-live-comet-05.chat.bilibili.com',
                'wss_port': 2245,
                'ws_port': 2244,
              },
            ],
        'group': 'live',
        'ts': 1757740000 + extraIndex,
      },
    };

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void _mockSecureStorage() {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async => null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockSecureStorage();
  });

  // -------------------------------------------------------------------------
  // BiliApi.fetchLiveDanmuInfo（弹幕服务器信息：WBI 签名 + 直播域名）
  // -------------------------------------------------------------------------

  group('BiliApi.fetchLiveDanmuInfo', () {
    test('走 api.live.bilibili.com 绝对 URL + WBI 签名（wts/w_rid/web_location）'
        '+ 直播 Referer/Origin', () async {
      final adapter = _Adapter({
        _kNavPath: (_) => [_navBody()],
        _kDanmuInfoPath: (_) => [_danmuInfoBody()],
      });
      final info = await _api(adapter).fetchLiveDanmuInfo(21452505);

      expect(info, isNotNull);
      expect(info!.token, 'LIVE-TOKEN');
      expect(info.hosts, hasLength(2));
      expect(info.hosts.first.host, 'tx-sh-live-comet-04.chat.bilibili.com');
      expect(info.hosts.first.wssPort, 2245);
      expect(info.hosts.first.wssUri.toString(),
          'wss://tx-sh-live-comet-04.chat.bilibili.com:2245/sub');
      expect(info.uid, 0, reason: '匿名 → uid=0（实测也能收弹幕）');

      final req = adapter.forPath(_kDanmuInfoPath).single;
      // 关键：host 必须是直播域名（打到 api.bilibili.com 会 404）
      expect(req.uri.host, 'api.live.bilibili.com');
      expect(req.uri.scheme, 'https');
      // 关键：必须带 WBI 签名（不加签名一律 -352）
      final q = req.queryParameters;
      expect(q['id'], '21452505');
      expect(q['type'], '0');
      expect(q['web_location'], '444.8');
      expect(q['wts'], isNotNull);
      expect(q['w_rid'], isNotNull);
      expect(q['w_rid'].toString(), hasLength(32),
          reason: 'w_rid = md5 十六进制 32 位（说明确实走了 WbiSigner）');
      // 请求头
      expect(req.headers['Referer'], 'https://live.bilibili.com/21452505');
      expect(req.headers['Origin'], 'https://live.bilibili.com');
    });

    test('-352（签名/token 失效）→ 刷新 WBI key 重签重试一次', () async {
      final adapter = _Adapter({
        _kNavPath: (_) => [_navBody()],
        _kDanmuInfoPath: (_) => [
              _danmuInfoBody(code: -352),
              _danmuInfoBody(token: 'AFTER-RETRY'),
            ],
      });
      final info = await _api(adapter).fetchLiveDanmuInfo(123);

      expect(info, isNotNull);
      expect(info!.token, 'AFTER-RETRY');
      expect(adapter.forPath(_kDanmuInfoPath), hasLength(2), reason: '重试一次');
    });

    test('业务码非 0 / token 缺失 / host_list 全脏 → null 不抛', () async {
      final cases = <Map<String, dynamic>>[
        _danmuInfoBody(code: -352), // 两次都是 -352
        {'code': 0, 'data': {'token': '', 'host_list': <Object?>[]}},
        {'code': 0, 'data': {'token': 'T', 'host_list': <Object?>[]}},
        {
          'code': 0,
          'data': {
            'token': 'T',
            'host_list': [
              {'host': 'h', 'wss_port': 0}, // 端口非法
              {'wss_port': 2245}, // 没有 host
              '脏数据',
            ],
          },
        },
        {'code': 0}, // 没有 data
      ];
      for (final body in cases) {
        final adapter = _Adapter({
          _kNavPath: (_) => [_navBody()],
          _kDanmuInfoPath: (_) => [body],
        });
        final info = await _api(adapter).fetchLiveDanmuInfo(123);
        expect(info, isNull, reason: '$body 应返回 null（静默降级）');
      }
    });

    test('网络异常 → null 不抛', () async {
      final adapter = _Adapter({}); // 没有 handler → 404 响应体
      final info = await _api(adapter).fetchLiveDanmuInfo(123);
      expect(info, isNull);
    });

    test('roomId 非法（<=0）→ 直接 null，不打任何请求', () async {
      final adapter = _Adapter({
        _kNavPath: (_) => [_navBody()],
        _kDanmuInfoPath: (_) => [_danmuInfoBody()],
      });
      expect(await _api(adapter).fetchLiveDanmuInfo(0), isNull);
      expect(adapter.requests, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 包解析（纯函数）
  // -------------------------------------------------------------------------

  group('parseLiveDanmakuFrames（纯函数拆包）', () {
    test('① 单包明文 JSON（protover=0）→ 解析出 DANMU_MSG', () {
      final frame = jsonMessageFrame(danmuMsgJson(text: '明文'));
      final events = parseLiveDanmakuFrames(frame);

      expect(events, hasLength(1));
      expect(events.single.operation, kLiveOpMessage);
      expect(events.single.danmaku, isNotNull);
      expect(events.single.danmaku!.text, '明文');
    });

    test('② 单包 zlib（protover=2，解压出包序列）→ 文本/颜色/模式/用户名/uid 都对',
        () {
      // 真实格式：压缩 body 解出来是**内层包序列**（内层 protover=0 明文 JSON）
      final inner = jsonMessageFrame(danmuMsgJson(
        text: '活了',
        mode: 4,
        color: 16711680,
        uid: 12345,
        uname: '远***',
      ));
      final events = parseLiveDanmakuFrames(zlibMessageFrame(inner));

      expect(events, hasLength(1));
      final d = events.single.danmaku!;
      expect(d.text, '活了');
      // 模式 4 = 底部（实测 info[0][1]）
      expect(d.mode, 4);
      // 颜色 16711680 = 0xFF0000 → ARGB 补 alpha
      expect(d.color, 0xFFFF0000);
      // 用户名/uid（实测 info[2][1] / info[2][0]）
      expect(d.uname, '远***');
      expect(d.uid, 12345);
      // 转成渲染模型后颜色/模式保持一致
      final danmaku = d.toDanmaku(1.5);
      expect(danmaku.color, 0xFFFF0000);
      expect(danmaku.mode, 4);
      expect(danmaku.isBottom, isTrue);
      expect(danmaku.timeSec, 1.5);
    });

    test('②b 压缩 body 直接是 JSON 对象（非包序列）→ 兜底也能解析', () {
      final direct = livePacketRaw(
        5,
        Uint8List.fromList(
          ZLibCodec().encode(Uint8List.fromList(
            utf8.encode(jsonEncode(danmuMsgJson(text: '兜底'))),
          )),
        ),
        protoVer: 2,
      );
      final events = parseLiveDanmakuFrames(direct);
      expect(events.single.danmaku?.text, '兜底');
    });

    test('③ 一个 WS 帧里塞多个包（拼接两个头+两个 body）→ 全部拆出', () {
      final frame = concatFrames([
        jsonMessageFrame(danmuMsgJson(text: '甲')),
        jsonMessageFrame({
          'cmd': 'INTERACT_WORD_V2',
          'data': {'uname': '某'},
        }),
        jsonMessageFrame(danmuMsgJson(text: '乙', mode: 5)),
      ]);
      final events = parseLiveDanmakuFrames(frame);

      expect(events, hasLength(3));
      expect(events.where((e) => e.danmaku != null).length, 2);
      expect(events.first.danmaku!.text, '甲');
      expect(events.last.danmaku!.text, '乙');
      expect(events[1].danmaku, isNull, reason: '非弹幕 cmd 不产出弹幕');
    });

    test('③b 一帧里「明文包 + 认证回复 + 心跳回复」混排', () {
      final frame = concatFrames([
        jsonMessageFrame(danmuMsgJson(text: '混排')),
        authReplyFrame(),
        heartbeatReplyFrame(popularity: 12345),
      ]);
      final events = parseLiveDanmakuFrames(frame);

      expect(events, hasLength(3));
      expect(events[0].danmaku!.text, '混排');
      expect(events[1].isAuthReply, isTrue);
      expect(events[1].authCode, 0);
      expect(events[2].popularity, 12345);
    });

    // ---- 认证回复的包头 protoVer（真机 bug 回归：只认 0 → 整包丢掉）----

    test('③c 认证回复包头 protoVer=1（**真机实测报文**）→ 认得出 op=8 + code=0', () {
      // 真机抓包：op=8、包头 protoVer=1、body=b'{"code":0}'
      final frame = authReplyFrame(protoVer: 1);
      expect(packetProtoVer(frame), 1, reason: '构造的必须是实测报文，不是臆造的 0');

      final events = parseLiveDanmakuFrames(frame);
      // 修复前：`protoVer != 0` → 直接 return，这里会是空列表（真机症状的根因）
      expect(events, hasLength(1), reason: 'protoVer=1 的认证回复不能被丢掉');
      expect(events.single.operation, kLiveOpAuthReply);
      expect(events.single.isAuthReply, isTrue);
      expect(events.single.authCode, 0, reason: 'code=0 = 认证成功');
    });

    test('③d 认证回复包头 protoVer=0（老报文）→ 同样支持（两种都容忍）', () {
      final events = parseLiveDanmakuFrames(authReplyFrame(protoVer: 0));
      expect(events, hasLength(1));
      expect(events.single.isAuthReply, isTrue);
      expect(events.single.authCode, 0);
    });

    test('③e 认证回复 body 非明文 JSON → 安全跳过，不抛', () {
      for (final protoVer in [0, 1]) {
        final frame = livePacketRaw(
          8,
          Uint8List.fromList([0x01, 0x02, 0x03]),
          protoVer: protoVer,
        );
        expect(() => parseLiveDanmakuFrames(frame), returnsNormally,
            reason: 'protoVer=$protoVer 的脏认证回复不该抛');
        expect(parseLiveDanmakuFrames(frame), isEmpty);
      }
    });

    test('③f op=5 消息包的判据不变：包头 protoVer=1 仍按非明文跳过', () {
      // 只放宽 op=8；消息包（op=5）依旧只认 protoVer=0（别顺手一起放宽）
      final frame = livePacketRaw(
        5,
        Uint8List.fromList(utf8.encode(jsonEncode(danmuMsgJson(text: '不该解析')))),
        protoVer: 1,
      );
      expect(parseLiveDanmakuFrames(frame), isEmpty);
    });

    test('④ 嵌套包（外层 protover=2 解压后又是一层 header+包）→ 递归解析', () {
      // 两层压缩：最内层才是明文 JSON
      final deepest = jsonMessageFrame(danmuMsgJson(text: '嵌套'));
      final middle = zlibMessageFrame(deepest); // 内层压缩包
      final outer = zlibMessageFrame(middle); // 外层压缩包

      final events = parseLiveDanmakuFrames(outer);
      expect(events, hasLength(1));
      expect(events.single.danmaku!.text, '嵌套');
    });

    test('⑤ 截断帧（packetLen 超过实际长度）→ 不抛，安全丢弃', () {
      final whole = jsonMessageFrame(danmuMsgJson(text: '截断'));
      final truncated = Uint8List.sublistView(whole, 0, whole.length - 4);

      expect(
        () => parseLiveDanmakuFrames(Uint8List.fromList(truncated)),
        returnsNormally,
      );
      expect(parseLiveDanmakuFrames(Uint8List.fromList(truncated)), isEmpty);
    });

    test('⑤ headerLen < 16 / packetLen=0 → 不抛，安全丢弃', () {
      final badHeader = livePacketRaw(
        5,
        Uint8List.fromList(utf8.encode(jsonEncode(danmuMsgJson(text: '坏头')))),
        headerLen: 12,
      );
      expect(() => parseLiveDanmakuFrames(badHeader), returnsNormally);
      expect(parseLiveDanmakuFrames(badHeader), isEmpty);

      final zeroLen = livePacketRaw(
        5,
        Uint8List.fromList(utf8.encode(jsonEncode(danmuMsgJson(text: '零长')))),
        packetLen: 0,
      );
      expect(() => parseLiveDanmakuFrames(zeroLen), returnsNormally);
      expect(parseLiveDanmakuFrames(zeroLen), isEmpty);
    });

    test('⑤c 帧里第一个包合法、第二个包截断 → 保留第一个', () {
      final good = jsonMessageFrame(danmuMsgJson(text: '前面这条'));
      final bad = Uint8List.sublistView(
        jsonMessageFrame(danmuMsgJson(text: '坏的')),
        0,
        20, // 只有 20 字节：头够但 body 不够
      );
      final frame = concatFrames([good, Uint8List.fromList(bad)]);

      final events = parseLiveDanmakuFrames(frame);
      expect(events, hasLength(1));
      expect(events.single.danmaku!.text, '前面这条');
    });

    test('⑤d 空帧 / 短于一个头的帧 → 空结果不抛', () {
      expect(parseLiveDanmakuFrames(Uint8List(0)), isEmpty);
      expect(parseLiveDanmakuFrames(Uint8List(8)), isEmpty);
    });

    test('⑥ cmd 带后缀（DANMU_MSG:4:0:2:2:2:0）也能识别', () {
      final frame = jsonMessageFrame(
        danmuMsgJson(text: '带后缀', cmd: 'DANMU_MSG:4:0:2:2:2:0'),
      );
      final events = parseLiveDanmakuFrames(frame);
      expect(events.single.danmaku?.text, '带后缀');
    });

    test('⑦ 非 DANMU_MSG 的 cmd（INTERACT_WORD_V2 / LOG_IN_NOTICE / ONLINE_RANK_COUNT）'
        '被忽略', () {
      final frame = concatFrames([
        jsonMessageFrame({'cmd': 'INTERACT_WORD_V2', 'data': {}}),
        jsonMessageFrame({'cmd': 'LOG_IN_NOTICE', 'data': {}}),
        jsonMessageFrame({'cmd': 'ONLINE_RANK_COUNT', 'data': {}}),
        jsonMessageFrame({'cmd': 'STOP_LIVE_ROOM_LIST', 'data': {}}),
      ]);
      final events = parseLiveDanmakuFrames(frame);

      expect(events, hasLength(4), reason: '包本身要拆出来（都不是弹幕）');
      expect(events.every((e) => e.danmaku == null), isTrue);
    });

    test('⑧ DANMU_MSG 结构异常（info 太短 / 元素类型不对）→ 不抛，跳过', () {
      final cases = <Map<String, dynamic>>[
        {'cmd': 'DANMU_MSG', 'info': <Object?>[]},
        {'cmd': 'DANMU_MSG', 'info': [<Object?>[], 42]}, // 文本不是 String
        {
          'cmd': 'DANMU_MSG',
          'info': [<Object?>[], '   ', <Object?>[]], // 空白文本
        },
        {
          'cmd': 'DANMU_MSG',
          'info': [<Object?>[], '文本', null], // 发送者不是 List（uid 兜 0）
        },
        {'cmd': 123, 'info': <Object?>[]}, // cmd 不是 String
        {'cmd': 'DANMU_MSG'}, // 没有 info
      ];
      for (final json in cases) {
        expect(() => parseLiveDanmakuFrames(jsonMessageFrame(json)),
            returnsNormally, reason: '$json 不该抛');
      }
      // 前三条彻底丢弃；第四条（发送者缺失）仍能出弹幕，uid/uname 兜底
      final events = parseLiveDanmakuFrames(jsonMessageFrame(cases[3]));
      expect(events.single.danmaku!.text, '文本');
      expect(events.single.danmaku!.uid, 0);
      expect(events.single.danmaku!.uname, '');
    });

    test('协议细节：raw deflate 兜底（万一服务端改裸 deflate）', () {
      final frame = livePacketRaw(
        5,
        Uint8List.fromList(ZLibCodec(raw: true).encode(
          Uint8List.fromList(utf8.encode(jsonEncode(danmuMsgJson(text: '裸压缩')))),
        )),
        protoVer: 2,
      );
      // 注意：这里是**直接压缩 JSON**，走兜底 JSON 分支
      final events = parseLiveDanmakuFrames(frame);
      expect(events.single.danmaku?.text, '裸压缩');
    });

    test('协议细节：protover=3（brotli）→ 跳过该包，不抛', () {
      final frame = livePacketRaw(
        5,
        Uint8List.fromList([1, 2, 3, 4]),
        protoVer: 3,
      );
      expect(() => parseLiveDanmakuFrames(frame), returnsNormally);
      expect(parseLiveDanmakuFrames(frame), isEmpty);
    });

    test('协议细节：解压失败（乱字节）→ 跳过该包，不抛', () {
      final frame = livePacketRaw(
        5,
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x11]),
        protoVer: 2,
      );
      expect(() => parseLiveDanmakuFrames(frame), returnsNormally);
      expect(parseLiveDanmakuFrames(frame), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 组包（客户端方向）
  // -------------------------------------------------------------------------

  group('buildLivePacket / buildLiveAuthPacket', () {
    test('心跳包：operation=2 且 body 为空', () {
      final packet = buildLiveHeartbeatPacket();
      expect(packet.length, 16);
      expect(packetOperation(packet), kLiveOpHeartbeat);
      expect(packetBody(packet), isEmpty);
    });

    test('认证包：operation=7，body 带 uid/roomid/protover=2/key', () {
      final packet = buildLiveAuthPacket(
        roomId: 21452505,
        token: 'TOKEN',
        uid: 0,
      );
      expect(packetOperation(packet), kLiveOpAuth);
      final body = packetJson(packet);
      expect(body['uid'], 0, reason: '匿名态填 0（实测也能收弹幕）');
      expect(body['roomid'], 21452505);
      expect(body['protover'], 2, reason: '要求服务端按 zlib 发消息');
      expect(body['platform'], 'web');
      expect(body['type'], 2);
      expect(body['key'], 'TOKEN');
    });
  });

  // -------------------------------------------------------------------------
  // 服务层（假 socket + 假 api）
  // -------------------------------------------------------------------------

  group('LiveDanmakuService 连接生命周期', () {
    /// 造一个服务 + 假 api + 假工厂；[hosts] 为 null 表示取信息失败。
    ({
      LiveDanmakuService service,
      FakeLiveDanmakuApi api,
      FakeSocketFactory factory,
      List<Danmaku> received,
    }) make({
      List<String>? hosts,
      List<int> backoffMs = const [10, 10, 10],
      Duration heartbeat = const Duration(milliseconds: 40),
      int Function()? clockMs,
    }) {
      final api = FakeLiveDanmakuApi(
        hosts: hosts == null ? null : liveHosts(hosts),
      );
      final factory = FakeSocketFactory();
      final received = <Danmaku>[];
      final service = LiveDanmakuService(
        api: api,
        connect: factory.connect,
        clockMs: clockMs,
        heartbeatInterval: heartbeat,
        backoffMs: backoffMs,
      )..onDanmaku = received.add;
      return (
        service: service,
        api: api,
        factory: factory,
        received: received,
      );
    }

    test('认证包内容正确（protover=2 / roomid / key / uid）+ WS 头带直播 Origin',
        () async {
      final t = make(hosts: ['h1']);
      t.service.start(roomId: 888, enteredAtMs: 0);
      await settle();

      expect(t.factory.calls, 1);
      expect(t.factory.uris.single.toString(), 'wss://h1:2245/sub');
      expect(t.factory.headers.single['Origin'], 'https://live.bilibili.com');
      expect(t.factory.headers.single['Referer'],
          'https://live.bilibili.com/888');
      expect(t.factory.headers.single['User-Agent'], contains('Chrome'),
          reason: '必须带浏览器 UA（防盗链/风控）');

      final sent = t.factory.last.sent;
      expect(sent, hasLength(1), reason: '认证前不发心跳');
      expect(packetOperation(sent.first), kLiveOpAuth);
      expect(packetProtoVer(sent.first), kLiveClientProtoVer,
          reason: '头部 protoVer 是编码标识（恒 1），与 body 的 protover=2 不是一回事');
      final body = packetJson(sent.first);
      expect(body['protover'], 2);
      expect(body['roomid'], 888);
      expect(body['key'], 'tok1');

      t.service.dispose();
    });

    test('认证成功后**立刻**发第一次心跳（第 2 个包就是心跳），之后周期心跳', () async {
      final t = make(hosts: ['h1'], heartbeat: const Duration(milliseconds: 40));
      t.service.start(roomId: 111, enteredAtMs: 0);
      await settle();
      expect(t.factory.last.sent, hasLength(1));

      t.factory.last.push(authReplyFrame());
      await settle();

      // 关键断言：认证回复后的**第一个**发出包就是心跳（实测：等 30s 才发会静默）
      expect(t.factory.last.sent, hasLength(2));
      expect(packetOperation(t.factory.last.sent[1]), kLiveOpHeartbeat);
      expect(t.service.status.value, LiveDanmakuStatus.connected);

      // 周期心跳：40ms 一次，等 130ms 至少再来 2 次
      await Future<void>.delayed(const Duration(milliseconds: 130));
      final heartbeats = t.factory.last.sentCount(kLiveOpHeartbeat);
      expect(heartbeats, greaterThanOrEqualTo(3),
          reason: '1 次立即 + 至少 2 次周期');
      expect(t.factory.last.sent.length, heartbeats + 1,
          reason: '认证后除了 1 个认证包 + 心跳，不该再发别的包');

      t.service.dispose();
    });

    test('实测认证回复（op=8 / 包头 protoVer=1）→ status=connected + 第 2 个包是心跳'
        '（真机 bug：认证回复被吞 → 永远 connecting、心跳从不发）', () async {
      final t = make(hosts: ['h1'], heartbeat: const Duration(milliseconds: 40));
      t.service.start(roomId: 23571, enteredAtMs: 0);
      await settle();
      expect(t.service.status.value, LiveDanmakuStatus.connecting);
      expect(t.factory.last.sent, hasLength(1), reason: '认证前不发心跳');

      final raw = authReplyFrame(protoVer: 1); // 真机抓到的报文（不是臆造的 0）
      expect(packetOperation(raw), kLiveOpAuthReply);
      expect(packetProtoVer(raw), 1);
      t.factory.last.push(raw);
      await settle();

      // 修复前：这条守卫把认证回复整包丢掉 → 状态停在 connecting、只有认证包
      expect(t.service.status.value, LiveDanmakuStatus.connected,
          reason: '认证回复必须被识别（真机症状 = 页面永远「连接中…」）');
      expect(t.factory.last.sent, hasLength(2),
          reason: '认证成功后要**立刻**发第一次心跳（第 2 个包）');
      expect(packetOperation(t.factory.last.sent[1]), kLiveOpHeartbeat);
      expect(packetBody(t.factory.last.sent[1]), isEmpty, reason: '心跳 body 为空');

      // 周期心跳随之启动（没有它：60~130s 后被服务端主动断开并无限重连）
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(t.factory.last.sentCount(kLiveOpHeartbeat), greaterThanOrEqualTo(3),
          reason: '1 次立即 + 至少 2 次周期');

      t.service.dispose();
    });

    test('认证失败（code != 0）→ 重连并重新取 token', () async {
      final t = make(hosts: ['h1'], backoffMs: const [10, 10]);
      t.service.start(roomId: 222, enteredAtMs: 0);
      await settle();
      expect(t.api.calls, 1);

      t.factory.last.push(authReplyFrame(code: -101));
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await settle();

      expect(t.api.calls, 2, reason: 'token 会过期 → 重连必须重取');
      expect(t.factory.calls, 2);
      expect(packetJson(t.factory.last.sent.first)['key'], 'tok2',
          reason: '新连接用新 token，不是复用旧的');

      t.service.dispose();
    });

    test('收到弹幕 → 回调拿到 Danmaku（时间轴 = 距进房秒数）', () async {
      var now = 1000000;
      final t = make(hosts: ['h1'], clockMs: () => now);
      t.service.start(roomId: 333, enteredAtMs: now);
      await settle();
      t.factory.last.push(authReplyFrame());
      await settle();

      now = 1002500; // 进房后 2.5 秒
      t.factory.last.push(zlibMessageFrame(jsonMessageFrame(danmuMsgJson(
        text: '活了',
        color: 16777215,
        uname: '远***',
      ))));
      await settle();

      expect(t.received, hasLength(1));
      expect(t.received.single.text, '活了');
      expect(t.received.single.color, 0xFFFFFFFF);
      expect(t.received.single.timeSec, closeTo(2.5, 1e-9));
      expect(t.received.single.isScroll, isTrue);

      t.service.dispose();
    });

    test('认证回复 / 非弹幕消息不会触发弹幕回调', () async {
      final t = make(hosts: ['h1']);
      t.service.start(roomId: 444, enteredAtMs: 0);
      await settle();
      expect(t.factory.last.sent, hasLength(1));

      t.factory.last.push(concatFrames([
        authReplyFrame(),
        jsonMessageFrame({'cmd': 'LOG_IN_NOTICE', 'data': {}}),
        jsonMessageFrame({'cmd': 'ONLINE_RANK_COUNT', 'data': {}}),
        heartbeatReplyFrame(),
      ]));
      await settle();

      expect(t.received, isEmpty);
      expect(t.service.status.value, LiveDanmakuStatus.connected);

      t.service.dispose();
    });

    test('onDone（WS 断开）→ 退避重连并重新取 token', () async {
      final t = make(hosts: ['h1'], backoffMs: const [20, 20]);
      t.service.start(roomId: 555, enteredAtMs: 0);
      await settle();
      t.factory.last.push(authReplyFrame());
      await settle();
      final firstSocket = t.factory.last;
      expect(t.api.calls, 1);

      firstSocket.drop(); // 服务端断开
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();

      expect(firstSocket.closed, isTrue, reason: '旧连接要关掉');
      expect(t.api.calls, 2, reason: '重连要重新取 token（会过期）');
      expect(t.factory.calls, 2);
      expect(packetOperation(t.factory.last.sent.first), kLiveOpAuth);
      expect(packetJson(t.factory.last.sent.first)['key'], 'tok2');

      t.service.dispose();
    });

    test('host 兜底：host_list[0] 连不上 → 用下一个', () async {
      final t = make(hosts: ['bad', 'good']);
      t.factory.failHosts.add('bad');

      t.service.start(roomId: 666, enteredAtMs: 0);
      await settle();

      expect(t.factory.calls, 2, reason: '第一个 host 失败要换下一个');
      expect(t.factory.uris.first.host, 'bad');
      expect(t.factory.uris.last.toString(), 'wss://good:2245/sub');
      expect(packetOperation(t.factory.last.sent.first), kLiveOpAuth);

      t.service.dispose();
    });

    test('取弹幕服务器信息失败 → 静默重试，用尽后 unavailable（不抛）', () async {
      final t = make(hosts: null, backoffMs: const [10, 10]);
      t.service.start(roomId: 777, enteredAtMs: 0);
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle();

      // 首次 + 两次退避重试都失败 → 用尽
      expect(t.api.calls, 3);
      expect(t.service.status.value, LiveDanmakuStatus.unavailable);
      expect(t.factory.calls, 0);
      expect(t.received, isEmpty);

      t.service.dispose();
    });

    test('pause() 断连接停心跳；resume() 重连', () async {
      final t = make(hosts: ['h1'], heartbeat: const Duration(milliseconds: 20));
      t.service.start(roomId: 999, enteredAtMs: 0);
      await settle();
      t.factory.last.push(authReplyFrame());
      await settle();

      final socket = t.factory.last;
      t.service.pause();
      await settle();
      expect(socket.closed, isTrue);
      expect(t.service.status.value, LiveDanmakuStatus.idle);
      final frozen = socket.sent.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(socket.sent.length, frozen, reason: '暂停后不该再发心跳');

      t.service.resume();
      await settle();
      expect(t.api.calls, 2);
      expect(t.factory.last.sent, isNotEmpty);
      expect(packetOperation(t.factory.last.sent.first), kLiveOpAuth);

      t.service.dispose();
    });

    test('dispose() 后：连接关闭、不再取 token、不再发包、无后台活动', () async {
      final t = make(hosts: ['h1'], backoffMs: const [5, 5],
          heartbeat: const Duration(milliseconds: 10));
      t.service.start(roomId: 1234, enteredAtMs: 0);
      await settle();
      t.factory.last.push(authReplyFrame());
      await settle();

      final socket = t.factory.last;
      final sentBefore = socket.sent.length;
      t.service.dispose();
      await settle();
      expect(socket.closed, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(socket.sent.length, sentBefore, reason: 'dispose 后不该再发心跳');
      expect(t.api.calls, 1, reason: 'dispose 后不该再取 token');
      expect(t.factory.calls, 1, reason: 'dispose 后不该再连');
      expect(t.service.debugReconnectAttempts, 0);
    });

    test('重连预算：认证成功会清零（长时间稳定后掉线仍有满额预算）', () async {
      final t = make(hosts: ['h1'], backoffMs: const [10, 10, 10]);
      t.service.start(roomId: 4321, enteredAtMs: 0);
      await settle();
      t.factory.last.push(authReplyFrame());
      await settle();
      expect(t.service.debugReconnectAttempts, 0);

      t.factory.last.drop();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await settle();
      // 新连接认证成功 → 预算再次清零
      t.factory.last.push(authReplyFrame());
      await settle();
      expect(t.service.debugReconnectAttempts, 0);

      t.service.dispose();
    });
  });
}
