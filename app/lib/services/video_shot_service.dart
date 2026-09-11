/// 进度条拖动预览的雪碧图服务：**按需加载 + 降采样解码 + LRU 缓存 + 时间→图像**。
///
/// ## 为什么必须降采样（本模块存在的唯一理由）
/// B 站预览雪碧图长视频实测 4800×2700，**全尺寸解码成 RGBA8888 一张就要
/// 4800×2700×4 ≈ 51.8MB**（≈52MB）。长视频有 8 张，全下全解 = 400MB+，
/// 必 OOM。所以本服务：
/// 1. **只下当前时间对应的那一张**（`index[]` 二分 → 格 → 张）；
/// 2. 解码走 `ImageDescriptor`（只读文件头拿原始尺寸）+ `instantiateCodec
///    (targetWidth: ...)` **降采样**，把单张压到 ≤1.5M 像素 ≈5.7MB；
/// 3. 解码结果进 **LRU（容量 2）**，淘汰时 `ui.Image.dispose()` 立刻归还原生内存。
///
/// ## 设计取舍
/// - **网络**：统一用 dio（项目既有 HTTP 客户端）+ [biliHeaders]（i0.hdslb.com
///   有防盗链，必须带 Referer/UA），不引入任何图片库（项目无
///   `cached_network_image`，也不需要——我们自己管解码与缓存）。
/// - **失败静默**：任何异常只 `debugPrint` + 返回 null。预览是增强功能，
///   接口挂了 / 网络断了不能影响拖动与播放（调用方降级成只显示时间气泡）。
/// - **并发去重**：快速拖动会高频调 [frameAtMs]，同一张雪碧图用 in-flight
///   `Future` 复用，保证**只下载一次**。
/// - **按时效自证，不按请求先后**：返回的 [SeekPreviewFrame] 带
///   [SeekPreviewFrame.spriteIndex]，调用方据此判「还是不是当前需要的那张」，
///   而不是「请求序号是否最新」（后者会把同张图里**完全可用**的迟到结果丢掉）。
///   [prefetchAtMs] 供调用方预热「当前播放位置」那一张，省掉首次拖动的等待。
/// - ⚠️ 淘汰会 `dispose()` 掉旧图：调用方（UI）拿到 [SeekPreviewFrame] 后应
///   尽快用掉、不要把 `sprite` 长期持有跨越多帧；连续加载也可能让「上一帧
///   引用的图」被释放（容量 2 = 当前张 + 前一张，正常拖动顺序下安全）。
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Rect;

import '../api/bilibili_api.dart';
import '../config.dart';
import '../models/video_shot.dart';

/// 拉取预览图元信息（默认走 [BiliApi.fetchVideoShot]；单测注入 fake）。
typedef VideoShotFetcher = Future<VideoShotInfo> Function(String bvid, int index);

/// 下载雪碧图原始字节（默认走 dio + 浏览器头；单测注入 fake，不触网）。
typedef SpriteBytesLoader = Future<Uint8List> Function(String url);

/// 降采样解码。
///
/// 实现**必须**先拿到原始尺寸（**只读文件头、不解码像素**）再调
/// [pickTargetWidth] 决定目标宽度，绝不能先全尺寸解码——
/// 全尺寸解码一张就是 ≈52MB（见库注释）。
typedef SpriteDecoder = Future<ui.Image> Function(
  Uint8List bytes,
  int Function(int srcWidth, int srcHeight) pickTargetWidth,
);

/// 一帧可绘制的预览图：雪碧图 + 该帧在其中的裁剪矩形。
///
/// UI 侧典型用法：`canvas.drawImageRect(sprite, srcRect, dst, paint)`。
@immutable
class SeekPreviewFrame {
  /// 已降采样的雪碧图（**不要 dispose，服务在淘汰时统一释放**）。
  final ui.Image sprite;

  /// 在 [sprite] 中的裁剪矩形（已按降采样比例缩放，可直接用于 src 参数）。
  final Rect srcRect;

  /// 该帧对应的秒数（气泡里的时间文字）。
  final int seconds;

  /// [sprite] 的尺寸（即降采样后的尺寸）。
  final int spriteWidth;
  final int spriteHeight;

  /// [sprite] 是第几张雪碧图（= 这帧画面属于哪一段区间）。
  ///
  /// UI 侧据它判「这个结果还是不是当前需要的」——同一张雪碧图里的迟到结果
  /// **仍然可用**（图就是当前这张，只有裁剪矩形对应的是发起时的格），换张了
  /// 才必须丢掉（否则会显示错误区段的画面）。
  final int spriteIndex;

  const SeekPreviewFrame({
    required this.sprite,
    required this.srcRect,
    required this.seconds,
    required this.spriteWidth,
    required this.spriteHeight,
    required this.spriteIndex,
  });

  /// 换到**同一张雪碧图**内的另一格（[sprite] 原样复用）。
  ///
  /// 调用方必须自行保证 [srcRect] 落在 [spriteIndex] 这张图内（本方法不做
  /// 校验）；典型场景见 `player_page.dart` 的落地逻辑：图是按发起时的格下好
  /// 的，回来时手指可能已经移到同张图内的另一格，于是用它把裁剪矩形改到
  /// 当前位置。
  SeekPreviewFrame withCell({required Rect srcRect, required int seconds}) =>
      SeekPreviewFrame(
        sprite: sprite,
        srcRect: srcRect,
        seconds: seconds,
        spriteWidth: spriteWidth,
        spriteHeight: spriteHeight,
        spriteIndex: spriteIndex,
      );
}

/// 进度条拖动预览的雪碧图服务。
class VideoShotService {
  /// LRU 容量：当前张 + 前一张就够（拖动方向来回时命中率高，内存翻倍可控）。
  final int cacheCapacity;

  BiliApi? _api;
  final Dio? _injectedDio;

  /// 懒构造的 dio（只用于下载雪碧图字节）。
  Dio? _spriteDioInstance;

  final VideoShotFetcher? _fetcher;
  final SpriteBytesLoader? _bytesLoader;
  final SpriteDecoder? _decoder;
  final void Function(ui.Image image)? _disposer;

  VideoShotInfo? _info;
  String? _bvid;
  int _index = 1;
  bool _disposed = false;

  /// 缓存代次：切视频/分P 时自增，用于丢弃「上一代」迟到的 in-flight 结果。
  int _generation = 0;

  /// 解码后的雪碧图（key = 雪碧图下标）。按访问顺序排列实现 LRU。
  final LinkedHashMap<int, ui.Image> _cache = LinkedHashMap<int, ui.Image>();

  /// in-flight 下载/解码（同一张只走一次）。
  final Map<int, Future<ui.Image?>> _inFlight = {};

  VideoShotService({
    BiliApi? api,
    Dio? dio,
    VideoShotFetcher? fetcher,
    SpriteBytesLoader? bytesLoader,
    SpriteDecoder? decoder,
    void Function(ui.Image image)? disposer,
    this.cacheCapacity = 2,
  }) : assert(cacheCapacity > 0, 'LRU 容量至少为 1'),
       _api = api,
       _injectedDio = dio,
       _fetcher = fetcher,
       _bytesLoader = bytesLoader,
       _decoder = decoder,
       _disposer = disposer;

  /// 单格目标显示宽度（逻辑像素）。
  ///
  /// 预览浮层里单格大约显示 120~160 逻辑像素宽，取 160 保证不糊（手机
  /// 2x~3x DPR 下也够看，比 B 站网页版预览框还略宽）。
  static const int kPreviewCellWidth = 160;

  /// 解码后像素上限：1_500_000 px × 4B(RGBA8888) ≈ 5.7MB，
  /// 压在「单张解码后 ≤ 6MB」的目标内。
  static const int kMaxDecodedPixels = 1500000;

  /// 元信息是否就绪（就绪才可能有预览；失败/未 prepare 都是 false）。
  bool get isReady {
    final info = _info;
    return !_disposed &&
        info != null &&
        info.shotCount > 0 &&
        info.perSprite > 0 &&
        info.spriteUrls.isNotEmpty;
  }

  /// 已拿到的元信息（未就绪为 null）。
  VideoShotInfo? get info => _info;

  /// 预先拉取元信息（播放页进入后异步调一次）。
  ///
  /// **失败静默**：接口挂了只留 `isReady == false`，调用方降级（不抛到 UI）。
  /// 同一 bvid + 分P 且已就绪 → 直接返回（不重复请求）。
  Future<void> prepare(String bvid, {int index = 1}) async {
    if (_disposed || bvid.isEmpty) return;
    if (_bvid == bvid && _index == index && isReady) return;
    _reset();
    _bvid = bvid;
    _index = index;
    final gen = _generation;
    try {
      final info = await _fetchMeta(bvid, index);
      // 期间又切了视频/分P（或已 dispose）→ 丢弃迟到结果
      if (_disposed || gen != _generation) return;
      _info = info;
      debugPrint('[video_shot] 元信息就绪 bvid=$bvid p$index: '
          '${info.shotCount} 帧 / ${info.spriteUrls.length} 张雪碧图'
          '（${info.xLen}x${info.yLen} 格，单格 ${info.xSize}x${info.ySize}）');
    } catch (e) {
      debugPrint('[video_shot] 拉取预览图元信息失败（降级：拖动只显示时间气泡）: $e');
    }
  }

  /// 取某时间点（毫秒）的缩略图。
  ///
  /// 未就绪 / 加载中失败 / 参数越界 → 返回 null（调用方降级成只显示时间气泡）。
  /// **任何异常都在内部吞掉，不会抛到 UI 层。**
  ///
  /// 返回值里的 `srcRect` 对应**本次请求的时间点**、`spriteIndex` 对应它落在
  /// 第几张雪碧图 —— 调用方异步拿到它时两者都可能已经不是「当前」的了：
  /// 同张图内应该按当前位置重裁剪（[SeekPreviewFrame.withCell]），换张则丢弃。
  Future<SeekPreviewFrame?> frameAtMs(int ms) async {
    if (_disposed) return null;
    final info = _info;
    if (info == null || info.shotCount == 0) return null;
    final seconds = ms <= 0 ? 0 : ms ~/ 1000;
    final shot = info.shotIndexForSeconds(seconds);
    if (shot < 0) return null;
    final cell = info.cellForShot(shot);
    if (cell.width <= 0 || cell.height <= 0) return null;
    try {
      final sprite = await _spriteImage(cell.spriteIndex, info);
      if (sprite == null || _disposed) return null;
      final scale = cellScale(spriteWidth: sprite.width, info: info);
      return SeekPreviewFrame(
        sprite: sprite,
        srcRect: Rect.fromLTWH(
          cell.left * scale,
          cell.top * scale,
          cell.width * scale,
          cell.height * scale,
        ),
        seconds: info.indexSeconds[shot],
        spriteWidth: sprite.width,
        spriteHeight: sprite.height,
        spriteIndex: cell.spriteIndex,
      );
    } catch (e) {
      debugPrint('[video_shot] frameAtMs($ms) 失败（降级：无预览）: $e');
      return null;
    }
  }

  /// 把某时间点所在的**那一张**雪碧图送进 LRU（不构造帧）。
  ///
  /// 给「用户最可能拖到的位置」预热：首次拖动慢，是慢在图要现下现解
  /// （实测一张 1.5~2.5s），而一轮拖动往往早就结束了；提前拉好当前播放位置
  /// 那一张，第一次按住拖动就有图。
  ///
  /// 已经把 [prepare] 拉到的元信息用上（未就绪 → 直接返回）。已在缓存 / 正在
  /// 下载的那一张由服务层去重 → 重复调用不产生任何请求。失败静默（与
  /// [frameAtMs] 同：任何异常只 debugPrint，不影响播放）。
  Future<void> prefetchAtMs(int ms) async {
    if (_disposed) return;
    final info = _info;
    if (info == null || info.shotCount == 0) return;
    final seconds = ms <= 0 ? 0 : ms ~/ 1000;
    final shot = info.shotIndexForSeconds(seconds);
    if (shot < 0) return;
    final cell = info.cellForShot(shot);
    if (cell.width <= 0 || cell.height <= 0) return;
    try {
      await _spriteImage(cell.spriteIndex, info);
    } catch (e) {
      debugPrint('[video_shot] 预取雪碧图#${cell.spriteIndex} 失败（忽略）: $e');
    }
  }

  /// 释放全部缓存与资源（页面退出时调；可重复调）。
  void dispose() {
    _disposed = true;
    _reset();
  }

  /// 清空元信息 + 释放所有缓存图，并让在途加载作废。
  void _reset() {
    _generation++;
    _info = null;
    for (final image in _cache.values) {
      _disposeImage(image);
    }
    _cache.clear();
    _inFlight.clear();
  }

  // -------------------------------------------------------------------------
  // 缓存的图层
  // -------------------------------------------------------------------------

  /// 取某张雪碧图的解码结果：命中缓存 → 刷新 LRU 顺序；在途 → 复用同一个
  /// `Future`（**同一张只下载一次**）；否则发起加载。
  Future<ui.Image?> _spriteImage(int spriteIndex, VideoShotInfo info) {
    final cached = _cache.remove(spriteIndex);
    if (cached != null) {
      _cache[spriteIndex] = cached; // 删了重插 = 标记为最近使用
      return Future<ui.Image?>.value(cached);
    }
    final pending = _inFlight[spriteIndex];
    if (pending != null) return pending;
    final future = _loadSprite(spriteIndex, info);
    _inFlight[spriteIndex] = future;
    return future.whenComplete(() {
      // 只清掉自己那一格（可能已被下一代的同名请求覆盖）
      if (identical(_inFlight[spriteIndex], future)) {
        _inFlight.remove(spriteIndex);
      }
    });
  }

  /// 下载 + 降采样解码 + 入 LRU。失败返回 null（静默降级）。
  Future<ui.Image?> _loadSprite(int spriteIndex, VideoShotInfo info) async {
    if (spriteIndex < 0 || spriteIndex >= info.spriteUrls.length) return null;
    final gen = _generation;
    final url = info.spriteUrls[spriteIndex];
    try {
      final bytes = await _loadBytes(url);
      if (bytes.isEmpty) {
        debugPrint('[video_shot] 雪碧图#$spriteIndex 下载为空（$url）');
        return null;
      }
      int? picked;
      final image = await _decode(bytes, (srcWidth, srcHeight) {
        picked = computeTargetWidth(
          xLen: info.xLen,
          xSize: info.xSize,
          srcWidth: srcWidth,
          srcHeight: srcHeight,
        );
        return picked!;
      });
      debugPrint('[video_shot] 雪碧图#$spriteIndex 解码完成：'
          '${image.width}x${image.height}'
          '（targetWidth=$picked，≈${_mb(image.width * image.height)}MB）');
      if (_disposed || gen != _generation) {
        // 期间切了视频/分P：这张已无主，直接释放，不进新缓存
        _disposeImage(image);
        return null;
      }
      _put(spriteIndex, image);
      return image;
    } catch (e) {
      debugPrint('[video_shot] 雪碧图#$spriteIndex 加载失败（降级：无预览）: $e');
      return null;
    }
  }

  /// 入缓存 + LRU 淘汰（淘汰即 `dispose()`，立即归还原生像素内存）。
  void _put(int spriteIndex, ui.Image image) {
    final old = _cache.remove(spriteIndex);
    if (old != null) _disposeImage(old);
    _cache[spriteIndex] = image;
    while (_cache.length > cacheCapacity) {
      final oldestKey = _cache.keys.first;
      final evicted = _cache.remove(oldestKey);
      if (evicted != null) {
        debugPrint('[video_shot] LRU 淘汰雪碧图#$oldestKey（释放其像素内存）');
        _disposeImage(evicted);
      }
    }
  }

  void _disposeImage(ui.Image image) {
    final disposer = _disposer;
    if (disposer != null) {
      // 测试注入的释放钩子：完全接管释放动作（便于计数断言）
      disposer(image);
      return;
    }
    image.dispose();
  }

  // -------------------------------------------------------------------------
  // 降采样比例
  // -------------------------------------------------------------------------

  /// 降采样后的图 → 元信息里的格的**缩放系数**（纯函数，便于单测）。
  ///
  /// `scale = 解码后单格宽 / 元信息单格宽 = (spriteWidth / xLen) / xSize`，
  /// 乘到格坐标上就是 [SeekPreviewFrame.srcRect]。元信息缺失（单格宽 0）→
  /// 1.0（不缩放，退回原始坐标）。
  static double cellScale({
    required int spriteWidth,
    required VideoShotInfo info,
  }) {
    if (info.xSize <= 0 || info.xLen <= 0) return 1.0;
    return (spriteWidth / info.xLen) / info.xSize;
  }

  /// 由「原图尺寸 + 网格」反推解码目标宽度（**纯函数**，便于单测）。
  ///
  /// 取两个约束的较小值：
  /// 1. **清晰度**：希望解码后单格宽 ≈ [kPreviewCellWidth]（160），
  ///    所需整图宽 = `原宽 × 160 / 单格宽`（等价于 `160 × 列数`）；
  /// 2. **内存**：解码像素数 ≤ [kMaxDecodedPixels]（≈5.7MB）。
  ///    等比缩放时 `w² × srcH/srcW ≤ maxPx` → `w ≤ sqrt(maxPx × srcW / srcH)`。
  ///
  /// 再与 `srcWidth` 取小（**不放大**）。
  ///
  /// 实测：4800×2700（单格 480×270）→ byCell=1600、byMemory≈1632 →
  /// **targetWidth=1600**，解码 1600×900 = 1.44M px ≈ **5.76MB**（vs 全尺寸 52MB），
  /// 单格 160×90 仍足够预览。
  static int computeTargetWidth({
    required int xLen,
    required int xSize,
    required int srcWidth,
    required int srcHeight,
  }) {
    if (srcWidth <= 0) return 1;
    final cols = xLen > 0 ? xLen : 1;
    final byCell = xSize > 0
        ? (srcWidth * kPreviewCellWidth / xSize).round()
        : kPreviewCellWidth * cols;
    final byMemory = srcHeight > 0
        ? math.sqrt(kMaxDecodedPixels * srcWidth / srcHeight).floor()
        : byCell;
    final target = math.min(byCell, byMemory);
    return math.max(1, math.min(srcWidth, target));
  }

  static String _mb(int pixels) =>
      (pixels * 4 / 1024 / 1024).toStringAsFixed(2);

  // -------------------------------------------------------------------------
  // 注入点：默认实现（生产路径）
  // -------------------------------------------------------------------------

  Future<VideoShotInfo> _fetchMeta(String bvid, int index) {
    final fetcher = _fetcher;
    if (fetcher != null) return fetcher(bvid, index);
    return (_api ??= BiliApi()).fetchVideoShot(bvid, index: index);
  }

  /// dio 懒构造（注入 fetcher/bytesLoader 的单测不会走到这里，也就不会
  /// 触碰 BiliApi 的安全存储初始化）。
  Dio get _spriteDio =>
      _injectedDio ??
      (_spriteDioInstance ??= Dio(
        BaseOptions(
          // i0.hdslb.com 图床有防盗链：必须带 Referer + 浏览器 UA
          headers: biliHeaders(),
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      ));

  Future<Uint8List> _loadBytes(String url) {
    final loader = _bytesLoader;
    if (loader != null) return loader(url);
    return _defaultLoadBytes(url);
  }

  Future<Uint8List> _defaultLoadBytes(String url) async {
    final resp = await _spriteDio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) return Uint8List(0);
    return data is Uint8List ? data : Uint8List.fromList(data);
  }

  Future<ui.Image> _decode(
    Uint8List bytes,
    int Function(int srcWidth, int srcHeight) pickTargetWidth,
  ) {
    final decoder = _decoder;
    if (decoder != null) return decoder(bytes, pickTargetWidth);
    return _defaultDecode(bytes, pickTargetWidth);
  }

  /// 生产解码：**先读文件头拿原始尺寸（不解码像素）**，再按目标宽度降采样解码。
  ///
  /// 对比 `ui.instantiateImageCodec(bytes)`（不给 targetWidth）——那条路会
  /// 先按原始尺寸解码，4800×2700 就是 ≈52MB 的瞬时峰值，绝对不能用。
  Future<ui.Image> _defaultDecode(
    Uint8List bytes,
    int Function(int srcWidth, int srcHeight) pickTargetWidth,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final targetWidth = pickTargetWidth(descriptor.width, descriptor.height);
      final codec = await descriptor.instantiateCodec(targetWidth: targetWidth);
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
