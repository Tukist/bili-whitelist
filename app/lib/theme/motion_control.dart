import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

/// 装饰性动画的全局开关。
///
/// **生产恒为 true；`flutter test` 环境下自动为 false**。理由：测试里到处是
/// `pumpAndSettle`，而装饰性动画一旦是无限循环（烟缕的 `repeat()`），
/// `pumpAndSettle` 就会永远等不到静止 → 超时。默认关掉后，既有测试不必逐个
/// 改，widget 树也天然退化成静态形态（动画组件都实现了"静态一帧"分支）。
///
/// 测试若要验证动画本身，显式 `MotionControl.enabled = true`（用完 `reset()`）。
///
/// 只在**装饰性**动画上收口：进度、播放、拖拽等"内容本身的状态变化"
/// 不归它管（关掉会让用户读到错误状态）。
class MotionControl {
  MotionControl._();

  /// 装饰性动画的全局开关。
  ///
  /// 生产恒为 true；`flutter test` 环境下自动为 false —— 让既有测试的
  /// `pumpAndSettle` 不会被无限循环动画卡住，也让 widget 树退化成静态形态。
  /// 测试若要验证动画本身，显式 `MotionControl.enabled = true` 后再 `reset()`。
  static bool enabled = !_isFlutterTest;

  /// 当前进程是否跑在 `flutter test` 里。
  ///
  /// `flutter test`（`flutter_tools` 的 test 设备）会给子进程注入
  /// `FLUTTER_TEST` 环境变量，这是判断"是不是测试环境"最可靠、且不依赖
  /// 任何测试框架 API 的办法。`dart:io` 在本项目全部目标平台（Android /
  /// iOS / Windows / macOS / Linux）都可用——本项目无 Web 目标。
  ///
  /// 名字带下划线：只服务本文件的默认值，不对外暴露。
  static final bool _isFlutterTest =
      Platform.environment.containsKey('FLUTTER_TEST');

  /// 组件统一入口：显式开关 **且** 系统未开启"减少动画"。
  static bool of(BuildContext context) =>
      enabled && !MediaQuery.of(context).disableAnimations;

  /// 测试专用：恢复**默认值**（不是硬编码 true——默认值本身随环境变化：
  /// 生产 true / `flutter test` false）。
  @visibleForTesting
  static void reset() => enabled = !_isFlutterTest;
}
