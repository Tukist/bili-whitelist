// 直播播放页（v2.27.0+）widget 测试。
//
// 覆盖（对应验收清单里「Dart 侧契约」的部分，原生 HLS 那半边由 build + 真机验证）：
// - 取流失败 → 可重试的错误态（点「重试」重新取流并起播）；未开播 → 「直播已结束」；
// - 成功 → `setDataSource(..., isLive: true)` **且 create(isLive: true)**
//   （这条专门防「忘了透传 isLive」的回归：透传断了就退化成 VOD 组源，
//   原生侧既不会走 HlsMediaSource、通知栏也会冒出 seek 按钮）；
// - 直播页**没有**进度条 / 倍速 / 选集 / 前后三秒 / 下载 / 字幕（不显示也不注册）；
// - 播完（onCompleted）→ 「直播已结束」+「重新连接」，**不是**「播放完成」；
// - 不写历史 / 不写播放进度（直播没有 bvid，写进去会污染历史与统计）；
// - 观看时长计入 [WatchStats]（暂停不计，退页落盘）；
// - 地址续期：剩余 11 分钟 → 约 1 分钟后自动换新地址续播；
// - 失败自愈：onUrlExpired → 退避重连（重取地址 + 重设源），预算用尽 → 错误态；
//   **BehindLiveWindow（code=1002）→ 不进错误态、第 1 次不退避立刻重取**，
//   但连续不恢复仍受「3 次 / 退避」约束最终落到错误态；
// - dispose 后定时器全停、不再打接口；
// - 媒体通知：文案带「直播」、positionMs/durationMs 都是 0；
// - 两个入口（UP 主页 / 信箱顶卡）点「正在直播」标记 → 进站内直播页。
//
// 测试骨架与 test/player_media_notification_test.dart / test/live_status_test.dart 同款：
// mock 播放器 MethodChannel + EventChannel、SystemChrome、secure_storage、SharedPreferences。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/live_play_info.dart';
import 'package:bili_whitelist_app/models/live_status.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/pages/live_player_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/danmaku_overlay.dart';

const int _kRoom = 21452505;
const int _kUpMid = 546195;
const String _kTitle = '一起来聊天';
const String _kUpName = '测试UP主';

/// 一条可播的直播取流结果（默认剩余 11 分钟 → 续期定时器 1 分钟后触发）。
LivePlayInfo _liveInfo({int expiresInSec = 11 * 60}) => LivePlayInfo(
      roomId: _kRoom,
      liveStatus: 1,
      hlsUrl: 'https://cdn.example.com/live/index.m3u8?expires=1&sig=abc',
      quality: 10000,
      expiresAtEpochSec:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresInSec,
      host: 'https://cdn.example.com',
      protocolName: 'http_hls',
      formatName: 'fmp4',
      codecName: 'avc',
    );

/// 直播取流接口替身（页面通过 [LivePlayerPage.api] 注入）。
class _FakeApi extends BiliApi {
  _FakeApi({this.info});

  /// null = 取流失败（返回 null 不抛，与真实实现一致）。
  LivePlayInfo? info;

  int calls = 0;

  /// 非空时把这之后的取流都挂起，直到测试手动 [Completer.complete]。
  ///
  /// 为什么需要：重连是「重取地址 → 重设源」两步异步，假时钟下几十微秒就跑完，
  /// 「正在重新连接…」这种**进行中**的界面状态根本没机会被 pump 到。卡住取流
  /// 就能稳定断言「重连进行中」的那一帧（用完记得清掉，否则退页时挂着的 future
  /// 会让 flutter_test 判 pending）。
  Completer<void>? gate;

  @override
  Future<LivePlayInfo?> fetchLivePlayUrl(int roomId, {int qn = 10000}) async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    return info;
  }
}

// ---------------------------------------------------------------------------
// 播放器通道 mock
// ---------------------------------------------------------------------------

class _Rec {
  /// 收到的通道方法名（不含 create）。
  final List<String> methods = [];

  /// create 的入参（断言 isLive 有没有透传）。
  final List<Map<Object?, Object?>> createArgs = [];

  /// setDataSource 的入参（顺序 = 起播 / 续期 / 重连）。
  final List<Map<Object?, Object?>> setDataSource = [];

  /// updateNowPlaying 的载荷。
  final List<Map<Object?, Object?>> nowPlaying = [];
}

class _PlayerMocks {
  _PlayerMocks(this.rec);

  final _Rec rec;
  MockStreamHandlerEventSink? sink;
  int textureId = 7;

  void emit(Map<String, Object?> payload) =>
      sink?.success({...payload, 'textureId': textureId});

  /// 原生进 READY。直播的 durationMs 恒为 0（原生 `C.TIME_UNSET`）。
  void emitPrepared({bool playWhenReady = true, int durationMs = 0}) => emit({
        'event': 'onPrepared',
        'width': 1280,
        'height': 720,
        'durationMs': durationMs,
        'playWhenReady': playWhenReady,
      });

  /// 直播流结束（主播下播 / 流断了）。
  void emitCompleted() => emit({'event': 'onCompleted'});

  /// 可自动恢复的数据源错误（地址过期 / 网络抖动）。
  void emitUrlExpired() => emit({'event': 'onUrlExpired'});

  /// 原生播放错误（不可自动恢复类）：[code] = ExoPlayer 的
  /// `PlaybackException.errorCode`（原生原样透传，见 DashExoPlayer.onPlayerError）。
  /// 1002 = `ERROR_CODE_BEHIND_LIVE_WINDOW`。
  void emitError({required int code, String message = '播放失败'}) =>
      emit({'event': 'onError', 'code': code, 'message': message});

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('bili_dash_player'),
      (call) async {
        if (call.method == 'create') {
          rec.createArgs.add(call.arguments as Map);
          return textureId;
        }
        rec.methods.add(call.method);
        switch (call.method) {
          case 'setDataSource':
            final map = call.arguments as Map;
            rec.setDataSource.add(map);
            textureId = (map['textureId'] as num).toInt();
            // 原生 setDataSource 后自动 play()：直接推 onPrepared
            emitPrepared();
          case 'updateNowPlaying':
            rec.nowPlaying.add(call.arguments as Map<Object?, Object?>);
          default:
            break; // 未知方法（含 requestNotificationPermission）返回 null
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

    // 登录态安全存储（BiliApi 构造/取流会读 SESSDATA）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null));
  }
}

/// 挂载直播页并等到取流 + onPrepared 完成。
Future<void> _pumpLive(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.pumpWidget(MaterialApp(
    home: LivePlayerPage(
      roomId: _kRoom,
      title: _kTitle,
      upName: _kUpName,
      upMid: _kUpMid,
      api: api,
    ),
  ));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 逐秒推进 [seconds] 秒（大跨度一次 pump 也能跑，但分步更接近真实 tick 节奏）。
Future<void> _pumpSeconds(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// 退页（触发 dispose：停定时器 + 关播放器 + 恢复系统 UI）。
Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

// ---------------------------------------------------------------------------
// 入口页用例用的替身（UP 主页 / 信箱）
// ---------------------------------------------------------------------------

bool _hasKey(SharedPreferences prefs, String prefix) =>
    prefs.getKeys().any((k) => k.startsWith(prefix));

/// UP 主页替身：**粉丝数/资料接口都失败**，视频列表给空但成功，只把开播状态与
/// 取流做成可控。
///
/// 为什么连粉丝数都要失败：`_loadInfo` 拿到粉丝数就会 `_info = _infoWithFans(...)`
/// → `_info` 非空 → 顶栏头像走 `Image.network(info.face)`，而这里的 face 是空串
/// → 在 widget 测试里必然抛 NetworkImageLoadException（既有页面在真实环境有
/// errorBuilder 兜底，但异常仍会被测试框架判失败）。那是既有页面的头像兜底
/// 问题，不是本任务要覆盖的东西，所以这里让所有资料接口都失败（走 initial/占位）。
class _FakeUpownerApi extends BiliApi {
  _FakeUpownerApi({this.live});

  final LiveStatus? live;

  @override
  Future<LiveStatus?> fetchLiveStatusByMid(int mid) async => live;

  @override
  Future<int> fetchUpownerFollower(int mid) async =>
      throw const BiliApiException(code: -1, message: 'fake: stat 失败');

  @override
  Future<UpownerInfo> fetchUpownerInfo(int mid) async =>
      throw const BiliApiException(code: -1, message: 'fake: 资料接口失败');

  @override
  Future<UpownerVideosPage> fetchUpownerVideos(
    int mid, {
    int pn = 1,
    int ps = 20,
    String order = 'pubdate',
    String keyword = '',
  }) async =>
      const UpownerVideosPage(videos: [], totalCount: 0, hasMore: false);

  @override
  Future<UpownerCollectionsResult> fetchUpownerCollections(
    int mid, {
    int pageNum = 1,
    int pageSize = 20,
  }) async =>
      const UpownerCollectionsResult(seasons: [], series: []);

  @override
  Future<LivePlayInfo?> fetchLivePlayUrl(int roomId, {int qn = 10000}) async =>
      null; // 入口用例只验证"进了站内直播页"，取流失败正好走错误态（不发网络）
}

class _FakeInboxService extends InboxService {
  _FakeInboxService(this.items);

  final List<InboxItem> items;

  @override
  Future<List<InboxItem>> getItems() async => items;

  @override
  Future<InboxCheckResult> checkAll({bool force = false}) async =>
      InboxCheckResult(total: 0, unseen: items.length, items: items);

  @override
  Future<void> markHandled(String bvid) async {}

  @override
  Future<void> unmarkHandled(InboxItem item) async {}

  @override
  Future<void> markAllRead() async {}
}

class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<SyncResult> sync() async => SyncResult(
        data: WhitelistData.empty(),
        sourceName: 'fake',
        fetchedAt: DateTime.now(),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

class _FakeGithubApi extends GithubApi {
  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() async => WhitelistData.empty();

  @override
  Future<bool> saveToGist(WhitelistData wl) async => true;
}

InboxItem _inboxItem() => const InboxItem(
      upMid: _kUpMid,
      upName: _kUpName,
      upFace: '',
      bvid: 'BV1a',
      title: '新视频 BV1a',
      cover: '',
      duration: 100,
      pubDate: 1700000000,
    );

/// 推进若干帧直到 [finder] 找到东西（最多 steps × 50ms）。
Future<void> _pumpUntil(WidgetTester tester, Finder finder,
    {int steps = 40}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// 点「正在直播」标记。
///
/// ⚠️ 必须点**胶囊内部**：[LiveNowBadge] 本体是整行的 `Align(centerLeft)`
/// （宽度撑满宿主），`tester.tap(find.byType(LiveNowBadge))` 会落在胶囊
/// 右侧的空白处 → 命中不到 InkWell（实测警告 "would not hit test"，
/// 而且点击静默失效）。
Future<void> _tapBadge(WidgetTester tester) async {
  final rect = tester.getRect(find.byType(LiveNowBadge));
  await tester.tapAt(Offset(rect.left + 24, rect.center.dy));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    MotionControl.enabled = false;
    SharedPreferences.setMockInitialValues({});
    // WatchStats 是单例：每个用例先按空数据重载，基线才干净
    await WatchStats.instance.load();
    LiveStatusHub.instance.clear();
  });

  tearDown(MotionControl.reset);

  group('取流 / 播放', () {
    testWidgets('取流失败 → 可重试错误态；点「重试」重新取流并起播', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeApi(); // info == null → 取流失败
      await _pumpLive(tester, api);

      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(rec.setDataSource, isEmpty, reason: '没拿到地址不该设源');

      // 网络恢复：点重试 → 重新取流并起播
      api.info = _liveInfo();
      final before = api.calls;
      await tester.tap(find.text('重试'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(api.calls, greaterThan(before));
      expect(rec.setDataSource, hasLength(1));
      expect(rec.setDataSource.single['isLive'], true);
      expect(find.byType(AppErrorView), findsNothing);
    });

    testWidgets('成功：create(isLive:true) + setDataSource(isLive:true)（防忘透传）',
        (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);

      expect(rec.createArgs.single['isLive'], true,
          reason: '直播必须在**构建期**告知原生（不设 seek 增量，通知栏才没有 seek）');
      final ds = rec.setDataSource.single;
      expect(ds['isLive'], true,
          reason: '漏了它就退化成 VOD 组源（ProgressiveMediaSource 播不了 HLS）');
      expect(ds['videoUrl'], api.info!.hlsUrl);
      expect(ds['positionMs'], 0, reason: '直播无进度语义');
      expect(ds['artist'], _kUpName);
      expect(find.byType(AppErrorView), findsNothing);
      // 界面进入播放态
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });

    testWidgets('直播页没有进度条 / 倍速 / 选集 / 下载 / 字幕（也不注册左右滑）',
        (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      await _pumpLive(tester, _FakeApi(info: _liveInfo()));

      expect(find.byType(Slider), findsNothing, reason: '直播不可 seek');
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (final label in ['倍速', '选集', '画质', '字幕']) {
        expect(find.text(label), findsNothing);
      }
      for (final icon in [
        Icons.download,
        Icons.comment_outlined,
        Icons.subtitles,
        Icons.replay_10,
        Icons.forward_10,
      ]) {
        expect(find.byIcon(icon), findsNothing);
      }
      // 弹幕（v2.27.0 接入）：位置区域在（关着时是占位空盒），开关可用
      // （开关状态与设置一起持久化，默认关 → 不连弹幕服务器），另有设置入口
      expect(find.byKey(kLiveDanmakuSeamKey), findsOneWidget);
      expect(find.text('弹幕'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      final danmakuSwitch = tester.widget<Switch>(find.byType(Switch));
      expect(danmakuSwitch.onChanged, isNotNull, reason: '弹幕开关要能点');
      expect(danmakuSwitch.value, isFalse, reason: '默认关（不联网、不耗流量）');
      expect(find.byType(DanmakuOverlay), findsNothing, reason: '关着时零开销');
      // 左右滑不做任何事：横向 pan 不会 seek（原生侧也没有 seek 可调）
      await tester.drag(find.byKey(const ValueKey('live-video-area')),
          const Offset(-120, 0));
      await tester.pump();
      expect(rec.methods, isNot(contains('seekTo')));

      await _disposePage(tester);
    });

    testWidgets('播完（onCompleted）→「直播已结束」+「重新连接」，不是「播放完成」',
        (tester) async {
      final rec = _Rec();
      final mocks = _PlayerMocks(rec)..install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);

      mocks.emitCompleted();
      await tester.pump();
      await tester.pump();

      expect(find.text('重新连接'), findsOneWidget);
      expect(find.text('直播已结束'), findsWidgets);
      expect(find.textContaining('播放完成'), findsNothing);
      expect(rec.nowPlaying.last['status'], '直播已结束');

      // 下播后停掉续期：再等很久也不该继续打取流接口
      final calls = api.calls;
      await tester.pump(const Duration(minutes: 70));
      expect(api.calls, calls, reason: '下播后不该再续期换地址');
    });

    testWidgets('「重新连接」按钮 → 重新取流并起播', (tester) async {
      final rec = _Rec();
      final mocks = _PlayerMocks(rec)..install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);
      mocks.emitCompleted();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('重新连接'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(rec.setDataSource, hasLength(2));
      expect(rec.setDataSource.last['isLive'], true);
      expect(find.text('重新连接'), findsNothing, reason: '重连成功后结束态收掉');
    });

    testWidgets('未开播（live_status != 1）→ 「直播已结束」，不设源', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeApi(
        info: const LivePlayInfo(roomId: _kRoom, liveStatus: 0),
      );
      await _pumpLive(tester, api);

      expect(rec.setDataSource, isEmpty);
      expect(find.byType(AppErrorView), findsNothing,
          reason: '「不可播」不是「取流失败」，不该显示错误态');
      expect(find.text('重新连接'), findsOneWidget);
      expect(find.text('直播已结束'), findsWidgets);
    });
  });

  group('观看时长统计（核心功能：看直播也要算时长）', () {
    testWidgets('播放中按 10 秒批量落盘到 WatchStats', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      await _pumpLive(tester, _FakeApi(info: _liveInfo()));

      final before = WatchStats.instance.todaySeconds;
      await _pumpSeconds(tester, 12);
      final after = WatchStats.instance.todaySeconds;
      expect(after, greaterThan(before), reason: '看直播必须计入观看时长');
      expect(after - before, inInclusiveRange(10, 12), reason: '10 秒粒度批量落盘');

      await _disposePage(tester);
    });

    testWidgets('暂停后不再累计（且暂停瞬间把已累计的落盘）', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      await _pumpLive(tester, _FakeApi(info: _liveInfo()));
      await _pumpSeconds(tester, 12);
      final playing = WatchStats.instance.todaySeconds;

      // 控制层 4s 后自动收起 → 先点画面唤出，再点暂停
      await tester.tap(find.byKey(const ValueKey('live-video-area')));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final paused = WatchStats.instance.todaySeconds;
      await _pumpSeconds(tester, 10);
      expect(WatchStats.instance.todaySeconds, paused,
          reason: '暂停期间的时间不算观看');
      expect(paused, greaterThanOrEqualTo(playing));

      await _disposePage(tester);
    });

    testWidgets('不写历史 / 不写播放进度（直播没有 bvid，写进去会污染统计）',
        (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      await _pumpLive(tester, _FakeApi(info: _liveInfo()));
      final before = WatchStats.instance.todaySeconds;
      await _pumpSeconds(tester, 12);
      // 反证：观看时长**确实**记了（否则下面的"没写"断言可能只是因为什么都没写）
      expect(WatchStats.instance.todaySeconds, greaterThan(before));
      await _disposePage(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(_hasKey(prefs, 'history_store'), isFalse);
      expect(_hasKey(prefs, 'playback_progress'), isFalse);
    });
  });

  group('地址续期 / 失败自愈', () {
    testWidgets('剩余 11 分钟 → 约 1 分钟后换新地址续播（不打断、不进错误态）',
        (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeApi(info: _liveInfo(expiresInSec: 11 * 60));
      await _pumpLive(tester, api);
      expect(rec.setDataSource, hasLength(1));

      await _pumpSeconds(tester, 62);

      expect(api.calls, greaterThanOrEqualTo(2), reason: '到期前要重新取流');
      expect(rec.setDataSource.length, greaterThanOrEqualTo(2),
          reason: '取到新地址要重设源（直播从最新处继续播）');
      expect(rec.setDataSource.last['isLive'], true);
      expect(find.byType(AppErrorView), findsNothing,
          reason: '续期换源不该弹错/打断');

      await _disposePage(tester);
    });

    testWidgets('续期取流失败 → 不打断当前播放，稍后再试', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeApi(info: _liveInfo(expiresInSec: 11 * 60));
      await _pumpLive(tester, api);

      api.info = null; // 之后取流一律失败
      await _pumpSeconds(tester, 62);

      expect(rec.setDataSource, hasLength(1), reason: '拿不到新地址就保持当前播放');
      expect(find.byType(AppErrorView), findsNothing);
      // 仍在播放态（控制层 4s 后会自动收起，所以看信息区的状态文案而不是图标）
      expect(find.text('正在直播'), findsOneWidget);

      await _disposePage(tester);
    });

    testWidgets('onUrlExpired → 退避重连：重取地址 + 重设源，期间提示「正在重新连接…」',
        (tester) async {
      final rec = _Rec();
      final mocks = _PlayerMocks(rec)..install(tester);
      await _pumpLive(tester, _FakeApi(info: _liveInfo()));

      mocks.emitUrlExpired();
      await tester.pump();
      await tester.pump(); // 两帧：第一帧派发事件（其中有一次 await），第二帧才是 setState 后的重建
      expect(find.text('正在重新连接…'), findsOneWidget);

      // 第一次退避 1s
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rec.setDataSource, hasLength(2));
      expect(rec.setDataSource.last['isLive'], true);
      expect(find.text('正在重新连接…'), findsNothing, reason: '新流 READY 后收起提示');
      expect(find.byType(AppErrorView), findsNothing);

      await _disposePage(tester);
    });

    testWidgets('重连预算用尽（3 次）→ 可重试错误态', (tester) async {
      final rec = _Rec();
      final mocks = _PlayerMocks(rec)..install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);

      api.info = null; // 后续取流全失败
      mocks.emitUrlExpired();
      await tester.pump();
      // 1s + 2s + 4s 三次退避
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.byType(AppErrorView), findsOneWidget);
      expect(rec.setDataSource, hasLength(1), reason: '取不到地址不会重设源');

      await _disposePage(tester);
    });

    testWidgets('BehindLiveWindow（code=1002）→ 静默自愈：不退避立刻重取地址、不进错误态',
        (tester) async {
      final rec = _Rec();
      final mocks = _PlayerMocks(rec)..install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);
      expect(rec.setDataSource, hasLength(1));
      final fetchBefore = api.calls;

      // 卡住这次重连的取流：把「重连进行中」的那一帧稳定下来
      final gate = api.gate = Completer<void>();
      mocks.emitError(code: 1002, message: 'BehindLiveWindowException');
      await tester.pump();
      await tester.pump();

      // 关键①：退避首档是 1s，而这里只推了两帧（0ms）→ 必须已经发起取流
      expect(api.calls, greaterThan(fetchBefore),
          reason: '1002 是确定性错误（窗口漂过），要**立刻**重取地址，不等 1s 退避');
      // 关键②：期间只给「正在重新连接…」，**绝不弹错误卡片**（真机闪断的根因）
      expect(find.text('正在重新连接…'), findsOneWidget);
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.textContaining('播放失败'), findsNothing);
      expect(find.textContaining('直播连接失败'), findsNothing);

      gate.complete(); // 放行取流
      api.gate = null;
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(rec.setDataSource, hasLength(2), reason: '取到新地址要重设源（静默自愈）');
      expect(rec.setDataSource.last['isLive'], true);
      expect(find.text('正在重新连接…'), findsNothing, reason: '恢复后提示收起');
      expect(find.byType(AppErrorView), findsNothing);

      await _disposePage(tester);
    });

    testWidgets('1002 连续不恢复 → 仍受「3 次 + 退避」约束，最终落到错误态（不死循环）',
        (tester) async {
      final rec = _Rec();
      final mocks = _PlayerMocks(rec)..install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);
      expect(rec.setDataSource, hasLength(1));

      api.info = null; // 之后一直取不到地址 → 1002 永远恢复不了
      mocks.emitError(code: 1002);
      await tester.pump();
      await tester.pump();
      // 第 1 次不退避，之后照走退避阶梯的 2s / 4s 两档
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.byType(AppErrorView), findsOneWidget,
          reason: '预算用尽必须落到错误态（否则 1002 会退化成无限重试）');
      expect(find.textContaining('直播连接失败'), findsOneWidget);
      expect(rec.setDataSource, hasLength(1), reason: '取不到地址不会重设源');

      await _disposePage(tester);
    });

    testWidgets('dispose 后：定时器全停、不再取流、播放器释放', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeApi(info: _liveInfo());
      await _pumpLive(tester, api);

      await _disposePage(tester);
      expect(rec.methods, contains('dispose'));

      final calls = api.calls;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(minutes: 1));
      }
      expect(api.calls, calls, reason: '退页后续期定时器必须停掉');
      expect(tester.takeException(), isNull);
    });
  });

  group('媒体通知', () {
    testWidgets('文案带「直播」；位置/时长都是 0（原生不显示进度）', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      await _pumpLive(tester, _FakeApi(info: _liveInfo()));

      expect(rec.nowPlaying, isNotEmpty);
      final np = rec.nowPlaying.last;
      expect(np['title'], '直播 · $_kTitle');
      expect(np['artist'], _kUpName);
      expect(np['status'], '正在直播');
      expect(np['playing'], true);
      expect(np['positionMs'], 0);
      expect(np['durationMs'], 0);
      expect(rec.methods, contains('requestNotificationPermission'),
          reason: '首次显示通知前请求一次通知权限（Android 13+）');

      await _disposePage(tester);
    });
  });

  group('入口：点「正在直播」标记进站内播放页', () {
    testWidgets('UP 主页：在播 → 点标记 push LivePlayerPage', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      final api = _FakeUpownerApi(
        live: const LiveStatus(
          mid: _kUpMid,
          roomId: _kRoom,
          liveStatus: 1,
          title: _kTitle,
        ),
      );
      await tester.pumpWidget(MaterialApp(home: UpownerPage(mid: _kUpMid, api: api)));
      await _pumpUntil(tester, find.byType(LiveNowBadge));
      expect(find.byType(LiveNowBadge), findsOneWidget);

      await _tapBadge(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final page = tester.widget<LivePlayerPage>(find.byType(LivePlayerPage));
      expect(page.roomId, _kRoom);
      expect(page.title, _kTitle);
      expect(page.upMid, _kUpMid);

      // 让下面那页（UpownerPage）的两条重试退避跑完（粉丝数 1s+2s，资料再 1s+2s）：
      // 否则用例结束时还挂着 Future.delayed 定时器，flutter_test 会判
      // "A Timer is still pending"
      await tester.pump(const Duration(seconds: 8));
      await _disposePage(tester);
    });

    testWidgets('信箱顶卡：在播 → 点角标 push LivePlayerPage', (tester) async {
      final rec = _Rec();
      _PlayerMocks(rec).install(tester);
      ServiceLocator.overrideInboxService(_FakeInboxService([_inboxItem()]));
      ServiceLocator.overrideSyncService(_FakeSyncService());
      final api = _FakeUpownerApi(
        live: const LiveStatus(
          mid: _kUpMid,
          roomId: _kRoom,
          liveStatus: 1,
          title: _kTitle,
        ),
      );
      await tester.pumpWidget(MaterialApp(
        home: InboxPage(
          api: api,
          writer: WhitelistWriter(github: _FakeGithubApi(), api: api),
        ),
      ));
      await _pumpUntil(tester, find.byType(LiveNowBadge));
      expect(find.byType(LiveNowBadge), findsOneWidget);

      await _tapBadge(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final page = tester.widget<LivePlayerPage>(find.byType(LivePlayerPage));
      expect(page.roomId, _kRoom);
      expect(page.upName, _kUpName);

      await _disposePage(tester);
    });
  });
}
