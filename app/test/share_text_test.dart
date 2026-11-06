// 分享链接 / 分享文案的纯函数断言（v2.62.0）。
//
// 这一层是分享功能里**唯一有分支**的地方（分 P / 进度），所以逐条钉住：
// - 单 P 视频：链接**不带**任何 query（`?p=1` 只是噪音，站外 App 会当跟踪码）；
// - 多 P：`?p=N` 是 **1 起**的序号，与 B 站站内链接一致；
// - 进度：`?t=` 只在调用方给了 >0 的秒数时出现，且排在 `p` 之后（同一集同一
//   位置拼出的 URL 逐字节相同，便于排查）；
// - 文案：标题一行、链接一行（标题空时只给链接）。
//
// 原生通道的参数另有 widget 层断言（`player_bottom_bar_items_test.dart`），
// 这里只测纯字符串，不碰通道、不碰网络。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/share_text.dart';

void main() {
  group('buildVideoShareUrl', () {
    test('单 P：只有基础链接，不带任何 query', () {
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD'),
          'https://www.bilibili.com/video/BV1xx411c7mD');
    });

    test('多 P：带 ?p=N（1 起）', () {
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD', page: 2),
          'https://www.bilibili.com/video/BV1xx411c7mD?p=2');
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD', page: 1),
          'https://www.bilibili.com/video/BV1xx411c7mD?p=1',
          reason: 'p=1 也照写：多 P 的第一集同样要落对');
    });

    test('带进度：p 在前、t 在后（顺序固定）', () {
      expect(
        buildVideoShareUrl(bvid: 'BV1xx411c7mD', page: 3, positionSeconds: 42),
        'https://www.bilibili.com/video/BV1xx411c7mD?p=3&t=42',
      );
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD', positionSeconds: 42),
          'https://www.bilibili.com/video/BV1xx411c7mD?t=42',
          reason: '单 P 也能带进度（只是不带 p）');
    });

    test('非法 p（0 / 负数）与 0 秒：都不写进 query', () {
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD', page: 0),
          'https://www.bilibili.com/video/BV1xx411c7mD');
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD', page: -1),
          'https://www.bilibili.com/video/BV1xx411c7mD');
      expect(buildVideoShareUrl(bvid: 'BV1xx411c7mD', positionSeconds: 0),
          'https://www.bilibili.com/video/BV1xx411c7mD',
          reason: '0 秒定位对谁都没意义，别给链接加看不懂的尾巴');
    });
  });

  group('buildVideoShareText', () {
    test('标题一行、链接一行', () {
      expect(
        buildVideoShareText(
          title: '某个视频标题',
          url: 'https://www.bilibili.com/video/BV1xx411c7mD?p=2',
        ),
        '某个视频标题\nhttps://www.bilibili.com/video/BV1xx411c7mD?p=2',
      );
    });

    test('标题首尾空白吃掉；标题为空时只给链接', () {
      expect(
        buildVideoShareText(
          title: '  带空白的标题  ',
          url: 'https://www.bilibili.com/video/BV1xx411c7mD',
        ),
        '带空白的标题\nhttps://www.bilibili.com/video/BV1xx411c7mD',
      );
      expect(
        buildVideoShareText(
          title: '   ',
          url: 'https://www.bilibili.com/video/BV1xx411c7mD',
        ),
        'https://www.bilibili.com/video/BV1xx411c7mD',
        reason: '没有标题就不留一个空行',
      );
    });
  });
}
