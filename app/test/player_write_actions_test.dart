// 播放页写操作（点赞 / 投币 / 收藏，v2.40.0+）widget 测试。
//
// 覆盖：
// - **总开关默认关**：一个写操作按钮都不构建（"关着 = 一个像素都不多"）；
// - 打开后：信息块出现「点赞 / 投币 / 收藏」三按钮（含点赞数格式化）；
// - 点赞初始态：view 的 `req_user.like` 存在 → 显示「已赞」；**不存在**
//   （未登录/接口没下发）→ 显示如实标注「状态未取到，重启后可能显示不准」；
// - 点赞：成功的乐观切换（按钮变「已赞」）+ 请求表单正确（like=1 + csrf）；
// - 点赞失败：**界面回滚** + **错误类 SnackBar**（连"关掉提示条"开关也挡不住）；
// - 投币：**必须二次确认**——点「取消」一个写请求都不发；点确认才发
//   coin/add（multiply=1 + select_like=1）；
// - 收藏：弹收藏夹列表（上次选过的排第一）→ 选一个 → add_media_ids=该 fid，
//   并把 fid 记进 UiPrefsStore；已收藏时走 del_media_ids；
// - 收藏夹弹层取消 → 不发请求；
// - 番剧集（epId != null）：即便总开关打开也不显示（pgc 是另一套接口）。
//
// 环境：mock HttpOverrides 记录**方法 + 路径 + 请求体**，按路径回合法 JSON；
// 不动真实网络、不发真实写请求。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';

/// 每条用例一个**独立 bvid**：播放页把 view 的 owner/desc/req_user/stat/aid
/// 按 bvid 做**会话内全局缓存**（`_upMetaCache` / `_reqUserCache` 等都是
/// player_page.dart 的 file-scope 变量，跨用例不重置）。同一个 bvid 复用会
/// 命中上一条用例留下的缓存、拿不到本用例配置的 `req_user`——给每条用例换
/// bvid，缓存天然隔离，不必去动生产代码里的私有状态。
String _bvid = 'BV1WRITE1000';
int _bvidSeq = 0;
const int _kAid = 3003;
const String _kJct = 'jct-write-test';

const Key _kWriteRow = ValueKey('player-write-actions');
const Key _kLike = ValueKey('write-like');
const Key _kCoin = ValueKey('write-coin');
const Key _kFav = ValueKey('write-fav');
const Key _kCoinConfirm = ValueKey('write-coin-confirm');
const Key _kStateUnknown = ValueKey('write-state-unknown');

const String _kLikePath = '/x/web-interface/archive/like';
const String _kCoinPath = '/x/web-interface/coin/add';
const String _kFavDealPath = '/x/v3/fav/resource/deal';
const String _kFavListPath = '/x/v3/fav/folder/created/list-all';

/// 互动态只读接口（v2.41.0+）。
const String _kRelationPath = '/x/web-interface/archive/relation';

WhitelistVideo _video({int? epId}) => WhitelistVideo(
      bvid: _bvid,
      cid: 1001,
      title: '写操作测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      desc: '一段简介，让信息块有内容。',
      epId: epId,
    );

// ---------------------------------------------------------------------------
// 记录型 HTTP fake
// ---------------------------------------------------------------------------

/// 一条被记录下来的请求。
class _Req {
  _Req(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final String body;

  /// 表单体解析（写请求都是 form-urlencoded）。
  Map<String, String> get form => body.isEmpty
      ? const {}
      : Map.fromEntries(body.split('&').where((s) => s.contains('=')).map((s) {
          final i = s.indexOf('=');
          return MapEntry(
            Uri.decodeQueryComponent(s.substring(0, i)),
            Uri.decodeQueryComponent(s.substring(i + 1)),
          );
        }));
}

final List<_Req> _recorded = [];

/// 各测试按需覆盖的响应钩子（path → JSON）。
Map<String, Map<String, dynamic> Function()> _overrideHandlers = {};

/// view 响应里的 `req_user`（null = 接口不下发，验证降级路径）。
Map<String, dynamic>? _reqUser;

/// 是否让写接口返回业务错误（键 = path，值 = 完整响应体）。
Map<String, Map<String, dynamic>> _writeFailures = {};

Map<String, dynamic> _replyJson(int i) => {
      'rpid': 1000 + i,
      'oid': _kAid,
      'root': 0,
      'parent': 0,
      'count': 0,
      'like': i,
      'ctime': 1700000000,
      'member': {
        'uname': '用户$i',
        'avatar': '',
        'level_info': {'current_level': 3},
      },
      'content': {'message': '第 $i 条评论，占位用。'},
      'replies': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _router(Uri uri) {
  final path = uri.path;
  final override = _overrideHandlers[path];
  if (override != null) return override();

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
        'mid': 1001,
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
        'bvid': _bvid,
        'aid': _kAid,
        'cid': 1001,
        'title': '写操作测试视频',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '一段简介，让信息块有内容。',
        'pubdate': 1700000000,
        'stat': {'like': 12345, 'coin': 67, 'favorite': 8},
        if (_reqUser != null) 'req_user': _reqUser!,
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
        'replies': List.generate(3, _replyJson),
        'top_replies': <Map<String, dynamic>>[],
        'cursor': {'is_end': true},
      },
    };
  }
  if (path.endsWith(_kFavListPath)) {
    return {
      'code': 0,
      'data': {
        'count': 2,
        'list': [
          {'media_id': 111, 'title': '默认收藏夹', 'media_count': 3},
          {'media_id': 222, 'title': '音乐', 'media_count': 1},
        ],
      },
    };
  }
  // 写接口：默认成功；测试可塞 _writeFailures 让某个 path 返回业务错误
  for (final p in [_kLikePath, _kCoinPath, _kFavDealPath]) {
    if (path.endsWith(p)) {
      return _writeFailures[p] ?? {'code': 0, 'data': null};
    }
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
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpRequest('GET', url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(method, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.method, this.requestUri);

  @override
  final String method;

  final Uri requestUri;
  final BytesBuilder _body = BytesBuilder();

  @override
  HttpHeaders get headers => _FakeHttpHeaders();
  @override
  int contentLength = 0;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.forEach(_body.add);
  }

  @override
  void write(Object? obj) => _body.add(utf8.encode('$obj'));
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _body.add(utf8.encode(objects.join(separator)));
  @override
  void writeCharCode(int charCode) => _body.add([charCode]);
  @override
  void writeln([Object? obj = '']) => _body.add(utf8.encode('$obj\n'));

  @override
  Future<HttpClientResponse> close() async {
    final body = utf8.decode(_body.takeBytes(), allowMalformed: true);
    _recorded.add(_Req(method, requestUri, body));
    return _FakeHttpResponse(utf8.encode(jsonEncode(_router(requestUri))));
  }

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
// 播放器通道 mock + 登录态 mock
// ---------------------------------------------------------------------------

void _installMocks(WidgetTester tester) {
  HttpOverrides.global = _FakeHttpOverrides();
  addTearDown(() => HttpOverrides.global = null);

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
      onListen: (arguments, events) {
        eventSink = events;
      },
    ),
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'), null));

  // secure storage：登录态 + csrf 都在（写操作才走得通）
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        const store = {
          'bili_sessdata': '100%2C9999999999%2Cabcdef',
          'bili_jct': _kJct,
        };
        return store[args['key'] as String?];
      default:
        return null;
    }
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), null));
}

// ---------------------------------------------------------------------------
// 助手
// ---------------------------------------------------------------------------

Future<void> _pumpPlayer(WidgetTester tester, {int? epId}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video(epId: epId))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 点一个按钮并把在飞的请求走完（显式 pump，不用 pumpAndSettle）。
Future<void> _tapAndSettle(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

List<_Req> _writes(String path) =>
    _recorded.where((r) => r.method == 'POST' && r.uri.path.endsWith(path)).toList();

void main() {
  setUp(() {
    MotionControl.enabled = false;
    SharedPreferences.setMockInitialValues({});
    _recorded.clear();
    _overrideHandlers = {};
    _reqUser = null;
    _writeFailures = {};
    // 每条用例换一个 bvid，隔离 player_page 的会话内全局缓存（见 _bvid 注释）
    _bvid = 'BV1WRITE${1000 + _bvidSeq++}';
    // 默认：总开关**关**（与产品默认一致）
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: false, loaded: true);
  });

  tearDown(() {
    MotionControl.reset();
    UiPrefsStore.instance.resetForTest(loaded: false);
    HttpOverrides.global = null;
  });

  // -------------------------------------------------------------------------
  // 总开关
  // -------------------------------------------------------------------------

  testWidgets('总开关默认关：播放页一个写操作按钮都不构建', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);

    await _pumpPlayer(tester);

    expect(UiPrefsStore.instance.writeActionsEnabled, isFalse, reason: '默认关');
    expect(find.byKey(_kWriteRow), findsNothing);
    expect(find.byKey(_kLike), findsNothing);
    expect(find.text('点赞'), findsNothing);
  });

  testWidgets('总开关打开：三个按钮出现，点赞数按万格式化', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.byKey(_kWriteRow), findsOneWidget);
    expect(find.byKey(_kLike), findsOneWidget);
    expect(find.byKey(_kCoin), findsOneWidget);
    expect(find.byKey(_kFav), findsOneWidget);
    // stat.like = 12345 → 1.2万
    expect(find.text('点赞 1.2万'), findsOneWidget);
    expect(find.text('投币'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
  });

  testWidgets('番剧集（epId != null）：总开关打开也不显示写操作行', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester, epId: 5555);

    expect(find.byKey(_kWriteRow), findsNothing,
        reason: 'pgc 的点赞/投币是另一套 ep_id 接口，本版只接普通视频');
  });

  // -------------------------------------------------------------------------
  // 点赞初始态
  // -------------------------------------------------------------------------

  testWidgets('req_user.like=1 → 初始显示「已赞」（真实初始态）', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 1, 'coin': 0, 'favorite': 0};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.text('已赞 1.2万'), findsOneWidget);
    expect(find.byKey(_kStateUnknown), findsNothing,
        reason: '拿到了真实的 req_user，不需要降级标注');
  });

  testWidgets('没有 req_user（未登录/接口没下发）→ 降级为会话内乐观态 + 如实标注',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = null;
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.text('点赞 1.2万'), findsOneWidget, reason: '按键存在（带计数）');
    expect(find.byKey(_kStateUnknown), findsOneWidget);
    expect(find.text('状态未取到，重启后可能显示不准'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // v2.41.0：archive/relation 给的真实互动态（view 不下发 req_user 的补丁）
  // -------------------------------------------------------------------------

  /// 让 relation 接口返回给定的 `data`（null = 返回空 data，即"没回答"）。
  void stubRelation(Map<String, dynamic>? data) {
    _overrideHandlers[_kRelationPath] =
        () => {'code': 0, 'data': data ?? <String, dynamic>{}};
  }

  testWidgets('拿到 relation → 三个按钮显示真实态，且**去掉**降级标注',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = null; // view 照旧不下发 req_user（现实就是这样）
    stubRelation({'like': true, 'coin': 0, 'favorite': true});
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.text('已赞 1.2万'), findsOneWidget, reason: 'relation.like=1 → 已赞');
    expect(find.text('收藏'), findsNothing);
    expect(find.text('已收藏'), findsOneWidget, reason: 'relation.fav=true → 已收藏');
    expect(find.text('投币'), findsOneWidget, reason: '没投过');
    expect(find.byKey(_kStateUnknown), findsNothing,
        reason: '拿到真实互动态 → 那句"状态未取到"必须消失');
    // 真的打了 relation 接口（不是靠猜）
    expect(_recorded.any((r) => r.uri.path.endsWith(_kRelationPath)), isTrue);
    expect(_writes(_kLikePath), isEmpty, reason: '只读探针，一个写请求都不许发');
  });

  testWidgets('relation 只给了 like 字段 → 该字段真、另两个按未做处理（仍算"取到了"）',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = null;
    stubRelation({'like': 1});
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.text('已赞 1.2万'), findsOneWidget);
    expect(find.byKey(_kStateUnknown), findsNothing,
        reason: '响应回答了互动态（有一个键在），就不算"没取到"');
  });

  testWidgets('relation 拿不到（未登录/失败/空 data）→ 保留降级标注', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = null;
    stubRelation(null); // data 是空的：接口没回答我的互动态
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.text('点赞 1.2万'), findsOneWidget, reason: '退回乐观起点（未赞）');
    expect(find.text('状态未取到，重启后可能显示不准'), findsOneWidget,
        reason: '拿不到就必须继续说真话');
  });

  testWidgets('relation 优先于 req_user（两个都给时以 relation 为准）', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0}; // view 说"没赞"
    stubRelation({'like': 1, 'coin': 0, 'favorite': 0}); // relation 说"赞了"
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.text('已赞 1.2万'), findsOneWidget,
        reason: 'relation 是专门回答这个问题的接口，优先于 view 顺带给的');
  });

  testWidgets('点赞成功后本地 relation 更新：同会话重进不再显示"未赞"',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = null;
    stubRelation({'like': false, 'coin': 0, 'favorite': false});
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    expect(find.text('点赞 1.2万'), findsOneWidget);

    await _tapAndSettle(tester, find.byKey(_kLike));
    expect(find.text('已赞 1.2万'), findsOneWidget);
    expect(_writes(_kLikePath), hasLength(1));

    // 同一条视频**再进一次**播放页：会话内缓存命中 → 不该再打 relation，
    // 也不该把刚点上的赞显示成"未赞"（_rememberWriteState 的回写）
    final relationHits =
        _recorded.where((r) => r.uri.path.endsWith(_kRelationPath)).length;
    await _pumpPlayer(tester);
    expect(find.text('已赞 1.2万'), findsOneWidget,
        reason: '本地 relation 已更新 → 重进显示已赞');
    expect(
      _recorded.where((r) => r.uri.path.endsWith(_kRelationPath)).length,
      relationHits,
      reason: '缓存命中：不重拉 relation（"不要每次重拉"）',
    );
  });

  // -------------------------------------------------------------------------
  // 点赞
  // -------------------------------------------------------------------------

  testWidgets('点赞成功：乐观切换为「已赞」+ 请求带 aid/like=1/csrf', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    expect(find.text('点赞 1.2万'), findsOneWidget);

    await _tapAndSettle(tester, find.byKey(_kLike));

    expect(find.text('已赞 1.2万'), findsOneWidget);
    final req = _writes(_kLikePath).single;
    // bvid 一起给（调用方本来就握着）：B 站 like 接口 aid/bvid 二者任选，
    // 多带一个是兼容性更稳
    expect(req.form, {
      'aid': '$_kAid',
      'bvid': _bvid,
      'like': '1',
      'csrf': _kJct,
    });
    expect(find.text('点赞 1.2万'), findsNothing, reason: '计数 +1');
  });

  testWidgets('点赞失败：界面回滚 + 错误提示条（关掉提示开关也挡不住）',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    _writeFailures[_kLikePath] = {'code': -509, 'message': '请求过于频繁'};
    // ★ 关掉「显示底部提示条」——错误类提示必须照样弹
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, showTips: false, loaded: true);

    await _pumpPlayer(tester);
    await _tapAndSettle(tester, find.byKey(_kLike));

    expect(find.text('点赞 1.2万'), findsOneWidget,
        reason: '失败必须回滚，不能留着"已赞"');
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('操作过于频繁'), findsOneWidget,
        reason: '写操作失败绝不能被"关提示"静默');
  });

  // -------------------------------------------------------------------------
  // 投币：二次确认
  // -------------------------------------------------------------------------

  testWidgets('投币：先弹确认框；点「取消」一个写请求都不发', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    await tester.tap(find.byKey(_kCoin));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('投 1 枚硬币？'), findsOneWidget);
    // 确认框必须把三件事说清（不可撤回 / 扣真硬币 / 会连带点赞）
    expect(find.textContaining('不支持撤回'), findsOneWidget);
    expect(find.textContaining('真实扣除'), findsOneWidget);
    expect(find.textContaining('同时给这个视频点赞'), findsOneWidget);

    await tester.tap(find.text('取消'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(_writes(_kCoinPath), isEmpty, reason: '取消 = 不发请求');
    expect(find.text('投币'), findsOneWidget, reason: '按钮状态不变');
  });

  testWidgets('投币确认：发 coin/add（multiply=1 + select_like=1）→ 变「已投币」',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    await tester.tap(find.byKey(_kCoin));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(_kCoinConfirm));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    final req = _writes(_kCoinPath).single;
    expect(req.form, {
      'aid': '$_kAid',
      'multiply': '1',
      'select_like': '1',
      'csrf': _kJct,
    });
    expect(find.text('已投币'), findsOneWidget);
    expect(find.text('已赞 1.2万'), findsOneWidget,
        reason: 'select_like=1 会连带点赞，界面跟着走');
  });

  // -------------------------------------------------------------------------
  // 收藏
  // -------------------------------------------------------------------------

  testWidgets('收藏：弹收藏夹列表（上次选的排第一）→ 选中走 add_media_ids + 记住 fid',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    // 上次收进过「音乐」（222）→ 它应排在第一个并标「上次」
    UiPrefsStore.instance.resetForTest(
        writeActionsEnabled: true, favFolderId: 222, loaded: true);

    await _pumpPlayer(tester);
    await tester.tap(find.byKey(_kFav));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.text('收藏到'), findsOneWidget);
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('默认收藏夹'), findsOneWidget);
    expect(find.text('上次'), findsOneWidget, reason: '上次选的夹有标记');

    await tester.tap(find.byKey(const ValueKey('fav-folder-222')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    final req = _writes(_kFavDealPath).single;
    expect(req.form, {
      'rid': '$_kAid',
      'type': '2',
      'add_media_ids': '222',
      'del_media_ids': '',
      'csrf': _kJct,
    });
    expect(find.text('已收藏'), findsOneWidget);
    expect(UiPrefsStore.instance.favFolderId, 222, reason: '记住本次选的夹');
  });

  testWidgets('已收藏（req_user.favorite=1）→ 点收藏走 del_media_ids', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 1};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    expect(find.text('已收藏'), findsOneWidget);

    await tester.tap(find.byKey(_kFav));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('从哪个收藏夹移除'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fav-folder-111')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    final req = _writes(_kFavDealPath).single;
    expect(req.form['del_media_ids'], '111');
    expect(req.form['add_media_ids'], '');
    expect(find.text('收藏'), findsOneWidget, reason: '移除后回到未收藏态');
  });

  testWidgets('收藏夹弹层取消（点遮罩关闭）→ 不发任何请求', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    await tester.tap(find.byKey(_kFav));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('收藏到'), findsOneWidget);

    // 点弹层左上角（遮罩区）关闭
    await tester.tapAt(const Offset(10, 10));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(_writes(_kFavDealPath), isEmpty);
    expect(find.text('收藏'), findsOneWidget);
  });

  testWidgets('收藏夹列表拉取失败（未登录）→ 错误提示条 + 不发收藏请求',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester);
    _reqUser = {'like': 0, 'coin': 0, 'favorite': 0};
    _overrideHandlers[_kFavListPath] = () =>
        {'code': -101, 'message': '账号未登录'};
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    await _tapAndSettle(tester, find.byKey(_kFav));

    expect(_writes(_kFavDealPath), isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('收藏夹列表获取失败'), findsOneWidget);
  });
}
