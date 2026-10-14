// App gRPC `PlayView` 取流（v2.52.0+，「免流兼容（实验）」开关的取流链路）测试。
//
// 背景（2026-10-14 匿名实测，见 `lib/api/playview_api.dart` 头注释）：
//   - 网页接口 / App REST 接口下发的直链签名是 `platform=pc`，取流要「浏览器 UA +
//     Referer」，**换成 App 特征 UA 反而 403** —— 只换 UA 那版（v2.51.x）必然取不到流；
//   - App gRPC `PlayView` 下发的直链签名是 `platform=android`，取流要「Android 特征
//     UA + **不带** Referer」（带了必 403）。
//
// 本文件把这些结论钉成回归测试，重点是**不许偷偷多带头**：
//   1. 协议编码/解码（BV→AV、PlayViewReq 字节、Metadata 字段、gRPC 帧）；
//   2. 真实 loopback HTTP 收请求：`content-type: application/grpc`、
//      `x-bili-metadata-bin` 只含匿名字段、**不带 referer / origin**、
//      body 是合法的 gRPC 帧且解出的 PlayViewReq 字段正确；
//   3. 响应解析：只收「有 base_url 且无 err_code」的视频轨、取最高清晰度、
//      backup_url 进候选线路表、音频轨/档位/码率对应；
//   4. 失败形态：无有效 aid、响应空、gRPC 帧越界、grpc-status != 0 → 抛错
//      （由 player_page 回落网页接口）。
//
// 【v2.52.0 契约变更】**cookie 从"一律不带"改成"有登录态就带"**，理由：
//   - 匿名 PlayView 与匿名网页接口一样只有 480P/360P，而本 App 是登录的
//     （网页接口靠 Cookie 拿 1080P）→ 这条路径**可能把 1080P 悄悄降成 480P**；
//   - 所以这里显式带上 `Cookie: SESSDATA=…`（`*.bilibili.com` 与 CDN 不同域，
//     客户端不会自动带），**试着**换到高清；拿不到也只是回到匿名档。
//   - **Referer / Origin 仍然一个都不许带**（实测带了必 403，与 cookie 无关）——
//     这条断言原样保留。
//
// 另有两组"不许静默降级"的测试：清晰度日志（只许出现数字/布尔）与
// `player_page` 的提示接线（低于 720P 且已登录 → 每会话只提示一次）。
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/playview_api.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

/// secure storage 的 MethodChannel（flutter_secure_storage 9.2.4 用的那个名字；
/// 与 `test/stream_compat_fallback_test.dart` 等既有测试同一套 mock 手法）。
const MethodChannel kSecureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// 明显是假的 SESSDATA 夹具（**真凭据绝不进仓库**）：`uid,过期时间戳,hash`。
///
/// 过期时间取 2030 年（≈1893456000）→ 未过期；[kFakeSessdataExpired] 取 2001 年
/// （1000000000）→ 已过期。`playViewLoginCookie` 复用 [BiliApi.sessdataExpireAt]
/// 解析这两段，所以夹具必须是**这个形状**（不然解析不出过期时间）。
const String kFakeSessdataValid = '123456,1893456000,FAKEHASHDONOTUSE';
const String kFakeSessdataExpired = '123456,1000000000,FAKEHASHDONOTUSE';
const String kFakeBiliJct = 'FAKEJCTDONOTUSE';

// ---------------------------------------------------------------------------
// 小工具：按 protobuf wire 格式手搓一段消息（与库里的编码器互相独立，
// 避免"自己编自己解"这种自我印证）
// ---------------------------------------------------------------------------

Uint8List _varint(int n) {
  final out = <int>[];
  var v = n;
  while (true) {
    final b = v & 0x7F;
    v >>= 7;
    if (v != 0) {
      out.add(b | 0x80);
    } else {
      out.add(b);
      return Uint8List.fromList(out);
    }
  }
}

Uint8List _fVarint(int f, int n) =>
    Uint8List.fromList([..._varint((f << 3) | 0), ..._varint(n)]);

Uint8List _fBytes(int f, List<int> b) => Uint8List.fromList(
    [..._varint((f << 3) | 2), ..._varint(b.length), ...b]);

Uint8List _fStr(int f, String s) => _fBytes(f, utf8.encode(s));

Uint8List _join(List<Uint8List> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

/// 一段假的 `PlayViewReply`：
/// - 视频轨 480P（quality=32，有 base_url + backup_url）
/// - 视频轨 360P（quality=16）
/// - 一条带 err_code=1 的 720P（应被过滤：那是"未登录/无权限"的档位）
/// - 一条 base_url 为空的（应被过滤）
/// - 两条音频轨
Uint8List _fakePlayViewReply() {
  Uint8List stream(int q, String? base, List<String> backups, int errCode) {
    final si = _join([
      _fVarint(1, q),
      if (errCode != 0) _fVarint(4, errCode),
    ]);
    final dv = _join([
      if (base != null) _fStr(1, base),
      for (final b in backups) _fStr(2, b),
      _fVarint(3, 123456),
      _fVarint(4, 7),
    ]);
    return _join([_fBytes(1, si), _fBytes(2, dv)]);
  }

  final videoInfo = _join([
    _fVarint(1, 32), // quality
    _fBytes(5, stream(32, 'https://a/480.m4s', ['https://b/480.m4s'], 0)),
    _fBytes(5, stream(16, 'https://a/360.m4s', const [], 0)),
    _fBytes(5, stream(64, null, const [], 1)),
    _fBytes(5, stream(8, '', const [], 0)),
    // dash_audio: id=1, baseUrl=2, backup_url=3, bandwidth=4
    _fBytes(
        6,
        _join([
          _fVarint(1, 30216),
          _fStr(2, 'https://a/a64.m4s'),
          _fStr(3, 'https://b/a64.m4s'),
          _fVarint(4, 43962),
        ])),
    _fBytes(
        6,
        _join([
          _fVarint(1, 30280),
          _fStr(2, 'https://a/a192.m4s'),
          _fVarint(4, 203786),
        ])),
  ]);
  return _fBytes(1, videoInfo); // PlayViewReply.video_info = 1
}

// ---------------------------------------------------------------------------
// 播放页接线用的小工具（骨架同 `test/stream_compat_fallback_test.dart`）
// ---------------------------------------------------------------------------

/// 标注：这个视频没有任何「免流兼容」字样，免得污染文案断言。
WhitelistVideo _pvVideo() => const WhitelistVideo(
      bvid: 'BV1PV00001',
      cid: 1001,
      title: 'App 取流清晰度测试视频',
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 一条假流（只用于让播放器通道拿到 URL；地址不会真的被请求）。
PlayUrlResult _pvStream({required int quality, String tag = 'pv'}) =>
    PlayUrlResult(
      quality: quality,
      dashVideoUrls: ['https://$tag.example/v.m4s'],
      dashAudioUrls: ['https://$tag.example/a.m4s'],
      dashVideoLines: [
        ['https://$tag.example/v.m4s']
      ],
      dashAudioLines: [
        ['https://$tag.example/a.m4s']
      ],
    );

/// 网页接口替身：**PlayView 成功时它一次都不该被调**（`webStream` 传 null 时
/// 一被调就抛错，把"白回落一次网页接口"这种回归直接钉死）。
class _PvApi extends BiliApi {
  _PvApi({this.webStream});

  final PlayUrlResult? webStream;
  int webCalls = 0;

  @override
  Future<PlayUrlResult> fetchPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    int fnval = 0,
  }) async {
    webCalls++;
    final s = webStream;
    if (s == null) {
      throw StateError('PlayView 取流成功时不该再打网页接口（测试构造）');
    }
    return s;
  }
}

/// 内存版 DownloadManager（零真实 IO；本组要「没有缓存」→ 走网络取流）。
class _PvEmptyManager extends DownloadManager {
  _PvEmptyManager() {
    cached.value = const [];
  }
}

/// 原生播放器通道桩（只装本组需要的那几个方法）。
class _PvMocks {
  MockStreamHandlerEventSink? sink;
  final List<String> sources = [];
  bool readyOnSetDataSource = true;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        switch (call.method) {
          case 'create':
            return 7;
          case 'getPosition':
            return 0;
          case 'setDataSource':
            final map = call.arguments as Map;
            sources.add(map['videoUrl'] as String);
            if (readyOnSetDataSource) {
              sink?.success({
                'event': 'onPrepared',
                'textureId': map['textureId'],
                'width': 1280,
                'height': 720,
                'durationMs': 600000,
                'playWhenReady': true,
              });
            }
          default:
            break;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('bili_dash_player'),
        null,
      ),
    );

    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          sink = events;
        },
      ),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        const EventChannel('bili_dash_player/events'),
        null,
      ),
    );

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }
}

/// 把 secure storage 的读结果钉成 [values]（未登录 = 空表）。
///
/// 播放页的「已登录」判据是 `_hasValidSession()`（读 `bili_sessdata` 并解析
/// 内嵌过期时间），所以夹具必须是 [kFakeSessdataValid] 那种形状。
void _mockSecureStorageFor(WidgetTester tester, Map<String, String> values) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    kSecureStorageChannel,
    (call) async {
      if (call.method != 'read') return null;
      final args = (call.arguments as Map).cast<Object?, Object?>();
      final key = args['key'] as String?;
      return key == null ? null : values[key];
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(kSecureStorageChannel, null));
}

void main() {
  // 本文件既有"真实 loopback HTTP"用例，又要 mock secure storage 通道
  // （登录 Cookie 判据）与驱动播放页 widget → 初始化测试 binding。
  // 副作用：flutter_test 会把 HttpClient 换成"一律 400"的桩，所以下面那组
  // loopback 用例自己临时摘掉 HttpOverrides（同 stream_compat_test.dart）。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // resetForTest 会把开关、会话回退标记、提示开关一并复位（防用例串味）
    UiPrefsStore.instance.resetForTest();
    debugResetPlayViewQualityNotice();
    DownloadManager.debugOverride(_PvEmptyManager());
  });
  tearDown(() {
    DownloadManager.debugReset();
    UiPrefsStore.instance.resetForTest();
    debugResetPlayViewQualityNotice();
  });

  group('BV→AV 换算', () {
    test('实测样本 BV1GJ411x7h7 → 80433022', () {
      // 期望值来自匿名接口 x/web-interface/view 的真实返回
      expect(aidFromBvid('BV1GJ411x7h7'), 80433022);
    });

    test('非法输入返回 0（调用方据此抛错回落）', () {
      expect(aidFromBvid(''), 0);
      expect(aidFromBvid('BV1GJ411x7h'), 0); // 太短
      expect(aidFromBvid('BV1GJ411x7h!'), 0); // 字母表外字符
    });
  });

  group('PlayViewReq 编码', () {
    test('字段号与字节序固定（aid=1 cid=2 qn=3 fnval=5 force_host=7 fourk=8）', () {
      final req = encodePlayViewReq(
        aid: 80433022,
        cid: 137649199,
        qn: 80,
        fnval: 16,
        fourk: 1,
        forceHost: 2,
      );
      // 08 fe9ead26 | 10 afb8d141 | 18 50 | 28 10 | 38 02 | 40 01
      expect(
        req,
        Uint8List.fromList(
            [0x08, 0xfe, 0x9e, 0xad, 0x26, 0x10, 0xaf, 0xb8, 0xd1, 0x41,
              0x18, 0x50, 0x28, 0x10, 0x38, 0x02, 0x40, 0x01]),
      );
    });

    test('不含 bvid / ep_id / mobi_app / platform（那些走元数据头或另设服务）', () {
      final req = encodePlayViewReq(aid: 1, cid: 2);
      final fields = pbParse(req).map((f) => f.field).toSet();
      expect(fields, isNot(contains(6))); // download 省略
      expect(fields, contains(1));
      expect(fields, contains(2));
    });
  });

  group('Metadata 编码', () {
    test('只填匿名字段（mobi_app/build/channel/buvid/platform），无 access_key', () {
      final meta = metadataBin(buvid: 'XYABC', build: 7650300);
      final fields = pbParse(meta);
      final byField = {for (final f in fields) f.field: f};

      expect(byField.containsKey(1), isFalse, reason: '不带 access_key');
      expect(utf8.decode(byField[2]!.value as Uint8List), 'android');
      expect(byField[4]!.value, 7650300);
      expect(utf8.decode(byField[5]!.value as Uint8List), 'master');
      expect(utf8.decode(byField[6]!.value as Uint8List), 'XYABC');
      expect(utf8.decode(byField[7]!.value as Uint8List), 'android');
    });
  });

  group('gRPC 帧', () {
    test('编码 = 0x00 + 4 字节大端长度 + 消息体', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      expect(grpcFrame(payload),
          Uint8List.fromList([0, 0, 0, 0, 3, 1, 2, 3]));
      expect(grpcUnframe(grpcFrame(payload)), payload);
    });

    test('响应过短 / 长度越界 → FormatException', () {
      expect(() => grpcUnframe(Uint8List.fromList([0, 0])),
          throwsA(isA<FormatException>()));
      expect(
          () => grpcUnframe(Uint8List.fromList([0, 0, 0, 0, 9, 1, 2])),
          throwsA(isA<FormatException>()));
    });
  });

  group('假 buvid', () {
    test('形状 = XY + 32 位十六进制大写；同种子可复现（不读真实设备指纹）', () {
      final a = fakeBuvid(Random(42));
      final b = fakeBuvid(Random(42));
      expect(a, b);
      expect(a.length, 34);
      expect(a.startsWith('XY'), isTrue);
      expect(RegExp(r'^XY[0-9A-F]{32}$').hasMatch(a), isTrue);
    });
  });

  group('响应解析', () {
    test('过滤无流/带错误码的档位、取最高清晰度、保留备用线路与音频档位', () {
      final streams = parsePlayViewReply(_fakePlayViewReply());

      expect(streams.quality, 32);
      expect(streams.videos.map((v) => v.quality), [32, 16],
          reason: '720P（err_code=1）与空 base_url 的档位都被过滤');

      final result = toPlayUrlResult(streams);
      expect(result.quality, 32);
      expect(result.dashVideoUrls, ['https://a/480.m4s']);
      expect(result.dashVideoLines, [
        ['https://a/480.m4s', 'https://b/480.m4s']
      ], reason: 'backup_url 进候选线路表，供换源轮转');
      expect(result.dashAudioUrls, ['https://a/a64.m4s', 'https://a/a192.m4s']);
      expect(result.dashAudioIds, [30216, 30280]);
      expect(result.dashAudioBandwidths, [43962, 203786]);
      expect(result.dashAudioLines.first,
          ['https://a/a64.m4s', 'https://b/a64.m4s']);
      expect(result.hasStream, isTrue);
    });

    test('没有 video_info / 没有可用视频轨 → 抛错（调用方回落网页接口）', () {
      expect(() => parsePlayViewReply(Uint8List.fromList([0x08, 0x01])),
          throwsA(isA<FormatException>()));
      expect(
          () => toPlayUrlResult(
              const PlayViewStreams(quality: 0, videos: [], audios: [])),
          throwsA(isA<FormatException>()));
    });
  });

  group('真实 loopback HTTP：请求头与请求体', () {
    late HttpServer server;
    late String baseUrl;
    late Map<String, String> seenHeaders;
    late Uint8List seenBody;
    var hits = 0;

    late HttpOverrides? oldOverrides;

    setUp(() async {
      hits = 0;
      seenHeaders = {};
      seenBody = Uint8List(0);
      // 本组要真连 loopback（127.0.0.1），而 flutter_test 默认把 HttpClient
      // 换成"一律 400"的桩 → 临时摘掉，用完还原（同 stream_compat_test.dart）
      oldOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        hits++;
        seenHeaders = {};
        req.headers.forEach((k, v) {
          seenHeaders[k.toLowerCase()] = v.join(',');
        });
        final chunks = <int>[];
        await for (final c in req) {
          chunks.addAll(c);
        }
        seenBody = Uint8List.fromList(chunks);
        req.response.headers.contentType =
            ContentType.parse('application/grpc');
        req.response.headers.set('grpc-status', '0');
        req.response.add(grpcFrame(_fakePlayViewReply()));
        await req.response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = oldOverrides;
      await server.close(force: true);
    });

    test('（匿名）发得对：content-type / 元数据头 / UA / **不带 referer·origin·cookie**',
        () async {
      final result = await fetchPlayViewStream(
        bvid: 'BV1GJ411x7h7',
        cid: 137649199,
        buvid: 'XYTESTBUVID',
        baseUrl: baseUrl,
        // 未登录（读不到 SESSDATA）→ 走匿名，与 v2.52.0 的行为一致
        cookieReader: () async => null,
      );

      expect(hits, 1);
      expect(result.dashVideoUrls, ['https://a/480.m4s']);

      expect(seenHeaders['content-type'], 'application/grpc');
      // 元数据头是 base64 的 protobuf；解出来必须只有匿名字段
      final meta = base64Decode(seenHeaders['x-bili-metadata-bin']!);
      final metaFields = {for (final f in pbParse(meta)) f.field};
      expect(metaFields, isNot(contains(1)), reason: '不传 access_key');
      expect(
          utf8.decode(
              pbParse(meta).firstWhere((f) => f.field == 6).value as Uint8List),
          'XYTESTBUVID');
      expect(
          utf8.decode(
              pbParse(meta).firstWhere((f) => f.field == 7).value as Uint8List),
          'android');

      // 关键回归：referer / origin 一个都不许出现（带了会被判成网页流量 /
      // 直接 403）；未登录时 cookie 也不许出现（保持匿名）
      expect(seenHeaders.containsKey('referer'), isFalse);
      expect(seenHeaders.containsKey('origin'), isFalse);
      expect(seenHeaders.containsKey('cookie'), isFalse,
          reason: '无 SESSDATA → 不带 Cookie（照旧匿名请求）');

      // 请求体是合法 gRPC 帧，解出来 aid/cid 正确
      expect(seenBody[0], 0);
      final reqMsg = grpcUnframe(seenBody);
      final fields = {for (final f in pbParse(reqMsg)) f.field: f.value};
      expect(fields[1], 80433022);
      expect(fields[2], 137649199);
      expect(fields[5], 16, reason: 'fnval=16 DASH 双流');
    });

    test('（已登录）请求头带 Cookie=SESSDATA…；**仍然不带 referer / origin**', () async {
      const cookieValue = 'SESSDATA=$kFakeSessdataValid; bili_jct=$kFakeBiliJct';
      final result = await fetchPlayViewStream(
        bvid: 'BV1GJ411x7h7',
        cid: 137649199,
        buvid: 'XYTESTBUVID',
        baseUrl: baseUrl,
        cookieReader: () async => cookieValue,
      );

      expect(hits, 1);
      expect(result.dashVideoUrls, ['https://a/480.m4s']);
      expect(seenHeaders['cookie'], cookieValue,
          reason: 'cookie 原样进请求头：SESSDATA 是换高清的唯一指望');
      expect(seenHeaders['cookie'], contains(kFakeSessdataValid));
      // 「不许带 Referer/Origin」这条与 cookie 无关，**两条路径都必须成立**
      expect(seenHeaders.containsKey('referer'), isFalse);
      expect(seenHeaders.containsKey('origin'), isFalse);
      // 也不许多塞无关 cookie（buvid3/DedeUserID 那些走元数据头，不走 cookie）
      expect(seenHeaders['cookie'], isNot(contains('buvid')));
      expect(seenHeaders['cookie'], isNot(contains('DedeUserID')));
    });

    test('清晰度日志：只打档位/轨道数（不带 cookie、不带 URL）', () async {
      final logs = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      addTearDown(() => debugPrint = old);

      await fetchPlayViewStream(
        bvid: 'BV1GJ411x7h7',
        cid: 137649199,
        baseUrl: baseUrl,
        cookieReader: () async => 'SESSDATA=$kFakeSessdataValid',
      );

      final line = logs.firstWhere((l) => l.startsWith('[playview] '),
          orElse: () => '（没有日志）');
      expect(line, contains('platform=android'));
      expect(line, contains('已带登录Cookie=true'));
      // 夹具里最高的可用视频轨是 480P（720P 那条带 err_code、被过滤掉）
      expect(line, contains('最高视频轨=32（480P）'));
      expect(line, contains('轨道数=2'));
      // 只许出现数字/名称/布尔 —— 凭据与 URL 一律不许进日志
      expect(line, isNot(contains(kFakeSessdataValid)));
      expect(line, isNot(contains('SESSDATA')));
      expect(line, isNot(contains('http')));
      expect(line, isNot(contains('m4s')));

      // 匿名那次：同一个格式，只是布尔为 false
      final anon = <String>[];
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) anon.add(m);
      };
      await fetchPlayViewStream(
        bvid: 'BV1GJ411x7h7',
        cid: 137649199,
        baseUrl: baseUrl,
        cookieReader: () async => null,
      );
      expect(
          anon.firstWhere((l) => l.startsWith('[playview] '),
              orElse: () => '（没有日志）'),
          contains('已带登录Cookie=false'));
    });

    test('grpc-status != 0 → 抛错（不静默给空流）', () async {
      await server.close(force: true);
      final s2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s2.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType =
            ContentType.parse('application/grpc');
        req.response.headers.set('grpc-status', '-101');
        req.response.headers.set('grpc-message', 'account not login');
        await req.response.close();
      });
      addTearDown(() => s2.close(force: true));

      await expectLater(
        fetchPlayViewStream(
          bvid: 'BV1GJ411x7h7',
          cid: 137649199,
          baseUrl: 'http://127.0.0.1:${s2.port}',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('无有效 aid（bvid 非法）→ ArgumentError，一个请求都不发', () async {
      await expectLater(
        fetchPlayViewStream(bvid: 'bad', cid: 1, baseUrl: baseUrl),
        throwsA(isA<ArgumentError>()),
      );
      expect(hits, 0);
    });
  });

  // -------------------------------------------------------------------------
  group('登录 Cookie 读取（v2.52.0+，走 secure storage 真路径）', () {
    Map<String, String>? values;
    var throwOnRead = false;

    void mockStorage() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kSecureStorageChannel, (call) async {
        if (throwOnRead) {
          throw PlatformException(
              code: 'storage_error', message: '测试构造：Keystore 解不开');
        }
        if (call.method != 'read') return null;
        final args = (call.arguments as Map).cast<Object?, Object?>();
        final key = args['key'] as String?;
        return key == null ? null : values?[key];
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(kSecureStorageChannel, null));
    }

    setUp(() {
      values = null;
      throwOnRead = false;
      mockStorage();
    });

    test('未登录（盘上没有 SESSDATA）→ null（照旧匿名请求，不失败）', () async {
      expect(await playViewLoginCookie(), isNull);
      values = {'bili_jct': kFakeBiliJct};
      expect(await playViewLoginCookie(), isNull,
          reason: '只有 bili_jct 没有 SESSDATA：登录态本体不在 → 仍是匿名');
    });

    test('有 SESSDATA → `SESSDATA=…`；有 bili_jct 时两个都带（分号分隔）', () async {
      values = {kSessdataStorageKey: kFakeSessdataValid};
      expect(await playViewLoginCookie(), 'SESSDATA=$kFakeSessdataValid');

      values = {
        kSessdataStorageKey: kFakeSessdataValid,
        kBiliJctStorageKey: kFakeBiliJct,
      };
      final cookie = await playViewLoginCookie();
      expect(cookie, 'SESSDATA=$kFakeSessdataValid; bili_jct=$kFakeBiliJct');
      // 只带这两样：多余 cookie 会让它更像「网页流量」，与开关目的相反
      expect(cookie, isNot(contains('buvid')));
      expect(cookie, isNot(contains('DedeUserID')));
    });

    test('SESSDATA 已过期 → null（不拿死会话去换流，回匿名档）', () async {
      values = {kSessdataStorageKey: kFakeSessdataExpired};
      final logs = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      addTearDown(() => debugPrint = old);

      expect(await playViewLoginCookie(), isNull);
      expect(logs.join('\n'), contains('已过期'));
      // 日志里不许出现凭据本身
      expect(logs.join('\n'), isNot(contains(kFakeSessdataExpired)));
    });

    test('读盘异常 → null 且不抛（绝不因为拿不到 cookie 让取流失败）', () async {
      values = {kSessdataStorageKey: kFakeSessdataValid};
      throwOnRead = true;
      await expectLater(playViewLoginCookie(), completion(isNull));
    });
  });

  // -------------------------------------------------------------------------
  group('清晰度档位名与提示判据（纯函数）', () {
    test('playViewQualityName：常见档位给人话，未知档位原样带值', () {
      expect(playViewQualityName(16), '360P');
      expect(playViewQualityName(32), '480P');
      expect(playViewQualityName(64), '720P');
      expect(playViewQualityName(80), '1080P');
      expect(playViewQualityName(120), '4K');
      expect(playViewQualityName(7), '未知档位 7');
    });

    test('shouldWarnLowPlayViewQuality：低于 720P 且已登录才提示', () {
      expect(
          shouldWarnLowPlayViewQuality(quality: 32, loggedIn: true), isTrue,
          reason: '480P + 已登录 = 就是这条路径把 1080P 降下来了');
      expect(
          shouldWarnLowPlayViewQuality(quality: 16, loggedIn: true), isTrue);
      expect(shouldWarnLowPlayViewQuality(quality: 64, loggedIn: true), isFalse,
          reason: '720P 是阈值上，不提示');
      expect(shouldWarnLowPlayViewQuality(quality: 80, loggedIn: true), isFalse);
      expect(shouldWarnLowPlayViewQuality(quality: 32, loggedIn: false), isFalse,
          reason: '未登录本来就只有 480P，不是这个开关的锅，提示会误导');
      expect(shouldWarnLowPlayViewQuality(quality: 0, loggedIn: true), isFalse,
          reason: '解析不出档位时宁可少提示，别凭空吓唬人');
    });
  });

  // -------------------------------------------------------------------------
  // ④ 播放页接线：清晰度**可见**（不许静默降级）
  //
  // 骨架同 `test/stream_compat_fallback_test.dart`：播放器通道 + EventChannel
  // 手工 mock、DownloadManager 内存替身、secure_storage / SharedPreferences
  // / SystemChrome mock，取流接口用 `PlayerPage.api` 注入替身精确计数，
  // PlayView 用 `PlayerPage.playViewFetcher` 注入替身（生产里这条是真发 gRPC）。
  // -------------------------------------------------------------------------
  group('清晰度可见性：player_page 接线', () {
    /// 走完启动流程（`_init` 的两个 500ms 超时之后才落到取流）。
    Future<void> pumpPlayer(
      WidgetTester tester, {
      required _PvApi api,
      required Future<PlayUrlResult> Function(String, int) fetcher,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(411, 914);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: PlayerPage(video: _pvVideo(), api: api, playViewFetcher: fetcher),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('低于 720P + 已登录 → 提示一次；第二个播放页不再提示', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      debugResetPlayViewQualityNotice();
      _mockSecureStorageFor(tester, {kSessdataStorageKey: kFakeSessdataValid});
      _PvMocks().install(tester);
      final api = _PvApi(webStream: _pvStream(quality: 80, tag: 'web'));
      var fetches = 0;

      await pumpPlayer(tester, api: api, fetcher: (bvid, cid) async {
        fetches++;
        return _pvStream(quality: 32); // 480P：被降了
      });

      expect(fetches, 1);
      expect(api.webCalls, 0, reason: 'PlayView 成功就不该再打网页接口');
      expect(find.text(kPlayViewLowQualityNotice), findsOneWidget,
          reason: '用户必须当场知道清晰度被降了');
      expect(kPlayViewLowQualityNotice, contains('480P'));
      expect(kPlayViewLowQualityNotice, contains('access_key'));

      // 第二个播放页（同一次运行）：说明性提示只给一次，换集/换视频不再唠叨。
      // 注意先把整棵树换掉（连 ScaffoldMessenger 一起销毁）——只换 home 的话
      // 上一条提示条还挂在这个 messenger 上，下面的 findsNothing 会被它骗过。
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await pumpPlayer(tester, api: api, fetcher: (bvid, cid) async {
        fetches++;
        return _pvStream(quality: 32);
      });
      expect(fetches, 2, reason: '第二次播放照样走 PlayView');
      expect(find.text(kPlayViewLowQualityNotice), findsNothing,
          reason: '每会话一次：第二次不再提示');
    });

    testWidgets('低于 720P 但**未登录** → 不提示（那不是开关的锅）', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      debugResetPlayViewQualityNotice();
      _mockSecureStorageFor(tester, const {}); // 没登录
      _PvMocks().install(tester);
      final api = _PvApi(webStream: _pvStream(quality: 80, tag: 'web'));

      await pumpPlayer(tester, api: api, fetcher: (bvid, cid) async {
        return _pvStream(quality: 32);
      });

      expect(find.text(kPlayViewLowQualityNotice), findsNothing);
    });

    testWidgets('≥ 720P + 已登录 → 不提示（没被降就不用吓唬人）', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      debugResetPlayViewQualityNotice();
      _mockSecureStorageFor(tester, {kSessdataStorageKey: kFakeSessdataValid});
      _PvMocks().install(tester);
      final api = _PvApi(webStream: _pvStream(quality: 32, tag: 'web'));

      await pumpPlayer(tester, api: api, fetcher: (bvid, cid) async {
        return _pvStream(quality: 80); // 1080P：正常
      });

      expect(find.text(kPlayViewLowQualityNotice), findsNothing);
    });

    testWidgets('开关关掉（或本会话已自动回退）→ PlayView 完全不介入', (tester) async {
      _mockSecureStorageFor(tester, {kSessdataStorageKey: kFakeSessdataValid});
      _PvMocks().install(tester);
      final api = _PvApi(webStream: _pvStream(quality: 32, tag: 'web'));
      var fetches = 0;
      Future<PlayUrlResult> fetcher(String bvid, int cid) async {
        fetches++;
        return _pvStream(quality: 32);
      }

      // ① 开关关着（默认）
      UiPrefsStore.instance.resetForTest();
      debugResetPlayViewQualityNotice();
      await pumpPlayer(tester, api: api, fetcher: fetcher);
      expect(fetches, 0, reason: '关着 → 一个 PlayView 请求都不发');
      expect(api.webCalls, 1, reason: '关着 → 照旧走网页接口');
      expect(find.text(kPlayViewLowQualityNotice), findsNothing);

      // ② 开关开着但本会话已自动回退（[streamCompatInUse] 为假）→ 同样不介入。
      // 同样整棵树换掉（连 ScaffoldMessenger 一起销毁），免得旧提示条干扰断言。
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      UiPrefsStore.instance.resetForTest(
          streamCompatEnabled: true, streamCompatSessionFallback: true);
      await pumpPlayer(tester, api: api, fetcher: fetcher);
      expect(fetches, 0, reason: '回退后取流链路已换回网页接口');
      expect(api.webCalls, 2);
      expect(find.text(kPlayViewLowQualityNotice), findsNothing);
    });
  });
}
