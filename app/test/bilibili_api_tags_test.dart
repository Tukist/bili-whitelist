// BiliApi.fetchVideoTags 单测（mock dio，不访问真实网络）。
//
// 覆盖：
// - 请求构造：`/x/tag/archive/tags` + bvid，**不需要 WBI 签名**（query 里
//   没有 w_rid/wts；匿名 buvid 指纹照常注入）
// - 解析：`data[].tag_name` 去空 / 去重 / 脏类型跳过 / 上限 20
// - 空数组 / data 不是 List → 空列表（不崩）
// - -412 / -352：先刷一次 WBI key 重试一次；两次都被拦 → 抛 BiliApiException
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

const String _kTagsPath = '/x/tag/archive/tags';
const String _kNavPath = '/x/web-interface/nav';
const String _kSpiPath = '/x/frontend/finger/spi';

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
}

/// 记录请求并按路径应答的假适配器（与 article_api_test 同款）。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final handler = handlers[options.path];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(handler(options)),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _spiBody(RequestOptions _) => {
  'code': 0,
  'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
};

Map<String, dynamic> _navBody(RequestOptions _) => {
  'code': 0,
  'data': {
    'wbi_img': {
      'img_url':
          'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
      'sub_url':
          'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
    },
  },
};

Map<String, dynamic> _tagsBody(List<dynamic> items, {int code = 0}) => {
  'code': code,
  if (code != 0) 'message': '风控了',
  'data': items,
};

BiliApi _api(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockSecureStorage);

  group('fetchVideoTags', () {
    test('请求构造：不需要 WBI 签名；解析 tag_name 去空去重', () async {
      final adapter = _RecordingAdapter({
        _kSpiPath: _spiBody,
        _kTagsPath: (_) => _tagsBody([
          {'tag_name': '动画'},
          {'tag_name': ' 日常 '},
          {'tag_name': ''},
          {'tag_name': '动画'}, // 重复
          {'tag_name': 123}, // 脏类型
          {'tag_id': 7}, // 缺字段
        ]),
      });
      final api = _api(adapter);

      final tags = await api.fetchVideoTags('BV1xx411c7mD');

      expect(tags, ['动画', '日常']);
      final req = adapter.forPath(_kTagsPath).single;
      expect(req.queryParameters['bvid'], 'BV1xx411c7mD');
      // 没有 WBI 签名参数，也没有请求 nav 拿 key
      expect(req.queryParameters.containsKey('w_rid'), isFalse);
      expect(req.queryParameters.containsKey('wts'), isFalse);
      expect(adapter.forPath(_kNavPath), isEmpty);
    });

    test('data 不是 List / 为空 → 空列表（不崩）', () async {
      final adapter = _RecordingAdapter({
        _kSpiPath: _spiBody,
        _kTagsPath: (_) => {'code': 0, 'data': null},
      });
      expect(await _api(adapter).fetchVideoTags('BV1xx411c7mD'), isEmpty);

      final adapter2 = _RecordingAdapter({
        _kSpiPath: _spiBody,
        _kTagsPath: (_) => _tagsBody(const []),
      });
      expect(await _api(adapter2).fetchVideoTags('BV1xx411c7mD'), isEmpty);
    });

    test('上限 20 个（多余的截断）', () async {
      final adapter = _RecordingAdapter({
        _kSpiPath: _spiBody,
        _kTagsPath: (_) => _tagsBody([
          for (var i = 0; i < 30; i++) {'tag_name': '标签$i'},
        ]),
      });
      final tags = await _api(adapter).fetchVideoTags('BV1xx411c7mD');
      expect(tags.length, BiliApi.kMaxVideoTags);
      expect(tags.first, '标签0');
      expect(tags.last, '标签19');
    });

    test('-412：刷新 WBI key 后重试一次；两次都被拦 → 抛 BiliApiException', () async {
      final adapter = _RecordingAdapter({
        _kSpiPath: _spiBody,
        _kNavPath: _navBody,
        _kTagsPath: (_) => _tagsBody(const [], code: -412),
      });
      final api = _api(adapter);

      await expectLater(
        api.fetchVideoTags('BV1xx411c7mD'),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -412)
              .having((e) => e.message, 'message', contains('风控')),
        ),
      );
      // 两次 tag 请求（第二次带刷新后的 key）+ 一次 nav
      expect(adapter.forPath(_kTagsPath).length, 2);
      expect(adapter.forPath(_kNavPath).length, 1);
    });

    test('-352：同样重试一次后抛异常（带码与可读文案）', () async {
      final adapter = _RecordingAdapter({
        _kSpiPath: _spiBody,
        _kNavPath: _navBody,
        _kTagsPath: (_) => _tagsBody(const [], code: -352),
      });
      await expectLater(
        _api(adapter).fetchVideoTags('BV1xx411c7mD'),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -352)
              .having((e) => e.path, 'path', _kTagsPath),
        ),
      );
      expect(adapter.forPath(_kTagsPath).length, 2);
    });
  });
}
