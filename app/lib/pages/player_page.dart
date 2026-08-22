import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/bilibili_api.dart';
import '../cache/download_manager.dart';
import '../config.dart';
import '../models/whitelist_video.dart';
import '../player/bili_dash_player.dart';
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
    _timer?.cancel();
    _eventSub?.cancel();
    _eventSub = null;
    _player?.dispose();
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
    setState(() {
      _error = null;
      _loginPrompt = false;
      _canRetry = true;
      _buffering = true;
      _loaded = false;
      _completed = false;
    });
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
  }

  void _onCompleted() {
    if (!mounted) return;
    _timer?.cancel();
    setState(() {
      _playing = false;
      _positionMs = _durationMs;
      _completed = true;
    });
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
  }

  Future<void> _togglePlay() async {
    debugPrint('[player_page] _togglePlay called, playing=$_playing');
    final player = _player;
    if (player == null) return;
    if (_playing) {
      await player.pause();
      setState(() => _playing = false);
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
    setState(() {
      _currentPageIndex = index;
      _buffering = true;
      _loaded = false;
      _completed = false;
      _error = null;
      _positionMs = 0;
      _durationMs = 0;
    });
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

  /// 中心播放/暂停大按钮（播放完成时上方附带提示文案）。
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
        IconButton(
          iconSize: 72,
          color: Colors.white,
          icon: Icon(
              _playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
          onPressed: _player == null ? null : _togglePlay,
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
