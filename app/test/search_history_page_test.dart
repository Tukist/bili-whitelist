// 搜索页「搜索历史」面板 widget 测试（v2.17.16+）。
// - 注入假白名单同步服务（[SearchPage.syncService]）与独立历史 store
//   （[SearchPage.historyStore]），不触发真实网络/原生插件
// - 验证：空历史隐藏面板 / 有历史渲染标题+词 / 点历史词填入并搜索 /
//   单删 / 清空 / 切到「我的白名单」Tab 不挡列表（面板隐藏）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/services/search_history_store.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 假 B 站接口：三个搜索方法返回空结果，不触发任何网络/原生插件。
class _FakeApi extends BiliApi {
  _FakeApi() : super();

  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async =>
      const SearchPageResult(results: [], totalCount: 0, hasMore: false);

  @override
  Future<MediaSearchPageResult> searchMedia(
    String keyword, {
    required String searchType,
    int page = 1,
  }) async =>
      const MediaSearchPageResult(results: [], totalCount: 0, hasMore: false);

  @override
  Future<SearchUpownerResult> searchUpowner(
    String keyword, {
    int page = 1,
  }) async =>
      const SearchUpownerResult(upowners: [], totalCount: 0, hasMore: false);
}

/// 假同步服务：返回固定白名单（空视频列表），不触发原生插件/网络。
class _FakeSyncService extends WhitelistSyncService {
  _FakeSyncService() : super();

  @override
  Future<SyncResult> sync() async => SyncResult(
    data: const WhitelistData(
      version: WhitelistData.currentVersion,
      updatedAt: '2026-09-09T00:00:00Z',
      videos: [],
    ),
    sourceName: 'fake',
    fetchedAt: DateTime(2026, 9, 9),
    fromNetwork: false,
  );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// pump 搜索页（Tab0 = 全部 B 站）。
Future<void> _pump(WidgetTester tester, SearchHistoryStore store) async {
  await tester.pumpWidget(MaterialApp(
    home: SearchPage(
      syncService: _FakeSyncService(),
      historyStore: store,
      api: _FakeApi(),
    ),
  ));
  // 等白名单同步 + 历史异步加载完成
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('搜索历史面板（v2.17.16）', () {
    testWidgets('空历史：不显示「搜索历史」区（Tab0 默认空态）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await _pump(tester, store);
      expect(find.text('搜索历史'), findsNothing);
    });

    testWidgets('有历史且输入框为空：显示标题 + 历史词 + 清空入口', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await store.add('火柴人');
      await store.add('白名单点播');
      await _pump(tester, store);

      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('火柴人'), findsOneWidget);
      expect(find.text('白名单点播'), findsOneWidget);
      expect(find.byKey(const ValueKey('search-history-clear')), findsOneWidget);
    });

    testWidgets('输入文字后面板隐藏；清空输入框后面板回来', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await store.add('旧词');
      await _pump(tester, store);
      expect(find.text('搜索历史'), findsOneWidget);

      // 输入文字 → 面板隐藏（进入搜索状态）
      await tester.enterText(find.byType(TextField), '新词');
      await tester.pump();
      expect(find.text('搜索历史'), findsNothing);

      // 清空输入框 → 面板恢复（历史词还在）
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('旧词'), findsOneWidget);
    });

    testWidgets('点历史词：填入输入框、立即搜索（输入框非空）、该词仍在历史顶部',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await store.add('旧词');
      await store.add('要点的词'); // 顶部
      await _pump(tester, store);

      await tester.tap(find.text('要点的词'));
      // 填入输入框并触发搜索（Tab0 视频搜索会发真实请求，测试环境 400 降级，
      // 这里只校验输入框与历史面板状态，不等网络 settle）
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '要点的词');
      expect(find.text('搜索历史'), findsNothing); // 面板随输入消失
      expect(await store.getAll(), ['要点的词', '旧词']); // 置顶保持
    });

    testWidgets('键盘搜索键提交：关键词记入历史', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await _pump(tester, store);
      expect(find.text('搜索历史'), findsNothing); // 空历史

      await tester.enterText(find.byType(TextField), '键盘提交的词');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(await store.getAll(), ['键盘提交的词']);
    });

    testWidgets('单删一条（行尾 X）：该词消失、其余保留、store 同步', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await store.add('词A');
      await store.add('词B');
      await _pump(tester, store);

      await tester.tap(find.byKey(const ValueKey('search-history-remove-词A')));
      await tester.pumpAndSettle();
      expect(find.text('词A'), findsNothing);
      expect(find.text('词B'), findsOneWidget);
      expect(await store.getAll(), ['词B']);
    });

    testWidgets('清空：面板消失并回到默认空态', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await store.add('词A');
      await store.add('词B');
      await _pump(tester, store);

      await tester.tap(find.byKey(const ValueKey('search-history-clear')));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsNothing);
      expect(find.text('词A'), findsNothing);
      expect(await store.getAll(), isEmpty);
    });

    testWidgets('切到「我的白名单」Tab：历史面板隐藏（不挡本地列表）',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = SearchHistoryStore();
      await store.add('历史词');
      await _pump(tester, store);
      expect(find.text('搜索历史'), findsOneWidget);

      // 点「我的白名单」Tab → 面板消失（显示白名单列表/空态）
      await tester.tap(find.text('我的白名单'));
      await tester.pumpAndSettle();
      expect(find.text('搜索历史'), findsNothing);
    });
  });
}
