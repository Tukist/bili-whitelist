// 「个人」页的「稍后再看」入口（v2.58.0+）：
// - 入口存在（key + 文案），挂在观看统计/设置所在的那一页；
// - 点它 → 推出稍后再看页。
//
// 不触网：secure storage 通道 mock 成**空**（= 未登录），稍后再看页会走
// "未登录 → 可读原因"那条路，不需要任何真实凭据或 HTTP。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/watch_later_page.dart';
import 'package:bili_whitelist_app/pages/watch_stats_page.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';

/// 空的 secure storage（读什么都拿不到 → 未登录）。
void _mockEmptySecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'read':
            return null;
          case 'write':
            return true;
          case 'delete':
            return true;
          default:
            return null;
        }
      });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockEmptySecureStorage();
  });

  testWidgets('个人页有「稍后再看」入口', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: WatchStatsPage(stats: WatchStats())),
    ));
    await tester.pumpAndSettle();

    // 页头行内的按钮（不占列表高度，见 watch_stats_page 的注释）
    expect(find.byKey(kWatchLaterEntryKey), findsOneWidget);
    expect(find.text('稍后再看'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byKey(kWatchLaterEntryKey)).onPressed,
      isNotNull,
      reason: '入口必须可点（不是摆设）',
    );
  });

  testWidgets('点入口 → 推出稍后再看页（未登录给可读原因）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: WatchStatsPage(stats: WatchStats())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kWatchLaterEntryKey));
    await tester.pumpAndSettle();

    expect(find.byType(WatchLaterPage), findsOneWidget);
    // 未登录 → 页面给可读原因（不是空白、不是裸 code）
    expect(find.textContaining('未登录'), findsOneWidget);
  });
}
