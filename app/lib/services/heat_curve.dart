/// 播放页「热度高潮线」：按弹幕密度算时间轴上的热度曲线（v2.61.0+）。
///
/// ## 为什么自己算（探针结论，2026-11-06）
/// - B 站官方的「高能进度条」（PBP）在社区文档里有一个接口
///   `https://api.bilibili.com/pbp/data?cid=<cid>`（文档：
///   bilibili-API-collect `docs/video/pbp.md`，返回 `step_sec` + `events.default`
///   顶点数组）。**实测该路径已 404**（匿名带完整浏览器头 + Referer，
///   `api.bilibili.com/pbp/data`、`bvc.bilivideo.com/pbp/data`、
///   `pbp.bilivideo.com/pbp/data` 三种写法都没有可用响应），文档仓库也已归档。
/// - `x/player/videoshot` 的 `pvdata` 是 **bin 格式的雪碧图截取时间表**
///   （实测 104 字节 = 52 个 uint16，与同响应的 `index[]` 逐项一致），
///   **不是**热度数据 —— 雪碧图只用来做拖动预览，别混用。
/// - 所以这里用**本 App 自己已经拉的弹幕**（`x/v1/dm/list.so`，见
///   `BiliApi.fetchDanmaku`）算密度。这与 B 站「高能进度条 = 单位时间弹幕量
///   的变化趋势」的定义是同源的，只是采样自己定。
///
/// ## 算法（纯函数，无 Flutter 依赖，可单测）
/// 1. 按 [kHeatBucketSec] 秒分桶计数（超长视频桶数超过 [kHeatMaxBuckets]
///    时自动放宽桶宽，保证内存与绘制开销恒定）；
/// 2. 半径 [kHeatSmoothRadius] 的滑动平均平滑（边缘按实际窗口数取均值，
///    不把边界拉向 0 —— 否则片头片尾会凭空出现"低谷"）；
/// 3. 除以最大值归一化到 0..1。
///
/// **没有数据就返回 null**（不画线）：弹幕为空、时长为 0、桶数不足 2、
/// 所有桶都是 0 一律 null —— 宁可什么都不画，也不画一条平线冒充"数据已就绪"。
library;

import '../models/danmaku.dart';

/// 分桶宽度（秒）：10s 一桶。短于 20s 的视频只有 1~2 桶，画不出曲线
/// （见 [buildHeatCurve] 的桶数判定）。
const double kHeatBucketSec = 10;

/// 滑动平均半径：1 = 取「本桶 ±1 桶」共 3 桶均值。
const int kHeatSmoothRadius = 1;

/// 桶数上限：超过就放宽桶宽（10 小时视频若按 10s 一桶会有 3600 个点）。
const int kHeatMaxBuckets = 600;

/// 一条可绘制的热度曲线（已归一化）。
///
/// 不可变：数据到齐时由播放页算**一次**并缓存，绘制层只读，不每帧重算。
class HeatCurve {
  /// 每个桶的热度（0..1，长度 = 桶数）。
  final List<double> values;

  /// 实际使用的桶宽（秒）。超长视频会大于 [kHeatBucketSec]。
  final double bucketSec;

  /// 计算时用的总时长（毫秒）。时长变了（换源 / 换集）必须重算。
  final int durationMs;

  const HeatCurve({
    required this.values,
    required this.bucketSec,
    required this.durationMs,
  });

  /// 能否画成一条线：至少 2 个点。单桶（极短视频）无法成线 → 不画。
  bool get isDrawable => values.length >= 2;

  @override
  String toString() =>
      'HeatCurve(${values.length} 桶 @${bucketSec.toStringAsFixed(1)}s, '
      'duration=${durationMs}ms)';
}

/// 由弹幕列表算热度曲线；**没有可用数据返回 null**（调用方据此不画线）。
///
/// - [danmaku]：当前**这一个 cid** 的全量弹幕（切 P 必须换成新 cid 的列表）
/// - [durationMs]：当前视频时长（<= 0 = 还没拿到 → null）
/// - [bucketSec] / [smoothRadius] / [maxBuckets]：见各常量；测试注入用
HeatCurve? buildHeatCurve(
  List<Danmaku> danmaku, {
  required int durationMs,
  double bucketSec = kHeatBucketSec,
  int smoothRadius = kHeatSmoothRadius,
  int maxBuckets = kHeatMaxBuckets,
}) {
  if (danmaku.isEmpty || durationMs <= 0 || bucketSec <= 0) return null;
  if (maxBuckets < 2) return null;

  final durationSec = durationMs / 1000.0;
  var step = bucketSec;
  var buckets = (durationSec / step).ceil();
  if (buckets < 2) return null; // 极短视频：一个桶画不出线
  if (buckets > maxBuckets) {
    // 超长视频：放宽桶宽，桶数固定在上限（点数量级恒定 → 绘制开销恒定）
    buckets = maxBuckets;
    step = durationSec / buckets;
  }

  final counts = List<int>.filled(buckets, 0);
  for (final d in danmaku) {
    final t = d.timeSec;
    // 脏时间（NaN / 负数 / 超出时长）不计入：超出时长的弹幕若塞进最后一桶
    // 会凭空在片尾造一个尖峰，宁可丢弃
    if (t.isNaN || t < 0 || t >= durationSec) continue;
    var i = (t / step).floor();
    if (i < 0) i = 0;
    if (i >= buckets) i = buckets - 1;
    counts[i]++;
  }

  final smoothed = _movingAverage(counts, smoothRadius);
  var max = 0.0;
  for (final v in smoothed) {
    if (v > max) max = v;
  }
  // 桶里一条弹幕都没有（或全被脏时间过滤掉）→ 不画，避免画一条平的假线
  if (max <= 0) return null;

  return HeatCurve(
    values: List<double>.unmodifiable([for (final v in smoothed) v / max]),
    bucketSec: step,
    durationMs: durationMs,
  );
}

/// 滑动平均：窗口 `[i-radius, i+radius]`，越界部分不计入分母（边缘用实际
/// 窗口数取均值）。[radius] <= 0 时原样返回 double 列表。
List<double> _movingAverage(List<int> counts, int radius) {
  if (radius <= 0) {
    return [for (final c in counts) c.toDouble()];
  }
  final out = List<double>.filled(counts.length, 0);
  for (var i = 0; i < counts.length; i++) {
    var sum = 0;
    var n = 0;
    final from = i - radius < 0 ? 0 : i - radius;
    final to = i + radius >= counts.length ? counts.length - 1 : i + radius;
    for (var j = from; j <= to; j++) {
      sum += counts[j];
      n++;
    }
    out[i] = n == 0 ? 0 : sum / n;
  }
  return out;
}
