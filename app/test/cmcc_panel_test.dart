// 个人页「流量计量」里的「中国移动掌厅（实验）」分组单测（v2.54.0）。
//
// 覆盖：登录态/尾号/上次更新时间/来源（接口 or 页面文字）/定向读数的如实显示、
// **手动录入兜底仍在**、自动来源能进既有差值算法、快照来源标记、失败原因的显示、
// 以及小字长度契约（≤ 42 个非空白字符）。
//
// 注意：系统口径那部分（权限/原生读数）的测试在 v2.53.0 的
// `test/traffic_panel_test.dart` 里，这里不动它，只加新分组的覆盖。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/cmcc_page.dart';
import 'package:bili_whitelist_app/services/cmcc_plan.dart';
import 'package:bili_whitelist_app/services/cmcc_session_store.dart';
import 'package:bili_whitelist_app/services/traffic_snapshot_store.dart';
import 'package:bili_whitelist_app/services/traffic_stats_service.dart';
import 'package:bili_whitelist_app/widgets/traffic_panel.dart';

Map<String, String> _secure = {};

void _mockPlatform() {
  SharedPreferences.setMockInitialValues({});
  _secure = {};
  const storage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storage, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return _secure[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        _secure[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        _secure.remove(args['key'] as String?);
        return true;
      default:
        return null;
    }
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(TrafficStatsService.channel, (call) async {
    switch (call.method) {
      case 'hasUsageAccess':
        return true;
      case 'queryMobile':
        return <Object?, Object?>{
          'appBytes': 104857600,
          'deviceBytes': 1073741824,
        };
      case 'mobileSinceBoot':
        return 5242880;
    }
    return null;
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storage, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(TrafficStatsService.channel, null);
  });
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: TrafficPanel(),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

CmccAutoReading _reading({
  double general = 6.05,
  double? directional = 3.22,
  CmccReadingSource source = CmccReadingSource.api,
  DateTime? at,
}) =>
    CmccAutoReading(
      generalUsedGb: general,
      directionalUsedGb: directional,
      totalUsedGb: 9.27,
      source: source,
      at: at ?? DateTime(2026, 10, 14, 11, 30),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockPlatform();
    CmccSessionStore.instance.resetForTest(loaded: true);
    TrafficSnapshotStore.instance.resetForTest(loaded: true);
  });

  group('① 登录态与"上次自动更新"的如实显示', () {
    testWidgets('还没登录/还没读到过：说清现状，不显示 0 冒充', (tester) async {
      await _pump(tester);
      expect(find.byKey(kTrafficCmccGroupKey), findsOneWidget);
      expect(find.text(kCmccGroup), findsOneWidget);
      expect(find.text(kCmccIntro), findsOneWidget);
      expect(find.text(kCmccPhoneUnknown), findsOneWidget);
      expect(find.text(kCmccStateLoggedOut), findsOneWidget);
      expect(find.text(kCmccNeverRead), findsOneWidget);
      expect(find.byKey(kTrafficCmccOpenKey), findsOneWidget);
      expect(find.text('通用流量已用'), findsNothing,
          reason: '没读到过就别摆一行数字出来（手动录入那组的标签带（GB），不算）');
      // 手动兜底那一组必须一直在
      expect(find.byKey(kTrafficCarrierInputKey), findsOneWidget);
      expect(find.text(kCmccManualStillHere), findsOneWidget);
    });

    testWidgets('已登录 + 自动读数：尾号、时间、来源（接口）都对得上',
        (tester) async {
      CmccSessionStore.instance.resetForTest(
        loaded: true,
        loginState: CmccLoginState.loggedIn,
        phoneTail: '****8000',
        reading: _reading(),
      );
      await _pump(tester);
      expect(find.text(kCmccStateLoggedIn), findsOneWidget);
      expect(find.text('****8000'), findsOneWidget);
      expect(find.textContaining('10-14 11:30'), findsOneWidget);
      expect(find.textContaining('（接口）'), findsOneWidget);
      expect(find.text('6.05 GB'), findsOneWidget);
      expect(find.text('3.22 GB'), findsOneWidget);
      expect(find.text(kCmccNoDirectional), findsNothing);
      expect(find.text(kCmccNeverRead), findsNothing);
      expect(find.textContaining('每 30 分钟读一次'), findsOneWidget,
          reason: '轮询节奏要如实告诉用户');
      expect(find.byKey(kTrafficCmccForgetKey), findsOneWidget);
    });

    testWidgets('读数来自页面文字（B 路线）时，来源要标成"页面文字"',
        (tester) async {
      CmccSessionStore.instance.resetForTest(
        loaded: true,
        loginState: CmccLoginState.loggedIn,
        phoneTail: '****8000',
        reading: _reading(source: CmccReadingSource.pageText),
      );
      await _pump(tester);
      expect(find.textContaining('（页面文字）'), findsOneWidget);
      expect(find.textContaining('（接口）'), findsNothing);
    });

    testWidgets('掌厅没给定向流量 → 显示"没给读数"与 —，**不显示 0**',
        (tester) async {
      CmccSessionStore.instance.resetForTest(
        loaded: true,
        loginState: CmccLoginState.loggedIn,
        phoneTail: '****8000',
        reading: _reading(directional: null),
      );
      await _pump(tester);
      expect(find.text(kCmccNoDirectional), findsOneWidget);
      expect(find.text('—'), findsOneWidget, reason: '读不到的项显示破折号');
      expect(find.text('0.00 GB'), findsNothing,
          reason: '0 是"没用量"，与"没读到"是两件事');
    });

    testWidgets('需要重新登录 → 显示状态与停止轮询的原因 + 失败原因',
        (tester) async {
      CmccSessionStore.instance.resetForTest(
        loaded: true,
        loginState: CmccLoginState.needRelogin,
        needsRelogin: true,
        phoneTail: '****8000',
        lastError: kCmccStateNeedRelogin,
        failures: 2,
      );
      await _pump(tester);
      expect(find.text(kCmccStateNeedRelogin), findsWidgets);
      expect(find.textContaining('自动轮询已停止'), findsOneWidget);
      expect(find.textContaining('自己收短信'), findsOneWidget);
    });

    testWidgets('读不到时把原因写出来（可读，不静默）', (tester) async {
      CmccSessionStore.instance.resetForTest(
        loaded: true,
        loginState: CmccLoginState.loggedIn,
        lastError: kCmccFailBoth,
        failures: 1,
      );
      await _pump(tester);
      expect(find.text(kCmccFailBoth), findsOneWidget);
      expect(find.textContaining('5 分钟后重试'), findsOneWidget);
    });
  });

  group('② 来源标记与差值算法打通（自动 + 手填一起算）', () {
    testWidgets('快照上标出"自动读到（掌厅）"/"手填的"', (tester) async {
      TrafficSnapshotStore.instance.resetForTest(loaded: true, snapshots: [
        CarrierSnapshot(
          at: DateTime(2026, 10, 14, 10),
          carrierGb: 10.00,
          appMobileBytes: 104857600,
        ),
        CarrierSnapshot(
          at: DateTime(2026, 10, 14, 10, 10),
          carrierGb: 10.35,
          appMobileBytes: 104857600 + 419430400,
          source: SnapshotSource.cmcc,
        ),
      ]);
      await _pump(tester);
      expect(find.text(kCmccSourceManualBadge), findsOneWidget);
      expect(find.text(kCmccSourceAutoBadge), findsOneWidget);
    });

    testWidgets('手填 + 自动 → 「算差值」照常给出疑似免流', (tester) async {
      TrafficSnapshotStore.instance.resetForTest(loaded: true, snapshots: [
        CarrierSnapshot(
          at: DateTime(2026, 10, 14, 10),
          carrierGb: 10.00,
          appMobileBytes: 104857600, // 100 MB
        ),
        CarrierSnapshot(
          at: DateTime(2026, 10, 14, 10, 10),
          carrierGb: 10.35,
          appMobileBytes: 104857600 + 419430400, // +400 MB
          source: SnapshotSource.cmcc,
        ),
      ]);
      await _pump(tester);
      await tester.tap(find.byKey(kTrafficDiffButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kTrafficDiffKey), findsOneWidget);
      expect(find.text('+0.35 GB'), findsOneWidget);
      expect(find.text('400.0 MB'), findsOneWidget);
      expect(find.text('≈ 0.04 GB'), findsOneWidget,
          reason: '自动来源的数字确实进了差值算法');
    });

    testWidgets('自动那条读不到系统口径 → 差值如实"算不出"（不拿 0 冒充）',
        (tester) async {
      TrafficSnapshotStore.instance.resetForTest(loaded: true, snapshots: [
        CarrierSnapshot(
          at: DateTime(2026, 10, 14, 10),
          carrierGb: 10.00,
          appMobileBytes: 104857600,
        ),
        CarrierSnapshot(
          at: DateTime(2026, 10, 14, 11),
          carrierGb: 10.35,
          appMobileBytes: -1, // 掌厅读到了但系统口径读不到
          source: SnapshotSource.cmcc,
        ),
      ]);
      await _pump(tester);
      await tester.tap(find.byKey(kTrafficDiffButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('本 App 读数不可用'), findsOneWidget);
      expect(find.text('算不出'), findsOneWidget);
    });

    testWidgets('手动录入兜底照旧：填数 → 记快照 → 标成"手填的"', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byKey(kTrafficCarrierInputKey), '12.34');
      await tester.tap(find.byKey(kTrafficRecordKey));
      await tester.pumpAndSettle();
      final snaps = TrafficSnapshotStore.instance.snapshots;
      expect(snaps.length, 1);
      expect(snaps.single.source, SnapshotSource.manual,
          reason: '手动录入仍然可用，且来源标成手填');
      expect(find.text(kCmccSourceManualBadge), findsOneWidget);
      expect(find.text('通用 12.34 GB'), findsOneWidget);
    });
  });

  group('③ 出口与隐私', () {
    testWidgets('「打开掌厅页面」→ 进抓取页（路线 D 的逃生口）', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(kTrafficCmccOpenKey));
      await tester.pumpAndSettle();
      expect(find.byType(CmccCapturePage), findsOneWidget,
          reason: '抓取页必须能打开：读不到时用户至少能自己看页面');
    });

    testWidgets('「清除本机手机号」→ 尾号没了、**不退出**掌厅登录', (tester) async {
      CmccSessionStore.instance.resetForTest(
        loaded: true,
        loginState: CmccLoginState.loggedIn,
        phoneTail: '****8000',
        reading: _reading(),
      );
      _secure[CmccSessionStore.phoneStorageKey] = '13800138000';
      await _pump(tester);
      await tester.tap(find.byKey(kTrafficCmccForgetKey));
      await tester.pumpAndSettle();
      expect(CmccSessionStore.instance.phoneTail, isNull);
      expect(find.text(kCmccPhoneUnknown), findsOneWidget);
      expect(_secure.containsKey(CmccSessionStore.phoneStorageKey), isFalse);
      expect(find.text(kCmccForgetPhoneSnack), findsOneWidget,
          reason: '要说清"只清了本机记录，掌厅登录没动"');
      expect(CmccSessionStore.instance.reading, isNotNull,
          reason: '上次读数不该被顺手清掉（那是流量计量的输入）');
    });
  });

  group('④ 小字长度契约（≤ 42 个非空白字符）', () {
    test('掌厅分组新增的每一句都不过两行', () {
      final texts = <String, String>{
        'kCmccOpenButton': kCmccOpenButton,
        'kCmccOpenHint': kCmccOpenHint,
        'kCmccPhoneLabel': kCmccPhoneLabel,
        'kCmccPhoneUnknown': kCmccPhoneUnknown,
        'kCmccLastUpdateLabel': kCmccLastUpdateLabel,
        'kCmccNeverRead': kCmccNeverRead,
        'kCmccAutoSnapshotHint': kCmccAutoSnapshotHint,
        'kCmccManualStillHere': kCmccManualStillHere,
        'kCmccForgetPhoneButton': kCmccForgetPhoneButton,
        'kCmccForgetPhoneSnack': kCmccForgetPhoneSnack,
        'kCmccSourceAutoBadge': kCmccSourceAutoBadge,
        'kCmccSourceManualBadge': kCmccSourceManualBadge,
      };
      texts.forEach((name, text) {
        final n = text.replaceAll(RegExp(r'\s'), '').length;
        expect(n, lessThanOrEqualTo(42), reason: '$name 有 $n 个非空白字符');
      });
    });

    test('登录态那三个词也要短', () {
      for (final s in CmccLoginState.values) {
        final label = cmccLoginStateLabel(s);
        expect(label.replaceAll(RegExp(r'\s'), '').length,
            lessThanOrEqualTo(42));
      }
      expect(cmccLoginStateLabel(CmccLoginState.unknown), kCmccStateLoggedOut);
      expect(cmccLoginStateLabel(CmccLoginState.needRelogin),
          kCmccStateNeedRelogin);
    });
  });
}
