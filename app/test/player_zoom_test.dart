// 全屏双指缩放 / 旋转 / 缩放态单指平移（v2.39.0）测试。
// v2.49.0 追加：画面变换的**显式入口**（右下角「旋转」按钮 + 复位按钮文案）。
//
// 背景（用户原话）：「全屏模式下可以手势放大，旋转视频窗口。注意不要和之前的
// 手势冲突」；v2.49.0 追加（用户原话）：「没有手势旋转」——旋转代码其实在，
// 但只在「双指连线转过 45°」才换档，**没有任何可发现的入口**，用户根本不知道
// 要这么做；且「横屏置顶」态（非全屏）下画面看着也是满宽的，在那里转完全没
// 反应（那个态原本不启用变换）。
//
// 覆盖：
// A. 纯函数：缩放换算与钳制（1.0–4.0）、旋转吸附 90° 步进、角度差归一化、
//    平移夹取（缩放 1 时不可拖、放大后按余量夹取）。
// B. widget：
//    1. **单指横滑仍走 seek（回归，最重要）**——全屏、无变换下单指横滑必须
//       照旧 seekTo（缩放/旋转没有偷走 Pan 手势）；
//    2. 双指捏合 → 画面缩放生效、被钳制在 ≤4.0；
//    3. 双指旋转 → 吸附到 90° 步进（矩阵里读出来的角度是 π/2 的整数倍）；
//    4. 缩放态下单指拖动 → 平移画面（**不发 seek**）；
//    5. 复位：底栏「复位」按钮 / 退出全屏 / 换 bvid（下一集）三条路径；
//    6. 非全屏时双指手势**不生效**（画面不变换）；
//    7. v2.49.0：「旋转」按钮常驻（变换可用时）→ 点一下转 90°、连点 4 次回原
//       位；复位按钮文案同时报倍率与角度，一次清掉缩放+旋转；
//    8. v2.49.0：**横屏置顶**态（非全屏 + 视口横放）也能变换（按钮同样在），
//       竖屏置顶仍然不给入口（视频区只有 231dp，且 v2.43.0 用例钉着它）。
//
// ⚠️ 多指手势只能由 widget 测试覆盖：`adb shell input` 不支持多点触控，真机
// 取证只能验「单指三向语义未回归 + 双击/长按不冲突 + 按钮能点」，见报告。
//
// 环境：mock 播放器通道（记录 setDataSource/seekTo，setDataSource 立即回
// onPrepared 1280×720）+ 假 HTTP（playurl 给 DASH 双流）+ 内存 DownloadManager。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/playlist_context.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvA = 'BV1ZOOM00001';
const String _kBvB = 'BV1ZOOM00002';

const Key _kViewTransform = ValueKey('player-view-transform');
const Key _kViewReset = ValueKey('player-view-reset');
const Key _kViewRotate = ValueKey('player-view-rotate');
const Key _kNextVideo = ValueKey('player-next-video');

WhitelistVideo _video(String bvid, String title) => WhitelistVideo(
      bvid: bvid,
      cid: 1001,
      title: title,
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

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
        'bvid': _kBvA,
        'aid': 1001,
        'cid': 1001,
        'title': '缩放旋转测试视频',
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

/// 记录原生调用的替身（seekTo 是「单指语义有没有被偷走」的判据）。
class _PlayerRec {
  final List<Map<Object?, Object?>> dataSources = [];
  final List<int> seeks = [];
}

void _installPlayerMock(WidgetTester tester, _PlayerRec rec) {
  MockStreamHandlerEventSink? sink;
  var nextTextureId = 0;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      switch (call.method) {
        case 'create':
          return ++nextTextureId;
        case 'getPosition':
          return 0;
        case 'seekTo':
          final m = call.arguments as Map;
          rec.seeks.add((m['positionMs'] as num).toInt());
        case 'setDataSource':
          final map = call.arguments as Map;
          rec.dataSources.add(map.cast<Object?, Object?>());
          sink?.success({
            'event': 'onPrepared',
            'textureId': map['textureId'],
            'width': 1280,
            'height': 720,
            'durationMs': 200000,
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

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  WhitelistVideo video, {
  PlaylistContext? playlist,
  int playlistIndex = 0,
  Size size = const Size(914, 411),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: PlayerPage(
      video: video,
      playlist: playlist,
      playlistIndex: playlistIndex,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 进全屏（按钮在底栏最右；用 icon 找，不依赖 key）。
Future<void> _enterFullscreen(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.fullscreen));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
}

/// 画面变换矩阵（无变换节点 → null）。
Matrix4? _viewMatrix(WidgetTester tester) {
  final finder = find.byKey(_kViewTransform);
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Transform>(finder).transform;
}

double? _viewScale(WidgetTester tester) => _viewMatrix(tester)?.getMaxScaleOnAxis();

double? _viewRotation(WidgetTester tester) {
  final m = _viewMatrix(tester);
  if (m == null) return null;
  // 矩阵是 T · R · S（S 为等比缩放）→ 左上 2×2 的极角就是旋转角
  return math.atan2(m.entry(1, 0), m.entry(0, 0));
}

Offset? _viewTranslation(WidgetTester tester) {
  final m = _viewMatrix(tester);
  if (m == null) return null;
  return Offset(m.entry(0, 3), m.entry(1, 3));
}

/// 手势相关的识别器（双击 300ms / 长按 500ms 判定窗口）会留下计时器，
/// 测试结束前把时间推过去，否则 flutter_test 会报「A Timer is still pending」。
Future<void> _flushGestureTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('缩放/旋转/平移换算（纯函数）', () {
    test('scaleFromGesture：按间距比换算并钳制在 1.0–4.0', () {
      expect(viewScaleFromGesture(startScale: 1, startSpan: 100, span: 100), 1.0);
      expect(viewScaleFromGesture(startScale: 1, startSpan: 100, span: 200), 2.0);
      expect(viewScaleFromGesture(startScale: 1, startSpan: 100, span: 700), 4.0,
          reason: '上限 4.0（再大只是马赛克）');
      expect(viewScaleFromGesture(startScale: 1, startSpan: 100, span: 50), 1.0,
          reason: '下限 1.0（缩小只多露黑边，没有信息量）');
      expect(viewScaleFromGesture(startScale: 2, startSpan: 100, span: 50), 1.0);
      expect(viewScaleFromGesture(startScale: 2, startSpan: 100, span: 300), 4.0);
      // 异常输入：保持起始值（不做除零，也不产生 NaN 矩阵）
      expect(viewScaleFromGesture(startScale: 1.5, startSpan: 0, span: 200), 1.5);
      expect(viewScaleFromGesture(startScale: 1.5, startSpan: 100, span: 0), 1.5);
      expect(
          viewScaleFromGesture(
              startScale: 1.5, startSpan: 100, span: double.nan),
          1.5);
    });

    test('snapRotation：吸附到 90° 步进并归一化到 [0, 2π)', () {
      const half = math.pi / 2;
      expect(snapViewRotation(0), 0);
      expect(snapViewRotation(0.3), 0, reason: '不到 45° 不换档');
      expect(snapViewRotation(1.2), closeTo(half, 1e-9));
      expect(snapViewRotation(half), closeTo(half, 1e-9));
      expect(snapViewRotation(2.4), closeTo(math.pi, 1e-9));
      expect(snapViewRotation(-1.2), closeTo(3 * half, 1e-9), reason: '反向转 → 270°');
      expect(snapViewRotation(-0.3), 0);
      expect(snapViewRotation(7.0), closeTo(0, 1e-9),
          reason: '7.0rad 约 4 档（360°）→ 归一化回 0');
      expect(snapViewRotation(double.nan), 0);
      // 全部结果都必须是 90° 的整数倍（"别留 37° 这种歪画面"）
      for (final r in [0.4, 1.0, 1.9, 2.9, 4.0, 5.5, -2.0, -5.0]) {
        final snapped = snapViewRotation(r);
        final steps = snapped / half;
        expect((steps - steps.roundToDouble()).abs() < 1e-9, isTrue,
            reason: '$r 吸附后必须是 90° 整数倍，实际 $snapped');
      }
    });

    test('normalizeAngleDelta：两指连线的 [-π, π] 跨界不产生假旋转', () {
      expect(normalizeAngleDelta(0), 0);
      expect(normalizeAngleDelta(1.0), closeTo(1.0, 1e-9));
      // -π 与 π 是同一个方向（连线反了个头），差值应归到 ±π 附近而不是 ±2π
      expect(normalizeAngleDelta(2 * math.pi).abs() < 1e-9, isTrue);
      expect(normalizeAngleDelta(-2 * math.pi).abs() < 1e-9, isTrue);
      expect(normalizeAngleDelta(7.0), closeTo(7.0 - 2 * math.pi, 1e-9));
      expect(normalizeAngleDelta(double.nan), 0);
    });

    test('clampViewOffset / viewPanLimit：缩放 1 时不可拖，放大后按余量夹取', () {
      const size = Size(914, 411); // 全屏横屏（16:9 画面铺满）
      // scale=1：画面正好贴合（914×411）→ 两个方向都不可拖
      expect(
        viewPanLimit(
            scale: 1,
            viewWidth: 914,
            viewHeight: 411,
            aspectRatio: 16 / 9,
            rotation: 0,
            horizontal: true),
        0,
      );
      // 贴合尺寸：16:9 在 914×411 里按高贴合 → 730.67×411（左右留边）
      // scale=2：横向余量 = (730.67*2 - 914)/2 = 273.67；纵向 = (411*2 - 411)/2 = 205.5
      expect(
        viewPanLimit(
            scale: 2,
            viewWidth: 914,
            viewHeight: 411,
            aspectRatio: 16 / 9,
            rotation: 0,
            horizontal: true),
        closeTo(273.67, 0.01),
      );
      expect(
        viewPanLimit(
            scale: 2,
            viewWidth: 914,
            viewHeight: 411,
            aspectRatio: 16 / 9,
            rotation: 0,
            horizontal: false),
        closeTo(205.5, 0.01),
      );
      final clamped = clampViewOffset(
        offset: const Offset(9999, -9999),
        scale: 2,
        viewSize: size,
        aspectRatio: 16 / 9,
        rotation: 0,
      );
      expect(clamped.dx, closeTo(273.67, 0.01));
      expect(clamped.dy, closeTo(-205.5, 0.01));
      // 未缩放时任何偏移都被夹回 0
      expect(
        clampViewOffset(
          offset: const Offset(50, 50),
          scale: 1,
          viewSize: size,
          aspectRatio: 16 / 9,
          rotation: 0,
        ),
        Offset.zero,
      );
      // 旋转 90°：画面长短边互换 → 横向余量变成原来纵向的那份
      expect(
        viewPanLimit(
            scale: 2,
            viewWidth: 914,
            viewHeight: 411,
            aspectRatio: 16 / 9,
            rotation: math.pi / 2,
            horizontal: true),
        closeTo(0, 0.01),
      );
    });
  });

  testWidgets('全屏单指横滑仍走 seek（单指三向语义零回归）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final rec = _PlayerRec();
    _installPlayerMock(tester, rec);

    await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'));
    await _enterFullscreen(tester);
    expect(rec.seeks, isEmpty, reason: '前置：还没发生 seek');

    // 中部横滑 200px（避开顶部/底部/左右豁免带，也避开中央播放簇）
    await tester.dragFrom(const Offset(200, 90), const Offset(200, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(rec.seeks, isNotEmpty,
        reason: '缩放/旋转没有偷走单指 Pan（用户验收过的 seek 语义）');
    expect(rec.seeks.last, greaterThan(0));
    expect(_viewScale(tester), closeTo(1.0, 1e-6),
        reason: '单指拖动不缩放');
    expect(_viewTranslation(tester), Offset.zero, reason: '未缩放 → 不平移');
  });

  testWidgets('双指捏合 → 放大画面（钳制 ≤4.0），且不误发 seek', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final rec = _PlayerRec();
    _installPlayerMock(tester, rec);

    await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'));
    await _enterFullscreen(tester);

    // 双指从间距 100 → 200（放大 2x）
    // 起点刻意放在 y=90：中央播放簇（屏幕中心一带）与底栏都会吃掉起手点，
    // 事件就到不了手势层/Listener（与既有 player_seek_* 用例同一注意事项）。
    final g1 = await tester.startGesture(const Offset(300, 90));
    final g2 = await tester.startGesture(const Offset(400, 90));
    await tester.pump();
    await g1.moveTo(const Offset(250, 90));
    await g2.moveTo(const Offset(450, 90));
    await tester.pump();

    expect(_viewScale(tester), closeTo(2.0, 1e-3), reason: '间距 ×2 → 画面 ×2');
    expect(find.byKey(_kViewReset), findsOneWidget,
        reason: '缩放态出现可见的复位入口');

    // 继续外扩到间距 700（×7）→ 钳制在 4.0
    await g1.moveTo(const Offset(50, 90));
    await g2.moveTo(const Offset(750, 90));
    await tester.pump();
    expect(_viewScale(tester), closeTo(4.0, 1e-3), reason: '上限 4.0');

    await g1.up();
    await g2.up();
    await tester.pump();
    expect(_viewScale(tester), closeTo(4.0, 1e-3), reason: '松手保持缩放');
    expect(rec.seeks, isEmpty, reason: '双指手势不触发 seek（不与单指语义冲突）');
    await _flushGestureTimers(tester);
  });

  testWidgets('双指旋转 → 吸附到 90° 步进（不留 37° 歪画面）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final rec = _PlayerRec();
    _installPlayerMock(tester, rec);

    await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'));
    await _enterFullscreen(tester);

    // 两指水平 → 竖直 = 转 90°（起点避开中央播放簇，见上）
    final g1 = await tester.startGesture(const Offset(300, 90));
    final g2 = await tester.startGesture(const Offset(400, 90));
    await tester.pump();
    await g1.moveTo(const Offset(350, 40));
    await g2.moveTo(const Offset(350, 140));
    await tester.pump();

    final rot = _viewRotation(tester);
    expect(rot, isNotNull);
    expect(rot, closeTo(math.pi / 2, 1e-3), reason: '转到 90°');
    // 断言是 90° 整数倍（吸附）
    final steps = rot! / (math.pi / 2);
    expect((steps - steps.roundToDouble()).abs() < 1e-6, isTrue,
        reason: '必须是 90° 整数倍，实际 ${rot * 180 / math.pi}°');

    await g1.up();
    await g2.up();
    await tester.pump();
    expect(_viewRotation(tester), closeTo(math.pi / 2, 1e-3));
    await _flushGestureTimers(tester);
  });

  testWidgets('缩放态下单指拖动 = 平移画面（不发 seek）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final rec = _PlayerRec();
    _installPlayerMock(tester, rec);

    await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'));
    await _enterFullscreen(tester);

    // 先放大 2x（双指；起点避开中央播放簇）
    final g1 = await tester.startGesture(const Offset(300, 90));
    final g2 = await tester.startGesture(const Offset(400, 90));
    await tester.pump();
    await g1.moveTo(const Offset(250, 90));
    await g2.moveTo(const Offset(450, 90));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pump();
    expect(_viewScale(tester), closeTo(2.0, 1e-3), reason: '前置：已放大 2x');
    rec.seeks.clear();

    // 单指拖动 → 平移（同样避开中央簇与底栏）
    await tester.dragFrom(const Offset(300, 90), const Offset(150, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(rec.seeks, isEmpty, reason: '缩放态单指拖动是平移，不是 seek');
    final t = _viewTranslation(tester);
    expect(t, isNotNull);
    expect(t!.dx, greaterThan(0), reason: '向右拖 → 画面右移');
    expect(t.dx, lessThanOrEqualTo(273.68), reason: '按缩放余量夹取，不拖出可视区');

    // 反向拖回来并拖过头 → 夹在下限（不会「贴边后回不来」）
    await tester.dragFrom(const Offset(300, 90), const Offset(-400, 0));
    await tester.pump();
    final t2 = _viewTranslation(tester);
    expect(t2!.dx, greaterThanOrEqualTo(-273.68));
    await _flushGestureTimers(tester);
  });

  testWidgets('复位：底栏「复位」按钮 / 退出全屏 / 换 bvid（下一集）三条路径',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final rec = _PlayerRec();
    _installPlayerMock(tester, rec);

    final a = _video(_kBvA, '缩放测试A');
    final b = _video(_kBvB, '缩放测试B');
    await _pumpPlayer(
      tester,
      a,
      playlist: PlaylistContext(videos: [a, b], label: '测试合集'),
    );
    await _enterFullscreen(tester);

    Future<void> zoomIn() async {
      final p1 = await tester.startGesture(const Offset(300, 90));
      final p2 = await tester.startGesture(const Offset(400, 90));
      await tester.pump();
      await p1.moveTo(const Offset(250, 90));
      await p2.moveTo(const Offset(450, 90));
      await tester.pump();
      await p1.up();
      await p2.up();
      await tester.pump();
      expect(_viewScale(tester), closeTo(2.0, 1e-3), reason: '前置：已放大');
    }

    // ① 复位按钮
    await zoomIn();
    expect(find.byKey(_kViewReset), findsOneWidget);
    await tester.tap(find.byKey(_kViewReset));
    await tester.pump();
    expect(_viewScale(tester), closeTo(1.0, 1e-6), reason: '点复位 → 回到 1.0x');
    expect(_viewRotation(tester), closeTo(0, 1e-6));
    expect(_viewTranslation(tester), Offset.zero);
    expect(find.byKey(_kViewReset), findsNothing,
        reason: '无变换后复位入口消失（不多留一个像素）');

    // ② 退出全屏
    await zoomIn();
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_viewMatrix(tester), isNull,
        reason: '非全屏且无变换 → 不构建变换节点（画面回到裸 Center）');
    await _enterFullscreen(tester);
    expect(_viewScale(tester), closeTo(1.0, 1e-6), reason: '再进全屏仍是 1.0x');

    // ③ 换 bvid（下一集）
    await zoomIn();
    await tester.tap(find.byKey(_kNextVideo));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_viewScale(tester), closeTo(1.0, 1e-6), reason: '换 bvid 复位缩放');
    expect(_viewRotation(tester), closeTo(0, 1e-6));
    expect(find.byKey(_kViewReset), findsNothing);
  });

  testWidgets('非全屏双指手势不生效（画面不变换）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    final rec = _PlayerRec();
    _installPlayerMock(tester, rec);

    // 竖屏（视频区只有 231dp 高）
    await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'),
        size: const Size(411, 914));
    expect(_viewMatrix(tester), isNull, reason: '非全屏：不构建变换节点');

    // 视频区内的双指捏合
    final g1 = await tester.startGesture(const Offset(150, 80));
    final g2 = await tester.startGesture(const Offset(250, 80));
    await tester.pump();
    await g1.moveTo(const Offset(100, 80));
    await g2.moveTo(const Offset(300, 80));
    await tester.pump();

    expect(_viewScale(tester), isNull,
        reason: '非全屏双指不生效（视频区太矮，且会与竖屏横滑 seek 抢手势）');
    expect(_viewMatrix(tester), isNull);
    await g1.up();
    await g2.up();
    await tester.pump();
    expect(_viewMatrix(tester), isNull);
    await _flushGestureTimers(tester);
  });

  // -------------------------------------------------------------------------
  // v2.49.0：画面变换的**显式入口**（用户报「没有手势旋转」的真实答案：
  // 旋转实现一直在，但入口只有「双指连线转过 45°」这一种，没人发现得了）。
  // -------------------------------------------------------------------------
  group('画面旋转按钮 / 复位文案（v2.49.0）', () {
    /// 挂载 + 进全屏（按钮在画面右下角，全屏横屏视口下位置稳定）。
    Future<_PlayerRec> pumpFullscreen(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = null);
      DownloadManager.debugOverride(_FakeManager());
      final rec = _PlayerRec();
      _installPlayerMock(tester, rec);
      await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'));
      await _enterFullscreen(tester);
      return rec;
    }

    testWidgets('点「旋转」按钮 → 画面转 90°；连点 4 次回到原位', (tester) async {
      await pumpFullscreen(tester);

      // 未变换时旋转键**也**在（这是本版的关键：入口要能被发现）
      expect(find.byKey(_kViewRotate), findsOneWidget,
          reason: '全屏下「旋转」按钮常驻，不依赖「已经变换过」');
      expect(_viewRotation(tester), closeTo(0, 1e-6));

      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();
      expect(_viewRotation(tester), closeTo(math.pi / 2, 1e-6),
          reason: '点一下 = 顺时针 90°（与手势同一套档位）');

      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();
      expect(_viewRotation(tester), closeTo(math.pi, 1e-6));

      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();
      // ⚠️ 读角度用 atan2（值域 (-π, π]）：270° 读出来是 -90°，同一个角
      expect(_viewRotation(tester), closeTo(-math.pi / 2, 1e-6),
          reason: '第 3 次 → 270°（atan2 读作 -90°）');

      // 第 4 次 → 360° → 归一化回 0°，画面变换整体清空（回到贴合尺寸）
      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();
      expect(_viewRotation(tester), closeTo(0, 1e-6));
      expect(_viewScale(tester), closeTo(1.0, 1e-6));
      expect(find.byKey(_kViewReset), findsNothing,
          reason: '无变换后复位入口消失（旋转也不再占用一个按钮）');

      await _flushGestureTimers(tester);
    });

    testWidgets('复位按钮文案同时报倍率与旋转档位，且一次清掉缩放与旋转', (tester) async {
      await pumpFullscreen(tester);

      // 先双指放大 2x（避开中央播放簇的起手点，见本文件既有用例说明）
      final g1 = await tester.startGesture(const Offset(300, 90));
      final g2 = await tester.startGesture(const Offset(400, 90));
      await tester.pump();
      await g1.moveTo(const Offset(250, 90));
      await g2.moveTo(const Offset(450, 90));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pump();
      expect(_viewScale(tester), closeTo(2.0, 1e-3), reason: '前置：已放大 2x');

      // 再点旋转 90°
      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();
      expect(_viewRotation(tester), closeTo(math.pi / 2, 1e-6));

      // 文案：旧版只有「复位 2.0x」——只旋转不缩放时会显示「复位 1.0x」，
      // 用户看不出画面被转过，也看不出还差几下才回正
      expect(find.byKey(_kViewReset), findsOneWidget);
      expect(find.text('复位 2.0x · 90°'), findsOneWidget,
          reason: '文案要同时体现倍率与旋转档位');

      await tester.tap(find.byKey(_kViewReset));
      await tester.pump();
      expect(_viewScale(tester), closeTo(1.0, 1e-6), reason: '复位清缩放');
      expect(_viewRotation(tester), closeTo(0, 1e-6), reason: '复位清旋转');
      expect(_viewTranslation(tester), Offset.zero);
      expect(find.byKey(_kViewReset), findsNothing);

      await _flushGestureTimers(tester);
    });

    testWidgets('只旋转不缩放：复位文案也能看出转过（旧版这里显示 1.0x）', (tester) async {
      await pumpFullscreen(tester);

      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();

      expect(find.text('复位 1.0x · 90°'), findsOneWidget,
          reason: '倍率没变但画面被转过 → 文案必须把角度说清楚');

      await tester.tap(find.byKey(_kViewReset));
      await tester.pump();
      expect(_viewRotation(tester), closeTo(0, 1e-6));
      await _flushGestureTimers(tester);
    });

    testWidgets('横屏置顶（非全屏）：变换同样可用，按钮也在', (tester) async {
      SharedPreferences.setMockInitialValues({});
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = null);
      DownloadManager.debugOverride(_FakeManager());
      final rec = _PlayerRec();
      _installPlayerMock(tester, rec);

      // 914×411 且不进全屏 = v2.17.17 的「横屏置顶」态
      await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'),
          size: const Size(914, 411));
      expect(find.byIcon(Icons.fullscreen_exit), findsNothing,
          reason: '前置：确实是非全屏');

      // 此前这个态只做「让位」不变换（用户在这里转 → 没反应）
      final g1 = await tester.startGesture(const Offset(300, 90));
      final g2 = await tester.startGesture(const Offset(400, 90));
      await tester.pump();
      await g1.moveTo(const Offset(250, 90));
      await g2.moveTo(const Offset(450, 90));
      await tester.pump();
      expect(_viewScale(tester), closeTo(2.0, 1e-3),
          reason: '横屏置顶现在也能双指缩放（v2.49.0 放开）');
      await g1.up();
      await g2.up();
      await tester.pump();

      // 显式入口同样在，且点一下真的转（此处是用户报「没有手势旋转」的场景）
      expect(find.byKey(_kViewRotate), findsOneWidget);
      await tester.tap(find.byKey(_kViewRotate));
      await tester.pump();
      expect(_viewRotation(tester), closeTo(math.pi / 2, 1e-6),
          reason: '横屏置顶点旋转要真的有反应');
      expect(_viewScale(tester), closeTo(2.0, 1e-3), reason: '旋转不清缩放');

      // 复位入口也要在（不然这个态下用户没有退路）
      expect(find.byKey(_kViewReset), findsOneWidget);
      await tester.tap(find.byKey(_kViewReset));
      await tester.pump();
      expect(_viewMatrix(tester), isNull,
          reason: '复位后非全屏不再构建变换节点（画面回到裸 Center）');
      expect(find.byKey(_kViewReset), findsNothing);

      await _flushGestureTimers(tester);
    });

    testWidgets('竖屏置顶（非全屏竖放）：不给变换入口（视频区只有 231dp）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      HttpOverrides.global = _FakeHttpOverrides();
      addTearDown(() => HttpOverrides.global = null);
      DownloadManager.debugOverride(_FakeManager());
      final rec = _PlayerRec();
      _installPlayerMock(tester, rec);

      await _pumpPlayer(tester, _video(_kBvA, '缩放测试A'),
          size: const Size(411, 914));

      expect(find.byKey(_kViewRotate), findsNothing,
          reason: '竖屏置顶不给入口（放大只多露黑边，且横滑 seek 优先）');
      expect(find.byKey(_kViewReset), findsNothing);
      expect(_viewMatrix(tester), isNull);
    });
  });
}
