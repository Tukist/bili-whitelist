/// 播放页弹幕渲染层：随时间发射弹幕并在视频画面上滚动/停留。
///
/// 设计要点（编码员权衡）：
/// - **驱动**：内部 Ticker 每帧推进（60fps 平滑滚动）。父层每 500ms 轮询
///   getPosition 后把最新 [positionMs] 传进来（复用字幕进度节奏，弹幕发射
///   粒度 500ms 足够）。只有弹幕层存在（开启且有数据）才运行，关闭时
///   整个 widget 不构建 → 无任何开销。
/// - **发射**：弹幕全量按时间升序，维护发射游标，`timeSec <= pos` 的逐条
///   进入活跃列表；播放暂停（playing=false）时不推进不发射（弹幕冻结）。
/// - **运动**：滚动弹幕从右往左匀速移动，总穿越时长固定（约 5s，折算
///   120~300px/s 视屏宽与文本宽而定）；到达左缘（文本尾部出屏）移除。
///   顶部/底部弹幕居中停留 3.5s 后消失。
/// - **分层**：简化实现——不逐条做碰撞检测，而是把弹幕区按行高切成多条
///   横向轨道，发射时轨道号 round-robin 轮转。同屏弹幕均匀分布在轨道上，
///   只有轨道数被打满时才会偶发叠字，视觉可接受且无碰撞计算成本。
/// - **绘制**：CustomPaint + 缓存 TextPainter（发射时 layout 一次，每帧只
///   paint），避免每帧重建排版；文本带黑色阴影保证白/亮弹幕可读。
/// - 切集/seek/恢复进度：父层换新数据实例 → 从头发射；播放位置发生 >3s
///   的跳变（seek/恢复记忆）→ 本层清空活跃并把发射游标跳到新位置，不再
///   补发已跳过的弹幕（跳变检测在 didUpdateWidget，父层无需额外通知）。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../models/danmaku.dart';

/// 滚动弹幕从出现到完全出左屏的总时长（秒）。
const double kDanmakuTravelSec = 5.0;

/// 顶部/底部弹幕停留时长（秒）。
const double kDanmakuStaySec = 3.5;

/// 一条正在屏幕上运动的弹幕。
class _ActiveDanmaku {
  final Danmaku danmaku;

  /// 已 layout 的文本（发射时排版一次，之后每帧只 paint）。
  final TextPainter painter;

  /// 当前横向偏移（滚动弹幕：右缘起点 x=屏宽，递减到 -textW 移除；
  /// 顶部/底部弹幕：x 为居中的左缘，不移动）。
  double x;

  /// 所处轨道（已换算为顶部 y 坐标；滚动/顶部弹幕 y 固定）。
  final double y;

  /// 滚动弹幕速度 px/s（向右为负）。
  final double vx;

  /// 顶部/底部弹幕剩余停留秒数（滚动弹幕恒 0）。
  double lifeLeft;

  _ActiveDanmaku({
    required this.danmaku,
    required this.painter,
    required this.x,
    required this.y,
    this.vx = 0,
    this.lifeLeft = 0,
  });

  /// 是否已移出屏幕左缘（文本尾部出屏）。
  bool get scrolledOff => danmaku.isScroll && x <= -painter.width;

  /// 是否停留时间到（顶部/底部）。
  bool get stayOver => !danmaku.isScroll && lifeLeft <= 0;

  void dispose() => painter.dispose();
}

/// 弹幕渲染层 widget（父层负责开启时才构建）。
class DanmakuOverlay extends StatefulWidget {
  /// 当前视频全量弹幕（**已按 timeSec 升序**，切集时父层换新 List 实例）。
  final List<Danmaku> danmaku;

  /// 是否播放中（false=暂停，冻结弹幕不推进）。
  final bool playing;

  /// 最新播放位置（毫秒，父层 500ms 轮询刷新）。
  final int positionMs;

  const DanmakuOverlay({
    super.key,
    required this.danmaku,
    required this.playing,
    required this.positionMs,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  /// 已发射但还在屏幕上的弹幕。
  final List<_ActiveDanmaku> _active = [];

  /// 发射游标：danmaku 列表中下一个待发射下标。
  int _cursor = 0;

  /// 上一次父层传入的播放位置（用于检测 seek/恢复进度的跳变）。
  int _lastPosMs = 0;

  /// 累计发射计数与上次日志时刻（每 ~2s debugPrint 一次活动，供实测佐证）。
  int _spawnCount = 0;
  int _lastLogSec = 0;

  /// 轨道布局待重算标记：首次/切集/旋转全屏后置 true，_onTick 发射前检查。
  bool _needRelayout = true;

  // 轨道布局（首次 layout 时按屏尺寸计算一次，旋转/全屏切换父层会带尺寸
  // 变化 → 用 _needRelayout 检测是否需要重算轨道参数）。
  double _laneH = 26; // 单轨道行高（px）
  int _scrollLanes = 6; // 滚动 + 顶部共用轨道数
  int _laneCursor = 0; // 滚动/顶部轨道轮转指针
  int _topCursor = 0; // 顶部弹幕轨道（从顶部轨道池轮转）
  final int _bottomLanes = 2; // 底部弹幕保留轨道数
  int _bottomCursor = 0;

  @override
  void initState() {
    super.initState();
    _lastPosMs = widget.positionMs;
    _ticker = createTicker(_onTick)..start();
    _reset(rewindToCurrent: false);
  }

  @override
  void didUpdateWidget(DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切集：新数据实例（identity 不同）→ 从头发射
    if (!identical(oldWidget.danmaku, widget.danmaku)) {
      _reset(rewindToCurrent: false);
      _needRelayout = true;
      _lastPosMs = widget.positionMs;
      return;
    }
    // seek / 恢复进度等位置大跳变（>3s）：清活跃 + 游标跳到当前时间点，
    // 不补发已跳过的弹幕；普通播放推进（两帧差 <=500ms）不受影响。
    final delta = (widget.positionMs - _lastPosMs).abs();
    if (delta > 3000) {
      _reset(rewindToCurrent: true);
    }
    _lastPosMs = widget.positionMs;
  }

  /// 清空活跃弹幕（并释放 TextPainter）；[rewindToCurrent] 为 true 时把
  /// 发射游标推进到 `>= 当前播放位置` 的第一条（seek 前进跳过后不补发）。
  void _reset({required bool rewindToCurrent}) {
    for (final a in _active) {
      a.dispose();
    }
    _active.clear();
    if (!rewindToCurrent) {
      _cursor = 0;
    } else {
      final list = widget.danmaku;
      final posSec = widget.positionMs / 1000.0;
      var i = _cursor;
      // 游标只前进（seek 前进场景）；seek 后退同样适用：清空后从首个
      // timeSec > pos 的弹幕开始，防止补发已看过的
      while (i < list.length && list[i].timeSec <= posSec) {
        i++;
      }
      _cursor = i;
    }
  }

  /// 屏幕尺寸变化（旋转/全屏）后重算轨道参数。
  void _ensureLayout(Size size) {
    if (!_needRelayout) return;
    _needRelayout = false;
    final h = size.height;
    _laneH = danmakuDisplayFontSize(25) * 1.6; // 轨道行高：普通字号行高+余量
    final usableH = h * 0.7; // 弹幕区占屏高 70%（避开顶/底控制带）
    final total = (usableH / _laneH).floor().clamp(4, 60);
    _scrollLanes = total - _bottomLanes;
    _laneCursor = 0;
    _topCursor = 0;
    _bottomCursor = 0;
  }

  double _topInset(Size size) => size.height * 0.12;

  /// 取滚动/顶部弹幕的轨道 y（自顶部弹幕区起 round-robin）。
  double _nextScrollLaneY(Size size, {required bool top}) {
    // 顶部弹幕只在顶部少量轨道内轮转，滚动弹幕用全部滚动轨道
    final usable = top ? (_scrollLanes < 3 ? _scrollLanes : 3) : _scrollLanes;
    final lane = top ? (_topCursor++ % usable) : (_laneCursor++ % usable);
    return _topInset(size) + lane * _laneH;
  }

  double _nextBottomLaneY(Size size) {
    final lane = _bottomCursor++ % _bottomLanes;
    // 底部弹幕区：从弹幕带底部往上排（屏幕 82% 起向下铺 lane）
    return size.height * 0.82 + lane * _laneH;
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (!widget.playing) return; // 暂停：冻结弹幕（dt 不累计）
    if (widget.danmaku.isEmpty && _active.isEmpty) return;

    // 1) 推进已有活跃弹幕
    var changed = false;
    for (final a in _active) {
      if (a.danmaku.isScroll) {
        a.x += a.vx * dt; // vx 为负：向左
      } else {
        a.lifeLeft -= dt;
      }
    }
    _active.removeWhere((a) {
      final gone = a.scrolledOff || a.stayOver;
      if (gone) {
        a.dispose();
        changed = true;
      }
      return gone;
    });

    // 2) 发射 timeSec <= 当前播放位置的弹幕
    final list = widget.danmaku;
    final posSec = widget.positionMs / 1000.0;
    if (_cursor < list.length) {
      final size = context.size ?? Size.zero;
      if (size == Size.zero) return;
      _ensureLayout(size);
      while (_cursor < list.length && list[_cursor].timeSec <= posSec) {
        _spawn(list[_cursor], size);
        _cursor++;
        changed = true;
      }
    }
    if (changed) setState(() {});
    // 弹幕活动日志（每 ~2s 一次，供模拟器 logcat 实测佐证渲染层在发射）
    if (_spawnCount > 0 && elapsed.inSeconds - _lastLogSec >= 2) {
      _lastLogSec = elapsed.inSeconds;
      debugPrint('[danmaku] 发射累计 $_spawnCount 条 · 屏幕活跃 '
          '${_active.length} 条 pos=${widget.positionMs}ms '
          'cursor=$_cursor/${widget.danmaku.length}');
    }
  }

  void _spawn(Danmaku d, Size size) {
    final fontSize = danmakuDisplayFontSize(d.fontSize).toDouble();
    final painter = TextPainter(
      text: TextSpan(
        text: d.text,
        style: TextStyle(
          fontSize: fontSize,
          color: Color(d.color),
          fontWeight: FontWeight.w600,
          // 黑色阴影描边：白/亮弹幕在浅色画面也可读
          shadows: const [
            ui.Shadow(color: Colors.black, offset: ui.Offset(1, 1)),
            ui.Shadow(color: Colors.black, offset: ui.Offset(-1, -1)),
            ui.Shadow(color: Colors.black, offset: ui.Offset(-1, 1)),
            ui.Shadow(color: Colors.black, offset: ui.Offset(1, -1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final textW = painter.width;

    if (d.isBottom) {
      final y = _nextBottomLaneY(size);
      // 底部弹幕：居中，x 为文本左缘
      final x = (size.width - textW) / 2;
      _active.add(_ActiveDanmaku(
        danmaku: d,
        painter: painter,
        x: x,
        y: y,
        lifeLeft: kDanmakuStaySec,
      ));
    } else if (d.isTop) {
      final y = _nextScrollLaneY(size, top: true);
      final x = (size.width - textW) / 2;
      _active.add(_ActiveDanmaku(
        danmaku: d,
        painter: painter,
        x: x,
        y: y,
        lifeLeft: kDanmakuStaySec,
      ));
    } else {
      // 滚动：从右缘外入场，5s 内穿越整屏
      final y = _nextScrollLaneY(size, top: false);
      final distance = size.width + textW;
      final vx = -distance / kDanmakuTravelSec;
      _active.add(_ActiveDanmaku(
        danmaku: d,
        painter: painter,
        x: size.width + 10, // 完全在右缘外起跑，避免入场瞬间跳入
        y: y,
        vx: vx,
      ));
    }
    _spawnCount++;
    // 溢出保护：异常密集（如批量时间点重合）时丢弃最早进入的滚动弹幕，
    // 防止单帧文本绘制过多掉帧；顶部/底部停留短、数量少，保留不丢。
    if (_active.length > 80) {
      var drop = _active.length - 60;
      for (var i = 0; i < _active.length && drop > 0;) {
        if (_active[i].danmaku.isScroll) {
          _active[i].dispose();
          _active.removeAt(i);
          drop--;
        } else {
          i++;
        }
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    for (final a in _active) {
      a.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _DanmakuPainter(_active),
    );
  }
}

/// 绘制活跃弹幕（每帧 paint 时把缓存的 TextPainter 画到对应坐标）。
class _DanmakuPainter extends CustomPainter {
  final List<_ActiveDanmaku> active;

  _DanmakuPainter(this.active);

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in active) {
      a.painter.paint(canvas, ui.Offset(a.x, a.y));
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) => true;
}
