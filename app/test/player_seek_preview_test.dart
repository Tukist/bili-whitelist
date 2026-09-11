// 播放页「拖动进度条显示缩略图预览」widget 测试。
//
// 覆盖：
//   1. 服务就绪 → 拖动进度条弹出预览浮层（缩略图 + 时间），松手立即消失；
//   2. 多 P：prepare 用 **1-based 分 P 序号**（进页与切集两条路，接口约定易错点）；
//   3. **服务不可用（prepare 抛错）→ 降级**：拖动只显示时间气泡、无缩略图、
//      不崩、不阻塞拖动（松手照常 seekTo）；
//   4. 浮层水平跟随手指，且两端夹在轨道内（不越出屏幕）；
//   5. 非全屏 / 全屏两档气泡尺寸不同（120×67.5 vs 180×101.25，16:9 不拉伸）；
//   6. 浮层是 IgnorePointer（纯展示，绝不参与命中）；
//   7. **跨张丢弃**：位置跳到另一张雪碧图后，上一张的迟到结果不得覆盖新帧
//      （真实服务挂闸一例 + 脚本化时序一例）；
//   8. 节流：同一格（≈同一秒）内连续拖动不重复发请求；
//   9. **同张图内换格：先回来的结果也能落地**（落地看「还是不是当前这张图」，
//      不看请求序号），且落地时用**当前位置**重算裁剪矩形 —— 本文件的核心
//      修复断言；
//  10. prepare 就绪后预取「当前位置」那一张雪碧图 → 首次拖动直接有图、不重复下载。
//
// 测试环境说明（与 player_seek_gesture_test.dart 同款骨架）：
// - mock 原生播放器 MethodChannel/EventChannel（create → textureId，
//   setDataSource → onPrepared 带 durationMs）→ 取流走通、时长已知；
// - mock bili_whitelist/media（亮度/音量基准，本文件用不到但不能少）；
// - mock SystemChannels.platform（进/退全屏会调方向与 UI 模式）；
// - mock HttpOverrides（返回合法 JSON）→ 不发真实请求；
// - 预览服务经 `PlayerPage(videoShotService:)` **注入**（fetcher/loader/decoder
//   全 fake，不触网、不需要图片文件），这样「服务可用 / 不可用」两条路都能
//   精确控制；
// - 「同一张图内换格、先发出的请求先回来」这种时序用**脚本化服务**
//   [_ScriptedShotService] 造（每个请求什么时候完成、以什么帧完成都由测试
//   决定）：真实服务里同一张图的并发请求共享一个 in-flight future，永远不会
//   出现这种完成顺序，而页面判「迟到结果该不该落地」恰恰必须与完成顺序无关。
// - **一律显式 pump，不用 pumpAndSettle**：页面自身的缓冲转圈 / 封面图加载
//   占位都是无限动画，pumpAndSettle 会被它们卡死（与本目录既有播放页测试
//   同一约定）。
//
// 几何（不硬编码屏幕坐标）：竖屏视口 411×914（dpr=1）→ 16:9 视频区高
// ≈231.19dp；进度条的矩形运行时用 `player-seek-bar` 这个 key 取，起手点与
// 落点都按该矩形比例算；全屏换成 914×411（横屏全屏）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/video_shot.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/video_shot_service.dart';

const String _kBvid = 'BV1SHOT00001';

/// 取流时长（ms）：onPrepared 与视频 duration 一致（200s）。
const int _kDurationMs = 200000;

/// 预览浮层的锚点（与 player_page.dart 里的字面量 key 一致，同
/// 'player-video-area' 的跨文件约定）。
const Key _kSeekBar = ValueKey('player-seek-bar');
const Key _kOverlay = ValueKey('seek-preview-overlay');
const Key _kThumb = ValueKey('seek-preview-thumb');
const Key _kTime = ValueKey('seek-preview-time');

WhitelistVideo _video({List<PageInfo>? pages}) => WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '拖动预览测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      pages: pages,
    );

// ---------------------------------------------------------------------------
// 预览服务测试替身：fetcher / loader / decoder 全 fake
// ---------------------------------------------------------------------------

/// 一帧 16:9 的雪碧图样本：xLen=10 列、单格 16×9 → 解码后 160×90 时
/// 缩放系数 = (160/10)/16 = 1，裁剪矩形恒为 16×9（16:9，浮层按它折算高度）。
VideoShotInfo _info({int spriteCount = 1, int shotCount = 60}) => VideoShotInfo(
      spriteUrls: List.generate(
        spriteCount,
        (i) => 'https://i0.hdslb.com/bfs/videoshot/sprite$i.jpg',
      ),
      xLen: 10,
      yLen: 1,
      xSize: 16,
      ySize: 9,
      indexSeconds: List.generate(shotCount, (i) => i * 5),
    );

Future<ui.Image> _makeImage(int width, int height) async {
  final buffer =
      await ui.ImmutableBuffer.fromUint8List(Uint8List(width * height * 4));
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// 预览服务替身：记录调用、可按 URL 挂起某张雪碧图的加载（构造迟到时序）。
class _ShotHarness {
  /// prepare 收到的 `bvid#index`（断言 1-based 分 P 序号用）。
  final List<String> fetchCalls = <String>[];

  /// 元信息（null + [fetchError] 非空 = prepare 失败路径）。
  VideoShotInfo? info;
  Object? fetchError;

  /// 每张雪碧图的加载闸门（url → Completer）：挂着的张不会返回，
  /// 直到测试 [release] 才放行。
  final Map<String, Completer<void>> gates = {};

  /// 实际下载过的雪碧图 URL（**唯一性/次数断言**用：节流与缓存命中）。
  final List<String> loadedUrls = <String>[];

  late final VideoShotService service;

  _ShotHarness() {
    service = VideoShotService(
      fetcher: _fetch,
      bytesLoader: _load,
      decoder: _decode,
      disposer: (image) => image.dispose(),
    );
  }

  /// 放行某张雪碧图的加载（该张必须已挂闸）。
  void release(int spriteIndex) {
    gates['https://i0.hdslb.com/bfs/videoshot/sprite$spriteIndex.jpg']
        ?.complete();
  }

  void gate(int spriteIndex) {
    gates['https://i0.hdslb.com/bfs/videoshot/sprite$spriteIndex.jpg'] =
        Completer<void>();
  }

  Future<VideoShotInfo> _fetch(String bvid, int index) async {
    fetchCalls.add('$bvid#$index');
    final err = fetchError;
    if (err != null) throw err;
    return info!;
  }

  Future<Uint8List> _load(String url) async {
    loadedUrls.add(url);
    final g = gates[url];
    if (g != null) await g.future;
    return Uint8List.fromList(const [1, 2, 3, 4]);
  }

  Future<ui.Image> _decode(
    Uint8List bytes,
    int Function(int srcWidth, int srcHeight) pickTargetWidth,
  ) =>
      _makeImage(160, 90);
}

/// 服务不可用的替身：元信息接口直接抛错（等价于接口挂了/网络断了）。
_ShotHarness _brokenHarness() => _ShotHarness()
  ..info = _info()
  ..fetchError = Exception('videoshot 接口挂了');

/// 造一帧：按 [info] 的元信息算 [shot] 那一格的裁剪矩形（与服务层同款算法）。
SeekPreviewFrame _frame(VideoShotInfo info, int shot, ui.Image sprite) {
  final cell = info.cellForShot(shot);
  final scale = VideoShotService.cellScale(spriteWidth: sprite.width, info: info);
  return SeekPreviewFrame(
    sprite: sprite,
    srcRect: Rect.fromLTWH(
      cell.left * scale,
      cell.top * scale,
      cell.width * scale,
      cell.height * scale,
    ),
    seconds: info.indexSeconds[shot],
    spriteWidth: sprite.width,
    spriteHeight: sprite.height,
    spriteIndex: cell.spriteIndex,
  );
}

/// [ms] 对应的缩略图格序号。
int _shotAt(VideoShotInfo info, int ms) =>
    info.shotIndexForSeconds(ms <= 0 ? 0 : ms ~/ 1000);

/// 脚本化预览服务：只接管页面真正用到的四个接口（info / isReady / prepare /
/// frameAtMs），**每个请求何时完成、以什么帧完成全由测试决定**。
///
/// 为什么需要它：真实服务里同一张雪碧图的并发请求共享同一个 in-flight
/// future（服务层 `_spriteImage` 的去重），永远造不出「先发出的请求先回来」；
/// 而页面判「迟到结果该不该落地」必须与请求的完成顺序无关。
class _ScriptedShotService extends VideoShotService {
  _ScriptedShotService(this.scriptInfo);

  final VideoShotInfo scriptInfo;

  /// 每次 frameAtMs 收到的 ms（按调用顺序）；索引与 [pending] 一一对应。
  final List<int> requestedMs = <int>[];
  final List<Completer<SeekPreviewFrame?>> pending = [];

  bool _stubDisposed = false;

  @override
  VideoShotInfo? get info => scriptInfo;

  @override
  bool get isReady => !_stubDisposed;

  @override
  Future<void> prepare(String bvid, {int index = 1}) async {}

  @override
  Future<SeekPreviewFrame?> frameAtMs(int ms) {
    requestedMs.add(ms);
    final completer = Completer<SeekPreviewFrame?>();
    pending.add(completer);
    return completer.future;
  }

  /// 完成第 [i] 个请求（i 从 0 起，按发起顺序）。
  void complete(int i, SeekPreviewFrame? frame) => pending[i].complete(frame);

  @override
  void dispose() {
    _stubDisposed = true;
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// mock HTTP：flutter_test 默认把所有请求 mock 成 400，这里换成合法 JSON，
// 让 nav/spi/view/reply/playurl 都走通（不发真实请求）
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1SHOT00001","aid":1001,"cid":1001,"duration":200,'
    '"quality":80,'
    '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
    'a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png","sub_url":"https://i0.hdslb.com/bfs/wbi/'
    'e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png"},'
    '"owner":{"mid":1001,"name":"测试UP主","face":""},'
    '"desc":"",'
    '"pages":[{"cid":1001,"part":"","duration":200},'
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

/// 挂载播放页并等到取流 + onPrepared 完成（时长已知 = 进度条可拖）。
Future<void> _pumpPlayer(
  WidgetTester tester,
  _Rec rec,
  WhitelistVideo video, {
  VideoShotService? service,
  int initialPageIndex = 0,
}) async {
  // 先卸一棵空树：同名 widget 会走 update 而不是 initState（同既有播放页测试）
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(
    home: PlayerPage(
      video: video,
      initialPageIndex: initialPageIndex,
      videoShotService: service,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // prepare 是异步的：多跑几帧让元信息到位（fake fetcher 立即返回）
  await tester.pump();
}

// ---------------------------------------------------------------------------
// 拖动助手：按「轨道局部 x」精确落点（分步越过 touch slop 才算拖动）
// ---------------------------------------------------------------------------

/// 放行「真实异步」并让结果落进树里。
///
/// 为什么必须 `runAsync`：预览帧的解码走 `dart:ui` 引擎调用
/// （`ImmutableBuffer.fromUint8List` / `instantiateCodec` / `getNextFrame`），
/// 在 `testWidgets` 的假时钟里这些 Future **不会自己完成**（flutter_test 的
/// 已知约束），只有 runAsync 能让真实事件循环转起来。这是测试环境问题，
/// 不是实现问题——服务层单测（纯 `test`）无需 runAsync。
Future<void> _settleFrames(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)));
  await tester.pump();
  await tester.pump();
}

class _SeekDrag {
  _SeekDrag(this._tester, this._gesture, this._pos);

  final WidgetTester _tester;
  final TestGesture _gesture;
  Offset _pos;
  bool _primed = false;

  /// 把手指移到轨道局部 x（全局 x = 轨道左缘 + x），最后一步精确落点。
  Future<void> toX(double x, {int steps = 4}) async {
    final bar = _tester.getRect(find.byKey(_kSeekBar));
    final target = Offset(bar.left + x, _pos.dy);
    if (!_primed) {
      // 第一次移动必须累计越过 touch slop（18px）才会被识别成「拖动」；
      // 若首次落点恰好就是起手点（delta 为 0），先横向抖一下再回到落点。
      _primed = true;
      const prime = Offset(40, 0);
      await _gesture.moveBy(prime);
      await _tester.pump();
      _pos += prime;
    }
    final delta = target - _pos;
    final step = delta / steps.toDouble();
    for (var i = 0; i < steps; i++) {
      await _gesture.moveBy(step);
      await _tester.pump();
      _pos += step;
    }
    // 帧请求是异步的：放行真实异步 + 多跑两帧让结果落进树里
    await _settleFrames(_tester);
  }

  Future<void> up() async {
    await _gesture.up();
    await _tester.pump();
    await _tester.pump(const Duration(milliseconds: 400));
  }
}

/// 从轨道局部 x = [fromX] 按下，返回拖动句柄（拖动中可断言浮层）。
Future<_SeekDrag> _startSeekDrag(WidgetTester tester, double fromX) async {
  final bar = tester.getRect(find.byKey(_kSeekBar));
  final pos = Offset(bar.left + fromX, bar.center.dy);
  final g = await tester.startGesture(pos);
  await tester.pump();
  return _SeekDrag(tester, g, pos);
}

/// 浮层矩形（key 挂在 `_SeekPreviewOverlay` 上 → 取其最近 RenderObject）。
Rect _overlayRect(WidgetTester tester) => tester.getRect(find.byKey(_kOverlay));

/// 浮层里的时间文字（判「降级只有时间气泡」时读它）。
String _timeText(WidgetTester tester) {
  final text = tester.widget<Text>(find.descendant(
    of: find.byKey(_kTime),
    matching: find.byType(Text),
  ));
  return text.data ?? '';
}

/// 当前画在缩略图上的帧（`_SeekPreviewPainter.frame` 是公开命名成员，
/// 私有类不能直接引用 → 走 dynamic；**只用于测试断言**）。
dynamic _paintedFrame(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(find.byKey(_kThumb));
  final painter = paint.painter;
  return (painter as dynamic).frame;
}

/// 当前画在缩略图上的帧的秒数。
int _paintedSeconds(WidgetTester tester) => _paintedFrame(tester).seconds as int;

/// 当前画在缩略图上的帧属于第几张雪碧图。
int _paintedSprite(WidgetTester tester) =>
    _paintedFrame(tester).spriteIndex as int;

/// 当前画在缩略图上的帧的裁剪矩形。
Rect _paintedSrcRect(WidgetTester tester) =>
    _paintedFrame(tester).srcRect as Rect;

/// 由时间气泡的文字（'m:ss' / 'h:mm:ss'）反推**当前位置**（ms）。
///
/// 用它而不是读私有 `_positionMs`：既拿到位置做期望值，又顺带验证气泡时间
/// 与「当前位置」一致（两者本就是同一份数据）。
int _timeTextMs(WidgetTester tester) {
  var seconds = 0;
  for (final part in _timeText(tester).split(':')) {
    seconds = seconds * 60 + int.parse(part);
  }
  return seconds * 1000;
}

/// 放行「脚本化服务」刚完成的请求，并把结果画进树里。
///
/// 为什么要两帧：完成回调是微任务，而 `pump` 是「先（必要时）建帧 → 最后 flush
/// 微任务」，所以回调里 setState 落下的脏标记要到**下一帧**才被构建（与
/// [_settleFrames] 同款处理；那边靠 runAsync 让真实解码完成）。
Future<void> _pumpCompleted(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = oldOverrides);
  });

  testWidgets('服务就绪：拖动进度条 → 弹缩略图 + 时间浮层；松手立即消失；'
      'prepare 用 1-based 分 P 序号', (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    // 进页即 prepare，且分 P 序号是 1-based（接口约定：0 会拿到空 index）
    expect(h.fetchCalls, ['$_kBvid#1'], reason: '进页 prepare 当前分 P（1-based）');
    expect(h.service.isReady, isTrue, reason: 'fake fetcher 已给元信息');

    rec.seeks.clear();
    final bar = tester.getRect(find.byKey(_kSeekBar));
    expect(bar.height, 44, reason: '进度条触摸目标高 44');
    expect(find.byKey(_kOverlay), findsNothing, reason: '未拖动时没有浮层');

    final drag = await _startSeekDrag(tester, bar.width * 0.5);
    await drag.toX(bar.width * 0.5);

    expect(find.byKey(_kOverlay), findsOneWidget, reason: '拖动中出现预览浮层');
    expect(find.byKey(_kThumb), findsOneWidget, reason: '服务就绪 → 有缩略图');
    expect(find.byKey(_kTime), findsOneWidget, reason: '时间文字恒有');
    expect(_timeText(tester), matches(RegExp(r'^\d+:\d{2}$')),
        reason: '时间是 mm:ss / h:mm:ss 格式');
    expect(_paintedSeconds(tester), greaterThan(0), reason: '画的是当前格');

    // 浮层在进度条**上方**（不压在进度条上、更不越到屏幕外）
    final overlay = _overlayRect(tester);
    expect(overlay.bottom, lessThanOrEqualTo(bar.top - 7.9),
        reason: '浮层底边在进度条上方留 ~8dp 间隙');
    expect(overlay.top, greaterThanOrEqualTo(0), reason: '不越出屏幕顶部');

    await drag.up();
    expect(find.byKey(_kOverlay), findsNothing, reason: '松手立即隐藏浮层');
    expect(rec.seeks, isNotEmpty, reason: '松手照常 seekTo（原有语义未动）');
  });

  testWidgets('多 P：initialPageIndex=1 → prepare 的分 P 序号是 2（1-based）',
      (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(
      tester,
      rec,
      _video(pages: const [
        PageInfo(cid: 1001, part: '第1集', duration: 200),
        PageInfo(cid: 1002, part: '第2集', duration: 200),
      ]),
      service: h.service,
      initialPageIndex: 1,
    );

    expect(h.fetchCalls, ['$_kBvid#2'], reason: '第 2 集 → index 2（1-based）');
  });

  testWidgets('换分 P：切集后按新分 P 重新 prepare（index 跟着变）',
      (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(
      tester,
      rec,
      _video(pages: const [
        PageInfo(cid: 1001, part: '第1集', duration: 200),
        PageInfo(cid: 1002, part: '第2集', duration: 200),
      ]),
      service: h.service,
    );
    expect(h.fetchCalls, ['$_kBvid#1'], reason: '进页 prepare 第 1 集');

    // 底栏「选集」→ 弹窗里点「第2集」
    await tester.tap(find.text('选集 1/2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第2集'), findsOneWidget, reason: '选集弹窗已打开');

    await tester.tap(find.text('第2集'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(h.fetchCalls, ['$_kBvid#1', '$_kBvid#2'],
        reason: '切集必须重新 prepare，且 index 是 1-based 的新分 P 序号');
  });

  testWidgets('服务不可用（prepare 抛错）→ 降级：只有时间气泡、无缩略图、'
      '不崩、拖动正常结束（仍 seekTo）', (tester) async {
    final rec = _Rec();
    final h = _brokenHarness();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);
    expect(h.service.isReady, isFalse, reason: '接口抛错 → 服务未就绪');
    expect(tester.takeException(), isNull, reason: '失败不得抛到 UI');

    rec.seeks.clear();
    final bar = tester.getRect(find.byKey(_kSeekBar));
    final drag = await _startSeekDrag(tester, bar.width * 0.4);
    await drag.toX(bar.width * 0.8);

    expect(find.byKey(_kOverlay), findsOneWidget, reason: '未就绪也要有时间气泡');
    expect(find.byKey(_kTime), findsOneWidget);
    expect(find.byKey(_kThumb), findsNothing, reason: '降级：没有缩略图');
    expect(h.loadedUrls, isEmpty, reason: '未就绪不发任何图片请求');

    await drag.up();
    expect(tester.takeException(), isNull, reason: '整段拖动不崩');
    expect(find.byKey(_kOverlay), findsNothing, reason: '松手浮层消失');
    expect(rec.seeks, isNotEmpty, reason: '降级不影响 seekTo（拖动照常结束）');
    expect(rec.seeks.last, greaterThan(0), reason: '落在中点之后 → 目标 > 0');
  });

  testWidgets('浮层水平跟随手指，两端夹在轨道内（不越出屏幕）', (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    final bar = tester.getRect(find.byKey(_kSeekBar));
    final screen = tester.view.physicalSize.width;
    final drag = await _startSeekDrag(tester, bar.width * 0.2);
    await drag.toX(bar.width * 0.2);
    final leftRect = _overlayRect(tester);

    await drag.toX(bar.width * 0.5);
    final midRect = _overlayRect(tester);

    await drag.toX(bar.width * 0.8);
    final rightRect = _overlayRect(tester);

    expect(leftRect.left, lessThan(midRect.left), reason: '浮层跟随手指右移');
    expect(midRect.left, lessThan(rightRect.left), reason: '同上（单调）');

    // 夹取：任何位置都不越出屏幕（两端由轨道端点兜住）
    for (final r in [leftRect, midRect, rightRect]) {
      expect(r.left, greaterThanOrEqualTo(0), reason: '不越出屏幕左缘');
      expect(r.right, lessThanOrEqualTo(screen), reason: '不越出屏幕右缘');
    }

    // 拖到最右端：气泡右缘不超过轨道右缘（夹到不越界）
    await drag.toX(bar.width);
    final edge = _overlayRect(tester);
    expect(edge.right, lessThanOrEqualTo(bar.right + 0.5),
        reason: '最右端拖动 → 夹在轨道内（= 屏幕内）');

    // 拖到最左端：气泡左缘不低于轨道左缘
    await drag.toX(0);
    final edgeL = _overlayRect(tester);
    expect(edgeL.left, greaterThanOrEqualTo(bar.left - 0.5),
        reason: '最左端拖动 → 夹在轨道内');

    await drag.up();
  });

  testWidgets('气泡尺寸：非全屏 120×67.5（16:9）；全屏 180×101.25（不得拉伸）',
      (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    // 非全屏（竖屏置顶）：120 宽、按帧 16:9 折算 67.5 高
    final compactBar = tester.getRect(find.byKey(_kSeekBar));
    final compactDrag = await _startSeekDrag(tester, compactBar.width * 0.5);
    await compactDrag.toX(compactBar.width * 0.5);
    final compact = tester.getRect(find.byKey(_kThumb));
    expect(compact.width, closeTo(120, 0.01), reason: '非全屏缩略图宽 120');
    expect(compact.height, closeTo(67.5, 0.01),
        reason: '高按帧比例折算（16:9 → 67.5），不拉伸');
    await compactDrag.up();

    // 进全屏（底栏全屏按钮）→ 横屏全屏 914×411
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget, reason: '已进全屏');
    tester.view.physicalSize = const Size(914, 411);
    await tester.pump();

    final fullBar = tester.getRect(find.byKey(_kSeekBar));
    final fullDrag = await _startSeekDrag(tester, fullBar.width * 0.5);
    await fullDrag.toX(fullBar.width * 0.5);
    final full = tester.getRect(find.byKey(_kThumb));
    expect(full.width, closeTo(180, 0.01), reason: '全屏缩略图宽 180');
    expect(full.height, closeTo(101.25, 0.01), reason: '16:9 → 101.25');
    expect(full.width, greaterThan(compact.width), reason: '两档尺寸不同');
    expect(full.height, greaterThan(compact.height));

    // 全屏空间足：浮层仍在进度条上方且不越出屏幕
    final overlay = _overlayRect(tester);
    expect(overlay.bottom, lessThanOrEqualTo(fullBar.top - 7.9));
    expect(overlay.top, greaterThanOrEqualTo(0), reason: '全屏也不越出屏幕顶部');

    await fullDrag.up();
  });

  testWidgets('浮层是 IgnorePointer：不拦截触摸（拖到底仍 seekTo）', (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    rec.seeks.clear();
    final bar = tester.getRect(find.byKey(_kSeekBar));
    final drag = await _startSeekDrag(tester, bar.width * 0.5);
    await drag.toX(bar.width * 0.5);
    expect(find.byKey(_kOverlay), findsOneWidget);

    // 浮层整层包在 IgnorePointer 里（纯展示）
    expect(
      find.descendant(
        of: find.byKey(_kOverlay),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
      reason: '浮层根节点必须是 IgnorePointer',
    );

    // 行为复核：浮层在屏幕上时，继续拖动仍然跟手 + 松手仍提交
    await drag.toX(bar.width * 0.7);
    final moved = _overlayRect(tester);
    expect(moved.left, greaterThan(0), reason: '浮层随手指继续移动');
    await drag.up();
    expect(rec.seeks, isNotEmpty, reason: '拖动未被浮层阻塞（seekTo 照常）');
  });

  testWidgets('跨张丢弃：跳到另一张雪碧图后，上一张的迟到结果不得覆盖新帧',
      (tester) async {
    final rec = _Rec();
    // 两张雪碧图：第 0 张挂闸（慢），第 1 张直通（快）
    final h = _ShotHarness()
      ..info = _info(spriteCount: 2)
      ..gate(0);
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    final bar = tester.getRect(find.byKey(_kSeekBar));
    final drag = await _startSeekDrag(tester, bar.width * 0.05);
    // ① 5s 附近 → shot 1（第 0 张雪碧图，请求挂起）
    await drag.toX(bar.width * 0.025);
    expect(find.byKey(_kOverlay), findsOneWidget);
    expect(find.byKey(_kThumb), findsNothing,
        reason: '慢请求未回来 → 先只有时间气泡');

    // ② 拖到 55s 附近 → shot 11（第 1 张雪碧图，直通）→ 先拿到新帧
    await drag.toX(bar.width * 0.275);
    expect(find.byKey(_kThumb), findsOneWidget, reason: '新位置的帧先到达');
    final secondsBeforeLate = _paintedSeconds(tester);
    expect(_paintedSprite(tester), 1, reason: '画的是第 1 张雪碧图');

    // ③ 放行慢的旧请求（第 0 张）：图已不是当前位置需要的那张 → 必须丢弃
    h.release(0);
    await _settleFrames(tester);
    await tester.pump();

    expect(_paintedSeconds(tester), secondsBeforeLate,
        reason: '迟到的旧图不得覆盖新帧（跨张丢弃：落地条件是图号匹配）');
    expect(_paintedSprite(tester), 1, reason: '仍是第 1 张，没被第 0 张顶掉');

    await drag.up();
    expect(tester.takeException(), isNull, reason: '迟到帧 + 松手后清理都不崩');
  });

  testWidgets('同张雪碧图内换格：先回来的结果也能落地，且按当前位置重画',
      (tester) async {
    final rec = _Rec();
    // 脚本化服务：元信息 2 张图（每张 10 格 × 5s）——本用例全程留在第 0 张（<50s）
    final info = _info(spriteCount: 2);
    final svc = _ScriptedShotService(info);
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    // 真 ui.Image（解码器调用要走真实事件循环）
    final sprite = (await tester.runAsync(() => _makeImage(160, 90)))!;
    addTearDown(sprite.dispose);

    await _pumpPlayer(tester, rec, _video(), service: svc);

    final bar = tester.getRect(find.byKey(_kSeekBar));
    final drag = await _startSeekDrag(tester, bar.width * 0.1);
    // 拖到轨道 5% 处（10s → shot 2，仍是第 0 张）：途中每换一格发一次请求
    await drag.toX(bar.width * 0.05);

    expect(svc.requestedMs.length, greaterThanOrEqualTo(2),
        reason: '同张图内连续换格 → 多次请求（这正是现场「每换一格 ++序号」）');
    final firstMs = svc.requestedMs.first;
    final currentShot = _shotAt(info, _timeTextMs(tester));
    expect(_shotAt(info, firstMs), isNot(currentShot),
        reason: '先发出的请求对应的格已经不是当前格（否则用例证明不了什么）');

    // 只有时间气泡（所有请求都还没回来）
    expect(find.byKey(_kThumb), findsNothing, reason: '请求都在路上');

    // ① 让**先发出**的那个请求先回来：同张图 → 仍然可用，必须落地
    svc.complete(0, _frame(info, _shotAt(info, firstMs), sprite));
    await _pumpCompleted(tester);

    expect(find.byKey(_kThumb), findsOneWidget,
        reason: '同一张雪碧图的迟到结果必须落地（按请求序号判就会整条丢掉）');

    // ② 落地时用**当前位置**重算裁剪矩形：画的是手指此刻所指的格
    final cell = info.cellForShot(currentShot);
    final scale = VideoShotService.cellScale(spriteWidth: sprite.width, info: info);
    expect(_paintedSeconds(tester), info.indexSeconds[currentShot],
        reason: '秒数跟着当前位置，不是发起请求时那一格');
    expect(
      _paintedSrcRect(tester),
      Rect.fromLTWH(
        cell.left * scale,
        cell.top * scale,
        cell.width * scale,
        cell.height * scale,
      ),
      reason: '裁剪矩形也重算到当前位置的格（而不是发起时那一格）',
    );

    // ③ 后发的请求再回来也不该把画面弄乱
    svc.complete(1, _frame(info, _shotAt(info, svc.requestedMs[1]), sprite));
    await _pumpCompleted(tester);
    expect(_paintedSeconds(tester), info.indexSeconds[currentShot],
        reason: '同张图的结果都指向当前位置，画出来一致');

    await drag.up();
    expect(tester.takeException(), isNull, reason: '整段拖动不崩');
  });

  testWidgets('跨张丢弃（脚本化时序）：跳到第 1 张后，第 0 张的迟到结果不得覆盖',
      (tester) async {
    final rec = _Rec();
    final info = _info(spriteCount: 2);
    final svc = _ScriptedShotService(info);
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    final sprite = (await tester.runAsync(() => _makeImage(160, 90)))!;
    addTearDown(sprite.dispose);

    await _pumpPlayer(tester, rec, _video(), service: svc);

    final bar = tester.getRect(find.byKey(_kSeekBar));
    // ① 先在第 0 张图内（10s 附近）拖一段 → 请求挂起
    final drag = await _startSeekDrag(tester, bar.width * 0.05);
    await drag.toX(bar.width * 0.05);
    expect(svc.requestedMs, isNotEmpty, reason: '第 0 张图的请求已发出');
    final sprite0Requests = svc.requestedMs.length;

    // ② 跳到第 1 张图（120s > 末帧 95s → 钳到末格 shot 19）并让它先回来
    await drag.toX(bar.width * 0.6);
    expect(svc.requestedMs.length, greaterThan(sprite0Requests),
        reason: '换张后按新位置发新请求');
    final lastIndex = svc.pending.length - 1;
    svc.complete(lastIndex, _frame(info, _shotAt(info, svc.requestedMs[lastIndex]), sprite));
    await _pumpCompleted(tester);
    expect(find.byKey(_kThumb), findsOneWidget, reason: '第 1 张图的帧先落地');
    expect(_paintedSprite(tester), 1);

    // ③ 第 0 张图的请求随后回来：图已不是当前位置需要的 → 不得覆盖
    svc.complete(0, _frame(info, _shotAt(info, svc.requestedMs[0]), sprite));
    await _pumpCompleted(tester);
    expect(_paintedSprite(tester), 1, reason: '第 0 张的迟到结果被丢弃');
    expect(_paintedSeconds(tester), info.indexSeconds[_shotAt(info, svc.requestedMs[lastIndex])],
        reason: '画面仍是第 1 张那张（不会显示错误区段）');

    await drag.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('prepare 就绪后预取「当前位置」那一张雪碧图 → 首次拖动直接有图、不重复下载',
      (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info(spriteCount: 2);
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    expect(
      h.loadedUrls,
      ['https://i0.hdslb.com/bfs/videoshot/sprite0.jpg'],
      reason: '元信息就绪即预取当前位置（0ms → 第 0 张），用户最可能拖到这一带',
    );

    // 第一次拖动就落在预取好的那张图内 → 缩略图立刻有（不再现下现解）
    final bar = tester.getRect(find.byKey(_kSeekBar));
    final drag = await _startSeekDrag(tester, bar.width * 0.1);
    await drag.toX(bar.width * 0.2); // 20~40s → shot 4~8，仍是第 0 张
    expect(find.byKey(_kThumb), findsOneWidget, reason: '首次拖动就有缩略图');
    expect(h.loadedUrls.length, 1, reason: '命中预取 → 不重复下载');

    await drag.up();
    expect(tester.takeException(), isNull);
  });

  testWidgets('节流：同一格内连续拖动不重复发请求（每格最多一次）',
      (tester) async {
    final rec = _Rec();
    final h = _ShotHarness()..info = _info();
    _installMocks(tester, rec);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);

    await _pumpPlayer(tester, rec, _video(), service: h.service);

    final bar = tester.getRect(find.byKey(_kSeekBar));
    // 同一格（≈同一秒）内的三次微小移动 + 同一格内的重复落点
    final drag = await _startSeekDrag(tester, bar.width * 0.5);
    await drag.toX(bar.width * 0.5 + 1);
    await drag.toX(bar.width * 0.5 + 2);
    await drag.toX(bar.width * 0.5);

    // 单张雪碧图：整段拖动只应下载一次（缩略图 + in-flight/缓存命中）
    expect(h.loadedUrls.length, 1,
        reason: '节流 + 服务层缓存：同一张雪碧图只下载一次');

    await drag.up();
  });
}
