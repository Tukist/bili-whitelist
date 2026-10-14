// 「免流兼容（实验）」开关**失败时的自救闭环**（v2.51.1+）测试。
//
// ## 背景（v2.51.0 的真实缺陷）
// v2.51.0 加了开关后，用户实测「打开它 → 视频一直转圈、黑屏」。原因是失败路径
// 走了**别处**：非浏览器 UA 取 `.bilivideo.com` 流被 CDN 403，而原生
// `DashExoPlayer.isRecoverableSourceError` 把 403（`InvalidResponseCodeException`
// 的 `isRecoverableHttpStatus`）归为**可自动恢复** → 发 `onUrlExpired`，根本不走
// 播放页的「致命错误」分支。于是 Dart 侧一路自动续播 1s→2s→4s 三次后落到
// `kAutoRecoverGiveUpMessage`（「播放中断（网络或视频流异常），请重试」）——
// v2.51.0 那句点名开关的 403 提示写在致命分支里，**用户永远看不到**。
//
// ## 本文件钉住的三件事
// 1. **说清楚 + 一键自救**：开关开着且流失败时，用户能看到的每个出口
//    （自动续播耗尽的放弃文案 / 原生流级错误）都带「免流兼容」归因，错误视图上
//    有「关掉免流兼容并重试」按钮；点它 = 真关开关（落盘）+ 重建播放器 + 重取流续播。
// 2. **自动回退**：开关在用、且自动续播预算耗尽（本地图轮转 + 重取都救不回来）
//    → 本次会话自动换回浏览器 UA 续播，并弹一条明说的提示；**不改用户的设置**
//    （盘上开关原值保留），且**只回退一次**（不来回抖动）。
// 3. **关着时零介入**：开关关着 → 文案、有无按钮、重建次数与改动前逐字/逐次一致。
//
// 骨架与 test/player_auto_recover_wiring_test.dart 同款（播放器通道 + EventChannel
// 手工 mock、DownloadManager 内存替身、secure_storage / SharedPreferences /
// SystemChrome mock、取流接口用 PlayerPage.api 注入替身精确计数）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

/// 原生侧「当前播放位置」——回退续播必须带上它（不是从 0 重放）。
const int _kResumeMs = 42000;

WhitelistVideo _video() => const WhitelistVideo(
  bvid: 'BV1SCF00001',
  cid: 1001,
  // 标题刻意不含「免流兼容」：下面多处用 textContaining 断言归因文案，
  // 别让测试自己的样本把断言弄脏（同 stream_compat_test.dart 的做法）
  title: '流失败自救测试视频',
  cover: '',
  duration: 600,
  upName: '测试UP主',
  addedAt: '2026-01-01',
);

/// 单线路（无备用）的一批流：换源只能重取 playurl。
PlayUrlResult _singleLineBatch(String tag) => PlayUrlResult(
  quality: 80,
  dashVideoUrls: ['https://$tag.bilivideo.com/v.m4s'],
  dashAudioUrls: ['https://$tag.bilivideo.com/a.m4s'],
  dashVideoLines: [
    ['https://$tag.bilivideo.com/v.m4s'],
  ],
  dashAudioLines: [
    ['https://$tag.bilivideo.com/a.m4s'],
  ],
);

/// 取流接口替身：按调用次数返回批次，可切换为失败。
class _FakeApi extends BiliApi {
  _FakeApi(this.batches);

  final List<PlayUrlResult> batches;
  int calls = 0;
  bool fail = false;

  @override
  Future<PlayUrlResult> fetchPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    int fnval = 0,
  }) async {
    calls++;
    if (fail) throw StateError('取流失败（测试构造）');
    final i = calls - 1;
    return batches[i < batches.length ? i : batches.length - 1];
  }
}

/// 内存版 DownloadManager（零真实 IO；本测试要「没有缓存」→ 网络取流）。
class _EmptyManager extends DownloadManager {
  _EmptyManager() {
    cached.value = const [];
  }
}

/// 原生播放器通道桩：记录 create 的 UA、setDataSource、seekTo，可主动回推事件。
class _PlayerMocks {
  _PlayerMocks();

  MockStreamHandlerEventSink? sink;

  /// 每次 `create` 收到的参数（断言「换了 UA 才会重建播放器」）。
  final List<Map<Object?, Object?>> creates = [];

  /// setDataSource 的 videoUrl（断言重新取流）。
  final List<String> sources = [];

  /// seekTo 的位置（断言回退续播保留位置）。
  final List<int> seeks = [];

  /// 原生 getPosition 的返回值（续播位置）。
  int positionMs = _kResumeMs;

  /// setDataSource 后是否自动进 READY。false = 新源也起不来（用于「连续失败」
  /// 累积自动续播预算，因为 onPrepared 会把预算清零）。
  bool readyOnSetDataSource = false;

  String? get lastUserAgent =>
      creates.isEmpty ? null : creates.last['userAgent'] as String?;

  void emit(Map<String, Object?> payload) =>
      sink?.success({...payload, 'textureId': 7});

  /// 可自动恢复的数据源错误（403 / URL 过期 / 网络抖动，原生统一发这个）。
  void emitUrlExpired() => emit({'event': 'onUrlExpired'});

  /// 原生播放错误（原生归类为「不可自动恢复」才会走到这里）。
  void emitError({required int code, String message = 'Source error'}) =>
      emit({'event': 'onError', 'code': code, 'message': message});

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        switch (call.method) {
          case 'create':
            creates.add((call.arguments as Map).cast<Object?, Object?>());
            return 7;
          case 'getPosition':
            return positionMs;
          case 'seekTo':
            seeks.add((call.arguments as Map)['positionMs'] as int);
          case 'setDataSource':
            final map = call.arguments as Map;
            sources.add(map['videoUrl'] as String);
            if (readyOnSetDataSource) {
              sink?.success({
                'event': 'onPrepared',
                'textureId': map['textureId'],
                'width': 1280,
                'height': 720,
                'durationMs': 600000,
                'playWhenReady': true,
              });
            }
          default:
            break;
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
          sink = events;
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
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
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
  }
}

/// `_init` 里 `_downloads.init()` / `PlaybackProgress.load()` 各带 500ms 超时，
/// FakeAsync 下必须把时间推过 500ms 才会走到取源（同既有 player_* 测试）。
Future<void> _pumpReady(WidgetTester tester, _FakeApi api) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(411, 914);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(video: _video(), api: api),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 推进 [ms] 毫秒并多推几帧：异步链（事件 → 退避 → 通道调用 → onPrepared）
/// 每段都要一帧才落到状态里。
Future<void> _pumpMs(WidgetTester tester, int ms) async {
  await tester.pump(Duration(milliseconds: ms));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// 走完自动续播的三档退避（1s/2s/4s）：每档**先推一条原生事件**再等对应退避。
/// 每条事件只推进一格预算（[readyOnSetDataSource] 为 false 时不会有 onPrepared
/// 把预算清零），三轮之后 `_autoRecoverFails` 恰好到上限——再来一条事件就走
/// 放弃分支（或 gated 的自动回退）。
Future<void> _drainAutoRecoverBudget(
  WidgetTester tester,
  _PlayerMocks mocks,
) async {
  const backoff = [1000, 2000, 4000];
  for (var i = 0; i < backoff.length; i++) {
    mocks.emitUrlExpired();
    await _pumpMs(tester, backoff[i]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest();
    DownloadManager.debugOverride(_EmptyManager());
  });
  tearDown(() {
    DownloadManager.debugReset();
    UiPrefsStore.instance.resetForTest();
  });

  // -------------------------------------------------------------------------
  group('① 纯函数：归因与「流类失败」判定', () {
    test('withStreamCompatAttribution：关着原样返回；开着补一句归因', () {
      UiPrefsStore.instance.resetForTest();
      expect(
        withStreamCompatAttribution(kAutoRecoverGiveUpMessage),
        kAutoRecoverGiveUpMessage,
        reason: '开关关着 → 文案必须逐字不变（既有用例钉着它）',
      );
      expect(withStreamCompatAttribution('x'), 'x');

      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final on = withStreamCompatAttribution(kAutoRecoverGiveUpMessage);
      expect(on, contains(kStreamCompatAttribution));
      expect(on, contains('免流兼容'));
      expect(
        on,
        startsWith(kAutoRecoverGiveUpMessage),
        reason: '原文案是前缀，别把老话改掉，只是补一句',
      );
    });

    test('isStreamLevelNativeError：只认流类（403 / 网络 IO 兜底码），解码类不算', () {
      // 403：仓库实测「非浏览器 UA 取流」的形态（media3 文案是
      // `Invalid response code: 403`）
      expect(
        isStreamLevelNativeError(
          code: 3001,
          message: 'Invalid response code: 403',
        ),
        isTrue,
      );
      expect(
        isStreamLevelNativeError(
          code: kExoErrorIoNetworkConnectionFailed,
          message: 'Source error',
        ),
        isTrue,
      );
      expect(
        isStreamLevelNativeError(
          code: kExoErrorIoNetworkConnectionTimeout,
          message: 'timeout',
        ),
        isTrue,
      );
      expect(
        isStreamLevelNativeError(
          code: kExoErrorIoBadHttpStatus,
          message: 'bad status',
        ),
        isTrue,
      );
      // 解码失败 / 格式损坏：与 UA 无关，别硬扯上开关
      expect(
        isStreamLevelNativeError(code: 3001, message: '解码器初始化失败'),
        isFalse,
      );
      expect(
        isStreamLevelNativeError(code: 4001, message: 'malformed'),
        isFalse,
      );
    });

    test('streamCompatInUse：会话回退只影响"是否在用"，不动用户设置与盘上记录', () async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      expect(streamCompatInUse(), isTrue);
      expect(streamUserAgent(), kBiliAppUA);

      UiPrefsStore.instance.markStreamCompatSessionFallback();
      expect(streamCompatInUse(), isFalse, reason: '回退后本会话不再用官方 UA');
      expect(streamUserAgent(), kBrowserUA, reason: '回退后取流用浏览器 UA');
      expect(
        UiPrefsStore.instance.streamCompatEnabled,
        isTrue,
        reason: '**不改用户设置**：开关原值仍是开',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(UiPrefsStore.streamCompatKey),
        isNull,
        reason: '回退是纯内存的，绝不落盘',
      );
      expect(UiPrefsStore.instance.streamCompatSessionFallback, isTrue);
    });

    test('用户手动重新打开开关 → 会话回退清掉（"再试一次"）', () async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      UiPrefsStore.instance.markStreamCompatSessionFallback();
      expect(streamCompatInUse(), isFalse);

      await UiPrefsStore.instance.setStreamCompatEnabled(true);
      expect(streamCompatInUse(), isTrue, reason: '用户明确要再试一次');
      expect(streamUserAgent(), kBiliAppUA);

      // resetForTest 也要清（单例跨用例不能串味）
      UiPrefsStore.instance.markStreamCompatSessionFallback();
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      expect(UiPrefsStore.instance.streamCompatSessionFallback, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('② 开关关着：新逻辑零介入（既有文案/行为不变）', () {
    testWidgets('流失败到预算耗尽 → 原文案、无归因、无按钮、不重建播放器', (tester) async {
      final api = _FakeApi([_singleLineBatch('off1')]);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpReady(tester, api);
      expect(mocks.creates.length, 1);
      expect(mocks.lastUserAgent, kBrowserUA, reason: '关着 → 浏览器 UA（原行为）');

      await _drainAutoRecoverBudget(tester, mocks);
      mocks.emitUrlExpired(); // 第 4 条事件 → 预算已尽 → 放弃
      await _pumpMs(tester, 100);

      expect(
        find.text(kAutoRecoverGiveUpMessage),
        findsOneWidget,
        reason: '关着时放弃文案与改动前逐字一致',
      );
      expect(
        find.textContaining('免流兼容'),
        findsNothing,
        reason: '没开就不能让用户去关一个没开的开关',
      );
      expect(
        find.text(kStreamCompatFixLabel),
        findsNothing,
        reason: '关着时错误视图不该多出这个按钮',
      );
      expect(mocks.creates.length, 1, reason: '没有回退/重建');
      expect(UiPrefsStore.instance.streamCompatSessionFallback, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('③ 开关开着 + 流失败：自动回退（且不改用户设置）', () {
    testWidgets('预算耗尽 → 会话内换回浏览器 UA 重建续播 + 提示条，只回退一次', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final api = _FakeApi([_singleLineBatch('on1')]);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpReady(tester, api);

      expect(mocks.creates.length, 1);
      expect(
        mocks.lastUserAgent,
        kBiliAppUA,
        reason: '开着 → 取流头表用官方 App 特征 UA（这就是触发 403 的那个变化）',
      );
      expect(api.calls, 1);

      await _drainAutoRecoverBudget(tester, mocks);
      // 三档退避里每轮都换了一次源（单线路只能重取 playurl）
      final callsBefore = api.calls;
      final sourcesBefore = mocks.sources.length;
      // 预算已尽 → 下一条事件走放弃分支；此时让新流能 READY（断言"回退后续播成功"）
      mocks.readyOnSetDataSource = true;
      mocks.emitUrlExpired();
      await _pumpMs(tester, 1500);

      // ① 用浏览器 UA 重建了播放器（UA 是**创建期**参数，不重建就换不掉）
      expect(mocks.creates.length, 2, reason: '自动回退 = 重建播放器一次');
      expect(mocks.lastUserAgent, kBrowserUA, reason: '回退后取流用浏览器 UA');
      // ② 确实重新取流并续播（保留位置）
      expect(api.calls, callsBefore + 1, reason: '重建后重取 playurl');
      expect(mocks.sources.length, sourcesBefore + 1, reason: '重设源');
      expect(mocks.sources.last, contains('on1'), reason: '新源来自这次取流');
      expect(mocks.seeks, contains(_kResumeMs), reason: '从当前位置续播，不是回到 0 或记忆进度');
      // ③ 明确告知（否则用户以为免流还生效）
      expect(find.text(kStreamCompatFallbackNotice), findsOneWidget);
      expect(kStreamCompatFallbackNotice, contains('免流兼容'));
      // ④ 没有错误视图（这就是"开了也不会把应用用坏"）
      expect(find.text(kAutoRecoverGiveUpMessage), findsNothing);
      expect(find.text(kStreamCompatFixLabel), findsNothing);
      // ⑤ **不改用户的设置**：开关原值保留、盘上没被写过
      expect(UiPrefsStore.instance.streamCompatEnabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(UiPrefsStore.streamCompatKey),
        isNull,
        reason: '自动回退不落盘：重启后仍按用户设置再试一次',
      );
      expect(streamCompatInUse(), isFalse, reason: '本会话已回退');
    });

    testWidgets('回退后仍然失败 → 放弃出口带归因 + 一键自救按钮，且不会再回退第二次', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final api = _FakeApi([_singleLineBatch('on2')]);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpReady(tester, api);

      // 第一轮：预算耗尽 → 自动回退
      await _drainAutoRecoverBudget(tester, mocks);
      mocks.readyOnSetDataSource = true;
      mocks.emitUrlExpired();
      await _pumpMs(tester, 1500);
      expect(mocks.creates.length, 2);

      // 第二轮：回退后的浏览器 UA 同样起不来（模拟这个网络真的用不了）→ 放弃
      mocks.readyOnSetDataSource = false;
      await _pumpMs(tester, 100);
      await _drainAutoRecoverBudget(tester, mocks);
      mocks.emitUrlExpired();
      await _pumpMs(tester, 100);

      // 放弃出口：文案点名开关（用户设置原值还是开）+ 错误视图上有自救按钮
      expect(
        find.textContaining(kStreamCompatAttribution),
        findsOneWidget,
        reason: '开关开着 → 放弃文案必须带归因',
      );
      expect(
        find.textContaining(kAutoRecoverGiveUpMessage),
        findsOneWidget,
        reason: '原文案仍是前缀（关着时逐字一致由 ② 钉住）',
      );
      expect(find.text(kStreamCompatFixLabel), findsOneWidget);
      expect(mocks.creates.length, 2, reason: '回退是会话级的、只做一次（不回退第二次、不来回抖动）');
    });

    testWidgets('回退后连取流接口都失败 → 不再回退第二次（防回退风暴）', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final api = _FakeApi([_singleLineBatch('on3')]);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpReady(tester, api);
      expect(mocks.creates.length, 1);

      api.fail = true; // 之后重取一律失败（含回退后的那次 _init）
      mocks.emitUrlExpired();
      await tester.pump();
      await tester.pump();
      await _pumpMs(tester, 1000);
      await _pumpMs(tester, 2000);
      await _pumpMs(tester, 4000);
      await _pumpMs(tester, 1500); // 回退重建 + 复取流（失败）

      expect(mocks.creates.length, 2, reason: '只回退一次');
      expect(mocks.lastUserAgent, kBrowserUA);
      expect(UiPrefsStore.instance.streamCompatSessionFallback, isTrue);
      expect(
        find.textContaining('取流失败（测试构造）'),
        findsOneWidget,
        reason: '落回取流失败的既有错误出口，不会死循环',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('④ 一键自救：真关开关 + 重建 + 重取流续播', () {
    testWidgets('点「关掉免流兼容并重试」→ 落盘关掉 + 浏览器 UA 重取流续播', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      await UiPrefsStore.instance.setStreamCompatEnabled(true); // 先落盘"开"
      final api = _FakeApi([_singleLineBatch('fix1')]);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpReady(tester, api);

      // 走到「预算耗尽 + 已回退」的放弃出口（模拟 ③ 的长流程，简化为直接耗尽）
      await _drainAutoRecoverBudget(tester, mocks);
      mocks.readyOnSetDataSource = true;
      mocks.emitUrlExpired();
      await _pumpMs(tester, 1500); // 自动回退（会话内）
      mocks.readyOnSetDataSource = false;
      await _pumpMs(tester, 100);
      await _drainAutoRecoverBudget(tester, mocks);
      mocks.emitUrlExpired();
      await _pumpMs(tester, 100);
      expect(find.text(kStreamCompatFixLabel), findsOneWidget);
      final createsBefore = mocks.creates.length;
      final callsBefore = api.calls;

      mocks.readyOnSetDataSource = true; // 点完之后这次取流要能播起来
      await tester.tap(find.text(kStreamCompatFixLabel));
      await tester.pump();
      await _pumpMs(tester, 1500);

      // ① 开关被**真的**关掉（内存 + 落盘）——用户点的是"关掉"，界面不能说谎
      expect(UiPrefsStore.instance.streamCompatEnabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(UiPrefsStore.streamCompatKey),
        isFalse,
        reason: '一键自救是真关（落盘），与自动回退的"只本会话"不同',
      );
      expect(streamUserAgent(), kBrowserUA);
      // ② 重建播放器（UA 是创建期参数）+ 重新取流 + 续播当前视频
      expect(mocks.creates.length, createsBefore + 1);
      expect(mocks.lastUserAgent, kBrowserUA);
      expect(api.calls, callsBefore + 1, reason: '重新取流');
      expect(mocks.seeks, contains(_kResumeMs), reason: '继续播当前视频的位置');
      // ③ 播起来了：错误视图消失
      expect(find.text(kStreamCompatFixLabel), findsNothing);
      expect(find.textContaining(kAutoRecoverGiveUpMessage), findsNothing);
    });

    testWidgets('开关关着时错误视图不会出现这个按钮（点无可点）', (tester) async {
      final api = _FakeApi([_singleLineBatch('nofix')]);
      final mocks = _PlayerMocks()..install(tester);
      mocks.readyOnSetDataSource = false;
      await _pumpReady(tester, api);

      // 不可恢复类原生错误（解码失败）→ 立刻弹错，不做无谓重试
      mocks.emitError(code: 3001, message: '解码器初始化失败');
      await _pumpMs(tester, 100);
      expect(find.textContaining('播放失败（3001）'), findsOneWidget);
      expect(find.text(kStreamCompatFixLabel), findsNothing);
      expect(find.textContaining('免流兼容'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('⑤ 原生致命错误出口（非 onUrlExpired 那条）', () {
    testWidgets('开关开着 + 流级致命错误（403）→ 归因 + 一键自救按钮', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final api = _FakeApi([_singleLineBatch('fatal1')]);
      final mocks = _PlayerMocks()..install(tester);
      mocks.readyOnSetDataSource = false;
      await _pumpReady(tester, api);

      // 原生把 403 当致命错误报上来（真实路径上原生优先判可恢复、走 onUrlExpired，
      // 这条是「万一漏判」的兜底出口，v2.51.0 只在这里写了文案、没有自救动作）
      mocks.emitError(
        code: kExoErrorIoBadHttpStatus,
        message: 'Invalid response code: 403',
      );
      await _pumpMs(tester, 100);

      expect(find.textContaining('防盗链异常（403）'), findsOneWidget);
      expect(
        find.textContaining(kStreamCompatAttribution),
        findsOneWidget,
        reason: '必须指出可能是这个开关干的',
      );
      expect(
        find.text(kStreamCompatFixLabel),
        findsOneWidget,
        reason: '并且给一键自救（v2.51.0 只写了文案，用户还得自己找设置页）',
      );
    });

    testWidgets('开关开着 + 流级致命错误（2001 预算耗尽）→ 也带归因与按钮', (tester) async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final api = _FakeApi([_singleLineBatch('fatal2')]);
      final mocks = _PlayerMocks()..install(tester);
      mocks.readyOnSetDataSource = false;
      await _pumpReady(tester, api);

      // 先把自动续播预算耗尽（三条事件 → _autoRecoverFails 到上限），再让一条
      // 2001 落进致命分支：`_onNativeError` 的可恢复兜底因预算已尽而不再介入
      await _drainAutoRecoverBudget(tester, mocks);
      mocks.emitError(
        code: kExoErrorIoNetworkConnectionFailed,
        message: 'Source error',
      );
      await _pumpMs(tester, 100);

      expect(find.textContaining('播放失败（2001）'), findsOneWidget);
      expect(
        find.textContaining(kStreamCompatAttribution),
        findsOneWidget,
        reason: '2001 是流类失败 → 开关开着就该点名它',
      );
      expect(find.text(kStreamCompatFixLabel), findsOneWidget);
    });

    testWidgets('开关关着 + 同样的 403 致命错误 → 原文案、无归因、无按钮', (tester) async {
      final api = _FakeApi([_singleLineBatch('fatal3')]);
      final mocks = _PlayerMocks()..install(tester);
      mocks.readyOnSetDataSource = false;
      await _pumpReady(tester, api);

      mocks.emitError(
        code: kExoErrorIoBadHttpStatus,
        message: 'Invalid response code: 403',
      );
      await _pumpMs(tester, 100);

      expect(
        find.textContaining('防盗链异常（403），请稍后重试'),
        findsOneWidget,
        reason: '关着时与 v2.51.0 逐字一致',
      );
      expect(find.textContaining('免流兼容'), findsNothing);
      expect(find.text(kStreamCompatFixLabel), findsNothing);
    });
  });
}
