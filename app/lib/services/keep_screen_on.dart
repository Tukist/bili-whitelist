import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 保持亮屏的通道名（原生侧 `KeepScreenOnPlugin.kt`）。
const String kKeepScreenOnChannel = 'bili_whitelist/keep_screen_on';

/// 是否应该**保持亮屏**（v2.60.0；纯函数 = 全部条件的唯一判据）。
///
/// 用户原话：「让amoTV保持亮屏。我不知道为什么放着放着手机会息屏但是这次的
/// bilibili不会」—— 即对齐 B 站官方 App：**有画面在播时别自动息屏**。
///
/// 七条条件必须**同时**成立（任一不成立 → 关）：
/// - [settingEnabled]：设置里「播放时保持亮屏」开着（默认开）；
/// - [playing]：确实在播（暂停 / 播完都不是 `true`）；
/// - [buffering] 为 false：缓冲中不亮屏（`_playing == false` 本来就挡住了，
///   这条是二次防御：换源 / 预取期间界面位置不再前进，用户也没在看画面）；
/// - [completed] 为 false：播完停在最后一帧 → 关（与 B 站一致）；
/// - [hasError] 为 false：播放失败 / 错误态 → 关（屏幕上没有画面可看）；
/// - [listenMode] 为 false：**「听视频」（音频-only）模式下不亮屏** —— 那时
///   用户就是要熄屏听，亮着屏反而是耗电；
/// - [foreground]：App 在前台（`AppLifecycleState.resumed`）。退到后台一律关，
///   绝不在后台拦着系统息屏。
bool shouldKeepScreenOn({
  required bool settingEnabled,
  required bool playing,
  required bool buffering,
  required bool completed,
  required bool hasError,
  required bool listenMode,
  required bool foreground,
}) {
  if (!settingEnabled) return false;
  if (!playing) return false;
  if (buffering) return false;
  if (completed) return false;
  if (hasError) return false;
  if (listenMode) return false;
  return foreground;
}

/// 「播放时保持亮屏」的原生通道封装（v2.60.0）。
///
/// 对应原生 `KeepScreenOnPlugin.kt`（`WindowManager.LayoutParams
/// .FLAG_KEEP_SCREEN_ON`）：**不加任何权限、不用 WakeLock**，标志跟着窗口
/// 可见性走，退出页面 / App 退后台时系统自然不生效。
///
/// ## 去重（硬要求）
///
/// 调用点里 [_syncKeepScreenOn] 会挂在 500ms 的 tick 上（还有播放态/前后台
/// 变化等钩子），**不能每次都发通道调用**。这里本地记住上一次**已下发**的值
/// （[lastSent]），同值直接返回 —— 「每 tick 一次通道往返」变成「只在真正变化
/// 时发一次」，断言见 `test/keep_screen_on_test.dart` 与
/// `test/player_keep_screen_on_test.dart`。
///
/// 去重值在**进程内全局**（单例）：同一时刻只有一页在播（叠页时旧页会暂停），
/// 所以全局一个「当前亮屏意图」是够的，也让「A 页关、B 页开」自然收敛。
///
/// ## 失败约定
///
/// 非 Android / 通道不可用 / 原生异常：**静默**（吞掉，不抛、不打断播放）。
/// 最坏结果就是照常息屏，与改动前一致。
class KeepScreenOn {
  /// 生产单例（播放页、测试都走它）。
  static final KeepScreenOn instance = KeepScreenOn();

  KeepScreenOn({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(kKeepScreenOnChannel);

  final MethodChannel _channel;

  /// 上一次**已下发**的值；null = 本次进程还从没下发过。
  bool? _lastSent;

  /// 实际发出去的通道调用次数（测试观测点：去重的直接证据）。
  int _sentCount = 0;

  /// 最近一次下发的值（null = 还没发过）。
  bool? get lastSent => _lastSent;

  /// 本次进程内已发出的通道调用次数。
  int get sentCount => _sentCount;

  /// 下发「保持亮屏 / 不保持」。同值不重复发（见类注释的「去重」）。
  ///
  /// 先记 [_lastSent] 再 await：并发调用（连续两帧都判到同一个值）也只发一次。
  /// 失败也保留这个值 —— 通道不可用是环境问题，按 tick 重试只会刷日志；用户
  /// 下次真正切换状态时值变了，自然会再发一次。
  Future<void> setEnabled(bool on) async {
    if (_lastSent == on) return;
    _lastSent = on;
    _sentCount++;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
    } catch (_) {
      // 静默：亮屏只是增强（与 DeviceMedia / BiliDashPlayer 的通知同步同约定）
    }
  }

  /// 测试用：清空去重态与计数（避免单例跨用例串味）。
  @visibleForTesting
  void resetForTest() {
    _lastSent = null;
    _sentCount = 0;
  }
}
