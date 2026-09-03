// 播放页 B 站式快捷手势纯逻辑单测（v2.16.7+，无原生/网络依赖）：
// - verticalSlideKind：竖屏纵向滑动起点半屏判定 → 亮度 / 音量
// - slideFraction：位移 → 比例（拖满一屏 = ±100%，防除零 / 越界钳制）
// - seekTargetMs：横屏 seek 目标位置（基准 + 比例 × 时长，钳制 0..时长）
// - volumeTargetLevel：音量目标档（基准 + 比例 × 最大档，钳制 0..max）
// - adjustPercent / brightnessPercent：纵向调节百分比（0..100 / 亮度下限 5%）
//
// 逻辑见 lib/pages/player_page.dart 顶部的纯函数（与会员集 pgc 回退同风格，
// 便于脱离 Widget/原生通道直接测判定与换算）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/player_page.dart';

void main() {
  group('verticalSlideKind（竖屏半屏判定）', () {
    test('起点 x 在左半屏（含正中线）→ 亮度', () {
      expect(verticalSlideKind(0, 411), PlayerSlideKind.brightness);
      expect(verticalSlideKind(205, 411), PlayerSlideKind.brightness);
      expect(verticalSlideKind(411 / 2, 411), PlayerSlideKind.brightness);
    });

    test('起点 x 在右半屏 → 音量', () {
      expect(verticalSlideKind(206, 411), PlayerSlideKind.volume);
      expect(verticalSlideKind(411, 411), PlayerSlideKind.volume);
    });
  });

  group('slideFraction（位移 → 比例）', () {
    test('span <= 0（测试/极端布局）→ 0，不除零', () {
      expect(slideFraction(100, 0), 0);
      expect(slideFraction(-100, -1), 0);
    });

    test('正负方向与线性比例', () {
      expect(slideFraction(100, 1000), closeTo(0.1, 1e-9));
      expect(slideFraction(-100, 1000), closeTo(-0.1, 1e-9));
      expect(slideFraction(0, 1000), 0);
    });

    test('拖满一屏 = ±100%，越界钳制到 ±1', () {
      expect(slideFraction(1000, 1000), 1);
      expect(slideFraction(-1000, 1000), -1);
      expect(slideFraction(5000, 1000), 1);
      expect(slideFraction(-5000, 1000), -1);
    });
  });

  group('seekTargetMs（横屏 seek 目标）', () {
    test('时长未知（<=0）→ 0（防御：此时不应 seek）', () {
      expect(seekTargetMs(baseMs: 1000, fraction: 0.5, durationMs: 0), 0);
      expect(seekTargetMs(baseMs: 1000, fraction: -0.5, durationMs: -1), 0);
    });

    test('向右滑（正比例）= 前进，线性映射', () {
      // 10 分钟视频：拖 10% = +1 分钟
      expect(seekTargetMs(baseMs: 60_000, fraction: 0.1, durationMs: 600_000),
          120_000);
      expect(seekTargetMs(baseMs: 60_000, fraction: -0.1, durationMs: 600_000),
          0); // 60s - 60s = 0
    });

    test('钳制到 [0, 时长]（滑过头不越界）', () {
      final durationMs = 300_000;
      expect(seekTargetMs(baseMs: 10_000, fraction: -1, durationMs: durationMs),
          0);
      expect(seekTargetMs(baseMs: 250_000, fraction: 1, durationMs: durationMs),
          durationMs);
      expect(seekTargetMs(baseMs: 290_000, fraction: 0.9, durationMs: durationMs),
          durationMs);
    });

    test('部分位移取整', () {
      // 100s 视频拖 1/3 屏 ≈ +33s（33.33 取整 33）
      expect(seekTargetMs(baseMs: 0, fraction: 1 / 3, durationMs: 100_000),
          33_333);
    });
  });

  group('volumeTargetLevel（音量目标档）', () {
    test('max <= 0 → 0（防御）', () {
      expect(volumeTargetLevel(baseLevel: 5, fraction: 1, maxLevel: 0), 0);
    });

    test('向上滑 = 增大，按比例换算档位', () {
      // 最大档 15：拖半屏 → +7 档（7.5 取整 8），base 5 → 13
      expect(volumeTargetLevel(baseLevel: 5, fraction: 0.5, maxLevel: 15), 13);
      // 拖 1/3 屏 → +5 档
      expect(volumeTargetLevel(baseLevel: 5, fraction: 1 / 3, maxLevel: 15),
          10);
    });

    test('钳制 0..max（不会滑到负数 / 超过最大档）', () {
      expect(volumeTargetLevel(baseLevel: 2, fraction: -1, maxLevel: 15), 0);
      expect(volumeTargetLevel(baseLevel: 14, fraction: 1, maxLevel: 15), 15);
      expect(volumeTargetLevel(baseLevel: 15, fraction: 1, maxLevel: 15), 15);
      expect(volumeTargetLevel(baseLevel: 0, fraction: -1, maxLevel: 15), 0);
    });
  });

  group('adjustPercent / brightnessPercent（纵向调节百分比）', () {
    test('基准 + 比例 × 100，钳制 0..100', () {
      expect(adjustPercent(basePercent: 50, fraction: 0.5), 100);
      expect(adjustPercent(basePercent: 50, fraction: -0.5), 0);
      expect(adjustPercent(basePercent: 80, fraction: 0.5), 100);
      expect(adjustPercent(basePercent: 20, fraction: -0.5), 0);
      expect(adjustPercent(basePercent: 30, fraction: 0.1), 40);
    });

    test('亮度下限 5%（全黑时浮层同窗口不可见，防误导）', () {
      expect(brightnessPercent(basePercent: 50, fraction: -1), 5);
      expect(brightnessPercent(basePercent: 5, fraction: 1), 100);
      expect(brightnessPercent(basePercent: 10, fraction: 0.2), 30);
      // 高于 5 的部分行为与 adjustPercent 一致
      expect(brightnessPercent(basePercent: 50, fraction: -0.3), 20);
    });
  });
}
