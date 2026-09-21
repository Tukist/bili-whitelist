// 评论区「左右滑切换排序（热门 / 最新）」（v2.40.0+）widget 测试。
//
// 需求（用户原话）：「评论区不能左右划让我有点难受」→ 主智能体定调做
// **整片横滑切「热门 / 最新」排序**（零新接口：`x/v2/reply/main` 的 `mode`
// 参数本来就有；只读探针已确认 mode=2 → cursor.name「最新评论」、按 ctime
// 递减，mode=3 → 「热门评论」、按 like 递减）。
//
// 覆盖：
// - **默认关闭时逐字节不变**：请求参数仍是 mode=3，区头没有排序词条，横滑
//   一次请求都不发（专栏/动态/独立评论页三个使用点都是这个默认值）；
// - 开启后：区头出现 `热门 | 最新`，当前档主色 + 加粗；
// - 左滑 → mode=2 + 重载（next 回到 0）+ 浮层提示「已切到「最新」」+ 回顶部；
// - 右滑 → 回 mode=3；
// - 点区头词条 ≡ 横滑（可发现性 + 读屏可用）；
// - **纵向滚动不受影响**：竖直拖动照样滚、不切排序；
// - 斜向拖动（横 80 / 纵 200）不切排序（"横向为主"门槛）；
// - 位移不足 56px 不触发；
// - 浮层提示 1.4s 后自动消失；
// - `sortMode` 初值可指定（2 = 一进来就是最新）。
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

const String _kSpiPath = '/x/frontend/finger/spi';
const String _kViewPath = '/x/web-interface/view';
const String _kMainPath = '/x/v2/reply/main';

/// 测试视频：aid 由 [WhitelistVideo] 之外显式给成 [kAid]。
const int kAid = 2002;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1SORT00001',
      cid: 2002,
      title: '排序测试视频',
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

Map<String, dynamic> _viewBody() => {
      'code': 0,
      'data': {'aid': kAid, 'bvid': 'BV1SORT00001', 'cid': 2002},
    };

/// 每条评论正文写长一点：让列表明显高于视口，纵向滚动的用例才有内容可滚。
String _longText(String tag, int i) =>
    '$tag 第 $i 条：为了让列表能滚起来，这里写一段比较长的评论正文占位文字，'
    '再补一点长度，确保每一块都够高。';

Map<String, dynamic> _replyJson({
  required int rpid,
  required String message,
}) =>
    {
      'rpid': rpid,
      'oid': kAid,
      'root': 0,
      'parent': 0,
      'count': 0,
      'like': 3,
      'ctime': 1700000000,
      'member': {
        'mid': '946974',
        'uname': '评论君',
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message},
    };

/// 首屏（next=0）与翻页（next!=0）返回**不同 rpid 段**，好断言"确实重置了
/// 第一页"；cursor.next 给成 100/200 让翻页链路可走。
Map<String, dynamic> _mainBody(RequestOptions o) {
  final next = o.queryParameters['next'] as String? ?? '0';
  final mode = o.queryParameters['mode'] as String? ?? '3';
  final int base = next == '0' ? 5000 : 6000;
  final tag = next == '0' ? '模式$mode' : '第二页';
  return {
    'code': 0,
    'data': {
      'replies': [
        for (var i = 0; i < 6; i++)
          _replyJson(rpid: base + i, message: _longText(tag, i)),
      ],
      'top_replies': <Map<String, dynamic>>[],
      'cursor': {'next': next == '0' ? 100 : 200, 'is_end': false, 'all_count': 30},
    },
  };
}

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

// ---------------------------------------------------------------------------
// 挂载 / 取值助手
// ---------------------------------------------------------------------------

/// 推进到首屏评论渲染出来（加载转圈会挂死 pumpAndSettle）。
Future<void> _pumpUntilListed(WidgetTester tester, {int steps = 40}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(AppBlock).evaluate().isNotEmpty) return;
  }
}

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

/// 评论列表当前滚动位置（px）。
double _pixels(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
            of: find.byType(CommentListView),
            matching: find.byType(Scrollable))
        .first)
    .position
    .pixels;

/// 从评论块左内边距（x=20，避开正文的选择手势）起手拖动。
///
/// 与 player_comment_scroll_hide_test 同一取舍：正文是 SelectableText，
/// 从正文上起手会被"选择/拖动"抢走。
Offset _startPoint(WidgetTester tester, {double y = 0.4}) {
  final r = tester.getRect(find.byType(CommentListView));
  return Offset(r.left + 20, r.top + r.height * y);
}

/// 一整套 handler（spi + view + 主评论）。
Map<String, Map<String, dynamic> Function(RequestOptions)> _handlers() => {
      _kSpiPath: (_) => _spiBody(),
      _kViewPath: (_) => _viewBody(),
      _kMainPath: _mainBody,
    };

void main() {
  setUp(() {
    // 动效关（断言静态形态），与 comment_list_generalized_test 同款
    MotionControl.enabled = false;
    _mockSecureStorage();
  });

  tearDown(MotionControl.reset);

  // -------------------------------------------------------------------------
  // 默认关闭：逐字节不变
  // -------------------------------------------------------------------------

  testWidgets('默认关闭：请求仍是 mode=3，区头没有排序词条', (tester) async {
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

    expect(adapter.forPath(_kMainPath).single.queryParameters, {
      'type': '1',
      'oid': '$kAid',
      'mode': '3',
      'next': '0',
    });
    expect(find.byKey(kCommentSortHotKey), findsNothing);
    expect(find.byKey(kCommentSortNewestKey), findsNothing);
    expect(find.text(kCommentSortHotLabel), findsNothing);
  });

  testWidgets('默认关闭：横滑一次请求都不发（三个未开启使用点行为不变）',
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
        api: _api(adapter),
      ),
    );
    final before = adapter.forPath(_kMainPath).length;

    await tester.dragFrom(_startPoint(tester), const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 300));

    expect(adapter.forPath(_kMainPath).length, before,
        reason: '没开启就不包任何横滑能力（连 Listener 都没有）');
    expect(find.byKey(kCommentSortHintKey), findsNothing);
  });

  testWidgets('专栏侧形态（oid + type=12，不开启）：参数与区头都不受影响',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        oid: 987654,
        commentType: 12,
        identityKey: 'cv987654',
        showCountHeader: true,
        header: const SizedBox(height: 40, child: Text('正文')),
        api: _api(adapter),
      ),
    );

    expect(adapter.forPath(_kMainPath).single.queryParameters, {
      'type': '12',
      'oid': '987654',
      'mode': '3',
      'next': '0',
    });
    expect(find.byKey(kCommentSortHotKey), findsNothing);
  });

  // -------------------------------------------------------------------------
  // 开启后：区头词条
  // -------------------------------------------------------------------------

  testWidgets('开启后：区头出现「热门 | 最新」，热门为当前档（主色 + 加粗）',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        api: _api(adapter),
      ),
    );

    final hot = tester.widget<Text>(find.descendant(
        of: find.byKey(kCommentSortHotKey), matching: find.byType(Text)));
    final newest = tester.widget<Text>(find.descendant(
        of: find.byKey(kCommentSortNewestKey), matching: find.byType(Text)));
    final primary =
        Theme.of(tester.element(find.byType(CommentListView))).colorScheme.primary;

    expect(hot.data, kCommentSortHotLabel);
    expect(newest.data, kCommentSortNewestLabel);
    expect(hot.style?.fontWeight, FontWeight.w600, reason: '当前档加粗');
    expect(hot.style?.color, primary, reason: '当前档主色');
    expect(newest.style?.color, isNot(primary), reason: '非当前档灰');
  });

  testWidgets('开启后：sortMode=2 → 一进来就是「最新」档', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        sortMode: kCommentSortNewest,
        api: _api(adapter),
      ),
    );

    expect(adapter.forPath(_kMainPath).single.queryParameters['mode'], '2');
    final newest = tester.widget<Text>(find.descendant(
        of: find.byKey(kCommentSortNewestKey), matching: find.byType(Text)));
    expect(newest.style?.fontWeight, FontWeight.w600);
  });

  // -------------------------------------------------------------------------
  // 切换：横滑 / 点词条
  // -------------------------------------------------------------------------

  testWidgets('开启后：左滑 → mode=2 重载 + 浮层提示 + 回到第一页与顶部',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    // 视口矮一些，好让列表可滚并触发翻页
    tester.view.physicalSize = const Size(400, 300);
    addTearDown(tester.view.reset);

    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        api: _api(adapter),
      ),
    );

    // 先滚到列表底部触发翻页（next=100）→ 证明切换后确实"回到第一页"
    await tester.dragFrom(_startPoint(tester), const Offset(0, -2000));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_pixels(tester), greaterThan(0), reason: '先离开顶部');
    await _pumpUntilListed(tester);
    final beforeSwitch = adapter.forPath(_kMainPath);
    expect(beforeSwitch.map((r) => r.queryParameters['next']).toList(),
        contains('100'),
        reason: '翻页请求用的是 cursor.next');

    // 横滑（左滑 = 往「最新」那一档拨）
    await tester.dragFrom(_startPoint(tester), const Offset(-150, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntilListed(tester);

    final after = adapter.forPath(_kMainPath).last;
    expect(after.queryParameters['mode'], '2', reason: '左滑 → 最新');
    expect(after.queryParameters['next'], '0', reason: '重载第一页');
    expect(find.byKey(kCommentSortHintKey), findsOneWidget);
    expect(find.text('已切到「最新」'), findsOneWidget);
    expect(_pixels(tester), 0, reason: '切换后回到顶部');
  });

  testWidgets('开启后：右滑 → 回到 mode=3（热门）', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        sortMode: kCommentSortNewest,
        api: _api(adapter),
      ),
    );
    expect(adapter.forPath(_kMainPath).last.queryParameters['mode'], '2');

    await tester.dragFrom(_startPoint(tester), const Offset(150, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntilListed(tester);

    expect(adapter.forPath(_kMainPath).last.queryParameters['mode'], '3');
    expect(find.text('已切到「热门」'), findsOneWidget);
  });

  testWidgets('开启后：点区头「最新」词条 ≡ 左滑（同样的请求与提示）',
      (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        api: _api(adapter),
      ),
    );

    await tester.tap(find.byKey(kCommentSortNewestKey));
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpUntilListed(tester);

    expect(adapter.forPath(_kMainPath).last.queryParameters['mode'], '2');
    expect(find.byKey(kCommentSortHintKey), findsOneWidget);
  });

  testWidgets('开启后：点当前档（热门）不发请求', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        api: _api(adapter),
      ),
    );
    final before = adapter.forPath(_kMainPath).length;

    await tester.tap(find.byKey(kCommentSortHotKey));
    await tester.pump(const Duration(milliseconds: 300));

    expect(adapter.forPath(_kMainPath).length, before);
    expect(find.byKey(kCommentSortHintKey), findsNothing);
  });

  // -------------------------------------------------------------------------
  // 不误触：纵向滚动 / 斜向 / 位移不足
  // -------------------------------------------------------------------------

  testWidgets('开启后：纵向拖动照旧滚动列表，且不切排序、不换档',
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
        api: _api(adapter),
      ),
    );
    final beforePixels = _pixels(tester);

    await tester.dragFrom(_startPoint(tester, y: 0.7), const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 300));

    expect(_pixels(tester), greaterThan(beforePixels),
        reason: '纵向滚动完全不受影响（Listener 只是旁听，不进手势竞技场）');
    // 注意：纵向滚到底会触发**翻页追加**（这是既有行为，本来就该发生），
    // 所以这里断言的不是"没有请求"，而是"没有**换档重载**"：
    expect(
      adapter.forPath(_kMainPath).map((r) => r.queryParameters['mode']).toSet(),
      {'3'},
      reason: '全程 mode 没变（横滑才换档）',
    );
    expect(find.byKey(kCommentSortHintKey), findsNothing);
  });

  testWidgets('开启后：斜向拖动（横 80 / 纵 200）不切排序', (tester) async {
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
        api: _api(adapter),
      ),
    );

    await tester.dragFrom(_startPoint(tester, y: 0.7), const Offset(-80, -200));
    await tester.pump(const Duration(milliseconds: 300));

    // 同样不能断言"没有请求"（滚到底会触发既有的翻页追加），断言"没换档"
    expect(
      adapter.forPath(_kMainPath).map((r) => r.queryParameters['mode']).toSet(),
      {'3'},
      reason: '纵向分量更大 → 是"滚列表"，不是"横滑切排序"',
    );
    expect(find.byKey(kCommentSortHintKey), findsNothing);
  });

  testWidgets('开启后：横滑位移不足 56px 不触发', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        api: _api(adapter),
      ),
    );
    final before = adapter.forPath(_kMainPath).length;

    await tester.dragFrom(_startPoint(tester), const Offset(-30, 0));
    await tester.pump(const Duration(milliseconds: 300));

    expect(adapter.forPath(_kMainPath).length, before);
    expect(find.byKey(kCommentSortHintKey), findsNothing);
  });

  testWidgets('开启后：浮层提示 1.4s 后自动消失', (tester) async {
    final adapter = _RecordingAdapter(_handlers());
    await _pump(
      tester,
      CommentListView(
        video: _video(),
        initialAid: kAid,
        showCountHeader: true,
        enableSortSwipe: true,
        api: _api(adapter),
      ),
    );

    await tester.tap(find.byKey(kCommentSortNewestKey));
    await tester.pump(const Duration(milliseconds: 200));
    await _pumpUntilListed(tester);
    expect(find.byKey(kCommentSortHintKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byKey(kCommentSortHintKey), findsNothing,
        reason: '提示是自解释的浮层，不需要用户点掉');
    // 排序本身不回退
    expect(adapter.forPath(_kMainPath).last.queryParameters['mode'], '2');
  });
}
