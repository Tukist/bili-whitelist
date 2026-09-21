// 播放页「非全屏双指捏合不再被当成单指拖动去 seek」的 widget 测试（v2.43.0）。
//
// 背景（v2.39.0 的已知限制，当时没动）：全屏的缩放/旋转只在全屏生效，非全屏
// 时双指捏合仍可能被 Pan 识别器当成单指拖动 → **莫名 seek**（用户只想捏合看
// 细节，进度却跳了）。本版沿用 v2.39.0 的 Listener + 指针配对机制，把「双指
// 期间让单指三向语义整体让位」扩到非全屏（但画面变换仍只在全屏，见
// `_viewTransformEnabled`）。
//
// 覆盖：
//   1. 非全屏双指同向横移 → **不发 seek**（无 seekTo、无 seek 浮层、无亮度变化）
//      —— 这一条是核心：两指同向移动正是 Pan 会赢下竞技场、旧版必然 seek 的
//      形态；
//   2. 非全屏双指反向捏合（真实捏合手势）→ 同样不发 seek；
//   3. 双指抬起后再单指横滑 → seek 恢复（让位不能粘住）；
//   4. 单指三向零回归：非全屏横滑仍 seek、纵滑仍走亮度（与既有
//      player_seek_gesture_test.dart 同款断言，放在同一文件里对照更直观）。
//
// 多指无法用 adb 模拟，这里是唯一可行的验证方式（`TestGesture` 多 pointer）。
//
// 测试环境说明与 player_seek_gesture_test.dart 完全同款（mock 原生播放器 /
// 媒体 / 方向 / HTTP 通道；**一律显式 pump，不用 pumpAndSettle**）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvid = 'BV1PINCH0001';
const Key _kVideoArea = ValueKey('player-video-area');
const int _kDurationMs = 200000;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '非全屏双指让位测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 记录到的平台调用。
class _Rec {
  final List<String> playerMethods = [];
  final List<int> seeks = [];
  final List<String> mediaMethods = [];
}

// ---------------------------------------------------------------------------
// mock HTTP（见 player_seek_gesture_test.dart 同款说明）
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1PINCH0001","aid":1001,"cid":1001,"duration":200,'
    '"quality":80,'
    '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
    'a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png","sub_url":"https://i0.hdslb.com/bfs/wbi/'
    'e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png"},'
    '"owner":{"mid":1001,"name":"测试UP主","face":""},'
    '"desc":"",'
    '"pages":[{"cid":1001,"part":"","duration":200}],'
    '"replies":[],"top_replies":[],"cursor":{"is_end":true},'
    '"dash":{"video":[{"baseUrl":"https://x.bilivideo.com/v.m4s"}],'
    '"audio":[{"baseUrl":"https://x.bilivideo.com/a.m4s"}]}}}';

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
      _FakeHttpRequest();

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
  @override
  HttpHeaders get headers => _FakeHttpHeaders();
  @override
  int get contentLength => 0;
  @override
  set contentLength(int value) {}
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  void add(List<int> data) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  void write(Object? obj) {}
  @override
  void writeAll(Iterable objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? obj = '']) {}

  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpResponse(utf8.encode(_mockBody));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  _FakeHttpResponse(this._body);

  final List<int> _body;

  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => _body.length;
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

  Stream<List<int>> get handle => Stream<List<int>>.fromIterable([_body]);

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
// 平台通道 mock
// ---------------------------------------------------------------------------

void _installMocks(WidgetTester tester, _Rec rec) {
  var texId = 0;
  MockStreamHandlerEventSink? eventSink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      if (call.method == 'create') return ++texId;
      rec.playerMethods.add(call.method);
      if (call.method == 'setDataSource') {
        final map = call.arguments as Map;
        eventSink?.success({
          'event': 'onPrepared',
          'textureId': map['textureId'],
          'width': 1280,
          'height': 720,
          'durationMs': _kDurationMs,
        });
      }
      if (call.method == 'seekTo') {
        rec.seeks.add((call.arguments as Map)['positionMs'] as int);
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
        eventSink = events;
      },
    ),
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'), null));

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_whitelist/media'),
    (call) async {
      rec.mediaMethods.add(call.method);
      switch (call.method) {
        case 'getBrightness':
          return 0.5;
        case 'getVolume':
          return <String, Object?>{'current': 5, 'max': 15};
        default:
          return null;
      }
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_whitelist/media'), null));

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));

  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}

Future<void> _pumpPlayer(
    WidgetTester tester, _Rec rec, WhitelistVideo video) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: video)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 收起控制层（底部控制行会吃掉起手点）。
Future<void> _hideControls(WidgetTester tester, Offset tapPoint) async {
  bool visible() =>
      find.byIcon(Icons.fullscreen).evaluate().isNotEmpty ||
      find.byIcon(Icons.fullscreen_exit).evaluate().isNotEmpty;
  if (!visible()) return;
  await tester.tapAt(tapPoint);
  await tester.pump(const Duration(milliseconds: 400));
  expect(visible(), isFalse, reason: '控制层应已收起（起手点须落在手势层上）');
}

/// 视频区内的「中部净区」起手点（避开顶部 24px 与左右 16px 豁免带）。
Offset _safePoint(Rect r) =>
    Offset(r.left + r.width * 0.35, r.top + r.height * 0.5);

Offset _toggleTapPoint(Rect r) =>
    Offset(r.left + r.width * 0.10, r.top + r.height * 0.30);

/// 单指分步拖动（同既有 seek 测试：Pan 要累计位移才赢下竞技场）。
Future<void> _drag(
  WidgetTester tester,
  Offset start,
  Offset total, {
  Future<void> Function()? duringDrag,
}) async {
  final g = await tester.startGesture(start);
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await g.moveBy(total / 3);
    await tester.pump();
  }
  if (duringDrag != null) await duringDrag();
  await g.up();
  await tester.pump(const Duration(milliseconds: 700));
}

/// 双指手势：两指各自按 [step1] / [step2] 分步移动（默认同向 = 最容易被 Pan
/// 识别器误判成单指拖动的那种形态）。
///
/// pointer 用 11/12（避开 tester 默认的 1）。
Future<void> _twoFinger(
  WidgetTester tester,
  Offset p1,
  Offset p2, {
  Offset step1 = const Offset(30, 0),
  Offset step2 = const Offset(30, 0),
  int steps = 3,
  Future<void> Function()? duringGesture,
}) async {
  final g1 = await tester.startGesture(p1, pointer: 11);
  await tester.pump();
  final g2 = await tester.startGesture(p2, pointer: 12);
  await tester.pump();
  for (var i = 0; i < steps; i++) {
    await g1.moveBy(step1);
    await g2.moveBy(step2);
    await tester.pump();
  }
  if (duringGesture != null) await duringGesture();
  await g1.up();
  await tester.pump();
  await g2.up();
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  testWidgets('非全屏双指同向横移 → 不发 seek（核心：旧版会被当成单指拖动）',
      (tester) async {
    final rec = _Rec();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video());
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.height, closeTo(231.19, 0.5), reason: '非全屏视频区 ≈231');
    await _hideControls(tester, _toggleTapPoint(videoRect));
    rec.seeks.clear();
    rec.mediaMethods.clear();

    // 两指同向横移 90px（正是 Pan 会赢下竞技场的形态）
    final c = videoRect.center;
    await _twoFinger(
      tester,
      Offset(c.dx - 40, c.dy),
      Offset(c.dx + 40, c.dy),
      duringGesture: () async {
        expect(find.byIcon(Icons.access_time), findsNothing,
            reason: '双指期间不该出现 seek 时间浮层');
      },
    );

    expect(rec.seeks, isEmpty, reason: '非全屏双指不得触发 seek（本版修复点）');
    expect(rec.playerMethods, isNot(contains('seekTo')), reason: '通道侧复核');
    expect(rec.mediaMethods, isNot(contains('setBrightness')),
        reason: '双指也不是纵向调节');
    expect(rec.mediaMethods, isNot(contains('setVolume')));
  });

  testWidgets('非全屏双指反向捏合（真实捏合形态）→ 同样不发 seek',
      (tester) async {
    final rec = _Rec();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video());
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    await _hideControls(tester, _toggleTapPoint(videoRect));
    rec.seeks.clear();

    final c = videoRect.center;
    await _twoFinger(
      tester,
      Offset(c.dx - 30, c.dy),
      Offset(c.dx + 30, c.dy),
      step1: const Offset(-14, 0), // 左指往左
      step2: const Offset(14, 0), // 右指往右 → 放大
    );

    expect(rec.seeks, isEmpty, reason: '捏合不得触发 seek');
    // 非全屏不做画面变换：捏合后视频区尺寸/位置不变
    final after = tester.getRect(find.byKey(_kVideoArea));
    expect(after, videoRect, reason: '非全屏不变换画面（变换仍只在全屏）');
  });

  testWidgets('双指抬起后再单指横滑 → seek 恢复（让位不粘住）', (tester) async {
    final rec = _Rec();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video());
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    await _hideControls(tester, _toggleTapPoint(videoRect));

    final c = videoRect.center;
    await _twoFinger(
      tester,
      Offset(c.dx - 40, c.dy),
      Offset(c.dx + 40, c.dy),
    );
    expect(rec.seeks, isEmpty, reason: '构造场景：双指期间没 seek');

    // 双指都抬起后，单指横滑回到原语义
    await _drag(tester, _safePoint(videoRect), const Offset(120, 0));
    expect(rec.seeks, isNotEmpty, reason: '双指结束后单指拖动应恢复 seek');
  });

  testWidgets('单指语义零回归：非全屏横滑仍 seek、纵滑仍亮度', (tester) async {
    final rec = _Rec();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video());
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    await _hideControls(tester, _toggleTapPoint(videoRect));
    rec.seeks.clear();
    rec.mediaMethods.clear();

    // ① 横滑 → seek
    await _drag(tester, _safePoint(videoRect), const Offset(120, 0));
    expect(rec.seeks, isNotEmpty, reason: '单一手指横滑仍 seek（零回归）');

    // ② 纵滑 → 亮度，不 seek
    rec.seeks.clear();
    await _drag(tester, _safePoint(videoRect), const Offset(0, 90));
    expect(rec.mediaMethods, contains('setBrightness'),
        reason: '单一手指纵滑仍走亮度（零回归）');
    expect(rec.seeks, isEmpty, reason: '纵向主导不得 seek');
  });
}
