import 'package:flutter/widgets.dart';

/// 把**已挂载的全部元素**标脏一次，让下一帧整棵树重建（v2.57.0）。
///
/// 为什么需要它（这是本版夜间模式唯一一处"框架层面"的手法，理由要写清）：
///
/// 本 App 的底材 / 中性色是**模块级 getter**（`kPaper` / `kInkBlack` / `kRule`
/// …, 见 `app_tokens.dart` 里 [AppSurfaces] 的注释），不是 `InheritedWidget`。
/// 换明暗时 `MaterialApp` 换的是 `ThemeData`，框架只会重建"依赖 `Theme` 的
/// 元素"；而**路由页面自身的 widget 实例是被缓存的**
/// （`_ModalScopeState._page ??= ...`），一个不读 `Theme.of` 的页面根本不会
/// 重建 → 用户停在那页上会看到旧底材，要退出去再进来才变。
///
/// 所以换亮度后**显式**把整棵树标脏一次：下一帧所有元素重跑 `build`，所有
/// token 读到新那套值。代价 = 一次全树 rebuild，换主题是低频操作，可接受；
/// 好处是页面代码不需要为"响应明暗"做任何事（这也是本版不把 300+ 处 token
/// 改成 `context.xxx` 的前提）。
///
/// 调用时机：**帧结束后**（`addPostFrameCallback` 里）。`markNeedsBuild` 在
/// build 阶段调用会触发框架断言，且此时新主题已经装配完毕，标脏后重建拿到的
/// 一定是新值。
void markEverythingDirty() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return;
  // 广度优先遍历整棵树：先标脏、再下探（顺序无关，只要覆盖到）。
  final pending = <Element>[root];
  while (pending.isNotEmpty) {
    final element = pending.removeLast();
    // 未 active 的元素（正在卸载）直接跳过：markNeedsBuild 对它无意义。
    element.markNeedsBuild();
    element.visitChildren(pending.add);
  }
}

/// 换亮度后统一收口：等到当前帧画完，再把整棵树标脏。
///
/// 幂等可重复调用（同一帧内多次只会有一次真正的全树重建）。
void scheduleFullTreeRebuild() {
  WidgetsBinding.instance.addPostFrameCallback((_) => markEverythingDirty());
}
