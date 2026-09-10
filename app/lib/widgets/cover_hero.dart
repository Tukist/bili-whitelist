/// 封面 Hero 包装件（列表封面 → 播放页封面的飞行动效）。
///
/// 设计取向：**零影响优先**。Hero 一旦进树，就会引入 `HeroMode` /
/// placeholder / 飞行 shuttle 这一套机制，还会在两端 route 之间建立 tag 配对
/// ——不需要它的页面不该为此付任何代价。所以 [CoverHero.tag] 为 null（或
/// [CoverHero.enabled] = false）时**直接 return child**：树里连 `Hero`
/// 节点都不出现，行为与"没做过这个改造"逐字节一致。
library;

import 'package:flutter/material.dart';

/// Hero tag 工厂：**bvid 为空 → null**（调用方据此完全不包 [CoverHero]）。
///
/// 分集视频用 [pageIndex] 区分：同一个 bvid 的各集封面是不同 URL，
/// 共用 tag 会让 Hero 在切换分集时"飞错图"。
///
/// ⚠️ **tag 必须在同一个 route 内唯一**（真实约束，不是建议）：
/// 同一个 bvid 的封面在同一个页面里出现两次（如播放页信息块 + 相关推荐列表、
/// 或同一列表的数据重复）→ 两端配对时 Flutter 会直接
/// `assert` 报 "multiple heroes share the same tag"。
/// 处理方式二选一：给重复项改用 [pageIndex]（或其他区分维度）生成不同 tag，
/// 或者其中一处传 `tag: null`（不参与 Hero）。
String? coverHeroTag(String bvid, {int? pageIndex}) {
  if (bvid.isEmpty) return null;
  return pageIndex == null ? 'cover:$bvid' : 'cover:$bvid#$pageIndex';
}

/// 封面 Hero 包装件：`CoverHero(tag: coverHeroTag(bvid), child: CoverImage(...))`。
///
/// **零影响保证**：[tag] 为 null（或 [enabled] = false）→ 直接返回 [child]，
/// 不做任何包装——不产生 `Hero` / `HeroMode` / placeholder，也不影响 layout
/// 与 hit test。
///
/// **多选 / 拖拽态整体关闭**：整片区域套 Flutter 自带的
/// `HeroMode(enabled: false, child: ...)` 即可（不另造 API）——
/// 多选或拖拽期间列表项会被移入 / 移出 overlay，此时若还有 Hero 在配对，
/// 会飞出"残影封面"。单点关掉用 [enabled] = false，整块关掉用 `HeroMode`。
class CoverHero extends StatelessWidget {
  const CoverHero({
    super.key,
    required this.tag,
    required this.child,
    this.enabled = true,
  });

  /// Hero tag（用 [coverHeroTag] 生成）；null → 完全不包 Hero。
  final String? tag;

  /// 封面本体（一般传共享的 `CoverImage`）。
  final Widget child;

  /// 单点开关：false → 同 [tag] 为 null，直接返回 [child]。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = tag;
    if (t == null || !enabled) return child;
    return Hero(
      tag: t,
      // 两端 fly 的都是 Image：`flightShuttleBuilder` 固定取 `to` 一侧的
      // **child**（即那个 Image），保证飞行中不因两端 Image 配置
      // （headers / fit）不同而跳变；叠一条 0.6 → 1.0 的淡入，落地瞬间
      // 不"啪"地闪一下。
      //
      // 注意 `toHeroContext.widget` 是 **Hero 本身**（`from/toHeroContext`
      // 是两端 Hero 的 BuildContext，见 Flutter `_defaultHeroFlightShuttleBuilder`
      // 的 `toHeroContext.widget as Hero`），所以这里要往下取一层 `.child`：
      // 直接塞 `toHeroContext.widget` 会在 shuttle 里再嵌一个 Hero，
      // 飞行层里凭空多一层 Hero 机制。
      flightShuttleBuilder: (flightContext, animation, flightDirection,
              fromHeroContext, toHeroContext) =>
          FadeTransition(
        opacity: animation.drive(Tween(begin: 0.6, end: 1.0)),
        child: (toHeroContext.widget as Hero).child,
      ),
      child: child,
    );
  }
}
