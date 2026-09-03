// UpdateService 单元测试（M1.1 + v2.16.8 更新下载修复）：
// - fetchLatest：HTTP 状态码 / JSON 异常 → UpdateException 转换
// - check：force / 节流 24h 逻辑
// - UpdateStorage：读/写最后检查时间
// - download（v2.16.8 新增）：断点续传（.part 保留 + Range 头 + 206/200 分支 +
//   成功改名 + 失败/取消保留 .part + 进度基数并入）、自动重试（重试带 Range
//   续传）、SHA-256 校验、错误分类友好化（无「未知错误」裸文案）
//
// 设计取舍：
// - download 不依赖 path_provider：构造注入 rootDirOverride（临时目录），
//   fake dio adapter 按 Range 模拟 GitHub 资产/CDN（206 分段 / 200 全量 /
//   302 跳转 / 流中断）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/update_info.dart';
import 'package:bili_whitelist_app/services/update_service.dart';
import 'package:bili_whitelist_app/services/update_storage.dart';

/// 固定响应的 fake adapter：返回预置 body + statusCode，并可记录请求。
class _FakeAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, List<String>> headers;
  final List<RequestOptions> requests = [];

  _FakeAdapter({
    required this.statusCode,
    required this.body,
    Map<String, List<String>>? headers,
  }) : headers = headers ?? const {'content-type': ['application/json']};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

UpdateService _svc({
  required Dio dio,
  required UpdateStorage storage,
  Future<String?> Function()? tokenProvider,
}) => UpdateService(dio: dio, storage: storage, tokenProvider: tokenProvider);

void main() {
  group('fetchLatest', () {
    test('200 + 合法 JSON → 返回 UpdateInfo', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'name': 'v2.14.0+26',
          'body': 'changelog',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
              'size': 100,
              'digest': 'sha256:abcdef',
            },
          ],
        },
      );
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      final info = await svc.fetchLatest();
      expect(info.version, '2.14.0');
      expect(info.code, 26);
      expect(info.apkUrl, 'https://example.com/a.apk');
      expect(info.sha256, 'abcdef');
    });

    test('404 且未配 token → 提示先配置 GitHub token', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(statusCode: 404, body: {});
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      expect(
        () => svc.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('请先在管理面板配置 GitHub token'),
          ),
        ),
      );
    });

    test('404 且已配 token → 提示仓库暂无 Release', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(statusCode: 404, body: {});
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => 'ghp_test_token',
      );
      expect(
        () => svc.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('仓库暂无 Release'),
          ),
        ),
      );
    });

    test('403 → 抛 UpdateException(速率限制)', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(statusCode: 403, body: {});
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      expect(
        () => svc.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('速率限制'),
          ),
        ),
      );
    });

    test('JSON 缺 arm64 asset → 抛 UpdateException(格式异常)', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(
        statusCode: 200,
        body: {'tag_name': 'v2.14.0+26', 'assets': []},
      );
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      expect(() => svc.fetchLatest(), throwsA(isA<UpdateException>()));
    });

    test('请求 header 含 User-Agent / Accept', () async {
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      await svc.fetchLatest();
      expect(adapter.requests, hasLength(1));
      final h = adapter.requests.first.headers;
      expect(h['User-Agent'], 'bili-whitelist-app');
      expect(h['Accept'], contains('github'));
    });

    test('tokenProvider 有 token → 请求带 Authorization 头', () async {
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => 'ghp_test_token',
      );
      await svc.fetchLatest();
      final h = adapter.requests.first.headers;
      expect(h['Authorization'], 'Bearer ghp_test_token');
    });

    test('tokenProvider 返回空 → 不带 Authorization 头', () async {
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => '   ',
      );
      await svc.fetchLatest();
      expect(adapter.requests.first.headers.containsKey('Authorization'), isFalse);
    });

    test('tokenProvider 抛异常 → 按无 token 处理，不阻塞检查', () async {
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => throw StateError('storage broken'),
      );
      final info = await svc.fetchLatest();
      expect(info.version, '2.14.0');
      expect(adapter.requests.first.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('resolveDownloadUrl（私有仓库两段式下载）', () {
    const info = UpdateInfo(
      version: '2.14.0',
      code: 26,
      apkUrl: 'https://github.com/x/releases/download/v2.14.0/a.apk',
      apkApiUrl: 'https://api.github.com/repos/x/y/releases/assets/123',
    );

    test('无 token → 直接返回 browser_download_url，不发请求', () async {
      final dio = Dio();
      final adapter = _FakeAdapter(statusCode: 200, body: const {});
      dio.httpClientAdapter = adapter;
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      final url = await svc.resolveDownloadUrl(info);
      expect(url, info.apkUrl);
      expect(adapter.requests, isEmpty);
    });

    test('有 token → 带鉴权请求资产 API，302 → 返回 location（鉴权头不转发）',
        () async {
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 302,
        body: const {},
        headers: const {
          'location': ['https://objects.githubusercontent.com/signed-url'],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => 'ghp_test_token',
      );
      final url = await svc.resolveDownloadUrl(info);
      expect(url, 'https://objects.githubusercontent.com/signed-url');
      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.first;
      expect(req.uri.toString(), info.apkApiUrl);
      expect(req.headers['Authorization'], 'Bearer ghp_test_token');
      expect(req.headers['Accept'], 'application/octet-stream');
      expect(req.followRedirects, isFalse);
    });

    test('有 token 但无 apkApiUrl → 回退 browser_download_url', () async {
      const noApi = UpdateInfo(
        version: '2.14.0',
        code: 26,
        apkUrl: 'https://example.com/a.apk',
      );
      final dio = Dio();
      final adapter = _FakeAdapter(statusCode: 200, body: const {});
      dio.httpClientAdapter = adapter;
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => 'ghp_test_token',
      );
      final url = await svc.resolveDownloadUrl(noApi);
      expect(url, noApi.apkUrl);
      expect(adapter.requests, isEmpty);
    });

    test('资产 API 返回 200（无跳转）→ 抛 UpdateException', () async {
      final dio = Dio();
      final adapter = _FakeAdapter(statusCode: 200, body: const {});
      dio.httpClientAdapter = adapter;
      final svc = _svc(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        tokenProvider: () async => 'ghp_test_token',
      );
      expect(
        () => svc.resolveDownloadUrl(info),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('下载地址获取失败'),
          ),
        ),
      );
    });
  });

  group('check 节流', () {
    test('force=false 且 24h 内已查过 → 不发请求，返回 null', () async {
      SharedPreferences.setMockInitialValues({
        'update:last_check_at': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      });
      final prefs = await SharedPreferences.getInstance();
      final dio = Dio();
      final adapter = _FakeAdapter(statusCode: 200, body: {});
      dio.httpClientAdapter = adapter;
      final svc = _svc(dio: dio, storage: UpdateStorage(prefs));
      final info = await svc.check();
      expect(info, isNull);
      expect(adapter.requests, isEmpty);
    });

    test('force=false 但距上次检查 > 24h → 重新发请求', () async {
      SharedPreferences.setMockInitialValues({
        'update:last_check_at': DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String(),
      });
      final prefs = await SharedPreferences.getInstance();
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(dio: dio, storage: UpdateStorage(prefs));
      final info = await svc.check();
      // 测试环境无 PackageInfo 通道，check 直接返回 info
      expect(info, isNotNull);
      expect(adapter.requests, hasLength(1));
    });

    test('force=true → 跳过节流', () async {
      SharedPreferences.setMockInitialValues({
        'update:last_check_at': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      });
      final prefs = await SharedPreferences.getInstance();
      final dio = Dio();
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      dio.httpClientAdapter = adapter;
      final svc = _svc(dio: dio, storage: UpdateStorage(prefs));
      final info = await svc.check(force: true);
      expect(info, isNotNull);
      expect(info!.version, '2.14.0');
      expect(adapter.requests, hasLength(1));
    });

    test('成功 fetchLatest 后写节流戳', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(
        statusCode: 200,
        body: {
          'tag_name': 'v2.14.0+26',
          'assets': [
            {
              'name': 'app-arm64-v8a-v2.14.0-release.apk',
              'browser_download_url': 'https://example.com/a.apk',
            },
          ],
        },
      );
      final svc = _svc(dio: dio, storage: UpdateStorage(prefs));
      await svc.check(force: true);
      expect(prefs.getString('update:last_check_at'), isNotNull);
    });
  });

  group('download（断点续传 + 自动重试 + 错误分类）', () {
    late Directory tmp;
    const code = 38;
    final payload = List<int>.generate(20, (i) => i); // 0..19

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('update_dl_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // 临时目录清理失败不阻塞
      }
    });

    Future<UpdateService> buildSvc(
      HttpClientAdapter adapter, {
      int attempts = 3,
    }) async {
      final dio = Dio();
      dio.httpClientAdapter = adapter;
      return UpdateService(
        dio: dio,
        storage: UpdateStorage(await _memPrefs()),
        rootDirOverride: tmp,
        maxDownloadAttempts: attempts,
        retryBaseDelay: Duration.zero,
      );
    }

    UpdateInfo info({String? sha256, int? size}) => UpdateInfo(
          version: '2.16.8',
          code: code,
          apkUrl: 'https://example.com/app.apk',
          sha256: sha256,
          size: size ?? payload.length,
        );

    File partFile() => File('${tmp.path}/updates/app-update-$code.apk.part');
    File apkFile() => File('${tmp.path}/updates/app-update-$code.apk');

    test('无 .part：请求不带 Range，200 全量下载 → .part 改名 apk 内容一致',
        () async {
      final src = _DownloadSource(payload);
      final svc = await buildSvc(src);

      final path = await svc.download(info());

      expect(path, apkFile().path);
      expect(await apkFile().readAsBytes(), payload);
      expect(await partFile().exists(), isFalse); // 成功已改名，无 .part 残留
      expect(src.requests, hasLength(1));
      expect(_rangeOf(src.requests.first), isNull); // 无续传不带 Range
    });

    test('.part 已存在 → 请求带 Range，206 续传追加，合并内容正确且进度以 size 为分母',
        () async {
      // 预置半成品：前 8 字节已下载
      final dir = partFile().parent;
      await dir.create(recursive: true);
      await File('${dir.path}/app-update-$code.apk.part')
          .writeAsBytes(payload.take(8).toList());

      final src = _DownloadSource(payload);
      final svc = await buildSvc(src);
      final progresses = <double>[];
      await svc.download(info(), onProgress: progresses.add);

      expect(await apkFile().readAsBytes(), payload); // 8 + 续传 12 合并一致
      expect(await partFile().exists(), isFalse);
      expect(_rangeOf(src.requests.single), 'bytes=8-'); // Range 头断言
      // 进度：206 续传 received 需加 startBytes 基数，分母 = size 20
      expect(progresses, isNotEmpty);
      expect(progresses.last, 1.0);
      for (var i = 1; i < progresses.length; i++) {
        expect(progresses[i] >= progresses[i - 1], isTrue,
            reason: '进度应单调不减（含续传基数）');
      }
    });

    test('服务器不支持 Range（200）→ 全量重下覆盖 .part，内容为新文件', () async {
      final dir = partFile().parent;
      await dir.create(recursive: true);
      await File('${dir.path}/app-update-$code.apk.part')
          .writeAsBytes(List.filled(5, 9)); // 与 payload 无关的旧数据

      final src = _DownloadSource(payload, ignoreRange: true);
      final svc = await buildSvc(src);
      await svc.download(info());

      expect(await apkFile().readAsBytes(), payload); // 覆盖而非追加
      expect(await partFile().exists(), isFalse);
      expect(_rangeOf(src.requests.single), 'bytes=5-'); // 仍带 Range（服务器忽略）
    });

    test('302 跳转（browser_download_url → CDN）：两跳都带 Range，CDN 命中 206',
        () async {
      final dir = partFile().parent;
      await dir.create(recursive: true);
      await File('${dir.path}/app-update-$code.apk.part')
          .writeAsBytes(payload.take(8).toList());

      final src = _DownloadSource(
        payload,
        redirectTo: 'https://cdn.example.com/app.apk',
      );
      final svc = await buildSvc(src);
      await svc.download(info());

      expect(await apkFile().readAsBytes(), payload);
      expect(src.requests, hasLength(2));
      expect(src.requests[0].uri.host, 'example.com'); // 原 URL 那跳
      expect(src.requests[1].uri.host, 'cdn.example.com'); // CDN 那跳
      expect(_rangeOf(src.requests[0]), 'bytes=8-');
      expect(_rangeOf(src.requests[1]), 'bytes=8-'); // Range 到达 CDN → 206
    });

    test('流中断（网络）→ .part 保留已写部分，自动重试带 Range 从断点续传成功',
        () async {
      final src = _DownloadSource(payload)
        ..breakSpecs = [
          (8, HttpException('Connection closed while receiving data')), // 首请求中断
        ];
      final svc = await buildSvc(src);
      await svc.download(info());

      expect(await apkFile().readAsBytes(), payload); // 重试续传后完整
      expect(src.requests, hasLength(2));
      expect(_rangeOf(src.requests[0]), isNull); // 首次无半成品
      expect(_rangeOf(src.requests[1]), 'bytes=8-'); // 重试从断点 8 继续
    });

    test('中断重试仍失败 → 抛友好网络中断文案，.part 保留可再续，apk 不存在',
        () async {
      final src = _DownloadSource(payload)
        ..breakSpecs = [
          (3, SocketException('Connection reset by peer')), // 每次请求都中断
          (3, SocketException('Connection reset by peer')),
        ];
      final svc = await buildSvc(src, attempts: 2);

      await expectLater(
        svc.download(info()),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('网络中断'),
              contains('断点继续'),
              isNot(contains('未知错误')),
            ),
          ),
        ),
      );

      expect(await apkFile().exists(), isFalse);
      final part = partFile();
      expect(await part.exists(), isTrue); // .part 保留
      // 第 1 次写了 3 字节、重试续传又写了 3 字节（Range bytes=3-）
      expect(await part.readAsBytes(), payload.take(6).toList());
      expect(src.requests, hasLength(2)); // 刚好尝试 2 次，未无限重试
    });

    test('取消下载 → 抛「已取消」且 .part 保留', () async {
      final dir = partFile().parent;
      await dir.create(recursive: true);
      await File('${dir.path}/app-update-$code.apk.part')
          .writeAsBytes(payload.take(8).toList());

      final src = _DownloadSource(payload);
      final svc = await buildSvc(src);
      final cancel = CancelToken()..cancel('user canceled');

      await expectLater(
        svc.download(info(), cancelToken: cancel),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('已取消'),
          ),
        ),
      );
      // 取消：.part 原样保留（下次可续传），不发下载请求、不生成 apk
      expect(await partFile().readAsBytes(), payload.take(8).toList());
      expect(await apkFile().exists(), isFalse);
      expect(src.requests, isEmpty);
    });

    test('HTTP 404（下载地址失效）→ 下载场景文案，且不自动重试', () async {
      final src = _DownloadSource(payload, failStatus: 404);
      final svc = await buildSvc(src); // attempts=3 但 404 不应触发重试

      await expectLater(
        svc.download(info()),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('404'),
          ),
        ),
      );
      expect(src.requests, hasLength(1)); // 业务错误不重试
    });

    test('unknown 非网络异常（message 为英文）→ 兜底「网络异常」，无未知错误裸文案',
        () async {
      final src = _DownloadSource(payload,
          streamError: StateError('raw English error from lib'));
      final svc = await buildSvc(src, attempts: 1);

      await expectLater(
        svc.download(info()),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(contains('网络异常'), isNot(contains('未知错误'))),
          ),
        ),
      );
      expect(await partFile().exists(), isTrue); // 半成品仍保留
    });

    test('SHA-256 匹配 → 下载成功并返回路径', () async {
      final good = sha256.convert(payload).toString();
      final src = _DownloadSource(payload);
      final svc = await buildSvc(src);

      final path = await svc.download(info(sha256: good));
      expect(path, apkFile().path);
      expect(await apkFile().readAsBytes(), payload);
    });

    test('SHA-256 不匹配 → 抛「完整性校验失败」并删除已下载文件', () async {
      final src = _DownloadSource(payload);
      final svc = await buildSvc(src);

      await expectLater(
        svc.download(info(sha256: 'a' * 64)),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            contains('完整性校验失败'),
          ),
        ),
      );
      expect(await apkFile().exists(), isFalse); // 校验失败删文件
      expect(await partFile().exists(), isFalse);
    });

    test('换版本下载：清理旧 versionCode 的残留 .part/apk，不影响本次续传', () async {
      final dir = partFile().parent;
      await dir.create(recursive: true);
      final stalePart = File('${dir.path}/app-update-37.apk.part');
      final staleApk = File('${dir.path}/app-update-37.apk');
      await stalePart.writeAsBytes([1, 2, 3]);
      await staleApk.writeAsBytes([4, 5, 6]);
      // 本次 versionCode=38 的 .part 预置 8 字节 → 续传
      await File('${dir.path}/app-update-$code.apk.part')
          .writeAsBytes(payload.take(8).toList());

      final src = _DownloadSource(payload);
      final svc = await buildSvc(src);
      await svc.download(info());

      expect(await stalePart.exists(), isFalse); // 旧版本残留被清理
      expect(await staleApk.exists(), isFalse);
      expect(await apkFile().readAsBytes(), payload); // 本次仍正常续传合并
      expect(_rangeOf(src.requests.single), 'bytes=8-');
    });
  });

  group('UpdateStorage', () {
    test('readLastCheckAt 初始为 null', () async {
      final prefs = await _memPrefs();
      final s = UpdateStorage(prefs);
      expect(await s.readLastCheckAt(), isNull);
    });

    test('writeLastCheckAt 后 readLastCheckAt 返回相同时间', () async {
      final prefs = await _memPrefs();
      final s = UpdateStorage(prefs);
      final t = DateTime(2026, 9, 1, 10, 30);
      await s.writeLastCheckAt(t);
      final got = await s.readLastCheckAt();
      expect(got, t);
    });

    test('写入非法 ISO8601 → read 返回 null', () async {
      SharedPreferences.setMockInitialValues({
        'update:last_check_at': 'not-a-date',
      });
      final prefs = await SharedPreferences.getInstance();
      final s = UpdateStorage(prefs);
      expect(await s.readLastCheckAt(), isNull);
    });
  });
}

/// 内存版 SharedPreferences，给单测用。
Future<SharedPreferences> _memPrefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

/// 取请求的 Range 头值（'bytes=N-' 或 null），头 key 大小写不敏感。
String? _rangeOf(RequestOptions o) {
  for (final e in o.headers.entries) {
    if (e.key.toLowerCase() == 'range') return e.value?.toString();
  }
  return null;
}

/// 内存版「GitHub 资产 / 签名 CDN」adapter：
/// - 支持 [Range] 头 → 206 返回剩余分段（带 content-range/content-length）；
///   不带 Range → 200 全量。
/// - [redirectTo]：模拟公开仓库 `browser_download_url` 302 → CDN 跳转。
/// - [failStatus]：直接回该状态码（模拟 4xx，dio 转 badResponse）。
/// - [ignoreRange]：服务器不支持 Range —— 即使请求带 Range 也回 200 全量。
/// - [breakSpecs]：按请求序号编排「流中断」（写 N 字节后抛底层网络异常，
///   模拟下载一半断网）；[streamError] 是整流写完后抛错（模拟 unknown 兜底）。
class _DownloadSource implements HttpClientAdapter {
  _DownloadSource(
    List<int> fullBytes, {
    this.redirectTo,
    this.failStatus,
    this.streamError,
    this.ignoreRange = false,
  }) : _fullBytes = fullBytes;

  final List<int> _fullBytes;
  final String? redirectTo;
  final int? failStatus;
  final Object? streamError;
  final bool ignoreRange;

  final List<RequestOptions> requests = [];

  /// 每个请求的中断描述（顺序对应）：null = 完整返回；(N, err) = 先写 N 字节
  /// 再抛 err。不覆盖的请求 = 完整返回。
  List<(int, Object)?> breakSpecs = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final idx = requests.length;
    requests.add(options);
    final uri = options.uri;

    if (failStatus != null) {
      return ResponseBody.fromString('', failStatus!);
    }
    // 第一跳：browser_download_url（example.com）→ 302 CDN
    if (redirectTo != null && uri.host == 'example.com') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [redirectTo!],
        },
      );
    }

    // 其余请求：按 Range 分段（ignoreRange → 服务器忽略 Range 回 200 全量）
    final range = ignoreRange ? null : _rangeOf(options);
    var start = 0;
    if (range != null) {
      final n =
          int.tryParse(range.substring('bytes='.length).split('-').first);
      start = n ?? 0;
    }
    final hasRange = range != null;
    final served = _fullBytes.sublist(start.clamp(0, _fullBytes.length));
    if (hasRange && served.isEmpty) {
      // Range 起点超出文件 → 416（本测试不触发，兜底保证不越界）
      return ResponseBody(Stream<Uint8List>.empty(), 416);
    }
    final status = hasRange ? 206 : 200;
    final headers = <String, List<String>>{
      'content-length': [served.length.toString()],
      if (hasRange)
        'content-range': [
          'bytes $start-${start + served.length - 1}/${_fullBytes.length}',
        ],
    };

    final brk = idx < breakSpecs.length ? breakSpecs[idx] : null;
    Stream<Uint8List> stream;
    if (brk != null) {
      final (breakAt, err) = brk;
      stream = () async* {
        if (served.isNotEmpty && breakAt > 0) {
          yield Uint8List.fromList(served.take(breakAt).toList());
        }
        throw err;
      }();
    } else if (streamError != null) {
      final Object err = streamError!;
      stream = () async* {
        if (served.isNotEmpty) {
          yield Uint8List.fromList(served);
        }
        throw err;
      }();
    } else {
      stream = Stream<Uint8List>.value(Uint8List.fromList(served));
    }
    return ResponseBody(stream, status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}
