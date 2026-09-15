// 合集管理逻辑单测（v2.30.0 起合集是**路径**、支持多层嵌套）：
// - createSubCollection：建顶层 / 建子合集（路径拼接、同级重名、名字含 / 拒绝）
// - moveCollectionUnder：「移动到…」= 嵌套（源合集**不被删除**，视频与子孙
//   一起跟着换前缀；target 空串 = 移到顶层；防环；目标下同名冲突抛错）
// - renameCollection：只换路径最后一段，级联子孙与视频引用；同级重名拒绝
// - deleteCollection：删合集本身；直属视频回未分类；**直属子合集上提一级**、
//   不连带删除子孙
// - sortedVideos：路径**精确匹配**（父合集不混入子孙的视频）
// - reorderCollections：只做同级重排（名单必须是现有名字的一个排列）
// - 旧数据兼容：不带 / 的名字就是顶层合集，零迁移
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
  group('路径工具（合集身份 = 路径，分隔符 /）', () {
    test('parent / localName / depth / ancestors / display', () {
      expect(collectionParentOf('动画'), '');
      expect(collectionParentOf('动画/2024冬'), '动画');
      expect(collectionParentOf('A/B/C'), 'A/B');
      expect(collectionLocalName('动画'), '动画');
      expect(collectionLocalName('动画/2024冬'), '2024冬');
      expect(collectionDepth('动画'), 0);
      expect(collectionDepth('动画/2024冬'), 1);
      expect(collectionDepth('A/B/C'), 2);
      expect(collectionDepth(''), 0, reason: '空串 = 未分类，不是层级');
      expect(collectionAncestors('A/B/C'), ['A', 'A/B']);
      expect(collectionAncestors('A'), isEmpty);
      expect(collectionDisplay('A/B'), 'A / B');
      expect(collectionDisplay('A'), 'A', reason: '顶层没有 / → 展示原样不变');
    });

    test('路径规范化：空白与多余斜杠不影响层级判断', () {
      expect(normalizeCollectionPath(' 甲 / 乙 '), '甲/乙');
      expect(normalizeCollectionPath('甲//乙'), '甲/乙');
      expect(normalizeCollectionPath('甲/'), '甲');
      expect(collectionParentOf(' 甲 / 乙 '), '甲');
    });

    test('isCollectionUnder 是严格子孙（不含自己；未分类没有子孙）', () {
      expect(isCollectionUnder('A/B', 'A'), isTrue);
      expect(isCollectionUnder('A', 'A'), isFalse);
      expect(isCollectionUnder('AB', 'A'), isFalse, reason: '前缀相同但不是一层');
      expect(isCollectionUnder('A', ''), isFalse);
      expect(isCollectionUnder('A/B/C', 'A'), isTrue);
    });

    test('children / descendants 只看数据里真实存在的路径', () {
      final data = _data(collections: ['A', 'A/B', 'A/B/C', 'D']);
      expect(collectionChildrenOf(data, '').map((c) => c.name), ['A', 'D']);
      expect(collectionChildrenOf(data, 'A').map((c) => c.name), ['A/B']);
      expect(collectionChildrenOf(data, 'A/B/C'), isEmpty);
      expect(collectionDescendants(data, 'A'), ['A/B', 'A/B/C']);
      expect(collectionDescendants(data, 'D'), isEmpty);
    });

    test('validateCollectionName：空 / 含 / / 「未分类」→ 抛错', () {
      expect(() => validateCollectionName('  '), throwsA(isA<CollectionException>()));
      expect(() => validateCollectionName('乙/丙'), throwsA(isA<CollectionException>()));
      expect(() => validateCollectionName(kUncategorizedCollectionName),
          throwsA(isA<CollectionException>()));
      expect(() => validateCollectionName('正常名字'), returnsNormally);
    });

    test('CollectionInfo 的 parentPath / localName / depth 便捷读法', () {
      const sub = CollectionInfo(name: '动画/2024冬', createdAt: '');
      expect(sub.parentPath, '动画');
      expect(sub.localName, '2024冬');
      expect(sub.depth, 1);
      const top = CollectionInfo(name: '动画', createdAt: '');
      expect(top.parentPath, '');
      expect(top.localName, '动画');
      expect(top.depth, 0);
    });
  });

  group('createSubCollection（新建合集 / 新建子合集）', () {
    test('顶层建合集：路径就是名字本身', () {
      final next = createSubCollection(_data(collections: const []), '', '动画');
      expect(next.collections.map((c) => c.name), ['动画']);
      expect(next.collections.single.createdAt, isNotEmpty);
      expect(next.collections.single.depth, 0);
    });

    test('建子合集：路径 = 父路径 + / + 名字，追加在数组末尾（= 显示顺序）', () {
      final next = createSubCollection(_data(collections: ['动画']), '动画', '2024冬');
      expect(next.collections.map((c) => c.name), ['动画', '动画/2024冬']);
    });

    test('多级：在子合集下再建子合集（任意深度）', () {
      final data = _data(collections: ['动画', '动画/2024冬']);
      final next = createSubCollection(data, '动画/2024冬', '第1集');
      expect(next.collections.last.name, '动画/2024冬/第1集');
      expect(next.collections.last.depth, 2);
    });

    test('同一层级下重名 → 抛错，原数据不变', () {
      final data = _data(collections: ['动画', '动画/2024冬']);
      expect(() => createSubCollection(data, '动画', '2024冬'),
          throwsA(isA<CollectionException>()));
      expect(data.collections, hasLength(2));
    });

    test('不同层级同名 → 允许（路径不同就是两个合集）', () {
      final next =
          createSubCollection(_data(collections: ['动画', '音乐']), '音乐', '动画');
      expect(next.collections.map((c) => c.name), ['动画', '音乐', '音乐/动画']);
    });

    test('名字含 / → 抛错（层级只能靠挂载，不能靠命名）', () {
      final data = _data(collections: ['甲']);
      expect(() => createSubCollection(data, '甲', '乙/丙'),
          throwsA(isA<CollectionException>()));
      expect(() => createSubCollection(data, '', '乙/丙'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['甲']);
    });

    test('名字为空 / 纯空白 / 「未分类」→ 抛错', () {
      final data = _data();
      expect(() => createSubCollection(data, '', ''),
          throwsA(isA<CollectionException>()));
      expect(() => createSubCollection(data, '', '   '),
          throwsA(isA<CollectionException>()));
      expect(
          () => createSubCollection(data, '', kUncategorizedCollectionName),
          throwsA(isA<CollectionException>()));
    });

    test('父合集不存在 → 抛错（不许凭空造父级）', () {
      final data = _data();
      expect(() => createSubCollection(data, '丙', '丁'),
          throwsA(isA<CollectionException>()));
    });

    test('原数据不可变', () {
      final data = _data(collections: ['甲']);
      final before = data.collections;
      createSubCollection(data, '甲', '乙');
      expect(data.collections, hasLength(1));
      expect(identical(data.collections, before), isTrue);
    });
  });

  group('moveCollectionUnder（「移动到…」= 嵌套，不删除源合集）', () {
    test('把「乙」移到「甲」下面：乙 定义还在、路径变 甲/乙、视频跟着挂', () {
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BV1', collection: '甲', order: 0),
        _video('BV2', collection: '乙', order: 0),
        _video('BV3', collection: '乙', order: 1),
        _video('BV4'), // 未分类
      ]);
      final next = moveCollectionUnder(data, '乙', '甲');

      // 关键：源合集**没有被删除**（上一版「并入」语义会在这里把它删掉）
      expect(next.collections.map((c) => c.name), ['甲', '甲/乙']);
      expect(next.collections.first.createdAt, isNotEmpty); // createdAt 保留
      expect(next.videos, hasLength(4)); // 视频一条没少
      expect(next.videos[1].collection, '甲/乙');
      expect(next.videos[2].collection, '甲/乙');
      expect(next.videos[0].collection, '甲');
      expect(next.videos[3].isUncategorized, isTrue);
      // 父合集精确匹配：甲 页里只看得到自己的直属视频
      expect(next.sortedVideos('甲').map((v) => v.bvid), ['BV1']);
      // 在目标里能正常打开源合集
      expect(next.sortedVideos('甲/乙').map((v) => v.bvid), ['BV2', 'BV3']);
      // 移动不动顺序
      expect(next.sortedVideos('甲/乙').map((v) => v.order), [0, 1]);
    });

    test('移动 A 时子孙路径与它们的视频一起级联', () {
      final data = _data(collections: ['甲', '乙', '乙/丙', '乙/丙/丁'], videos: [
        _video('BV1', collection: '乙/丙'),
        _video('BV2', collection: '乙/丙/丁'),
      ]);
      final next = moveCollectionUnder(data, '乙', '甲');

      expect(next.collections.map((c) => c.name),
          ['甲', '甲/乙', '甲/乙/丙', '甲/乙/丙/丁']);
      expect(next.videos[0].collection, '甲/乙/丙');
      expect(next.videos[1].collection, '甲/乙/丙/丁');
      expect(next.sortedVideos('甲/乙'), isEmpty, reason: '乙 自己没有直属视频');
      expect(next.sortedVideos('甲/乙/丙/丁').single.bvid, 'BV2');
    });

    test('移到顶层（target 空串 = 首页那一层，不是「未分类」）', () {
      final data = _data(collections: ['甲', '甲/乙', '甲/乙/丙'], videos: [
        _video('BV1', collection: '甲/乙'),
        _video('BV2', collection: '甲/乙/丙'),
      ]);
      final next = moveCollectionUnder(data, '甲/乙', '');

      expect(next.collections.map((c) => c.name), ['甲', '乙', '乙/丙']);
      expect(next.videos[0].collection, '乙', reason: '视频跟着回顶层路径');
      expect(next.videos[1].collection, '乙/丙');
      expect(next.videos.every((v) => !v.isUncategorized), isTrue,
          reason: '合集移回顶层 ≠ 视频落回未分类');
    });

    test('多级整体移动：A/B 连同 A/B/C 一起挪到 D 下面', () {
      final data = _data(collections: ['A', 'A/B', 'A/B/C', 'D'], videos: [
        _video('BV1', collection: 'A/B/C'),
      ]);
      final next = moveCollectionUnder(data, 'A/B', 'D');

      // 数组位置保持不动（只改路径）；显示顺序 = 各层自己过滤后的顺序
      expect(next.collections.map((c) => c.name), ['A', 'D/B', 'D/B/C', 'D']);
      expect(collectionChildrenOf(next, 'D').map((c) => c.name), ['D/B']);
      expect(next.videos.single.collection, 'D/B/C');
    });

    test('防环：移进自己 → 抛错，原数据不变', () {
      final data = _data(collections: ['甲']);
      expect(() => moveCollectionUnder(data, '甲', '甲'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['甲']);
    });

    test('防环：移进自己的子孙 → 抛错（不许把合集挂进自己的子树）', () {
      final data = _data(collections: ['甲', '甲/乙', '甲/乙/丙']);
      expect(() => moveCollectionUnder(data, '甲', '甲/乙'),
          throwsA(isA<CollectionException>()));
      expect(() => moveCollectionUnder(data, '甲', '甲/乙/丙'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['甲', '甲/乙', '甲/乙/丙']);
    });

    test('目标下已有同名子合集 → 抛错（不自动改名），原数据不变', () {
      final data = _data(collections: ['甲', '乙', '甲/乙'], videos: [
        _video('BV1', collection: '乙'),
      ]);
      expect(() => moveCollectionUnder(data, '乙', '甲'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['甲', '乙', '甲/乙']);
      expect(data.videos.single.collection, '乙');
    });

    test('目标不存在 / 源不存在 / 源名为空 → 抛错', () {
      final data = _data(collections: ['甲']);
      expect(() => moveCollectionUnder(data, '甲', '丙'),
          throwsA(isA<CollectionException>()));
      expect(() => moveCollectionUnder(data, '丙', '甲'),
          throwsA(isA<CollectionException>()));
      expect(() => moveCollectionUnder(data, '', '甲'),
          throwsA(isA<CollectionException>()));
    });

    test('本来就在该层级（含只差空白）→ 未改动，原样返回不抛错', () {
      final data = _data(collections: ['甲', '甲/乙'], videos: [
        _video('BV1', collection: '甲/乙', order: 3),
      ]);
      final next = moveCollectionUnder(data, '甲/乙', ' 甲 ');
      expect(identical(next, data), isTrue);
      expect(next.collections.map((c) => c.name), ['甲', '甲/乙']);
      expect(next.videos.single.order, 3, reason: '未改动就不该重编号');
    });

    test('原数据对象未被修改（不可变）', () {
      final data = _data(collections: ['甲', '乙'], videos: [
        _video('BV1', collection: '甲'),
        _video('BV2', collection: '乙', order: 7),
      ]);
      final beforeVideos = data.videos;
      final beforeCollections = data.collections;
      final next = moveCollectionUnder(data, '乙', '甲');

      expect(data.collections.map((c) => c.name), ['甲', '乙']);
      expect(data.videos[1].collection, '乙');
      expect(data.videos[1].order, 7);
      expect(identical(data.videos, beforeVideos), isTrue);
      expect(identical(data.collections, beforeCollections), isTrue);
      expect(identical(next, data), isFalse);
    });
  });

  group('renameCollection（只换最后一段 + 级联子孙与视频）', () {
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

    test('重命名子合集：只换最后一段，父路径不变', () {
      final data = _data(collections: ['动画', '动画/2024冬'], videos: [
        _video('BV1', collection: '动画/2024冬'),
      ]);
      final next = renameCollection(data, '动画/2024冬', '2025春');
      expect(next.collections.map((c) => c.name), ['动画', '动画/2025春']);
      expect(next.videos.single.collection, '动画/2025春');
    });

    test('重命名级联子孙路径与它们的视频（父合集不受影响）', () {
      final data = _data(collections: ['甲', '甲/乙', '甲/乙/丙'], videos: [
        _video('BV1', collection: '甲/乙'),
        _video('BV2', collection: '甲/乙/丙'),
        _video('BV3', collection: '甲'),
      ]);
      final next = renameCollection(data, '甲/乙', 'B');

      expect(next.collections.map((c) => c.name), ['甲', '甲/B', '甲/B/丙']);
      expect(next.videos[0].collection, '甲/B');
      expect(next.videos[1].collection, '甲/B/丙');
      expect(next.videos[2].collection, '甲', reason: '父合集（不是子孙）不受影响');
    });

    test('同一层级下重名 → 抛错（不会合并合集），原数据不变', () {
      final data = _data(collections: ['甲', '甲/乙', '甲/丙'], videos: [
        _video('BV1', collection: '甲/乙'),
      ]);
      expect(() => renameCollection(data, '甲/乙', '丙'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['甲', '甲/乙', '甲/丙']);
      expect(data.videos.single.collection, '甲/乙');
    });

    test('跨层同名 → 允许（路径不同就是两个合集）', () {
      final data = _data(collections: ['甲', '甲/乙', '丙'], videos: [
        _video('BV1', collection: '甲/乙'),
      ]);
      final next = renameCollection(data, '甲/乙', '丙');
      expect(next.collections.map((c) => c.name), ['甲', '甲/丙', '丙']);
      expect(next.videos.single.collection, '甲/丙');
    });

    test('新名含 / → 抛错（换层级请用移动，不要用改名）', () {
      final data = _data(collections: ['甲']);
      expect(() => renameCollection(data, '甲', '乙/丙'),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['甲']);
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

    test('子合集重命名成同一个局部名 → 未改动', () {
      final data = _data(collections: ['甲', '甲/乙']);
      final next = renameCollection(data, '甲/乙', ' 乙 ');
      expect(identical(next, data), isTrue);
    });

    test('空合集也可重命名（无视频引用同步）', () {
      final data = _data(collections: ['甲', '乙']);
      final next = renameCollection(data, '乙', '丙');
      expect(next.collections.map((c) => c.name), ['甲', '丙']);
    });
  });

  group('deleteCollection（删定义 + 子合集上提一级 + 直属视频回未分类）', () {
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

    test('删除父合集：子合集上提一级、直属视频回未分类、子孙视频不受影响', () {
      final data = _data(
        collections: ['动画', '动画/2024冬', '动画/2024冬/合集A', '音乐'],
        videos: [
          _video('BV1', collection: '动画'), // 直属 → 未分类
          _video('BV2', collection: '动画/2024冬'), // 子合集 → 跟着上提
          _video('BV3', collection: '动画/2024冬/合集A'), // 孙合集 → 跟着上提
          _video('BV4', collection: '音乐'), // 无关
        ],
      );
      final next = deleteCollection(data, '动画');

      // 合集：只删了「动画」，子孙上提一级（不跟着删）
      expect(next.collections.map((c) => c.name),
          ['2024冬', '2024冬/合集A', '音乐']);
      expect(next.collections.first.depth, 0, reason: '子合集变成顶层合集');
      expect(next.collections[1].depth, 1);
      // 视频：一条都没少，归属按新路径改
      expect(next.videos, hasLength(4));
      expect(next.videos[0].isUncategorized, isTrue, reason: '直属视频回未分类');
      expect(next.videos[1].collection, '2024冬');
      expect(next.videos[2].collection, '2024冬/合集A');
      expect(next.videos[3].collection, '音乐');
      // 相关合集页里确实看得到这些视频
      expect(next.sortedVideos('2024冬').single.bvid, 'BV2');
      expect(next.sortedVideos('2024冬/合集A').single.bvid, 'BV3');
    });

    test('删除深层子合集：父合集与其他分支不受影响', () {
      final data = _data(collections: ['甲', '甲/乙', '甲/乙/丙', '甲/丁'], videos: [
        _video('BV1', collection: '甲'),
        _video('BV2', collection: '甲/乙/丙'),
        _video('BV3', collection: '甲/丁'),
      ]);
      final next = deleteCollection(data, '甲/乙');
      expect(next.collections.map((c) => c.name), ['甲', '甲/丙', '甲/丁']);
      expect(next.videos[0].collection, '甲');
      expect(next.videos[1].collection, '甲/丙');
      expect(next.videos[2].collection, '甲/丁');
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

  group('sortedVideos 路径精确匹配（父合集不混入子孙视频）', () {
    test('父合集只列直属视频，子孙的另算', () {
      final data = _data(collections: ['动画', '动画/2024冬'], videos: [
        _video('BV1', collection: '动画'),
        _video('BV2', collection: '动画/2024冬'),
        _video('BV3'),
      ]);
      expect(data.sortedVideos('动画').map((v) => v.bvid), ['BV1']);
      expect(data.sortedVideos('动画/2024冬').map((v) => v.bvid), ['BV2']);
      expect(data.sortedVideos('').map((v) => v.bvid), ['BV3']);
      expect(data.sortedVideos(), hasLength(3));
      expect(data.sortedVideos('动画/2024冬/不存在'), isEmpty);
    });

    test('父合集内排序只看自己的 order（不受子孙 order 干扰）', () {
      final data = _data(collections: ['动画', '动画/2024冬'], videos: [
        _video('BV1', collection: '动画', order: 1),
        _video('BV2', collection: '动画', order: 0),
        _video('BV9', collection: '动画/2024冬', order: 0),
      ]);
      expect(data.sortedVideos('动画').map((v) => v.bvid), ['BV2', 'BV1']);
      expect(data.sortedVideos('动画').map((v) => v.order), [0, 1]);
    });
  });

  group('reorderCollections 同级重排（名单必须是一个排列）', () {
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

    test('子合集同级重排（在父合集页里拖动）', () {
      final data = collectionsData(['甲', '甲/乙', '甲/丙', '丁']);
      final next = reorderCollections(data, ['甲', '甲/丙', '甲/乙', '丁']);
      expect(next.collections.map((c) => c.name), ['甲', '甲/丙', '甲/乙', '丁']);
      expect(next.videos.single.collection, '甲', reason: '归属与路径都不动');
      expect(collectionChildrenOf(next, '甲').map((c) => c.name),
          ['甲/丙', '甲/乙']);
    });

    test('数量不匹配抛 CollectionException，原数据不动', () {
      final data = collectionsData(['A', 'B', 'C']);
      expect(() => reorderCollections(data, ['A', 'B']),
          throwsA(isA<CollectionException>()));
      expect(data.collections.map((c) => c.name), ['A', 'B', 'C']);
    });

    test('名字不匹配（含混入「未分类」/ 借重排改路径）抛 CollectionException', () {
      final data = collectionsData(['甲', '甲/乙', '丁']);
      expect(() => reorderCollections(data, ['甲', '甲/乙', 'X']),
          throwsA(isA<CollectionException>()));
      expect(() => reorderCollections(data, ['甲', '甲/乙', '未分类']),
          throwsA(isA<CollectionException>()));
      // 想借重排把「甲/乙」改成「乙」换层级 → 名字对不上，拒绝
      expect(() => reorderCollections(data, ['甲', '乙', '丁']),
          throwsA(isA<CollectionException>()));
    });

    test('跨层名字混排（只是数组顺序变化）→ 允许，路径一个都没改', () {
      final data = collectionsData(['甲', '甲/乙', '丁']);
      final next = reorderCollections(data, ['甲/乙', '甲', '丁']);
      expect(next.collections.map((c) => c.name), ['甲/乙', '甲', '丁']);
      expect(next.collections[0].depth, 1, reason: '层级由路径决定，重排改不了');
    });
  });

  group('旧数据兼容（零迁移）', () {
    test('不带 / 的顶层合集与带 / 的子合集混在一起，各函数都正常', () {
      final data = _data(
        collections: ['老合集', '动画', '动画/2024冬'],
        videos: [
          _video('BV1', collection: '老合集'),
          _video('BV2', collection: '动画'),
          _video('BV3', collection: '动画/2024冬'),
        ],
      );
      // 读：老数据（无 /）天然就是顶层
      expect(collectionDepth('老合集'), 0);
      expect(collectionChildrenOf(data, '').map((c) => c.name),
          ['老合集', '动画']);
      expect(collectionChildrenOf(data, '动画').map((c) => c.name), ['动画/2024冬']);
      expect(data.sortedVideos('老合集').single.bvid, 'BV1');
      expect(data.sortedVideos('动画').single.bvid, 'BV2');

      // 改：把老合集挂到「动画」下面（旧数据不需要任何迁移步骤）
      final moved = moveCollectionUnder(data, '老合集', '动画');
      expect(moved.collections.map((c) => c.name),
          ['动画/老合集', '动画', '动画/2024冬']);
      expect(collectionChildrenOf(moved, '动画').map((c) => c.name),
          ['动画/老合集', '动画/2024冬']);
      expect(moved.sortedVideos('动画/老合集').single.bvid, 'BV1');
      expect(moved.sortedVideos(''), isEmpty, reason: '未分类没被牵连');

      // 改名在混排数据里同样级联
      final renamed = renameCollection(moved, '动画/2024冬', '2025春');
      expect(renamed.collections.map((c) => c.name),
          ['动画/老合集', '动画', '动画/2025春']);
      expect(renamed.videos[2].collection, '动画/2025春');

      // 删除在混排数据里同样上提（子合集上提、直属视频回未分类）
      final deleted = deleteCollection(renamed, '动画');
      expect(deleted.collections.map((c) => c.name), ['老合集', '2025春']);
      expect(deleted.videos[1].isUncategorized, isTrue);
      expect(deleted.sortedVideos('2025春').single.bvid, 'BV3');
      expect(deleted.sortedVideos('老合集').single.bvid, 'BV1');
    });

    test('路径当普通字符串序列化，往返后层级读法不变', () {
      final data = _data(collections: ['动画', '动画/2024冬'], videos: [
        _video('BV1', collection: '动画/2024冬'),
      ]);
      final back = WhitelistData.fromJson(data.toJson());
      expect(back.collections.map((c) => c.name), ['动画', '动画/2024冬']);
      expect(back.collections[1].depth, 1);
      expect(back.collections[1].localName, '2024冬');
      expect(back.videos.single.collection, '动画/2024冬');
      expect(back.sortedVideos('动画'), isEmpty);
      expect(back.sortedVideos('动画/2024冬').single.bvid, 'BV1');
    });
  });
}
