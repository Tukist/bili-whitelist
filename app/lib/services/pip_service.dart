import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 画中画（小窗播放）的方法通道名（原生侧 `PipPlugin.kt`）。
const String kPipChannel = 'bili_whitelist/pip';

/// 画中画状态事件通道名（原生侧同一个 `PipPlugin.kt`）。
const String kPipEventChannel = 'bili_whitelist/pip_events';

/// 系统允许的宽高比区间（`PictureInPictureParams.setAspectRatio` 的合法范围）。
///
/// 超出这个区间的 `Rational` 会让 `enterPictureInPictureMode` 直接抛
/// `IllegalArgumentException` —— 所以进小窗前必须夹取（见 [pipEnterSize]）。
const double kPipMinAspect = 0.5;
const double kPipMaxAspect = 2.33;

/// 进小窗时交给原生的尺寸（像素）。
///
/// 只有**比例**有意义（系统按比例决定小窗形状，不看绝对像素），所以夹取时
/// 按比例缩放其中一边即可，不改变画面比：
/// - 比例在 [kPipMinAspect]~[kPipMaxAspect] 内 → 原样返回；
/// - 超宽（> 2.33，如 32:9）→ 高度按 `width / 2.33` 拉高；
/// - 超窄（< 0.5，如 1:3 竖屏条）→ 宽度按 `height * 0.5` 拉宽；
/// - 宽或高 **≤ 0**（取流还没给出真实尺寸 / 仅音频源）→ 退回 16:9。
///
/// 纯函数：原生侧 `PipPlugin.aspectRatioOf` 是同一契约的二次防御。
(int width, int height) pipEnterSize(int width, int height) {
  if (width <= 0 || height <= 0) return (16, 9);
  final aspect = width / height;
  if (aspect > kPipMaxAspect) {
    return (width, (width / kPipMaxAspect).round());
  }
  if (aspect < kPipMinAspect) {
    return ((height * kPipMinAspect).round(), height);
  }
  return (width, height);
}

/// 进小窗的结果：成功 / 失败（带一句可读中文）。
///
/// 与 `ShareResult` / `GallerySaveResult` 同一套约定：**不抛异常**，调用点只判
/// [ok]，失败时把 [message] 原样提示给用户。
class PipEnterResult {
  /// 是否成功进入小窗。
  final bool ok;

  /// 给用户看的一句话（成功时为空串；失败时必有内容）。
  final String message;

  const PipEnterResult({required this.ok, required this.message});

  const PipEnterResult.ok()
      : ok = true,
        message = '';
}

/// 画中画状态事件（原生 `bili_whitelist/pip_events`）。
sealed class PipEvent {
  const PipEvent();
}

/// 进/出小窗。
///
/// [inPip] 为 true = 已经缩成系统小窗（此刻界面只该留视频画面）；
/// false = 已退出（恢复全屏播放页的完整 UI）。
final class PipModeChanged extends PipEvent {
  final bool inPip;

  const PipModeChanged(this.inPip);
}

/// 小窗被系统关掉（用户点小窗上的 ✕）。
///
/// 与 [PipModeChanged] 的区别：这是**终止**信号，不是"退出小窗回到页面"——
/// 播放页要按既有的「停止播放」路径收尾（停播、存进度、释放亮屏）。
final class PipWindowDismissed extends PipEvent {
  const PipWindowDismissed();
}

/// 系统画中画（小窗播放）的通道封装（v2.63.0）。
///
/// 对应原生 `PipPlugin.kt`：**不需要任何权限**，只靠清单里的
/// `android:supportsPictureInPicture="true"` + API 26 的
/// `enterPictureInPictureMode`。小窗的窗口尺寸/形状由系统管，我们只告诉它
/// 视频的宽高比，视频本身仍在原生的播放器纹理里继续解码。
///
/// ## 「不支持」是本功能的一等公民
///
/// [isSupported] 为 false（旧系统 / ROM 没这个 feature / 非 Android）时，播放页
/// **不显示**「小窗播放」入口 —— 用户看不到点了没反应的按钮。原生方法异常一律
/// 吞成 false（不抛）。
///
/// ## 失败约定
///
/// [enter] 三条失败路径都给**可读中文**，绝不抛到界面：
/// - 原生 `UNSUPPORTED` / `enterPictureInPictureMode` 回 false → 「不支持」类文案；
/// - 原生 `FAILED`（Activity 正在销毁 / ROM 拒绝）→ 带原生原因的文案；
/// - 通道不存在（`MissingPluginException`：非 Android 平台 / 旧包）→ 环境不支持。
class PipService {
  /// 生产单例（播放页、测试都走它）。
  static final PipService instance = PipService();

  PipService({MethodChannel? channel, EventChannel? events})
      : _channel = channel ?? const MethodChannel(kPipChannel),
        _eventChannel = events ?? const EventChannel(kPipEventChannel) {
    // 事件流建一次（广播）：多个监听者（正常只有一个播放页）共用底层订阅。
    // 错误（非 Android / 旧原生没有这个通道）直接吞掉——小窗只是增强，
    // 拿不到状态时播放页保持"从没进过小窗"的形态即可。
    _events = _eventChannel
        .receiveBroadcastStream()
        .map(_parseEvent)
        .where((e) => e != null)
        .cast<PipEvent>()
        .handleError((Object _) {});
  }

  final MethodChannel _channel;
  final EventChannel _eventChannel;

  late final Stream<PipEvent> _events;

  /// 是否已问过原生「支不支持」（缓存：一个进程内设备能力不会变）。
  bool? _supported;

  /// 最近一次**交给原生**的尺寸（夹取之后；测试观测点，null = 还没调过 enter）。
  (int width, int height)? lastEnterSize;

  /// 进/出小窗事件流。
  Stream<PipEvent> get events => _events;

  /// 本机是否支持画中画。任何异常 → false（不抛）。
  Future<bool> isSupported() async {
    final cached = _supported;
    if (cached != null) return cached;
    bool result;
    try {
      result = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      // MissingPluginException（非 Android / 旧包）/ PlatformException：
      // 都按"不支持"处理 —— 入口不显示，功能整体降级为不存在。
      result = false;
    }
    _supported = result;
    return result;
  }

  /// 进小窗。[width]/[height] 是**视频真实像素尺寸**（取不到时传 0，
  /// 内部按 16:9 兜底），比例会先夹到 [kPipMinAspect]~[kPipMaxAspect]。
  ///
  /// 成功与否由系统返回值决定（部分 ROM 里 `enterPictureInPictureMode` 会
  /// 直接回 false）；失败一律返回 [PipEnterResult]，不抛。
  Future<PipEnterResult> enter({required int width, required int height}) async {
    final (w, h) = pipEnterSize(width, height);
    lastEnterSize = (w, h);
    try {
      final ok = await _channel
          .invokeMethod<bool>('enter', {'width': w, 'height': h});
      if (ok == true) return const PipEnterResult.ok();
      return const PipEnterResult(
        ok: false,
        message: '进入小窗失败：系统当前不允许画中画',
      );
    } on PlatformException catch (e) {
      if (e.code == 'UNSUPPORTED') {
        return const PipEnterResult(
          ok: false,
          message: '当前设备不支持小窗播放',
        );
      }
      final detail = (e.message ?? '').trim();
      return PipEnterResult(
        ok: false,
        message: detail.isEmpty ? '进入小窗失败，请稍后再试' : detail,
      );
    } on MissingPluginException {
      return const PipEnterResult(
        ok: false,
        message: '当前环境不支持小窗播放',
      );
    } catch (e) {
      return PipEnterResult(ok: false, message: '进入小窗失败：$e');
    }
  }

  /// 原生事件载荷 → [PipEvent]；看不懂的载荷返回 null（由 map 丢掉）。
  PipEvent? _parseEvent(Object? raw) {
    if (raw is! Map) return null;
    switch (raw['event']) {
      case 'pipChanged':
        return PipModeChanged(raw['inPip'] == true);
      case 'pipDismissed':
        return const PipWindowDismissed();
      default:
        return null;
    }
  }

  /// 测试用：清空能力缓存与最近一次尺寸（避免单例跨用例串味）。
  @visibleForTesting
  void resetForTest() {
    _supported = null;
    lastEnterSize = null;
  }
}
