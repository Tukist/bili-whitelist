// 直播「正在直播」标记（v2.25.2+，最小形态）测试。
//
// 覆盖：
// - **接口解析**：`https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld`
//   匿名可用（注意 host 是**直播域名**、路径**无 `/x/` 前缀**）—— 在播（1）/ 未播
//   （0）/ **轮播（2，无直播流）**；请求 host 与路径、`mid` 参数；非零业务码 /
//   脏 data / 网络失败 → **返回 null 不抛**（标记是纯装饰，失败必须静默）；
// - **节流 + 缓存**：同一 UP 主只查一次（会话内缓存）；同一个 mid 的并发调用
//   共享一个在途请求；不同 mid 之间**串行**且相邻请求间隔 ≥ gap；
// - **失败静默且不写缓存**：fetch 抛异常 → null，下次还会再试；
// - **UI**：UP 主页在播时出现「正在直播 · <标题>」，未播 / 轮播**不出现**；
//   信箱顶卡在播时出现角标（点它跳 B 站直播间的 url 由 LiveStatus.liveUrl 给）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/live_status.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';

// ---------------------------------------------------------------------------
// mock HTTP（API 层用例）
// ---------------------------------------------------------------------------

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];

  /// 按**路径**取请求。
  ///
  /// 同时匹配 `path` 与 `uri.path`：用绝对 URL 发出的请求（如直播接口的
  /// `https://api.live.bilibili.com/...`），`RequestOptions.path` 是完整 URL，
  /// 而 `uri.path` 才是 `/room/v1/...`——只按 `path` 匹配会把这类请求当成
  /// 「no handler」返回 404，让用例**假绿**（拿 null 也符合「失败静默」）。
  List<RequestOptions> forPath(String path) => requests
      .where((r) => r.path == path || r.uri.path == path)
      .toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final h = handlers[options.path] ?? handlers[options.uri.path];
    if (h == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(h(options)),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 断网 adapter。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

const String _kRoomPath = '/room/v1/Room/getRoomInfoOld';
const String _kSpiPath = '/x/frontend/finger/spi';

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

/// getRoomInfoOld 响应（字段名与实测一致）。
Map<String, dynamic> _roomBody({
  int code = 0,
  int roomStatus = 1,
  int liveStatus = 1,
  int? roomid = 21452505,
  String title = '一起来聊天',
  String url = 'https://live.bilibili.com/21452505',
}) =>
    {
      'code': code,
      if (code != 0) 'message': 'boom',
      'data': {
        'roomStatus': roomStatus,
        'liveStatus': liveStatus,
        'roomid': roomid,
        'title': title,
        'url': url,
      },
    };

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void _mockSecureStorage() {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    return null;
  });
}

// ---------------------------------------------------------------------------
// 替身（页面层用例：直接覆盖 BiliApi 的相关方法）
// ---------------------------------------------------------------------------

/// UP 主页用的假接口：信息/视频/合集都给「空但成功」，只把开播状态做成可控。
class _FakeApi extends BiliApi {
  _FakeApi({this.live});

  /// 返回的开播状态（null = 查不到）。
  final LiveStatus? live;

  int liveCalls = 0;

  @override
  Future<LiveStatus?> fetchLiveStatusByMid(int mid) async {
    liveCalls++;
    return live;
  }

  @override
  Future<int> fetchUpownerFollower(int mid) async => 1234;

  @override
  Future<UpownerInfo> fetchUpownerInfo(int mid) async =>
      const UpownerInfo(name: '测试UP主', face: '', sign: '');

  @override
  Future<UpownerVideosPage> fetchUpownerVideos(
    int mid, {
    int pn = 1,
    int ps = 20,
    String order = 'pubdate',
    String keyword = '',
  }) async =>
      const UpownerVideosPage(videos: [], totalCount: 0, hasMore: false);

  @override
  Future<UpownerCollectionsResult> fetchUpownerCollections(
    int mid, {
    int pageNum = 1,
    int pageSize = 20,
  }) async =>
      const UpownerCollectionsResult(seasons: [], series: []);
}

/// 假信箱服务（队列固定一条未读）。
class _FakeInboxService extends InboxService {
  _FakeInboxService(this.items);

  final List<InboxItem> items;

  @override
  Future<List<InboxItem>> getItems() async => items;

  @override
  Future<InboxCheckResult> checkAll({bool force = false}) async =>
      InboxCheckResult(total: 0, unseen: items.length, items: items);

  @override
  Future<void> markHandled(String bvid) async {}

  @override
  Future<void> unmarkHandled(InboxItem item) async {}

  @override
  Future<void> markAllRead() async {}
}

class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<SyncResult> sync() async => SyncResult(
        data: WhitelistData.empty(),
        sourceName: 'fake',
        fetchedAt: DateTime.now(),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

class _FakeGithubApi extends GithubApi {
  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() async => WhitelistData.empty();

  @override
  Future<bool> saveToGist(WhitelistData wl) async => true;
}

InboxItem _item({int mid = 100, String bvid = 'BV1a'}) => InboxItem(
      upMid: mid,
      upName: '测试UP主',
      upFace: '',
      bvid: bvid,
      title: '新视频 $bvid',
      cover: '',
      duration: 100,
      pubDate: 1700000000,
    );

/// 推进若干帧直到 [finder] 找到东西（最多 steps × 50ms）。
Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int steps = 40}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  setUp(() {
    MotionControl.enabled = false;
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({});
    LiveStatusHub.instance.clear();
  });

  tearDown(MotionControl.reset);

  group('API：getRoomInfoOld 解析（匿名可用）', () {
    test('直播中：roomId/标题/url 都解析出来，isLive=true', () async {
      final adapter = _Adapter({
        _kSpiPath: (_) => _spiBody(), // 匿名指纹（spi）；拿不到也不影响本接口
        _kRoomPath: (_) => _roomBody(),
      });
      final status = await _api(adapter).fetchLiveStatusByMid(946974);

      expect(status, isNotNull);
      expect(status!.mid, 946974);
      expect(status.roomId, 21452505);
      expect(status.liveStatus, LiveStatus.statusLive);
      expect(status.title, '一起来聊天');
      expect(status.isLive, isTrue);
      expect(status.liveUrl, 'https://live.bilibili.com/21452505');

      final req = adapter.forPath(_kRoomPath).single;
      expect(req.queryParameters, {
        'mid': '946974',
      }, reason: '白名单只存 mid，用它换 room_id + 开播状态');
      expect(req.method, 'GET');
    });

    test('请求打到 api.live.bilibili.com（不是 api.bilibili.com）', () async {
      final adapter = _Adapter({
        _kRoomPath: (_) => _roomBody(),
      });
      await _api(adapter).fetchLiveStatusByMid(946974);

      // 先确认真的命中了 handler（否则拿到 null 也会让本用例「过去」）
      final req = adapter.forPath(_kRoomPath).single;
      expect(req.uri.host, 'api.live.bilibili.com',
          reason: '直播接口在直播域名上；打到 api.bilibili.com 会 404，'
              '异常被 fetchLiveStatusByMid 的 catch 静默吞掉 → 标记永不显示');
      expect(req.uri.host, isNot('api.bilibili.com'));
      expect(req.uri.scheme, 'https');
      expect(req.uri.path, _kRoomPath, reason: '直播域名下路径**无 /x/ 前缀**');
      expect(req.uri.toString(),
          startsWith('https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld'));
      // 宿主（*_api 里注入的）baseUrl 仍是普通 API 域名：靠绝对 URL 定向，
      // 不动全局 baseUrl（否则会波及全部接口）
      expect(req.baseUrl, kBiliApi);
    });

    test('未开播：仍返回状态对象（isLive=false）', () async {
      final adapter = _Adapter({
        _kRoomPath: (_) => _roomBody(liveStatus: 0, title: ''),
      });
      final status = await _api(adapter).fetchLiveStatusByMid(946974);
      expect(status, isNotNull);
      expect(status!.liveStatus, LiveStatus.statusOff);
      expect(status.isLive, isFalse);
    });

    test('轮播（liveStatus=2）：**不当在播**（没有直播流）', () async {
      final adapter = _Adapter({
        _kRoomPath: (_) => _roomBody(liveStatus: 2),
      });
      final status = await _api(adapter).fetchLiveStatusByMid(946974);
      expect(status, isNotNull);
      expect(status!.liveStatus, LiveStatus.statusLoop);
      expect(status.isLive, isFalse, reason: '轮播不是直播');
    });

    test('脏数据 / 未知形态不崩：roomid 是字符串、负数、缺失都给安全默认',
        () async {
      // 字符串 roomid
      final s = LiveStatus.fromRoomInfoOld(1, {
        'liveStatus': '1',
        'roomid': '9527',
        'title': 't',
      });
      expect(s.roomId, 9527);
      expect(s.liveStatus, 1);
      expect(s.isLive, isTrue);

      // 全脏（null / 类型错）
      final dirty = LiveStatus.fromRoomInfoOld(2, {
        'roomid': null,
        'liveStatus': {'x': 1},
        'title': 42,
        'url': false,
      });
      expect(dirty.roomId, 0);
      expect(dirty.liveStatus, 0);
      expect(dirty.title, '');
      expect(dirty.url, '');
      expect(dirty.isLive, isFalse);
      expect(dirty.liveUrl, '', reason: '没有 roomId 也没有 url → 不可跳转');
    });

    test('code != 0 / data 缺失 / mid 非法 → null（不抛）', () async {
      final bad = _Adapter({
        _kRoomPath: (_) => _roomBody(code: -352),
      });
      expect(await _api(bad).fetchLiveStatusByMid(1), isNull);

      final noData = _Adapter({
        _kRoomPath: (_) => {'code': 0},
      });
      expect(await _api(noData).fetchLiveStatusByMid(1), isNull);

      final any = _Adapter({});
      expect(await _api(any).fetchLiveStatusByMid(0), isNull,
          reason: 'mid 非法直接返回，不打接口');
      expect(any.requests, isEmpty);
    });

    test('网络失败 → null（失败静默，标记不显示）', () async {
      expect(await _api(_ThrowingAdapter()).fetchLiveStatusByMid(1), isNull);
    });
  });

  group('LiveStatusHub：会话内缓存 + 串行节流 + 失败静默', () {
    test('同一 UP 主只查一次（缓存命中不再打接口）', () async {
      final hub = LiveStatusHub(gap: Duration.zero);
      var calls = 0;
      Future<LiveStatus?> fetch(int mid) async {
        calls++;
        return const LiveStatus(mid: 1, roomId: 7, liveStatus: 1);
      }

      final a = await hub.statusOf(1, fetch: fetch);
      final b = await hub.statusOf(1, fetch: fetch);
      expect(calls, 1, reason: '会话内缓存');
      expect(a!.roomId, 7);
      expect(b!.roomId, 7);
      expect(hub.hasCached(1), isTrue);

      // refresh = true → 忽略缓存重查
      await hub.statusOf(1, fetch: fetch, refresh: true);
      expect(calls, 2);
    });

    test('「没在播」也缓存（null 结果同样记住，不反复打接口）', () async {
      final hub = LiveStatusHub(gap: Duration.zero);
      var calls = 0;
      Future<LiveStatus?> fetch(int mid) async {
        calls++;
        return const LiveStatus(mid: 1, roomId: 7, liveStatus: 0);
      }

      await hub.statusOf(1, fetch: fetch);
      await hub.statusOf(1, fetch: fetch);
      expect(calls, 1);
      expect(hub.hasCached(1), isTrue);
      expect(hub.cached(1)!.isLive, isFalse);
    });

    test('同一 mid 并发调用共享在途请求（不会打两次）', () async {
      final hub = LiveStatusHub(gap: Duration.zero);
      var calls = 0;
      Future<LiveStatus?> fetch(int mid) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return const LiveStatus(mid: 1, roomId: 7, liveStatus: 1);
      }

      final results = await Future.wait([
        hub.statusOf(1, fetch: fetch),
        hub.statusOf(1, fetch: fetch),
        hub.statusOf(1, fetch: fetch),
      ]);
      expect(calls, 1, reason: '共享一个在途 Future');
      expect(results.every((r) => r!.roomId == 7), isTrue);
    });

    test('不同 UP 主：串行 + 相邻请求间隔 ≥ gap（不可并发轰炸）', () async {
      final hub = LiveStatusHub(gap: const Duration(milliseconds: 60));
      final starts = <int, DateTime>{};
      var running = 0;
      var maxConcurrent = 0;
      Future<LiveStatus?> fetch(int mid) async {
        starts[mid] = DateTime.now();
        running++;
        maxConcurrent = running > maxConcurrent ? running : maxConcurrent;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        return LiveStatus(mid: mid, roomId: mid, liveStatus: 1);
      }

      await Future.wait([
        hub.statusOf(1, fetch: fetch),
        hub.statusOf(2, fetch: fetch),
        hub.statusOf(3, fetch: fetch),
      ]);

      expect(maxConcurrent, 1, reason: '同一时刻只允许一个 live 请求在飞');
      expect(hub.debugRequestCount, 3);
      final gap12 = starts[2]!.difference(starts[1]!);
      final gap23 = starts[3]!.difference(starts[2]!);
      expect(gap12.inMilliseconds, greaterThanOrEqualTo(55),
          reason: '相邻两次请求间隔 ≥ gap（这里留 5ms 抖动余量）');
      expect(gap23.inMilliseconds, greaterThanOrEqualTo(55));
    });

    test('失败静默且不写缓存（下次进页还能再试）', () async {
      final hub = LiveStatusHub(gap: Duration.zero);
      var calls = 0;
      Future<LiveStatus?> fetch(int mid) async {
        calls++;
        throw StateError('boom');
      }

      expect(await hub.statusOf(1, fetch: fetch), isNull, reason: '不抛，返回 null');
      expect(hub.hasCached(1), isFalse, reason: '失败不写缓存');
      await hub.statusOf(1, fetch: fetch);
      expect(calls, 2, reason: '失败后允许重试');
    });
  });

  group('UI：UP 主页 / 信箱顶卡 的开播标记', () {
    testWidgets('UP 主页：在播 → 「正在直播 · 标题」上屏（点它能跳）',
        (tester) async {
      final api = _FakeApi(
        live: const LiveStatus(
          mid: 546195,
          roomId: 21452505,
          liveStatus: 1,
          title: '一起来聊天',
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: UpownerPage(mid: 546195, api: api),
      ));
      await _pumpUntil(tester, find.byType(LiveNowBadge));

      expect(api.liveCalls, 1);
      expect(find.text('正在直播 · 一起来聊天'), findsOneWidget);
      final badge = tester.widget<LiveNowBadge>(find.byType(LiveNowBadge));
      expect(badge.title, '一起来聊天');
      // 触摸目标 ≥48dp（视觉是矮胶囊，热区是整行）
      final size = tester.getSize(find.byType(LiveNowBadge));
      expect(size.height, 48);
    });

    testWidgets('UP 主页：未开播 / 轮播都不显示标记', (tester) async {
      for (final status in [
        const LiveStatus(mid: 546195, roomId: 21452505, liveStatus: 0),
        const LiveStatus(
          mid: 546195,
          roomId: 21452505,
          liveStatus: 2, // 轮播：不该当在播
          title: '录播轮播中',
        ),
      ]) {
        LiveStatusHub.instance.clear();
        final api = _FakeApi(live: status);
        await tester.pumpWidget(MaterialApp(
          home: UpownerPage(mid: 546195, api: api),
        ));
        await _pumpUntil(tester, find.text('测试UP主'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(LiveNowBadge), findsNothing,
            reason: 'liveStatus=${status.liveStatus} 不该显示标记');
      }
    });

    testWidgets('信箱顶卡：队首作者在播 → 卡片上出现角标', (tester) async {
      ServiceLocator.overrideInboxService(_FakeInboxService([_item()]));
      ServiceLocator.overrideSyncService(_FakeSyncService());
      final api = _FakeApi(
        live: const LiveStatus(
          mid: 100,
          roomId: 21452505,
          liveStatus: 1,
          title: '开播了',
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: InboxPage(
          api: api,
          writer: WhitelistWriter(github: _FakeGithubApi(), api: api),
        ),
      ));
      await _pumpUntil(tester, find.byType(LiveNowBadge));

      expect(find.text('正在直播 · 开播了'), findsOneWidget);
      expect(api.liveCalls, 1, reason: '只查队首这一张，不为一整队未读轰炸');
      expect(find.text('新视频 BV1a'), findsOneWidget, reason: '卡片内容照旧');
    });

    testWidgets('信箱顶卡：查不到开播状态 → 没有角标，页面也不出错',
        (tester) async {
      ServiceLocator.overrideInboxService(_FakeInboxService([_item()]));
      ServiceLocator.overrideSyncService(_FakeSyncService());
      final api = _FakeApi(live: null); // 失败/未播一律 null
      await tester.pumpWidget(MaterialApp(
        home: InboxPage(
          api: api,
          writer: WhitelistWriter(github: _FakeGithubApi(), api: api),
        ),
      ));
      await _pumpUntil(tester, find.text('新视频 BV1a'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(LiveNowBadge), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
