// filterUpownerVideosByKeyword 客户端兜底过滤单元测试：
// - 空白关键词 → 原列表（不过滤）
// - 关键词大小写不敏感子串匹配
// - 无匹配 → 空列表
// 背景：B 站 arc/search 的 keyword 参数实测（2026-09）在部分环境下不生效
// （keyword=AI 仍返回未过滤列表），客户端按标题子串兜底保证搜索可用。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';

WhitelistVideo _v(String bvid, String title) => WhitelistVideo(
      bvid: bvid,
      cid: 0,
      title: title,
      cover: '',
      duration: 0,
      upName: 'UP',
      addedAt: '2026-01-01T00:00:00.000Z',
    );

void main() {
  final videos = [
    _v('BV1a', '【泛式】ChatGPT 动画杂谈'),
    _v('BV2b', '【泛式】T.E.I.O 剧情 MAD'),
    _v('BV3c', '【泛式】若叶睦同学'),
  ];

  test('空白关键词 → 返回原列表', () {
    expect(filterUpownerVideosByKeyword(videos, ''), same(videos));
    expect(filterUpownerVideosByKeyword(videos, '   '), same(videos));
  });

  test('关键词命中标题 → 只保留匹配项', () {
    final r = filterUpownerVideosByKeyword(videos, 'MAD');
    expect(r.map((v) => v.bvid), ['BV2b']);
  });

  test('大小写不敏感匹配', () {
    final r = filterUpownerVideosByKeyword(videos, 'chatgpt');
    expect(r.map((v) => v.bvid), ['BV1a']);
  });

  test('无匹配 → 空列表', () {
    expect(filterUpownerVideosByKeyword(videos, 'qwertyuiop'), isEmpty);
  });
}
