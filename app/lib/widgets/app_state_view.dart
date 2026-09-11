import 'package:flutter/material.dart';

import '../services/loading_copy.dart';
import '../services/ui_copy_store.dart';
import '../theme/app_motion.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';
import 'animated_copy_line.dart';
import 'dot_illustration.dart';
import 'smoke_silhouette.dart';

/// 状态视图的种类。
enum AppStateKind {
  /// 空态：细线插画 + 标题 +（可选）副文案 +（可选）动作。
  empty,

  /// 加载态：三颗方点依次亮起（[AppLoadingView] / [PressDots]）+（可选）文案。
  ///
  /// 用在"整块区域的等待"：`favorite_videos_page` 拉全量收藏视频时用它
  /// （`scrollable: true` + 进度文案）。整页等待用 [AppLoadingHero]
  /// （那是画面主角，不是这里的轻量指示）。
  loading,

  /// 错误态：细线插画（错误墨）+ 标题 + 副文案 + 重试按钮。
  error,
}

/// 全 App 统一的状态视图：**空态 / 加载态 / 错误态**一套封装。
///
/// 取代此前 18 处各写各的「Icon(56) + SizedBox(12) + Text」手写空态，
/// 以及两份逐字重复的私有 `_StateView`。
///
/// ## ★ 硬约束：宿主用 `RefreshIndicator` 的空态必须 `scrollable: true`
///
/// 大量空态是靠「可滚动的 ListView（AlwaysScrollableScrollPhysics）」撑开
/// 可滚动区域，才能让宿主的 [RefreshIndicator] 下拉刷新生效（见
/// `favorites_page.dart` 里 `_StateView` 的注释）。所以：
///
/// - 宿主包了 `RefreshIndicator`（或自带下拉刷新）→ **一律 `scrollable: true`**；
/// - 纯静态区域（底部弹层里、已有外层滚动视图内）→ `scrollable: false`
///   （此时是居中布局，**父级要有界高度**，别直接塞进 `Column`）。
///
/// `scrollable: true` 的输出结构与既有实现**功能等价**：
/// `ListView(AlwaysScrollableScrollPhysics) → [kEmptyTopGap, 插画, 16, 标题, 8, 副文案, (16 + 按钮)]`。
///
/// ## 文案
/// - [copyId] 非空 → 主文案走 [UiCopyStore]（用户可在设置页改写，逐字默认值
///   与旧文案一致）；[copyId] 为 null → 用 [title] 直给。
/// - 副文案同理：[subtitleCopyId] 非空走 store，否则用 [subtitle] 直给
///   （约定副文案 id = 主 id + `.sub`）。
/// - 组件自己监听 [UiCopyStore]，设置页改完立刻刷新。
///
/// ## 对比度 / 触摸目标（Android 移动设计规范）
/// - 标题 [kTypeTitleM] + [kInkBlack]，副文案 [kTypeBody] + [kInkGray70]（≥ 4.5:1）；
/// - 动作按钮高度 48dp（触摸目标 ≥ 48dp）。
class AppStateView extends StatelessWidget {
  const AppStateView({
    super.key,
    required this.kind,
    this.copyId,
    this.title,
    this.subtitle,
    this.subtitleCopyId,
    this.actionLabel,
    this.onAction,
    this.illustrationSeed = 'state',
    this.scrollable = false,
  });

  /// 状态种类。
  final AppStateKind kind;

  /// 主文案 id（走 [UiCopyStore]，可被用户在设置页改写）。
  final String? copyId;

  /// 主文案直给（仅 [copyId] 为 null 时生效）。
  final String? title;

  /// 副文案直给（仅 [subtitleCopyId] 为 null 时生效）。
  final String? subtitle;

  /// 副文案 id（走 [UiCopyStore]）；约定为 `<主 id>.sub`。
  final String? subtitleCopyId;

  /// 动作按钮文案（如「重试」「搜索并加入 UP 主」）；为空则不显示按钮。
  final String? actionLabel;

  /// 动作回调：为空则不显示按钮。
  final VoidCallback? onAction;

  /// 插画种子：**建议传页面 ID**（如 `'empty.history'`），同 seed 同图案。
  final String illustrationSeed;

  /// 是否用 `ListView(AlwaysScrollableScrollPhysics)` 承载（保住宿主下拉刷新）。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UiCopyStore.instance,
      builder: (context, _) {
        final resolvedTitle = _resolve(copyId, title);
        final resolvedSubtitle = _resolve(subtitleCopyId, subtitle);

        if (kind == AppStateKind.loading) {
          final loading = AppLoadingView(message: resolvedTitle);
          if (!scrollable) return loading;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: kSectionPadH),
            children: [
              const SizedBox(height: kEmptyTopGap),
              loading,
            ],
          );
        }

        final children = _contentChildren(
          context,
          resolvedTitle: resolvedTitle,
          resolvedSubtitle: resolvedSubtitle,
        );
        if (!scrollable) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSectionPadH),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          );
        }
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: kSectionPadH),
          children: [
            const SizedBox(height: kEmptyTopGap),
            ...children,
          ],
        );
      },
    );
  }

  /// 非加载态的正文（插画 → 标题 → 副文案 → 动作）。
  List<Widget> _contentChildren(
    BuildContext context, {
    required String? resolvedTitle,
    required String? resolvedSubtitle,
  }) {
    final palette = context.palette;
    // 错误态用语义红做细线（1px 线很细，不会破坏 mono-color 的克制），
    // 空态用主墨（已过对比度护栏）。
    final ink = kind == AppStateKind.error ? kError : palette.inkText;
    final children = <Widget>[
      Center(
        child: DotIllustration(
          seed: illustrationSeed,
          ink: ink,
          accent: palette.accent,
        ),
      ),
    ];
    if (resolvedTitle != null) {
      children.add(const SizedBox(height: kSpace16));
      children.add(
        Text(
          resolvedTitle,
          textAlign: TextAlign.center,
          style: kTypeTitleM.copyWith(color: kInkBlack),
        ),
      );
    }
    if (resolvedSubtitle != null) {
      children.add(const SizedBox(height: kSpace8));
      children.add(
        Text(
          resolvedSubtitle,
          textAlign: TextAlign.center,
          style: kTypeBody.copyWith(color: kInkGray70),
        ),
      );
    }
    if (actionLabel != null && onAction != null) {
      children.add(const SizedBox(height: kSpace16));
      children.add(
        Center(
          child: FilledButton(
            onPressed: onAction,
            style: FilledButton.styleFrom(
              backgroundColor: palette.inkFill,
              foregroundColor: palette.onInk,
              // Android 规范：触摸目标 ≥ 48dp
              minimumSize: const Size(120, 48),
            ),
            child: Text(actionLabel!),
          ),
        ),
      );
    }
    return children;
  }

  /// 直给优先；直给为空时按 id 走 store；两者都没有 → null（不渲染这一段）。
  String? _resolve(String? id, String? direct) {
    if (direct != null && direct.trim().isNotEmpty) return direct;
    if (id != null && id.trim().isNotEmpty) return UiCopyStore.instance.text(id);
    return null;
  }
}

/// 加载态：三颗方点依次亮起（[PressDots]）+（可选）文案。居中，尺寸克制。
///
/// 指示器是印刷语言（方点 = 铅字，节拍 = 印刷走纸的 [kPressCycle]），与整页
/// 加载态主角 [SmokeSilhouette] 同源。**它不"取代"全 App 的转圈**：
/// 2.21.0 曾在本类注释里写"那是全 App 最后一只别人家的转圈"，与事实不符
/// ——实测 `lib/` 下有 22 处 Material 的 `CircularProgressIndicator`；本轮只把
/// 其中 3 处"整块等待"（见下）换成这里，仍有 19 处按各自语义保留。
///
/// ## 它用在哪儿（整块区域的等待）
/// - `favorite_videos_page`：搜索态拉全量收藏视频 → 走 [AppStateView] 的
///   `kind: loading`（`scrollable: true` + 进度文案）；
/// - `favorites_import_dialog`：收藏夹选择弹层（`_folders == null`）那一块；
/// - `login_page`：WebView 就绪前的那一块。
///
/// ## 哪些地方**仍然**用 Material 的 `CircularProgressIndicator`（如实清单）
/// 只替换"整页 / 整块的等待画面"。下面几类都不是等待画面，**保留**：
/// - **按钮内联**（操作反馈，12–22px）：`add_success_button`、
///   `playlist_page` 导入、`followings_import_page` 加入、`upowner_page` 与
///   `upowner_tile` 关注、`manage_panel` 保存、`comment_list` 加载更多、
///   `favorites_import_dialog` 进度对话框的状态行、`pgc_import_dialog`；
/// - **进度 / 缓冲**（有确定进度或播放语义，不是"不知道要等多久"）：
///   `player_page` 的下载环（`value: task.progress`）与播放器缓冲环、
///   `image_viewer_page` 的大图与"加载更多"、`comment_list` 楼层懒加载；
/// - **黑底反色底材**（播放页 `kPlayerPaper` 那一套）：`ink` 与底色对比不足
///   甚至消失，`player_page` 的 3 处等待仍在 Material 上；
/// - **图片 / 封面占位**：`cover_image`（封面未回来时的小转圈）；
/// - **本次改动范围外的文件**：`comment_list` 的评论区整块加载、`manage_panel`。
///
/// 本类走后两类的分工：**整页**等待给 [AppLoadingHero]（画面主角），
/// **整块/内联**等待给这里（三颗方点，占位 24×24）。
class AppLoadingView extends StatelessWidget {
  const AppLoadingView({
    super.key,
    this.message,
    this.copyId,
    this.size = 24,
  });

  /// 文案直给。
  final String? message;

  /// 文案 id（走 [UiCopyStore]）。
  final String? copyId;

  /// 指示器占位边长（px）。默认 24，保持克制（= 原转圈的直径）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UiCopyStore.instance,
      builder: (context, _) {
        final text = (message != null && message!.trim().isNotEmpty)
            ? message
            : (copyId != null && copyId!.trim().isNotEmpty
                ? UiCopyStore.instance.text(copyId!)
                : null);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PressDots(size: size),
              if (text != null) ...[
                const SizedBox(height: kSpace12),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: kTypeBodyS.copyWith(color: kInkGray70),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 三颗方点的静态帧（[PressDots.animate] = false 或 [MotionControl] 关）取的进度：
/// 0 = 第一颗亮。停在周期起手相，而不是随便挑一帧——静态态与动效的第一帧一致。
const double kStaticPressDotsT = 0.0;

/// 方点数。
const int _kDotCount = 3;

/// 方点边长（px）：与印刷走纸的领墨笔尖同一个量级（**方 = 铅字**）。
///
/// ⚠️ 待设备复核：2.2dp 在 420dpi 上约 5.8 设备像素，与 2.21.0 那颗被判定
/// "太弱"的领墨方块同一量级。本轮只在页面侧把它**真正用起来**（3 处），
/// 尺寸维持原值不动（三颗并排、其中一颗是 accent，比单颗更认得出来）；
/// 若实测仍嫌弱，改这一个常量即可（占位 24×24 与三颗间距都不受影响）。
const double _kDotSide = 2.2;

/// 未亮起那颗方点的墨量（相对主墨）：低到不抢注意力，又看得见"一共三颗"。
const double _kDimAlpha = 0.22;

/// 印刷语言的等待指示：**三颗方点依次亮起**（方 = 铅字，圆点是空态插画的活）。
///
/// 语言上与加载态主角 [SmokeSilhouette] 的「印刷走纸」同源 —— 都由
/// "**一颗 accent 方块落在墨上**"表达"现在进行到哪儿"，节拍也共用
/// [kPressCycle]（2.8s，三颗各亮约 933ms）。
///
/// 它是"**整块 / 内联等待**"的指示（由 [AppLoadingView] 承载），而**不是**
/// "全 App 唯一的转圈"：`lib/` 下仍有 19 处 Material
/// `CircularProgressIndicator`（按钮内联 / 进度缓冲 / 黑底反色 / 图片占位）
/// 按各自语义保留，清单见 [AppLoadingView] 的注释。
///
/// 占位是 [size] × [size] 的正方形，三颗点的中心在 `size × (1/4, 2/4, 3/4)`
/// 处水平排开、垂直居中：默认 24 时与原来的转圈占位**完全一致**，
/// 调用方的布局不用改。
///
/// 动效走 [MotionControl]（装饰性动效总开关 + 系统"减少动画"）：关掉时停在
/// `t = 0` 那一帧（第一颗亮、另两颗低墨量）——静态但不空场，且与动画的第一帧
/// 完全一致，不会多出一个"停住了"的怪状态。
class PressDots extends StatefulWidget {
  const PressDots({
    super.key,
    this.size = 24,
    this.animate = true,
  });

  /// 占位边长（px）。
  final double size;

  /// 是否让方点依次亮起。false → 静态一帧（t = 0），零 ticker。
  final bool animate;

  /// 当前存活的 ticker 数（**仅供测试断言不泄漏**）。
  @visibleForTesting
  static int activeTickers = 0;

  @override
  State<PressDots> createState() => _PressDotsState();
}

class _PressDotsState extends State<PressDots>
    with SingleTickerProviderStateMixin {
  /// 仅当真的要走动画路径时才非空（静态路径恒为 null → 零 ticker）。
  AnimationController? _ctl;

  /// 当前是否处于动画路径（= [_ctl] 非空）。
  bool _animating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyMotion(widget.animate && MotionControl.of(context));
  }

  @override
  void didUpdateWidget(PressDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) {
      _applyMotion(widget.animate && MotionControl.of(context));
    }
  }

  /// 把「是否跑动画」落到实际 ticker 上：只在状态翻转时增删，重复调用无副作用。
  void _applyMotion(bool want) {
    if (want == _animating) return;
    _animating = want;
    if (want) {
      _ctl = AnimationController(vsync: this, duration: kPressCycle)..repeat();
      PressDots.activeTickers++;
      return;
    }
    final old = _ctl;
    _ctl = null;
    if (old != null) {
      old.dispose();
      PressDots.activeTickers--;
    }
  }

  @override
  void dispose() {
    // 卸载前走一次静态分支：统一 ticker 计数与释放，计数器必然归零。
    _applyMotion(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.size;
    // 非法尺寸：不绘制、不抛异常（父级拿到零尺寸占位）
    if (!(side > 0) || !side.isFinite) return const SizedBox.shrink();

    final palette = context.palette;
    final ctl = _animating ? _ctl : null;

    // 纯装饰：对无障碍树没有语义贡献（"正在加载"由文案承担），整体排除。
    return ExcludeSemantics(
      child: SizedBox(
        width: side,
        height: side,
        child: CustomPaint(
          painter: PressDotsPainter(
            ink: palette.inkText,
            accent: palette.accent,
            progress: ctl,
          ),
        ),
      ),
    );
  }
}

/// 三颗方点的画笔（公开以便单测直接断言，与 [SmokeSilhouettePainter] 同约定）。
///
/// **每帧只 paint，不 rebuild**：动画驱动挂在 [progress]（即
/// `AnimationController`）这个 listenable 上，`paint` 时才读 `progress.value`。
/// 每帧开销：3 次 `drawRect`，无 blur、无 Path。
class PressDotsPainter extends CustomPainter {
  PressDotsPainter({
    required this.ink,
    required this.accent,
    this.progress,
  }) : super(repaint: progress);

  /// 未亮起的点：主墨降到低墨量（不抢注意力）。
  final Color ink;

  /// 当前亮起的那颗：点缀墨（"现在"是时间信息）。
  final Color accent;

  /// 动画进度源；**null = 静态路径**（画 t = 0 那一帧，零 ticker）。
  final Animation<double>? progress;

  /// 当前用于绘制的进度。
  double get effectiveT => progress?.value ?? kStaticPressDotsT;

  /// 测试专用：第 [i] 颗点在边长 [side] 的画布上的中心
  /// （三颗排在 `side × (1/4, 2/4, 3/4)` 处、垂直居中）。
  @visibleForTesting
  static Offset dotCenterAt(int i, double side) =>
      Offset(side * (i + 1) / (_kDotCount + 1), side / 2);

  /// 测试专用：[t] 时正在亮的那颗的序号（0–2）。
  @visibleForTesting
  static int litIndexAt(double t) {
    final i = (t * _kDotCount).floor() % _kDotCount;
    return i < 0 ? 0 : i;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final side = size.shortestSide;
    if (!(side > 0)) return;
    final lit = litIndexAt(effectiveT);
    final base = Paint()..isAntiAlias = true;
    for (var i = 0; i < _kDotCount; i++) {
      base.color =
          i == lit ? accent : ink.withValues(alpha: ink.a * _kDimAlpha);
      canvas.drawRect(
        Rect.fromCenter(
          center: dotCenterAt(i, side),
          width: _kDotSide,
          height: _kDotSide,
        ),
        base,
      );
    }
  }

  /// 颜色变了 / 静态↔动画切换了才重绘（动画期间由 [progress] 驱动，不 rebuild）。
  @override
  bool shouldRepaint(PressDotsPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.accent != accent ||
      (oldDelegate.progress == null) != (progress == null);
}

/// 错误态：细线插画（错误墨）+ 标题 + 副文案 + 重试按钮。
///
/// 网络 / 风控 / 解析失败都走这里；[message] 直接给接口错误文案
/// （旧代码里就是 `_error!`），不给则用出厂默认 `error.generic`。
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    this.message,
    this.copyId,
    this.subtitle,
    this.subtitleCopyId,
    this.onRetry,
    this.retryLabel = '重试',
    this.illustrationSeed = 'error',
    this.scrollable = false,
  });

  /// 错误文案直给（通常是接口返回的错误信息）。
  final String? message;

  /// 错误文案 id（走 [UiCopyStore]）；[message] 为空时才生效。
  final String? copyId;

  /// 副文案直给。
  final String? subtitle;

  /// 副文案 id（走 [UiCopyStore]）。
  final String? subtitleCopyId;

  /// 重试回调；为空则不显示按钮。
  final VoidCallback? onRetry;

  /// 重试按钮文案。
  final String retryLabel;

  /// 插画种子（建议传页面 ID）。
  final String illustrationSeed;

  /// 是否 `scrollable`（宿主有下拉刷新 → true）。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final hasMessage = message != null && message!.trim().isNotEmpty;
    return AppStateView(
      kind: AppStateKind.error,
      copyId: hasMessage ? null : (copyId ?? 'error.generic'),
      title: hasMessage ? message : null,
      subtitle: subtitle,
      subtitleCopyId: subtitleCopyId,
      actionLabel: onRetry == null ? null : retryLabel,
      onAction: onRetry,
      illustrationSeed: illustrationSeed,
      scrollable: scrollable,
    );
  }
}

/// 整页加载态：印刷走纸 [SmokeSilhouette] + 主文案（单一 [Text]）+ 逐字特效副文案。
///
/// 与 [AppLoadingView] 的分工：那个是"**整块**等待指示"（三颗方点 [PressDots]，
/// 用在弹层正文、页面里的一块区域），这个是"**整页**等待"的画面主角。
/// **两处独立、互不影响** —— 本组件不引用 [AppLoadingView] 的任何状态。
///
/// ## 动画与无障碍
/// - [SmokeSilhouette] 内是**无限循环动画**（`repeat()`），故整组件尊重
///   `MotionControl.of`（全局开关 + 系统"减少动画"）：关闭时它走静态一帧
///   （"第 3 条线正在画"）、副文案 [AnimatedCopyLine] 退化成单个 [Text]
///   （`pumpAndSettle` 能收敛，测试环境默认就是这条路径）；
/// - 主文案**刻意用单一 [Text]**（不走逐字特效）：它是页面测试 `find.text`
///   的断言锚点，拆成逐字 widget 会让断言全部失效。
///
/// ## ★ 硬约束：宿主用 `RefreshIndicator` 的加载态一律 `scrollable: true`
/// 与 [AppStateView] 同约定：`scrollable: true` 才用
/// `ListView(AlwaysScrollableScrollPhysics)` 撑开可滚动区域，宿主的下拉刷新
/// 才生效；纯静态区域（底部弹层里、已有外层滚动视图内）用 `false`，
/// 此时是居中布局，**父级要有界高度**。
///
/// ## 底材限制
/// 只能用在 [kPaper] 一类浅底材上（播放页黑底上 inkDeco 与底色对比不足，
/// 文字线会消失）。
class AppLoadingHero extends StatelessWidget {
  const AppLoadingHero({
    super.key,
    this.copyId = 'loading.generic',
    this.title,
    this.pool = kLoadingPoolPage,
    this.seed = 'loading',
    this.size = 160,
    this.scrollable = false,
    this.shrink = false,
  });

  /// 主文案 id（走 [UiCopyStore]，用户可在设置页改写）。
  /// 出厂默认 `'loading.generic'`（= 「正在加载…」）。
  final String? copyId;

  /// 主文案直给；非空时**压过** [copyId]（与它"二选一"）。
  final String? title;

  /// 副文案池（默认 [kLoadingPoolPage]，整页加载）。
  final List<String> pool;

  /// 决定池里挑哪一条（**确定性**：同 seed 同一条，不闪变、可测试）。
  /// 一般传页面名，且整页生命周期内保持不变。
  final String seed;

  /// 印刷走纸画面边长（px）。默认 160：整页等待时它是画面主角。
  final double size;

  /// 是否用 `ListView(AlwaysScrollableScrollPhysics)` 承载
  /// （宿主有 `RefreshIndicator` → 必须 true）。
  final bool scrollable;

  /// true → 不撑满、靠上（用于内嵌区块），也不顶 [kEmptyTopGap] 的整页留白。
  final bool shrink;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UiCopyStore.instance,
      builder: (context, _) {
        final titleText = _resolveTitle();
        // 纵向节奏：印刷走纸 → 16 → 主文案 → 8 → 副文案。
        // 主文案缺省时不留空档（16 的间隔跟着主文案一起省掉）。
        final content = <Widget>[
          SmokeSilhouette(size: size),
          const SizedBox(height: kSpace16),
          if (titleText != null)
            Text(
              titleText,
              textAlign: TextAlign.center,
              style: kTypeTitleM.copyWith(color: kInkBlack),
            ),
          const SizedBox(height: kSpace8),
          AnimatedCopyLine(
            text: loadingCopyFor(pool: pool, seed: seed),
            style: kTypeBodyS.copyWith(color: kInkGray70),
          ),
        ];

        if (scrollable) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: kSectionPadH),
            children: [
              const SizedBox(height: kEmptyTopGap),
              ...content,
            ],
          );
        }
        if (shrink) {
          // 内嵌区块：靠上、不撑满（Column 默认主轴对齐 start）
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSectionPadH),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: content,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSectionPadH),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: content,
            ),
          ),
        );
      },
    );
  }

  /// 主文案：直给 [title] 优先；否则按 [copyId] 走 [UiCopyStore]；
  /// 两者都为空 → null（不渲染这一段）。
  String? _resolveTitle() {
    final direct = title;
    if (direct != null && direct.trim().isNotEmpty) return direct;
    final id = copyId;
    if (id != null && id.trim().isNotEmpty) return UiCopyStore.instance.text(id);
    return null;
  }
}
