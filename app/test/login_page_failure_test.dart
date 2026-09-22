// 登录页失败可见化（v2.49.1+）单测。
//
// 背景（2026-09-22 真机诊断）：`WebViewController()` / `loadRequest` 在部分
// 国产 ROM（系统 WebView provider 被精简 / 组件异常）上会抛异常，旧代码没有
// try/catch → 页面永远停在「三颗方点」加载动画上。用户看到的是"点了去登录
// 就没反应"，既不知道坏了、也没法重试——这正是"无法进入登录态"最可能的一种
// 现场表现。现在失败必须换成**整页错误态 + 重试按钮**。
//
// 测试环境里 WebView 平台未注册（`flutter test` 不跑原生注册），
// `WebViewController()` 构造即抛 —— 正好是这条失败路径的真实触发条件。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/login_page.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WebView 初始化失败 → 整页错误态 + 「重试」（不停在加载方点）',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump(); // initState 里发起 _initWebView
    await tester.pump(); // 失败后的 setState

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('登录页加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 加载方点必须已被错误态取代：否则用户分不清"正在加载"与"已经坏了"
    expect(find.byType(AppLoadingView), findsNothing);
  });

  testWidgets('点「重试」→ 重新创建 WebView；仍失败则回到错误态且不崩',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('登录页加载失败'), findsOneWidget);
  });
}
