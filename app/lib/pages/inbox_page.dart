/// 信箱页（v2.13.0+ 起）：白名单 UP 主的新视频。
///
/// ## Tinder 式卡片栈（v2.19.0+）
/// 未读不再是一条条列表项，而是**一叠卡片**：
/// - 顶层卡片跟随手指左右拖动（位移 + 轻微旋转），松手按阈值判定：
///   **右滑 = 加入白名单**（未分类）、**左滑 = 跳过**（只记已处理，不动白名单），
///   没过阈值 → 弹回原位；
/// - 下层卡片**底边对齐**：用 `Positioned(bottom: -kInboxStackOffset)` 把它的
///   底边钉在顶层卡片底边之下，再按 [kInboxStackScale] 以底边为锚缩放 →
///   **净露出量恒为 [kInboxStackOffset]**，与两张卡片各自的内容高度（标题 1 行 /
///   2 行）无关（见 [_buildDeck] 的说明；旧实现用「固定下移 + 居中缩放」，
///   下一张比顶层矮时会被完全盖住）；
/// - 底部另有「跳过」/「加入」两个 ≥48dp 的按钮（不习惯滑的人 / 无障碍），
///   与滑动等价；右下角「撤销」可把上一张放回来（见 [_undoLast] 的说明）；
/// - 点按卡片仍然是老行为：打开播放页（与拖动手势由手势竞技场区分：
///   位移超过 touch slop 只能有一条胜出，所以「点」不会误触发拖动，
///   「拖」也不会误触发打开）。
///
/// ## ★ 后台检查不阻塞交互（v2.19.x）
/// `checkAll` 要串行遍历白名单 UP 主（每个间隔 ≥1.5s），100 个 UP 主要跑几分钟。
/// 这期间：
/// - 顶部 AppBar 显示一行「检查中…」（[_busyNote]），**仅提示、不禁用任何操作**；
/// - 用户照样能**划卡、点卡开播放页、撤销**（[_openItem] 只由 [_opening] 防连点）；
/// - 检查完成时用 [_mergeChecked] 合并结果：**只把新出现的条目追加到队尾**，
///   已经在队列里的、以及本次会话里被消费掉的（[_consumedBvids]）一律跳过 →
///   卡片栈**不会跳回第一张**，用户划过的不复活；
/// - 服务层配合：写盘前按最新「已处理」记录再过滤一次（见 `inbox_service.dart`
///   的「并发」小节），红点数与页面上这条队列保持一致。
/// 队列被清空（用户划完最后一张）而检查还在跑时，显示**空态**而不是整页加载态
/// （[_loadedOnce] 区分「划完了」与「还没加载出来」）。
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
/// - 飞出用 [kDurSlow]、弹回用 [kDurBase]，曲线 [kCurveOut]；
/// - [MotionControl.of] 为 false（`flutter test` 默认 / 系统「减少动画」）时
///   **连 AnimationController 都不建**，直接跳变 —— `pumpAndSettle` 必然收敛；
/// - 卡片子树挂在 `AnimatedBuilder` 的 `child:` 上，飞出期间不逐帧重建；
/// - 拖动期间不触发任何网络/存储请求，动作只在松手后执行。
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
import '../services/inbox_service.dart';
import '../services/service_locator.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';
import '../widgets/app_state_view.dart';
import '../widgets/inbox_swipe_card.dart';
import '../widgets/staggered_entrance.dart';
import 'player_page.dart';

/// 底部按钮行的高度（用于给卡片区留出高度预算）。
///
/// 两种形态同高：有卡片 = 48dp 按钮 + 12 + 16；空态 = 48dp「撤销上一张」+ 12 + 16。
const double _kBottomBarH = 76;

/// 未配置 GitHub 时的门禁提示（与搜索页 / 管理页文案一致）。
const String _kConfigHint = '请先到底部导航「个人」页配置 GitHub token 与 Gist ID';

/// 一次滑动/按钮操作的方向。
enum _Exit {
  /// 右滑：加入白名单
  like,

  /// 左滑：跳过（只记已处理）
  skip,
}

/// 当前正在跑的动画类型。
enum _SwipeAnim {
  /// 飞出屏幕
  exit,

  /// 弹回原位
  back,
}

/// 刚处理掉的一张（撤销用）。
class _SwipeRecord {
  const _SwipeRecord(this.item, {required this.liked});

  final InboxItem item;

  /// true = 右滑加入（可能已写白名单），false = 左滑跳过。
  final bool liked;
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
    with SingleTickerProviderStateMixin {
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
  final Set<String> _consumedBvids = <String>{};

  /// 正在 fetch view 元数据（防连点重复 push 播放页）。
  bool _opening = false;

  /// 交错入场的「已入场」账本：卡片被重建（换一张）时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 拖动位移（松手前实时跟随手指；松手后由动画接管）。
  Offset _drag = Offset.zero;

  /// 浮层标记的渐显进度（拖动时实时更新；飞出时钉在松手那一刻的值）。
  double _likeProgress = 0;
  double _skipProgress = 0;

  /// 动画区间（[_SwipeAnim.exit] 与 [_SwipeAnim.back] 共用一对端点）。
  Offset _animFrom = Offset.zero;
  Offset _animTo = Offset.zero;

  /// 当前动画类型；null = 静止（位移直接用 [_drag]）。
  _SwipeAnim? _anim;

  /// 飞出/弹回动画控制器；关动效时**恒为 null**（不建 ticker）。
  AnimationController? _fly;

  /// [MotionControl.of] 的当前值（didChangeDependencies 里刷新）。
  bool _motion = false;

  /// 正在提交（门禁检查/飞出中）→ 阻止重复触发。
  bool _deciding = false;

  /// 正在飞出的那张的方向（[_commitExit] 结算用）。
  _Exit? _exiting;

  /// 上一张（撤销用）。
  _SwipeRecord? _undo;

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
        ..addStatusListener(_onFlyStatus);
      return;
    }
    // 关动效：连 controller 都不留（不是建了不 forward），并立刻收尾
    _fly?.dispose();
    _fly = null;
    _anim = null;
    _drag = Offset.zero;
    _likeProgress = 0;
    _skipProgress = 0;
  }

  @override
  void dispose() {
    _fly?.removeStatusListener(_onFlyStatus);
    _fly?.dispose();
    _fly = null;
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
  /// 上给一行「检查中…」。回来时走 [_mergeChecked]（只追加新条目），当前正在
  /// 看的那张不会跳回第一张。
  Future<void> _checkNow() async {
    setState(() {
      _busyNote = '检查中…';
      _error = null;
    });
    _abortSwipe();
    try {
      final result = await ServiceLocator.inboxService.checkAll(force: true);
      if (!mounted) return;
      setState(() {
        // ★ 失败时 result.items 就是「上次缓存」——照样并进列表，
        //   绝不用空列表把画面打空（错误只在列表本身为空时占满整页）
        _busyNote = null;
        _loadedOnce = true;
        _error = result.failed ? result.message : null;
        _items = _mergeChecked(result.items);
      });
      if (result.failed && _items.isNotEmpty) {
        _showSnack(result.message);
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
    }
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
        _undo = null;
        _busyNote = null;
        // 用户显式清空 → 之后就是空态（不是"还没加载出来"）
        _loadedOnce = true;
        _error = null;
      });
      _showSnack('已全部标记已读');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyNote = null);
      _showSnack('标记已读失败：$e');
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
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      _showSnack('网络请求失败，请重试');
    } finally {
      _opening = false;
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 手势与动画
  // ---------------------------------------------------------------------------

  bool get _busy => _deciding || _anim != null;

  /// 位移：静止时 = 手指位移；动画中 = 端点之间按 [kCurveOut] 插值。
  Offset _offsetAt(double t) {
    if (_anim == null) return _drag;
    return Offset.lerp(_animFrom, _animTo, kCurveOut.transform(t))!;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_busy || _items.isEmpty) return;
    setState(() {
      // 只跟水平位移（纵向留给下拉刷新）：竖直抖动不再传导到卡片上
      _drag += Offset(details.delta.dx, 0);
      _updateProgress();
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_busy || _items.isEmpty) return;
    final screenW = MediaQuery.sizeOf(context).width;
    final vx = details.velocity.pixelsPerSecond.dx;
    final far = _drag.dx.abs() > screenW * kInboxSwipeThresholdRatio;
    final fast = vx.abs() > kInboxSwipeVelocity;
    if (!far && !fast) {
      _springBack();
      return;
    }
    final toRight = _drag.dx != 0 ? _drag.dx > 0 : vx > 0;
    unawaited(_decide(toRight ? _Exit.like : _Exit.skip));
  }

  /// 浮层渐显进度：水平位移达到阈值比例时满显。
  void _updateProgress() {
    final screenW = MediaQuery.sizeOf(context).width;
    final unit = screenW * kInboxSwipeThresholdRatio;
    final dx = _drag.dx;
    _likeProgress = dx > 0 ? (dx / unit).clamp(0.0, 1.0) : 0;
    _skipProgress = dx < 0 ? (-dx / unit).clamp(0.0, 1.0) : 0;
  }

  /// 没过阈值 → 弹回原位（不调用任何动作）。
  void _springBack() {
    if (_deciding) return;
    final c = _motion ? _fly : null;
    setState(() {
      // 没成一张 → 浮层立即收掉，卡片滑回原位
      _likeProgress = 0;
      _skipProgress = 0;
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
    c.duration = kDurBase;
    c.forward(from: 0);
  }

  /// 提交一张：右滑加入 / 左滑跳过。
  Future<void> _decide(_Exit kind) async {
    if (_deciding || _items.isEmpty) return;
    // 先上锁：门禁检查也是异步的，期间不能再拖/再点（防重复提交）
    _deciding = true;
    final item = _items.first;
    if (kind == _Exit.like) {
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
    _exiting = kind;
    // 记「已处理」+ 从本地未读缓存里摘掉 → 首页红点立刻下降（不触网）
    unawaited(ServiceLocator.inboxService.markHandled(item.bvid));
    if (kind == _Exit.like) {
      unawaited(_like(item));
    }
    final c = _motion ? _fly : null;
    if (c == null) {
      _commitExit();
      return;
    }
    final screenW = MediaQuery.sizeOf(context).width;
    setState(() {
      _animFrom = _drag;
      _animTo = Offset(
        (kind == _Exit.like ? 1 : -1) * screenW * 1.4,
        _drag.dy,
      );
      _anim = _SwipeAnim.exit;
    });
    c.duration = kDurSlow;
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
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      _showSnack('网络请求失败，请重试');
    } on GithubApiException catch (e) {
      if (!mounted) return;
      _showSnack('加入失败：${e.message}');
    }
  }

  /// 动画结束：确认动画类型。
  void _onFlyStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final mode = _anim;
    _anim = null;
    if (mode == _SwipeAnim.exit) {
      _commitExit();
      return;
    }
    if (!mounted) return;
    setState(() => _drag = Offset.zero);
  }

  /// 结算「这张已经处理掉了」：出栈 + 记入撤销位 + 复位手势状态。
  void _commitExit() {
    final exit = _exiting;
    final item = _items.isEmpty ? null : _items.first;
    _exiting = null;
    _anim = null;
    _deciding = false;
    if (!mounted) return;
    setState(() {
      if (item != null) {
        final bvid = item.bvid;
        // 记账：这一轮 checkAll 还在跑的话，它返回的列表里可能还有这张
        // → [_mergeChecked] 靠这份记录把它挡在队列外（不复活）
        _consumedBvids.add(bvid);
        _items = [
          for (final it in _items)
            if (it.bvid != bvid) it,
        ];
        _undo = _SwipeRecord(item, liked: exit == _Exit.like);
      }
      // 屏上的卡片全处理完了 → 收起「上次检查失败」的提示（错误态不该盖住
      // 「没有未读了」这个结论；要重试还可以下拉刷新）
      if (_items.isEmpty) _error = null;
      _drag = Offset.zero;
      _likeProgress = 0;
      _skipProgress = 0;
    });
  }

  /// 刷新/离开前收尾：把正在飞出的那张按已完成结算（动作早已发出），
  /// 并清掉拖动与浮层状态（避免刷新回来后残留一个半飞的卡片）。
  void _abortSwipe() {
    _fly?.stop();
    if (_anim == _SwipeAnim.exit) {
      _commitExit();
      return;
    }
    _anim = null;
    _drag = Offset.zero;
    _likeProgress = 0;
    _skipProgress = 0;
  }

  /// 撤销上一张：放回队首 + 删掉「已处理」记录。
  ///
  /// **不会**自动把已经写进白名单的视频移除（那是一次不可逆的 Gist 写操作），
  /// 所以提示文案里明确说明——让用户自己决定要不要再去白名单删掉。
  ///
  /// 空态（刚划掉最后一张）也能用：底部栏在无卡片时只留这一个入口。
  void _undoLast() {
    final rec = _undo;
    if (rec == null) return;
    _undo = null;
    unawaited(ServiceLocator.inboxService.unmarkHandled(rec.item));
    setState(() {
      // 撤销 → 这条不再算「已消费」：检查回来的合并结果里可以重新出现它
      _consumedBvids.remove(rec.item.bvid);
      _items = [rec.item, ..._items];
      _loadedOnce = true;
      _drag = Offset.zero;
      _likeProgress = 0;
      _skipProgress = 0;
      _anim = null;
    });
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
      body: RefreshIndicator(
        onRefresh: _checkNow,
        child: _buildBody(),
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
  Widget _buildDeck() {
    final media = MediaQuery.of(context);
    // 可用高度 ≈ 窗口高 - 状态栏 - AppBar（略微高估也无妨：内容超出就滚动）
    final bodyH = math.max(
      media.size.height - media.padding.top - kToolbarHeight,
      240.0,
    );
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
                  final cardW = math.min(cons.maxWidth * 0.88, 420.0);
                  final maxCoverH = math.max(
                    availableH - kInboxCardInfoH - _kBottomBarH - kSpace24,
                    96.0,
                  );
                  final coverH = math.min(cardW * 9 / 16, maxCoverH);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        // 只定宽：高度由**顶层卡片**决定（Stack 取非定位子项的
                        // 自然高度），下层卡片才拿得到"顶层底边"当对齐基准
                        width: cardW,
                        child: Stack(
                          alignment: Alignment.topCenter,
                          // 下层卡片会伸到 Stack 框外 → 别裁（否则"一角"被切掉）
                          clipBehavior: Clip.none,
                          children: [
                            // ★ 绘制顺序：下层卡片在前、顶层卡片在后（Stack 按
                            //   children 顺序绘制）→ 顶层盖住下层，只露底边那一条。
                            //
                            // ★ 底边对齐：Positioned 的 `bottom` 是相对**父容器
                            //   底边**（= 顶层卡片底边）算的，缩放锚点再用
                            //   `bottomCenter`（底边不动）→ 下层卡片的底边恒定落在
                            //   顶层底边之下 [kInboxStackOffset]。
                            //   净露出量与两张卡片各自的内容高度（标题 1 行 / 2 行）
                            //   **无关**：旧实现「固定下移 + 居中缩放」在下一张更矮
                            //   时，居中缩放会让它的底边上收超过下移量 → 完全盖住。
                            if (_items.length > 1)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: -kInboxStackOffset,
                                child: StaggeredEntrance(
                                  entryKey: 'bvid:${_items[1].bvid}',
                                  index: 1,
                                  child: IgnorePointer(
                                    child: Transform.scale(
                                      scale: kInboxStackScale,
                                      alignment: Alignment.bottomCenter,
                                      child: InboxSwipeCard(
                                        item: _items[1],
                                        width: cardW,
                                        coverHeight: coverH,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            _buildTopCard(_items.first, cardW, coverH),
                          ],
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

  /// 顶层卡片：手势 + 跟随/旋转 + 浮层标记。
  Widget _buildTopCard(InboxItem item, double cardW, double coverH) {
    final card = InboxSwipeCard(
      item: item,
      width: cardW,
      coverHeight: coverH,
      likeProgress: _likeProgress,
      skipProgress: _skipProgress,
    );
    final gesture = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 点按（打开播放页）与横向拖动共存：手势竞技场按位移裁决
      onTap: () => unawaited(_openItem(item)),
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _springBack,
      child: card,
    );
    final c = _motion ? _fly : null;
    return StaggeredEntrance(
      entryKey: 'bvid:${item.bvid}',
      index: 0,
      child: c == null
          ? _decorate(gesture, 1)
          : AnimatedBuilder(
              animation: c,
              // ★ 必须传 child：飞出/弹回期间卡片子树不逐帧重建
              child: gesture,
              builder: (_, child) => _decorate(child!, c.value),
            ),
    );
  }

  /// 位移 + 旋转（旋转角与水平位移成正比，最多 ±[kInboxSwipeMaxTilt]）。
  Widget _decorate(Widget child, double t) {
    final off = _offsetAt(t);
    final screenW = MediaQuery.sizeOf(context).width;
    final tilt =
        (off.dx / screenW).clamp(-1.0, 1.0) * kInboxSwipeMaxTilt;
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
            onPressed: _undo == null ? null : _undoLast,
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
              onPressed: _undo == null ? null : _undoLast,
              icon: const Icon(Icons.undo),
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: disabled ? null : () => unawaited(_decide(_Exit.skip)),
            icon: const Icon(Icons.close, size: 18),
            label: const Text('跳过'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(104, 48),
            ),
          ),
          const SizedBox(width: kSpace12),
          FilledButton.icon(
            onPressed: disabled ? null : () => unawaited(_decide(_Exit.like)),
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
