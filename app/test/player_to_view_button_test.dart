// 播放页写操作那排的「稍后再看」（v2.59.0+）widget 测试。
//
// 用户原话：「还有视频播放界面的那个收藏键也可以放入稍后再看。」
//
// 覆盖：
// - 总开关**关着**：整排不构建 → 这颗按钮也不存在（"关着 = 一个像素都不多"）；
// - 未登录（secure storage 读不到 SESSDATA）：列表接口在本地就被拦下 →
//   拿不到"在不在"这个答案 → **整颗不构建**（切换式按钮不能瞎猜方向）；
// - 已登录 + 总开关开：列表里没有这条 → 显示「稍后再看」；
// - 点它 → `toview/add`（bvid + aid + csrf）→ 立刻变「已加入」；
// - 再点 → `toview/del`（**只认 aid**）→ 回到「稍后再看」；
// - **同一会话只拉一次列表**：进页 / 加 / 移 / 再进页，GET `toview` 始终 1 次；
// - 加入失败：提示条给可读原因（90001 列表已满），按钮状态不变（不假装成功）；
// - 360dp 窄屏：四颗按钮一行放得下（不溢出、不裁字）。
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

String _bvid = 'BV1TOVIEW00';
int _bvidSeq = 0;
const int _kAid = 4004;
const String _kJct = 'jct-toview-test';

const Key _kToview = ValueKey('write-toview');
const Key _kWriteRow = ValueKey('player-write-actions');

const String _kToViewGetPath = '/x/v2/history/toview';
const String _kToViewAddPath = '/x/v2/history/toview/add';
const String _kToViewDelPath = '/x/v2/history/toview/del';

WhitelistVideo _video() => WhitelistVideo(
      bvid: _bvid,
      cid: 1001,
      title: '稍后再看按钮测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      desc: '一段简介，让信息块有内容。',
    );

// ---------------------------------------------------------------------------
// 记录型 HTTP fake
// ---------------------------------------------------------------------------

class _Req {
  _Req(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final String body;

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

/// 列表里已有的条目（bvid → aid）。空 = 账号那份稍后再看里没有本用例的视频。
Map<String, int> _listItems = {};

/// 服务端说的总数（null = 跟条目数一致）。用来验证"条数不参与按钮判断"。
int? _listCount;

/// 写接口失败注入（path → 完整响应体）。
Map<String, Map<String, dynamic>> _writeFailures = {};

/// 列表接口失败注入（null = 正常返回）。
Map<String, dynamic>? _listFailure;

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
        'title': '稍后再看按钮测试视频',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '一段简介，让信息块有内容。',
        'pubdate': 1700000000,
        'stat': {'like': 12, 'coin': 0, 'favorite': 0},
        'pages': [
          {'cid': 1001, 'part': '', 'duration': 200},
        ],
      },
    };
  }
  if (path.endsWith(_kToViewGetPath)) {
    final failure = _listFailure;
    if (failure != null) return failure;
    return {
      'code': 0,
      'data': {
        'count': _listCount ?? _listItems.length,
        'list': [
          for (final e in _listItems.entries)
            {
              'aid': e.value,
              'bvid': e.key,
              'cid': 1001,
              'title': '已在列表里的视频',
              'pic': '',
              'duration': 200,
              'progress': 0,
              'add_at': 1700000000,
              'owner': {'mid': 1, 'name': 'UP甲'},
              'page': {'cid': 1001, 'page': 1},
              'videos': 1,
            },
        ],
      },
    };
  }
  for (final p in [_kToViewAddPath, _kToViewDelPath]) {
    if (path.endsWith(p)) {
      return _writeFailures[p] ?? {'code': 0, 'data': null};
    }
  }
  if (path.endsWith('/x/v2/reply/main')) {
    return {
      'code': 0,
      'data': {
        'replies': <Map<String, dynamic>>[],
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

void _installMocks(WidgetTester tester, {required bool loggedIn}) {
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

  // secure storage：登录态 + csrf（loggedIn=false 时读什么都拿不到）
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        if (!loggedIn) return null;
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

Future<void> _pumpPlayer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _tapAndSettle(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 列表 GET 的真实请求次数（写接口不算）。
int _listGets() =>
    _recorded.where((r) => r.uri.path.endsWith(_kToViewGetPath)).length;

List<_Req> _writes(String path) => _recorded
    .where((r) => r.method == 'POST' && r.uri.path.endsWith(path))
    .toList();

void main() {
  setUp(() {
    MotionControl.enabled = false;
    SharedPreferences.setMockInitialValues({});
    _recorded.clear();
    _listItems = {};
    _listCount = null;
    _listFailure = null;
    _writeFailures = {};
    // 每条用例换一个 bvid：播放页的 view/relation 缓存是**按 bvid** 的库级
    // 缓存，换 bvid 天然隔离
    _bvid = 'BV1TOVIEW${100 + _bvidSeq++}';
    // 稍后再看列表缓存是**库级、与 bvid 无关**的（一次会话只拉一次）——
    // 必须显式复位，否则第一条用例拉过的结果会被后面所有用例命中
    debugResetToViewCacheForTest();
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: false, loaded: true);
  });

  tearDown(() {
    MotionControl.reset();
    UiPrefsStore.instance.resetForTest(loaded: false);
    HttpOverrides.global = null;
    debugResetToViewCacheForTest();
  });

  testWidgets('总开关关着：整排不构建，这颗按钮也不存在', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: true);

    await _pumpPlayer(tester);

    expect(find.byKey(_kWriteRow), findsNothing);
    expect(find.byKey(_kToview), findsNothing);
  });

  testWidgets('未登录：拿不到"在不在"的答案 → 不构建这颗按钮（不是画成未加入）',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: false);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.byKey(_kWriteRow), findsOneWidget,
        reason: '其余三个写操作按钮照旧（它们可以乐观起步）');
    expect(find.byKey(_kToview), findsNothing,
        reason: '切换式按钮在不知道方向时不能出现');
    expect(find.text('稍后再看'), findsNothing);
    expect(_recorded.where((r) => r.uri.path.endsWith(_kToViewGetPath)), isEmpty,
        reason: '未登录时接口在本地就拦下，一个请求都不发');
  });

  testWidgets('已登录 + 不在列表里 → 显示「稍后再看」；点它加入并立刻变「已加入」',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: true);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(find.byKey(_kToview), findsOneWidget);
    expect(find.text('稍后再看'), findsOneWidget);
    expect(find.text('已加入'), findsNothing);
    expect(_listGets(), 1, reason: '进播放页拉一次列表（仅一次）');

    await _tapAndSettle(tester, find.byKey(_kToview));

    final req = _writes(_kToViewAddPath).single;
    expect(req.form['bvid'], _bvid);
    expect(req.form['aid'], '$_kAid', reason: '播放页握着 aid 就顺手带上');
    expect(req.form['csrf'], _kJct);
    expect(find.text('已加入'), findsOneWidget, reason: '成功后按钮状态立刻变');
    expect(find.text('稍后再看'), findsNothing);
  });

  testWidgets('已在列表里 → 初始显示「已加入」；点它移除（del 只认 aid）→ 变回「稍后再看」',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: true);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);
    // 账号那份列表里已经有这条（aid 用列表给的，故意与 view 的 aid 不同，
    // 验证"移除用记录自己的 aid"）
    _listItems = {_bvid: 7777};

    await _pumpPlayer(tester);

    expect(find.text('已加入'), findsOneWidget);
    expect(find.text('稍后再看'), findsNothing);

    await _tapAndSettle(tester, find.byKey(_kToview));

    final req = _writes(_kToViewDelPath).single;
    expect(req.form, {'aid': '7777', 'csrf': _kJct},
        reason: 'del 只认 aid，且用列表条目自己的 aid');
    expect(find.text('稍后再看'), findsOneWidget);
    expect(find.text('已加入'), findsNothing);
  });

  testWidgets('同一会话只拉一次列表：进页 / 加 / 移 / 再进页，GET 始终 1 次',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: true);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);
    expect(_listGets(), 1);

    await _tapAndSettle(tester, find.byKey(_kToview)); // 加入
    await _tapAndSettle(tester, find.byKey(_kToview)); // 移出
    expect(_listGets(), 1, reason: '加入/移出后改缓存，不重拉列表');

    // 同一条视频再进一次播放页：缓存命中（加入又移出 → 最终"不在"）
    await _pumpPlayer(tester);
    expect(_listGets(), 1, reason: '重进播放页也不重拉（会话内缓存）');
    expect(find.text('稍后再看'), findsOneWidget);

    // 换一条视频（缓存是整份列表，与 bvid 无关 → 同样不重拉）
    _bvid = 'BV1TOVIEW999';
    await _pumpPlayer(tester);
    expect(_listGets(), 1);
    expect(find.byKey(_kToview), findsOneWidget);
  });

  testWidgets('加入失败（90001 列表已满）：错误提示条 + 按钮状态不变',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: true);
    // 关掉「显示底部提示条」——写操作失败的提示必须照样弹
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, showTips: false, loaded: true);
    _writeFailures[_kToViewAddPath] = {
      'code': 90001,
      'message': '稍后再看已满（上限 100 个视频），请先移除一些',
    };

    await _pumpPlayer(tester);
    await _tapAndSettle(tester, find.byKey(_kToview));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('已满'), findsOneWidget);
    expect(find.text('稍后再看'), findsOneWidget,
        reason: '没成功就不能显示"已加入"');
    expect(find.text('已加入'), findsNothing);
    expect(_listGets(), 1, reason: '失败也不重拉列表');
  });

  testWidgets('360dp 窄屏：四颗按钮（含「稍后再看」）不溢出、不裁字',
      (tester) async {
    // 360dp 是产品口径里的最小目标屏宽；测试字体（每字符 = 字号宽）比真机
    // 中文更宽，等于做最坏情况的宽度预算。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    _installMocks(tester, loggedIn: true);
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: true, loaded: true);

    await _pumpPlayer(tester);

    expect(tester.takeException(), isNull, reason: 'RenderFlex 溢出会在这里报出来');
    expect(find.byKey(_kToview), findsOneWidget);
    expect(find.text('稍后再看'), findsOneWidget);
    // 三颗老按钮一个不少（新按钮没把它们挤掉）
    expect(find.byKey(const ValueKey('write-like')), findsOneWidget);
    expect(find.byKey(const ValueKey('write-coin')), findsOneWidget);
    expect(find.byKey(const ValueKey('write-fav')), findsOneWidget);
  });
}
