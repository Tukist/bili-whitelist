// 读侧可见性测试（v2.43.1）：v2.43.0 把门禁做在**写**侧（改了会提示"没保存"），
// 但用户真正的投诉是「我在白名单里面还是只看到 2 个人」「白名单 UP 主会时不时
// 自动清空」——那是**看**的时候就在看旧/空数据，却没有任何一处告诉他。
// 本文件给三个洞各上锁：
// ① 数据时间不许伪造：来源 local（本地手动导入的快照）**没有**真实抓取时间时，
//    信息条必须显示「数据时间未知（来源: local）」，绝不拿当前时间冒充
//    （旧实现 `snapshot.fetchedAt ?? now` 会把几周前的快照显示成"今天"）；
// ② 陈旧状态必须可见：`SyncResult.stale` → 首页「合集」tab 与合集内部页顶部的
//    **常驻**横幅（含「立即同步」动作，同步成功后消失）；stale == false 时
//    不出现（防止把正常状态误报成离线）；
// ③ 同步失败不再伪装成"白名单为空"：无数据 + `error != null` 走失败态并给
//    「重试」；无数据但同步成功仍是原来的「白名单为空」；
// ④ 信息条第三条分支：无错误、无来源、无时间（**还没同步到任何一份**）→
//    「暂无数据，下拉刷新同步」（不能显示成"时间未知"，那是"有数据但不知道
//    什么时候取的"）。
// ⑤ 搜索页「我的白名单」tab（v2.48.0）：
//    - 陈旧横幅（点「立即同步」重跑一次白名单同步，成功后消失；同步失败**不**
//      清陈旧标记 → 横幅继续挂着）；
//    - **失败 ≠ 空**：四源全失败 → 失败态 + 「重试」（原先和"白名单为空"共用
//      一条文案，用户会把"没同步上"读成"我的白名单空了"）；
//    - "白名单真的空"仍是原来的空态。
// ⑥ 信箱（v2.48.0）：陈旧横幅（信箱消费白名单快照 → 陈旧 = 少几个 UP 主的新
//    视频），且它的「立即同步」**只跑白名单同步**——不复用一轮几分钟的全量
//    `checkAll`（断言：全量检查的调用次数没有增加）。
//
// 复用既有模式：`ServiceLocator.overrideSyncService` 注入假同步服务 + 内存版
// secure storage（不碰原生插件/网络）；「local 快照没有 fetchedAt」那条刻意
// **真跑** `WhitelistSyncService.sync()`（用临时目录覆盖应用文档目录、注入离线
// dio），否则走的还是假服务、测不到本轮改的兜底逻辑。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/collection_page.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_freshness.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/stale_sync_banner.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 假同步服务：按调用次序返回预先排好的结果（最后一个会重复使用）。
class _ScriptedSync extends WhitelistSyncService {
  _ScriptedSync(this._results) : super(dio: Dio());

  final List<SyncResult> _results;
  int calls = 0;

  @override
  Future<SyncResult> sync() async {
    final r = _results[calls.clamp(0, _results.length - 1)];
    calls++;
    return r;
  }

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 同步替身：前 [failTimes] 次**抛异常**（= 四源全失败，真实 `sync()` 就是
/// 抛 `StateError`），之后返回 [result]。同一个替身覆盖"一直失败""失败一次后
/// 恢复"两种用例。
class _FlakySync extends WhitelistSyncService {
  _FlakySync({required this.failTimes, required this.result}) : super(dio: Dio());

  int failTimes;
  final SyncResult result;
  int calls = 0;

  @override
  Future<SyncResult> sync() async {
    calls++;
    if (calls <= failTimes) {
      throw StateError('所有白名单源都不可用（gist/lan/local/cache 全失败）');
    }
    return result;
  }

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 先成功一次（返回 [first]），之后**一直失败**（抛异常）。
///
/// 用来验证"同步失败**不改**陈旧标记"：第一次同步已把页面带进陈旧态，第二次
/// 失败时那条警告必须继续挂着（它说的是"你看的数据是旧的"，与"这次能不能
/// 同步上"是两件事）。
class _FailsAfterFirstSync extends WhitelistSyncService {
  _FailsAfterFirstSync(this.first) : super(dio: Dio());

  final SyncResult first;
  int calls = 0;

  @override
  Future<SyncResult> sync() async {
    calls++;
    if (calls == 1) return first;
    throw StateError('所有白名单源都不可用（gist/lan/local/cache 全失败）');
  }

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 挂起的同步：首帧不返回（结果由测试自己 [Completer.complete]）。
///
/// 用来观察"还没有**任何**一份数据"时信息条显示什么（第三条分支）。
class _PendingSync extends WhitelistSyncService {
  _PendingSync() : super(dio: Dio());

  final Completer<SyncResult> completer = Completer<SyncResult>();
  int calls = 0;

  @override
  Future<SyncResult> sync() {
    calls++;
    return completer.future;
  }

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 每次都失败的网络适配器（= 离线）。
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: '离线（测试）',
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 固定 200 的 fake adapter：只为了让 GithubApi 不触网。
class _NullAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 固定的"真实抓取时间"：刻意用很久以前的日期，这样"界面不出现**今天**的
/// 日期"这条断言不会被数据里的日期污染。
final DateTime _kFetchedAt = DateTime(2020, 1, 2, 3, 4);

/// 今天的 `yyyy-MM-dd`（本地时区）——数据时间若被伪造成"现在"，界面就会出现它。
String _todayPrefix() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

/// 一份白名单。
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

SyncResult _result(
  WhitelistData data, {
  required String source,
  required DateTime? fetchedAt,
  bool stale = false,
}) =>
    SyncResult(
      data: data,
      sourceName: source,
      fetchedAt: fetchedAt,
      fromNetwork: source == 'gist' || source == 'lan',
      stale: stale,
    );

/// 有视频 + 一个「动画」合集的常规数据（首页会渲染合集卡片）。
WhitelistData _homeData() =>
    _wl('2026-09-20T00:00:00Z', ['BV1'], collections: ['动画']);

/// 内存版 secure storage（GitHub token / gist id / 会话都从这里读）。
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

/// 打开首页（注入假同步服务；GitHub/登录态用内存替身，避免触网与原生插件）。
Future<void> _pumpHome(WidgetTester tester, WhitelistSyncService sync) async {
  _store.clear();
  _mockSecureStorage();
  _store[GithubApi.kTokenKey] = 'ghp_fake';
  _store[GithubApi.kGistIdKey] = 'gist1';
  // 合成"会话有效"的 SESSDATA：避免启动自动登录引导把首页顶掉
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';

  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = _NullAdapter();
  ServiceLocator.overrideSyncService(sync);
  await tester.pumpWidget(
    MaterialApp(home: PlaylistPage(github: GithubApi(dio: dio))),
  );
  await tester.pump(); // _load 完成（假服务同步返回）
  await tester.pump();
}

/// 直接打开合集内部页（不经过首页导航）。
Future<void> _pumpCollection(
  WidgetTester tester, {
  required WhitelistData data,
  bool stale = false,
  WhitelistSyncService? sync,
}) async {
  _store.clear();
  _mockSecureStorage();
  if (sync != null) ServiceLocator.overrideSyncService(sync);
  await tester.pumpWidget(
    MaterialApp(
      home: CollectionPage(
        collectionName: '动画',
        data: data,
        saveAndRefresh: (_) async {},
        stale: stale,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 不触网的 dio（所有请求都返回空 JSON 200）。
///
/// 搜索页/信箱都会**构造**真实 [BiliApi]（测试里不该真发请求）：本批要测的
/// 两个 tab / 页面都不需要 B 站接口，给它一个哑适配器即可——真发了请求也不会
/// 触网，而且返回的空 body 会让那条路径立刻失败而不是静默通过。
Dio _deadDio() {
  final dio = Dio();
  dio.httpClientAdapter = _NullAdapter();
  return dio;
}

/// 直接打开搜索页的「我的白名单」tab（不经过首页导航）。
///
/// `initialTab: 1` = 「我的白名单」：本 tab 是**纯本地过滤**，不会发搜索请求。
Future<void> _pumpSearchWhitelistTab(
  WidgetTester tester,
  WhitelistSyncService sync,
) async {
  _store.clear();
  _mockSecureStorage();
  await tester.pumpWidget(
    MaterialApp(
      home: SearchPage(
        initialTab: 1,
        syncService: sync,
        api: BiliApi(dio: _deadDio()),
      ),
    ),
  );
  await tester.pump(); // _loadWhitelist 完成（假服务同步返回）
  await tester.pump();
}

/// 信箱服务替身：只数「全量检查跑了几轮」。
///
/// [staleAfterCheck] 为真时，在 [checkAll] 里给 [WhitelistFreshness] 打标——
/// 真实服务就是这么做的（`checkAll` 内部 `syncService.sync()` → 服务打标），
/// 页面随后读单例拿到"这一轮用的快照旧不旧"。
class _CountingInboxService extends InboxService {
  _CountingInboxService({required this.staleAfterCheck});

  /// 本轮检查用到的白名单快照是否为陈旧快照。
  final bool staleAfterCheck;

  /// [checkAll] 被调用的次数（=「全量检查跑了几轮」）。
  int checkCalls = 0;

  @override
  Future<List<InboxItem>> getItems() async => const [];

  @override
  Future<InboxCheckResult> checkAll({bool force = false}) async {
    checkCalls++;
    WhitelistFreshness.instance.markSync(
      sourceName: staleAfterCheck ? 'cache' : 'gist',
      stale: staleAfterCheck,
    );
    return InboxCheckResult(total: 0, unseen: 0, items: const []);
  }

  @override
  Future<void> markAllRead() async {}
}

/// 打开信箱页；返回的服务替身用来数「全量检查跑了几轮」。
///
/// 队列**刻意留空**（本批测的是顶部横幅与它的动作，不是卡片栈——卡片栈的
/// 用例在 `test/inbox_swipe_test.dart`）：空队列也走完 `_checkNow` 整条路径，
/// 横幅与「立即同步」照常渲染。
Future<_CountingInboxService> _pumpInbox(
  WidgetTester tester, {
  required WhitelistSyncService sync,
  required bool stale,
}) async {
  _store.clear();
  _mockSecureStorage();
  ServiceLocator.overrideSyncService(sync);
  final inbox = _CountingInboxService(staleAfterCheck: stale);
  ServiceLocator.overrideInboxService(inbox);
  await tester.pumpWidget(
    MaterialApp(home: InboxPage(api: BiliApi(dio: _deadDio()))),
  );
  await tester.pumpAndSettle();
  return inbox;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WhitelistFreshness.instance.resetForTest();
    _store.clear();
  });

  tearDown(() {
    WhitelistFreshness.instance.resetForTest();
  });

  // -------------------------------------------------------------------------
  // ① 数据时间不许伪造
  // -------------------------------------------------------------------------
  group('① 数据时间不许拿"现在"冒充', () {
    test('真跑 sync：local 快照（本地导入文件）返回的 fetchedAt 是 null，不是"现在"',
        () async {
      final dir = await Directory.systemTemp.createTemp('wl_read_vis');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      // 只有本地导入文件、没有缓存：网络源全离线 → 落到 local 快照
      File('${dir.path}/whitelist_local.json').writeAsStringSync(
        jsonEncode(_wl('2026-08-01T00:00:00Z', ['BVold']).toJson()),
      );
      final dio = Dio()..httpClientAdapter = _OfflineAdapter();

      final result = await WhitelistSyncService(
        dio: dio,
        supportDirOverride: dir,
      ).sync();

      expect(result.sourceName, 'local');
      expect(result.fetchedAt, isNull,
          reason: '导入快照没有"取得时间"这回事 → 只能是 null，绝不许回退成 now');
    });

    testWidgets('首页信息条：local 且无真实时间 → 「数据时间未知」，不出现今天的日期',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'local', fetchedAt: null),
      ]);
      await _pumpHome(tester, sync);

      // 信息条仍然在（来源可见），时间那一段明确说"未知"
      expect(find.text('数据时间未知（来源: local）'), findsOneWidget);
      // 回归锁：一旦有人再把 `?? DateTime.now()` 加回来，上面那条会变成
      // 「数据时间 <今天>（来源: local）」，下面这条立刻红
      expect(find.textContaining('数据时间 ${_todayPrefix()}'), findsNothing);
      expect(find.textContaining(_todayPrefix()), findsNothing,
          reason: '界面任何一处都不该出现今天的日期（这份数据不是今天取的）');
    });

    testWidgets('首页信息条：cache 等有真实时间的来源 → 照原样显示那个时间',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'cache', fetchedAt: _kFetchedAt),
      ]);
      await _pumpHome(tester, sync);

      expect(find.text('数据时间 2020-01-02 03:04（来源: cache）'), findsOneWidget);
      expect(find.textContaining('数据时间未知'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // ② 陈旧状态必须可见（首页 + 合集内部页）
  // -------------------------------------------------------------------------
  group('② 陈旧状态可见（常驻横幅 + 立即同步）', () {
    testWidgets('首页：stale == true → 出现陈旧横幅，且时间/来源没有被挤掉',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(),
            source: 'cache', fetchedAt: _kFetchedAt, stale: true),
      ]);
      await _pumpHome(tester, sync);

      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);
      expect(find.byType(StaleSyncBanner), findsOneWidget);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, greaterThan(0));
      expect(find.text('立即同步'), findsOneWidget);
      // 横幅与信息条**并存**：陈旧的证据（时间 + 来源）不能因为提示而消失
      expect(find.text('数据时间 2020-01-02 03:04（来源: cache）'), findsOneWidget);
    });

    testWidgets('首页：stale == false → 不出现陈旧横幅，也不占位（防误报）',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpHome(tester, sync);

      expect(find.text(kStaleSnapshotBannerMessage), findsNothing);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, 0,
          reason: '非陈旧态必须零占位（组件留在树上但渲染成 SizedBox.shrink）');
      expect(find.text('立即同步'), findsNothing);
    });

    testWidgets('首页：点横幅「立即同步」→ 真的又同步一次，成功后横幅消失',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(),
            source: 'cache', fetchedAt: _kFetchedAt, stale: true),
        _result(_wl('2026-09-25T00:00:00Z', ['BV1', 'BV2'],
                collections: ['动画', '新合辑']),
            source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpHome(tester, sync);

      expect(sync.calls, 1);
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);

      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(sync.calls, 2, reason: '横幅上的动作必须真的触发一次同步');
      expect(find.text(kStaleSnapshotBannerMessage), findsNothing,
          reason: '同步成功（stale=false）→ 横幅自己消失');
      // 数据也换成了新的一份（不是只把提示藏了）
      expect(find.text('新合辑'), findsOneWidget);
      expect(find.textContaining('已同步到最新，请重新操作一次'), findsOneWidget);
    });

    testWidgets('合集内部页：直接以 stale == true 打开 → 同样出现陈旧横幅',
        (tester) async {
      await _pumpCollection(tester, data: _homeData(), stale: true);

      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      // 列表本身照常渲染（提示是加在上面的，不是替换列表）
      expect(find.text('视频BV1'), findsOneWidget);
    });

    testWidgets('合集内部页：stale == false → 没有横幅', (tester) async {
      await _pumpCollection(tester, data: _homeData());

      expect(find.text(kStaleSnapshotBannerMessage), findsNothing);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, 0);
    });

    testWidgets('首页 → 合集内部页：陈旧标记跟着数据传下去，页内「立即同步」可解除',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(),
            source: 'cache', fetchedAt: _kFetchedAt, stale: true),
        _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpHome(tester, sync);

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      final inCollection = find.descendant(
        of: find.byType(CollectionPage),
        matching: find.text(kStaleSnapshotBannerMessage),
      );
      expect(inCollection, findsOneWidget,
          reason: '合集页的写操作同样被门禁拦 → 提示必须跟着数据下钻');

      await tester.tap(find.descendant(
        of: find.byType(CollectionPage),
        matching: find.text('立即同步'),
      ));
      await tester.pumpAndSettle();

      expect(sync.calls, 2);
      expect(inCollection, findsNothing, reason: '同步成功后合集页的横幅也消失');
    });

    testWidgets('首页：同步失败**不改**陈旧标记 → 横幅继续挂着，且与错误同屏',
        (tester) async {
      final sync = _FailsAfterFirstSync(_result(_homeData(),
          source: 'cache', fetchedAt: _kFetchedAt, stale: true));
      await _pumpHome(tester, sync);

      expect(sync.calls, 1);
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);

      // 点横幅「立即同步」→ 这次同步失败
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(sync.calls, 2);
      // ★ 失败**不清**陈旧标记：屏幕上的数据没变，它是不是旧快照与"这次能不能
      //   同步上"是两件事。让一次失败把"你看的是旧数据"的警告藏掉，正是本批
      //   要消灭的"用户看着旧数据毫不知情"。
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget,
          reason: '同步失败后横幅必须还在（不能被失败顶掉）');
      // 横幅与错误**同屏**是刻意设计：错误只说"没同步上"，横幅说"数据是旧的"。
      // ⚠️ 这里用异常正文点出来而不是 `同步失败：`——提示条那句「仍然同步失败：
      // 请确认网络后重试」也含这四个字，用前缀会命中两条（下一条单独断言它）。
      expect(find.textContaining('所有白名单源都不可用'), findsOneWidget,
          reason: '信息条的红字必须还在（失败不能被藏起来）');
      expect(find.text('数据时间 2020-01-02 03:04（来源: cache）'), findsOneWidget,
          reason: '错误不能把时间/来源挤掉（信息条是多行）');
      // 门禁结论也没被清掉（仍陈旧 → 提示"仍然同步失败"）
      expect(WhitelistFreshness.instance.isStale, isTrue);
      expect(find.textContaining('仍然同步失败'), findsOneWidget);
    });

    testWidgets('合集内部页：重同步仍失败 → 横幅不消失（_stale 不变）',
        (tester) async {
      final sync = _FlakySync(
        failTimes: 99,
        result: _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      );
      await _pumpCollection(tester, data: _homeData(), stale: true, sync: sync);

      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(CollectionPage),
        matching: find.text('立即同步'),
      ));
      await tester.pumpAndSettle();

      expect(sync.calls, 1);
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget,
          reason: '同步仍失败 → 陈旧标记不变，横幅不能消失');
      expect(find.textContaining('同步失败：'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // ③ 同步失败不再伪装成"白名单为空"
  // -------------------------------------------------------------------------
  group('③ 同步失败 vs 白名单为空', () {
    testWidgets('无数据 + 同步失败 → 显示"同步失败"空态 + 重试，不再说"白名单为空"',
        (tester) async {
      final sync = _FlakySync(
        failTimes: 99,
        result: _result(WhitelistData.empty(), source: 'gist', fetchedAt: _kFetchedAt),
      );
      await _pumpHome(tester, sync);

      expect(find.textContaining('白名单为空'), findsNothing,
          reason: '四源全失败不等于"你的白名单被清空了"');
      expect(find.text('同步失败，可能是离线\n下拉刷新或点「重试」重新同步'),
          findsOneWidget);
      // 走的是统一状态视图的**错误态**（与"真空白"的空态是两种画面语言）
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.error);
      expect(state.copyId, 'empty.playlist.sync_failed');
      expect(state.scrollable, isTrue,
          reason: '宿主是 RefreshIndicator → 必须可滚动，下拉刷新才生效');
      // 「重试」入口必须在（失败态要能自救）。⚠️ 测试默认屏幕是 800×600，比
      // 真机矮：空态的「留白 120 + 插画 160 + 标题」把按钮顶到了首屏之外
      // （真机 360×800 上它在首屏内），所以这里先滚进视野再断言——断言的是
      // "入口存在且可点"，与用户在短屏上要做的动作一致。
      final retry = find.text('重试', skipOffstage: false);
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pump();
      expect(find.text('重试'), findsOneWidget);
      // 具体报错仍然看得到（信息条的红字），不会被空态吞掉
      expect(find.textContaining('同步失败：'), findsOneWidget);
      expect(find.textContaining('所有白名单源都不可用'), findsWidgets);
    });

    testWidgets('无数据但同步成功 → 仍是原来的「白名单为空」', (tester) async {
      final sync = _ScriptedSync([
        _result(WhitelistData.empty(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpHome(tester, sync);

      expect(find.text('白名单为空\n下拉刷新重新同步'), findsOneWidget);
      expect(find.textContaining('同步失败'), findsNothing);
      expect(find.text('重试', skipOffstage: false), findsNothing);
    });

    testWidgets('失败态点「重试」→ 再同步一次，成功后切回「白名单为空」',
        (tester) async {
      final sync = _FlakySync(
        failTimes: 1,
        result: _result(WhitelistData.empty(), source: 'gist', fetchedAt: _kFetchedAt),
      );
      await _pumpHome(tester, sync);

      expect(sync.calls, 1);
      final retry = find.text('重试', skipOffstage: false);
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pump();

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(sync.calls, 2, reason: '「重试」必须真的再跑一次同步');
      expect(find.textContaining('同步失败'), findsNothing);
      expect(find.text('白名单为空\n下拉刷新重新同步'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // ④ 信息条的第三条分支（还没有任何一份数据）
  // -------------------------------------------------------------------------
  group('④ 信息条：还没同步到任何一份数据', () {
    testWidgets('无错误 + 无来源 + 无时间 → 「暂无数据，下拉刷新同步」，不是"时间未知"',
        (tester) async {
      final sync = _PendingSync();
      await _pumpHome(tester, sync);

      expect(sync.calls, 1);
      // 首帧：同步还挂着（空态是"正在同步白名单…"），信息条如实说"暂无数据"
      expect(find.text('正在同步白名单…'), findsOneWidget);
      expect(find.text('暂无数据，下拉刷新同步'), findsOneWidget);
      // "时间未知"是**有数据但不知道什么时候取的**（local 快照）专用；
      // 一份数据都没有时不能说"时间未知"，那会让人以为数据已经在了
      expect(find.textContaining('数据时间未知'), findsNothing);
      expect(find.textContaining('数据时间'), findsNothing);

      // 同步回来 → 这行退场，换成正常的时间/来源（顺带证明它只属于"首帧"）
      sync.completer
          .complete(_result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt));
      await tester.pumpAndSettle();

      expect(find.text('暂无数据，下拉刷新同步'), findsNothing);
      expect(find.text('数据时间 2020-01-02 03:04（来源: gist）'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // ⑤ 搜索页「我的白名单」tab：陈旧横幅 + 失败不伪装成空
  // -------------------------------------------------------------------------
  //
  // 这一处是 v2.44.0 明确记下的已知限制：首页「合集」tab 与合集内部页有了
  // 常驻陈旧提示，搜索页的「我的白名单」tab 还没有；而它同样消费白名单快照
  // （这个 tab 就是"照白名单过滤"的入口，「全部 B 站」tab 的「已加入」判断
  // 也走同一份快照 → 看旧快照的人会以为某个视频"没加进去"）。
  // 顺带修同一个 tab 里的误导：同步失败原先被渲染成"白名单加载失败或暂无
  // 数据"，用户会读成"我的白名单空了"。
  group('⑤ 搜索页「我的白名单」tab', () {
    testWidgets('stale == true → 顶部出现陈旧横幅，列表照常渲染', (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(),
            source: 'cache', fetchedAt: _kFetchedAt, stale: true),
      ]);
      await _pumpSearchWhitelistTab(tester, sync);

      expect(sync.calls, 1);
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);
      expect(find.byType(StaleSyncBanner), findsOneWidget);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, greaterThan(0));
      expect(find.text('立即同步'), findsOneWidget);
      // 横幅是**加在列表上面**的，不是替换列表
      expect(find.text('视频BV1'), findsOneWidget);
    });

    testWidgets('stale == false → 没有横幅，也不占位（防误报成离线）',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpSearchWhitelistTab(tester, sync);

      expect(find.text(kStaleSnapshotBannerMessage), findsNothing);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, 0,
          reason: '非陈旧态必须零占位（组件留在树上但渲染成 SizedBox.shrink）');
      expect(find.text('立即同步'), findsNothing);
      expect(find.text('视频BV1'), findsOneWidget);
    });

    testWidgets('点横幅「立即同步」→ 真的又同步一次，成功后横幅消失',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(),
            source: 'cache', fetchedAt: _kFetchedAt, stale: true),
        _result(_wl('2026-09-25T00:00:00Z', ['BV9'], collections: ['动画']),
            source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpSearchWhitelistTab(tester, sync);

      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);

      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(sync.calls, 2, reason: '横幅上的动作必须真的触发一次同步');
      expect(find.text(kStaleSnapshotBannerMessage), findsNothing,
          reason: '同步成功（stale=false）→ 横幅自己消失');
      // 数据也换成了新的一份（不是只把提示藏了）
      expect(find.text('视频BV9'), findsOneWidget);
      expect(find.text('视频BV1'), findsNothing);
    });

    testWidgets('首次同步就失败 → 失败态 + 「重试」，不再说"白名单为空"',
        (tester) async {
      final sync = _FlakySync(
        failTimes: 99,
        result: _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      );
      await _pumpSearchWhitelistTab(tester, sync);

      expect(sync.calls, 1);
      // 四源全失败 ≠ 白名单为空：走的是错误态，文案也是另一条
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.error);
      expect(state.copyId, 'empty.search.whitelist.sync_failed');
      expect(find.text('白名单同步失败，可能是离线\n请确认网络后点「重试」'),
          findsOneWidget);
      // 两条"像是空"的文案都不该出现（"加载失败或暂无数据" / "没有匹配的视频"）
      expect(find.textContaining('白名单加载失败或暂无数据'), findsNothing);
      expect(find.text('白名单里没有匹配的视频'), findsNothing);
      // 具体报错不丢（本页没有别的红字出口 → 挂在副文案上）
      expect(find.textContaining('所有白名单源都不可用'), findsOneWidget);
      // 原始异常可能很长 → 这个态必须是可滚动的，短屏上「重试」才够得着
      expect(state.scrollable, isTrue,
          reason: '副文案长度不可控（原始异常）→ 走可滚动形态');
      // 「重试」入口必须在（失败态要能自救）。⚠️ 测试默认屏幕是 800×600，比
      // 真机矮：插画 + 两行标题 + 原始异常把按钮顶到了首屏之外（真机 360×800
      // 上它在首屏内），所以这里先滚进视野再断言——断言的是"入口存在且可点"，
      // 与用户在短屏上要做的动作一致（与首页那条同样的写法）。
      final retry = find.text('重试', skipOffstage: false);
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pump();
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('失败态点「重试」→ 再同步一次，成功后切回列表', (tester) async {
      final sync = _FlakySync(
        failTimes: 1,
        result: _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      );
      await _pumpSearchWhitelistTab(tester, sync);

      expect(sync.calls, 1);
      final retry = find.text('重试', skipOffstage: false);
      expect(retry, findsOneWidget);
      await tester.ensureVisible(retry);
      await tester.pump();

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(sync.calls, 2, reason: '「重试」必须真的再跑一次同步');
      expect(find.text('重试', skipOffstage: false), findsNothing);
      expect(find.textContaining('白名单同步失败'), findsNothing);
      expect(find.text('视频BV1'), findsOneWidget, reason: '成功后显示真实列表');
    });

    testWidgets('白名单真的空 → 仍是原来的空态（不是失败态、也没有「重试」）',
        (tester) async {
      final sync = _ScriptedSync([
        _result(WhitelistData.empty(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpSearchWhitelistTab(tester, sync);

      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty, reason: '同步成功但没数据 = 空，不是错');
      expect(state.copyId, 'empty.search.whitelist.filter');
      expect(find.text('白名单里没有匹配的视频'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.textContaining('同步失败'), findsNothing);
    });

    testWidgets('同步还在途中 → 沿用原来的空态文案，不会被误报成失败',
        (tester) async {
      final sync = _PendingSync();
      await _pumpSearchWhitelistTab(tester, sync);

      expect(sync.calls, 1);
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.search.whitelist');
      expect(find.text('重试'), findsNothing);

      // 同步回来 → 换成真实列表（顺带证明上面那条只属于"还没拿到数据"）
      sync.completer
          .complete(_result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt));
      await tester.pumpAndSettle();
      expect(find.text('视频BV1'), findsOneWidget);
    });

    testWidgets('陈旧 + 同步失败**不**清陈旧标记 → 横幅与失败态同屏',
        (tester) async {
      final sync = _FailsAfterFirstSync(_result(_homeData(),
          source: 'cache', fetchedAt: _kFetchedAt, stale: true));
      await _pumpSearchWhitelistTab(tester, sync);

      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);

      // 点横幅「立即同步」→ 这次同步失败
      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(sync.calls, 2);
      // ★ 失败**不清**陈旧标记：屏幕上的数据没变，"这份快照旧不旧"与"这次能不能
      //   同步上"是两件事（与首页/合集页/信箱同一约定）
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget,
          reason: '同步失败后横幅必须还在（不能被失败顶掉）');
      // 失败态同时出现：横幅说"你看的是旧数据"，失败态说"这次没同步上"
      expect(find.text('重试', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('所有白名单源都不可用'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // ⑥ 信箱：陈旧横幅 + 「立即同步」只跑白名单同步
  // -------------------------------------------------------------------------
  //
  // 信箱确实消费白名单快照（`InboxService.checkAll` 内部 `syncService.sync()`
  // 拿 `data.upowners`）：快照陈旧 = 名单里少几个 UP 主 → 他们的新视频不会被
  // 发现。而它的「立即同步」**不能**复用页面的一轮全量检查（那一轮要串行遍历
  // 白名单 UP 主、每个间隔 ≥1.5s，可能跑几分钟）——本组把这个约定钉住。
  group('⑥ 信箱：陈旧横幅 + 轻量重同步', () {
    testWidgets('本轮检查用的快照陈旧 → 顶部出现横幅（队列空也照常渲染）',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      final inbox = await _pumpInbox(tester, sync: sync, stale: true);

      expect(inbox.checkCalls, 1, reason: '进页面跑了一轮检查');
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);
      expect(find.byType(StaleSyncBanner), findsOneWidget);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, greaterThan(0));
      expect(find.text('立即同步'), findsOneWidget);
      // 横幅挂在滚动容器之外：空队列的空态照常显示
      expect(find.textContaining('暂未有白名单 UP 主的新视频'), findsOneWidget);
    });

    testWidgets('快照不陈旧 → 没有横幅，也不占位', (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      await _pumpInbox(tester, sync: sync, stale: false);

      expect(find.text(kStaleSnapshotBannerMessage), findsNothing);
      expect(tester.getSize(find.byType(StaleSyncBanner)).height, 0);
      expect(find.text('立即同步'), findsNothing);
    });

    testWidgets('点「立即同步」→ 只跑白名单同步，**不再跑一轮全量检查**',
        (tester) async {
      final sync = _ScriptedSync([
        _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      ]);
      final inbox = await _pumpInbox(tester, sync: sync, stale: true);

      expect(inbox.checkCalls, 1);
      expect(sync.calls, 0,
          reason: '页面的检查走 inboxService，页面自己不直接调 syncService');

      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(sync.calls, 1, reason: '「立即同步」必须真的同步一次白名单');
      expect(inbox.checkCalls, 1,
          reason: '★ 只跑白名单同步：一轮几分钟的全量 checkAll 不许被顺带触发');
      expect(find.text(kStaleSnapshotBannerMessage), findsNothing,
          reason: '同步成功 → 横幅自己消失');
      expect(find.textContaining('白名单已同步到最新'), findsOneWidget);
    });

    testWidgets('轻同步仍失败 → 横幅不消失（不清陈旧标记）+ 给出错误提示',
        (tester) async {
      final sync = _FlakySync(
        failTimes: 99,
        result: _result(_homeData(), source: 'gist', fetchedAt: _kFetchedAt),
      );
      final inbox = await _pumpInbox(tester, sync: sync, stale: true);

      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget);

      await tester.tap(find.text('立即同步'));
      await tester.pumpAndSettle();

      expect(sync.calls, 1);
      expect(inbox.checkCalls, 1, reason: '失败也一样不许顺带跑全量检查');
      expect(find.text(kStaleSnapshotBannerMessage), findsOneWidget,
          reason: '同步仍失败 → 快照还是那份旧的，横幅不能消失');
      expect(find.textContaining('同步失败：'), findsOneWidget);
    });
  });
}
