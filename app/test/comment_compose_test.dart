// 评论区「发表评论 / 回复」（v2.42.0+）widget 测试。
//
// 覆盖：
// - **默认关（[CommentListView.enableCompose] = false）逐字节不变**：没有
//   「说点什么…」入口行、没有「回复」按钮、入口点击不产生任何请求——专栏 /
//   动态 / 独立评论页三个使用点都是这个默认值；
// - 开启后：区头下方出现「说点什么…」，点它弹底部弹层（**不是常驻输入框**）；
// - 发送成功：请求字段正确（oid/type/message/csrf，顶层评论不带 root/parent）
//   → 弹层关闭 → **重拉第一页**（next=0 再来一次）→ 成功提示；
// - 回复根评论：预填 `@某人 `，请求 `root == parent == 该评论 rpid`；
// - 回复楼中楼里的某条子回复：`root` = 根评论、`parent` = 子回复（两者不等）；
// - 失败（-412 / 网络）：**弹层不关**（用户打的字还在）+ 内联错误 + 错误类
//   提示条（设置里关掉提示条也挡不住）；
// - 失败（12002）：入口置灰 + 写「该评论区已关闭」（持久状态，不再让用户撞墙）；
// - 空正文：发送按钮禁用（一个请求都不发）；
// - **口径**：视频 `type=1 + oid=aid`、专栏 `type=12 + oid=cvid`、
//   动态 `type=basic.comment_type + oid=basic.comment_id_str`——三条各一个断言
//   （v2.31.0 的动态评论就是口径传错，静默拿到 -404）；
// - **与「整片横滑切排序」共存**：两者同时开启时，横滑照样切排序且不会误开
//   弹层、点入口照样开弹层且不会误切排序。
//
// 全部走 mock HttpClientAdapter（不触网、不发真实写请求）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

const String _kSpiPath = '/x/frontend/finger/spi';
const String _kViewPath = '/x/web-interface/view';
const String _kMainPath = '/x/v2/reply/main';
const String _kChildrenPath = '/x/v2/reply/reply';
const String _kAddPath = '/x/v2/reply/add';

/// 测试视频的 aid（显式给成 initialAid，不走 view 反查也行）。
const int kAid = 4004;
const String _kJct = 'jct-compose-test';

/// 根评论 / 子回复的 rpid（断言 root/parent 用）。
const int kRootRpid = 5000;
const int kChildRpid = 6001;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1COMPOSE01',
      cid: kAid,
      title: '发表评论测试视频',
      cover: '',
      duration: 120,
      upName: 'up',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// mock HTTP
// ---------------------------------------------------------------------------

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
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

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

Map<String, dynamic> _viewBody() => {
      'code': 0,
      'data': {'aid': kAid, 'bvid': 'BV1COMPOSE01', 'cid': kAid},
    };

Map<String, dynamic> _replyJson({
  required int rpid,
  required String uname,
  int oid = kAid,
  String? message,
  int count = 0,
  List<Map<String, dynamic>> previews = const [],
}) =>
    {
      'rpid': rpid,
      'oid': oid,
      'root': 0,
      'parent': 0,
      'count': count,
      'like': 2,
      'ctime': 1700000000,
      'member': {
        'mid': '946974',
        'uname': uname,
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message ?? '第 $rpid 条评论'},
      if (previews.isNotEmpty) 'replies': previews,
    };

/// 主评论首屏：两条根评论，第一条带 2 条楼中楼回复（count=2）。
///
/// `oid` 取自**请求参数**而不是写死 kAid：组件会丢弃 `oid` 与归属 id 不一致的
/// 脏条目（见 `_parseReplyList`），写死会让专栏/动态形态的用例静默变成空列表。
Map<String, dynamic> _mainBody(RequestOptions o) {
  final oid = int.tryParse(o.queryParameters['oid'] as String? ?? '') ?? kAid;
  return {
    'code': 0,
    'data': {
      'replies': [
        _replyJson(
          rpid: kRootRpid,
          uname: '甲',
          oid: oid,
          count: 2,
          previews: [
            _replyJson(rpid: 7001, uname: '乙', oid: oid),
            _replyJson(rpid: 7002, uname: '丙', oid: oid),
          ],
        ),
        _replyJson(rpid: 5001, uname: '丁', oid: oid),
      ],
      'top_replies': <Map<String, dynamic>>[],
      'cursor': {
        'next': o.queryParameters['next'] == '0' ? 100 : 200,
        'is_end': false,
        'all_count': 9,
      },
    },
  };
}

Map<String, dynamic> _childrenBody() => {
      'code': 0,
      'data': {
        'replies': [
          _replyJson(rpid: kChildRpid, uname: '乙', message: '乙的回复'),
        ],
        'page': {'count': 1},
      },
    };

/// 一整套 handler，[main] / [add] 可被单条用例覆盖。
Map<String, Map<String, dynamic> Function(RequestOptions)> _handlers({
  Map<String, dynamic> Function(RequestOptions)? main,
  Map<String, dynamic> Function()? add,
}) =>
    {
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: main ?? _mainBody,
      _kChildrenPath: (_) => _childrenBody(),
      _kAddPath: add == null ? (_) => {'code': 0, 'data': {'rpid': 987654321}} : (_) => add(),
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
    final args = (call.arguments as Map?) ?? const {};
    if (call.method != 'read') return null;
    const store = {
      'bili_sessdata': '100%2C9999999999%2Cabcdef',
      'bili_jct': _kJct,
    };
    return store[args['key'] as String?];
  });
}

// ---------------------------------------------------------------------------
// 挂载 / 取值助手
// ---------------------------------------------------------------------------

/// 一路 pump 到首屏评论渲染出来（加载转圈会挂死 pumpAndSettle）。
Future<void> _pump(WidgetTester tester, Widget child, {int steps = 40}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(AppBlock).evaluate().isNotEmpty) return;
  }
}

/// 显式推进若干帧（**不用 pumpAndSettle**：重拉第一页时列表在转圈，
/// pumpAndSettle 会一直等它转完）。
Future<void> _settle(WidgetTester tester, {int steps = 12}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 评论列表内部的滚动控制器偏移（横滑共存用例用）。
double _pixels(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
            of: find.byType(CommentListView), matching: find.byType(Scrollable))
        .first)
    .position
    .pixels;

/// 横滑起手点：从评论块左内边距（x=20）起，避开正文的选择手势。
Offset _startPoint(WidgetTester tester, {double y = 0.4}) {
  final r = tester.getRect(find.byType(CommentListView));
  return Offset(r.left + 20, r.top + r.height * y);
}

Map<String, String> _form(RequestOptions r) =>
    Map<String, String>.from(r.data as Map);

/// 打开弹层 → 输入 → 点发送（完整的"发一条评论"动作）。
Future<void> _composeAndSend(
  WidgetTester tester,
  String text, {
  Finder? entry,
  bool clearFirst = false,
}) async {
  await tester.tap(entry ?? find.byKey(kCommentComposeEntryKey));
  await _settle(tester, steps: 6);
  if (clearFirst) {
    // 回复场景里有预填的 `@某人 `：直接 enterText 会覆盖整段，正好当"用户全删
    // 重打"用；这里只做显式清空，语义更清楚
    await tester.enterText(find.byKey(kCommentComposeFieldKey), '');
  }
  await tester.enterText(find.byKey(kCommentComposeFieldKey), text);
  await tester.pump();
  await tester.tap(find.byKey(kCommentComposeSendKey));
  await _settle(tester);
}

void main() {
  setUp(() {
    MotionControl.enabled = false; // 断言静态形态
    _mockSecureStorage();
    // 提示条开关（AppSnack 的成功/错误都靠它放行）
    UiPrefsStore.instance.resetForTest(showTips: true);
  });

  tearDown(() {
    MotionControl.reset();
    UiPrefsStore.instance.resetForTest(loaded: false);
  });

  // -------------------------------------------------------------------------
  // 默认关：逐字节不变
  // -------------------------------------------------------------------------

  testWidgets('默认关：没有「说点什么…」入口，也没有任何「回复」按钮', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        api: _api(adapter),
      ),
    );

    expect(find.byKey(kCommentComposeEntryKey), findsNothing);
    expect(find.text('说点什么…'), findsNothing);
    expect(find.text('回复'), findsNothing);
    expect(find.byKey(commentReplyKey(kRootRpid)), findsNothing);
    // 读链路参数与 v2.41.0 完全一致（没被这一版改动碰到）
    expect(adapter.forPath(_kMainPath).single.queryParameters, {
      'type': '1',
      'oid': '$kAid',
      'mode': '3',
      'next': '0',
    });
  });

  testWidgets('默认关：列表条目数与开启时只差"入口行"这一项', (tester) async {
    // 用同一条数据源分别渲染两遍，比较列表项数（开启 = 多一个固定槽位）
    final off = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        api: _api(off),
      ),
    );
    final offTiles = find.byType(AppBlock).evaluate().length;

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    final on = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(on),
      ),
    );
    expect(find.byType(AppBlock).evaluate().length, offTiles,
        reason: '多出来的只是入口行，评论块本身不多不少');
    expect(find.byKey(kCommentComposeEntryKey), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // 开启：入口 + 弹层
  // -------------------------------------------------------------------------

  testWidgets('开启：区头下方出现「说点什么…」，区头排序词条不受影响', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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

    expect(find.byKey(kCommentComposeEntryKey), findsOneWidget);
    expect(find.text('说点什么…'), findsOneWidget);
    expect(find.text('评论 9'), findsOneWidget);
    // 入口在区头**下方**：入口的 y 必须大于区头的 y
    final headerY = tester.getTopLeft(find.text('评论 9')).dy;
    final entryY = tester.getTopLeft(find.byKey(kCommentComposeEntryKey)).dy;
    expect(entryY, greaterThan(headerY));
    // 没开排序横滑 → 词条不该因为开了发表就冒出来
    expect(find.byKey(kCommentSortHotKey), findsNothing);
  });

  testWidgets('默认关（专栏 / 动态形态，带头部）：列表里没有任何发表相关节点',
      (tester) async {
    // 另三个使用点（专栏阅读页 / 动态详情页 / 独立评论页）走的就是这个形态：
    // header 是正文整块 + 默认不开发表。这里锁"一个发表相关节点都没有"，
    // 配合各页自己的既有用例（article_comment / dynamic_detail_page）构成
    // "渲染树不变"的双保险。
    for (final oid in [987654, 326122895]) {
      final adapter = _RecordingAdapter(_handlers());
      await _pump(
        tester,
        CommentListView(
          oid: oid,
          commentType: oid == 987654 ? 12 : 11,
          identityKey: 'k$oid',
          showCountHeader: true,
          header: const SizedBox(height: 30, child: Text('正文')),
          physics: const AlwaysScrollableScrollPhysics(),
          api: _api(adapter),
        ),
      );

      expect(find.text('正文'), findsOneWidget, reason: '正文头照旧在第一项');
      expect(find.text('评论 9'), findsOneWidget);
      // 2 条根评论块 + 第 1 条内嵌的楼中楼预览块（同一份 mock 数据）
      expect(find.byType(AppBlock), findsNWidgets(3));
      expect(find.byKey(kCommentComposeEntryKey), findsNothing);
      expect(find.text('说点什么…'), findsNothing);
      expect(find.text('回复'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets('点入口 → 弹底部弹层（多行输入 + 字数上限提示 + 发送/取消）',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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
    expect(find.byKey(kCommentComposeSheetKey), findsNothing, reason: '弹层不该常驻');

    await tester.tap(find.byKey(kCommentComposeEntryKey));
    await _settle(tester, steps: 6);

    expect(find.byKey(kCommentComposeSheetKey), findsOneWidget);
    expect(find.byKey(kCommentComposeFieldKey), findsOneWidget);
    expect(find.byKey(kCommentComposeSendKey), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 打开弹层本身**不该发任何写请求**
    expect(adapter.forPath(_kAddPath), isEmpty);
    final field =
        tester.widget<TextField>(find.byKey(kCommentComposeFieldKey));
    expect(field.maxLines, greaterThan(1), reason: '多行');
    expect(field.maxLength, kCommentMaxLength, reason: 'B 站上限 1000 字');
  });

  testWidgets('空正文：发送按钮禁用，一个请求都不发', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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
    await tester.tap(find.byKey(kCommentComposeEntryKey));
    await _settle(tester, steps: 6);

    final btn = tester.widget<TextButton>(
        find.byKey(kCommentComposeSendKey));
    expect(btn.onPressed, isNull, reason: '空正文不能发');

    // 只有空白也一样
    await tester.enterText(find.byKey(kCommentComposeFieldKey), '   ');
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.byKey(kCommentComposeSendKey))
            .onPressed,
        isNull);
    expect(adapter.forPath(_kAddPath), isEmpty);
  });

  // -------------------------------------------------------------------------
  // 发表：成功
  // -------------------------------------------------------------------------

  testWidgets('发表成功：请求字段正确 → 弹层关闭 → 重拉第一页 → 成功提示',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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
    final mainBefore = adapter.forPath(_kMainPath).length;

    await _composeAndSend(tester, 'amoTV test comment, will delete');

    // ① 请求构造
    final req = adapter.forPath(_kAddPath).single;
    expect(req.method, 'POST');
    expect(req.contentType, Headers.formUrlEncodedContentType);
    expect(_form(req), {
      'oid': '$kAid',
      'type': '1', // 视频口径：type=1 + oid=aid
      'message': 'amoTV test comment, will delete',
      'csrf': _kJct,
    }, reason: '顶层评论不带 root/parent');

    // ② 弹层关闭 + ③ 重拉第一页（next 回到 0）
    expect(find.byKey(kCommentComposeSheetKey), findsNothing);
    final mainAfter = adapter.forPath(_kMainPath);
    expect(mainAfter.length, greaterThan(mainBefore),
        reason: '发布成功后要刷新评论区');
    expect(mainAfter.last.queryParameters['next'], '0', reason: '重新拉第一页');
    expect(mainAfter.last.queryParameters['mode'], '3', reason: '排序档位不变');

    // ④ 成功提示（info 类）
    expect(find.text('评论已发表'), findsOneWidget);
  });

  testWidgets('发表成功：评论总数跟着刷新（cursor.all_count 回传宿主）',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    final counts = <int>[];
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        onCountChanged: counts.add,
        api: _api(adapter),
      ),
    );
    await _composeAndSend(tester, 'hello');
    expect(counts, isNotEmpty);
    expect(counts.last, 9, reason: 'all_count 到货后回传宿主（独立页 AppBar 用）');
  });

  // -------------------------------------------------------------------------
  // 回复：root / parent
  // -------------------------------------------------------------------------

  testWidgets('回复根评论：预填 `@甲 `，请求 root == parent == 该评论 rpid',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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

    await tester.tap(find.byKey(commentReplyKey(kRootRpid)));
    await _settle(tester, steps: 6);

    final field =
        tester.widget<TextField>(find.byKey(kCommentComposeFieldKey));
    expect(field.controller!.text, '@甲 ',
        reason: '回复要先 @ 上对方（与网页端一致）');
    expect(find.text('回复 甲'), findsOneWidget);

    await tester.enterText(
        find.byKey(kCommentComposeFieldKey), '@甲 回你一句');
    await tester.pump();
    await tester.tap(find.byKey(kCommentComposeSendKey));
    await _settle(tester);

    expect(_form(adapter.forPath(_kAddPath).single), {
      'oid': '$kAid',
      'type': '1',
      'message': '@甲 回你一句',
      'root': '$kRootRpid',
      'parent': '$kRootRpid',
      'csrf': _kJct,
    }, reason: '回复根评论：root 与 parent 都是那条根评论的 rpid');
    expect(find.text('回复已发表'), findsOneWidget);
  });

  testWidgets('回复楼中楼子回复：root=根评论、parent=子回复（两者不等）',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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

    // 先展开楼中楼（拉 reply/reply），子回复行上才有「回复」
    expect(find.byKey(commentReplyKey(kChildRpid)), findsNothing);
    await tester.tap(find.text('2 条回复'));
    await _settle(tester, steps: 8);
    expect(adapter.forPath(_kChildrenPath), hasLength(1));
    expect(find.byKey(commentReplyKey(kChildRpid)), findsOneWidget);

    await tester.tap(find.byKey(commentReplyKey(kChildRpid)));
    await _settle(tester, steps: 6);
    final field =
        tester.widget<TextField>(find.byKey(kCommentComposeFieldKey));
    expect(field.controller!.text, '@乙 ', reason: '被回复的是子回复的作者');

    await tester.enterText(
        find.byKey(kCommentComposeFieldKey), '@乙 回你的回复');
    await tester.pump();
    await tester.tap(find.byKey(kCommentComposeSendKey));
    await _settle(tester);

    final form = _form(adapter.forPath(_kAddPath).single);
    expect(form['root'], '$kRootRpid', reason: 'root 是它所属的**根评论**');
    expect(form['parent'], '$kChildRpid', reason: 'parent 是**被回复的那条**子回复');
    expect(form['root'], isNot(form['parent']),
        reason: '两个值写反会把评论挂到错误楼层（服务端不报错）');
  });

  // -------------------------------------------------------------------------
  // 失败：弹层不关 + 可重试
  // -------------------------------------------------------------------------

  testWidgets('失败（-412 风控）：弹层**不关** + 内联错误 + 错误类提示条',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers(
      add: () => {'code': -412, 'message': '风控'},
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
    await _composeAndSend(tester, '会被风控拦下的评论');

    expect(find.byKey(kCommentComposeSheetKey), findsOneWidget,
        reason: '失败必须留住弹层，否则用户打的字就没了');
    final field =
        tester.widget<TextField>(find.byKey(kCommentComposeFieldKey));
    expect(field.controller!.text, '会被风控拦下的评论', reason: '正文还在，可直接再点发送');
    expect(find.byKey(kCommentComposeErrorKey), findsOneWidget);
    expect(find.text('操作被风控拦截，请稍后再试'), findsOneWidget, reason: '内联原因');
    expect(find.text('发表失败：操作被风控拦截，请稍后再试'), findsOneWidget,
        reason: '错误类提示条（关掉"显示底部提示条"也照样弹）');
    // 失败不刷新
    expect(adapter.forPath(_kMainPath), hasLength(1));
  });

  testWidgets('失败（-412）：设置里关掉提示条 → 错误提示**照样弹**', (tester) async {
    UiPrefsStore.instance.resetForTest(showTips: false);
    final adapter = _RecordingAdapter(_handlers(
      add: () => {'code': -412, 'message': '风控'},
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
    await _composeAndSend(tester, 'x');

    expect(find.text('发表失败：操作被风控拦截，请稍后再试'), findsOneWidget,
        reason: '失败静默比多看一条提示糟糕得多');
  });

  testWidgets('失败（网络）：文案说"可能没发出去"，不当成功也不说死失败',
      (tester) async {
    // 用会抛网络异常的 adapter：只让 add 路径炸，读路径正常
    final adapter = _RecordingAdapter(_handlers());
    final netFail = _NetFailOnPath(_kAddPath, adapter);
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableCompose: true,
        api: _api(netFail),
      ),
    );
    await _composeAndSend(tester, 'x');

    expect(find.byKey(kCommentComposeSheetKey), findsOneWidget);
    // 两处都给：内联（弹层里，用户真正看得见的那一份）+ 提示条（错误类，不被开关静默）
    final inline = tester.widget<Text>(find.byKey(kCommentComposeErrorKey));
    expect(inline.data, contains('评论可能没发出去'));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(adapter.forPath(_kMainPath), hasLength(1), reason: '没成功就不刷新');
  });

  testWidgets('失败：再点一次发送能成功（弹层没关 = 真的能重试）', (tester) async {
    var fail = true;
    final adapter = _RecordingAdapter(_handlers(
      add: () => fail ? {'code': -509, 'message': '频繁'} : {'code': 0},
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
    await _composeAndSend(tester, '重试也要能发出去');
    expect(find.byKey(kCommentComposeSheetKey), findsOneWidget);

    fail = false;
    await tester.tap(find.byKey(kCommentComposeSendKey));
    await _settle(tester);

    expect(adapter.forPath(_kAddPath), hasLength(2));
    expect(find.byKey(kCommentComposeSheetKey), findsNothing);
    expect(find.text('评论已发表'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // 12002：入口置灰
  // -------------------------------------------------------------------------

  testWidgets('发表时回 12002：入口置灰 + 写「该评论区已关闭」+ 弹层不关',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers(
      add: () => {'code': 12002, 'message': '评论区已关闭'},
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
    await _composeAndSend(tester, 'x');
    expect(find.byKey(kCommentComposeSheetKey), findsOneWidget,
        reason: '失败一律不关弹层（包括"评论区关了"这种持久失败）');

    // 关掉弹层，看入口行
    await tester.tap(find.text('取消'));
    await _settle(tester, steps: 6);

    expect(find.text('该评论区已关闭'), findsOneWidget);
    expect(find.text('说点什么…'), findsNothing);
    // 置灰 = InkWell 的 onTap 为 null（点了不会再发请求）
    final ink = tester.widget<InkWell>(find.descendant(
      of: find.byKey(kCommentComposeEntryKey),
      matching: find.byType(InkWell),
    ));
    expect(ink.onTap, isNull);

    // 再点一次入口：不发任何请求（弹层也打不开）
    await tester.tap(find.byKey(kCommentComposeEntryKey));
    await _settle(tester, steps: 4);
    expect(adapter.forPath(_kAddPath), hasLength(1));
    expect(find.byKey(kCommentComposeSheetKey), findsNothing);
  });

  testWidgets('读主评论时回 12002：入口行照旧在（且已置灰）——有"可置灰的对象"',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers(
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

    expect(find.byKey(kCommentComposeEntryKey), findsOneWidget);
    expect(find.text('该评论区已关闭'), findsOneWidget);
    expect(find.text('说点什么…'), findsNothing);
    final ink = tester.widget<InkWell>(find.descendant(
      of: find.byKey(kCommentComposeEntryKey),
      matching: find.byType(InkWell),
    ));
    expect(ink.onTap, isNull);
  });

  testWidgets('关着发表能力时，12002 只走老路（没有入口行，仍是错误态 + 重试）',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers(
      main: (_) => {'code': 12002, 'message': '评论区已关闭'},
    ));
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        api: _api(adapter),
      ),
    );
    expect(find.byKey(kCommentComposeEntryKey), findsNothing);
    expect(find.text('评论区已关闭'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // 口径（防重演 v2.31.0 的动态评论 -404）
  // -------------------------------------------------------------------------

  testWidgets('口径-视频：type=1 + oid=aid', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
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
    await _composeAndSend(tester, 'x');
    final form = _form(adapter.forPath(_kAddPath).single);
    expect([form['type'], form['oid']], ['1', '$kAid'],
        reason: '视频评论：type=1 + oid=aid');
  });

  testWidgets('口径-专栏：type=12 + oid=cvid', (tester) async {
    const int cvid = 987654;
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        oid: cvid,
        commentType: 12, // 专栏
        identityKey: 'cv$cvid',
        showCountHeader: true,
        enableCompose: true,
        header: const SizedBox(height: 30, child: Text('正文')),
        api: _api(adapter),
      ),
    );
    expect(find.text('说点什么…'), findsOneWidget);
    await _composeAndSend(tester, 'x');
    final form = _form(adapter.forPath(_kAddPath).single);
    expect([form['type'], form['oid']], ['12', '$cvid'],
        reason: '专栏评论：type=12 + oid=cvid（不是视频的 1+aid）');
  });

  testWidgets('口径-动态：type=basic.comment_type + oid=basic.comment_id_str',
      (tester) async {
    // 动态的 (type, oid) **必须**来自服务端 basic 字段（相册型动态是
    // type=11 + rid），不能用 `type=17 + 动态 id`——v2.31.0 实测那是 -404，
    // 而服务端对"配错的口径"不报错、只会静默换一类内容。
    // dynamic_detail_page 的 _commentTypeOf / _commentOid 给出的就是这两个值，
    // 这里锁的是**从组件传下去到写请求**这一段不许被改写。
    const int albumRid = 326122895;
    const int albumCommentType = 11;
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        oid: albumRid,
        commentType: albumCommentType,
        identityKey: 'dyn123',
        showCountHeader: true,
        enableCompose: true,
        header: const SizedBox(height: 30, child: Text('动态正文')),
        api: _api(adapter),
      ),
    );
    // 读也用的是同一对（同一个 commentType / _aid 透传），写必须一致
    expect(adapter.forPath(_kMainPath).single.queryParameters, {
      'type': '$albumCommentType',
      'oid': '$albumRid',
      'mode': '3',
      'next': '0',
    });
    await _composeAndSend(tester, 'x');
    final form = _form(adapter.forPath(_kAddPath).single);
    expect([form['type'], form['oid']],
        ['$albumCommentType', '$albumRid'],
        reason: '写请求必须与读请求同一对 (type, oid)，都来自 basic.*');
  });

  // -------------------------------------------------------------------------
  // 与排序横滑共存
  // -------------------------------------------------------------------------

  testWidgets('共存：两者同时开启 → 横滑照样切排序，且不会误开弹层/发评论',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );
    expect(find.byKey(kCommentComposeEntryKey), findsOneWidget);
    expect(find.byKey(kCommentSortHotKey), findsOneWidget);

    await tester.dragFrom(_startPoint(tester), const Offset(-200, 0));
    await _settle(tester, steps: 6);

    expect(adapter.forPath(_kMainPath).last.queryParameters['mode'], '2',
        reason: '横滑仍然切到「最新」（整片 Listener 没被输入框抢走）');
    expect(find.byKey(kCommentSortHintKey), findsOneWidget);
    expect(find.byKey(kCommentComposeSheetKey), findsNothing,
        reason: '横滑不该顺手把输入弹层打开');
    expect(adapter.forPath(_kAddPath), isEmpty, reason: '更不能顺势发出评论');
  });

  testWidgets('共存：点入口只开弹层，不切排序、不发请求', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );
    final mainBefore = adapter.forPath(_kMainPath).length;

    await tester.tap(find.byKey(kCommentComposeEntryKey));
    await _settle(tester, steps: 6);

    expect(find.byKey(kCommentComposeSheetKey), findsOneWidget);
    expect(adapter.forPath(_kMainPath), hasLength(mainBefore),
        reason: '点入口不该触发排序重载');
    expect(find.byKey(kCommentSortHintKey), findsNothing,
        reason: '没有「已切到…」浮层 = 没切排序');
    // 排序档位也没变（词条仍高亮「热门」）
    final hot = tester.widget<Text>(find.descendant(
        of: find.byKey(kCommentSortHotKey), matching: find.byType(Text)));
    expect(hot.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('共存：弹层开着时在列表区域的横滑不会切排序（弹层自己吃掉手势）',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        enableCompose: true,
        api: _api(adapter),
      ),
    );
    await tester.tap(find.byKey(kCommentComposeEntryKey));
    await _settle(tester, steps: 6);
    final mainBefore = adapter.forPath(_kMainPath).length;
    final pixelsBefore = _pixels(tester);

    // 弹层遮罩把列表挡住了 → 这里从弹层上方的列表区域拖（模拟"手指划到遮罩"）
    await tester.dragFrom(_startPoint(tester, y: 0.1), const Offset(-200, 0));
    await _settle(tester, steps: 6);

    expect(adapter.forPath(_kMainPath), hasLength(mainBefore),
        reason: '弹层（含遮罩）在自己的路由里，横滑到不了列表的 Listener');
    expect(_pixels(tester), pixelsBefore, reason: '列表也没被拖动');
  });
}

/// 只对某个 path 抛网络异常、其余转发的 adapter（验证网络失败分支）。
class _NetFailOnPath implements HttpClientAdapter {
  _NetFailOnPath(this.failPath, this.inner);

  final String failPath;
  final HttpClientAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    if (options.path == failPath) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
