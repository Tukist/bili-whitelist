// 播放页**远程进度补查**（v2.59.0，跨端续播的 B2 部分）测试。
//
// 场景：从白名单 / 合集 / 搜索直接进视频时没有经过历史同步，本机进度记忆里
// 也没有这一集 —— 这时补查一次 B 站「上次播放到哪」，让 PC 上看了一半的视频
// 在手机上接着播。
//
// 钉住的点（断言落在**请求次数 / seek 目标 / 通道方法**上，不戳私有字段）：
// - 本地无记录 + 已登录 → 用远程进度作为初始位置（seekTo 目标 = 远程值）；
// - 本地**有**记录 → 一次远程请求都不发（本机就是最新的事实）；
// - 远程进度过小（≤5s）/ 太接近结尾 → 不用；
// - 未登录 → 不发请求、静默从头播；
// - 远程请求失败 → 静默，正常从头播。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

/// 视频时长（onPrepared 给的值）；与 view/playurl 里的 duration 一致。
const int _kDurationMs = 200000;

const int _kCid = 1001;

WhitelistVideo _video(String bvid) => WhitelistVideo(
  bvid: bvid,
  cid: _kCid,
  title: '跨端进度测试视频',
  cover: '',
  duration: 200,
  upName: '测试UP主',
  addedAt: '2026-01-01',
  pages: const [PageInfo(cid: _kCid, part: '', duration: 200)],
);

/// 记录到的平台调用 + 收到过的 HTTP 路径。
class _Rec {
  final List<String> playerMethods = [];
  final List<int> seeks = [];
  final List<String> httpPaths = [];
}

// ---------------------------------------------------------------------------
// mock HTTP：按路径回合法 JSON（不发真实请求）
// ---------------------------------------------------------------------------

String? _playerV2Body; // 由用例设置：`x/player/wbi/v2` 的响应体

String _bodyFor(Uri uri) {
  final path = uri.path;
  if (path.contains('player/wbi/v2')) {
    return _playerV2Body ?? '{"code":0,"data":{}}';
  }
  if (path.contains('/x/web-interface/nav')) {
    return '{"code":0,"data":{"isLogin":true,"mid":123,'
        '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png","sub_url":"https://i0.hdslb.com/bfs/wbi/'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png"}}}';
  }
  // 其余（spi / view / playurl / 相关推荐…）统一回一份"什么都够用"的 data
  return '{"code":0,"data":{'
      '"bvid":"BV1CROSS0001","aid":1001,"cid":$_kCid,"duration":200,'
      '"quality":80,"accept_quality":[80],"accept_description":["1080P"],'
      '"owner":{"mid":1001,"name":"测试UP主","face":""},'
      '"desc":"",'
      '"pages":[{"cid":$_kCid,"part":"","duration":200}],'
      '"replies":[],"top_replies":[],"cursor":{"is_end":true},'
      '"subtitles":[],'
      '"dash":{"video":[{"baseUrl":"https://x.bilivideo.com/v.m4s"}],'
      '"audio":[{"baseUrl":"https://x.bilivideo.com/a.m4s"}]}}}';
}

class _FakeHttpOverrides extends HttpOverrides {
  _FakeHttpOverrides(this.rec);

  final _Rec rec;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(rec);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.rec);

  final _Rec rec;

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
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    rec.httpPaths.add(url.path);
    return _FakeHttpRequest(url);
  }

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
  _FakeHttpRequest(this._target);

  /// 目标 URI（不叫 `uri`：那会覆盖 `HttpClientRequest.uri` 成员，
  /// 需要 `@override` 注解，白挨一条 lint）。
  final Uri _target;

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
  Future<HttpClientResponse> close() async =>
      _FakeHttpResponse(utf8.encode(_bodyFor(_target)));

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
// 平台通道 mock
// ---------------------------------------------------------------------------

void _installMocks(WidgetTester tester, _Rec rec, {required bool loggedIn}) {
  HttpOverrides.global = _FakeHttpOverrides(rec);
  addTearDown(() => HttpOverrides.global = null);

  var texId = 0;
  MockStreamHandlerEventSink? eventSink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      if (call.method == 'create') return ++texId;
      rec.playerMethods.add(call.method);
      if (call.method == 'setDataSource') {
        final map = call.arguments as Map;
        eventSink?.success({
          'event': 'onPrepared',
          'textureId': map['textureId'],
          'width': 1280,
          'height': 720,
          'durationMs': _kDurationMs,
        });
      }
      if (call.method == 'seekTo') {
        rec.seeks.add((call.arguments as Map)['positionMs'] as int);
      }
      return null;
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
        eventSink = events;
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
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_whitelist/media'),
      null,
    ),
  );

  // 登录态：`loggedIn` 决定 secure storage 里有没有有效 SESSDATA
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async {
      if (call.method != 'read') return null;
      if (!loggedIn) return null;
      return '100%2C9999999999%2Cabcdef';
    },
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

Future<_Rec> _pumpPlayer(
  WidgetTester tester,
  WhitelistVideo video, {
  required bool loggedIn,
}) async {
  final rec = _Rec();
  _installMocks(tester, rec, loggedIn: loggedIn);
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: video)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600)); // 取流 + onPrepared
  await tester.pump(const Duration(milliseconds: 400)); // 补查结果落地 + 定位
  return rec;
}

/// 远程进度响应体（`last_play_time` 毫秒；cid 默认与视频一致）。
String _progressBody(int ms, {int cid = _kCid}) =>
    '{"code":0,"data":{"last_play_cid":$cid,"last_play_time":$ms}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => _playerV2Body = null);

  group('usableRemoteProgressMs（纯函数）', () {
    test('5 秒及以下不用（太靠前，续播没意义）', () {
      expect(usableRemoteProgressMs(remoteMs: 0, durationMs: 200000), isNull);
      expect(usableRemoteProgressMs(remoteMs: 5000, durationMs: 200000), isNull);
      expect(
        usableRemoteProgressMs(remoteMs: 5001, durationMs: 200000),
        5001,
      );
    });

    test('太接近结尾不用（一进去就播完）', () {
      expect(
        usableRemoteProgressMs(remoteMs: 195000, durationMs: 200000),
        isNull,
      );
      expect(
        usableRemoteProgressMs(remoteMs: 194000, durationMs: 200000),
        194000,
      );
    });

    test('时长未知时不判上界（下界已挡掉脏数据）', () {
      expect(
        usableRemoteProgressMs(remoteMs: 90000, durationMs: 0),
        90000,
      );
    });

    test('null 不用', () {
      expect(usableRemoteProgressMs(remoteMs: null, durationMs: 200000), isNull);
    });
  });

  testWidgets('本地无记录 + 已登录 → 用远程进度作为初始位置', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _playerV2Body = _progressBody(90000);

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0001'),
        loggedIn: true);

    expect(
      rec.httpPaths.where((p) => p.contains('player/wbi/v2')),
      isNotEmpty,
      reason: '本机没有这一集的记录 → 要补查一次远程进度',
    );
    expect(rec.seeks, contains(90000), reason: '按远程进度续播（90s / 200s）');
    expect(find.textContaining('已从上次'), findsOneWidget);
  });

  testWidgets('本地已有记录 → 一次远程请求都不发（本机才是最新的事实）',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      // 本机进度记忆（键 <bvid>_<pageIndex>）
      'playback_progress:BV1CROSS0002_0': '{"positionMs":30000}',
    });
    _playerV2Body = _progressBody(90000);

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0002'),
        loggedIn: true);

    expect(
      rec.httpPaths.where((p) => p.contains('player/wbi/v2')),
      isEmpty,
      reason: '有本机记录就不该再问远程',
    );
    expect(rec.seeks, contains(30000), reason: '按本机记忆续播');
    expect(rec.seeks, isNot(contains(90000)));
  });

  testWidgets('远程进度过小（≤5s）→ 不用，正常从头播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _playerV2Body = _progressBody(3000);

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0003'),
        loggedIn: true);

    expect(
      rec.httpPaths.where((p) => p.contains('player/wbi/v2')),
      isNotEmpty,
      reason: '前置：确实查了',
    );
    expect(rec.seeks, isEmpty, reason: '3 秒不值得续播，也不该 seek');
    expect(find.textContaining('已从上次'), findsNothing);
  });

  testWidgets('远程进度太接近结尾 → 不用（免得一进去就播完）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _playerV2Body = _progressBody(197000); // 距 200s 结尾只剩 3s

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0004'),
        loggedIn: true);

    expect(rec.seeks, isEmpty);
    expect(find.textContaining('已从上次'), findsNothing);
  });

  testWidgets('远程进度属于别的分 P → 不借用', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // last_play_cid 与当前集不一致（上次看的是另一集）
    _playerV2Body = _progressBody(90000, cid: 9999);

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0005'),
        loggedIn: true);

    expect(rec.seeks, isEmpty, reason: '别的分 P 的进度不能 seek 到这一集');
  });

  testWidgets('未登录 → 不发请求、静默从头播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _playerV2Body = _progressBody(90000);

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0006'),
        loggedIn: false);

    expect(
      rec.httpPaths.where((p) => p.contains('player/wbi/v2')),
      isEmpty,
      reason: '未登录时补查注定 -101，一个请求都不该发',
    );
    expect(rec.seeks, isEmpty);
    // 播放照常（取流成功、播放器就绪）
    expect(rec.playerMethods, contains('setDataSource'));
  });

  testWidgets('远程请求失败（风控）→ 静默，正常从头播', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _playerV2Body = '{"code":-412,"message":"请求被拦截"}';

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0007'),
        loggedIn: true);

    expect(rec.seeks, isEmpty, reason: '拿不到进度就从头播，不弹错');
    expect(find.textContaining('已从上次'), findsNothing);
    expect(rec.playerMethods, contains('setDataSource'), reason: '播放不能被影响');
  });

  testWidgets('同一次入页只查一次（去重）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    _playerV2Body = _progressBody(90000);

    final rec = await _pumpPlayer(tester, _video('BV1CROSS0008'),
        loggedIn: true);
    await tester.pump(const Duration(seconds: 12)); // 跨过若干个 10s 保存 tick

    final queried = rec.httpPaths.where((p) => p.contains('player/wbi/v2'));
    expect(queried, hasLength(1), reason: '同一集不许反复打这个接口');
  });
}
