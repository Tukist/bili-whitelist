// 冷启动「读剪贴板 → 直接播」的**接线**测试（v2.35.0）：
// - 首帧 + 900ms 后才读（提前推进时间不读）
// - 命中视频链接 → 调开播动作一次，参数（视频 / ?p / ?t）正确
// - 同一条链接第二次启动（prefs 里已有记录）→ 不跳、也不取元数据
// - 设置里关掉 → 连剪贴板都不读
// - 短链解析失败 → 只提示不跳（openClipboardVideo 不被调用）
// - 首页不在栈顶（上面压着别的页）→ 当时不打扰，退回首页后仍会处理
// - 取元数据期间首页被压住 → 结果先存着，退回首页后仍会跳（不静默丢弃）
// - 首页一直被压着、等满预算 → 彻底放弃（剪贴板一个字节都没读）
// - b23.tv 短链分享文本 → 解析成真实 BV 后直接开播
//
// 用真 [ClipboardLinkProbe]（但注入假剪贴板内容 + 假 BiliApi）+ 注入的开播
// 替身，避免碰系统剪贴板、网络与原生播放器通道。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/clipboard_link_probe.dart';
import 'package:bili_whitelist_app/services/clipboard_link_store.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/utils/clipboard_link.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

const _bv = 'BV1yE8r6KErQ';

/// 分享文本（带 ?p=2&t=129 定位参数，用来验证参数被传到开播动作）。
const _shareText =
    '【【Noita全天赋介绍39】魔杖实验者】 '
    'https://www.bilibili.com/video/$_bv/?p=2&t=129&share_source=copy_web';

WhitelistData _oneVideo() => WhitelistData(
      version: 4,
      updatedAt: '2026-08-20T00:00:00Z',
      videos: [
        WhitelistVideo(
          bvid: 'BV1aaaaaaa',
          cid: 1,
          title: '白名单视频',
          cover: '',
          duration: 60,
          upName: 'UP主',
          addedAt: '2026-08-01T00:00:00Z',
          collection: '动画',
        ),
      ],
      collections: [
        CollectionInfo(name: '动画', createdAt: '2026-08-01T00:00:00Z'),
      ],
      upowners: const <Upowner>[],
    );

class _FakeSyncService extends WhitelistSyncService {
  final WhitelistData data;

  _FakeSyncService(this.data) : super(dio: Dio());

  @override
  Future<SyncResult> sync() async => SyncResult(
        data: data,
        sourceName: 'fake',
        fetchedAt: DateTime(2026, 1, 1),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

class _FakeBiliApi extends BiliApi {
  _FakeBiliApi({this.gate});

  int calls = 0;

  /// 非 null 时 `fetchVideoMeta` 先等它 —— 用来把"取元数据"钉在在飞状态，
  /// 以便在取元数据期间把首页压到下层（模拟启动期登录引导页盖上来）。
  final Completer<void>? gate;

  @override
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    return {
      'bvid': bvid,
      'cid': 999,
      'title': '剪贴板里的视频',
      'pic': '',
      'duration': 300,
      'owner': {'mid': 7, 'name': 'UP主'},
      'pages': [
        {'cid': 999, 'part': 'P1', 'duration': 300},
      ],
    };
  }
}

/// 记录"跳了什么"的开播替身（不构造真实播放页）。
class _OpenRecorder {
  final List<ClipboardOpenResult> calls = [];

  Future<void> open(BuildContext context, ClipboardOpenResult result) async {
    calls.add(result);
  }
}

/// mock secure storage（GitHub 配置 + 合成"已登录"的 SESSDATA，避免启动时
/// 自动进登录页把首页顶掉——LoginPage 的 WebView 在测试环境无法构建）。
void _mockSecureStorage() {
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  final store = <String, String>{
    'bili_sessdata': '12345,$expireSec,${'a' * 32}',
  };
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return store[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        store[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        store.remove(args['key'] as String?);
        return true;
      case 'readAll':
        return Map<String, String>.from(store);
      default:
        return null;
    }
  });
}

/// 挂首页（注入假剪贴板来源与开播替身）。
Future<void> _pumpHome(
  WidgetTester tester, {
  required String? clipboard,
  required _OpenRecorder recorder,
  _FakeBiliApi? api,
  Dio? dio,
  List<int>? reads,
}) async {
  _mockSecureStorage();
  ServiceLocator.overrideSyncService(_FakeSyncService(_oneVideo()));
  final probe = ClipboardLinkProbe(
    api: api ?? _FakeBiliApi(),
    dio: dio,
    readClipboard: () async {
      reads?.add(1);
      return clipboard;
    },
  );
  await tester.pumpWidget(MaterialApp(
    home: PlaylistPage(
      github: GithubApi(dio: Dio()),
      clipboardProbe: probe,
      openClipboardVideo: recorder.open,
    ),
  ));
  await tester.pump(); // 首帧
  await tester.pump(); // _load 完成（假服务同步返回）
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClipboardLinkStore.instance.resetForTest();
  });

  testWidgets('冷启动：首帧 + 900ms 后才读剪贴板，命中就调开播（带 ?p / ?t）',
      (tester) async {
    final recorder = _OpenRecorder();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: _shareText,
      recorder: recorder,
      reads: reads,
    );

    // 还没到时间：一帧都不该读剪贴板
    await tester.pump(const Duration(milliseconds: 800));
    expect(reads, isEmpty, reason: '首帧之后要等一会儿才读（别打断首页加载）');
    expect(recorder.calls, isEmpty);

    // 越过 900ms：读一次 → 命中 → 跳
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    expect(reads.length, 1);
    expect(recorder.calls.length, 1);

    final result = recorder.calls.single;
    expect(result.status, ClipboardOpenStatus.opened);
    expect(result.video!.bvid, _bv);
    expect(result.video!.title, '剪贴板里的视频');
    expect(result.pageIndex, 1, reason: '?p=2 → 0 起下标 1');
    expect(result.positionMs, 129000, reason: '?t=129 → 129 秒');

    // 再推进 5 秒：一个进程只读一次，不重复跳
    await tester.pump(const Duration(seconds: 5));
    expect(reads.length, 1);
    expect(recorder.calls.length, 1);
  });

  testWidgets('同一条链接第二次启动：不再跳（去重记录跨启动持久化）', (tester) async {
    // 模拟"上次启动已经处理过这条链接"：prefs 里躺着的正是它的原文
    final raw = parseClipboardLink(_shareText)!.raw;
    SharedPreferences.setMockInitialValues({
      ClipboardLinkStore.lastKeyStorageKey: raw,
    });
    ClipboardLinkStore.instance.resetForTest(); // loaded=false → 会重新读盘

    final recorder = _OpenRecorder();
    final api = _FakeBiliApi();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: _shareText,
      recorder: recorder,
      api: api,
      reads: reads,
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    await tester.pump();

    expect(reads.length, 1, reason: '剪贴板读了（才知道是不是同一条）');
    expect(api.calls, 0, reason: '去重命中在取元数据之前');
    expect(recorder.calls, isEmpty, reason: '同一条链接只跳一次');
  });

  testWidgets('设置里关掉开关：连剪贴板都不读（更彻底的不打扰）', (tester) async {
    SharedPreferences.setMockInitialValues({
      ClipboardLinkStore.enabledKey: false,
    });
    ClipboardLinkStore.instance.resetForTest();

    final recorder = _OpenRecorder();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: _shareText,
      recorder: recorder,
      reads: reads,
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(reads, isEmpty);
    expect(recorder.calls, isEmpty);
    expect(ClipboardLinkStore.instance.enabled, isFalse);
  });

  testWidgets('短链解析失败：只提示「短链解析失败」，不跳', (tester) async {
    final recorder = _OpenRecorder();
    // 会抛连接错误的 dio → 短链解析失败
    final badDio = Dio()
      ..httpClientAdapter = _FailingAdapter();
    await _pumpHome(
      tester,
      clipboard: '【【边狱巴士】第八赛季将至！...-哔哩哔哩】 https://b23.tv/spVKBAi',
      recorder: recorder,
      dio: badDio,
    );
    await tester.pump(const Duration(milliseconds: 1000));
    // 短链解析失败要等两次 800ms 重试间隔（resolveShortLink 每次失败都等一下）
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump();
    await tester.pump();

    expect(recorder.calls, isEmpty);
    expect(find.text('短链解析失败'), findsOneWidget);
  });

  testWidgets('首页不在栈顶（上面压着别的页）→ 当时不打扰，退回首页后仍会处理',
      (tester) async {
    final recorder = _OpenRecorder();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: _shareText,
      recorder: recorder,
      reads: reads,
    );

    // 用户手快，首帧就点进了合集页（首页被压在下面）
    await tester.tap(find.text('动画'));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 1000));
    expect(reads, isEmpty, reason: '首页不在栈顶时连读都不读，不抢导航');
    expect(recorder.calls, isEmpty);

    // 退回首页 → 下一轮重试发现首页空闲 → 正常读剪贴板并开播
    // （"等首页就绪后再处理"，而不是"被挡一次就永远不做了"）
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump(kClipboardOpenDelay);
    await tester.pump();
    await tester.pump();

    expect(reads.length, 1, reason: '剪贴板只在真正要处理时读，且只读一次');
    expect(recorder.calls.length, 1);
    expect(recorder.calls.single.video!.bvid, _bv);
  });

  testWidgets('取元数据期间首页被压住 → 结果先存着，退回首页后仍会跳（不静默丢弃）',
      (tester) async {
    final gate = Completer<void>();
    final api = _FakeBiliApi(gate: gate);
    final recorder = _OpenRecorder();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: _shareText,
      recorder: recorder,
      api: api,
      reads: reads,
    );

    // 到点读剪贴板 → 命中 → 开始取元数据（被闸门钉住）
    await tester.pump(const Duration(milliseconds: 1000));
    expect(reads.length, 1);
    expect(api.calls, 1);

    // 取元数据还没回来，用户先点进了合集页（真机上是自动登录引导页盖上来）
    await tester.tap(find.text('动画'));
    await tester.pumpAndSettle();
    expect(recorder.calls, isEmpty, reason: '首页不在栈顶时不插队');

    // 元数据回来了，但首页仍被压着 → 不该硬跳（也不该把这一条悄悄扔掉）
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(recorder.calls, isEmpty);

    // 首页重新空闲 → 下一轮把**已经取到的那一个**跳出来
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump(kClipboardOpenDelay);
    await tester.pump();

    expect(reads.length, 1, reason: '等待期间不重读剪贴板');
    expect(api.calls, 1, reason: '等待期间不重取元数据');
    expect(recorder.calls.length, 1);
    expect(recorder.calls.single.video!.bvid, _bv);
  });

  testWidgets('首页一直被压着、等满预算 → 彻底放弃（剪贴板一个字节都没读）',
      (tester) async {
    final recorder = _OpenRecorder();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: _shareText,
      recorder: recorder,
      reads: reads,
    );

    // 一直待在合集页：把「等首页就绪」的预算耗光
    await tester.tap(find.text('动画'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.pump(kClipboardOpenDelay);
    }

    // 再回到首页也不该补跳（预算用完了就是放弃，不做"迟到的惊喜"）
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));

    expect(reads, isEmpty);
    expect(recorder.calls, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('冷启动：剪贴板是 b23.tv 短链分享文本 → 解析成真实 BV 后直接开播',
      (tester) async {
    final recorder = _OpenRecorder();
    final reads = <int>[];
    await _pumpHome(
      tester,
      clipboard: '【【边狱巴士】第八赛季将至！...-哔哩哔哩】 https://b23.tv/spVKBAi',
      recorder: recorder,
      reads: reads,
      dio: Dio()
        ..httpClientAdapter = _RedirectAdapter(
          Uri.parse('https://www.bilibili.com/video/$_bv/?p=2&t=60'),
        ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    await tester.pump();

    expect(reads.length, 1);
    expect(recorder.calls.length, 1);
    final result = recorder.calls.single;
    expect(result.status, ClipboardOpenStatus.opened);
    expect(result.video!.bvid, _bv, reason: '短链已解析成真实 BV');
    expect(result.pageIndex, 1, reason: '落点 URL 的 ?p=2 → 0 起下标 1');
    expect(result.positionMs, 60000, reason: '落点 URL 的 ?t=60 → 60 秒');
    // 去重键仍是剪贴板里的**原文**（短链），不是落点 URL：用户没重新复制过
    // 内容 → 下次启动还是同一条 → 仍然只跳一次
    expect(result.link, 'https://b23.tv/spVKBAi');
  });

  testWidgets('剪贴板里没有视频链接 → 什么都不做（不提示、不打扰）', (tester) async {
    final recorder = _OpenRecorder();
    await _pumpHome(
      tester,
      clipboard: '今晚吃火锅，记得买豆腐',
      recorder: recorder,
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(recorder.calls, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('设置面板：开关默认开，点一下关掉并落盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ClipboardLinkStore.instance.resetForTest();
    await ClipboardLinkStore.instance.ensureLoaded();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ManagePanel(
            github: GithubApi(dio: Dio()),
            onManageCollections: () {},
            onCheckUpdate: () {},
            onLogin: () {},
          ),
        ),
      ),
    ));
    await tester.pump();

    final switchFinder = find.byKey(kClipboardOpenSwitchKey);
    expect(switchFinder, findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(switchFinder).value,
      isTrue,
      reason: '默认开（用户明确要这个功能）',
    );
    expect(find.text('启动行为'), findsOneWidget);

    await tester.ensureVisible(switchFinder);
    await tester.pump();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(ClipboardLinkStore.instance.enabled, isFalse);
    // 断言收窄到**该开关自己的子树**（v2.40.0）：原来是
    // `find.textContaining('已关闭')`，匹配范围是整个设置面板；v2.40.0 新增的
    // 「允许点赞/投币/收藏」开关关闭时的副标题同样以「已关闭：」开头（面板里
    // SwitchListTile 副标题的既有写法），于是这条 finder 变成 2 个命中。
    // 收窄后断言的**主张不变**（剪贴板开关关掉后，它自己的副标题说「已关闭」），
    // 只是不再受"面板里别的开关也这么写"影响。
    expect(
      find.descendant(of: switchFinder, matching: find.textContaining('已关闭')),
      findsOneWidget,
    );

    // 落盘：重启后仍然是关的
    ClipboardLinkStore.instance.resetForTest();
    await ClipboardLinkStore.instance.ensureLoaded();
    expect(ClipboardLinkStore.instance.enabled, isFalse);
  });
}

/// 模拟 b23.tv 短链重定向：响应带一条 [RedirectRecord]，真实落点就是它
/// （与 `utils/import_parser.dart` 的 resolveShortLink 读取方式一致）。
class _RedirectAdapter implements HttpClientAdapter {
  final Uri location;

  _RedirectAdapter(this.location);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = ResponseBody.fromString('<html>go</html>', 200, headers: {
      'content-type': ['text/html; charset=utf-8'],
    });
    body.redirects = [RedirectRecord(302, 'GET', location)];
    return body;
  }

  @override
  void close({bool force = false}) {}
}

/// 一律连接失败的 adapter（短链解析失败路径）。
class _FailingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}
