// 全局异常捕获（v2.67.0）· 单元测试。
//
// 崩溃入口有四个，测试各钉一条（入口本身装在 main() 里，这里直接调装好的
// 那套回调，等价于"运行时真的被调用"）：
//
// - `FlutterError.onError`：先 presentError（红屏/控制台）再**同步**落盘；
// - `PlatformDispatcher.onError`：落盘并返回 true（引擎不再往 zone 抛）；
// - `runZonedGuarded`：Dart 异步未处理异常（入口在 main.dart，回调是
//   `DiagLog.recordError('zone', ...)` —— 这里用同样的组合验证）；
// - `ErrorWidget.builder`：极简错误卡 + 按错误摘要去重（防 build 风暴）。
//
// 用临时目录当根目录（`DiagLog.rootDirOverride`），不依赖 path_provider。
// 全局静态（FlutterError.onError / ErrorWidget.builder / PlatformDispatcher
// .onError）在每个用例后恢复，避免污染同进程里的其它用例。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/crash_guard.dart';
import 'package:bili_whitelist_app/services/diag_log.dart';

late Directory _tmp;
late DebugPrintCallback _originalDebugPrint;
late FlutterExceptionHandler? _originalOnError;
late ErrorWidgetBuilder _originalErrorWidgetBuilder;
late bool Function(Object error, StackTrace stack)? _originalPlatformOnError;

String _allLogText() {
  final dir = Directory('${_tmp.path}/logs');
  if (!dir.existsSync()) return '';
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.log'))
      .map((f) => f.readAsStringSync())
      .join('\n');
}

int _countOf(String needle) => needle.allMatches(_allLogText()).length;

FlutterErrorDetails _details(Object error) => FlutterErrorDetails(
      exception: error,
      stack: StackTrace.fromString('#0      boom (package:x/a.dart:9:9)'),
      library: 'test',
    );

void main() {
  setUp(() async {
    _originalDebugPrint = debugPrint;
    _originalOnError = FlutterError.onError;
    _originalErrorWidgetBuilder = ErrorWidget.builder;
    _originalPlatformOnError = PlatformDispatcher.instance.onError;

    _tmp = Directory.systemTemp.createTempSync('crash_guard_test_');
    DiagLog.resetForTest();
    CrashGuard.resetForTest();
    DiagLog.rootDirOverride = _tmp;
    // 故意**不调 DiagLog.install()**：widget 用例收尾时 flutter_test 会断言
    // `debugPrint` 已恢复默认（debugAssertAllFoundationVarsUnset），install 换掉
    // 的全局实现会让每条 testWidgets 都挂掉。`recordError` 只需要注入根目录，
    // 不依赖接管 debugPrint。
  });

  tearDown(() {
    CrashGuard.resetForTest();
    DiagLog.resetForTest();
    FlutterError.onError = _originalOnError;
    ErrorWidget.builder = _originalErrorWidgetBuilder;
    PlatformDispatcher.instance.onError = _originalPlatformOnError;
    debugPrint = _originalDebugPrint;
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用，忽略
    }
  });

  test('FlutterError.onError：同步落盘一条 [crash:flutter]', () {
    CrashGuard.install();
    FlutterError.onError!(_details(StateError('框架里炸了')));

    // 不需要额外 flush：入口内部已经是 flushSync
    expect(_countOf('[crash:flutter]'), 1);
    expect(_allLogText(), contains('框架里炸了'));
    expect(_allLogText(), contains('a.dart:9:9'), reason: '堆栈要一起落盘');
  });

  test('PlatformDispatcher.onError：落盘并返回 true', () {
    CrashGuard.install();
    final handled = PlatformDispatcher.instance.onError!(
      StateError('引擎里炸了'),
      StackTrace.fromString('#0      boom'),
    );
    expect(handled, isTrue, reason: '返回 true = 已处理，引擎不再往 zone 抛');
    expect(_countOf('[crash:engine]'), 1);
    expect(_allLogText(), contains('引擎里炸了'));
  });

  test('runZonedGuarded：Dart 异步未处理异常被兜住并落盘', () async {
    // 与 main.dart 完全同一条组合：守护 zone + recordError('zone', ...)
    final done = Completer<void>();
    runZonedGuarded(
      () async {
        Future<void>.error(StateError('异步炸了，没人接'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        done.complete();
      },
      (error, stack) {
        DiagLog.recordError('zone', error, stack: stack);
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future;

    expect(_countOf('[crash:zone]'), 1);
    expect(_allLogText(), contains('异步炸了，没人接'));
  });

  test('ErrorWidget.builder：同一错误 build 多次只记 1 条', () {
    CrashGuard.install();
    final details = _details(StateError('同一处 build 崩了'));

    CrashGuard.buildErrorWidget(details);
    CrashGuard.buildErrorWidget(details);
    CrashGuard.buildErrorWidget(details);

    expect(CrashGuard.widgetErrorReports, 1);
    expect(_countOf('[crash:widget]'), 1);
    expect(_allLogText(), contains('同一处 build 崩了'));
  });

  test('ErrorWidget.builder：不同错误各记 1 条', () {
    CrashGuard.install();
    CrashGuard.buildErrorWidget(_details(StateError('第一个')));
    CrashGuard.buildErrorWidget(_details(StateError('第二个')));
    expect(CrashGuard.widgetErrorReports, 2);
    expect(_countOf('[crash:widget]'), 2);
  });

  testWidgets('ErrorWidget.builder 产物能在没有任何 Material 祖先时渲染', (tester) async {
    // 这里**故意不 install**：flutter_test 要求用例自己恢复 `FlutterError
    // .onError`，而 install 会换成我们的实现（widget 用例里换全局 onError 会
    // 让 binding 在收尾时判定"测试没恢复原状"）。错误卡本身不依赖 install。
    await tester.pumpWidget(CrashGuard.buildErrorWidget(_details(StateError('x'))));
    expect(find.text('这块内容加载出错（已记录到诊断日志）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('install 幂等：重复调用不重复记账', () {
    CrashGuard.install();
    final installedOnError = FlutterError.onError;
    CrashGuard.install();
    expect(FlutterError.onError, same(installedOnError));
    expect(ErrorWidget.builder, same(CrashGuard.buildErrorWidget));
  });
}
