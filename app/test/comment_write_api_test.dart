// 写操作第二阶段（评论，v2.42.0+）· BiliApi 单元测试。
//
// 覆盖（全部走 mock HttpClientAdapter，**不触网、不碰真账号**）：
// - `addComment`：path / 方法 / 表单字段（oid / type / message / csrf）/
//   `contentType` = form-urlencoded；顶层评论**不带** root/parent；
// - 回复：带上 root / parent（两个都给了才带）；
// - 本机拦下（**一个请求都不发**）：空正文 / 全空白的正文 / 超 1000 字 /
//   oid<=0 / type<=0；
// - **csrf 为空**（没登录 / 没抓到 bili_jct）→ 可读的 -101「请先登录 B 站账号」，
//   且一个网络请求都不发（不是发出去换个语焉不详的 -111）；
// - `deleteComment`：path / 字段（oid / type / rpid / csrf）；rpid<=0 本机拦下；
// - 错误码分类：12002 评论区已关闭 / 12015 内容被拦截 / -101 / -509 /
//   未知码回落接口原文；
// - **网络失败原样上抛且不重试**（写接口重试 = 多发一条公开评论）；
// - 成功返回 rpid（服务端没给 / 给了脏值 → null）。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

const String _kAddPath = '/x/v2/reply/add';
const String _kDelPath = '/x/v2/reply/del';

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

/// 按路径路由的 fake adapter：记录请求（含**实际编码后的表单体**）。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];

  /// 每个请求**真正写到线路上**的表单体。
  ///
  /// 为什么不看 `options.data` 就够：那只是"我们传进去的 map"，真正发出去的
  /// 是 dio 编码后的字符串。评论正文可能含换行/`&`/`=`（用户随手打的），
  /// 这些恰好是 form-urlencoded 最容易出错的地方——必须钉在**线路上**。
  final Map<RequestOptions, String> wireBody = {};

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  /// 写请求（POST）列表。
  ///
  /// 单独挑出来是因为 [_injectAuth] 会先打一次只读的 `finger/spi` 拿 buvid
  /// 指纹——"一个写请求都不发"要判的是 POST，不是"一个请求都不发"。
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
    return ResponseBody.fromString(
      jsonEncode(h == null ? const {'code': 0, 'data': null} : h()),
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

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

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

Map<String, String> _form(RequestOptions r) =>
    Map<String, String>.from(r.data as Map);

/// 业务码响应。
Map<String, dynamic> _code(int code, [String? message]) => {
      'code': code,
      if (message != null) 'message': message,
    };

void main() {
  // 纯 Dart 单测，但 secure storage 的 mock 走 MethodChannel →
  // 需要先初始化测试 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _store['bili_sessdata'] = _kValidSess;
    _store['bili_jct'] = _kJct;
    _mockSecureStorage();
  });

  // -------------------------------------------------------------------------
  // addComment：请求构造
  // -------------------------------------------------------------------------

  test('addComment（顶层）：POST /x/v2/reply/add + oid/type/message/csrf + 表单编码',
      () async {
    final adapter = _Adapter({
      _kAddPath: () => {'code': 0, 'data': {'rpid': 123456789}},
    });
    final rpid = await _api(adapter).addComment(
      oid: 80433022,
      type: 1, // 视频：type=1 + oid=aid
      message: 'amoTV test comment',
    );

    expect(rpid, 123456789, reason: '成功要把 rpid 回给调用方（善后/定位用）');
    final req = adapter.forPath(_kAddPath).single;
    expect(req.method, 'POST');
    expect(req.contentType, Headers.formUrlEncodedContentType,
        reason: 'B 站写接口只认表单体；用 JSON 会被当成参数缺失');
    expect(_form(req), {
      'oid': '80433022',
      'type': '1',
      'message': 'amoTV test comment',
      'csrf': _kJct,
    }, reason: '顶层评论**不带** root/parent（带上 root=0 会被服务端当非法值）');
  });

  test('addComment：正文里的 & = 换行 真的按表单编码写到线路上', () async {
    final adapter = _Adapter({_kAddPath: () => _code(0)});
    await _api(adapter).addComment(
      oid: 1,
      type: 1,
      message: 'a&b=c\n第二行',
    );

    final req = adapter.forPath(_kAddPath).single;
    // 表单里出现的是**编码后**的字面量（%26/%3D/%0A），不是原字符——
    // 否则 `&` 会被服务端当成字段分隔符，正文被截断
    final wire = adapter.wireBody[req]!;
    expect(wire, contains('a%26b%3Dc%0A'));
    expect(_form(req)['message'], 'a&b=c\n第二行',
        reason: 'dio 解码后应还原原文');
  });

  test('addComment（回复根评论）：root 与 parent **同值**（都是那条根评论的 rpid）',
      () async {
    final adapter = _Adapter({_kAddPath: () => _code(0)});
    await _api(adapter).addComment(
      oid: 777,
      type: 12, // 专栏：type=12 + oid=cvid
      message: '@某人 回复你',
      root: 555,
      parent: 555,
    );

    final req = adapter.forPath(_kAddPath).single;
    expect(_form(req), {
      'oid': '777',
      'type': '12',
      'message': '@某人 回复你',
      'root': '555',
      'parent': '555',
      'csrf': _kJct,
    });
  });

  test('addComment（回复楼中楼某条子回复）：root = 根评论、parent = 被回复那条',
      () async {
    final adapter = _Adapter({_kAddPath: () => _code(0)});
    await _api(adapter).addComment(
      oid: 777,
      type: 1,
      message: '@甲 回你',
      root: 555, // 根评论 rpid
      parent: 666, // 被回复的那条子回复 rpid
    );

    final form = _form(adapter.forPath(_kAddPath).single);
    expect(form['root'], '555');
    expect(form['parent'], '666');
    expect(form['root'], isNot(form['parent']),
        reason: '两者不相等正是"楼中楼回复"的定义；写反会把评论挂错楼层');
  });

  test('addComment：服务端没给 rpid / 给了脏值 → 返回 null（不崩）', () async {
    final a1 = _Adapter({_kAddPath: () => _code(0)});
    expect(await _api(a1).addComment(oid: 1, type: 1, message: 'x'), isNull);

    final a2 = _Adapter({
      _kAddPath: () => {'code': 0, 'data': {'rpid': 'oops'}},
    });
    expect(await _api(a2).addComment(oid: 1, type: 1, message: 'x'), isNull);
  });

  test('addComment：rpid 是数字串也认（服务端偶发给字符串）', () async {
    final adapter = _Adapter({
      _kAddPath: () => {'code': 0, 'data': {'rpid': '987654321'}},
    });
    expect(await _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
        987654321);
  });

  // -------------------------------------------------------------------------
  // addComment：本机拦下（一个请求都不发）
  // -------------------------------------------------------------------------

  test('addComment：空正文 / 全空白 → 本机 -400，一个请求都不发', () async {
    for (final text in ['', '   ', '\n\t ']) {
      final adapter = _Adapter({_kAddPath: () => _code(0)});
      await expectLater(
        _api(adapter).addComment(oid: 1, type: 1, message: text),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -400)
            .having((e) => e.message, 'message', '评论内容不能为空')),
      );
      expect(adapter.requests, isEmpty,
          reason: '空评论服务端只回笼统的 -400，不如本机直接说清、少一次往返');
    }
  });

  test('addComment：超 1000 字 → 本机 -400，一个请求都不发', () async {
    final adapter = _Adapter({_kAddPath: () => _code(0)});
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: '字' * 1001),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -400)
          .having((e) => e.message, 'message', contains('1000'))),
    );
    expect(adapter.requests, isEmpty);
  });

  test('addComment：刚好 1000 字放行（边界不是 999）', () async {
    final adapter = _Adapter({_kAddPath: () => _code(0)});
    await _api(adapter).addComment(oid: 1, type: 1, message: '字' * 1000);
    expect(adapter.forPath(_kAddPath), hasLength(1));
    expect(_form(adapter.forPath(_kAddPath).single)['message']!.runes.length,
        1000);
  });

  test('addComment：emoji 按 code point 计数（与网页端「1000 字」一致）', () async {
    // '👍' 在 UTF-16 里占 2 个 code unit（Dart String.length）但只是 1 个
    // code point；按 length 判会**误拒**用户没超长的评论
    final adapter = _Adapter({_kAddPath: () => _code(0)});
    await _api(adapter).addComment(oid: 1, type: 1, message: '👍' * 1000);
    expect(adapter.forPath(_kAddPath), hasLength(1),
        reason: '1000 个 emoji 是 1000 字（length 会是 2000，按它判就误拒了）');
  });

  test('addComment：oid <= 0 / type <= 0 → 本机 -400，一个请求都不发', () async {
    final a1 = _Adapter({_kAddPath: () => _code(0)});
    await expectLater(
      _api(a1).addComment(oid: 0, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.message, 'message', contains('内容 id 无效'))),
    );
    expect(a1.requests, isEmpty);

    final a2 = _Adapter({_kAddPath: () => _code(0)});
    await expectLater(
      _api(a2).addComment(oid: 1, type: 0, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.message, 'message', contains('归属类型无效'))),
    );
    expect(a2.requests, isEmpty,
        reason: 'type 传错会静默挂到别的内容名下，宁可本机拒绝');
  });

  // -------------------------------------------------------------------------
  // csrf
  // -------------------------------------------------------------------------

  test('csrf 为空（未登录）→ 可读的 -101，并且**一个写请求都不发**', () async {
    _store.remove('bili_jct');
    final adapter = _Adapter({_kAddPath: () => _code(0)});

    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -101)
          .having((e) => e.message, 'message', '请先登录 B 站账号')),
    );
    expect(adapter.posts, isEmpty,
        reason: '发出去只会得到一个语焉不详的 -111，不如直接说清是没登录');
  });

  test('csrf 为空：deleteComment 同样拦下（清理时也不能静默失败）', () async {
    _store.remove('bili_jct');
    final adapter = _Adapter({_kDelPath: () => _code(0)});
    await expectLater(
      _api(adapter).deleteComment(oid: 1, type: 1, rpid: 2),
      throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -101)),
    );
    expect(adapter.posts, isEmpty);
  });

  // -------------------------------------------------------------------------
  // 错误码映射
  // -------------------------------------------------------------------------

  test('addComment：12002 → 「该评论区已关闭」（持久状态，不是"再试一次"）',
      () async {
    final adapter = _Adapter({
      _kAddPath: () => _code(12002, '评论区已关闭'),
    });
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', BiliApi.kCommentClosedCode)
          .having((e) => e.message, 'message', '该评论区已关闭')),
    );
  });

  test('addComment：-101 → 登录失效的可读提示', () async {
    final adapter = _Adapter({_kAddPath: () => _code(-101)});
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -101)
          .having((e) => e.message, 'message', '登录已失效，请重新登录 B 站账号')),
    );
  });

  test('addComment：-509 → 限频的可读提示', () async {
    final adapter = _Adapter({_kAddPath: () => _code(-509)});
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -509)
          .having((e) => e.message, 'message', '操作过于频繁，请稍后再试')),
    );
  });

  test('addComment：12015 内容被拦截 → 提示"改一下再发"（不是笼统"操作失败"）',
      () async {
    final adapter = _Adapter({_kAddPath: () => _code(12015)});
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', 12015)
          .having((e) => e.message, 'message', '评论内容被拦截，请修改后再发')),
    );
  });

  test('addComment：没映射过的码回落接口原文（不猜）', () async {
    final adapter = _Adapter({
      _kAddPath: () => _code(-352, '被限流了'),
    });
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>().having((e) => e.message, 'message', '操作被限流，请稍后再试')),
    );

    final a2 = _Adapter({_kAddPath: () => _code(99999, '服务端原话')});
    await expectLater(
      _api(a2).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', 99999)
          .having((e) => e.message, 'message', '服务端原话')),
    );
  });

  // -------------------------------------------------------------------------
  // 网络失败：不重试
  // -------------------------------------------------------------------------

  test('addComment：网络失败原样上抛 DioException，且**只发一次**（绝不重试）',
      () async {
    final adapter = _NetFailAdapter();
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.forPath(_kAddPath), hasLength(1),
        reason: '重试就是多发一条公开评论 —— 读接口可以退避重试，写接口不行');
  });

  test('addComment：-509 不做退避重试（读接口才有那条，写接口没有）', () async {
    final adapter = _Adapter({_kAddPath: () => _code(-509)});
    await expectLater(
      _api(adapter).addComment(oid: 1, type: 1, message: 'x'),
      throwsA(isA<BiliApiException>()),
    );
    expect(adapter.forPath(_kAddPath), hasLength(1),
        reason: '评论读接口的 -509 退避在 _getReplyApi，写路径不经过它');
  });

  // -------------------------------------------------------------------------
  // deleteComment
  // -------------------------------------------------------------------------

  test('deleteComment：POST /x/v2/reply/del + oid/type/rpid/csrf', () async {
    final adapter = _Adapter({_kDelPath: () => _code(0)});
    await _api(adapter).deleteComment(oid: 80433022, type: 1, rpid: 123456789);

    final req = adapter.forPath(_kDelPath).single;
    expect(req.method, 'POST');
    expect(req.contentType, Headers.formUrlEncodedContentType);
    expect(_form(req), {
      'oid': '80433022',
      'type': '1',
      'rpid': '123456789',
      'csrf': _kJct,
    });
  });

  test('deleteComment：oid / rpid <= 0 → 本机 -400，一个请求都不发', () async {
    final a1 = _Adapter({_kDelPath: () => _code(0)});
    await expectLater(
      _api(a1).deleteComment(oid: 0, type: 1, rpid: 1),
      throwsA(isA<BiliApiException>()
          .having((e) => e.message, 'message', contains('评论 id 无效'))),
    );
    expect(a1.requests, isEmpty);

    final a2 = _Adapter({_kDelPath: () => _code(0)});
    await expectLater(
      _api(a2).deleteComment(oid: 1, type: 1, rpid: 0),
      throwsA(isA<BiliApiException>()),
    );
    expect(a2.requests, isEmpty);
  });

  test('deleteComment：-404（已经不存在）→ 可读提示，且不自动重试', () async {
    final adapter = _Adapter({_kDelPath: () => _code(-404)});
    await expectLater(
      _api(adapter).deleteComment(oid: 1, type: 1, rpid: 2),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -404)
          .having((e) => e.message, 'message', '内容不存在或已失效')),
    );
    expect(adapter.forPath(_kDelPath), hasLength(1));
  });

  // -------------------------------------------------------------------------
  // 常量本身（口径防漂）
  // -------------------------------------------------------------------------

  test('kCommentMaxLength = 1000（与设置页/输入框提示同一个数）', () {
    expect(kCommentMaxLength, 1000);
  });

  test('kCommentClosedCode = 12002（UI 靠它置灰入口）', () {
    expect(BiliApi.kCommentClosedCode, 12002);
  });
}
