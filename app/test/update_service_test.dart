// UpdateService 单元测试（M1.1）：
// - fetchLatest：HTTP 状态码 / JSON 异常 → UpdateException 转换
// - check：force / 节流 24h 逻辑
// - UpdateStorage：读/写最后检查时间
//
// 设计取舍：
// - download 的 SHA-256 流式校验 + path_provider 联动属于 IO 集成测，
//   单测里 mock path_provider 收益不大（M1.5 已用 widget test 验证
//   UI 路径），这里只覆盖到 check / fetchLatest 两个数据面。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  final List<RequestOptions> requests = [];

  _FakeAdapter({required this.statusCode, required this.body});

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
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

UpdateService _svc({required Dio dio, required UpdateStorage storage}) =>
    UpdateService(dio: dio, storage: storage);

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

    test('404 → 抛 UpdateException(没有可用更新/仓库不可访问)', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(statusCode: 404, body: {});
      final svc = _svc(dio: dio, storage: UpdateStorage(await _memPrefs()));
      expect(
        () => svc.fetchLatest(),
        throwsA(
          isA<UpdateException>().having(
            (e) => e.message,
            'message',
            allOf(contains('没有可用更新'), contains('仓库当前不可访问')),
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
