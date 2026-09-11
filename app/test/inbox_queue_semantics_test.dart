// 信箱「队列语义」审计测试（v2.19.0+）。
//
// 用户期望的语义：**抓取（checkAll）只是入队**，队列持久、只增不减；只有
// **卡片操作**（右滑加入 / 左滑跳过 / 底部按钮）才把条目**释放**（消费）出队。
// 本文件把下面 8 条逐条钉住（每条都有断言，不依赖间接覆盖）：
//   S1 反复 checkAll 不丢队列   → group('S1 …')
//   S2 打开信箱页不消费         → group('S2 …')（★ 真 service + 真页面端到端）
//   S3 只有卡片操作才消费       → group('S3 …')（列出合法消费入口）
//   S4 冷启动后队列仍在         → group('S4 …')（★ 新实例 = 模拟杀进程重开）
//   S5 基线推进时机             → group('S5 …')
//   S6 检查失败不丢队列         → group('S6 …')
//   S7 撤销回队                 → group('S7 …')
//   S8 红点 == 队列条数         → group('S8 …')
//
// 另有一个**现状锁定**用例（group('边界 …')）：每个 UP 只拉首页 5 条
// （`kUnseenPerUpowner = 5`，配 `ps: 5`），两次检查之间该 UP 发 >5 条时，
// 更早的那些永远进不了队列。这是既有取舍，修不修由产品定，本文件只记录现状。
//
// 接口全部走内存替身（不触网 / 不触原生插件 / 不碰真实 Gist）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/services/inbox_handled_store.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/inbox_swipe_card.dart';

// ---------------------------------------------------------------------------
// 原生插件替身（BiliApi._injectAuth 会读 secure storage）
// ---------------------------------------------------------------------------

final Map<String, String> _secure = {};

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return _secure[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        _secure[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        _secure.remove(args['key'] as String?);
        return true;
      default:
        return null;
    }
  });
}

// ---------------------------------------------------------------------------
// 按 mid 路由的 dio 适配器（支持「服务端分页窗口」语义）
// ---------------------------------------------------------------------------

/// 记录一次 UP 主视频列表请求（用来证明"永远只请求第 1 页"）。
typedef _ArcRequest = ({int mid, int pn, int ps});

class _MidAdapter implements HttpClientAdapter {
  _MidAdapter(this.videos, {Set<int>? riskControl, Set<int>? networkFail})
      : riskControl = riskControl ?? <int>{},
        networkFail = networkFail ?? <int>{};

  /// mid → 该 UP 主的**全量**视频列表生成器（适配器按 pn/ps 切窗口，
  /// 与真实接口一致：服务端只返回请求的那一页）。
  final Map<int, List<Map<String, dynamic>> Function()> videos;

  /// 这些 mid 返回 -412（风控/限流）。
  final Set<int> riskControl;

  /// 这些 mid 抛 [DioException]（网络异常）。
  final Set<int> networkFail;

  /// 这些 mid 返回业务错误码（非风控，如 62002 稿件已失效）。
  final Map<int, int> bizFail = {};

  final List<_ArcRequest> arcRequests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    switch (options.path) {
      case '/x/frontend/finger/spi':
        return _json(_spiBody());
      case '/x/web-interface/nav':
        return _json(_navBody());
      case '/x/space/wbi/arc/search':
        final mid = int.tryParse('${options.queryParameters['mid']}') ?? -1;
        final pn = int.tryParse('${options.queryParameters['pn']}') ?? 1;
        final ps = int.tryParse('${options.queryParameters['ps']}') ?? 20;
        arcRequests.add((mid: mid, pn: pn, ps: ps));
        if (networkFail.contains(mid)) {
          throw DioException(
            requestOptions: options,
            message: '模拟网络异常',
            type: DioExceptionType.connectionError,
          );
        }
        if (riskControl.contains(mid)) {
          return _json({'code': -412, 'message': '请求过于频繁，请稍后再试'});
        }
        final biz = bizFail[mid];
        if (biz != null) {
          return _json({'code': biz, 'message': '业务错误 $biz'});
        }
        final all = videos[mid]?.call() ?? const <Map<String, dynamic>>[];
        final from = (pn - 1) * ps;
        if (from >= all.length) {
          return _json(_videoListBody(const []));
        }
        final to = from + ps > all.length ? all.length : from + ps;
        return _json(_videoListBody(all.sublist(from, to)));
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

Map<String, dynamic> _videoListBody(List<Map<String, dynamic>> vlist) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'list': {'vlist': vlist},
      },
    };

Map<String, dynamic> _v({
  required String bvid,
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

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

// ---------------------------------------------------------------------------
// 同步 / Gist 替身
// ---------------------------------------------------------------------------

class _FakeSyncService extends WhitelistSyncService {
  _FakeSyncService(this.data);

  final WhitelistData data;

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

/// 永远抛异常的 sync 替身（模拟 Gist/LAN/本地缓存全失败）。
class _DeadSyncService extends WhitelistSyncService {
  @override
  Future<SyncResult> sync() async => throw StateError('所有白名单源都不可用');

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 内存版 GitHub：让 `UpownerWriter.updateLastSeenBatch` 真能"写盘"，
/// `saves` 就是「基线写了几次」的观察点。
class _MemoryGithubApi extends GithubApi {
  _MemoryGithubApi(this.data);

  WhitelistData data;
  int saves = 0;

  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() async => data;

  @override
  Future<bool> saveToGist(WhitelistData wl) async {
    data = wl;
    saves++;
    return true;
  }
}

/// 跟着内存 GitHub 走的 sync 替身：基线写盘后下一次 sync 就能读到。
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

// ---------------------------------------------------------------------------
// 数据构造 / 断言小工具
// ---------------------------------------------------------------------------

Upowner _up({required int mid, String? lastSeenBvid}) => Upowner(
      mid: mid,
      name: 'UP$mid',
      face: '',
      addedAt: DateTime.utc(2026, 1, 1),
      lastSeenBvid: lastSeenBvid,
    );

WhitelistData _whitelist(List<Upowner> ups) => WhitelistData(
      version: 4,
      updatedAt: '',
      videos: const [],
      upowners: ups,
    );

/// 一条 prefs 里的未读条目（字段名对齐 `InboxItem.toJson`）。
Map<String, dynamic> _q(String bvid, String title, int pubDate, {int mid = 100}) =>
    {
      'up_mid': mid,
      'up_name': 'UP$mid',
      'up_face': '',
      'bvid': bvid,
      'title': title,
      'cover': '',
      'duration': 60,
      'pub_date': pubDate,
    };

const int _kMid = 100;

/// 冲掉一串 `await`（替身接口都是立刻完成的 Future）+ 收敛动效。
/// 与 `inbox_swipe_test.dart` 的 `_flush` 同构。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 共用装配（真 InboxService + 内存 prefs + 内存 Gist）
  // -------------------------------------------------------------------------

  /// 1 个 UP（mid=100，基线 BV1）+ 首页三条（BV3/BV2 未读）。
  ({_MidAdapter adapter, InboxService svc, _MemoryGithubApi github}) oneUp() {
    final github = _MemoryGithubApi(
      _whitelist([_up(mid: _kMid, lastSeenBvid: 'BV1')]),
    );
    final videos = [
      _v(bvid: 'BV3', title: '新视频 3', created: 1700000300),
      _v(bvid: 'BV2', title: '新视频 2', created: 1700000200),
      _v(bvid: 'BV1', title: '已读基线', created: 1700000100),
    ];
    final adapter = _MidAdapter({_kMid: () => videos});
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

  /// 直接往 prefs 里种一份「已经抓好的队列」（模拟上一次运行留下的队列）。
  ///
  /// `last_check_at` 特意写成很久以前 —— S2 用例靠"它被刷新成当前时间"
  /// 来证明页面那次 force 检查**真的跑完**了（而不是断言在等待中途通过）。
  void seedQueue(
    List<Map<String, dynamic>> items, {
    List<int> checkedMids = const [_kMid],
  }) {
    SharedPreferences.setMockInitialValues({
      'inbox:upowner:$_kMid:unseen': jsonEncode(items),
      'inbox:meta:total_unseen': items.length,
      'inbox:meta:checked_mids': jsonEncode(checkedMids),
      'inbox:meta:last_check_at':
          DateTime.utc(2020, 1, 1).toIso8601String(),
    });
  }

  /// prefs 里所有未读 key 的 bvid（按 key 顺序，逐条展开）。
  Future<List<String>> queueInPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String>[];
    for (final key in prefs.getKeys().where(
      (k) => k.startsWith('inbox:upowner:') && k.endsWith(':unseen'),
    )) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      out.addAll([
        for (final e in jsonDecode(raw) as List) (e as Map)['bvid'] as String,
      ]);
    }
    return out;
  }

  Future<List<String>> queueOf(InboxService svc) async =>
      [for (final it in await svc.getItems()) it.bvid];

  /// 把「真 InboxService + 真 InboxPage」接起来（S2 用）。
  ({_MidAdapter adapter, InboxService svc, _MemoryGithubApi github}) wireRealPage(
    List<Map<String, dynamic>> videos,
  ) {
    final github = _MemoryGithubApi(
      _whitelist([_up(mid: _kMid, lastSeenBvid: 'BV1')]),
    );
    final adapter = _MidAdapter({_kMid: () => videos});
    final svc = InboxService.fromApi(
      _api(adapter),
      upownerWriter: UpownerWriter(github: github),
    );
    ServiceLocator.overrideSyncService(_MemorySyncService(github));
    ServiceLocator.overrideInboxService(svc);
    return (adapter: adapter, svc: svc, github: github);
  }

  Future<void> pumpRealInboxPage(WidgetTester tester, _MidAdapter adapter) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _api(adapter);
    await tester.pumpWidget(MaterialApp(
      home: InboxPage(
        api: api,
        writer: WhitelistWriter(
          github: _MemoryGithubApi(WhitelistData.empty()),
          api: api,
        ),
      ),
    ));
    await _flush(tester);
  }

  setUp(() {
    _secure.clear();
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({});
    ServiceLocator.overrideSyncService(_FakeSyncService(WhitelistData.empty()));
    MotionControl.reset(); // 测试环境默认关动效（松手即出栈、可 settle）
  });
  tearDown(MotionControl.reset);

  // =========================================================================
  // S1 反复 checkAll 不丢队列
  // =========================================================================
  group('S1 反复 checkAll 不丢队列（抓取 = 入队，不是消费）', () {
    test('连续 3 次 force checkAll：条目不变、不重复、基线不动、不写 Gist',
        () async {
      final s = oneUp();
      for (var i = 1; i <= 3; i++) {
        final r = await s.svc.checkAll(force: true);
        expect(r.items.map((e) => e.bvid).toList(), ['BV3', 'BV2'],
            reason: '第 $i 次 checkAll 的队列必须与第 1 次完全一致');
        expect(r.unseen, 2);
      }
      expect(await queueOf(s.svc), ['BV3', 'BV2']);
      expect(await s.svc.getUnseenCount(), 2);
      expect(s.github.data.upowners.single.lastSeenBvid, 'BV1',
          reason: '用户一条都没处理 → 基线不许动（检测 ≠ 已读确认）');
      expect(s.github.saves, 0, reason: '没有已读确认就不该写 Gist');
    });

    test('已入队条目滑出首页 5 条窗口后仍在（队列只增不减、不重复）', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true); // 队列 = BV3、BV2

      // UP 又发了一堆：首页窗口（ps: 5）里已经没有 BV3/BV2，基线 BV1 也不在
      s.adapter.videos[_kMid] = () => [
            _v(bvid: 'BV8', created: 1700000800),
            _v(bvid: 'BV7', created: 1700000700),
            _v(bvid: 'BV6', created: 1700000600),
            _v(bvid: 'BV5', created: 1700000500),
            _v(bvid: 'BV4', created: 1700000400),
          ];
      final r = await s.svc.checkAll(force: true);

      final bvids = r.items.map((e) => e.bvid).toList();
      expect(bvids.toSet(), {'BV8', 'BV7', 'BV6', 'BV5', 'BV4', 'BV3', 'BV2'},
          reason: '新候选进队、旧条目一个都不能掉');
      expect(bvids.length, 7, reason: '按 bvid 去重 → 没有重复条目');
      expect(bvids.first, 'BV8', reason: '队列按发布时间倒序');
      expect(await s.svc.getUnseenCount(), 7);
    });

    test('节流命中的 checkAll（首页启动 5s 自动检查那条路）也不消费', () async {
      // playlist_page 启动 5s 后会调一次「不带 force 的 checkAll」；
      // 距上次 < 30min 时走节流分支（只读缓存，连写盘都没有）。
      final s = oneUp();
      await s.svc.checkAll(force: true); // 写入队列 + last_check_at=现在

      final prefs = await SharedPreferences.getInstance();
      final queueBefore = prefs.getString('inbox:upowner:$_kMid:unseen');
      final r = await s.svc.checkAll(); // 不带 force → 节流命中
      expect(r.failed, isFalse);
      expect(r.items.map((e) => e.bvid).toList(), ['BV3', 'BV2']);
      expect(r.unseen, 2);
      expect(prefs.getString('inbox:upowner:$_kMid:unseen'), queueBefore,
          reason: '节流分支不该动队列（一个字节都不写）');
      expect(await queueOf(s.svc), ['BV3', 'BV2']);
    });
  });

  // =========================================================================
  // S2 打开信箱页不消费（本轮重点，端到端）
  // =========================================================================
  group('S2 打开信箱页不消费（真 service + 真页面）', () {
    final seeded = [
      _q('BV3', '新视频 3', 1700000300),
      _q('BV2', '新视频 2', 1700000200),
    ];

    for (final (name, videos) in <(String, List<Map<String, dynamic>>)>[
      (
        '有候选新视频',
        [
          _v(bvid: 'BV3', title: '新视频 3', created: 1700000300),
          _v(bvid: 'BV2', title: '新视频 2', created: 1700000200),
          _v(bvid: 'BV1', created: 1700000100),
        ],
      ),
      ('首页窗口里只剩基线（无候选）', [_v(bvid: 'BV1', created: 1700000100)]),
      ('服务端返回空窗口', const []),
    ]) {
      testWidgets('队列已有 2 条 + $name → force 检查跑完后卡片栈仍是那 2 条',
          (tester) async {
        seedQueue(seeded);
        final h = wireRealPage(videos);
        await pumpRealInboxPage(tester, h.adapter);

        // ① 那次 force 检查确实跑完了：last_check_at 被刷新成"刚刚"
        //    （seedQueue 把它写成 2020 年；跑完 checkAll 才会更新）
        final prefs = await SharedPreferences.getInstance();
        final lastCheck =
            DateTime.parse(prefs.getString('inbox:meta:last_check_at')!);
        expect(DateTime.now().toUtc().difference(lastCheck).inMinutes, lessThan(1),
            reason: '页面 initState 的 checkAll(force: true) 必须已经跑完');

        // ② 队列在 UI 上一条不少（★ 「时不时清空」的回归点）
        expect(find.byType(InboxSwipeCard), findsNWidgets(2),
            reason: '打开页面不能消费队列');
        expect(find.byType(AppStateView), findsNothing, reason: '不该掉进空态');
        expect(find.text('新视频 3'), findsOneWidget);
        expect(find.text('新视频 2'), findsOneWidget);

        // ③ 持久层也没被改小
        expect(await queueInPrefs(), ['BV3', 'BV2']);
        expect(prefs.getInt('inbox:meta:total_unseen'), 2);

        // ④ 看页面 ≠ 处理过：没有记「已处理」，基线也没推进
        expect(await InboxHandledStore.instance.getAll(), isEmpty);
        expect(h.github.saves, 0);
        expect(h.github.data.upowners.single.lastSeenBvid, 'BV1');
      });
    }

    testWidgets('页面里点一下卡片（打开播放页链路）也不消费队列', (tester) async {
      seedQueue(seeded);
      final h = wireRealPage([
        _v(bvid: 'BV3', title: '新视频 3', created: 1700000300),
        _v(bvid: 'BV2', title: '新视频 2', created: 1700000200),
        _v(bvid: 'BV1', created: 1700000100),
      ]);
      await pumpRealInboxPage(tester, h.adapter);

      // 点按 → fetchVideoMeta（假 adapter 无此路由 → 报错但路径被走到）
      await tester.tap(find.byType(InboxSwipeCard).last);
      await _flush(tester);

      expect(find.byType(InboxSwipeCard), findsNWidgets(2),
          reason: '点开看 ≠ 处理掉，卡片必须还在');
      expect(await queueInPrefs(), ['BV3', 'BV2']);
      expect(await InboxHandledStore.instance.getAll(), isEmpty);
    });
  });

  // =========================================================================
  // S3 只有卡片操作才消费
  // =========================================================================
  group('S3 消费入口只有两个：卡片操作 + 用户显式「全部标记已读」', () {
    test('卡片操作（markHandled）→ 消费；这是唯一的自动/增量入口', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);
      await s.svc.markHandled('BV3');
      expect(await queueOf(s.svc), ['BV2']);
      expect(await s.svc.getUnseenCount(), 1);
      expect(await InboxHandledStore.instance.getAll(), {'BV3'});
    });

    test('「全部标记已读」= 用户显式动作 → 允许清空（与卡片并列的合法入口）',
        () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);
      expect(await queueOf(s.svc), isNotEmpty);

      await s.svc.markAllRead();
      expect(await queueOf(s.svc), isEmpty);
      expect(await s.svc.getUnseenCount(), 0);
    });

    test('UP 被移出白名单 → 队列只是"隐藏"（prefs 里还在），不是被删掉', () async {
      // 白名单里 100 有 1 条未读，之后白名单换成只有 200
      seedQueue([_q('BV3', '新视频 3', 1700000300)]);
      final github = _MemoryGithubApi(
        _whitelist([_up(mid: 200, lastSeenBvid: 'BV8')]),
      );
      final adapter = _MidAdapter({
        200: () => [_v(bvid: 'BV9', created: 1700000900)],
      });
      ServiceLocator.overrideSyncService(_MemorySyncService(github));
      final svc = InboxService.fromApi(
        _api(adapter),
        upownerWriter: UpownerWriter(github: github),
      );

      await svc.checkAll(force: true);
      expect(await queueOf(svc), ['BV9'], reason: '100 不在白名单里 → 不显示它的队列');
      expect(await queueInPrefs(), contains('BV3'),
          reason: '只是过滤掉，没被 remove（重新加回白名单就能恢复）');

      // 加回来 → 旧队列还在
      github.data = _whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ]);
      await svc.checkAll(force: true);
      expect((await queueOf(svc)).toSet(), {'BV3', 'BV9'});
    });
  });

  // =========================================================================
  // S4 冷启动后队列仍在（持久化）
  // =========================================================================
  group('S4 冷启动后队列仍在（杀进程重开）', () {
    test('checkAll 写盘 → 新实例读得到同一队列', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);

      // 冷启动：全新 service 实例，只共享同一份 prefs
      final cold = InboxService.fromApi(_api(_MidAdapter(const {})));
      expect(await queueOf(cold), ['BV3', 'BV2']);
      expect(await cold.getUnseenCount(), 2);
    });

    test('冷启动后立刻再 checkAll（首页窗口无候选）→ 队列照样不丢', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);

      final coldAdapter = _MidAdapter({
        _kMid: () => [_v(bvid: 'BV1', created: 1700000100)],
      });
      ServiceLocator.overrideSyncService(_MemorySyncService(s.github));
      final cold = InboxService.fromApi(
        _api(coldAdapter),
        upownerWriter: UpownerWriter(github: s.github),
      );

      final r = await cold.checkAll(force: true);
      expect(r.items.map((e) => e.bvid).toList(), ['BV3', 'BV2']);
      expect(await queueOf(cold), ['BV3', 'BV2']);
      expect(await cold.getUnseenCount(), 2);
    });

    test('消费一条后冷启动 → 只剩未处理的那条（已处理记录也是持久的）', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);
      await s.svc.markHandled('BV3');

      final cold = InboxService.fromApi(_api(_MidAdapter(const {})));
      expect(await queueOf(cold), ['BV2']);
      expect(await cold.getUnseenCount(), 1);
      // 冷启动再 checkAll：BV3 不会因为"首页还有它"就重新冒出来
      final coldAdapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV2', created: 1700000200),
              _v(bvid: 'BV1', created: 1700000100),
            ],
      });
      ServiceLocator.overrideSyncService(_MemorySyncService(s.github));
      final cold2 = InboxService.fromApi(
        _api(coldAdapter),
        upownerWriter: UpownerWriter(github: s.github),
      );
      expect((await cold2.checkAll(force: true)).items.map((e) => e.bvid).toList(),
          ['BV2']);
    });
  });

  // =========================================================================
  // S5 基线推进时机
  // =========================================================================
  group('S5 基线只在「该 UP 队列全被处理完」后推进，且推进成功才清记录', () {
    test('队列里还有未处理条目 → 完全不调用 updateLastSeenBatch', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);
      await s.svc.checkAll(force: true);
      expect(s.github.saves, 0, reason: '还有没处理完的条目 → 一次都不该写基线');
      expect(s.github.data.upowners.single.lastSeenBvid, 'BV1');
    });

    test('只处理了一部分 → 不推进基线（剩下没看的不能算已读）', () async {
      final s = oneUp();
      await s.svc.checkAll(force: true);
      await s.svc.markHandled('BV3');

      final r = await s.svc.checkAll(force: true);
      expect(r.items.map((e) => e.bvid).toList(), ['BV2']);
      expect(s.github.saves, 0);
      expect(s.github.data.upowners.single.lastSeenBvid, 'BV1');
      expect(await InboxHandledStore.instance.getAll(), contains('BV3'),
          reason: '基线没推进 → 已处理记录必须留着（否则 BV3 会重新冒出来）');
    });

    // 「全处理完 → 推进到最新 + 清已处理记录」「写失败 → 记录保留」两条
    // 由 test/inbox_service_test.dart 覆盖（用例名见下）：
    //   - 某 UP 未读全部处理完 → 基线推进到最新（下次不再产生同一批）
    //   - 基线写盘失败时不清「已处理」记录（避免卡片重新冒出来）
  });

  // =========================================================================
  // S6 检查失败不丢队列
  // =========================================================================
  group('S6 检查失败不丢队列', () {
    final seeded = [
      _q('BV3', '新视频 3', 1700000300),
      _q('BV2', '新视频 2', 1700000200),
    ];

    test('冷启动首次检查就 sync 全失败（还没写过 checked_mids）→ 队列仍完整返回',
        () async {
      seedQueue(seeded);
      ServiceLocator.overrideSyncService(_DeadSyncService());
      final svc = InboxService.fromApi(_api(_MidAdapter(const {})));

      final r = await svc.checkAll(force: true);
      expect(r.failed, isTrue);
      expect(r.message, isNotEmpty);
      expect(r.items.map((e) => e.bvid).toList(), ['BV3', 'BV2']);
      expect(await queueOf(svc), ['BV3', 'BV2']);
      expect(await svc.getUnseenCount(), 2);
    });

    test('单个 UP 网络异常（DioException）→ 该 UP 队列一个字节不动', () async {
      final adapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV1', created: 1700000100),
            ],
        200: () => [
              _v(bvid: 'BV9', created: 1700000900),
              _v(bvid: 'BV8', created: 1700000800),
            ],
      });
      ServiceLocator.overrideSyncService(_FakeSyncService(_whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ])));
      final svc = InboxService.fromApi(_api(adapter));

      final first = await svc.checkAll(force: true);
      expect(first.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'});

      adapter.networkFail.add(_kMid);
      final second = await svc.checkAll(force: true);
      expect(second.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'},
          reason: '网络失败的 UP 主，卡片不能凭空消失');
      expect((await queueOf(svc)).toSet(), {'BV3', 'BV9'});
      expect(await svc.getUnseenCount(), 2);
      // 成功的那个 UP 主照常工作
      expect(adapter.arcRequests.where((q) => q.mid == 200), isNotEmpty);
    });

    test('单个 UP 业务异常（62002 稿件已失效）→ 该 UP 队列不动', () async {
      final adapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV1', created: 1700000100),
            ],
        200: () => [
              _v(bvid: 'BV9', created: 1700000900),
              _v(bvid: 'BV8', created: 1700000800),
            ],
      });
      ServiceLocator.overrideSyncService(_FakeSyncService(_whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ])));
      final svc = InboxService.fromApi(_api(adapter));
      await svc.checkAll(force: true);

      adapter.bizFail[200] = 62002;
      final r = await svc.checkAll(force: true);
      expect(r.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'});
      expect((await queueOf(svc)).toSet(), {'BV3', 'BV9'});
      expect(await svc.getUnseenCount(), 2);
    });

    test('单个 UP 被风控（-412）→ 该 UP 队列不动，且不清空其它 UP',
        () async {
      final adapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV1', created: 1700000100),
            ],
        200: () => [
              _v(bvid: 'BV9', created: 1700000900),
              _v(bvid: 'BV8', created: 1700000800),
            ],
      });
      ServiceLocator.overrideSyncService(_FakeSyncService(_whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ])));
      final svc = InboxService.fromApi(_api(adapter));
      await svc.checkAll(force: true);

      adapter.riskControl.add(_kMid);
      final r = await svc.checkAll(force: true);
      expect(r.items.map((e) => e.bvid).toSet(), {'BV3', 'BV9'});
      expect(await svc.getUnseenCount(), 2);
    });

    // 「sync 整体失败 → 返回上次缓存 + failed」的热启动分支由
    // test/inbox_service_test.dart 覆盖：
    //   - sync 整体失败 → 返回上次缓存（不是空列表），并置 failed
  });

  // =========================================================================
  // S7 撤销回队
  // =========================================================================
  group('S7 撤销：条目回队 + 已处理记录移除', () {
    test('markHandled → unmarkHandled：条目回队、记录移除、总数回升', () async {
      final s = oneUp();
      final first = await s.svc.checkAll(force: true);
      await s.svc.markHandled('BV3');
      expect(await InboxHandledStore.instance.getAll(), contains('BV3'));

      await s.svc.unmarkHandled(first.items.first); // BV3
      expect(await InboxHandledStore.instance.getAll(), isNot(contains('BV3')));
      expect(await queueOf(s.svc), ['BV3', 'BV2'], reason: '回队且回到正确位置');
      expect(await s.svc.getUnseenCount(), 2);
    });

    test('撤销一个「已不在本次检查名单」的 UP 条目 → 不复活它的 key', () async {
      seedQueue([_q('BV3', '新视频 3', 1700000300)], checkedMids: [200]);
      final svc = InboxService.fromApi(_api(_MidAdapter(const {})));

      await svc.unmarkHandled(const InboxItem(
        upMid: _kMid,
        upName: 'UP100',
        upFace: '',
        bvid: 'BV3',
        title: '新视频 3',
        cover: '',
        duration: 60,
        pubDate: 1700000300,
      ));

      expect(await queueInPrefs(), ['BV3'], reason: 'key 里还是原来那 1 条，没被重建');
      expect(await queueOf(svc), isEmpty, reason: '100 不在名单里 → 不显示');
    });
  });

  // =========================================================================
  // S8 红点 == 队列条数
  // =========================================================================
  group('S8 红点与队列一致', () {
    test('多 UP：每次操作后 getUnseenCount() == getItems().length', () async {
      final adapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV1', created: 1700000100),
            ],
        200: () => [
              _v(bvid: 'BV9', created: 1700000900),
              _v(bvid: 'BV8', created: 1700000800),
            ],
      });
      ServiceLocator.overrideSyncService(_FakeSyncService(_whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ])));
      final svc = InboxService.fromApi(_api(adapter));

      Future<void> assertConsistent(String step) async {
        final items = await svc.getItems();
        expect(await svc.getUnseenCount(), items.length, reason: '$step 后红点 != 队列条数');
      }

      final first = await svc.checkAll(force: true);
      expect(first.items.length, 2);
      await assertConsistent('checkAll');

      await svc.markHandled('BV3');
      expect(await svc.getUnseenCount(), 1);
      await assertConsistent('消费一条');

      await svc.unmarkHandled(first.items.firstWhere((e) => e.bvid == 'BV3'));
      expect(await svc.getUnseenCount(), 2);
      await assertConsistent('撤销');

      await svc.markAllRead();
      await assertConsistent('全部标记已读');
      expect(await svc.getUnseenCount(), 0);
    });

    test('白名单移除一个 UP → 红点与列表一起下降（残留 key 不计入）', () async {
      final adapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV1', created: 1700000100),
            ],
        200: () => [
              _v(bvid: 'BV9', created: 1700000900),
              _v(bvid: 'BV8', created: 1700000800),
            ],
      });
      final github = _MemoryGithubApi(_whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
        _up(mid: 200, lastSeenBvid: 'BV8'),
      ]));
      ServiceLocator.overrideSyncService(_MemorySyncService(github));
      final svc = InboxService.fromApi(
        _api(adapter),
        upownerWriter: UpownerWriter(github: github),
      );
      await svc.checkAll(force: true);
      expect(await svc.getUnseenCount(), 2);

      // 白名单里删掉 200 → 它的未读不该再计入红点
      github.data = _whitelist([_up(mid: _kMid, lastSeenBvid: 'BV1')]);
      final r = await svc.checkAll(force: true);
      expect(r.unseen, 1);
      expect(await svc.getUnseenCount(), 1);
      expect(await queueOf(svc), ['BV3']);
    });

    test('单个 UP 拉取失败时红点与列表仍一致', () async {
      final adapter = _MidAdapter({
        _kMid: () => [
              _v(bvid: 'BV3', created: 1700000300),
              _v(bvid: 'BV1', created: 1700000100),
            ],
      });
      ServiceLocator.overrideSyncService(_FakeSyncService(_whitelist([
        _up(mid: _kMid, lastSeenBvid: 'BV1'),
      ])));
      final svc = InboxService.fromApi(_api(adapter));
      await svc.checkAll(force: true);

      adapter.networkFail.add(_kMid);
      await svc.checkAll(force: true);
      expect(await svc.getUnseenCount(), (await svc.getItems()).length);
      expect(await svc.getUnseenCount(), 1);
    });
  });

  // =========================================================================
  // 边界：每个 UP 只拉首页 5 条（现状锁定，本任务不改行为）
  // =========================================================================
  group('边界（现状锁定，不改行为）：每个 UP 只拉首页 5 条', () {
    test('两次检查间该 UP 发了 >5 条 → 更早的那些永远进不了队列', () async {
      // 服务端共有 9 条：BV9（最新）… BV1（基线）。适配器按 pn/ps 真分页。
      final all = [
        for (var i = 9; i >= 1; i--)
          _v(bvid: 'BV$i', created: 1700000000 + i * 100),
      ];
      final github = _MemoryGithubApi(
        _whitelist([_up(mid: _kMid, lastSeenBvid: 'BV1')]),
      );
      final adapter = _MidAdapter({_kMid: () => all});
      ServiceLocator.overrideSyncService(_MemorySyncService(github));
      final svc = InboxService.fromApi(
        _api(adapter),
        upownerWriter: UpownerWriter(github: github),
      );

      final r = await svc.checkAll(force: true);
      expect(r.items.map((e) => e.bvid).toSet(),
          {'BV9', 'BV8', 'BV7', 'BV6', 'BV5'});
      expect(adapter.arcRequests.map((q) => q.pn).toSet(), {1},
          reason: '只请求第 1 页：BV4/BV3/BV2 从来没被请求过');
      expect(adapter.arcRequests.single.ps, InboxService.kUnseenPerUpowner,
          reason: '窗口就是 5 条（kUnseenPerUpowner）');

      // 用户把这 5 条都滑掉 → 基线推进到 BV9 → 更早的 4 条永久跳过
      for (final b in ['BV9', 'BV8', 'BV7', 'BV6', 'BV5']) {
        await svc.markHandled(b);
      }
      await svc.checkAll(force: true);
      expect(github.data.upowners.single.lastSeenBvid, 'BV9',
          reason: '基线推进到首页最新那条');
      expect(await queueOf(svc), isEmpty);

      // 再检查一次：BV9 撞上基线立刻停 → BV4/BV3/BV2 永远不会出现
      final again = await svc.checkAll(force: true);
      expect(again.items, isEmpty);
      expect(adapter.arcRequests.every((q) => q.mid != _kMid || q.pn == 1), isTrue,
          reason: '现状：永远不会翻到第 2 页');
    });
  });
}
