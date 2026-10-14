// 播放页「清晰度」选择（v2.53.0）测试。
//
// 背景（用户原话）：「在播放界面下面弄一个可选择播放清晰度的。」
//
// 设计要点（本文件把它们钉成回归测试）：
//   1. **底栏入口**显示**这次实际下发**的档位（回落过就显示回落后的那一档），
//      没取到流时禁用入口；
//   2. **列表把拿不到的档位也列出来并标明原因**（`需登录` / `需大会员` /
//      `当前模式下不可用`）且**点不动** —— 点一个拿不到的东西只会黑屏；
//      PlayView（App 形态）匿名只有 480P/360P 这件事必须如实体现；
//   3. **选中后保持播放位置**换源（复用既有 `_switchStreamLine` 重取 playurl，
//      不重建播放器、不新写切源逻辑）；
//   4. **记住用户的选择**（落盘 `ui:preferred_quality`，下次进来默认用它；
//      没选过仍是 1080P）；
//   5. 用户选的档位**拿不到时回落 + 明确提示**（绝不静默）；
//   6. `qn` 一路打通：网页接口的 `qn` 查询参数 + PlayView 的 `PlayViewReq.qn`
//      （字段号 3，直接从 gRPC 请求体里解出来验）。
//
// 环境：假 HTTP（路由 nav / playurl / PlayView，并**记录请求体**）+
// `PlayerPage.api` 注入替身（网页取流可控 + 登录态可控）+ mock 播放器通道。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

/// 模拟器同款逻辑分辨率：1080x2400 @ density 420 → 约 411x914 dp。
const double _dpr = 2.625;

/// 用**真实形状**的 bvid：PlayView 的 `aid` 由纯算法从 bvid 换算
/// （`aidFromBvid`），随手编的编号可能算出 0（= 取不到，回落网页接口）。
/// 这个号来自 `playview_api_test.dart` 的实测样本（BV1GJ411x7h7 → 80433022）。
const String _kBvid = 'BV1GJ411x7h7';

/// 未过期的假 SESSDATA（形状必须能被 `BiliApi.sessdataExpireAt` 解析出时间）。
const String _kFakeSessdataValid = '123456,1893456000,FAKEHASHDONOTUSE';

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '清晰度测试视频',
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// 假 HTTP：路由 nav / playurl / PlayView，并记录每次请求（uri + body）
// ---------------------------------------------------------------------------

/// 一次被记录下来的请求。
class _Captured {
  _Captured(this.uri, this.body);

  final Uri uri;
  final List<int> body;
}

/// 本用例的 HTTP 桩状态（每个用例新建一份，避免串味）。
class _HttpStub {
  /// playurl 下发的清晰度（网页接口的 `quality`）。
  int quality = 80;

  /// playurl 声明支持的档位（`accept_quality`）。
  List<int> acceptQuality = const [80, 64, 32, 16];

  /// 匿名（未登录）时服务端最多给到哪一档（网页接口）。
  ///
  /// 夹具取 480P（保守档）：现实中未登录有时能拿到 720P（播放页横幅「未登录仅
  /// 720P」），但"匿名只给 480P"是更常见的形态，用例要靠它验「用户选的 1080P
  /// 拿不到 → 回落 + 提示」。两种形态在纯函数用例里都覆盖了。
  int anonymousMax = 32;

  /// PlayView 请求体（gRPC 帧）——「qn 有没有传到 PlayView」的取证点。
  final List<List<int>> playViewBodies = [];

  /// 所有请求（含 playurl 的 query，`qn` 就在里面）。
  final List<_Captured> requests = [];

  /// PlayView 列出的档位（含拿不到的）与实际下发档位。
  List<int> playViewListed = const [80, 74, 64, 32, 16];
  int playViewQuality = 32;

  List<_Captured> requestsTo(String pathSuffix) =>
      requests.where((r) => r.uri.path.endsWith(pathSuffix)).toList();
}

_HttpStub? _stub;

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      openUrl('GET', Uri.parse('http://$host:$port$path'));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.requestUri);

  final Uri requestUri;
  final List<int> _body = [];

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  int get contentLength => _body.length;
  @override
  set contentLength(int value) {}

  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.addAll(chunk);
    }
  }

  @override
  void write(Object? obj) => _body.addAll(utf8.encode(obj.toString()));

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    _body.addAll(utf8.encode(objects.join(separator)));
  }

  @override
  void writeCharCode(int charCode) => _body.add(charCode);

  @override
  void writeln([Object? obj = '']) {
    _body.addAll(utf8.encode(obj.toString()));
    _body.add(0x0A);
  }

  @override
  Future<HttpClientResponse> close() async {
    final stub = _stub!;
    stub.requests.add(_Captured(requestUri, List<int>.of(_body)));
    final path = requestUri.path;
    // PlayView 是 POST + gRPC 帧（响应体是二进制），其余是 JSON
    if (path.endsWith('/PlayView')) {
      stub.playViewBodies.add(List<int>.of(_body));
      return _FakeHttpResponse.bytes(_playViewReplyBytes(stub));
    }
    return _FakeHttpResponse.json(_route(requestUri));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  _FakeHttpResponse.json(Map<String, dynamic> body)
      : _bytes = utf8.encode(jsonEncode(body)),
        _contentType = 'application/json; charset=utf-8';

  _FakeHttpResponse.bytes(List<int> bytes)
      : _bytes = bytes,
        _contentType = 'application/grpc';

  final List<int> _bytes;
  final String _contentType;

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK';

  @override
  int get contentLength => _bytes.length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpHeaders get headers {
    final h = _FakeHttpHeaders();
    h.add('content-type', _contentType);
    return h;
  }

  Stream<Uint8List> get handle =>
      Stream<Uint8List>.fromIterable([Uint8List.fromList(_bytes)]);

  @override
  Stream<R> cast<R>() => handle.cast<R>();

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      handle.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      add(name, value);

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) => _map[name.toLowerCase()]?.first;

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _route(Uri uri) {
  final path = uri.path;
  if (path.endsWith('/x/web-interface/nav')) {
    return {
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/11a8a4f1a25f41b4e05e02d6f2b4b3a3.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/0e146c531c4e43e20a7cfb1a3d4f5a5b.png',
        },
      },
    };
  }
  if (path.endsWith('/x/frontend/finger/spi')) {
    return {
      'code': 0,
      'data': {'b_3': 'buvid3x', 'b_4': 'buvid4x'},
    };
  }
  if (path.contains('playurl')) {
    final stub = _stub!;
    // 服务端"按 qn 下发"：真发请求的用例（验 qn 查询参数）靠它把 qn 映射成档位
    final qn = int.tryParse(uri.queryParameters['qn'] ?? '') ?? 0;
    return {
      'code': 0,
      'data': {
        'quality': qn > 0 ? qn : stub.quality,
        'accept_quality': stub.acceptQuality,
        'dash': {
          'video': [
            {'baseUrl': 'https://x.bilivideo.com/v${stub.quality}.m4s'},
          ],
          'audio': [
            {'baseUrl': 'https://x.bilivideo.com/a.m4s'},
          ],
        },
      },
    };
  }
  return {'code': 0, 'data': {}};
}

// ---- PlayViewReply 的最小 protobuf 编码（构造响应夹具用） ----

List<int> _varint(int n) {
  final out = <int>[];
  var v = n;
  while (true) {
    final b = v & 0x7F;
    v >>= 7;
    if (v != 0) {
      out.add(b | 0x80);
    } else {
      out.add(b);
      return out;
    }
  }
}

List<int> _fVarint(int field, int n) =>
    [..._varint((field << 3) | 0), ..._varint(n)];

List<int> _fBytes(int field, List<int> b) =>
    [..._varint((field << 3) | 2), ..._varint(b.length), ...b];

List<int> _fStr(int field, String s) => _fBytes(field, utf8.encode(s));

/// 拼一份 `PlayViewReply`：`video_info{quality, stream_list[], dash_audio[]}`。
///
/// [listed] 里**不超过实际下发档位**的档位给 `dash_video`（能播）；超过
/// [playViewListed] 之外的更高档位只带 `stream_info` + 非零 `err_code`（无权限，
/// 正是真实形态）→ 解析层过滤掉它们但保留档位号（列表要拿它说明「需登录」）。
///
/// **实际下发档位会尊重请求里的 `qn`**（服务端按你请求的档位给，最多给到匿名
/// 上限）：这样「换个低档位 → 真的换成那条流」才验得出来。
List<int> _playViewReplyBytes(_HttpStub stub) {
  final requested = stub.playViewBodies.isEmpty
      ? 0
      : (pbFirst(
              grpcUnframe(Uint8List.fromList(stub.playViewBodies.last)), 3,
              wantVarint: true) as int?) ??
          0;
  final maxQ = requested > 0
      ? math.min(stub.playViewQuality, requested)
      : stub.playViewQuality;
  final videoInfo = <int>[..._fVarint(1, maxQ)];
  for (final q in stub.playViewListed) {
    // 每个 Stream 是**独立的一个 field 5**（repeated 字段：一条一个 key，
    // 不能把多条拼成一个 blob——拼了就只有第一条会被解析到）
    final stream = <int>[
      ..._fBytes(1, <int>[
        ..._fVarint(1, q),
        if (q > stub.playViewQuality) ..._fVarint(4, 10403), // 非零 = 无权限
      ]),
      if (q <= maxQ) ..._fBytes(2, _fStr(1, 'https://x.bilivideo.com/pv$q.m4s')),
    ];
    videoInfo.addAll(_fBytes(5, stream));
  }
  videoInfo.addAll(_fBytes(6, [
    ..._fVarint(1, 30216),
    ..._fStr(2, 'https://x.bilivideo.com/pva.m4s'),
  ]));
  // PlayViewReply.video_info = 字段 1（length-delimited）
  final reply = <int>[..._fBytes(1, videoInfo)];
  return Uint8List.fromList(grpcFrame(Uint8List.fromList(reply)));
}

// ---------------------------------------------------------------------------
// 注入替身与播放器桩
// ---------------------------------------------------------------------------

/// 网页取流替身：记录每次请求的 `qn`，返回可配置的流（也可指定抛错）。
class _FakeApi extends BiliApi {
  _FakeApi({this.loggedIn = false});

  bool loggedIn;

  /// 每次 `fetchPlayUrl` 收到的 `qn`（顺序）。
  final List<int> qns = [];

  /// 非 null 时用它的返回值当结果（按收到的 qn 决定下发档位）。
  PlayUrlResult Function(int qn)? respond;

  /// 非 null 时抛这个错（模拟取流失败）。
  Object? throwOnFetch;

  /// true = 走**真实**的 `fetchPlayUrl`（真发 HTTP，用来验 `qn` 查询参数）；
  /// false = 直接返回构造好的结果（快，且不受 HTTP 桩细节影响）。
  bool useRealFetch = false;

  @override
  Future<String?> readSessdata() async =>
      loggedIn ? _kFakeSessdataValid : null;

  @override
  Future<PlayUrlResult> fetchPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    int fnval = 0,
  }) async {
    qns.add(qn);
    final err = throwOnFetch;
    if (err != null) throw err;
    if (useRealFetch) {
      return super.fetchPlayUrl(bvid: bvid, cid: cid, qn: qn, fnval: fnval);
    }
    final custom = respond;
    if (custom != null) return custom(qn);
    final stub = _stub!;
    // 真实行为：按登录态封顶（匿名只能到这个档），再取 accept_quality 里不超过
    // 请求值的最高档下发 —— 这样"用户选的档位拿不到 → 服务端给更低的档"才对得上
    final cap = loggedIn ? 1 << 30 : stub.anonymousMax;
    final ok =
        stub.acceptQuality.where((q) => q <= qn && q <= cap).toList()..sort();
    final delivered = ok.isEmpty ? (stub.quality <= cap ? stub.quality : cap) : ok.last;
    return PlayUrlResult(
      quality: delivered,
      dashVideoUrls: ['https://x.bilivideo.com/v$delivered.m4s'],
      dashVideoLines: [
        ['https://x.bilivideo.com/v$delivered.m4s']
      ],
      dashAudioUrls: const ['https://x.bilivideo.com/a.m4s'],
      dashAudioIds: const [30216],
      dashAudioBandwidths: const [64000],
      dashAudioLines: const [
        ['https://x.bilivideo.com/a.m4s']
      ],
      acceptQuality: stub.acceptQuality,
    );
  }
}

/// 播放器桩：记录 setDataSource 的位置，`getPosition` 返回 [positionMs]。
class _PlayerStub {
  int positionMs = 0;
  int createCount = 0;
  final List<Map<Object?, Object?>> dataSources = [];

  void install(WidgetTester tester) {
    MockStreamHandlerEventSink? sink;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        switch (call.method) {
          case 'create':
            createCount++;
            return 7;
          case 'getPosition':
            return positionMs;
          case 'setDataSource':
            final map = call.arguments as Map;
            dataSources.add(map.cast<Object?, Object?>());
            sink?.success({
              'event': 'onPrepared',
              'textureId': map['textureId'],
              'width': 1280,
              'height': 720,
              'durationMs': 600000,
              'playWhenReady': true,
            });
          default:
            break;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bili_dash_player'), null));

    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          sink = events;
        },
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
        const EventChannel('bili_dash_player/events'), null));

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // secure storage：一律 null（未登录时读不到东西；登录态由 _FakeApi 决定）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        ));
  }
}

class _EmptyManager extends DownloadManager {
  _EmptyManager() {
    cached.value = const [];
  }
}

/// 挂载播放页并等取流 + onPrepared 走完。
Future<void> _pumpPlayer(
  WidgetTester tester,
  _FakeApi api, {
  Size size = const Size(1080, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video(), api: api)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 50));
}

Finder _inSheet(Finder matching) =>
    find.descendant(of: find.byType(BottomSheet), matching: matching);

/// 解出一次 PlayView 请求体里的 `PlayViewReq.qn`（字段号 3，varint）。
int _playViewQnOf(List<int> grpcBody) {
  final body = grpcUnframe(Uint8List.fromList(grpcBody));
  return pbFirst(body, 3, wantVarint: true)! as int;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _stub = _HttpStub();
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest();
    debugResetPlayViewQualityNotice();
    DownloadManager.debugOverride(_EmptyManager());
  });

  tearDown(() {
    DownloadManager.debugReset();
    UiPrefsStore.instance.resetForTest();
    debugResetPlayViewQualityNotice();
    _stub = null;
  });

  // -------------------------------------------------------------------------
  // A. 纯函数：哪些能点、哪些不能点、为什么
  // -------------------------------------------------------------------------
  group('清晰度列表判定（纯函数）', () {
    test('网页接口匿名：480P/360P 可选，720P/1080P 标「需登录」', () {
      final choices = buildQualityChoices(
        declared: const [80, 64, 32, 16],
        actualQuality: 32,
        appMode: false,
        loggedIn: false,
      );
      expect(choices.map((c) => c.quality).toList(), [80, 64, 32, 16],
          reason: '从高到低（与 B 站一致）');
      expect(choices[0].label, '1080P');
      expect(choices[0].enabled, isFalse);
      expect(choices[0].reason, '需登录');
      expect(choices[1].reason, '需登录', reason: '720P 起要登录（未登录仅 720P）');
      expect(choices[2].enabled, isTrue);
      expect(choices[2].reason, isNull);
      expect(choices[3].enabled, isTrue, reason: '已实测 480P → 360P 必然也能拿');
    });

    test('网页接口已登录：实测 1080P → 四档全可选', () {
      final choices = buildQualityChoices(
        declared: const [80, 64, 32, 16],
        actualQuality: 80,
        appMode: false,
        loggedIn: true,
      );
      expect(choices.every((c) => c.enabled), isTrue);
      expect(choices.every((c) => c.reason == null), isTrue);
    });

    test('App 形态匿名：480P/360P 可选，720P 起标「需登录」（access_key 拿不到）',
        () {
      final choices = buildQualityChoices(
        declared: const [80, 74, 64, 32, 16],
        actualQuality: 32,
        appMode: true,
        loggedIn: false,
      );
      expect(choices.firstWhere((c) => c.quality == 80).reason, '需登录');
      expect(choices.firstWhere((c) => c.quality == 64).reason, '需登录',
          reason: 'App 形态 720P 起就要 access_key，阈值比网页接口低一档');
      expect(choices.firstWhere((c) => c.quality == 32).enabled, isTrue);
      expect(choices.firstWhere((c) => c.quality == 16).enabled, isTrue);
    });

    test('App 形态匿名 + 接口没列高档位：补上 1080P/720P 并标「需登录」', () {
      final choices = buildQualityChoices(
        declared: const [32, 16],
        actualQuality: 32,
        appMode: true,
        loggedIn: false,
      );
      expect(choices.map((c) => c.quality).toList(), [80, 64, 32, 16],
          reason: 'PlayView 匿名可能根本不列 720P+ → 补出来才说得清"为什么没有"');
      expect(choices.firstWhere((c) => c.quality == 80).reason, '需登录');
      expect(choices.firstWhere((c) => c.quality == 80).enabled, isFalse);
    });

    test('网页接口 480P 老视频（接口只列 480P/360P）：**不**凭空补 1080P', () {
      final choices = buildQualityChoices(
        declared: const [32, 16],
        actualQuality: 32,
        appMode: false,
        loggedIn: true,
      );
      expect(choices.map((c) => c.quality).toList(), [32, 16],
          reason: '网页 accept_quality 是完整的，补了会在老视频上凭空多一个 1080P');
    });

    test('会员档标「需大会员」（1080P+ 及以上）', () {
      final choices = buildQualityChoices(
        declared: const [120, 112, 80, 32],
        actualQuality: 80,
        appMode: false,
        loggedIn: true,
      );
      expect(choices.firstWhere((c) => c.quality == 120).reason, '需大会员');
      expect(choices.firstWhere((c) => c.quality == 112).reason, '需大会员');
      expect(choices.firstWhere((c) => c.quality == 80).enabled, isTrue);
    });

    test('接口一个档位都没给：退化为「实测档位 + 更低的标准档」', () {
      final choices = buildQualityChoices(
        declared: const [],
        actualQuality: 80,
        appMode: false,
        loggedIn: true,
      );
      expect(choices.map((c) => c.quality).toList(), [80, 64, 32, 16]);
      expect(choices.every((c) => c.enabled), isTrue,
          reason: '都 ≤ 已实测档位');
    });

    test('档位未知（还没取到流）：列表为空，不瞎猜', () {
      expect(
        buildQualityChoices(
          declared: const [],
          actualQuality: 0,
          appMode: false,
          loggedIn: false,
        ),
        isEmpty,
      );
    });

    test('回落文案把"为什么"和"回落到哪"都说清', () {
      expect(
        qualityFallbackNotice(requested: 80, actualQuality: 32, reason: '需登录'),
        '1080P 需登录，已回落 480P',
      );
    });

    test('换清晰度必须重取 playurl（不在旧候选线路里轮转）', () {
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.quality, hasNextLine: true),
        isTrue,
        reason: '候选线路是上一档的 URL，轮转它等于用旧档位冒充新选择',
      );
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.quality, hasNextLine: false),
        isTrue,
      );
      // 既有语义不受影响
      expect(
        shouldReloadStreamUrl(
            cause: StreamSwitchCause.lineError, hasNextLine: true),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // B. widget：入口 / 列表 / 切换 / 持久化 / 回落 / qn 打通
  // -------------------------------------------------------------------------
  group('底栏「清晰度」入口与列表（widget）', () {
    testWidgets('底栏显示实际档位；列表只把能拿到的列为可选、其余标原因且点不动',
        (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.quality = 32; // 匿名实际只给 480P
      stub.acceptQuality = const [80, 64, 32, 16];
      _PlayerStub().install(tester);
      final api = _FakeApi(); // 未登录

      await _pumpPlayer(tester, api);

      // 底栏入口显示**实际**档位（不是用户意愿的 1080P）
      expect(find.text('480P'), findsOneWidget,
          reason: '标签跟画面走：回落过就显示回落后的档位');

      await tester.tap(find.text('480P'));
      await tester.pumpAndSettle();
      expect(find.text('清晰度'), findsWidgets, reason: '弹窗标题（与入口文案同名）');

      // 四档都在列表里
      for (final label in ['1080P', '720P', '480P', '360P']) {
        expect(_inSheet(find.text(label)), findsOneWidget, reason: '$label 应列出');
      }
      // 拿不到的两档标明原因
      expect(_inSheet(find.text('需登录')), findsNWidgets(2),
          reason: '1080P / 720P 都要登录（匿名）');

      // 点拿不到的档位：弹窗不关、不选中（onTap: null）
      await tester.tap(_inSheet(find.text('1080P')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget,
          reason: '拿不到的档位点了必须没反应（绝不能选中后黑屏）');
      expect(api.qns, [80], reason: '没触发任何新的取流');
      expect(UiPrefsStore.instance.preferredQuality, 80, reason: '偏好没被改');

      // 选 360P：关弹窗、记住选择、按新 qn 重取流
      await tester.tap(_inSheet(find.text('360P')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(api.qns, [80, 16], reason: '换档位要按新的 qn=16 重取流');
      expect(UiPrefsStore.instance.preferredQuality, 16, reason: '选择被记住（落盘）');
      expect(find.text('360P'), findsOneWidget, reason: '底栏标签跟着新档位走');
    });

    testWidgets('切换清晰度保持播放位置，且不重建播放器', (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.quality = 80;
      stub.acceptQuality = const [80, 64, 32, 16];
      final rec = _PlayerStub()..install(tester);
      final api = _FakeApi(loggedIn: true);

      await _pumpPlayer(tester, api);
      expect(rec.createCount, 1);
      expect(rec.dataSources.length, 1);
      expect(find.text('1080P'), findsOneWidget);

      rec.positionMs = 42500; // 看到 42.5s 处去换清晰度

      await tester.tap(find.text('1080P'));
      await tester.pumpAndSettle();
      await tester.tap(_inSheet(find.text('480P')));
      await tester.pumpAndSettle();

      expect(rec.createCount, 1, reason: '换档位复用换源机制，不重建播放器');
      expect(rec.dataSources.length, 2, reason: '第二次 setDataSource = 新档位的流');
      expect(rec.dataSources.last['positionMs'], 42500,
          reason: '从当前位置续播（不回到片头）');
      expect(find.text('480P'), findsOneWidget, reason: '底栏标签跟着新档位走');
      expect(UiPrefsStore.instance.preferredQuality, 32);
    });

    testWidgets('用户选的档位拿不到 → 回落到能拿到的最高档 + 明确提示', (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.quality = 32;
      stub.acceptQuality = const [80, 64, 32, 16];
      _PlayerStub().install(tester);
      final api = _FakeApi(); // 未登录：默认选的 1080P 拿不到

      await _pumpPlayer(tester, api);

      expect(api.qns, [80], reason: '默认仍按 1080P 请求（默认值不变）');
      expect(find.text('1080P 需登录，已回落 480P'), findsOneWidget,
          reason: '回落必须明说（含原因与落到哪一档），不能静默');
      expect(find.text('480P'), findsOneWidget, reason: '底栏显示实际档位');
    });

    testWidgets('切换失败 → 不把失败的选择留在设置里，并明说一句', (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.quality = 80;
      stub.acceptQuality = const [80, 64, 32, 16];
      _PlayerStub().install(tester);
      final api = _FakeApi(loggedIn: true);

      await _pumpPlayer(tester, api);
      api.throwOnFetch = const BiliApiException(
          code: -404, message: '取不到流', path: '/x/player/wbi/playurl');

      await tester.tap(find.text('1080P'));
      await tester.pumpAndSettle();
      await tester.tap(_inSheet(find.text('480P')));
      await tester.pumpAndSettle();

      expect(UiPrefsStore.instance.preferredQuality, 80,
          reason: '失败的选择要回滚（否则设置里留着一个真的做不到的档位）');
      expect(find.text('切换清晰度失败，保持 1080P'), findsOneWidget);
    });

    testWidgets('App 形态：用户选的档位作为 PlayViewReq.qn 传下去（字段号 3）',
        (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.playViewListed = const [80, 74, 64, 32, 16];
      stub.playViewQuality = 32;
      _PlayerStub().install(tester);
      // 「免流兼容（实验）」开着 + 用户上次选的是 480P（不是默认的 1080P）
      UiPrefsStore.instance
          .resetForTest(streamCompatEnabled: true, preferredQuality: 32);
      final api = _FakeApi()
        ..throwOnFetch = StateError('PlayView 成功时不该再打网页接口（测试构造）');

      await _pumpPlayer(tester, api);

      expect(stub.playViewBodies, hasLength(1), reason: '走了 PlayView');
      expect(_playViewQnOf(stub.playViewBodies.single), 32,
          reason: '用户选的档位必须进 PlayViewReq.qn（字段 3），不再写死 80');
      expect(find.text('480P'), findsOneWidget,
          reason: 'App 形态匿名最多 480P → 底栏如实显示实际档位');

      // 列表里 720P/1080P 照列但标「需登录」
      await tester.tap(find.text('480P'));
      await tester.pumpAndSettle();
      expect(_inSheet(find.text('1080P')), findsOneWidget);
      expect(_inSheet(find.text('720P')), findsOneWidget);
      expect(_inSheet(find.text('需登录')), findsNWidgets(3),
          reason: '1080P / 720P60 / 720P 都要 access_key');

      // 选 360P → 带新的 qn 重取一次 PlayView
      await tester.tap(_inSheet(find.text('360P')));
      await tester.pumpAndSettle();
      expect(stub.playViewBodies, hasLength(2), reason: '换档位重取一次 PlayView');
      expect(_playViewQnOf(stub.playViewBodies.last), 16);
      expect(find.text('360P'), findsOneWidget, reason: '底栏跟着新档位走');
    });

    testWidgets('App 形态匿名：只有 480P/360P —— 列表如实体现 + 回落明说',
        (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.playViewListed = const [80, 74, 64, 32, 16];
      stub.playViewQuality = 32;
      _PlayerStub().install(tester);
      // 「免流兼容（实验）」开着（用户没选过清晰度 → 默认仍是 1080P）
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final api = _FakeApi()
        ..throwOnFetch = StateError('PlayView 成功时不该再打网页接口（测试构造）');

      await _pumpPlayer(tester, api);

      expect(_playViewQnOf(stub.playViewBodies.single), 80,
          reason: '默认档位仍是 1080P（不因加了清晰度选择而改默认）');
      expect(find.text('480P'), findsOneWidget, reason: '实际下发只有 480P');
      expect(find.text('1080P 需登录，已回落 480P'), findsOneWidget,
          reason: '未登录时 kPlayViewLowQualityNotice（要求已登录）不弹 → '
              '这条回落提示就是用户唯一能看到的说明，绝不许静默降级');

      await tester.tap(find.text('480P'));
      await tester.pumpAndSettle();
      // 接口列出的 5 档全在列表里，但只有实拿到的两档可选
      for (final label in ['1080P', '720P60', '720P', '480P', '360P']) {
        expect(_inSheet(find.text(label)), findsOneWidget, reason: '$label 应列出');
      }
      expect(_inSheet(find.text('需登录')), findsNWidgets(3),
          reason: 'PlayView 的 720P+ 全要 access_key（服务端 need_login）——'
              'PlayView 匿名只有 480P/360P 这件事必须如实体现');

      // 只有 480P/360P 可选：点 360P 真的换过去
      await tester.tap(_inSheet(find.text('360P')));
      await tester.pumpAndSettle();
      expect(_playViewQnOf(stub.playViewBodies.last), 16);
      expect(UiPrefsStore.instance.preferredQuality, 16);
      expect(find.text('360P'), findsOneWidget);
    });

    testWidgets('网页接口：qn 查询参数跟着用户选择走', (tester) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = oldOverrides);

      final stub = _stub!;
      stub.quality = 80;
      stub.acceptQuality = const [80, 64, 32, 16];
      _PlayerStub().install(tester);
      UiPrefsStore.instance.resetForTest(preferredQuality: 64); // 上次选了 720P
      final api = _FakeApi(loggedIn: true)..useRealFetch = true;

      await _pumpPlayer(tester, api);

      final playurls = stub.requestsTo('/x/player/wbi/playurl');
      expect(playurls, isNotEmpty, reason: '走的是真实 fetchPlayUrl（会带 qn 查询参数）');
      expect(playurls.first.uri.queryParameters['qn'], '64',
          reason: '网页接口的 qn 不再是写死的 80');
      expect(api.qns.first, 64);
      expect(find.text('720P'), findsOneWidget, reason: '底栏显示下发的档位');
    });
  });
}
