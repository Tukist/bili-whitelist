// App 启动冒烟测试：验证首页能正常渲染出「白名单点播」标题。
//
// 注意：测试环境没有 path_provider/flutter_secure_storage 等原生插件，
// PlaylistPage 的同步会在异步 try/catch 中被捕获并显示错误条，UI 不崩溃。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/main.dart';

void main() {
  testWidgets('App 启动显示首页标题', (WidgetTester tester) async {
    await tester.pumpWidget(const BiliWhitelistApp());
    // 首帧后允许异步同步任务抛出/被捕获
    await tester.pump();
    await tester.pump();

    expect(find.text('白名单点播'), findsOneWidget);
  });
}
