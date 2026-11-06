// 播放页底栏「压扁 + 精简」与「更多」弹层 / 系统分享的行为断言（v2.62.0）。
//
// 用户反馈（配截图）：「功能栏太高了…略缩模式功能不需要这么多」——截图里底栏
// 是**9 格**图标 + 两行文字，标签被挤到右侧截断。本批把它压成**单行横排**、
// 只留 5 格最常用的动作，其余（选集 / 听视频 / 字幕 / 下载 / 分享）收进
// 「更多」底部弹层，并把全屏键挪到进度条行右端（B 站同位置，零新增高度）。
//
// 本文件钉住这四条：
// 1. **可见项 = 5 格、顺序固定**（倍速 / 清晰度 / 弹幕 / 评论 / 更多），且其余
//    功能的标签不再出现在底栏（真的「收起来了」，不是藏起来仍占位）；
// 2. **标签无截断**：不抛 RenderFlex overflow，每个标签的渲染矩形都落在自己那一
//    格里，且文字完整（无省略号）；
// 3. 「更多」弹层**内容与行为与原来的底栏按钮一致**（字幕 → 字幕面板、
//    听视频 → 进听视频模式、选集 → 选集弹窗、分享 → 系统通道）；
// 4. 分享**参数正确**（标题 + 含 `?p=` 的站内链接）、失败给可读提示、
//    **不发任何网络请求**。
//
// 高度几何（32 / 72 / 112）在 `player_bottom_bar_geometry_test.dart` 里量，本
// 文件不重复。
//
// 环境与既有播放页测试同款：mock 播放器通道（setDataSource → onPrepared）+ 假
// HTTP（playurl 给 DASH 双流，走正常播放态）+ 内存 DownloadManager 替身 +
// mock 分享通道（记录调用参数）。**一律显式 pump**（页面有无限动画）。
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

const String _kBvid = 'BV1ITM00001';

const Key _kButtonRow = ValueKey('player-button-row');
const Key _kSpeedBtn = ValueKey('player-speed-button');
const Key _kQualityBtn = ValueKey('player-quality-button');
const Key _kDanmakuBtn = ValueKey('player-danmaku-button');
const Key _kCommentsBtn = ValueKey('player-comments-button');
const Key _kMoreBtn = ValueKey('player-more-button');
const Key _kMoreEpisodes = ValueKey('player-more-episodes');
const Key _kMoreListen = ValueKey('player-more-listen');
const Key _kMoreSubtitles = ValueKey('player-more-subtitles');
const Key _kMoreDownload = ValueKey('player-more-download');
const Key _kMoreShare = ValueKey('player-more-share');

/// 竖屏 411×914 下按钮行 5 等分的格宽（82.2）——标签不截断的余量基准。
const double _kCellWidth = 411 / 5;

WhitelistVideo _video({List<PageInfo>? pages}) => WhitelistVideo(
      bvid: _kBvid,
      cid: 1001,
      title: '底栏精简测试视频',
      cover: '',
      duration: 200,
      upName: '测试UP主',
      addedAt: '2026-01-01',
      pages: pages,
    );

List<PageInfo> _twoPages() => const [
      PageInfo(cid: 1001, part: '第1集', duration: 200),
      PageInfo(cid: 1002, part: '第2集', duration: 200),
    ];

/// 内存版 DownloadManager（不读真文件：FakeAsync 下真实 IO 永不完成）。
class _FakeManager extends DownloadManager {
  _FakeManager() {
    cached.value = const [];
  }
}

// ---- 假 HTTP：playurl 给 DASH 双流（走正常播放态）----

/// 全局请求计数：「分享不发网络请求」这条断言用它。
int _httpRequests = 0;

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
  Future<HttpClientRequest> getUrl(Uri url) async {
    _httpRequests++;
    return _FakeHttpRequest(url);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    _httpRequests++;
    return _FakeHttpRequest(url);
  }

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
        'title': '底栏精简测试视频',
        'pic': '',
        'duration': 200,
        'owner': {'mid': 1001, 'name': '测试UP主', 'face': ''},
        'desc': '',
        'pubdate': 1700000000,
        'pages': [
          {'cid': 1001, 'part': '第1集', 'duration': 200},
          {'cid': 1002, 'part': '第2集', 'duration': 200},
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

/// 分享通道收到的调用（每条方法的参数原样记下来）。
final List<MethodCall> _shareCalls = [];

void _installMocks(
  WidgetTester tester, {
  bool shareSucceeds = true,
  PlatformException? shareThrows,
  int getPositionMs = 0,
}) {
  MockStreamHandlerEventSink? sink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      switch (call.method) {
        case 'create':
          return 1;
        case 'getPosition':
          return getPositionMs;
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

  // 系统分享通道（v2.62.0）：记下每次调用的方法名 + 参数，回包由用例指定
  _shareCalls.clear();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_whitelist/share'),
    (call) async {
      _shareCalls.add(call);
      if (shareThrows != null) throw shareThrows;
      return shareSucceeds;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('bili_whitelist/share'),
          null));
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  WhitelistVideo video, {
  int initialPageIndex = 0,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PlayerPage(video: video, initialPageIndex: initialPageIndex),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 打开底栏「更多」弹层（等展开动画）。
Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(_kMoreBtn));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _httpRequests = 0;
  });

  Future<void> mount(WidgetTester tester,
      {WhitelistVideo? video, int initialPageIndex = 0}) async {
    HttpOverrides.global = _FakeHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    DownloadManager.debugOverride(_FakeManager());
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(411, 914);
    addTearDown(tester.view.reset);
    await _pumpPlayer(tester, video ?? _video(pages: _twoPages()),
        initialPageIndex: initialPageIndex);
  }

  group('底栏精简（v2.62.0）', () {
    testWidgets('竖屏可见项 = 5 格：倍速 / 清晰度 / 弹幕 / 评论 / 更多（顺序固定）',
        (tester) async {
      _installMocks(tester);
      await mount(tester);

      // ① 五格都在
      for (final key in [
        _kSpeedBtn,
        _kQualityBtn,
        _kDanmakuBtn,
        _kCommentsBtn,
        _kMoreBtn,
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key 应在底栏');
      }
      // ② 按钮行里**只有**这 5 个可点单元（不是「藏起来仍占位」）
      expect(
        find.descendant(
            of: find.byKey(_kButtonRow), matching: find.byType(InkWell)),
        findsNWidgets(5),
        reason: 'v2.62.0：9 格 → 5 格（其余进「更多」）',
      );
      // ③ 顺序：x 中心递增（倍速 → 清晰度 → 弹幕 → 评论 → 更多）
      final xs = [
        _kSpeedBtn,
        _kQualityBtn,
        _kDanmakuBtn,
        _kCommentsBtn,
        _kMoreBtn,
      ].map((k) => tester.getCenter(find.byKey(k)).dx).toList();
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]),
            reason: '第 ${i + 1} 格应排在第 $i 格右侧（顺序固定）');
      }
      // ④ 收走的那些功能不再出现在底栏（标签一个都不该在树里）
      for (final label in ['听视频', '字幕', '下载缓存', '分享']) {
        expect(find.text(label), findsNothing,
            reason: '「$label」已收进「更多」，底栏文字层不该再有它');
      }
      // ⑤ 每格宽度 = 屏宽 5 等分（标签不截断的空间来源）
      for (final key in [_kSpeedBtn, _kMoreBtn]) {
        expect(tester.getSize(find.byKey(key)).width,
            closeTo(_kCellWidth, 0.5),
            reason: '五等分格宽 ≈82.2dp（原来是 9 等分 45.7dp）');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('标签不截断：无 RenderFlex overflow、每个标签都落在自己那一格里',
        (tester) async {
      _installMocks(tester);
      await mount(tester);

      // 五格各自的标签（按当前状态取真值：默认 1x / 本次下发的 1080P）
      const expected = ['1x', '1080P', '弹幕', '评论', '更多'];
      final keys = [_kSpeedBtn, _kQualityBtn, _kDanmakuBtn, _kCommentsBtn, _kMoreBtn];
      for (var i = 0; i < keys.length; i++) {
        final cellRect = tester.getRect(find.byKey(keys[i]));
        final label = tester.widget<Text>(find.descendant(
          of: find.byKey(keys[i]),
          matching: find.byType(Text),
        ));
        expect(label.data, expected[i],
            reason: '第 ${i + 1} 格的标签（顺序与文案都固定）');
        expect(label.overflow, isNot(TextOverflow.ellipsis),
            reason: 'v2.62.0：标签走 FittedBox 等比缩放，绝不省略');
        final textRect = tester.getRect(find.descendant(
          of: find.byKey(keys[i]),
          matching: find.byType(Text),
        ));
        expect(textRect.left, greaterThanOrEqualTo(cellRect.left - 0.5),
            reason: '「${expected[i]}」不得伸出本格左缘');
        expect(textRect.right, lessThanOrEqualTo(cellRect.right + 0.5),
            reason: '「${expected[i]}」不得伸出本格右缘（伸出即被裁切）');
        expect(cellRect.width, lessThanOrEqualTo(_kCellWidth + 0.5),
            reason: '格宽就是五等分，没有额外挤压');
      }
      expect(tester.takeException(), isNull, reason: '整行布局不得抛溢出');
    });

    testWidgets('「更多」弹层承载其余功能：选集 / 听视频 / 字幕 / 下载 / 分享',
        (tester) async {
      _installMocks(tester);
      await mount(tester);

      await _openMore(tester);
      expect(find.text('更多功能'), findsOneWidget, reason: '弹层标题');
      for (final key in [
        _kMoreEpisodes,
        _kMoreListen,
        _kMoreSubtitles,
        _kMoreDownload,
        _kMoreShare,
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key 应出现在弹层里');
      }
      // 状态文案与原来的底栏标签一致（多 P 带当前集号）
      expect(find.text('选集 1/2'), findsOneWidget);
      expect(find.text('听视频'), findsOneWidget);
      expect(find.text('字幕'), findsOneWidget);
      expect(find.text('下载缓存'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「更多」→ 选集：打开选集弹窗（与原来点底栏选集一致）',
        (tester) async {
      _installMocks(tester);
      await mount(tester);

      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreEpisodes));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('第2集'), findsOneWidget, reason: '选集弹窗已打开（分 P 列表就绪）');

      // 选第 2 集 → 真的切集（行为与改动前一致：切完「更多」里报 2/2）
      await tester.tap(find.text('第2集'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));

      await _openMore(tester);
      expect(find.text('选集 2/2'), findsOneWidget,
          reason: '切集成功（选集标签跟着当前集号走）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('全屏态：同一套高度、同一套横排，格数放到 8（听视频/字幕/下载回来）',
        (tester) async {
      _installMocks(tester);
      await mount(tester);

      // 全屏键现在在进度条行右端（v2.62.0），点它进全屏
      await tester.tap(find.byKey(const ValueKey('player-seek-fullscreen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));

      // 高度规范与竖屏**同一套**（32dp，不因全屏变高）
      expect(tester.getSize(find.byKey(_kButtonRow)).height, 32,
          reason: '全屏与竖屏共用同一个按钮行高度（别两套视觉）');
      // 8 格：倍速 / 清晰度 / 听视频 / 字幕 / 弹幕 / 评论 / 下载 / 更多
      expect(
        find.descendant(
            of: find.byKey(_kButtonRow), matching: find.byType(InkWell)),
        findsNWidgets(8),
        reason: '横屏空间充足 → 听视频 / 字幕 / 下载 常驻',
      );
      expect(find.text('听视频'), findsOneWidget);
      expect(find.text('字幕'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「更多」→ 听视频：进入听视频模式（行为未变）', (tester) async {
      _installMocks(tester);
      await mount(tester);

      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreListen));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // 占位层是听视频模式的既有标志（点按恢复画面那段文案）
      expect(find.textContaining('听视频中'), findsWidgets,
          reason: '进入听视频 → 画面区换成占位层文案');
      expect(tester.takeException(), isNull);
    });

    testWidgets('「更多」→ 字幕：打开字幕设置面板（行为未变）', (tester) async {
      _installMocks(tester);
      await mount(tester);

      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreSubtitles));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('字幕设置'), findsOneWidget, reason: '字幕面板已打开');
      expect(tester.takeException(), isNull);
    });
  });

  group('系统分享（v2.62.0）', () {
    testWidgets('点分享 → 通道收到「标题 + 含 ?p= 的站内链接」，且不发网络请求',
        (tester) async {
      _installMocks(tester);
      await mount(tester, initialPageIndex: 1); // 停在 P2

      final requestsBefore = _httpRequests;
      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreShare));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_shareCalls, hasLength(1), reason: '只调一次原生分享');
      expect(_shareCalls.single.method, 'shareText');
      final args = Map<Object?, Object?>.from(
          _shareCalls.single.arguments as Map);
      expect(args['subject'], '底栏精简测试视频', reason: 'EXTRA_SUBJECT = 视频标题');
      final text = args['text'] as String;
      expect(text, startsWith('底栏精简测试视频\n'),
          reason: '第一行标题、第二行链接');
      expect(text, contains('https://www.bilibili.com/video/$_kBvid?p=2'),
          reason: '多 P 必须带 ?p=N（1 起）→ 对方点开落在同一集');
      expect(text.contains('&t='), isFalse,
          reason: '当前位置 0s（<10s）不附 t=，链接保持干净');
      expect(_httpRequests, requestsBefore,
          reason: '分享只是把文本递给原生 → 一个网络请求都不许发');
    });

    testWidgets('播放超过 10s → 链接追加 &t=（落在同一位置），p 在前 t 在后',
        (tester) async {
      // 假播放器回报 12.345s：tick 一轮后 _positionMs ≥ 10s
      _installMocks(tester, getPositionMs: 12345);
      await mount(tester, initialPageIndex: 1);
      await tester.pump(const Duration(milliseconds: 600)); // 推一轮 500ms tick
      await tester.pump();

      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreShare));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final args = Map<Object?, Object?>.from(
          _shareCalls.single.arguments as Map);
      expect(args['text'],
          contains('https://www.bilibili.com/video/$_kBvid?p=2&t=12'),
          reason: 'p 在前、t 在后（秒取整）；站内链接解析侧认这两个参数');
    });

    testWidgets('分享失败（系统没有能接收文字的 App）→ 一条可读提示，不崩',
        (tester) async {
      _installMocks(tester, shareSucceeds: false);
      await mount(tester);

      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreShare));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('分享失败：系统里没有能接收文字的 App'), findsOneWidget,
          reason: '失败给中文可读提示（不含异常类名）');
      expect(tester.takeException(), isNull, reason: '失败不崩');
    });

    testWidgets('原生抛 PlatformException → 提示里带原生给的原因，不崩',
        (tester) async {
      _installMocks(tester,
          shareThrows: PlatformException(
              code: 'SHARE_FAILED', message: '调起分享面板失败'));
      await mount(tester);

      await _openMore(tester);
      await tester.tap(find.byKey(_kMoreShare));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('分享失败：调起分享面板失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
