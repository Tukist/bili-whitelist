// ManagePanel 的「界面文案」编辑入口 widget 测试（v2.19.0 补：数据层与读取
// 接线早就在，但设置页一直没有编辑入口——这一批补上）：
// - 设置面板里有入口，按钮标签跟随覆盖条数（全部为默认 / 已自定义 N 条）
// - 弹层按场景分组列出全部出厂文案，输入框预填当前生效值
// - 改一条 → UiCopyStore 立刻有覆盖，且同屏监听它的组件立刻显示新文案
// - 关掉弹层再打开，输入框仍是新值（说明写的是 store 而不是局部 state）
// - 单条「恢复默认」→ 覆盖清除、输入框回填出厂默认
// - 「全部恢复默认」（二次确认）→ 覆盖全清、弹层关闭、宿主提示
// - 空 / 纯空白输入 = 清除覆盖、用回默认（沿用 UiCopyStore 既有语义，未改一字）
// - 分组覆盖 kDefaultCopies 全量（不漏条目）；出厂默认值未被改动
//
// 全局单例状态（UiCopyStore / SharedPreferences）在 setUp / tearDown 里清干净。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

/// 入口按钮 key（与 lib/widgets/manage_panel.dart 里的常量一致）。
const Key _entryKey = Key('ui-copy-editor-entry');

/// 弹层内滚动列表 key。
const Key _listKey = Key('ui-copy-editor-list');

Key _fieldKey(String id) => Key('ui-copy-field:$id');
Key _resetKey(String id) => Key('ui-copy-reset:$id');
Key _itemKey(String id) => Key('ui-copy-item:$id');

/// 内存版 secure storage（mock 原生 MethodChannel，同 manage_panel_test）。
Map<String, String> _store = {};

const MethodChannel _channel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return _store[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        _store[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        _store.remove(args['key'] as String?);
        return true;
      default:
        return null;
    }
  });
}

/// 同屏「读文案」探针：模拟页面上任何一个监听 UiCopyStore 的组件，
/// 用来验证「改完立刻生效」（不依赖具体页面组件，避免与并行改动耦合）。
class _CopyProbe extends StatelessWidget {
  final String id;

  const _CopyProbe(this.id);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UiCopyStore.instance,
      builder: (context, _) => Text(UiCopyStore.instance.text(id)),
    );
  }
}

/// 挂载面板（顶部可选挂一个 [_CopyProbe] 探针）。
///
/// 视口调成 400×1000 逻辑像素：面板 + 47 条文案列表都在里面，测试里
/// 需要滚动的距离短一些（默认 800×600 也跑得通，只是要多滚几屏）。
Future<void> _pumpPanel(WidgetTester tester, {String? probeId}) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final panel = ManagePanel(
    github: GithubApi(),
    closeBeforeNavigate: false,
    headingTitle: '设置',
    headingSubtitle: '集中设置区（测试）',
    onManageCollections: () {},
    onCheckUpdate: () {},
    onLogin: () {},
  );
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          if (probeId != null) _CopyProbe(probeId),
          Expanded(child: SingleChildScrollView(child: panel)),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
  // 面板 initState 会触发一次 ensureLoaded（幂等）：显式 await 一次，
  // 保证后续断言不会撞上「还在读盘」的中间态。
  await UiCopyStore.instance.ensureLoaded();
  await tester.pumpAndSettle();
}

/// 滚到面板里的入口并点开编辑弹层。
Future<void> _openEditor(WidgetTester tester) async {
  final entry = find.byKey(_entryKey);
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
  expect(find.byKey(_listKey), findsOneWidget, reason: '弹层没打开');
}

/// 关掉弹层（右上角关闭按钮）。
Future<void> _closeEditor(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.close));
  await tester.pumpAndSettle();
  expect(find.byKey(_listKey), findsNothing, reason: '弹层没关掉');
}

/// 弹层列表里的滚动视图。
///
/// `scrollable` 要取 `.first`：每个输入框里的 EditableText 自己也有一个
/// Scrollable，不取第一个会命中一堆（7 个）。
Finder _listScrollable() => find
    .descendant(of: find.byKey(_listKey), matching: find.byType(Scrollable))
    .first;

/// 在弹层列表里滚到某个 id 的整块（说明行 + 输入框 + 恢复默认按钮）。
///
/// 列表是 `shrinkWrap: true` 的懒构建列表：**只有当前可见的条目才会 mount**
/// （连视口上方 40px 的分组标题都会被回收），所以断言前必须先滚到它。
Future<void> _scrollToItem(WidgetTester tester, String id) async {
  final target = find.byKey(_itemKey(id));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      300,
      maxScrolls: 80,
      scrollable: _listScrollable(),
    );
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget, reason: '没滚到 $id');
}

/// 滚到弹层列表里的某段文字（分组标题等）。
Future<void> _scrollToText(WidgetTester tester, String text) async {
  final target = find.text(text);
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      300,
      maxScrolls: 80,
      scrollable: _listScrollable(),
    );
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget, reason: '没滚到「$text」');
}

/// 读某条输入框里当前的文本。
String _fieldText(WidgetTester tester, String id) {
  final field = tester.widget<TextField>(find.byKey(_fieldKey(id)));
  return field.controller!.text;
}

/// 改一条（先滚到它）。
Future<void> _edit(WidgetTester tester, String id, String value) async {
  await _scrollToItem(tester, id);
  await tester.enterText(find.byKey(_fieldKey(id)), value);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store = {};
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({});
    // 传空 map：内存无覆盖 + `_loaded = true` → 面板 initState 的
    // ensureLoaded 直接返回，用例内不会撞上"还在读盘"的中间态。
    UiCopyStore.instance.resetForTest(const <String, String>{});
  });

  tearDown(() {
    UiCopyStore.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('入口', () {
    testWidgets('设置面板里有「界面文案」分区与入口按钮（默认「全部为默认」）',
        (tester) async {
      await _pumpPanel(tester);

      final entry = find.byKey(_entryKey);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();

      expect(find.text('界面文案'), findsOneWidget);
      expect(entry, findsOneWidget);
      expect(find.text('全部为默认'), findsOneWidget);
      expect(find.textContaining('已自定义'), findsNothing);
    });

    testWidgets('入口标签跟随覆盖条数：改了 N 条 → 「已自定义 N 条」',
        (tester) async {
      UiCopyStore.instance.resetForTest(const <String, String>{});
      await UiCopyStore.instance.setOverride('empty.history', 'A');
      await UiCopyStore.instance.setOverride('empty.comment', 'B');

      await _pumpPanel(tester);
      final entry = find.byKey(_entryKey);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();

      expect(find.text('已自定义 2 条'), findsOneWidget);
      expect(find.text('全部为默认'), findsNothing);
    });

    testWidgets('盘上的覆盖在打开面板后被读回来（重启后仍生效的数据链路）',
        (tester) async {
      // 模拟"上次改过、这次冷启动"：存储里有覆盖，内存是空的（loaded=false）
      SharedPreferences.setMockInitialValues({
        UiCopyStore.storageKey: jsonEncode({'empty.history': '盘上的文案'}),
      });
      UiCopyStore.instance.resetForTest();
      expect(UiCopyStore.instance.hasOverride('empty.history'), isFalse);

      await _pumpPanel(tester); // initState 触发 ensureLoaded + 显式 await
      await _openEditor(tester);
      await _scrollToItem(tester, 'empty.history');

      expect(_fieldText(tester, 'empty.history'), '盘上的文案');
    });
  });

  group('弹层内容', () {
    testWidgets('按场景分组列出全部文案，输入框预填当前生效值', (tester) async {
      await _pumpPanel(tester);
      await _openEditor(tester);

      // 弹层标题（「界面文案」既是面板分区标题也是弹层标题，面板还在下面）
      expect(find.text('界面文案'), findsWidgets);
      // 首个分组 + 组内条目的可读说明 + 当前文案（输入框预填）
      expect(find.text('空态 · 白名单 / 首页'), findsOneWidget);
      expect(find.text('首页白名单为空'), findsOneWidget);
      expect(find.text('白名单里还没有 UP 主'), findsOneWidget);
      expect(find.text('empty.playlist.upowner'), findsOneWidget);
      expect(find.text('还没有白名单 UP 主'), findsOneWidget);
      expect(_fieldText(tester, 'empty.playlist'), '白名单为空\n下拉刷新重新同步');

      // 后面的分组逐条滚过去（列表懒构建：没挂载 = 视口外，断言前先滚到它）
      await _scrollToText(tester, '空态 · 历史');
      expect(find.text('历史页为空'), findsOneWidget);
      expect(_fieldText(tester, 'empty.history'), '暂无历史记录');
      // .sub 是独立一条，说明里带"副文案"
      await _scrollToItem(tester, 'empty.history.sub');
      expect(find.text('历史页为空的副文案'), findsOneWidget);
      expect(
        _fieldText(tester, 'empty.history.sub'),
        '看过的视频会出现在这里，点击可续播',
      );
      await _scrollToText(tester, '某一天没有观看记录');
      expect(_fieldText(tester, 'empty.daily_history'), '该日无观看记录');

      await _scrollToText(tester, '整页加载 · 闲话');
      expect(find.text('整页加载闲话 1'), findsOneWidget);
      await _scrollToItem(tester, 'loading.line.1');
      expect(
        _fieldText(tester, 'loading.line.1'),
        '人生有时就得管没有肉的青椒肉丝，叫青椒肉丝。',
      );
    });

    testWidgets('分组表覆盖全部出厂文案（不漏条目、不重不漏）', (tester) async {
      final sections = groupCopyIds();
      final ids = <String>[
        for (final s in sections) ...s.ids,
      ];

      expect(ids.toSet().length, ids.length, reason: '有 id 落进了多个分组');
      expect(
        ids.toSet(),
        UiCopyStore.kDefaultCopies.keys.toSet(),
        reason: '分组表漏掉了出厂文案（新加的文案要补分组前缀或说明）',
      );
      expect(sections.length, greaterThan(5), reason: '分组太粗，用户找不到条目');
    });

    testWidgets('未覆盖时没有「恢复默认」，覆盖后单条按钮出现', (tester) async {
      await _pumpPanel(tester);
      await _openEditor(tester);
      await _scrollToItem(tester, 'empty.history');

      expect(find.byKey(_resetKey('empty.history')), findsNothing);

      await _edit(tester, 'empty.history', '改了');

      expect(find.byKey(_resetKey('empty.history')), findsOneWidget);
    });
  });

  group('写入与生效', () {
    testWidgets('改一条 → UiCopyStore 立刻有覆盖，同屏监听它的组件立刻显示新文案',
        (tester) async {
      await _pumpPanel(tester, probeId: 'empty.history');
      expect(find.text('暂无历史记录'), findsOneWidget); // 探针

      await _openEditor(tester);
      await _edit(tester, 'empty.history', '这里空得能听见回声');

      // store 侧：覆盖写入 + 立刻可读
      expect(UiCopyStore.instance.hasOverride('empty.history'), isTrue);
      expect(UiCopyStore.instance.text('empty.history'), '这里空得能听见回声');
      // 只动这一条，别的还是默认
      expect(UiCopyStore.instance.text('empty.daily_history'), '该日无观看记录');
      // UI 侧：探针 + 输入框都显示新文案（探针在弹层下面，也被刷新了）
      expect(find.text('这里空得能听见回声'), findsNWidgets(2));

      await _closeEditor(tester);
      // 弹层关掉后只剩探针 → 页面确实拿到的是新文案
      expect(find.text('这里空得能听见回声'), findsOneWidget);
      expect(find.text('暂无历史记录'), findsNothing);
    });

    testWidgets('关掉再打开：输入框仍是改过的值（值来自 store，不是局部 state）',
        (tester) async {
      await _pumpPanel(tester);
      await _openEditor(tester);
      await _edit(tester, 'empty.comment', '第一句话留给我');
      await _closeEditor(tester);

      await _openEditor(tester);
      await _scrollToItem(tester, 'empty.comment');

      expect(_fieldText(tester, 'empty.comment'), '第一句话留给我');
      expect(UiCopyStore.instance.text('empty.comment'), '第一句话留给我');
    });

    testWidgets('空 / 纯空白输入 = 清除覆盖、用回默认（沿用 store 语义）',
        (tester) async {
      await _pumpPanel(tester);
      await _openEditor(tester);

      // 先改成功，再把内容清成纯空白
      await _edit(tester, 'empty.comment', '临时改的');
      expect(UiCopyStore.instance.hasOverride('empty.comment'), isTrue);
      await _edit(tester, 'empty.comment', '   ');

      expect(UiCopyStore.instance.hasOverride('empty.comment'), isFalse);
      expect(UiCopyStore.instance.text('empty.comment'), '暂无评论');
      // 输入框为空时给出提示：留空 = 用回默认（并显示默认文案）
      expect(find.text('留空 = 用回默认：暂无评论'), findsOneWidget);
      // 该条的「恢复默认」随覆盖一起消失
      expect(find.byKey(_resetKey('empty.comment')), findsNothing);
    });
  });

  group('恢复默认', () {
    testWidgets('单条恢复：覆盖被清除、输入框回填出厂默认', (tester) async {
      await _pumpPanel(tester);
      await _openEditor(tester);

      await _edit(tester, 'empty.history', '改过的历史空态');
      expect(UiCopyStore.instance.hasOverride('empty.history'), isTrue);

      await tester.tap(find.byKey(_resetKey('empty.history')));
      await tester.pumpAndSettle();

      expect(UiCopyStore.instance.hasOverride('empty.history'), isFalse);
      expect(UiCopyStore.instance.text('empty.history'), '暂无历史记录');
      expect(_fieldText(tester, 'empty.history'), '暂无历史记录');
      expect(find.byKey(_resetKey('empty.history')), findsNothing);
      // 单条恢复不关弹层
      expect(find.byKey(_listKey), findsOneWidget);
    });

    testWidgets('全部恢复默认：先二次确认（取消不动），确认后清空并关闭弹层+提示',
        (tester) async {
      await UiCopyStore.instance.setOverride('empty.history', 'A');
      await UiCopyStore.instance.setOverride('empty.comment', 'B');
      await _pumpPanel(tester);
      await _openEditor(tester);

      // 弹层里显示当前自定义条数
      expect(find.text('全部恢复默认（2 条）'), findsOneWidget);
      await tester.tap(find.text('全部恢复默认（2 条）'));
      await tester.pumpAndSettle();

      // 二次确认：先取消 → 覆盖还在
      expect(find.text('全部恢复默认'), findsOneWidget); // 对话框标题
      expect(find.text('将清掉全部 2 条自定义文案，界面回到出厂文案。这不会影响别的设置。'),
          findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(UiCopyStore.instance.hasOverride('empty.history'), isTrue);
      expect(find.byKey(_listKey), findsOneWidget);

      // 再来一次并确认 → 覆盖全清、弹层关闭、宿主提示
      await tester.tap(find.text('全部恢复默认（2 条）'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '全部恢复'));
      await tester.pumpAndSettle();

      expect(UiCopyStore.instance.hasOverride('empty.history'), isFalse);
      expect(UiCopyStore.instance.hasOverride('empty.comment'), isFalse);
      expect(copyOverrideCount(), 0);
      expect(find.byKey(_listKey), findsNothing, reason: '确认后弹层应关掉');
      expect(find.text('已全部恢复默认'), findsOneWidget); // SnackBar（干净上下文）
    });
  });

  group('出厂默认不被改动', () {
    testWidgets('全改一遍再 resetAll：逐字回到出厂默认、默认表本身无覆盖残留',
        (tester) async {
      // 所有可编辑条目都改一遍（走 store，UI 改法同上，这里为速度直接改）
      for (final id in UiCopyStore.kDefaultCopies.keys) {
        await UiCopyStore.instance.setOverride(id, '覆盖:$id');
      }
      expect(copyOverrideCount(), UiCopyStore.kDefaultCopies.length);

      await UiCopyStore.instance.resetAll();

      expect(copyOverrideCount(), 0);
      for (final entry in UiCopyStore.kDefaultCopies.entries) {
        expect(UiCopyStore.instance.text(entry.key), entry.value,
            reason: '${entry.key} 没回到出厂默认');
        expect(UiCopyStore.instance.hasOverride(entry.key), isFalse);
      }
      // 测试断言锚点：出厂值必须逐字不变（store 与编辑器都不许动它们）
      expect(UiCopyStore.kDefaultCopies['empty.history'], '暂无历史记录');
      expect(UiCopyStore.kDefaultCopies['empty.playlist'],
          '白名单为空\n下拉刷新重新同步');
      expect(UiCopyStore.kDefaultCopies['footer.no_more'], '没有更多了');
      expect(UiCopyStore.kDefaultCopies.length, 47);
    });
  });
}
