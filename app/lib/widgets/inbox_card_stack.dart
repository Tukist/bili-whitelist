/// 信箱卡片栈（Tinder 式）的**多层叠放**与**一张划走、下一张向前推出**。
///
/// ## 一叠牌（不是「一张卡 + 一条边」）
/// 同时渲染**顶层 + 后 3 张**（[kInboxStackCards] = 4）：越深越**小**、越**低**、
/// 越**淡**（表中第 5 行只在推进/退回途中经过，静止时不存在）：
///
/// | 深度 | 缩放 | 底边下移 | 不透明度 |
/// |------|------|----------|----------|
/// | 0（顶层） | 1.00 | 0 | 1.00 |
/// | 1（下一张） | [kInboxStackScale]（0.96） | [kInboxStackOffset]（12） | 1.00 |
/// | 2 | 0.92 | 20 | 0.94 |
/// | 3 | 0.88 | 28 | 0.88 |
/// | 4（推进/退回途中经过） | 0.84 | 36 | 0.00 |
///
/// 为什么这样取值 / 为什么好看：
/// - **底边对齐**：每层都锚在**底边**上（`Positioned(bottom: -下移量)` +
///   `Transform.scale(alignment: bottomCenter)`；缩放不改底边位置）→
///   净露出量恒等于该层的下移量，与卡片内容高度（标题 1 行 / 2 行）无关
///   （旧实现「固定下移 + 居中缩放」在下一张更矮时会被完全盖住）；
/// - **逐层递进**：每层缩 4%、底部多下移 8dp 左右 —— 这是「一叠牌」的最小可辨
///   增量：再小就只剩一条线（这正是要修的现状），再大就摊成扇形了。
///   缩放让两侧各露出 ~7dp、下移让底部露出 8~12dp，**横竖两条边都能看见**，
///   「这里有一叠牌」一眼成立；
/// - **无阴影**（本设计语言只有 1px 描边 + 底材差）：层级只能靠「更小 + 更低 +
///   更淡」。不透明度只降 6%～12%（深度 1 保持满不透明 —— 下一张是要读的），
///   再淡就成了一叠半透明的纸，卡面描边的对比度也会被稀释；
/// - 深度 4 的不透明度 = 0：它不是「可见的一层」，而是**补充进栈的那张**在
///   推进起点处的位置（从更深更淡处浮现，见下）。
///
/// ## 向前推进（一张划走 → 下一张顶上来）
/// 推进由**一个** [AnimationController] 的进度 `u ∈ [0,1]` 驱动。第 `i` 层
/// （`i ≥ 1`，`i = 0` 是顶层，永远铺在深度 0）的**连续深度**是
///
/// ```
/// depth_i(u) = i - p_i(u)
/// p_i(u)     = kCurveOut.transform(clamp01((u - lag_i) / (1 - lag_i)))
/// ```
///
/// `lag_i` 按「这一层**结算后**的深度」给（顶层 0 → 越深越晚起步）→ 前排先走、
/// 后排末尾**追上来**：这是**层次感**，不是弹簧回弹（本项目风格克制）。
///
/// 四条关键性质（都在测试里锁住了）：
/// 1. **不跳变**。`u = 1` 时 `depth_i = i - 1`；而出栈那一刻列表索引整体前移
///    一位（原第 `i` 张变成第 `i - 1` 张）→ 两边算出的位置**逐层重合**。
///    于是在改变列表的**同一帧**把 `u` 归零（见 [didUpdateWidget] 的
///    `_isHeadRemoval` 分支），推进与出栈就无缝续上；
/// 2. **与飞出并行**。顶层一开始飞出（[advancing]）推进就跑了；[kDurAdvance]
///    （260ms）< 飞出时长 [kDurSlow]（320ms）→ 下一张在顶层还没飞出屏幕时就已
///    到位，没有「等它飞完才动」的停顿。★ 该不等式是硬前提：出栈早于推进到位
///    会把没走完的层硬拽到位（跳变）；
/// 3. **补卡不突兀**。推进/退回期间渲染窗口**多带一张**（[`_extra`]）：它从
///    深度 4（不透明度 0）浮现到深度 3（0.88）；收窗口时它恰好在深度 4
///    （= 全透明）→ 收掉看不出来。队列再长也只多建这一张，
///    **不会为 100 条都建 widget**；
/// 4. **拖动时后层不动**。推进只由「顶层开始飞出」这一件事触发；跟手只动顶层
///    自己 → 拖动期间后层的 widget 实例**原样交回**（见 [`_layers`] 缓存），
///    Flutter 的 `updateChild` 见到同一个实例会直接跳过整棵子树。
///
/// ## 撤销
/// 撤销 = **反着播**同一条推进：队首插回一张（见 [didUpdateWidget] 的
/// `_isHeadInsert` 分支）→ `u` 从 1 倒回 0，后层退回原位；那一刻被顶开的那张
/// 恰好落回它原来的位置 → 逐层连续、无跳变。
///
/// ## 关动效（`flutter test` 默认 / 系统「减少动画」）
/// [MotionControl.of] 为 false 时**连 AnimationController 都不建**：每层直接铺
/// 静止变换、不预留多一张的窗口，出栈瞬时到位，`pumpAndSettle` 必然收敛
/// （既有约定，别改）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/inbox_service.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';
import 'inbox_card_styles.dart';
import 'inbox_swipe_card.dart';
import 'staggered_entrance.dart';

/// 静止时栈内最多同时渲染的卡片数（顶层 + 后 3 张）。
///
/// 深度 0..[kInboxStackCards] - 1；队列更长时也只渲染这几张（不为 100 条都
/// 建 widget）。推进/退回期间窗口临时 +1（见文件头「补卡不突兀」）。
const int kInboxStackCards = 4;

/// 最深一层的底边下移量（= 深度 4 的值，深度表里最大的一项）。
///
/// 宿主用它给卡片区留高度预算（见 `inbox_page.dart` 的 `_buildDeck`）：
/// 后层是按底边往下铺的，不预留就会压到下面那排按钮上。
const double kInboxStackMaxDrop = 36;

/// 「向前推进」的时长。
///
/// ★ 必须 **≤ 顶层飞出时长**（[kDurSlow]，320ms）：推进与飞出并行跑，出栈那一刻
/// 推进必须已经到位 —— 否则出栈会把没走完的层硬拽到位（跳变）。
/// 取 260ms（kDurBase 200 ~ kDurSlow 320 之间）比飞出**略早**收尾：
/// 下一张先落位，顶层再飞出屏幕，收尾干净。
const Duration kDurAdvance = Duration(milliseconds: 260);

/// 连续深度 → 缩放（线性插值；深度 1 沿用既有常量 [kInboxStackScale]，
/// 保证「下一张露多少」这一既有观感不变）。
const List<double> _kScale = [1.0, kInboxStackScale, 0.92, 0.88, 0.84];

/// 连续深度 → 底边下移量（深度 1 沿用 [kInboxStackOffset] = 12）。
const List<double> _kDrop = [0.0, kInboxStackOffset, 20.0, 28.0, kInboxStackMaxDrop];

/// 连续深度 → 不透明度。深度 1 保持满不透明（下一张要读得清），
/// 深度 4 归零 = 「补充进栈的那张」的起点（浮现用）。
const List<double> _kAlpha = [1.0, 1.0, 0.94, 0.88, 0.0];

/// 推进起步延迟（按「结算后的深度」索引）：前排 0（立刻走），越深越晚起步 →
/// 末尾追上来，形成层次感。
///
/// ⚠️ 必须**非递减**：延迟小的层在任何时刻的进度都 ≥ 延迟大的层（可证：
/// `a ≤ b ≤ u ≤ 1` 时 `(u-a)/(1-a) ≥ (u-b)/(1-b)`），否则深层的**深度**会反超
/// 浅层（缩放更大）→ 后面的牌会从前面那张里冒出来。
const List<double> _kLag = [0.0, 0.12, 0.22, 0.30];

/// 按连续深度在表上做线性插值（表外取端点值）。
double _at(List<double> table, double depth) {
  if (depth <= 0) return table.first;
  final i = depth.floor();
  if (i >= table.length - 1) return table.last;
  return table[i] + (table[i + 1] - table[i]) * (depth - i);
}

/// 第 [index] 层在推进进度 `u`（0 = 起点，1 = 到位）下的**连续深度**。
double _depthAt(int index, double u) {
  final lag = _at(_kLag, math.max(index - 1, 0).toDouble());
  final t = ((u - lag) / (1 - lag)).clamp(0.0, 1.0);
  return index - kCurveOut.transform(t);
}

/// 队列前后是否只是「头部少了一张」（= 出栈）。
bool _isHeadRemoval(List<String> oldIds, List<String> newIds) {
  if (newIds.length != oldIds.length - 1) return false;
  for (var i = 0; i < newIds.length; i++) {
    if (newIds[i] != oldIds[i + 1]) return false;
  }
  return true;
}

/// 队列前后是否只是「头部多了一张」（= 撤销放回）。
bool _isHeadInsert(List<String> oldIds, List<String> newIds) {
  if (newIds.length != oldIds.length + 1) return false;
  for (var i = 0; i < oldIds.length; i++) {
    if (oldIds[i] != newIds[i + 1]) return false;
  }
  return true;
}

/// 队列内容是否逐项相同（**按对象身份**：条目是不可变值对象，页面只在
/// 追加/摘除时换列表，不会改条目本身）—— 用来决定后层的 widget 能否原样复用。
bool _sameItems(List<InboxItem> a, List<InboxItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

/// 卡片栈：把 [items][1..] 按深度铺在 [topCard] 之下，并负责「推进」动画。
///
/// 顶层由页面构建（它要挂手势与飞出装饰，见 `inbox_page.dart` 的
/// `_buildTopCard`）——本组件只铺后层 + 推进。
class InboxCardStack extends StatefulWidget {
  const InboxCardStack({
    super.key,
    required this.items,
    required this.topCard,
    required this.width,
    required this.style,
    this.advancing = false,
  }) : assert(items.length > 0, '空队列不该进卡片栈（页面走空态）');

  /// 待处理队列（index 0 = 队首 = 顶层，由 [topCard] 渲染）。
  final List<InboxItem> items;

  /// 顶层卡片（含手势、跟手位移/旋转、飞出与弹回装饰）。
  final Widget topCard;

  /// 卡片宽度（高度 = 宽 × [kInboxCardAspect]，见 [inboxCardHeight]）。
  final double width;

  /// 卡片版式（设置页可切换）。
  final InboxCardStyle style;

  /// 顶层是否**正在飞出**（= 刚提交了一张）。
  ///
  /// 由页面在「松手过了阈值、开始飞出」那一刻置起：推进与飞出并行 ——
  /// 顶层开始走，后层就开始往前顶（见文件头「与飞出并行」）。
  final bool advancing;

  @override
  State<InboxCardStack> createState() => _InboxCardStackState();
}

class _InboxCardStackState extends State<InboxCardStack>
    // 一个 State 生命周期内最多一个 controller（或者没有）→ Single 够用
    with SingleTickerProviderStateMixin {
  /// 推进进度 0→1（撤销时 1→0）。关动效时**恒为 null**（不建 ticker）。
  AnimationController? _advance;

  /// [MotionControl.of] 的当前值（didChangeDependencies 里刷新）。
  bool _motion = false;

  /// 是否多渲染一张（推进/退回期间；见文件头第 3 条）。
  bool _extra = false;

  /// 后层 widget 缓存：拖动期间页面每帧 `setState`，但**后层的版式子树一帧都
  /// 不该重建** —— 只要交回去的 widget 实例没变，`Element.updateChild` 会直接
  /// 跳过整棵子树（见文件头第 4 条）。失效条件：宽度 / 版式 / 动效开关 /
  /// 多渲染窗口 / 队列内容（[`_sameItems`]）变了。
  List<Widget>? _layers;
  List<InboxItem>? _layersItems;
  double? _layersWidth;
  String? _layersStyleId;
  bool? _layersMotion;
  bool? _layersExtra;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不在 initState 里查 MotionControl.of：它内部走 MediaQuery（祖先查找），
    // 在 initState 里做会直接断言。didChangeDependencies 同样在首帧前跑一次。
    final on = MotionControl.of(context);
    if (on == _motion) return;
    _motion = on;
    if (on) {
      _advance ??= AnimationController(vsync: this, duration: kDurAdvance)
        ..addStatusListener(_onAdvanceStatus);
      return;
    }
    // 关动效：连 controller 都不留（不是建了不 forward）
    _advance?.removeStatusListener(_onAdvanceStatus);
    _advance?.dispose();
    _advance = null;
    _extra = false; // 没有动画 → 不需要多渲染的那张
  }

  @override
  void dispose() {
    _advance?.removeStatusListener(_onAdvanceStatus);
    _advance?.dispose();
    _advance = null;
    super.dispose();
  }

  /// 反向（撤销）跑完 → 收起多渲染的那张。
  ///
  /// 正向（推进）到位时**不能**收：出栈那一帧才收（见 [didUpdateWidget]）。
  /// 收的时候那张恰好在深度 4 = 不透明度 0，所以看不出被收掉。
  void _onAdvanceStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !mounted || !_extra) return;
    setState(() => _extra = false);
  }

  @override
  void didUpdateWidget(covariant InboxCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 注意：didUpdateWidget 之后框架**必然**会再 build 一次（StatefulElement.update
    // → rebuild(force: true)），所以这里改字段不需要 setState。
    final c = _advance;
    if (c == null) {
      // 关动效：瞬时到位，没有可接管的动画
      _extra = false;
      return;
    }

    final oldIds = [for (final it in oldWidget.items) it.bvid];
    final newIds = [for (final it in widget.items) it.bvid];

    if (_isHeadRemoval(oldIds, newIds)) {
      // 出栈：推进早在「顶层开始飞出」时就跑完了（advancing），此刻 u = 1，
      // 各层实际位置已经等于「索引前移一位」后的静止位置 → 把 u 归零，
      // 位置逐层重合，看不出任何跳变。
      //（★ 前提：推进时长 ≤ 飞出时长，见 kDurAdvance。）
      c.value = 0;
      _extra = false; // 新尾巴已经落进静止窗口（min(len, 4)）里
      return;
    }
    if (_isHeadInsert(oldIds, newIds)) {
      // 撤销：反向播同一条推进 —— 后层退回原位。多渲染一张才能让「被顶开的
      // 那张」留在原位（它此刻在索引 4 = 深度 3，位置没变）。
      _extra = true;
      c.value = 1;
      c.reverse();
      return;
    }
    if (!_sameIds(oldIds, newIds)) {
      // 换数据（刷新 / 全部标记已读）：没有可续上的语义，直接到位
      c.value = 0;
      _extra = false;
    }
    // 顶层开始飞出 → 后层立刻向前推进（与飞出并行）
    if (widget.advancing && !oldWidget.advancing) {
      _extra = true;
      c.forward(from: 0);
    }
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 一层的形态：底边对齐的下移 + 以底边为锚的缩放 + 轻微降调。
  ///
  /// `Opacity` **一律**包上（即使不透明度是 1.0）：`RenderOpacity` 对 255 有
  /// 直通快路径，代价可忽略；而**保持树形稳定**才能让每层的 element 在
  /// 出栈/补卡时被按 key 复用（树形变来变去会重建子树、丢状态）。
  Widget _depthLayer(double depth, Widget child) => Opacity(
        opacity: _at(_kAlpha, depth),
        child: Transform.scale(
          scale: _at(_kScale, depth),
          // ★ 锚点必须是底边：居中缩放会让底边上收、把下移量吃掉（回归点）
          alignment: Alignment.bottomCenter,
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final c = _advance;
    // 渲染窗口：静止 = 前 kInboxStackCards 张；推进/退回期间**多带一张**
    //（它是「补充进栈」的那张：从深度 4 浮现，落到位时正好被收掉，不闪）
    final extra = c != null && _extra;
    final last = math.min(items.length, kInboxStackCards + (extra ? 1 : 0)) - 1;

    final layers = _layerWidgets(items, c, last, extra);
    return Stack(
      alignment: Alignment.topCenter,
      // 后层会伸到 Stack 框外（页面已按 kInboxStackMaxDrop 预留高度）→ 别裁
      clipBehavior: Clip.none,
      // 绘制顺序：深 → 浅，顶层最后画（盖住后层，只露出各层的边）
      children: [...layers, widget.topCard],
    );
  }

  /// 后层 children（深 → 浅）。命中缓存时**原样交回上一次的 widget 实例**。
  List<Widget> _layerWidgets(
    List<InboxItem> items,
    AnimationController? c,
    int last,
    bool extra,
  ) {
    final cached = _layers;
    if (cached != null &&
        _layersWidth == widget.width &&
        _layersStyleId == widget.style.id &&
        _layersMotion == _motion &&
        _layersExtra == extra &&
        _sameItems(_layersItems!, items)) {
      return cached;
    }
    final built = <Widget>[
      for (var i = last; i >= 1; i--) _buildLayer(items[i], i, c),
    ];
    _layers = built;
    _layersItems = items;
    _layersWidth = widget.width;
    _layersStyleId = widget.style.id;
    _layersMotion = _motion;
    _layersExtra = extra;
    return built;
  }

  Widget _buildLayer(InboxItem item, int index, AnimationController? c) {
    // ★ key 用 bvid：出栈/补卡时 Stack 的 children 会整体前移一位，
    //   没有稳定 key 就会把 element 按位置复用给另一张卡（动画错乱、入场重播）
    final key = ValueKey<String>('inbox.stack:${item.bvid}');
    final body = StaggeredEntrance(
      entryKey: 'bvid:${item.bvid}',
      index: index,
      child: IgnorePointer(
        // 后层不参与命中：拖动/点按永远只作用于顶层
        child: InboxSwipeCard(
          item: item,
          width: widget.width,
          style: widget.style,
        ),
      ),
    );
    if (c == null) {
      // 关动效：直接铺静止变换 —— 没有 controller、没有 AnimatedBuilder
      final d = index.toDouble();
      return Positioned(
        key: key,
        left: 0,
        right: 0,
        bottom: -_at(_kDrop, d),
        child: _depthLayer(d, body),
      );
    }
    return AnimatedBuilder(
      key: key,
      animation: c,
      // ★ 必须传 child：推进期间不逐帧重建卡片版式子树（只重建位置/缩放包装）
      child: body,
      builder: (_, child) {
        final d = _depthAt(index, c.value);
        return Positioned(
          left: 0,
          right: 0,
          bottom: -_at(_kDrop, d),
          child: _depthLayer(d, child!),
        );
      },
    );
  }
}
