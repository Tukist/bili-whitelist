// UpownerPage 容错（v2.17.8）widget 测试（注入 mock BiliApi，不访问真实网络）：
// - 粉丝数接口（relation/stat）间歇失败 → 页面自动重试（退避 1s → 2s）后
//   显示粉丝数，不弹错误、不阻塞（用户手动重试被吸收）
// - 视频列表（arc/search）间歇失败 → 自动重试后显示列表，无整页错误
// - 视频列表一直失败 → 重试 3 次后仍失败才显示整页错误 + 「重试」按钮
// - UP 主信息会话级缓存：同 mid 二次进入不再请求 acc/info / relation/stat，
//   直接显示缓存（粉丝数 + 名字）
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';

final Map<String, String> _store = {};

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'read':
            return _store[args['key'] as String?];
          case 'write':
            final key = args['key'] as String?;
            if (key == null) return false;
            _store[key] = args['value'] as String? ?? '';
            return true;
          case 'delete':
            _store.remove(args['key'] as String?);
            return true;
          default:
            return null;
        }
      });
}

/// 记录每个请求 path 的调用次数 + 返回 handler 内容（可配置先失败 n 次）。
class _Recorder implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<String> hits = [];

  /// path → 前 [failTimes] 次返回的响应（默认 code=-352 模拟风控/限流；
  /// 想模拟 -412 就传 [failCode]）。
  final Map<String, int> failTimes;
  final int failCode;
  final Map<String, int> _failed = {};

  /// path → **按顺序消费**的一次性响应（队首优先，用完后回落 [handlers]）。
  /// 用来造「第 1 次失败、第 2 次成功」这种链路（-412 自愈）。
  final Map<String, List<Map<String, dynamic> Function()>> queue;

  /// 这些 path 直接抛 [DioException]（模拟超时/断连这类网络失败）。
  final Set<String> throwPaths;

  _Recorder(
    this.handlers, {
    Map<String, int>? failTimes,
    this.failCode = -352,
    Map<String, List<Map<String, dynamic> Function()>>? queue,
    Set<String>? throwPaths,
  }) : failTimes = failTimes ?? {},
       queue = queue ?? {},
       throwPaths = throwPaths ?? {};

  int count(String path) => hits.where((p) => p == path).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hits.add(options.path);
    final path = options.path;
    if (throwPaths.contains(path)) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }
    final pending = queue[path];
    if (pending != null && pending.isNotEmpty) {
      final next = pending.removeAt(0);
      return ResponseBody.fromString(
        jsonEncode(next()),
        200,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
      );
    }
    final handler = handlers[path];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: $path'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    final f = failTimes[path] ?? 0;
    if ((_failed[path] ?? 0) < f) {
      _failed[path] = (_failed[path] ?? 0) + 1;
      return ResponseBody.fromString(
        jsonEncode({'code': failCode, 'message': '风控校验失败', 'data': {}}),
        200,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(handler()),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _spiBody() => {
  'code': 0,
  'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
};

Map<String, dynamic> _navBody() => {
  'code': -101,
  'data': {
    'wbi_img': {
      'img_url':
          'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
      'sub_url':
          'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
    },
  },
};

/// acc/info 真实形态：不含 fans（2026-09 实测）。
Map<String, dynamic> _accInfoBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'name': '测试UP主',
    'face': '',
    'sign': '这是一个简介',
  },
};

Map<String, dynamic> _statBody({int follower = 12345}) => {
  'code': 0,
  'message': 'OK',
  'data': {'mid': 546195, 'follower': follower},
};

Map<String, dynamic> _videosBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'list': {
      'vlist': [
        {
          'bvid': 'BV1retry',
          'title': '主列表视频一号',
          'length': '4:45',
          'author': '测试UP主',
          'pic': '',
          'created': 1700000000,
        },
      ],
    },
    'page': {'pn': 1, 'ps': 20, 'count': 1},
  },
};

/// 只带业务码的响应体（`-412` 风控等；data 为空）。
Map<String, dynamic> _code(int code) => {
  'code': code,
  'message': code == -412 ? '风控校验失败' : '业务错误',
  'data': <String, dynamic>{},
};

Map<String, dynamic> _emptyCollectionsBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'items_lists': {
      'page': {'page_num': 1, 'page_size': 20, 'total': 0},
      'seasons_list': <Map<String, dynamic>>[],
      'series_list': <Map<String, dynamic>>[],
    },
  },
};

BiliApi _fakeApi(_Recorder recorder) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = recorder;
  return BiliApi(dio: dio);
}

_Recorder _defaultRecorder({
  Map<String, int>? failTimes,
  int failCode = -352,
  Map<String, List<Map<String, dynamic> Function()>>? queue,
  Set<String>? throwPaths,
}) => _Recorder(
  {
    '/x/frontend/finger/spi': _spiBody,
    '/x/web-interface/nav': _navBody,
    '/x/space/wbi/acc/info': _accInfoBody,
    '/x/space/wbi/arc/search': _videosBody,
    '/x/relation/stat': _statBody,
    '/x/polymer/web-space/seasons_series_list': _emptyCollectionsBody,
  },
  failTimes: failTimes,
  failCode: failCode,
  queue: queue,
  throwPaths: throwPaths,
);

Future<void> _pumpPage(WidgetTester tester, _Recorder recorder) async {
  await tester.pumpWidget(
    MaterialApp(home: UpownerPage(mid: 546195, api: _fakeApi(recorder))),
  );
}

/// 快进：把重试退避的时间窗走完。
///
/// v2.47.0 起重试节奏按失败类型分流（网络类 1s→2s / `-352` 1.5s→3s /
/// `-412` 等 2s 只再试一次），最长的一条链是 1.5s + 3s = 4.5s（API 层内部
/// 还可能先退避 700ms），这里给到 8s 富余——只影响「等够了没有」，
/// 不会让重试次数变多（次数由策略写死）。
Future<void> _passRetryBackoff(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    UpownerPage.clearInfoCacheForTest();
  });

  testWidgets('粉丝数接口间歇失败（-352 ×2）→ 自动重试后显示粉丝数，无错误',
      (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/relation/stat': 2},
    );
    await _pumpPage(tester, rec);
    // 前两次 -352 触发退避重试（spinner 阶段不落错误态）
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    // 共请求 3 次 stat（初次 + 2 次重试），最终显示粉丝数
    expect(rec.count('/x/relation/stat'), 3);
    expect(find.text('1.2万 粉丝'), findsOneWidget);
    expect(find.textContaining('失败'), findsNothing);
    expect(find.text('重试'), findsNothing); // 无整页错误
    expect(find.text('主列表视频一号'), findsOneWidget);
  });

  testWidgets('视频列表接口间歇失败（-352 ×2）→ 自动重试后列表出现，无整页错误',
      (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/space/wbi/arc/search': 2},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    expect(rec.count('/x/space/wbi/arc/search'), 3);
    expect(find.text('主列表视频一号'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('视频列表一直失败 → 重试 3 次后仍失败才显示整页错误 + 重试按钮',
      (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/space/wbi/arc/search': 99},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    expect(rec.count('/x/space/wbi/arc/search'), 3);
    expect(find.text('重试'), findsOneWidget); // 整页错误 + 手动重试兜底
    expect(find.textContaining('限流'), findsOneWidget);
  });

  testWidgets('信息会话级缓存：同 mid 二次进入不再请求 acc/info 与 stat，'
      '直接显示缓存', (tester) async {
    final rec = _defaultRecorder();
    await _pumpPage(tester, rec);
    await tester.pumpAndSettle();
    // 名字出现（AppBar 标题 + 头部卡片各一处）
    expect(find.text('测试UP主'), findsWidgets);
    expect(find.text('1.2万 粉丝'), findsOneWidget);
    expect(rec.count('/x/space/wbi/acc/info'), 1);
    expect(rec.count('/x/relation/stat'), 1);

    // 二次进入（同 mid、新页面实例/新 BiliApi）：信息直接命中缓存
    final rec2 = _defaultRecorder();
    await tester.pumpWidget(
      MaterialApp(
        home: UpownerPage(
          key: UniqueKey(), // 强制新 State：否则 Element 复用 → initState 不再跑
          mid: 546195,
          api: _fakeApi(rec2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rec2.count('/x/space/wbi/acc/info'), 0, reason: '不再请求 acc/info');
    expect(rec2.count('/x/relation/stat'), 0, reason: '不再请求 relation/stat');
    expect(find.text('测试UP主'), findsWidgets);
    expect(find.text('1.2万 粉丝'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // v2.47.0：用户报「进 UP 主页经常网络请求失败，重试几次才正常」
  //   A) 首屏这条链接入 -412 刷 key 重签自愈；B) spi/nav 在途去重；
  //   C) 重试按失败类型分流；D) 粉丝数失败不再是「一次就永久放弃」
  // -------------------------------------------------------------------------

  testWidgets('首次进 UP 主页：spi 与 nav 各只请求 1 次（在途去重，'
      '进页不再打请求风暴）', (tester) async {
    final rec = _defaultRecorder();
    await _pumpPage(tester, rec);
    await tester.pumpAndSettle();

    // 首屏 4 条链（信息/视频/合集/直播）同时起跑，以前 spi 打 2~3 次、nav 2 次
    expect(rec.count('/x/frontend/finger/spi'), 1);
    expect(rec.count('/x/web-interface/nav'), 1);
    // 去重不能把内容去没了：首屏照常
    expect(find.text('主列表视频一号'), findsOneWidget);
    expect(find.text('1.2万 粉丝'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('视频列表首次 -412 → 刷 WBI key 重签后自愈，列表照常出来'
      '（不落整页错误）', (tester) async {
    final rec = _defaultRecorder(
      queue: {
        '/x/space/wbi/arc/search': [() => _code(-412)],
      },
    );
    await _pumpPage(tester, rec);
    await tester.pumpAndSettle();

    expect(rec.count('/x/space/wbi/arc/search'), 2,
        reason: '首次 -412 → 重签重试一次');
    expect(rec.count('/x/web-interface/nav'), greaterThan(1),
        reason: '-412 触发了换 key（多一次 nav）');
    expect(find.text('主列表视频一号'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.text('网络请求失败，请检查网络后重试'), findsNothing);
  });

  testWidgets('风控类 -352：等待比网络类长（1s 时还没重试），仍最多 3 次尝试',
      (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/space/wbi/arc/search': 99},
    );
    await _pumpPage(tester, rec);
    // 旧的 1s → 2s 节奏在这里就会发出第 2 次请求；新策略（-352 等 1.5s）
    // 到 1s 时还没动
    await tester.pump(const Duration(seconds: 1));
    expect(rec.count('/x/space/wbi/arc/search'), 1,
        reason: '-352 第一次重试要等 1.5s（比网络类的 1s 长）');

    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();
    expect(rec.count('/x/space/wbi/arc/search'), 3,
        reason: '次数与旧行为一致：不靠加请求量解决，靠等够时间');
    expect(find.textContaining('限流'), findsOneWidget);
  });

  testWidgets('网络类失败（DioException）→ 既有退避不变（1s→2s/3 次），'
      '整页文案是「网络请求失败，请检查网络后重试」', (tester) async {
    final rec = _defaultRecorder(
      throwPaths: {'/x/space/wbi/arc/search'},
    );
    await _pumpPage(tester, rec);
    await tester.pump(const Duration(seconds: 1));
    expect(rec.count('/x/space/wbi/arc/search'), 2,
        reason: '网络类仍按 1s 退避（第 1 次重试）');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(rec.count('/x/space/wbi/arc/search'), 3,
        reason: '网络类仍 3 次尝试（行为未改）');
    expect(find.text('网络请求失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget); // 手动重试兜底还在
  });

  testWidgets('风控类 -412 持续失败：只再试 1 次（不靠堆请求量），'
      '文案是风控而非「检查网络」', (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/space/wbi/arc/search': 99},
      failCode: -412,
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    // 2 次页面尝试 × (首打 + 换 key 重签) = 4；旧行为是 3 次页面尝试
    expect(rec.count('/x/space/wbi/arc/search'), 4,
        reason: '-412 页面层只再试 1 次（API 层已刷 key 重签过一轮）');
    expect(rec.count('/x/web-interface/nav'), greaterThan(1),
        reason: '确实走了换 key 重签');
    expect(find.textContaining('风控'), findsOneWidget);
    expect(find.text('网络请求失败，请检查网络后重试'), findsNothing,
        reason: '业务风控不是网络故障，别误导用户去检查网络');
  });

  testWidgets('粉丝数（relation/stat）一直失败 → 页面照常（列表可见、无整页'
      '错误），粉丝数位置显示 —', (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/relation/stat': 99},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    expect(rec.count('/x/relation/stat'), greaterThanOrEqualTo(3),
        reason: '粉丝数失败是真重试，不是一次就放弃');
    expect(find.text('— 粉丝'), findsOneWidget);
    expect(find.text('主列表视频一号'), findsOneWidget);
    expect(find.text('重试'), findsNothing,
        reason: '粉丝数是次要字段，不该拖垮整页');
  });

  testWidgets('acc/info 失败但 stat 成功 → 粉丝数照常显示，信息卡只有一行'
      '「简介加载失败」', (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/space/wbi/acc/info': 99},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    expect(find.text('1.2万 粉丝'), findsOneWidget,
        reason: '资料拿不到不影响粉丝数（两条链互相独立）');
    expect(find.textContaining('简介加载失败'), findsOneWidget);
    expect(find.text('主列表视频一号'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: '资料失败只降级，不弹整页错误');
  });

  testWidgets('acc/info 成功但 stat 失败 → 缓存记住「粉丝数还没拿到」，'
      '下次进页自动补拉并显示出来', (tester) async {
    // 第 1 次进页：资料成功、粉丝数一直被风控
    final rec = _defaultRecorder(
      failTimes: {'/x/relation/stat': 99},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();
    expect(find.text('— 粉丝'), findsOneWidget);
    expect(find.text('测试UP主'), findsWidgets); // 资料进了缓存

    // 第 2 次进页（风控已恢复）：资料不再请求（缓存命中），但粉丝数会补拉
    final rec2 = _defaultRecorder();
    await tester.pumpWidget(
      MaterialApp(
        home: UpownerPage(
          key: UniqueKey(), // 强制新 State：否则 Element 复用 → initState 不再跑
          mid: 546195,
          api: _fakeApi(rec2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rec2.count('/x/space/wbi/acc/info'), 0, reason: '资料命中缓存');
    expect(rec2.count('/x/relation/stat'), 1,
        reason: '缓存里 fans=null 视为「还没拿到」→ 每次进页都补拉一次');
    expect(find.text('1.2万 粉丝'), findsOneWidget,
        reason: '不能一直显示 —（用户投诉 #2）');
    expect(find.text('— 粉丝'), findsNothing);
  });

  testWidgets('缓存补拉粉丝数也走退避重试（前两次失败 → 第 3 次成功显示）',
      (tester) async {
    // 第 1 次进页：粉丝数一直失败 → 缓存里 fans=null
    final rec = _defaultRecorder(
      failTimes: {'/x/relation/stat': 99},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();
    expect(find.text('— 粉丝'), findsOneWidget);

    // 第 2 次进页：补拉前两次仍失败（-352 ×2）、第 3 次才成功
    // —— 旧实现是「单次、不重试、失败静默」，这里就该永远显示 —
    final rec2 = _defaultRecorder(
      failTimes: {'/x/relation/stat': 2},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: UpownerPage(
          key: UniqueKey(), // 强制新 State：否则 Element 复用 → initState 不再跑
          mid: 546195,
          api: _fakeApi(rec2),
        ),
      ),
    );
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    expect(rec2.count('/x/relation/stat'), 3,
        reason: '补拉也按风控节奏重试（1 + 2 次重试）');
    expect(find.text('1.2万 粉丝'), findsOneWidget);
  });

  testWidgets('粉丝数补拉后仍失败 → 缓存不被写成「已缓存」，再进页还会再试',
      (tester) async {
    final rec = _defaultRecorder(
      failTimes: {'/x/relation/stat': 99},
    );
    await _pumpPage(tester, rec);
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();

    // 二次进页：粉丝数依然失败 → 依然是 —，但下次还会尝试
    final rec2 = _defaultRecorder(
      failTimes: {'/x/relation/stat': 99},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: UpownerPage(
          key: UniqueKey(), // 强制新 State：否则 Element 复用 → initState 不再跑
          mid: 546195,
          api: _fakeApi(rec2),
        ),
      ),
    );
    await _passRetryBackoff(tester);
    await tester.pumpAndSettle();
    expect(find.text('— 粉丝'), findsOneWidget);
    expect(rec2.count('/x/relation/stat'), greaterThanOrEqualTo(3));

    // 三次进页（风控恢复）→ 粉丝数终于显示
    final rec3 = _defaultRecorder();
    await tester.pumpWidget(
      MaterialApp(
        home: UpownerPage(
          key: UniqueKey(),
          mid: 546195,
          api: _fakeApi(rec3),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rec3.count('/x/relation/stat'), 1);
    expect(find.text('1.2万 粉丝'), findsOneWidget);
  });
}
