// 倍速弹窗（BottomSheet）横竖屏可见性/可滚动性测试。
//
// 背景：弹窗此前用默认 showModalBottomSheet（高度上限为屏高 9/16）+
// 不可滚动 Column，横屏/小屏下九档内容被裁出屏幕，档位看不见、选不中。
// 修复后：isScrollControlled + 70% 屏高约束 + useSafeArea + Flexible/ListView。
//
// 测试环境说明：
// - mock 原生播放器 MethodChannel（create 返回 textureId）→ 倍速按钮可用
// - mock secure storage（read 返回 null）→ 登录态读取不挂起
// - mock HttpOverrides（返回合法 nav/playurl JSON）→ 取流成功、无错误视图
//   （错误视图是 ColoredBox，RenderProxyBoxWithHitTestBehavior 默认 opaque，
//   会全屏拦截点击，测试里必须避免它出现）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

/// 模拟器同款逻辑分辨率：1080x2400 @ density 420 → 约 411x914 dp。
const double _dpr = 2.625;

WhitelistVideo _fakeVideo() => const WhitelistVideo(
      bvid: 'BV-test',
      cid: 1,
      title: '测试视频',
      cover: '',
      duration: 300,
      upName: 'up',
      addedAt: '2026-01-01',
    );

/// 九档倍速文案（不含重复的底部栏当前档 '1x'，用弹窗内 descendant 限定）。
const List<String> _speeds = [
  '0.5x', '0.75x', '1.25x', '1.5x', '1.75x', '2x', '2.5x', '3x',
];

// ---------------------------------------------------------------------------
// mock HTTP：flutter_test 默认把所有 HTTP 请求 mock 成 400 空响应，这里换成
// 返回合法 JSON（nav 的 wbi_img + playurl 的 dash），让取流链路走通。
// ---------------------------------------------------------------------------

const String _mockBody = '{"code":0,"data":{'
    '"quality":80,'
    '"wbi_img":{"img_url":"https://i0.hdslb.com/bfs/wbi/'
    'a2c2f919cb12ebdcf0fbc8a4e0a0f7f5.png",'
    '"sub_url":"https://i0.hdslb.com/bfs/wbi/'
    'e6f5b9b4b8f3e6f5b9b4b8f3e6f5b9b4.png"},'
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
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
  Future<HttpClientResponse> close() async {
    // 模拟服务器响应：固定返回合法 JSON（GET 请求体为空，不能 echo 请求体）
    return _FakeHttpResponse(utf8.encode(_mockBody));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHttpResponse implements HttpClientResponse {
  final List<int> _body;
  _FakeHttpResponse(this._body);

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
    // 响应头必须带 content-type: application/json，dio 才把 body 当 JSON 解析
    final h = _FakeHttpHeaders();
    h.add('content-type', 'application/json; charset=utf-8');
    return h;
  }

  // 注：handle 不是 HttpClientResponse 抽象接口成员（在内部实现类上），
  // 不加 @override；dio 通过 `response.handle!` 动态访问
  Stream<Uint8List>? get handle =>
      Stream<Uint8List>.fromIterable([Uint8List.fromList(_body)]);

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
  }) {
    return handle!.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      add(name, value);

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  // lookup 也不是 HttpHeaders 抽象接口成员（内部实现类成员），不加 @override
  List<String>? lookup(String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) => _map[name.toLowerCase()]?.first;

  // protocolVersion 是内部 _HttpHeaders 的成员（dio 用 dynamic 访问），不加 @override
  String? get protocolVersion => 'HTTP/1.1';

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// 测试主体
// ---------------------------------------------------------------------------

Future<void> _pumpPlayer(WidgetTester tester, Size physicalSize) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);

  // 注：本 SDK 中 HttpOverrides 无 global getter（读用 current），setter 仍叫 global
  final oldOverrides = HttpOverrides.current;
  HttpOverrides.global = _FakeHttpOverrides();
  addTearDown(() => HttpOverrides.global = oldOverrides);

  // mock 原生播放器：create 返回 textureId 1，其余操作空实现。
  // （未 mock 的 MethodChannel 在 flutter_test 里 send 永不返回，必须 mock）
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async => call.method == 'create' ? 1 : null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_dash_player'), null));

  // mock secure storage：read 返回 null（未登录），避免 _injectAuth 挂起
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null));

  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _fakeVideo())));
  // 等取流走通（无错误视图、无缓冲动画）
  await tester.pumpAndSettle();
}

Finder _inSheet(Finder matching) => find.descendant(
    of: find.byType(BottomSheet), matching: matching);

/// 断言弹窗完整落在屏幕内，且九档全部可达（竖屏高度足够时直接全部可见）。
void _expectSheetFullyOnScreen(WidgetTester tester) {
  final sheetRect = tester.getRect(find.byType(BottomSheet));
  final screenH = tester.getSize(find.byType(MaterialApp)).height;
  final screenW = tester.getSize(find.byType(MaterialApp)).width;
  expect(sheetRect.top, greaterThanOrEqualTo(-0.5),
      reason: '弹窗顶部不应超出屏幕上方');
  expect(sheetRect.bottom, lessThanOrEqualTo(screenH + 0.5),
      reason: '弹窗底部不应超出屏幕下方');
  expect(sheetRect.left, greaterThanOrEqualTo(-0.5),
      reason: '弹窗左侧不应超出屏幕');
  expect(sheetRect.right, lessThanOrEqualTo(screenW + 0.5),
      reason: '弹窗右侧不应超出屏幕');
}

void main() {
  testWidgets('竖屏：倍速弹窗完整在屏内，九档全部可见可点', (tester) async {
    await _pumpPlayer(tester, const Size(1080, 2400));
    expect(find.text('1x'), findsOneWidget); // 底部栏当前档

    await tester.tap(find.text('1x'));
    await tester.pumpAndSettle();
    expect(find.text('播放速度'), findsOneWidget);

    _expectSheetFullyOnScreen(tester);

    // 竖屏（约 411x914dp）下 70% 屏高足够容纳九档，全部无需滚动即可见
    for (final s in [..._speeds, '1x']) {
      expect(_inSheet(find.text(s)), findsOneWidget, reason: '档位 $s 应可见');
    }

    // 选中 2x：弹窗关闭，底部栏显示新倍速
    await tester.tap(_inSheet(find.text('2x')));
    await tester.pumpAndSettle();
    expect(find.text('播放速度'), findsNothing);
    expect(find.text('2x'), findsOneWidget);
  });

  testWidgets('横屏：弹窗完整在屏内且不超高，底部档位滚动后可达并可选', (tester) async {
    await _pumpPlayer(tester, const Size(2400, 1080));
    expect(find.text('1x'), findsOneWidget);

    await tester.tap(find.text('1x'));
    await tester.pumpAndSettle();
    expect(find.text('播放速度'), findsOneWidget);

    // 横屏（约 914x411dp）下弹窗必须完整在屏内（此前问题：超出屏幕下方）
    _expectSheetFullyOnScreen(tester);

    // 内容超出一屏 → 列表可滚动：滚动到最底档位 3x 并断言可见
    final scrollable = _inSheet(find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(
      _inSheet(find.text('3x')),
      80,
      scrollable: scrollable,
    );
    expect(_inSheet(find.text('3x')), findsOneWidget);

    // 滚动后选中最底档 3x：弹窗关闭，底部栏显示 3x
    await tester.tap(_inSheet(find.text('3x')));
    await tester.pumpAndSettle();
    expect(find.text('播放速度'), findsNothing);
    expect(find.text('3x'), findsOneWidget);
  });
}
