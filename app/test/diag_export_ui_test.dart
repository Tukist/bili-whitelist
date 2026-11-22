// 「诊断日志 → 导出日志」入口（v2.67.0）· UI + 通道测试。
//
// 覆盖三件事：
// - **入口在**：个人页设置区（ManagePanel）里有 [kDiagExportButtonKey]，
//   小字里必须出现「已自动脱敏」（用户敢不敢发就看这一句），且非空白字符
//   ≤ 42（与 `kStreamCompatHint` 同一条既有约束）；
// - **点得动**：点一下真的打包出 zip 并调 `shareFile` 通道（参数：path /
//   mimeType / subject）；
// - **失败可读**：`ShareService.shareFile` 的三态（true / false / 异常）都
//   给一句人话，绝不抛到界面。
//
// 打包用临时目录当根目录（`DiagLog.rootDirOverride`），不碰 path_provider；
// 分享通道用 `setMockMethodCallHandler` 拦下来看参数。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/services/diag_log.dart';
import 'package:bili_whitelist_app/services/share_service.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

late Directory _tmp;
late DebugPrintCallback _originalDebugPrint;

/// 非空白字符数（设置页文案的长度口径）。
int _nonSpace(String s) => s.replaceAll(RegExp(r'\s'), '').length;

const MethodChannel _shareChannel = MethodChannel(kShareChannel);

Future<void> _pumpPanel(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ManagePanel(
          github: GithubApi(dio: Dio()),
          onManageCollections: () {},
          onCheckUpdate: () {},
          onLogin: () {},
        ),
      ),
    )),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _originalDebugPrint = debugPrint;
    _tmp = Directory.systemTemp.createTempSync('diag_export_test_');
    DiagLog.resetForTest();
    DiagLog.rootDirOverride = _tmp;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    DiagLog.resetForTest();
    debugPrint = _originalDebugPrint;
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用，忽略
    }
  });

  group('设置区入口', () {
    testWidgets('「诊断日志」小节在、导出按钮在、小字讲了「已自动脱敏」', (tester) async {
      await _pumpPanel(tester);

      expect(find.text('诊断日志'), findsOneWidget);
      expect(find.byKey(kDiagExportButtonKey), findsOneWidget);
      expect(find.text('导出日志'), findsOneWidget);
      expect(find.textContaining('已自动脱敏'), findsWidgets);
      expect(find.textContaining('发之前建议自己先看一眼'), findsWidgets);
    });

    test('小字非空白字符 ≤ 42（两行上限，与 kStreamCompatHint 同一条约束）', () {
      expect(_nonSpace(kDiagExportHint), lessThanOrEqualTo(42),
          reason: '当前 ${_nonSpace(kDiagExportHint)} 字');
      expect(kDiagExportHint, contains('已自动脱敏'));
      expect(kDiagExportHint, contains('token'));
      expect(kDiagExportHint, contains('手机号'));
    });
  });

  group('点「导出日志」', () {
    testWidgets('打包出 zip 并调 shareFile（path / mimeType / subject 都对）',
        (tester) async {
      // 先落一条日志，否则没有什么可打包
      DiagLog.recordError('zone', StateError('给导出用的一条'));

      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _shareChannel,
        (call) async {
          calls.add(call);
          return true;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, null));

      await _pumpPanel(tester);
      final button = find.byKey(kDiagExportButtonKey);
      await tester.ensureVisible(button);

      // 打包是真实文件 IO + zip 编码，fake async 时钟推不动 → 用 runAsync 放它跑
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      expect(calls.length, 1, reason: '一次点击只该有一次分享调用');
      expect(calls.single.method, 'shareFile');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect('${args['path']}', endsWith('.zip'));
      expect(File('${args['path']}').existsSync(), isTrue, reason: '真的打出来了');
      expect(args['mimeType'], 'application/zip');
      expect(args['subject'], isNotEmpty);
    });

    testWidgets('打包失败（没有日志）→ 一条可读 SnackBar，不调分享通道', (tester) async {
      var shareCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _shareChannel,
        (call) async {
          shareCalls++;
          return true;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, null));

      await _pumpPanel(tester);
      final button = find.byKey(kDiagExportButtonKey);
      await tester.ensureVisible(button);

      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(shareCalls, 0);
      expect(find.textContaining('导出失败'), findsOneWidget);
    });
  });

  group('ShareService.shareFile 三态', () {
    test('成功：通道参数原样传过去，返回 ok', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, (call) async {
        seen = call;
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, null));

      final result = await ShareService.shareFile(
        path: '/data/user/0/x/files/logs/export/diag-1.zip',
        mimeType: 'application/zip',
        subject: 'amoTV 诊断日志',
      );

      expect(result.ok, isTrue);
      expect(seen!.method, 'shareFile');
      final args = seen!.arguments as Map<Object?, Object?>;
      expect(args['path'], '/data/user/0/x/files/logs/export/diag-1.zip');
      expect(args['mimeType'], 'application/zip');
      expect(args['subject'], 'amoTV 诊断日志');
    });

    test('原生回 false（没有接收方）→ 可读文案', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, (call) async => false);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, null));

      final result = await ShareService.shareFile(
        path: '/x/diag.zip',
        mimeType: 'application/zip',
        subject: 's',
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('没有能接收该文件'));
    });

    test('原生抛 PlatformException → 文案带原因', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, (call) async {
        throw PlatformException(code: 'NOT_FOUND', message: '文件不存在：/x.zip');
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_shareChannel, null));

      final result = await ShareService.shareFile(
        path: '/x.zip',
        mimeType: 'application/zip',
        subject: 's',
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('文件不存在'));
    });

    test('通道缺失（MissingPluginException）→ 「当前环境不支持系统分享」', () async {
      final result = await ShareService.shareFile(
        path: '/x.zip',
        mimeType: 'application/zip',
        subject: 's',
      );
      expect(result.ok, isFalse);
      expect(result.message, '当前环境不支持系统分享');
    });

    test('空路径直接拒绝（不惊动原生）', () async {
      final result = await ShareService.shareFile(
        path: '  ',
        mimeType: 'application/zip',
        subject: 's',
      );
      expect(result.ok, isFalse);
      expect(result.message, '没有可分享的文件');
    });
  });
}
