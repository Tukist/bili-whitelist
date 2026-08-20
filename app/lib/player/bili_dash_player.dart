import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// B 站 DASH 双流播放器（Dart 侧封装，对应 android 原生插件 `BiliDashPlayerPlugin`）。
///
/// 原生侧负责：双流合并（MergingMediaSource）、防盗链请求头（Referer + UA）、
/// URL 过期识别（onUrlExpired 事件）。Dart 侧负责：取流、过期续播、UI 状态。
///
/// 生命周期：
/// ```dart
/// final player = await BiliDashPlayer.create();
/// final sub = player.events.listen((e) { ... }); // onPrepared/onCompleted/onError/onUrlExpired
/// await player.setDataSource(videoUrl, audioUrl: audioUrl); // 自动播放
/// ...
/// await sub.cancel();
/// await player.dispose();
/// ```
class BiliDashPlayer {
  static const MethodChannel _channel = MethodChannel('bili_dash_player');

  /// 原生侧是**单一** EventChannel（`bili_dash_player/events`），所有播放器共用，
  /// 事件载荷里带 `textureId` 区分播放器；Dart 侧每个播放器按自己的 textureId 过滤。
  static const EventChannel _events = EventChannel('bili_dash_player/events');

  /// 共享原始事件流（receiveBroadcastStream 本身是广播流，可多播放器订阅）。
  static Stream<dynamic>? _sharedRawEvents;

  /// 原生纹理 id，用于 [BiliDashTexture]（Texture(textureId:)）渲染。
  final int textureId;

  BiliDashPlayer._(this.textureId);

  static Stream<dynamic> _rawEvents() =>
      _sharedRawEvents ??= _events.receiveBroadcastStream();

  /// 本播放器的事件流（按 textureId 过滤后的广播流）。
  ///
  /// 事件类型：[BiliDashPreparedEvent] / [BiliDashCompletedEvent] /
  /// [BiliDashErrorEvent] / [BiliDashUrlExpiredEvent]。
  /// 未知事件名 / 载荷非法时静默丢弃（parse 返回 null 后被过滤）。
  ///
  /// ⚠️ 订阅方需持有订阅并在不再需要时 cancel（dispose 原生播放器前先 cancel）。
  Stream<BiliDashEvent> get events => _rawEvents()
      .where((raw) =>
          raw is Map &&
          (raw['textureId'] as num?)?.toInt() == textureId)
      .map(BiliDashEvent.parse)
      .where((e) => e != null)
      .cast<BiliDashEvent>();

  /// 创建原生播放器并返回 Dart 封装（textureId 已可用于渲染）。
  static Future<BiliDashPlayer> create() async {
    final id = await _channel.invokeMethod<int>('create');
    if (id == null) {
      throw StateError('原生播放器创建失败（create 返回 null）');
    }
    return BiliDashPlayer._(id);
  }

  /// 组源并播放：[videoUrl] 必填（DASH video 或 mp4 单流）；
  /// [audioUrl] 为空则退化为单流。[positionMs] 用于过期续播（毫秒）。
  Future<void> setDataSource(
    String videoUrl, {
    String? audioUrl,
    int positionMs = 0,
  }) =>
      _channel.invokeMethod('setDataSource', {
        'textureId': textureId,
        'videoUrl': videoUrl,
        'audioUrl': audioUrl ?? '',
        'positionMs': positionMs,
      });

  Future<void> play() =>
      _channel.invokeMethod('play', {'textureId': textureId});

  Future<void> pause() =>
      _channel.invokeMethod('pause', {'textureId': textureId});

  Future<void> seekTo(int positionMs) => _channel.invokeMethod(
      'seekTo', {'textureId': textureId, 'positionMs': positionMs});

  Future<void> setVolume(double volume) => _channel.invokeMethod(
      'setVolume', {'textureId': textureId, 'volume': volume});

  /// 设置播放倍速（范围 0.25~4.0，原生侧越界自动 clamp）。
  Future<void> setPlaybackSpeed(double speed) => _channel.invokeMethod(
      'setPlaybackSpeed', {'textureId': textureId, 'speed': speed});

  /// 当前播放位置（毫秒）。
  Future<int> getPosition() async {
    final pos = await _channel
        .invokeMethod<int>('getPosition', {'textureId': textureId});
    return pos ?? 0;
  }

  /// 释放原生播放器（纹理随之释放）。
  Future<void> dispose() =>
      _channel.invokeMethod('dispose', {'textureId': textureId});
}

/// 播放器事件（原生 EventChannel 载荷解析结果，按 textureId 过滤后到达）。
sealed class BiliDashEvent {
  /// 事件来源播放器 textureId（多播放器共用一个 EventChannel 时区分用）。
  final int textureId;

  const BiliDashEvent({required this.textureId});

  /// 解析原生事件载荷（map），未知事件名 / 载荷非法返回 null。
  static BiliDashEvent? parse(dynamic raw) {
    if (raw is! Map) return null;
    final id = (raw['textureId'] as num?)?.toInt() ?? -1;
    switch (raw['event'] as String?) {
      case 'onPrepared':
        return BiliDashPreparedEvent(
          textureId: id,
          width: (raw['width'] as num?)?.toInt() ?? 0,
          height: (raw['height'] as num?)?.toInt() ?? 0,
          durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
        );
      case 'onCompleted':
        return BiliDashCompletedEvent(textureId: id);
      case 'onError':
        return BiliDashErrorEvent(
          textureId: id,
          code: (raw['code'] as num?)?.toInt() ?? -1,
          message: raw['message'] as String? ?? '未知错误',
        );
      case 'onUrlExpired':
        return BiliDashUrlExpiredEvent(textureId: id);
      default:
        return null;
    }
  }
}

/// 准备完成：视频宽/高（像素）与总时长（毫秒，未知时为 0）。
class BiliDashPreparedEvent extends BiliDashEvent {
  final int width;
  final int height;
  final int durationMs;

  const BiliDashPreparedEvent({
    required super.textureId,
    required this.width,
    required this.height,
    required this.durationMs,
  });
}

/// 播放到结尾。
class BiliDashCompletedEvent extends BiliDashEvent {
  const BiliDashCompletedEvent({required super.textureId});
}

/// 播放错误（非 URL 过期）：code/message。
class BiliDashErrorEvent extends BiliDashEvent {
  final int code;
  final String message;

  const BiliDashErrorEvent({
    required super.textureId,
    required this.code,
    required this.message,
  });
}

/// 流 URL 过期（403/404/410）——播放页负责重取 playurl 后 setDataSource 续播。
class BiliDashUrlExpiredEvent extends BiliDashEvent {
  const BiliDashUrlExpiredEvent({required super.textureId});
}

/// 渲染原生视频纹理。配合 `AspectRatio` 保持画面比例居中显示。
class BiliDashTexture extends StatelessWidget {
  final int textureId;

  const BiliDashTexture({super.key, required this.textureId});

  @override
  Widget build(BuildContext context) {
    return Texture(textureId: textureId, filterQuality: FilterQuality.low);
  }
}
