// TranslateApi 单元测试（mock secure storage + mock dio，不访问真实网络）：
// - 配置存取（translate_ 前缀）/ hasConfig（任一字段留空 = 未启用）
// - translateBatch 请求构造（base_url/model/Authorization/批量拆分/序号拼接）
// - 回复解析（行数对应 / 不足补原文 / 多行截断 / 序号剥离 / 空回复异常）
// - 本地缓存（命中 / 写入 / 缺失 / 损坏容错）
// - 失败分类（未配置 / 401 / 超时 / 断网）
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/translate_api.dart';

/// 内存版 secure storage（对应原生 MethodChannel）。
final Map<String, String> _store = {};

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'read':
        return _store[args['key'] as String?];
      case 'write':
        final key = args['key'] as String?;
        if (key == null) return false;
        _store[key] = args['value'] as String? ?? '';
        return true;
      case 'delete':
        _store.remove(args['key'] as String?);
        return true;
      default:
        return null;
    }
  });
}

/// 记录请求并按 handler 返回响应体的 adapter。
class _ChatAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final ResponseBody Function(RequestOptions options) handler;

  _ChatAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// 构造 chat.completions 响应体（content 按行 = 译文）。
ResponseBody _chatBody(List<String> lines, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode({
      'choices': [
        {
          'message': {'content': lines.join('\n')},
        },
      ],
    }),
    status,
    headers: {
      'content-type': ['application/json; charset=utf-8'],
    },
  );
}

/// 解析请求体 JSON（dio data 是 Map 或 String，统一转 Map）。
Map<String, dynamic> _bodyOf(RequestOptions options) {
  final data = options.data;
  if (data is Map<String, dynamic>) return data;
  if (data is String) return jsonDecode(data) as Map<String, dynamic>;
  return <String, dynamic>{};
}

TranslateApi _api(HttpClientAdapter adapter, {Directory? cacheDir}) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  ));
  dio.httpClientAdapter = adapter;
  return TranslateApi(dio: dio, cacheDirOverride: cacheDir);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    tmpDir = Directory.systemTemp.createTempSync('translate_test_');
  });

  tearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('配置存取', () {
    test('saveConfig → loadConfig 完整读取；key 带 translate_ 前缀', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])));
      expect(_store.containsKey('translate_base_url'), isFalse);

      await api.saveConfig(
        baseUrl: ' https://api.deepseek.com ',
        apiKey: ' sk-test ',
        model: ' deepseek-chat ',
      );

      expect(_store['translate_base_url'], 'https://api.deepseek.com');
      expect(_store['translate_api_key'], 'sk-test');
      expect(_store['translate_model'], 'deepseek-chat');

      final cfg = await api.loadConfig();
      expect(cfg, isNotNull);
      expect(cfg!.baseUrl, 'https://api.deepseek.com');
      expect(cfg.apiKey, 'sk-test');
      expect(cfg.model, 'deepseek-chat');
    });

    test('未配置 → loadConfig null / hasConfig false', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])));
      expect(await api.loadConfig(), isNull);
      expect(await api.hasConfig(), isFalse);
    });

    test('任一字段留空（如 key 留空=不启用）→ hasConfig false', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])));
      await api.saveConfig(baseUrl: 'https://api.deepseek.com', model: 'deepseek-chat');
      expect(await api.hasConfig(), isFalse);
      expect(await api.loadConfig(), isNull);
    });
  });

  group('translateBatch 请求构造', () {
    test('base_url/model/Authorization/序号拼接；回复逐条对应', () async {
      final adapter = _ChatAdapter((_) => _chatBody(['你好', '早上好']));
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com/',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );

      final result = await api.translateBatch(['Hello', 'Good morning']);

      expect(result, ['你好', '早上好']);
      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.uri.toString(),
          'https://api.deepseek.com/v1/chat/completions'); // 尾部 / 已去
      expect(req.headers['Authorization'], 'Bearer sk-test');
      final body = _bodyOf(req);
      expect(body['model'], 'deepseek-chat');
      expect(body['stream'], isFalse);
      final messages = body['messages'] as List;
      expect(messages, hasLength(2));
      expect((messages[0] as Map)['role'], 'system');
      expect((messages[0] as Map)['content'], contains('简体中文'));
      expect((messages[1] as Map)['role'], 'user');
      expect((messages[1] as Map)['content'],
          '1. Hello\n2. Good morning');
    });

    test('超过 batchSize（20）自动分批串行请求', () async {
      final adapter = _ChatAdapter((options) {
        final body = _bodyOf(options);
        final content =
            (body['messages'] as List).last['content'] as String;
        // 逐行回显（模拟服务端按序翻译）
        final lines = content
            .split('\n')
            .map((l) => l.replaceFirst(RegExp(r'^\d+\. '), ''))
            .toList();
        return _chatBody(lines);
      });
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );

      final texts = [for (var i = 0; i < 25; i++) 'line$i'];
      final result = await api.translateBatch(texts);

      expect(adapter.requests, hasLength(2)); // 20 + 5
      final firstBody = _bodyOf(adapter.requests[0]);
      final firstContent =
          (firstBody['messages'] as List).last['content'] as String;
      expect(firstContent.split('\n'), hasLength(20));
      expect(firstContent, startsWith('1. line0'));
      expect(firstContent, contains('20. line19'));
      final secondBody = _bodyOf(adapter.requests[1]);
      final secondContent =
          (secondBody['messages'] as List).last['content'] as String;
      expect(secondContent.split('\n'), hasLength(5));
      expect(secondContent, contains('5. line24'));
      expect(result, hasLength(25));
      expect(result.first, 'line0');
      expect(result.last, 'line24');
    });

    test('空列表不请求直接返回空', () async {
      final adapter = _ChatAdapter((_) => _chatBody(const []));
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );
      expect(await api.translateBatch(const []), isEmpty);
      expect(adapter.requests, isEmpty);
    });

    test('进度 ValueNotifier 随批次更新（20+5 → 20 后 25）', () async {
      final adapter = _ChatAdapter((options) {
        final body = _bodyOf(options);
        final content =
            (body['messages'] as List).last['content'] as String;
        final lines = content
            .split('\n')
            .map((l) => l.replaceFirst(RegExp(r'^\d+\. '), ''))
            .toList();
        return _chatBody(lines);
      });
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );
      final progress = ValueNotifier<int>(0);
      final seen = <int>[];
      progress.addListener(() => seen.add(progress.value));

      await api.translateBatch(
          [for (var i = 0; i < 25; i++) 't$i'], progress: progress);

      expect(progress.value, 25);
      expect(seen, [20, 25]); // 每批完成更新一次已翻译条数
    });
  });

  group('回复解析容错', () {
    test('行数不足 → 不足部分补原文', () async {
      final adapter = _ChatAdapter((_) => _chatBody(['仅一行']));
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );

      final result =
          await api.translateBatch(['Hello', 'Good morning', 'Bye']);

      expect(result, ['仅一行', 'Good morning', 'Bye']);
    });

    test('回复行带序号（1. 2、）→ 剥离序号', () async {
      final adapter =
          _ChatAdapter((_) => _chatBody(['1. 你好', '2、早上好']));
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );

      final result = await api.translateBatch(['Hello', 'Good morning']);

      expect(result, ['你好', '早上好']);
    });

    test('回复行数多于输入 → 截断到输入条数', () async {
      final adapter =
          _ChatAdapter((_) => _chatBody(['一', '二', '三', '四']));
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );

      final result = await api.translateBatch(['a', 'b']);

      expect(result, ['一', '二']);
    });

    test('choices 缺失/内容为空 → 抛中文异常', () async {
      final api = _api(_ChatAdapter((_) => ResponseBody.fromString(
            jsonEncode({'choices': <Object>[]}),
            200,
            headers: {
              'content-type': ['application/json'],
            },
          )));
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );

      expect(
        () => api.translateBatch(['Hello']),
        throwsA(isA<TranslateApiException>()
            .having((e) => e.message, 'message', contains('响应格式异常'))),
      );
    });
  });

  group('本地缓存', () {
    test('无缓存 → null；保存后可读回；同一 bvid_cid_lan 命中', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])),
          cacheDir: tmpDir);

      expect(await api.getCachedTranslation('BV1x', 1, 'ai-en'), isNull);

      await api.saveTranslation(
          'BV1x', 1, 'ai-en', ['你好', '早上好', '再见']);

      final cached = await api.getCachedTranslation('BV1x', 1, 'ai-en');
      expect(cached, ['你好', '早上好', '再见']);
      // 不同 lan / cid 不串
      expect(await api.getCachedTranslation('BV1x', 1, 'ai-zh'), isNull);
      expect(await api.getCachedTranslation('BV1x', 2, 'ai-en'), isNull);
    });

    test('缓存文件损坏 → 返回 null（不抛）', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])),
          cacheDir: tmpDir);
      final f = File('${tmpDir.path}/subtitle_translation_BV1x_1_ai-en.json');
      await f.writeAsString('not json {{');
      expect(await api.getCachedTranslation('BV1x', 1, 'ai-en'), isNull);
    });

    test('缓存文件名含 bvid_cid_lan（格式约定）', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])),
          cacheDir: tmpDir);
      await api.saveTranslation('BV1x', 123, 'ai-en', const ['a']);
      final files = tmpDir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.path,
          contains('subtitle_translation_BV1x_123_ai-en.json'));
    });
  });

  group('失败分类', () {
    test('未配置 → 抛「未配置翻译服务」', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [])));
      expect(
        () => api.translateBatch(['Hello']),
        throwsA(isA<TranslateApiException>()
            .having((e) => e.message, 'message', contains('未配置翻译服务'))),
      );
    });

    test('HTTP 401 → key 无效', () async {
      final api = _api(_ChatAdapter((_) => _chatBody(const [], status: 401)));
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'bad-key',
        model: 'deepseek-chat',
      );
      expect(
        () => api.translateBatch(['Hello']),
        throwsA(isA<TranslateApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('key 无效'))),
      );
    });

    test('连接超时 → 提示超时', () async {
      final adapter = _ChatAdapter((options) {
        throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: const Duration(seconds: 30),
        );
      });
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );
      expect(
        () => api.translateBatch(['Hello']),
        throwsA(isA<TranslateApiException>()
            .having((e) => e.message, 'message', contains('超时'))),
      );
    });

    test('断网 → 提示网络连接失败', () async {
      final adapter = _ChatAdapter((options) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Connection refused',
        );
      });
      final api = _api(adapter);
      await api.saveConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'sk-test',
        model: 'deepseek-chat',
      );
      expect(
        () => api.translateBatch(['Hello']),
        throwsA(isA<TranslateApiException>()
            .having((e) => e.message, 'message', contains('网络连接失败'))),
      );
    });
  });
}
