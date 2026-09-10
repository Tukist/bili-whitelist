// 播放页「块化与动效系统」批次 C 测试：
//   1. 信息行块化：ValueKey('player-info-bar') 仍在、几何仍满足「信息行顶部
//      == 视频区底部」，且外形交给 AppBlock(variant: videoInfo)；
//   2. 信息块「补场」动效：MotionControl 关 → 裸块（树里没有包裹层）；
//      开 → 动画期有 FadeTransition/Transform 包裹，播完卸载（不残留）；
//   3. 封面占位层（「封面放大变成播放界面」的假转场）：cover 为空 → 整层不
//      构建（子树里连 CoverHero/Hero 都没有，也就不发图片请求）；cover 非空
//      → CoverHero 落在与纹理同一个 AspectRatio 盒里、被 IgnorePointer 包住，
//      并在播放器就绪（或 1200ms 兜底超时）后淡出卸载。
//
// 测试环境说明：
// - mock 原生播放器 MethodChannel/EventChannel（create → textureId，
//   setDataSource → onPrepared）→ 取流链路走通、_loaded 可控；
// - mock HttpOverrides（返回合法 JSON）→ 不发真实请求；
// - **一律显式 pump，不用 pumpAndSettle**：页面自身的缓冲转圈/封面图的加载
//   占位都是无限动画，pumpAndSettle 会被它们卡死（与本目录既有播放页测试
//   同一约定）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/theme/app_motion.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/cover_hero.dart';

const String _kBvid = 'BV1INFO000001';
const String _kCover = 'https://i0.hdslb.com/bfs/archive/fake-cover.jpg';

const Key _kVideoArea = ValueKey('player-video-area');
const Key _kInfoBar = ValueKey('player-info-bar');
const Key _kComments = ValueKey('player-comments');

WhitelistVideo _video({String cover = '', String desc = '一段用于占位的简介文本。'}) =>
    WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '块化测试视频',
      cover: cover,
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      desc: desc,
    );

// ---------------------------------------------------------------------------
// mock HTTP：flutter_test 默认把所有请求 mock 成 400，这里换成合法 JSON，
// 让 nav/spi/view/reply/playurl 都走通（封面图的 URL 也会落到这里 → 解码
// 失败 → CoverImage 的 errorBuilder 兜住，不会打到真实网络）。
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1INFO000001","aid":1001,"cid":1001,"duration":200,'
    '"quality":80,'
    '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
    'a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png","sub_url":"https://i0.hdslb.com/bfs/wbi/'
    'e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png"},'
    '"owner":{"mid":1001,"name":"测试UP主","face":""},'
    '"desc":"一段用于占位的简介文本。",'
    '"pages":[{"cid":1001,"part":"","duration":200}],'
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
// 页面 harness：逻辑视口 400x800（dpr=1）→ 16:9 视频区高 225。
// ---------------------------------------------------------------------------

void _installPlayerMock(WidgetTester tester,
    {required bool Function() emitPrepared}) {
  var texId = 0;
  MockStreamHandlerEventSink? eventSink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      if (call.method == 'create') return ++texId;
      if (call.method == 'setDataSource' && emitPrepared()) {
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
      // 注意用块体：箭头体会把赋值结果（sink）当返回值回给平台，
      // 平台侧解码报 "Invalid argument: Instance of 'MockStreamHandlerEventSink'"
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
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
}

/// 挂载播放页（先卸一棵空树：同名 widget 会走 update 而不是 initState）。
Future<void> _pumpPlayer(WidgetTester tester, WhitelistVideo video) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: video)));
  await tester.pump();
}

/// 信息块的祖先 Finder（包裹层在信息块**外面**，所以只能往上看）。
Finder _ancestorOfInfo(Type type) =>
    find.ancestor(of: find.byKey(_kInfoBar), matching: find.byType(type));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  tearDown(MotionControl.reset);

  testWidgets('信息行块化：key 保留、几何不变、外形是 AppBlock(videoInfo)、空封面不建封面层',
      (tester) async {
    // 关闭装饰动效：本用例只验静态结构（包裹层缺席由下一个用例验）
    MotionControl.enabled = false;
    _installPlayerMock(tester, emitPrepared: () => true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, _video());
    await tester.pump(const Duration(milliseconds: 600));

    // ① 三个测试锚点 Key 原样保留
    expect(find.byKey(_kVideoArea), findsOneWidget);
    expect(find.byKey(_kInfoBar), findsOneWidget);
    expect(find.byKey(_kComments), findsOneWidget);

    // ② 几何断言：信息行顶部 == 视频区底部（块上没有外边距）
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    final infoRect = tester.getRect(find.byKey(_kInfoBar));
    expect(infoRect.top, closeTo(videoRect.bottom, 0.5),
        reason: '信息块紧贴视频区下沿');
    expect(infoRect.width, closeTo(videoRect.width, 0.5),
        reason: '通栏铺满（块没有左右外边距）');

    // ③ 信息行的块外形 = AppBlock(videoInfo)（key 就挂在这个块上）
    final block = tester.widget<AppBlock>(find.byKey(_kInfoBar));
    expect(block.variant, AppBlockVariant.videoInfo);
    // 块的子树仍是原来的信息行内容（标题/UP/时长/简介没被拆换）
    expect(
      find.descendant(of: find.byKey(_kInfoBar), matching: find.text('块化测试视频')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(_kInfoBar), matching: find.text('测试UP主')),
      findsOneWidget,
    );

    // ④ MotionControl 关 → 信息块是裸块（上溯不到补场包裹层）
    expect(_ancestorOfInfo(FadeTransition), findsNothing);
    expect(_ancestorOfInfo(Transform), findsNothing);

    // ⑤ cover 为空 → 整层不构建（无 CoverHero、全页无 Hero、无图片节点）
    expect(find.byType(CoverHero), findsNothing);
    expect(find.byType(Hero), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('信息块补场动效：动画期有包裹层，播完卸载（树里不留 Transform）',
      (tester) async {
    MotionControl.enabled = true;
    _installPlayerMock(tester, emitPrepared: () => true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, _video());
    // 起步：控制器已 forward 但还在 kInfoBlockDelay(120ms) 的延迟段内
    await tester.pump(const Duration(milliseconds: 30));
    expect(_ancestorOfInfo(FadeTransition), findsOneWidget,
        reason: '补场期的淡入层在位');
    expect(_ancestorOfInfo(Transform), findsOneWidget, reason: '补场期的微缩放层在位');
    // 注意用 m00（x 轴缩放）取值：Transform.scale 的 z 轴保持 1.0，
    // getMaxScaleOnAxis() 恒为 1.0（拿它断言会永远"已经放大到位"）。
    double scaleX() =>
        tester.widget<Transform>(_ancestorOfInfo(Transform)).transform.storage[0];
    double opacity() => tester
        .widget<FadeTransition>(_ancestorOfInfo(FadeTransition))
        .opacity
        .value;
    expect(scaleX(), closeTo(kInfoBlockScaleFrom, 0.001),
        reason: '延迟段停在起点 96%');
    expect(opacity(), 0.0, reason: '延迟段还没开始淡入');

    // 延迟走完后的中段：淡入中、放大中（两端都不在极值）
    await tester.pump(const Duration(milliseconds: 260));
    expect(opacity(), greaterThan(0.0));
    expect(opacity(), lessThan(1.0));
    expect(scaleX(), greaterThan(kInfoBlockScaleFrom));
    expect(scaleX(), lessThan(1.0));

    // 走完全长（延迟 120 + 时长 320）→ completed → setState 卸掉包裹层
    await tester.pump(const Duration(milliseconds: 400));
    expect(_ancestorOfInfo(FadeTransition), findsNothing,
        reason: '播完卸载：不留 FadeTransition');
    expect(_ancestorOfInfo(Transform), findsNothing,
        reason: '播完卸载：不留 Transform（不动的块不付合成代价）');

    // 卸载后信息块本身与几何都不变
    expect(find.byKey(_kInfoBar), findsOneWidget);
    expect(tester.widget<AppBlock>(find.byKey(_kInfoBar)).variant,
        AppBlockVariant.videoInfo);
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    expect(tester.getRect(find.byKey(_kInfoBar)).top,
        closeTo(videoRect.bottom, 0.5));
  });

  testWidgets('封面占位层：非空封面 → Hero 落点对齐视频盒 + IgnorePointer + 就绪/超时后淡出',
      (tester) async {
    MotionControl.enabled = true;
    var emitPrepared = true;
    _installPlayerMock(tester, emitPrepared: () => emitPrepared);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    // ① 播放器就绪 → 封面层淡出卸载
    await _pumpPlayer(tester, _video(cover: _kCover));
    expect(find.byType(CoverHero), findsOneWidget, reason: '有封面 → 封面占位层在位');
    expect(find.byType(Hero), findsOneWidget);

    // tag 与源端同一工厂（卡片 → 播放页能配上对）
    final hero = tester.widget<Hero>(find.byType(Hero));
    expect(hero.tag, coverHeroTag(_kBvid));

    // IgnorePointer 必须在：本层是 opaque 命中区，不忽略就会吃掉「点按显隐/
    // 恢复画面」（它压在听视频占位层之上）
    final ignoreFinder = find.ancestor(
      of: find.byType(CoverHero),
      matching: find.byType(IgnorePointer),
    );
    expect(ignoreFinder, findsWidgets, reason: '封面层被 IgnorePointer 包住');
    expect(tester.widgetList<IgnorePointer>(ignoreFinder).first.ignoring, isTrue);

    // 落点：与纹理同一个 AspectRatio 盒（16:9 充满 400x225 视频区）
    final videoRect = tester.getRect(find.byKey(_kVideoArea));
    final coverRect = tester.getRect(find.byType(CoverHero));
    expect(coverRect.width, closeTo(videoRect.width, 0.5));
    expect(coverRect.height, closeTo(videoRect.height, 0.5));
    expect(coverRect.center, videoRect.center);

    // onPrepared 已触发淡出 → 等 kCoverFadeOutDur(220ms) 后整层移出树
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CoverHero), findsNothing, reason: '就绪后封面层卸载');

    // ② 播放器一个回调都不来 → 1200ms 兜底超时同样淡出（防封面永驻）
    emitPrepared = false;
    await _pumpPlayer(tester, _video(cover: _kCover));
    expect(find.byType(CoverHero), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.byType(CoverHero), findsOneWidget, reason: '900ms 未到兜底时限');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CoverHero), findsNothing, reason: '1200ms 兜底超时后卸载');

    // ③ 空封面：同一条路径不建层（不发图片请求）
    await _pumpPlayer(tester, _video());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CoverHero), findsNothing);
    expect(find.byType(Hero), findsNothing);
    expect(find.byType(Image), findsNothing);
  });
}
