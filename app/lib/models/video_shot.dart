/// B 站「视频进度预览图（雪碧图）」模型。
///
/// 数据源：`GET /x/player/videoshot?bvid=<bvid>&index=<分P序号，1-based>`
/// （**免 WBI 签名、免登录态**，2026-09 实测）。`data` 形如：
/// ```json
/// {"pvdata":"//i0.hdslb.com/bfs/videoshot/137649199.bin",
///  "img_x_len":10, "img_y_len":10,      // 每张雪碧图的网格（列 × 行）
///  "img_x_size":160, "img_y_size":90,   // 单格尺寸（像素）
///  "image":["//i0.hdslb.com/bfs/videoshot/137649199.jpg"],
///  "index":[0,0,5,11,...,211]}          // 第 i 张缩略图对应的【秒】
/// ```
///
/// 取图算法（[cellForShot]）：缩略图 i → 第 `i / (xLen*yLen)` 张雪碧图，
/// 该图内 `row = (i % perSprite) / xLen`、`col = (i % perSprite) % xLen`。
///
/// ⚠️ `index` 长度就是缩略图总张数，**必须与雪碧图网格逐格对齐**：
/// 解析时只能「就地修正」（越界值钳到前一项），绝不能丢弃元素，否则
/// 序号 → 格坐标的映射整体错位。
library;

import 'package:flutter/foundation.dart';

/// B 站「视频进度预览图（雪碧图）」信息。
@immutable
class VideoShotInfo {
  /// 雪碧图 URL（已补全 `https:`），长视频可能多张。
  final List<String> spriteUrls;

  /// 每张雪碧图的网格（列数 / 行数）。
  final int xLen;
  final int yLen;

  /// 单格尺寸（像素）。
  final int xSize;
  final int ySize;

  /// 第 i 张缩略图对应的秒数（**单调不减**；前两项实测可能都是 0）。
  final List<int> indexSeconds;

  const VideoShotInfo({
    required this.spriteUrls,
    required this.xLen,
    required this.yLen,
    required this.xSize,
    required this.ySize,
    required this.indexSeconds,
  });

  /// 每张雪碧图能装多少格缩略图。
  int get perSprite => xLen * yLen;

  /// 总缩略图张数。
  int get shotCount => indexSeconds.length;

  /// 时间（秒）→ 缩略图序号。
  ///
  /// **纯计算**（不碰网络/状态，便于单测）：在 [indexSeconds] 上二分
  /// （`lower_bound`），命中或取最近的候选；`lower_bound` 结果与其前一项
  /// 等距时取**较小**序号 —— 保证结果确定、且随时间为单调不减（向右拖动
  /// 帧序号不会倒退）。前两项都是 0 时：0 秒走「≤ 首项」分支 → 序号 0。
  ///
  /// - 数组为空 → -1（调用方据此降级）
  /// - 时间 < 首项 → 0；时间 > 末项 → 末项序号（钳到端点）
  int shotIndexForSeconds(int seconds) {
    final n = indexSeconds.length;
    if (n == 0) return -1;
    if (seconds <= indexSeconds.first) return 0;
    if (seconds >= indexSeconds.last) return n - 1;

    // lower_bound：找第一个 indexSeconds[i] >= seconds 的下标
    var lo = 0;
    var hi = n - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (indexSeconds[mid] < seconds) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // lo 命中或其后一项；比一比 lo 与前一项谁更近
    final hiIdx = lo;
    final loIdx = lo - 1;
    final dHi = (indexSeconds[hiIdx] - seconds).abs();
    final dLo = (seconds - indexSeconds[loIdx]).abs();
    return dLo <= dHi ? loIdx : hiIdx;
  }

  /// 缩略图序号 → 该格在雪碧图中的裁剪矩形 + 属于哪张雪碧图。
  ///
  /// **纯计算**：`spriteIndex` 已钳到实际雪碧图张数内（防接口元信息与
  /// 图片张数不一致时越界）；序号越界 / 元信息不可用 → 返回零尺寸矩形
  /// （调用方按「无预览」降级，不会崩）。
  ({int spriteIndex, int left, int top, int width, int height}) cellForShot(
    int shotIndex,
  ) {
    const empty = (spriteIndex: 0, left: 0, top: 0, width: 0, height: 0);
    if (shotIndex < 0 || shotIndex >= shotCount) return empty;
    if (perSprite <= 0 || xSize <= 0 || ySize <= 0) return empty;
    if (spriteUrls.isEmpty) return empty;

    final rawSprite = shotIndex ~/ perSprite;
    // 元信息与图片张数不一致时钳到末张（宁可给错帧，也不越界崩）
    final spriteIndex = rawSprite < spriteUrls.length
        ? rawSprite
        : spriteUrls.length - 1;
    final within = shotIndex % perSprite;
    final row = within ~/ xLen;
    final col = within % xLen;
    return (
      spriteIndex: spriteIndex,
      left: col * xSize,
      top: row * ySize,
      width: xSize,
      height: ySize,
    );
  }

  /// 宽松解析（字段缺失/类型不对时给安全默认，绝不抛错）。
  ///
  /// 既能吃 `data` 内层对象（[BiliApi.fetchVideoShot] 的用法），也能吃
  /// 整个 `{code,data}` 信封（容错）。
  factory VideoShotInfo.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    final src = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : json;

    final urls = <String>[];
    final rawImages = src['image'];
    if (rawImages is List) {
      for (final e in rawImages) {
        final u = _normalizeUrl(e);
        if (u.isNotEmpty) urls.add(u);
      }
    }

    final seconds = <int>[];
    final rawIndex = src['index'];
    if (rawIndex is List) {
      for (final e in rawIndex) {
        final s = e is num ? e.toInt() : int.tryParse('$e');
        final prev = seconds.isEmpty ? 0 : seconds.last;
        if (s == null || s < 0) {
          // 保留位置（对齐雪碧图网格）→ 用前一项顶替，而不是丢弃
          seconds.add(prev);
        } else {
          // 二分前提是单调不减；实测个别视频有回跳，就地钳平
          seconds.add(s < prev ? prev : s);
        }
      }
    }

    return VideoShotInfo(
      spriteUrls: urls,
      xLen: _positiveInt(src['img_x_len'], 10),
      yLen: _positiveInt(src['img_y_len'], 10),
      xSize: _positiveInt(src['img_x_size'], 160),
      ySize: _positiveInt(src['img_y_size'], 90),
      indexSeconds: seconds,
    );
  }

  /// 只保留 > 0 的整数；缺省/非法/非正 → [fallback]。
  static int _positiveInt(dynamic raw, int fallback) {
    final v = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (v == null || v <= 0) return fallback;
    return v;
  }

  /// B 站返回的是协议相对 URL（`//i0.hdslb.com/...`），补 `https:` 才能请求。
  static String _normalizeUrl(dynamic raw) {
    if (raw is! String) return '';
    final s = raw.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('//')) return 'https:$s';
    return s;
  }
}
