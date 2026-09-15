// 离线缓存页（v2.29.0）widget 测试：
// - 空态 / 分组 / 仅音频标记 / 单删 / 全清 / 分项占用 / 清理动作
// - 点条目 → push PlayerPage 且**参数正确**（离线页用 CachedVideo 现场构造
//   WhitelistVideo）；仅音频条目还要断言播放页把音频文件当 videoUrl 传
//   （离线播放的核心契约）
//
// ## 测试环境的硬约束（踩过坑）
// flutter_test 的 FakeAsync 时区里 **dart:io 的真实异步永远不完成**
// （除非包在 `tester.runAsync` 里）——而 DownloadManager 的生产实现必须读
// 真实文件，页面 initState 里的 IO 会把「加载中」永远卡住。所以本文件：
// - `DownloadManager` / `SherpaAudioSource` 一律用**内存替身**（下面的
//   `_FakeManager` / `_FakeAudioSource`），页面行为与真实 IO 解耦；
// - 真实文件 IO 的覆盖在 download_manager_test.dart（那边用 plain `test()`，
//   不受 FakeAsync 限制）与 realtime_transcriber_test.dart；
// - 播放页要发弹幕/字幕请求 → mock HttpOverrides（否则真实 socket 在
//   FakeAsync 里挂着，收尾还会报 pending timer）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/sherpa_audio.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/pages/offline_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';

// ---------------------------------------------------------------------------
// 内存替身
// ---------------------------------------------------------------------------

/// 内存版 DownloadManager：零真实文件 IO（理由见文件头）。
class _FakeManager extends DownloadManager {
  _FakeManager({
    List<CachedVideo> items = const [],
    CacheDiskUsage usage = const CacheDiskUsage(),
  })  : _items = List.of(items),
        _usage = usage {
    _published = List.unmodifiable(_items);
  }

  List<CachedVideo> _items;
  final CacheDiskUsage _usage;
  late List<CachedVideo> _published;

  /// 回收残留的返回值（测试可改），并累计调用次数。
  ({int files, int bytes}) reclaimResult = (files: 0, bytes: 0);
  int reclaimCalls = 0;

  /// 变更后重新发布（notifier 换实例 → 页面监听刷新）。
  void _publish() {
    _published = List.unmodifiable(_items);
    cached.value = _published;
  }

  @override
  Future<void> init() async {
    // 只在内容变化时赋值：ValueNotifier 换实例会通知页面 → 页面 _reload
    // 又调 init → 无脑赋值会变成死循环
    if (!identical(cached.value, _published)) cached.value = _published;
  }

  @override
  Future<CacheDiskUsage> diskUsage() async => _usage;

  @override
  Future<({int files, int bytes})> reclaimOrphans() async {
    reclaimCalls++;
    return reclaimResult;
  }

  @override
  Future<void> deleteCache(String bvid, int pageIndex) async {
    _items = _items
        .where((c) => !(c.bvid == bvid && c.pageIndex == pageIndex))
        .toList();
    _publish();
  }

  @override
  Future<void> cleanAllCache() async {
    _items = <CachedVideo>[];
    _publish();
  }
}

/// 内存版中转音频清理（只记调用次数与返回值）。
class _FakeAudioSource extends SherpaAudioSource {
  int calls = 0;
  ({int files, int bytes}) result = (files: 0, bytes: 0);

  @override
  Future<({int files, int bytes})> cleanTmpAudio() async {
    calls++;
    return result;
  }
}

/// 记录 setDataSource 的原生参数（断言离线播放用的是哪个文件）。
class _PlayerRec {
  final List<Map<Object?, Object?>> dataSources = [];

  /// 最后一次 setDataSource 的 videoUrl（无调用 → null）。
  String? get lastVideoUrl =>
      dataSources.isEmpty ? null : dataSources.last['videoUrl'] as String?;

  /// 最后一次 setDataSource 的 audioUrl（原生把 null 收成空串）。
  String? get lastAudioUrl =>
      dataSources.isEmpty ? null : dataSources.last['audioUrl'] as String?;
}

// ---------------------------------------------------------------------------
// mock：播放器通道 / 平台通道 / HTTP
// ---------------------------------------------------------------------------

/// mock 原生播放器通道：create 返回 textureId；setDataSource 记录参数并立即
/// 回一条 onPrepared（播放页据此进入「已就绪」）。
void _mockPlayerChannels(WidgetTester tester, _PlayerRec rec) {
  const textureId = 7;
  MockStreamHandlerEventSink? sink;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('bili_dash_player'),
    (call) async {
      switch (call.method) {
        case 'create':
          return textureId;
        case 'setDataSource':
          final map = call.arguments as Map;
          rec.dataSources.add(map.cast<Object?, Object?>());
          sink?.success({
            'event': 'onPrepared',
            'textureId': map['textureId'],
            'width': 1280,
            'height': 720,
            'durationMs': 60000,
            'playWhenReady': true,
          });
        default:
          // getPosition / updateNowPlaying / 通知权限等一律返回 null
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

  // 平台通道（SystemChrome 方向/常亮）：不 mock 会抛 MissingPluginException
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  // 登录态安全存储（弹幕/字幕请求前会读 SESSDATA）：同上
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
}

/// 固定返回空 JSON 的 HTTP fake（播放页发弹幕/字幕请求时用；与既有 player_*
/// 测试同款，避免真实 socket 挂在 FakeAsync 里）。
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
      _FakeHttpResponse(utf8.encode('{"code":0,"data":{}}'));

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
// 夹具
// ---------------------------------------------------------------------------

CachedVideo _cached({
  required String bvid,
  int pageIndex = 0,
  String title = '缓存测试视频',
  String partTitle = '',
  bool audioOnly = false,
  int sizeBytes = 1000,
  int cid = 100,
  int durationMs = 60000,
  DateTime? cachedAt,
}) {
  return CachedVideo(
    bvid: bvid,
    title: title,
    cover: '',
    pageIndex: pageIndex,
    partTitle: partTitle,
    videoPath: audioOnly ? '' : '/fake/video_cache/${bvid}_p${pageIndex + 1}.m4s',
    audioPath: '/fake/video_cache/${bvid}_p${pageIndex + 1}.audio.m4s',
    sizeBytes: sizeBytes,
    cachedAt: cachedAt ?? DateTime.now().toUtc(),
    upName: 'up主',
    cid: cid,
    durationMs: durationMs,
    audioOnly: audioOnly,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeManager manager;
  late _FakeAudioSource audio;
  late _PlayerRec rec;
  HttpOverrides? oldHttpOverrides;

  /// 挂载离线缓存页（单例已注入内存替身，页面 initState 自己加载）。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OfflinePage(audioSource: audio),
    ));
    // 三帧：initState 的两个 await（init + diskUsage）→ setState → 重建
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    oldHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = _FakeHttpOverrides();
    manager = _FakeManager();
    DownloadManager.debugOverride(manager);
    audio = _FakeAudioSource();
    rec = _PlayerRec();
  });

  tearDown(() {
    HttpOverrides.global = oldHttpOverrides;
    DownloadManager.debugReset();
  });

  testWidgets('空态：走 AppStateView（seed = cache）+ 占用卡在 + 清理动作置灰',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('离线缓存'), findsOneWidget); // AppBar 标题
    expect(find.text('缓存占用'), findsOneWidget);
    expect(find.text('合计 0 B'), findsOneWidget);
    expect(find.textContaining('媒体文件 0 B（0 个）'), findsOneWidget);
    expect(find.text('暂无缓存'), findsOneWidget);
    final state = tester.widget<AppStateView>(find.byType(AppStateView));
    expect(state.kind, AppStateKind.empty);
    expect(state.copyId, 'empty.cache');
    expect(state.subtitleCopyId, 'empty.cache.sub');
    expect(state.scrollable, isTrue, reason: '独立页不在弹层里，自带滚动');
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'cache',
    );
    // 没有缓存 → 不显示「清空全部缓存」
    expect(find.text('清空全部缓存'), findsNothing);
    // 占用为 0 → 两个清理动作都置灰
    for (final key in [kCleanTmpAudioKey, kReclaimOrphansKey]) {
      final button = tester.widget<OutlinedButton>(find.byKey(key));
      expect(button.onPressed, isNull, reason: '$key 应置灰');
    }
  });

  testWidgets('分组渲染：同一 bvid 的多 P 归一组，另一 bvid 单独一组', (tester) async {
    manager = _FakeManager(items: [
      _cached(bvid: 'BV1multi', pageIndex: 0, partTitle: '第一集'),
      _cached(bvid: 'BV1multi', pageIndex: 1, partTitle: '第二集'),
      _cached(bvid: 'BV1solo', title: '单 P 视频'),
    ]);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    expect(find.byKey(const ValueKey('offline#BV1multi#0')), findsOneWidget);
    expect(find.byKey(const ValueKey('offline#BV1multi#1')), findsOneWidget);
    expect(find.byKey(const ValueKey('offline#BV1solo#0')), findsOneWidget);
    // 分 P 名 + 大小 + 「视频」标记
    expect(find.text('第 2 集 · 第二集'), findsOneWidget);
    expect(find.textContaining('第一集 · 1000 B · '), findsOneWidget);
    expect(find.textContaining(' · 视频'), findsNWidgets(3));
    // 组头：UP 名 · 组内条数 · 组内总大小
    expect(find.textContaining('up主 · 2 个 · 2.0 KB'), findsOneWidget);
    expect(find.textContaining('up主 · 1 个 · 1000 B'), findsOneWidget);
    expect(find.text('清空全部缓存'), findsOneWidget);
  });

  testWidgets('仅音频条目：标「音频」+ 组头标「仅音频」+ 分项占用正确', (tester) async {    manager = _FakeManager(
      items: [
        _cached(bvid: 'BV1audio', audioOnly: true),
        _cached(bvid: 'BV1full'),
      ],
      usage: const CacheDiskUsage(
        mediaBytes: 2048,
        tmpAudioBytes: 800,
        orphanBytes: 400,
        orphanCount: 2,
      ),
    );
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    expect(find.textContaining(' · 音频'), findsOneWidget);
    expect(find.textContaining(' · 视频'), findsOneWidget);
    expect(find.textContaining('· 仅音频'), findsOneWidget, reason: '组头标注');
    expect(find.byIcon(Icons.audiotrack_outlined), findsWidgets);
    // 占用卡：分项（媒体/中转/残留）+ 合计
    expect(find.textContaining('媒体文件 2.0 KB（2 个）'), findsOneWidget);
    expect(find.textContaining('中转音频 800 B'), findsOneWidget);
    expect(find.textContaining('残留 400 B'), findsOneWidget);
    expect(find.text('合计 3.2 KB'), findsOneWidget);
    // 有残留 / 有中转 → 两个动作都可点
    for (final key in [kCleanTmpAudioKey, kReclaimOrphansKey]) {
      final button = tester.widget<OutlinedButton>(find.byKey(key));
      expect(button.onPressed, isNotNull, reason: '$key 应可点');
    }
  });

  testWidgets('单 P 的 partTitle 与标题相同时：副信息不重复那句标题', (tester) async {
    // B 站单 P 视频的 pages[0].part 实测就等于视频标题（真机截图里明显冗余）
    manager = _FakeManager(items: [
      _cached(bvid: 'BV1dup', title: '同名视频', partTitle: '同名视频'),
    ]);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    expect(find.text('同名视频'), findsNWidgets(2),
        reason: '组头 + 条目标题行各一次（若副信息也重复就是 3 次）');
    expect(find.text('1000 B · 刚刚 · 视频'), findsOneWidget,
        reason: '副信息以大小开头（省掉重复的标题）');
  });

  testWidgets('删除单条：确认后索引更新、条目消失（另一条不受影响）', (tester) async {
    manager = _FakeManager(items: [
      _cached(bvid: 'BV1a'),
      _cached(bvid: 'BV1b', title: '另一个视频'),
    ]);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('offline#BV1a#0')), findsOneWidget);

    await tester.tap(find.byTooltip('删除这条缓存').first);
    await tester.pumpAndSettle(); // 确认框
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('offline#BV1a#0')), findsNothing);
    expect(find.byKey(const ValueKey('offline#BV1b#0')), findsOneWidget);
    expect(manager.isCached('BV1a', 0), isFalse, reason: '索引已更新');
    expect(manager.isCached('BV1b', 0), isTrue);
  });

  testWidgets('清空全部：确认框写明大小与中转音频，确认后回到空态', (tester) async {
    manager = _FakeManager(items: [_cached(bvid: 'BV1a')]);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    await tester.tap(find.text('清空全部缓存'));
    await tester.pumpAndSettle();
    // 全清确认框把「中转音频不在此次清理范围」讲清楚（不误伤转写中转）
    expect(find.textContaining('将删除所有已缓存的视频/音频文件'), findsOneWidget);
    expect(find.textContaining('转写中转音频'), findsOneWidget);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(manager.getCachedList(), isEmpty);
    expect(find.text('暂无缓存'), findsOneWidget);
    expect(find.text('清空全部缓存'), findsNothing);
  });

  testWidgets('点条目 → push PlayerPage 且参数取自缓存记录', (tester) async {
    _mockPlayerChannels(tester, rec);
    manager = _FakeManager(items: [
      _cached(
        bvid: 'BV1play',
        pageIndex: 1,
        partTitle: '第二集',
        title: '要点开的视频',
        cid: 2222,
        durationMs: 90000,
      ),
    ]);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('offline#BV1play#1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(page.video.bvid, 'BV1play');
    expect(page.video.cid, 2222, reason: 'cid 取自缓存记录（弹幕/字幕要用）');
    expect(page.video.title, '要点开的视频');
    expect(page.video.duration, 90, reason: 'durationMs → 秒');
    expect(page.video.upName, 'up主');
    expect(page.initialPageIndex, 1, reason: '落到缓存的那一分 P');
    // 整段缓存：videoUrl = 视频文件，audioUrl = 音频文件
    expect(rec.dataSources, hasLength(1));
    expect(rec.lastVideoUrl, contains('BV1play_p2.m4s'));
    expect(rec.lastVideoUrl, isNot(contains('audio')));
    expect(rec.lastAudioUrl, contains('BV1play_p2.audio.m4s'));
  });

  testWidgets('点仅音频条目 → 播放页把音频文件当 videoUrl 传（离线播放契约）',
      (tester) async {
    _mockPlayerChannels(tester, rec);
    manager = _FakeManager(items: [_cached(bvid: 'BV1only', audioOnly: true)]);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('offline#BV1only#0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(rec.dataSources, hasLength(1));
    expect(rec.lastVideoUrl, contains('BV1only_p1.audio.m4s'),
        reason: '仅音频缓存：音频文件走 videoUrl 通道（原生单流分支）');
    expect(rec.lastAudioUrl, isEmpty, reason: '不再重复挂 audioUrl');
    // 播放页给出「仅缓存了音频」的说明层（否则只有黑屏，用户以为坏了）
    expect(find.text('仅缓存了音频：无画面，可正常听声音'), findsOneWidget);
  });

  testWidgets('清理中转音频：调一次清理、提示条数与字节', (tester) async {
    manager = _FakeManager(
      items: [_cached(bvid: 'BV1a')],
      usage: const CacheDiskUsage(mediaBytes: 1000, tmpAudioBytes: 800),
    );
    DownloadManager.debugOverride(manager);
    audio.result = (files: 2, bytes: 800);
    await pumpPage(tester);

    await tester.tap(find.text('清理中转音频'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理'));
    await tester.pumpAndSettle();

    expect(audio.calls, 1);
    expect(find.text('已清理 2 个中转文件 · 800 B'), findsOneWidget);
  });

  testWidgets('回收残留文件：调一次回收、提示条数与字节', (tester) async {
    manager = _FakeManager(
      items: [_cached(bvid: 'BV1a')],
      usage: const CacheDiskUsage(
        mediaBytes: 1000,
        orphanBytes: 300,
        orphanCount: 2,
      ),
    );
    manager.reclaimResult = (files: 2, bytes: 300);
    DownloadManager.debugOverride(manager);
    await pumpPage(tester);

    await tester.tap(find.text('回收残留文件'));
    await tester.pumpAndSettle();

    expect(manager.reclaimCalls, 1);
    expect(find.text('已回收 2 个残留文件 · 300 B'), findsOneWidget);
  });

  test('groupCachedByBvid：组间按最新一条倒序，组内按分 P 升序', () {
    final now = DateTime.now().toUtc();
    CachedVideo mk(String bvid, int page, Duration age) => _cached(
          bvid: bvid,
          pageIndex: page,
          cachedAt: now.subtract(age),
        );
    // 入参口径 = DownloadManager.getCachedList（缓存时间倒序）
    final groups = groupCachedByBvid([
      mk('BV1a', 1, Duration.zero),
      mk('BV1b', 0, const Duration(minutes: 1)),
      mk('BV1a', 0, const Duration(minutes: 2)),
    ]);

    expect(groups.map((g) => g.bvid), ['BV1a', 'BV1b']);
    expect(groups.first.parts.map((c) => c.pageIndex), [0, 1]);
    expect(groups.first.totalBytes, 2000);
    expect(groups.first.allAudioOnly, isFalse);
    expect(groupCachedByBvid(const []), isEmpty);
  });
}
