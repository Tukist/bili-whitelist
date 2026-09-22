// 「登录必须经服务端校验才算成功」+「粘贴 Cookie 登录」单测（v2.49.1+）。
//
// 背景（2026-09-22 真机取证）：WebView cookie jar 里那份**服务端早已作废**的
// 死 cookie，在本地看来和有效会话一模一样。老代码「读到 SESSDATA 就宣布登录
// 成功」于是走成一条死循环：弹「登录成功」→ 落盘 → pop → 收藏夹重载 →
// 服务端 -101 → 「登录已失效」→ 点「去登录」→ 又读到同一份死 cookie → 又弹
// 「登录成功」……真机截图里「登录已失效」与「登录成功」同屏并存，就是这么来的。
//
// 这组用例锁住三件事：
// 1. 服务端**没有**点头（-101 / 网络失败 / 风控码）→ 不报成功、不落盘、不 pop；
// 2. 服务端点头 → 落盘 + 提示 + pop；
// 3. 判定死亡时，WebView 里那份死 cookie 也要被清掉（否则登录页还会读到它）。
//
// 测试环境里 WebView 平台未注册（`WebViewController()` 构造即抛），所以
// 「页面卡住不返回」的看门狗路径用 [LoginPage.createWebView] 注入替身来覆盖。
//
// ⚠️ 夹具全部是明显假的字符串（FAKE_*），不含任何真实凭据。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/login_page.dart';
import 'package:bili_whitelist_app/services/web_login_cookies.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';

// ---------------------------------------------------------------------------
// 平台替身：内存版 secure storage + cookie 通道桩
// ---------------------------------------------------------------------------

Map<String, String> _store = {};

/// cookie 通道被调用的方法名（按顺序；断言"清死会话时确实清了 WebView cookie"）。
List<String> _cookieCalls = [];

/// `getCookies` 返回的 cookie 串（空串 = jar 里没有 cookie）。
String _cookieValue = '';

/// 让 cookie 通道整体不可用（模拟原生组件缺失）。
bool _cookieChannelFails = false;

void _mockPlatform() {
  _store = {};
  _cookieCalls = [];
  _cookieValue = '';
  _cookieChannelFails = false;

  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storage, (call) async {
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

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(WebLoginCookies.channel, (call) async {
    _cookieCalls.add(call.method);
    if (_cookieChannelFails) {
      throw PlatformException(code: 'unavailable', message: 'no webview');
    }
    switch (call.method) {
      case 'getCookies':
        return _cookieValue;
      default:
        return null;
    }
  });
}

/// 固定响应的 dio adapter（不访问真实网络）。
///
/// [body] 可改（`adapter.body = …`）：测「先 -101 判否、随后用户在页面里重新登录
/// 拿到新 cookie、服务端这次点头」这种两段式场景需要它。
class _NavAdapter implements HttpClientAdapter {
  Map<String, Object?> body;
  final bool network;

  /// 全部请求（断言"该不该打服务端"用）。
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

/// `nav` 的成功响应（服务端确认已登录）。
Map<String, Object?> _navOk() => {
      'code': 0,
      'message': '0',
      'data': {'isLogin': true, 'mid': 12345},
    };

/// `nav` 的未登录响应（会话已被服务端作废）。
Map<String, Object?> _navNotLogin() => {
      'code': -101,
      'message': '账号未登录',
      'data': {'isLogin': false},
    };

/// 被 pop 出来的返回值（闭包外可见）。
class _PushOutcome {
  bool? value;
  bool get popped => value != null;
}

/// 把 LoginPage 推成第二个路由（pop 才有意义），并返回结果捕获器。
Future<_PushOutcome> _pushLogin(
  WidgetTester tester, {
  required BiliApi api,
  Future<void> Function()? createWebView,
}) async {
  final outcome = _PushOutcome();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              outcome.value = await Navigator.of(ctx).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (_) => LoginPage(api: api, createWebView: createWebView),
                ),
              );
            },
            child: const Text('去登录'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('去登录'));
  await tester.pump(); // 起导航
  await tester.pump(const Duration(milliseconds: 400)); // 路由动画
  return outcome;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockPlatform);

  // -------------------------------------------------------------------------
  // 1. cookie 串解析（登录页读到的 / 用户粘贴的，同一套解析）
  // -------------------------------------------------------------------------
  group('parseBiliCookieCreds（容错解析）', () {
    test('完整串：SESSDATA / bili_jct / bili_refresh_token 全取到', () {
      final c = parseBiliCookieCreds(
          'SESSDATA=FAKE_SESSDATA; bili_jct=FAKE_JCT; '
          'DedeUserID=123456; bili_refresh_token=FAKE_REFRESH');
      expect(c.sessdata, 'FAKE_SESSDATA');
      expect(c.biliJct, 'FAKE_JCT');
      expect(c.refreshToken, 'FAKE_REFRESH');
      expect(c.hasSessdata, isTrue);
    });

    test('顺序打乱 + 多余键 + 键名大小写混用，照样能认', () {
      final c = parseBiliCookieCreds(
          'DedeUserID=1; BILI_JCT=FAKE_JCT; buvid3=xyz; sessdata=FAKE_SESSDATA');
      expect(c.sessdata, 'FAKE_SESSDATA');
      expect(c.biliJct, 'FAKE_JCT');
    });

    test('带换行 / 尾部多余分号 / 键值周围空白', () {
      final c = parseBiliCookieCreds(
          '  SESSDATA = FAKE_SESSDATA ;\n bili_jct=FAKE_JCT ;\r\n');
      expect(c.sessdata, 'FAKE_SESSDATA');
      expect(c.biliJct, 'FAKE_JCT');
    });

    test('SESSDATA 里的 %2C 原样保留（不解码——回填 Cookie 头要用原值）', () {
      final c = parseBiliCookieCreds('SESSDATA=1%2C99%2Cfake');
      expect(c.sessdata, '1%2C99%2Cfake');
    });

    test('ac_time_value 当作刷新口令', () {
      final c = parseBiliCookieCreds(
          'SESSDATA=FAKE_SESSDATA; ac_time_value=FAKE_REFRESH');
      expect(c.refreshToken, 'FAKE_REFRESH');
    });

    test('值含 `=` 时只在第一个 `=` 处切分（不丢整条）', () {
      final c = parseBiliCookieCreds('SESSDATA=FAKE_a=b=c');
      expect(c.sessdata, 'FAKE_a=b=c');
    });

    test('值被引号包着 → 剥掉外层引号', () {
      final c = parseBiliCookieCreds('SESSDATA="FAKE_SESSDATA"; '
          "bili_jct='FAKE_JCT'");
      expect(c.sessdata, 'FAKE_SESSDATA');
      expect(c.biliJct, 'FAKE_JCT');
    });

    test('Set-Cookie 整行（带 Path/HttpOnly/Secure）→ 只认凭据键', () {
      final c = parseBiliCookieCreds(
          'SESSDATA=FAKE_SESSDATA; Path=/; Domain=.bilibili.com; HttpOnly; Secure');
      expect(c.sessdata, 'FAKE_SESSDATA');
      expect(c.biliJct, isNull);
      expect(c.refreshToken, isNull);
    });

    test('只有 SESSDATA 也能用（jct / 刷新口令缺省）', () {
      final c = parseBiliCookieCreds('SESSDATA=FAKE_SESSDATA');
      expect(c.hasSessdata, isTrue);
      expect(c.biliJct, isNull);
      expect(c.refreshToken, isNull);
    });

    test('没有 SESSDATA（只有 bili_jct）→ hasSessdata 为 false', () {
      final c = parseBiliCookieCreds('bili_jct=FAKE_JCT');
      expect(c.hasSessdata, isFalse);
    });

    test('空串 / 纯垃圾串 → 全空，不抛异常', () {
      expect(parseBiliCookieCreds('').hasSessdata, isFalse);
      expect(parseBiliCookieCreds(';;;  \n ;').hasSessdata, isFalse);
      expect(parseBiliCookieCreds('not a cookie').hasSessdata, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 2. BiliApi.verifySession（服务端校验的四个结论）
  // -------------------------------------------------------------------------
  group('verifySession（服务端校验）', () {
    test('code=0 且 isLogin=true → passed（带上待校验的 cookie）', () async {
      final adapter = _NavAdapter(_navOk());
      final result = await _api(adapter).verifySession(
        sessdata: 'FAKE_SESSDATA',
        biliJct: 'FAKE_JCT',
      );

      expect(result.passed, isTrue);
      expect(result.status, SessionVerifyStatus.ok);
      expect(result.mid, 12345);
      final req = adapter.requests.single;
      expect(req.path, '/x/web-interface/nav');
      expect(req.headers['Cookie'], contains('SESSDATA=FAKE_SESSDATA'));
      expect(req.headers['Cookie'], contains('bili_jct=FAKE_JCT'));
    });

    test('code=-101 → invalid（passed=false）', () async {
      final adapter = _NavAdapter(_navNotLogin());
      final result = await _api(adapter).verifySession(sessdata: 'FAKE_SESSDATA');

      expect(result.passed, isFalse);
      expect(result.status, SessionVerifyStatus.invalid);
      expect(result.code, -101);
    });

    test('code=0 但服务端当匿名处理（isLogin 不为 true）→ invalid', () async {
      final adapter = _NavAdapter({
        'code': 0,
        'message': '0',
        'data': {'isLogin': false, 'mid': 0},
      });
      final result = await _api(adapter).verifySession(sessdata: 'FAKE_SESSDATA');

      expect(result.passed, isFalse);
      expect(result.status, SessionVerifyStatus.invalid);
    });

    test('网络失败 → network（passed=false，结论未知也算不通过）', () async {
      final result =
          await _api(_NavAdapter.network()).verifySession(sessdata: 'FAKE_SESSDATA');

      expect(result.passed, isFalse);
      expect(result.status, SessionVerifyStatus.network);
      expect(result.code, isNull);
    });

    test('风控业务码 -412 → rejected（passed=false，不当成功也不当失效）', () async {
      final adapter = _NavAdapter({'code': -412, 'message': '请求被拦截'});
      final result = await _api(adapter).verifySession(sessdata: 'FAKE_SESSDATA');

      expect(result.passed, isFalse);
      expect(result.status, SessionVerifyStatus.rejected);
      expect(result.code, -412);
    });

    test('空 SESSDATA → 直接 invalid，且一次请求都不发', () async {
      final adapter = _NavAdapter(_navOk());
      final result = await _api(adapter).verifySession(sessdata: '   ');

      expect(result.passed, isFalse);
      expect(adapter.requests, isEmpty);
    });

    test('校验不改动本地已存会话（fail 也不落盘）', () async {
      _store['bili_sessdata'] = 'OLD_FAKE';
      final adapter = _NavAdapter(_navNotLogin());
      await _api(adapter).verifySession(sessdata: 'FAKE_SESSDATA');

      expect(_store['bili_sessdata'], 'OLD_FAKE');
    });
  });

  // -------------------------------------------------------------------------
  // 3. 清死会话时，WebView 里那份 cookie 也要清
  // -------------------------------------------------------------------------
  group('清死会话（-101）同步清 WebView cookie', () {
    test('收藏夹链路撞 -101 → 清 secure storage + 调原生 clearAll', () async {
      _store['bili_sessdata'] = 'FAKE_SESSDATA';
      _store['bili_jct'] = 'FAKE_JCT';
      final adapter = _NavAdapter(_navNotLogin());
      final api = _api(adapter);

      await expectLater(
        api.fetchMyFavorites(),
        throwsA(isA<BiliApiException>()),
      );

      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(_store.containsKey('bili_jct'), isFalse);
      expect(_cookieCalls, contains('clearAll'));
    });

    test('原生通道不可用（清不掉）也不影响 -101 正常上抛', () async {
      _store['bili_sessdata'] = 'FAKE_SESSDATA';
      _cookieChannelFails = true;
      final api = _api(_NavAdapter(_navNotLogin()));

      await expectLater(
        api.fetchMyFavorites(),
        throwsA(isA<BiliApiException>()),
      );
      expect(_store.containsKey('bili_sessdata'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 4. 登录页：服务端不点头就不算成功（堵死"假成功"循环）
  // -------------------------------------------------------------------------
  group('登录页：服务端校验', () {
    testWidgets('cookie 有 SESSDATA 但服务端 -101 → 不 pop、不落盘、提示原因、清死 cookie',
        (tester) async {
      _cookieValue = 'SESSDATA=FAKE_DEAD_SESSDATA; bili_jct=FAKE_JCT';
      final adapter = _NavAdapter(_navNotLogin());
      final outcome = await _pushLogin(tester, api: _api(adapter));

      // 轮询（1s 一次）与首次自检都要跑过：推进 2 秒足够
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(adapter.requests, isNotEmpty); // 真的去问了服务端
      expect(find.byType(LoginPage), findsOneWidget); // 留在登录页
      expect(outcome.popped, isFalse); // 没有 pop
      expect(find.textContaining('登录成功'), findsNothing); // 没有假成功
      expect(find.textContaining('-101'), findsOneWidget); // 明确说出原因
      expect(_store.containsKey('bili_sessdata'), isFalse); // 绝不落盘
      expect(_cookieCalls, contains('clearAll')); // 死 cookie 一并清掉

      // 推走页面，避免测试结束时还留着定时器
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('同一份 cookie 不会每秒重复打服务端（去重生效）', (tester) async {
      _cookieValue = 'SESSDATA=FAKE_DEAD_SESSDATA';
      final adapter = _NavAdapter(_navNotLogin());
      await _pushLogin(tester, api: _api(adapter));

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(adapter.requests.length, 1);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('死 cookie 判否后，用户在页面里重新登录（新 cookie）→ 被校验通过并登录成功',
        (tester) async {
      // 第一段：残留死 cookie → 服务端 -101 → 不成功、不落盘
      _cookieValue = 'SESSDATA=FAKE_DEAD_SESSDATA';
      final adapter = _NavAdapter(_navNotLogin());
      final outcome = await _pushLogin(tester, api: _api(adapter));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('-101'), findsOneWidget);
      expect(outcome.popped, isFalse);

      // 第二段：用户在 WebView 里重新登录 → cookie 变成新的，服务端这次点头。
      // 关键：轮询必须还在跑（校验开始时它被停过）——否则新会话永远没人发现，
      // 用户就会卡在"明明登录了却没反应"上。
      _cookieValue = 'SESSDATA=FAKE_NEW_SESSDATA; bili_jct=FAKE_NEW_JCT';
      adapter.body = _navOk();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(_store['bili_sessdata'], 'FAKE_NEW_SESSDATA');
      expect(_store['bili_jct'], 'FAKE_NEW_JCT');
      expect(outcome.value, isTrue);
      expect(find.byType(LoginPage), findsNothing);
    });

    testWidgets('服务端点头 → 落盘（三个 key）+ 提示 + pop(true)', (tester) async {
      _cookieValue = 'SESSDATA=FAKE_SESSDATA; bili_jct=FAKE_JCT; '
          'ac_time_value=FAKE_REFRESH';
      final adapter = _NavAdapter(_navOk());
      final outcome = await _pushLogin(tester, api: _api(adapter));

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(outcome.value, isTrue);
      expect(find.byType(LoginPage), findsNothing);
      expect(_store['bili_sessdata'], 'FAKE_SESSDATA');
      expect(_store['bili_jct'], 'FAKE_JCT');
      expect(_store['bili_refresh_token'], 'FAKE_REFRESH');
      expect(find.text('登录成功，已解锁 1080P 清晰度'), findsOneWidget);
    });

    testWidgets('校验撞网络失败 → 不落盘、不 pop，给「重新校验」', (tester) async {
      _cookieValue = 'SESSDATA=FAKE_SESSDATA';
      final outcome = await _pushLogin(tester, api: _api(_NavAdapter.network()));

      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(outcome.popped, isFalse);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(find.textContaining('无法确认登录状态'), findsOneWidget);
      expect(find.text('重新校验'), findsOneWidget);
      // 网络失败时**不清** WebView cookie（结论未知，不该动本机那份）
      expect(_cookieCalls, isNot(contains('clearAll')));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('cookie 里没有 SESSDATA → 一次服务端请求都不发', (tester) async {
      _cookieValue = 'buvid3=xyz';
      final adapter = _NavAdapter(_navOk());
      await _pushLogin(tester, api: _api(adapter));

      await tester.pump(const Duration(seconds: 2));

      expect(adapter.requests, isEmpty);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  // -------------------------------------------------------------------------
  // 5. 看门狗（10 秒）+ 「清除网页数据后重试」
  // -------------------------------------------------------------------------
  group('登录页：加载卡住（看门狗）与自救入口', () {
    testWidgets('10 秒仍未加载完 → 错误页 + 「清除网页数据后重试」（此前无任何提示）',
        (tester) async {
      // 注入"构造成功但页面永远加载不完"的替身：真机上渲染进程崩掉时就是这样
      // （没有任何 Dart 回调），而测试环境里真 WebViewController 构造即抛，
      // 走不到这条路径。
      await tester.pumpWidget(MaterialApp(
        home: LoginPage(api: _api(_NavAdapter(_navOk())), createWebView: () async {}),
      ));

      await tester.pump(const Duration(milliseconds: 500));
      // 5 秒时还没到点：仍在加载态（看门狗确实是 10 秒这个量级在起作用）
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(AppErrorView), findsNothing);
      expect(find.byType(AppLoadingView), findsOneWidget);

      // 越过 10 秒 → 明确错误态
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.textContaining('10 秒仍未加载完成'), findsOneWidget);
      expect(find.text('清除网页数据后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('已有具体加载错误时，看门狗不覆盖它（保住可诊断的原因）',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LoginPage(
          api: _api(_NavAdapter(_navOk())),
          createWebView: () async => throw PlatformException(
            code: 'webview_unavailable',
            message: 'no provider',
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('登录页加载失败'), findsOneWidget);

      await tester.pump(const Duration(seconds: 12));
      // 12 秒后仍是那条具体原因，而不是被"仍未加载完成"盖掉
      expect(find.textContaining('登录页加载失败'), findsOneWidget);
      expect(find.textContaining('仍未加载完成'), findsNothing);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('点「清除网页数据后重试」→ 调原生 clearAllData 并重建 WebView',
        (tester) async {
      var created = 0;
      await tester.pumpWidget(MaterialApp(
        home: LoginPage(
          api: _api(_NavAdapter(_navOk())),
          createWebView: () async {
            created++;
            throw PlatformException(code: 'webview_unavailable');
          },
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.byType(AppErrorView), findsOneWidget);
      expect(created, 1);

      await tester.tap(find.text('清除网页数据后重试'));
      await tester.pump();
      await tester.pump();

      expect(_cookieCalls, contains('clearAllData'));
      // 重建了一次（清完数据后重新走创建流程），且仍然失败 → 回到错误态
      expect(created, 2);
      expect(find.byType(AppErrorView), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });
}
