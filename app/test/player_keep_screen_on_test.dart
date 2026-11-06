// 「播放时保持亮屏」播放页行为测试（v2.60.0）。
//
// 用户原话：「让amoTV保持亮屏。我不知道为什么放着放着手机会息屏但是这次的
// bilibili不会」—— 对齐 B 站官方 App：**有画面在播**时不让手机自动息屏。
//
// 本文件只用**平台可观测量**断言：mock 掉原生通道
// `bili_whitelist/keep_screen_on`，记录每一次 `setKeepScreenOn(on)` 的调用序列
// （不是"没抛异常"，而是"发了什么、发了几次"）。覆盖：
//   1. 起播 → true；暂停 → false；继续 → true；
//   2. 播完（onCompleted）→ false；原生报错（onError）→ false；
//   3. 进入听视频（音频-only）→ false，且整个听视频期间不再发 true；
//   4. 离开播放页（dispose）→ false（**防泄漏的硬要求**）；
//   5. 退到后台 → false；回到前台且仍在播 → true；
//   6. 设置关着 → 全程一次 true 都不发；播放中关掉开关 → 立刻 false；
//   7. 500ms tick 只复核不下发：同一状态持续 tick 时调用次数不增（去重）。
//
// 环境（与 player_media_notification_test.dart 同款骨架）：播放器
// MethodChannel/EventChannel 手工 mock（setDataSource 立即回 onPrepared）、
// HttpOverrides 返回合法 JSON、一律显式 pump（页面有无限动画，不用
// pumpAndSettle）。
//
// ⚠️ 边界：`FLAG_KEEP_SCREEN_ON` 真的让屏幕不息屏这一点 flutter test 验不了
// （窗口标志在原生侧，且测试进程没有真实屏幕）—— 需真机确认；本文件锁住的是
// 「什么时候下发 true/false、下发了几次」这条 Dart↔原生契约。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/keep_screen_on.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

const String _kBvid = 'BV1KEEPSCR001';
const int _kDurationMs = 200000;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '保持亮屏测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// mock HTTP：让 nav/spi/view/playurl 都走通（不发真实请求）
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1KEEPSCR001","aid":1001,"cid":1001,"duration":200,'
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
  MockStreamHandlerEventSink? sink;
  int textureId = 1;

  /// 「保持亮屏」通道收到的**调用序列**（只记成功的；true/false 按顺序）。
  final List<bool> keepCalls = [];

  void emit(String event, {String? action, int positionMs = 0}) {
    sink?.success({
      'event': event,
      'textureId': textureId,
      if (action != null) 'action': action,
      'positionMs': positionMs,
    });
  }

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        switch (call.method) {
          case 'create':
            return textureId;
          case 'setDataSource':
            final map = call.arguments as Map;
            textureId = (map['textureId'] as num).toInt();
            sink?.success({
              'event': 'onPrepared',
              'textureId': map['textureId'],
              'width': 1280,
              'height': 720,
              'durationMs': _kDurationMs,
              // setDataSource 后原生自动 play()：真实播放意图 = true
              'playWhenReady': true,
            });
          case 'getPosition':
            return 0;
          default:
            // 未知方法（含 updateNowPlaying / requestNotificationPermission）：
            // 与既有 player_* 测试同一约定
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

    // ★ 本文件的主角：亮屏通道（记录每一次真正下发的值）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kKeepScreenOnChannel),
      (call) async {
        expect(call.method, 'setKeepScreenOn');
        keepCalls.add((call.arguments as Map)['on'] as bool);
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(kKeepScreenOnChannel), null));

    // SystemChrome（进全屏 / dispose 恢复方向）
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // 登录态安全存储（取流前读 SESSDATA）：不 mock 会打断取流链路
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

/// 打开底栏「更多」弹层（v2.62.0：听视频 / 字幕 / 下载 / 分享 都收在这里）。
Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-more-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 关闭「更多」弹层（点弹层上方的遮罩区）。
Future<void> _closeMore(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 4));
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
}

/// 按合法路径走一遍「退到后台」/「回到前台」（框架会校验非法跳变）。
Future<void> _toBackground(WidgetTester tester) async {
  for (final s in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
  await _settle(tester);
}

Future<void> _toForeground(WidgetTester tester) async {
  for (final s in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
  await _settle(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 设置基线：保持亮屏出厂默认开；写历史关掉（避免用例里多出上报请求）
    UiPrefsStore.instance.resetForTest();
    KeepScreenOn.instance.resetForTest();
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  testWidgets('起播 → true；暂停 → false；继续 → true', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '界面处于播放态');
    expect(mocks.keepCalls, [true],
        reason: '有画面在播 → 亮屏；起播只下发一次（onPrepared 后复核不重复）');
    expect(KeepScreenOn.instance.lastSent, isTrue);

    final beforePause = mocks.keepCalls.length;
    await tester.tap(find.byIcon(Icons.pause));
    await _settle(tester);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(mocks.keepCalls, [...mocks.keepCalls.sublist(0, beforePause), false],
        reason: '暂停 → 立刻关掉亮屏（不能还亮着）');

    final beforeResume = mocks.keepCalls.length;
    await tester.tap(find.byIcon(Icons.play_arrow));
    await _settle(tester);
    expect(mocks.keepCalls, [...mocks.keepCalls.sublist(0, beforeResume), true],
        reason: '继续播放 → 重新亮屏');
    expect(mocks.keepCalls.where((v) => v).length, 2,
        reason: '只该有起播 + 恢复两次 true（暂停期间没有多余 true）');
  });

  testWidgets('播完（onCompleted）→ false', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);

    mocks.emit('onCompleted');
    await _settle(tester);
    expect(mocks.keepCalls.last, isFalse, reason: '播完停在最后一帧 → 关');
    expect(KeepScreenOn.instance.lastSent, isFalse);
  });

  testWidgets('原生报错（onError）→ false', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);

    // 3001 = 解码类不可恢复错误 → 直接进错误态，不触发自动续播
    mocks.sink?.success({
      'event': 'onError',
      'textureId': mocks.textureId,
      'code': 3001,
      'message': '解码失败',
    });
    await _settle(tester);
    expect(mocks.keepCalls.last, isFalse, reason: '错误态：屏幕上没有画面可看 → 关');
    expect(find.textContaining('播放失败'), findsWidgets);
  });

  testWidgets('进入听视频（音频-only）→ false，且全程不再发 true', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);

    // v2.62.0：底栏把「听视频」收进「更多」弹层 → 先开弹层再点开关
    await _openMore(tester);
    await tester.tap(find.text('听视频'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 弹层收起
    await tester.pump(const Duration(milliseconds: 100));
    await _settle(tester);

    // 状态容器换到弹层里，断言的文本与唯一性不变
    await _openMore(tester);
    expect(find.text('听视频中'), findsOneWidget, reason: '确实进入了听视频');
    await _closeMore(tester);
    expect(mocks.keepCalls.last, isFalse,
        reason: '听视频时用户就是要熄屏听 → 不许亮屏');

    // 换源后的 onPrepared + 若干 tick 都不能把亮屏开回来
    final count = mocks.keepCalls.length;
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(mocks.keepCalls.length, count, reason: '听视频期间同值复核不下发');
    expect(mocks.keepCalls.where((v) => v).length, 1, reason: '只有起播那一次 true');
  });

  testWidgets('离开播放页（dispose）→ 一定 false（防泄漏）', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);
    expect(KeepScreenOn.instance.lastSent, isTrue);

    // 直接卸载页面（等价于 pop 回上一页）：dispose 里必须无条件关掉
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);

    expect(mocks.keepCalls.last, isFalse,
        reason: 'dispose 必须把亮屏关掉 —— 否则退出播放页后手机一直不熄屏（泄漏）');
    expect(KeepScreenOn.instance.lastSent, isFalse);
  });

  testWidgets('退到后台 → false；回到前台仍在播 → true', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);

    await _toBackground(tester);
    expect(mocks.keepCalls.last, isFalse,
        reason: 'App 退到后台 → 绝不在后台拦着系统息屏');

    await _toForeground(tester);
    expect(mocks.keepCalls.last, isTrue,
        reason: '回到前台且仍在播 → 重新亮屏');
  });

  testWidgets('设置关着 → 全程一次 true 都不发', (tester) async {
    // 用例前置：设置里关掉「播放时保持亮屏」
    UiPrefsStore.instance.resetForTest(keepScreenOnEnabled: false);

    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);

    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '视频照常播');
    expect(mocks.keepCalls.where((v) => v), isEmpty,
        reason: '设置关着 → 任何时刻都不许开亮屏');

    // 暂停 / 继续 / 若干 tick 走一圈，仍然一次 true 都没有
    await tester.tap(find.byIcon(Icons.pause));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);

    expect(mocks.keepCalls.where((v) => v), isEmpty,
        reason: '关掉开关后恢复播放也不许开');
    // 允许下发 false（无害、原生侧是清标志），但绝不能是 true
    expect(mocks.keepCalls.every((v) => !v), isTrue);
  });

  testWidgets('播放中关掉设置开关 → 立刻 false，且之后不再发 true', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);

    // 用户在设置页关掉开关（store 立即通知 → 播放页立刻复核）
    await UiPrefsStore.instance.setKeepScreenOnEnabled(false);
    await _settle(tester);
    expect(mocks.keepCalls.last, isFalse,
        reason: '关掉开关时正在播也必须立刻关（不是等下一次 tick）');

    final count = mocks.keepCalls.length;
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    expect(mocks.keepCalls.length, count, reason: '关着之后 tick 复核不下发');
    expect(mocks.keepCalls.where((v) => v).length, 1, reason: '只有起播那一次 true');
  });

  testWidgets('500ms tick 只复核不下发：同一状态持续 tick 不增加调用', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _mount(tester, mocks);
    expect(mocks.keepCalls, [true]);

    await tester.pump(const Duration(seconds: 3)); // ≈6 次 tick
    await _settle(tester);
    expect(mocks.keepCalls, [true],
        reason: '播放态没变 → 6 次 tick 也不该多发一次通道调用（去重）');
    expect(KeepScreenOn.instance.sentCount, 1);
  });
}
