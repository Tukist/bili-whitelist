// BiliApi 字幕接口单元测试（mock dio）：
// - fetchSubtitles：请求参数（WBI 签名 + bvid/cid）、登录态 Cookie 注入、
//   无字幕返回空、错误分类（-101 / -352 / -412 重试 / 网络失败）
// - downloadSubtitle：// 补 https、防盗链 Referer+UA、解析、内存缓存去重
// 不访问真实网络。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/subtitle.dart';

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

/// 按路径路由的 fake adapter：记录请求，返回预置 body。
class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];

  _RoutingAdapter(this.handlers);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
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

/// 抛连接错误的 adapter（模拟断网）。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

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

Map<String, dynamic> _subtitleBody({int code = 0, List? subtitles}) => {
      'code': code,
      'message': code == 0 ? 'OK' : '业务错误',
      'data': {
        'subtitle': {'subtitles': subtitles ?? []},
      },
    };

Map<String, dynamic> _oneTrack() => {
      'lan': 'ai-zh',
      'lan_doc': '中文（自动生成）',
      'subtitle_url': '//i0.hdslb.com/bfs/subtitle/zh.json',
    };

const _subtitleFileUrl = 'https://i0.hdslb.com/bfs/subtitle/zh.json';

Map<String, dynamic> _subtitleFileBody() => {
      'font_size': 0.4,
      'body': [
        {'from': 0.0, 'to': 2.0, 'content': '你好，世界'},
        {'from': 2.0, 'to': 4.0, 'content': '第二句字幕'},
      ],
    };

Map<String, dynamic> _playV2Body({int code = 0, List? subtitles}) => {
      'code': code,
      'message': code == 0 ? 'OK' : '错误',
      'data': {
        'aid': 1,
        'subtitle': {'subtitles': subtitles ?? []},
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  group('fetchSubtitles', () {
    test('请求参数（bvid/cid + WBI 签名）与轨道解析', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/player/wbi/v2': () =>
            _subtitleBody(subtitles: [_oneTrack(), {
              'lan': 'ai-en',
              'lan_doc': '英文（自动生成）',
              'subtitle_url': '//i0.hdslb.com/bfs/subtitle/en.json',
            }]),
      });
      final api = _api(adapter);

      final tracks = await api.fetchSubtitles('BV1xx', 1234);

      final req = adapter.requests
          .lastWhere((r) => r.path == '/x/player/wbi/v2');
      expect(req.queryParameters['bvid'], 'BV1xx');
      expect(req.queryParameters['cid'], '1234');
      expect(req.queryParameters['w_rid'], isNotEmpty);
      expect(req.queryParameters['wts'], isNotEmpty);
      expect(req.queryParameters['dm_img_list'], '[]');

      expect(tracks, hasLength(2));
      expect(tracks[0].lan, 'ai-zh');
      expect(tracks[0].lanDoc, '中文（自动生成）');
      expect(tracks[0].subtitleUrl, startsWith('//'));
      expect(tracks[1].lan, 'ai-en');
    });

    test('登录态存在时 Cookie 头注入 SESSDATA（含 buvid 指纹）', () async {
      _store['bili_sessdata'] = 'sessdata_test_value';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/player/wbi/v2': () => _subtitleBody(),
      });
      final api = _api(adapter);

      await api.fetchSubtitles('BV1xx', 1);

      final req = adapter.requests
          .lastWhere((r) => r.path == '/x/player/wbi/v2');
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('SESSDATA=sessdata_test_value'));
    });

    test('subtitles 缺失/为空 → 返回空列表（无字幕）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/player/wbi/v2': () => _playV2Body(),
      });
      expect(await _api(adapter).fetchSubtitles('BV1xx', 1), isEmpty);
    });

    test('-101 未登录 → 抛 BiliApiException(-101)', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/player/wbi/v2': () => _subtitleBody(code: -101),
      });
      expect(
        () => _api(adapter).fetchSubtitles('BV1xx', 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -101)
            .having((e) => e.message, 'message', contains('登录'))),
      );
    });

    test('-352 限流 → 抛 BiliApiException(-352)', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/player/wbi/v2': () => _subtitleBody(code: -352),
      });
      expect(
        () => _api(adapter).fetchSubtitles('BV1xx', 1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -352)
            .having((e) => e.message, 'message', contains('限流'))),
      );
    });

    test('-412 首次 → 刷新 WBI key 重试一次成功', () async {
      var callCount = 0;
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        '/x/player/wbi/v2': () {
          callCount++;
          return callCount == 1
              ? _subtitleBody(code: -412)
              : _subtitleBody(subtitles: [_oneTrack()]);
        },
      });
      final api = _api(adapter);

      final tracks = await api.fetchSubtitles('BV1xx', 1);

      expect(callCount, 2);
      expect(tracks, hasLength(1));
      final v2Requests =
          adapter.requests.where((r) => r.path == '/x/player/wbi/v2');
      expect(v2Requests, hasLength(2));
    });

    test('网络连接失败 → 抛 DioException', () async {
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(
        () => BiliApi(dio: dio).fetchSubtitles('BV1xx', 1),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('downloadSubtitle', () {
    test('// 补 https + 防盗链头 + 解析 cue', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        _subtitleFileUrl: _subtitleFileBody,
      });
      final api = _api(adapter);
      final track = SubtitleTrack.fromJson(_oneTrack());

      final cues = await api.downloadSubtitle(track,
          bvid: 'BV1xx', cid: 1234);

      expect(cues, hasLength(2));
      expect(cues[0].content, '你好，世界');
      expect(cues[0].from, 0.0);
      expect(cues[0].to, 2.0);
      expect(cues[1].content, '第二句字幕');

      final req = adapter.requests.last;
      expect(req.uri.toString(), _subtitleFileUrl); // 补了 https:
      expect(req.headers['Referer'], kBiliReferer);
      expect(req.headers['User-Agent'], kBrowserUA);
    });

    test('同 bvid_cid_lan 缓存去重（第二次不重新下载）', () async {
      var downloadCount = 0;
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        _subtitleFileUrl: () {
          downloadCount++;
          return _subtitleFileBody();
        },
      });
      final api = _api(adapter);
      final track = SubtitleTrack.fromJson(_oneTrack());

      final first = await api.downloadSubtitle(track,
          bvid: 'BV1xx', cid: 1234);
      final second = await api.downloadSubtitle(track,
          bvid: 'BV1xx', cid: 1234);

      expect(first, hasLength(2));
      expect(identical(first, second), isTrue); // 同一缓存实例
      expect(downloadCount, 1);
    });

    test('字幕文件是非法 JSON → 返回空列表（不抛）', () async {
      // 直接替换 fetch 行为：返回非 JSON 文本
      final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      dio.httpClientAdapter = _TextAdapter();
      final api = BiliApi(dio: dio);
      final track = SubtitleTrack.fromJson({
        'lan': 'ai-zh',
        'lan_doc': '中文',
        'subtitle_url': 'https://i0.hdslb.com/bfs/subtitle/bad.json',
      });

      expect(
        await api.downloadSubtitle(track, bvid: 'BV1xx', cid: 1),
        isEmpty,
      );
    });
  });
}

/// 返回固定文本的 adapter（模拟字幕文件响应体，测试非法 JSON 容错）。
class _TextAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(
      'this is not json {',
      200,
      headers: {
        'content-type': ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
