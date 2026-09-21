// 管理写操作的「乐观更新」widget 测试（v2.35.0）：
// - 新建合集 / 视频入合集：**远端写还挂在网上时**界面就已经更新（点击立刻生效）
// - 远端写失败：出现「未同步到 Gist（本地已生效）」提示，且**本地改动仍在**
// - 远端写失败不再把本地改动回滚（与旧行为"写成功才 setState"相反）
//
// 用可闸门化的 fake adapter（`HttpClientAdapter`）把 PATCH 钉在"在飞"状态，
// 再用 mock secure storage 提供 GitHub 配置；同步服务注入假实现，不触网。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 内存版 secure storage（GitHub token / gist id 从这里读）。
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

/// 可闸门化的 fake adapter：每个请求先登记，然后 await [gate]（非 null 时）
/// ——测试用它在"远端写在飞"的瞬间断言界面。
class _GatedAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// 非 null 时每个请求都先等它（= 网络卡住）。
  Completer<void>? gate;

  /// 响应状态码（500 用来验失败分支）。
  int status = 200;

  /// 已经**返回**的请求数（requests.length - completed = 在飞数）。
  int completed = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final g = gate;
    if (g != null) await g.future;
    completed++;
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  /// 最后一次 PATCH 里 whitelist.json 的 JSON。
  Map<String, dynamic> lastGistJson() {
    final payload = requests.last.data as Map<String, dynamic>;
    final files = payload['files'] as Map<String, dynamic>;
    final content =
        (files['whitelist.json'] as Map<String, dynamic>)['content'] as String;
    return jsonDecode(content) as Map<String, dynamic>;
  }
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

WhitelistVideo _video(String bvid, String title, {String collection = ''}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 100,
      title: title,
      cover: '',
      duration: 90,
      upName: 'UP主',
      addedAt: '2026-08-01T00:00:00Z',
      collection: collection,
    );

WhitelistData _dataWith(
  List<WhitelistVideo> videos, {
  List<String> collectionNames = const [],
}) =>
    WhitelistData(
      version: 4,
      updatedAt: '2026-08-20T00:00:00Z',
      videos: videos,
      collections: [
        for (final n in collectionNames)
          CollectionInfo(name: n, createdAt: '2026-08-01T00:00:00Z'),
      ],
      upowners: const <Upowner>[],
    );

/// 注入可闸门化 GithubApi 的首页。
Future<_GatedAdapter> _pumpHome(
  WidgetTester tester,
  WhitelistData data, {
  int status = 200,
}) async {
  _store.clear();
  _mockSecureStorage();
  _store[GithubApi.kTokenKey] = 'ghp_fake';
  _store[GithubApi.kGistIdKey] = 'gist1';
  // 合成"会话有效"的 SESSDATA：避免启动自动登录引导（LoginPage 的 WebView
  // 在测试环境无法构建）把首页顶掉
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';

  final adapter = _GatedAdapter()..status = status;
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(
    MaterialApp(home: PlaylistPage(github: GithubApi(dio: dio))),
  );
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump();
  return adapter;
}

/// 走首页「新建合集」入口建一个 [name] 合集（停在"点完创建"之后一帧）。
Future<void> _createCollection(WidgetTester tester, String name) async {
  final button = find.ancestor(
    of: find.text('新建合集'),
    matching: find.byWidgetPredicate((w) => w is OutlinedButton),
  );
  expect(button, findsOneWidget);
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, name);
  await tester.tap(find.text('创建'));
  await tester.pumpAndSettle();
}

void main() {
  group('乐观更新：点击立刻生效（不等远端写）', () {
    testWidgets('新建合集：PATCH 还挂在网上时，新合集卡片已经出现', (tester) async {
      final adapter = await _pumpHome(
        tester,
        _dataWith([_video('BV1', '视频A', collection: '动画')],
            collectionNames: ['动画']),
      );
      adapter.gate = Completer<void>(); // 让远端写"卡住"

      await _createCollection(tester, '新合辑');

      // 远端写已经发出、但一个字节都还没回来
      expect(adapter.requests.length, 1);
      expect(adapter.completed, 0, reason: '构造场景：PATCH 仍在飞');
      // 界面已经更新（旧实现要等 PATCH 成功才 setState，这里是空的）
      expect(find.text('新合辑'), findsOneWidget);

      // 放行远端写：不该出现任何"没同步"的提示
      adapter.gate!.complete();
      adapter.gate = null;
      await tester.pumpAndSettle();
      expect(adapter.completed, 1);
      expect(find.textContaining('未同步到 Gist'), findsNothing);
      expect(find.text('新合辑'), findsOneWidget);
    });

    testWidgets('视频入合集：PATCH 还挂在网上时，视频已经不在原合集了', (tester) async {
      final adapter = await _pumpHome(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collectionNames: ['动画', '音乐'],
        ),
      );
      await tester.tap(find.text('动画')); // 进合集页
      await tester.pumpAndSettle();
      expect(find.text('视频A'), findsOneWidget);

      adapter.gate = Completer<void>();
      // 长按进多选 → 底部「移动到合集」→ 选目标
      await tester.longPress(find.text('视频A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到合集'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(BottomSheet).last,
        matching: find.text('音乐'),
      ));
      await tester.pumpAndSettle();

      // 远端写仍在飞 → 但本页已经看不到这条视频了
      expect(adapter.requests.length, 1);
      expect(adapter.completed, 0, reason: '构造场景：PATCH 仍在飞');
      expect(find.text('视频A'), findsNothing);
      expect(find.text('「动画」暂无视频'), findsOneWidget);

      // 放行后：写上去的内容确实是"BV1 → 音乐"
      adapter.gate!.complete();
      adapter.gate = null;
      await tester.pumpAndSettle();
      final json = adapter.lastGistJson();
      final videos = (json['videos'] as List).cast<Map<String, dynamic>>();
      expect(videos.single['bvid'], 'BV1');
      expect(videos.single['collection'], '音乐');
    });
  });

  group('乐观更新：远端写失败', () {
    testWidgets('新建合集失败：弹「未同步到 Gist（本地已生效）」，本地改动仍在',
        (tester) async {
      final adapter = await _pumpHome(
        tester,
        _dataWith([_video('BV1', '视频A', collection: '动画')],
            collectionNames: ['动画']),
        status: 500,
      );

      await _createCollection(tester, '新合辑');

      expect(adapter.requests.length, 1);
      expect(find.textContaining('未同步到 Gist（本地已生效）'), findsOneWidget);
      expect(find.textContaining('HTTP 500'), findsOneWidget);
      // **不回滚**：本地已经生效的合集保留（回滚才更糟：用户刚建好的东西消失）
      expect(find.text('新合辑'), findsOneWidget);
    });

    testWidgets('未配置 GitHub 时同样先本地生效，再提示去配置', (tester) async {
      _store.clear();
      _mockSecureStorage(); // 通道在，但不写 token/gist（= 未配置）
      final expireSec =
          DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
              1000;
      _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
      final adapter = _GatedAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
      dio.httpClientAdapter = adapter;
      ServiceLocator.overrideSyncService(_FakeSyncService(
        _dataWith([_video('BV1', '视频A', collection: '动画')],
            collectionNames: ['动画']),
      ));
      await tester.pumpWidget(
        MaterialApp(home: PlaylistPage(github: GithubApi(dio: dio))),
      );
      await tester.pump();
      await tester.pump();

      await _createCollection(tester, '新合辑');

      // 没发请求（配置门禁在 GithubApi 内部），但仍先本地生效 + 明确提示
      expect(adapter.requests, isEmpty);
      expect(find.textContaining('尚未配置 GitHub token 与 Gist ID'), findsOneWidget);
      expect(find.text('新合辑'), findsOneWidget);
    });
  });
}
