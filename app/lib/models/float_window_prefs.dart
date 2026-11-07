/// 应用内浮动小窗的窗口状态（v2.65.0）：大小 / 位置 / 锁定。
///
/// 为什么存**比例**而不是 dp：
/// - 不同机型屏宽差很多（320~480dp），横竖屏切换、分屏也会变；存 dp 会让
///   "上次调好的窗口"在新宽度下跑到屏幕外或占满整屏；
/// - 三个比例都是相对**可移动空间**的（见各字段注释），所以取值天然落在
///   0~1 之间，读回来直接夹取就能用，不需要知道上次的屏幕尺寸。
///
/// 与 [DanmakuSettings] 同一套写法：纯数据 + 纯逻辑（不依赖 Flutter UI），
/// 序列化交给 `FloatWindowStore`；坏值逐字段回退默认，绝不整条丢弃。
library;

/// 默认宽度比：屏宽 40%（用户原话「小窗」——再大就挡着信息块与评论区了）。
const double kFloatDefaultWidthRatio = 0.40;

/// 默认水平位置比：1 = 贴右（右手拇指够得着，也不压着标题）。
const double kFloatDefaultDxRatio = 1.0;

/// 默认垂直位置比：0 = 贴顶（紧挨状态栏下方，不挡评论区首屏）。
const double kFloatDefaultDyRatio = 0.0;

/// 宽度比的合法下限：0 或负数会让窗口消失（且除法会炸），一律当坏值。
const double kFloatMinWidthRatio = 0.05;

/// 应用内浮动小窗的窗口状态。不可变：任何修改经 [copyWith] 产生新实例。
class FloatWindowPrefs {
  /// 窗口宽度 / 页面宽度（0.40 = 屏宽 40%）。
  final double widthRatio;

  /// 窗口左边距 / 可移动的水平空间（0 = 贴左，1 = 贴右）。
  ///
  /// "可移动空间" = 页面宽度 − 窗口宽度：窗口不能有一半露在屏幕外，所以
  /// 左边界只能在这段区间里走，用它做分母比用整页宽度更直观（0/1 就是两端）。
  final double dxRatio;

  /// 窗口上边距 / 可移动的垂直空间（0 = 贴顶，1 = 贴底）。
  ///
  /// 同上，分母 = 可视区高度 − 窗口高度（可视区已去掉状态栏与底部手势条）。
  final double dyRatio;

  /// 是否锁定：锁定后窗口不可拖动、不可缩放（防误触），但**可以**还原大屏。
  final bool locked;

  const FloatWindowPrefs({
    this.widthRatio = kFloatDefaultWidthRatio,
    this.dxRatio = kFloatDefaultDxRatio,
    this.dyRatio = kFloatDefaultDyRatio,
    this.locked = false,
  });

  FloatWindowPrefs copyWith({
    double? widthRatio,
    double? dxRatio,
    double? dyRatio,
    bool? locked,
  }) {
    return FloatWindowPrefs(
      widthRatio: widthRatio ?? this.widthRatio,
      dxRatio: dxRatio ?? this.dxRatio,
      dyRatio: dyRatio ?? this.dyRatio,
      locked: locked ?? this.locked,
    );
  }

  /// 序列化（字段名取短名：这是**本机私有**的一份小状态，不需要可读性）。
  Map<String, dynamic> toJson() => {
        'w': widthRatio,
        'x': dxRatio,
        'y': dyRatio,
        'locked': locked,
      };

  /// 反序列化：逐字段校验，坏值**只回退该字段**（其余字段仍然生效）。
  ///
  /// 容错的四类坏值：不是 Map / 字段缺失 / 不是数字（含 null、字符串、NaN、
  /// Infinity）/ 超出 0~1（宽度比另要求 ≥ [kFloatMinWidthRatio]）。
  /// 整条 JSON 损坏的情况由 `FloatWindowStore.get` 兜（decode 失败 → 默认）。
  factory FloatWindowPrefs.fromJson(Object? raw) {
    if (raw is! Map) return const FloatWindowPrefs();
    return FloatWindowPrefs(
      widthRatio:
          _ratio(raw['w'], kFloatDefaultWidthRatio, min: kFloatMinWidthRatio),
      dxRatio: _ratio(raw['x'], kFloatDefaultDxRatio),
      dyRatio: _ratio(raw['y'], kFloatDefaultDyRatio),
      // 只有明确的 true 才算锁定：其余（缺失 / 1 / "true"）一律按未锁定，
      // 宁可让用户能拖动，也不要因为一个坏值把小窗焊死在屏幕上。
      locked: raw['locked'] == true,
    );
  }

  /// 单个比例字段的校验：不是有限数字或越界 → [fallback]。
  static double _ratio(Object? raw, double fallback, {double min = 0}) {
    if (raw is! num) return fallback;
    final value = raw.toDouble();
    if (!value.isFinite || value < min || value > 1) return fallback;
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is FloatWindowPrefs &&
      other.widthRatio == widthRatio &&
      other.dxRatio == dxRatio &&
      other.dyRatio == dyRatio &&
      other.locked == locked;

  @override
  int get hashCode => Object.hash(widthRatio, dxRatio, dyRatio, locked);

  @override
  String toString() => 'FloatWindowPrefs(w=$widthRatio, x=$dxRatio, '
      'y=$dyRatio, locked=$locked)';
}
