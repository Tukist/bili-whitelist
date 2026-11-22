import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'diag_log.dart';

/// 全局异常捕获（v2.67.0）：把"红屏 / 闪退 / 静默失败"三种崩溃都变成
/// `logs/diag-*.log` 里的一条记录。
///
/// ## 四个入口，各管一段
///
/// | 入口 | 管什么 | 为什么非它不可 |
/// |------|--------|----------------|
/// | `runZonedGuarded`（main.dart） | Dart **异步**未处理异常（`unawaited` 的 future 抛了没人接） | 这类异常不经过 Flutter 的任何回调，只有 zone 能拦 |
/// | [FlutterError.onError] | 框架内异常（build / layout / paint 抛出的、`assert` 失败） | 框架内部 `catch` 后统一走这里；换掉它就等于拿到"红屏那一份"原文 |
/// | [PlatformDispatcher.onError] | 引擎回调里的未捕获异常 | 跑在 root zone 的引擎回调不经过自定义 zone，必须单独接 |
/// | [ErrorWidget.builder] | build 抛异常后那块"灰红块" | 只换 onError 的话用户还是看到默认红屏/灰块，这里换成一句人话 |
///
/// ## 为什么崩溃路径必须**同步**落盘
///
/// 异常之后进程随时可能被系统杀掉（原生侧 handler 也是拿到异常就转给系统），
/// 异步 flush 的 Timer 很可能排不上队。所以三个入口都走
/// `DiagLog.recordError(...)`，它内部 `flushSync()` —— 写完这一条才往下走。
///
/// ## ErrorWidget 为什么要按错误摘要去重
///
/// 一个 build 抛异常，父级可能每帧重建一次那块子树 → 同一个错误一秒能记几十
/// 条，把 512KB 滚完、把真正的第一条挤掉。按"异常文本摘要"去重后，同一错误
/// **只记 1 条**（界面上的错误卡每次照常渲染，去重只作用于日志）。
class CrashGuard {
  CrashGuard._();

  static bool _installed = false;

  /// 已经记过的 ErrorWidget 错误摘要（去重用）。
  static final Set<String> _seenWidgetErrors = <String>{};

  /// ErrorWidget 路径累计**落盘**的条数（测试用：应为去重后的数量）。
  @visibleForTesting
  static int widgetErrorReports = 0;

  /// 装好三个 Dart 侧入口。重复调用直接返回（测试可能重复初始化）。
  ///
  /// ⚠️ 与 [DiagLog.install] 一样，只由 `main()` 调用 —— 测试里换掉
  /// `FlutterError.onError` 来断言异常的用例（flutter_test 自己就换了一套）
  /// 不能被这里覆盖。
  static void install() {
    if (_installed) return;
    _installed = true;

    // 先 presentError：debug 下的红屏/控制台堆栈照旧（这是日常开发最趁手的
    // 一份信息），再同步落盘一份给用户导出。
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      DiagLog.recordError(
        'flutter',
        details.exception,
        stack: details.stack,
      );
    };

    // 引擎回调里的异常：落盘后返回 true（表示已处理，引擎不再往 zone 抛）。
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      DiagLog.recordError('engine', error, stack: stack);
      return true;
    };

    ErrorWidget.builder = buildErrorWidget;
  }

  /// 替换掉默认 ErrorWidget（v2.67.0）：一句人话 + 按错误摘要去重记一条日志。
  ///
  /// 卡片刻意做得极简（不依赖 Material / Theme / MediaQuery）：它出现的时候
  /// 恰恰可能是整棵树都建不起来的时候，任何"顺手拿个 Theme"都可能二次抛异常。
  static Widget buildErrorWidget(FlutterErrorDetails details) {
    final summary = _summaryOf(details);
    if (_seenWidgetErrors.add(summary)) {
      widgetErrorReports++;
      DiagLog.recordError(
        'widget',
        details.exception,
        stack: details.stack,
      );
    }
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xFF202020),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '这块内容加载出错（已记录到诊断日志）',
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFE0E0E0), fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  /// 测试用：恢复初始态（允许再次 install / 重新统计）。
  @visibleForTesting
  static void resetForTest() {
    _installed = false;
    _seenWidgetErrors.clear();
    widgetErrorReports = 0;
  }

  /// 错误摘要：异常文本前 120 字（同一异常重复抛出的文本一致，够去重了）。
  static String _summaryOf(FlutterErrorDetails details) {
    var text = details.exceptionAsString();
    if (text.length > 120) text = text.substring(0, 120);
    return text;
  }
}
