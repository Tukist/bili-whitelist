/// 交错入场（块化批次 0）。
///
/// 只做**逐项 wrapper** + 列表级 scope，**刻意不做接管列表的
/// `StaggeredListView`**：接管列表就必须把每一项都先建出来才能算延迟，
/// 这会毁掉 `ListView.builder` 的懒加载 —— 长列表（收藏夹动辄上千条）
/// 一次性建完必然卡死/爆内存。逐项包装天然兼容懒加载：划到哪，哪一项
/// 自己入场；已经入场过的项由 [EntranceLedger] 记账，被回收再出现时不重播。
///
/// 用法：
/// ```dart
/// StaggeredListScope(
///   generation: bvid,          // 换数据源 → 新 generation
///   ledger: EntranceLedger(),  // 由宿主 state 持有，跨列表项生命周期存活
///   child: ListView.builder(
///     itemBuilder: (c, i) => StaggeredEntrance(
///       entryKey: items[i].bvid,
///       index: i,
///       child: VideoTile(...),
///     ),
///   ),
/// )
/// ```
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';

/// 「已入场」记账本：**活在 item 之外**，所以 `ListView` 回收 element
/// 再重建时也能认出「这一条演过了」，不会重播。
///
/// 只记账，不管生命周期；换数据（重新加载 / 换 bvid / 换合集）时由宿主
/// 换一个新本子（见 [StaggeredListScope.generation]）。
class EntranceLedger {
  final Set<String> _played = <String>{};

  /// 首次认领 [key] → true（顺便记账）；已记过账 → false。
  bool claim(String key) => _played.add(key);

  /// 清空（等价于「全部允许重播」）
  void clear() => _played.clear();

  /// 已记账条数（调试 / 测试用）
  int get size => _played.length;
}

/// 列表级 scope：给底下的 [StaggeredEntrance] 提供 [ledger] 与 [generation]。
///
/// [generation] 变（重新加载 / 换 bvid / 换合集）→ 宿主换新 ledger，
/// 于是「同样的条目」可以再演一次；不变则一直沿用同一本账。
class StaggeredListScope extends InheritedWidget {
  const StaggeredListScope({
    super.key,
    required this.generation,
    required this.ledger,
    required super.child,
  });

  /// 数据身份：同一个列表数据用同一个值（如 bvid / 合集名 / 页码种子）。
  ///
  /// ⚠️ generation 变化**不会**让已经在树上的 element 重播：记账只在 element
  /// 首次挂载时读一次（[StaggeredEntrance] 的生命周期约束）。重播发生在列表
  /// 随数据重建出新 element 时——换 bvid → 新列表 → 新 element → 新账本
  /// → 允许再演一次。这也是它必须配 [ledger] 一起换的原因。
  final Object generation;

  final EntranceLedger ledger;

  /// 用 `getInheritedWidgetOfExactType` 而不是 `dependOn...`：
  /// [StaggeredEntrance] 要在 `didChangeDependencies` 里查它，
  /// 语义上只是"读一次当前配置"，不需要订阅重建。
  static StaggeredListScope? maybeOf(BuildContext c) =>
      c.getInheritedWidgetOfExactType<StaggeredListScope>();

  @override
  bool updateShouldNotify(StaggeredListScope old) =>
      old.generation != generation || !identical(old.ledger, ledger);
}

/// 单项交错入场包裹件。
///
/// 四条硬约束（都写进测试了）：
/// 1. **延迟用 [Interval]，不用 `Future.delayed`**：只有一个**有限**的
///    ticker，没有定时器 + setState 的反模式，`pumpAndSettle` 必然收敛；
/// 2. **记账在首帧前同步完成，账本在 item 之外**（[EntranceLedger]）；
/// 3. **动画结束即卸载飞行包裹层**：树里不留残余
///    `FadeTransition` / `Transform`，拖拽与长按的命中测试回到干净状态；
/// 4. **飞行只管 opacity + 平移，绝不加 `IgnorePointer`**：
///    入场那 240ms 里用户点到什么就得是什么。
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    super.key,
    required this.entryKey,
    required this.child,
    this.index = 0,
    this.enabled,
    this.step = kStaggerStep,
    this.duration = kDurEntrance,
    this.maxIndex = kStaggerMaxIndex,
    this.risePx = kEntranceRisePx,
  });

  /// 稳定标识（bvid / rpid / `collection#<name>`）：**同一条内容必须始终
  /// 给同一个值**，否则记账认不出来，每次重建都会重播。
  final String entryKey;

  final Widget child;

  /// 同批次内的序号（决定延迟）
  final int index;

  /// null → 读 [MotionControl.of]（全局开关 + 系统「减少动画」）
  final bool? enabled;

  /// 相邻项步进
  final Duration step;

  /// 单项入场时长
  final Duration duration;

  /// 延迟封顶序号（第 N 项之后不再叠加，避免长列表尾部等太久）
  final int maxIndex;

  /// 起始下移量（px）
  final double risePx;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    // 只 arm 一次 → 一个 State 生命周期内最多一个 controller，Single 足够
    // （AnimatedCopyLine 会因为换文案重建 controller，那里必须用多 ticker 版）
    with SingleTickerProviderStateMixin {
  AnimationController? _c;
  CurvedAnimation? _curved;

  /// 是否走动画路径（false = 直接给 child，树里没有任何包裹层）
  bool _animated = false;

  /// 动画是否已结束（结束后卸载包裹层）
  bool _finished = false;

  /// 是否已完成一次性初始化（记账 + 建 controller 只做一次）
  bool _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不在 initState 里查 MotionControl.of：它内部走 MediaQuery.of
    // （`dependOnInheritedWidgetOfExactType`），在 initState 里做祖先查找
    // 会直接抛断言。didChangeDependencies 同样在**首帧之前**同步执行一次，
    // 「首帧前完成记账」这个目标照样满足；`_armed` 保证只跑一次。
    if (_armed) return;
    _armed = true;
    _arm();
  }

  void _arm() {
    // 关动效 → 树里连 controller 都不建（不是建了不 forward，免得多一个
    // 挂着的 ticker 与一堆无谓的重建）
    final enabled = widget.enabled ?? MotionControl.of(context);
    if (!enabled) return;

    // 记账：查 scope 只用 getInheritedWidgetOfExactType（不注册依赖）
    final scope = StaggeredListScope.maybeOf(context);
    if (scope != null && !scope.ledger.claim(widget.entryKey)) {
      // 演过了 → 直接到位：不建 controller、不做动画，也不留包裹层
      return;
    }

    _animated = true;
    // ⚠️ math.min/max 的结果直接当乘数会被推断成 num（`num operator *` 传下去的
    // 上下文类型就是 num）→ 先落到 int 变量再参与算术，否则 num 会一路传播，
    // Duration(milliseconds:) 那里类型不过。
    final int at = math.min(widget.index, widget.maxIndex);
    final int delayMs = widget.step.inMilliseconds * at;
    final int totalMs = math.max(1, delayMs + widget.duration.inMilliseconds);
    final c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: totalMs),
    );
    c.addStatusListener(_onStatus);
    _c = c;
    // 延迟用 Interval 表达（delayMs/totalMs → 1）：ticker 只跑一段有限时间，
    // 没有 Future.delayed + setState，pumpAndSettle 一定收敛。
    _curved = CurvedAnimation(
      parent: c,
      curve: Interval(delayMs / totalMs, 1.0, curve: kCurveOut),
    );
    c.forward();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    // 结束 → 卸载飞行包裹层：此后树里既没有 FadeTransition 也没有 Transform，
    // 拖拽/长按的命中测试不受残留变换影响。
    setState(() => _finished = true);
  }

  @override
  void dispose() {
    _c?.removeStatusListener(_onStatus);
    _curved?.dispose();
    _c?.dispose();
    _curved = null;
    _c = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = _curved;
    // 关动效 / 已记账 / 动画结束：直接给 child —— 零包裹层、零语义变化
    if (!_animated || _finished || curved == null) return widget.child;
    return FadeTransition(
      opacity: curved,
      child: AnimatedBuilder(
        animation: curved,
        // ★ 必须传 child：否则每帧重建整棵子树（列表项子树很贵）
        child: widget.child,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, widget.risePx * (1 - curved.value)),
          child: child,
        ),
      ),
    );
  }
}
