// v2.17.17「横屏置顶模式」播放页布局/方向策略 widget 测试。
//
// 覆盖（单 testWidgets 分阶段断言，避免同文件多用例串扰——BiliDashPlayer
// EventChannel 静态缓存跨用例残留，见 comment_jump_position_test.dart 说明）：
// - 竖屏进入播放 = 竖屏「顶部置顶视频 + 信息行 + 内嵌评论区」（v2.17.0 行为不变）；
// - 进全屏 = 锁横屏（platform 通道收到 landscapeLeft/Right 两向）且整屏视频
//   （无信息行/评论区）；
// - 横屏视图下退出全屏 = **不强制转竖屏**——方向放开为
//   portraitUp + landscapeLeft + landscapeRight 三向（设备横放即停在横屏），
//   布局自适应为横屏「置顶+评论」：视频区封顶屏高 55%、信息行紧凑、下方
//   评论区保留可见高度（整页不溢出）；
// - 旋转回竖屏 = 竖屏置顶+评论回归（视频区封顶 60%）；
// - 全屏中点返回箭头 = 先退出全屏（页面不离开、方向放开）；
// - 离开播放页（dispose）= 恢复系统竖屏 + edgeToEdge（现状保留）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/widgets/comment_list.dart';

/// 测试视频：单 P、带简介（信息行渲染标题/UP/时长/简介，验证紧凑逻辑）。
const String _kBvid = 'BV1LAND00001';

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '横屏置顶模式测试视频（v2.17.17）',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      desc: '这是一段视频简介，用于验证横屏下信息行紧凑（标题 1 行 / 简介少行）不撑爆布局。',
    );

// ---- 按路径路由的 HTTP fake（view/nav/spi/reply/playurl 均返回合法体）-----

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
  final Uri requestUri;
  final List<int> _body = [];
  _FakeHttpRequest(this.requestUri);

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
      _FakeHttpResponse(_router(requestUri));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  final Map<String, dynamic> body;
  _FakeHttpResponse(this.body);

  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => 0;
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

  Stream<List<int>> get handle => Stream<List<int>>.fromIterable(
      [utf8.encode(jsonEncode(body))]);

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
        'aid': 1001,
        'cid': 1001,
        'title': '横屏置顶模式测试视频（v2.17.17）',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '这是一段视频简介',
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
        'replies': [],
        'top_replies': [],
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
          'video': [{'baseUrl': 'https://x.bilivideo.com/v.m4s'}],
          'audio': [{'baseUrl': 'https://x.bilivideo.com/a.m4s'}],
        },
      },
    };
  }
  return {'code': 0, 'data': {}};
}

const Key _kVideoArea = ValueKey('player-video-area');
const Key _kInfoBar = ValueKey('player-info-bar');
const Key _kComments = ValueKey('player-comments');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('横屏置顶模式：退出全屏停在横屏+布局自适应 / 返回先退全屏 / dispose 恢复方向',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);

    // 播放器通道：create → 自增 id；setDataSource → 触发 onPrepared（模拟原生
    // 就绪，纹理 1280x720 → 16:9 与默认 _aspectRatio 一致，几何稳定）。
    final calls = <String>[];
    var texId = 0;
    MockStreamHandlerEventSink? eventSink;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        if (call.method == 'create') return ++texId;
        calls.add(call.method);
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
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );

    // 捕获 SystemChrome 方向/UI 模式调用：方向放开/锁定 = 本特性验收核心证据
    // （设备真实旋转交给模拟器实机；widget 测试用 physicalSize 模拟横竖屏）。
    final orientCalls = <List<String>>[];
    final uiModeCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientCalls.add(List<String>.from(call.arguments as List));
        } else if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          // 本版本实参为 String（mode.toString()，见 system_chrome.dart）
          uiModeCalls.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // 逻辑视口：dpr=1 → 竖屏 400x800 / 横屏 800x400。
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    // ① 竖屏进入播放 = 竖屏置顶+信息行+评论（v2.17.0 行为回归）
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    Rect videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.top, 0, reason: '非全屏视频区顶部置顶');
    // 16:9 → 理想高 400/16*9=225 < 屏高 60%（480）→ 225
    expect(videoRect.height, closeTo(225, 0.5));
    expect(find.byKey(_kInfoBar), findsOneWidget);
    expect(find.byType(CommentListView), findsOneWidget, reason: '竖屏内嵌评论区');
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);

    // ② 进全屏：锁横屏 + 整屏视频（无信息行/评论区）
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.height, closeTo(800, 0.5), reason: '全屏视频区占满整屏');
    expect(find.byKey(_kInfoBar), findsNothing);
    expect(find.byKey(_kComments), findsNothing);
    expect(orientCalls.last,
        ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
        reason: '进全屏锁横屏两向');

    // ③ 模拟设备横放（全屏保持整屏横屏）
    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.height, closeTo(400, 0.5), reason: '横屏全屏仍整屏');
    expect(find.byKey(_kInfoBar), findsNothing);

    // ④ 横屏下退出全屏 → 停在横屏「置顶+评论」：方向放开三向 + 布局自适应
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byIcon(Icons.fullscreen), findsOneWidget, reason: '已退出全屏');
    // 方向策略核心：不再强制竖屏，放开 portraitUp + landscape 两向（无 portraitDown）
    final exitOrient = orientCalls.last;
    expect(exitOrient.length, 3, reason: '退出全屏放开三向');
    expect(exitOrient, contains('DeviceOrientation.portraitUp'));
    expect(exitOrient, contains('DeviceOrientation.landscapeLeft'));
    expect(exitOrient, contains('DeviceOrientation.landscapeRight'));
    expect(exitOrient.where((o) => o.contains('portraitDown')), isEmpty);

    videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.top, 0);
    expect(videoRect.height, closeTo(400 * kLandscapeVideoHeightRatio, 0.5),
        reason: '横屏视频区封顶屏高 55%');
    final infoRect = tester.getRect(find.byKey(_kInfoBar));
    expect(infoRect.top, closeTo(videoRect.bottom, 0.5), reason: '信息行紧贴视频区下方');
    final commentsRect = tester.getRect(find.byType(CommentListView));
    expect(commentsRect.top, greaterThanOrEqualTo(infoRect.bottom - 0.5));
    expect(commentsRect.bottom, lessThanOrEqualTo(400.5),
        reason: '评论区不越出屏底（整页无溢出）');
    expect(commentsRect.height, greaterThan(0), reason: '横屏下方评论区保留可见高度');

    // ⑤ 转回竖屏（模拟器 rotation）→ 竖屏置顶+评论回归（兼容 v2.17.0）
    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.height, closeTo(225, 0.5), reason: '竖屏视频区封顶 60% 内（宽高比 225）');
    expect(tester.getRect(find.byKey(_kInfoBar)).top, closeTo(videoRect.bottom, 0.5));
    expect(find.byType(CommentListView), findsOneWidget);

    // ⑥ 全屏中点返回箭头 = 先退出全屏（页面不离开，方向放开）
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget, reason: '再次进全屏');
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(PlayerPage), findsOneWidget, reason: '返回先退全屏不离开页面');
    expect(find.byIcon(Icons.fullscreen), findsOneWidget, reason: '全屏已退出');
    final backOrient = orientCalls.last;
    expect(backOrient.length, 3, reason: '返回退全屏同样放开三向');
    videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(videoRect.height, closeTo(225, 0.5), reason: '退回竖屏置顶布局');

    // ⑦ 离开播放页（dispose）= 恢复系统竖屏 + edgeToEdge（现状保留）
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(orientCalls.last, ['DeviceOrientation.portraitUp'],
        reason: 'dispose 恢复系统竖屏基准');
    expect(uiModeCalls.last, 'SystemUiMode.edgeToEdge');
  });
}
