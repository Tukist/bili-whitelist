// 写操作第一阶段（点赞 / 投币 / 收藏，v2.40.0+）· BiliApi 单元测试。
//
// 覆盖（全部走 mock HttpClientAdapter，**不触网**）：
// - `readBiliJct`：读到就返回、没有就 null；
// - `likeVideo`：path / 方法 / 表单字段（aid + like 目标态）/ csrf 注入 /
//   `contentType` = form-urlencoded；**幂等**（重复调用传的是同一个目标态）；
// - `addCoin`：multiply + select_like 字段；multiply 越界在本机拦下（不发请求）；
// - `favVideo`：收藏走 add_media_ids、取消走 del_media_ids、另一个字段留空串；
//   两个都给 / 都不给 → 本机 -400；
// - **csrG 为空**（没登录 / 没抓到 bili_jct）→ 可读的 -101「请先登录 B 站账号」，
//   并且**一个网络请求都不发**（不是发出去换个语焉不详的 -111）；
// - 错误码分类：-101 / -111 / -400 / -403 / -404 / -412 / -509 / -352 /
//   未知码回落接口原文 / 接口没给 message；
// - **网络失败原样上抛且不重试**（写接口重试 = 第二次点赞/第二次扣币）；
// - SESSDATA 过期 → 视为未登录（写操作给同一句可读提示）；
// - 纯函数 `parseVideoReqUser` / `viewStatCounts` 的容错。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

const String _kLikePath = '/x/web-interface/archive/like';
const String _kCoinPath = '/x/web-interface/coin/add';
const String _kFavDealPath = '/x/v3/fav/resource/deal';

/// 有效（未过期）的 SESSDATA：`urlencode(uid,expire,md5)`，expire 取远期。
const String _kValidSess = '100%2C9999999999%2Cabcdef';
const String _kJct = 'jct-token-abc';

/// 内存版 secure storage（对应原生 MethodChannel）。
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

/// 按路径路由的 fake adapter：记录请求（含**实际编码后的表单体**），返回预置 body。
class _WriteAdapter implements HttpClientAdapter {
  _WriteAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];

  /// 每个请求**真正写到线路上**的表单体（`requestStream` 解码）。
  ///
  /// 为什么要单独收这个：`options.data` 只是"我们传进去的 map"，真正发出去的
  /// 是 dio 编码后的字符串——两者理论上一致，但写操作的值（`like=0`）恰好是
  /// "看起来像假值"的那一类，必须钉在**线路上**而不是"我们以为传了什么"。
  final Map<RequestOptions, String> wireBody = {};

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  /// 写请求（POST）列表。
  List<RequestOptions> get posts =>
      requests.where((r) => r.method == 'POST').toList();

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

Map<String, dynamic> _ok() => {'code': 0, 'data': null};

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Map<String, String> _form(RequestOptions r) =>
    Map<String, String>.from(r.data as Map);

void main() {
  // 这些是纯 Dart 单测，但 secure storage 的 mock 走 MethodChannel →
  // 需要先初始化测试 binding（否则 TestDefaultBinaryMessengerBinding.instance
  // 直接抛「Binding has not yet been initialized」）
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _store['bili_sessdata'] = _kValidSess;
    _store['bili_jct'] = _kJct;
    _mockSecureStorage();
  });

  // -------------------------------------------------------------------------
  // readBiliJct
  // -------------------------------------------------------------------------

  test('readBiliJct：读到存进去的值；没有（未登录）返回 null', () async {
    final api = _api(_WriteAdapter({}));
    expect(await api.readBiliJct(), _kJct);

    _store.remove('bili_jct');
    expect(await api.readBiliJct(), isNull);
  });

  // -------------------------------------------------------------------------
  // likeVideo
  // -------------------------------------------------------------------------

  test('likeVideo(like: true)：POST archive/like + aid/like=1/csrf + 表单编码',
      () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await _api(adapter).likeVideo(aid: 80433022, like: true);

    final req = adapter.forPath(_kLikePath).single;
    expect(req.method, 'POST');
    expect(req.contentType, Headers.formUrlEncodedContentType,
        reason: 'B 站写接口只认表单体；用 JSON 会被当成参数缺失');
    expect(_form(req), {
      'aid': '80433022',
      'like': '1',
      'csrf': _kJct,
    });
  });

  test('likeVideo(like: false)：取消点赞的 like 值是 **2**（真机实测，不是 0）',
      () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await _api(adapter).likeVideo(aid: 7, like: false);
    final req = adapter.forPath(_kLikePath).single;
    // ⚠️ 这条是**真机实测锁**：社区文档写 like=0 取消，但真机实测 like=0 一律被
    // 服务端拒成 -400 请求错误（试了 5 种请求形状），只有 like=2 返回 code=0
    // 且 stat.like 真的减 1。谁要是照文档改回 0，这条用例会红。
    expect(_form(req)['like'], '${BiliApi.kLikeOff}');
    expect(_form(req)['like'], '2');
    expect(BiliApi.kLikeOn, 1);
    // 钉在**线路上**：dio 的编码器不能把字段吞掉
    expect(adapter.wireBody[req], contains('like=2'));
  });

  test('点赞幂等：重复调用同一目标态 → 两次请求都是 like=1（不是切换）',
      () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    final api = _api(adapter);
    await api.likeVideo(aid: 7, like: true);
    await api.likeVideo(aid: 7, like: true);

    final likes =
        adapter.forPath(_kLikePath).map((r) => _form(r)['like']).toList();
    expect(likes, ['1', '1']);
  });

  test('likeVideo 给了 bvid 就一起发（不给则不发这个字段）', () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    final api = _api(adapter);
    await api.likeVideo(aid: 7, like: false, bvid: 'BV1AB411c7mD');
    await api.likeVideo(aid: 7, like: false);

    final forms = adapter.forPath(_kLikePath).map(_form).toList();
    expect(forms[0]['bvid'], 'BV1AB411c7mD');
    expect(forms[1].containsKey('bvid'), isFalse);
  });

  test('写请求的 Cookie 头带上 bili_jct（与浏览器一致）', () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await _api(adapter).likeVideo(aid: 7, like: true);

    final cookie =
        adapter.forPath(_kLikePath).single.headers['Cookie'] as String?;
    expect(cookie, contains('bili_jct=$_kJct'));
    expect(cookie, contains('SESSDATA='));
  });

  test('点赞的 65006「重复点赞」按成功处理（要的状态已经在了）', () async {
    final adapter = _WriteAdapter({
      _kLikePath: () => {'code': 65006, 'message': '重复点赞'},
    });
    await expectLater(
      _api(adapter).likeVideo(aid: 7, like: true),
      completes,
      reason: '重复点赞不是失败：否则"界面不认识点赞态 → 再点一次"会被回滚成没赞',
    );
  });

  test('其他接口的 65006 不享受这个豁免（只有点赞声明了）', () async {
    final adapter = _WriteAdapter({
      _kCoinPath: () => {'code': 65006, 'message': '重复点赞'},
    });
    await expectLater(
      _api(adapter).addCoin(aid: 7),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', 65006)
          .having((e) => e.message, 'message', '重复点赞')),
    );
  });

  test('likeVideo：aid <= 0 → 本机抛 -400，不发请求', () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await expectLater(
      _api(adapter).likeVideo(aid: 0, like: true),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -400)
          .having((e) => e.message, 'message', contains('id 无效'))),
    );
    expect(adapter.requests, isEmpty);
  });

  // -------------------------------------------------------------------------
  // addCoin
  // -------------------------------------------------------------------------

  test('addCoin：multiply + select_like 字段齐全（投币并点赞）', () async {
    final adapter = _WriteAdapter({_kCoinPath: _ok});
    await _api(adapter).addCoin(aid: 99, multiply: 2, alsoLike: true);

    final req = adapter.forPath(_kCoinPath).single;
    expect(req.method, 'POST');
    expect(_form(req), {
      'aid': '99',
      'multiply': '2',
      'select_like': '1',
      'csrf': _kJct,
    });
  });

  test('addCoin 默认值：1 枚 + 不勾选连带点赞', () async {
    final adapter = _WriteAdapter({_kCoinPath: _ok});
    await _api(adapter).addCoin(aid: 99);
    expect(_form(adapter.forPath(_kCoinPath).single), {
      'aid': '99',
      'multiply': '1',
      'select_like': '0',
      'csrf': _kJct,
    });
  });

  test('addCoin：multiply 越界（0 / 3）→ 本机 -400，一个请求都不发', () async {
    final adapter = _WriteAdapter({_kCoinPath: _ok});
    for (final m in [0, 3, -1]) {
      await expectLater(
        _api(adapter).addCoin(aid: 99, multiply: m),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
      );
    }
    expect(adapter.requests, isEmpty,
        reason: '扣真硬币的接口，参数越界必须在本机拦下');
  });

  // -------------------------------------------------------------------------
  // favVideo
  // -------------------------------------------------------------------------

  test('favVideo 收藏：rid + type=2 + add_media_ids，del 留空串', () async {
    final adapter = _WriteAdapter({_kFavDealPath: _ok});
    await _api(adapter).favVideo(aid: 123, addFid: 456);

    final req = adapter.forPath(_kFavDealPath).single;
    expect(req.method, 'POST');
    expect(_form(req), {
      'rid': '123',
      'type': '2',
      'add_media_ids': '456',
      'del_media_ids': '',
      'csrf': _kJct,
    });
  });

  test('favVideo 取消收藏：del_media_ids 有值，add 留空串', () async {
    final adapter = _WriteAdapter({_kFavDealPath: _ok});
    await _api(adapter).favVideo(aid: 123, delFid: 789);
    expect(_form(adapter.forPath(_kFavDealPath).single), {
      'rid': '123',
      'type': '2',
      'add_media_ids': '',
      'del_media_ids': '789',
      'csrf': _kJct,
    });
  });

  test('favVideo：add/del 同时给或同时不给 → 本机 -400，不发请求', () async {
    final adapter = _WriteAdapter({_kFavDealPath: _ok});
    final api = _api(adapter);
    await expectLater(
      api.favVideo(aid: 1, addFid: 2, delFid: 3),
      throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
    );
    await expectLater(
      api.favVideo(aid: 1),
      throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -400)),
    );
    expect(adapter.requests, isEmpty);
  });

  // -------------------------------------------------------------------------
  // csrf / 登录态
  // -------------------------------------------------------------------------

  test('csrG 为空（没登录 / 没抓到 bili_jct）→ 可读的 -101，且不发请求',
      () async {
    _store.remove('bili_jct');
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await expectLater(
      _api(adapter).likeVideo(aid: 7, like: true),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -101)
          .having((e) => e.message, 'message', '请先登录 B 站账号')),
    );
    expect(adapter.posts, isEmpty, reason: '空 csrf 发出去只会换个语焉不详的 -111');
  });

  test('csrG 为空：投币与收藏同样在本机拦下', () async {
    _store.remove('bili_jct');
    final adapter = _WriteAdapter({});
    final api = _api(adapter);
    for (final f in <Future<void> Function()>[
      () => api.addCoin(aid: 7),
      () => api.favVideo(aid: 7, addFid: 1),
    ]) {
      await expectLater(f(), throwsA(isA<BiliApiException>()));
    }
    // 注意断言的是"没有任何**写**请求"：_injectAuth 会先打一次
    // GET /x/frontend/finger/spi（buvid 指纹），所以 requests 不是空的
    expect(adapter.posts, isEmpty);
  });

  test('SESSDATA 过期 → 按未登录处理（写操作给同一句可读提示）', () async {
    // 过期时间取过去（1 = 1970），_injectAuth 会判过期并清掉整套凭据
    _store['bili_sessdata'] = '100%2C1%2Cabcdef';
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await expectLater(
      _api(adapter).likeVideo(aid: 7, like: true),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -101)
          .having((e) => e.message, 'message', '请先登录 B 站账号')),
    );
    expect(adapter.posts, isEmpty);
    expect(_store.containsKey('bili_jct'), isFalse,
        reason: '顺带清掉失效会话，避免后续请求继续带死 cookie');
  });

  // -------------------------------------------------------------------------
  // 错误码分类
  // -------------------------------------------------------------------------

  test('业务码分类：-101 / -111 / -400 / -403 / -404 / -412 / -509 / -352',
      () async {
    final cases = <int, String>{
      -101: '登录已失效，请重新登录 B 站账号',
      -111: '操作校验失败（csrf 无效），请重新登录 B 站账号',
      -400: '操作参数被拒绝，请稍后再试',
      -412: '操作被风控拦截，请稍后再试',
      -509: '操作过于频繁，请稍后再试',
      -352: '操作被限流，请稍后再试',
    };
    for (final e in cases.entries) {
      final adapter = _WriteAdapter({
        _kLikePath: () => {'code': e.key, 'message': '服务端原文'},
      });
      await expectLater(
        _api(adapter).likeVideo(aid: 7, like: true),
        throwsA(isA<BiliApiException>()
            .having((x) => x.code, 'code', e.key)
            .having((x) => x.message, 'message', e.value)),
        reason: 'code=${e.key} 要给人话，不是把 -509 这种数字甩给用户',
      );
    }
  });

  test('业务码分类：-403 / -404 优先透出接口原文（B 站中文更准）', () async {
    final adapter = _WriteAdapter({
      _kLikePath: () => {'code': -403, 'message': '稿件不可见'},
    });
    await expectLater(
      _api(adapter).likeVideo(aid: 7, like: true),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -403)
          .having((e) => e.message, 'message', '稿件不可见')),
    );

    final empty = _WriteAdapter({
      _kLikePath: () => {'code': -403},
    });
    await expectLater(
      _api(empty).likeVideo(aid: 7, like: true),
      throwsA(isA<BiliApiException>()
          .having((e) => e.message, 'message', '没有权限执行该操作')),
    );
  });

  test('未知业务码：回落接口原文；连原文都没有 → 「操作失败」', () async {
    final withMsg = _WriteAdapter({
      _kCoinPath: () => {'code': 34005, 'message': '超过投币上限'},
    });
    await expectLater(
      _api(withMsg).addCoin(aid: 7),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', 34005)
          .having((e) => e.message, 'message', '超过投币上限')),
    );

    final noMsg = _WriteAdapter({
      _kCoinPath: () => {'code': 34005},
    });
    await expectLater(
      _api(noMsg).addCoin(aid: 7),
      throwsA(isA<BiliApiException>()
          .having((e) => e.message, 'message', '操作失败')),
    );
  });

  test('code=0 不抛（正常返回）', () async {
    final adapter = _WriteAdapter({_kLikePath: _ok});
    await _api(adapter).likeVideo(aid: 7, like: true);
    expect(adapter.forPath(_kLikePath), hasLength(1));
  });

  // -------------------------------------------------------------------------
  // 网络失败：原样上抛 + 不重试
  // -------------------------------------------------------------------------

  test('网络失败：DioException 原样上抛，且**只发一次**（写接口不重试）',
      () async {
    final adapter = _NetFailAdapter();
    await expectLater(
      _api(adapter).likeVideo(aid: 7, like: true),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1),
        reason: '读接口可以退避重试，写接口重试可能就是第二次点赞/第二次扣币');
  });

  // -------------------------------------------------------------------------
  // 纯函数：view 里的 req_user / stat
  // -------------------------------------------------------------------------

  test('parseVideoReqUser：没有 req_user → null（未登录拿不到）', () {
    expect(parseVideoReqUser(null), isNull);
    expect(parseVideoReqUser(const {}), isNull);
    expect(parseVideoReqUser(const {'req_user': 'x'}), isNull);
  });

  test('parseVideoReqUser：0/1 与 true/false 两种形态都当"有没有"读', () {
    final numeric = parseVideoReqUser(const {
      'req_user': {'like': 1, 'coin': 0, 'favorite': 1},
    })!;
    expect([numeric.like, numeric.coin, numeric.favorite], [true, false, true]);

    final boolean = parseVideoReqUser(const {
      'req_user': {'like': true, 'coin': false, 'favorite': true},
    })!;
    expect(
        [boolean.like, boolean.coin, boolean.favorite], [true, false, true]);
  });

  test('parseVideoReqUser：单个字段缺失/脏 → 该字段 false，其余照常', () {
    final ru = parseVideoReqUser(const {
      'req_user': {'like': 'yes', 'favorite': 1},
    })!;
    expect(ru.like, isFalse, reason: '认不出的值按"没有"处理，不猜');
    expect(ru.coin, isFalse, reason: '缺字段 = 没投过');
    expect(ru.favorite, isTrue);
  });

  test('viewStatCounts：取 stat 三个数；缺失/脏/负数 → 0', () {
    final s = viewStatCounts(const {
      'stat': {'like': 12345, 'coin': 67, 'favorite': 8},
    });
    expect([s.like, s.coin, s.favorite], [12345, 67, 8]);

    final dirty = viewStatCounts(const {
      'stat': {'like': -5, 'coin': 'x'},
    });
    expect([dirty.like, dirty.coin, dirty.favorite], [0, 0, 0]);

    final missing = viewStatCounts(null);
    expect([missing.like, missing.coin, missing.favorite], [0, 0, 0]);
  });

  // -------------------------------------------------------------------------
  // 纯函数：archive/relation 的互动态（v2.41.0+，写按钮的真实初始态）
  // -------------------------------------------------------------------------

  test('parseVideoRelation：data 缺失 / 三个键一个都没有 → null（按"没取到"处理）',
      () {
    expect(parseVideoRelation(null), isNull);
    // 空 data：不是"三个都是 false"，而是"这个响应没回答我的互动态"
    expect(parseVideoRelation(const {}), isNull);
    // 有 data 但一个相关键都没有（风控改写 / 结构变了）
    expect(parseVideoRelation(const {'aid': 2, 'bvid': 'BV1'}), isNull);
  });

  test('parseVideoRelation：bool 形态（真机实测的字段名与类型）', () {
    // 2026-09 真机探针的原始响应形状，逐键照抄
    final r = parseVideoRelation(const {
      'attention': true,
      'favorite': false,
      'season_fav': false,
      'like': true,
      'dislike': false,
      'coin': 2,
    })!;
    expect(r.like, isTrue);
    expect(r.coin, 2, reason: 'coin 是**枚数**不是布尔');
    expect(r.coined, isTrue);
    expect(r.fav, isFalse, reason: '键名是 favorite（不是 fav），这里为 false');
  });

  test('parseVideoRelation：favorite=true → 已收藏；旧写法的 fav 也认', () {
    expect(
      parseVideoRelation(const {'like': false, 'favorite': true})!.fav,
      isTrue,
      reason: '真机给的是 favorite',
    );
    expect(
      parseVideoRelation(const {'like': false, 'fav': 1})!.fav,
      isTrue,
      reason: '防御性兜底：万一哪天变体用 fav 也不至于"永远未收藏"',
    );
  });

  test('parseVideoRelation：0/1 与布尔混搭都认（B 站两套形态都给过）', () {
    final numeric = parseVideoRelation(const {
      'like': 1,
      'coin': 0,
      'favorite': 1,
    })!;
    expect([numeric.like, numeric.coined, numeric.fav], [true, false, true]);

    final booleanCoin = parseVideoRelation(const {
      'like': false,
      'coin': true,
      'favorite': false,
    })!;
    expect(booleanCoin.coin, 1, reason: '布尔 true 当"投过 1 枚"');
    expect(booleanCoin.coined, isTrue);
  });

  test('parseVideoRelation：单个字段脏/缺失 → 该字段安全默认，其余照常', () {
    final r = parseVideoRelation(const {'like': 'yes', 'favorite': 1})!;
    expect(r.like, isFalse, reason: '认不出的值按"没有"处理，不猜');
    expect(r.coin, 0, reason: '缺 coin = 没投过');
    expect(r.fav, isTrue, reason: '一个字段脏不该把另一个有效字段也丢掉');

    final negative = parseVideoRelation(const {'coin': -3})!;
    expect(negative.coin, 0, reason: '负数夹到 0（不显示"已投 -3 枚"）');
  });

  test('fetchVideoRelation：解析 data、失败返回 null 不抛', () async {
    final adapter = _WriteAdapter({
      '/x/web-interface/archive/relation': () => {
            'code': 0,
            'message': 'OK',
            'data': {
              'attention': true,
              'favorite': false,
              'like': true,
              'coin': 2,
            },
          },
    });
    final r = await _api(adapter).fetchVideoRelation('BV1TEST');
    expect(r, isNotNull);
    expect([r!.like, r.coin, r.fav], [true, 2, false]);
    final req = adapter.forPath('/x/web-interface/archive/relation').single;
    expect(req.method, 'GET');
    expect(req.uri.queryParameters['bvid'], 'BV1TEST');
    expect(req.uri.queryParameters.containsKey('csrf'), isFalse,
        reason: '只读接口：不带 csrf、不发 POST');
  });

  test('fetchVideoRelation：未登录（-101）/ 认不出数据 / 网络失败 → 一律 null',
      () async {
    final notLoggedIn = _WriteAdapter({
      '/x/web-interface/archive/relation': () =>
          {'code': -101, 'message': '账号未登录'},
    });
    expect(await _api(notLoggedIn).fetchVideoRelation('BV1'), isNull);

    final emptyData = _WriteAdapter({
      '/x/web-interface/archive/relation': () => {'code': 0, 'data': <String, dynamic>{}},
    });
    expect(await _api(emptyData).fetchVideoRelation('BV1'), isNull,
        reason: '空 data 当"没取到"，UI 保留降级标注');

    expect(await _api(_NetFailAdapter()).fetchVideoRelation('BV1'), isNull,
        reason: '网络失败不抛：初始态请求失败不该让播放页报错');

    // bvid 空 → 一个请求都不发
    final none = _WriteAdapter(const {});
    expect(await _api(none).fetchVideoRelation(''), isNull);
    expect(none.requests, isEmpty);
  });
}
