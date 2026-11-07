// 播放页「应用内浮动小窗」行为测试（v2.65.0）。
//
// 用户原话：「小窗改成可以拖动角来缩放的，然后加个锁定按钮」。
//
// 与 `player_pip_test.dart`（系统画中画）的分工：
//   - 那个文件守的是「系统小窗」的通道契约与"小窗里只留画面"；
//   - 本文件守的是**应用内**浮窗：拖动 / 拖角缩放 / 锁定 / 还原 / 持久化，
//     以及"进出浮窗不重新取流"。
//
// 断言口径（能观测到什么就断言什么）：
//   - 几何：`tester.getRect('player-float-window')` 的矩形；
//   - 状态：树里有没有把手（`player-float-handle`）、锁图标是 lock 还是 lock_open；
//   - 播放：`bili_dash_player#setDataSource` 的次数（判"没有重新取流"）、
//     `pause` 次数（判"没被打断"）、亮屏通道最后一次下发的值。
//
// ⚠️ 边界：真机上的手指跟随手感、浮窗与系统手势导航的冲突、不同 ROM 的
// 状态栏内边距，flutter test 验不了 —— 这里锁住的是几何与状态机契约。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/float_window_prefs.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/player/bili_dash_player.dart';
import 'package:bili_whitelist_app/services/float_window_store.dart';
import 'package:bili_whitelist_app/services/keep_screen_on.dart';
import 'package:bili_whitelist_app/services/pip_service.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/widgets/floating_player_window.dart';

const String _kBvid = 'BV1FLOATWIN01';
const int _kDurationMs = 200000;

/// 起播时原生回报的视频像素尺寸（16:9）。
const int _kVideoWidth = 1280;
const int _kVideoHeight = 720;

/// 与 `player_pip_test.dart` 同一个页面尺寸（竖屏手机）。
const Size _kScreen = Size(411, 914);

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '应用内小窗测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// mock HTTP：让 nav/spi/view/playurl 都走通（不发真实请求）
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1FLOATWIN01","aid":1001,"cid":1001,"duration":200,'
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

  /// 播放器通道收到的 `setDataSource` 次数（判"没有重新取流"）。
  int dataSourceCalls = 0;

  /// `pause` 次数（判"进出浮窗没打断播放"）。
  int pauseCalls = 0;

  /// `bili_whitelist/pip#enter` 的调用次数。
  int pipEnterCalls = 0;

  /// 「保持亮屏」通道收到的调用序列。
  final List<bool> keepCalls = [];

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
            return 0;
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

    // 系统小窗通道（本文件只用来确认"点系统小窗走的是 PiP，不是浮窗"）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kPipChannel),
      (call) async {
        switch (call.method) {
          case 'isSupported':
            return true;
          case 'enter':
            pipEnterCalls++;
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

/// 挂载播放页（每个测试独立挂载/卸载，避免浮窗状态串味）。
Future<void> _mount(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = _kScreen;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await _settle(tester);
  await tester.pump(const Duration(milliseconds: 100));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

/// 进应用内小窗（「更多 → 应用内小窗」）。
Future<void> _enterFloat(WidgetTester tester) async {
  await _openMore(tester);
  expect(find.byKey(const ValueKey('player-more-float')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('player-more-float')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300)); // 弹层收起
  await _settle(tester);
}

Rect _windowRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('player-float-window')));

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

  testWidgets('「更多」里两个入口并存：应用内小窗 / 小窗播放（系统），名字可区分', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester);

    await _openMore(tester);
    expect(find.byKey(const ValueKey('player-more-float')), findsOneWidget);
    expect(find.text('应用内小窗'), findsOneWidget);
    expect(find.text('浮在本页上：可拖动、拖角缩放、可锁定'), findsOneWidget);
    // 系统小窗入口原样还在（v2.63.0 的行为一点没改）
    expect(find.byKey(const ValueKey('player-more-pip')), findsOneWidget);
    expect(find.text('小窗播放'), findsOneWidget);
    expect(find.text('系统小窗：切到别的 App 也能继续看'), findsOneWidget);

    // 点「应用内小窗」→ 浮窗出现，但**没有**走系统 PiP 通道
    await tester.tap(find.byKey(const ValueKey('player-more-float')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);

    expect(find.byKey(const ValueKey('player-float-window')), findsOneWidget);
    expect(mocks.pipEnterCalls, 0, reason: '应用内小窗不碰系统 PiP');
  });

  testWidgets('进浮窗：画面搬进窗口（只有一份纹理），信息块与评论区照常可见', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester);

    expect(find.byType(BiliDashTexture), findsOneWidget);
    final rect0 = _windowRectOrNull(tester);
    expect(rect0, isNull, reason: '进之前没有浮窗');

    await _enterFloat(tester);

    expect(find.byKey(const ValueKey('player-float-window')), findsOneWidget);
    expect(find.byType(BiliDashTexture), findsOneWidget,
        reason: '同一份纹理只是换了位置 —— 不能有两份画面，也不能重新取流');
    expect(
      tester.widget<BiliDashTexture>(find.byType(BiliDashTexture)).textureId,
      mocks.textureId,
    );

    // 视频区收成一条操作条，页面内容全在
    expect(find.byKey(const ValueKey('player-float-bar')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('player-video-area'))).height,
        kFloatBarHeight);
    expect(find.byKey(const ValueKey('player-info-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-comments')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-bottom-bar')), findsNothing,
        reason: '底栏随视频区一起收起（播放/暂停已放进操作条）');

    // 默认窗口：屏宽 40%、16:9、贴右，纵向落在操作条**下方**
    final rect = _windowRect(tester);
    expect(rect.width, closeTo(_kScreen.width * 0.40, 0.5));
    expect(rect.width / rect.height, closeTo(_kVideoWidth / _kVideoHeight, 0.01));
    expect(rect.right, closeTo(_kScreen.width, 0.5));
    expect(rect.top, closeTo(kFloatBarHeight, 0.5),
        reason: '默认贴顶 = 操作条下沿：不许盖住那条控制条');

    // 浮窗里仍在看画面 → 亮屏不关（与系统 PiP 相反）
    expect(mocks.keepCalls.last, isTrue,
        reason: '应用内小窗里用户还在看这一页，屏幕不能黑');
    expect(mocks.pauseCalls, 0, reason: '进浮窗不打断播放');
  });

  testWidgets('拖动：窗口跟着手指移动；甩出边界被夹回可视区', (tester) async {
    _Mocks().install(tester);
    await _mount(tester);
    await _enterFloat(tester);

    final before = _windowRect(tester);
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(-40, 60),
    );
    await _settle(tester);
    final moved = _windowRect(tester);
    expect(moved.left, lessThan(before.left), reason: '往左拖 → 左边界变小');
    expect(moved.top, greaterThan(before.top), reason: '往下拖 → 上边界变大');
    expect(moved.width, closeTo(before.width, 0.5), reason: '拖动不改尺寸');

    // 往右下甩 2000dp：必须被夹在可视区内（不许有一半在屏幕外）
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(2000, 2000),
    );
    await _settle(tester);
    final clamped = _windowRect(tester);
    expect(clamped.right, lessThanOrEqualTo(_kScreen.width + 0.01));
    expect(clamped.bottom, lessThanOrEqualTo(_kScreen.height + 0.01));
    expect(clamped.right, closeTo(_kScreen.width, 0.5), reason: '贴右边停住');
    expect(clamped.bottom, closeTo(_kScreen.height, 0.5), reason: '贴底边停住');

    // 往左上甩：同理
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(-2000, -2000),
    );
    await _settle(tester);
    final leftTop = _windowRect(tester);
    expect(leftTop.left, greaterThanOrEqualTo(-0.01));
    expect(leftTop.top, greaterThanOrEqualTo(kFloatBarHeight - 0.01),
        reason: '上边界是操作条下沿，不许盖住控制条');

    // 双击识别器在指针抬起后还有个等待窗口（判"是不是下一击"）：让它自然过期，
    // 否则用例结束时框架会报 "Timer is still pending"。
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('拖角缩放：尺寸变化、保持视频比例、最小 120 / 最大屏宽 85%', (tester) async {
    _Mocks().install(tester);
    await _mount(tester);
    await _enterFloat(tester);

    // 先往左挪：默认贴右，放大时会被"推回可视区"，看不出"定位点不动"
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(-120, 0),
    );
    await _settle(tester);

    final before = _windowRect(tester);
    // 把手在右下角：往右下拖 = 放大
    await tester.drag(
      find.byKey(const ValueKey('player-float-handle')),
      const Offset(60, 0),
    );
    await _settle(tester);
    final bigger = _windowRect(tester);
    expect(bigger.width, greaterThan(before.width + 20));
    expect(bigger.width / bigger.height,
        closeTo(_kVideoWidth / _kVideoHeight, 0.01),
        reason: '缩放保持 16:9');
    expect(bigger.left, closeTo(before.left, 0.5), reason: '贴着左上角原地放大');

    // 缩到最小：120dp
    await tester.drag(
      find.byKey(const ValueKey('player-float-handle')),
      const Offset(-500, 0),
    );
    await _settle(tester);
    final smallest = _windowRect(tester);
    expect(smallest.width, closeTo(kFloatMinWidth, 0.5));
    expect(smallest.width / smallest.height,
        closeTo(_kVideoWidth / _kVideoHeight, 0.01));

    // 放到最大：屏宽 85%
    await tester.drag(
      find.byKey(const ValueKey('player-float-handle')),
      const Offset(2000, 0),
    );
    await _settle(tester);
    final largest = _windowRect(tester);
    expect(largest.width,
        closeTo(_kScreen.width * kFloatMaxWidthRatio, 0.5));
    expect(largest.right, lessThanOrEqualTo(_kScreen.width + 0.01),
        reason: '放大后要被推回可视区');
    expect(largest.width / largest.height,
        closeTo(_kVideoWidth / _kVideoHeight, 0.01));

    // 双击识别器的等待窗口过期（见拖动用例的说明）
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('锁定：拖不动也缩放不了（把手消失）；解锁后恢复', (tester) async {
    _Mocks().install(tester);
    await _mount(tester);
    await _enterFloat(tester);

    final before = _windowRect(tester);
    expect(find.byKey(const ValueKey('player-float-handle')), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-float-lock')));
    await _settle(tester);
    expect(find.byIcon(Icons.lock), findsOneWidget, reason: '两态图标必须能看出来');
    expect(find.byKey(const ValueKey('player-float-handle')), findsNothing,
        reason: '锁定后把手整块不构建 → 结构上不可能缩放');

    // 拖窗口：纹丝不动
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(-60, 60),
    );
    await _settle(tester);
    final lockedRect = _windowRect(tester);
    expect(lockedRect.left, closeTo(before.left, 0.01), reason: '锁定后不能拖动');
    expect(lockedRect.top, closeTo(before.top, 0.01));
    expect(lockedRect.size.width, closeTo(before.width, 0.01));

    // 解锁 → 恢复可拖动
    await tester.tap(find.byKey(const ValueKey('player-float-lock')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('player-float-handle')), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(-60, 60),
    );
    await _settle(tester);
    final unlockedRect = _windowRect(tester);
    expect(unlockedRect.left, lessThan(before.left - 10),
        reason: '解锁后拖动必须重新生效');

    // 双击识别器的等待窗口过期（见拖动用例的说明）
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('还原：按钮/操作条都能回大屏，位置连续、不重新取流', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester);
    await _enterFloat(tester);

    final sourcesBefore = mocks.dataSourceCalls;
    expect(sourcesBefore, greaterThan(0));

    // ① 窗口上的还原按钮
    await tester.tap(find.byKey(const ValueKey('player-float-restore')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('player-float-window')), findsNothing);
    expect(find.byKey(const ValueKey('player-bottom-bar')), findsOneWidget);
    expect(find.byType(BiliDashTexture), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '还原后仍在播');

    // ② 再进一次，用操作条的「回到大屏」
    await _enterFloat(tester);
    await tester.tap(find.byKey(const ValueKey('player-float-bar-restore')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('player-float-window')), findsNothing);

    // ③ 双击窗口也能还原
    await _enterFloat(tester);
    await tester.tap(find.byKey(const ValueKey('player-float-window')));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byKey(const ValueKey('player-float-window')));
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    expect(find.byKey(const ValueKey('player-float-window')), findsNothing,
        reason: '双击 = 回到大屏');

    expect(mocks.dataSourceCalls, sourcesBefore,
        reason: '进出浮窗只是换渲染树，绝不能重新取流');
    expect(mocks.pauseCalls, 0, reason: '还原不该暂停过播放器');
    expect(mocks.keepCalls.last, isTrue, reason: '回到大屏仍在播 → 继续亮屏');
  });

  testWidgets('持久化：拖动/缩放/锁定后重进播放页，窗口沿用同一套', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester);
    await _enterFloat(tester);

    // 挪一下 + 缩一下 + 锁上
    await tester.drag(
      find.byKey(const ValueKey('player-float-window')),
      const Offset(-30, 100),
    );
    await _settle(tester);
    await tester.drag(
      find.byKey(const ValueKey('player-float-handle')),
      const Offset(30, 0),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('player-float-lock')));
    await _settle(tester);
    final saved = _windowRect(tester);

    // 真的写进了 prefs
    final prefs = await FloatWindowStore.instance.get();
    expect(prefs.locked, isTrue);
    expect(prefs.widthRatio, greaterThan(0.40));

    // 卸载 → 重挂（模拟再次进页面）
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await _mount(tester);
    await _enterFloat(tester);

    final restored = _windowRect(tester);
    expect(restored.left, closeTo(saved.left, 1.0), reason: '位置沿用上次');
    expect(restored.top, closeTo(saved.top, 1.0));
    expect(restored.width, closeTo(saved.width, 1.0), reason: '大小沿用上次');
    expect(find.byKey(const ValueKey('player-float-handle')), findsNothing,
        reason: '锁定状态也要沿用');
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(mocks.dataSourceCalls, greaterThan(0), reason: '重进当然会重新取流');

    // 双击识别器的等待窗口过期（见拖动用例的说明）
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('坏值回退：store 里是坏数据 → 用默认窗口，不崩不消失', (tester) async {
    SharedPreferences.setMockInitialValues({
      FloatWindowStore.key:
          '{"w":0.0,"x":-9,"y":"nope","locked":"yes"}',
    });
    _Mocks().install(tester);
    await _mount(tester);
    await _enterFloat(tester);

    final rect = _windowRect(tester);
    expect(rect.width, closeTo(_kScreen.width * kFloatDefaultWidthRatio, 0.5),
        reason: '宽度比坏 → 回退 40%');
    expect(rect.right, closeTo(_kScreen.width, 0.5), reason: '位置坏 → 回退贴右');
    expect(rect.top, closeTo(kFloatBarHeight, 0.5),
        reason: '位置坏 → 回退"贴着操作条下沿"（默认贴顶）');
    expect(find.byKey(const ValueKey('player-float-handle')), findsOneWidget,
        reason: '坏值不该把窗口锁死');
  });

  testWidgets('系统小窗入口行为未变：点了走 PiP 通道，不进应用内浮窗', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester);

    await _openMore(tester);
    await tester.tap(find.text('小窗播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);

    expect(mocks.pipEnterCalls, 1, reason: '系统小窗仍走原生 PiP');
    expect(find.byKey(const ValueKey('player-float-window')), findsNothing,
        reason: 'PiP 不是应用内浮窗');
  });
}

/// 「现在有没有浮窗」——没有就返回 null（测试里用来判"进之前/还原之后"）。
Rect? _windowRectOrNull(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('player-float-window'));
  if (finder.evaluate().isEmpty) return null;
  return tester.getRect(finder);
}
