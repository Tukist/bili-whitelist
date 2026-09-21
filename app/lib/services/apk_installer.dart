/// 应用内版本更新（M1.4）：Dart 侧 MethodChannel 封装，跳原生 ApkInstaller.kt。
///
/// 原生侧用 FileProvider 暴露 ApplicationSupport 目录给系统安装器，
/// 避免 API 24+ 直接传 file:// URI 抛 FileUriExposedException。
///
/// channel 名 `app.apk_installer` 与 Kotlin `ApkInstaller.CHANNEL` 严格一致。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// 「安装未知应用」权限未开时原生回的错误码（见 `ApkInstaller.kt`）。
///
/// 正常路径下 Dart 会先调 [ApkInstallerChannel.canInstallUnknownApps] 拦住，
/// 这个码是**兜底**：万一检查与安装之间权限被撤（或检查本身不可用），安装仍会
/// 被系统拒绝，此时按同一套引导文案处理，而不是甩一句看不懂的原生错误。
const String kNeedUnknownSourcesCode = 'NEED_UNKNOWN_SOURCES';

class ApkInstallerChannel {
  static const MethodChannel _ch = MethodChannel('app.apk_installer');

  /// 调原生安装入口。返回 `null` 即视为成功触发系统安装流程；
  /// 原生侧通过 [MethodChannel] 的 result.error 上报 NOT_FOUND /
  /// INVALID_ARG / INSTALL_FAILED / NEED_UNKNOWN_SOURCES 等错误，
  /// 本函数直接 rethrow 让 UI 归因处理。
  ///
  /// 日志只打文件名（绝对路径冗长且无信息量）。
  Future<void> install(String path) async {
    debugPrint('[update] install 通道调用：${path.split(RegExp(r'[/\\]')).last}');
    await _ch.invokeMethod<void>('install', {'path': path});
  }

  /// 当前 App 是否被允许安装未知来源应用（Android 8+ 的
  /// `PackageManager.canRequestPackageInstalls`）。
  ///
  /// **查不到就按「允许」**：原生没实现该方法（老包）/ 测试环境无原生通道时会抛
  /// [MissingPluginException] —— 把用户堵在安装门外，比「让系统安装器自己拦一下」
  /// 更糟，所以回 true，由 [install] 那一步兜底并给出可读原因。
  Future<bool> canInstallUnknownApps() async {
    try {
      final allowed = await _ch.invokeMethod<bool>('canInstallUnknownApps');
      return allowed ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// 跳系统「安装未知应用」设置页：`Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`
  /// + 本应用包名（原生在个别 ROM 缺该页面时会退化到应用详情页）。
  Future<void> openUnknownSourcesSettings() async {
    await _ch.invokeMethod<void>('openUnknownSourcesSettings');
  }
}
