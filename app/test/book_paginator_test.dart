// 正文分页纯函数测试（v2.72.0）。
//
// 分页算法是左右翻页模式的地基：切少了页尾溢出、切多了满屏空白页、算不准
// 就是死循环。这里用测试字体（等宽，每字符宽 = fontSize）把宽高固定住，
// 逐条验边界：正常段落、超长无换行、空正文、高度不足一行、段落换行不被
// 切到页首、以及最关键的「单调、不重叠、覆盖全文」。
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_paginator.dart';

/// 行高 24（16 × 1.5），可用宽 400 → 测试字体每行 25 字，可用高 240 → 10 行。
const TextStyle _style = TextStyle(fontSize: 16, height: 1.5);
const double _width = 400;
const double _height = 240;

/// 与分页器同口径地量一段文本的高度（用来反证「每页真的放得下」）。
double _measuredHeight(String text) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: _style),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: _width);
  final height = painter.height;
  painter.dispose();
  return height;
}

/// 每页渲染出来的文本。
List<String> _renderAll(String text, List<int> starts) => [
      for (var i = 0; i < starts.length; i++) pageText(text, starts, i),
    ];

void main() {
  // TextPainter 需要字体管理器就绪（测试环境用的是等宽测试字体）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paginateText 边界', () {
    test('空正文 → 一页 [0]（不崩、不返回空列表）', () {
      expect(
        paginateText('', style: _style, width: _width, height: _height),
        <int>[0],
      );
    });

    test('宽 / 高为 0 或无穷 → 整章一页（兜底，不死循环）', () {
      const text = '一二三四五六七八九十';
      expect(
        paginateText(text, style: _style, width: _width, height: 0),
        <int>[0],
      );
      expect(
        paginateText(text, style: _style, width: 0, height: _height),
        <int>[0],
      );
      expect(
        paginateText(text, style: _style, width: _width, height: -20),
        <int>[0],
      );
      expect(
        paginateText(
          text,
          style: _style,
          width: double.infinity,
          height: _height,
        ),
        <int>[0],
      );
      expect(
        paginateText(text, style: _style, width: _width, height: double.nan),
        <int>[0],
      );
    });

    test('高度不足一行 → 整章一页（不是一字一页）', () {
      final text = '字' * 60;
      final pages = paginateText(
        text,
        style: _style,
        width: _width,
        height: 10, // 行高 24，10px 连一行都放不下
      );
      expect(pages, <int>[0]);
      expect(pageEnd(text, pages, 0), text.length);
    });
  });

  group('paginateText 正常分页', () {
    test('段落正文：每页放得下、起点递增、末页覆盖到结尾', () {
      final text = List.generate(40, (i) => '第 $i 段：${'字' * 30}').join('\n');
      final pages = paginateText(
        text,
        style: _style,
        width: _width,
        height: _height,
      );

      expect(pages.length, greaterThan(1));
      expect(pages.first, 0);
      for (var i = 0; i < pages.length; i++) {
        final rendered = pageText(text, pages, i);
        expect(rendered, isNotEmpty, reason: '第 $i 页不该是空白页');
        expect(
          _measuredHeight(rendered),
          lessThanOrEqualTo(_height + 0.01),
          reason: '第 $i 页超出了可用高度',
        );
        if (i + 1 < pages.length) {
          expect(pages[i + 1], greaterThan(pages[i]), reason: '页起点必须递增');
        }
      }
      expect(pageEnd(text, pages, pages.length - 1), text.length);
    });

    test('超长无换行文本：硬切，拼回来还是全文', () {
      final text = '字' * 5000;
      final pages = paginateText(
        text,
        style: _style,
        width: _width,
        height: _height,
      );

      expect(pages.length, greaterThan(1));
      // 没有换行字符，所以 pageText 的裁剪不会丢字符 → 拼起来必须逐字节等于原文
      expect(_renderAll(text, pages).join(), text);
    });

    test('段落换行不会被切在页首（页首没有空行 / 空页）', () {
      final text = List.generate(60, (i) => '段落$i${'。' * 40}').join('\n');
      final pages = paginateText(
        text,
        style: _style,
        width: _width,
        height: _height,
      );

      for (var i = 0; i < pages.length; i++) {
        expect(pageText(text, pages, i).startsWith('\n'), isFalse);
        expect(text[pages[i]], isNot('\n'), reason: '第 $i 页起点正好落在换行上');
      }
    });

    test('区间覆盖全文：每页紧接上一页，不重不漏', () {
      final text = List.generate(30, (i) => '第 $i 行${'字' * 20}').join('\n');
      final pages = paginateText(
        text,
        style: _style,
        width: _width,
        height: _height,
      );

      expect(pageStart(pages, 0), 0);
      for (var i = 0; i + 1 < pages.length; i++) {
        expect(pageEnd(text, pages, i), pages[i + 1]);
      }
      expect(pageEnd(text, pages, pages.length - 1), text.length);
    });
  });

  group('pageText / pageStart / pageEnd', () {
    test('页首页尾的换行在渲染文本里被去掉，但区间不变', () {
      const text = '\n\n第一章\n正文内容\n\n';
      const starts = <int>[0];
      expect(pageText(text, starts, 0), '第一章\n正文内容');
      expect(pageStart(starts, 0), 0);
      expect(pageEnd(text, starts, 0), text.length);
    });

    test('越界下标夹取，不抛异常', () {
      const text = 'abcdef';
      const starts = <int>[0, 3];
      expect(pageStart(starts, -5), 0);
      expect(pageStart(starts, 99), 3);
      expect(pageEnd(text, starts, 99), text.length);
      expect(pageText(text, starts, 99), 'def');
    });
  });
}
