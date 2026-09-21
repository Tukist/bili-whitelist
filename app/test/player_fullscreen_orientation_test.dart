// 全屏方向按视频宽高比判定（v2.39.0）测试。
//
// 背景（用户原话）：「竖屏视频全屏之后还是竖屏，而不是现在的旋转九十度」——
// 旧实现 `_toggleFullscreen` 进全屏**无条件**锁 landscape 两向，竖屏视频在横屏
// 整屏里只占约 1/3 宽、左右大黑边。
//
// 覆盖：
// 1. 纯函数 [fullscreenOrientationsFor]：竖向 → portraitUp；横向 → landscape
//    两向；接近 1:1 → 空（不下命令 = 不锁）；未就绪 → 放开的三向；比例异常 → 空。
// 2. widget：720×1280（竖屏）进全屏 → 平台通道收到 [portraitUp]。
// 3. widget：1280×720（横屏）进全屏 → 仍收到 landscape 两向（**既有行为不变**）。
// 4. widget：宽高比还没拿到（onPrepared 未到）时点全屏 → 不放 landscape 锁
//    （收到放开的三向）；随后 onPrepared 到达 → **补一次锁**（竖屏源 → portraitUp）。
// 5. widget：全屏中收到另一个方向源的 onPrepared（模拟换源/切集）→ 补锁新方向。
//
// 环境：mock 播放器通道（setDataSource 由测试决定何时回 onPrepared）+ 假 HTTP。
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

const String _kBvid = 'BV1DIR000001';

WhitelistVideo _video() => WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '全屏方向测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 内存版 DownloadManager（不读真文件）。
class _FakeManager extends DownloadManager {
  _FakeManager() {
    cached.value = const [];
  }
}

// ---- 假 HTTP ----

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
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(url);

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
  Future<HttpClientResponse> close() async =>
      _FakeHttpResponse(_route(requestUri));

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

Map<String, dynamic> _route(Uri uri) {
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
        'bvid': _kBvid,
        'aid': 1001,
        'cid': 1001,
        'title': '全屏方向测试视频',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '',
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '', 'duration': 200},
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
    return {
      'code': 0,
      'data': {
        'quality': 80,
        'dash': {
          'video': [{'baseUrl': 'https://x.bilivideo.com/v.m4s'}],
          'audio': [{'baseUrl': 'https://x.bilivideo.com/a.m4s'}],
        },
      },
    };
  }
  return {'code': 0, 'data': {}};
}

/// 播放器通道替身：[autoPrepared] 为 true 时 setDataSource 立即回一条
/// [preparedWidth]×[preparedHeight] 的 onPrepared；false 时把 sink 留给测试手动
/// 触发（用于验证「宽高比未就绪」的窗口与「全屏中补锁」）。
class _PlayerHarness {
  _PlayerHarness({required this.autoPrepared, this.width = 1280, this.height = 720});

  final bool autoPrepared;
  int width;
  int height;
  MockStreamHandlerEventSink? sink;
  final List<Map<Object?, Object?>> dataSources = [];

  /// 手动回一条 onPrepared（模拟「切集/换源后的画面就绪」）。
  void firePrepared({int? w, int? h}) {
    if (w != null) width = w;
    if (h != null) height = h;
    sink?.success({
      'event': 'onPrepared',
      'textureId': dataSources.isEmpty
          ? 1
          : (dataSources.last['textureId'] ?? 1),
      'width': width,
      'height': height,
      'durationMs': 200000,
      'playWhenReady': true,
    });
  }
}

void _installMocks(WidgetTester tester, _PlayerHarness h) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      switch (call.method) {
        case 'create':
          return 1;
        case 'getPosition':
          return 0;
        case 'setDataSource':
          final map = call.arguments as Map;
          h.dataSources.add(map.cast<Object?, Object?>());
          if (h.autoPrepared) h.firePrepared();
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
        h.sink = events;
      },
    ),
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'), null));
}

/// 捕获 SystemChrome 的方向调用（本文件的核心观测量）。
List<List<String>> _captureOrientations(WidgetTester tester) {
  final calls = <List<String>>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(List<String>.from(call.arguments as List));
      }
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

Future<void> _pumpPlayerReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

// 平台通道收到的是**字符串**（SystemChrome._stringify 把枚举 toString()），
// 纯函数返回的是**枚举**——两套期望值分开放，别混用。
const List<DeviceOrientation> _kPortraitOrient = [DeviceOrientation.portraitUp];
const List<DeviceOrientation> _kLandscapeOrient = [
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];
const List<String> _kFree = [
  'DeviceOrientation.portraitUp',
  'DeviceOrientation.landscapeLeft',
  'DeviceOrientation.landscapeRight',
];
const List<String> _kPortrait = ['DeviceOrientation.portraitUp'];
const List<String> _kLandscape = [
  'DeviceOrientation.landscapeLeft',
  'DeviceOrientation.landscapeRight',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fullscreenOrientationsFor（纯函数）', () {
    test('竖向视频 → 只锁 portraitUp（不含 portraitDown）', () {
      expect(fullscreenOrientationsFor(720 / 1280), _kPortraitOrient);
      expect(fullscreenOrientationsFor(9 / 16), _kPortraitOrient);
      expect(fullscreenOrientationsFor(0.5), _kPortraitOrient);
      expect(
        fullscreenOrientationsFor(9 / 16),
        isNot(contains(DeviceOrientation.portraitDown)),
        reason: '倒持全屏没有理由',
      );
    });

    test('横向视频 → landscape 两向（既有行为不变）', () {
      expect(fullscreenOrientationsFor(1280 / 720), _kLandscapeOrient);
      expect(fullscreenOrientationsFor(16 / 9), _kLandscapeOrient);
      expect(fullscreenOrientationsFor(2.35), _kLandscapeOrient);
    });

    test('接近 1:1 → 不下命令（空列表 = 不锁，避免抖）', () {
      expect(fullscreenOrientationsFor(1.0), isEmpty);
      expect(fullscreenOrientationsFor(1.05), isEmpty);
      expect(fullscreenOrientationsFor(0.95), isEmpty);
      // 容差边界（1 ± 0.1）刻意不断言：浮点下 1.0 + 0.1 与 0.1 的比较本身
      // 就不可靠（1.1 - 1 = 0.10000000000000009 > 0.1），断言它会随平台抖动。
      // 设计上「差得远就分档」即可，边界落在哪一侧无实际影响。
      // 容差之外立刻分档
      expect(fullscreenOrientationsFor(0.85), _kPortraitOrient);
      expect(fullscreenOrientationsFor(1.2), _kLandscapeOrient);
    });

    test('宽高比未就绪 → 放开三向（不锁某一向）', () {
      final o = fullscreenOrientationsFor(16 / 9, known: false);
      expect(o, kPlayerPageFreeOrientations);
      expect(o.length, 3);
      expect(o, contains(DeviceOrientation.portraitUp));
      expect(o, contains(DeviceOrientation.landscapeLeft));
      expect(o, contains(DeviceOrientation.landscapeRight));
      expect(
        fullscreenOrientationsFor(9 / 16, known: false),
        isNot(_kLandscapeOrient),
        reason: '未知比例下绝不能锁横屏——那正是要修的 bug',
      );
    });

    test('比例异常（NaN/∞/≤0）→ 空列表（防御，不等于锁横屏）', () {
      expect(fullscreenOrientationsFor(double.nan), isEmpty);
      expect(fullscreenOrientationsFor(double.infinity), isEmpty);
      expect(fullscreenOrientationsFor(0), isEmpty);
      expect(fullscreenOrientationsFor(-1.5), isEmpty);
    });
  });

  testWidgets('竖屏视频（720×1280）进全屏 → 锁 portraitUp（不再转 90°）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final h = _PlayerHarness(autoPrepared: true, width: 720, height: 1280);
    _installMocks(tester, h);
    final orientCalls = _captureOrientations(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
    await _pumpPlayerReady(tester);
    expect(h.dataSources, hasLength(1), reason: '取流已发生 → 比例已知');

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget, reason: '已进全屏');
    expect(orientCalls.last, _kPortrait,
        reason: '竖屏视频锁竖屏（旧行为是 landscape 两向 → 画面只占 1/3 宽）');
  });

  testWidgets('横屏视频（1280×720）进全屏 → 仍锁 landscape 两向（行为不变）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final h = _PlayerHarness(autoPrepared: true, width: 1280, height: 720);
    _installMocks(tester, h);
    final orientCalls = _captureOrientations(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
    await _pumpPlayerReady(tester);

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(orientCalls.last, _kLandscape, reason: '横屏视频：与改动前逐字一致');
  });

  testWidgets('比例未就绪时点全屏 → 不锁；onPrepared 到达后补一次锁',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    // autoPrepared=false：setDataSource 不回 onPrepared，由测试手动触发
    final h = _PlayerHarness(autoPrepared: false, width: 720, height: 1280);
    _installMocks(tester, h);
    final orientCalls = _captureOrientations(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
    await _pumpPlayerReady(tester);
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing,
        reason: '前置：还没进全屏');

    // 未就绪（onPrepared 未到 → _aspectKnown = false）就点全屏
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(orientCalls.last, _kFree,
        reason: '比例未知 → 放开三向（不锁某一向），绝不错锁横屏');

    // 画面就绪（竖屏源）→ 补一次锁
    h.firePrepared();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(orientCalls.last, _kPortrait,
        reason: 'onPrepared 在全屏时补锁（覆盖「点全屏早于就绪」的窗口）');
  });

  testWidgets('全屏中收到另一方向源的 onPrepared（换源/切集）→ 补锁新方向',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final h = _PlayerHarness(autoPrepared: true, width: 1280, height: 720);
    _installMocks(tester, h);
    final orientCalls = _captureOrientations(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
    await _pumpPlayerReady(tester);

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(orientCalls.last, _kLandscape, reason: '前置：横屏源 → 横屏锁');

    // 全屏中画面换成竖屏源（切集到竖屏视频 / 换源）
    h.firePrepared(w: 720, h: 1280);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(orientCalls.last, _kPortrait, reason: '全屏中换到竖屏源 → 补锁竖屏');
  });
}
