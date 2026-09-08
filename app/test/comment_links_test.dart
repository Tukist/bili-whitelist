// 评论正文链接识别/分类（v2.16.19+）单测。
//
// 覆盖：完整视频链接（www./m.、带查询参数）、裸 BV、b23 短链（带协议头/
// 裸）、UP 空间（带协议头/裸、space.bilibili.com 与 /space/ 两种形态）、
// 番剧（ep/ss）、其他通用 http(s)、正文混排（标点裁剪/换行保留）、无链接
// 纯文本。纯正则无网络。
import 'package:bili_whitelist_app/utils/comment_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitCommentLinks 正文拆分', () {
    test('无链接：单段纯文本（评论页据此保持 SelectableText）', () {
      final segs = splitCommentLinks('这是一条普通评论，没有链接。');
      expect(segs.length, 1);
      expect(segs.first.isLink, isFalse);
      expect(segs.first.text, '这是一条普通评论，没有链接。');
    });

    test('空串 → 空列表', () {
      expect(splitCommentLinks(''), isEmpty);
    });

    test('完整视频链接：拆成 文本/链接/文本 三段', () {
      final segs = splitCommentLinks('看这个 https://www.bilibili.com/video/BV1fK4y1s7Uz 超好看');
      expect(segs.length, 3);
      expect(segs[0].text, '看这个 ');
      expect(segs[1].isLink, isTrue);
      expect(segs[1].link!.kind, CommentLinkKind.video);
      expect(segs[1].link!.bvid, 'BV1fK4y1s7Uz');
      expect(segs[1].text, 'https://www.bilibili.com/video/BV1fK4y1s7Uz');
      expect(segs[2].text, ' 超好看');
    });

    test('m.bilibili 视频 + 查询参数（p=）整段识别', () {
      final segs = splitCommentLinks('推荐 https://m.bilibili.com/video/BV1GJ411x7h7?p=2&t=30s 这段');
      expect(segs.length, 3);
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.video);
      expect(link.bvid, 'BV1GJ411x7h7');
    });

    test('无协议头 www.bilibili.com 视频链接也识别', () {
      final segs = splitCommentLinks('见 www.bilibili.com/video/BV1fK4y1s7Uz 评论');
      expect(segs.length, 3);
      expect(segs[1].link!.kind, CommentLinkKind.video);
      expect(segs[1].link!.bvid, 'BV1fK4y1s7Uz');
    });

    test('裸 BV 号（正文独立出现）识别为视频', () {
      final segs = splitCommentLinks('新视频 BV1fK4y1s7Uz 不错');
      expect(segs.length, 3);
      expect(segs[1].link!.kind, CommentLinkKind.video);
      expect(segs[1].link!.bvid, 'BV1fK4y1s7Uz');
      // 首尾文字原样保留
      expect(segs[0].text, '新视频 ');
      expect(segs[2].text, ' 不错');
    });

    test('裸 BV 不会拦腰截断更长 ASCII 词（前有字母不命中）', () {
      final segs = splitCommentLinks('abBV1fK4y1s7Uzcd 不是链接位置');
      expect(segs.length, 1); // 整段纯文本
      expect(segs.first.isLink, isFalse);
    });

    test('b23 短链（带协议头）→ b23 分类，原文保留待点击解析', () {
      final segs = splitCommentLinks('点开 https://b23.tv/spVKBAi 就有');
      expect(segs.length, 3);
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.b23);
      expect(link.raw, 'https://b23.tv/spVKBAi');
    });

    test('裸 b23.tv 短码也识别（补协议头在点击时才做）', () {
      final segs = splitCommentLinks('链接 b23.tv/spVKBAi 分享');
      expect(segs.length, 3);
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.b23);
      expect(link.raw, 'b23.tv/spVKBAi');
    });

    test('UP 空间 space.bilibili.com/<uid> → up + mid', () {
      final segs = splitCommentLinks('主站 https://space.bilibili.com/123456 快去');
      expect(segs.length, 3);
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.up);
      expect(link.upMid, 123456);
    });

    test('UP 空间 /space/<uid> 形态也识别', () {
      final segs = splitCommentLinks('主页 https://www.bilibili.com/space/888');
      expect(segs.length, 2);
      expect(segs[0].text, '主页 ');
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.up);
      expect(link.upMid, 888);
    });

    test('裸 space.bilibili.com/<uid> 也识别为 up', () {
      final segs = splitCommentLinks('看看 space.bilibili.com/555 的视频');
      expect(segs.length, 3);
      expect(segs[1].link!.kind, CommentLinkKind.up);
      expect(segs[1].link!.upMid, 555);
    });

    test('番剧 ep 链接 → bangumi', () {
      final segs = splitCommentLinks('这集 https://www.bilibili.com/bangumi/play/ep98603 好看');
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.bangumi);
      expect(link.bangumiRef, 'ep98603');
    });

    test('番剧 ss + 大写 EP 容忍', () {
      final segs = splitCommentLinks('https://www.bilibili.com/bangumi/play/SS5800');
      expect(segs[0].link!.kind, CommentLinkKind.bangumi);
      expect(segs[0].link!.bangumiRef, 'ss5800');
    });

    test('其他 http(s) 链接 → other', () {
      final segs = splitCommentLinks('官网 https://example.com/docs/guide?a=1#top 看文档');
      expect(segs.length, 3);
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.other);
      expect(link.raw, 'https://example.com/docs/guide?a=1#top');
    });

    test('URL 尾随中英文标点被裁剪（标点不算链接内容）', () {
      final segs = splitCommentLinks('见 https://example.com/x?a=1，谢谢！');
      expect(segs.length, 3);
      expect(segs[1].link!.kind, CommentLinkKind.other);
      expect(segs[1].link!.raw, 'https://example.com/x?a=1');
      expect(segs[2].text, '，谢谢！');
    });

    test('换行正文里链接识别不吞相邻文字（文本段含换行）', () {
      final segs = splitCommentLinks('第一行没链接\n第二行 https://b23.tv/abc1 结尾');
      expect(segs.length, 3);
      expect(segs[0].text, '第一行没链接\n第二行 ');
      expect(segs[1].link!.kind, CommentLinkKind.b23);
      expect(segs[2].text, ' 结尾');
    });

    test('多个链接依次拆分且顺序/文本不丢', () {
      final text = 'A https://www.bilibili.com/video/BV1fK4y1s7Uz/ B https://example.com C b23.tv/xyz1 D';
      final segs = splitCommentLinks(text);
      final kinds = [for (final s in segs) if (s.isLink) s.link!.kind];
      expect(kinds, [
        CommentLinkKind.video,
        CommentLinkKind.other,
        CommentLinkKind.b23,
      ]);
      // 纯文本部分全部保留且顺序正确
      final plain = segs.where((s) => !s.isLink).map((s) => s.text).toList();
      expect(plain, ['A ', ' B ', ' C ', ' D']);
    });
  });

  group('classifyUrl 分类纯逻辑', () {
    test('完整视频 URL（含查询）', () {
      final l = classifyUrl('https://www.bilibili.com/video/BV1GJ411x7h7/?p=1&vd_source=abc');
      expect(l!.kind, CommentLinkKind.video);
      expect(l.bvid, 'BV1GJ411x7h7');
    });

    test('裸 BV', () {
      expect(classifyUrl('BV1fK4y1s7Uz')!.kind, CommentLinkKind.video);
    });

    test('b23（协议头可有可无）', () {
      expect(classifyUrl('https://b23.tv/ab12CD')!.kind, CommentLinkKind.b23);
      expect(classifyUrl('b23.tv/ab12CD')!.kind, CommentLinkKind.b23);
    });

    test('UP 空间两种形态 + mid 解析', () {
      expect(classifyUrl('https://space.bilibili.com/42')!.upMid, 42);
      expect(classifyUrl('space.bilibili.com/42')!.upMid, 42);
      expect(classifyUrl('https://www.bilibili.com/space/42')!.upMid, 42);
    });

    test('番剧 ep / ss', () {
      expect(classifyUrl('https://www.bilibili.com/bangumi/play/ep123456')!.bangumiRef,
          'ep123456');
      expect(classifyUrl('https://www.bilibili.com/bangumi/play/ss789')!.bangumiRef,
          'ss789');
    });

    test('通用链接 / 无法识别', () {
      expect(classifyUrl('https://example.com/a/b')!.kind, CommentLinkKind.other);
      expect(classifyUrl('http://内网地址')!.kind, CommentLinkKind.other);
      expect(classifyUrl('普通文字'), isNull);
      expect(classifyUrl(''), isNull);
    });
  });

  group('parseVideoLinkPosition ?p/?t 定位参数解析（v2.17.6+）', () {
    test('?p=2&t=129.0 → pageIndex=1 + positionMs=129000（p 1起转0起、t 小数秒）', () {
      final pos = parseVideoLinkPosition(
          'https://www.bilibili.com/video/BV1GJ411x7h7/?p=2&t=129.0');
      expect(pos.pageIndex, 1);
      expect(pos.positionMs, 129000);
    });

    test('?p=1 → pageIndex=0（首集，等同默认）', () {
      final pos = parseVideoLinkPosition(
          'https://www.bilibili.com/video/BV1GJ411x7h7?p=1');
      expect(pos.pageIndex, 0);
      expect(pos.positionMs, isNull);
    });

    test('t 整数秒无单位（?t=129）→ 129000ms', () {
      final pos = parseVideoLinkPosition(
          'https://www.bilibili.com/video/BV1GJ411x7h7?t=129');
      expect(pos.pageIndex, isNull);
      expect(pos.positionMs, 129000);
    });

    test('t=Xs / t=XmYs 带单位形式（30s、2m5s、2m5.5s）', () {
      expect(
        parseVideoLinkPosition(
                'https://www.bilibili.com/video/BV1GJ411x7h7?t=30s')
            .positionMs,
        30000,
      );
      expect(
        parseVideoLinkPosition(
                'https://www.bilibili.com/video/BV1GJ411x7h7?t=2m5s')
            .positionMs,
        125000,
      );
      expect(
        parseVideoLinkPosition(
                'https://www.bilibili.com/video/BV1GJ411x7h7?p=3&t=1m30s')
            .positionMs,
        90000,
      );
      expect(
        parseVideoLinkPosition(
                'https://www.bilibili.com/video/BV1GJ411x7h7?t=2m5.5s')
            .positionMs,
        125500,
      );
    });

    test('无 p/t 参数 / 空查询 → 双 null（维持全视频/记忆行为）', () {
      expect(
        parseVideoLinkPosition('https://www.bilibili.com/video/BV1GJ411x7h7'),
        (pageIndex: null, positionMs: null),
      );
      expect(
        parseVideoLinkPosition(
            'https://www.bilibili.com/video/BV1GJ411x7h7?vd_source=abc'),
        (pageIndex: null, positionMs: null),
      );
      // 裸 BV 号（正文引用形态）也没有定位参数
      expect(
        parseVideoLinkPosition('BV1GJ411x7h7'),
        (pageIndex: null, positionMs: null),
      );
    });

    test('多 P 边界：p 大序号原样保留（越界钳制留给播放端实际集数）', () {
      final pos = parseVideoLinkPosition(
          'https://www.bilibili.com/video/BV1GJ411x7h7?p=10&t=60');
      expect(pos.pageIndex, 9);
      expect(pos.positionMs, 60000);
    });

    test('非法参数按无处理：p=0/负数/非数字、t 空/负/字母/冒号/小时制', () {
      // p 非法 → pageIndex null（不分 P）；t 不受影响
      for (final p in ['0', '-1', 'abc']) {
        final pos =
            parseVideoLinkPosition('https://www.bilibili.com/video/BV1xx?p=$p&t=10');
        expect(pos.pageIndex, isNull, reason: 'p=$p 应判无分P');
        expect(pos.positionMs, 10000);
      }
      // t 非法（格式不支持：冒号 mm:ss / XhYmZs / 空 / 负 / 纯字母）→ null
      for (final t in ['', '-5', 'abc', '2:05', '1h2m3s']) {
        final pos = parseVideoLinkPosition(
            'https://www.bilibili.com/video/BV1xx?t=$t');
        expect(pos.positionMs, isNull, reason: 't=$t 应判无进度');
      }
    });

    test('m./无协议头完整视频链接同样解析（www/m/裸 host 均带 query）', () {
      expect(
        parseVideoLinkPosition('https://m.bilibili.com/video/BV1GJ411x7h7?p=2&t=129.0'),
        (pageIndex: 1, positionMs: 129000),
      );
      expect(
        parseVideoLinkPosition('m.bilibili.com/video/BV1GJ411x7h7?p=2&t=129.0'),
        (pageIndex: 1, positionMs: 129000),
      );
      expect(
        parseVideoLinkPosition('www.bilibili.com/video/BV1GJ411x7h7?t=2m5s'),
        (pageIndex: null, positionMs: 125000),
      );
    });
  });

  group('CommentLink 携带定位参数（video 链接 ?p/?t → 点击分发用）', () {
    test('完整视频链接 + ?p/?t → kind=video 且带 pageIndex/positionMs', () {
      final link = classifyUrl(
          'https://www.bilibili.com/video/BV1GJ411x7h7?p=2&t=129.0');
      expect(link!.kind, CommentLinkKind.video);
      expect(link.bvid, 'BV1GJ411x7h7');
      expect(link.pageIndex, 1);
      expect(link.positionMs, 129000);
    });

    test('splitCommentLinks 拆分后链接段保留 ?p/?t 参数', () {
      final segs = splitCommentLinks(
          '推荐 https://m.bilibili.com/video/BV1GJ411x7h7?p=2&t=30s 这段');
      expect(segs.length, 3);
      final link = segs[1].link!;
      expect(link.kind, CommentLinkKind.video);
      expect(link.pageIndex, 1);
      expect(link.positionMs, 30000);
      // 纯文本段不受影响
      expect(segs[0].text, '推荐 ');
      expect(segs[2].text, ' 这段');
    });

    test('无参数视频链接 / 裸 BV → pageIndex/positionMs 均 null（维持旧行为）', () {
      expect(classifyUrl('https://www.bilibili.com/video/BV1GJ411x7h7')!.pageIndex,
          isNull);
      expect(classifyUrl('https://www.bilibili.com/video/BV1GJ411x7h7')!.positionMs,
          isNull);
      expect(classifyUrl('BV1fK4y1s7Uz')!.pageIndex, isNull);
      expect(classifyUrl('BV1fK4y1s7Uz')!.positionMs, isNull);
    });

    test('非 video 分类（b23/up/番剧/other）不带定位参数', () {
      expect(classifyUrl('https://b23.tv/spVKBAi')!.pageIndex, isNull);
      expect(classifyUrl('https://space.bilibili.com/42')!.pageIndex, isNull);
      expect(
          classifyUrl('https://www.bilibili.com/bangumi/play/ep123456')!.positionMs,
          isNull);
      expect(classifyUrl('https://example.com/a?p=2&t=30s')!.positionMs, isNull);
    });
  });
}
