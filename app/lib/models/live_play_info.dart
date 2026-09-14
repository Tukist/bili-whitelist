/// 直播间**播放地址**（v2.27.0+）：App 内直播播放的取流结果。
///
/// 与 `LiveStatus`（开播标记）的分工：那个只回答「在不在播」，本模型回答
/// 「怎么播」—— 从 `getRoomPlayInfo` 的响应里挑出**可播的那一条流**并拼出
/// 完整地址（见 [fromPlayInfo]）。
///
/// ⚠️ **地址有时效（实测 ≈ 58 分钟）且不可落盘**：URL 带签名/过期参数，
/// 缓存或持久化只会拿到过期地址；每次进页现取，长看直播靠 `LivePlayerPage`
/// 的续期定时器换新地址（见 [hasExpiry] / [refreshDelay]）。
///
/// 解析一律**宽松**（字段缺失 / 类型异常 / 结构变形都不抛，退回安全默认），
/// 风格与 [LiveStatus.fromRoomInfoOld] 一致——脏数据只表现为「没有地址」。
library;

import 'package:flutter/foundation.dart';

/// 续期提前量：剩余有效期不足这个量就换新地址（实测地址约 58 分钟有效，
/// 提前 10 分钟足够覆盖一次取流 + 换源的耗时，且换源本身几乎无感）。
const Duration kLiveUrlRefreshLead = Duration(minutes: 10);

/// 续期定时器的下限 / 上限（防御）：剩余有效期算出来的等待时间夹在这个区间
/// 内——小于 1 分钟说明地址几乎已过期（立刻换），大于 45 分钟按 45 分钟兜底
/// （地址寿命按实测 58 分钟估计，没必要拖到最后一刻才换）。
const Duration kLiveUrlRefreshMinDelay = Duration(minutes: 1);
const Duration kLiveUrlRefreshMaxDelay = Duration(minutes: 45);

/// 一次直播取流的结果（**一次性对象，不要缓存/持久化**）。
class LivePlayInfo {
  const LivePlayInfo({
    required this.roomId,
    required this.liveStatus,
    this.hlsUrl = '',
    this.quality = 0,
    this.expiresAtEpochSec = 0,
    this.host = '',
    this.protocolName = '',
    this.formatName = '',
    this.codecName = '',
  });

  /// 直播间号（取流键）。
  final int roomId;

  /// 开播状态（`data.live_status`，**不是** `data.room_info.live_status`——
  /// 实测 `room_info` 为 null，读它必空指针）：1 = 直播中，0 = 未开播，
  /// 2 = 轮播（无直播流）。
  final int liveStatus;

  /// 挑中的流地址（HLS 媒体播放列表；未在播 / 挑不出来时为空串）。
  final String hlsUrl;

  /// 清晰度（`current_qn`；0 = 未知）。
  final int quality;

  /// 地址过期时间（Unix 秒；0 = 服务端没给，调用方按固定时长兜底）。
  ///
  /// 来源：地址 query 里的 `expires`（其次 `deadline`），都缺时按
  /// `url_info[].stream_ttl` 从现在起算（见 [_resolveExpiresAt]）。
  final int expiresAtEpochSec;

  /// 实际使用的 CDN host（排障用；同一条流有多个 host 互为备份）。
  final String host;

  /// 挑中的流形态（`http_hls` / `http_stream` 等，排障用）。
  final String protocolName;

  /// 挑中的封装格式（`fmp4` / `ts` / `flv`，排障用）。
  final String formatName;

  /// 挑中的编码（`avc` / `hevc`，排障用）。
  final String codecName;

  /// 是否**拿到可播地址且在播**：只有 `liveStatus == 1` 且地址非空才算。
  ///
  /// 轮播（2）与未开播（0）一律 false —— 页面据此显示「直播已结束 /
  /// 未开播」而不是「播放失败」。
  bool get isLive => liveStatus == 1 && hlsUrl.isNotEmpty;

  /// 服务端给了过期时间。
  bool get hasExpiry => expiresAtEpochSec > 0;

  /// 距过期还剩多久（没给过期时间 → null）；已过期返回负值。
  Duration? remaining({DateTime? now}) {
    if (!hasExpiry) return null;
    final nowSec =
        ((now ?? DateTime.now()).millisecondsSinceEpoch / 1000).floor();
    return Duration(seconds: expiresAtEpochSec - nowSec);
  }

  /// 是否该换新地址了（剩余有效期 < [kLiveUrlRefreshLead]，或已过期）。
  /// 没给过期时间 → false（调用方按固定时长兜底）。
  bool isExpiring({DateTime? now, Duration within = kLiveUrlRefreshLead}) {
    final left = remaining(now: now);
    return left != null && left < within;
  }

  /// 续期定时器该等多久（夹在 [kLiveUrlRefreshMinDelay]..[kLiveUrlRefreshMaxDelay]
  /// 之间；没给过期时间 → 上限兜底）。
  Duration get refreshDelay {
    final left = remaining();
    if (left == null) return kLiveUrlRefreshMaxDelay;
    final delay = left - kLiveUrlRefreshLead;
    if (delay < kLiveUrlRefreshMinDelay) return kLiveUrlRefreshMinDelay;
    if (delay > kLiveUrlRefreshMaxDelay) return kLiveUrlRefreshMaxDelay;
    return delay;
  }

  /// 由 `getRoomPlayInfo` 的 **`data`** 构造（宽松解析，脏数据只表现为
  /// 没有地址，不抛）。
  ///
  /// 结构（2026-09 实测，字段位置是最容易写错的地方）：
  /// `data.playurl_info.playurl.stream[]`
  ///   → `{protocol_name: http_stream|http_hls, format[]}`
  ///   → `format[] {format_name: flv|ts|fmp4, codec[]}`
  ///   → `codec[] {codec_name: avc|hevc, base_url, current_qn, url_info[]}`
  ///   → `url_info[] {host, extra, stream_ttl}`。
  ///
  /// ⚠️ **`base_url` 在 codec 这一层**（不在 `url_info` 里）；完整地址 =
  /// `url_info[i].host + base_url + url_info[i].extra`（纯字符串拼接、无分隔符，
  /// `base_url` 自带结尾 `?`；不带时补一个，见 [_composeUrl]）。
  ///
  /// `data` 完全不可用（非 Map / 空）→ null；只要 `data` 可用就一定返回对象
  /// （未在播 / 挑不出流 → [hlsUrl] 为空串），调用方按 [isLive] 分流。
  static LivePlayInfo? fromPlayInfo(int roomId, dynamic data) {
    if (data is! Map) return null;
    final liveStatus = _int(data['live_status']);
    final streams = _flattenStreams(data);

    // 未开播 / 轮播：不挑流、不给地址。轮播虽然可能有地址，但它不是直播
    // （B 站会回放录像），交给播放器只会播出一段没有结尾的旧流。
    if (liveStatus != 1) {
      return LivePlayInfo(roomId: roomId, liveStatus: liveStatus);
    }

    final picked = _pickStream(streams);
    if (picked == null) {
      debugPrint('[live_play] room=$roomId live_status=$liveStatus '
          '但没有任何可用流（stream 数=${streams.length}）');
      return LivePlayInfo(roomId: roomId, liveStatus: liveStatus);
    }

    // url_info 是长度 2 的列表（互为备份的 CDN host）：逐个尝试，取第一个
    // 能拼出非空地址的。整体缺失 → 拿不到 host，地址留空（base_url 不含
    // host，单独交给播放器必失败）。
    var url = '';
    var host = '';
    var ttl = 0;
    for (final ui in picked.urlInfos) {
      final candidate =
          _composeUrl(_str(ui['host']), picked.baseUrl, _str(ui['extra']));
      if (candidate.isNotEmpty) {
        url = candidate;
        host = _str(ui['host']);
        ttl = _int(ui['stream_ttl']);
        break;
      }
    }
    if (url.isEmpty) {
      debugPrint('[live_play] room=$roomId 挑中的流拼不出地址'
          '（url_info 数=${picked.urlInfos.length}）');
    }
    if (picked.protocol != 'http_hls') {
      // 兜底：ExoPlayer 原生**不支持 FLV**（http_stream 全是 flv），这条
      // 地址大概率播不起来。留在这里是为了「有地址总比没有强」以及日志可查。
      debugPrint('[live_play] ⚠️ room=$roomId 回退到 ${picked.protocol}/'
          '${picked.format}，ExoPlayer 原生不支持 FLV，可能无法播放');
    }

    return LivePlayInfo(
      roomId: roomId,
      liveStatus: liveStatus,
      hlsUrl: url,
      quality: picked.quality,
      expiresAtEpochSec: _resolveExpiresAt(url, ttl),
      host: host,
      protocolName: picked.protocol,
      formatName: picked.format,
      codecName: picked.codec,
    );
  }

  @override
  String toString() =>
      'LivePlayInfo(room=$roomId, live=$liveStatus, qn=$quality, '
      '${protocolName.isEmpty ? '?' : protocolName}/${formatName.isEmpty ? '?' : formatName}/'
      '${codecName.isEmpty ? '?' : codecName}, host="$host", '
      'expires=$expiresAtEpochSec, url=${hlsUrl.isEmpty ? '(空)' : hlsUrl})';
}

// ---------------------------------------------------------------------------
// 选流 + 拼地址（纯函数实现，单测直接覆盖这些最容易写错的规则）
// ---------------------------------------------------------------------------

/// 展平后的候选流（stream → format → codec 三层各取关心的字段）。
class _StreamCandidate {
  _StreamCandidate({
    required this.protocol,
    required this.format,
    required this.codec,
    required this.baseUrl,
    required this.urlInfos,
    required this.quality,
  });

  final String protocol;
  final String format;
  final String codec;
  final String baseUrl;
  final List<Map> urlInfos;
  final int quality;
}

/// 把 `data.playurl_info.playurl.stream[]` 展平成候选流列表。
List<_StreamCandidate> _flattenStreams(Map data) {
  final out = <_StreamCandidate>[];
  final playurlInfo = data['playurl_info'];
  if (playurlInfo is! Map) return out;
  final playurl = playurlInfo['playurl'];
  if (playurl is! Map) return out;
  final streams = playurl['stream'];
  if (streams is! List) return out;
  for (final s in streams) {
    if (s is! Map) continue;
    final protocol = _str(s['protocol_name']);
    final formats = s['format'];
    if (formats is! List) continue;
    for (final f in formats) {
      if (f is! Map) continue;
      final format = _str(f['format_name']);
      final codecs = f['codec'];
      if (codecs is! List) continue;
      for (final c in codecs) {
        if (c is! Map) continue;
        final rawInfos = c['url_info'];
        out.add(_StreamCandidate(
          protocol: protocol,
          format: format,
          codec: _str(c['codec_name']),
          // base_url 正常在 codec 层；format/stream 层作为防御性兜底
          // （实测唯一位置是 codec 层，见 [LivePlayInfo.fromPlayInfo]）
          baseUrl: _firstNonEmpty([
            _str(c['base_url']),
            _str(f['base_url']),
            _str(s['base_url']),
          ]),
          urlInfos: rawInfos is List ? rawInfos.whereType<Map>().toList() : const [],
          quality: _int(c['current_qn']),
        ));
      }
    }
  }
  return out;
}

/// 选流优先级（纯函数，可单测）。
///
/// 为什么是 HLS 优先、且 fmp4 优先于 ts：
/// - `http_stream` 全是 **FLV**，ExoPlayer 原生不支持 → 只能作最后兜底；
/// - `http_hls/ts` 这条实测用的 CDN host 在本机 DNS 是 NXDOMAIN（拼出来也
///   连不上），而 `http_hls/fmp4` 实测可播；
/// - hevc 排在 avc 之后：兼容性更好，且部分设备硬解 hevc 缺能力。
_StreamCandidate? _pickStream(List<_StreamCandidate> streams) {
  if (streams.isEmpty) return null;
  const priority = <(String, String, String)>[
    ('http_hls', 'fmp4', 'avc'),
    ('http_hls', 'ts', 'avc'),
    ('http_hls', 'fmp4', 'hevc'),
    ('http_hls', 'ts', 'hevc'),
  ];
  for (final (protocol, format, codec) in priority) {
    for (final s in streams) {
      if (s.protocol == protocol && s.format == format && s.codec == codec) {
        return s;
      }
    }
  }
  // 任何 http_hls（格式/编码是没见过的取值）
  for (final s in streams) {
    if (s.protocol == 'http_hls') return s;
  }
  // 兜底：任何流（http_stream/flv，有地址总比没有强；调用方会打警告）
  return streams.first;
}

/// 拼完整地址：`host + base_url + extra`（**纯字符串拼接，无分隔符**）。
///
/// `base_url` 实测自带结尾 `?`；不带而 `extra` 非空时补一个 `?`（防御——
/// 少一个分隔符会得到 `...m3u8expires=...` 这种必然失败的地址）。
/// host / base_url 缺任一 → 空串（调用方换下一个 url_info）。
String _composeUrl(String host, String baseUrl, String extra) {
  if (host.isEmpty || baseUrl.isEmpty) return '';
  // host 正常带 scheme（`https://x.mcdn.bilivideo.cn:8082`）；不带时补 https
  final h = host.contains('://') ? host : 'https://$host';
  var url = h + baseUrl;
  if (extra.isNotEmpty) {
    if (!url.endsWith('?') && !extra.startsWith('?')) url = '$url?';
    url += extra;
  }
  return url;
}

/// 地址过期时间（Unix 秒）：query 的 `expires`（其次 `deadline`）优先；
/// 都缺 → 按 [streamTtlSec] 从现在起算；再缺 → 0（调用方按固定时长兜底）。
int _resolveExpiresAt(String url, int streamTtlSec) {
  final query = Uri.tryParse(url)?.queryParameters;
  if (query != null) {
    for (final key in const ['expires', 'deadline']) {
      final raw = int.tryParse(query[key] ?? '');
      if (raw == null || raw <= 0) continue;
      // 毫秒时间戳（13 位）→ 秒；正常就是 10 位秒
      return raw > 100000000000 ? raw ~/ 1000 : raw;
    }
  }
  if (streamTtlSec > 0) {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 + streamTtlSec;
  }
  return 0;
}

String _firstNonEmpty(List<String> values) {
  for (final v in values) {
    if (v.isNotEmpty) return v;
  }
  return '';
}

// ---------------------------------------------------------------------------
// 宽松解析小工具（与 article.dart / live_status.dart 同一套风格）
// ---------------------------------------------------------------------------

/// 宽松取整数：num 直接转、数字串容错解析，其余按 0。
int _int(dynamic raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}

/// 宽松取字符串：非 String 一律空串。
String _str(dynamic raw) => raw is String ? raw : '';
