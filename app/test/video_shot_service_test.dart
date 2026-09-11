/// 进度条预览雪碧图服务单测（**全部注入 fake，不触网、不碰播放器**）。
///
/// 覆盖：
/// - 未 prepare / prepare 失败 → `isReady == false`、`frameAtMs` 返回 null
///   （**不抛异常**，UI 可降级）
/// - 同一张雪碧图只下载一次（缓存命中 + 并发 in-flight 去重）
/// - 跨张切换：按需再下载；LRU（容量 2）淘汰时旧 `ui.Image` 被释放
/// - 降采样比例 [VideoShotService.computeTargetWidth]：单格 160 宽 + 内存上限；
///   裁剪缩放系数 [VideoShotService.cellScale]
/// - 解码/网络失败静默返回 null；dispose / 换视频释放缓存
/// - `frameAtMs` 返回的帧带 `spriteIndex`（UI 判「还是不是当前这张图」用）
/// - [VideoShotService.prefetchAtMs] 预取：命中缓存 / 重复调用零成本 / 失败静默
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Rect;
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/video_shot.dart';
import 'package:bili_whitelist_app/services/video_shot_service.dart';

// ---------------------------------------------------------------------------
// 工具：真实 ui.Image（用 dart:ui 直接造，不依赖图片文件/第三方库）
// ---------------------------------------------------------------------------

Future<ui.Image> _makeImage(int width, int height) async {
  final pixels = Uint8List(width * height * 4);
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// 造样本：xLen*yLen 网格，index 每 5 秒一张。
VideoShotInfo _info({
  int spriteCount = 1,
  int shotCount = 300,
  int xLen = 10,
  int yLen = 10,
  int xSize = 80,
  int ySize = 45,
}) =>
    VideoShotInfo(
      spriteUrls: List.generate(
        spriteCount,
        (i) => 'https://i0.hdslb.com/bfs/videoshot/sprite$i.jpg',
      ),
      xLen: xLen,
      yLen: yLen,
      xSize: xSize,
      ySize: ySize,
      indexSeconds: List.generate(shotCount, (i) => i * 5),
    );

// ---------------------------------------------------------------------------
// fake 依赖
// ---------------------------------------------------------------------------

class _FakeFetcher {
  final List<String> calls = <String>[];
  VideoShotInfo? result;
  Object? error;
  Completer<void>? gate;

  Future<VideoShotInfo> call(String bvid, int index) async {
    calls.add('$bvid#$index');
    final g = gate;
    if (g != null) await g.future;
    if (error != null) throw error!;
    return result!;
  }
}

class _FakeLoader {
  final List<String> urls = <String>[];
  final Map<String, Uint8List> payloads = <String, Uint8List>{};
  Object? error;
  Completer<void>? gate;

  Future<Uint8List> call(String url) async {
    urls.add(url);
    final g = gate;
    if (g != null) await g.future;
    if (error != null) throw error!;
    return payloads[url] ?? Uint8List.fromList(const [1, 2, 3, 4]);
  }
}

class _FakeDecoder {
  /// 依次记录每次请求的 `targetWidth`（断言降采样比例用）。
  final List<int> targetWidths = <int>[];

  /// 冒充「原图尺寸」（生产路径由 `ImageDescriptor` 读文件头得到）。
  int srcWidth = 800;
  int srcHeight = 450;

  /// 返回图的宽度（null = 与 targetWidth 一致，模拟真实等比降采样）。
  int? forceWidth;

  /// 返回图的高度（测试里给个极小的值省内存）。
  int forceHeight = 8;

  final List<ui.Image> created = <ui.Image>[];
  Object? error;

  Future<ui.Image> call(
    Uint8List bytes,
    int Function(int srcWidth, int srcHeight) pickTargetWidth,
  ) async {
    final tw = pickTargetWidth(srcWidth, srcHeight);
    targetWidths.add(tw);
    if (error != null) throw error!;
    final image = await _makeImage(forceWidth ?? tw, forceHeight);
    created.add(image);
    return image;
  }
}

/// 一把手（fake fetcher/loader/decoder + 释放计数器）。
class _Harness {
  final _FakeFetcher fetcher = _FakeFetcher();
  final _FakeLoader loader = _FakeLoader();
  final _FakeDecoder decoder = _FakeDecoder();

  /// 被服务释放掉的图（LRU 淘汰 / dispose / 换视频）。
  final List<ui.Image> disposed = <ui.Image>[];

  late final VideoShotService service;

  _Harness({int cacheCapacity = 2}) {
    service = VideoShotService(
      fetcher: fetcher.call,
      bytesLoader: loader.call,
      decoder: decoder.call,
      disposer: _dispose,
      cacheCapacity: cacheCapacity,
    );
  }

  void _dispose(ui.Image image) {
    disposed.add(image);
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('未就绪 / 失败路径：一律 null，不抛异常', () {
    test('未 prepare：isReady=false、info=null、frameAtMs=null 且不发请求', () async {
      final h = _Harness();
      expect(h.service.isReady, isFalse);
      expect(h.service.info, isNull);

      expect(await h.service.frameAtMs(0), isNull);
      expect(await h.service.frameAtMs(12345), isNull);
      expect(h.fetcher.calls, isEmpty);
      expect(h.loader.urls, isEmpty);
    });

    test('prepare 失败（接口抛错）→ isReady=false，frameAtMs 静默 null', () async {
      final h = _Harness();
      h.fetcher.error = Exception('boom 风控');

      await h.service.prepare('BV1TEST'); // 不应抛
      expect(h.service.isReady, isFalse);
      expect(h.service.info, isNull);
      expect(await h.service.frameAtMs(1000), isNull);
      expect(h.loader.urls, isEmpty);
    });

    test('元信息就绪但雪碧图 URL 为空 → isReady=false', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 0);
      await h.service.prepare('BV1TEST');
      expect(h.service.isReady, isFalse);
      expect(await h.service.frameAtMs(1000), isNull);
    });

    test('下载抛错 → frameAtMs=null（不抛）；下载空字节 → null', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');

      h.loader.error = Exception('403 防盗链');
      expect(await h.service.frameAtMs(0), isNull);
      expect(h.loader.urls.length, 1);

      h.loader.error = null;
      h.loader.payloads[h.loader.urls.first] = Uint8List(0);
      expect(await h.service.frameAtMs(0), isNull);
      expect(h.disposed, isEmpty);
    });

    test('解码抛错 → null（不抛），且未污染缓存（再请求会重试下载）', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');

      h.decoder.error = Exception('codec failed');
      expect(await h.service.frameAtMs(0), isNull);
      expect(h.loader.urls.length, 1);

      h.decoder.error = null;
      final frame = await h.service.frameAtMs(0);
      expect(frame, isNotNull);
      // 上一次失败没入缓存 → 重新下载了一次
      expect(h.loader.urls.length, 2);
    });

    test('prepare 传空 bvid → 直接跳过（不发请求）', () async {
      final h = _Harness();
      await h.service.prepare('');
      expect(h.fetcher.calls, isEmpty);
    });
  });

  group('正常路径：时间 → 图像', () {
    test('prepare 成功 → isReady=true；重复 prepare 不重复拉元信息', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');
      expect(h.service.isReady, isTrue);
      expect(h.service.info!.shotCount, 300);

      await h.service.prepare('BV1TEST'); // 同 bvid + 分P → 命中，不再请求
      expect(h.fetcher.calls.length, 1);

      await h.service.prepare('BV1TEST', index: 2); // 换分P → 重新请求
      expect(h.fetcher.calls, ['BV1TEST#1', 'BV1TEST#2']);
    });

    test('frameAtMs：srcRect / seconds / 尺寸都对（scale=1 不放大）', () async {
      final h = _Harness();
      h.fetcher.result = _info(); // xSize=80, 源图 800x450 → targetWidth=800
      await h.service.prepare('BV1TEST');

      // 500s → shot 100 → 第 2 张雪碧图第 0 格
      final f2 = await h.service.frameAtMs(500 * 1000);
      expect(f2, isNotNull);
      expect(f2!.srcRect, Rect.fromLTWH(0, 0, 80, 45));
      expect(f2.seconds, 500);
      expect(f2.spriteWidth, 800);

      // 5s → shot 1 → 第 1 张 (col=1, row=0)
      final f1 = await h.service.frameAtMs(5000);
      expect(f1!.srcRect, Rect.fromLTWH(80, 0, 80, 45));
      expect(f1.seconds, 5);

      // 95s → shot 19 → (col=9, row=1)
      final f3 = await h.service.frameAtMs(95 * 1000);
      expect(f3!.srcRect, Rect.fromLTWH(720, 45, 80, 45));
      expect(f3.seconds, 95);
    });

    test('时间钳到端点：负毫秒 → 0 秒；超过末尾 → 末帧秒数', () async {
      final h = _Harness();
      h.fetcher.result = _info(shotCount: 10, spriteCount: 1); // 0,5,...,45
      await h.service.prepare('BV1TEST');

      final first = await h.service.frameAtMs(-5000);
      expect(first!.seconds, 0);

      final last = await h.service.frameAtMs(99999999);
      expect(last!.seconds, 45);
    });

    test('返回值带 spriteIndex：UI 据此判「还是不是当前需要的那张图」', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 3); // 每张 100 格 × 5s
      await h.service.prepare('BV1TEST');

      expect((await h.service.frameAtMs(0))!.spriteIndex, 0);
      expect((await h.service.frameAtMs(500 * 1000))!.spriteIndex, 1);
      expect((await h.service.frameAtMs(1000 * 1000))!.spriteIndex, 2);
      // 元信息里的图张数比实际少 → 钳到末张（不越界），值仍是可比较的
      final h2 = _Harness();
      h2.fetcher.result = _info(spriteCount: 1);
      await h2.service.prepare('BV1TEST');
      expect((await h2.service.frameAtMs(1000 * 1000))!.spriteIndex, 0);
    });

    test('withCell：同张图换格只换裁剪矩形/秒数，图与图号原样复用', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 3);
      await h.service.prepare('BV1TEST');

      final f = (await h.service.frameAtMs(0))!;
      final other = f.withCell(srcRect: const Rect.fromLTWH(16, 0, 8, 5), seconds: 5);
      expect(identical(other.sprite, f.sprite), isTrue, reason: '同一张图复用');
      expect(other.spriteIndex, f.spriteIndex);
      expect(other.srcRect, const Rect.fromLTWH(16, 0, 8, 5));
      expect(other.seconds, 5);
      expect(other.spriteWidth, f.spriteWidth);
      expect(other.spriteHeight, f.spriteHeight);
    });
  });

  group('按需下载 + 并发去重 + LRU', () {
    test('同一张被多次请求 → 只下载 1 次', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');

      for (var i = 0; i < 5; i++) {
        expect(await h.service.frameAtMs(1000), isNotNull);
      }
      expect(h.loader.urls.length, 1);
      expect(h.decoder.targetWidths.length, 1);
    });

    test('并发请求同一张 → in-flight 去重，只下载 1 次', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');
      h.loader.gate = Completer<void>();

      final futures = [
        h.service.frameAtMs(1000),
        h.service.frameAtMs(1000),
        h.service.frameAtMs(1000),
      ];
      h.loader.gate!.complete();
      final frames = await Future.wait(futures);

      expect(frames.every((f) => f != null), isTrue);
      expect(h.loader.urls.length, 1);
      expect(h.decoder.targetWidths.length, 1);
    });

    test('跨张切换：各张按需下载；LRU=2 时第 3 张挤掉最旧的并释放', () async {
      final h = _Harness(); // cacheCapacity=2
      h.fetcher.result = _info(spriteCount: 3); // shot 0~99 第1张、100~199 第2张…
      await h.service.prepare('BV1TEST');

      await h.service.frameAtMs(0); // 第 1 张
      expect(h.loader.urls.length, 1);
      expect(h.disposed, isEmpty);

      await h.service.frameAtMs(500 * 1000); // 第 2 张（shot 100）
      expect(h.loader.urls.length, 2);
      expect(h.disposed, isEmpty); // 容量 2，还没淘汰

      await h.service.frameAtMs(1000 * 1000); // 第 3 张（shot 200）
      expect(h.loader.urls.length, 3);
      expect(h.disposed.length, 1); // 第 1 张被淘汰释放
      expect(h.disposed.single, h.decoder.created[0]);
    });

    test('LRU 命中不重复下载：两张之间来回拖动', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 3);
      await h.service.prepare('BV1TEST');

      await h.service.frameAtMs(500 * 1000); // 第 2 张
      await h.service.frameAtMs(1000 * 1000); // 第 3 张 → 恰好填满容量 2，无淘汰
      expect(h.loader.urls.length, 2);
      expect(h.disposed, isEmpty);

      await h.service.frameAtMs(500 * 1000); // 回到第 2 张 → 在缓存里
      await h.service.frameAtMs(1000 * 1000);
      await h.service.frameAtMs(500 * 1000);
      expect(h.loader.urls.length, 2); // 只有 2 张图，来回不新增下载
      expect(h.disposed, isEmpty);
    });

    test('手动小容量（1）：每次换张都立即释放上一张', () async {
      final h = _Harness(cacheCapacity: 1);
      h.fetcher.result = _info(spriteCount: 2);
      await h.service.prepare('BV1TEST');

      await h.service.frameAtMs(0);
      await h.service.frameAtMs(500 * 1000);
      expect(h.disposed.length, 1);
      expect(h.decoder.created.length, 2);
    });
  });

  group('预取（prefetchAtMs）：给「用户最可能拖到的位置」预热', () {
    test('预取该位置所在的张 → 之后 frameAtMs 直接命中，不再下载', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 3);
      await h.service.prepare('BV1TEST');

      await h.service.prefetchAtMs(500 * 1000); // 第 2 张（index 1）
      expect(h.loader.urls, [
        'https://i0.hdslb.com/bfs/videoshot/sprite1.jpg',
      ], reason: '预取的是该位置所属的那一张');

      final frame = await h.service.frameAtMs(500 * 1000);
      expect(frame!.spriteIndex, 1);
      expect(h.loader.urls.length, 1, reason: '已预取 → 拖动时零下载');
    });

    test('未就绪 / 重复预取：不发请求 / 只下载一次', () async {
      final h = _Harness();
      await h.service.prefetchAtMs(1000); // 还没 prepare
      expect(h.loader.urls, isEmpty);

      h.fetcher.result = _info(spriteCount: 3);
      await h.service.prepare('BV1TEST');
      await h.service.prefetchAtMs(0);
      await h.service.prefetchAtMs(0);
      await h.service.prefetchAtMs(1000); // 1s → 同一格 → 同一张
      expect(h.loader.urls.length, 1, reason: '同一张由缓存/in-flight 去重');
    });

    test('预取失败静默：下载抛错不抛到调用方', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');

      h.loader.error = Exception('403 防盗链');
      await h.service.prefetchAtMs(0); // 不应抛
      expect(h.loader.urls.length, 1);
    });

    test('dispose 后预取直接返回（不发请求）', () async {
      final h = _Harness();
      h.fetcher.result = _info();
      await h.service.prepare('BV1TEST');
      h.service.dispose();

      await h.service.prefetchAtMs(0);
      expect(h.loader.urls, isEmpty);
    });
  });

  group('降采样比例（硬指标：绝不整张全尺寸解码）', () {
    test('computeTargetWidth 纯函数：4800x2700 单格 480 → 1600（≈5.76MB）', () {
      final tw = VideoShotService.computeTargetWidth(
        xLen: 10,
        xSize: 480,
        srcWidth: 4800,
        srcHeight: 2700,
      );
      expect(tw, 1600);
      // 解码后 1600x900 = 1.44M px ≈ 5.76MB ≤ 6MB 目标
      final decodedPixels = tw * (tw * 2700 / 4800).round();
      expect(decodedPixels, lessThanOrEqualTo(VideoShotService.kMaxDecodedPixels));
      expect(decodedPixels * 4 / 1024 / 1024, lessThan(6.0));
      // 单格仍有 160 宽（够预览）
      expect(tw / 10, 160);
    });

    test('computeTargetWidth：小图不放大', () {
      expect(
        VideoShotService.computeTargetWidth(
          xLen: 10,
          xSize: 160,
          srcWidth: 1600,
          srcHeight: 900,
        ),
        1600,
      );
    });

    test('computeTargetWidth：极端长宽比时由内存上限收口', () {
      final tw = VideoShotService.computeTargetWidth(
        xLen: 10,
        xSize: 80,
        srcWidth: 800,
        srcHeight: 8000,
      );
      // byCell=1600 但内存上限更紧 → 收口
      expect(tw, lessThan(1600));
      final decodedPixels = tw * (tw * 8000 / 800).round();
      expect(decodedPixels, lessThanOrEqualTo(VideoShotService.kMaxDecodedPixels));
    });

    test('任意输入下解码像素都不超上限，且不小于 1', () {
      const cases = [
        [4800, 2700, 10, 480],
        [4800, 2700, 10, 160],
        [1920, 1080, 10, 192],
        [4000, 2250, 8, 500],
        [160, 90, 10, 16],
        [10000, 10000, 5, 2000],
      ];
      for (final c in cases) {
        final tw = VideoShotService.computeTargetWidth(
          xLen: c[2],
          xSize: c[3],
          srcWidth: c[0],
          srcHeight: c[1],
        );
        expect(tw, greaterThanOrEqualTo(1), reason: '$c');
        expect(tw, lessThanOrEqualTo(c[0]), reason: '$c');
        final pixels = tw * (tw * c[1] / c[0]).round();
        expect(
          pixels,
          lessThanOrEqualTo(VideoShotService.kMaxDecodedPixels),
          reason: '$c 解码 ${pixels}px',
        );
      }
    });

    test('非法元信息（单格宽 0）不崩、不放大', () {
      expect(
        VideoShotService.computeTargetWidth(
          xLen: 0,
          xSize: 0,
          srcWidth: 800,
          srcHeight: 450,
        ),
        lessThanOrEqualTo(800),
      );
    });

    test('cellScale：解码后单格宽 / 元信息单格宽（缺元信息退回 1）', () {
      // 1600 宽的整图 ÷ 10 列 = 单格 160，元信息单格 480 → 1/3
      expect(
        VideoShotService.cellScale(
          spriteWidth: 1600,
          info: _info(xLen: 10, xSize: 480),
        ),
        closeTo(1 / 3, 1e-9),
      );
      // 坐标原样透传（1.0）
      expect(
        VideoShotService.cellScale(
          spriteWidth: 800,
          info: _info(xLen: 10, xSize: 80),
        ),
        1.0,
      );
      // 非法元信息 → 1.0（不缩放，不崩）
      expect(
        VideoShotService.cellScale(
          spriteWidth: 800,
          info: _info(xLen: 0, xSize: 0),
        ),
        1.0,
      );
    });

    test('服务真的把 targetWidth 传给了解码器，单格裁剪仍是 160 宽', () async {
      final h = _Harness();
      h.decoder.srcWidth = 4800;
      h.decoder.srcHeight = 2700;
      h.fetcher.result = _info(spriteCount: 8, xSize: 480, ySize: 270);
      await h.service.prepare('BV1TEST');

      final frame = await h.service.frameAtMs(0);
      expect(h.decoder.targetWidths, [1600]); // ← 降采样发生在解码前
      expect(frame!.spriteWidth, 1600);
      // scale = (1600/10)/480 = 1/3 → 单格裁剪 160x90（清晰度达标）
      expect(frame.srcRect, Rect.fromLTWH(0, 0, 160, 90));
      expect(h.loader.urls.length, 1); // 只下了当前时间那一张
    });
  });

  group('资源释放', () {
    test('dispose()：释放全部缓存、之后 frameAtMs 一律 null、可重复调', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 2);
      await h.service.prepare('BV1TEST');
      await h.service.frameAtMs(0);
      await h.service.frameAtMs(500 * 1000);
      expect(h.disposed, isEmpty);

      h.service.dispose();
      expect(h.disposed.length, 2);
      expect(h.service.isReady, isFalse);
      expect(await h.service.frameAtMs(0), isNull);

      h.service.dispose(); // 幂等：不重复释放
      expect(h.disposed.length, 2);
    });

    test('换视频（prepare 另一个 bvid）→ 旧图释放、重新拉元信息', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 2);
      await h.service.prepare('BV1TEST');
      await h.service.frameAtMs(0);

      await h.service.prepare('BV2OTHER');
      expect(h.disposed.length, 1);
      expect(h.fetcher.calls, ['BV1TEST#1', 'BV2OTHER#1']);

      // 新视频用新缓存（旧的已释放）
      final frame = await h.service.frameAtMs(0);
      expect(frame, isNotNull);
    });

    test('dispose 期间切视频：迟到的在途解码结果被丢弃并释放', () async {
      final h = _Harness();
      h.fetcher.result = _info(spriteCount: 2);
      await h.service.prepare('BV1TEST');
      h.loader.gate = Completer<void>();

      final pending = h.service.frameAtMs(0); // 卡在下载
      h.service.dispose();
      h.loader.gate!.complete();

      expect(await pending, isNull);
      expect(h.disposed.length, 1); // 迟到的那张被丢弃并释放
    });
  });
}
