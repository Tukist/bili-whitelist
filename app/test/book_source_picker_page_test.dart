// 书源索引选择页测试（R3）。
//
// 覆盖的是「6000 条也不卡」和「上限 200 必须显式说清楚」这两件事：
// - 列表懒加载（只建可见行）；
// - 搜索过滤（name / baseUrl）、两个筛选开关、全选/清空；
// - 超过 200 时导入按钮禁用 + 给提示；
// - 导入真的调 `upsertAll` 并把条数交回上一页；
// - 下载的链接会写回 store（整份替换）；
// - 底部按钮给系统导航栏让位（A 批那条安全区规矩）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_source_picker_page.dart';
import 'package:bili_whitelist_app/services/book_source_index_service.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

BookSource _src(String name) => BookSource(
      name: name,
      baseUrl: 'https://$name.example',
      search: const SearchRule(url: '/s?q={{key}}', list: '.item'),
      toc: const TocRule(list: '.ch', name: '.cn', urlSel: '.cu'),
      content: const ContentRule(text: '#content'),
    );

/// 从 JSON 造源（走模型读入口，用来复现索引包里带换行 / 零宽字符的脏名字）。
BookSource _srcFromJson(String rawName) => BookSource.fromJson({
      'name': rawName,
      'baseUrl': 'https://dirty.example',
      'search': {'url': '/s?q={{key}}', 'list': '.item'},
      'toc': {'list': '.ch', 'name': '.cn', 'urlSel': '.cu'},
      'content': {'text': '#content'},
    });

/// 假服务：直接返回预设结果（不碰网络），并记下被请求的链接。
class _FakeIndexService extends BookSourceIndexService {
  _FakeIndexService(this.result);

  final BookSourceIndexResult result;
  List<String>? lastUrls;
  int calls = 0;

  @override
  Future<BookSourceIndexResult> fetchIndexes({
    List<String>? urls,
    void Function(int done, int total)? onProgress,
  }) async {
    calls++;
    lastUrls = urls;
    onProgress?.call(0, 1);
    onProgress?.call(1, 1);
    return result;
  }
}

BookSourceIndexResult _result(
  List<BookSource> sources, {
  Set<String> jsKeys = const {},
  List<IndexUrlOutcome> outcomes = const [],
}) =>
    BookSourceIndexResult(sources: sources, jsKeys: jsKeys, outcomes: outcomes);

const String _kLink = 'https://index.example/a.json';

Future<void> _pump(
  WidgetTester tester, {
  required BookSourceStore store,
  required BookSourceIndexService service,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: BookSourcePickerPage(store: store, service: service)),
  );
  await tester.pumpAndSettle();
}

/// 点「下载」并等结果落到界面。
Future<void> _download(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '下载'));
  await tester.pumpAndSettle();
}

Future<void> _openPickerViaPush(
  WidgetTester tester, {
  required BookSourceStore store,
  required BookSourceIndexService service,
  required void Function(int?) onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final result = await Navigator.of(context).push<int>(
                MaterialPageRoute(
                  builder: (_) =>
                      BookSourcePickerPage(store: store, service: service),
                ),
              );
              onResult(result);
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('6000 条只建可见行（ListView.builder 懒加载）', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final all = [for (var i = 0; i < 6000; i++) _src('源$i')];
    await _pump(tester, store: store, service: _FakeIndexService(_result(all)));

    await _download(tester);

    expect(find.text('源0'), findsOneWidget);
    // 懒加载的证据：6000 条里只建出来几十行
    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(60));
    expect(find.byType(CheckboxListTile).evaluate().length, greaterThan(0));
  });

  testWidgets('搜索：按名字和站点地址都能过滤', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final all = [for (var i = 0; i < 30; i++) _src('源$i')];
    await _pump(tester, store: store, service: _FakeIndexService(_result(all)));
    await _download(tester);

    await tester.enterText(find.byType(TextField).last, '源2');
    await tester.pumpAndSettle();
    // 断言落在列表行上，而不是 find.text（搜索框里也有这两个字）
    expect(find.widgetWithText(CheckboxListTile, '源2'), findsOneWidget);
    expect(find.widgetWithText(CheckboxListTile, '源20'), findsOneWidget);
    expect(find.widgetWithText(CheckboxListTile, '源1'), findsNothing);
    expect(find.widgetWithText(CheckboxListTile, '源3'), findsNothing);

    // 地址也参与匹配（用户可能只记得域名）
    await tester.enterText(find.byType(TextField).last, '源7.example');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CheckboxListTile, '源7'), findsOneWidget);
    expect(find.widgetWithText(CheckboxListTile, '源6'), findsNothing);
  });

  testWidgets('筛选：默认只看没导入的，关掉后已导入的会出现', (tester) async {
    final store = BookSourceStore();
    await store.upsertAll([_src('已有')]);
    await store.saveIndexUrls([_kLink]);
    await _pump(
      tester,
      store: store,
      service: _FakeIndexService(_result([_src('已有'), _src('新的')])),
    );
    await _download(tester);

    // 默认 _onlyNew = true：已导入的藏起来
    expect(find.text('新的'), findsOneWidget);
    expect(find.text('已有'), findsNothing);

    await tester.tap(find.text('只看当前没导入的'));
    await tester.pumpAndSettle();
    expect(find.text('已有'), findsOneWidget);
    // 已经导入过的会带角标，用户能明白为什么它不算新增
    expect(find.text('已导入'), findsOneWidget);
  });

  testWidgets('筛选：只看不需要 JS 的', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final plain = _src('普通');
    final js = _src('JS源');
    await _pump(
      tester,
      store: store,
      service: _FakeIndexService(
        _result([plain, js], jsKeys: {js.key}),
      ),
    );
    await _download(tester);
    expect(find.text('JS源'), findsOneWidget);

    await tester.tap(find.text('只看不需要 JS 的'));
    await tester.pumpAndSettle();
    expect(find.text('JS源'), findsNothing);
    expect(find.text('普通'), findsOneWidget);
  });

  testWidgets('全选 / 清空：只改集合，底部计数跟着走', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final all = [for (var i = 0; i < 5; i++) _src('源$i')];
    await _pump(tester, store: store, service: _FakeIndexService(_result(all)));
    await _download(tester);

    expect(find.textContaining('已选 0'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 5 / 可导入剩余 200'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 0'), findsOneWidget);
  });

  testWidgets('超过上限：导入按钮禁用 + 明说上限是 200', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final all = [for (var i = 0; i < 201; i++) _src('源$i')];
    await _pump(tester, store: store, service: _FakeIndexService(_result(all)));
    await _download(tester);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    expect(find.text('已选 201 / 可导入剩余 200'), findsOneWidget);
    expect(find.textContaining('书源上限 200 个'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '导入'),
    );
    expect(button.onPressed, isNull, reason: '超额时不该让用户点得下去');
  });

  testWidgets('导入：调 upsertAll 落库，并把条数 pop 回上一页', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final all = [_src('甲'), _src('乙')];
    int? popped;
    await _openPickerViaPush(
      tester,
      store: store,
      service: _FakeIndexService(_result(all)),
      onResult: (value) => popped = value,
    );
    await _download(tester);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect((await store.getAll()).map((s) => s.name), ['甲', '乙']);
    expect(popped, 2);
    expect(find.byType(BookSourcePickerPage), findsNothing);
  });

  testWidgets('下载的链接写回 store（整份替换：删掉的行不再留着）', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([
      'https://old.example/keep.json',
      'https://old.example/drop.json',
    ]);
    final service = _FakeIndexService(_result([_src('甲')]));
    await _pump(tester, store: store, service: service);

    // 默认填的是 store 里那两行；改成一行再下载
    await tester.enterText(find.byType(TextField).first, _kLink);
    await _download(tester);

    expect(service.lastUrls, [_kLink]);
    expect(await store.getIndexUrls(), [_kLink]);
  });

  testWidgets('汇总行：几个源、几个需 JS、哪个链接失败了', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    final js = _src('JS源');
    await _pump(
      tester,
      store: store,
      service: _FakeIndexService(
        _result(
          [_src('甲'), _src('乙'), js],
          jsKeys: {js.key},
          outcomes: const [
            IndexUrlOutcome(
              url: 'https://index.example/bad.json',
              status: IndexUrlStatus.failed,
              message: '响应超时（15 秒）',
            ),
          ],
        ),
      ),
    );
    await _download(tester);

    expect(find.textContaining('共 3 个源'), findsOneWidget);
    expect(find.textContaining('1 个需 JS'), findsOneWidget);
    expect(find.textContaining('失败 1 个：响应超时'), findsOneWidget);
    // 失败链接单独一行，带上文件名（完整 URL 太长，只留最后一段）
    expect(find.textContaining('bad.json'), findsOneWidget);
  });

  testWidgets('链接框为空时点下载：只提示，不发请求', (tester) async {
    final store = BookSourceStore();
    final service = _FakeIndexService(_result([_src('甲')]));
    await _pump(tester, store: store, service: service);

    await _download(tester);

    expect(find.textContaining('先填至少一个'), findsOneWidget);
    expect(service.calls, 0);
  });

  testWidgets('底部按钮给系统导航栏让位（viewPadding.bottom）', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);

    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    await _pump(
      tester,
      store: store,
      service: _FakeIndexService(_result([for (var i = 0; i < 20; i++) _src('源$i')])),
    );
    await _download(tester);

    final button = tester.getRect(find.widgetWithText(FilledButton, '导入'));
    // 640 - 24（导航栏）= 616：按钮底边必须在上方，否则会被系统栏压住
    expect(button.bottom, lessThanOrEqualTo(616.0));
    // 也不能因为让位把按钮挤出屏幕
    expect(button.top, greaterThan(0));
  });

  // 「全选 / 清空」曾经排在筛选开关的 `Wrap` 里，411dp 下总宽装不下，
  // 「清空」被甩到下一行孤立成一行灰字。现在它们单独一行：两种常见手机
  // 宽度下都必须同一行（文字 dy 相等），且不能有溢出异常。
  for (final width in <double>[360, 411]) {
    testWidgets('全选 / 清空 在 ${width.toInt()}dp 下同一行且不溢出', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = BookSourceStore();
      await store.saveIndexUrls([_kLink]);
      await _pump(
        tester,
        store: store,
        service: _FakeIndexService(
          _result([for (var i = 0; i < 20; i++) _src('源$i')]),
        ),
      );
      await _download(tester);

      final selectAll = tester.getTopLeft(find.text('全选'));
      final clear = tester.getTopLeft(find.text('清空'));
      expect(clear.dy, selectAll.dy, reason: '两个按钮必须在同一行');
      // 都还在屏幕内（右侧留出页面边距，不被裁掉）
      expect(tester.getRect(find.text('清空')).right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('名字带换行 / 零宽字符：模型清洗成单行，列表按单行渲染', (tester) async {
    final store = BookSourceStore();
    await store.saveIndexUrls([_kLink]);
    await _pump(
      tester,
      store: store,
      service: _FakeIndexService(
        _result([_srcFromJson('缩书\u200B文学\n网')]),
      ),
    );
    await _download(tester);

    // 名称在模型读入口就被压成单行（零宽字符被删、换行变空格）
    expect(find.text('缩书文学 网'), findsOneWidget);
    final title = tester.widget<Text>(find.text('缩书文学 网'));
    expect(title.maxLines, 1);
    expect(title.softWrap, isFalse);
    expect(title.overflow, TextOverflow.ellipsis);
  });
}
