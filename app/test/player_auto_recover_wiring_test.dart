// 点播页自动续播**接线**测试（v2.45.0+）：把「原生报错 → Dart 换源 → 续播」
// 这条链真正跑一遍（既有 player_auto_recover_test.dart 只锁退避决策纯函数，
// 接线在点播页一直没有测试触发）。
//
// 覆盖：
// 1. `onUrlExpired` → **先在候选线路里轮转**（备用 CDN）：不重取 playurl、
//    setDataSource 收到下一条 URL 且带上 getPosition 的真实位置续播；
// 2. 候选耗尽（本批 3 条用完）→ 才重取 playurl 换一批，新批首条起播；
// 3. 重取一直失败 → 按退避表 1s/2s/4s 试 3 次 → 给出
//    kAutoRecoverGiveUpMessage（错误视图 + 重试按钮）；**不再继续**（第 4 次
//    不发请求）；
// 4. `onError` 兜底：可恢复类错误码（2001/2002）在预算内先走自动续播、耗尽才
//    弹致命错误；不可恢复类（3001 解码失败）立刻弹错、不做无谓重试。
//
// 骨架与 test/player_source_switch_test.dart 同款：播放器通道 + EventChannel
// 手工 mock、DownloadManager 内存替身、secure_storage / SharedPreferences /
// SystemChrome mock；取流接口用 `PlayerPage.api` 注入替身精确计数（其他 HTTP
// 请求由 flutter_test 的默认 HttpOverrides 直接 400，不阻塞测试）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

/// 原生侧「当前播放位置」——续播必须带上它（不是从 0 重放）。
const int _kResumeMs = 42000;

WhitelistVideo _video() => const WhitelistVideo(
      bvid: 'BV1AR000001',
      cid: 1001,
      title: '自动续播接线测试',
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 构造一批流：video 轨（baseUrl + 各 backupUrl）/ audio 轨同款。
PlayUrlResult _batch(
  List<String> videoLines,
  List<String> audioLines, {
  int quality = 80,
}) =>
    PlayUrlResult(
      quality: quality,
      dashVideoUrls: [videoLines.first],
      dashAudioUrls: audioLines.isEmpty ? const [] : [audioLines.first],
      dashVideoLines: [videoLines],
      dashAudioLines: audioLines.isEmpty ? const [] : [audioLines],
    );

/// 取流接口替身：按调用次数返回不同的「一批线路」，可切换为失败。
class _FakeApi extends BiliApi {
  _FakeApi(this.batches);

  /// 第 n 次 fetchPlayUrl 返回的批次（用完重复最后一批）。
  final List<PlayUrlResult> batches;

  /// 取流请求次数（断言「有没有重取 playurl」）。
  int calls = 0;

  /// true → 取流一律抛错（模拟网络/接口失败）。
  bool fail = false;

  /// 每次请求记下 fnval（DASH=16 / mp4 降级=0）。
  final List<int> fnvals = [];

  @override
  Future<PlayUrlResult> fetchPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    int fnval = 0,
  }) async {
    calls++;
    fnvals.add(fnval);
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

class _Rec {
  final List<Map<Object?, Object?>> dataSources = [];

  Map<Object?, Object?>? get last =>
      dataSources.isEmpty ? null : dataSources.last;

  String? get lastVideoUrl => last?['videoUrl'] as String?;
  String? get lastAudioUrl => last?['audioUrl'] as String?;

  /// setDataSource 的次数（轮转/重取都算一次换源）。
  int get switches => dataSources.length;
}

class _PlayerMocks {
  _PlayerMocks(this.rec);

  final _Rec rec;
  MockStreamHandlerEventSink? sink;

  /// 原生 getPosition 的返回值（续播位置）。
  int positionMs = _kResumeMs;

  /// setDataSource 后是否自动进 READY（false = 新源也起不来，用于「连续失败」）。
  bool readyOnSetDataSource = true;

  void emit(Map<String, Object?> payload) =>
      sink?.success({...payload, 'textureId': 7});

  /// 可自动恢复的数据源错误（URL 过期 / 网络抖动 / IO 兜底类 2001）。
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
            return 7;
          case 'getPosition':
            return positionMs;
          case 'setDataSource':
            final map = call.arguments as Map;
            rec.dataSources.add(map.cast<Object?, Object?>());
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
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('bili_dash_player/events'), null));

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
  }
}

/// `_init` 里 `_downloads.init()` / `PlaybackProgress.load()` 各带 500ms 超时，
/// FakeAsync 下必须把时间推过 500ms 才会走到取源（与既有 player_* 测试同款）。
Future<void> _pumpReady(WidgetTester tester, _FakeApi api) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(411, 914);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: PlayerPage(video: _video(), api: api)));
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

/// 三候选线路（baseUrl + 2 条备用）的一批流。
PlayUrlResult _threeLineBatch(String tag) => _batch(
      [
        'https://$tag-1.bilivideo.com/v.m4s',
        'https://$tag-2.bilivideo.com/v.m4s',
        'https://$tag-3.bilivideo.com/v.m4s',
      ],
      [
        'https://$tag-1.bilivideo.com/a.m4s',
        'https://$tag-2.bilivideo.com/a.m4s',
        'https://$tag-3.bilivideo.com/a.m4s',
      ],
    );

/// 单线路（无备用）的一批流：换源只能重取 playurl。
PlayUrlResult _singleLineBatch(String tag) => _batch(
      ['https://$tag.bilivideo.com/v.m4s'],
      ['https://$tag.bilivideo.com/a.m4s'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DownloadManager.debugOverride(_EmptyManager());
  });
  tearDown(DownloadManager.debugReset);

  testWidgets('onUrlExpired → 先轮转备用线路（不重取 playurl），视频/音频成对推进且带位置续播',
      (tester) async {
    final api = _FakeApi([_threeLineBatch('b1')]);
    final rec = _Rec();
    final mocks = _PlayerMocks(rec)..install(tester);
    await _pumpReady(tester, api);

    // 起播：首条线路 + 位置 0
    expect(api.calls, 1, reason: '_init 只取一次流');
    expect(rec.switches, 1);
    expect(rec.lastVideoUrl, 'https://b1-1.bilivideo.com/v.m4s');
    expect(rec.lastAudioUrl, 'https://b1-1.bilivideo.com/a.m4s');
    expect(rec.last?['positionMs'], 0);

    // ① 第一次报错 → 轮转到第 2 条（video/audio 同一游标），**不重取 playurl**
    mocks.emitUrlExpired();
    await _pumpMs(tester, 1000);
    expect(api.calls, 1, reason: '本批还有备用线路 → 不该重取 playurl');
    expect(rec.switches, 2);
    expect(rec.lastVideoUrl, 'https://b1-2.bilivideo.com/v.m4s');
    expect(rec.lastAudioUrl, 'https://b1-2.bilivideo.com/a.m4s',
        reason: '音频必须跟着视频一起换（成对推进）');
    expect(rec.last?['positionMs'], _kResumeMs,
        reason: '续播要带上 getPosition 的真实位置，不是从 0 重放');

    // ② 再报错 → 第 3 条，仍不重取
    mocks.emitUrlExpired();
    await _pumpMs(tester, 1000);
    expect(api.calls, 1);
    expect(rec.lastVideoUrl, 'https://b1-3.bilivideo.com/v.m4s');
    expect(rec.lastAudioUrl, 'https://b1-3.bilivideo.com/a.m4s');

    // ③ 再报错 → 本批候选耗尽 → 重取 playurl 换一批（新批首条起播）
    mocks.emitUrlExpired();
    await _pumpMs(tester, 1000);
    expect(api.calls, 2, reason: '候选耗尽才重取 playurl');
    expect(rec.switches, 4);
    expect(rec.lastVideoUrl, 'https://b1-1.bilivideo.com/v.m4s',
        reason: '替身对第 2 次请求返回同一批 → 新批首条（游标已重置）');
    expect(rec.last?['positionMs'], _kResumeMs);
  });

  testWidgets('重取一直失败 → 退避 1s/2s/4s 试 3 次后放弃（给文案 + 不再继续）',
      (tester) async {
    final api = _FakeApi([_singleLineBatch('s1')]);
    final rec = _Rec();
    final mocks = _PlayerMocks(rec)..install(tester);
    await _pumpReady(tester, api);
    expect(api.calls, 1);
    expect(rec.switches, 1);

    api.fail = true; // 之后重取一律失败（单线路 → 只能重取）
    mocks.emitUrlExpired();
    await tester.pump(); // 派发事件（内部先 await 退避）
    await tester.pump();

    // 第 1 次：等 1s 后重取（失败，无 setDataSource）
    await _pumpMs(tester, 1000);
    expect(api.calls, 2, reason: '第 1 次尝试在 1s 退避后发起');
    expect(rec.switches, 1, reason: '取流失败不会设源');
    expect(find.text(kAutoRecoverGiveUpMessage), findsNothing);

    // 第 2 次：再等 2s
    await _pumpMs(tester, 2000);
    expect(api.calls, 3, reason: '第 2 次尝试在 2s 退避后发起');
    expect(find.text(kAutoRecoverGiveUpMessage), findsNothing);

    // 第 3 次：再等 4s → 用尽预算 → 自动恢复放弃，显示错误（保留重试按钮）
    await _pumpMs(tester, 4000);
    expect(api.calls, 4, reason: '第 3 次尝试在 4s 退避后发起');
    expect(find.text(kAutoRecoverGiveUpMessage), findsOneWidget);
    // 「重试」按钮存在即可（页面下方 UP 主信息 / 评论区各自的错误块也有同名按钮
    // ——它们都因为默认 HttpOverrides 返回 400 而处于错误态，故用 findsWidgets）
    expect(find.text('重试'), findsWidgets, reason: '放弃后仍有手动重试兜底');

    // 之后不再继续折腾：多推 10s，取流次数不再增长
    await _pumpMs(tester, 10000);
    expect(api.calls, 4, reason: '预算耗尽后不再自动重试');
  });

  testWidgets('候选表缺失（旧样本形态）→ 无候选时重取，且音轨不被丢弃', (tester) async {
    // 手工构造的 PlayUrlResult（不带 dashVideoLines/dashAudioLines，模拟旧解析
    // / 其他调用方构造的样本）：候选退化为「只有主线路」→ 换源只能重取，
    // 但**音轨不能丢**（丢了这个视频就变无声画面）
    final api = _FakeApi([
      const PlayUrlResult(
        quality: 80,
        dashVideoUrls: ['https://v1.bilivideo.com/v.m4s'],
        dashAudioUrls: ['https://a1.bilivideo.com/a.m4s'],
      ),
    ]);
    final rec = _Rec();
    final mocks = _PlayerMocks(rec)..install(tester);
    await _pumpReady(tester, api);
    expect(api.calls, 1);
    expect(rec.lastAudioUrl, 'https://a1.bilivideo.com/a.m4s');

    mocks.emitUrlExpired();
    await _pumpMs(tester, 1000);
    expect(api.calls, 2, reason: '没有候选线路 → 直接重取 playurl');
    expect(rec.switches, 2);
    expect(rec.lastVideoUrl, 'https://v1.bilivideo.com/v.m4s');
    expect(rec.lastAudioUrl, 'https://a1.bilivideo.com/a.m4s',
        reason: '换源后音轨必须还在（不能变成无声画面）');
    expect(rec.last?['positionMs'], _kResumeMs);
  });

  testWidgets('可恢复类原生错误（2001）在预算内先走自动续播，耗尽才弹致命错误',
      (tester) async {
    final api = _FakeApi([_singleLineBatch('e1')]);
    final rec = _Rec();
    final mocks = _PlayerMocks(rec)..install(tester);
    await _pumpReady(tester, api);
    expect(api.calls, 1);

    api.fail = true;
    mocks.emitError(code: kExoErrorIoNetworkConnectionFailed); // 2001
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('播放失败（2001）'), findsNothing,
        reason: '可恢复类错误码先兜一次自动续播，不直接弹致命错误');

    // 三次退避（1s/2s/4s）后仍失败 → 落到放弃文案（不是「播放失败（2001）」：
    // 兜底走的就是自动续播那条路，耗尽后与 onUrlExpired 同款结局）
    await _pumpMs(tester, 1000);
    expect(api.calls, 2, reason: '兜底确实重取了一次 playurl');
    await _pumpMs(tester, 2000);
    expect(api.calls, 3);
    await _pumpMs(tester, 4000);
    expect(api.calls, 4);
    expect(find.text(kAutoRecoverGiveUpMessage), findsOneWidget);
    expect(find.text('重试'), findsWidgets);
  });

  testWidgets('不可恢复类原生错误（3001 解码失败）→ 立刻弹错，不做无谓重试',
      (tester) async {
    final api = _FakeApi([_singleLineBatch('e2')]);
    final rec = _Rec();
    final mocks = _PlayerMocks(rec)..install(tester);
    await _pumpReady(tester, api);
    expect(api.calls, 1);

    mocks.emitError(code: 3001, message: '解码器初始化失败');
    await _pumpMs(tester, 100);
    expect(find.textContaining('播放失败（3001）'), findsOneWidget);
    await _pumpMs(tester, 10000);
    expect(api.calls, 1, reason: '解码类错误重试无意义 → 一次自动重取都不该有');
  });
}
