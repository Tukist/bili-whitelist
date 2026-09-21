/// 信箱页（v2.13.0+ 起）：白名单 UP 主的新视频。
///
/// ## Tinder 式卡片栈（v2.19.0+，v2.22.0+ 起多层）
/// 未读不再是一条条列表项，而是**一叠卡片**：
/// - **一叠牌**：顶层之下同时铺着后 3 张（越深越小/越低/越淡），
///   各层一律**底边对齐**（`Positioned(bottom: -下移量)` + 以底边为锚缩放）→
///   净露出量恒等于该层的下移量，与卡片内容高度（标题 1 行 / 2 行）无关
///   （旧实现「固定下移 + 居中缩放」在下一张更矮时会被完全盖住）；
/// - **一张划走、下一张向前推出**：顶层飞出与后层推进**并行**（[kDurAdvance]
///   略早于飞出收尾），后层按深度错峰推进、末尾追上来，栈底同时补一张新的
///   （从更深更淡处浮现），全程无跳变；拖动跟手期间后层不动。
///   实现与参数表见 `widgets/inbox_card_stack.dart`（别在本文件里重写这套几何）；
/// - 顶层卡片跟随手指**四个方向**拖动（位移按手指的真实二维位移走，旋转仍只看
///   水平分量），松手按阈值判定。四向 = **四个不同的行为**，不是两对镜像：
///   - **右滑 = 加入白名单**（未分类）、**左滑 = 跳过**（只记已处理，不再出现）；
///   - **下滑 = 稍后**（用户原话：「**下滑不是跳过，而是暂时不判断，先看后面的
///     卡片，可以上滑回来**」）—— 把这张从队首**推到队尾**、不做任何判断，
///     于是后面那张顶上来；这张之后还会再出现（它一直在队列里）；
///   - **上滑 = 取回** —— 把最近一次被「稍后」推后的那张拿回**栈顶**
///     （LIFO，可连续取回），同样不写任何东西；
///   - 没过阈值 → 弹回原位；
/// - 「快速轻扫」四个方向都算数（v2.32.0+）：位移没过距离阈值但**甩得够快**
///   （同一对阈值横竖共用，见 [_onDragEnd]）→ 照样判定。斜着划按**主导轴**
///   （位移更大的那根轴）决定这次算哪个方向 —— 不会两边都不算，也不会一次
///   触发两个动作；
/// - 方向 → 行为**只在 [_actionForEdge] 一处**（别在别处再写一份映射）。
///   ⚠️ v2.32.0 在这里放过一个 `kInboxSwipeUpMeansLike` 布尔开关（"上滑 = 加入"），
///   那是把产品意图理解错了：上下滑现在是「稍后 / 取回」两件不同的事，**不是**
///   一对可以互换的「加入 / 跳过」，所以那个开关已经删掉，别再捡回来；
/// - ★ 侧效应：卡片上的上下拖被判定手势吃掉（纵向拖动识别器在手势竞技场里
///   胜出，见 [_buildTopCard]）→ **下拉刷新要从卡片外的留白发起**；
/// - 底部另有「跳过」/「加入」两个 ≥48dp 的按钮（不习惯滑的人 / 无障碍），
///   与滑动等价（**只等价于左右滑**：稍后 / 取回没有按钮，它们是"先放一放"
///   的辅助手势，不是判定）；右下角「撤销」可把上一张放回来（飞回来 + 后层
///   退回，见 [_undoLast] 的说明）；
/// - 点按卡片仍然是老行为：打开播放页（与拖动手势由手势竞技场区分：
///   位移超过 touch slop 只能有一条胜出，所以「点」不会误触发拖动，
///   「拖」也不会误触发打开）。
///
/// ## 卡片比例与版式（v2.21.0+）
/// - 卡片固定为**扑克牌比例**（宽 : 高 = 1 : [kInboxCardAspect] = 1 : 1.39，
///   63:88）：宽度仍取「屏宽 × 0.88 封顶 420」，高度由比例算出；
///   屏太矮时**等比**缩小（比例不变），所以「不出屏」与「下一张露一条边」
///   两个性质都还在；
/// - 卡面排版有多个**风格**（全出血渐变 / 编辑排版 / 宝丽来 / 沉浸横幅 /
///   极简留白，见 `widgets/inbox_card_styles.dart`），在「个人」页设置区
///   「信箱卡片样式」里可**预览 + 切换**，选择持久化在
///   [InboxCardStyleStore]；本页用 [ListenableBuilder] 监听它 →
///   切换后卡片栈立即换版式（所有风格同尺寸，不跳动）。
///
/// ## ★ 后台检查不阻塞交互（v2.19.x）
/// `checkAll` 要串行遍历白名单 UP 主（每个间隔 ≥1.5s），100 个 UP 主要跑几分钟。
/// 这期间：
/// - 顶部 AppBar 显示一行「检查中…」（[_busyNote]），**仅提示、不禁用任何操作**；
/// - 用户照样能**划卡、点卡开播放页、撤销**（[_openItem] 只由 [_opening] 防连点）；
/// - 检查完成时用 [_mergeChecked] 合并结果：**只把新出现的条目追加到队尾**，
///   已经在队列里的、以及本次会话里被消费掉的（[_consumedBvids]）一律跳过 →
///   卡片栈**不会跳回第一张**，用户划过的不复活；
/// - ★ **检查进行中也会把新条目送进来**（[_pollProgress]）：服务层是"边查边
///   落盘"的（每查完一个 UP 主就写一次本地未读），本页每隔几秒**只读盘、不触网**
///   回读一次并追加进卡片栈 —— 老实现要等整轮 checkAll 求值回来才合并，一轮
///   几分钟期间用户只能看到缓存快照（表现为"一次只见一张，退出重进才见下一张"）；
/// - 服务层配合：写盘前按最新「已处理」记录再过滤一次（见 `inbox_service.dart`
///   的「并发」小节），红点数与页面上这条队列保持一致。
/// 队列被清空（用户划完最后一张）而检查还在跑时，显示**空态**而不是整页加载态
/// （[_loadedOnce] 区分「划完了」与「还没加载出来」）。
///
/// ## 陈旧白名单提示（v2.48.0）
/// 信箱**消费白名单快照**（`InboxService.checkAll` 内部走 `syncService.sync()`
/// 拿 `data.upowners`）：快照陈旧 = 名单里少几个 UP 主 → 他们的新视频不会被
/// 发现。所以检查完一轮后，若 `WhitelistFreshness.instance.isStale` 为真，
/// 页面顶部常驻一条 [StaleSyncBanner]（挂在滚动容器之外，不随队列滚走）。
/// 它的「立即同步」接的是 [_resyncWhitelistOnly]（**只跑白名单同步**），
/// 刻意不复用 [_checkNow] —— 后者是一轮几分钟的全量检查。
///
/// ## 空态也保留撤销入口
/// 划掉最后一张后底部栏整体消失、撤销不回来是可用性缺陷：空态下改为
/// 「细线插画 + 一行只有『撤销上一张』的底栏」（[_buildBottomBar] `hasCards: false`）。
///
/// ## 缺陷修复（同批）
/// `checkAll` 不再把「看到新视频」当成「已读」（详见 `inbox_service.dart`）。
/// 页面侧配合两点：
/// - `checkAll` 返回的 `failed`（sync 整体失败）→ **保留上次列表** + 提示错误，
///   不再把画面清空；
/// - 每滑一张 → `InboxService.markHandled(bvid)`：记「已处理」+ 从本地未读里
///   摘掉 → 首页红点立刻下降。
///
/// ## 动效与测试
/// - **一次滑动分两段**（v2.36.0）：
///   1. **推进段**（`0 → kDurAdvance`，140ms）：飞出的那张还是顶卡，后层同时
///      往前顶（[InboxCardStack] 的推进）；这一段里新手势会被 `_busy` 挡住 ——
///      此时顶卡正飞在半路、下一张还没长到位，"抓住下一张"在画面上不成立；
///   2. **幽灵段**（`kDurAdvance → 出屏时长`）：到推进到位那一刻把飞出的那张
///      **从队列里摘出去**（[_handOff]），交给画在整叠牌之上的**幽灵层**
///      （[_buildGhost]，[IgnorePointer] 不吃手势）继续飞完。于是
///      `_items.first` 立刻就是新的顶卡 → **松手 140ms 后就能拖下一张**，
///      连续跳过快划不再"划了没反应"（旧实现整段飞出都锁输入：
///      上滑取回两步动画加起来 ~400ms 全程锁）。
/// - 飞出时长按**距离**给（[inboxExitMotion]）：水平 = 1.4 × 屏宽 / [kDurSlow]；
///   竖直 = 1.0 × 屏高 / 等比例放大的时长 → 四个方向出屏速度一致
///   （旧实现竖直距离 1.4 × 屏高、时长却与水平一样 → 竖直快一倍，"嗖一下没了"）；
/// - 回弹 / 取回滑入 / 撤销飞回用 [kDurBase]，**回弹半路可以被新手势接管**
///   （[_takeOverBackAnimation]：手指落下就从当前画面位置接着走）→ 锁输入的时间
///   只有"手指还没落下"那一下；取回的第一步（让手上这张让位）用 [kDurQuick]，
///   它就是取回这条路的锁输入时长（120ms）；
/// - [MotionControl.of] 为 false（`flutter test` 默认 / 系统「减少动画」）时
///   **连 AnimationController 都不建**（本页的飞出/幽灵、卡片栈的推进都是），
///   松手即交接、即出栈 —— `pumpAndSettle` 必然收敛；
/// - 卡片子树挂在 `AnimatedBuilder` 的 `child:` 上，飞出/推进期间不逐帧重建；
/// - 拖动期间不触发任何网络/存储请求，动作只在松手后执行。
///
/// ## 连续判定与并发写（v2.36.0）
/// 输入解锁后"连划两张右滑"会**并发两次 Gist 写**（`WhitelistWriter.addVideo`
/// 是"GET 整份查重 → PATCH 整份"的 read-modify-write，两次并行会互相覆盖、
/// 静默丢一条视频）。处理方式：把串行闸门放在**写入服务内部**
/// （`whitelist_writer.dart` 的 `_chain`）—— 它同时罩住搜索页「加入」、UP 主页
/// 长按加入、链接导入等一切共用该服务的入口，比在本页加一把锁覆盖得全。
/// 判定本身（出栈、记已处理）照旧**立刻**生效，只有"写白名单"这一步排队，
/// 用户感觉不到等待。为什么没复用 `WhitelistWriteQueue`：见该字段的注释
/// （它只能串行"已知快照"的 PATCH，挡不住两次 GET 读到同一份旧快照）。
///
/// ## 既有锚点（别动）
/// 空态 [AppStateView]`copyId: 'empty.inbox'`、首屏 [AppLoadingHero]`seed: 'inbox'`
/// （`scrollable: true`，因为宿主是 [RefreshIndicator]）、错误态 [AppErrorView]
/// 的「重试」、下拉刷新。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/live_status.dart';
import '../services/inbox_card_style_store.dart';
import '../services/inbox_service.dart';
import '../services/service_locator.dart';
import '../services/whitelist_writer.dart';
import '../sync/whitelist_freshness.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/inbox_card_stack.dart';
import '../widgets/inbox_card_styles.dart';
import '../widgets/inbox_swipe_card.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/stale_sync_banner.dart';
import 'live_player_page.dart';
import 'player_page.dart';
import 'upowner_page.dart' show LiveNowBadge;

/// 底部按钮行的高度（用于给卡片区留出高度预算）。
///
/// 两种形态同高：有卡片 = 48dp 按钮 + 12 + 16；空态 = 48dp「撤销上一张」+ 12 + 16。
/// 另外还要给「后层卡片按深度下移」留量（[kInboxStackMaxDrop]），见 [_buildDeck]。
const double _kBottomBarH = 76;

/// 未配置 GitHub 时的门禁提示（与搜索页 / 管理页文案一致）。
const String _kConfigHint = '请先到底部导航「个人」页配置 GitHub token 与 Gist ID';

/// 水平飞出的距离倍数（× 屏宽）。**既有值，别动**：它是"出屏"这件事的
/// 观感基准，竖直方向的时长就是按它等比折算的（见 [inboxExitMotion]）。
const double kInboxExitRatio = 1.4;

/// 一出屏的**位移**与**时长**（纯函数，测试可直接断言"四向出屏速度一致"）。
///
/// - **水平**：距离 = 屏宽 × [kInboxExitRatio]，时长 = [kDurSlow]（既有值）；
/// - **竖直**：距离 = **1.0 × 屏高** —— 卡片顶边恒在屏内（≥ 0）处，往下推满
///   一屏高就必然整张出屏；旧值 1.4 × 屏高**多推了 40%**，白跑一截。
///   时长按 `水平时长 × 竖直距离 / 水平距离` 等比给。
///
/// ★ 这是"垂直比水平快一倍"的根治：旧实现竖直距离是水平的 h/w 倍（411×914 上
/// 约 2.2 倍）、时长却和水平一样长 → 上下滑时卡片"嗖一下没了"，而连续上下切换
/// 时又因为下一张的锁定期同样长而显得迟钝。现在四个方向**出屏速度一致**
/// （竖直只是"走得远、所以走得久"）。
///
/// [perp] = 另一根轴上保留的余量（斜着划时卡片跟着偏，与改动前的观感一致）。
({Offset offset, Duration duration}) inboxExitMotion({
  required Size screen,
  required bool vertical,
  required bool positive,
  double perp = 0,
}) {
  final ref = screen.width * kInboxExitRatio;
  final dist = vertical ? screen.height : ref;
  final main = positive ? dist : -dist;
  return (
    offset: vertical ? Offset(perp, main) : Offset(main, perp),
    duration: Duration(
      microseconds: (kDurSlow.inMicroseconds * dist / ref).round(),
    ),
  );
}

/// 正在飞出的那张（**已经交接**：从 [_InboxPageState._items] 里摘出去了）。
///
/// 它就是"松手后立刻能拖下一张"的关键：飞行观感还在（画在整叠牌之上、由
/// [_InboxPageState._ghostFly] 独立驱动），但**不吃手势**、也不占队列的队首 ——
/// 新顶卡因此可以马上开始下一次拖动。
class _GhostExit {
  _GhostExit({
    required this.item,
    required this.edge,
    required this.from,
    required this.to,
    required this.action,
    required this.badge,
    required this.badgeProgress,
    required this.vertical,
  });

  final InboxItem item;

  /// 朝哪一边飞出去的（只用于 debugPrint / 断言）。
  final _SwipeEdge edge;

  /// 飞出区间（松手那一刻的位移 → 屏外），与顶卡飞出的那一段**完全同一组端点**：
  /// 交接时把 [_InboxPageState._fly] 的进度原样交给 [_InboxPageState._ghostFly]，
  /// 位置逐帧连续（不会在交接那一帧"跳一下"）。
  final Offset from;
  final Offset to;

  /// 这次判定是什么（稍后 / 加入 / 跳过）——落地时要按它决定"要不要把这张
  /// 插回队尾"（稍后要，判定掉的不要）。
  final InboxSwipeAction action;

  /// 交接那一刻钉住的浮层（徽标 + 渐显进度 + 是否竖直）：飞行途中它一直亮着
  /// （沿用"飞出时徽标钉在松手那一刻"的既有观感），下一张顶卡的浮层则归零。
  final InboxSwipeAction? badge;
  final double badgeProgress;
  final bool vertical;

  /// 幽灵卡在进度 `t ∈ [0,1]` 时的位移（与顶卡飞出用同一条曲线 [kCurveOut]）。
  Offset offsetAt(double t) => Offset.lerp(from, to, kCurveOut.transform(t))!;
}

/// 检查进行中「回读本地未读」的间隔（见 [_InboxPageState._pollProgress]）。
///
/// 服务层是"边查边落盘"的（每个 UP 主查完就写一次未读），而一轮遍历里每个
/// UP 主间隔 ≥1.5s（风控时 3s）——3s 回读一次足够跟上进度，又不至于频繁重建
/// 卡片栈。
const Duration _kProgressPoll = Duration(seconds: 3);

/// 一次拖动最终落在**哪一边**（四根箭头）。
///
/// 和 [InboxSwipeAction] 分开：行为只有四个，而「哪一边」还要决定卡片往哪飞出、
/// 徽标怎么摆、撤销时从哪飞回来 —— 那些都是方向信息，不能在折算成行为时就丢掉
/// （例：下滑「稍后」是往下飞出，上滑「取回」是让卡**从下方**滑回来，两者都读
/// 方向，但行为完全不同）。
enum _SwipeEdge { left, right, up, down }

/// 方向 → 行为：**全页唯一的映射点**（别在别处再写一份映射）。
///
/// ★ 用户原话（v2.32.1 订正语义）★
/// 「**下滑不是跳过，而是暂时不判断，先看后面的卡片，可以上滑回来**」
///
/// → 所以四向是**四件不同的事**（详见 [InboxSwipeAction]）：
/// - 右滑 = [InboxSwipeAction.like] 加入白名单（既有语义）
/// - 左滑 = [InboxSwipeAction.skip] 跳过：记「已处理」，不再出现（既有语义）
/// - 下滑 = [InboxSwipeAction.defer] **稍后**：推到队尾、不做判断，之后还能看到
/// - 上滑 = [InboxSwipeAction.restore] **取回**：把最近推后的那张拿回栈顶
///
/// ⚠️ 这里**不该**再有「把上下滑对调」的布尔开关（v2.32.0 的
/// `kInboxSwipeUpMeansLike` 已删）：稍后 / 取回不是一对互逆的判定动作，
/// 它们是两个独立的、都不写数据的手势。
InboxSwipeAction _actionForEdge(_SwipeEdge edge) => switch (edge) {
      // 水平：右 = 加入、左 = 跳过（既有语义，别动）
      _SwipeEdge.right => InboxSwipeAction.like,
      _SwipeEdge.left => InboxSwipeAction.skip,
      // 竖直：下滑 = 稍后（不判断）、上滑 = 取回
      _SwipeEdge.down => InboxSwipeAction.defer,
      _SwipeEdge.up => InboxSwipeAction.restore,
    };

/// 行为 → 中文名（只用于 debugPrint 与注释，让 logcat 里的人话和语义对得上）。
String _actionLabel(InboxSwipeAction action) => switch (action) {
      InboxSwipeAction.like => '加入',
      InboxSwipeAction.skip => '跳过',
      InboxSwipeAction.defer => '稍后',
      InboxSwipeAction.restore => '取回',
    };

/// 方向 → 短名字（只给 debugPrint 用：`edge=down` 比 `edge=_SwipeEdge.down` 好读，
/// `adb logcat | grep '\[inbox\] 判定'` 一眼能对上手势与行为）。
String _edgeLabel(_SwipeEdge edge) => switch (edge) {
      _SwipeEdge.left => 'left',
      _SwipeEdge.right => 'right',
      _SwipeEdge.up => 'up',
      _SwipeEdge.down => 'down',
    };

/// 当前正在跑的动画类型。
enum _SwipeAnim {
  /// 飞出屏幕
  exit,

  /// 弹回原位
  back,
}

/// 刚处理掉的一张（撤销用）。
class _SwipeRecord {
  const _SwipeRecord(this.item, {required this.edge});

  final InboxItem item;

  /// 它是朝**哪一边**飞出去的（撤销时从同一侧飞回来，见 [_undoLast]）。
  final _SwipeEdge edge;

  /// true = 加入（右滑，可能已写白名单），false = 跳过（左滑）。
  /// 不单独存：行为一律由方向经 [_actionForEdge] 折算，免得两处说法打架。
  /// 注意：只有「加入 / 跳过」会进撤销位 —— 下滑「稍后」不进（它是靠上滑
  /// 「取回」回来的，见 [_deferred]）。
  bool get liked => _actionForEdge(edge) == InboxSwipeAction.like;
}

class InboxPage extends StatefulWidget {
  const InboxPage({super.key, this.api, this.writer});

  /// 测试用：注入 B 站接口（点按卡片打开播放页、右滑加入取元数据）。
  final BiliApi? api;

  /// 测试用：注入白名单写入器（右滑加入）。
  final WhitelistWriter? writer;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage>
    // 两个 controller：顶卡（[_fly]）与幽灵卡（[_ghostFly]）要同时跑 —— 后者是
    // "飞出的那张继续飞"、前者要能立刻接住新手势 → 不能用 Single
    with TickerProviderStateMixin {
  late final BiliApi _api = widget.api ?? BiliApi();
  late final WhitelistWriter _writer = widget.writer ?? WhitelistWriter();

  /// 待处理队列（未读，按发布时间倒序；队首 = 顶层卡片）。
  List<InboxItem> _items = [];

  /// 后台任务提示文案（null = 没有任务在跑）。
  ///
  /// ★ 只驱动 AppBar 上那一行小字，**不参与任何交互门禁**：检查/标记期间
  /// 用户照样能划卡、点卡、撤销（见文件头「后台检查不阻塞交互」）。
  String? _busyNote;
  String? _error;

  /// 上一轮检查时白名单快照是否被**确证**陈旧（v2.48.0）。
  ///
  /// 信箱**确实消费白名单快照**（`InboxService.checkAll` 内部的
  /// `syncService.sync()` 拿 `data.upowners`）：快照陈旧 = 少几个 UP 主 →
  /// 他们的新视频根本不会被发现，所以"这份白名单是旧的"值得常驻提示。
  ///
  /// 取值只能读单例 [WhitelistFreshness]（[InboxCheckResult] 里没有 `stale`
  /// 字段，透传不过去）；页面存一份 bool 是因为那个单例不是 ChangeNotifier
  /// （build 时读它拿不到"判定变了、横幅该消失"的信号）——与首页 `_stale`
  /// 同一套理由。`checkAll` 命中"缓存够新"的节流分支时会早退、不再 sync，
  /// 此时单例保留上一次的判定，与"屏幕上这份快照是哪一份"仍然一致。
  bool _stale = false;

  /// 检查进行中周期性回读本地未读的定时器（见 [_pollProgress]；dispose 取消）。
  Timer? _progressTimer;

  /// 是否有后台任务在跑（checkAll / markAllRead）。
  bool get _checking => _busyNote != null;

  /// 是否已经拿到过至少一次「队列」结果（本地缓存非空，或 checkAll 跑完）。
  ///
  /// 用来区分两种「空队列」：**用户刚划完最后一张**（→ 直接显示空态，
  /// 而不是整页加载态）与**首次进入还没加载出来**（→ 整页加载态）。
  bool _loadedOnce = false;

  /// 本次页面会话里被用户消费掉的 bvid（撤销会移出）。
  ///
  /// `checkAll` 与用户操作可以并行（一轮检查可能几分钟）：它返回的列表是
  /// 「检查过程中读到的队列」，可能包含刚被划走的条目。合并时按这份记录
  /// 过滤，已消费的条目不复活。
  ///
  /// ★ 只有**左滑跳过 / 右滑加入**才进这份记录 —— 下滑「稍后」**绝不**记进来
  /// （它不是判定，那张必须还能再看到）。
  final Set<String> _consumedBvids = <String>{};

  /// 「稍后」推后的卡片（**栈**，LIFO）：上滑「取回」时从栈顶拿回最近的一张。
  ///
  /// 关键约定（改这里之前先读这条）：
  /// - 被推后的卡**一直留在 [_items] 里**（只是排到了队尾）→ 用户"先看后面的
  ///   卡片"之后，它照样会随着队列转回来；这份记录只是为了记**取回的顺序**；
  /// - 它**不进** [_consumedBvids]、不调 `markHandled`、不写 Gist、不取元数据
  ///   （用户原话：「暂时不判断」）；
  /// - 一张卡在这份记录里最多出现一次（再次下滑时挪到栈顶，见 [_settleExit]）；
  /// - 判定掉（加入 / 跳过）、撤销、全部标记已读时把它清出来（见各处调用点）——
  ///   否则上滑会把一张已经处理掉的卡再搬回栈顶。
  final List<InboxItem> _deferred = <InboxItem>[];

  /// 正在 fetch view 元数据（防连点重复 push 播放页）。
  bool _opening = false;

  /// 交错入场的「已入场」账本：卡片被重建（换一张）时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 顶层卡片作者的「正在直播」状态（v2.25.2+；null = 没在播 / 还没查到 /
  /// 查失败——都不显示标记）。只查**队首这一张**（见 [_loadTopLive]）。
  LiveStatus? _live;

  /// 拖动位移：**两个轴都跟手**（松手前实时跟随手指；松手后由动画接管）。
  /// 旋转仍只看 [Offset.dx]（见 [_decorate]），倾斜手感与只有左右滑时一致。
  Offset _drag = Offset.zero;

  /// 主指针上一次的**全局**位置（见 [_onDragStart] / [_onDragUpdate]）。
  ///
  /// 为什么记位置而不用 `details.delta`：单轴的拖动识别器交给回调的 `delta`
  /// 已被它**按轴裁过**（水平识别器的 `delta.dy` 恒为 0，见 flutter 的
  /// `HorizontalDragGestureRecognizer._getDeltaForDetails`）→ 只靠它累不出
  /// 真正的二维位移。`globalPosition` 是手指的真实位置，两次相减就是真实位移。
  Offset? _pointer;

  /// 浮层标记：当前这次拖动 / 飞出落在**哪个动作**上（null = 不显示浮层）
  /// 与它的渐显进度（拖动时实时更新；飞出时钉在松手那一刻的值）。
  InboxSwipeAction? _reaction;
  double _reactionProgress = 0;

  /// 当前这次拖动 / 飞出是不是**竖直主导**的（决定徽标摆哪、斜不斜，
  /// 见 `InboxSwipeCard.reactionVertical`）。飞出期间沿用松手那一刻的值。
  bool _vertical = false;

  /// 动画区间（[_SwipeAnim.exit] 与 [_SwipeAnim.back] 共用一对端点）。
  Offset _animFrom = Offset.zero;
  Offset _animTo = Offset.zero;

  /// 当前动画类型；null = 静止（位移直接用 [_drag]）。
  _SwipeAnim? _anim;

  /// 飞出/弹回动画控制器（**只管顶卡**）；关动效时**恒为 null**（不建 ticker）。
  AnimationController? _fly;

  /// 幽灵卡（[ _ghost]）的飞出控制器：与 [_fly] 分开 —— 交接之后"飞出的那张继续飞"
  /// 与"新顶卡跟手/再飞出"必须能同时进行（见 [_handOff]）。
  /// 关动效时**恒为 null**（没有幽灵层）。
  AnimationController? _ghostFly;

  /// 正在飞出的那张（已交接；null = 没有幽灵在飞）。同一时刻**最多一个**，
  /// 见 [_handOff] 里"上一个幽灵还没落地就延后交接"的策略。
  _GhostExit? _ghost;

  /// 本次判定的头卡**是否已经交接给幽灵层**（见 [_handOff]）。
  ///
  /// 交接点 = 后层推进到位（[kDurAdvance]）；关动效时松手即交接。
  bool _exitRetired = false;

  /// [MotionControl.of] 的当前值（didChangeDependencies 里刷新）。
  bool _motion = false;

  /// 正在提交（门禁检查/飞出中）→ 阻止重复触发。
  bool _deciding = false;

  /// 正在飞出的那张朝**哪一边**（[_commitExit] 结算用；也决定飞出方向）。
  _SwipeEdge? _exiting;

  /// 正在飞出的那张对应**哪个行为**（[_commitExit] 靠它分流：稍后 vs 判定）。
  InboxSwipeAction? _exitingAction;

  /// 「取回」的两步动画走到第二步了：手上这张弹回原位结束之后，接着把推后的
  /// 那张从下方滑回栈顶（见 [_restoreTop] / [_applyRestore]）。
  ///
  /// 为什么分两步：用户原话是「可以**上滑回来**」，所以要让人明确看见「有**一张
  /// 卡回来**」，而**不能**做成"当前这张被判定/飞走"。先让手上这张稳稳弹回原位
  /// （它没被判定），再让取回的那张滑进来盖住它。
  bool _restorePending = false;

  /// 「取回」的打点（每取回一次 +1，交给 [InboxCardStack.restoreTick]）。
  ///
  /// 取回是「长度不变的队首换人」，卡片栈认不出 id 序列，只能靠这个显式打点
  /// 才知道该反播一次「后层退回原位」。
  int _restoreTick = 0;

  /// 上一张（撤销用）。
  ///
  /// ★ **栈**（v2.36.0 起可连撤）：输入解锁后用户会连着划好几张，只留一张的话
  /// "撤销上一张"按一次就用完了（第二张永远撤不回来）。判定掉的卡按顺序压栈，
  /// 每次撤销弹栈顶那张放回队首 —— 连撤 N 次就逐张退回去（LIFO，与直觉一致）。
  /// 上限 [_kMaxUndo] 条：够连撤了，也不让会话内存无界增长（每张只是一个
  /// 不可变的 [InboxItem] 引用，但没必要留着整场会话的所有历史）。
  final List<_SwipeRecord> _undoStack = <_SwipeRecord>[];

  /// 撤销栈上限（见 [_undoStack]）。
  static const int _kMaxUndo = 20;

  /// 现在是否有可撤销的（底部按钮的可用性就靠它）。
  bool get _canUndo => _undoStack.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _refreshItems();
    _checkNow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final on = MotionControl.of(context);
    if (on == _motion) return;
    _motion = on;
    if (on) {
      _fly ??= AnimationController(vsync: this, duration: kDurSlow)
        ..addStatusListener(_onFlyStatus)
        // 逐帧检查"后层推进到位了没" → 到点就把飞出的那张交接出去
        // （交接之后顶卡换人、新手势立刻可用，见 [_onFlyTick]）
        ..addListener(_onFlyTick);
      _ghostFly ??= AnimationController(vsync: this, duration: kDurSlow)
        ..addStatusListener(_onGhostStatus);
      return;
    }
    // 关动效：连 controller 都不留（不是建了不 forward），并立刻收尾
    //（此刻若还有幽灵在飞，先让它**落地**：「稍后」的那张必须回队尾，
    // 否则它会凭空消失 —— 这里不能 setState，紧接着就会 build）
    final flying = _ghost;
    if (flying != null) {
      _ghost = null;
      if (flying.action == InboxSwipeAction.defer) _reinsertDeferred(flying.item);
    }
    _fly?.removeListener(_onFlyTick);
    _fly?.dispose();
    _fly = null;
    _ghostFly?.removeStatusListener(_onGhostStatus);
    _ghostFly?.dispose();
    _ghostFly = null;
    _ghost = null;
    _anim = null;
    _exitRetired = false;
    _restorePending = false;
    _resetGestureState();
  }

  @override
  void dispose() {
    _stopProgressPolling();
    _fly?.removeStatusListener(_onFlyStatus);
    _fly?.removeListener(_onFlyTick);
    _fly?.dispose();
    _fly = null;
    _ghostFly?.removeStatusListener(_onGhostStatus);
    _ghostFly?.dispose();
    _ghostFly = null;
    _ghost = null;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 数据
  // ---------------------------------------------------------------------------

  /// 只刷新缓存条目（不触网）。
  Future<void> _refreshItems() async {
    final items = await ServiceLocator.inboxService.getItems();
    if (!mounted) return;
    setState(() {
      // 本地缓存里已经有卡片 → 记「拿到过队列结果」：此后队列被划空时显示
      // 空态，而不是转圈等 checkAll
      if (items.isNotEmpty) _loadedOnce = true;
      _items = _mergeChecked(items);
    });
    unawaited(_loadTopLive());
  }

  /// 查**队首那张卡片**作者的「正在直播」状态（信箱上的开播角标，v2.25.2+）。
  ///
  /// 取舍（为什么只查队首这一张）：一叠卡片同一时刻只看得见顶卡，而 live
  /// 接口风控很严——绝不为一整队未读逐张轰炸。用户每划走一张，顶卡换人，
  /// 这里再补一次查询（见 [_commitExit] / [_undoLast] 的调用点）。
  ///
  /// 一律走 [LiveStatusHub.instance]：会话内缓存（同一 UP 主只查一次）+
  /// **串行 + 相邻请求间隔 ≥1.5s** + **失败静默**（查不到就是没角标）。
  /// 只有 `liveStatus == 1`（真的在播）才显示；**轮播（2）不显示**。
  Future<void> _loadTopLive() async {
    final item = _items.isEmpty ? null : _items.first;
    if (item == null || item.upMid <= 0) {
      if (mounted && _live != null) setState(() => _live = null);
      return;
    }
    final status = await LiveStatusHub.instance
        .statusOf(item.upMid, fetch: _api.fetchLiveStatusByMid);
    if (!mounted) return;
    // 等待期间卡片可能已被划走 / 撤销 → 只在「查的还是当前顶卡作者」时上屏
    final cur = _items.isEmpty ? null : _items.first;
    if (cur == null || cur.upMid != item.upMid) return;
    setState(() => _live = status);
  }

  /// 点开播角标 → **站内**直播播放页（v2.27.0+，[LivePlayerPage]）。
  ///
  /// 信箱是 Tinder 卡片：卡片本体已注册 onTap（开播放页）与 onHorizontalDrag*，
  /// 内层角标的点击在手势竞技场里自己胜出（v2.25.2+ 实测可行）。**长按次级
  /// 入口（跳站外浏览器）这里刻意不做**——长按与卡片拖拽/飞出的手势面重叠风险
  /// 高，而信箱只是"顺手看一眼"，站内播不了还有 UP 主页那条路。
  Future<void> _openLive(LiveStatus status) async {
    if (status.roomId <= 0) return;
    final item = _items.isEmpty ? null : _items.first;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        // 借用播放页的路由名：享受那套「快速淡入」转场（见 app_theme 按路由名
        // 分流）
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => LivePlayerPage(
          roomId: status.roomId,
          title: status.title,
          upName: item?.upName ?? '',
          upMid: item?.upMid ?? 0,
        ),
      ),
    );
  }

  /// 把一份「服务端 / 缓存的队列」并进当前队列。
  ///
  /// ★ 只增不改（并发要求）：已经在队列里的、以及本次会话里被用户消费掉的
  /// （[_consumedBvids]）一律跳过；新出现的条目**追加到队尾**。刻意不重排、
  /// 不覆盖：一轮 [InboxService.checkAll] 可能跑几分钟，期间用户已经划走了
  /// 几张，重排会让卡片栈跳回第一张、覆盖会让划过的不复活。
  List<InboxItem> _mergeChecked(List<InboxItem> incoming) {
    final known = {for (final it in _items) it.bvid};
    final merged = List<InboxItem>.of(_items);
    for (final it in incoming) {
      if (it.bvid.isEmpty) continue;
      if (_consumedBvids.contains(it.bvid)) continue;
      if (!known.add(it.bvid)) continue; // 已在队列里（add 返回 false）
      merged.add(it);
    }
    return merged;
  }

  /// 触发 checkAll(force=true) 并刷新本地列表。
  ///
  /// ★ 不阻塞交互：检查期间用户可以继续划卡 / 点开播放页 / 撤销，只在 AppBar
  /// 上给一行「检查中…」。结果走 [_mergeChecked]（只追加新条目），当前正在
  /// 看的那张不会跳回第一张。
  ///
  /// ★ 检查**进行中**也会把新条目送进卡片栈：见 [_pollProgress]（服务层是
  /// "边查边落盘"的）。一轮遍历可能几分钟，如果只靠这里 await 回来的那一次
  /// 合并，用户就得等整轮跑完才看到新卡（老表现：一次只见一张、退出重进才见
  /// 下一张）。
  ///
  /// 检查完成前页面就被离开也不用担心丢结果：条目已在 prefs 里，重进页面时
  /// [_refreshItems] 照样读得到（这里只是不再 setState）。
  Future<void> _checkNow() async {
    setState(() {
      _busyNote = '检查中…';
      _error = null;
    });
    _abortSwipe();
    _startProgressPolling();
    try {
      final result = await ServiceLocator.inboxService.checkAll(force: true);
      if (!mounted) return;
      setState(() {
        // ★ 失败时 result.items 就是「上次缓存」——照样并进列表，
        //   绝不用空列表把画面打空（错误只在列表本身为空时占满整页）
        _busyNote = null;
        _loadedOnce = true;
        _error = result.failed ? result.message : null;
        // 这一轮用到的白名单快照新不新（判据由服务打标，这里只搬进 state）。
        // ★ 失败分支**不改**它：屏幕上的队列没变，"这份快照旧不旧"与"这次
        //   检查成不成"是两件事（与首页 `_load` 的同一约定）。
        _stale = WhitelistFreshness.instance.isStale;
        _items = _mergeChecked(result.items);
      });
      if (result.failed && _items.isNotEmpty) {
        // 整体检查失败：这是「没能刷新」这个结论，error 档（关掉提示也不静默）
        _showSnack(result.message, kind: SnackKind.error);
      }
    } on DioException {
      if (!mounted) return;
      setState(() {
        _busyNote = null;
        _error = '网络请求失败，请检查网络后重试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busyNote = null;
        _error = '检查失败：$e';
      });
    } finally {
      _stopProgressPolling();
    }
  }

  /// 陈旧横幅上的「立即同步」：**只跑白名单同步**（v2.48.0）。
  ///
  /// ★ 为什么不复用 [_checkNow]：那一轮是**全量信箱检查**——串行遍历白名单
  /// UP 主、每个之间间隔 ≥1.5s，100 个 UP 主要跑几分钟（见文件头「后台检查
  /// 不阻塞交互」）。用户此刻的意图是"把白名单这份数据拉新"（好让下一次检查
  /// 依据的是新名单），点一下却触发几分钟的后台遍历是过度反应。
  ///
  /// 同步是**只读**操作，一条 `syncService.sync()` 就够：它同时也把
  /// [WhitelistFreshness] 的判定刷新了（服务内部会打标），横幅据此消失。
  /// 这里不顺手刷新卡片栈：队列内容由 `checkAll` 决定，而这一路刻意**不**跑它
  /// （要立刻看新视频 → 下拉刷新，那是用户明确的动作）。
  Future<void> _resyncWhitelistOnly() async {
    try {
      final result = await ServiceLocator.syncService.sync();
      // 与首页/合集页同一约定：判据只由服务给（[SyncResult.stale]），页面只是
      // 把它搬进 state；这里显式再标一次是为了覆盖**测试替身直接改写 sync()**
      // 的路径（替身不会自己打标，读单例会读到上一条）。
      WhitelistFreshness.instance
          .markSync(sourceName: result.sourceName, stale: result.stale);
      if (!mounted) return;
      setState(() => _stale = result.stale);
      _showSnack(
        result.stale ? '仍然同步失败：请确认网络后重试' : '白名单已同步到最新',
        kind: result.stale ? SnackKind.error : SnackKind.info,
      );
    } catch (e) {
      // 失败**不改**陈旧标记（数据没换，它还是那份），横幅继续挂着
      if (mounted) _showSnack('同步失败：$e', kind: SnackKind.error);
    }
  }

  /// 开/停「检查进行中回读本地未读」的定时器（见 [_pollProgress]）。
  void _startProgressPolling() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(_kProgressPoll, (_) {
      unawaited(_pollProgress());
    });
  }

  void _stopProgressPolling() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// 检查进行中：每隔 [_kProgressPoll] **只读盘**（不触网）回读一次本地未读，
  /// 把新出现的条目追加进卡片栈 —— 用户不必退出重进就能往下滑。
  ///
  /// 服务层每查完一个 UP 主就落盘一次，所以这里读到的新条目就是"刚抓到的"。
  /// 合并仍走 [_mergeChecked]：**只追加、不重排**，已在队列里的与本次会话里
  /// 消费过的一律跳过；队列长度没变（没有新条目）时直接返回，连 setState 都
  /// 不发 —— 既不会扰动正在进行的滑动/飞出动画，也让测试里的 `pumpAndSettle`
  /// 能正常收敛。
  Future<void> _pollProgress() async {
    if (!mounted || !_checking) return;
    final items = await ServiceLocator.inboxService.getItems();
    if (!mounted) return;
    final next = _mergeChecked(items);
    if (next.length == _items.length) return; // 没有新条目 → 不动树
    setState(() {
      _loadedOnce = true;
      _items = next;
    });
  }

  /// 「全部标记已读」。
  Future<void> _markAllRead() async {
    setState(() => _busyNote = '标记中…');
    _abortSwipe();
    try {
      await ServiceLocator.inboxService.markAllRead();
      final items = await ServiceLocator.inboxService.getItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        // 全部标记已读 = 用户明说"这些都看过了" → 「待取回」的也一并作废
        // （否则上滑还会把一张已经标记已读的卡搬回栈顶）
        _deferred.clear();
        // 全部标记已读 = 这一屏的卡都不作数了 → 撤销栈也一并作废
        _undoStack.clear();
        _busyNote = null;
        // 用户显式清空 → 之后就是空态（不是"还没加载出来"）
        _loadedOnce = true;
        _error = null;
      });
      _showSnack('已全部标记已读');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyNote = null);
      _showSnack('标记已读失败：$e', kind: SnackKind.error);
    }
  }

  /// 点按卡片 → fetch view 补 cid → push PlayerPage（老行为，保持不变）。
  ///
  /// 与拖动手势不冲突：`onTap` 与 `onHorizontalDrag*` 由手势竞技场裁决，
  /// 位移超过 touch slop 时横向拖动胜出，点按自然不触发。
  ///
  /// ★ 后台检查（[InboxService.checkAll]）期间**照样能点**：检查不挡交互，
  /// [_opening] 只用来防连点重复 push（旧实现这里 `if (_checking) return;`
  /// 静默吞掉点按，检查几分钟期间点卡片完全没反应）。
  Future<void> _openItem(InboxItem item) async {
    if (_opening) return;
    _opening = true;
    try {
      final meta = await _api.fetchVideoMeta(item.bvid);
      final v = WhitelistWriter.videoFromMeta(meta, fallbackBvid: item.bvid);
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(video: v),
      ));
    } on BiliApiException catch (e) {
      if (!mounted) return;
      _showSnack('获取视频信息失败：${e.message}', kind: SnackKind.error);
    } on DioException {
      if (!mounted) return;
      _showSnack('网络请求失败，请重试', kind: SnackKind.error);
    } finally {
      _opening = false;
    }
  }

  /// 本页提示条入口（统一走 [AppSnack]，见该文件顶部：info 档受设置里的
  /// 「界面提示」开关控制，失败类显式 `kind: SnackKind.error` 永不静默）。
  ///
  /// ★ 本页是"最吵"的一处（每取回一张就一句「已取回「…」」），也正是改连续滑动
  /// 时最碍事的存在 —— 关掉提示之后连划三张只看见卡片飞，不再刷三条黑框。
  void _showSnack(String message, {SnackKind kind = SnackKind.info}) {
    if (!mounted) return;
    AppSnack.show(context, message, kind: kind);
  }

  // ---------------------------------------------------------------------------
  // 手势与动画
  // ---------------------------------------------------------------------------

  /// 顶卡是否**正忙**（提交中 / 正在飞 / 正在回弹）→ 挡住新手势。
  ///
  /// 注意它**不含幽灵卡**：飞出去的那张交接给幽灵层之后就不再挡输入了
  /// （见 [_handOff]），所以"连续跳过"能一张接一张地划。
  bool get _busy => _deciding || _anim != null;

  /// 「队列里还有几张」——**把已经交接出去、还在飞的那张也算上**。
  ///
  /// 为什么要把幽灵算进来：交接到落地之间那张卡不在 [_items] 里，但它在用户眼里
  /// 仍然是"这个队列里的一张"（马上要落到队尾）。若只数 [_items]，连划两张下滑
  /// 时第二张会被判成"队列只剩 1 张 → 推到队尾就是原地打转"而**拒绝执行**
  /// （卡弹回来，用户以为又卡住了）。判定"稍后是否等于原地打转"用它，
  /// 才与用户的感受一致。
  int get _deckLength => _items.length + (_ghost == null ? 0 : 1);

  /// 位移：静止时 = 手指位移；动画中 = 端点之间按 [kCurveOut] 插值。
  Offset _offsetAt(double t) {
    if (_anim == null) return _drag;
    return Offset.lerp(_animFrom, _animTo, kCurveOut.transform(t))!;
  }

  /// 横向 / 纵向拖动共用同一起步回调：记下手指当前的**真实**位置。
  ///
  /// 两个方向的识别器（见 [_buildTopCard] 注册的 `onHorizontalDrag*` /
  /// `onVerticalDrag*`）用的是同一套回调 —— 谁先在手势竞技场里胜出（谁先越过
  /// touch slop），后续事件才送到这里来，所以不会一次收到两份。
  void _onDragStart(DragStartDetails details) {
    _pointer = details.globalPosition;
    _takeOverBackAnimation();
  }

  /// 手指在「回弹 / 取回滑入」跑到一半时又按下并拖动 → 把动画**交给手指**
  /// （从画面上当前那一帧的位置接着走）。
  ///
  /// 为什么可以半路夺回：这两种动画都只是"卡片回到原位"，**还没提交任何判定**
  /// （没记已处理、没写白名单），用户想改主意就该让他改 —— 这也是"上下快速切换
  /// 不卡手"的关键：回弹期间不需要等动画跑完才能开始下一次拖动。
  ///
  /// 为什么**不**接管 [_SwipeAnim.exit]：那一下已经 `markHandled`（右滑还写了
  /// 白名单），半路把卡拽回来会让人以为"刚才那下不算"，而远端其实已经落了账。
  void _takeOverBackAnimation() {
    if (_anim != _SwipeAnim.back) return;
    final c = _fly;
    _drag = c == null ? Offset.zero : _offsetAt(c.value);
    c?.stop();
    _anim = null;
    // 取回的第一步被夺回 = 这次取回取消（那张还在 [_deferred] 里，随时能再上滑）
    _restorePending = false;
    _deciding = false;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_busy || _items.isEmpty) return;
    // ★ 用「真实位置之差」而不是 `details.delta`：单轴识别器交给回调的 delta
    //   已经被它按轴裁过（水平识别器的 `delta.dy` 恒为 0）→ 只靠它累积，
    //   卡片永远只跟一个方向动。
    final prev = _pointer ?? details.globalPosition;
    _pointer = details.globalPosition;
    final delta = details.globalPosition - prev;
    if (delta == Offset.zero) return;
    setState(() {
      _drag += delta; // 两个轴都跟手；旋转仍只看 dx（见 [_decorate]）
      _updateProgress();
    });
  }

  /// 拖动被手势竞技场判给了别人（例如纵向被外层滚动容器抢走）→ 弹回原位。
  void _onDragCancel() {
    _pointer = null;
    _springBack();
  }

  void _onDragEnd(DragEndDetails details) {
    _pointer = null;
    if (_busy || _items.isEmpty) return;
    final screenW = MediaQuery.sizeOf(context).width;
    final v = details.velocity.pixelsPerSecond;
    // 两个轴**共用同一套阈值**（距离 = 屏宽 × kInboxSwipeThresholdRatio，
    // 速度 = kInboxSwipeVelocity）→ 竖直方向和水平方向一样能「快速轻扫」判定
    final farX = _drag.dx.abs() > screenW * kInboxSwipeThresholdRatio;
    final farY = _drag.dy.abs() > screenW * kInboxSwipeThresholdRatio;
    final fastX = v.dx.abs() > kInboxSwipeVelocity;
    final fastY = v.dy.abs() > kInboxSwipeVelocity;

    // ★ 按**主导轴**判定：位移绝对值大的那根轴说了算 —— 斜着划（比如右下
    //   45°）不会两边都不算，也不会一次触发两个动作。两轴位移完全相同（含
    //   都是 0 的「纯甩动」）时看速度，由速度大的那一侧主导（轻扫几乎不产生
    //   位移，只剩速度分得出主次）。
    final vertical = _drag.dx.abs() == _drag.dy.abs()
        ? v.dy.abs() > v.dx.abs()
        : _drag.dy.abs() > _drag.dx.abs();

    // 主轴上「距离过阈值」**或**「甩得够快」就算数（后者 = 快速轻扫）
    if (!(vertical ? (farY || fastY) : (farX || fastX))) {
      _springBack();
      return;
    }
    // 方向取主轴位移的符号；位移恰好为 0（纯甩动）时退回主轴速度的符号
    final main = vertical ? _drag.dy : _drag.dx;
    final speed = vertical ? v.dy : v.dx;
    final positive = main != 0 ? main > 0 : speed > 0;
    final edge = vertical
        ? (positive ? _SwipeEdge.down : _SwipeEdge.up)
        : (positive ? _SwipeEdge.right : _SwipeEdge.left);
    unawaited(_decide(edge));
  }

  /// 浮层渐显进度：**主导轴**的位移到阈值比例时满显。
  ///
  /// 只按主导轴算 → 四个词里永远只会亮一个（斜着划不会两个徽标一起冒出来）；
  /// 哪个方向算哪个行为，一律问 [_actionForEdge]。
  void _updateProgress() {
    final screenW = MediaQuery.sizeOf(context).width;
    final unit = screenW * kInboxSwipeThresholdRatio;
    final vertical = _drag.dy.abs() > _drag.dx.abs();
    final v = vertical ? _drag.dy : _drag.dx;
    if (v == 0) {
      _clearReaction();
      return;
    }
    final edge = vertical
        ? (v > 0 ? _SwipeEdge.down : _SwipeEdge.up)
        : (v > 0 ? _SwipeEdge.right : _SwipeEdge.left);
    final action = _actionForEdge(edge);
    // 没有"待取回"的卡时**不亮**「取回」：亮着却什么都回不来，会让人以为卡丢了
    //（松手时的行为见 [_decide] 的 restore 分支：什么都不做、弹回原位）
    _reaction = (action == InboxSwipeAction.restore && _deferred.isEmpty)
        ? null
        : action;
    _reactionProgress = (v.abs() / unit).clamp(0.0, 1.0);
    // 竖直主导 → 徽标换成居中显示（原来贴左右边缘，竖滑时看不出方向）
    _vertical = vertical;
  }

  /// 收掉浮层（拖动归零 / 弹回 / 结算时用）。不动 [_drag] / [_pointer]。
  void _clearReaction() {
    _reaction = null;
    _reactionProgress = 0;
    _vertical = false;
  }

  /// 复位一次手势的**全部**瞬时状态（结算 / 撤销 / 取回 / 关动效时用）。
  void _resetGestureState() {
    _drag = Offset.zero;
    _pointer = null;
    _clearReaction();
  }

  /// 朝 [edge] 那一侧**飞出屏幕**的终点位移（见 [inboxExitMotion]）。
  ///
  /// [perp] 是另一根轴上保留的余量：向右划但手上带了下沉，卡片就斜着飞出去
  /// （与改动前 `Offset(±屏宽 × 1.4, _drag.dy)` 的观感一致）；竖直方向同理。
  Offset _offscreen(_SwipeEdge edge, {double perp = 0}) => _exitMotion(edge, perp: perp).offset;

  /// 出屏位移 + 时长（本页唯一的出口，纯计算在 [inboxExitMotion] 里）。
  ({Offset offset, Duration duration}) _exitMotion(
    _SwipeEdge edge, {
    double perp = 0,
  }) =>
      inboxExitMotion(
        screen: MediaQuery.sizeOf(context),
        vertical: edge == _SwipeEdge.up || edge == _SwipeEdge.down,
        positive: edge == _SwipeEdge.right || edge == _SwipeEdge.down,
        perp: perp,
      );

  /// 没过阈值 → 弹回原位（不调用任何动作）。
  ///
  /// 时长用 [kDurSlow]（= 飞出的时长）：回弹比飞出更急会显得"甩回来"很生硬
  /// （旧实现 200ms vs 飞出 320ms）。回弹期间手指落下可以从当前位置接管
  /// （[_takeOverBackAnimation]），所以给足时长不影响"连续操作"。
  void _springBack() {
    if (_deciding) return;
    final c = _motion ? _fly : null;
    setState(() {
      // 没成一张 → 浮层立即收掉（徽标摆位也回到默认），卡片滑回原位
      _clearReaction();
    });
    if (c == null || _drag == Offset.zero) {
      setState(() => _drag = Offset.zero);
      return;
    }
    setState(() {
      _animFrom = _drag;
      _animTo = Offset.zero;
      _anim = _SwipeAnim.back;
    });
    c.duration = kDurSlow;
    c.forward(from: 0);
  }

  /// 提交一次滑动：四向 = 四个行为，一律经 [_actionForEdge] 折算。
  ///
  /// - [InboxSwipeAction.like] / [InboxSwipeAction.skip]：飞出屏幕 → [_commitExit]
  ///   （记「已处理」，进撤销位）；
  /// - [InboxSwipeAction.defer]（下滑 = **稍后**）：也是朝下飞出屏幕，但飞出结束
  ///   后走 [_settleExit] 的 defer 分支 —— **不记「已处理」**，落地时推到队尾；
  /// - [InboxSwipeAction.restore]（上滑 = **取回**）：**当前这张不飞走**，见
  ///   [_restoreTop]。
  Future<void> _decide(_SwipeEdge edge) async {
    if (_deciding || _items.isEmpty) return;
    // 先上锁：门禁检查也是异步的，期间不能再拖/再点（防重复提交）
    _deciding = true;
    final item = _items.first;
    final action = _actionForEdge(edge);

    // ---- 上滑 = 取回：手上这张不判定、不飞走，把最近推后的那张拿回栈顶 ----
    if (action == InboxSwipeAction.restore) {
      final back = _deferred.isEmpty ? null : _deferred.last;
      // 判定留痕：`adb logcat | grep inbox` 一眼看出"划了没反应"是为什么
      debugPrint(back == null
          ? '[inbox] 判定 edge=${_edgeLabel(edge)} → 取回（没有可取的卡 → 不动）'
              ' bvid=${item.bvid} drag=$_drag'
          : '[inbox] 判定 edge=${_edgeLabel(edge)} → 取回 bvid=${back.bvid}'
              ' drag=$_drag');
      if (back == null) {
        // 从没下滑过 → 什么都不做（不判定、不提示、不当成别的动作）
        _deciding = false;
        _springBack();
        return;
      }
      _restoreTop();
      return;
    }

    // ---- 下滑 = 稍后：队列里只剩 1 张时"推到队尾"就是原地打转 → 什么都不做 ----
    if (action == InboxSwipeAction.defer && _deckLength < 2) {
      debugPrint('[inbox] 判定 edge=${_edgeLabel(edge)} → 稍后（队列只有 1 张 → 不动）'
          ' bvid=${item.bvid} drag=$_drag');
      _deciding = false;
      _springBack();
      return;
    }

    // 判定留痕：「划了没反应 / 判反了」时一眼看得出手势被认成了哪一边（tag 与
    // inbox_service 一致，`adb logcat | grep '[inbox] 判定'` 即可）
    debugPrint(
        '[inbox] 判定 edge=${_edgeLabel(edge)} → ${_actionLabel(action)} '
        'bvid=${item.bvid} drag=$_drag');
    final like = action == InboxSwipeAction.like;
    if (like) {
      // 配置门禁：未配置 GitHub → 提示并弹回（不改任何状态；与搜索页同文案）
      var ok = false;
      try {
        ok = await _writer.hasConfig();
      } catch (_) {
        ok = false;
      }
      if (!mounted) {
        _deciding = false;
        return;
      }
      if (!ok) {
        _deciding = false;
        _showSnack(_kConfigHint);
        _springBack();
        return;
      }
    }
    if (!mounted) {
      _deciding = false;
      return;
    }
    _exiting = edge;
    _exitingAction = action;
    _exitRetired = false;
    if (action != InboxSwipeAction.defer) {
      // 记「已处理」+ 从本地未读缓存里摘掉 → 首页红点立刻下降（不触网）。
      // ★ 下滑「稍后」绝不走这里（它不是判定，那张必须还能再看到）
      unawaited(ServiceLocator.inboxService.markHandled(item.bvid));
    }
    if (like) {
      // 加入白名单是真写 Gist（GET 整份 + PATCH 整份）：输入解锁后连划两张右滑
      // 会并发两次，`WhitelistWriter.addVideo` 内部已把整段读改写串行化
      // （见该服务里的 `_chain`），这里 fire-and-forget 即可。
      unawaited(_like(item));
    }
    final c = _motion ? _fly : null;
    if (c == null) {
      _commitExit();
      return;
    }
    final vertical = edge == _SwipeEdge.up || edge == _SwipeEdge.down;
    // 朝实际判定出来的那一侧飞出去（下滑往下、左滑往左、右滑往右）；
    // 时长按出屏距离给 —— 竖直方向距离更长、时长等比放大，四个方向的出屏
    // **速度**一致（见 [inboxExitMotion]）。
    final motion = _exitMotion(edge, perp: vertical ? _drag.dx : _drag.dy);
    setState(() {
      _animFrom = _drag;
      _animTo = motion.offset;
      _anim = _SwipeAnim.exit;
    });
    c.duration = motion.duration;
    c.forward(from: 0);
  }

  /// 右滑 = 加入白名单（未分类）：取 view 元数据 → 走共用 [WhitelistWriter]。
  Future<void> _like(InboxItem item) async {
    try {
      final meta = await _api.fetchVideoMeta(item.bvid);
      final v = WhitelistWriter.videoFromMeta(meta, fallbackBvid: item.bvid);
      final result = await _writer.addVideo(v);
      if (!mounted) return;
      _showSnack(result.message);
    } on BiliApiException catch (e) {
      if (!mounted) return;
      _showSnack('获取视频信息失败：${e.message}', kind: SnackKind.error);
    } on DioException {
      if (!mounted) return;
      _showSnack('网络请求失败，请重试', kind: SnackKind.error);
    } on GithubApiException catch (e) {
      if (!mounted) return;
      _showSnack('加入失败：${e.message}', kind: SnackKind.error);
    }
  }

  /// 动画结束：确认动画类型。
  void _onFlyStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final mode = _anim;
    _anim = null;
    if (mode == _SwipeAnim.exit) {
      // 兜底：正常路径早在"后层推进到位"那一刻就交接完了（[_onFlyTick]），
      // 这里处理没赶上交接点的情形（例如交接被上一个幽灵延后了）
      _commitExit();
      return;
    }
    if (!mounted) return;
    setState(() => _drag = Offset.zero);
    // 「取回」第一步（手上这张弹回原位）刚走完 → 接着让取回的那张滑进来
    if (_restorePending) _applyRestore();
  }

  /// 顶卡飞出动画**逐帧**：到「后层推进到位」那一刻就把飞出的那张交接出去。
  ///
  /// 为什么盯着自家的 controller 而不是等卡片栈回调：两边是同一帧启动的
  /// ticker、时长分别是 [kDurAdvance] 与本次出屏时长 → `_fly.value` 到
  /// `kDurAdvance / 出屏时长` 这一比例的时刻，恰好就是后层推进到位（u = 1）的
  /// 那一帧。而 [InboxCardStack] 只在 u = 1 时出栈才不会跳变（那条硬约束见
  /// `inbox_card_stack.dart` 文件头第 1 条）—— 所以交接点必须精确落在这里。
  void _onFlyTick() {
    final c = _fly;
    if (c == null || _anim != _SwipeAnim.exit || _exitRetired) return;
    final total = c.duration?.inMicroseconds ?? 0;
    if (total <= 0) return;
    if (c.value * total < kDurAdvance.inMicroseconds) return;
    // 上一个幽灵还没落地 → **延后交接**（一次只放一个幽灵；它一落地 [_landGhost]
    // 会再调一次这里补上）。为什么不直接顶掉旧幽灵：竖直方向出屏要 ~500ms，
    // 交接点在它的 1/3 处，顶掉时那张卡还在屏幕里飞 → 会"凭空消失"，
    // 更糟的是它那句"落地回队尾"的收尾也跟着没了（卡片直接从队列里丢掉）。
    if (_ghost != null) return;
    _handOff();
  }

  /// 幽灵卡飞完 → 落地（见 [_landGhost]）。
  void _onGhostStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _landGhost();
  }

  /// 把「正在飞出的那张」**交接给幽灵层**（v2.36.0 连续滑动的核心）。
  ///
  /// 动作（同一个 `setState` 里一次做完，卡片栈才认得出"头部少了一张"）：
  /// - 从 [_items] 摘掉队首 → `_items.first` 立刻是下一张，**新手势马上可用**；
  /// - 把这一张连同飞出区间交给 [_ghost]（画在整叠牌之上、不吃手势的幽灵层），
  ///   进度从 [_fly] 当前值原样接过去 → 位置逐帧连续，看不出交接；
  /// - 判定记账（[_settleExit]）：记「已处理」/ 进撤销栈 / 「稍后」的等落地再回队尾。
  ///
  /// ★ 一次只放**一个**幽灵：上一个还没落地时**延后交接**（[_onFlyTick] 会每帧
  /// 再试），等它落地立刻补上。宁可多锁几十毫秒，也不把一张还剩大半路程的卡
  /// 凭空抹掉（旧幽灵直接替换掉的话，竖直方向出屏要走 ~500ms，交接后幽灵还有
  /// 一大半路要飞，抹掉就是"卡片在半屏处消失"）。
  void _handOff() {
    final item = _items.isEmpty ? null : _items.first;
    final edge = _exiting;
    final action = _exitingAction;
    if (item == null || edge == null || action == null) {
      // 队列被清空了（例如全部标记已读）：直接收尾，别留下悬空的动画状态
      //（force —— 这时候本来就没有可交接的那张）
      _finishExitState(force: true);
      return;
    }
    final from = _animFrom;
    final to = _animTo;
    final progress = _fly?.value ?? 1;
    final duration = _fly?.duration ?? kDurSlow;
    _fly?.stop();
    _exitRetired = true;

    final g = _ghostFly == null
        ? null
        : _GhostExit(
            item: item,
            edge: edge,
            from: from,
            to: to,
            action: action,
            badge: _reaction,
            badgeProgress: _reactionProgress,
            vertical: _vertical,
          );
    _anim = null;
    _deciding = false;
    _exiting = null;
    _exitingAction = null;
    if (!mounted) {
      _ghost = null;
      _finishExitState();
      return;
    }
    setState(() {
      _settleExit(item, action, edge);
      // 屏上的卡片全处理完了 → 收起「上次检查失败」的提示（错误态不该盖住
      // 「没有未读了」这个结论；要重试还可以下拉刷新）
      if (_items.isEmpty) _error = null;
      _resetGestureState();
      _ghost = g;
    });
    if (g != null) {
      // 同一个时长 + 从当前进度续跑 → 位置与速度都连续（不是重新起一段动画）
      _ghostFly!
        ..duration = duration
        ..forward(from: progress);
    } else {
      // 关动效（没有幽灵层）：交接即落地（「稍后」的那张就地插回队尾）
      _landGhost(deferred: item, deferredAction: action);
      return;
    }
    // 顶卡换人了 → 重新看一眼新顶卡作者在不在播
    unawaited(_loadTopLive());
  }

  /// 判定记账：把飞出的这一张从队首摘掉（并做对应的簿记）。
  ///
  /// ★ 行为分流（别合并）：
  /// - **稍后**（[InboxSwipeAction.defer]）：**不记「已处理」**（[_consumedBvids]
  ///   与 `markHandled` 都不动）、不写 Gist、不取元数据 —— 用户原话「暂时不判断，
  ///   先看后面的卡片」。它只是**离开队首**，等幽灵落地再插回**队尾**（那句
  ///   "推到队尾"的语义没变，只是分两步：先摘、落地再插，免得同一张卡同时出现在
  ///   "飞出去"和"牌堆里"两处）。
  /// - **加入 / 跳过**：进 [_consumedBvids]（本轮的 checkAll 结果不复活它）、
  ///   从 [_deferred] 里摘掉（一张卡只能"在某个地方等着"）、压进撤销栈。
  void _settleExit(InboxItem item, InboxSwipeAction action, _SwipeEdge edge) {
    final bvid = item.bvid;
    _items = [
      for (final it in _items)
        if (it.bvid != bvid) it,
    ];
    if (action == InboxSwipeAction.defer) return; // 稍后：不判定，落地时回队尾
    _consumedBvids.add(bvid);
    _deferred.removeWhere((it) => it.bvid == bvid);
    _undoStack.add(_SwipeRecord(item, edge: edge));
    if (_undoStack.length > _kMaxUndo) _undoStack.removeAt(0);
  }

  /// 幽灵卡落地：收掉它，并把「稍后」的那张插回队尾。
  ///
  /// [deferred] / [deferredAction] 是**关动效**那条路传进来的（没有幽灵对象，
  /// 交接即落地）；有幽灵时一律从 [_ghost] 读。
  ///
  /// ★ 必须**在 setState 里**清 [_ghost]：否则树不重建，那张已经"落地"的幽灵卡
  /// 会一直挂在 Stack 上（表现为"飞走的卡没消失、牌堆多一张"）。
  void _landGhost({InboxItem? deferred, InboxSwipeAction? deferredAction}) {
    final g = _ghost;
    final item = g?.item ?? deferred;
    final action = g?.action ?? deferredAction;
    _ghost = null;
    _ghostFly?.stop();
    if (mounted && item != null) {
      setState(() {
        if (action == InboxSwipeAction.defer) _reinsertDeferred(item);
      });
    }
    _finishExitState();
    // 上一次飞出因为"幽灵没落地"被延后交接了 → 现在补上（它此刻已到推进点）
    _onFlyTick();
  }

  /// 「稍后」的那张落地回**队尾**（[_settleExit] 在交接时把它从队首摘掉了）。
  ///
  /// 若这张已经被"取回"插回队首了（[_items] 里已有）就不重复插 ——
  /// 取回是更晚的意图，以它为准。
  void _reinsertDeferred(InboxItem item) {
    if (!_items.any((it) => it.bvid == item.bvid)) {
      _items = [..._items, item];
    }
    // 推后记录是**栈**：绕一圈又回到队首的挪到栈顶，不留两份
    //（否则上滑会把同一张插回队列两次）
    _deferred
      ..removeWhere((it) => it.bvid == item.bvid)
      ..add(item);
    // 它已经"回到牌堆后面"了：让交错入场账本忘掉它，好让它在新的层位上
    // 淡入一次（不退账的话，它会从"飞出屏幕"直接"啪"地出现在牌堆里）
    _entranceLedger.clear();
  }

  /// 收尾这次飞出（交给"松手即出栈"那条路与 [_abortSwipe] 共用）。
  ///
  /// ★ 只在**这次飞出确实已经交接**时才清状态：幽灵落地时若已经有一次新的飞出
  /// 在等交接（它的 [_exitRetired] 是 false），那份状态不能清 —— 清了它就会
  /// 永远停在"正在飞"上（顶卡永远不换人）。见 [_onFlyTick] / [_landGhost]。
  /// [force] = 那些"本来就没有可交接的东西"的收尾路径（队列被清空 / 关动效）。
  void _finishExitState({bool force = false}) {
    if (!force && !_exitRetired) return;
    _exiting = null;
    _exitingAction = null;
    _anim = null;
    _deciding = false;
    _exitRetired = false;
    _ghost = null;
    _ghostFly?.stop();
  }

  /// 飞出结束（关动效时是松手即到）：按 [_exitingAction] 分流结算。
  ///
  /// 交接过（有幽灵 / 已摘队首）→ 只需收尾；没交接（顶卡的飞出动画在别的路径上
  /// 走完了，或刷新要强推）→ 先交接再收尾。
  void _commitExit() {
    if (!_exitRetired) {
      // 强推交接之前先把**还在飞的旧幽灵**落地：它的「稍后」那张必须回队尾
      //（刷新收尾也要保证这张不丢）。落地那一帧它会顺手把交接补上
      //（[_landGhost] 末尾的 [_onFlyTick]）→ 所以下面再判一次是否还欠交接。
      if (_ghost != null) _landGhost();
      if (!_exitRetired) _handOff();
    }
    _landGhost();
  }

  /// 上滑 = **取回**：把最近一次被「稍后」推后的那张拿回**栈顶**。
  ///
  /// 两步（见 [_restorePending]）：① 手上这张先弹回原位；② 落位后由
  /// [_applyRestore] 把取回的那张从**下方**滑进来（它当初是往下飞出去的）。
  /// 全程不写任何东西 —— 那张既没被判过"已处理"，也没进过白名单。
  ///
  /// ★ 第一步用 [kDurQuick]（120ms）而不是 [kDurBase]：**这一步的时长就是
  /// "取回"这条路锁输入的时间**（[_deciding] 在这一步里是 true）。上滑取回是
  /// "上下快速来回切"的主路径，用户原话要的是"可以垂直上下快速切换" ——
  /// 让手上这张**快点让位**比让它优雅地滑回去重要。第二步（被取回的那张滑入）
  /// 不锁输入：手指落下就能接管（[_takeOverBackAnimation]），所以仍用
  /// [kDurBase] 保证观感。
  void _restoreTop() {
    final c = _motion ? _fly : null;
    if (c == null || _drag == Offset.zero) {
      _applyRestore();
      return;
    }
    setState(() {
      _clearReaction();
      _animFrom = _drag;
      _animTo = Offset.zero;
      _anim = _SwipeAnim.back;
      _restorePending = true;
    });
    c.duration = kDurQuick;
    c.forward(from: 0);
  }

  /// 取回的第二步：把 [_deferred] 栈顶那张放回**队首**，并从下方滑入到栈顶。
  ///
  /// 它一直在 [_items] 里（只是先前被推到了队尾）→ 先摘掉旧位置再插到队首，
  /// 免得队列里出现两张一样的。后层由卡片栈反播推进退回原位（[restoreTick]
  /// 打点，见 `inbox_card_stack.dart`），所以是退回去、不是跳回去。
  void _applyRestore() {
    _restorePending = false;
    _deciding = false;
    _anim = null;
    if (!mounted || _deferred.isEmpty) return;
    final item = _deferred.removeLast();
    final c = _motion ? _fly : null;
    setState(() {
      _items = [
        item,
        for (final it in _items)
          if (it.bvid != item.bvid) it,
      ];
      _loadedOnce = true;
      _resetGestureState();
      _restoreTick++; // 告诉卡片栈：队首换人了，把后层退回去（见该字段的说明）
      if (c != null) {
        // 从**下方**屏外滑回原位（当初"稍后"就是往下飞出去的）→ 一眼看得出
        // "有一张卡回来了"，而当前这张只是让位、没被判定
        _animFrom = _offscreen(_SwipeEdge.down);
        _animTo = Offset.zero;
        _anim = _SwipeAnim.back;
      }
    });
    if (c != null) {
      c.duration = kDurBase;
      c.forward(from: 0);
    }
    unawaited(_loadTopLive());
    _showSnack('已取回「${item.title}」');
  }

  /// 刷新/离开前收尾：把正在飞出的那张按已完成结算（动作早已发出），
  /// 并清掉拖动与浮层状态（避免刷新回来后残留一个半飞的卡片）。
  ///
  /// 「幽灵卡」也要一起落地：它的"稍后"那张得插回队尾（见 [_landGhost]），
  /// 否则刷新一次那张卡就凭空消失了。
  void _abortSwipe() {
    _fly?.stop();
    if (_anim == _SwipeAnim.exit || _exitRetired) {
      _commitExit();
      return;
    }
    // 「取回」的两步动画走到一半：直接放弃这次取回（什么都没写，那张还在
    // [_deferred] 里，随时能再上滑一次）。★ 必须把 [_deciding] 一起放掉——
    // 它在这一段里是 true，留着的话刷新之后所有手势都会被 [_busy] 挡死。
    _restorePending = false;
    _deciding = false;
    _anim = null;
    _resetGestureState();
  }

  /// 撤销上一张：从撤销栈弹出一张放回队首 + 删掉它的「已处理」记录。
  ///
  /// **可连撤**（v2.36.0）：输入解锁后用户会连着划好几张，只留一张的话
  /// "撤销上一张"按一次就用完了 —— 现在判定掉的卡按顺序进 [_undoStack]，
  /// 每按一次退一张（LIFO）。
  ///
  /// **不会**自动把已经写进白名单的视频移除（那是一次不可逆的 Gist 写操作），
  /// 所以提示文案里明确说明——让用户自己决定要不要再去白名单删掉。
  ///
  /// 空态（刚划掉最后一张）也能用：底部栏在无卡片时只留这一个入口。
  ///
  /// ## 动效（v2.22.0+）
  /// 撤销是**反着播**划走那一下：
  /// - 放回来的这张从原来飞出去的**那一侧**飞回来（复用 [_fly] 的 back 区间：
  ///   起点 = 屏外同侧（[_exitMotion]）、终点 = 原位，走的还是 [kCurveOut] +
  ///   [kDurBase]）→ 上滑划走的就从上方飞回来，所以它带着一点回正的角度感，
  ///   而不是"啪"地出现在原位；
  /// - 后层的「退回」由卡片栈自己反播推进（它检测到队首插回一张，
  ///   见 `inbox_card_stack.dart` 的 `_isHeadInsert`）→ 后层退回原位、无跳变。
  ///
  /// 关动效时两件事都是瞬时到位（[MotionControl.of] 为 false → 没有 controller）。
  void _undoLast() {
    // 顶卡正在飞 / 正在回弹时不动队列：此刻 _items 的头部正要换人，
    // 往队首插一张会让它中途换人。（幽灵卡不算"正在飞" —— 它已经从队列里
    // 摘出去了，所以交接之后撤销随时可用。）
    if (_busy) return;
    if (_undoStack.isEmpty) return;
    final rec = _undoStack.removeLast();
    unawaited(ServiceLocator.inboxService.unmarkHandled(rec.item));
    final c = _motion ? _fly : null;
    setState(() {
      // 撤销 → 这条不再算「已消费」：检查回来的合并结果里可以重新出现它
      _consumedBvids.remove(rec.item.bvid);
      _items = [rec.item, ..._items];
      _loadedOnce = true;
      _clearReaction();
      // 放回来的这张回到了队首 → 不再算「待取回」的（免得它被上滑又插一次）
      _deferred.removeWhere((it) => it.bvid == rec.item.bvid);
      if (c == null) {
        _anim = null;
        _drag = Offset.zero;
      } else {
        // 从原来飞出去的那一侧、屏外飞回原位
        _animFrom = _offscreen(rec.edge);
        _animTo = Offset.zero;
        _anim = _SwipeAnim.back;
      }
    });
    if (c != null) {
      c.duration = kDurBase;
      c.forward(from: 0);
    }
    // 顶卡换人（放回来的这张）：重新看一眼它的开播状态
    unawaited(_loadTopLive());
    _showSnack(rec.liked
        ? '已撤销上一张（若已加入白名单，需到白名单里自行移除）'
        : '已撤销上一张');
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('信箱'),
        actions: [
          // 后台任务提示：**不是**加载态、不挡任何操作，只是一行小字
          //（一轮 checkAll 可能要几分钟，见文件头）
          if (_checking)
            Center(
              child: Text(
                _busyNote!,
                style: kTypeBodyS.copyWith(color: kInkGray70),
              ),
            ),
          TextButton.icon(
            icon: const Icon(Icons.done_all),
            label: const Text('全部标记已读'),
            onPressed: _items.isEmpty ? null : _markAllRead,
          ),
        ],
      ),
      body: ListenableBuilder(
        // 卡片样式 store：切换风格 → 卡片栈立即换版式（尺寸固定，不跳动）
        listenable: InboxCardStyleStore.instance,
        builder: (context, _) => Column(
          children: [
            // 陈旧快照常驻提示（v2.48.0）：挂在滚动容器**之外**（不随队列
            // 滚走），与合集页 `CollectionPage` 同一种形状。用的是**只跑白名单
            // 同步**的轻回调，不是 [_checkNow]（理由见 [_resyncWhitelistOnly]）。
            // 不陈旧时组件自己返回 SizedBox.shrink()，不占位。
            StaleSyncBanner(
              stale: _stale,
              onResync: () => unawaited(_resyncWhitelistOnly()),
            ),
            Expanded(
              child: RefreshIndicator(onRefresh: _checkNow, child: _buildBody()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_checking && _items.isEmpty && !_loadedOnce) {
      // 首屏等待（还没拿到过任何队列结果）：本页在 RefreshIndicator 里 →
      // 必须 scrollable（保下拉刷新）。
      // ★ 已经拿到过结果（例如用户刚把最后一张划走、后台检查还在跑）→ 不走
      //   这里，直接空态；否则「划完了」会先闪一整页加载态（观感像又转圈了）。
      return const AppLoadingHero(seed: 'inbox', scrollable: true);
    }
    if (_error != null && _items.isEmpty) {
      // 错误态：细线插画 + 错误文案 + 重试
      return AppErrorView(
        message: _error!,
        onRetry: _checkNow,
        illustrationSeed: 'inbox',
        scrollable: true,
      );
    }
    if (_items.isEmpty) {
      // 空态（全部处理完 / 没有新视频）：文案走 UiCopyStore，key 不变。
      // ★ 底部保留「撤销上一张」：刚划掉最后一张也能收回来（否则底部栏整体
      //   消失，撤销不回来）。
      return Column(
        children: [
          const Expanded(
            child: AppStateView(
              kind: AppStateKind.empty,
              copyId: 'empty.inbox',
              illustrationSeed: 'inbox',
              // 宿主是 RefreshIndicator → 必须可滚动
              scrollable: true,
            ),
          ),
          _buildBottomBar(hasCards: false),
        ],
      );
    }
    return _buildDeck();
  }

  /// 卡片栈：外层仍是可滚动区（`AlwaysScrollableScrollPhysics`，
  /// 保证 [RefreshIndicator] 在「内容正好占满一屏」时也能下拉刷新）。
  ///
  /// 高度预算不靠 `SliverFillRemaining`（它要问子树的 intrinsic 高度，
  /// 而 [LayoutBuilder] 不支持 intrinsic 查询 → 直接断言失败），改为
  /// `SliverToBoxAdapter + ConstrainedBox(minHeight: 可用高度)`：
  /// 内容比一屏矮 → 撑满并居中；比一屏高 → 自然增高并可滚动。
  ///
  /// 卡片的多层叠放与「向前推进」在 [InboxCardStack] 里（本文件只给
  /// 队列、版式、宽度，以及「顶层正在飞出」这个信号）。
  Widget _buildDeck() {
    final media = MediaQuery.of(context);
    // 可用高度 ≈ 窗口高 - 状态栏 - AppBar（略微高估也无妨：内容超出就滚动）
    final bodyH = math.max(
      media.size.height - media.padding.top - kToolbarHeight,
      240.0,
    );
    // 当前卡片版式（设置页可切）：本方法在 ListenableBuilder 里被重建，
    // 换风格 → 整叠卡片同时换版式（尺寸固定，卡片栈不跳动）
    final style = InboxCardStyleStore.instance.style;
    return StaggeredListScope(
      generation: 'inbox',
      ledger: _entranceLedger,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: bodyH),
              child: LayoutBuilder(
                builder: (context, cons) {
                  // 高度约束是「minHeight = 一屏、maxHeight = ∞」→ 取 minHeight
                  final availableH =
                      cons.hasBoundedHeight ? cons.maxHeight : cons.minHeight;
                  // 扑克牌比例（宽 : 高 = 1 : kInboxCardAspect），宽度仍取
                  // 「屏宽 88% 封顶 420」；屏太矮时**等比**缩到预算内（比例
                  // 不变，各层的露出量与版式都不受影响）。
                  // 高度预算三块：底部按钮行 + 上下留白 + 后层按深度下移的量
                  //（后层是「底边往下铺」的，不预留就会压到按钮上 / 出屏）
                  final maxCardH = math.max(
                    availableH - _kBottomBarH - kSpace24 - kInboxStackMaxDrop,
                    200.0,
                  );
                  var cardW = math.min(cons.maxWidth * 0.88, 420.0);
                  if (inboxCardHeight(cardW) > maxCardH) {
                    cardW = maxCardH / kInboxCardAspect;
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        // 给最深那层留出「底边下移」的余量（见 kInboxStackMaxDrop）：
                        // 后层会画到 Stack 框外，靠这段 padding 把它挡在底部按钮之上
                        padding: const EdgeInsets.only(
                          bottom: kInboxStackMaxDrop,
                        ),
                        child: SizedBox(
                          // 只定宽：高度由**顶层卡片**决定（Stack 取非定位子项的
                          // 自然高度），下层卡片才拿得到"顶层底边"当对齐基准
                          width: cardW,
                          child: InboxCardStack(
                            items: _items,
                            width: cardW,
                            style: style,
                            // 顶层开始飞出 → 后层立刻向前推进（与飞出并行）
                            advancing: _anim == _SwipeAnim.exit,
                            // 上滑取回一次 → 后层退回原位（见该字段的说明）
                            restoreTick: _restoreTick,
                            topCard: _buildTopCard(_items.first, cardW, style),
                            // 幽灵卡：已经交接出去、还在飞的那张（画在最上面、
                            // 不吃手势）—— 新手势因此落到下面新顶卡上
                            overlay: _buildGhost(cardW, style),
                          ),
                        ),
                      ),
                      _buildBottomBar(hasCards: true),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶层卡片：手势 + 跟随/旋转 + 浮层标记（+ 在播角标）。
  Widget _buildTopCard(InboxItem item, double cardW, InboxCardStyle style) {
    final card = InboxSwipeCard(
      item: item,
      width: cardW,
      style: style,
      // 浮层：当前这次拖动/飞出落在哪个行为上（加入 / 跳过 / 稍后 / 取回），
      // 由 _updateProgress 按主导轴 + _actionForEdge 算好
      action: _reaction,
      actionProgress: _reactionProgress,
      // 竖直主导的拖动/飞出 → 徽标居中显示（见 _vertical 的说明）
      reactionVertical: _vertical,
    );
    final gesture = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 点按（打开播放页）与拖动共存：手势竞技场按位移裁决
      onTap: () => unawaited(_openItem(item)),
      // ★ 四个方向都要跟手：横向与纵向各注册一个拖动识别器，两者共用同一套回调
      //   （谁先越过 touch slop 谁在手势竞技场里胜出，事件只送到胜出的那个）。
      //   纵向识别器注册在**卡片**上、比外层 CustomScrollView 的滚动识别器更
      //   内层 → 卡片上的上下拖会被这里吃掉（这正是"上下滑判定"的前提），
      //   代价是下拉刷新要从卡片外的留白发起。
      onHorizontalDragStart: _onDragStart,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragCancel,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _onDragCancel,
      child: card,
    );
    // 「正在直播」角标（v2.25.2+）：叠在卡片左上角，**不改变卡片尺寸**（
    // 只是 Stack 里的一层，卡片的自然高度仍是 Stack 的高度，卡片栈的几何
    // 一点没动）。点它是自己的手势（内层 InkWell 在手势竞技场里胜出），
    // → 进站内直播播放页（v2.27.0+）；点卡片其它地方照旧开播放页。
    final live = _live;
    final body = (live != null && live.isLive)
        ? Stack(
            children: [
              gesture,
              Positioned(
                left: kSpace8,
                top: kSpace8,
                child: LiveNowBadge(
                  title: live.title,
                  maxWidth: math.max(cardW - kSpace24, 120),
                  onTap: () => unawaited(_openLive(live)),
                ),
              ),
            ],
          )
        : gesture;
    final c = _motion ? _fly : null;
    return StaggeredEntrance(
      entryKey: 'bvid:${item.bvid}',
      index: 0,
      child: c == null
          ? _decorate(body, 1)
          : AnimatedBuilder(
              animation: c,
              // ★ 必须传 child：飞出/弹回期间卡片子树不逐帧重建
              child: body,
              builder: (_, child) => _decorate(child!, c.value),
            ),
    );
  }

  /// 幽灵卡：**已经交接出去、还在飞**的那张（null = 没有）。
  ///
  /// 三个要点：
  /// - 它画在**整叠牌之上**（所以"飞出期间 `find.byType(InboxSwipeCard).last`
  ///   仍是飞出去的那张"这条既有观感/既有用例都成立），但整层套
  ///   [IgnorePointer] → **不吃手势**，新手势落到下面的新顶卡上（这就是"松手
  ///   140ms 后就能拖下一张"）；
  /// - 位置由自己的控制器 [_ghostFly] 驱动，进度从顶卡飞出的那一帧**原样接过来**
  ///   （[ _GhostExit.offsetAt ] + 同一个时长）→ 交接那一帧看不出任何变化；
  /// - 卡片内容不重建（[AnimatedBuilder] 的 `child:`），400ms 内只是被平移。
  Widget? _buildGhost(double cardW, InboxCardStyle style) {
    final g = _ghost;
    final c = _ghostFly;
    if (g == null || c == null) return null;
    return Positioned(
      key: ValueKey<String>('inbox.ghost:${g.item.bvid}'),
      left: 0,
      right: 0,
      top: 0,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: c,
          child: InboxSwipeCard(
            item: g.item,
            width: cardW,
            style: style,
            // 飞出途中浮层一直亮着（沿用"钉在松手那一刻"的既有观感）
            action: g.badge,
            actionProgress: g.badgeProgress,
            reactionVertical: g.vertical,
          ),
          builder: (_, child) => _decorateWith(child!, g.offsetAt(c.value)),
        ),
      ),
    );
  }

  /// 位移 + 旋转（旋转角与水平位移成正比，最多 ±[kInboxSwipeMaxTilt]）。
  Widget _decorate(Widget child, double t) => _decorateWith(child, _offsetAt(t));

  /// 按一个**已经算好的位移**摆卡片（顶卡与幽灵卡共用；幽灵卡不走 [_offsetAt]，
  /// 它的区间与进度都在 [_ghost] 里）。
  Widget _decorateWith(Widget child, Offset off) {
    final screenW = MediaQuery.sizeOf(context).width;
    final tilt = (off.dx / screenW).clamp(-1.0, 1.0) * kInboxSwipeMaxTilt;
    return Transform.translate(
      offset: off,
      child: Transform.rotate(angle: tilt, child: child),
    );
  }

  /// 底部：撤销 + 「跳过」/「加入」（≥48dp，与滑动等价）。
  ///
  /// [hasCards] = false（空态）时只留撤销入口：没有卡片，「跳过/加入」无处可施，
  /// 但「撤销」必须还在——否则划掉最后一张就撤不回来了。
  ///
  /// ★ 按钮**不因后台任务（checkAll / markAllRead）而禁用**：检查期间照样能
  /// 划卡、撤销（见文件头「后台检查不阻塞交互」）。
  Widget _buildBottomBar({required bool hasCards}) {
    final disabled = _busy;
    if (!hasCards) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          kPagePadH,
          kSpace12,
          kPagePadH,
          kSpace16,
        ),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _canUndo ? _undoLast : null,
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('撤销上一张'),
            style: OutlinedButton.styleFrom(
              // Android 规范：触摸目标 ≥ 48dp
              minimumSize: const Size(160, 48),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPagePadH,
        kSpace12,
        kPagePadH,
        kSpace16,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: IconButton(
              tooltip: '撤销',
              onPressed: _canUndo ? _undoLast : null,
              icon: const Icon(Icons.undo),
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: disabled ? null : () => unawaited(_decide(_SwipeEdge.left)),
            icon: const Icon(Icons.close, size: 18),
            label: const Text('跳过'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(104, 48),
            ),
          ),
          const SizedBox(width: kSpace12),
          FilledButton.icon(
            onPressed: disabled ? null : () => unawaited(_decide(_SwipeEdge.right)),
            icon: const Icon(Icons.favorite_border, size: 18),
            label: const Text('加入'),
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.inkFill,
              foregroundColor: context.palette.onInk,
              minimumSize: const Size(104, 48),
            ),
          ),
          const Spacer(),
          // 与左侧撤销按钮对称：两个主按钮保持视觉居中
          const SizedBox(width: 56),
        ],
      ),
    );
  }
}
