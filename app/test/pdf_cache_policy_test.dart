// PDF 渲染缓存淘汰策略单测（F1，v2.74.0）。
//
// 策略是纯函数（不碰文件系统），所以这里只需要造「文件清单」数组：
// 上限（300MB / 每本 500 页）、按最旧清理、当前页不许被删、结果稳定。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/pdf_cache_policy.dart';

PdfCacheFile f(
  String path, {
  String book = 'b1',
  int bytes = 1000,
  int mtime = 1,
}) =>
    PdfCacheFile(path: path, bookKey: book, bytes: bytes, modifiedMs: mtime);

void main() {
  test('空清单 → 什么都不删', () {
    expect(planPdfCacheEviction(const []), isEmpty);
  });

  test('单本超过页数上限：新的留下，旧的删（结果与顺序无关）', () {
    final files = [
      for (var i = 0; i < 5; i++) f('p$i', mtime: i),
    ];
    final doomed = planPdfCacheEviction(
      // 故意打乱输入顺序：策略必须自己按 mtime 排序
      files.reversed.toList(),
      maxPagesPerBook: 2,
      maxBytes: 1 << 30,
    );
    expect(doomed, unorderedEquals(['p0', 'p1', 'p2']));
  });

  test('多本书各算各的页数上限', () {
    final files = [
      f('a0', book: 'a', mtime: 1),
      f('a1', book: 'a', mtime: 2),
      f('b0', book: 'b', mtime: 3),
      f('b1', book: 'b', mtime: 4),
    ];
    final doomed = planPdfCacheEviction(
      files,
      maxPagesPerBook: 1,
      maxBytes: 1 << 30,
    );
    expect(doomed, unorderedEquals(['a0', 'b0']));
  });

  test('总量超限：从最旧的开始删，删到不超为止', () {
    final files = [
      f('old', bytes: 100, mtime: 1),
      f('mid', bytes: 100, mtime: 2),
      f('new', bytes: 100, mtime: 3),
    ];
    // 限 250：删最旧的 100 → 剩 200，够了
    expect(planPdfCacheEviction(files, maxBytes: 250),
        unorderedEquals(['old']));
    // 限 150：要删两个
    expect(planPdfCacheEviction(files, maxBytes: 150),
        unorderedEquals(['old', 'mid']));
    // 限 300（正好等于总量）：一个都不删
    expect(planPdfCacheEviction(files, maxBytes: 300), isEmpty);
  });

  test('keepPath（当前正在看的那一页）永不被删，哪怕它最旧、哪怕仍然超限', () {
    final files = [
      f('oldest-but-open', bytes: 100, mtime: 1),
      f('b', bytes: 100, mtime: 2),
      f('c', bytes: 100, mtime: 3),
    ];
    final doomed = planPdfCacheEviction(
      files,
      maxBytes: 50,
      keepPath: 'oldest-but-open',
    );
    expect(doomed, isNot(contains('oldest-but-open')));
    expect(doomed, containsAll(<String>['b', 'c']));
  });

  test('同一 mtime 时按路径定序：结果可复现（两次调用一致）', () {
    final files = [
      f('b', mtime: 7),
      f('a', mtime: 7),
      f('c', mtime: 7),
    ];
    final first = planPdfCacheEviction(
      files,
      maxPagesPerBook: 1,
      maxBytes: 1 << 30,
    );
    final second = planPdfCacheEviction(
      files.reversed.toList(),
      maxPagesPerBook: 1,
      maxBytes: 1 << 30,
    );
    expect(first, second);
    expect(first, unorderedEquals(['b', 'c']));
  });

  test('负数字节按 0 记（清单坏了也不至于算出诡异的量）', () {
    final files = [
      f('bad', bytes: -5, mtime: 1),
      f('ok', bytes: 100, mtime: 2),
    ];
    expect(planPdfCacheEviction(files, maxBytes: 100), isEmpty);
  });

  test('默认上限：300MB / 每本 500 页', () {
    expect(kPdfCacheMaxBytes, 300 * 1024 * 1024);
    expect(kPdfCacheMaxPagesPerBook, 500);
    // 501 个文件 + 默认参数 → 只删最旧的 1 个
    final files = [for (var i = 0; i < 501; i++) f('p$i', mtime: i)];
    final doomed = planPdfCacheEviction(files);
    expect(doomed, ['p0']);
  });
}
