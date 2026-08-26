import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/bilibili_api.dart';
import '../api/translate_api.dart';
import '../api/whisper_audio.dart';
import '../api/whisper_model.dart';
import '../cache/download_manager.dart';
import '../cache/playback_progress.dart';
import '../config.dart';
import '../models/subtitle.dart';
import '../models/whitelist_video.dart';
import '../player/bili_dash_player.dart';
import '../services/transcriber.dart';
import 'login_page.dart';

/// 可选的播放倍速档位（默认 1.0，均落在原生支持区间 0.25~4.0 内）。
const List<double> kPlaybackSpeeds = [
  0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
];

/// 长按视频画面时强制使用的倍速。
const double kLongPressSpeed = 2.0;

/// 播放页：进入即取流（DASH 双流 fnval=16，老视频降级 mp4 单流），
/// 原生 ExoPlayer MergingMediaSource 合并播放。
///
/// - 控制层：播放/暂停、进度条（500ms 轮询 getPosition）、当前/总时长、
///   倍速选择（九档 0.5~3x）、听视频（纯音频）开关、全屏切换；
///   点击画面切换控制层显隐，长按画面 2x、松手恢复长按前倍速；进入自动播放
/// - URL 过期（onUrlExpired）：重取 playurl → 记位置 → setDataSource(新流, 位置) 续播，
///   续播后按当前倍速/听视频状态恢复；重试 1 次仍失败显示「视频流过期，请重试」+ 重试按钮
/// - 错误分类：403 防盗链异常 / -412 风控（指数退避 1s→2s→4s 重试）/ 62002 稿件失效 /
///   -101 登录失效（引导去登录页）
/// - 登录过期提醒：SESSDATA 到期 < 7 天时顶部横幅提示重新登录
///
/// 听视频模式：只隐藏/显示画面（Offstage），不调 pause/play，音频持续播放；
/// 不做系统后台服务，App 退后台时 Flutter 进程存活即可继续出声。
class PlayerPage extends StatefulWidget {
  final WhitelistVideo video;

  const PlayerPage({super.key, required this.video});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final BiliApi _api = BiliApi();

  /// 翻译服务（副字幕「翻译（中文）」；配置在管理面板）。
  final TranslateApi _translateApi = TranslateApi();

  /// 离线缓存管理器（下载/已缓存状态/进度；监听两个 notifier 刷新 UI）。
  final DownloadManager _downloads = DownloadManager.instance;

  BiliDashPlayer? _player;
  int? _textureId;

  /// 播放器事件订阅（dispose 时 cancel）。
  StreamSubscription<BiliDashEvent>? _eventSub;

  // 播放状态
  bool _playing = false;
  bool _buffering = true;
  bool _loaded = false;
  bool _completed = false;
  int _positionMs = 0;
  int _durationMs = 0;
  double _aspectRatio = 16 / 9;

  // 控制层
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _dragging = false;

  // 倍速 / 长按 2x
  double _speed = 1.0;
  double _speedBeforeLongPress = 1.0;

  // 听视频（纯音频）模式：隐藏画面，音频继续
  bool _listenMode = false;

  // 字幕（M-字幕功能）
  // ---------------------------------------------------------------------
  // 面板打开时拉取轨道列表（登录态可能变化，每次进入重新拉）；
  // 选中轨道时下载对应 cues（按 bvid_cid_lan 内存缓存，见 BiliApi）。
  // 渲染只在 _tick（每 500ms）刷新，且仅文本变化时 setState。

  /// 字幕总开关（关掉则不渲染任何字幕）。
  bool _subtitleEnabled = false;

  /// 当前视频可用的字幕轨道列表（面板打开时拉取）。
  List<SubtitleTrack> _subtitleTracks = const [];

  /// 轨道拉取状态：加载中 / 错误文案（null=正常）。
  bool _subtitleLoading = false;
  String? _subtitleError;

  /// 主字幕轨道（null=无，即关闭主字幕）。
  SubtitleTrack? _mainSubtitleTrack;

  /// 副字幕轨道（null=无；不能与主字幕同轨）。
  SubtitleTrack? _secondarySubtitleTrack;

  /// 副字幕是否「翻译（中文）」模式：true 时副字幕显示主字幕内容的译文。
  ///
  /// 与 [_secondarySubtitleTrack] 互斥（选翻译则轨道置空，反之翻译关闭）。
  bool _secondaryIsTranslation = false;

  /// 主字幕译文列表（按 cue 顺序索引对应，译文[i] ↔ 第 i 条主字幕 cue）。
  List<String> _translationTexts = const [];

  /// 翻译状态：加载中（面板显示「翻译中 x/y」）/ 失败文案（null=正常）。
  bool _translationLoading = false;
  String? _translationError;
  int _translationDone = 0;
  int _translationTotal = 0;

  /// 已下载的字幕条目缓存（lan -> cues，页面级）。
  final Map<String, List<SubtitleCue>> _subtitleCues = {};

  // 本地转写（whisper）状态
  // ---------------------------------------------------------------------
  // 「🎙 转写字幕」：本地识别当前集音频生成字幕（缓存命中直接显示）。
  // _whisperCues 为当前集转写结果（缓存或新转写）；_mainIsWhisper 表示
  // 主字幕数据源=转写结果（此时渲染/翻译不再看 _mainSubtitleTrack）。
  final Transcriber _transcriber = Transcriber.instance;

  /// 当前集转写结果（null=未转写；缓存命中 / 转写完成后非空）。
  List<SubtitleCue>? _whisperCues;

  /// 主字幕数据源是否为「本地转写」（true 时走 _whisperCues）。
  bool _mainIsWhisper = false;

  /// 转写是否进行中（面板显示进度 + 取消按钮）。
  bool _whisperTranscribing = false;

  /// 整体转写进度 0~1（0~0.1 模型下载，0.1~1.0 转写推理）。
  final ValueNotifier<double> _whisperProgress = ValueNotifier(0);

  /// 最近一次转写错误文案（null=正常；面板红字提示，分类见各异常 message）。
  String? _whisperError;

  /// 转写运行令牌：每次 _startTranscribe 自增；完成/失败回调校验，防止
  /// 取消后再次开始的旧运行回写新状态。
  int _transcribeRun = 0;

  /// 字幕设置面板是否打开（转写完成后先关面板再弹 SnackBar，避免被遮挡）。
  bool _subtitleSheetOpen = false;

  /// 当前渲染的主/副字幕文本（仅文本变化时 setState）。
  String _mainSubtitleText = '';
  String _secondarySubtitleText = '';

  // 多 P 选集：_currentPageIndex 指向 pages 中的当前集
  // （无 pages 数据 → 单 P，不展示选集 UI）
  int _currentPageIndex = 0;

  /// pages 列表：空/缺失视为单 P（返回 null）。
  List<PageInfo>? get _pages {
    final pages = widget.video.pages;
    return (pages == null || pages.isEmpty) ? null : pages;
  }

  /// 当前集的 cid：多 P → pages[_currentPageIndex].cid；单 P → 顶层 cid。
  int get _currentCid {
    final pages = _pages;
    if (pages != null) return pages[_currentPageIndex].cid;
    return widget.video.cid;
  }

  /// 当前集的 part 标题（多 P 时用于 TopBar/占位界面展示）。
  String get _currentPartTitle {
    final pages = _pages;
    if (pages != null) return pages[_currentPageIndex].part;
    return widget.video.title;
  }

  // 错误 / 过期
  String? _error;
  bool _loginPrompt = false;
  bool _canRetry = true;
  int _expiredRetry = 0;

  String? _loginExpiryText;
  Timer? _timer;

  // 播放进度记忆（本地 shared_preferences，按 bvid+pageIndex 分别记忆）
  PlaybackProgress? _progressStore;

  /// 下一次 onPrepared 时是否恢复记忆进度：
  /// 首次进入 / 手动切集 / 手动重试后为 true（恢复对应集的进度）；
  /// URL 过期续播等自动换源不置 true（沿用续播位置，不被记忆覆盖）。
  bool _pendingRestore = true;

  /// 500ms tick 计数：每 20 次（=10s）定时保存一次进度（防杀进程丢失）。
  int _tickCount = 0;

  @override
  void initState() {
    super.initState();
    // 监听缓存状态变化（下载进度/完成/删除），驱动下载按钮与进度刷新
    _downloads.cached.addListener(_onCacheStateChanged);
    _downloads.tasks.addListener(_onCacheStateChanged);
    _checkLoginExpiry();
    _init();
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onCacheStateChanged);
    _downloads.tasks.removeListener(_onCacheStateChanged);
    // 退出前保存一次进度（fire-and-forget，防杀进程/直接返回丢失进度）。
    // 播放器尚未释放，getPosition 可用；看完（_completed）已清记忆，跳过。
    final store = _progressStore;
    final player = _player;
    if (store != null && player != null && !_completed) {
      player.getPosition().then((pos) {
        if (pos > 0) {
          store.saveProgress(widget.video.bvid, _currentPageIndex, pos);
        }
      }).catchError((Object _) {
        // 原生通道异常：忽略，进度最多丢一次
      });
    }
    _timer?.cancel();
    _eventSub?.cancel();
    _eventSub = null;
    _player?.dispose();
    _whisperProgress.dispose();
    _restoreSystemUi();
    super.dispose();
  }

  void _onCacheStateChanged() {
    if (mounted) setState(() {});
  }

  // -------------------------------------------------------------------------
  // 初始化 / 取流
  // -------------------------------------------------------------------------

  Future<void> _init() async {
    // 重进/重试：取消在途转写（转写状态随集/页重置，见 _switchToPage）
    _transcriber.cancel();
    setState(() {
      _error = null;
      _loginPrompt = false;
      _canRetry = true;
      _buffering = true;
      _loaded = false;
      _completed = false;
      // 重新初始化（重试/重进）→ 清空字幕状态，等下次面板打开/切集再拉
      _subtitleTracks = const [];
      _subtitleLoading = false;
      _subtitleError = null;
      _mainSubtitleTrack = null;
      _secondarySubtitleTrack = null;
      _secondaryIsTranslation = false;
      _translationTexts = const [];
      _translationLoading = false;
      _translationError = null;
      _translationDone = 0;
      _translationTotal = 0;
      _mainSubtitleText = '';
      _secondarySubtitleText = '';
      _subtitleCues.clear();
      // 转写状态：随页重置（缓存命中由 _loadWhisperCache 异步恢复）
      _whisperCues = null;
      _mainIsWhisper = false;
      _whisperTranscribing = false;
      _whisperError = null;
      _whisperProgress.value = 0;
      _transcribeRun++; // 作废旧转写的完成/失败回调
    });
    _loadWhisperCache();
    try {
      // 先加载缓存索引，保证「播放优先本地缓存」判定准确。
      // 带超时保护：测试环境无 path_provider 原生通道时 send 永不返回，
      // 不能让它阻塞播放初始化（超时则本次按未缓存走网络取流）。
      try {
        await _downloads
            .init()
            .timeout(const Duration(milliseconds: 500));
      } catch (_) {
        // 索引加载失败/超时：忽略，走网络取流
      }
      // 加载播放进度记忆存储（失败/超时则本次会话不记忆，不影响播放）。
      // 带超时保护：测试环境无 shared_preferences 原生通道时 send 永不返回，
      // 不能让它阻塞播放初始化（与上方 _downloads.init 同模式）。
      try {
        _progressStore = await PlaybackProgress.load()
            .timeout(const Duration(milliseconds: 500));
      } catch (_) {
        _progressStore = null;
      }
      final player = await BiliDashPlayer.create();
      _eventSub = player.events.listen(_onPlayerEvent, onError: (Object _, StackTrace __) {
        // 事件流中断（如播放器已释放）静默忽略，以错误态兜底
      });
      _player = player;
      if (!mounted) return;
      setState(() => _textureId = player.textureId);
      await _loadStreamAndPlay(positionMs: 0);
      _timer ??= Timer.periodic(
          const Duration(milliseconds: 500), (_) => _tick());
    } catch (e) {
      if (!mounted) return;
      await _handleLoadFailure(e);
    } finally {
      if (mounted) setState(() => _buffering = false);
    }
  }

  /// 取流并开始播放：**已缓存 → 直接播本地文件**（无网络、无 URL 过期问题）；
  /// 否则优先 DASH 双流（video+audio），无 dash 则 fnval=0 降级 mp4 单流。
  /// cid 取当前集 `_currentCid`（多 P 切换选集后为 pages[index].cid）。
  Future<void> _loadStreamAndPlay({required int positionMs}) async {
    final player = _player;
    if (player == null) return;
    // 本地缓存优先：命中则不请求网络流
    final cached =
        _downloads.getCached(widget.video.bvid, _currentPageIndex);
    if (cached != null) {
      debugPrint('[player_page] 本地缓存播放 video=${cached.videoPath} '
          'audio=${cached.audioPath}');
      await player.setDataSource(
        Uri.file(cached.videoPath).toString(),
        audioUrl: cached.audioPath.isEmpty
            ? null
            : Uri.file(cached.audioPath).toString(),
        positionMs: positionMs,
      );
      return;
    }
    debugPrint('[player_page] 取流 bvid=${widget.video.bvid} cid=$_currentCid');
    var result = await _api.fetchPlayUrl(
      bvid: widget.video.bvid,
      cid: _currentCid,
      qn: 80,
      fnval: 16, // DASH 双流（M2.1 实测定案：1080P 走路线 A）
    );
    // 老视频无 DASH → 重取 fnval=0 拿 durl[0].url（fnval=16 的响应里没有 durl）
    if (result.dashVideoUrls.isEmpty) {
      debugPrint('[player_page] fnval=16 无 DASH，降级 fnval=0');
      result = await _api.fetchPlayUrl(
        bvid: widget.video.bvid,
        cid: _currentCid,
        qn: 80,
        fnval: 0,
      );
    }
    if (!result.hasStream) {
      throw StateError('未拿到可播放的流（可能视频不可播放）');
    }
    if (result.dashVideoUrls.isNotEmpty) {
      await player.setDataSource(
        result.dashVideoUrls.first,
        audioUrl:
            result.dashAudioUrls.isEmpty ? null : result.dashAudioUrls.first,
        positionMs: positionMs,
      );
    } else {
      await player.setDataSource(result.mp4Url!, positionMs: positionMs);
    }
  }

  /// 取流失败分类处理。
  Future<void> _handleLoadFailure(Object e) async {
    // -412 风控：指数退避 1s→2s→4s 后重试（fetchPlayUrl 内部已刷新 WBI key 重试过一次）
    if (e is BiliApiException && e.code == -412) {
      for (final delay in const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
      ]) {
        await Future<void>.delayed(delay);
        if (!mounted) return;
        try {
          await _loadStreamAndPlay(positionMs: 0);
          if (mounted) setState(() => _buffering = false);
          return;
        } on BiliApiException catch (retryE) {
          if (retryE.code != -412) {
            _showFatal(retryE);
            return;
          }
        } catch (retryE) {
          _showFatal(retryE);
          return;
        }
      }
      _showFatal(e);
      return;
    }
    // -352 接口限流（v_voucher 软风控，playurl 返回 code=0+空流）：
    // 退避 3s→6s 重试两次（短时限流可自愈），仍失败给出明确提示。
    // 完全解除需过 B 站验证码，App 内无法自动化，只能靠等待/换网络。
    if (e is BiliApiException && e.code == -352) {
      for (final delay in const [
        Duration(seconds: 3),
        Duration(seconds: 6),
      ]) {
        await Future<void>.delayed(delay);
        if (!mounted) return;
        try {
          await _loadStreamAndPlay(positionMs: 0);
          if (mounted) setState(() => _buffering = false);
          return;
        } on BiliApiException catch (retryE) {
          if (retryE.code != -352) {
            _showFatal(retryE);
            return;
          }
        } catch (retryE) {
          _showFatal(retryE);
          return;
        }
      }
      _showFatal(e);
      return;
    }
    // 稿件失效：提示后返回
    if (e is BiliApiException && e.code == 62002) {
      _showFatal(e, canRetry: false);
      _schedulePop('稿件已失效（62002），即将返回列表');
      return;
    }
    // 登录失效：引导去登录页
    if (e is BiliApiException && e.code == -101) {
      setState(() {
        _error = '登录已失效，请重新登录';
        _loginPrompt = true;
      });
      return;
    }
    _showFatal(e);
  }

  void _schedulePop(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _showFatal(Object e, {bool canRetry = true}) {
    if (!mounted) return;
    setState(() {
      _error = _errMsg(e);
      _canRetry = canRetry;
    });
  }

  String _errMsg(Object e) {
    if (e is BiliApiException) return e.message;
    if (e is Exception && e.toString().contains('DioException')) {
      return e.toString().split('\n').first;
    }
    return '$e';
  }

  // -------------------------------------------------------------------------
  // 原生事件
  // -------------------------------------------------------------------------

  /// 事件流分发：按事件类型路由到对应处理方法。
  void _onPlayerEvent(BiliDashEvent e) {
    debugPrint('[player] event: ${e.runtimeType} textureId=${e.textureId}');
    if (!mounted) return;
    switch (e) {
      case BiliDashPreparedEvent(:final width, :final height, :final durationMs):
        _onPrepared(width, height, durationMs);
      case BiliDashCompletedEvent():
        _onCompleted();
      case BiliDashErrorEvent(:final code, :final message):
        _onNativeError(code, message);
      case BiliDashUrlExpiredEvent():
        _onUrlExpired();
    }
  }

  void _onPrepared(int width, int height, int durationMs) {
    debugPrint('[player] onPrepared ${width}x$height duration=$durationMs');
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _playing = true;
      _buffering = false;
      _completed = false;
      _durationMs = durationMs;
      if (width > 0 && height > 0) _aspectRatio = width / height;
    });
    // 首次进入 / 切集后恢复该集记忆进度（不打断自动播放）
    _maybeRestoreProgress(durationMs);
  }

  void _onCompleted() {
    if (!mounted) return;
    _timer?.cancel();
    setState(() {
      _playing = false;
      _positionMs = _durationMs;
      _completed = true;
    });
    // 观看完成 → 清除进度记忆（下次从头播）
    _clearProgress();
  }

  void _onNativeError(int code, String message) {
    debugPrint('[player] onNativeError code=$code msg=$message');
    if (!mounted) return;
    // 403 = 防盗链异常（流请求 Referer/UA 缺失或被拦）
    final msg = message.contains('403') ? '防盗链异常（403），请稍后重试' : message;
    setState(() {
      _error = '播放失败（$code）：$msg';
      _playing = false;
    });
  }

  /// 流 URL 过期续播：重取 playurl → 记当前位置 → setDataSource 续播。
  /// 已重试过 1 次仍失败 → 显示「视频流过期，请重试」。
  Future<void> _onUrlExpired() async {
    if (!mounted) return;
    if (_expiredRetry >= 1) {
      _showFatal('视频流过期，请重试');
      return;
    }
    _expiredRetry++;
    setState(() => _buffering = true);
    final position = await _player?.getPosition() ?? 0;
    try {
      await _loadStreamAndPlay(positionMs: position);
      // 续播成功：按当前倍速与听视频状态恢复（换源后原生倍速会被重置为 1x）
      await _player?.setPlaybackSpeed(_speed);
      if (mounted) setState(() => _buffering = false);
    } catch (e) {
      if (!mounted) return;
      _showFatal('视频流过期，请重试');
    }
  }

  // -------------------------------------------------------------------------
  // 控制动作
  // -------------------------------------------------------------------------

  Future<void> _tick() async {
    final player = _player;
    if (player == null || _dragging) return;
    final pos = await player.getPosition();
    if (mounted) setState(() => _positionMs = pos);
    if (mounted) _updateSubtitleText(pos);
    // 播放中每 20 次 tick（=10s）保存一次进度（防杀进程丢失）
    if (++_tickCount % 20 == 0) _saveProgress();
  }

  /// 当前主字幕数据源 cues：本地转写优先；否则 B 站主轨道下载结果。
  List<SubtitleCue>? _mainSubtitleCues() {
    if (_mainIsWhisper) return _whisperCues;
    final track = _mainSubtitleTrack;
    if (track == null) return null;
    return _subtitleCues[track.lan];
  }

  /// 按当前播放位置刷新主/副字幕文本（复用 _tick 的 500ms 轮询）。
  ///
  /// 性能：仅当主/副文本任一变化才 setState，避免每 tick 重建字幕层；
  /// 播放暂停时 getPosition 停在原地 → 字幕保持显示当前句。
  ///
  /// 副字幕三种来源：
  /// - 普通轨道：命中副轨 cue 的 content
  /// - 翻译模式：主字幕当前 cue 的 index → 译文[index]（译文与 cue 一一对应）；
  ///   翻译失败且无译文时显示「翻译失败」（小号，不阻塞播放）
  void _updateSubtitleText(int positionMs) {
    final mainCues = _mainSubtitleCues();
    final mainText = mainCues == null
        ? ''
        : currentCue(mainCues, positionMs.toDouble())?.content ?? '';
    var secText = '';
    if (_secondaryIsTranslation) {
      if (_translationError != null && _translationTexts.isEmpty) {
        secText = '翻译失败';
      } else if (_translationTexts.isNotEmpty && mainCues != null) {
        final idx = currentCueIndex(mainCues, positionMs.toDouble());
        if (idx != null && idx < _translationTexts.length) {
          secText = _translationTexts[idx];
        }
      }
    } else {
      final secTrack = _secondarySubtitleTrack;
      final secCues = secTrack == null ? null : _subtitleCues[secTrack.lan];
      secText = secCues == null
          ? ''
          : currentCue(secCues, positionMs.toDouble())?.content ?? '';
    }
    if (mainText != _mainSubtitleText ||
        secText != _secondarySubtitleText) {
      setState(() {
        _mainSubtitleText = mainText;
        _secondarySubtitleText = secText;
      });
    }
  }

  Future<void> _togglePlay() async {
    debugPrint('[player_page] _togglePlay called, playing=$_playing');
    final player = _player;
    if (player == null) return;
    if (_playing) {
      await player.pause();
      setState(() => _playing = false);
      _saveProgress(); // 暂停时保存一次进度
    } else {
      if (_positionMs >= _durationMs && _durationMs > 0) {
        await player.seekTo(0);
        setState(() {
          _positionMs = 0;
          _completed = false;
        });
      }
      await player.play();
      setState(() => _playing = true);
    }
  }

  // -------------------------------------------------------------------------
  // 快退 3 秒
  // -------------------------------------------------------------------------

  /// 快退 3 秒：当前播放位置 -3000ms（下限 0）。连点连续生效：
  /// 每次独立 getPosition → seekTo，原生 seek 完成后下一次取到新位置。
  Future<void> _rewind3s() async {
    debugPrint('[player_page] 快退 3 秒');
    final player = _player;
    if (player == null) return;
    final pos = await player.getPosition();
    final target = pos > 3000 ? pos - 3000 : 0;
    debugPrint('[player_page] seekTo ${target}ms (快退 3 秒，原 ${pos}ms)');
    await player.seekTo(target);
    if (mounted) setState(() => _positionMs = target);
    _saveProgress(); // 快退后保存，防快退丢失
  }

  // -------------------------------------------------------------------------
  // 播放进度记忆（保存 / 恢复 / 清除）
  // -------------------------------------------------------------------------

  /// 保存当前播放位置（跳过未开始/已完成）。
  Future<void> _saveProgress() async {
    final store = _progressStore;
    final player = _player;
    if (store == null || player == null || _completed) return;
    final pos = await player.getPosition();
    if (pos <= 0) return;
    await store.saveProgress(widget.video.bvid, _currentPageIndex, pos);
    debugPrint('[player_page] 保存进度 '
        '${widget.video.bvid}#$_currentPageIndex $pos ms');
  }

  /// 清除当前集进度记忆（观看完成 / 从头播放时）。
  Future<void> _clearProgress() async {
    final store = _progressStore;
    if (store == null) return;
    await store.clearProgress(widget.video.bvid, _currentPageIndex);
    debugPrint('[player_page] 清除进度 '
        '${widget.video.bvid}#$_currentPageIndex');
  }

  /// onPrepared 后尝试恢复记忆进度（仅首次进入 / 切集 / 手动重试后）：
  /// - 无记忆或 <=5s → 从头播，不打扰
  /// - 距结尾 <3s → 视为已看完，清除记忆后从头播
  /// - 其余 → seekTo(记忆位置)（不打断自动播放）+ SnackBar「从头播放」action
  Future<void> _maybeRestoreProgress(int durationMs) async {
    if (!_pendingRestore) return;
    _pendingRestore = false;
    final store = _progressStore;
    if (store == null) return;
    final saved = store.getProgress(widget.video.bvid, _currentPageIndex);
    if (saved == null || saved <= 5000) return;
    if (durationMs > 0 && saved >= durationMs - 3000) {
      await _clearProgress();
      return;
    }
    debugPrint('[player_page] 恢复进度 '
        '${widget.video.bvid}#$_currentPageIndex $saved ms');
    await _player?.seekTo(saved);
    if (!mounted) return;
    _showSnackWithAction(
      '已从上次 ${_fmtMs(saved)} 继续',
      actionLabel: '从头播放',
      onAction: _restartFromBeginning,
    );
  }

  /// SnackBar「从头播放」action：seekTo(0) + 清记忆，下次从头播。
  void _restartFromBeginning() {
    debugPrint('[player_page] 从头播放');
    _player?.seekTo(0);
    _clearProgress();
    if (mounted) {
      setState(() {
        _positionMs = 0;
        _completed = false;
      });
    }
  }

  void _onSeekStart(double v) {
    setState(() {
      _dragging = true;
      _positionMs = v.round();
    });
  }

  void _onSeekEnd(double v) {
    debugPrint('[player_page] seekTo ${v.round()}ms');
    setState(() {
      _dragging = false;
      _positionMs = v.round();
    });
    _player?.seekTo(v.round());
  }

  void _toggleControls() {
    debugPrint('[player_page] _toggleControls called, '
        'visible=$_controlsVisible -> ${!_controlsVisible}');
    setState(() => _controlsVisible = !_controlsVisible);
  }

  // -------------------------------------------------------------------------
  // 倍速 / 长按 2x / 听视频
  // -------------------------------------------------------------------------

  /// 应用倍速：更新 Dart 状态并通知原生播放器。
  Future<void> _applySpeed(double speed) async {
    debugPrint('[player_page] setPlaybackSpeed $speed');
    setState(() => _speed = speed);
    await _player?.setPlaybackSpeed(speed);
  }

  /// 长按开始：记下进入长按时倍速，立即切 2x（松手恢复的是这个值）。
  void _onLongPressStart(LongPressStartDetails _) {
    debugPrint('[player_page] longPress start, speedBefore=$_speed');
    _speedBeforeLongPress = _speed;
    _applySpeed(kLongPressSpeed);
  }

  /// 长按结束：恢复进入长按前的倍速（而非 1x）。
  void _onLongPressEnd(LongPressEndDetails _) {
    debugPrint('[player_page] longPress end, restore=$_speedBeforeLongPress');
    _applySpeed(_speedBeforeLongPress);
  }

  /// 弹出倍速选择（九档，当前档高亮）。
  ///
  /// 横屏/小屏可用高度很小，若用默认 BottomSheet（高度上限为屏高 9/16）+
  /// 不可滚动 Column，九档内容会被裁出屏幕（档位看不见、选不中）。
  /// 修复：isScrollControlled 放开高度 + constraints 限高 70% 屏高 +
  /// useSafeArea 处理横屏刘海/手势条 + Flexible+ListView 兜底滚动，
  /// 保证任意方向下弹窗完整可见、所有档位可滚动选中。
  Future<void> _showSpeedSheet() async {
    debugPrint('[player_page] show speed sheet, current=$_speed');
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF202023),
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 6),
              child: Text('播放速度',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            // Flexible + shrinkWrap：内容超过弹窗约束时在弹窗内滚动，
            // 与同文件 _showEpisodeSheet 的选集列表同一写法
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: kPlaybackSpeeds.length,
                itemBuilder: (context, i) {
                  final s = kPlaybackSpeeds[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      _fmtSpeed(s),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: s == _speed ? Colors.pinkAccent : Colors.white,
                        fontSize: 16,
                        fontWeight: s == _speed
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: s == _speed
                        ? const Icon(Icons.check,
                            color: Colors.pinkAccent, size: 20)
                        : const SizedBox(width: 20),
                    onTap: () => Navigator.of(context).pop(s),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) await _applySpeed(selected);
  }

  /// 听视频开关：只隐藏/显示画面，不打断播放（不调 pause/play）。
  void _toggleListenMode() {
    debugPrint('[player_page] toggle listenMode -> ${!_listenMode}');
    setState(() => _listenMode = !_listenMode);
  }

  // -------------------------------------------------------------------------
  // 字幕设置
  // -------------------------------------------------------------------------

  /// 拉取当前视频字幕轨道列表（进入面板时调用；[onChanged] 用于面板
  /// 内重试时同步刷新面板 UI，面板未开时传 null）。
  ///
  /// 错误分类（面板内展示错误文案 + 重试）：
  /// - -101 未登录/登录失效 → 提示重新登录（AI 字幕需登录态）
  /// - -352 限流 / 其他业务码 → 显示接口 message
  /// - 网络失败 → 显示网络错误
  Future<void> _loadSubtitleTracks({VoidCallback? onChanged}) async {
    _subtitleLoading = true;
    _subtitleError = null;
    onChanged?.call();
    try {
      final tracks =
          await _api.fetchSubtitles(widget.video.bvid, _currentCid);
      if (!mounted) return;
      _subtitleTracks = tracks;
      _subtitleLoading = false;
      onChanged?.call();
      debugPrint('[player_page] 字幕轨道 ${tracks.length} 条'
          '（${tracks.map((t) => t.lan).join(',')}）');
    } catch (e) {
      if (!mounted) return;
      _subtitleLoading = false;
      _subtitleError = _errMsg(e);
      onChanged?.call();
    }
  }

  /// 打开字幕设置面板：先拉取轨道列表，再弹 BottomSheet。
  Future<void> _showSubtitleSheet() async {
    debugPrint('[player_page] show subtitle sheet');
    _subtitleSheetOpen = true;
    await _loadSubtitleTracks();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202023),
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (sheetContext) => _buildSubtitleSheet(sheetContext),
    );
    _subtitleSheetOpen = false;
  }

  /// 字幕设置面板内容。
  ///
  /// StatefulBuilder 局部刷新：轨道选中/开关变化即时反映在面板上，
  /// 同时（可选）刷新 PlayerPage（字幕层/底部按钮高亮）。
  Widget _buildSubtitleSheet(BuildContext sheetContext) {
    return StatefulBuilder(
      builder: (sheetContext, sheetSetState) {
        void refreshBoth() {
          if (mounted) setState(() {});
          sheetSetState(() {});
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 14, bottom: 6),
                child: Text('字幕设置',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('显示字幕',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                value: _subtitleEnabled,
                onChanged: (v) {
                  _subtitleEnabled = v;
                  refreshBoth();
                },
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _buildSubtitleSheetBody(refreshBoth),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 字幕面板主体：加载中 / 错误 / 无字幕提示 / 主副轨道选择 + 翻译，
  /// 末尾恒挂「🎙 转写字幕」区块（无字幕视频也可本地转写，故不放行提前 return）。
  List<Widget> _buildSubtitleSheetBody(VoidCallback refresh) {
    final List<Widget> body;
    if (_subtitleLoading) {
      body = const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: CircularProgressIndicator(color: Colors.pinkAccent),
          ),
        ),
      ];
    } else if (_subtitleError != null) {
      body = [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_subtitleError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _loadSubtitleTracks(onChanged: refresh),
                style:
                    OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ];
    } else if (_subtitleTracks.isEmpty) {
      body = const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text('该视频无可用字幕（可尝试下方「转写字幕」本地识别）',
                style: TextStyle(color: Colors.white54, fontSize: 14)),
          ),
        ),
      ];
    } else {
      body = [
        _buildSubtitleTrackHeader('主字幕'),
        _buildSubtitleTrackTile(null, isMain: true, refresh: refresh),
        // 已转写 → 主字幕选择里多一个「本地转写」选项（不占 B 站轨道项）
        if (_whisperCues != null) _buildWhisperMainTile(refresh),
        for (final t in _subtitleTracks)
          _buildSubtitleTrackTile(t, isMain: true, refresh: refresh),
        _buildSubtitleTrackHeader('副字幕'),
        _buildSubtitleTrackTile(null, isMain: false, refresh: refresh),
        for (final t in _subtitleTracks)
          _buildSubtitleTrackTile(
            t,
            isMain: false,
            refresh: refresh,
            disabled: t.lan == _mainSubtitleTrack?.lan, // 不能与主字幕同轨
          ),
        // 翻译（中文）：恒显示；未配置翻译服务时点击提示去配置
        _buildTranslateTile(refresh),
        // 翻译进度/失败状态行（面板内可见「翻译中 x/y」）
        if (_translationLoading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.pinkAccent),
                ),
                const SizedBox(width: 8),
                Text('翻译中 $_translationDone/$_translationTotal',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          )
        else if (_translationTotal > 0 && _translationError == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Text('已翻译 $_translationDone/$_translationTotal 条',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
        if (_translationError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Text('翻译失败：$_translationError',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
      ];
    }
    return [...body, _buildTranscribeSection(refresh)];
  }

  /// 「🎙 转写字幕」区块：轨道列表/翻译下方。状态机：
  /// 转写中（进度+取消）→ 已转写（设为主字幕/重新转写）/ 未转写（主按钮）。
  Widget _buildTranscribeSection(VoidCallback refresh) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text('🎙 转写字幕',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        ..._buildTranscribeStates(refresh),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 转写区块状态内容：进度（转写中）/ 错误行 / 主按钮区。
  List<Widget> _buildTranscribeStates(VoidCallback refresh) {
    if (_whisperTranscribing) {
      return [
        // 进度：整体 0~1 → 模型下载（0~0.1）→ 转写（0.1~1），分阶段显示 %
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: ValueListenableBuilder<double>(
            valueListenable: _whisperProgress,
            builder: (context, p, _) {
              final phase = p < 0.1 ? '模型下载' : '转写';
              final pct = p < 0.1 ? p / 0.1 : (p - 0.1) / 0.9;
              return Text(
                '$phase ${(pct.clamp(0.0, 1.0) * 100).round()}%',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: ValueListenableBuilder<double>(
            valueListenable: _whisperProgress,
            builder: (context, p, _) => LinearProgressIndicator(
              value: p.clamp(0.0, 1.0).toDouble(),
              color: Colors.pinkAccent,
              backgroundColor: Colors.white12,
              minHeight: 3,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text('本地识别中，请保持播放页打开',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
              TextButton(
                onPressed: _cancelTranscribe,
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ];
    }
    // 非转写中：错误行（红字，分类文案由各异常 message 携带）+ 已转写/未转写
    final err = _whisperError;
    final done = _whisperCues != null && _whisperCues!.isNotEmpty;
    final isMain = _mainIsWhisper;
    return [
      if (err != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(err,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ),
      if (done)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Row(
            children: [
              const Icon(Icons.check_circle,
                  color: Colors.greenAccent, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '✅ 已转写（${_whisperCues!.length} 条）',
                  style: const TextStyle(
                      color: Colors.greenAccent, fontSize: 13),
                ),
              ),
              if (isMain)
                const Text('主字幕',
                    style:
                        TextStyle(color: Colors.pinkAccent, fontSize: 13))
              else
                TextButton(
                  onPressed: () {
                    _selectWhisperMain();
                    refresh();
                  },
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.pinkAccent),
                  child: const Text('设为字幕'),
                ),
              TextButton(
                onPressed: () => _retranscribe(refresh),
                style: TextButton.styleFrom(
                    foregroundColor: Colors.white70),
                child: const Text('重新转写'),
              ),
            ],
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FilledButton(
                onPressed: () => _startTranscribe(refresh),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.pinkAccent,
                  foregroundColor: Colors.black,
                ),
                child: const Text('🎙 转写字幕'),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('本地识别音频生成字幕（首次需下载模型 142MB）',
                    style:
                        TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ],
          ),
        ),
    ];
  }

  /// 主字幕选择里的「本地转写」选项（已转写才出现；选中即把转写结果设为主字幕）。
  Widget _buildWhisperMainTile(VoidCallback refresh) {
    final selected = _mainIsWhisper;
    return ListTile(
      dense: true,
      title: Text(
        '🎙 本地转写',
        style: TextStyle(
          color: selected ? Colors.pinkAccent : Colors.white,
          fontSize: 14,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: selected
          ? const Icon(Icons.check, color: Colors.pinkAccent, size: 18)
          : const SizedBox(width: 18),
      onTap: () {
        _selectWhisperMain();
        refresh();
      },
    );
  }

  Widget _buildSubtitleTrackHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(title,
          style: const TextStyle(color: Colors.white70, fontSize: 12)),
    );
  }

  /// 单条轨道选择行：选中打勾高亮；[disabled]（副轨与主轨同语种）置灰不可点。
  Widget _buildSubtitleTrackTile(
    SubtitleTrack? track, {
    required bool isMain,
    required VoidCallback refresh,
    bool disabled = false,
  }) {
    final isSelected = track == null
        ? (isMain
            ? (_mainSubtitleTrack == null && !_mainIsWhisper)
            : _secondarySubtitleTrack == null)
        : (isMain
            ? _mainSubtitleTrack?.lan == track.lan
            : _secondarySubtitleTrack?.lan == track.lan);
    return ListTile(
      dense: true,
      title: Text(
        track == null ? '无' : (track.lanDoc.isEmpty ? track.lan : track.lanDoc),
        style: TextStyle(
          color: disabled
              ? Colors.white24
              : isSelected
                  ? Colors.pinkAccent
                  : Colors.white,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check, color: Colors.pinkAccent, size: 18)
          : const SizedBox(width: 18),
      onTap: disabled
          ? null
          : () {
              if (isMain) {
                _selectMainSubtitle(track);
              } else {
                _selectSecondarySubtitle(track);
              }
              refresh();
            },
    );
  }

  /// 副字幕「🔤 翻译（中文）」选项行：选中即把主字幕内容翻译成中文显示。
  ///
  /// 恒显示；未配置翻译服务时点击提示去配置（不选中）。
  Widget _buildTranslateTile(VoidCallback refresh) {
    final isSelected = _secondaryIsTranslation;
    return ListTile(
      dense: true,
      title: Text(
        '🔤 翻译（中文）',
        style: TextStyle(
          color: isSelected ? Colors.pinkAccent : Colors.white,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check, color: Colors.pinkAccent, size: 18)
          : const SizedBox(width: 18),
      onTap: () {
        _selectTranslationMode();
        refresh();
      },
    );
  }

  /// 选择主字幕轨道：立即更新选中态 + 异步下载 cues；
  /// 副字幕若与主字幕同轨则自动清空（防止同轨双行）。
  /// 选 B 站轨道/「无」→ 主字幕退出「本地转写」模式（转写结果仍在面板可切回）。
  void _selectMainSubtitle(SubtitleTrack? track) {
    setState(() {
      _mainSubtitleTrack = track;
      _mainIsWhisper = false;
    });
    if (track != null &&
        _secondarySubtitleTrack != null &&
        _secondarySubtitleTrack!.lan == track.lan) {
      setState(() => _secondarySubtitleTrack = null);
    }
    _ensureSubtitleCues(track);
    // 翻译模式下切换主字幕 → 重新翻译新的主字幕内容
    if (_secondaryIsTranslation && track != null) {
      _runTranslation();
    }
  }

  /// 把主字幕设为「本地转写」结果（面板「设为字幕」/主字幕选择「本地转写」）。
  /// 转写结果作为主字幕数据源，不占用 B 站轨道项。
  void _selectWhisperMain() {
    if (_whisperCues == null || _whisperCues!.isEmpty) return;
    setState(() {
      _mainIsWhisper = true;
      _mainSubtitleTrack = null;
      _subtitleEnabled = true; // 直接显示转写字幕
    });
    // 翻译模式下主字幕源变化 → 重新翻译新的主字幕内容
    if (_secondaryIsTranslation) _runTranslation();
  }

  /// 选择副字幕轨道（面板侧已禁用与主字幕同轨的项）；
  /// 退出翻译模式（翻译与轨道互斥）。
  void _selectSecondarySubtitle(SubtitleTrack? track) {
    setState(() {
      _secondarySubtitleTrack = track;
      _secondaryIsTranslation = false;
      _translationError = null;
    });
    _ensureSubtitleCues(track);
  }

  /// 选中「翻译（中文）」：校验主字幕/翻译配置 → 启动翻译流程。
  ///
  /// - 未选主字幕（B 站轨道或本地转写都没有）→ 提示先选主字幕
  /// - 未配置翻译服务 → 提示去管理面板配置（不选中）
  /// - 已配置 → 副字幕切到翻译模式，_runTranslation 负责缓存/翻译/渲染
  Future<void> _selectTranslationMode() async {
    final mainTrack = _mainSubtitleTrack;
    final hasMain = mainTrack != null || _mainIsWhisper;
    if (!hasMain) {
      _showSnack('请先选择主字幕轨道（需翻译的原文轨道）');
      return;
    }
    final hasCfg = await _translateApi.hasConfig();
    if (!mounted) return;
    if (!hasCfg) {
      _showSnack('未配置翻译服务，请到管理面板配置');
      return;
    }
    setState(() {
      _secondarySubtitleTrack = null;
      _secondaryIsTranslation = true;
      _translationTexts = const [];
      _translationError = null;
    });
    await _runTranslation();
  }

  /// 执行翻译流程：加载主字幕 cues → 查本地缓存 → 无缓存则批量翻译（进度回显）。
  ///
  /// - 主字幕源支持两种：B 站轨道（按 bvid_cid_lan 缓存）与本地转写
  ///   （lan='whisper'，转写结果翻译缓存独立命名，重转写后条数变化自动失效）
  /// - 缓存命中（同源已翻译过）直接显示，不重复翻译
  /// - 翻译完成写缓存（切集/重进命中即显示）
  /// - 失败：面板/字幕层提示「翻译失败」+ SnackBar 具体错误（401 配置无效/网络）
  Future<void> _runTranslation() async {
    final mainTrack = _mainSubtitleTrack;
    final isWhisper = _mainIsWhisper;
    if (!isWhisper && mainTrack == null) return;
    setState(() {
      _translationLoading = true;
      _translationError = null;
      _translationDone = 0;
      _translationTotal = 0;
    });
    final cues = isWhisper
        ? _whisperCues
        : await _ensureSubtitleCuesFor(mainTrack!);
    if (!mounted) return;
    if (cues == null || cues.isEmpty) {
      setState(() {
        _translationLoading = false;
        _translationError = '主字幕内容为空，无法翻译';
      });
      _showSnack('主字幕内容为空，无法翻译');
      return;
    }
    final bvid = widget.video.bvid;
    final cid = _currentCid;
    final lan = isWhisper ? 'whisper' : mainTrack!.lan;

    // 1) 本地缓存命中：直接显示
    final cached = await _translateApi.getCachedTranslation(bvid, cid, lan);
    if (!mounted) return;
    if (cached != null && cached.length == cues.length) {
      setState(() {
        _translationTexts = cached;
        _translationLoading = false;
        _translationTotal = cues.length;
        _translationDone = cues.length;
      });
      debugPrint('[player_page] 翻译命中缓存 ${bvid}_${cid}_$lan');
      return;
    }

    // 2) 无缓存：批量翻译（进度 ValueNotifier 驱动面板「翻译中 x/y」）
    final texts = [for (final c in cues) c.content];
    setState(() {
      _translationTotal = texts.length;
      _translationDone = 0;
    });
    final progress = ValueNotifier<int>(0);
    progress.addListener(() {
      if (mounted && _translationLoading) {
        setState(() => _translationDone = progress.value);
      }
    });
    try {
      final result =
          await _translateApi.translateBatch(texts, progress: progress);
      if (!mounted) return;
      setState(() {
        _translationTexts = result;
        _translationLoading = false;
        _translationDone = result.length;
      });
      await _translateApi.saveTranslation(bvid, cid, lan, result);
    } catch (e) {
      if (!mounted) return;
      final msg = e is TranslateApiException ? e.message : '$e';
      setState(() {
        _translationLoading = false;
        _translationError = msg;
      });
      _showSnack('翻译失败：$msg');
    } finally {
      progress.dispose();
    }
  }

  /// 下载选中轨道字幕内容（内存缓存去重），完成后刷新字幕层。
  void _ensureSubtitleCues(SubtitleTrack? track) {
    if (track == null) return;
    if (_subtitleCues.containsKey(track.lan)) return;
    _api
        .downloadSubtitle(track,
            bvid: widget.video.bvid, cid: _currentCid)
        .then((cues) {
      if (!mounted) return;
      setState(() => _subtitleCues[track.lan] = cues);
    }).catchError((Object e) {
      if (!mounted) return;
      debugPrint('[player_page] 字幕下载失败 ${track.lan}: $e');
      _showSnack('字幕加载失败：${_shortErr(e)}');
    });
  }

  /// 等待指定轨道字幕下载完成（内存缓存命中直接返回；失败返回 null）。
  ///
  /// 与 [_ensureSubtitleCues]（fire-and-forget）不同，翻译流程需要先拿到
  /// cues 才能决定缓存/翻译，故 await 版并返回结果。
  Future<List<SubtitleCue>?> _ensureSubtitleCuesFor(SubtitleTrack track) async {
    final cached = _subtitleCues[track.lan];
    if (cached != null) return cached;
    try {
      final cues = await _api.downloadSubtitle(track,
          bvid: widget.video.bvid, cid: _currentCid);
      if (!mounted) return cues;
      setState(() => _subtitleCues[track.lan] = cues);
      return cues;
    } catch (e) {
      debugPrint('[player_page] 字幕下载失败 ${track.lan}: $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // 本地转写（whisper）：缓存检查 / 开始 / 取消 / 重新转写
  // -------------------------------------------------------------------------

  /// 当前集转写缓存检查：命中则直接加载（面板显示「已转写」，无需重新转写）。
  /// 无缓存/读取失败静默（面板显示「转写字幕」入口）。
  Future<void> _loadWhisperCache() async {
    final bvid = widget.video.bvid;
    final pageIndex = _currentPageIndex;
    try {
      final cached =
          await _transcriber.getCachedTranscription(bvid, pageIndex);
      if (!mounted || _currentPageIndex != pageIndex) return;
      if (cached != null && cached.isNotEmpty) {
        setState(() => _whisperCues = cached);
        debugPrint('[player_page] 转写缓存命中 $bvid#$pageIndex '
            '${cached.length} 条');
      }
    } catch (_) {
      // 缓存读取失败（存储异常等）：按未转写处理
    }
  }

  /// 开始转写当前集：模型 → 音频 → whisper → cues → 写缓存。
  /// 完成后主字幕自动设为转写结果、关闭面板并 SnackBar 提示。
  /// 错误分类展示：模型下载 / 音频 / 转写分别抛中文异常（见 [TranscribeException]
  /// 及 WhisperModelException / AudioSourceException 的 message）。
  Future<void> _startTranscribe(VoidCallback refresh) async {
    if (_whisperTranscribing) return;
    final run = ++_transcribeRun;
    final pageIndex = _currentPageIndex;
    setState(() {
      _whisperTranscribing = true;
      _whisperError = null;
      _whisperProgress.value = 0;
    });
    refresh();
    try {
      final cues = await _transcriber.transcribe(
        widget.video,
        pageIndex,
        onProgress: (p) => _whisperProgress.value = p,
      );
      if (!mounted ||
          run != _transcribeRun ||
          _currentPageIndex != pageIndex) {
        return; // 已切集/重进/重新开始：放弃本次结果（缓存已落盘，可复用）
      }
      setState(() {
        _whisperCues = cues;
        _whisperTranscribing = false;
        // 主字幕自动设为转写结果（无 B 站轨道选中时仅显示转写字幕）
        _mainIsWhisper = true;
        _mainSubtitleTrack = null;
        _subtitleEnabled = true;
      });
      // 先关面板再提示（SnackBar 不被 BottomSheet 遮挡）
      if (_subtitleSheetOpen) Navigator.of(context).pop();
      _showSnack('转写完成，已加载字幕');
      // 翻译模式下主字幕源变化 → 重新翻译新的主字幕内容
      if (_secondaryIsTranslation) _runTranslation();
    } catch (e) {
      if (!mounted ||
          run != _transcribeRun ||
          _currentPageIndex != pageIndex) {
        return;
      }
      // 错误分类：模型下载 / 音频 / 转写异常均带用户可读 message
      final msg = switch (e) {
        WhisperModelException(:final message) => message,
        AudioSourceException(:final message) => message,
        TranscribeException(:final message) => message,
        _ => '转写失败（$e）',
      };
      final cancelled = e is TranscribeException && e.message == '转写已取消';
      setState(() {
        _whisperTranscribing = false;
        _whisperError = cancelled ? '转写已取消' : msg;
      });
      if (!cancelled) _showSnack('转写失败：$msg');
    }
  }

  /// 取消当前转写（Transcriber 置取消标志，阶段边界生效；面板立即恢复按钮态，
  /// 真正的终止由 transcribe 抛「转写已取消」兜底，此时旧 run 令牌已作废）。
  void _cancelTranscribe() {
    _transcriber.cancel();
    setState(() {
      _whisperTranscribing = false;
      _whisperError = '转写已取消';
    });
  }

  /// 重新转写：清缓存（保证下次不命中旧结果）→ 重新开始。
  Future<void> _retranscribe(VoidCallback refresh) async {
    final pageIndex = _currentPageIndex;
    try {
      await _transcriber.clearTranscription(widget.video.bvid, pageIndex);
    } catch (_) {
      // 缓存清除失败：直接转写（写缓存会覆盖旧结果）
    }
    setState(() => _whisperCues = null);
    refresh();
    await _startTranscribe(refresh);
  }

  // -------------------------------------------------------------------------
  // 离线缓存：下载按钮 / 菜单 / 进度 / 删除
  // -------------------------------------------------------------------------

  /// 当前集缓存记录（无则 null）。
  CachedVideo? get _currentCached =>
      _downloads.getCached(widget.video.bvid, _currentPageIndex);

  /// 当前集下载任务（下载中/排队；无则 null）。
  DownloadTask? get _currentTask => _downloads.tasks.value[
      CachedVideo.keyOf(widget.video.bvid, _currentPageIndex)];

  /// 点击下载按钮：未缓存 → 下载菜单；已缓存 → 缓存操作菜单；下载中不响应。
  void _onDownloadTap() {
    final task = _currentTask;
    if (task != null &&
        (task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.downloading)) {
      return; // 下载中/排队：按钮只显示进度，不弹菜单
    }
    final cached = _currentCached;
    final partTitle = _currentPartTitle;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202023),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: Text(cached != null ? '缓存操作' : '离线下载',
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              subtitle: Text(
                partTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const Divider(height: 1),
            if (cached == null) ...[
              ListTile(
                leading:
                    const Icon(Icons.download_outlined, color: Colors.white),
                title: const Text('下载本集',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDownloadPage(_currentPageIndex);
                },
              ),
              if (widget.video.isMultiPage)
                ListTile(
                  leading: const Icon(Icons.download_done,
                      color: Colors.white),
                  title: Text('下载全部集（${widget.video.pageCount} 集）',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmDownloadAll();
                  },
                ),
            ] else ...[
              ListTile(
                leading: const Icon(Icons.refresh, color: Colors.white),
                title: const Text('重新下载',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDownloadPage(_currentPageIndex);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error),
                title: Text('删除缓存',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDeleteCache();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 确认下载本集（提示消耗流量）→ 入队。
  Future<void> _confirmDownloadPage(int pageIndex) async {
    final pages = _pages;
    final partTitle = pages != null && pageIndex < pages.length
        ? pages[pageIndex].part
        : _currentPartTitle;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('离线下载'),
        content: Text('将下载《${partTitle.isEmpty ? widget.video.title : partTitle}》'
            '到本地缓存（约需网络流量），之后可在无网时离线播放。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _startDownloadPage(pageIndex);
  }

  /// 确认下载全部 P（提示流量）→ 逐集入队。
  Future<void> _confirmDownloadAll() async {
    final n = widget.video.pageCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('离线下载'),
        content: Text('将依次下载全部 $n 集到本地缓存'
            '（${n > 1 ? '流量较大，' : ''}完成后可在无网时离线播放）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _startDownloadAll();
  }

  /// 启动单集下载（入队后立即返回；完成/失败用 SnackBar 反馈）。
  void _startDownloadPage(int pageIndex) {
    final future = _downloads.downloadVideo(widget.video, pageIndex);
    future.then((_) {
      final cached =
          _downloads.getCached(widget.video.bvid, pageIndex);
      if (mounted) {
        _showSnack('已缓存：${cached?.partTitle ?? '第 ${pageIndex + 1} 集'}');
      }
    }).catchError((Object e) {
      if (mounted) _showSnack('下载失败：${_shortErr(e)}');
    });
  }

  /// 启动全部 P 下载（逐集入队，内部串行执行）。
  void _startDownloadAll() {
    _downloads.downloadAllPages(widget.video).then((_) {
      if (mounted) _showSnack('全部 ${widget.video.pageCount} 集已缓存');
    }).catchError((Object e) {
      if (mounted) _showSnack('下载未完成：${_shortErr(e)}');
    });
  }

  /// 确认删除当前集缓存。
  Future<void> _confirmDeleteCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除缓存'),
        content: Text('确定删除《$_currentPartTitle》的本地缓存吗？'
            '删除后离线将无法播放本集。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.deleteCache(widget.video.bvid, _currentPageIndex);
    if (mounted) _showSnack('已删除缓存');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 带操作按钮的 SnackBar（进度恢复提示的「从头播放」action）。
  void _showSnackWithAction(
    String message, {
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        // 悬浮在底部控制行（进度条行 36 + 按钮行 44 = 80px）之上，
        // 避免「从头播放」action 与全屏按钮区域重叠误触
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(left: 16, right: 16, bottom: 80),
        action: SnackBarAction(label: actionLabel, onPressed: onAction),
      ));
  }

  /// 下载错误精简文案（去掉过长的类型/堆栈前缀）。
  String _shortErr(Object e) {
    final s = '$e';
    final idx = s.indexOf('\n');
    return (idx > 0 ? s.substring(0, idx) : s);
  }

  /// 底部下载控制按钮：未缓存「下载」/ 下载中进度环+百分比 / 已缓存「已缓存」。
  Widget _buildDownloadControl() {
    final task = _currentTask;
    final downloading = task != null &&
        (task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.downloading);
    final cached = _currentCached;
    final Widget icon;
    final String label;
    final Color color;
    if (downloading) {
      icon = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          value: task.progress,
          strokeWidth: 2,
          color: Colors.pinkAccent,
        ),
      );
      label = task.progress == null ? '下载中' : '${task.percent}%';
      color = Colors.pinkAccent;
    } else if (cached != null) {
      icon =
          const Icon(Icons.check_circle_outline, color: Colors.pinkAccent, size: 18);
      label = '已缓存';
      color = Colors.pinkAccent;
    } else {
      icon = const Icon(Icons.download_outlined, color: Colors.white, size: 18);
      label = '下载';
      color = Colors.white;
    }
    return InkWell(
      onTap: downloading ? null : _onDownloadTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 多 P 选集切换
  // -------------------------------------------------------------------------

  /// 切换选集：更新当前集 → 重新取流（position 从 0 开始）→
  /// 恢复倍速（换源后原生倍速被重置为 1x）；听视频状态为 Dart 状态自然保持。
  /// 取流失败按 _handleLoadFailure 分类提示（-412/62002/-101 等），不崩溃。
  Future<void> _switchToPage(int index) async {
    final pages = _pages;
    if (pages == null || index < 0 || index >= pages.length) return;
    if (index == _currentPageIndex) return;
    debugPrint('[player_page] switchToPage ${index + 1}/${pages.length} '
        'cid=${pages[index].cid} part=${pages[index].part}');
    _pendingRestore = true; // 切集后 onPrepared 恢复新集记忆进度
    // 切集：取消在途转写（转写状态随集重置，新集缓存由 _loadWhisperCache 恢复）
    _transcriber.cancel();
    setState(() {
      _currentPageIndex = index;
      _buffering = true;
      _loaded = false;
      _completed = false;
      _error = null;
      _positionMs = 0;
      _durationMs = 0;
      // 字幕：切集清空轨道/文本（新集字幕等下次打开面板重新拉取）
      _subtitleTracks = const [];
      _subtitleLoading = false;
      _subtitleError = null;
      _mainSubtitleTrack = null;
      _secondarySubtitleTrack = null;
      _secondaryIsTranslation = false;
      _translationTexts = const [];
      _translationLoading = false;
      _translationError = null;
      _translationDone = 0;
      _translationTotal = 0;
      _mainSubtitleText = '';
      _secondarySubtitleText = '';
      _subtitleCues.clear();
      // 转写状态：随集重置（缓存命中由 _loadWhisperCache 异步恢复）
      _whisperCues = null;
      _mainIsWhisper = false;
      _whisperTranscribing = false;
      _whisperError = null;
      _whisperProgress.value = 0;
      _transcribeRun++; // 作废旧转写的完成/失败回调
    });
    _loadWhisperCache();
    try {
      await _loadStreamAndPlay(positionMs: 0);
      await _player?.setPlaybackSpeed(_speed);
      if (mounted) setState(() => _buffering = false);
    } catch (e) {
      if (!mounted) return;
      await _handleLoadFailure(e);
    }
  }

  /// 弹出选集 BottomSheet：每行「序号 + part 标题 + 时长」，当前集高亮；
  /// 选中 → 关弹窗 → 切换选集重播。
  Future<void> _showEpisodeSheet() async {
    final pages = _pages;
    if (pages == null || pages.length < 2) return;
    debugPrint(
        '[player_page] show episode sheet, current=${_currentPageIndex + 1}');
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF202023),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 6),
              child: Text('选集',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
            // Flexible + shrinkWrap：分 P 较多时在弹窗约束内滚动
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: pages.length,
                itemBuilder: (context, i) {
                  final p = pages[i];
                  final isCurrent = i == _currentPageIndex;
                  final TextStyle titleStyle = TextStyle(
                    color: isCurrent ? Colors.pinkAccent : Colors.white,
                    fontSize: 15,
                    fontWeight:
                        isCurrent ? FontWeight.bold : FontWeight.normal,
                  );
                  return ListTile(
                    dense: true,
                    leading: Text('${i + 1}', style: titleStyle),
                    title: Text(
                      p.part.isEmpty ? '第 ${i + 1} 集' : p.part,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_fmtPageDuration(p.duration),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 13)),
                        const SizedBox(width: 8),
                        if (isCurrent)
                          const Icon(Icons.check,
                              color: Colors.pinkAccent, size: 18)
                        else
                          const SizedBox(width: 18),
                      ],
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(i),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) await _switchToPage(selected);
  }

  /// 分 P 时长：秒 → `03:33` / `1:02:03`（<=0 显示 --:--）。
  String _fmtPageDuration(int seconds) {
    if (seconds <= 0) return '--:--';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '${m.toString().padLeft(2, '0')}:$ss';
  }

  /// 倍速档位文案：整数显示 `1x`，小数显示 `1.5x` / `0.75x`。
  String _fmtSpeed(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}x';
    final t = s.toString();
    return '${t.endsWith('0') ? t.substring(0, t.length - 1) : t}x';
  }

  Future<void> _toggleFullscreen() async {
    debugPrint('[player_page] _toggleFullscreen called, full=$_fullscreen');
    final full = !_fullscreen;
    setState(() => _fullscreen = full);
    if (full) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _restoreSystemUi() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _retry() {
    _expiredRetry = 0;
    _eventSub?.cancel();
    _eventSub = null;
    final old = _player;
    _player = null;
    _textureId = null;
    old?.dispose();
    _pendingRestore = true; // 手动重试视为重新进入：onPrepared 恢复记忆进度
    _init();
  }

  Future<void> _goLogin() async {
    setState(() => _loginPrompt = false);
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()));
    if (mounted) _retry();
  }

  // -------------------------------------------------------------------------
  // 登录过期检测（C. 简单版：SESSDATA 内嵌过期时间戳）
  // -------------------------------------------------------------------------

  Future<void> _checkLoginExpiry() async {
    try {
      final raw = await _api.readSessdata();
      if (raw == null || raw.isEmpty) return;
      final decoded = Uri.decodeComponent(raw);
      final parts = decoded.split(',');
      if (parts.length < 2) return; // 解析失败就不管
      final ts = int.tryParse(parts[1]);
      if (ts == null) return;
      final expire = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final remain = expire.difference(DateTime.now());
      if (remain < const Duration(days: 7)) {
        if (!mounted) return;
        final text = remain.isNegative
            ? '登录已过期，请重新登录'
            : '登录将过期（${_fmtDateTime(expire)}），请重新登录';
        setState(() => _loginExpiryText = text);
      }
    } catch (_) {
      // 解析失败静默忽略（TODO：M3c 补 refresh_token 自动续期全流程）
    }
  }

  String _fmtDateTime(DateTime t) =>
      '${t.month}月${t.day}日${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 播放画面（保持宽高比居中，黑色铺底；听视频模式下隐藏但播放不中断）
          if (_textureId != null)
            Offstage(
              offstage: _listenMode,
              child: Center(
                child: AspectRatio(
                  aspectRatio: _aspectRatio,
                  child: BiliDashTexture(textureId: _textureId!),
                ),
              ),
            ),
          // 2. 听视频占位界面（封面 + 标题 + 提示，点按恢复画面）
          if (_listenMode) _buildListenPlaceholder(),
          // 2.5 字幕层：Texture 之上、控制层之下（听视频模式隐藏）。
          // 底部控制行约 80px（进度条行 36 + 按钮行 44），字幕悬浮在其上方。
          // 主字幕大号在上，副字幕小号在其下（见 _SubtitleOverlay）。
          // 字幕相对屏幕底部定位，但固定 bottom 值在全屏横屏下会跑偏：
          // 竖屏逻辑高 914，bottom:100 使字幕落在 86% 处（控制行上方，正常）；
          // 全屏横屏逻辑高仅 411，同样 bottom:100 会把字幕顶到画面中部（复现 bounds
          // [982,736][1690,807]，屏幕高 1080）。故全屏时按控制层显隐取值：
          // 控制层显示→抬升到控制行上方（110）；控制层隐藏（沉浸观影）→贴画面底部（24）。
          if (!_listenMode &&
              _subtitleEnabled &&
              (_mainSubtitleText.isNotEmpty ||
                  _secondarySubtitleText.isNotEmpty))
            Positioned(
              left: 24,
              right: 24,
              bottom: _fullscreen ? (_controlsVisible ? 110.0 : 24.0) : 100.0,
              child: _SubtitleOverlay(
                mainText: _mainSubtitleText,
                secondaryText: _secondarySubtitleText,
              ),
            ),
          // 3. 登录过期横幅
          if (_loginExpiryText != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _LoginExpiryBanner(
                text: _loginExpiryText!,
                onTap: _goLogin,
              ),
            ),
          // 4. 点击画面切换控制层显隐 + 长按 2x（onTap 与 onLongPress 可共存；
          //    长按赢得手势后 onTap 自动取消，不会误触切换）
          //    听视频模式下让位给占位层（其自己处理点按恢复画面 + 长按 2x），
          //    否则本 opaque 层会拦截占位层的点击。
          if (!_listenMode)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onLongPressStart: _player == null ? null : _onLongPressStart,
                onLongPressEnd: _player == null ? null : _onLongPressEnd,
              ),
            ),
          // 5. 控制层（置于点击层之上）
          if (_controlsVisible || !_loaded) _buildControls(),
          // 6. 缓冲指示
          if (_buffering)
            const Center(
                child: CircularProgressIndicator(color: Colors.white)),
          // 7. 错误视图
          if (_error != null) _buildErrorView(),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Stack(
      children: [
        _buildTopBar(),
        Center(child: _buildCenterControls()),
        Align(alignment: Alignment.bottomCenter, child: _buildBottomBar()),
      ],
    );
  }

  /// 听视频占位界面：封面 + 标题 + 提示。点按恢复画面；长按同样支持 2x。
  Widget _buildListenPlaceholder() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleListenMode,
        onLongPressStart: _player == null ? null : _onLongPressStart,
        onLongPressEnd: _player == null ? null : _onLongPressEnd,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.video.cover.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      widget.video.cover,
                      width: 200,
                      height: 113,
                      fit: BoxFit.cover,
                      headers: {
                        'User-Agent': kBrowserUA,
                        'Referer': kBiliReferer,
                      },
                      errorBuilder: (_, __, ___) => Container(
                        width: 200,
                        height: 113,
                        color: Colors.white10,
                        child: const Icon(Icons.broken_image_outlined,
                            color: Colors.white54, size: 32),
                      ),
                    ),
                  )
                else
                  const Icon(Icons.headphones,
                      color: Colors.white70, size: 56),
                const SizedBox(height: 16),
                const Icon(Icons.headphones, color: Colors.white70, size: 32),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    widget.video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('听视频中 · 点按恢复画面',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 中心控制：快退 3 秒（左）+ 播放/暂停大按钮（中）+ 对称占位（右）。
  /// 固定大小 IconButton，位于点击层之上不会被手势层吞；横竖屏均居中不遮挡。
  Widget _buildCenterControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_completed)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('播放完成',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 快退 3 秒：Icons.replay 转圈箭头，tooltip 提示；连点连续生效
            IconButton(
              tooltip: '快退 3 秒',
              iconSize: 40,
              color: Colors.white,
              icon: const Icon(Icons.replay),
              onPressed: _player == null ? null : _rewind3s,
            ),
            IconButton(
              iconSize: 72,
              color: Colors.white,
              icon: Icon(
                  _playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
              onPressed: _player == null ? null : _togglePlay,
            ),
            // 右侧同宽占位，保持播放/暂停按钮视觉居中
            const SizedBox(width: 48),
          ],
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () {
                debugPrint('[player_page] back tapped');
                Navigator.of(context).pop();
              },
            ),
            Expanded(
              child: Text(
                widget.video.isMultiPage
                    ? '${widget.video.title} · $_currentPartTitle'
                    : widget.video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final sliderEnabled = _durationMs > 0;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      // 固定高度：Slider 在「有界高度」约束下会撑满整个高度
      // （_RenderSlider 布局取 constraints.maxHeight），不固定会盖满全屏
      // 并吞掉中心播放/暂停与返回按钮的点击，且进度条漂到屏幕中部。
      // 两行结构：进度条行 + 按钮行（倍速/听视频/全屏），横竖屏均可用。
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  Text(_fmtMs(_positionMs),
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: sliderEnabled
                          ? _positionMs.clamp(0, _durationMs).toDouble()
                          : 0,
                      max: sliderEnabled ? _durationMs.toDouble() : 1,
                      activeColor: Colors.white,
                      inactiveColor: Colors.white24,
                      onChanged: sliderEnabled ? _onSeekStart : null,
                      onChangeEnd: sliderEnabled ? _onSeekEnd : null,
                    ),
                  ),
                  Text(_fmtMs(_durationMs),
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  // 选集按钮：仅多 P 显示（当前集 1/N），点按弹出选集列表
                  if (widget.video.isMultiPage)
                    Expanded(
                      child: InkWell(
                        onTap: _player == null ? null : _showEpisodeSheet,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.queue_music,
                                color: Colors.white, size: 18),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '选集 ${_currentPageIndex + 1}/${widget.video.pageCount}',
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // 倍速按钮：显示当前档位，点按弹出九档选择
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _showSpeedSheet,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.speed,
                              color: Colors.white, size: 18),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _fmtSpeed(_speed),
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 听视频按钮：图标 + 状态反馈（开启时高亮）
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _toggleListenMode,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _listenMode
                                ? Icons.headset
                                : Icons.headset_off,
                            color: _listenMode
                                ? Colors.pinkAccent
                                : Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _listenMode ? '听视频中' : '听视频',
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _listenMode
                                    ? Colors.pinkAccent
                                    : Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 字幕按钮：图标 + 状态反馈（开启时高亮），点按弹出字幕设置
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _showSubtitleSheet,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _subtitleEnabled
                                ? Icons.subtitles
                                : Icons.subtitles_off,
                            color: _subtitleEnabled
                                ? Colors.pinkAccent
                                : Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _subtitleEnabled ? '字幕中' : '字幕',
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _subtitleEnabled
                                    ? Colors.pinkAccent
                                    : Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 下载按钮：未缓存「下载」/ 下载中进度环+百分比 / 已缓存「已缓存」
                  Expanded(child: _buildDownloadControl()),
                  // 全屏按钮
                  Expanded(
                    child: IconButton(
                      color: Colors.white,
                      icon: Icon(
                          _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                      onPressed: _toggleFullscreen,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 20),
              if (_loginPrompt) ...[
                FilledButton(
                  onPressed: _goLogin,
                  child: const Text('去登录'),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_canRetry) ...[
                    OutlinedButton(
                      onPressed: _retry,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white),
                      child: const Text('重试'),
                    ),
                    const SizedBox(width: 12),
                  ],
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white),
                    child: const Text('返回'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 登录即将过期横幅（点按跳登录页）。
class _LoginExpiryBanner extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _LoginExpiryBanner({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF7A5C00),
      child: InkWell(
        onTap: onTap,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 字幕叠加层：主字幕（大号）在上，副字幕（小号）在其下，居中可换行。
class _SubtitleOverlay extends StatelessWidget {
  final String mainText;
  final String secondaryText;

  const _SubtitleOverlay({required this.mainText, required this.secondaryText});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mainText.isNotEmpty)
          _SubtitleLine(text: mainText, fontSize: 19),
        if (secondaryText.isNotEmpty) ...[
          const SizedBox(height: 5),
          _SubtitleLine(text: secondaryText, fontSize: 13),
        ],
      ],
    );
  }
}

/// 单行字幕：半透明圆角底 + 白字 + 黑色阴影描边（清晰可读）。
class _SubtitleLine extends StatelessWidget {
  final String text;
  final double fontSize;

  const _SubtitleLine({required this.text, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          // 黑色阴影描边：无底时也保证字幕可读
          shadows: const [
            Shadow(offset: Offset(0, 1), blurRadius: 2, color: Colors.black),
            Shadow(offset: Offset(0, -1), blurRadius: 2, color: Colors.black),
            Shadow(offset: Offset(1, 0), blurRadius: 2, color: Colors.black),
            Shadow(offset: Offset(-1, 0), blurRadius: 2, color: Colors.black),
          ],
        ),
      ),
    );
  }
}

/// 毫秒 → `12:34` / `1:02:03`。
String _fmtMs(int ms) {
  final s = ms < 0 ? 0 : ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}
