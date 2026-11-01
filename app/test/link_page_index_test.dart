// `?p=` / `?t=` → 播放页初始分 P 下标的**唯一**换算规则（v2.58.0 收口）。
//
// 背景（这次结的"小账"）：同一个语义在两个入口各写了一套 ——
// 评论链接兜底预览传 `pageIndex ?? (positionMs != null ? 0 : null)`，
// 剪贴板/分享链接直接传 `pageIndex`（于是只带 `?t=` 的链接走集数记忆）。
// 现在两处都调用 `initialPageIndexOfLink`，本文件把三种情形钉死：
//   有 `?p=N` → N；没有 `?p` 但有 `?t=` → 0；两者都没有 → null。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/comment_links.dart';

void main() {
  group('initialPageIndexOfLink（三种情形）', () {
    test('有 ?p=N → 显式 N（不被集数记忆覆盖）', () {
      expect(initialPageIndexOfLink(pageIndex: 2, positionMs: null), 2);
      expect(initialPageIndexOfLink(pageIndex: 0, positionMs: null), 0,
          reason: '?p=1 → 0 也是"显式"，不是"没指定"');
      // 同时带 t：仍是 p 说了算
      expect(initialPageIndexOfLink(pageIndex: 3, positionMs: 45000), 3);
    });

    test('只有 ?t= → 显式 0（第 1 集；t 说的是"这个视频的第 N 秒"）', () {
      expect(initialPageIndexOfLink(pageIndex: null, positionMs: 45000), 0);
      expect(initialPageIndexOfLink(positionMs: 1), 0,
          reason: '哪怕只有 1ms 也是"带 t"');
    });

    test('都没有 → null（走本地「上次看到第几 P」记忆）', () {
      expect(initialPageIndexOfLink(), isNull);
      expect(initialPageIndexOfLink(pageIndex: null, positionMs: null), isNull);
    });
  });

  group('与链接解析串起来（端到端语义）', () {
    test('?p=2&t=45 → 第 2 集（下标 1）', () {
      final pos = parseVideoLinkPosition(
          'https://www.bilibili.com/video/BV1aa411c7dd?p=2&t=45');
      expect(pos.pageIndex, 1);
      expect(pos.positionMs, 45000);
      expect(
        initialPageIndexOfLink(
          pageIndex: pos.pageIndex,
          positionMs: pos.positionMs,
        ),
        1,
      );
    });

    test('只有 ?t=45 → 第 1 集（下标 0），不是记忆里的第 5 集', () {
      final pos = parseVideoLinkPosition(
          'https://www.bilibili.com/video/BV1aa411c7dd?t=45');
      expect(pos.pageIndex, isNull);
      expect(pos.positionMs, 45000);
      expect(
        initialPageIndexOfLink(
          pageIndex: pos.pageIndex,
          positionMs: pos.positionMs,
        ),
        0,
      );
    });

    test('裸链接（无参数）→ null（交给集数记忆）', () {
      final pos =
          parseVideoLinkPosition('https://www.bilibili.com/video/BV1aa411c7dd');
      expect(pos.pageIndex, isNull);
      expect(pos.positionMs, isNull);
      expect(
        initialPageIndexOfLink(
          pageIndex: pos.pageIndex,
          positionMs: pos.positionMs,
        ),
        isNull,
      );
    });
  });
}
