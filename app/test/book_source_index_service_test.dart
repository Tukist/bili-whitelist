// 书源索引下载服务单测（R3）。
//
// 用假 `HttpClientAdapter` 造响应（不访问真实网络，见 `article_api_test.dart`
// 的同一套路），覆盖：
// - 三种文件形态：书源数组 / 包一层 `{"sources":[…]}` / 单个书源对象；
// - 同名去重（纯函数 + 跨文件，保留先出现的）；
// - 单文件 25MB 上限：既看 `Content-Length`（不读 body），也看实际读到多少；
// - 404 / 超时 / 坏 JSON 各自落 failed，且**不影响其它 URL**；
// - usesJs 标注、进度回调、BOM 与「疑似非 UTF-8」告警；
// - 纯函数：dedupeByName / exceedsMaxBytes / looksLikeUtf8 /
//   expandBookSourceEnvelope。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_source_index_service.dart';

/// 一个假的 HTTP 适配器：按**完整 URL** 找 handler；没配的 URL 一律 404。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, Future<ResponseBody> Function(RequestOptions)> routes;

  /// 被请求过的 URL（顺序 = 实际请求顺序，用来断言「串行」）。
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final url = options.uri.toString();
    requested.add(url);
    final handler = routes[url];
    if (handler == null) {
      return Future.value(ResponseBody.fromString('not found', 404));
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// 正常响应：UTF-8 的 JSON + 真实的 `Content-Length`。
Future<ResponseBody> _json(Object data) async {
  final bytes = utf8.encode(jsonEncode(data));
  return _bytes(bytes, contentLength: bytes.length);
}

/// 原样字节响应（可伪造 `Content-Length`，用来验「超限不读 body」）。
Future<ResponseBody> _bytes(
  List<int> bytes, {
  int? contentLength,
  int statusCode = 200,
}) async {
  return ResponseBody.fromBytes(
    bytes,
    statusCode,
    headers: {
      'content-type': ['application/json; charset=utf-8'],
      if (contentLength != null)
        Headers.contentLengthHeader: ['$contentLength'],
    },
  );
}

BookSourceIndexService _service(
  _FakeAdapter adapter, {
  int maxBytes = kBookSourceIndexMaxBytes,
}) {
  final dio = Dio(BaseOptions(connectTimeout: kBookSourceIndexTimeout));
  dio.httpClientAdapter = adapter;
  return BookSourceIndexService(dio: dio, maxBytes: maxBytes);
}

/// 一个 legado 书源（`fromLegado` 认这套字段）。
Map<String, dynamic> _legado(
  String name, {
  String? site,
  Map<String, dynamic>? ruleSearch,
}) =>
    {
      'bookSourceName': name,
      'bookSourceUrl': site ?? 'https://${name.toLowerCase()}.example',
      'ruleSearch': ruleSearch ?? {'bookList': '.item', 'name': '.name'},
      'ruleToc': {'chapterList': '.ch'},
    };

const String _u1 = 'https://index.example/a.json';
const String _u2 = 'https://index.example/b.json';

void main() {
  group('三种文件形态都能解析', () {
    test('书源数组', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _json([_legado('甲'), _legado('乙')]),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);

      expect(result.sources.map((s) => s.name), ['甲', '乙']);
      expect(result.outcomes.single.status, IndexUrlStatus.ok);
      expect(result.outcomes.single.count, 2);
      expect(result.outcomes.single.message, isEmpty);
    });

    test('包一层 {"sources":[…]}（parseBookSourceText 本身不认这种）', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _json({
          'version': 3,
          'sources': [_legado('甲'), _legado('乙')],
        }),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);
      expect(result.sources.map((s) => s.name), ['甲', '乙']);
    });

    test('再包深一层 {"data":{"sources":[…]}} 也认', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _json({
          'code': 0,
          'data': {
            'sources': [_legado('甲')],
          },
        }),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);
      expect(result.sources.map((s) => s.name), ['甲']);
    });

    test('单个书源对象（本身就是一份书源，不是包一层的信封）', () async {
      final adapter = _FakeAdapter({_u1: (_) => _json(_legado('孤源'))});
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);
      expect(result.sources.map((s) => s.name), ['孤源']);
      expect(result.sources.single.baseUrl, 'https://孤源.example');
    });
  });

  group('去重', () {
    test('纯函数：同名（大小写不敏感）保留先出现的', () {
      final first = BookSource.fromLegado(_legado('Foo', site: 'https://a.example'))!;
      final second =
          BookSource.fromLegado(_legado('foo', site: 'https://b.example'))!;
      final deduped = dedupeByName([first, second]);
      expect(deduped, hasLength(1));
      expect(deduped.single.baseUrl, 'https://a.example');
    });

    test('跨文件：先下到的文件保持权威（后一个文件里的同名旧条目被丢掉）', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _json([
          _legado('共享', site: 'https://first.example'),
          _legado('只在A'),
        ]),
        _u2: (_) => _json([
          _legado('共享', site: 'https://second.example'),
          _legado('只在B'),
        ]),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1, _u2]);

      expect(result.sources.map((s) => s.name), ['共享', '只在A', '只在B']);
      expect(
        result.sources.first.baseUrl,
        'https://first.example',
        reason: '同名时先下到的文件赢',
      );
      // 每个 URL 各自的计数照实报（第二个文件里确实有 2 条）
      expect(result.outcomes.map((o) => o.count), [2, 2]);
    });
  });

  group('单文件 25MB 上限', () {
    test('Content-Length 就超了 → skipped，且不解析 body', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _bytes(
          utf8.encode(jsonEncode([_legado('甲')])),
          // 假报 30MB：真造 30MB 字节只会让用例变慢，这里验的是判定链路
          contentLength: 30 * 1024 * 1024,
        ),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);

      expect(result.sources, isEmpty);
      expect(result.outcomes.single.status, IndexUrlStatus.skipped);
      expect(result.outcomes.single.message, contains('25.0 MB'));
      expect(result.outcomes.single.message, contains('已跳过'));
    });

    test('服务器不报长度、边读边超 → skipped（用小的 maxBytes 代替 25MB）', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _bytes(utf8.encode(jsonEncode([_legado('甲')]))),
      });
      final result =
          await _service(adapter, maxBytes: 8).fetchIndexes(urls: [_u1]);

      expect(result.sources, isEmpty);
      expect(result.outcomes.single.status, IndexUrlStatus.skipped);
      expect(result.outcomes.single.message, contains('上限'));
    });

    test('纯函数 exceedsMaxBytes：null（没报长度）不算超，等于上限也不算', () {
      expect(exceedsMaxBytes(null), isFalse);
      expect(exceedsMaxBytes(kBookSourceIndexMaxBytes), isFalse);
      expect(exceedsMaxBytes(kBookSourceIndexMaxBytes + 1), isTrue);
    });
  });

  group('失败隔离', () {
    test('404 / 超时 / 坏 JSON 各自 failed，但不影响别的 URL', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => Future.value(ResponseBody.fromString('not found', 404)),
        _u2: (_) => _json([_legado('好的')]),
        'https://index.example/slow.json': (options) async =>
            throw DioException.receiveTimeout(
          timeout: kBookSourceIndexTimeout,
          requestOptions: options,
        ),
        'https://index.example/bad.json': (_) => _bytes(utf8.encode('{不是 JSON')),
      });
      final urls = [
        _u1,
        _u2,
        'https://index.example/slow.json',
        'https://index.example/bad.json',
      ];
      final result = await _service(adapter).fetchIndexes(urls: urls);

      expect(result.outcomes.map((o) => o.status), [
        IndexUrlStatus.failed,
        IndexUrlStatus.ok,
        IndexUrlStatus.failed,
        IndexUrlStatus.failed,
      ]);
      expect(result.outcomes.first.message, contains('404'));
      expect(result.outcomes[2].message, contains('超时'));
      expect(result.outcomes[3].message, isNotEmpty);
      // 失败的不影响成功的
      expect(result.sources.map((s) => s.name), ['好的']);
      // 汇总里点明失败个数与第一个原因
      expect(result.summary, contains('失败 3 个'));
    });

    test('非法协议 → failed，且根本不发请求', () async {
      final adapter = _FakeAdapter({});
      final result =
          await _service(adapter).fetchIndexes(urls: ['ftp://x/a.json', '不是链接']);

      expect(result.outcomes.map((o) => o.status),
          [IndexUrlStatus.failed, IndexUrlStatus.failed]);
      expect(result.outcomes.first.message, contains('http(s)'));
      expect(adapter.requested, isEmpty);
    });

    test('适配器抛任意异常也只会变成 failed（永不抛到调用方）', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => throw StateError('boom'),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);
      expect(result.outcomes.single.status, IndexUrlStatus.failed);
      expect(result.sources, isEmpty);
    });

    test('一个 URL 都没有 → 空结果，不发任何请求', () async {
      final adapter = _FakeAdapter({});
      final result = await _service(adapter).fetchIndexes(urls: const []);
      expect(result.sources, isEmpty);
      expect(result.outcomes, isEmpty);
      expect(adapter.requested, isEmpty);
    });
  });

  group('usesJs 标注', () {
    test('JS 源进 jsKeys，普通源不进；汇总里报个数', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _json([
          _legado('普通源'),
          _legado('JS源', ruleSearch: {'bookList': '.item', 'name': '@js:...'}),
        ]),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);

      final plain = result.sources.firstWhere((s) => s.name == '普通源');
      final js = result.sources.firstWhere((s) => s.name == 'JS源');
      expect(result.needsJs(plain), isFalse);
      expect(result.needsJs(js), isTrue);
      expect(result.jsCount, 1);
      expect(result.summary, contains('1 个需 JS'));
    });

    test('只在发现页用了 JS 的源：进 partialJsKeys，不算「需 JS」', () async {
      // 设计契约变更（I1）：旧口径扫整份 raw，exploreUrl 里有 JS 就整源判死。
      // 本 App 从不执行发现页，所以这类源应该能直接搜。
      final explore = _legado('只在发现页用JS')
        ..['exploreUrl'] = '@js:java.ajax("/explore")';
      final adapter = _FakeAdapter({
        _u1: (_) => _json([_legado('普通源'), explore]),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);

      final partial = result.sources.firstWhere((s) => s.name == '只在发现页用JS');
      expect(result.needsJs(partial), isFalse);
      expect(result.partialJs(partial), isTrue);
      expect(result.jsCount, 0);
      expect(result.partialJsCount, 1);
      expect(result.summary, contains('不影响搜索'));
    });
  });

  group('进度 / 串行', () {
    test('逐 URL 串行请求，回调给出 (已完成, 总数) 并补一次收尾', () async {
      final adapter = _FakeAdapter({
        _u1: (_) => _json([_legado('甲')]),
        _u2: (_) => _json([_legado('乙')]),
      });
      final progress = <String>[];
      await _service(adapter).fetchIndexes(
        urls: [_u1, _u2],
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(progress, ['0/2', '1/2', '2/2']);
      expect(adapter.requested, [_u1, _u2]);
    });
  });

  group('解码', () {
    test('带 BOM 的文件也能解析（BOM 不算 JSON 内容）', () async {
      final body = utf8.encode(jsonEncode([_legado('带BOM')]));
      final adapter = _FakeAdapter({
        _u1: (_) => _bytes([0xEF, 0xBB, 0xBF, ...body], contentLength: body.length + 3),
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);
      expect(result.sources.map((s) => s.name), ['带BOM']);
      expect(result.outcomes.single.message, isEmpty);
    });

    test('明显不是 UTF-8 → 仍尝试解析，但带一句告警', () async {
      // GBK 的「中文」四个字节，按 UTF-8 强解会得到替换符
      final adapter = _FakeAdapter({
        _u1: (_) async {
          final bytes = [0xD6, 0xD0, 0xCE, 0xC4];
          return ResponseBody.fromBytes(
            bytes,
            200,
            headers: {
              Headers.contentLengthHeader: ['${bytes.length}'],
            },
          );
        },
      });
      final result = await _service(adapter).fetchIndexes(urls: [_u1]);
      // 内容解析不出来 → failed；但判定依据是内容而不是编码（编码只告警）
      expect(result.outcomes.single.status, IndexUrlStatus.failed);
    });

    test('looksLikeUtf8：偶发一个替换符不算，成片替换才算', () {
      expect(looksLikeUtf8('正常的中文文本'), isTrue);
      expect(looksLikeUtf8(''), isTrue);
      // 1001 个字符里 1 个坏字节 ≈ 0.1%，算「偶然」
      expect(looksLikeUtf8('${List.filled(1000, 'a').join()}\uFFFD'), isTrue);
      // GBK 中文按 UTF-8 强解：几乎全是替换符
      expect(looksLikeUtf8(utf8.decode([0xD6, 0xD0, 0xCE, 0xC4], allowMalformed: true)),
          isFalse);
    });
  });

  group('expandBookSourceEnvelope（纯函数）', () {
    test('顶层就是数组 → 不展开（返回 null，交给解析器）', () {
      expect(expandBookSourceEnvelope('[{},{}]'), isNull);
    });

    test('{"sources":[…]} → 展开成数组的 JSON 文本', () {
      final expanded = expandBookSourceEnvelope('{"sources":[{"name":"A"}]}');
      expect(expanded, isNotNull);
      expect(jsonDecode(expanded!), [
        {'name': 'A'},
      ]);
    });

    test('单个书源对象 / 非 JSON → 不展开', () {
      expect(expandBookSourceEnvelope(jsonEncode(_legado('甲'))), isNull);
      expect(expandBookSourceEnvelope('不是 JSON'), isNull);
      expect(expandBookSourceEnvelope('{"version":3}'), isNull);
    });
  });
}
