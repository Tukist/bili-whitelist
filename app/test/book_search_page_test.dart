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
import 'package:bili_whitelist_app/services/book_source_health_service.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

/// 只返回内存列表的书源存储（不碰 prefs）。
class _FakeSourceStore extends BookSourceStore {
  _FakeSourceStore(this.sources);

  final List<BookSource> sources;

  @override
  Future<List<BookSource>> getAll() async => sources;
}

/// 假检测结果（本页只读 `reader:source_health`，不需要引擎）。
class _FakeHealth extends BookSourceHealthService {
  _FakeHealth(this.store);

  final Map<String, SourceHealth> store;

  @override
  Future<Map<String, SourceHealth>> loadAll() async => store;
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

BookSource _source(
  String name,
  String host, {
  String nameRule = '.title',
  Map<String, dynamic>? raw,
}) =>
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
      raw: raw,
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
  BookSourceHealthService? health,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookSearchPage(
        sourceStore: store,
        holder: holder,
        healthService: health,
      ),
      navigatorObservers: [if (observer != null) observer],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('只在发现页用 JS 的源照常搜索（旧口径会整源跳过）', (tester) async {
    final holder = RuleEngineHolder.withEngine(_engine());
    await _pump(
      tester,
      store: _FakeSourceStore([
        _source('源A', 'a.example'),
        // 设计契约变更（I1）：exploreUrl 本版根本不执行，不该把源判死
        _source('源D', 'd.example', raw: {
          'exploreUrl': '@js:java.ajax("/explore")',
          'loginUrl': 'https://d.example/login?<js>x</js>',
        }),
      ]),
      holder: holder,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    final engine = holder.engine as FakeRuleEngine;
    expect(engine.fetchedUrls.any((u) => u.contains('d.example')), isTrue);
    expect(find.textContaining('已跳过'), findsNothing);
    expect(find.textContaining('源D · '), findsOneWidget);
  });

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

  // ==================== F2：健康状态 / 空结果文案 / 跳过源弹层 ====================

  /// 一个只会「返回 0 条」的引擎（页面结构与规则不符）。
  FakeRuleEngine emptyEngine() => FakeRuleEngine(
        onFetch: (url) async => '<html><body>no result</body></html>',
        onQueryMap: (html, list, fields) async => const {},
      );

  /// 一个「站点返回 403」的引擎。
  FakeRuleEngine blockedEngine() => FakeRuleEngine(
        onFetch: (url) async => throw const RuleEngineException(
          RuleErrorKind.network,
          '站点返回 403：https://blocked.example/search?q=x',
          statusCode: 403,
        ),
      );

  testWidgets('分组标题右侧显示该源上次检测的健康状态', (tester) async {
    final holder = RuleEngineHolder.withEngine(_engine());
    final health = _FakeHealth({
      '源a': SourceHealth(
        sourceKey: '源a',
        status: SourceHealthStatus.ok,
        at: DateTime(2026, 11, 23),
        count: 12,
      ),
    });
    await _pump(
      tester,
      store: _FakeSourceStore([_source('源A', 'a.example')]),
      holder: holder,
      health: health,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('检测：可用 12 条'), findsOneWidget);
  });

  testWidgets('某源 0 条且上次检测被拦 → 小字说「这个源可能已失效」', (tester) async {
    // 源A 有结果（否则整页走空态，看不到分组），源B 0 条且上次被拦
    final holder = RuleEngineHolder.withEngine(FakeRuleEngine(
      onFetch: (url) async => url.contains('a.example') ? 'A' : 'B',
      onQueryMap: (html, list, fields) async {
        if (html == 'A') {
          return {
            'name': ['斗罗大陆'],
            'author': ['唐家三少'],
            'detailUrl': ['https://a.example/book/1'],
          };
        }
        return const {};
      },
    ));
    final health = _FakeHealth({
      '源b': SourceHealth(
        sourceKey: '源b',
        status: SourceHealthStatus.blocked,
        at: DateTime(2026, 11, 23),
        message: '站点返回 403',
      ),
    });
    await _pump(
      tester,
      store: _FakeSourceStore([
        _source('源A', 'a.example'),
        _source('源B', 'b.example'),
      ]),
      holder: holder,
      health: health,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.textContaining('这个源可能已失效'), findsOneWidget);
    expect(find.textContaining('上次检测：被拦'), findsOneWidget);
  });

  testWidgets('所有源都没结果 → 「没有找到」，而不是「都失败了」', (tester) async {
    final holder = RuleEngineHolder.withEngine(emptyEngine());
    await _pump(
      tester,
      store: _FakeSourceStore([
        _source('源A', 'a.example'),
        _source('源B', 'b.example'),
      ]),
      holder: holder,
    );

    await tester.enterText(find.byType(TextField), '不存在');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('没有找到「不存在」'), findsOneWidget);
    expect(find.text('所有书源都失败了'), findsNothing);
    expect(find.textContaining('2 个源没搜到'), findsOneWidget);
  });

  testWidgets('所有源都失败 → 「所有书源都失败了」+ 原因归类汇总', (tester) async {
    final holder = RuleEngineHolder.withEngine(blockedEngine());
    await _pump(
      tester,
      store: _FakeSourceStore([
        _source('源A', 'a.example'),
        _source('源B', 'b.example'),
      ]),
      holder: holder,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('所有书源都失败了'), findsOneWidget);
    expect(find.text('没有找到「斗罗」'), findsNothing);
    expect(find.textContaining('2 个源被拦'), findsOneWidget);
  });

  testWidgets('「已跳过 N 个需 JS 的源」可点开看名单（最多 20 个 + 还有 N 个）',
      (tester) async {
    final holder = RuleEngineHolder.withEngine(_engine());
    final jsSources = [
      for (var i = 1; i <= 25; i++) _source('JS源$i', 'js$i.example', nameRule: '<js>x</js>'),
    ];
    await _pump(
      tester,
      store: _FakeSourceStore([_source('源A', 'a.example'), ...jsSources]),
      holder: holder,
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已跳过 25 个需要 JS 规则的书源'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '查看'));
    await tester.pumpAndSettle();

    expect(find.text('已跳过 25 个源'), findsOneWidget);
    expect(find.text('· JS源1'), findsOneWidget);
    expect(find.text('· JS源20'), findsOneWidget);
    expect(find.text('· JS源21'), findsNothing); // 只列前 20 个
    expect(find.text('还有 5 个'), findsOneWidget);
  });

  testWidgets('GBK 源：分组标题下有一行「编码：GBK」，条目照常显示', (tester) async {
    final engine = _GbkEngine(
      onFetch: (_) async => 'A',
      onQueryMap: (html, list, fields) async => {
        'name': ['斗罗大陆'],
        'detailUrl': ['https://a.example/book/1'],
      },
    );
    await _pump(
      tester,
      store: _FakeSourceStore([_source('源A', 'a.example')]),
      holder: RuleEngineHolder.withEngine(engine),
    );

    await tester.enterText(find.byType(TextField), '斗罗');
    await tester.tap(find.widgetWithText(FilledButton, '搜索'));
    await tester.pumpAndSettle();

    expect(find.text('源A · 1 条'), findsOneWidget);
    expect(find.text('编码：GBK'), findsOneWidget);
    expect(find.text('斗罗大陆'), findsOneWidget);
  });
}

/// 会「报 GBK」的假引擎：只把 `lastDecodeEncoding` 摆好，求值仍走注入回调。
///
/// 为什么要它：分组标题下那行编码小字读的是 `BookSearchGroup.decodeNote`，
/// 而它由搜索服务从引擎的解码事实里抄出来 —— 默认的 [FakeRuleEngine] 永远
/// 不设这个字段，这条路就测不到。
class _GbkEngine extends FakeRuleEngine {
  _GbkEngine({super.onFetch, super.onQueryMap});

  @override
  Future<String> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String charset = 'utf-8',
  }) async {
    fetchedUrls.add(url);
    lastDecodeEncoding = 'gbk';
    if (onFetch != null) return onFetch!(url);
    return '<html></html>';
  }
}
