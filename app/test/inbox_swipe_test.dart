// 信箱页 Tinder 式卡片栈的 widget 测试（v2.19.0+）：
// - 卡片排版：封面 / 标题 / 作者（头像 + 名字）/ 时长 / 相对时间；
//   卡片 = **扑克牌比例**（1:1.39）、宽度 ≈ 屏宽 88%，竖屏 411×914 下不出屏；
//   默认版式 classic = 全出血氛围（16:9 的封面完整居中 + 同图模糊底衬铺满整卡）
//   ——版式细节见 `test/inbox_card_style_test.dart`（每个风格各有一条渲染用例）
// - 卡片栈：下层**底边对齐**（底边恒定露出 kInboxStackOffset + 缩放 kInboxStackScale
//   以底边为锚）→ 不论下一张标题 1 行还是 2 行，顶层下方都稳定可见它的边（#3）
// - 手势：右滑过阈值 = 加入（写白名单）、左滑过阈值 = 跳过（只记已处理）、
//   下滑 = 稍后（推到队尾、**不做判断**，之后还能再看到）、
//   上滑 = 取回（把最近推后的那张拿回栈顶，LIFO）、
//   未过阈值 = 弹回且不调任何动作
// - 浮层标记：四个词各一个（加入 / 跳过 / 稍后 / 取回）随手势渐显，颜色走
//   `palette.inkFill` / `kInkGray70` / `palette.accentWash` / `palette.accentFill`
//   （都是已过对比度护栏的档位）
// - 底部按钮「跳过」/「加入」与滑动等价；「撤销」把上一张放回来；
//   空态下底部仍留着「撤销上一张」（#2）
// - 后台 checkAll 进行中不阻塞交互：仍能点卡开播放页 / 划卡 / 撤销，
//   检查回来只增不改（新条目按发布时间落位）→ 卡片栈不跳回第一张、
//   已消费的不复活（#1）
// - 检查**进行中**的新条目也会进卡片栈：页面每隔几秒只读盘回读一次本地未读
//   （见 inbox_page.dart 的 _pollProgress），不必退出重进（#2）
// - ★ 上下交替**不循环**（v2.49.1）：一张卡每次「稍后」只欠**一次**取回（票），
//   交替多少轮都是"下滑→上滑→回到原样"，票用完即空；「稍后」的那张在**落地前**
//   没有票 → 飞行窗口里取不到它、也不会取错卡；票空了再上滑只给一条可见反馈
//   （不再静默）。断言落在状态上（队列 / 票栈 / 取回次数），见 `_inboxState`
// - ★ 回读合并**按发布时间落位**（v2.49.1）：新抓到的条目插到该在的位置（绝不
//   插到当前这张之前 → 正在看的那张不换人），且**不把正在飞的那张并回来**
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
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';
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

/// 会「慢」的 GitHub 替身：每次读写都耗 [delay]，并统计**同一时刻在飞的请求数**。
///
/// 用来验证「连续两张右滑 → Gist 写被串行化」：[WhitelistWriter.addVideo] 是
/// "GET 整份 → 查重 → PATCH 整份"的 read-modify-write，两次并发会各自基于同一份
/// 旧快照写，后一次覆盖前一次（丢一条视频，而且全程没有任何报错）。
class _SerialGithubApi extends GithubApi {
  _SerialGithubApi({this.delay = Duration.zero});

  final Duration delay;
  WhitelistData data = WhitelistData.empty();

  int _inFlight = 0;

  /// 观测到的**并发峰值**（串行化之后必须恒为 1）。
  int maxInFlight = 0;

  Future<T> _track<T>(Future<T> Function() body) async {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return await body();
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() => _track(() async => data);

  @override
  Future<bool> saveToGist(WhitelistData wl) => _track(() async {
        data = wl;
        return true;
      });
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
///
/// [checkGate] 非空 → `checkAll` 挂在闸门上（"检查还在跑"），这时 [InboxPage] 的
/// 3s 回读定时器（`_kProgressPoll`）才会真的回读一次 —— 要验"回读与飞行窗口重叠"
/// 的用例必须传它。
Future<_Harness> _pumpInboxAnimated(
  WidgetTester tester,
  List<InboxItem> items, {
  bool githubConfigured = true,
  Completer<void>? checkGate,
}) async {
  MotionControl.enabled = true;
  _usePortraitPhone(tester);
  final service = _FakeInboxService(items);
  if (checkGate != null) service.checkGate = checkGate;
  final api = _FakeBiliApi();
  final github = _FakeGithubApi(configured: githubConfigured);
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

/// 从卡片**外面**（卡片区上方的留白）往下甩一次 → 下拉刷新。
///
/// v2.32.0+ 起卡片自己吃掉了上下拖（那是判定手势），下拉刷新只能从卡片外的
/// 留白发起。旧用例原来直接甩 `CustomScrollView` 的中心，而卡片正好是居中的
/// → 那个起点现在落在卡片上，会被判成「下滑 = 稍后」。
Future<void> _flingDeckForRefresh(WidgetTester tester) async {
  final top = tester.getTopLeft(find.byType(CustomScrollView));
  await tester.flingFrom(
    top + const Offset(200, 20),
    const Offset(0, 300),
    1000,
  );
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

/// [hours] 小时前的 Unix 秒（构造"发布时间有序"的队列用）。
int _agoHours(int hours) =>
    DateTime.now().millisecondsSinceEpoch ~/ 1000 - hours * 3600;

/// 页面 State —— 观察口见 `inbox_page.dart` 末尾的「测试观察口」一节
/// （队列内容 / 待取回票栈 / 幽灵层里飞的那张 / 取回次数）。
///
/// 为什么必须直接读它：这批修的是"同一张卡被反复取回"这种**状态机不变式**，
/// 只靠动画位置与文案间接推断，正是这个缺陷当初逃过全套测试的原因。
InboxPageState _inboxState(WidgetTester tester) =>
    tester.state<InboxPageState>(find.byType(InboxPage));

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

/// 卡片栈里**从上到下的队列顺序**（顶层在前，bvid 列表）。
///
/// 卡片栈的 children 顺序是「深 → 浅」、顶层卡片排在最后（见
/// `inbox_card_stack.dart` 的 build）→ 倒过来就是队列顺序。用它来断言
/// 「谁被推到了后面 / 谁回到了栈顶」比只看顶层那一张硬得多。
List<String> _deckOrder(WidgetTester tester) {
  final cards =
      tester.widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard)).toList();
  return [for (final c in cards.reversed) c.item.bvid];
}

/// 顶层卡片的 bvid。
String _topBvid(WidgetTester tester) =>
    tester.widget<InboxSwipeCard>(_topCard()).item.bvid;

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
  // 上下滑（v2.32.1 订正语义）：下滑 = 稍后（推到队尾、不判断）、上滑 = 取回
  // 用户原话：「下滑不是跳过，而是暂时不判断，先看后面的卡片，可以上滑回来」
  // -------------------------------------------------------------------------

  group('上下滑手势（四向 = 四件事）', () {
    /// 划 [offset] → 返回**飞出途中**顶层卡片（相对它静止位）的位移。
    ///
    /// ⚠️ 调用方要自己先把页面 pump 起来，而且**一个测试里只 pump 一次**：
    /// `pumpWidget` 交回去的是同类型、同 key 的 `InboxPage` → Flutter 会复用
    /// 原来的 State（队列与撤销位都不会重置），再 pump 一次得到的不是"新的一页"。
    /// 要验多个方向就在同一页上连着划：每划一次下一张顶上来，静止位不变。
    Future<Offset> exitShift(WidgetTester tester, Offset offset) async {
      final rest = tester.getCenter(_topCard());
      final count = find.byType(InboxSwipeCard).evaluate().length;
      await tester.drag(_topCard(), offset);
      await tester.pump(); // 门禁通过 → 启动飞出
      await tester.pump(const Duration(milliseconds: 160)); // 飞到一半
      expect(find.byType(InboxSwipeCard).evaluate().length, count,
          reason: '飞出动画期间卡片还在树上（不是瞬间消失）');
      final mid = tester.getCenter(_topCard());
      await tester.pumpAndSettle();
      return mid - rest;
    }

    testWidgets('下滑过阈值 → 稍后：不记「已处理」、不写 Gist、不取元数据，队首换下一张',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2), _item(3)]);
      final before = tester.getCenter(_topCard());

      await tester.drag(_topCard(), const Offset(0, 300)); // 下滑
      await _flush(tester);

      expect(_topBvid(tester), 'BV2', reason: '队首换成下一张（用户"先看后面的卡片"）');
      expect(h.service.handled, isEmpty, reason: '稍后**不是跳过**：绝不能记「已处理」');
      expect(h.service.unhandled, isEmpty);
      expect(h.github.savedBvids, isEmpty, reason: '稍后不写白名单');
      expect(h.api.metaCalls, isEmpty, reason: '稍后不取元数据');
      expect(_cardByBvid('BV1'), findsOneWidget,
          reason: '推后的那张还在牌堆里 → 之后还能再看到');
      expect(_deckOrder(tester), ['BV2', 'BV3', 'BV1'], reason: '队列转了一位：BV1 到队尾');
      // 跟手位移不能残留：顶层（新顶卡）回到原位
      final after = tester.getCenter(_topCard());
      expect(after.dx, closeTo(before.dx, 0.5));
      expect(after.dy, closeTo(before.dy, 0.5));
      expect(_badgeText('稍后'), findsNothing, reason: '结算后浮层收掉');
      expect(find.byType(SnackBar), findsNothing, reason: '稍后刻意不打断用户');
    });

    testWidgets('下滑 = 稍后：两张卡轮流推到队尾 → 队首轮转（谁都没被"处理掉"）',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      await tester.drag(_topCard(), const Offset(0, 300));
      await _flush(tester);
      expect(_deckOrder(tester), ['BV2', 'BV1']);

      // 再下滑：BV2 也推到队尾 → 队首又轮回到 BV1（它只是"排到后面"、没被处理）
      await tester.drag(_topCard(), const Offset(0, 300));
      await _flush(tester);
      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '推后 → 队列轮转，不是"不再出现"');
      expect(h.service.handled, isEmpty);
      expect(h.github.savedBvids, isEmpty);
    });

    testWidgets('上滑过阈值 → 取回：最近推后的那张回到栈顶，且什么都不写',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      await tester.drag(_topCard(), const Offset(0, 300)); // 下滑 BV1（稍后）
      await _flush(tester);
      expect(_topBvid(tester), 'BV2');

      await tester.drag(_topCard(), const Offset(0, -300)); // 上滑 = 取回
      await _flush(tester);

      expect(_topBvid(tester), 'BV1', reason: '被推后的那张回到**栈顶**（原话"上滑回来"）');
      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '顺序回到原样');
      expect(h.service.handled, isEmpty, reason: '取回不写「已处理」');
      expect(h.service.unhandled, isEmpty, reason: '取回也不该去"撤销已处理"（从没记过）');
      expect(h.github.savedBvids, isEmpty);
      expect(h.api.metaCalls, isEmpty);
      expect(find.text('已取回「新视频 1」'), findsOneWidget, reason: '给一条轻提示');
    });

    testWidgets('连续下滑两张 → 连续上滑：按 LIFO 逐张取回（顺序正确）',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2), _item(3)]);

      await tester.drag(_topCard(), const Offset(0, 300)); // BV1 → 队尾
      await _flush(tester);
      await tester.drag(_topCard(), const Offset(0, 300)); // BV2 → 队尾
      await _flush(tester);
      expect(_deckOrder(tester), ['BV3', 'BV1', 'BV2']);

      await tester.drag(_topCard(), const Offset(0, -300)); // 取回
      await _flush(tester);
      expect(_topBvid(tester), 'BV2', reason: 'LIFO：最近推后的先回来（不是先进先出）');
      expect(_deckOrder(tester), ['BV2', 'BV3', 'BV1']);

      await tester.drag(_topCard(), const Offset(0, -300)); // 再取回
      await _flush(tester);
      expect(_topBvid(tester), 'BV1');
      expect(_deckOrder(tester), ['BV1', 'BV2', 'BV3'], reason: '两张都取回后恢复原序');
      expect(h.service.handled, isEmpty, reason: '全程都只是"放一放"，一次判定都没发生');
      expect(h.github.savedBvids, isEmpty);
    });

    testWidgets('没有可取的卡时上滑：队列不动、弹回原位，并给一条可见提示（不再静默）',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      final before = tester.getCenter(_topCard());

      await tester.drag(_topCard(), const Offset(0, -300)); // 从没下滑过
      await _flush(tester);

      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '队列一个字节都不该变');
      final after = tester.getCenter(_topCard());
      expect(after.dx, closeTo(before.dx, 0.5), reason: '弹回原位');
      expect(after.dy, closeTo(before.dy, 0.5));
      expect(h.service.handled, isEmpty);
      expect(h.service.unhandled, isEmpty);
      expect(h.github.savedBvids, isEmpty, reason: '绝不能误判成"加入"');
      expect(h.api.metaCalls, isEmpty);
      // ★ v2.49.1 契约变更（旧断言：`find.byType(SnackBar), findsNothing`
      //   "不弹提示（它不是错误）"）：**静默本身就是缺陷** —— 用户上滑什么都没
      //   看到，读成"卡了 / 上下滑逻辑乱"。现在一律给一条克制的 info 提示
      //   （受设置里的「界面提示」开关控制，关了照样安静）。
      expect(find.text('暂无可取回的卡片'), findsOneWidget,
          reason: '空手取回时必须有可见反馈（旧实现只有 debugPrint）');
    });

    testWidgets('设置里关掉「界面提示」→ 空手取回照旧不弹（提示条本就不该绕过总开关）',
        (tester) async {
      UiPrefsStore.instance.resetForTest(showTips: false);
      addTearDown(() => UiPrefsStore.instance.resetForTest(showTips: true));
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      await tester.drag(_topCard(), const Offset(0, -300)); // 从没下滑过
      await _flush(tester);

      expect(find.byType(SnackBar), findsNothing,
          reason: 'info 档走 AppSnack，受「界面提示」总开关控制（关了就安静）');
      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '队列照样一个字节都不动');
      expect(h.service.handled, isEmpty);
      expect(h.github.savedBvids, isEmpty);
    });

    testWidgets('只有 1 张卡时下滑无动作（"推到队尾"就是原地打转）', (tester) async {
      final h = await _pumpInbox(tester, [_item(1)]);
      final before = tester.getCenter(_topCard());

      await tester.drag(_topCard(), const Offset(0, 300));
      await _flush(tester);

      expect(_deckOrder(tester), ['BV1'], reason: '唯一一张不该在队首/队尾之间空转');
      final after = tester.getCenter(_topCard());
      expect(after.dx, closeTo(before.dx, 0.5), reason: '弹回原位');
      expect(after.dy, closeTo(before.dy, 0.5));
      expect(h.service.handled, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('新视频 1'), findsOneWidget, reason: '卡片没动');
    });

    testWidgets('取回的卡可以再次被下滑（可反复）', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      for (var i = 0; i < 2; i++) {
        await tester.drag(_topCard(), const Offset(0, 300));
        await _flush(tester);
        expect(_topBvid(tester), 'BV2', reason: '第 ${i + 1} 轮：推到队尾');
        await tester.drag(_topCard(), const Offset(0, -300));
        await _flush(tester);
        expect(_topBvid(tester), 'BV1', reason: '第 ${i + 1} 轮：取回');
      }
      expect(h.service.handled, isEmpty, reason: '来回多少轮都不写任何东西');
      expect(_deckOrder(tester), ['BV1', 'BV2']);
    });

    testWidgets('已被判定的那张不再被取回；取回过的卡照样能被左滑 / 右滑', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      await tester.drag(_topCard(), const Offset(0, 300)); // 稍后 BV1
      await _flush(tester);
      await tester.drag(_topCard(), const Offset(0, 300)); // 稍后 BV2
      await _flush(tester);
      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '轮转一圈，两张都"待取回"');

      // 队首的 BV1 这次不取回，直接左滑跳过 → 它不再是"待取回"的
      await tester.drag(_topCard(), const Offset(-300, 0));
      await _flush(tester);
      expect(h.service.handled, ['BV1']);
      expect(_deckOrder(tester), ['BV2'], reason: '跳过的那张不再出现');

      // 上滑只该取回 BV2（BV1 已被判定，不能又被搬回栈顶）
      await tester.drag(_topCard(), const Offset(0, -300));
      await _flush(tester);
      expect(_deckOrder(tester), ['BV2'], reason: '判定掉的那张不该再被取回');
      expect(h.service.handled, ['BV1'], reason: '取回不产生新的「已处理」');
      expect(h.github.savedBvids, isEmpty);
    });

    testWidgets('下滑 → 从**下方**飞出屏幕；上滑 → 当前卡**不**飞出、取回的那张从下方滑回（开动效）',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final restTop = tester.getRect(_topCard()).top;

      // ① 下滑 = 稍后：BV1 往下飞出屏幕（顺着"推到后面"的方向）
      final down = await exitShift(tester, const Offset(0, 300));
      expect(down.dy, greaterThan(300), reason: '下滑 → 往下飞出屏');
      expect(down.dx.abs(), lessThan(5), reason: '纯竖直滑动不该带水平分量');
      expect(_topBvid(tester), 'BV2', reason: '下一张顶上来');

      // ② 上滑 = 取回：当前这张（BV2）**不**飞走，被取回的 BV1 从下方滑回栈顶
      await tester.drag(_topCard(), const Offset(0, -200));
      await tester.pump();
      var incomingFromBelow = false;
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        final cur = tester.getRect(_cardByBvid('BV2')).top;
        expect(cur, greaterThan(restTop - 260),
            reason: '第 $i 帧：当前卡不该朝屏幕外飞走（上滑不是判定）');
        expect(cur, lessThan(restTop + 260),
            reason: '第 $i 帧：当前卡只是弹回原位 / 退成后层');
        final back = _cardByBvid('BV1');
        if (back.evaluate().isNotEmpty &&
            tester.getRect(back).top > restTop + 400) {
          incomingFromBelow = true; // 它从屏外**下方**一路滑上来
        }
      }
      expect(incomingFromBelow, isTrue,
          reason: '被取回的那张必须从下方滑入 —— 一眼看出"有卡回来了"');
      await tester.pumpAndSettle();
      expect(_topBvid(tester), 'BV1');
      expect(_deckOrder(tester), ['BV1', 'BV2', 'BV3'], reason: '取回后队列回原样');
      expect(tester.getRect(_topCard()).top, closeTo(restTop, 0.6),
          reason: '取回的那张最终落回顶层原位');
    });

    testWidgets('左右滑回归：左滑往左飞、右滑往右飞（开动效）', (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 3; i++) _item(i)]);

      final left = await exitShift(tester, const Offset(-300, 0)); // BV1 左滑
      expect(left.dx, lessThan(-300), reason: '左滑 → 往左飞出屏');
      expect(left.dy.abs(), lessThan(5));

      final right = await exitShift(tester, const Offset(300, 0)); // BV2 右滑
      expect(right.dx, greaterThan(300), reason: '右滑 → 往右飞出屏');
      expect(right.dy.abs(), lessThan(5));
    });

    testWidgets('快速轻扫｜下：位移没过阈值 + 甩得够快 → 判成**稍后**（不记「已处理」）',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      await tester.fling(_topCard(), const Offset(0, 60), 2000);
      await _flush(tester);

      expect(_deckOrder(tester), ['BV2', 'BV1'], reason: '轻扫下滑 = 稍后 → 推到队尾');
      expect(h.service.handled, isEmpty, reason: '稍后不是跳过');
      expect(h.github.savedBvids, isEmpty);
      expect(h.api.metaCalls, isEmpty);
    });

    testWidgets('快速轻扫｜上：有可取的卡 → 取回；没有 → 无动作', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);

      // ① 还没下滑过 → 没卡可取：轻扫上滑什么队列都不动，只给一条提示
      await tester.fling(_topCard(), const Offset(0, -60), 2000);
      await _flush(tester);
      expect(_deckOrder(tester), ['BV1', 'BV2']);
      // ★ v2.49.1 契约变更（旧断言：`find.byType(SnackBar), findsNothing`）：
      //   空手取回不再静默，见上面「没有可取的卡时上滑」那条用例的说明
      expect(find.text('暂无可取回的卡片'), findsOneWidget,
          reason: '没卡可取时给可见反馈');
      expect(h.github.savedBvids, isEmpty, reason: '上滑绝不是"加入"');

      // ② 先轻扫下滑把 BV1 推到后面 → 再轻扫上滑把它取回来
      await tester.fling(_topCard(), const Offset(0, 60), 2000);
      await _flush(tester);
      expect(_deckOrder(tester), ['BV2', 'BV1']);
      await tester.fling(_topCard(), const Offset(0, -60), 2000);
      await _flush(tester);
      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '轻扫上滑 = 取回');
      expect(h.service.handled, isEmpty);
    });

    testWidgets('快速轻扫｜左 / 右：既有方向回归（位移没过阈值也能判定）', (tester) async {
      final h = await _pumpInbox(tester, [for (var i = 1; i <= 3; i++) _item(i)]);

      await tester.fling(_topCard(), const Offset(-60, 0), 2000); // BV1 左滑轻扫
      await _flush(tester);
      expect(h.service.handled, ['BV1'], reason: '左滑轻扫 = 跳过');
      expect(h.github.savedBvids, isEmpty);

      await tester.fling(_topCard(), const Offset(60, 0), 2000); // BV2 右滑轻扫
      await _flush(tester);
      expect(h.github.savedBvids, ['BV2'], reason: '右滑轻扫 = 加入');
      expect(h.service.handled, ['BV1', 'BV2']);
    });

    testWidgets('阈值内的小位移 + 慢速 → 弹回原位（四向都不判定、浮层清零）',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      final before = tester.getCenter(_topCard());
      // 80 < 411×30% ≈ 123；`tester.drag` 的移动事件时间戳全是 0 → 速度估不出来
      //（DragGestureRecognizer 在拿不到速度估计时给的是 0）→ 只剩距离能判定
      for (final d in const [
        Offset(80, 0),
        Offset(-80, 0),
        Offset(0, 80),
        Offset(0, -80),
      ]) {
        await tester.drag(_topCard(), d);
        await _flush(tester);
        expect(h.service.handled, isEmpty, reason: '$d 没过阈值 → 不该判定');
        expect(h.github.savedBvids, isEmpty);
        expect(h.api.metaCalls, isEmpty, reason: '拖动不该触发打开播放页');
        final now = tester.getCenter(_topCard());
        expect(now.dx, closeTo(before.dx, 0.5), reason: '$d 之后要弹回原位');
        expect(now.dy, closeTo(before.dy, 0.5));
      }
      expect(_badgeText('加入'), findsNothing, reason: '没成一张 → 浮层收掉');
      expect(_badgeText('跳过'), findsNothing);
      expect(_badgeText('稍后'), findsNothing);
      expect(_badgeText('取回'), findsNothing);
      expect(_deckOrder(tester), ['BV1', 'BV2'], reason: '四向都没过阈值 → 队列不动');
    });

    testWidgets('斜向拖动按**主导轴**判定：dx 明显大 → 水平；dy 明显大 → 竖直（稍后）',
        (tester) async {
      final h = await _pumpInbox(tester, [for (var i = 1; i <= 3; i++) _item(i)]);

      // ① (200, 60)：dx 明显大 → 按水平轴判成「右滑加入」
      await tester.drag(_topCard(), const Offset(200, 60));
      await _flush(tester);
      expect(h.github.savedBvids, ['BV1'], reason: 'dx 主导 → 走水平判定（加入）');
      expect(h.service.handled, ['BV1']);

      // ② (60, 200)：dy 明显大 → 按竖直轴判成「下滑稍后」
      await tester.drag(_topCard(), const Offset(60, 200));
      await _flush(tester);
      expect(h.service.handled, ['BV1'],
          reason: 'dy 主导 → 走竖直判定（稍后），不该记「已处理」');
      expect(_deckOrder(tester), ['BV3', 'BV2'], reason: '第二张被推到队尾');
      expect(h.github.savedBvids, ['BV1'], reason: '第二张是稍后，不该进白名单');
      expect(h.api.metaCalls, ['BV1'], reason: '只有第一张去取过元数据');
    });

    testWidgets('稍后不进撤销位：撤销仍只作用于判定过的卡（开动效）', (tester) async {
      final h = await _pumpInboxAnimated(tester, [_item(1), _item(2), _item(3)]);

      // 一进来没有可撤销的 → 按钮禁用（既有语义）
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
            .onPressed,
        isNull,
      );

      // 下滑「稍后」**不是**一次判定 → 撤销位仍是空的
      await tester.drag(_topCard(), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(_topBvid(tester), 'BV2');
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
            .onPressed,
        isNull,
        reason: '「稍后」不产生可撤销项（它是靠上滑取回回来的）',
      );
      expect(h.service.unhandled, isEmpty);

      // 真判一次（左滑跳过）之后，撤销才把那张放回来 —— 且仍从**左侧**飞回
      await tester.drag(_topCard(), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(h.service.handled, ['BV2']);
      final restRect = tester.getRect(_topCard());
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40)); // 飞回来的途中
      expect(
        tester.getRect(_cardByBvid('BV2')).left,
        lessThan(restRect.left - 100),
        reason: '起点在屏外**左侧** → 从左侧飞回来（撤销方向语义没变）',
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(_cardByBvid('BV2')).top, closeTo(restRect.top, 0.6));
      expect(h.service.unhandled, ['BV2'], reason: '撤销要把「已处理」记录也去掉');
      expect(_topBvid(tester), 'BV2');
    });

    testWidgets('浮层：下滑「稍后」/ 上滑「取回」都居中，颜色与左右滑明显区分（回归）',
        (tester) async {
      await _pumpInbox(tester, [_item(1), _item(2)]);

      /// 卡面上的徽标底色 / 描边 / 字色（护栏断言用）。
      BoxDecoration badgeDeco(String label) {
        final box = tester.widget<Container>(
          find
              .ancestor(of: _badgeText(label), matching: find.byType(Container))
              .first,
        );
        return box.decoration! as BoxDecoration;
      }

      // ① 下滑 → 「稍后」（**不是**「跳过」）：浅底深字 + 描边，居中
      final down = await tester.startGesture(tester.getCenter(_topCard()));
      await down.moveBy(const Offset(0, 60)); // 第一次移动被 touch slop 吃掉
      await tester.pump();
      await down.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(_badgeText('稍后'), findsOneWidget);
      expect(_badgeText('跳过'), findsNothing, reason: '下滑不是跳过');
      expect(_badgeText('加入'), findsNothing);
      expect(
        tester.getRect(_badgeText('稍后')).center.dx,
        closeTo(tester.getRect(_topCard()).center.dx, 1),
        reason: '竖直主导 → 徽标居中',
      );
      expect(badgeDeco('稍后').color, AppPalette.fallback.accentWash,
          reason: '「稍后」是浅底（不是判定），与两个实心判定标记分开');
      expect(badgeDeco('稍后').border, isNotNull,
          reason: '浅底必须配描边，否则浅色卡面上看不出块');
      expect(tester.widget<Text>(_badgeText('稍后')).style?.color,
          AppPalette.fallback.accentDeep);
      await down.up();
      await _flush(tester);
      expect(_badgeText('稍后'), findsNothing, reason: '没成一张 → 浮层收掉');

      // ② 上滑 → 「取回」（**不是**「加入」）：实心点缀底，居中
      //    先验"没有可取的卡时不亮"：亮着却什么都回不来会让人以为卡丢了
      final empty = await tester.startGesture(tester.getCenter(_topCard()));
      await empty.moveBy(const Offset(0, -60));
      await tester.pump();
      await empty.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(_badgeText('取回'), findsNothing,
          reason: '还没有"待取回"的卡 → 不亮「取回」');
      expect(_badgeText('加入'), findsNothing, reason: '上滑绝不是「加入」');
      await empty.up();
      await _flush(tester);

      // 先下滑一张（真过阈值）→ 此刻有卡可取，上滑拖中才亮「取回」
      await tester.drag(_topCard(), const Offset(0, 300));
      await _flush(tester);
      expect(_topBvid(tester), 'BV2');

      final up = await tester.startGesture(tester.getCenter(_topCard()));
      await up.moveBy(const Offset(0, -60));
      await tester.pump();
      await up.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(_badgeText('取回'), findsOneWidget);
      expect(_badgeText('加入'), findsNothing, reason: '上滑不是加入');
      expect(_badgeText('稍后'), findsNothing);
      expect(
        tester.getRect(_badgeText('取回')).center.dx,
        closeTo(tester.getRect(_topCard()).center.dx, 1),
      );
      expect(badgeDeco('取回').color, AppPalette.fallback.accentFill);
      expect(tester.widget<Text>(_badgeText('取回')).style?.color,
          AppPalette.fallback.onAccent);
      expect(badgeDeco('取回').color, isNot(AppPalette.fallback.inkFill),
          reason: '与右滑「加入」的墨蓝明显区分');
      await up.up();
      await _flush(tester);
      expect(_badgeText('取回'), findsNothing);

      // ③ 右滑回归 → 仍贴左边缘（既有观感不变）
      final right = await tester.startGesture(tester.getCenter(_topCard()));
      await right.moveBy(const Offset(60, 0));
      await tester.pump();
      await right.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(_badgeText('加入'), findsOneWidget);
      expect(
        tester.getRect(_badgeText('加入')).center.dx,
        lessThan(tester.getRect(_topCard()).center.dx - 60),
        reason: '水平主导 → 徽标仍贴左边缘',
      );
      await right.up();
      await _flush(tester);
    });

    testWidgets('卡片上的上下拖不再带动页面滚动 / 不触发下拉刷新', (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2)]);
      expect(h.service.checkCalls, 1);

      // 从卡片中心往下甩（这正是旧用例里"下拉刷新"的起点）：现在算「下滑 = 稍后」
      await tester.fling(_topCard(), const Offset(0, 300), 1000);
      await _flush(tester);

      expect(h.service.checkCalls, 1,
          reason: '纵向拖动被卡片吃掉 → 不带页面滚动、不触发下拉刷新');
      expect(_deckOrder(tester), ['BV2', 'BV1'], reason: '这一下算「下滑 = 稍后」');
      expect(h.service.handled, isEmpty, reason: '稍后不记「已处理」');
      expect(h.github.savedBvids, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 上下交替的不变式（v2.49.1）
  // 用户报障：「上下跳过逻辑很乱，不停上滑居然会出现之前跳过的卡片变成循环」
  // 断言一律落在**状态**上（队列内容 / 待取回票栈 / 取回次数），不只看动画位置：
  // - 一卡一票、票用完即空 → 同一张卡不可能靠一张票被取回两次；
  // - 「稍后」的那张在**落地前**没有票 → 飞行窗口里取不到它，也不会取错卡；
  // - 空手取回有可见反馈 → "划了没反应"不再被读成"逻辑乱"。
  // -------------------------------------------------------------------------

  group('上下交替不循环（一张卡最多被取回一次）', () {
    testWidgets('下滑→上滑交替 5 轮：每轮回到原样，票用完即空（同一张卡不会被反复取回）',
        (tester) async {
      await _pumpInbox(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final s = _inboxState(tester);
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3'], reason: '初始队列');

      for (var round = 1; round <= 5; round++) {
        await tester.drag(_topCard(), const Offset(0, 300)); // 下滑 = 稍后
        await _flush(tester);
        expect(s.debugItemBvids, ['BV2', 'BV3', 'BV1'],
            reason: '第 $round 轮：队首挪到队尾（队列转一位）');
        expect(s.debugDeferredBvids, ['BV1'],
            reason: '第 $round 轮：只有一张票（落地时才挂）');

        await tester.drag(_topCard(), const Offset(0, -300)); // 上滑 = 取回
        await _flush(tester);
        expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3'],
            reason: '第 $round 轮：取回后回到原样');
        expect(s.debugDeferredBvids, isEmpty,
            reason: '第 $round 轮：票**被消费掉**了 —— 一张票不可能取回两次');
        expect(s.debugRestoreCount, round,
            reason: '第 $round 轮：全程只该发生 $round 次取回');
        expect(s.debugItemBvids.toSet().length, 3, reason: '队列里没有重复 bvid');
        expect(find.text('已取回「新视频 1」'), findsOneWidget,
            reason: '第 $round 轮：取回的确实是刚「稍后」掉的那张');
      }

      // ★ 票已空：再上滑只给可见反馈，**不会**又冒出一张"之前处理掉的卡"
      //   （旧实现走到这里往往还能再"取回"一次 —— 就是用户看到的循环）
      await tester.drag(_topCard(), const Offset(0, -300));
      await _flush(tester);
      expect(s.debugDeferredBvids, isEmpty);
      expect(s.debugRestoreCount, 5, reason: '没有第 6 次取回');
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3'], reason: '队列一个字节都不动');
      expect(find.text('暂无可取回的卡片'), findsOneWidget);
      expect(find.text('已取回「新视频 1」'), findsNothing,
          reason: '同一张卡不会被再次"取回"（循环被消灭的直接证据）');
    });

    testWidgets('用户报障的原样动作：不停上滑 5 次 → 只有第一次真的取回，之后 4 次只给反馈',
        (tester) async {
      await _pumpInbox(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final s = _inboxState(tester);

      // 上滑能取回的**唯一**来源是一次「稍后」：先下滑一张，攒下一张票
      await tester.drag(_topCard(), const Offset(0, 300));
      await _flush(tester);
      expect(s.debugItemBvids, ['BV2', 'BV3', 'BV1']);
      expect(s.debugDeferredBvids, ['BV1']);

      // 用户报障的动作就是「不停上滑」（中间不夹下滑）。旧实现在这里能让同一
      // 张卡反复回栈顶 —— 看起来就是"之前处理掉的卡变成循环"。
      for (var i = 1; i <= 5; i++) {
        await tester.drag(_topCard(), const Offset(0, -300));
        await _flush(tester);
        expect(s.debugRestoreCount, 1,
            reason: '第 $i 次上滑：全程只该有第一次那一次取回（票用完即空）');
        expect(s.debugDeferredBvids, isEmpty,
            reason: '第 $i 次上滑：票栈必须为空 —— 不存在"同一张卡无限回到栈顶"');
        expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3'],
            reason: '第 $i 次上滑：队列停在"取回一次"之后的样子，没有卡被反复搬回来');
        expect(s.debugItemBvids.toSet().length, 3, reason: '队列里没有重复 bvid');
      }
      // 屏幕上最后一条提示是"没有可取的"，不是"又取回了一张"
      expect(find.text('暂无可取回的卡片'), findsOneWidget);
      expect(find.text('已取回「新视频 1」'), findsNothing,
          reason: '★ 反复上滑不会让已经取回过的卡再冒出来（用户报障的直接反例）');
    });

    testWidgets('连续下滑三张后连续上滑：LIFO 逐张取回，第 4 次只给反馈（不再回到栈顶）',
        (tester) async {
      await _pumpInbox(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final s = _inboxState(tester);

      for (var i = 1; i <= 3; i++) {
        await tester.drag(_topCard(), const Offset(0, 300)); // 三张都「稍后」
        await _flush(tester);
      }
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3'], reason: '转一圈又回到原序');
      expect(s.debugDeferredBvids, ['BV1', 'BV2', 'BV3'],
          reason: '三张各有一张票（栈顶 = 最后推后的那张）');

      const expects = [('BV3', '新视频 3'), ('BV2', '新视频 2'), ('BV1', '新视频 1')];
      for (final (bvid, title) in expects) {
        await tester.drag(_topCard(), const Offset(0, -300)); // 上滑 = 取回
        await _flush(tester);
        expect(s.debugItemBvids.first, bvid, reason: 'LIFO：$bvid 回到队首');
        expect(find.text('已取回「$title」'), findsOneWidget,
            reason: '取回的正是 $bvid（没有取错卡）');
      }
      expect(s.debugDeferredBvids, isEmpty, reason: '三张票各被取回一次 → 排空');
      expect(s.debugRestoreCount, 3);

      // 第 4 次上滑：旧实现这里还能"再取回"一张（反复上滑 → 卡片循环）
      await tester.drag(_topCard(), const Offset(0, -300));
      await _flush(tester);
      expect(find.text('暂无可取回的卡片'), findsOneWidget);
      expect(s.debugRestoreCount, 3, reason: '没有第 4 次取回');
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3']);
    });

    testWidgets('下滑之后幽灵还在飞就上滑：取不到正在飞的那张，取的是已落地的票（开动效）',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final s = _inboxState(tester);

      // ① 先把 BV1「稍后」并等它**落地** → 有了一张已落地的票
      await tester.drag(_topCard(), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV2', 'BV3', 'BV1']);
      expect(s.debugDeferredBvids, ['BV1']);
      expect(s.debugGhostBvid, isNull, reason: '已经落地了');

      // ② 再下滑 BV2：过了交接点（kDurAdvance）它还在幽灵层里飞
      await tester.drag(_topCard(), const Offset(0, 300));
      await tester.pump();
      await tester.pump(kDurAdvance + const Duration(milliseconds: 20));
      expect(s.debugGhostBvid, 'BV2', reason: 'BV2 正在飞');
      expect(s.debugItemBvids, ['BV3', 'BV1'], reason: '交接之后它已离开牌堆');
      expect(s.debugDeferredBvids, ['BV1'],
          reason: '★ 飞行中的 BV2 **没有票**（旧实现这里会把它、或更早那张算成"可取"）');

      // ③ 飞行途中上滑：只可能取到已落地的 BV1，取不到正在飞的 BV2
      await tester.drag(_cardByBvid('BV3'), const Offset(0, -300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200)); // > kDurQuick：第一步走完
      expect(s.debugItemBvids.first, 'BV1', reason: '取回的是票栈顶那张（已落地的）');
      expect(s.debugRestoreCount, 1);
      expect(s.debugDeferredBvids, isEmpty, reason: '那张票被消费掉了');
      expect(find.text('已取回「新视频 1」'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV1', 'BV3', 'BV2'],
          reason: 'BV2 落地后回队尾（没有插到队首、也没有凭空多一张）');
      expect(s.debugDeferredBvids, ['BV2'],
          reason: '落地**之后**才给它挂票（飞行窗口里没有）');
      expect(s.debugItemBvids.toSet().length, 3, reason: '队列里没有重复 bvid');
      expect(s.debugGhostBvid, isNull);
    });

    testWidgets('下滑之后还没有已落地的票就上滑：给可见反馈，不再静默（开动效）',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final s = _inboxState(tester);

      await tester.drag(_topCard(), const Offset(0, 300)); // 稍后 BV1
      await tester.pump();
      await tester.pump(kDurAdvance + const Duration(milliseconds: 20));
      expect(s.debugGhostBvid, 'BV1', reason: 'BV1 正在飞');
      expect(s.debugItemBvids, ['BV2', 'BV3']);
      expect(s.debugDeferredBvids, isEmpty, reason: '飞行中不挂票 → 此刻没有可取的');

      // 上滑：弹回原位 + 一条提示（旧实现只有一行 debugPrint，用户看到的是
      // "划了没反应"）
      await tester.drag(_cardByBvid('BV2'), const Offset(0, -300));
      await tester.pump();
      expect(find.text('暂无可取回的卡片'), findsOneWidget);
      expect(s.debugRestoreCount, 0, reason: '一次取回都没发生');
      expect(s.debugItemBvids, ['BV2', 'BV3'], reason: '队列没有被改动');

      // 落地之后就能取回了 —— 说明"刚才取不到"不是丢卡，只是还没轮到
      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV2', 'BV3', 'BV1']);
      expect(s.debugDeferredBvids, ['BV1'], reason: '落地才挂票');
      await tester.drag(_topCard(), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3'], reason: '取回后回原样');
      expect(s.debugRestoreCount, 1);
      expect(s.debugDeferredBvids, isEmpty);
    });

    testWidgets('同一张卡第二次「稍后」的飞行窗口里上滑：取到的是已落地的票，绝不是正在飞的那张（开动效）',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 3; i++) _item(i)]);
      final s = _inboxState(tester);

      // 三张各「稍后」一次并等落地 → 票 [BV1,BV2,BV3]，队列转回原序
      for (var i = 0; i < 3; i++) {
        await tester.drag(_topCard(), const Offset(0, 300));
        await tester.pumpAndSettle();
      }
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3']);
      expect(s.debugDeferredBvids, ['BV1', 'BV2', 'BV3']);
      expect(s.debugRestoreCount, 0, reason: '还一次都没取回过');

      // 再把队首 BV1「稍后」一次：它在飞行窗口里**必须没有票**。旧实现这里
      // 留着上一次那张票（defer 分支提前 return，不作废）→ 上滑取到的是**正在
      // 飞的 BV1**，把它搬到队首 = 用户报的"取错卡 / 之前的卡又回来了"。
      await tester.drag(_topCard(), const Offset(0, 300));
      await tester.pump();
      await tester.pump(kDurAdvance + const Duration(milliseconds: 20));
      expect(s.debugGhostBvid, 'BV1', reason: 'BV1 正在飞');
      expect(s.debugItemBvids, ['BV2', 'BV3'], reason: '交接后它离开了牌堆');
      expect(s.debugDeferredBvids, ['BV2', 'BV3'],
          reason: '★ 飞行的 BV1 不占票（旧实现这里还是 [BV1,BV2,BV3]）');

      // 飞行途中上滑 → 只能取到那一摞里最近落地的 BV3
      await tester.drag(_cardByBvid('BV2'), const Offset(0, -300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200)); // > kDurQuick
      expect(s.debugItemBvids.first, 'BV3', reason: '取到的是已落地的 BV3，不是正在飞的 BV1');
      expect(find.text('已取回「新视频 3」'), findsOneWidget);
      expect(s.debugRestoreCount, 1);

      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV3', 'BV2', 'BV1'], reason: 'BV1 落地回队尾');
      expect(s.debugDeferredBvids, ['BV2', 'BV1'], reason: 'BV1 落地后才挂票');
      expect(s.debugItemBvids.toSet().length, 3, reason: '队列里没有重复 bvid');
    });
  });

  // -------------------------------------------------------------------------
  // 回读合并的顺序（v2.49.1）：新条目按发布时间插到该在的位置
  // -------------------------------------------------------------------------

  group('回读合并：新条目按发布时间插入', () {
    testWidgets('检查进行中新抓到的视频按发布时间插入，不顶掉当前这张、也不落到队尾',
        (tester) async {
      final gate = Completer<void>();
      // 队列：BV1（1 小时前）、BV2（5 小时前）—— 中间还留着一个"两小时前"的位
      final items = <InboxItem>[
        _item(1, pubDate: _agoHours(1)),
        _item(2, pubDate: _agoHours(5)),
      ];
      await _pumpInbox(tester, items, checkGate: gate);
      final s = _inboxState(tester);
      expect(s.debugItemBvids, ['BV1', 'BV2']);

      // 检查还在跑：服务层又落盘了一条（2 小时前发的 → 比 BV2 新、比 BV1 旧）
      items.add(_item(3, pubDate: _agoHours(2)));
      await tester.pump(const Duration(seconds: 3)); // _kProgressPoll
      await _flush(tester);

      expect(s.debugItemBvids, ['BV1', 'BV3', 'BV2'],
          reason: '按发布时间倒序插到 BV2 之前（旧实现一律追加到队尾 → '
              '顺序与发布时间脱钩，用户读成"顺序很乱"）');
      expect(_topBvid(tester), 'BV1', reason: '既有契约：不顶掉当前正在看的那张');

      // 更晚抓到的"最新那条"同样不顶掉当前这张（插入位置下限 = 索引 1）
      items.add(_item(4, pubDate: _agoHours(0)));
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);
      expect(s.debugItemBvids, ['BV1', 'BV4', 'BV3', 'BV2']);
      expect(_topBvid(tester), 'BV1', reason: '回读每 3s 一次，可能正跑在拖动中间');

      // 当前这张被划走之后，队列就完全是发布时间序了
      await tester.drag(_topCard(), const Offset(-300, 0)); // 跳过 BV1
      await _flush(tester);
      expect(s.debugItemBvids, ['BV4', 'BV3', 'BV2'], reason: '此后严格按发布时间倒序');

      // 中途插入不影响「取回」的顺序：票是按"推后的先后"入栈的，与卡在队列里
      // 的位置无关 → 取回后队列必须回到推后之前的样子
      await tester.drag(_topCard(), const Offset(0, 300)); // 稍后 BV4
      await _flush(tester);
      expect(s.debugItemBvids, ['BV3', 'BV2', 'BV4']);
      expect(s.debugDeferredBvids, ['BV4']);
      await tester.drag(_topCard(), const Offset(0, -300)); // 取回 BV4
      await _flush(tester);
      expect(s.debugItemBvids, ['BV4', 'BV3', 'BV2'], reason: '取回后回到推后之前');

      gate.complete(); // 收掉挂着的 checkAll（否则用例结束时留下未完成的 Future）
      await _flush(tester);
      expect(find.byType(InboxSwipeCard), findsNWidgets(3));
    });

    testWidgets('回读正好撞上「稍后」那张还在飞：不把它并回来、牌堆不出两张，落地后照样能取回（开动效）',
        (tester) async {
      final gate = Completer<void>();
      // 服务层此刻仍把 BV1 当"未读"（「稍后」不写盘）→ 回读的列表里一定有它
      final items = <InboxItem>[_item(1), _item(2), _item(3)];
      await _pumpInboxAnimated(tester, items, checkGate: gate);
      final s = _inboxState(tester);
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV3']);

      // ★ 时间安排（三个时刻必须落在一条线上，改这里的数字前先看这段算术）：
      //   回读定时器（_kProgressPoll = 3s）从 initState 起算、_pumpInboxAnimated
      //   已经走了 500ms → 第一次回读在**时钟 3.0s**；竖直出屏 ≈ 508ms
      //   （= 320ms × 屏高 / 1.4 屏宽，见 inboxExitMotion），交接点在它的
      //   kDurAdvance(160ms) 处 → 于是"松手"留在 **2.70s**：幽灵层存活区间
      //   2.86s → 3.208s，回读那一刻（3.0s）正落在里面。
      await tester.pump(const Duration(milliseconds: 2200)); // 时钟 → 2.70s
      await tester.drag(_topCard(), const Offset(0, 300)); // 稍后 BV1（松手）
      await tester.pump(); // 起飞
      // 哨兵：只在"回读真的跑过一次"之后才会进队列（它跟守卫无关，
      // 所以它出现 = 回读那一刻确实到了，下面关于 BV1 的断言不是在空转）
      items.add(_item(9, pubDate: _agoHours(0)));
      await tester.pump(kDurAdvance + const Duration(milliseconds: 10)); // 2.87s：已交接
      expect(s.debugGhostBvid, 'BV1', reason: '交接之后 BV1 在幽灵层里飞');
      expect(s.debugItemBvids, ['BV2', 'BV3']);
      // 按 50ms 步进，**一旦哨兵出现就停下**：这样下面那条"BV1 还在飞"的断言
      // 恰好落在回读那一帧上（多 pump 一步它就落地了，见下一段）
      var steps = 0;
      while (!s.debugItemBvids.contains('BV9') && steps < 40) {
        await tester.pump(const Duration(milliseconds: 50));
        steps++;
      }
      expect(s.debugItemBvids.contains('BV9'), isTrue,
          reason: '回读必须真的跑过一次（哨兵 BV9 进了队列），否则本用例是空转');
      expect(s.debugGhostBvid, 'BV1',
          reason: '★ 回读与飞行窗口真的重叠了：此刻 BV1 还在幽灵层里飞');
      expect(s.debugItemBvids, ['BV2', 'BV9', 'BV3'],
          reason: '★ 回读不把正在飞的那张并回来（并回来会同时画两张一样的卡，'
              '而且落地时"已经在队里"→ 不再挂票 → 这张再也取不回来）；'
              'BV9 插在比它旧的 BV3 之前 = 按发布时间落位');

      // 落地 → 回队尾 + 挂票 → 照样能取回（说明它没被回读吞掉）
      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV2', 'BV9', 'BV3', 'BV1'],
          reason: '落地回队尾（只一张，没有插到队首）');
      expect(s.debugDeferredBvids, ['BV1'], reason: '落地才挂票');
      await tester.drag(_topCard(), const Offset(0, -300)); // 取回 BV1
      await tester.pumpAndSettle();
      expect(s.debugItemBvids, ['BV1', 'BV2', 'BV9', 'BV3'], reason: '取回后回队首');
      expect(s.debugDeferredBvids, isEmpty);
      expect(s.debugItemBvids.toSet().length, 4, reason: '全程没有重复 bvid');
      expect(find.text('已取回「新视频 1」'), findsOneWidget);

      gate.complete();
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

      await _flingDeckForRefresh(tester);
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
      await _flingDeckForRefresh(tester);
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

      await _flingDeckForRefresh(tester);
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

      // ⑤ 检查回来（闸门放开）：只把新条目并进来（这批 pubDate 相同 → 等价于
      //    追加到队尾），当前这张不动、已消费的不复活
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
      // inbox_page.dart 的 _kProgressPoll = 3s）→ 新卡自动并进来
      //（这里两张的 pubDate 相同 → 等价于追加到队尾，见 _mergeChecked）
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);
      expect(_cardByBvid('BV2'), findsOneWidget,
          reason: '检查进行中的新条目必须能进卡片栈 —— 老实现要等整轮跑完');
      expect(tester.widget<InboxSwipeCard>(_topCard()).item.bvid, 'BV1',
          reason: '回读只增不改：当前正在看的那张不能换人');

      // 检查回来：不重复追加（还是那 2 张），提示收掉
      gate.complete();
      await _flush(tester);
      expect(find.byType(InboxSwipeCard), findsNWidgets(2));
      expect(find.text('检查中…'), findsNothing);
      expect(h.service.checkCalls, 1);
    });
  });

  // -------------------------------------------------------------------------
  // 连续滑动（v2.36.0）：松手后立刻能拖下一张 + 垂直上下快速切换
  // -------------------------------------------------------------------------
  group('连续滑动：解锁输入 + 幽灵层', () {
    /// 划一张（到出屏）→ 返回这一张**从松手到幽灵落地**经过的虚拟时间。
    ///
    /// 靠幽灵层的 key 判定"还在飞"（卡片栈的后层是 `inbox.stack:<bvid>`，
    /// 不会混）：幽灵落地那一刻它就消失了 —— 那就是这次飞出的总时长。
    Future<Duration> flightTime(
      WidgetTester tester,
      String bvid,
      Offset offset,
    ) async {
      await tester.drag(_cardByBvid(bvid), offset);
      await tester.pump();
      final ghost = find.byKey(ValueKey<String>('inbox.ghost:$bvid'));
      var ms = 0;
      // 先等幽灵出现（= 交接发生），再等它消失（= 落地）→ 两段之和就是这次飞出的总时长
      while (ghost.evaluate().isEmpty && ms < 1000) {
        await tester.pump(const Duration(milliseconds: 16));
        ms += 16;
      }
      expect(ghost, findsOneWidget, reason: '交接之后必须有幽灵卡接着飞');
      while (ghost.evaluate().isNotEmpty && ms < 3000) {
        await tester.pump(const Duration(milliseconds: 16));
        ms += 16;
      }
      expect(ghost, findsNothing, reason: '$bvid 的幽灵卡必须落地（不能挂着不放）');
      await tester.pumpAndSettle();
      return Duration(milliseconds: ms);
    }

    test('飞出位移与时长：竖直按距离等比放大（四向出屏速度一致）', () {
      const screen = Size(411, 914);
      final h = inboxExitMotion(screen: screen, vertical: false, positive: true);
      final v = inboxExitMotion(screen: screen, vertical: true, positive: true);
      final hl = inboxExitMotion(screen: screen, vertical: false, positive: false);
      final vu = inboxExitMotion(screen: screen, vertical: true, positive: false);

      // 水平：既有观感基准（1.4 × 屏宽 / kDurSlow），一个字没动
      expect(h.offset.dx, closeTo(411 * kInboxExitRatio, 0.001));
      expect(h.offset.dy, 0);
      expect(h.duration, kDurSlow);

      // 竖直：只推一屏高（旧值 1.4 屏高 = 多推 40%），时长等比放大
      expect(v.offset.dy, closeTo(914, 0.001));
      expect(v.offset.dx, 0);
      expect(v.duration.inMilliseconds, greaterThan(h.duration.inMilliseconds),
          reason: '走得更远 → 必须走得更久（旧实现两者同为 320ms → 竖直快一倍）');

      // ★ 核心不变式：四个方向出屏的**速度**一致
      final speedH = h.offset.dx / h.duration.inMicroseconds;
      final speedV = v.offset.dy / v.duration.inMicroseconds;
      expect(speedV, closeTo(speedH, speedH * 0.01),
          reason: '竖直与水平的出屏速度必须同量级（旧实现是 2.2 倍）');

      // 符号：四个方向各朝各的边；时长与方向无关（只与距离有关）
      expect(hl.offset.dx, lessThan(0));
      expect(vu.offset.dy, lessThan(0));
      expect(hl.duration, h.duration);
      expect(vu.duration, v.duration);
    });

    testWidgets('实测：竖直飞出时长 ≈ 水平 × (屏高 / 1.4 屏宽)', (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 4; i++) _item(i)]);

      // 水平：BV1 左滑（跳过 → 飞出去就不再回来）
      final tH = await flightTime(tester, 'BV1', const Offset(-300, 0));
      // 竖直：BV2 下滑（稍后 → 落地后回队尾，但幽灵本身同样"飞完就消失"）
      final tV = await flightTime(tester, 'BV2', const Offset(0, 300));

      const ref = 411 * kInboxExitRatio;
      final expectedV = tH.inMilliseconds * (914 / ref);
      expect(tV.inMilliseconds, closeTo(expectedV, expectedV * 0.15),
          reason: '竖直时长必须按距离等比放大（实测 ${tV.inMilliseconds}ms vs '
              '预期 ${expectedV.round()}ms；旧实现是 320 vs 320）');
      // 换算成平均速度：两者同量级（±15%）
      final speedH = ref / tH.inMilliseconds;
      final speedV = 914 / tV.inMilliseconds;
      expect(speedV, closeTo(speedH, speedH * 0.15),
          reason: '竖直速度必须重回同一量级（旧实现快 2.2 倍）');
    });

    testWidgets('松手 kDurAdvance 后立刻能拖下一张（旧实现整段飞出都在吞手势）',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 4; i++) _item(i)]);
      final rest = tester.getCenter(_cardByBvid('BV2'));

      await tester.drag(_cardByBvid('BV1'), const Offset(300, 0)); // 右滑 = 加入
      await tester.pump();

      // ① 推进段内（还没到 kDurAdvance）：顶卡仍是飞出去的 BV1，抓下一张抓不动
      await tester.pump(const Duration(milliseconds: 40));
      // warnIfMissed: false —— 此刻 BV2 还是**不吃手势**的后层（推进段内本来
      // 就不该拖动它），命中警告是预期的
      await tester.drag(_cardByBvid('BV2'), const Offset(60, 0),
          warnIfMissed: false);
      await tester.pump();
      expect(tester.getCenter(_cardByBvid('BV2')).dx, closeTo(rest.dx, 0.5),
          reason: '推进段（0~kDurAdvance）内下一张还没长到位，手势不该作用在它身上');

      // ② 过了交接点：BV2 就是顶卡 → 立刻能拖（这就是"连续跳过"的前提）
      await tester.pump(kDurAdvance);
      await tester.drag(_cardByBvid('BV2'), const Offset(60, 0));
      await tester.pump();
      expect(tester.getCenter(_cardByBvid('BV2')).dx, greaterThan(rest.dx + 20),
          reason: '松手 kDurAdvance（160ms）后就能拖下一张 —— '
              '旧实现要等整段飞出（320ms）');
      await tester.pumpAndSettle();
    });

    testWidgets('连续滑三张：每张只等 kDurAdvance 就能接着划（吞吐翻倍）',
        (tester) async {
      final h =
          await _pumpInboxAnimated(tester, [for (var i = 1; i <= 5; i++) _item(i)]);

      for (var i = 1; i <= 3; i++) {
        await tester.drag(_cardByBvid('BV$i'), const Offset(-300, 0)); // 左滑 = 跳过
        await tester.pump();
        // 只等到"交接点"就划下一张（每张之间的等待 = kDurAdvance）
        await tester.pump(kDurAdvance + const Duration(milliseconds: 20));
      }

      // 每张之间只等 kDurAdvance：如果交接没生效，第二、三次拖动会被 _busy 吞掉
      // → handled 里就不会有三条
      expect(h.service.handled, ['BV1', 'BV2', 'BV3'],
          reason: '三张都被判定掉了（没有一张被"手势被吞"挡掉）');

      // 第三张的幽灵还在飞（.last 此刻是它）→ 等它落地再看牌堆
      await tester.pumpAndSettle();
      expect(_topBvid(tester), 'BV4', reason: '第四张已经在顶上待命');
      expect(_deckOrder(tester), ['BV4', 'BV5']);
    });

    testWidgets('连续下滑两张（开动效）：第二张不被"队列只剩 1 张"挡掉（在飞的也算队列里的）',
        (tester) async {
      final h = await _pumpInboxAnimated(tester, [_item(1), _item(2)]);

      await tester.drag(_cardByBvid('BV1'), const Offset(0, 300)); // 稍后
      await tester.pump();
      await tester.pump(kDurAdvance + const Duration(milliseconds: 20)); // 交接
      // 此刻 _items 里只剩 BV2（BV1 还在飞）：队列长度必须把幽灵算上，
      // 否则这次下滑会被判成"推到队尾 = 原地打转"而拒绝执行
      await tester.drag(_cardByBvid('BV2'), const Offset(0, 300)); // 稍后
      await tester.pump();
      await tester.pumpAndSettle();

      expect(h.service.handled, isEmpty, reason: '稍后不是判定');
      expect(_deckOrder(tester), ['BV1', 'BV2'],
          reason: '两张都推到了队尾（队列转了一圈）—— 旧实现在这里会拒绝第二张');
    });

    testWidgets('上滑取回：锁输入 ≤ 250ms（第一步 kDurQuick），滑入途中可被手指接管',
        (tester) async {
      await _pumpInboxAnimated(tester, [for (var i = 1; i <= 3; i++) _item(i)]);

      // 先把 BV1「稍后」推走 → 有可取的卡
      await tester.drag(_topCard(), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(_topBvid(tester), 'BV2');

      // 上滑 = 取回
      await tester.drag(_topCard(), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_deckOrder(tester).first, 'BV2',
          reason: '第一步（手上这张让位）还没走完：队首仍是 BV2');

      // 累计 140ms ≥ kDurQuick(120ms) → 取回已经生效（≤ 250ms 的硬要求）
      await tester.pump(const Duration(milliseconds: 100));
      expect(_deckOrder(tester).first, 'BV1',
          reason: '取回必须在 250ms 内生效（旧实现要等第一步 200ms 走完）');

      // 第二步（被取回的那张从下方滑入）不锁输入：手指落下就能接管
      expect(find.byKey(const ValueKey<String>('inbox.ghost:BV1')), findsNothing,
          reason: '取回的那张是顶卡（从下方滑入），不是幽灵');
      // 再等 100ms：BV1 从下方滑入了一点，卡片中心进到屏内（否则手势点落在
      // 屏幕外、根本送不到卡片上，测不出能不能接管）
      await tester.pump(const Duration(milliseconds: 100));
      final before = tester.getTopLeft(_cardByBvid('BV1')).dy;
      final rect = tester.getRect(_cardByBvid('BV1'));
      final gesture = await tester.startGesture(
        Offset(rect.center.dx, rect.center.dy.clamp(60.0, 854.0)),
      );
      await gesture.moveBy(const Offset(0, -60)); // 第一次移动被 touch slop 吃掉
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(tester.getTopLeft(_cardByBvid('BV1')).dy, lessThan(before - 20),
          reason: '滑入途中手指落下即可接管（[_takeOverBackAnimation]）');
      await gesture.up();
      await _flush(tester);
      expect(_deckOrder(tester), ['BV1', 'BV2', 'BV3'], reason: '接管后队列不变');
    });

    testWidgets('撤销可连撤（栈）：连划两张后连按两次撤销，逐张退回队首',
        (tester) async {
      final h = await _pumpInbox(tester, [_item(1), _item(2), _item(3)]);

      await tester.drag(_topCard(), const Offset(-300, 0)); // BV1 跳过
      await _flush(tester);
      await tester.drag(_topCard(), const Offset(-300, 0)); // BV2 跳过
      await _flush(tester);
      expect(_deckOrder(tester), ['BV3']);

      await tester.tap(find.byTooltip('撤销'));
      await _flush(tester);
      expect(h.service.unhandled, ['BV2'], reason: 'LIFO：先退回最近判定掉的那张');
      expect(_deckOrder(tester), ['BV2', 'BV3']);

      // ★ 旧实现是单张撤销位 → 这里按钮已经禁用；现在可连撤
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
            .onPressed,
        isNotNull,
        reason: '撤销栈里还有 BV1 → 按钮必须仍可用',
      );
      await tester.tap(find.byTooltip('撤销'));
      await _flush(tester);
      expect(h.service.unhandled, ['BV2', 'BV1']);
      expect(_deckOrder(tester), ['BV1', 'BV2', 'BV3'], reason: '两张都退回来了');
    });
  });

  // -------------------------------------------------------------------------
  // 连续右滑的 Gist 写必须串行（解锁输入之后才出现的并发风险）
  // -------------------------------------------------------------------------
  group('连续右滑：Gist 写串行化', () {
    testWidgets('连续两张右滑 → 同一时刻只有一次「读整份 → 写整份」在飞，两条都保住',
        (tester) async {
      MotionControl.enabled = true;
      _usePortraitPhone(tester);
      final service = _FakeInboxService([_item(1), _item(2), _item(3)]);
      final api = _FakeBiliApi();
      final github = _SerialGithubApi(delay: const Duration(milliseconds: 200));
      ServiceLocator.overrideInboxService(service);
      ServiceLocator.overrideSyncService(_FakeSyncService());
      await tester.pumpWidget(MaterialApp(
        home: InboxPage(
          api: api,
          writer: WhitelistWriter(github: github, api: api),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // 第一张右滑（加入）：Gist 读改写开始（一次要 200ms×2）
      await tester.drag(_cardByBvid('BV1'), const Offset(300, 0));
      await tester.pump();
      // 只等到交接点（此刻第一张的 Gist 写还在飞）就划第二张
      await tester.pump(kDurAdvance + const Duration(milliseconds: 20));
      await tester.drag(_cardByBvid('BV2'), const Offset(300, 0));
      await tester.pump();

      // 让排队与在飞的写全部跑完
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      expect(github.maxInFlight, 1,
          reason: '同一时刻只能有一次「GET 整份 → 查重 → PATCH 整份」在飞 —— '
              '两次并行会各自基于同一份旧快照 PATCH，后一次把前一次覆盖掉');
      expect(github.data.videos.map((v) => v.bvid).toList(), ['BV1', 'BV2'],
          reason: '两次加入都要落进白名单（不丢更新）');
      expect(service.handled, ['BV1', 'BV2']);
      expect(_deckOrder(tester), ['BV3']);
    });
  });
}
