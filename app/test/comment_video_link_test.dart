// 评论视频链接跳转（v2.17.1+，阶段 B）widget 测试。
//
// 背景：播放页 P 播视频 A → 评论区（竖屏内嵌 / 全屏独立页 C）里点视频链接，
// 旧实现（v2.16.23）回调 P 当前实例 playVideo 换源（防双音轨，但不可返回）。
// 阶段 B：改为 **push 新 PlayerPage（P2 播 B）**——P 在 push 前显式暂停并保存
// 进度（防双音轨）；P2 返回 → P 经 RouteAware didPopNext 恢复续播 A。
// 覆盖：
// - PlayerPage.playVideo 换源（v2.16.23+ 语义）保留：旧播放器 dispose、只新建
//   一个播放器、页面不叠加（内部换源回归，多 P 等仍可用）
// - didPushNext/didPopNext 路由可见性：P 叠 P2 → 暂停（channel 记 pause）；
//   P2 返回 → 恢复（channel 记 play）；非 'player' 路由（评论页）叠上不暂停
//   （边看边评回归）
// - CommentPage 有回调（onNavigateToVideo，由播放页传）：点评论视频链接 →
//   pop 评论页 + 回调把新视频交给宿主（宿主 push 新播放页）
// - CommentPage 无回调：点评论视频链接 → 兜底 push 新 PlayerPage（name 'player'）
// - 链接带 ?p/?t 定位参数（v2.17.6+）：解析/回调透传 pageIndex+positionMs；
//   异 bvid → 叠新播放页带 initialPageIndex/initialPositionMs；同 bvid → 本页
//   定位/切集（不叠页不暂停）
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

import 'package:bili_whitelist_app/main.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/comment_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

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

/// 多 P 版视频 A（两集）——同 bvid 评论链接带 ?p 跳自家另一集（本页内切集）
/// 的测试样本。
WhitelistVideo _videoAMulti() => const WhitelistVideo(
      bvid: kVideoA,
      cid: 1001,
      title: '视频A(多P)',
      cover: '',
      duration: 120,
      upName: 'upA',
      addedAt: '2026-01-01',
      pages: [
        PageInfo(cid: 1001, part: '第1集', duration: 120),
        PageInfo(cid: 1002, part: '第2集', duration: 120),
      ],
    );

/// 评论正文里带 ?p/?t 定位参数的完整视频链接（B 站 web 分享串形态：
/// p=分P号(1起)、t=秒（可小数））。target：分 P 2 + 129s。
const String kVideoBLinkP2T129 =
    'https://www.bilibili.com/video/BV2BBBB22222?p=2&t=129.0';

/// 同上但仅 ?t（无 p → 不分 P，只定位进度 45s）。
const String kVideoBLinkT45 = 'https://www.bilibili.com/video/BV2BBBB22222?t=45';

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

/// 可覆盖的评论正文（默认裸 BV 链接；带 ?p/?t 完整链接的分发用例改为完整
/// 分享链接，见 ?p/?t 组）。测试顺序执行，用例开头设置即可。
String _replyMessage = kVideoB;

Map<String, dynamic> _replyMainBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        // 正文只含一个链接引用（默认裸 BV，或 ?p/?t 完整链接）→ 整段渲染为
        // 可点链接（RichText 单链接段，便于 tap 命中中心即链接）
        'replies': [
          _replyJson(rpid: 5001, oid: 1001, message: _replyMessage),
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
  OpenCommentVideo? onNavigateToVideo,
}) async {
  navKey.currentState!.push(MaterialPageRoute<void>(
    builder: (_) => CommentPage(
      video: _videoA(),
      onNavigateToVideo: onNavigateToVideo,
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

  group('CommentPage 评论视频链接（v2.17.1+ 跳转语义）', () {
    testWidgets('有回调：点链接 → 回调拿新视频 + pop 评论页回宿主（宿主负责叠新播放页）',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      WhitelistVideo? opened;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('宿主页'))),
      ));
      await _pushCommentPage(tester, navKey, onNavigateToVideo: (v,
          {int? pageIndex, int? positionMs}) {
        opened = v;
      });
      expect(find.byType(CommentPage), findsOneWidget);
      // 评论正文里的视频链接已渲染为可点文本
      expect(find.text(kVideoB, findRichText: true), findsOneWidget);

      await tester.tap(find.text(kVideoB, findRichText: true));
      await _pumpNetwork(tester);
      await tester.pumpAndSettle(); // 等 pop 退场动画完成

      // v2.17.1+ 语义：先 pop 评论页，再把视频交给宿主（播放页 push 新播放页）
      expect(opened, isNotNull, reason: '有回调时应回调宿主拿到目标视频');
      expect(opened!.bvid, kVideoB);
      // 评论页已 pop（回到宿主——生产环境宿主是播放页，会继续 push P2）
      expect(find.byType(CommentPage), findsNothing,
          reason: '回调前应已 pop 评论页');
      expect(find.text('宿主页'), findsOneWidget);
    });

    testWidgets('无回调（评论页独立打开）：兜底 push 新 PlayerPage（路由名 player）预览',
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
      // 兜底 push 的路由统一命名 'player'（下方若有播放页，其 RouteAware
      // 也能据此……本版本 didPushNext 无参不做事，命名保留一致性/文档语义）
      final playerElement = tester.element(find.byType(PlayerPage));
      final route = ModalRoute.of(playerElement);
      expect(route?.settings.name, kPlayerRouteName,
          reason: '兜底 push PlayerPage 应带路由名 kPlayerRouteName');
    });
  });

  group('评论链接跳转/返回（v2.17.1+ 阶段 B：push 新播放页 + 暂停 + 返回续播）', () {
    testWidgets('P 叠 P2 → 播放器暂停（无双音轨）；P2 返回 → P 恢复（play）',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [routeObserver],
        home: PlayerPage(video: _videoA()),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.text('视频A'), findsOneWidget);
      expect(log.where((m) => m == 'pause'), isEmpty, reason: '初始不应暂停');

      // 播放页评论链接入口（内嵌评论 onOpenVideo / 独立评论页回调共用）：
      // push 新播放页 B（路由名 'player'），push 前本页显式暂停。
      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      state.openVideoInNewPlayer(_videoB());
      await tester.pumpAndSettle();

      // 旧页暂停（防双音轨）且新页 B 叠上可见
      expect(log.where((m) => m == 'pause'), hasLength(1),
          reason: 'push 新播放页前应暂停当前播放器');
      expect(find.text('视频A'), findsNothing, reason: 'A 页被新播放页盖住');
      expect(find.text('评论链接视频B'), findsWidgets);

      // 返回（pop P2）→ P 恢复续播
      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(log.where((m) => m == 'play'), hasLength(1),
          reason: '返回后应恢复播放（play）');
      expect(find.text('视频A'), findsOneWidget, reason: '回到 A 播放页');
    });

    testWidgets('打开独立评论页 C（非 player 路由）→ 本页不暂停（边看边评）',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [routeObserver],
        home: PlayerPage(video: _videoA()),
      ));
      await tester.pumpAndSettle();
      // 模拟播放页横屏「评论」按钮：push 全屏独立评论页（播放页同款回调：
      // C 内点视频链接 → C 先 pop 自己再交给宿主 push 新播放页）
      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => CommentPage(
          video: _videoA(),
          onNavigateToVideo: (v, {int? pageIndex, int? positionMs}) =>
              state.openVideoInNewPlayer(v,
                  pageIndex: pageIndex, positionMs: positionMs),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(CommentPage), findsOneWidget);
      expect(log.where((m) => m == 'pause'), isEmpty,
          reason: '打开独立评论页不应暂停播放（边看边评）');

      // C 里点视频链接 → C pop → 宿主 push P2（本页暂停）
      await tester.tap(find.text(kVideoB, findRichText: true));
      await _pumpNetwork(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CommentPage), findsNothing, reason: 'C 已先关闭');
      expect(log.where((m) => m == 'pause'), hasLength(1),
          reason: '跳新播放页前应暂停本页播放');
      expect(find.text('评论链接视频B'), findsWidgets, reason: 'P2(B) 已叠上');

      // P2 返回 → C 已不在栈中，直接回到 P → A 恢复续播
      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(log.where((m) => m == 'play'), hasLength(1),
          reason: '返回后应恢复播放（play）');
      expect(find.text('视频A'), findsOneWidget, reason: '回到 A 播放页');
    });

    testWidgets('点同 bvid（本视频自身）：不暂停不叠页', (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [routeObserver],
        home: PlayerPage(video: _videoA()),
      ));
      await tester.pumpAndSettle();
      final createsBefore = log.where((m) => m == 'create').length;

      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      state.openVideoInNewPlayer(_videoA()); // 点正在播的同一视频
      await tester.pumpAndSettle();

      expect(log.where((m) => m == 'pause'), isEmpty,
          reason: '同 bvid 不应暂停');
      expect(log.where((m) => m == 'create'), hasLength(createsBefore),
          reason: '同 bvid 不应叠新播放页');
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.text('视频A'), findsOneWidget);
    });
  });

  group('评论视频链接 ?p/?t 定位跳转（v2.17.6+）', () {
    testWidgets('完整链接带 ?p=2&t=129.0：点击 → 回调宿主拿到 pageIndex=1/'
        'positionMs=129000（薄壳先 pop 再转发）', (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      WhitelistVideo? opened;
      int? gotP;
      int? gotT;
      _replyMessage = kVideoBLinkP2T129; // 评论正文 = 完整分享链接（带 p/t）
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('宿主页'))),
      ));
      await _pushCommentPage(tester, navKey, onNavigateToVideo:
          (v, {int? pageIndex, int? positionMs}) {
        opened = v;
        gotP = pageIndex;
        gotT = positionMs;
      });
      // 评论正文 = 带 ?p/?t 的完整分享链接（整段渲染为可点链接）
      final linkFinder = find.text(kVideoBLinkP2T129, findRichText: true);
      expect(linkFinder, findsOneWidget);
      await tester.ensureVisible(linkFinder);
      await tester.pump();
      // 长链接在 776px 宽内折成两行，中心点可能落在字形间隙 → 点第一行左端
      // 字形处（真实点击同理命中文本即触发 recognizer）
      final tl = tester.getTopLeft(linkFinder);
      await tester.tapAt(tl + const Offset(30, 10));
      await _pumpNetwork(tester);
      await tester.pumpAndSettle();

      expect(opened, isNotNull, reason: '应回调宿主拿到目标视频');
      expect(opened!.bvid, kVideoB);
      expect(gotP, 1, reason: 'p=2（1起）→ pageIndex=1（0起）');
      expect(gotT, 129000, reason: 't=129.0 秒 → 129000ms（小数秒支持）');
      expect(find.byType(CommentPage), findsNothing, reason: '薄壳已 pop 回宿主');
    });

    testWidgets('无回调兜底：push 新 PlayerPage 透传 initialPageIndex=0 + '
        'initialPositionMs=45000（仅 ?t=45）', (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      _replyMessage = kVideoBLinkT45; // 评论正文 = 仅带 ?t 的完整链接
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Center(child: Text('宿主页'))),
      ));
      await _pushCommentPage(tester, navKey); // 不传回调 → 列表兜底 push
      expect(find.text(kVideoBLinkT45, findRichText: true), findsOneWidget);
      await tester.tap(find.text(kVideoBLinkT45, findRichText: true));
      await _pumpNetwork(tester);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerPage), findsOneWidget);
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.initialPageIndex, 0, reason: '无 p → 默认第 1 集');
      expect(page.initialPositionMs, 45000, reason: 't=45 → 初始定位 45s');
    });

    testWidgets('异 bvid + p/t：叠新播放页（initialPageIndex/initialPositionMs '
        '透传）且旧页暂停防双音轨', (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [routeObserver],
        home: PlayerPage(video: _videoA()),
      ));
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      state.openVideoInNewPlayer(_videoB(), pageIndex: 1, positionMs: 45000);
      await tester.pumpAndSettle();

      expect(log.where((m) => m == 'pause'), hasLength(1),
          reason: 'push 新播放页前应暂停当前播放');
      // opaque 路由叠页：旧页不在可见树中（其 State 保留），可见的只剩新页
      expect(find.byType(PlayerPage), findsOneWidget,
          reason: '叠上新播放页后可见 PlayerPage 为新页');
      final pushed = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(pushed.video.bvid, kVideoB);
      expect(pushed.initialPageIndex, 1, reason: 'p=2 → 新页初始分P下标 1');
      expect(pushed.initialPositionMs, 45000,
          reason: 't=45 → 新页初始定位（覆盖该页记忆进度）');
    });

    testWidgets('同 bvid 同集链接带 t：本页定位，不叠页不暂停不新建播放器',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _videoA())));
      await tester.pumpAndSettle();
      final createsBefore = log.where((m) => m == 'create').length;

      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      state.openVideoInNewPlayer(_videoA(), positionMs: 45000);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerPage), findsOneWidget, reason: '同 bvid 不叠页');
      expect(log.where((m) => m == 'pause'), isEmpty, reason: '同 bvid 不暂停');
      expect(log.where((m) => m == 'create'), hasLength(createsBefore),
          reason: '同 bvid 不新建播放器');
      expect(log.where((m) => m == 'dispose'), isEmpty);
      // 注：测试环境无原生 onPrepared（播放器不进入 loaded），同集 t 走
      // 「入队等 onPrepared 定位」（_pendingSeekMs）；真实设备 seek 证据见
      // 模拟器实测日志。
    });

    testWidgets('同 bvid 异分P链接（?p=2）+t：本页内切集重取流，不叠页',
        (tester) async {
      final log = <String>[];
      _installEnv(tester, log);
      await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _videoAMulti())));
      await tester.pumpAndSettle();
      final createsBefore = log.where((m) => m == 'create').length;
      final loadsBefore = log.where((m) => m == 'setDataSource').length;

      final state = tester.state(find.byType(PlayerPage)) as dynamic;
      state.openVideoInNewPlayer(_videoAMulti(), pageIndex: 1, positionMs: 30000);
      await tester.pumpAndSettle();

      expect(find.byType(PlayerPage), findsOneWidget,
          reason: '同 bvid 分P跳本页切集，不叠第二个播放页');
      expect(log.where((m) => m == 'pause'), isEmpty);
      expect(log.where((m) => m == 'create'), hasLength(createsBefore));
      expect(log.where((m) => m == 'setDataSource'),
          hasLength(loadsBefore + 1),
          reason: '切到第 2 集重取流（本页内）');
    });
  });
}
