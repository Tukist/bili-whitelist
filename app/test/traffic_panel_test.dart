// 个人页「流量计量」块（v2.53.0）测试。
//
// 用户诉求：「可不可以在个人界面加一个剩余免费流量计量」「需要同时有读自己的移动
// 数据用量和运营商通用流量用量，相减得结果」。运营商侧的免流额度读不到（没有任何
// 公开接口），所以这块给的是**替代方案**：
//   - 系统口径：本 App / 本机的**移动数据**用量（原生 NetworkStatsManager，
//     需「使用情况访问」；没开时一句话 + 一个「去开启」按钮，绝不静默失败）；
//   - 运营商口径：用户手抄一个数 → 记快照 → 两条快照相减 → **疑似**免流量；
//   - 全程带口径说明与不确定性（"仅供参考，以运营商账单为准"）。
//
// 覆盖：权限引导 / 系统读数 / 输入容错 / 快照与差值 / 从设置页回来自动刷新 /
// 小字长度契约。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/traffic_snapshot_store.dart';
import 'package:bili_whitelist_app/services/traffic_stats_service.dart';
import 'package:bili_whitelist_app/widgets/traffic_panel.dart';

/// 原生流量通道替身（只实现本块用到的那四个方法）。
class _FakeTraffic {
  bool granted = true;
  int appBytes = 104857600; // 100 MB
  int? deviceBytes = 1073741824; // 1 GB
  int sinceBoot = 5242880; // 5 MB
  bool failQuery = false;
  int settingsOpened = 0;
  final List<Map<Object?, Object?>> queries = [];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      TrafficStatsService.channel,
      (call) async {
        switch (call.method) {
          case 'hasUsageAccess':
            return granted;
          case 'openUsageAccessSettings':
            settingsOpened++;
            return true;
          case 'queryMobile':
            queries.add((call.arguments as Map).cast<Object?, Object?>());
            if (failQuery) {
              throw PlatformException(
                  code: 'STATS_FAILED',
                  message: '读不到流量统计（SecurityException）');
            }
            return <Object?, Object?>{
              'appBytes': appBytes,
              'deviceBytes': deviceBytes,
            };
          case 'mobileSinceBoot':
            return sinceBoot;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(TrafficStatsService.channel, null));
  }
}

/// 挂上「流量计量」块（只给它一块足够宽的画布 + 可滚动，省得断言被溢出打断）。
Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: const TrafficPanel(),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 走到"有两条快照"的状态：[appBytes] 与运营商数值都在这一步发生变化。
Future<void> _recordTwice(WidgetTester tester, _FakeTraffic fake) async {
  // 第一条：运营商 10.00GB，此刻本 App 100MB（_FakeTraffic 初值）
  await tester.enterText(find.byKey(kTrafficCarrierInputKey), '10.00');
  await tester.tap(find.byKey(kTrafficRecordKey));
  await tester.pumpAndSettle();

  // 第二条：本 App 涨到 500MB（先刷新让读数变新），运营商 10.35GB
  fake.appBytes = 524288000;
  await tester.tap(find.byKey(kTrafficRefreshKey));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(kTrafficCarrierInputKey), '10.35GB');
  await tester.tap(find.byKey(kTrafficRecordKey));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TrafficSnapshotStore.instance.resetForTest(loaded: true);
  });

  tearDown(() => TrafficSnapshotStore.instance.resetForTest());

  group('① 系统口径：权限未开时给一句话 + 一个按钮（不静默失败）', () {
    testWidgets('未开权限 → 说明 + 「去开启」+ 自开机兜底对照；本机本月读数"读不到"',
        (tester) async {
      final fake = _FakeTraffic()
        ..granted = false
        ..deviceBytes = null; // 没权限时 device 口径读不到
      fake.install(tester);
      await _pump(tester);

      expect(find.text(kTrafficPermissionLine), findsOneWidget);
      expect(find.byKey(kTrafficGrantKey), findsOneWidget);
      // 本 App 那一项按官方文档在 API 24+ 免权限也能读 → 照常显示数字
      expect(find.text('100.0 MB'), findsOneWidget);
      expect(find.text('读不到'), findsOneWidget, reason: '本机本月总量读不到要如实说');
      expect(find.textContaining('自开机'), findsOneWidget,
          reason: '没权限时至少给一个免权限的对照数（如实标注口径）');
      expect(find.text('5.0 MB'), findsOneWidget);
    });

    testWidgets('点「去开启」→ 拉起系统设置页（真实入口，不是自己画一个开关）',
        (tester) async {
      final fake = _FakeTraffic()..granted = false;
      fake.install(tester);
      await _pump(tester);

      await tester.tap(find.byKey(kTrafficGrantKey));
      await tester.pumpAndSettle();
      expect(fake.settingsOpened, 1);
    });

    testWidgets('已开权限 → 不显示引导，两个口径都出数字', (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);

      expect(find.byKey(kTrafficGrantKey), findsNothing);
      expect(find.text(kTrafficPermissionLine), findsNothing);
      expect(find.text('100.0 MB'), findsOneWidget);
      expect(find.text('1.00 GB'), findsOneWidget);
      expect(find.textContaining('自开机'), findsNothing);
    });

    testWidgets('原生读失败 → 显示一句中文（不是空白、不是刷屏异常）', (tester) async {
      final fake = _FakeTraffic()..failQuery = true;
      fake.install(tester);
      await _pump(tester);

      expect(find.textContaining('读不到流量统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('刷新按钮会用新的时间区间再查一次（本月口径）', (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);
      expect(fake.queries.length, 1);
      final from = fake.queries.first['fromMs'] as int;
      expect(
        DateTime.fromMillisecondsSinceEpoch(from),
        DateTime(DateTime.now().year, DateTime.now().month),
        reason: '本月 = 本地月初 00:00 → 现在',
      );

      await tester.tap(find.byKey(kTrafficRefreshKey));
      await tester.pumpAndSettle();
      expect(fake.queries.length, 2);
    });

    testWidgets('从系统设置页回来（resumed）→ 自动重读，权限状态跟着变', (tester) async {
      final fake = _FakeTraffic()..granted = false;
      fake.install(tester);
      await _pump(tester);
      expect(find.byKey(kTrafficGrantKey), findsOneWidget);

      // 用户去设置里开了权限再切回来：不重读的话他会看到"还是没权限"（白跑一趟）。
      // 生命周期必须按合法路径走（resumed→inactive→hidden→paused→hidden→
      // inactive→resumed）：框架会校验非法跳变，直接 paused→resumed 会断言失败。
      for (final s in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      fake.granted = true;
      for (final s in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();

      expect(find.byKey(kTrafficGrantKey), findsNothing,
          reason: '回到前台自动重读一次权限');
    });
  });

  group('② 运营商口径：输入容错 + 快照', () {
    testWidgets('空输入 / 非法输入 → 就地友好提示，且不记快照', (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);

      await tester.tap(find.byKey(kTrafficRecordKey));
      await tester.pumpAndSettle();
      expect(find.text(kTrafficInputEmpty), findsOneWidget);
      expect(TrafficSnapshotStore.instance.snapshots, isEmpty);

      await tester.enterText(find.byKey(kTrafficCarrierInputKey), 'abc');
      await tester.tap(find.byKey(kTrafficRecordKey));
      await tester.pumpAndSettle();
      expect(find.text(kTrafficInputInvalid), findsOneWidget);
      expect(TrafficSnapshotStore.instance.snapshots, isEmpty,
          reason: '看不懂的输入不许变成垃圾快照');
    });

    testWidgets('记一条快照 → 卡片出现、输入清空、落盘、按钮/文案跟着变',
        (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);
      expect(find.byKey(kTrafficOlderSnapshotKey), findsNothing);

      await tester.enterText(find.byKey(kTrafficCarrierInputKey), '12.34GB');
      await tester.tap(find.byKey(kTrafficRecordKey));
      await tester.pumpAndSettle();

      expect(find.text('通用 12.34 GB'), findsOneWidget,
          reason: '带单位也能认，显示统一成 12.34 GB');
      expect(find.text('快照 1（最近）'), findsOneWidget);
      // 快照里带上当时的系统读数（做差值要用）
      expect(find.text('本 App 100.0 MB'), findsOneWidget);
      expect(find.widgetWithText(TextField, '12.34GB'), findsNothing,
          reason: '记成功后输入框清空');
      expect(find.text('再记一次就能对比增量。'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TrafficSnapshotStore.snapshotsKey), isNotNull);
    });

    testWidgets('两条快照并排显示（较早 / 最近），可「删掉最新一条」撤销',
        (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);
      await _recordTwice(tester, fake);

      expect(find.byKey(kTrafficOlderSnapshotKey), findsOneWidget);
      expect(find.byKey(kTrafficLatestSnapshotKey), findsOneWidget);
      expect(find.text('快照 1（较早）'), findsOneWidget);
      expect(find.text('快照 2（最近）'), findsOneWidget);
      expect(find.text('通用 10.00 GB'), findsOneWidget);
      expect(find.text('通用 10.35 GB'), findsOneWidget);

      await tester.tap(find.text('删掉最新一条'));
      await tester.pumpAndSettle();
      expect(find.text('快照 2（最近）'), findsNothing);
      expect(TrafficSnapshotStore.instance.snapshots.length, 1);
    });
  });

  group('③ 一键算差值（增量 + 疑似免流 + 口径说明）', () {
    testWidgets('点「算差值」→ 三个数字 + 不确定性说明都在', (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);
      await _recordTwice(tester, fake);

      expect(find.byKey(kTrafficDiffButtonKey), findsOneWidget);
      expect(find.byKey(kTrafficDiffKey), findsNothing, reason: '没点之前不占位');

      await tester.tap(find.byKey(kTrafficDiffButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kTrafficDiffKey), findsOneWidget);
      expect(find.text('+0.35 GB'), findsOneWidget, reason: '运营商通用增量');
      expect(find.text('400.0 MB'), findsOneWidget, reason: '本 App 移动增量');
      expect(find.text('≈ 0.04 GB'), findsOneWidget,
          reason: '疑似免流 = 0.390625GB − 0.35GB（**带 ≈，不写死结论**）');
      expect(find.text(kTrafficDiffCaveat), findsOneWidget);
      expect(find.text(kTrafficCaveat), findsOneWidget);
      expect(find.textContaining('以运营商账单为准'), findsWidgets);
    });

    testWidgets('只有一条快照 → 没有「算差值」（不该让用户对着半个功能点）',
        (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);
      await tester.enterText(find.byKey(kTrafficCarrierInputKey), '1');
      await tester.tap(find.byKey(kTrafficRecordKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kTrafficDiffButtonKey), findsNothing);
    });

    testWidgets('快照变了要把上次算的差值作废（不许把旧结果留在屏幕上骗人）',
        (tester) async {
      final fake = _FakeTraffic();
      fake.install(tester);
      await _pump(tester);
      await _recordTwice(tester, fake);
      await tester.tap(find.byKey(kTrafficDiffButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kTrafficDiffKey), findsOneWidget);

      await tester.enterText(find.byKey(kTrafficCarrierInputKey), '11.00');
      await tester.tap(find.byKey(kTrafficRecordKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kTrafficDiffKey), findsNothing);
    });
  });

  group('④ 小字长度契约（用户要求设置里的小字不超过两行）', () {
    test('全部导出小字：非空白字符 ≤ 42', () {
      final texts = {
        'kTrafficHint': kTrafficHint,
        'kTrafficPermissionLine': kTrafficPermissionLine,
        'kTrafficSnapshotHint': kTrafficSnapshotHint,
        'kTrafficCaveat': kTrafficCaveat,
        'kTrafficDiffCaveat': kTrafficDiffCaveat,
        'kTrafficInputEmpty': kTrafficInputEmpty,
        'kTrafficInputInvalid': kTrafficInputInvalid,
        'kTrafficSystemGroup': kTrafficSystemGroup,
        'kTrafficCarrierGroup': kTrafficCarrierGroup,
        'kTrafficCarrierSource': kTrafficCarrierSource,
      };
      texts.forEach((name, text) {
        final n = text.replaceAll(RegExp(r'\s'), '').length;
        expect(n, lessThanOrEqualTo(42), reason: '$name 有 $n 个非空白字符');
      });
    });

    test('口径与不确定性必须落在文案里（不许写成"你免了 X GB"）', () {
      expect(kTrafficHint, contains('读不到'), reason: '先把"额度读不到"说清楚');
      expect(kTrafficCaveat, contains('仅供参考'));
      expect(kTrafficCaveat, contains('运营商账单'));
    });

    test('显示格式化：GB 两位小数 / 带符号 / 时长', () {
      expect(fmtGb(12.3), '12.30 GB');
      expect(fmtSignedGb(0.35), '+0.35 GB');
      expect(fmtSignedGb(-0.05), '-0.05 GB');
      expect(fmtSnapshotTime(DateTime(2026, 1, 2, 3, 4)), '01-02 03:04');
      expect(fmtSpan(const Duration(seconds: 45)), '45 秒');
      expect(fmtSpan(const Duration(minutes: 12)), '12 分');
      expect(fmtSpan(const Duration(minutes: 63)), '1 小时 3 分');
      expect(fmtSpan(const Duration(hours: 2)), '2 小时');
    });
  });
}
