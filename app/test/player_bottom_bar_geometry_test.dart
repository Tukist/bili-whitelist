// 播放页底栏绝对几何断言（v2.39.0 新增）widget + 纯函数测试。
//
// 背景（用户原话）：「现在视频播放窗口下方的功能栏太高。ui美术，比例需要改进」
// ——底栏是**叠在视频区里**的（Stack 上层），所以要真正确认「收矮了 8dp 且没有
// 收过头」，必须量绝对高度。改动前整个仓库**没有任何测试断言底栏绝对高度**
// （只有「视频区底部 == 信息行顶部」这类相对关系），所以这里补上：
//
// 1. 纯函数：底栏总高 [kPlayerBottomBarHeight] = 80（进度条行 40 + 按钮行 40），
//    上下集行 40 单独算；字幕悬浮基准 [subtitleBottomOffset] 与控制行高度的
//    关系（可见态的间隙恒为全屏 30 / 非全屏 12）——即「字幕基准与播放器几何
//    一致」。字幕文本要在 widget 层真拉到字幕才出现（要跑通字幕接口 + 切轨道），
//    代价与脆弱度都高于直接测这条几何关系，故走纯函数。
// 2. widget：竖屏 411×914（与真机 Pixel 7 逻辑尺寸同档）下量三行与合计——
//    无播放列表 80、有播放列表 120；进度条行 40、上下集行 40；且底栏**整体落
//    在视频区内底边**（证明「收矮只多露画面、不动视频区几何」）。
//
// 环境：mock 播放器通道（setDataSource → onPrepared）+ 假 HTTP（playurl 给
// DASH 双流，走正常播放态而不是错误态）+ 内存 DownloadManager 替身。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/playlist_context.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvid = 'BV1GEOM00001';
const String _kBvid2 = 'BV1GEOM00002';

const Key _kVideoArea = ValueKey('player-video-area');
const Key _kBottomBar = ValueKey('player-bottom-bar');
const Key _kSeekBar = ValueKey('player-seek-bar');
const Key _kPlaylistRowKey = ValueKey('player-playlist-row');

/// 设计值（与 `_kBottomButtonRowHeight` / `_PlayerSeekBar.height`
/// 同源，这里**写字面量**才是有效断言：拿常量比自己会变成恒真）。
const double _kSeekRow = 40;
const double _kButtonRow = 40;
const double _kPlaylistRow = 40;
const double _kBarTotal = 80;
const double _kBarTotalWithPlaylist = 120;

WhitelistVideo _video(String bvid, String title) => WhitelistVideo(
      bvid: bvid,
      cid: 1001,
      title: title,
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 内存版 DownloadManager（不读真文件：FakeAsync 下真实 IO 永不完成）。
class _FakeManager extends DownloadManager {
  _FakeManager() {
    cached.value = const [];
  }
}

// ---- 假 HTTP：playurl 给 DASH 双流（走正常播放态）----

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
      _FakeHttpResponse(_route(requestUri));

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

Map<String, dynamic> _route(Uri uri) {
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
        'title': '底栏几何测试视频',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '',
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
        'dash': {
          'video': [{'baseUrl': 'https://x.bilivideo.com/v.m4s'}],
          'audio': [{'baseUrl': 'https://x.bilivideo.com/a.m4s'}],
        },
      },
    };
  }
  return {'code': 0, 'data': {}};
}

void _installMocks(WidgetTester tester) {
  MockStreamHandlerEventSink? sink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      switch (call.method) {
        case 'create':
          return 1;
        case 'getPosition':
          return 0;
        case 'setDataSource':
          final map = call.arguments as Map;
          sink?.success({
            'event': 'onPrepared',
            'textureId': map['textureId'],
            'width': 1280,
            'height': 720,
            'durationMs': 200000,
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

/// 起播到就绪（`_init` 里两个 500ms 超时兜底必须被 FakeAsync 推过去）。
Future<void> _pumpPlayer(
  WidgetTester tester,
  WhitelistVideo video, {
  PlaylistContext? playlist,
  int playlistIndex = 0,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PlayerPage(
      video: video,
      playlist: playlist,
      playlistIndex: playlistIndex,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('底栏几何（纯函数 / 常量）', () {
    test('底栏总高 = 进度条行 40 + 按钮行 40 = 80；上下集行 40 不计入', () {
      expect(kPlayerBottomBarHeight, _kBarTotal,
          reason: 'v2.39.0：两行各 44 → 40（改动前合计 88）');
      expect(kPlayerBottomBarHeight, _kSeekRow + _kButtonRow,
          reason: '总高必须由两行推导（字幕基准挂在它上面）');
      expect(kPlayerBottomBarHeight + _kPlaylistRow, _kBarTotalWithPlaylist,
          reason: '有上下集行时底栏合计 120（改动前 128，让出 8dp 画面）');
    });

    test('字幕基准 = 控制行高度 + 定值间隙（可见态）；隐藏态不随控制行变', () {
      // 控制层可见：抬到控制行之上
      expect(
        subtitleBottomOffset(fullscreen: true, controlsVisible: true),
        _kBarTotal + 30,
        reason: '全屏可见 = 80 + 30 = 110（改动前 118，间隙 30 不变）',
      );
      expect(
        subtitleBottomOffset(fullscreen: false, controlsVisible: true),
        _kBarTotal + 12,
        reason: '非全屏可见 = 80 + 12 = 92（改动前 100，间隙 12 不变）',
      );
      // 显式钉住字面量：改成别的数就说明观感基准被动了，必须有意识
      expect(subtitleBottomOffset(fullscreen: true, controlsVisible: true), 110);
      expect(subtitleBottomOffset(fullscreen: false, controlsVisible: true), 92);
      // 控制层隐藏（沉浸观影）：贴画面底部，与控制行高度无关
      expect(subtitleBottomOffset(fullscreen: true, controlsVisible: false), 24);
      expect(subtitleBottomOffset(fullscreen: false, controlsVisible: false), 16);
    });
  });

  testWidgets('竖屏无播放列表：底栏高 80（40 + 40），贴在视频区内底边', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    _installMocks(tester);
    DownloadManager.debugOverride(_FakeManager());

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, _video(_kBvid, '底栏几何'));

    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    final barRect = tester.getRect(find.byKey(_kBottomBar));
    expect(find.byKey(_kPlaylistRowKey), findsNothing, reason: '无播放列表');
    expect(barRect.height, _kBarTotal,
        reason: '底栏合计 80（进度条行 40 + 按钮行 40）');
    expect(tester.getRect(find.byKey(_kSeekBar)).height, _kSeekRow,
        reason: '进度条行 40（v2.39.0 由 44 收矮）');
    // 按钮行 = 合计 - 进度条行（按钮行自身没有 key，用差值得出）
    expect(barRect.height - tester.getRect(find.byKey(_kSeekBar)).height,
        _kButtonRow,
        reason: '按钮行 40（8 个按钮的竖排单元实测 36.2，余量 3.8）');
    // 底栏叠在视频区里：底边与视频区底边重合，顶边 = 视频区底 - 80
    expect(barRect.bottom, closeTo(videoRect.bottom, 0.5),
        reason: '底栏贴视频区内底边（画面区没被撑高）');
    expect(barRect.top, closeTo(videoRect.bottom - _kBarTotal, 0.5));
    expect(barRect.height, lessThan(videoRect.height),
        reason: '底栏是叠层，不是把视频区顶高');
  });

  testWidgets('竖屏有播放列表：底栏高 120（40 + 40 + 40），三行顺序自上而下', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    _installMocks(tester);
    DownloadManager.debugOverride(_FakeManager());

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    final a = _video(_kBvid, '底栏几何');
    final b = _video(_kBvid2, '底栏几何 2');
    await _pumpPlayer(
      tester,
      a,
      playlist: PlaylistContext(videos: [a, b], label: '测试合集'),
      playlistIndex: 0,
    );

    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    final barRect = tester.getRect(find.byKey(_kBottomBar));
    final playlistRect = tester.getRect(find.byKey(_kPlaylistRowKey));
    final seekRect = tester.getRect(find.byKey(_kSeekBar));

    expect(barRect.height, _kBarTotalWithPlaylist,
        reason: '底栏合计 120（上下集行 40 + 进度条行 40 + 按钮行 40）');
    expect(playlistRect.height, _kPlaylistRow, reason: '上下集行 40（未改动）');
    expect(seekRect.height, _kSeekRow, reason: '进度条行 40');
    expect(playlistRect.top, closeTo(barRect.top, 0.5), reason: '上下集行在底栏最上');
    expect(seekRect.top, closeTo(playlistRect.bottom, 0.5),
        reason: '进度条行紧接其下（顺序未变）');
    expect(barRect.bottom, closeTo(videoRect.bottom, 0.5));
    expect(barRect.top, closeTo(videoRect.bottom - _kBarTotalWithPlaylist, 0.5));
  });
}
