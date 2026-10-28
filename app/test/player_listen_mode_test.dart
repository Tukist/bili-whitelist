// v2.55.0「听视频」= **真的只拉音频轨**（视频轨零请求）widget 测试。
//
// 背景（用户原话）：「之前的听视频只是遮盖了播放界面，花的流量是一点也不少。
// 我需要只花音频流量的方案。」旧实现只把画面 Offstage 掉，视频轨照常下载。
// 本文件覆盖新契约：
//   1. 进入听视频 → setDataSource 收到 **videoUrl 为空** + `audioOnly: true`
//      （原生据此只建音频源、不建 MergingMediaSource → 视频轨零请求），
//      audioUrl = 当前那条音频轨；位置用 getPosition 真值（不清零）；
//   2. 退出听视频 → 恢复视频轨（videoUrl 非空 + 位置沿用），不重取 playurl；
//   3. 本地缓存音频命中 → 播 `file://` 本地音频（零流量），且没有任何音频流
//      网络请求；
//   4. 拿不到独立音频轨（mp4 单流）→ 提示 kListenNoAudioNotice + **不切模式**
//      （视频照常播，绝不静默「开着听视频只播视频」）；
//   5. 听视频中音频轨失效（onUrlExpired 重取后 dash.audio 消失）→ 提示 +
//      回落视频播放（带位置），不卡黑屏。
//
// 环境（与既有 player_* 测试同款）：播放器 MethodChannel/EventChannel 手工 mock
// （setDataSource 立即回 onPrepared）；HTTP 用假 HttpClient（**记录每一次请求
// URL**，当「应用侧有没有偷偷取流」的观测点）。
//
// 「没有音频网络请求」怎么验：本套件里 flutter_test 的 binding 会把 `HttpClient`
// 全局换成「一律 400、不发真实请求」的桩，所以再绑一个**真 loopback 服务器**
// （[ServerSocket]）当流地址的 origin，统计「打到它的真实连接数」——setUp 里先
// 自检一次计数器（真连一下），避免「0 次」是「压根没计数」的假绿。
// 真正的因果证据是：播放器收到的是 `file://`（文件地址不可能产生网络流量）
// + 应用侧请求日志里没有任何流地址。
//
// ⚠️ 边界（本机验不了的部分，见交付说明）：播放器是桩，**原生侧真的不发视频轨
// 请求**由 `audioOnly` 契约（视频 URL 为空）+ DashExoPlayer.prepare 的
// `audioOnly` 分支（只建音频源）保证；真机流量/解码器对「无视频轨」的表现
// 需真机验证。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvidNet = 'BV1LISTEN001'; // 未缓存 → 听视频走网络音频轨
const String _kBvidLocal = 'BV1LISTEN002'; // 已缓存 → 听视频走本地音频文件

/// 原生侧「当前播放位置」：进出听视频都必须原样带进新源（不许清零重放）。
const int _kResumeMs = 42000;

/// 流地址 origin 的 loopback 端口（setUp 里绑定；playurl 里的流地址指向它）。
int _loopbackPort = 0;

/// 连到流 origin 的**真实 socket 连接数**（进入听视频后必须仍是 0）。
///
/// 用 [ServerSocket] 而不是 [HttpServer]：flutter_test 的 binding 会把
/// `HttpClient` 全局替换成「一律 400、不发真实请求」的桩（本套件启动时就会
/// 打印那条 warning），只有裸 socket 才是真连接 —— 计数器因此有实际意义。
int _streamConnections = 0;

WhitelistVideo _video(String bvid, String title) => WhitelistVideo(
      bvid: bvid,
      cid: 1001,
      title: title,
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

CachedVideo _cached(String bvid) => CachedVideo(
      bvid: bvid,
      title: bvid,
      cover: '',
      pageIndex: 0,
      partTitle: '',
      videoPath: 'C:/cache/${bvid}_p1.video.m4s',
      audioPath: 'C:/cache/${bvid}_p1.audio.m4s',
      sizeBytes: 2048,
      cachedAt: DateTime(2026, 1, 1),
      upName: '测试UP主',
      cid: 1001,
      durationMs: 600000,
      audioOnly: false,
    );

/// 内存版 DownloadManager（零真实 IO；缓存命中判定走真实现）。
class _FakeManager extends DownloadManager {
  _FakeManager(List<CachedVideo> items) {
    cached.value = List.unmodifiable(items);
  }
}

// ---------------------------------------------------------------------------
// 假 HTTP：返回合法 JSON，并记录每一次请求 URL
// ---------------------------------------------------------------------------

class _HttpState {
  /// 应用侧发出的所有请求 URL（断言「没有音频流请求」用）。
  final List<Uri> requests = [];

  /// true → playurl 只给 mp4 单流（`durl`，没有独立音频轨）。
  bool mp4Only = false;

  /// true → playurl 的 dash 只剩视频轨（模拟「重取后音频轨消失」）。
  bool audioGone = false;
}

/// 流地址的 origin（loopback）：视频/音频都指向它，便于统计命中数。
String get _videoStreamUrl => 'http://127.0.0.1:$_loopbackPort/v.m4s';
String get _audioStreamUrl => 'http://127.0.0.1:$_loopbackPort/a.m4s';

Map<String, dynamic> _route(Uri uri, _HttpState state) {
  state.requests.add(uri);
  final path = uri.path;
  if (path.endsWith('/x/frontend/finger/spi')) {
    return {
      'code': 0,
      'data': {'b_3': 'buvid3x', 'b_4': 'buvid4x'},
    };
  }
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
  if (path.endsWith('/x/web-interface/view')) {
    return {
      'code': 0,
      'data': {
        'bvid': _kBvidNet,
        'aid': 1001,
        'cid': 1001,
        'title': '听视频测试',
        'pic': '',
        'duration': 600,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '',
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '', 'duration': 600},
        ],
      },
    };
  }
  if (path.endsWith('/x/v2/reply/main')) {
    return {
      'code': 0,
      'data': {
        'replies': [],
        'top_replies': [],
        'cursor': {'is_end': true},
      },
    };
  }
  if (path.contains('playurl')) {
    if (state.mp4Only) {
      // 老视频/试看流：只有 mp4 单流（音画在同一个文件里，没有独立音频轨）
      return {
        'code': 0,
        'data': {
          // 档位与请求一致（80）：否则会先弹一条「清晰度回落」提示，把
          // 本用例要断言的那条提示挤在 SnackBar 队列后面（4 秒后才轮到）
          'quality': 80,
          'durl': [
            {'url': '$_videoStreamUrl/mp4.mp4'},
          ],
        },
      };
    }
    return {
      'code': 0,
      'data': {
        'quality': 80,
        'dash': {
          'video': [
            {'baseUrl': _videoStreamUrl},
          ],
          'audio': [
            if (!state.audioGone) {'baseUrl': _audioStreamUrl, 'bandwidth': 132000},
          ],
        },
      },
    };
  }
  return {'code': 0, 'data': {}};
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides(this.state);

  final _HttpState state;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(state);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.state);

  final _HttpState state;

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
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url, state);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(url, state);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.requestUri, this.state);

  final Uri requestUri;
  final _HttpState state;
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
  Future<HttpClientResponse> close() async =>
      _FakeHttpResponse(_route(requestUri, state));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  _FakeHttpResponse(this.body);

  final Map<String, dynamic> body;

  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => 0;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpHeaders get headers {
    final h = _FakeHttpHeaders();
    h.add('content-type', 'application/json; charset=utf-8');
    return h;
  }

  Stream<List<int>> get handle =>
      Stream<List<int>>.fromIterable([utf8.encode(jsonEncode(body))]);

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
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map[name.toLowerCase()] = [value.toString()];

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      add(name, value);

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) => _map[name.toLowerCase()]?.first;

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _map.forEach(action);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// 播放器通道 mock：记录 setDataSource 的**每一个字段**
// ---------------------------------------------------------------------------

class _PlayerRec {
  final List<Map<Object?, Object?>> dataSources = [];

  Map<Object?, Object?>? get last =>
      dataSources.isEmpty ? null : dataSources.last;

  String? get lastVideoUrl => last?['videoUrl'] as String?;
  String? get lastAudioUrl => last?['audioUrl'] as String?;
  int? get lastPositionMs => last?['positionMs'] as int?;
  bool get lastAudioOnly => (last?['audioOnly'] as bool?) ?? false;

  /// 第 [index] 次 setDataSource 的 videoUrl（null = 没这么多次）。
  String? videoUrlAt(int index) =>
      index < dataSources.length
          ? dataSources[index]['videoUrl'] as String?
          : null;
}

class _Mocks {
  _Mocks(this.rec);

  final _PlayerRec rec;
  MockStreamHandlerEventSink? sink;
  static const int textureId = 7;

  void emit(String event) {
    sink?.success({
      'event': event,
      'textureId': textureId,
    });
  }

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        switch (call.method) {
          case 'create':
            return textureId;
          case 'getPosition':
            // 原生侧真实位置：进出听视频都要带上它（断言「位置不归零」）
            return _kResumeMs;
          case 'setDataSource':
            final map = call.arguments as Map;
            rec.dataSources.add(map.cast<Object?, Object?>());
            sink?.success({
              'event': 'onPrepared',
              'textureId': map['textureId'],
              // 只听音频时原生没有视频轨 → videoSize 恒 0x0（audioOnly 时）
              'width': 0,
              'height': 0,
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
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('bili_dash_player/events'), null));

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null));
  }
}

/// 起播到「已就绪」：`_init` 里 `_downloads.init()` / `PlaybackProgress.load()`
/// 各带 500ms 超时兜底，必须把时间推过 500ms 才会走到取源。
Future<void> _pumpPlayerReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 点一下底栏听视频开关并在假时钟里走完 setDataSource + onPrepared。
Future<void> _tapListenToggle(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _mount(WidgetTester tester, WhitelistVideo video) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(411, 914);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: video)));
  await _pumpPlayerReady(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _streamConnections = 0;
    // 真 loopback 流服务器（裸 socket）：统计「有多少连接打到流 origin」。
    // 播放器是桩、不会真去取流，所以 0 本身不算证据 —— 下面先自检一次，证明
    // 计数器真的在数（避免「0 次」是「压根没计数」的假绿）。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _loopbackPort = server.port;
    server.listen((socket) {
      _streamConnections++;
      socket.destroy();
    });
    addTearDown(() => server.close());
    final probe = await Socket.connect(InternetAddress.loopbackIPv4, _loopbackPort);
    probe.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(_streamConnections, 1, reason: 'loopback 计数器自检：它必须真的在计数');
    _streamConnections = 0;
  });

  testWidgets('进入听视频 → videoUrl 为空 + audioOnly；退出恢复视频轨且位置不丢',
      (tester) async {
    final state = _HttpState();
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(state);
    addTearDown(() => HttpOverrides.global = old);
    final rec = _PlayerRec();
    _Mocks(rec).install(tester);
    DownloadManager.debugOverride(_FakeManager(const []));

    await _mount(tester, _video(_kBvidNet, '听视频网络流'));

    // 起播：正常双流（视频轨 + 音频轨），audioOnly 未传
    expect(rec.dataSources, hasLength(1));
    expect(rec.lastVideoUrl, _videoStreamUrl);
    expect(rec.lastAudioUrl, _audioStreamUrl);
    expect(rec.lastAudioOnly, isFalse);

    await _tapListenToggle(tester, '听视频');

    // 1) 播放器收到的**视频 URL 为空** → 原生不建视频源 → 视频轨零请求
    expect(rec.dataSources, hasLength(2), reason: '进入听视频要重设数据源');
    expect(rec.lastVideoUrl, isEmpty,
        reason: '听视频模式下 videoUrl 必须为空（否则视频轨照常下载）');
    expect(rec.lastAudioOnly, isTrue, reason: '原生据此只建音频源');
    expect(rec.lastAudioUrl, _audioStreamUrl, reason: '音频轨照常给');
    expect(rec.lastPositionMs, _kResumeMs,
        reason: '切换不清零位置（getPosition 真值带进新源）');
    expect(_streamConnections, 0,
        reason: '没有任何连接打到流 origin（视频/音频都没被取）');
    expect(state.requests.where((u) => u.path.endsWith('.m4s')), isEmpty,
        reason: 'Dart 侧也不许自己去抓流（流请求只由原生播放器发）');

    // 占位层如实说明「只加载音频」
    expect(find.text('听视频中'), findsOneWidget);
    expect(find.textContaining('只加载音频，不请求视频画面'), findsOneWidget);

    // 2) 退出：恢复视频轨（复用已解析 URL，不重取 playurl）+ 位置不丢
    await _tapListenToggle(tester, '听视频中');

    expect(rec.dataSources, hasLength(3));
    expect(rec.lastVideoUrl, _videoStreamUrl, reason: '退出后视频轨必须回来');
    expect(rec.lastAudioOnly, isFalse, reason: '不再是只听音频');
    expect(rec.lastPositionMs, _kResumeMs, reason: '退出也不回 0');
    expect(find.text('听视频'), findsOneWidget, reason: '底栏恢复未开启态');
    expect(
        state.requests.where((u) => u.path.contains('playurl')).length, 1,
        reason: '退出只复用已有 URL，不再打一次 playurl');
  });

  testWidgets('本地缓存音频命中 → 播 file:// 本地音频，零音频网络请求',
      (tester) async {
    final state = _HttpState();
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(state);
    addTearDown(() => HttpOverrides.global = old);
    final rec = _PlayerRec();
    _Mocks(rec).install(tester);
    DownloadManager.debugOverride(_FakeManager([_cached(_kBvidLocal)]));

    await _mount(tester, _video(_kBvidLocal, '听视频本地缓存'));

    // 起播即本地缓存（video + 音频两条本地文件）
    expect(rec.lastVideoUrl, startsWith('file://'));
    final apiRequestsBefore = state.requests.length;

    await _tapListenToggle(tester, '听视频');

    expect(rec.dataSources, hasLength(2));
    expect(rec.lastVideoUrl, isEmpty, reason: '听视频：视频轨不给');
    expect(rec.lastAudioOnly, isTrue);
    expect(rec.lastAudioUrl, startsWith('file://'),
        reason: '有本地缓存音频就优先本地（连音频流量都不花）');
    expect(rec.lastAudioUrl, contains('${_kBvidLocal}_p1.audio.m4s'));
    expect(rec.lastPositionMs, _kResumeMs);

    // 零网络请求：既没有音频流请求，也没有任何新请求（本地文件不走网络）
    expect(state.requests.length, apiRequestsBefore,
        reason: '进入听视频全程不该再发任何 HTTP 请求');
    expect(state.requests.where((u) => u.path.endsWith('.m4s')), isEmpty);
    expect(_streamConnections, 0,
        reason: 'stream origin 零连接：本地音频不走网络');

    // 占位层明说「用本地缓存音频」
    expect(find.textContaining('用本地缓存音频'), findsOneWidget);
  });

  testWidgets('拿不到独立音频轨（mp4 单流）→ 明确提示 + 不切模式，视频照常播',
      (tester) async {
    final state = _HttpState()..mp4Only = true;
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(state);
    addTearDown(() => HttpOverrides.global = old);
    final rec = _PlayerRec();
    _Mocks(rec).install(tester);
    DownloadManager.debugOverride(_FakeManager(const []));

    await _mount(tester, _video(_kBvidNet, '只有 mp4 单流'));

    expect(rec.dataSources, hasLength(1));
    expect(rec.lastVideoUrl, contains('mp4.mp4'), reason: '起播是 mp4 单流');
    expect(rec.lastAudioUrl, isEmpty, reason: 'mp4 单流没有独立音频轨');

    await _tapListenToggle(tester, '听视频');

    // 不切模式：不重设数据源（原来的视频继续播），底栏仍是未开启态
    expect(rec.dataSources, hasLength(1),
        reason: '拿不到音频轨时不许「静默只播视频」地硬切进去');
    expect(find.text('听视频'), findsOneWidget);
    expect(find.text('听视频中'), findsNothing);
    // 明确提示（错误类提示，不被「界面提示」开关静音）
    expect(find.text(kListenNoAudioNotice), findsOneWidget);
  });

  testWidgets('听视频中音频轨失效（重取后 dash.audio 消失）→ 提示 + 回落视频（带位置）',
      (tester) async {
    final state = _HttpState();
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(state);
    addTearDown(() => HttpOverrides.global = old);
    final rec = _PlayerRec();
    final mocks = _Mocks(rec)..install(tester);
    DownloadManager.debugOverride(_FakeManager(const []));

    await _mount(tester, _video(_kBvidNet, '听视频中断'));

    await _tapListenToggle(tester, '听视频');
    expect(rec.lastAudioOnly, isTrue);
    final before = rec.dataSources.length;

    // 音频 URL 过期 → 自动续播：本批只剩 1 条候选 → 重取 playurl（这次没音频了）
    state.audioGone = true;
    mocks.emit('onUrlExpired');
    await tester.pump();
    // 第一次退避 1s
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(rec.dataSources.length, greaterThan(before), reason: '确实换过一次源');
    expect(rec.lastVideoUrl, _videoStreamUrl,
        reason: '拿不到音频轨 → 回落到视频播放（不是黑屏，也不是静音）');
    expect(rec.lastAudioOnly, isFalse);
    expect(rec.lastPositionMs, _kResumeMs, reason: '回落也带着位置');
    expect(find.text(kListenNoAudioNotice), findsOneWidget,
        reason: '回落必须有可读提示');
    expect(find.text('听视频'), findsOneWidget, reason: '听视频开关已收起');
  });
}
