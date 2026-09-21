// v2.39.0「本地缓存 ⇄ 网络流」播放源切换 widget 测试。
//
// 背景（用户原话）：「当我缓存了一个视频的音频的时候，我就没法观看视频画面
// 了。也就是说我需要一个切换本地播放和流媒体播放的东西」——仅音频缓存时本地
// 源物理上没有视频轨，缓存命中就无条件走本地 → 永远看不到画面。本文件覆盖：
// 1. 整段缓存：默认走本地（与改动前一致）→ 菜单切网络 → 通道收到 http(s) URL；
// 2. 仅音频缓存：切网络 → 收到 http URL 且「仅缓存音频」占位层消失（能看画面）；
// 3. 进度无缝：切源前取 getPosition 真值，带进新源的 setDataSource(positionMs:)
//    （断言 positionMs，不是从 0 重放）；
// 4. 失败回退：playurl 被限流（-352）→ 回到本地源 + SnackBar 提示，且**源字段
//    真回退了**（再开菜单文案是「切到网络流播放」而不是「切回本地」）。
//
// 「仅音频离线播放契约」（离线页点仅音频条目 → 音频文件当 videoUrl 传）的既有
// 用例在 offline_page_test.dart，本文件不复制、只保证它继续绿。
//
// 环境约束（与既有 player_* 测试同款）：播放器通道 + EventChannel 手工 mock
// （setDataSource 立即回 onPrepared）；HTTP 用假 HttpClient 按路径路由（避免
// 真实 socket 挂在 FakeAsync 里）；DownloadManager 用内存替身（真实现要读真文件，
// FakeAsync 里真实 IO 永不完成）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvidFull = 'BV1SRC00001'; // 整段缓存（视频+音频）
const String _kBvidAudio = 'BV1SRC00002'; // 仅音频缓存

/// 原生侧「当前播放位置」——切源时必须原样带进新源。
const int _kResumeMs = 42000;

WhitelistVideo _video(String bvid, String title) => WhitelistVideo(
      bvid: bvid,
      cid: 1001,
      title: title,
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

CachedVideo _cached(String bvid, {bool audioOnly = false}) => CachedVideo(
      bvid: bvid,
      title: bvid,
      cover: '',
      pageIndex: 0,
      partTitle: '',
      videoPath: audioOnly ? '' : 'C:/cache/${bvid}_p1.m4s',
      audioPath: 'C:/cache/${bvid}_p1.audio.m4s',
      sizeBytes: 1024,
      cachedAt: DateTime(2026, 1, 1),
      upName: '测试UP主',
      cid: 1001,
      durationMs: 600000,
      audioOnly: audioOnly,
    );

/// 内存版 DownloadManager（零真实 IO，理由见文件头）。
class _FakeManager extends DownloadManager {
  _FakeManager(List<CachedVideo> items) {
    cached.value = List.unmodifiable(items);
  }
}

// ---- 按路径路由的 HTTP fake（playurl 可切换为「被限流」）----

class _Http {
  _Http(this.state);

  final _HttpState state;

  static void install(_HttpState state, WidgetTester tester) {
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(state);
    addTearDown(() => HttpOverrides.global = old);
  }
}

class _HttpState {
  /// true → playurl 返回 -352（软风控/限流），用于验收「失败回退」。
  bool playurlThrottled = false;
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides(this.state);

  final _HttpState state;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(state);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.state);

  final _HttpState state;

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
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url, state);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest(url, state);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.requestUri, this.state);

  final Uri requestUri;
  final _HttpState state;
  final List<int> _body = [];

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
      _FakeHttpResponse(_route(requestUri, state));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  _FakeHttpResponse(this.body);

  final Map<String, dynamic> body;

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

  Stream<List<int>> get handle =>
      Stream<List<int>>.fromIterable([utf8.encode(jsonEncode(body))]);

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

Map<String, dynamic> _route(Uri uri, _HttpState state) {
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
        'bvid': _kBvidFull,
        'aid': 1001,
        'cid': 1001,
        'title': '播放源切换测试',
        'pic': '',
        'duration': 600,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '',
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '', 'duration': 600},
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
    if (state.playurlThrottled) {
      // -352 = 接口被限流（软风控）：_switchPlaySource 必须走失败回退分支
      return {'code': -352, 'message': '接口被限流，请稍后重试'};
    }
    return {
      'code': 0,
      'data': {
        'quality': 80,
        'dash': {
          'video': [{'baseUrl': 'https://x.bilivideo.com/v.m4s'}],
          'audio': [{'baseUrl': 'https://x.bilivideo.com/a.m4s'}],
        },
      },
    };
  }
  return {'code': 0, 'data': {}};
}

/// 记录原生 setDataSource 参数的替身通道。
class _PlayerRec {
  final List<Map<Object?, Object?>> dataSources = [];

  Map<Object?, Object?>? get last =>
      dataSources.isEmpty ? null : dataSources.last;

  String? get lastVideoUrl => last?['videoUrl'] as String?;
  String? get lastAudioUrl => last?['audioUrl'] as String?;
  int? get lastPositionMs => last?['positionMs'] as int?;
}

void _mockPlayerChannel(WidgetTester tester, _PlayerRec rec) {
  const textureId = 7;
  MockStreamHandlerEventSink? sink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      switch (call.method) {
        case 'create':
          return textureId;
        case 'getPosition':
          // 原生侧「当前播放位置」：切源用它定位（不是从 0 重放）
          return _kResumeMs;
        case 'setDataSource':
          final map = call.arguments as Map;
          rec.dataSources.add(map.cast<Object?, Object?>());
          sink?.success({
            'event': 'onPrepared',
            'textureId': map['textureId'],
            'width': 1280,
            'height': 720,
            'durationMs': 600000,
            'playWhenReady': true,
          });
        default:
          break;
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
        sink = events;
      },
    ),
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'), null));

  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
}

/// 打开缓存操作菜单：点底栏「已缓存」，等弹出动画。
Future<void> _openCacheMenu(WidgetTester tester) async {
  await tester.tap(find.text('已缓存'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 起播到「已就绪」：`_init` 里 `_downloads.init()` / `PlaybackProgress.load()`
/// 各带 500ms 超时兜底，FakeAsync 下必须把时间推过 500ms 才会走到取源。
Future<void> _pumpPlayerReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('整段缓存：默认本地 → 菜单切网络流 → 通道收到 http URL 且进度被带上',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = _HttpState();
    _Http.install(state, tester);
    final rec = _PlayerRec();
    _mockPlayerChannel(tester, rec);
    DownloadManager.debugOverride(_FakeManager([_cached(_kBvidFull)]));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video(_kBvidFull, '整段缓存视频')),
    ));
    await _pumpPlayerReady(tester);

    // 默认源 = 本地：首帧走的就是缓存文件（与改动前行为一致）
    expect(rec.dataSources, hasLength(1));
    expect(rec.lastVideoUrl, contains('${_kBvidFull}_p1.m4s'));
    expect(rec.lastVideoUrl, startsWith('file://'));
    expect(rec.lastAudioUrl, contains('${_kBvidFull}_p1.audio.m4s'));

    // 切网络流
    await _openCacheMenu(tester);
    expect(find.text('切到网络流播放（看画面/更高清晰度）'), findsOneWidget);
    await tester.tap(find.text('切到网络流播放（看画面/更高清晰度）'));
    await _pumpPlayerReady(tester);

    expect(rec.dataSources, hasLength(2), reason: '重新设源一次（不是从 0 起播）');
    expect(rec.lastVideoUrl, startsWith('https://'), reason: '网络流走 video 轨');
    expect(rec.lastAudioUrl, startsWith('https://'), reason: '网络流带 side audio');
    expect(rec.lastPositionMs, _kResumeMs,
        reason: '切源带当前进度（getPosition 真值），不是从 0 重放');
  });

  testWidgets('仅音频缓存：默认本地无画面 → 切网络流后占位层消失且拿到 http 视频流',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = _HttpState();
    _Http.install(state, tester);
    final rec = _PlayerRec();
    _mockPlayerChannel(tester, rec);
    DownloadManager.debugOverride(_FakeManager([
      _cached(_kBvidAudio, audioOnly: true),
    ]));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video(_kBvidAudio, '仅音频缓存视频')),
    ));
    await _pumpPlayerReady(tester);

    // 本地源 = 音频文件当 videoUrl（既有离线契约）+ 占位层出现（没有画面）
    expect(rec.lastVideoUrl, contains('${_kBvidAudio}_p1.audio.m4s'));
    expect(find.text('仅缓存了音频：无画面，可正常听声音'), findsOneWidget);

    // 菜单里明确提示「本地只有音频，要看画面得用网络流」
    await _openCacheMenu(tester);
    expect(find.text('本地只缓存了音频，要看画面得用网络流'), findsOneWidget);
    await tester.tap(find.text('切到网络流播放（看画面/更高清晰度）'));
    await _pumpPlayerReady(tester);

    expect(rec.lastVideoUrl, startsWith('https://'),
        reason: '网络流给的是 DASH 视频轨，画面才出得来');
    expect(rec.lastPositionMs, _kResumeMs);
    expect(find.text('仅缓存了音频：无画面，可正常听声音'), findsNothing,
        reason: '源有视频轨了 → 仅音频占位层必须复位（否则画面被它盖住）');
  });

  testWidgets('切网络失败（-352 限流）→ 回到本地源 + 提示，且源字段真回退',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final state = _HttpState()..playurlThrottled = true;
    _Http.install(state, tester);
    final rec = _PlayerRec();
    _mockPlayerChannel(tester, rec);
    DownloadManager.debugOverride(_FakeManager([_cached(_kBvidFull)]));

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video(_kBvidFull, '失败回退视频')),
    ));
    await _pumpPlayerReady(tester);
    expect(rec.dataSources, hasLength(1));

    await _openCacheMenu(tester);
    await tester.tap(find.text('切到网络流播放（看画面/更高清晰度）'));
    await _pumpPlayerReady(tester);

    // 回退：源字段回到 local **并且**重新装回本地文件（字段与实际播放一致）
    expect(rec.dataSources, hasLength(2), reason: '失败的源不留在通道上');
    expect(rec.lastVideoUrl, startsWith('file://'));
    expect(rec.lastVideoUrl, contains('${_kBvidFull}_p1.m4s'));
    expect(rec.lastPositionMs, _kResumeMs, reason: '回退也带进度，不会跳回 0');
    expect(find.text('网络取流失败，已回到本地缓存播放'), findsOneWidget,
        reason: '如实告知，不停在错误页');
    expect(find.textContaining('播放失败'), findsNothing);

    // 再开菜单：文案是「切到网络流播放」= 源字段确实回退了（不是只回退了播放器）
    await tester.pump(const Duration(milliseconds: 100));
    await _openCacheMenu(tester);
    expect(find.text('切到网络流播放（看画面/更高清晰度）'), findsOneWidget);
    expect(find.text('切回本地缓存播放（省流量/离线可用）'), findsNothing);
  });
}
