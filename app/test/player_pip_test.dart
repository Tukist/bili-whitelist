// 播放页「小窗播放」（画中画）行为测试（v2.63.0）。
//
// 用户原话：「然后再搞个小窗模式」—— 播放视频时点「更多 → 小窗播放」，画面缩成
// 系统小窗继续播；退出小窗回到全屏播放页。
//
// 本文件只用**平台可观测量**断言（与 player_keep_screen_on_test.dart 同款骨架）：
//   - 通道：`bili_whitelist/pip` 的 `isSupported` / `enter(width,height)` 收到什么；
//   - 树：哪些组件**不在树里**（不是"透明"，是根本没构建）；
//   - 播放：`setDataSource` 没有被重新调用 = 位置连续（没有 re-source）。
//
// 覆盖：
//   1. 支持机型 → 「更多」里有「小窗播放」，点了通道收到**视频真实宽高**；
//   2. 不支持机型 → 入口**不存在**（降级契约）；
//   3. 听视频（音频-only）→ 入口不存在（源里没视频轨，小窗只会是黑屏）；
//   4. 进小窗 → 顶栏/底栏/功能条/信息块/评论区全不在树里，视频层还在，
//      点画面也不弹控制层；亮屏被关掉；
//   5. 退出小窗 → UI 全部恢复、仍在播、没有重新取流（位置连续）；
//   6. 小窗被系统 ✕ 关掉 → 暂停原生播放器 + 关亮屏（按"停止播放"收尾）。
//
// ⚠️ 边界：真机上"窗口真的缩成小窗、切到别的 App 还在播、视频在小窗里继续解码"
// 这三件事 flutter test 验不了 —— 这里锁住的是 Dart 侧的界面与通道契约。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/player/bili_dash_player.dart';
import 'package:bili_whitelist_app/services/keep_screen_on.dart';
import 'package:bili_whitelist_app/services/pip_service.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

const String _kBvid = 'BV1PIPMODE001';
const int _kDurationMs = 200000;

/// 起播时原生回报的视频像素尺寸（16:9）——「小窗播放」必须按这个比例进小窗。
const int _kVideoWidth = 1280;
const int _kVideoHeight = 720;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '小窗模式测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// mock HTTP：让 nav/spi/view/playurl 都走通（不发真实请求）
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1PIPMODE001","aid":1001,"cid":1001,"duration":200,'
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

class _Mocks {
  MockStreamHandlerEventSink? playerSink;
  MockStreamHandlerEventSink? pipSink;
  int textureId = 1;

  /// 本机是否支持画中画（`bili_whitelist/pip#isSupported` 的返回值）。
  bool pipSupported = true;

  /// `enter` 收到的参数（每次进小窗一条）。
  final List<Map<Object?, Object?>> pipEnterArgs = [];

  /// 播放器通道收到的 `setDataSource` 次数（判"没有重新取流"）。
  int dataSourceCalls = 0;

  /// 播放器通道收到的 `pause` 次数。
  int pauseCalls = 0;

  /// `getPosition` 的返回值（`_saveExitProgress` 用它落盘进度）。
  int positionMs = 0;

  /// 「保持亮屏」通道收到的调用序列。
  final List<bool> keepCalls = [];

  void emit(String event, {String? action, int positionMs = 0}) {
    playerSink?.success({
      'event': event,
      'textureId': textureId,
      if (action != null) 'action': action,
      'positionMs': positionMs,
    });
  }

  /// 推一条"进 / 出小窗"事件（原生 MainActivity.onPictureInPictureModeChanged）。
  void emitPip([bool inPip = true]) {
    pipSink?.success({'event': 'pipChanged', 'inPip': inPip});
  }

  /// 推一条"小窗被系统 ✕ 关掉"事件（原生 MainActivity.onStop）。
  void emitPipDismissed() {
    pipSink?.success({'event': 'pipDismissed'});
  }

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        switch (call.method) {
          case 'create':
            return textureId;
          case 'setDataSource':
            dataSourceCalls++;
            final map = call.arguments as Map;
            textureId = (map['textureId'] as num).toInt();
            playerSink?.success({
              'event': 'onPrepared',
              'textureId': map['textureId'],
              'width': _kVideoWidth,
              'height': _kVideoHeight,
              'durationMs': _kDurationMs,
              'playWhenReady': true,
            });
          case 'pause':
            pauseCalls++;
          case 'getPosition':
            return positionMs;
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
          playerSink = events;
        },
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('bili_dash_player/events'), null));

    // ★ 本文件的主角之一：小窗通道（方法 + 状态事件）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kPipChannel),
      (call) async {
        switch (call.method) {
          case 'isSupported':
            return pipSupported;
          case 'enter':
            pipEnterArgs.add(call.arguments as Map);
            return true;
          default:
            return null;
        }
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(kPipChannel), null));

    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel(kPipEventChannel),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          pipSink = events;
        },
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel(kPipEventChannel), null));

    // ★ 另一个：保持亮屏（判"小窗里不亮屏"）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kKeepScreenOnChannel),
      (call) async {
        keepCalls.add((call.arguments as Map)['on'] as bool);
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(kKeepScreenOnChannel), null));

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
  }
}

/// 把挂起的一次通道往返 + setState 收干净（两帧足够：一帧派发、一帧重建）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// 打开底栏「更多」弹层。
Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-more-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _mount(WidgetTester tester, _Mocks mocks) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(411, 914);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await _settle(tester);
  // 每个用例结束前卸载页面：取消小窗事件订阅，否则下个用例的 mock 收不到 onListen
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// 小窗态该"消失"的界面锚点（进小窗后这些 key 一个都不许在树里）。
const List<String> _kHiddenInPip = [
  'player-video-area', // 视频区（含控制层的那个 Stack）
  'player-bottom-bar', // 底栏（进度条行 + 功能条）
  'player-button-row', // 功能条
  'player-info-bar', // 信息块
  'player-comments', // 评论区
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest();
    KeepScreenOn.instance.resetForTest();
    PipService.instance.resetForTest();
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  testWidgets('支持机型：「更多」里有「小窗播放」，点了通道收到视频真实宽高', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    await _openMore(tester);
    expect(find.byKey(const ValueKey('player-more-pip')), findsOneWidget,
        reason: '支持画中画的机型必须有这个入口');
    expect(find.text('小窗播放'), findsOneWidget);

    await tester.tap(find.text('小窗播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 弹层收起
    await _settle(tester);

    expect(mocks.pipEnterArgs, hasLength(1), reason: '真的调了原生 enter');
    expect(mocks.pipEnterArgs.single['width'], _kVideoWidth);
    expect(mocks.pipEnterArgs.single['height'], _kVideoHeight,
        reason: '宽高比必须是视频真实比例（原生据此算小窗形状）');
    final w = mocks.pipEnterArgs.single['width']! as int;
    final h = mocks.pipEnterArgs.single['height']! as int;
    expect(w / h, closeTo(16 / 9, 0.001));
  });

  testWidgets('不支持机型：「小窗播放」入口不存在（降级契约）', (tester) async {
    final mocks = _Mocks()
      ..pipSupported = false
      ..install(tester);
    await _mount(tester, mocks);

    await _openMore(tester);
    // 其余项照旧在（弹层没被整体砍掉）
    expect(find.text('分享'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-more-pip')), findsNothing,
        reason: '不支持就不给入口 —— 点了没反应的按钮不如没有');
    expect(find.text('小窗播放'), findsNothing);
  });

  testWidgets('听视频（音频-only）时入口不存在', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    // 进听视频（源里之后没有视频轨）
    await _openMore(tester);
    await tester.tap(find.text('听视频'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await _settle(tester);

    await _openMore(tester);
    expect(find.text('听视频中'), findsOneWidget, reason: '确实进了听视频');
    expect(find.byKey(const ValueKey('player-more-pip')), findsNothing,
        reason: '没有视频轨 → 小窗里只会是黑屏，不给入口');
  });

  testWidgets('进小窗：只留视频画面，控制层/功能条/信息块/评论区都不在树里', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    expect(find.byType(BiliDashTexture), findsOneWidget);
    expect(mocks.keepCalls.last, isTrue, reason: '进小窗前：有画面在播 → 亮屏');

    mocks.emitPip(true);
    await _settle(tester);

    for (final key in _kHiddenInPip) {
      expect(find.byKey(ValueKey(key)), findsNothing,
          reason: '小窗里不该有 $key（巴掌大的窗口只该有画面）');
    }
    expect(find.byType(Scaffold), findsNothing,
        reason: '整页骨架（顶栏/底栏所在的那层）都不该构建');
    expect(find.byIcon(Icons.arrow_back), findsNothing, reason: '顶栏的返回键不在');
    expect(find.byIcon(Icons.more_horiz), findsNothing, reason: '功能条不在');

    // 画面本体还在（同一个 textureId 的 Texture，继续出帧）
    expect(find.byType(BiliDashTexture), findsOneWidget,
        reason: '小窗里必须还有视频画面');
    final texture = tester.widget<BiliDashTexture>(find.byType(BiliDashTexture));
    expect(texture.textureId, mocks.textureId);

    // 不响应控制层手势：点画面不该把任何控制 UI 唤回来
    await tester.tap(find.byType(BiliDashTexture));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('player-bottom-bar')), findsNothing);

    expect(mocks.keepCalls.last, isFalse,
        reason: '小窗是"用户去看别的 App"，不该继续拦着系统息屏');
  });

  testWidgets('退出小窗：UI 全部恢复、仍在播、位置连续（没有重新取流）', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    final sourcesBefore = mocks.dataSourceCalls;
    expect(sourcesBefore, greaterThan(0));

    mocks.emitPip(true);
    await _settle(tester);
    expect(find.byKey(const ValueKey('player-bottom-bar')), findsNothing);

    mocks.emitPip(false);
    await _settle(tester);
    // 退出小窗会把评论区整棵子树重新挂载（PiP 态下它不在树里）→ 评论首屏
    // 重新取一次数据，把这次请求的异步尾巴 pump 干净（否则测试结束时会剩
    // 一个 Dio 的零延迟 Timer，被框架判成"泄漏"）。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    for (final key in _kHiddenInPip) {
      expect(find.byKey(ValueKey(key)), findsOneWidget,
          reason: '退出小窗必须完整恢复 $key');
    }
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '出来之后仍在播');

    expect(mocks.dataSourceCalls, sourcesBefore,
        reason: '进出小窗只是换渲染树，绝不能重新取流 —— 那会把播放位置打回起点');
    expect(mocks.keepCalls.last, isTrue,
        reason: '回到全屏且仍在播 → 重新亮屏（原有语义不变）');
  });

  testWidgets('小窗被系统 ✕ 关掉 → 暂停原生播放器 + 存进度 + 关亮屏（按停止播放收尾）',
      (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    mocks.emitPip(true);
    await _settle(tester);
    expect(mocks.pauseCalls, 0);

    // 播放器此刻停在 42s —— 小窗被关掉时必须把这个位置存下来
    mocks.positionMs = 42000;
    mocks.emitPipDismissed();
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(mocks.pauseCalls, 1, reason: '小窗没了还要停播，否则是"幽灵播放"');
    expect(mocks.keepCalls.last, isFalse, reason: '停止播放 → 释放亮屏');

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('playback_progress:${_kBvid}_0');
    expect(raw, isNotNull, reason: '关小窗要按"停止播放"存进度（下次接着看）');
    expect((jsonDecode(raw!) as Map)['positionMs'], 42000);

    // 界面回到可交互的播放页（已暂停态），不是卡在空窗口里
    expect(find.byKey(const ValueKey('player-bottom-bar')), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });
}
