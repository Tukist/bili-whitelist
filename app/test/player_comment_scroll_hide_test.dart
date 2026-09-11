// 竖屏播放页「评论区滚动 → 视频信息块收起/展开」widget 测试。
//
// 需求（用户原话）：在评论区滑动翻的时候，下滑（内容上移）把视频标题/简介块
// 收起，上滑（内容下移）重新出现。覆盖：
// - 方向判定：向下翻评论 → 信息块收起（评论区顶边顶到视频区下沿）；向上翻 →
//   展开（评论区顶边回到「视频区下沿 + 信息块固有高」）；
// - 阈值防抖：单个手势里滚动位移小于 `kInfoBarHideScrollThreshold` → 不切换；
// - 到顶强制展开：回到列表顶部（pixels == 0）即使方向判定没攒够阈值也展开；
// - 收起/展开是动画（`MotionControl.enabled = true` 时有中间帧几何，不是瞬移）；
// - 关动效（`MotionControl.enabled = false`，测试默认值）→ 一帧到位 + 无残留
//   动画（`pumpAndSettle` 收敛）；
// - 全屏不参与（下方内容区整个不在树里），退出全屏信息块复位为展开；
// - 横屏置顶模式不参与（几何与改动前一致）；
// - 三个测试锚点 Key（video-area / info-bar / comments）语义不变，且
//   「信息行顶部 == 视频区底部」在展开态与收起态都成立（块顶边钉在视频区下沿）。
//
// 测试环境说明（骨架与 player_info_block_test 同款）：
// - mock 播放器 MethodChannel/EventChannel（create → textureId，
//   setDataSource → onPrepared）→ 取流链路走通、无缓冲转圈；
// - mock HttpOverrides：按 URI 路径返回合法 JSON（view/reply/playurl 等），
//   不发真实请求；reply 返回 N 条长评论 → 评论区内容高于视口、可滚动；
// - 逻辑视口 400x800（dpr=1）→ 16:9 视频区 225；横屏用例 800x400；
// - 拖拽起点固定 x=20（评论块的左内边距里，没有 SelectableText 等手势竞争，
//   否则正文的选择手势会抢走拖拽、列表根本滚不动，见 comment_block_flow_test）；
// - 一律显式 pump，不用 pumpAndSettle（除专门验"关动效后能收敛"那一处）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

const String _kBvid = 'BV1SCHIDE0001';
const int _kAid = 1001;

/// 根评论条数：足够多 → 评论内容明显高于视口，列表可滚（判定前提）。
const int _kRootCount = 12;

const Key _kVideoArea = ValueKey('player-video-area');
const Key _kInfoBar = ValueKey('player-info-bar');
const Key _kComments = ValueKey('player-comments');

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '评论滚动收起信息块测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      desc: '这是一段视频简介，用来占住信息块的高度。',
    );

// ---------------------------------------------------------------------------
// mock HTTP：按路径返回合法 JSON
// ---------------------------------------------------------------------------

Map<String, dynamic> _replyJson(int i) => {
      'rpid': 1000 + i,
      'oid': _kAid,
      'root': 0,
      'parent': 0,
      'count': 0,
      'like': i,
      'ctime': 1700000000 + i,
      'member': {
        'uname': '用户$i',
        'avatar': '',
        'level_info': {'current_level': 3},
      },
      'content': {
        'message': '第 $i 条评论正文：为了让每块都够高、列表能滚起来，'
            '这里写一段比较长的文字占位。'
      },
      'replies': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _router(Uri uri) {
  final path = uri.path;
  if (path.endsWith('/x/frontend/finger/spi')) {
    return {
      'code': 0,
      'data': {'b_3': 'buvid3x', 'b_4': 'buvid4x'},
    };
  }
  if (path.endsWith('/x/web-interface/nav')) {
    return {
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/11a8a4f1a25f41b4e05e02d6f2b4b3a3.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/0e146c531c4e43e20a7cfb1a3d4f5a5b.png',
        },
      },
    };
  }
  if (path.endsWith('/x/web-interface/view')) {
    return {
      'code': 0,
      'data': {
        'bvid': _kBvid,
        'aid': _kAid,
        'cid': 1001,
        'title': '评论滚动收起信息块测试视频',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '这是一段视频简介，用来占住信息块的高度。',
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '', 'duration': 200},
        ],
      },
    };
  }
  if (path.endsWith('/x/v2/reply/main')) {
    return {
      'code': 0,
      'data': {
        'replies': List.generate(_kRootCount, _replyJson),
        'top_replies': <Map<String, dynamic>>[],
        'cursor': {'is_end': true},
      },
    };
  }
  if (path.contains('playurl')) {
    return {
      'code': 0,
      'data': {
        'quality': 80,
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/11a8a4f1a25f41b4e05e02d6f2b4b3a3.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/0e146c531c4e43e20a7cfb1a3d4f5a5b.png',
        },
        'dash': {
          'video': [
            {'baseUrl': 'https://x.bilivideo.com/v.m4s'}
          ],
          'audio': [
            {'baseUrl': 'https://x.bilivideo.com/a.m4s'}
          ],
        },
      },
    };
  }
  return {'code': 0, 'data': <String, dynamic>{}};
}

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
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
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.requestUri);

  final Uri requestUri;

  @override
  HttpHeaders get headers => _FakeHttpHeaders();
  @override
  int get contentLength => 0;
  @override
  set contentLength(int value) {}
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  void add(List<int> data) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  void write(Object? obj) {}
  @override
  void writeAll(Iterable objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? obj = '']) {}

  @override
  Future<HttpClientResponse> close() async =>
      _FakeHttpResponse(utf8.encode(jsonEncode(_router(requestUri))));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  _FakeHttpResponse(this._body);

  final List<int> _body;

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

  Stream<List<int>> get handle => Stream<List<int>>.fromIterable([_body]);

  @override
  Stream<R> cast<R>() => handle.cast<R>();
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      handle.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map[name.toLowerCase()] = [value.toString()];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      add(name, value);
  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];
  @override
  String? value(String name) => _map[name.toLowerCase()]?.first;
  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _map.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// 播放器通道 mock（create → id；setDataSource → onPrepared）
// ---------------------------------------------------------------------------

void _installPlayerMock(WidgetTester tester) {
  var texId = 0;
  MockStreamHandlerEventSink? eventSink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      if (call.method == 'create') return ++texId;
      if (call.method == 'setDataSource') {
        final map = call.arguments as Map;
        eventSink?.success({
          'event': 'onPrepared',
          'textureId': map['textureId'],
          'width': 1280,
          'height': 720,
          'durationMs': 200000,
        });
      }
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_dash_player'), null));
  tester.binding.defaultBinaryMessenger.setMockStreamHandler(
    const EventChannel('bili_dash_player/events'),
    MockStreamHandler.inline(
      // 注意用块体：箭头体会把赋值结果当返回值回给平台（解码报错）
      onListen: (arguments, events) {
        eventSink = events;
      },
    ),
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'), null));
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
}

// ---------------------------------------------------------------------------
// 几何/滚动取值助手
// ---------------------------------------------------------------------------

/// 挂载播放页并等到评论列表加载完（显式 pump，不用 pumpAndSettle）。
Future<void> _pumpPlayer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

double _infoBarHeight(WidgetTester tester) =>
    tester.getRect(find.byKey(_kInfoBar)).height;

double _commentsTop(WidgetTester tester) =>
    tester.getRect(find.byType(CommentListView)).top;

/// 评论列表当前滚动位置（px）。
double _commentPixels(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(of: find.byKey(_kComments), matching: find.byType(Scrollable))
        .first)
    .position
    .pixels;

/// 从评论块左内边距（x=20，无手势竞争）竖直拖动列表。
Future<void> _dragComments(WidgetTester tester, double dy) => tester.dragFrom(
    Offset(20, tester.getRect(find.byType(CommentListView)).center.dy),
    Offset(0, dy));

/// 走几帧让 200ms 的收起/展开动画演完（不用 pumpAndSettle：页面里还有别的
/// 装饰动画，收敛条件不由本用例负责）。AnimatedSize 的控制器是**在 layout
/// 里**起步的，所以触发那一帧只是第 0 帧，后面必须再走几帧才看得见终点。
Future<void> _settleAnim(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  tearDown(MotionControl.reset);

  testWidgets('竖屏：下翻评论收起信息块、上翻展开（含动画中间态）', (tester) async {
    MotionControl.enabled = true; // 本用例要看动画中间帧
    _installPlayerMock(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester);

    final video = tester.getRect(find.byKey(_kVideoArea));
    final infoH = _infoBarHeight(tester);
    final expandedTop = _commentsTop(tester);
    expect(find.byKey(_kComments), findsOneWidget);
    expect(expandedTop, closeTo(video.bottom + infoH, 0.5),
        reason: '初始：信息块占位，评论区在其下方');
    expect(expandedTop, greaterThan(video.bottom + 20),
        reason: '前提：信息块确实占了可观高度（否则本特性没有意义）');

    // ① 向下翻评论：手指上滑、内容上移（scrollDelta > 0）。
    //    分两步走，第二步之后停下看中间帧——第 60px 已超阈值 → 触发收起。
    final start = Offset(20, tester.getRect(find.byType(CommentListView)).center.dy);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(); // 应用滚动 + setState（收起动画第 0 帧）

    // 收起动画（kDurBase=200ms）进行到一半：评论区顶边应已上移但还没到位。
    await tester.pump(const Duration(milliseconds: 100));
    final midTop = _commentsTop(tester);
    expect(midTop, lessThan(expandedTop - 1),
        reason: '收起动画中评论区在顺滑地往上占位（不是瞬间跳变）');
    expect(midTop, greaterThan(video.bottom + 1),
        reason: '动画中间帧还没到最终位置 = 有中间态的实证');

    await gesture.up();
    await _settleAnim(tester); // 动画走完
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5),
        reason: '收起后评论区顶边顶到视频区下沿（多出的高度全给评论）');
    expect(find.byKey(_kInfoBar), findsOneWidget, reason: '信息块仍在树里（只是不占高度）');
    expect(tester.getRect(find.byKey(_kInfoBar)).top, closeTo(video.bottom, 0.5),
        reason: '收起态「信息行顶部 == 视频区底部」这条几何断言依旧成立');

    // ② 继续往下翻一段（离开顶部），再向上翻 → 展开。
    await _dragComments(tester, -300);
    await _settleAnim(tester);
    expect(_commentPixels(tester), greaterThan(100), reason: '已翻离列表顶部');
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5), reason: '仍是收起态');

    await _dragComments(tester, 80); // 手指下滑、内容下移
    await _settleAnim(tester);
    expect(_commentPixels(tester), greaterThan(0), reason: '展开靠的是方向，不是"到顶"');
    expect(_commentsTop(tester), closeTo(video.bottom + infoH, 0.5),
        reason: '向上翻评论 → 信息块重新出现（评论区让回高度）');
  });

  testWidgets('阈值防抖：单个手势位移小于阈值不切换；到顶强制展开', (tester) async {
    MotionControl.enabled = false;
    _installPlayerMock(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester);
    final video = tester.getRect(find.byKey(_kVideoArea));
    final infoH = _infoBarHeight(tester);

    // 先滚一点点（20px > 阈值 12）→ 收起，同时只离开顶部 20px。
    await _dragComments(tester, -20);
    await tester.pump();
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5),
        reason: '20px > 阈值 → 收起');

    // 小幅上翻（8px < 阈值 12）：位移真实发生（pixels 减少）但不切换。
    final before = _commentPixels(tester);
    await _dragComments(tester, 8);
    await tester.pump();
    final after = _commentPixels(tester);
    expect(before - after, closeTo(8, 0.5), reason: '8px 位移确实滚了');
    expect(after, greaterThan(0), reason: '还没到顶');
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5),
        reason: '小于阈值不切换（仍收起）');

    // 再两小步逼近/到达顶部：每步都小于阈值 → 方向判定始终不触发；
    // 触发展开的只可能是「到顶强制展开」这条分支。
    await _dragComments(tester, 8);
    await tester.pump();
    expect(_commentPixels(tester), closeTo(4, 0.5), reason: '第三小步后剩 4px');
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5),
        reason: '仍没收够反向阈值 → 还收着');

    await _dragComments(tester, 8);
    await tester.pump();
    expect(_commentPixels(tester), 0, reason: '已回到列表顶部');
    expect(_commentsTop(tester), closeTo(video.bottom + infoH, 0.5),
        reason: '到顶强制展开：回到顶部就该看见标题/简介');
  });

  testWidgets('关动效：一帧到位、无残留动画（pumpAndSettle 收敛）', (tester) async {
    MotionControl.enabled = false; // 测试默认值，显式写出来当档位证据
    _installPlayerMock(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester);
    final video = tester.getRect(find.byKey(_kVideoArea));
    final infoH = _infoBarHeight(tester);

    await _dragComments(tester, -80);
    // 只走一帧：关动效时不应该有"中间态"，几何应立刻到位。
    await tester.pump();
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5),
        reason: '关动效 = 瞬时到位（不建 controller、不排动画帧）');

    await _dragComments(tester, 80);
    await tester.pump();
    expect(_commentsTop(tester), closeTo(video.bottom + infoH, 0.5),
        reason: '展开同样瞬时到位');

    // 收敛证据：没有无限/未收敛的动画在转（否则这里会超时）。
    await tester.pumpAndSettle();
    expect(_commentsTop(tester), closeTo(video.bottom + infoH, 0.5),
        reason: 'pumpAndSettle 后仍停在展开态');
  });

  testWidgets('全屏不参与：无评论区；退出全屏后信息块复位为展开', (tester) async {
    MotionControl.enabled = false;
    _installPlayerMock(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester);
    final video = tester.getRect(find.byKey(_kVideoArea));
    final infoH = _infoBarHeight(tester);

    // 先在竖屏把信息块收起来（证明"收起态"确实存在过）。
    await _dragComments(tester, -120);
    await tester.pump();
    expect(_commentsTop(tester), closeTo(video.bottom, 0.5), reason: '竖屏已收起');

    // 进全屏：视频区占满整屏，信息块/评论区整个不在树里。
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(find.byKey(_kInfoBar), findsNothing, reason: '全屏无信息块');
    expect(find.byKey(_kComments), findsNothing, reason: '全屏无内嵌评论区');
    expect(tester.getRect(find.byKey(_kVideoArea)).height, closeTo(800, 0.5));

    // 退出全屏 → 回到竖屏布局，信息块是展开态（收起态不跨全屏残留）。
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(_commentsTop(tester), closeTo(video.bottom + infoH, 0.5),
        reason: '退出全屏后信息块重新出现');
  });

  testWidgets('横屏置顶模式不参与：滚评论不收信息块', (tester) async {
    MotionControl.enabled = false;
    _installPlayerMock(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester);
    final video = tester.getRect(find.byKey(_kVideoArea));
    final infoH = _infoBarHeight(tester);
    expect(infoH, greaterThan(0));
    final top0 = _commentsTop(tester);
    expect(top0, closeTo(video.bottom + infoH, 0.5));

    await _dragComments(tester, -120);
    await tester.pump();
    expect(_commentPixels(tester), greaterThan(0), reason: '横屏评论区确实滚动了');
    expect(_commentsTop(tester), closeTo(top0, 0.5),
        reason: '横屏置顶模式行为不变（信息块照旧占位）');
    expect(tester.getRect(find.byKey(_kInfoBar)).top,
        closeTo(video.bottom, 0.5));
  });
}
