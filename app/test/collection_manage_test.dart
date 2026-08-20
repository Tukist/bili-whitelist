// 合集管理逻辑单测（与 PC 端 whitelist.py collection rename/delete 语义一致）：
// - renameCollection：改 collections 名字 + 同步所有 videos.collection 引用；
//   新名非空、不与现有合集重名、旧名存在才允许；新旧名相同视为未改动
// - deleteCollection：移除合集定义 + 该合集下视频回未分类（不删除视频）
// 纯 Dart 测试，无原生插件依赖。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';

WhitelistVideo _video(String bvid, {String collection = ''}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 100,
      title: '视频$bvid',
      cover: '',
      duration: 60,
      upName: 'up',
      addedAt: '2026-01-01T00:00:00Z',
      collection: collection,
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
}
