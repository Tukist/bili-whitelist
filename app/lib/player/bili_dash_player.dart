import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/media_search_result.dart';

/// B 站 DASH 双流播放器（Dart 侧封装，对应 android 原生插件 `BiliDashPlayerPlugin`）。
///
/// 原生侧负责：双流合并（MergingMediaSource）、防盗链请求头（Referer + UA）、
/// 可自动恢复的数据源错误识别（流 URL 过期 / 瞬时网络错误 → onUrlExpired 事件）、
/// 媒体通知 + 媒体会话（耳机媒体键控制播放，v2.25.x）。
/// Dart 侧负责：取流、自动续播、UI 状态。
///
/// 生命周期：
/// ```dart
/// final player = await BiliDashPlayer.create();
/// final sub = player.events.listen((e) { ... }); // onPrepared/onCompleted/onError/onUrlExpired/onMediaAction
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
  /// [BiliDashErrorEvent] / [BiliDashUrlExpiredEvent] /
  /// [BiliDashMediaActionEvent]。
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
  ///
  /// [title] / [artist]（UP 名）/ [coverUrl] 只写进原生 MediaItem 的元信息，
  /// 供**会话侧**消费者（Android Auto / 车机 / Wear 这类 MediaController，以及
  /// `dumpsys media_session`）读到；不影响取流与解码。
  /// 本 App 自己那条通知的文案走 [updateNowPlaying]。
  /// （v2.25.0-r2 起通知不绑会话 token，系统媒体卡片不再参与显示。）
  Future<void> setDataSource(
    String videoUrl, {
    String? audioUrl,
    int positionMs = 0,
    String title = '',
    String artist = '',
    String coverUrl = '',
  }) =>
      _channel.invokeMethod('setDataSource', {
        'textureId': textureId,
        'videoUrl': videoUrl,
        'audioUrl': audioUrl ?? '',
        'positionMs': positionMs,
        'title': title,
        'artist': artist,
        'coverUrl': normalizeCoverUrl(coverUrl),
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

  /// 同步「正在播放」信息给原生媒体通知 / 媒体会话（Android，v2.25.x）。
  ///
  /// 播放页在**状态变化时**（onPrepared / 播放暂停 / 看待完 / 出错 / 听视频开关 /
  /// 换集换源）调用；原生侧据此刷新通知的标题、副标题（`[artist] · [status]`）
  /// 与封面，并把通知跟随到本播放器上（同时存在两个播放页时，通知跟随最后
  /// 同步的那个）。
  ///
  /// - [status] 是状态文案（`正在播放` / `已暂停` / `已播完` / `播放失败` /
  ///   `后台听视频省流量`），原样拼进副标题；
  /// - [playing] / [positionMs] / [durationMs] 传给原生做状态对齐记录：通知上
  ///   的播放暂停图标与进度一律以原生播放器自身状态为准（不会与真实状态不符）。
  Future<void> updateNowPlaying({
    required String title,
    required String artist,
    required String coverUrl,
    required String status,
    required bool playing,
    required int positionMs,
    required int durationMs,
  }) =>
      _channel.invokeMethod('updateNowPlaying', {
        'textureId': textureId,
        'title': title,
        'artist': artist,
        'coverUrl': normalizeCoverUrl(coverUrl),
        'status': status,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs,
      });

  /// 请求通知权限（Android 13+；<13 或已授权时原生侧空转）。
  ///
  /// v2.25.0-r2 起播放通知**不再**绑媒体会话 token（绑了会被系统媒体卡片接管，
  /// 快退/快进/关闭三个按钮点不到），因此不再享受「媒体会话通知豁免」——
  /// 这条请求是**必需**的：被拒绝时通知不显示（播放本身不受影响）。
  /// 不需要等待结果，也不应因通道异常影响播放（内部吞掉异常）。
  static Future<void> requestNotificationPermission() async {
    try {
      await _channel.invokeMethod('requestNotificationPermission');
    } catch (_) {
      // 原生通道异常（测试环境等）：通知只是增强，忽略
    }
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
          // 播放意图：原生**每次进 READY 都会发 onPrepared**（seek、重新缓冲后
          // 也会），所以这个字段决定界面播放态。载荷缺字段（旧原生 / 测试 mock）
          // 按 true —— 与「setDataSource 后原生自动 play」的既有语义一致。
          playWhenReady: (raw['playWhenReady'] as bool?) ?? true,
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
      case 'onMediaAction':
        return BiliDashMediaActionEvent(
          textureId: id,
          action: raw['action'] as String? ?? '',
          positionMs: (raw['positionMs'] as num?)?.toInt() ?? 0,
        );
      default:
        return null;
    }
  }
}

/// 准备完成：视频宽/高（像素）与总时长（毫秒，未知时为 0）。
///
/// [playWhenReady] 是**原生播放器的真实播放意图**（用户意图，非「此刻是否出声」：
/// 缓冲中 isPlaying 会翻成 false）。Dart 侧据此决定界面播放态——暂停态下 seek
/// 也会触发 onPrepared，若无条件置「正在播放」就会出现「界面与通知都显示在播、
/// 位置却冻结」的错报（v2.25.0-r2 修复）。
class BiliDashPreparedEvent extends BiliDashEvent {
  final int width;
  final int height;
  final int durationMs;
  final bool playWhenReady;

  const BiliDashPreparedEvent({
    required super.textureId,
    required this.width,
    required this.height,
    required this.durationMs,
    this.playWhenReady = true,
  });
}

/// 播放到结尾。
class BiliDashCompletedEvent extends BiliDashEvent {
  const BiliDashCompletedEvent({required super.textureId});
}

/// 播放错误（不可自动恢复，即非 URL 过期 / 瞬时网络类）：code/message。
class BiliDashErrorEvent extends BiliDashEvent {
  final int code;
  final String message;

  const BiliDashErrorEvent({
    required super.textureId,
    required this.code,
    required this.message,
  });
}

/// 流 URL 过期（403/404/410/429/5xx）或瞬时网络错误（超时/断连，如 2001
/// timeout）——原生判定为**可自动恢复**的数据源错误，播放页负责重取 playurl
/// 后 setDataSource 续播（保留位置），不弹错误打断观看。
class BiliDashUrlExpiredEvent extends BiliDashEvent {
  const BiliDashUrlExpiredEvent({required super.textureId});
}

/// 媒体通知 / 耳机媒体键触发的动作（v2.25.x）——播放页据此把界面状态对齐到
/// 原生播放器的真实状态，避免「通知暂停了但界面还显示在播」。
///
/// [action] 取值：
/// - `play`：播放（通知栏 ▶ 或耳机播放键）——原生 playWhenReady 已为 true；
/// - `pause`：暂停（通知栏 ⏸ 或耳机暂停键）；
/// - `seek`：位置跳变，[positionMs] 为新位置。来源：通知栏 / 系统媒体卡片 /
///   锁屏上的**快退 15 秒 / 快进 15 秒**（原生会话自定义命令，见
///   `DashMediaNotification.callback`，实现是 `seekTo(current ± 15000)`）、
///   进度条拖动、断点恢复；
/// - `stop`：通知栏 / 卡片上的「关闭」（✕）——原生已停止播放并清空媒体项
///   （再次播放需重新取流）。
class BiliDashMediaActionEvent extends BiliDashEvent {
  final String action;

  /// seek 的新位置（毫秒）；其他动作为 0。
  final int positionMs;

  const BiliDashMediaActionEvent({
    required super.textureId,
    required this.action,
    required this.positionMs,
  });
}

/// 封面 URL 归一化：`http://…` → `https://…`、`//…` → `https://…`
/// （复用 [MediaSearchResult.normalizeCover]，B 站图床同域支持 https）。
///
/// 为什么在**传给原生之前**做：原生侧下载通知封面走 `HttpURLConnection`，
/// 明文 HTTP 会被 App 的 cleartext 策略直接拒绝（实测 logcat
/// `Cleartext HTTP traffic to i2.hdslb.com not permitted`，部分视频的 cover
/// 字段就是 `http://`）→ 通知 `largeIcon` 恒为 null（不显示封面）。
/// 原生 `downloadBitmap()` 里还有一道同样的兜底（双保险）。
String normalizeCoverUrl(String raw) => MediaSearchResult.normalizeCover(raw);

/// 渲染原生视频纹理。配合 `AspectRatio` 保持画面比例居中显示。
class BiliDashTexture extends StatelessWidget {
  final int textureId;

  const BiliDashTexture({super.key, required this.textureId});

  @override
  Widget build(BuildContext context) {
    return Texture(textureId: textureId, filterQuality: FilterQuality.low);
  }
}
