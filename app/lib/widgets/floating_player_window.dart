import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/float_window_prefs.dart';
import '../services/pip_service.dart' show kPipMaxAspect, kPipMinAspect;

// ---------------------------------------------------------------------------
// 应用内浮动小窗（v2.65.0）
// ---------------------------------------------------------------------------
//
// 用户原话：「小窗改成可以拖动角来缩放的，然后加个锁定按钮」。
//
// 为什么不是把系统画中画改一改：系统 PiP 的窗口大小/位置/装饰**全由系统管**，
// App 既不能拖角缩放，也没法在窗口上加自定义按钮 —— 这是 Android 平台限制。
// 所以这里做的是**应用内**浮窗：一块 Positioned 在播放页上层、跟页面内容
// 共存的窗口（页面照常能滚评论），系统 PiP 原样保留（它能在切到别的 App 时
// 继续播，这是应用内浮窗做不到的）。
//
// 本文件只负责「窗口长什么样 + 手势怎么改矩形」：
//  - 几何全是**纯函数**（[floatWindowRect] / [clampFloatWindowRect] /
//    [resizeFloatWindowRect] / [floatWindowRatiosOf]），可单测、无副作用；
//  - 状态（大小/位置/锁定）由播放页持有并持久化，这里只在**手势结束时**回传
//    最终矩形（[FloatingPlayerWindow.onSettled]），拖动过程不写盘。
//
// 三个常量是这一批的契约（测试直接断言这几个数）：
//  - 最小宽度 120dp：再小连"锁"和"还原"两个按钮都摆不开；
//  - 最大宽度 = 页面宽 × 85%：永远留一条边看得见下面的内容；
//  - 拖角把手触摸区 40dp：Android 触摸规范的下限，不再小。

/// 窗口最小宽度（dp）。
const double kFloatMinWidth = 120.0;

/// 窗口最大宽度 / 页面宽度。
const double kFloatMaxWidthRatio = 0.85;

/// 拖角把手的触摸区边长（dp）。
const double kFloatHandleTouchSize = 40.0;

/// 窗口圆角（dp）。
const double kFloatRadius = 12.0;

/// 页面可视区（去掉状态栏 / 底部手势条）。
///
/// 浮窗必须待在这块区域里，否则会被状态栏压住半个标题（用户明确要求
/// 「不能被状态栏遮住」）。
Rect floatWindowSafeArea(Size page, EdgeInsets safe) {
  final top = safe.top.clamp(0.0, page.height);
  final bottom = safe.bottom.clamp(0.0, page.height - top);
  return Rect.fromLTWH(0, top, page.width, page.height - top - bottom);
}

/// 视频宽高比归一（窗口形状跟随画面比例）。
///
/// - 非有限数 / ≤0（取流还没给出真实尺寸）→ 16:9 兜底；
/// - 超宽（> 2.33，如 32:9）或超窄（< 0.5，如竖屏条）夹到
///   [kPipMinAspect]~[kPipMaxAspect] —— 与系统小窗共用同一组上下限：再宽的片子
///   也还该是个"窗口"，而不是一条看不见内容的横线。
double floatWindowAspect(double raw) {
  if (!raw.isFinite || raw <= 0) return 16 / 9;
  return raw.clamp(kPipMinAspect, kPipMaxAspect).toDouble();
}

/// 由比例算出窗口矩形（页面坐标系，dp）。
///
/// 顺序很重要：**先算宽 → 再按比例得高 → 再夹位置**。反过来（先定位置再改
/// 尺寸）会让缩放时窗口"跳"到别处；这里缩放固定左上角，只有越界才整体推回来。
///
/// [widthRatio] / [dxRatio] / [dyRatio] 越界直接夹到 0~1（比读坏值更宽容：
/// 万一 store 里是旧版本写的别的口径，夹一下总比窗口消失好）。
Rect floatWindowRect({
  required Size page,
  required EdgeInsets safe,
  required double aspectRatio,
  required double widthRatio,
  required double dxRatio,
  required double dyRatio,
}) {
  final area = floatWindowSafeArea(page, safe);
  final (width, height) = _windowSize(
    targetWidth: page.width * widthRatio.clamp(0.0, 1.0).toDouble(),
    aspect: floatWindowAspect(aspectRatio),
    page: page,
    area: area,
  );
  // 可移动空间：0 表示"没得动"（窗口比页面还大，或页面退化）→ 位置比就是 0
  final travelX = math.max(0.0, page.width - width);
  final travelY = math.max(0.0, area.height - height);
  return Rect.fromLTWH(
    travelX * dxRatio.clamp(0.0, 1.0).toDouble(),
    area.top + travelY * dyRatio.clamp(0.0, 1.0).toDouble(),
    width,
    height,
  );
}

/// 把窗口矩形整体挪回可视区（尺寸不变）。
///
/// 拖动用：手指怎么甩，窗口最多贴着边停住，不会有一半跑到屏幕外。
Rect clampFloatWindowRect(Rect rect, Size page, EdgeInsets safe) {
  final area = floatWindowSafeArea(page, safe);
  final maxLeft = math.max(0.0, page.width - rect.width);
  // 页面比窗口还矮（极小窗 / 分屏）时 maxTop 会小于 area.top —— 取两者较大的
  // 那个当上界，夹取区间才不会反转（那样 clamp 会抛）。
  final maxTop = math.max(area.top, area.bottom - rect.height);
  return Rect.fromLTWH(
    rect.left.clamp(0.0, maxLeft).toDouble(),
    rect.top.clamp(area.top, maxTop).toDouble(),
    rect.width,
    rect.height,
  );
}

/// 拖右下角之后的矩形：宽度从 [start] 出发加 [deltaWidth]，高度按比例跟，
/// 再夹到最大/最小宽度，最后整体夹回可视区（左上角不动，只有越界才被推回）。
Rect resizeFloatWindowRect({
  required Rect start,
  required double deltaWidth,
  required Size page,
  required EdgeInsets safe,
  required double aspectRatio,
}) {
  final area = floatWindowSafeArea(page, safe);
  final (width, height) = _windowSize(
    targetWidth: start.width + deltaWidth,
    aspect: floatWindowAspect(aspectRatio),
    page: page,
    area: area,
  );
  return clampFloatWindowRect(
    Rect.fromLTWH(start.left, start.top, width, height),
    page,
    safe,
  );
}

/// 矩形 → 比例（拖动/缩放结束后写回 store 用）。
///
/// 与 [floatWindowRect] 严格互逆：`floatWindowRect(ratios(r)) == r`（夹取后）。
({double widthRatio, double dxRatio, double dyRatio}) floatWindowRatiosOf(
  Rect rect,
  Size page,
  EdgeInsets safe,
) {
  final area = floatWindowSafeArea(page, safe);
  final travelX = page.width - rect.width;
  final travelY = area.height - rect.height;
  double ratio(double value, double travel) =>
      travel <= 0 ? 0 : (value / travel).clamp(0.0, 1.0).toDouble();
  return (
    widthRatio: page.width <= 0
        ? kFloatDefaultWidthRatio
        : (rect.width / page.width)
            .clamp(kFloatMinWidthRatio, 1.0)
            .toDouble(),
    dxRatio: ratio(rect.left, travelX),
    dyRatio: ratio(rect.top - area.top, travelY),
  );
}

/// 宽 + 高（保持 [aspect]）。高度超出可视区时按高度反推宽度（仍旧保住比例）。
(double, double) _windowSize({
  required double targetWidth,
  required double aspect,
  required Size page,
  required Rect area,
}) {
  final maxWidth = page.width * kFloatMaxWidthRatio;
  final minWidth = math.min(kFloatMinWidth, maxWidth);
  var width = targetWidth.isFinite
      ? targetWidth.clamp(minWidth, maxWidth).toDouble()
      : minWidth;
  var height = width / aspect;
  if (area.height > 0 && height > area.height) {
    height = area.height;
    width = height * aspect;
  }
  return (width, height);
}

/// 应用内浮动小窗的窗口本体（画面 + 锁 / 还原按钮 + 拖角把手 + 拖动手势）。
///
/// 职责边界：**它不改播放器**，只画 `child`（播放页传进来的是原生纹理）并把手势
/// 翻译成新矩形。矩形归调用方所有（[rect]）——这样"大小/位置"的唯一真相在
/// 播放页手里，它才能顺手持久化。
class FloatingPlayerWindow extends StatefulWidget {
  /// 当前矩形（页面坐标系）。拖动/缩放过程中会被本地临时矩形覆盖。
  final Rect rect;

  /// 页面尺寸（拖动/缩放夹取的口径）。
  final Size pageSize;

  /// 安全区（状态栏 / 底部手势条），夹取时窗口不许越过它。
  final EdgeInsets safeInsets;

  /// 视频宽高比（缩放保持比例用）。
  final double aspectRatio;

  /// 锁定时：拖动/缩放全部失效，把手不构建。
  final bool locked;

  /// 画面本体（原生纹理）。
  final Widget child;

  /// 手势结束回传最终矩形（拖动结束 / 缩放结束各一次）——调用方据此存比例。
  final ValueChanged<Rect> onSettled;

  /// 点锁图标：切换锁定。
  final VoidCallback onToggleLock;

  /// 回到大屏（窗口上的还原按钮 / 双击窗口 / 页面上方的「回到大屏」）。
  final VoidCallback onRestore;

  const FloatingPlayerWindow({
    super.key,
    required this.rect,
    required this.pageSize,
    required this.safeInsets,
    required this.aspectRatio,
    required this.locked,
    required this.child,
    required this.onSettled,
    required this.onToggleLock,
    required this.onRestore,
  });

  @override
  State<FloatingPlayerWindow> createState() => _FloatingPlayerWindowState();
}

class _FloatingPlayerWindowState extends State<FloatingPlayerWindow> {
  /// 手势进行中的临时矩形（null = 用 [FloatingPlayerWindow.rect]）。
  Rect? _drag;

  /// 本次手势的起手矩形。
  Rect? _start;

  /// 缩放累计的水平位移（dx/dy 取绝对值大的那个累加，见 [_onResizeUpdate]）。
  double _resizeDelta = 0;

  /// 本次手势的按下点（窗口局部坐标）：判"拖窗口"还是"拖把手"用。
  Offset? _downPosition;

  /// 本次手势是不是在拖右下角把手。
  bool _resizing = false;

  Rect get _active => _drag ?? widget.rect;

  @override
  void didUpdateWidget(FloatingPlayerWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 锁定时丢掉拖到一半的临时值：否则"拖动中按下锁定"会让窗口停在
    // 一个页面上并不存在的位置（比例里没有它）。
    if (widget.locked && !oldWidget.locked) {
      _drag = null;
      _start = null;
      _resizeDelta = 0;
      _resizing = false;
      _downPosition = null;
    }
  }

  void _onPanDown(DragDownDetails details) {
    // 用**按下点**记位置，而不是 onPanStart 的坐标：pan 要等手指移动超过
    // 触摸阈值才成立，那时的位置已经离按下点 18dp 以上 —— 把手只有 40dp，
    // 很容易在竞技场胜出的那一刻被判成"拖窗口"。
    _downPosition = details.localPosition;
  }

  void _beginDrag(DragStartDetails _) {
    final down = _downPosition;
    // 按下点落在右下角把手区（40dp）→ 这一下是**缩放**，否则是**拖动窗口**。
    // 单一手势识别器 + 按下点分流，比"窗口一个 GestureDetector、把手再套一个"
    // 更可靠：嵌套的同类识别器谁先进竞技场取决于命中顺序，容易出现"拖把手
    // 却把窗口拖走了"（本批实测踩过）。
    _resizing = down != null &&
        down.dx >= widget.rect.width - kFloatHandleTouchSize &&
        down.dy >= widget.rect.height - kFloatHandleTouchSize;
    _start = widget.rect;
    _drag = widget.rect;
    _resizeDelta = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final start = _start;
    if (start == null) return;
    if (_resizing) {
      _onResizeUpdate(details, start);
      return;
    }
    final current = _drag ?? widget.rect;
    setState(() {
      _drag = clampFloatWindowRect(
        current.shift(details.delta),
        widget.pageSize,
        widget.safeInsets,
      );
    });
  }

  void _endGesture() {
    final rect = _drag;
    if (rect == null) return;
    widget.onSettled(rect);
    // 清掉临时值：调用方会用新比例重建出同一个矩形（夹取过的那一个）。
    setState(() {
      _drag = null;
      _start = null;
      _resizeDelta = 0;
      _resizing = false;
    });
  }

  void _onResizeUpdate(DragUpdateDetails details, Rect start) {
    // 取位移较大的那个轴：16:9 的窗口竖着拖 10dp 只该长 10dp（而不是 5.6dp），
    // 否则用户会觉得把手"跟不上手指"。
    final dx = details.delta.dx;
    final dy = details.delta.dy;
    _resizeDelta += dx.abs() >= dy.abs() ? dx : dy;
    setState(() {
      _drag = resizeFloatWindowRect(
        start: start,
        deltaWidth: _resizeDelta,
        page: widget.pageSize,
        safe: widget.safeInsets,
        aspectRatio: widget.aspectRatio,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final rect = widget.locked ? widget.rect : _active;
    return Positioned.fromRect(
      rect: rect,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kFloatRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. 黑底：比例被夹过（超宽/超窄片源）时两侧留黑，语义与全屏一致
            const ColoredBox(color: Colors.black),
            // 2. 画面（宽高比与窗口一致 → 正常情况下刚好填满）
            Center(
              child: AspectRatio(
                aspectRatio: floatWindowAspect(widget.aspectRatio),
                child: widget.child,
              ),
            ),
            // 3. 手势层：拖动窗口 / 拖右下角缩放 / 双击还原，**一个识别器**搞定。
            //    按下点落在右下角 40dp 内 → 缩放，否则拖动窗口（见 [_beginDrag]）。
            //    锁定时**不挂 pan**（拖动/缩放都不生效），但双击还原还在 ——
            //    锁定只防误触，不该把人锁死在小窗里。
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('player-float-window'),
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.onRestore,
                onPanDown: widget.locked ? null : _onPanDown,
                onPanStart: widget.locked ? null : _beginDrag,
                onPanUpdate: widget.locked ? null : _onDragUpdate,
                onPanEnd: widget.locked ? null : (_) => _endGesture(),
                onPanCancel: widget.locked ? null : _endGesture,
              ),
            ),
            // 4. 右上角：锁定 + 还原（两个 40dp 触摸区，压一层黑雾保证在亮画面上
            //    也看得见）
            Positioned(
              top: 0,
              right: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  borderRadius:
                      BorderRadius.only(bottomLeft: Radius.circular(10)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FloatChromeButton(
                      buttonKey: const ValueKey('player-float-lock'),
                      icon: widget.locked ? Icons.lock : Icons.lock_open,
                      tooltip: widget.locked ? '解锁小窗' : '锁定小窗（防误触）',
                      color: widget.locked ? const Color(0xFFFFD54F) : Colors.white,
                      onTap: widget.onToggleLock,
                    ),
                    _FloatChromeButton(
                      buttonKey: const ValueKey('player-float-restore'),
                      icon: Icons.close_fullscreen,
                      tooltip: '回到大屏',
                      color: Colors.white,
                      onTap: widget.onRestore,
                    ),
                  ],
                ),
              ),
            ),
            // 5. 右下角：拖角缩放把手（锁定后整块不构建 = 视觉上就告诉你"不能
            //    缩放了"；40dp 触摸区，IgnorePointer 让手势落到下面那个统一的
            //    识别器上，避免嵌套同类识别器抢手势）
            if (!widget.locked)
              Positioned(
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey('player-float-handle'),
                    width: kFloatHandleTouchSize,
                    height: kFloatHandleTouchSize,
                    alignment: Alignment.bottomRight,
                    decoration: const BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(10),
                        bottomRight: Radius.circular(kFloatRadius),
                      ),
                    ),
                    child: const CustomPaint(
                      size: Size.square(16),
                      painter: _FloatGripPainter(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 窗口角上的小图标按钮（40×40 触摸区，图标 18）。
class _FloatChromeButton extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _FloatChromeButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        key: buttonKey,
        padding: EdgeInsets.zero,
        iconSize: 18,
        tooltip: tooltip,
        icon: Icon(icon, color: color),
        onPressed: onTap,
      ),
    );
  }
}

/// 右下角的斜线抓手（三条 45° 短线，越大越靠里 —— 经典 resize grip）。
class _FloatGripPainter extends CustomPainter {
  const _FloatGripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final gap = 4.0 + i * 4.0;
      canvas.drawLine(
        Offset(size.width - gap, size.height),
        Offset(size.width, size.height - gap),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FloatGripPainter oldDelegate) => false;
}
