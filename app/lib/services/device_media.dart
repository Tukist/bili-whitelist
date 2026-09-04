import 'package:flutter/services.dart';

/// 播放页 B 站式快捷手势的媒体调节（v2.16.7+），对应原生
/// `MediaController.kt`（MethodChannel `bili_whitelist/media`）：
///
/// - 音量：AudioManager STREAM_MUSIC 当前 / 最大档（[getVolume]），按档精确
///   设置（[setVolume]，0..max，原生不带系统音量 UI）
/// - 亮度：**应用内亮度**（WindowManager LayoutParams.screenBrightness 0..1，
///   仅当前 Activity，退出恢复系统亮度；[getBrightness] / [setBrightness]）
///
/// 失败约定：非 Android / 原生通道异常时返回 null 或静默失败——播放页手势
/// 直接放弃本次调节（无副作用），绝不打断播放。
class DeviceMedia {
  static const MethodChannel _channel =
      MethodChannel('bili_whitelist/media');

  /// 媒体音量档位：当前档 + 最大档（STREAM_MUSIC）。
  /// 通道不可用 / 异常 → null（调用方放弃本次音量手势）。
  static Future<({int current, int max})?> getVolume() async {
    try {
      final map =
          await _channel.invokeMethod<Map<Object?, Object?>>('getVolume');
      if (map == null) return null;
      return (
        current: (map['current'] as num?)?.toInt() ?? 0,
        max: (map['max'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 设置媒体音量档位（越界由原生钳制 0..max）。失败静默。
  static Future<void> setVolume(int level) async {
    try {
      await _channel.invokeMethod<void>('setVolume', {'level': level});
    } catch (_) {
      // 静默：一次手势失败不影响后续（下次手势会重新 getVolume）
    }
  }

  /// 当前应用内亮度（0..1；未覆盖过时原生回退读系统亮度）。
  /// 通道不可用 / 异常 → null。
  static Future<double?> getBrightness() async {
    try {
      final v = await _channel.invokeMethod<double>('getBrightness');
      return v;
    } catch (_) {
      return null;
    }
  }

  /// 原生亮度原始值 → 有效百分比（0..100，纯函数可单测）。
  ///
  /// 兜底规则：**任何拿不到有效值的情况都回退 [fallbackPercent]**（默认 50%）——
  /// - null（通道失败 / 原生异常）
  /// - 非有限值（NaN / Infinity）
  /// - 越界（原生正常返回 0..1；收到 -1 = 窗口未设置（BRIGHTNESS_OVERRIDE_NONE）
  ///   之类的异常值也在此列——v2.16.12 前若原生把 -1 原样透传，基准会换算成
  ///   -100% 再被 clamp 到 0，表现为「动一点就跳 0」）
  ///
  /// 有效值按 0..1 → 0..100 换算后同样钳制到 [0, 100]，保证返回值**永远可用**。
  static double normalizeBrightnessPercent(
    Object? raw, {
    double fallbackPercent = 50,
  }) {
    final v = raw is num ? raw.toDouble() : double.nan;
    if (!v.isFinite || v < 0 || v > 1) return fallbackPercent;
    final pct = v * 100;
    return pct < 0 ? 0 : (pct > 100 ? 100 : pct);
  }

  /// 当前应用内亮度（**0..100 百分比，保证有效**）：原生 0..1 → 百分比，
  /// 任何失败（通道异常 / 异常值如 -1）都按 [normalizeBrightnessPercent]
  /// 兜底到 [fallbackPercent]（默认 50%），不抛异常、永不返回无效值。
  ///
  /// 播放页手势把返回值直接当调节基准——读取必须可靠，否则基准错了
  /// 换算出来的目标也会错（跳 0/100 的根因之一）。
  static Future<double> getBrightnessPercent({
    double fallbackPercent = 50,
  }) async {
    final raw = await getBrightness();
    return normalizeBrightnessPercent(raw, fallbackPercent: fallbackPercent);
  }

  /// 设置应用内亮度（0..1，原生钳制 0.05..1.0）。失败静默。
  static Future<void> setBrightness(double value) async {
    try {
      await _channel
          .invokeMethod<void>('setBrightness', {'value': value});
    } catch (_) {
      // 静默（同上）
    }
  }
}
