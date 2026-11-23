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
import 'package:bili_whitelist_app/pages/book_source_picker_page.dart';
import 'package:bili_whitelist_app/services/book_source_index_service.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';
import 'package:bili_whitelist_app/services/file_import_service.dart';

BookSource _src(String name, {bool enabled = true}) => BookSource(
  name: name,
  baseUrl: 'https://$name.example',
  version: '1.2',
  enabled: enabled,
  search: const SearchRule(url: '/s?q={{key}}', list: '.item'),
  toc: const TocRule(list: '.ch', name: '.cn', urlSel: '.cu'),
  content: const ContentRule(text: '#content'),
);

/// 假索引服务：不做网络请求，直接给一份结果。
class _FakeIndexService extends BookSourceIndexService {
  _FakeIndexService(this.result);

  final BookSourceIndexResult result;

  @override
  Future<BookSourceIndexResult> fetchIndexes({
    List<String>? urls,
    void Function(int done, int total)? onProgress,
  }) async {
    onProgress?.call(0, 1);
    onProgress?.call(1, 1);
    return result;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  BookSourceStore? store,
  BookSourceIndexService? indexService,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookSourcePage(
        store: store ?? BookSourceStore(),
        indexService: indexService,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 打开 AppBar 的溢出菜单。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
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

/// 让「从文件导入」这条通道返回 [payload]（null = 用户取消）。
void _mockFilePicker(Object? payload) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    FileImportService.channel,
    (call) async => payload,
  );
}

/// 让「从文件导入」抛一个平台异常（验证错误文案真的被翻译成中文）。
void _mockFilePickerError(String code, String message) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(FileImportService.channel, (call) async {
    throw PlatformException(code: code, message: message);
  });
}

void _clearFilePicker() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(FileImportService.channel, null);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _clearClipboard();
    _clearFilePicker();
  });
  tearDown(_clearClipboard);
  tearDown(_clearFilePicker);

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

  testWidgets('剪贴板里只有索引链接 → 记下来并指路去「下载索引书源」', (tester) async {
    _mockClipboard('https://example.com/bookSource.json');
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从剪贴板导入'));
    await tester.pumpAndSettle();

    expect(await store.getIndexUrls(), ['https://example.com/bookSource.json']);
    expect(find.textContaining('可在右上角「下载索引书源」里下载'), findsOneWidget);
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

  testWidgets('从链接导入：直接贴 JSON 能真导入；贴 URL 只记录并指路去下载',
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

    // ② 贴索引 URL → 只记录，界面指路去下载
    await tester.tap(find.text('从链接导入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/list.json',
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(await store.getIndexUrls(), ['https://example.com/list.json']);
    expect(find.textContaining('可在右上角「下载索引书源」里下载'), findsOneWidget);
    // 书源列表没变（没造假成功）
    expect((await store.getAll()).length, 1);
  });

  // ==================== v2.70.0：从本地文件导入 ====================

  testWidgets('三个导入入口都在（含「从文件导入」）', (tester) async {
    await _pump(tester);

    expect(find.text('从剪贴板导入'), findsOneWidget);
    expect(find.text('从文件导入'), findsOneWidget);
    expect(find.text('从链接导入'), findsOneWidget);
  });

  testWidgets('从文件导入：走通道 → 同一个解析器 → 落库 + 提示「导入 N 个（跳过 M 个）」',
      (tester) async {
    _mockFilePicker(<Object?, Object?>{
      'name': 'sources.json',
      // 第二个对象缺 name → 解析器会跳过它，正好验「跳过几个」这句提示
      'content': jsonEncode([
        {'name': '文件里的源', 'baseUrl': 'https://file.example'},
        {'baseUrl': 'https://broken.example'},
      ]),
      'sizeBytes': 128,
    });
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();

    // 真落库（不是界面上假显示）
    expect((await store.getAll()).map((s) => s.name), ['文件里的源']);
    expect(find.text('文件里的源'), findsOneWidget);
    // 提示带上文件名 + 跳过数
    expect(find.textContaining('已从「sources.json」导入 1 个书源'), findsOneWidget);
    expect(find.textContaining('跳过 1 个'), findsOneWidget);
  });

  testWidgets('从文件导入：用户取消 → 什么都不做（不写库、不弹错误）', (tester) async {
    _mockFilePicker(null);
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();

    expect(await store.getAll(), isEmpty);
    expect(find.byType(SnackBar), findsNothing, reason: '取消不是错误，不该弹任何东西');
    // 空态还在（没被"假导入"改掉）
    expect(find.text('还没有书源'), findsOneWidget);
  });

  testWidgets('从文件导入：原生报错 → 把中文文案弹出来，不写库', (tester) async {
    _mockFilePickerError('BAD_ENCODING', '这个文件不是 UTF-8 编码（多半是 GBK），请另存为 UTF-8 后再导入');
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不是 UTF-8 编码'), findsOneWidget);
    expect(await store.getAll(), isEmpty);
  });

  testWidgets('从文件导入：空文件 → 明说它是空的（不丢给 JSON 解析器报含糊错误）',
      (tester) async {
    _mockFilePicker(<Object?, Object?>{'name': 'empty.json', 'content': ''});
    final store = BookSourceStore();
    await _pump(tester, store: store);

    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('「empty.json」是空的'), findsOneWidget);
    expect(await store.getAll(), isEmpty);
  });

  testWidgets('窄屏 360dp：三个导入按钮一行放得下，不溢出也不换行', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester);

    // ① 布局没有溢出（有 RenderFlex overflow 的话这里会拿到异常）
    expect(tester.takeException(), isNull);

    // ② 三个按钮真的都在、且同一行（top 相同 = 没被 Wrap 挤到第二行）
    final clipboard = tester.getRect(find.text('从剪贴板导入'));
    final file = tester.getRect(find.text('从文件导入'));
    final link = tester.getRect(find.text('从链接导入'));
    expect(file.top, clipboard.top);
    expect(link.top, clipboard.top);

    // ③ 都没有被右边界截断
    expect(link.right, lessThanOrEqualTo(360));
  });

  // ==================== R3：索引下载 / 清空 ====================

  testWidgets('溢出菜单三项都在：下载索引书源 / 添加示例书源 / 清空书源', (tester) async {
    await _pump(tester);
    await _openMenu(tester);

    expect(find.text('下载索引书源…'), findsOneWidget);
    expect(find.text('添加示例书源'), findsOneWidget);
    expect(find.text('清空书源'), findsOneWidget);
  });

  testWidgets('下载索引书源：选择页导入后回列表刷新 + 提示「已导入 N 个」',
      (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls(['https://index.example/a.json']);
    await _pump(
      tester,
      store: store,
      indexService: _FakeIndexService(
        BookSourceIndexResult(sources: [_src('索引甲'), _src('索引乙')]),
      ),
    );

    await _openMenu(tester);
    await tester.tap(find.text('下载索引书源…'));
    await tester.pumpAndSettle();
    expect(find.byType(BookSourcePickerPage), findsOneWidget);

    // 选择页里全选 + 导入
    await tester.tap(find.widgetWithText(FilledButton, '下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    // 回到管理页：列表刷新、条数同步、提示说清导了几个
    expect(find.byType(BookSourcePickerPage), findsNothing);
    expect((await store.getAll()).map((s) => s.name), ['索引甲', '索引乙']);
    expect(find.text('索引甲'), findsOneWidget);
    expect(find.text('已导入 2 个书源'), findsOneWidget);
  });

  testWidgets('清空书源：二次确认，取消不动、确认后全删', (tester) async {
    final store = BookSourceStore();
    await store.upsertAll([_src('甲'), _src('乙')]);
    await _pump(tester, store: store);

    // 取消 → 什么都不变
    await _openMenu(tester);
    await tester.tap(find.text('清空书源'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除全部 2 个书源吗'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await store.getAll()).length, 2);

    // 确认 → 全删 + 回到空态
    await _openMenu(tester);
    await tester.tap(find.text('清空书源'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();

    expect(await store.getAll(), isEmpty);
    expect(find.text('还没有书源'), findsOneWidget);
    expect(find.text('已清空 2 个书源'), findsOneWidget);
  });
}
