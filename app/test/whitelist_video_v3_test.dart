// 数据模型 v3 兼容性测试：
// - v1/v2 旧数据（无 collections/collection 字段）fromJson 不崩、缺省正确
// - v3 字段正常解析 / 序列化
// - normalizedForSave 统一写 version 3 + collections
// 纯 Dart 测试，无原生插件依赖。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';

Map<String, dynamic> _v2Video(String bvid) => {
      'bvid': bvid,
      'cid': 100,
      'title': '旧视频$bvid',
      'cover': '',
      'duration': 60,
      'up_name': 'up',
      'added_at': '2026-01-01T00:00:00Z',
    };

void main() {
  group('WhitelistData v3 兼容', () {
    test('v1（只有 version/videos）解析不崩，collections=[]，视频未分类', () {
      final data = WhitelistData.fromJson({
        'version': 1,
        'videos': [_v2Video('BV1')],
      });
      expect(data.version, 1);
      expect(data.collections, isEmpty);
      expect(data.videos, hasLength(1));
      expect(data.videos.first.collection, '');
      expect(data.videos.first.isUncategorized, isTrue);
    });

    test('v2（videos 无 collection 字段）解析后 collection 缺省为空串', () {
      final data = WhitelistData.fromJson({
        'version': 2,
        'updated_at': '2026-08-20T00:00:00Z',
        'videos': [_v2Video('BV2')],
      });
      expect(data.videos.first.collection, '');
      // toJson 总是输出 collection 键（写回 Gist 不会丢字段）
      final encoded = data.toJson()['videos'] as List;
      expect((encoded.first as Map)['collection'], '');
    });

    test('v3 完整解析：collections + 视频 collection', () {
      final data = WhitelistData.fromJson({
        'version': 3,
        'updated_at': '2026-08-20T00:00:00Z',
        'collections': [
          {'name': '动画', 'created_at': '2026-08-01T00:00:00Z'},
        ],
        'videos': [
          {..._v2Video('BV3'), 'collection': '动画'},
          _v2Video('BV4'),
        ],
      });
      expect(data.collections, hasLength(1));
      expect(data.collections.first.name, '动画');
      expect(data.videos.first.collection, '动画');
      expect(data.videos.last.isUncategorized, isTrue);
    });

    test('collections 非列表（脏数据）时缺省为 []，不崩', () {
      final data = WhitelistData.fromJson({
        'version': 3,
        'collections': 'not-a-list',
        'videos': [_v2Video('BV5')],
      });
      expect(data.collections, isEmpty);
    });

    test('normalizedForSave：version 固定 3、updated_at 刷新、collections 必出', () {
      final old = WhitelistData.fromJson({
        'version': 2,
        'videos': [_v2Video('BV6')],
      });
      final v3 = old.normalizedForSave();
      expect(v3.version, 3);
      expect(v3.updatedAt, isNotEmpty);
      expect(DateTime.tryParse(v3.updatedAt), isNotNull);
      final json = v3.toJson();
      expect(json['version'], 3);
      expect(json.containsKey('collections'), isTrue);
    });
  });

  group('WhitelistVideo.copyWith', () {
    test('改 collection 不影响其他字段', () {
      final v = WhitelistVideo.fromJson({..._v2Video('BV7'), 'collection': 'A'});
      final moved = v.copyWith(collection: '');
      expect(moved.collection, '');
      expect(moved.bvid, 'BV7');
      expect(moved.title, v.title);
      // 原对象不变（不可变模型）
      expect(v.collection, 'A');
    });
  });
}
