// 「粘贴 Cookie 登录」单测（v2.49.1+）。
//
// 为什么需要这条路：真机上登录页的 WebView 渲染进程每次必崩（系统日志
// `Renderer process crash detected (code -1)`），WebView 那条路直接不可用，
// 而崩不崩取决于用户手机/网络里的代理（中间人证书），App 侧修不了。
// 于是必须留一条"不管 WebView 好坏都能登进去"的物质入口：在电脑浏览器里
// 登录 B 站，把整段 cookie 复制过来粘贴。
//
// 这组用例锁住的关键性质：
// 1. 粘贴的串**必须经服务端校验**（同一个 nav 接口）才落盘——校验不通过就
//    绝不保存（保存一份服务端不认的凭据，正是"处处 -101 但 App 说自己已登录"
//    那种坏状态的来源）；
// 2. 校验失败/网络失败时弹层不关、给明确原因，用户能改一改再试；
// 3. 解析容错（顺序/大小写/换行/多余键/只有部分键），且**不做 url 解码**。
//
// ⚠️ 夹具全部是明显假的字符串（FAKE_*），不含任何真实凭据。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

Map<String, String> _store = {};

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

/// 固定响应的 dio adapter（不访问真实网络）。
class _NavAdapter implements HttpClientAdapter {
  final Map<String, Object?> body;
  final bool network;
  final List<RequestOptions> requests = [];

  _NavAdapter(this.body) : network = false;

  _NavAdapter.network()
      : body = const {},
        network = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (network) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Future<void> _pumpPanel(WidgetTester tester, BiliApi api) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ManagePanel(
          github: GithubApi(),
          bili: api,
          onManageCollections: () {},
          onCheckUpdate: () {},
          onLogin: () {},
          headingTitle: '设置',
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 打开粘贴弹层并输入 [cookie]。
Future<void> _openAndType(WidgetTester tester, String cookie) async {
  await tester.tap(find.byKey(kPasteCookieButtonKey));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, cookie);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store = {};
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('入口在「B 站账号」区（与「登录 / 重新登录」并列）', (tester) async {
    await _pumpPanel(tester, _api(_NavAdapter({'code': 0})));

    expect(find.text('B 站账号'), findsOneWidget);
    expect(find.byKey(kPasteCookieButtonKey), findsOneWidget);
    expect(find.textContaining('粘贴 Cookie 登录'), findsOneWidget);
  });

  testWidgets('校验通过 → 落盘 + 提示成功 + 关闭弹层（含 bili_jct / 刷新口令）',
      (tester) async {
    final adapter = _NavAdapter({
      'code': 0,
      'message': '0',
      'data': {'isLogin': true, 'mid': 12345},
    });
    await _pumpPanel(tester, _api(adapter));
    await _openAndType(
      tester,
      'SESSDATA=FAKE_SESSDATA; bili_jct=FAKE_JCT; '
      'DedeUserID=123456; bili_refresh_token=FAKE_REFRESH',
    );

    await tester.tap(find.text('校验并登录'));
    await tester.pumpAndSettle();

    // 校验请求确实打了服务端（nav），且带上了粘贴的那份 cookie
    expect(adapter.requests.single.path, '/x/web-interface/nav');
    expect(adapter.requests.single.headers['Cookie'],
        contains('SESSDATA=FAKE_SESSDATA'));
    // 三个凭据全部落盘
    expect(_store['bili_sessdata'], 'FAKE_SESSDATA');
    expect(_store['bili_jct'], 'FAKE_JCT');
    expect(_store['bili_refresh_token'], 'FAKE_REFRESH');
    // 弹层关闭 + 成功提示
    expect(find.text('校验并登录'), findsNothing);
    expect(find.textContaining('登录成功'), findsOneWidget);
  });

  testWidgets('服务端 -101 → 不落盘、弹层不关、说明已失效', (tester) async {
    final adapter = _NavAdapter({'code': -101, 'message': '账号未登录'});
    await _pumpPanel(tester, _api(adapter));
    await _openAndType(tester, 'SESSDATA=FAKE_DEAD_SESSDATA');

    await tester.tap(find.text('校验并登录'));
    await tester.pumpAndSettle();

    expect(_store.containsKey('bili_sessdata'), isFalse); // 绝不落盘
    expect(find.textContaining('服务端不认'), findsOneWidget);
    expect(find.textContaining('没有保存'), findsOneWidget);
    expect(find.text('校验并登录'), findsOneWidget); // 弹层还在，可重试
  });

  testWidgets('网络失败 → 不落盘、提示检查网络', (tester) async {
    await _pumpPanel(tester, _api(_NavAdapter.network()));
    await _openAndType(tester, 'SESSDATA=FAKE_SESSDATA');

    await tester.tap(find.text('校验并登录'));
    await tester.pumpAndSettle();

    expect(_store.containsKey('bili_sessdata'), isFalse);
    expect(find.textContaining('请检查网络'), findsOneWidget);
    expect(find.text('校验并登录'), findsOneWidget);
  });

  testWidgets('风控码 -412 → 不落盘、如实说被拦', (tester) async {
    final adapter = _NavAdapter({'code': -412, 'message': '请求被拦截'});
    await _pumpPanel(tester, _api(adapter));
    await _openAndType(tester, 'SESSDATA=FAKE_SESSDATA');

    await tester.tap(find.text('校验并登录'));
    await tester.pumpAndSettle();

    expect(_store.containsKey('bili_sessdata'), isFalse);
    expect(find.textContaining('-412'), findsOneWidget);
  });

  testWidgets('没粘到 SESSDATA → 提示怎么改，且一次请求都不发', (tester) async {
    final adapter = _NavAdapter({'code': 0, 'data': {'isLogin': true}});
    await _pumpPanel(tester, _api(adapter));
    await _openAndType(tester, 'bili_jct=FAKE_JCT');

    await tester.tap(find.text('校验并登录'));
    await tester.pumpAndSettle();

    expect(adapter.requests, isEmpty);
    expect(_store, isEmpty);
    expect(find.textContaining('没找到 SESSDATA'), findsOneWidget);
  });

  testWidgets('乱序 / 换行 / 多余键 / 只有 SESSDATA 的串都能认（解析容错）',
      (tester) async {
    final adapter = _NavAdapter({
      'code': 0,
      'message': '0',
      'data': {'isLogin': true, 'mid': 1},
    });
    await _pumpPanel(tester, _api(adapter));
    await _openAndType(
      tester,
      'DedeUserID=1;\n  BILI_JCT=FAKE_JCT ;\r\n buvid3=xyz;\n'
      '  sessdata = FAKE_2C%2C9999%2Cabc ;',
    );

    await tester.tap(find.text('校验并登录'));
    await tester.pumpAndSettle();

    // 值原样保留（%2C 不解码——回填 Cookie 头必须用原值）
    expect(_store['bili_sessdata'], 'FAKE_2C%2C9999%2Cabc');
    expect(_store['bili_jct'], 'FAKE_JCT');
    expect(_store['bili_refresh_token'], ''); // 没给刷新口令 → 空串（不阻塞登录）
    expect(find.textContaining('登录成功'), findsOneWidget);
  });
}
