// 直播页「保持亮屏」接线测试（v2.60.0）。
//
// 点播页的完整覆盖在 `test/player_keep_screen_on_test.dart`；本文件只钉住直播页
// 这条**新接的线**（判据与通道层复用同一套，不重复测）：
//   1. 起播（onPrepared + 播放中 + 在前台 + 设置默认开）→ 下发 true；
//   2. 离开直播页（dispose）→ 一定下发 false（**防泄漏的硬要求**）；
//   3. 设置关着 → 全程一次 true 都不发；
//   4. 暂停 / 直播已结束 → false；退后台 → false，回前台仍在播 → true。
//
// 只断言**平台可观测量**：mock 掉 `bili_whitelist/keep_screen_on`，记录每一次
// `setKeepScreenOn(on)` 的调用序列（不是"没抛异常"，而是"发了什么"）。
// 真机「屏幕真的不息屏」验不了 —— 那要真机，见 README 的已知限制。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/live_play_info.dart';
import 'package:bili_whitelist_app/pages/live_player_page.dart';
import 'package:bili_whitelist_app/services/keep_screen_on.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

const int _kRoom = 21452505;

LivePlayInfo _liveInfo() => LivePlayInfo(
      roomId: _kRoom,
      liveStatus: 1,
      hlsUrl: 'https://cdn.example.com/live/index.m3u8?expires=1&sig=abc',
      quality: 10000,
      expiresAtEpochSec:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 11 * 60,
      host: 'https://cdn.example.com',
      protocolName: 'http_hls',
      formatName: 'fmp4',
      codecName: 'avc',
    );

/// 取流替身：固定给一条可播地址（不发真实请求）。
class _FakeApi extends BiliApi {
  @override
  Future<LivePlayInfo?> fetchLivePlayUrl(int roomId, {int qn = 10000}) async =>
      _liveInfo();
}

/// 播放器 / 亮屏通道 mock（骨架同 `test/live_player_page_test.dart`）。
class _Mocks {
  MockStreamHandlerEventSink? sink;
  int textureId = 7;

  /// 「保持亮屏」通道收到的值序列（只记成功的）。
  final List<bool> keepCalls = [];

  void emitPrepared({bool playWhenReady = true}) => sink?.success({
        'event': 'onPrepared',
        'textureId': textureId,
        'width': 1280,
        'height': 720,
        'durationMs': 0,
        'playWhenReady': playWhenReady,
      });

  void emitCompleted() =>
      sink?.success({'event': 'onCompleted', 'textureId': textureId});

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        if (call.method == 'create') return textureId;
        switch (call.method) {
          case 'setDataSource':
            final map = call.arguments as Map;
            textureId = (map['textureId'] as num).toInt();
            // 原生 setDataSource 后自动 play()：直接推 onPrepared
            emitPrepared();
          default:
            break; // updateNowPlaying / requestNotificationPermission 等
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bili_dash_player'), null));

    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'),
      MockStreamHandler.inline(
        // 用块体：箭头体会把赋值结果当返回值回给平台，解码报错
        onListen: (arguments, events) {
          sink = events;
        },
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('bili_dash_player/events'), null));

    // ★ 主角：亮屏通道
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

    // SystemChrome（dispose 恢复方向）：不 mock 会抛 MissingPluginException
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // 登录态安全存储（BiliApi 取流会读 SESSDATA）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpLive(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(
    home: LivePlayerPage(
      roomId: _kRoom,
      title: '保持亮屏直播',
      upName: '测试UP主',
      upMid: 1001,
      api: _FakeApi(),
    ),
  ));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
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
    UiPrefsStore.instance.resetForTest();
    KeepScreenOn.instance.resetForTest();
  });

  testWidgets('直播起播 → true（只发一次）', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _pumpLive(tester);

    expect(find.byIcon(Icons.pause), findsWidgets, reason: '直播处于播放态');
    // 起播前 `_init` 会先下发一次 false（取流中没画面），起播后再下发 true；
    // 这里只钉「确实亮屏了」且「只亮了一次」。
    expect(mocks.keepCalls.last, isTrue,
        reason: '有画面在播 → 亮屏；onPrepared 复核不会重复下发');
    expect(mocks.keepCalls.where((v) => v).length, 1);
    expect(KeepScreenOn.instance.lastSent, isTrue);
  });

  testWidgets('离开直播页（dispose）→ 一定 false（防泄漏）', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _pumpLive(tester);
    expect(mocks.keepCalls.last, isTrue);

    await tester.pumpWidget(const SizedBox());
    await _settle(tester);

    expect(mocks.keepCalls.last, isFalse,
        reason: 'dispose 必须关掉亮屏 —— 否则退出直播页后手机一直不熄屏（泄漏）');
    expect(KeepScreenOn.instance.lastSent, isFalse);
  });

  testWidgets('设置关着 → 全程一次 true 都不发', (tester) async {
    UiPrefsStore.instance.resetForTest(keepScreenOnEnabled: false);

    final mocks = _Mocks()..install(tester);
    await _pumpLive(tester);

    expect(find.byIcon(Icons.pause), findsWidgets, reason: '直播照常播');
    expect(mocks.keepCalls.where((v) => v), isEmpty,
        reason: '设置关着 → 任何时刻都不许开亮屏');
    // 允许下发 false（无害、原生侧是清标志），但绝不能是 true
    expect(mocks.keepCalls.every((v) => !v), isTrue);
  });

  testWidgets('暂停 → false；直播已结束 → false', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _pumpLive(tester);
    expect(mocks.keepCalls.last, isTrue);

    await tester.tap(find.byIcon(Icons.pause).first);
    await _settle(tester);
    expect(mocks.keepCalls.last, isFalse, reason: '暂停 → 立刻关掉亮屏');

    await tester.tap(find.byIcon(Icons.play_arrow).first);
    await _settle(tester);
    expect(mocks.keepCalls.last, isTrue, reason: '恢复播放 → 重新亮屏');

    mocks.emitCompleted();
    await _settle(tester);
    expect(mocks.keepCalls.last, isFalse,
        reason: '直播已结束（没有画面在播）→ 关');
  });

  testWidgets('退到后台 → false；回到前台仍在播 → true', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _pumpLive(tester);
    expect(mocks.keepCalls.last, isTrue);

    await _toBackground(tester);
    expect(mocks.keepCalls.last, isFalse,
        reason: 'App 退到后台 → 绝不在后台拦着系统息屏');

    await _toForeground(tester);
    expect(mocks.keepCalls.last, isTrue,
        reason: '回到前台且仍在播 → 重新亮屏');
  });

  testWidgets('播放中关掉设置开关 → 立刻 false', (tester) async {
    final mocks = _Mocks()..install(tester);
    await _pumpLive(tester);
    expect(mocks.keepCalls.last, isTrue);

    await UiPrefsStore.instance.setKeepScreenOnEnabled(false);
    await _settle(tester);
    expect(mocks.keepCalls.last, isFalse,
        reason: '关掉开关时正在播也必须立刻关（不是等下一次 tick）');
    expect(mocks.keepCalls.where((v) => v).length, 1,
        reason: '只有起播那一次 true');
  });
}
