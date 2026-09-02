// import_parser 单元测试：
// - 裸 BV / 完整链接（www、m）/ 夹杂标题文本 / 多链接取第一个 / 无法识别
// - b23.tv 短链：注入 fake adapter 模拟重定向（最终 URL 提取 BV）
// - 短链重定向失败 / 网络失败 → 「短链解析失败」
// 纯 Dart + dio fake adapter，不访问真实网络。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/import_parser.dart';

/// 两个合法 10 位 BV（`BV` + 10 位字母数字）。
const _bv1 = 'BV1yE8r6KErQ'; // 任务示例的完整链接 BV
const _bv2 = 'BV1xX7yY6zZ5'; // 另一个 BV，用于多链接测试

/// 模拟短链重定向的 adapter：返回带 redirects 的响应（`realUri` 取最终地址）。
class _RedirectAdapter implements HttpClientAdapter {
  /// null → 抛网络连接错误。
  final Uri? finalLocation;
  final List<RequestOptions> requests = [];

  _RedirectAdapter({this.finalLocation});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (finalLocation == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }
    final body = ResponseBody.fromString(
      '<html>redirecting...</html>',
      200,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
      },
    );
    // dio 用 ResponseBody.redirects 填充 Response.redirects，realUri 据此取最终地址
    body.redirects = [
      RedirectRecord(302, 'GET', finalLocation!),
    ];
    return body;
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseBvid 纯文本解析（无网络）', () {
    test('裸 BV 号', () async {
      expect(await parseBvid(_bv1), _bv1);
    });

    test('完整链接（www.bilibili.com）', () async {
      expect(
        await parseBvid('【标题】 https://www.bilibili.com/video/$_bv1/'
            '?share_source=copy_web&vd_source=abc123'),
        _bv1,
      );
    });

    test('完整链接（m.bilibili.com）', () async {
      expect(
        await parseBvid('https://m.bilibili.com/video/$_bv2'),
        _bv2,
      );
    });

    test('完整链接带分P/分享 query → 裸 BV 命中，不走网络', () async {
      expect(
        await parseBvid('https://www.bilibili.com/video/$_bv1'
            '?p=2&share_source=copy_web&vd_source=abc'),
        _bv1,
      );
    });

    test('extractShortCode 返回带协议头的完整短链', () {
      // 完整 URL：原样返回
      expect(extractShortCode('https://b23.tv/spVKBAi'),
          'https://b23.tv/spVKBAi');
      // 无协议头：自动补 https://
      expect(extractShortCode('b23.tv/spVKBAi'), 'https://b23.tv/spVKBAi');
      // 带 query（手机分享格式）：只取短码部分，query 丢弃
      expect(
        extractShortCode('https://b23.tv/spVKBAi'
            '?share_medium=android&bbid=123&ts=1787426885'),
        'https://b23.tv/spVKBAi',
      );
      expect(extractShortCode('没有短链'), isNull);
    });

    test('夹杂标题文本', () async {
      expect(
        await parseBvid('【测试视频】这个视频很好看 '
            'https://www.bilibili.com/video/$_bv1/ 快来看'),
        _bv1,
      );
    });

    test('多链接取第一个', () async {
      expect(
        await parseBvid('$_bv1 $_bv2'),
        _bv1,
      );
      // 完整链接形式的多链接也取第一个
      expect(
        await parseBvid(
            'https://www.bilibili.com/video/$_bv1/ '
            'https://www.bilibili.com/video/$_bv2/'),
        _bv1,
      );
    });

    test('无法识别 → 未识别到有效的 B 站视频链接', () async {
      await expectLater(
        parseBvid('随便一段没有链接的文字'),
        throwsA(isA<ImportParseException>().having(
          (e) => e.message,
          'message',
          contains('未识别到有效的 B 站视频链接'),
        )),
      );
    });

    test('空输入 → 未识别到有效的 B 站视频链接', () async {
      await expectLater(
        parseBvid('   '),
        throwsA(isA<ImportParseException>()),
      );
    });
  });

  group('parseBvid 短链解析（mock 重定向）', () {
    test('短链重定向到视频 → 提取 BV', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse(
            'https://www.bilibili.com/video/$_bv1?spm_id_from=333.999'),
      );
      final dio = _dioWith(adapter);

      expect(
        await parseBvid('【标题】 https://b23.tv/spVKBAi', dio: dio),
        _bv1,
      );
      // 请求必须打到带协议头的完整短链（无协议头会 No host specified）
      final uri = adapter.requests.single.uri;
      expect(uri.toString(), 'https://b23.tv/spVKBAi');
    });

    test('带 query 的短链（手机分享格式）→ 只取短码部分请求', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('https://m.bilibili.com/video/$_bv1?p=1'),
      );
      final dio = _dioWith(adapter);

      expect(
        await parseBvid('https://b23.tv/spVKBAi'
            '?share_medium=android&share_source=copy_link&bbid=123&ts=1787426885',
            dio: dio),
        _bv1,
      );
      final uri = adapter.requests.single.uri;
      expect(uri.toString(), 'https://b23.tv/spVKBAi');
    });

    test('无协议头短链 b23.tv/xxx → 自动补 https:// 再请求', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('https://www.bilibili.com/video/$_bv1/'),
      );
      final dio = _dioWith(adapter);

      expect(
        await parseBvid('b23.tv/spVKBAi', dio: dio),
        _bv1,
      );
      expect(
        adapter.requests.single.uri.toString(),
        'https://b23.tv/spVKBAi',
      );
    });

    test('重定向最终 URL 是相对路径 /video/BVxx/?... → 提取 BV', () async {
      // 真实链路：b23.tv 302 → www.bilibili.com/video/BVxx?... → 301 相对路径
      // /video/BVxx/?...（dio realUri 直接记录相对 Location，无 host）。
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('/video/$_bv1/?buvid=abc&p=1'),
      );
      final dio = _dioWith(adapter);

      expect(
        await parseBvid('https://b23.tv/spVKBAi', dio: dio),
        _bv1,
      );
    });

    test('移动端重定向 m.bilibili.com/video/BVxx?p=1 → 提取 BV', () async {
      final adapter = _RedirectAdapter(
        finalLocation:
            Uri.parse('https://m.bilibili.com/video/$_bv1?p=1&share_medium=android'),
      );
      final dio = _dioWith(adapter);

      expect(
        await parseBvid('https://b23.tv/spVKBAi', dio: dio),
        _bv1,
      );
    });

    test('短链重定向到非视频 → 短链解析失败', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('https://www.bilibili.com/'),
      );
      final dio = _dioWith(adapter);

      await expectLater(
        parseBvid('https://b23.tv/spVKBAi', dio: dio),
        throwsA(isA<ImportParseException>().having(
          (e) => e.message,
          'message',
          contains('短链解析失败'),
        )),
      );
    });

    test('短链网络失败 → 短链解析失败', () async {
      final dio = _dioWith(_RedirectAdapter(finalLocation: null));

      await expectLater(
        parseBvid('https://b23.tv/spVKBAi', dio: dio),
        throwsA(isA<ImportParseException>().having(
          (e) => e.message,
          'message',
          contains('短链解析失败'),
        )),
      );
    });
  });

  test('countLinkTokens 统计链接数量', () {
    expect(countLinkTokens(_bv1), 1);
    expect(countLinkTokens('$_bv1 $_bv2'), 2);
    expect(countLinkTokens('https://b23.tv/spVKBAi'), 1);
    expect(countLinkTokens('https://b23.tv/spVKBAi $_bv1'), 2);
    expect(
      countLinkTokens('https://b23.tv/spVKBAi'
          '?share_medium=android&bbid=1&ts=2 $_bv1'),
      2,
    );
    expect(countLinkTokens('没有链接'), 0);
  });

  group('parsePgcRef 番剧引用解析（本地正则，不走网络）', () {
    test('ep 完整链接 → PgcRef(ep, id)', () async {
      expect(
        await parsePgcRef('https://www.bilibili.com/bangumi/play/ep98603'),
        const PgcRef(kind: PgcKind.ep, id: 98603),
      );
    });

    test('ss 完整链接 → PgcRef(ss, id)', () async {
      expect(
        await parsePgcRef('https://www.bilibili.com/bangumi/play/ss5800'),
        const PgcRef(kind: PgcKind.ss, id: 5800),
      );
    });

    test('m. 前缀 + 分享 query 的番剧链接', () async {
      expect(
        await parsePgcRef(
            'https://m.bilibili.com/bangumi/play/ep98603?from=search&seid=1'),
        const PgcRef(kind: PgcKind.ep, id: 98603),
      );
    });

    test('夹杂标题文本的番剧链接', () async {
      expect(
        await parsePgcRef('【安利】这部番超好看 '
            'https://www.bilibili.com/bangumi/play/ss5800 快去看'),
        const PgcRef(kind: PgcKind.ss, id: 5800),
      );
    });

    test('裸 ep 号 / 裸 ss 号', () async {
      expect(await parsePgcRef('ep98603'),
          const PgcRef(kind: PgcKind.ep, id: 98603));
      expect(await parsePgcRef('ss5800'),
          const PgcRef(kind: PgcKind.ss, id: 5800));
      expect(await parsePgcRef('文本里的 ss5800 结尾'),
          const PgcRef(kind: PgcKind.ss, id: 5800));
    });

    test('b23.tv/ep|ss 番剧短码 → 本地取 id，不请求网络', () async {
      // adapter 无 finalLocation：若方法尝试发请求会抛连接错误 ——
      // 断言不请求即证明番剧短码无需网络重定向
      final adapter = _RedirectAdapter(finalLocation: null);
      final dio = _dioWith(adapter);
      expect(await parsePgcRef('https://b23.tv/ep98603', dio: dio),
          const PgcRef(kind: PgcKind.ep, id: 98603));
      expect(await parsePgcRef('b23.tv/ss5800', dio: dio),
          const PgcRef(kind: PgcKind.ss, id: 5800));
      expect(adapter.requests, isEmpty);
    });

    test('随机短码重定向到 bangumi → 提取 ep/ss', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse(
            'https://www.bilibili.com/bangumi/play/ep98603?from=search'),
      );
      expect(
        await parsePgcRef('https://b23.tv/spVKBAi', dio: _dioWith(adapter)),
        const PgcRef(kind: PgcKind.ep, id: 98603),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.toString(), 'https://b23.tv/spVKBAi');
    });

    test('随机短码重定向到 ss 整季', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('https://www.bilibili.com/bangumi/play/ss5800'),
      );
      expect(
        await parsePgcRef('b23.tv/abcdef', dio: _dioWith(adapter)),
        const PgcRef(kind: PgcKind.ss, id: 5800),
      );
    });

    test('随机短码重定向到普通视频 → 返回 null（交给 parseBvid）', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('https://www.bilibili.com/video/$_bv1'),
      );
      expect(
        await parsePgcRef('https://b23.tv/spVKBAi', dio: _dioWith(adapter)),
        isNull,
      );
    });

    test('纯 BV / 普通视频链接 → null（不误判为番剧）', () async {
      expect(await parsePgcRef(_bv1), isNull);
      expect(
        await parsePgcRef('https://www.bilibili.com/video/$_bv1?p=2'),
        isNull,
      );
      expect(await parsePgcRef('https://www.bilibili.com/'), isNull);
    });

    test('无法识别的文本 → null（不抛错）', () async {
      expect(await parsePgcRef('随便一段没有链接的文字'), isNull);
      expect(await parsePgcRef('   '), isNull);
    });

    test('extractPgcRefFromText 单词内嵌 ep/ss 不误命中', () {
      // step123 / ess123 / b23 随机码含 ep 但不带数字后缀 → 都不是番剧
      expect(extractPgcRefFromText('step1234'), isNull);
      expect(extractPgcRefFromText('ess1234'), isNull);
      expect(extractPgcRefFromText('b23.tv/spVKBAi'), isNull);
      // b23 番剧短码是独立 ep|ss+数字 → 命中
      expect(extractPgcRefFromText('b23.tv/ep98603'),
          const PgcRef(kind: PgcKind.ep, id: 98603));
    });
  });

  group('parseBvid 番剧防护', () {
    test('番剧完整链接 → 抛「番剧」提示而非「未识别」', () async {
      await expectLater(
        parseBvid('https://www.bilibili.com/bangumi/play/ep98603'),
        throwsA(isA<ImportParseException>().having(
          (e) => e.message,
          'message',
          contains('番剧/电影'),
        )),
      );
    });

    test('裸 ep 号 → 抛「番剧」提示', () async {
      await expectLater(
        parseBvid('ep98603'),
        throwsA(isA<ImportParseException>().having(
          (e) => e.message,
          'message',
          contains('番剧/电影'),
        )),
      );
    });

    test('随机短链重定向到番剧 → 抛「番剧」提示（而非短链解析失败）', () async {
      final adapter = _RedirectAdapter(
        finalLocation: Uri.parse('https://www.bilibili.com/bangumi/play/ss5800'),
      );
      await expectLater(
        parseBvid('https://b23.tv/spVKBAi', dio: _dioWith(adapter)),
        throwsA(isA<ImportParseException>().having(
          (e) => e.message,
          'message',
          contains('番剧/电影'),
        )),
      );
    });
  });
}
