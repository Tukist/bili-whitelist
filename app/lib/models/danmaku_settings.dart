/// 弹幕显示设置（v2.16.6+，v2.16.13+ 显示区域/开关记忆）：是否开启 /
/// 屏蔽词 / 屏蔽类型 / 全局透明度 / 显示区域。
///
/// 纯数据 + 纯逻辑（无 Flutter UI 依赖，可单测）：
/// - [shouldBlock]：发射前过滤判定（命中任一屏蔽词 或 所属类型被屏蔽 → 不显示）
/// - [opacity]：全局绘制透明度系数（0.2~1.0），CustomPaint 绘制时乘到颜色 alpha
/// - [displayAreaPercent]：弹幕显示区域（10~100，10 步进，100=默认全屏带）
/// - 序列化 toJson/fromJson 供 [DanmakuSettingsStore] 持久化（损坏容错回默认）
library;

import 'danmaku.dart';

/// 透明度滑杆下限（20%）。
const double kDanmakuOpacityMin = 0.2;

/// 透明度滑杆上限（100%）。
const double kDanmakuOpacityMax = 1.0;

/// 显示区域滑杆下限（10%，弹幕只出现在屏幕上方 10% 内）。
const int kDanmakuDisplayAreaMin = 10;

/// 显示区域滑杆上限（100% = 默认全屏带，与 v2.16.12 及更早布局一致）。
const int kDanmakuDisplayAreaMax = 100;

/// 显示区域步进（10%）。
const int kDanmakuDisplayAreaStep = 10;

/// 单条弹幕的屏蔽命中结果（供日志/测试区分原因）。
enum DanmakuBlockReason {
  /// 未被屏蔽。
  none,

  /// 弹幕文本命中屏蔽关键词。
  keyword,

  /// 弹幕所属类型（滚动/顶部/底部）被屏蔽。
  type,
}

/// 弹幕显示设置。不可变：任何修改经 [copyWith] 产生新实例（渲染层据此
/// 感知"设置变了"并即时重载，详见 danmaku_overlay.dart）。
///
/// 构造为 const 可用（默认值）；[blockWords] 约定已由 [normalizeWords]
/// 清洗（trim + 去空），UI 与存储层统一走该入口，不合法输入不会进入实例。
class DanmakuSettings {
  /// 屏蔽关键词列表（条目已 trim、空串剔除；命中 = 弹幕文本 substring 包含）。
  final List<String> blockWords;

  /// 是否屏蔽滚动弹幕（默认显示）。
  final bool blockScroll;

  /// 是否屏蔽顶部弹幕。
  final bool blockTop;

  /// 是否屏蔽底部弹幕。
  final bool blockBottom;

  /// 弹幕是否开启（总开关，播放页底部「弹幕」按钮点按切换）。
  /// v2.16.13 起随设置一起持久化：重启 App 后保持用户上次的开关状态。
  final bool enabled;

  /// 弹幕显示区域占屏高度百分比（10~100，步进 10；100=默认全屏带）。
  /// 渲染层按此把弹幕轨道限制在屏幕**上方**该比例高度内滚动（防弹幕
  /// 飘到画面中下部妨碍观感）。字段缺失（旧版本设置）→ 默认 100。
  final int displayAreaPercent;

  /// 全局透明度（0.2~1.0，1.0=完全不透明，绘制时乘到弹幕颜色 alpha）。
  final double opacity;

  const DanmakuSettings({
    this.blockWords = const [],
    this.blockScroll = false,
    this.blockTop = false,
    this.blockBottom = false,
    this.enabled = false,
    this.displayAreaPercent = kDanmakuDisplayAreaMax,
    this.opacity = kDanmakuOpacityMax,
  });

  /// 构造时的入参约束依赖调用方传入已清洗的词；本方法提供标准清洗入口
  /// （trim + 去空 + 去重保序），UI 添加词/解析旧数据时统一走这里。
  static List<String> normalizeWords(Iterable<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final w in raw) {
      final t = w.trim();
      if (t.isEmpty || seen.contains(t)) continue;
      seen.add(t);
      out.add(t);
    }
    return List.unmodifiable(out);
  }

  /// 弹幕所属类型是否被屏蔽。
  bool isTypeBlocked(Danmaku d) {
    if (d.isTop) return blockTop;
    if (d.isBottom) return blockBottom;
    return blockScroll;
  }

  /// 弹幕文本是否命中任一屏蔽词（substring 匹配，大小写不敏感）。
  bool isTextBlocked(String text) {
    if (blockWords.isEmpty) return false;
    final lower = text.toLowerCase();
    for (final w in blockWords) {
      if (lower.contains(w.toLowerCase())) return true;
    }
    return false;
  }

  /// 发射前过滤判定：命中返回原因，未命中返回 [DanmakuBlockReason.none]。
  /// 类型屏蔽优先（type），其次关键词（keyword）。
  DanmakuBlockReason blockReason(Danmaku d) {
    if (isTypeBlocked(d)) return DanmakuBlockReason.type;
    if (isTextBlocked(d.text)) return DanmakuBlockReason.keyword;
    return DanmakuBlockReason.none;
  }

  /// 是否应屏蔽该弹幕（[blockReason] != none 的简写）。
  bool shouldBlock(Danmaku d) => blockReason(d) != DanmakuBlockReason.none;

  /// 复制并改指定字段（blockWords 传 null 表示保持不变；传值需已清洗）。
  DanmakuSettings copyWith({
    List<String>? blockWords,
    bool? blockScroll,
    bool? blockTop,
    bool? blockBottom,
    bool? enabled,
    int? displayAreaPercent,
    double? opacity,
  }) {
    return DanmakuSettings(
      blockWords: blockWords ?? this.blockWords,
      blockScroll: blockScroll ?? this.blockScroll,
      blockTop: blockTop ?? this.blockTop,
      blockBottom: blockBottom ?? this.blockBottom,
      enabled: enabled ?? this.enabled,
      displayAreaPercent:
          normalizeDisplayArea(displayAreaPercent ?? this.displayAreaPercent),
      opacity: (opacity ?? this.opacity)
          .clamp(kDanmakuOpacityMin, kDanmakuOpacityMax)
          .toDouble(),
    );
  }

  /// 显示区域百分比归一化：越界 / 非 10 步进值收敛到合法档位
  /// （10..100、10 倍数）。UI 滑杆（divisions 已锁步进）与反序列化
  /// （脏数据，如 35/200/5）统一走这里，保证实例内字段恒合法。
  static int normalizeDisplayArea(int raw) {
    final snapped = ((raw + kDanmakuDisplayAreaStep ~/ 2) ~/
            kDanmakuDisplayAreaStep) *
        kDanmakuDisplayAreaStep;
    return snapped.clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax);
  }

  Map<String, dynamic> toJson() => {
        'blockWords': blockWords,
        'blockScroll': blockScroll,
        'blockTop': blockTop,
        'blockBottom': blockBottom,
        'enabled': enabled,
        'displayAreaPercent': displayAreaPercent,
        // 存 0~1 浮点，四舍五入到万分位避免重复读写的二进制尾巴
        'opacity': (opacity * 10000).round() / 10000.0,
      };

  /// 反序列化：字段缺失/类型非法回退默认；blockWords 走 [normalizeWords]
  /// 清洗（兼容手改脏数据）。整体异常（非 Map 等）由调用方兜底。
  factory DanmakuSettings.fromJson(Map<String, dynamic> json) {
    // bool 字段容错：值不是 bool（脏数据，如字符串）→ 回退默认 false
    bool flag(String key) => json[key] is bool ? json[key] as bool : false;
    return DanmakuSettings(
      blockWords: normalizeWords(
        (json['blockWords'] as List?)?.whereType<String>() ?? const [],
      ),
      blockScroll: flag('blockScroll'),
      blockTop: flag('blockTop'),
      blockBottom: flag('blockBottom'),
      // 弹幕开关默认关（旧版本无此字段）；缺失 → false
      enabled: flag('enabled'),
      // 显示区域缺失（旧版本）→ 100 全屏带；脏值经 normalize 收敛
      displayAreaPercent: normalizeDisplayArea(
        (json['displayAreaPercent'] as num?)?.toInt() ??
            kDanmakuDisplayAreaMax,
      ),
      opacity: ((json['opacity'] as num?)?.toDouble() ??
              kDanmakuOpacityMax)
          .clamp(kDanmakuOpacityMin, kDanmakuOpacityMax)
          .toDouble(),
    );
  }

  @override
  String toString() =>
      'DanmakuSettings(enabled=${enabled ? '开' : '关'} '
      'area=$displayAreaPercent% '
      'words=$blockWords scroll=${blockScroll ? 'X' : '·'}'
      ' top=${blockTop ? 'X' : '·'} bottom=${blockBottom ? 'X' : '·'}'
      ' opacity=${(opacity * 100).round()}%)';
}
