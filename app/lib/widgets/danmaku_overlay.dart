/// 播放页弹幕渲染层：随时间发射弹幕并在视频画面上滚动/停留。
///
/// 设计要点（编码员权衡，v2.16.3 → v2.16.6 演进）：
/// - **驱动**：内部 Ticker 每帧推进（60fps 平滑滚动）。父层每 500ms 轮询
///   getPosition 后把最新 [positionMs] 传进来（复用字幕进度节奏，弹幕发射
///   粒度 500ms 足够）。只有弹幕层存在（开启且有数据）才运行，关闭时
///   整个 widget 不构建 → 无任何开销。
/// - **平滑（v2.16.6）**：位置推进严格按帧间时间差 dt（浮点秒）驱动，
///   dt 钳制在 [maxDtSec] 内——掉帧/卡顿时弹幕不跳变（大步长会显得"生硬"），
///   只按真实流逝时间缓慢追平。发射循环每帧有预算上限，密集弹幕分散到
///   后续帧逐个进入（避免单帧集中布局 TextPainter 掉帧）。滚动弹幕尾缘
///   被屏幕左缘裁剪消失、右缘屏外入场，天然无闪烁。
/// - **真碰撞分层（v2.16.6）**：不再 round-robin，改用 [DanmakuLanes]
///   轨道分配器——滚动弹幕每条轨道只记录"最后一条"的尾缘/速率，新弹幕
///   按追尾时间判定（O(1)），同轨追不上才进入；轨道全忙 → 丢弃（计丢弃
///   数）。顶部/底部各自维护纵向行堆叠（停留期间占行，取最上空闲行），
///   行全忙 → 丢弃。高密度下优先不叠字（宁可丢几条）。
/// - **屏蔽（v2.16.6）**：发射前按 [settings] 过滤（屏蔽词 substring /
///   屏蔽类型）；设置变更（新实例）→ 清活跃并按当前播放位置重载，即时生效。
/// - **透明度（v2.16.6）**：[settings.opacity]（20%~100%）乘到绘制 alpha；
///   顶部/底部弹幕带 0.15s 淡入 + 0.4s 淡出（透明度为 1 时零额外开销）。
/// - **绘制**：CustomPaint + 缓存 TextPainter（发射时 layout 一次，每帧只
///   paint），避免每帧重建排版；文本带黑色阴影保证白/亮弹幕可读。
/// - 切集/seek/恢复进度：父层换新数据实例 → 从头发射；播放位置发生 >3s
///   的跳变（seek/恢复记忆）→ 本层清空活跃并把发射游标跳到新位置，不再
///   补发已跳过的弹幕（跳变检测在 didUpdateWidget，父层无需额外通知）。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../models/danmaku.dart';
import '../models/danmaku_lanes.dart';
import '../models/danmaku_settings.dart';

/// 滚动弹幕从出现到完全出左屏的总时长（秒）——可按观感调整（可配置点）。
/// v2.16.6 由 5.0 收紧到 4.0：原 5s 视觉偏"拖"，调快后更接近 B 站节奏。
const double kDanmakuTravelSec = 4.0;

/// 顶部/底部弹幕停留时长（秒）。
const double kDanmakuStaySec = 3.5;

/// 顶部/底部弹幕淡入时长（秒）。
const double kDanmakuFadeInSec = 0.15;

/// 顶部/底部弹幕淡出时长（秒，临近停留结束时渐变透明）。
const double kDanmakuFadeOutSec = 0.4;

/// 单帧 dt 钳制上限（秒）：掉帧超过该值不跳位置，按上限推进平滑恢复。
const double kMaxDanmakuDtSec = 0.05;

/// 弹幕区占屏高比例（顶部 12% 起、底部控制带前止，见 _ensureLayout）。
const double _topAreaRatio = 0.12;
const double _usableAreaRatio = 0.7;
const double _bottomAreaRatio = 0.82;

/// 顶部/底部弹幕各自保留的行数（纵向堆叠层数）。
const int _topLaneCount = 3;
const int _bottomLaneCount = 2;

/// 单帧发射预算：密集弹幕（时间点重合/轮询补齐）分散到后续帧逐个进入，
/// 避免单帧集中 layout 文本掉帧（帧率稳定的关键）。
const int _maxSpawnPerFrame = 12;

/// 屏幕活跃弹幕上限（溢出保护：再密也只保留这么多，防极端数据掉帧）。
const int _maxActiveCount = 80;
const int _trimActiveCount = 60;

/// 一条正在屏幕上运动的弹幕。
class _ActiveDanmaku {
  final Danmaku danmaku;

  /// 已 layout 的文本（发射时排版一次，之后每帧只 paint）。
  final TextPainter painter;

  /// 当前横向偏移（滚动弹幕：右缘起点 x=屏宽+间隙，递减到 -textW 移除；
  /// 顶部/底部弹幕：x 为居中的左缘，不移动）。
  double x;

  /// 所处轨道（已换算为顶部 y 坐标；滚动/顶部弹幕 y 固定）。
  final double y;

  /// 滚动弹幕速度 px/s（向左为负；滚动弹幕才用）。
  final double vx;

  /// 滚动弹幕速率（正数，供轨道分配器登记；滚动弹幕才用）。
  final double speed;

  /// 顶部/底部弹幕剩余停留秒数（滚动弹幕恒 0）。
  double lifeLeft;

  _ActiveDanmaku({
    required this.danmaku,
    required this.painter,
    required this.x,
    required this.y,
    this.vx = 0,
    this.speed = 0,
    this.lifeLeft = 0,
  });

  /// 是否已移出屏幕左缘（文本尾部出屏）。
  bool get scrolledOff => danmaku.isScroll && x <= -painter.width;

  /// 是否停留时间到（顶部/底部）。
  bool get stayOver => !danmaku.isScroll && lifeLeft <= 0;

  /// 顶部/底部淡入淡出系数：出现 0.15s 渐显、结束前 0.4s 渐隐。
  /// 滚动弹幕恒 1（由屏幕边缘裁剪自然进出，无需淡变）。
  double get stayFadeAlpha {
    if (danmaku.isScroll) return 1;
    final stayed = kDanmakuStaySec - lifeLeft;
    final fadeIn = (stayed / kDanmakuFadeInSec).clamp(0.0, 1.0);
    final fadeOut = lifeLeft < kDanmakuFadeOutSec
        ? (lifeLeft / kDanmakuFadeOutSec).clamp(0.0, 1.0)
        : 1.0;
    return math.min(fadeIn, fadeOut);
  }

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

  /// 弹幕显示设置（屏蔽词/屏蔽类型/透明度）。设置值变化 → 父层传**新实例**
  /// （copyWith），本层感知后清活跃按当前位置重载（即时生效）。
  final DanmakuSettings settings;

  const DanmakuOverlay({
    super.key,
    required this.danmaku,
    required this.playing,
    required this.positionMs,
    this.settings = const DanmakuSettings(),
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

  /// 统计（供 debugPrint 周期日志与模拟器 logcat 实测佐证）。
  int _spawnCount = 0; // 实际发射条数
  int _blockedCount = 0; // 被屏蔽条数（词/类型）
  int _lastLogSec = 0;

  /// 轨道分配器（布局时按屏尺寸创建）。
  DanmakuLanes? _lanes;

  /// 轨道布局待重算标记：首次/切集/旋转全屏后置 true，_onTick 发射前检查。
  bool _needRelayout = true;

  // 布局参数（首次 layout 时按屏尺寸计算一次，旋转/全屏切换会带尺寸
  // 变化 → 用 _needRelayout 检测是否需要重算）。
  double _laneH = 27; // 单轨道行高（px）
  double _topY0 = 0; // 顶部弹幕区起始 y（滚动轨道区上界）
  double _scrollY0 = 0; // 滚动轨道区起始 y
  double _bottomY0 = 0; // 底部弹幕区起始 y
  Size? _layoutSize; // 最近一次布局的尺寸（build 时发现变化 → 置重算标记）

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
    // 设置变化（父层改动屏蔽词/屏蔽类型/透明度 → copyWith 新实例）：
    // 清活跃 + 按当前播放位置重载，让屏蔽即时生效（在屏残留立即移除，
    // 且不重放已播弹幕——游标维持当前位置不动）。
    if (!identical(oldWidget.settings, widget.settings)) {
      debugPrint('[danmaku] 设置变更 -> ${widget.settings}，清屏重载');
      _reset(rewindToCurrent: true);
      _lastPosMs = widget.positionMs;
    } else {
      // seek / 恢复进度等位置大跳变（>3s）：清活跃 + 游标跳到当前时间点，
      // 不补发已跳过的弹幕；普通播放推进（两帧差 <=500ms）不受影响。
      final delta = (widget.positionMs - _lastPosMs).abs();
      if (delta > 3000) {
        _reset(rewindToCurrent: true);
      }
      _lastPosMs = widget.positionMs;
    }
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

  /// 屏幕尺寸变化（旋转/全屏）后重算布局与轨道分配器。
  void _ensureLayout(Size size) {
    if (!_needRelayout) return;
    _needRelayout = false;
    final w = size.width;
    final h = size.height;
    _laneH = danmakuDisplayFontSize(25) * 1.6; // 行高：普通字号行高+余量
    // 弹幕可用带占屏高 70%（顶部 12% 控制带之下起）；总行 = 顶 + 滚 + 底
    final total = ((h * _usableAreaRatio) / _laneH)
        .floor()
        .clamp(_topLaneCount + _bottomLaneCount + 1, 60);
    final scrollLanes = total - _topLaneCount - _bottomLaneCount;
    _topY0 = h * _topAreaRatio;
    _scrollY0 = _topY0 + _topLaneCount * _laneH;
    _bottomY0 = h * _bottomAreaRatio;
    _lanes = DanmakuLanes(
      screenWidth: w,
      entryGap: 10,
      scrollLanes: scrollLanes,
      topLanes: _topLaneCount,
      bottomLanes: _bottomLaneCount,
      staySec: kDanmakuStaySec,
    );
    debugPrint('[danmaku] 布局: 屏 ${w.round()}x${h.round()} 行高 '
        '${_laneH.round()} 滚动轨道 $scrollLanes 顶 $_topLaneCount '
        '底 $_bottomLaneCount');
  }

  /// 取指定滚动轨道（下标 i）的顶部 y。
  double _scrollLaneY(int i) => _scrollY0 + i * _laneH;

  /// 取指定顶部行（下标 i，0 = 最顶行）的顶部 y。
  double _topLaneY(int i) => _topY0 + i * _laneH;

  /// 取指定底部行（下标 i，0 = 底区最上行）的顶部 y。
  double _bottomLaneY(int i) => _bottomY0 + i * _laneH;

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    // 尺寸变化检测（旋转/全屏切换）：tick 回调发生在 build/layout 之外，
    // 可安全读 context.size；发现变化 → 置重算标记，本帧起用新布局轨道。
    final curSize = context.size;
    if (curSize != null && _layoutSize != curSize) {
      _layoutSize = curSize;
      _needRelayout = true;
    }
    var dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (!widget.playing) return; // 暂停：冻结弹幕（dt 不累计）
    if (widget.danmaku.isEmpty && _active.isEmpty) return;
    // 掉帧保护：大步长会让人眼察觉位置跳变（"移动生硬"的主因之一），
    // 钳制单帧位移；丢失的时间在后续帧按真实 dt 自然追平，无累积漂移。
    dt = math.min(dt, kMaxDanmakuDtSec);

    // 1) 推进已有活跃弹幕（浮点 dt 精确位移）
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
      }
      return gone;
    });

    // 2) 轨道分配器同步推进（腾空已出屏轨道/已停留完的行）
    _lanes?.advance(dt);

    // 3) 发射 timeSec <= 当前播放位置的弹幕（每帧预算内，余量下帧补）
    var changed = false;
    final size = context.size;
    if (size != null && size != Size.zero && _cursor < widget.danmaku.length) {
      _ensureLayout(size);
      final posSec = widget.positionMs / 1000.0;
      var budget = _maxSpawnPerFrame;
      final list = widget.danmaku;
      while (_cursor < list.length && budget > 0) {
        final d = list[_cursor];
        if (d.timeSec > posSec) break; // 未到时间，停（后续帧继续）
        _cursor++;
        if (widget.settings.shouldBlock(d)) {
          _blockedCount++; // 屏蔽命中：不显示（游标已越过，不重发）
          changed = true;
          continue;
        }
        budget--;
        if (_spawn(d, size)) {
          _spawnCount++;
          changed = true;
        }
      }
    }
    if (changed) setState(() {});
    // 弹幕活动日志（每 ~2s 一次，供模拟器 logcat 实测佐证渲染层在发射）
    final nowSec = elapsed.inSeconds;
    if (nowSec != _lastLogSec && (_spawnCount > 0 || _blockedCount > 0)) {
      _lastLogSec = nowSec;
      _logStats();
    }
  }

  /// 周期日志：发射/屏蔽/丢弃计数 + 活跃 vs 轨道数（实测断言依据：
  /// 滚动弹幕逐轨前后不追尾 → 同屏活跃滚动数 <= 轨道数即无叠字；
  /// 丢弃计数 > 0 说明高密度片段在靠丢弹幕保不叠）。
  void _logStats() {
    final lanes = _lanes;
    final activeScroll = _active.where((a) => a.danmaku.isScroll).length;
    final activeStatic = _active.length - activeScroll;
    debugPrint('[danmaku] 发射 $_spawnCount 屏蔽 $_blockedCount '
        '丢(滚动)${lanes?.scrollDropped ?? 0} '
        '丢(顶/底)${(lanes?.topDropped ?? 0) + (lanes?.bottomDropped ?? 0)} · '
        '屏上 滚$activeScroll/静$activeStatic · '
        '滚动轨道 用${lanes?.busyScrollLanes ?? 0}/共${lanes?.scrollLanes ?? 0}'
        ' · pos=${widget.positionMs}ms '
        'cursor=$_cursor/${widget.danmaku.length}');
  }

  /// 发射一条弹幕：经轨道分配器落轨/落行；无可用轨道（打满）→ 丢弃并
  /// 计数（计数在 [DanmakuLanes] 内部），返回 false。文本宽度在此布局
  /// 一次并缓存 TextPainter。
  bool _spawn(Danmaku d, Size size) {
    final lanes = _lanes;
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

    _ActiveDanmaku? placed;
    if (d.isBottom) {
      if (lanes == null) return _drop(painter);
      final lane = lanes.pickBottomLane();
      if (lane == null) return _drop(painter);
      lanes.markBottomLane(lane);
      // 底部弹幕：居中，x 为文本左缘
      placed = _ActiveDanmaku(
        danmaku: d,
        painter: painter,
        x: (size.width - textW) / 2,
        y: _bottomLaneY(lane),
        lifeLeft: kDanmakuStaySec,
      );
    } else if (d.isTop) {
      if (lanes == null) return _drop(painter);
      final lane = lanes.pickTopLane();
      if (lane == null) return _drop(painter);
      lanes.markTopLane(lane);
      placed = _ActiveDanmaku(
        danmaku: d,
        painter: painter,
        x: (size.width - textW) / 2,
        y: _topLaneY(lane),
        lifeLeft: kDanmakuStaySec,
      );
    } else {
      // 滚动：真碰撞选轨道（空轨/追不上的轨），全部打满 → 丢弃
      if (lanes == null) return _drop(painter);
      final distance = size.width + textW;
      final speed = distance / kDanmakuTravelSec; // 速率 px/s（正值）
      final lane = lanes.pickScrollLane(textWidth: textW, speed: speed);
      if (lane == null) return _drop(painter);
      lanes.markScrollLane(lane, textWidth: textW, speed: speed);
      placed = _ActiveDanmaku(
        danmaku: d,
        painter: painter,
        x: size.width + 10, // 屏外起跑（= allocator 的 entryGap），避免闪现
        y: _scrollLaneY(lane),
        vx: -speed,
        speed: speed,
      );
    }
    _active.add(placed);
    _trimOverflow();
    return true;
  }

  /// 丢弃一条（轨道打满放不下）：释放刚 layout 的 TextPainter，返回 false。
  bool _drop(TextPainter painter) {
    painter.dispose();
    return false;
  }

  /// 溢出保护：异常密集（时间点重合 burst）时丢弃最早进入的滚动弹幕，
  /// 防止单帧文本绘制过多掉帧；顶部/底部停留短、数量少，保留不丢。
  void _trimOverflow() {
    if (_active.length <= _maxActiveCount) return;
    var drop = _active.length - _trimActiveCount;
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
      painter: _DanmakuPainter(_active, widget.settings.opacity),
    );
  }
}

/// 绘制活跃弹幕（每帧 paint 时把缓存的 TextPainter 画到对应坐标）。
///
/// 透明度 [opacity] 与顶部/底部淡入淡出统一按"层 alpha"实现：需要淡变时
/// 对该条文本 saveLayer 一次（含阴影一起变淡），alpha=1 时零额外开销。
class _DanmakuPainter extends CustomPainter {
  final List<_ActiveDanmaku> active;

  /// 全局透明度（0.2~1.0，用户滑杆设置）。
  final double opacity;

  _DanmakuPainter(this.active, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in active) {
      final alpha = opacity * a.stayFadeAlpha;
      if (alpha >= 0.995) {
        // 完全不透明：直接画（默认场景，零 saveLayer 开销）
        a.painter.paint(canvas, ui.Offset(a.x, a.y));
        continue;
      }
      // 半透明（用户透明度 or 淡入淡出）：整体乘 alpha（含阴影）
      final rect = Rect.fromLTWH(
        a.x - 2,
        a.y - 2,
        a.painter.width + 4,
        a.painter.height + 4,
      );
      canvas.saveLayer(
        rect,
        Paint()..color = Color.fromRGBO(255, 255, 255, alpha),
      );
      a.painter.paint(canvas, ui.Offset(a.x, a.y));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) => true;
}
