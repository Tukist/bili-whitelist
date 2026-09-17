#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 xlsx 解析器的测试夹具（v2.34.0）。

用法（在 app/ 目录下）：

    python tools/make_xlsx_fixture.py

输出：test/fixtures/schedule_sample.xlsx（**全合成数据，不是用户真实表格**）

为什么要专门生成一个夹具、而不是拿用户那张真实表来测：
用户那张 `超级代办 大三上.xlsx` 是他的私人日程，**绝不能提交进公开仓库**。
这里用 openpyxl 造一张结构类似（表头 + 文本 + 纯色底 + 只有底色没文本的格子 +
空列头 + 一张 WPS 保留表）但内容完全是编的表，既能覆盖真实文件的关键形态，
又不带任何隐私。**格子文本一律用与用户无关的通用词**（写代码 / 交作业 / 背单词…），
连"看起来像他日程"的字符串都不要出现。

夹具结构（断言见 test/xlsx_reader_test.dart）：

    Sheet1「课程表」
        A1 星期日        B1 星期一9.14     C1 (空，但**有黄底**)
        A2 写代码(黄)    B2 交作业         C2 (无文本，**红底**)
        A3 背单词(灰)    B3 (空)           C3 看书
        A4 (空)          B4 3 (数字)       C4 跑步(绿)
    Sheet2「第二张表」      B1 第二张的内容
    Sheet3「WpsReserved_CellImgList」  ← WPS 保留表，导入时应当被过滤掉

其它形态（共享字符串富文本 / inlineStr / 公式结果 / 缺 r 属性 / 命名空间前缀 /
截断 XML / 缺 entry）用 Dart 侧手工构造的 zip 覆盖，不落盘成文件
（test/xlsx_reader_test.dart 里的 _buildXlsx），因为那些是"故意畸形"的输入，
做成文件反而不好维护。
"""
import os

from openpyxl import Workbook
from openpyxl.styles import PatternFill

# 与 App 色板前 5 色逐字一致（lib/models/schedule.dart 的 kScheduleColors）
YELLOW = 'FFFFFF00'
GRAY = 'FFBFBFBF'
GREEN = 'FF92D050'
RED = 'FFFF0000'


def fill(rgb):
    return PatternFill(start_color=rgb, end_color=rgb, fill_type='solid')


def main():
    wb = Workbook()

    # ---------- Sheet1：主表 ----------
    ws = wb.active
    ws.title = '课程表'
    ws['A1'] = '星期日'
    ws['B1'] = '星期一9.14'
    ws['C1'].fill = fill(YELLOW)          # 空列头（只有底色）→ 应兜底成「第3列」

    ws['A2'] = '写代码'
    ws['A2'].fill = fill(YELLOW)
    ws['B2'] = '交作业'
    ws['C2'].fill = fill(RED)             # 只有底色没文本的格子 → 保留

    ws['A3'] = '背单词'
    ws['A3'].fill = fill(GRAY)
    ws['C3'] = '看书'

    ws['B4'] = 3                          # 数字 → 文本 '3'（不带小数尾巴）
    ws['C4'] = '跑步'
    ws['C4'].fill = fill(GREEN)

    # ---------- Sheet2：第二张表（测「多表选一张」）----------
    ws2 = wb.create_sheet('第二张表')
    ws2['B1'] = '第二张的内容'

    # ---------- Sheet3：WPS 保留表（测过滤）----------
    ws3 = wb.create_sheet('WpsReserved_CellImgList')
    ws3['A1'] = 'wps 内部用'

    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                           'test', 'fixtures')
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, 'schedule_sample.xlsx')
    wb.save(out)
    print('written:', out)


if __name__ == '__main__':
    main()
