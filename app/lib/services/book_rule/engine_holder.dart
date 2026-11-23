/// 规则引擎的宿主单例（R3 新增）。
///
/// ## 为什么必须「一个 App 一个引擎」
/// [WebViewRuleEngine] 的真实现里，一个实例 = 一个 `WebViewController` =
/// 一个原生 WebView。如果搜索页、详情页、阅读页各自 `new` 一个：
/// 1. **内存**：同时挂三个 WebView，每个都带着自己的渲染进程；
/// 2. **互相抢页面**：三个 controller 各自 `loadHtmlString`，页面在谁手里
///    说不清，求值结果是 A 的规则跑在 B 的文档上；
/// 3. **重复成本**：每次进页面都要重新建 WebView（几百毫秒起）。
///
/// 所以引擎**跟随 App 生命周期**：页面只 `reset()`（丢弃本页还在等的求值），
/// 不 `dispose()`。真正的 `dispose()` 留给 App 退出（本版没有调用点，
/// 进程结束由系统回收；即使调了也不会影响下一个页面，因为那时 App 已经走了）。
///
/// ## 为什么是「可注入的 holder」而不是直接暴露单例
/// `flutter test` 里没有 WebView 平台实现，`WebViewController()` 构造即抛。
/// 页面只依赖这个 holder，测试塞一个 [FakeRuleEngine] 就完全绕开原生：
/// `RuleEngineHolder.withEngine(FakeRuleEngine(...))`。
library;

import 'package:flutter/widgets.dart';

import 'rule_engine.dart';

/// 规则引擎宿主：懒建、单例、可注入。
class RuleEngineHolder {
  /// 全局单例（真机上搜索 / 详情 / 阅读三页共用这一个）。
  static final RuleEngineHolder instance = RuleEngineHolder();

  /// 自定义引擎工厂（测试注入假引擎；不传则首次使用时建 [WebViewRuleEngine]）。
  final BookRuleEngine Function()? _factory;

  BookRuleEngine? _engine;
  bool _disposed = false;

  RuleEngineHolder({BookRuleEngine Function()? engineFactory})
      : _factory = engineFactory;

  /// 直接包一个现成引擎（测试最常用）。
  RuleEngineHolder.withEngine(BookRuleEngine engine)
      : _factory = (() => engine);

  /// 取引擎（首次访问时才真正创建，避免「打开 App 就建 WebView」）。
  BookRuleEngine get engine {
    if (_disposed) throw StateError('规则引擎宿主已释放');
    return _engine ??= (_factory?.call() ?? WebViewRuleEngine());
  }

  /// 是否已经建出真 WebView 引擎（**不会**触发创建）。
  bool get hasWebViewEngine => _engine is WebViewRuleEngine;

  /// 引擎宿主 widget：必须挂进页面树里，隐藏的 WebView 才会真正创建。
  ///
  /// 假引擎（测试）返回 `SizedBox.shrink()`，不会碰任何原生接口。
  ///
  /// **这里走 [engine] getter 而不是读 `_engine`**：页面首次 build 时引擎
  /// 未必已经建出来（搜索页是点「搜索」时才第一次取 engine，`initState`
  /// 里不碰它）。读裸字段会安静地返回 `SizedBox.shrink()`，WebView 要等
  /// 下一次 setState 才进树 —— 那等于把「搜索前页面一定先取过 engine」这条
  /// 隐含时序约定藏进调用方。走 getter 则「要宿主 = 引擎已就绪」由代码保证：
  /// 建 WebView 的那几百毫秒本来也躲不掉，只是提前到首帧。
  Widget buildHost() {
    // 已释放时不再建新引擎（原行为是返回空盒子，别让它变成 build 期抛异常）
    if (_disposed) return const SizedBox.shrink();
    final e = engine;
    if (e is WebViewRuleEngine) return e.buildHost();
    return const SizedBox.shrink();
  }

  /// 页面离开时调：丢弃本页还在等的求值，但**不销毁**引擎。
  void reset() {
    _engine?.reset();
  }

  /// 释放（只有测试 / App 退出才需要）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final e = _engine;
    _engine = null;
    await e?.dispose();
  }
}
