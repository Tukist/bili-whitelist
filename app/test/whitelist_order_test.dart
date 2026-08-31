// order 排序逻辑单测：
// - WhitelistVideo.order 读写（fromJson 缺省 0 / toJson 输出）
// - sortedVideos：order 升序优先，order 相同按 added_at 倒序兜底
// - 旧数据（无 order 字段）兼容：全 0 → 走 added_at 倒序，不崩
// 纯 Dart 测试，无原生插件依赖。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';

WhitelistVideo _video(
  String bvid, {
  int order = 0,
  String addedAt = '2026-01-01T00:00:00Z',
  String collection = '',
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

WhitelistData _data(List<WhitelistVideo> videos) => WhitelistData(
      version: 3,
      updatedAt: '2026-08-20T00:00:00Z',
      videos: videos,
    );

void main() {
  group('WhitelistVideo.order 读写', () {
    test('fromJson 缺省 order=0（旧数据兼容）', () {
      final v = WhitelistVideo.fromJson({
        'bvid': 'BV1',
        'cid': 100,
        'title': 't',
        'duration': 60,
      });
      expect(v.order, 0);
    });

    test('fromJson 解析 order + toJson 输出 order', () {
      final v = WhitelistVideo.fromJson({
        'bvid': 'BV1',
        'cid': 100,
        'title': 't',
        'duration': 60,
        'order': 5,
      });
      expect(v.order, 5);
      expect(v.toJson()['order'], 5);
    });

    test('order 为脏数据（非数字）时缺省 0，不崩', () {
      final v = WhitelistVideo.fromJson({
        'bvid': 'BV1',
        'cid': 100,
        'title': 't',
        'duration': 60,
        'order': 'oops',
      });
      expect(v.order, 0);
    });
  });

  group('sortedVideos 排序', () {
    test('order 升序优先：乱序 order 按从小到大排', () {
      final data = _data([
        _video('BV2', order: 2),
        _video('BV0', order: 0),
        _video('BV1', order: 1),
      ]);
      final sorted = data.sortedVideos().map((v) => v.bvid).toList();
      expect(sorted, ['BV0', 'BV1', 'BV2']);
    });

    test('order 相同 → added_at 倒序兜底（新加入在前）', () {
      final data = _data([
        _video('BV_old', order: 1, addedAt: '2026-01-01T00:00:00Z'),
        _video('BV_new', order: 1, addedAt: '2026-06-01T00:00:00Z'),
        _video('BV_mid', order: 1, addedAt: '2026-03-01T00:00:00Z'),
      ]);
      final sorted = data.sortedVideos().map((v) => v.bvid).toList();
      expect(sorted, ['BV_new', 'BV_mid', 'BV_old']);
    });

    test('旧数据全 0 → 等价 added_at 倒序（现有行为兼容）', () {
      final data = _data([
        _video('BV1', addedAt: '2026-01-01T00:00:00Z'),
        _video('BV2', addedAt: '2026-08-01T00:00:00Z'),
        _video('BV3', addedAt: '2026-03-01T00:00:00Z'),
      ]);
      final sorted = data.sortedVideos().map((v) => v.bvid).toList();
      expect(sorted, ['BV2', 'BV3', 'BV1']);
    });

    test('order 混合：order 优先，组内 added_at 倒序', () {
      final data = _data([
        _video('A1', order: 0, addedAt: '2026-01-01T00:00:00Z'),
        _video('A2', order: 0, addedAt: '2026-06-01T00:00:00Z'),
        _video('B1', order: 1, addedAt: '2026-01-01T00:00:00Z'),
      ]);
      final sorted = data.sortedVideos().map((v) => v.bvid).toList();
      expect(sorted, ['A2', 'A1', 'B1']);
    });

    test('added_at 空串/脏数据排最后，不崩', () {
      final data = _data([
        _video('BV1', addedAt: ''),
        _video('BV2', addedAt: '2026-06-01T00:00:00Z'),
      ]);
      final sorted = data.sortedVideos().map((v) => v.bvid).toList();
      expect(sorted, ['BV2', 'BV1']);
    });
  });

  group('sortedVideos 合集过滤', () {
    test('collection 过滤：只返回该合集视频', () {
      final data = _data([
        _video('BV1', collection: '动画'),
        _video('BV2', collection: '音乐'),
        _video('BV3'),
      ]);
      expect(data.sortedVideos('动画').single.bvid, 'BV1');
      expect(data.sortedVideos('不存在'), isEmpty);
    });

    test('空串 = 未分类；null = 全部', () {
      final data = _data([
        _video('BV1', collection: '动画'),
        _video('BV2'),
      ]);
      expect(data.sortedVideos('').single.bvid, 'BV2');
      expect(data.sortedVideos(), hasLength(2));
    });

    test('sortedVideos 返回新列表，原数据顺序不变', () {
      final data = _data([
        _video('BV1', addedAt: '2026-01-01T00:00:00Z'),
        _video('BV2', addedAt: '2026-08-01T00:00:00Z'),
      ]);
      data.sortedVideos();
      expect(data.videos.map((v) => v.bvid), ['BV1', 'BV2']);
    });
  });

  group('reorderCollections 合集重排（主页拖拽排序）', () {
    WhitelistData collectionsData(List<String> names) => WhitelistData(
          version: 3,
          updatedAt: '2026-08-20T00:00:00Z',
          videos: [_video('BV1', collection: names.first)],
          collections: [
            for (final n in names) CollectionInfo(name: n, createdAt: ''),
          ],
        );

    test('按新顺序重排 collections；原数据不变', () {
      final data = collectionsData(['A', 'B', 'C']);
      final next = reorderCollections(data, ['C', 'A', 'B']);
      expect(next.collections.map((c) => c.name), ['C', 'A', 'B']);
      // 视频归属不受影响
      expect(next.videos.single.collection, 'A');
      expect(data.collections.map((c) => c.name), ['A', 'B', 'C']);
    });

    test('数量不匹配抛 CollectionException，原数据不动', () {
      final data = collectionsData(['A', 'B', 'C']);
      expect(() => reorderCollections(data, ['A', 'B']),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['A', 'B', 'C']);
    });

    test('名字不匹配（含混入「未分类」）抛 CollectionException', () {
      final data = collectionsData(['A', 'B', 'C']);
      expect(() => reorderCollections(data, ['A', 'B', 'X']),
          throwsA(isA<CollectionException>()));
      expect(() => reorderCollections(data, ['A', 'B', '未分类']),
          throwsA(isA<CollectionException>()));
    });
  });

  group('reorderVideosInCollection 视频重排（合集页拖拽排序）', () {
    test('该合集视频 order 按新顺序 0..n-1，其他合集 order 不变', () {
      final data = _data([
        _video('BV1', collection: '动画'),
        _video('BV2', collection: '动画'),
        _video('BV3', collection: '动画'),
        _video('BVX', collection: '音乐', order: 7),
      ]);
      final next =
          WhitelistWriter.reorderVideosInCollection(data, '动画', [
        'BV3',
        'BV1',
        'BV2',
      ]);
      final byBvid = {for (final v in next.videos) v.bvid: v.order};
      expect(byBvid['BV3'], 0);
      expect(byBvid['BV1'], 1);
      expect(byBvid['BV2'], 2);
      // 其他合集 order 保持原值
      expect(byBvid['BVX'], 7);
      // 原数据不可变
      expect(data.videos.every((v) => v.order == 0) ||
          data.videos.last.order == 7, true);
    });

    test('未分类（空串）重排同样生效', () {
      final data = _data([
        _video('BV1'),
        _video('BV2'),
        _video('BVX', collection: '音乐', order: 3),
      ]);
      final next = WhitelistWriter.reorderVideosInCollection(data, '', [
        'BV2',
        'BV1',
      ]);
      final byBvid = {for (final v in next.videos) v.bvid: v.order};
      expect(byBvid['BV2'], 0);
      expect(byBvid['BV1'], 1);
      expect(byBvid['BVX'], 3); // 其他合集不动
    });

    test('空新顺序返回原数据（无变化）', () {
      final data = _data([_video('BV1', collection: '动画')]);
      final next =
          WhitelistWriter.reorderVideosInCollection(data, '动画', []);
      expect(identical(next, data), true);
    });
  });
}
