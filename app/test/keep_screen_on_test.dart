// 「播放时保持亮屏」通道层与判据单测（v2.60.0）。
//
// 用户原话：「让amoTV保持亮屏……这次的 bilibili 不会」—— 对齐 B 站官方 App：
// **有画面在播**时不让手机自动息屏（原生 FLAG_KEEP_SCREEN_ON，无权限、无
// WakeLock）。本文件覆盖两层：
//   1. [shouldKeepScreenOn] 判据矩阵（七个条件，任一不满足 → 关）；
//   2. [KeepScreenOn] 通道封装：真的发 `setKeepScreenOn`、**同值不重复发**
//      （去重）、异常被吞掉不抛。
//
// 播放页什么时候开/关（暂停、播完、报错、听视频、dispose、退后台、设置关）
// 由 `test/player_keep_screen_on_test.dart` 用播放器桩 + 通道调用序列钉住。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/keep_screen_on.dart';

/// 一条完整成立的「应该亮屏」输入（各用例只改其中一个维度）。
bool _invoke({
  bool settingEnabled = true,
  bool playing = true,
  bool buffering = false,
  bool completed = false,
  bool hasError = false,
  bool listenMode = false,
  bool foreground = true,
}) =>
    shouldKeepScreenOn(
      settingEnabled: settingEnabled,
      playing: playing,
      buffering: buffering,
      completed: completed,
      hasError: hasError,
      listenMode: listenMode,
      foreground: foreground,
    );

/// 记录通道调用（真实可观测：mock handler 收到什么就是发了什么）。
class _Rec {
  final List<bool> calls = [];

  /// true → 通道抛 PlatformException（模拟非 Android / 原生异常）。
  bool throwOnCall = false;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(kKeepScreenOnChannel),
      (call) async {
        expect(call.method, 'setKeepScreenOn');
        final on = (call.arguments as Map)['on'];
        expect(on, isA<bool>(), reason: '载荷必须是 bool（原生按 Boolean 取）');
        if (throwOnCall) {
          throw PlatformException(code: 'BOOM', message: '模拟原生异常');
        }
        calls.add(on as bool);
        return true;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(kKeepScreenOnChannel), null));
  }
}

void main() {
  testWidgets('判据：七条全成立才亮屏；任一条不成立就关', (tester) async {
    expect(_invoke(), isTrue, reason: '设置开 + 在播 + 有画面 + 前台 = 亮屏');

    // 逐条关掉一个维度 → 都必须变成「不亮屏」
    expect(_invoke(settingEnabled: false), isFalse, reason: '设置关着（默认开，但可关）');
    expect(_invoke(playing: false), isFalse, reason: '暂停 / 停止');
    expect(_invoke(buffering: true), isFalse, reason: '缓冲中');
    expect(_invoke(completed: true), isFalse, reason: '播完（画面停在最后一帧）');
    expect(_invoke(hasError: true), isFalse, reason: '播放失败 / 错误态');
    expect(_invoke(listenMode: true), isFalse,
        reason: '听视频（音频-only）：用户就是要熄屏听，亮屏反而费电');
    expect(_invoke(foreground: false), isFalse, reason: 'App 退到后台');
  });

  testWidgets('setEnabled(true/false) 各只发一次，载荷与值一致', (tester) async {
    final rec = _Rec()..install(tester);
    final svc = KeepScreenOn();

    await svc.setEnabled(true);
    expect(rec.calls, [true]);
    expect(svc.lastSent, isTrue);
    expect(svc.sentCount, 1);

    await svc.setEnabled(false);
    expect(rec.calls, [true, false]);
    expect(svc.lastSent, isFalse);
    expect(svc.sentCount, 2);
  });

  testWidgets('重复设置同一值 → 不再发通道调用（去重）', (tester) async {
    final rec = _Rec()..install(tester);
    final svc = KeepScreenOn();

    await svc.setEnabled(true);
    for (var i = 0; i < 20; i++) {
      await svc.setEnabled(true); // 模拟每 500ms tick 复核
    }
    expect(rec.calls, [true], reason: '同值重复 20 次也只发 1 次');
    expect(svc.sentCount, 1);

    await svc.setEnabled(false);
    await svc.setEnabled(false);
    expect(rec.calls, [true, false], reason: 'false 同样去重');
  });

  testWidgets('通道异常被吞掉：不抛、不打断调用方', (tester) async {
    final rec = _Rec()
      ..throwOnCall = true
      ..install(tester);
    final svc = KeepScreenOn();

    // 不抛异常（返回的 Future 正常完成）
    await expectLater(svc.setEnabled(true), completes);
    expect(rec.calls, isEmpty, reason: '异常路径下 mock 没记到成功调用');

    // 之后真正变化的值照常发（失败不粘住去重态）
    rec.throwOnCall = false;
    await svc.setEnabled(false);
    expect(rec.calls, [false]);
  });

  testWidgets('resetForTest 清空去重态与计数（防单例跨用例串味）', (tester) async {
    final rec = _Rec()..install(tester);
    final svc = KeepScreenOn();

    await svc.setEnabled(true);
    svc.resetForTest();
    expect(svc.lastSent, isNull);
    expect(svc.sentCount, 0);

    await svc.setEnabled(true);
    expect(rec.calls, [true, true], reason: '复位后同一个值会重新下发');
  });
}
