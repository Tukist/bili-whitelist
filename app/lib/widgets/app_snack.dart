/// 全 App 统一的「底部提示条」入口（v2.36.0）。
///
/// ## 为什么要有这个入口
/// 全 App 上百处提示原先各写各的
/// `ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(...)`，
/// 于是「设置里关掉底部黑框提示」这件事**没有任何一处能收口**。这里把三件事
/// 一次做完：
///
/// 1. **按语义分类**（[SnackKind]）：只有 [SnackKind.info]（提示 / 成功 /
///    门禁文案）会被设置里的「界面提示」开关挡掉；
/// 2. **错误类（[SnackKind.error]）永不被挡**。关掉提示是为了清静，不是为了
///    让失败静默 ——「保存失败」「未同步到 Gist（本地已生效）」「网络请求失败」
///    这类必须照样弹：用户以为操作成功了、实际上白名单没写上去 / 缓存没删掉，
///    比多看一条提示糟糕得多（失败静默 = 数据悄悄不对）；
/// 3. **带 [SnackBarAction] 的一律不挡**。[action] 是用户最后的挽回入口，
///    最典型的是日程页「已填充 N 格」+「撤销」—— 把提示关掉等于顺手把撤销
///    入口一起关掉，用户填错一片格子就只能自己一格一格改回来。
///
/// ## 统一 `hideCurrentSnackBar()`
/// 旧代码有的 hide 有的不 hide；不 hide 的那些在"连划几张卡"时会排队堆叠
/// （一条一条往外挤，最后一句话要等前面几条播完才看得到）。这里一律
/// **新的顶掉旧的**：连划几张卡时屏幕上永远只有当前那一条。
///
/// ## 用法（全 App 一致）
/// ```dart
/// AppSnack.show(context, '已保存');                       // 提示 / 成功（受开关控制）
/// AppSnack.show(context, '保存失败：$e', kind: SnackKind.error);  // 错误（不受控制）
/// AppSnack.show(context, '已填充 6 格', action: SnackBarAction(label: '撤销', ...));
/// ```
/// 少数页面要在提示里放图形（首页导入成功的小勾）→ 传 [content] 覆盖正文
/// 组件（[message] 仍然必填，它同时是语义上的"这条提示说的是什么"）。
library;

import 'package:flutter/material.dart';

import '../services/ui_prefs_store.dart';

/// 提示条语义。**只有 [info] 会被设置里的开关挡掉**（见 [AppSnack.allows]）。
enum SnackKind {
  /// 提示 / 成功 / 门禁（「已保存」「已跳过」「请先配置 GitHub token」…）
  /// —— 这些只是**告知**，用户嫌吵可以关掉。
  info,

  /// 错误 / 失败（「保存失败：…」「网络请求失败」「未同步到 Gist（本地已生效）：…」）
  /// —— **永不关闭**：关掉等于让失败静默。
  error,
}

/// 底部提示条的统一出口。
class AppSnack {
  AppSnack._();

  /// 这条提示**当下是否允许显示**。
  ///
  /// 判定只有一处（别在别处再写一份）：错误类 → 永远允许；带 [action]
  /// （撤销等挽回入口）→ 永远允许；其余（info）→ 看设置里的「界面提示」开关。
  static bool allows(SnackKind kind, {SnackBarAction? action}) {
    if (kind == SnackKind.error) return true;
    if (action != null) return true;
    return UiPrefsStore.instance.showTips;
  }

  /// 弹一条底部提示。[message] 是正文（[content] 非空时由它覆盖显示）。
  ///
  /// 设置里关掉「界面提示」时 [SnackKind.info] **直接不弹**（连
  /// `ScaffoldMessenger` 都不碰）；错误类与带 [action] 的照常弹。
  static void show(
    BuildContext context,
    String message, {
    SnackKind kind = SnackKind.info,
    SnackBarAction? action,
    Widget? content,
    Duration? duration,
  }) {
    if (!allows(kind, action: action)) return;
    // maybeOf 而不是 of：页面正在被销毁（弹层关闭 / 路由 pop 的那一帧）
    // 时没有 ScaffoldMessenger 祖先，`of` 会直接抛断言 —— 提示条不该成为
    // 崩溃源。
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: content ?? Text(message),
          action: action,
          duration: duration ?? const Duration(seconds: 4),
        ),
      );
  }
}
