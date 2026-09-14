/// 直播弹幕服务：连接生命周期（认证 / 心跳 / 断线重连）+ `DANMU_MSG` → [Danmaku]。
///
/// 分工：[LiveDanmakuClient] 管「怎么取信息、怎么连、怎么拆包」，本文件管
/// 「连上之后怎么活」——认证、**认证成功后立刻发第一次心跳**、周期心跳、
/// 退避重连、彻底清理。数据源与渲染层都只认纯数据（[Danmaku]），故本层可单测。
///
/// ## 两条实测踩过的坑（改之前先读）
/// 1. **认证成功后必须立刻发第一次心跳**：实测等了 30s 才发，数据流会「静默」
///    （收不到弹幕也不报错）；之后每 20~25s 一次（本实现取 20s）。
/// 2. **token 会过期**：重连时必须**重新取** token + host（不能复用上次的），
///    所以重连路径走 [LiveDanmakuClient.fetchDanmuInfo] 再连。
///
/// ## 失败一律静默降级
/// 取信息失败 / host 全连不上 / 认证失败 / 帧解析异常，都只 debugPrint，绝不
/// 抛给页面——**弹幕是增强功能，不能成为直播播放的失败点**。重试用尽后状态置
/// [LiveDanmakuStatus.unavailable]，页面最多在开关旁显示一行灰字。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/bilibili_api.dart';
import '../api/live_danmaku_client.dart';
import '../models/danmaku.dart';
import '../models/live_danmaku.dart';

/// 心跳间隔（实测 20~25s 一次；取 20s 留一点余量）。
const Duration kLiveDanmakuHeartbeatInterval = Duration(seconds: 20);

/// 重连退避阶梯（ms）：1s → 2s → 4s → 8s → 8s（约 5 次后放弃）。
const List<int> kLiveDanmakuBackoffMs = [1000, 2000, 4000, 8000, 8000];

/// 弹幕连接状态（页面据此显示不干扰的灰字状态；[connected] 时不显示任何字）。
enum LiveDanmakuStatus {
  /// 未启动 / 已暂停（用户关了弹幕开关）。
  idle,

  /// 取弹幕服务器信息或建连中（含重连）。
  connecting,

  /// 认证成功，正在收弹幕。
  connected,

  /// 重试用尽 / 服务端不可用：弹幕区保持空，**不影响播放**。
  unavailable,
}

/// 直播弹幕服务。用法：
/// ```dart
/// final svc = LiveDanmakuService(api: api)..onDanmaku = (d) => append(d);
/// svc.start(roomId: room.roomId, enteredAtMs: roomEnteredAtMs);
/// // 用户关弹幕开关：svc.pause()；再开：svc.resume()；离开页面：svc.dispose()
/// ```
class LiveDanmakuService {
  /// [api] 取弹幕服务器信息用（测试注入假实现）；[connect] WS 连接器（测试
  /// 注入假 socket）；[clockMs] 时间源（测试注入可控时钟，默认系统墙钟）；
  /// [_heartbeatInterval] / [_backoffMs] 是为**单测提速**留的注入口（生产用默认值）。
  LiveDanmakuService({
    BiliApi? api,
    LiveSocketConnector? connect,
    int Function()? clockMs,
    Duration heartbeatInterval = kLiveDanmakuHeartbeatInterval,
    List<int> backoffMs = kLiveDanmakuBackoffMs,
  })  : _client = LiveDanmakuClient(api: api, connect: connect),
        _clock = clockMs ?? _wallClock,
        _heartbeatInterval = heartbeatInterval,
        _backoffMs = backoffMs;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final LiveDanmakuClient _client;
  final int Function() _clock;
  final Duration _heartbeatInterval;
  final List<int> _backoffMs;

  /// 收到一条弹幕（已带进房秒数的时间轴，可直接喂渲染层）。
  void Function(Danmaku danmaku)? onDanmaku;

  /// 连接状态（页面可监听见 [LiveDanmakuStatus]）。
  final ValueNotifier<LiveDanmakuStatus> status =
      ValueNotifier<LiveDanmakuStatus>(LiveDanmakuStatus.idle);

  int _roomId = 0;

  /// 进房时刻（毫秒）：弹幕没有进度轴，时间轴以它为 0 点。
  int _enteredAtMs = 0;

  LiveSocket? _socket;
  StreamSubscription<Uint8List>? _sub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  /// 已用掉的重连次数（认证成功即清零——长时间稳定后掉线应重新有满额预算）。
  int _attempt = 0;

  /// 代次：pause/resume/重连自增，让在途异步结果作废（避免旧连接回写到新状态）。
  int _session = 0;

  bool _paused = false;
  bool _disposed = false;

  /// 测试探针：已发出重连次数（供「重试用尽」用例断言）。
  @visibleForTesting
  int get debugReconnectAttempts => _attempt;

  /// 开始收弹幕（进页/用户打开开关时调用）。
  ///
  /// [enteredAtMs] = 进房时刻（墙钟毫秒），弹幕的 [Danmaku.timeSec] 一律换算成
  /// 「距进房多少秒」——渲染层零改动（它只用 `positionMs/1000` 与 `timeSec`
  /// 比较），页面把 `positionMs` 喂成「距进房的毫秒数」即可。
  void start({required int roomId, required int enteredAtMs}) {
    if (_disposed || roomId <= 0) return;
    _roomId = roomId;
    _enteredAtMs = enteredAtMs;
    _paused = false;
    _attempt = 0;
    unawaited(_open());
  }

  /// 暂停（用户关掉弹幕开关）：断开连接、停掉心跳与重连，状态回 [idle]。
  void pause() {
    if (_disposed) return;
    _paused = true;
    _session++; // 在途的取信息/连接结果作废
    _stopTimers();
    _closeSocket();
    _setStatus(LiveDanmakuStatus.idle);
  }

  /// 恢复（用户重新打开开关）：重置退避预算重新连。
  void resume() {
    if (_disposed) return;
    _paused = false;
    _attempt = 0;
    unawaited(_open());
  }

  /// 彻底清理（页面销毁时必须调用）：socket、心跳/重连 Timer、状态监听全关，
  /// **不留任何后台活动**（否则退页后还在重连、测试会判 "A Timer is still pending"）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session++;
    _stopTimers();
    _closeSocket();
    status.dispose();
  }

  void _stopTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ---------------------------------------------------------------------------
  // 连接
  // ---------------------------------------------------------------------------

  /// 取 token/host → 逐 host 尝试建连 → 认证。
  Future<void> _open() async {
    if (_disposed || _paused) return;
    final session = ++_session;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _closeSocket();
    if (_disposed || _paused || session != _session) return;
    _setStatus(LiveDanmakuStatus.connecting);

    // 重连**必须重取** token（会过期），不能缓存上次的
    final info = await _client.fetchDanmuInfo(_roomId);
    if (_disposed || _paused || session != _session) return;
    if (info == null || !info.isUsable) {
      _scheduleReconnect(session, '取弹幕服务器信息失败');
      return;
    }

    // host 兜底：host_list 逐项尝试（实测 host_list[0] 也可能连不上）
    LiveSocket? socket;
    for (final host in info.hosts) {
      if (_disposed || _paused || session != _session) return;
      try {
        socket = await _client.connect(host, _roomId);
        debugPrint('[live_danmaku] room=$_roomId 已连 ${host.wssUri}');
        break;
      } catch (e) {
        debugPrint('[live_danmaku] room=$_roomId host $host 连接失败：$e');
      }
    }
    if (socket == null) {
      _scheduleReconnect(session, '全部弹幕 host 连接失败');
      return;
    }
    if (_disposed || _paused || session != _session) {
      await socket.close();
      return;
    }
    _socket = socket;
    _sub = socket.frames.listen(
      (frame) => _onFrame(frame, session),
      onError: (Object e) {
        debugPrint('[live_danmaku] room=$_roomId WS 错误：$e');
        _scheduleReconnect(session, 'WS 错误');
      },
      onDone: () => _scheduleReconnect(session, 'WS 断开'),
    );
    _send(buildLiveAuthPacket(
      roomId: _roomId,
      token: info.token,
      uid: info.uid,
    ));
    debugPrint('[live_danmaku] room=$_roomId 已发认证包（uid=${info.uid}）');
  }

  /// 退避重连（`onDone` / `onError` / 认证失败 / 取信息失败都走这里）。
  void _scheduleReconnect(int session, String reason) {
    if (_disposed || _paused || session != _session) return;
    // onError 与 onDone 可能都触发 → 已有待重连就直接返回（不然会重复排）
    if (_reconnectTimer != null) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _closeSocket();
    if (_attempt >= _backoffMs.length) {
      debugPrint('[live_danmaku] room=$_roomId $reason → 重试用尽'
          '（$_attempt 次），弹幕停止（不影响播放）');
      _setStatus(LiveDanmakuStatus.unavailable);
      return;
    }
    final delay = _backoffMs[_attempt];
    _attempt++;
    debugPrint('[live_danmaku] room=$_roomId $reason → 第 $_attempt 次重连，'
        '退避 ${delay}ms（会重新取 token）');
    _setStatus(LiveDanmakuStatus.connecting);
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      _reconnectTimer = null;
      if (_disposed || _paused || session != _session) return;
      unawaited(_open());
    });
  }

  /// 关掉当前连接（**同步返回**：先摘引用，再 fire-and-forget 收尾）。
  ///
  /// 为什么不等 `await sub.cancel()`：清理动作不能拖慢生效时机——实测在
  /// flutter_test 的假时钟里，`StreamSubscription.cancel()` 的 future 不会在
  /// `tester.pump()` 内完成（真机上也要多绕一个事件循环），`pause()`/`dispose()`
  /// 会「看起来没关连接」。这里改为同步摘引用 + 不等收尾：
  /// - 先关 socket（之后 stream 自然结束；onDone 里的重连由 session/`_paused`
  ///   守卫挡住，见 [_scheduleReconnect]），再 cancel 订阅做收尾；
  /// - 两个收尾都是「清理」，失败（已断开）无需上抛。
  void _closeSocket() {
    final sub = _sub;
    _sub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      unawaited(socket.close().catchError((Object _) {}));
    }
    if (sub != null) {
      unawaited(sub.cancel().catchError((Object _) {}));
    }
  }

  // ---------------------------------------------------------------------------
  // 收包
  // ---------------------------------------------------------------------------

  void _onFrame(Uint8List frame, int session) {
    if (_disposed || session != _session) return;
    for (final event in parseLiveDanmakuFrames(frame)) {
      if (event.isAuthReply) {
        _onAuthReply(event);
      } else if (event.danmaku != null) {
        // 时间轴 = 「收到时刻距进房多少秒」（协议里的时间戳是墙上时间，与直播
        // 画面没有对应关系，不能当进度用）
        final timeSec = (_clock() - _enteredAtMs) / 1000.0;
        onDanmaku?.call(event.danmaku!.toDanmaku(timeSec));
      }
      // 其余（心跳回复/进场/看过人数/通知…）一律忽略
    }
  }

  void _onAuthReply(LiveDanmakuEvent event) {
    final code = event.authCode;
    if (code != 0) {
      // 非 0（token 过期最常见）→ 重取 token 重连
      _scheduleReconnect(_session, '认证失败 code=$code');
      return;
    }
    _attempt = 0; // 连上了：重连预算重置
    debugPrint('[live_danmaku] room=$_roomId 认证成功 → 立刻发第一次心跳'
        '（实测：等 30s 才发会导致数据流静默）');
    _setStatus(LiveDanmakuStatus.connected);
    _heartbeatTimer?.cancel();
    _send(buildLiveHeartbeatPacket()); // ① 认证成功后**立刻**发
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_disposed || _paused) return;
      _send(buildLiveHeartbeatPacket()); // ② 之后每 20~25s 一次
    });
  }

  void _send(List<int> packet) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(packet);
    } catch (e) {
      // 发包失败：连接已坏，交给 onDone/onError 的重连路径（这里不重复排重连）
      debugPrint('[live_danmaku] room=$_roomId 发包失败：$e');
    }
  }

  void _setStatus(LiveDanmakuStatus next) {
    if (_disposed || status.value == next) return;
    status.value = next;
  }
}
