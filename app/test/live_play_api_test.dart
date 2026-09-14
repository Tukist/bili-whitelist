// 直播取流（v2.27.0+）测试：`getRoomPlayInfo` 的选流 / 拼地址 / 失败静默。
//
// 覆盖（全是实测踩过或最容易写错的点）：
// - **选流优先级**：http_hls/fmp4/avc → http_hls/ts/avc → …→ 任意 http_hls →
//   http_stream（flv 兜底，ExoPlayer 原生不支持，只保证"有地址"）；
// - **base_url 在 codec 层**（不在 url_info 里！），完整地址 = host + base_url + extra；
// - **url_info 是长度 2 的列表**（互为备份的 CDN host）：[0] 拼不出来要回退 [1]；
// - **live_status 读 data.live_status**（`data.room_info` 实测为 null）：
//   只有 1 才给地址，未开播（0）/ 轮播（2）一律不给；
// - **过期时间**：地址 query 的 expires 优先，stream_ttl 兜底（续期定时器靠它）；
// - **HTTP 层**：绝对 URL 打到 api.live.bilibili.com（不是 api.bilibili.com）、
//   参数按探针结论、Referer 必须是该直播间；失败/脏数据 → null 不抛。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/live_play_info.dart';

const String _kPlayInfoPath = '/xlive/web-room/v2/index/getRoomPlayInfo';
const String _kSpiPath = '/x/frontend/finger/spi';

// ---------------------------------------------------------------------------
// mock HTTP（与 test/live_status_test.dart 同一套写法）
// ---------------------------------------------------------------------------

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];

  /// 按**路径**取请求：绝对 URL 下 `RequestOptions.path` 是完整 URL，
  /// 而 `uri.path` 才是 `/xlive/...`——两个都要看，否则会把请求当「no handler」
  /// 返回 404，用例拿到 null 也符合「失败静默」→ **假绿**。
  List<RequestOptions> forPath(String path) => requests
      .where((r) => r.path == path || r.uri.path == path)
      .toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final h = handlers[options.path] ?? handlers[options.uri.path];
    if (h == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(h(options)),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 断网 adapter。
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'Connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

// ---------------------------------------------------------------------------
// 响应样本构造（字段位置严格照实测：base_url 在 codec 层）
// ---------------------------------------------------------------------------

Map<String, dynamic> _urlInfo({
  String host = 'https://cdn1.mcdn.bilivideo.cn:8082',
  String extra = 'expires=1800000000&len=0&oi=1&pt=web&qn=10000&sig=abc',
  int ttl = 3500,
  bool withOwnBaseUrl = false,
}) =>
    {
      'host': host,
      'extra': extra,
      'stream_ttl': ttl,
      // 部分响应里 url_info 也带一个 base_url（实测**不是**拼地址用的那个）；
      // 用它来证明我们取的是 codec 层那份
      if (withOwnBaseUrl) 'base_url': '/WRONG/from-url_info.m3u8?',
    };

Map<String, dynamic> _codec({
  String name = 'avc',
  String baseUrl = '/live-bvc/123/live.m3u8?',
  List<Map<String, dynamic>>? urlInfos,
  int qn = 10000,
}) =>
    {
      'codec_name': name,
      'base_url': baseUrl,
      'current_qn': qn,
      'url_info': urlInfos ?? [_urlInfo()],
    };

Map<String, dynamic> _format({
  String name = 'fmp4',
  List<Map<String, dynamic>>? codecs,
}) =>
    {'format_name': name, 'codec': codecs ?? [_codec()]};

Map<String, dynamic> _stream({
  String protocol = 'http_hls',
  List<Map<String, dynamic>>? formats,
}) =>
    {'protocol_name': protocol, 'format': formats ?? [_format()]};

/// `getRoomPlayInfo` 响应。
///
/// `data.room_info` 特意放 null：实测就是这个值，代码若去读
/// `room_info.live_status` 就会空指针——样本要把这个坑一起带上。
Map<String, dynamic> _body({
  int code = 0,
  int liveStatus = 1,
  List<Map<String, dynamic>>? streams,
  Map<String, dynamic>? data,
}) =>
    {
      'code': code,
      if (code != 0) 'message': 'boom',
      'data': data ??
          {
            'live_status': liveStatus,
            'room_info': null,
            'playurl_info': {
              'playurl': {
                'stream': streams ??
                    [
                      _stream(
                        protocol: 'http_hls',
                        formats: [
                          _format(name: 'fmp4', codecs: [_codec()]),
                        ],
                      ),
                    ],
              },
            },
          },
    };

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void _mockSecureStorage() {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    return null;
  });
}

/// 取流响应里的 `data`（纯函数用例直接喂它）。
Map<String, dynamic> _data(
  List<Map<String, dynamic>> streams, {
  int liveStatus = 1,
}) =>
    {
      'live_status': liveStatus,
      'room_info': null,
      'playurl_info': {
        'playurl': {'stream': streams},
      },
    };

void main() {
  // 本文件只有 test()（无 testWidgets），binding 不会被自动初始化——
  // 而 secure_storage 的通道 mock 需要它
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockSecureStorage);

  group('pickLiveStream：选流优先级与拼地址（纯函数）', () {
    test('fmp4 优先于 ts（同为 http_hls/avc）', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            protocol: 'http_hls',
            formats: [
              _format(
                name: 'ts',
                codecs: [_codec(baseUrl: '/ts.m3u8?')],
              ),
            ],
          ),
          _stream(
            protocol: 'http_hls',
            formats: [
              _format(
                name: 'fmp4',
                codecs: [_codec(baseUrl: '/fmp4.m3u8?')],
              ),
            ],
          ),
        ]),
      );

      expect(info, isNotNull);
      expect(info!.formatName, 'fmp4', reason: '实测 http_hls/ts 的 CDN host DNS 不通');
      expect(info.protocolName, 'http_hls');
      expect(info.hlsUrl, contains('/fmp4.m3u8'));
      expect(info.hlsUrl, isNot(contains('/ts.m3u8')));
      expect(info.quality, 10000);
      expect(info.isLive, isTrue);
    });

    test('base_url 取自 codec 层（url_info 里那份不算数）', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(
                  baseUrl: '/live-bvc/1/real.m3u8?',
                  urlInfos: [_urlInfo(withOwnBaseUrl: true)],
                ),
              ]),
            ],
          ),
        ]),
      );

      expect(info!.hlsUrl, startsWith('https://cdn1.mcdn.bilivideo.cn:8082'));
      expect(info.hlsUrl, contains('/live-bvc/1/real.m3u8'));
      expect(info.hlsUrl, isNot(contains('WRONG')),
          reason: 'base_url 在 codec 层，url_info 里那份是干扰项');
      // 完整地址 = host + base_url + extra（纯字符串拼接）
      expect(
        info.hlsUrl,
        'https://cdn1.mcdn.bilivideo.cn:8082/live-bvc/1/real.m3u8?'
        'expires=1800000000&len=0&oi=1&pt=web&qn=10000&sig=abc',
      );
    });

    test('base_url 不带结尾 ? 时补一个（防御）', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(baseUrl: '/live-bvc/1/x.m3u8', urlInfos: [
                  _urlInfo(extra: 'expires=1800000000&sig=abc'),
                ]),
              ]),
            ],
          ),
        ]),
      );

      expect(info!.hlsUrl, contains('/live-bvc/1/x.m3u8?expires=1800000000'));
    });

    test('extra 为空：地址不拖一个多余的 ?', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(baseUrl: '/live-bvc/1/x.m3u8?', urlInfos: [
                  _urlInfo(extra: ''),
                ]),
              ]),
            ],
          ),
        ]),
      );

      expect(info!.hlsUrl, 'https://cdn1.mcdn.bilivideo.cn:8082/live-bvc/1/x.m3u8?');
    });

    test('url_info[0] host 为空 → 回退 url_info[1]', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(urlInfos: [
                  _urlInfo(host: '', extra: 'expires=1'),
                  _urlInfo(host: 'https://backup.cdn.cn', extra: 'expires=2'),
                ]),
              ]),
            ],
          ),
        ]),
      );

      expect(info!.host, 'https://backup.cdn.cn');
      expect(info.hlsUrl, startsWith('https://backup.cdn.cn'));
      expect(info.hlsUrl, contains('expires=2'));
    });

    test('两个 url_info 都拿不到 host → 地址留空（isLive=false，不喂半截地址）', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(urlInfos: [
                  _urlInfo(host: '', extra: 'a'),
                  _urlInfo(host: '', extra: 'b'),
                ]),
              ]),
            ],
          ),
        ]),
      );

      expect(info!.hlsUrl, '');
      expect(info.isLive, isFalse);
    });

    test('host 不带 scheme（防御）→ 补 https://', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(urlInfos: [_urlInfo(host: 'cdn.example.com')]),
              ]),
            ],
          ),
        ]),
      );

      expect(info!.hlsUrl, startsWith('https://cdn.example.com'));
    });

    test('没有 http_hls → 兜底 http_stream（FLV，ExoPlayer 不支持，仅保证有地址）', () {
      final info = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            protocol: 'http_stream',
            formats: [
              _format(
                name: 'flv',
                codecs: [_codec(baseUrl: '/live-bvc/1/x.flv?')],
              ),
            ],
          ),
        ]),
      );

      expect(info!.hlsUrl, contains('/live-bvc/1/x.flv'));
      expect(info.protocolName, 'http_stream');
      expect(info.formatName, 'flv');
      expect(info.isLive, isTrue, reason: '有地址就算可取（播放由原生侧兜底）');
    });

    test('一条流都没有 → 地址空、isLive=false（不抛）', () {
      final info = BiliApi.pickLiveStream(1, _data([]));
      expect(info, isNotNull);
      expect(info!.hlsUrl, '');
      expect(info.isLive, isFalse);
    });

    test('live_status != 1（未开播 / 轮播）→ 不给地址，isLive=false', () {
      for (final status in [0, 2]) {
        final info = BiliApi.pickLiveStream(1, _data([
          _stream(
            formats: [
              _format(codecs: [_codec()]),
            ],
          ),
        ], liveStatus: status));
        expect(info, isNotNull);
        expect(info!.liveStatus, status);
        expect(info.hlsUrl, '', reason: '未开播/轮播不该拿旧地址去喂播放器');
        expect(info.isLive, isFalse);
      }
    });

    test('live_status 从 data.live_status 读（room_info 是 null 也不崩）', () {
      // 样本里 room_info = null：读 room_info.live_status 会直接抛
      final info = BiliApi.pickLiveStream(1, _data([
        _stream(),
      ]));
      expect(info!.liveStatus, 1);
      expect(info.isLive, isTrue);
    });

    test('结构变形（format/codec/url_info 全是脏数据）→ 不抛，地址空', () {
      final dirty = <String, dynamic>{
        'live_status': '1',
        'room_info': null,
        'playurl_info': {
          'playurl': {
            'stream': [
              'not-a-map',
              {'protocol_name': 42, 'format': 'not-a-list'},
              {
                'protocol_name': 'http_hls',
                'format': [
                  'not-a-map',
                  {'format_name': 7, 'codec': 'nope'},
                  {
                    'format_name': 'fmp4',
                    'codec': [
                      null,
                      {'codec_name': 'avc', 'url_info': 'nope'},
                    ],
                  },
                ],
              },
            ],
          },
        },
      };
      final info = BiliApi.pickLiveStream(1, dirty);
      expect(info, isNotNull);
      expect(info!.hlsUrl, '');
      expect(info.isLive, isFalse);
    });

    test('data 根本不是 Map → null（模型层兜底）', () {
      expect(LivePlayInfo.fromPlayInfo(1, 'not-a-map'), isNull);
      expect(LivePlayInfo.fromPlayInfo(1, null), isNull);
    });

    test('过期时间：query 的 expires 优先；没有则用 stream_ttl；都没有 → 0', () {
      final withExpires = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(urlInfos: [_urlInfo(extra: 'expires=1800000000', ttl: 99)]),
              ]),
            ],
          ),
        ]),
      );
      expect(withExpires!.expiresAtEpochSec, 1800000000);
      expect(withExpires.hasExpiry, isTrue);
      expect(withExpires.remaining()!.inSeconds, greaterThan(0));

      // 没有 expires/deadline → 按 stream_ttl 从现在起算
      final withTtl = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(urlInfos: [_urlInfo(extra: 'sig=abc', ttl: 3509)]),
              ]),
            ],
          ),
        ]),
      );
      final remain = withTtl!.remaining()!.inSeconds;
      expect(remain, inInclusiveRange(3500, 3509));

      // 两者都没有 → 0（页面按固定时长兜底续期）
      final none = BiliApi.pickLiveStream(
        1,
        _data([
          _stream(
            formats: [
              _format(codecs: [
                _codec(urlInfos: [_urlInfo(extra: 'sig=abc', ttl: 0)]),
              ]),
            ],
          ),
        ]),
      );
      expect(none!.expiresAtEpochSec, 0);
      expect(none.hasExpiry, isFalse);
      expect(none.refreshDelay, kLiveUrlRefreshMaxDelay, reason: '没有过期时间按上限兜底');
    });

    test('续期等待时间：剩余 11 分钟 → 约 1 分钟（提前 10 分钟换流，夹在下限）', () {
      final now = DateTime.now();
      final info = LivePlayInfo(
        roomId: 1,
        liveStatus: 1,
        hlsUrl: 'https://x/y.m3u8?sig=1',
        expiresAtEpochSec:
            now.millisecondsSinceEpoch ~/ 1000 + 11 * 60,
      );
      expect(info.isExpiring(), isFalse, reason: '还剩 11 分钟，不急');
      expect(info.refreshDelay.inSeconds, inInclusiveRange(55, 60));
    });
  });

  group('fetchLivePlayUrl：绝对 URL + 参数 + 失败静默', () {
    test('请求打到 api.live.bilibili.com 的绝对 URL，参数/Referer 按探针结论', () async {
      final adapter = _Adapter({
        _kSpiPath: (_) => {
              'code': 0,
              'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
            },
        _kPlayInfoPath: (_) => _body(),
      });
      final info = await _api(adapter).fetchLivePlayUrl(21452505);

      expect(info, isNotNull);
      expect(info!.isLive, isTrue);
      expect(info.roomId, 21452505);

      final req = adapter.forPath(_kPlayInfoPath).single;
      expect(req.method, 'GET');
      expect(req.uri.host, 'api.live.bilibili.com',
          reason: '直播接口在直播域名上；打到 api.bilibili.com 会 404 并被静默吞掉');
      expect(req.uri.host, isNot('api.bilibili.com'));
      expect(req.uri.path, _kPlayInfoPath);
      expect(req.baseUrl, kBiliApi, reason: '靠绝对 URL 定向，不改全局 baseUrl');
      expect(req.queryParameters, {
        'room_id': '21452505',
        'protocol': '0,1',
        'format': '0,1,2',
        'codec': '0,1',
        'qn': '10000',
        'platform': 'web',
        'ptype': '8',
        'dolby': '5',
        'panorama': '1',
      });
      expect(req.headers['Referer'], 'https://live.bilibili.com/21452505',
          reason: '防盗链：Referer 必须是**该直播间**');
    });

    test('qn 可指定（默认 10000 = 原画）', () async {
      final adapter = _Adapter({
        _kPlayInfoPath: (_) => _body(),
      });
      await _api(adapter).fetchLivePlayUrl(1, qn: 400);
      expect(adapter.forPath(_kPlayInfoPath).single.queryParameters['qn'], '400');
    });

    test('业务码非 0 / 无 data / roomId 非法 → null（不抛）', () async {
      final bad = _Adapter({
        _kPlayInfoPath: (_) => _body(code: -352),
      });
      expect(await _api(bad).fetchLivePlayUrl(1), isNull);

      final noData = _Adapter({
        _kPlayInfoPath: (_) => {'code': 0},
      });
      expect(await _api(noData).fetchLivePlayUrl(1), isNull);

      final any = _Adapter({});
      expect(await _api(any).fetchLivePlayUrl(0), isNull,
          reason: 'roomId 非法直接返回，不打接口');
      expect(any.requests, isEmpty);
    });

    test('未开播也返回对象（isLive=false），页面据此显示「直播已结束」', () async {
      final adapter = _Adapter({
        _kPlayInfoPath: (_) => _body(liveStatus: 0, streams: []),
      });
      final info = await _api(adapter).fetchLivePlayUrl(1);
      expect(info, isNotNull, reason: '「不可播」不是「取流失败」，页面要能区分');
      expect(info!.isLive, isFalse);
      expect(info.liveStatus, 0);
    });

    test('网络失败 → null（不抛）', () async {
      expect(await _api(_ThrowingAdapter()).fetchLivePlayUrl(1), isNull);
    });
  });
}
