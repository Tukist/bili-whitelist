// Upowner 模型单元测试 + WhitelistData v4 兼容性测试：
// - Upowner.fromJson / toJson 字段完整 + 必填字段缺省不崩
// - addUpowner 查重（同 mid 已存在抛 UpownerException）
// - removeUpowner 移除
// - WhitelistData 兼容 v3 JSON（缺 upowners → []）
// - normalizedForSave 输出 version=4 + upowners 必出
// 纯 Dart 测试，无原生插件依赖。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';

void main() {
  group('Upowner.fromJson / toJson', () {
    test('全字段往返：字段完整保留', () {
      final orig = Upowner(
        mid: 12345,
        name: '测试UP主',
        face: 'https://i0.hdslb.com/face.jpg',
        fans: 9999,
        addedAt: DateTime.utc(2026, 9, 1, 10, 0, 0),
        lastSeenBvid: 'BV1seen',
        lastSeenAt: DateTime.utc(2026, 9, 1, 11, 0, 0),
      );
      final j = orig.toJson();
      expect(j['mid'], 12345);
      expect(j['name'], '测试UP主');
      expect(j['face'], 'https://i0.hdslb.com/face.jpg');
      expect(j['fans'], 9999);
      expect(j['last_seen_bvid'], 'BV1seen');
      final restored = Upowner.fromJson(j);
      expect(restored.mid, 12345);
      expect(restored.name, '测试UP主');
      expect(restored.fans, 9999);
      expect(restored.lastSeenBvid, 'BV1seen');
      expect(restored.lastSeenAt?.toIso8601String(),
          orig.lastSeenAt?.toIso8601String());
    });

    test('可选字段缺省：fans/lastSeen* 为 null → toJson 不输出对应键',
        () {
      final up = Upowner(
        mid: 1,
        name: 'A',
        face: '',
        addedAt: DateTime.utc(2026, 1, 1),
      );
      final j = up.toJson();
      expect(j.containsKey('fans'), isFalse);
      expect(j.containsKey('last_seen_bvid'), isFalse);
      expect(j.containsKey('last_seen_at'), isFalse);
      final restored = Upowner.fromJson(j);
      expect(restored.fans, isNull);
      expect(restored.lastSeenBvid, isNull);
      expect(restored.lastSeenAt, isNull);
    });

    test('脏数据容错：mid 为 null → 0；name 为 null → 空串', () {
      final up = Upowner.fromJson({
        'mid': null,
        'name': null,
        'face': null,
        'added_at': '2026-01-01T00:00:00Z',
      });
      expect(up.mid, 0);
      expect(up.name, '');
      expect(up.face, '');
    });
  });

  group('Upowner.copyWith', () {
    test('只改 lastSeen*，其他字段不变', () {
      final orig = Upowner(
        mid: 100,
        name: 'X',
        face: 'f',
        fans: 50,
        addedAt: DateTime.utc(2026, 1, 1),
      );
      final next = orig.copyWith(
        lastSeenBvid: 'BV1new',
        lastSeenAt: DateTime.utc(2026, 9, 1),
      );
      expect(next.mid, 100);
      expect(next.name, 'X');
      expect(next.fans, 50);
      expect(next.lastSeenBvid, 'BV1new');
      expect(next.lastSeenAt, DateTime.utc(2026, 9, 1));
      // 原对象不变（不可变）
      expect(orig.lastSeenBvid, isNull);
    });
  });

  group('addUpowner / removeUpowner 纯函数', () {
    final up1 = Upowner(
      mid: 100,
      name: 'A',
      face: '',
      addedAt: DateTime.utc(2026, 1, 1),
    );
    final up2 = Upowner(
      mid: 200,
      name: 'B',
      face: '',
      addedAt: DateTime.utc(2026, 2, 1),
    );
    final base = WhitelistData.fromJson({
      'version': 4,
      'updated_at': '2026-09-01T00:00:00Z',
      'collections': [],
      'videos': [],
      'upowners': [up1.toJson()],
    });

    test('addUpowner：追加新 UP 主', () {
      final next = addUpowner(base, up2);
      expect(next.upowners, hasLength(2));
      expect(next.upowners.last.mid, 200);
      // 原对象不变
      expect(base.upowners, hasLength(1));
    });

    test('addUpowner：mid 重复 → 抛 UpownerException', () {
      expect(() => addUpowner(base, up1.copyWith(name: 'A 重命名')),
          throwsA(isA<UpownerException>().having(
              (e) => e.message, 'message', contains('已在白名单'))));
    });

    test('removeUpowner：按 mid 移除', () {
      final next = removeUpowner(base, 100);
      expect(next.upowners, isEmpty);
    });

    test('removeUpowner：mid 不存在 → 原样返回', () {
      expect(identical(removeUpowner(base, 999), base), isTrue);
    });
  });

  group('WhitelistData v4 兼容 + 规范化', () {
    test('v3 JSON（无 upowners 字段）→ upowners=[]', () {
      final data = WhitelistData.fromJson({
        'version': 3,
        'updated_at': '2026-09-01T00:00:00Z',
        'collections': [
          {'name': '动画', 'created_at': '2026-08-01T00:00:00Z'}
        ],
        'videos': [
          {
            'bvid': 'BV1',
            'cid': 1,
            'title': '一',
            'up_name': 'u',
            'added_at': '2026-01-01T00:00:00Z',
          },
        ],
      });
      expect(data.upowners, isEmpty);
      expect(data.collections, hasLength(1));
    });

    test('upowners 字段类型异常（脏数据）→ 缺省为 []', () {
      final data = WhitelistData.fromJson({
        'version': 4,
        'upowners': 'not-a-list',
        'videos': [],
      });
      expect(data.upowners, isEmpty);
    });

    test('normalizedForSave：version=4 + upowners 必出 + updated_at 刷新', () {
      final old = WhitelistData.fromJson({
        'version': 3,
        'upowners': [
          {
            'mid': 100,
            'name': 'A',
            'face': '',
            'added_at': '2026-01-01T00:00:00Z',
          },
        ],
        'videos': [],
      });
      final v4 = old.normalizedForSave();
      expect(v4.version, 4);
      expect(DateTime.tryParse(v4.updatedAt), isNotNull);
      final json = v4.toJson();
      expect(json['version'], 4);
      expect(json.containsKey('upowners'), isTrue);
      expect((json['upowners'] as List), hasLength(1));
    });

    test('currentVersion 常量 = 4', () {
      expect(WhitelistData.currentVersion, 4);
    });
  });
}