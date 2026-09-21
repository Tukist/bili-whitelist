// 合集封面 / 简介（v2.38.0）模型层测试：
// - CollectionInfo：cover / desc 可选（默认空串）、fromJson 容错、toJson
//   **仅非空才输出**、copyWith 逐字段透传；
// - ⚠ 防坑回归（本批次最重要的一条）：renameCollection / deleteCollection /
//   moveCollectionUnder 过去是**重新构造** CollectionInfo(name, createdAt)，
//   加字段后若不改成 copyWith 就会「改个合集名 → 封面简介静默清空」；
// - setCollectionMeta：只改目标合集、null = 不改、空串 = 清空、不存在抛错；
// - 老数据兼容：没有 cover/desc 的 JSON 读进来再写回去，collections 里一个
//   字节都不会多（不会出现 "cover":"" 这种噪声）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';

WhitelistData _data({
  List<CollectionInfo> collections = const [],
  List<WhitelistVideo> videos = const [],
}) => WhitelistData(
  version: 4,
  updatedAt: '2026-08-20T00:00:00Z',
  collections: collections,
  videos: videos,
);

CollectionInfo _col(
  String name, {
  String cover = '',
  String desc = '',
  String createdAt = '2026-08-01T00:00:00Z',
}) => CollectionInfo(
  name: name,
  createdAt: createdAt,
  cover: cover,
  desc: desc,
);

WhitelistVideo _video(String bvid, {String collection = ''}) => WhitelistVideo(
  bvid: bvid,
  cid: 100,
  title: '视频$bvid',
  cover: '',
  duration: 60,
  upName: 'up',
  addedAt: '2026-01-01T00:00:00Z',
  collection: collection,
);

/// 从数据里取某合集的 cover/desc（找不到 → null）。
({String cover, String desc})? _meta(WhitelistData d, String name) {
  final hits = d.collections.where((c) => c.name == name);
  if (hits.isEmpty) return null;
  return (cover: hits.first.cover, desc: hits.first.desc);
}

void main() {
  group('CollectionInfo：cover / desc 读写', () {
    test('默认空串（老数据 / 新建合集不用显式传）', () {
      const c = CollectionInfo(name: '动画', createdAt: '2026-08-01');
      expect(c.cover, '');
      expect(c.desc, '');
    });

    test('toJson：非空才输出（空值不产生 "cover":"" 噪声）', () {
      expect(_col('动画').toJson(), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
      });
      expect(_col('动画', cover: 'https://i0.hdslb.com/a.jpg').toJson(), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
        'cover': 'https://i0.hdslb.com/a.jpg',
      });
      expect(_col('动画', desc: '一句话简介').toJson(), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
        'desc': '一句话简介',
      });
      expect(
        _col('动画', cover: 'u', desc: 'd').toJson(),
        {
          'name': '动画',
          'created_at': '2026-08-01T00:00:00Z',
          'cover': 'u',
          'desc': 'd',
        },
      );
    });

    test('fromJson：缺失 / 脏类型 → 空串（不让解析炸掉）', () {
      final missing = CollectionInfo.fromJson({'name': 'a', 'created_at': 't'});
      expect(missing.cover, '');
      expect(missing.desc, '');

      final dirty = CollectionInfo.fromJson({
        'name': 'a',
        'created_at': 't',
        'cover': 123, // 数字
        'desc': {'x': 1}, // 对象
      });
      expect(dirty.cover, '');
      expect(dirty.desc, '');

      final nulls = CollectionInfo.fromJson({
        'name': 'a',
        'created_at': 't',
        'cover': null,
        'desc': null,
      });
      expect(nulls.cover, '');
      expect(nulls.desc, '');
    });

    test('fromJson ↔ toJson 往返', () {
      final c = _col('动 画/2024冬', cover: 'https://x/y.png', desc: '简介\n第二行');
      final back = CollectionInfo.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
      );
      expect(back.name, c.name);
      expect(back.createdAt, c.createdAt);
      expect(back.cover, c.cover);
      expect(back.desc, '简介\n第二行', reason: '简介里的换行原样保留');
    });

    test('copyWith：改一个字段，其余（含 cover/desc）逐字段透传', () {
      final c = _col('甲/乙', cover: 'u', desc: 'd', createdAt: 'T');
      // 注意：CollectionInfo 没有 operator==（身份是 name 路径，值语义没必要），
      // 所以这里逐字段断言。
      void expectSame(CollectionInfo got, CollectionInfo want) {
        expect(got.name, want.name);
        expect(got.createdAt, want.createdAt);
        expect(got.cover, want.cover);
        expect(got.desc, want.desc);
      }

      expectSame(
        c.copyWith(name: '甲/丙'),
        _col('甲/丙', cover: 'u', desc: 'd', createdAt: 'T'),
      );
      expect(c.copyWith(cover: 'u2').desc, 'd');
      expect(c.copyWith(desc: 'd2').cover, 'u');
      expect(c.copyWith(cover: '').cover, '', reason: '空串是合法值（清空封面）');
      // 不传任何字段 = 全等副本
      expectSame(c.copyWith(), c);
    });

    test('老数据 JSON 读进来再写回去：collections 里一个字节都不多', () {
      const raw = '{"name":"动画","created_at":"2026-08-01T00:00:00Z"}';
      final c = CollectionInfo.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      expect(
        jsonEncode(c.toJson()),
        raw,
        reason: '没有 cover/desc 的老数据回写不产生任何新字段',
      );
    });
  });

  group('⚠ 防坑回归：改合集不丢封面 / 简介', () {
    test('renameCollection：自己与子孙的 cover/desc 都保留（只换路径）', () {
      final data = _data(
        collections: [
          _col('动画', cover: 'cov-动画', desc: 'desc-动画'),
          _col('动画/2024冬', cover: 'cov-冬', desc: 'desc-冬'),
          _col('动画/2024冬/OVA', cover: 'cov-ova', desc: 'desc-ova'),
          _col('音乐', cover: 'cov-音乐', desc: 'desc-音乐'),
        ],
        videos: [_video('BV1', collection: '动画/2024冬')],
      );

      final next = renameCollection(data, '动画', '番剧');

      expect(_meta(next, '番剧'), (cover: 'cov-动画', desc: 'desc-动画'));
      expect(_meta(next, '番剧/2024冬'), (cover: 'cov-冬', desc: 'desc-冬'));
      expect(_meta(next, '番剧/2024冬/OVA'), (cover: 'cov-ova', desc: 'desc-ova'));
      // 无关合集原样（连对象都不该被重建）
      expect(_meta(next, '音乐'), (cover: 'cov-音乐', desc: 'desc-音乐'));
      expect(next.videos.single.collection, '番剧/2024冬',
          reason: '视频引用照旧级联');
    });

    test('deleteCollection：上提一级的子孙合集不丢封面 / 简介', () {
      final data = _data(
        collections: [
          _col('动画', cover: 'cov-动画', desc: 'desc-动画'),
          _col('动画/2024冬', cover: 'cov-冬', desc: 'desc-冬'),
        ],
      );

      final next = deleteCollection(data, '动画');

      expect(_meta(next, '动画'), isNull, reason: '被删的合集自己不在了');
      expect(_meta(next, '2024冬'), (cover: 'cov-冬', desc: 'desc-冬'),
          reason: '删父不该把子的封面简介一起清空');
    });

    test('moveCollectionUnder：源合集与它的子孙都不丢封面 / 简介', () {
      final data = _data(
        collections: [
          _col('动画', cover: 'cov-动画', desc: 'desc-动画'),
          _col('动画/2024冬', cover: 'cov-冬', desc: 'desc-冬'),
          _col('音乐', cover: 'cov-音乐', desc: 'desc-音乐'),
        ],
      );

      final next = moveCollectionUnder(data, '动画', '音乐');

      expect(_meta(next, '音乐/动画'), (cover: 'cov-动画', desc: 'desc-动画'));
      expect(_meta(next, '音乐/动画/2024冬'), (cover: 'cov-冬', desc: 'desc-冬'));
      expect(_meta(next, '音乐'), (cover: 'cov-音乐', desc: 'desc-音乐'));
    });

    test('移到顶层（target 空串）同样保留', () {
      final data = _data(
        collections: [
          _col('音乐'),
          _col('音乐/动画', cover: 'cov', desc: 'd'),
        ],
      );

      final next = moveCollectionUnder(data, '音乐/动画', '');
      expect(_meta(next, '动画'), (cover: 'cov', desc: 'd'));
    });

    test('reorderCollections：同级重排原对象直接复用（封面简介天然不变）', () {
      final data = _data(
        collections: [
          _col('甲', cover: 'c1'),
          _col('乙', cover: 'c2'),
        ],
      );
      final next = reorderCollections(data, ['乙', '甲']);
      expect(_meta(next, '甲'), (cover: 'c1', desc: ''));
      expect(_meta(next, '乙'), (cover: 'c2', desc: ''));
    });
  });

  group('setCollectionMeta：只改目标合集', () {
    test('设封面 + 简介；其它合集一个字段都不动', () {
      final data = _data(
        collections: [
          _col('动画'),
          _col('动画/2024冬'),
          _col('音乐', cover: 'c', desc: 'd'),
        ],
      );

      final next = setCollectionMeta(
        data,
        '动画',
        cover: '  https://i0.hdslb.com/a.jpg  ', // 两端空白要去掉
        desc: '  一句话简介  ',
      );

      expect(_meta(next, '动画'),
          (cover: 'https://i0.hdslb.com/a.jpg', desc: '一句话简介'));
      expect(_meta(next, '动画/2024冬'), (cover: '', desc: ''),
          reason: '不做级联：父合集设封面不该动子合集');
      expect(_meta(next, '音乐'), (cover: 'c', desc: 'd'));
    });

    test('只传一个字段时另一个不改（null = 不改）', () {
      final data = _data(collections: [_col('动画', cover: 'c', desc: 'd')]);

      final onlyCover = setCollectionMeta(data, '动画', cover: 'c2');
      expect(_meta(onlyCover, '动画'), (cover: 'c2', desc: 'd'));

      final onlyDesc = setCollectionMeta(data, '动画', desc: 'd2');
      expect(_meta(onlyDesc, '动画'), (cover: 'c', desc: 'd2'));
    });

    test('传空串 = 清空（回到「未设置」）', () {
      final data = _data(collections: [_col('动画', cover: 'c', desc: 'd')]);
      final next = setCollectionMeta(data, '动画', cover: '', desc: '');
      expect(_meta(next, '动画'), (cover: '', desc: ''));
      expect(next.collections.single.toJson().containsKey('cover'), isFalse);
      expect(next.collections.single.toJson().containsKey('desc'), isFalse);
    });

    test('路径会规范化；不存在的合集 / 空路径 → 抛 CollectionException', () {
      final data = _data(collections: [_col('动画/2024冬')]);
      expect(
        _meta(setCollectionMeta(data, ' 动画 / 2024冬 ', desc: 'd'), '动画/2024冬'),
        (cover: '', desc: 'd'),
        reason: '路径过 normalizeCollectionPath',
      );
      expect(
        () => setCollectionMeta(data, '不存在', desc: 'd'),
        throwsA(isA<CollectionException>()),
      );
      expect(
        () => setCollectionMeta(data, '', desc: 'd'),
        throwsA(isA<CollectionException>()),
      );
    });

    test('子合集同样能设（路径就是身份，没有层级限制）', () {
      final data = _data(
        collections: [_col('甲'), _col('甲/乙'), _col('甲/乙/丙')],
      );
      final next = setCollectionMeta(data, '甲/乙/丙', desc: '第三层');
      expect(_meta(next, '甲/乙/丙'), (cover: '', desc: '第三层'));
      expect(_meta(next, '甲'), (cover: '', desc: ''));
      expect(_meta(next, '甲/乙'), (cover: '', desc: ''));
    });
  });
}
