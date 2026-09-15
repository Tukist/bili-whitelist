// 合集管理逻辑单测（与 PC 端 whitelist.py collection rename/delete 语义一致）：
// - renameCollection：改 collections 名字 + 同步所有 videos.collection 引用；
//   新名非空、不与现有合集重名、旧名存在才允许；新旧名相同视为未改动
// - deleteCollection：移除合集定义 + 该合集下视频回未分类（不删除视频）
// - moveCollectionInto：「移动到其他合集」= 源合集整体并入目标（视频改挂目标 +
//   源定义删除 + 目标合集内 order 重排，并入的排到末尾）
// 纯 Dart 测试，无原生插件依赖。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';

WhitelistVideo _video(
  String bvid, {
  String collection = '',
  int order = 0,
  String addedAt = '2026-01-01T00:00:00Z',
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 100,
      title: '视频$bvid',
      cover: '',
      duration: 60,
      upName: 'up',
      addedAt: addedAt,
      collection: collection,
      order: order,
    );

WhitelistData _data({
  List<String> collections = const ['甲', '乙'],
  List<WhitelistVideo> videos = const [],
}) =>
    WhitelistData(
      version: 3,
      updatedAt: '2026-08-20T00:00:00Z',
      collections: [
        for (final n in collections)
          CollectionInfo(name: n, createdAt: '2026-08-01T00:00:00Z'),
      ],
      videos: videos,
    );

void main() {
  group('renameCollection', () {
    test('改 collections 名字 + 同步该合集下所有视频引用', () {
      final data = _data(videos: [
        _video('BV1', collection: '甲'),
        _video('BV2', collection: '甲'),
        _video('BV3', collection: '乙'),
        _video('BV4'), // 未分类
      ]);
      final next = renameCollection(data, '甲', '乙2');
      // collections 名字已改
      expect(next.collections.map((c) => c.name), ['乙2', '乙']);
      expect(next.collections.first.createdAt, isNotEmpty); // createdAt 保留
      // 视频引用同步
      expect(next.videos[0].collection, '乙2');
      expect(next.videos[1].collection, '乙2');
      expect(next.videos[2].collection, '乙'); // 其他合集不受影响
      expect(next.videos[3].isUncategorized, isTrue);
      // 原数据不可变
      expect(data.collections.first.name, '甲');
      expect(data.videos.first.collection, '甲');
    });

    test('新名与现有合集重名 → 抛错，原数据不变', () {
      final data = _data(videos: [_video('BV1', collection: '甲')]);
      expect(() => renameCollection(data, '甲', '乙'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.first.name, '甲');
      expect(data.videos.first.collection, '甲');
    });

    test('旧名不存在 → 抛错', () {
      final data = _data();
      expect(() => renameCollection(data, '丙', '丁'),
          throwsA(isA<CollectionException>()));
    });

    test('新名为空（含纯空白）→ 抛错', () {
      final data = _data();
      expect(() => renameCollection(data, '甲', '  '),
          throwsA(isA<CollectionException>()));
    });

    test('新旧名相同 → 未改动，原样返回不抛错', () {
      final data = _data(videos: [_video('BV1', collection: '甲')]);
      final next = renameCollection(data, '甲', ' 甲 ');
      expect(identical(next, data), isTrue); // 去空白后相同 → 直接返回原数据
      expect(next.collections.first.name, '甲');
      expect(next.videos.first.collection, '甲');
    });

    test('空合集也可重命名（无视频引用同步）', () {
      final data = _data(collections: ['甲', '乙']);
      final next = renameCollection(data, '乙', '丙');
      expect(next.collections.map((c) => c.name), ['甲', '丙']);
    });
  });

  group('deleteCollection', () {
    test('移除合集定义 + 该合集下视频回未分类，不删除视频', () {
      final data = _data(videos: [
        _video('BV1', collection: '甲'),
        _video('BV2', collection: '乙'),
        _video('BV3', collection: '乙'),
        _video('BV4'),
      ]);
      final next = deleteCollection(data, '乙');
      expect(next.collections.map((c) => c.name), ['甲']); // 乙 定义已移除
      expect(next.videos, hasLength(4)); // 视频不删
      expect(next.videos[1].isUncategorized, isTrue); // 乙 → 未分类
      expect(next.videos[2].isUncategorized, isTrue);
      expect(next.videos[0].collection, '甲'); // 其他合集不受影响
      expect(next.videos[3].isUncategorized, isTrue);
      // 原数据不可变
      expect(data.collections, hasLength(2));
      expect(data.videos[1].collection, '乙');
    });

    test('合集不存在 → 抛错', () {
      final data = _data();
      expect(() => deleteCollection(data, '丙'),
          throwsA(isA<CollectionException>()));
    });

    test('空合集也可删除', () {
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BV1', collection: '甲'),
      ]);
      final next = deleteCollection(data, '乙');
      expect(next.collections.map((c) => c.name), ['甲']);
      expect(next.videos.single.collection, '甲');
    });

    test('删除最后一个合集 → collections 为空', () {
      final data = _data(collections: ['甲'], videos: [
        _video('BV1', collection: '甲'),
      ]);
      final next = deleteCollection(data, '甲');
      expect(next.collections, isEmpty);
      expect(next.videos.single.isUncategorized, isTrue);
    });
  });

  group('moveCollectionInto', () {
    test('源合集视频改挂目标 + 源定义消失 + 目标定义保留（视频不丢）', () {
      final data = _data(collections: ['甲', '乙', '丙'], videos: [
        _video('BV1', collection: '甲'),
        _video('BV2', collection: '乙', order: 0),
        _video('BV3', collection: '乙', order: 1),
        _video('BV4', collection: '丙'),
        _video('BV5'), // 未分类
      ]);
      final next = moveCollectionInto(data, '乙', '甲');

      // 源合集定义已删除，其他合集定义原样保留（含顺序）
      expect(next.collections.map((c) => c.name), ['甲', '丙']);
      expect(next.collections.first.createdAt, isNotEmpty); // createdAt 保留
      // 视频一条没少
      expect(next.videos, hasLength(5));
      // 源合集视频改挂目标
      expect(next.videos[1].collection, '甲');
      expect(next.videos[2].collection, '甲');
      // 其它视频不受影响
      expect(next.videos[0].collection, '甲');
      expect(next.videos[3].collection, '丙');
      expect(next.videos[4].isUncategorized, isTrue);
    });

    test('顺序：并入的排在目标原有之后，order 连续无重复', () {
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BV1', collection: '甲', order: 0),
        _video('BV2', collection: '甲', order: 1),
        _video('BV3', collection: '乙', order: 0),
        _video('BV4', collection: '乙', order: 1),
      ]);
      final next = moveCollectionInto(data, '乙', '甲');

      expect(
        next.sortedVideos('甲').map((v) => v.bvid),
        ['BV1', 'BV2', 'BV3', 'BV4'],
        reason: '目标原有在前、并入的在后（跨合集 order 重叠必须重排）',
      );
      final orders = next.sortedVideos('甲').map((v) => v.order).toList();
      expect(orders, [0, 1, 2, 3]);
      expect(orders.toSet(), hasLength(4), reason: 'order 不得重复');
    });

    test('顺序：目标原有 order 全为 0（旧数据）时也按各自展示顺序重排', () {
      // 旧数据全部 order=0 → 展示顺序由 added_at 倒序兜底决定
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BVold', collection: '甲', addedAt: '2026-01-01T00:00:00Z'),
        _video('BVnew', collection: '甲', addedAt: '2026-06-01T00:00:00Z'),
        _video('BV3', collection: '乙', addedAt: '2026-02-01T00:00:00Z'),
      ]);
      final next = moveCollectionInto(data, '乙', '甲');

      expect(
        next.sortedVideos('甲').map((v) => v.bvid),
        ['BVnew', 'BVold', 'BV3'],
        reason: '目标原有保持原展示顺序（added_at 倒序），并入的接在末尾',
      );
      expect(next.sortedVideos('甲').map((v) => v.order), [0, 1, 2]);
    });

    test('源 == 目标（含前后空白）→ 未改动，原样返回不抛错', () {
      final data = _data(videos: [_video('BV1', collection: '甲', order: 3)]);
      final next = moveCollectionInto(data, '甲', ' 甲 ');
      expect(identical(next, data), isTrue);
      expect(next.collections.map((c) => c.name), ['甲', '乙']);
      expect(next.videos.single.order, 3, reason: '未改动就不该重编号');
    });

    test('源合集不存在 → 抛错', () {
      final data = _data();
      expect(() => moveCollectionInto(data, '丙', '甲'),
          throwsA(isA<CollectionException>()));
    });

    test('目标合集不存在 → 抛错（不许凭空造合集）', () {
      final data = _data(videos: [_video('BV1', collection: '甲')]);
      expect(() => moveCollectionInto(data, '甲', '丙'),
          throwsA(isA<CollectionException>()));
      // 抛错即未改动
      expect(data.collections.map((c) => c.name), ['甲', '乙']);
      expect(data.videos.single.collection, '甲');
    });

    test('源/目标名为空（含纯空白）→ 抛错', () {
      final data = _data();
      expect(() => moveCollectionInto(data, '', '甲'),
          throwsA(isA<CollectionException>()));
      expect(() => moveCollectionInto(data, '甲', '   '),
          throwsA(isA<CollectionException>()));
    });

    test('原数据对象未被修改（不可变）', () {
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BV1', collection: '甲'),
        _video('BV2', collection: '乙', order: 7),
      ]);
      final beforeVideos = data.videos;
      final beforeCollections = data.collections;
      final next = moveCollectionInto(data, '乙', '甲');

      expect(data.collections.map((c) => c.name), ['甲', '乙']);
      expect(data.videos[1].collection, '乙');
      expect(data.videos[1].order, 7);
      expect(identical(data.videos, beforeVideos), isTrue);
      expect(identical(data.collections, beforeCollections), isTrue);
      // 返回的是新对象（不是同一个实例）
      expect(identical(next, data), isFalse);
    });

    test('源合集的视频数为 0 → 也能正常删掉源定义', () {
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BV1', collection: '甲'),
      ]);
      final next = moveCollectionInto(data, '乙', '甲');
      expect(next.collections.map((c) => c.name), ['甲']);
      expect(next.videos.single.collection, '甲');
      expect(next.sortedVideos('甲').single.order, 0);
    });
  });
}
