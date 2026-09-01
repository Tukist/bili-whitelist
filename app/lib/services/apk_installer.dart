/// 应用内版本更新（M1.4）：Dart 侧 MethodChannel 封装，跳原生 ApkInstaller.kt。
///
/// 原生侧用 FileProvider 暴露 ApplicationSupport 目录给系统安装器，
/// 避免 API 24+ 直接传 file:// URI 抛 FileUriExposedException。
///
/// channel 名 `app.apk_installer` 与 Kotlin `ApkInstaller.CHANNEL` 严格一致。
library;

import 'package:flutter/services.dart';

class ApkInstallerChannel {
  static const MethodChannel _ch = MethodChannel('app.apk_installer');

  /// 调原生安装入口。返回 `null` 即视为成功触发系统安装流程；
  /// 原生侧通过 [MethodChannel] 的 result.error 上报 NOT_FOUND /
  /// INVALID_ARG / INSTALL_FAILED 三类错误，本函数直接 rethrow 让 UI 处理。
  Future<void> install(String path) async {
    await _ch.invokeMethod<void>('install', {'path': path});
  }
}
