/// 应用内版本更新服务（M1.1）。
///
/// 职责：
/// 1. 调 GitHub Releases API 拿最新版本（[fetchLatest]）。
/// 2. 节流 24h 后判断是否有更新（[check]）。
/// 3. 下载 APK 到 ApplicationSupport/updates（[download]）：断点续传 +
///    网络错误自动重试 + 可选 SHA-256 校验。
///
/// 断点续传设计（v2.16.8）：
/// - 下载目标为半成品 `app-update-<code>.apk.part`；`.part` 已存在时按其大小
///   带 `Range: bytes=<startBytes>-` 续传（文件名带 versionCode，避免换版本后
///   把旧版本的半成品续接到新 APK 上拼出损坏文件）。
/// - 服务器返回 206 → 从断点追加写入；200（服务器不支持 Range）→ 全量重写
///   （截断 .part 从 0 开始）。GitHub Release 资产实测支持 206 分段。
/// - 跳转手动跟随（[dio] 自动跳转不保证转发自定义头）：`browser_download_url`
///   的 302 → 签名 CDN 每一跳都带 Range，保证命中 CDN 时仍能续传。
/// - 下载完成（HTTP 2xx + 流写完）→ `.part` 改名最终 APK
///   `app-update-<code>.apk`。
/// - **失败 / 取消都保留 `.part`**（不删半成品），下次点击「重试/立即更新」
///   自动从断点继续；取消≠网络失败，保留进度合理。
/// - 自动重试：瞬时网络错误（超时/连接失败/网络中断）默认共 3 次尝试
///   （初始 1 + 重试 2），指数退避 1s→2s，每次重试从断点继续；HTTP 业务错误
///   （403/404 等）与用户取消不重试。
/// - SHA-256：校验整个文件（[UpdateInfo.sha256] 非 null 时）；失败删除文件
///   抛「完整性校验失败」（半成品数据可疑，不值得续传）。
///
/// 其余设计要点：
/// - 仓库当前是**私有**的：Release 元数据与资产下载都要带 GitHub token
///   （[tokenProvider]，主页接管理页已存的 token）；无 token 时按公开仓库
///   匿名请求，向后兼容。
/// - 私有仓库资产下载走「资产 API 地址 → 302 签名 CDN 地址」两段式，鉴权头
///   不随跳转转发（见 [resolveDownloadUrl]）。
/// - 失败一律抛 [UpdateException]，message 直接给 UI 用；网络错误按类型给
///   友好中文提示，**不直出底层原始英文**（不再出现「未知错误」裸文案）。
/// - 进度回调 [onProgress] 已归一为 0~1，续传时分子/分母都并入起始字节基数
///   （分母优先 [UpdateInfo.size] → Content-Range 全量 → Content-Length+基数，
///   均不可知时不回调，UI 转不定态进度条）。
/// - 单测可注入 fake dio + rootDirOverride（临时目录）+ 真实 UpdateStorage。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// 读取 GitHub token（可选）。私有仓库的 Release 元数据与资产下载都要鉴权；
  /// 由调用方注入（主页接的是 GitHub 配置里已存的 token）。返回 null/空 →
  /// 按公开仓库匿名请求（向后兼容）。
  final Future<String?> Function()? _tokenProvider;

  /// 下载根目录覆盖（测试注入临时目录；null → path_provider 应用支持目录）。
  final Directory? _rootDirOverride;

  /// 一次 [download] 最多尝试次数（初始 1 + 自动重试 N-1 次；网络瞬时错误才重试）。
  final int maxDownloadAttempts;

  /// 重试退避基准时长：第 n 次重试前等待 `基准 × 2^(n-1)`（默认 1s→2s）。
  final Duration retryBaseDelay;

  UpdateService({
    Dio? dio,
    required UpdateStorage storage,
    Future<String?> Function()? tokenProvider,
    @visibleForTesting Directory? rootDirOverride,
    this.maxDownloadAttempts = 3,
    this.retryBaseDelay = const Duration(seconds: 1),
  }) : _dio = dio ?? Dio(),
       _storage = storage,
       _tokenProvider = tokenProvider,
       _rootDirOverride = rootDirOverride;

  /// 下载根目录：测试注入优先，否则 path_provider 应用支持目录。
  Future<Directory> _rootDir() async {
    final override = _rootDirOverride;
    return override ?? await getApplicationSupportDirectory();
  }

  /// 读 token 并归一化：空白 → null。provider 抛异常视为无 token（不阻塞检查）。
  Future<String?> _readToken() async {
    final provider = _tokenProvider;
    if (provider == null) return null;
    try {
      final t = (await provider())?.trim() ?? '';
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  /// 拉最新 Release 元数据。失败抛 [UpdateException]。
  Future<UpdateInfo> fetchLatest() async {
    try {
      final token = await _readToken();
      final resp = await _dio.get<Map<String, dynamic>>(
        kReleaseApi,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'bili-whitelist-app',
            if (token != null) 'Authorization': 'Bearer $token',
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
      throw UpdateException(await _mapFetchError(e));
    } on FormatException catch (e) {
      throw UpdateException('版本信息格式异常：${e.message}');
    } catch (e) {
      throw UpdateException('检查更新失败：$e');
    }
  }

  /// 把「拉最新 Release 元数据」时的异常转成用户可读提示。
  ///
  /// 404 分两种（其余走 [_mapDioError] 通用文案）：
  /// - 未配 token：私有仓库的 `releases/latest` 匿名访问必然 404（GitHub
  ///   不暴露私有仓库存在性）→ 提示先去管理面板配 token。
  /// - 已配 token 仍 404：token 有效但仓库还没有 Release → 提示暂无发布。
  Future<String> _mapFetchError(DioException e) async {
    final code = e.response?.statusCode;
    if (code == 404) {
      final token = await _readToken();
      return token == null
          ? '检查更新失败：请先在管理面板配置 GitHub token（私有仓库需要）'
          : '已是最新：仓库暂无 Release（没有比当前更新的发布版本）';
    }
    return _mapDioError(e);
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

  /// 解析真实下载地址。
  ///
  /// - 无 token / 无资产 API 地址（公开仓库）：直接返回 [UpdateInfo.apkUrl]。
  /// - 私有仓库：带 token 请求资产 API 地址（`Accept: application/octet-stream`），
  ///   GitHub 返回 302 跳转到签名 CDN 地址。**必须手动跳这一次**：若让 dio 自动
  ///   跟随跳转，Authorization 头会被转发到 CDN，S3 会因"双重鉴权"直接报 400。
  ///
  /// 公开出来是为了单测可注入 fake adapter 覆盖私有仓库跳转逻辑。
  Future<String> resolveDownloadUrl(UpdateInfo info) async {
    final token = await _readToken();
    final apiUrl = info.apkApiUrl;
    if (token == null || apiUrl == null || apiUrl.isEmpty) {
      return info.apkUrl;
    }
    Response<ResponseBody>? resp;
    try {
      resp = await _dio.get<ResponseBody>(
        apiUrl,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (s) => s != null && s < 400,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/octet-stream',
            'User-Agent': 'bili-whitelist-app',
          },
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = resp.headers.value('location') ?? '';
        if (location.isEmpty) {
          throw const UpdateException('APK 下载地址跳转失败（缺少 location）');
        }
        return location;
      }
      // 200（GitHub 直连流式回包）等情形没有跳转地址，私有仓库下
      // browser_download_url 匿名访问必然 404，直接失败比下错文件好。
      throw UpdateException('APK 下载地址获取失败（HTTP $status）');
    } on UpdateException {
      rethrow;
    } on DioException catch (e) {
      throw UpdateException(_mapDioError(e));
    } finally {
      // 排掉 302 的空响应体，释放连接。
      try {
        await resp?.data?.stream.drain<void>();
      } catch (_) {}
    }
  }

  /// 下载 APK 到 ApplicationSupport/updates/app-update-<code>.apk。
  /// 返回本地路径。[onProgress] 回调参数 0.0~1.0。
  ///
  /// 断点续传：下载写 `.part`，完成改名；失败/取消保留 `.part`。瞬时网络
  /// 错误自动重试（从断点继续），HTTP 业务错误与用户取消不重试。
  Future<String> download(
    UpdateInfo info, {
    void Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = Directory('${(await _rootDir()).path}/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    // 文件名带 versionCode：换版本后旧版半成品不会续接到新 APK（避免拼出
    // 损坏文件且无法恢复）。新下载开始时顺带清掉其它版本号的残留。
    final apkName = 'app-update-${info.code}.apk';
    final apk = File('${dir.path}/$apkName');
    final part = File('${dir.path}/$apkName.part');
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('app-update-') &&
            name != apkName &&
            name != '$apkName.part') {
          await entity.delete();
        }
      }
    } catch (_) {
      // 清理旧版本残留失败不阻塞下载
    }

    // 私有仓库先解析真实下载地址；后续下载请求不带鉴权头（302 → 签名 CDN）。
    final url = await resolveDownloadUrl(info);

    // 自动重试循环：只对瞬时网络错误重试；重试前重读 .part 大小从断点继续。
    var startBytes = await _partStartBytes(part);
    var attemptsLeft = maxDownloadAttempts;
    var backoffMs = retryBaseDelay.inMilliseconds;
    while (true) {
      try {
        await _downloadAttempt(
          url: url,
          part: part,
          startBytes: startBytes,
          info: info,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        break; // 流写完（HTTP 2xx）
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          // 用户取消：保留 .part（下次点击更新/重试自动续传）。
          throw const UpdateException('下载已取消（进度已保留，下次将自动续传）');
        }
        attemptsLeft -= 1;
        if (attemptsLeft <= 0 || !_isTransientDownloadError(e)) {
          throw UpdateException(_mapDioError(e, forDownload: true));
        }
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
        backoffMs *= 2;
        startBytes = await _partStartBytes(part);
      } on UpdateException {
        rethrow; // 业务错误（HTTP 403/404、跳转失败、416 等）不重试
      } catch (e) {
        // 兜底：非 dio 意外错误也重试到次数上限再抛出（.part 保留可续传）。
        attemptsLeft -= 1;
        if (attemptsLeft <= 0) throw UpdateException('下载失败：$e');
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
        backoffMs *= 2;
        startBytes = await _partStartBytes(part);
      }
    }

    // 流写完 → .part 改名最终 APK（rename 目标已存在会先替换）。
    try {
      await part.rename(apk.path);
    } catch (e) {
      throw UpdateException('下载完成但保存文件失败：$e');
    }

    // SHA-256 流式校验整个文件（info.sha256 为 null 时跳过）。
    // 校验失败删文件抛错：数据可疑（网络损坏/拼接错位）不值得续传，全量重下。
    if (info.sha256 != null) {
      try {
        final digest = await sha256.bind(apk.openRead()).first;
        final actual = digest.toString().toLowerCase();
        if (actual != info.sha256!.toLowerCase()) {
          await apk.delete();
          throw const UpdateException('APK 完整性校验失败');
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

  /// 读 .part 已有字节数作为续传起点。文件不存在/读损坏按 0（全量重下）。
  Future<int> _partStartBytes(File part) async {
    try {
      if (await part.exists()) return await part.length();
    } catch (_) {}
    return 0;
  }

  /// 单次下载尝试：跟随跳转 → 拿 200/206 响应 → 写 `.part` 直到流结束。
  ///
  /// - 206：从 [startBytes] 断点追加写入（.part 保留原内容）。
  /// - 200：服务器不支持 Range → 全量重写（截断 .part，进度基数归 0）。
  /// - 失败（流中断/写盘错误）：关闭文件、**保留已写入部分**，抛异常交给
  ///   外层决定重试或上报。
  Future<void> _downloadAttempt({
    required String url,
    required File part,
    required int startBytes,
    required UpdateInfo info,
    required void Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await _followRedirectsToResponse(url, startBytes, cancelToken);
    final status = resp.statusCode ?? 0;

    // Range 被拒绝（416，仅续传时可能出现，如 .part 比远端还大）：清掉
    // 半成品提示用户重试（下次自动全量重下）。
    if (status == 416) {
      try {
        await part.delete();
      } catch (_) {}
      throw const UpdateException('续传位置无效（HTTP 416），已清除半成品，请重试');
    }
    if (status != 200 && status != 206) {
      throw UpdateException('下载失败（HTTP $status）');
    }

    final isResume = status == 206; // 200 → base=0 全量重写
    final base = isResume ? startBytes : 0;
    final responseTotal = _responseTotal(resp);
    final fullTotal = _fullTotal(
      knownSize: info.size,
      contentRange: resp.headers.value('content-range'),
      base: base,
      responseTotal: responseTotal,
    );
    final body = resp.data;
    if (body == null) {
      throw const UpdateException('下载响应为空，请重试');
    }

    // 续传追加 vs 全量截断；写盘期间始终持锁，退出/失败才关闭（保留 .part）。
    final raf = part.openSync(mode: isResume ? FileMode.append : FileMode.write);
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        if (cancelToken?.isCancelled ?? false) {
          throw cancelToken!.cancelError!; // 用户取消：抛 cancel → 保留 .part
        }
        await raf.writeFrom(chunk);
        received += chunk.length;
        _notifyProgress(onProgress, base, received, fullTotal);
      }
    } catch (e) {
      // 取消时 dio 会 abort 底层请求，流中断先判取消再分类。
      if (cancelToken?.isCancelled ?? false) {
        throw cancelToken!.cancelError!;
      }
      if (e is DioException) rethrow;
      // 断网 / 连接重置 / 接收中断 → 包装为 unknown 供外层分类 + 重试。
      throw DioException(
        requestOptions: resp.requestOptions,
        type: DioExceptionType.unknown,
        error: e,
      );
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  /// 手动跟随 3xx 跳转直到拿到最终响应（200/206/416 或抛出）。
  ///
  /// 不依赖 dio 自动跳转：dio 把跳转交给底层 HttpClient，不保证转发自定义头，
  /// 而续传的 `Range` 头必须到达签名 CDN 那跳才能命中 206。
  Future<Response<ResponseBody>> _followRedirectsToResponse(
    String url,
    int startBytes,
    CancelToken? cancelToken,
  ) async {
    var current = url;
    for (var hop = 0; hop < 8; hop++) {
      final resp = await _dio.get<ResponseBody>(
        current,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          // 4xx/5xx 交给 dio 抛 badResponse；3xx 与 2xx 由本方法处理。
          validateStatus: (s) => s != null && s < 400,
          headers: {
            if (startBytes > 0) 'Range': 'bytes=$startBytes-',
          },
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
        cancelToken: cancelToken,
      );
      final status = resp.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = resp.headers.value('location') ?? '';
        // 排空跳转响应的空响应体，释放连接。
        try {
          await resp.data?.stream.drain<void>();
        } catch (_) {}
        if (location.isEmpty) {
          throw const UpdateException('APK 下载地址跳转失败（缺少 location）');
        }
        current = location.startsWith('http')
            ? location
            : Uri.parse(current).resolve(location).toString();
        continue;
      }
      if (status == 200 || status == 206 || status == 416) {
        return resp;
      }
      throw UpdateException('下载失败（HTTP $status）');
    }
    throw const UpdateException('APK 下载地址跳转次数过多');
  }

  /// 本次响应 Content-Length（无/未知 → -1）。
  int _responseTotal(Response<ResponseBody> resp) {
    final cl = resp.headers.value('content-length');
    final n = int.tryParse(cl ?? '');
    return (n == null || n < 0) ? -1 : n;
  }

  /// 进度分母（完整文件大小）：
  /// 1. [knownSize]（UpdateInfo.size，GitHub 资产 size）；
  /// 2. `Content-Range: bytes x-y/total` 里的 total；
  /// 3. 206 续传 = 起始基数 + 本次响应长度；200 = 本次响应长度。
  /// 都不可知 → null（不回调，UI 转不定态进度条）。
  int? _fullTotal({
    required int? knownSize,
    String? contentRange,
    required int base,
    required int responseTotal,
  }) {
    if (knownSize != null && knownSize > 0) return knownSize;
    if (contentRange != null) {
      final slash = contentRange.lastIndexOf('/');
      if (slash > 0 && slash < contentRange.length - 1) {
        final t = int.tryParse(contentRange.substring(slash + 1).trim());
        if (t != null && t > 0) return t;
      }
    }
    if (responseTotal > 0 && base + responseTotal > 0) {
      return base + responseTotal;
    }
    return null;
  }

  /// 进度回调：received 是「本次响应」收到的字节，需加续传基数。
  void _notifyProgress(
    void Function(double)? onProgress,
    int base,
    int received,
    int? fullTotal,
  ) {
    if (onProgress == null || fullTotal == null || fullTotal <= 0) return;
    final ratio = (base + received) / fullTotal;
    onProgress(ratio.clamp(0.0, 1.0));
  }

  /// dio 错误 → 用户可读中文文案。[forDownload]=true 走下载场景文案：
  /// 网络中断给出「可断点续传」引导、404 指下载地址失效（而非 Release 元数据）。
  ///
  /// 铁律：**不直出底层原始错误/英文**（unknown 兜底给通用「网络异常」），
  /// 任何路径都不出现「未知错误」裸文案。
  String _mapDioError(DioException e, {bool forDownload = false}) {
    // 下载场景：断网 / 连接被重置 / 接收中断 → 明确中断提示（自动断点续传）。
    // dio 把这些底层 IOException 包成 unknown（message 常为 null/英文）。
    if (forDownload && _isNetworkInterruption(e)) {
      return '网络中断，下载未完成，请检查网络后重试（将自动从断点继续）';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return forDownload
            ? '下载超时，请检查网络后重试（将自动从断点继续）'
            : '网络超时，请检查连接后重试';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (forDownload) {
          // 下载 URL 上的 4xx（签名 CDN / browser_download_url，非元数据接口）
          if (code == 401) return '下载需要授权（HTTP 401），请检查 GitHub token';
          if (code == 403) return '下载被拒绝（HTTP 403），请稍后重试或重新检查更新';
          if (code == 404) return '下载地址已失效（HTTP 404），请重新检查更新';
          return '下载失败（HTTP $code）';
        }
        if (code == 401) return 'GitHub token 无效或已过期，请检查管理页配置';
        if (code == 403) return 'GitHub API 速率限制（403），稍后再试';
        if (code == 404) {
          return '暂时没有可用更新：可能还没有创建 GitHub Release，或版本仓库当前不可访问';
        }
        return '版本信息接口返回 $code';
      case DioExceptionType.cancel:
        return forDownload ? '下载已取消' : '请求已取消';
      case DioExceptionType.connectionError:
        return forDownload
            ? '网络连接失败，请检查网络后重试（将自动从断点继续）'
            : '网络连接失败，请检查网络';
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return '网络异常，请检查网络后重试';
    }
  }

  /// 是否「网络中断类」底层错误：Socket / Http / TLS 握手异常（都实现
  /// dart:io 的 IOException）。这类错误重试有效、且可断点续传。
  bool _isNetworkInterruption(DioException e) {
    final cause = e.error;
    if (cause is DioException) return false; // 偶发嵌套：不套中断文案
    return cause is SocketException ||
        cause is HttpException ||
        cause is HandshakeException;
  }

  /// 是否值得自动重试：超时/连接失败/unknown（网络中断）都重试；
  /// HTTP 业务错误（badResponse）、证书错误、取消不重试。
  bool _isTransientDownloadError(DioException e) {
    switch (e.type) {
      case DioExceptionType.badResponse:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
        return false;
      default:
        return true;
    }
  }
}
