// BiliApi.fetchUserDynamics 单元测试（mock dio，不访问真实网络）：
// - 请求构造：WBI 签名（w_rid/wts）+ buvid3/buvid4 Cookie + host_mid /
//   features=itemOpusStyle / platform=web / timezone_offset=-480
// - 解析：items[] → DynamicItem；data.offset + has_more → nextOffset / hasMore
// - offset 游标分页：第二页把上一页游标原样回传；has_more=false 时游标作废
// - 间歇空页（code=0 但 items 空且 has_more=false）→ 自动重试一次（实测风控
//   软返回；真到底时只是多打一次空请求）
// - -412 → 刷新 WBI key 后重签重试一次；两次都 -412 → BiliApiException(风控)
// - -352 → BiliApiException(限流)；其它业务码 → 带 message 的 BiliApiException
// - 脏 data（null / items 非 List / 空 id 条目）不崩，按空页处理
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/dynamic_item.dart';

const String _kFeedPath = '/x/polymer/web-dynamic/v1/feed/space';

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
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
      jsonEncode(handler()),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

/// 匿名 nav：code=-101 但 wbi_img 照给（与线上一致；_ensureWbiKeys 只取 wbi_img）。
Map<String, dynamic> _navBody() => {
      'code': -101,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

Map<String, dynamic> _item(String id, {String text = '动态正文'}) => {
      'id_str': id,
      'type': DynamicType.draw,
      'modules': {
        'module_author': {
          'name': '测试UP',
          'face': '//i0.hdslb.com/bfs/face/f.jpg',
          'pub_ts': 1730000000,
        },
        'module_dynamic': {
          'desc': {'text': text},
          'major': {
            'draw': {
              'items': [
                {'src': '//i0.hdslb.com/d.jpg'},
              ],
            },
          },
        },
      },
    };

Map<String, dynamic> _feedBody({
  List<Map<String, dynamic>>? items,
  String offset = '',
  bool hasMore = false,
  int code = 0,
  String? message,
}) =>
    {
      'code': code,
      if (message != null) 'message': message,
      'data': {
        'items': items ?? <Map<String, dynamic>>[],
        'offset': offset,
        'has_more': hasMore,
      },
    };

BiliApi _api(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockSecureStorage);

  test('首屏：WBI 签名 + buvid Cookie + 固定参数；解析 items/游标', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => _feedBody(
            items: [_item('111'), _item('222', text: '第二条')],
            offset: 'cursor-2',
            hasMore: true,
          ),
    });
    final api = _api(adapter);

    final page = await api.fetchUserDynamics(546195);

    expect(page.items.map((d) => d.id), ['111', '222']);
    expect(page.items.first.text, '动态正文');
    expect(page.items.first.authorName, '测试UP');
    expect(page.items.first.authorFace, 'https://i0.hdslb.com/bfs/face/f.jpg');
    expect(page.items.first.imageUrls, ['https://i0.hdslb.com/d.jpg']);
    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 'cursor-2');

    final req = adapter.forPath(_kFeedPath).single;
    final q = req.queryParameters;
    expect(q['host_mid'], '546195');
    expect(q['features'], 'itemOpusStyle');
    expect(q['platform'], 'web');
    expect(q['timezone_offset'], '-480');
    expect(q['w_rid'], isNotEmpty);
    expect(q['wts'], isNotEmpty);
    expect(q.containsKey('offset'), isFalse, reason: '首屏不传游标');
    final cookie = req.headers['Cookie'] as String? ?? '';
    expect(cookie, contains('buvid3=buvid3test'));
    expect(cookie, contains('buvid4=buvid4test'));
  });

  test('offset 游标分页：第二页原样回传游标；has_more=false 时游标作废', () async {
    var feedCalls = 0;
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () {
        feedCalls++;
        return feedCalls == 1
            ? _feedBody(items: [_item('1')], offset: 'cursor-2', hasMore: true)
            : _feedBody(
                items: [_item('2')],
                // 到底：服务端仍回一个游标，但 has_more=false
                offset: 'cursor-3',
                hasMore: false,
              );
      },
    });
    final api = _api(adapter);

    final first = await api.fetchUserDynamics(1);
    expect(first.hasMore, isTrue);

    final second = await api.fetchUserDynamics(1, offset: first.nextOffset);
    expect(second.items.map((d) => d.id), ['2']);
    expect(second.hasMore, isFalse);
    expect(second.nextOffset, '', reason: '到底后游标作废（不再回传）');

    final reqs = adapter.forPath(_kFeedPath);
    expect(reqs, hasLength(2));
    expect(reqs[1].queryParameters['offset'], 'cursor-2');
  });

  test('间歇空页（code=0 但 items 空且 has_more=false）→ 自动重试一次', () async {
    var feedCalls = 0;
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () {
        feedCalls++;
        // 第一次：风控软返回（空页 + 无更多）；第二次：正常给一条
        return feedCalls == 1
            ? _feedBody()
            : _feedBody(items: [_item('7')], hasMore: false);
      },
    });
    final api = _api(adapter);

    final page = await api.fetchUserDynamics(1);

    expect(page.items.map((d) => d.id), ['7']);
    expect(adapter.forPath(_kFeedPath), hasLength(2), reason: '空页重试一次');
  });

  test('连续两次空页 → 返回空页（不无限重试）', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => _feedBody(),
    });
    final api = _api(adapter);

    final page = await api.fetchUserDynamics(1);

    expect(page.isEmpty, isTrue);
    expect(page.hasMore, isFalse);
    expect(adapter.forPath(_kFeedPath), hasLength(2));
  });

  test('-412 → 刷新 WBI key 后重签重试一次，成功返回', () async {
    var feedCalls = 0;
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () {
        feedCalls++;
        return feedCalls == 1
            ? _feedBody(code: -412, message: '风控')
            : _feedBody(items: [_item('9')]);
      },
    });
    final api = _api(adapter);

    final page = await api.fetchUserDynamics(1);

    expect(page.items.map((d) => d.id), ['9']);
    expect(adapter.forPath(_kFeedPath), hasLength(2));
    expect(adapter.forPath('/x/web-interface/nav'), hasLength(2),
        reason: '首次取 key + -412 后刷新 key 各一次');
    // 重签：第二次请求的 wts/w_rid 是新签的（都非空即视为已重签）
    expect(adapter.forPath(_kFeedPath)[1].queryParameters['w_rid'], isNotEmpty);
  });

  test('-412 两次 → 抛 BiliApiException（风控文案）', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => _feedBody(code: -412, message: '风控'),
    });
    final api = _api(adapter);

    await expectLater(
      api.fetchUserDynamics(1),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -412)
          .having((e) => e.message, 'message', contains('风控'))),
    );
    expect(adapter.forPath(_kFeedPath), hasLength(2));
  });

  test('-352 → 抛 BiliApiException（限流文案）', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => _feedBody(code: -352, message: '被限流'),
    });
    final api = _api(adapter);

    await expectLater(
      api.fetchUserDynamics(1),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -352)
          .having((e) => e.message, 'message', contains('限流'))),
    );
  });

  test('其它业务码 → 抛 BiliApiException，带服务端 message', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => _feedBody(code: -400, message: '请求错误'),
    });
    final api = _api(adapter);

    await expectLater(
      api.fetchUserDynamics(1),
      throwsA(isA<BiliApiException>()
          .having((e) => e.code, 'code', -400)
          .having((e) => e.message, 'message', '请求错误')),
    );
  });

  test('脏 data（null / items 非 List / 空 id 条目）不崩，按空页处理', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => {
            'code': 0,
            'data': {
              'items': [
                {'id_str': '', 'type': 'DYNAMIC_TYPE_WORD'},
                {'modules': <String, dynamic>{}},
                _item('keep'),
              ],
              'offset': 0,
              'has_more': false,
            },
          },
    });
    final api = _api(adapter);

    final page = await api.fetchUserDynamics(1);

    expect(page.items.map((d) => d.id), ['keep'], reason: '空 id 脏条目丢弃');
    expect(page.nextOffset, '');
    expect(page.hasMore, isFalse);
  });

  test('data 整个缺失 → 空页（不抛）', () async {
    final adapter = _RecordingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      _kFeedPath: () => {'code': 0},
    });
    final api = _api(adapter);

    final page = await api.fetchUserDynamics(1);

    expect(page.isEmpty, isTrue);
    expect(page.hasMore, isFalse);
  });
}
