/// 「运营商通用流量」快照存储 + 差值算法（v2.53.0，个人页「流量计量」用）。
///
/// ## 为什么只能手动录入
///
/// 用户要的是"同时读自己的移动数据用量和运营商通用流量用量，相减得结果"。
/// **运营商侧的"剩余免流额度 / 通用流量已用 / 套餐余额"没有任何公开接口或授权**
/// 可供第三方 App 读取（三大运营商都是封闭的自家营业厅/App 接口）——所以：
/// - **系统口径**（本 App 的移动数据用量）：App 自己读（`TrafficStatsService`）；
/// - **运营商口径**：**用户从运营商 App 抄一个数进来**，本 store 把它记成快照。
///
/// ## 算法（两个快照相减）
///
/// 看视频前记一次、看完再记一次：
/// - `运营商增量 = 后一次通用流量已用 − 前一次`（GB）；
/// - `本 App 移动增量 = 后一次系统读数 − 前一次`（字节）；
/// - **疑似免流 ≈ 本 App 移动增量 − 运营商通用增量**：本 App 确实下载了这么多
///   移动流量，而这期间运营商的通用流量只涨了那么点，差就是"没走通用流量"的部分
///   （最可能就是被定向免流吃掉了）。
///
/// ⚠️ 口径本来就不同：运营商计费有延迟（几分钟到几小时）、两边四舍五入不同、
/// 系统统计不含某些流量（tethering/系统流量不走本 UID），所以结果**只是参考**，
/// 不许写成"你免了 X GB"（界面上必须带这句说明，见 `traffic_panel.dart`）。
///
/// 单位：**1 GB = 1024³ 字节**（国内三大运营商计费按 1024 进制）。这与本仓库
/// `fmtBytes()` 的换算一致，两个数能直接对照。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 1 GB 的字节数（运营商计费口径：1GB = 1024MB = 1024³B）。
const double kBytesPerGb = 1024 * 1024 * 1024;

/// 一条快照的**来源**（v2.54.0：界面必须能看出这个数字是自动读到的还是手填的）。
enum SnapshotSource {
  /// 用户从运营商 App 抄进来、手动录入的。
  manual,

  /// App 从中国移动掌厅页面**自动读到**的（非官方接口，可能失效）。
  cmcc,
}

/// 自动快照的最小间隔：短时间内反复刷新（点两下）不该堆出两条快照，
/// 把用户珍贵的手动快照挤出 [TrafficSnapshotStore.maxSnapshots] 名额。
const Duration kAutoSnapshotMinGap = Duration(minutes: 5);

/// 一条快照：某时刻"运营商 App 里显示的通用流量已用" + 当时的系统读数。
class CarrierSnapshot {
  /// 记录时刻（本地时间）。
  final DateTime at;

  /// 运营商侧显示的「通用流量已用」（GB）。
  final double carrierGb;

  /// 记录时的**本 App 移动流量**（字节；`< 0` = 当时读不到，不许用 0 冒充）。
  final int appMobileBytes;

  /// 这个数字怎么来的（手动抄 / 掌厅自动读）。
  final SnapshotSource source;

  const CarrierSnapshot({
    required this.at,
    required this.carrierGb,
    this.appMobileBytes = -1,
    this.source = SnapshotSource.manual,
  });

  /// 这条快照有没有可用的系统读数（做差值需要两条都有）。
  bool get hasAppReading => appMobileBytes >= 0;

  /// 是不是自动读到的那条（界面加"自动"标记）。
  bool get isAuto => source == SnapshotSource.cmcc;

  Map<String, Object?> toJson() => {
        'at': at.millisecondsSinceEpoch,
        'carrierGb': carrierGb,
        'appBytes': appMobileBytes,
        // 老数据没有这个字段 → 读回来按"手动"处理（v2.54.0 之前全是手填的）
        'src': source == SnapshotSource.cmcc ? 'cmcc' : 'manual',
      };

  /// 从盘上的 JSON 还原；结构不对（缺字段/类型错/时间非法）→ null（跳过这一条）。
  static CarrierSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ms = raw['at'];
    final gb = raw['carrierGb'];
    if (ms is! num || gb is! num) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    final bytes = raw['appBytes'];
    return CarrierSnapshot(
      at: at,
      carrierGb: gb.toDouble(),
      appMobileBytes: bytes is num ? bytes.toInt() : -1,
      source: raw['src'] == 'cmcc' ? SnapshotSource.cmcc : SnapshotSource.manual,
    );
  }

  @override
  String toString() => 'CarrierSnapshot($at, ${carrierGb}GB, '
      'app=${appMobileBytes}B, src=${source.name})';
}

/// 这次自动读数**该不该**记成快照（纯函数，测试直接钉）。
///
/// 规则：只有"最近一条已经是自动快照、且距现在不足 [kAutoSnapshotMinGap]"才拦。
/// 手动快照永远不拦（用户点了就是要记）；两条自动快照隔得够久就正常记。
bool mayRecordAutoSnapshot({
  required CarrierSnapshot? latest,
  required DateTime now,
  Duration minGap = kAutoSnapshotMinGap,
}) {
  if (latest == null) return true;
  if (!latest.isAuto) return true;
  return now.difference(latest.at).abs() >= minGap;
}

/// 两次快照的差值结果（**算得出与算不出都如实表达**）。
class TrafficDiff {
  const TrafficDiff({
    required this.older,
    required this.newer,
    required this.carrierDeltaGb,
    required this.appDeltaBytes,
    required this.suspectFreeGb,
  });

  final CarrierSnapshot older;
  final CarrierSnapshot newer;

  /// 运营商通用流量的增量（GB）；**可能为负**（换月重置 / 用户抄错数）。
  final double carrierDeltaGb;

  /// 本 App 移动流量的增量（字节）；null = 两次快照有一次没有系统读数，
  /// 或后一次比前一次小（换月/系统统计被清）→ 算不出。
  final int? appDeltaBytes;

  /// **疑似免流量**（GB）= 本 App 增量 − 运营商增量；null = 算不出。
  ///
  /// 界面上必须写成"疑似/≈"，并带上口径说明。
  final double? suspectFreeGb;

  /// 这组数看起来能不能用：运营商增量非负、且两个系统读数都有。
  bool get plausible => carrierDeltaGb >= 0 && appDeltaBytes != null;

  /// 差值时长（后一次 − 前一次）。
  Duration get span => newer.at.difference(older.at);
}

/// 两个快照相减；[newer] 早于 [older] 时**交换**（不报错，按时间顺序算）。
TrafficDiff diffSnapshots(CarrierSnapshot a, CarrierSnapshot b) {
  final older = b.at.isBefore(a.at) ? b : a;
  final newer = b.at.isBefore(a.at) ? a : b;
  final carrierDeltaGb = newer.carrierGb - older.carrierGb;
  final appDeltaBytes =
      (older.hasAppReading && newer.hasAppReading &&
              newer.appMobileBytes >= older.appMobileBytes)
          ? newer.appMobileBytes - older.appMobileBytes
          : null;
  final suspectFreeGb = appDeltaBytes == null
      ? null
      : appDeltaBytes / kBytesPerGb - carrierDeltaGb;
  return TrafficDiff(
    older: older,
    newer: newer,
    carrierDeltaGb: carrierDeltaGb,
    appDeltaBytes: appDeltaBytes,
    suspectFreeGb: suspectFreeGb,
  );
}

/// 解析用户输入的「通用流量已用」GB 数。
///
/// 容错（用户是手抄运营商 App 上的数字，不该因为多打一个单位就报错）：
/// - `12.34` / `12.34GB` / `12.34 gb` / `12.34G` / 前后空格 / 全角数字与小数点；
/// - 千分位 `1,234.5`；只有逗号没有点号（`12,34`）按小数点处理；
/// - 负数、非数字、超过 1e7 GB（明显打错）→ **返回 null**（界面给友好提示）。
double? tryParseCarrierGb(String raw) {
  var s = _halfWidthDigits(raw)
      .replaceAll('Ｇ', 'G')
      .replaceAll('ｇ', 'g')
      .replaceAll('Ｂ', 'B')
      .replaceAll('ｂ', 'b')
      .replaceAll('．', '.')
      .replaceAll('，', ',')
      .replaceAll('　', ' ')
      .trim();
  if (s.isEmpty) return null;
  // 去掉单位后缀（GB / G）
  s = s.replaceFirst(RegExp(r'[gG]\s*[bB]?\s*$'), '').trim();
  // 逗号：与点号同时出现时它一定是千分位；只有逗号时按"是否像千分位"判断
  // （`1,234` → 1234；`12,34` → 12.34，即"只有逗号没有点号时当小数点"）
  if (s.contains(',')) {
    if (s.contains('.')) {
      s = s.replaceAll(',', '');
    } else {
      final parts = s.split(',');
      final thousands = parts.first.length <= 3 &&
          parts.skip(1).every((p) => p.length == 3);
      s = thousands ? s.replaceAll(',', '') : s.replaceFirst(',', '.');
    }
  }
  if (s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null || v.isNaN || v.isInfinite || v < 0 || v >= 1e7) return null;
  return v;
}

/// 全角数字 → 半角（用户从运营商 App 抄数字时，输入法常给全角）。
///
/// 只动 `U+FF10..U+FF19`（０-９）这一段；其余字符原样保留（单位、小数点、
/// 负号等由调用方自己处理）。
String _halfWidthDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0xFF10 && r <= 0xFF19 ? r - 0xFF10 + 0x30 : r);
  }
  return b.toString();
}

/// 快照存储（单例，**落盘**：重启后"上次记的那两条"还在）。
///
/// 只留最近 [maxSnapshots] 条（默认 8）：做差值只用最近两条，留几条是为了让用户
/// 能回看"我这几次记的数"和手滑记错时删掉重记；再多就是垃圾数据了。
class TrafficSnapshotStore extends ChangeNotifier {
  /// 存储 key（String：JSON 数组，旧 → 新）。
  static const String snapshotsKey = 'traffic:carrier_snapshots';

  /// 最多留几条。
  static const int maxSnapshots = 8;

  /// 全局单例（个人页写、UI 读）。
  static final TrafficSnapshotStore instance = TrafficSnapshotStore._();

  TrafficSnapshotStore._();

  List<CarrierSnapshot> _snapshots = const [];
  bool _loaded = false;

  /// 全部快照（**旧 → 新**；不可变视图，别在外部改）。
  List<CarrierSnapshot> get snapshots => List.unmodifiable(_snapshots);

  /// 最近一条（没有则 null）。
  CarrierSnapshot? get latest => _snapshots.isEmpty ? null : _snapshots.last;

  /// 启动时读一次；幂等（重复调用只在首次真正读盘）。
  /// 读失败 / JSON 坏掉 → 当作"没有快照"，不抛（那几条说明性数据不值得崩页面）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    var next = const <CarrierSnapshot>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      next = decodeSnapshots(prefs.getString(snapshotsKey));
    } catch (_) {
      next = const <CarrierSnapshot>[];
    }
    _loaded = true;
    if (!_sameList(next, _snapshots)) {
      _snapshots = next;
      notifyListeners();
    }
  }

  /// 记一条快照（立即生效 + 落盘；写失败静默，本次内存里仍然能用）。
  Future<void> add(CarrierSnapshot snapshot) async {
    final next = [..._snapshots, snapshot];
    // 超出上限：从最旧的开始丢
    _snapshots = next.length > maxSnapshots
        ? next.sublist(next.length - maxSnapshots)
        : next;
    notifyListeners();
    await _save();
  }

  /// 删掉最后一条（手滑记错时的撤销手段）。
  Future<void> removeLatest() async {
    if (_snapshots.isEmpty) return;
    _snapshots = _snapshots.sublist(0, _snapshots.length - 1);
    notifyListeners();
    await _save();
  }

  /// 清空全部快照。
  Future<void> clear() async {
    if (_snapshots.isEmpty) return;
    _snapshots = const [];
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_snapshots.isEmpty) {
        await prefs.remove(snapshotsKey);
        return;
      }
      await prefs.setString(snapshotsKey, encodeSnapshots(_snapshots));
    } catch (_) {
      // 写入失败静默（本次已生效，下次启动回到上次成功保存的值）
    }
  }

  /// 测试用：重置内存态（不触碰存储），避免单例跨用例串味。
  @visibleForTesting
  void resetForTest({List<CarrierSnapshot>? snapshots, bool loaded = false}) {
    _snapshots = snapshots ?? const [];
    _loaded = loaded;
  }

  /// 序列化（纯函数，测试直接钉）。结构不对的条目被跳过，不整串丢弃。
  static String encodeSnapshots(List<CarrierSnapshot> list) =>
      jsonEncode([for (final s in list) s.toJson()]);

  /// 反序列化（纯函数，测试直接钉）；坏数据一律跳过。
  static List<CarrierSnapshot> decodeSnapshots(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (CarrierSnapshot.fromJson(e) case final s?) s,
      ];
    } catch (_) {
      return const [];
    }
  }

  static bool _sameList(List<CarrierSnapshot> a, List<CarrierSnapshot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].at != b[i].at ||
          a[i].carrierGb != b[i].carrierGb ||
          a[i].appMobileBytes != b[i].appMobileBytes) {
        return false;
      }
    }
    return true;
  }
}
