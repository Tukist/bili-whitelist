// 「稍后再看」入口的位置（v2.58.0 在个人页 → **v2.59.0 搬到合集页**）：
// - 个人页（观看统计页）**不再**有入口（用户原话「现在的在个人页面顶部的页面
//   稍后再看要移动到合集页面和收藏夹平行」）；
// - 合集页「收藏夹」卡右边（同一行、同宽同高）多一张同样式的「稍后再看」卡；
// - 卡上副标显示条数（拿到才显示数字，拿不到显示中性文案——不假装 0）；
//   条数来自会话缓存 `toViewCachedCount`（稍后再看页 / 播放页拉过列表就写），
//   合集页自己**不发请求**；
// - 未登录点击 → 提示需登录 + 引导登录（与收藏夹卡同一套门禁）。
//
// 不触网：合集页不发网络请求（登录门禁用注入的 openLogin 替身，导航用
// openWatchLater 替身）；条数用 `cacheToViewCount` 直接种进会话缓存。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/pages/watch_later_page.dart';
import 'package:bili_whitelist_app/pages/watch_stats_page.dart';
import 'package:bili_whitelist_app/services/bili_toview_api.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';

/// 内存版 secure storage（默认空 = 未登录）。
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

/// 白名单同步不落真盘（主页 initState 会拉一次缓存）。
class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 假的稍后再看服务：用于验证「稍后再看页拉过列表之后」的条数传播
/// （合集页那张卡读的是会话缓存 `toViewCachedCount`）。
BiliToViewService _fakeService({int count = 3}) => BiliToViewService(
      fetchList: () async => {
        'count': count,
        'list': [
          for (var i = 0; i < count; i++)
            {'aid': 100 + i, 'bvid': 'BV1fake$i'},
        ],
      },
      add: ({int? aid, String? bvid}) async {},
      remove: (aid) async {},
    );

Future<void> _pumpHome(
  WidgetTester tester, {
  Future<void> Function(BuildContext context, {String? banner})? openLogin,
  Future<void> Function(BuildContext context)? openWatchLater,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: PlaylistPage(
      // 未注入登录替身时会去构造真实 LoginPage（WebView 平台未注册会 assert），
      // 这里统一给一个空实现（各用例需要计数时自己传）
      openLogin: openLogin ?? (context, {banner}) async {},
      openWatchLater: openWatchLater,
    ),
  ));
  await tester.pump(); // 启动自动登录 / 数据加载
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _store.clear();
    _mockSecureStorage();
    ServiceLocator.overrideSyncService(_FakeSyncService());
    // 会话内条数是库级变量：每条用例从"还不知道"起步（否则上一条的 7
    // 会被下一条读成"拿到的"）
    cacheToViewCount(null);
  });

  group('个人页（观看统计）', () {
    testWidgets('不再有「稍后再看」入口（v2.59.0 搬到合集页）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: WatchStatsPage(stats: WatchStats())),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kWatchLaterEntryKey), findsNothing);
      expect(find.text('稍后再看'), findsNothing);
      // 页头标题还在（删入口不是把整行删了）
      expect(find.text('观看统计'), findsOneWidget);
    });

    testWidgets('设置区仍然在统计内容之后（删入口没动布局）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WatchStatsPage(
            stats: WatchStats(),
            settingsSection: const Text('设置区标记'),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('观看总览')).dy,
        lessThan(tester.getTopLeft(find.text('设置区标记')).dy),
      );
    });
  });

  group('合集页：与「收藏夹」卡并列的「稍后再看」卡', () {
    testWidgets('两张卡都在：并排、同宽同高（平行）', (tester) async {
      await _pumpHome(tester);

      expect(find.text('收藏夹'), findsOneWidget);
      expect(find.text('稍后再看'), findsOneWidget);
      expect(find.byKey(kWatchLaterEntryKey), findsOneWidget);

      // 两张卡是同一个组件（_AccountEntryCard）→ 同一行、同宽、同高
      final favCard = tester.getRect(find
          .ancestor(of: find.text('收藏夹'), matching: find.byType(AppBlock))
          .first);
      final toViewCard = tester.getRect(find
          .ancestor(of: find.text('稍后再看'), matching: find.byType(AppBlock))
          .first);
      expect(toViewCard.left, greaterThan(favCard.right), reason: '并排：在收藏夹右侧');
      expect(toViewCard.width, favCard.width, reason: '同宽 = 同级');
      expect(toViewCard.height, favCard.height, reason: '同高 = 同级');
      expect(toViewCard.top, favCard.top, reason: '同一行');
    });

    testWidgets('条数：会话里已知就显示数字（稍后再看页拉过列表 → 写进缓存）',
        (tester) async {
      // 模拟"稍后再看页已经拉过一次列表"：会话缓存里已经有条数
      cacheToViewCount(7);
      await _pumpHome(tester);

      expect(find.text('7 个视频'), findsOneWidget);
    });

    testWidgets('条数未知（没拉过/未登录/失败）：显示中性文案，不假装 0',
        (tester) async {
      cacheToViewCount(null); // 明确"还不知道"
      await _pumpHome(tester);

      expect(find.text('B 站账号里的稍后再看'), findsOneWidget);
      expect(find.text('0 个视频'), findsNothing);
    });

    testWidgets('稍后再看页拉过列表后，条数真的会传到这张卡上（端到端）',
        (tester) async {
      cacheToViewCount(null);
      // 用真实页面 + 注入服务：页面 _load 成功 → cacheToViewCount(count)
      await tester.pumpWidget(MaterialApp(
        home: WatchLaterPage(service: _fakeService(count: 4)),
      ));
      await tester.pumpAndSettle();
      expect(toViewCachedCount, 4);

      // 回到合集页（重新建树）：卡片读到 4
      await _pumpHome(tester);
      expect(find.text('4 个视频'), findsOneWidget);
    });

    testWidgets('未登录点击 → 提示需登录 + 引导登录，不进稍后再看页',
        (tester) async {
      var loginCalls = 0;
      Future<void> openLoginSpy(BuildContext context, {String? banner}) async {
        loginCalls++;
      }

      await _pumpHome(tester, openLogin: openLoginSpy);

      await tester.tap(find.byKey(kWatchLaterEntryKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.text('稍后再看需要登录 B 站账号（稍后再看属于个人账号数据）'),
        findsOneWidget,
      );
      expect(loginCalls, greaterThanOrEqualTo(1));
      expect(find.byType(WatchLaterPage), findsNothing);
    });

    testWidgets('已登录点击 → 走导航（不进登录门禁）', (tester) async {
      final expireSec =
          DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
              1000;
      _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
      var loginCalls = 0;
      Future<void> openLoginSpy(BuildContext context, {String? banner}) async {
        loginCalls++;
      }

      var navigations = 0;
      await _pumpHome(
        tester,
        openLogin: openLoginSpy,
        // 注入导航替身：真实 WatchLaterPage 一进页面就拉账号那份列表（真网络），
        // 这里要验的只是"门禁过了之后有没有往那一页去"
        openWatchLater: (context) async => navigations++,
      );

      await tester.tap(find.byKey(kWatchLaterEntryKey));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(navigations, 1, reason: '已登录 → 直接去稍后再看页');
      expect(loginCalls, 0, reason: '已登录：不需要引导登录');
      expect(
        find.text('稍后再看需要登录 B 站账号（稍后再看属于个人账号数据）'),
        findsNothing,
      );
    });
  });
}
