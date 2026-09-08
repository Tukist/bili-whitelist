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

  /// path → 前 [failTimes] 次返回的响应（code=-352 模拟风控/限流）。
  final Map<String, int> failTimes;
  final Map<String, int> _failed = {};

  _Recorder(this.handlers, {Map<String, int>? failTimes})
    : failTimes = failTimes ?? {};

  int count(String path) => hits.where((p) => p == path).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hits.add(options.path);
    final path = options.path;
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
        jsonEncode({'code': -352, 'message': '风控校验失败', 'data': {}}),
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

_Recorder _defaultRecorder({Map<String, int>? failTimes}) => _Recorder({
  '/x/frontend/finger/spi': _spiBody,
  '/x/web-interface/nav': _navBody,
  '/x/space/wbi/acc/info': _accInfoBody,
  '/x/space/wbi/arc/search': _videosBody,
  '/x/relation/stat': _statBody,
  '/x/polymer/web-space/seasons_series_list': _emptyCollectionsBody,
}, failTimes: failTimes);

Future<void> _pumpPage(WidgetTester tester, _Recorder recorder) async {
  await tester.pumpWidget(
    MaterialApp(home: UpownerPage(mid: 546195, api: _fakeApi(recorder))),
  );
}

/// 快进：把重试退避（1s → 2s）的时间窗走完。
Future<void> _passRetryBackoff(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 2));
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
      MaterialApp(home: UpownerPage(mid: 546195, api: _fakeApi(rec2))),
    );
    await tester.pumpAndSettle();

    expect(rec2.count('/x/space/wbi/acc/info'), 0, reason: '不再请求 acc/info');
    expect(rec2.count('/x/relation/stat'), 0, reason: '不再请求 relation/stat');
    expect(find.text('测试UP主'), findsWidgets);
    expect(find.text('1.2万 粉丝'), findsOneWidget);
  });
}
