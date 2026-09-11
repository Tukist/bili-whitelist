// 信箱页 Tinder 式卡片栈的 widget 测试（v2.19.0+）：
// - 卡片排版：封面 / 标题 / 作者（头像 + 名字）/ 时长 / 相对时间；
//   卡片 = **扑克牌比例**（1:1.39）、宽度 ≈ 屏宽 88%，竖屏 411×914 下不出屏；
//   默认版式 classic = 全出血氛围（16:9 的封面完整居中 + 同图模糊底衬铺满整卡）
//   ——版式细节见 `test/inbox_card_style_test.dart`（每个风格各有一条渲染用例）
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
// - 检查**进行中**的新条目也会进卡片栈：页面每隔几秒只读盘回读一次本地未读
//   （见 inbox_page.dart 的 _pollProgress），不必退出重进（#2）
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
import 'package:bili_whitelist_app/widgets/inbox_card_stack.dart';
import 'package:bili_whitelist_app/widgets/inbox_card_styles.dart';
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

/// 按 bvid 找那张卡。
///
/// 卡片栈是多层的（v2.22.0+），「第几张」不再能靠位置猜 —— 用数据身份定位。
Finder _cardByBvid(String bvid) => find.byWidgetPredicate(
      (w) => w is InboxSwipeCard && w.item.bvid == bvid,
    );

/// 某层卡片的**降调不透明度**：从卡片往上找最近的那层 `Opacity`
///（卡片栈给每层铺的深度变换，见 `inbox_card_stack.dart` 的 `_depthLayer`）。
double _layerAlpha(WidgetTester tester, String bvid) {
  final el = _cardByBvid(bvid).evaluate().single;
  Opacity? found;
  el.visitAncestorElements((a) {
    if (a.widget is Opacity) {
      found = a.widget as Opacity;
      return false;
    }
    return true;
  });
  return found!.opacity;
}

/// 起一个**开着动效**的信箱页：飞出/推进/弹回都是真在跑（用于验证动画过程）。
Future<_Harness> _pumpInboxAnimated(
  WidgetTester tester,
  List<InboxItem> items,
) async {
  MotionControl.enabled = true;
  _usePortraitPhone(tester);
  final service = _FakeInboxService(items);
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
  // 数据到达 + 交错入场跑完（此后屏上没有无限 ticker，才敢继续按帧 pump）
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return _Harness(service: service, api: api, github: github);
}

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

      // 封面：**完整显示的那张**走共享 CoverImage（带防盗链头）——老实现拿它
      // 铺满 1:1.39 的整卡（`BoxFit.cover` 按高撑满 → 左右各裁 20%+，图上的
      // 标题被切断）；现在给它的是 16:9 的盒子 → cover == contain，左右不裁
      final cover = tester.widget<CoverImage>(
        find.descendant(
          of: find.byKey(kInboxCardCoverKey),
          matching: find.byType(CoverImage),
        ),
      );
      expect(cover.cover, '');
      expect(cover.width / cover.height, closeTo(kInboxCoverAspect, 0.01));
      expect(cover.width, closeTo(411 * 0.88 - 2, 1),
          reason: '封面按卡宽铺开（卡面 1px 描边吃掉 2dp）');

      // 卡片 = 扑克牌比例（宽 : 高 = 1 : kInboxCardAspect = 1 : 1.39）
      final size = tester.getSize(find.byType(InboxSwipeCard));
      expect(size.width, closeTo(411 * 0.88, 1));
      expect(size.height, closeTo(size.width * kInboxCardAspect, 1));
      // classic 的「全出血」由同一张图的模糊底衬保住（铺满整卡）；
      // 图本身完整居中（高度小于整卡 → 没有被拉高裁切）
      expect(
        tester.getSize(find.byType(ImageFiltered)).height,
        closeTo(size.height - 2, 1),
        reason: 'classic：模糊底衬铺满整卡（1px 描边吃掉 2dp）',
      );
      expect(
        tester.getSize(find.byKey(kInboxCardCoverKey)).height,
        lessThan(size.height - 2),
        reason: 'classic：16:9 的图完整显示，不是被拉高裁掉',
      );

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
  // 卡片栈：一叠牌 + 向前推进（v2.22.0+）
  // -------------------------------------------------------------------------

  group('卡片栈：一叠牌', () {
    testWidgets('静止时同时叠 4 张，深度越大越小/越低/越淡（几何断言）',
        (tester) async {
      // 队列给长一点（30 条）：证明**只渲染前 4 张**，不为整条队列建 widget
      await _pumpInbox(tester, [for (var i = 1; i <= 30; i++) _item(i)]);

      expect(find.byType(InboxSwipeCard), findsNWidgets(4));
      expect(_cardByBvid('BV5'), findsNothing, reason: '第 5 张不进 widget 树');
      expect(_cardByBvid('BV30'), findsNothing);

      const cardW = 411 * 0.88;
      const scales = [1.0, kInboxStackScale, 0.92, 0.88];
      const drops = [0.0, kInboxStackOffset, 20.0, 28.0];
      final rects = <Rect>[
        for (var d = 0; d < 4; d++) tester.getRect(_cardByBvid('BV${d + 1}')),
      ];
      final top = rects.first;

      // 每层的缩放/下移都按表落位（不是目测，是几何）
      for (var d = 0; d < 4; d++) {
        expect(rects[d].width, closeTo(cardW * scales[d], 0.6),
            reason: '深度 $d 的缩放');
        expect(rects[d].bottom - top.bottom, closeTo(drops[d], 0.6),
            reason: '深度 $d 的底边露出量（底边对齐语义）');
      }
      // 递进：一眼是「一叠」，不是「一张 + 一条边」
      for (var d = 1; d < 4; d++) {
        expect(rects[d].width, lessThan(rects[d - 1].width - 4));
        expect(rects[d].bottom, greaterThan(rects[d - 1].bottom + 4));
        expect(rects[d].bottom, greaterThan(top.bottom),
            reason: '后层底边稳定可见（与卡片内容高度无关）');
      }
      // 很轻的降调：下一张（深度 1）仍是满不透明，深两档起才压一点
      expect(_layerAlpha(tester, 'BV2'), 1.0);
      expect(_layerAlpha(tester, 'BV3'), closeTo(0.94, 0.001));
      expect(_layerAlpha(tester, 'BV4'), closeTo(0.88, 0.001));
    });

    testWidgets('拖动时后层不动，且后层的 widget 实例一帧都不重建', (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 5; i++) _item(i)]);

      final topRest = tester.getTopLeft(_cardByBvid('BV1'));
      final before = <Rect>[
        for (var d = 2; d <= 4; d++) tester.getRect(_cardByBvid('BV$d')),
      ];
      final beforeWidgets = <InboxSwipeCard>[
        for (var d = 2; d <= 4; d++)
          tester.widget<InboxSwipeCard>(_cardByBvid('BV$d')),
      ];

      final gesture = await tester.startGesture(tester.getCenter(_topCard()));
      await gesture.moveBy(const Offset(60, 0)); // 第一次移动被 touch slop 吃掉
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();

      // 顶层跟手走了（拖动幅度没过阈值 → 松手会弹回，不影响本用例断言）
      expect(tester.getTopLeft(_cardByBvid('BV1')).dx,
          greaterThan(topRest.dx + 20));

      // 后层：位置/尺寸/实例都没变 —— 「跟手只在顶层」
      for (var d = 2; d <= 4; d++) {
        final now = tester.getRect(_cardByBvid('BV$d'));
        expect(now.left, closeTo(before[d - 2].left, 0.01));
        expect(now.top, closeTo(before[d - 2].top, 0.01));
        expect(now.width, closeTo(before[d - 2].width, 0.01));
        expect(now.bottom, closeTo(before[d - 2].bottom, 0.01));
        expect(
          identical(
            tester.widget<InboxSwipeCard>(_cardByBvid('BV$d')),
            beforeWidgets[d - 2],
          ),
          isTrue,
          reason: '拖动期间后层的版式子树不该被逐帧重建（widget 实例原样交回）',
        );
      }

      await gesture.up();
      await _flush(tester);
      // 弹回原位（既有行为不受影响）
      expect(tester.getTopLeft(_cardByBvid('BV1')).dx, closeTo(topRest.dx, 0.5));
    });

    testWidgets('关动效：栈内不建 controller（没有逐帧驱动者），出栈瞬时到位',
        (tester) async {
      await _pumpInbox(tester, [_item(1), _item(2), _item(3)]);
      expect(MotionControl.enabled, isFalse, reason: 'flutter test 默认关动效');

      // 栈内没有任何 AnimatedBuilder → 没有以 controller 驱动的逐帧层
      expect(
        find.descendant(
          of: find.byType(InboxCardStack),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );

      final topRest = tester.getRect(_cardByBvid('BV1'));
      await tester.drag(_topCard(), const Offset(300, 0));
      await tester.pump(); // 只走一帧：没有「还在推」的中间态
      expect(find.byType(InboxSwipeCard), findsNWidgets(2),
          reason: '关动效时不预留"多渲染一张"的窗口');
      final nowTop = tester.getRect(_cardByBvid('BV2'));
      expect(nowTop.topLeft.dx, closeTo(topRest.topLeft.dx, 0.6));
      expect(nowTop.topLeft.dy, closeTo(topRest.topLeft.dy, 0.6));
      await tester.pumpAndSettle();
    });
  });

  group('卡片栈：向前推进', () {
    testWidgets('滑走顶层 → 第二张平滑长大上移（中途态 + 层次感 + 补卡不突兀）',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 6; i++) _item(i)]);

      final cardW = tester.getRect(_cardByBvid('BV1')).width;
      final topRest = tester.getRect(_cardByBvid('BV1'));
      final secondRest = tester.getRect(_cardByBvid('BV2'));
      final thirdRest = tester.getRect(_cardByBvid('BV3'));
      expect(secondRest.width, closeTo(cardW * kInboxStackScale, 0.6));
      expect(thirdRest.width, closeTo(cardW * 0.92, 0.6));
      expect(_cardByBvid('BV5'), findsNothing, reason: '静止时只渲染 4 张');

      await tester.drag(_topCard(), const Offset(300, 0)); // 右滑过阈值 → 提交
      await tester.pump(); // 门禁通过 → 飞出与推进一起启动

      // 逐帧采样（20ms 一帧，覆盖推进前半程）：推进必须是"从旧深度走到新深度"，
      // 不是跳变。★ 几何一律用 getRect：getSize 不套祖先的 Transform，量不出缩放。
      final second = <double>[];
      final third = <double>[];
      final incoming = <double>[];
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        second.add(tester.getRect(_cardByBvid('BV2')).width);
        third.add(tester.getRect(_cardByBvid('BV3')).width);
        final f = _cardByBvid('BV5');
        incoming.add(f.evaluate().isEmpty ? -1 : _layerAlpha(tester, 'BV5'));
      }

      // ① 平滑推进：逐帧单调增长（不回跳），且**中途确实停在两层之间**
      for (var i = 1; i < second.length; i++) {
        expect(second[i], greaterThanOrEqualTo(second[i - 1] - 0.001),
            reason: '推进只能向前，不会回跳');
      }
      expect(
        second.where((w) => w > secondRest.width + 0.5 && w < cardW - 0.5),
        isNotEmpty,
        reason: '要有"介于原深度与新深度之间"的中间态（跳变就不可能有）',
      );

      // ② 层次感：不同深度错峰推进（前排先走、后排末尾追上来）
      var layered = false;
      for (var i = 0; i < second.length; i++) {
        final p2 =
            (second[i] - secondRest.width) / (cardW - secondRest.width);
        final p3 = (third[i] - thirdRest.width) /
            (secondRest.width - thirdRest.width);
        expect(p2, greaterThanOrEqualTo(p3 - 0.001),
            reason: '前排只能更快，不能反超（否则深层的牌会从前面那张里冒出来）');
        if (p2 - p3 > 0.005) layered = true;
      }
      expect(layered, isTrue, reason: '不同深度要有不同的推进节奏');

      // ③ 补卡：栈底补上第 5 张，从全透明浮现 → 分层落位，不突兀
      expect(incoming.contains(-1), isFalse,
          reason: '推进期间要多带一张（第 5 张）');
      expect(incoming.first, lessThan(0.3), reason: '它从更深处（不透明度 0）浮现');
      expect(
        incoming.where((a) => a > 0.05 && a < 0.85),
        isNotEmpty,
        reason: '淡入过程中要有中间态',
      );

      await tester.pumpAndSettle(); // 顶层飞出屏幕 → 出栈

      // ④ 收尾：原第二张长成顶层大小，并落在顶层原来的位置上
      final nowTop = tester.getRect(_cardByBvid('BV2'));
      expect(nowTop.width, closeTo(cardW, 0.6));
      expect(nowTop.topLeft.dx, closeTo(topRest.topLeft.dx, 0.6));
      expect(nowTop.topLeft.dy, closeTo(topRest.topLeft.dy, 0.6));
      expect(nowTop.bottom, closeTo(topRest.bottom, 0.6));

      // ⑤ 数量不减少：滑走一张又补一张，栈内仍是 4 张
      expect(find.byType(InboxSwipeCard), findsNWidgets(4));
      expect(_cardByBvid('BV1'), findsNothing);
      expect(_cardByBvid('BV5'), findsOneWidget);
      expect(_layerAlpha(tester, 'BV5'), closeTo(0.88, 0.001),
          reason: '到位后它就是深度 3 的那一层');
      expect(
        tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).last.item.bvid,
        'BV2',
        reason: '推进到位后顶层就是原第二张',
      );
    });

    test('推进时长必须 ≤ 飞出时长（出栈与推进无缝续上的前提）', () {
      expect(
        kDurAdvance.inMilliseconds,
        lessThanOrEqualTo(kDurSlow.inMilliseconds),
        reason: '出栈早于推进到位会把没走完的层硬拽到位（跳变）',
      );
    });

    testWidgets('撤销：反着播推进（放回的从屏外飞回来 + 后层退回），无跳变',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 5; i++) _item(i)]);

      final cardW = tester.getRect(_cardByBvid('BV1')).width;
      final topRest = tester.getRect(_cardByBvid('BV1'));
      final secondRest = tester.getRect(_cardByBvid('BV2'));

      // 划走一张：飞出 + 推进（原第二张长成顶层大小）
      await tester.drag(_topCard(), const Offset(300, 0));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.getRect(_cardByBvid('BV2')).width, closeTo(cardW, 0.6));
      expect(_cardByBvid('BV1'), findsNothing);

      // 撤销 → 反向播同一条推进
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();

      final flying = <double>[];
      final second = <double>[];
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        flying.add(tester.getRect(_cardByBvid('BV1')).left);
        second.add(tester.getRect(_cardByBvid('BV2')).width);
      }

      // ① 放回来的那张从屏外飞回来（不是「啪」地出现在原位），且一路往回走
      expect(flying.first, greaterThan(topRest.left + 200));
      for (var i = 1; i < flying.length; i++) {
        expect(flying[i], lessThanOrEqualTo(flying[i - 1] + 0.001));
      }
      // ② 后层正在退回：起点在「推进到位」那一侧，中途有"介于两者之间"的态
      expect(second.first, greaterThan(secondRest.width + 0.5),
          reason: '退回的起点就是"已经推进到位"的位置');
      expect(
        second.where((w) => w > secondRest.width + 0.5 && w < cardW - 0.5),
        isNotEmpty,
        reason: '退回是"从到位处走回原位"，不是跳变',
      );

      await tester.pumpAndSettle();
      // ③ 全部复原：顶层回到原位，后层回到原深度
      final backTop = tester.getRect(_cardByBvid('BV1'));
      expect(backTop.topLeft.dx, closeTo(topRest.topLeft.dx, 0.6));
      expect(backTop.topLeft.dy, closeTo(topRest.topLeft.dy, 0.6));
      final backSecond = tester.getRect(_cardByBvid('BV2'));
      expect(backSecond.width, closeTo(secondRest.width, 0.6));
      expect(backSecond.bottom, closeTo(secondRest.bottom, 0.6));
      // 静止窗口仍是 4 张（多渲染的那张在退回结束后收掉）
      expect(find.byType(InboxSwipeCard), findsNWidgets(4));
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

    testWidgets('#2 检查进行中：新入队的条目能进卡片栈（不必退出重进）',
        (tester) async {
      final gate = Completer<void>();
      // 可变队列：模拟服务层"边查边落盘"之后本地未读变多了
      final items = <InboxItem>[_item(1)];
      final h = await _pumpInbox(tester, items, checkGate: gate);
      expect(_cardByBvid('BV1'), findsOneWidget);
      expect(find.text('检查中…'), findsOneWidget);

      // 检查还在跑：服务层又落盘了一条（页面此刻还不知道）
      items.add(_item(2));
      expect(_cardByBvid('BV2'), findsNothing, reason: '回读间隔还没到');

      // 页面在检查期间周期性回读本地未读（只读盘、不触网；间隔同
      // inbox_page.dart 的 _kProgressPoll = 3s）→ 新卡自动追加进来
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);
      expect(_cardByBvid('BV2'), findsOneWidget,
          reason: '检查进行中的新条目必须能进卡片栈 —— 老实现要等整轮跑完');
      expect(tester.widget<InboxSwipeCard>(_topCard()).item.bvid, 'BV1',
          reason: '只追加不重排：当前正在看的那张不能换人');

      // 检查回来：不重复追加（还是那 2 张），提示收掉
      gate.complete();
      await _flush(tester);
      expect(find.byType(InboxSwipeCard), findsNWidgets(2));
      expect(find.text('检查中…'), findsNothing);
      expect(h.service.checkCalls, 1);
    });
  });
}
