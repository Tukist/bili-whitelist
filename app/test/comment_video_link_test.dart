// 评论视频链接换源（v2.16.23+，防双音轨）widget 测试。
//
// 背景：播放页 P 播视频 A → push 评论区 C → C 里点视频链接，旧实现 push
// 第二个 PlayerPage（P2）叠在栈顶 → P 播放器未释放 → P(A)+P2(B) 双音轨。
// 修复：C 点链接 → 回调 P 当前实例换源（停旧播新）+ pop C；无回调兜底 push。
//
// 覆盖：
// - PlayerPage.playVideo 换源：旧播放器 dispose、只新建一个播放器、
//   页面不叠加（标题切到新视频）；同 bvid 跳过不重载
// - CommentPage 有回调：点评论视频链接 → 回调拿到新视频 + pop 评论页
// - CommentPage 无回调：点评论视频链接 → 兜底 push 新 PlayerPage
//
// 测试环境说明（复用 speed_sheet_test 骨架 + 按路径路由的 HTTP fake）：
// - mock 原生播放器 MethodChannel（create 返回递增 textureId、记录调用）
// - mock secure storage / shared_preferences（登录态与设置不挂起）
// - mock HttpOverrides：按 URI 路径返回合法 nav / view / reply / playurl
//   JSON → BiliApi 取流与评论加载链路走通（不访问真实网络）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/comment_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

/// 初始播放的视频 A（评论入口所在视频）。
const String kVideoA = 'BV1AAAA11111';

/// 评论正文里链接指向的视频 B（点链接后续播/预览的目标）。
const String kVideoB = 'BV2BBBB22222';

WhitelistVideo _videoA() => const WhitelistVideo(
      bvid: kVideoA,
      cid: 1001,
      title: '视频A',
      cover: '',
      duration: 120,
      upName: 'upA',
      addedAt: '2026-01-01',
    );

WhitelistVideo _videoB() => const WhitelistVideo(
      bvid: kVideoB,
      cid: 2002,
      title: '评论链接视频B',
      cover: '',
      duration: 120,
      upName: 'upB',
      addedAt: '2026-01-01',
    );

// ---------------------------------------------------------------------------
// mock HTTP：flutter_test 默认把所有 HTTP 请求 mock 成 400 空响应，这里按
// URI 路径返回合法 JSON（nav 的 wbi_img + view 的元数据 + reply 的评论 +
// playurl 的 dash），让 BiliApi 各链路走通。
// ---------------------------------------------------------------------------

/// 按路径路由返回响应体（path → body）。
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
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(router, url);

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

/// view 接口 data：按 bvid 给两套元数据（aid 与评论 oid 对齐）。
Map<String, dynamic> _viewData(String? bvid) {
  final String b = bvid ?? kVideoA;
  if (b == kVideoB) {
    return {
      'bvid': kVideoB,
      'aid': 2002,
      'cid': 2002,
      'title': '评论链接视频B',
      'pic': '',
      'duration': 120,
      'owner': {'name': 'upB'},
      'pubdate': 1700000000,
      'pages': [
        {'cid': 2002, 'part': '', 'duration': 120},
      ],
    };
  }
  return {
    'bvid': kVideoA,
    'aid': 1001,
    'cid': 1001,
    'title': '视频A',
    'pic': '',
    'duration': 120,
    'owner': {'name': 'upA'},
    'pubdate': 1700000000,
    'pages': [
      {'cid': 1001, 'part': '', 'duration': 120},
    ],
  };
}

Map<String, dynamic> _viewBody(String? bvid) => {
      'code': 0,
      'data': _viewData(bvid),
    };

/// 一条根评论（正文含指向视频 B 的裸 BV 链接）。
Map<String, dynamic> _replyJson({
  required int rpid,
  required int oid,
  required String message,
}) =>
    {
      'rpid': rpid,
      'oid': oid,
      'root': 0,
      'parent': 0,
      'count': 0,
      'like': 3,
      'ctime': 1700000000,
      'member': {
        'uname': '评论君',
        'avatar': '',
        'level_info': {'current_level': 5},
      },
      'content': {'message': message},
    };

Map<String, dynamic> _replyMainBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        // 正文只含裸 BV 引用（评论里最常见的贴视频号形态）→ 整段渲染为
        // 可点链接（RichText 单链接段，便于 tap 命中中心即链接）
        'replies': [
          _replyJson(rpid: 5001, oid: 1001, message: kVideoB),
        ],
        'top_replies': [],
        'cursor': {'next': 0, 'is_end': true, 'all_count': 1},
      },
    };

Map<String, dynamic> _playurlBody() => {
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
            {'baseUrl': 'https://x.bilivideo.com/v.m4s'},
          ],
          'audio': [
            {'baseUrl': 'https://x.bilivideo.com/a.m4s'},
          ],
        },
      },
    };

Map<String, dynamic> _router(Uri uri) {
  final path = uri.path;
  if (path.endsWith('/x/frontend/finger/spi')) return _spiBody();
  if (path.endsWith('/x/web-interface/nav')) return _navBody();
  if (path.endsWith('/x/web-interface/view')) {
    return _viewBody(uri.queryParameters['bvid']);
  }
  if (path.endsWith('/x/v2/reply/main')) return _replyMainBody();
  if (path.contains('playurl')) return _playurlBody();
  // 未命中路径返回空 data（调用方按空/错误处理，不影响已覆盖链路）
  return {'code': 0, 'data': {}};
}

// ---- 平台通道 mock ---------------------------------------------------------

/// 安装测试环境：HTTP 路由 + 播放器/安全存储通道 mock。
/// [playerLog] 记录 bili_dash_player 通道的调用（create/setDataSource/
/// dispose/…），用于断言换源过程只停旧建新。
void _installEnv(WidgetTester tester, List<String> playerLog) {
  SharedPreferences.setMockInitialValues({});
  final oldOverrides = HttpOverrides.current;
  HttpOverrides.global = _FakeHttpOverrides(_router);
  addTearDown(() => HttpOverrides.global = oldOverrides);

  var texId = 0;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      playerLog.add(call.method);
      if (call.method == 'create') return ++texId;
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_dash_player'), null));

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null));
}

/// 在宿主页上 push 一个 CommentPage（便于断言 pop 后回宿主）。
Future<void> _pushCommentPage(
  WidgetTester tester,
  GlobalKey<NavigatorState> navKey, {
  void Function(WhitelistVideo video)? onOpenVideoPreview,
}) async {
  navKey.currentState!.push(MaterialPageRoute<void>(
    builder: (_) => CommentPage(
      video: _videoA(),
      onOpenVideoPreview: onOpenVideoPreview,
    ),
  ));
  await tester.pumpAndSettle();
}

/// 等待评论列表首屏出现链接文本（网络 + 列表渲染）。
Future<void> _pumpNetwork(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerPage 评论视频链接换源（playVideo）', () {
    testWidgets('停旧播新：旧播放器 dispose、只新建一个播放器、页面不叠加',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      await tester
          .pumpWidget(MaterialApp(home: PlayerPage(video: _videoA())));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.text('视频A'), findsOneWidget);
      final createsBefore = log.where((m) => m == 'create').length;
      expect(createsBefore, 1, reason: '首次进入应只创建一个播放器');

      // 触发评论视频链接换源（等价于 C 点链接后回调本方法）。
      // 不 await：playVideo 内含 .timeout(500ms) 等假时钟定时器，需由
      // pumpAndSettle 推进时间（await 会死锁 fake-async）。
      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      unawaited(state.playVideo(_videoB()));
      await tester.pumpAndSettle();

      // 旧播放器已释放 → 无双播放器双音轨
      expect(log.where((m) => m == 'dispose'), hasLength(1),
          reason: '换源应 dispose 旧播放器');
      // 只新建了 1 个播放器（停旧建新，非叠第二个页面）
      expect(log.where((m) => m == 'create'), hasLength(createsBefore + 1),
          reason: '换源只新建一个播放器');
      // 同一页面换源：页面不叠加、标题已切到新视频
      expect(find.byType(PlayerPage), findsOneWidget,
          reason: '换源不应新增第二个播放页');
      expect(find.text('评论链接视频B'), findsOneWidget);
      expect(find.text('视频A'), findsNothing);
    });

    testWidgets('同 bvid 点击不重载：不 dispose 不新建播放器', (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      await tester
          .pumpWidget(MaterialApp(home: PlayerPage(video: _videoA())));
      await tester.pumpAndSettle();
      final createsBefore = log.where((m) => m == 'create').length;

      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      unawaited(state.playVideo(_videoA())); // 点的是正在播的同一视频
      await tester.pumpAndSettle();

      expect(log.where((m) => m == 'dispose'), isEmpty,
          reason: '同 bvid 不应动播放器');
      expect(log.where((m) => m == 'create'), hasLength(createsBefore),
          reason: '同 bvid 不应新建播放器');
      expect(find.text('视频A'), findsOneWidget);
    });
  });

  group('CommentPage 评论视频链接（v2.16.23+）', () {
    testWidgets('有回调：点链接 → 回调拿新视频 + pop 评论页回播放页', (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      WhitelistVideo? opened;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('宿主页'))),
      ));
      await _pushCommentPage(tester, navKey, onOpenVideoPreview: (v) {
        opened = v;
      });
      expect(find.byType(CommentPage), findsOneWidget);
      // 评论正文里的视频链接已渲染为可点文本
      expect(find.text(kVideoB, findRichText: true), findsOneWidget);

      await tester.tap(find.text(kVideoB, findRichText: true));
      await _pumpNetwork(tester);
      await tester.pumpAndSettle(); // 等 pop 退场动画完成

      // 回调换源：拿到目标视频
      expect(opened, isNotNull, reason: '有回调时应回调播放页换源');
      expect(opened!.bvid, kVideoB);
      // 评论页已 pop（回播放页观看）
      expect(find.byType(CommentPage), findsNothing,
          reason: '回调换源后应 pop 评论页');
      expect(find.text('宿主页'), findsOneWidget);
    });

    testWidgets('无回调（评论页独立打开）：兜底 push 新 PlayerPage 预览',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('宿主页'))),
      ));
      await _pushCommentPage(tester, navKey); // 不传回调
      expect(find.text(kVideoB, findRichText: true), findsOneWidget);

      await tester.tap(find.text(kVideoB, findRichText: true));
      await _pumpNetwork(tester);
      await tester.pumpAndSettle(); // 等新页 push 动画完成

      // 兜底 push 新 PlayerPage（旧行为保留）→ 新页盖住评论页
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.text('评论链接视频B'), findsWidgets);
      // 评论页在 opaque 路由下方，push 完成后不在可见树中（仍在栈上）
      expect(find.byType(CommentPage), findsNothing);
    });
  });
}
