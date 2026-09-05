// 评论图片全屏查看页（v2.16.19+）widget 冒烟测试。
//
// 不访问真实网络（flutter_test 的 HttpClient 替身返回 400 → errorBuilder
// 兜底显示占位，页面本身逻辑不受影响）。覆盖：
// - 初始 UI：页码「1/N」、关闭按钮、底部「保存到相册」按钮
// - 左滑翻页 → 页码更新（多图 PageView）
// - 单图显示「1/1」
// - 双击缩放（1x → >1x）后再双击还原（不依赖图片是否加载成功）
import 'package:bili_whitelist_app/pages/image_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpViewer(
    WidgetTester tester, {
    required List<String> urls,
    int initialIndex = 0,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: ImageViewerPage(urls: urls, initialIndex: initialIndex),
    ));
    // 等图片请求失败落定（errorBuilder 替代 spinner，避免动画悬挂）
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('双图：页码 1/2 + 关闭 + 保存按钮齐全', (tester) async {
    await pumpViewer(tester, urls: const [
      'https://i0.hdslb.com/a.jpg',
      'https://i0.hdslb.com/b.png',
    ]);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);
    expect(find.text('保存到相册'), findsOneWidget);
  });

  testWidgets('左滑翻页 → 页码变 2/2', (tester) async {
    await pumpViewer(tester, urls: const [
      'https://i0.hdslb.com/a.jpg',
      'https://i0.hdslb.com/b.jpg',
    ]);
    // 图片 1x 时平移禁用，横向滑动交给 PageView 翻页
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('单图：显示 1/1', (tester) async {
    await pumpViewer(tester, urls: const ['https://i0.hdslb.com/only.jpg']);
    expect(find.text('1/1'), findsOneWidget);
  });

  testWidgets('双击放大后再次双击还原（TransformationController 往返）', (tester) async {
    await pumpViewer(tester, urls: const ['https://i0.hdslb.com/a.jpg']);
    final center = tester.getCenter(find.byType(PageView));
    dynamic state = tester.state(find.byType(ImageViewerPage));
    expect(state.debugZoomScale, closeTo(1.0, 1e-6));

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    expect(state.debugZoomScale, greaterThan(1.0));

    // 再次双击还原 1x
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    expect(state.debugZoomScale, closeTo(1.0, 1e-6));
  });
}
