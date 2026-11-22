// 推荐页 widget 测试：
// - 空历史 → 「先看几个视频…」空态；空态在 RefreshIndicator 下必须 scrollable
// - 有数据 → 热力球 / 交叉区 / 列表三块都渲染
// - 点气泡 → 按标签筛选，再点取消
// - 「换一批」→ 用 force 重算
// - 点卡片 → 先 fetchVideoMeta 补元数据，再 push 播放页（只播，不写白名单）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/search_result.dart';
import 'package:bili_whitelist_app/pages/recommend_page.dart';
import 'package:bili_whitelist_app/services/recommend_service.dart';
import 'package:bili_whitelist_app/theme/route_names.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';

/// 只记账的 B 站接口替身：点卡片要走的 view 接口在这里被拦下，
/// 既证明"请求发生过"，也不用真的构造播放器所需的原生通道。
class _RecordingApi extends BiliApi {
  final List<String> metaBvids = [];

  @override
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    metaBvids.add(bvid);
    return {
      'bvid': bvid,
      'cid': 4242,
      'title': '补全标题',
      'duration': 300,
      'owner': {'name': '真UP主'},
      'stat': {'view': 1234},
      'pages': [
        {'cid': 4242, 'part': 'P1', 'duration': 300},
      ],
    };
  }
}

/// 固定 feed 的服务替身（不触网、不读历史）。
class _StubService extends RecommendService {
  _StubService(this.feed);

  final RecommendFeed feed;
  final List<bool> forceCalls = [];

  @override
  Future<RecommendFeed> buildFeed({bool force = false}) async {
    forceCalls.add(force);
    return feed;
  }
}

SearchResult _video(String bvid, String title, {int pubDate = 0}) =>
    SearchResult(
      bvid: bvid,
      title: title,
      cover: '',
      author: 'UP 主',
      durationSec: 300,
      playCount: 12345,
      pubDate: pubDate,
    );

RecommendItem _item(String bvid, String title, Set<String> tags) =>
    RecommendItem(video: _video(bvid, title), hitTags: tags, score: 0.5);

RecommendFeed _feed() {
  final cross = [
    _item('BV3', '交叉视频', {'动画', '游戏'}),
  ];
  return RecommendFeed(
    hasHistory: true,
    fetchedAt: DateTime(2026, 11, 22, 12),
    tags: const [
      TagWeight(tag: '动画', weight: 1.0),
      TagWeight(tag: '游戏', weight: 0.6),
    ],
    items: [
      _item('BV1', '动画视频', {'动画'}),
      _item('BV2', '游戏视频', {'游戏'}),
      ...cross,
    ],
    crossings: [TagCrossing(a: '动画', b: '游戏', videos: cross)],
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required RecommendService service,
  BiliApi? api,
  List<NavigatorObserver> observers = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: observers,
      home: Scaffold(
        body: RecommendPage(service: service, api: api),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _PushSpy extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('空态', () {
    testWidgets('没有观看历史 → 「先看几个视频…」；空态在 RefreshIndicator 下可滚动', (tester) async {
      // 真服务 + 空 prefs：走"历史为空"的真实分支（不触网）
      await _pump(
        tester,
        service: RecommendService(
          api: _RecordingApi(),
          requestGap: Duration.zero,
          degradedGap: Duration.zero,
        ),
      );

      expect(find.text('先看几个视频，这里会生成你的兴趣标签'), findsOneWidget);
      // 外层是下拉刷新 → AppStateView 必须 scrollable（否则拉不动）
      expect(find.byType(RefreshIndicator), findsOneWidget);
      final state = tester.widget<AppStateView>(find.byType(AppStateView));
      expect(state.scrollable, isTrue);
    });

    testWidgets('有历史但池子空 → 「换一批」用 force 重算', (tester) async {
      final service = _StubService(
        const RecommendFeed(
          hasHistory: true,
          fetchedAt: null,
          tags: [TagWeight(tag: '动画', weight: 1.0)],
        ),
      );
      await _pump(tester, service: service);

      expect(find.text('这个标签下暂时没有没看过的视频了'), findsOneWidget);
      // 首屏那次不算 force
      expect(service.forceCalls, [false]);

      await tester.tap(find.text('换一批'));
      await tester.pumpAndSettle();
      expect(service.forceCalls.last, isTrue);
    });
  });

  group('内容', () {
    testWidgets('热力球 / 交叉区 / 列表三块都渲染，标题与副信息在位', (tester) async {
      await _pump(tester, service: _StubService(_feed()));

      expect(find.text('为你推荐'), findsOneWidget);
      expect(find.text('3 条'), findsOneWidget);
      expect(find.text('交叉区 · 同时命中两个标签'), findsOneWidget);
      // 气泡（按 key 找，避免与列表里的同名标签 chip 撞）
      expect(find.byKey(const ValueKey('recommend-tag-动画')), findsOneWidget);
      expect(find.byKey(const ValueKey('recommend-tag-游戏')), findsOneWidget);
      // 交叉 chip 带条数
      expect(find.text('动画 × 游戏 · 1 条'), findsOneWidget);
      // 卡片
      expect(find.text('动画视频'), findsOneWidget);
      expect(find.text('游戏视频'), findsOneWidget);
      expect(find.text('交叉视频'), findsOneWidget);
    });

    testWidgets('点气泡按标签筛选，再点一次取消', (tester) async {
      await _pump(tester, service: _StubService(_feed()));

      await tester.tap(find.byKey(const ValueKey('recommend-tag-动画')));
      await tester.pumpAndSettle();

      expect(find.text('动画视频'), findsOneWidget);
      expect(find.text('交叉视频'), findsOneWidget);
      expect(find.text('游戏视频'), findsNothing);
      expect(find.text('2 条'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('recommend-tag-动画')));
      await tester.pumpAndSettle();
      expect(find.text('游戏视频'), findsOneWidget);
      expect(find.text('3 条'), findsOneWidget);
    });

    testWidgets('卡片副信息分两行：作者·时长 / 播放·日期（日期完整不截断）', (tester) async {
      final recent = DateTime.now().subtract(const Duration(days: 2));
      final feed = RecommendFeed(
        hasHistory: true,
        tags: const [TagWeight(tag: '动画', weight: 1.0)],
        items: [
          RecommendItem(
            video: _video(
              'BV1',
              '动画视频',
              pubDate: recent.millisecondsSinceEpoch ~/ 1000,
            ),
            hitTags: const {'动画'},
            score: 0.5,
          ),
        ],
      );
      await _pump(tester, service: _StubService(feed));

      expect(find.text('UP 主 · 5:00'), findsOneWidget);
      expect(find.text('1.2万 播放 · 2 天前'), findsOneWidget);
    });

    testWidgets('点交叉 chip 只留同时命中两个标签的视频', (tester) async {
      await _pump(tester, service: _StubService(_feed()));

      await tester.tap(find.byKey(const ValueKey('recommend-cross-动画-游戏')));
      await tester.pumpAndSettle();

      expect(find.text('交叉视频'), findsOneWidget);
      expect(find.text('动画视频'), findsNothing);
      expect(find.text('游戏视频'), findsNothing);
    });
  });

  group('点卡片 → 播放', () {
    testWidgets('先补元数据（view 接口）再 push 播放页，路由名用 player', (tester) async {
      final api = _RecordingApi();
      final spy = _PushSpy();
      final service = _StubService(
        RecommendFeed(
          hasHistory: true,
          fetchedAt: DateTime(2026, 11, 22, 12),
          tags: const [TagWeight(tag: '动画', weight: 1.0)],
          items: [
            _item('BV1', '动画视频', {'动画'}),
          ],
        ),
      );
      await _pump(tester, service: service, api: api, observers: [spy]);
      spy.pushed.clear(); // 首页那条路由也是 push 进来的

      await tester.tap(find.byKey(const ValueKey('recommend-item-BV1')));
      // ⚠ 刻意不 pump：push 已发生，但新路由还没被建（真建会拉起播放器原生通道）

      expect(api.metaBvids, ['BV1'], reason: '搜索结果只有 bvid，必须补 cid/标题');
      final route = spy.pushed.single as MaterialPageRoute<void>;
      expect(route.settings.name, kPlayerRouteName);
    });
  });

  group('热力球布局（纯函数）', () {
    // Pixel 7 竖屏：411dp 宽 − 左右各 24 的页边距 = 387；
    // 热力区 160 − 顶部 12 的让位内边距 = 148
    const canvas = Size(387, 148);

    test('固定权重 → 任意两球圆心距 ≥ 两半径之和（且不重叠）', () {
      final radii = [
        for (final w in [1.0, 0.82, 0.61, 0.4, 0.2]) bubbleRadiusForWeight(w),
      ];
      final layout = layoutBubbles(radii: radii, size: canvas);

      expect(layout.centers.length, radii.length);
      expect(layout.overlaps, isFalse, reason: '411dp 宽的正常屏不该退化到重叠');
      // 放得下就不缩半径：原样使用
      for (var i = 0; i < radii.length; i++) {
        expect(layout.radii[i], closeTo(radii[i], 1e-9));
      }
      for (var i = 0; i < layout.centers.length; i++) {
        for (var j = i + 1; j < layout.centers.length; j++) {
          expect(
            (layout.centers[i] - layout.centers[j]).distance,
            greaterThanOrEqualTo(layout.radii[i] + layout.radii[j]),
            reason: '第 $i 与第 $j 颗球的圆相交了',
          );
        }
      }
    });

    test('布局确定性：同一组半径两次结果完全一致', () {
      final radii = [
        for (final w in [1.0, 0.8, 0.6, 0.4, 0.2]) bubbleRadiusForWeight(w),
      ];
      final a = layoutBubbles(radii: radii, size: canvas);
      final b = layoutBubbles(radii: radii, size: canvas);
      expect(a.centers, b.centers);
      expect(a.radii, b.radii);
      expect(a.overlaps, b.overlaps);
    });

    test('缩半径路径：半径整体缩放但不低于最小半径，且球仍在画布内', () {
      // 10 颗满权重球（直径 76）塞进 160×120：原尺寸必然放不下 → 走缩放
      final radii = List<double>.filled(10, bubbleRadiusForWeight(1));
      const tight = Size(160, 120);
      final layout = layoutBubbles(radii: radii, size: tight);

      expect(layout.radii.length, 10);
      for (var i = 0; i < layout.radii.length; i++) {
        expect(
          layout.radii[i],
          greaterThanOrEqualTo(kRecommendBubbleMinRadius - 1e-9),
          reason: '缩半径不许突破最小半径',
        );
        expect(layout.radii[i], lessThanOrEqualTo(radii[i]));
        final r = layout.radii[i];
        final c = layout.centers[i];
        expect(c.dx, greaterThanOrEqualTo(r - 1e-6));
        expect(c.dx, lessThanOrEqualTo(tight.width - r + 1e-6));
        expect(c.dy, greaterThanOrEqualTo(r - 1e-6));
        expect(c.dy, lessThanOrEqualTo(tight.height - r + 1e-6));
      }
      expect(layout.overlaps, isTrue, reason: '10 颗直径 76 的球塞 160×120 必然放不下');
    });

    test('缩半径后放得下 → 不重叠（overlaps=false）', () {
      // 3 颗满权重球塞 200×148：原尺寸塞不下，缩档后能排开
      final radii = List<double>.filled(3, bubbleRadiusForWeight(1));
      final layout = layoutBubbles(radii: radii, size: const Size(200, 148));

      expect(layout.overlaps, isFalse);
      expect(layout.radii.first, lessThan(radii.first), reason: '应该走过缩半径');
      expect(layout.radii.first, greaterThanOrEqualTo(kRecommendBubbleMinRadius));
      for (var i = 0; i < layout.centers.length; i++) {
        for (var j = i + 1; j < layout.centers.length; j++) {
          expect(
            (layout.centers[i] - layout.centers[j]).distance,
            greaterThanOrEqualTo(layout.radii[i] + layout.radii[j]),
          );
        }
      }
    });
  });

  group('formatPubdateShort（副信息日期短格式）', () {
    final now = DateTime(2026, 11, 22, 12);
    int ts(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

    test('7 天内 → N 天前（边界 7 天仍在窗口内）', () {
      expect(
        formatPubdateShort(ts(now.subtract(const Duration(days: 3))), now: now),
        '3 天前',
      );
      expect(
        formatPubdateShort(ts(now.subtract(const Duration(days: 7))), now: now),
        '7 天前',
      );
      expect(
        formatPubdateShort(ts(now.subtract(const Duration(hours: 5))), now: now),
        '5 小时前',
      );
      expect(
        formatPubdateShort(
          ts(now.subtract(const Duration(minutes: 20))),
          now: now,
        ),
        '刚刚',
      );
    });

    test('同年 → M月D日', () {
      expect(formatPubdateShort(ts(DateTime(2026, 9, 2)), now: now), '9月2日');
      expect(
        formatPubdateShort(ts(now.subtract(const Duration(days: 8))), now: now),
        '11月14日',
        reason: '超出一周窗口 → 同年日期',
      );
    });

    test('跨年 → YYYY-MM-DD', () {
      expect(
        formatPubdateShort(ts(DateTime(2025, 9, 2, 8)), now: now),
        '2025-09-02',
      );
    });

    test('pubDate <= 0 → 空串（整段不显示，不摆占位）', () {
      expect(formatPubdateShort(0, now: now), '');
      expect(formatPubdateShort(-5, now: now), '');
    });
  });
}
