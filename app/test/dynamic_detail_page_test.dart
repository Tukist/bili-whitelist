// 动态详情页（DynamicDetailPage）widget 测试（注入 mock BiliApi，不访问真实网络）。
//
// 覆盖：
// - **有 `initial` 就首帧渲染**：详情接口还挂着也**不**显示整页等待态（正文/
//   作者/图片直接用列表带来的那条画出来）
// - 无 `initial` → [AppLoadingHero]（整页等待）→ 正文到货
// - 评论口径：**优先 `basic.{comment_type, comment_id_str}`**（实测相册型动态是
//   11 + rid；想当然的 17 + dyn id 会 -404 被当空页）；响应里没有 `basic` 才回退
//   `type=17` + `oid=int.parse(id)` + `initialTotal=<module_stat.comment>`
//   —— 两条口径都得钉死（传错 type 不报错，或直接 -404）
//   另外钉住「19 位动态 id 当 int 传给 comment_list 的 oid 过滤」不会把评论
//   整批丢掉（`_parseReplyList` 里 `oid != aid` 的条目会被丢弃）
// - 正文（header）与评论在同一个滚动体内：整页只有一个 ListView（「不 shrinkWrap」
//   的结构证明，与专栏阅读页同一骨架）
// - 点配图 → [ImageViewerPage]（图集与下标正确）
// - 点视频投稿 → fetch view 补 cid → push [PlayerPage]（路由名 player；cid 已补）
// - 转发原文：作者 + 正文 + **原文自己的图片/视频**都能上屏，且原文的视频
//   进的是原文的 bvid
// - 互动数据行：点赞/评论/转发只读展示；三个 0 → 整行不渲染
// - 详情接口失败：**有 initial 时静默**（正文照旧、不弹错误页）；没有内容时才
//   落 [AppErrorView]，重试会重新请求
// - 下拉刷新重新请求详情；刷新失败不清空已有正文
//
// 说明：这里的 `_api` 是注入的 mock；push 出来的 [PlayerPage] 会自建真实
// BiliApi（测试环境一律 400 → 播放页自己落失败态），本文件只钉住「页面被推
// 出来了 + 参数对」——与 upowner_dynamics_test 的取舍一致。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/dynamic_item.dart';
import 'package:bili_whitelist_app/pages/dynamic_detail_page.dart';
import 'package:bili_whitelist_app/pages/image_viewer_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';
import 'package:bili_whitelist_app/widgets/dynamic_card.dart';

const String _kDetailPath = '/x/polymer/web-dynamic/v1/detail';
const String _kMainPath = '/x/v2/reply/main';
const String _kViewPath = '/x/web-interface/view';

/// 动态 id：**19 位雪花数**（与线上同量级，仍在 Dart int64 内）。
const String kDynId = '967717348014293017';

/// 相册型动态的评论归属（2026-09 匿名实测的真实取值：`basic` 里那一对）。
/// 用它取评论 `type=11&oid=326122895` → code=0；`type=17&oid=<dyn id>` → -404。
const int kAlbumCommentType = 11;
const String kAlbumRid = '326122895';

/// 动态发布时间：相对「现在」3 小时 → 作者行显示「3 小时前」。
final int _pubTs =
    DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/
        1000;

// ---------------------------------------------------------------------------
// mock HTTP
// ---------------------------------------------------------------------------

/// 可挂起的适配器：`gate` 未完成前不返回响应（用来钉住「第一帧」）。
class _GatedAdapter implements HttpClientAdapter {
  _GatedAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];
  Completer<void>? gate;

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final g = gate;
    if (g != null) await g.future;
    final handler = handlers[options.path];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(handler()),
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
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

/// 动态条目 JSON（feed 与 detail 同构，两边共用它）。
///
/// [basic] 不给时**不写** `basic` 字段（→ 评论归属回退默认口径 17 + dyn id）。
Map<String, dynamic> _dynJson({
  String id = kDynId,
  String type = DynamicType.draw,
  String author = '动态君',
  String text = '',
  List<String> images = const [],
  String? videoBvid,
  String videoTitle = '',
  Map<String, dynamic>? orig,
  int like = 0,
  int comment = 0,
  int forward = 0,
  Map<String, dynamic>? basic,
}) =>
    {
      'id_str': id,
      'type': type,
      if (basic != null) 'basic': basic,
      'modules': {
        'module_author': {'name': author, 'face': '', 'pub_ts': _pubTs},
        'module_dynamic': {
          if (text.isNotEmpty) 'desc': {'text': text},
          if (images.isNotEmpty || videoBvid != null)
            'major': {
              if (images.isNotEmpty)
                'draw': {
                  'items': [
                    for (final u in images) {'src': u},
                  ],
                },
              if (videoBvid != null)
                'archive': {
                  'bvid': videoBvid,
                  'title': videoTitle,
                  'cover': '',
                },
            },
        },
        'module_stat': {
          'like': {'count': like},
          'comment': {'count': comment},
          'forward': {'count': forward},
        },
      },
      if (orig != null) 'orig': orig,
    };

/// 转发的原文（同构，可带自己的图/视频）。
Map<String, dynamic> _origJson({
  String author = '原作者',
  String text = '被转发的原文',
  List<String> images = const [],
  String? videoBvid,
  String videoTitle = '',
}) =>
    {
      'id_str': '8001',
      'type': DynamicType.word,
      'modules': {
        'module_author': {'name': author, 'face': '', 'pub_ts': _pubTs},
        'module_dynamic': {
          if (text.isNotEmpty) 'desc': {'text': text},
          if (images.isNotEmpty || videoBvid != null)
            'major': {
              if (images.isNotEmpty)
                'draw': {
                  'items': [
                    for (final u in images) {'src': u},
                  ],
                },
              if (videoBvid != null)
                'archive': {
                  'bvid': videoBvid,
                  'title': videoTitle,
                  'cover': '',
                },
            },
        },
      },
    };

Map<String, dynamic> _detailBody({
  Map<String, dynamic>? item,
  int code = 0,
  String? message,
}) =>
    {
      'code': code,
      if (message != null) 'message': message,
      if (code == 0) 'data': {'item': item ?? _dynJson()},
    };

/// 一条根评论：`oid` 用**数字**形态（与线上一致）——19 位数字串当 num 传，
/// 正是 `_parseReplyList` 的 `oid != aid` 过滤要过的关。
Map<String, dynamic> _replyJson({
  int rpid = 7001,
  String message = '第一条评论',
  int oid = 967717348014293017,
}) =>
    {
      'rpid': rpid,
      'oid': oid,
      'root': 0,
      'parent': 0,
      'count': 0,
      'like': 7,
      'ctime': _pubTs,
      'member': {
        'mid': '946974',
        'uname': '评论君',
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message},
    };

Map<String, dynamic> _replyBody({
  List<Map<String, dynamic>>? replies,
  int allCount = 34,
}) =>
    {
      'code': 0,
      'data': {
        'replies': replies ?? [_replyJson()],
        'top_replies': <Map<String, dynamic>>[],
        'cursor': {'next': 0, 'is_end': true, 'all_count': allCount},
      },
    };

Map<String, dynamic> _viewBody({int cid = 22334455, String bvid = 'BV1dyn4111'}) => {
      'code': 0,
      'data': {
        'bvid': bvid,
        'aid': 111,
        'cid': cid,
        'title': '动态里的视频标题',
        'pic': '',
        'duration': 120,
        'owner': {'mid': 1, 'name': '动态君', 'face': ''},
        'pages': [
          {'cid': cid, 'page': 1, 'part': 'P1', 'duration': 120},
        ],
      },
    };

BiliApi _api(_GatedAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

/// 基础 handler（详情 / 评论 / view 都不含在内，各用例按需加）。
Map<String, Map<String, dynamic> Function()> _base() => {
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kDetailPath: _detailBody,
      _kMainPath: _replyBody,
    };

void _mockSecureStorage() {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    return null;
  });
}

/// mock 原生播放器通道（push 出来的 [PlayerPage] 会调 create 拿 textureId）。
void _mockPlayerChannel() {
  var texId = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_dash_player'),
          (call) async {
    if (call.method == 'create') return ++texId;
    return null;
  });
}

/// 测试环境里图床请求一律 400 → 图片加载失败是预期内的（渲染侧有 errorBuilder
/// 兜底成占位）；把已上报的图片异常取走，避免它们污染用例结果。
void _drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

Future<void> _pumpPage(
  WidgetTester tester,
  BiliApi api, {
  DynamicItem? initial,
  String id = kDynId,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: DynamicDetailPage(id: id, initial: initial, api: api),
  ));
  // 评论列表的入场动效已关（MotionControl），但状态切换仍要几帧
  await tester.pumpAndSettle();
  _drainImageErrors(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    MotionControl.enabled = false; // 断言静态形态（也是 pumpAndSettle 的前提）
    SharedPreferences.setMockInitialValues({});
    _mockSecureStorage();
    _mockPlayerChannel();
  });

  tearDown(MotionControl.reset);

  testWidgets('有 initial：首帧就渲染正文/作者/图片（不显示整页等待态）',
      (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
    });
    adapter.gate = Completer<void>(); // 详情与评论请求都钉住不返回
    final initial = DynamicItem.fromJson(
      _dynJson(text: '列表带来的正文', images: ['//i0.hdslb.com/a.jpg']),
    );

    await tester.pumpWidget(MaterialApp(
      home: DynamicDetailPage(id: kDynId, initial: initial, api: _api(adapter)),
    ));
    await tester.pump(); // 只推进一帧

    expect(find.byType(AppLoadingHero), findsNothing,
        reason: '有 initial 时首帧不能是转圈');
    expect(find.text('列表带来的正文'), findsOneWidget);
    expect(find.text('动态君'), findsOneWidget, reason: '作者行');
    expect(find.text('3 小时前'), findsOneWidget, reason: '相对时间');
    expect(find.byType(DynamicImages), findsOneWidget, reason: '配图块');

    adapter.gate!.complete();
    await tester.pumpAndSettle();
    _drainImageErrors(tester);
  });

  testWidgets('无 initial：先整页 AppLoadingHero，详情到货后渲染正文 + 互动数据',
      (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () => _detailBody(
            item: _dynJson(text: '详情正文', like: 65, comment: 34, forward: 2),
          ),
    });
    adapter.gate = Completer<void>();

    await tester.pumpWidget(MaterialApp(
      home: DynamicDetailPage(id: kDynId, api: _api(adapter)),
    ));
    await tester.pump();

    expect(find.byType(AppLoadingHero), findsOneWidget);

    adapter.gate!.complete();
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    expect(find.byType(AppLoadingHero), findsNothing);
    expect(find.text('详情正文'), findsOneWidget);
    // 互动数据行（只读）
    expect(find.text('点赞 65'), findsOneWidget);
    expect(find.text('转发 2'), findsOneWidget);
    // 「评论 34」出现两次：互动数据行 + 评论区的「评论 N」区头
    expect(find.text('评论 34'), findsNWidgets(2));
  });

  testWidgets('评论口径（响应无 basic，回退默认）：type=17 + oid=int.parse(id) + '
      'initialTotal=评论数；正文与评论同一个滚动体', (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () => _detailBody(
            item: _dynJson(text: '详情正文', like: 65, comment: 34, forward: 2),
          ),
    });
    await _pumpPage(tester, _api(adapter));

    // ① widget 参数（最容易错的一处）
    final list = tester.widget<CommentListView>(find.byType(CommentListView));
    expect(list.commentType, 17, reason: '动态评论是 type=17（视频 1 / 专栏 12）');
    expect(list.oid, int.parse(kDynId));
    expect(list.oid, 967717348014293017);
    expect(list.initialTotal, 34, reason: '区头初值取 module_stat.comment');
    expect(list.identityKey, 'dyn$kDynId');
    expect(list.footerSeed, 'dyn$kDynId#footer');
    expect(list.showCountHeader, isTrue);

    // ② 真发出去的请求口径
    final req = adapter.forPath(_kMainPath).single;
    expect(req.queryParameters['type'], '17');
    expect(req.queryParameters['oid'], kDynId);
    expect(req.queryParameters['mode'], '3');

    // ③ 19 位数字 oid 没被 comment_list 的 `oid != aid` 过滤丢掉
    expect(find.text('第一条评论'), findsOneWidget,
        reason: '19 位雪花 id 在 int64 内，评论不该被静默丢弃');

    // ④ 正文与评论同一个滚动体（不 shrinkWrap）
    expect(find.byType(ListView), findsOneWidget,
        reason: '不是「外层列表 + 内层列表」');
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('详情正文')),
      findsOneWidget,
      reason: '正文是评论列表的第 0 项（header）',
    );
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('第一条评论')),
      findsOneWidget,
      reason: '评论是同一个 ListView 的后代',
    );
  });

  testWidgets('评论口径（服务端给了 basic）：用 basic.comment_type + '
      'comment_id_str，而不是想当然的 17 + dyn id', (tester) async {
    // 2026-09 匿名实测的真实响应：相册型动态 basic 是 11 + rid；
    // `type=17&oid=<dyn id>` 会 -404（评论整块变成空/错误），所以有 basic 就必须用它
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () => _detailBody(
            item: _dynJson(
              text: '相册型动态',
              like: 73,
              comment: 43,
              basic: {
                'comment_type': kAlbumCommentType,
                'comment_id_str': kAlbumRid,
                'rid_str': kAlbumRid,
              },
            ),
          ),
      // 评论挂在 rid 上：oid 也得是 rid（否则会被 comment_list 的
      // `oid != aid` 过滤丢掉——真实响应里返回的 oid 就是 rid）
      _kMainPath: () => _replyBody(
            allCount: 43,
            replies: [_replyJson(oid: int.parse(kAlbumRid), message: '相册评论')],
          ),
    });
    await _pumpPage(tester, _api(adapter));

    final list = tester.widget<CommentListView>(find.byType(CommentListView));
    expect(list.commentType, kAlbumCommentType, reason: '用 basic.comment_type');
    expect(list.oid, int.parse(kAlbumRid), reason: '用 basic.comment_id_str（rid）');
    expect(list.initialTotal, 43);

    final req = adapter.forPath(_kMainPath).single;
    expect(req.queryParameters['type'], '$kAlbumCommentType');
    expect(req.queryParameters['oid'], kAlbumRid);
    expect(find.text('相册评论'), findsOneWidget);
  });

  testWidgets('点配图 → ImageViewerPage（图集 = 本条动态全部图片，下标正确）',
      (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () => _detailBody(
            item: _dynJson(
              text: '两张图',
              images: ['//i0.hdslb.com/1.jpg', '//i0.hdslb.com/2.jpg'],
            ),
          ),
    });
    await _pumpPage(tester, _api(adapter));

    final thumbs = find.descendant(
      of: find.byType(DynamicImages),
      matching: find.byType(GestureDetector),
    );
    expect(thumbs, findsNWidgets(2));
    await tester.tap(thumbs.last, warnIfMissed: false);
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.urls, [
      'https://i0.hdslb.com/1.jpg',
      'https://i0.hdslb.com/2.jpg',
    ]);
    expect(viewer.initialIndex, 1);
  });

  testWidgets('点视频投稿 → fetch view 补 cid 后 push PlayerPage（路由名 player）',
      (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kViewPath: () => _viewBody(cid: 22334455),
      _kDetailPath: () => _detailBody(
            item: _dynJson(
              type: DynamicType.av,
              text: '投了个视频',
              videoBvid: 'BV1dyn4111',
              videoTitle: '动态里的视频标题',
            ),
          ),
    });
    await _pumpPage(tester, _api(adapter));

    expect(find.text('动态里的视频标题'), findsOneWidget);
    expect(find.text('视频投稿 · 3 小时前'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(DynamicVideo),
      matching: find.byType(InkWell),
    ));
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    final viewReq = adapter.forPath(_kViewPath).single;
    expect(viewReq.queryParameters['bvid'], 'BV1dyn4111');

    expect(find.byType(PlayerPage), findsOneWidget);
    final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(page.video.bvid, 'BV1dyn4111');
    expect(page.video.cid, 22334455, reason: 'cid 由 view 接口补全（不是 0）');
    expect(
      ModalRoute.of(tester.element(find.byType(PlayerPage)))?.settings.name,
      kPlayerRouteName,
    );
  });

  testWidgets('转发原文：作者 + 正文 + 原文自己的图片/视频都能渲染',
      (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kViewPath: () => _viewBody(cid: 999, bvid: 'BV1orig1111'),
      _kDetailPath: () => _detailBody(
            item: _dynJson(
              type: DynamicType.forward,
              text: '转发附言',
              orig: _origJson(
                author: '原作者',
                text: '被转发的原文',
                images: ['//i0.hdslb.com/orig1.jpg'],
                videoBvid: 'BV1orig1111',
                videoTitle: '原文里的视频',
              ),
            ),
          ),
    });
    await _pumpPage(tester, _api(adapter));

    expect(find.text('转发附言'), findsOneWidget);
    expect(find.text('@原作者'), findsOneWidget);
    expect(find.text('被转发的原文'), findsOneWidget);
    expect(find.text('原文里的视频'), findsOneWidget);
    // 原文的图另成一块（本条动态自己没有图）
    final thumbs = find.descendant(
      of: find.byType(DynamicImages),
      matching: find.byType(GestureDetector),
    );
    expect(thumbs, findsOneWidget);

    await tester.tap(thumbs, warnIfMissed: false);
    await tester.pumpAndSettle();
    _drainImageErrors(tester);
    expect(
      tester.widget<ImageViewerPage>(find.byType(ImageViewerPage)).urls,
      ['https://i0.hdslb.com/orig1.jpg'],
    );
    // 关掉查看页，继续点原文的视频
    Navigator.of(tester.element(find.byType(ImageViewerPage))).pop();
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    await tester.tap(find.descendant(
      of: find.byType(DynamicVideo),
      matching: find.byType(InkWell),
    ));
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    // 原文的视频进的是**原文的** bvid
    expect(adapter.forPath(_kViewPath).single.queryParameters['bvid'],
        'BV1orig1111');
    expect(
      tester.widget<PlayerPage>(find.byType(PlayerPage)).video.bvid,
      'BV1orig1111',
    );
  });

  testWidgets('互动数据全 0（接口没给 module_stat）→ 整行不渲染', (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () => _detailBody(item: _dynJson(text: '没有互动数据')),
    });
    await _pumpPage(tester, _api(adapter));

    expect(find.text('没有互动数据'), findsOneWidget);
    expect(find.textContaining('点赞 0'), findsNothing);
    expect(find.text('评论 0'), findsNothing);
    expect(find.textContaining('转发 0'), findsNothing);
  });

  testWidgets('详情接口失败但已有 initial → 正文照旧、不弹错误页（不打断阅读）',
      (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      // 一直 -412：API 内换 key 重试一次后仍失败 → null
      _kDetailPath: () => _detailBody(code: -412, message: '风控'),
    });
    final initial = DynamicItem.fromJson(
      _dynJson(text: '列表带来的正文', images: ['//i0.hdslb.com/a.jpg']),
    );
    await _pumpPage(tester, _api(adapter), initial: initial);

    expect(find.text('列表带来的正文'), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing, reason: '不该整页错误态');
    expect(find.byType(DynamicImages), findsOneWidget);
    // 评论照常加载（详情失败不影响评论区）
    expect(find.text('第一条评论'), findsOneWidget);
    expect(adapter.forPath(_kDetailPath).length, greaterThanOrEqualTo(2),
        reason: '-412 换 key 重试过一次');
  });

  testWidgets('无 initial 且详情失败 → AppErrorView + 重试再请求', (tester) async {
    var calls = 0;
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () {
        calls++;
        return calls <= 2
            ? _detailBody(code: -412, message: '风控')
            : _detailBody(item: _dynJson(text: '重试后的正文'));
      },
    });
    await _pumpPage(tester, _api(adapter));

    expect(find.byType(AppErrorView), findsOneWidget);
    final before = adapter.forPath(_kDetailPath).length;

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    expect(adapter.forPath(_kDetailPath).length, greaterThan(before));
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('重试后的正文'), findsOneWidget);
  });

  testWidgets('下拉刷新重新请求详情；失败不清空已有正文', (tester) async {
    var calls = 0;
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () {
        calls++;
        return calls == 1
            ? _detailBody(item: _dynJson(text: '已有正文', comment: 5))
            : _detailBody(code: -412, message: '风控');
      },
    });
    await _pumpPage(tester, _api(adapter));
    expect(find.text('已有正文'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    expect(adapter.forPath(_kDetailPath).length, greaterThan(1),
        reason: '下拉刷新重新请求详情');
    expect(find.text('已有正文'), findsOneWidget, reason: '刷新失败不清空正文');
    expect(find.byType(AppErrorView), findsNothing);
  });

  testWidgets('脏 id（非数字）→ 只渲染正文，不挂评论区（没有可用的评论归属）',
      (tester) async {
    final adapter = _GatedAdapter({
      ..._base(),
      _kDetailPath: () => _detailBody(item: _dynJson(id: 'abc', text: '脏 id 的正文')),
    });
    await _pumpPage(tester, _api(adapter), id: 'abc');

    expect(find.text('脏 id 的正文'), findsOneWidget);
    expect(find.byType(CommentListView), findsNothing);
    expect(adapter.forPath(_kMainPath), isEmpty, reason: '不该发评论请求');
  });
}
