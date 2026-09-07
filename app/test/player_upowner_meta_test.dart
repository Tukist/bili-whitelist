// 信息行 UP 主入口元数据解析单测（阶段 C）：
// fetchVideoMeta(bvid) 返回 view 接口的 data map → parseViewOwner 抽
// owner{mid,name,face}（普通视频 UP 入口的 mid/头像来源）。
//
// 纯函数无网络；逻辑见 lib/pages/player_page.dart 顶部。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/player_page.dart';

void main() {
  group('parseViewOwner（view data → UP 主信息）', () {
    test('完整 owner（mid/name/face）→ 三元组', () {
      final r = parseViewOwner({
        'bvid': 'BV1xx',
        'owner': {'mid': 123456, 'name': '老番茄', 'face': 'https://i0.hdslb.com/x.jpg'},
      });
      expect(r, isNotNull);
      expect(r!.mid, 123456);
      expect(r.name, '老番茄');
      expect(r.face, 'https://i0.hdslb.com/x.jpg');
    });

    test('name 带首尾空格 → 去除；face 缺失 → 空串（走首字占位）', () {
      final r = parseViewOwner({
        'owner': {'mid': 1, 'name': '  名字  '},
      });
      expect(r!.name, '名字');
      expect(r.face, '');
    });

    test('owner 缺失（无 UP 主场景）→ null', () {
      expect(parseViewOwner({'bvid': 'BV1xx'}), isNull);
    });

    test('owner 类型异常（List/字符串）→ null 不崩', () {
      expect(parseViewOwner({'owner': '不是 map'}), isNull);
      expect(parseViewOwner({'owner': <int>[1, 2]}), isNull);
    });

    test('mid 缺失 / 为 0 / 为负 → null（无法定位 UP 主页）', () {
      expect(parseViewOwner({'owner': {'name': 'x'}}), isNull);
      expect(parseViewOwner({'owner': {'mid': 0, 'name': 'x'}}), isNull);
      expect(parseViewOwner({'owner': {'mid': -3, 'name': 'x'}}), isNull);
    });

    test('mid 为字符串数字（脏数据）→ 按 0 处理返回 null，不崩', () {
      expect(parseViewOwner({'owner': {'mid': '123', 'name': 'x'}}), isNull);
    });
  });
}
