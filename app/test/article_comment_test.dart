// 专栏阅读页 · 评论区（v2.26.0+）测试（注入 mock BiliApi，不访问真实网络）。
//
// 覆盖：
// - **请求口径**：专栏评论是 `type=12` + `oid=<cvid>`（视频评论才是 type=1）
//   —— 传错 type 不报错、静默给错数据，所以这条必须钉死；
// - 评论上屏 + 「评论 N」区头（区头初值取正文 stats.reply，首屏后被
//   cursor.all_count 覆盖）；
// - **正文（header）与评论在同一个滚动体内**：整页只有一个 ListView，
//   正文与评论都是它的后代（这是「不 shrinkWrap」的结构证明）；
// - 楼中楼展开：请求同样透传 type=12；
// - 分页：next 用 cursor.next 原样回传（同样带 type=12）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/article_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';

const String _kSpiPath = '/x/frontend/finger/spi';
const String _kViewPath = '/x/article/view';
const String _kMainPath = '/x/v2/reply/main';
const String _kReplyPath = '/x/v2/reply/reply';

const int kCvid = 45123193;

/// 正文里的段落标记（断言「正文与评论同体」时用它定位）。
const String kBodyText = '正文第一段';

// ---------------------------------------------------------------------------
// mock HTTP
// ---------------------------------------------------------------------------

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handlers);

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

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

/// 正文（`stats.reply` = 5：区头初值；首屏评论到货后被 all_count 覆盖）。
Map<String, dynamic> _viewBody({
  String content = '<p>$kBodyText</p>',
  int replyStat = 5,
}) =>
    {
      'code': 0,
      'data': {
        'id': kCvid,
        'title': '专栏标题',
        'content': content,
        'publish_time':
            DateTime.now().subtract(const Duration(hours: 4)).millisecondsSinceEpoch ~/
                1000,
        'author': {'mid': 946974, 'name': '测试作者', 'face': ''},
        'stats': {'view': 1932, 'like': 97, 'favorite': 48, 'reply': replyStat},
      },
    };

Map<String, dynamic> _replyJson({
  required int rpid,
  int count = 0,
  String message = '专栏评论一',
  List<Map<String, dynamic>>? nested,
}) =>
    {
      'rpid': rpid,
      'oid': kCvid, // 专栏评论的 oid 就是 cvid
      'root': 0,
      'parent': 0,
      'count': count,
      'like': 7,
      'ctime': 1700000000,
      'member': {
        'mid': '946974',
        'uname': '评论君',
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message},
      if (nested != null) 'replies': nested,
    };

Map<String, dynamic> _mainBody({
  List<Map<String, dynamic>>? replies,
  int next = 0,
  bool isEnd = true,
  int allCount = 693,
}) =>
    {
      'code': 0,
      'data': {
        'replies': replies ??
            [
              _replyJson(rpid: 7001, count: 2, message: '专栏评论一'),
              _replyJson(rpid: 7002, message: '专栏评论二'),
            ],
        'top_replies': [],
        'cursor': {'next': next, 'is_end': isEnd, 'all_count': allCount},
      },
    };

Map<String, dynamic> _childrenBody() => {
      'code': 0,
      'data': {
        'replies': [
          {
            ..._replyJson(rpid: 8001, message: '专栏楼中楼'),
            'root': 7001,
            'parent': 7001,
          },
        ],
        'page': {'num': 1, 'size': 20, 'count': 2},
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

/// 挂载专栏页并推进到评论渲染出来（加载态转圈会挂死 pumpAndSettle）。
Future<void> _pump(WidgetTester tester, HttpClientAdapter adapter) async {
  await tester.pumpWidget(MaterialApp(
    home: ArticlePage(cvid: kCvid, api: _api(adapter)),
  ));
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(AppBlock).evaluate().isNotEmpty) return;
  }
}

void main() {
  setUp(() {
    MotionControl.enabled = false; // 断言静态形态
    _mockSecureStorage();
  });

  tearDown(MotionControl.reset);

  testWidgets('专栏评论口径：type=12 + oid=<cvid>；评论上屏 + 「评论 N」区头',
      (tester) async {
    final adapter = _Adapter({
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(tester, adapter);

    final req = adapter.forPath(_kMainPath).single;
    // ⚠️ 传错 type/oid 不报错（静默给错数据）→ 这条是专栏评论的关键锁
    expect(req.queryParameters, {
      'type': '12',
      'oid': '$kCvid',
      'mode': '3',
      'next': '0',
    });
    expect(find.text('专栏评论一'), findsOneWidget);
    expect(find.text('专栏评论二'), findsOneWidget);
    // 区头计数：先用正文 stats.reply（5）顶着，首屏到货后覆盖成 all_count
    expect(find.text('评论 693'), findsOneWidget);
  });

  testWidgets('正文（header）与评论在同一个滚动体里：整页只有一个 ListView',
      (tester) async {
    final adapter = _Adapter({
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(tester, adapter);

    expect(find.byType(ListView), findsOneWidget, reason: '不是「外层列表 + 内层列表」');
    final list = find.byType(ListView);
    expect(
      find.descendant(of: list, matching: find.text(kBodyText)),
      findsOneWidget,
      reason: '正文是评论列表的第 0 项（header）',
    );
    expect(
      find.descendant(of: list, matching: find.text('专栏评论一')),
      findsOneWidget,
      reason: '评论与正文同体',
    );
    // 正文在上、评论在下（顺序锁：区头「评论 N」排在正文之后）
    final bodyY = tester.getTopLeft(find.text(kBodyText)).dy;
    final headY = tester.getTopLeft(find.text('评论 693')).dy;
    expect(headY, greaterThan(bodyY));

    // 同一个滚动体 → 拖动列表，正文与评论一起动
    await tester.dragFrom(const Offset(20, 300), const Offset(0, -120));
    await tester.pump();
    expect(tester.getTopLeft(find.text(kBodyText)).dy, lessThan(bodyY),
        reason: '正文随同一个滚动体上移');
  });

  testWidgets('楼中楼：展开请求同样透传 type=12', (tester) async {
    final adapter = _Adapter({
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: (_) => _mainBody(),
      _kReplyPath: (_) => _childrenBody(),
    });
    await _pump(tester, adapter);

    await tester.tap(find.text('2 条回复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(adapter.forPath(_kReplyPath).single.queryParameters, {
      'type': '12',
      'oid': '$kCvid',
      'root': '7001',
      'pn': '1',
      'ps': '20',
    });
    expect(find.text('专栏楼中楼'), findsOneWidget);
  });

  testWidgets('分页：next 用 cursor.next 原样回传（仍带 type=12）', (tester) async {
    final adapter = _Adapter({
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: (req) => req.queryParameters['next'] == '0'
          ? _mainBody(
              next: 20,
              isEnd: false,
              replies: [
                _replyJson(rpid: 7001, message: '专栏评论一'),
                _replyJson(rpid: 7002, message: '专栏评论二'),
              ],
            )
          : _mainBody(
              isEnd: true,
              replies: [_replyJson(rpid: 7003, message: '第二页专栏评论')],
            ),
    });
    // 视口压矮（但不低于首屏加载态的高度：太小会把 AppLoadingHero 挤到溢出）：
    // 内容高于视口才拖得动
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, adapter);
    expect(adapter.forPath(_kMainPath), hasLength(1));

    // 拖拽起点选左边距里（正文是可选文本，落在正文上会被选择手势抢走拖拽）
    await tester.dragFrom(const Offset(16, 400), const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final reqs = adapter.forPath(_kMainPath);
    expect(reqs.length, greaterThan(1), reason: '触底翻页');
    expect(reqs.last.queryParameters, {
      'type': '12',
      'oid': '$kCvid',
      'mode': '3',
      'next': '20',
    });
  });

  testWidgets('评论头像 → 作者个人页（专栏页同样可用）', (tester) async {
    final adapter = _Adapter({
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(tester, adapter);

    // 头像热区左上角 = 卡内 (12,12)、48 见方 → 取 (24,24) 稳落在热区里
    // （与 comment_avatar_tap_test 同一套点法：不依赖 InkWell 查找）
    final block = find.byType(AppBlock).first;
    final tl = tester.getTopLeft(block);
    await tester.tapAt(tl + const Offset(24, 24));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(UpownerPage).evaluate().isNotEmpty) break;
    }
    expect(find.byType(UpownerPage), findsOneWidget, reason: '进作者主页');

    // 被 push 的 UP 主页用的是**它自建的 BiliApi**（测试环境一律 400）→ 其退避
    // 重试会留下 1s / 2s 定时器。把假时间走完，别让用例结束时报 pending timer
    // （本用例只验「头像能进个人页」这条链路）。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
