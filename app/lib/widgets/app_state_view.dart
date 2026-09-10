import 'package:flutter/material.dart';

import '../services/loading_copy.dart';
import '../services/ui_copy_store.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import 'animated_copy_line.dart';
import 'dot_illustration.dart';
import 'smoke_silhouette.dart';

/// 状态视图的种类。
enum AppStateKind {
  /// 空态：细线插画 + 标题 +（可选）副文案 +（可选）动作。
  empty,

  /// 加载态：主墨转圈 +（可选）文案。
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

/// 加载态：主墨 24px 转圈 +（可选）文案。居中，尺寸克制。
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

  /// 转圈尺寸（直径，px）。默认 24，保持克制。
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
              SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.palette.inkText,
                ),
              ),
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

/// 整页加载态：风衣男抽烟剪影 + 主文案（单一 [Text]）+ 逐字特效副文案。
///
/// 与 [AppLoadingView] 的分工：那个是"轻量转圈"（保留给按钮 / 小容器），
/// 这个是"整页等待"的画面主角。**两处独立、互不影响**——本组件不动
/// [AppLoadingView] 的任何既有行为（它是 `test/app_state_view_test.dart`
/// 的尺寸/存在性断言锚点）。
///
/// ## 动画与无障碍
/// - 剪影 [SmokeSilhouette] 内是**无限循环动画**（`repeat()`），故整组件尊重
///   `MotionControl.of`（全局开关 + 系统"减少动画"）：关闭时剪影走静态一帧、
///   副文案 [AnimatedCopyLine] 退化成单个 [Text]（`pumpAndSettle` 能收敛，
///   测试环境默认就是这条路径）；
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
/// 剪影只能用在 [kPaper] 一类浅底材上（播放页黑底上 inkDeco 与底色对比不足，
/// 剪影会消失）。
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

  /// 剪影边长（px）。默认 160：整页等待时它是画面主角。
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
        // 纵向节奏：剪影 → 16 → 主文案 → 8 → 副文案。
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
