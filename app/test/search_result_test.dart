// SearchResult 模型单元测试：标题清洗 / 封面补全 / 时长解析 / 播放量解析 / 整条解析。
//
// 顺带覆盖 SearchPageResult 字段契约（v2.12.1+ 引入）：
// - results / totalCount / hasMore 三字段语义；
// - hasMore 的两条判断路径（numResults 已知 / 未知）由 search_api_test
//   走真实 mock adapter 验证；本文件只做模型层 shape 断言。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/search_result.dart';

void main() {
  group('cleanTitle', () {
    test('去除 <em class="keyword"> 高亮标签', () {
      expect(
        SearchResult.cleanTitle('旅人の唄 - <em class="keyword">无职转生</em> OP'),
        '旅人の唄 - 无职转生 OP',
      );
    });

    test('解码常见 HTML 实体', () {
      expect(SearchResult.cleanTitle('a &amp; b &lt;c&gt; &quot;d&quot;'),
          'a & b <c> "d"');
    });
  });

  group('normalizeCover', () {
    test('// 开头补 https:', () {
      expect(SearchResult.normalizeCover('//i0.hdslb.com/bfs/archive/a.jpg'),
          'https://i0.hdslb.com/bfs/archive/a.jpg');
    });

    test('已有协议头原样返回', () {
      expect(SearchResult.normalizeCover('https://i0.hdslb.com/a.jpg'),
          'https://i0.hdslb.com/a.jpg');
    });
  });

  group('parseDuration', () {
    test('MM:SS → 秒', () => expect(SearchResult.parseDuration('4:45'), 285));
    test('H:MM:SS → 秒', () => expect(SearchResult.parseDuration('1:23:45'), 5025));
    test('数字原样', () => expect(SearchResult.parseDuration(120), 120));
    test('非法字符串 → 0', () => expect(SearchResult.parseDuration('abc'), 0));
    test('空串 → 0', () => expect(SearchResult.parseDuration(''), 0));
  });

  group('parsePlayCount', () {
    test('int 直接用', () => expect(SearchResult.parsePlayCount(179906), 179906));
    test('万', () => expect(SearchResult.parsePlayCount('12.3万'), 123000));
    test('亿', () => expect(SearchResult.parsePlayCount('1.2亿'), 120000000));
    test('纯数字字符串', () => expect(SearchResult.parsePlayCount('179906'), 179906));
    test('千位逗号', () => expect(SearchResult.parsePlayCount('1,234'), 1234));
    test('非法 → 0', () => expect(SearchResult.parsePlayCount('abc'), 0));
  });

  group('fromSearchJson', () {
    test('完整解析一条真实接口结构（清洗 + 补全 + 转换）', () {
      final r = SearchResult.fromSearchJson({
        'bvid': 'BV1g5411J7Lh',
        'title': '旅人の唄 - <em class="keyword">无职转生</em> OP',
        'pic': '//i0.hdslb.com/bfs/archive/a.jpg',
        'author': 'Zyglisfer',
        'duration': '4:45',
        'play': 179906,
        'pubdate': 1611978055,
      });
      expect(r.bvid, 'BV1g5411J7Lh');
      expect(r.title, '旅人の唄 - 无职转生 OP');
      expect(r.cover, 'https://i0.hdslb.com/bfs/archive/a.jpg');
      expect(r.author, 'Zyglisfer');
      expect(r.durationSec, 285);
      expect(r.playCount, 179906);
      expect(r.pubDate, 1611978055);
    });

    test('缺字段容错（不抛错，给空/0）', () {
      final r = SearchResult.fromSearchJson({'bvid': 'BV1'});
      expect(r.bvid, 'BV1');
      expect(r.title, '');
      expect(r.cover, '');
      expect(r.author, '');
      expect(r.durationSec, 0);
      expect(r.playCount, 0);
      expect(r.pubDate, 0);
    });
  });

  group('SearchPageResult', () {
    test('构造：results / totalCount / hasMore 字段透传', () {
      const page = SearchPageResult(
        results: [],
        totalCount: 100,
        hasMore: true,
      );
      expect(page.results, isEmpty);
      expect(page.totalCount, 100);
      expect(page.hasMore, isTrue);
    });

    test('totalCount 为 null 表示「未知命中数」（hasMore 由调用方判定）', () {
      const page = SearchPageResult(
        results: [],
        totalCount: null,
        hasMore: false,
      );
      expect(page.totalCount, isNull);
      expect(page.hasMore, isFalse);
    });
  });
}
