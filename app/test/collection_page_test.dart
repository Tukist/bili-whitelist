// 首页合集卡片视图 + 合集视频列表页 widget 测试：
// - 主页：有数据时显示合集卡片（合集名 + 视频数）与固定「未分类」卡片；
//   无数据时显示空态
// - 点击合集卡片 → 进入 CollectionPage（两级导航）
// - 合集页：视频列表（标题 + 时长·UP主）、order 升序排列、
//   长按进入多选模式（底部批量操作栏）
// - 拖拽排序：主页长按合集卡片重排 collections（未分类固定最后不可拖）、
//   合集页长按视频重排 order；保存走注入的 GithubApi（mock secure storage
//   通道 + fake HttpClientAdapter 记录 PATCH 请求，断言 Gist 内容）
// 通过 ServiceLocator.overrideSyncService 注入假同步服务，不触发网络/原生插件。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/main.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/video_tile.dart';

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
  String bvid,
  String title, {
  String collection = '',
  int order = 0,
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 100,
      title: title,
      cover: '',
      duration: 90,
      upName: 'UP主',
      addedAt: '2026-08-01T00:00:00Z',
      collection: collection,
      order: order,
    );

WhitelistData _dataWith(List<WhitelistVideo> videos,
        {List<String> collectionNames = const []}) =>
    WhitelistData(
      version: 3,
      updatedAt: '2026-08-20T00:00:00Z',
      videos: videos,
      collections: [
        for (final n in collectionNames)
          CollectionInfo(name: n, createdAt: '2026-08-01T00:00:00Z'),
      ],
    );

// ---------------------------------------------------------------------------
// 拖拽排序测试基建：mock secure storage 通道 + fake HttpClientAdapter，
// 注入带替身的 GithubApi（PlaylistPage.github），断言 PATCH 请求体。
// 复刻 github_api_test 的同款 mock 模式。
// ---------------------------------------------------------------------------

/// 内存版 secure storage（对应原生 MethodChannel）。
final Map<String, String> _store = {};

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return _store[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        final value = args['value'] as String? ?? '';
        _store[key] = value;
        return true;
      case 'delete':
        _store.remove(args['key'] as String?);
        return true;
      case 'readAll':
        return Map<String, String>.from(_store);
      case 'deleteAll':
        _store.clear();
        return true;
      default:
        return null;
    }
  });
}

/// 固定 200 的 fake adapter：记录每次请求（含 PATCH 请求体），不触网。
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString('{}', 200, headers: {
      'content-type': ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 注入带替身 GithubApi 的 PlaylistPage（主页 + 两级导航均可测保存路径）。
Future<({_FakeAdapter adapter, GithubApi github})> _pumpHomeWithGithub(
  WidgetTester tester,
  WhitelistData data,
) async {
  _store.clear();
  _mockSecureStorage(); // 注册内存 secure storage 通道（hasConfig 需要）
  _store[GithubApi.kTokenKey] = 'ghp_fake';
  _store[GithubApi.kGistIdKey] = 'gist1';
  final adapter = _FakeAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  final github = GithubApi(dio: dio);
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(MaterialApp(home: PlaylistPage(github: github)));
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump();
  return (adapter: adapter, github: github);
}

/// 长按后移动到目标项中心（模拟 ReorderableDelayedDragStartListener 拖拽，
/// 与 Flutter 官方 reorderable_list_test 的 drag 模式一致）：
/// 按下 → 等待长按超时 → moveTo 目标中心 → 抬起。
///
/// ⚠ ReorderableListView 插入语义：moveTo(目标中心) 产生
/// onReorder(old, 目标index) = 「插到目标前面」。要真正越位重排，
/// 调用方需把目标选为「被拖项想要落位处后一项」（本测试选列表尾部锚点）。
Future<void> _longPressDrag(
  WidgetTester tester,
  Finder from,
  Finder to,
) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.moveTo(tester.getCenter(to));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 按住拖拽把手立即拖动（ReorderableDragStartListener 是 Immediate 识别器，
/// 按下即拖，无需长按）：startGesture → moveTo 目标点 → 抬起。
/// 目标点传绝对 Offset（如列表底部 = 移到末尾，确定性最强）。
Future<void> _dragHandle(
  WidgetTester tester,
  Finder from,
  Offset to,
) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 解析最后一次 PATCH 请求体里 whitelist.json 的 JSON。
Map<String, dynamic> _savedGistJson(_FakeAdapter adapter) {
  final req = adapter.requests.last;
  final payload = req.data as Map<String, dynamic>;
  final files = payload['files'] as Map<String, dynamic>;
  final content =
      (files['whitelist.json'] as Map<String, dynamic>)['content'] as String;
  return jsonDecode(content) as Map<String, dynamic>;
}

/// 最后一次保存里 collections 的名字顺序。
List<String> _savedCollectionNames(_FakeAdapter adapter) {
  final json = _savedGistJson(adapter);
  return [
    for (final c in (json['collections'] as List).cast<Map<String, dynamic>>())
      c['name'] as String,
  ];
}

/// 最后一次保存里指定合集的视频 order 映射 {bvid: order}。
Map<String, int> _savedOrders(_FakeAdapter adapter, String collection) {
  final json = _savedGistJson(adapter);
  return {
    for (final v
        in (json['videos'] as List).cast<Map<String, dynamic>>())
      if (v['collection'] == collection)
        v['bvid'] as String: (v['order'] as num).toInt(),
  };
}

/// 注入假数据并 pump 主页。
Future<void> _pumpHome(WidgetTester tester, WhitelistData data) async {
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(const BiliWhitelistApp());
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump();
}

void main() {
  group('主页合集卡片视图', () {
    testWidgets('有数据时显示合集卡片（名称+数量）与未分类卡片', (tester) async {
      await _pumpHome(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A', collection: '动画'),
            _video('BV2', '视频B', collection: '动画'),
            _video('BV3', '视频C', collection: '音乐'),
            _video('BV4', '视频D'),
          ],
          collectionNames: ['动画', '音乐'],
        ),
      );

      // 合集卡片：名称 + 视频数
      expect(find.text('动画'), findsOneWidget);
      expect(find.text('2 个视频'), findsOneWidget);
      expect(find.text('音乐'), findsOneWidget);
      // 固定「未分类」卡片（含 0 个时也显示）
      expect(find.text('未分类'), findsOneWidget);
      // 「音乐」合集与「未分类」各 1 个视频
      expect(find.text('1 个视频'), findsNWidgets(2));
    });

    testWidgets('未分类 0 个视频时仍显示未分类卡片（标 0）', (tester) async {
      await _pumpHome(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画'],
        ),
      );
      expect(find.text('动画'), findsOneWidget);
      expect(find.text('未分类'), findsOneWidget);
      expect(find.text('0 个视频'), findsOneWidget);
    });

    testWidgets('无任何视频时显示空态（白名单为空）', (tester) async {
      await _pumpHome(tester, _dataWith([], collectionNames: []));
      expect(find.textContaining('白名单为空'), findsOneWidget);
      // 空态下不显示合集卡片
      expect(find.text('未分类'), findsNothing);
    });
  });

  group('两级导航：主页 → 合集视频列表页', () {
    testWidgets('点击合集卡片进入合集页，显示该合集视频', (tester) async {
      await _pumpHome(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A', collection: '动画'),
            _video('BV2', '视频B', collection: '动画'),
            _video('BV3', '视频C'),
          ],
          collectionNames: ['动画'],
        ),
      );

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      // 合集页 AppBar 标题 = 合集名；只显示该合集视频
      expect(find.text('动画'), findsOneWidget);
      expect(find.text('视频A'), findsOneWidget);
      expect(find.text('视频B'), findsOneWidget);
      expect(find.text('视频C'), findsNothing); // 未分类视频不显示
      // 列表项副标题：时长 · UP主
      expect(find.text('1:30 · UP主'), findsNWidgets(2));
    });

    testWidgets('点击未分类卡片进入未分类视频列表', (tester) async {
      await _pumpHome(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A', collection: '动画'),
            _video('BV3', '视频C'),
          ],
          collectionNames: ['动画'],
        ),
      );

      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();

      expect(find.text('未分类'), findsOneWidget); // AppBar 标题
      expect(find.text('视频C'), findsOneWidget);
      expect(find.text('视频A'), findsNothing);
    });
  });

  group('合集页视频列表', () {
    testWidgets('视频按 order 升序排列（顺序即列表顺序）', (tester) async {
      await _pumpHome(
        tester,
        _dataWith(
          [
            _video('BV1', '视频1', collection: '动画', order: 2),
            _video('BV2', '视频2', collection: '动画', order: 0),
            _video('BV3', '视频3', collection: '动画', order: 1),
          ],
          collectionNames: ['动画'],
        ),
      );

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      final tiles = tester
          .widgetList<VideoTile>(find.byType(VideoTile))
          .map((t) => t.video.bvid)
          .toList();
      expect(tiles, ['BV2', 'BV3', 'BV1']);
    });

    testWidgets('长按视频进入多选模式，底部出现批量操作栏', (tester) async {
      await _pumpHome(
        tester,
        _dataWith(
          [
            _video('BV1', '视频1', collection: '动画'),
            _video('BV2', '视频2', collection: '动画'),
          ],
          collectionNames: ['动画'],
        ),
      );

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('视频1'));
      await tester.pumpAndSettle();

      // AppBar 显示已选数量 + 底部批量操作栏
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.text('移动到合集'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });
  });

  group('主页合集拖动排序（长按）', () {
    testWidgets('长按拖动合集卡片 → collections 重排并保存 Gist', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画', '音乐'],
        ),
      );

      // 初始顺序：动画、音乐、未分类。长按「动画」拖到尾部锚点「未分类」
      // → newIndex=未分类index → 插到未分类前面 → [音乐, 动画, 未分类]
      await _longPressDrag(tester, find.text('动画'), find.text('未分类'));

      // 保存调用：PATCH 请求，collections 按新顺序
      expect(ctx.adapter.requests, isNotEmpty);
      expect(ctx.adapter.requests.last.method, 'PATCH');
      expect(_savedCollectionNames(ctx.adapter), ['音乐', '动画']);

      // UI 刷新后的卡片顺序
      final yOf = <String, double>{};
      for (final name in ['音乐', '动画', '未分类']) {
        yOf[name] = tester.getTopLeft(find.text(name)).dy;
      }
      expect(yOf['音乐']!, lessThan(yOf['动画']!));
      expect(yOf['动画']!, lessThan(yOf['未分类']!)); // 未分类固定最后
    });

    testWidgets('未分类卡片固定最后，长按拖动不触发保存', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画'],
        ),
      );

      await _longPressDrag(tester, find.text('未分类'), find.text('动画'));

      expect(ctx.adapter.requests, isEmpty); // 未分类不可拖 → 无保存
      // 顺序不变：未分类仍在最后
      expect(
        tester.getTopLeft(find.text('未分类')).dy,
        greaterThan(tester.getTopLeft(find.text('动画')).dy),
      );
    });
  });

  group('合集页视频拖动排序（长按）', () {
    testWidgets('长按拖动视频 → 该合集 order 重排 0..n-1 并保存 Gist', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [
            _video('BV1', '视频1', collection: '动画'),
            _video('BV2', '视频2', collection: '动画'),
            _video('BV3', '视频3', collection: '动画'),
            _video('BVX', '视频X', collection: '音乐'),
          ],
          collectionNames: ['动画', '音乐'],
        ),
      );

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      // 初始展示 [BV1, BV2, BV3]；按住「视频1」尾部拖拽把手拖到列表底部
      // → 移到末尾 → [BV2, BV3, BV1]
      final lastTile = tester.getRect(find.byType(VideoTile).last);
      await _dragHandle(
        tester,
        find.byIcon(Icons.drag_indicator).first,
        Offset(400, lastTile.bottom + 60),
      );

      expect(ctx.adapter.requests, isNotEmpty);
      expect(ctx.adapter.requests.last.method, 'PATCH');
      final orders = _savedOrders(ctx.adapter, '动画');
      expect(orders['BV2'], 0);
      expect(orders['BV3'], 1);
      expect(orders['BV1'], 2);
      // 其他合集 order 不变
      expect(_savedOrders(ctx.adapter, '音乐')['BVX'], 0);

      // UI 刷新后的列表顺序
      final bvids = tester
          .widgetList<VideoTile>(find.byType(VideoTile))
          .map((t) => t.video.bvid)
          .toList();
      expect(bvids, ['BV2', 'BV3', 'BV1']);
    });
  });
}
