// 播放页「热度高潮线」widget 测试（v2.61.0+）：
// - 数据就绪（弹幕 + 时长都有）→ 曲线层出现，位置在轨道**上方**，且整层被
//   IgnorePointer 包着（不抢命中）
// - 曲线**不影响**进度条：带曲线时拖动仍照常 submit seekTo
// - 弹幕为空 / 还没回来（挂闸）→ 不画线；回来后画出（不画假的平线）
// - 开关关掉（预置 heatCurve=false）→ 不画线，且**不拉弹幕**（不多花请求）
// - 切分 P → 用新 cid 的弹幕重算，曲线数据随之变化
// - 运行时在弹幕设置面板里关掉 → 立刻消失
//
// 环境沿用 player_seek_preview_test 的骨架（mock 播放器通道 / 假 HTTP /
// 显式 pump 不用 pumpAndSettle）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/danmaku.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/heat_curve.dart';
import 'package:bili_whitelist_app/widgets/heat_curve_bar.dart';

const String _kBvid = 'BV1HEAT00001';

/// 取流时长（ms）：200s → 默认桶宽 10s = 20 个桶。
const int _kDurationMs = 200000;

const Key _kSeekBar = ValueKey('player-seek-bar');

WhitelistVideo _video({List<PageInfo>? pages}) => WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '热度曲线测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      pages: pages,
    );

/// 造一条弹幕。
Danmaku _dm(double t) =>
    Danmaku(timeSec: t, mode: 1, fontSize: 25, color: 0xFFFFFF, text: '$t');

/// 假 B 站接口：只接管 [fetchDanmaku]（记录 cid、可按 cid 挂闸/定制数据）。
class _FakeDanmakuApi extends BiliApi {
  /// 每次 fetchDanmaku 收到的 cid（按调用顺序）。
  final List<int> cids = [];

  /// 每个 cid 要挂起的闸（非空时该 cid 的请求等到 complete 才返回）。
  final Map<int, Completer<void>> gates = {};

  /// cid → 返回的弹幕（缺省按 [defaultList]）。
  final Map<int, List<Danmaku>> byCid = {};

  /// 缺省数据：前 40 秒密集（20 条），其余稀疏（4 条）→ 明显的高峰
  List<Danmaku> get defaultList => [
        for (var i = 0; i < 20; i++) _dm(5 + i * 1.5),
        for (var i = 0; i < 4; i++) _dm(100 + i * 20.0),
      ];

  /// 缺省数据为空（验「弹幕为空 → 不画线」）。
  bool empty = false;

  @override
  Future<List<Danmaku>> fetchDanmaku(int cid) async {
    cids.add(cid);
    final gate = gates[cid];
    if (gate != null) await gate.future;
    if (empty) return const [];
    return byCid[cid] ?? defaultList;
  }
}

// ---------------------------------------------------------------------------
// mock HTTP（flutter_test 默认把请求 mock 成 400 → 这里给合法 JSON）
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1HEAT00001","aid":1001,"cid":1001,"duration":200,'
    '"quality":80,'
    '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
    'a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png","sub_url":"https://i0.hdslb.com/bfs/wbi/'
    'e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png"},'
    '"owner":{"mid":1001,"name":"测试UP主","face":""},'
    '"desc":"",'
    '"pages":[{"cid":1001,"part":"第1集","duration":200},'
    '{"cid":1002,"part":"第2集","duration":200}],'
    '"replies":[],"top_replies":[],"cursor":{"is_end":true},'
    '"dash":{"video":[{"baseUrl":"https://x.bilivideo.com/v.m4s"}],'
    '"audio":[{"baseUrl":"https://x.bilivideo.com/a.m4s"}]}}}';

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
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpRequest();

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
      _FakeHttpResponse(utf8.encode(_mockBody));

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
// 平台通道 mock
// ---------------------------------------------------------------------------

class _Rec {
  final List<String> playerMethods = [];
  final List<int> seeks = [];
}

void _installMocks(WidgetTester tester, _Rec rec) {
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
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_whitelist/media'), null));

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));

  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}

/// 挂载播放页并等到取流 + onPrepared + 弹幕设置加载完成。
Future<void> _pumpPlayer(
  WidgetTester tester,
  _Rec rec,
  BiliApi api,
  WhitelistVideo video,
) async {
  // 先卸一棵空树：同名 widget 会走 update 而不是 initState
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(
    home: PlayerPage(
      video: video,
      api: api,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // 弹幕设置读取（500ms 超时兜底）+ 弹幕/曲线 setState 的落地帧
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// 当前画在进度条上的曲线（`HeatCurveBar.curve` 是公开字段）。
HeatCurve? _curveOf(WidgetTester tester) =>
    tester.widget<HeatCurveBar>(find.byKey(HeatCurveBar.widgetKey)).curve;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  testWidgets('数据就绪 → 画出曲线；位置在轨道上方、整层 IgnorePointer',
      (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());

    expect(api.cids, [1001], reason: '热度曲线默认开 → 拉当前集弹幕');
    expect(find.byKey(HeatCurveBar.widgetKey), findsOneWidget,
        reason: '弹幕 + 时长都到齐 → 曲线层出现');

    final curve = _curveOf(tester);
    expect(curve, isNotNull);
    expect(curve!.durationMs, _kDurationMs);
    expect(curve.values.length, 20, reason: '200s / 10s 一桶 = 20 桶');
    expect(curve.values.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-9),
        reason: '归一化后峰值恒为 1');

    // 位置：曲线带在轨道（进度条行正中）**上方**，且不越出进度条盒
    final seekRect = tester.getRect(find.byKey(_kSeekBar));
    final heatRect = tester.getRect(find.byKey(HeatCurveBar.widgetKey));
    expect(heatRect.bottom, lessThanOrEqualTo(seekRect.center.dy),
        reason: '曲线底边不能压到轨道（轨道在 progress 行正中）');
    expect(heatRect.top, greaterThanOrEqualTo(seekRect.top));
    expect(heatRect.width, closeTo(seekRect.width - 4, 0.5),
        reason: '与轨道同宽（两端各内缩半个柄宽 = 2）');

    // 命中：整层被 IgnorePointer 包着（不注册手势、不吃触摸）
    expect(
      find.ancestor(
        of: find.byKey(HeatCurveBar.widgetKey),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
      reason: '曲线层必须 IgnorePointer → 命中穿透给进度条',
    );

    // 进度条行的触摸目标高度没被撑高（40）
    expect(seekRect.height, 40);
  });

  testWidgets('曲线在也不影响进度条：拖动仍照常 seekTo', (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());
    expect(find.byKey(HeatCurveBar.widgetKey), findsOneWidget,
        reason: '前提：曲线已经画出来了');
    rec.seeks.clear();

    // 从轨道 40% 拖到 80%（分步越过 touch slop）
    final bar = tester.getRect(find.byKey(_kSeekBar));
    final y = bar.center.dy;
    final g = await tester.startGesture(Offset(bar.left + bar.width * 0.4, y));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await g.moveBy(Offset(bar.width * 0.4 / 6, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(rec.seeks, isNotEmpty,
        reason: '曲线层若有命中拦截，这里一条 seekTo 都不会收到');
    expect(rec.seeks.last, greaterThan(_kDurationMs * 0.5),
        reason: '落在 40%~80% 区间 → 目标位置过半');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点按进度条也照常跳转（点按路径同样不被拦）', (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());
    rec.seeks.clear();

    final bar = tester.getRect(find.byKey(_kSeekBar));
    await tester.tapAt(Offset(bar.left + bar.width * 0.75, bar.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(rec.seeks, isNotEmpty, reason: '点按跳转仍要提交 seekTo');
    expect(rec.seeks.last, greaterThan(_kDurationMs * 0.6));
  });

  testWidgets('弹幕为空 → 不画线（不画假的平线）', (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi()..empty = true;
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());

    expect(api.cids, [1001], reason: '确实拉过弹幕（不是没拉）');
    expect(find.byKey(HeatCurveBar.widgetKey), findsNothing,
        reason: '没有弹幕数据就不画');
  });

  testWidgets('弹幕还没回来 → 不画；回来后画出', (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi();
    final gate = Completer<void>();
    api.gates[1001] = gate;
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());

    expect(api.cids, [1001], reason: '请求已发出（只是还没完成）');
    expect(find.byKey(HeatCurveBar.widgetKey), findsNothing,
        reason: '数据未就绪 → 不画线（时长已经有了也不画）');

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(HeatCurveBar.widgetKey), findsOneWidget);
    expect(_curveOf(tester), isNotNull);
  });

  testWidgets('开关关闭 → 不画线，且不拉弹幕（不多花请求）', (tester) async {
    // 预置持久化设置：只需关掉热度曲线（其它字段走默认）
    SharedPreferences.setMockInitialValues({
      'danmaku:settings': jsonEncode({'heatCurve': false}),
    });
    final rec = _Rec();
    final api = _FakeDanmakuApi();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());

    expect(find.byKey(HeatCurveBar.widgetKey), findsNothing);
    expect(api.cids, isEmpty,
        reason: '弹幕层关着 + 曲线也关着 → 这条视频不该发弹幕请求');
  });

  testWidgets('切分 P → 用新 cid 的弹幕重算曲线', (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi()
      // 第 1 集：前 40 秒密集；第 2 集：最后 40 秒密集（曲线必然不同）
      ..byCid[1001] = [
        for (var i = 0; i < 20; i++) _dm(5 + i * 1.5),
      ]
      ..byCid[1002] = [
        for (var i = 0; i < 20; i++) _dm(155 + i * 1.5),
      ];
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(
      tester,
      rec,
      api,
      _video(pages: const [
        PageInfo(cid: 1001, part: '第1集', duration: 200),
        PageInfo(cid: 1002, part: '第2集', duration: 200),
      ]),
    );

    expect(api.cids, [1001]);
    final p1 = _curveOf(tester);
    expect(p1, isNotNull);
    expect(p1!.values[1], greaterThan(0.5), reason: '第 1 集片头就是高峰');
    expect(p1.values[18], closeTo(0, 1e-9), reason: '第 1 集片尾没有高峰');

    // 底栏「选集」→ 弹窗里点「第2集」
    await tester.tap(find.text('选集 1/2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('第2集'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 200));

    expect(api.cids, [1001, 1002], reason: '切集要按新 cid 重新拉弹幕');
    final p2 = _curveOf(tester);
    expect(p2, isNotNull);
    expect(identical(p1, p2), isFalse, reason: '换集必须重算（新对象）');
    expect(p2!.durationMs, _kDurationMs);
    expect(p2.values[18], greaterThan(0.5), reason: '第 2 集片尾才是高峰');
    expect(p2.values[1], closeTo(0, 1e-9));
  });

  testWidgets('运行时在弹幕设置里关掉 → 曲线立刻消失（开关文案 ≤42 字）',
      (tester) async {
    final rec = _Rec();
    final api = _FakeDanmakuApi();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, api, _video());
    expect(find.byKey(HeatCurveBar.widgetKey), findsOneWidget);

    // 长按底栏「弹幕」→ 弹幕设置面板
    await tester.longPress(find.text('弹幕'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('热度曲线'), findsOneWidget);

    // 「进度条上方显示弹幕密度高峰（默认开启）」= 19 个非空白字符（上限 42）
    const subtitle = '进度条上方显示弹幕密度高峰（默认开启）';
    expect(subtitle.replaceAll(RegExp(r'\s'), '').characters.length,
        lessThanOrEqualTo(42));
    expect(find.text(subtitle), findsOneWidget);

    await tester.tap(find.text(subtitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(HeatCurveBar.widgetKey), findsNothing,
        reason: '关掉开关要立刻不画（不需要等下一集）');
  });
}
