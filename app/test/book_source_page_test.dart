// 书源管理页测试（R1）。
//
// 这里验证的是「管理页真的读写了那份存储」，而不是只画了个列表：
// - 空态 / 有数据两种样子；
// - 从剪贴板导入（真走 Clipboard.getData 通道，用 mock method channel）；
// - 启用开关落库、删除有二次确认、删除后行消失；
// - 长按看原始 JSON（只读弹层里能看到 legado 原始字段）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_source_page.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

BookSource _src(String name, {bool enabled = true}) => BookSource(
  name: name,
  baseUrl: 'https://$name.example',
  version: '1.2',
  enabled: enabled,
  search: const SearchRule(url: '/s?q={{key}}', list: '.item'),
  toc: const TocRule(list: '.ch', name: '.cn', urlSel: '.cu'),
  content: const ContentRule(text: '#content'),
);

Future<void> _pump(
  WidgetTester tester, {
  BookSourceStore? store,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: BookSourcePage(store: store ?? BookSourceStore())),
  );
  await tester.pumpAndSettle();
}

/// 让 `Clipboard.getData` 返回 [text]。
void _mockClipboard(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      return text == null ? null : {'text': text};
    }
    return null;
  });
}

void _clearClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _clearClipboard();
  });
  tearDown(_clearClipboard);

  testWidgets('空存储 → 空态文案（引导粘贴 legado JSON）', (tester) async {
    await _pump(tester);

    expect(find.text('书源'), findsOneWidget); // AppBar
    expect(find.text('还没有书源'), findsOneWidget);
    expect(find.text('粘贴 legado 格式的书源 JSON 导入'), findsOneWidget);
    // 两个入口都在
    expect(find.text('从剪贴板导入'), findsOneWidget);
    expect(find.text('从链接导入'), findsOneWidget);
  });

  testWidgets('已有书源 → 每行显示名字 / 地址 / 版本 + 开关 + 删除', (tester) async {
    final store = BookSourceStore();
    await store.upsertAll([_src('甲'), _src('乙', enabled: false)]);
    await _pump(tester, store: store);

    expect(find.text('甲'), findsOneWidget);
    expect(find.text('https://甲.example'), findsOneWidget);
    expect(find.text('v1.2'), findsNWidgets(2));
    expect(find.byType(Switch), findsNWidgets(2));
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    // 停用的源开关是关的
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.where((s) => s.value).length, 1);
  });

  testWidgets('从剪贴板导入：落库 + 列表立刻出现新源', (tester) async {
    _mockClipboard(
      jsonEncode({
        'name': '剪贴板源',
        'baseUrl': 'https://clip.example',
        'search': {'url': '/s?q={{key}}', 'list': '.item'},
      }),
    );
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();

    // 落到存储里（不是只在界面上假显示）
    final saved = await store.getAll();
    expect(saved.map((s) => s.name), ['剪贴板源']);
    // 界面刷新成列表
    expect(find.text('剪贴板源'), findsOneWidget);
    expect(find.text('还没有书源'), findsNothing);
  });

  testWidgets('剪贴板是空的 → 提示，不写存储', (tester) async {
    _mockClipboard('');
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();

    expect(find.text('剪贴板是空的，先复制书源 JSON'), findsOneWidget);
    expect(await store.getAll(), isEmpty);
  });

  testWidgets('剪贴板内容解析不了 → 把人话原因弹出来（不是堆栈）', (tester) async {
    _mockClipboard('这里只有一段中文，没有 JSON');
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有找到书源 JSON'), findsOneWidget);
    expect(await store.getAll(), isEmpty);
  });

  testWidgets('剪贴板里只有索引链接 → 记下来并明说「后续版本启用」', (tester) async {
    _mockClipboard('https://example.com/bookSource.json');
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();

    expect(await store.getIndexUrls(), ['https://example.com/bookSource.json']);
    expect(find.textContaining('链接下载将在后续版本启用'), findsOneWidget);
    // 没有假装导入成功
    expect(await store.getAll(), isEmpty);
  });

  testWidgets('启用开关：点一下落库（停用后再点回启用也能存）', (tester) async {
    final store = BookSourceStore();
    await store.upsertAll([_src('甲')]);
    await _pump(tester, store: store);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect((await store.getAll()).single.enabled, isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect((await store.getAll()).single.enabled, isTrue);
  });

  testWidgets('删除要二次确认：取消不动，确认后行消失且存储同步', (tester) async {
    final store = BookSourceStore();
    await store.upsertAll([_src('要删的'), _src('留着的')]);
    await _pump(tester, store: store);

    // 第一行的删除按钮
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('删除书源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await store.getAll()).length, 2);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect((await store.getAll()).map((s) => s.name), ['留着的']);
    expect(find.text('要删的'), findsNothing);
  });

  testWidgets('长按看原始 JSON：弹层里能看到 legado 原始字段（只读）', (tester) async {
    final store = BookSourceStore();
    await store.upsertAll([
      BookSource.fromLegado({
        'bookSourceName': 'L源',
        'bookSourceUrl': 'https://l.example',
        'ruleSearch': {'bookList': '.item'},
      })!,
    ]);
    await _pump(tester, store: store);

    await tester.longPress(find.text('L源'));
    await tester.pumpAndSettle();

    // 弹层标题 = 书源名；内容是格式化 JSON（含 raw 里的 legado 字段）
    expect(find.text('L源'), findsWidgets);
    expect(find.textContaining('bookSourceName'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bookSourceName'), findsNothing);
  });

  testWidgets('从链接导入：直接贴 JSON 能真导入；贴 URL 只记录并说明未启用',
      (tester) async {
    final store = BookSourceStore();
    await _pump(tester, store: store);

    // ① 贴 JSON 正文 → 真导入
    await tester.tap(find.text('从链接导入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      jsonEncode({'name': '链接里的源', 'baseUrl': 'https://inline.example'}),
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect((await store.getAll()).map((s) => s.name), ['链接里的源']);

    // ② 贴索引 URL → 只记录，界面明说后续版本启用
    await tester.tap(find.text('从链接导入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/list.json',
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(await store.getIndexUrls(), ['https://example.com/list.json']);
    expect(find.textContaining('链接下载将在后续版本启用'), findsOneWidget);
    // 书源列表没变（没造假成功）
    expect((await store.getAll()).length, 1);
  });
}
