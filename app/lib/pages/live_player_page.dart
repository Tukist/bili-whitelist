/// 直播播放页（v2.27.0+）：App 内观看白名单 UP 主的直播。
///
/// ## 为什么另起一页（不改 `player_page.dart`）
/// VOD 播放页有进度条 / 倍速 / 选集 / 前后三秒 / 下载 / 弹幕(cid) / 断点续播 /
/// 字幕，且这些入口**没有类型门禁**（靠 `_player == null` 或 `_video.isMultiPage`
/// 包一层）。要在一页里同时容纳直播，得在 30+ 处插 `isLive` 分支，diff 不可审、
/// 回归面覆盖整套播放页测试。所以直播走这一页：只保留「中央播放/暂停 + 全屏 +
/// 亮度/音量手势」这一小块控制层，其余一概没有——这也是产品定位（防成瘾）要的
/// 最小形态：能看直播，但没有进度条可以拖、没有倍速可以刷。
///
/// ## 直播与 VOD 的机制差别（本页的全部特殊性都来源于此）
/// - **取流地址有时效**（实测 ≈ 58 分钟）且**不可缓存**：进页现取，播放中按
///   剩余有效期（不足 10 分钟）换新地址续播（[kLiveUrlRefreshLead]）；
/// - **没有时长、没有进度**：`durationMs` 恒为 0（原生 `C.TIME_UNSET`），
///   所以不显示进度条、不做断点续播、左右滑不 seek、观看时长按**真实播过的
///   墙上时间**累计（[WatchStats]）；
/// - **不写历史 / 不写进度**：直播没有 bvid，写进去会污染历史与统计；
/// - **流结束 = 下播**：原生 `onCompleted` 在直播下意味着「主播下播 / 流断了」，
///   显示「直播已结束」+「重新连接」，不显示「播放完成」；
/// - **失败可自愈**：地址过期/网络抖动（原生 onUrlExpired）与播放错误都走
///   「重取地址 → 重设源」的退避重试（1s/2s/4s，最多 3 次）；其中
///   [kLiveErrorBehindWindow]（1002，BehindLiveWindow）是确定性错误
///   → **第 1 次不退避、且不进错误态**（见 [_LivePlayerPageState._autoRecover]）。
///
/// ## 弹幕
/// 直播弹幕走 WS（`lib/api/live_danmaku_client.dart` + `lib/services/
/// live_danmaku_service.dart`），**复用 VOD 那套渲染层与设置**
/// （[DanmakuOverlay] / [DanmakuSettings] / [DanmakuSettingsStore] /
/// [DanmakuSettingsSheet]），本页只做三件事：
/// - **时间轴**：直播没有进度轴 → 把「进房毫秒数」（`_roomElapsedMs`）当播放
///   位置喂给渲染层，弹幕的 `timeSec` 也是「进房秒数」→ 渲染层零改动；
/// - **列表原地追加**：渲染层用 `identical(oldWidget.danmaku, new)` 判「换数据
///   了要清屏」，所以新弹幕必须 `add` 进**同一个 List 实例**（见
///   `_onLiveDanmaku` 的注释）；
/// - **失败静默降级**：取弹幕服务器信息失败 / WS 连不上 → 弹幕区空着，最多在
///   开关旁显示一行灰字，**绝不影响播放**。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/bilibili_api.dart';
import '../api/live_danmaku_client.dart' show LiveSocketConnector;
import '../models/danmaku.dart';
import '../models/danmaku_settings.dart';
import '../models/live_play_info.dart';
import '../player/bili_dash_player.dart';
import '../services/danmaku_settings_store.dart';
import '../services/device_media.dart';
import '../services/live_danmaku_service.dart';
import '../services/watch_stats.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_block.dart';
import '../widgets/app_state_view.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_sheet.dart';
// 复用 VOD 播放页**已经调好的**常量与纯函数（方向、豁免带、灵敏度、半屏判定）：
// 直播页与 VOD 页的手势手感必须一致，抄一份实现迟早会漂移；这里只 import，
// 一行都不改 player_page.dart。
import 'player_page.dart'
    show
        PanSlideMode,
        PlayerSlideKind,
        brightnessPercent,
        isExcludedGestureStart,
        kBottomGestureExclusionFactor,
        kBottomGestureExclusionMinPx,
        kLandscapeVideoHeightRatio,
        kPlayerPageFreeOrientations,
        kPortraitVideoHeightRatio,
        kSideGestureExclusionPxPortrait,
        nextPanMode,
        slideFraction,
        verticalSlideKind,
        volumeTargetLevel;

/// 观看时长累计的一跳（毫秒）与批量落盘阈值：对齐 VOD 播放页的
/// 「500ms tick × 20 次 = 10s 落盘一次」口径（见 `player_page._accumulateWatchTime`）。
///
/// 直播没有播放位置可读，所以直接按**真实跑过的 tick 数**累计：
/// Timer 在 App 退后台时会被系统挂起（不 fire）→ 后台时间不会被算成观看时长。
const int kLiveWatchTickMs = 500;
const int kLiveWatchFlushIntervalMs = 10000;

/// 自动重连的退避阶梯（ms）：1s → 2s → 4s，用满即放弃并显示可重试的错误态。
const List<int> kLiveRecoverBackoffMs = [1000, 2000, 4000];

/// ExoPlayer 的 `ERROR_CODE_BEHIND_LIVE_WINDOW`（`PlaybackException.errorCode`
/// 由原生 `DashExoPlayer.onPlayerError` **原样透传**，所以 Dart 侧拿得到 1002）。
///
/// 直播首帧偶发 `BehindLiveWindowException`：HLS 播放列表已经滚过 ExoPlayer
/// 记下的窗口位置。它**不是**「播放失败」——地址还在、网络也没断，重取一次
/// 地址就等于把窗口拉回最新处（实测约 1 秒即恢复）。所以这一码单独走
/// **静默自愈**：不退避、立刻重取、不进错误态（否则用户会看到一次闪断）。
const int kLiveErrorBehindWindow = 1002;

/// 续期取流失败后的重试间隔（不打断当前播放，稍后再试）。
const Duration kLiveRenewRetryDelay = Duration(minutes: 2);

/// 控制层自动隐藏延时（播放中）。
const Duration kLiveControlsAutoHide = Duration(seconds: 4);

/// 弹幕层的**挂载位置**（画面之上、手势层之下的那块 `Positioned.fill` +
/// `IgnorePointer`）：弹幕开启时这里放 [DanmakuOverlay]，关闭时放等大的空盒，
/// 两种情况都带这个 key（测试据此定位弹幕层所在区域）。
const Key kLiveDanmakuSeamKey = ValueKey('live-danmaku-seam');

/// 弹幕时间轴时钟的推进间隔（毫秒）。
///
/// 与观看时长的 500ms 跳（[kLiveWatchTickMs]）**同值但不同生命周期**：观看
/// 时长只在该「播放中且未缓冲」时累计（暂停即停表），而弹幕时钟必须**单调**
/// 推进——否则暂停 10 分钟后恢复，位置一次跳 600000ms 会触发渲染层的
/// 「跳变 >3s 清屏」，屏上弹幕莫名消失。所以这里单开一个只跑在弹幕开启期间的
/// 时钟跳（值同 500ms，复用同一套节奏感）。
const int kLiveDanmakuTickMs = 500;

/// 直播弹幕列表的**条数上限**与超限后保留的条数。
///
/// 为什么要上限：挂着看几小时直播，弹幕会无限增长（每条约 100 字节）。
/// 怎么处理：超限时**换一次新 List 实例**（只留最近 [kLiveDanmakuKeepCount]
/// 条）——渲染层 `didUpdateWidget` 发现实例变了会清屏重载（一次性的、肉眼
/// 看不见的代价），但**必须换实例**：渲染层的发射游标 `_cursor` 是**列表
/// 下标**，若从头部原地 `removeRange`，下标会整体错位 → 老游标指向新列表的
/// 其它位置，表现为「弹幕忽然乱掉/长时间不再出现」。换实例后游标按当前时刻
/// 重新对齐，语义正确。
const int kLiveDanmakuMaxCount = 4000;
const int kLiveDanmakuKeepCount = 500;

/// 直播播放页。
///
/// [roomId] 必填（取流键）；[title] / [upName] / [upMid] 只用于展示与元信息，
/// 缺省也不影响播放。
class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    required this.roomId,
    this.title = '',
    this.upName = '',
    this.upMid = 0,
    this.api,
    this.clockMs,
    this.danmakuConnector,
  });

  /// 直播间号（`LiveStatus.roomId`）。
  final int roomId;

  /// 直播间标题（列表页拿到的 [LiveStatus.title]，可能为空）。
  final String title;

  /// UP 主名（通知副标题与信息区展示）。
  final String upName;

  /// UP 主 mid（信息区展示；弹幕模块后续取粉丝牌/头像可能也要）。
  final int upMid;

  /// 取流接口（**仅测试注入用**；生产传 null，由 State 自建）。
  /// 与 [UpownerPage.api] / [InboxPage.api] 同一套注入约定。
  @visibleForTesting
  final BiliApi? api;

  /// 时间源（**仅测试注入用**；默认系统墙钟毫秒）。
  ///
  /// 为什么需要注入：直播弹幕的时间轴是「距进房毫秒数」，而 widget 测试里
  /// `tester.pump(Duration)` 推的是**假时钟**、`DateTime.now()` 几乎不动 ——
  /// 不给测试一个可控时钟，「弹幕按时间轴发射」这类断言只能靠真实等待（慢且飘）。
  /// 生产不传。
  @visibleForTesting
  final int Function()? clockMs;

  /// 弹幕 WS 连接器（**仅测试注入用**；生产传 null，走 `dart:io` WebSocket）。
  /// 让 widget 测试塞假 socket 就能端到端验证「弹幕进列表 → 渲染层不清屏」。
  @visibleForTesting
  final LiveSocketConnector? danmakuConnector;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage> {
  late final BiliApi _api;

  BiliDashPlayer? _player;
  int? _textureId;
  StreamSubscription<BiliDashEvent>? _eventSub;

  /// 代次：页面释放 / 重来时自增，避免在途异步结果回写到新状态（同
  /// `player_page._initSession` 的用法）。
  int _session = 0;

  String? _error;
  bool _loading = true; // 首次取流 / 重连取流中
  bool _loaded = false; // 至少 READY 过一次
  bool _buffering = false;
  bool _playing = false;
  bool _ended = false; // 直播已结束（completed 或通知 ✕ 停止）
  bool _stopped = false; // 上面那种「已结束」是不是通知 ✕ 触发的
  bool _reconnecting = false; // 自动重连流程进行中（界面提示「正在重新连接…」）
  bool _notifPermissionRequested = false;
  int _recoverFails = 0; // 本段播放已用掉的重连次数（READY 后清零）
  double _aspectRatio = 16 / 9; // 起播前按 16:9 占位

  Timer? _renewTimer; // 地址续期
  Timer? _watchTimer; // 观看时长累计（仅播放中）
  int _pendingWatchMs = 0; // 未落盘的观看毫秒

  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  // 手势状态（与 VOD 播放页同一套：豁免带判定 + 主导方向锁定 + 半屏定亮度/音量）
  PanSlideMode? _panMode;
  bool _panExcluded = false;
  double _panStartX = 0;
  double _panDx = 0;
  double _panDy = 0;
  PlayerSlideKind? _adjustKind;
  bool _adjustReady = false;
  double _adjustBase = 0;
  double _adjustApplied = 0;
  double _adjustDy = 0;
  double _adjustSpan = 1;
  int _volumeMax = 0;
  PlayerSlideKind? _hudKind;
  double _hudValue = 0;
  Timer? _hudTimer;

  // ---------------------------------------------------------------------------
  // 弹幕（v2.27.0+）
  // ---------------------------------------------------------------------------

  /// 时间源：生产 = 系统墙钟毫秒，测试可注入（见 [LivePlayerPage.clockMs]）。
  late final int Function() _clock =
      widget.clockMs ?? () => DateTime.now().millisecondsSinceEpoch;

  /// **进房时钟**（毫秒）：直播弹幕没有进度轴，时间轴以「进房时刻」为 0 点。
  late final int _roomEnteredAtMs = _clock();

  /// 弹幕渲染数据：**必须保持同一个 List 实例原地追加**（见
  /// `_onLiveDanmaku` 与 [kLiveDanmakuMaxCount] 的说明）。
  List<Danmaku> _liveDanmaku = <Danmaku>[];

  LiveDanmakuService? _danmakuService;
  DanmakuSettings _danmakuSettings = const DanmakuSettings();
  bool _danmakuEnabled = false;

  /// 喂给 [DanmakuOverlay] 的「播放位置」= 距进房毫秒数。
  int _danmakuClockMs = 0;
  Timer? _danmakuClockTimer;

  /// 距进房毫秒数（单调推；弹幕时间轴的唯一基准）。
  int get _roomElapsedMs => _clock() - _roomEnteredAtMs;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? BiliApi();
    debugPrint('[live_player] 进房 room=${widget.roomId} '
        '进房时钟=${_roomEnteredAtMs}ms（弹幕时间轴基准）');
    unawaited(_init());
    // 弹幕设置（含开关记忆）异步读，读不到就用默认（关），不阻塞播放
    unawaited(_loadDanmakuSettings());
  }

  @override
  void dispose() {
    // 代次自增 → 在途的取流/重连结果全部作废（回写会发生 setState after dispose）
    _session++;
    _renewTimer?.cancel();
    _controlsTimer?.cancel();
    _hudTimer?.cancel();
    _danmakuClockTimer?.cancel();
    _danmakuClockTimer = null;
    // 弹幕：断开 WS + 停心跳/重连定时器，不留任何后台活动（否则退页后还在重连）
    _danmakuService?.status.removeListener(_onDanmakuStatusChanged);
    _danmakuService?.dispose();
    _danmakuService = null;
    _stopWatchTimer(); // 顺带把未落盘的观看时长写入（页面退出也算看过）
    _eventSub?.cancel();
    _eventSub = null;
    unawaited(_player?.dispose());
    _player = null;
    // 离开播放页恢复系统方向与系统 UI（同 VOD 播放页 dispose）
    _restoreSystemUi();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 弹幕（数据源 = live_danmaku_service；渲染层与设置全部复用 VOD 那套）
  // -------------------------------------------------------------------------

  /// 异步加载弹幕设置（屏蔽词/类型/透明度/显示区域/**开关记忆**），与 VOD
  /// 播放页同一套存储（[DanmakuSettingsStore]）——两页共享同一份设置。
  ///
  /// 带超时保护：测试环境无 shared_preferences 原生通道时 getInstance 永不
  /// 返回，不能阻塞播放初始化（同 `player_page._loadDanmakuSettings`）。
  Future<void> _loadDanmakuSettings() async {
    try {
      final s = await DanmakuSettingsStore.instance
          .get()
          .timeout(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() {
        _danmakuSettings = s;
        _danmakuEnabled = s.enabled; // 开关记忆：上次开着 → 进页自动开
      });
      if (s.enabled) _startDanmaku();
    } catch (_) {
      // 超时/存储异常：保持默认设置（关），不影响播放
    }
  }

  /// 弹幕总开关（竖屏信息区的那一行，不占中央播放控制区）。
  ///
  /// 状态与 [DanmakuSettings.enabled] 一起持久化（与 VOD 播放页同一份设置），
  /// 重启 App 后保持。
  void _toggleDanmaku() {
    final on = !_danmakuEnabled;
    debugPrint('[live_player] 弹幕开关 -> ${on ? '开' : '关'}');
    setState(() {
      _danmakuEnabled = on;
      _danmakuSettings = _danmakuSettings.copyWith(enabled: on);
      if (!on) _liveDanmaku.clear(); // 关闭即清屏（重开是新建 State，会自动对齐时刻）
    });
    DanmakuSettingsStore.instance.save(_danmakuSettings);
    if (on) {
      _startDanmaku();
    } else {
      _stopDanmaku();
    }
  }

  /// 起弹幕：建服务（一次）→ 启动弹幕时钟 → 连 WS。
  void _startDanmaku() {
    if (!mounted) return;
    var svc = _danmakuService;
    if (svc == null) {
      svc = LiveDanmakuService(
        api: _api,
        connect: widget.danmakuConnector,
        clockMs: _clock,
      )..onDanmaku = _onLiveDanmaku;
      svc.status.addListener(_onDanmakuStatusChanged);
      _danmakuService = svc;
      svc.start(roomId: widget.roomId, enteredAtMs: _roomEnteredAtMs);
    } else {
      svc.resume();
    }
    _ensureDanmakuClock();
  }

  /// 停弹幕：断开连接 + 停时钟（设置与列表保留，开关状态已持久化）。
  void _stopDanmaku() {
    _danmakuClockTimer?.cancel();
    _danmakuClockTimer = null;
    _danmakuService?.pause();
  }

  /// 弹幕时钟（500ms 一跳）：把「距进房毫秒数」推给渲染层当播放位置。
  ///
  /// 为什么不直接复用观看时长那个 500ms 跳（`_watchTimer`）：那个只在
  /// 「播放中且未缓冲」时跑，暂停 10 分钟再恢复，位置会一次跳 600 秒 → 撞上
  /// 渲染层的「跳变 >3s 清屏」；而弹幕时钟必须单调（见 [kLiveDanmakuTickMs]）。
  void _ensureDanmakuClock() {
    if (!mounted) return;
    final t = _danmakuClockTimer;
    if (t != null && t.isActive) return;
    // 首值先对齐当前时刻：让渲染层挂载时的游标从「现在」开始（不补发历史）
    _danmakuClockMs = _roomElapsedMs;
    _danmakuClockTimer = Timer.periodic(
      const Duration(milliseconds: kLiveDanmakuTickMs),
      (_) {
        if (!mounted) return;
        setState(() => _danmakuClockMs = _roomElapsedMs);
      },
    );
  }

  /// 收到一条弹幕 → **原地追加**到同一个 List 实例。
  ///
  /// ⚠️ **不要**写成 `setState(() => _liveDanmaku = [..._liveDanmaku, d])`：
  /// 渲染层 `didUpdateWidget` 里 `!identical(oldWidget.danmaku, widget.danmaku)`
  /// 即「换数据了」→ 清屏重载（VOD 切集就靠这条）。直播是**流式追加**，每次
  /// 换实例都会把屏上弹幕清掉，表现成「弹幕一闪一闪」。渲染层每帧读
  /// `widget.danmaku.length`，同实例原地 add 就能吃到新元素（也无需 setState：
  /// 弹幕时钟每 500ms 的 setState 会把最新的 List 传给渲染层）。
  void _onLiveDanmaku(Danmaku d) {
    if (!mounted || !_danmakuEnabled) return;
    final list = _liveDanmaku;
    if (list.length >= kLiveDanmakuMaxCount) {
      // 超上限：换一次新实例（只留最近若干条）——渲染层会清屏一次，
      // 但游标按当前时刻重新对齐，语义正确；原地删头会让游标下标错位。
      debugPrint('[live_player] 弹幕超过 $kLiveDanmakuMaxCount 条 → '
          '换新列表，仅保留最近 $kLiveDanmakuKeepCount 条（渲染层清屏一次）');
      setState(() {
        _liveDanmaku = List<Danmaku>.of(
          list.sublist(list.length - kLiveDanmakuKeepCount),
        );
      });
      _liveDanmaku.add(d);
      return;
    }
    list.add(d);
  }

  void _onDanmakuStatusChanged() {
    if (mounted) setState(() {});
  }

  /// 弹幕设置面板（复用 VOD 那套 [DanmakuSettingsSheet]）：透明度 / 显示区域 /
  /// 屏蔽词 / 屏蔽类型。改动即时回调 → setState（渲染层收到新 settings 实例即
  /// 清屏重载，立刻生效）+ 持久化。
  Future<void> _showDanmakuSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      // 面板自身是深色卡片（内部配色写死在 DanmakuSettingsSheet 里），宿主
      // 底色与 VOD 播放页拉起面板时保持一致，两页观感一致
      backgroundColor: const Color(0xFF202023),
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      builder: (sheetContext) => DanmakuSettingsSheet(
        initial: _danmakuSettings,
        onChanged: (s) {
          setState(() => _danmakuSettings = s);
          DanmakuSettingsStore.instance.save(s);
        },
      ),
    );
  }

  /// 开关旁的灰字状态（**不干扰播放**，连上时不显示）：弹幕失败只是少一层
  /// 装饰，不弹提示、不挡画面。
  String? get _danmakuHint {
    if (!_danmakuEnabled) return null;
    switch (_danmakuService?.status.value) {
      case LiveDanmakuStatus.connecting:
        return '连接中…';
      case LiveDanmakuStatus.unavailable:
        return '暂不可用';
      case LiveDanmakuStatus.idle:
      case LiveDanmakuStatus.connected:
      case null:
        return null;
    }
  }

  // -------------------------------------------------------------------------
  // 取流 / 播放
  // -------------------------------------------------------------------------

  /// 建立播放器并首次取流起播（重试按钮也走这里）。
  Future<void> _init() async {
    final session = ++_session;
    setState(() {
      _loading = true;
      _error = null;
      _ended = false;
      _stopped = false;
      _reconnecting = false;
      _recoverFails = 0;
    });
    try {
      // isLive: true 必须在**创建期**告知原生：直播不设 ExoPlayer 的 seek
      // 增量（那两个只能在 Builder 上设），通知栏/锁屏因此没有 seek 按钮
      final player = await BiliDashPlayer.create(isLive: true);
      if (!mounted || session != _session) {
        unawaited(player.dispose());
        return;
      }
      _player = player;
      _textureId = player.textureId;
      _eventSub = player.events.listen(_onPlayerEvent);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[live_player] 创建播放器失败：$e');
      if (!mounted || session != _session) return;
      setState(() {
        _error = '播放器初始化失败，请重试';
        _loading = false;
      });
      return;
    }
    await _loadAndPlay(session: session);
  }

  /// 取流 → 设源 → 播放。取流失败落到错误态（错误态里有「重试」按钮）。
  Future<void> _loadAndPlay({required int session}) async {
    final player = _player;
    if (player == null || !mounted || session != _session) return;
    final info = await _api.fetchLivePlayUrl(widget.roomId);
    if (!mounted || session != _session) return;
    if (info == null) {
      setState(() {
        _error = '直播取流失败，请检查网络后重试';
        _loading = false;
      });
      return;
    }
    if (!info.isLive) {
      // 未开播 / 轮播 / 挑不出流：这不是"取流失败"，是直播间本身不可播
      // （与「正在直播」标记的门禁一致：只有 live_status == 1 才给地址）
      debugPrint('[live_player] room=${widget.roomId} 不可播 '
          '（live_status=${info.liveStatus}，地址${info.hlsUrl.isEmpty ? '空' : '有'}）');
      setState(() {
        _loading = false;
        _ended = true;
        _stopped = false;
      });
      unawaited(_syncNowPlaying());
      return;
    }
    setState(() {
      _loading = false;
      _ended = false;
      _buffering = true;
    });
    try {
      await _setSource(player, info);
    } catch (e) {
      debugPrint('[live_player] setDataSource 失败：$e');
      if (!mounted) return;
      setState(() => _error = '直播播放失败，请重试');
      return;
    }
    _scheduleRenewal(info);
  }

  /// 把地址交给原生播放器（直播分支：HLS + 不可 seek）。
  ///
  /// 失败**抛出**（不在这里写错误态）：续期/自动重连路径要按退避继续重试，
  /// 由调用方决定失败语义。
  Future<void> _setSource(BiliDashPlayer player, LivePlayInfo info) {
    return player.setDataSource(
      info.hlsUrl,
      isLive: true,
      positionMs: 0, // 直播无进度语义；原生侧按"窗口默认位置（≈最新）"起播
      title: _displayTitle,
      artist: widget.upName,
      // 直播间封面不在取流响应里（`room_info` 实测为 null），留空 →
      // 媒体通知用应用图标占位；不影响播放本身
      coverUrl: '',
    );
  }

  /// 信息区/通知里的标题（直播间标题为空时退化成「直播间 {roomId}」）。
  String get _displayTitle =>
      widget.title.trim().isEmpty ? '直播间 ${widget.roomId}' : widget.title.trim();

  // -------------------------------------------------------------------------
  // 地址续期（约 58 分钟过期）
  // -------------------------------------------------------------------------

  /// 排下一次换新地址的定时器。
  ///
  /// [info] 为 null（续期取流失败）→ 按 [kLiveRenewRetryDelay] 稍后再试，
  /// **不打断当前播放**：正在播的地址还活着，等它真失败还有自动重连兜底。
  void _scheduleRenewal(LivePlayInfo? info) {
    _renewTimer?.cancel();
    _renewTimer = null;
    if (!mounted || _ended || _error != null) return;
    final delay = info?.refreshDelay ?? kLiveRenewRetryDelay;
    debugPrint('[live_player] 续期定时器 ${delay.inSeconds}s 后触发'
        '（剩余有效期 ${info?.remaining()?.inSeconds ?? '未知'}s）');
    _renewTimer = Timer(delay, () => unawaited(_renew()));
  }

  Future<void> _renew() async {
    final player = _player;
    if (!mounted || player == null || _ended || _error != null) return;
    final session = _session;
    final info = await _api.fetchLivePlayUrl(widget.roomId);
    if (!mounted || session != _session) return;
    if (info == null || !info.isLive) {
      debugPrint('[live_player] 续期取流失败/已下播（不打断当前播放），'
          '${kLiveRenewRetryDelay.inMinutes} 分钟后重试');
      _scheduleRenewal(null);
      return;
    }
    _recoverFails = 0;
    debugPrint('[live_player] 续期换源：host=${info.host} '
        '剩余=${info.remaining()?.inSeconds}s');
    try {
      await _setSource(player, info);
    } catch (e) {
      // 换源失败：当前地址还在播，不弹错、下轮再试
      debugPrint('[live_player] 续期换源失败（保持当前播放）：$e');
    }
    _scheduleRenewal(info);
  }

  // -------------------------------------------------------------------------
  // 失败自愈（地址过期 / 网络抖动 / 播放错误）
  // -------------------------------------------------------------------------

  /// 退避重连：用**新取的**地址重设源，最多 [kLiveRecoverBackoffMs] 次。
  ///
  /// 与 VOD 播放页的 `_onAutoRecover` 同思路但更轻：直播不需要保留位置
  /// （重设源即回到最新处），也不需要预取/代次以外的额外状态。
  ///
  /// [immediate] = true（只有 [kLiveErrorBehindWindow] 走这条）：**第 1 次不退避**。
  /// 窗口漂移是确定性的「重取即好」，等 1 秒只是把黑屏拉长；但**预算照常扣**
  /// （[kLiveRecoverBackoffMs] 的档位从第 2 次起照用），所以连续 1002 不恢复时
  /// 仍会走完 3 次并落到错误态，不会变成死循环。
  Future<void> _autoRecover({
    required String reason,
    bool immediate = false,
  }) async {
    if (!mounted || _reconnecting || _ended) return;
    final player = _player;
    if (player == null) return;
    if (_recoverFails >= kLiveRecoverBackoffMs.length) {
      // 预算用尽：落到错误态（有「重试」按钮手动兜底）
      setState(() => _error = '直播连接失败，请稍后重试');
      return;
    }
    _reconnecting = true;
    if (mounted) setState(() => _buffering = true);
    final session = _session;
    try {
      while (mounted && session == _session && !_ended) {
        final attempt = _recoverFails;
        if (attempt >= kLiveRecoverBackoffMs.length) break;
        _recoverFails = attempt + 1; // 预扣一次（成功 READY 后在 onPrepared 清零）
        final delayMs = immediate && attempt == 0
            ? 0
            : kLiveRecoverBackoffMs[attempt];
        debugPrint('[live_player] $reason → 第 ${attempt + 1} 次重连，'
            '${delayMs == 0 ? '不退避（立即重取地址）' : '退避 ${delayMs}ms'}');
        if (delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
        if (!mounted || session != _session || _ended) return;
        final info = await _api.fetchLivePlayUrl(widget.roomId);
        if (!mounted || session != _session || _ended) return;
        if (info == null) continue; // 取流也失败：按下一档退避再试
        if (!info.isLive) {
          // 主播下播了：重连没有意义，直接收成「直播已结束」
          _onCompleted();
          return;
        }
        try {
          await _setSource(player, info);
        } catch (e) {
          debugPrint('[live_player] 重连设源失败：$e');
          continue;
        }
        _scheduleRenewal(info); // 新流 READY 由 onPrepared 收尾
        return;
      }
      if (mounted && session == _session && !_ended) {
        setState(() => _error = '直播连接失败，请稍后重试');
      }
    } finally {
      // 无论成败都解除「重连中」：成功时新流即将 READY（onPrepared 会再清一次），
      // 失败时已经落到错误态；不解除的话下一次原生错误会被挡在门外
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  /// 手动「重试」/「重新连接」：重置预算后重新取流起播。
  Future<void> _retry() async {
    if (!mounted) return;
    _renewTimer?.cancel();
    _renewTimer = null;
    _recoverFails = 0;
    if (_player == null) {
      await _init(); // 播放器都没建起来（首次失败）：整页重来
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
      _ended = false;
      _stopped = false;
      _reconnecting = false;
    });
    await _loadAndPlay(session: _session);
  }

  // -------------------------------------------------------------------------
  // 原生事件
  // -------------------------------------------------------------------------

  void _onPlayerEvent(BiliDashEvent e) {
    debugPrint('[live_player] event: ${e.runtimeType} textureId=${e.textureId}');
    if (!mounted) return;
    switch (e) {
      case BiliDashPreparedEvent(:final width, :final height, :final playWhenReady):
        _onPrepared(width, height, playWhenReady);
      case BiliDashCompletedEvent():
        _onCompleted();
      case BiliDashErrorEvent(:final code, :final message):
        _onNativeError(code, message);
      case BiliDashUrlExpiredEvent():
        unawaited(_autoRecover(reason: '流地址过期/网络抖动'));
      case BiliDashMediaActionEvent(:final action):
        _onMediaAction(action);
    }
  }

  void _onPrepared(int width, int height, bool playWhenReady) {
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _loading = false;
      _buffering = false;
      _reconnecting = false;
      _ended = false;
      _stopped = false;
      _recoverFails = 0; // 新流就绪 → 重连预算重置（每段播放独立预算）
      // 播放态取原生的真实播放意图（暂停态下重新缓冲也会走这里）
      _playing = playWhenReady;
      if (width > 0 && height > 0) _aspectRatio = width / height;
    });
    _ensureWatchTimer();
    _scheduleControlsHide();
    unawaited(_syncNowPlaying());
  }

  /// 直播流结束 / 通知 ✕ 停止：**不显示「播放完成」**，收成「直播已结束」，
  /// 并停掉续期定时器（地址已经没用了）。
  void _onCompleted() {
    if (!mounted) return;
    _renewTimer?.cancel();
    _renewTimer = null;
    _stopWatchTimer();
    setState(() {
      _playing = false;
      _buffering = false;
      _reconnecting = false;
      _ended = true;
      _stopped = false;
    });
    unawaited(_syncNowPlaying());
  }

  void _onNativeError(int code, String message) {
    debugPrint('[live_player] 原生播放错误 code=$code msg=$message');
    if (!mounted) return;
    if (code == kLiveErrorBehindWindow) {
      // 直播窗口漂移（BehindLiveWindowException，实测首帧偶发）：**不是播放失败**
      // ——地址还在、网络也没断，重取一次地址就等于把窗口拉回最新处。
      // 走「静默自愈」：不退避立刻重取（见 [_autoRecover] 的 immediate），期间
      // 只显示「正在重新连接…」，**不进错误态**（真机上这里曾闪一下「播放失败」
      // 卡片）。预算照常扣，连续不恢复最终仍落到错误态（不会死循环）。
      unawaited(_autoRecover(reason: '直播窗口漂移（$code）', immediate: true));
      return;
    }
    unawaited(_autoRecover(reason: '播放错误（$code）'));
  }

  /// 通知 / 耳机按键回传（原生已经执行了动作，这里只对齐界面）。
  void _onMediaAction(String action) {
    debugPrint('[live_player] onMediaAction action=$action');
    switch (action) {
      case 'play':
        if (mounted) setState(() => _playing = true);
        _ensureWatchTimer();
        unawaited(_syncNowPlaying());
      case 'pause':
        if (mounted) setState(() => _playing = false);
        _stopWatchTimer();
        unawaited(_syncNowPlaying());
      case 'stop':
        // 通知栏 ✕：等同用户主动停止（直播没有"已完成"的语义，文案区分开）
        _renewTimer?.cancel();
        _renewTimer = null;
        _stopWatchTimer();
        if (mounted) {
          setState(() {
            _playing = false;
            _buffering = false;
            _reconnecting = false;
            _ended = true;
            _stopped = true;
          });
        }
        unawaited(_syncNowPlaying());
      default:
        // 'seek'：直播不可 seek（原生已不派发），这里再挡一层
        break;
    }
  }

  // -------------------------------------------------------------------------
  // 观看时长统计（直播没有进度轴，按真实播过的 tick 累计）
  // -------------------------------------------------------------------------

  void _ensureWatchTimer() {
    if (!mounted || _ended || !_playing || _buffering) return;
    final t = _watchTimer;
    if (t != null && t.isActive) return; // 已在跑：不重开（防双计时器）
    t?.cancel(); // 死实例（暂停时 cancel 过）
    _watchTimer = Timer.periodic(
      const Duration(milliseconds: kLiveWatchTickMs),
      (_) => _onWatchTick(),
    );
  }

  void _onWatchTick() {
    if (!mounted || !_playing || _buffering || _ended) return;
    _pendingWatchMs += kLiveWatchTickMs;
    if (_pendingWatchMs >= kLiveWatchFlushIntervalMs) _flushWatchTime();
  }

  /// 批量落盘（整秒取整；不足 1s 的残留留给下次，同 VOD 播放页口径）。
  void _flushWatchTime() {
    if (_pendingWatchMs < 1000) return;
    final seconds = _pendingWatchMs ~/ 1000;
    _pendingWatchMs -= seconds * 1000;
    debugPrint('[live_player] 观看时长 +${seconds}s（room=${widget.roomId}）');
    unawaited(WatchStats.instance.record(seconds));
  }

  /// 暂停 / 停止 / 退页：停表并落盘（漏掉这一段会让热力图少算）。
  void _stopWatchTimer() {
    _watchTimer?.cancel();
    _watchTimer = null;
    _flushWatchTime();
  }

  // -------------------------------------------------------------------------
  // 媒体通知（B 站式通知 + 耳机按键；直播的 seek 由原生侧关掉）
  // -------------------------------------------------------------------------

  /// 通知状态文案（原生拼成 `<UP 名> · <状态>`）。
  String get _nowPlayingStatus {
    if (_error != null) return '直播连接失败';
    if (_reconnecting) return '正在重新连接';
    if (_ended) return _stopped ? '已停止' : '直播已结束';
    if (!_playing) return '已暂停';
    return '正在直播';
  }

  Future<void> _syncNowPlaying() async {
    final player = _player;
    if (player == null) return;
    if (!_notifPermissionRequested) {
      _notifPermissionRequested = true;
      unawaited(BiliDashPlayer.requestNotificationPermission());
    }
    try {
      await player.updateNowPlaying(
        // 标题带「直播」：锁屏 / 车机上要一眼看出这不是普通视频
        title: '直播 · $_displayTitle',
        artist: widget.upName.isEmpty ? 'B 站直播' : widget.upName,
        coverUrl: '',
        status: _nowPlayingStatus,
        playing: _playing,
        // 直播没有进度：位置与时长一律 0（原生只做状态对齐，不显示进度）
        positionMs: 0,
        durationMs: 0,
      );
    } catch (_) {
      // 通道异常：通知只是增强，忽略（播放照常）
    }
  }

  // -------------------------------------------------------------------------
  // 界面动作
  // -------------------------------------------------------------------------

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null || _ended || _error != null) return;
    final next = !_playing;
    setState(() => _playing = next);
    if (next) {
      await player.play();
      _ensureWatchTimer();
    } else {
      await player.pause();
      _stopWatchTimer();
    }
    _scheduleControlsHide();
    unawaited(_syncNowPlaying());
  }

  Future<void> _toggleFullscreen() async {
    final full = !_fullscreen;
    setState(() {
      _fullscreen = full;
      _controlsVisible = true;
    });
    if (full) {
      // 进全屏：锁横屏 + 沉浸（同 VOD 播放页）
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      // 退出全屏：放开「竖屏 + 双向横屏」，当前横放就停在横屏
      await SystemChrome.setPreferredOrientations(kPlayerPageFreeOrientations);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleControlsHide();
  }

  void _restoreSystemUi() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _toggleControls() {
    final next = !_controlsVisible;
    setState(() => _controlsVisible = next);
    if (next) _scheduleControlsHide();
  }

  /// 播放中才自动收起（暂停/出错时不收：用户正在找按钮）。
  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (!_playing || _ended) return;
    _controlsTimer = Timer(kLiveControlsAutoHide, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  /// 返回键 / 顶栏箭头：全屏中先退全屏，否则离页（同 VOD 播放页语义）。
  void _handleBack() {
    if (_fullscreen) {
      unawaited(_toggleFullscreen());
      return;
    }
    Navigator.of(context).pop();
  }

  // -------------------------------------------------------------------------
  // 手势：亮度 / 音量（**没有左右滑** —— 直播不可 seek）
  // -------------------------------------------------------------------------

  /// 手势层矩形：全屏 = 整屏；非全屏 = 视频区黑盒（同 VOD 播放页口径）。
  Size _gestureAreaSize() {
    final s = MediaQuery.sizeOf(context);
    if (_fullscreen) return s;
    return Size(s.width, _embeddedVideoHeight(s));
  }

  double _sideGestureExclusionPx(Size size) {
    if (size.width > size.height) {
      return math.max(
          size.height * kBottomGestureExclusionFactor,
          kBottomGestureExclusionMinPx);
    }
    return kSideGestureExclusionPxPortrait;
  }

  /// 非全屏视频区高度：按视频宽高比铺满可用宽，再按方向封顶（竖屏 60% /
  /// 横屏 55%，与 VOD 播放页同一套取值，保证两页观感一致）。
  double _embeddedVideoHeight(Size screen) {
    final aspect = _aspectRatio > 0 ? _aspectRatio : 16 / 9;
    final ideal = screen.width / aspect;
    final capRatio = screen.width > screen.height
        ? kLandscapeVideoHeightRatio
        : kPortraitVideoHeightRatio;
    final maxH = screen.height * capRatio;
    return ideal > maxH ? maxH : ideal;
  }

  /// 按下点判豁免带（用**按下点**而非竞技场胜出点，同 VOD 播放页）：
  /// 从屏幕边缘/底部启动的滑动让给系统手势，不当作亮度/音量调节。
  void _onPanDown(DragDownDetails d) {
    if (_player == null) return;
    final size = _gestureAreaSize();
    final sidePx = _sideGestureExclusionPx(MediaQuery.sizeOf(context));
    // 底部豁免带只在全屏生效（语义 = 物理屏幕底边 = 系统导航区）
    final bottomFactor = _fullscreen ? kBottomGestureExclusionFactor : 0.0;
    final bottomMinPx = _fullscreen ? kBottomGestureExclusionMinPx : 0.0;
    _panExcluded = isExcludedGestureStart(
      x0: d.localPosition.dx,
      y0: d.localPosition.dy,
      width: size.width,
      height: size.height,
      bottomFactor: bottomFactor,
      bottomMinPx: bottomMinPx,
      leftPx: sidePx,
      rightPx: sidePx,
    );
  }

  void _onPanStart(DragStartDetails d) {
    if (_player == null || _panExcluded) return;
    _panMode = null;
    _panStartX = d.localPosition.dx;
    _panDx = 0;
    _panDy = 0;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_panExcluded) return;
    if (_panMode == null) {
      _panDx += d.delta.dx;
      _panDy += d.delta.dy;
      final m = nextPanMode(current: null, dx: _panDx, dy: _panDy);
      if (m != null) _lockPanMode(m);
    }
    // 垂直主导 → 亮度/音量；水平主导 → **什么也不做**（直播不可 seek，
    // 本页不注册任何左右滑行为，见类注释）
    if (_panMode == PanSlideMode.vertical) _onVerticalDragUpdate(d);
  }

  void _lockPanMode(PanSlideMode m) {
    _panMode = m;
    if (m == PanSlideMode.vertical) _beginVerticalAdjust();
  }

  void _onPanEnd(DragEndDetails _) {
    final m = _panMode;
    _panMode = null;
    if (_panExcluded) {
      _panExcluded = false;
      return;
    }
    if (m == PanSlideMode.vertical) _onVerticalDragEnd();
  }

  void _onPanCancel() {
    _panExcluded = false;
    _panMode = null;
    if (_adjustKind != null) {
      _adjustKind = null;
      _adjustReady = false;
      _scheduleHudHide();
    }
  }

  /// 锁定为垂直：按起点半屏定类型，再**异步读基准**（音量当前/最大档、
  /// 亮度百分比）。读基准期间 [_adjustReady] = false，忽略滑动——基准没到位
  /// 就换算是「动一点跳 0/100」的根因（同 VOD 播放页的取舍）。
  void _beginVerticalAdjust() {
    final area = _gestureAreaSize();
    final kind = verticalSlideKind(_panStartX, area.width);
    _adjustKind = kind;
    _adjustReady = false;
    _adjustDy = 0;
    _adjustApplied = 0;
    _adjustSpan = area.height;
    if (kind == PlayerSlideKind.volume) {
      _volumeMax = 0;
      DeviceMedia.getVolume().then((v) {
        if (!mounted || _adjustKind != kind) return;
        if (v == null || v.max <= 0) {
          // 通道失败 / 无音量设备：本次手势作废（不硬设 0）
          debugPrint('[live_player] 音量基准读取失败（v=$v）→ 放弃本次手势');
          _adjustKind = null;
          _scheduleHudHide();
          return;
        }
        _volumeMax = v.max;
        _adjustBase = v.current.toDouble();
        _adjustApplied = v.current.toDouble();
        _adjustReady = true;
        _showValueHud(kind, _percentOfLevel(v.current, v.max));
      });
    } else {
      DeviceMedia.getBrightnessPercent().then((pct) {
        if (!mounted || _adjustKind != kind) return;
        final base = pct < 5 ? 5.0 : pct; // 亮度下限 5%（同原生）
        _adjustBase = base;
        _adjustApplied = base;
        _adjustReady = true;
        _showValueHud(kind, base);
      });
    }
  }

  /// 纵向滑动：目标一律按「锁定时的固定基准 + 累计比例 × 灵敏度 0.3」换算
  /// （基准不逐帧改写），变化达阈值才写原生通道。
  void _onVerticalDragUpdate(DragUpdateDetails d) {
    final kind = _adjustKind;
    if (kind == null || !_adjustReady) return;
    _adjustDy += d.delta.dy;
    final fraction = slideFraction(-_adjustDy, _adjustSpan);
    if (kind == PlayerSlideKind.volume) {
      final level = volumeTargetLevel(
        baseLevel: _adjustBase.round(),
        fraction: fraction,
        maxLevel: _volumeMax,
      );
      if (level != _adjustApplied.round()) {
        DeviceMedia.setVolume(level);
        _adjustApplied = level.toDouble();
        _showValueHud(kind, _percentOfLevel(level, _volumeMax));
      }
    } else {
      final pct = brightnessPercent(basePercent: _adjustBase, fraction: fraction);
      if ((pct - _adjustApplied).abs() >= 1) {
        DeviceMedia.setBrightness(pct / 100);
        _adjustApplied = pct;
        _showValueHud(kind, pct);
      }
    }
  }

  void _onVerticalDragEnd() {
    if (_adjustKind == null) return;
    _adjustKind = null;
    _adjustReady = false;
    _scheduleHudHide();
  }

  double _percentOfLevel(int level, int max) =>
      max <= 0 ? 0 : (level * 100 / max).roundToDouble();

  void _showValueHud(PlayerSlideKind kind, double value) {
    _hudTimer?.cancel();
    if (mounted) {
      setState(() {
        _hudKind = kind;
        _hudValue = value;
      });
    }
    _scheduleHudHide();
  }

  void _scheduleHudHide() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hudKind = null);
    });
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 取流失败 / 重连用尽 → 整页标准错误态（AppErrorView 是纸底组件，
    // 放在视频黑底上会糊掉对比度，所以这里换成常规页面形态）
    final error = _error;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        body: AppErrorView(
          scrollable: true,
          message: error,
          subtitle: '直播地址有效期较短，长时间观看会自动换流；'
              '若一直连不上，可稍后再试',
          onRetry: () => unawaited(_retry()),
          illustrationSeed: 'error.live',
        ),
      );
    }
    final screen = MediaQuery.sizeOf(context);
    final videoAreaHeight =
        _fullscreen ? screen.height : _embeddedVideoHeight(screen);
    return PopScope(
      // 系统返回键：全屏中拦截为「先退出全屏」（同 VOD 播放页）
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) unawaited(_toggleFullscreen());
      },
      child: Scaffold(
        backgroundColor: _fullscreen
            ? Colors.black
            : Theme.of(context).colorScheme.surface,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const ValueKey('live-video-area'),
              height: videoAreaHeight,
              child: ColoredBox(color: Colors.black, child: _buildVideoLayers()),
            ),
            if (!_fullscreen) Expanded(child: _buildInfoArea(context)),
          ],
        ),
      ),
    );
  }

  /// 视频层（全屏 / 非全屏共用）：画面 → 弹幕接缝 → 手势 → 结束态 → 控制层 →
  /// 提示浮层 → 缓冲指示。
  Widget _buildVideoLayers() {
    final textureId = _textureId;
    return Stack(
      children: [
        // 1. 画面：原生纹理，按视频宽高比居中（黑边补齐）
        Positioned.fill(
          child: Center(
            child: AspectRatio(
              aspectRatio: _aspectRatio > 0 ? _aspectRatio : 16 / 9,
              child: textureId == null
                  ? const SizedBox.shrink()
                  : BiliDashTexture(textureId: textureId),
            ),
          ),
        ),
        // 2. 弹幕层：画面之上、手势层之下（IgnorePointer 不抢手势）。
        //    开启时挂 `DanmakuOverlay`（复用 VOD 渲染层），关闭时留一块等大的
        //    空盒——两种情况都带 [kLiveDanmakuSeamKey]，测试可稳定定位。
        //    时钟：`positionMs` = 距进房毫秒数，弹幕 `timeSec` 也是进房秒数，
        //    渲染层零改动即可按时序发射。
        //    `playing` 用 `!_ended` 而不是 `_playing`：直播弹幕是墙上时间流，
        //    用户暂停画面不该让弹幕冻住（B 站直播同样如此）。
        Positioned.fill(
          child: IgnorePointer(
            child: _danmakuEnabled
                ? DanmakuOverlay(
                    key: kLiveDanmakuSeamKey,
                    danmaku: _liveDanmaku,
                    playing: !_ended,
                    positionMs: _danmakuClockMs,
                    settings: _danmakuSettings,
                  )
                : const SizedBox.expand(key: kLiveDanmakuSeamKey),
          ),
        ),
        // 3. 手势层：单击显隐控制层；上下滑调亮度/音量（不注册左右滑）
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onPanDown: _player == null ? null : _onPanDown,
            onPanStart: _player == null ? null : _onPanStart,
            onPanUpdate: _player == null ? null : _onPanUpdate,
            onPanEnd: _player == null ? null : _onPanEnd,
            onPanCancel: _player == null ? null : _onPanCancel,
          ),
        ),
        // 5. 控制层（未就绪时也显示，保证加载中也有返回键）
        if (_controlsVisible || !_loaded) _buildControls(),
        // 6. 手势提示（亮度/音量）
        if (_hudKind != null)
          Positioned.fill(child: IgnorePointer(child: _buildGestureHud())),
        // 7. 缓冲 / 首次取流
        if (_loading || _buffering)
          const Center(child: CircularProgressIndicator(color: kPlayerOn)),
        // 8. 直播已结束 / 已停止：盖在控制层**之上**（此时中央播放键已无意义，
        //    而「重新连接」必须点得到）。做成居中小面板而不是整屏遮罩——
        //    顶栏的返回键与全屏键仍然露在外面可用。
        if (_ended) Positioned.fill(child: _buildEndedOverlay()),
        // 9. 重连提示（压在缓冲环上方，文案与图标一起给）
        if (_reconnecting) Center(child: _buildReconnectingNotice()),
      ],
    );
  }

  /// 控制层：顶栏（返回 / 标题 / 全屏）+ 中央播放暂停。
  ///
  /// 刻意只有这两样：直播没有进度条、倍速、选集、下载、字幕、一键三连、
  /// 评论入口（那些在 VOD 播放页，直播全都不适用）。
  Widget _buildControls() {
    return Stack(
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ColoredBox(
            color: kInkBlack.withValues(alpha: 0.55),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    color: kPlayerOn,
                    iconSize: 22,
                    tooltip: _fullscreen ? '退出全屏' : '返回',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _handleBack,
                  ),
                  Expanded(
                    child: Text(
                      _displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kTypeTitleS.copyWith(color: kPlayerOn),
                    ),
                  ),
                  const _LiveDot(),
                  const SizedBox(width: kSpace4),
                  IconButton(
                    color: kPlayerOn,
                    iconSize: 22,
                    tooltip: _fullscreen ? '退出全屏' : '全屏',
                    icon: Icon(
                      _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                    onPressed: () => unawaited(_toggleFullscreen()),
                  ),
                  const SizedBox(width: kSpace4),
                ],
              ),
            ),
          ),
        ),
        Center(
          child: IconButton(
            color: kPlayerOn,
            iconSize: 56,
            tooltip: _playing ? '暂停' : '播放',
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: () => unawaited(_togglePlay()),
          ),
        ),
      ],
    );
  }

  /// 手势提示浮层（亮度 / 音量）：墨黑胶囊 + 图标 + 百分比。
  Widget _buildGestureHud() {
    final kind = _hudKind;
    if (kind == null) return const SizedBox.shrink();
    final icon = kind == PlayerSlideKind.brightness
        ? Icons.brightness_6
        : Icons.volume_up;
    final label = '${_hudValue.clamp(0, 100).round()}%';
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace16,
          vertical: kSpace12,
        ),
        decoration: BoxDecoration(
          color: kInkBlack.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: kPlayerOn, size: 20),
            const SizedBox(width: kSpace8),
            Text(label, style: kTypeTitleS.copyWith(color: kPlayerOn)),
          ],
        ),
      ),
    );
  }

  /// 「正在重新连接…」：播放失败自愈期间给用户一个明确的进行中提示。
  Widget _buildReconnectingNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace8,
      ),
      decoration: BoxDecoration(
        color: kInkBlack.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: kPlayerOn),
          ),
          const SizedBox(width: kSpace8),
          Text(
            '正在重新连接…',
            style: kTypeBodyS.copyWith(color: kPlayerOn),
          ),
        ],
      ),
    );
  }

  /// 「直播已结束 / 已停止播放」+「重新连接」。
  ///
  /// 做成一枚**居中小面板**（不是整屏遮罩）：整屏遮罩会连顶栏的返回键一起
  /// 吃掉，而直播结束恰恰需要给用户一条"退回去"的路。面板自身不透明底
  /// 保证文字对比度（kPlayerOn 纸白压在墨黑上）。
  Widget _buildEndedOverlay() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace24,
          vertical: kSpace16,
        ),
        decoration: BoxDecoration(
          color: kInkBlack.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(kRadiusMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _stopped ? '已停止播放' : '直播已结束',
              style: kTypeTitleS.copyWith(color: kPlayerOn),
            ),
            const SizedBox(height: kSpace12),
            OutlinedButton(
              onPressed: () => unawaited(_retry()),
              style: OutlinedButton.styleFrom(
                foregroundColor: kPlayerOn,
                side: const BorderSide(color: kPlayerOnDim),
              ),
              child: const Text('重新连接'),
            ),
          ],
        ),
      ),
    );
  }

  /// 非全屏时的下方信息区：直播间标题 / UP 主 / 弹幕占位 / 返回与全屏。
  ///
  /// 视觉走项目 token（[AppBlock] + [context.palette]，不写颜色字面量、
  /// 不加阴影），与其它页面的信息块同构。
  Widget _buildInfoArea(BuildContext context) {
    final palette = context.palette;
    final title = widget.title.trim();
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        kPagePadH,
        kSpace16,
        kPagePadH,
        kSpace24 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBlock(
            variant: AppBlockVariant.videoInfo,
            child: Padding(
              padding: const EdgeInsets.only(top: kSpace4, bottom: kSpace8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: kSpace8,
                          vertical: kSpace2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.accentWash,
                          borderRadius: BorderRadius.circular(kRadiusXs),
                        ),
                        child: Text(
                          _nowPlayingStatus,
                          style: kTypeLabel.copyWith(color: palette.accentDeep),
                        ),
                      ),
                      const SizedBox(width: kSpace8),
                      Text(
                        '直播间 ${widget.roomId}',
                        style: kTypeNum.copyWith(color: kInkGray50),
                      ),
                    ],
                  ),
                  const SizedBox(height: kSpace8),
                  Text(
                    title.isEmpty ? '直播间 ${widget.roomId}' : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: kTypeTitleM.copyWith(color: kInkBlack),
                  ),
                  const SizedBox(height: kSpace4),
                  Text(
                    widget.upName.isEmpty ? '未知 UP 主' : widget.upName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kTypeBodyS.copyWith(color: kInkGray70),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: kBlockGap),
          // 弹幕开关 + 设置入口：放在竖屏信息区（**不占中央播放控制区**，
          // 直播页的中央只留播放/暂停）。开关状态与 VOD 播放页共用同一份设置
          // 持久化（[DanmakuSettingsStore]），重启 App 后保持。
          AppBlock(
            variant: AppBlockVariant.setting,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '弹幕',
                        style: kTypeBody.copyWith(color: kInkBlack),
                      ),
                      // 灰字状态：只在「开启且还不能用」时出现，不弹提示、
                      // 不挡画面（弹幕是装饰，绝不能成为播放的失败点）
                      if (_danmakuHint != null)
                        Text(
                          _danmakuHint!,
                          style: kTypeBodyS.copyWith(color: kInkGray50),
                        ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(_showDanmakuSettings()),
                  style: TextButton.styleFrom(
                    foregroundColor: palette.accentDeep,
                    minimumSize: const Size(56, 40),
                  ),
                  child: const Text('设置'),
                ),
                Switch(
                  value: _danmakuEnabled,
                  onChanged: (_) => _toggleDanmaku(),
                ),
              ],
            ),
          ),
          const SizedBox(height: kBlockGap),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kInkBlack,
                  side: const BorderSide(color: kRuleStrong),
                  minimumSize: const Size(88, 44),
                ),
                child: const Text('返回'),
              ),
              const SizedBox(width: kSpace12),
              OutlinedButton(
                onPressed: () => unawaited(_toggleFullscreen()),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kInkBlack,
                  side: const BorderSide(color: kRuleStrong),
                  minimumSize: const Size(88, 44),
                ),
                child: const Text('全屏'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 顶栏上的「直播中」小圆点（点缀墨 = 新鲜的墨，与「正在直播」标记同一语义）；
/// 单独抽出来只是为了让 [_LivePlayerPageState._buildControls] 的 Row 读起来短一点。
class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        // 走 palette（换配色配方时自动跟随，见 app_palette 的约定）
        color: context.palette.accentFill,
        shape: BoxShape.circle,
      ),
    );
  }
}
