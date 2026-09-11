// 评论区头像点击 → 作者个人主页（v2.22.0+）widget 测试。
//
// 覆盖：
// - 三个位置的头像都能点：根评论 / 内嵌楼中楼预览 / 展开后的楼中楼
// - 点击 → push UpownerPage（mid 取自 `member.mid`，并把评论里的
//   uname/avatar 预填成 initial 让个人页秒开）
// - 头像热区 ≥48×48（Android 触摸目标；头像本体只有 34/20/18px）
// - mid 无效（`member.mid` 缺失 / `"0"`）→ 头像**不挂手势**，点了不跳转
// - 既有交互不被破坏：点完头像评论列表仍在（不误触正文/楼中楼展开）
//
// 测试环境说明（骨架与 comment_block_flow_test 同款）：按 URI 路径返回合法
// JSON 的 fake HttpClient（不触网）+ secure storage / shared_preferences 通道
// mock。UP 主页的接口也给合法空响应——否则那页的退避重试会留下 pending timer。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

const String kBvid = 'BV1AVATAR111';

/// 三个位置各自的作者 mid。
const int kRootMid = 54321;
const int kPreviewMid = 999;
const int kSubMid = 777;

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
// 可调用例开头覆盖的 fixture 开关（每个用例 setUp 里重置）
// ---------------------------------------------------------------------------

/// 根评论作者的 `member.mid`：null = 接口不给该字段（老数据）；'0' = 无效。
String? _rootMid = '$kRootMid';

/// 根评论作者头像（默认空串：测试里不发图片请求，避免图床错误噪音）。
String _rootAvatar = '';

void _resetFixtures() {
  _rootMid = '$kRootMid';
  _rootAvatar = '';
}

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
  Future<HttpClientResponse> close() async =>
      _FakeHttpResponse(utf8.encode(jsonEncode(router(_uri))));

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
  }) =>
      handle!.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

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

Map<String, dynamic> _member({
  required String uname,
  required String? mid,
  String avatar = '',
}) =>
    {
      'uname': uname,
      'avatar': avatar,
      if (mid != null) 'mid': mid,
      'level_info': {'current_level': 5},
    };

Map<String, dynamic> _reply({
  required int rpid,
  required Map<String, dynamic> member,
  String message = '前排',
  int count = 0,
  List<Map<String, dynamic>>? replies,
}) =>
    {
      'rpid': rpid,
      'root': 0,
      'parent': 0,
      'count': count,
      'like': 3,
      'ctime': 1700000000,
      'member': member,
      'content': {'message': message},
      if (replies != null) 'replies': replies,
    };

/// 主评论：1 条根评论（作者 = [_rootMid]），内嵌 1 条预览（作者 = kPreviewMid）。
Map<String, dynamic> _replyMainBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        'replies': [
          _reply(
            rpid: 5001,
            count: 2,
            member: _member(
              uname: '评论君',
              mid: _rootMid,
              avatar: _rootAvatar,
            ),
            message: '根评论正文',
            replies: [
              _reply(
                rpid: 6001,
                member: _member(uname: '预览君', mid: '$kPreviewMid'),
                message: '预览正文',
              ),
            ],
          ),
        ],
        'top_replies': <Map<String, dynamic>>[],
        'cursor': {'next': 0, 'is_end': true, 'all_count': 1},
      },
    };

/// 楼中楼（展开「2 条回复」后拉）：两条子回复。
Map<String, dynamic> _replyChildrenBody() => {
      'code': 0,
      'message': 'success',
      'data': {
        'replies': [
          _reply(
            rpid: 7001,
            member: _member(uname: '楼中楼君', mid: '$kSubMid'),
            message: '子回复一',
          ),
          _reply(
            rpid: 7002,
            member: _member(uname: '路过君', mid: '$kRootMid'),
            message: '子回复二',
          ),
        ],
        'page': {'num': 1, 'size': 20, 'count': 2},
      },
    };

// ---- UP 主页（push 后由 UpownerPage 自己发的请求；给合法响应，避免退避重试
//      在测试结束前还留着 pending timer）------------------------------------

Map<String, dynamic> _accInfoBody() => {
      'code': 0,
      'message': 'OK',
      'data': {'name': '评论君', 'face': '', 'sign': ''},
    };

Map<String, dynamic> _statBody() => {
      'code': 0,
      'message': 'OK',
      'data': {'mid': kRootMid, 'follower': 10},
    };

Map<String, dynamic> _emptyVideosBody() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'list': {'count': 0, 'vlist': <Map<String, dynamic>>[]},
        'page': {'count': 0},
      },
    };

Map<String, dynamic> _emptyCollectionsBody() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'items_lists': {
          'page': {'page_num': 1, 'page_size': 20, 'total': 0},
          'seasons_list': <Map<String, dynamic>>[],
          'series_list': <Map<String, dynamic>>[],
        },
      },
    };

Map<String, dynamic> _router(Uri uri) {
  final path = uri.path;
  if (path.endsWith('/x/frontend/finger/spi')) return _spiBody();
  if (path.endsWith('/x/web-interface/nav')) return _navBody();
  if (path.endsWith('/x/web-interface/view')) return _viewBody();
  if (path.endsWith('/x/v2/reply/main')) return _replyMainBody();
  if (path.endsWith('/x/v2/reply/reply')) return _replyChildrenBody();
  if (path.endsWith('/x/space/wbi/acc/info')) return _accInfoBody();
  if (path.endsWith('/x/relation/stat')) return _statBody();
  if (path.endsWith('/x/space/wbi/arc/search')) return _emptyVideosBody();
  if (path.endsWith('/x/polymer/web-space/seasons_series_list')) {
    return _emptyCollectionsBody();
  }
  return {'code': 0, 'data': <String, dynamic>{}};
}

// ---------------------------------------------------------------------------
// 测试骨架
// ---------------------------------------------------------------------------

void _installEnv(WidgetTester tester) {
  SharedPreferences.setMockInitialValues({});
  final oldOverrides = HttpOverrides.current;
  HttpOverrides.global = _FakeHttpOverrides(_router);
  addTearDown(() => HttpOverrides.global = oldOverrides);

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null));
}

Future<void> _pumpComments(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: CommentListView(video: _video())),
  ));
  await tester.pumpAndSettle();
  expect(find.text('根评论正文'), findsOneWidget);
}

/// 点某张卡片（[AppBlock]）里的头像。
///
/// 头像热区左上角 = 卡内 (12,12)（comment 规格内边距）且 48 见方，取点
/// (24,24) 稳落在热区里——**不**依赖 `find.byType(InkWell)`（mid 无效时头像
/// 本来就没有 InkWell，点「头像位置」才是真实用户行为）。
Future<void> _tapAvatarIn(WidgetTester tester, Finder card) async {
  final tl = tester.getTopLeft(card);
  await tester.tapAt(tl + const Offset(24, 24));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _resetFixtures();
    // UP 主信息会话缓存跨用例隔离（静态缓存会串数据）
    UpownerPage.clearInfoCacheForTest();
  });

  testWidgets('根评论头像：热区 ≥48×48，点击 push 个人主页（mid + 名字预填）',
      (tester) async {
    _installEnv(tester);
    await _pumpComments(tester);

    final card = find.byType(AppBlock).first;
    final avatarTap =
        find.descendant(of: card, matching: find.byType(InkWell)).first;
    final size = tester.getSize(avatarTap);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    await _tapAvatarIn(tester, card);

    expect(find.byType(UpownerPage), findsOneWidget);
    final page = tester.widget<UpownerPage>(find.byType(UpownerPage));
    expect(page.mid, kRootMid);
    expect(page.initial?.name, '评论君', reason: '评论里的 uname 预填，秒开头部');
    expect(page.initial?.mid, kRootMid);
  });

  testWidgets('根评论头像：带评论里的头像 URL → 预填到 initial.face',
      (tester) async {
    _installEnv(tester);
    _rootAvatar = '//i0.hdslb.com/bfs/face/root.jpg';
    await _pumpComments(tester);

    await _tapAvatarIn(tester, find.byType(AppBlock).first);

    final page = tester.widget<UpownerPage>(find.byType(UpownerPage));
    expect(page.initial?.face, 'https://i0.hdslb.com/bfs/face/root.jpg');
  });

  testWidgets('根评论 mid 缺失（老数据）：头像不挂手势，点了不跳转',
      (tester) async {
    _installEnv(tester);
    _rootMid = null;
    await _pumpComments(tester);

    final card = find.byType(AppBlock).first;
    // 根头像不挂手势：卡内 InkWell 只剩「预览头像」+「2 条回复」两个
    // （mid 有效时是 3 个——根头像占一个）
    expect(find.descendant(of: card, matching: find.byType(InkWell)),
        findsNWidgets(2),
        reason: 'mid 无效 → 根头像不包 InkWell');

    await _tapAvatarIn(tester, card);

    expect(find.byType(UpownerPage), findsNothing);
    // 评论列表没被破坏（仍在原位）
    expect(find.text('根评论正文'), findsOneWidget);
  });

  testWidgets('根评论 mid="0"（无效）：同样不跳转', (tester) async {
    _installEnv(tester);
    _rootMid = '0';
    await _pumpComments(tester);

    await _tapAvatarIn(tester, find.byType(AppBlock).first);

    expect(find.byType(UpownerPage), findsNothing);
  });

  testWidgets('楼中楼预览头像：可点进个人页（mid 取自预览条目）', (tester) async {
    _installEnv(tester);
    await _pumpComments(tester);

    expect(find.text('预览正文'), findsOneWidget);
    // AppBlock 顺序：根评论卡(0) → 内嵌预览块(1)
    await _tapAvatarIn(tester, find.byType(AppBlock).at(1));

    final page = tester.widget<UpownerPage>(find.byType(UpownerPage));
    expect(page.mid, kPreviewMid);
    expect(page.initial?.name, '预览君');
  });

  testWidgets('展开后的楼中楼头像：可点进个人页', (tester) async {
    _installEnv(tester);
    await _pumpComments(tester);

    await tester.tap(find.text('2 条回复'));
    await tester.pumpAndSettle();
    expect(find.text('子回复一'), findsOneWidget);

    // 展开后预览块收起：AppBlock 顺序 = 根评论卡(0) → 子回复一(1) → 子回复二(2)
    await _tapAvatarIn(tester, find.byType(AppBlock).at(1));

    final page = tester.widget<UpownerPage>(find.byType(UpownerPage));
    expect(page.mid, kSubMid);
    expect(page.initial?.name, '楼中楼君');
  });

  testWidgets('点头像不影响既有交互：返回后评论列表照常（正文/图片区都在）',
      (tester) async {
    _installEnv(tester);
    await _pumpComments(tester);
    await _tapAvatarIn(tester, find.byType(AppBlock).first);
    expect(find.byType(UpownerPage), findsOneWidget);

    // 返回评论列表：内容仍在、无异常
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.byType(UpownerPage), findsNothing);
    expect(find.text('根评论正文'), findsOneWidget);
    expect(find.text('预览正文'), findsOneWidget);
  });
}
