// 「设置里能关掉底部黑框提示」的测试（v2.36.0，用户原话「可以在设置里关掉底部
// 的黑框提示」）。三块：
//
// 1. [UiPrefsStore]：默认**开**、关掉后落盘、重建（模拟冷启动）读回同一个值；
// 2. [AppSnack]：**只有 info 档受开关控制** —— 关掉提示时
//    - info（提示 / 成功 / 门禁）不弹，
//    - error（失败 / 未同步到 Gist）照样弹（关掉提示不该让失败静默），
//    - 带 [SnackBarAction] 的照样弹（「撤销」是最后的挽回入口，不能一起关掉）；
// 3. 设置页（ManagePanel）里的开关：默认开、点一下关掉并落盘。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/widgets/app_snack.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

// ---------------------------------------------------------------------------
// 替身 / 工具
// ---------------------------------------------------------------------------

/// 内存版 secure storage（ManagePanel 读 B 站账号态时要走它，不 mock 会报
/// MissingPluginException；同 manage_panel_test / copy_editor_test 的做法）。
Map<String, String> _secure = {};

const MethodChannel _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
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
}

/// 三条不同语义的提示各一个按钮（info / error / 带「撤销」动作的 info）。
class _SnackHost extends StatelessWidget {
  const _SnackHost();

  @override
  Widget build(BuildContext context) {
    void action() {} // 撤销按钮的回调在测试里不做事
    return Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => AppSnack.show(context, '已保存'),
            child: const Text('弹 info'),
          ),
          TextButton(
            onPressed: () => AppSnack.show(
              context,
              '保存失败：网络错误',
              kind: SnackKind.error,
            ),
            child: const Text('弹 error'),
          ),
          TextButton(
            onPressed: () => AppSnack.show(
              context,
              '已填充 6 格',
              action: SnackBarAction(label: '撤销', onPressed: action),
            ),
            child: const Text('弹 撤销'),
          ),
        ],
      ),
    );
  }
}

Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: _SnackHost()));
  await tester.pumpAndSettle();
}

/// 挂设置页（视口放大到能看全，省得滚很远）。
Future<void> _pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ManagePanel(
            github: GithubApi(),
            headingTitle: '设置',
            headingSubtitle: '集中设置区（测试）',
            onManageCollections: () {},
            onCheckUpdate: () {},
            onLogin: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _secure = {};
    _mockSecureStorage();
    UiPrefsStore.instance.resetForTest();
  });
  tearDown(() => UiPrefsStore.instance.resetForTest());

  // -------------------------------------------------------------------------
  group('UiPrefsStore：默认开 + 持久化', () {
    test('默认开，且 key 走 ui: 前缀', () {
      expect(UiPrefsStore.instance.showTips, isTrue, reason: '默认必须开');
      expect(UiPrefsStore.showTipsKey, startsWith('ui:'));
    });

    test('关掉 → 落盘；重置内存态后 ensureLoaded 读回同一个值（模拟冷启动）',
        () async {
      final store = UiPrefsStore.instance;
      await store.setShowTips(false);
      expect(store.showTips, isFalse, reason: '立刻生效（设置页开关跟着走）');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(UiPrefsStore.showTipsKey), isFalse, reason: '落盘');

      // 模拟冷启动：内存态回默认、loaded 标记清掉 → 再读一次盘
      store.resetForTest();
      expect(store.showTips, isTrue, reason: '重置后是默认值（证明下面读到的是盘上的）');
      await store.ensureLoaded();
      expect(store.showTips, isFalse, reason: '上次关过 → 冷启动仍是关');
    });

    test('盘上没有记录 / 值坏掉 → 一律回默认开', () async {
      final store = UiPrefsStore.instance;
      await store.ensureLoaded();
      expect(store.showTips, isTrue);
    });

    test('ensureLoaded 幂等：重复调用不会把内存里刚改的值覆盖回去', () async {
      final store = UiPrefsStore.instance;
      await store.ensureLoaded();
      await store.setShowTips(false);
      await store.ensureLoaded();
      expect(store.showTips, isFalse, reason: '_loaded 之后不再读盘');
    });
  });

  // -------------------------------------------------------------------------
  group('AppSnack.allows：按语义 gate（判定只有这一处）', () {
    test('开关开：三种都允许', () {
      expect(AppSnack.allows(SnackKind.info), isTrue);
      expect(AppSnack.allows(SnackKind.error), isTrue);
      expect(
        AppSnack.allows(
          SnackKind.info,
          action: SnackBarAction(label: '撤销', onPressed: () {}),
        ),
        isTrue,
      );
    });

    test('开关关：info 不允许，error 与带 action 的仍允许', () {
      UiPrefsStore.instance.resetForTest(showTips: false);
      expect(AppSnack.allows(SnackKind.info), isFalse, reason: '提示类被关掉');
      expect(AppSnack.allows(SnackKind.error), isTrue,
          reason: '错误类永不静默 —— 关掉提示不能让失败变成没声音');
      expect(
        AppSnack.allows(
          SnackKind.info,
          action: SnackBarAction(label: '撤销', onPressed: () {}),
        ),
        isTrue,
        reason: '带撤销按钮的一律放行：关掉它等于把撤销入口一起关掉',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('AppSnack.show：真实的提示条行为', () {
    testWidgets('开关开：三条都弹得出来（回归：默认开时一切照旧）', (tester) async {
      await _pumpHost(tester);

      await tester.tap(find.text('弹 info'));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsOneWidget);

      await tester.tap(find.text('弹 error'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败：网络错误'), findsOneWidget);
      // 新的一条顶掉旧的（统一 hideCurrentSnackBar）→ 屏上永远只有一条
      expect(find.text('已保存'), findsNothing);

      await tester.tap(find.text('弹 撤销'));
      await tester.pumpAndSettle();
      expect(find.text('已填充 6 格'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
    });

    testWidgets('开关关：info 不弹、error 照弹、带撤销动作的照弹', (tester) async {
      UiPrefsStore.instance.resetForTest(showTips: false);
      await _pumpHost(tester);

      await tester.tap(find.text('弹 info'));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsNothing, reason: '提示类被关掉了');

      await tester.tap(find.text('弹 error'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败：网络错误'), findsOneWidget,
          reason: '失败必须有声音');

      await tester.tap(find.text('弹 撤销'));
      await tester.pumpAndSettle();
      expect(find.text('已填充 6 格'), findsOneWidget,
          reason: '带「撤销」的提示不能一起关掉');
      expect(find.text('撤销'), findsOneWidget);
    });

    testWidgets('开关**中途**关掉：之后弹的 info 立刻不显示（读的是实时值）',
        (tester) async {
      await _pumpHost(tester);
      await tester.tap(find.text('弹 info'));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsOneWidget);
      // 让这条自己超时消失（默认 4s），免得下面把"上一轮残留"误判成"又弹了"
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsNothing);

      await UiPrefsStore.instance.setShowTips(false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('弹 info'));
      await tester.pumpAndSettle();
      expect(find.text('已保存'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('设置页开关', () {
    testWidgets('默认开；点一下 → 关 + 落盘；恢复再点 → 开', (tester) async {
      await _pumpPanel(tester);

      final sw = find.byKey(kTipsSwitchKey);
      expect(sw, findsOneWidget, reason: '设置里有这个分区');
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(sw).value, isTrue, reason: '默认开');
      expect(find.text('显示底部提示条'), findsOneWidget);
      expect(
        find.textContaining('关掉后不再弹底部的提示条'),
        findsOneWidget,
        reason: '文案要说清"关掉会发生什么"',
      );

      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      expect(UiPrefsStore.instance.showTips, isFalse, reason: '立刻生效');
      expect(
        (await SharedPreferences.getInstance())
            .getBool(UiPrefsStore.showTipsKey),
        isFalse,
        reason: '落盘（下次冷启动仍是关）',
      );

      await tester.tap(sw);
      await tester.pumpAndSettle();
      expect(UiPrefsStore.instance.showTips, isTrue);
      expect(
        (await SharedPreferences.getInstance())
            .getBool(UiPrefsStore.showTipsKey),
        isTrue,
      );
    });

    testWidgets('盘上存着「关」→ 面板打开时开关就是关的', (tester) async {
      SharedPreferences.setMockInitialValues({UiPrefsStore.showTipsKey: false});
      UiPrefsStore.instance.resetForTest();
      await UiPrefsStore.instance.ensureLoaded();
      await _pumpPanel(tester);

      final sw = find.byKey(kTipsSwitchKey);
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
    });
  });
}
