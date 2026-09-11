// InboxService 单元测试（mock dio + 内存 shared_preferences）：
// - checkAll：白名单空 → 0/0；UP 主有 lastSeenBvid → diff 出未读条目
// - checkAll：节流命中（< 30min）→ 返回缓存不触网（并把对不上的红点存量校正）
// - markAllRead：清空 unseen + 写 last_check_at
// - getItems：按 pub_date 倒序输出（**按 bvid 去重**）
// - getUnseenCount：从 prefs 读（口径 = 去重后的队列条数）
// - ★ v2.19.0 缺陷修复回归（「检测」≠「已读确认」）：
//   连续两次 checkAll（中间不处理）第二次仍返回同样的未读、
//   sync 整体失败回退缓存、单个 UP 拉取失败保留原未读、
//   已处理 bvid 不再出现、未读全部处理完才推进基线、getItems 过滤残留 key
// - ★ v2.23.0 缺陷修复回归：
//   首次见到的 UP（无基线）**恰好产出首页最新 1 条**（不是 0、不是 5）且
//   基线指向最新那条；红点口径 == 卡片栈口径（同 bvid 跨 UP / 重复 mid 只算
//   一条）；checkAll 单飞（并发两次只跑一轮）；边查边落盘（整轮没跑完时
//   本地未读已经能读到第一个 UP 主的结果）
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/inbox_handled_store.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

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
      default:
        return null;
    }
  });
}

class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];
  _RoutingAdapter(this.handlers);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final handler = handlers[options.path];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler'}),
        404,
        headers: {'content-type': ['application/json']},
      );
    }
    return ResponseBody.fromString(
      jsonEncode(handler()),
      200,
      headers: {'content-type': ['application/json; charset=utf-8']},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 假 sync service：返回固定白名单（不触发路径/Gist 等）
class _FakeSyncService extends WhitelistSyncService {
  final WhitelistData data;
  _FakeSyncService(this.data);

  @override
  Future<SyncResult> sync() async => SyncResult(
        data: data,
        sourceName: 'fake',
        fetchedAt: DateTime.now(),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 会失败的假 sync service：`failAfter` 次（默认 0）后开始抛异常。
class _FlakySyncService extends WhitelistSyncService {
  _FlakySyncService(this.data, {this.failAfter = 0});

  final WhitelistData data;
  int failAfter;

  @override
  Future<SyncResult> sync() async {
    if (failAfter <= 0) throw StateError('所有白名单源都不可用');
    failAfter--;
    return SyncResult(
      data: data,
      sourceName: 'fake',
      fetchedAt: DateTime.now(),
      fromNetwork: false,
    );
  }

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 内存版 GitHub：让 `UpownerWriter.updateLastSeenBatch` 真能"写盘"，
/// 从而观察基线推进（以及跨 checkAll 生效）。
class _MemoryGithubApi extends GithubApi {
  _MemoryGithubApi(this.data);

  WhitelistData data;
  int saves = 0;

  /// true → saveToGist 返回 false（模拟写盘失败）。
  bool failSave = false;

  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() async => data;

  @override
  Future<bool> saveToGist(WhitelistData wl) async {
    if (failSave) return false;
    data = wl;
    saves++;
    return true;
  }
}

/// 跟着内存 GitHub 走的 sync 替身：写盘后下一次 sync 就能读到新基线。
class _MemorySyncService extends WhitelistSyncService {
  _MemorySyncService(this.github);

  final _MemoryGithubApi github;

  @override
  Future<SyncResult> sync() async => SyncResult(
        data: github.data,
        sourceName: 'fake',
        fetchedAt: DateTime.now(),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 按 **mid** 路由的 dio 适配器（多 UP 主 / 指定 UP 主失败用）：
/// `videos` 是 mid → 首页 vlist 生成器（可随时改，模拟"又发了新视频"）。
class _MidAdapter implements HttpClientAdapter {
  _MidAdapter(this.videos, {Set<int>? failing})
      : failing = failing ?? <int>{};

  final Map<int, List<Map<String, dynamic>> Function()> videos;

  /// 这些 mid 返回风控错误码 -412（模拟拉取失败）。
  final Set<int> failing;

  /// 这些 mid 的请求先挂在闸门上（模拟"这一轮还没走完"；见「边查边落盘」用例）。
  final Map<int, Completer<void>> gates = {};

  int searchCalls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    switch (options.path) {
      case '/x/frontend/finger/spi':
        return _json(_spiBody());
      case '/x/web-interface/nav':
        return _json(_navBody());
      case '/x/space/wbi/arc/search':
        searchCalls++;
        final mid = int.tryParse('${options.queryParameters['mid']}') ?? -1;
        final gate = gates[mid];
        if (gate != null) await gate.future;
        if (failing.contains(mid)) {
          return _json({'code': -412, 'message': '请求过于频繁，请稍后再试'});
        }
        final gen = videos[mid];
        return _json(_videoListBody(gen == null ? const [] : gen()));
      default:
        return _json({'code': -1, 'message': 'no handler'}, 404);
    }
  }

  ResponseBody _json(Map<String, dynamic> body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {'content-type': ['application/json; charset=utf-8']},
      );

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'b3', 'b_4': 'b4'},
    };

Map<String, dynamic> _navBody() => {
      'code': -101,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

Map<String, dynamic> _videoListBody(List<Map<String, dynamic>> vlist, {int? count}) =>
    {
      'code': 0,
      'message': 'OK',
      'data': {
        'list': {
          if (count != null) 'count': count,
          'vlist': vlist,
        },
      },
    };

Map<String, dynamic> _v({
  String bvid = 'BV1',
  String title = 'T',
  int created = 1700000000,
}) =>
    {
      'bvid': bvid,
      'title': title,
      'length': '4:45',
      'author': 'UP',
      'pic': '',
      'mid': 1,
      'created': created,
    };

Upowner _up({required int mid, String? lastSeenBvid}) => Upowner(
      mid: mid,
      name: 'UP$mid',
      face: '',
      addedAt: DateTime.utc(2026, 1, 1),
      lastSeenBvid: lastSeenBvid,
    );

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _store.clear();
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({});
    // reset service locator to defaults
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData.empty()));
  });

  test('白名单无 UP 主 → checkAll 返回 0/0', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([]),
    });
    final api = _api(adapter);
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData.empty()));
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll(force: true);
    expect(result.total, 0);
    expect(result.unseen, 0);
    expect(result.items, isEmpty);
  });

  test('UP 主有 lastSeenBvid → diff 出新视频条目', () async {
    // UP1 首页返回 3 条：BV3（最新）/ BV2 / BV1（lastSeenBvid）
    // 期望未读 = BV3、BV2（BV1 是已读基线）
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([
            _v(bvid: 'BV3', title: '最新', created: 1700000300),
            _v(bvid: 'BV2', title: '次新', created: 1700000200),
            _v(bvid: 'BV1', title: '已读', created: 1700000100),
          ]),
    });
    final api = _api(adapter);
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    );
    ServiceLocator.overrideSyncService(_FakeSyncService(data));
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll(force: true);
    expect(result.total, 1);
    expect(result.unseen, 2);
    expect(result.items.map((e) => e.bvid).toList(), ['BV3', 'BV2']);
    // getItems 也返回缓存
    final cached = await svc.getItems();
    expect(cached.map((e) => e.bvid).toList(), ['BV3', 'BV2']);
    // getUnseenCount
    expect(await svc.getUnseenCount(), 2);
  });

  test('★ 首次见到的 UP（无 lastSeenBvid）→ 恰好产出首页最新 1 条，不堆积历史',
      () async {
    // 首页 5 条（BV5 最新 … BV1 最旧）。老行为是 0 条（只建基线不产未读），
    // 修后是**恰好 1 条**（最新那条）：不是 0（风控下队列会空得只剩别的 UP 主
    // 那一两条、甚至空），也不是 5（把历史一次全灌进信箱）。
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([
            _v(bvid: 'BV5', title: '最新', created: 1700000500),
            _v(bvid: 'BV4', title: '次新', created: 1700000400),
            _v(bvid: 'BV3', title: '旧3', created: 1700000300),
            _v(bvid: 'BV2', title: '旧2', created: 1700000200),
            _v(bvid: 'BV1', title: '旧1', created: 1700000100),
          ]),
    });
    final api = _api(adapter);
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100)], // 无 lastSeenBvid（刚导入 / 一直被风控）
    );
    ServiceLocator.overrideSyncService(_FakeSyncService(data));
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll(force: true);
    expect(result.items.map((e) => e.bvid).toList(), ['BV5']);
    expect(result.unseen, 1);
    expect(result.items.single.title, '最新');
    // 「不堆积历史」的原意 = 别把首页窗口那 5 条全塞进来（只取 1 条）
    expect(result.items.length, lessThan(InboxService.kUnseenPerUpowner));
    // 落盘与红点同一口径
    expect((await svc.getItems()).map((e) => e.bvid).toList(), ['BV5']);
    expect(await svc.getUnseenCount(), 1);

    // 再检查一次：白名单是静态替身（基线写不出去）→ 仍是「首次」分支，
    // 但队列里只该有那 1 条（不重复），且**不许自动消费**（markHandled 仍是
    // 唯一消费入口 —— 首次产出 ≠ 已读）
    final again = await svc.checkAll(force: true);
    expect(again.items.map((e) => e.bvid).toList(), ['BV5']);
    expect(await svc.getUnseenCount(), 1);
    expect(await InboxHandledStore.instance.getAll(), isEmpty,
        reason: '反复检查不许把"首次产出的这条"当成已处理掉');
  });

  test('★ 首次见到 → 基线指向最新那条；这条未读不会被"检测即已读"抹掉', () async {
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100)], // 无基线
    );
    final github = _MemoryGithubApi(data);
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV3', title: '最新', created: 1700000300),
            _v(bvid: 'BV2', title: '次新', created: 1700000200),
          ],
    });
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    final svc = InboxService.fromApi(
      _api(adapter),
      upownerWriter: UpownerWriter(github: github),
    );

    final first = await svc.checkAll(force: true);
    expect(first.items.map((e) => e.bvid).toList(), ['BV3']);
    expect(github.data.upowners.single.lastSeenBvid, 'BV3',
        reason: '首次建基线：指向首页最新那条');

    // 第二次：基线已到位 → diff 为空，但**上次没处理的未读还在**
    //（检测 ≠ 已读确认：不许因为它成了基线就消失）
    final second = await svc.checkAll(force: true);
    expect(second.items.map((e) => e.bvid).toList(), ['BV3'],
        reason: '这条未读要等用户亲手处理');
    expect(second.unseen, 1);
    expect(await svc.getUnseenCount(), 1);
    expect(github.data.upowners.single.lastSeenBvid, 'BV3');

    // 用户处理掉（唯一消费入口）→ 红点归零；再检查也不会把它复活
    await svc.markHandled('BV3');
    expect(await svc.getUnseenCount(), 0);
    expect((await svc.checkAll(force: true)).items, isEmpty);
  });

  test('首次见到但首页窗口为空 → 0 条且不建基线（不崩）', () async {
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100)],
    );
    final github = _MemoryGithubApi(data);
    final adapter = _MidAdapter({100: () => const []});
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    final svc = InboxService.fromApi(
      _api(adapter),
      upownerWriter: UpownerWriter(github: github),
    );

    final r = await svc.checkAll(force: true);
    expect(r.items, isEmpty);
    expect(await svc.getUnseenCount(), 0);
    expect(github.saves, 0, reason: '没有可建基线的数据 → 不写 Gist');
  });

  test('节流命中（< 30min）→ 返回缓存不触网，且红点与队列同一口径（自愈）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([]),
    });
    final api = _api(adapter);
    Map<String, dynamic> qi(String bvid, int pubDate) => InboxItem(
          upMid: 100,
          upName: 'UP100',
          upFace: '',
          bvid: bvid,
          title: bvid,
          cover: '',
          duration: 60,
          pubDate: pubDate,
        ).toJson();
    // last_check_at = 5 分钟前 → 节流命中；队列里实际有 2 条，但存量红点数是
    // 旧实现算歪的 7（口径统一后应以队列为准，并顺手校正）
    SharedPreferences.setMockInitialValues({
      'inbox:meta:last_check_at':
          DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
      'inbox:meta:total_unseen': 7,
      'inbox:meta:checked_mids': jsonEncode([100]),
      'inbox:upowner:100:unseen': jsonEncode([
        qi('BV2', 1700000200),
        qi('BV1', 1700000100),
      ]),
    });
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll();
    // 节流命中 → 不发请求（adapter.requests 只有 spi/nav，没有 arc/search）
    expect(
      adapter.requests.where((r) => r.path == '/x/space/wbi/arc/search'),
      isEmpty,
    );
    expect(result.items.map((e) => e.bvid).toList(), ['BV2', 'BV1']);
    expect(result.unseen, 2, reason: '红点口径 = 去重后的队列条数（不是存量 7）');
    expect(await svc.getUnseenCount(), 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('inbox:meta:total_unseen'), 2,
        reason: '存量与队列对不上时顺手校正 → 首页红点下次启动自愈');
  });

  test('force=true 绕过节流（即使 < 30min）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([
            _v(bvid: 'BV9'),
            _v(bvid: 'BV1'), // lastSeenBvid = BV1
          ]),
    });
    final api = _api(adapter);
    SharedPreferences.setMockInitialValues({
      'inbox:meta:last_check_at':
          DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
      'inbox:meta:total_unseen': 99,
    });
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    );
    ServiceLocator.overrideSyncService(_FakeSyncService(data));
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll(force: true);
    expect(
      adapter.requests.where((r) => r.path == '/x/space/wbi/arc/search'),
      isNotEmpty,
    );
    expect(result.unseen, 1); // BV9 未读
  });

  test('markAllRead → 清空 unseen + total_unseen=0', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([
            _v(bvid: 'BVNEW'),
          ]),
    });
    final api = _api(adapter);
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    );
    ServiceLocator.overrideSyncService(_FakeSyncService(data));
    final svc = InboxService.fromApi(api);

    await svc.checkAll(force: true);
    expect(await svc.getUnseenCount(), 1);

    await svc.markAllRead();
    expect(await svc.getUnseenCount(), 0);
    expect(await svc.getItems(), isEmpty);
  });

  // -------------------------------------------------------------------------
  // ★ v2.19.0 缺陷修复回归：「检测」与「已读确认」解耦
  // -------------------------------------------------------------------------

  /// 常见场景：1 个 UP 主（mid=100，基线 BV1）+ 首页 3 条（BV3 最新）。
  ///
  /// 走内存 GitHub + 内存 sync：基线推进能真写进"Gist"，下一次 checkAll
  /// 就能读到（这样才能验出"推进基线"这个行为本身）。
  ({_MidAdapter adapter, InboxService svc, _MemoryGithubApi github}) oneUp() {
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    );
    final github = _MemoryGithubApi(data);
    final videos = [
      _v(bvid: 'BV3', title: '最新', created: 1700000300),
      _v(bvid: 'BV2', title: '次新', created: 1700000200),
      _v(bvid: 'BV1', title: '已读', created: 1700000100),
    ];
    final adapter = _MidAdapter({100: () => videos});
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    return (
      adapter: adapter,
      github: github,
      svc: InboxService.fromApi(
        _api(adapter),
        upownerWriter: UpownerWriter(github: github),
      ),
    );
  }

  test('★ 核心回归：连续两次 checkAll（中间不处理）第二次仍返回同样的未读', () async {
    final s = oneUp();
    final first = await s.svc.checkAll(force: true);
    expect(first.items.map((e) => e.bvid).toList(), ['BV3', 'BV2']);

    // ★ 不变量的直接断言：用户还没处理，基线**不许动**。
    //   老实现正是在这里把 lastSeenBvid 推到 BV3（发现即已读）→ 下一次 diff
    //   为空 → 未读缓存被删、红点归零（用户没看过内容就"被已读"）。
    expect(
      s.github.data.upowners.single.lastSeenBvid,
      'BV1',
      reason: '检测 ≠ 已读确认：用户没处理就不推进基线',
    );

    final second = await s.svc.checkAll(force: true);
    expect(second.items.map((e) => e.bvid).toList(), ['BV3', 'BV2'],
        reason: '没处理过的未读必须一直在');
    expect(second.unseen, 2);
    expect(await s.svc.getUnseenCount(), 2);
    expect(
      (await s.svc.getItems()).map((e) => e.bvid).toList(),
      ['BV3', 'BV2'],
    );
    expect(s.github.data.upowners.single.lastSeenBvid, 'BV1');
  });

  test('已处理的 bvid 不再出现在 checkAll 结果里', () async {
    final s = oneUp();
    await s.svc.checkAll(force: true);
    await s.svc.markHandled('BV3');

    final r = await s.svc.checkAll(force: true);
    expect(r.items.map((e) => e.bvid).toList(), ['BV2']);
    expect(r.unseen, 1);
    expect(await s.svc.getUnseenCount(), 1);
  });

  test('markHandled / unmarkHandled：摘掉未读后能放回，总数跟着变', () async {
    final s = oneUp();
    final first = await s.svc.checkAll(force: true);
    await s.svc.markHandled('BV3');
    expect(await s.svc.getUnseenCount(), 1);
    expect((await s.svc.getItems()).map((e) => e.bvid).toList(), ['BV2']);

    // 撤销：记录消失 + 条目回到未读 + 总数回升
    await s.svc.unmarkHandled(first.items.first);
    expect(await s.svc.getUnseenCount(), 2);
    expect(
      (await s.svc.getItems()).map((e) => e.bvid).toSet(),
      {'BV3', 'BV2'},
    );
  });

  test('某 UP 未读全部处理完 → 基线推进到最新（下次不再产生同一批）', () async {
    final s = oneUp();
    await s.svc.checkAll(force: true);
    await s.svc.markHandled('BV3');
    await s.svc.markHandled('BV2');

    // 这一轮：候选都在、但全被处理过 → 推进基线到最新 + 清「已处理」记录
    final done = await s.svc.checkAll(force: true);
    expect(done.unseen, 0);
    expect(s.github.data.upowners.single.lastSeenBvid, 'BV3',
        reason: '未读全部处理完 → 基线推进到首页最新那条');
    expect(await InboxHandledStore.instance.getAll(), isEmpty,
        reason: '基线写盘成功后顺手清掉这批已处理记录（防记录无限增长）');

    // 基线已推到 BV3：UP 主又发了一条 BV4 → 只有 BV4 是未读。
    // （若基线还停在 BV1，BV3/BV2 会被重新算成未读 → 这里会看到 3 条）
    s.adapter.videos[100] = () => [
          _v(bvid: 'BV4', title: '更新的', created: 1700000400),
          _v(bvid: 'BV3', title: '最新', created: 1700000300),
          _v(bvid: 'BV2', title: '次新', created: 1700000200),
          _v(bvid: 'BV1', title: '已读', created: 1700000100),
        ];
    final r = await s.svc.checkAll(force: true);
    expect(r.items.map((e) => e.bvid).toList(), ['BV4']);
  });

  test('基线写盘失败时不清「已处理」记录（避免卡片重新冒出来）', () async {
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    );
    final github = _MemoryGithubApi(data);
    github.failSave = true; // 模拟 Gist 写失败
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV3', title: '最新', created: 1700000300),
            _v(bvid: 'BV1', title: '已读', created: 1700000100),
          ],
    });
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    final svc = InboxService.fromApi(
      _api(adapter),
      upownerWriter: UpownerWriter(github: github),
    );

    await svc.checkAll(force: true);
    await svc.markHandled('BV3');
    final r = await svc.checkAll(force: true);
    expect(r.unseen, 0);
    expect(await InboxHandledStore.instance.getAll(), contains('BV3'),
        reason: '基线没写出去 → 保留已处理记录，下一次不会重新冒出来');
    expect(await svc.getUnseenCount(), 0);
  });

  test('单个 UP 拉取失败 → 该 UP 原有未读保留（不被 remove）', () async {
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV3', title: 'A3', created: 1700000300),
            _v(bvid: 'BV1', title: 'A1', created: 1700000100),
          ],
      200: () => [
            _v(bvid: 'BV9', title: 'B9', created: 1700000900),
            _v(bvid: 'BV8', title: 'B8', created: 1700000800),
          ],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ],
    )));
    final svc = InboxService.fromApi(_api(adapter));

    final first = await svc.checkAll(force: true);
    expect(first.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'});

    adapter.failing.add(100); // mid=100 开始被风控
    final second = await svc.checkAll(force: true);
    expect(second.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'},
        reason: '拉取失败的 UP 主，卡片不能凭空消失');
    expect(
      (await svc.getItems()).map((e) => e.bvid).toSet(),
      {'BV3', 'BV9'},
      reason: '缓存也不能被 remove 掉',
    );
    expect(await svc.getUnseenCount(), 2);
  });

  test('sync 整体失败 → 返回上次缓存（不是空列表），并置 failed', () async {
    final s = oneUp();
    final first = await s.svc.checkAll(force: true);
    expect(first.items, isNotEmpty);

    ServiceLocator.overrideSyncService(
      _FlakySyncService(WhitelistData.empty(), failAfter: 0),
    );
    final r = await s.svc.checkAll(force: true);
    expect(r.failed, isTrue);
    expect(r.message, isNotEmpty);
    expect(r.items.map((e) => e.bvid).toList(), ['BV3', 'BV2'],
        reason: '整体失败要保留上次列表，不能把 UI 打空');
    expect(r.unseen, 2);
  });

  test('getItems 只返回当前白名单 UP 主的未读（残留 key 不外泄）', () async {
    final s = oneUp();
    await s.svc.checkAll(force: true);

    // 手工塞一个"白名单里已经没有"的 UP 主残留 key
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'inbox:upowner:999:unseen',
      jsonEncode([
        {
          'up_mid': 999,
          'up_name': '已移除',
          'bvid': 'BVX',
          'title': '残留',
          'pub_date': 1700009999,
        },
      ]),
    );

    final items = await s.svc.getItems();
    expect(items.map((e) => e.bvid).toSet(), {'BV3', 'BV2'});
    expect(items.any((e) => e.upMid == 999), isFalse);
  });

  // -------------------------------------------------------------------------
  // ★ 并发（v2.19.x）：一轮 checkAll 可能跑几分钟（每 UP 主间隔 ≥1.5s），
  //   页面不再为它阻塞交互 → markHandled 随时可能发生在遍历中途。
  // -------------------------------------------------------------------------

  test('★ 并发：遍历期间用户处理掉的条目不会被写回未读（也不出现在返回值里）',
      () async {
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ],
    );
    final github = _MemoryGithubApi(data);
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    late InboxService svc;
    var triggered = false;
    final adapter = _MidAdapter({
      100: () {
        // 第一个 UP 主刚拉完，用户就在页面上把 BV3 划走了。
        // 旧实现：pending 用的是**遍历开始时**的「已处理」快照 → 第 4 步会
        // 把 BV3 又写回未读（卡片复活、红点回涨、与页面队列对不上）。
        if (!triggered) {
          triggered = true;
          unawaited(svc.markHandled('BV3'));
        }
        return [
          _v(bvid: 'BV3', title: '最新', created: 1700000300),
          _v(bvid: 'BV2', title: '次新', created: 1700000200),
          _v(bvid: 'BV1', title: '已读', created: 1700000100),
        ];
      },
      200: () => [
            _v(bvid: 'BV9', title: '最新', created: 1700000900),
            _v(bvid: 'BV8', title: '已读', created: 1700000800),
          ],
    });
    svc = InboxService.fromApi(_api(adapter));

    final r = await svc.checkAll(force: true);

    expect(r.items.map((e) => e.bvid).toList(), ['BV9', 'BV2'],
        reason: '期间被消费的 BV3 不能再算未读');
    expect(
      (await svc.getItems()).map((e) => e.bvid).toList(),
      ['BV9', 'BV2'],
      reason: 'prefs 里也不能把它写回来',
    );
    expect(await svc.getUnseenCount(), 2, reason: '红点必须与队列保持一致');
    expect(await InboxHandledStore.instance.getAll(), contains('BV3'));
  });

  test('并发：遍历期间用户撤销过的条目照常留在队列里（不会被冲掉）', () async {
    // 先让 BV2 处于「已处理」状态（页面上的"上一张"）
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    );
    final github = _MemoryGithubApi(data);
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    late InboxService svc;
    var triggered = false;
    final adapter = _MidAdapter({
      100: () {
        if (!triggered) {
          triggered = true;
          // 用户把"上一张"放回来（撤销）—— 条目已写回 prefs，本轮 pending 里
          // 也有它，写盘时不能被覆盖掉
          unawaited(svc.unmarkHandled(const InboxItem(
            upMid: 100,
            upName: 'UP100',
            upFace: '',
            bvid: 'BV2',
            title: '次新',
            cover: '',
            duration: 60,
            pubDate: 1700000200,
          )));
        }
        return [
          _v(bvid: 'BV3', title: '最新', created: 1700000300),
          _v(bvid: 'BV2', title: '次新', created: 1700000200),
          _v(bvid: 'BV1', title: '已读', created: 1700000100),
        ];
      },
    });
    svc = InboxService.fromApi(_api(adapter));
    // 先记一条「已处理」，再撤销（模拟页面上"划过又撤销"）
    await svc.markHandled('BV2');

    final r = await svc.checkAll(force: true);
    expect(r.items.map((e) => e.bvid).toList(), ['BV3', 'BV2']);
    expect((await svc.getItems()).map((e) => e.bvid).toList(), ['BV3', 'BV2']);
  });

  // -------------------------------------------------------------------------
  // ★ 红点口径 == 卡片栈口径（v2.23.0）：按 bvid 去重后的条数
  // -------------------------------------------------------------------------

  test('★ 红点口径：同一 bvid 落在两个 UP 主的 key 里 → 只算 1 条（联合投稿）',
      () async {
    // 两个 UP 主的首页窗口里都有同一条 BV9（联合投稿 / 被两人转发），
    // 各自基线是 BV1 / BV8 → 两位都候选出 BV9
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV9', title: '联合投稿', created: 1700000900),
            _v(bvid: 'BV1', created: 1700000100),
          ],
      200: () => [
            _v(bvid: 'BV9', title: '联合投稿', created: 1700000900),
            _v(bvid: 'BV8', created: 1700000800),
          ],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ],
    )));
    final svc = InboxService.fromApi(_api(adapter));

    final r = await svc.checkAll(force: true);
    expect(r.items.map((e) => e.bvid).toList(), ['BV9'],
        reason: '卡片栈按 bvid 去重 → 只有一张卡');
    expect(r.unseen, 1, reason: '红点必须与卡片栈同一个口径');
    expect(await svc.getItems(), hasLength(1));
    expect(await svc.getUnseenCount(), 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('inbox:meta:total_unseen'), 1,
        reason: '写盘的总数也是去重后的（老实现按 key 累加会写成 2）');

    // 消费它：两个 key 里的它都要摘掉，否则去重口径下红点降不下去
    await svc.markHandled('BV9');
    expect(await svc.getUnseenCount(), 0);
    expect(await svc.getItems(), isEmpty);
  });

  test('★ 红点口径：白名单里有重复 mid → 同一个 UP 只检查一遍、只算一条', () async {
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV3', title: '最新', created: 1700000300),
            _v(bvid: 'BV1', created: 1700000100),
          ],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 100, lastSeenBvid: 'BV1'), // 重复导入留下的
      ],
    )));
    final svc = InboxService.fromApi(_api(adapter));

    final r = await svc.checkAll(force: true);
    expect(adapter.searchCalls, 1, reason: '去重后只查一遍（不是两遍）');
    expect(r.items.map((e) => e.bvid).toList(), ['BV3']);
    expect(r.unseen, 1);
    expect(await svc.getUnseenCount(), 1);
    expect(await svc.getItems(), hasLength(1));
  });

  // -------------------------------------------------------------------------
  // ★ 单飞 + 边查边落盘（v2.23.0）
  // -------------------------------------------------------------------------

  test('★ 单飞：并发两次 checkAll 只跑一轮遍历（共享同一个 Future）', () async {
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV3', created: 1700000300),
            _v(bvid: 'BV1', created: 1700000100),
          ],
      200: () => [
            _v(bvid: 'BV9', created: 1700000900),
            _v(bvid: 'BV8', created: 1700000800),
          ],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ],
    )));
    final svc = InboxService.fromApi(_api(adapter));

    final f1 = svc.checkAll(force: true);
    final f2 = svc.checkAll(force: true);
    expect(identical(f1, f2), isTrue, reason: '第二轮复用第一轮的 Future');
    final results = await Future.wait([f1, f2]);
    expect(adapter.searchCalls, 2,
        reason: '2 个 UP 主 → 只遍历一轮（不是两轮各 2 次）');
    expect(results[0].items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'});
    expect(results[1].items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'});

    // 上一轮结束后闸门放开：后续调用能重新开一轮
    await svc.checkAll(force: true);
    expect(adapter.searchCalls, 4);
  });

  test('★ 边查边落盘：第一个 UP 主查完就写盘（页面在检查中就能读到新条目）',
      () async {
    final gate = Completer<void>();
    final adapter = _MidAdapter({
      100: () => [
            _v(bvid: 'BV3', title: 'A3', created: 1700000300),
            _v(bvid: 'BV1', created: 1700000100),
          ],
      200: () => [
            _v(bvid: 'BV9', title: 'B9', created: 1700000900),
            _v(bvid: 'BV8', created: 1700000800),
          ],
    });
    adapter.gates[200] = gate; // 第二个 UP 主卡住 → 这一轮还没跑完
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ],
    )));
    final svc = InboxService.fromApi(_api(adapter));

    final f = svc.checkAll(force: true);
    // 第一个 UP 主已查完并落盘，第二个还挂在闸门上（此刻在 1.5s 间隔里）
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await svc.getItems()).map((e) => e.bvid).toList(), ['BV3'],
        reason: '整轮还没跑完，但第一个 UP 主的结果已经在盘上了');
    expect(await svc.getUnseenCount(), 1, reason: '红点也同步涨了');

    gate.complete();
    final r = await f;
    expect(r.items.map((e) => e.bvid).toList(), ['BV9', 'BV3']);
    expect(await svc.getUnseenCount(), 2);
  });

  // -------------------------------------------------------------------------
  // ★ v2.24.0 #2：白名单远超每轮上限 → **轮转**覆盖全部（不是只看前 100 个）
  // -------------------------------------------------------------------------

  test('★ 轮转：250 个 UP 三轮覆盖全部，每轮 ≤ 上限，不在本轮的 UP 未读照样可见',
      () async {
    // 设备实测：gist 白名单 204 个 UP，而每轮只查前 100 个 → 第 101 个之后
    // 永远没有基线、永远不被检查（"信箱没东西可滑"的残留主因）。
    const total = 250;
    const firstMid = 1000;
    // 种一条"上一轮留下的"未读：它属于**最后一个** UP（第 1 轮轮不到它）
    SharedPreferences.setMockInitialValues({
      'inbox:upowner:${firstMid + total - 1}:unseen': jsonEncode([
        const InboxItem(
          upMid: firstMid + total - 1,
          upName: 'UP 最后的',
          upFace: '',
          bvid: 'BVSEED',
          title: '上一轮留下的',
          cover: '',
          duration: 60,
          pubDate: 1700000000,
        ).toJson(),
      ]),
      'inbox:meta:total_unseen': 1,
      'inbox:meta:checked_mids': jsonEncode([firstMid + total - 1]),
    });
    final adapter = _MidAdapter({
      for (var i = 0; i < total; i++)
        firstMid + i: () => [
              _v(
                bvid: 'BV${firstMid + i}',
                title: '新 ${firstMid + i}',
                created: 1701000000 + i,
              ),
              _v(bvid: 'BVOLD', created: 1700000000),
            ],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        for (var i = 0; i < total; i++)
          _up(mid: firstMid + i, lastSeenBvid: 'BVOLD'),
      ],
    )));
    // 间隔 0：250 个 UP × 3 轮要快速跑完（生产是 ≥1.5s/个）
    final svc = InboxService.fromApi(_api(adapter), requestGap: Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    final rounds = <Set<int>>[];

    for (var round = 1; round <= 3; round++) {
      final r = await svc.checkAll(force: true);
      expect(r.total, lessThanOrEqualTo(InboxService.kMaxUpowners),
          reason: '第 $round 轮：每轮检查的 UP 主数不能超过上限');
      final checked = (jsonDecode(prefs.getString('inbox:meta:checked_mids')!)
              as List)
          .map((e) => (e as num).toInt())
          .toSet();
      expect(checked.length, lessThanOrEqualTo(InboxService.kMaxUpowners),
          reason: '第 $round 轮：checked_mids 就是本轮的名单，≤ 上限');
      rounds.add(checked);

      final items = await svc.getItems();
      // ★ 不在本轮名单里的 UP 主的未读**不能被隐藏**（否则条目随轮次忽隐忽现）
      expect(items.any((e) => e.bvid == 'BVSEED'), isTrue,
          reason: '第 $round 轮：没轮到的 UP（${firstMid + total - 1}）的未读照样可见');
      if (round == 1) {
        // 第 1 轮：上一轮留下的 1 条 + 本轮 100 个 UP 各 1 条 = 101
        expect(checked.length, InboxService.kMaxUpowners);
        expect(items.length, 101, reason: '队列里既有本轮结果、也有没轮到的 UP 的旧未读');
        expect(
          items.where((e) => e.upMid >= firstMid + 100).map((e) => e.bvid),
          ['BVSEED'],
          reason: '第 101 个之后的 UP 本轮还没被检查（只剩那条旧未读）',
        );
      }
    }

    // ★ 三轮并集 = 全部 250 个 UP（轮转覆盖；不是永远只查前 100 个）
    final union = rounds.expand((s) => s).toSet();
    expect(union.length, total, reason: '三轮的 checked_mids 并集必须覆盖全部 $total 个 UP');
    expect(
      union,
      {for (var i = 0; i < total; i++) firstMid + i},
      reason: '逐个 mid 都要轮到',
    );
    expect(adapter.searchCalls, 3 * InboxService.kMaxUpowners,
        reason: '每轮恰好查 100 个（3 轮 300 次），没有漏掉也没有重复超量');
    // 全部 250 个 UP 的新视频最终都在队列里（+ 那条旧的）
    expect((await svc.getItems()).length, total + 1);
  });

  test('★ 轮转：UP 数 ≤ 上限时不做轮转（每轮都查全部，游标归零）', () async {
    final adapter = _MidAdapter({
      100: () => [_v(bvid: 'BV3', created: 1700000300)],
      200: () => [_v(bvid: 'BV9', created: 1700000900)],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [
        _up(mid: 100, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ],
    )));
    final svc = InboxService.fromApi(_api(adapter), requestGap: Duration.zero);

    for (var i = 0; i < 2; i++) {
      final r = await svc.checkAll(force: true);
      expect(r.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'},
          reason: '没超过上限 → 每轮都查全部（与老行为一致）');
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('inbox:meta:rotate_cursor'), 0);
  });

  // -------------------------------------------------------------------------
  // ★ v2.24.0 #3：拉取失败残留的「已处理」条目不再显示（卡片不复活）
  // -------------------------------------------------------------------------

  test('★ 已处理过滤：拉取失败 UP 残留在 prefs 里的已划过条目不再显示、也不计红点',
      () async {
    // 设备实测：handled_bvids 里已有 BV17kYu63EYb，而 upowner:…:unseen 里也是它
    // → 红点 1、卡片就是那张**已经划过**的卡（"我明明划掉了它又回来了"）。
    // 成因：该 UP 那轮撞 412 → 走 keep（按设计"一个字节都不动"）→ 没机会清掉
    // 已处理的条目。
    const bvid = 'BV17kYu63EYb';
    SharedPreferences.setMockInitialValues({
      'inbox:upowner:100:unseen': jsonEncode([
        const InboxItem(
          upMid: 100,
          upName: 'UP100',
          upFace: '',
          bvid: bvid,
          title: '已经划过的',
          cover: '',
          duration: 60,
          pubDate: 1700000300,
        ).toJson(),
      ]),
      'inbox:meta:total_unseen': 1,
      'inbox:meta:checked_mids': jsonEncode([100]),
    });
    await InboxHandledStore.instance.add(bvid);
    final adapter = _MidAdapter({
      100: () => [_v(bvid: 'BV1', created: 1700000100)],
    });
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100, lastSeenBvid: 'BV1')],
    )));
    final svc = InboxService.fromApi(_api(adapter), requestGap: Duration.zero);

    // 可见队列 / 红点都不算它（红点顺手被校正）
    expect(await svc.getItems(), isEmpty);
    expect(await svc.getUnseenCount(), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('inbox:meta:total_unseen'), 0);

    // 该 UP 继续撞 412（走 keep）→ 本地未读照旧不动，但返回值里也不能有它
    //（页面会把 checkAll 返回的新条目追加进卡片栈）
    adapter.failing.add(100);
    final r = await svc.checkAll(force: true);
    expect(r.items, isEmpty, reason: 'keep 的 UP 残留的已处理条目也不许回到队列');
    expect(await svc.getItems(), isEmpty);
    expect(await svc.getUnseenCount(), 0);
    // keep 语义不变：本地未读一个字节都没动（只是不显示）
    expect(prefs.getString('inbox:upowner:100:unseen'), isNotNull);
  });

  test('已处理过滤：撤销后条目正常回到队列与红点（不会误伤未处理的）', () async {
    final s = oneUp();
    final first = await s.svc.checkAll(force: true);
    await s.svc.markHandled('BV3');
    expect((await s.svc.getItems()).map((e) => e.bvid).toList(), ['BV2']);
    expect(await s.svc.getUnseenCount(), 1);

    await s.svc.unmarkHandled(first.items.first); // BV3 撤销
    expect((await s.svc.getItems()).map((e) => e.bvid).toSet(), {'BV3', 'BV2'});
    expect(await s.svc.getUnseenCount(), 2);
  });

  test('InboxHandledStore.dedupeFront：去重置顶 + 上限裁剪', () {
    expect(InboxHandledStore.dedupeFront(['a', 'b'], ['b', 'c']),
        ['b', 'c', 'a']);
    expect(InboxHandledStore.dedupeFront(['a', 'b'], ['a'], maxEntries: 2),
        ['a', 'b']);
    expect(InboxHandledStore.dedupeFront(['a', 'b'], ['c'], maxEntries: 2),
        ['c', 'a']);
    expect(InboxHandledStore.dedupeFront(['a'], const []), ['a']);
  });
}