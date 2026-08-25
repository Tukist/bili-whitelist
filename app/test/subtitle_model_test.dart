// 字幕模型单元测试：
// - SubtitleTrack.fromJson 解析
// - parseSubtitleCues 容错（非法 JSON / 结构异常 / 单条跳过 / BOM 剥离）
// - currentCue 逻辑（单行 / 跨行 / 同时间多行取最后 / 越界 / 边界）
// 纯 Dart，不访问网络、不依赖 Flutter 绑定。
import 'package:bili_whitelist_app/models/subtitle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubtitleTrack.fromJson', () {
    test('正常解析 lan/lan_doc/subtitle_url', () {
      final t = SubtitleTrack.fromJson({
        'lan': 'ai-zh',
        'lan_doc': '中文（自动生成）',
        'subtitle_url': '//i0.hdslb.com/bfs/subtitle/abc.json',
      });
      expect(t.lan, 'ai-zh');
      expect(t.lanDoc, '中文（自动生成）');
      expect(t.subtitleUrl, startsWith('//'));
    });

    test('字段缺失 → 空串兜底', () {
      final t = SubtitleTrack.fromJson({});
      expect(t.lan, '');
      expect(t.lanDoc, '');
      expect(t.subtitleUrl, '');
    });

    test('cacheKey 拼 bvid_cid_lan', () {
      final t = SubtitleTrack.fromJson({'lan': 'ai-en'});
      expect(t.cacheKey('BV1xx', 123), 'BV1xx_123_ai-en');
    });
  });

  group('parseSubtitleCues', () {
    const valid = '{"body":[{"from":1.0,"to":2.0,"content":"你好"},'
        '{"from":2.5,"to":3.5,"content":"世界"}]}';

    test('正常解析 body 列表', () {
      final cues = parseSubtitleCues(valid);
      expect(cues, hasLength(2));
      expect(cues[0].from, 1.0);
      expect(cues[0].to, 2.0);
      expect(cues[0].content, '你好');
      expect(cues[1].content, '世界');
    });

    test('非法 JSON → 空列表', () {
      expect(parseSubtitleCues('not-json{'), isEmpty);
      expect(parseSubtitleCues(''), isEmpty);
      expect(parseSubtitleCues('   '), isEmpty);
    });

    test('顶层非对象 / body 非列表 → 空列表', () {
      expect(parseSubtitleCues('[1,2,3]'), isEmpty);
      expect(parseSubtitleCues('{"body":"nope"}'), isEmpty);
      expect(parseSubtitleCues('{"body":null}'), isEmpty);
      expect(parseSubtitleCues('{"no_body":[]}'), isEmpty);
    });

    test('单条字段缺失/类型异常 → 跳过该条，不影响其余', () {
      final cues = parseSubtitleCues('{"body":['
          '{"from":1,"to":2,"content":"好"},'
          '{"from":3,"to":4},' // content 缺失
          '{"from":5,"to":6,"content":123},' // content 类型异常
          '{"from":7,"content":"no-to"},' // to 缺失
          '{"from":"x","to":8,"content":"bad"},' // from 类型异常
          '{"from":9,"to":10,"content":""},' // 空文本
          '{"from":11,"to":12,"content":"留"}' // 正常
          ']}');
      expect(cues, hasLength(2));
      expect(cues[0].content, '好');
      expect(cues[1].content, '留');
    });

    test('body 里混入非 Map 项 → 跳过', () {
      final cues = parseSubtitleCues('{"body":[{"from":1,"to":2,"content":"a"},'
          '"bogus",42,null]}');
      expect(cues, hasLength(1));
      expect(cues[0].content, 'a');
    });

    test('UTF-8 BOM 剥离后正常解析', () {
      final cues = parseSubtitleCues('\uFEFF$valid');
      expect(cues, hasLength(2));
    });
  });

  group('currentCue', () {
    const cues = [
      SubtitleCue(from: 0, to: 2, content: '第一句'),
      SubtitleCue(from: 2.5, to: 4, content: '第二句'),
      SubtitleCue(from: 5, to: 6, content: '第三句'),
    ];

    test('命中区间内 → 返回该句', () {
      expect(currentCue(cues, 1000)?.content, '第一句'); // pos=1s
      expect(currentCue(cues, 3000)?.content, '第二句'); // pos=3s
      expect(currentCue(cues, 5500)?.content, '第三句'); // pos=5.5s
    });

    test('边界值（from/to 端点）命中', () {
      expect(currentCue(cues, 0)?.content, '第一句'); // pos=0 == from
      expect(currentCue(cues, 2000)?.content, '第一句'); // pos=2 == to
      expect(currentCue(cues, 2500)?.content, '第二句'); // pos=2.5 == from
    });

    test('越界（间隙 / 之前 / 之后）→ null', () {
      expect(currentCue(cues, 2200), isNull); // pos=2.2 落在 gap
      expect(currentCue(cues, -500), isNull); // 负位置
      expect(currentCue(cues, 6100), isNull); // 超过最后一句
    });

    test('同一时刻多条命中 → 取最后一条', () {
      const dup = [
        SubtitleCue(from: 0, to: 10, content: '长句'),
        SubtitleCue(from: 1, to: 2, content: '短句'),
      ];
      expect(currentCue(dup, 1500)?.content, '短句'); // 两者都命中，取列表最后
    });

    test('空列表 → null', () {
      expect(currentCue(const [], 1000), isNull);
    });
  });
}
