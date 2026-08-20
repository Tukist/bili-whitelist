import '../sync/whitelist_source.dart';

/// 极简服务定位器：全局持有 [WhitelistSyncService] 单例。
///
/// 避免在页面里重复构造带 dio 的同步服务；测试可注入替换实现。
class ServiceLocator {
  static WhitelistSyncService? _syncService;

  static WhitelistSyncService get syncService =>
      _syncService ??= WhitelistSyncService();

  /// 测试用：注入替身。
  static void overrideSyncService(WhitelistSyncService service) {
    _syncService = service;
  }
}
