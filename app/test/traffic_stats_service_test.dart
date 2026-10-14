// 流量计量的**原生通道**封装（v2.53.0）测试。
//
// 这里钉住的是"读不到时怎么办"这一半 —— 用户明确要求：权限没开时给"一句话 +
// 一个按钮"，**不许静默失败、不许刷屏报错**。所以本文件里所有失败路径都必须
// 是"一句能直接显示的中文"或 null，**永远不抛异常到界面**。
//
// 覆盖：
//   1. monthRange：本月口径（本地月初 00:00 → 现在），纯函数逐值钉住；
//   2. hasUsageAccess / openUsageAccessSettings：成功、返回 null、无通道、
//      抛异常四条路都给出确定的布尔（不抛）；
//   3. queryMobile：成功（含 device 读不到 = null 的形态）、参数形状、
//      原生 error → 中文、无通道 → 中文、负数当"读不到"；
//   4. mobileSinceBoot：正常值 / 系统不支持（负数）/ 无通道。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/traffic_stats_service.dart';

/// 装一个通道桩；[handler] 返回 null 表示"这个方法没有实现"。
void _mockChannel(WidgetTester tester,
    Future<Object?> Function(MethodCall call) handler) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      TrafficStatsService.channel, handler);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(TrafficStatsService.channel, null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = TrafficStatsService();

  group('① 本月口径（纯函数）', () {
    test('本地月初 00:00 → 现在', () {
      final r = TrafficStatsService.monthRange(DateTime(2026, 10, 14, 18, 30));
      expect(r.from, DateTime(2026, 10, 1));
      expect(r.to, DateTime(2026, 10, 14, 18, 30));
    });

    test('边界：1 月 1 日 00:00 / 12 月 31 日 23:59', () {
      final a = TrafficStatsService.monthRange(DateTime(2026, 1, 1));
      expect(a.from, DateTime(2026, 1, 1));
      final b = TrafficStatsService.monthRange(DateTime(2026, 12, 31, 23, 59));
      expect(b.from, DateTime(2026, 12, 1));
      expect(b.to, DateTime(2026, 12, 31, 23, 59));
    });
  });

  group('② 权限查询与引导（失败都要给确定值，不抛）', () {
    testWidgets('hasUsageAccess：原生 true / null / 抛异常 → true / false / false',
        (tester) async {
      _mockChannel(tester, (call) async => call.method == 'hasUsageAccess');
      expect(await service.hasUsageAccess(), isTrue);

      _mockChannel(tester, (call) async => null);
      expect(await service.hasUsageAccess(), isFalse, reason: '返回 null = 没开');

      _mockChannel(tester, (call) async => throw PlatformException(
          code: 'X', message: '看「使用情况访问」状态失败'));
      expect(await service.hasUsageAccess(), isFalse);
    });

    testWidgets('hasUsageAccess：通道不存在（非 Android / 未注册）→ false',
        (tester) async {
      // 注意：**必须显式装一个抛 MissingPluginException 的桩**。flutter_test 下
      // 对"没有任何 handler"的通道发消息是**永远不回**的（不是抛异常），
      // 直接调会把这个用例挂死 —— 这里模拟的是真机上插件缺失时抛的那个异常。
      _mockChannel(tester,
          (call) async => throw MissingPluginException('没有注册这条通道'));
      expect(await service.hasUsageAccess(), isFalse);
    });

    testWidgets('openUsageAccessSettings：true / false / 抛异常 → true / false / false',
        (tester) async {
      var opened = 0;
      _mockChannel(tester, (call) async {
        if (call.method == 'openUsageAccessSettings') {
          opened++;
          return true;
        }
        return null;
      });
      expect(await service.openUsageAccessSettings(), isTrue);
      expect(opened, 1);

      _mockChannel(tester, (call) async => false);
      expect(await service.openUsageAccessSettings(), isFalse,
          reason: '拉不起来 → 界面要补一句人话（不静默）');

      _mockChannel(tester, (call) async =>
          throw PlatformException(code: 'NO_ACTIVITY', message: '没有可处理的页面'));
      expect(await service.openUsageAccessSettings(), isFalse);
    });
  });

  group('③ queryMobile：参数形状、成功/部分读不到、失败文案', () {
    testWidgets('成功：fromMs/toMs 传毫秒；device 为 null 时那一项是"读不到"',
        (tester) async {
      Map<Object?, Object?>? got;
      _mockChannel(tester, (call) async {
        got = (call.arguments as Map).cast<Object?, Object?>();
        return <Object?, Object?>{
          'appBytes': 104857600, // 100 MB
          'deviceBytes': null, // 未开权限时 device 口径读不到
        };
      });
      final r = await service.queryMobile(
        from: DateTime(2026, 10, 1),
        to: DateTime(2026, 10, 14, 12),
      );
      expect(r.isOk, isTrue);
      expect(r.error, isNull);
      expect(r.sample!.appBytes, 104857600);
      expect(r.sample!.deviceBytes, isNull);
      expect(r.sample!.isEmpty, isFalse, reason: '有一项读到就不算空');
      expect(got!['fromMs'],
          DateTime(2026, 10, 1).millisecondsSinceEpoch);
      expect(got!['toMs'], DateTime(2026, 10, 14, 12).millisecondsSinceEpoch);
    });

    testWidgets('负数（设备不支持时系统回负数）→ 当作读不到，不显示成负字节',
        (tester) async {
      _mockChannel(tester, (call) async => <Object?, Object?>{
            'appBytes': -1,
            'deviceBytes': -1,
          });
      final r = await service.queryMobile(
          from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 2));
      expect(r.isOk, isTrue);
      expect(r.sample!.appBytes, isNull);
      expect(r.sample!.deviceBytes, isNull);
      expect(r.sample!.isEmpty, isTrue);
    });

    testWidgets('原生 error → 一句中文（含"回到 App 再刷新一次"的操作指引）',
        (tester) async {
      _mockChannel(tester, (call) async => throw PlatformException(
          code: 'STATS_FAILED', message: '读不到流量统计（SecurityException）'));
      final r = await service.queryMobile(
          from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 2));
      expect(r.isOk, isFalse);
      expect(r.sample, isNull);
      expect(r.error, contains('读不到流量统计'));
      expect(r.error, contains('回到 App 再刷新一次'));
    });

    testWidgets('返回结构不对（不是 Map）→ 友好失败，不抛', (tester) async {
      _mockChannel(tester, (call) async => '不是 map');
      final r = await service.queryMobile(
          from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 2));
      expect(r.isOk, isFalse);
      expect(r.error, contains('返回的数据不对'));
    });

    testWidgets('通道不存在 → "当前版本不支持流量统计"', (tester) async {
      _mockChannel(tester,
          (call) async => throw MissingPluginException('没有注册这条通道'));
      final r = await service.queryMobile(
          from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 2));
      expect(r.isOk, isFalse);
      expect(r.error, '当前版本不支持流量统计');
    });
  });

  group('④ mobileSinceBoot（免权限兜底对照）', () {
    testWidgets('正常值照传；负数（UNSUPPORTED）→ null；无通道 → null',
        (tester) async {
      _mockChannel(tester, (call) async => 12345678);
      expect(await service.mobileSinceBoot(), 12345678);

      _mockChannel(tester, (call) async => -1);
      expect(await service.mobileSinceBoot(), isNull,
          reason: '不支持时不许把 -1 当字节数显示');

      _mockChannel(tester, (call) async =>
          throw PlatformException(code: 'X', message: 'y'));
      expect(await service.mobileSinceBoot(), isNull);
    });

    testWidgets('通道不存在 → null（不是 0：0 会被读成"没用流量"）', (tester) async {
      _mockChannel(tester,
          (call) async => throw MissingPluginException('没有注册这条通道'));
      expect(await service.mobileSinceBoot(), isNull);
    });
  });
}
