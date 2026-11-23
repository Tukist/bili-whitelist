#!/usr/bin/env python3
"""生成 GBK 解码码表 -> app/lib/utils/gbk_table.dart

为什么用生成而不是手写 / 引依赖：GBK 是 126 × 191 的二维表（约 2.4 万个码位），
手写不可能；Dart 侧没有内置 GBK 解码器，而为了读一本本地 TXT 去引一个纯 Dart
的 charset 包（含码表 + 一堆我们永远不用的编码）不值得。码表是**一次性**产物，
生成一次就固定在仓库里，运行时零依赖、零 IO。

索引公式（与 Dart 侧 text_decoding.dart 完全一致）：
    index = (lead - 0x81) * 191 + (trail - 0x40)
lead 取 0x81..0xFE（126 个），trail 取 0x40..0xFE（191 个）→ 24066 项。
其中 trail == 0x7F 的位置在 GBK 里不存在，解不出来，一律用 U+FFFD 占位；
其它未映射组合（留空给扩展区的洞）同样占位。

用法：
    python tools/gen_gbk_table.py            # 写 lib/utils/gbk_table.dart
    python tools/gen_gbk_table.py --check    # 只校验现有文件是否最新（CI 用）
"""

from __future__ import annotations

import argparse
import pathlib
import sys

LEAD_MIN, LEAD_MAX = 0x81, 0xFE
TRAIL_MIN, TRAIL_MAX = 0x40, 0xFE
TRAIL_COUNT = TRAIL_MAX - TRAIL_MIN + 1  # 191
REPLACEMENT = "\ufffd"

OUT_NAME = "gbk_table.dart"


def build_table() -> list[str]:
    """按 (lead, trail) 顺序生成码表；解不出来的位置放 U+FFFD。"""
    table: list[str] = []
    for lead in range(LEAD_MIN, LEAD_MAX + 1):
        for trail in range(TRAIL_MIN, TRAIL_MAX + 1):
            if trail == 0x7F:
                table.append(REPLACEMENT)
                continue
            try:
                ch = bytes([lead, trail]).decode("gbk")
            except UnicodeDecodeError:
                table.append(REPLACEMENT)
                continue
            # GBK 全部落在 BMP（非 BMP 是 GB18030 的四字节区），正常长度恒为 1。
            # 真出现别的长度就按未映射处理，宁可显示替换字符也不要把索引搞错位。
            table.append(ch if len(ch) == 1 else REPLACEMENT)
    return table


def dart_escape(ch: str) -> str:
    """转义成 Dart 单引号字符串里安全的一段。

    只转义会破坏字面量的字符：引号、反斜杠、`$`（Dart 的插值符）、控制字符、
    行分隔符（U+2028/U+2029，某些工具链会把它们当成换行的近似物）。
    其它一律原样输出 —— 中文留在源码里，人要 review 时至少能看懂一部分。
    """
    code = ord(ch)
    if ch == "'":
        return "\\'"
    if ch == "\\":
        return "\\\\"
    if ch == "$":
        return "\\$"
    if code < 0x20 or code == 0x7F or code in (0x2028, 0x2029):
        return "\\u%04X" % code
    return ch


def render(table: list[str]) -> str:
    body = "".join(dart_escape(ch) for ch in table)
    header = f'''// 由 tools/gen_gbk_table.py 生成，勿手改。
//
// GBK 双字节 → UTF-16 码元的查表常量，索引 = (lead - 0x81) * 191 + (trail - 0x40)。
// lead 0x81..0xFE（126 个）、trail 0x40..0xFE（191 个），共 {len(table)} 项。
// 未映射 / 非法组合（含 GBK 里根本不存在的 trail 0x7F）一律是 U+FFFD 占位，
// 解码侧遇到它就把该位置记成「替换字符」，用来判断「这份文件是不是压根不是 GBK」。
//
// 为什么内联成字符串常量而不是 assets 文件：Dart 的 const 字符串在编译期就固化进
// snapshot，运行时没有一次 IO / 一次 base64 解码；2.4 万字符的 const 对编译时间与
// 包体的影响都可以忽略（UTF-8 约 {len(body.encode("utf-8"))} 字节）。
//
// 重新生成：python tools/gen_gbk_table.py
library;

/// GBK 码表（索引见文件头）。
const String kGbkTable = \'{body}\';

/// 码表长度（= 126 * 191）。解码时用它做边界检查。
const int kGbkTableLength = {len(table)};
'''
    return header


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比对，不写文件")
    args = ap.parse_args()

    app_dir = pathlib.Path(__file__).resolve().parent.parent
    target = app_dir / "lib" / "utils" / OUT_NAME

    content = render(build_table())

    if args.check:
        if not target.exists():
            print(f"缺少 {target}", file=sys.stderr)
            return 1
        if target.read_text(encoding="utf-8") != content:
            print(f"{target} 与生成器不一致，请重新生成", file=sys.stderr)
            return 1
        print("gbk_table.dart 是最新的")
        return 0

    target.write_text(content, encoding="utf-8", newline="\n")
    print(f"已写入 {target}（{len(content)} 字符）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
