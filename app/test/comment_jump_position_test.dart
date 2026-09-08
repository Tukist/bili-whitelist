// 评论链接 ?p/?t 跳转的「定位 seek」widget 测试（v2.17.6+）。
//
// 独立文件原因：测试要 mock **EventChannel（bili_dash_player/events）触发原生
// onPrepared**，让播放器进入 loaded 态——onPrepared 只在播放器真正就绪后由原生
// 推送，mock 需在首个播放器创建前挂好。flutter test 每个文件独立 isolate，
// BiliDashPlayer._sharedRawEvents 静态缓存不会跨文件串扰（同文件多用例会串，
// 故本文件核心断言收在一个 testWidgets 里分阶段跑）。
//
// 覆盖（定位证据 = 播放器 MethodChannel 收到的 seekTo 目标）：
// - PlayerPage.initialPositionMs>0：onPrepared 后 **seekTo(指定位置)** 且**覆盖**
//   同集记忆进度（预置记忆 20s，入参 120s → seek 120s 而非 20s，无「已从上次
//   继续」SnackBar——定位语义优先）；
// - 同 bvid 链接带 ?p(异分P)+t：本页切集后 onPrepared seekTo(t)（_switchToPage
//   seekMs 覆盖该集记忆）；
// - 同 bvid 同集带 t（播放器已就绪）：直接 seekTo(t)（不叠页）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

/// 测试视频 A：多 P（两集），onPrepared 模拟时长 200s。
const String kVideoA = 'BV1AAAA11111';

WhitelistVideo _videoAMulti() => const WhitelistVideo(
      bvid: kVideoA,
      cid: 1001,
      title: '视频A',
      cover: '',
      duration: 200,
      upName: 'upA',
      addedAt: '2026-01-01',
      pages: [
        PageInfo(cid: 1001, part: '第1集', duration: 200),
        PageInfo(cid: 1002, part: '第2集', duration: 200),
      ],
    );

// ---- 按路径路由的 HTTP fake（view/playurl/nav/spi/reply 均返回合法体）-----

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

  Stream<Uint8List>? get handle =>
      Stream<Uint8List>.fromIterable([Uint8List.fromList(utf8.encode(jsonEncode(body)))]);

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
      handle!.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

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
          'img_url': 'https://i0.hdslb.com/bfs/wbi/11a8a4f1a25f41b4e05e02d6f2b4b3a3.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/0e146c531c4e43e20a7cfb1a3d4f5a5b.png',
        },
      },
    };
  }
  if (path.endsWith('/x/web-interface/view')) {
    return {
      'code': 0,
      'data': {
        'bvid': kVideoA,
        'aid': 1001,
        'cid': 1001,
        'title': '视频A',
        'pic': '',
        'duration': 200,
        'owner': {'name': 'upA'},
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '第1集', 'duration': 200},
          {'cid': 1002, 'part': '第2集', 'duration': 200},
        ],
      },
    };
  }
  if (path.endsWith('/x/v2/reply/main')) {
    return {'code': 0, 'data': {'replies': [], 'top_replies': [], 'cursor': {'is_end': true}}};
  }
  if (path.contains('playurl')) {
    return {
      'code': 0,
      'data': {
        'quality': 80,
        'wbi_img': {
          'img_url': 'https://i0.hdslb.com/bfs/wbi/11a8a4f1a25f41b4e05e02d6f2b4b3a3.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/0e146c531c4e43e20a7cfb1a3d4f5a5b.png',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initialPositionMs 覆盖记忆进度 + 同 bvid 带参本页跳（定位 seek 证据）',
      (tester) async {
    // 预置第 1 集记忆进度 20s（验证入参 120s 覆盖它而不是恢复 20s）
    SharedPreferences.setMockInitialValues({
      'playback_progress:BV1AAAA11111_0': '{"positionMs": 20000}',
      'playback_progress:BV1AAAA11111_1': '{"positionMs": 8000}',
    });
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);

    // 播放器通道：create → 自增 id；setDataSource → 触发 onPrepared（模拟原生
    // 就绪）；seekTo 把目标记成 'seekTo:<ms>'（便于断言定位目标），其余只记名
    final calls = <String>[];
    var texId = 0;
    MockStreamHandlerEventSink? eventSink;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        if (call.method == 'create') return ++texId;
        if (call.method == 'seekTo') {
          final map = call.arguments as Map;
          calls.add('seekTo:${map['positionMs']}');
          return null;
        }
        calls.add(call.method);
        if (call.method == 'setDataSource') {
          final map = call.arguments as Map;
          // 原生就绪回调：模拟 onPrepared（时长 200s，纹理为该播放器）
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

    // EventChannel：播放器事件流（首个播放器创建前挂好）
    tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'),
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          eventSink = events;
        },
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
          const EventChannel('bili_dash_player/events'),
          null));

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );

    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _videoAMulti(), initialPositionMs: 120000),
    ));
    await tester.pumpAndSettle();

    // ① initialPositionMs=120s 覆盖记忆 20s：seekTo 120000（而非 20000）
    expect(calls, contains('seekTo:120000'), reason: '?t=120s → 首次定位 120s'
        '（覆盖预置记忆 20s，链接定位优先）');
    expect(calls.contains('seekTo:20000'), isFalse,
        reason: '不应恢复记忆进度 20s');

    // ② 同 bvid 链接带 ?p=2 + t=30s：本页切集后定位 30s（覆盖第 2 集记忆 8s）
    final state = tester.state(find.byType(PlayerPage)) as dynamic;
    state.openVideoInNewPlayer(_videoAMulti(), pageIndex: 1, positionMs: 30000);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsOneWidget, reason: '同 bvid 不叠页');
    expect(calls, contains('seekTo:30000'),
        reason: '同 bvid 切第 2 集后按 ?t=30s 定位（覆盖该集记忆 8s）');

    // ③ 同 bvid 同集带 t=45s（当前第 2 集，播放器已就绪）→ 直接 seek 45s
    state.openVideoInNewPlayer(_videoAMulti(), positionMs: 45000);
    await tester.pumpAndSettle();
    expect(calls, contains('seekTo:45000'),
        reason: '同集带 t=45s → 播放器就绪时直接 seek 定位');
    expect(find.byType(PlayerPage), findsOneWidget);
  });
}
