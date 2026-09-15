// ManagePanel（v2.17.10 自首页 _ManageSheet 抽取；v2.19.0 起由底部导航
// 「个人」页底部内联承载）widget 测试：
// - 内联模式（closeBeforeNavigate=false，「个人」页场景）：分区标题可用
//   「设置」；各管理分区渲染；点「登录」调回调且不 pop（无路由可 pop）
// - 保存 GitHub 配置走真实 GithubApi（secure storage channel mock）
// - 已登录（模拟 SESSDATA 有效）显示「重新登录」文案
// - 「新建合集」已移到合集页（v2.19.0）→ 面板内不再有该分区
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/cache/download_manager.dart';
import 'package:bili_whitelist_app/main.dart';
import 'package:bili_whitelist_app/pages/offline_page.dart';
import 'package:bili_whitelist_app/services/theme_store.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

/// 内存版 secure storage（mock 原生 MethodChannel，同 auto_login_test）。
Map<String, String> _store = {};

const MethodChannel _channel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
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
/// `urlencode(uid,<过期秒>,md5...)` 结构，仅用于登录态 UI 测试。
String _fakeSessdata(Duration validFor) {
  final expireSec =
      DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
  return '12345,$expireSec,${'a' * 32}';
}

class _Spy {
  int loginCalls = 0;
  int checkUpdateCalls = 0;
  int manageCollectionsCalls = 0;
}

/// 内存版 DownloadManager：只提供入口概要要的「已缓存列表」，
/// **不做任何真实文件 IO**（理由见「缓存入口文案」用例的注释）。
class _MemoryManager extends DownloadManager {
  _MemoryManager(List<CachedVideo> items) : _items = items {
    // 面板不会调 init()，构造时就发布（让它看起来像「索引已加载」）
    cached.value = _items;
  }

  final List<CachedVideo> _items;

  @override
  Future<void> init() async {
    if (!identical(cached.value, _items)) cached.value = _items;
  }
}

/// **懒加载版**内存 DownloadManager：构造时**不发布**，只有 [init] 被调用过
/// 才把列表发出来——复刻真实 [DownloadManager] 的行为（索引要等有人 `init()`
/// 才进内存，`getCachedList()` 在此之前是空的）。
///
/// 「缓存入口文案」那两条用例必须用这个版本才测得到东西：`_MemoryManager`
/// 构造即发布，即使 **没有人**预热索引，入口也照样显示计数（掩盖缺陷）。
class _LazyManager extends DownloadManager {
  _LazyManager(this._items);

  final List<CachedVideo> _items;

  /// `init()` 被调用了几次（断言启动预热真的跑过、且只跑一次）。
  int initCalls = 0;

  @override
  Future<void> init() async {
    initCalls++;
    // 真实 init 是异步读盘（不是同步就能拿到）：这里也过一趟事件循环
    await Future<void>.delayed(Duration.zero);
    cached.value = _items;
  }
}

/// 入口概要用的单条缓存记录（audioOnly：2 KB 音频）。
CachedVideo _cachedEntry() => CachedVideo(
      bvid: 'BV1entry',
      title: '入口概要测试',
      cover: '',
      pageIndex: 0,
      partTitle: '',
      videoPath: '',
      audioPath: '/fake/BV1entry_p1.audio.m4s',
      sizeBytes: 2048,
      cachedAt: DateTime.now().toUtc(),
      upName: 'up主',
      cid: 1,
      durationMs: 1000,
      audioOnly: true,
    );

Future<void> _pumpPanel(
  WidgetTester tester,
  ManagePanel panel,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: panel)),
  ));
  await tester.pumpAndSettle();
}

ManagePanel _panel(
  _Spy spy, {
  String heading = '管理',
  bool closeBeforeNavigate = false,
  VoidCallback? onLoginExtra,
}) {
  return ManagePanel(
    github: GithubApi(),
    closeBeforeNavigate: closeBeforeNavigate,
    headingTitle: heading,
    onManageCollections: () => spy.manageCollectionsCalls++,
    onCheckUpdate: () => spy.checkUpdateCalls++,
    onLogin: () {
      spy.loginCalls++;
      onLoginExtra?.call();
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store = {};
    _mockSecureStorage();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('ManagePanel 分区渲染（「个人」页底部内联共用组件）', () {
    testWidgets('内联模式：标题「设置」+ 各管理分区齐全（无「新建合集」）', (tester) async {
      final spy = _Spy();
      await _pumpPanel(
        tester,
        _panel(spy, heading: '设置'),
      );

      // 标题与全部管理分区
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('B 站账号'), findsOneWidget);
      expect(find.text('GitHub 配置'), findsOneWidget);
      expect(find.text('合集管理'), findsOneWidget);
      expect(find.text('离线缓存'), findsOneWidget);
      expect(find.text('翻译服务'), findsOneWidget);
      expect(find.text('版本更新'), findsOneWidget);
      // 「新建合集」已移到合集页（v2.19.0）：面板里不再有该分区/输入框
      expect(find.text('新建合集'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2)); // 只剩 token / gist
      // 未登录文案 + 登录按钮（无 SESSDATA → none）
      expect(find.textContaining('登录后可解锁 1080P'), findsOneWidget);
      expect(find.text('登录'), findsOneWidget);
    });

    testWidgets('内联模式点「登录」→ 调回调、不 pop（页面仍渲染）',
        (tester) async {
      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy, heading: '设置'));

      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(spy.loginCalls, 1);
      // 内联（closeBeforeNavigate=false）没有 pop：面板仍在
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('GitHub 配置'), findsOneWidget);
    });

    testWidgets('弹层模式（默认标题「管理」）：分区齐全、已登录显示「重新登录」',
        (tester) async {
      final spy = _Spy();
      // 已登录场景：模拟 SESSDATA 仍有效 → 「重新登录」
      _store['bili_sessdata'] = _fakeSessdata(const Duration(days: 30));
      await _pumpPanel(
        tester,
        _panel(spy, closeBeforeNavigate: true),
      );

      expect(find.text('管理'), findsOneWidget);
      expect(find.textContaining('已登录：B 站账号已连接'), findsOneWidget);
      expect(find.text('重新登录'), findsOneWidget);
      // 弹层宿主里点「登录」的真实 pop+推登录链路由 auto_login_test
      //（首页整页）覆盖
      expect(spy.loginCalls, 0);
    });

    testWidgets('保存 GitHub 配置 → 写入 secure storage + 成功提示',
        (tester) async {
      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy));

      // 填 token（第 0 个输入框 = GitHub Token）与 gist id（第 1 个）
      await tester.enterText(find.byType(TextField).at(0), 'ghp_test_token');
      await tester.enterText(find.byType(TextField).at(1), 'gist_abc123');
      // 面板在 600px 高的测试视口里放不下全部设置区（v2.21.0 起多了
      // 「信箱卡片样式」分区）→ 先滚到按钮再点（同文件「管理合集」用例的做法）
      await tester.ensureVisible(find.text('保存配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();

      expect(find.text('GitHub 配置已保存（仅存本机）'), findsOneWidget);
      expect(_store['github_token'], 'ghp_test_token');
      expect(_store['gist_id'], 'gist_abc123');
    });

    testWidgets('点「管理合集」→ 调回调（分区仍在设置面板里）', (tester) async {
      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy));

      final button = find.text('管理合集');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(spy.manageCollectionsCalls, 1);
    });

    testWidgets('配色主题（P1.5）：按钮显示当前配方 → 弹层选一套 → 即时生效',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      ThemeStore.instance.resetForTest();
      addTearDown(ThemeStore.instance.resetForTest);
      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy));

      // 当前配方显示在按钮上（默认 = 克莱因蓝 · 陶土）
      final button = find.text('配色：克莱因蓝 · 陶土');
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      // 弹层：中文名 + 英文原名（末尾几项在视口外，断言靠前的项）
      // 「配色主题」既是面板分区标题也是弹层标题 → 命中 2 处
      expect(find.text('配色主题'), findsNWidgets(2));
      expect(find.text('钴蓝 · 陶土'), findsOneWidget);
      expect(find.text('Cobalt · Terracotta'), findsOneWidget);

      await tester.tap(find.text('钴蓝 · 陶土'));
      await tester.pumpAndSettle();

      // 点击即生效（store 已切）并关闭弹层；按钮文案同步刷新
      expect(ThemeStore.instance.recipe.id, 'cobalt_terracotta');
      expect(find.text('Cobalt · Terracotta'), findsNothing);
      expect(find.text('配色：钴蓝 · 陶土'), findsOneWidget);
    });

    testWidgets('点「缓存管理」→ 进独立「离线缓存」页（不再开弹层，v2.29.0）',
        (tester) async {
      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy));

      final button = find.text('缓存管理');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      // 入口从弹层改成整页（两套并存会漂移，见 offline_page.dart 顶部说明）
      expect(find.byType(OfflinePage), findsOneWidget);
      expect(find.text('离线缓存'), findsOneWidget); // 页面 AppBar 标题
      // 无缓存 → 空态统一走 AppStateView（seed = cache）
      expect(find.text('暂无缓存'), findsOneWidget);
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.cache');
      expect(state.subtitleCopyId, 'empty.cache.sub');
      // 独立页自带滚动（不在弹层的有界高度里）
      expect(state.scrollable, isTrue);
      expect(
        tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
        'cache',
      );
    });

    testWidgets('缓存入口文案带实时概要（N 个视频 · X）', (tester) async {
      // 注入内存版 DownloadManager（**不做真实文件 IO**：flutter_test 的
      // FakeAsync 时区里 dart:io 异步永不完成，页面/入口的 IO 会卡死用例）
      final manager = _MemoryManager([
        CachedVideo(
          bvid: 'BV1entry',
          title: '入口概要测试',
          cover: '',
          pageIndex: 0,
          partTitle: '',
          videoPath: '',
          audioPath: '/fake/BV1entry_p1.audio.m4s',
          sizeBytes: 2048,
          cachedAt: DateTime.now().toUtc(),
          upName: 'up主',
          cid: 1,
          durationMs: 1000,
          audioOnly: true,
        ),
      ]);
      DownloadManager.debugOverride(manager);
      addTearDown(DownloadManager.debugReset);

      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy));

      expect(find.textContaining('缓存管理（1 个视频 · 2.0 KB）'), findsOneWidget);
    });

    testWidgets('冷启动预热：没访问过任何缓存页，入口概况就是正确计数（v2.29.0）',
        (tester) async {
      // 懒加载版 fake（构造时不发布列表）：只有「启动预热过一次」入口才有计数
      // —— 对齐真机现象（冷启动直奔「个人」页，合集页/离线页/播放页都没进过）
      final manager = _LazyManager([_cachedEntry()]);
      DownloadManager.debugOverride(manager);
      addTearDown(DownloadManager.debugReset);

      // 复刻 main() 的启动预热：**不 await**（不阻塞首帧），只让它异步落地
      unawaited(preheatCacheIndex());
      expect(manager.initCalls, 1, reason: '启动流程应预热一次缓存索引');

      final spy = _Spy();
      // 预热在飞的同时面板照常渲染（预热不卡首帧）
      await _pumpPanel(tester, _panel(spy));

      expect(
        find.textContaining('缓存管理（1 个视频 · 2.0 KB）'),
        findsOneWidget,
        reason: '冷启动后入口概况就该带计数（修复前这里只有「缓存管理」四个字）',
      );
      // 预热只此一次：面板/入口自己不重复碰盘（避免每次 build 都触发 IO）
      expect(manager.initCalls, 1);
    });

    testWidgets('反证：没预热时入口概况确实没有计数（懒加载索引没进内存）',
        (tester) async {
      // 这条是上面那条的「诚实性」护栏：证明 _LazyManager 真的懒（没人 init
      // 列表就没进内存）。否则上面那条即使去掉预热也会假绿。
      final manager = _LazyManager([_cachedEntry()]);
      DownloadManager.debugOverride(manager);
      addTearDown(DownloadManager.debugReset);

      final spy = _Spy();
      await _pumpPanel(tester, _panel(spy));

      expect(find.text('缓存管理'), findsOneWidget);
      expect(find.textContaining('缓存管理（'), findsNothing);
      expect(manager.initCalls, 0, reason: '预热在启动流程，面板自身不该碰索引');
    });
  });
}
