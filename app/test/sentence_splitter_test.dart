/// 实时转写二次分句工具单测。
///
/// 覆盖：纯标点拆、过长短句按逗号拆、无标点长句按空格/硬切、
/// 时间戳按字符数比例分配（覆盖原范围、单调不重叠）、空/单字符容错、
/// 连续标点并入、startTs>endTs 交换。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/sentence_splitter.dart';

void main() {
  group('splitSentence', () {
    test('纯标点拆：句末标点分隔成子句，标点保留在子句尾部', () {
      final parts = splitSentence('你好世界。今天天气不错！', 0, 10);
      expect(parts, hasLength(2));
      expect(parts[0].text, '你好世界。');
      expect(parts[1].text, '今天天气不错！');
    });

    test('中英文标点都识别（。．.!！?？…；;）', () {
      final parts = splitSentence('你好。Good morning! 真的吗?', 0, 9);
      // '你好。' / 'Good morning! ' → trim 后 'Good morning!' / '真的吗?'
      expect(parts, hasLength(3));
      expect(parts[0].text, '你好。');
      expect(parts[1].text, 'Good morning!');
      expect(parts[2].text, '真的吗?');
    });

    test('连续句末标点：孤立纯标点段并入前一子句', () {
      final parts = splitSentence('太好了！！真的吗？', 0, 6);
      expect(parts, hasLength(2));
      expect(parts[0].text, '太好了！！');
      expect(parts[1].text, '真的吗？');
    });

    test('标点开头的文本：前置纯标点并入首子句', () {
      final parts = splitSentence('！你好。', 0, 4);
      expect(parts, hasLength(1));
      expect(parts[0].text, '！你好。');
    });

    test('过长短句（>45 字符）：按逗号拆到 ≤45', () {
      // 62 字符无句末标点（除末尾句号），按逗号拆为 2 段
      final long = '今天是个好日子我们一起去公园散步然后回家吃饭，'
          '顺便买点水果和蔬菜，晚上我们再看一部非常精彩的电影吧，'
          '明天还要早起上班呢。';
      final parts = splitSentence(long, 0, 10);
      expect(parts, hasLength(2));
      expect(parts[0].text,
          '今天是个好日子我们一起去公园散步然后回家吃饭，顺便买点水果和蔬菜，');
      expect(parts[1].text, '晚上我们再看一部非常精彩的电影吧，明天还要早起上班呢。');
      for (final p in parts) {
        expect(p.text.length, lessThanOrEqualTo(maxPartLength));
        expect(p.text, isNotEmpty);
      }
    });

    test('无句末标点但有逗号：也在逗号处拆', () {
      // 58 字符无句末标点，按逗号拆为 2 段（段1 41 字符、段2 17 字符）
      final long = '第一段内容很长很长没有句号但是有逗号，'
          '第二段内容同样很长也没有句号但是有别的词，'
          '第三段内容也很长没有句号但是有逗号';
      final parts = splitSentence(long, 0, 8);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(p.text.length, lessThanOrEqualTo(maxPartLength));
      }
      // 首段以逗号结尾（标点保留）
      expect(parts.first.text.endsWith('，'), isTrue);
      // 拼接还原原文（空格断点才会丢字符，这里只有逗号断点）
      expect(parts.map((p) => p.text).join(), long);
    });

    test('无标点长句：按空格拆', () {
      final long = 'hello world this is a very long sentence without any '
          'punctuation at all so we split at spaces';
      expect(long.length, greaterThan(maxPartLength));
      final parts = splitSentence(long, 0, 10);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(p.text.length, lessThanOrEqualTo(maxPartLength));
        expect(p.text, isNot(startsWith(' ')));
        expect(p.text, isNot(endsWith(' ')));
      }
    });

    test('无任何断点的长串：硬切 maxPartLength', () {
      final long = '汉' * 50;
      final parts = splitSentence(long, 0, 10);
      expect(parts, hasLength(2));
      expect(parts[0].text.length, maxPartLength);
      expect(parts[1].text.length, 5);
      expect(parts[0].text + parts[1].text, long);
    });

    test('时间戳按字符数比例分配：总和覆盖原范围、单调不重叠', () {
      // 四个 2 字符子句各占 25% → [0,2.5][2.5,5][5,7.5][7.5,10]
      final parts = splitSentence('一。二。三。四。', 0, 10);
      expect(parts, hasLength(4));
      expect(parts[0].fromTs, 0);
      expect(parts[0].toTs, closeTo(2.5, 1e-9));
      expect(parts[1].fromTs, closeTo(2.5, 1e-9));
      expect(parts[1].toTs, closeTo(5, 1e-9));
      expect(parts[2].fromTs, closeTo(5, 1e-9));
      expect(parts[2].toTs, closeTo(7.5, 1e-9));
      expect(parts[3].fromTs, closeTo(7.5, 1e-9));
      expect(parts[3].toTs, 10);
      // 单调不重叠
      for (var i = 1; i < parts.length; i++) {
        expect(parts[i].fromTs, greaterThanOrEqualTo(parts[i - 1].toTs));
      }
    });

    test('时间戳比例：非等长子句按字符数比例分配', () {
      // 段1 5 字符、段2 6 字符，共 11 字符，时长 8
      final parts = splitSentence('你好世界。今天天气好。', 0, 8);
      expect(parts, hasLength(2));
      expect(parts[0].text, '你好世界。');
      expect(parts[1].text, '今天天气好。');
      expect(parts[0].fromTs, 0);
      expect(parts[0].toTs, closeTo(8 * 5 / 11, 1e-9));
      expect(parts[1].fromTs, closeTo(8 * 5 / 11, 1e-9));
      expect(parts[1].toTs, 8);
    });

    test('空文本 / 纯空白：返回空列表', () {
      expect(splitSentence('', 0, 10), isEmpty);
      expect(splitSentence('   ', 0, 10), isEmpty);
    });

    test('单字符：单子句，时间戳覆盖原范围', () {
      final parts = splitSentence('好', 3, 5);
      expect(parts, hasLength(1));
      expect(parts[0].text, '好');
      expect(parts[0].fromTs, 3);
      expect(parts[0].toTs, 5);
    });

    test('startTs > endTs：自动交换后分配', () {
      final parts = splitSentence('你好。', 10, 0);
      expect(parts, hasLength(1));
      expect(parts[0].fromTs, 0);
      expect(parts[0].toTs, 10);
    });

    test('零时长（fromTs == toTs）：全部子句时间戳相同', () {
      final parts = splitSentence('一。二。三。', 4, 4);
      expect(parts, hasLength(3));
      for (final p in parts) {
        expect(p.fromTs, 4);
        expect(p.toTs, 4);
      }
    });
  });
}
