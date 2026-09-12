// 播放媒体通知 + 耳机按键控制（v2.25.x）widget 测试。
//
// 背景：Android 侧用 media3 的 MediaSession + PlayerNotificationManager 做「B 站式」
// 媒体通知（封面 + 标题 + `UP 名 · 状态` + 快退15s/播放暂停/快进15s/关闭），耳机
// 媒体键由 MediaSession 接收后驱动 ExoPlayer。**Kotlin 那半边 flutter test 覆盖不到**
// （需真机验证，见交付说明），这里覆盖 Dart 侧契约：
//   1. onPrepared → updateNowPlaying 带齐标题/UP 名/封面/状态/playing（通知内容来源），
//      并请求一次通知权限（Android 13+，原生侧自带版本判断）；
//   2. 界面播放/暂停 → updateNowPlaying 跟着翻（通知与界面一致，不会有脏状态）；
//   3. 听视频开关 → 状态文案变「后台听视频省流量」（与 B 站通知副标题一致）；
//   4. 原生回传 onMediaAction=play/pause（通知/耳机按键路径）→ 界面播放态跟着翻；
//   5. onMediaAction=seek（通知快退/快进 15 秒）→ 界面位置跟着走；
//   6. onMediaAction=stop（通知 ✕）→ 界面收成停止态；再点播放 → 重新取流续播；
//   7. 通道 mock 不因新增方法而崩（旧 player_* 测试继续全绿，另见全量测试）。
//   8. v2.25.0 回归：播完（onCompleted）后再播 → tick 轮询定时器必须复活
//      （进度/字幕继续刷新），且任何时刻只有一个 tick（详见末条用例）。
//
// 测试环境（与 player_seek_gesture_test.dart 同款骨架）：
// - mock 原生播放器 MethodChannel/EventChannel（create → textureId，
//   setDataSource → onPrepared 带 durationMs）；
// - mock HttpOverrides（返回合法 JSON）→ 取流链路走通、不发真实请求；
// - 一律显式 pump，不用 pumpAndSettle（页面缓冲转圈/封面占位是无限动画）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/player/bili_dash_player.dart';

const String _kBvid = 'BV1NOTIFY001';
const int _kDurationMs = 200000;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '媒体通知测试视频',
      cover: 'https://i0.hdslb.com/bfs/archive/notify.jpg',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 封面是 `http://` 的视频（B 站部分条目实测就是明文 HTTP）——#3 用。
WhitelistVideo _httpCoverVideo() => const WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '明文封面测试视频',
      cover: 'http://i2.hdslb.com/bfs/archive/d92d77bfa32e2cec57048a6849a7a8b52270d214.jpg',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 记录到的平台调用。
class _Rec {
  /// bili_dash_player 收到的方法名（按顺序）。
  final List<String> playerMethods = [];

  /// updateNowPlaying 的载荷（每次调用一条，按顺序）。
  final List<Map<Object?, Object?>> nowPlaying = [];

  /// getPosition 返回值（tick 轮询用；默认 0 = 不干扰位置断言）。
  int position = 0;

  /// 非 null 时：getPosition 会先等这个门再返回（模拟「在途的 tick」——
  /// 请求发出后、结果回来前播放器已被通知栏 ✕ 停掉）。
  Completer<int>? positionGate;

  /// 完成 [positionGate]（把位置结果放行）。
  void releasePositionGate(int value) {
    final gate = positionGate;
    positionGate = null;
    gate?.complete(value);
  }
}

// ---------------------------------------------------------------------------
// mock HTTP：flutter_test 默认把所有请求 mock 成 400，这里换成合法 JSON，
// 让 nav/spi/view/playurl 都走通（不发真实请求）。
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"bvid":"BV1NOTIFY001","aid":1001,"cid":1001,"duration":200,'
    '"quality":80,'
    '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
    'a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png","sub_url":"https://i0.hdslb.com/bfs/wbi/'
    'e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png"},'
    '"owner":{"mid":1001,"name":"测试UP主","face":""},'
    '"desc":"",'
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
// 平台通道 mock
// ---------------------------------------------------------------------------

/// 播放器通道 mock + 事件回推句柄。
class _Mocks {
  _Mocks(this.rec);

  final _Rec rec;
  MockStreamHandlerEventSink? sink;

  /// 原生分配的 textureId（create 时记录，回推事件要用同一个值）。
  int textureId = 1;

  /// 把一条原生事件推给 Dart（模拟通知/耳机按键触发的原生事件）。
  void emit(String event, {String? action, int positionMs = 0}) {
    sink?.success({
      'event': event,
      'textureId': textureId,
      if (action != null) 'action': action,
      'positionMs': positionMs,
    });
  }

  /// 推一条原生 onPrepared（模拟**每次进 READY** 都会来的准备完成事件：起播、
  /// seek 之后重新缓冲都会走这里）。[playWhenReady] 是原生播放器的真实播放
  /// 意图 —— 暂停态下 seek 会带着 false 上来。
  void emitPrepared({bool playWhenReady = true, int durationMs = _kDurationMs}) {
    sink?.success({
      'event': 'onPrepared',
      'textureId': textureId,
      'width': 1280,
      'height': 720,
      'durationMs': durationMs,
      'playWhenReady': playWhenReady,
    });
  }

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        if (call.method == 'create') return textureId;
        rec.playerMethods.add(call.method);
        switch (call.method) {
          case 'setDataSource':
            final map = call.arguments as Map;
            textureId = (map['textureId'] as num).toInt();
            sink?.success({
              'event': 'onPrepared',
              'textureId': map['textureId'],
              'width': 1280,
              'height': 720,
              'durationMs': _kDurationMs,
              // setDataSource 后原生自动 play()：真实播放意图 = true
              'playWhenReady': true,
            });
          case 'getPosition':
            final gate = rec.positionGate;
            if (gate != null) return gate.future; // 在途 tick：等门放行
            return rec.position;
          case 'updateNowPlaying':
            rec.nowPlaying.add(call.arguments as Map<Object?, Object?>);
          default:
            // 未知方法（含 requestNotificationPermission）：mock 一律返回 null，
            // 与既有 player_* 测试同一约定（不因新增方法报错）
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
        // 用块体：箭头体会把赋值结果（sink）当返回值回给平台，解码报错
        onListen: (arguments, events) {
          sink = events;
        },
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('bili_dash_player/events'), null));

    // SystemChrome（进全屏 / dispose 恢复方向）：不 mock 会抛 MissingPluginException
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // 登录态安全存储（取流前会读 SESSDATA 拼 Cookie）：不 mock 会抛
    // MissingPluginException 把取流链路打断（既有播放页测试同款）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
  }
}

/// 挂载播放页并等到取流 + onPrepared 完成（媒体通知首次同步已完成）。
Future<void> _pumpPlayer(
  WidgetTester tester,
  _Rec rec, {
  WhitelistVideo? video,
}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(
      MaterialApp(home: PlayerPage(video: video ?? _video())));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 推一条原生 onMediaAction 事件并泵两帧。
///
/// 两帧是必要的：第一帧只把通道消息派发给 Dart 处理器（其中还有一次 await 通道
/// 调用），第二帧才是 setState 之后的重建；只泵一帧会偶发看不到新状态。
Future<void> _emitAction(
  WidgetTester tester,
  _Mocks mocks,
  String action, {
  int positionMs = 0,
}) async {
  mocks.emit('onMediaAction', action: action, positionMs: positionMs);
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

  testWidgets('onPrepared → updateNowPlaying 带标题/UP/封面/状态；并请求一次通知权限',
      (tester) async {
    final rec = _Rec();
    _Mocks(rec).install(tester);

    await _pumpPlayer(tester, rec);

    expect(rec.nowPlaying, isNotEmpty, reason: '进入播放就应同步媒体通知内容');
    final np = rec.nowPlaying.last;
    expect(np['title'], '媒体通知测试视频');
    expect(np['artist'], '测试UP主');
    expect(np['coverUrl'], 'https://i0.hdslb.com/bfs/archive/notify.jpg');
    expect(np['status'], '正在播放');
    expect(np['playing'], true);
    expect(np['positionMs'], isA<int>());
    expect(np['durationMs'], _kDurationMs, reason: '时长来自 onPrepared，供原生对齐');
    expect(rec.playerMethods, contains('requestNotificationPermission'),
        reason: '首次显示通知前请求一次通知权限（Android 13+；原生侧自带版本判断）');
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '界面处于播放态');
  });

  testWidgets('界面暂停/继续 → updateNowPlaying 跟着翻（通知与界面一致）',
      (tester) async {
    final rec = _Rec();
    _Mocks(rec).install(tester);
    await _pumpPlayer(tester, rec);

    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget, reason: '界面已暂停');
    expect(rec.nowPlaying.last['status'], '已暂停');
    expect(rec.nowPlaying.last['playing'], false);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '界面已继续播放');
    expect(rec.nowPlaying.last['status'], '正在播放');
    expect(rec.nowPlaying.last['playing'], true);
  });

  testWidgets('听视频开关 → 状态文案变「后台听视频省流量」', (tester) async {
    final rec = _Rec();
    _Mocks(rec).install(tester);
    await _pumpPlayer(tester, rec);

    await tester.tap(find.text('听视频'));
    await tester.pump();

    expect(rec.nowPlaying.last['status'], '后台听视频省流量',
        reason: '副标题状态与 B 站通知一致（UP 名 · 后台听视频省流量）');
    expect(rec.nowPlaying.last['playing'], true, reason: '听视频不打断播放');
  });

  testWidgets('原生 onMediaAction=play/pause（通知/耳机按键）→ 界面播放态跟着翻',
      (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // 耳机按一下暂停：原生已 pause，界面必须跟上（否则界面显示在播）
    await _emitAction(tester, mocks, 'pause');
    expect(find.byIcon(Icons.play_arrow), findsOneWidget,
        reason: '耳机暂停 → 界面转成播放键');
    expect(rec.nowPlaying.last['playing'], false,
        reason: '同步回原生时通知也应是暂停态');

    // 再按一下继续
    await _emitAction(tester, mocks, 'play');
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '耳机播放 → 界面转成暂停键');
    expect(rec.nowPlaying.last['playing'], true);
  });

  testWidgets('原生 onMediaAction=seek（通知快退/快进 15 秒）→ 界面位置跟着走',
      (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    // 125s → 进度文本 2:05（getPosition 仍返回 0，排除 tick 轮询的干扰）
    await _emitAction(tester, mocks, 'seek', positionMs: 125000);
    expect(find.text('2:05'), findsOneWidget,
        reason: '通知栏 seek 后界面位置立即跟上');
    expect(find.byIcon(Icons.pause), findsOneWidget,
        reason: 'seek 只挪位置，不改播放态（也不该被当成「关闭」处理）');
  });

  testWidgets('原生 onMediaAction=stop（通知 ✕）→ 界面收成停止态；再点播放重新取流续播',
      (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);
    final streamsBefore =
        rec.playerMethods.where((m) => m == 'setDataSource').length;
    expect(streamsBefore, 1);

    await _emitAction(tester, mocks, 'stop');
    expect(find.byIcon(Icons.play_arrow), findsOneWidget,
        reason: '通知 ✕ → 界面收成停止态（播放器已无媒体项）');

    // 再点播放：原生播放器已被 stop + clearMediaItems → 必须重新取流
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(rec.playerMethods.where((m) => m == 'setDataSource').length,
        greaterThan(streamsBefore),
        reason: '停止后再播放要重新取流（原生已清空媒体项）');
    expect(find.byIcon(Icons.pause), findsOneWidget,
        reason: '重新取流后恢复播放态');
  });

  // v2.25.0 回归用例：修 `_onCompleted` 只 cancel 不置 null 导致的「播完再播，
  // 进度条与字幕不再刷新」（`_timer ??=` 拿到的是已 cancel 的死实例）。
  //
  // 断言方式：不看私有字段，只走**界面/平台可观测量** ——
  //   1. mock 的 getPosition 返回 42s，播完再播后进度文本必须出现 0:42；
  //      旧 bug 下 tick 已死，文本停在 0:00（重播复位值），必红。
  //   2. 统计 2s 窗口内 getPosition 的调用次数（单计时器 500ms 一次 ≈ 4 次），
  //      旧 bug 下是 0 次，双计时器会翻倍到 8 次 —— 一条断言同时守住「复活」
  //      与「不重复开」两侧。
  // 用 findsWidgets 而非 findsOneWidget：同一位置文本在页面里有多处（主控制层 /
  // 手势单独浮出的进度条行 / 拖动预览气泡 timeLabel），在布台上是否 onstage 会随
  // 「预览浮层有没有帧」等条件浮动 —— 数个数就是脆弱断言，看「有没有」才稳。
  // 时间断言只依赖 500ms 周期与 2s 窗口的宽松区间，全 fake clock，不受机器速度影响。
  testWidgets('看完后再播 → tick 定时器复活（进度文本继续刷新）且只有一个 tick',
      (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    // 原生推 onCompleted：界面进「已播完」，tick 定时器被停掉
    mocks.emit('onCompleted');
    await tester.pump();
    await tester.pump();
    expect(find.text('3:20'), findsWidgets,
        reason: '播完位置 = 时长（200s → 3:20）');

    // 原生位置改成 42s：只有 tick 真在跑，界面才会出现 0:42
    rec.position = 42000;

    // 再点播放（中央播放键；耳机/通知播放键回传的 play 也走同一条 _togglePlay）
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await tester.pump();
    expect(find.text('0:00'), findsWidgets, reason: '播完重播先复位到 0:00');

    await tester.pump(const Duration(milliseconds: 600)); // 让一次 tick 落地
    expect(find.text('0:42'), findsWidgets,
        reason: '播完再播后进度文本必须重新跟 tick 走（旧 bug：定时器被 cancel '
            '未重建，文本永远停在 0:00）');

    // 双计时器守卫：2s 窗口内的 getPosition 次数（500ms 周期 ≈ 4 次）
    final before = rec.playerMethods.where((m) => m == 'getPosition').length;
    await tester.pump(const Duration(seconds: 2));
    final calls =
        rec.playerMethods.where((m) => m == 'getPosition').length - before;
    expect(calls, inInclusiveRange(3, 6),
        reason: '单 tick 每 500ms 一次 → 2s 内约 4 次；0 次 = 定时器没复活，'
            '8 次左右 = 开了两个计时器');
  });

  // 双计时器守卫：通知 ✕ 后再点播放走的是 [_init] 里的 `_ensureTickTimer`。
  // v2.25.0-r2 起 ✕ 会先把旧 tick cancel 掉（停止态不再空转，见下一条用例），
  // 所以这里是「cancel + 重建」路径 —— 若 [_ensureTickTimer] 不判 `isActive`
  // 就无条件新建（或旧 tick 没被 cancel），会出现两个 tick（进度/字幕双份轮询、
  // 观看时长双计）。用 getPosition 调用次数（2s ≈ 4 次）守住。
  testWidgets('通知 ✕ 后再播重取流 → 不会叠加出第二个 tick 定时器', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    await _emitAction(tester, mocks, 'stop'); // ✕：界面停止态 + 停 tick
    await tester.tap(find.byIcon(Icons.play_arrow)); // 重新取流（_init）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '已恢复播放态');

    final before = rec.playerMethods.where((m) => m == 'getPosition').length;
    await tester.pump(const Duration(seconds: 2));
    final calls =
        rec.playerMethods.where((m) => m == 'getPosition').length - before;
    expect(calls, inInclusiveRange(3, 6),
        reason: '仍应只有一个 tick（2s ≈ 4 次）；翻倍说明重开时又建了一个');
  });

  // v2.25.0-r2 用例（#3）：封面 URL 归一化。
  //
  // 实测 logcat：`Cleartext HTTP traffic to i2.hdslb.com not permitted` —— 部分
  // 视频的 cover 字段是 `http://`，原生 HttpURLConnection 明文请求被 App 的
  // cleartext 策略拦掉 → 通知 largeIcon 恒为 null（不显示封面）。Dart 侧在
  // 传给原生前先升到 https（原生 downloadBitmap 里还有一道同样的兜底）。
  test('normalizeCoverUrl：http:// 升 https、// 补 https、其余原样', () {
    expect(normalizeCoverUrl('http://i2.hdslb.com/a.jpg'),
        'https://i2.hdslb.com/a.jpg');
    expect(normalizeCoverUrl('//i2.hdslb.com/a.jpg'), 'https://i2.hdslb.com/a.jpg');
    expect(normalizeCoverUrl('https://i2.hdslb.com/a.jpg'),
        'https://i2.hdslb.com/a.jpg');
    expect(normalizeCoverUrl(''), '');
  });

  testWidgets('封面是 http:// → 传给原生的 coverUrl 已升为 https（通知封面才下载得到）',
      (tester) async {
    final rec = _Rec();
    _Mocks(rec).install(tester);

    await _pumpPlayer(tester, rec, video: _httpCoverVideo());

    expect(rec.nowPlaying, isNotEmpty);
    expect(
      rec.nowPlaying.last['coverUrl'],
      'https://i2.hdslb.com/bfs/archive/'
      'd92d77bfa32e2cec57048a6849a7a8b52270d214.jpg',
      reason: '传给原生媒体通知的封面 URL 必须是 https（明文的会被 cleartext 策略拦掉）',
    );
  });

  // v2.25.0-r2 用例（#2 回归）：暂停态下 seek 不能让界面错报「正在播放」。
  //
  // 实测 bug：通知栏暂停 → 拖通知进度条 / 点卡片快退 → 原生进 READY 发 onPrepared
  // （**每次进 READY 都会发**，不只 setDataSource 之后），旧 `_onPrepared` 无条件
  // `_playing = true` → 界面与通知都显示「正在播放」，而 `dumpsys media_session`
  // 里 `state=NONE(0)`、位置冻结。
  //
  // 现在 onPrepared 带原生真实播放意图 `playWhenReady`，暂停态 seek 上来的是
  // false → 界面保持暂停。
  testWidgets('暂停态下 seek → onPrepared(playWhenReady=false) 后界面仍暂停', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    // 1. 用户暂停（界面 → 暂停键）
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget, reason: '已暂停');
    expect(rec.nowPlaying.last['playing'], false);

    // 2. 暂停态下 seek（通知栏拖进度条 / 卡片快退 → 原生 seek 后重新进 READY）
    await _emitAction(tester, mocks, 'seek', positionMs: 125000);
    expect(find.text('2:05'), findsWidgets, reason: '位置跟着 seek 走');

    // 3. 原生 READY 事件（playWhenReady=false，因为 playWhenReady 一直是暂停）
    mocks.emitPrepared(playWhenReady: false);
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.play_arrow), findsOneWidget,
        reason: '暂停态下 seek 后界面必须仍是暂停（旧 bug：_onPrepared 无条件 '
            '置 _playing=true，界面错报「正在播放」）');
    expect(rec.nowPlaying.last['status'], '已暂停',
        reason: '推给原生通知的状态文案也应是「已暂停」，与原生播放器一致');
    expect(rec.nowPlaying.last['playing'], false);
  });

  // 只有 `playWhenReady=true` 的准备完成才把界面拉回播放态（正常起播路径与新流
  // 续播路径都靠它）：确认上面的修复没有把「起播」也一起改坏。
  testWidgets('播放态下 onPrepared(playWhenReady=true) → 界面保持播放', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // 换源 / 重新缓冲：原生自动 play → playWhenReady=true
    mocks.emitPrepared(playWhenReady: true);
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '起播/续播仍是播放态');
    expect(rec.nowPlaying.last['status'], '正在播放');
  });

  // v2.25.0-r2 用例（#1）：卡片上的「快退 15 秒 / 快进 15 秒」由原生会话自定义
  // 命令执行（`DashMediaNotification.onCustomCommand` → `seekTo(current ∓ 15000)`），
  // Kotlin 半边 flutter test 覆盖不到；Dart 侧要保证**收到 onMediaAction=seek 后
  // 的语义正确**：位置按原生给的新位置走、播放态不变、不再是「已播完」。
  testWidgets('原生自定义命令（快退/快进 15 秒）回传 seek → 位置走、播放态不变', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    // 快退 15 秒：原生从 140s → 125s（不是「回到开头」= 0）
    await _emitAction(tester, mocks, 'seek', positionMs: 125000);
    expect(find.text('2:05'), findsWidgets, reason: '快退后界面位置 = 125s');
    expect(find.byIcon(Icons.pause), findsOneWidget,
        reason: 'seek 不改播放态（播放中快退仍是播放中）');

    // 快进 15 秒：125s → 140s
    await _emitAction(tester, mocks, 'seek', positionMs: 140000);
    expect(find.text('2:20'), findsWidgets, reason: '快进后界面位置 = 140s');
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  // v2.25.0-r2 用例（#1 的关闭动作）：卡片 / 通知上的「关闭」→ 原生 stop +
  // 清媒体项 + 撤下通知，回传 onMediaAction=stop；界面收成停止态。
  testWidgets('原生自定义命令（关闭）回传 stop → 界面收成停止态', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    await _emitAction(tester, mocks, 'stop');

    expect(find.byIcon(Icons.play_arrow), findsOneWidget,
        reason: '关闭 → 界面收成停止态（可再点播放重新取流）');
  });

  // v2.25.0-r2 用例（#4）：通知 ✕ 之后播放器已被原生 stop + 清媒体项，
  // tick 不该继续空转（getPosition 恒为 0，还会把界面位置刷回 0:00、
  // 把关闭时保存的续播位置冲掉）。再点播放要能重新起 tick。
  testWidgets('通知 ✕ 后停止 tick 轮询；再点播放能重新开始轮询', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    // 先确认 tick 本来是活的（2s 窗口 ≈ 4 次 getPosition）
    final aliveBefore =
        rec.playerMethods.where((m) => m == 'getPosition').length;
    await tester.pump(const Duration(seconds: 2));
    expect(rec.playerMethods.where((m) => m == 'getPosition').length - aliveBefore,
        inInclusiveRange(3, 6),
        reason: '播放中 tick 每 500ms 轮询一次');

    await _emitAction(tester, mocks, 'stop'); // ✕
    final stoppedAt = rec.playerMethods.where((m) => m == 'getPosition').length;
    await tester.pump(const Duration(seconds: 2));
    expect(rec.playerMethods.where((m) => m == 'getPosition').length - stoppedAt, 0,
        reason: '停止态不该继续轮询（旧 bug：_onStoppedByNotification 不停 tick）');

    // 再点播放 → 重新取流 → tick 复活
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byIcon(Icons.pause), findsOneWidget, reason: '已恢复播放态');
    final resumedAt = rec.playerMethods.where((m) => m == 'getPosition').length;
    await tester.pump(const Duration(seconds: 2));
    expect(
      rec.playerMethods.where((m) => m == 'getPosition').length - resumedAt,
      inInclusiveRange(3, 6),
      reason: '重新播放后 tick 必须复活（进度条/字幕继续刷新），且只有一个',
    );
  });

  // v2.25.0-r2 用例（#4 的另一个窗口）：原生 stop() 之后、Dart 收到 stop 事件之前
  // 有一个窗口（模拟器实测 ~150ms），这段里 getPosition 会报 0。播放中位置不可能
  // 倒退到 0 → 这种值必须丢弃，否则界面被冲成 0:00，且随后「✕ 收尾按 _positionMs
  // 存进度」也会落空。
  testWidgets('原生 stop 后、关闭事件到达前的那个 0 位置不能被采纳', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    rec.position = 119000;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1:59'), findsWidgets, reason: '界面位置到 119s');

    // 用户已按 ✕（原生已 stop → getPosition 报 0），但 Dart 还没收到 stop 事件
    rec.position = 0;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1:59'), findsWidgets,
        reason: '播放中的 0 位置是「已 stop」的假位置，不能覆盖界面（否则 0:00）');

    // 停止事件随后到达：按界面位置存进度（119s），界面保持 1:59
    await _emitAction(tester, mocks, 'stop');
    expect(find.byIcon(Icons.play_arrow), findsOneWidget, reason: '收成停止态');
    expect(find.text('1:59'), findsWidgets,
        reason: '✕ 后的界面位置是关闭瞬间的位置，不是 0:00');
  });

  // v2.25.0-r2 用例（#4 的竞态面）：✕ 的瞬间可能正好有一次 tick **在途**
  // （getPosition 已发出、结果还没回来）。原生停掉播放器后那个结果恒为 0，
  // 若直接 setState 会把界面位置冲成 0:00 —— 实测就是「进度已正确存成 1:59、
  // 界面却显示 0:00」。用 positionGate 精确复现这个交错。
  testWidgets('通知 ✕ 时在途的 tick 结果不能把界面位置冲成 0:00', (tester) async {
    final rec = _Rec();
    final mocks = _Mocks(rec)..install(tester);
    await _pumpPlayer(tester, rec);

    // 位置先到 1:59（119s），并让界面显示出来
    rec.position = 119000;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1:59'), findsWidgets, reason: 'tick 把界面位置带到 119s');

    // 下一次 tick 的 getPosition 卡在门上（在途）
    rec.positionGate = Completer<int>();
    await tester.pump(const Duration(milliseconds: 600));
    final inFlight =
        rec.playerMethods.where((m) => m == 'getPosition').length;

    // 此刻用户点了通知栏 ✕：原生 stop → Dart 收成停止态（tick 被停掉 + 存进度）
    await _emitAction(tester, mocks, 'stop');
    expect(find.byIcon(Icons.play_arrow), findsOneWidget, reason: '已收成停止态');

    // 在途那一次 tick 现在才拿到结果（原生已停 = 0）
    rec.releasePositionGate(0);
    await tester.pump();
    await tester.pump();

    expect(find.text('0:00'), findsNothing,
        reason: '在途 tick 的 0 位置不能覆盖界面（否则刚存的续播位置在界面上'
            '变成 0:00）；界面应保持 ✕ 时的位置 1:59');
    expect(rec.playerMethods.where((m) => m == 'getPosition').length,
        inInclusiveRange(inFlight, inFlight + 1),
        reason: '停止态下不应再有新的 getPosition 请求（只有那个在途的回来）');
  });
}
