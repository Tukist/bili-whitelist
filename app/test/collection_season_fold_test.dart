// 番剧「整季折叠成一张卡」（v2.41.0+）：
// 用户原话「不要让收藏一个剧或者番的时候需要把每集都收藏。现在比如说在
// アニメ合集里面一个 43 集的高达…」——v2.37.0 只修了"上下集乱跳"，"43 集占
// 43 行"这半边欠着。
//
// 覆盖：
// - 纯函数 [buildCollectionListRows]：≥2 集折一张、**只 1 集逐集平铺**、
//   不同季互不折、卡的位置 = 该季首集的原有位置、普通视频不受影响、
//   展开态 = 季头 + 逐集平铺（组内正序）、OVA 借季名归位；
// - 已看口径 [watchedVideoCount] / [isVideoWatched]：与 collection_stats
//   同源（越界分 P 不算、不在这一季的历史不算）；
// - 合集页渲染：1 张整季卡（集数 / 封面 / 「已看 X/N」/「整季」角标）；
// - 点整季卡 → 选集弹层 → 点第 k 集 → push 播放页且 `playlist` 恰为该季
//   正序、`playlistIndex == k`、label = 季名；
// - 左滑「展开」→ 逐集平铺（拖拽 / 多选 / 批量删除照旧）；左滑「收起」→ 回卡；
// - 多选模式下整季卡**整体勾选**（长按 = 进入多选并勾满这一季）；
// - **未分类页同样生效**（未分类不是 CollectionInfo，它就是空 collection）；
// - **折叠状态不落库**：全程断言 `saveAndRefresh` 收到的数据里没有任何
//   "折叠"字段（数据模型压根没有这个概念）。
//
// 测试环境：直接 pump [CollectionPage]（不经过首页），注入内存版 secure
// storage + 假 SharedPreferences（HistoryStore 读它）。
// **点选集不真的挂载播放页**：用 [NavigatorObserver] 拦下被 push 的
// `MaterialPageRoute`，直接问它的 `builder` 要那个 `PlayerPage` —— 断言的是
// 【传下去了什么】，而播放页自己怎么播已经由 player_playlist_switch_test 覆盖。
// 这样既不需要 mock 原生播放器，也不会让这条"折叠"用例被播放器的网络/动画
// 拖进来（一处失败看起来像两处坏）。
import 'dart:convert';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/collection_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/collection_stats.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/season_tile.dart';
import 'package:bili_whitelist_app/widgets/swipe_action_box.dart';
import 'package:bili_whitelist_app/widgets/video_tile.dart';

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

/// 番剧集：`季名 第N话`（与整季导入的标题结构一致）。
WhitelistVideo _ep(
  String season,
  int n,
  String bvid, {
  int? epId,
  String collection = 'アニメ',
  int order = 0,
  String cover = '',
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 900 + n,
      title: '$season 第$n话',
      cover: cover,
      duration: 120 + n,
      upName: '番剧官方',
      addedAt: '2026-08-01T00:00:00Z',
      collection: collection,
      order: order,
      epId: epId ?? (900000 + n),
    );

/// 普通视频（epId == null）：与折叠无关的那一半。
WhitelistVideo _plain(
  String title,
  String bvid, {
  String collection = 'アニメ',
  int order = 0,
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 500,
      title: title,
      cover: '',
      duration: 90,
      upName: '某UP主',
      addedAt: '2026-08-01T00:00:00Z',
      collection: collection,
      order: order,
    );

WhitelistData _dataWith(
  List<WhitelistVideo> videos, {
  List<String> collectionNames = const ['アニメ'],
}) => WhitelistData(
  version: 4,
  updatedAt: '2026-08-20T00:00:00Z',
  videos: videos,
  collections: [
    for (final n in collectionNames)
      CollectionInfo(name: n, createdAt: '2026-08-01T00:00:00Z'),
  ],
  upowners: const <Upowner>[],
);

// ---------------------------------------------------------------------------
// pump
// ---------------------------------------------------------------------------

/// 测试环境无网：封面 URL 必然 400 → `CoverImage` 的 `errorBuilder` 兜底。
/// 这条**异步**异常由框架记在案（不 drain 就会飘到后面的断言上当成失败），
/// 收掉它并确认就是这一条（不是别的异常被顺手吞了）。
void _drainImageError(WidgetTester tester) {
  final e = tester.takeException();
  if (e != null) expect(e, isA<NetworkImageLoadException>());
}

/// 点某条之后让在飞的请求/动画落地（显式 pump，不用 pumpAndSettle：播放页
/// 取流失败时可能停在加载态）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// 挂载合集页（[collection] 空串 = 未分类页）。
Future<void> _pumpCollection(
  WidgetTester tester, {
  required String collection,
  required WhitelistData data,
  void Function(WhitelistData next)? onSave,
  List<HistoryEntry> history = const [],
}) async {
  // MotionControl 是全局静态状态（关动效时 SwipeActionBox 一个 ticker 都不建）
  MotionControl.reset();
  SwipeActionBox.resetForTest();
  addTearDown(MotionControl.reset);
  addTearDown(SwipeActionBox.resetForTest);

  SharedPreferences.setMockInitialValues({
    if (history.isNotEmpty)
      'history_store:entries':
          jsonEncode([for (final h in history) h.toJson()]),
  });
  // 视口拉高：43 集那一类夹具在 800×600 下装不下，tap 点不到
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(600, 4000);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: CollectionPage(
        collectionName: collection,
        data: data,
        saveAndRefresh: (next) async => onSave?.call(next),
      ),
    ),
  );
  await tester.pump(); // 历史加载（假 prefs 同步返回）
  await tester.pump();
}

/// 左滑一张卡（-160px 一步越过 touch slop → 横向拖动识别器直接胜出）。
Future<void> _swipeLeft(WidgetTester tester, Finder card) async {
  final gesture = await tester.startGesture(tester.getCenter(card));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-160, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder _seasonCard(String seasonName) => find.byWidgetPredicate(
  (w) => w is SeasonTile && w.seasonName == seasonName,
);

/// 左滑整季卡 → 点「展开」/「收起」（[SwipeActionBox] 的既有手势语言）。
Future<void> _swipeAction(
  WidgetTester tester,
  String seasonName,
  String label,
) async {
  await _swipeLeft(tester, _seasonCard(seasonName));
  expect(find.text(label), findsOneWidget, reason: '左滑该露出「$label」块');
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// 长按（进入多选）。
Future<void> _longPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.up();
  await tester.pumpAndSettle();
}

HistoryEntry _watched(String bvid, {int pageIndex = 0}) => HistoryEntry(
  bvid: bvid,
  pageIndex: pageIndex,
  cid: 1,
  title: '已看',
  cover: '',
  upName: 'UP',
  durationMs: 1000,
  positionMs: 100,
  watchedAt: DateTime(2026, 8, 1),
);

void main() {
  // -------------------------------------------------------------------------
  // 纯函数：行折叠
  // -------------------------------------------------------------------------
  group('buildCollectionListRows：整季折叠的判定', () {
    test('同一季 ≥2 集 → 折成 1 行；组内正序、位置 = 首集的原有位置', () {
      // 展示序（order 升序）：普通1, 大臣1, 大臣2, 大臣3, 普通2
      final videos = [
        _plain('普通1', 'BVP1', order: 0),
        _ep('是，大臣 第一季', 1, 'BVD1', order: 1),
        _ep('是，大臣 第一季', 2, 'BVD2', order: 2),
        _ep('是，大臣 第一季', 3, 'BVD3', order: 3),
        _plain('普通2', 'BVP2', order: 4),
      ];
      final rows = buildCollectionListRows(videos);

      expect(rows, hasLength(3), reason: '3 集折成 1 行 → 5 行变 3 行');
      expect(rows[0], isA<CollectionVideoRow>());
      final season = rows[1] as CollectionSeasonRow;
      expect(season.key, '是，大臣 第一季');
      expect(season.episodes.map((e) => e.title).toList(), [
        '是，大臣 第一季 第1话',
        '是，大臣 第一季 第2话',
        '是，大臣 第一季 第3话',
      ]);
      expect(season.firstIndex, 1, reason: '卡的显示位置 = 该季首集原来的下标');
      expect(season.collapsed, isTrue);
      expect((rows[2] as CollectionVideoRow).video.title, '普通2');
    });

    test('同一季只有 1 集 → **逐集平铺**（与改动前一致，不折）', () {
      final videos = [
        _ep('孤独番', 1, 'BVONLY', order: 0),
        _plain('普通1', 'BVP1', order: 1),
      ];
      final rows = buildCollectionListRows(videos);

      expect(rows, hasLength(2));
      expect(rows.every((r) => r is CollectionVideoRow), isTrue,
          reason: '1 集的季原样平铺：换成一张内容一样的卡只是多一层点击');
      expect((rows[0] as CollectionVideoRow).video.bvid, 'BVONLY');
      expect(rows[0].anchor, 0);
      expect(rows[1].anchor, 1);
    });

    test('不同季互不折（各折各的，键 = 季名）', () {
      final videos = [
        _ep('高达', 1, 'BVG1', order: 0),
        _ep('高达', 2, 'BVG2', order: 1),
        _ep('芙莉莲', 1, 'BVF1', order: 2),
        _ep('芙莉莲', 2, 'BVF2', order: 3),
      ];
      final rows = buildCollectionListRows(videos);

      expect(rows, hasLength(2));
      expect((rows[0] as CollectionSeasonRow).key, '高达');
      expect((rows[1] as CollectionSeasonRow).key, '芙莉莲');
      expect((rows[0] as CollectionSeasonRow).episodes, hasLength(2));
      expect((rows[1] as CollectionSeasonRow).episodes, hasLength(2));
    });

    test('普通视频（epId == null）永远不折，位置/顺序原封不动', () {
      final videos = [
        _plain('标题里也有第1话 的普通视频', 'BVP1', order: 0),
        _plain('普通2', 'BVP2', order: 1),
      ];
      final rows = buildCollectionListRows(videos);

      expect(rows, hasLength(2));
      expect(rows.map((r) => r.anchor).toList(), [0, 1]);
      expect(
        rows.map((r) => (r as CollectionVideoRow).video.bvid).toList(),
        ['BVP1', 'BVP2'],
      );
    });

    test('展开态：季头保留（collapsed=false）+ 紧接着逐集平铺，且是组内正序', () {
      // 列表序故意是倒序（整季导入：order 恒 0 + added_at 递增的典型形态）
      final videos = [
        _ep('高达', 3, 'BVG3', order: 0),
        _ep('高达', 2, 'BVG2', order: 0),
        _ep('高达', 1, 'BVG1', order: 0),
        _plain('普通1', 'BVP1', order: 9),
      ];
      final rows = buildCollectionListRows(videos, expandedSeasons: {'高达'});

      expect(rows, hasLength(5), reason: '季头 1 行 + 3 集 + 普通 1 行');
      final header = rows[0] as CollectionSeasonRow;
      expect(header.collapsed, isFalse);
      expect(header.firstIndex, 0);
      expect(
        rows.sublist(1, 4).map((r) => (r as CollectionVideoRow).video.title),
        ['高达 第1话', '高达 第2话', '高达 第3话'],
        reason: '展开后按集号正序逐集平铺（不是列表里的倒序块）',
      );
      expect(rows[4].anchor, 3);
    });

    test('OVA（标题没有第N话）借同列表的季名归位，不单列一行', () {
      final videos = [
        _ep('某番', 1, 'BV1', order: 0),
        _ep('某番', 2, 'BV2', order: 1),
        // 14(OVA)：epId 有、标题没有 `第N话` → 靠'某番 '前缀归位
        WhitelistVideo(
          bvid: 'BVOVA',
          cid: 99,
          title: '某番 14(OVA)',
          cover: '',
          duration: 100,
          upName: 'UP',
          addedAt: '2026-08-01T00:00:00Z',
          collection: 'アニメ',
          order: 2,
          epId: 777,
        ),
      ];
      final rows = buildCollectionListRows(videos);

      expect(rows, hasLength(1));
      final season = rows.single as CollectionSeasonRow;
      expect(season.episodes, hasLength(3));
      expect(season.episodes.last.title, '某番 14(OVA)',
          reason: '没集号的排在最后（[sortedSeasonEpisodes] 的回退顺序）');
    });
  });

  // -------------------------------------------------------------------------
  // 纯函数：已看口径
  // -------------------------------------------------------------------------
  group('watchedVideoCount / isVideoWatched：与合集卡同一条口径', () {
    final eps = [
      _ep('某番', 1, 'BV1'),
      _ep('某番', 2, 'BV2'),
      _ep('某番', 3, 'BV3'),
    ];

    test('看过几集算几集；重复看只算一次', () {
      final history = [
        _watched('BV1'),
        _watched('BV1'),
        _watched('BV2'),
      ];
      expect(watchedVideoCount(eps, history), 2);
      expect(isVideoWatched(eps[0], history), isTrue);
      expect(isVideoWatched(eps[2], history), isFalse);
    });

    test('越界分 P 的历史不算（分 P 数变少后的陈旧记录）', () {
      expect(isVideoWatched(eps[0], [_watched('BV1', pageIndex: 5)]), isFalse);
      expect(watchedVideoCount(eps, [_watched('BV1', pageIndex: 5)]), 0);
    });

    test('不在这一季里的历史不算（合集里别的番的进度不能算到这一季头上）', () {
      expect(watchedVideoCount(eps, [_watched('BVOTHER')]), 0);
    });

    test('空列表 / 空历史 → 0', () {
      expect(watchedVideoCount(const [], const []), 0);
      expect(watchedVideoCount(eps, const []), 0);
    });
  });

  // -------------------------------------------------------------------------
  // 合集页渲染与交互
  // -------------------------------------------------------------------------
  group('合集页：整季卡（渲染）', () {
    testWidgets('同一季 ≥2 集 → 1 张整季卡：季名 / N 集 / 已看 X/N / 封面取第一集',
        (tester) async {
      final data = _dataWith([
        _ep('是，大臣 第一季', 1, 'BVD1', order: 0, cover: 'https://x/1.jpg'),
        _ep('是，大臣 第一季', 2, 'BVD2', order: 1, cover: 'https://x/2.jpg'),
        _ep('是，大臣 第一季', 3, 'BVD3', order: 2, cover: 'https://x/3.jpg'),
        _ep('是，大臣 第一季', 4, 'BVD4', order: 3, cover: 'https://x/4.jpg'),
      ]);
      await _pumpCollection(
        tester,
        collection: 'アニメ',
        data: data,
        history: [_watched('BVD1'), _watched('BVD3')],
      );

      expect(find.byType(SeasonTile), findsOneWidget);
      expect(find.byType(VideoTile), findsNothing,
          reason: '4 集全部折进去 → 一条逐集行都不剩');
      expect(find.text('是，大臣 第一季'), findsOneWidget);
      expect(find.text('4 集 · 已看 2/4'), findsOneWidget);
      expect(find.text('整季'), findsOneWidget);

      final card = tester.widget<SeasonTile>(find.byType(SeasonTile));
      expect(card.episodeCount, 4);
      expect(card.watchedCount, 2);
      expect(card.cover, 'https://x/1.jpg', reason: '封面取该季第一集（正序第 1 话）');
      _drainImageError(tester);
    });

    testWidgets('只 1 集的季 → 逐集平铺（与改动前一致：还是 VideoTile）',
        (tester) async {
      final data = _dataWith([
        _ep('孤独番', 1, 'BVONLY', order: 0),
        _plain('普通视频', 'BVP1', order: 1),
      ]);
      await _pumpCollection(tester, collection: 'アニメ', data: data);

      expect(find.byType(SeasonTile), findsNothing);
      expect(find.byType(VideoTile), findsNWidgets(2));
      expect(find.text('孤独番 第1话'), findsOneWidget);
      expect(find.text('普通视频'), findsOneWidget);
    });

    testWidgets('未分类页同样生效（未分类不是 CollectionInfo，只是空 collection）',
        (tester) async {
      final data = _dataWith([
        _ep('是，大臣 第一季', 1, 'BVD1', collection: '', order: 0),
        _ep('是，大臣 第一季', 2, 'BVD2', collection: '', order: 1),
        _ep('是，大臣 第一季', 3, 'BVD3', collection: '', order: 2),
        _ep('是，大臣 第一季', 4, 'BVD4', collection: '', order: 3),
      ]);
      await _pumpCollection(tester, collection: '', data: data);

      expect(find.text('未分类'), findsOneWidget);
      expect(find.byType(SeasonTile), findsOneWidget);
      expect(find.text('4 集 · 已看 0/4'), findsOneWidget);
      expect(find.byType(VideoTile), findsNothing);
    });

    testWidgets('整季卡不落库：折叠/展开都不触发一次保存', (tester) async {
      final data = _dataWith([
        _ep('某番', 1, 'BV1', order: 0),
        _ep('某番', 2, 'BV2', order: 1),
      ]);
      var saved = 0;
      await _pumpCollection(
        tester,
        collection: 'アニメ',
        data: data,
        onSave: (_) => saved++,
      );

      expect(find.byType(SeasonTile), findsOneWidget);
      await _swipeAction(tester, '某番', '展开');
      expect(find.byType(VideoTile), findsNWidgets(2));
      expect(saved, 0, reason: '折叠是视图：展开/收起一个字节都不写 Gist');
    });
  });

  group('合集页：点整季卡 → 选集 → 从那一集开始连播', () {
    testWidgets('点卡 → 弹层列出 N 集；点第 3 集 → playlist = 该季正序、下标 2',
        (tester) async {
      final data = _dataWith([
        _ep('高达', 1, 'BVG1', order: 0),
        _ep('高达', 2, 'BVG2', order: 1),
        _ep('高达', 3, 'BVG3', order: 2),
        _ep('高达', 4, 'BVG4', order: 3),
      ]);
      await _pumpCollection(
        tester,
        collection: 'アニメ',
        data: data,
        history: [_watched('BVG1')],
      );

      await tester.tap(_seasonCard('高达'));
      await tester.pumpAndSettle();

      // 弹层：季名 + 「共 N 集 · 点某一集从它开始连播」+ N 条集
      expect(find.text('共 4 集 · 点某一集从它开始连播'), findsOneWidget);
      for (var n = 1; n <= 4; n++) {
        expect(find.byKey(ValueKey('season-ep-BVG$n')), findsOneWidget);
      }
      // 已看标记：只有第 1 集有
      expect(find.text('已看'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('season-ep-BVG3')));
      await _settle(tester);

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(
        page.playlist!.videos.map((v) => v.title).toList(),
        ['高达 第1话', '高达 第2话', '高达 第3话', '高达 第4话'],
        reason: 'playlist 恰为该季正序（走的就是 sortedSeasonEpisodes）',
      );
      expect(page.playlistIndex, 2, reason: '被点的第 3 集在组内的下标');
      expect(page.playlist!.label, '高达', reason: 'label = 季名（不是「アニメ」）');
      expect(page.video.bvid, 'BVG3');
    });

    testWidgets('43 集整季：卡只说「43 集」，点开才列 43 条（不再占 43 行）',
        (tester) async {
      final data = _dataWith([
        for (var n = 1; n <= 43; n++)
          _ep('高达', n, 'BVGD${n.toString().padLeft(2, '0')}', order: n - 1),
      ]);
      await _pumpCollection(tester, collection: 'アニメ', data: data);

      expect(find.byType(SeasonTile), findsOneWidget);
      expect(find.byType(VideoTile), findsNothing);
      expect(find.text('43 集 · 已看 0/43'), findsOneWidget);

      await tester.tap(_seasonCard('高达'));
      await tester.pumpAndSettle();
      expect(find.text('共 43 集 · 点某一集从它开始连播'), findsOneWidget);

      // 43 条在「70% 屏高」的弹层里装不下 → 弹层自己可滚动（这正是限高的
      // 目的）。滚到底点最后一集，验"点第 k 集 = playlist[k]"对末集也成立。
      final lastTile = find.byKey(const ValueKey('season-ep-BVGD43'));
      await tester.scrollUntilVisible(
        lastTile,
        400,
        scrollable: find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(lastTile);
      await _settle(tester);
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.playlist!.videos, hasLength(43));
      expect(page.playlist!.videos.first.title, '高达 第1话');
      expect(page.playlistIndex, 42);
    });
  });

  group('合集页：左滑展开 / 收起（展开后既有能力一条不少）', () {
    testWidgets('左滑「展开」→ 季头 + 逐集平铺；再左滑「收起」→ 回到 1 张卡',
        (tester) async {
      final data = _dataWith([
        _ep('某番', 1, 'BV1', order: 0),
        _ep('某番', 2, 'BV2', order: 1),
        _plain('普通视频', 'BVP1', order: 9),
      ]);
      await _pumpCollection(tester, collection: 'アニメ', data: data);

      expect(find.byType(SeasonTile), findsOneWidget);
      expect(find.byType(VideoTile), findsOneWidget, reason: '只有「普通视频」那条');

      await _swipeAction(tester, '某番', '展开');
      expect(find.byType(SeasonTile), findsOneWidget,
          reason: '展开后季头留在原位（「收起」得有落点）');
      expect(find.byType(VideoTile), findsNWidgets(3),
          reason: '2 集逐集平铺 + 普通视频');
      expect(find.text('某番 第1话'), findsOneWidget);
      expect(find.text('某番 第2话'), findsOneWidget);
      // 季头与「第 1 话」的封面是同一张图：季头若也挂 Hero，同一个 PageRoute
      // 子树里就有两个同 tag 的 Hero → 框架抛 "multiple heroes..."（红屏）。
      // 所以整季卡**一个 Hero 节点都不建**，这条断言把它钉住。
      expect(
        find.descendant(
          of: _seasonCard('某番'),
          matching: find.byType(Hero),
        ),
        findsNothing,
        reason: '整季卡封面不参与 Hero 飞行（点它进的是选集弹层）',
      );
      expect(tester.takeException(), isNull);

      await _swipeAction(tester, '某番', '收起');
      expect(find.byType(VideoTile), findsOneWidget);
      expect(find.text('某番 第1话'), findsNothing);
    });

    testWidgets('展开后拖拽排序照旧：拖到末尾 → 逐集 order 重排 0..n-1 并保存',
        (tester) async {
      final data = _dataWith([
        _ep('某番', 1, 'BV1', order: 0),
        _ep('某番', 2, 'BV2', order: 1),
        _ep('某番', 3, 'BV3', order: 2),
      ]);
      WhitelistData? saved;
      await _pumpCollection(
        tester,
        collection: 'アニメ',
        data: data,
        onSave: (next) => saved = next,
      );
      await _swipeAction(tester, '某番', '展开');

      // 拖拽把手：季头没有把手（折叠卡不可拖）→ 第一个把手属于第 1 话
      final handles = find.byIcon(Icons.drag_indicator);
      expect(handles, findsNWidgets(3), reason: '3 集各一个把手（季头没有）');
      final bottom = tester.getRect(find.byType(VideoTile).last).bottom + 60;
      final gesture = await tester.startGesture(tester.getCenter(handles.first));
      await tester.pump();
      await gesture.moveTo(Offset(300, bottom));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(
        {for (final v in saved!.videos) v.bvid: v.order},
        {'BV2': 0, 'BV3': 1, 'BV1': 2},
        reason: '第 1 话被拖到末尾 → 该合集 order 重排',
      );
    });

    testWidgets('展开后多选 + 批量删除照旧', (tester) async {
      final data = _dataWith([
        _ep('某番', 1, 'BV1', order: 0),
        _ep('某番', 2, 'BV2', order: 1),
        _ep('某番', 3, 'BV3', order: 2),
        _plain('普通视频', 'BVP1', order: 9),
      ]);
      WhitelistData? saved;
      await _pumpCollection(
        tester,
        collection: 'アニメ',
        data: data,
        onSave: (next) => saved = next,
      );
      await _swipeAction(tester, '某番', '展开');

      // 长按第 2 话进多选
      await _longPress(tester, find.text('某番 第2话'));
      expect(find.text('已选 1 项'), findsOneWidget);

      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('删除'),
      ));
      await tester.pumpAndSettle();

      expect(saved!.videos.map((v) => v.bvid).toList(), ['BV1', 'BV3', 'BVP1'],
          reason: '批量删除按 bvid 走，与折叠无关');
    });

    testWidgets('多选模式下长按整季卡 = 整季一起勾上（不是"自动展开"）', (tester) async {
      final data = _dataWith([
        _ep('某番', 1, 'BV1', order: 0),
        _ep('某番', 2, 'BV2', order: 1),
        _ep('某番', 3, 'BV3', order: 2),
      ]);
      WhitelistData? saved;
      await _pumpCollection(
        tester,
        collection: 'アニメ',
        data: data,
        onSave: (next) => saved = next,
      );

      await _longPress(tester, _seasonCard('某番'));
      expect(find.text('已选 3 项'), findsOneWidget,
          reason: '整季卡整体选中 = 这一季全部 3 集');
      expect(find.byType(VideoTile), findsNothing, reason: '不展开，卡片照旧');

      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('删除'),
      ));
      await tester.pumpAndSettle();

      expect(saved!.videos, isEmpty, reason: '一季 3 集一次删干净');
    });
  });
}
