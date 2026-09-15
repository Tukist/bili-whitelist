// 播放页「同合集上下集」widget 测试（v2.30.0+）。
//
// 覆盖：
//   1. 有播放列表且下标居中 → 底栏出现「上一集 / 下一集」，点下一集换到列表
//      里下一条（断言取流 setDataSource 的 title 与通知 updateNowPlaying 的
//      title 两处可观测点）；
//   2. **边界不循环也不外溢**：第 1 集「上一集」禁用、最后一集「下一集」禁用，
//      点禁用态无动作；
//   3. **不传播放列表 → 上下集行整行不构建**（findsNothing，既不是禁用也不是
//      灰色按钮），这是「不影响既有入口」的回归保护；
//   4. 播放列表只有一条 → 同「没有列表」处理（不出现两个死按钮）；
//   5. 切换后的状态复位：旧视频进度/历史落盘（key = bvid+pageIndex）、UP 信息
//      与弹幕按**新** bvid/cid 重拉、通知标题跟着换；
//   6. 邻居缺 cid（cid<=0）→ 先用 fetchVideoMeta 补齐再切；补不到 → 只提示
//      一句、**不动当前播放**；
//   7. 入口接线：合集页点单条视频 → PlayerPage.playlist 长度/顺序 = 合集列表
//      （sortedVideos 的 order 升序），playlistIndex = 被点下标；UP 主页同款。
//
// 测试环境（与 player_seek_preview_test.dart 同款骨架）：
// - mock 原生播放器 MethodChannel/EventChannel：create → textureId、
//   setDataSource → onPrepared（playWhenReady 默认 true）、getPosition 按
//   textureId **脚本化**返回（换源后是新 textureId，所以能分别给两段的
//   位置序列）；
// - mock bili_whitelist/media（亮度/音量基准）、SystemChannels.platform、
//   secure storage；
// - **HttpOverrides 按 URL 路由的假响应**：view / playurl / nav / 弹幕 / UP
//   主页各接口都返回构造好的 JSON，不发真实请求；每条请求的完整 URL 记进
//   [_FakeHttp.requests]，用 `bvid=` / `cid=` / `oid=` 断言「换的是哪一条」；
// - 一律显式 pump，不用 pumpAndSettle（播放页的缓冲转圈是无限动画）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/playlist_context.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/collection_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';

const String _kBvA = 'BV1PL0000001';
const String _kBvB = 'BV1PL0000002';
const String _kBvC = 'BV1PL0000003';

/// bvid → cid（view/playurl 按它生成；弹幕 oid 也是它）。
const Map<String, int> _kCids = {
  _kBvA: 1111,
  _kBvB: 2222,
  _kBvC: 3333,
};

/// bvid → 标题（取流/通知的可观测文案）。
const Map<String, String> _kTitles = {
  _kBvA: '视频A',
  _kBvB: '视频B',
  _kBvC: '视频C',
};

const Key _kPrevBtn = ValueKey('player-prev-video');
const Key _kNextBtn = ValueKey('player-next-video');
const Key _kPlaylistRow = ValueKey('player-playlist-row');

/// 视频区 / 中央播放键圆环（几何断言用；与 player_page.dart 里的字面量 key
/// 同一约定，见 `player-video-area` / `player-seek-bar`）。
const Key _kVideoArea = ValueKey('player-video-area');
const Key _kPlayGlyph = ValueKey('player-play-glyph');

WhitelistVideo _video(String bvid, {int? cid, String? title}) => WhitelistVideo(
  bvid: bvid,
  cid: cid ?? _kCids[bvid]!,
  title: title ?? _kTitles[bvid]!,
  cover: '',
  duration: 200,
  upName: '测试UP主',
  addedAt: '2026-01-01T00:00:00Z',
);

List<WhitelistVideo> _threeVideos() => [_video(_kBvA), _video(_kBvB), _video(_kBvC)];

// ---------------------------------------------------------------------------
// 假 HTTP：按 URL 路由出响应，并记录每条请求的完整 URL
// ---------------------------------------------------------------------------

const String _kDanmakuXml =
    '<?xml version="1.0"?><i><d p="1,1,25,16777215,0,0,0,0">测试弹幕</d></i>';

/// 置上后：该 bvid 的 view 接口返回业务错误码（测「邻居补不到元数据」）。
String? _failViewBvid;

/// 置上后：UP 主页多一个「精品合集」分区（测「合集分区点视频不接播放上下文」）。
bool _withSeason = false;

class _FakeHttp {
  final List<Uri> requests = [];

  bool has(String fragment) => requests.any((u) => u.toString().contains(fragment));

  int count(String fragment) =>
      requests.where((u) => u.toString().contains(fragment)).length;
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides(this.harness);

  final _FakeHttp harness;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(harness);
}

/// nav 用的 wbi key（与既有播放页测试同一份，只为让 WBI 签名走通）。
const Map<String, dynamic> _kWbiImg = {
  'img_url':
      'https://i0.hdslb.com/bfs/wbi/a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png',
  'sub_url':
      'https://i0.hdslb.com/bfs/wbi/e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png',
};

/// view 与 playurl 共用一份 data（两个解析各自取自己那几个字段）。
Map<String, dynamic> _mediaData(String bvid) {
  final cid = _kCids[bvid] ?? 999;
  return {
    'bvid': bvid,
    'aid': 1,
    'cid': cid,
    'title': _kTitles[bvid] ?? '未知视频',
    'pic': '',
    'duration': 200,
    'pubdate': 1700000000,
    'quality': 80,
    'wbi_img': _kWbiImg,
    'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
    'desc': '',
    'pages': [
      {'cid': cid, 'part': '', 'duration': 200},
    ],
    'dash': {
      'video': [
        {'baseUrl': 'https://x.bilivideo.com/$bvid.v.m4s', 'bandwidth': 1000},
      ],
      'audio': [
        {'baseUrl': 'https://x.bilivideo.com/$bvid.a.m4s', 'bandwidth': 128000},
      ],
    },
  };
}

/// UP 主页「全部视频」列表（两条，够验上下集）。
const String _kUpVlist = 'BV1UP0000001';
const String _kUpVlist2 = 'BV1UP0000002';

Map<String, dynamic> _upVideosBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'list': {
      'vlist': [
        for (final (i, bvid) in [_kUpVlist, _kUpVlist2].indexed)
          {
            'bvid': bvid,
            'title': '主页视频 ${i + 1}',
            'length': '3:20',
            'author': '测试UP主',
            'pic': '',
            'created': 1700000000 - i,
          },
      ],
    },
    'page': {'pn': 1, 'ps': 20, 'count': 2},
  },
};

/// 一条请求的响应：(状态码, content-type, body 字节)。
(int, String, List<int>) _responseFor(Uri url) {
  final path = url.path;
  final bvid = url.queryParameters['bvid'] ?? '';

  if (path.endsWith('/x/v1/dm/list.so')) {
    return (200, 'text/xml', utf8.encode(_kDanmakuXml));
  }
  if (path.endsWith('/x/frontend/finger/spi')) {
    return (
      200,
      'application/json',
      utf8.encode(
        jsonEncode({
          'code': 0,
          'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
        }),
      ),
    );
  }
  if (path.endsWith('/x/web-interface/nav')) {
    return (
      200,
      'application/json',
      utf8.encode(jsonEncode({'code': 0, 'data': {'wbi_img': _kWbiImg}})),
    );
  }
  if (path.endsWith('/x/space/wbi/acc/info')) {
    return (
      200,
      'application/json',
      utf8.encode(
        jsonEncode({
          'code': 0,
          'data': {'name': '测试UP主', 'face': '', 'sign': ''},
        }),
      ),
    );
  }
  if (path.endsWith('/x/relation/stat')) {
    return (
      200,
      'application/json',
      utf8.encode(
        jsonEncode({
          'code': 0,
          'data': {'mid': 100, 'follower': 100},
        }),
      ),
    );
  }
  if (path.endsWith('/x/space/wbi/arc/search')) {
    return (200, 'application/json', utf8.encode(jsonEncode(_upVideosBody())));
  }
  if (path.endsWith('/x/polymer/web-space/seasons_series_list')) {
    return (
      200,
      'application/json',
      utf8.encode(
        jsonEncode({
          'code': 0,
          'data': {
            'items_lists': {
              'page': {'page_num': 1, 'page_size': 20, 'total': 0},
              'seasons_list': _withSeason
                  ? [
                      {
                        'archives': <Map<String, dynamic>>[],
                        'meta': {
                          'season_id': 3993361,
                          'name': '精品合集',
                          'cover': '',
                          'description': '',
                          'total': 1,
                        },
                        'recent_aids': <int>[],
                      },
                    ]
                  : <Map<String, dynamic>>[],
              'series_list': <Map<String, dynamic>>[],
            },
          },
        }),
      ),
    );
  }
  // 合集分区的视频列表：故意给**同一个 bvid**（也出现在「全部视频」里），
  // 用来验「合集分区点视频不会拿全部视频列表当上下文」。
  if (path.endsWith('/x/polymer/web-space/seasons_archives_list')) {
    return (
      200,
      'application/json',
      utf8.encode(
        jsonEncode({
          'code': 0,
          'data': {
            'archives': [
              {
                'aid': 2,
                'bvid': _kUpVlist2,
                'title': '合集里的视频',
                'pic': '',
                'duration': 200,
                'pubdate': 1700000000,
              },
            ],
            'page': {'page_num': 1, 'page_size': 20, 'total': 1},
          },
        }),
      ),
    );
  }
  // view / playurl / videoshot / 其它：按 bvid 出元数据
  final fail = _failViewBvid;
  if (fail != null &&
      fail == bvid &&
      path.endsWith('/x/web-interface/view')) {
    return (
      200,
      'application/json',
      utf8.encode(jsonEncode({'code': -404, 'message': '啥都木有'})),
    );
  }
  return (
    200,
    'application/json',
    utf8.encode(jsonEncode({'code': 0, 'data': _mediaData(bvid)})),
  );
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.harness);

  final _FakeHttp harness;

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
      _FakeHttpRequest(harness, url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      openUrl('GET', Uri.parse('http://$host:$port$path'));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.harness, this.url);

  final _FakeHttp harness;
  final Uri url;

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
  Future<HttpClientResponse> close() async {
    harness.requests.add(url);
    final (status, contentType, body) = _responseFor(url);
    return _FakeHttpResponse(status, contentType, body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  _FakeHttpResponse(this._status, this._contentType, this._body);

  final int _status;
  final String _contentType;
  final List<int> _body;

  @override
  int get statusCode => _status;
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
    h.add('content-type', _contentType);
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
  }) => handle.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

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
// 原生播放器通道替身
// ---------------------------------------------------------------------------

class _PlayerRec {
  /// 每个 textureId 的位置脚本（按 tick 顺序依次取，用尽后固定取最后一个）。
  final Map<int, List<int>> positions = {};
  final Map<int, int> _posCalls = {};

  final List<Map<String, Object?>> setDataSources = [];
  final List<Map<String, Object?>> nowPlaying = [];
  final List<int> seeks = [];

  String lastTitle() => (setDataSources.last['title'] ?? '') as String;
  String lastNotifTitle() => (nowPlaying.last['title'] ?? '') as String;

  /// 原生 → Dart 的事件回推句柄（`_installMocks` 挂载时写入）。
  MockStreamHandlerEventSink? eventSink;

  /// 把一条原生事件推给 Dart（模拟通知栏 / 耳机按键触发的原生事件）。
  void emit(String event, {String? action, int positionMs = 0}) {
    eventSink?.success({
      'event': event,
      'textureId': _lastTextureId,
      if (action != null) 'action': action,
      'positionMs': positionMs,
    });
  }

  /// 最近一次取流用的 textureId（换集会换新 id，事件要跟着走）。
  int get _lastTextureId => (setDataSources.last['textureId'] as int?) ?? 1;

  int _tick(int textureId) {
    final script = positions[textureId];
    if (script == null || script.isEmpty) return 0;
    final n = _posCalls[textureId] ?? 0;
    _posCalls[textureId] = n + 1;
    return n < script.length ? script[n] : script.last;
  }
}

void _installMocks(WidgetTester tester, _PlayerRec rec) {
  var texSeq = 0;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'create':
          return ++texSeq;
        case 'setDataSource':
          final map = Map<String, Object?>.from(args);
          rec.setDataSources.add(map);
          rec.eventSink?.success({
            'event': 'onPrepared',
            'textureId': map['textureId'],
            'width': 1280,
            'height': 720,
            'durationMs': 200000,
            'playWhenReady': true,
          });
          return null;
        case 'getPosition':
          return rec._tick(args['textureId'] as int);
        case 'seekTo':
          rec.seeks.add(args['positionMs'] as int);
          return null;
        case 'updateNowPlaying':
          rec.nowPlaying.add(Map<String, Object?>.from(args));
          return null;
        default:
          return null;
      }
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      null,
    ),
  );

  tester.binding.defaultBinaryMessenger.setMockStreamHandler(
    const EventChannel('bili_dash_player/events'),
    MockStreamHandler.inline(
      onListen: (arguments, events) {
        rec.eventSink = events;
      },
    ),
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('bili_dash_player/events'),
      null,
    ),
  );

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_whitelist/media'),
    (call) async {
      switch (call.method) {
        case 'getBrightness':
          return 0.5;
        case 'getVolume':
          return <String, Object?>{'current': 5, 'max': 15};
        default:
          return null;
      }
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_whitelist/media'),
      null,
    ),
  );

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    ),
  );

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

/// 挂载播放页并等到取流 + onPrepared 完成（点上下集前必须先有播放器，
/// 否则按钮本就是禁用态、测不出东西）。
Future<void> _pumpPlayer(
  WidgetTester tester,
  WhitelistVideo video, {
  PlaylistContext? playlist,
  int playlistIndex = 0,
}) async {
  // 先卸一棵空树：同名 widget 会走 update 而不是 initState（同既有播放页测试）
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        video: video,
        playlist: playlist,
        playlistIndex: playlistIndex,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

/// 点某条请求已发出（含 await 链）后让异步落地。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

bool _enabled(WidgetTester tester, Key key) =>
    tester.widget<InkWell>(find.byKey(key)).onTap != null;

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.tap(find.byKey(key), warnIfMissed: false);
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHttp http;

  setUp(() {
    _failViewBvid = null;
    _withSeason = false;
    SharedPreferences.setMockInitialValues({});
    http = _FakeHttp();
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(http);
    addTearDown(() => HttpOverrides.global = old);
  });

  group('播放页：上下集入口与切换', () {
    testWidgets('有播放列表且居中 → 上一集/下一集都可用，点下一集换到下一条', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      rec.positions[1] = [30000]; // 旧视频的当前位置（切换前要落盘）
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[1],
        playlist: PlaylistContext(videos: videos, label: '合集'),
        playlistIndex: 1,
      );

      expect(find.byKey(_kPlaylistRow), findsOneWidget);
      expect(find.text('上一集'), findsOneWidget);
      expect(find.text('下一集'), findsOneWidget);
      expect(_enabled(tester, _kPrevBtn), isTrue);
      expect(_enabled(tester, _kNextBtn), isTrue);
      // 「合集 · 2/3」：上下文名 + 第几集/共几集
      expect(find.textContaining('2/3'), findsOneWidget);
      expect(rec.setDataSources.length, 1);
      expect(rec.lastTitle(), '视频B');

      await _tap(tester, _kNextBtn);

      // 换到下一条：取流与通知都跟着换成新视频
      expect(rec.setDataSources.length, 2, reason: '下一集要走一次新的取流');
      expect(rec.lastTitle(), '视频C');
      expect(rec.lastNotifTitle(), '视频C', reason: '通知栏标题要跟着换');
      expect(find.textContaining('3/3'), findsOneWidget, reason: '集号要跟着走');
      // 切换前先存了旧视频进度（key = bvid+pageIndex；旧视频的位置绝不能
      // 落到新视频的 key 上——见 _saveExitProgress 的注释）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('playback_progress:${_kBvB}_0'), isNotNull);
      expect(prefs.getString('playback_progress:${_kBvC}_0'), isNull);

      await _tap(tester, _kPrevBtn);
      expect(rec.lastTitle(), '视频B', reason: '上一集回到原来那一条');
    });

    testWidgets('第 1 集：上一集禁用（不越界），下一集可用', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[0],
        playlist: PlaylistContext(videos: videos),
        playlistIndex: 0,
      );

      expect(_enabled(tester, _kPrevBtn), isFalse);
      expect(_enabled(tester, _kNextBtn), isTrue);
      expect(find.textContaining('1/3'), findsOneWidget);

      final before = rec.setDataSources.length;
      await _tap(tester, _kPrevBtn);
      expect(rec.setDataSources.length, before, reason: '第 1 集没有「上一集」可去');
      expect(rec.lastTitle(), '视频A');
    });

    testWidgets('最后一集：下一集禁用（不循环回第一集）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[2],
        playlist: PlaylistContext(videos: videos),
        playlistIndex: 2,
      );

      expect(_enabled(tester, _kNextBtn), isFalse);
      expect(_enabled(tester, _kPrevBtn), isTrue);

      final before = rec.setDataSources.length;
      await _tap(tester, _kNextBtn);
      expect(
        rec.setDataSources.length,
        before,
        reason: '最后一集的「下一集」不循环回第一集',
      );
      expect(rec.lastTitle(), '视频C');

      await _tap(tester, _kPrevBtn);
      expect(rec.lastTitle(), '视频B');
    });

    testWidgets('不传播放列表 → 上下集行整行不构建（回归保护）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _video(_kBvA));

      expect(find.byKey(_kPlaylistRow), findsNothing);
      expect(find.byKey(_kPrevBtn), findsNothing);
      expect(find.byKey(_kNextBtn), findsNothing);
      expect(find.text('上一集'), findsNothing);
      expect(find.text('下一集'), findsNothing);
      // 底栏本身照常（证明上面 findsNothing 不是「整条底栏没渲染」）
      expect(find.text('1x'), findsOneWidget);
      expect(find.text('弹幕'), findsOneWidget);
    });

    testWidgets('播放列表只有一条 → 同「没有列表」处理（不出现死按钮）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(
        tester,
        _video(_kBvA),
        playlist: PlaylistContext(videos: [_video(_kBvA)], label: '单条合集'),
      );

      expect(find.byKey(_kPlaylistRow), findsNothing);
      expect(find.text('上一集'), findsNothing);
      expect(find.text('下一集'), findsNothing);
    });

    testWidgets('切换后：旧视频进度/历史落盘 + 弹幕按新 cid 重拉 + UP 信息重拉', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      // 旧视频当前播放位置 45s（切换前的 _saveExitProgress 取的就是它）
      rec.positions[1] = [45000];
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[0],
        playlist: PlaylistContext(videos: videos, label: '合集'),
        playlistIndex: 0,
      );

      // 打开弹幕（开关仍开 → 换源后会自动按新 cid 再拉一次）
      await tester.tap(find.text('弹幕'));
      await _settle(tester);
      expect(http.has('oid=1111'), isTrue, reason: '当前视频的弹幕请求');

      await _tap(tester, _kNextBtn);

      // ① 旧视频进度 + 历史都落盘（key 是 bvid+pageIndex，换 bvid 天然不串）
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('playback_progress:${_kBvA}_0');
      expect(saved, isNotNull, reason: '切换前必须存旧视频进度');
      expect(saved, contains('45000'));
      expect(
        prefs.getString('playback_progress:${_kBvB}_0'),
        isNull,
        reason: '旧视频的位置绝不能写到新视频的 key 上（否则新视频会被恢复成旧进度）',
      );
      final history = prefs.getString('history_store:entries') ?? '';
      expect(history, contains(_kBvA), reason: '历史记录记的是旧视频那条');
      expect(
        history,
        isNot(contains(_kBvB)),
        reason: '切走时历史里不该出现新视频的条目',
      );

      // ② 新视频的 UP 元数据（view）重新拉
      expect(http.has('bvid=$_kBvB'), isTrue);
      // ③ 弹幕按新 cid 重新拉（不是旧 cid 复用）
      expect(http.has('oid=2222'), isTrue, reason: '换源后弹幕要用新 cid');
      // ④ 通知栏标题跟着换
      expect(rec.lastNotifTitle(), '视频B');
    });

    testWidgets('邻居缺 cid（cid=0）→ 先 fetchVideoMeta 补齐再切', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = [
        _video(_kBvA),
        _video(_kBvB, cid: 0), // 列表里这条没带 cid
      ];
      await _pumpPlayer(
        tester,
        videos[0],
        playlist: PlaylistContext(videos: videos),
        playlistIndex: 0,
      );
      final before = rec.setDataSources.length;

      await _tap(tester, _kNextBtn);

      expect(http.has('bvid=$_kBvB'), isTrue, reason: '缺 cid 要先补 view 元数据');
      expect(
        rec.setDataSources.length,
        before + 1,
        reason: '补齐后照常切换（不是报错退出）',
      );
      expect(rec.lastTitle(), '视频B');
      // 取流用的是补齐后的 cid（2222），不是 0
      expect(http.has('cid=2222'), isTrue);
      expect(find.textContaining('获取视频信息失败'), findsNothing);
    });

    testWidgets('邻居元数据拉取失败 → 只提示一句，不动当前播放', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      _failViewBvid = _kBvB; // 目标这条的 view 接口返回业务错误
      final videos = [
        _video(_kBvA),
        _video(_kBvB, cid: 0),
      ];
      await _pumpPlayer(
        tester,
        videos[0],
        playlist: PlaylistContext(videos: videos),
        playlistIndex: 0,
      );
      final before = rec.setDataSources.length;

      await _tap(tester, _kNextBtn);

      expect(rec.setDataSources.length, before, reason: '补不到元数据就不切走');
      expect(rec.lastTitle(), '视频A', reason: '当前播放不受影响');
      expect(find.textContaining('获取视频信息失败'), findsOneWidget);
      // 下标退回原处：集号仍显示 1/2
      expect(find.textContaining('1/2'), findsOneWidget);
    });
  });

  // 上下集行的**几何**（v2.30.0-r2 修 P1 布局缺陷）。
  //
  // 真机实测的缺陷：初版 `Row[Expanded(上一集), Flexible(标签), Expanded(下一集)]`
  // 三个孩子都吃 flex → 按钮各只占 1/3 屏，标签 loose fit 用不完的份额留在行尾
  // 变成死区（竖屏 411dp：行右侧 366.8..411 死区；横屏 2400px：右侧 1786..2400
  // 死区 ≈234dp）→ 横屏下点在视觉上「下一集 ▶」旁边（屏宽 75% 处）落空。
  //
  // 这里用**矩形**而不是像素坐标断言（屏幕尺寸是测试自己设的，公式才对得上）：
  //   1. 两个按钮各 = 行宽 × 0.5，左端贴行左、右端贴行右（一点死区都没有）；
  //   2. 按钮高度 = 整行高（40dp 的行高才是设计里的触摸目标下限，初版只有 18dp）；
  //   3. 标签居中、不超上限、不参与宽度分配（长 label 走省略号，绝不挤按钮）；
  //   4. **行为**层面：点在「下一集」视觉中心（行宽 75% 处）必须真的换集；
  //   5. 竖屏 / 横屏置顶 / 全屏横屏三种形态都要成立。
  group('上下集行：行几何（半屏按钮 + 无行尾死区）', () {
    /// 行、两个按钮、标签的矩形（全部来自真实布局）。
    ({
      Rect row,
      Rect prev,
      Rect next,
      Rect label,
    }) geom(WidgetTester tester, String labelFragment) => (
      row: tester.getRect(find.byKey(_kPlaylistRow)),
      prev: tester.getRect(find.byKey(_kPrevBtn)),
      next: tester.getRect(find.byKey(_kNextBtn)),
      label: tester.getRect(find.textContaining(labelFragment)),
    );

    /// 两条**通用**断言：各占半屏 + 无死区（三种形态共用一份口径）。
    void expectHalves(Rect row, Rect prev, Rect next, {required String form}) {
      expect(prev.left, closeTo(row.left, 0.01), reason: '$form：上一集贴行左端');
      expect(prev.width, closeTo(row.width / 2, 0.01),
          reason: '$form：上一集必须是真正的半屏（初版只有 1/3 屏）');
      expect(next.left, closeTo(row.left + row.width / 2, 0.01),
          reason: '$form：下一集从行中线开始');
      expect(next.width, closeTo(row.width / 2, 0.01),
          reason: '$form：下一集必须是真正的半屏');
      expect(next.right, closeTo(row.right, 0.01),
          reason: '$form：行尾不得留死区（初版横屏右侧 ~234dp 全落空）');
      expect(prev.right, closeTo(next.left, 0.01),
          reason: '$form：两个半屏必须严丝合缝，中间不能有缝');
      expect(prev.height, closeTo(row.height, 0.01),
          reason: '$form：按钮要撑满整行高（40dp 触摸目标下限）');
      expect(next.height, closeTo(row.height, 0.01), reason: '$form：同上');
    }

    testWidgets('竖屏 411×914：各占半屏、无死区、标签居中不超上限；中央播放键不再压标签',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(411, 914);
      addTearDown(tester.view.reset);
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[1],
        playlist: PlaylistContext(videos: videos, label: '合集'),
        playlistIndex: 1,
      );

      final g = geom(tester, '2/3');
      expectHalves(g.row, g.prev, g.next, form: '竖屏');
      expect(g.label.center.dx, closeTo(g.row.center.dx, 0.5),
          reason: '标签在行里居中');
      expect(g.label.width,
          lessThanOrEqualTo(kPlaylistLabelMaxWidth + 0.01),
          reason: '标签有明确的最大宽度（不是「用不完的份额」）');
      expect(g.label.left, greaterThan(g.prev.left + g.prev.width * 0.5),
          reason: '标签不越到上一集那一半里去');

      // 中央控制簇的可读性冲突：这一行的标签曾被 72dp 播放键圆环 + 快退/快进
      // 圆环穿插（白压白）。修法是「有上下集行时整簇上移一行的高度」——
      // 断言按**可见图形**判，不按 IconButton 的盒子（盒子带 8dp padding）。
      final videoArea = tester.getRect(find.byKey(_kVideoArea));
      final glyph = tester.getRect(find.byKey(_kPlayGlyph));
      final replay = tester.getRect(find.byIcon(Icons.replay));
      expect(replay.overlaps(g.label), isFalse,
          reason: '快退圆环不得压到上下集行的标签');
      expect(glyph.overlaps(g.label), isFalse,
          reason: '中央播放键的圆环不得压到上下集行的标签');
      expect(glyph.bottom, lessThanOrEqualTo(videoArea.center.dy),
          reason: '整簇确实上移了（圆环落在视频区中线以上）');
    });

    testWidgets('竖屏：无播放列表时中央控制簇照旧居中（上移只在这一行存在时生效）',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(411, 914);
      addTearDown(tester.view.reset);
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _video(_kBvA));

      expect(find.byKey(_kPlaylistRow), findsNothing);
      final videoArea = tester.getRect(find.byKey(_kVideoArea));
      final glyph = tester.getRect(find.byKey(_kPlayGlyph));
      expect(glyph.center.dy, closeTo(videoArea.center.dy, 1.0),
          reason: '没有上下集行时中央簇必须仍是垂直居中（回归保护）');
    });

    testWidgets('长 label：省略号收口，绝不把按钮挤没（仍各占半屏）', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(411, 914);
      addTearDown(tester.view.reset);
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[1],
        playlist: PlaylistContext(
          videos: videos,
          label: '一个非常非常长的合集名字用来验证省略号与按钮不被挤掉',
        ),
        playlistIndex: 1,
      );

      final g = geom(tester, '2/3');
      expectHalves(g.row, g.prev, g.next, form: '竖屏+长标签');
      expect(g.label.width, lessThanOrEqualTo(g.row.width * 0.34 + 0.01),
          reason: '窄屏兜底：标签最多占行宽 34%（411dp 上是 140dp 封顶）');
      expect(g.label.width, lessThan(g.row.width / 2),
          reason: '长 label 不能长过半屏');
      final text = tester.widget<Text>(find.textContaining('2/3'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis,
          reason: '长 label 走省略号，不是换行也不是撑破行');
    });

    testWidgets('横屏置顶 914×411：各占半屏；点屏宽 75% 处（视觉上的「下一集」）真的换集',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(914, 411);
      addTearDown(tester.view.reset);
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[1],
        playlist: PlaylistContext(videos: videos, label: '合集'),
        playlistIndex: 1,
      );

      final g = geom(tester, '2/3');
      expectHalves(g.row, g.prev, g.next, form: '横屏置顶');

      // 真机缺陷的**原始复现路径**：视觉上「下一集 ▶」在行宽 75% 处，初版那里
      // 是死区（点在 1786..2400 这一段没有任何反应）。这里直接点那个点。
      expect(rec.setDataSources.length, 1);
      await tester.tapAt(Offset(g.row.left + g.row.width * 0.75, g.row.center.dy));
      await _settle(tester);
      expect(rec.setDataSources.length, 2,
          reason: '屏宽 75% 处必须落在「下一集」的命中区里（初版这里落空）');
      expect(rec.lastTitle(), '视频C');
    });

    testWidgets('全屏横屏 914×411：各占半屏、无死区', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(411, 914);
      addTearDown(tester.view.reset);
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      await _pumpPlayer(
        tester,
        videos[1],
        playlist: PlaylistContext(videos: videos, label: '合集'),
        playlistIndex: 1,
      );

      // 进全屏（竖屏视口下点全屏键）→ 再把视口转成横屏（与
      // player_landscape_pin_test 同一路径）
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget,
          reason: '已进全屏');
      tester.view.physicalSize = const Size(914, 411);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      final g = geom(tester, '2/3');
      expectHalves(g.row, g.prev, g.next, form: '全屏横屏');
      expect(g.row.width, closeTo(914, 1.0), reason: '全屏下这一行铺满屏宽');
    });

    testWidgets('横屏带挖孔 inset（MediaQuery padding）：两半仍等宽，且按钮不压到挖孔下',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(914, 411);
      addTearDown(tester.view.reset);
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final videos = _threeVideos();
      // 真机横屏实测左侧有 136px 的挖孔 inset（模拟器 Pixel 7 配置）→ 底栏被
      // SafeArea 内缩。这里用 MediaQuery.padding 造出同一条件，验两件事：
      // ① 两个半屏在**有 inset 时仍然等宽**（不是「谁多吃掉一个 inset」）；
      // ② 这一行整体不越过 inset 起点（按钮绝不落在挖孔下面）。
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(left: 52)),
          child: MaterialApp(
            home: PlayerPage(
              video: videos[1],
              playlist: PlaylistContext(videos: videos, label: '合集'),
              playlistIndex: 1,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      final g = geom(tester, '2/3');
      expectHalves(g.row, g.prev, g.next, form: '横屏+左侧挖孔 inset');
      expect(g.row.left, greaterThanOrEqualTo(52.0),
          reason: '整行必须在挖孔 inset 之后（按钮不能被推到挖孔下面）');
      expect(g.prev.left, closeTo(g.row.left, 0.01),
          reason: '上一集仍贴行的左端（没有被 inset 推走、也没多占）');
    });
  });

  group('入口接线：把列表页看到的顺序传下去', () {
    testWidgets('合集页点单条视频 → playlist = 合集列表、下标 = 被点那条', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      // order 乱序给：sortedVideos 按 order 升序 → 列表显示 B(0) C(1) A(2)
      final data = WhitelistData(
        version: 4,
        updatedAt: '2026-08-20T00:00:00Z',
        videos: [
          _video(_kBvA).copyWith(order: 2, collection: '动画'),
          _video(_kBvB).copyWith(order: 0, collection: '动画'),
          _video(_kBvC).copyWith(order: 1, collection: '动画'),
        ],
        collections: const [
          CollectionInfo(name: '动画', createdAt: '2026-08-01T00:00:00Z'),
        ],
        upowners: const <Upowner>[],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CollectionPage(
            collectionName: '动画',
            data: data,
            saveAndRefresh: (_) async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('视频B'), findsOneWidget);

      // 点列表里第 2 条（= 视频C）
      await tester.tap(find.text('视频C'));
      await _settle(tester);

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.playlist, isNotNull);
      expect(
        page.playlist!.videos.map((v) => v.title).toList(),
        ['视频B', '视频C', '视频A'],
        reason: '顺序必须是合集页看到的顺序（order 升序）',
      );
      expect(page.playlist!.label, '动画');
      expect(page.playlistIndex, 1, reason: '被点的就是第 2 条');
    });

    testWidgets('UP 主页点单条视频 → playlist = 全部视频列表、下标 = 被点那条', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      UpownerPage.clearInfoCacheForTest();

      await tester.pumpWidget(
        const MaterialApp(home: UpownerPage(mid: 100)),
      );
      // UP 资料 / 全部视频 / 合集清单三路都在首屏拉
      await _settle(tester);
      await _settle(tester);
      expect(find.text('主页视频 1'), findsOneWidget);

      await tester.tap(find.text('主页视频 2'));
      await _settle(tester);

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.playlist, isNotNull);
      expect(
        page.playlist!.videos.map((v) => v.title).toList(),
        ['主页视频 1', '主页视频 2'],
      );
      expect(page.playlistIndex, 1);
    });

    testWidgets('UP 主页「合集」分区点视频 → 不接播放上下文（不接错）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      _withSeason = true;
      UpownerPage.clearInfoCacheForTest();

      await tester.pumpWidget(
        const MaterialApp(home: UpownerPage(mid: 100)),
      );
      await _settle(tester);
      await _settle(tester);

      // 切到「精品合集」分区（chip 点选 → PageView 动画滑过去 + 懒加载）
      await tester.tap(find.text('精品合集'));
      await _settle(tester);
      await _settle(tester);
      expect(find.text('合集里的视频'), findsOneWidget);

      await tester.tap(find.text('合集里的视频'));
      await _settle(tester);

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      // 这条 bvid 同时也在「全部视频」列表里（[BV1UP0000002]）——若不做分区
      // 判定，播放页会拿到那份「按发布时间排的全部视频」当上下文，「下一集」
      // 就跳到一条毫不相干的视频上。
      expect(page.playlist, isNull, reason: '合集分区的顺序不是 _videos，宁可不接');
    });
  });
}
