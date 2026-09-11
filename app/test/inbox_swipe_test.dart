// 信箱页 Tinder 式卡片栈的 widget 测试（v2.19.0+）：
// - 卡片排版：封面（16:9）/ 标题 / 作者（头像 + 名字）/ 时长 / 相对时间；
//   卡片宽度 ≈ 屏宽 88%，竖屏 411×914 下不出屏
// - 卡片栈：下层**底边对齐**（底边恒定露出 kInboxStackOffset + 缩放 kInboxStackScale
//   以底边为锚）→ 不论下一张标题 1 行还是 2 行，顶层下方都稳定可见它的边（#3）
// - 手势：右滑过阈值 = 加入（写白名单）、左滑过阈值 = 跳过（只记已处理）、
//   未过阈值 = 弹回且不调任何动作
// - 浮层标记：「加入」/「跳过」随手势渐显（幅度越大越明显），实心底走
//   `palette.inkFill` / `onInk`（已过对比度护栏）
// - 底部按钮「跳过」/「加入」与滑动等价；「撤销」把上一张放回来；
//   空态下底部仍留着「撤销上一张」（#2）
// - 后台 checkAll 进行中不阻塞交互：仍能点卡开播放页 / 划卡 / 撤销，
//   检查回来只追加新条目 → 卡片栈不跳回第一张、已消费的不复活（#1）
// - 队列被用户划空（后台检查还在跑）→ 显示空态而不是整页加载态（#6）
// - 点按卡片仍是「打开播放页」（本文件用"是否去 fetch view 元数据"当证据：
//   真去 push PlayerPage 要 mock 播放器通道，这里只验点按链路被触发）
// - 全部处理完 → `AppStateView(copyId: 'empty.inbox')`
// - 关动效（`flutter test` 默认）：松手即出栈、无动画层，`pumpAndSettle` 收敛；
//   开动效：飞出期间卡片仍在树上且被平移到屏幕外
// - 既有能力不丢：下拉刷新、错误态重试、加载英雄
//
// 全部接口走内存替身（不触网 / 不触原生插件 / 不碰真实 Gist）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/theme/app_palette.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/utils/relative_time.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/cover_image.dart';
import 'package:bili_whitelist_app/widgets/inbox_swipe_card.dart';

// ---------------------------------------------------------------------------
// 替身（全部内存态）
// ---------------------------------------------------------------------------

/// 假信箱服务：固定未读列表 + 记录「已处理 / 撤销」调用。
class _FakeInboxService extends InboxService {
  _FakeInboxService(this.items);

  final List<InboxItem> items;
  final List<String> handled = [];
  final List<String> unhandled = [];
  int checkCalls = 0;
  bool failNext = false;
  Completer<void>? checkGate;

  @override
  Future<List<InboxItem>> getItems() async => items;

  @override
  Future<InboxCheckResult> checkAll({bool force = false}) async {
    checkCalls++;
    final gate = checkGate;
    if (gate != null) await gate.future;
    if (failNext) {
      failNext = false;
      throw DioException(requestOptions: RequestOptions(path: '/x/inbox'));
    }
    return InboxCheckResult(total: 0, unseen: items.length, items: items);
  }

  @override
  Future<void> markHandled(String bvid) async => handled.add(bvid);

  @override
  Future<void> unmarkHandled(InboxItem item) async => unhandled.add(item.bvid);

  @override
  Future<void> markAllRead() async {}
}

/// 假 B 站接口：`fetchVideoMeta` 立刻返回最小 meta（或按需抛错）。
class _FakeBiliApi extends BiliApi {
  final List<String> metaCalls = [];
  bool failMeta = false;

  @override
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    metaCalls.add(bvid);
    if (failMeta) {
      throw const BiliApiException(code: -404, message: '测试用错误');
    }
    return {
      'bvid': bvid,
      'cid': 1,
      'title': '标题 $bvid',
      'pic': '',
      'duration': 245,
      'owner': {'name': 'UP'},
    };
  }
}

/// 内存版 GitHub（白名单写盘观察点）。
class _FakeGithubApi extends GithubApi {
  _FakeGithubApi({this.configured = true});

  bool configured;
  WhitelistData data = WhitelistData.empty();
  final List<String> savedBvids = [];

  @override
  Future<bool> hasConfig() async => configured;

  @override
  Future<WhitelistData?> fetchFromGist() async => data;

  @override
  Future<bool> saveToGist(WhitelistData wl) async {
    data = wl;
    savedBvids
      ..clear()
      ..addAll(wl.videos.map((v) => v.bvid));
    return true;
  }
}

/// 假同步服务（`WhitelistWriter.addVideo` 落缓存用）。
class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<SyncResult> sync() async => SyncResult(
        data: WhitelistData.empty(),
        sourceName: 'fake',
        fetchedAt: DateTime.now(),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 顶层（队首 = 最新）卡片：Stack 里它排在最后（绘制在最上层）。
Finder _topCard() => find.byType(InboxSwipeCard).last;

/// 下层卡片（下一张）。
Finder _behindCard() => find.byType(InboxSwipeCard).first;

/// 卡片上的浮层标记文字（**只**在卡片内找：底部按钮也有「加入」/「跳过」）。
Finder _badgeText(String label) => find.descendant(
      of: find.byType(InboxSwipeCard),
      matching: find.text(label),
    );

/// 带 [label] 文字的按钮（`*Button.icon` 是私有子类，`find.byType` 匹配不到，
/// 只能按类型谓词找祖先）。
Finder _buttonWithText(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    )
    .first;

/// 固定屏幕为竖屏 411×914（真机常见规格）。
void _usePortraitPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(411, 914);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

InboxItem _item(int i, {int duration = 245, int? pubDate}) => InboxItem(
      upMid: i,
      upName: 'UP$i',
      upFace: '',
      bvid: 'BV$i',
      title: '新视频 $i',
      cover: '',
      duration: duration,
      // 默认 3 小时前（相对时间可断言且不受当天时间影响）
      pubDate: pubDate ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3 * 3600,
    );

class _Harness {
  _Harness({required this.service, required this.api, required this.github});

  final _FakeInboxService service;
  final _FakeBiliApi api;
  final _FakeGithubApi github;
}

/// 起一个信箱页。
///
/// [checkGate] 非空 → `checkAll` 挂在这个闸门上（模拟"一轮检查要跑几分钟"），
/// 用来验「检查期间交互不被阻塞」。
Future<_Harness> _pumpInbox(
  WidgetTester tester,
  List<InboxItem> items, {
  bool githubConfigured = true,
  bool failMeta = false,
  Completer<void>? checkGate,
}) async {
  _usePortraitPhone(tester);
  final service = _FakeInboxService(items);
  if (checkGate != null) service.checkGate = checkGate;
  final api = _FakeBiliApi()..failMeta = failMeta;
  final github = _FakeGithubApi(configured: githubConfigured);
  ServiceLocator.overrideInboxService(service);
  ServiceLocator.overrideSyncService(_FakeSyncService());

  await tester.pumpWidget(MaterialApp(
    home: InboxPage(
      api: api,
      writer: WhitelistWriter(github: github, api: api),
    ),
  ));
  await tester.pumpAndSettle();
  return _Harness(service: service, api: api, github: github);
}

/// 带 [title] 的条目（#3 要构造"顶层 2 行标题 / 下一张 1 行标题"）。
InboxItem _titled(int i, String title) => InboxItem(
      upMid: i,
      upName: 'UP$i',
      upFace: '',
      bvid: 'BV$i',
      title: title,
      cover: '',
      duration: 245,
      pubDate: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3 * 3600,
    );

/// 冲掉一串 `await`（假接口都是立刻完成的 Future）+ 收敛动画。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 取浮层标记「加入」/「跳过」的渐显不透明度。
double _badgeOpacity(WidgetTester tester, String label) {
  final finder = find.ancestor(
    of: _badgeText(label),
    matching: find.byType(Opacity),
  );
  return tester.widget<Opacity>(finder.first).opacity;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MotionControl.reset(); // 测试环境默认 = false（关动效 → 直接跳变）
  });
  tearDown(MotionControl.reset);

  // -------------------------------------------------------------------------
  // 排版
  // -------------------------------------------------------------------------

  group('卡片排版', () {
    testWidgets('封面 / 标题 / 作者 / 时长 / 相对时间都在，宽度 ≈ 屏宽 88%',
        (tester) async {
      final pubDate = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3 * 3600;
      await _pumpInbox(tester, [_item(1, duration: 245, pubDate: pubDate)]);

      expect(find.byType(InboxSwipeCard), findsOneWidget);
      expect(find.text('新视频 1'), findsOneWidget);
      expect(find.text('UP1'), findsOneWidget);
      expect(find.text('4:05'), findsOneWidget, reason: '245s → mm:ss');
      expect(
        find.text(
          fmtRelativeTime(DateTime.fromMillisecondsSinceEpoch(pubDate * 1000)),
        ),
        findsOneWidget,
      );

      // 封面：16:9（未被高度预算压扁）+ 走共享 CoverImage（带防盗链头）
      final cover = tester.widget<CoverImage>(
        find.descendant(
          of: find.byType(InboxSwipeCard),
          matching: find.byType(CoverImage),
        ),
      );
      expect(cover.height, closeTo(cover.width * 9 / 16, 1));
      expect(cover.cover, '');

      // 卡片宽度 ≈ 屏宽 88%（411 × 0.88 ≈ 361.7）
      final size = tester.getSize(find.byType(InboxSwipeCard));
      expect(size.width, closeTo(411 * 0.88, 1));

      // 竖屏 411×914 下整张卡片都在屏内（越界会被下面的断言/溢出报错抓到）
      final rect = tester.getRect(find.byType(InboxSwipeCard));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(914));
    });

    testWidgets('卡片栈：下层卡片底边对齐（缩放 0.96 + 底边下移 12dp）', (tester) async {
      await _pumpInbox(tester, [_item(1), _item(2)]);
      expect(find.byType(InboxSwipeCard), findsNWidgets(2));

      // 变换挂在卡片**外面**（卡片本身是纯展示，不含 Transform）：
      // 下层卡片 = Transform.scale(0.96, alignment: bottomCenter)
      final scaled = tester
          .widgetList<Transform>(find.byType(Transform))
          .where((t) =>
              (t.transform.storage[0] - kInboxStackScale).abs() < 0.001 &&
              (t.transform.storage[5] - kInboxStackScale).abs() < 0.001)
          .toList();
      expect(scaled, isNotEmpty, reason: '下层卡片要缩放 $kInboxStackScale');
      expect(
        scaled.first.alignment,
        Alignment.bottomCenter,
        reason: '缩放锚点必须是底边：居中缩放会让底边上收，把下移量吃掉',
      );

      // 底边对齐：下层底边恒定落在顶层底边之下 kInboxStackOffset（几何断言）
      final top = tester.getRect(_topCard());
      final behind = tester.getRect(_behindCard());
      expect(behind.bottom - top.bottom, closeTo(kInboxStackOffset, 0.6));

      // 语义：下层是「下一张」，顶层是队首（最新）
      expect(tester.widget<InboxSwipeCard>(_behindCard()).item.bvid, 'BV2');
      expect(tester.widget<InboxSwipeCard>(_topCard()).item.bvid, 'BV1');
    });

    testWidgets('#3 下一张更矮（顶层 2 行标题 / 下一张 1 行）也稳定露出它的边',
        (tester) async {
      // 顶层标题够长 → 折成 2 行；下一张只有 3 个字 → 1 行。
      // 旧实现（固定下移 12 + 居中缩放）在这个高度差下会把下一张完全盖住。
      const long = '这是一条很长很长很长很长很长很长很长很长很长很长的标题一二三四五六七八九十';
      await _pumpInbox(tester, [_titled(1, long), _titled(2, '短标题')]);

      final topTitle = tester.getSize(
        find.descendant(of: _topCard(), matching: find.text(long)),
      );
      final behindTitle = tester.getSize(
        find.descendant(of: _behindCard(), matching: find.text('短标题')),
      );
      expect(topTitle.height, greaterThan(behindTitle.height),
          reason: '前提：顶层标题 2 行、下一张 1 行（这正是报出问题的组合）');

      final top = tester.getRect(_topCard());
      final behind = tester.getRect(_behindCard());
      expect(behind.bottom, greaterThan(top.bottom),
          reason: '顶层卡片下沿之下必须看得到下层卡片');
      expect(behind.bottom - top.bottom, closeTo(kInboxStackOffset, 0.6),
          reason: '露出量恒为 kInboxStackOffset，与两张卡片的高度差无关');
      // 下层卡片还要横向窄一点（缩放的可见证据，不只是"多露出一点背景"）
      expect(behind.width, closeTo(top.width * kInboxStackScale, 0.6));
    });
  });

  // -------------------------------------------------------------------------
  // 手势
  // -------------------------------------------------------------------------

  group('滑动手势', () {
    testWidgets('左滑过阈值 → 跳过：记已处理、不动白名单、进入下一张',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      final before = tester.getCenter(_topCard()).dx;

      await tester.drag(_topCard(), Offset(-(before + 200), 0));
      await _flush(tester);

      expect(h.service.handled, ['BV1']);
      expect(h.github.savedBvids, isEmpty, reason: '跳过不写白名单');
      // 换下一张：顶层卡片变成 BV2，且回到屏幕中间
      expect(find.text('新视频 2'), findsOneWidget);
      final cards =
          tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).toList();
      expect(cards.last.item.bvid, 'BV2');
    });

    testWidgets('未过阈值 → 弹回原位：不调任何动作、仍停原卡片', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      final before = tester.getCenter(_topCard());

      await tester.drag(_topCard(), const Offset(80, 0)); // < 411×30%
      await _flush(tester);

      expect(h.service.handled, isEmpty);
      expect(h.api.metaCalls, isEmpty, reason: '拖动不应触发打开播放页');
      expect(h.github.savedBvids, isEmpty);
      final after = tester.getCenter(_topCard());
      expect(after.dx, closeTo(before.dx, 0.5));
      expect(after.dy, closeTo(before.dy, 0.5));
      expect(find.text('新视频 1'), findsOneWidget);
    });

    testWidgets('拖动时浮层「加入」渐显，幅度越大越明显（向右不会显示「跳过」）',
        (tester) async {
      await _pumpInbox(tester, [_item(1), _item(2)]);
      final gesture = await tester.startGesture(tester.getCenter(_topCard()));
      // 第一次移动会被 touch slop 吃掉（DragStartBehavior.start）→ 之后才有 update
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 200));
      final low = _badgeOpacity(tester, '加入');
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 200));
      final high = _badgeOpacity(tester, '加入');

      expect(low, greaterThan(0), reason: '拖起来就要出现「加入」');
      expect(high, greaterThan(low), reason: '幅度越大越明显');
      expect(high, lessThanOrEqualTo(1));
      expect(_badgeText('跳过'), findsNothing);

      // 实心底必须走「已过对比度护栏」的档位
      final box = tester.widget<Container>(
        find.ancestor(of: _badgeText('加入'), matching: find.byType(Container)).first,
      );
      expect((box.decoration as BoxDecoration).color,
          AppPalette.fallback.inkFill);
      expect(tester.widget<Text>(_badgeText('加入')).style?.color,
          AppPalette.fallback.onInk);

      // 总位移 80 < 411×30% → 松手弹回，浮层收掉
      await gesture.up();
      await _flush(tester);
      expect(_badgeText('加入'), findsNothing, reason: '没成一张 → 浮层收掉');
      expect(find.text('新视频 1'), findsOneWidget);
    });

    testWidgets('向左拖显示「跳过」浮层（灰底纸白字，已过护栏）', (tester) async {
      await _pumpInbox(tester, [_item(1), _item(2)]);
      final gesture = await tester.startGesture(tester.getCenter(_topCard()));
      await gesture.moveBy(const Offset(-40, 0)); // 吃 touch slop
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 200));

      expect(_badgeText('跳过'), findsOneWidget);
      expect(_badgeText('加入'), findsNothing);
      final box = tester.widget<Container>(
        find.ancestor(of: _badgeText('跳过'), matching: find.byType(Container)).first,
      );
      expect((box.decoration as BoxDecoration).color, kInkGray70);
      expect(tester.widget<Text>(_badgeText('跳过')).style?.color, kPaper);

      await gesture.up();
      await _flush(tester);
    });
  });

  // -------------------------------------------------------------------------
  // 右滑加入（含飞出动画）
  // -------------------------------------------------------------------------

  group('右滑加入', () {
    testWidgets('过阈值 → 取元数据 + 写白名单 + 飞出 + 进入下一张', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      await tester.drag(_topCard(), const Offset(300, 0));
      await _flush(tester);

      expect(h.api.metaCalls, contains('BV1'));
      expect(h.github.savedBvids, ['BV1'], reason: '右滑 = 加入白名单（未分类）');
      expect(
        h.github.data.videos.single.collection,
        '',
        reason: '默认未分类',
      );
      expect(h.service.handled, ['BV1']);
      final cards =
          tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).toList();
      expect(cards.last.item.bvid, 'BV2', reason: '进入下一张');
    });

    testWidgets('开动效：飞出期间卡片仍在树上且被平移到屏幕外，settle 后出栈',
        (tester) async {
      MotionControl.enabled = true;
      _usePortraitPhone(tester);
      final service = _FakeInboxService([_item(1), _item(2)]);
      final api = _FakeBiliApi();
      final github = _FakeGithubApi();
      ServiceLocator.overrideInboxService(service);
      ServiceLocator.overrideSyncService(_FakeSyncService());
      await tester.pumpWidget(MaterialApp(
        home: InboxPage(
          api: api,
          writer: WhitelistWriter(github: github, api: api),
        ),
      ));
      // 数据到达 + 交错入场跑完（此时屏上无「无限 ticker」组件，才敢 settle）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(InboxSwipeCard), findsNWidgets(2));

      await tester.drag(_topCard(), const Offset(300, 0));
      await tester.pump(); // 门禁通过 → 启动飞出
      await tester.pump(const Duration(milliseconds: 160)); // 飞到一半

      expect(find.byType(InboxSwipeCard), findsNWidgets(2),
          reason: '飞出动画期间卡片还在树上（不是瞬间消失）');
      expect(tester.getTopLeft(_topCard()).dx, greaterThan(200),
          reason: '卡片被平移到屏幕外');

      await tester.pumpAndSettle();
      expect(find.byType(InboxSwipeCard), findsOneWidget);
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).single.item.bvid,
        'BV2',
      );
    });

    testWidgets('关动效：松手即出栈（无中间飞行帧，pumpAndSettle 收敛）',
        (tester) async {
      await _pumpInbox(tester, [_item(1), _item(2)]);
      expect(MotionControl.enabled, isFalse, reason: 'flutter test 默认关动效');

      await tester.drag(_topCard(), const Offset(300, 0));
      await tester.pump(); // 只走一帧：不该有"还在飞"的中间态
      expect(find.byType(InboxSwipeCard), findsOneWidget);
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).single.item.bvid,
        'BV2',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('未配置 GitHub → 门禁提示 + 弹回（不写白名单、不记已处理）',
        (tester) async {
      final h = await _pumpInbox(
        tester,
        [_item(1), _item(2)],
        githubConfigured: false,
      );
      final before = tester.getCenter(_topCard()).dx;

      await tester.drag(_topCard(), const Offset(300, 0));
      await _flush(tester);

      expect(
        find.text('请先到底部导航「个人」页配置 GitHub token 与 Gist ID'),
        findsOneWidget,
      );
      expect(h.github.savedBvids, isEmpty);
      expect(h.service.handled, isEmpty);
      expect(tester.getCenter(_topCard()).dx, closeTo(before, 0.5));
    });
  });

  // -------------------------------------------------------------------------
  // 底部按钮 / 撤销 / 空态
  // -------------------------------------------------------------------------

  group('底部按钮与撤销', () {
    testWidgets('「跳过」与「加入」与滑动等价（≥48dp）', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2), _item(3)]);

      expect(tester.getSize(_buttonWithText('跳过')).height,
          greaterThanOrEqualTo(48));
      expect(tester.getSize(_buttonWithText('加入')).height,
          greaterThanOrEqualTo(48));

      await tester.tap(find.text('跳过'));
      await _flush(tester);
      expect(h.service.handled, ['BV1']);
      expect(h.github.savedBvids, isEmpty);
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).last.item.bvid,
        'BV2',
      );

      await tester.tap(find.text('加入'));
      await _flush(tester);
      expect(h.api.metaCalls, contains('BV2'));
      expect(h.github.savedBvids, ['BV2']);
      expect(h.service.handled, ['BV1', 'BV2']);
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).last.item.bvid,
        'BV3',
      );
    });

    testWidgets('「撤销」把上一张放回来 + 撤销「已处理」记录', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      // 初始没有可撤销的 → 按钮禁用
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
            .onPressed,
        isNull,
      );

      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);
      expect(h.service.handled, ['BV1']);
      expect(find.text('新视频 1'), findsNothing);

      await tester.tap(find.byTooltip('撤销'));
      await _flush(tester);

      expect(h.service.unhandled, ['BV1']);
      expect(find.text('新视频 1'), findsOneWidget, reason: '卡片回到栈顶');
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).last.item.bvid,
        'BV1',
      );
    });

    testWidgets('全部处理完 → 空态 AppStateView(copyId: empty.inbox)', (tester) async {
      await _pumpInbox(tester, [_item(1)]);
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);

      expect(find.byType(InboxSwipeCard), findsNothing);
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.kind, AppStateKind.empty);
      expect(state.copyId, 'empty.inbox');
      expect(state.scrollable, isTrue, reason: '宿主是 RefreshIndicator → 必须可滚动');
    });

    testWidgets('#2 空态仍保留撤销入口：划掉最后一张后能撤回来', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      // 划掉两张 → 空队列（旧实现底部栏整体消失，撤销入口没了）
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);

      expect(find.byType(InboxSwipeCard), findsNothing);
      expect(
        tester.widget<AppStateView>(find.byType(AppStateView)).copyId,
        'empty.inbox',
      );

      // 空态里仍有「撤销上一张」，且 ≥48dp 可点
      final undo = _buttonWithText('撤销上一张');
      expect(undo, findsOneWidget, reason: '空态必须保留撤销入口');
      expect(tester.getSize(undo).height, greaterThanOrEqualTo(48));
      expect(
        tester.widget<OutlinedButton>(undo).onPressed,
        isNotNull,
        reason: '刚划掉的那张可撤销 → 按钮必须可用',
      );
      // 「跳过 / 加入」没有卡片可作用 → 空态下不出现
      expect(find.text('跳过'), findsNothing);
      expect(find.text('加入'), findsNothing);

      await tester.tap(undo);
      await _flush(tester);

      expect(h.service.unhandled, ['BV2'], reason: '撤销要把「已处理」记录也去掉');
      expect(find.text('新视频 2'), findsOneWidget, reason: '卡片回到栈顶');
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).single.item.bvid,
        'BV2',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 既有能力 + 点按
  // -------------------------------------------------------------------------

  group('既有能力不丢', () {
    testWidgets('点按卡片 → 走「打开播放页」链路（fetch view 元数据）',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)], failMeta: true);

      await tester.tap(_topCard());
      await _flush(tester);

      expect(h.api.metaCalls, ['BV1']);
      // 取元数据失败 → 与旧版一致的错误提示（导航未发生）
      expect(find.text('获取视频信息失败：测试用错误'), findsOneWidget);
      expect(find.text('新视频 1'), findsOneWidget, reason: '卡片不动');
    });

    testWidgets('卡片栈上仍能下拉刷新（force=true 重检）', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      expect(h.service.checkCalls, 1);

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.service.checkCalls, 2, reason: '卡片栈不是列表，但下拉刷新必须还在');
      await _flush(tester);
    });

    testWidgets('首屏加载 = AppLoadingHero(seed: inbox)，加载态仍能下拉刷新',
        (tester) async {
      _usePortraitPhone(tester);
      final service = _FakeInboxService(const []);
      service.checkGate = Completer<void>();
      ServiceLocator.overrideInboxService(service);
      ServiceLocator.overrideSyncService(_FakeSyncService());

      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pump();
      final hero = tester.widget<AppLoadingHero>(find.byType(AppLoadingHero));
      expect(hero.seed, 'inbox');
      expect(hero.scrollable, isTrue, reason: '宿主是 RefreshIndicator → 必须可滚动');

      // 加载态下仍能下拉刷新
      expect(service.checkCalls, 1);
      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(service.checkCalls, 2);

      service.checkGate!.complete();
      await tester.pumpAndSettle();
      // 没有未读 → 空态（锚点不变）
      expect(
        tester.widget<AppStateView>(find.byType(AppStateView)).copyId,
        'empty.inbox',
      );
    });

    testWidgets('#6 队列被用户划空（后台检查还在跑）→ 空态，不是整页加载态',
        (tester) async {
      _usePortraitPhone(tester);
      final service = _FakeInboxService([_item(1)]);
      ServiceLocator.overrideInboxService(service);
      ServiceLocator.overrideSyncService(_FakeSyncService());

      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();
      expect(find.byType(InboxSwipeCard), findsOneWidget);

      // 之后的检查挂起（模拟"这一轮又要跑几分钟"）
      service.checkGate = Completer<void>();
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(service.checkCalls, 2);
      expect(find.text('检查中…'), findsOneWidget,
          reason: '后台任务只在顶栏给一行提示');

      // 划掉最后一张。注意检查还没回来 → 不能用 pumpAndSettle
      //（RefreshIndicator 还在转，无限动画收敛不了）
      await tester.drag(_topCard(), const Offset(-300, 0));
      await tester.pump();
      await tester.pump();

      // 用户"划完了" → 直接空态；不能显示"正在加载…"那种整页等待
      expect(find.byType(AppLoadingHero), findsNothing,
          reason: '队列是被用户划空的，不是还没加载出来');
      expect(
        tester.widget<AppStateView>(find.byType(AppStateView)).copyId,
        'empty.inbox',
      );
      expect(_buttonWithText('撤销上一张'), findsOneWidget);

      // 检查回来也不把这张复活（它在本次会话里已被消费）
      service.checkGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(InboxSwipeCard), findsNothing);
      expect(find.byType(AppStateView), findsOneWidget);
    });

    testWidgets('刷新整体失败且列表为空 → AppErrorView + 重试可恢复', (tester) async {
      _usePortraitPhone(tester);
      final service = _FakeInboxService(const [])..failNext = true;
      ServiceLocator.overrideInboxService(service);
      ServiceLocator.overrideSyncService(_FakeSyncService());

      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      final before = service.checkCalls;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(service.checkCalls, before + 1);
      expect(find.byType(AppErrorView), findsNothing);
    });

    testWidgets('刷新失败时保留已有卡片栈（不把画面打空）', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      h.service.failNext = true;

      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _flush(tester);

      expect(find.byType(InboxSwipeCard), findsNWidgets(2),
          reason: '检查失败不能把已经读到的卡片清掉');
      expect(find.byType(AppErrorView), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // 后台检查不阻塞交互（#1）
  // -------------------------------------------------------------------------

  group('后台 checkAll 进行中：交互不阻塞', () {
    testWidgets('#1 检查期间点卡 / 划卡 / 撤销都能用；检查回来不重置卡片栈',
        (tester) async {
      final gate = Completer<void>();
      final h = await _pumpInbox(
        tester,
        [_item(1), _item(2), _item(3)],
        checkGate: gate,
        // 只验"点按链路被触发"：真 push 播放页要 mock 播放器通道
        failMeta: true,
      );

      // 顶部只有一行提示，**不**禁用任何操作
      expect(find.text('检查中…'), findsOneWidget);

      // ① 点卡仍能走「打开播放页」链路（旧实现静默 return，点了完全没反应）
      await tester.tap(_topCard());
      await _flush(tester);
      expect(h.api.metaCalls, ['BV1']);

      // ② 底部「跳过 / 加入」没有变灰
      expect(
        tester.widget<OutlinedButton>(_buttonWithText('跳过')).onPressed,
        isNotNull,
        reason: '检查期间按钮必须可用',
      );
      expect(
        tester.widget<FilledButton>(_buttonWithText('加入')).onPressed,
        isNotNull,
        reason: '检查期间按钮必须可用',
      );

      // ③ 划卡仍生效
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);
      expect(h.service.handled, ['BV1']);

      // ④ 撤销仍能用
      await tester.tap(find.byTooltip('撤销'));
      await _flush(tester);
      expect(h.service.unhandled, ['BV1']);
      expect(find.text('新视频 1'), findsOneWidget, reason: '卡片回到栈顶');

      // 再划走两张 → 当前这张变成第 3 张
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);
      expect(tester.widget<InboxSwipeCard>(_topCard()).item.bvid, 'BV3');

      // ⑤ 检查回来（闸门放开）：只把新条目追加到队尾，
      //    当前这张不动、已消费的不复活
      gate.complete();
      await _flush(tester);

      expect(find.text('检查中…'), findsNothing);
      expect(
        tester.widget<InboxSwipeCard>(_topCard()).item.bvid,
        'BV3',
        reason: '卡片栈不能重置回第一张',
      );
      expect(find.byType(InboxSwipeCard), findsOneWidget);
      expect(find.text('新视频 1'), findsNothing, reason: '已消费的条目不复活');
      expect(find.text('新视频 2'), findsNothing, reason: '已消费的条目不复活');
      expect(
        h.service.handled,
        ['BV1', 'BV1', 'BV2'],
        reason: '划走 BV1 → 撤销 → 再划走 BV1 → 划走 BV2（替身只记调用）',
      );
    });
  });
}
