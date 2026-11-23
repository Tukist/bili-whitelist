/// PDF 渲染缓存的淘汰**策略**（纯函数，v2.74.0）。
///
/// ## 为什么策略在 Dart 而不在 Kotlin
/// 「超出上限删哪些」是唯一值得单测的部分：它决定用户翻过的页会不会莫名其妙
/// 变成黑屏（删了正在看的页），也决定缓存会不会无限长。Kotlin 侧只提供
/// `cacheFiles` / `deleteCacheFiles` 两个原语（列清单、按下发的路径删），
/// 策略放在这里就能用 `flutter test` 覆盖边界，不必连模拟器。
///
/// ## 上限
/// - 全书缓存总量 **300MB**：一张 1080 宽的漫画页 PNG 约 300KB~1MB，300MB 够
///   存 300~900 页，足够连续读几本，又不会把手机塞满；
/// - 单本 **500 页**：一页一个文件，目录里太多文件会让原生侧的目录遍历变慢
///   （每次 `cacheFiles` 都要 list），500 页之后回到老页会重新渲染，代价只有
///   一次几百毫秒。
///
/// 两个上限都按「**最久没被渲染过的先删**」（文件 mtime 近似「最近一次被需要」），
/// 因为渲染结果命中缓存时不会刷新 mtime —— 也就是「最久没读过的那一批」。
///
/// ## 为什么要 `keepPath`
/// 调用方是「渲染完这一页之后顺手清一遍」。如果淘汰恰好选中了刚渲染出来的
/// 这一页（磁盘满 + 单本超页数时完全可能），用户会看到「刚打开就黑屏」。
/// 所以策略允许调用方把当前页钉住。
library;

/// 缓存目录里的一项（来自原生 `cacheFiles`）。
class PdfCacheFile {
  /// 绝对路径。
  final String path;

  /// 所属书 id（缓存子目录名）。
  final String bookKey;

  final int bytes;

  /// 文件最后修改时间（epoch 毫秒）。
  final int modifiedMs;

  const PdfCacheFile({
    required this.path,
    required this.bookKey,
    required this.bytes,
    required this.modifiedMs,
  });

  @override
  String toString() => 'PdfCacheFile($path, $bytes B, $modifiedMs)';
}

/// 全书缓存总量上限（300MB）。
const int kPdfCacheMaxBytes = 300 * 1024 * 1024;

/// 单本缓存页数上限（500 页）。
const int kPdfCacheMaxPagesPerBook = 500;

/// 算出应该删掉哪些缓存文件（**纯函数**，不碰文件系统）。
///
/// 规则（顺序固定，先单本再总量）：
/// 1. 按 [PdfCacheFile.bookKey] 分组，每组保留最新的 [maxPagesPerBook] 个文件，
///    其余删；
/// 2. 剩下的总计仍超过 [maxBytes] 时，从最旧的开始删，直到不超；
/// 3. [keepPath] 永不出现在结果里（哪怕它超限、哪怕它是最旧的）。
///
/// 返回值是**路径列表**，调用方原样交给原生 `deleteCacheFiles`。
/// 同一个路径不会重复出现。
List<String> planPdfCacheEviction(
  List<PdfCacheFile> files, {
  int maxBytes = kPdfCacheMaxBytes,
  int maxPagesPerBook = kPdfCacheMaxPagesPerBook,
  String? keepPath,
}) {
  if (files.isEmpty) return const [];

  final byBook = <String, List<PdfCacheFile>>{};
  for (final f in files) {
    byBook.putIfAbsent(f.bookKey, () => <PdfCacheFile>[]).add(f);
  }

  final doomed = <String>{};
  // ---- 1. 单本超页数：新的留下，旧的删 ----
  if (maxPagesPerBook > 0) {
    for (final group in byBook.values) {
      if (group.length <= maxPagesPerBook) continue;
      // 新的在前（mtime 相同则按路径定序，保证结果稳定 / 可测）
      group.sort((a, b) {
        final byTime = b.modifiedMs.compareTo(a.modifiedMs);
        return byTime != 0 ? byTime : a.path.compareTo(b.path);
      });
      for (var i = maxPagesPerBook; i < group.length; i++) {
        doomed.add(group[i].path);
      }
    }
  }

  // ---- 2. 总量超限：最旧的先删 ----
  if (maxBytes > 0) {
    final alive = <PdfCacheFile>[
      for (final f in files)
        if (!doomed.contains(f.path)) f,
    ]..sort((a, b) {
        final byTime = a.modifiedMs.compareTo(b.modifiedMs);
        return byTime != 0 ? byTime : a.path.compareTo(b.path);
      });
    var total = alive.fold<int>(0, (sum, f) => sum + (f.bytes < 0 ? 0 : f.bytes));
    for (final f in alive) {
      if (total <= maxBytes) break;
      if (f.path == keepPath) continue;
      doomed.add(f.path);
      total -= f.bytes < 0 ? 0 : f.bytes;
    }
  }

  final keep = keepPath;
  return [
    for (final p in doomed)
      if (p != keep) p,
  ];
}
