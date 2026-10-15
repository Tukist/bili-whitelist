// 掌厅抓取页状态机单测（v2.54.0）。
//
// WebView 交互用**注入替身**测（`CmccCapturePage(driverFactory: ...)`），
// 因为 `flutter_test` 环境里没有 WebView 平台实现。替身把持着"通道消息"入口，
// 所以整条链路（钩到响应 → 解密 → 解析 → 落库 + 记自动来源快照 → 排轮询）
// 都能在测试里真实走一遍。
//
// 对照的现场事实（用户/调研给的）：页面打开后约 8 秒才自己发接口；数据要用户
// 点一下「点击刷新」才出；最多试 3 次，第 2/3 次用 reload。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:bili_whitelist_app/pages/cmcc_page.dart';
import 'package:bili_whitelist_app/services/cmcc_capture_driver.dart';
import 'package:bili_whitelist_app/services/cmcc_plan.dart';
import 'package:bili_whitelist_app/services/cmcc_session_store.dart';
import 'package:bili_whitelist_app/services/traffic_snapshot_store.dart';
import 'package:bili_whitelist_app/services/traffic_stats_service.dart';

/// 同一份余量 JSON 的密文（自造向量，见 test/cmcc_plan_test.dart）。
const String _cipherMargin =
    '1567779d8f74e2926e1b2eb3ae12c34f5bfa5477999858bd85f28f1c716da40fa952828348c7ae11550873dd8dc0eaf4ba9b7af8ac7299579f3ce25fd9bf9497ab4255dcec20cf2dd58d4bc4d93bbdf63bb3dc7cca0cc2bf4db070546d3404c2d51061128146fb993dc3bf0daff54ebaabdec0d1a011d8fad19fd01caea78bf22f7aefb11a042b7065eee5b742bd291e9748c07ddd20ee7bde45d6ea516b12208cb3ff1f6b4e2fad5885fe055eaa9c89e304ddb800ac8d9f15d1b7afa46701d4baaeaadeedab5ff0c81fc147eb6ca1d19e162472b74e757acfcd98db5e57e157e339a1f359a9208b6d52e2d966dd2f061f2b1c5aaa5efc70e72ed0a04935a0605e5f8e3636eff0356472852d5fef748dc7d362cab8415875b393b1821adfb939952f924099f809f4b8be61d96bb311dcf0d7771f19f9519cebea74c2135d34f8ccf0bf13a6943a4dc2cf60d7ed14c96b8ee5183d16be0d1be1a896d7580b12ceabdc569011443d2adba13050866db4292b8d869c634bd1528228982e3dbebbb8';

/// 一段"首页 + 有数字"的页面文字（B 路线要能认出来）。
const String _homeTextWithNumbers =
    '话费余额 12.34 元 我的 套餐余量 通用流量 已用 6.05GB 剩余 73.95GB '
    '定向流量 已用 3.22GB 剩余 26.78GB';

/// 一段"首页但没数字"的页面文字（走 D 路线）。
const String _homeTextNoNumbers = '话费余额 12.34 元 我的 套餐余量 退出';

/// 登录页文字。
const String _loginText = '手机号 验证码 获取验证码 登录';

/// secure storage 替身（只实现本页用到的那三个方法）。
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
          'appBytes': 104857600, // 100 MB
          'deviceBytes': 1073741824,
        };
      case 'mobileSinceBoot':
        return 0;
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

/// 抓取驱动替身：记录页面**调过哪些能力**、把通道消息入口留给测试。
class _FakeDriver implements CmccCaptureDriver {
  void Function(String raw) onHook = (_) {};
  CmccPageBindings? bindings;
  final List<String> calls = [];
  final List<String> urls = [];
  String? phone = '13800138000';
  bool failStart = false;

  // 替身没有真 WebView → 页面显示占位说明（也就不会去碰平台通道）
  @override
  WebViewController? get controller => null;

  @override
  void bind(CmccPageBindings bindings) {
    this.bindings = bindings;
    calls.add('bind');
  }

  @override
  Future<void> start(String url) async {
    calls.add('start');
    urls.add(url);
    if (failStart) throw StateError('no webview here');
  }

  @override
  Future<void> reload() async => calls.add('reload');

  @override
  Future<void> requestText() async => calls.add('requestText');

  @override
  Future<void> pokeRefresh() async => calls.add('pokeRefresh');

  @override
  Future<String?> readPhoneField() async {
    calls.add('readPhoneField');
    return phone;
  }

  @override
  Future<bool> hookInstalled() async {
    calls.add('hookInstalled');
    return true;
  }

  @override
  void dispose() => calls.add('dispose');

  int count(String name) => calls.where((c) => c == name).length;
}

/// 挂上抓取页并返回替身。
///
/// 时钟用 `tester.binding.clock`（跟着 fake async 走）：页面里的"上次更新时间"
/// 与"自动快照防抖"依赖真实时间差，用系统时间的话在测试里永远是"刚刚"，
/// 防抖判断就没法验。
Future<_FakeDriver> _pump(WidgetTester tester) async {
  final driver = _FakeDriver();
  await tester.pumpWidget(MaterialApp(
    home: CmccCapturePage(
      now: () => tester.binding.clock.now(),
      driverFactory: (onHook) {
        driver.onHook = onHook;
        return driver;
      },
    ),
  ));
  await tester.pump();
  await tester.pump();
  return driver;
}

/// 把异步链跑完（不推进到 8 秒那个等待窗口）。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
}

/// 推一条通道消息（页面对页面的唯一输入口）。
Future<void> _push(WidgetTester tester, _FakeDriver d, Map<String, Object?> m)
    async {
  d.onHook(jsonEncode(m));
  await _flush(tester);
}

Future<void> _pushText(WidgetTester tester, _FakeDriver d, String text) =>
    _push(tester, d, {'kind': 'text', 'text': text});

Future<void> _pushResponse(
        WidgetTester tester, _FakeDriver d, String api, String body) =>
    _push(tester, d, {'kind': 'response', 'api': api, 'body': body});

/// 走完一次"加载完成 → 首页文字 → 三次 8 秒尝试"（第 2/3 次带 reload）。
Future<void> _runThreeAttempts(
  WidgetTester tester,
  _FakeDriver d,
  String homeText,
) async {
  d.bindings!.onPageFinished();
  await _flush(tester);
  await _pushText(tester, d, homeText); // 第 1 轮
  await tester.pump(kCmccAttemptWait); // 到点 → reload
  d.bindings!.onPageFinished();
  await _flush(tester);
  await _pushText(tester, d, homeText); // 第 2 轮
  await tester.pump(kCmccAttemptWait);
  d.bindings!.onPageFinished();
  await _flush(tester);
  await _pushText(tester, d, homeText); // 第 3 轮
  await tester.pump(kCmccAttemptWait); // 到点 → 降级
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockPlatform();
    CmccSessionStore.instance.resetForTest();
    TrafficSnapshotStore.instance.resetForTest();
  });

  group('① 路线 C：钩到响应 → 解密 → 落库 + 记自动快照', () {
    testWidgets('密文响应：读出 6.05GB、存尾号、记一条 source=cmcc 的快照',
        (tester) async {
      final d = await _pump(tester);
      expect(d.urls, [kCmccLoginUrl], reason: '第一站是登录页（要用户自己登）');
      expect(find.textContaining('没有 WebView'), findsOneWidget,
          reason: '替身没有 controller → 显示占位说明，不建真 WebView');

      d.bindings!.onPageFinished();
      await _flush(tester);
      // 加载完成后：读一次手机号（只读值）+ 点刷新 + 收一次页面文字
      expect(d.count('readPhoneField'), greaterThanOrEqualTo(1));
      expect(d.count('pokeRefresh'), greaterThanOrEqualTo(1));

      await _pushText(tester, d, _homeTextWithNumbers); // 到首页 → 开始抓取
      expect(d.count('pokeRefresh'), greaterThanOrEqualTo(2),
          reason: '开始抓取时要自己点一下「点击刷新」逼页面重发请求');

      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);

      final store = CmccSessionStore.instance;
      expect(store.reading, isNotNull);
      expect(store.reading!.generalUsedGb, closeTo(6.05, 1e-9));
      expect(store.reading!.directionalUsedGb, closeTo(3.22, 1e-9));
      expect(store.reading!.source, CmccReadingSource.api);
      expect(store.phoneTail, '****8000', reason: '内存里只留尾号');
      expect(_secure[CmccSessionStore.phoneStorageKey], '13800138000',
          reason: '全号只进 secure storage');
      expect(store.failures, 0);
      expect(store.needsRelogin, isFalse);

      final snaps = TrafficSnapshotStore.instance.snapshots;
      expect(snaps.length, 1);
      expect(snaps.single.source, SnapshotSource.cmcc);
      expect(snaps.single.carrierGb, closeTo(6.05, 1e-9));
      expect(snaps.single.appMobileBytes, 104857600,
          reason: '顺手带上此刻的系统读数，差值才用得上');

      expect(find.textContaining('读到了'), findsOneWidget);
      expect(find.textContaining('通用流量已用 6.05 GB'), findsOneWidget);
      expect(find.text(kCmccNoDirectional), findsNothing,
          reason: '这次掌厅给了定向读数，不该说"没给"');
    });

    testWidgets('明文响应（页面某分支直出 JSON）也一样能用', (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getMainPlan',
          '{"data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"1.5","remainNum":"8.5","sumNum":"10","unit":"04"}}}}}');
      expect(CmccSessionStore.instance.reading!.generalUsedGb,
          closeTo(1.5, 1e-9));
      expect(TrafficSnapshotStore.instance.latest!.source, SnapshotSource.cmcc);
    });

    testWidgets('掌厅没给定向流量 → 如实显示"掌厅没给定向流量读数"，不显示 0',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getNewMarginInfo',
          '{"data":{"resultData":{"planRemianFlowInfo":{"planRemian":'
          '{"usedNum":"6.05","remainNum":"73.95","sumNum":"80","unit":"04"},'
          '"directionalFlowInfo":{"usedNum":"0","remainNum":"0","sumNum":"0","unit":"04"}}}}}');
      final reading = CmccSessionStore.instance.reading!;
      expect(reading.directionalUsedGb, isNull);
      expect(reading.hasDirectional, isFalse);
      expect(find.text(kCmccNoDirectional), findsOneWidget);
    });

    testWidgets('解不开的密文 → 不当数据用，会继续重试，最后降级到 B', (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers); // 第 1 轮
      await _pushResponse(tester, d, 'getNewMarginInfo', '0' * 32);
      // 解不开 → 页面先把可读原因摆出来（还没判失败）
      expect(find.text(kCmccFailDecrypt), findsOneWidget);
      expect(CmccSessionStore.instance.reading, isNull,
          reason: '解不开就当没读到，绝不用半个结果');

      // 第 1 轮到点：钩到过坏响应也必须继续重试（否则整条链卡死在这儿）
      await tester.pump(kCmccAttemptWait);
      expect(d.count('reload'), 1);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers); // 第 2 轮
      await tester.pump(kCmccAttemptWait);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers); // 第 3 轮
      await tester.pump(kCmccAttemptWait);

      final store = CmccSessionStore.instance;
      expect(store.reading!.source, CmccReadingSource.pageText,
          reason: 'C 解不开 → B 从页面文字里认出来');
      expect(store.reading!.generalUsedGb, closeTo(6.05, 1e-9));
    });
  });

  group('② 降级链：C 三次不成就 B，B 不成才 D（每条原因不同）', () {
    testWidgets('C 全程钩不到 → B（页面文字），且 reload 正好 2 次',
        (tester) async {
      final d = await _pump(tester);
      await _runThreeAttempts(tester, d, _homeTextWithNumbers);
      expect(d.count('reload'), 2, reason: '第 2/3 次尝试用 reload');
      final store = CmccSessionStore.instance;
      expect(store.reading!.source, CmccReadingSource.pageText);
      expect(store.reading!.generalUsedGb, closeTo(6.05, 1e-9));
      expect(store.reading!.directionalUsedGb, closeTo(3.22, 1e-9));
      expect(find.textContaining('从页面文字里认出来的'), findsOneWidget);
      expect(TrafficSnapshotStore.instance.latest!.source, SnapshotSource.cmcc);
    });

    testWidgets('C 与 B 都不成 → D：不解析、页面留给用户、原因可读、不记垃圾快照',
        (tester) async {
      final d = await _pump(tester);
      await _runThreeAttempts(tester, d, _homeTextNoNumbers);
      final store = CmccSessionStore.instance;
      expect(store.reading, isNull);
      expect(store.lastError, kCmccFailBoth);
      expect(store.failures, 1, reason: '失败要计数（退避用）');
      expect(TrafficSnapshotStore.instance.snapshots, isEmpty,
          reason: '读不到就什么都不记，绝不用 0 冒充');
      expect(find.text('读不到数字'), findsOneWidget);
      expect(find.text(kCmccFailBoth), findsOneWidget);
      expect(find.text(kCmccFallbackHint), findsOneWidget, reason: 'D 的出口');
      expect(find.byKey(kCmccPageRetryKey), findsOneWidget);
    });

    testWidgets('点「重新读一次」→ 重来一轮（不清失败计数，成功才清）',
        (tester) async {
      final d = await _pump(tester);
      await _runThreeAttempts(tester, d, _homeTextNoNumbers);
      expect(CmccSessionStore.instance.failures, 1);
      final before = d.count('pokeRefresh');
      await tester.tap(find.byKey(kCmccPageRetryKey));
      await _flush(tester);
      expect(d.count('pokeRefresh'), greaterThan(before));
      expect(CmccSessionStore.instance.failures, 1,
          reason: '失败计数要留到读成功为止（退避靠它）');
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      expect(CmccSessionStore.instance.failures, 0, reason: '成功了清零');
      expect(CmccSessionStore.instance.reading, isNotNull);
    });
  });

  group('③ 登录页 / 维护页 / 会话失效', () {
    testWidgets('停在登录页：提示自己登录、给"我已登录"出口、且不自动查数据',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _loginText);

      expect(find.textContaining('等你在这个页面里登录'), findsOneWidget);
      expect(find.text(kCmccLoginHint), findsOneWidget);
      expect(find.textContaining('App 不代填、不代发'), findsOneWidget);
      expect(find.byKey(kCmccPageGoHomeKey), findsOneWidget);
      expect(d.urls, [kCmccLoginUrl], reason: '没登录过就不该乱跳页面');

      final pokes = d.count('pokeRefresh');
      await tester.pump(const Duration(minutes: 2)); // 停在这儿两分钟
      expect(d.count('pokeRefresh'), pokes,
          reason: '登录页上不做任何自动取数（更不会碰验证码）');

      // 「我已登录，去读数字」→ 去首页
      await tester.tap(find.byKey(kCmccPageGoHomeKey));
      await _flush(tester);
      expect(d.urls.last, kCmccHomeUrl);
    });

    testWidgets('运营商侧维护中 → 如实说明 + 按失败退避排下一次', (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, '系统优化升级公告 请稍后再试');
      final store = CmccSessionStore.instance;
      expect(store.lastError, kCmccFailMaintenance);
      expect(find.text('运营商侧维护中'), findsOneWidget);
      expect(store.failures, 1);
      expect(store.pollPlan.delay, const Duration(minutes: 5));
      // 5 分钟后自动再来一轮
      final pokes = d.count('pokeRefresh');
      await tester.pump(const Duration(minutes: 4));
      expect(d.count('pokeRefresh'), pokes, reason: '不到退避时间不重试');
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(d.count('pokeRefresh'), greaterThan(pokes));
    });

    testWidgets('会话失效 → 停轮询、只提示用户自己重登（绝不代发验证码）',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getNewMarginInfo',
          '{"code":"-1","msg":"请登录"}');

      final store = CmccSessionStore.instance;
      expect(store.needsRelogin, isTrue);
      expect(store.loginState, CmccLoginState.needRelogin);
      expect(store.pollPlan.poll, isFalse, reason: '需要重登 → 停止自动轮询');
      expect(store.pollPlan.delay, isNull);
      expect(find.textContaining('不会代发验证码'), findsOneWidget);
      expect(find.byKey(kCmccPageGoHomeKey), findsOneWidget);

      final pokes = d.count('pokeRefresh');
      await tester.pump(const Duration(hours: 3));
      expect(d.count('pokeRefresh'), pokes,
          reason: '停了就是停了：不会偷偷重试，更不会去撞验证码限流');
      expect(d.urls.toSet(),
          everyElement(isIn([kCmccLoginUrl, kCmccHomeUrl])));
    });

    testWidgets('点了「我已登录」其实没登进去 → 登录引导还在（不留白屏发呆）',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _loginText); // 第一次看到登录页
      expect(find.textContaining('等你在这个页面里登录'), findsOneWidget);

      await tester.tap(find.byKey(kCmccPageGoHomeKey));
      await _flush(tester);
      expect(d.urls.last, kCmccHomeUrl);

      // 页面又回到登录页（用户其实没登）→ 引导必须重新出现
      await _pushText(tester, d, _loginText);
      expect(find.textContaining('等你在这个页面里登录'), findsOneWidget);
      expect(find.text(kCmccLoginHint), findsOneWidget);
      expect(find.byKey(kCmccPageGoHomeKey), findsOneWidget);
    });

    testWidgets('被判"需要重登"后用户真登进去了 → 自动继续读（不留死状态）',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getMainPlan', '{"code":"-1","msg":"请登录"}');
      expect(CmccSessionStore.instance.needsRelogin, isTrue);

      // 用户在页面里重新登录成功 → 页面回到首页
      await _pushText(tester, d, _homeTextWithNumbers);
      expect(CmccSessionStore.instance.needsRelogin, isFalse,
          reason: '回到首页说明会话又活了，重登标记必须清掉');
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      expect(CmccSessionStore.instance.reading!.generalUsedGb,
          closeTo(6.05, 1e-9));
      expect(find.textContaining('读到了'), findsOneWidget);
    });
  });

  group('④ 轮询节奏（30 分钟 / 失败 5 分钟 / 连续 3 次 1 小时）', () {
    testWidgets('成功后 30 分钟才自动再读一次', (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      final pokes = d.count('pokeRefresh');

      await tester.pump(const Duration(minutes: 29));
      expect(d.count('pokeRefresh'), pokes, reason: '不到 30 分钟不查');
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(d.count('pokeRefresh'), greaterThan(pokes),
          reason: '到 30 分钟自动再读一次');
      // 快照防抖：30 分钟后允许再记一条（不会两条挤在一起）
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      expect(TrafficSnapshotStore.instance.snapshots.length, 2);
    });

    testWidgets('连续失败 3 次后退到 1 小时', (tester) async {
      final d = await _pump(tester);
      await _runThreeAttempts(tester, d, _homeTextNoNumbers); // 失败 1
      expect(CmccSessionStore.instance.failures, 1);
      // 5 分钟后退避重试 → 又失败（第 2 次）
      await tester.pump(const Duration(minutes: 5, seconds: 1));
      await _runThreeAttempts(tester, d, _homeTextNoNumbers);
      expect(CmccSessionStore.instance.failures, 2);
      await tester.pump(const Duration(minutes: 5, seconds: 1));
      await _runThreeAttempts(tester, d, _homeTextNoNumbers); // 失败 3
      final store = CmccSessionStore.instance;
      expect(store.failures, 3);
      expect(store.pollPlan.delay, const Duration(hours: 1));

      final pokes = d.count('pokeRefresh');
      await tester.pump(const Duration(minutes: 30));
      expect(d.count('pokeRefresh'), pokes, reason: '已经退到 1 小时，30 分钟不该再试');
      await tester.pump(const Duration(minutes: 30, seconds: 1));
      expect(d.count('pokeRefresh'), greaterThan(pokes));
    });

    testWidgets('页面关掉就不再排轮询（WebView 抓取的硬约束，不常驻后台）',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      final pokes = d.count('pokeRefresh');

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(hours: 2));
      expect(d.count('pokeRefresh'), pokes,
          reason: '页面销毁后定时器必须停（dispose 里 cancel）');
      expect(d.calls, contains('dispose'));
    });
  });

  group('⑤ 兜底与安全面（不新增依赖 / 不代填 / 不代发）', () {
    testWidgets('真 WebView 在测试环境起不来 → 整页可读错误 + 手动兜底提示',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CmccCapturePage()));
      await tester.pump();
      await tester.pump();
      await _flush(tester);
      expect(find.text('打不开掌厅页面'), findsOneWidget);
      expect(find.textContaining('用手动录入'), findsOneWidget);
      expect(find.byKey(kCmccPageStatusKey), findsOneWidget);
    });

    testWidgets('加载失败（驱动抛错）也要说清原因', (tester) async {
      final driver = _FakeDriver()..failStart = true;
      await tester.pumpWidget(MaterialApp(
        home: CmccCapturePage(
          driverFactory: (onHook) {
            driver.onHook = onHook;
            return driver;
          },
        ),
      ));
      await tester.pump();
      await _flush(tester);
      expect(find.text('打不开掌厅页面'), findsOneWidget);
      expect(find.textContaining('StateError'), findsOneWidget);
      expect(CmccSessionStore.instance.lastError, isNotNull);
    });

    testWidgets('页面只会调驱动这几种能力：没有任何"发验证码"的口子',
        (tester) async {
      final d = await _pump(tester);
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _loginText);
      await tester.tap(find.byKey(kCmccPageGoHomeKey));
      await _flush(tester);
      await _runThreeAttempts(tester, d, _homeTextNoNumbers);

      const allowed = {
        'bind',
        'start',
        'reload',
        'requestText',
        'pokeRefresh',
        'readPhoneField',
        'hookInstalled',
        'dispose',
      };
      expect(d.calls.toSet().difference(allowed), isEmpty,
          reason: '驱动接口上根本没有"发/重发验证码"这类方法可调');
      expect(d.urls.toSet(), everyElement(isIn([kCmccLoginUrl, kCmccHomeUrl])),
          reason: '页面只会加载这两个 URL，没有任何"发码"请求');
      // 登录页上停过、失败也发生过，仍然只有这两种 URL
      expect(d.urls, isNotEmpty);
    });

    testWidgets('手机号读不到 / 不是号码 → 不存、不显示（宁缺毋滥）',
        (tester) async {
      final d = await _pump(tester);
      d.phone = '12345'; // 明显不是手机号
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      final store = CmccSessionStore.instance;
      expect(store.phoneTail, isNull);
      expect(_secure.containsKey(CmccSessionStore.phoneStorageKey), isFalse);
      expect(store.reading, isNotNull, reason: '尾号拿不到不该挡住读数');
    });

    testWidgets('自动快照防抖：连着两次读数只记一条（手动快照不被挤掉）',
        (tester) async {
      final d = await _pump(tester);
      // 先手动记一条（模拟 v2.53.0 的老用法）
      await TrafficSnapshotStore.instance.add(CarrierSnapshot(
        at: DateTime(2026, 10, 14, 9),
        carrierGb: 10.00,
        appMobileBytes: 1000,
      ));
      d.bindings!.onPageFinished();
      await _flush(tester);
      await _pushText(tester, d, _homeTextWithNumbers);
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      // 同一分钟内再读一次（用户又点了一次刷新）
      await _pushResponse(tester, d, 'getNewMarginInfo', _cipherMargin);
      final snaps = TrafficSnapshotStore.instance.snapshots;
      expect(snaps.length, 2, reason: '手动那条 + 一条自动，不该被自动的刷屏挤掉');
      expect(snaps.first.source, SnapshotSource.manual);
      expect(snaps.last.source, SnapshotSource.cmcc);
    });
  });
}
