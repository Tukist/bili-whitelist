/// 评论图片全屏查看页（v2.16.19+）。
///
/// 功能：
/// - 黑底 PageView 多图左右滑动（单图不显示页码/不可滑也无妨），顶部
///   显示「当前页/总数」页码与关闭按钮
/// - 每张图 InteractiveViewer 双指缩放（1x~4x），双击在 1x ↔ 2.5x 切换；
///   缩放到 1x 时禁止平移 → 左右滑动交给 PageView 翻页（放大时优先平移
///   看图，边缘到页再继续划为翻页由 InteractiveViewer 处理，两者不打架）
/// - 底部「保存」按钮：下载当前图字节（Dart 侧带 UA/Referer）→ 原生
///   MethodChannel（MediaStore，见 services/gallery_saver.dart）存入系统
///   相册，保存结果 SnackBar 提示
///
/// 图片加载失败显示灰底占位（防整页白屏）。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../services/gallery_saver.dart';

/// 图片/头像请求兜底头：与评论页一致（i*.hdslb.com 一般无需 Referer，
/// 带上浏览器头更稳）。
const Map<String, String> _imgHeaders = {
  'User-Agent': kBrowserUA,
  'Referer': kBiliReferer,
};

class ImageViewerPage extends StatefulWidget {
  /// 待查看的图片 URL 列表（顺序即滑动顺序）。
  final List<String> urls;

  /// 初始定位到第几张（0 起；越界自动钳制）。
  final int initialIndex;

  const ImageViewerPage({
    super.key,
    required this.urls,
    this.initialIndex = 0,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pageCtrl;
  late int _index;

  /// 当前页缩放控制器（翻页/缩回 1x 时重置为恒等）。
  final TransformationController _zoom = TransformationController();

  /// 是否处于放大状态（>1x）：放大时本页平移看图、禁 PageView 抢手势。
  bool _zoomed = false;

  bool _saving = false; // 保存中（禁用按钮 + 防重复点击）

  @override
  void initState() {
    super.initState();
    final urls = widget.urls;
    _index = urls.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, urls.length - 1).toInt();
    _pageCtrl = PageController(initialPage: _index);
    _zoom.addListener(_onZoomChanged);
  }

  @override
  void dispose() {
    _zoom.removeListener(_onZoomChanged);
    _zoom.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    // 缩放矩阵 >1x 才算放大（平移不改变尺度）；翻页时恒等 → 自动回 false
    final scale = _zoom.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onPageChanged(int i) {
    setState(() => _index = i);
    _zoom.value = Matrix4.identity(); // 换页重置缩放
  }

  /// 双击：1x ↔ 2.5x（以屏幕中心为缩放锚点，视觉不飘走）。
  void _onDoubleTap() {
    final s = _zoom.value.getMaxScaleOnAxis();
    if (s > 1.01) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final size = MediaQuery.of(context).size;
    const target = 2.5;
    final tx = (1 - target) * size.width / 2;
    final ty = (1 - target) * size.height / 2;
    _zoom.value = Matrix4.identity()
      ..translate(tx, ty)
      ..scale(target);
  }

  Future<void> _saveCurrent() async {
    if (_saving || _index >= widget.urls.length) return;
    final messenger = ScaffoldMessenger.of(context);
    final url = widget.urls[_index];
    setState(() => _saving = true);
    final result = await GallerySaver.saveUrlImage(url);
    if (!mounted) return;
    setState(() => _saving = false);
    debugPrint('[image_viewer] 保存结果 ok=${result.ok} msg=${result.message} '
        'url=$url');
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(result.message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.urls;
    final count = urls.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (count == 0)
            _emptyView()
          else
            PageView.builder(
              controller: _pageCtrl,
              itemCount: count,
              onPageChanged: _onPageChanged,
              itemBuilder: (_, i) => _buildZoomableImage(urls[i], i),
            ),
          if (count > 0) ...[
            _topBar(count),
            _bottomSave(),
          ],
        ],
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 56, color: Colors.grey.shade600),
          const SizedBox(height: 10),
          Text('没有可查看的图片', style: TextStyle(color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildZoomableImage(String url, int index) {
    return GestureDetector(
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _zoom,
        // 1x 时禁平移：横向滑动交给 PageView 翻页；放大后本页可平移看图
        panEnabled: _zoomed,
        minScale: 1,
        maxScale: 4,
        child: Center(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            headers: _imgHeaders,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: CircularProgressIndicator(
                  color: Colors.white54,
                  strokeWidth: 2.5,
                ),
              );
            },
            errorBuilder: (context, error, stack) {
              debugPrint('[image_viewer] 图片加载失败 $url error=$error');
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined,
                        size: 56, color: Colors.grey.shade600),
                    const SizedBox(height: 10),
                    Text(
                      '图片加载失败',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 顶部：关闭（左）+ 页码（中）。
  Widget _topBar(int count) {
    final iconColor = Colors.white;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Colors.black.withValues(alpha: 0.2),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              const SizedBox(width: 4),
              _circleButton(
                tooltip: '关闭',
                icon: Icons.close,
                color: iconColor,
                onTap: () => Navigator.of(context).pop(),
              ),
              const Spacer(),
              Text(
                '${_index + 1}/$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              // 右侧占位对称（页码视觉居中）
              const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部：保存到相册。
  Widget _bottomSave() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: Colors.black.withValues(alpha: 0.2),
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: SafeArea(
          top: false,
          child: Center(
            child: _saving
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white70,
                        strokeWidth: 2,
                      ),
                    ),
                  )
                : FilledButton.tonalIcon(
                    onPressed: _saveCurrent,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('保存到相册'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.18),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _circleButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, color: color, size: 26),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
      ),
    );
  }

  /// 供测试引用的内部校验值（非公开 API，勿用于业务逻辑）。
  @visibleForTesting
  double get debugZoomScale => _zoom.value.getMaxScaleOnAxis();

  @visibleForTesting
  int get debugCurrentIndex => _index;

  /// 供测试/外部直接查看多图：可查看的图片数。
  @visibleForTesting
  int get debugCount => widget.urls.length;
}
