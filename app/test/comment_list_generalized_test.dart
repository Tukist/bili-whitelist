// CommentListView 泛化（v2.25.2+）· **视频侧零回归**测试。
//
// 背景：为了给专栏阅读页复用评论列表，[CommentListView] 新增了一批可选参数
// （oid / commentType / identityKey / header / footerSeed / initialTotal /
// physics / api），`video` 也从 required 变成可空。视频侧（CommentPage、
// player_page 内嵌）**一行都没改**，因此这里把老行为逐条钉死：
//
// 覆盖：
// - **请求参数快照**：视频侧仍是 `{type:'1', oid:<aid>, mode:'3', next:'0'}`
//   —— `type` 参数化后默认值必须与写死时**逐字节一致**；
// - 归属 id 解析链：`initialAid` 命中 → 不打 view；只给 `video` → view 反查；
// - 翻页 `next` 用 cursor.next 原样回传；楼中楼请求仍是 `type=1`；
// - 入场代次串：`identityKey` 为 null 时仍是 `<bvid>#<cid>#<代次>`；
// - `showCountHeader` / `countHeaderKey` / `controller` 在 `header == null`
//   时行为不变；
// - 注入 `api`（新参数）后视频侧照旧上屏、头像可点、楼中楼可展开。
//
// 底部加载文案的 seed（`<bvid>#footer`）另由 comment_block_flow_test 钉住
// （`loadingCopyFor(pool: kLoadingPoolFooter, seed: '$bvid#footer')`），
// 本文件不重复。
//
// 全部走 mock HttpClientAdapter（不触网）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';
import 'package:bili_whitelist_app/widgets/staggered_entrance.dart';

const String _kSpiPath = '/x/frontend/finger/spi';
const String _kNavPath = '/x/web-interface/nav';
const String _kViewPath = '/x/web-interface/view';
const String _kMainPath = '/x/v2/reply/main';
const String _kReplyPath = '/x/v2/reply/reply';

/// 测试视频：aid 由 view 接口给成 1001。
const int kAid = 1001;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1GEN11111',
      cid: 1001,
      title: '视频',
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

Map<String, dynamic> _navBody() => {
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png',
        },
      },
    };

Map<String, dynamic> _viewBody() => {
      'code': 0,
      'data': {'aid': kAid, 'bvid': 'BV1GEN11111', 'cid': 1001},
    };

Map<String, dynamic> _replyJson({
  required int rpid,
  int count = 0,
  String message = '前排',
  List<Map<String, dynamic>>? nested,
}) =>
    {
      'rpid': rpid,
      'oid': kAid,
      'root': 0,
      'parent': 0,
      'count': count,
      'like': 3,
      'ctime': 1700000000,
      'member': {
        'mid': '946974',
        'uname': '评论君',
        'avatar': 'http://i0.hdslb.com/bfs/face/a.jpg',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message},
      if (nested != null) 'replies': nested,
    };

Map<String, dynamic> _mainBody({
  List<Map<String, dynamic>>? replies,
  int next = 0,
  bool isEnd = true,
  int allCount = 0,
}) =>
    {
      'code': 0,
      'data': {
        'replies': replies ?? [_replyJson(rpid: 5001, message: '第一条')],
        'top_replies': [],
        'cursor': {'next': next, 'is_end': isEnd, 'all_count': allCount},
      },
    };

Map<String, dynamic> _childrenBody({
  List<Map<String, dynamic>>? replies,
  int count = 20,
}) =>
    {
      'code': 0,
      'data': {
        'replies': replies ??
            [
              {
                ..._replyJson(rpid: 6001, message: '楼中楼一位'),
                'root': 5001,
                'parent': 5001,
              },
            ],
        'page': {'num': 1, 'size': 20, 'count': count},
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

/// 推进到首屏评论渲染出来（加载态转圈会挂死 pumpAndSettle）。
Future<void> _pumpUntilListed(WidgetTester tester, {int steps = 30}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(AppBlock).evaluate().isNotEmpty) return;
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool settle = false,
}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _pumpUntilListed(tester);
  }
}

void main() {
  setUp(() {
    // 动效默认关（断言静态形态；见 comment_block_flow_test 同款处理）
    MotionControl.enabled = false;
    _mockSecureStorage();
  });

  tearDown(MotionControl.reset);

  testWidgets('请求参数快照：视频侧仍是 type=1 / oid=<aid> / mode=3 / next=0',
      (tester) async {
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(
      tester,
      CommentListView(video: _video(), initialAid: kAid, api: _api(adapter)),
    );

    final req = adapter.forPath(_kMainPath).single;
    // ⚠️ 这条就是「视频侧参数逐字节不变」的锁：type 由写死的 '1' 变成
    // `'$type'`（默认 1）后，参数表必须完全相等。
    expect(req.queryParameters, {
      'type': '1',
      'oid': '$kAid',
      'mode': '3',
      'next': '0',
    });
    expect(find.text('第一条'), findsOneWidget);
  });

  testWidgets('只给 video（无 initialAid/oid）→ 走 view 反查 aid，口径不变',
      (tester) async {
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kNavPath: (_) => _navBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(tester, CommentListView(video: _video(), api: _api(adapter)));

    expect(adapter.forPath(_kViewPath), hasLength(1), reason: '没有 aid 才查 view');
    expect(adapter.forPath(_kMainPath).single.queryParameters['oid'], '$kAid');
  });

  testWidgets('翻页：next 用 cursor.next 原样回传', (tester) async {
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kMainPath: (req) => req.queryParameters['next'] == '0'
          ? _mainBody(
              next: 15,
              isEnd: false,
              allCount: 30,
              replies: [
                _replyJson(rpid: 5001, message: '第一条评论正文'),
                _replyJson(rpid: 5002, message: '第二条评论正文'),
              ],
            )
          : _mainBody(
              next: 0,
              isEnd: true,
              allCount: 30,
              replies: [_replyJson(rpid: 5003, message: '第二页评论正文')],
            ),
    });
    // 视口压矮：内容高于视口才拖得动（见 comment_block_flow_test 同款说明）
    tester.view.physicalSize = const Size(600, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      CommentListView(video: _video(), initialAid: kAid, api: _api(adapter)),
    );
    expect(adapter.forPath(_kMainPath), hasLength(1));

    // 拖拽起点选在块的左内边距里（x=20）：正文是可选文本，落在正文上会被
    // 选择手势抢走拖拽。
    await tester.dragFrom(const Offset(20, 150), const Offset(0, -150));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final reqs = adapter.forPath(_kMainPath);
    expect(reqs.length, greaterThan(1), reason: '触底翻页');
    expect(reqs.last.queryParameters, {
      'type': '1',
      'oid': '$kAid',
      'mode': '3',
      'next': '15', // cursor.next 原样回传（不手写 +1）
    });
  });

  testWidgets('楼中楼：展开请求仍是 type=1（oid/root/pn/ps 口径不变）',
      (tester) async {
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kMainPath: (_) => _mainBody(
            allCount: 30,
            replies: [_replyJson(rpid: 5001, count: 3, message: '第一条评论正文')],
          ),
      _kReplyPath: (_) => _childrenBody(),
    });
    await _pump(
      tester,
      CommentListView(video: _video(), initialAid: kAid, api: _api(adapter)),
    );

    await tester.tap(find.text('3 条回复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(adapter.forPath(_kReplyPath).single.queryParameters, {
      'type': '1',
      'oid': '$kAid',
      'root': '5001',
      'pn': '1',
      'ps': '20',
    });
    expect(find.text('楼中楼一位'), findsOneWidget);
  });

  testWidgets('入场代次串：identityKey 为 null 时仍是 <bvid>#<cid>#<代次>',
      (tester) async {
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(
      tester,
      CommentListView(video: _video(), initialAid: kAid, api: _api(adapter)),
    );

    final scope =
        tester.widget<StaggeredListScope>(find.byType(StaggeredListScope));
    // 首屏 = 第一次 _init → 代次计数 1；串的构造方式与旧版逐字一致
    expect(scope.generation, 'BV1GEN11111#1001#1');
  });

  testWidgets('showCountHeader + countHeaderKey + controller：行为不变',
      (tester) async {
    final key = GlobalKey();
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kMainPath: (_) => _mainBody(allCount: 42),
    });
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        api: _api(adapter),
        showCountHeader: true,
        countHeaderKey: key,
        controller: ctrl,
      ),
    );

    expect(find.text('评论 42'), findsOneWidget, reason: '区头显示 all_count');
    expect(key.currentContext, isNotNull, reason: '区头锚点挂在「评论 N」上');
    // 外部控制器被复用（不是自建的）
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller,
      same(ctrl),
    );
  });

  testWidgets('header == null → 列表结构不变（第 0 项就是评论区头/评论）',
      (tester) async {
    final adapter = _RecordingAdapter({
      _kSpiPath: (_) => _spiBody(),
      _kMainPath: (_) => _mainBody(),
    });
    await _pump(
      tester,
      CommentListView(video: _video(), initialAid: kAid, api: _api(adapter)),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    // 1 条根评论 + 脚部 = 2 项（没有自定义头、没有区头、没有置顶）
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 2);
    expect(list.physics, isNull, reason: '不传 physics 时保持框架默认');
  });
}
