// 写操作总开关（v2.40.0+）· 存储 + 设置页开关测试。
//
// 覆盖：
// - [UiPrefsStore] 默认值：`writeActionsEnabled` **默认 false**、`favFolderId`
//   **默认 null**、`showTips` 仍默认 true（不改旧默认）；
// - 写 → 立即生效（同步读）+ 真的落盘（SharedPreferences 里能查到）；
// - 落盘回读：`resetForTest(loaded: false)` + `ensureLoaded()` 后仍是关/开的值；
// - `favFolderId`：>0 才存，0/负数等同"没有上次"；
// - 存储抛异常时静默降级（读失败回默认、写失败不抛）；
// - 设置页「写操作」分区：默认关、说明文案写清了为什么默认关 + 投币不可撤回 +
//   评论会立刻公开（v2.50.0 把副标题压到两行后只留这几条要点，"投稿/发视频不在
//   这里"那条免责说明移出）；点一下开关 → 开关态与 store 同步。
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

  // -------------------------------------------------------------------------
  // store
  // -------------------------------------------------------------------------

  test('默认值：写操作**默认关**、没有上次收藏夹、提示条仍默认开', () async {
    await UiPrefsStore.instance.ensureLoaded();
    expect(UiPrefsStore.instance.writeActionsEnabled, isFalse,
        reason: '改动用户真实账号的功能必须默认关');
    expect(UiPrefsStore.instance.favFolderId, isNull);
    expect(UiPrefsStore.instance.showTips, isTrue, reason: '旧默认不变');
  });

  test('开关：立即生效 + 落盘 + 回读', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    expect(store.writeActionsEnabled, isFalse);

    var notified = 0;
    store.addListener(() => notified++);
    await store.setWriteActionsEnabled(true);
    expect(store.writeActionsEnabled, isTrue, reason: '同步读就是新值');
    expect(notified, 1, reason: '通知一次（设置页开关跟着走）');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(UiPrefsStore.writeActionsKey), isTrue);

    // 模拟重启：内存态清掉，从盘上读回来
    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.writeActionsEnabled, isTrue);
  });

  test('开关：重复设同一个值不发多余通知', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    await store.setWriteActionsEnabled(true);
    var notified = 0;
    store.addListener(() => notified++);
    await store.setWriteActionsEnabled(true);
    expect(notified, 0);
  });

  test('favFolderId：记住 / 回读 / 清空；0 与负数等同"没有上次"', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();

    await store.setFavFolderId(222);
    expect(store.favFolderId, 222);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UiPrefsStore.favFolderKey), 222);

    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.favFolderId, 222, reason: '重启后还记得上次的夹');

    await store.setFavFolderId(null);
    expect(store.favFolderId, isNull);

    await store.setFavFolderId(0);
    expect(store.favFolderId, isNull, reason: '0 不是合法夹 id');
    await store.setFavFolderId(-3);
    expect(store.favFolderId, isNull);
  });

  test('盘上有脏值时按"没有上次"处理（不会去请求一个 id=0 的夹）', () async {
    SharedPreferences.setMockInitialValues({'ui:fav_folder_id': 0});
    UiPrefsStore.instance.resetForTest(loaded: false);
    await UiPrefsStore.instance.ensureLoaded();
    expect(UiPrefsStore.instance.favFolderId, isNull);
  });

  test('三个值互相独立：只改一个不影响另两个', () async {
    final store = UiPrefsStore.instance;
    await store.ensureLoaded();
    await store.setWriteActionsEnabled(true);
    await store.setShowTips(false);
    await store.setFavFolderId(333);

    expect(store.writeActionsEnabled, isTrue);
    expect(store.showTips, isFalse);
    expect(store.favFolderId, 333);

    store.resetForTest(loaded: false);
    await store.ensureLoaded();
    expect(store.writeActionsEnabled, isTrue);
    expect(store.showTips, isFalse);
    expect(store.favFolderId, 333);
  });

  // -------------------------------------------------------------------------
  // 设置页
  // -------------------------------------------------------------------------

  testWidgets('设置页：写操作分区默认关，文案说清为什么默认关 + 投币不可撤回',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);

    await _pumpPanel(tester);

    expect(find.text('写操作'), findsOneWidget);
    final sw = find.byKey(kWriteActionsSwitchKey);
    expect(sw, findsOneWidget);
    expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    expect(find.text('已关闭：一个写操作入口都不显示'), findsOneWidget);
    // 默认关的**理由**必须在页面上，不能只写在代码注释里
    expect(find.textContaining('默认关闭'), findsOneWidget);
    // v2.50.0：副标题压到两行 → 原文的「B 站不支持撤回」缩成「投币不可撤回」，
    // 断言跟着改用新措辞（守的还是同一件事：不可撤回这条安全信息必须在页面上）
    expect(find.textContaining('投币不可撤回'), findsOneWidget);
    // v2.42.0：评论区也归这道总闸 → 文案必须把"发评论会怎样"说清（它是四件
    // 写操作里唯一一件"立刻公开给第三方"的）。v2.50.0 压到两行后从"评论会立刻
    // 出现在对方评论区"缩成「（会立刻公开）」，断言随之收窄但意图不变。
    // 另：「投稿/发视频不在这里」那条免责说明随文案删减一并移出（它只是把
    // CHANGELOG 里的边界说明重复一遍，不是安全信息）。
    expect(find.textContaining('会立刻公开'), findsOneWidget);
  });

  testWidgets('设置页：点一下开关 → store 变 true 且副标题跟着改', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);

    await _pumpPanel(tester);
    final sw = find.byKey(kWriteActionsSwitchKey);
    await tester.ensureVisible(sw);
    await tester.pump();

    await tester.tap(sw);
    await tester.pumpAndSettle();

    expect(UiPrefsStore.instance.writeActionsEnabled, isTrue);
    expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    expect(find.text('已开启：信息块显示三个按钮，评论区可发表与回复'),
        findsOneWidget);

    // 再点回去
    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(UiPrefsStore.instance.writeActionsEnabled, isFalse);
  });
}
