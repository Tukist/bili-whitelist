/// 白名单 UP 主模型（whitelist.json v4 新增的 `upowners` 数组项）。
///
/// 数据流：
/// - 用户在搜索页搜 UP 主 → 选 [Upowner] → [UpownerWriter.add] 写 Gist
/// - 主页「信箱」入口检查所有 UP 主新视频 → 写 `last_seen_bvid` / `last_seen_at`
///
/// 字段说明：
/// - [mid]：B 站用户唯一 ID（必填，主键）
/// - [name] / [face]：展示用（搜索结果 / 信箱 / 详情页标题栏）
/// - [fans]：粉丝数缓存展示用，可为 null
/// - [addedAt]：加入白名单时间（ISO 8601）
/// - [lastSeenBvid] / [lastSeenAt]：信箱增量检查对照基准（最新见过哪个 bvid）
library;

import 'whitelist_video.dart';

/// 白名单 UP 主（与 WhitelistVideo 同级存在，videos 数组不冗余存 UP 主视频）。
class Upowner {
  final int mid;
  final String name;
  final String face; // 头像 URL
  final int? fans; // 缓存展示用
  final DateTime addedAt;
  final String? lastSeenBvid; // 信箱增量对照
  final DateTime? lastSeenAt; // 上次检查时间

  const Upowner({
    required this.mid,
    required this.name,
    required this.face,
    this.fans,
    required this.addedAt,
    this.lastSeenBvid,
    this.lastSeenAt,
  });

  factory Upowner.fromJson(Map<String, dynamic> json) => Upowner(
        mid: (json['mid'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
        face: json['face'] as String? ?? '',
        fans: (json['fans'] as num?)?.toInt(),
        addedAt: _parseDate(json['added_at']),
        lastSeenBvid: json['last_seen_bvid'] as String?,
        lastSeenAt: json['last_seen_at'] == null
            ? null
            : _parseDate(json['last_seen_at']),
      );

  Map<String, dynamic> toJson() => {
        'mid': mid,
        'name': name,
        'face': face,
        if (fans != null) 'fans': fans,
        'added_at': addedAt.toIso8601String(),
        if (lastSeenBvid != null) 'last_seen_bvid': lastSeenBvid,
        if (lastSeenAt != null) 'last_seen_at': lastSeenAt!.toIso8601String(),
      };

  /// 复制并修改 `lastSeen*`（信箱检查后写回用，其他字段不变）。
  Upowner copyWith({
    int? mid,
    String? name,
    String? face,
    int? fans,
    DateTime? addedAt,
    String? lastSeenBvid,
    DateTime? lastSeenAt,
  }) =>
      Upowner(
        mid: mid ?? this.mid,
        name: name ?? this.name,
        face: face ?? this.face,
        fans: fans ?? this.fans,
        addedAt: addedAt ?? this.addedAt,
        lastSeenBvid: lastSeenBvid ?? this.lastSeenBvid,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      );

  static DateTime _parseDate(dynamic raw) {
    if (raw is DateTime) return raw;
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return DateTime.now().toUtc();
  }
}

/// 「加入 UP 主」异常：message 可直接展示给用户。
class UpownerException implements Exception {
  final String message;

  const UpownerException(this.message);

  @override
  String toString() => 'UpownerException: $message';
}

/// 加入 UP 主到白名单：mid 查重，重复抛 [UpownerException]；返回新数据。
WhitelistData addUpowner(WhitelistData data, Upowner up) {
  if (data.upowners.any((u) => u.mid == up.mid)) {
    throw UpownerException('UP 主「${up.name}」（mid=${up.mid}）已在白名单中');
  }
  return data.copyWith(
    upowners: [...data.upowners, up],
  );
}

/// 从白名单移除 UP 主（mid 不存在 → 原样返回，不抛错）。
WhitelistData removeUpowner(WhitelistData data, int mid) {
  final filtered = data.upowners.where((u) => u.mid != mid).toList();
  if (filtered.length == data.upowners.length) return data;
  return data.copyWith(upowners: filtered);
}