// 首页合集卡「移动到…」（v2.38.0）widget 测试：
// - 左滑三块（移动 / 重命名 / 删除），**顺序与宽度**实测/断言（3 × 76 = 228dp
//   ≤ 卡片可用宽 336dp，卡住「别把 360dp 屏挤坏」这条）；
// - 点「移动」→ 目标选择 sheet（排除自己/子孙/当前父级）→ 确认框 → 落库
//   （断言 PATCH 出去的 collections 变成嵌套路径 + 视频 collection 跟着走）；
// - 取消确认框 → 一个 PATCH 都不发；
// - 防环：目标列表里没有自己，也没有自己的子孙；非顶层首项是「移到顶层」；
// - 「未分类」卡不是合集 → 没有「移动」这一块；
// - 首页同级拖拽重排**没被动**（4 条既有拖拽用例在 collection_page_test.dart，
//   本文件只补一条「左滑露出「移动」之后，长按拖拽仍然可用」的手势共存检查）。
//
// 基建复刻 collection_page_test.dart：mock secure storage 通道 + fake
// HttpClientAdapter 记录 PATCH 请求体 → 断言真正要写进 Gist 的内容。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/swipe_action_box.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

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
            _store[key] = args['value'] as String? ?? '';
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

class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

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
}) => WhitelistVideo(
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

WhitelistData _dataWith(
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

/// 注入带替身 GithubApi 的首页（写操作会真的走 PATCH → 被 adapter 记下）。
Future<({_FakeAdapter adapter, GithubApi github})> _pumpHomeWithGithub(
  WidgetTester tester,
  WhitelistData data,
) async {
  _store.clear();
  _mockSecureStorage();
  _store[GithubApi.kTokenKey] = 'ghp_fake';
  _store[GithubApi.kGistIdKey] = 'gist1';
  // 注入「会话有效」的合成 SESSDATA，让首页静默启动（不弹含 WebView 的登录页）
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
  final adapter = _FakeAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  final github = GithubApi(dio: dio);
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(MaterialApp(home: PlaylistPage(github: github)));
  await tester.pump(); // _load 完成
  await tester.pump();
  return (adapter: adapter, github: github);
}

/// 在卡片上左滑（一步 -160px，越过 touch slop → 横向识别器直接胜出）。
Future<void> _swipeCardLeft(WidgetTester tester, Finder card) async {
  final gesture = await tester.startGesture(tester.getCenter(card));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-160, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 最后一次 PATCH 里 whitelist.json 的 JSON。
Map<String, dynamic> _savedGistJson(_FakeAdapter adapter) {
  final payload = adapter.requests.last.data as Map<String, dynamic>;
  final files = payload['files'] as Map<String, dynamic>;
  final content =
      (files['whitelist.json'] as Map<String, dynamic>)['content'] as String;
  return jsonDecode(content) as Map<String, dynamic>;
}

List<String> _savedCollectionNames(_FakeAdapter adapter) => [
  for (final c in (_savedGistJson(adapter)['collections'] as List)
      .cast<Map<String, dynamic>>())
    c['name'] as String,
];

Map<String, String> _savedVideoCollections(_FakeAdapter adapter) => {
  for (final v in (_savedGistJson(adapter)['videos'] as List)
      .cast<Map<String, dynamic>>())
    v['bvid'] as String: v['collection'] as String,
};

/// 目标选择器里的文案（只在那层弹层里找；目标 sheet 一开就只有它一个
/// [BottomSheet]，不加 `.last` —— `.last` 那种链式 finder 在断言失败时
/// 会因为「没 evaluate 就访问 found」再抛一次，把真正的失败原因盖掉）。
Finder _pickerText(String text) => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.text(text),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('首页合集卡左滑三块：顺序与宽度', () {
    testWidgets('左滑露出「移动 / 重命名 / 删除」三块，每块 76dp、总宽不撑破卡片',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画', '音乐'],
        ),
      );

      expect(find.text('移动'), findsNothing, reason: '合上时不在树上');
      await _swipeCardLeft(tester, find.text('动画'));

      for (final label in ['移动', '重命名', '删除']) {
        final block = find.byKey(SwipeActionBox.actionKey(label));
        expect(block, findsOneWidget, reason: '「$label」这一块要露出来');
        final size = tester.getSize(block);
        expect(size.width, 76, reason: '默认 actionWidth（≥48dp 触摸目标）');
        expect(size.height, greaterThanOrEqualTo(48));
      }

      // 「别把 360dp 屏挤坏」：3 块总宽 ≤ 卡片可用宽（360 - 左右各 12 内边距）
      const cardWidth = 360.0 - 12 * 2;
      expect(76.0 * 3, lessThanOrEqualTo(cardWidth));
      // 全露出后卡片本体仍留一块可见区域（不是被整张推出屏外）
      final area = tester.getSize(find.byKey(SwipeActionBox.actionAreaKey));
      expect(area.width, lessThanOrEqualTo(cardWidth));
      expect(cardWidth - 76.0 * 3, greaterThanOrEqualTo(100),
          reason: '至少留 100dp 卡片可见（封面 64 + 一截名字）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('三块顺序：移动在最左、删除在最右（与合集页子合集卡一致）',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画', '音乐'],
        ),
      );
      await _swipeCardLeft(tester, find.text('动画'));

      final xMove =
          tester.getCenter(find.byKey(SwipeActionBox.actionKey('移动'))).dx;
      final xRename =
          tester.getCenter(find.byKey(SwipeActionBox.actionKey('重命名'))).dx;
      final xDelete =
          tester.getCenter(find.byKey(SwipeActionBox.actionKey('删除'))).dx;
      expect(xMove, lessThan(xRename));
      expect(xRename, lessThan(xDelete));
    });

    testWidgets('「未分类」卡不是合集 → 没有「移动」这一块', (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画'],
        ),
      );
      await _swipeCardLeft(tester, find.text('未分类'));
      expect(find.text('移动'), findsNothing);
      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('左滑露出后，长按拖拽仍可用（同级重排没被手势层挡住）',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画', '音乐'],
        ),
      );
      await _swipeCardLeft(tester, find.text('动画'));
      expect(find.text('移动'), findsOneWidget);

      // 长按「动画」并往下拖：ReorderableListView 的拖拽代理要能起来
      final gesture = await tester.startGesture(tester.getCenter(find.text('动画')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('首页「移动到…」落库', () {
    testWidgets('左滑「移动」→ 选目标 → 确认 → collections 变嵌套路径、视频跟着走',
        (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A', collection: '动画'),
            _video('BV2', '视频B', collection: '动画/2024冬'),
            _video('BV3', '视频C', collection: '音乐'),
          ],
          collectionNames: ['动画', '动画/2024冬', '音乐'],
        ),
      );

      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();

      // 目标选择器：自己与自己的子孙都不在列表里
      expect(find.text('移动到合集'), findsOneWidget);
      expect(find.text('把「动画」移动到…'), findsOneWidget);
      expect(_pickerText('音乐'), findsOneWidget);
      expect(_pickerText('动画'), findsNothing, reason: '自己不能当目标（防环）');
      expect(_pickerText('动画 / 2024冬'), findsNothing,
          reason: '自己的子孙不能当目标（挂进去会自我包含）');
      expect(_pickerText('未分类'), findsNothing, reason: '未分类不是合集');

      await tester.tap(_pickerText('音乐'));
      await tester.pumpAndSettle();
      expect(find.text('移动合集「动画」'), findsOneWidget);
      expect(find.textContaining('把「动画」移动到「音乐」下面'), findsOneWidget);

      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();

      expect(_savedCollectionNames(ctx.adapter), [
        '音乐/动画',
        '音乐/动画/2024冬',
        '音乐',
      ]);
      expect(_savedVideoCollections(ctx.adapter), {
        'BV1': '音乐/动画',
        'BV2': '音乐/动画/2024冬',
        'BV3': '音乐',
      });
      expect(find.textContaining('已把「动画」移动到「音乐」下面'), findsOneWidget);
      // 首页只剩一个顶层合集（动画 已搬进 音乐）→ 移动入口也只剩一个
      await _swipeCardLeft(tester, find.text('音乐'));
      expect(find.text('移动'), findsOneWidget);
    });

    testWidgets('取消确认框 → 一个 PATCH 都不发', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画', '音乐'],
        ),
      );
      final before = ctx.adapter.requests.length;

      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();
      await tester.tap(_pickerText('音乐'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(ctx.adapter.requests.length, before, reason: '取消不该产生 PATCH');
      expect(find.text('动画'), findsOneWidget, reason: '合集还在原位');
    });

    testWidgets('只有自己一个合集 → 给一句提示，不弹空列表', (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画'],
        ),
      );

      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();

      expect(find.text('没有其它合集可以作为目标，请先新建一个合集'), findsOneWidget);
      expect(find.text('移动到合集'), findsNothing);
    });

    testWidgets('防环：左滑顶层合集 → 目标列表排除自己与自己的子孙',
        (tester) async {
      // 首页只展示**顶层**合集 → 首页左滑只能移动顶层合集，「移到顶层（首页）」
      // 这一项在首页这条路径上永远不会出现（那是子合集的场景，见
      // collection_page_test 的子合集左滑「移动」）。
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A', collection: '音乐/动画'),
            _video('BV2', '视频B', collection: '动画'),
          ],
          collectionNames: ['音乐', '音乐/动画', '动画'],
        ),
      );
      await _swipeCardLeft(tester, find.text('音乐'));
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();

      expect(_pickerText('动画'), findsOneWidget, reason: '另一个顶层合集是合法目标');
      expect(_pickerText('音乐'), findsNothing, reason: '自己不能当目标');
      expect(_pickerText('音乐 / 动画'), findsNothing,
          reason: '自己的子孙不能当目标（挂进去路径会自我包含）');
      expect(_pickerText('移到顶层（首页）'), findsNothing,
          reason: '顶层合集已经在首页那一层');
      expect(_pickerText('未分类'), findsNothing);

      // 点弹层外面关掉（目标选择 sheet 没有按钮，选目标才关）
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(ctx.adapter.requests, isEmpty);
    });
  });
}
