// TXT 章节切分单测（E1）。
//
// 这一层是纯函数，唯一的硬契约是「偏移连续、覆盖全文、没有空段」——
// 阅读页靠 `text.substring(start, end)` 直接渲染，偏移错一个字符就是
// 「上一章的最后一个字跑到下一章开头」，所以每个用例都顺带断言连续性。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/txt_chapter_splitter.dart';

/// 通用断言：首段从 0 起、相邻严格衔接、末段到全文结束、没有空段。
void expectContiguous(String text, List<TxtChapterSlice> slices) {
  expect(slices, isNotEmpty);
  expect(slices.first.start, 0, reason: '首段必须从 0 开始（否则前面那段文字没人管）');
  expect(slices.last.end, text.length, reason: '末段必须覆盖到全文结尾');
  for (var i = 0; i < slices.length; i++) {
    expect(slices[i].end, greaterThan(slices[i].start), reason: '第 $i 段是空段');
    if (i + 1 < slices.length) {
      expect(slices[i].end, slices[i + 1].start, reason: '第 $i 段与第 ${i + 1} 段之间有缝');
    }
  }
}

void main() {
  group('标准「第X章」', () {
    test('三章 + 结尾，标题与偏移都对', () {
      const text = '第一章 风起\n内容一。\n第二章 云涌\n内容二。\n第三章 雨落\n内容三。';
      final slices = splitTxtChapters(text);
      expect(slices.length, 3);
      expect(slices.map((s) => s.title), ['第一章 风起', '第二章 云涌', '第三章 雨落']);
      expectContiguous(text, slices);
      expect(
        text.substring(slices[1].start, slices[1].end),
        '第二章 云涌\n内容二。\n',
      );
    });

    test('阿拉伯数字 / 全角数字 / 回·节·集 都认', () {
      const text = '第12章 a\nx\n第１３回 b\ny\n第7节 c\nz\n第3集 d\nw';
      final slices = splitTxtChapters(text);
      expect(slices.length, 4);
      expect(slices[0].title, '第12章 a');
      expect(slices[1].title, '第１３回 b');
      expect(slices[2].title, '第7节 c');
      expect(slices[3].title, '第3集 d');
      expectContiguous(text, slices);
    });

    test('卷 + 章混合：卷也断章', () {
      const text = '第一卷 少年\n楔子\n序章内容\n第一章 出山\n正文\n第二卷 江湖\n第二章 入城\n正文';
      final slices = splitTxtChapters(text);
      expect(slices.map((s) => s.title), [
        '第一卷 少年',
        '楔子',
        '第一章 出山',
        '第二卷 江湖',
        '第二章 入城',
      ]);
      expectContiguous(text, slices);
    });

    test('标题行允许行首空白（全角空格 / 制表符）', () {
      const text = '第一章 a\nx\n\u3000\u3000第二章 b\ny\n\t第三章 c\nz';
      final slices = splitTxtChapters(text);
      expect(slices.length, 3);
      expect(slices[1].title, '第二章 b');
      expectContiguous(text, slices);
    });

    test('标题行带冒号 / 空格 / 破折号', () {
      const text = '第1章：起点\nx\n第2章 — 转折\n y\n第3章  终\nz';
      final slices = splitTxtChapters(text);
      expect(slices.map((s) => s.title), ['第1章：起点', '第2章 — 转折', '第3章  终']);
    });

    test('正文里提到「第5章」不断章（行长超 40 字）', () {
      final body = '他翻开书，看到第5章写着：那一年春天，城外的桃花开得正好，'
          '风一吹就落了满地，像谁把心事抖了出来。\n';
      final text = '第一章 起\n$body';
      final slices = splitTxtChapters(text);
      expect(slices.length, 1, reason: '长句里的「第5章」不该被当成标题');
      expect(slices.single.title, '第一章 起');
    });

    test('只有标题没有正文时不产生空段', () {
      const text = '第一章\n第二章\n第三章';
      final slices = splitTxtChapters(text);
      expect(slices.length, 3);
      expectContiguous(text, slices);
    });
  });

  group('特有名与英文', () {
    test('楔子 / 番外 / 尾声 / 终章', () {
      const text = '楔子\n甲\n番外一\n乙\n尾声\n丙\n终章\n丁';
      final slices = splitTxtChapters(text);
      expect(slices.map((s) => s.title), ['楔子', '番外一', '尾声', '终章']);
      expectContiguous(text, slices);
    });

    test('Chapter N / CHAPTER 罗马数字', () {
      const text = 'Chapter 1 Start\nAAA\nChapter 2 End\nBBB\nCHAPTER XII\nCCC';
      final slices = splitTxtChapters(text);
      expect(slices.map((s) => s.title), [
        'Chapter 1 Start',
        'Chapter 2 End',
        'CHAPTER XII',
      ]);
      expectContiguous(text, slices);
      // 小写 chapter 不认（避免正文里的英文句子误判）
      expect(isChapterTitleLine('chapter 1 start'), isFalse);
    });

    test('超长行不认（> 40 字）', () {
      final long = '第1章${'很长' * 30}';
      expect(isChapterTitleLine(long), isFalse);
      expect(isChapterTitleLine('第1章 短标题'), isTrue);
    });

    test('正文句以特有名开头时不误判（「序章内容…」不是标题）', () {
      expect(isChapterTitleLine('序章内容在这里说明一下背景'), isFalse);
      expect(isChapterTitleLine('尾声之后的故事还没完'), isFalse);
      expect(isChapterTitleLine('序章'), isTrue);
      expect(isChapterTitleLine('楔子 血夜'), isTrue);
      expect(isChapterTitleLine('番外篇 小剧场'), isTrue);
    });
  });

  group('开头前言', () {
    test('前言有实质内容（> 20 字）→ 单独一章「开始」', () {
      const text = '这本书讲一个少年从山村走到江湖的故事，'
          '他没什么本事，只有一身力气和一点运气。\n'
          '第一章 出山\n正文';
      final slices = splitTxtChapters(text);
      expect(slices.first.title, '开始');
      expect(slices.first.start, 0);
      expect(slices[1].title, '第一章 出山');
      expectContiguous(text, slices);
    });

    test('前言只有书名行 / 空行 → 并进第一章，不从 0 之后开始', () {
      const text = '[某某小说网] 书名.txt\n\n\n\n第一章 出山\n正文';
      final slices = splitTxtChapters(text);
      expect(slices.length, 1);
      expect(slices.single.start, 0);
      expect(slices.single.title, '第一章 出山');
      expectContiguous(text, slices);
    });

    test('开头全是空行也不产生空段', () {
      const text = '\n\n\n\n第一章 a\nx';
      final slices = splitTxtChapters(text);
      expect(slices.length, 1);
      expectContiguous(text, slices);
    });
  });

  group('无标题长文', () {
    test('按固定长度分块，标题「第 N 节」，且连续', () {
      final text = List.generate(500, (i) => '这是第$i句测试正文，长度足够用来切块。').join();
      final slices = splitTxtChapters(text, chunkSize: 300);
      expect(slices.length, greaterThan(3));
      expect(slices.first.title, '第 1 节');
      expect(slices[1].title, '第 2 节');
      expectContiguous(text, slices);
      for (final s in slices) {
        // 允许在句末附近前后浮动，但不能超过 target + 200
        expect(s.length, lessThanOrEqualTo(300 + 200));
      }
    });

    test('切点尽量落在句号 / 换行后', () {
      final text = '${'一' * 99}。${'二' * 200}';
      final slices = splitTxtChapters(text, chunkSize: 100);
      // 第 100 个字符正好是句号之后 → 应切在 100
      expect(slices.first.end, 100);
      expect(text.substring(0, 100).endsWith('。'), isTrue);
    });

    test('无标点的超长串也能切（不许死循环 / 空段）', () {
      final text = '字' * 1000;
      final slices = splitTxtChapters(text, chunkSize: 300);
      expect(slices.length, 4); // 300 * 3 + 100
      expectContiguous(text, slices);
    });

    test('chunkSize 非法（0 / 负）回落到默认值', () {
      final text = '字' * 100;
      final slices = splitTxtChapters(text, chunkSize: 0);
      expect(slices.length, 1);
      expectContiguous(text, slices);
    });
  });

  group('边界情况', () {
    test('空文本 → 空列表', () {
      expect(splitTxtChapters(''), isEmpty);
    });

    test('纯空白 → 单段（不崩）', () {
      const text = '\n\n\n';
      final slices = splitTxtChapters(text);
      expect(slices.length, 1);
      expectContiguous(text, slices);
    });

    test('CRLF 文件：偏移仍对得上原文', () {
      const text = '第一章 a\r\n甲\r\n第二章 b\r\n乙\r\n';
      final slices = splitTxtChapters(text);
      expect(slices.length, 2);
      expectContiguous(text, slices);
      expect(slices[0].title, '第一章 a');
      expect(text.substring(slices[1].start, slices[1].end), '第二章 b\r\n乙\r\n');
    });

    test('连续空行夹在章之间', () {
      const text = '第一章 a\n正文\n\n\n\n第二章 b\n正文\n\n\n';
      final slices = splitTxtChapters(text);
      expect(slices.length, 2);
      expectContiguous(text, slices);
      expect(slices[0].end - slices[0].start, greaterThan('第一章 a\n正文'.length));
    });

    test('1 万字、200 章：连续性与章节数都对', () {
      final buf = StringBuffer();
      for (var i = 1; i <= 200; i++) {
        buf.write('第$i章 标题$i\n');
        buf.write('${'正文正文正文正文正文正文正文正文正文正文' * 2}。\n');
      }
      final text = buf.toString();
      expect(text.length, greaterThan(9000));
      final slices = splitTxtChapters(text);
      expect(slices.length, 200);
      expect(slices.last.title, '第200章 标题200');
      expectContiguous(text, slices);
    });

    test('章数超上限时合并相邻章，而不是丢尾部', () {
      final buf = StringBuffer();
      for (var i = 1; i <= 100; i++) {
        buf.write('第$i章 标题\n正文。\n');
      }
      final text = buf.toString();
      final slices = splitTxtChapters(text, maxChapters: 30);
      expect(slices.length, lessThanOrEqualTo(30));
      expect(slices.first.title, '第1章 标题');
      expectContiguous(text, slices);
      // 合并后最后一段仍然覆盖到文末 → 内容没有丢
      expect(slices.last.end, text.length);
    });

    test('代理对不被劈开（emoji 落在切点附近）', () {
      // 300 个 'a' 后跟 emoji，再跟正文；切点 300 正好落在 emoji 的高位之前
      final text = '${'a' * 299}😀${'b' * 400}';
      final slices = splitTxtChapters(text, chunkSize: 300);
      for (final s in slices) {
        // 每个切点都不能停在代理对中间
        if (s.end < text.length) {
          final before = text.codeUnitAt(s.end - 1);
          final after = text.codeUnitAt(s.end);
          final splitPair = before >= 0xD800 &&
              before <= 0xDBFF &&
              after >= 0xDC00 &&
              after <= 0xDFFF;
          expect(splitPair, isFalse, reason: '切点 ${s.end} 劈开了代理对');
        }
      }
      expectContiguous(text, slices);
    });
  });
}
