// ① 离线陈旧快照风险的测试（v2.43.0）：
// - **选源**：网络源都失败时，在 local（手动导入快照）与 cache（上次同步副本）
//   之间按数据自带的 `updated_at` 选**更新**的那一份（两个方向都覆盖）；
// - **门禁**：确证陈旧 → 写操作被拦（一句提示 + **零 PATCH** + 界面不出现假成功）；
// - **恢复**：点「立即同步」同步成功后写操作恢复；
// - **回归红线**：正常联网（gist 源）启动时写操作完全不受影响。
//
// 这里刻意**真跑** `WhitelistSyncService.sync()`（用临时目录覆盖应用文档目录、
// 注入离线 dio），因为本轮改的正是"源选择 + 陈旧判定"这两段只有真跑才走得到
// 的逻辑——用假同步服务会把它整段绕过。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/whitelist_write_queue.dart';
import 'package:bili_whitelist_app/sync/whitelist_freshness.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 每次都失败的网络适配器（= 离线）。
class _OfflineAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: '离线（测试）',
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 记录请求、按需返回成功/失败的 Gist 适配器（PATCH 计数用）。
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  int status = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 一份白名单（`updated_at` 是本轮判据的核心字段）。
WhitelistData _wl(String updatedAt, List<String> bvids,
        {List<String> collections = const []}) =>
    WhitelistData(
      version: 4,
      updatedAt: updatedAt,
      videos: [
        for (final b in bvids)
          WhitelistVideo(
            bvid: b,
            cid: 100,
            title: '视频$b',
            cover: '',
            duration: 60,
            upName: 'UP主',
            addedAt: '2026-01-01T00:00:00Z',
            collection: collections.isEmpty ? '' : collections.first,
          ),
      ],
      collections: [
        for (final c in collections)
          CollectionInfo(name: c, createdAt: '2026-01-01T00:00:00Z'),
      ],
      upowners: const [],
    );

/// 应用文档目录（临时），测试结束由 tearDown 清理。
late Directory _dir;

void _writeLocal(WhitelistData data) {
  File('${_dir.path}/whitelist_local.json')
      .writeAsStringSync(jsonEncode(data.toJson()));
}

void _writeCache(WhitelistData data, {String? fetchedAt}) {
  File('${_dir.path}/whitelist_cache.json').writeAsStringSync(jsonEncode({
    'fetched_at': fetchedAt ?? DateTime(2026, 9, 20).toIso8601String(),
    'data': data.toJson(),
  }));
}

/// 真跑一次同步（网络源全部离线 → 落到离线快照分支）。
Future<SyncResult> _syncOffline() async {
  final dio = Dio()..httpClientAdapter = _OfflineAdapter();
  final service = WhitelistSyncService(dio: dio, supportDirOverride: _dir);
  return service.sync();
}

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

/// 假同步服务：按调用次序返回预先排好的结果（最后一个会重复使用）。
class _ScriptedSync extends WhitelistSyncService {
  _ScriptedSync(this._results) : super(dio: Dio());

  final List<SyncResult> _results;
  int calls = 0;

  /// 是否记录到「落本地缓存」的调用（陈旧态下一次都不该发生）。
  final List<WhitelistData> cachedWrites = [];

  @override
  Future<SyncResult> sync() async {
    final r = _results[calls.clamp(0, _results.length - 1)];
    calls++;
    return r;
  }

  @override
  Future<void> saveToCache(WhitelistData data) async {
    cachedWrites.add(data);
  }
}

SyncResult _result(WhitelistData data, {required String source, bool stale = false}) =>
    SyncResult(
      data: data,
      sourceName: source,
      fetchedAt: DateTime(2026, 9, 21),
      fromNetwork: source == 'gist' || source == 'lan',
      stale: stale,
    );

/// 打开首页（注入假同步服务 + 记录型 GitHub 适配器）。
Future<_RecordingAdapter> _pumpHome(
  WidgetTester tester,
  _ScriptedSync sync,
) async {
  _store.clear();
  _mockSecureStorage();
  _store[GithubApi.kTokenKey] = 'ghp_fake';
  _store[GithubApi.kGistIdKey] = 'gist1';
  // 合成"会话有效"的 SESSDATA：避免启动自动登录引导把首页顶掉
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';

  final adapter = _RecordingAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  ServiceLocator.overrideSyncService(sync);
  await tester.pumpWidget(
    MaterialApp(home: PlaylistPage(github: GithubApi(dio: dio))),
  );
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump();
  return adapter;
}

/// 走首页「新建合集」入口建一个 [name] 合集。
Future<void> _createCollection(WidgetTester tester, String name) async {
  final button = find.ancestor(
    of: find.text('新建合集'),
    matching: find.byWidgetPredicate((w) => w is OutlinedButton),
  );
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, name);
  await tester.tap(find.text('创建'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    _dir = await Directory.systemTemp.createTemp('wl_stale_test');
    SharedPreferences.setMockInitialValues({});
    WhitelistFreshness.instance.resetForTest();
  });

  tearDown(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
    WhitelistFreshness.instance.resetForTest();
  });

  group('①a 离线时按 updated_at 选更新的那一份', () {
    test('local 旧 / cache 新 → 选 cache（不再"local 存在就用 local"）', () async {
      _writeLocal(_wl('2026-08-01T00:00:00Z', ['BVold']));
      _writeCache(_wl('2026-09-20T00:00:00Z', ['BVnew']));

      final result = await _syncOffline();

      expect(result.sourceName, 'cache');
      expect(result.data.videos.single.bvid, 'BVnew');
      expect(result.data.updatedAt, '2026-09-20T00:00:00Z');
    });

    test('local 新 / cache 旧 → 选 local（另一个方向）', () async {
      _writeLocal(_wl('2026-09-21T00:00:00Z', ['BVnew']));
      _writeCache(_wl('2026-07-01T00:00:00Z', ['BVold']));

      final result = await _syncOffline();

      expect(result.sourceName, 'local');
      expect(result.data.videos.single.bvid, 'BVnew');
    });

    test('local 没有 updated_at、cache 有 → 有明确时间的 cache 胜', () async {
      _writeLocal(_wl('', ['BVunknown']));
      _writeCache(_wl('2026-09-20T00:00:00Z', ['BVnew']));

      final result = await _syncOffline();

      expect(result.sourceName, 'cache');
    });

    test('两边都无法比较（都没有 updated_at）→ 按原顺序兜底 local', () async {
      _writeLocal(_wl('', ['BVlocal']));
      _writeCache(_wl('', ['BVcache']));

      final result = await _syncOffline();

      expect(result.sourceName, 'local', reason: '无从比较 → 保持旧顺序');
    });

    test('只有 cache 存在（没导入过文件）→ 仍用 cache', () async {
      _writeCache(_wl('2026-09-20T00:00:00Z', ['BVcache']));

      final result = await _syncOffline();

      expect(result.sourceName, 'cache');
      expect(result.data.videos.single.bvid, 'BVcache');
    });
  });

  group('①b 陈旧判定（是否落后于"已知最新"）', () {
    test('快照 updated_at == 最近一次同步到的 → 不算陈旧', () async {
      _writeCache(_wl('2026-09-20T00:00:00Z', ['BV1']));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('whitelist_remote_updated_at', '2026-09-20T00:00:00Z');

      final result = await _syncOffline();

      expect(result.sourceName, 'cache');
      expect(result.stale, isFalse, reason: '这份快照就是已知最新');
      expect(WhitelistFreshness.instance.isStale, isFalse);
    });

    test('快照落后于已知最新 → 判为陈旧并打标', () async {
      _writeLocal(_wl('2026-08-01T00:00:00Z', ['BVold']));
      _writeCache(_wl('2026-09-20T00:00:00Z', ['BVnew']));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('whitelist_remote_updated_at', '2026-09-25T00:00:00Z');

      final result = await _syncOffline();

      // 选的是更新的 cache，但仍落后于"已知最新"（9-25）→ 陈旧
      expect(result.stale, isTrue);
      expect(result.data.updatedAt, '2026-09-20T00:00:00Z');
      expect(WhitelistFreshness.instance.isStale, isTrue);
      expect(WhitelistFreshness.instance.writeBlockReason,
          kStaleSnapshotWriteBlockedMessage);
    });

    test('从没成功同步过（无已知最新记录）→ 保守判为陈旧', () async {
      _writeCache(_wl('2026-09-20T00:00:00Z', ['BV1']));

      final result = await _syncOffline();

      expect(result.stale, isTrue, reason: '无从证明它是最新 → 宁可多拦一次');
    });

    test('时间解析不出来时退回字符串比较（不同 → 陈旧）', () async {
      _writeCache(_wl('第一版', ['BV1']));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('whitelist_remote_updated_at', '第二版');

      final result = await _syncOffline();

      expect(result.stale, isTrue);
    });
  });

  group('①b 陈旧态下写操作被拦（零 PATCH / 零本地缓存写）', () {
    test('写队列：陈旧态 submit 直接拒掉，不发 PATCH 也不落本地缓存', () async {
      WhitelistFreshness.instance.markStaleForTest();
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
      dio.httpClientAdapter = adapter;
      final sync = _ScriptedSync([_result(_wl('t', ['BV1']), source: 'cache')]);
      final messages = <String>[];
      final queue = WhitelistWriteQueue(
        github: GithubApi(dio: dio),
        syncService: () => sync,
        onError: messages.add,
      );

      final ok = await queue.submit(_wl('t', ['BV1', 'BV2']));

      expect(ok, isFalse);
      expect(adapter.requests, isEmpty, reason: '零 PATCH');
      expect(sync.cachedWrites, isEmpty, reason: '陈旧快照不许写进本地缓存');
      expect(messages.single, kStaleSnapshotWriteBlockedMessage);
    });

    test('写队列：不陈旧时照常写（门禁不能误伤）', () async {
      _mockSecureStorage();
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      WhitelistFreshness.instance
          .markSync(sourceName: 'gist', stale: false);
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
      dio.httpClientAdapter = adapter;
      final sync = _ScriptedSync([_result(_wl('t', ['BV1']), source: 'gist')]);
      final queue = WhitelistWriteQueue(
        github: GithubApi(dio: dio),
        syncService: () => sync,
      );

      final ok = await queue.submit(_wl('t', ['BV1', 'BV2']));

      expect(ok, isTrue);
      expect(adapter.requests.length, 1);
      expect(sync.cachedWrites.length, 1);
    });

    testWidgets('首页：陈旧态下新建合集被拦（界面不出现假成功 + 一句话提示 + 零 PATCH）',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_wl('2026-09-20T00:00:00Z', ['BV1']),
            source: 'cache', stale: true),
      ]);
      final adapter = await _pumpHome(tester, sync);

      await _createCollection(tester, '新合辑');

      expect(adapter.requests, isEmpty, reason: '零 PATCH');
      expect(find.textContaining('整份覆盖到云端较新的白名单上'), findsOneWidget);
      expect(find.text('新合辑'), findsNothing, reason: '拦在 setState 之前，界面不能出现假成功');
    });

    testWidgets('首页：同步成功（gist 源）后写操作恢复', (tester) async {      final data = _wl('2026-09-20T00:00:00Z', ['BV1']);
      final sync = _ScriptedSync([
        _result(data, source: 'cache', stale: true),
        // 「立即同步」之后：真源拿到最新数据 → 不再陈旧
        _result(data, source: 'gist'),
      ]);
      final adapter = await _pumpHome(tester, sync);

      await _createCollection(tester, '被拦的');
      expect(adapter.requests, isEmpty);
      // v2.44.0 起首页顶部多了一条常驻陈旧横幅（`StaleSyncBanner`），它也有
      // 一个「立即同步」按钮 → 这里必须指名 SnackBar 里那个动作，否则会与横幅
      // 撞名。断言强度不变：仍然是"恰好一个"带该文案的动作，并且点的就是它。
      final snackSyncAction =
          find.widgetWithText(SnackBarAction, '立即同步');
      expect(snackSyncAction, findsOneWidget);

      // 点提示上的「立即同步」→ 同步成功 → 门禁解除
      await tester.tap(snackSyncAction);
      await tester.pumpAndSettle();
      expect(sync.calls, 2);
      expect(WhitelistFreshness.instance.isStale, isFalse);
      expect(find.textContaining('已同步到最新，请重新操作一次'), findsOneWidget);

      // 再操作一次 → 正常落库
      await _createCollection(tester, '新合辑');
      expect(adapter.requests.length, 1, reason: '同步成功后写操作恢复');
      expect(find.text('新合辑'), findsOneWidget);
    });

    testWidgets('首页：正常联网启动（gist 源、不陈旧）→ 写操作完全不受影响',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_wl('2026-09-21T00:00:00Z', ['BV1']), source: 'gist'),
      ]);
      final adapter = await _pumpHome(tester, sync);

      await _createCollection(tester, '新合辑');

      expect(adapter.requests.length, 1, reason: '回归红线：门禁不能误伤正常流程');
      expect(find.text('新合辑'), findsOneWidget);
      expect(find.textContaining('本地快照'), findsNothing);
    });

    testWidgets('合集页（子页）：陈旧态下新建子合集同样被拦，零 PATCH、本页不出现假成功',
        (tester) async {
      final sync = _ScriptedSync([
        _result(
          _wl('2026-09-20T00:00:00Z', ['BV1'], collections: ['动画']),
          source: 'cache',
          stale: true,
        ),
      ]);
      final adapter = await _pumpHome(tester, sync);

      // 进合集页（本页有自己的内存副本，是"第二道门禁"要罩住的地方）
      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建子合集'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '子合集X');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(adapter.requests, isEmpty, reason: '零 PATCH');
      expect(find.textContaining('整份覆盖到云端较新的白名单上'), findsOneWidget,
          reason: '一句可读提示（与首页同一份文案）');
      expect(find.text('子合集X'), findsNothing,
          reason: '拦在 setState 之前：本页界面不能出现假成功');
    });
  });
}
