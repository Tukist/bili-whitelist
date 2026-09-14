// 直播弹幕**接入层**（widget）测试：验证弹幕接进直播页后的三条硬要求。
//
// 覆盖：
// - ① 打开弹幕开关 → 弹幕区挂 `DanmakuOverlay`；收到弹幕 → **列表原地追加**
//   （List 实例身份不变、屏上弹幕不被清屏）；
// - ② 关闭开关 → 渲染层卸载且 `enabled` 被持久化；开关记忆（上次开着 → 进页自动开）；
// - ③ 弹幕数据源失败（取不到弹幕服务器信息 / WS 连不上）→ **静默降级**：页面照常
//   播放、无错误提示、无异常（硬性要求：弹幕不能成为播放的失败点）；
// - ④ 设置面板复用 VOD 的 `DanmakuSettingsSheet`，改动立刻生效并持久化。
//
// 全部离线：假 `BiliApi`（取流 + 弹幕服务器信息）+ 假 WS socket（见
// test/live_danmaku_fakes.dart）+ 假播放器通道（照抄 test/live_player_page_test.dart）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/live_danmaku_client.dart';
import 'package:bili_whitelist_app/models/danmaku.dart';
import 'package:bili_whitelist_app/models/danmaku_settings.dart';
import 'package:bili_whitelist_app/models/live_play_info.dart';
import 'package:bili_whitelist_app/pages/live_player_page.dart';
import 'package:bili_whitelist_app/services/danmaku_settings_store.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/danmaku_overlay.dart';
import 'package:bili_whitelist_app/widgets/danmaku_settings_sheet.dart';

import 'live_danmaku_fakes.dart';

const int _kRoom = 21452505;
const String _kTitle = '一起来聊天';
const String _kUpName = '测试UP主';

/// 直播取流结果（剩余 11 分钟不影响本文件的用例）。
LivePlayInfo _liveInfo() => LivePlayInfo(
      roomId: _kRoom,
      liveStatus: 1,
      hlsUrl: 'https://cdn.example.com/live/index.m3u8?expires=1&sig=abc',
      quality: 10000,
      expiresAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 660,
      host: 'https://cdn.example.com',
      protocolName: 'http_hls',
      formatName: 'fmp4',
      codecName: 'avc',
    );

/// 页面用假 api：取流可控 + 弹幕服务器信息可控（[FakeLiveDanmakuApi]）。
class _PageApi extends FakeLiveDanmakuApi {
  _PageApi({super.hosts, this.info});

  LivePlayInfo? info;

  int playCalls = 0;

  @override
  Future<LivePlayInfo?> fetchLivePlayUrl(int roomId, {int qn = 10000}) async {
    playCalls++;
    return info;
  }
}

/// 可控假时钟（弹幕时间轴 = 距进房毫秒数 → 测试要能拨它）。
class _Clock {
  int nowMs = 1000000;

  /// 距进房的假想「进房秒数」推进 [steps] 个弹幕时钟跳。
  int call() => nowMs;

  void advance(int ms) => nowMs += ms;
}

// ---------------------------------------------------------------------------
// 播放器通道 mock（照抄 test/live_player_page_test.dart 的最小集）
// ---------------------------------------------------------------------------

class _PlayerMocks {
  _PlayerMocks();

  MockStreamHandlerEventSink? sink;
  int textureId = 7;
  final List<String> methods = [];

  void emit(Map<String, Object?> payload) =>
      sink?.success({...payload, 'textureId': textureId});

  void emitPrepared() => emit({
        'event': 'onPrepared',
        'width': 1280,
        'height': 720,
        'durationMs': 0, // 直播没有时长
        'playWhenReady': true,
      });

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        if (call.method == 'create') return textureId;
        methods.add(call.method);
        if (call.method == 'setDataSource') {
          final map = call.arguments as Map;
          textureId = (map['textureId'] as num).toInt();
          emitPrepared(); // 原生设源后自动 play → READY
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
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
  }
}

// ---------------------------------------------------------------------------
// 挂载 / 推进
// ---------------------------------------------------------------------------

Future<void> _pumpLive(
  WidgetTester tester, {
  required BiliApi api,
  required _Clock clock,
  required LiveSocketConnector connect,
}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(
    home: LivePlayerPage(
      roomId: _kRoom,
      title: _kTitle,
      upName: _kUpName,
      upMid: 546195,
      api: api,
      clockMs: clock.call,
      danmakuConnector: connect,
    ),
  ));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 退页（dispose → 断连接、停定时器；flutter_test 会因此不报 pending timer）。
Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// 点弹幕开关（信息区那一行的 `Switch`；先确保滚进可视区）。
Future<void> _tapDanmakuSwitch(WidgetTester tester) async {
  final finder = find.byType(Switch);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 推进弹幕时钟：假时钟与渲染位置同步前进（两条时间轴必须一致）。
Future<void> _tickClock(WidgetTester tester, _Clock clock, int steps) async {
  for (var i = 0; i < steps; i++) {
    clock.advance(kLiveDanmakuTickMs);
    await tester.pump(const Duration(milliseconds: kLiveDanmakuTickMs));
  }
}

/// 取当前渲染层拿到的弹幕列表实例（判「原地追加」的关键）。
List<Danmaku> _overlayList(WidgetTester tester) =>
    tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).danmaku;

/// 渲染层 State 的测试探针：屏上活跃滚动弹幕的 y（清屏会立刻归零）。
dynamic _overlayState(WidgetTester tester) =>
    tester.state(find.byType(DanmakuOverlay));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MotionControl.enabled = false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(MotionControl.reset);

  testWidgets('① 开弹幕 → 弹幕上屏；新弹幕**原地追加**，屏上弹幕不被清屏', (tester) async {
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory();
    final api = _PageApi(hosts: liveHosts(['h1']), info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    // 未开弹幕：只有接缝占位，没有渲染层
    expect(find.byKey(kLiveDanmakuSeamKey), findsOneWidget);
    expect(find.byType(DanmakuOverlay), findsNothing);

    await _tapDanmakuSwitch(tester);
    expect(find.byType(DanmakuOverlay), findsOneWidget, reason: '开开关要挂渲染层');
    expect(factory.calls, 1, reason: '开开关才连弹幕服务器');
    expect(packetOperation(factory.last.sent.first), kLiveOpAuth);

    factory.last.push(authReplyFrame());
    await tester.pump();
    await tester.pump();

    // 第 1 条弹幕（进房 0.5 秒处）
    clock.advance(500);
    factory.last.push(zlibMessageFrame(jsonMessageFrame(danmuMsgJson(text: '甲'))));
    await tester.pump();
    await tester.pump();
    final list = _overlayList(tester);
    expect(list, hasLength(1), reason: '弹幕要进渲染列表');
    expect(list.first.text, '甲');

    // 时钟越过该弹幕时间点 → 上屏
    await _tickClock(tester, clock, 2);
    expect((_overlayState(tester).debugActiveScrollYs as List), hasLength(1));

    // 第 2 条弹幕：必须**原地 add**（不能换 List 实例）
    clock.advance(500);
    factory.last.push(zlibMessageFrame(jsonMessageFrame(danmuMsgJson(text: '乙'))));
    await tester.pump();
    await tester.pump();

    final listAfter = _overlayList(tester);
    expect(identical(list, listAfter), isTrue,
        reason: '列表必须同一实例：换实例会让渲染层 didUpdateWidget 判"换数据了"→清屏');
    expect(listAfter, hasLength(2));

    await _tickClock(tester, clock, 3);
    expect((_overlayState(tester).debugActiveScrollYs as List), isNotEmpty,
        reason: '追加后不能清屏（原先在屏的弹幕仍在）');
    expect((_overlayState(tester).debugActiveScrollYs as List).length,
        greaterThanOrEqualTo(2));

    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });

  testWidgets('①b 实测认证回复（op=8 包头 protoVer=1）→ 灰字「连接中…」消失（不再恒为 connecting）',
      (tester) async {
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory();
    final api = _PageApi(hosts: liveHosts(['h1']), info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    await _tapDanmakuSwitch(tester);
    expect(find.textContaining('连接中'), findsOneWidget, reason: '认证前显示连接中');

    factory.last.push(authReplyFrame(protoVer: 1)); // 真机抓到的报文
    await tester.pump();
    await tester.pump();

    // 修复前：认证回复被解析器丢掉 → 状态停在 connecting → 这句红（真机症状）
    expect(find.textContaining('连接中'), findsNothing,
        reason: '认证成功 → status=connected（真机 bug：永远停在「连接中…」）');
    expect(find.byType(AppErrorView), findsNothing);
    expect(tester.takeException(), isNull);

    await _disposePage(tester);
  });

  testWidgets('② 关开关 → 渲染层卸载 + 设置持久化（enabled=false）', (tester) async {
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory();
    final api = _PageApi(hosts: liveHosts(['h1']), info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    await _tapDanmakuSwitch(tester);
    expect(find.byType(DanmakuOverlay), findsOneWidget);
    expect((await DanmakuSettingsStore.instance.get()).enabled, isTrue,
        reason: '开关状态要跟着设置一起持久化（重启后保持）');
    final socket = factory.last;

    await _tapDanmakuSwitch(tester);
    expect(find.byType(DanmakuOverlay), findsNothing, reason: '关开关要卸载渲染层');
    expect((await DanmakuSettingsStore.instance.get()).enabled, isFalse);
    expect(socket.closed, isTrue, reason: '关开关要断开弹幕连接');

    await _disposePage(tester);
  });

  testWidgets('②b 开关记忆：上次开着 → 进页自动开并自动连', (tester) async {
    await DanmakuSettingsStore.instance.save(const DanmakuSettings(enabled: true));
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory();
    final api = _PageApi(hosts: liveHosts(['h1']), info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    expect(find.byType(DanmakuOverlay), findsOneWidget);
    expect(factory.calls, 1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await _disposePage(tester);
  });

  testWidgets('③ 弹幕失败静默降级：取不到服务器信息也照常播放、无错误无异常', (tester) async {
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory();
    // hosts == null → getDanmuInfo 失败（真实实现同样返回 null 不抛）
    final api = _PageApi(hosts: null, info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    await _tapDanmakuSwitch(tester);
    // 走一轮退避重试（默认 1s 起）
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(api.calls, greaterThanOrEqualTo(2), reason: '失败要按退避重试');
    expect(find.byType(DanmakuOverlay), findsOneWidget, reason: '渲染层仍挂着（空列表）');
    expect(find.byType(AppErrorView), findsNothing, reason: '不能弹错误态');
    expect(find.textContaining('直播已结束'), findsNothing);
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '播放不受影响');
    expect(tester.takeException(), isNull);
    // 只在开关旁给一行灰字状态，不打断用户
    expect(find.textContaining('连接中'), findsOneWidget);

    await _disposePage(tester);
  });

  testWidgets('③b WS 连不上（host 全失败）→ 同样静默，播放不受影响', (tester) async {
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory()..failHosts.add('h1');
    final api = _PageApi(hosts: liveHosts(['h1']), info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    await _tapDanmakuSwitch(tester);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byType(DanmakuOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposePage(tester);
  });

  testWidgets('④ 复用 DanmakuSettingsSheet：改动立刻生效并持久化', (tester) async {
    _PlayerMocks().install(tester);
    final clock = _Clock();
    final factory = FakeSocketFactory();
    final api = _PageApi(hosts: liveHosts(['h1']), info: _liveInfo());
    await _pumpLive(tester, api: api, clock: clock, connect: factory.connect);

    await _tapDanmakuSwitch(tester);
    final settingsButton = find.text('设置');
    await tester.ensureVisible(settingsButton);
    await tester.pump();
    await tester.tap(settingsButton);
    // 不能用 pumpAndSettle：弹幕层常驻 Ticker（永不 settle），只推固定帧
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(DanmakuSettingsSheet), findsOneWidget);

    // 关掉「滚动弹幕」（= blockScroll true）
    await tester.tap(find.text('滚动弹幕'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect((await DanmakuSettingsStore.instance.get()).blockScroll, isTrue,
        reason: '面板改动要持久化（与 VOD 播放页共用同一份设置）');
    expect(
      tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).settings.blockScroll,
      isTrue,
      reason: '改动要立刻传给渲染层',
    );
    expect(tester.takeException(), isNull);

    await _disposePage(tester);
  });
}
