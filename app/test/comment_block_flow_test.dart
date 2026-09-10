// 评论块化 + 交错入场 + 底部加载剪影（P0「块化与动效系统」批次 B）widget 测试。
//
// 覆盖：
// - 块化：根评论渲染为 `AppBlock(comment)`（纸底 + hairline 描边），
//   楼中楼预览 / 真回复渲染为 `AppBlock(reply)`（冷底 + 左竖条）；
// - 尾部 Divider 已删除：评论区子树内 `find.byType(Divider)` 为空；
// - 交错入场：`MotionControl.enabled = false` → 树里没有任何
//   `FadeTransition` 包裹层；`true` → 演的时候有、演完即卸载；
// - 底部翻页加载：`_loadingMore` 为真时是 `SmokeSilhouette` + 加载文案，
//   不再是 `CircularProgressIndicator`。
//
// 测试环境说明（骨架与 comment_video_link_test 同款）：按 URI 路径返回
// 合法 JSON 的 fake HttpClient（不触网），secure storage / shared_preferences
// 通道 mock 掉。本文件不涉及播放器 → 不 mock 播放通道。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/loading_copy.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';
import 'package:bili_whitelist_app/widgets/smoke_silhouette.dart';
import 'package:bili_whitelist_app/widgets/staggered_entrance.dart';

/// 测试视频（aid 由 view 接口给成 1001）。
const String kBvid = 'BV1BLOCK1111';

WhitelistVideo _video() => const WhitelistVideo(
      bvid: kBvid,
      cid: 1001,
      title: '视频',
      cover: '',
      duration: 120,
      upName: 'up',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// 可调的 fake 行为开关（每个用例在开头重置，见 setUp）
// ---------------------------------------------------------------------------

/// 首屏评论页是否 is_end：true → 底部是「没有更多了」（不触发翻页）。
bool _endOnFirstPage = true;

/// HTTP 响应延迟（fake-async 下不推进时间就不完成）→ 用来稳定观察
/// 「翻页加载中」这一帧。
Duration _httpDelay = Duration.zero;

/// `/x/v2/reply/main` 被调用的次数（断言翻页确实发生了）。
int _replyMainCalls = 0;

/// true → `/x/v2/reply/main` 返回空列表（测空态）。
bool _noComments = false;

/// true → `/x/v2/reply/main` 返回 -412（测错误态 + 重试）。
bool _commentsFail = false;

// ---------------------------------------------------------------------------
// mock HTTP：按 URI 路径返回合法 JSON
// ---------------------------------------------------------------------------

typedef _Router = Map<String, dynamic> Function(Uri uri);

class _FakeHttpOverrides extends HttpOverrides {
  final _Router router;
  _FakeHttpOverrides(this.router);
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(router);
}

class _FakeHttpClient implements HttpClient {
  final _Router router;
  _FakeHttpClient(this.router);

  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    // 请求计数放在「发出请求」这一层（不是 router 里）：翻页响应被刻意延迟
    // 300ms，router 要等延迟结束才跑，计数放那里会晚一拍。
    if (url.path.endsWith('/x/v2/reply/main')) _replyMainCalls++;
    return _FakeHttpRequest(router, url);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      openUrl('GET', Uri.parse('http://$host:$port$path'));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  final _Router router;
  final Uri _uri;
  final List<int> _body = [];

  _FakeHttpRequest(this.router, this._uri);

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  int get contentLength => _body.length;

  @override
  set contentLength(int value) {}

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.addAll(chunk);
    }
  }

  @override
  void write(Object? obj) => _body.addAll(utf8.encode(obj.toString()));

  @override
  void writeAll(Iterable objects, [String separator = '']) {
    _body.addAll(utf8.encode(objects.join(separator)));
  }

  @override
  void writeCharCode(int charCode) => _body.add(charCode);

  @override
  void writeln([Object? obj = '']) {
    _body.addAll(utf8.encode(obj.toString()));
    _body.add(0x0A);
  }

  @override
  Future<HttpClientResponse> close() async {
    // 可选延迟：让「加载中」这一帧在 fake-async 下可被稳定观察到
    if (_httpDelay > Duration.zero) {
      await Future<void>.delayed(_httpDelay);
    }
    return _FakeHttpResponse(utf8.encode(jsonEncode(router(_uri))));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  final List<int> _body;
  _FakeHttpResponse(this._body);

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK';

  @override
  int get contentLength => _body.length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpHeaders get headers {
    final h = _FakeHttpHeaders();
    h.add('content-type', 'application/json; charset=utf-8');
    return h;
  }

  Stream<Uint8List>? get handle =>
      Stream<Uint8List>.fromIterable([Uint8List.fromList(_body)]);

  @override
  Stream<R> cast<R>() => handle!.cast<R>();

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return handle!.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      add(name, value);

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  List<String>? lookup(String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) => _map[name.toLowerCase()]?.first;

  String? get protocolVersion => 'HTTP/1.1';

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ---- 各接口的合法响应体 ----------------------------------------------------

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3x', 'b_4': 'buvid4x'},
    };

Map<String, dynamic> _navBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/11a8a4f1a25f41b4e05e02d6f2b4b3a3.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/0e146c531c4e43e20a7cfb1a3d4f5a5b.png',
        },
      },
    };

Map<String, dynamic> _viewBody() => {
      'code': 0,
      'data': {
        'bvid': kBvid,
        'aid': 1001,
        'cid': 1001,
        'title': '视频',
        'pic': '',
        'duration': 120,
        'owner': {'name': 'up'},
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '', 'duration': 120},
        ],
      },
    };

/// 一条评论（可带内嵌 `replies[]` 预览）。
Map<String, dynamic> _replyJson({
  required int rpid,
  required String uname,
  required String message,
  int count = 0,
  List<Map<String, dynamic>> previews = const [],
}) =>
    {
      'rpid': rpid,
      'oid': 1001,
      'root': 0,
      'parent': 0,
      'count': count,
      'like': 3,
      'ctime': 1700000000,
      'member': {
        'uname': uname,
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message},
      if (previews.isNotEmpty) 'replies': previews,
    };

/// 首屏：两条根评论（第一条带 1 条预览、第二条有 3 条回复）。
Map<String, dynamic> _firstPageBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        'replies': [
          _replyJson(
            rpid: 5001,
            uname: '评论甲',
            message: '第一条评论正文',
            count: 1,
            previews: [
              _replyJson(rpid: 5101, uname: '预览乙', message: '预览回复正文'),
            ],
          ),
          _replyJson(
            rpid: 5002,
            uname: '评论丙',
            message: '第二条评论正文',
            count: 3,
          ),
        ],
        'top_replies': [],
        'cursor': {
          'next': _endOnFirstPage ? 0 : 2,
          'is_end': _endOnFirstPage,
          'all_count': 4,
        },
      },
    };

/// 翻页（next=2）：两条追加评论。
Map<String, dynamic> _secondPageBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        'replies': [
          _replyJson(rpid: 5003, uname: '评论戊', message: '翻页追加的第一条'),
          _replyJson(rpid: 5004, uname: '评论己', message: '翻页追加的第二条'),
        ],
        'top_replies': [],
        'cursor': {'next': 0, 'is_end': true, 'all_count': 4},
      },
    };

Map<String, dynamic> _childrenBody({required int root}) => {
      'code': 0,
      'message': 'success',
      'data': {
        'replies': [
          _replyJson(rpid: 5201, uname: '子回复甲', message: '楼中楼回复一'),
          _replyJson(rpid: 5202, uname: '子回复乙', message: '楼中楼回复二'),
        ],
        'page': {'num': 1, 'size': 20, 'count': 2},
        // root 原样回显，便于断言请求确实带上了根评论 rpid
        'root': root,
      },
    };

Map<String, dynamic> _router(Uri uri) {
  final path = uri.path;
  if (path.endsWith('/x/frontend/finger/spi')) return _spiBody();
  if (path.endsWith('/x/web-interface/nav')) return _navBody();
  if (path.endsWith('/x/web-interface/view')) return _viewBody();
  if (path.endsWith('/x/v2/reply/main')) {
    if (_commentsFail) {
      return {'code': -412, 'message': '请求被风控拦截'};
    }
    if (_noComments) {
      return {
        'code': 0,
        'message': 'success',
        'data': {
          'replies': <Map<String, dynamic>>[],
          'top_replies': <Map<String, dynamic>>[],
          'cursor': {'next': 0, 'is_end': true, 'all_count': 0},
        },
      };
    }
    final next = int.tryParse(uri.queryParameters['next'] ?? '0') ?? 0;
    return next > 0 ? _secondPageBody() : _firstPageBody();
  }
  if (path.endsWith('/x/v2/reply/reply')) {
    final root = int.tryParse(uri.queryParameters['root'] ?? '0') ?? 0;
    return _childrenBody(root: root);
  }
  return {'code': 0, 'data': {}};
}

/// 安装测试环境（HTTP 路由 + 存储通道 mock）。
void _installEnv() {
  SharedPreferences.setMockInitialValues({});
  final oldOverrides = HttpOverrides.current;
  HttpOverrides.global = _FakeHttpOverrides(_router);
  addTearDown(() => HttpOverrides.global = oldOverrides);

  final messenger = TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      ));
}

/// 挂载评论列表并推进到首屏渲染完成。
///
/// ⚠️ 不能用 `pumpAndSettle`：加载态里的转圈是无限动画，会直接把 settle 挂死。
Future<void> _pumpComments(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: CommentListView(video: _video())),
  ));
  await _pumpUntilListed(tester);
}

/// 固定步长推进若干帧（≤ [steps] × [step]），直到评论列表渲染出来。
Future<void> _pumpUntilListed(
  WidgetTester tester, {
  int steps = 30,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(step);
    if (find.byType(AppBlock).evaluate().isNotEmpty) return;
  }
}

/// 指定 variant 的块。
Iterable<AppBlock> _blocks(WidgetTester tester, AppBlockVariant v) => tester
    .widgetList<AppBlock>(find.byType(AppBlock))
    .where((b) => b.variant == v);

/// 评论区内是否有 Divider。
Finder _dividerInComments() => find.descendant(
      of: find.byType(CommentListView),
      matching: find.byType(Divider),
    );

void main() {
  setUp(() {
    // 装饰性动画默认关：断言静态形态、避免无限 ticker 干扰（用例内可单独打开）
    MotionControl.enabled = false;
    _endOnFirstPage = true;
    _httpDelay = Duration.zero;
    _replyMainCalls = 0;
    _noComments = false;
    _commentsFail = false;
  });

  tearDown(MotionControl.reset);

  testWidgets('块化：根评论是 comment 块、预览是 reply 块，尾部不再有 Divider',
      (tester) async {
    _installEnv();
    await _pumpComments(tester);

    expect(_blocks(tester, AppBlockVariant.comment).length, 2,
        reason: '两条根评论各自成块');
    expect(_blocks(tester, AppBlockVariant.reply).isNotEmpty, isTrue,
        reason: '楼中楼预览走 reply 规格');
    expect(_dividerInComments(), findsNothing, reason: '条目尾部 Divider 已删除');
    // 正文与按钮文案照旧（块化不动内容）
    expect(find.text('第一条评论正文'), findsOneWidget);
    expect(find.text('3 条回复'), findsOneWidget);
  });

  testWidgets('块化：展开楼中楼后，真回复同样落在 reply 块里', (tester) async {
    _installEnv();
    await _pumpComments(tester);

    // 展开前：只有「评论甲」的 1 条预览是 reply 块
    expect(_blocks(tester, AppBlockVariant.reply).length, 1);
    await tester.tap(find.text('3 条回复'));
    // 拉楼中楼网络 + 渲染（固定步进，不用 pumpAndSettle）
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 展开后：预览块仍是 1 个，另加「评论丙」下的 2 条真回复 = 3 个 reply 块
    expect(_blocks(tester, AppBlockVariant.reply).length, 3,
        reason: '两条真回复应各成 reply 块');
    expect(find.text('楼中楼回复一'), findsOneWidget);
    expect(find.text('楼中楼回复二'), findsOneWidget);
    expect(_dividerInComments(), findsNothing);
  });

  testWidgets('交错入场（关动效）：条目无 FadeTransition 包裹层', (tester) async {
    _installEnv();
    MotionControl.enabled = false;
    await _pumpComments(tester);

    // 条目仍带 StaggeredEntrance 节点（列表结构不变），但不产生飞行包裹层
    expect(find.byType(StaggeredEntrance), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(StaggeredEntrance),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
  });

  testWidgets('交错入场（开动效）：演的时候有包裹层，演完即卸载', (tester) async {
    _installEnv();
    MotionControl.enabled = true;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CommentListView(video: _video())),
    ));
    // 逐帧推进，捕捉「条目首次上屏」那一帧的入场包裹层
    var sawFlight = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find
          .descendant(
            of: find.byType(StaggeredEntrance),
            matching: find.byType(FadeTransition),
          )
          .evaluate()
          .isNotEmpty) {
        sawFlight = true;
        break;
      }
    }
    expect(sawFlight, isTrue, reason: '开动效时入场包裹层应真的出现');

    // 演完 → 包裹层卸载（树里不留残余 FadeTransition）
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(StaggeredEntrance),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
      reason: '入场结束后应卸载飞行包裹层',
    );
    // 内容照旧在
    expect(find.text('第一条评论正文'), findsOneWidget);
  });

  testWidgets('翻页加载：底部是剪影 + 加载文案，不是转圈', (tester) async {
    _installEnv();
    _endOnFirstPage = false; // 允许翻页
    // 视口压矮（600×200）：两屏评论内容已高于视口 → 列表可滚动，才拖得动
    // （可拖拽的前提是 maxScrollExtent > 0，见 ScrollPhysics.shouldAcceptUserOffset）。
    tester.view.physicalSize = const Size(600, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpComments(tester);
    // 此时底部应为占位空间（未在加载）
    expect(find.byType(SmokeSilhouette), findsNothing);

    // 先把翻页响应的返回按住（延迟 300ms），再滚动触发翻页。
    // ⚠️ 拖拽起点刻意选 x=20（块的左内边距里，没有任何手势识别器）：
    // 评论正文是 SelectableText/富文本，指针落在正文上时选择手势会抢走
    // 拖拽，列表根本滚不动。
    _httpDelay = const Duration(milliseconds: 300);
    final callsBefore = _replyMainCalls;
    await tester.dragFrom(const Offset(20, 150), const Offset(0, -150));
    await tester.pump();

    // 剪影只在 `_loadingMore == true` 时挂出来，而 `_loadingMore` 只有
    // `_loadMain(reset:false)` 会置真 → 剪影出现即证明「滚到底触发了下一页」。
    expect(find.byType(SmokeSilhouette), findsOneWidget, reason: '加载态应是剪影');
    expect(
      find.descendant(
        of: find.byType(CommentListView),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
      reason: '脚部不再是转圈',
    );
    expect(
      find.text(loadingCopyFor(
        pool: kLoadingPoolFooter,
        seed: '$kBvid#footer',
      )),
      findsOneWidget,
      reason: '加载文案取自 footer 池（确定性 seed）',
    );
    // 关动效时剪影走静态帧：零 ticker
    expect(SmokeSilhouette.activeTickers, 0);

    // 放行延迟响应 → 加载结束，脚部不再挂剪影
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(SmokeSilhouette), findsNothing);
    expect(_replyMainCalls, greaterThan(callsBefore), reason: '第二页确实请求了');
  });

  testWidgets('空态：暂无评论统一走 AppStateView（细线插画 seed = comment）',
      (tester) async {
    _noComments = true;
    _installEnv();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CommentListView(video: _video())),
    ));
    // 不能用 pumpAndSettle（加载态转圈是无限动画）→ 固定步长等落地
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppStateView).evaluate().isNotEmpty) break;
    }

    expect(find.text('暂无评论'), findsOneWidget);
    final state = tester.widget<AppStateView>(find.byType(AppStateView));
    expect(state.kind, AppStateKind.empty);
    expect(state.copyId, 'empty.comment');
    expect(state.subtitleCopyId, 'empty.comment.sub');
    // 评论区在矮容器里（_fitState 负责滚动），这里不再叠自己的 ListView
    expect(state.scrollable, isFalse);
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'comment',
    );
    expect(find.byType(AppBlock), findsNothing);
  });

  testWidgets('错误态：AppErrorView（细线插画 + 重试），点重试重新拉取',
      (tester) async {
    _commentsFail = true;
    _installEnv();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CommentListView(video: _video())),
    ));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppErrorView).evaluate().isNotEmpty) break;
    }

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'comment',
    );
    final callsBefore = _replyMainCalls;

    // 放行下一次请求 → 点「重试」应真的重拉（并回到正常列表）
    _commentsFail = false;
    await tester.tap(find.text('重试'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(AppBlock).evaluate().isNotEmpty) break;
    }
    expect(_replyMainCalls, greaterThan(callsBefore), reason: '点重试必须重拉评论');
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('第一条评论正文'), findsOneWidget);
  });
}
