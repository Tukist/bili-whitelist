import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../api/bilibili_api.dart';
import '../api/sherpa_model.dart';
import '../api/translate_api.dart';
import '../cache/download_manager.dart';
import '../cache/playback_progress.dart';
import '../models/danmaku.dart';
import '../models/danmaku_settings.dart';
import '../models/playlist_context.dart';
import '../models/subtitle.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../player/bili_dash_player.dart';
import '../services/danmaku_settings_store.dart';
import '../services/device_media.dart';
import '../services/history_store.dart';
import '../services/realtime_transcriber.dart';
import '../services/ui_prefs_store.dart';
import '../services/video_shot_service.dart';
import '../services/watch_stats.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';
import '../theme/route_names.dart';
import '../widgets/app_block.dart';
import '../widgets/app_snack.dart';
import '../widgets/comment_list.dart';
import '../widgets/cover_hero.dart';
import '../widgets/cover_image.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_sheet.dart';
import '../widgets/expandable_text.dart';
import '../widgets/upowner_badge.dart';
import 'comment_page.dart';
import 'login_page.dart';
import 'upowner_page.dart';

// 路由名常量已上移到 theme 层（避免 theme → pages 的跨层依赖）。
// 这里 re-export：各入口页面与测试历来自 `player_page.dart` 取
// [kPlayerRouteName]，re-export 让这些引用点零改动，也保证全 App
// 只有一个定义（`route_names.dart`）。
export '../theme/route_names.dart';

/// 可选的播放倍速档位（默认 1.0，均落在原生支持区间 0.25~4.0 内）。
const List<double> kPlaybackSpeeds = [
  0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0,
];

/// 长按视频画面时强制使用的倍速。
const double kLongPressSpeed = 2.0;

/// 底栏「上一集 / 第 N/M 集 / 下一集」行里**中间标签**的宽度上限（dp）。
///
/// 参考机 411dp 宽：左右按钮各占半屏（205.5dp），按钮内容（图标 18 + 4 + 三字
/// 标签）约 57dp 居中在各自半屏里 → 中间真正空出来的带子约 148dp。取 140 留
/// 8dp 余量，既能完整显示「合集名 · 3/5」这种常见文案，又不会长到压住两侧按钮
/// 的图标/文字；超长 label 一律省略号（见 `_buildPlaylistRow`）。
const double kPlaylistLabelMaxWidth = 140.0;

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
// 播放错误自动续播决策（v2.17.14+，纯函数，便于单测）
//
// 背景：播放中途遇到流 URL 过期（403/404/410）或瞬时网络错误（超时/断连，
// 原生统一归为 onUrlExpired）时，Dart 侧重取 playurl → setDataSource 续播
// （保留位置）。网络抖动可能一次不成功：按 [kAutoRecoverBackoffMs] 退避重试
// **有限次**，仍失败才显示错误（保留手动重试兜底）——避免网络抖动弹
// 「播放失败」打断观看。
// -------------------------------------------------------------------------

/// 自动续播尝试间的退避毫秒表（长度即最大尝试次数）：第 0/1/2 次尝试前
/// 分别等 1s/2s/4s（给网络喘息）；第 3 次起不再自动尝试（放弃显示错误）。
const List<int> kAutoRecoverBackoffMs = [1000, 2000, 4000];

/// 自动续播第 [attempt]（0 起）次尝试前的退避毫秒；attempt 越界（超上限，
/// 应放弃、显示错误交手动重试）/负数 → null。
int? autoRecoverDelayMs(int attempt) =>
    attempt >= 0 && attempt < kAutoRecoverBackoffMs.length
        ? kAutoRecoverBackoffMs[attempt]
        : null;

/// 自动续播耗尽（连续失败超过上限）后的错误文案（保留「重试」按钮兜底）。
const String kAutoRecoverGiveUpMessage = '播放中断（网络或视频流异常），请重试';

// -------------------------------------------------------------------------
// 流 URL deadline 解析 + 主动预取换源决策（v2.17.15+，纯函数，便于单测）
//
// 背景：B 站 `.bilivideo.com` 流 URL 带 `deadline`（过期时间戳）+ `upsig`
// 签名，过期后读取必然失败（403/2001）。2026-09 实测：普通/番剧 DASH
// video/audio 与 mp4 durl 的 deadline 均为**固定 2 小时（7200s）**（跨 4 条
// 视频 × 全部流类型稳定，单位是 Unix **秒**）。普通长度视频播放中不会到期，
// 但「超长视频（>2h 一次看完）/ 长时间暂停后续播」仍可能用完 URL 剩余有效期
// → 读到过期 URL 必中断。方案：解析流 URL deadline → 播放中周期判定「当前
// URL 剩余有效期不足以播完剩余内容 + 提前量」→ 到期前主动 fetchPlayUrl 换
// 新 URL（setDataSource+seek，URL 尚有效时主动做，播放几乎无感）；无法解析
// deadline（本地缓存/无此参数）不预取，回退 v2.17.14 被动 onUrlExpired 续播。
// -------------------------------------------------------------------------

/// 主动预取提前量（毫秒）：判定换源时给「重取 playurl + 重建源 + 新源首缓冲」
/// 留的余量——URL 剩余有效期比「剩余内容播放时长」多出不足该值即触发。
const int kPrefetchLeadMs = 60000;

/// 两次预取尝试的最小间隔（毫秒）：成功/失败都占位，防网络异常时每 10s
/// 反复打 playurl 形成请求风暴（超长视频「换源后仍不够播完」的连续触发
/// 场景也按此节流，每 90s 才重试一次）。
const int kPrefetchMinIntervalMs = 90000;

/// 解析流 URL 的 `deadline` 参数（过期时刻，归一为 Unix **毫秒**）。
///
/// 实测该参数单位是 Unix 秒（~1.7e9，2026-09）；部分渠道/历史版本可能是
/// 毫秒（~1.7e12）——按量级统一归一为毫秒（阈值 1e11 ≈ 公元 5138 年，
/// 秒/毫秒两态都远低于/高于该界）。缺参数 / 非数字 / URL 非法 → null
/// （无法预取，由被动恢复兜底）。
int? streamDeadlineMs(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final raw = uri.queryParameters['deadline'];
  if (raw == null) return null;
  final v = int.tryParse(raw);
  if (v == null) return null;
  return v < 100000000000 ? v * 1000 : v;
}

/// 流 URL 距离过期的剩余毫秒（[deadlineMs] 减当前时刻；已过期 → ≤0）。
/// [deadlineMs] 为 null（无 deadline）→ null。
int? streamDeadlineRemainMs(int? deadlineMs, {required int nowMs}) {
  if (deadlineMs == null) return null;
  return deadlineMs - nowMs;
}

/// 主动预取换源决策（纯函数）：
///
/// 需要提前换源 ⇔ 「当前 URL 剩余有效期 [deadlineRemainMs]」不足以比
/// 「剩余内容播放时长 [videoRemainMs]」多出 [leadMs] 提前量——即按 1x 继续
/// 用当前 URL 播，会在 URL 到期前后脚才放完，到期前必须换新 URL（换源本身
/// 耗时由 [leadMs] 覆盖）。两者都在播放中按 1:1 递减，差值不变，因此
/// 判定对「何时会触发」是稳定且单调的。
///
/// 任一输入不可用（deadline 缺失 [deadlineRemainMs]=null / 剩余时长未知
/// ≤0）→ false（不预取，回退被动恢复）。
bool shouldPrefetchSource({
  required int? deadlineRemainMs,
  required int videoRemainMs,
  int leadMs = kPrefetchLeadMs,
}) {
  if (deadlineRemainMs == null || videoRemainMs <= 0) return false;
  return deadlineRemainMs - videoRemainMs < leadMs;
}

// -------------------------------------------------------------------------
// B 站式播放快捷手势（v2.16.7+）纯函数（便于单测）
//
// 手势总览（参照 B 站手机端播放器；冲突处理见 build 中手势层注释）：
// - 双击：播放 / 暂停（与单击显隐共存，单击延迟 ~300ms 等双击判定）
// - 滑动统一走 Pan + 主导方向判定（v2.16.9+）：斜向滑动按**位移主方向**
//   归类——水平主导 → seek（v2.18.x 起**竖屏 / 横屏置顶 / 横屏全屏统一
//   可用**，能否 seek 由 [canGestureSeek] 判定；位移/手势区宽 = 时长比例，
//   松手 seekTo；本版起呈现成「直接拖进度条」：进度条手柄跟着目标位置走 +
//   进度条上方弹出预览气泡，见 [_PlayerPageState._buildSeekRow]）；垂直主导
//   → 起点左半屏亮度 / 右半屏音量（原生通道 bili_whitelist/media，见
//   services/device_media.dart）。
// - 手势起点豁免带（v2.16.14+ 顶/底 → v2.16.17+ 四边）：起点落在屏幕
//   底部/顶部/左/右任一条豁免带内的 Pan 整体忽略（不 seek / 不调亮度音量）
//   ——横屏全屏从**物理屏幕底部**滑动（旋转后 = 逻辑左/右边缘，见类顶注释）
//   唤醒系统导航不再误触发 seek，让给系统手势；参数与判定见
//   [isExcludedGestureStart]。底部带 v2.18.x 起**仅全屏生效**：非全屏手势层
//   = 视频黑盒，其底边落在屏幕中部（竖屏 16:9 时约屏高 1/4 处），不是物理
//   屏幕底边、那里没有系统导航区（见 [_onPanDown]）。
//
// 滑动量换算统一走 [slideFraction]：滑满一屏 = ±100%（比例），
// 方向约定：向右 / 向上为「前进 / 增大」。
//
// 亮度/音量纵向调节的灵敏度（v2.16.12+）：完整上下滑一屏 ≈ 基准 ±30%
// （灵敏度 [kAdjustSensitivity] = 0.3，见 [adjustPercent]），小幅滑动
// 平滑小幅变化——不再像 v2.16.7~11 那样「滑满一屏 = ±100%、基准被逐帧
// 累加改写」，表现为手指动一点点就跳 0 / 100。
// -------------------------------------------------------------------------

/// 手势提示浮层的类型（也即半屏判定可产生的目标）。
enum PlayerSlideKind {
  /// seek（浮层显示 当前进度 / 总时长；竖屏 / 横屏统一可用）。
  seek,

  /// 亮度（左半屏纵向滑动）。
  brightness,

  /// 音量（右半屏纵向滑动）。
  volume,
}

/// 滑动手势的主导方向（判定锁定后本次手势不再切换，防中途抖动）。
enum PanSlideMode {
  /// 水平主导 → seek（听视频 / 时长未知时不 seek，见 [canGestureSeek]）。
  horizontal,

  /// 垂直主导 → 起点左半屏亮度 / 右半屏音量。
  vertical,
}

/// 主导方向判定的位移阈值（px）：dx/dy 都未超此值视为未开始滑动
/// （点按抖动 / 微移不触发任何手势），超过才按主导分量归类。
const double kPanModeThreshold = 12;

// 手势起点豁免带（v2.16.14+ 顶/底 → v2.16.17+ 扩展四边）
// ---------------------------------------------------------------------------
// 背景（用户实测反馈）：横屏全屏（immersiveSticky）时想从屏幕**底部**滑动
// 唤醒 Android 三键导航 / 手势导航，App 手势层与系统手势区同时收到触摸——
// 旧版单一 Pan 覆盖整屏，从屏幕下方发起的滑动被当成 seek（进度被拖走、
// hud 乱跳）。而系统导航条在几何屏幕底部，这一带本来就不该属于播放手势。
// v2.16.14 方案：Pan 起点 y0 落在**底部/顶部豁免带**内 → 本次 Pan 整体忽略
// （不 seek、不调亮度/音量、不出 hud），把这段屏幕让给系统手势。
//
// v2.16.17 修复（用户实测 v2.16.14 仍误触发 seek 的根因）：豁免只查 y0 上下，
// 但**横屏全屏时系统导航区在物理屏幕底边，对应 Flutter 逻辑坐标的左/右边**
// （旋转后物理底边 = 逻辑左边缘或右边缘，取决于 landscapeLeft/Right）——
// 用户从物理底部上滑在逻辑上呈「起点贴逻辑左/右边缘的横向滑动」，y0 在屏
// 中部、不落任何 y 豁免带 → 豁免失效、仍被当 seek。修复：豁免判定扩展为
// **四边**（含逻辑左/右边缘），横屏左右边缘用「与底部同宽」的豁免带覆盖
// 物理底边导航区（两侧都留：用户持机方向不同，物理底边可能映到左或右任
// 一边）；且判定改用**触摸按下点**（onPanDown 的真实坐标；onPanStart 是
// 竞技场胜出点，边缘滑动实测可内移 ~100px，按它判边带会漏判）。
// 竖屏维持上下豁免为主 + 左右窄带可选防误触（见参数注释）。
// 豁免只作用于 Pan 滑动本身——tap / 双击 / 长按不走 Pan 竞技场（tap 无位移
// 不触发 Pan），豁免带内单击显隐等照常。
// ---------------------------------------------------------------------------

/// 底部豁免带 = 屏高 × [kBottomGestureExclusionFactor]，且**不低于**
/// [kBottomGestureExclusionMinPx]。取值权衡：横屏屏高 ~400dp 时 8% ≈ 32px，
/// 低于系统导航条 / 手势排除区（3-button 导航条 ~48px、手势导航上滑触发区
/// 24~48px）——用「比例 or 固定 48px 取较大者」保证窄边（横屏）也够宽；
/// 竖屏 8% ≈ 屏高 73px 更大。宁宽勿窄（带内仅损失从带内启动的滑动，seek/
/// 调节都改从中部启动），但整体 < 屏高 15%，不挤压中部正常操作区。
///
/// v2.18.x 起该带**只在全屏生效**（语义：底部 = 物理屏幕底边 = 系统导航区）。
/// 非全屏手势层 = 视频黑盒，底边落在屏幕中部（竖屏 411×914 时视频区高
/// ≈231dp、底边 ≈ 屏高 1/4 处），既不是系统导航区，按本参数豁免还会白吃
/// 竖屏视频区约 21% 的起手区 → 非全屏关闭底部带（见 [_onPanDown]）。
const double kBottomGestureExclusionFactor = 0.08;

/// 底部豁免带的最小绝对宽度（px，见 [kBottomGestureExclusionFactor]）。
const double kBottomGestureExclusionMinPx = 48;

/// 顶部豁免带（px，固定窄带）：状态栏 / 刘海下拉区。
const double kTopGestureExclusionPx = 24;

/// 竖屏时左右边缘的豁免带宽度（px，固定小窄带）：默认生效的左右豁免
/// （v2.16.17+）——防从屏幕左/右最边缘启动的滑动被误判为亮度/音量调节 /
/// 与系统手势导航「边缘返回」区重叠时抢手势；竖屏宽度 411dp 时 16px 仅占
/// 两侧各 ~4%，几乎不挤压半屏亮度/音量操作区。横屏时该默认值不适用
/// （物理底边导航区需要更宽，见 [isExcludedGestureStart] 调用处按横/竖屏
/// 分别传入）。
const double kSideGestureExclusionPxPortrait = 16;

/// 手势起点是否落在豁免带内（纯函数，v2.16.14+ 顶/底、v2.16.17+ 四边，
/// 可单测）。逻辑坐标点 (x0, y0)、逻辑尺寸 (width, height)，任一边命中即
/// 返回 true：
/// - y0 ≤ [topPx] → 顶部带内（状态栏 / 刘海区）
/// - y0 ≥ height - max(height × [bottomFactor], [bottomMinPx]) → 底部带内；
///   [bottomFactor] 与 [bottomMinPx] **同时传 0 即关闭该带**（v2.18.x+：
///   非全屏手势层 = 视频黑盒，其底边落在屏幕中部，那里没有系统导航区，
///   见 [_onPanDown]）
/// - x0 ≤ [leftPx] → 左带内（横屏全屏时物理底边导航区 = 逻辑左边缘）
/// - x0 ≥ width - [rightPx] → 右带内（物理底边也可能映到逻辑右边缘）
/// 尺寸异常（≤ 0，防御）→ false（不豁免，退化为旧行为）。
bool isExcludedGestureStart({
  required double x0,
  required double y0,
  required double width,
  required double height,
  double topPx = kTopGestureExclusionPx,
  double bottomFactor = kBottomGestureExclusionFactor,
  double bottomMinPx = kBottomGestureExclusionMinPx,
  double leftPx = kSideGestureExclusionPxPortrait,
  double rightPx = kSideGestureExclusionPxPortrait,
}) {
  if (width <= 0 || height <= 0) return false;
  final bottomPx = math.max(height * bottomFactor, bottomMinPx);
  // bottomPx <= 0（两个参数同时为 0）= 显式关闭底部带。必须单独判：否则
  // 「y0 >= height - 0」会把紧贴手势层底边的起点误判成带内。
  final inTopBottom = y0 <= topPx || (bottomPx > 0 && y0 >= height - bottomPx);
  final inSides = x0 <= leftPx || x0 >= width - rightPx;
  return inTopBottom || inSides;
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

/// 当前是否允许「水平滑动调进度」（纯函数，可单测）。
///
/// v2.18.x 起**与全屏无关**（用户反馈：竖屏模式下无法左右滑动推动进度）：
/// 旧实现三处 `if (_fullscreen)` 把非全屏的水平 seek 链整条掐断——竖屏
/// 水平主导只累计位移、不进 seek 拖动（不出时间浮层）、松手也不 seekTo；
/// 本函数取代这些 gate，让竖屏 / 横屏置顶 / 横屏全屏统一可滑 seek。
/// 唯一的两个否定条件是：
/// - [listenMode]（听视频模式）：画面已隐藏，seek 手势无意义（且此时手势层
///   本身不挂载，见 build 中 `if (!_listenMode)`，这里只是二次防御）
/// - [durationMs] <= 0（时长未知：未就绪 / 直播等）：无时长则比例换算无基准，
///   [seekTargetMs] 也返回 0，此时发起 seek 只会把进度打到 0
bool canGestureSeek({required bool listenMode, required int durationMs}) {
  if (listenMode) return false;
  return durationMs > 0;
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

// -------------------------------------------------------------------------
// 信息行 UP 主入口（阶段 C）：view 接口 owner 解析 + 会话内缓存
//
// 背景：WhitelistVideo 只有 up_name，没有 mid/face（避免改白名单数据/
// 导入/油猴链路）。UP 主区运行时调 fetchVideoMeta(bvid) 取
// data.owner{mid,name,face} 补齐：mid 用于进 [UpownerPage]、name 覆盖
// up_name 展示、face 作头像。同会话缓存避免重复请求同一视频的 view。
// -------------------------------------------------------------------------

/// 从 view 接口返回的 `data` map 解析 UP 主信息（owner.mid/name/face）。
///
/// - owner 缺失/类型异常/mid 非正 → null（调用方回退 up_name 文本展示）
/// - face 允许为空串（部分接口场景无头像 → 走首字圆形占位）
({int mid, String name, String face})? parseViewOwner(
  Map<String, dynamic> data,
) {
  final owner = data['owner'];
  if (owner is! Map<String, dynamic>) return null;
  // 脏数据（字符串等非数字）→ 按 0 处理返回 null（与模型 fromJson 防御风格一致）
  final mid = owner['mid'] is num ? (owner['mid'] as num).toInt() : 0;
  if (mid <= 0) return null;
  return (
    mid: mid,
    name: (owner['name'] as String?)?.trim() ?? '',
    face: owner['face'] as String? ?? '',
  );
}

/// 会话内 UP 主元数据缓存（bvid → owner，阶段 C）。
///
/// 同一视频可能被多次进播放页（历史/评论链接叠页/多 P 切集），缓存让
/// 「已成功拉取过 view owner」的页面直接复用，不再重复请求 view 接口。
final Map<String, ({int mid, String name, String face})> _upMetaCache = {};

// -------------------------------------------------------------------------
// 信息行简介区（v2.17.3+）：desc 运行时补拉 + 会话内缓存
//
// 背景：WhitelistVideo.desc 是 v2.17.3 新增字段，**旧白名单数据没有 desc**。
// 播放页简介优先用 WhitelistVideo.desc（新导入/油猴写入即带）；为空时若该
// 视频不是番剧（番剧简介是季级，逐集导入留空且不拉 pgc view——见 writer
// 取舍），则搭 UP 主元数据那次 fetchVideoMeta 的顺风车补拉 view data.desc
// （同一次响应、零额外请求）。结果按 bvid 缓存在 [_viewDescCache]。
// -------------------------------------------------------------------------

/// 从 view 接口返回的 `data` map 解析简介（data.desc，含 \n 换行原样）。
/// 缺失/类型异常 → 空串（调用方不显示简介区）。
String viewDescOf(Map<String, dynamic> data) =>
    data['desc'] is String ? data['desc'] as String : '';

/// 会话内简介缓存（bvid → desc）：与 [_upMetaCache] 同一次 view 响应写入，
/// 让同一 bvid 的后续播放页（缓存命中跳过请求）也能拿到 desc。
final Map<String, String> _viewDescCache = {};

// -------------------------------------------------------------------------
// 写操作（点赞 / 投币 / 收藏，v2.40.0+）：初始态的会话内缓存
//
// 三个缓存都与 [_upMetaCache] 写在**同一次 view 响应**里（零额外请求），
// 按 bvid 记账的理由也一样：同一条视频可能被反复进播放页（历史/评论链接
// 叠页/上下集来回切），不该每次都等一次网络往返才敢把按钮画成正确状态。
//
// ⚠️ [_reqUserCache] 用 `containsKey` 区分「探过了但接口没给 req_user」
// （匿名/未登录，值就是 null）与「还没探」——两者都让按钮显示"未点赞"，
// 但只有后者值得再等等（前者等到下次启动也一样）。
// -------------------------------------------------------------------------

/// 会话内「我的互动态」缓存（bvid → req_user；值可为 null = 接口没下发）。
final Map<String, VideoReqUser?> _reqUserCache = {};

/// 会话内真实互动态缓存（bvid → relation；v2.41.0+）。
///
/// 与 [_reqUserCache] 的关系：`req_user` 是 **view 接口**给的那份（实测
/// 匿名/登录都不下发，恒 null），[VideoRelation] 是 **archive/relation
/// 接口**给的那份（要登录，是真值）。两者都可能为 null；用 `containsKey`
/// 区分"探过了但没有"与"还没探"。取值优先级：relation > req_user。
final Map<String, VideoRelation?> _relationCache = {};

/// 会话内公开计数缓存（bvid → stat{like,coin,favorite}）。
final Map<String, ({int like, int coin, int favorite})> _viewStatCache = {};

/// 会话内 aid 缓存（bvid → aid）：写接口只认 aid，拿到就记着。
final Map<String, int> _viewAidCache = {};

/// 播放页：进入即取流（DASH 双流 fnval=16，老视频降级 mp4 单流），
/// 原生 ExoPlayer MergingMediaSource 合并播放。
///
/// - 控制层：播放/暂停、进度条（500ms 轮询 getPosition）、当前/总时长、
///   倍速选择（九档 0.5~3x）、听视频（纯音频）开关、全屏切换；
///   点击画面切换控制层显隐，长按画面 2x、松手恢复长按前倍速；进入自动播放；
///   B 站式快捷手势（v2.16.7+）：双击播放/暂停（单击显隐延迟 ~300ms 防误触）、
///   滑动按**主导方向**归类（v2.16.9+）：水平主导 → seek（时间浮层 + 松手
///   seekTo；v2.18.x 起竖屏 / 横屏置顶 / 横屏全屏**统一可用**，见
///   [canGestureSeek]）；垂直主导 → 按起点左/右半屏调亮度/音量（原生通道
///   bili_whitelist/media，仅当前 Activity 内生效）。v2.16.14+/v2.16.17+：
///   触摸按下点落在手势区（非全屏 = 视频区黑盒，见下；全屏 = 整屏）顶部/
///   左右豁免带，以及**全屏时**的底部豁免带（[isExcludedGestureStart]，
///   按下点判定见 [_onPanDown]）→
///   本次 Pan 整体忽略（不 seek / 不调亮度音量）——横屏全屏从**物理底部**滑动
///   （旋转后 = 逻辑左/右边缘，左右带加宽）唤醒系统导航不再误触发 seek
/// - 进度条拖动预览（缩略图 + 时间）：拖动自绘进度条时在轨道上方弹出跟随
///   手指的浮层（[VideoShotService] 提供雪碧图，按分 P 异步 prepare；接口
///   不可用/未就绪 → **降级为只显示时间气泡**，绝不影响拖动与播放）。
///   非全屏气泡 120 宽、全屏 180 宽（高度按帧比例折算，不拉伸）。
/// - 非全屏布局（v2.17.0+ 重构；v2.17.17 横屏置顶模式）：
///   非全屏 = 视频区顶部置顶（按宽高比的黑盒，竖屏超高视频封顶屏高 60%、
///   横屏 16:9 封顶屏高 55%）+ 下方视频信息行（标题/时长 + UP 主入口——
///   阶段 C 加：圆形头像+名字可点进 UP 主页，番剧弱化为剧集标签；横屏自动
///   紧凑：标题 1 行/简介少行）+
///   **内嵌评论区**（[CommentListView]，与独立 [CommentPage]
///   共用同一实现，视频切换按 bvid+分P 重建刷新）。画面/弹幕/字幕/手势/
///   控制层全部绑定在视频区矩形内（不再整屏黑底、不覆盖下方评论区）。
///   设备竖放为竖屏布局；设备横放（v2.17.17）= 横屏「置顶+评论」形态——
///   退出全屏不再强制转竖屏（设备当前横放即停在该形态，旋转设备可在两态
///   间自由切换，见 [_toggleFullscreen]/[_PlayerPageState.build]）；离开播放
///   页恢复系统方向。
///   控制层「评论」按钮：非全屏（竖屏/横屏置顶）= 滚动定位到评论区，
///   横屏全屏 = 打开独立评论页（原行为）。全屏（横屏）保持整屏播放布局
///   （无下方内容区）。
/// - 播放错误自动续播（v2.17.14+，onUrlExpired）：原生把**可自动恢复**的数据源错误
///   （流 URL 过期 403/404/410/429/5xx + 瞬时网络错误：超时/断连/解析失败，含
///   2001 timeout）统一归为 onUrlExpired → Dart 重取 playurl → 记位置 →
///   setDataSource(新流, 位置) 续播（不弹错误打断观看）；续播失败按退避
///   1s→2s→4s 自动重试**有限次**（每段播放独立预算，成功 READY 清零），仍失败
///   才显示错误 + 重试按钮（手动兜底）
/// - 主动预取 + 平滑换源（v2.17.15+，根治「读到过期 URL → 2001/失败」的必然中断）：
///   实测 B 站流 URL deadline 有效期固定 **2 小时**（普通视频播放中不会到期，主因仍是
///   网络瞬时错误——由上方 v2.17.14 自动续播兜底）；但超长视频（>2h）/ 长时间暂停后
///   续播仍会用完 URL 剩余有效期 → 到期后读取必失败。播放中每 10s 解析当前网络流
///   deadline 并判定「剩余有效期不足以播完剩余内容 + 60s」→ 到期前主动重取 playurl
///   换新 URL（setDataSource+seek，URL 尚有效时切换，几乎无感）；deadline 缺失
///   （本地缓存等）不预取，回退被动 onUrlExpired
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

/// 非全屏视频区高度占屏高上限（v2.17.17 横屏置顶模式）：
/// 竖屏 60%（v2.17.0 起，超高视频如 9:16 封顶留出信息行/评论区）；横屏
/// （宽>高）屏高低、16:9 视频按屏宽换算的理想高度 ≈ 整屏高 → 封顶取略小
/// 的 55%，把更多剩余高度让给信息行与评论区（详见
/// [_PlayerPageState._embeddedVideoHeight]）。
const double kPortraitVideoHeightRatio = 0.6;
const double kLandscapeVideoHeightRatio = 0.55;

/// 底栏按钮行高度（选集/倍速/听视频/字幕/弹幕/评论/下载/全屏）。
///
/// [_PlayerPageState._buildSeekRowOnly] 要在进度条行下方留出同样的空档（见其
/// 注释），两条路径共用本常量。
///
/// 44 → **40**（v2.39.0，用户原话「视频播放窗口下方的功能栏太高。ui美术，
/// 比例需要改进」）：底栏是**叠在视频区里**的（见 `_buildVideoLayers`），收矮
/// 只会露出更多画面，不影响视频区 / 评论区高度。竖向内容的实测高度是 36.2dp
/// （算式见 `_barIconLabel`），44 里有 7.8dp 是纯空白——两行各收 4dp（本行 +
/// 进度条行 `_PlayerSeekBar.height`）一共让出 **8dp** 画面。**不往 36 收**：
/// 那会顶到内容且没有余量，中文字体在不同机型上的行高微差就会裁切。
///
/// 触摸目标：本行 40dp 高，但每格宽 51.4dp（411dp 屏 8 等分），实际可点区
/// 51.4×40dp 与改动前同量级；真正被 Android ≥44 规范约束的是进度条行
/// （细轨 + 拖动柄），它的下限单列在 `_PlayerSeekBar.height`。
const double _kBottomButtonRowHeight = 40;

/// 底栏控制行总高 = 进度条行（[_PlayerSeekBar.height]）+ 按钮行
/// （[_kBottomButtonRowHeight]）——v2.39.0 起 40 + 40 = **80**（改动前
/// 44 + 44 = 88）。
///
/// 从两个行高**推导**而不是写死 80：字幕层的悬浮基准
/// （[subtitleBottomOffset]）必须与控制行顶部保持定值间隙（全屏 30 / 非全屏
/// 12），写死数字的话下次再调行高就会静默错位——历史上 P5 把控制行 80 → 88
/// 时就得手工把两个基准各 +8，v2.39.0 再 -8，正是同一个隐患。
/// 上下集行 `_PlaylistRowHeight`（40）**不计入**：它只出现在有播放列表时，
/// 字幕让开的永远是下面两行。
const double kPlayerBottomBarHeight =
    _PlayerSeekBar.height + _kBottomButtonRowHeight;

/// 字幕悬浮基准（相对**视频区矩形底边**的 bottom 偏移，dp）——纯函数，为了
/// 把「字幕让开控制行」这条几何关系钉进单测（widget 层的字幕文本要在测试里
/// 真拉到字幕才出现，成本和脆弱度都高于直接测这条关系）。
///
/// 语义（v2.17.0+，v2.39.0 改控制行高度后仍成立）：
/// - 控制层**可见**：抬到控制行顶部之上，全屏 30 / 非全屏 12——这两个间隙是
///   历史观感值（全屏画面大、留白可以更松），与 [kPlayerBottomBarHeight] 相加
///   得到实际 bottom（全屏 110 / 非全屏 92，改动前是 118 / 100）。
/// - 控制层**隐藏**（沉浸观影）：贴画面底部，全屏 24 / 非全屏 16——与控制行
///   无关的历史取值，故不随控制行高度变化（防字幕跑偏）。
double subtitleBottomOffset({
  required bool fullscreen,
  required bool controlsVisible,
}) {
  if (!controlsVisible) return fullscreen ? 24 : 16;
  return fullscreen ? kPlayerBottomBarHeight + 30 : kPlayerBottomBarHeight + 12;
}

// ---------------------------------------------------------------------------
// 全屏画面变换（缩放 / 旋转 / 平移）的换算纯函数（v2.39.0+）
// ---------------------------------------------------------------------------
// 放在顶层（而不是 _PlayerPageState 的 static）的唯一理由是**可单测**：本仓库
// 的既有约定就是「几何/判定逻辑抽成顶层纯函数，widget 测试直接断言」（见
// decideMode / nextPanMode / seekTargetMs / subtitleBottomOffset）。
// 手势实现（Listener + 手算）见 [_PlayerPageState] 里的 _onViewPointer* 一节。

/// 平移偏移夹取：把 [offset] 夹在当前缩放/旋转下画面**允许外移的最大范围**内。
///
/// 语义：缩放后画面比可视区大，最多能拖到「画面边缘贴住可视区边缘」；缩放为 1
/// （画面本来就装得下）时只能为 0。旋转 90°/270° 时画面长短边互换，所以先按
/// 「旋转后的贴合尺寸」再算余量。余量 = (缩放后画面尺寸 - 可视区尺寸) / 2，
/// 负数取 0（画面比可视区小 → 不许拖）。
Offset clampViewOffset({
  required Offset offset,
  required double scale,
  required Size viewSize,
  required double aspectRatio,
  required double rotation,
}) {
  final maxX = viewPanLimit(
    scale: scale,
    viewWidth: viewSize.width,
    viewHeight: viewSize.height,
    aspectRatio: aspectRatio,
    rotation: rotation,
    horizontal: true,
  );
  final maxY = viewPanLimit(
    scale: scale,
    viewWidth: viewSize.width,
    viewHeight: viewSize.height,
    aspectRatio: aspectRatio,
    rotation: rotation,
    horizontal: false,
  );
  return Offset(
    offset.dx.clamp(-maxX, maxX),
    offset.dy.clamp(-maxY, maxY),
  );
}

/// 单轴可平移上限（px，≥0）：见 [clampViewOffset] 的语义。
double viewPanLimit({
  required double scale,
  required double viewWidth,
  required double viewHeight,
  required double aspectRatio,
  required double rotation,
  required bool horizontal,
}) {
  if (viewWidth <= 0 || viewHeight <= 0) return 0;
  final rotated = rotation % math.pi != 0; // 90° / 270°：长短边互换
  final aspect = aspectRatio > 0 ? aspectRatio : 16 / 9;
  // 画面在可视区内按 AspectRatio 居中后的「贴合尺寸」
  double w = viewWidth;
  double h = viewWidth / aspect;
  if (h > viewHeight) {
    h = viewHeight;
    w = viewHeight * aspect;
  }
  final boxW = rotated ? h : w; // 旋转 90° 后画面占的横向尺寸
  final boxH = rotated ? w : h;
  final scaledW = boxW * scale;
  final scaledH = boxH * scale;
  final limit = horizontal
      ? (scaledW - viewWidth) / 2
      : (scaledH - viewHeight) / 2;
  return limit > 0 ? limit : 0;
}

/// 双指捏合 → 缩放倍数：以**手势起始倍数**为基准乘「间距比」，钳制在
/// [kMinViewScale]..[kMaxViewScale]。
///
/// 用起始倍数 × 比值而不是逐帧累乘：逐帧累乘会把夹取损失与浮点误差滚进基准，
/// 捏到上限再松开时画面不会跟着回缩（手感「粘住」）。
/// [startSpan] ≤ 0（两指重合，极端）→ 保持起始倍数（不做除零）。
double viewScaleFromGesture({
  required double startScale,
  required double startSpan,
  required double span,
}) {
  if (startSpan <= 0 || span <= 0 || !span.isFinite) {
    return startScale.clamp(kMinViewScale, kMaxViewScale);
  }
  final next = startScale * (span / startSpan);
  return next.isFinite
      ? next.clamp(kMinViewScale, kMaxViewScale)
      : startScale.clamp(kMinViewScale, kMaxViewScale);
}

/// 旋转角**吸附到 90° 步进**并归一化到 [0, 2π)。
///
/// 为什么吸附：自由旋转必然出现 37° 这种歪画面——四角露黑边、字幕/弹幕又不
/// 跟着转，读起来像渲染坏了；B 站/iOS 播放器也都是 90° 档。
double snapViewRotation(double radians) {
  if (!radians.isFinite) return 0;
  final steps = (radians / kViewRotationStep).round();
  final snapped = steps * kViewRotationStep;
  final twoPi = 2 * math.pi;
  final normalized = snapped % twoPi;
  return normalized < 0 ? normalized + twoPi : normalized;
}

/// 把角度差归一化到 (-π, π]：两指连线方向 `Offset.direction` 的值域是
/// [-π, π]，跨界时会从 π 跳到 -π，直接相减会得到 ±2π 的假旋转。
/// 代价：单次手势最多转 ±180°（要 180° 就转两次），对 90° 档位足够。
double normalizeAngleDelta(double delta) {
  if (!delta.isFinite) return 0;
  final twoPi = 2 * math.pi;
  var d = delta % twoPi;
  if (d > math.pi) d -= twoPi;
  if (d <= -math.pi) d += twoPi;
  return d;
}

/// 「评论区滚动收起视频信息块」（竖屏非全屏）的方向判定阈值（px）。
///
/// 评论列表滚动时按**累积位移**判方向：连续向下翻（内容上移，scrollDelta > 0）
/// 累积到本阈值才收起信息块，反向累积到本阈值才展开——避免一有位移就切换
/// （手指微抖/惯性尾巴造成来回跳）。取 12px ≈ 一次轻微滑动的量级。
const double kInfoBarHideScrollThreshold = 12;

/// 播放页**非全屏**状态允许的方向（v2.17.17）：
/// 「竖屏 + 双向横屏」三向——退出全屏时不再强制回竖屏：设备横放停在横屏
/// 「顶部置顶+下方评论区」（横屏置顶模式），设备竖放仍竖屏置顶布局
/// （兼容 v2.17.0），之后旋转设备可在两态间自由切换。不含 portraitDown
/// （避免倒持误入）；离开播放页（dispose）仍恢复系统竖屏基准
/// （[_PlayerPageState._restoreSystemUi]）。
const List<DeviceOrientation> kPlayerPageFreeOrientations = [
  DeviceOrientation.portraitUp,
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

/// 播放源（v2.39.0+「本地缓存 / 网络流」二态切换）。
///
/// 背景（用户原话）：「当我缓存了一个视频的音频的时候，我就没法观看视频
/// 画面了。也就是说我需要一个切换本地播放和流媒体播放的东西」——**仅音频
/// 缓存**时不带视频轨，缓存命中就无条件走本地 → 永远看不到画面。用户没有
/// 别的出口（删缓存重看要重下整段），所以给播放页一个显式的源切换。
///
/// 语义边界：这不是清晰度档位，只回答「这一次取源走哪条路」。
/// - [local]：命中本地缓存就用本地文件（省流量、离线可看）——**默认值**，
///   与 v2.38.0 及以前的行为逐字节一致（含离线缓存页的「仅音频离线播放」
///   契约：那条路径进来也是 local）。
/// - [network]：强制走 [BiliApi] 取流那条既有路径（可看画面 / 更高清晰度），
///   代价是流量与 URL 过期后的重取（active 预取照常工作，见 [_netStreamDeadlineMs]）。
///
/// 与 [_audioOnlyPlayback]/[_listenMode] 正交：「源本身没有视频轨」（前者）
/// 和「用户主动隐藏画面」（后者）都不决定取源走哪条路——切到 [network]
/// 正是为了绕开「源没有视频轨」这件事。
enum PlaySource {
  /// 本地缓存优先（默认；缓存缺失时自然回落网络）。
  local,

  /// 强制网络取流（忽略本地缓存）。
  network,
}

/// 「接近正方形」的宽高比容差（|aspect - 1| ≤ 本值 → 视为正方形/近方形，
/// 进全屏**不锁方向**，避免在两向之间抖）。0.1 = 0.9 ~ 1.1，覆盖 1:1 与
/// 常见的近方形测试卡/录屏。
const double kFullscreenSquareAspectTolerance = 0.1;

/// 进全屏时应锁的方向（纯函数，v2.39.0+，可单测）。
///
/// 背景（用户原话）：「竖屏视频全屏之后还是竖屏，而不是现在的旋转九十度」——
/// 旧实现进全屏**无条件**锁 landscape 两向（[kPlayerPageFreeOrientations] 的
/// 横屏部分），竖屏视频（如 9:16）在横屏整屏里只占约 1/3 宽、左右大黑边。
///
/// 返回语义（**空列表 = 不下发方向命令**，保持设备当前方向）：
/// - [known] 为 false（宽高比还没拿到：`_onPrepared` 尚未上报）→ 返回
///   [kPlayerPageFreeOrientations]（"不锁"：竖屏 + 双向横屏都允许，用户可以
///   自由转，等画面就绪后由 `_onPrepared` 补一次锁）。这条兜底很要紧：全屏
///   按钮在 `!_loaded` 时也可点，而 [_aspectRatio] 初值是 16:9——不兜底就会
///   出现「竖屏视频被错锁横屏」的窗口；
/// - 接近 1:1（|aspect - 1| ≤ [kFullscreenSquareAspectTolerance]）→ 空列表，
///   两个方向都说得通，锁谁都会让另一半用户觉得错，保持现状最稳；
/// - 竖向（aspect < 1）→ 只锁 [DeviceOrientation.portraitUp]（**不含
///   portraitDown**：倒持全屏没有任何理由）；
/// - 横向（aspect > 1）→ 锁 landscape 两向（**与旧行为完全一致**，横屏视频
///   的既有体验零改动）。
///
/// 比例异常（NaN/∞/≤0，防御）→ 空列表（不下命令，不等于锁横屏）。
List<DeviceOrientation> fullscreenOrientationsFor(
  double aspectRatio, {
  bool known = true,
}) {
  if (!known) return kPlayerPageFreeOrientations;
  if (!aspectRatio.isFinite || aspectRatio <= 0) return const [];
  if ((aspectRatio - 1).abs() <= kFullscreenSquareAspectTolerance) {
    return const [];
  }
  return aspectRatio < 1
      ? const [DeviceOrientation.portraitUp]
      : const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
}

/// 全屏画面缩放的上下限（v2.39.0+，见 [_PlayerPageState._viewScale]）。
///
/// 下限 1.0：不支持缩小到比「贴合尺寸」更小——那只会露出更多黑边，没有任何
/// 信息量（视频播放器不需要「缩小看整幅」）。
/// 上限 4.0：1080P 画面在 411dp 宽的竖屏上放大 4 倍已经接近「逐字看字幕」的
/// 极限，再大就纯粹是马赛克；4 倍也刚好让单指平移有足够的可移动余量。
const double kMinViewScale = 1.0;
const double kMaxViewScale = 4.0;

/// 旋转档位步进（弧度）：π/2 = 90°。手势里的连续旋转角只用于判定换档。
const double kViewRotationStep = math.pi / 2;

class PlayerPage extends StatefulWidget {
  final WhitelistVideo video;

  /// 初始播放的分 P 下标（历史记录续播用：直接定位到上次看的那一集；
  /// 默认 0 = 第一集/单 P）。
  final int initialPageIndex;

  /// 初始定位进度（毫秒；评论视频链接 ?t / 跳转定位用，v2.17.6+）。
  ///
  /// >0 时首次 onPrepared 直接 seek 到该位置并**覆盖记忆进度**（语义=「跳到
  /// 链接指定的进度」，不弹「已从上次…继续」——用户明确要这个位置）；
  /// null/<=0 = 保持原有记忆进度恢复行为。
  final int? initialPositionMs;

  /// 进度条拖动预览的雪碧图服务（**仅测试注入用**；生产一律传 null，
  /// 由 [_PlayerPageState] 自建并在页面销毁时释放）。
  ///
  /// 存在的理由：预览是「接口就绪 → 缩略图；未就绪/失败 → 只显示时间气泡」
  /// 的双路行为，widget 测试要精确控制这两条路（fake fetcher/loader/decoder
  /// 必须注入到 service 里，而 service 由 State 持有）——注入点放在这里，
  /// 服务层接口一行不用改。
  @visibleForTesting
  final VideoShotService? videoShotService;

  /// 播放上下文（同合集 / 同 UP 主页的有序视频列表；v2.30.0+）。
  ///
  /// 传了才有「上一集 / 下一集」入口——**不传时一个像素都不多**（底栏结构与
  /// 改动前逐像素一致），历史记录 / 搜索 / 信箱 / 评论跳转等「语义不是同合集」
  /// 的入口一律不传（详见 [PlaylistContext] 类注释与底栏「上下集」行注释）。
  final PlaylistContext? playlist;

  /// 本视频在 [playlist] 中的下标（0 起；调用方按列表页看到的顺序给）。
  /// 越界时按 0 处理（防御：列表在别处被改过也不至于崩）。
  final int playlistIndex;

  const PlayerPage({
    super.key,
    required this.video,
    this.initialPageIndex = 0,
    this.initialPositionMs,
    this.videoShotService,
    this.playlist,
    this.playlistIndex = 0,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with RouteAware, SingleTickerProviderStateMixin {
  /// 当前播放的视频（initState 初始化为 _video；内部换源（[playVideo]）后
  /// 更新为被换视频）。标题/取流/弹幕/下载/历史/评论等一律以 [_video] 为准
  /// ——换源后仍引用 _video 会把旧视频记进历史/进度、下载与评论串到旧视频
  /// 上。v2.17.1+ 评论链接改走「push 新播放页」（[openVideoInNewPlayer]），
  /// 不再改动本页 [_video]（本页暂停在旧视频 A 上，返回后续播 A）。
  late WhitelistVideo _video;

  // -------------------------------------------------------------------------
  // 播放上下文（同合集 / 同 UP 主页的上下集切换，v2.30.0+）
  // ---------------------------------------------------------------------
  // 三个字段都在 initState 里按构造参数一次性落定（见 [PlayerPage.playlist]）。
  // [_playlistVideos] 为 null = 本次没有播放列表 → 底栏**不构建**上下集行
  // （不是禁用、是整行不存在），行为与改动前逐像素一致。
  //
  // ⚠️ 这里刻意**不放进 [playVideo] 的复位清单**：换 bvid 只移动下标，
  // 列表本身属于「这次是从哪个列表点进来的」，不随换源改变（同一合集内切
  // 邻居时列表当然不变；这也正是「不接管评论跳转来的新页」的原因，见
  // [_pushNewPlayer] 的注释）。
  List<WhitelistVideo>? _playlistVideos;
  int _playlistIndex = 0;
  String? _playlistLabel;

  /// 一次换源未走完时挡住连点（[playVideo] 内部有 await，连点两次会叠两次
  /// 取流；通知栏/遥控器的「下一集」尤其容易连发）。
  bool _neighborSwitching = false;

  /// 是否显示「上一集 / 下一集」入口：至少两条才有去处——一条时上下集都是
  /// 死按钮，按「无播放列表」处理（不显示）。
  bool get _hasPlaylistNeighbors =>
      _playlistVideos != null && _playlistVideos!.length > 1;

  bool get _canPlayPrev => _hasPlaylistNeighbors && _playlistIndex > 0;

  bool get _canPlayNext =>
      _hasPlaylistNeighbors && _playlistIndex < _playlistVideos!.length - 1;

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

  /// 宽高比是否**真的**来自播放器（[_onPrepared] 的 width/height）。
  ///
  /// 为什么不能只看 `_aspectRatio != 16/9`：16:9 是初值也是真实值（绝大多数
  /// 视频就是 16:9），两者无法区分；而进全屏的方向策略（v2.39.0，
  /// [fullscreenOrientationsFor]）必须知道「这个比例是真的还是占位初值」——
  /// 占位值下把竖屏视频锁成横屏正是要修的那个 bug。
  /// 置 false 的时机：换源换 bvid（[playVideo]）、切分 P（[_switchToPage]）——
  /// 新源的宽高比未知，等它的 [onPrepared] 再判定；若此刻正好在全屏，
  /// [onPrepared] 会补一次锁。
  bool _aspectKnown = false;

  // 信息块「补场」动画（块化与动效系统 · 批次 C）
  // ---------------------------------------------------------------------
  // 用户从卡片点进播放页时：卡片封面先由 Hero 飞进视频区落位（[kHeroFlightDur]
  // 340ms），信息块延迟 [kInfoBlockDelay] 后再淡入 + 从 [kInfoBlockScaleFrom]
  // 96% 微放大到位（[kInfoBlockDur] 320ms）——两段在时间轴上重叠，读起来像
  // 「先落画面、文字跟上」的因果，而不是一个没有来处的整页闪现。
  //
  // 不做「卡片副标题 → 视频标题」的字面 morph：Hero 是**一对一**机制，而两端
  // 的尺寸/结构差太远（卡片 tag 是一行小字，信息块是标题 + UP 行 + 简介的多行
  // 块），插值中间态必然是一坨被拉扁的畸形文字；「整块补场」拿到了同样的因果
  // 观感，代价只是两个 token，且不引入任何跨 route 的共享状态。
  late final AnimationController _infoBlockCtl = AnimationController(
    vsync: this,
    duration: kInfoBlockDelay + kInfoBlockDur,
  );

  /// 补场动画已播完 → 信息块恢复成裸块（树里不留 FadeTransition/Transform）。
  bool _infoBlockDone = false;

  // 封面占位层（「封面放大变成播放界面」的假转场）
  // ---------------------------------------------------------------------
  // 播放页画面是原生纹理（BiliDashTexture），Hero 没法跨进 Texture 里，所以
  // 转场做成：Hero 把封面从卡片飞进视频区、落在**同一个 AspectRatio 盒**里的
  // 封面占位层上，等播放器就绪（或兜底超时）后这一层淡出，露出真实画面。
  //
  // 三态字段分工：[_coverOverlayVisible] = 这一层是否还留在树里；
  // [_coverOverlayOpaque] = 不透明度目标值（淡出中/已透明）。
  // 两个都只在本页首次出现时用——全屏/横竖屏切换、换源都不会重播（不进
  // [playVideo] 的复位清单）。[_video].cover 为空时**整层不构建**（零开销、
  // 零网络请求），兜底计时器也不排。
  bool _coverOverlayVisible = true;
  bool _coverOverlayOpaque = true;

  /// 封面占位层的兜底淡出计时器（播放器/cid=0 等取流卡死时不至于让封面常驻）。
  Timer? _coverFallbackTimer;

  /// 淡出动画结束后把这一层移出树（[kCoverFadeOutDur] 之后）。
  Timer? _coverTeardownTimer;

  /// 封面占位层的兜底淡出时限：正常由 onPrepared / 错误态触发，这里是
  /// 「播放器一个回调都没来」时的保底。
  static const int kCoverOverlayFallbackMs = 1200;

  /// 控制层
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _dragging = false;

  // 进度条拖动预览（缩略图 + 时间浮层）
  // ---------------------------------------------------------------------
  // 数据/解码/缓存全部由 [VideoShotService] 负责（按需下载 + 降采样 + LRU +
  // 并发去重），本页只做三件事：进页异步 prepare、拖动时异步取「当前格」的
  // 图、把结果画成跟随手指的浮层。预览是**纯增强**：接口挂了 / 网络断了 /
  // prepare 还没回来，一律降级成「只显示时间气泡」，绝不影响拖动与播放。
  //
  // 三个字段分工：
  // - [_previewFrame] 当前可画的帧（null = 只显示时间气泡）；
  // - [_previewGen] **拖动代次**：每轮拖动起手/结束、切集/换源时自增。异步结果
  //   回来时代次不等 = 这轮已经不是当前轮（浮层已隐藏/已复位）→ 丢弃；
  // - [_previewShot] 最近一次已发起请求的「格」序号，用作**节流**：同一格
  //   （≈同一秒）不重复发请求（服务层虽有 LRU + in-flight 去重，每帧发一次
  //   仍是白费）。
  //
  // 注意这里**没有**「请求序号」：判一个迟到结果该不该落地，看的是它属于哪张
  // 雪碧图（[SeekPreviewFrame.spriteIndex] vs 当前位置需要的张号），不是它排
  // 第几个发出——同张图内的迟到结果依然可用，按序号判会把首次拖动整条丢掉。
  VideoShotService? _videoShot;

  SeekPreviewFrame? _previewFrame;
  int _previewGen = 0;
  int _previewShot = -1;

  /// 想预取的播放位置（ms）：服务未就绪时先记下，等元信息到位后补取
  /// （见 [_prefetchVideoShotAt] / [_prepareVideoShot]）。
  int? _prefetchWantMs;

  /// [_previewFrame] 引用的雪碧图下标：换张前先扔掉手里的旧帧——LRU（容量 2）
  /// 淘汰时会 `dispose()` 旧图，继续画一张已释放的图会触发断言。
  int _previewSprite = -1;

  /// 本轮拖动是否已开始（拖动起手时清帧/复位节流，见 [_onSeekDragPosition]）。
  bool _previewDragActive = false;

  /// 手指在进度条轨道上的水平位置（轨道局部坐标，0..[_previewTrackWidth]）。
  double _previewDragX = 0;

  /// 拖动轨道可用宽度（浮层横向夹取用；0 = 尚未回报 → 不显示浮层）。
  double _previewTrackWidth = 0;

  // 非全屏内嵌评论区（v2.17.0+ 布局重构；v2.17.17 横屏置顶模式共用）：
  // ---------------------------------------------------------------------
  // 非全屏（竖屏置顶 / 横屏置顶）时视频下方内嵌 [CommentListView]（与独立
  // [CommentPage] 共用同一组件）。_commentScroll 为列表的外部滚动控制器
  // （点控制层「评论」按钮时定位用；独立页/全屏时该列表不在树中，控制器
  // 仍持有多余无妨）；_commentCountHeaderKey 挂在列表顶部「评论 N」区头
  // 上，供 Scrollable.ensureVisible 锚定滚动到评论区。
  final ScrollController _commentScroll = ScrollController();
  final GlobalKey _commentCountHeaderKey = GlobalKey();

  // 评论滚动 → 信息块收起/展开（竖屏非全屏专用）：
  // ---------------------------------------------------------------------
  // 向下翻评论（内容上移，`scrollDelta > 0`）= 想看评论 → 把标题/简介块收起，
  // 高度让给评论列表；向上翻（内容下移）再放回来；滚到列表顶部强制展开
  // （回到顶部就该看见标题）。判定与动画见 [_onCommentScrollNotification] /
  // [_buildCollapsibleInfoBlock]。
  /// 信息块当前是否因评论滚动而收起（仅竖屏非全屏渲染时生效）。
  bool _infoBarCollapsed = false;

  /// 方向判定的累积位移（px，正 = 内容上移 = 向下翻评论）。达到
  /// [kInfoBarHideScrollThreshold] 就切换一次并清零，故取值被夹在阈值内。
  double _infoBarScrollAccum = 0;

  /// 本轮滚动是否由**手指拖拽**发起（含其后惯性段）。
  /// 程序化滚动（点控制层「评论」的 `Scrollable.ensureVisible` / `animateTo`）
  /// 不算 → 不参与收起判定（不然点个按钮标题就没了）。
  bool _commentScrollByUser = false;

  // 信息行 UP 主入口（阶段 C，仿 B 站）
  // ---------------------------------------------------------------------
  // WhitelistVideo 无 mid/face → 运行时 fetchVideoMeta(bvid) 拿 view 接口
  // data.owner 补齐（_refreshUpownerMeta，结果按 bvid 缓存在 _upMetaCache）。
  // _ownerMeta 为当前视频的 UP 主信息（null = 未拉取/失败/番剧无入口）。
  // 换源（playVideo 换 _video）后必须复位重拉，防止残留上一个视频的 UP。
  ({int mid, String name, String face})? _ownerMeta;

  // _runtimeDesc：当前视频的运行时简介（v2.17.3+，旧数据无 desc 时搭 UP
  // 元数据那次 view 请求补拉，见 viewDescOf/_viewDescCache）。显示优先级：
  // WhitelistVideo.desc 非空用它；为空才用 _runtimeDesc（旧数据/评论链路上
  // 用 videoFromMeta 现构的无 desc 视频）。换源复位。
  String _runtimeDesc = '';

  // 写操作（点赞 / 投币 / 收藏，v2.40.0+）
  // ---------------------------------------------------------------------
  // 初始态来自两路请求：view 那次（owner/desc/stat/aid）与 **v2.41.0 新增的
  // `archive/relation`**（真实互动态）。view **不下发 `req_user`**（匿名与
  // 登录都不下发，v2.40.0 三处实测），所以真实态只能靠 relation：
  // - _relation：relation 接口给的**真实**互动态（拿到 → 按钮显示真值、
  //   不显示降级标注）；null = 没取到（未登录/失败），此时退回 [_reqUser]，
  //   两者都没有就只做"本次会话内乐观切换"，UI 如实标注"重启后可能显示不准"；
  // - _reqUser：view 的 `data.req_user`（保留给旧路径与既有测试夹具）；
  // - _viewStat：view 的 `data.stat`（公开展示计数），按钮上的数字用它；
  // - _writeAid：view 的 `data.aid`——写接口只认 aid。它同时也被下面三个
  //   按钮的可用性依赖（拿不到 aid 的番剧集/接口失败时不显示按钮）。
  // 换源（playVideo 换 _video）后必须复位，防止把上一个视频的点赞态带过来。
  VideoRelation? _relation;
  VideoReqUser? _reqUser;
  int? _writeAid;

  /// 点赞数的**可显示值**：初始 = view 的 `stat.like`，本页点赞/取消时 ±1。
  ///
  /// 单独一个字段而不是从 `stat` 现算：现算要反推"初始时我赞没赞过"，
  /// 而那个信息在降级路径（[_reqUser] 为 null）里根本没有——用可变的显示值
  /// 最不容易算错，回滚时也只是把 ±1 还回去。
  ///
  /// （投币数/收藏数不展示：接口的 `stat.coin`/`stat.favorite` 是**全站**计数，
  /// 与"我投没投/收没收藏"不是一回事，摆出来反而容易被读成"我投了 1.2 万枚"。）
  int _likeCount = 0;

  /// 三个按钮的**会话内**真实态（初始值取 [_reqUser]，之后由本页乐观维护）。
  bool _liked = false;
  bool _coined = false;
  bool _faved = false;

  /// 写请求在飞（防连点：一次只放行一个写动作，三个按钮一起置灰）。
  bool _writeBusy = false;

  // 全屏画面变换（缩放 / 旋转 / 平移，v2.39.0+）
  // ---------------------------------------------------------------------
  // 需求（用户原话）：「全屏模式下可以手势放大，旋转视频窗口。注意不要和之前
  // 的手势冲突」。三个字段在**非全屏永远保持默认值**（[kMinViewScale]..4.0 的
  // 缩放、90° 步进的旋转、缩放态下的单指平移都只在全屏生效）：
  // - 非全屏视频区只有 ~231dp 高，放大/旋转后能看到的有效内容反而更少；
  // - 且非全屏的横滑是 seek（用户验收过的三向语义），让画面变换插进来会把
  //   单指拖动的判断搅乱（[kPanModeThreshold] 那套豁免/锁定逻辑只认单指）。
  //
  // v2.43.0 起**双指「让位」不再只在全屏**（[kPanModeThreshold] 那条注释里
  // "非全屏双指可能被当单指拖动去 seek" 的已知限制已修）：非全屏的双指同样会
  // 让单指三向语义整体让位（不 seek / 不调亮度音量），但不做任何变换——
  // 见 [_viewTransformEnabled] 与 [_applyViewGesture] 的取舍说明。
  //
  // 复位时机：退出全屏（[_toggleFullscreen]）、换 bvid（[playVideo]）、切分 P
  // （[_switchToPage]）——三者都会让「画面窗口」换一个坐标系。另有可见的复位
  // 按钮（底栏，仅缩放态出现，见 [_buildBottomBar]）。
  // 渲染（[Transform]）只包**画面本身**，手势层仍在 Transform 之外：否则缩放后
  // 「点画面显隐控制层」的命中区会跟着变形（点空白处不再显隐）。字幕/弹幕层
  // 同样不参与变换——B 站也是这个层级（字幕/弹幕跟着屏幕走，不跟着画面平移）。
  /// 画面缩放倍数（1.0 = 原始大小；范围 [kMinViewScale]..[kMaxViewScale]）。
  double _viewScale = 1;

  /// 画面平移偏移（**视频区坐标系内的逻辑像素**；缩放态下单指拖动累加）。
  /// 偏移量按当前缩放与区域尺寸夹取（见 [clampViewOffset]），保证画面不会
  /// 被拖出可视区之外。
  Offset _viewOffset = Offset.zero;

  /// 旋转（弧度，恒为 90° 的整数倍：0 / π/2 / π / 3π/2）。
  ///
  /// **吸附到 90° 步进**而不是自由角度：自由旋转必然出现 37° 这种歪画面，四角
  /// 露黑边、字幕/弹幕又不会跟着转，读起来像渲染坏了；B 站/iOS 播放器的旋转
  /// 也是 90° 档。吸附换算在顶层纯函数 [snapViewRotation] 里（可单测）。
  double _viewRotation = 0;

  /// 本轮双指手势的起始状态（手势期间在起点值上叠加增量，不逐帧累加）：
  /// 逐帧累加会把浮点误差和夹取损失滚进基准，松手再捏合时手感会漂。
  double _viewScaleStart = 1;
  double _viewRotationStart = 0;
  Offset _viewPanStart = Offset.zero;

  /// 多指手势是否正在进行（供 [_onPanDown] 等单指回调让路：双指期间单指拖动
  /// 不能去 seek/调亮度）。
  bool _viewGestureActive = false;

  /// 复位画面变换（退出全屏 / 换 bvid / 切集 / 点复位按钮）。
  ///
  /// 同时**清掉双指手势状态**。v2.39.0 时这么做是因为"退出全屏 → Listener 回调
  /// 被摘掉 → [_viewGestureActive] 会永远停在 true → 单指拖动全哑"；v2.43.0 起
  /// 回调不再随全屏开关摘换（非全屏也跟踪双指以保证让位），但这里照旧清一次：
  /// 换 bvid / 切集时用户手上那次双指已经失去意义（画面窗口换了坐标系），
  /// 留着 active 只会让接下来第一下拖动被白白让位掉。
  void _resetViewTransform() {
    _viewPointers.clear();
    _viewPanRaw = Offset.zero;
    final changed = _viewScale != 1 ||
        _viewOffset != Offset.zero ||
        _viewRotation != 0 ||
        _viewGestureActive;
    if (!changed) return;
    debugPrint('[player_page] 画面变换复位（scale=$_viewScale rot=$_viewRotation）');
    if (!mounted) {
      _viewScale = 1;
      _viewOffset = Offset.zero;
      _viewRotation = 0;
      _viewGestureActive = false;
      return;
    }
    setState(() {
      _viewScale = 1;
      _viewOffset = Offset.zero;
      _viewRotation = 0;
      _viewGestureActive = false;
    });
  }

  // -------- 双指缩放 / 旋转 / 平移的手势实现（v2.39.0+） --------
  // 实现方式：**原始指针事件（Listener）+ 自己算变换**，不用 ScaleGestureRecognizer。
  //
  // 为什么不用 ScaleGestureRecognizer（实测依据，不是猜的）：
  // Flutter 3.32 的 `ScaleGestureRecognizer._advanceStateMachine`（
  // packages/flutter/lib/src/gestures/scale.dart:731-741）在 **单指** 时也判定
  // `focalPointDelta > computePanSlop(...)` → `resolve(accepted)`——即单指拖动
  // 一旦超过 slop，scale 识别器就**赢下竞技场**、把同场竞争的 Pan 挤掉。而
  // onScaleStart 是「已经赢下竞技场之后」才回调的，那时候按 pointerCount 让位
  // 已经晚了（Pan 那一轮已被判负、onPanStart 不会再来了）→ 用户验收过的三条
  // 单指 seek 用例会直接挂掉。所以「在 onScaleStart 里按 pointerCount 让位」
  // 这条方案在本项目**不可行**（本机 Flutter 源码逐行核对 + widget 测试验证）。
  //
  // 换成 Listener 的好处：Listener 不参与手势竞技场，只在命中路径上旁观原始
  // 事件 → 单指拖动仍然完全落在原来的 Pan 识别器手里（三向语义逐字不变、
  // 零回归），双指则由我们自己按 pointerId 配对计算。代价是要自己写几何换算，
  // 但那部分本来就抽成了顶层纯函数（[viewScaleFromGesture] /
  // [snapViewRotation] / [clampViewOffset]），可单测。

  /// 双指**变换**（缩放/旋转/平移）是否启用：**只在全屏**（见 [_viewScale]
  /// 字段注释：非全屏视频区太矮，放大反而看不到东西）。
  ///
  /// ⚠️ 注意它**不**控制"是否跟踪双指 / 是否让位"——那个始终开着
  /// （v2.43.0 起，见 [_onViewPointerDown] 与 [_applyViewGesture]）：
  /// 非全屏双指虽然不变换画面，但必须让单指三向语义整体让位，否则一次捏合
  /// 会被 Pan 识别器当成长横滑 → **莫名 seek**（用户在这一版之前遇到的就是
  /// 这个：他只想捏合看细节，进度却跳了）。
  bool get _viewTransformEnabled => _fullscreen;

  /// 当前按下的指针（pointerId → 手势层局部坐标）。只用于双指换算。
  ///
  /// v2.43.0 起**非全屏也记录**（旧实现在非全屏直接 return）：记录 + 配对是
  /// 「双指让位」的判据来源，而让位是全屏/非全屏都要的。代价只是两个 int/double
  /// 的字典操作，且非全屏不变换画面（[_applyViewGesture] 早退）。
  final Map<int, Offset> _viewPointers = <int, Offset>{};

  /// 本轮双指手势的起始双指间距 / 起始连线角度 / 起始焦点。
  double _viewStartSpan = 0;
  double _viewStartAngle = 0;
  Offset _viewStartFocal = Offset.zero;

  /// 单指平移的**未夹取**累计偏移（夹取只在取值时做，避免「贴边后回不来」）。
  Offset _viewPanRaw = Offset.zero;

  /// 长按 2x 是否生效中（双指接管时要把它放掉，见 [_onLongPressStart]）。
  bool _longPressSpeedActive = false;

  void _onViewPointerDown(PointerDownEvent e) {
    _viewPointers[e.pointer] = e.localPosition;
    if (_viewPointers.length >= 2) _beginViewGesture();
  }

  void _onViewPointerMove(PointerMoveEvent e) {
    if (!_viewGestureActive) return;
    if (!_viewPointers.containsKey(e.pointer)) return;
    _viewPointers[e.pointer] = e.localPosition;
    if (_viewPointers.length < 2) return;
    _applyViewGesture();
  }

  void _onViewPointerUp(PointerEvent e) {
    if (_viewPointers.remove(e.pointer) == null) return;
    if (_viewPointers.length < 2 && _viewGestureActive) {
      // 少于两指：双指手势结束（剩下那一指若继续拖 → 走「缩放态单指平移」，
      // 与松手后再按一指的语义一致）
      if (mounted) {
        setState(() => _viewGestureActive = false);
      } else {
        _viewGestureActive = false;
      }
      _viewPanRaw = _viewOffset;
    }
  }

  /// 双指就位（第二指按下 / 第三指加入）：接管手势 + 取本轮基准。
  ///
  /// 取「当前值」作基准而不是上次的起点：第三指加入或双指抬手再按都能从画面
  /// 当前状态接着走，不会跳变。
  void _beginViewGesture() {
    // 单指那一轮可能在做的 seek / 亮度音量 / hud 一并作废（双指接管）
    _onPanCancel();
    // 长按 2x 若正生效：双指手势要看清画面，先放回原速（否则捏合一直在 2x）
    if (_longPressSpeedActive) {
      _longPressSpeedActive = false;
      _applySpeed(_speedBeforeLongPress);
    }
    final ids = _viewPointers.keys.toList();
    final p1 = _viewPointers[ids[0]]!;
    final p2 = _viewPointers[ids[1]]!;
    _viewScaleStart = _viewScale;
    _viewRotationStart = _viewRotation;
    _viewPanStart = _viewOffset;
    _viewPanRaw = _viewOffset;
    _viewStartSpan = (p2 - p1).distance;
    _viewStartAngle = (p2 - p1).direction;
    _viewStartFocal = (p1 + p2) / 2;
    debugPrint('[player_page] 双指手势开始 span=${_viewStartSpan.toStringAsFixed(1)} '
        'scale=$_viewScale rot=${_viewRotation.toStringAsFixed(2)}');
    if (!_viewGestureActive) {
      setState(() => _viewGestureActive = true);
    }
  }

  /// 双指移动 → 换算缩放 / 旋转（90° 吸附）/ 平移，并同步渲染。
  ///
  /// **非全屏在这里早退**（v2.43.0）：非全屏的双指只做「让位」（见
  /// [_onViewPointerDown]），不改画面 —— 画面变换仍按 v2.39.0 的设计只在全屏
  /// 生效（原因见 [_viewScale] 字段注释）。早退放在**换算之前**是为了不改动
  /// [_viewScaleStart] 等基准（非全屏来回捏几次不会给全屏攒下状态）。
  void _applyViewGesture() {
    if (!_viewTransformEnabled) return;
    final ids = _viewPointers.keys.toList();
    final p1 = _viewPointers[ids[0]]!;
    final p2 = _viewPointers[ids[1]]!;
    final span = (p2 - p1).distance;
    final angle = (p2 - p1).direction;
    final focal = (p1 + p2) / 2;
    final scale = viewScaleFromGesture(
      startScale: _viewScaleStart,
      startSpan: _viewStartSpan,
      span: span,
    );
    final rotation = snapViewRotation(
      _viewRotationStart + normalizeAngleDelta(angle - _viewStartAngle),
    );
    final rawOffset = _viewPanStart + (focal - _viewStartFocal);
    _viewPanRaw = rawOffset;
    setState(() {
      _viewScale = scale;
      _viewRotation = rotation;
      _viewOffset = clampViewOffset(
        offset: rawOffset,
        scale: scale,
        viewSize: _gestureAreaSize(),
        aspectRatio: _aspectRatio,
        rotation: rotation,
      );
    });
  }

  /// 缩放态下的单指平移（v2.39.0+，iOS / YouTube / B 站 的通行做法）。
  ///
  /// 只在 [_viewTransformed] 时启用：[_viewScale] == 1 且无旋转时**完全走原来的
  /// 三向判定**（用户验收过的 seek / 亮度 / 音量语义零改动）。
  void _onViewPanUpdate(DragUpdateDetails d) {
    final raw = _viewPanRaw + d.delta;
    _viewPanRaw = raw;
    final offset = clampViewOffset(
      offset: raw,
      scale: _viewScale,
      viewSize: _gestureAreaSize(),
      aspectRatio: _aspectRatio,
      rotation: _viewRotation,
    );
    if (offset == _viewOffset) return;
    setState(() => _viewOffset = offset);
  }

  /// 画面是否处于「变换态」（缩放 / 旋转生效）——决定单指拖动是平移还是 seek，
  /// 也决定底栏「复位」入口是否出现。
  bool get _viewTransformed => _viewScale != 1 || _viewRotation != 0;

  // B 站式快捷手势（v2.16.7+）
  // -------------------------------------------------------------------
  // 双击播放/暂停：GestureDetector onDoubleTap；单击显隐因与双击共存自动
  // 延迟 ~300ms（等双击窗口判定，双击赢得则单击取消，不误触显隐）。
  // 滑动统一走单一 Pan（v2.16.9+）：位移累计超 [kPanModeThreshold] 按主导
  // 方向锁定（[decideMode]）——horizontal → seek（v2.18.x 起竖屏 / 横屏
  // 统一可用，见 [canGestureSeek]）；vertical → 起点半屏亮度/音量（横竖屏
  // 都可用）。锁定后本次手势不再切换
  // （防中途抖动）；seek 拖动中暂停 tick 位置刷新（松手 seek 后恢复）。
  double _panStartX = 0; // 手势起点 x（垂直模式按半屏判亮度/音量）
  bool _panExcluded = false; // 起点在豁免带（v2.16.17+ 顶/左右，v2.18.x 底部仅全屏）→ 本次 Pan 整体忽略
  PanSlideMode? _panMode; // 已锁定的主导方向（null = 未定，继续累计判定）
  double _panDx = 0; // 手势累计横向位移（px，仅锁定判定用）
  double _panDy = 0; // 手势累计纵向位移（px，仅锁定判定用）
  bool _seekDragging = false; // seek 拖动中（锁定 horizontal 且允许 seek 后）
  // 手势 seek 的 UI 态（与拖进度条的 [_dragging] 并列）：手柄要跟着手指走、
  // 预览气泡要贴着进度条，而控制层可能正收着（那时进度条不在树里，见
  // [_buildSeekRowOnly]）。松手 / 手势被系统打断即复位。
  bool _gestureSeeking = false;
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

  /// 本次播放的源是「仅音频缓存」（只缓存了音频 → 没有画面可渲染）。
  ///
  /// 与 [_listenMode] 的区别：听视频是**用户主动**隐藏画面（源本来有画面）；
  /// 这个是**源本身没有视频轨**——不提示的话用户会以为播放器坏了（黑屏有声）。
  /// 网络取流 / 整段缓存的路径一律复位 false（见 [_setAudioOnlyPlayback]）。
  bool _audioOnlyPlayback = false;

  // 播放源（v2.39.0+「本地缓存 / 网络流」切换，见 [PlaySource]）
  // ---------------------------------------------------------------------
  // 只决定「这一次取源走哪条路」，与 [_audioOnlyPlayback]（源本身有没有视频轨）
  // 和 [_listenMode]（用户是否主动隐藏画面）正交。
  //
  // 复位时机：换 bvid（[playVideo]）→ 回 [PlaySource.local]（新视频重新按「有
  // 缓存就用缓存」判定，不让上一个视频的选择串台）；**切分 P 不复位**——同一条
  // 视频里用户的意愿是一样的（在选集与「看网络画面」之间来回切很烦），且新分 P
  // 无缓存时 [PlaySource.local] 本来就会自然回落网络，不会有死路。
  PlaySource _playSource = PlaySource.local;

  /// 正在切换播放源（防连点：本方法内部有 await 取流，连点会叠两次 setDataSource）。
  bool _sourceSwitching = false;

  /// 置位/复位「仅音频缓存播放」标记（值不变则不动，避免多余重建）。
  void _setAudioOnlyPlayback(bool value) {
    if (_audioOnlyPlayback == value) return;
    if (!mounted) {
      _audioOnlyPlayback = value;
      return;
    }
    setState(() => _audioOnlyPlayback = value);
  }

  // 媒体通知（v2.25.x：B 站式播放通知 + 耳机按键控制）
  // ---------------------------------------------------------------------
  // 播放状态变化时调 _syncNowPlaying 把标题/UP/封面/状态推给原生媒体通知；原生侧
  // 通知上的操作（播放暂停/快退快进/关闭）经 onMediaAction 事件回传，见 [_onMediaAction]。

  /// 原生播放器已被通知栏「关闭（✕）」停止（媒体项被清空）。
  ///
  /// 置位后界面按「已停止」显示：再点播放需要重新取流（[_init]），因为原生播放器
  /// 已经没有可播的源了。伪事件（如换源瞬间媒体项暂时为空）会在下一次
  /// [onPrepared] 里自动复位，所以这个标志不会把界面卡在停止态。
  bool _stoppedByNotification = false;

  /// 通知权限（Android 13+）是否已请求过：每个播放页只请求一次。
  bool _notifPermissionRequested = false;

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
    final pages = _video.pages;
    return (pages == null || pages.isEmpty) ? null : pages;
  }

  /// 当前集的 cid：多 P → pages[_currentPageIndex].cid；单 P → 顶层 cid。
  int get _currentCid {
    final pages = _pages;
    if (pages != null) return pages[_currentPageIndex].cid;
    return _video.cid;
  }

  /// 当前集的 part 标题（多 P 时用于 TopBar/占位界面展示）。
  String get _currentPartTitle {
    final pages = _pages;
    if (pages != null) return pages[_currentPageIndex].part;
    return _video.title;
  }

  // 错误 / 过期
  String? _error;
  bool _loginPrompt = false;
  bool _canRetry = true;

  // 自动续播（流 URL 过期 / 瞬时网络错误，v2.17.14+）
  // ---------------------------------------------------------------------
  // 原生把「可自动恢复的数据源错误」统一发 onUrlExpired 事件，Dart 重取
  // playurl 续播（保留位置）。网络抖动可能一次不成功，按退避重试有限次：
  // [_autoRecoverFails] 连续失败计数（新流成功 READY / 手动重试 / 换源 /
  // 重进清零 → 每段播放独立的恢复预算）；[_autoRecovering] 续播流程进行中
  // 防重入（原生错误事件可能比 Dart 处理快）。
  int _autoRecoverFails = 0;
  bool _autoRecovering = false;

  // 主动预取 + 平滑换源（流 URL deadline 到期前换新 URL，v2.17.15+）
  // ---------------------------------------------------------------------
  // 见文件顶部「流 URL deadline 解析 + 主动预取换源决策」纯函数与类注释。
  // [_prefetching] 与 [_autoRecovering] 互斥（入口各自检查对方），避免与
  // 被动自动续播并发换源造成双 setDataSource；[_initSession] 代次校验在
  // await 间隙播放器被重建（重进/手动重试/换源）时安全退出。
  /// 当前网络流 URL 的过期时刻（epoch 毫秒）。null = 本地缓存播放 / 上条流
  /// 未带 deadline / 尚未取到——此时不预取，回退被动 onUrlExpired 续播。
  int? _netStreamDeadlineMs;

  /// 主动预取换源流程进行中（防重入；也供被动自动续播让路，见 [_onAutoRecover]）。
  bool _prefetching = false;

  /// 上次预取尝试的墙钟毫秒（成功/失败都占位：防网络异常时 10s 周期反复打
  /// playurl；见 [kPrefetchMinIntervalMs]）。
  int _lastPrefetchAttemptMs = 0;

  /// 播放器重建代次：_init 每次（首次进入/手动重试/换源/切集后恢复）自增。
  /// 自动续播流程 await 间隙若有重建（_init 必经），凭代次差异安全退出，
  /// 防止向新播放器重复 setDataSource 造成双源竞争。
  int _initSession = 0;

  String? _loginExpiryText;

  /// 进度/字幕轮询定时器（500ms 一次 [_tick]）。
  ///
  /// 生命周期约定：**同一时刻最多一个**，且「取消」必须伴随置 null（或交给
  /// [_ensureTickTimer] 用 `isActive` 判定后重建）——`Timer` 被 cancel 后引用
  /// 仍是非 null 的**死实例**，一旦有人用 `??=` 想去「确保它在跑」，拿到的就是
  /// 这个死实例，于是进度条/字幕从此不再刷新（v2.25.0 修的即此类 bug）。
  Timer? _timer;

  // 播放进度记忆（本地 shared_preferences，按 bvid+pageIndex 分别记忆）
  PlaybackProgress? _progressStore;

  /// 下一次 onPrepared 时是否恢复记忆进度：
  /// 首次进入 / 手动切集 / 手动重试后为 true（恢复对应集的进度）；
  /// URL 过期续播等自动换源不置 true（沿用续播位置，不被记忆覆盖）。
  bool _pendingRestore = true;

  /// 下一次 onPrepared 时**直接定位**的位置（毫秒；>0 时优先于记忆进度，见
  /// [_maybeRestoreProgress]；null = 走记忆）。来源（v2.17.6+ 评论 ?t 跳转）：
  /// - PlayerPage.initialPositionMs（链接 ?t 跳新视频/历史入口）；
  /// - 同 bvid 链接带 t 的本页跳：切集（_switchToPage seekMs）或当前集播放器
  ///   未就绪（_seekCurrentTo 先入队，等 onPrepared 定位）。
  /// 一次性消费：_maybeRestoreProgress 用掉即置 null（此后恢复记忆进度）。
  int? _pendingSeekMs;

  /// 500ms tick 计数：每 20 次（=10s）定时保存一次进度（防杀进程丢失）。
  int _tickCount = 0;

  // 观看时长累计（v2.17.9+，供「观看统计」页；口径见 [_accumulateWatchTime]）
  // ---------------------------------------------------------------------
  /// 累计基线上一次 tick 位置（ms）。null = 无基线：首 tick 或 seek/换集/
  /// 断点恢复跳变后重建基线用，**该 tick 本身不累计**（跳变前后的差值不是
  /// 真实观看）。pause/resume 不重置——暂停时位置停住 Δ=0 自然不计。
  int? _watchBaselineMs;

  /// 内存待落盘的观看毫秒：每 tick 把「连续前进」的增量累进来，
  /// 攒够 [kWatchFlushIntervalMs] 批量 [WatchStats.record] 一次
  /// （避免每 500ms tick 都写 shared_preferences）；dispose 时把剩余落盘。
  int _pendingWatchMs = 0;

  /// 批量落盘间隔（≈10s 的真实观看）。
  static const int kWatchFlushIntervalMs = 10000;

  // 路由可见性（v2.17.1+，评论链接跳新播放页 → 返回续播，防双音轨）
  // ---------------------------------------------------------------------
  // 评论链接跳新播放页由 [openVideoInNewPlayer] **在 push 前显式暂停**本页
  // 播放（[_pauseBeforePushingNewPlayer]：pause + 保存进度 + 置
  // [_pausedForNewPlayer] 标记）；[didPopNext]（本页重新成为顶层，用户从
  // 新播放页返回）→ 若此前因让路而暂停则恢复续播。非 'player' 路由（评论
  // 页/图片/登录等）不打断播放——全屏独立评论页 C 打开时本页照常出声
  // （边看边评），仅在 C 里点视频链接跳新播放页时才停。
  bool _pausedForNewPlayer = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅全局路由观察者：感知本页重新成为顶层（didPopNext 恢复续播）。
    // ModalRoute.of(context) 在本阶段必然非空（页面在路由栈中）。
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route as ModalRoute<void>);
  }

  @override
  void initState() {
    super.initState();
    _video = widget.video; // 换源前的初始视频（换源见 playVideo）
    // 播放上下文（v2.30.0+）：只取一份**可写副本**——cid 缺失的邻居补拉完
    // 元数据后要就地替换本列表里的那一条，下次切到它不用再拉一次（构造参数
    // [PlaylistContext] 本身仍只读）。
    final playlist = widget.playlist;
    if (playlist != null && playlist.videos.isNotEmpty) {
      _playlistVideos = List<WhitelistVideo>.of(playlist.videos);
      _playlistLabel = playlist.label;
      final idx = widget.playlistIndex;
      // 下标越界（列表在别处被改过 / 调用方给错）→ 落到第 0 集，不崩
      _playlistIndex = (idx >= 0 && idx < playlist.length) ? idx : 0;
    }
    // 拖动预览服务：生产自建，测试可注入（见 [PlayerPage.videoShotService]）
    _videoShot = widget.videoShotService ?? VideoShotService();
    // 历史记录续播：初始定位到对应分 P（越界 / 单 P 回落第 0 集）。
    // 必须在 _init 之前设置，_maybeRestoreProgress 按 _currentPageIndex 取进度。
    //
    // v2.29.0：**没有分 P 信息时不夹取**（原实现恒夹到 0）。离线缓存页只有
    // `CachedVideo`（bvid/cid/pageIndex），拿不到整条 pages 列表 → 现场构造的
    // [WhitelistVideo.pages] 为 null；若夹到 0，缓存查找键会变成 (bvid, 0)，
    // 点「第 3 集」却播第 1 集的缓存。缓存键本来就是 (bvid, pageIndex)，
    // 无 pages 时按传入下标原样使用才是对的（|>0 只可能来自离线缓存页）。
    final pages = _video.pages;
    final maxIdx = (pages == null || pages.isEmpty)
        ? widget.initialPageIndex
        : pages.length - 1;
    _currentPageIndex = widget.initialPageIndex < 0
        ? 0
        : (widget.initialPageIndex > maxIdx ? maxIdx : widget.initialPageIndex);
    // 评论 ?t 跳转初始定位（v2.17.6+）：>0 时首次 onPrepared 直接 seek 到该处，
    // 覆盖该集记忆进度（链接定位语义优先于历史记忆）。
    final initialMs = widget.initialPositionMs;
    if (initialMs != null && initialMs > 0) _pendingSeekMs = initialMs;
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
    // UP 主入口元数据（阶段 C）：拉 view 接口 owner 补齐 mid/face（异步，
    // 信息行先用 up_name 文本渲染，拉取成功后 setState 换头像+真名）
    _refreshUpownerMeta();
    // 信息块「补场」：进页即起步（延迟 kInfoBlockDelay 由 Interval 表达，
    // 见 [_withInfoBlockEntrance]）。控制器只在装饰开关打开时才被读取，
    // 但**一律 forward**——否则「测试环境默认关闭动效」时它永远停在第 0 帧，
    // 中途开启动效会从半个动画开始。
    _infoBlockCtl.forward();
    _infoBlockCtl.addStatusListener(_onInfoBlockCtlStatus);
    // 封面占位层兜底：cover 为空时整层不构建，也就不必排计时器。
    if (_video.cover.isNotEmpty) {
      _coverFallbackTimer = Timer(
        const Duration(milliseconds: kCoverOverlayFallbackMs),
        _dismissCoverOverlay,
      );
    }
    _init();
  }

  /// 补场动画播完 → 卸掉包裹层（只置一次标志，幂等）。
  void _onInfoBlockCtlStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _infoBlockDone) return;
    if (!mounted) return;
    setState(() => _infoBlockDone = true);
  }

  /// 封面占位层淡出：播放器就绪 / 取流出错 / 兜底超时（三者任一先到）。
  ///
  /// 幂等：第二次调用直接返回——[onPrepared] 每次换源都会来一遍，而这一层
  /// 只该在本页首次出现时淡出一次（换源/全屏/横竖屏都不重播）。
  void _dismissCoverOverlay() {
    if (!mounted || !_coverOverlayVisible || !_coverOverlayOpaque) return;
    setState(() => _coverOverlayOpaque = false);
    _coverTeardownTimer?.cancel();
    _coverTeardownTimer = Timer(kCoverFadeOutDur, () {
      if (!mounted) return;
      setState(() => _coverOverlayVisible = false);
    });
  }

  @override
  void dispose() {
    // 退订路由观察者（必须：didChangeDependencies 里 subscribe 过）
    routeObserver.unsubscribe(this);
    _downloads.cached.removeListener(_onCacheStateChanged);
    _downloads.tasks.removeListener(_onCacheStateChanged);
    _realtime.stage.removeListener(_onRealtimeStageChanged);
    _realtime.sentences.removeListener(_onRealtimeSentencesChanged);
    // 退出播放页：停止实时转写（标志位在块边界生效，不打断引擎单步）
    _realtime.stop();
    // 退出前保存一次进度 + 写入历史（fire-and-forget，防杀进程/直接返回
    // 丢失进度）。播放器尚未释放，getPosition 可用（见 _saveExitProgress）。
    _saveExitProgress();
    // 退出播放页：把内存里不足一次批量阈值（10s）的观看秒数也落盘
    _flushWatchTime();
    _timer?.cancel();
    _hudTimer?.cancel();
    _coverFallbackTimer?.cancel();
    _coverTeardownTimer?.cancel();
    _eventSub?.cancel();
    _eventSub = null;
    _commentScroll.dispose();
    // 补场控制器：必须在 super.dispose() 之前释放——SingleTickerProviderState
    // 在状态销毁时断言「ticker 不能还在跑」，正是靠这里 stop。
    _infoBlockCtl.removeStatusListener(_onInfoBlockCtlStatus);
    _infoBlockCtl.dispose();
    // 拖动预览：释放 LRU 里的雪碧图（原生像素内存）+ 让在途请求作废
    _videoShot?.dispose();
    _player?.dispose();
    _restoreSystemUi();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 路由可见性：push 新播放页前显式暂停；返回 → RouteAware 恢复续播
  // （v2.17.1+）
  // -------------------------------------------------------------------------
  //
  // 背景：评论区点视频链接从「playVideo 当前页换源」（v2.16.23+ 防双音轨）
  // 改为「push 新播放页」（阶段 B 目标：跳转可返回，返回续播上一个视频）。
  // 叠页后旧页播放器仍在出声 → 双音轨，所以旧页必须在自己「不再是顶层」
  // 时暂停，回到顶层再恢复。
  //
  // 机制取舍：RouteAware.didPushNext() 在本 Flutter 版本**无参**（RouteObserver
  // 只通知被盖住的页，不告知上方新路由是谁，见 flutter widgets/routes.dart），
  // 无法按「路由名 == player」过滤——若在 didPushNext 里无差别暂停，打开全屏
  // 独立评论页 C（边看边评，需本页照常出声）也会被误停。因此暂停改在
  // **push 新播放页的调用点显式执行**（[_pauseBeforePushingNewPlayer]，push
  // 方必然知道自己叠的是播放页）；恢复仍走 [didPopNext]（无参即天然正确：
  // 本页重新成为顶层时触发，且只有我们自己置过 [_pausedForNewPlayer] 才动）。
  // didPushNext 不予覆盖（收到也一律忽略），避免误伤边看边评/图片查看等。

  /// 本页重新成为顶层（上面路由被 pop）：若此前因「让路给新播放页」而暂停
  /// → 恢复续播（从离开时保存的进度继续，播放器异常/已释放则重建续播）。
  @override
  void didPopNext() {
    if (!_pausedForNewPlayer) return;
    _pausedForNewPlayer = false;
    debugPrint('[player_page] didPopNext → 恢复本页续播 '
        '${_video.bvid}#$_currentPageIndex');
    unawaited(_resumeAfterNewPlayer());
  }

  /// push 新 [PlayerPage] 前的让路：暂停当前播放并保存进度（防双音轨）。
  ///
  /// 置 [_pausedForNewPlayer] 标记（供 [didPopNext] 恢复）；播放器存在且
  /// 非完成/非错误态才真正 pause + 存进度（完成/错误态无出声，无需停、
  /// 返回后保持原态）。见 [RouteAware] 段注释的机制取舍说明。
  void _pauseBeforePushingNewPlayer() {
    final player = _player;
    if (player == null || _completed || _error != null) {
      // 无出声可能：仅记录调试信息，不置标记（返回后保持当前状态）
      debugPrint('[player_page] push 前无需暂停'
          '（player=${player != null} completed=$_completed error=$_error）');
      return;
    }
    debugPrint('[player_page] push 新播放页前暂停当前播放并保存进度 '
        '${_video.bvid}#$_currentPageIndex');
    _pausedForNewPlayer = true;
    unawaited(_pauseAndSave());
  }

  /// 暂停当前播放器并保存一次进度（push 新播放页让路用）。
  Future<void> _pauseAndSave() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.pause();
    } catch (_) {
      // 原生通道异常：忽略（进度仍保存，音频停不停以原生为准）
    }
    if (mounted) setState(() => _playing = false);
    await _saveProgress();
    // 让路期间通知跟随本页（显示已暂停）；新页开始播放时会改绑到它的播放器
    unawaited(_syncNowPlaying());
  }

  /// 从「新播放页」返回后恢复续播：
  /// - 播放器可用且无错误 → play()（若离开前用户手动暂停也统一恢复——
  ///   取舍：语义简单「跳走再回来一律续播」，想停再点一次暂停即可）；
  /// - 播放器已释放 / 错误态 → 重建取流（_pendingRestore=true 令新流
  ///   onPrepared 时 seek 到刚保存的离开进度续播）。
  Future<void> _resumeAfterNewPlayer() async {
    final player = _player;
    if (player == null || _error != null) {
      debugPrint('[player_page] didPopNext 播放器不可用'
          '（player=${player != null} error=$_error）→ 重建续播');
      _pendingRestore = true;
      await _init();
      return;
    }
    if (_completed) {
      // 已看完停在结尾：不自动重播（用户可点播放/「重播」从头再来）
      debugPrint('[player_page] didPopNext 已看完，保持结束态');
      return;
    }
    try {
      await player.play();
    } catch (_) {
      // 原生通道异常：忽略（UI 态不置播放，用户可手动重试）
      return;
    }
    if (mounted) setState(() => _playing = true);
    unawaited(_syncNowPlaying()); // 恢复续播：通知重新跟随本页
  }

  /// 退出/换源前保存一次进度 + 写入历史（fire-and-forget，防杀进程/直接
  /// 返回丢失进度）。须在播放器释放前调用，getPosition 才可用；看完
  /// （_completed）已清记忆，跳过进度保存（历史仍记录「看过」，位置=结尾
  /// 无妨）。
  ///
  /// ⚠️ 视频信息必须**同步快照**下来再进回调：`getPosition` 是异步的，而
  /// [playVideo] 换源会在同一个事件循环里把 `_video`/`_currentPageIndex`
  /// 换成新视频 —— 回调里再读这两个字段，就会把**旧视频的位置写进新视频的
  /// key 与历史条目**（v2.30.0 上下集实测：切下一集后新视频被「恢复」到旧
  /// 视频的进度、旧视频的观看记录丢失；本方法此前只有 dispose 一个调用点，
  /// 所以这个坑一直没暴露）。
  void _saveExitProgress() {
    final store = _progressStore;
    final player = _player;
    if (player == null) return;
    final video = _video;
    final pageIndex = _currentPageIndex;
    final cid = _currentCid;
    final durationMs = _durationMs;
    final completed = _completed;
    player.getPosition().then((pos) {
      if (pos > 0) {
        if (store != null && !completed) {
          store.saveProgress(video.bvid, pageIndex, pos);
        }
        unawaited(_writeHistory(
          pos,
          video: video,
          pageIndex: pageIndex,
          cid: cid,
          durationMs: durationMs,
        ));
      }
    }).catchError((Object _) {
      // 原生通道异常：忽略，进度最多丢一次
    });
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
    // 重建播放器前先收掉上一个：取消事件订阅 + 释放原生播放器。
    // ⚠️ 必须做——Dart 侧的事件流是**共享**广播流（`BiliDashPlayer._sharedRawEvents`），
    // 上一个播放器的订阅若留着，同一事件会被处理两次；且旧原生播放器会一直
    // 出声（_player 被覆盖后再也没人 dispose 它）。通知栏「关闭（✕）后再点播放」
    // 与「评论区链接换视频」都会走到这条「_init 第二次」的路径。
    // （原 _retry 里的同款收尾已并入这里，不再重复。）
    _eventSub?.cancel();
    _eventSub = null;
    final previous = _player;
    _player = null;
    _textureId = null; // 旧纹理随旧播放器释放（同 playVideo/_retry 原行为）
    previous?.dispose();
    // 实时转写（sherpa）随页重置：停止 + 清句子/partial/错误
    _resetRealtime();
    _initSession++; // 播放器重建代次自增（自动续播流程据此安全退出，见字段注释）
    // 拖动预览：拉当前视频 + 当前分 P 的雪碧图元信息。**不 await**——
    // 预览只是增强，不能让一次视频接口请求拖慢取流（失败由服务层静默降级）。
    // 服务内部对「同 bvid + 同分 P 且已就绪」短路，重复调用不会重复请求。
    unawaited(_prepareVideoShot());
    setState(() {
      _error = null;
      _loginPrompt = false;
      _canRetry = true;
      _buffering = true;
      _loaded = false;
      _completed = false;
      // 重新初始化（重试/重进/换源）→ 自动续播预算与进行中标记重置
      // （新播放器从零开始，续播成功 READY 后还会在 onPrepared 再次清零）
      _autoRecoverFails = 0;
      _autoRecovering = false;
      // 重新初始化（重试/重进/换源）→ 主动预取状态复位：旧流的 deadline
      // 不再适用，新流 setDataSource 后由 _playStream 重新记录
      _prefetching = false;
      _netStreamDeadlineMs = null;
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
      _ensureTickTimer();
    } catch (e) {
      if (!mounted) return;
      await _handleLoadFailure(e);
    } finally {
      if (mounted) setState(() => _buffering = false);
    }
  }

  /// 取流并开始播放：**已缓存且源为本地 → 直接播本地文件**（无网络、无 URL
  /// 过期问题）；否则优先 DASH 双流（video+audio），无 dash 则 fnval=0 降级
  /// mp4 单流。
  /// cid 取当前集 `_currentCid`（多 P 切换选集后为 pages[index].cid）。
  ///
  /// v2.39.0+ 缓存命中多了一个前提 [PlaySource.local]：源为 [PlaySource.network]
  /// 时**跳过缓存、强制走取流**（这是「缓存了音频之后还能切回网络看画面」的
  /// 实现点——仅音频缓存本地源没有视频轨，只有网络流能出画面）。
  Future<void> _loadStreamAndPlay({required int positionMs}) async {
    final player = _player;
    if (player == null) return;
    // 本地缓存优先：命中则不请求网络流（源为网络流时不查缓存，见上方注释）
    final cached = _playSource == PlaySource.local
        ? _downloads.getCached(_video.bvid, _currentPageIndex)
        : null;
    if (cached != null) {
      // 仅音频缓存（videoPath 为空）：**把音频文件当 videoUrl 传**。
      //
      // 为什么走这条通道而不是 audioUrl：播放器原生侧 `prepare` 在 audioUrl
      // 为空时只用 videoUrl 建一个 ProgressiveMediaSource；Dart 侧 videoUrl
      // 又是必填位置参数。音频 m4s 是合法单流（AAC），当 videoUrl 传进去 →
      // 走同一个单流分支，有声音、能 seek，原生一行不用改（v2.29.0 已在
      // 模拟器上实测：有声、可拖动进度、不留错误）。
      final asAudioOnly = cached.audioOnly &&
          cached.videoPath.isEmpty &&
          cached.audioPath.isNotEmpty;
      final mediaPath = asAudioOnly ? cached.audioPath : cached.videoPath;
      final sideAudio = asAudioOnly || cached.audioPath.isEmpty
          ? null
          : Uri.file(cached.audioPath).toString();
      debugPrint('[player_page] 本地缓存播放'
          '${asAudioOnly ? '（仅音频）' : ''} video=$mediaPath '
          'audio=${cached.audioPath}');
      _setAudioOnlyPlayback(asAudioOnly);
      await player.setDataSource(
        Uri.file(mediaPath).toString(),
        audioUrl: sideAudio,
        positionMs: positionMs,
        title: _video.title,
        artist: _video.upName,
        coverUrl: _video.cover,
      );
      // 本地缓存播放无 deadline（也不应去取网络流）：主动预取不适用，
      // 标记清除（防上一次网络流的 deadline 残留误触发）
      _netStreamDeadlineMs = null;
      return;
    }
    // 走网络流：一定不是「仅音频缓存」播放（换源/新集/未缓存），复位标记
    _setAudioOnlyPlayback(false);
    final epId = _video.epId; // 番剧集 ep_id（普通视频/旧番剧数据 = null）
    debugPrint(
        '[player_page] 取流 bvid=${_video.bvid} cid=$_currentCid epId=$epId');
    try {
      // 1) 普通 playurl（WBI）：普通视频/免费番剧集走这里（免费集普通接口
      //    720P 比 pgc 端点的更清晰，优先）
      var result = await _api.fetchPlayUrl(
        bvid: _video.bvid,
        cid: _currentCid,
        qn: 80,
        fnval: 16, // DASH 双流（M2.1 实测定案：1080P 走路线 A）
      );
      // 老视频无 DASH → 重取 fnval=0 拿 durl[0].url（fnval=16 的响应里没有 durl）
      if (result.dashVideoUrls.isEmpty) {
        debugPrint('[player_page] fnval=16 无 DASH，降级 fnval=0');
        result = await _api.fetchPlayUrl(
          bvid: _video.bvid,
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

  /// 把解析好的流交给播放器播放（dash 双流 / mp4 单流），并记录网络流
  /// URL 的 deadline（主动预取换源判定用，v2.17.15+）。
  ///
  /// [result] 须 [PlayUrlResult.hasStream] 为真（调用方保证）。
  Future<void> _playStream(PlayUrlResult result,
      {required int positionMs}) async {
    final player = _player;
    if (player == null) return;
    final String videoUrl;
    final String? audioUrl;
    if (result.dashVideoUrls.isNotEmpty) {
      videoUrl = result.dashVideoUrls.first;
      audioUrl = result.dashAudioUrls.isEmpty ? null : result.dashAudioUrls.first;
    } else {
      videoUrl = result.mp4Url!;
      audioUrl = null;
    }
    await player.setDataSource(videoUrl,
        audioUrl: audioUrl,
        positionMs: positionMs,
        title: _video.title,
        artist: _video.upName,
        coverUrl: _video.cover);
    // 记录当前网络流 URL 的过期时刻：主动预取判定依据（解析失败=URL 无
    // deadline → null → 回退被动恢复）。仅记录不换源，换源由
    // [_maybePrefetchSource] 按剩余时间决策。
    _netStreamDeadlineMs = streamDeadlineMs(videoUrl);
    final deadline = _netStreamDeadlineMs;
    if (deadline != null) {
      final remainS =
          (deadline - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
      debugPrint('[player_page] 网络流 deadline 剩余≈${remainS}s '
          '${_video.bvid}#$_currentPageIndex');
    } else {
      debugPrint('[player_page] 网络流 URL 无 deadline，不主动预取 '
          '（回退被动 onUrlExpired）${_video.bvid}#$_currentPageIndex');
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
        _dismissCoverOverlay();
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
    _dismissCoverOverlay();
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
      _dismissCoverOverlay();
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
      _dismissCoverOverlay();
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
    // 取流失败：不会再有 onPrepared，封面占位层立刻淡出（露出错误视图）
    _dismissCoverOverlay();
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
      case BiliDashPreparedEvent(
          :final width,
          :final height,
          :final durationMs,
          :final playWhenReady,
        ):
        _onPrepared(width, height, durationMs, playWhenReady);
      case BiliDashCompletedEvent():
        _onCompleted();
      case BiliDashErrorEvent(:final code, :final message):
        _onNativeError(code, message);
      case BiliDashUrlExpiredEvent():
        _onAutoRecover();
      case BiliDashMediaActionEvent(:final action, :final positionMs):
        _onMediaAction(action, positionMs);
    }
  }

  // -------------------------------------------------------------------------
  // 媒体通知（B 站式通知 + 耳机按键控制，v2.25.x）
  // -------------------------------------------------------------------------

  /// 通知/耳机操作回传到界面（原生播放器**已经**执行了对应动作，这里只对齐 UI）。
  ///
  /// 例外：`prev` / `next`（通知收起行的「上一集 / 下一集」，v2.30.0-r2）原生
  /// **什么都没做** —— 切集要换 bvid 重新取流，只有本页做得到，见 [playNeighbor]。
  Future<void> _onMediaAction(String action, int positionMs) async {
    debugPrint('[player] onMediaAction action=$action positionMs=$positionMs');
    switch (action) {
      case 'play':
      case 'pause':
        // 播放器已在播 / 已暂停：复用播放按钮的同一条路径改状态（内含「看完后
        // 重播」复位与暂停时保存进度），`_togglePlay` 自身按 _playing 取反，
        // 所以只有状态确实不一致时才调用（否则会反向把它切回去）。
        if (_error != null) return; // 错误态：播放器无源，别把界面改成在播
        if (action == 'play' && !_playing) {
          await _togglePlay();
        } else if (action == 'pause' && _playing) {
          await _togglePlay();
        }
      case 'seek':
        // 通知栏快退/快进 15 秒等：位置跳变不计入观看时长，且不再是「已播完」
        _resetWatchBaseline();
        if (mounted) {
          setState(() {
            _positionMs = positionMs;
            if (positionMs < _durationMs) _completed = false;
          });
        }
      case 'stop':
        if (mounted) await _onStoppedByNotification();
      // 通知收起行的「上一集 / 下一集」：与底栏那对按钮**走同一条路**
      // （越界/无列表/换源中都被 playNeighbor 自己挡掉，这里不做任何判断）
      case 'prev':
        await playNeighbor(-1);
      case 'next':
        await playNeighbor(1);
      default:
        debugPrint('[player] 未知媒体动作：$action');
    }
  }

  /// 通知栏「关闭（✕）」：原生已 stop + 清空媒体项 → 界面收成停止态。
  ///
  /// 位置按 Dart 侧最后一次 tick 的位置存（原生已 stop，getPosition 归零），再点
  /// 播放时 [_togglePlay] 会重新取流并走「记忆进度恢复」续播。
  Future<void> _onStoppedByNotification() async {
    if (_stoppedByNotification) return;
    debugPrint('[player_page] 通知关闭（✕）→ 界面收成停止态');
    final pos = _positionMs;
    // 停掉 tick 轮询（并置 null，同 [_onCompleted] 的约定）：播放器已被原生
    // stop、媒体项被清空，getPosition 恒为 0 —— 继续轮询只是空转，还会把界面
    // 位置刷回 0:00、把「关闭时保存的续播位置」冲掉（v2.25.0-r2 修复）。
    // 再点播放走 [_togglePlay] → [_init]（内含 [_ensureTickTimer]）重建轮询。
    _timer?.cancel();
    _timer = null;
    setState(() {
      _playing = false;
      _stoppedByNotification = true;
    });
    final store = _progressStore;
    if (pos > 0 && !_completed) {
      if (store != null) {
        await store.saveProgress(_video.bvid, _currentPageIndex, pos);
      }
      await _writeHistory(
        pos,
        video: _video,
        pageIndex: _currentPageIndex,
        cid: _currentCid,
        durationMs: _durationMs,
      );
    }
  }

  /// 当前副标题里的状态文案（原生拼成 `<UP 名> · <状态>`，与 B 站一致）。
  String _nowPlayingStatus() {
    if (_error != null) return '播放失败';
    if (_completed) return '已播完';
    if (!_playing) return '已暂停';
    return _listenMode ? '后台听视频省流量' : '正在播放';
  }

  /// 把当前播放状态推给原生媒体通知（播放状态变化时调用，空操作安全）。
  ///
  /// 通知只是增强：原生通道异常（老版本原生 / 测试环境）一律静默忽略，
  /// 绝不能因为通知失败影响播放。
  Future<void> _syncNowPlaying() async {
    final player = _player;
    if (player == null) return;
    if (!_notifPermissionRequested) {
      // 第一次要显示通知了：顺手请求一次通知权限（Android 13+，原生侧自带
      // 版本判断与去重）。v2.25.0-r2 起通知不绑媒体会话 token，不再享受
      // 「媒体会话通知」的权限豁免 → 被拒绝时通知不显示（播放不受影响）。
      _notifPermissionRequested = true;
      unawaited(BiliDashPlayer.requestNotificationPermission());
    }
    try {
      await player.updateNowPlaying(
        title: _video.title,
        artist: _video.upName,
        coverUrl: _video.cover,
        status: _nowPlayingStatus(),
        playing: _playing,
        positionMs: _positionMs,
        durationMs: _durationMs,
        // 上/下一集是否真有：通知收起行据此在 `上一集/暂停/下一集` 与既有的
        // `快退15s/暂停/快进15s` 之间二选一（v2.30.0-r2）。两个都为 false
        // （单集 / 头尾 / 没有播放列表）时原生完全不动，行为与改动前一致。
        hasPrev: _canPlayPrev,
        hasNext: _canPlayNext,
      );
    } catch (_) {
      // 通道异常：忽略（通知不显示，播放照常）
    }
  }

  void _onPrepared(
    int width,
    int height,
    int durationMs,
    bool playWhenReady,
  ) {
    debugPrint('[player] onPrepared ${width}x$height duration=$durationMs '
        'playWhenReady=$playWhenReady');
    if (!mounted) return;
    setState(() {
      _loaded = true;
      // 播放态取**原生的真实播放意图**，不再无条件置 true：onPrepared 每次进
      // READY 都会发（seek、重新缓冲后也发），旧写法会让「暂停态下拖通知进度条 /
      // 点卡片快退」把界面错报成「正在播放」（位置冻结、与 dumpsys 的
      // state=NONE 矛盾，v2.25.0-r2 修复）。正常起播（setDataSource 后原生
      // 自动 play）playWhenReady=true，行为与旧版一致。
      _playing = playWhenReady;
      _buffering = false;
      // 只有确实在播才清「已播完」：暂停态下 seek 到结尾附近不该被当成重新起播
      if (playWhenReady) _completed = false;
      // 新流就绪 = 确实在播：清掉「通知关闭」的停止态（换源瞬间媒体项为空可能
      // 误触发过停止事件，这里自愈；原生真被关闭时不会再有 onPrepared）
      _stoppedByNotification = false;
      _durationMs = durationMs;
      if (width > 0 && height > 0) {
        _aspectRatio = width / height;
        _aspectKnown = true; // 比例是真的了 → 进全屏的方向策略可据此判定
      }
      // 新流成功 READY → 自动续播预算清零：每段播放独立预算，
      // 播放中多次零星网络抖动各自都能拿到完整重试次数
      _autoRecoverFails = 0;
    });
    // 宽高比此刻才拿到（或换集后变了）→ 若正在全屏，按新比例**补一次方向锁**
    // （v2.39.0）：覆盖两个窗口——① 用户在全屏按钮可点时（!_loaded）先点了
    // 全屏，那时 [_aspectKnown] 还是 false、只放过自由方向；② 全屏中切集到
    // 另一个方向的视频（如横屏集 → 竖屏集）。已锁对时重复下发同一组方向是
    // 幂等的，不会转屏。
    if (_fullscreen) unawaited(_applyFullscreenOrientation());
    // 首次进入 / 切集后恢复该集记忆进度（不打断自动播放）
    _maybeRestoreProgress(durationMs);
    // 画面就绪 → 封面占位层淡出（换源时这一层早已卸载，调用是空操作）
    _dismissCoverOverlay();
    // 新流开始：观看时长累计基线重建（旧流位置与此无关；若本流 onPrepared
    // 后还要 seek 恢复进度，_maybeRestoreProgress/seek 处会再次置 null）
    _resetWatchBaseline();
    // 媒体通知：标题/UP/封面/状态（首次进入即显示通知）
    unawaited(_syncNowPlaying());
  }

  void _onCompleted() {
    if (!mounted) return;
    // 看完 → 停掉 tick（画面已停，没必要再轮询），**并置 null**：否则这个已
    // cancel 的死实例会让后面的 `??=`/isActive 判定失真（旧 bug：播完再播进度
    // 条/字幕不再刷新）。重建走 [_ensureTickTimer]。
    _timer?.cancel();
    _timer = null;
    setState(() {
      _playing = false;
      _positionMs = _durationMs;
      _completed = true;
    });
    // 观看完成 → 清除进度记忆（下次从头播）
    _clearProgress();
    unawaited(_syncNowPlaying()); // 通知副标题 → 已播完
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
    // 原生报错：画面不会来了，封面占位层让位给错误视图
    _dismissCoverOverlay();
    unawaited(_syncNowPlaying()); // 通知副标题 → 播放失败
  }

  /// 自动续播（流 URL 过期 / 瞬时网络错误，原生已统一归类为可恢复）：
  /// 重取 playurl → 记当前位置 → setDataSource 续播（保留位置），失败按
  /// [kAutoRecoverBackoffMs] 退避重试**有限次**（预算 [_autoRecoverFails]，
  /// 新流成功 READY 后清零），仍失败才显示 [kAutoRecoverGiveUpMessage]——
  /// 保留「重试」按钮手动兜底，网络抖动弹错打断观看成为极少情况。
  Future<void> _onAutoRecover() async {
    if (!mounted || _error != null) return;
    if (_autoRecovering) {
      debugPrint('[player] 自动续播流程进行中，忽略重复事件');
      return;
    }
    if (_prefetching) {
      // 主动预取换源正在进行（它本身就在重取 playurl → 换新源）：URL 过期
      // 事件交给它解决，避免并发双换源；其失败路径会再调回本方法兜底
      debugPrint('[player] 主动预取进行中，onUrlExpired 交给预取流程');
      return;
    }
    _autoRecovering = true;
    final session = _initSession; // 代次校验：await 间隙播放器被重建则退出
    try {
      while (mounted && _error == null && session == _initSession) {
        final attempt = _autoRecoverFails; // 本次为第 attempt+1 次尝试
        final delay = autoRecoverDelayMs(attempt);
        if (delay == null) {
          // 连续失败超过上限：显示错误（手动重试兜底），不再自动折腾
          debugPrint('[player] 自动续播 $attempt 次均失败，放弃自动恢复');
          _showFatal(kAutoRecoverGiveUpMessage);
          return;
        }
        _autoRecoverFails = attempt + 1; // 预扣一次（成功 READY 后在 onPrepared 清零）
        debugPrint('[player] 自动续播第 ${attempt + 1} 次，退避 ${delay}ms');
        if (mounted) setState(() => _buffering = true); // 转缓冲，不弹错误
        await Future<void>.delayed(Duration(milliseconds: delay));
        if (!mounted || _error != null || session != _initSession) return;
        final position = await _player?.getPosition() ?? 0;
        try {
          await _loadStreamAndPlay(positionMs: position);
          // 续播成功：按当前倍速恢复（换源后原生倍速会被重置为 1x）
          await _player?.setPlaybackSpeed(_speed);
          if (mounted) setState(() => _buffering = false);
          return;
        } catch (e) {
          debugPrint('[player] 自动续播第 ${attempt + 1} 次失败：$e');
          // 继续 while：按下一档退避再试；原生侧若已自行再次上报事件则被
          // _autoRecovering 拦下（本循环统一驱动，避免并发多次续播）
        }
      }
    } finally {
      _autoRecovering = false;
    }
  }

  /// 主动预取 + 平滑换源（v2.17.15+）：在流 URL 到期前换新 URL，消除
  /// 「读到过期 URL → 2001/失败」的必然中断（被动 onUrlExpired 是失败后才
  /// 恢复，这里 URL 尚有效就主动做，播放几乎无感）。
  ///
  /// 由 [_tick] 每 10s（20 × 500ms）调用一次，纯判定 + 按需执行：
  /// - 前置：READY 播放中、无错误/缓冲/完成、不与被动自动续播或本次预取并发、
  ///   播放器未重建（代次一致）；
  /// - 判定：当前网络流 deadline 剩余 < 剩余内容时长 + [kPrefetchLeadMs]
  ///   （[shouldPrefetchSource]，deadline 缺失/时长未知 → 不预取回退被动）；
  /// - 触发：节流（距上次尝试 ≥ [kPrefetchMinIntervalMs]）后重取 playurl →
  ///   记位置 → setDataSource 平滑换源（同 [_onAutoRecover] 的续播路径，
  ///   但此刻 URL 仍有效，不会失败）；
  /// - 失败：静默（不弹错），URL 尚有效则下轮再试；期间原生若因 URL 真过期
  ///   报 onUrlExpired 会被 [_prefetching] 让路并最终走回 [_onAutoRecover]。
  Future<void> _maybePrefetchSource() async {
    final player = _player;
    if (player == null || !mounted) return;
    if (!_loaded || !_playing || _buffering || _completed || _error != null) {
      return;
    }
    if (_autoRecovering || _prefetching) return; // 与被动续播互斥，防双换源
    if (_dragging || _seekDragging) return; // 用户 seek 拖动中不打断
    final deadline = _netStreamDeadlineMs;
    final duration = _durationMs;
    if (deadline == null || duration <= 0) return; // 本地/无 deadline/时长未知
    final session = _initSession; // 代次校验：await 间隙播放器被重建则退出
    // 位置取一次就够（判定基准）；换源前会再取最新位置
    final pos = await player.getPosition();
    if (!mounted || session != _initSession) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final remainMs = streamDeadlineRemainMs(deadline, nowMs: now);
    final videoRemainMs = math.max(0, duration - pos);
    if (!shouldPrefetchSource(
        deadlineRemainMs: remainMs, videoRemainMs: videoRemainMs)) {
      return;
    }
    if (now - _lastPrefetchAttemptMs < kPrefetchMinIntervalMs) {
      return; // 节流：距上次尝试不足（上次失败/刚换完源都占位）
    }
    _lastPrefetchAttemptMs = now;
    _prefetching = true;
    var needRecoverFallback = false; // 预取失败且可能已丢 onUrlExpired → 走被动兜底
    try {
      debugPrint('[player_page] 主动预取换源：URL 剩余≈${remainMs! ~/ 1000}s '
          '视频剩余≈${videoRemainMs ~/ 1000}s '
          '（${_video.bvid}#$_currentPageIndex）');
      if (mounted) setState(() => _buffering = true); // 换源短暂转缓冲
      final posNow = await player.getPosition();
      if (!mounted || session != _initSession) return;
      await _loadStreamAndPlay(positionMs: posNow); // 同集同清晰度重取流换源
      await player.setPlaybackSpeed(_speed); // 换源后原生倍速被重置为 1x
      // 新流 READY 时 onPrepared 会把 _buffering 置 false 并续 _playing
    } catch (e) {
      debugPrint('[player_page] 主动预取换源失败（静默，稍后重试或被动兜底）：$e');
      needRecoverFallback = true;
      if (mounted) setState(() => _buffering = false); // 不弹错、不留转缓冲
    } finally {
      _prefetching = false;
    }
    if (needRecoverFallback && mounted && _error == null) {
      // 预取失败：当前 URL 可能已真过期（原生 onUrlExpired 被上面让路吞掉），
      // 回退被动自动续播（自带退避重试与放弃文案）兜底
      unawaited(_onAutoRecover());
    }
  }

  // -------------------------------------------------------------------------
  // 控制动作
  // -------------------------------------------------------------------------

  Future<void> _tick() async {
    final player = _player;
    if (player == null || _dragging || _seekDragging) return;
    final pos = await player.getPosition();
    // 两种「停止带来的假位置」都要挡（v2.25.0-r2，模拟器实测）：
    // 1) 原生 stop() 之后、Dart 收到 onMediaAction=stop 之前有一个窗口（实测
    //    ~150ms）；这段里 getPosition 会报 0 —— 播放中位置不可能倒退到 0，
    //    这种值一律丢弃，否则界面位置被冲成 0:00，而且「✕ 时按 _positionMs
    //    存进度」会一并落空（实测：进度停在上一轮定期保存的值）；
    // 2) 在途的这次 tick 可能在 await 期间被停止事件抢跑（_stoppedByNotification
    //    已置位）—— 同样不能覆盖界面位置。
    if (_playing && pos == 0 && _positionMs > 0) return;
    if (!mounted || _stoppedByNotification) return;
    setState(() => _positionMs = pos);
    // 观看时长累计（纯本地；每 500ms tick 增量判断真实播放，攒够批量落盘）
    _accumulateWatchTime(pos);
    if (mounted) _updateSubtitleText(pos);
    // 播放中每 20 次 tick（=10s）保存一次进度（防杀进程丢失）+ 判定一次
    // 是否需要主动预取换源（v2.17.15+，见 _maybePrefetchSource：普通视频
    // deadline 2h 足够，判定不通过即零开销返回）
    if (++_tickCount % 20 == 0) {
      _saveProgress();
      unawaited(_maybePrefetchSource());
    }
  }

  /// 确保 [_tick] 轮询定时器在跑（幂等：同一时刻**最多一个**）。
  ///
  /// 判定用 `isActive` 而不是 `??=`：cancel 过的 `Timer` 引用仍非 null，`??=` 会
  /// 把它当成「已在跑」而永不重建 → 进度条/时间文本/字幕从此停在原地。改动前的
  /// 「播完 → 再播」（点中央播放键 / 耳机播放键 / 通知播放键都会走 [_togglePlay]）
  /// 正是踩了这个：[_onCompleted] 只 cancel 没置 null。
  void _ensureTickTimer() {
    if (!mounted) return;
    final existing = _timer;
    if (existing != null && existing.isActive) return; // 已在跑：不重开（防双计时器）
    existing?.cancel(); // 死实例：先收尾再重建
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  /// 观看时长累计（口径）：仅当 **playing（含听视频纯音频模式）** 且相对
  /// 上一 tick 的位置增量 `0 < Δ ≤ 5s` 时，视为真实播放的连续前进并累加：
  /// - Δ ≤ 0：暂停 / 缓冲停住 / 看完 → 不计（听视频时画面隐藏但位置照常
  ///   前进 → 照计；屏幕关闭后 Dart tick 被系统挂起 → 少计，见类注释取舍）
  /// - Δ > 5s：seek（快进/拖动/断点恢复/链接定位）与跳变 → 跳过内容不算
  ///   观看；seek 后 [_watchBaselineMs] 会被置 null 重建基线，避免把 seek
  ///   前后相邻 tick 的差值误计
  void _accumulateWatchTime(int posMs) {
    if (!_playing || _completed) return; // 暂停 / 播放结束不计
    final base = _watchBaselineMs;
    _watchBaselineMs = posMs; // 无论是否累计，基线都要推进到本次位置
    if (base == null) return; // 首 tick / seek 重建：只设基线不累计
    final delta = posMs - base;
    if (delta <= 0 || delta > WatchStats.maxTickDeltaMs) return;
    _pendingWatchMs += delta;
    if (_pendingWatchMs >= kWatchFlushIntervalMs) _flushWatchTime();
  }

  /// 把内存累计的观看秒数批量落盘（整秒取整；不足 1s 的残留亚秒留给下次）。
  void _flushWatchTime() {
    if (_pendingWatchMs < 1000) return;
    final seconds = _pendingWatchMs ~/ 1000;
    _pendingWatchMs = 0;
    debugPrint('[player_page] 观看时长 +${seconds}s '
        '（${_video.bvid}#$_currentPageIndex）');
    unawaited(WatchStats.instance.record(seconds));
  }

  /// seek / 换集等位置跳变后重置观看时长累计基线（跳过/跳回的内容不计）。
  void _resetWatchBaseline() {
    _watchBaselineMs = null;
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
    if (_stoppedByNotification) {
      // 通知栏「关闭（✕）」后原生播放器已没有媒体项：重新取流续播
      // （_pendingRestore 令新流 onPrepared 时 seek 回记忆进度）
      debugPrint('[player_page] 通知关闭后点播放 → 重新取流续播');
      _stoppedByNotification = false;
      _pendingRestore = true;
      await _init();
      return;
    }
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
      // 复活 tick：看完（[_onCompleted] 停掉了轮询）后重播，或任何「定时器被取消
      // 过」的路径，都必须在这里重建，否则进度条/时间文本/字幕不再刷新。
      _ensureTickTimer();
    }
    unawaited(_syncNowPlaying()); // 媒体通知：播放/暂停状态 + 副标题
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
    _resetWatchBaseline(); // 位置跳变：跳过的内容不计观看时长
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
    _resetWatchBaseline(); // +3s 前进可能落在 5s 阈值内 → 必须重置基线防误计
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
    // 视频信息**同步快照**：下面 getPosition 是 await，期间可能换源/切集
    // （[_saveExitProgress] 注释里有这条坑的完整说明）。
    final video = _video;
    final pageIndex = _currentPageIndex;
    final cid = _currentCid;
    final durationMs = _durationMs;
    final pos = await player.getPosition();
    if (pos <= 0) return;
    await store.saveProgress(video.bvid, pageIndex, pos);
    debugPrint('[player_page] 保存进度 '
        '${video.bvid}#$pageIndex $pos ms');
    // 与进度保存同节奏写历史（_tick 每 10s / 暂停 / 快进快退 / dispose 触发）
    await _writeHistory(
      pos,
      video: video,
      pageIndex: pageIndex,
      cid: cid,
      durationMs: durationMs,
    );
  }

  /// 写入播放历史：记录 **调用方同步取好的那份视频快照** + 进度 + 观看时间。
  ///
  /// [video]/[pageIndex]/[cid]/[durationMs] 一律显式传入而不是在方法体内读
  /// `_video` 等字段：本方法（及其调用方）都在 await 之后落笔，而播放页会在
  /// await 间隙换源/切集 —— 那时读当前字段会把旧视频的位置写进新视频的历史
  /// 条目（与 [_saveExitProgress] 同源的坑，见其注释）。
  /// 失败静默不影响播放。
  Future<void> _writeHistory(
    int positionMs, {
    required WhitelistVideo video,
    required int pageIndex,
    required int cid,
    required int durationMs,
  }) async {
    try {
      await HistoryStore.instance.addOrUpdate(
        HistoryEntry(
          bvid: video.bvid,
          pageIndex: pageIndex,
          cid: cid,
          title: video.title,
          cover: video.cover,
          upName: video.upName,
          durationMs: durationMs > 0 ? durationMs : video.duration * 1000,
          positionMs: positionMs,
          watchedAt: DateTime.now(),
          pages: video.pages,
          // 发布时间随历史一起存：历史卡副信息行显示「发布 yyyy-MM-dd」
          pubdate: video.pubdate,
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
    await store.clearProgress(_video.bvid, _currentPageIndex);
    debugPrint('[player_page] 清除进度 '
        '${_video.bvid}#$_currentPageIndex');
  }

  /// onPrepared 后定位（仅首次进入 / 切集 / 手动重试后触发）：
  /// - 带明确的 ?t 定位（[_pendingSeekMs]，评论链接跳转 / initialPositionMs
  ///   v2.17.6+）→ 直接 seek 到该位置（**覆盖记忆进度**）且不弹「已从上次…
  ///   继续」（用户明确要链接指定的位置，无需打扰）；超出当前集时长按结尾
  ///   处理（与 B 站 web 相同：贴结尾从末尾附近播）。
  /// - 否则按记忆进度恢复：无记忆或 <=5s → 从头播，不打扰；距结尾 <3s →
  ///   视为已看完，清除记忆后从头播；其余 → seekTo(记忆位置) + SnackBar
  ///   「从头播放」action。
  Future<void> _maybeRestoreProgress(int durationMs) async {
    if (!_pendingRestore) return;
    _pendingRestore = false;
    final overrideMs = _pendingSeekMs;
    _pendingSeekMs = null; // 一次性消费：本次定位用掉即清（之后回到记忆进度）
    if (overrideMs != null && overrideMs > 0) {
      var target = overrideMs;
      final maxMs = durationMs - 1000;
      if (maxMs > 0 && target > maxMs) target = maxMs;
      debugPrint('[player_page] 按链接/入参定位 seekTo $target ms '
          '${_video.bvid}#$_currentPageIndex');
      await _player?.seekTo(target);
      // 预热定位到的位置：这是用户要观看的地方，也是最可能拖动的一带
      _prefetchVideoShotAt(target);
      return;
    }
    final store = _progressStore;
    if (store == null) return;
    final saved = store.getProgress(_video.bvid, _currentPageIndex);
    if (saved == null || saved <= 5000) return;
    if (durationMs > 0 && saved >= durationMs - 3000) {
      await _clearProgress();
      return;
    }
    debugPrint('[player_page] 恢复进度 '
        '${_video.bvid}#$_currentPageIndex $saved ms');
    await _player?.seekTo(saved);
    // 同上：预热恢复到的位置（非 0 时，进页那次预取的 0 号图没用）
    _prefetchVideoShotAt(saved);
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
    // 仅追加预览请求：位置/拖动状态的语义与调用时机一字未动
    _requestSeekPreview(v.round());
  }

  void _onSeekEnd(double v) {
    debugPrint('[player_page] seekTo ${v.round()}ms');
    setState(() {
      _dragging = false;
      _positionMs = v.round();
      // 预览随拖动结束立即隐藏并作废：清帧 + 代次自增（在途的迟到结果不再应用）
      _endSeekPreviewRound();
    });
    _player?.seekTo(v.round());
    _resetWatchBaseline(); // 进度条拖动跳变：不计观看时长
    // 预热刚跳到的位置：下一轮拖动大概率还在这一带（图通常已在 LRU 里，
    // 命中即零成本；拖动太短还没拉上时这里顺手把它补上）
    _prefetchVideoShotAt(v.round());
  }

  // -------------------------------------------------------------------------
  // 进度条拖动预览（缩略图 + 时间浮层）
  // -------------------------------------------------------------------------

  /// 拉取「当前视频 + 当前分 P」的预览图元信息（进页/切集/换源各调一次），
  /// 就绪后顺手**预取「当前（或即将恢复到的）播放位置」那一张雪碧图**。
  ///
  /// **失败静默**：接口挂了只留服务 `isReady == false`，拖动仍显示时间气泡。
  /// `index` 是 **1-based** 的分 P 序号（接口约定，与 `_currentPageIndex` 差 1）。
  Future<void> _prepareVideoShot() async {
    final bvid = _video.bvid;
    if (bvid.isEmpty) return;
    await _videoShot?.prepare(bvid, index: _currentPageIndex + 1);
    if (!mounted) return;
    // 位置以「此前报过的预取位置」优先（如记忆进度恢复的位置，见
    // [_maybeRestoreProgress]）；没有就取当前播放位置（进页通常是 0）
    _prefetchVideoShotAt(_prefetchWantMs ?? _positionMs);
  }

  /// 进度条拖动中回报「手指在轨道上的水平位置」（[_PlayerSeekBar.onDragPosition]）。
  ///
  /// 只做两件事：记录位置给浮层用；识别「本轮拖动起手」并复位上一轮的残留
  /// （旧帧/节流位/在途代次）——拖动起手那一次回报先于 [_onSeekStart] 到达，
  /// 所以这里用「本轮是否已开始」而不是 `_dragging` 判定，不依赖回调时序。
  void _onSeekDragPosition(double dragX, double trackWidth) {
    final starting = !_previewDragActive;
    setState(() {
      _previewDragX = dragX;
      _previewTrackWidth = trackWidth;
      if (starting) _beginSeekPreviewRound();
    });
  }

  /// 本轮 seek 拖动起手：置位「已开始」并复位上一轮的残留。
  ///
  /// 上一轮留下的帧可能已被 LRU 淘汰（容量 2，淘汰即 `dispose`）→ 起手清空，
  /// 等本轮第一帧到位再画（命中缓存时几乎无感）；代次自增让在途的迟到结果
  /// 全部作废。拖动进度条与手势横滑 seek 两条路径共用（同一时刻只有一条在跑）。
  void _beginSeekPreviewRound() {
    _previewDragActive = true;
    _previewFrame = null;
    _previewShot = -1;
    _previewSprite = -1;
    _previewGen++;
  }

  /// 本轮 seek 拖动结束：清帧 + 代次自增（在途结果不许再落地）。
  void _endSeekPreviewRound() {
    _previewFrame = null;
    _previewShot = -1;
    _previewSprite = -1;
    _previewDragActive = false;
    _previewGen++;
  }

  /// 取「当前位置」的缩略图（拖动中高频调用）。
  ///
  /// - 未就绪（prepare 未完成 / 失败）→ 直接返回：只显示时间气泡（降级）
  /// - 同一格（≈同一秒）→ 不重复请求（节流；也顺带不对失败反复重试）
  /// - **落地条件是「这张雪碧图还是当前位置需要的那张」**，不是「请求序号最
  ///   新」：连续拖动几百毫秒就能换好几格，而一张雪碧图要下 + 解 1.5~2.5s，
  ///   按序号判新旧会把明明可用的结果整条丢掉（首次拖动就只剩时间气泡，实测
  ///   松手后再拖一次才出现——图其实已经进了 LRU）。换张了才丢：那时图已经不是
  ///   当前位置的画面，落地会显示错误区段。
  /// - 落地时用**当前位置**重算裁剪矩形（见 [_reframeAtCurrentPosition]）：
  ///   显示的是手指此刻所指的时间，只是图刚下好。
  /// - ★ 取帧时刻先过 [_previewMsAt]：贴到片尾时回退一小段，避开雪碧图的
  ///   末格（末格实测是纯黑，拖到最右端就成一块黑）。
  void _requestSeekPreview(int ms) {
    final service = _videoShot;
    final info = service?.info;
    if (service == null || info == null || !service.isReady) return;
    final at = _previewMsAt(ms);
    final shot = info.shotIndexForSeconds(at <= 0 ? 0 : at ~/ 1000);
    if (shot < 0 || shot == _previewShot) return;
    _previewShot = shot;
    final cell = info.cellForShot(shot);
    // 换到另一张雪碧图：先扔掉手里的旧帧（它可能马上被 LRU 淘汰并释放）
    if (_previewFrame != null && cell.spriteIndex != _previewSprite) {
      setState(() => _previewFrame = null);
    }
    _previewSprite = cell.spriteIndex;
    final gen = _previewGen;
    unawaited(service.frameAtMs(at).then((frame) {
      // 本轮拖动已结束/已复位（浮层已隐藏）→ 丢弃
      if (!mounted || gen != _previewGen) return;
      // 图已不是当前位置需要的那张（跨张了）→ 丢弃，避免显示错误区段
      if (frame == null || frame.spriteIndex != _previewNeededSprite()) return;
      setState(() => _previewFrame = _reframeAtCurrentPosition(frame));
    }));
  }

  /// 预览取帧时刻：贴到片尾（总时长）时回退 [kSeekPreviewEndGuardMs]。
  ///
  /// 时长未知（未就绪）→ 原样返回；视频比护栏还短 → 不折腾（照原样取）。
  int _previewMsAt(int ms) {
    final dur = _durationMs;
    if (dur <= 0) return ms;
    final maxMs = dur - kSeekPreviewEndGuardMs;
    if (maxMs <= 0) return ms;
    return ms > maxMs ? maxMs : ms;
  }

  /// 「当前位置」需要的是第几张雪碧图（-1 = 元信息不可用 / 该格无效）。
  ///
  /// 落地迟到结果时用它判「这张图还是当前需要的吗」，见 [_requestSeekPreview]。
  /// 用的时刻与取帧一致（同样过 [_previewMsAt]），否则贴到片尾时会把"回退过
  /// 的帧"误判成跨张而丢掉。
  int _previewNeededSprite() {
    final info = _videoShot?.info;
    if (info == null || info.shotCount == 0) return -1;
    final at = _previewMsAt(_positionMs);
    final shot = info.shotIndexForSeconds(at <= 0 ? 0 : at ~/ 1000);
    if (shot < 0) return -1;
    final cell = info.cellForShot(shot);
    return cell.width > 0 ? cell.spriteIndex : -1;
  }

  /// 把「同一张雪碧图」的结果落到**当前位置**的格上。
  ///
  /// 图是按发起时的格下载的，回来时手指可能已经移到同张图内的另一格（连续
  /// 拖动几百毫秒就能换好几格）→ 用当前位置重算裁剪矩形与秒数，画出来就是
  /// 手指此刻所指的时间。[VideoShotService.cellScale] 是服务层算裁剪用的同一个
  /// 缩放系数，避免两处各算一遍。
  ///
  /// 兜底：当前位置的格不可用（元信息边界情况 / 竟已跨张）→ 原样返回结果自带
  /// 的 `srcRect`（宁可差几格，也不画错图）。
  SeekPreviewFrame _reframeAtCurrentPosition(SeekPreviewFrame frame) {
    final info = _videoShot?.info;
    if (info == null) return frame;
    final at = _previewMsAt(_positionMs);
    final shot = info.shotIndexForSeconds(at <= 0 ? 0 : at ~/ 1000);
    if (shot < 0 || shot >= info.shotCount) return frame;
    final cell = info.cellForShot(shot);
    if (cell.width <= 0 || cell.spriteIndex != frame.spriteIndex) return frame;
    final scale = VideoShotService.cellScale(
      spriteWidth: frame.spriteWidth,
      info: info,
    );
    return frame.withCell(
      srcRect: Rect.fromLTWH(
        cell.left * scale,
        cell.top * scale,
        cell.width * scale,
        cell.height * scale,
      ),
      seconds: info.indexSeconds[shot],
    );
  }

  /// 预取「[ms] 位置」所在的那张雪碧图（用户最可能拖到当前位置附近）。
  ///
  /// 首次拖动看不到缩略图的根因是「图要现下现解 1.5~2.5s，而这一轮拖动往往
  /// 早就结束了」；提前把这张送进 LRU，第一次按住拖动就有图。服务未就绪
  /// （元信息还在路上）→ 先记下位置，等 [_prepareVideoShot] 就绪后补取。
  /// 已缓存 / 在途的那张由服务层去重，重复调用零成本；失败静默（纯增强）。
  void _prefetchVideoShotAt(int ms) {
    // 与取帧用同一套时刻（贴片尾回退 kSeekPreviewEndGuardMs）：预热的就是
    // 拖动到这儿真正要显示的那一格，否则片尾第一下拖动还得现下现解。
    final at = _previewMsAt(ms);
    _prefetchWantMs = at;
    final service = _videoShot;
    if (service == null || !service.isReady) return;
    unawaited(service.prefetchAtMs(at));
  }

  /// 预览浮层的横向摆放：轨道上的锚点 → 气泡左边缘（夹到轨道内，永不越界）。
  ///
  /// [anchorX] 是锚点在**轨道局部坐标**上的水平位置（与 [_PlayerSeekBar] 的
  /// 命中点同一套坐标：两端各内缩 `handleWidth/2`）——拖进度条时是手指位置
  /// （[_previewDragX]），手势横滑 seek 时是「位置比例映射回轨道的虚拟手指」
  /// （[_gestureSeekAnchorX]）。两条路径共用同一套换算，气泡观感一致。
  ///
  /// [bubbleWidth] 为 0（无缩略图，只有时间气泡）时按 [kSeekPreviewTimeBubbleW]
  /// 估算宽度——只影响「时间气泡居中于手指」的观感，不影响是否越界。
  double _seekPreviewLeft(
    double anchorX,
    double bubbleWidth,
    double trackWidth,
  ) {
    const inset = _PlayerSeekBar.handleWidth / 2;
    final span = trackWidth - _PlayerSeekBar.handleWidth;
    final width = bubbleWidth > 0 ? bubbleWidth : kSeekPreviewTimeBubbleW;
    if (span <= 0) return 0;
    final ratio = ((anchorX - inset) / span).clamp(0.0, 1.0);
    final center = inset + span * ratio;
    return (center - width / 2).clamp(0.0, math.max(0.0, trackWidth - width));
  }

  /// 手势横滑 seek 的「虚拟手指」在轨道上的坐标：按 [_positionMs]/[_durationMs]
  /// 比例映射到轨道可用宽度（与 [_PlayerSeekBar] 的命中点 → 时长换算互为逆
  /// 运算，同样两端各内缩 `handleWidth/2`）。
  ///
  /// 手势路径没有真实手指落在进度条上（手在视频区滑动），所以用「目标位置在
  /// 轨道上的比例位置」当锚点——观感就是「直接拖到了这里」，与拖进度条一致。
  double _gestureSeekAnchorX(double trackWidth) {
    const inset = _PlayerSeekBar.handleWidth / 2;
    final span = trackWidth - _PlayerSeekBar.handleWidth;
    if (span <= 0) return 0;
    final ratio =
        _durationMs > 0 ? (_positionMs / _durationMs).clamp(0.0, 1.0) : 0.0;
    return inset + span * ratio;
  }

  /// 拖动预览浮层（只应在 [_dragging] / [_gestureSeeking] 且轨道宽 > 0 时构建）。
  ///
  /// [trackWidth] 是轨道可用宽度、[anchorX] 是锚点（见 [_seekPreviewLeft]）：
  /// 两条 seek 路径各自给出自己的几何，浮层本身完全复用。
  ///
  /// 缩略图目标宽：非全屏 [kSeekPreviewThumbWCompact]（120）、全屏
  /// [kSeekPreviewThumbWFullscreen]（180）——**非全屏刻意做小**：视频区只有
  /// ~231dp 高，B 站式 ~90dp 预览框会吃掉半屏画面。高度由浮层按帧比例
  /// 折算（16:9 → 120×67.5 / 180×101.25），不拉伸变形。
  ///
  /// 轨道比缩略图还窄（超窄窗口 / 横屏置顶的窄盒）→ `bubbleWidth = 0`，
  /// 退化成「只显示时间气泡」，绝不越界。
  Widget _buildSeekPreview({
    required double trackWidth,
    required double anchorX,
  }) {
    final wantThumb = _fullscreen
        ? kSeekPreviewThumbWFullscreen
        : kSeekPreviewThumbWCompact;
    final withThumb = trackWidth >= wantThumb;
    final width = withThumb ? wantThumb : 0.0;
    return _SeekPreviewOverlay(
      key: const ValueKey('seek-preview-overlay'),
      timeLabel: _fmtMs(_positionMs),
      frame: withThumb ? _previewFrame : null,
      left: _seekPreviewLeft(anchorX, width, trackWidth),
      bubbleWidth: width,
    );
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
  //   水平主导：seek（位移比例 = 时长比例，松手 seekTo；v2.18.x 起竖屏 /
  //             横屏置顶 / 横屏全屏统一可用，见 [canGestureSeek]；本版起
  //             呈现成「直接拖进度条」：手柄跟手 + 预览气泡，控制层收着时
  //             只浮出进度条行，见 [_buildSeekRowOnly]）
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

  // ---------- 滑动统一 Pan：按下判豁免 → 起点记录 → 主导方向锁定 → 分发 ----------

  /// 侧边豁免带宽度（px，v2.16.17+）：横屏（width > height，**物理底边 =
  /// 逻辑左/右边**，见类顶注释）→ 与底部同宽策略（短边 ×8% or 48px 取较大，
  /// 覆盖 3-button/手势导航条物理高度换算 + 手指按下点容差）；竖屏 → 窄带
  /// 防误触（物理底边 = 逻辑底边，已有底部豁免覆盖，左右窄带仅防边缘误启动
  /// 亮度/音量）。
  double _sideGestureExclusionPx(Size size) {
    if (size.width > size.height) {
      return math.max(
          size.height * kBottomGestureExclusionFactor,
          kBottomGestureExclusionMinPx);
    }
    return kSideGestureExclusionPxPortrait;
  }

  /// 非全屏视频区黑盒高度（竖屏置顶 v2.17.0 / 横屏置顶模式 v2.17.17 共用）：
  /// 按视频宽高比铺满可用宽（顶部置顶），再按方向封顶留出信息行与评论区：
  /// 竖屏超高视频（如 9:16）按比例会顶掉下方内容区 → 封顶屏高
  /// [kPortraitVideoHeightRatio]（60%）；横屏（宽>高）16:9 视频按屏宽换算的
  /// 理想高度 ≈ 整屏高 → 封顶 [kLandscapeVideoHeightRatio]（55%，略低于竖屏
  /// 档位，多让空间给下方评论区）。盒内画面统一按 AspectRatio 居中 + 黑边
  /// 补齐。
  double _embeddedVideoHeight(Size screen) {
    final aspect = _aspectRatio > 0 ? _aspectRatio : 16 / 9;
    final ideal = screen.width / aspect;
    final capRatio = screen.width > screen.height
        ? kLandscapeVideoHeightRatio
        : kPortraitVideoHeightRatio;
    final maxH = screen.height * capRatio;
    return ideal > maxH ? maxH : ideal;
  }

  /// 手势层所在矩形的逻辑尺寸：全屏 = 屏幕；非全屏 = 视频区黑盒（宽 = 屏宽、
  /// 高 = [_embeddedVideoHeight]）。亮度/音量纵向换算、半屏分界与豁免带判定
  /// 均以手势层自身为准——非全屏（竖屏/横屏置顶）时手势只发生在视频区内
  /// （不覆盖下方评论区）。
  Size _gestureAreaSize() {
    final s = MediaQuery.sizeOf(context);
    if (_fullscreen) return s;
    return Size(s.width, _embeddedVideoHeight(s));
  }

  /// 当前是否允许水平滑动 seek：把状态喂给纯函数 [canGestureSeek]（竖屏 /
  /// 横屏置顶 / 横屏全屏统一判定，不再看 `_fullscreen`——v2.18.x 起用户
  /// 反馈竖屏也要能左右滑调进度）。
  bool get _canSeekByGesture =>
      canGestureSeek(listenMode: _listenMode, durationMs: _durationMs);

  /// 按下即判豁免（v2.16.17+，用**触摸按下点**而非 panStart 的竞技场胜出点）：
  /// onPanDown 在手指按下第一时间回调（尚未位移 / 未进 arena），localPosition
  /// 即真实触摸起点；而 onPanStart 的坐标是手势**赢得竞技场那一刻**的位置
  /// （已滑过 touch slop、且边缘滑动常被系统手势区延迟释放——实测横屏右缘
  /// 起点内移可达 ~100px），按它判边缘豁免带会漏判。命中豁免带
  /// （[isExcludedGestureStart]）→ [_panExcluded] = true，本次 Pan 整体忽略
  /// （update/end/cancel 早退，不 seek / 不调亮度音量 / 不出 hud）——横屏全屏
  /// 从**物理屏幕底部**滑动（旋转后 = 逻辑左或右边缘，取决于 landscapeLeft/
  /// Right）唤醒系统导航不再误触发 seek。tap / 双击 / 长按不走 Pan 竞技场
  /// （tap 无位移不触发 Pan），按下点豁免不影响单击显隐等。
  void _onPanDown(DragDownDetails d) {
    if (_player == null) return;
    // 双指手势进行中（v2.39.0；v2.43.0 起非全屏同样生效）：单指那一套整体
    // 让位——Pan 识别器此时可能已赢下竞技场（两指同向拖动就是一次合法的
    // pan），但语义上属于画面手势（非全屏时是"用户在捏合"，不是"他在横滑"）。
    if (_viewGestureActive) return;
    final size = _gestureAreaSize();
    final w = size.width;
    final h = size.height;
    final sidePx = _sideGestureExclusionPx(MediaQuery.sizeOf(context));
    // 底部豁免带只在**全屏**生效（v2.18.x+）：该带的语义是「物理屏幕底边 =
    // 系统导航区」，而全屏时手势层 = 整屏，底边才等于物理屏幕底边。非全屏
    // 手势层只是视频黑盒，其底边落在屏幕中部（竖屏 411×914 时视频区高
    // ≈231dp、底边 ≈ 屏高 1/4 处），那里既没有系统导航区，又会被
    // 「高 × 8% or 48px」白吃掉竖屏约 21% 的有效起手区——直接关闭（两参数
    // 同传 0）。顶部带（视频区顶边 = 屏幕顶边，护状态栏）与左右窄带保留。
    final bottomFactor = _fullscreen ? kBottomGestureExclusionFactor : 0.0;
    final bottomMinPx = _fullscreen ? kBottomGestureExclusionMinPx : 0.0;
    if (isExcludedGestureStart(
          x0: d.localPosition.dx,
          y0: d.localPosition.dy,
          width: w,
          height: h,
          bottomFactor: bottomFactor,
          bottomMinPx: bottomMinPx,
          leftPx: sidePx,
          rightPx: sidePx,
        )) {
      _panExcluded = true;
      debugPrint('[player_page] 手势按下点在豁免带 x0='
          '${d.localPosition.dx.toStringAsFixed(0)}px y0='
          '${d.localPosition.dy.toStringAsFixed(0)}px'
          '（手势面 ${w.toInt()}x${h.toInt()}，fullscreen=$_fullscreen，'
          'bottomFactor=$bottomFactor，side=${sidePx.toStringAsFixed(0)}px）'
          '→ 本次 Pan 忽略（让给系统手势）');
    } else {
      _panExcluded = false;
    }
  }

  /// 手势赢得竞技场（已过 touch slop）：记录起点（x0 供垂直模式半屏判亮度/
  /// 音量），状态复位为未定，清掉上一手势残留 hud（延迟隐藏计时同步取消）。
  /// 豁免判定不在这里做（按下点已判，见 [_onPanDown]）；命中时直接早退——
  /// 不再 seek / 不调亮度音量 / 不出 hud。
  void _onPanStart(DragStartDetails d) {
    if (_player == null) return;
    if (_panExcluded) {
      debugPrint('[player_page] 按下点已豁免 → panStart 早退（本次 Pan 忽略）');
      return;
    }
    if (_viewGestureActive) {
      debugPrint('[player_page] 双指手势中 → panStart 早退（单指语义让位）');
      return;
    }
    // 缩放 / 旋转生效后（v2.39.0）：单指拖动 = **平移画面**（iOS / YouTube /
    // B 站的通行做法），不再走三向判定——此时用户想看的正是「被放大后的
    // 局部」，横滑 seek 会把画面动机变成碰运气。scale==1 且无旋转时完全走
    // 下面的原逻辑（零回归）。
    if (_viewTransformed) {
      _viewPanRaw = _viewOffset;
      debugPrint('[player_page] 缩放态单指拖动 → 平移画面 '
          'scale=$_viewScale rot=${_viewRotation.toStringAsFixed(2)}');
      return;
    }
    _panMode = null;
    _panStartX = d.localPosition.dx;
    _panDx = 0;
    _panDy = 0;
    _hudTimer?.cancel();
    if (_hudKind != null) setState(() => _hudKind = null);
    final size = _gestureAreaSize();
    debugPrint('[player_page] 手势开始 x0=${_panStartX.toStringAsFixed(0)}px '
        'y0=${d.localPosition.dy.toStringAsFixed(0)}px '
        'fullscreen=$_fullscreen（手势面 ${size.width.toInt()}x${size.height.toInt()}）');
  }

  /// 手势滑动：先累计位移并尝试锁定主导方向（锁定后不再切换），
  /// 再按锁定模式分发到 seek / 亮度·音量逻辑。
  void _onPanUpdate(DragUpdateDetails d) {
    if (_panExcluded) return; // 豁免带起点：本次 Pan 已整体忽略
    if (_viewGestureActive) return; // 双指手势中：单指语义不参与
    if (_viewTransformed) {
      _onViewPanUpdate(d); // 缩放态：拖动 = 平移画面（不发 seek）
      return;
    }
    if (_panMode == null) {
      _panDx += d.delta.dx;
      _panDy += d.delta.dy;
      final m = nextPanMode(current: null, dx: _panDx, dy: _panDy);
      if (m != null) _lockPanMode(m);
    }
    switch (_panMode) {
      case PanSlideMode.horizontal:
        // 水平主导 → seek（竖屏 / 横屏统一；听视频 / 时长未知时
        // [_canSeekByGesture] 为 false，此时 [_seekDragging] 也没建立，
        // [_onSeekDragUpdate] 自身还会二次早退）
        if (_canSeekByGesture) _onSeekDragUpdate(d);
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
        // v2.18.x：不再要求全屏（[_canSeekByGesture] 只看听视频 / 时长），
        // 竖屏也能横滑 seek
        if (_canSeekByGesture) _beginSeekDrag();
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
    if (_viewGestureActive || _viewTransformed) {
      // 双指手势中 / 缩放态平移：偏移已实时生效，松手无需收尾（不 seek）
      _viewPanRaw = _viewOffset;
      _panMode = null;
      return;
    }
    final m = _panMode;
    _panMode = null;
    switch (m) {
      case PanSlideMode.horizontal:
        // 竖屏 / 横屏统一（同 [_lockPanMode]）；未建立 seek 拖动时
        // [_onSeekDragEnd] 自身早退，不会误 seekTo
        if (_canSeekByGesture) await _onSeekDragEnd(d);
        break;
      case PanSlideMode.vertical:
        _onVerticalDragEnd(d);
        break;
      case null:
        break;
    }
  }

  /// 手势被系统打断（来电 / 通知栏下拉等）：复位拖动状态，
  /// 避免 _seekDragging 一直卡住 tick 位置刷新；手势 seek 的 UI 态
  /// （[_gestureSeeking] + 预览气泡）同步收起，不留残影。
  void _onPanCancel() {
    _panExcluded = false;
    _panMode = null;
    if (_seekDragging) {
      _seekDragging = false;
      setState(() {
        _gestureSeeking = false;
        _endSeekPreviewRound();
      });
      _scheduleHudHide(const Duration(milliseconds: 600));
    }
    if (_adjustKind != null) {
      _adjustKind = null;
      _adjustReady = false;
      _scheduleHudHide(const Duration(milliseconds: 700));
    }
  }

  // ---------- horizontal（水平主导）→ seek（竖屏 / 横屏统一） ----------
  //
  // 本版起：这条路径的**呈现**与「直接拖进度条」对齐（用户需求「左右滑动
  // 播放页 = 直接拖动进度条 + 预览气泡」）——三个可复用点：
  //   1. [_positionMs] 拖动中跟着目标位置走 → 进度条手柄/已播段跟手
  //      （[_showSeekHud] 之外不额外算位置，与拖进度条的 [_onSeekStart] 同款）；
  //   2. 预览帧走既有 [_requestSeekPreview]（节流 + 防陈旧 + 预取命中）；
  //   3. 气泡复用 [_SeekPreviewOverlay]，锚点 = 「位置比例映射回轨道的虚拟
  //      手指」→ 与拖进度条同一套换算（见 [_gestureSeekAnchorX]）。
  // 控制层收着时只把进度条行浮出来（[_buildSeekRowOnly]），不动
  // [_controlsVisible]（显隐是用户点画面定下的偏好）。

  /// 锁定为水平且当前允许 seek（见 [canGestureSeek]）：初始化 seek（基准 =
  /// 当前播放位置，位移从锁定起累计）。时长未知（<=0）时不建拖动状态
  /// （纯防御，正常入口已被 [_canSeekByGesture] 拦下）。
  void _beginSeekDrag() {
    if (_player == null || _durationMs <= 0) return;
    _seekDragging = true;
    _seekDragBaseMs = _positionMs;
    _seekDragDx = 0;
    _seekDragSpan = MediaQuery.sizeOf(context).width;
    setState(() {
      _gestureSeeking = true;
      _beginSeekPreviewRound(); // 起手复位上一轮残留（同拖进度条路径）
    });
    _showSeekHud(_positionMs);
    _requestSeekPreview(_positionMs);
    debugPrint('[player_page] seek 开始 base=${_positionMs}ms '
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
    // 位置跟着目标走：进度条手柄与已播段跟手（同拖进度条路径的
    // [_onSeekStart]）；[_seekDragging] 期间 tick 不回写位置，不会被顶掉
    setState(() => _positionMs = target);
    _showSeekHud(target);
    _requestSeekPreview(target);
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
    debugPrint('[player_page] seekTo ${target}ms'
        '（比例 ${fraction.toStringAsFixed(2)}）');
    await _player?.seekTo(target);
    _resetWatchBaseline(); // seek 跳变：跳过内容不计观看时长
    if (mounted) {
      setState(() {
        _positionMs = target;
        // 松手即收：手柄恢复原显示逻辑、气泡消失（在途的迟到结果由代次作废）
        _gestureSeeking = false;
        _endSeekPreviewRound();
      });
    }
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
    final area = _gestureAreaSize();
    final kind = verticalSlideKind(_panStartX, area.width);
    debugPrint('[player_page] 垂直手势开始 kind=${kind.name} '
        'x=${_panStartX.toStringAsFixed(0)}px');
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
  ///
  /// **预览管线可用时不出这个浮层**（本版起）：横滑 seek 已经改成「直接拖
  /// 进度条」的呈现（手柄跟手 + 进度条上方带缩略图的预览气泡，气泡自带时间，
  /// 见 [_buildSeekPreview]），再叠一个居中大号时间浮层就是同一份读数来两遍
  /// ——竖屏视频区只有 ~231dp 高，两者必然重叠。管线不可用（服务未注入 /
  /// 未就绪 / 接口挂了）→ 保持原样给居中时间浮层，这是降级路径下唯一的
  /// 「当前位置 / 总时长」读数（那时气泡只剩时间条，位置在底部）。
  /// 亮度 / 音量浮层走 [_showValueHud]，与此无关。
  void _showSeekHud(int posMs) {
    if (!mounted) return;
    _hudTimer?.cancel();
    if (_videoShot?.isReady ?? false) {
      // 上一帧可能还留着 seek 浮层（管线中途就绪）→ 顺手收起
      if (_hudKind == PlayerSlideKind.seek) setState(() => _hudKind = null);
      return;
    }
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
  ///
  /// 双指手势进行中直接忽略（v2.39.0）：捏合/旋转时若第一指已按下 500ms，
  /// LongPress 会赢下竞技场把播放打到 2x——那时用户是在调整画面，不是要快进。
  void _onLongPressStart(LongPressStartDetails _) {
    if (_viewGestureActive) return;
    debugPrint('[player_page] longPress start, speedBefore=$_speed');
    _speedBeforeLongPress = _speed;
    _longPressSpeedActive = true;
    _applySpeed(kLongPressSpeed);
  }

  /// 长按结束：恢复进入长按前的倍速（而非 1x）。
  void _onLongPressEnd(LongPressEndDetails _) {
    if (!_longPressSpeedActive) return; // 双指接管时已放掉，不重复恢复
    _longPressSpeedActive = false;
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
                  style: TextStyle(color: kPlayerOnDim, fontSize: 13)),
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
                        color: s == _speed ? kPlayerOn : kPlayerOff,
                        fontSize: 16,
                        fontWeight: s == _speed
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: s == _speed
                        ? const Icon(Icons.check,
                            color: kPlayerOn, size: 20)
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
    // 通知副标题跟着变（听视频时显示「后台听视频省流量」，与 B 站一致）
    unawaited(_syncNowPlaying());
  }

  /// 评论按钮行为（v2.17.0+ 竖屏布局重构 / v2.17.17 横屏置顶共用 /
  /// v2.17.1+ 链接跳转语义）：
  ///
  /// - **横屏全屏（_fullscreen=true）**：push 独立 [CommentPage]（全屏下无
  ///   内嵌评论区；本页在 C 下面照常出声 = 边看边评）。C 内点视频链接 →
  ///   C 先 pop 自己回本页，再由本页 [openVideoInNewPlayer] push 新播放页
  ///   （push 前显式暂停本页防双音轨）；返回本页 → [didPopNext] 恢复续播。
  /// - **非全屏（竖屏置顶 / 横屏置顶）**：评论区已内嵌在视频下方内容区，
  ///   点按即「滚动定位到评论区」——用 [Scrollable.ensureVisible] 平滑滚动
  ///   使列表顶「评论 N」区头贴到内容区顶（锚点 [_commentCountHeaderKey]）；
  ///   列表尚未加载出区头（首屏加载/暂无评论等）时兜底把列表滚回顶部
  ///   （内容区即从评论区起，回到顶部等价于定位到评论区）。
  void _onCommentsButtonTap() {
    if (!mounted) return;
    debugPrint('[player_page] 评论按钮 _fullscreen=$_fullscreen '
        'bvid=${_video.bvid} epId=${_video.epId}');
    if (_fullscreen) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CommentPage(
            video: _video,
            // 独立评论页 C 内点视频链接 → C pop 自己后本方法 push 新播放页
            // （不开新页时 C 已关，保持现状即可）。路由不带 'player' 名 →
            // C 未命名 'player' 且不触发暂停 → 本页边看边评照常播放。
            onNavigateToVideo: openVideoInNewPlayer,
          ),
        ),
      );
      return;
    }
    final headerCtx = _commentCountHeaderKey.currentContext;
    if (headerCtx != null) {
      Scrollable.ensureVisible(
        headerCtx,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        alignment: 0.0,
      );
      return;
    }
    if (_commentScroll.hasClients) {
      _commentScroll.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
  }

  /// 评论内视频链接（内嵌评论区 / 独立评论页 [CommentPage]）点击分发
  /// （v2.17.1+ 跳转语义 → v2.17.6+ 支持 ?p/?t 定位）。
  ///
  /// [pageIndex]（0 起分 P）/ [positionMs]（毫秒进度）来自链接 query ?p/?t
  /// （见 utils/comment_links.dart；无参数链接两者均 null）。分发语义：
  ///
  /// **无定位参数**（维持 v2.17.1+ 行为）：
  /// - 同 bvid 且在播第 0 集（点的是本视频自身第 1 集链接）→ 不暂停不叠页；
  /// - 其余 → 叠新 [PlayerPage]（从目标视频开头播，进度/历史独立；返回 →
  ///   本页 [didPopNext] 恢复 A 续播）。
  ///
  /// **带 ?p/?t**（v2.17.6+，语义 = 「跳到该视频该分 P 该时间」，链接定位
  /// 优先于记忆进度）：
  /// - 同 bvid：**本页内跳**（[_switchToPage] 切分 P + [_seekCurrentTo] 定位
  ///   t）——不叠页不打断，返回键仍回上一个视频、省一个播放器实例（取舍：
  ///   多 P 视频评论区点自家另一集链接 = 原地切集，与选集 UI 一致；详见
  ///   分发注释）；目标分 P 超出本页已加载 pages 时兜底叠新页（新页拿到的
  ///   video 自带全量 pages，initState 会按实际集数钳制）。
  /// - 不同 bvid：叠新 [PlayerPage] 并传 initialPageIndex + initialPositionMs
  ///   （新页首次定位即覆盖其记忆进度——用户明确点了链接指定位置）。
  ///
  /// 叠页前先 [_pauseBeforePushingNewPlayer] 暂停本页（旧视频 A）并保存进度
  /// （无双音轨）；返回 → 本页 [didPopNext] 恢复 A 续播。playVideo 换源语义
  /// 保留给多 P 切集等**内部**换源场景（不再由评论触发）。
  void openVideoInNewPlayer(
    WhitelistVideo video, {
    int? pageIndex,
    int? positionMs,
  }) {
    if (!mounted) return;
    final sameBvid = video.bvid == _video.bvid;
    final hasJump = pageIndex != null || positionMs != null;

    if (!hasJump) {
      // 无 ?p/?t：维持 v2.17.1+ 语义（无定位 = 从目标视频开头播）
      if (sameBvid && _currentPageIndex == 0) {
        debugPrint('[player_page] 评论链接同 bvid=${video.bvid}，跳过叠页');
        return;
      }
      _pushNewPlayer(video);
      return;
    }

    // 带 ?p/?t → 明确「跳到该视频该分P该时间」
    final targetIdx = pageIndex ?? _currentPageIndex; // 无 p 视为当前集
    final pages = _pages;
    final canSwitchInPlace =
        pages != null && targetIdx >= 0 && targetIdx < pages.length;
    if (sameBvid) {
      if (targetIdx == _currentPageIndex) {
        // 目标 = 正在播的集：只需定位 t（无 t → 原地无动作）
        if (positionMs != null && positionMs > 0) {
          debugPrint('[player_page] 评论链接同 bvid 同集带 t=${positionMs}ms，'
              '本页定位');
          unawaited(_seekCurrentTo(positionMs));
        } else {
          debugPrint('[player_page] 评论链接同 bvid 同集无 t，原地无动作');
        }
        return;
      }
      if (canSwitchInPlace) {
        // 目标为其他分 P 且本页 pages 可覆盖 → 原地切集（t 交给切集后定位）
        debugPrint('[player_page] 评论链接同 bvid 跳分P '
            '$targetIdx${positionMs != null ? ' +t=${positionMs}ms' : ''}，'
            '本页切集');
        unawaited(_switchToPage(targetIdx, seekMs: positionMs));
        return;
      }
      // 本页 pages 覆盖不了（单 P 数据缺 pages / 越界）：落到叠新页兜底
    }
    _pushNewPlayer(video,
        initialPageIndex: targetIdx, initialPositionMs: positionMs);
  }

  /// 叠新 [PlayerPage]（评论链接跳不同视频 / 同 bvid 兜底共用）。
  ///
  /// [initialPageIndex]/[initialPositionMs] 只在链接带 ?p/?t 时非默认（由调用
  /// 方按 [openVideoInNewPlayer] 的 pageIndex/positionMs 换算传入）：>0 分 P /
  /// >0 进度 → 新页首备后直接定位（覆盖其记忆进度）；不带参时维持 v2.17.1+
  /// 从开头播/记忆进度行为。
  ///
  /// **不继承本页的播放列表**（v2.30.0+）：评论区的视频链接、搜索结果等来自
  /// 另一个语境，其「上一条/下一条」与当前合集无关——把本页的 [_playlistVideos]
  /// 漏给新页会造出「下一集」跳到合集里某条毫不相干的视频。新页只在自己
  /// 被点进来的那条路上带 playlist（见 [PlayerPage.playlist]）。
  void _pushNewPlayer(
    WhitelistVideo video, {
    int initialPageIndex = 0,
    int? initialPositionMs,
  }) {
    debugPrint('[player_page] 评论链接 push 新播放页(name=$kPlayerRouteName) '
        '${_video.bvid}#$_currentPageIndex -> ${video.bvid}'
        '${initialPageIndex != 0 ? ' p${initialPageIndex + 1}' : ''}'
        '${initialPositionMs != null ? ' t=${initialPositionMs}ms' : ''} '
        'title=${video.title}');
    // 先暂停自己（防双音轨）+ 保存进度；再从自己头上叠新播放页。
    // 顺序不能反：若先 push，新页出声时本页还在播 → 双音轨瞬间成立。
    _pauseBeforePushingNewPlayer();
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: kPlayerRouteName),
      builder: (_) => PlayerPage(
        video: video,
        initialPageIndex: initialPageIndex,
        initialPositionMs: initialPositionMs,
      ),
    ));
  }

  /// 同视频同集带 t：把当前集定位到链接进度（覆盖记忆；[pageIndex] 未指定/
  /// 等于当前集时由 [openVideoInNewPlayer] 调用）。
  ///
  /// - 播放器已就绪（loaded）→ 直接 seekTo（按当前集时长钳制贴结尾进度）；
  /// - 首备/取流中（未 loaded 且 [_pendingRestore] 未消费）→ 先记
  ///   [_pendingSeekMs]，等 onPrepared 时由 [_maybeRestoreProgress] 定位；
  /// - 无播放器/错误态（不在可定位窗口）→ 忽略（保持现状，不强跳）。
  Future<void> _seekCurrentTo(int positionMs) async {
    final player = _player;
    if (player == null || (!_loaded && !_pendingRestore)) {
      debugPrint('[player_page] 同集 t 跳转跳过（player=${player != null} '
          'loaded=$_loaded pendingRestore=$_pendingRestore）');
      return;
    }
    if (!_loaded) {
      // 首备未完成：并入队给 onPrepared 定位（此时时长未知，不预钳制）
      _pendingSeekMs = positionMs;
      debugPrint('[player_page] 同集 t 跳转入队（onPrepared 定位）'
          ' ${_video.bvid}#$_currentPageIndex $positionMs ms');
      return;
    }
    final target = _clampSeekPosition(positionMs);
    debugPrint('[player_page] 评论链接同集跳进度 seekTo $target ms '
        '${_video.bvid}#$_currentPageIndex');
    await player.seekTo(target);
    _resetWatchBaseline(); // 评论链接跳进度：跳过内容不计观看时长
    if (mounted) setState(() => _positionMs = target);
  }

  /// 把请求的定位进度钳到当前集时长内（留 1s 余量让播放器能自然触发完成；
  /// 链接 t 超出时长/贴结尾 → 从末尾附近开始，与 B 站 web 语义一致）。
  int _clampSeekPosition(int ms) {
    final maxMs = _durationMs - 1000;
    if (maxMs > 0 && ms > maxMs) return maxMs;
    return ms;
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
          await _api.fetchSubtitles(_video.bvid, _currentCid);
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
                    style: TextStyle(color: kPlayerOnDim, fontSize: 13)),
              ),
              SwitchListTile(
                dense: true,
                title: const Text('显示字幕',
                    style: TextStyle(color: kPlayerOn, fontSize: 15)),
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
            child: CircularProgressIndicator(color: kPlayerOn),
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
                        const TextStyle(color: kPlayerOnDim, fontSize: 13)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _loadSubtitleTracks(onChanged: refresh),
                  style:
                      OutlinedButton.styleFrom(foregroundColor: kPlayerOn),
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
                  style: TextStyle(color: kPlayerOnDim, fontSize: 14)),
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
                      strokeWidth: 2, color: kPlayerOn),
                ),
                const SizedBox(width: 8),
                Text('翻译中 $_translationDone/$_translationTotal',
                    style:
                        const TextStyle(color: kPlayerOnDim, fontSize: 12)),
              ],
            ),
          )
        else if (_translationTotal > 0 && _translationError == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Text('已翻译 $_translationDone/$_translationTotal 条',
                style: const TextStyle(color: kPlayerOnDim, fontSize: 12)),
          ),
        if (_translationError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Text('翻译失败：$_translationError',
                style: const TextStyle(color: kError, fontSize: 12)),
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
              style: const TextStyle(color: kPlayerOnDim, fontSize: 12)),
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
                        strokeWidth: 2, color: kPlayerOn),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('转写中…',
                        style:
                            TextStyle(color: kPlayerOnDim, fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: _stopRealtime,
                    style: TextButton.styleFrom(
                        foregroundColor: kPlayerOnDim),
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
                  style: const TextStyle(color: kPlayerOff, fontSize: 12),
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
                    color: kSuccess, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '✅ 实时转写完成（${list.length} 句）· 已作为字幕',
                    style: const TextStyle(
                        color: kSuccess, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: _startRealtime,
                  style: TextButton.styleFrom(
                      foregroundColor: kPlayerOnDim),
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
                  style: const TextStyle(color: kError, fontSize: 12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: OutlinedButton(
                onPressed: _startRealtime,
                style:
                    OutlinedButton.styleFrom(foregroundColor: kPlayerOn),
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
                  backgroundColor: kPlayerOn,
                  foregroundColor: kInkBlack,
                ),
                child: const Text('🎙 实时转写'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('流式识别，边播边出字幕（首次需下载模型 247MB）',
                  style: TextStyle(color: kPlayerOff, fontSize: 12)),
            ),
            if (_realtimeModelDir.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('也可手动放置模型文件到：$_realtimeModelDir',
                    style: const TextStyle(color: kPlayerRule, fontSize: 11)),
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
              style: const TextStyle(color: kPlayerOnDim, fontSize: 12)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: LinearProgressIndicator(
            value: v,
            color: kPlayerOn,
            backgroundColor: kPlayerRule,
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
        style: const TextStyle(color: kPlayerOff, fontSize: 12),
      ),
    );
  }

  /// 开始实时转写（sherpa 流式）：模型 → 音频 → 流式转写 + 逐句翻译。
  /// 阶段/进度/partial/句子由单例 ValueNotifier 驱动面板与字幕层刷新；
  /// 错误：start 内部已置 stage=error + error 文案（面板红字），这里补 SnackBar。
  Future<void> _startRealtime() async {
    if (_realtime.isRunning) return;
    try {
      await _realtime.start(_video, _currentPageIndex);
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
          style: const TextStyle(color: kPlayerOnDim, fontSize: 12)),
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
              ? kPlayerOff
              : isSelected
                  ? kPlayerOn
                  : kPlayerOnDim,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check, color: kPlayerOn, size: 18)
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
          color: isSelected ? kPlayerOn : kPlayerOff,
          fontSize: 14,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check, color: kPlayerOn, size: 18)
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
    final bvid = _video.bvid;
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
            bvid: _video.bvid, cid: _currentCid)
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
          bvid: _video.bvid, cid: _currentCid);
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
      _downloads.getCached(_video.bvid, _currentPageIndex);

  /// 当前集下载任务（下载中/排队；无则 null）。
  DownloadTask? get _currentTask => _downloads.tasks.value[
      CachedVideo.keyOf(_video.bvid, _currentPageIndex)];

  /// 切换播放源（本地缓存 ⇄ 网络流，v2.39.0+，入口在缓存操作菜单里）。
  ///
  /// 为什么要「取当前进度 → 重新设源 → 带 positionMs 定位」而不是别的路：
  /// - 不走 [playVideo]：它对同 bvid 直接短路返回（换源语义是换视频，不是换源）；
  /// - 不走 [_switchToPage]：那是切分 P，会清字幕/弹幕/拖动预览（同集换源不该
  ///   把这些擦掉）；
  /// - 走 [_loadStreamAndPlay]：它就是「按当前 [_playSource] 决定本地还是网络」
  ///   的唯一入口（同集重取流换源的既有写法，见 [_maybePrefetchSource]），
  ///   且 positionMs 是原生 `setDataSource` 的既有参数 → 进度无缝接上。
  ///
  /// 进度取 [BiliDashPlayer.getPosition] 的真值而**不是** [_positionMs]：后者靠
  /// 500ms 一次的 [_tick] 刷新，切源时刻最多落后半秒，用它会每次都往回退一点。
  ///
  /// 失败回退（风控 -412 / 断网）：**源字段与实际播放的源一起退回**。只回退
  /// 字段是不够的——字段是「下一次取源走哪条路」和菜单勾选态的唯一依据，若
  /// 字段已指向网络而实际播着本地（或反过来），下次取源就会按错的假设走，且
  /// 菜单会骗人。所以回退时重新 [_loadStreamAndPlay] 一次把上一源真正装回去，
  /// 再用 [SnackBar] 说明；连回退都失败才交给 [_handleLoadFailure] 走统一错误页。
  Future<void> _switchPlaySource(PlaySource target) async {
    final player = _player;
    if (player == null) return;
    if (target == _playSource) return; // 已是该源：无事发生
    if (_sourceSwitching) return; // 连点保护（内部有 await 取流）
    _sourceSwitching = true;
    final prev = _playSource;
    try {
      final pos = await player.getPosition();
      if (!mounted) return;
      debugPrint('[player_page] 切换播放源 ${prev.name} → ${target.name} '
          '（带进度 ${pos}ms）');
      setState(() {
        _playSource = target;
        _buffering = true;
        _error = null; // 上一次的错误态不该压在换源结果上（新源可能没问题）
        _canRetry = true;
      });
      try {
        await _loadStreamAndPlay(positionMs: pos);
        await _player?.setPlaybackSpeed(_speed); // 换源后原生倍速被重置为 1x
        if (mounted) setState(() => _buffering = false);
      } catch (e) {
        debugPrint('[player_page] 切换播放源失败（$e）→ 回退 ${prev.name}');
        if (!mounted) return;
        setState(() {
          _playSource = prev; // 字段与实际播放的源必须一致（见方法注释）
          _buffering = true;
        });
        try {
          await _loadStreamAndPlay(positionMs: pos);
          await _player?.setPlaybackSpeed(_speed);
          if (mounted) setState(() => _buffering = false);
          if (mounted) {
            _showSnack(prev == PlaySource.local
                ? '网络取流失败，已回到本地缓存播放'
                : '本地缓存不可用，已回到网络流播放');
          }
        } catch (retryE) {
          // 两个源都装不回来：没有可播的源了，交给统一失败处理（错误页 + 重试）
          if (!mounted) return;
          await _handleLoadFailure(retryE);
        }
      }
    } finally {
      _sourceSwitching = false;
    }
  }

  /// 点击下载按钮：未缓存 → 下载菜单；已缓存 → 缓存操作菜单；下载中不响应。
  ///
  /// v2.29.0 起菜单里多了「仅缓存音频」（省空间：30 分钟视频 15~36MB vs
  /// 整段 200~500MB）；已缓存时也给这一项——已整段缓存过的视频可以重下成
  /// 仅音频把空间收回来（覆盖式重下，旧的视频文件会被清掉）。
  /// v2.39.0 起已缓存菜单里还有「本地缓存 ⇄ 网络流」切换（[PlaySource]）。
  void _onDownloadTap() {
    final task = _currentTask;
    if (task != null &&
        (task.status == DownloadStatus.queued ||
            task.status == DownloadStatus.downloading)) {
      return; // 下载中/排队：按钮只显示进度，不弹菜单
    }
    final cached = _currentCached;
    final partTitle = _currentPartTitle;
    // 已缓存时把缓存形态写进副标题：「仅缓存音频」的集点进来没有画面，
    // 这里先说清楚，别让用户以为是播放器坏了
    final subtitle = cached != null && cached.audioOnly
        ? '${partTitle.isEmpty ? _video.title : partTitle} · 仅缓存音频'
        : partTitle;
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
                  style: const TextStyle(color: kPlayerOn, fontSize: 15)),
              subtitle: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kPlayerOnDim, fontSize: 12),
              ),
            ),
            const Divider(height: 1),
            if (cached == null) ...[
              ListTile(
                leading:
                    const Icon(Icons.download_outlined, color: kPlayerOn),
                title: const Text('下载本集',
                    style: TextStyle(color: kPlayerOn, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDownloadPage(_currentPageIndex);
                },
              ),
              ListTile(
                leading: const Icon(Icons.audiotrack_outlined,
                    color: kPlayerOn),
                title: const Text('仅缓存音频（省空间，无画面）',
                    style: TextStyle(color: kPlayerOn, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDownloadPage(_currentPageIndex, audioOnly: true);
                },
              ),
              if (_video.isMultiPage)
                ListTile(
                  leading: const Icon(Icons.download_done,
                      color: kPlayerOn),
                  title: Text('下载全部集（${_video.pageCount} 集）',
                      style:
                          const TextStyle(color: kPlayerOn, fontSize: 15)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmDownloadAll();
                  },
                ),
              if (_video.isMultiPage)
                ListTile(
                  leading: const Icon(Icons.audiotrack_outlined,
                      color: kPlayerOn),
                  title: Text('仅缓存音频（全部 ${_video.pageCount} 集）',
                      style:
                          const TextStyle(color: kPlayerOn, fontSize: 15)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmDownloadAll(audioOnly: true);
                  },
                ),
            ] else ...[
              // 本地缓存 ⇄ 网络流（v2.39.0+）：**放在菜单第一项**——这是
              // 「缓存了音频之后看不了画面」的唯一出口，压在「重新下载」下面
              // 用户找不到（重下要重新花流量/时间，而切源立刻就能看）。
              ListTile(
                leading: Icon(
                  _playSource == PlaySource.local
                      ? Icons.cloud_outlined
                      : Icons.sd_storage_outlined,
                  color: kPlayerOn,
                ),
                title: Text(
                  _playSource == PlaySource.local
                      ? '切到网络流播放（看画面/更高清晰度）'
                      : '切回本地缓存播放（省流量/离线可用）',
                  style: const TextStyle(color: kPlayerOn, fontSize: 15),
                ),
                subtitle: Text(
                  // 仅音频缓存时把话说透：本地源**物理上没有视频轨**，切回本地
                  // 就是黑屏有声，别让用户来回切两次才发现（文案即原因）
                  _playSource == PlaySource.local
                      ? (cached.audioOnly
                          ? '本地只缓存了音频，要看画面得用网络流'
                          : '当前用本地缓存文件播放；网络流可按账号清晰度重取')
                      : '当前用网络流播放；切回本地不消耗流量',
                  style: const TextStyle(color: kPlayerOnDim, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  unawaited(_switchPlaySource(
                    _playSource == PlaySource.local
                        ? PlaySource.network
                        : PlaySource.local,
                  ));
                },
              ),
              ListTile(
                leading: const Icon(Icons.refresh, color: kPlayerOn),
                title: const Text('重新下载（视频+音频）',
                    style: TextStyle(color: kPlayerOn, fontSize: 15)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDownloadPage(_currentPageIndex);
                },
              ),
              if (!cached.audioOnly)
                ListTile(
                  leading: const Icon(Icons.audiotrack_outlined,
                      color: kPlayerOn),
                  title: const Text('改为仅缓存音频（省空间，无画面）',
                      style: TextStyle(color: kPlayerOn, fontSize: 15)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _confirmDownloadPage(_currentPageIndex, audioOnly: true);
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
  ///
  /// [audioOnly] = true：只下音频（文案标明「无画面」，别让用户事后才发现）。
  Future<void> _confirmDownloadPage(int pageIndex, {bool audioOnly = false}) async {
    final pages = _pages;
    final partTitle = pages != null && pageIndex < pages.length
        ? pages[pageIndex].part
        : _currentPartTitle;
    final name = partTitle.isEmpty ? _video.title : partTitle;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('离线下载'),
        content: Text(audioOnly
            ? '将只下载《$name》的「音频」到本地缓存（体积小得多，'
                '离线播放时没有画面）。'
            : '将下载《$name》'
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
    _startDownloadPage(pageIndex, audioOnly: audioOnly);
  }

  /// 确认下载全部 P（提示流量）→ 逐集入队。
  Future<void> _confirmDownloadAll({bool audioOnly = false}) async {
    final n = _video.pageCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('离线下载'),
        content: Text(audioOnly
            ? '将依次只下载全部 $n 集的「音频」到本地缓存'
                '（体积小得多，离线播放时没有画面）。'
            : '将依次下载全部 $n 集到本地缓存'
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
    _startDownloadAll(audioOnly: audioOnly);
  }

  /// 启动单集下载（入队后立即返回；完成/失败用 SnackBar 反馈）。
  void _startDownloadPage(int pageIndex, {bool audioOnly = false}) {
    final future =
        _downloads.downloadVideo(_video, pageIndex, audioOnly: audioOnly);
    future.then((_) {
      final cached =
          _downloads.getCached(_video.bvid, pageIndex);
      if (mounted) {
        _showSnack('已缓存：${cached?.partTitle ?? '第 ${pageIndex + 1} 集'}'
            '${audioOnly ? '（仅音频）' : ''}');
      }
    }).catchError((Object e) {
      if (mounted) _showSnack('下载失败：${_shortErr(e)}');
    });
  }

  /// 启动全部 P 下载（逐集入队，内部串行执行）。
  void _startDownloadAll({bool audioOnly = false}) {
    _downloads.downloadAllPages(_video, audioOnly: audioOnly).then((_) {
      if (mounted) {
        _showSnack('全部 ${_video.pageCount} 集已缓存'
            '${audioOnly ? '（仅音频）' : ''}');
      }
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
            child: const Text('删除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.deleteCache(_video.bvid, _currentPageIndex);
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
        // 悬浮在底部控制行（进度条行 40 + 按钮行 40 = 80px，v2.39.0 起，
        // 与 [kPlayerBottomBarHeight] 同一口径）之上，
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
      // 下载中：进度环本身就是非颜色的状态载体（环 + 百分比文字），不再加短线
      icon = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          value: task.progress,
          strokeWidth: 2,
          color: kPlayerOn,
        ),
      );
      label = task.progress == null ? '下载中' : '${task.percent}%';
      color = kPlayerOn;
    } else if (cached != null) {
      // 已缓存 = 持续生效的「开启态」→ 纸白 + 短线
      icon = _barToggleIcon(Icons.check_circle_outline, on: true);
      label = '已缓存';
      color = kPlayerOn;
    } else {
      icon = _barToggleIcon(Icons.download_outlined, on: false);
      label = '下载';
      color = kPlayerOff;
    }
    return InkWell(
      onTap: downloading ? null : _onDownloadTap,
      // 图标在上、标签在下（见 [_barIconLabel]）——与同级 7 个按钮同一竖排
      // 语汇，「已缓存」「下载中」等 3 字标签不再被省略号截断
      child: _barIconLabel(icon: icon, label: label, color: color),
    );
  }

  // -------------------------------------------------------------------------
  // 多 P 选集切换
  // -------------------------------------------------------------------------

  /// 切换选集：更新当前集 → 重新取流（position 从 0 开始）→
  /// 恢复倍速（换源后原生倍速被重置为 1x）；听视频状态为 Dart 状态自然保持。
  /// 取流失败按 _handleLoadFailure 分类提示（-412/62002/-101 等），不崩溃。
  ///
  /// [seekMs]（v2.17.6+ 评论 ?p/?t 同视频跳分 P）：>0 时切集后 onPrepared
  /// 直接 seek 到该位置（覆盖该集记忆进度）；null = 切集后按该集记忆进度
  /// 恢复（选集 UI 原行为）。无论哪种，都会清除上一次遗留的 [_pendingSeekMs]
  /// 覆盖（防过期定位串到新集）。
  Future<void> _switchToPage(int index, {int? seekMs}) async {
    final pages = _pages;
    if (pages == null || index < 0 || index >= pages.length) return;
    if (index == _currentPageIndex) return;
    debugPrint('[player_page] switchToPage ${index + 1}/${pages.length} '
        'cid=${pages[index].cid} part=${pages[index].part}');
    _pendingRestore = true; // 切集后 onPrepared 恢复新集记忆进度
    _pendingSeekMs = (seekMs != null && seekMs > 0) ? seekMs : null;
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
      // 宽高比未知 + 画面变换复位（v2.39.0）：新分 P 的宽高比要等它的
      // onPrepared；缩放/旋转是「上一个画面窗口」的坐标系，带过去会裁错。
      // 若此刻正在全屏，onPrepared 会按新比例补一次方向锁。
      _aspectKnown = false;
      _viewScale = 1;
      _viewOffset = Offset.zero;
      _viewRotation = 0;
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
      // 拖动预览：清掉上一集的帧 + 复位节流/代次与预取位置（新集要重新 prepare）
      _previewFrame = null;
      _previewShot = -1;
      _previewSprite = -1;
      _previewGen++;
      _prefetchWantMs = null;
    });
    // 切集 = 换分 P：预览图按分 P 提供 → 必须重新拉（index 1-based）
    unawaited(_prepareVideoShot());
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

  // -------------------------------------------------------------------------
  // 播放页内部换源（playVideo，v2.16.23+ 防双音轨；v2.17.1+ 起评论链接不再
  // 走本方法——改为 push 新播放页 [openVideoInNewPlayer]，本方法保留给多 P
  // 切集/其他内部换源场景）
  // -------------------------------------------------------------------------

  /// 换源播放：**在当前播放页实例停旧播新**（内部换源语义，如后续多 P
  /// 切集/特殊场景复用）。
  ///
  /// v2.16.23 修复背景：评论页旧实现是 push 第二个 PlayerPage（叠加在本页
  /// 之上），本页播放器未释放 → P(A)+P2(B) 同时出声 = 双音轨。当时改由
  /// 评论页回调本方法「停旧播新」。v2.17.1（阶段 B）起评论链接语义改为
  /// 「push 新播放页 + push 前显式暂停旧页 + 返回经 RouteAware 续播」
  /// （[openVideoInNewPlayer]），本方法不再由评论触发，仅作内部换源保留。
  /// 流程：
  /// 1. dispose/停止当前播放器并清理关联状态（timer/订阅/字幕/弹幕/手势
  ///    hud/进度等，同 dispose 语义）；
  /// 2. 更新 [_video] 为被点视频（分 P 从 0 集起）；
  /// 3. 复用首次加载流程 [_init] 重新取流（含 bvid/epId 的取流分支、本地
  ///    缓存优先、记忆进度恢复）。
  Future<void> playVideo(WhitelistVideo video) async {
    if (video.bvid == _video.bvid) {
      debugPrint('[player_page] playVideo 同 bvid=${video.bvid}，跳过换源');
      return;
    }
    debugPrint('[player_page] playVideo 换源 '
        '${_video.bvid} -> ${video.bvid} title=${video.title}');
    // 1) 先保存旧视频进度 + 写历史（播放器还在，getPosition 可用）
    _saveExitProgress();
    // 2) 停旧：取消 tick/浮层定时器与事件订阅，dispose 旧播放器
    _timer?.cancel();
    _timer = null;
    _hudTimer?.cancel();
    _hudTimer = null;
    _eventSub?.cancel();
    _eventSub = null;
    final old = _player;
    _player = null;
    _textureId = null;
    old?.dispose();
    // 实时转写随视频重置（句子时间轴是旧视频音频，防串台）
    _resetRealtime();
    _autoRecoverFails = 0; // 换源：自动续播预算重置（_init 内也会重置）
    _pendingRestore = true; // 新视频 onPrepared 恢复其记忆进度（同首次进入）
    _pendingSeekMs = null; // 内部换源不带 ?t 覆盖（防旧定位串到新视频）
    // 观看时长累计基线丢弃：新视频的位置与旧视频无关。正常情况下新流 READY
    // 时 [_onPrepared] 已重置过一次，这里补的是**取流失败/noPrepared 那条路**
    // ——基线若还指着旧视频的位置，之后任何一次 tick 都可能把两段之间毫无关系
    // 的差值当成「连续观看」（上限 WatchStats.maxTickDeltaMs = 5s），给新视频
    // 白记几秒。
    _resetWatchBaseline();
    setState(() {
      _video = video;
      _currentPageIndex = 0;
      // UP 主信息随换源复位（不残留上一个视频的头像/名字）
      _ownerMeta = null;
      // 运行时简介随换源复位（desc 优先 _video.desc，旧数据等重拉补齐）
      _runtimeDesc = '';
      // 写操作态随换源复位（v2.40.0+）：不把上一个视频的点赞/收藏态带过来，
      // 否则用户切到新视频会看到"已点赞"（其实是上一条的）
      _resetWriteActions();
      _playing = false;
      _completed = false;
      _positionMs = 0;
      _durationMs = 0;
      _aspectRatio = 16 / 9;
      // 宽高比回到未知（v2.39.0）：新视频的比例要等它的 onPrepared，期间
      // 进全屏只放开自由方向（见 [fullscreenOrientationsFor]）。
      _aspectKnown = false;
      // 画面缩放/旋转复位（v2.39.0）：换 bvid 后「画面窗口」是新的坐标系，
      // 上一个视频的放大/旋转带过去会裁错。切分 P 同样复位（见 [_switchToPage]）。
      _viewScale = 1;
      _viewOffset = Offset.zero;
      _viewRotation = 0;
      // 播放源随换 bvid 复位为「本地优先」（v2.39.0+）：新视频按自己的缓存
      // 情况重新判定，不让上一个视频的「强制网络流」串台。切分 P 不复位
      // （见 [_playSource] 字段注释）。
      _playSource = PlaySource.local;
      _error = null;
      _loginPrompt = false;
      _canRetry = true;
      // 手势/浮层残态清理（换源瞬间若有 hud 显示则一并复位）
      _dragging = false;
      _seekDragging = false;
      _gestureSeeking = false;
      _panMode = null;
      _panExcluded = false;
      _panDx = 0;
      _panDy = 0;
      _adjustKind = null;
      _adjustReady = false;
      _hudKind = null;
      _hudValue = 0;
      _hudSeekPosMs = 0;
      // 拖动预览：同样复位（新视频的预览图由 _init 里的 prepare 重拉）
      _previewFrame = null;
      _previewShot = -1;
      _previewSprite = -1;
      _previewDragActive = false;
      _previewGen++;
      _prefetchWantMs = null;
      _listenMode = false; // 新视频正常显示画面
      // 弹幕：清空旧视频渲染数据（缓存按 cid 保留，重开秒显示）
      _danmaku = const [];
    });
    // 3) 复用首次加载流程重新取流（含新 tick 定时器）
    await _init();
    // 换源后重拉新视频的 UP 主信息（阶段 C）
    _refreshUpownerMeta();
    // 换源后弹幕开关仍开 → 自动拉新视频弹幕（与切集一致；异常静默）
    try {
      if (_danmakuEnabled && _error == null) await _loadDanmaku();
    } catch (_) {
      // 弹幕拉取异常静默（不阻塞换源播放）
    }
  }

  // -------------------------------------------------------------------------
  // 同合集上下集（v2.30.0+）
  // -------------------------------------------------------------------------

  /// 播放列表里的邻居（「上一集」[delta] = -1 / 「下一集」= +1）。
  ///
  /// **公开入口**（v2.30.0-r2）：底栏那一对按钮与**通知收起行的「上一集 /
  /// 下一集」**走的是同一条路——后者经 `_onMediaAction('prev'/'next')` 调到这里。
  /// 之所以不再私有：通知链路与测试都要用它，而两处若各写一份「取邻居 + 换源」
  /// 迟早会漂移（越界/防连点/缺 cid 补齐三件套都得同步）。
  ///
  /// 语义与取舍：
  /// - **边界不做任何事**（越界直接 return，不弹提示、不报错、**不循环**）。
  ///   循环播放是另一种语义（「看完了继续看」），用户没要求，且「最后一集
  ///   的下一集」跳到第一集对合集浏览场景只会让人困惑；头尾按钮也是直接
  ///   禁用（见 [_buildPlaylistRow]），通知层同样只在两头都可用时才放出
  ///   上下集按钮（见 `_syncNowPlaying` 的 hasPrev/hasNext），正常操作根本
  ///   走不到这里；
  /// - **复用 [playVideo]**：换 bvid 要复位的状态有 17 项（播放器/定时器/
  ///   字幕/弹幕/手势 HUD/拖动预览/UP 元数据/简介/听视频…），`playVideo`
  ///   已经逐项做全，这里再抄一遍必然漏项、两份清单还会各自漂移。
  ///   本方法只负责「选中列表里的下一条 + 缺 cid 时补齐元数据」；
  /// - **不接历史 / 搜索 / 信箱 / 评论跳转**的播放列表：那些列表是「观看时间
  ///   序 / 相关度序」，不是「同一部的第几集」，切「下一个」语义会错位——见
  ///   [PlaylistContext] 类注释；
  /// - 同一 bvid 在列表里重复出现（脏数据）时 `playVideo` 会短路跳过换源，
  ///   此时下标照常移动（不影响后续导航）。
  Future<void> playNeighbor(int delta) async {
    final list = _playlistVideos;
    if (list == null) return;
    final target = _playlistIndex + delta;
    if (target < 0 || target >= list.length) {
      debugPrint('[player_page] 上下集越界（$target/${list.length}），无动作');
      return;
    }
    if (_neighborSwitching) return; // 防连点：上一次换源还没走完
    final picked = list[target];
    debugPrint('[player_page] 播放列表切集 ${delta > 0 ? '下一集' : '上一集'} '
        '${_playlistIndex + 1} -> ${target + 1}/${list.length} '
        'bvid=${picked.bvid}');
    setState(() => _playlistIndex = target);
    _neighborSwitching = true;
    try {
      // 邻居缺 cid（合集/UP 主页一般都有；动态/脏数据可能为 0）→ 先补元数据。
      // 取不到就只提示、**不动当前播放**：切过去只会是一个取不了流的空壳，
      // 不如停在能看的这一集（同 upowner_page 的 _openVideo 取舍）。
      var video = picked;
      if (video.cid <= 0) {
        final fixed = await _resolveNeighborMeta(video);
        if (fixed == null) {
          if (mounted) setState(() => _playlistIndex -= delta); // 下标退回原处
          _showSnack('获取视频信息失败，无法切换');
          return;
        }
        video = fixed;
        // 就地替换列表里那一条：下次切回它不用再拉一次
        final idx = _playlistVideos!.indexWhere((v) => v.bvid == picked.bvid);
        if (idx >= 0) _playlistVideos![idx] = fixed;
      }
      await playVideo(video);
    } finally {
      _neighborSwitching = false;
    }
  }

  /// 邻居视频缺 cid 时补拉 view 元数据（返回 null = 失败，调用方保持现状）。
  Future<WhitelistVideo?> _resolveNeighborMeta(WhitelistVideo v) async {
    debugPrint('[player_page] 邻居视频缺 cid，fetch view 补齐 bvid=${v.bvid}');
    try {
      final meta = await _api.fetchVideoMeta(v.bvid);
      final fixed = WhitelistWriter.videoFromMeta(meta, fallbackBvid: v.bvid);
      if (fixed.cid <= 0) return null; // 接口给了数据但没有 cid → 视为失败
      return fixed;
    } catch (e) {
      debugPrint('[player_page] 邻居视频元数据拉取失败 bvid=${v.bvid} $e');
      return null;
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
                  style: TextStyle(color: kPlayerOnDim, fontSize: 13)),
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
                    color: isCurrent ? kPlayerOn : kPlayerOff,
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
                                color: kPlayerOnDim, fontSize: 13)),
                        const SizedBox(width: 8),
                        if (isCurrent)
                          const Icon(Icons.check,
                              color: kPlayerOn, size: 18)
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

  /// 按当前视频的宽高比下发全屏方向锁（v2.39.0+）。
  ///
  /// 决策在纯函数 [fullscreenOrientationsFor] 里（可单测）；这里只负责「拿到
  /// 决策 → 下发」，并且**空列表不下发**（= 保持设备当前方向：近方形视频 /
  /// 比例异常时锁谁都会让一半用户觉得错，保持现状最稳）。
  ///
  /// 调用点两处：进全屏（[_toggleFullscreen]）与 [onPrepared] 后补锁。两处都
  /// 是幂等的——已锁对时重复下发同一组方向不会真的转屏。
  Future<void> _applyFullscreenOrientation() async {
    final orientations = fullscreenOrientationsFor(
      _aspectRatio,
      known: _aspectKnown,
    );
    debugPrint('[player_page] 全屏方向锁 aspect=$_aspectRatio '
        'known=$_aspectKnown → ${orientations.map((o) => o.name).join('/')}'
        '${orientations.isEmpty ? '（保持当前方向）' : ''}');
    if (orientations.isEmpty) return;
    await SystemChrome.setPreferredOrientations(orientations);
  }

  Future<void> _toggleFullscreen() async {
    debugPrint('[player_page] _toggleFullscreen called, full=$_fullscreen');
    final full = !_fullscreen;
    setState(() {
      _fullscreen = full;
      // 全屏没有下方内容区（评论区不在树里），收起态在两个方向上来回切都
      // 没有意义——退出全屏时评论区是从头重建的，信息块也一并复位成展开，
      // 免得出现「列表停在顶部、标题却是收起」的错位。
      _infoBarCollapsed = false;
      _infoBarScrollAccum = 0;
      _commentScrollByUser = false;
    });
    if (full) {
      // 进全屏：**按视频宽高比**锁方向（v2.39.0，用户原话「竖屏视频全屏之后
      // 还是竖屏，而不是现在的旋转九十度」）——旧实现无条件锁 landscape 两向，
      // 竖屏视频在横屏整屏里只占约 1/3 宽、左右大黑边。
      // 横屏视频仍锁 landscape 两向（行为与旧版逐字一致）；竖屏视频锁
      // portraitUp；近 1:1 不下发命令；比例未就绪时下发放开的三向（见
      // [fullscreenOrientationsFor]）。
      await _applyFullscreenOrientation();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      // v2.17.17 退出全屏：**不再强制转竖屏**——放开「竖屏 + 双向横屏」
      // （[kPlayerPageFreeOrientations]）：设备当前横放 → 停在横屏「顶部
      // 置顶 + 下方评论区」（横屏置顶模式，布局按方向自适应见 build）；
      // 设备竖放 → 仍竖屏置顶+评论（兼容 v2.17.0 行为）；之后旋转设备
      // 可在横/竖两态间自由切换。离开播放页才恢复系统方向（dispose）。
      await SystemChrome.setPreferredOrientations(kPlayerPageFreeOrientations);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // 退出全屏 → 画面缩放/旋转复位（v2.39.0，见 [_resetViewTransform]）：
    // 那些变换只在全屏下有意义，带回竖屏视频区会变成「画面被裁掉一块」。
    if (!full) _resetViewTransform();
  }

  void _restoreSystemUi() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 返回（顶栏箭头 / 系统返回键共用语义，v2.17.17）：
  /// - 全屏中：**先退出全屏**回到当前方向的「置顶 + 评论」布局（设备横放 →
  ///   横屏置顶+评论）——与全屏退出按钮一致，不再直接整页离开；
  /// - 非全屏：离开播放页（dispose 恢复系统方向）。
  void _handleBack() {
    if (_fullscreen) {
      _toggleFullscreen();
      return;
    }
    Navigator.of(context).pop();
  }

  void _retry() {
    _autoRecoverFails = 0; // 手动重试：自动续播预算重置（_init 内也会重置）
    _autoRecovering = false;
    // 旧播放器的收尾（退订 + dispose）由 [_init] 统一负责
    _pendingRestore = true; // 手动重试视为重新进入：onPrepared 恢复记忆进度
    _init();
  }

  Future<void> _goLogin() async {
    setState(() => _loginPrompt = false);
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()));
    if (!mounted) return;
    // 登录成功（现在有有效会话）→ 重取流解锁 1080P；没登录（直接返回/
    // 关闭登录页）→ 不打断当前画面：播放失败态保留「去登录」按钮，正常
    // 播放态（匿名/临近过期横幅）横幅保持现状即可。
    final loggedIn = await _hasValidSession();
    if (!mounted) return;
    if (loggedIn) {
      await _checkLoginExpiry(); // 新会话长有效期 → 清掉匿名/临近过期横幅
      if (!mounted) return;
      _retry();
    } else if (_error != null) {
      setState(() => _loginPrompt = true); // 未登录返回：失败态仍可再去登录
    }
  }

  /// secure storage 里是否有**未过期**的有效 SESSDATA（登录成功判定）。
  Future<bool> _hasValidSession() async {
    try {
      final raw = await _api.readSessdata();
      final expire =
          raw == null || raw.isEmpty ? null : BiliApi.sessdataExpireAt(raw);
      return expire != null && expire.isAfter(DateTime.now());
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // 登录过期检测（C. 简单版：SESSDATA 内嵌过期时间戳）
  // -------------------------------------------------------------------------

  /// 播放页顶部横幅文案（未登录 / 登录将过期共用同一横幅组件）。
  ///
  /// 未登录（无 SESSDATA，含关闭自动引导登录页 = 明确匿名）→ 给清晰提示 +
  /// 去登录入口（v2.16.21，不默认静默降级）；已登录但临近过期 → 提示重登。
  static const String _kAnonymousBannerText =
      '未登录仅 720P，去登录解锁 1080P（登录一次长期保持）';

  /// 检查登录态并维护顶部横幅：
  /// - 无 SESSDATA（匿名）→ 显示 [._kAnonymousBannerText]（点按去登录）；
  /// - 有 SESSDATA 且临近过期（< 7 天）→ 显示过期提醒；
  /// - 有 SESSDATA 且有效期充足 → 清掉横幅（登录成功后 _goLogin 复用本方法）。
  Future<void> _checkLoginExpiry() async {
    try {
      final raw = await _api.readSessdata();
      if (raw == null || raw.isEmpty) {
        if (!mounted) return;
        if (_loginExpiryText != _kAnonymousBannerText) {
          setState(() => _loginExpiryText = _kAnonymousBannerText);
        }
        return;
      }
      final decoded = Uri.decodeComponent(raw);
      final parts = decoded.split(',');
      if (parts.length < 2) return; // 解析失败就不管
      final ts = int.tryParse(parts[1]);
      if (ts == null) return;
      final expire = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      final remain = expire.difference(DateTime.now());
      if (!mounted) return;
      if (remain < const Duration(days: 7)) {
        final text = remain.isNegative
            ? '登录已过期，请重新登录'
            : '登录将过期（${_fmtDateTime(expire)}），请重新登录';
        setState(() => _loginExpiryText = text);
      } else if (_loginExpiryText != null) {
        setState(() => _loginExpiryText = null); // 有效期充足 → 不再提示
      }
    } catch (_) {
      // 解析/存储异常静默忽略
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
    // v2.17.0+ 非全屏布局重构（v2.17.17 起竖屏 / 横屏两态自适应）：
    // - 非全屏 = 常规观看页：视频区顶部置顶（按宽高比的黑盒）+
    //   下方视频信息行 + 内嵌评论区（滚动）——设备竖放为竖屏布局；设备
    //   横放（v2.17.17 横屏置顶模式）= 同一 Column 的横屏形态：视频区高度
    //   封顶比例略低（屏高 55%，见 _embeddedVideoHeight）、信息行紧凑（标题
    //   1 行/简介少行，见 _buildVideoInfoBar/_descMaxExpandedHeight），剩余
    //   高度全给评论区（哪怕矮也可滚）；
    // - 全屏（横屏）= 视频占满整屏（原全屏布局，无下方内容区）。
    // 两态共用 _buildVideoLayers：画面/听视频占位/弹幕/字幕/手势/控制层/
    // 浮层全部绑定在视频区矩形内（非全屏不覆盖下方评论区）；切换全屏只是
    // 换视频区高度与是否渲染下方内容，布局随 _fullscreen 联动。退出全屏
    // 不再强制转竖屏（方向见 _toggleFullscreen）——当前横放即停在此横屏
    // 置顶+评论形态。
    final screen = MediaQuery.sizeOf(context);
    final videoAreaHeight =
        _fullscreen ? screen.height : _embeddedVideoHeight(screen);
    return PopScope(
      // 系统返回键：全屏中拦截为「先退出全屏」（canPop=false 拦截后由
      // onPopInvokedWithResult 兜底退全屏，回到当前方向的置顶+评论）；
      // 非全屏放行直接离开页面（dispose 恢复系统方向）。
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: _fullscreen
            ? Colors.black
            : Theme.of(context).colorScheme.surface,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 视频区（黑底）：非全屏 = 顶部置顶、按宽高比封顶的黑盒
            //    （竖屏超高视频封顶屏高 60%；横屏 16:9 理想高度≈整屏高 →
            //    封顶屏高 55%——盒内画面均按 AspectRatio 居中 + 黑边补齐）；
            //    全屏 = 占满整屏。
            SizedBox(
              key: const ValueKey('player-video-area'),
              height: videoAreaHeight,
              child:
                  ColoredBox(color: Colors.black, child: _buildVideoLayers()),
            ),
            // 2/3. 非全屏内容区（竖屏 / 横屏置顶共用）：视频信息块（标题/
            //      时长 + UP 主入口：阶段 C 已从 UP 主名文本占位升级为头像
            //      +名字可点进 UP 主页；横屏自动紧凑；块化见 [_buildInfoBlock]）
            //      + 内嵌评论区（评论区底部避开系统手势导航条）。
            //      全屏不渲染（下方内容区不占位）。
            //      竖屏额外支持「滚评论收信息块」：收起/展开见
            //      [_buildCollapsibleInfoBlock]（横屏置顶不参与，返回原块）。
            if (!_fullscreen) ...[
              // 竖屏：评论区滚动可把这块收起（见 _buildCollapsibleInfoBlock）
              _buildCollapsibleInfoBlock(context),
              Expanded(
                key: const ValueKey('player-comments'),
                // 评论滚动 → 信息块显隐的监听放在页面侧（评论区组件自己那个
                // NotificationListener 返回 false 会继续冒泡上来，不必改组件）。
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onCommentScrollNotification,
                  child: SafeArea(
                    top: false,
                    child: _buildEmbeddedComments(),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 视频区各图层（与所在矩形自适应：非全屏视频黑盒 / 全屏整屏）。
  ///
  /// Positioned.fill 的层（弹幕/手势/缓冲/听视频占位等）填满矩形；
  /// 字幕与控制层按矩形底部定位（字幕悬浮在控制行上方）——所有播放相关
  /// UI 与手势都只在视频区内，不覆盖下方评论区。
  /// 播放画面本体（保持宽高比居中 + 全屏下的缩放/旋转/平移）。
  ///
  /// 结构：`ClipRect → Transform(scale/rotateZ/translate) → Center(AspectRatio
  /// → Texture)`（v2.39.0+）。
  /// - [ClipRect] 是必须的：放大或旋转 90° 后画面会越出视频区，不裁就会画到
  ///   顶栏、字幕、评论区上去；
  /// - [Transform] 的 matrix 顺序是 `T · R · S`（translate 写最前 = 应用在
  ///   最外层）：这样 [_viewOffset] 恒为**可视区坐标系**里的像素，与
  ///   [clampViewOffset] 的夹取口径一致，旋转/缩放都不会让平移量改变含义；
  /// - 非全屏且未变换时**不构建** ClipRect/Transform（返回裸 Center），非全屏
  ///   的渲染树与改动前逐节点一致、零额外开销。
  ///
  /// 注意字幕/弹幕层在画面**之上**且**不参与**这套变换（B 站也是这个层级）：
  /// 弹幕/字幕是「贴屏幕」的信息层，跟着画面缩放平移会让它们跑出可视区、
  /// 也会与字号体系打架。这是有意为之，不是漏做。
  Widget _buildVideoPicture() {
    final picture = Center(
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: BiliDashTexture(textureId: _textureId!),
      ),
    );
    if (!_fullscreen && !_viewTransformed) return picture;
    return ClipRect(
      child: Transform(
        // 测试锚点：断言缩放倍数 / 旋转档位 / 平移量都读这个 Transform 的矩阵
        key: const ValueKey('player-view-transform'),
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translate(_viewOffset.dx, _viewOffset.dy)
          ..rotateZ(_viewRotation)
          ..scale(_viewScale),
        child: picture,
      ),
    );
  }

  Widget _buildVideoLayers() {
    return Stack(
      fit: StackFit.expand,
      children: [
          // 1. 播放画面（保持宽高比居中，黑色铺底；听视频模式下隐藏但播放不中断；
          //    全屏下支持双指缩放/旋转与缩放态单指平移，见 [_buildVideoPicture]）
          if (_textureId != null)
            Offstage(
              offstage: _listenMode,
              child: _buildVideoPicture(),
            ),
          // 2. 听视频占位界面（封面 + 标题 + 提示，点按恢复画面）
          if (_listenMode) _buildListenPlaceholder(),
          // 2.05 仅音频缓存占位界面：本次源**本身没有视频轨**（缓存时只下载
          //      了音频），纹理永远出不来画面 → 用封面 + 一句说明顶住，
          //      否则用户只看到黑屏，以为播放器坏了。不拦点按（手势/控制层
          //      要照常可用），所以套 IgnorePointer。
          if (_audioOnlyPlayback && !_listenMode)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _aspectRatio,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        // 封面为空则不构建图片（零请求，与封面占位层同约定），
                        // 只剩底部的说明文字
                        if (_video.cover.isNotEmpty)
                          CoverImage(cover: _video.cover),
                        // 底部压一层黑雾 + 说明，保证封面再花也读得清
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            color: kInkBlack.withValues(alpha: .6),
                            child: const Text(
                              '仅缓存了音频：无画面，可正常听声音',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: kPaper, fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // 2.1 封面占位层（「封面放大变成播放界面」的假转场）
          //     ───────────────────────────────────────────────────────
          //     为什么是「假」：播放画面是原生纹理（BiliDashTexture），Hero
          //     飞不到 Texture 里去，所以让 Hero 把卡片封面飞进视频区、落在
          //     这一层上，等播放器就绪后这层淡出，露出真实画面。
          //
          //     落点精度：包在**与纹理同一个 AspectRatio 盒**里（_aspectRatio
          //     + Center），两端 box 一致 → 飞行终点与最终画面严格同位。
          //     tag 用 coverHeroTag(_video.bvid)，与源端 VideoTile 同一工厂，
          //     不会对不上；本页只渲染这一个封面层 → tag 唯一。
          //
          //     IgnorePointer 是硬要求（不是防御性写法）：本层在听视频占位层
          //     **之上**，而 CoverImage/占位底色是 opaque 命中区，不忽略命中就
          //     会截掉「点按恢复画面」；非听视频态也会挡住下面的显隐/手势层。
          //
          //     cover 为空则整层不构建（连 AnimatedOpacity 都没有），因此既不
          //     产生占位图也绝不发图片请求（测试用的空 cover 视频即走这条路径）。
          //     这一层与听视频模式无关：它按自己的节奏淡出，不被 _listenMode
          //     分支收编（否则开着听视频进来封面会永远盖着）。
          if (_coverOverlayVisible && _video.cover.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _coverOverlayOpaque ? 1.0 : 0.0,
                  duration: kCoverFadeOutDur,
                  curve: kCurveOut,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _aspectRatio,
                      child: CoverHero(
                        tag: coverHeroTag(_video.bvid),
                        child: CoverImage(
                          cover: _video.cover,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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
          // 底部控制行 [kPlayerBottomBarHeight] = 80px（进度条行 40 + 按钮行 40，
          // 见 _buildBottomBar），字幕悬浮在其上方。主字幕大号在上，副字幕
          // 小号在其下（见 _SubtitleOverlay）。
          // v2.17.0+：字幕相对**视频区矩形**底部定位（不再相对整屏）；基准值
          // 全交给纯函数 [subtitleBottomOffset]（控制行可见时 = 控制行高度 +
          // 定值间隙，全屏 30 / 非全屏 12；控制行隐藏时贴画面底部 24 / 16）。
          // 这样控制行高度再变也只需改一处，字幕不会静默错位——P5（80 → 88）
          // 与 v2.39.0（88 → 80）两次都踩过「数字散落两处」。纯函数同时可单测。
          if (!_listenMode &&
              _subtitleEnabled &&
              (_mainSubtitleText.isNotEmpty ||
                  _secondarySubtitleText.isNotEmpty))
            Positioned(
              left: 24,
              right: 24,
              bottom: subtitleBottomOffset(
                fullscreen: _fullscreen,
                controlsVisible: _controlsVisible,
              ),
              child: _SubtitleOverlay(
                mainText: _mainSubtitleText,
                secondaryText: _secondarySubtitleText,
              ),
            ),
          // 3. 登录过期横幅
          //    v2.17.18：不再与返回键共享同一条带——横幅整条下压不合适（会落进
          //    中央播放簇的命中带、抢走「点按去登录」），改为让横幅**从返回键
          //    触摸区右缘起**（left = 48，与 [_buildTopBar] 里 IconButton 钉死的
          //    minWidth 48 对齐）：箭头独占左上角 48×48 触摸区，不再压在横幅
          //    左内边距上（旧版两者重叠 → 箭头看着像横幅的前置图标）。
          //    横幅高度随文字自适应（Text 不设 maxLines），窄了会换行不截断。
          if (_loginExpiryText != null)
            Positioned(
              top: 0,
              // 与顶栏返回键触摸区宽度一致（player_page 常量：48dp）
              left: 48,
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
          //      [decideMode] 按主导方向锁定：水平主导 → seek（v2.18.x 起竖屏 /
          //      横屏置顶 / 横屏全屏统一可用，见 [canGestureSeek]；本版起呈现
          //      成「直接拖进度条」——进度条手柄跟手 + 上方预览气泡，控制层
          //      收着时只浮出进度条行，见 [_buildSeekRow]/[_buildSeekRowOnly]），
          //      垂直主导 → 起点半屏亮度/音量（横竖屏都可用，斜向按主方向归类；
          //      锁定后本次手势不再切换）。v2.16.7 旧实现「横屏只注册横向、
          //      竖屏只注册纵向」→ 横屏全屏稍斜的上下滑被误判为横向 seek、
          //      纯上下滑完全无响应——本次修复让两者共存
          //    - 豁免带（v2.16.14+ 顶/底 → v2.16.17+ 四边 + 按下点判定；
          //      v2.18.x 起**底部带仅全屏**，非全屏手势层底边在屏幕中部、无系统
          //      导航区）：**触摸按下点**（onPanDown 的真实坐标；onPanStart 是
          //      竞技场胜出点，边缘滑动会因 slop/系统延迟内移，实测可达 ~100px，
          //      不可靠）落在顶部/左/右（+全屏时的底部）豁免带
          //      （[isExcludedGestureStart]，见类顶常量）→ 本次 Pan 整体忽略，
          //      不 seek / 不调亮度音量 / 不出 hud——横屏全屏从**物理屏幕底部**
          //      滑动（旋转后 = 逻辑左/右边缘，左右带加宽覆盖物理底边导航区）
          //      唤醒系统导航不再误触发 seek（按下点带内该次触摸让给系统手势）；
          //      tap / 双击 / 长按无位移不触发 Pan、不受豁免影响
          //    - 控制层按钮 / 进度条在本层**之后**渲染（Stack 上层），其区域内
          //      点击与拖动天然拦截（按钮优先）；弹幕层 IgnorePointer 不参与命中
          //    听视频模式下让位给占位层（其自己处理点按恢复画面 + 长按 2x），
          //    否则本 opaque 层会拦截占位层的点击。
          //
          //    v2.39.0 全屏双指缩放/旋转：外层套一个 **Listener** 旁观原始指针
          //    事件（按 pointerId 配对算缩放/旋转/平移，见 [_onViewPointerDown]
          //    等方法与那里的「为什么不用 ScaleGestureRecognizer」实测理由）。
          //    Listener **不参与手势竞技场**——这是本方案的核心：单指拖动仍然
          //    完全落在下面这个 GestureDetector 的 Pan 识别器手里，用户验收过的
          //    三条 seek 用例零回归。
          //    v2.43.0：回调**不再只在全屏挂**（旧实现非全屏时传 null）——非全屏
          //    也要让双指期间的让位生效，否则一次捏合会被当成单指长横滑 →
          //    无故 seek。变换本身仍只在全屏生效（[_viewTransformEnabled]）。
          if (!_listenMode)
            Positioned.fill(
              child: Listener(
                onPointerDown: _onViewPointerDown,
                onPointerMove: _onViewPointerMove,
                onPointerUp: _onViewPointerUp,
                onPointerCancel: _onViewPointerUp,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTap: _player == null ? null : _onDoubleTap,
                  onLongPressStart:
                      _player == null ? null : _onLongPressStart,
                  onLongPressEnd: _player == null ? null : _onLongPressEnd,
                  // 滑动统一 Pan（v2.16.9+）：方向判定在手势内完成——水平主导
                  // seek（竖屏 / 横屏统一）、垂直主导亮度/音量共存
                  onPanDown: _player == null ? null : _onPanDown,
                  onPanStart: _player == null ? null : _onPanStart,
                  onPanUpdate: _player == null ? null : _onPanUpdate,
                  onPanEnd: _player == null ? null : _onPanEnd,
                  onPanCancel: _player == null ? null : _onPanCancel,
                ),
              ),
            ),
          // 5. 控制层（置于点击层之上）
          if (_controlsVisible || !_loaded)
            _buildControls()
          // 5.1 手势横滑 seek 且控制层收着：只把**进度条行**浮出来——
          //     手柄跟着手指走 + 预览气泡贴着进度条（「直接拖动进度条」的
          //     手感），但不把整套控制层弹出来、也不改用户的显隐偏好。
          else if (_gestureSeeking)
            _buildSeekRowOnly(),
          // 5.2 画面变换的复位入口（v2.39.0）：只在全屏且真的缩放/旋转过时出现。
          //     悬浮在底栏之上（**不进底栏那一行**——8 等分已经每格 51.4dp，
          //     再挤第 9 个按钮会把「选集 1/2」「听视频中」压到省略号），
          //     且不受控制层显隐影响：画面被放大后若找不到复位入口，用户只能
          //     退出全屏再来（那个动作会复位，但不该是唯一出路）。
          if (_fullscreen && _viewTransformed) _buildViewResetButton(),
          // 5.5 手势提示浮层（B 站式快捷手势）：seek 时间 / 亮度 / 音量，
          //     中心偏上、不拦截任何点击（IgnorePointer）。
          if (_hudKind != null)
            Positioned.fill(child: _buildGestureHud()),
          // 6. 缓冲指示
          if (_buffering)
            const Center(
                child: CircularProgressIndicator(color: kPlayerOn)),
          // 7. 错误视图
          if (_error != null) _buildErrorView(),
        ],
    );
  }

  Widget _buildControls() {
    // 非全屏视频区较短（如超宽视频黑盒 / 横屏置顶模式屏高矮 < 230px）时
    // 中央播放/快进快退簇与底部控制行重叠 → 收起中央簇（双击播放/暂停仍
    // 可用，见手势层）。
    final screen = MediaQuery.sizeOf(context);
    final compactEmbedded =
        !_fullscreen && _embeddedVideoHeight(screen) < 230;
    return Stack(
      children: [
        _buildTopBar(),
        if (!compactEmbedded)
          // 有上下集行时整簇上移**一行的高度**（见 [_buildPlaylistRowHeightOffset]）：
          // 中央簇是「在视频区里垂直居中」的，底栏长高 40 它不会自己让位，
          // 实测竖屏 16:9（视频区仅 231dp）下中央播放键的圆环正好压在这一行的
          // 中间标签上（白压白，标签可读性崩掉）。上移 40 后本簇相对底栏
          // （进度条行 / 按钮行）的纵向关系与加这一行之前**逐像素一致**，
          // 让出来的正是新那一行的带子。不改簇内部布局。
          Transform.translate(
            offset: Offset(0, _playlistRowHeightOffset),
            child: Center(child: _buildCenterControls()),
          ),
        Align(alignment: Alignment.bottomCenter, child: _buildBottomBar()),
      ],
    );
  }

  /// 中央控制簇在有上下集行时的纵向偏移（0 或 `-行高`）。
  ///
  /// 用 [Transform.translate] 而不是给 `Center` 套 `Padding(bottom:)`：后者的
  /// 位移量只有 padding 的一半（盒子连同 padding 一起居中），要上移 40 得写 80，
  /// 读代码的人只会看到一对魔法数字。translate 语义就是「整簇上移 N」，且默认
  /// `transformHitTests = true`，命中区跟着走，不需要额外补偿。
  double get _playlistRowHeightOffset =>
      _hasPlaylistNeighbors ? -_kPlaylistRowHeight : 0;

  /// 信息块的补场起点（归一化到控制器 0..1 上的 [Interval]）：前
  /// [kInfoBlockDelay] 是「等封面先落位」，与封面 Hero 的 [kHeroFlightDur]
  /// 重叠，不是串行等待。
  static final double _kInfoBlockFadeStart = kInfoBlockDelay.inMilliseconds /
      (kInfoBlockDelay.inMilliseconds + kInfoBlockDur.inMilliseconds);

  /// 信息块（块化 + 补场动效）。
  ///
  /// 外形交给 [AppBlock]（variant=videoInfo）：描边 + 左侧短竖条当「起笔」+
  /// 圆角，底色沿用规格表的 [kPaper]（与原 `colorScheme.surface` 同值，所以
  /// 原来的底色写法直接删掉，不做双层底）。原来那条 `border(bottom:)` 的
  /// hairline 分隔线也一并删——现在由块的四周描边表达层级，再留一条横线就是
  /// 两套语言打架。
  ///
  /// `ValueKey('player-info-bar')` 仍挂在这里（测试锚点：横屏/竖屏/集成三处
  /// 几何断言都量它的 RenderObject ⊤ == 视频区底边）。注意**没有外边距**：
  /// 块紧贴视频区下沿、通栏铺满，任何 margin 都会让「顶部 == 视频区底部」
  /// 偏掉。
  Widget _buildInfoBlock(BuildContext context) {
    final block = AppBlock(
      key: const ValueKey('player-info-bar'),
      variant: AppBlockVariant.videoInfo,
      child: _buildVideoInfoBar(context),
    );
    return _withInfoBlockEntrance(context, block);
  }

  // -------------------------------------------------------------------------
  // 评论滚动 → 信息块收起/展开（竖屏非全屏专用）
  // -------------------------------------------------------------------------

  /// 本特性是否适用：**竖屏（屏高 ≥ 屏宽）的非全屏**播放页。
  ///
  /// 全屏没有下方内容区（不渲染信息块/评论区）；横屏置顶模式（v2.17.17）
  /// 屏高低、评论区本来就只占一小条，把标题收掉收益也小、还容易误触，
  /// 故保持原行为不变（横屏滚评论一律不收）。
  bool get _infoBarScrollCollapseApplies {
    if (!mounted || _fullscreen) return false;
    final s = MediaQuery.sizeOf(context);
    return s.height >= s.width;
  }

  /// 评论列表滚动通知：按**方向 + 累积阈值**决定信息块收起/展开。
  ///
  /// - 判定量 = [ScrollUpdateNotification.scrollDelta] 的累积：内容上移
  ///   （向下翻评论，delta > 0）累积到 [kInfoBarHideScrollThreshold] → 收起；
  ///   内容下移（向上翻）反向累积到阈值 → 展开。切换后清零，所以取值被夹在
  ///   ±阈值内（否则反向时要先"还清"前面攒的位移，手感很黏）；
  /// - **滚到列表顶部强制展开**（用户回到顶部就该看见标题），连同累积量一起
  ///   复位；
  /// - 只认「手指拖拽发起」的那一轮滚动（[ScrollStartNotification.dragDetails]
  ///   非空 → 连其后惯性段一起认，[ScrollEndNotification] 收尾）。程序化的
  ///   `Scrollable.ensureVisible` / `animateTo`（点「评论」按钮定位）不参与
  ///   ——否则点一下按钮标题就被收掉；
  /// - 收起/展开会改变评论区视口高度，可能反过来触发一次位置修正通知；
  ///   阈值 + 每轮清零足以让它自稳，不会来回抖。
  bool _onCommentScrollNotification(ScrollNotification n) {
    if (!_infoBarScrollCollapseApplies) return false;
    if (n is ScrollStartNotification) {
      _commentScrollByUser = n.dragDetails != null;
      if (_commentScrollByUser) _infoBarScrollAccum = 0;
      return false;
    }
    if (n is ScrollEndNotification) {
      _commentScrollByUser = false;
      return false;
    }
    // 到顶：强制展开（含过滚到负值）。放在方向判定之前——到顶那一刻的方向
    // 可能是"继续向上翻"，跟展开是同一个结果，直接短路更省事。
    if (n.metrics.pixels <= n.metrics.minScrollExtent) {
      _infoBarScrollAccum = 0;
      if (_infoBarCollapsed) setState(() => _infoBarCollapsed = false);
      return false;
    }
    if (!_commentScrollByUser || n is! ScrollUpdateNotification) return false;
    final delta = n.scrollDelta ?? 0;
    if (delta == 0) return false;
    const t = kInfoBarHideScrollThreshold;
    final acc = (_infoBarScrollAccum + delta).clamp(-t, t);
    if (acc >= t && !_infoBarCollapsed) {
      _infoBarScrollAccum = 0;
      setState(() => _infoBarCollapsed = true);
    } else if (acc <= -t && _infoBarCollapsed) {
      _infoBarScrollAccum = 0;
      setState(() => _infoBarCollapsed = false);
    } else {
      _infoBarScrollAccum = acc;
    }
    return false;
  }

  /// 可收起的视频信息块：竖屏非全屏时，评论滚动可把它收起（高度让给评论）。
  ///
  /// 结构（自外向内）：[ClipRect] → [AnimatedSize] → [Align] → 信息块
  ///
  /// - `Align(heightFactor: 0/1)` 决定**目标**高度：0 = 收起。用 Align 而不是
  ///   直接把块从树里摘掉，是为了让 `ValueKey('player-info-bar')` 与其内容
  ///   始终在位（每帧都在同一处，没有"重建/卸载"的额外状态）；
  /// - [AnimatedSize] 让**高度**在 0 ↔ 固有高之间平滑过渡（[kDurBase] +
  ///   [kCurveOut]，`alignment: topCenter` 保证动画期间块顶边钉在视频区下沿，
  ///   所以「信息行顶部 == 视频区底部」这条几何断言在两种状态下都成立）；
  /// - 外层 [ClipRect] 负责动画期间把超出的内容裁掉：AnimatedSize 只动自己的
  ///   盒子、不动 child 的尺寸，而它的自动裁剪在动画收尾（盒子 == 目标尺寸）
  ///   时就停了，剩 Align 里那份**固有高**的内容会画到评论区上。自己在外面
  ///   再套一层：盒子多高就裁多高（高度为 0 时 Flutter 直接整棵子树跳过绘制，
  ///   也就不可能挡住评论区的点击）；
  /// - 关动效（[MotionControl]）时**根本不套 [AnimatedSize]**：它的
  ///   `duration: Duration.zero` 会在自己的 performLayout 里同步 `forward()`
  ///   → 在 layout 期间 `markNeedsLayout`，Flutter 直接断言失败
  ///   （"RenderAnimatedSize was mutated in its own performLayout"）。这条路上
  ///   本来也不需要动画，直接 `ClipRect + Align` 瞬时到位，一个 controller
  ///   都不建。
  ///
  /// 横屏置顶 / 全屏不套这一层（直接返回原块，行为与改动前完全一致）。
  Widget _buildCollapsibleInfoBlock(BuildContext context) {
    final block = _buildInfoBlock(context);
    if (!_infoBarScrollCollapseApplies) return block;
    // heightFactor 0 = 目标高度为零（收起），但块本身仍按固有高布局 →
    // 外层 ClipRect 按"当前实际高度"裁剪，就是抽出/收回的视觉效果。
    final shrinkWrap = Align(
      alignment: Alignment.topCenter,
      heightFactor: _infoBarCollapsed ? 0.0 : 1.0,
      child: block,
    );
    if (!MotionControl.of(context)) return ClipRect(child: shrinkWrap);
    return ClipRect(
      child: AnimatedSize(
        duration: kDurBase,
        curve: kCurveOut,
        alignment: Alignment.topCenter,
        child: shrinkWrap,
      ),
    );
  }

  /// 给信息块套「补场」动效：延迟 [kInfoBlockDelay] 后淡入 + 从 96%
  /// ([kInfoBlockScaleFrom]) 微放大到位，总长 [kInfoBlockDur]。
  ///
  /// 卸载时机：[_infoBlockDone]（控制器 completed 时置位）之后本方法直接返回
  /// 原块——树里不留 `FadeTransition`/`Transform`，信息块不动的那些帧不必
  /// 多走一次 opacity + transform 的合成。
  ///
  /// 不加 `IgnorePointer`：这块里有 UP 主入口等可点元素，动画期间也必须可点
  /// （`FadeTransition`/`Transform` 都不拦命中，保持默认即可）。
  Widget _withInfoBlockEntrance(BuildContext context, Widget block) {
    if (!MotionControl.of(context) || _infoBlockDone) return block;
    // 用 drive 而不是 CurvedAnimation：CurvedAnimation 要在 state 里持有并
    // dispose，而这里每次 build 都取一次动画视图，drive 出来的 Animatable
    // 不挂监听、随 build 丢弃无副作用。
    final t = _infoBlockCtl
        .drive(CurveTween(curve: Interval(_kInfoBlockFadeStart, 1.0, curve: kCurveOut)));
    return FadeTransition(
      opacity: t,
      // child 必须传：否则每帧重建整棵信息块子树（含 ExpandableText）
      child: AnimatedBuilder(
        animation: t,
        child: block,
        builder: (_, child) => Transform.scale(
          scale: kInfoBlockScaleFrom + (1 - kInfoBlockScaleFrom) * t.value,
          // 从左上角放大：信息块是「落位后长出来」，锚点跟着左上角才不倒冲
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
    );
  }

  /// 非全屏（竖屏置顶 / v2.17.17 横屏置顶）视频信息行：标题（含分 P）+
  /// UP 主入口 + 时长 + 简介。
  ///
  /// v2.17.17+ 横屏自适应：横屏屏高低 → 标题收成 1 行（竖屏 2 行）、简介
  /// 折叠少行（竖屏 3 行 → 横屏 2 行）——压低信息行固有高度，把剩余空间
  /// 留给评论区（视频区封顶比例也随方向变档，见 [_embeddedVideoHeight]）。
  ///
  /// 阶段 C：UP 主区从 v2.17.0 的「person 图标 + up_name 文本占位」升级为
  /// [UpownerBadge]（圆形头像 + 名字，可点进 [UpownerPage]）；番剧/电影
  /// （带 epId）按阶段 C 取舍弱化（见方法内注释）。
  ///
  /// v2.17.3+ 简介区：数据 = WhitelistVideo.desc（新导入/油猴写入即带），
  /// 为空时用 [_runtimeDesc]（旧数据搭 UP 元数据那次 view 请求补拉）；
  /// 两路都空（番剧/拉取失败）→ **不显示、不占位**。长简介超 3 行折叠 +
  /// 「展开」看全文、「收起」复原；展开态封顶高度内可滚动（防超长简介把
  /// 固定信息行撑爆布局，见 [_descMaxExpandedHeight]）。
  ///
  /// 标题同列表视频卡：超过折叠行数（竖屏 2 / 横屏 1）时多出「展开/收起」
  /// 入口（[ExpandableText]），否则不增任何子树。
  Widget _buildVideoInfoBar(BuildContext context) {
    // 中性墨分层（P5）：标题主墨（kInkBlack）→ UP 主/集数/简介次级
    // （kInkGray70）→ 时长三级（kInkGray50，等宽数字）。标题/正文/元信息
    // 分别走 kTypeTitleM / kTypeBodyS / kTypeNum 字阶。
    final subStyle = kTypeBodyS.copyWith(color: kInkGray70);
    // 横屏（v2.17.17 横屏置顶模式）屏高低 → 信息行紧凑（标题 1 行 / 简介
    // 少行），多留高度给评论区。
    final landscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final titleText = _video.isMultiPage
        ? (_currentPartTitle.isEmpty
            ? _video.title
            : '${_video.title} · $_currentPartTitle')
        : _video.title;
    final durMs = _durationMs > 0
        ? _durationMs
        : (_video.duration > 0 ? _video.duration * 1000 : 0);
    // 发布时间：旧数据/脏值（pubdate 为 null/0）→ 空串（见 [formatPubdate]），
    // 下面据此整段不拼接。
    final pubdateText = formatPubdate(_video.pubdate);
    // 简介（含换行原样；trim 去首尾空行——导入/接口常有结尾 \n）。
    // 多 P 视频简介是视频级：换分 P 不换简介（_video 不变）。
    final videoDesc = _video.desc.isNotEmpty ? _video.desc : _runtimeDesc;
    final desc = videoDesc.trim();
    // 番剧/电影（带 epId）→ 剧集标签：pgc 内容挂靠官方/搬运号，点进其
    // 「主页」无白名单点播价值且易误导（观感像进了 UP 空间其实是官方号），
    // 取舍为**弱化**——不拉 view owner、无头像、不可点（名字为导入数据
    // 的 up_name，空则显示「剧集」）。旧版导入的无 epId 番剧数据无法区分，
    // 走普通视频路径（行为以 view 接口实测 owner 为准，属已知边界）。
    final bangumiName =
        _video.upName.isEmpty ? '剧集' : _video.upName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题：竖屏 2 行 / 横屏 1 行截断；**超行才有**「展开/收起」入口
        // （长标题在播放页同样是重灾区）。未超行时不增一棵子树，与旧版一致。
        ExpandableText(
          text: titleText,
          foldLines: landscape ? 1 : 2,
          style: kTypeTitleM.copyWith(color: kInkBlack),
          // 标题不需要选择/复制，完整态用 Text（不引入选择手势与滚动手势打架）
          selectable: false,
          animated: true,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            // UP 主区（阶段 C）：普通视频 → 头像+名字可点；番剧 → 剧集标签
            if (_video.epId != null) ...[
              Icon(Icons.play_circle_outline,
                  size: 15, color: kInkGray50),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  bangumiName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: subStyle,
                ),
              ),
            ] else
              Flexible(
                child: UpownerBadge(
                  name: _ownerMeta != null && _ownerMeta!.name.isNotEmpty
                      ? _ownerMeta!.name // view owner.name 真名（覆盖 up_name）
                      : (_video.upName.isEmpty ? 'UP 主' : _video.upName),
                  face: _ownerMeta?.face,
                  onTap: _onUpownerTap,
                ),
              ),
            if (_video.isMultiPage) ...[
              const SizedBox(width: 8),
              Text('第 ${_currentPageIndex + 1} 集',
                  style: subStyle),
            ],
            const Spacer(),
            // 发布时间 + 时长（v2.27.1）：三级墨 + 等宽数字（与进度条两端
            // 时间同一套数字语汇），发布日期就接在时长左边、**同一行**——
            //   ① **零额外高度**：横屏置顶模式屏高低，信息块每多一行都从
            //      评论区抢地方，放简介区上方会多出一行；
            //   ② 与列表卡的「元信息行」写法一致（video_tile 的
            //      「时长 · UP主 · 发布日期」、upowner_page 的
            //      「时长 · 发布日期」），日期走同一套等宽数字语汇（kTypeNum
            //      + kInkGray50，与时长同级）；
            //   ③ 无简介的视频（desc 空 → 简介区整块不构建）也照样看得到。
            // 词序对齐 history_tile（「发布 xxx」在前、时长在后）。空串时
            // 只拼时长：界面上连分隔符都不会出现，与改动前逐字符一致。
            // 空间不够时让 UP 名（Flexible + 省略号）先让位，不挤掉这一段。
            Text(
              pubdateText.isEmpty
                  ? _fmtMs(durMs)
                  : '发布 $pubdateText · ${_fmtMs(durMs)}',
              style: kTypeNum.copyWith(color: kInkGray50),
            ),
          ],
        ),
        // 写操作行（v2.40.0+，默认关闭）：点赞 / 投币 / 收藏。
        //
        // 落点为什么在这里（信息块里独立一行，**不是底栏**）：底栏刚在
        // v2.39.0 收窄到 8 个 40dp 的按钮，第 9 个必然压垮「选集 1/2」这类
        // 文案（见 _buildBottomBar 的注释）；而信息块这一行本来就贴着
        // 标题/UP 主，是"关于这个视频"的信息集中地，写操作放在这里语义最近。
        //
        // 为什么套 ListenableBuilder：设置页那个总开关可能在播放页还活着
        // 的时候被改（播放页在路由栈下层），监听 store 才能一回来就对上。
        // **关闭时返回 SizedBox.shrink()**：零高度，Column 里不产生任何
        // 视觉变化（信息块几何与改动前逐像素一致），
        // 也就是"总开关关着 = 一个像素都不多"。
        ListenableBuilder(
          listenable: UiPrefsStore.instance,
          builder: (context, _) => _writeActionsAvailable
              ? _buildWriteActionsRow(context)
              : const SizedBox.shrink(),
        ),
        // 简介区：desc 空（无简介/番剧/拉取失败）不占位，避免空行喧宾夺主
        if (desc.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ExpandableText(
              text: desc,
              style: subStyle.copyWith(height: 1.45),
              // 折叠行数按方向：竖屏 3 行；横屏（屏高低）2 行更省高度
              foldLines: landscape ? 2 : 3,
              // 简介无链接、展开后整段都在滚动区内 → 无需长按复制兜底；
              // selectable=false：完整态用 Text（不引入选择手势与滚动打架）
              selectable: false,
              // 展开态封顶（超高内部滚动，收起按钮在滚动区外）
              maxExpandedHeight: _descMaxExpandedHeight(context),
            ),
          ),
      ],
    );
  }

  /// 简介展开态封顶高度：非全屏下方剩余高度（屏幕 − 视频区）扣掉信息行
  /// 标题/UP 行/边距等固有高度后的安全余量——防超长简介把固定信息行撑高
  /// 到把评论区挤没、整列溢出（余量小时展开区相应矮、超高部分内部滚动）。
  /// 竖屏夹在 [80, 220]；横屏（v2.17.17 横屏置顶模式，屏高低、标题 1 行）
  /// 收紧到 [48, 80]——展开后整行信息区仍给评论区留可见高度。
  double _descMaxExpandedHeight(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final landscape =
        screen.width > screen.height; // 与 _buildVideoInfoBar 紧凑判定一致
    final belowVideo = screen.height - _embeddedVideoHeight(screen);
    if (landscape) {
      const reservedForCompactInfoBar = 100.0; // 标题(1行)+UP 行+内边距+简介顶距
      return (belowVideo - reservedForCompactInfoBar).clamp(48.0, 80.0);
    }
    const reservedForInfoBar = 120.0; // 标题(≤2行) + UP 行 + 内边距 + 简介顶距
    return (belowVideo - reservedForInfoBar).clamp(80.0, 220.0);
  }

  /// 信息行 UP 主入口的元数据拉取（阶段 C）+ 简介运行时补拉（v2.17.3+）
  /// + 写操作初始态（v2.40.0+，v2.41.0 起改走 relation 接口）：
  /// fetchVideoMeta 拿 view 接口 data.owner{mid,name,face} 补齐头像与 UP 主页
  /// 入口，同时拿 data.desc 补旧数据缺的简介、拿 data.stat / data.aid 给
  /// 点赞·投币·收藏三个按钮；**互动态**（我赞没赞/投没投/收没收藏）另发一次
  /// `archive/relation`（v2.41.0+），与 view **并发**发出、同一批收口。
  ///
  /// 为什么互动态不能继续搭 view 的顺风车：view 实测**不下发 `req_user`**
  /// （匿名与登录都不下发），搭不上。见 [BiliApi.fetchVideoRelation] 的说明。
  ///
  /// 结果按 bvid 分别缓存在 [_upMetaCache]/[_viewDescCache]/[_reqUserCache]/
  /// [_relationCache]/[_viewStatCache]/[_viewAidCache]，多播放页/切集不重复请求。
  ///
  /// 番剧（epId != null）**不拉取**——阶段 C 取舍为弱化展示（见
  /// [_buildVideoInfoBar] 注释），避免为官方号做无意义请求；简介同理
  /// （番剧简介是季级、逐集导入留空，运行时也不补——见 whitelist_writer
  /// videoFromPgcEpisode 取舍）。**写操作按钮在番剧上也不出现**：pgc 内容的
  /// 点赞/投币是另一套 ep_id 接口，本版不接（见 [_writeActionsAvailable]）。
  Future<void> _refreshUpownerMeta() async {
    if (_video.epId != null) return; // 番剧：无 UP 入口/无简介/无写操作，不请求
    final bvid = _video.bvid;
    final cached = _upMetaCache[bvid];
    if (cached != null) {
      _ownerMeta = cached;
      // 缓存命中（同会话再次进入同一视频）：顺带恢复 desc 与写操作态
      // （都与 owner 写在同一次响应里）
      _runtimeDesc = _viewDescCache[bvid] ?? _runtimeDesc;
      _restoreWriteCache(bvid);
      return; // 会话内缓存命中（无需 setState：build 前同步赋值即可）
    }
    // 互动态与 view **并发**发出：两者互不依赖，串行会白白多等一个 RTT
    // （进入播放页的观感就是这么一点点攒起来的）。relation 内部自己吞异常、
    // 失败返回 null，所以这里不会因为它多出一个失败路径。
    final relationFuture = _api.fetchVideoRelation(bvid);
    final Map<String, dynamic> data;
    try {
      data = await _api.fetchVideoMeta(bvid);
    } catch (e) {
      // 失败静默：信息行保持 up_name 文本展示；点击时提示无法获取；
      // 简介区保持隐藏（desc 空时不占位）；写操作三个按钮此时 tap 会各自
      // 再兜底解析一次 aid（见 [_ensureWriteAid]），不必在这里拦
      debugPrint('[player_page] 拉取 UP 主信息失败 bvid=$bvid error=$e');
      // 收口并发的那次 relation：不让它悬着（失败路径也用不上它的值）
      await relationFuture;
      return;
    }
    final relation = await relationFuture;
    final parsed = parseViewOwner(data);
    final desc = viewDescOf(data);
    final reqUser = parseVideoReqUser(data);
    final stat = viewStatCounts(data);
    final aid = resolveAidForVideo(_video, meta: data);
    if (parsed != null) _upMetaCache[bvid] = parsed;
    if (desc.isNotEmpty) _viewDescCache[bvid] = desc;
    // 写操作相关一律**按 bvid 记账**（含"probed 但接口没给"这种情况：
    // 也要记下来，否则每次进同一视频都要等一次网络请求才敢渲染）
    _reqUserCache[bvid] = reqUser;
    _relationCache[bvid] = relation;
    _viewStatCache[bvid] = stat;
    if (aid != null) _viewAidCache[bvid] = aid;
    // 拉取期间可能换源/退出：按 bvid 对账，防把旧视频的 UP 信息串到新视频
    if (!mounted || _video.bvid != bvid) return;
    setState(() {
      _ownerMeta = parsed;
      _runtimeDesc = desc;
      _reqUser = reqUser;
      _relation = relation;
      _likeCount = stat.like;
      if (aid != null) _writeAid = aid;
      _applyWriteInitialState();
    });
    debugPrint('[player_page] UP 主信息 bvid=$bvid '
        'mid=${parsed?.mid} name=${parsed?.name}');
    debugPrint('[player_page] 写操作初始态 bvid=$bvid aid=$aid '
        'relation=$relation reqUser=$reqUser stat=$stat');
  }

  /// 把刚拿到的真实互动态落到三个按钮的初始态上。
  ///
  /// 优先级：**relation > req_user**——前者是专门回答这个问题的接口（要登录、
  /// 是真值），后者是 view 顺带给的（实测根本不下发，只为兼容既有夹具保留）。
  /// 两个都没有 → **一个字都不改**（维持"未点赞/未投币/未收藏"这个乐观起点，
  /// 同时 [_writeStateKnown] 为 false → UI 保留"状态未取到"的降级标注）。
  void _applyWriteInitialState() {
    final rel = _relation;
    if (rel != null) {
      _liked = rel.like;
      _coined = rel.coined;
      _faved = rel.fav;
      return;
    }
    final ru = _reqUser;
    if (ru != null) {
      _liked = ru.like;
      _coined = ru.coin;
      _faved = ru.favorite;
    }
  }

  /// 从会话内缓存恢复当前 bvid 的写操作态（[bvid] 命中 [_upMetaCache] 时走）。
  void _restoreWriteCache(String bvid) {
    if (_reqUserCache.containsKey(bvid)) _reqUser = _reqUserCache[bvid];
    if (_relationCache.containsKey(bvid)) _relation = _relationCache[bvid];
    final stat = _viewStatCache[bvid];
    if (stat != null) _likeCount = stat.like;
    final aid = _viewAidCache[bvid];
    if (aid != null) _writeAid = aid;
    _applyWriteInitialState();
  }

  // -------------------------------------------------------------------------
  // 写操作 UI（点赞 / 投币 / 收藏，v2.40.0+）
  // -------------------------------------------------------------------------

  /// 三个写操作按钮是否出现：**总开关打开 + 当前不是番剧集**。
  ///
  /// 为什么番剧集排除：pgc 内容的点赞/投币走的是另一套按 `ep_id` 的接口，
  /// 本版只接了普通视频的 `archive/like` / `coin/add`（都只认 aid）；
  /// 番剧集上摆三个点了会失败的按钮比不摆更糟。
  bool get _writeActionsAvailable =>
      UiPrefsStore.instance.writeActionsEnabled && _video.epId == null;

  /// 是否拿到了**真实的**初始态（`archive/relation` 的互动态，或退一步的
  /// view `data.req_user`）。
  ///
  /// false = 未登录 / 两个接口都没给出互动态 → 页面上的点赞态是"本次会话内的
  /// 乐观切换"，重启后可能与真实状态不一致。这种情况**必须在界面上说出来**，
  /// 不能让用户以为看到的就是账号里的真实状态（见 [_buildWriteActionsRow]
  /// 尾部标注）。true 就不用标注了——v2.41.0 起 relation 接口能带回真值，
  /// 标注从"永远挂着"变成"只在真拿不到时挂着"。
  bool get _writeStateKnown => _relation != null || _reqUser != null;

  /// 写操作行：`点赞 N · 投币 · 收藏` 三个轻量按钮 + （降级时）一句如实标注。
  ///
  /// 三个按钮行高只有一行（约 30dp），并且只在总开关打开时才构建——关着时
  /// 信息块高度与改动前逐像素一致。
  Widget _buildWriteActionsRow(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      key: const ValueKey('player-write-actions'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          _WriteActionChip(
            key: const ValueKey('write-like'),
            icon: _liked ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
            label: _liked ? '已赞' : '点赞',
            count: _likeCount,
            active: _liked,
            accent: primary,
            onTap: _writeBusy ? null : _onLikeTap,
          ),
          const SizedBox(width: 4),
          _WriteActionChip(
            key: const ValueKey('write-coin'),
            icon: Icons.monetization_on_outlined,
            label: _coined ? '已投币' : '投币',
            count: 0,
            active: _coined,
            accent: primary,
            onTap: _writeBusy ? null : _onCoinTap,
          ),
          const SizedBox(width: 4),
          _WriteActionChip(
            key: const ValueKey('write-fav'),
            icon: _faved ? Icons.star : Icons.star_border,
            label: _faved ? '已收藏' : '收藏',
            count: 0,
            active: _faved,
            accent: primary,
            onTap: _writeBusy ? null : _onFavTap,
          ),
          if (!_writeStateKnown) ...[
            const SizedBox(width: 8),
            // 降级如实标注（不是装饰）：没有 req_user 时上面的"已赞/未赞"只是
            // 本次会话的猜测，重启后可能显示错——与其让用户以为 App 显示错了，
            // 不如直接说明白。
            Flexible(
              child: Text(
                '状态未取到，重启后可能显示不准',
                key: const ValueKey('write-state-unknown'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: kInkGray50),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 拿写操作用的 aid：缓存命中直接用；否则现拉一次 view（[fetchVideoAid]
  /// 内部自己解析并兜异常，失败返回 null）。
  Future<int?> _ensureWriteAid() async {
    final cached = _writeAid;
    if (cached != null && cached > 0) return cached;
    final aid = await _api.fetchVideoAid(_video);
    if (aid != null && aid > 0) {
      _writeAid = aid;
      _viewAidCache[_video.bvid] = aid;
    }
    return aid;
  }

  /// 写操作失败的统一提示（**错误类** SnackBar）。
  ///
  /// 用 `SnackKind.error` 而不是页内 [_showSnack]：写操作失败绝不能被设置里
  /// 的「显示底部提示条」开关静默——用户以为点赞成功了、其实没有（或反过来
  /// 以为投币没出去、其实扣了硬币），这个误解比多看一条提示糟糕得多。
  void _writeSnack(String message) {
    if (!mounted) return;
    AppSnack.show(context, message, kind: SnackKind.error);
  }

  /// 点赞 / 取消点赞（**幂等**：传的是目标态，所以可以放心先改界面）。
  ///
  /// 乐观切换 + 失败回滚：点赞是唯一幂等的写操作，失败时把界面改回去不会
  /// 让服务端状态和界面脱节（重新点一次仍是同一个目标态）。
  Future<void> _onLikeTap() async {
    final aid = await _ensureWriteAid();
    if (!mounted) return;
    if (aid == null) {
      _writeSnack('拿不到视频信息（aid），无法点赞');
      return;
    }
    final target = !_liked;
    setState(() {
      _liked = target;
      _likeCount += target ? 1 : -1;
      _writeBusy = true;
    });
    try {
      await _api.likeVideo(aid: aid, like: target, bvid: _video.bvid);
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _rememberWriteState();
      debugPrint('[player_page] 点赞 aid=$aid like=$target ok');
    } on BiliApiException catch (e) {
      if (!mounted) return;
      // 回滚：接口没生效，界面也不能留着"已赞"
      setState(() {
        _liked = !target;
        _likeCount -= target ? 1 : -1;
        _writeBusy = false;
      });
      _writeSnack(target ? '点赞失败：${e.message}' : '取消点赞失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      setState(() {
        _liked = !target;
        _likeCount -= target ? 1 : -1;
        _writeBusy = false;
      });
      _writeSnack('网络请求失败，点赞未生效');
    }
  }

  /// 投币：**先二次确认，再发请求**。
  ///
  /// 为什么必须要这一步（三道风险，确认框里逐条说清）：
  /// ① **不可撤回**——B 站没有"取消投币"接口，投出去就回不来；
  /// ② **扣的是真硬币**——不是"记录一个状态"，是消耗账号里的资产；
  /// ③ **会连带点赞**（`select_like`）——一次点击产生两个后果，用户没点过赞
  ///    就凭空多一个赞（会进对方的消息/动态）。
  ///
  /// 所以：**取消 → 一个请求都不发**（`confirmed != true` 直接 return）。
  /// 投币同时也**不做乐观更新**（[multiply] 不是目标态、不幂等）——只有服务端
  /// 确认成功才把按钮改成"已投币"。
  Future<void> _onCoinTap() async {
    final aid = await _ensureWriteAid();
    if (!mounted) return;
    if (aid == null) {
      _writeSnack('拿不到视频信息（aid），无法投币');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('投 1 枚硬币？'),
        content: const Text(
          '硬币会从你的 B 站账号里真实扣除，投出后 B 站不支持撤回，也不退还。'
          '（同一个稿件最多 2 枚。）\n\n'
          '投币会同时给这个视频点赞（B 站「投币并点赞」）——'
          '不想点赞的话，这里点「取消」。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('write-coin-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('投 1 枚并点赞'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _writeBusy = true);
    try {
      await _api.addCoin(aid: aid, multiply: 1, alsoLike: true);
      if (!mounted) return;
      setState(() {
        _writeBusy = false;
        _coined = true;
        // 连带点赞：select_like=1 时服务端也会把点赞置上，界面跟着走
        _liked = true;
      });
      _rememberWriteState();
      AppSnack.show(context, '已投 1 枚硬币并点赞');
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _writeSnack('投币失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _writeSnack('网络请求失败：投币可能没成功，请到 B 站确认后再决定要不要重投');
    }
  }

  /// 收藏 / 取消收藏：弹收藏夹列表让用户选（**收藏与取消用同一个弹层**）。
  ///
  /// 为什么取消也要选夹：B 站按"从哪个夹里删"来取消，同一条视频可以在多个夹
  /// 里——不选夹就无从取消。选中的夹会被记到本地 prefs（
  /// [UiPrefsStore.setFavFolderId]，**不写 Gist**：那是本机操作习惯，跨设备
  /// 同步可能指到别的账号的夹 id 上），下次进来它排第一个。
  Future<void> _onFavTap() async {
    final aid = await _ensureWriteAid();
    if (!mounted) return;
    if (aid == null) {
      _writeSnack('拿不到视频信息（aid），无法收藏');
      return;
    }
    setState(() => _writeBusy = true);
    List<FavoriteFolder> folders;
    try {
      // 只读接口（v2.17.5+ 就有）：拿夹列表，不新增重复方法
      folders = await _api.fetchMyFavorites();
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _writeSnack('收藏夹列表获取失败：${e.message}');
      return;
    } on DioException {
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _writeSnack('网络请求失败，收藏夹列表没拿到');
      return;
    }
    if (!mounted) return;
    setState(() => _writeBusy = false);
    if (folders.isEmpty) {
      _writeSnack('没有可用的收藏夹，请先到 B 站建一个');
      return;
    }
    final removing = _faved;
    final picked = await showModalBottomSheet<FavoriteFolder>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FavFolderSheet(
        folders: folders,
        removing: removing,
        lastFid: UiPrefsStore.instance.favFolderId,
      ),
    );
    if (picked == null || !mounted) return;
    unawaited(UiPrefsStore.instance.setFavFolderId(picked.mediaId));
    setState(() => _writeBusy = true);
    try {
      await _api.favVideo(
        aid: aid,
        addFid: removing ? null : picked.mediaId,
        delFid: removing ? picked.mediaId : null,
      );
      if (!mounted) return;
      setState(() {
        _writeBusy = false;
        _faved = !removing;
      });
      _rememberWriteState();
      debugPrint('[player_page] ${removing ? '取消收藏' : '收藏'} aid=$aid '
          'fid=${picked.mediaId} ok');
      AppSnack.show(
          context, removing ? '已从「${picked.title}」移除' : '已收藏到「${picked.title}」');
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _writeSnack('${removing ? '取消收藏' : '收藏'}失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      setState(() => _writeBusy = false);
      _writeSnack('网络请求失败，请稍后重试');
    }
  }

  /// 换源时复位写操作态（被 [playVideo] 调用）。
  void _resetWriteActions() {
    _relation = null;
    _reqUser = null;
    _writeAid = null;
    _likeCount = 0;
    _liked = false;
    _coined = false;
    _faved = false;
    _writeBusy = false;
  }

  /// 把本页刚做成功的写操作写回会话内缓存（v2.40.0+，v2.41.0 起同时更新
  /// relation）。
  ///
  /// 为什么需要：缓存里存的是"服务端某次告诉我的互动态"，而这里的点赞/投币/
  /// 收藏是**我们刚刚真实改掉的状态**。不写回去的话，「点赞 → 返回 → 再进
  /// 同一条视频」（同会话命中缓存、不再打接口）会显示旧的"未点赞"，用户会
  /// 以为没生效。
  ///
  /// 只在**原本就拿到过真实态**（[_writeStateKnown]）时写回：未知时强行造一个
  /// relation 会把"猜的"伪装成"服务端说的"，比显示旧值更糟——那条"状态未取到"
  /// 的降级标注必须继续说真话。
  ///
  /// 只改本地、**不重拉接口**：用户刚点完的那一下，本地就知道结果（写成功的
  /// 前提就是服务端接受了这个目标态），再发一次 GET 只是把一个确定的答案问一遍。
  void _rememberWriteState() {
    if (!_writeStateKnown) return;
    _reqUserCache[_video.bvid] = VideoReqUser(
      like: _liked,
      coin: _coined,
      favorite: _faved,
    );
    // 投币枚数：原本拿到的枚数保留（B 站上限 2，我们只会往上加 1），
    // 原本没拿到（0 或未知）时按"投过 1 枚"记——UI 只用 coined，枚数仅备查。
    final prevCoin = _relation?.coin ?? 0;
    final next = VideoRelation(
      like: _liked,
      coin: _coined ? (prevCoin > 0 ? prevCoin : 1) : 0,
      fav: _faved,
    );
    _relation = next;
    _relationCache[_video.bvid] = next;
  }

  /// 点击信息行 UP 主区（仿 B 站 → 进 UP 主主页 [UpownerPage]）。
  ///
  /// - 已有 mid（view owner 拉取成功）→ 先暂停本页播放再 push UP 主页，
  ///   返回时 [didPopNext] 恢复续播（复用 v2.17.1 叠播放页的让路机制：
  ///   从 UP 主页再点开视频时本页不产生重叠音轨）
  /// - 无 mid（拉取失败/进行中）→ 名字照常显示，点击提示获取状态，不进页
  void _onUpownerTap() {
    final meta = _ownerMeta;
    if (meta == null) {
      _showSnack('无法获取 UP 主信息（网络异常或稿件已失效）');
      return;
    }
    if (!mounted) return;
    debugPrint('[player_page] 进 UP 主页 mid=${meta.mid} name=${meta.name} '
        'bvid=${_video.bvid}');
    _pauseBeforePushingNewPlayer();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpownerPage(
          mid: meta.mid,
          // initial 预填头像/名字（头部卡片立即可见，fetchUpownerInfo 返回后
          // 覆盖；addedAt 仅为满足 Upowner 必填字段——播放页非白名单写入方，
          // UpownerPage 只用 name/face/fans，不读写加入时间）
          initial: Upowner(
            mid: meta.mid,
            name: meta.name,
            face: meta.face,
            addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
        ),
      ),
    );
  }

  /// 非全屏（竖屏置顶 / v2.17.17 横屏置顶）内嵌评论区：数据/列表/楼中楼/
  /// 图片/链接全部复用 [CommentListView]（与独立 [CommentPage] 同一份实现，
  /// 避免双份）。
  ///
  /// 按「bvid + 当前分 P」换 key：换集/换源时自动重建重拉——评论归属随
  /// aid 变化（换源必变；同 aid 分 P 只是多一次请求，换取语义简单可靠），
  /// 且滚动位置随新视频复位。评论内点视频链接 → [openVideoInNewPlayer]
  /// **push 新播放页**（v2.17.1+：push 前显式暂停本页防双音轨、返回时
  /// 恢复本视频续播），不再走 playVideo 换源。
  Widget _buildEmbeddedComments() {
    // 发表评论（v2.42.0+）与点赞/投币/收藏共用**同一道写操作总开关**
    // （UiPrefsStore.writeActionsEnabled，默认关）：一个总闸管全部写操作，
    // 不做"评论单独一个开关"——用户要的是"别碰我账号"这一个决定。
    // 套 ListenableBuilder 的理由同信息块那行：设置页可能在播放页还活着时
    // 改开关（播放页在路由栈下层），监听 store 才能一回来就对上。
    return ListenableBuilder(
      listenable: UiPrefsStore.instance,
      builder: (context, _) => CommentListView(
        key: ValueKey('embedded-comments-${_video.bvid}-$_currentPageIndex'),
        video: _video,
        controller: _commentScroll,
        countHeaderKey: _commentCountHeaderKey,
        showCountHeader: true,
        onOpenVideo: openVideoInNewPlayer,
        // v2.40.0+：本处（且只有本处）开启「评论区左右滑切换热门/最新排序」。
        // 为什么只在这里开：用户是在**看视频时**抱怨"评论区不能左右划"，
        // 而播放页内嵌评论区是唯一有"继续看下去"语境的位置；专栏 / 动态 /
        // 独立评论页的横向手势位将来另有用途（单条左滑等），现在不占。
        // 两者不能同时上：同一片区域只能有一套横滑手势（见参数注释）。
        enableSortSwipe: true,
        // v2.42.0+：同样只在本处开「说点什么… / 回复」。另外三个使用点
        // （专栏 / 动态 / 独立评论页）保持默认 false → 渲染树逐节点不变。
        enableCompose: UiPrefsStore.instance.writeActionsEnabled,
      ),
    );
  }

  /// 画面变换的复位入口（v2.39.0+，仅全屏且 [_viewTransformed] 时出现）。
  ///
  /// 位置：右下方、底栏之上（`bottom: kPlayerBottomBarHeight + 12`）——**不进
  /// 底栏那一行**（8 等分每格 51.4dp，第 9 个按钮会压垮「选集 1/2」这类文案，
  /// 见 ② 的约束）；也不放中央（会与播放簇抢点击）。
  ///
  /// 是**开关式**的可见性而不是常驻：只有画面真的被放大/旋转过才出现，
  /// 没变换时一个像素都不多（与「没有播放列表就不构建上下集行」同一标准）。
  /// 顺带显示当前倍数，用户一眼知道自己在哪一档（4.0x 会显示 4.0x）。
  Widget _buildViewResetButton() {
    return Positioned(
      right: 12,
      bottom: kPlayerBottomBarHeight + 12,
      child: TextButton.icon(
        key: const ValueKey('player-view-reset'),
        onPressed: _resetViewTransform,
        icon: const Icon(Icons.restart_alt, size: 16, color: kPlayerOn),
        label: Text(
          '复位 ${_viewScale.toStringAsFixed(1)}x',
          style: kTypeLabel.copyWith(color: kPlayerOn),
        ),
        style: TextButton.styleFrom(
          // 压在任意画面上都要读得清：墨黑 62% 圆角底 + 纸白字（与手势 hud
          // 同一套语汇，不引入新配色）
          backgroundColor: kInkBlack.withValues(alpha: .62),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
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
            color: kInkBlack.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: kPlayerOn, size: 22),
              const SizedBox(width: 8),
              Text(
                text,
                style: kTypeTitleM.copyWith(color: kPlayerOn),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 听视频占位界面：封面 + 标题 + 提示。点按恢复画面；长按同样支持 2x。
  /// v2.17.0+：占位层绑定在视频区矩形内（非全屏黑盒可能较矮），内容压缩
  /// + 可滚动，防小盒溢出。
  Widget _buildListenPlaceholder() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleListenMode,
        onLongPressStart: _player == null ? null : _onLongPressStart,
        onLongPressEnd: _player == null ? null : _onLongPressEnd,
        child: ColoredBox(
          color: Colors.black,
          child: SingleChildScrollView(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 封面：与列表/占位层共用 [CoverImage]（防盗链头 + 加载/
                    // 失败占位只此一份）。听视频占位层的封面尺寸固定 150x84，
                    // 与 [CoverImage] 默认一致，只是这里显式写出来免歧义。
                    if (_video.cover.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CoverImage(
                          cover: _video.cover,
                          width: 150,
                          height: 84,
                        ),
                      )
                    else
                      const Icon(Icons.headphones,
                          color: kPlayerOnDim, size: 40),
                    const SizedBox(height: 12),
                    const Icon(Icons.headphones,
                        color: kPlayerOnDim, size: 24),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: kTypeTitleS.copyWith(color: kPlayerOn),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('听视频中 · 点按恢复画面',
                        style: kTypeBodyS.copyWith(color: kPlayerOnDim)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 中央播放/暂停键图形（P5 印刷语汇）：1.5px 纸白描边圆 + 8% 纸白半透明
  /// 填充 + 实心三角/暂停双竖条——比原来实心 `play_circle_filled` 更克制、
  /// 平面（不靠色块压画面）。
  ///
  /// 尺寸固定 72×72：与原 `iconSize: 72` 完全一致——中央簇尺寸属几何敏感区
  /// （[_buildControls] 的 compactEmbedded 收起判定 + player_landscape_pin
  /// 测试的矩形断言），**只换描边不换尺寸**。
  Widget _buildPlayGlyph() {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          // 测试锚点：中央播放键的圆环（与上下集行的可读性断言以它为基准 ——
          // 压在标签上的是这个 72dp 圆，不是 IconButton 的整个盒子）。
          key: const ValueKey('player-play-glyph'),
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: kPlayerPaper.withValues(alpha: 0.08),
            border: Border.all(
              color: kPlayerPaper.withValues(alpha: 0.8),
              width: 1.5,
            ),
          ),
        ),
        Icon(_playing ? Icons.pause : Icons.play_arrow,
            color: kPlayerOn, size: 34),
      ],
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
                style: TextStyle(color: kPlayerOn, fontSize: 16)),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 快退 3 秒：Icons.replay 转圈箭头，tooltip 提示；连点连续生效
            IconButton(
              tooltip: '快退 3 秒',
              iconSize: 40,
              color: kPlayerOn,
              icon: const Icon(Icons.replay),
              onPressed: _player == null ? null : _rewind3s,
            ),
            IconButton(
              iconSize: 72,
              color: kPlayerOn,
              icon: _buildPlayGlyph(),
              onPressed: _player == null ? null : _togglePlay,
            ),
            // 快进 3 秒：Icons.forward_30 转圈箭头，与左侧快退对称
            IconButton(
              tooltip: '快进 3 秒',
              iconSize: 40,
              color: kPlayerOn,
              icon: const Icon(Icons.forward_30),
              onPressed: _player == null ? null : _forward3s,
            ),
          ],
        ),
      ],
    );
  }

  /// 顶部控制栏（全屏 / 非全屏共用的返回行）。
  ///
  /// 遮罩：现在就是「贴内容高度」的渐变条（SafeArea + 48 高按钮行 ≈ 48 + 状态栏
  /// inset），P5 保持不扩大——只有返回键与全屏标题两个元素，无需更高的 scrim。
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
              icon: const Icon(Icons.arrow_back, color: kPlayerOn),
              // 命中区 ≥48×48（Android 触摸规范）：M3 IconButton 的 padded
              // tapTarget 已是 48，这里显式钉住 minSize，避免将来主题改
              // visualDensity / tapTargetSize 时悄悄缩水
              constraints:
                  const BoxConstraints(minWidth: 48, minHeight: 48),
              // v2.17.17：全屏中返回 = 先退出全屏（回当前方向置顶+评论），
              // 非全屏 = 离开播放页（见 _handleBack）
              onPressed: _handleBack,
            ),
            // v2.17.0+：标题只在全屏顶栏显示——非全屏（竖屏置顶 / 横屏
            // 置顶）标题在视频下方信息行（_buildVideoInfoBar），避免同一
            // 标题在屏上出现两次。
            if (_fullscreen)
              Expanded(
                child: Text(
                  _video.isMultiPage
                      ? '${_video.title} · $_currentPartTitle'
                      : _video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kTypeTitleM.copyWith(color: kPlayerOn),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 底部按钮行的「开关图标 + 开启标记」：开启态 [kPlayerOn]（纸白）、
  /// 关闭态 [kPlayerOff]（白 38%）；开启时图标下方加一条 2×10 纸白短线。
  ///
  /// 短线是**颜色之外的第二状态载体**（Android 无障碍规范：状态不得只用颜色
  /// 表达）；关闭态同样占 2px 槽位（无子节点 = 不绘制），保证两态图标垂直
  /// 位置不跳动。
  ///
  /// v2.39.0 起图标 20 → 18：按钮行 44 → 40 后竖向余量从 4.8dp 收到 3.8dp，
  /// 18 的图标把「图标 + 短线槽 + 间距 + 单行文字」压到 36.2dp，余量回到 3.8dp
  /// 之上（详见 [_barIconLabel] 的算式）。
  Widget _barToggleIcon(IconData icon, {required bool on}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: on ? kPlayerOn : kPlayerOff, size: 18),
        const SizedBox(height: 2),
        SizedBox(
          width: 10,
          height: 2,
          child: on ? const ColoredBox(color: kPlayerOn) : null,
        ),
      ],
    );
  }

  /// 底部按钮行的单个按钮内容：**图标在上、标签在下**的竖排单元（v2.17.18）。
  ///
  /// 为什么改成竖排：8 等分格在 411dp 宽屏（Pixel 7 档）上每格仅 51.4dp，
  /// 横排时「图标 20 + 间距 4」先吃掉 24dp，标签只剩 27.4dp——而 [kTypeLabel]
  /// （11px + 字距 0.6 ≈ 11.6dp/字）下 2 个中文字要 23.2dp、3 个字要 34.8dp、
  /// 4 个字要 46.4dp，**必然**被 `TextOverflow.ellipsis` 截断（实测「选集 1/N」
  /// 显示成「选⋯」、「听视频」显示成「听⋯」，「听视频中」「字幕中」「已缓存」
  /// 同理）。竖排后标签独占整格宽 51.4dp：3 字（34.8）与 4 字（46.4）都完整
  /// 显示，不再有省略号。
  ///
  /// [FittedBox]（`scaleDown`，Flutter 内置组件，不引入新依赖）是最后一道
  /// 保险：极端长度（如「选集 1/100」≈ 56dp 超出整格）整体等比缩到格宽以内
  /// 而**不省略**；正常长度缩放比 = 1，字号仍是 [kTypeLabel]，字阶不乱。
  /// 竖排单元高 = 图标（开关类 18 + 短线槽 2 + 短线 2 = 22，非开关类 18）
  /// + 间距 + 单行文字 13.2：最坏情况（开关类按钮，如「听视频中」「字幕中」）
  /// 22 + 1 + 13.2 = **36.2** ＜ 按钮行 [_kBottomButtonRowHeight] 40，仍留
  /// 3.8dp 余量（v2.39.0 起把图标 20 → 18、间距 2 → 1，就是为了在行高收 4dp
  /// 之后保住这段余量——图标或文字一旦顶到行高它俩就会被竖向挤压裁切）。
  /// 点击回调、按钮顺序全部照旧。
  Widget _barIconLabel({
    required Widget icon,
    required String label,
    required Color color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(height: 1),
        SizedBox(
          // 撑满整格宽（Column 交叉轴对子级是松约束，infinity 会夹到格宽），
          // 让 FittedBox 拿到确定的可用宽度
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              // softWrap: false 且不设 maxLines：文本按自然宽度单行排版（不受
              // 格宽约束 → 结构上不可能出现省略号），超宽交给 FittedBox 缩放
              softWrap: false,
              style: kTypeLabel.copyWith(color: color),
            ),
          ),
        ),
      ],
    );
  }

  /// 进度条行：两端时间文本 + 自绘 [_PlayerSeekBar] + 预览浮层。
  ///
  /// 单独成方法是因为**手势横滑 seek 时控制层可能是收着的**（用户点画面隐藏
  /// 过）——那时只把这一行浮出来就够了（见 [_buildSeekRowOnly]），没必要把
  /// 顶栏 / 中央播放簇 / 8 个按钮整套弹出来。两条路径共用同一份行实现，
  /// 进度条盒与气泡坐标系自然一致。
  Widget _buildSeekRow() {
    return SizedBox(
      height: _PlayerSeekBar.height,
      child: Row(
        children: [
          // 已播时间：等宽数字（秒位跳动时不抖）
          Text(_fmtMs(_positionMs),
              style: kTypeNum.copyWith(color: kPlayerOn)),
          Expanded(
            child: Padding(
              // 细轨与两端时间文本之间留白（原 Slider 内建 24px 边距，
              // 自绘后按印刷语汇收紧到 8）
              padding: const EdgeInsets.symmetric(horizontal: 8),
              // LayoutBuilder 取「轨道可用宽度」：手势横滑 seek 时用它把
              // 「位置比例」映射成气泡锚点（见 [_gestureSeekAnchorX]）——
              // 轨道宽度由布局决定（两端时间文本宽度随字号/时长变），不该
              // 在整屏坐标系里反推。
              child: LayoutBuilder(
                builder: (context, c) {
                  final trackWidth = c.maxWidth;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _PlayerSeekBar(
                        // 测试锚点：进度条盒（拖动预览的定位/断言都以它为
                        // 基准；与 'player-video-area' 同款约定）
                        key: const ValueKey('player-seek-bar'),
                        positionMs: _positionMs,
                        durationMs: _durationMs,
                        // 原生播放器未上报缓冲进度（BiliDashEvent 只有
                        // prepared/completed/error/urlExpired 四类），因此
                        // 不画缓冲段——不伪造数据；将来原生补
                        // onBufferUpdate 时在此传值即可点亮轨道中段的
                        // kPlayerOnDim。
                        bufferedMs: null,
                        // 手柄：控制层可见时照旧；此外拖动进度条与手势横滑
                        // seek 期间也要看得见（手势 seek 时控制层可能收着，
                        // 「直接拖进度条」的手感全靠这根柄）
                        showHandle: _controlsVisible || _dragging ||
                            _gestureSeeking,
                        // 回调完全沿用原 Slider：拖动中 = onChanged
                        // （_onSeekStart 只更新 UI 位置），松手 =
                        // onChangeEnd（_onSeekEnd 提交 seekTo）——
                        // 播放行为零改动
                        onDrag: _onSeekStart,
                        onDragEnd: _onSeekEnd,
                        onDragPosition: _onSeekDragPosition,
                      ),
                      // 拖动预览浮层：拖动中才在树里，松手即消失（无淡出——
                      // 跟手的东西淡出会读成「没跟上手」）。位置跟随手指
                      // 并且水平夹在轨道内（必然不越出屏幕）；轨道太窄放
                      // 不下缩略图 → 只给时间气泡。
                      //
                      // 两条 seek 路径共用同一个浮层，只是锚点不同：拖进度条
                      // → 手指在轨道上的真实位置；手势横滑 → 按位置比例映射
                      // 回轨道的「虚拟手指」（[_gestureSeekAnchorX]）。
                      if (_dragging && _previewTrackWidth > 0)
                        _buildSeekPreview(
                          trackWidth: _previewTrackWidth,
                          anchorX: _previewDragX,
                        )
                      else if (_gestureSeeking && trackWidth > 0)
                        _buildSeekPreview(
                          trackWidth: trackWidth,
                          anchorX: _gestureSeekAnchorX(trackWidth),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          Text(_fmtMs(_durationMs),
              style: kTypeNum.copyWith(color: kPlayerOn)),
        ],
      ),
    );
  }

  /// 手势横滑 seek 且控制层收着时，只把进度条行浮出来。
  ///
  /// 为什么不是直接显示整套控制层：横滑 seek 的诉求是「手柄跟着手指 +
  /// 气泡贴着进度条」，顶栏 / 中央播放簇 / 8 个按钮一起弹出来只会更干扰；
  /// 而控制层的显隐是用户点画面定下的偏好，不该被一次 seek 改掉
  /// （所以不动 [_controlsVisible]）。
  ///
  /// 行位置与 [_buildBottomBar] 里那一行**完全一致**（下面留出按钮行的高度，
  /// 遮罩也是同一份）——控制层显隐切换时进度条不会上下跳。
  Widget _buildSeekRowOnly() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        bottom: _fullscreen,
        child: Container(
          decoration: _kBottomBarScrim,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 有上下集行时**空出同样的高度**：这一行的位置必须与完整底栏里的
              // 那一份逐像素一致（见本方法注释），否则「横滑 seek 浮出进度条」
              // 与「控制层弹出」之间来回切换时进度条会上下跳 40dp。这里只留占位、
              // 不渲染按钮：横滑 seek 手势中途冒出一对可点的「上一集/下一集」
              // 既不是用户此刻的意图，也会把一次滑动变成误触换集。
              if (_hasPlaylistNeighbors)
                const SizedBox(height: _kPlaylistRowHeight),
              _buildSeekRow(),
              const SizedBox(height: _kBottomButtonRowHeight),
            ],
          ),
        ),
      ),
    );
  }

  /// 底栏遮罩：底部 black54 → 透明。细轨压在浅色画面上靠它才看得清，
  /// 底栏与「手势 seek 单独浮出的进度条行」（[_buildSeekRowOnly]）共用。
  static const BoxDecoration _kBottomBarScrim = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [Colors.black54, Colors.transparent],
    ),
  );

  /// 底栏「上下集行」高度（仅在有播放列表时占据底栏上沿的一条）。
  ///
  /// 40 而不是 44：这一行只有一个 18px 图标 + 一行小字，纯粹是导航；但也不能
  /// 更矮——「上一集」「下一集」各占左右半屏（411dp 屏上 ~205dp 宽），高度是
  /// 唯一被压缩的维度，40dp 是可点且不误触的下限。
  static const double _kPlaylistRowHeight = 40;

  /// 底栏「上一集 / 第 N/M 集 / 下一集」行（v2.30.0+ 同合集上下集）。
  ///
  /// 为什么放在底栏、且**单独一行**：
  /// - 不挤占既有按钮行：那一行在 411dp 宽屏上 8 等分后每格仅 51.4dp，为了
  ///   不出现省略号才特意改成竖排（见 [_barIconLabel]）；再塞两个按钮必然
  ///   压垮「选集 1/2」「听视频中」这些既有文案。所以不碰它；
  /// - 也不用中央控制簇：视频区过矮（[compactEmbedded]）时整个中央簇会被
  ///   收起，放那里会在横屏置顶/超宽视频下消失。底栏在竖屏 / 横屏置顶 /
  ///   横屏全屏三种形态下都渲染；
  /// - 位置在**进度条行上方**：底栏整体贴底（Align.bottomCenter），往上长
  ///   不影响下方任何几何，[_buildSeekRowOnly]（手势 seek 单独浮出进度条）
  ///   也完全不受影响；
  /// - 播放列表**不足两条时不构建本行**（上下集都无处可去 = 两个死按钮），
  ///   与「没有播放列表就一个像素都不多」是同一标准——这正是用户在通知栏
  ///   那边投诉过的形态，不能在播放页重演。
  ///
  /// 头尾**禁用**（[InkWell.onTap] 传 null，文字转暗色）：不循环、不越界；
  /// 禁用的按钮保持可见（位置稳定，不会因为到最后一集按钮消失而让中间
  /// 位置文案横向跳动）。
  ///
  /// v2.30.0-r2 修布局缺陷（真机实测 P1）：初版写成 `Row[Expanded, Flexible,
  /// Expanded]`，三个孩子都吃 flex，中间标签白拿 1/3 行宽却又用不满（loose fit），
  /// 用不完的份额按 [MainAxisAlignment.start] 留在**行尾**变成死区 —— 实测竖屏
  /// 411dp 上按钮各只有 137dp（1/3 屏），行右侧 366.8..411（44dp）纯死区；横屏
  /// 更糟：两侧还有 cutout inset，屏宽 75% 处（视觉上就在「下一集 ▶」旁边）点下去
  /// 落空。现在改成 **Stack：两个 [Expanded] 各拿真正的半屏 + 中间标签浮在上层**：
  /// - 标签不参与 Row 的宽度分配（[Positioned.fill] 里的 Row 只有两个 flex 孩子
  ///   → 各 = 行宽 × 0.5），死区从根上消失；
  /// - 标签自己给死了最大宽度（见 [kPlaylistLabelMaxWidth]），长 label 走省略号，
  ///   绝不会反过来挤掉按钮；
  /// - 标签**层**用 [IgnorePointer]：文字层不得吃掉中间那一带的点击 —— 否则
  ///   RenderParagraph 会命中自己，把「上一集 / 下一集」的分界线上的一段变成
  ///   点击黑洞（与上面那个死区是同一个 bug 的两种表现）。
  ///
  /// 按钮高度撑满整行（[Positioned.fill]）：40dp 行高才是设计里的触摸目标下限，
  /// 初版 InkWell 只包了内容（18dp 高），点偏一点就落空。
  Widget _buildPlaylistRow() {
    final videos = _playlistVideos!;
    final label = _playlistLabel;
    final posText = (label == null || label.isEmpty)
        ? '${_playlistIndex + 1}/${videos.length}'
        : '$label · ${_playlistIndex + 1}/${videos.length}';
    // 深浅两色表达「可点/禁用」：可点 = kPlayerOn（纸白），禁用 = kPlayerOnDim
    return SizedBox(
      key: const ValueKey('player-playlist-row'),
      height: _kPlaylistRowHeight,
      child: LayoutBuilder(
        builder: (context, c) {
          // 标签宽度上限：既要装得下「合集名 · 3/5」这类文案，又不能长到压住两侧
          // 按钮的图标/文字。`0.34 ×` 那一项是给窄屏兜底（320dp 屏左右各半屏只有
          // 160dp，按钮内容约 57dp 宽居中，中间自由带只剩 ~103dp）。
          final maxLabelWidth =
              math.min(kPlaylistLabelMaxWidth, c.maxWidth * 0.34);
          return Stack(
            children: [
              Positioned.fill(
                child: Row(
                  // 撑满整行高（40dp）—— Row 默认 center 会让 InkWell 只有内容高
                  // （18dp），点偏一点就落空（见方法注释里的触摸目标下限）。
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: InkWell(
                        key: const ValueKey('player-prev-video'),
                        onTap: _canPlayPrev ? () => playNeighbor(-1) : null,
                        child: _playlistNavLabel(
                          icon: Icons.skip_previous,
                          label: '上一集',
                          enabled: _canPlayPrev,
                        ),
                      ),
                    ),
                    Expanded(
                      child: InkWell(
                        key: const ValueKey('player-next-video'),
                        onTap: _canPlayNext ? () => playNeighbor(1) : null,
                        child: _playlistNavLabel(
                          icon: Icons.skip_next,
                          label: '下一集',
                          enabled: _canPlayNext,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Center(
                child: IgnorePointer(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxLabelWidth),
                    child: Text(
                      posText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: kTypeLabel.copyWith(color: kPlayerOnDim),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 上下集按钮内容：图标 + 文字横排居中（图标朝外：上一集在左、下一集在右）。
  Widget _playlistNavLabel({
    required IconData icon,
    required String label,
    required bool enabled,
  }) {
    final color = enabled ? kPlayerOn : kPlayerOnDim;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Text(label, style: kTypeLabel.copyWith(color: color)),
      ],
    );
  }

  Widget _buildBottomBar() {
    return Container(
      // 测试锚点：底栏整体（几何断言量它的高度 = 上下集行 40 + 进度条行 40 +
      // 按钮行 40；无播放列表时不含第一项）。手势 seek 单独浮出的那一份
      // （[_buildSeekRowOnly]）**不挂 key**——它是另一条渲染路径，锚点会撞车。
      key: const ValueKey('player-bottom-bar'),
      decoration: _kBottomBarScrim,
      // 两行结构：进度条行（[_buildSeekRow]，[_PlayerSeekBar.height] = 40）+
      // 按钮行（[_kBottomButtonRowHeight] = 40：选集/倍速/听视频/字幕/弹幕/
      // 评论/下载/全屏）；合计 [kPlayerBottomBarHeight] = 80。
      //
      // P5：进度条行不用原生 Slider——Slider 在「有界高度」约束下会撑满整个
      // 高度（_RenderSlider 布局取 constraints.maxHeight）并吞掉中心播放/暂停
      // 与返回按钮的点击，且两端内建 24px 边距让细轨几何不可控。改为自绘后
      // 轨道位置 / 命中区 / 柄形状全部自定（见 [_PlayerSeekBar] 类注释）。
      // 行高沿革：P5 曾把进度条行 36 → 44 以满足 ≥44 触摸目标（控制行 80 → 88）；
      // v2.39.0 用户要求「功能栏太高、比例要改进」→ 两行各回 40（控制行 **80**），
      // 字幕悬浮基准改用 [kPlayerBottomBarHeight] 推导自动跟随（见 [_buildVideoLayers]
      // 字幕层的 bottom 取值与 [kPlayerBottomBarHeight] 注释）。底栏叠在视频区里，
      // 收矮只多露画面，不动视频区/评论区几何。
      // v2.17.0+：底部 SafeArea 只在全屏吃系统底 inset——非全屏（竖屏 /
      // 横屏置顶）时本行位于视频区黑盒底部（屏幕中部，不在屏底），系统
      // 导航条在屏幕最下方（横屏在侧边），不需也**不能**再垫底（否则按钮
      // 行上方悬空留黑）。
      child: SafeArea(
        top: false,
        bottom: _fullscreen,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 上下集行（v2.30.0+）：**仅在有播放列表时构建**——没有播放列表
            // 的入口（历史/搜索/信箱/评论跳转/收藏夹…）这里一个像素都不多，
            // 底栏与改动前逐像素一致。
            if (_hasPlaylistNeighbors) _buildPlaylistRow(),
            _buildSeekRow(),
            SizedBox(
              height: _kBottomButtonRowHeight,
              child: Row(
                children: [
                  // 选集按钮：仅多 P 显示（当前集 1/N），点按弹出选集列表。
                  // 非开关（导航动作）→ 恒定纸白，无「开启标记」短线。
                  if (_video.isMultiPage)
                    Expanded(
                      child: InkWell(
                        onTap: _player == null ? null : _showEpisodeSheet,
                        child: _barIconLabel(
                          icon: const Icon(Icons.queue_music,
                              color: kPlayerOn, size: 18),
                          label:
                              '选集 ${_currentPageIndex + 1}/${_video.pageCount}',
                          color: kPlayerOn,
                        ),
                      ),
                    ),
                  // 倍速按钮：显示当前档位，点按弹出九档选择。
                  // 非开关（档位由文字自明）→ 恒定纸白，无短线。
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _showSpeedSheet,
                      child: _barIconLabel(
                        icon: const Icon(Icons.speed,
                            color: kPlayerOn, size: 18),
                        label: _fmtSpeed(_speed),
                        color: kPlayerOn,
                      ),
                    ),
                  ),
                  // 听视频按钮：开关态「纸白 + 图标下方 2×10 纸白短线」
                  // （短线 = 颜色之外的第二状态载体，Android 无障碍规范：
                  // 不得只用颜色表达状态）
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _toggleListenMode,
                      child: _barIconLabel(
                        icon: _barToggleIcon(
                          _listenMode ? Icons.headset : Icons.headset_off,
                          on: _listenMode,
                        ),
                        label: _listenMode ? '听视频中' : '听视频',
                        color: _listenMode ? kPlayerOn : kPlayerOff,
                      ),
                    ),
                  ),
                  // 字幕按钮：开关态同上；点按弹出字幕设置（_showSubtitleSheet）
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _showSubtitleSheet,
                      child: _barIconLabel(
                        icon: _barToggleIcon(
                          _subtitleEnabled
                              ? Icons.subtitles
                              : Icons.subtitles_off,
                          on: _subtitleEnabled,
                        ),
                        label: _subtitleEnabled ? '字幕中' : '字幕',
                        color: _subtitleEnabled ? kPlayerOn : kPlayerOff,
                      ),
                    ),
                  ),
                  // 弹幕按钮：开关态同上。
                  // 点按 = 开关；长按 = 弹幕设置（屏蔽词/类型/透明度）。
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _toggleDanmaku,
                      onLongPress:
                          _player == null ? null : _showDanmakuSettings,
                      child: _barIconLabel(
                        icon: _barToggleIcon(
                          _danmakuEnabled
                              ? Icons.chat_bubble
                              : Icons.chat_bubble_outline,
                          on: _danmakuEnabled,
                        ),
                        label: '弹幕',
                        color: _danmakuEnabled ? kPlayerOn : kPlayerOff,
                      ),
                    ),
                  ),
                  // 评论按钮（v2.17.0+；v2.17.17 横屏置顶共用）：非全屏
                  // （竖屏/横屏置顶）= 滚动定位到下方内嵌评论区；
                  // 横屏全屏 = 打开原独立评论页（见 _onCommentsButtonTap）。
                  // 非开关 → 恒定纸白，无短线。
                  Expanded(
                    child: InkWell(
                      onTap: _player == null ? null : _onCommentsButtonTap,
                      child: _barIconLabel(
                        icon: const Icon(Icons.comment_outlined,
                            color: kPlayerOn, size: 18),
                        label: '评论',
                        color: kPlayerOn,
                      ),
                    ),
                  ),
                  // 下载按钮：未缓存「下载」/ 下载中进度环+百分比 / 已缓存「已缓存」
                  Expanded(child: _buildDownloadControl()),
                  // 全屏按钮（非开关动作；图标 20 与同级按钮对齐）
                  Expanded(
                    child: IconButton(
                      color: kPlayerOn,
                      iconSize: 18,
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

  /// 播放失败 / 需登录面板：墨黑半透明底（保留画面透出感）+ 纸白系内容。
  ///
  /// 点缀墨 [kInkClay] **只用在唯一「需要行动」的强调点**——「去登录」是
  /// 用户必须做点什么才能继续播放的动作；「重试」「返回」是可选/退路，保持
  /// 纸白描边，不抢焦点（点缀色不得多点开花）。
  Widget _buildErrorView() {
    return ColoredBox(
      // 覆盖在视频之上的错误面板：半透明墨黑底（保留画面透出感）
      color: kInkBlack.withValues(alpha: 0.87),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: kPlayerOnDim, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: kTypeTitleS.copyWith(color: kPlayerOn),
              ),
              const SizedBox(height: 20),
              if (_loginPrompt) ...[
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kInkClay,
                    foregroundColor: kPaper,
                  ),
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
                        foregroundColor: kPlayerOn,
                        side: const BorderSide(color: kPlayerOnDim),
                      ),
                      child: const Text('重试'),
                    ),
                    const SizedBox(width: 12),
                  ],
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kPlayerOn,
                      side: const BorderSide(color: kPlayerOnDim),
                    ),
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

/// 预览缩略图基准宽（逻辑像素）：非全屏（竖屏置顶 / 横屏置顶）与全屏两档。
///
/// 为什么非全屏要小：非全屏视频区只有 ~231dp 高（16:9 铺满 411dp 宽屏），
/// B 站式 ~90dp 高的预览框会吃掉半屏画面；120×67.5（16:9）压在控制行上方
/// 仍读得清，画面干扰最小。全屏空间充裕 → 放到 180×101。
const double kSeekPreviewThumbWCompact = 120;
const double kSeekPreviewThumbWFullscreen = 180;

/// 无缩略图时「时间气泡」的定位估算宽（**只用于横向夹取**，不参与绘制）：
/// 气泡实际宽度由文字决定（等宽数字 '12:34' 约 34px + 左右内边距 12）。
const double kSeekPreviewTimeBubbleW = 46;

/// 气泡底边距进度条行的间隙（dp）。
const double kSeekPreviewGap = 8;

/// 取帧时与「片尾」保持的安全距离（ms）。
///
/// 拖到最右端（目标 == 总时长）时，雪碧图给的末格实测是**纯黑**（B 站对
/// 「最后一帧」那一格没画面；同一视频拖到中间一切正常）。预览只是"顺手看一眼
/// 大概位置"，贴到片尾时回退这一小段，既避开末格、也不影响判断。
const int kSeekPreviewEndGuardMs = 1500;

/// 拖动预览浮层：缩略图（有帧时）+ 一行时间文字，压在进度条**上方**、
/// 水平跟随手指。整体 [IgnorePointer]——纯展示，绝不参与命中（拖动必须
/// 一路畅通）。
///
/// 摆放：[left] 由调用方按手指位置算好并夹在轨道内 → 这里只管落位；
/// 位置基准是**进度条自身的盒**（调用处把它直接放进进度条的 Stack），
/// `bottom = 进度条行高 + [kSeekPreviewGap]` 即「贴在进度条上方留 8dp」。
///
/// 降级：`frame == null`（服务未就绪 / prepare 失败 / 该格加载失败 / 轨道
/// 太窄放不下缩略图）时只画时间气泡——[bubbleWidth] 传 0 即此路，**任何
/// 情况下都至少给出时间信息**。
class _SeekPreviewOverlay extends StatelessWidget {
  /// 格式化后的时间（如 '12:34'）。
  final String timeLabel;

  /// 当前可画的帧（null → 只显示时间气泡）。
  final SeekPreviewFrame? frame;

  /// 气泡左边缘（已由调用方夹到不越界）。
  final double left;

  /// 缩略图宽（无缩略图时为 0）。
  final double bubbleWidth;

  const _SeekPreviewOverlay({
    super.key,
    required this.timeLabel,
    required this.frame,
    required this.left,
    required this.bubbleWidth,
  });

  @override
  Widget build(BuildContext context) {
    final image = frame;
    // 高按帧的真实宽高比折算（不拉伸变形）：srcRect 就是该格在雪碧图里的
    // 裁剪矩形，比例恒等于后端 xSize/ySize
    final thumbHeight = (image == null || image.srcRect.width <= 0)
        ? 0.0
        : bubbleWidth * image.srcRect.height / image.srcRect.width;
    return Positioned(
      left: left,
      bottom: _PlayerSeekBar.height + kSeekPreviewGap,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (image != null && bubbleWidth > 0 && thumbHeight > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusSm),
                child: CustomPaint(
                  key: const ValueKey('seek-preview-thumb'),
                  size: Size(bubbleWidth, thumbHeight),
                  painter: _SeekPreviewPainter(image),
                ),
              ),
              const SizedBox(height: 4),
            ],
            // 时间气泡：半透明黑底 + 等宽数字（与手势 seek 浮层同一墨）
            Container(
              key: const ValueKey('seek-preview-time'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kInkBlack.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(kRadiusSm),
              ),
              child:
                  Text(timeLabel, style: kTypeNum.copyWith(color: kPlayerOn)),
            ),
          ],
        ),
      ),
    );
  }
}

/// [_SeekPreviewOverlay] 的缩略图画笔：把雪碧图里的那一格裁到目标框 + 1px 描边。
///
/// 只做一次 `drawImageRect`（[SeekPreviewFrame] 自带裁剪矩形与降采样后的
/// 图），描边画在裁剪内（否则会被 ClipRRect 削掉一半）。**不缓存画布/画笔
/// 之外的东西**，也不持有 [SeekPreviewFrame.sprite]（图归服务层 LRU 管）。
class _SeekPreviewPainter extends CustomPainter {
  final SeekPreviewFrame frame;

  const _SeekPreviewPainter(this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(
      frame.sprite,
      frame.srcRect,
      Offset.zero & size,
      paint,
    );
    // 1px 白 24% 描边（kPlayerRule，与播放器导轨同墨）：画面什么颜色都有，
    // 需要一条边界把预览框从画面里拎出来；不抢画面所以不用实心白
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
        const Radius.circular(kRadiusSm),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = kPlayerRule,
    );
  }

  @override
  bool shouldRepaint(_SeekPreviewPainter old) => !identical(old.frame, frame);
}

/// 自绘播放进度条（P5）：2px 三段轨道 + 4×14 竖条拖动柄，替代原生
/// Material `Slider`。
///
/// 为什么自绘：Slider 在「有界高度」约束下会撑满整个高度（`_RenderSlider`
/// 布局取 `constraints.maxHeight`），两端还内建 24px 边距、柄为 20px 直径
/// 圆，细轨几何不可控；播放页要的是印刷语汇的「细轨 + 方柄 + 无阴影」。
///
/// 视觉三态（左→右）：未播 [kPlayerRule]（白 24%）→ 已缓冲 [kPlayerOnDim]
/// （白 54%）→ 已播 [kPlayerPaper]（纸白）；柄为 4×14 纸白竖条（「书签」
/// 而非圆点），仅控制层可见时显示（[showHandle]）。
///
/// 亮/暗双向可见（v2.17.18）：三态墨里只有已播/已缓冲/柄是「白系」，它们在
/// 浅色画面上靠底部黑色渐变（`_buildBottomBar` 的 black54 遮罩）压暗背景才
/// 显出来；未播档的 kPlayerRule 只有白 24%，压在**浅米色画面**上与背景同色
/// → 实测拖动后「柄右侧的未播轨道几乎消失」（看不出轨道走向）。修法：在整条
/// 轨道下方先铺一条同厚度（仍是 [trackThickness]=2，不加粗）的 [kInkBlack]
/// 70% 暗垫，再画三态——未播段变成「白 24% 压在暗垫上」的复合灰，浅色画面
/// 上对比度 ≈3:1 可见，深色画面上暗垫融入背景、白 24% 照旧发亮；已播段与柄
/// 是**不透明纸白**，压在暗垫上完全不受影响，层级仍是「已播 + 柄 ＞ 未播」。
///
/// 触摸目标：整条 [height]=40 高、整宽都是命中区（`HitTestBehavior.opaque`），
/// 比原生 Slider 的 2px 细轨好按得多。**取 40 而不是 44（Android 规范的 ≥48
/// 更达不到）**：v2.39.0 用户要求「功能栏太高、比例要改进」，底栏两行各收 4dp
/// 一共让出 8dp 画面（底栏叠在视频区里，收矮 = 多露画面）；这一行的命中判断
/// 只用到 dx（dy 不参与取值），竖向容差损失在实际操作里不可感，而水平方向上
/// 仍有 300+dp 的通宽 —— 收益（8dp 画面）大于代价（4dp 竖向命中带）。
///
/// 回调语义与 Slider 一一对应：[onDrag] = `onChanged`（拖动/点按过程持续
/// 回调，播放页只更新 UI 位置）、[onDragEnd] = `onChangeEnd`（松手/抬手
/// 提交 `seekTo`）。播放页传入 [_PlayerPageState._onSeekStart] /
/// [_PlayerPageState._onSeekEnd]，**播放行为零改动**。
///
/// [onDragPosition] 是**唯一的额外回调**（拖动预览浮层定位用）：把「手指在
/// 轨道上的水平位置」原样带出去——拖动开始/更新与抬手点按都会回报，其中
/// 拖动起手那一次**先于** [onDrag] 发出（预览据此判定「本轮拖动起手」）。
/// 它不参与取值与提交，纯粹是几何信息，不改变上两个回调的语义与时机。
class _PlayerSeekBar extends StatelessWidget {
  /// 已播位置（ms）。
  final int positionMs;

  /// 总时长（ms）；<= 0 视为时长未知 → 不可拖（只画未播轨道）。
  final int durationMs;

  /// 已缓冲位置（ms）；null / <= 0 = 无缓冲信息 → 不画缓冲段。
  ///
  /// 现状：播放页传 null——原生层未上报缓冲进度（[BiliDashEvent] 只有
  /// prepared / completed / error / urlExpired 四类事件，没有缓冲事件），
  /// 不伪造数据、不假装有缓冲段。轨道中段这一档画法已就绪，原生侧将来
  /// 补 `onBufferUpdate` 时在调用处传值即可点亮。
  final int? bufferedMs;

  /// 是否显示拖动柄（控制层可见时显示；隐藏时只留轨道）。
  final bool showHandle;

  /// 拖动/点按中回调（Slider.onChanged 语义）。
  final ValueChanged<double>? onDrag;

  /// 松手/抬手回调（Slider.onChangeEnd 语义）。
  final ValueChanged<double>? onDragEnd;

  /// 拖动中回报「手指在轨道的哪个水平位置」——用于精确摆放预览气泡。
  ///
  /// [dragX] 是相对于轨道可用宽度的像素偏移（0..trackWidth，即
  /// [_PlayerSeekBar] 自身盒宽），[trackWidth] 是可用宽度。**不夹取**：
  /// 越界（手指滑出轨道）时原样回报，由调用方决定怎么摆。
  final void Function(double dragX, double trackWidth)? onDragPosition;

  const _PlayerSeekBar({
    super.key,
    required this.positionMs,
    required this.durationMs,
    required this.showHandle,
    this.bufferedMs,
    this.onDrag,
    this.onDragEnd,
    this.onDragPosition,
  });

  /// 触摸目标高度（与 [_PlayerPageState._buildBottomBar] 的进度条行一致）。
  ///
  /// 44 → **40**（v2.39.0，见 [_PlayerPageState._kBottomButtonRowHeight] 的
  /// 取值理由）：这一行是**整条轨道通宽**的可点/可拖面（`HitTestBehavior.opaque`
  /// 铺满 40 高），水平方向 300+dp，垂直方向收 4dp 后横向拖动的跟手区域不变
  /// ——真正要求 ≥44 的场景是「点一下定位」的竖向容差，而这里点按与拖动都
  /// 落在同一条 2px 细轨的**放大命中带**上（本组件自己按 dx 取值，dy 不参与），
  /// 收矮不改变命中语义。旧注解里「44 是为满足 Android ≥44 触摸目标」的说法
  /// 在 v2.39.0 按「改矮 8dp 让出画面」的用户诉求重新权衡后不再成立，如实更新。
  static const double height = 40;

  /// 轨道粗细（px）。
  static const double trackThickness = 2;

  /// 拖动柄宽 / 高（px）。
  static const double handleWidth = 4;
  static const double handleHeight = 14;

  @override
  Widget build(BuildContext context) {
    final max = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final draggable = durationMs > 0 && onDrag != null && onDragEnd != null;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, c) {
          final width = c.maxWidth;
          // 命中点 dx → 目标时长：轨道左右各内缩半个柄宽（柄在任何位置都
          // 完整落在画布内），故比例按 (width - handleWidth) 折算
          double valueAt(double dx) {
            final span = width - handleWidth;
            if (span <= 0) return 0;
            return ((dx - handleWidth / 2) / span).clamp(0.0, 1.0) * max;
          }

          // 预览浮层定位用的几何回报（与 [valueAt] 同一套坐标：轨道两端各
          // 内缩 handleWidth/2，dx 未夹取，越界原样带出）
          void reportAt(double dx) => onDragPosition?.call(dx, width);

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 手势集刻意只有两种，且**不注册 onTapDown**：
            // - 点按：抬手（onTapUp）一次性「定位并提交」，等价 Slider 的
            //   tap-to-seek；
            // - 拖动：start/update 持续回调（拇指跟手）、end 提交。
            // 不注册 onTapDown 的原因：按下超过 100ms 时 Tap 识别器会先触发
            // onTapDown，随后若横向位移超 slop 则由 HorizontalDrag 赢走竞技场
            // （onTapUp 不再触发，只发 onTapCancel，而这里没有 onTapCancel
            // 回调）——那会让播放页的 _dragging 停在 true、tick 循环永久
            // 停摆。只在抬手/松手提交，就没有任何「开了收不住」的路径。
            onTapUp: draggable
                ? (d) {
                    // 先回报位置再提交：预览浮层只见于拖动（_dragging），
                    // 点按这条路上的回报只是保持几何信息一致
                    reportAt(d.localPosition.dx);
                    onDragEnd!(valueAt(d.localPosition.dx));
                  }
                : null,
            onHorizontalDragStart: draggable
                ? (d) {
                    reportAt(d.localPosition.dx);
                    onDrag!(valueAt(d.localPosition.dx));
                  }
                : null,
            onHorizontalDragUpdate: draggable
                ? (d) {
                    reportAt(d.localPosition.dx);
                    onDrag!(valueAt(d.localPosition.dx));
                  }
                : null,
            onHorizontalDragEnd: draggable
                ? (d) => onDragEnd!(valueAt(d.localPosition.dx))
                : null,
            child: CustomPaint(
              size: Size(width, height),
              painter: _SeekBarPainter(
                progress: durationMs > 0 ? positionMs / max : 0,
                buffered: (bufferedMs == null || durationMs <= 0)
                    ? 0
                    : bufferedMs! / max,
                showHandle: showHandle,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// [_PlayerSeekBar] 的画笔：三段细轨（未播 / 已缓冲 / 已播）+ 竖条柄。
/// 只有矩形描边式色块，无阴影、无圆角装饰（印刷语汇）。
class _SeekBarPainter extends CustomPainter {
  /// 已播比例 0..1。
  final double progress;

  /// 已缓冲比例 0..1；<= 0 时不画（不伪造缓冲进度）。
  final double buffered;

  final bool showHandle;

  const _SeekBarPainter({
    required this.progress,
    required this.buffered,
    required this.showHandle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final left = _PlayerSeekBar.handleWidth / 2;
    final right = size.width - _PlayerSeekBar.handleWidth / 2;
    final span = right - left;
    if (span <= 0) return;

    final ink = Paint()..style = PaintingStyle.fill;
    final trackTop = cy - _PlayerSeekBar.trackThickness / 2;
    final track = Rect.fromLTWH(
        left, trackTop, span, _PlayerSeekBar.trackThickness);

    // 暗垫（v2.17.18）：整条轨道先铺一层 kInkBlack 70% 的**同厚度**底——
    // 只垫底不加粗（保持 2px 细轨印刷感），让未播档在浅色画面上也有对比。
    canvas.drawRect(track, ink..color = kInkBlack.withValues(alpha: 0.7));

    // 未播段（整条轨道底）
    canvas.drawRect(track, ink..color = kPlayerRule);

    // 已缓冲段（有缓冲信息才画；无信息时轨道中段不出现第三种墨）
    if (buffered > 0) {
      final w = span * buffered.clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromLTWH(left, trackTop, w, _PlayerSeekBar.trackThickness),
        ink..color = kPlayerOnDim,
      );
    }

    // 已播段
    final playedW = span * progress.clamp(0.0, 1.0);
    canvas.drawRect(
      Rect.fromLTWH(left, trackTop, playedW, _PlayerSeekBar.trackThickness),
      ink..color = kPlayerPaper,
    );

    // 拖动柄：4×14 纸白竖条，仅在控制层可见时出现
    if (showHandle) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(left + playedW, cy),
          width: _PlayerSeekBar.handleWidth,
          height: _PlayerSeekBar.handleHeight,
        ),
        ink..color = kPlayerPaper,
      );
    }
  }

  @override
  bool shouldRepaint(_SeekBarPainter old) =>
      old.progress != progress ||
      old.buffered != buffered ||
      old.showHandle != showHandle;
}

/// 登录即将过期 / 未登录匿名横幅（点按跳登录页；未登录文案见播放页
/// [_PlayerPageState._kAnonymousBannerText]）。
class _LoginExpiryBanner extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _LoginExpiryBanner({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      // 登录即将过期 / 未登录匿名横幅：点缀墨职责——「时效性提示」，用
      // kInkClayWash 底 + kInkClay 字（浅底上的赤陶，对比度足够且不与视频
      // 黑底混同；旧的「墨底纸字」在此场景看不见，横幅本就压在视频上）
      color: kInkClayWash,
      child: InkWell(
        onTap: onTap,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: kInkClay, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: kTypeBodyS.copyWith(color: kInkClay),
                  ),
                ),
                const Icon(Icons.chevron_right, color: kInkClay),
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
        // 字幕小药丸：半透明墨黑底（画面透出）+ 纸白字
        color: kInkBlack.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: kPlayerOn,
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

/// 一个写操作按钮（点赞 / 投币 / 收藏）：小图标 + 词 + 可选计数。
///
/// 为什么做成"图标 + 词"而不是纯图标：这三个动作都**不可逆或代价高**，
/// 认错图标（尤其 `monetization_on` 与 `star`）的代价比多占一点宽度大得多。
/// 高度压到一行（最小点击高度 32dp）：信息块每多一行都从评论区抢地方。
/// [onTap] 为 null = 正在发写请求（三个按钮一起置灰，见 `_writeBusy`）。
class _WriteActionChip extends StatelessWidget {
  final IconData icon;
  final String label;

  /// 计数（0 = 不显示数字，只显示词——避免"点赞 0"这种噪音）。
  final int count;

  /// 是否处于"已做"态（主色 + 实心图标）。
  final bool active;

  /// 主色（从宿主 theme 传进来，避免每个 chip 各自查一次 Theme）。
  final Color accent;

  final VoidCallback? onTap;

  const _WriteActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled
        ? kInkGray30
        : (active ? accent : kInkGray70);
    return Semantics(
      button: true,
      enabled: !disabled,
      selected: active,
      label: count > 0 ? '$label $count' : label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(
                count > 0 ? '$label ${_fmtWriteCount(count)}' : label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 收藏夹选择弹层（收藏 / 取消收藏共用）。
///
/// - [removing] = true：标题写成「取消收藏」，选中某个夹 = **从该夹移除**
///   （B 站按夹删，同一条视频在多个夹里时只影响选中的那个）；
/// - [lastFid]：上次选过的夹（[UiPrefsStore.favFolderId]）——**排到第一个并
///   标「上次」**，让"再收一遍到老地方"是一下点击；
/// - 取消返回 null（调用方据此不发任何请求）。
class _FavFolderSheet extends StatelessWidget {
  final List<FavoriteFolder> folders;
  final bool removing;
  final int? lastFid;

  const _FavFolderSheet({
    required this.folders,
    required this.removing,
    required this.lastFid,
  });

  @override
  Widget build(BuildContext context) {
    // 上次选过的夹提到最前（其余保持接口顺序，便于用户按熟悉的位置找）
    final ordered = [
      for (final f in folders)
        if (lastFid != null && f.mediaId == lastFid) f,
      for (final f in folders)
        if (lastFid == null || f.mediaId != lastFid) f,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: Text(
            removing ? '从哪个收藏夹移除' : '收藏到',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: kInkGray70),
          ),
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: ordered.length,
            itemBuilder: (context, i) {
              final f = ordered[i];
              final isLast = lastFid != null && f.mediaId == lastFid;
              return ListTile(
                key: ValueKey('fav-folder-${f.mediaId}'),
                dense: true,
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        f.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isLast) ...[
                      const SizedBox(width: 6),
                      Text('上次',
                          style: TextStyle(fontSize: 11, color: kInkGray50)),
                    ],
                  ],
                ),
                subtitle: Text('${f.mediaCount} 个内容',
                    style: const TextStyle(fontSize: 11.5)),
                onTap: () => Navigator.of(context).pop(f),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 计数格式化（点赞数）：<1 万原样；≥1 万 → `1.2万`；≥1 亿 → `1.2亿`。
///
/// 与列表卡/专栏页的 `fmtArticleCount` 同一套口径，但**不复用它**：
/// 那是 `article_page.dart` 的顶层函数，播放页 import 页面文件只为一个小函数
/// 会让依赖方向变怪（页面之间互相 import 也是这个项目一直在避免的）。
String _fmtWriteCount(int n) {
  if (n < 10000) return '$n';
  if (n < 100000000) {
    final v = n / 10000;
    final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${s.replaceAll(RegExp(r'\.0$'), '')}万';
  }
  final v = n / 100000000;
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${s.replaceAll(RegExp(r'\.0$'), '')}亿';
}
