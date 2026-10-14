// 「免流兼容（实验）」开关（v2.51.0+，v2.52.0 换机制）测试。
//
// 背景（用户诉求 + 调研结论）：视频/音频数据本来就发往 B 站官方 CDN
// （*.bilivideo.com，与官方 App 同一批域名），但本 App 所有请求都带桌面
// Chrome UA。运营商若按「App 特征」判定定向免流范围，浏览器 UA 就不算数。
// 于是加一个**默认关闭**的实验开关。v2.51.x 只换流请求 UA；**v2.52.0 起改成
// 换整条取流链路**：播放改走 App gRPC `PlayView`（下发 `platform=android`
// 的直链，取流要「App 特征 UA + 不带 Referer」）—— 因为实测「网页直链
// （`platform=pc`）+ App UA」是**必然 403**。
//
// **v2.53.0 起离线缓存下载 / 语音转写临时音频也跟着开关走 `PlayView`**：它们
// 下载的就是流本身（正是免流该覆盖的流量），而 v2.51.x/2.52.0 那版只换了 UA、
// 直链还是网页接口 → 「pc 链 + App UA」= 必然 403（放着开关时下载/转写可能直接
// 失败）。两条链的请求头因此改成**按直链形态分流**
// （`config.biliStreamHeadersFor`，与原生 `DashExoPlayer.networkFactoryFor` 同一
// 判据）：pc 链 = 浏览器 UA + Referer，android 链 = App UA 且不带 Referer。
// 本文件第 5 组用真 loopback 服务器把两种形态都钉住。
//
// 这个开关有**真实风险**（万一运营商/CDN 策略不认，就会 403），
// 所以本文件把两件事钉死：
//   1. 默认关，且关着时行为与改动前**逐字节一致**（浏览器 UA + 网页接口）；
//   2. 打开后**只有流**换 UA —— API 头表 / 直播弹幕 WS 握手**一个都不许跟着变**
//      （防"顺手改多了"：API 改 UA 有 -412 风控风险，图片/弹幕改了与免流无关）。
// 另外钉住"失败要能自己看出来"：403 时播放页提示必须指向这个开关。
//
// 覆盖：
//   1. [UiPrefsStore.streamCompatKey]：默认关、落盘、冷启动读回；
//   2. `config.streamUserAgent()` / `biliStreamHeaders()`：关=浏览器 UA、
//      开=官方 App 特征 UA，Referer 恒定；
//   3. `BiliDashPlayer.create()` 把解析出的 UA **显式传给原生**（channel 桩断言
//      传入参数；VOD 与直播两条路都过这里）；
//   4. **离线下载请求头**用真 loopback HTTP 收（不是只看常量）：开关切换后
//      服务端收到的 User-Agent 跟着变、Referer 不变；
//   5. **API 头表 / 弹幕 WS 握手不动**（`biliHeaders()`、`LiveDanmakuClient.wsHeaders`）；
//   6. 设置页：[kStreamCompatSwitchKey] 默认关、点开落盘，小字含「实验」与
//      「自动切回普通模式」且非空白字符 ≤ 42（v2.51.1 起小字改成如实描述）；
//   7. 403 提示：开关开 → 文案含「免流兼容（实验）」指引；关 → 不含（且仍是
//      改动前的原文）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/api/live_danmaku_client.dart';
import 'package:bili_whitelist_app/api/sherpa_audio.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';
import 'package:bili_whitelist_app/player/bili_dash_player.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

// ---------------------------------------------------------------------------
// 替身 / 工具
// ---------------------------------------------------------------------------

WhitelistVideo _video({String bvid = 'BV1STR00001'}) => WhitelistVideo(
      bvid: bvid,
      cid: 1001,
      // 标题刻意**不含**「免流兼容」：下面的断言是 `findsNothing`
      // （textContaining 会命中标题，别让测试自己的样本把断言弄脏）
      title: '流 UA 开关测试视频',
      cover: '',
      duration: 600,
      upName: '测试UP主',
      addedAt: '2026-01-01',
    );

/// 内存版 secure storage（ManagePanel 读 B 站账号态要过它，否则
/// MissingPluginException；同 ui_prefs_snack_test 的做法）。
const MethodChannel _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
    if (call.method == 'read') return null;
    if (call.method == 'write') return true;
    if (call.method == 'delete') return true;
    return null;
  });
}

/// 挂设置页（视口放大到能看全，省得滚很远；同 ui_prefs_snack_test）。
Future<void> _pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ManagePanel(
            github: GithubApi(),
            headingTitle: '设置',
            headingSubtitle: '集中设置区（测试）',
            onManageCollections: () {},
            onCheckUpdate: () {},
            onLogin: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 取流接口替身（播放页 403 提示用例用）：固定返回单线路 DASH 双流。
class _FakeApi extends BiliApi {
  int calls = 0;

  @override
  Future<PlayUrlResult> fetchPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    int fnval = 0,
  }) async {
    calls++;
    return PlayUrlResult(
      quality: 80,
      dashVideoUrls: const ['https://s1.bilivideo.com/v.m4s'],
      dashAudioUrls: const ['https://s1.bilivideo.com/a.m4s'],
    );
  }
}

/// 内存版 DownloadManager（零真实 IO；只用来占住 `PlayerPage._init` 里的
/// `_downloads.init()`，同 player_auto_recover_wiring_test）。
class _EmptyManager extends DownloadManager {
  _EmptyManager() {
    cached.value = const [];
  }
}

/// 原生播放器通道桩：记录 setDataSource 参数、可主动回推原生事件。
class _PlayerMocks {
  MockStreamHandlerEventSink? sink;

  void emit(Map<String, Object?> payload) =>
      sink?.success({...payload, 'textureId': 7});

  /// 原生报错（不可自动恢复那一类才会走到播放页的「弹错」分支）。
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
            return 0;
          case 'setDataSource':
            final map = call.arguments as Map;
            sink?.success({
              'event': 'onPrepared',
              'textureId': map['textureId'],
              'width': 1280,
              'height': 720,
              'durationMs': 600000,
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
      MockStreamHandler.inline(onListen: (arguments, events) {
        sink = events;
      }),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('bili_dash_player/events'), null));

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    _mockSecureStorage();
  }
}

/// 起播并等就绪（`_init` 里 `_downloads.init()` / `PlaybackProgress.load()`
/// 各带 500ms 超时，必须把时间推过去；同既有 player_* 测试）。
Future<void> _pumpPlayerReady(WidgetTester tester, BiliApi api) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(411, 914);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
      MaterialApp(home: PlayerPage(video: _video(), api: api)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 推进时间并多推几帧（事件 → 状态 → 树）。
Future<void> _pumpMs(WidgetTester tester, int ms) async {
  await tester.pump(Duration(milliseconds: ms));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest();
  });
  tearDown(() => UiPrefsStore.instance.resetForTest());

  // -------------------------------------------------------------------------
  group('① 开关默认关 + 落盘', () {
    test('默认关（内存默认值与冷启动读盘都是关）', () async {
      expect(UiPrefsStore.instance.streamCompatEnabled, isFalse,
          reason: '默认必须关：打开它有可能让本来能播的视频 403');
      expect(UiPrefsStore.streamCompatKey, startsWith('ui:'));

      UiPrefsStore.instance.resetForTest(loaded: false);
      await UiPrefsStore.instance.ensureLoaded();
      expect(UiPrefsStore.instance.streamCompatEnabled, isFalse,
          reason: '盘上没记录 → 回默认关');
    });

    test('打开 → 落盘；冷启动读回同一个值（其它开关不受影响）', () async {
      await UiPrefsStore.instance.setStreamCompatEnabled(true);
      expect(UiPrefsStore.instance.streamCompatEnabled, isTrue, reason: '立即生效');
      expect(UiPrefsStore.instance.showTips, isTrue, reason: '提示开关不受牵连');
      expect(UiPrefsStore.instance.writeActionsEnabled, isFalse,
          reason: '写操作开关不受牵连');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(UiPrefsStore.streamCompatKey), isTrue, reason: '落盘');

      UiPrefsStore.instance.resetForTest(loaded: false);
      expect(UiPrefsStore.instance.streamCompatEnabled, isFalse,
          reason: '重置后是默认值（证明下面读到的是盘上的）');
      await UiPrefsStore.instance.ensureLoaded();
      expect(UiPrefsStore.instance.streamCompatEnabled, isTrue, reason: '冷启动仍是开');
    });
  });

  // -------------------------------------------------------------------------
  group('② 取 UA 判据（config）', () {
    test('关闭：流请求 UA = 浏览器 UA（与改动前逐字节一致）；开启 = 官方 App 特征 UA',
        () {
      UiPrefsStore.instance.resetForTest();
      expect(streamUserAgent(), kBrowserUA, reason: '关着时必须是改动前那一个');
      expect(kBrowserUA, contains('Chrome/'));

      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      expect(streamUserAgent(), kBiliAppUA);
      expect(streamUserAgent(), isNot(kBrowserUA));
    });

    test('官方 App UA 的原样值（BiliDroid 那套格式）', () {
      expect(kBiliAppUA, startsWith('Mozilla/5.0 BiliDroid/'));
      expect(kBiliAppUA, contains('os/android'));
      expect(kBiliAppUA, contains('model/'));
      expect(kBiliAppUA, contains('mobi_app/android'));
      expect(kBiliAppUA, contains('build/'));
      expect(kBiliAppUA, contains('channel/'));
      expect(kBiliAppUA, contains('innerVer/'));
    });

    test('下载请求头（biliStreamHeaders）：Referer 恒定，只有 UA 跟着开关走', () {
      UiPrefsStore.instance.resetForTest();
      expect(biliStreamHeaders(), {
        'User-Agent': kBrowserUA,
        'Referer': kBiliReferer,
      });

      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      expect(biliStreamHeaders(), {
        'User-Agent': kBiliAppUA,
        'Referer': kBiliReferer,
      }, reason: '只换 UA：Referer 必须还是 https://www.bilibili.com/');
    });
  });

  // -------------------------------------------------------------------------
  group('③ 只有流换 UA：API 头表 / 弹幕 WS 一个都不许跟着变', () {
    test('API 头表（biliHeaders）恒为浏览器 UA —— 防"顺手改多了"', () {
      for (final on in [false, true]) {
        UiPrefsStore.instance.resetForTest(streamCompatEnabled: on);
        expect(biliHeaders()['User-Agent'], kBrowserUA,
            reason: 'API 改 UA 会被 -412 风控（实测），开关无论如何都不能动它');
        expect(biliHeaders()['Referer'], kBiliReferer);
        expect(biliHeaders()['Origin'], 'https://www.bilibili.com');
      }
    });

    test('直播弹幕 WS 握手头恒为浏览器 UA（' 'Chrome' ' 那条既有断言的同一条链）',
        () {
      for (final on in [false, true]) {
        UiPrefsStore.instance.resetForTest(streamCompatEnabled: on);
        final h = LiveDanmakuClient.wsHeaders(12345);
        expect(h['User-Agent'], kBrowserUA);
        expect(h['User-Agent'], contains('Chrome'));
        expect(h['Origin'], 'https://live.bilibili.com');
      }
    });
  });

  // -------------------------------------------------------------------------
  group('④ 播放器初始化：UA 显式传给原生（channel 桩）', () {
    testWidgets('关闭 → create 传浏览器 UA；开启 → 传官方 App 特征 UA（VOD 与直播同一条路）',
        (tester) async {
      final creates = <Map<Object?, Object?>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('bili_dash_player'),
        (call) async {
          if (call.method == 'create') {
            creates.add((call.arguments as Map).cast<Object?, Object?>());
            return 7;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('bili_dash_player'), null));

      UiPrefsStore.instance.resetForTest();
      final vod = await BiliDashPlayer.create();
      expect(creates.last['userAgent'], kBrowserUA,
          reason: '关着时传给原生的 UA 必须与改动前一致（原生侧行为逐字节不变）');
      expect(creates.last['isLive'], isFalse);
      await vod.dispose();

      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final live = await BiliDashPlayer.create(isLive: true);
      expect(creates.last['userAgent'], kBiliAppUA, reason: '开启后换成官方 App 特征 UA');
      expect(creates.last['isLive'], isTrue, reason: '直播标记不受影响');
      await live.dispose();

      // 显式传参优先（调用方可覆盖）：给测试与将来别的入口留口子
      final custom = await BiliDashPlayer.create(userAgent: 'X/1');
      expect(creates.last['userAgent'], 'X/1');
      await custom.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('⑤ 离线下载请求头（真 loopback HTTP，不是只看常量）', () {
    test('服务端实收：**直链形态**决定请求头（pc 链=浏览器 UA+Referer，android 链=App UA 且无 Referer）',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uas = <String?>[];
      final referers = <String?>[];
      final sub = server.listen((req) async {
        uas.add(req.headers.value('user-agent'));
        referers.add(req.headers.value('referer'));
        req.response.statusCode = 200;
        req.response.add(List<int>.filled(8, 7));
        await req.response.close();
      });
      addTearDown(() async {
        await sub.cancel();
        await server.close(force: true);
      });

      final root = await Directory.systemTemp.createTemp('stream_compat_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      // flutter_test 默认把 HttpClient 换成"一律 400"的桩；这里要真连
      // loopback（127.0.0.1），所以临时摘掉（用完还原，同 offline_page_test 的做法）。
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = oldOverrides);

      /// 取流替身：直接给出**指定形态**的直链（v2.53.0 起请求头只看 URL，
      /// 所以这里要显式把两种形态都造出来 —— 真实世界里前端由哪条取流链决定）。
      Future<void> downloadOnce(String tag, bool compat,
          {required bool appShaped}) async {
        UiPrefsStore.instance.resetForTest(streamCompatEnabled: compat);
        final url = appShaped
            ? 'http://127.0.0.1:${server.port}/$tag.m4s?platform=android&qn=32'
            : 'http://127.0.0.1:${server.port}/$tag.m4s?platform=pc&qn=80';
        final mgr = DownloadManager(
          fetchPlayUrl:
              ({required String bvid, required int cid}) async =>
                  PlayUrlResult(
            quality: 80,
            dashVideoUrls: [url],
            dashAudioUrls: const [],
          ),
          rootDir: root,
          betweenTasks: Duration.zero,
          retryDelay: Duration.zero,
        );
        await mgr.downloadVideo(_video(bvid: 'BV1STR_$tag'), 0);
      }

      // ① 网页链（默认形态）：浏览器 UA + Referer（与改动前逐字节一致）
      await downloadOnce('off', false, appShaped: false);
      expect(uas, [kBrowserUA], reason: '网页链用浏览器 UA（非浏览器 UA 会 403）');
      expect(referers, [kBiliReferer], reason: '网页链 Referer 必需');

      // ② **v2.53.0 的 403 修复点**：开关开着但拿到的是网页链（PlayView 取流失败
      //    回落、或番剧走 pgc 端点）→ 必须用浏览器 UA。旧代码在这里发 App UA，
      //    实测「pc 签名 + App UA」必 403 → 下载直接失败。
      await downloadOnce('on_pc', true, appShaped: false);
      expect(uas.length, 2);
      expect(uas.last, kBrowserUA,
          reason: '网页链配 App UA 必 403：请求头要跟着**直链**走，不是跟着开关走');
      expect(referers.last, kBiliReferer);

      // ③ App 形态直链（开关打开时由 PlayView 下发）：App UA 且**不带 Referer**
      await downloadOnce('on_app', true, appShaped: true);
      expect(uas.length, 3);
      expect(uas.last, kBiliAppUA, reason: 'App 形态链要 App 特征 UA');
      expect(referers.last, isNull,
          reason: 'App 形态链带 Referer 必 403（2026-10 实测）');
    });

    test('biliStreamHeadersFor：与原生 networkFactoryFor 同一判据（纯函数逐值钉住）', () {
      // 判据是 URL 里的 CDN 签名参数，**不是开关状态** —— 同一次会话里两种链会并存
      for (final on in [false, true]) {
        UiPrefsStore.instance.resetForTest(streamCompatEnabled: on);
        expect(
          biliStreamHeadersFor('https://x.bilivideo.com/a.m4s?platform=android&qn=32'),
          {'User-Agent': kBiliAppUA},
          reason: 'App 形态链：只有 UA、没有 Referer（开关原值不该改变这个结论）',
        );
        expect(
          biliStreamHeadersFor('https://x.bilivideo.com/a.m4s?platform=pc&qn=80'),
          {'User-Agent': kBrowserUA, 'Referer': kBiliReferer},
        );
        // 直播 HLS 没有 platform 参数 → 走网页那套（Referer + 浏览器 UA）
        expect(
          biliStreamHeadersFor('https://x.bilivideo.com/live/1.m3u8'),
          {'User-Agent': kBrowserUA, 'Referer': kBiliReferer},
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // ⑤b 开关打开时**下载/语音转写改走 PlayView**（v2.53.0）
  //
  // 上一版的 bug：那两条链只换了 UA、直链仍是网页接口（`platform=pc`），而
  // 「pc 链 + App UA」= 必然 403（⇔ 开着开关时下载/转写可能直接失败）。
  // 现在两条链与播放页同一条路：先试 App gRPC `PlayView`，拿不到就回落网页接口。
  // -------------------------------------------------------------------------
  group('⑤b 下载 / 语音转写：开关打开时也走 App 取流链', () {
    /// 一条 App 形态流（`platform=android`，与 PlayView 下发的一致）。
    PlayUrlResult appShapedStream(String tag) => PlayUrlResult(
          quality: 32,
          dashVideoUrls: ['https://$tag.bilivideo.com/v.m4s?platform=android'],
          dashAudioUrls: ['https://$tag.bilivideo.com/a.m4s?platform=android'],
        );

    test('开关开着：离线下载先用 PlayView（不再打网页取流接口）', () async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final root = await Directory.systemTemp.createTemp('stream_compat_pv_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      var playViewCalls = 0;
      final mgr = DownloadManager(
        // 网页接口一被调就抛错：PlayView 成功时**一次都不该**打它
        fetchPlayUrl:
            ({required String bvid, required int cid}) async =>
                throw StateError('PlayView 成功时不该回落网页接口（测试构造）'),
        playViewFetcher: ({required String bvid, required int cid}) async {
          playViewCalls++;
          return appShapedStream('pv');
        },
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List<int>.filled(8, 3));
        },
        rootDir: root,
        betweenTasks: Duration.zero,
        retryDelay: Duration.zero,
      );
      await mgr.downloadVideo(_video(bvid: 'BV1STR_PV1'), 0);

      expect(playViewCalls, 1);
      expect(mgr.getCached('BV1STR_PV1', 0), isNotNull, reason: '下载成功');
    });

    test('开关开着但 PlayView 拿不到流 → 原样回落网页接口（不改用户设置）', () async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final root = await Directory.systemTemp.createTemp('stream_compat_pv2_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      var webCalls = 0;
      final mgr = DownloadManager(
        fetchPlayUrl:
            ({required String bvid, required int cid}) async {
          webCalls++;
          return PlayUrlResult(
            quality: 80,
            dashVideoUrls: ['https://web.bilivideo.com/v.m4s?platform=pc'],
            dashAudioUrls: const [],
          );
        },
        playViewFetcher: ({required String bvid, required int cid}) async =>
            throw StateError('PlayView 取流失败（测试构造）'),
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List<int>.filled(8, 3));
        },
        rootDir: root,
        betweenTasks: Duration.zero,
        retryDelay: Duration.zero,
      );
      await mgr.downloadVideo(_video(bvid: 'BV1STR_PV2'), 0);

      expect(webCalls, 1, reason: '回落后照旧用网页接口');
      expect(UiPrefsStore.instance.streamCompatEnabled, isTrue,
          reason: '回落不动用户设置');
      expect(mgr.getCached('BV1STR_PV2', 0), isNotNull);
    });

    test('番剧（epId 非空）不试 PlayView：只认 aid/cid 的链不该碰番剧', () async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final root = await Directory.systemTemp.createTemp('stream_compat_pv3_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      var playViewCalls = 0;
      var webCalls = 0;
      final mgr = DownloadManager(
        fetchPlayUrl:
            ({required String bvid, required int cid}) async {
          webCalls++;
          return PlayUrlResult(
            quality: 80,
            dashVideoUrls: ['https://web.bilivideo.com/v.m4s?platform=pc'],
            dashAudioUrls: const [],
          );
        },
        playViewFetcher: ({required String bvid, required int cid}) async {
          playViewCalls++;
          return appShapedStream('pv');
        },
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List<int>.filled(8, 3));
        },
        rootDir: root,
        betweenTasks: Duration.zero,
        retryDelay: Duration.zero,
      );
      await mgr.downloadVideo(
        const WhitelistVideo(
          bvid: 'BV1STR_EP1',
          cid: 1001,
          title: '番剧集',
          cover: '',
          duration: 600,
          upName: '测试UP主',
          addedAt: '2026-01-01',
          epId: 99999,
        ),
        0,
      );

      expect(playViewCalls, 0, reason: '番剧不走 PlayView（要另一套 pgc 服务）');
      expect(webCalls, 1);
    });

    test('语音转写临时音频：开关开着也走 PlayView（且只取音频轨）', () async {
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final root = await Directory.systemTemp.createTemp('stream_compat_pv4_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      var playViewCalls = 0;
      final source = SherpaAudioSource(
        downloadManager: DownloadManager(
          rootDir: root,
          betweenTasks: Duration.zero,
          retryDelay: Duration.zero,
        ),
        fetchPlayUrl:
            ({required String bvid, required int cid}) async =>
                throw StateError('PlayView 成功时不该回落网页接口（测试构造）'),
        playViewFetcher: ({required String bvid, required int cid}) async {
          playViewCalls++;
          return appShapedStream('pv');
        },
        downloadFile: (url, savePath, onProgress) async {
          await File(savePath).writeAsBytes(List<int>.filled(8, 3));
        },
        rootDir: root,
      );
      final path = await source.getAudioPath(_video(bvid: 'BV1STR_PV4'), 0);

      expect(playViewCalls, 1);
      expect(path, endsWith('.m4s'));
      expect(await File(path).length(), 8);
    });
  });

  // -------------------------------------------------------------------------
  group('⑥ 设置页：开关 + 小字', () {
    test('小字（设置页说明）：含「实验」与「自动切回普通模式」，非空白字符 ≤ 42', () {
      expect(kStreamCompatHint, contains('实验'));
      // v2.51.1 文案契约变更（不是放宽）：取不到流会自动回退，小字不再写
      // 「播放 403 请关掉」，改成如实说明「取不到流会自动切回普通模式」。
      expect(kStreamCompatHint, contains('自动切回普通模式'));
      final n = kStreamCompatHint.replaceAll(RegExp(r'\s'), '').length;
      expect(n, lessThanOrEqualTo(42),
          reason: '用户要求设置页小字压到两行（当前 $n 字）');
    });

    test('副标题（开启态）：必须说清可能只有 480P（缺 access_key）', () {
      // v2.52.0 契约：清晰度告诫放在**副标题**（小字已顶满 42 字上限，塞不进去）。
      // 这条是"不许静默降级"的界面侧一半：用户打开开关时就该看到代价。
      expect(kStreamCompatSubtitleOn,
          allOf(contains('480P'), contains('access_key')));
    });

    testWidgets('默认关 → 点一下打开并落盘；文案含「免流兼容（实验）」', (tester) async {
      await _pumpPanel(tester);

      expect(find.byKey(kStreamCompatSwitchKey), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byKey(kStreamCompatSwitchKey)).value,
        isFalse,
        reason: '默认关',
      );
      expect(find.text('免流兼容（实验）'), findsOneWidget);
      expect(find.text(kStreamCompatHint), findsOneWidget, reason: '小字在设置页里');

      // 面板很长，开关在折叠线以下 → 先滚到可见再点（同 ui_prefs_snack_test）
      final sw = find.byKey(kStreamCompatSwitchKey);
      await tester.ensureVisible(sw);
      await tester.pumpAndSettle();
      await tester.tap(sw);
      await tester.pumpAndSettle();

      expect(UiPrefsStore.instance.streamCompatEnabled, isTrue, reason: '点开立即生效');
      expect(
        tester.widget<SwitchListTile>(find.byKey(kStreamCompatSwitchKey)).value,
        isTrue,
        reason: '开关态跟着 store 走',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(UiPrefsStore.streamCompatKey), isTrue, reason: '落盘');
    });
  });

  // -------------------------------------------------------------------------
  group('⑦ 403 提示：开着开关时要能一眼知道是它干的', () {
    testWidgets('关闭：仍是原文「防盗链异常（403），请稍后重试」，不含开关指引',
        (tester) async {
      DownloadManager.debugOverride(_EmptyManager());
      addTearDown(DownloadManager.debugReset);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpPlayerReady(tester, _FakeApi());

      mocks.emitError(code: 3001, message: 'Invalid response code: 403');
      await _pumpMs(tester, 50);

      expect(find.textContaining('防盗链异常（403），请稍后重试'), findsOneWidget,
          reason: '关着开关时文案与改动前逐字一致');
      expect(find.textContaining('免流兼容（实验）'), findsNothing,
          reason: '没开就不能让用户去关一个没开的开关');
    });

    testWidgets('开启：提示里点名「免流兼容（实验）」并让用户去设置里关掉', (tester) async {
      DownloadManager.debugOverride(_EmptyManager());
      addTearDown(DownloadManager.debugReset);
      UiPrefsStore.instance.resetForTest(streamCompatEnabled: true);
      final mocks = _PlayerMocks()..install(tester);
      await _pumpPlayerReady(tester, _FakeApi());

      mocks.emitError(code: 3001, message: 'Invalid response code: 403');
      await _pumpMs(tester, 50);

      expect(find.textContaining('防盗链异常（403）'), findsOneWidget);
      expect(find.textContaining('可能是「免流兼容（实验）」开关导致的'), findsOneWidget,
          reason: '必须指出是这个开关干的');
      expect(find.textContaining('请到设置里关掉后再试'), findsOneWidget,
          reason: '并给出止损办法');
    });
  });
}
