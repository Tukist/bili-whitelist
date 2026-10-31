// B 站观看历史（v2.57.0+）· 读方向测试：接口调用形状 + 解析 + 全部保留（不再
// 按白名单过滤）+ 只丢播放器里没有对应物的条目 + 游标翻页 + 失败映射。
//
// 全部走 mock HttpClientAdapter（**不触网**）；同步服务另用注入的 fetchPage /
// whitelist 直接测翻页与保留/丢弃规则（那部分不需要 HTTP）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/bili_history_api.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

const String _kCursorPath = '/x/web-interface/history/cursor';
const String _kReportPath = '/x/v2/history/report';

/// 有效（未过期）的 SESSDATA：`urlencode(uid,expire,md5)`，expire 取远期。
const String _kValidSess = '100%2C9999999999%2Cabcdef';
const String _kJct = 'jct-token-abc';

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

/// 按路径路由的 fake adapter：记录请求，返回预置 body。
class _HistoryAdapter implements HttpClientAdapter {
  _HistoryAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];
  final Map<RequestOptions, String> wireBody = {};

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      wireBody[options] = utf8.decode(
        [for (final c in chunks) ...c],
        allowMalformed: true,
      );
    }
    final h = handlers[options.path];
    if (h == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': 0, 'data': null}),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(h()),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Map<String, dynamic> _ok([Map<String, dynamic>? data]) =>
    {'code': 0, 'data': data ?? {'cursor': null, 'list': []}};

/// 一条 archive 历史项（字段名照 bilibili-API-collect 文档）。
Map<String, dynamic> _archiveItem({
  String bvid = 'BV1aa411c7dd',
  int page = 1,
  int cid = 111,
  int progress = 42,
  int viewAt = 1700000000,
  String title = '标题甲',
  String up = 'UP甲',
  int duration = 600,
  String cover = '',
  List<String>? covers,
  String business = 'archive',
  int epId = 0,
}) =>
    {
      'title': title,
      'long_title': '',
      'cover': cover,
      'covers': covers,
      'history': {
        'oid': 80433022,
        'epid': epId,
        'bvid': bvid,
        'page': page,
        'cid': cid,
        'part': '',
        'business': business,
        'dt': 1,
      },
      'author_name': up,
      'author_mid': 123,
      'view_at': viewAt,
      'progress': progress,
      'badge': '',
      'duration': duration,
      'is_finish': 0,
    };

WhitelistVideo _video(
  String bvid, {
  int cid = 111,
  String title = '标题甲',
  String cover = 'http://cover/1.jpg',
  int duration = 600,
  List<PageInfo>? pages,
  int? pubdate,
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: cid,
      title: title,
      cover: cover,
      duration: duration,
      upName: 'UP甲',
      addedAt: '2026-01-01T00:00:00.000Z',
      pages: pages,
      pubdate: pubdate,
    );

WhitelistData _wl(List<WhitelistVideo> videos) => WhitelistData(
      version: 4,
      updatedAt: '2026-01-01T00:00:00.000Z',
      videos: videos,
    );

/// 跑一次同步：只给一页假响应（无 cursor → 不会再翻页），白名单按需注入。
///
/// v2.57.0 调整后白名单为空**不是**失败（全部按「不在白名单」保留），
/// 所以默认给空白名单最省事——想测"白名单内条目"就显式传。
Future<HistorySyncOutcome> _syncPage(
  List<Map<String, dynamic>> list, {
  List<WhitelistVideo> whitelist = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  return BiliHistorySyncService(
    fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async =>
        {'cursor': null, 'list': list},
    whitelist: () async => _wl(whitelist),
    store: HistoryStore.instance,
    now: () => DateTime(2026, 9, 8, 12),
  ).sync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _store['bili_sessdata'] = _kValidSess;
    _store['bili_jct'] = _kJct;
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({});
  });

  group('fetchHistoryCursor 请求形状', () {
    test('未登录（没有 SESSDATA）→ 本机 -101，且一个请求都不发', () async {
      _store.remove('bili_sessdata');
      final adapter = _HistoryAdapter({_kCursorPath: _ok});
      final api = _api(adapter);

      await expectLater(
        api.fetchHistoryCursor(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('请先登录'))),
      );
      expect(adapter.requests, isEmpty, reason: '没登录就别发请求（少一次风控面）');
    });

    test('带游标参数：ps 夹到 30、max/view_at/business 原样回填、type 默认 all',
        () async {
      final adapter = _HistoryAdapter({_kCursorPath: _ok});
      final api = _api(adapter);

      await api.fetchHistoryCursor(
        max: 26193,
        viewAt: 1700000000,
        business: 'pgc',
        ps: 99, // 越界 → 夹到上限 30
      );

      final req = adapter.forPath(_kCursorPath).single;
      expect(req.method, 'GET');
      expect(req.queryParameters['ps'], '30');
      expect(req.queryParameters['max'], '26193');
      expect(req.queryParameters['view_at'], '1700000000');
      expect(req.queryParameters['business'], 'pgc');
      expect(req.queryParameters['type'], 'all');
      // 登录态注入：Cookie 里有 SESSDATA（请求头表本身不许改，只验注入结果）
      expect('${req.headers['Cookie']}', contains('SESSDATA='));
    });

    test('第一页不带游标（max/view_at/business 全空时不出现在 query 里）',
        () async {
      final adapter = _HistoryAdapter({_kCursorPath: _ok});
      await _api(adapter).fetchHistoryCursor();

      final q = adapter.forPath(_kCursorPath).single.queryParameters;
      expect(q.containsKey('max'), isFalse);
      expect(q.containsKey('view_at'), isFalse);
      expect(q.containsKey('business'), isFalse);
    });

    test('code=-101 → 抛可读 -101，并清掉本地死会话', () async {
      final adapter = _HistoryAdapter({
        _kCursorPath: () => {'code': -101, 'message': '账号未登录'},
      });
      final api = _api(adapter);

      await expectLater(
        api.fetchHistoryCursor(),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -101)),
      );
      expect(_store['bili_sessdata'], isNull, reason: '服务端说没登录 → 清死会话');
    });

    test('code=-412 → 抛 -412（风控），message 用接口原文', () async {
      final adapter = _HistoryAdapter({
        _kCursorPath: () => {'code': -412, 'message': '请求被拦截'},
      });
      await expectLater(
        _api(adapter).fetchHistoryCursor(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', '请求被拦截')),
      );
    });
  });

  group('reportHistory 请求形状（写方向）', () {
    test('表单含 aid/cid/progress/platform=android/csrf，form-urlencoded', () async {
      final adapter = _HistoryAdapter({_kReportPath: _ok});
      await _api(adapter)
          .reportHistory(aid: 80433022, cid: 137649199, progress: 42);

      final req = adapter.forPath(_kReportPath).single;
      expect(req.method, 'POST');
      expect(req.contentType, Headers.formUrlEncodedContentType);
      expect(req.data, {
        'aid': '80433022',
        'cid': '137649199',
        'progress': '42',
        'platform': 'android',
        'csrf': _kJct,
      });
      // csrf 同时作为 cookie 发出去（与浏览器一致）
      expect('${req.headers['Cookie']}', contains('bili_jct=$_kJct'));
    });

    test('负数进度夹到 0（不把 -5 这种脏值发给服务端）', () async {
      final adapter = _HistoryAdapter({_kReportPath: _ok});
      await _api(adapter).reportHistory(aid: 1, cid: 2, progress: -5);
      expect((adapter.forPath(_kReportPath).single.data as Map)['progress'], '0');
    });

    test('aid/cid 无效 → 本机 -400，零请求', () async {
      final adapter = _HistoryAdapter({_kReportPath: _ok});
      final api = _api(adapter);
      await expectLater(
        api.reportHistory(aid: 0, cid: 5, progress: 1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
      );
      await expectLater(
        api.reportHistory(aid: 5, cid: 0, progress: 1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
      );
      expect(adapter.requests, isEmpty);
    });

    test('未登录（没有 bili_jct）→ -101「请先登录 B 站账号」，且不发上报请求', () async {
      _store.remove('bili_jct');
      final adapter = _HistoryAdapter({_kReportPath: _ok});
      await expectLater(
        _api(adapter).reportHistory(aid: 1, cid: 2, progress: 3),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('请先登录'))),
      );
      // 注：[BiliApi._postAuth] 会先走 _injectAuth（顺路取一次 buvid 指纹，
      // 这是**既有写操作的共同行为**），所以只断言"上报请求没发出去"。
      expect(adapter.forPath(_kReportPath), isEmpty);
    });
  });

  group('parseHistoryCursor 字段解析（文档字段名）', () {
    test('archive 项：bvid/cid/page/progress/view_at/duration/author_name', () {
      final page = parseHistoryCursor({
        'cursor': {'max': 26193, 'view_at': 1700000000, 'business': 'pgc'},
        'list': [_archiveItem()],
      });

      expect(page.cursorMax, 26193);
      expect(page.cursorViewAt, 1700000000);
      expect(page.cursorBusiness, 'pgc');
      expect(page.hasCursor, isTrue);

      final item = page.items.single;
      expect(item.bvid, 'BV1aa411c7dd');
      expect(item.cid, 111);
      expect(item.page, 1);
      expect(item.business, 'archive');
      expect(item.progressSec, 42, reason: 'progress 单位是秒');
      expect(item.durationSec, 600, reason: 'duration 单位是秒');
      expect(item.viewAtSec, 1700000000, reason: 'view_at 是秒级时间戳');
      expect(item.upName, 'UP甲');
      expect(item.isUsable, isTrue);
    });

    test('番剧项（business=pgc、bvid 为空、有 epid）→ 不可用（会被丢弃）', () {
      final page = parseHistoryCursor({
        'list': [
          {
            'title': '百妖谱',
            'long_title': '庆忌（下）',
            'cover': 'http://cover/pgc.jpg',
            'history': {
              'oid': 370908663,
              'epid': 326789,
              'bvid': '',
              'page': 0,
              'cid': 199204975,
              'business': 'pgc',
              'dt': 3,
            },
            'author_name': '',
            'view_at': 1592985807,
            'progress': 533,
            'duration': 1402,
          },
        ],
      });
      final item = page.items.single;
      expect(item.bvid, isEmpty);
      expect(item.epId, 326789);
      expect(item.business, 'pgc');
      expect(item.isUsable, isFalse, reason: '白名单按 bvid 记账，pgc 项对不上');
    });

    test('cover 为空时退到 covers[0]；标题里的高亮标签剔除', () {
      final page = parseHistoryCursor({
        'list': [
          {
            ..._archiveItem(title: '看<em class="keyword">这个</em>视频'),
            'covers': ['http://cover/from-covers.jpg'],
          },
        ],
      });
      final item = page.items.single;
      expect(item.cover, 'http://cover/from-covers.jpg');
      expect(item.title, '看这个视频');
    });

    test('脏数据容错：list 缺失/非数组 → 空页；非 Map 条目跳过、不拖累同页其它条',
        () {
      expect(parseHistoryCursor(null).items, isEmpty);
      expect(parseHistoryCursor({'list': 'x'}).items, isEmpty);
      final page = parseHistoryCursor({
        'list': [
          'not-a-map',
          _archiveItem(bvid: 'BVgood'),
          {'title': '缺 history'},
        ],
      });
      expect(page.items, hasLength(2));
      expect(page.items.first.bvid, 'BVgood');
      expect(page.items[1].bvid, isEmpty);
      expect(page.items[1].isUsable, isFalse);
    });

    test('没有 cursor / 全零 cursor → hasCursor=false（翻页必须停）', () {
      expect(parseHistoryCursor({'list': []}).hasCursor, isFalse);
      expect(
        parseHistoryCursor({
          'cursor': {'max': 0, 'view_at': 0, 'business': ''},
        }).hasCursor,
        isFalse,
      );
    });
  });

  group('resolvePageIndex（分 P 归属）', () {
    test('cid 能对上分 P 列表 → 用它的下标（不依赖 page 是 1 基还是 0 基）', () {
      final video = _video('BV1', pages: const [
        PageInfo(cid: 10, part: 'P1', duration: 60),
        PageInfo(cid: 20, part: 'P2', duration: 70),
      ]);
      final item = parseHistoryCursor({
        'list': [_archiveItem(cid: 20, page: 1)],
      }).items.single;
      // page 故意给错（1 基的 P1），仍应以 cid=20 命中下标 1
      expect(resolvePageIndex(item: item, video: video), 1);
    });

    test('对不上 cid → 退回 page-1（1 基推断）；越界夹到最后一集', () {
      final video = _video('BV1', pages: const [
        PageInfo(cid: 10, part: 'P1', duration: 60),
        PageInfo(cid: 20, part: 'P2', duration: 70),
      ]);
      final first = parseHistoryCursor({
        'list': [_archiveItem(cid: 999, page: 1)],
      }).items.single;
      expect(resolvePageIndex(item: first, video: video), 0);

      final outOfRange = parseHistoryCursor({
        'list': [_archiveItem(cid: 999, page: 9)],
      }).items.single;
      expect(resolvePageIndex(item: outOfRange, video: video), 1,
          reason: '脏 page 不能让人点开一个不存在的分 P');
    });

    test('白名单没有分 P 列表（单 P）→ 永远 0（App 只认那一个 cid）', () {
      final video = _video('BV1');
      final item = parseHistoryCursor({
        'list': [_archiveItem(page: 3)],
      }).items.single;
      expect(resolvePageIndex(item: item, video: video), 0);
    });
  });

  group('entryFromRemote（映射规则）', () {
    test('进度秒→毫秒、时间戳秒→DateTime、元信息优先白名单、来源标 bilibili',
        () {
      final video = _video('BV1', pubdate: 1715212800);
      final item = parseHistoryCursor({
        'list': [
          _archiveItem(
            progress: 42,
            viewAt: 1700000000,
            title: '远程标题',
            up: '远程UP',
            duration: 600,
            cover: 'http://remote/cover.jpg',
          ),
        ],
      }).items.single;

      final e = entryFromRemote(item: item, video: video);
      expect(e.bvid, 'BV1');
      expect(e.pageIndex, 0);
      expect(e.cid, 111);
      expect(e.positionMs, 42000, reason: 'progress 是秒');
      expect(e.durationMs, 600000);
      expect(e.watchedAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
      expect(e.title, '标题甲', reason: '元信息优先白名单那份（字段最全）');
      expect(e.cover, 'http://cover/1.jpg');
      expect(e.pubdate, 1715212800);
      expect(e.source, HistorySource.bilibili);
      expect(e.inWhitelist, isTrue, reason: '白名单内的条目不带「未在白名单」标记');
    });

    test('白名单标题/封面为空时用远程兜底；多 P 时长按该分 P 的 duration', () {
      final video = _video(
        'BV1',
        title: '',
        cover: '',
        pages: const [
          PageInfo(cid: 10, part: 'P1', duration: 60),
          PageInfo(cid: 20, part: 'P2', duration: 70),
        ],
      );
      final item = parseHistoryCursor({
        'list': [
          _archiveItem(cid: 20, page: 2, progress: 30, cover: 'http://r/c.jpg'),
        ],
      }).items.single;

      final e = entryFromRemote(item: item, video: video);
      expect(e.pageIndex, 1);
      expect(e.title, '标题甲', reason: '白名单标题为空 → 用远程 title');
      expect(e.cover, 'http://r/c.jpg');
      expect(e.durationMs, 70000, reason: '第 2 P 的时长');
    });

    test('没有白名单那份（非白名单条目）：全部字段用远程补齐，标 inWhitelist=false',
        () {
      final item = parseHistoryCursor({
        'list': [
          _archiveItem(
            bvid: 'BVoutside',
            page: 3,
            cid: 987654,
            progress: 42,
            viewAt: 1700000000,
            title: '别人的投稿',
            up: '某UP',
            duration: 700,
            cover: 'http://r/cover.jpg',
          ),
        ],
      }).items.single;

      final e = entryFromRemote(item: item);
      expect(e.bvid, 'BVoutside');
      expect(e.pageIndex, 2, reason: 'page=3 → 第 3 集（1 基推断）');
      expect(e.cid, 987654, reason: '取流只认 cid，必须原样带上');
      expect(e.title, '别人的投稿');
      expect(e.cover, 'http://r/cover.jpg');
      expect(e.upName, '某UP');
      expect(e.durationMs, 700000, reason: '远程 duration 是秒');
      expect(e.positionMs, 42000);
      expect(e.watchedAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
      expect(e.pages, isNull, reason: '远程没给整份分 P 列表，不编一个假的');
      expect(e.pubdate, isNull, reason: '远程没有发布时间');
      expect(e.source, HistorySource.bilibili);
      expect(e.inWhitelist, isFalse);
    });
  });

  group('BiliHistorySyncService（游标翻页 + 全部保留）', () {
    test('非白名单的普通投稿也进历史（标 inWhitelist=false、元信息用远程补齐），'
        '本机独有记录不丢，记 lastSyncAt', () async {
      SharedPreferences.setMockInitialValues({});
      await HistoryStore.instance.addOrUpdate(HistoryEntry(
        bvid: 'BVlocal',
        pageIndex: 0,
        cid: 5,
        title: '本机独有',
        cover: '',
        upName: 'UP',
        durationMs: 60000,
        positionMs: 10000,
        watchedAt: DateTime(2026, 1, 1),
      ));

      final calls = <Map<String, dynamic>>[];
      final service = BiliHistorySyncService(
        fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async {
          calls.add({'max': max, 'view_at': viewAt, 'business': business, 'ps': ps});
          if (calls.length > 1) return {'cursor': null, 'list': []}; // 第二页到底
          return {
            'cursor': {'max': 1, 'view_at': 1700000000, 'business': 'archive'},
            'list': [
              _archiveItem(bvid: 'BVin', progress: 42, viewAt: 1700000000),
              _archiveItem(
                bvid: 'BVout',
                progress: 9,
                viewAt: 1700000000,
                title: '远程标题',
                up: '远程UP',
                duration: 700,
                cover: 'http://remote/c.jpg',
              ),
            ],
          };
        },
        whitelist: () async => _wl([_video('BVin')]),
        store: HistoryStore.instance,
        now: () => DateTime(2026, 2, 2, 3, 4, 5),
      );

      final outcome = await service.sync();

      expect(outcome.ok, isTrue);
      expect(outcome.scanned, 2);
      expect(outcome.kept, 2, reason: '白名单内外都要收（用户要求所有视频都进历史）');
      expect(outcome.dropped, 0);
      expect(outcome.notInWhitelist, 1, reason: '只有 BVout 不在白名单');
      expect(outcome.added, 2);
      expect(outcome.lastSyncAt, DateTime(2026, 2, 2, 3, 4, 5));

      final all = await HistoryStore.instance.getAll();
      expect(all.map((e) => e.bvid), containsAll(['BVin', 'BVout', 'BVlocal']));
      final inWl = all.singleWhere((e) => e.bvid == 'BVin');
      expect(inWl.inWhitelist, isTrue);
      expect(inWl.title, '标题甲', reason: '白名单内的元信息仍优先用白名单那份');
      final out = all.singleWhere((e) => e.bvid == 'BVout');
      expect(out.inWhitelist, isFalse, reason: '非白名单 → 历史卡要能标出来');
      expect(out.source, HistorySource.bilibili);
      // 非白名单条目的元信息全部来自远程字段（否则历史卡是一行空白）
      expect(out.title, '远程标题');
      expect(out.cover, 'http://remote/c.jpg');
      expect(out.upName, '远程UP');
      expect(out.cid, 111);
      expect(out.durationMs, 700000);
      expect(out.positionMs, 9000);
      expect(out.pageIndex, 0);
      expect((await HistoryStore.instance.readLastSyncAt()),
          DateTime(2026, 2, 2, 3, 4, 5));
    });

    test('非白名单条目能构造出可播放条目（cid/title/cover 都有，可点开播）',
        () async {
      await _syncPage([
        _archiveItem(
          bvid: 'BVoutside',
          page: 2,
          cid: 424242,
          progress: 30,
          title: '别人的投稿',
          up: '某UP',
          duration: 300,
          cover: 'http://r/c.jpg',
        ),
      ]);

      final e = (await HistoryStore.instance.getAll()).single;
      expect(e.bvid, 'BVoutside');
      expect(e.cid, 424242, reason: '取流只认 cid —— 远程给了就能播');
      expect(e.pageIndex, 1, reason: 'page=2 → 第 2 集（1 基推断）');
      expect(e.title, '别人的投稿');
      expect(e.cover, 'http://r/c.jpg');
      expect(e.inWhitelist, isFalse);
      // 播放页只要 bvid + cid 就能取流（页面侧转换见 videoFromHistoryEntry）
      expect(e.bvid.isNotEmpty && e.cid > 0, isTrue);
    });

    test('白名单为空：不再直接失败，全部按「不在白名单」保留', () async {
      final outcome = await _syncPage([
        _archiveItem(bvid: 'BV1'),
        _archiveItem(bvid: 'BV2'),
      ]);

      expect(outcome.ok, isTrue);
      expect(outcome.kept, 2);
      expect(outcome.notInWhitelist, 2);
      final all = await HistoryStore.instance.getAll();
      expect(all, hasLength(2));
      expect(all.every((e) => !e.inWhitelist), isTrue);
    });

    test('游标翻页：上一页 cursor 回填到下一页参数；最多 3 页', () async {
      SharedPreferences.setMockInitialValues({});
      final calls = <Map<String, dynamic>>[];
      var page = 0;
      final service = BiliHistorySyncService(
        fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async {
          calls.add({'max': max, 'view_at': viewAt, 'business': business, 'ps': ps});
          page++;
          return {
            'cursor': {
              'max': 100 + page,
              'view_at': 1700000000 - page,
              'business': 'archive',
            },
            'list': [_archiveItem(bvid: 'BV$page', progress: page)],
          };
        },
        whitelist: () async =>
            _wl([_video('BV1'), _video('BV2'), _video('BV3'), _video('BV4')]),
        store: HistoryStore.instance,
        now: () => DateTime(2026, 2, 2),
      );

      final outcome = await service.sync();

      expect(calls, hasLength(3), reason: '上限 3 页（kHistorySyncMaxPages）');
      expect(calls[0]['max'], isNull, reason: '首页不带游标');
      expect(calls[1]['max'], 101, reason: '第二页回填上一页 cursor.max');
      expect(calls[1]['view_at'], 1700000000 - 1);
      expect(calls[1]['business'], 'archive');
      expect(calls[2]['max'], 102);
      expect(calls.every((c) => c['ps'] == 30), isTrue, reason: 'ps 上限 30');
      expect(outcome.kept, 3);
    });

    test('空页 / 无 cursor → 立即停止，不再发第二次请求', () async {
      SharedPreferences.setMockInitialValues({});
      var n = 0;
      final service = BiliHistorySyncService(
        fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async {
          n++;
          return {'cursor': null, 'list': []};
        },
        whitelist: () async => _wl([_video('BV1')]),
        store: HistoryStore.instance,
      );

      final outcome = await service.sync();
      expect(n, 1);
      expect(outcome.ok, isTrue);
      expect(outcome.kept, 0);
      expect(outcome.summary, contains('没有观看记录'));
    });

    test('游标不前进（接口异常）→ 停止翻页，不死循环', () async {
      SharedPreferences.setMockInitialValues({});
      var n = 0;
      final service = BiliHistorySyncService(
        fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async {
          n++;
          return {
            // 同一份 cursor 一直返回（服务端兜底/异常时会这样）
            'cursor': {'max': 7, 'view_at': 1700000000, 'business': 'archive'},
            'list': [_archiveItem(bvid: 'BV1')],
          };
        },
        whitelist: () async => _wl([_video('BV1')]),
        store: HistoryStore.instance,
      );

      await service.sync();
      expect(n, 2, reason: '第 2 页发现游标没前进就停（不是翻满 3 页）');
    });

    test('白名单读取失败 → 明确失败（不把全部条目误标成「未在白名单」）',
        () async {
      SharedPreferences.setMockInitialValues({});
      var n = 0;
      final service = BiliHistorySyncService(
        fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async {
          n++;
          return {'cursor': null, 'list': [_archiveItem(bvid: 'BV1')]};
        },
        whitelist: () async => throw StateError('gist 挂了'),
        store: HistoryStore.instance,
      );

      final outcome = await service.sync();
      expect(n, 0, reason: '读不到白名单就别发请求（发了也只能全标错）');
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('白名单读取失败'));
    });

    test('同一批远程条目重复同步：第二次全部是"更新"，不重复插入', () async {
      SharedPreferences.setMockInitialValues({});
      Future<Map<String, dynamic>> page({
        int? max,
        int? viewAt,
        String? business,
        int ps = 30,
      }) async =>
          {
            'cursor': null,
            'list': [_archiveItem(bvid: 'BV1', progress: 42)],
          };
      final service = BiliHistorySyncService(
        fetchPage: page,
        whitelist: () async => _wl([_video('BV1')]),
        store: HistoryStore.instance,
      );

      final first = await service.sync();
      final second = await service.sync();
      expect(first.added, 1);
      expect(second.added, 0);
      expect(second.updated, 1);
      expect(await HistoryStore.instance.getAll(), hasLength(1));
    });
  });

  group('丢弃哪些条目（只丢播放器里没有对应物的）', () {
    test('番剧（business=pgc、bvid 空、有 epid）→ 丢弃', () async {
      final o = await _syncPage([
        _archiveItem(
          business: 'pgc',
          bvid: '',
          epId: 326789,
          cid: 199204975,
          duration: 1402,
        ),
      ]);
      expect(o.kept, 0);
      expect(o.dropped, 1);
      expect(o.notInWhitelist, 0);
      expect(await HistoryStore.instance.getAll(), isEmpty,
          reason: '播放器只认 bvid + cid 的普通投稿，番剧集要走 pgc 取流');
    });

    test('直播（business=live）→ 丢弃', () async {
      final o = await _syncPage([
        _archiveItem(business: 'live', bvid: '', cid: 0),
      ]);
      expect(o.kept, 0);
      expect(o.dropped, 1);
      expect(await HistoryStore.instance.getAll(), isEmpty);
    });

    test('专栏（business=article）→ 丢弃', () async {
      final o = await _syncPage([
        _archiveItem(business: 'article', bvid: '', cid: 0),
      ]);
      expect(o.kept, 0);
      expect(o.dropped, 1);
      expect(await HistoryStore.instance.getAll(), isEmpty);
    });

    test('bvid 缺失的脏条目（archive 但没有 bvid）→ 丢弃', () async {
      final o = await _syncPage([_archiveItem(bvid: '', cid: 111)]);
      expect(o.kept, 0);
      expect(o.dropped, 1);
      expect(await HistoryStore.instance.getAll(), isEmpty,
          reason: '没有 bvid 就没有去重主键，也没有可播对象');
    });

    test('观看时间缺失（view_at=0）→ 丢弃', () async {
      final o = await _syncPage([_archiveItem(bvid: 'BV1', viewAt: 0)]);
      expect(o.kept, 0);
      expect(o.dropped, 1);
      expect(await HistoryStore.instance.getAll(), isEmpty);
    });

    test('非白名单且 cid 缺失 → 丢弃（点开也取不到流）', () async {
      final o = await _syncPage([_archiveItem(bvid: 'BV1', cid: 0)]);
      expect(o.kept, 0);
      expect(o.dropped, 1);
      expect(await HistoryStore.instance.getAll(), isEmpty);
    });

    test('白名单条目 cid 缺失仍保留（cid 能从白名单那份补）', () async {
      final o = await _syncPage(
        [_archiveItem(bvid: 'BV1', cid: 0)],
        whitelist: [_video('BV1', cid: 777)],
      );
      expect(o.kept, 1);
      expect(o.dropped, 0);
      final e = (await HistoryStore.instance.getAll()).single;
      expect(e.cid, 777);
      expect(e.inWhitelist, isTrue);
    });

    test('一页混着来：能播的收、不能播的丢，各自计数正确', () async {
      final o = await _syncPage([
        _archiveItem(bvid: 'BVok'),
        _archiveItem(business: 'pgc', bvid: ''),
        _archiveItem(bvid: '', business: 'live'),
        _archiveItem(bvid: 'BVnocid', cid: 0),
      ]);
      expect(o.scanned, 4);
      expect(o.kept, 1);
      expect(o.dropped, 3);
      expect(await HistoryStore.instance.getAll(), hasLength(1));
    });
  });

  group('historySyncErrorText（失败可读原因）', () {
    test('-101 未登录 / -412 风控 / -352 频繁 / DioException 网络', () {
      expect(
        historySyncErrorText(
            const BiliApiException(code: -101, message: 'x')),
        contains('未登录'),
      );
      expect(
        historySyncErrorText(
            const BiliApiException(code: -412, message: 'x')),
        contains('风控'),
      );
      expect(
        historySyncErrorText(
            const BiliApiException(code: -352, message: 'x')),
        contains('频繁'),
      );
      expect(
        historySyncErrorText(DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.connectionError)),
        contains('网络'),
      );
      // 未映射的码用接口自己的中文原文（不猜）
      expect(
        historySyncErrorText(
            const BiliApiException(code: -400, message: '请求错误')),
        '请求错误',
      );
    });
  });

  group('HistorySyncOutcome.summary 文案', () {
    test('有新增/更新/不在白名单时逐项说清（不再说"忽略"）', () {
      const o = HistorySyncOutcome(
        ok: true,
        scanned: 10,
        kept: 6,
        dropped: 0,
        notInWhitelist: 4,
        added: 5,
        updated: 1,
        lastSyncAt: null,
      );
      expect(o.summary, '已同步 6 条 B 站历史 · 新增 5 · 更新 1 · 其中 4 条不在白名单');
    });

    test('全部都是白名单内的条目 → 不出现"不在白名单"', () {
      const o = HistorySyncOutcome(
        ok: true,
        scanned: 2,
        kept: 2,
        dropped: 0,
        added: 2,
        updated: 0,
      );
      expect(o.summary, '已同步 2 条 B 站历史 · 新增 2');
    });

    test('有跳过（无法播放）的条目时说明跳过多少条', () {
      const o = HistorySyncOutcome(
        ok: true,
        scanned: 5,
        kept: 3,
        dropped: 2,
        notInWhitelist: 1,
        added: 3,
        updated: 0,
      );
      expect(o.summary,
          '已同步 3 条 B 站历史 · 新增 3 · 其中 1 条不在白名单 · 跳过 2 条无法播放的');
    });

    test('一条都收不进来时说明原因', () {
      const o = HistorySyncOutcome(
        ok: true,
        scanned: 4,
        kept: 0,
        dropped: 4,
        added: 0,
        updated: 0,
      );
      expect(o.summary, 'B 站历史里没有能在这里播放的条目（已跳过 4 条：番剧 / 直播 / 专栏等）');
    });
  });
}
