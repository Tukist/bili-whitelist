// 首页合集卡「块化 + 更新时间角标 + 观看进度」测试（P3）。
//
// 覆盖：
// - 合集卡底板走 AppBlock(AppBlockVariant.collectionCard)（块化规格）；
// - 既有文案锚点逐字保留：'N 个视频' / '收藏夹' / '我的 B 站收藏'；
// - 更新时间角标：pubdate → 「N 天前更新」；addedAt 兜底 → 「N 天前加入」；
//   取不到时间 → 不显示角标；
// - 观看进度：底部 3px 细条（kCollectionProgressBarKey；total == 0 时不存在）
//   + 副信息行「已看 X/Y」（watched == 0 也显示，明说「没看过」）。
//
// 卡片是页面私有 widget，所以走 PlaylistPage 整页渲染；统计走
// HistoryStore 的真实读取路径（shared_preferences mock），不触网、不碰原生插件。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/collection_stats.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';

/// 假同步服务：返回固定数据，不触发任何原生插件/网络。
class _FakeSyncService extends WhitelistSyncService {
  final WhitelistData data;

  _FakeSyncService(this.data) : super(dio: Dio());

  @override
  Future<SyncResult> sync() async => SyncResult(
    data: data,
    sourceName: 'fake',
    fetchedAt: DateTime(2026, 1, 1),
    fromNetwork: false,
  );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

WhitelistVideo _video(
  String bvid, {
  String collection = '',
  String addedAt = '',
  int parts = 1,
  int? pubdate,
}) => WhitelistVideo(
  bvid: bvid,
  cid: 100,
  title: '视频 $bvid',
  cover: '',
  duration: 90,
  upName: 'UP主',
  addedAt: addedAt,
  collection: collection,
  pubdate: pubdate,
  // parts <= 1 → pages 为 null（单 P 视频，pageCount = 1）
  pages: parts <= 1
      ? null
      : [
          for (var i = 0; i < parts; i++)
            PageInfo(cid: 100 + i, part: 'P${i + 1}', duration: 30),
        ],
);

WhitelistData _data(
  List<WhitelistVideo> videos, {
  List<String> collectionNames = const [],
}) => WhitelistData(
  version: 4,
  updatedAt: '2026-08-20T00:00:00Z',
  videos: videos,
  collections: [
    for (final n in collectionNames)
      CollectionInfo(name: n, createdAt: '2026-08-01T00:00:00Z'),
  ],
);

/// 一条「已看」历史（表格结构 = HistoryStore 真实落盘格式）。
HistoryEntry _watched(String bvid, int pageIndex) => HistoryEntry(
  bvid: bvid,
  pageIndex: pageIndex,
  cid: 100 + pageIndex,
  title: '视频 $bvid',
  cover: '',
  upName: 'UP主',
  durationMs: 30000,
  positionMs: 1000,
  watchedAt: DateTime(2026, 9, 1, 12, 0, 0),
);

/// 预置历史（必须在 pump 之前调用：页面加载完数据就会去读这张表）。
void _seedHistory(List<HistoryEntry> entries) {
  SharedPreferences.setMockInitialValues({
    'history_store:entries': jsonEncode([for (final e in entries) e.toJson()]),
  });
}

/// 注入假数据并 pump 首页（统计是异步加载的，多 pump 两次等它上屏）。
Future<void> _pumpHome(WidgetTester tester, WhitelistData data) async {
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(
    MaterialApp(
      // 注入登录页替身：测试环境没有 WebView 原生通道，真推登录页会 assert
      home: PlaylistPage(openLogin: (context, {banner}) async {}),
    ),
  );
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump(); // 统计异步加载完成 → 角标 / 进度条上屏
  await tester.pump();
}

/// 定位「包含 [inside] 文案的那张卡」的块底板。
Finder _cardBlockOf(Finder inside) =>
    find.ancestor(of: inside, matching: find.byType(AppBlock));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('合集卡更新时间角标文案（纯函数，固定 now）', () {
    final now = DateTime(2026, 9, 10, 12, 0, 0);

    test('pubdate 口径 → 「N 天前更新」', () {
      expect(
        collectionBadgeText(
          CollectionStat(
            watched: 3,
            total: 12,
            updatedAt: now.subtract(const Duration(days: 3)),
            fromPubdate: true,
          ),
          now: now,
        ),
        '3 天前更新',
      );
    });

    test('addedAt 兜底口径 → 「N 天前加入」（不谎称「更新」）', () {
      expect(
        collectionBadgeText(
          CollectionStat(
            watched: 0,
            total: 1,
            updatedAt: now.subtract(const Duration(days: 3)),
            // fromPubdate 默认 false = 只有加入时间可兜底
          ),
          now: now,
        ),
        '3 天前加入',
      );
    });

    test('取不到更新时间（updatedAt == null / 无统计）→ 不显示角标', () {
      expect(
        collectionBadgeText(const CollectionStat(watched: 1, total: 1), now: now),
        isNull,
      );
      expect(collectionBadgeText(null, now: now), isNull);
    });
  });

  group('合集卡（块化 + 角标 + 观看进度）', () {
    testWidgets('底板块化、既有文案保留、角标与进度按统计上屏', (tester) async {
      final now = DateTime.now();
      // 动画合集：12 集里看过 3 集（P1/P2/P3）
      _seedHistory([
        _watched('BV1', 0),
        _watched('BV1', 1),
        _watched('BV1', 2),
      ]);
      await _pumpHome(
        tester,
        _data(
          [
            _video(
              'BV1',
              collection: '动画',
              parts: 12,
              // 3 天前发布（pubdate = Unix 秒）
              pubdate: now
                      .subtract(const Duration(days: 3))
                      .millisecondsSinceEpoch ~/
                  1000,
            ),
            // 未分类视频：没有 pubdate，只有 5 天前的加入时间
            _video(
              'BV2',
              addedAt: now.subtract(const Duration(days: 5)).toIso8601String(),
            ),
          ],
          collectionNames: ['动画', '空合集'],
        ),
      );

      // 1) 块化：底板 = AppBlock(collectionCard)
      expect(
        tester.widget<AppBlock>(_cardBlockOf(find.text('动画'))).variant,
        AppBlockVariant.collectionCard,
      );

      // 2) 既有文案锚点逐字保留（'N 个视频' 数的是视频数，不是集数）
      expect(find.text('动画'), findsOneWidget);
      expect(find.text('空合集'), findsOneWidget);
      expect(find.text('未分类'), findsOneWidget);
      expect(find.text('1 个视频'), findsNWidgets(2)); // 动画 + 未分类
      expect(find.text('0 个视频'), findsOneWidget); // 空合集

      // 3) 角标：pubdate → 「N 天前更新」；addedAt 兜底 → 「N 天前加入」
      expect(find.text('3 天前更新'), findsOneWidget);
      expect(find.text('5 天前加入'), findsOneWidget);

      // 4) 进度：底部细条 + 副信息行文字（未看过也明说「已看 0/N」）
      expect(find.text('已看 3/12'), findsOneWidget);
      expect(find.text('已看 0/1'), findsOneWidget);
      // 有集的卡片才画进度条：动画(12) + 未分类(1)，空合集(0 集)没有
      expect(find.byKey(kCollectionProgressBarKey), findsNWidgets(2));

      // 5) 0 集的空合集卡：既没有进度条，也没有更新时间角标
      final emptyCard = _cardBlockOf(find.text('0 个视频'));
      expect(
        find.descendant(
          of: emptyCard,
          matching: find.byKey(kCollectionProgressBarKey),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: emptyCard, matching: find.textContaining('更新')),
        findsNothing,
      );
      expect(
        find.descendant(of: emptyCard, matching: find.textContaining('加入')),
        findsNothing,
      );
    });

    testWidgets('取不到更新时间（addedAt 脏）→ 不显示角标，进度照常', (tester) async {
      await _pumpHome(tester, _data([_video('BV1', addedAt: '')]));

      final card = _cardBlockOf(find.text('未分类'));
      expect(find.text('已看 0/1'), findsOneWidget); // 没看过也显示
      expect(find.byKey(kCollectionProgressBarKey), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.textContaining('加入')),
        findsNothing,
      );
      expect(
        find.descendant(of: card, matching: find.textContaining('更新')),
        findsNothing,
      );
    });

    testWidgets('固定「收藏夹」卡也块化，两条文案逐字保留', (tester) async {
      await _pumpHome(tester, _data([_video('BV1', addedAt: '')]));

      expect(find.text('收藏夹'), findsOneWidget);
      expect(find.text('我的 B 站收藏'), findsOneWidget);
      expect(
        tester.widget<AppBlock>(_cardBlockOf(find.text('收藏夹'))).variant,
        AppBlockVariant.collectionCard,
      );
    });

    testWidgets('切走再切回首页 tab → 重算统计（刚看完的集数立刻反映）', (tester) async {
      await _pumpHome(
        tester,
        _data(
          [_video('BV1', collection: '动画', parts: 12)],
          collectionNames: const ['动画'],
        ),
      );
      expect(find.text('已看 0/12'), findsOneWidget);

      // 模拟「刚看完 P1」：历史表多一条，然后切走 → 切回首页
      await HistoryStore.instance.addOrUpdate(_watched('BV1', 0));
      await tester.tap(find.text('UP 主'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('合集'));
      await tester.pumpAndSettle();
      await tester.pump(); // _reloadTab(0) 触发的统计重算是异步的

      expect(find.text('已看 1/12'), findsOneWidget);
    });

    testWidgets('窄屏 + 最长角标文案（绝对日期）也不撑破卡片行', (tester) async {
      // 320dp 宽（@3x）：角标最长形态 = 一年以上的绝对日期「2023-03-15更新」，
      // 再配一个超长合集名，检查名称行不会 overflow（角标不是弹性子项）。
      tester.view.physicalSize = const Size(960, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      const longName = '一个特别特别长的合集名称用来挤压名称行的剩余空间';
      await _pumpHome(
        tester,
        _data(
          [
            _video(
              'BV1',
              collection: longName,
              parts: 12,
              pubdate: DateTime(2023, 3, 15, 12).millisecondsSinceEpoch ~/ 1000,
            ),
          ],
          collectionNames: const [longName],
        ),
      );

      expect(find.text('2023-03-15更新'), findsOneWidget);
      expect(find.text('已看 0/12'), findsOneWidget);
      expect(tester.takeException(), isNull); // 不给 RenderFlex overflow 留口子
    });
  });
}
