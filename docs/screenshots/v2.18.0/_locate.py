"""从截图里定位控件（tester 一次性工具）。

用途：模拟器上 Flutter 不暴露 accessibility 语义树（uiautomator 拿不到
text/bounds），而 `input tap` 又必须给物理像素坐标。所以用像素特征反查：

- fields <png>          找「实心冷灰输入框」（kPaperCool #E9E9E5 通栏）的 y 区间
- rows   <png>          找「描边按钮/块」的上下边线 y（1px 描边通栏）
- probes <png> <x> <y>  打印某点颜色 + 该点在 900x2000 / 450x1000 视图下的坐标
"""
import sys
from PIL import Image

BG = (250, 250, 247)      # kPaper
COOL = (233, 233, 229)    # kPaperCool
STRONG = (201, 201, 193)  # kRuleStrong


def near(c, t, tol=8):
    return all(abs(c[i] - t[i]) <= tol for i in range(3))


def row_kind(px, y, w, x0=60, x1=1010):
    cool = strong = 0
    n = 0
    for x in range(x0, x1, 4):
        c = px[x, y]
        n += 1
        if near(c, COOL):
            cool += 1
        if near(c, STRONG):
            strong += 1
    return cool / n, strong / n, n


def runs(flags):
    out = []
    start = None
    for i, f in enumerate(flags):
        if f and start is None:
            start = i
        elif not f and start is not None:
            out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(flags) - 1))
    return out


def main():
    cmd = sys.argv[1]
    im = Image.open(sys.argv[2]).convert('RGB')
    px = im.load()
    w, h = im.size
    if cmd == 'fields':
        flags = []
        for y in range(h):
            cool, strong, _ = row_kind(px, y, w)
            flags.append(cool > 0.9)
        print(f'image {w}x{h}; 视图换算: 900x2000 -> x{1080/900:.3f}  | 450x1000 -> x{1080/450:.3f}')
        for a, b in runs(flags):
            if b - a >= 8:
                print(f'  冷灰实心块 y={a}..{b} (h={b-a+1}) 中心 y={(a+b)//2}')
    elif cmd == 'rows':
        flags = []
        for y in range(h):
            _, strong, _ = row_kind(px, y, w)
            flags.append(strong > 0.7)
        print(f'image {w}x{h}')
        for a, b in runs(flags):
            print(f'  通栏描边线 y={a}..{b}')
    elif cmd == 'probes':
        x, y = int(sys.argv[3]), int(sys.argv[4])
        print(px[x, y], f'orig=({x},{y}) 900x2000视图=({x/1.2:.0f},{y/1.2:.0f}) 450x1000视图=({x/2.4:.0f},{y/2.4:.0f})')


main()
