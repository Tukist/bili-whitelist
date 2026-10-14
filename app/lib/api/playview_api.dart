/// App gRPC `PlayView` 取流（**只服务「免流兼容（实验）」开关**，v2.52.0+）。
///
/// ## 为什么要这条路径
///
/// 网页接口 `x/player/wbi/playurl` 与 App REST 接口 `x/player/playurl` 下发的直链
/// 里 CDN 签名写的是 **`platform=pc`**，该 CDN 策略要求「浏览器 UA + 带 Referer」；
/// 换成 App 特征 UA 反而 **403**（2026-10 实测，见仓库 `docs/`）。也就是说只换 UA
/// 那版（v2.51.x）在网页直链上**必然取不到流**。
///
/// 官方 App 用的是 gRPC 接口 `bilibili.app.playurl.v1.PlayURL/PlayView`，它下发的
/// 直链签名是 **`platform=android`**，取流要求恰好是「Android 特征 UA + **不带**
/// Referer」（带了就 403）。这条链才是「看起来像官方 App」的流量。
///
/// ## 实测结论（2026-10-14，匿名）
///
/// - 端点：`POST https://app.bilibili.com/bilibili.app.playurl.v1.PlayURL/PlayView`
///   （`grpc.biliapi.net` 亦可，但 `app.bilibili.com` 与 `api.bilibili.com` 同属
///   `*.bilibili.com`，对运营商免流白名单更保险）；
/// - **HTTP/1.1 就能发**：`content-type: application/grpc` + 5 字节帧头，
///   服务端把 `grpc-status` 放在**响应头**里（实测 `Grpc-Status: 0`），
///   所以本文件不用 HTTP/2 库、也不用 grpc dart 包，`dio` 一个 POST 足够；
/// - **元数据只要 `x-bili-metadata-bin` 一个**（实测最小可用集合），
///   里面的 `buvid` 服务端**不校验**：随便造一个 `XY…` 形状的假值即可
///   （实测该假值会被原样回显进 CDN 直链，且直链能 206 取到数据）；
/// - **不需要 `access_key`**：匿名即可拿到流；`access_key` 只影响清晰度上限
///   （匿名与网页接口一样，只有 480P/360P 有流，720P+ 报 `need_login`）。
///
/// ## 登录态与清晰度（v2.52.0+）
///
/// 本 App 是登录的（`flutter_secure_storage` 里有 `bili_sessdata`），但网页登录
/// **拿不到 `access_key`** —— 那是官方 App 形态的凭据，只由 App 端登录流程下发。
/// 匿名 PlayView 与匿名网页接口一样只有 480P/360P，所以这个开关**有可能把本来
/// 能拿到的 1080P 悄悄降成 480P**。本模块为此做两件事：
///
/// 1. **尽力试高清**：请求显式带上 `Cookie: SESSDATA=…`（[playViewLoginCookie]）。
///    端点是 `*.bilibili.com` 而不是 CDN，客户端不会自动带 cookie，必须显式设。
///    **能不能靠 SESSDATA 换到高清，本机无法验证**（要真机 + 真会话）；拿不到
///    也只是回到匿名档，不会更坏 —— 所以值得低成本试一次；
/// 2. **不许静默降级**：取流成功后打一行清晰度日志（[fetchPlayViewStream]），
///    `player_page` 据此在「低于 720P 且本机已登录」时**当着用户说明一次**。
///
/// ## 与网页接口的差异（没有差异的部分也说清楚）
///
/// - 直链 host **可能相同**（`cn-bj-fx-01-0x.bilivideo.com`），IP 段也相同；
///   真正的差异是**签名参数 `platform=android`（vs `pc`）**与**取流鉴权策略**
///   （App UA、无 Referer）；
/// - 画质上限**未必提升**（匿名 480P/360P，与网页接口一致；带 `SESSDATA` 能否
///   更高，本机未验证）。
library;

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import '../services/secure_store.dart';
import 'bilibili_api.dart' show BiliApi, PlayUrlResult;

/// gRPC 网关域名（与 [kBiliApi] 同属 `*.bilibili.com`）。
const String kPlayViewBase = 'https://app.bilibili.com';

/// gRPC 方法路径：`/包名.服务名/方法名`。
const String kPlayViewPath = '/bilibili.app.playurl.v1.PlayURL/PlayView';

/// `force_host`：0=允许用 IP（官方 App 的形态，http + IP，明文），
/// 1=http 域名，2=https 域名。
///
/// 这里**默认用 2**：Android 9+ 默认禁明文 HTTP，`force_host=0` 那种
/// `http://182.48.96.67/...` 会被系统挡掉（除非改 manifest）。实测 `force_host=2`
/// 的直链同样是 `platform=android`、同样「App UA + 无 Referer」才给流。
const int kPlayViewForceHost = 2;

/// 期望清晰度（80=1080P）。匿名时实际只会下发 480P/360P。
const int kPlayViewQn = 80;

/// `fnval`：16 = DASH 双流（与本 App 原生播放器的取流方式一致）。
const int kPlayViewFnval = 16;

/// 元数据里的 App 构建号（`Metadata.build`），与 [kBiliAppUA] 里那串一致。
const int kPlayViewBuild = 7650300;

/// 720P 的 quality 值（**低于它 = 本次取流被降清晰度**，v2.52.0+）。
///
/// 只用来做「要不要当面告诉用户清晰度被降了」的判据（见 `player_page` 的
/// `shouldWarnLowPlayViewQuality`），不参与请求参数。
const int kPlayViewQuality720P = 64;

/// quality 值 → 人话名字（只用于日志与提示，不参与任何协议字段）。
///
/// 对应关系按 B 站全站约定（`16=360P 32=480P 64=720P 80=1080P…`）；遇到没列出的
/// 档位**原样带值返回**（「未知档位 N」），免得日志里出现一个看不出所以然的数字。
String playViewQualityName(int quality) => switch (quality) {
      6 => '240P',
      16 => '360P',
      32 => '480P',
      64 => '720P',
      74 => '720P60',
      80 => '1080P',
      112 => '1080P+',
      116 => '1080P60',
      120 => '4K',
      125 => 'HDR',
      126 => '杜比视界',
      127 => '8K',
      _ => '未知档位 $quality',
    };

// ---------------------------------------------------------------------------
// BV 号 → AV 号（纯算法，避免为了一个 aid 再打一次接口）
// ---------------------------------------------------------------------------

const String _bvAlphabet = 'fZodR9XQDSUm21yCkr6zBqiveYah8bt4xsWpHnJE7jL5VG3guMTKNPAwcF';
const int _bvXor = 177451812;
const int _bvAdd = 8728348608;
const List<int> _bvPos = [11, 10, 3, 8, 4, 6];

/// BV 号 → 稿件 avid（`PlayViewReq.aid`）。
///
/// `PlayViewReq` **没有 bvid 字段**，只认 `aid`；而 App 里到处是 bvid，
/// 所以这里做一次纯算法换算（不用打接口）。输入非法时返回 0 —— 调用方
/// 应把 0 当「取不到」处理（[fetchPlayViewStream] 会直接抛错回落）。
int aidFromBvid(String bvid) {
  if (bvid.length < 12) return 0;
  var acc = 0;
  for (var i = 0; i < _bvPos.length; i++) {
    final idx = _bvAlphabet.indexOf(bvid[_bvPos[i]]);
    if (idx < 0) return 0;
    acc += idx * pow(58, i).toInt();
  }
  return (acc - _bvAdd) ^ _bvXor;
}

// ---------------------------------------------------------------------------
// 最小 protobuf 编解码（只实现 varint / length-delimited）
// ---------------------------------------------------------------------------

/// 一条 protobuf 字段：`(字段号, wire type, 值)`。
///
/// wire type 0 → [value] 是 `int`；2 → [value] 是 `Uint8List`（字符串/嵌套消息）。
class PbField {
  const PbField(this.field, this.wireType, this.value);

  final int field;
  final int wireType;
  final Object value;
}

Uint8List _varint(int n) {
  var v = n;
  if (v < 0) v += 1 << 64; // 负数是 10 字节的补码形式
  final out = <int>[];
  while (true) {
    final b = v & 0x7F;
    v >>= 7;
    if (v != 0) {
      out.add(b | 0x80);
    } else {
      out.add(b);
      return Uint8List.fromList(out);
    }
  }
}

Uint8List _fVarint(int field, int n) =>
    Uint8List.fromList([..._varint((field << 3) | 0), ..._varint(n)]);

Uint8List _fBytes(int field, List<int> b) => Uint8List.fromList(
    [..._varint((field << 3) | 2), ..._varint(b.length), ...b]);

Uint8List _fString(int field, String s) => _fBytes(field, utf8.encode(s));

(int, int) _readVarint(Uint8List buf, int i) {
  var shift = 0;
  var result = 0;
  while (true) {
    final b = buf[i];
    i++;
    result |= (b & 0x7F) << shift;
    if (b & 0x80 == 0) return (result, i);
    shift += 7;
  }
}

/// 解析一段 protobuf 消息体（未知 wire type 直接抛错，交给调用方回退）。
List<PbField> pbParse(Uint8List buf) {
  final out = <PbField>[];
  var i = 0;
  while (i < buf.length) {
    final (key, ni) = _readVarint(buf, i);
    i = ni;
    final field = key >> 3;
    final wt = key & 7;
    if (wt == 0) {
      final (v, nj) = _readVarint(buf, i);
      i = nj;
      out.add(PbField(field, 0, v));
    } else if (wt == 2) {
      final (len, nj) = _readVarint(buf, i);
      i = nj;
      out.add(PbField(
          field, 2, Uint8List.sublistView(buf, i, i + len)));
      i += len;
    } else if (wt == 5) {
      out.add(PbField(field, 5, Uint8List.sublistView(buf, i, i + 4)));
      i += 4;
    } else if (wt == 1) {
      out.add(PbField(field, 1, Uint8List.sublistView(buf, i, i + 8)));
      i += 8;
    } else {
      throw FormatException('不支持的 protobuf wire type $wt');
    }
  }
  return out;
}

/// 取某字段的**第一个**值；[wantVarint] 决定按数字还是字节取。
Object? pbFirst(Uint8List buf, int field, {bool wantVarint = false}) {
  for (final f in pbParse(buf)) {
    if (f.field == field && f.wireType == (wantVarint ? 0 : 2)) {
      return f.value;
    }
  }
  return null;
}

/// 取某字段的**所有**值（length-delimited）。
List<Uint8List> pbAllBytes(Uint8List buf, int field) =>
    [for (final f in pbParse(buf)) if (f.field == field && f.wireType == 2) f.value as Uint8List];

/// 取某字段的**所有**数字值（varint）。protobuf3 不序列化 0 值，所以缺字段
/// 等价于 0，这里返回 null 让调用方自己给默认值。
List<int> pbAllVarints(Uint8List buf, int field) =>
    [for (final f in pbParse(buf)) if (f.field == field && f.wireType == 0) f.value as int];

String _utf8Of(Uint8List b) => utf8.decode(b, allowMalformed: true);

// ---------------------------------------------------------------------------
// PlayViewReq / x-bili-metadata-bin 编码
// ---------------------------------------------------------------------------

/// 编码 `PlayViewReq`（`bilibili.app.playurl.v1.PlayViewReq`）。
///
/// 字段号（三份独立开源 proto 交叉一致：bilireq / bilimiao2 / bv）：
/// `aid=1, cid=2, qn=3, fnver=4, fnval=5, download=6, force_host=7, fourk=8,
/// spmid=9, from_spmid=10, teenagers_mode=11, prefer_codec_type=12,
/// business=13, voice_balance=14`
///
/// ⚠️ **没有 `ep_id` / `bvid` / `mobi_app` / `platform` 字段** —— 番剧要用另一套
/// 服务（`bilibili.pgc.gateway.player.v2`），`platform` 只走元数据头。
Uint8List encodePlayViewReq({
  required int aid,
  required int cid,
  int qn = kPlayViewQn,
  int fnval = kPlayViewFnval,
  int fnver = 0,
  int fourk = 1,
  int forceHost = kPlayViewForceHost,
}) {
  final b = <int>[];
  b.addAll(_fVarint(1, aid));
  b.addAll(_fVarint(2, cid));
  b.addAll(_fVarint(3, qn));
  if (fnver != 0) b.addAll(_fVarint(4, fnver));
  b.addAll(_fVarint(5, fnval));
  if (forceHost != 0) b.addAll(_fVarint(7, forceHost));
  if (fourk != 0) b.addAll(_fVarint(8, fourk));
  return Uint8List.fromList(b);
}

/// 编码 `x-bili-metadata-bin`（`bilibili.metadata.Metadata`）。
///
/// 字段号：`access_key=1, mobi_app=2, device=3, build=4, channel=5, buvid=6,
/// platform=7`。
///
/// **匿名只填 2/4/5/6/7**，不填 `access_key`（本 App 没有 access_key，也不伪造）。
Uint8List metadataBin({
  required String buvid,
  String mobiApp = 'android',
  String platform = 'android',
  int build = kPlayViewBuild,
  String channel = 'master',
}) {
  final b = <int>[];
  b.addAll(_fString(2, mobiApp));
  b.addAll(_fVarint(4, build));
  b.addAll(_fString(5, channel));
  b.addAll(_fString(6, buvid));
  b.addAll(_fString(7, platform));
  return Uint8List.fromList(b);
}

/// gRPC 请求体的一层信封：`1 字节压缩标志(0) + 4 字节大端长度 + 消息体`。
Uint8List grpcFrame(Uint8List payload) => Uint8List.fromList(
    [0, ...payload.length.toInt().toUnsigned(32).toBytes(), ...payload]);

extension on int {
  List<int> toBytes() =>
      [(this >> 24) & 0xFF, (this >> 16) & 0xFF, (this >> 8) & 0xFF, this & 0xFF];
}

/// 去掉 gRPC 信封，取出消息体。
///
/// 服务端可能返回**多条**帧（本方法只取第一条——`PlayView` 是 unary，实测一条）。
/// 响应体短于 5 字节 / 长度越界时抛 [FormatException]。
Uint8List grpcUnframe(Uint8List body) {
  if (body.length < 5) {
    throw FormatException('gRPC 响应过短（${body.length} 字节）');
  }
  final len = (body[1] << 24) | (body[2] << 16) | (body[3] << 8) | body[4];
  if (len < 0 || 5 + len > body.length) {
    throw FormatException('gRPC 帧长度越界（声称 $len，实有 ${body.length - 5}）');
  }
  return Uint8List.sublistView(body, 5, 5 + len);
}

/// 造一个「形状正确」的假 buvid（`XY` + 32 位十六进制大写）。
///
/// 实测：PlayView **不校验** buvid 真实性，它只被原样回显进 CDN 直链的 `buvid=`
/// 参数，且删掉该参数直链照样 206。所以**不读、不传**任何真实设备指纹。
/// 传 [random] 便于测试固定结果。
String fakeBuvid([Random? random]) {
  final r = random ?? Random();
  String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16))
      .join()
      .toUpperCase();
  return 'XY${hex(32)}';
}

// ---------------------------------------------------------------------------
// PlayViewReply 解析
// ---------------------------------------------------------------------------

/// 一条 DASH 视频轨（`Stream.dash_video`）。
class PlayViewVideo {
  const PlayViewVideo({
    required this.quality,
    required this.baseUrl,
    required this.backupUrls,
    required this.bandwidth,
    required this.codecid,
  });

  /// 清晰度（来自 `Stream.stream_info.quality`：16=360P 32=480P 64=720P…）。
  final int quality;
  final String baseUrl;
  final List<String> backupUrls;
  final int bandwidth;
  final int codecid;
}

/// 一条 DASH 音频轨（`VideoInfo.dash_audio`）。
class PlayViewAudio {
  const PlayViewAudio({
    required this.id,
    required this.baseUrl,
    required this.backupUrls,
    required this.bandwidth,
  });

  final int id;
  final String baseUrl;
  final List<String> backupUrls;
  final int bandwidth;
}

/// `PlayViewReply` 里本 App 用得到的部分。
class PlayViewStreams {
  const PlayViewStreams({
    required this.quality,
    required this.videos,
    required this.audios,
  });

  /// `video_info.quality`（实际下发清晰度）。
  final int quality;
  final List<PlayViewVideo> videos;
  final List<PlayViewAudio> audios;
}

/// 解析 `PlayViewReply`。
///
/// 只用到的字段（字段号见 `playurl.proto`）：
/// - `PlayViewReply.video_info = 1`
/// - `VideoInfo.quality = 1, stream_list = 5, dash_audio = 6`
/// - `Stream.stream_info = 1, dash_video = 2`
/// - `StreamInfo.quality = 1, err_code = 4`
/// - `DashVideo.base_url = 1, backup_url = 2, bandwidth = 3, codecid = 4`
/// - `DashItem.id = 1, baseUrl = 2, backup_url = 3, bandwidth = 4`
///
/// 只收「有非空 base_url 且没有 err_code」的视频轨（匿名时 720P+ 的条目不带
/// dash_video 或带 err_code，自然被过滤掉）。
PlayViewStreams parsePlayViewReply(Uint8List reply) {
  final videoInfo = pbFirst(reply, 1) as Uint8List?;
  if (videoInfo == null) {
    throw const FormatException('PlayViewReply 没有 video_info');
  }
  final quality = (pbFirst(videoInfo, 1, wantVarint: true) as int?) ?? 0;

  final videos = <PlayViewVideo>[];
  for (final s in pbAllBytes(videoInfo, 5)) {
    final dv = pbFirst(s, 2) as Uint8List?;
    if (dv == null) continue;
    var streamQuality = 0;
    final si = pbFirst(s, 1) as Uint8List?;
    if (si != null) {
      streamQuality = (pbFirst(si, 1, wantVarint: true) as int?) ?? 0;
      if (((pbFirst(si, 4, wantVarint: true) as int?) ?? 0) != 0) {
        continue; // 带错误码的档位（未登录/无权限）不给 dash_video
      }
    }
    final base = pbFirst(dv, 1) as Uint8List?;
    if (base == null || base.isEmpty) continue;
    videos.add(PlayViewVideo(
      quality: streamQuality,
      baseUrl: _utf8Of(base),
      backupUrls: [for (final u in pbAllBytes(dv, 2)) _utf8Of(u)],
      bandwidth: (pbFirst(dv, 3, wantVarint: true) as int?) ?? 0,
      codecid: (pbFirst(dv, 4, wantVarint: true) as int?) ?? 0,
    ));
  }

  final audios = <PlayViewAudio>[];
  for (final a in pbAllBytes(videoInfo, 6)) {
    final base = pbFirst(a, 2) as Uint8List?;
    if (base == null || base.isEmpty) continue;
    audios.add(PlayViewAudio(
      id: (pbFirst(a, 1, wantVarint: true) as int?) ?? 0,
      baseUrl: _utf8Of(base),
      backupUrls: [for (final u in pbAllBytes(a, 3)) _utf8Of(u)],
      bandwidth: (pbFirst(a, 4, wantVarint: true) as int?) ?? 0,
    ));
  }

  return PlayViewStreams(quality: quality, videos: videos, audios: audios);
}

/// 把 [PlayViewStreams] 折成 App 既有的 [PlayUrlResult]。
///
/// 视频轨**只取一条**：清晰度最高的那条（匿名时即 480P）。这样 `_playStream`
/// 拿到的就是 `dashVideoUrls.length == 1`，与网页接口的用法一致；
/// 同档的 `backup_url` 保留在 `dashVideoLines` 里供换源轮转用。
///
/// 音频轨全部保留（`dashAudioUrls` 顺序即服务端顺序），
/// [pickLowestBandwidthAudio] 之类既有逻辑照常工作。
PlayUrlResult toPlayUrlResult(PlayViewStreams streams) {
  if (streams.videos.isEmpty) {
    throw const FormatException('PlayView 没有可用视频轨');
  }
  final best = streams.videos.reduce(
      (a, b) => b.quality > a.quality ? b : a);
  return PlayUrlResult(
    quality: best.quality != 0 ? best.quality : streams.quality,
    dashVideoUrls: [best.baseUrl],
    dashVideoLines: [
      [best.baseUrl, ...best.backupUrls.where((u) => u != best.baseUrl)]
    ],
    dashAudioUrls: [for (final a in streams.audios) a.baseUrl],
    dashAudioIds: [for (final a in streams.audios) a.id],
    dashAudioBandwidths: [for (final a in streams.audios) a.bandwidth],
    dashAudioLines: [
      for (final a in streams.audios)
        [a.baseUrl, ...a.backupUrls.where((u) => u != a.baseUrl)]
    ],
  );
}

// ---------------------------------------------------------------------------
// 登录 Cookie（v2.52.0+：试着靠 SESSDATA 拿高清）
// ---------------------------------------------------------------------------

/// secure storage 里登录凭据的 key（与 [BiliApi] 的私有常量同值）。
///
/// `bilibili_api.dart` 是本批的**红线文件**（一行不改），那两个 key 常量是私有的，
/// 所以这里复写字面量。改动任一处都要同步（`grep bili_sessdata`）。
const String kSessdataStorageKey = 'bili_sessdata';

/// `bili_jct` 的 key（同上，只用于尽量贴近官方 App 的 cookie 集合）。
const String kBiliJctStorageKey = 'bili_jct';

/// 读本机登录凭据、拼成 PlayView 的 `Cookie` 头值；**未登录/读盘失败返回 null**。
///
/// 只带两样，且都是「已经在 secure storage 里的」：
/// - `SESSDATA`（必需，登录态本体）—— 没有它（或它内嵌的过期时间已过）就返回
///   null，调用方按**匿名**发请求（与 v2.52.0 的行为一致，绝不因此失败）；
/// - `bili_jct`（有就带上，尽量贴近官方 App 的 cookie 集合）。
///
/// **不带** `buvid3/buvid4/DedeUserID` 等无关 cookie：本请求的设备指纹走
/// `x-bili-metadata-bin`（见 [metadataBin]），掺一堆网页 cookie 只会让它更像
/// 「网页流量」，与这个开关的目的相反。
///
/// ⚠️ 返回**含凭据**：调用方只许把它塞进请求头，**不许打日志/不许回显**。
/// 过期判定复用 [BiliApi.sessdataExpireAt]（与 `_injectAuth` 同一判据：拿一个
/// 死会话去换流只会更容易吃到 -101，不如干脆匿名）。
Future<String?> playViewLoginCookie({FlutterSecureStorage? storage}) async {
  try {
    final s = storage ?? createSecureStorage();
    final sess = (await s.read(key: kSessdataStorageKey))?.trim();
    if (sess == null || sess.isEmpty) return null;
    final expire = BiliApi.sessdataExpireAt(sess);
    if (expire != null && expire.isBefore(DateTime.now())) {
      debugPrint('[playview] 本机 SESSDATA 已过期 → 本次按匿名请求（不注入 Cookie）');
      return null;
    }
    final jct = (await s.read(key: kBiliJctStorageKey))?.trim();
    return jct == null || jct.isEmpty
        ? 'SESSDATA=$sess'
        : 'SESSDATA=$sess; bili_jct=$jct';
  } catch (e) {
    // Keystore 异常 / 通道不可用等：读不到就当没登录（匿名请求），
    // 绝不因为拿不到 cookie 让整条取流路径失败
    debugPrint('[playview] 读取登录凭据失败 → 本次按匿名请求：$e');
    return null;
  }
}

/// 读登录 Cookie 的方式（默认 [playViewLoginCookie]；测试注入替身用）。
typedef PlayViewCookieReader = Future<String?> Function();

// ---------------------------------------------------------------------------
// 网络调用
// ---------------------------------------------------------------------------

/// 直接打 PlayView，拿回 [`PlayViewReply`] 的原始字节（测试与排查用）。
///
/// 头只带必要的那几样：**故意不带** `biliHeaders()` 那套浏览器头（Sec-Fetch /
/// Origin / 浏览器 UA）——那会让服务端和 CDN 把请求判成网页流量，与开关的目的
/// 相反。
///
/// [cookie] 非空时带上 `cookie: <它>`（登录态，见 [playViewLoginCookie]）；
/// **仍然不带 `Referer` / `Origin`**（实测带了必 403，与带不带 cookie 无关）。
///
/// [dio] 仅供测试注入；默认自己造一个干净实例，不复用 API 层带 cookie 拦截器的
/// `_dio`。
Future<Uint8List> playViewRaw({
  required int aid,
  required int cid,
  int qn = kPlayViewQn,
  String? buvid,
  Dio? dio,
  String baseUrl = kPlayViewBase,
  String? cookie,
}) async {
  final client = dio ?? Dio();
  try {
    final resp = await client.post<List<int>>(
      '$baseUrl$kPlayViewPath',
      data: grpcFrame(encodePlayViewReq(aid: aid, cid: cid, qn: qn)),
      options: Options(
        responseType: ResponseType.bytes,
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'content-type': 'application/grpc',
          // 与流请求同一份 UA（用户开着「免流兼容」时 = kBiliAppUA）
          'user-agent': streamUserAgent(),
          'x-bili-metadata-bin': base64Encode(
              metadataBin(buvid: buvid ?? fakeBuvid())),
          'te': 'trailers',
          'accept': '*/*',
          // 登录态（显式设置：本请求打到 *.bilibili.com，客户端不会自动带
          // CDN/网页的 cookie）。**只在有 SESSDATA 时加这一行**，且只加这一行
          // ——Referer/Origin 一个都不加。
          if (cookie != null && cookie.isNotEmpty) 'cookie': cookie,
        },
        // gRPC 的错误走响应头 Grpc-Status / Grpc-Message（实测），
        // 先让所有 2xx 进来再自己判，避免 dio 抛一个丢失了头信息的异常
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    final grpcStatus = resp.headers.value('grpc-status');
    if (grpcStatus != null && grpcStatus != '0') {
      throw StateError('PlayView grpc-status=$grpcStatus '
          'message=${resp.headers.value('grpc-message') ?? ''}');
    }
    final body = resp.data;
    if (body == null || body.isEmpty) {
      throw const FormatException('PlayView 返回空响应体');
    }
    return grpcUnframe(Uint8List.fromList(body));
  } finally {
    if (dio == null) client.close(force: true);
  }
}

/// 取流（免流兼容路径）：返回 App 既有形状的 [PlayUrlResult]。
///
/// 任何一步出问题都**抛错**，由调用方回落到网页接口 —— 本函数不做静默降级，
/// 免得「取到空流还在播」这种更难查的形态。
///
/// 本机有**未过期**的 `SESSDATA` 时带上登录 Cookie（[playViewLoginCookie]），
/// 取完再打一行清晰度日志 —— 清晰度就是本路径最大的不确定性，必须留下痕迹：
///
/// ```text
/// [playview] platform=android 已带登录Cookie=true 最高视频轨=32（480P） 轨道数=2
/// ```
///
/// 日志里**只有数字与布尔**：不带 cookie、不带 URL、不带任何签名（凭据只许进
/// 请求头）。
Future<PlayUrlResult> fetchPlayViewStream({
  required String bvid,
  required int cid,
  int qn = kPlayViewQn,
  String? buvid,
  Dio? dio,
  String baseUrl = kPlayViewBase,
  PlayViewCookieReader? cookieReader,
}) async {
  final aid = aidFromBvid(bvid);
  if (aid <= 0 || cid <= 0) {
    throw ArgumentError('PlayView 需要有效 aid/cid（bvid=$bvid aid=$aid cid=$cid）');
  }
  final cookie = await (cookieReader ?? playViewLoginCookie)();
  final reply = await playViewRaw(
      aid: aid,
      cid: cid,
      qn: qn,
      buvid: buvid,
      dio: dio,
      baseUrl: baseUrl,
      cookie: cookie);
  final streams = parsePlayViewReply(reply);
  final result = toPlayUrlResult(streams);
  if (result.dashVideoUrls.isEmpty) {
    throw const FormatException('PlayView 未下发任何 DASH 视频轨');
  }
  debugPrint('[playview] platform=android 已带登录Cookie=${cookie != null} '
      '最高视频轨=${result.quality}（${playViewQualityName(result.quality)}） '
      '轨道数=${streams.videos.length}');
  return result;
}
