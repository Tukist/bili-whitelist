// computeCollectionStats / loadCollectionStats 单元测试
// （lib/services/collection_stats.dart）：
// - 已看集数（同 bvid 多集去重、跨视频累加）
// - 总集数 = Σ pageCount
// - 最近更新时间：pubdate 取最大；全无 pubdate 回退 addedAt（fromPubdate=false）
// - 空合集（声明了但没视频）/ 未分类 '' / 未声明的脏合集名
// - 脏数据容错：bvid 大小写与空白、白名单外历史、越界 pageIndex、
//   空 bvid、脏 addedAt、脏 pubdate
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/collection_stats.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

WhitelistVideo _v(
  String bvid, {
  String collection = '',
  List<String> parts = const [],
  int? pubdate,
  String addedAt = '2024-01-01T00:00:00.000',
}) => WhitelistVideo(
  bvid: bvid,
  cid: 100,
  title: '视频 $bvid',
  cover: '',
  duration: 60,
  upName: 'UP主',
  addedAt: addedAt,
  collection: collection,
  pubdate: pubdate,
  pages: parts.isEmpty
      ? null
      : [
          for (var i = 0; i < parts.length; i++)
            PageInfo(cid: 100 + i, part: parts[i], duration: 30),
        ],
);

HistoryEntry _h(String bvid, int pageIndex) => HistoryEntry(
  bvid: bvid,
  pageIndex: pageIndex,
  cid: 100 + pageIndex,
  title: '视频 $bvid',
  cover: '',
  upName: 'UP主',
  durationMs: 60000,
  positionMs: 10000,
  watchedAt: DateTime(2026, 9, 1, 12, 0, 0),
);

WhitelistData _data(
  List<WhitelistVideo> videos, [
  List<String> collections = const [],
]) => WhitelistData(
  version: 4,
  updatedAt: '',
  videos: videos,
  collections: [
    for (final name in collections)
      CollectionInfo(name: name, createdAt: '2024-01-01T00:00:00.000'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('已看 / 总集数', () {
    test('总集数 = Σ pageCount（多 P 按 P 数、单 P 按 1）', () {
      final data = _data([
        _v('BV1', collection: 'A', parts: ['P1', 'P2', 'P3']),
        _v('BV2', collection: 'A'),
      ]);

      final stats = computeCollectionStats(data, const []);
      expect(stats['A']!.total, 4);
      expect(stats['A']!.watched, 0);
      expect(stats['A']!.unwatched, isTrue);
    });

    test('已看集数：同 bvid 多集各算一集，重复看不重复计数', () {
      final data = _data([
        _v('BV1', collection: 'A', parts: ['P1', 'P2', 'P3']),
        _v('BV2', collection: 'A'),
      ]);
      final history = [
        _h('BV1', 0),
        _h('BV1', 1),
        _h('BV1', 0), // 重复看第 1 集 → 仍只算一集
        _h('BV2', 0),
      ];

      final stats = computeCollectionStats(data, history);
      expect(stats['A']!.watched, 3); // BV1:P1 / BV1:P2 / BV2:P1
      expect(stats['A']!.total, 4);
      expect(stats['A']!.unwatched, isFalse);
    });

    test('未分类（collection 空串）单独成组，key = 空串', () {
      final data = _data([
        _v('BV1', collection: 'A'),
        _v('BV2'), // 未分类
      ]);
      final stats = computeCollectionStats(data, [_h('BV2', 0)]);

      expect(stats['']!.watched, 1);
      expect(stats['']!.total, 1);
      expect(stats['A']!.watched, 0);
    });

    test('空合集：声明了但一条视频都没有 → 0 / 0，无更新时间', () {
      final data = _data([_v('BV1', collection: 'A')], ['A', '空合集']);

      final stats = computeCollectionStats(data, const []);
      expect(stats['空合集']!.watched, 0);
      expect(stats['空合集']!.total, 0);
      expect(stats['空合集']!.updatedAt, isNull);
      expect(stats['空合集']!.fromPubdate, isFalse);
    });

    test('空数据（无视频无合集）→ 空 map', () {
      expect(computeCollectionStats(_data(const []), const []), isEmpty);
    });
  });

  group('最近更新时间', () {
    test('有 pubdate → 取最大，fromPubdate = true', () {
      final data = _data([
        _v('BV1', collection: 'A', pubdate: 1700000000),
        _v('BV2', collection: 'A', pubdate: 1730000000),
        _v('BV3', collection: 'A', pubdate: 1710000000),
      ]);

      final stat = computeCollectionStats(data, const [])['A']!;
      expect(stat.fromPubdate, isTrue);
      expect(
        stat.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1730000000 * 1000),
      );
    });

    test('部分有 pubdate → 只用有 pubdate 的那部分（不混 addedAt）', () {
      final data = _data([
        _v('BV1', collection: 'A', pubdate: 1700000000),
        _v('BV2', collection: 'A', addedAt: '2030-01-01T00:00:00.000'),
      ]);

      final stat = computeCollectionStats(data, const [])['A']!;
      expect(stat.fromPubdate, isTrue);
      expect(
        stat.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });

    test('全无 pubdate → 回退 max(addedAt)，fromPubdate = false', () {
      final data = _data([
        _v('BV1', collection: 'A', addedAt: '2024-01-01T00:00:00.000'),
        _v('BV2', collection: 'A', addedAt: '2024-05-01T00:00:00.000'),
        _v('BV3', collection: 'A', addedAt: '2024-03-01T00:00:00.000'),
      ]);

      final stat = computeCollectionStats(data, const [])['A']!;
      expect(stat.fromPubdate, isFalse);
      expect(stat.updatedAt, DateTime(2024, 5, 1));
    });

    test('pubdate 是脏值（<= 0）→ 当作没有，回退 addedAt', () {
      final data = _data([
        _v('BV1', collection: 'A', pubdate: 0, addedAt: '2024-02-02T00:00:00.000'),
        _v('BV2', collection: 'A', pubdate: -1, addedAt: '2024-01-01T00:00:00.000'),
      ]);

      final stat = computeCollectionStats(data, const [])['A']!;
      expect(stat.fromPubdate, isFalse);
      expect(stat.updatedAt, DateTime(2024, 2, 2));
    });

    test('addedAt 全脏（空串 / 非法）→ updatedAt = null', () {
      final data = _data([
        _v('BV1', collection: 'A', addedAt: ''),
        _v('BV2', collection: 'A', addedAt: '不是时间'),
      ]);

      final stat = computeCollectionStats(data, const [])['A']!;
      expect(stat.updatedAt, isNull);
      expect(stat.fromPubdate, isFalse);
    });
  });

  group('脏数据容错', () {
    test('bvid 大小写 / 空白归一化后仍能对上（不整块漏计）', () {
      final data = _data([_v('BV1xx411c7mD', collection: 'A')]);
      final history = [_h(' bv1XX411C7MD ', 0)];

      final stat = computeCollectionStats(data, history)['A']!;
      expect(stat.watched, 1);
    });

    test('白名单外的历史不计入任何合集', () {
      final data = _data([_v('BV1', collection: 'A')]);

      final stats = computeCollectionStats(data, [_h('BV_OTHER', 0)]);
      expect(stats['A']!.watched, 0);
    });

    test('空 bvid 的历史 / 视频被跳过，不崩', () {
      final data = _data([
        _v('', collection: 'A'),
        _v('BV1', collection: 'A'),
      ]);

      final stats = computeCollectionStats(data, [_h('', 0), _h('BV1', 0)]);
      expect(stats['A']!.watched, 1);
      expect(stats['A']!.total, 2);
    });

    test('越界 pageIndex（历史陈旧）不计入，保证 watched <= total', () {
      final data = _data([_v('BV1', collection: 'A')]); // 单 P

      final stats =
          computeCollectionStats(data, [_h('BV1', 0), _h('BV1', 7), _h('BV1', -1)]);
      expect(stats['A']!.watched, 1);
      expect(stats['A']!.total, 1);
    });

    test('视频引用了未声明的合集名 → 也统计出来（脏数据宽容）', () {
      final data = _data([_v('BV1', collection: '已删掉的合集')]);

      final stats = computeCollectionStats(data, const []);
      expect(stats.containsKey('已删掉的合集'), isTrue);
      expect(stats['已删掉的合集']!.total, 1);
    });

    test('同一 bvid 出现在两个合集 → 只归第一个，不重复计数', () {
      final data = _data([
        _v('BV1', collection: 'A'),
        _v('BV1', collection: 'B'),
      ]);

      final stats = computeCollectionStats(data, [_h('BV1', 0)]);
      expect(stats['A']!.watched, 1);
      expect(stats['B']!.watched, 0);
    });

    test('history 为空 → 全 0，不影响 total 统计', () {
      final data = _data([
        _v('BV1', collection: 'A', parts: ['P1', 'P2']),
      ]);

      final stats = computeCollectionStats(data, const []);
      expect(stats['A']!.watched, 0);
      expect(stats['A']!.total, 2);
    });
  });

  group('loadCollectionStats（读 HistoryStore 的便捷入口）', () {
    test('与 computeCollectionStats 用同一份历史，结果一致', () async {
      SharedPreferences.setMockInitialValues({});
      final data = _data([
        _v('BV1', collection: 'A', parts: ['P1', 'P2']),
        _v('BV2', collection: 'A'),
      ]);
      await HistoryStore.instance.addOrUpdate(_h('BV1', 0));
      await HistoryStore.instance.addOrUpdate(_h('BV1', 1));

      final loaded = await loadCollectionStats(data);
      final direct = computeCollectionStats(
        data,
        await HistoryStore.instance.getAll(),
      );

      expect(loaded['A']!.watched, direct['A']!.watched);
      expect(loaded['A']!.watched, 2);
      expect(loaded['A']!.total, 3);
    });

    test('存储为空 → 已看全 0', () async {
      SharedPreferences.setMockInitialValues({});
      final data = _data([_v('BV1', collection: 'A')]);

      final stats = await loadCollectionStats(data);
      expect(stats['A']!.watched, 0);
      expect(stats['A']!.total, 1);
    });
  });
}
