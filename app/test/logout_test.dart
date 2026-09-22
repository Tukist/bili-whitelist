// 「退出登录」单测（v2.49.1+）。
//
// 为什么需要这个功能：在此之前"退不出登录"——用户想换账号 / 把凭据从这台机器上
// 抹掉，只能去系统设置里清 App 数据（等于顺手丢掉 GitHub 配置与本地数据）。
//
// 这组用例锁住的关键性质：
// 1. **两处都要清**：secure storage 的三个 key（`bili_sessdata` / `bili_jct` /
//    `bili_refresh_token`）**以及** WebView cookie jar。cookie jar 是同一份会话的
//    第二处拷贝，而登录页正是拿它判"登录是否成功"的（见 login_page `_checkLogin`）
//    ——只清一处的话，用户下次打开登录页就会被那份残留 cookie 自动登回去，
//    退出等于没退。
// 2. 有确认步骤（误触不该把人踢出去），**未确认前什么都不动**；
// 3. 退完刷新成未登录：账号区文案变「未登录」+ 首页「未登录仅 720P」提示条出现
//    （经宿主 `onSessionChanged` 挂钩），且**不自动弹登录页**；
// 4. 本机没会话时不显示入口（按了也没东西可退，不做按不动的假入口）。
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
import 'package:bili_whitelist_app/pages/login_page.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/web_login_cookies.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

// ---------------------------------------------------------------------------
// 平台替身：内存版 secure storage + cookie 通道桩（同 login_cookie_verify_test）
// ---------------------------------------------------------------------------

Map<String, String> _store = {};

/// cookie 通道被调用的方法名（按顺序）；断言"退出时确实清了 WebView cookie"。
List<String> _cookieCalls = [];

/// `getCookies` 返回的 cookie 串（空串 = jar 里没有 cookie）。
///
/// 桩里 `clearAll` 会把**它**也清空——与真机一致：清完 jar，`getCookies`
/// 就读不到东西了。下面"退出后再进登录页"那条用例正是靠这个语义成立。
String _cookieValue = '';

/// 让 cookie 通道整体不可用（模拟原生组件缺失）。
bool _cookieChannelFails = false;

/// 让 secure storage 的 `read` / `delete` 抛异常（Keystore 故障两种表现）。
bool _storageDeleteFails = false;
bool _storageReadFails = false;

void _mockPlatform() {
  _store = {};
  _cookieCalls = [];
  _cookieValue = '';
  _cookieChannelFails = false;
  _storageDeleteFails = false;
  _storageReadFails = false;

  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(storage, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        if (_storageReadFails) {
          throw PlatformException(code: 'keystore_error');
        }
        return _store[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        _store[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        if (_storageDeleteFails) {
          throw PlatformException(code: 'keystore_error');
        }
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
      case 'clearAll':
        _cookieValue = ''; // 清完 jar 就读不到了（与真机同语义）
        return null;
      default:
        return null;
    }
  });
}

/// 构造可被 [BiliApi.sessdataExpireAt] 解析的（合成）SESSDATA：
/// `urlencode(uid,<过期秒>,md5...)` 结构，仅用于登录态 UI 测试。
String _fakeSessdata(Duration validFor) {
  final expireSec =
      DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
  return '12345,$expireSec,${'a' * 32}';
}

/// 固定响应的 dio adapter（不访问真实网络）：用来断言"该不该打服务端"。
/// [body] 是 `nav` 的**成功**响应——假设登录页错误地拿残留 cookie 去校验，
/// 这份响应会让它"登录成功"，所以"一次请求都没发"才是有意义的结论。
class _NavAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'code': 0,
        'message': '0',
        'data': {'isLogin': true, 'mid': 12345},
      }),
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

// ---------------------------------------------------------------------------
// 装配
// ---------------------------------------------------------------------------

/// 直挂管理面板（不经过首页），用于入口显隐 / 确认与清理 / 失败路径。
Future<void> _pumpPanel(
  WidgetTester tester, {
  VoidCallback? onSessionChanged,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ManagePanel(
          github: GithubApi(),
          onManageCollections: () {},
          onCheckUpdate: () {},
          onLogin: () {},
          onSessionChanged: onSessionChanged,
          headingTitle: '设置',
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 点「退出登录」并确认。
Future<void> _tapLogoutAndConfirm(WidgetTester tester) async {
  await tester.tap(find.byKey(kLogoutButtonKey));
  await tester.pumpAndSettle();
  expect(find.text('退出 B 站登录？'), findsOneWidget); // 先确认
  await tester.tap(find.text('退出'));
  await tester.pumpAndSettle();
}

/// 进入底部导航「个人」页，并把设置区（管理面板内联在观看统计下方）
/// 滚到可见（同 auto_login_test 的做法）。
Future<void> _openPersonalSettings(WidgetTester tester, Finder target) async {
  await tester.tap(find.byTooltip('个人（观看统计 / 设置）'));
  await tester.pumpAndSettle();
  for (var i = 0; i < 8 && target.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  expect(target, findsWidgets);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockPlatform();
    SharedPreferences.setMockInitialValues({});
  });

  // -------------------------------------------------------------------------
  // 1. 入口显隐（未登录不显示）
  // -------------------------------------------------------------------------
  group('「退出登录」入口显隐', () {
    testWidgets('未登录（本机无会话）→ 不显示入口', (tester) async {
      await _pumpPanel(tester);

      expect(find.textContaining('未登录：登录后可解锁 1080P'), findsOneWidget);
      expect(find.byKey(kLogoutButtonKey), findsNothing);
      // 对照：登录入口照旧在（没登录时该给的是「登录」）
      expect(find.text('登录'), findsOneWidget);
    });

    testWidgets('已登录 → 显示入口（与「登录 / 重新登录」「粘贴 Cookie 登录」并列）',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      await _pumpPanel(tester);

      expect(find.textContaining('已登录：B 站账号已连接'), findsOneWidget);
      expect(find.byKey(kLogoutButtonKey), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      // 既有入口一个都没被顶掉
      expect(find.text('重新登录'), findsOneWidget);
      expect(find.byKey(kPasteCookieButtonKey), findsOneWidget);
    });

    testWidgets('本机会话已过期（有残留会话）→ 仍显示入口（那是唯一能清掉残留的地方）',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: -1));
      await _pumpPanel(tester);

      expect(find.textContaining('登录已过期'), findsOneWidget);
      expect(find.byKey(kLogoutButtonKey), findsOneWidget);
    });

    testWidgets('读不到登录态（存储异常）→ 不显示入口（不是"未登录"，但也没东西可退）',
        (tester) async {
      _storageReadFails = true;
      await _pumpPanel(tester);

      expect(find.textContaining('读取登录态失败'), findsOneWidget);
      expect(find.byKey(kLogoutButtonKey), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // 2. 确认步骤 + 两处一起清
  // -------------------------------------------------------------------------
  group('退出登录：确认与清理', () {
    testWidgets('点入口先弹确认框；点「取消」→ 什么都不清、仍是已登录', (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      _store['bili_jct'] = 'FAKE_JCT';
      _store['bili_refresh_token'] = 'FAKE_REFRESH';
      _cookieValue = 'SESSDATA=FAKE_SESSDATA; bili_jct=FAKE_JCT';
      await _pumpPanel(tester);

      await tester.tap(find.byKey(kLogoutButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('退出 B 站登录？'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 三个 key 原封不动
      expect(_store['bili_sessdata'], isNotNull);
      expect(_store['bili_jct'], 'FAKE_JCT');
      expect(_store['bili_refresh_token'], 'FAKE_REFRESH');
      // WebView cookie 也没动
      expect(_cookieCalls, isNot(contains('clearAll')));
      expect(_cookieValue, isNotEmpty);
      // 界面仍是已登录
      expect(find.textContaining('已登录：B 站账号已连接'), findsOneWidget);
    });

    testWidgets('确认后：storage 三个 key 全清 + WebView cookie 清理被调用 + 账号区变未登录',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      _store['bili_jct'] = 'FAKE_JCT';
      _store['bili_refresh_token'] = 'FAKE_REFRESH';
      _cookieValue = 'SESSDATA=FAKE_SESSDATA; bili_jct=FAKE_JCT';
      await _pumpPanel(tester);

      await _tapLogoutAndConfirm(tester);

      // 三个 key 全清（少清一个都会留下半份会话）
      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(_store.containsKey('bili_jct'), isFalse);
      expect(_store.containsKey('bili_refresh_token'), isFalse);
      // WebView 那份也被要求清了（通道桩：清完 getCookies 读不到）
      expect(_cookieCalls, contains('clearAll'));
      expect(_cookieValue, isEmpty);
      // 账号区立刻变未登录 + 提示 + 入口消失
      expect(find.textContaining('未登录：登录后可解锁 1080P'), findsOneWidget);
      expect(find.textContaining('已退出登录'), findsOneWidget);
      expect(find.byKey(kLogoutButtonKey), findsNothing);
      // 退完不自动弹登录页（那是用户下一步的选择）——面板还在原位，登录入口在
      expect(find.byKey(kPasteCookieButtonKey), findsOneWidget);
      expect(find.text('登录'), findsOneWidget);
    });

    testWidgets('确认后通知宿主（首页提示条/关注同步的挂钩）', (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      var notified = 0;
      await _pumpPanel(tester, onSessionChanged: () => notified++);

      await _tapLogoutAndConfirm(tester);

      expect(notified, 1);
    });

    testWidgets('WebView cookie 清不掉（通道不可用）→ 本机凭据照样清，但如实提示没清干净',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      _store['bili_jct'] = 'FAKE_JCT';
      _cookieValue = 'SESSDATA=FAKE_SESSDATA';
      _cookieChannelFails = true;
      await _pumpPanel(tester);

      await _tapLogoutAndConfirm(tester);

      // 本机那份清了（App 侧确实退出），但**不能含糊说"已退出"**——
      // 残留 cookie 会让登录页显示成"已登录"，必须让用户知道
      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(find.textContaining('网页数据没清干净'), findsOneWidget);
      expect(find.textContaining('已退出登录（本机凭据与网页登录状态都已清除）'),
          findsNothing);
    });

    testWidgets('本机凭据清不掉（存储异常）→ 报退出失败，不谎报成功；仍会去清 WebView 那份',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      _storageDeleteFails = true;
      _cookieValue = 'SESSDATA=FAKE_SESSDATA';
      await _pumpPanel(tester);

      await _tapLogoutAndConfirm(tester);

      expect(find.textContaining('退出失败'), findsOneWidget);
      // 第一步失败不跳过第二步：jar 里那份照清（少一份残留总是好事）
      expect(_cookieCalls, contains('clearAll'));
      // 存储里那份还在 → 界面不会假装"未登录"
      expect(find.textContaining('已登录：B 站账号已连接'), findsOneWidget);
      expect(find.byKey(kLogoutButtonKey), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // 3. 全流程：「个人」页退出 → 首页提示条出现（不再残留"已登录"假象）
  // -------------------------------------------------------------------------
  group('首页：退出后不再残留已登录假象', () {
    /// 首页 + 注入的登录导航替身（不真推含 WebView 的登录页）。
    Future<int Function()> pumpHome(WidgetTester tester) async {
      var loginCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: PlaylistPage(openLogin: (_, {String? banner}) async {
          loginCalls++;
        }),
      ));
      await tester.pump();
      await tester.pump();
      return () => loginCalls;
    }

    testWidgets('已登录冷启动 → 无提示条；退出登录后 → 出现「未登录仅 720P」提示条',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      _store['bili_jct'] = 'FAKE_JCT';
      _cookieValue = 'SESSDATA=FAKE_SESSDATA; bili_jct=FAKE_JCT';
      final loginCalls = await pumpHome(tester);

      // 冷启动：会话有效 → 静默恢复，首页不该有未登录提示条
      expect(find.textContaining('未登录仅 720P'), findsNothing);
      expect(loginCalls(), 0);

      // 「个人」页 → 设置区 → 退出登录
      await _openPersonalSettings(tester, find.byKey(kLogoutButtonKey));
      await _tapLogoutAndConfirm(tester);
      expect(find.textContaining('未登录：登录后可解锁 1080P'), findsOneWidget);

      // 回首页：提示条出现（宿主经 onSessionChanged 重查登录态）
      await tester.tap(find.byTooltip('合集（白名单视频）'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('未登录仅 720P'), findsOneWidget);
      // 退出**不**自动弹登录页：本次进程里一次都没请求过登录页
      expect(loginCalls(), 0);
      // 两处凭据都空了
      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(_cookieValue, isEmpty);
    });

    testWidgets('退出后再走一次登录页：读不到 SESSDATA → 一次服务端请求都不发、不落盘',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      _store['bili_jct'] = 'FAKE_JCT';
      // jar 里先留一份 cookie：正是"只清 storage 不清 jar"会留下的那种残留
      _cookieValue = 'SESSDATA=FAKE_DEAD_SESSDATA; bili_jct=FAKE_JCT';
      await _pumpPanel(tester);

      await _tapLogoutAndConfirm(tester);
      expect(_cookieValue, isEmpty);
      expect(_store, isEmpty);

      // 退出后用户自己打开登录页：登录页只读得到"干净的空 jar"，
      // 因此不会拿残留 cookie 去校验、更不会被判成功（不落盘、不 pop）
      var created = 0;
      final adapter = _NavAdapter();
      await tester.pumpWidget(MaterialApp(
        home: LoginPage(
          api: _api(adapter),
          createWebView: () async {
            created++;
          },
        ),
      ));
      await tester.pump(const Duration(seconds: 2));

      expect(created, 1);
      expect(adapter.requests, isEmpty); // 一次服务端请求都不发
      expect(find.textContaining('登录成功'), findsNothing);
      expect(_store, isEmpty);

      // 推走页面，避免测试结束时还留着定时器
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });
}
