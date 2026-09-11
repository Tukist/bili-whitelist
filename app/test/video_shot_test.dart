/// 视频进度预览图（雪碧图）模型与纯函数单测。
///
/// 覆盖（不触网，纯计算）：
/// - [VideoShotInfo.fromJson]：标准 JSON / `{code,data}` 信封 / 字段缺失 /
///   非法值 / `//` URL 补 `https:` / `index` 回跳钳平与元素不丢（对齐网格）
/// - [VideoShotInfo.shotIndexForSeconds]：二分正确性（含**前两项都是 0**、
///   时间 0、并列取小序号、超出两端、空数组）
/// - [VideoShotInfo.cellForShot]：多张雪碧图时的 spriteIndex + 格坐标
///   （xLen=10 样本手算校验）、越界/元信息不可用的零尺寸兜底
/// - [VideoShotInfo.perSprite] / [VideoShotInfo.shotCount]
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/video_shot.dart';

/// 造一个「每 5 秒一张」的规整样本（便于手算期望值）。
VideoShotInfo _build({
  List<int>? seconds,
  int spriteCount = 1,
  int xLen = 10,
  int yLen = 10,
  int xSize = 160,
  int ySize = 90,
}) =>
    VideoShotInfo(
      spriteUrls: List.generate(
        spriteCount,
        (i) => 'https://i0.hdslb.com/bfs/videoshot/sprite$i.jpg',
      ),
      xLen: xLen,
      yLen: yLen,
      xSize: xSize,
      ySize: ySize,
      indexSeconds: seconds ?? List.generate(300, (i) => i * 5),
    );

void main() {
  group('VideoShotInfo.fromJson', () {
    test('标准 data 对象：URL 补 https、网格/单格/index 全解析', () {
      final info = VideoShotInfo.fromJson({
        'pvdata': '//i0.hdslb.com/bfs/videoshot/137649199.bin',
        'img_x_len': 10,
        'img_y_len': 10,
        'img_x_size': 160,
        'img_y_size': 90,
        'image': [
          '//i0.hdslb.com/bfs/videoshot/137649199.jpg',
          '//i0.hdslb.com/bfs/videoshot/137649199_1.jpg',
        ],
        'index': [0, 0, 5, 11, 17],
      });

      expect(info.spriteUrls, [
        'https://i0.hdslb.com/bfs/videoshot/137649199.jpg',
        'https://i0.hdslb.com/bfs/videoshot/137649199_1.jpg',
      ]);
      expect(info.xLen, 10);
      expect(info.yLen, 10);
      expect(info.xSize, 160);
      expect(info.ySize, 90);
      expect(info.indexSeconds, [0, 0, 5, 11, 17]);
      expect(info.perSprite, 100);
      expect(info.shotCount, 5);
    });

    test('也能吃 {code,data} 外层信封（容错）', () {
      final info = VideoShotInfo.fromJson({
        'code': 0,
        'message': '0',
        'data': {
          'img_x_len': 5,
          'img_y_len': 4,
          'img_x_size': 320,
          'img_y_size': 180,
          'image': ['//i0.hdslb.com/a.jpg'],
          'index': [0, 8, 16],
        },
      });
      expect(info.xLen, 5);
      expect(info.yLen, 4);
      expect(info.perSprite, 20);
      expect(info.xSize, 320);
      expect(info.shotCount, 3);
      expect(info.spriteUrls, ['https://i0.hdslb.com/a.jpg']);
    });

    test('字段缺失/为空：给安全默认且不抛错', () {
      final info = VideoShotInfo.fromJson({});
      expect(info.spriteUrls, isEmpty);
      expect(info.indexSeconds, isEmpty);
      // 默认网格 10x10 / 单格 160x90
      expect(info.xLen, 10);
      expect(info.yLen, 10);
      expect(info.xSize, 160);
      expect(info.ySize, 90);
      expect(info.perSprite, 100);
      expect(info.shotCount, 0);
      // 没有图 → 无预览可用
      expect(info.shotIndexForSeconds(0), -1);
      expect(info.cellForShot(0).width, 0);
      expect(info.cellForShot(0).height, 0);
    });

    test('非法值：0/负数/字符串/类型不符 → 默认或忽略', () {
      final info = VideoShotInfo.fromJson({
        'img_x_len': 0, // 非正 → 默认 10
        'img_y_len': -3, // 非正 → 默认 10
        'img_x_size': '160', // 字符串数字 → 解析成功
        'img_y_size': null, // 缺失 → 默认 90
        'image': [
          '//i0.hdslb.com/ok.jpg',
          '', // 空串剔除
          '   ', // 全空格剔除
          123, // 非字符串忽略
          null, // null 忽略
          'https://i0.hdslb.com/full.jpg', // 已是完整 URL → 原样
        ],
        'index': [0, 10, 5, 20], // 第 3 项回跳 → 钳平成上一项
      });

      expect(info.xLen, 10);
      expect(info.yLen, 10);
      expect(info.xSize, 160);
      expect(info.ySize, 90);
      expect(info.spriteUrls, [
        'https://i0.hdslb.com/ok.jpg',
        'https://i0.hdslb.com/full.jpg',
      ]);
      // 钳平但**不丢元素**（丢了会让序号 → 格坐标整体错位）
      expect(info.indexSeconds, [0, 10, 10, 20]);
      expect(info.shotCount, 4);
    });

    test('index 里的非数字项：用前一项顶替，保持长度不变', () {
      final info = VideoShotInfo.fromJson({
        'img_x_len': 10,
        'img_y_len': 10,
        'image': ['//i0.hdslb.com/a.jpg'],
        'index': [0, '12', null, 30],
      });
      expect(info.indexSeconds, [0, 12, 12, 30]);
    });
  });

  group('shotIndexForSeconds（二分，纯函数）', () {
    test('空数组 → -1', () {
      final info = _build(seconds: const []);
      expect(info.shotIndexForSeconds(0), -1);
      expect(info.shotIndexForSeconds(999), -1);
    });

    test('前两项都是 0 的边界：时间 0 稳定落到序号 0', () {
      final info = _build(seconds: const [0, 0, 5, 11, 17]);
      expect(info.shotIndexForSeconds(0), 0);
      expect(info.shotIndexForSeconds(1), 1); // |0-1|=1 < |5-1|=4
      expect(info.shotIndexForSeconds(2), 1); // 并列 2/3 → 取更小序号 1
      expect(info.shotIndexForSeconds(3), 2); // |5-3|=2 < |0-3|=3
      expect(info.shotIndexForSeconds(4), 2);
      expect(info.shotIndexForSeconds(5), 2); // 精确命中
      expect(info.shotIndexForSeconds(8), 2); // 与 11 并列 → 取更小
      expect(info.shotIndexForSeconds(11), 3);
      expect(info.shotIndexForSeconds(16), 4); // |17-16|=1 < |11-16|=5
    });

    test('负时间钳到首项；超出末尾钳到末项', () {
      final info = _build(seconds: const [0, 0, 5, 11, 17]);
      expect(info.shotIndexForSeconds(-1), 0);
      expect(info.shotIndexForSeconds(-100), 0);
      expect(info.shotIndexForSeconds(17), 4);
      expect(info.shotIndexForSeconds(99999), 4);
    });

    test('长数组逐点校验：结果是最近项 + 序号单调不减 + 稳定', () {
      // 真实粒度 ≈5s/张，混入前两项 0 的坑
      final seconds = <int>[0, 0];
      for (var i = 1; i <= 200; i++) {
        seconds.add((i * 5.3).round());
      }
      final info = _build(seconds: seconds);
      var prevIdx = 0;
      for (var s = 0; s <= 1100; s++) {
        final idx = info.shotIndexForSeconds(s);
        // ① 结果必须是最近项（距离 = 全局最小距离）
        var minD = 1 << 30;
        for (final v in seconds) {
          final d = (v - s).abs();
          if (d < minD) minD = d;
        }
        expect((seconds[idx] - s).abs(), minD, reason: 's=$s 不是最近项');
        // ② 单调不减：向右拖动时帧序号不会倒退（UI 观感要求）
        expect(idx, greaterThanOrEqualTo(prevIdx), reason: 's=$s 序号倒退');
        prevIdx = idx;
        // ③ 稳定：同一时间多次调用结果一致
        expect(info.shotIndexForSeconds(s), idx, reason: 's=$s 结果不稳定');
      }
    });

    test('单调严格递增样本精确命中', () {
      final info = _build(seconds: List.generate(50, (i) => i * 6));
      for (var i = 0; i < 50; i++) {
        expect(info.shotIndexForSeconds(i * 6), i);
      }
    });
  });

  group('cellForShot（多张雪碧图裁剪，纯函数）', () {
    test('xLen=10/yLen=10：手算逐点校验', () {
      final info = _build(spriteCount: 3);

      // 第 1 张：shot 0~99
      expect(
        info.cellForShot(0),
        (spriteIndex: 0, left: 0, top: 0, width: 160, height: 90),
      );
      expect(
        info.cellForShot(9),
        (spriteIndex: 0, left: 1440, top: 0, width: 160, height: 90),
      );
      expect(
        info.cellForShot(10), // 换行
        (spriteIndex: 0, left: 0, top: 90, width: 160, height: 90),
      );
      expect(
        info.cellForShot(99), // 第 1 张最后一格
        (spriteIndex: 0, left: 1440, top: 810, width: 160, height: 90),
      );

      // 第 2 张：shot 100~199
      expect(
        info.cellForShot(100),
        (spriteIndex: 1, left: 0, top: 0, width: 160, height: 90),
      );
      expect(
        info.cellForShot(105), // within=5 → row0/col5
        (spriteIndex: 1, left: 800, top: 0, width: 160, height: 90),
      );

      // 第 3 张：shot 200~299
      expect(
        info.cellForShot(205),
        (spriteIndex: 2, left: 800, top: 0, width: 160, height: 90),
      );
      expect(
        info.cellForShot(299), // 全表最后一格
        (spriteIndex: 2, left: 1440, top: 810, width: 160, height: 90),
      );
    });

    test('越界/负数序号 → 零尺寸（调用方按无预览降级）', () {
      final info = _build(spriteCount: 2); // perSprite=100 → 上限 shot 199
      expect(info.cellForShot(-1).width, 0);
      expect(info.cellForShot(-1).height, 0);
      expect(info.cellForShot(300).width, 0);
      expect(info.cellForShot(300).height, 0);
    });

    test('元信息与图片张数不一致时 spriteIndex 钳到末张（不越界）', () {
      // index 有 300 项（算出 3 张），但只有 2 张图 → 钳到 1
      final info = _build(spriteCount: 2);
      expect(info.cellForShot(205).spriteIndex, 1);
      expect(info.cellForShot(205).left, 800);
    });

    test('没有图片 / 网格非法 → 零尺寸', () {
      final noImage = _build(spriteCount: 0);
      expect(noImage.cellForShot(0).width, 0);

      final badGrid = VideoShotInfo(
        spriteUrls: const ['https://i0.hdslb.com/a.jpg'],
        xLen: 10,
        yLen: 10,
        xSize: 0, // 非法单格宽
        ySize: 90,
        indexSeconds: const [0, 5],
      );
      expect(badGrid.cellForShot(0).width, 0);
      expect(badGrid.cellForShot(0).height, 0);
    });

    test('单格尺寸与网格自由组合（非 10x10）也自洽', () {
      final info = _build(
        seconds: List.generate(40, (i) => i * 5),
        spriteCount: 2,
        xLen: 5,
        yLen: 4,
        xSize: 320,
        ySize: 180,
      );
      expect(info.perSprite, 20);
      expect(
        info.cellForShot(19),
        (spriteIndex: 0, left: 1280, top: 540, width: 320, height: 180),
      );
      expect(
        info.cellForShot(20),
        (spriteIndex: 1, left: 0, top: 0, width: 320, height: 180),
      );
    });
  });

  group('perSprite / shotCount', () {
    test('perSprite = xLen*yLen；shotCount = index 长度', () {
      expect(_build(xLen: 10, yLen: 10).perSprite, 100);
      expect(_build(xLen: 5, yLen: 5).perSprite, 25);
      expect(_build(seconds: const [0, 1, 2]).shotCount, 3);
      expect(_build(seconds: const []).shotCount, 0);
    });
  });
}
