// InboxService 单元测试（mock dio + 内存 shared_preferences）：
// - checkAll：白名单空 → 0/0；UP 主有 lastSeenBvid → diff 出未读条目
// - checkAll：节流命中（< 30min）→ 返回缓存不触网
// - markAllRead：清空 unseen + 写 last_check_at
// - getItems：按 pub_date 倒序输出所有条目
// - getUnseenCount：从 prefs 读
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
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

  test('UP 主无 lastSeenBvid（首次检查）→ 0 未读（避免堆积历史）', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([
            _v(bvid: 'BV3'),
            _v(bvid: 'BV2'),
          ]),
    });
    final api = _api(adapter);
    final data = WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: [_up(mid: 100)], // 无 lastSeenBvid
    );
    ServiceLocator.overrideSyncService(_FakeSyncService(data));
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll(force: true);
    expect(result.unseen, 0);
    expect(result.items, isEmpty);
  });

  test('节流命中（< 30min）→ 返回缓存不触网', () async {
    final adapter = _RoutingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/arc/search': () => _videoListBody([]),
    });
    final api = _api(adapter);
    // 预设 last_check_at 为 5 分钟前 → 节流命中
    SharedPreferences.setMockInitialValues({
      'inbox:meta:last_check_at':
          DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
      'inbox:meta:total_unseen': 7,
    });
    final svc = InboxService.fromApi(api);

    final result = await svc.checkAll();
    // 节流命中 → 不发请求（adapter.requests 只有 spi/nav，没有 arc/search）
    expect(
      adapter.requests.where((r) => r.path == '/x/space/wbi/arc/search'),
      isEmpty,
    );
    expect(result.unseen, 7);
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
}