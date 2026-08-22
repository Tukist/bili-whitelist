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
      // 请求确实打到短链
      expect(adapter.requests.single.uri.toString(), contains('b23.tv/spVKBAi'));
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
    expect(countLinkTokens('没有链接'), 0);
  });
}
