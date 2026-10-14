/// 流量计量的**原生通道**封装（v2.53.0，个人页「流量计量」用）。
///
/// 对应原生 `TrafficStatsPlugin.kt`（MethodChannel
/// `bili_whitelist/traffic_stats`）：读**本 App / 本机**的**移动数据**用量，并
/// 提供「使用情况访问」这个特殊权限的查询与引导入口。
///
/// 与 `ImagePickService` / `ScheduleImportService` 同一套约定（不引新依赖、
/// 原生能力走 MainActivity 手动注册的 MethodChannel、错误码到中文的映射只在
/// 这一处做、**永不抛**给界面）：
/// - 本类所有方法都不抛异常：能读就给数字，读不到就给一句能直接显示的中文，
///   或者"读不到"本身（null）—— 界面据此决定显示数字还是显示引导按钮；
/// - **不臆造数字**：任何一项读不到就是 null，不用 0 冒充"没用流量"。
///
/// 口径提醒（写在代码里也写在界面上）：这里读的是**系统统计**，与运营商计费
/// 口径本来就有出入（计费延迟、四舍五入、系统统计不覆盖全部流量）→
/// 结果仅供参考，以运营商账单为准。
library;

import 'package:flutter/services.dart';

/// 一次移动流量查询的结果：本 App 与 本机总量（单位：字节）。
///
/// 任一项为 null = 那一项读不到（例：未开「使用情况访问」时读不到本机总量）。
class MobileTrafficSample {
  /// 本 App 的移动数据用量（按 UID 聚合；**不含 Wi-Fi**）。
  final int? appBytes;

  /// 本机全部 App 的移动数据用量（device 口径；**不含 Wi-Fi**）。
  final int? deviceBytes;

  const MobileTrafficSample({this.appBytes, this.deviceBytes});

  /// 两项都读不到（整条查询没拿到东西）。
  bool get isEmpty => appBytes == null && deviceBytes == null;

  @override
  String toString() =>
      'MobileTrafficSample(app=$appBytes, device=$deviceBytes)';
}

/// 一次查询的结果：[sample] 与 [error] 不同时存在。
///
/// 为什么要分成"数字"和"一句话"两种出口：用户要的是"读不到时说清楚 + 给个
/// 按钮"，不是让界面去猜错误码；成功时也不该因为一句提示就少显示数字。
class TrafficQueryResult {
  /// 读到的数字（失败时为 null）。
  final MobileTrafficSample? sample;

  /// 面向用户的中文失败原因（成功时为 null）。
  final String? error;

  const TrafficQueryResult.ok(MobileTrafficSample this.sample) : error = null;

  const TrafficQueryResult.failed(String this.error) : sample = null;

  bool get isOk => sample != null;
}

/// 流量统计服务（无状态；测试直接 mock 那条 MethodChannel 即可，
/// 同 `test/collection_cover_pick_test.dart` 的做法）。
class TrafficStatsService {
  /// 与原生 `TrafficStatsPlugin.CHANNEL` 必须一致。
  static const MethodChannel channel =
      MethodChannel('bili_whitelist/traffic_stats');

  const TrafficStatsService();

  /// 当前是否已开启「使用情况访问」（特殊权限；用户必须在系统设置里手动开）。
  ///
  /// 非 Android / 通道缺失时返回 false（= "没开"，界面给引导按钮，
  /// 而不是把 MissingPluginException 抛到界面）。
  Future<bool> hasUsageAccess() async {
    try {
      return await channel.invokeMethod<bool>('hasUsageAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳到系统「使用情况访问」设置页；返回是否成功拉起（false = 没拉起来，
  /// 界面应该给一句"请到 设置 → 应用 → 特殊应用权限 里手动开启"）。
  Future<bool> openUsageAccessSettings() async {
    try {
      return await channel.invokeMethod<bool>('openUsageAccessSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 查 `[from, to)` 区间内的移动数据用量（**只算蜂窝，不含 Wi-Fi**）。
  ///
  /// [from] 与 [to] 的毫秒时间戳传给原生；区间不合法（to <= from）原生回
  /// error，这里映射成一句中文。
  Future<TrafficQueryResult> queryMobile({
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final raw = await channel.invokeMethod<Object?>('queryMobile', {
        'fromMs': from.millisecondsSinceEpoch,
        'toMs': to.millisecondsSinceEpoch,
      });
      if (raw is! Map) {
        return const TrafficQueryResult.failed('读不到流量统计：返回的数据不对');
      }
      return TrafficQueryResult.ok(MobileTrafficSample(
        appBytes: _asBytes(raw['appBytes']),
        deviceBytes: _asBytes(raw['deviceBytes']),
      ));
    } on PlatformException catch (e) {
      return TrafficQueryResult.failed(
          _messageForError(e.code, e.message));
    } on MissingPluginException {
      return const TrafficQueryResult.failed('当前版本不支持流量统计');
    } catch (_) {
      return const TrafficQueryResult.failed('读流量统计失败，请重试');
    }
  }

  /// **免权限**的兜底对照：本机移动数据累计（自开机以来，`TrafficStats`）。
  ///
  /// 为什么要有：没开「使用情况访问」时读不到"本月本机总量"，但用户至少能看
  /// 一个"从开机到现在一共用了多少移动流量"的数字（界面必须如实标注"自开机
  /// 以来"，不能冒充"本月"）。读不到（设备不支持 / 通道缺失）→ null。
  Future<int?> mobileSinceBoot() async {
    try {
      final v = await channel.invokeMethod<num>('mobileSinceBoot');
      final n = v?.toInt();
      // 系统不支持时 TrafficStats 回负数（UNSUPPORTED）→ 当作读不到
      if (n == null || n < 0) return null;
      return n;
    } catch (_) {
      return null;
    }
  }

  /// 本月口径的时间区间：本地时区**月初 00:00** → [now]。
  ///
  /// 纯函数（可被测试逐值钉住）。为什么用本地时区：运营商账单按本地时间分月，
  /// 用户看到的"本月"也是本地口径（跨时区使用是极小概率，不做处理）。
  static ({DateTime from, DateTime to}) monthRange(DateTime now) => (
        from: DateTime(now.year, now.month),
        to: now,
      );

  /// 原生回来的是 Long（可能为 null = 那一项读不到）；负数当作读不到。
  static int? _asBytes(Object? raw) {
    if (raw is! num) return null;
    final n = raw.toInt();
    return n < 0 ? null : n;
  }

  static String _messageForError(String code, String? detail) {
    switch (code) {
      case 'STATS_FAILED':
        return '读不到流量统计${_detail(detail)}'
            '；如果刚开「使用情况访问」，回到 App 再刷新一次';
      case 'NO_SERVICE':
        return '这台设备没有流量统计服务';
      case 'BAD_ARGS':
        return '查询区间不合法';
      default:
        return '读流量统计失败${_detail(detail)}';
    }
  }

  static String _detail(String? detail) =>
      detail == null || detail.isEmpty ? '' : '（$detail）';
}
