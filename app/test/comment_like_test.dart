// 评论点赞（v2.43.0+）测试：接口构造 + 乐观更新 / 回滚 / 幂等 + 总开关门禁。
//
// 覆盖：
// - **接口构造**（`BiliApi.likeComment`）：POST `x/v2/reply/action`、表单
//   `oid` / `type` / `rpid` / `action` / `csrf`、`contentType` = form-urlencoded；
//   点赞 `action=1`、取消 `action=0`（**与视频点赞的 like=1/2 不同**，正是最容易
//   抄错的地方）；
// - 本机拦下（**零请求**）：oid<=0 / rpid<=0 / type<=0；未登录（无 bili_jct）
//   → 可读的 -101「请先登录 B 站账号」；
// - 错误码分类（-412 风控 / -509 频繁 / 12002 评论区已关闭）；
// - **网络失败原样上抛且不重试**（写接口重试 = 再点一次别人的通知）；
// - **总开关关闭**（`CommentListView.enableCompose=false`）时点赞数是静态展示：
//   点它一个写请求都不发（专栏 / 动态 / 独立评论页三个使用点都是这个默认值）；
// - 开启后：点一下 → **乐观**变实心 + 计数 +1 且请求 action=1；再点一下 →
//   action=0、计数 -1（目标态取反 = 幂等）；已赞态（服务端 `action=1`）从实心
//   开始；
// - 失败 → **回滚**（回到服务端给的状态）+ 错误类提示；
// - 请求在飞 → 轻量反馈（12px 进度圈）+ 连点被忽略（只发一次）。
//
// 全部走 mock HttpClientAdapter（不触网、不发真实写请求）。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/comment.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

const String _kSpiPath = '/x/frontend/finger/spi';
const String _kViewPath = '/x/web-interface/view';
const String _kMainPath = '/x/v2/reply/main';
const String _kActionPath = '/x/v2/reply/action';

const int kAid = 4004;
const int kRootRpid = 5000;
const int kRoot2Rpid = 5001;
const String _kJct = 'jct-like-test';

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1LIKE00001',
      cid: kAid,
      title: '评论点赞测试视频',
      cover: '',
      duration: 120,
      upName: 'up',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// mock HTTP
// ---------------------------------------------------------------------------

/// 可闸门化的 adapter：记录请求，[gate] 非 null 时每个请求先等它（= 在飞）。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];
  Completer<void>? gate;

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  List<RequestOptions> get posts =>
      requests.where((r) => r.method == 'POST').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final g = gate;
    // 只挡写请求：[_injectAuth] 会先打一次只读的 spi 拿指纹，把只读也挡住
    // 会让写请求永远发不出去（假死，而不是"在飞"）。
    if (g != null && options.method == 'POST') await g.future;
    final h = handlers[options.path];
    return ResponseBody.fromString(
      jsonEncode(h == null ? const {'code': 0, 'data': null} : h(options)),
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

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

Map<String, dynamic> _viewBody() => {
      'code': 0,
      'data': {'aid': kAid, 'bvid': 'BV1LIKE00001', 'cid': kAid},
    };

Map<String, dynamic> _replyJson({
  required int rpid,
  required String uname,
  int like = 2,
  int action = 0,
  String? message,
}) =>
    {
      'rpid': rpid,
      'oid': kAid,
      'root': 0,
      'parent': 0,
      'count': 0,
      'like': like,
      // `action` 是位掩码：bit0 = 已点赞（v2.43.0 起解析成 CommentReply.liked）
      'action': action,
      'ctime': 1700000000,
      'member': {
        'mid': '946974',
        'uname': uname,
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message ?? '第 $rpid 条评论'},
    };

Map<String, dynamic> _mainBody(RequestOptions o) => {
      'code': 0,
      'data': {
        'replies': [
          _replyJson(rpid: kRootRpid, uname: '甲', like: 2),
          _replyJson(rpid: kRoot2Rpid, uname: '乙', like: 7, action: 1),
        ],
        'top_replies': <Map<String, dynamic>>[],
        'cursor': {'next': 100, 'is_end': true, 'all_count': 2},
      },
    };

Map<String, Map<String, dynamic> Function(RequestOptions)> _handlers({
  Map<String, dynamic> Function(RequestOptions)? action,
  Map<String, dynamic> Function(RequestOptions)? main,
}) =>
    {
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: main ?? _mainBody,
      _kActionPath:
          action ?? (_) => {'code': 0, 'data': null},
    };

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void _mockSecureStorage({bool loggedIn = true}) {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    if (call.method != 'read') return null;
    if (!loggedIn) return null;
    const store = {
      'bili_sessdata': '100%2C9999999999%2Cabcdef',
      'bili_jct': _kJct,
    };
    return store[args['key'] as String?];
  });
}

Map<String, String> _form(RequestOptions r) =>
    Map<String, String>.from(r.data as Map);

// ---------------------------------------------------------------------------
// widget 助手
// ---------------------------------------------------------------------------

/// 一路 pump 到首屏评论渲染出来（加载转圈会挂死 pumpAndSettle）。
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  int steps = 40,
}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(AppBlock).evaluate().isNotEmpty) return;
  }
}

/// 显式推进若干帧（**不用 pumpAndSettle**：列表里可能有转圈）。
Future<void> _settle(WidgetTester tester, {int steps = 12}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 某条评论的点赞入口（只有开启写能力时才构建 `_LikeAffordance`）。
Finder _likeOf(int rpid) => find.byKey(ValueKey('comment-like-$rpid'));

/// 点赞入口当前显示的数字。
String _likeCount(WidgetTester tester, int rpid) => tester
    .widget<Text>(
      find.descendant(of: _likeOf(rpid), matching: find.byType(Text)),
    )
    .data!;

/// 点赞入口当前是否是"已赞"（实心图标）。
bool _likeFilled(WidgetTester tester, int rpid) => find
    .descendant(of: _likeOf(rpid), matching: find.byIcon(Icons.thumb_up_alt))
    .evaluate()
    .isNotEmpty;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MotionControl.enabled = false;
    _mockSecureStorage();
    UiPrefsStore.instance.resetForTest(showTips: true);
  });

  tearDown(() {
    MotionControl.reset();
    UiPrefsStore.instance.resetForTest(loaded: false);
  });

  // -------------------------------------------------------------------------
  // 接口构造
  // -------------------------------------------------------------------------

  group('likeComment 请求构造', () {
    test('点赞：POST /x/v2/reply/action + oid/type/rpid/action=1/csrf', () async {
      final adapter = _Adapter(_handlers());
      await _api(adapter).likeComment(
        oid: 80433022,
        type: 1,
        rpid: 123456789,
        like: true,
      );

      final req = adapter.forPath(_kActionPath).single;
      expect(req.method, 'POST');
      expect(req.contentType, Headers.formUrlEncodedContentType);
      expect(_form(req), {
        'oid': '80433022',
        'type': '1',
        'rpid': '123456789',
        'action': '1',
        'csrf': _kJct,
      });
    });

    test('取消赞：action=0（**不是 2**——那是视频点赞的取值习惯）', () async {
      final adapter = _Adapter(_handlers());
      await _api(adapter).likeComment(
        oid: 1,
        type: 12,
        rpid: 2,
        like: false,
      );

      expect(_form(adapter.forPath(_kActionPath).single)['action'], '0');
    });

    test('oid/rpid/type 非法：本机拦下，一个请求都不发', () async {
      final adapter = _Adapter(_handlers());
      final api = _api(adapter);

      await expectLater(
        api.likeComment(oid: 0, type: 1, rpid: 5, like: true),
        throwsA(isA<BiliApiException>()),
      );
      await expectLater(
        api.likeComment(oid: 1, type: 1, rpid: 0, like: true),
        throwsA(isA<BiliApiException>()),
      );
      await expectLater(
        api.likeComment(oid: 1, type: 0, rpid: 5, like: true),
        throwsA(isA<BiliApiException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test('未登录（无 bili_jct）：可读的 -101，且零 POST', () async {
      _mockSecureStorage(loggedIn: false);
      final adapter = _Adapter(_handlers());

      await expectLater(
        _api(adapter).likeComment(oid: 1, type: 1, rpid: 2, like: true),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('请先登录'))),
      );
      expect(adapter.posts, isEmpty, reason: '没登录就别发出去换 -111');
    });

    test('错误码分类：-412 风控 / -509 频繁 / 12002 评论区关闭', () async {
      for (final (code, expectText) in [
        (-412, '操作被风控拦截'),
        (-509, '操作过于频繁'),
        (12002, '该评论区已关闭'),
      ]) {
        final adapter =
            _Adapter(_handlers(action: (_) => {'code': code, 'message': 'x'}));
        await expectLater(
          _api(adapter).likeComment(oid: 1, type: 1, rpid: 2, like: true),
          throwsA(isA<BiliApiException>()
              .having((e) => e.message, 'message', contains(expectText))),
          reason: 'code=$code',
        );
      }
    });

    test('网络失败：原样上抛，且**不重试**（只有一次 POST）', () async {
      final adapter = _NetFailAdapter();
      await expectLater(
        _api(adapter).likeComment(oid: 1, type: 1, rpid: 2, like: true),
        throwsA(isA<DioException>()),
      );
      expect(
        adapter.requests.where((r) => r.method == 'POST').length,
        1,
        reason: '写接口重试 = 再点一次别人的通知，绝不能自动重试',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 模型：action 位掩码解析
  // -------------------------------------------------------------------------

  group('CommentReply.liked（action 位掩码）', () {
    test('action=1 → 已赞；action=0/缺失 → 未赞', () {
      expect(CommentReply.likedFromAction(1), isTrue);
      expect(CommentReply.likedFromAction(0), isFalse);
      expect(CommentReply.likedFromAction(null), isFalse);
      expect(CommentReply.likedFromAction('2'), isFalse);
    });

    test('action=3（既赞又踩）→ 仍算已赞（**不能写成 action == 1**）', () {
      expect(CommentReply.likedFromAction(3), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // widget：总开关 + 乐观更新 + 回滚 + 幂等
  // -------------------------------------------------------------------------

  testWidgets('总开关关闭：点赞数是静态展示，点它一个写请求都不发', (tester) async {
    final adapter = _Adapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        api: _api(adapter),
        // enableCompose 默认 false（专栏 / 动态 / 独立评论页三个使用点）
      ),
    );

    expect(find.byType(AppBlock), findsWidgets);
    expect(_likeOf(kRootRpid), findsNothing,
        reason: '默认关时连可点入口都不构建（渲染树逐节点不变）');
    expect(find.byIcon(Icons.thumb_up_alt_outlined), findsWidgets,
        reason: '静态展示仍在（图标 + 数字）');
    expect(adapter.posts, isEmpty);
  });

  testWidgets('开启后：点一下 → 乐观变实心 + 计数 +1 + action=1', (tester) async {
    final handle = tester.ensureSemantics();
    final adapter = _Adapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );

    // 甲：like=2 未赞；乙：like=7 已赞（服务端 action=1）
    expect(_likeCount(tester, kRootRpid), '2');
    expect(_likeFilled(tester, kRootRpid), isFalse);
    expect(_likeCount(tester, kRoot2Rpid), '7');
    expect(_likeFilled(tester, kRoot2Rpid), isTrue,
        reason: '服务端 action=1 → 初始就是实心（已赞）');

    await tester.tap(_likeOf(kRootRpid));
    await _settle(tester);

    expect(_likeFilled(tester, kRootRpid), isTrue,
        reason: '乐观：立刻变已赞（不等网络）');
    expect(_likeCount(tester, kRootRpid), '3', reason: '计数 +1');
    final posts = adapter.forPath(_kActionPath);
    expect(posts.length, 1);
    final form = _form(posts.single);
    expect(form['rpid'], '$kRootRpid');
    expect(form['oid'], '$kAid');
    expect(form['type'], '1');
    expect(form['action'], '1');
    handle.dispose();
  });

  testWidgets('点两次：第二次传 action=0 且计数回退（目标态取反 = 幂等）',
      (tester) async {
    final handle = tester.ensureSemantics();
    final adapter = _Adapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );

    await tester.tap(_likeOf(kRootRpid));
    await _settle(tester);
    expect(_likeCount(tester, kRootRpid), '3');

    await tester.tap(_likeOf(kRootRpid));
    await _settle(tester);

    expect(_likeFilled(tester, kRootRpid), isFalse, reason: '再点回未赞');
    expect(_likeCount(tester, kRootRpid), '2', reason: '计数回 2');
    final forms = adapter.forPath(_kActionPath).map(_form).toList();
    expect(forms.length, 2);
    expect(forms[0]['action'], '1');
    expect(forms[1]['action'], '0', reason: '第二次要传**相反**的目标态');
    expect(forms[1]['rpid'], '$kRootRpid', reason: '还是同一条评论');
    handle.dispose();
  });

  testWidgets('已赞的评论（服务端 action=1）：点一下发 action=0 并变线框',
      (tester) async {
    final handle = tester.ensureSemantics();
    final adapter = _Adapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );

    await tester.tap(_likeOf(kRoot2Rpid));
    await _settle(tester);

    expect(_likeFilled(tester, kRoot2Rpid), isFalse);
    expect(_likeCount(tester, kRoot2Rpid), '6');
    expect(_form(adapter.forPath(_kActionPath).single)['action'], '0');
    handle.dispose();
  });

  testWidgets('失败（-412）：回滚到服务端状态 + 错误类提示', (tester) async {
    final handle = tester.ensureSemantics();
    final adapter = _Adapter(
      _handlers(action: (_) => {'code': -412, 'message': '风控'}),
    );
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );

    await tester.tap(_likeOf(kRootRpid));
    await _settle(tester);

    expect(_likeFilled(tester, kRootRpid), isFalse,
        reason: '失败必须回滚，不能停在假已赞');
    expect(_likeCount(tester, kRootRpid), '2', reason: '计数也回滚');
    expect(find.textContaining('点赞失败'), findsOneWidget,
        reason: '错误类提示（关掉"界面提示"也不该静默）');
    expect(find.textContaining('操作被风控拦截'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('请求在飞：轻量反馈（12px 进度圈）+ 连点只发一次', (tester) async {
    final handle = tester.ensureSemantics();
    final adapter = _Adapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );

    adapter.gate = Completer<void>(); // 把写请求钉在"在飞"
    await tester.tap(_likeOf(kRootRpid));
    await _settle(tester, steps: 6); // 等 chip 的 spi 指纹请求走完、POST 真正发出

    expect(adapter.forPath(_kActionPath).length, 1, reason: '第一次已发出');
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '点赞中给轻量反馈（12px 小圈）');

    // 连点：被忽略（防连点），不会第二次发请求
    await tester.tap(_likeOf(kRootRpid));
    await tester.pump();
    expect(adapter.forPath(_kActionPath).length, 1, reason: '在飞期间连点被忽略');

    adapter.gate!.complete();
    adapter.gate = null;
    await _settle(tester);
    expect(_likeFilled(tester, kRootRpid), isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    handle.dispose();
  });

  testWidgets('评论区已关闭（12002）：点赞入口置灰、点了不发请求', (tester) async {
    final handle = tester.ensureSemantics();
    // 主评论接口回 12002 → _commentClosed = true（与发表入口同一套门禁）
    final adapter = _Adapter(_handlers(
      main: (_) => {'code': 12002, 'message': '评论区已关闭'},
    ));
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );
    await _settle(tester);

    expect(adapter.forPath(_kActionPath), isEmpty,
        reason: '评论区关了就别装作能点赞（门禁与发表入口同源）');
    handle.dispose();
  });
}
