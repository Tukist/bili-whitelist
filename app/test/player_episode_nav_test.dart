// 播放页「分 P 上下集」widget 测试（v2.46.0+）。
//
// 背景（用户原话）：「仍然没有完成单个视频有多集的上下集切换」——一个 BV 号下
// 分 P（`?p=1`/`?p=2`…），App 里只能播一集，底栏那对「上一集/下一集」按钮切的
// 是**播放列表里的下一条 bvid**（v2.30.0 的语义），分 P 维度从来没接上过
// （历史两次「上下集」其实都是「播放列表里换 bvid」）。
//
// 覆盖：
//   1. 纯函数 [parseViewPages]：正常解析 / 缺键 / 脏数据（含 cid<=0）→ 空列表；
//   2. 多 P 视频：底栏出现上下集行，中间标签报**分 P 维度**（`1/3 P`）；点
//      「下一集」真的切到 P2（取流用了 P2 的 cid，不是 bvid 维度）；
//   3. **P 边界不跨界**：第一个 P 的「上一集」禁用、最后一个 P 的「下一集」
//      禁用；即便这次带了播放列表，也不跨到列表里的其它视频；
//   4. **运行时补分 P 列表**（本版核心）：条目不带 pages 时，`?p=2` 进来先补
//      pages 再取流 → 取流用的是 P2 的 cid（改动前恒为顶层 cid = P1）；
//      且**不重复发** view（复用进页那一次）；
//   5. 进度按分 P 记忆：切到 P2 恢复的是 P2 自己的进度（key 含 pageIndex）；
//   6. 通知收起行的「下一集」与底栏走同一条路（同样切分 P）；
//   7. 既有行为零回归：单 P 视频的上下集仍走播放列表（见
//      test/player_playlist_switch_test.dart，本文件不重复其断言）。
//
// 测试环境（与 player_playlist_switch_test.dart 同款骨架）：mock 播放器通道
// （setDataSource → onPrepared）、按 URL 路由的假 HTTP（view 给多 P 列表，
// playurl 的 DASH baseUrl 里带 cid）、内存 DownloadManager 替身；
// **一律显式 pump，不用 pumpAndSettle**（缓冲转圈是无限动画）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/playlist_context.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

const String _kBvMulti = 'BV1EP0000001';
const String _kBvOther = 'BV1EP0000002';

/// 「条目没带 pages → 运行时补」那几条用例各自用一个**全新 bvid**：分 P 列表
/// 缓存（`_viewPagesCache`）与 UP 主元数据缓存都是**库级**的（会话内跨播放页
/// 共享，同 [_upMetaCache]），用同一个 bvid 会让后一条用例直接命中缓存、测不到
/// 「补」这条路。
const String _kBvGate = 'BV1EP0001001';
const String _kBvCount = 'BV1EP0001002';
const String _kBvCountCtrl = 'BV1EP0001003';
const String _kBvClamp = 'BV1EP0001004';

const String _kTitle = '多P视频';
const String _kOtherTitle = '播放列表里的另一条';

/// 多 P 视频的三个分 P（cid 各不相同：取流用哪一集是可观测的）。
const List<PageInfo> _kPages = [
  PageInfo(cid: 1001, part: '第1集', duration: 200),
  PageInfo(cid: 1002, part: '第2集', duration: 200),
  PageInfo(cid: 1003, part: '第3集', duration: 200),
];

const Key _kPrevBtn = ValueKey('player-prev-video');
const Key _kNextBtn = ValueKey('player-next-video');
const Key _kPlaylistRow = ValueKey('player-playlist-row');

/// 多 P 视频条目（[withPages] = false 模拟「旧数据 / 离线缓存页」：条目没带
/// 分 P 列表，只能靠播放页运行时补）。
WhitelistVideo _multiVideo({String bvid = _kBvMulti, bool withPages = true}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 1001,
      title: _kTitle,
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01T00:00:00Z',
      pages: withPages ? _kPages : null,
    );

WhitelistVideo _otherVideo() => const WhitelistVideo(
  bvid: _kBvOther,
  cid: 2001,
  title: _kOtherTitle,
  cover: '',
  duration: 200,
  upName: '测试UP主',
  addedAt: '2026-01-02T00:00:00Z',
);

// ---------------------------------------------------------------------------
// 假 HTTP：view 给多 P 列表；playurl 的 DASH 流地址里带**请求的 cid**
// （于是 `setDataSource` 记下来的 videoUrl 就是「取的是哪一集」的直接证据）
// ---------------------------------------------------------------------------

class _FakeHttp {
  final List<Uri> requests = [];

  /// 非 null 时：view 接口的响应被挂住，直到测试显式 complete（用来断言
  /// 「**必须先拿到分 P 列表再取流**」——取流请求不可能抢在它前面）。
  Completer<void>? viewGate;

  int count(String fragment) =>
      requests.where((u) => u.toString().contains(fragment)).length;
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides(this.harness);

  final _FakeHttp harness;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient(harness);
}

const Map<String, dynamic> _kWbiImg = {
  'img_url':
      'https://i0.hdslb.com/bfs/wbi/a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png',
  'sub_url':
      'https://i0.hdslb.com/bfs/wbi/e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png',
};

/// view 接口的 data：多 P 列表 + 顶层 cid = P1（B 站的真实形态）。
Map<String, dynamic> _viewData(String bvid) => {
  'bvid': bvid,
  'aid': 1,
  'cid': 1001,
  'title': _kTitle,
  'pic': '',
  'duration': 600,
  'pubdate': 1700000000,
  'quality': 80,
  'wbi_img': _kWbiImg,
  'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
  'desc': '',
  'pages': [
    {'cid': 1001, 'part': '第1集', 'duration': 200},
    {'cid': 1002, 'part': '第2集', 'duration': 200},
    {'cid': 1003, 'part': '第3集', 'duration': 200},
  ],
};

/// playurl 的 data：DASH 双流，baseUrl 里写死请求的 cid。
Map<String, dynamic> _playUrlData(Uri url) {
  final cid = int.tryParse(url.queryParameters['cid'] ?? '') ?? 0;
  return {
    'quality': 80,
    'dash': {
      'video': [
        {'baseUrl': 'https://x.bilivideo.com/p$cid.v.m4s', 'bandwidth': 1000},
      ],
      'audio': [
        {'baseUrl': 'https://x.bilivideo.com/p$cid.a.m4s', 'bandwidth': 128000},
      ],
    },
  };
}

(int, String, List<int>) _responseFor(Uri url) {
  final path = url.path;
  final bvid = url.queryParameters['bvid'] ?? '';
  if (path.endsWith('/x/v1/dm/list.so')) {
    return (
      200,
      'text/xml',
      utf8.encode('<?xml version="1.0"?><i></i>'),
    );
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
  // 取流：按请求里的 cid 给流地址（「切到第几 P」的唯一硬证据）
  if (path.contains('playurl')) {
    return (
      200,
      'application/json',
      utf8.encode(jsonEncode({'code': 0, 'data': _playUrlData(url)})),
    );
  }
  // 元数据（view / relation / 评论区 / 预览图…）：统一给 view 形状的响应
  return (
    200,
    'application/json',
    utf8.encode(jsonEncode({'code': 0, 'data': _viewData(bvid)})),
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
    final gate = harness.viewGate;
    if (gate != null && url.path.endsWith('/x/web-interface/view')) {
      await gate.future; // 挂住 view 响应（测试用：断言取流等它）
    }
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

/// 内存版 DownloadManager（不读真文件：FakeAsync 下真实 IO 永不完成）。
class _FakeManager extends DownloadManager {
  _FakeManager() {
    cached.value = const [];
  }
}

// ---------------------------------------------------------------------------
// 原生播放器通道替身
// ---------------------------------------------------------------------------

class _PlayerRec {
  final List<Map<String, Object?>> setDataSources = [];
  final List<int> seeks = [];

  /// 取流时用的流地址（`p1002.v.m4s` 这种 → 直接读出「取的是哪一集」）。
  String lastVideoUrl() => (setDataSources.last['videoUrl'] ?? '') as String;

  MockStreamHandlerEventSink? eventSink;

  int get lastTextureId => (setDataSources.last['textureId'] as int?) ?? 1;

  /// 推一条原生事件（模拟通知收起行 / 耳机按键 → onMediaAction）。
  void emit(String event, {String? action}) {
    eventSink?.success({
      'event': event,
      'textureId': lastTextureId,
      if (action != null) 'action': action,
      'positionMs': 0,
    });
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
          return 0;
        case 'seekTo':
          rec.seeks.add(args['positionMs'] as int);
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

Future<void> _pumpPlayer(
  WidgetTester tester,
  WhitelistVideo video, {
  PlaylistContext? playlist,
  int playlistIndex = 0,
  int initialPageIndex = 0,
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
        initialPageIndex: initialPageIndex,
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

/// 某个 bvid 的 view 请求次数（**只数 view 接口**：relation / playurl 都带
/// bvid，不能混进来）。播放页自己会发一次，内嵌评论区解析 aid 时还会发一次
/// （两条路径都走 fetchVideoMeta），所以这里用「两次进入的差值」做断言。
int _viewCount(_FakeHttp h, String bvid) => h.requests
    .where(
      (u) =>
          u.path.endsWith('/x/web-interface/view') &&
          u.queryParameters['bvid'] == bvid,
    )
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHttp http;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    http = _FakeHttp();
    final old = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides(http);
    addTearDown(() => HttpOverrides.global = old);
    DownloadManager.debugOverride(_FakeManager());
  });
  group('parseViewPages（纯函数）', () {
    test('正常解析：cid/part/duration 逐条读出', () {
      final pages = parseViewPages({
        'pages': [
          {'cid': 11, 'part': 'P1', 'duration': 60},
          {'cid': 22, 'part': 'P2', 'duration': 90},
        ],
      });
      expect(pages, hasLength(2));
      expect(pages[0].cid, 11);
      expect(pages[0].part, 'P1');
      expect(pages[1].cid, 22);
      expect(pages[1].duration, 90);
    });

    test('缺键 / null / 非 List / 空数组 → 空列表（调用方保持原行为）', () {
      expect(parseViewPages(null), isEmpty);
      expect(parseViewPages(const {}), isEmpty);
      expect(parseViewPages(const {'pages': null}), isEmpty);
      expect(parseViewPages(const {'pages': 'oops'}), isEmpty);
      expect(parseViewPages(const {'pages': []}), isEmpty);
    });

    test('脏元素 → 整份空列表（宁可不要，也不让分 P 序号错位）', () {
      // 非 Map 元素
      expect(parseViewPages(const {'pages': [11, {'cid': 22}]}), isEmpty);
      // 条目里脏类型（part 是数字 → PageInfo.fromJson 的 `as String?` 会抛）
      expect(
        parseViewPages(const {'pages': [{'cid': 22, 'part': 3}]}),
        isEmpty,
      );
      // 缺 cid → cid 解析成 0
      expect(parseViewPages(const {'pages': [{'part': '没有 cid'}]}), isEmpty);
    });

    test('任何一条 cid<=0 → 整份空列表（cid 是取流的唯一凭据）', () {
      expect(
        parseViewPages(const {
          'pages': [
            {'cid': 11},
            {'cid': 0},
          ],
        }),
        isEmpty,
      );
    });
  });

  group('多 P 视频：上下集切分 P', () {
    testWidgets('点「下一集」真的切到 P2（取流用 P2 的 cid，不是换 bvid）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _multiVideo());

      // 进来先播 P1
      expect(rec.setDataSources, hasLength(1));
      expect(rec.lastVideoUrl(), contains('p1001.v.m4s'),
          reason: '首帧取流用的是顶层 cid（= P1）');
      // 中间标签报**分 P 维度**（不是 1/2 这种「视频条数」）
      expect(find.byKey(_kPlaylistRow), findsOneWidget);
      expect(find.textContaining('1/3 P'), findsOneWidget);
      expect(_enabled(tester, _kPrevBtn), isFalse, reason: 'P1 没有上一集');
      expect(_enabled(tester, _kNextBtn), isTrue);

      await _tap(tester, _kNextBtn);

      expect(rec.setDataSources, hasLength(2), reason: '切 P 要重新取流');
      expect(rec.lastVideoUrl(), contains('p1002.v.m4s'),
          reason: '取流必须用 P2 的 cid（1002），而不是顶层 cid');
      expect(http.count('cid=1002'), greaterThanOrEqualTo(1),
          reason: 'playurl 请求带的是 P2 的 cid');
      expect(find.textContaining('2/3 P'), findsOneWidget, reason: '标签跟着走到 2/3');
      expect(_enabled(tester, _kPrevBtn), isTrue);

      // 再点一次 → P3（标签 3/3，且「下一集」到头禁用）
      await _tap(tester, _kNextBtn);
      expect(rec.lastVideoUrl(), contains('p1003.v.m4s'));
      expect(find.textContaining('3/3 P'), findsOneWidget);
      expect(_enabled(tester, _kNextBtn), isFalse, reason: '最后一个 P 没有下一集');
    });

    testWidgets('P 边界不跨界：最后一个 P 的「下一集」禁用，即便带着播放列表', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final multi = _multiVideo();
      final other = _otherVideo();
      await _pumpPlayer(
        tester,
        multi,
        playlist: PlaylistContext(videos: [multi, other], label: '合集'),
        playlistIndex: 0,
        initialPageIndex: 2, // 直接进最后一个 P
      );

      expect(find.textContaining('3/3 P'), findsOneWidget,
          reason: '多 P 时标签是分 P 维度，不是「1/2」的列表维度');
      expect(_enabled(tester, _kNextBtn), isFalse, reason: '末 P 没有下一集');
      expect(_enabled(tester, _kPrevBtn), isTrue);

      final before = rec.setDataSources.length;
      await _tap(tester, _kNextBtn);
      expect(rec.setDataSources, hasLength(before),
          reason: '点禁用态无动作 —— 绝不跨到播放列表里的下一条视频');
      expect(rec.lastVideoUrl(), contains('p1003.v.m4s'));
      expect(find.textContaining(_kOtherTitle), findsNothing);
    });

    testWidgets('第一个 P 的「上一集」禁用（不跨到播放列表的上一条）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      final multi = _multiVideo();
      final other = _otherVideo();
      await _pumpPlayer(
        tester,
        multi,
        playlist: PlaylistContext(videos: [other, multi], label: '合集'),
        playlistIndex: 1, // 列表里第 2 条：列表维度上有「上一集」
      );

      expect(find.textContaining('1/3 P'), findsOneWidget);
      expect(_enabled(tester, _kPrevBtn), isFalse,
          reason: 'P1 没有上一集，不去列表里的上一条');

      final before = rec.setDataSources.length;
      await _tap(tester, _kPrevBtn);
      expect(rec.setDataSources, hasLength(before));
      expect(rec.lastVideoUrl(), contains('p1001.v.m4s'));
    });

    testWidgets('切 P 后按新分 P 重拉弹幕（oid = 新 cid）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _multiVideo());

      await tester.tap(find.text('弹幕'));
      await _settle(tester);
      expect(http.count('oid=1001'), greaterThanOrEqualTo(1),
          reason: '当前集是 P1 → 弹幕要 P1 的 cid');

      await _tap(tester, _kNextBtn);
      expect(http.count('oid=1002'), greaterThanOrEqualTo(1),
          reason: '切到 P2 后弹幕按新 cid 重拉（不是复用 P1 的）');
    });

    testWidgets('通知收起行的「下一集」走同一条路（也切分 P）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _multiVideo());
      expect(rec.setDataSources, hasLength(1));

      // 原生侧只回推动作（Kotlin 不做换集），换集全部由 Dart 完成
      rec.emit('onMediaAction', action: 'next');
      await _settle(tester);

      expect(rec.setDataSources, hasLength(2));
      expect(rec.lastVideoUrl(), contains('p1002.v.m4s'),
          reason: '通知「下一集」在多 P 视频上同样切分 P');
      expect(find.textContaining('2/3 P'), findsOneWidget);
    });
  });

  group('运行时补分 P 列表（条目没带 pages）', () {
    testWidgets('?p=2 进来：**取流必须等分 P 列表到手** → 取流用 P2 的 cid',
        (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      // 把 view 响应挂住：如果取流不等它（改动前的行为），这里就会先按顶层
      // cid（= P1）取流 —— 正是用户报的「点第 2 集播了第 1 集」。
      http.viewGate = Completer<void>();
      // 条目**不带** pages（旧白名单数据 / 老历史记录 / 离线缓存页都是这个形态）
      await _pumpPlayer(tester, _multiVideo(bvid: _kBvGate, withPages: false),
          initialPageIndex: 1);

      expect(rec.setDataSources, isEmpty,
          reason: '分 P 列表还没到手 → 一次取流都不该发生（否则恒按 P1 取流）');

      // 放行 view 响应（其他请求早已返回）
      http.viewGate!.complete();
      await _settle(tester);

      expect(rec.setDataSources, hasLength(1));
      expect(rec.lastVideoUrl(), contains('p1002.v.m4s'),
          reason: '页面停在 ?p=2 → 取流必须用 P2 的 cid（1002）');
      expect(http.count('cid=1001'), 0,
          reason: '全程一次都不该按 P1 取流');

      // 补上 pages 后：选集 UI 与上下集按钮都出现了
      expect(find.byKey(_kPlaylistRow), findsOneWidget);
      expect(find.textContaining('2/3 P'), findsOneWidget);
      expect(find.text('选集 2/3'), findsOneWidget, reason: '多 P 判定同样跟着补上');
      expect(_enabled(tester, _kPrevBtn), isTrue, reason: 'P2 有上一集');
      expect(_enabled(tester, _kNextBtn), isTrue);
    });

    testWidgets('补 pages 不额外增加 view 请求（复用进页那次）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);

      // ① 对照：另一个**全新 bvid** 从第 1 集进（不需要补分 P 列表），
      //    它的 view 次数就是「一个播放页本来就会发几次」的基线
      await _pumpPlayer(tester,
          _multiVideo(bvid: _kBvCountCtrl, withPages: false));
      await _settle(tester);
      final baseline = _viewCount(http, _kBvCountCtrl);
      expect(baseline, greaterThan(0), reason: '进页本来就会拉一次 view');

      // 卸载（上一页的收尾请求别算进新计数器）后换一份干净计数器再进一次
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final http2 = _FakeHttp();
      HttpOverrides.global = _FakeHttpOverrides(http2);

      await _pumpPlayer(tester,
          _multiVideo(bvid: _kBvCount, withPages: false), initialPageIndex: 1);
      await _settle(tester);

      expect(_viewCount(http2, _kBvCount), baseline,
          reason: '补分 P 列表复用进页那次 view，不额外发请求（多一个 RTT 都不给）');
      expect(find.textContaining('2/3 P'), findsOneWidget);
    });

    testWidgets('条目已带 pages：一个字节都不改（不覆盖白名单写入的分 P 信息）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _multiVideo(), initialPageIndex: 2);

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.video.pages, hasLength(3), reason: '构造参数本身不被改写');
      expect(find.textContaining('3/3 P'), findsOneWidget);
      expect(rec.lastVideoUrl(), contains('p1003.v.m4s'));
    });

    testWidgets('?p 超出分 P 数：补上列表后夹到最后一集（不 RangeError）', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      await _pumpPlayer(tester, _multiVideo(bvid: _kBvClamp, withPages: false),
          initialPageIndex: 8);
      await _settle(tester); // 让在途请求（buvid/评论首屏）跑完，别留 pending 定时器

      expect(tester.takeException(), isNull);
      expect(find.textContaining('3/3 P'), findsOneWidget, reason: '夹到最后一集');
      expect(rec.lastVideoUrl(), contains('p1003.v.m4s'));
    });

    testWidgets('进度按分 P 记忆：切到 P2 恢复的是 P2 自己的进度', (tester) async {
      final rec = _PlayerRec();
      _installMocks(tester, rec);
      // P2（pageIndex 1）上次看到 30s —— key 里带 pageIndex，天然按 P 隔离
      SharedPreferences.setMockInitialValues({
        'playback_progress:${_kBvMulti}_1': jsonEncode({'positionMs': 30000}),
      });
      await _pumpPlayer(tester, _multiVideo());

      expect(rec.seeks, isEmpty, reason: 'P1 没有记忆进度 → 从头播');

      await _tap(tester, _kNextBtn);

      expect(rec.seeks, contains(30000),
          reason: '切到 P2 后要按 P2 的记忆进度续播（key = bvid+pageIndex）');
    });
  });
}
