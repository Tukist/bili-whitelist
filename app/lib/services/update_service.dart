/// 应用内版本更新服务（M1.1）。
///
/// 职责：
/// 1. 调 GitHub Releases API 拿最新版本（[fetchLatest]）。
/// 2. 节流 24h 后判断是否有更新（[check]）。
/// 3. 下载 APK 到 ApplicationSupport/updates（[download]），可选 SHA-256 校验。
///
/// 设计要点：
/// - 默认 dio 10s 超时（GitHub Releases 一般 < 2s）。
/// - 失败一律抛 [UpdateException]，message 直接给 UI 用，不回显原始 stack。
/// - 进度回调 [onProgress] 在 dio 的 onReceiveProgress 中转，参数已归一为 0~1。
/// - 单测可注入 fake dio + 真实 UpdateStorage（用 SharedPreferences mock）。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../models/update_info.dart';
import 'update_storage.dart';

class UpdateService {
  /// 启动检查的节流间隔（24h 内只查一次，除非 force=true）。
  static const Duration checkThrottle = Duration(hours: 24);

  /// GitHub Releases `/releases/latest` API endpoint。
  static const String kReleaseApi =
      'https://api.github.com/repos/Tukist/bili-whitelist/releases/latest';

  final Dio _dio;
  final UpdateStorage _storage;

  UpdateService({Dio? dio, required UpdateStorage storage})
    : _dio = dio ?? Dio(),
      _storage = storage;

  /// 拉最新 Release 元数据。失败抛 [UpdateException]。
  Future<UpdateInfo> fetchLatest() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        kReleaseApi,
        options: Options(
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'bili-whitelist-app',
          },
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      if (resp.statusCode != 200 || resp.data == null) {
        throw UpdateException('版本信息接口返回 ${resp.statusCode ?? 'unknown'}');
      }
      return UpdateInfo.fromGitHubReleaseJson(resp.data!);
    } on UpdateException {
      rethrow;
    } on DioException catch (e) {
      throw UpdateException(_mapDioError(e));
    } on FormatException catch (e) {
      throw UpdateException('版本信息格式异常：${e.message}');
    } catch (e) {
      throw UpdateException('检查更新失败：$e');
    }
  }

  /// 检查更新（节流版）。
  ///
  /// 返回 `null` 表示当前已是最新（或在节流窗口内已查过）。
  /// [force]=true 时跳过 24h 节流（用于「设置页手动检查」）。
  Future<UpdateInfo?> check({bool force = false}) async {
    final lastCheck = await _storage.readLastCheckAt();
    final now = DateTime.now();
    if (!force &&
        lastCheck != null &&
        now.difference(lastCheck) < checkThrottle) {
      return null;
    }
    final info = await fetchLatest();
    // 写节流戳（在比较之前写，确保节流命中失败也抑制重复请求）。
    await _storage.writeLastCheckAt(now);

    PackageInfo? pkg;
    try {
      pkg = await PackageInfo.fromPlatform();
    } catch (_) {
      // 测试环境无原生通道：跳过版本比对，返回 info 让 UI 自行决定。
      return info;
    }
    final currentCode = int.tryParse(pkg.buildNumber) ?? 0;
    if (!info.isNewerThan(pkg.version, currentCode)) {
      return null;
    }
    return info;
  }

  /// 下载 APK 到 ApplicationSupport/updates/app-update.apk。
  /// 返回本地路径。[onProgress] 回调参数 0.0~1.0。
  Future<String> download(
    UpdateInfo info, {
    void Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    final apk = File('${dir.path}/app-update.apk');
    if (await apk.exists()) await apk.delete();

    try {
      await _dio.download(
        info.apkUrl,
        apk.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
    } on DioException catch (e) {
      // 半成品清理
      if (await apk.exists()) {
        try {
          await apk.delete();
        } catch (_) {}
      }
      if (CancelToken.isCancel(e)) {
        throw UpdateException('下载已取消');
      }
      throw UpdateException(_mapDioError(e));
    } catch (e) {
      if (await apk.exists()) {
        try {
          await apk.delete();
        } catch (_) {}
      }
      throw UpdateException('下载失败：$e');
    }

    // SHA-256 流式校验（info.sha256 为 null 时跳过）
    if (info.sha256 != null) {
      try {
        final digest = await sha256.bind(apk.openRead()).first;
        final actual = digest.toString().toLowerCase();
        if (actual != info.sha256!.toLowerCase()) {
          await apk.delete();
          throw UpdateException('APK 完整性校验失败');
        }
      } on UpdateException {
        rethrow;
      } catch (e) {
        if (await apk.exists()) {
          try {
            await apk.delete();
          } catch (_) {}
        }
        throw UpdateException('APK 校验出错：$e');
      }
    }
    return apk.path;
  }

  String _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '网络超时，请检查连接后重试';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 403) return 'GitHub API 速率限制（403），稍后再试';
        if (code == 404) {
          return '暂时没有可用更新：可能还没有创建 GitHub Release，或版本仓库当前不可访问';
        }
        return '版本信息接口返回 $code';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络';
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return '网络异常：${e.message ?? '未知错误'}';
    }
  }
}
