/// 播放页「热度高潮线」：按弹幕密度算时间轴上的热度曲线（v2.61.0+，
/// v2.62.0 重做算法的后半段：更细的桶、高斯平滑、分位拉伸 + 伽马）。
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
/// ```
/// 1. 分桶      c[i] = 落在第 i 个桶里的弹幕条数（桶宽 kHeatBucketSec，上限定点）
/// 2. 平滑      s = c ⊛ 高斯核（σ = kHeatSmoothSigma 桶、半径 kHeatSmoothRadius 桶）
/// 3. 拉伸      t = clamp((s - p5) / max(p98 - p5, 0.20*peak), 0, 1)
/// 4. 伽马      v = t ^ kHeatGamma
/// ```
/// 起伏够大时 `t` 在峰值处必然 ≥ 1（被 clamp 成 1），所以**归一化是算式自带的**
/// （峰值恒为 1）；起伏太小（见 [kHeatStretchMinSpan]）时峰值抬不到 1，
/// 曲线整体贴底 —— 这是有意的：密度平齐的视频本来就没有高潮，不硬凑一个。
///
/// **没有数据就返回 null**（不画线）：弹幕为空、时长为 0、桶数不足 2、
/// 所有桶都是 0 一律 null —— 宁可什么都不画，也不画一条平线冒充"数据已就绪"。
/// 密度完全平齐（拉伸后处处为 0，没有任何起伏）同样 null：没有高潮可画。
///
/// ## v2.62.0 为什么动这一段（用户反馈原话）
/// > 「让热度线变成更加光滑的曲线，还有现在这个热度线的梯度有点小，总体太平」
/// - **不够光滑**：10s 一桶 + 半径 1 的三桶平均，点少、棱角多 → 桶宽降到 5s，
///   平滑换成高斯核（等效窗口更宽但峰形不被削平）。
/// - **太平**：长视频里弹幕密度本来就均匀，除以最大值后大量桶挤在 0.3~0.6，
///   视觉上就是一条平线 → 换成「分位拉伸 + 伽马」，背景沉到底、峰值顶到顶。
///   仍然只吃弹幕密度，不改任何语义：只是**显示映射**（相当于照片的自动对比度），
///   没有凭空造出原数据里不存在的起伏。
library;

import 'dart:math' as math;

import '../models/danmaku.dart';

/// 分桶宽度（秒）：5s 一桶（v2.61.0 是 10s）。
///
/// 20 分钟的番按 5s 一桶 = 240 个点，曲线才够看；短于**一桶**（5s）的视频
/// 只有 1 个点，成不了线 → 不画（见 [buildHeatCurve] 的桶数判定）。
const double kHeatBucketSec = 5;

/// 高斯平滑的 σ（单位：桶）。1.2 桶 ≈ 等效窗口 ±6s：
/// 够压住「某桶突然多两条弹幕」的毛刺，又不至于把 20~30s 的短高潮抹成缓坡。
const double kHeatSmoothSigma = 1.2;

/// 高斯核半径（单位：桶）。3σ 截断（1.2*3 = 3.6 → 取 3），
/// 权重 exp(-k²/(2σ²)) 在 k=3 时只剩 4%，再远的桶可以忽略。
const int kHeatSmoothRadius = 3;

/// 拉伸下分位：低于 P5 的一律压到 0（背景沉底）。
const double kHeatLowPercentile = 0.05;

/// 拉伸上分位（P98）：高于它的一律顶到 1（峰值顶格）。
///
/// 上分位取 0.98 而不是用户建议的 P90/P95，是因为**分位越窄拉伸越猛、
/// 但被钉在顶格的点也越多**：
/// - P90 → 10% 的点并列在 1.0，画出来是一段假平顶（台地），峰混在台地里；
/// - P95 → 5%（20 分钟的片子 ≈ 60 秒）仍然是一段台地；
/// - P98 → 只钉住最高的 2%，峰是「峰」；同时它又比 max 稳：单个离群桶
///   （刷屏、机器人）顶多把 P98 抬高一截，不至于把整条曲线压成一根针。
const double kHeatHighPercentile = 0.98;

/// 伽马：拉伸之后中间段再压一档。
///
/// 1.6 取自 1.4~2.0 的中段：以 0.5 为例，0.5^1.6 ≈ 0.33，背景明显下沉；
/// 以 0.85 为例 → 0.77，高位段几乎不动。再大（1.8 以上）会把整条曲线压成
/// 「贴着底 + 一根尖刺」，中段的起伏（副歌、二段高潮）就看不清了。
const double kHeatGamma = 1.6;

/// 拉伸分母的下限（相对峰值）：`denom = max(p98 - p5, 0.20 * peak)`。
///
/// 为什么要有：分位拉伸对**平坦**数据是纯噪声放大器 —— 每条弹幕数都差不多时
/// `p98 - p5` 只剩一点点（甚至只剩几个桶的抖动），硬拉会把「多一条弹幕」
/// 放大成一座假山。压一个下限后，起伏不到峰值 20% 的视频会被按比例压到
/// 接近底部（峰也抬不起来），**不放大噪声**；而且下限是连续的，
/// 不像开关那样在临界值上跳变。
///
/// 0.20 的取值：真实有高潮的视频，p5 与 p98 的差距普遍是峰值的 50% 以上，
/// 下限完全不起作用（等价于纯分位拉伸）；只有「从头到尾一个密度」的视频
/// 才会落进压缩区。
const double kHeatStretchMinSpan = 0.20;

/// 桶数上限：超过就放宽桶宽（5s 一桶时 50 分钟的视频刚好 600 点）。
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
/// - [bucketSec] / [smoothSigma] / [smoothRadius] / [maxBuckets]：见各常量；
///   测试注入用（[smoothSigma] <= 0 关闭平滑，用来对比"平滑前/后"）
HeatCurve? buildHeatCurve(
  List<Danmaku> danmaku, {
  required int durationMs,
  double bucketSec = kHeatBucketSec,
  double smoothSigma = kHeatSmoothSigma,
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

  var peak = 0;
  for (final c in counts) {
    if (c > peak) peak = c;
  }
  // 桶里一条弹幕都没有（或全被脏时间过滤掉）→ 不画，避免画一条平的假线
  if (peak <= 0) return null;

  // 2) 高斯平滑。先转 double 再做，避免整数均值的截断误差
  final smoothed = heatSmooth(
    [for (final c in counts) c.toDouble()],
    sigma: smoothSigma,
    radius: smoothRadius,
  );

  var smoothPeak = 0.0;
  for (final v in smoothed) {
    if (v > smoothPeak) smoothPeak = v;
  }
  if (smoothPeak <= 0) return null;

  // 3) 分位对比度拉伸：P5 以下沉到 0、P98 以上顶到 1（v2.62.0）
  final sorted = [...smoothed]..sort();
  final lo = _percentile(sorted, kHeatLowPercentile);
  final hi = _percentile(sorted, kHeatHighPercentile);
  // 分母下限：起伏不到峰值的 20% 就按住不放（见 [kHeatStretchMinSpan]），
  // 顺便兜住「所有桶一样多」时的除零
  final denom = math.max(hi - lo, kHeatStretchMinSpan * smoothPeak);

  final shaped = List<double>.filled(buckets, 0);
  var outPeak = 0.0;
  for (var i = 0; i < buckets; i++) {
    // 4) 伽马：clamp 之后 [0,1]，峰值天然落在 1（见文件头的说明）
    final t = denom > 0 ? ((smoothed[i] - lo) / denom).clamp(0.0, 1.0) : 0.0;
    final v = math.pow(t, kHeatGamma).toDouble();
    shaped[i] = v;
    if (v > outPeak) outPeak = v;
  }

  // 密度完全平齐（没有任何起伏）→ 没有高潮可画，不画（不画一条假的底边）。
  // 阈值不是 0：均匀输入经过高斯核的浮点累加会留下 ~1e-24 的残差，
  // 这种残差画出来就是「一条贴着底边的线」，等于没画，直接归到"没有起伏"。
  if (outPeak <= 1e-6) return null;

  return HeatCurve(
    values: List<double>.unmodifiable(shaped),
    bucketSec: step,
    durationMs: durationMs,
  );
}

/// 高斯平滑（测试可见）：窗口 `[i-radius, i+radius]`，核权重
/// `exp(-k²/(2σ²))`，**越界部分既不计入权重也不计入分母**（边缘按实际存在的
/// 桶归一化）——否则片头片尾会被凭空拉向 0，出现一段假低谷。
///
/// [sigma] <= 0 或 [radius] <= 0 时原样返回（测试里用来拿"未平滑"的对照组）。
List<double> heatSmooth(
  List<double> values, {
  double sigma = kHeatSmoothSigma,
  int radius = kHeatSmoothRadius,
}) {
  if (values.isEmpty || sigma <= 0 || radius <= 0) {
    return List<double>.of(values);
  }
  final n = 2 * radius + 1;
  final weights = List<double>.generate(n, (i) {
    final k = i - radius;
    return math.exp(-(k * k) / (2 * sigma * sigma));
  });
  final out = List<double>.filled(values.length, 0);
  for (var i = 0; i < values.length; i++) {
    var sum = 0.0;
    var wsum = 0.0;
    for (var j = -radius; j <= radius; j++) {
      final idx = i + j;
      if (idx < 0 || idx >= values.length) continue;
      final w = weights[j + radius];
      sum += w * values[idx];
      wsum += w;
    }
    out[i] = wsum == 0 ? 0 : sum / wsum;
  }
  return out;
}

/// 按「排序后位置 p*(n-1) 线性插值」取分位数（p ∈ 0..1）。
double _percentile(List<double> sorted, double p) {
  if (sorted.length == 1) return sorted.first;
  final pos = p * (sorted.length - 1);
  final i = pos.floor();
  if (i >= sorted.length - 1) return sorted.last;
  final frac = pos - i;
  return sorted[i] + (sorted[i + 1] - sorted[i]) * frac;
}
