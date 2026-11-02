// 「播放时保持亮屏」开关（v2.60.0）· 存储 + 设置页文案测试。
//
// 覆盖：
// - **默认开**（与 B 站官方 App 一致）：出厂 `keepScreenOnEnabled` 是 true；
// - 关掉后**落盘**，模拟重启仍是关（"关着就一次都不亮屏"的持久化前提）；
// - 存储异常静默降级（读失败回默认开、写失败不抛）；
// - 设置页「网络与播放」分区里有 [kKeepScreenOnSwitchKey]，默认显示开启态，
//   点一下立即生效并落盘；
// - 文案约束：标题/副标题**非空白字符 ≤ 42**，且副标题说清"听视频不亮屏"
//   这条边界（否则用户会以为点了听视频还一直亮着）。
//
// 真正的"什么时候亮 / 什么时候关"由 `test/player_keep_screen_on_test.dart`
// 用通道调用序列钉住；通道层去重见 `test/keep_screen_on_test.dart`。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

/// 非空白字符数（设置页文案的长度口径，与 [kStreamCompatHint] 同一条）。
int _nonSpace(String s) => s.replaceAll(RegExp(r'\s'), '').length;

Future<void> _pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ManagePanel(
          github: GithubApi(dio: Dio()),
          onManageCollections: () {},
          onCheckUpdate: () {},
          onLogin: () {},
        ),
      ),
    )),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest(loaded: false);
  });

  tearDown(() => UiPrefsStore.instance.resetForTest(loaded: false));

  test('默认开：出厂的 keepScreenOnEnabled 是 true（与 B 站官方 App 一致）', () async {
    await UiPrefsStore.instance.ensureLoaded();
    expect(UiPrefsStore.instance.keepScreenOnEnabled, isTrue);
  });

  test('开关：立即生效 + 落盘 + 模拟重启回读', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    expect(store.keepScreenOnEnabled, isTrue, reason: '默认开');

    var notified = 0;
    store.addListener(() => notified++);
    await store.setKeepScreenOnEnabled(false);
    expect(store.keepScreenOnEnabled, isFalse);
    expect(notified, 1, reason: '设置页开关要跟着走');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UiPrefsStore.keepScreenOnKey), isFalse, reason: '落盘');

    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.keepScreenOnEnabled, isFalse,
        reason: '用户关过就要跨重启记住（不能又回到默认开）');

    await store.setKeepScreenOnEnabled(true);
    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.keepScreenOnEnabled, isTrue);
  });

  test('存储读失败 → 回默认开（不抛）；写失败也不抛', () async {
    // 读失败：把 key 写成错误类型（getBool 遇到非 bool 会抛 TypeError）
    SharedPreferences.setMockInitialValues({
      UiPrefsStore.keepScreenOnKey: 'not-a-bool',
    });
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    expect(store.keepScreenOnEnabled, isTrue, reason: '读失败按默认开启动，不影响看视频');

    await expectLater(store.setKeepScreenOnEnabled(false), completes);
    expect(store.keepScreenOnEnabled, isFalse, reason: '本次运行立即生效');
  });

  test('设置页文案：标题/副标题非空白字符 ≤ 42，且说清「听视频不亮屏」', () {
    for (final s in [
      kKeepScreenOnTitle,
      kKeepScreenOnSubtitleOn,
      kKeepScreenOnSubtitleOff,
    ]) {
      expect(_nonSpace(s), lessThanOrEqualTo(42),
          reason: '设置项文案要压到两行（当前「$s」= ${_nonSpace(s)} 字）');
    }
    expect(kKeepScreenOnSubtitleOn, contains('听视频'),
        reason: '听视频（音频-only）不亮屏这条边界必须写明');
  });

  testWidgets('设置页：默认开 → 点一下关掉并落盘', (tester) async {
    await _pumpPanel(tester);

    expect(find.byKey(kKeepScreenOnSwitchKey), findsOneWidget);
    expect(find.text(kKeepScreenOnTitle), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byKey(kKeepScreenOnSwitchKey)).value,
      isTrue,
      reason: '默认开（与 B 站一致）',
    );
    expect(find.text(kKeepScreenOnSubtitleOn), findsOneWidget);

    // 面板很长，开关在折叠线以下 → 先滚到可见再点
    final sw = find.byKey(kKeepScreenOnSwitchKey);
    await tester.ensureVisible(sw);
    await tester.pumpAndSettle();
    await tester.tap(sw);
    await tester.pumpAndSettle();

    expect(UiPrefsStore.instance.keepScreenOnEnabled, isFalse, reason: '点关立即生效');
    expect(
      tester.widget<SwitchListTile>(find.byKey(kKeepScreenOnSwitchKey)).value,
      isFalse,
      reason: '开关态跟着 store 走',
    );
    expect(find.text(kKeepScreenOnSubtitleOff), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UiPrefsStore.keepScreenOnKey), isFalse, reason: '落盘');
  });
}
