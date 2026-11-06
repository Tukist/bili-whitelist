// 小窗播放（画中画）通道封装的单测（v2.63.0）。
//
// 用户原话：「然后再搞个小窗模式」—— 系统画中画。本文件锁住 **Dart ↔ 原生** 这条
// 契约里所有"能说清楚"的部分（真机上的窗口行为 flutter test 验不了，见文件末）：
//   1. [pipEnterSize]：比例夹取（0.5~2.33）、非法尺寸退 16:9 —— 纯函数；
//   2. [PipService.isSupported]：真 / 假 / 通道不存在 / 原生抛异常，一律不抛；
//   3. [PipService.enter]：发给原生的参数（宽高 = 视频真实像素）、成功、系统拒绝、
//      UNSUPPORTED、通道不存在 —— 失败一律是**可读中文**，不抛；
//   4. 事件流：pipChanged → [PipModeChanged]；pipDismissed → [PipWindowDismissed]。
//
// ⚠️ 边界：`enterPictureInPictureMode` 后系统小窗长什么样、视频在不在小窗里继续
// 解码、某些 ROM 支不支持 —— 都要真机验证；这里验的是参数与状态契约。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/pip_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(kPipChannel);

  /// 原生方法通道收到的所有调用（名称 + 参数）。
  late List<MethodCall> calls;

  /// 当前"设备支不支持"的桩值。
  late bool nativeSupported;

  /// enter 的原生返回值（null = 走默认 true）。
  bool? nativeEnterResult;

  /// Enter 时让原生抛的错误。
  PlatformException? nativeEnterError;

  /// 事件通道的推送端（mock 的 onListen 拿到）。
  MockStreamHandlerEventSink? eventSink;

  void resetChannel({bool register = true}) {
    calls = [];
    nativeSupported = true;
    nativeEnterResult = null;
    nativeEnterError = null;
    PipService.instance.resetForTest();
    messenger.setMockMethodCallHandler(
      channel,
      register
          ? (call) async {
              calls.add(call);
              switch (call.method) {
                case 'isSupported':
                  return nativeSupported;
                case 'enter':
                  if (nativeEnterError != null) throw nativeEnterError!;
                  return nativeEnterResult ?? true;
                default:
                  return null;
              }
            }
          : null,
    );
    messenger.setMockStreamHandler(
      const EventChannel(kPipEventChannel),
      MockStreamHandler.inline(
        onListen: (arguments, events) => eventSink = events,
      ),
    );
  }

  setUp(() => resetChannel());

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(
        const EventChannel(kPipEventChannel), null);
    eventSink = null;
  });

  group('pipEnterSize（比例夹取）', () {
    test('16:9 原样通过', () {
      expect(pipEnterSize(1280, 720), (1280, 720));
    });

    test('竖屏 9:16 原样通过（0.5625 在合法区间）', () {
      expect(pipEnterSize(720, 1280), (720, 1280));
    });

    test('超宽（32:9 = 3.56）→ 高度被拉高到 2.33', () {
      final (w, h) = pipEnterSize(3840, 1080);
      expect(w, 3840);
      expect(w / h, closeTo(kPipMaxAspect, 0.01),
          reason: '系统只接受 ≤2.33，越界会让 enterPictureInPictureMode 抛异常');
    });

    test('超窄（1:3）→ 宽度被拉宽到 0.5', () {
      final (w, h) = pipEnterSize(400, 1200);
      expect(h, 1200);
      expect(w / h, closeTo(kPipMinAspect, 0.01));
    });

    test('宽或高 ≤ 0（取流还没给尺寸）→ 退 16:9', () {
      expect(pipEnterSize(0, 0), (16, 9));
      expect(pipEnterSize(-1, 720), (16, 9));
    });
  });

  group('isSupported', () {
    test('原生说支持 → true', () async {
      expect(await PipService.instance.isSupported(), isTrue);
      expect(calls.single.method, 'isSupported');
    });

    test('原生说不支持 → false', () async {
      nativeSupported = false;
      expect(await PipService.instance.isSupported(), isFalse);
    });

    test('通道不存在（非 Android / 旧包）→ false，不抛', () async {
      resetChannel(register: false);
      expect(await PipService.instance.isSupported(), isFalse);
    });

    test('原生抛异常 → false，不抛', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'BOOM', message: '炸了');
      });
      expect(await PipService.instance.isSupported(), isFalse);
    });

    test('结果被缓存：第二次不再打通道', () async {
      await PipService.instance.isSupported();
      await PipService.instance.isSupported();
      expect(calls.length, 1);
    });
  });

  group('enter', () {
    test('把视频真实宽高交给原生（原生据此算宽高比）', () async {
      final result = await PipService.instance.enter(width: 1920, height: 1080);
      expect(result.ok, isTrue);
      expect(result.message, isEmpty);
      final enter = calls.singleWhere((c) => c.method == 'enter');
      expect((enter.arguments as Map)['width'], 1920);
      expect((enter.arguments as Map)['height'], 1080);
      expect(PipService.instance.lastEnterSize, (1920, 1080));
    });

    test('取流没给尺寸 → 交给原生 16:9', () async {
      await PipService.instance.enter(width: 0, height: 0);
      final enter = calls.singleWhere((c) => c.method == 'enter');
      expect((enter.arguments as Map)['width'], 16);
      expect((enter.arguments as Map)['height'], 9);
    });

    test('超宽片源 → 先夹到 2.33 再交出去', () async {
      await PipService.instance.enter(width: 3840, height: 1080);
      final enter = calls.singleWhere((c) => c.method == 'enter');
      final w = (enter.arguments as Map)['width'] as int;
      final h = (enter.arguments as Map)['height'] as int;
      expect(w / h, closeTo(kPipMaxAspect, 0.01));
    });

    test('系统回 false（ROM 当前不允许）→ 失败 + 可读中文', () async {
      nativeEnterResult = false;
      final result = await PipService.instance.enter(width: 1280, height: 720);
      expect(result.ok, isFalse);
      expect(result.message, contains('进入小窗失败'));
    });

    test('原生 UNSUPPORTED → 「不支持」文案', () async {
      nativeEnterError = PlatformException(
        code: 'UNSUPPORTED',
        message: '当前设备不支持小窗播放',
      );
      final result = await PipService.instance.enter(width: 1280, height: 720);
      expect(result.ok, isFalse);
      expect(result.message, '当前设备不支持小窗播放');
    });

    test('原生 FAILED 带上原因 → 原样转成一句中文', () async {
      nativeEnterError = PlatformException(
        code: 'FAILED',
        message: '进入小窗失败：IllegalStateException',
      );
      final result = await PipService.instance.enter(width: 1280, height: 720);
      expect(result.ok, isFalse);
      expect(result.message, contains('进入小窗失败'));
      expect(result.message, contains('IllegalStateException'));
    });

    test('通道不存在 → 「当前环境不支持小窗播放」，不抛', () async {
      resetChannel(register: false);
      final result = await PipService.instance.enter(width: 1280, height: 720);
      expect(result.ok, isFalse);
      expect(result.message, '当前环境不支持小窗播放');
    });
  });

  group('事件流', () {
    test('pipChanged → PipModeChanged（进 / 出）', () async {
      final seen = <PipEvent>[];
      final sub = PipService.instance.events.listen(seen.add);
      addTearDown(sub.cancel);
      // 让 mock 的 onListen 先跑起来（EventChannel 的 listen 是一次异步往返）
      await Future<void>.delayed(Duration.zero);
      eventSink?.success({'event': 'pipChanged', 'inPip': true});
      await Future<void>.delayed(Duration.zero);
      eventSink?.success({'event': 'pipChanged', 'inPip': false});
      await Future<void>.delayed(Duration.zero);

      expect(seen.length, 2);
      expect((seen[0] as PipModeChanged).inPip, isTrue);
      expect((seen[1] as PipModeChanged).inPip, isFalse);
    });

    test('pipDismissed → PipWindowDismissed', () async {
      final seen = <PipEvent>[];
      final sub = PipService.instance.events.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      eventSink?.success({'event': 'pipDismissed'});
      await Future<void>.delayed(Duration.zero);

      expect(seen.single, isA<PipWindowDismissed>());
    });

    test('看不懂的载荷被丢掉（不抛、不占位）', () async {
      final seen = <PipEvent>[];
      final sub = PipService.instance.events.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      eventSink?.success({'event': 'what'});
      eventSink?.success('not-a-map');
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
    });
  });
}
