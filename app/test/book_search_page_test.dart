// 搜索页测试（R3）。
//
// 用假引擎 + 假书源存储：验「分组 / 合并切换」「空书源提示」「需要 JS 的源
// 被跳过」「点条目进详情页」。导航用 NavigatorObserver 观察，不依赖真网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_detail_page.dart';
import 'package:bili_whitelist_app/pages/book_search_page.dart';
import 'package:bili_whitelist_app/services/book_rule/engine_holder.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

/// 只返回内存列表的书源存储（不碰 prefs）。
class _FakeSourceStore extends BookSourceStore {
  _FakeSourceStore(this.sources);

  final List<BookSource> sources;

  @override
  Future<List<BookSource>> getAll() async => sources;
}

/// 记录 push 过的路由（断言「点了会进详情页」）。
class _RouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

BookSource _source(String name, String host, {String nameRule = '.title'}) =>
    BookSource(
      name: name,
      baseUrl: 'https://$host',
      search: SearchRule(
        url: '/search?q={{key}}',
        list: '.book',
        name: nameRule,
        author: '.author',
        detailUrl: 'a@href',
      ),
      toc: const TocRule(),
      content: const ContentRule(text: '#content'),
    );

/// 假引擎：A / B 两个源都搜到同一本书（合并视图应显示「2 个源」）。
FakeRuleEngine _engine() => FakeRuleEngine(
      onFetch: (url) async {
        if (url.contains('a.example')) return 'A';
        if (url.contains('b.example')) return 'B';
        return 'EMPTY';
      },
      onQueryMap: (html, list, fields) async {
        if (html == 'A') {
          return {
            'name': ['斗罗大陆'],
            'author': ['唐家三少'],
            'detailUrl': ['https://a.example/book/1'],
          };
        }
        if (html == 'B') {
          return {
            'name': ['斗罗大陆'],
            'author': ['唐家三少'],
            'detailUrl': ['https://b.example/book/1'],
          };
        }
        return {};
      },
    );

Future<void> _pump(
  WidgetTester tester, {
  required BookSourceStore store,
  required RuleEngineHolder holder,
  _RouteObserver? observer,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookSearchPage(sourceStore: store, holder: holder),
      navigatorObservers: [if (observer != null) observer],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('分组视图 → 合并视图；需要 JS 的源被跳过并说明', (tester) async {
    final holder = RuleEngineHolder.withEngine(_engine());
    await _pump(
      tester,
      store: _FakeSourceStore([
        _source('源A', 'a.example'),
        _source('源B', 'b.example'),
        // 需要 JS：不该发请求，只应在「已跳过」里出现
        _source('源C', 'c.example', nameRule: '<js>x</js>'),
      ]),
      holder: holder,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    // 分组视图：每个源一个标题
    expect(find.text('源A · 1 条'), findsOneWidget);
    expect(find.text('源B · 1 条'), findsOneWidget);
    // JS 源没发请求，但用户能看到「被跳过了」
    expect(find.textContaining('已跳过 1 个需要 JS 规则的书源'), findsOneWidget);
    final engine = holder.engine as FakeRuleEngine;
    expect(engine.fetchedUrls.any((u) => u.contains('c.example')), isFalse);

    // 切合并视图：同书合并成一条，右侧标「2 个源」
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    expect(find.text('2 个源'), findsOneWidget);
    expect(find.text('斗罗大陆'), findsOneWidget);
  });

  testWidgets('一个书源都没有 → 空态提示 + 「去导入书源」', (tester) async {
    await _pump(
      tester,
      store: _FakeSourceStore(const []),
      holder: RuleEngineHolder.withEngine(FakeRuleEngine()),
    );

    expect(find.text('还没有书源'), findsOneWidget);
    expect(find.text('去导入书源'), findsOneWidget);
  });

  testWidgets('点搜索结果 → 进详情页', (tester) async {
    final observer = _RouteObserver();
    final holder = RuleEngineHolder.withEngine(_engine());
    await _pump(
      tester,
      store: _FakeSourceStore([_source('源A', 'a.example')]),
      holder: holder,
      observer: observer,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('斗罗大陆'));
    await tester.pumpAndSettle();

    expect(observer.pushed, isNotEmpty);
    expect(find.byType(BookDetailPage), findsOneWidget);
  });

  testWidgets('空关键词不发搜索、不崩', (tester) async {
    final holder = RuleEngineHolder.withEngine(_engine());
    await _pump(
      tester,
      store: _FakeSourceStore([_source('源A', 'a.example')]),
      holder: holder,
    );

    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect((holder.engine as FakeRuleEngine).fetchedUrls, isEmpty);
    expect(find.text('搜一本书'), findsOneWidget);
  });
}
