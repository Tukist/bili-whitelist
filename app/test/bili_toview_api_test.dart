// 稍后再看（v2.58.0+）· 读/写接口形状 + 解析容错 + 服务层"永不抛"与
// "失败不误报成功"。
//
// 全部走 mock HttpClientAdapter（**不触网**）；服务层另用注入的
// fetchList / add / remove 直接测三条分支（那部分不需要 HTTP）。
//
// 探针出处（细节见 lib/services/bili_toview_api.dart 文件头）：
// - 匿名实测：三条端点（GET toview / POST add / POST del）不带凭据全部回
//   -101 账号未登录 —— 所以"未登录要在本机拦下"是实测结论，不是猜的；
// - 字段名与错误码（90001 列表满 / 90003 稿件已删除）来自
//   bilibili-API-collect 的 docs/historytoview/toview.md。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/services/bili_toview_api.dart';

const String _kListPath = '/x/v2/history/toview';
const String _kAddPath = '/x/v2/history/toview/add';
const String _kDelPath = '/x/v2/history/toview/del';

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

/// 按路径路由的 fake adapter：记录请求（含**线路上的表单体**），返回预置 body。
class _ToViewAdapter implements HttpClientAdapter {
  _ToViewAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];

  /// 真正写到线路上的表单体（`requestStream` 解码）：`csrf` / `aid` / `bvid`
  /// 断言钉在**发出去的那份**上，而不是"我们以为传进去了什么"。
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

/// 会抛网络异常的 adapter（验证"原样上抛 + 不重试"）。
class _NetFailAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
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

/// 一条稍后再看记录（字段名照文档 `data.list[]`）。
Map<String, dynamic> _item({
  int aid = 170001,
  String bvid = 'BV1aa411c7dd',
  int cid = 111,
  int page = 1,
  int videos = 1,
  int? count,
  String title = '标题甲',
  String pic = 'https://i0.hdslb.com/bfs/archive/a.jpg',
  String up = 'UP甲',
  int duration = 600,
  int progress = 42,
  int addAt = 1700000000,
  Object? pageObj = _absent,
}) {
  return {
    'aid': aid,
    'bvid': bvid,
    'cid': cid,
    'videos': videos,
    if (count != null) 'count': count,
    'title': title,
    'pic': pic,
    'duration': duration,
    'progress': progress,
    'add_at': addAt,
    'owner': {'mid': 99, 'name': up},
    'page': pageObj == _absent
        ? {'cid': cid, 'page': page, 'part': 'P1'}
        : pageObj,
  };
}

/// 标记"这个键不存在"（`page: null` 与"没有 page 键"是两回事，都要测）。
const Object _absent = Object();

/// 一份解析层入参（= 响应的 `data` 本体；`parseToViewList` 吃的就是它，**不是**
/// 带 `code` 的信封）。名字保留 `_list` 是为了让测试读起来像"一份列表响应"。
Map<String, dynamic> _list(Map<String, dynamic> data) => data;

/// HTTP 响应信封（`{code, message, ttl, data}`）。
Map<String, dynamic> _resp(Map<String, dynamic> data) =>
    {'code': 0, 'message': '0', 'ttl': 1, 'data': data};

Map<String, dynamic> _code(int code, [String message = '0']) =>
    {'code': code, 'message': message, 'ttl': 1};

Map<String, String> _form(RequestOptions r) =>
    Map<String, String>.from(r.data as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _store['bili_sessdata'] = _kValidSess;
    _store['bili_jct'] = _kJct;
    _mockSecureStorage();
  });

  // -------------------------------------------------------------------------
  // 解析（纯函数）
  // -------------------------------------------------------------------------

  group('parseToViewList', () {
    test('完整字段：aid/bvid/cid/title/pic/owner/duration/progress/add_at/分P',
        () {
      final parsed = parseToViewList(_list({
        'count': 1,
        'list': [
          _item(
            aid: 555,
            bvid: 'BV1xxxxxxx',
            cid: 777,
            page: 3,
            videos: 5,
            title: '  三体  ',
            up: '刘慈欣',
            duration: 3600,
            progress: 120,
            addAt: 1700000001,
          ),
        ],
      }));
      expect(parsed.count, 1);
      expect(parsed.items, hasLength(1));
      final it = parsed.items.single;
      expect(it.aid, 555);
      expect(it.bvid, 'BV1xxxxxxx');
      expect(it.cid, 777);
      expect(it.page, 3);
      expect(it.pageIndex, 2, reason: 'page 是 1 基 → 0 起下标 2');
      expect(it.pageCount, 5);
      expect(it.title, '三体', reason: '标题两端空白被清掉');
      expect(it.cover, contains('hdslb.com'));
      expect(it.upName, '刘慈欣');
      expect(it.durationSec, 3600);
      expect(it.progressSec, 120);
      expect(it.hasProgress, isTrue);
      expect(it.addedAt, isNotNull);
      expect(it.addedAt!.toUtc().year, greaterThan(2020));
      expect(it.canPlay, isTrue);
      expect(it.canRemove, isTrue);
    });

    test('缺字段 / 脏类型：不抛，缺的按 0 / 空串', () {
      final parsed = parseToViewList(_list({
        'count': 1,
        'list': [
          // 只有 bvid：其余字段全缺（aid=0 → 删不掉，但能播）
          {'bvid': 'BV1onlybvid'},
          // 脏类型：duration 是字符串、progress 是 null、owner 不是 Map
          {
            'aid': 2,
            'bvid': 'BV1dirty000',
            'duration': '600',
            'progress': null,
            'owner': 'not-a-map',
            'page': 'not-a-map',
          },
        ],
      }));
      expect(parsed.items, hasLength(2));
      final noAid = parsed.items[0];
      expect(noAid.aid, 0);
      expect(noAid.canRemove, isFalse, reason: '没有 aid 就移除不了');
      expect(noAid.canPlay, isTrue);
      expect(noAid.title, '');
      expect(noAid.upName, '');
      expect(noAid.pageIndex, 0);

      final dirty = parsed.items[1];
      expect(dirty.durationSec, 600, reason: '字符串数字也认');
      expect(dirty.progressSec, 0);
      expect(dirty.hasProgress, isFalse);
      expect(dirty.upName, '', reason: 'owner 不是 Map → 空串，不抛');
      expect(dirty.page, 0, reason: 'page 不是 Map → 0');
      expect(dirty.pageIndex, 0);
    });

    test('cid：顶层为 0 时用 page.cid 兜底（文档示例里真有顶层 cid=0 的条目）',
        () {
      final parsed = parseToViewList(_list({
        'count': 1,
        'list': [
          _item(cid: 0, pageObj: {'cid': 8888, 'page': 2}),
        ],
      }));
      final it = parsed.items.single;
      expect(it.cid, 8888);
      expect(it.pageIndex, 1);
    });

    test('count：缺失时回落条目数；服务端说更多时 truncated', () {
      final empty = parseToViewList(_list({'count': 0, 'list': []}));
      expect(empty.items, isEmpty);
      expect(empty.count, 0);
      expect(empty.truncated, isFalse);

      final partial = parseToViewList(_list({
        'count': 100,
        'list': [_item(aid: 1), _item(aid: 2)],
      }));
      expect(partial.items, hasLength(2));
      expect(partial.count, 100);
      expect(partial.truncated, isTrue, reason: '只拿到 2 条但服务端说 100');

      final noCount =
          parseToViewList(_list({'list': [_item(aid: 1)]}));
      expect(noCount.count, 1, reason: 'count 缺失 → 按条目数');
    });

    test('整份脏数据：data=null / list 不是数组 / 单条不是 Map → 空列表不抛',
        () {
      expect(parseToViewList(null).items, isEmpty);
      expect(parseToViewList({'list': 'oops'}).items, isEmpty);
      expect(
        parseToViewList({
          'count': 3,
          'list': [
            'not-a-map',
            _item(aid: 9),
          ],
        }).items,
        hasLength(1),
        reason: '坏的那条跳过，好的照收',
      );
    });

    test('既无 aid 又无 bvid 的记录被跳过（播不了也删不掉）', () {
      final parsed = parseToViewList(_list({
        'count': 2,
        'list': [
          {'title': '幽灵条目'},
          _item(aid: 3),
        ],
      }));
      expect(parsed.items.map((e) => e.aid), [3]);
    });

    test('标题里夹带的高亮标签被清掉', () {
      final parsed = parseToViewList(_list({
        'count': 1,
        'list': [_item(title: '<em class="keyword">三体</em> 解说')],
      }));
      expect(parsed.items.single.title, '三体 解说');
    });
  });

  // -------------------------------------------------------------------------
  // 读：BiliApi.fetchToViewList
  // -------------------------------------------------------------------------

  group('fetchToViewList', () {
    test('GET /x/v2/history/toview（无分页参数），返回 data 对象', () async {
      final adapter = _ToViewAdapter({
        _kListPath: () => _resp(_list({
              'count': 1,
              'list': [_item(aid: 12)],
            })),
      });
      final data = await _api(adapter).fetchToViewList();
      expect(data['count'], 1);
      expect((data['list'] as List), hasLength(1));

      final reqs = adapter.forPath(_kListPath);
      expect(reqs, hasLength(1));
      expect(reqs.single.method, 'GET');
      expect(reqs.single.queryParameters, isEmpty,
          reason: '文档没有 pn/ps：一次拿全量');
    });

    test('未登录（本机没有 SESSDATA）→ 可读 -101，且**一个请求都不发**', () async {
      _store.remove('bili_sessdata');
      final adapter = _ToViewAdapter({});
      await expectLater(
        _api(adapter).fetchToViewList(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录'))),
      );
      expect(adapter.requests, isEmpty);
    });

    test('服务端回 -101 → 可读"登录已失效"', () async {
      final adapter = _ToViewAdapter({
        _kListPath: () => _code(-101, '账号未登录'),
      });
      await expectLater(
        _api(adapter).fetchToViewList(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录已失效'))),
      );
    });

    test('data=null（空列表）→ 返回空壳而不是 null', () async {
      final adapter = _ToViewAdapter({
        _kListPath: () => {'code': 0, 'data': null},
      });
      final data = await _api(adapter).fetchToViewList();
      expect(data['count'], 0);
      expect(data['list'], isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 写：加入 / 移除
  // -------------------------------------------------------------------------

  group('addToView', () {
    test('只给 bvid：POST add + 表单 bvid + csrf（不需要 aid）', () async {
      final adapter = _ToViewAdapter({_kAddPath: () => _code(0)});
      await _api(adapter).addToView(bvid: 'BV1aa411c7dd');

      final req = adapter.forPath(_kAddPath).single;
      expect(req.method, 'POST');
      final form = _form(req);
      expect(form['bvid'], 'BV1aa411c7dd');
      expect(form['csrf'], _kJct, reason: 'csrf = bili_jct（文档：必要）');
      expect(form.containsKey('aid'), isFalse);
      expect(adapter.wireBody[req], contains('bvid=BV1aa411c7dd'));
      expect(adapter.wireBody[req], contains('csrf=$_kJct'));
    });

    test('只给 aid：表单带 aid', () async {
      final adapter = _ToViewAdapter({_kAddPath: () => _code(0)});
      await _api(adapter).addToView(aid: 170001);
      final form = _form(adapter.forPath(_kAddPath).single);
      expect(form['aid'], '170001');
      expect(form['csrf'], _kJct);
    });

    test('aid 与 bvid 都没有 → 本机 -400，一个请求都不发', () async {
      final adapter = _ToViewAdapter({});
      await expectLater(
        _api(adapter).addToView(),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -400)
            .having((e) => e.message, 'message', contains('缺少稿件 id'))),
      );
      expect(adapter.requests, isEmpty);
    });

    test('90001 列表已满 → 说明要"先移除一些"（不是"稍后再试"）', () async {
      final adapter = _ToViewAdapter({
        _kAddPath: () => _code(90001, ''),
      });
      await expectLater(
        _api(adapter).addToView(bvid: 'BV1aa411c7dd'),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', 90001)
            .having((e) => e.message, 'message', contains('上限 100'))),
      );
    });

    test('90003 稿件已删除 → 可读原因', () async {
      final adapter = _ToViewAdapter({
        _kAddPath: () => _code(90003, ''),
      });
      await expectLater(
        _api(adapter).addToView(bvid: 'BV1aa411c7dd'),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', 90003)
            .having((e) => e.message, 'message', contains('已被删除'))),
      );
    });

    test('-111 csrf 失效 → 可读提示', () async {
      final adapter = _ToViewAdapter({
        _kAddPath: () => _code(-111, 'csrf 校验失败'),
      });
      await expectLater(
        _api(adapter).addToView(bvid: 'BV1aa411c7dd'),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -111)
            .having((e) => e.message, 'message', contains('csrf'))),
      );
    });

    test('没登录（没有 bili_jct）→ -101 且不发写请求', () async {
      _store.remove('bili_jct');
      final adapter = _ToViewAdapter({});
      await expectLater(
        _api(adapter).addToView(bvid: 'BV1aa411c7dd'),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -101)),
      );
      // 注意只数 toview 那一条：`_injectAuth` 会先打一次 spi 取 buvid 指纹
      // （读请求，不是这次写操作）。
      expect(adapter.forPath(_kAddPath), isEmpty);
    });

    test('网络失败原样上抛且不重试（写接口不重试）', () async {
      final adapter = _NetFailAdapter();
      await expectLater(
        _api(adapter).addToView(bvid: 'BV1aa411c7dd'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests.where((r) => r.path == _kAddPath), hasLength(1),
          reason: '只发一次（spi 指纹那次不算）');
    });
  });

  group('delFromView', () {
    test('只认 aid：POST del + 表单 aid + csrf', () async {
      final adapter = _ToViewAdapter({_kDelPath: () => _code(0)});
      await _api(adapter).delFromView(aid: 540580868);

      final req = adapter.forPath(_kDelPath).single;
      expect(req.method, 'POST');
      final form = _form(req);
      expect(form['aid'], '540580868');
      expect(form['csrf'], _kJct);
      expect(form.containsKey('viewed'), isFalse,
          reason: '批量"删所有已看过的"本版不接');
      expect(adapter.wireBody[req], contains('aid=540580868'));
    });

    test('aid <= 0 → 本机 -400，不发请求', () async {
      final adapter = _ToViewAdapter({});
      await expectLater(
        _api(adapter).delFromView(aid: 0),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
      );
      expect(adapter.requests, isEmpty);
    });

    test('-400 → 可读提示（不误报成功）', () async {
      final adapter = _ToViewAdapter({
        _kDelPath: () => _code(-400, '请求错误'),
      });
      await expectLater(
        _api(adapter).delFromView(aid: 1),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
      );
    });
  });

  // -------------------------------------------------------------------------
  // 服务层：永不抛 + 失败不误报成功
  // -------------------------------------------------------------------------

  group('BiliToViewService', () {
    test('load 成功：解析条目 + count', () async {
      final svc = BiliToViewService(
        fetchList: () async => _list({
          'count': 1,
          'list': [_item(aid: 7)],
        }),
      );
      final r = await svc.load();
      expect(r.ok, isTrue);
      expect(r.items.single.aid, 7);
      expect(r.count, 1);
      expect(r.error, isNull);
    });

    test('load 失败：折成可读原因，**不抛**', () async {
      final svc = BiliToViewService(
        fetchList: () async => throw const BiliApiException(
          code: -101,
          message: '账号未登录',
          path: _kListPath,
        ),
      );
      final r = await svc.load();
      expect(r.ok, isFalse);
      expect(r.items, isEmpty);
      expect(r.error, contains('未登录'));
    });

    test('load 网络失败：说"网络请求失败"，不是笼统"操作失败"', () async {
      final svc = BiliToViewService(
        fetchList: () async => throw DioException.connectionError(
          requestOptions: RequestOptions(path: _kListPath),
          reason: 'refused',
        ),
      );
      final r = await svc.load();
      expect(r.ok, isFalse);
      expect(r.error, contains('网络'));
    });

    test('addVideo：成功 → ok；参数原样透传（只给 bvid，不瞎编 aid）', () async {
      String? gotBvid;
      int? gotAid;
      final svc = BiliToViewService(
        add: ({int? aid, String? bvid}) async {
          gotAid = aid;
          gotBvid = bvid;
        },
      );
      final r = await svc.addVideo(bvid: 'BV1aa411c7dd');
      expect(r.ok, isTrue);
      expect(gotBvid, 'BV1aa411c7dd');
      expect(gotAid, isNull);
    });

    test('addVideo：接口失败 → ok=false 且带原因（不误报成功）', () async {
      var called = 0;
      final svc = BiliToViewService(
        add: ({int? aid, String? bvid}) async {
          called++;
          throw const BiliApiException(
            code: 90001,
            message: '稍后再看已满（上限 100 个视频），请先移除一些',
            path: _kAddPath,
          );
        },
      );
      final r = await svc.addVideo(bvid: 'BV1aa411c7dd');
      expect(called, 1);
      expect(r.ok, isFalse);
      expect(r.error, contains('已满'));
    });

    test('addVideo：aid 与 bvid 都没有 → 本机拦下，**一次调用都不发**', () async {
      var called = 0;
      final svc = BiliToViewService(
        add: ({int? aid, String? bvid}) async {
          called++;
        },
      );
      final r = await svc.addVideo();
      expect(r.ok, isFalse);
      expect(called, 0);
      expect(r.error, contains('缺少稿件 id'));
    });

    test('removeItem：成功 → ok；aid 透传', () async {
      int? got;
      final svc = BiliToViewService(remove: (aid) async => got = aid);
      final r = await svc.removeItem(42);
      expect(r.ok, isTrue);
      expect(got, 42);
    });

    test('removeItem：接口失败 → ok=false 且带原因', () async {
      final svc = BiliToViewService(
        remove: (aid) async => throw const BiliApiException(
          code: -412,
          message: '操作被风控拦截',
          path: _kDelPath,
        ),
      );
      final r = await svc.removeItem(42);
      expect(r.ok, isFalse);
      expect(r.error, contains('风控'));
    });

    test('removeItem：aid <= 0 → 本机拦下，不发请求', () async {
      var called = 0;
      final svc = BiliToViewService(remove: (aid) async => called++);
      final r = await svc.removeItem(0);
      expect(r.ok, isFalse);
      expect(called, 0);
      expect(r.error, contains('aid'));
    });
  });

  // -------------------------------------------------------------------------
  // 条目 → 播放页入参（纯函数）
  // -------------------------------------------------------------------------

  group('videoFromToViewItem', () {
    test('bvid/cid/标题/封面/时长/UP 主原样带过去，pages 留 null', () {
      final parsed = parseToViewList(_list({
        'count': 1,
        'list': [
          _item(
            bvid: 'BV1zzz',
            cid: 321,
            title: '标题丙',
            duration: 900,
            up: 'UP丙',
            addAt: 1700000000,
          ),
        ],
      }));
      final v = videoFromToViewItem(parsed.items.single);
      expect(v.bvid, 'BV1zzz');
      expect(v.cid, 321);
      expect(v.title, '标题丙');
      expect(v.duration, 900, reason: '播放页要的是秒');
      expect(v.upName, 'UP丙');
      expect(v.pages, isNull,
          reason: '远程只给了"这一集"，给假的分 P 列表会让集数/时长全错');
      expect(v.addedAt, isNotEmpty, reason: '加入时间填进去，不留 1970');
    });

    test('add_at 缺失 → addedAt 空串（不留假的 1970 时间）', () {
      final parsed = parseToViewList(_list({
        'count': 1,
        'list': [_item(addAt: 0)],
      }));
      expect(videoFromToViewItem(parsed.items.single).addedAt, '');
    });
  });
}
