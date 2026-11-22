// 推荐服务单测：纯函数（权重/打分/交叉分组）+ 网络编排（合并/剔除/TTL/缓存/失败）。
//
// 全部不触网：BiliApi 用子类替身；高分/低分只断言相对关系，不钉具体小数。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/search_result.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/services/recommend_service.dart';

/// 固定"现在"，所有时间断言都相对它算，避免跨日/跨机器漂移。
final DateTime _now = DateTime(2026, 11, 22, 12);

HistoryEntry _entry(
  String bvid, {
  int pageIndex = 0,
  required DateTime watchedAt,
  int durationMs = 0,
  int positionMs = 0,
}) => HistoryEntry(
  bvid: bvid,
  pageIndex: pageIndex,
  cid: 100 + pageIndex,
  title: '视频 $bvid',
  cover: '',
  upName: 'UP',
  durationMs: durationMs,
  positionMs: positionMs,
  watchedAt: watchedAt,
);

SearchResult _video(String bvid, {int playCount = 10000, int pubDate = 0}) =>
    SearchResult(
      bvid: bvid,
      title: '视频 $bvid',
      cover: '',
      author: 'UP',
      durationSec: 300,
      playCount: playCount,
      pubDate: pubDate,
    );

int _secAgo({int days = 0}) =>
    _now.subtract(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;

/// 假 B 站接口：标签表 + 搜索结果表可配；两个方法都记账，便于断言"有没有发"。
class _FakeBiliApi extends BiliApi {
  _FakeBiliApi({
    this.tags = const {},
    this.search = const {},
    this.tagError,
    this.tagFailBvid,
    this.searchErrorCode = 0,
  });

  /// bvid → 标签。
  final Map<String, List<String>> tags;

  /// `'标签|order'` → 结果列表。
  final Map<String, List<SearchResult>> search;

  /// fetchVideoTags 要抛的异常（null → 正常返回）。
  final BiliApiException? tagError;

  /// 只对这个 bvid 抛 [tagError]（验"前面拉到的一半也要落盘"）。
  final String? tagFailBvid;

  /// 非 0 → searchVideo 一律抛这个码（验风控退化）。
  final int searchErrorCode;

  final List<String> tagCalls = [];
  final List<String> searchCalls = [];

  @override
  Future<List<String>> fetchVideoTags(String bvid) async {
    tagCalls.add(bvid);
    final e = tagError;
    if (e != null && (tagFailBvid == null || tagFailBvid == bvid)) throw e;
    return tags[bvid] ?? const [];
  }

  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async {
    searchCalls.add('$keyword|$order');
    if (searchErrorCode != 0) {
      throw BiliApiException(
        code: searchErrorCode,
        message: '风控',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    final results = search['$keyword|$order'] ?? const <SearchResult>[];
    return SearchPageResult(
      results: results,
      totalCount: results.length,
      hasMore: false,
    );
  }
}

RecommendService _service(_FakeBiliApi api) => RecommendService(
  api: api,
  // 测试里不真等 1.5s/3s
  requestGap: Duration.zero,
  degradedGap: Duration.zero,
  now: () => _now,
);

Future<void> _seedHistory(List<HistoryEntry> entries) async {
  for (final e in entries) {
    await HistoryStore.instance.addOrUpdate(e);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('computeBvidWeights', () {
    test('14 天半衰 + 完播率钳制 + 同一 bvid 只算一次 + 非 BV 过滤', () {
      final weights = computeBvidWeights([
        // 刚看完 → 1.0
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
        // 14 天前 → 衰减一半；没有时长信息就不算完播率
        _entry('BV2', watchedAt: _now.subtract(const Duration(days: 14))),
        // 点开就退（5%）→ 钳到下界 0.2
        _entry('BV3', watchedAt: _now, durationMs: 1000, positionMs: 50),
        // 同 bvid 的另一分 P（28 天前）不参与：只认最近那次
        _entry(
          'BV3',
          pageIndex: 1,
          watchedAt: _now.subtract(const Duration(days: 28)),
          durationMs: 1000,
          positionMs: 1000,
        ),
        // 老格式 aid 条目直接忽略
        _entry('av123', watchedAt: _now),
      ], _now);

      expect(weights.keys, ['BV1', 'BV2', 'BV3']);
      expect(weights['BV1'], closeTo(1.0, 1e-9));
      expect(weights['BV2'], closeTo(0.5, 1e-3));
      expect(weights['BV3'], closeTo(0.2, 1e-9));
    });

    test('positionMs == 0（远程历史写成 0）也走完播率夹取，拿到下界 0.2', () {
      final weights = computeBvidWeights([
        // 远程历史 progressSec <= 0 → positionMs: 0，但时长仍 > 0
        _entry('BVzero', watchedAt: _now, durationMs: 1000, positionMs: 0),
        // 对照组：同一时刻看完
        _entry('BVfull', watchedAt: _now, durationMs: 1000, positionMs: 1000),
      ], _now);

      expect(weights['BVzero'], closeTo(0.2, 1e-9));
      expect(weights['BVfull'], closeTo(1.0, 1e-9));
      // 同一 watchedAt → 衰减相同，权重比 = 完播率比 = 5:1
      expect(weights['BVfull']! / weights['BVzero']!, closeTo(5.0, 1e-9));
    });
  });

  group('computeTagWeights', () {
    test('按标签聚合后归一化到 0..1，并按权重降序', () {
      final entries = [
        _entry(
          'BV1',
          watchedAt: _now,
          durationMs: 1000,
          positionMs: 1000,
        ), // 1.0
        _entry(
          'BV2',
          watchedAt: _now.subtract(const Duration(days: 14)),
        ), // 0.5
        _entry('BV3', watchedAt: _now, durationMs: 1000, positionMs: 50), // 0.2
      ];
      final weights = computeTagWeights(
        entries,
        _now,
        tagsByBvid: {
          'BV1': ['动画'],
          'BV2': ['动画', '日常'],
          'BV3': ['日常'],
        },
      );

      // 动画 = 1.0 + 0.5 = 1.5；日常 = 0.5 + 0.2 = 0.7
      expect(weights.keys.toList(), ['动画', '日常']);
      expect(weights['动画'], closeTo(1.0, 1e-9));
      expect(weights['日常'], closeTo(0.7 / 1.5, 1e-6));
    });

    test('没有标签 → 空表（推荐页据此走"没标签"空态）', () {
      expect(
        computeTagWeights([_entry('BV1', watchedAt: _now)], _now),
        isEmpty,
      );
    });
  });

  group('scoreRecommendation', () {
    test('播放量单调：同标签同时刻，播放多的分更高', () {
      final low = scoreRecommendation(
        tagWeight: 0.8,
        playCount: 1000,
        pubDateSec: _secAgo(days: 3),
        now: _now,
      );
      final high = scoreRecommendation(
        tagWeight: 0.8,
        playCount: 5000000,
        pubDateSec: _secAgo(days: 3),
        now: _now,
      );
      expect(high, greaterThan(low));
    });

    test('时间单调：同标签同播放，新发布的分更高', () {
      final fresh = scoreRecommendation(
        tagWeight: 0.8,
        playCount: 100000,
        pubDateSec: _secAgo(days: 1),
        now: _now,
      );
      final old = scoreRecommendation(
        tagWeight: 0.8,
        playCount: 100000,
        pubDateSec: _secAgo(days: 730),
        now: _now,
      );
      expect(fresh, greaterThan(old));
    });

    test('pubDate 缺失（<=0）记 0.3：比极旧的高、比新的低', () {
      double score(int pubdate) => scoreRecommendation(
        tagWeight: 0.5,
        playCount: 100000,
        pubDateSec: pubdate,
        now: _now,
      );
      expect(score(0), greaterThan(score(_secAgo(days: 365 * 5))));
      expect(score(0), lessThan(score(_secAgo(days: 0))));
    });
  });

  group('buildCrossings', () {
    RecommendItem item(String bvid, List<String> tags) =>
        RecommendItem(video: _video(bvid), hitTags: tags.toSet(), score: 0.5);

    test('只保留 ≥2 条视频的标签对；标签对内部排序；最多 3 组', () {
      final items = [
        item('BV1', ['B', 'A']),
        item('BV2', ['A', 'B']),
        item('BV3', ['C', 'D']),
        item('BV4', ['A', 'C']), // A×C 只有 1 条 → 不成组
        item('BV5', ['C', 'D']),
      ];
      final crossings = buildCrossings(items);
      expect(crossings.length, 2);
      expect(crossings.first.a, 'A');
      expect(crossings.first.b, 'B');
      expect(crossings.first.videos.map((i) => i.video.bvid), ['BV1', 'BV2']);
      expect(crossings.last.a, 'C');
      expect(crossings.last.b, 'D');
    });

    test('最多 3 组：视频数降序优先', () {
      // A×B 3 条、A×C 2 条、A×D 2 条、A×E 2 条 → 取前 3
      final items = [
        for (var i = 0; i < 3; i++) item('BVb$i', ['A', 'B']),
        for (var i = 0; i < 2; i++) item('BVc$i', ['A', 'C']),
        for (var i = 0; i < 2; i++) item('BVd$i', ['A', 'D']),
        for (var i = 0; i < 2; i++) item('BVe$i', ['A', 'E']),
      ];
      final crossings = buildCrossings(items);
      expect(crossings.length, 3);
      expect(crossings.first.videos.length, 3);
      expect(crossings.first.b, 'B');
    });
  });

  group('RecommendService.buildFeed', () {
    test('合并两路搜索结果去重 + 剔除已看 + 命中标签集合', () async {
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
      ]);
      final api = _FakeBiliApi(
        tags: {
          'BV1': ['动画'],
        },
        search: {
          '动画|click': [_video('BV1'), _video('BV2'), _video('BV3')],
          '动画|pubdate': [_video('BV3'), _video('BV4')],
        },
      );

      final feed = await _service(api).buildFeed();

      expect(feed.error, isNull);
      expect(feed.hasHistory, isTrue);
      expect(feed.tags.map((t) => t.tag), ['动画']);
      expect(
        feed.items.map((i) => i.video.bvid).toSet(),
        {'BV2', 'BV3', 'BV4'},
        reason: 'BV1 已看过 → 不出现；BV3 两路都有 → 只留一条',
      );
      expect(feed.items.length, 3);
      for (final item in feed.items) {
        expect(item.hitTags, {'动画'});
      }
    });

    test('TTL：30 分钟内再构建不再发请求；force 才重算', () async {
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
      ]);
      final api = _FakeBiliApi(
        tags: {
          'BV1': ['动画'],
        },
        search: {
          '动画|click': [_video('BV2')],
          '动画|pubdate': [_video('BV3')],
        },
      );
      final service = _service(api);

      await service.buildFeed();
      final callsAfterFirst = api.searchCalls.length;
      final tagCallsAfterFirst = api.tagCalls.length;
      // 「上次构建时间」落到 prefs（key = recommend:last_fetch_at）
      expect(await service.readLastFetchAt(), _now);

      await service.buildFeed();
      expect(api.searchCalls.length, callsAfterFirst, reason: 'TTL 内不该再搜');
      expect(api.tagCalls.length, tagCallsAfterFirst, reason: '标签也不该再拉');

      await service.buildFeed(force: true);
      expect(
        api.searchCalls.length,
        greaterThan(callsAfterFirst),
        reason: 'force 必须绕过 TTL',
      );
    });

    test('标签缓存命中：同一个 bvid 不发 tag 请求', () async {
      // 先铺缓存再写历史：setMockInitialValues 会清空整份 prefs
      SharedPreferences.setMockInitialValues({
        RecommendService.kTagCachePrefsKey:
            '{"__order":["BV1"],'
            '"BV1":["动画"]}',
      });
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
      ]);
      final api = _FakeBiliApi(
        search: {
          '动画|click': [_video('BV2')],
          '动画|pubdate': [_video('BV3')],
        },
      );

      final feed = await _service(api).buildFeed();

      expect(api.tagCalls, isEmpty, reason: '缓存命中就不该再打标签接口');
      expect(feed.tags.map((t) => t.tag), ['动画']);
      expect(feed.items, isNotEmpty);
    });

    test('标签接口失败 → 折成 error，不往外抛', () async {
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
      ]);
      final api = _FakeBiliApi(
        tagError: const BiliApiException(
          code: 62002,
          message: '稿件失效',
          path: '/x/tag/archive/tags',
        ),
      );

      final feed = await _service(api).buildFeed();

      expect(feed.error, isNotNull);
      expect(feed.items, isEmpty);
      expect(feed.loading, isFalse);
    });

    test('搜索被风控（-412）：跳过每个标签剩余请求，不报错也不死磕', () async {
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
        _entry('BV2', watchedAt: _now),
      ]);
      final api = _FakeBiliApi(
        tags: {
          'BV1': ['动画'],
          'BV2': ['游戏'],
        },
        searchErrorCode: -412,
      );

      final feed = await _service(api).buildFeed();

      expect(feed.error, isNull, reason: '风控不是致命错误，页面该给空态而不是错误页');
      expect(feed.items, isEmpty);
      // 两个标签各只发了 click 那一发（pubdate 被跳过）
      expect(api.searchCalls, ['动画|click', '游戏|click']);
    });

    test('空历史 → hasHistory=false，一个请求都不发', () async {
      final api = _FakeBiliApi();
      final feed = await _service(api).buildFeed();

      expect(feed.hasHistory, isFalse);
      expect(feed.items, isEmpty);
      expect(api.tagCalls, isEmpty);
      expect(api.searchCalls, isEmpty);
    });

    test('有历史但一个标签都没拿到 → 不写 last_fetch_at，下次仍会重试', () async {
      // 两个 bvid 都拿不到标签（接口抽风/风控刚过）
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
        _entry('BV2', watchedAt: _now, durationMs: 1000, positionMs: 1000),
      ]);
      final api = _FakeBiliApi();
      final service = _service(api);

      final feed = await service.buildFeed();

      expect(feed.hasHistory, isTrue);
      expect(feed.tags, isEmpty);
      expect(feed.error, isNull);
      expect(
        await service.readLastFetchAt(),
        isNull,
        reason: '这一支不缓存：不写 last_fetch_at',
      );

      // 空标签不进标签缓存 → 再构建一次仍会重新拉（不至于 30 分钟都干等）
      final tagCallsBefore = api.tagCalls.length;
      await service.buildFeed();
      expect(api.tagCalls.length, greaterThan(tagCallsBefore));
    });

    test('标签循环中段失败：已拿到的标签仍写回缓存（finally）', () async {
      await _seedHistory([
        _entry('BV1', watchedAt: _now, durationMs: 1000, positionMs: 1000),
        // 早 5 分钟看 → 排在 BV1 后面（保证 BV1 先被拉、BV2 才抛错）
        _entry(
          'BV2',
          watchedAt: _now.subtract(const Duration(minutes: 5)),
          durationMs: 1000,
          positionMs: 1000,
        ),
      ]);
      final api = _FakeBiliApi(
        tags: {
          'BV1': ['动画'],
        },
        tagError: const BiliApiException(
          code: 62002,
          message: '稿件失效',
          path: '/x/tag/archive/tags',
        ),
        tagFailBvid: 'BV2',
      );

      final feed = await _service(api).buildFeed();

      expect(feed.error, isNotNull);
      expect(api.tagCalls, ['BV1', 'BV2']);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(RecommendService.kTagCachePrefsKey) ?? '';
      expect(raw, contains('BV1'), reason: '失败前拉到的标签要落盘');
      expect(raw, contains('动画'));
    });
  });
}
