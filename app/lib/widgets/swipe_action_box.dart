/// 通用「左滑露出操作块」组件（合集卡左滑重命名 / 删除，v2.19.x）。
///
/// 包住任何卡片即可：手指向左滑 → 卡片整体左移，右侧露出
/// `actions.length * actionWidth` 宽的操作块区；松手按位移比例吸附
/// （过半或甩得够快 → 完全露出，否则收回）。
///
/// 四条设计约束：
/// 1. **不引第三方依赖**（不用 flutter_slidable）：一个 [AnimationController]
///    管 [Offset] 就够，省一个包；
/// 2. **关动效 = 零 ticker**：`MotionControl.of(context)` 为 false（含
///    `flutter test` 默认环境、系统「减少动画」）时**不创建**
///    [AnimationController]，位移直接 setState 跳变 —— 与
///    `add_success_button.dart` / `smoke_silhouette.dart` 同一条约定，
///    测试里的 `pumpAndSettle` 因此不会被卡住；
/// 3. **不与宿主手势抢戏**：配合长按拖拽（[ReorderableDelayedDragStartListener]）
///    使用时，只有**横向位移越过 [kTouchSlop]** 才真正接管 —— 按住不动
///    500ms 的延时拖拽识别器先胜出，长按拖拽不受影响（见
///    `playlist_page.dart` 的合集卡排序）；
/// 4. **同时只允许一张卡露出**：跨卡状态收在本组件的静态引用里（见
///    [SwipeActionBox.resetForTest]），宿主**不需要**知道「当前打开的是谁」——
///    多张卡之间本就没有共同父 State，硬提状态等于把列表整段改造。
///
/// 交互细节：
/// - **起始阈值**：累计 dx 未越过 [kTouchSlop] 前不移动卡片（防轻碰误触）；
/// - **跨卡联动**：手指一按到别的卡（或开始横向拖它），上一张露出的就收回
///    —— 同屏永远不会同时挂着两张「半开」的卡；
/// - **滚即收回**：宿主列表一滚（[ScrollPosition] 变化）就收回 —— 卡片位置
///   都变了，还挂着半开的操作块只会显得脏；
/// - **收回**：点操作块后自动收回；已露出时点卡片本体 → 只收回，并把这次
///   点击**挡在卡片之外**（不触发 child 的 `InkWell`）；右滑也收回；
/// - **点操作块**：靠几何分区而不是手势竞技场顺序来保证不误触 —— 露出时
///   在「卡片可见区」盖一层透明挡板，操作块区**不在**挡板范围内；
/// - **右圆角不留缝**：操作块区**只裁右外缘圆角、左缘直角**，并在最左补一
///   条与首块同色的垫片（[SwipeActionBox.cornerFillKey]）—— 卡片左移后，
///   从它自己 [kRadiusMd] 右圆角缺口里透出来的就是**块色**，整条看起来像是
///   从卡片底下铺出来的（几何见 `_SwipeActionBoxState.build` 的 ①）。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior, kTouchSlop;
import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';

/// 甩动判定阈值（px/s）：超过它时，方向决定开合，不看位移比例。
///
/// 取 700：慢拖（测试里的 10px/100ms = 100px/s）不会误判成甩动，
/// 而真手指一甩（通常 > 1500）一定达标。
const double _kFlingVelocity = 700;

/// 一个操作块的内容（纯数据，不持状态）。
@immutable
class SwipeAction {
  const SwipeAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textColor,
  });

  /// 块上的文字（如「重命名」/「删除」），同时作 [Semantics] 标签。
  final String label;

  final IconData icon;

  /// 块底色。
  final Color color;

  /// 点击回调。
  final VoidCallback onTap;

  /// 图标 / 文字色；null → [highestContrastOn] 按 [color] 自动挑（纸白或近黑）。
  ///
  /// 调用方要精确控制时显式传（如「重命名」传 `palette.onInk`、
  /// 「删除」传 `kPaper`）。
  final Color? textColor;
}

/// 左滑露出右侧操作块；包住任何卡片即可。
class SwipeActionBox extends StatefulWidget {
  const SwipeActionBox({
    super.key,
    required this.child,
    required this.actions,
    this.enabled = true,
    this.actionWidth = 76.0,
  });

  /// 被包住的卡片本体（跟着手指左移的就是它）。
  final Widget child;

  /// 露出的操作块（从左到右 = 列表顺序；视觉上贴右边缘）。
  final List<SwipeAction> actions;

  /// false → 直接返回 [child]（零手势、零动画层）。
  final bool enabled;

  /// 单个操作块的宽度；[SwipeActionBox] 保证触摸目标 ≥ 48dp，故默认 76。
  final double actionWidth;

  /// 单个操作块根 [Material] 的 key（测试锚点：量触摸目标尺寸）。
  static Key actionKey(String label) =>
      ValueKey<String>('swipe-action-$label');

  /// 操作块区外框 [ClipRRect] 的 key（测试锚点：断言只裁右外缘圆角）。
  static const Key actionAreaKey = ValueKey<String>('swipe-action-area');

  /// 卡片右圆角补角垫片的 key（测试锚点：断言宽度 = [kRadiusMd]）。
  static const Key cornerFillKey =
      ValueKey<String>('swipe-action-corner-fill');

  /// 测试专用：清空跨卡「当前打开者」的静态引用。
  ///
  /// 与 `MotionControl.reset()` 同一条约定 —— 全局状态都留一个清理入口，
  /// `setUp` / `tearDown` 各调一次，免得上一个用例的引用串到下一个用例。
  @visibleForTesting
  static void resetForTest() => _SwipeActionBoxState.resetCurrent();

  @override
  State<SwipeActionBox> createState() => _SwipeActionBoxState();
}

class _SwipeActionBoxState extends State<SwipeActionBox>
    with TickerProviderStateMixin {
  /// 模块级「当前打开者」：整个 app 同一时刻只允许一张卡露出。
  ///
  /// 故意不是宿主的状态：同屏多张卡之间没有共同父 State，要宿主维护
  /// 「当前打开的是谁」就得把整段列表提状态 / 建 InheritedWidget；收
  /// 在这里，宿主一行 [SwipeActionBox] 就拿到联动效果。
  static _SwipeActionBoxState? _current;

  /// 测试专用：清空 [_current]（由 [SwipeActionBox.resetForTest] 转发）。
  static void resetCurrent() => _current = null;

  /// 宿主滚动位置（列表一滚就收回）；在 [didChangeDependencies] 里同步。
  ScrollPosition? _scroll;
  /// 补间控制器；**关动效（含 `flutter test` 默认环境）恒为 null**。
  ///
  /// 用 [TickerProviderStateMixin] 而非 Single：关闭/重开动效（或
  /// enabled 抖动）可能丢掉再建，Single 只允许 createTicker 一次。
  AnimationController? _c;

  /// 当前露出比例：0 = 完全合上，1 = 完全露出。
  ///
  /// 它同时是「关动效」时的唯一真相（直接 setState 跳变）。
  double _progress = 0;

  /// 本组件可用宽度内，操作块区实际占的宽度（px）。
  ///
  /// 在 [LayoutBuilder] 里刷新：宿主比「全部操作块」还窄时按宿主宽裁，
  /// 不把卡片推出自己的盒子。
  double _travel = 0;

  /// 本次横向拖动的累计 dx（带符号：负 = 左滑）。
  double _accum = 0;

  /// 按下那一刻的 [_progress]。
  double _startProgress = 0;

  /// 累计位移是否已越过 [kTouchSlop]（越过才真正接管手势）。
  bool _claimed = false;

  /// 是否正被手指拖动（拖动中不跑收/放动画）。
  bool _dragging = false;

  /// [MotionControl.of] 的当前值（`didChangeDependencies` 里刷新）。
  bool _motion = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MotionControl.of 内部走 MediaQuery（系统「减少动画」）→ 只能在
    // didChangeDependencies 里读，不能在 initState。
    _motion = MotionControl.of(context);
    _syncController();
    _syncScrollListener();
  }

  @override
  void didUpdateWidget(covariant SwipeActionBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.actions.isEmpty || widget.actionWidth <= 0) {
      // 禁用 / 无操作块 → 立即回位，不留位移（下次启用从合上开始）
      _progress = 0;
      _dragging = false;
      _claimed = false;
      _forgetCurrent(); // 自己都不再用左滑了，别继续占着「当前打开者」
    }
    _syncController();
  }

  /// 按需建 / 丢 controller：**关动效时一个 ticker 都不注册**。
  void _syncController() {
    final want = widget.enabled && widget.actions.isNotEmpty && _motion;
    if (want) {
      if (_c == null) {
        final c = AnimationController(vsync: this, duration: kDurBase);
        c.addListener(_onTick);
        _c = c;
      }
    } else if (_c != null) {
      _c!.dispose();
      _c = null;
    }
  }

  void _onTick() {
    if (!mounted) return;
    setState(() => _progress = _c!.value);
  }

  // -------------------------------------------------------------------------
  // 跨卡联动 / 滚动收回
  // -------------------------------------------------------------------------

  /// 挂上最近一层可滚动容器的位置监听：列表一滚，露出的卡就收回。
  ///
  /// 用 [Scrollable.maybeOf]（依赖内部 `_ScrollableScope`）**而不是**在本
  /// 子树里套 [NotificationListener]：宿主列表是本组件的**祖先**，滚动通知
  /// 只从 Scrollable 往上冒，套在自己身上一条都收不到。
  void _syncScrollListener() {
    final pos = Scrollable.maybeOf(context)?.position;
    if (identical(pos, _scroll)) return;
    _scroll?.removeListener(_onScroll);
    _scroll = pos;
    _scroll?.addListener(_onScroll);
  }

  /// 列表滚动中 → 把还在露出的自己收回（本来就合上时什么都不做）。
  void _onScroll() {
    if (_progress != 0) _close();
  }

  /// 如果「当前打开者」是自己就清掉（被禁用 / 卸载时调用）。
  ///
  /// 卸载时必须清：静态引用悬到一个已 dispose 的 State 上，下一个卡一开
  /// 就会去 setState 它 → 直接抛。
  void _forgetCurrent() {
    if (identical(_current, this)) _current = null;
  }

  /// 收回**别的**卡（自己即将成为新的「当前打开者」）。
  void _dismissOthers() {
    final prev = _current;
    if (!identical(prev, this)) prev?._close();
  }

  @override
  void dispose() {
    _forgetCurrent();
    _scroll?.removeListener(_onScroll);
    _scroll = null;
    _c?.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 手势
  // -------------------------------------------------------------------------

  void _onDragStart(DragStartDetails d) {
    _dragging = true;
    _claimed = false;
    _accum = 0;
    _startProgress = _progress;
    _c?.stop(); // 拖住正在收 / 放的动画
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    // 累计位移从按下点算起（DragStartBehavior.down 把 slop 那一段也交上来）
    _accum += d.delta.dx;
    // 起始阈值：没越过 touch slop 前不接管（轻碰 / 竖滑不惊动卡片）
    if (!_claimed) {
      if (_accum.abs() <= kTouchSlop) return;
      _claimed = true;
      // 真正接管了才动手：别的卡若还挂着操作块，现在收回（同屏只许一张）
      _dismissOthers();
    }
    if (_travel <= 0) return;
    _apply(_startProgress - _accum / _travel);
  }

  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    if (!_claimed) return; // 没接管过 → 什么也没动
    final vx = d.velocity.pixelsPerSecond.dx;
    final bool open;
    if (vx.abs() >= _kFlingVelocity) {
      open = vx < 0; // 左甩 → 露出；右甩 → 收回
    } else {
      open = _progress >= .5; // 过半吸附
    }
    if (open) {
      _open();
    } else {
      _close();
    }
  }

  /// 把 [p] 夹到 [0,1] 并写到当前真相（有 controller 走补间值，没有直接跳）。
  void _apply(double p) {
    final v = p.clamp(0.0, 1.0);
    final c = _c;
    if (c != null) {
      c.value = v; // 监听器 setState
    } else {
      setState(() => _progress = v);
    }
  }

  /// 收 / 放到 [target]：有 controller 走 [kDurBase] + [kCurveOut]，否则瞬变。
  void _animateTo(double target) {
    final c = _c;
    if (c == null) {
      if (_progress != target) setState(() => _progress = target);
      return;
    }
    if (c.value == target) return;
    c.animateTo(target, duration: kDurBase, curve: kCurveOut);
  }

  /// 露出自己：先把上一张露出的卡收回，再把自己记成「当前打开者」。
  void _open() {
    _dismissOthers();
    _current = this;
    _animateTo(1);
  }

  void _close() {
    _forgetCurrent();
    _animateTo(0);
  }

  // -------------------------------------------------------------------------
  // 布局
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 禁用 / 没有操作块：直接就是 child，树里连手势层都没有
    if (!widget.enabled || widget.actions.isEmpty || widget.actionWidth <= 0) {
      return widget.child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final natural = widget.actions.length * widget.actionWidth;
        // 宿主比「全部操作块」还窄时按宿主宽裁（不把卡片推出自己的盒子）
        _travel = constraints.maxWidth.isFinite
            ? math.min(natural, constraints.maxWidth)
            : natural;
        // 卡片右圆角要垫的宽度：[kRadiusMd]。卡片左移后，它自己右上 /
        // 右下那两块圆角缺口底下是空的（卡片的圆角把这一小块挖掉了），
        // 操作块区不往左多铺这一条，缺口里透出来的就是**背景色** ——
        // 也就是「块和卡没连上」的那道缝。窄宿主下按剩余宽度收着垫，
        // 不越出盒子左边。
        final fillW = constraints.maxWidth.isFinite
            ? math.max(
                0.0, math.min(kRadiusMd, constraints.maxWidth - _travel))
            : kRadiusMd;
        final dx = _travel * _progress.clamp(0.0, 1.0);
        return Listener(
          // 手指一按到本卡（还没滑）就把别的卡的露出收掉：「滑开 A 之后
          // 去点 / 去滑别的卡，A 还挂着半开」就不会发生。
          // [Listener] 不进手势竞技场、只旁观，child 的点击 / 长按拖拽
          // 一个都不受影响。
          onPointerDown: (_) => _dismissOthers(),
          child: GestureDetector(
            // opaque：卡片被 [Transform] 平移后，命中区也跟着走；本层必须
            // 始终可命中（露出时「点卡片收回」的挡板才盖得住）
            behavior: HitTestBehavior.opaque,
            // down（默认是 start）：把「越过 slop 的那一段」也当作位移交上来，
            // 卡片与手指从按下点起 1:1 —— 否则一大步甩动会被整段吞掉，
            // `_accum` 永远为 0（单步 160px 的滑动手势完全失效）。
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: Stack(
              // 卡片左移后要画出自己的左边界（右侧操作块区不能跟着裁）
              clipBehavior: Clip.none,
              children: [
                // ① 右侧操作块区：贴右固定，卡片左移后露出来。
                //    只在「已露出」时建 —— 列表里成百张卡不必养着 2N 个
                //    Material/InkWell，也让测试能用 find.text 判断露出与否。
                if (dx > 0)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    // 比操作块本身再宽 [fillW]：多出来的那截藏在卡片右
                    // 圆角缺口下面（全露时正好垫满，半露时垫在卡片底下）
                    width: _travel + fillW,
                    child: ClipRRect(
                      key: SwipeActionBox.actionAreaKey,
                      // **只裁右外缘**：左缘必须直角 —— 这条垫片要伸到
                      // 卡片圆角底下，左缘若是圆角，缺口里露出来的还是
                      // 背景色（缝还在）。右外缘留 [kRadiusMd] 圆角，是
                      // 为了全露时整行外廓仍是块化语言，不比邻卡突兀。
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(kRadiusMd),
                        bottomRight: Radius.circular(kRadiusMd),
                      ),
                      child: Row(
                        children: [
                          // 补角垫片：与最左块同色 —— 视觉上就是块从卡片
                          // 底下铺出来的一整条，看不出「块从哪儿开始」
                          if (fillW > 0)
                            SizedBox(
                              width: fillW,
                              // 撑满行高：Row 默认 center 对齐（高度是松约束），
                              // 不显式撑高的话这个「没有 child 的 ColoredBox」
                              // 会塌成 0 高 → 什么也不画（缝还在）
                              height: double.infinity,
                              child: ColoredBox(
                                key: SwipeActionBox.cornerFillKey,
                                color: widget.actions.first.color,
                              ),
                            ),
                          for (final a in widget.actions)
                            Expanded(child: _actionBlock(a)),
                        ],
                      ),
                    ),
                  ),
                // ② 卡片本体：非 Positioned → 它决定 Stack 的尺寸
                //    （Positioned(top/bottom) 需要 Stack 先有高度，全靠它）
                Transform.translate(
                  offset: Offset(-dx, 0),
                  child: widget.child,
                ),
                // ③ 已露出时的「点一下收回」挡板：宽度只到卡片右缘，
                //    右侧操作块区**不在**范围内 → 操作块照常可点（几何分区，
                //    不赌手势竞技场的先后）
                if (dx > 0)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: 0,
                    right: dx,
                    child: GestureDetector(
                      // translucent：自己不拦命中路径，只是"顺便"参与竞技场
                      behavior: HitTestBehavior.translucent,
                      onTap: _close,
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 单个操作块：底色实心 [Material]（自带 ink 层，不依赖宿主 Scaffold）+
  /// 图标 + [kTypeLabel] 文字；撑满整列 → 触摸目标 = 块尺寸（≥ 48dp）。
  Widget _actionBlock(SwipeAction a) {
    final fg = a.textColor ?? highestContrastOn(a.color);
    return Semantics(
      button: true,
      label: a.label,
      // 文案已经写在块上，别再让读屏念第二遍
      excludeSemantics: true,
      child: Material(
        key: SwipeActionBox.actionKey(a.label),
        color: a.color,
        child: InkWell(
          onTap: () {
            // 先收回再执行：删除会连带移除本卡片，先改自己的状态更安全
            _close();
            a.onTap();
          },
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(a.icon, size: 20, color: fg),
                const SizedBox(height: kSpace4),
                Text(a.label, style: kTypeLabel.copyWith(color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
