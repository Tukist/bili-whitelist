// 应用内浮动小窗的几何纯函数测试（v2.65.0）。
//
// 窗口的「大小 / 位置 / 夹取」全部在 `lib/widgets/floating_player_window.dart`
// 的四个纯函数里（不在手势回调里写算式），本文件把它们当契约逐条钉住：
//   1. 默认窗口：屏宽 40%、16:9、贴右贴顶；
//   2. 位置夹取：怎么甩都出不了可视区（含状态栏 / 底部手势条）；
//   3. 缩放：保持视频比例、最小 120dp、最大屏宽 85%、越界整体推回；
//   4. 比例互逆：矩形 → 比例 → 矩形 走一圈等于原样（持久化靠这条）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/widgets/floating_player_window.dart';

/// 测试用页面（竖屏手机，与播放页测试同一尺寸）。
const Size _kPage = Size(411, 914);

/// 16:9 视频。
const double _kAspect = 16 / 9;

Rect _rect({
  double widthRatio = 0.40,
  double dxRatio = 1.0,
  double dyRatio = 0.0,
  double aspect = _kAspect,
  EdgeInsets safe = EdgeInsets.zero,
  Size page = _kPage,
}) {
  return floatWindowRect(
    page: page,
    safe: safe,
    aspectRatio: aspect,
    widthRatio: widthRatio,
    dxRatio: dxRatio,
    dyRatio: dyRatio,
  );
}

void main() {
  group('默认窗口', () {
    test('屏宽 40% + 16:9 + 贴右贴顶', () {
      final rect = _rect();
      expect(rect.width, closeTo(411 * 0.40, 1e-9));
      expect(rect.height, closeTo(rect.width / (16 / 9), 1e-9));
      expect(rect.left, closeTo(411 - rect.width, 1e-9), reason: 'dxRatio=1 → 贴右');
      expect(rect.top, 0, reason: 'dyRatio=0 → 贴顶');
      expect(rect.right, closeTo(411, 1e-9));
    });

    test('位置比 0/1 分别是贴左/贴右、贴顶/贴底', () {
      final leftTop = _rect(dxRatio: 0, dyRatio: 0);
      expect(leftTop.left, 0);
      expect(leftTop.top, 0);

      final rightBottom = _rect(dxRatio: 1, dyRatio: 1);
      expect(rightBottom.right, closeTo(411, 1e-9));
      expect(rightBottom.bottom, closeTo(914, 1e-9));
    });

    test('安全区把窗口顶在状态栏下方（默认贴顶也不许被遮）', () {
      final rect = _rect(safe: const EdgeInsets.only(top: 24, bottom: 34));
      expect(rect.top, 24, reason: '状态栏 24dp 之下');
      final bottom = _rect(dxRatio: 0, dyRatio: 1,
          safe: const EdgeInsets.only(top: 24, bottom: 34));
      expect(bottom.bottom, closeTo(914 - 34, 1e-9), reason: '底部手势条之上');
    });

    test('比例越界（坏值漏网）→ 夹到 0~1，不出现负坐标', () {
      final rect = _rect(dxRatio: 2.5, dyRatio: -3);
      expect(rect.left, closeTo(411 - rect.width, 1e-9));
      expect(rect.top, 0);
    });
  });

  group('位置夹取（拖到哪都出不去）', () {
    const safe = EdgeInsets.only(top: 24, bottom: 34);

    test('往右下甩 1000dp → 右下贴边', () {
      final rect = clampFloatWindowRect(
        _rect(safe: safe).shift(const Offset(1000, 1000)),
        _kPage,
        safe,
      );
      expect(rect.right, closeTo(411, 1e-9));
      expect(rect.bottom, closeTo(914 - 34, 1e-9));
      expect(rect.width, closeTo(411 * 0.40, 1e-9), reason: '夹位置不改尺寸');
    });

    test('往左上甩 1000dp → 左上贴边（上方是状态栏下沿）', () {
      final rect = clampFloatWindowRect(
        _rect(safe: safe).shift(const Offset(-1000, -1000)),
        _kPage,
        safe,
      );
      expect(rect.left, 0);
      expect(rect.top, 24);
    });

    test('页面比窗口还矮时不抛（夹取区间不反转）', () {
      const tiny = Size(200, 60);
      final rect = clampFloatWindowRect(
        const Rect.fromLTWH(10, 10, 160, 90),
        tiny,
        const EdgeInsets.only(top: 20, bottom: 20),
      );
      expect(rect.top, 20);
      expect(rect.width, 160);
    });
  });

  group('缩放（拖右下角）', () {
    test('宽变大 → 高按 16:9 跟着变，左上角不动', () {
      final start = _rect(dxRatio: 0, dyRatio: 0); // 贴左，右边有空间
      final rect = resizeFloatWindowRect(
        start: start,
        deltaWidth: 60,
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: _kAspect,
      );
      expect(rect.width, closeTo(start.width + 60, 1e-9));
      expect(rect.width / rect.height, closeTo(16 / 9, 1e-9));
      expect(rect.left, start.left);
      expect(rect.top, start.top);
    });

    test('最小宽度 120dp（再往左拖也不会更小）', () {
      final rect = resizeFloatWindowRect(
        start: _rect(),
        deltaWidth: -500,
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: _kAspect,
      );
      expect(rect.width, closeTo(kFloatMinWidth, 1e-9));
      expect(rect.width, closeTo(120, 1e-9), reason: 'Rect.width = right-left，带浮点尾数');
      expect(rect.width / rect.height, closeTo(16 / 9, 1e-9));
    });

    test('最大宽度 = 屏宽 85%', () {
      final rect = resizeFloatWindowRect(
        start: _rect(),
        deltaWidth: 2000,
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: _kAspect,
      );
      expect(rect.width, closeTo(411 * kFloatMaxWidthRatio, 1e-9));
      expect(kFloatMaxWidthRatio, 0.85);
    });

    test('放大后右缘越界 → 整体往左推回可视区（尺寸不缩水）', () {
      final start = _rect(dxRatio: 1); // 贴右
      final rect = resizeFloatWindowRect(
        start: start,
        deltaWidth: 100,
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: _kAspect,
      );
      expect(rect.right, closeTo(411, 1e-9), reason: '不许有一半在屏幕外');
      expect(rect.width, closeTo(start.width + 100, 1e-9), reason: '推回不是缩回');
    });

    test('竖屏视频（9:16）也守同一条最小/最大规则', () {
      final rect = resizeFloatWindowRect(
        start: _rect(aspect: 9 / 16, dxRatio: 0),
        deltaWidth: 40,
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: 9 / 16,
      );
      expect(rect.width / rect.height, closeTo(9 / 16, 1e-9));
      expect(rect.width, greaterThanOrEqualTo(kFloatMinWidth - 1e-9));
      expect(rect.width, lessThanOrEqualTo(411 * kFloatMaxWidthRatio + 1e-9));
    });
  });

  group('宽高比归一', () {
    test('0 / 负数 / NaN / Infinity → 16:9', () {
      for (final bad in <double>[0, -1, double.nan, double.infinity]) {
        expect(floatWindowAspect(bad), closeTo(16 / 9, 1e-9), reason: '$bad');
      }
    });

    test('超宽 4.0 → 夹到 2.33；超窄 0.2 → 夹到 0.5', () {
      expect(floatWindowAspect(4.0), closeTo(2.33, 1e-9));
      expect(floatWindowAspect(0.2), closeTo(0.5, 1e-9));
      expect(floatWindowAspect(1.5), 1.5);
    });
  });

  group('比例互逆（持久化靠这条）', () {
    test('矩形 → 比例 → 矩形，走一圈还是原来那个（拖动后用）', () {
      final start = _rect(widthRatio: 0.33, dxRatio: 0.42, dyRatio: 0.17);
      final ratios = floatWindowRatiosOf(start, _kPage, EdgeInsets.zero);
      final back = floatWindowRect(
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: _kAspect,
        widthRatio: ratios.widthRatio,
        dxRatio: ratios.dxRatio,
        dyRatio: ratios.dyRatio,
      );
      expect(back.left, closeTo(start.left, 1e-9));
      expect(back.top, closeTo(start.top, 1e-9));
      expect(back.width, closeTo(start.width, 1e-9));
      expect(ratios.widthRatio, closeTo(0.33, 1e-9));
    });

    test('缩放后的矩形同样可逆（换了页面尺寸也落在合法区间）', () {
      final resized = resizeFloatWindowRect(
        start: _rect(dxRatio: 1),
        deltaWidth: 80,
        page: _kPage,
        safe: EdgeInsets.zero,
        aspectRatio: _kAspect,
      );
      final ratios = floatWindowRatiosOf(resized, _kPage, EdgeInsets.zero);
      expect(ratios.widthRatio, inInclusiveRange(0.05, 1.0));
      expect(ratios.dxRatio, inInclusiveRange(0.0, 1.0));
      expect(ratios.dyRatio, inInclusiveRange(0.0, 1.0));
    });
  });
}
