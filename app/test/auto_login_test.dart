// v2.16.18 自动登录单测：
// 1. planSessionStart 纯函数决策映射（无会话→autoLogin / <7天→refresh /
//    ≥7天→silent；含 7 天边界与已过期）
// 2. Widget：有会话（长期有效）冷启动 → 首页**无**登录按钮 tooltip、
//    不请求登录（静默恢复）；管理面板显示「已连接 + 重新登录」次级入口
// 3. Widget：无会话冷启动 → **自动请求登录**一次（带 kAutoLoginBanner 提示，
//    测试注入导航替身，不真推含 WebView 的 LoginPage）；管理面板显示
//    「未登录 + 登录」入口
// 4. Widget：会话已过期（无 refresh 凭据）→ 续期失败 → 自动请求重登 +
//    清除失效会话（v2.16.20 修复：残留过期 SESSDATA 不应再被播放取流
//    注入——服务端对真实过期 cookie 返回 -101 → 未登录播放没画面）；
//    会话有效但 <7 天且缺 refresh 凭据 → 续期失败未过期 → 保留、不请求
//
// 真实登录页（WebView 平台注册）只在真机/模拟器验证（CHANGELOG v2.16.18）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/pages/login_page.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';

/// 内存版 secure storage（mock 原生 MethodChannel，同 pgc_playurl_api_test）。
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

/// 构造可被 [BiliApi.sessdataExpireAt] 解析的（合成）SESSDATA：
/// `urlencode(uid,<过期秒>,md5...)` 结构，仅用于登录态 UI/流程测试，
/// 不是真实凭据、也无需服务端校验。
String _fakeSessdata(Duration validFor) {
  final expireSec =
      DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
  return '12345,$expireSec,${'a' * 32}';
}

/// 记录"请求打开登录页"的替身导航（记录次数 + 是否带自动引导 banner）。
class _LoginSpy {
  int calls = 0;
  String? lastBanner;

  Future<void> Function(BuildContext, {String? banner}) get handler =>
      (_, {String? banner}) async {
        calls++;
        lastBanner = banner;
      };
}

Future<void> _pumpHome(WidgetTester tester, _LoginSpy spy) async {
  await tester.pumpWidget(
    MaterialApp(home: PlaylistPage(openLogin: spy.handler)),
  );
  // 首帧后允许异步会话检查/同步任务完成（同 widget_test.dart 冒烟方式）
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('planSessionStart（启动登录态决策，纯函数）', () {
    test('无 SESSDATA（null）→ autoLogin（自动进登录页）', () {
      expect(planSessionStart(null), SessionStartAction.autoLogin);
    });

    test('距过期 ≥ 7 天 → silent（静默恢复）', () {
      expect(planSessionStart(const Duration(days: 30)),
          SessionStartAction.silent);
      expect(planSessionStart(const Duration(days: 7)),
          SessionStartAction.silent); // 边界：恰好 7 天不需续期
    });

    test('距过期 < 7 天 → refresh（静默续期）', () {
      expect(planSessionStart(const Duration(days: 6, hours: 23)),
          SessionStartAction.refresh);
      expect(planSessionStart(const Duration(hours: 1)),
          SessionStartAction.refresh);
      expect(planSessionStart(const Duration(minutes: 1)),
          SessionStartAction.refresh);
    });

    test('已过期（负数）→ refresh（先试续期；续期失败且过期才转 autoLogin）',
        () {
      expect(planSessionStart(const Duration(seconds: -1)),
          SessionStartAction.refresh);
      expect(planSessionStart(const Duration(days: -3)),
          SessionStartAction.refresh);
    });
  });

  group('首页自动登录（widget，注入登录导航替身）', () {
    setUp(() {
      _store = {};
      _mockSecureStorage();
    });

    testWidgets('无会话：冷启动自动请求登录一次（带自动引导 banner）',
        (tester) async {
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);

      // 启动检查为异步：需要再 pump 几帧让会话读取 + 首帧后导航回调执行
      await tester.pump();
      await tester.pump();

      expect(spy.calls, 1);
      expect(spy.lastBanner, kAutoLoginBanner);
      // 首页登录按钮已移除
      expect(find.byTooltip('登录（解锁 1080P）'), findsNothing);
    });

    testWidgets('无会话：自动登录请求只触发一次（防循环/重复弹页）',
        (tester) async {
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(spy.calls, 1);
    });

    testWidgets('有会话（≥7 天）：静默恢复，不请求登录、无登录按钮',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 60));
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);
      await tester.pump();
      await tester.pump();

      expect(spy.calls, 0); // 会话有效 → 完全静默
      expect(find.byTooltip('登录（解锁 1080P）'), findsNothing);
    });

    testWidgets('会话 <7 天且缺 refresh 凭据：续期失败未过期 → 保留、不请求登录',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 6));
      // 缺 bili_jct / refresh_token → refreshSession 直接返回 false（无网络）
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);
      await tester.pump();
      await tester.pump();

      expect(spy.calls, 0); // 未过期 → 保留现会话，不打扰
      expect(find.byTooltip('登录（解锁 1080P）'), findsNothing);
    });

    testWidgets('会话已过期且无 refresh 凭据：续期失败 → 自动请求重新登录'
        ' + 清除失效会话', (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: -1));
      _store['bili_jct'] = 'jct_stale';
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);
      await tester.pump();
      await tester.pump();

      expect(spy.calls, 1); // 彻底过期 → 引导重登
      expect(spy.lastBanner, kAutoLoginBanner);
      // 失效会话已被清除：避免残留过期 SESSDATA 后续被播放取流注入
      // （服务端对真实过期 cookie 返回 -101 → 未登录播放没画面）
      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(_store.containsKey('bili_jct'), isFalse);
    });

    testWidgets('管理面板：已登录显示「已连接 + 重新登录」次级入口',
        (tester) async {
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);

      await tester.tap(
        find.byTooltip('管理（GitHub 配置 / 合集 / B 站账号）'),
      );
      await tester.pumpAndSettle();

      expect(find.text('B 站账号'), findsOneWidget);
      expect(find.textContaining('已登录：B 站账号已连接'), findsOneWidget);
      expect(find.text('重新登录'), findsOneWidget);
      expect(find.text('登录（解锁 1080P）'), findsNothing);

      // 点「重新登录」→ 请求打开登录页（本次带 banner=null：手动入口）
      await tester.tap(find.text('重新登录'));
      await tester.pumpAndSettle();
      expect(spy.calls, 1);
      expect(spy.lastBanner, isNull);
    });

    testWidgets('管理面板：未登录显示「登录」次级入口', (tester) async {
      final spy = _LoginSpy();
      await _pumpHome(tester, spy);
      await tester.pump();
      await tester.pump();

      await tester.tap(
        find.byTooltip('管理（GitHub 配置 / 合集 / B 站账号）'),
      );
      await tester.pumpAndSettle();

      expect(find.text('B 站账号'), findsOneWidget);
      expect(find.textContaining('未登录'), findsOneWidget);
      expect(find.text('登录'), findsOneWidget);
    });
  });
}
