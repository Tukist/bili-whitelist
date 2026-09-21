// 剪贴板链接识别 + 冷启动探测（v2.35.0）单元测试：
// - parseClipboardLink：完整链接（含 ?p/?t）、分享文本两种形态、裸 BV、
//   无协议头 b23、番剧链接、无链接文本、尾部标点、UP 空间链接不算视频
// - resolveClipboardShortLink：b23 重定向 → 视频 / 番剧 / 非视频 / 失败
// - ClipboardLinkProbe：命中 opened、同一条第二次 duplicate、开关关 disabled
//   （连剪贴板都不读）、无链接 none、解析失败 failed、番剧不跳、取元数据失败
//   failed 且不记已处理
//
// 全部用假剪贴板读取函数 + 假 adapter + 假 BiliApi，**不碰系统剪贴板、不联网**。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/services/clipboard_link_probe.dart';
import 'package:bili_whitelist_app/services/clipboard_link_store.dart';
import 'package:bili_whitelist_app/utils/clipboard_link.dart';
import 'package:bili_whitelist_app/utils/import_parser.dart';

const _bv = 'BV1yE8r6KErQ';

/// 分享文本的真实形态（用户给过的两条样例）。
const _shareTextFull =
    '【【Noita全天赋介绍39】魔杖实验家——我忘了能回血了】 '
    'https://www.bilibili.com/video/$_bv/?share_source=copy_web&vd_source=abc123';
const _shareTextShort = '【【边狱巴士】第八赛季将至！...-哔哩哔哩】 https://b23.tv/spVKBAi';

/// 模拟短链重定向：返回带 redirects 的响应（`realUri` = 最终地址）。
class _RedirectAdapter implements HttpClientAdapter {
  /// null → 抛网络连接错误。
  final Uri? finalLocation;

  _RedirectAdapter({this.finalLocation});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (finalLocation == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }
    final body = ResponseBody.fromString('<html>go</html>', 200, headers: {
      'content-type': ['text/html; charset=utf-8'],
    });
    body.redirects = [RedirectRecord(302, 'GET', finalLocation!)];
    return body;
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(Uri? location) =>
    Dio()..httpClientAdapter = _RedirectAdapter(finalLocation: location);

/// 假 B 站接口：记录调用次数，可返回元数据或抛业务错误。
class _FakeBiliApi extends BiliApi {
  _FakeBiliApi({this.error});

  int calls = 0;

  /// 非 null → 抛这个错误。
  final BiliApiException? error;

  @override
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    return {
      'bvid': bvid,
      'cid': 12345,
      'title': '剪贴板里的视频',
      'pic': 'https://i0.hdslb.com/cover.jpg',
      'duration': 300,
      'pubdate': 1780000000,
      'desc': '简介',
      'owner': {'mid': 7, 'name': 'UP主'},
      'pages': [
        {'cid': 12345, 'part': 'P1', 'duration': 300},
      ],
    };
  }
}

/// 造一个探测实例：假剪贴板内容（或抛异常）+ 假 B 站接口 + 可选 dio。
({
  ClipboardLinkProbe probe,
  _FakeBiliApi api,
  List<int> reads,
}) _probeWith(
  String? clipboard, {
  _FakeBiliApi? api,
  Dio? dio,
  bool enabled = true,
  String? lastHandled,
  bool throwOnRead = false,
}) {
  final reads = <int>[];
  final a = api ?? _FakeBiliApi();
  ClipboardLinkStore.instance.resetForTest(
    enabled: enabled,
    lastHandledKey: lastHandled,
    loaded: true, // 直接用内存态（不再读盘）
  );
  final probe = ClipboardLinkProbe(
    api: a,
    dio: dio,
    readClipboard: () async {
      reads.add(1);
      if (throwOnRead) throw StateError('clipboard unavailable');
      return clipboard;
    },
  );
  return (probe: probe, api: a, reads: reads);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ClipboardLinkStore.instance.resetForTest();
  });

  group('parseClipboardLink 纯解析（无网络）', () {
    test('分享文本 + 完整链接 → 视频（BV）', () {
      final hit = parseClipboardLink(_shareTextFull)!;
      expect(hit.kind, ClipboardLinkKind.video);
      expect(hit.bvid, _bv);
      expect(hit.raw, contains('bilibili.com/video/$_bv'));
      expect(hit.pageIndex, isNull);
      expect(hit.positionMs, isNull);
    });

    test('分享文本 + b23 短链 → b23（待解析）', () {
      final hit = parseClipboardLink(_shareTextShort)!;
      expect(hit.kind, ClipboardLinkKind.b23);
      expect(hit.shortUrl, 'https://b23.tv/spVKBAi');
      expect(hit.raw, 'https://b23.tv/spVKBAi');
    });

    test('完整链接带 ?p=2&t=129 → 分 P 下标 1 + 进度 129 秒', () {
      final hit = parseClipboardLink(
        '【标题】 https://www.bilibili.com/video/$_bv/?p=2&t=129&share_source=copy_web',
      )!;
      expect(hit.kind, ClipboardLinkKind.video);
      expect(hit.bvid, _bv);
      expect(hit.pageIndex, 1);
      expect(hit.positionMs, 129000);
    });

    test('裸 BV 号 / 无协议头 b23.tv 短码', () {
      final bare = parseClipboardLink('看看这个 $_bv 不错')!;
      expect(bare.kind, ClipboardLinkKind.video);
      expect(bare.bvid, _bv);
      expect(bare.raw, _bv);

      final short = parseClipboardLink('b23.tv/spVKBAi')!;
      expect(short.kind, ClipboardLinkKind.b23);
      expect(short.shortUrl, 'https://b23.tv/spVKBAi');
    });

    test('番剧链接（完整 / b23 短码）→ bangumi（由调用方决定不跳）', () {
      final full = parseClipboardLink(
          'https://www.bilibili.com/bangumi/play/ep98603')!;
      expect(full.kind, ClipboardLinkKind.bangumi);
      expect(full.pgcRef, 'ep98603');

      final code = parseClipboardLink('【番剧】https://b23.tv/ep98603')!;
      expect(code.kind, ClipboardLinkKind.bangumi);
      expect(code.pgcRef, 'ep98603');
    });

    test('无链接文本 / 空串 → null（什么都不做）', () {
      expect(parseClipboardLink('今天天气不错，晚上吃啥'), isNull);
      expect(parseClipboardLink(''), isNull);
      expect(parseClipboardLink('   \n  '), isNull);
      expect(parseClipboardLink('随便一句 https://example.com/a 外链'), isNull);
    });

    test('UP 空间链接不算视频（继续往后找真正的视频链接）', () {
      expect(parseClipboardLink('https://space.bilibili.com/12345'), isNull);
      final hit = parseClipboardLink(
          'https://space.bilibili.com/12345 然后这个 https://www.bilibili.com/video/$_bv');
      expect(hit?.bvid, _bv);
    });

    test('链接尾部粘连标点/中文会被裁掉', () {
      final hit = parseClipboardLink(
          '给：https://www.bilibili.com/video/$_bv。看完记得说一声');
      expect(hit?.bvid, _bv);
      expect(hit!.raw.endsWith(_bv), isTrue);
    });
  });

  group('resolveClipboardShortLink（b23 重定向）', () {
    test('落点视频 → video 命中（含落点定位参数）', () async {
      final hit = parseClipboardLink(_shareTextShort)!;
      final resolved = await resolveClipboardShortLink(
        hit,
        dio: _dioWith(Uri.parse('https://www.bilibili.com/video/$_bv/?p=3&t=60')),
      );
      expect(resolved!.kind, ClipboardLinkKind.video);
      expect(resolved.bvid, _bv);
      expect(resolved.pageIndex, 2);
      expect(resolved.positionMs, 60000);
      expect(resolved.raw, hit.raw, reason: '去重键仍是剪贴板原文（短链）');
    });

    test('落点番剧 → bangumi', () async {
      final hit = parseClipboardLink(_shareTextShort)!;
      final resolved = await resolveClipboardShortLink(
        hit,
        dio: _dioWith(Uri.parse('https://www.bilibili.com/bangumi/play/ep98603')),
      );
      expect(resolved!.kind, ClipboardLinkKind.bangumi);
      expect(resolved.pgcRef, 'ep98603');
    });

    test('落点非视频（活动页）→ null', () async {
      final hit = parseClipboardLink(_shareTextShort)!;
      expect(
        await resolveClipboardShortLink(
          hit,
          dio: _dioWith(Uri.parse('https://www.bilibili.com/blackboard/activity.html')),
        ),
        isNull,
      );
    });

    test('网络失败 → 抛「短链解析失败」', () async {
      final hit = parseClipboardLink(_shareTextShort)!;
      await expectLater(
        resolveClipboardShortLink(hit, dio: _dioWith(null)),
        throwsA(isA<ImportParseException>()),
      );
    });
  });

  group('ClipboardLinkProbe 探测流程', () {
    test('命中完整链接 → opened + 完整视频 + 记下已处理', () async {
      final ctx = _probeWith(_shareTextFull);
      final result = await ctx.probe.probe();

      expect(result.status, ClipboardOpenStatus.opened);
      expect(result.video!.bvid, _bv);
      expect(result.video!.cid, 12345);
      expect(result.video!.title, '剪贴板里的视频');
      expect(result.video!.pages!.single.part, 'P1');
      expect(ctx.api.calls, 1);
      expect(ClipboardLinkStore.instance.lastHandledKey, result.link);
    });

    test('同一条链接第二次启动 → duplicate（一次元数据请求都不发）', () async {
      final ctx = _probeWith(_shareTextFull);
      final first = await ctx.probe.probe();
      expect(first.status, ClipboardOpenStatus.opened);
      expect(ctx.api.calls, 1);

      final second = await ctx.probe.probe();
      expect(second.status, ClipboardOpenStatus.duplicate);
      expect(second.video, isNull);
      expect(ctx.api.calls, 1, reason: '去重命中最先判定，不再取元数据');
    });

    test('换一条链接（剪贴板变了）→ 又能跳', () async {
      final ctx = _probeWith(_shareTextFull);
      await ctx.probe.probe();
      final other = _probeWith('【另一个】https://www.bilibili.com/video/BV1xX7yY6zZ5');
      final result = await other.probe.probe();
      expect(result.status, ClipboardOpenStatus.opened);
      expect(result.video!.bvid, 'BV1xX7yY6zZ5');
    });

    test('b23 短链 → 解析后 opened', () async {
      final ctx = _probeWith(
        _shareTextShort,
        dio: _dioWith(Uri.parse('https://www.bilibili.com/video/$_bv/?share_source=copy_web')),
      );
      final result = await ctx.probe.probe();
      expect(result.status, ClipboardOpenStatus.opened);
      expect(result.video!.bvid, _bv);
    });

    test('b23 短链解析失败 → failed + 提示「短链解析失败」', () async {
      final ctx = _probeWith(_shareTextShort, dio: _dioWith(null));
      final result = await ctx.probe.probe();
      expect(result.status, ClipboardOpenStatus.failed);
      expect(result.message, '短链解析失败');
      expect(result.video, isNull, reason: '失败不跳空白页');
      expect(ClipboardLinkStore.instance.lastHandledKey, '',
          reason: '失败不记为"已处理"：下次启动还能再试');
    });

    test('开关关掉 → disabled，且**完全没有读剪贴板**', () async {
      final ctx = _probeWith(_shareTextFull, enabled: false);
      final result = await ctx.probe.probe();
      expect(result.status, ClipboardOpenStatus.disabled);
      expect(ctx.reads, isEmpty);
      expect(ctx.api.calls, 0);
    });

    test('剪贴板里没有视频链接 → none（不打扰）', () async {
      final ctx = _probeWith('今天要买牛奶、鸡蛋，顺便取快递');
      final result = await ctx.probe.probe();
      expect(result.status, ClipboardOpenStatus.none);
      expect(ctx.reads.length, 1);
      expect(ctx.api.calls, 0);
    });

    test('剪贴板为空 / 读剪贴板抛异常 → none（静默，不打扰）', () async {
      final empty = _probeWith('   ');
      expect((await empty.probe.probe()).status, ClipboardOpenStatus.none);

      final boom = _probeWith(null, throwOnRead: true);
      expect((await boom.probe.probe()).status, ClipboardOpenStatus.none);
    });

    test('番剧链接 → none（App 无通用番剧播放入口，不跳也不弹提示）', () async {
      final ctx = _probeWith('https://www.bilibili.com/bangumi/play/ss5800');
      final result = await ctx.probe.probe();
      expect(result.status, ClipboardOpenStatus.none);
      expect(ctx.api.calls, 0);
    });

    test('取元数据失败（稿件失效）→ failed + 不记已处理', () async {
      final api = _FakeBiliApi(
        error: const BiliApiException(
          code: 62002,
          message: '稿件已失效',
          path: '/x/web-interface/view',
        ),
      );
      final ctx = _probeWith(_shareTextFull, api: api);
      final result = await ctx.probe.probe();
      expect(result.status, ClipboardOpenStatus.failed);
      expect(result.message, '获取视频信息失败：稿件已失效');
      expect(ClipboardLinkStore.instance.lastHandledKey, '');
    });
  });

  group('ClipboardLinkStore', () {
    test('默认开启；写开关 / 记已处理后能从盘上读回', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ClipboardLinkStore.instance;
      store.resetForTest();
      await store.ensureLoaded();
      expect(store.enabled, isTrue, reason: '默认开（用户明确要这个功能）');
      expect(store.lastHandledKey, '');

      await store.setEnabled(false);
      await store.markHandled('BV1yE8r6KErQ');
      // 模拟"重启"：清内存态（loaded=false）后重新读盘
      store.resetForTest();
      await store.ensureLoaded();
      expect(store.enabled, isFalse);
      expect(store.lastHandledKey, 'BV1yE8r6KErQ');

      store.resetForTest();
    });
  });
}
