// 「把观看进度写进 B 站账号历史」开关（v2.57.0+）· 存储 + 设置页文案测试。
//
// 覆盖（v2.57.0 调整后的产品约束，断言的正是这几条）：
// - **默认开**：`historyWriteEnabled` 出厂 true（用户要求「默认开启」）；
// - 用户**显式关掉**后落盘为 false，重启仍是关（"关着零请求"的持久化前提）；
// - 未登录时零请求：由播放页的本地 `bili_jct` 检查 + 上报器的 -101 停手保证
//   （见 `history_write_reporter_test.dart` 与 `shouldReportHistory`）；
// - 立即生效 + 落盘 + 重启回读；
// - 存储异常时静默降级（读失败回默认**开**、写失败不抛）；
// - 设置页「写操作」分区里有这个开关，默认显示「已开启」，且文案写明
//   "会写进你的 B 站账号"；
// - 开关与写操作总开关**互相独立**（开一个不动另一个）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

Future<void> _pumpPanel(WidgetTester tester) async {
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
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest(loaded: false);
  });

  tearDown(() => UiPrefsStore.instance.resetForTest(loaded: false));

  test('默认开：出厂的 historyWriteEnabled 是 true（用户要求「默认开启」）',
      () async {
    await UiPrefsStore.instance.ensureLoaded();
    expect(UiPrefsStore.instance.historyWriteEnabled, isTrue);
  });

  test('开关：立即生效 + 落盘 + 模拟重启回读（显式关掉后又重启仍是关）', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    expect(store.historyWriteEnabled, isTrue, reason: '默认开');

    var notified = 0;
    store.addListener(() => notified++);
    // 显式关掉（"关着零请求"必须先能真的关掉并记住）
    await store.setHistoryWriteEnabled(false);
    expect(store.historyWriteEnabled, isFalse);
    expect(notified, 1, reason: '设置页开关要跟着走');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UiPrefsStore.historyWriteKey), isFalse);
    expect(prefs.getBool(UiPrefsStore.writeActionsKey), isNull,
        reason: '关写历史不该顺手打开点赞/投币/收藏');

    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.historyWriteEnabled, isFalse,
        reason: '用户的选择要跨重启保留（不能又回到默认开）');

    // 再打开一次：同样落盘
    await store.setHistoryWriteEnabled(true);
    expect(prefs.getBool(UiPrefsStore.historyWriteKey), isTrue);
    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.historyWriteEnabled, isTrue);
  });

  test('与写操作总开关互相独立（开写操作不动写历史）', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    // 默认开 → 先显式关掉，再验证"开写操作"不会把它打开
    await store.setHistoryWriteEnabled(false);
    await store.setWriteActionsEnabled(true);
    expect(store.historyWriteEnabled, isFalse);
    await store.setHistoryWriteEnabled(true);
    expect(store.writeActionsEnabled, isTrue);
    await store.setWriteActionsEnabled(false);
    expect(store.historyWriteEnabled, isTrue, reason: '关写操作不该关掉写历史');
  });

  test('存储异常：读失败回默认开、写失败不抛', () async {
    // 读：脏类型（字符串而不是 bool）→ getBool 抛 → 走默认值兜底（默认开）
    SharedPreferences.setMockInitialValues({
      UiPrefsStore.historyWriteKey: 'not-a-bool',
    });
    UiPrefsStore.instance.resetForTest(loaded: false);
    await UiPrefsStore.instance.ensureLoaded();
    expect(UiPrefsStore.instance.historyWriteEnabled, isTrue,
        reason: '读不出来就按出厂默认（开）走，而不是悄悄变成关');

    // 写：内存态照生效（本次运行可用），不抛
    await UiPrefsStore.instance.setHistoryWriteEnabled(false);
    expect(UiPrefsStore.instance.historyWriteEnabled, isFalse);
  });

  testWidgets('设置页：开关存在、默认显示「已开启」、副标题写明会写进 B 站账号',
      (tester) async {
    UiPrefsStore.instance.resetForTest(loaded: false);
    await UiPrefsStore.instance.ensureLoaded();
    await _pumpPanel(tester);

    final tile = find.byKey(kHistoryWriteSwitchKey);
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue,
        reason: '默认开启（用户要求）');

    expect(find.text('把观看进度写进 B 站账号历史'), findsOneWidget);
    // 开着时的文案必须说清"会写进你的 B 站账号"
    expect(
      find.textContaining('会写进你的 B 站账号'),
      findsOneWidget,
    );
    // 分区里还有一句独立说明：默认开、与点赞/投币/收藏无关
    expect(find.textContaining('观看进度默认同步到你的 B 站账号历史'), findsOneWidget);
  });

  testWidgets('设置页：点一下开关 → store 变 false，副标题改成"不会写进你的 B 站账号"',
      (tester) async {
    UiPrefsStore.instance.resetForTest(loaded: false);
    await UiPrefsStore.instance.ensureLoaded();
    await _pumpPanel(tester);

    // 开关在长设置页靠下 → 先滚到可见再点（否则 tap 落在屏幕外）
    await tester.ensureVisible(find.byKey(kHistoryWriteSwitchKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kHistoryWriteSwitchKey));
    await tester.pumpAndSettle();

    expect(UiPrefsStore.instance.historyWriteEnabled, isFalse);
    expect(tester.widget<SwitchListTile>(find.byKey(kHistoryWriteSwitchKey)).value,
        isFalse);
    expect(find.textContaining('不会写进你的 B 站账号'), findsOneWidget);
    // 顺手确认没有把"点赞/投币/收藏"那道总闸一起动到
    expect(UiPrefsStore.instance.writeActionsEnabled, isFalse);
  });
}
