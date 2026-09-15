// fetchPlayUrl（x/player/wbi/playurl 取流）登录态注入 + qn=80 单测
// （mock dio adapter，不访问真实网络）：
// - 登录态（有效 SESSDATA）存在 → 取流请求带 Cookie: SESSDATA + buvid 指纹，
//   且 qn=80（1080P 期望）——「登录态下播放自动 1080P」链路断言
// - 匿名（无 SESSDATA）→ 请求不带 SESSDATA（保持匿名 720P 可播）
// - 残留已过期 SESSDATA → 不注入 + 清除失效凭据（v2.16.20，取流共用路径）
// - 服务端按登录态下发 quality=80（1080P）→ 解析结果 quality=80
//
// 注：真实「有效登录态 + 大会员 → 服务端真给 1080P」需真机真实账号验证；
// 本测试锁死「请求带有效 SESSDATA + qn=80」这一 App 能控制的部分。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

/// 内存版 secure storage。
Map<String, String> _store = {};

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

/// 按路径路由的 fake adapter（同 pgc_playurl_api_test）：记录请求。
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

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

/// nav 响应（拿 wbi_img → 签名 key，url 尾部 32 位文件名即 key）。
Map<String, dynamic> _navBody() => {
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/763f32ec5f8d47d2892e1ee6b6a2dd2c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/3a8d6e7b8fae4b1a9c8d3f2a1e5b4c6d.png',
        },
      },
    };

/// playurl 响应：登录态下发的 1080P DASH（quality=80，dash.video[]/audio[]）。
Map<String, dynamic> _playurlBody() => {
      'code': 0,
      'message': '0',
      'data': {
        'quality': 80,
        'format': 'dash',
        'timelength': 10000,
        'accept_quality': [80, 64, 32, 16],
        'dash': {
          'video': [
            {'baseUrl': 'https://upos.bilivideo.com/video_1080p.m4s'},
          ],
          // 两档音频，**高档在前**（2026-09 实测顺序不稳定）：
          // 「仅缓存音频」必须按 bandwidth 挑最低档，不能靠顺序
          'audio': [
            {
              'baseUrl': 'https://upos.bilivideo.com/audio_134k.m4s',
              'id': 30232,
              'bandwidth': 134000,
            },
            {
              'baseUrl': 'https://upos.bilivideo.com/audio_64k.m4s',
              'id': 30216,
              'bandwidth': 64000,
            },
          ],
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store = {};
    _mockSecureStorage();
  });

  const playurlPath = '/x/player/wbi/playurl';

  /// 构造有效 SESSDATA（未来 N 天过期，可被 sessdataExpireAt 解析的合成值）。
  String fakeSessdata(Duration validFor) {
    final expireSec =
        DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
    return '12345,$expireSec,${'a' * 32}';
  }

  group('fetchPlayUrl 登录态注入（qn=80）', () {
    test('登录态存在 → 取流带 SESSDATA + buvid 指纹，qn=80（1080P）', () async {
      _store['bili_sessdata'] = fakeSessdata(const Duration(days: 30));
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        playurlPath: _playurlBody,
      });

      final r = await _api(adapter).fetchPlayUrl(bvid: 'BV1xx', cid: 1, qn: 80);

      // 服务端按登录态下发的 quality=80（1080P）解析成功
      expect(r.quality, 80);
      expect(r.dashVideoUrls, isNotEmpty);

      final req = adapter.requests.lastWhere((p) => p.path == playurlPath);
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, contains('SESSDATA=${_store['bili_sessdata']}'));
      // 请求参数：qn=80 期望 1080P（实际下发由登录态决定）
      expect(req.queryParameters['qn'], '80');
      expect(req.queryParameters['bvid'], 'BV1xx');
    });

    test('匿名（无 SESSDATA）→ 不带 SESSDATA 保持匿名可播（720P），qn 仍 80',
        () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        playurlPath: _playurlBody,
      });

      final r = await _api(adapter).fetchPlayUrl(bvid: 'BV1xx', cid: 1, qn: 80);

      expect(r.hasStream, isTrue); // 匿名也能播（服务端给 720P 及以下）
      final req = adapter.requests.lastWhere((p) => p.path == playurlPath);
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, contains('buvid3=buvid3test'));
      expect(cookie, isNot(contains('SESSDATA=')));
      expect(req.queryParameters['qn'], '80');
    });

    test('残留已过期 SESSDATA → 取流不注入 + 清除失效凭据（v2.16.20 修复路径）',
        () async {
      // 2020 年已失效的合成值（结构可解析）
      _store['bili_sessdata'] =
          '12345,1609451400,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      _store['bili_jct'] = 'jct_stale';
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        playurlPath: _playurlBody,
      });

      final r = await _api(adapter).fetchPlayUrl(bvid: 'BV1xx', cid: 1, qn: 80);

      expect(r.hasStream, isTrue); // 回退匿名 → 仍可播
      final req = adapter.requests.lastWhere((p) => p.path == playurlPath);
      final cookie = req.headers['Cookie'] ?? '';
      expect(cookie, isNot(contains('SESSDATA=')));
      // 失效会话已被清除（后续请求不再携带死 cookie → 不再被 -101 拒绝）
      expect(_store.containsKey('bili_sessdata'), isFalse);
      expect(_store.containsKey('bili_jct'), isFalse);
      expect(req.queryParameters['qn'], '80');
    });
  });

  // ---------------------------------------------------------------------------
  // 音频档位（v2.29.0）：「仅缓存音频」靠 bandwidth 挑最低档
  // ---------------------------------------------------------------------------

  group('DASH 音频档位解析与选择', () {
    test('dash.audio 的 id/bandwidth 按序解析，与 url 一一对应', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/web-interface/nav': _navBody,
        playurlPath: _playurlBody,
      });

      final r = await _api(adapter).fetchPlayUrl(bvid: 'BV1xx', cid: 1, qn: 80);

      expect(r.dashAudioUrls, hasLength(2));
      expect(r.dashAudioIds, [30232, 30216]);
      expect(r.dashAudioBandwidths, [134000, 64000]);
      // 顺序不可信（高档在前）→ 「仅缓存音频」必须挑最小档
      expect(pickLowestBandwidthAudio(r), endsWith('audio_64k.m4s'));
      // 既有行为不变：整段缓存取第一条（高档）
      expect(r.dashAudioUrls.first, endsWith('audio_134k.m4s'));
    });

    test('缺 bandwidth / 全缺 → 退回第一条（与改动前一致）', () {
      const noBandwidth = PlayUrlResult(
        quality: 80,
        dashAudioUrls: ['a.m4s', 'b.m4s'],
      );
      expect(pickLowestBandwidthAudio(noBandwidth), 'a.m4s');

      const partial = PlayUrlResult(
        quality: 80,
        dashAudioUrls: ['unknown.m4s', 'known.m4s'],
        dashAudioBandwidths: [0, 128000],
      );
      expect(pickLowestBandwidthAudio(partial), 'known.m4s',
          reason: '缺码率的条目不参与比较，但不能挡住有码率的');

      const bandwidthsLongerThanUrls = PlayUrlResult(
        quality: 80,
        dashAudioUrls: ['only.m4s'],
        dashAudioBandwidths: [64000, 128000],
      );
      expect(pickLowestBandwidthAudio(bandwidthsLongerThanUrls), 'only.m4s',
          reason: '两个列表长度不一致时不越界');
    });

    test('没有音频流 → null（仅音频下载据此报「没有可下载的音频流」）', () {
      const mp4Only = PlayUrlResult(
        quality: 32,
        mp4Url: 'https://x.bilivideo.com/v.mp4',
      );
      expect(pickLowestBandwidthAudio(mp4Only), isNull);
    });

    test('多条同码率 → 取先出现的那条（稳定，不吃列表顺序）', () {
      const tie = PlayUrlResult(
        quality: 80,
        dashAudioUrls: ['first.m4s', 'second.m4s'],
        dashAudioBandwidths: [64000, 64000],
      );
      expect(pickLowestBandwidthAudio(tie), 'first.m4s');
    });
  });
}
