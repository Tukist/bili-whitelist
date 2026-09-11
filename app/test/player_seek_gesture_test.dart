// 播放页「竖屏左右滑动调进度」手势 widget 测试（v2.18.x 用户反馈修复）。
//
// 覆盖（为什么必须 widget 测试：三处 `if (_fullscreen)` gate 在 State 方法里，
// 纯函数测试覆盖不到）：
//   1. 竖屏（非全屏）视频区**横滑** → 平台通道收到 seekTo（用户反馈的修复点）
//      + 拖动中弹出 seek 时间浮层（Icons.access_time）；
//   2. 竖屏**纵滑** → 仍走亮度（原生 bili_whitelist/media 收到 setBrightness），
//      且**不** seek（主导方向判定（kPanModeThreshold + |dx|>=|dy|）未被这轮
//      改动放宽——否则会反噬亮度/音量）；
//   3. 全屏回归：屏中部横滑仍 seekTo；**底部豁免带（48px）起手的横滑仍不
//      seek**（用户此前专门反馈的「横屏全屏从物理底边上滑唤醒三键导航被误判
//      成调进度」修复必须保住）。
//
// 测试环境说明（与 player_info_block_test.dart 同款骨架）：
// - mock 原生播放器 MethodChannel/EventChannel（create → textureId，
//   setDataSource → onPrepared 带 durationMs）→ 取流链路走通、时长已知；
// - mock bili_whitelist/media（亮度 / 音量基准）→ 纵向手势可走通；
// - mock SystemChannels.platform（进全屏会调方向 / UI 模式）→ 不抛
//   MissingPluginException；
// - mock HttpOverrides（返回合法 JSON）→ 不发真实请求；
// - **一律显式 pump，不用 pumpAndSettle**：页面自身的缓冲转圈 / 封面图加载
//   占位都是无限动画，pumpAndSettle 会被它们卡死（与本目录既有播放页测试
//   同一约定）。
//
// 几何（**不硬编码坐标**）：竖屏视口 411×914（dpr=1）→ 16:9 视频区高
// = 411 ÷ 16 × 9 ≈ 231.19dp（与用户机一致，也是此前测试完全没覆盖的非全屏
// 尺寸）。视频区矩形运行时用 getRect(find.byKey('player-video-area')) 取，
// 起手点按比例从该矩形算出；全屏换成 914×411（横屏全屏）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvid = 'BV1SEEK00001';
const Key _kVideoArea = ValueKey('player-video-area');

/// 取流时长（ms）：onPrepared 与视频 duration 一致（200s）。
const int _kDurationMs = 200000;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '竖屏滑动 seek 测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 记录到的平台调用（断言 seekTo 目标与媒体通道方法）。
class _Rec {
  final List<String> playerMethods = [];
  final List<int> seeks = [];

  /// bili_whitelist/media 收到的方法名（setBrightness / setVolume / get*）。
  final List<String> mediaMethods = [];
}

// ---------------------------------------------------------------------------
// mock HTTP：flutter_test 默认把所有请求 mock 成 400，这里换成合法 JSON，
// 让 nav/spi/view/reply/playurl 都走通（不发真实请求）。
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1SEEK00001","aid":1001,"cid":1001,"duration":200,'
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

/// 装好播放器 / 媒体 / 方向通道的 mock（每个用例独立装 + tearDown 清理）。
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
      // 注意用块体：箭头体会把赋值结果（sink）当返回值回给平台，
      // 平台侧解码报 "Invalid argument: Instance of 'MockStreamHandlerEventSink'"
      onListen: (arguments, events) {
        eventSink = events;
      },
    ),
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'), null));

  // 亮度 50% / 音量 5 档（max 15）→ 纵向手势基准可用
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
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_whitelist/media'), null));

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));

  // SystemChrome（进全屏 / dispose 恢复方向）：不 mock 的话
  // setPreferredOrientations 会抛 MissingPluginException
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}

/// 挂载播放页并等到取流 + onPrepared 完成（时长已知 = seek 可用）。
Future<void> _pumpPlayer(
    WidgetTester tester, _Rec rec, WhitelistVideo video) async {
  // 先卸一棵空树：同名 widget 会走 update 而不是 initState（同既有播放页测试）
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: video)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 收起控制层（点画面切显隐）。控制层在**手势层之上**——底部控制行
/// （88px：进度条行 + 按钮行）与中央播放簇会吃掉起手点的触摸，所以拖动前
/// 先收起，让起手点稳稳落在手势层上。
///
/// 判「控制层在位」用底栏全屏按钮图标（全屏态为 fullscreen_exit）；单击显隐
/// 要等双击窗口（~300ms）过期才生效 → 收起后 pump 400ms 再断言（断言失败
/// 说明起手点没落在手势层上，是坏测试而不是坏实现）。
Future<void> _hideControls(WidgetTester tester, Offset tapPoint) async {
  bool visible() =>
      find.byIcon(Icons.fullscreen).evaluate().isNotEmpty ||
      find.byIcon(Icons.fullscreen_exit).evaluate().isNotEmpty;
  if (!visible()) return;
  await tester.tapAt(tapPoint);
  await tester.pump(const Duration(milliseconds: 400));
  expect(visible(), isFalse, reason: '控制层应已收起（起手点须落在手势层上）');
}

/// 分步拖动：Pan 需累计位移超 touch slop 才赢得竞技场，主导方向也按累计
/// 位移（kPanModeThreshold=12）锁定；分步还能让纵向模式的「异步读原生基准」
/// 在后续 update 之前完成。[duringDrag] 在抬手**之前**执行（断言拖动中浮层）。
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
  // 抬手后补足时间：双击识别器的 tap 追踪计时（~40ms）与双击窗口（300ms）
  // 必须走完，否则用例结束时会报「A Timer is still pending」；顺带让 seek
  // 浮层的 600ms 延迟隐藏也走完（不影响用例内已完成的断言）。
  await tester.pump(const Duration(milliseconds: 700));
}

/// 视频区内的「中部净区」起手点：避开顶部 24px 豁免带与左右 16px 窄带
/// （非全屏底部豁免带已关闭，视频区底边也可起手）。比例由实际矩形算。
Offset _safePoint(Rect r) =>
    Offset(r.left + r.width * 0.35, r.top + r.height * 0.5);

/// 切显隐用的起手点：视频区左上（避开中央播放簇的横向范围与底部控制行）。
Offset _toggleTapPoint(Rect r) =>
    Offset(r.left + r.width * 0.10, r.top + r.height * 0.30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  testWidgets('竖屏（非全屏）视频区横滑 → 弹 seek 浮层 + 松手 seekTo（用户反馈修复）',
      (tester) async {
    final rec = _Rec();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914); // 用户机竖屏逻辑尺寸
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video());

    // 非全屏视频区 = 顶部置顶 16:9 黑盒：高 411 ÷ 16 × 9 ≈ 231.19（< 屏高 60%）
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.top, 0, reason: '非全屏视频区顶部置顶');
    expect(videoRect.height, closeTo(231.19, 0.5), reason: '竖屏 16:9 视频区高 ≈231');
    expect(videoRect.width, closeTo(411, 0.5));

    await _hideControls(tester, _toggleTapPoint(videoRect));
    rec.seeks.clear();

    // 横滑 +120px：起点在视频区中部净区（非豁免带）→ 水平主导 → seek
    await _drag(
      tester,
      _safePoint(videoRect),
      const Offset(120, 0),
      duringDrag: () async {
        expect(find.byIcon(Icons.access_time), findsOneWidget,
            reason: '竖屏横滑拖动中应弹出 seek 时间浮层');
      },
    );

    expect(rec.seeks, isNotEmpty,
        reason: '竖屏横滑松手应 seekTo（旧版被 if (_fullscreen) 掐断）');
    final target = rec.seeks.last;
    expect(target, greaterThan(0), reason: '向右滑 = 前进（目标位置 > 0）');
    expect(target, lessThanOrEqualTo(_kDurationMs), reason: '不越界到总时长之外');
  });

  testWidgets('竖屏纵滑 → 仍走亮度（setBrightness）、不 seek', (tester) async {
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

    // 起点在左半屏（x=0.35w < 0.5w）→ 亮度；纵滑 +90px（下滑 = 减小）
    final start = _safePoint(videoRect);
    expect(start.dx, lessThan(videoRect.center.dx), reason: '左半屏起手 = 亮度');

    await _drag(
      tester,
      start,
      const Offset(0, 90),
      duringDrag: () async {
        expect(find.byIcon(Icons.brightness_6), findsOneWidget,
            reason: '纵滑弹出亮度浮层');
      },
    );

    expect(rec.mediaMethods, contains('setBrightness'),
        reason: '纵滑仍走亮度调节（原生通道）');
    expect(rec.seeks, isEmpty, reason: '纵向主导不得触发 seek');
    expect(rec.playerMethods, isNot(contains('seekTo')), reason: '同上（通道侧复核）');
  });

  testWidgets('全屏回归：中部横滑仍 seek；底部豁免带（48px）起手仍不 seek',
      (tester) async {
    final rec = _Rec();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video());

    // 进全屏（底栏全屏按钮）→ 整屏视频
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget, reason: '已进全屏');

    // 模拟设备横放 = 横屏全屏 914×411（与既有横屏测试同一逻辑尺寸）
    tester.view.physicalSize = const Size(914, 411);
    await tester.pump();
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.height, closeTo(411, 0.5), reason: '全屏视频区占满整屏');

    await _hideControls(tester, _toggleTapPoint(videoRect));
    rec.seeks.clear();

    // ① 中部横滑 → 仍 seekTo（全屏回归，行为与修复前一致）
    await _drag(tester, _safePoint(videoRect), const Offset(160, 0));
    expect(rec.seeks, isNotEmpty, reason: '全屏中部横滑仍 seekTo');
    rec.seeks.clear();

    // ② 从**底部豁免带**内起手横滑（y=380 ≥ 411-48=363）→ 整体忽略、不 seek
    //    ——横屏全屏从物理屏幕底边上滑唤醒三键导航，不得被当成调进度
    //    （用户此前专门反馈的修复，本轮不能弱化）
    await _drag(tester, Offset(videoRect.center.dx, 380), const Offset(160, 0));
    expect(rec.seeks, isEmpty,
        reason: '全屏底部豁免带（48px）起手仍不 seek（旧修复保住）');
  });
}
