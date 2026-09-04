import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/bilibili_api.dart';
import '../api/sherpa_model.dart';
import '../api/translate_api.dart';
import '../cache/download_manager.dart';
import '../cache/playback_progress.dart';
import '../config.dart';
import '../models/danmaku.dart';
import '../models/danmaku_settings.dart';
import '../models/subtitle.dart';
import '../models/whitelist_video.dart';
import '../player/bili_dash_player.dart';
import '../services/danmaku_settings_store.dart';
import '../services/device_media.dart';
import '../services/history_store.dart';
import '../services/realtime_transcriber.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_sheet.dart';
import 'comment_page.dart';
import 'login_page.dart';

/// 可选的播放倍速档位（默认 1.0，均落在原生支持区间 0.25~4.0 内）。
const List<double> kPlaybackSpeeds = [
  0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
];

/// 长按视频画面时强制使用的倍速。
const double kLongPressSpeed = 2.0;

// -------------------------------------------------------------------------
// 会员集播放回退决策（纯函数，便于单测）
//
// 背景：番剧每集有真实 bvid/cid；会员集经普通 `x/player/wbi/playurl`
// 实测返回 -404（非稿件失效），需回退 pgc 端点 `pgc/player/web/playurl`
// 取流（匿名只给试看流，完整播放需登录态 + 大会员）。
// -------------------------------------------------------------------------

/// pgc 回退取流后的播放动作。
enum PgcFallbackAction {
  /// 拿到非试看完整流 → 交给播放器正常播放。
  play,

  /// 只拿到试看流（会员集未解锁，仅前几分钟）→ 提示并停止（不播试看防误导）。
  trialOnly,

  /// 取流失败（抛异常）→ 提示登录大会员后观看。
  failed,
}

/// 普通 playurl 取流失败 → 是否应回退 pgc 端点（纯函数）。
///
/// - 有 [epId]（番剧集，v2.16.4+ 导入写入）且失败码是会员集特征
///   （-404 实测 / -10403 无权限）→ 回退
/// - 无 epId（普通视频 / 旧版导入的番剧数据）→ 不回退，走原有提示
bool shouldFallbackToPgc({required int? epId, required Object error}) {
  if (epId == null) return false;
  return error is BiliApiException &&
      (error.code == -404 || error.code == -10403);
}

/// pgc 回退取流结果 → 播放动作（纯函数）。
///
/// 决策：拿到非试看流 → [PgcFallbackAction.play]；拿到试看流
/// （[PgcPlayUrlResult.isPreview]=true）→ [PgcFallbackAction.trialOnly]；
/// 抛异常 → [PgcFallbackAction.failed]。
PgcFallbackAction pgcFallbackAction({
  PgcPlayUrlResult? result,
  Object? error,
}) {
  if (result != null) {
    return result.isPreview ? PgcFallbackAction.trialOnly : PgcFallbackAction.play;
  }
  return PgcFallbackAction.failed;
}

/// 会员集各回退动作对应的用户文案（纯函数）。
String pgcFallbackMessage(PgcFallbackAction action) {
  switch (action) {
    case PgcFallbackAction.trialOnly:
      return '该集为大会员内容，当前为试看（仅前几分钟），请登录大会员账号完整观看';
    case PgcFallbackAction.failed:
      return '该集为大会员/付费内容，请登录大会员账号后观看';
    case PgcFallbackAction.play:
      return '';
  }
}

// -------------------------------------------------------------------------
// B 站式播放快捷手势（v2.16.7+）纯函数（便于单测）
//
// 手势总览（参照 B 站手机端播放器；冲突处理见 build 中手势层注释）：
// - 双击：播放 / 暂停（与单击显隐共存，单击延迟 ~300ms 等双击判定）
// - 滑动统一走 Pan + 主导方向判定（v2.16.9+）：斜向滑动按**位移主方向**
//   归类——水平主导 → 全屏横屏 seek（位移/屏宽 = 时长比例，松手 seekTo）；
//   垂直主导 → 起点左半屏亮度 / 右半屏音量（原生通道 bili_whitelist/media，
//   见 services/device_media.dart）。竖屏只保留亮度/音量（水平主导忽略，
//   无 seek 防误触）。
// - 手势起点豁免带（v2.16.14+）：起点 y0 落在屏幕底部（或顶部）豁免带内
//   的 Pan 整体忽略（不 seek / 不调亮度音量）——横屏全屏从屏幕下方滑动
//   唤醒系统导航不再误触发 seek，让给系统手势；参数与判定见
//   [isExcludedGestureStart]。
//
// 滑动量换算统一走 [slideFraction]：滑满一屏 = ±100%（比例），
// 方向约定：向右 / 向上为「前进 / 增大」。
//
// 亮度/音量纵向调节的灵敏度（v2.16.12+）：完整上下滑一屏 ≈ 基准 ±30%
// （灵敏度 [kAdjustSensitivity] = 0.3，见 [adjustPercent]），小幅滑动
// 平滑小幅变化——不再像 v2.16.7~11 那样「滑满一屏 = ±100%、基准被逐帧
// 累加改写」，表现为手指动一点点就跳 0 / 100。
// -------------------------------------------------------------------------

/// 手势提示浮层的类型（也即竖屏半屏判定可产生的目标）。
enum PlayerSlideKind {
  /// 横屏 seek（浮层显示 当前进度 / 总时长）。
  seek,

  /// 亮度（竖屏左半屏纵向滑动）。
  brightness,

  /// 音量（竖屏右半屏纵向滑动）。
  volume,
}

/// 滑动手势的主导方向（判定锁定后本次手势不再切换，防中途抖动）。
enum PanSlideMode {
  /// 水平主导 → seek（仅全屏横屏激活；竖屏忽略）。
  horizontal,

  /// 垂直主导 → 起点左半屏亮度 / 右半屏音量。
  vertical,
}

/// 主导方向判定的位移阈值（px）：dx/dy 都未超此值视为未开始滑动
/// （点按抖动 / 微移不触发任何手势），超过才按主导分量归类。
const double kPanModeThreshold = 12;

// 手势起点豁免带（v2.16.14+）
// ---------------------------------------------------------------------------
// 背景（用户实测反馈）：横屏全屏（immersiveSticky）时想从屏幕**底部**滑动
// 唤醒 Android 三键导航 / 手势导航，App 手势层与系统手势区同时收到触摸——
// 旧版单一 Pan 覆盖整屏，这次从屏幕下方发起的左右滑被当成 seek（进度被拖走、
// hud 乱跳）。而系统导航条在几何屏幕底部，底部这一带本来就不该属于播放手势。
// 方案：Pan 起点 y0 落在**底部豁免带**内 → 本次 Pan 整体忽略（不 seek、
// 不调亮度/音量、不出 hud），把这段屏幕让给系统手势；顶部同样留窄带
// （横屏刘海 / 状态栏下拉区，防从屏幕最上缘启动的滑动误触发 seek）。
// 竖屏/横屏统一适用：竖屏底部带内让给系统（从底部启动的纵向亮度/音量调节
// 本来就可能被系统「上滑唤导航」手势抢占/截断，豁免后中部启动的调节不受
// 影响，更安全）。豁免只作用于 Pan 滑动本身——tap / 双击 / 长按不走 Pan
// 竞技场（tap 无位移不触发 Pan），底部带内单击显隐等照常。
// ---------------------------------------------------------------------------

/// 底部豁免带 = 屏高 × [kBottomGestureExclusionFactor]，且**不低于**
/// [kBottomGestureExclusionMinPx]。取值权衡：横屏屏高 ~400dp 时 8% ≈ 32px，
/// 低于系统导航条 / 手势排除区（3-button 导航条 ~48px、手势导航上滑触发区
/// 24~48px）——用「比例 or 固定 48px 取较大者」保证窄边（横屏）也够宽；
/// 竖屏 8% ≈ 屏高 73px 更大。宁宽勿窄（带内仅损失从带内启动的滑动，seek/
/// 调节都改从中部启动），但整体 < 屏高 15%，不挤压中部正常操作区。
const double kBottomGestureExclusionFactor = 0.08;

/// 底部豁免带的最小绝对宽度（px，见 [kBottomGestureExclusionFactor]）。
const double kBottomGestureExclusionMinPx = 48;

/// 顶部豁免带（px，固定窄带）：状态栏 / 刘海下拉区。
const double kTopGestureExclusionPx = 24;

/// 手势起点是否落在豁免带内（纯函数，v2.16.14+，可单测）：
/// - y0 ≥ 底部带上缘：height - max(height × [bottomFactor], [bottomMinPx])
///   → 底部带内（让给系统导航手势）
/// - y0 ≤ [topPx] → 顶部带内（状态栏 / 刘海区）
/// 高度异常（≤ 0，防御）→ false（不豁免，退化为旧行为）。
bool isExcludedGestureStart({
  required double y0,
  required double height,
  double bottomFactor = kBottomGestureExclusionFactor,
  double bottomMinPx = kBottomGestureExclusionMinPx,
  double topPx = kTopGestureExclusionPx,
}) {
  if (height <= 0) return false;
  final bottomPx = math.max(height * bottomFactor, bottomMinPx);
  return y0 >= height - bottomPx || y0 <= topPx;
}

/// 亮度 / 音量纵向调节的灵敏度（v2.16.12+）：`调节量 = 基准 + 滑动比例 ×
/// 灵敏度 × 100`——完整上下滑一屏（比例 ±1）≈ 基准 ±30%，小幅滑动平滑
/// 小幅变化。旧版按 ±100% 映射 + 基准被逐帧改写，导致手指动一点点就
/// 跳 0 / 100；0.3 让满行程只跨 30%，细调不再越界。
const double kAdjustSensitivity = 0.3;

/// 竖屏半屏判定：滑动起点 x ≤ 屏宽一半 → 亮度，否则 → 音量。
PlayerSlideKind verticalSlideKind(double x, double width) =>
    x <= width / 2 ? PlayerSlideKind.brightness : PlayerSlideKind.volume;

/// 主导方向判定（纯函数，v2.16.9+）：斜向位移按**主导分量**归类——
/// - dx/dy 都未超 [threshold] → null（未定，继续累计）
/// - |dx| >= |dy| → [PanSlideMode.horizontal]（45° 平分归水平，与 |dx|
///   不落后于 |dy| 的语义一致）
/// - |dy| > |dx| → [PanSlideMode.vertical]
/// 方向符号（正负）只表示左右 / 上下，不影响归类。
PanSlideMode? decideMode(
  double dx,
  double dy, [
  double threshold = kPanModeThreshold,
]) {
  final ax = dx.abs();
  final ay = dy.abs();
  if (ax <= threshold && ay <= threshold) return null;
  return ax >= ay ? PanSlideMode.horizontal : PanSlideMode.vertical;
}

/// 手势方向锁定（纯函数）：已有模式时**不受后续位移影响**（原样返回，
/// 本次手势不切换）；未锁定才交给 [decideMode] 判定。
PanSlideMode? nextPanMode({
  required PanSlideMode? current,
  required double dx,
  required double dy,
  double threshold = kPanModeThreshold,
}) {
  if (current != null) return current;
  return decideMode(dx, dy, threshold);
}

/// 位移 → 滑动比例：delta / span，钳制 -1..1（拖满一屏 = ±100%）。
/// span <= 0（测试 / 极端布局）按 0 处理，避免除零。
double slideFraction(double delta, double span) {
  if (span <= 0) return 0;
  final f = delta / span;
  return f < -1 ? -1 : (f > 1 ? 1 : f);
}

/// seek 目标位置：基准进度 + 滑动比例 × 视频时长（钳制 0..时长）。
/// 无时长（未加载 / 时长未知）→ 0（此时不应发起 seek，纯防御）。
/// 方向：向右滑（正比例）= 前进，与进度条拖动方向一致。
int seekTargetMs({
  required int baseMs,
  required double fraction,
  required int durationMs,
}) {
  if (durationMs <= 0) return 0;
  var target = baseMs + (fraction * durationMs).round();
  if (target < 0) target = 0;
  if (target > durationMs) target = durationMs;
  return target;
}

/// 音量目标档位：基准档 + 滑动比例 × 灵敏度 × 最大档（钳制 0..max）。
/// 灵敏度默认 [kAdjustSensitivity]（0.3）——完整上下滑一屏 = ±30% 最大档，
/// 与百分比口径的 [adjustPercent] 一致（0.3 × max 档）。
/// 最大档 <= 0（无音量设备 / 防御）→ 0。
int volumeTargetLevel({
  required int baseLevel,
  required double fraction,
  required int maxLevel,
  double sensitivity = kAdjustSensitivity,
}) {
  if (maxLevel <= 0) return 0;
  final delta = fraction * sensitivity * maxLevel;
  // 档位差向远离 0 取整（±x.5 边界向上取），并加 ε 修正消除 0.3 × max 的
  // 二进制误差在 x.5 边界随机向下取整的问题（满屏 ±30% 常落在 ±4.5 档，
  // 裸 round 会让结果在 4/5 之间摇摆）。
  final d = delta >= 0
      ? (delta + 0.5 + 1e-9).floor()
      : (delta - 0.5 - 1e-9).ceil();
  final t = baseLevel + d;
  return t < 0 ? 0 : (t > maxLevel ? maxLevel : t);
}

/// 纵向调节当前百分比（0..100，v2.16.12+）：基准百分比 + 滑动比例 ×
/// 灵敏度 × 100（钳制）。灵敏度默认 [kAdjustSensitivity]（0.3）——
/// 完整上下滑一屏（fraction=±1）≈ 基准 ±30%，小幅滑动平滑小幅变化
/// （如滑 1/10 屏 → ±3%），不再「滑满一屏 = ±100%」一碰就到头。
double adjustPercent({
  required double basePercent,
  required double fraction,
  double sensitivity = kAdjustSensitivity,
}) {
  final v = basePercent + fraction * sensitivity * 100;
  return v < 0 ? 0 : (v > 100 ? 100 : v);
}

/// 亮度百分比（带下限 5%）：全黑时手势浮层与画面同窗口会不可见、误以为
/// 失效——下限与原生侧 MediaController 一致。
double brightnessPercent({
  required double basePercent,
  required double fraction,
}) {
  final v = adjustPercent(basePercent: basePercent, fraction: fraction);
  return v < 5 ? 5 : v;
}

/// 播放页：进入即取流（DASH 双流 fnval=16，老视频降级 mp4 单流），
/// 原生 ExoPlayer MergingMediaSource 合并播放。
///
/// - 控制层：播放/暂停、进度条（500ms 轮询 getPosition）、当前/总时长、
///   倍速选择（九档 0.5~3x）、听视频（纯音频）开关、全屏切换；
///   点击画面切换控制层显隐，长按画面 2x、松手恢复长按前倍速；进入自动播放；
///   B 站式快捷手势（v2.16.7+）：双击播放/暂停（单击显隐延迟 ~300ms 防误触）、
///   滑动按**主导方向**归类（v2.16.9+）：水平主导 → 全屏横屏 seek（时间浮层 +
///   松手 seekTo）；垂直主导 → 按起点左/右半屏调亮度/音量（原生通道
///   bili_whitelist/media，仅当前 Activity 内生效）。竖屏只保留亮度/音量
///   （水平主导忽略，无 seek 防误触）。v2.16.14+：Pan 起点落在屏幕底部/
///   顶部豁免带（[isExcludedGestureStart]）→ 本次 Pan 整体忽略（不 seek /
///   不调亮度音量）——横屏全屏从屏幕下方滑动唤醒系统导航不再误触发 seek
/// - URL 过期（onUrlExpired）：重取 playurl → 记位置 → setDataSource(新流, 位置) 续播，
///   续播后按当前倍速/听视频状态恢复；重试 1 次仍失败显示「视频流过期，请重试」+ 重试按钮
/// - 错误分类：403 防盗链异常 / -412 风控（指数退避 1s→2s→4s 重试）/ 62002 稿件失效 /
///   -101 登录失效（引导去登录页）
/// - 会员集播放（v2.16.4+）：番剧导入的视频带 epId，播放时**先走普通 playurl**（免费集
///   更清晰），会员集普通接口返回 -404 → **自动回退 pgc 端点**（fetchPgcPlayUrl）：
///   拿到非试看完整流直接播；匿名只有试看流时**不播试看**，提示「大会员内容请登录
///   大会员账号完整观看」并引导登录（防误导）；无 epId 的旧数据保持原 -404 友好提示
/// - 登录过期提醒：SESSDATA 到期 < 7 天时顶部横幅提示重新登录
///
/// 听视频模式：只隐藏/显示画面（Offstage），不调 pause/play，音频持续播放；
/// 不做系统后台服务，App 退后台时 Flutter 进程存活即可继续出声。
class PlayerPage extends StatefulWidget {
  final WhitelistVideo video;

  /// 初始播放的分 P 下标（历史记录续播用：直接定位到上次看的那一集；
  /// 默认 0 = 第一集/单 P）。
  final int initialPageIndex;

  const PlayerPage({
    super.key,
    required this.video,
    this.initialPageIndex = 0,
  });

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

  // B 站式快捷手势（v2.16.7+）
  // -------------------------------------------------------------------
  // 双击播放/暂停：GestureDetector onDoubleTap；单击显隐因与双击共存自动
  // 延迟 ~300ms（等双击窗口判定，双击赢得则单击取消，不误触显隐）。
  // 滑动统一走单一 Pan（v2.16.9+）：位移累计超 [kPanModeThreshold] 按主导
  // 方向锁定（[decideMode]）——horizontal → 全屏横屏 seek、竖屏忽略；
  // vertical → 起点半屏亮度/音量（横竖屏都可用）。锁定后本次手势不再切换
  // （防中途抖动）；seek 拖动中暂停 tick 位置刷新（松手 seek 后恢复）。
  double _panStartX = 0; // 手势起点 x（垂直模式按半屏判亮度/音量）
  bool _panExcluded = false; // 起点在豁免带（v2.16.14+）→ 本次 Pan 整体忽略
  PanSlideMode? _panMode; // 已锁定的主导方向（null = 未定，继续累计判定）
  double _panDx = 0; // 手势累计横向位移（px，仅锁定判定用）
  double _panDy = 0; // 手势累计纵向位移（px，仅锁定判定用）
  bool _seekDragging = false; // 横屏 seek 拖动中（锁定 horizontal 后）
  int _seekDragBaseMs = 0; // seek 起点基准位置（拖动开始时）
  double _seekDragDx = 0; // 累计横向位移（px，向右为正）
  double _seekDragSpan = 1; // 拖满一屏对应的屏宽（px）
  // 纵向调节（亮度/音量）：起点半屏定类型，滑动量按屏高换算比例。
  PlayerSlideKind? _adjustKind; // 纵向调节类型（null = 未进行）
  bool _adjustReady = false; // 基准值已从原生取到（取到前忽略滑动）
  // v2.16.12+：基准在锁定后**固定不再改写**（旧版逐帧把基准改成目标值 +
  // ±100% 映射 → 换算双重叠加，手指动一点点就近 0/100）。目标始终按
  // 「固定基准 + 累计比例 × 灵敏度 0.3」计算，只追平一次、可回退。
  double _adjustBase = 0; // 手势锁定时读到的原始基准：音量=当前档/亮度=百分比
  double _adjustApplied = 0; // 最近一次已生效目标（音量=档位/亮度=百分比，
                              // 只用于写通道与浮层的阈值过滤，不是换算基准）
  double _adjustSpan = 1; // 纵向拖满一屏对应的屏高（px）
  double _adjustDy = 0; // 累计纵向位移（px，向下为正）
  int _volumeMax = 0; // 音量最大档（本次手势开始时取）
  // 手势提示浮层（hud）：seek 时间 / 亮度 / 音量
  PlayerSlideKind? _hudKind;
  double _hudValue = 0; // 亮度/音量百分比（0..100；seek 类型不用）
  int _hudSeekPosMs = 0; // seek 当前目标位置（仅 seek 类型）
  Timer? _hudTimer; // 浮层自动消失计时（手势结束后延迟隐藏）

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

  // 实时转写（sherpa 流式）状态
  // ---------------------------------------------------------------------
  // 「边播边出实时字幕」：主字幕=原文句子、副字幕=逐句译文。
  // 状态直接监听全局单例 RealtimeTranscriber 的 ValueNotifier：
  // 面板（ValueListenableBuilder）与字幕层（stage 监听）各自刷新。
  final RealtimeTranscriber _realtime = RealtimeTranscriber.instance;

  /// 实时转写结果是否为当前主字幕数据源：
  /// stage=transcribing/done 时为 true（主字幕=原文、副字幕=译文，按播放位置
  /// 从 sentences 取当前句）；停止/切集/重进后置 false（字幕回退到轨道）。
  bool _realtimeAsSubtitle = false;

  /// 模型目录提示路径（面板「手动放置模型」指引；异步取，取不到显示通用文案）。
  String _realtimeModelDir = '';

  /// 当前渲染的主/副字幕文本（仅文本变化时 setState）。
  String _mainSubtitleText = '';
  String _secondarySubtitleText = '';

  // 多 P 选集：_currentPageIndex 指向 pages 中的当前集
  // （无 pages 数据 → 单 P，不展示选集 UI）
  int _currentPageIndex = 0;

  // 弹幕（播放页弹幕层，v2.16.3+ → v2.16.6+ 屏蔽/透明度 → v2.16.13+
  // 显示区域/设置记忆）
  // ---------------------------------------------------------------------
  // 开关默认关；开启时按当前集 cid 拉取弹幕 XML（fetchDanmaku，失败静默
  // 返回空不阻塞播放）→ 交给 DanmakuOverlay 随时间发射渲染。
  // 渲染层只在「开关开 && 有数据」时构建，关闭无任何开销。
  // 弹幕设置（屏蔽词/屏蔽类型/透明度/显示区域/开关状态）：进页异步加载本地
  // 持久化值（开关记忆上次开 → 本次自动开并自动拉弹幕）；改动经
  // _showDanmakuSettings / _toggleDanmaku 回写 state（overlay 收到新
  // settings 实例即时重载生效）并保存。

  /// 弹幕总开关（默认关；开启才拉取并显示）。v2.16.13 起由持久化设置
  /// 的 enabled 字段初始化/保存（见 _loadDanmakuSettings/_toggleDanmaku）。
  bool _danmakuEnabled = false;

  /// 弹幕显示设置（屏蔽词/类型/透明度/显示区域/开关；overlay 渲染与发射
  /// 过滤用）。
  DanmakuSettings _danmakuSettings = const DanmakuSettings();

  /// 当前集（cid）的全量弹幕（按 timeSec 升序）；切集/关闭时清空。
  List<Danmaku> _danmaku = const [];

  /// 弹幕缓存（cid → 全量列表）：切集后同 cid 再开秒显示，不重复请求。
  final Map<int, List<Danmaku>> _danmakuCache = {};

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
    // 历史记录续播：初始定位到对应分 P（越界 / 单 P 回落第 0 集）。
    // 必须在 _init 之前设置，_maybeRestoreProgress 按 _currentPageIndex 取进度。
    final pages = widget.video.pages;
    final maxIdx = (pages == null || pages.isEmpty) ? 0 : pages.length - 1;
    _currentPageIndex = widget.initialPageIndex < 0
        ? 0
        : (widget.initialPageIndex > maxIdx ? maxIdx : widget.initialPageIndex);
    // 监听缓存状态变化（下载进度/完成/删除），驱动下载按钮与进度刷新
    _downloads.cached.addListener(_onCacheStateChanged);
    _downloads.tasks.addListener(_onCacheStateChanged);
    // 实时转写（sherpa）：stage 变化决定「是否作为字幕源」，句子/译文更新
    // 时按播放位置刷新字幕文本；面板用 ValueListenableBuilder 自行刷新。
    _realtime.stage.addListener(_onRealtimeStageChanged);
    _realtime.sentences.addListener(_onRealtimeSentencesChanged);
    _realtimeModelDirHint();
    _loadDanmakuSettings();
    _checkLoginExpiry();
    _init();
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onCacheStateChanged);
    _downloads.tasks.removeListener(_onCacheStateChanged);
    _realtime.stage.removeListener(_onRealtimeStageChanged);
    _realtime.sentences.removeListener(_onRealtimeSentencesChanged);
    // 退出播放页：停止实时转写（标志位在块边界生效，不打断引擎单步）
    _realtime.stop();
    // 退出前保存一次进度 + 写入历史（fire-and-forget，防杀进程/直接返回
    // 丢失进度）。播放器尚未释放，getPosition 可用；看完（_completed）
    // 已清记忆，跳过进度保存（历史仍记录「看过」，位置=结尾无妨）。
    final store = _progressStore;
    final player = _player;
    if (player != null) {
      player.getPosition().then((pos) {
        if (pos > 0) {
          if (store != null && !_completed) {
            store.saveProgress(widget.video.bvid, _currentPageIndex, pos);
          }
          unawaited(_writeHistory(pos));
        }
      }).catchError((Object _) {
        // 原生通道异常：忽略，进度最多丢一次
      });
    }
    _timer?.cancel();
    _hudTimer?.cancel();
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
  // 实时转写（sherpa）：监听回调 + 辅助
  // -------------------------------------------------------------------------

  /// stage 变化：transcribing/done → 实时转写作为字幕源（自动开字幕）；
  /// 其余（idle/error/modelDownload/audioPrep）→ 不占字幕源。
  void _onRealtimeStageChanged() {
    if (!mounted) return;
    setState(() {
      _realtimeAsSubtitle = _realtime.stage.value == RtStage.transcribing ||
          _realtime.stage.value == RtStage.done;
      if (_realtimeAsSubtitle) _subtitleEnabled = true;
    });
    // 切换数据源后立即按播放位置刷新一次字幕文本
    _updateSubtitleText(_positionMs);
  }

  /// 句子列表/译文更新（新句进列表、译文异步返回）：刷新当前句字幕。
  void _onRealtimeSentencesChanged() {
    if (!mounted) return;
    _updateSubtitleText(_positionMs);
  }

  /// 异步取模型目录路径（面板「手动放置模型」指引用；取不到回退通用文案）。
  Future<void> _realtimeModelDirHint() async {
    try {
      final dir = await SherpaModelManager.instance.targetModelDir();
      if (mounted) setState(() => _realtimeModelDir = dir);
    } catch (_) {
      // 原生通道异常（测试环境等）：面板回退通用文案
    }
  }

  /// 停止 + 清除实时转写状态（切集/重进/重试时调用；句子按集隔离）。
  void _resetRealtime() {
    _realtime.stop();
    _realtime.clear();
    _realtimeAsSubtitle = false;
  }

  // -------------------------------------------------------------------------
  // 初始化 / 取流
  // -------------------------------------------------------------------------

  Future<void> _init() async {
    // 实时转写（sherpa）随页重置：停止 + 清句子/partial/错误
    _resetRealtime();
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
    final epId = widget.video.epId; // 番剧集 ep_id（普通视频/旧番剧数据 = null）
    debugPrint(
        '[player_page] 取流 bvid=${widget.video.bvid} cid=$_currentCid epId=$epId');
    try {
      // 1) 普通 playurl（WBI）：普通视频/免费番剧集走这里（免费集普通接口
      //    720P 比 pgc 端点的更清晰，优先）
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
        // 普通接口空流（番剧会员集可能不给流直接空响应）：
        // 带 epId → 回退 pgc 端点；普通视频 → 保持原样报错
        if (epId == null) {
          throw StateError('未拿到可播放的流（可能视频不可播放）');
        }
        debugPrint('[player_page] 普通 playurl 空流 epId=$epId → 回退 pgc');
        await _playPgcFallback(epId, positionMs);
        return;
      }
      await _playStream(result, positionMs: positionMs);
    } on BiliApiException catch (e) {
      // 2) 普通 playurl -404（番剧会员集实测特征）且带 epId → 回退 pgc 端点；
      //    无 epId（普通视频/旧番剧数据）→ 原样上抛走 _handleLoadFailure 提示
      if (shouldFallbackToPgc(epId: epId, error: e)) {
        debugPrint(
            '[player_page] 普通 playurl 失败 code=${e.code} epId=$epId → 回退 pgc');
        // shouldFallbackToPgc 已保证 epId 非空（catch 作用域内无法做类型提升）
        await _playPgcFallback(epId!, positionMs);
        return;
      }
      rethrow;
    }
  }

  /// 把解析好的流交给播放器播放（dash 双流 / mp4 单流）。
  ///
  /// [result] 须 [PlayUrlResult.hasStream] 为真（调用方保证）。
  Future<void> _playStream(PlayUrlResult result,
      {required int positionMs}) async {
    final player = _player;
    if (player == null) return;
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

  /// 番剧集回退 pgc 端点取流（普通 playurl -404/空流后调用）。
  ///
  /// 决策纯函数 [pgcFallbackAction]/[pgcFallbackMessage]（可单测）：
  /// - 拿到非试看完整流 → 正常播放
  /// - 试看流（会员集未解锁，仅前几分钟）→ **不播试看**，提示大会员并停止
  ///   （避免"能播但只有几分钟"的误导）；引导去登录（登录大会员后回来可解锁）
  /// - 取流抛异常 → -412/-352 风控/限流按可重试提示；其余（-10403 无权限/
  ///   网络失败等）提示登录大会员账号后观看
  Future<void> _playPgcFallback(int epId, int positionMs) async {
    PgcPlayUrlResult? result;
    Object? error;
    try {
      result = await _api.fetchPgcPlayUrl(epId);
    } catch (e) {
      error = e;
      debugPrint('[player_page] pgc 回退取流失败 epId=$epId error=$e');
    }
    final action = pgcFallbackAction(result: result, error: error);
    if (action == PgcFallbackAction.play) {
      final r = result!;
      debugPrint('[player_page] pgc 完整流 epId=$epId '
          'dash=${r.dashVideoUrls.length} mp4=${r.mp4Url != null} → 播放');
      if (!r.hasStream) {
        // 完整标记但无流（极端场景，如接口给空 dash/durl）：不播放，明示
        if (!mounted) return;
        setState(() {
          _error = '该集未返回可播放的流（可能需大会员/付费）';
          _canRetry = false;
        });
        return;
      }
      await _playStream(r, positionMs: positionMs);
      return;
    }
    final msg = pgcFallbackMessage(action);
    if (!mounted) return;
    // 风控/限流（-412/-352）不是权限问题：保留可重试、不引导登录；
    // 试看/无权限失败 → 提示大会员 + 引导去登录（登录大会员后重进可解锁）
    final err = error;
    final isRisk = err is BiliApiException &&
        (err.code == -412 || err.code == -352);
    setState(() {
      _error = isRisk ? _errMsg(err) : msg;
      _canRetry = isRisk;
      _loginPrompt = !isRisk;
    });
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
    // -404：普通 playurl 对番剧会员/付费集返回 -404（v2.16.4+ 带 epId 的
    // 番剧集已在 _loadStreamAndPlay 内回退 pgc 端点，不会走到这里）；能走到
    // 此分支的只有**无 epId** 的视频（普通视频该码 = 稿件被删/下架；旧版导入
    // 的番剧数据没有 epId 无法回退）。统一友好提示、不可重试。
    if (e is BiliApiException && e.code == -404) {
      setState(() {
        _error = '该集可能为大会员/付费内容或已下架';
        _canRetry = false;
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
    if (player == null || _dragging || _seekDragging) return;
    final pos = await player.getPosition();
    if (mounted) setState(() => _positionMs = pos);
    if (mounted) _updateSubtitleText(pos);
    // 播放中每 20 次 tick（=10s）保存一次进度（防杀进程丢失）
    if (++_tickCount % 20 == 0) _saveProgress();
  }

  /// 当前主字幕数据源 cues：B 站主轨道下载结果。
  List<SubtitleCue>? _mainSubtitleCues() {
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
    // 实时转写（sherpa）：主字幕=当前播放位置命中的原文句子、副字幕=其译文。
    // 句子时间轴=当前集音频时间轴，与播放位置一一对应（见 RealtimeTranscriber）。
    if (_realtimeAsSubtitle) {
      final s = _currentRealtimeSentence(positionMs);
      final mainText = s?.text ?? '';
      final secText = s?.translation ?? '';
      if (mainText != _mainSubtitleText ||
          secText != _secondarySubtitleText) {
        setState(() {
          _mainSubtitleText = mainText;
          _secondarySubtitleText = secText;
        });
      }
      return;
    }
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

  /// 实时转写句子中命中当前播放位置的一句（`fromTs <= pos/1000 <= toTs`，
  /// 同刻多条取最后一条，规则同 [currentCue]）；无命中返回 null。
  RealtimeSentence? _currentRealtimeSentence(int positionMs) {
    final list = _realtime.sentences.value;
    if (list.isEmpty) return null;
    final pos = positionMs / 1000;
    RealtimeSentence? hit;
    for (final s in list) {
      if (s.fromTs <= pos && pos <= s.toTs) hit = s;
    }
    return hit;
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
  // 快退 / 快进 3 秒（对称）
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

  /// 快进 3 秒：当前播放位置 +3000ms（上限视频时长 _durationMs）。
  /// 连点连续生效：每次独立 getPosition → seekTo，原生 seek 完成后下一次
  /// 取到新位置；到结尾不越界（clamp 到时长）。
  Future<void> _forward3s() async {
    debugPrint('[player_page] 快进 3 秒');
    final player = _player;
    if (player == null) return;
    final pos = await player.getPosition();
    final max = _durationMs > 0 ? _durationMs : pos + 3000;
    final target = pos + 3000 < max ? pos + 3000 : max;
    debugPrint('[player_page] seekTo ${target}ms (快进 3 秒，原 ${pos}ms)');
    await player.seekTo(target);
    if (mounted) setState(() => _positionMs = target);
    _saveProgress(); // 快进后保存，防快进丢失
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
    // 与进度保存同节奏写历史（_tick 每 10s / 暂停 / 快进快退 / dispose 触发）
    await _writeHistory(pos);
  }

  /// 写入播放历史：记录当前视频信息 + 进度 + 观看时间。
  /// 与进度保存同节奏（见 [_saveProgress]），失败静默不影响播放。
  Future<void> _writeHistory(int positionMs) async {
    try {
      await HistoryStore.instance.addOrUpdate(
        HistoryEntry(
          bvid: widget.video.bvid,
          pageIndex: _currentPageIndex,
          cid: _currentCid,
          title: widget.video.title,
          cover: widget.video.cover,
          upName: widget.video.upName,
          durationMs: _durationMs > 0
              ? _durationMs
              : widget.video.duration * 1000,
          positionMs: positionMs,
          watchedAt: DateTime.now(),
          pages: widget.video.pages,
        ),
      );
    } catch (_) {
      // 历史写入失败静默（不阻塞播放/退出）
    }
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
  // B 站式快捷手势（v2.16.7+）：双击 / 滑动主导方向判定（v2.16.9+）
  //
  // 判定与冲突处理汇总（详见 build 手势层注释）：
  // - 双击 = 播放/暂停；单击 = 显隐（延迟 ~300ms 等双击窗口判定）
  // - 滑动统一走单一 Pan：位移累计超 [kPanModeThreshold] 后按主导方向锁定
  //   （[decideMode]），锁定后本次手势不再切换——
  //   水平主导：全屏横屏 = seek（位移比例 = 时长比例，松手 seekTo）；
  //             竖屏忽略（v2.16.9 之前即无横屏滑动，防误触）
  //   垂直主导：亮度（起点左半屏）/ 音量（右半屏），横竖屏都可用；
  //             原生通道调节（device_media.dart），调节即生效、松手不恢复
  // - 控制层按钮 / 进度条在 Stack 上层，其区域内的点击与拖动天然优先
  // -------------------------------------------------------------------------

  /// 双击 → 播放 / 暂停。单击显隐因双击共存自动延迟，双击赢得手势时
  /// 延迟的单击会取消 → 双击不会误触显隐。
  Future<void> _onDoubleTap() async {
    debugPrint('[player_page] doubleTap → 播放/暂停');
    await _togglePlay();
  }

  // ---------- 滑动统一 Pan：起点记录 → 主导方向锁定 → 分发 ----------

  /// 手势开始：记录起点（x0 供垂直模式半屏判亮度/音量），状态复位为未定，
  /// 清掉上一手势残留 hud（延迟隐藏计时同步取消）。
  /// 豁免带判定（v2.16.14+）：起点 y0 落在底部/顶部豁免带 → [_panExcluded]
  /// = true，本次 Pan 整体忽略（update/end/cancel 早退，不 seek/不调亮度
  /// 音量/不出 hud）——横屏全屏从屏幕下方滑动唤醒系统导航不再误触发 seek。
  /// tap / 双击 / 长按不走 Pan 竞技场（tap 无位移不触发 Pan），不受影响。
  void _onPanStart(DragStartDetails d) {
    if (_player == null) return;
    _panMode = null;
    _panExcluded = false;
    _panStartX = d.localPosition.dx;
    _panDx = 0;
    _panDy = 0;
    _hudTimer?.cancel();
    if (_hudKind != null) setState(() => _hudKind = null);
    final height = MediaQuery.sizeOf(context).height;
    if (isExcludedGestureStart(y0: d.localPosition.dy, height: height)) {
      _panExcluded = true;
      debugPrint('[player_page] 手势起点在豁免带 y0='
          '${d.localPosition.dy.toStringAsFixed(0)}px'
          '（屏高 ${height.toStringAsFixed(0)}px）→ 本次 Pan 忽略（让给系统手势）');
      return;
    }
    debugPrint('[player_page] 手势开始 x0=${_panStartX.toStringAsFixed(0)}px '
        'fullscreen=$_fullscreen');
  }

  /// 手势滑动：先累计位移并尝试锁定主导方向（锁定后不再切换），
  /// 再按锁定模式分发到 seek / 亮度·音量逻辑。
  void _onPanUpdate(DragUpdateDetails d) {
    if (_panExcluded) return; // 豁免带起点：本次 Pan 已整体忽略
    if (_panMode == null) {
      _panDx += d.delta.dx;
      _panDy += d.delta.dy;
      final m = nextPanMode(current: null, dx: _panDx, dy: _panDy);
      if (m != null) _lockPanMode(m);
    }
    switch (_panMode) {
      case PanSlideMode.horizontal:
        // 水平主导：仅全屏横屏有 seek（竖屏忽略 = 无 seek，防误触）
        if (_fullscreen) _onSeekDragUpdate(d);
        break;
      case PanSlideMode.vertical:
        _onVerticalDragUpdate(d);
        break;
      case null:
        break;
    }
  }

  /// 锁定主导方向：初始化对应模式的拖动状态（水平 → seek 基准；垂直 →
  /// 半屏定亮度/音量并取原生基准）。
  void _lockPanMode(PanSlideMode m) {
    _panMode = m;
    switch (m) {
      case PanSlideMode.horizontal:
        if (_fullscreen) _beginSeekDrag();
        break;
      case PanSlideMode.vertical:
        _beginVerticalAdjust();
        break;
    }
    debugPrint('[player_page] 手势锁定 mode=${m.name}');
  }

  /// 手势结束：按锁定模式收尾（水平 → seekTo + 保存进度；垂直 → 复位类型），
  /// 随后复位本次手势状态。位移未达阈值（mode 仍为 null）= 点按 / 微移，
  /// 不产生任何动作（tap / 双击 / 长按已由 GestureDetector 另行处理）。
  void _onPanEnd(DragEndDetails d) async {
    if (_panExcluded) {
      _panExcluded = false;
      return; // 豁免带起点：本次 Pan 已整体忽略（不 seek / 不调节 / 不出 hud）
    }
    final m = _panMode;
    _panMode = null;
    switch (m) {
      case PanSlideMode.horizontal:
        if (_fullscreen) await _onSeekDragEnd(d);
        break;
      case PanSlideMode.vertical:
        _onVerticalDragEnd(d);
        break;
      case null:
        break;
    }
  }

  /// 手势被系统打断（来电 / 通知栏下拉等）：复位拖动状态，
  /// 避免 _seekDragging 一直卡住 tick 位置刷新。
  void _onPanCancel() {
    _panExcluded = false;
    _panMode = null;
    if (_seekDragging) {
      _seekDragging = false;
      _scheduleHudHide(const Duration(milliseconds: 600));
    }
    if (_adjustKind != null) {
      _adjustKind = null;
      _adjustReady = false;
      _scheduleHudHide(const Duration(milliseconds: 700));
    }
  }

  // ---------- horizontal（水平主导）→ 全屏横屏 seek ----------

  /// 锁定为水平且在全屏横屏：初始化 seek（基准 = 当前播放位置，位移从
  /// 锁定起累计）。竖屏不建 seek（水平主导忽略）。
  void _beginSeekDrag() {
    if (_player == null || _durationMs <= 0) return;
    _seekDragging = true;
    _seekDragBaseMs = _positionMs;
    _seekDragDx = 0;
    _seekDragSpan = MediaQuery.sizeOf(context).width;
    _showSeekHud(_positionMs);
    debugPrint('[player_page] 横屏 seek 开始 base=${_positionMs}ms '
        'span=${_seekDragSpan}px');
  }

  void _onSeekDragUpdate(DragUpdateDetails d) {
    if (!_seekDragging) return;
    _seekDragDx += d.delta.dx;
    final target = seekTargetMs(
      baseMs: _seekDragBaseMs,
      fraction: slideFraction(_seekDragDx, _seekDragSpan),
      durationMs: _durationMs,
    );
    _showSeekHud(target);
  }

  Future<void> _onSeekDragEnd(DragEndDetails _) async {
    if (!_seekDragging) return;
    _seekDragging = false;
    final fraction = slideFraction(_seekDragDx, _seekDragSpan);
    final target = seekTargetMs(
      baseMs: _seekDragBaseMs,
      fraction: fraction,
      durationMs: _durationMs,
    );
    debugPrint('[player_page] 横屏 seekTo ${target}ms'
        '（比例 ${fraction.toStringAsFixed(2)}）');
    await _player?.seekTo(target);
    if (mounted) setState(() => _positionMs = target);
    _saveProgress(); // seek 后保存，防滑到新位置丢进度
    _scheduleHudHide(const Duration(milliseconds: 600));
  }

  // ---------- vertical（垂直主导）→ 亮度 / 音量（横竖屏都可用） ----------

  /// 锁定为垂直：按起点 [_panStartX] 半屏判定类型，再**异步读取当前基准**
  /// （音量当前档 + 最大档 / 亮度当前百分比）。读取成功前 [_adjustReady]
  /// =false，期间忽略滑动——基准未就绪不做任何换算，避免基准缺失/错误
  /// 导致跳变（「动一点就 0/100」的根因之一）。
  /// 读取失败：亮度由 [DeviceMedia.getBrightnessPercent] 兜底 50%；
  /// 音量（getVolume 为 null 或 max<=0）无有效档位信息 → 放弃本次手势
  /// （不硬设 0，避免把音量清零）。
  void _beginVerticalAdjust() {
    final width = MediaQuery.sizeOf(context).width;
    final kind = verticalSlideKind(_panStartX, width);
    debugPrint('[player_page] 垂直手势开始 kind=${kind.name} '
        'x=${_panStartX.toStringAsFixed(0)}px');
    _adjustKind = kind;
    _adjustReady = false;
    _adjustDy = 0;
    _adjustApplied = 0;
    _adjustSpan = MediaQuery.sizeOf(context).height;
    if (kind == PlayerSlideKind.volume) {
      _volumeMax = 0;
      DeviceMedia.getVolume().then((v) {
        if (!mounted || _adjustKind != kind) return;
        if (v == null || v.max <= 0) {
          // 通道失败 / 无音量设备：本次手势作废（不硬设 0）
          debugPrint('[player_page] 音量基准读取失败（v=$v）→ 放弃本次手势');
          _adjustKind = null;
          _scheduleHudHide(const Duration(milliseconds: 700));
          return;
        }
        _volumeMax = v.max;
        _adjustBase = v.current.toDouble();
        _adjustApplied = v.current.toDouble();
        _adjustReady = true;
        _showValueHud(kind, _percentOfLevel(v.current, v.max));
        debugPrint('[player_page] 音量基准 current=${v.current} max=${v.max} '
            '（${_percentOfLevel(v.current, v.max).toStringAsFixed(0)}%）');
      });
    } else {
      DeviceMedia.getBrightnessPercent().then((pct) {
        if (!mounted || _adjustKind != kind) return;
        // 亮度下限 5%（与原生 MIN_BRIGHTNESS / brightnessPercent 一致）
        final base = pct < 5 ? 5.0 : pct;
        _adjustBase = base;
        _adjustApplied = base;
        _adjustReady = true;
        _showValueHud(kind, base);
        debugPrint('[player_page] 亮度基准 ${base.toStringAsFixed(1)}%');
      });
    }
  }

  /// 纵向滑动更新：上滑（dy 为负）→ 增大。目标始终按「锁定时的固定基准 +
  /// 累计滑动比例 × 灵敏度 0.3」换算（v2.16.12+，基准不再被逐帧改写——
  /// 旧版把目标写回基准再叠加，双重累积导致手指动一点点就跳 0/100），
  /// 目标变化达阈值才写原生（避免每帧刷通道）并刷新浮层。
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
        debugPrint('[player_page] 音量调节 '
            '${_adjustApplied.round()}/$_volumeMax → $level/$_volumeMax'
            '（${_percentOfLevel(level, _volumeMax).toStringAsFixed(0)}%）');
        DeviceMedia.setVolume(level);
        _adjustApplied = level.toDouble();
        _showValueHud(kind, _percentOfLevel(level, _volumeMax));
      }
    } else {
      final pct =
          brightnessPercent(basePercent: _adjustBase, fraction: fraction);
      if ((pct - _adjustApplied).abs() >= 1) {
        debugPrint('[player_page] 亮度调节 '
            '${_adjustApplied.toStringAsFixed(1)}% → ${pct.toStringAsFixed(1)}%');
        DeviceMedia.setBrightness(pct / 100);
        _adjustApplied = pct;
        _showValueHud(kind, pct);
      }
    }
  }

  /// 纵向手势结束：类型复位（调节已即时生效，不恢复），浮层延迟隐藏。
  void _onVerticalDragEnd(DragEndDetails _) {
    if (_adjustKind == null) return;
    debugPrint('[player_page] 纵向手势结束 kind=${_adjustKind!.name} '
        'base=${_adjustBase.toStringAsFixed(1)}');
    _adjustKind = null;
    _adjustReady = false;
    _scheduleHudHide(const Duration(milliseconds: 700));
  }

  double _percentOfLevel(int level, int max) => max <= 0
      ? 0
      : (level * 100 / max).roundToDouble();

  // ---------- 手势提示浮层（hud） ----------

  /// 显示 seek 时间浮层（当前进度 / 总时长），先取消待隐藏计时。
  void _showSeekHud(int posMs) {
    if (!mounted) return;
    _hudTimer?.cancel();
    setState(() {
      _hudKind = PlayerSlideKind.seek;
      _hudSeekPosMs = posMs;
    });
  }

  /// 显示亮度 / 音量百分比浮层。
  void _showValueHud(PlayerSlideKind kind, double percent) {
    if (!mounted) return;
    _hudTimer?.cancel();
    setState(() {
      _hudKind = kind;
      _hudValue = percent;
    });
  }

  /// 手势结束后延迟隐藏浮层（seek / 亮度 / 音量共用）。
  void _scheduleHudHide(Duration delay) {
    _hudTimer?.cancel();
    _hudTimer = Timer(delay, () {
      if (mounted) setState(() => _hudKind = null);
    });
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

  /// 打开评论区（只读查看；aid 在评论页内异步解析，失败页内提示重试）。
  Future<void> _openComments() async {
    debugPrint('[player_page] 打开评论区 bvid=${widget.video.bvid} '
        'epId=${widget.video.epId}');
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CommentPage(video: widget.video)),
    );
  }

  // -------------------------------------------------------------------------
  // 弹幕（v2.16.3+）
  // -------------------------------------------------------------------------

  /// 弹幕开关：开 → 拉取当前 cid 弹幕并显示；关 → 清空显示数据（缓存保留）。
  /// v2.16.13 起开关状态并入设置持久化——重启 App 后保持上次开关状态。
  void _toggleDanmaku() {
    final on = !_danmakuEnabled;
    debugPrint('[player_page] 弹幕开关 -> ${on ? '开' : '关'} cid=$_currentCid');
    setState(() {
      _danmakuEnabled = on;
      _danmakuSettings = _danmakuSettings.copyWith(enabled: on);
      if (!on) {
        _danmaku = const []; // 关闭：清空渲染数据（cache 保留，重开秒显示）
      }
    });
    // 立即持久化开关（fire-and-forget：失败静默，下次进页读不到用默认）
    DanmakuSettingsStore.instance.save(_danmakuSettings);
    if (on) _loadDanmaku();
  }

  /// 异步加载弹幕设置（屏蔽词/类型/透明度/显示区域/**开关记忆**）。带超时
  /// 保护：测试环境无 shared_preferences 原生通道时 getInstance 永不返回，
  /// 不能阻塞播放初始化（与 PlaybackProgress.load 同模式）；超时/异常保持
  /// 默认设置。
  Future<void> _loadDanmakuSettings() async {
    try {
      final s = await DanmakuSettingsStore.instance
          .get()
          .timeout(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() {
        _danmakuSettings = s;
        // 开关记忆（v2.16.13）：上次开着 → 本次进播放页自动开（不用再点）
        _danmakuEnabled = s.enabled;
      });
      // 记忆为开 → 自动拉当前集弹幕（切集走 _switchPage 同样按开启状态拉取）
      if (s.enabled) _loadDanmaku();
    } catch (_) {
      // 超时/存储异常：保持默认设置（不影响播放）
    }
  }

  /// 弹幕设置面板（弹幕按钮**长按**触发）：屏蔽词/屏蔽类型/透明度集中管理。
  /// 面板内任何改动即回调 → setState（overlay 收到新 settings 实例即时
  /// 清屏按当前位置重载，屏蔽/透明度立刻生效）+ 本地持久化（自动保存）。
  Future<void> _showDanmakuSettings() async {
    debugPrint('[player_page] show danmaku settings sheet');
    await showModalBottomSheet<void>(
      context: context,
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
          // 持久化（fire-and-forget：失败静默，下次进页读不到用默认）
          DanmakuSettingsStore.instance.save(s);
        },
      ),
    );
  }

  /// 拉取当前视频（当前集 cid）弹幕。
  ///
  /// - 命中页面缓存（同 cid 重复开）→ 直接显示，不重复请求
  /// - fetchDanmaku 本身失败静默返回空（接口异常不阻塞播放）
  /// - 拉取为空（视频无弹幕 / 老视频弹幕被关闭 / 接口异常）→ 轻提示一次，
  ///   开关保持开启但无数据可渲染（不打扰播放）
  Future<void> _loadDanmaku() async {
    final cid = _currentCid;
    final cached = _danmakuCache[cid];
    if (cached != null) {
      debugPrint('[player_page] 弹幕缓存命中 cid=$cid ${cached.length} 条');
      if (mounted) setState(() => _danmaku = cached);
      return;
    }
    final list = await _api.fetchDanmaku(cid);
    if (!mounted) return;
    // 拉取期间切了集 → 丢弃过期结果（新集 _loadDanmaku 会再触发）
    if (_currentCid != cid) return;
    _danmakuCache[cid] = list;
    debugPrint('[player_page] 弹幕拉取完成 cid=$cid ${list.length} 条'
        ' enabled=$_danmakuEnabled');
    setState(() {
      // 仅开关仍开启时挂载渲染数据（用户期间已关闭则保持空）
      _danmaku = _danmakuEnabled ? list : const [];
    });
    if (list.isEmpty && _danmakuEnabled) {
      _showSnack('该视频暂无弹幕');
    }
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
  /// 末尾恒挂「🎙 实时转写（流式）」区块（无字幕视频也可实时转写，故不放行提前 return）。
  /// 「翻译（中文）」恒显示（tracks 为空时也显示——实时转写结果作主字幕时同样可翻译）。
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
    } else {
      final List<Widget> trackPart;
      if (_subtitleError != null) {
        trackPart = [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_subtitleError!,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 13)),
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
        trackPart = const [
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text('该视频无可用字幕（可尝试下方「实时转写」）',
                  style: TextStyle(color: Colors.white54, fontSize: 14)),
            ),
          ),
        ];
      } else {
        trackPart = [
          _buildSubtitleTrackHeader('主字幕'),
          _buildSubtitleTrackTile(null, isMain: true, refresh: refresh),
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
        ];
      }
      body = [
        ...trackPart,
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
    return [...body, _buildRealtimeSection(refresh)];
  }

  /// 「🎙 实时转写（流式）」区块：轨道列表/翻译下方。
  ///
  /// 状态机（监听 [RealtimeTranscriber.stage]，ValueListenableBuilder 驱动，
  /// 面板内任意变化自动刷新，无需手动 refresh）：
  /// - idle：主按钮「🎙 实时转写」+ 说明（首次需下载模型 247MB）+ 手动放置指引
  /// - modelDownload：进度条 + 「模型下载 x%」+ 下载慢/手动放置提示
  /// - audioPrep：进度条 + 「音频准备中」
  /// - transcribing：「转写中…」+ partial 实时预览（小字）+ 「停止」
  /// - done：「✅ 实时转写完成（N 句）· 已作为字幕」+ 重新转写
  /// - error：红字错误 + 「重试」
  Widget _buildRealtimeSection(VoidCallback refresh) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Text('🎙 实时转写（流式）',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        ..._buildRealtimeStates(refresh),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 实时转写区块状态内容：按 stage 分发（[refresh] 仅用于错误「重试」
  /// 等即时动作，阶段变化由 ValueListenableBuilder 自行驱动）。
  List<Widget> _buildRealtimeStates(VoidCallback refresh) {
    return [
      ValueListenableBuilder<RtStage>(
        valueListenable: _realtime.stage,
        builder: (context, stage, _) =>
            _buildRealtimeStageBody(stage, refresh),
      ),
    ];
  }

  Widget _buildRealtimeStageBody(RtStage stage, VoidCallback refresh) {
    switch (stage) {
      case RtStage.modelDownload:
        return ValueListenableBuilder<double>(
          valueListenable: _realtime.progress,
          builder: (context, p, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ensureModel 进度：下载 0~0.9，解压 0.9~1.0 → 显示段 0~100%
              _buildRealtimeProgressRow('模型下载', (p / 0.9).clamp(0.0, 1.0)),
              _buildRealtimeModelHint(),
            ],
          ),
        );
      case RtStage.audioPrep:
        return ValueListenableBuilder<double>(
          valueListenable: _realtime.progress,
          builder: (context, p, _) =>
              _buildRealtimeProgressRow('音频准备中', p.clamp(0.0, 1.0)),
        );
      case RtStage.transcribing:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.pinkAccent),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('转写中…',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: _stopRealtime,
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.white70),
                    child: const Text('停止'),
                  ),
                ],
              ),
            ),
            // partialText 实时预览（小字；仅面板预览，不占字幕层）
            ValueListenableBuilder<String>(
              valueListenable: _realtime.partialText,
              builder: (context, t, _) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  t.trim().isEmpty ? '（识别中…）' : t.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ),
          ],
        );
      case RtStage.done:
        return ValueListenableBuilder<List<RealtimeSentence>>(
          valueListenable: _realtime.sentences,
          builder: (context, list, _) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.check_circle,
                    color: Colors.greenAccent, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '✅ 实时转写完成（${list.length} 句）· 已作为字幕',
                    style: const TextStyle(
                        color: Colors.greenAccent, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: _startRealtime,
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.white70),
                  child: const Text('重新转写'),
                ),
              ],
            ),
          ),
        );
      case RtStage.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: _realtime.error,
              builder: (context, err, _) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  err ?? '实时转写失败',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: OutlinedButton(
                onPressed: _startRealtime,
                style:
                    OutlinedButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('重试'),
              ),
            ),
          ],
        );
      case RtStage.idle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: FilledButton(
                onPressed: _startRealtime,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.pinkAccent,
                  foregroundColor: Colors.black,
                ),
                child: const Text('🎙 实时转写'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('流式识别，边播边出字幕（首次需下载模型 247MB）',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
            if (_realtimeModelDir.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('也可手动放置模型文件到：$_realtimeModelDir',
                    style: const TextStyle(color: Colors.white24, fontSize: 11)),
              ),
          ],
        );
    }
  }

  /// 阶段进度行：文案 + 线性进度条。
  Widget _buildRealtimeProgressRow(String label, double v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text('$label ${(v * 100).round()}%',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: LinearProgressIndicator(
            value: v,
            color: Colors.pinkAccent,
            backgroundColor: Colors.white12,
            minHeight: 3,
          ),
        ),
      ],
    );
  }

  /// 模型下载阶段提示：下载可能较慢 + 手动放置模型指引（目录路径）。
  Widget _buildRealtimeModelHint() {
    final dir = _realtimeModelDir;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Text(
        dir.isEmpty
            ? '下载可能较慢（GitHub 国内网络），也可手动放置模型文件后重试'
            : '下载可能较慢（GitHub 国内网络），也可手动放置模型文件到：$dir',
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
    );
  }

  /// 开始实时转写（sherpa 流式）：模型 → 音频 → 流式转写 + 逐句翻译。
  /// 阶段/进度/partial/句子由单例 ValueNotifier 驱动面板与字幕层刷新；
  /// 错误：start 内部已置 stage=error + error 文案（面板红字），这里补 SnackBar。
  Future<void> _startRealtime() async {
    if (_realtime.isRunning) return;
    try {
      await _realtime.start(widget.video, _currentPageIndex);
    } catch (e) {
      if (!mounted) return;
      _showSnack('实时转写失败：${_realtime.error.value ?? '$e'}');
    }
  }

  /// 停止实时转写（标志位，块边界生效；stage 回 idle，句子保留在单例）。
  void _stopRealtime() => _realtime.stop();

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
        ? (isMain ? _mainSubtitleTrack == null : _secondarySubtitleTrack == null)
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
  void _selectMainSubtitle(SubtitleTrack? track) {
    setState(() => _mainSubtitleTrack = track);
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
  /// - 未选主字幕 → 提示先选主字幕
  /// - 未配置翻译服务 → 提示去管理面板配置（不选中）
  /// - 已配置 → 副字幕切到翻译模式，_runTranslation 负责缓存/翻译/渲染
  Future<void> _selectTranslationMode() async {
    final mainTrack = _mainSubtitleTrack;
    final hasMain = mainTrack != null;
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
  /// - 主字幕源为 B 站轨道（译文按 bvid_cid_lan 缓存）
  /// - 缓存命中（同源已翻译过）直接显示，不重复翻译
  /// - 翻译完成写缓存（切集/重进命中即显示）
  /// - 失败：面板/字幕层提示「翻译失败」+ SnackBar 具体错误（401 配置无效/网络）
  Future<void> _runTranslation() async {
    final mainTrack = _mainSubtitleTrack;
    if (mainTrack == null) return;
    setState(() {
      _translationLoading = true;
      _translationError = null;
      _translationDone = 0;
      _translationTotal = 0;
    });
    final cues = await _ensureSubtitleCuesFor(mainTrack);
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
    final lan = mainTrack.lan;

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
    // 实时转写（sherpa）随集重置：停止 + 清句子（句子时间轴是当前集音频）
    _resetRealtime();
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
      // 弹幕：切集清空渲染数据（缓存按 cid 保留）；开关状态保留，
      // 下方 _loadStreamAndPlay 成功后若开关仍开则自动拉新集弹幕
      _danmaku = const [];
    });
    try {
      await _loadStreamAndPlay(positionMs: 0);
      await _player?.setPlaybackSpeed(_speed);
      if (mounted) setState(() => _buffering = false);
      // 切集后弹幕开关仍开 → 自动拉取新集弹幕（新 cid 数据）
      if (_danmakuEnabled) await _loadDanmaku();
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
          // 2.25 弹幕层：Texture 之上、字幕层之下（字幕可读优先）。
          // 仅「开关开 && 有数据 && 已加载」才构建——关闭时零开销；
          // 无弹幕（空数据）不构建，不产生任何绘制。
          if (!_listenMode &&
              _danmakuEnabled &&
              _danmaku.isNotEmpty &&
              _loaded)
            Positioned.fill(
              child: IgnorePointer(
                child: DanmakuOverlay(
                  danmaku: _danmaku,
                  playing: _playing,
                  positionMs: _positionMs,
                  settings: _danmakuSettings,
                ),
              ),
            ),
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
          // 4. 点击画面切换控制层显隐 + 长按 2x + B 站式快捷手势（v2.16.7+）。
          //    onTap 与 onLongPress 可共存：长按赢得手势后 onTap 自动取消。
          //    手势冲突面（识别器在同一竞技场竞争，由 Flutter 判定谁赢）：
          //    - 单击（显隐）vs 双击（播放/暂停）：onDoubleTap 与 onTap 共存时，
          //      Tap 需等双击窗口（~300ms）判定——双击赢得 → 单击自动取消
          //      （双击不误触显隐）；单击赢得 → 显隐延迟 ~300ms 触发
          //    - 长按 2x：按住不动 500ms 赢得，期间不响应滑动（松开再滑）
          //    - 滑动（v2.16.9+）：**单一 Pan 注册**（横竖屏统一）——pan 需位移
          //      超 touchSlop 才赢得竞技场（tap 无位移不受影响）；赢后由
          //      [decideMode] 按主导方向锁定：水平主导 → 仅全屏横屏 seek，
          //      垂直主导 → 起点半屏亮度/音量（横竖屏都可用，斜向按主方向归类；
          //      锁定后本次手势不再切换）。v2.16.7 旧实现「横屏只注册横向、
          //      竖屏只注册纵向」→ 横屏全屏稍斜的上下滑被误判为横向 seek、
          //      纯上下滑完全无响应——本次修复让两者共存
          //    - 豁免带（v2.16.14+）：Pan **起点 y0** 落在底部/顶部豁免带
          //      （[isExcludedGestureStart]，见类顶常量）→ 本次 Pan 整体忽略，
          //      不 seek / 不调亮度音量 / 不出 hud——横屏全屏从屏幕下方滑动
          //      唤醒系统导航不再误触发 seek（起点带内该次触摸让给系统手势）；
          //      tap / 双击 / 长按无位移不触发 Pan、不受豁免影响
          //    - 控制层按钮 / 进度条在本层**之后**渲染（Stack 上层），其区域内
          //      点击与拖动天然拦截（按钮优先）；弹幕层 IgnorePointer 不参与命中
          //    听视频模式下让位给占位层（其自己处理点按恢复画面 + 长按 2x），
          //    否则本 opaque 层会拦截占位层的点击。
          if (!_listenMode)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: _player == null ? null : _onDoubleTap,
                onLongPressStart: _player == null ? null : _onLongPressStart,
                onLongPressEnd: _player == null ? null : _onLongPressEnd,
                // 滑动统一 Pan（v2.16.9+）：方向判定在手势内完成——全屏横屏
                // 水平主导 seek、垂直主导亮度/音量共存；竖屏水平主导忽略
                onPanStart: _player == null ? null : _onPanStart,
                onPanUpdate: _player == null ? null : _onPanUpdate,
                onPanEnd: _player == null ? null : _onPanEnd,
                onPanCancel: _player == null ? null : _onPanCancel,
              ),
            ),
          // 5. 控制层（置于点击层之上）
          if (_controlsVisible || !_loaded) _buildControls(),
          // 5.5 手势提示浮层（B 站式快捷手势）：seek 时间 / 亮度 / 音量，
          //     中心偏上、不拦截任何点击（IgnorePointer）。
          if (_hudKind != null)
            Positioned.fill(child: _buildGestureHud()),
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

  /// 手势提示浮层（seek 时间 / 亮度 / 音量）：半透明黑底圆角小条，居中偏上。
  /// 整体包 IgnorePointer——纯展示，不拦截下方任何点击/拖动。
  Widget _buildGestureHud() {
    final kind = _hudKind!;
    final String text;
    final IconData icon;
    switch (kind) {
      case PlayerSlideKind.seek:
        text = '${_fmtMs(_hudSeekPosMs)} / ${_fmtMs(_durationMs)}';
        icon = Icons.access_time;
      case PlayerSlideKind.brightness:
        text = '亮度 ${_hudValue.round()}%';
        icon = Icons.brightness_6;
      case PlayerSlideKind.volume:
        text = '音量 ${_hudValue.round()}%';
        final v = _hudValue;
        icon = v <= 0
            ? Icons.volume_off
            : (v < 50 ? Icons.volume_down : Icons.volume_up);
    }
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.28),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 8),
              Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
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

  /// 中心控制：快退 3 秒（左）+ 播放/暂停大按钮（中）+ 快进 3 秒（右，对称）。
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
            // 快进 3 秒：Icons.forward_30 转圈箭头，与左侧快退对称
            IconButton(
              tooltip: '快进 3 秒',
              iconSize: 40,
              color: Colors.white,
              icon: const Icon(Icons.forward_30),
              onPressed: _player == null ? null : _forward3s,
            ),
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
                  // 弹幕按钮：图标 + 状态反馈（开启时高亮）。
                  // 点按 = 开关；长按 = 弹幕设置（屏蔽词/类型/透明度）。
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _toggleDanmaku,
                      onLongPress:
                          _player == null ? null : _showDanmakuSettings,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _danmakuEnabled
                                ? Icons.chat_bubble
                                : Icons.chat_bubble_outline,
                            color: _danmakuEnabled
                                ? Colors.pinkAccent
                                : Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '弹幕',
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _danmakuEnabled
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
                  // 评论按钮：打开评论区（只读查看，aid 页内解析）
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _openComments,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.comment_outlined,
                              color: Colors.white, size: 18),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '评论',
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
