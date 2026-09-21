// UpdateDialog 首次覆盖（v2.46.0）。
//
// 为什么这个文件直到现在才出现：UpdateDialog 一直零测试，而用户报的
// 「下载到一半出现未知错误」正是它把**下载**与**安装**塞进同一个 try 造成的
// （安装被系统拦下 → 显示「下载失败：未知错误」）。这里把归因、复用、
// 权限引导三条路径钉住，断言全部落在**用户看得见的东西**上（文案、按钮、
// 真实的调用次数）。
//
// 设计取舍：
// - 用替身（_FakeService / _FakeInstaller）控制下载与安装的成败，全部断言落在
//   可观测的结果上（文案、按钮、真实的调用次数）。
// - 为什么下载失败那条不用「真 UpdateService + 假 dio」：`testWidgets` 跑在
//   FakeAsync 里，真 service 的**文件 I/O + dio** 在假时钟下推不动（实测会挂到
//   超时）。所以这里验证的是「下载阶段抛出的 UpdateException 原样展示、归因是
//   下载」；而「404 → 下载地址已失效（HTTP 404）」这条映射由
//   test/update_service_test.dart 用真 service + 假 adapter 钉住。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/update_info.dart';
import 'package:bili_whitelist_app/pages/update_dialog.dart';
import 'package:bili_whitelist_app/services/apk_installer.dart';
import 'package:bili_whitelist_app/services/update_service.dart';
import 'package:bili_whitelist_app/services/update_storage.dart';

/// UpdateService 替身：只覆盖 dialog 用到的两个口（download / existingApk）。
class _FakeService extends UpdateService {
  _FakeService(SharedPreferences prefs) : super(storage: UpdateStorage(prefs));

  int downloadCalls = 0;
  int existingApkCalls = 0;

  /// 已下好且可复用的 APK 路径（null = 没有 → 走下载）。
  String? reusablePath;

  /// 下载抛出的异常（null = 成功返回 [downloadPath]）。
  Object? downloadThrows;

  /// 下载成功后「落盘」的路径。
  String downloadPath = '/data/user/0/app/updates/app-update-38.apk';

  @override
  Future<String?> existingApk(UpdateInfo info) async {
    existingApkCalls += 1;
    return reusablePath;
  }

  @override
  Future<String> download(
    UpdateInfo info, {
    void Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    downloadCalls += 1;
    onProgress?.call(1.0);
    final err = downloadThrows;
    if (err != null) throw err;
    return downloadPath;
  }
}

/// ApkInstallerChannel 替身：记录 install / 跳设置调用次数，可控制权限与失败。
class _FakeInstaller extends ApkInstallerChannel {
  bool allowed = true;
  Object? installThrows;

  /// 权限查询本身抛异常（模拟老原生没实现 canInstallUnknownApps）。
  Object? permissionThrows;
  final List<String> installPaths = [];
  int settingsCalls = 0;
  int permissionChecks = 0;

  @override
  Future<bool> canInstallUnknownApps() async {
    permissionChecks += 1;
    final err = permissionThrows;
    if (err != null) throw err;
    return allowed;
  }

  @override
  Future<void> install(String path) async {
    installPaths.add(path);
    final err = installThrows;
    if (err != null) throw err;
  }

  @override
  Future<void> openUnknownSourcesSettings() async {
    settingsCalls += 1;
  }
}

/// 固定状态码的假 adapter 已不需要（见文件头「设计取舍」）——下载阶段的文案映射
/// 由 test/update_service_test.dart 覆盖。
Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

UpdateInfo _info() => const UpdateInfo(
      version: '2.46.0',
      code: 38,
      apkUrl: 'https://example.com/app.apk',
      size: 100,
    );

/// 弹窗打开 → 点「立即更新」→ 等状态机落定。
Future<void> _openAndTapUpdate(
  WidgetTester tester, {
  required UpdateService service,
  required ApkInstallerChannel installer,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => UpdateDialog(
                info: _info(),
                service: service,
                installer: installer,
              ),
            ),
            child: const Text('打开更新弹窗'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开更新弹窗'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('立即更新'));
  await tester.pumpAndSettle();
}

void main() {
  group('A 归因分离：下载失败 ≠ 安装失败', () {
    testWidgets('①安装阶段失败 → 显示「安装失败」+ 原生原因，绝不谎报成「下载失败」',
        (tester) async {
      final service = _FakeService(await _prefs());
      final installer = _FakeInstaller()
        ..installThrows = PlatformException(
          code: 'INSTALL_FAILED',
          message: 'ActivityNotFoundException: No Activity found to handle Intent',
        );

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(service.downloadCalls, 1, reason: '安装阶段失败之前确实下载过一次');
      expect(installer.permissionChecks, 1, reason: '安装前必须先查「安装未知应用」权限');
      expect(installer.installPaths, [service.downloadPath]);
      // 用户可见文案：归因是「安装」，且原生原因原样透出
      expect(find.textContaining('安装失败：'), findsOneWidget);
      expect(
        find.textContaining('ActivityNotFoundException: No Activity found'),
        findsOneWidget,
      );
      // 归因不许错位：既没有「下载失败」字样，也没有「未知错误」裸文案
      expect(find.textContaining('下载失败'), findsNothing);
      expect(find.textContaining('未知错误'), findsNothing);
      // 安装阶段的按钮语义
      expect(find.text('重试安装'), findsOneWidget);
      expect(find.text('重新下载'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('②下载阶段失败（HTTP 404 文案）→ 归因「下载」，不进安装', (tester) async {
      // 文案与真 service 的 _mapDioError(404, forDownload: true) 逐字一致
      // （映射本身见 update_service_test.dart 的「HTTP 404」用例）。
      final service = _FakeService(await _prefs())
        ..downloadThrows =
            const UpdateException('下载地址已失效（HTTP 404），请重新检查更新');
      final installer = _FakeInstaller();

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(find.textContaining('404'), findsOneWidget);
      expect(find.textContaining('安装失败'), findsNothing);
      expect(find.textContaining('未知错误'), findsNothing);
      // 下载阶段：只给「重试」，且压根没碰安装通道
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('重试安装'), findsNothing);
      expect(find.text('重新下载'), findsNothing);
      expect(installer.installPaths, isEmpty);
      expect(installer.permissionChecks, 0);
    });

    testWidgets('②下载阶段抛非 UpdateException → 兜底文案仍是「下载失败」',
        (tester) async {
      final service = _FakeService(await _prefs())
        ..downloadThrows = StateError('boom');
      final installer = _FakeInstaller();

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(find.textContaining('下载失败：'), findsOneWidget);
      expect(find.textContaining('安装失败'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      expect(installer.installPaths, isEmpty);
    });
  });

  group('C 已下好的 APK 不再重下', () {
    testWidgets('④已有合格安装包 → 点「立即更新」直接安装，完全不调 download()',
        (tester) async {
      final service = _FakeService(await _prefs())
        ..reusablePath = '/data/user/0/app/updates/app-update-38.apk';
      final installer = _FakeInstaller();

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(service.existingApkCalls, 1);
      expect(service.downloadCalls, 0, reason: '文件已经在磁盘上，不该再下一次');
      expect(installer.installPaths, [service.reusablePath]);
      // 安装成功 → 弹窗自动关闭
      expect(find.text('立即更新'), findsNothing);
    });

    testWidgets('④安装失败后点「重试安装」→ 只重发安装 Intent，download() 次数不变',
        (tester) async {
      final service = _FakeService(await _prefs());
      final installer = _FakeInstaller()
        ..installThrows = PlatformException(
          code: 'INSTALL_FAILED',
          message: 'INSTALL_PARSE_FAILED_NO_CERTIFICATES',
        );

      await _openAndTapUpdate(tester, service: service, installer: installer);
      expect(service.downloadCalls, 1);

      // 第一次安装失败后手上就有完整安装包（service 侧能复用）
      service.reusablePath = service.downloadPath;
      await tester.tap(find.text('重试安装'));
      await tester.pumpAndSettle();

      expect(service.downloadCalls, 1, reason: '重试安装不该重新下载 68MB');
      expect(installer.installPaths, hasLength(2));
      expect(installer.installPaths.last, service.downloadPath);
      expect(find.textContaining('安装失败：INSTALL_PARSE_FAILED'), findsOneWidget);
    });

    testWidgets('④安装失败后点「重新下载」→ 绕过复用，真的重下（用户主动路径）',
        (tester) async {
      final service = _FakeService(await _prefs())
        ..reusablePath = '/data/user/0/app/updates/app-update-38.apk';
      final installer = _FakeInstaller()
        ..installThrows = PlatformException(code: 'INSTALL_FAILED', message: 'boom');

      await _openAndTapUpdate(tester, service: service, installer: installer);
      expect(service.downloadCalls, 0, reason: '首轮走的复用路径');
      expect(service.existingApkCalls, 1);

      await tester.tap(find.text('重新下载'));
      await tester.pumpAndSettle();

      expect(service.downloadCalls, 1, reason: '「重新下载」必须真的重下');
      expect(
        service.existingApkCalls,
        1,
        reason: '强制重下时不问复用（否则又会拿回同一份旧文件）',
      );
    });

    testWidgets('④「重新下载」失败后再点「重试」仍继续重下，不复用旧文件',
        (tester) async {
      final service = _FakeService(await _prefs())
        ..reusablePath = '/data/user/0/app/updates/app-update-38.apk'
        ..downloadThrows = const UpdateException('网络中断，下载未完成，请检查网络后重试');
      final installer = _FakeInstaller()
        ..installThrows = PlatformException(code: 'INSTALL_FAILED', message: 'boom');

      await _openAndTapUpdate(tester, service: service, installer: installer);
      await tester.tap(find.text('重新下载'));
      await tester.pumpAndSettle();
      expect(service.downloadCalls, 1);
      expect(find.textContaining('网络中断'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(service.downloadCalls, 2, reason: '重下失败后的重试应继续重下');
      expect(service.existingApkCalls, 1, reason: '不该回头复用那份旧文件');
    });
  });

  group('D 「安装未知应用」权限前置检查 + 引导', () {
    testWidgets('③权限未开启 → 给引导文案 + 「去开启」跳设置，且不调用 install',
        (tester) async {
      final service = _FakeService(await _prefs())
        ..reusablePath = '/data/user/0/app/updates/app-update-38.apk';
      final installer = _FakeInstaller()..allowed = false;

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(installer.permissionChecks, 1);
      expect(installer.installPaths, isEmpty, reason: '权限没开就别去撞系统安装器');
      // 文案说清「要开哪个开关」
      expect(find.textContaining('安装未知应用'), findsWidgets);
      expect(find.textContaining('重试安装'), findsWidgets);
      expect(find.text('去开启'), findsOneWidget);
      // 权限问题不给「重新下载」（该做的是去开开关）
      expect(find.text('重新下载'), findsNothing);

      await tester.tap(find.text('去开启'));
      await tester.pumpAndSettle();
      expect(installer.settingsCalls, 1, reason: '点「去开启」要真的跳设置页');
      expect(tester.takeException(), isNull);
    });

    testWidgets('③原生以 NEED_UNKNOWN_SOURCES 拒绝 —— 兜底也给同一套引导',
        (tester) async {
      final service = _FakeService(await _prefs());
      final installer = _FakeInstaller()
        ..installThrows = PlatformException(
          code: kNeedUnknownSourcesCode,
          message: '未开启「安装未知应用」权限',
        );

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(find.textContaining('安装未知应用'), findsWidgets);
      expect(find.text('去开启'), findsOneWidget);
      expect(find.textContaining('未知错误'), findsNothing);
    });

    testWidgets('③权限查询本身失败（老原生 / 无通道）→ 不堵死安装，照常调用 install',
        (tester) async {
      final service = _FakeService(await _prefs())
        ..reusablePath = '/data/user/0/app/updates/app-update-38.apk';
      final installer = _FakeInstaller()
        ..permissionThrows = MissingPluginException('旧包没有这个方法');

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(installer.permissionChecks, 1);
      expect(installer.installPaths, hasLength(1),
          reason: '查不到权限 ≠ 没权限：把用户堵在门外比让系统自己拦更糟');
      expect(find.text('立即更新'), findsNothing, reason: '照常走完安装流程（弹窗关闭）');
    });

    testWidgets('③安装通道未注册（老包）→ 给可读原因，而不是「未知错误」', (tester) async {
      final service = _FakeService(await _prefs())
        ..reusablePath = '/data/user/0/app/updates/app-update-38.apk';
      final installer = _FakeInstaller()
        ..installThrows = MissingPluginException('no impl');

      await _openAndTapUpdate(tester, service: service, installer: installer);

      expect(installer.installPaths, hasLength(1));
      expect(find.textContaining('安装失败：当前系统未注册安装通道'), findsOneWidget);
      expect(find.textContaining('未知错误'), findsNothing);
    });
  });
}
