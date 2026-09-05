// 播放页 B 站式快捷手势纯逻辑单测（v2.16.7+，无原生/网络依赖）：
// - verticalSlideKind：竖屏纵向滑动起点半屏判定 → 亮度 / 音量
// - decideMode：滑动主导方向判定（v2.16.9+ 横屏 seek 与亮度/音量共存——
//   斜向按位移主方向归类，|dx|>=|dy|→horizontal、|dy|>|dx|→vertical）
// - nextPanMode：方向锁定（已有模式不受后续位移影响，本次手势不切换）
// - slideFraction：位移 → 比例（拖满一屏 = ±100%，防除零 / 越界钳制）
// - seekTargetMs：横屏 seek 目标位置（基准 + 比例 × 时长，钳制 0..时长）
// - volumeTargetLevel：音量目标档（基准 + 比例 × 灵敏度 × 最大档，钳制 0..max）
// - adjustPercent / brightnessPercent：纵向调节百分比（灵敏度 0.3：滑满一屏
//   ±30%、小幅平滑；亮度下限 5%）
// - isExcludedGestureStart：手势起点豁免带判定（v2.16.14+ 顶部/底部 →
//   v2.16.17+ 扩展四边：起点 x0/y0 落在顶部 topPx 带、底部 max(屏高×factor,
//   minPx) 带、或左/右边缘带内 → 本次 Pan 忽略，让给系统导航手势——横屏全屏
//   时物理底边导航区 = 逻辑左/右边缘，靠左右带命中；边界含等号；尺寸 <=0
//   防御不豁免）
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

  group('decideMode（主导方向判定，v2.16.9+）', () {
    test('dx/dy 都未超阈值 → null（未定，继续累计）', () {
      expect(decideMode(10, 100, 100), isNull); // 阈值内全量判定
      expect(decideMode(11, 3), isNull);
      expect(decideMode(12, 12), isNull); // 恰在阈值上仍不算
      expect(decideMode(0, 0), isNull);
      expect(decideMode(5, -8), isNull);
    });

    test('垂直主导（|dy| > |dx| 且超阈值）→ vertical', () {
      expect(decideMode(10, 100), PanSlideMode.vertical); // 稍斜的上下滑
      expect(decideMode(100, 1000), PanSlideMode.vertical);
      expect(decideMode(3, 15), PanSlideMode.vertical);
    });

    test('水平主导（|dx| >= |dy| 且超阈值）→ horizontal', () {
      expect(decideMode(100, 10), PanSlideMode.horizontal); // 稍斜的左右滑
      expect(decideMode(1000, 100), PanSlideMode.horizontal);
      expect(decideMode(15, 3), PanSlideMode.horizontal);
    });

    test('45° 平分（|dx| == |dy|）→ horizontal（|dx| 不落后即归水平）', () {
      expect(decideMode(100, 100), PanSlideMode.horizontal);
      expect(decideMode(-50, -50), PanSlideMode.horizontal);
      expect(decideMode(13, 13), PanSlideMode.horizontal);
    });

    test('负数方向不影响归类（符号只表左右/上下）', () {
      expect(decideMode(-10, -100), PanSlideMode.vertical); // 向左下滑
      expect(decideMode(-100, -10), PanSlideMode.horizontal); // 向左上滑
      expect(decideMode(100, -200), PanSlideMode.vertical); // 右下滑
      expect(decideMode(-300, 40), PanSlideMode.horizontal); // 左上/右斜
    });
  });

  group('nextPanMode（方向锁定，本次手势不切换）', () {
    test('未锁定（current=null）时交给 decideMode 判定', () {
      expect(nextPanMode(current: null, dx: 10, dy: 100),
          PanSlideMode.vertical);
      expect(nextPanMode(current: null, dx: 100, dy: 10),
          PanSlideMode.horizontal);
      expect(nextPanMode(current: null, dx: 5, dy: 5), isNull);
    });

    test('已锁定 → 不受后续位移影响（斜向反超也不切换）', () {
      // 先锁定 horizontal，后续大幅垂直位移仍保持 horizontal
      expect(
          nextPanMode(
              current: PanSlideMode.horizontal, dx: 5, dy: 500),
          PanSlideMode.horizontal);
      // 先锁定 vertical，后续大幅水平位移仍保持 vertical
      expect(
          nextPanMode(current: PanSlideMode.vertical, dx: 500, dy: 5),
          PanSlideMode.vertical);
      // 微小抖动同样不回退为未定
      expect(
          nextPanMode(current: PanSlideMode.vertical, dx: 1, dy: 1),
          PanSlideMode.vertical);
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

  group('volumeTargetLevel（音量目标档，灵敏度 0.3）', () {
    test('max <= 0 → 0（防御）', () {
      expect(volumeTargetLevel(baseLevel: 5, fraction: 1, maxLevel: 0), 0);
    });

    test('向上滑 = 增大：滑满一屏 = +30% 最大档（不再 ±100%）', () {
      // 最大档 15：满屏 +0.3×15=4.5 档 → 5+4.5=9.5 round 10（10/15≈67%）
      expect(volumeTargetLevel(baseLevel: 5, fraction: 1, maxLevel: 15), 10);
      // 拖半屏 → +2.25 档 → 7（7/15≈47%）
      expect(volumeTargetLevel(baseLevel: 5, fraction: 0.5, maxLevel: 15), 7);
      // 拖 1/3 屏 → +1.5 档 → 7
      expect(volumeTargetLevel(baseLevel: 5, fraction: 1 / 3, maxLevel: 15),
          7);
      // 1/4 屏 → +1.125 档 → 6（≈ +7.5% 最大档）
      expect(volumeTargetLevel(baseLevel: 5, fraction: 0.25, maxLevel: 15),
          6);
    });

    test('小幅滑动平滑：1/10 屏 → ±0.45 档 → 不变（档位离散的合理静默）', () {
      expect(volumeTargetLevel(baseLevel: 5, fraction: 0.1, maxLevel: 15), 5);
      expect(volumeTargetLevel(baseLevel: 5, fraction: -0.1, maxLevel: 15), 5);
      // 稍大些（2/10 屏）→ +0.9 档 → 才 +1 档
      expect(volumeTargetLevel(baseLevel: 5, fraction: 0.2, maxLevel: 15), 6);
    });

    test('钳制 0..max（不会滑到负数 / 超过最大档）', () {
      expect(volumeTargetLevel(baseLevel: 2, fraction: -1, maxLevel: 15), 0);
      expect(volumeTargetLevel(baseLevel: 14, fraction: 1, maxLevel: 15), 15);
      expect(volumeTargetLevel(baseLevel: 15, fraction: 1, maxLevel: 15), 15);
      expect(volumeTargetLevel(baseLevel: 0, fraction: -1, maxLevel: 15), 0);
      // 远离边界也能被满屏滑动打满（档位差 ±4.5 → 向远离 0 取整 ±5）
      expect(volumeTargetLevel(baseLevel: 8, fraction: -1, maxLevel: 15),
          3); // 8 - 5 = 3
      expect(volumeTargetLevel(baseLevel: 10, fraction: 1, maxLevel: 15),
          15); // 10 + 5 = 15
    });
  });

  group('adjustPercent / brightnessPercent（纵向调节百分比，灵敏度 0.3）', () {
    test('基准 + 比例 × 灵敏度：滑满一屏 = ±30%（不再 ±100%）', () {
      expect(adjustPercent(basePercent: 50, fraction: 1), 80);
      expect(adjustPercent(basePercent: 50, fraction: -1), 20);
      expect(adjustPercent(basePercent: 50, fraction: 0.5), 65);
      expect(adjustPercent(basePercent: 50, fraction: -0.5), 35);
      // 旧版语义（±100%）回归确认：50 满屏滑现在只到 80/20，不会跳 0/100
      expect(adjustPercent(basePercent: 80, fraction: 1), 100);
      expect(adjustPercent(basePercent: 20, fraction: -1), 0);
    });

    test('小幅滑动平滑小幅变化（1/10 屏 ≈ ±3%，不跳变）', () {
      expect(adjustPercent(basePercent: 50, fraction: 0.1), closeTo(53, 1e-9));
      expect(adjustPercent(basePercent: 50, fraction: -0.1),
          closeTo(47, 1e-9));
      // 手指“动一点点”（1/20 屏）→ 仅 ±1.5%
      expect(adjustPercent(basePercent: 50, fraction: 0.05),
          closeTo(51.5, 1e-9));
      expect(adjustPercent(basePercent: 40, fraction: 0.1), 43);
      expect(adjustPercent(basePercent: 40, fraction: -0.1), 37);
    });

    test('自定义灵敏度生效（按 fraction × sensitivity × 100 换算）', () {
      expect(adjustPercent(basePercent: 50, fraction: 1, sensitivity: 1), 100);
      expect(adjustPercent(basePercent: 50, fraction: 1, sensitivity: 0.5),
          100); // ±50%
      expect(adjustPercent(basePercent: 50, fraction: -1, sensitivity: 0.5),
          0);
      expect(adjustPercent(basePercent: 50, fraction: -0.5, sensitivity: 0.5),
          25); // 25%
    });

    test('钳制 0..100（靠边滑动越界时钳到边界）', () {
      expect(adjustPercent(basePercent: 90, fraction: 1), 100); // 90+30 → 100
      expect(adjustPercent(basePercent: 10, fraction: -1), 0); // 10-30 → 0
      expect(adjustPercent(basePercent: 0, fraction: 1), 30); // 从 0 只涨 30
      expect(adjustPercent(basePercent: 100, fraction: -1), 70); // 从 100 只降 30
      expect(adjustPercent(basePercent: 0, fraction: -1), 0);
      expect(adjustPercent(basePercent: 100, fraction: 1), 100);
    });

    test('负方向（下滑 = 减小）线性', () {
      expect(adjustPercent(basePercent: 60, fraction: -0.3), 51);
      expect(adjustPercent(basePercent: 60, fraction: -1), 30);
    });

    test('亮度下限 5%（全黑时浮层同窗口不可见，防误导）', () {
      expect(brightnessPercent(basePercent: 10, fraction: -1), 5); // 10-30 → 下限
      expect(brightnessPercent(basePercent: 5, fraction: -1), 5);
      expect(brightnessPercent(basePercent: 50, fraction: -1), 20); // 高于下限正常减
      expect(brightnessPercent(basePercent: 5, fraction: 1), 35);
      expect(brightnessPercent(basePercent: 90, fraction: 1), 100);
      expect(brightnessPercent(basePercent: 40, fraction: 0.1), 43);
    });
  });

  group('isExcludedGestureStart（起点豁免带，v2.16.14+ 顶/底 → v2.16.17+ 四边）', () {
    // 默认参数：bottomFactor=0.08、bottomMinPx=48、topPx=24、
    // leftPx=rightPx=16（竖屏窄带）。
    // h=1000：底部带 = max(1000×0.08, 48) = 80px → 带上缘 920。
    test('底部带内（含带上缘边界）→ true（x0 取中部，不干扰 y 判定）', () {
      expect(isExcludedGestureStart(x0: 500, y0: 999, width: 1000, height: 1000),
          isTrue); // 贴屏幕底
      expect(isExcludedGestureStart(x0: 500, y0: 950, width: 1000, height: 1000),
          isTrue);
      expect(isExcludedGestureStart(x0: 500, y0: 920, width: 1000, height: 1000),
          isTrue); // 上缘含等号
    });

    test('底部带上缘外（带上方一点/中部）→ false', () {
      expect(isExcludedGestureStart(
          x0: 500, y0: 919.9, width: 1000, height: 1000),
          isFalse);
      expect(isExcludedGestureStart(x0: 500, y0: 800, width: 1000, height: 1000),
          isFalse); // 中部
      expect(isExcludedGestureStart(x0: 500, y0: 500, width: 1000, height: 1000),
          isFalse);
    });

    test('顶部带内（含边界 24px）→ true', () {
      expect(isExcludedGestureStart(x0: 500, y0: 0, width: 1000, height: 1000),
          isTrue); // 贴屏幕顶
      expect(isExcludedGestureStart(x0: 500, y0: 10, width: 1000, height: 1000),
          isTrue);
      expect(isExcludedGestureStart(x0: 500, y0: 24, width: 1000, height: 1000),
          isTrue); // 边界含等号
    });

    test('顶带下缘外且不在底部带（中部净区）→ false', () {
      expect(isExcludedGestureStart(x0: 500, y0: 25, width: 1000, height: 1000),
          isFalse);
      expect(isExcludedGestureStart(x0: 500, y0: 100, width: 1000, height: 1000),
          isFalse);
    });

    // v2.16.17 核心回归：横屏全屏从**物理屏幕底部**上滑唤醒导航，旋转后起点
    // 落在**逻辑左/右边缘**（y0 在屏中部，不在任何 y 豁免带内）——必须靠
    // 左右带命中。页面按横屏（w>h）传入 leftPx=rightPx=48（与底部同宽策略）。
    test('横屏物理底边 = 逻辑左右边缘：y0 中部 + x0 贴左/右边缘 → true', () {
      const w = 914.0, h = 411.0; // 模拟器横屏全屏逻辑尺寸（1080x2400 @420dpi）
      // 用户从物理底部中央上滑 → 旋转后可能是逻辑左边缘或右边缘起点
      expect(isExcludedGestureStart(
          x0: 0, y0: 200, width: w, height: h, leftPx: 48, rightPx: 48),
          isTrue); // 贴左缘、y 中部
      expect(isExcludedGestureStart(
          x0: 47, y0: 200, width: w, height: h, leftPx: 48, rightPx: 48),
          isTrue); // 左带内（< 48）
      expect(isExcludedGestureStart(
          x0: 48, y0: 200, width: w, height: h, leftPx: 48, rightPx: 48),
          isTrue); // 左带边界含等号
      expect(isExcludedGestureStart(
          x0: 913, y0: 100, width: w, height: h, leftPx: 48, rightPx: 48),
          isTrue); // 贴右缘
      expect(isExcludedGestureStart(
          x0: 866, y0: 400, width: w, height: h, leftPx: 48, rightPx: 48),
          isTrue); // 右带内（≥ 914-48=866，含等号）
    });

    test('横屏左右带外（x0 距边缘 > 48）→ false（中部 seek 不被豁免）', () {
      const w = 914.0, h = 411.0;
      expect(isExcludedGestureStart(
          x0: 50, y0: 200, width: w, height: h, leftPx: 48, rightPx: 48),
          isFalse);
      expect(isExcludedGestureStart(
          x0: 865, y0: 200, width: w, height: h, leftPx: 48, rightPx: 48),
          isFalse); // 865 < 914-48=866
      expect(isExcludedGestureStart(
          x0: 400, y0: 200, width: w, height: h, leftPx: 48, rightPx: 48),
          isFalse); // 屏中部横滑 → seek 正常
    });

    test('竖屏默认左右窄带（16px，v2.16.17+）：贴左/右边缘 → true', () {
      const w = 411.0, h = 914.0; // 竖屏逻辑尺寸
      expect(isExcludedGestureStart(x0: 0, y0: 500, width: w, height: h),
          isTrue); // 贴左缘
      expect(isExcludedGestureStart(x0: 16, y0: 500, width: w, height: h),
          isTrue); // 左带边界含等号
      expect(isExcludedGestureStart(x0: 411, y0: 500, width: w, height: h),
          isTrue); // 贴右缘
      expect(isExcludedGestureStart(x0: 411 - 16, y0: 500, width: w, height: h),
          isTrue); // 右带边界含等号
      expect(isExcludedGestureStart(x0: 20, y0: 500, width: w, height: h),
          isFalse); // 窄带外（>16）
    });

    test('左右豁免可调窄/关闭（leftPx/rightPx=0 时贴边微内起点不豁免）', () {
      expect(isExcludedGestureStart(
          x0: 5, y0: 500, width: 411, height: 914, leftPx: 0, rightPx: 0),
          isFalse);
      expect(isExcludedGestureStart(
          x0: 200, y0: 500, width: 411, height: 914, leftPx: 24, rightPx: 24),
          isFalse);
      expect(isExcludedGestureStart(
          x0: 20, y0: 500, width: 411, height: 914, leftPx: 24, rightPx: 24),
          isTrue); // < 24 → 带内
    });

    test('矮屏（横屏屏高 ~400）由固定 minPx 兜底加宽豁免带', () {
      // h=400：8% = 32px < 48px → 底部带取 48px，带上缘 = 400-48 = 352
      expect(isExcludedGestureStart(
          x0: 200, y0: 399, width: 914, height: 400),
          isTrue);
      expect(isExcludedGestureStart(
          x0: 200, y0: 360, width: 914, height: 400),
          isTrue);
      expect(isExcludedGestureStart(
          x0: 200, y0: 352, width: 914, height: 400),
          isTrue); // 边界
      expect(isExcludedGestureStart(
          x0: 200, y0: 351, width: 914, height: 400),
          isFalse); // 带外
      expect(isExcludedGestureStart(
          x0: 200, y0: 100, width: 914, height: 400),
          isFalse);
    });

    test('显式 bottomMinPx=0 → 纯比例带（无固定兜底，可单独验证 factor）', () {
      // h=400、factor=0.08、minPx=0：底部带 = 32px，带上缘 = 368
      expect(isExcludedGestureStart(
          x0: 200, y0: 380, width: 914, height: 400, bottomMinPx: 0),
          isTrue);
      expect(isExcludedGestureStart(
          x0: 200, y0: 368, width: 914, height: 400, bottomMinPx: 0),
          isTrue); // 边界
      expect(isExcludedGestureStart(
          x0: 200, y0: 360, width: 914, height: 400, bottomMinPx: 0),
          isFalse); // 无兜底时 360 已在 8% 带外
      // 加大 factor（如 0.12）→ 带加宽，同一起点变为带内
      expect(isExcludedGestureStart(
              x0: 200, y0: 360, width: 914, height: 400,
              bottomFactor: 0.12, bottomMinPx: 0),
          isTrue); // 400×0.12=48px 带上缘 352
    });

    test('顶部带可关（topPx=0）：仅贴屏幕顶（y0=0）在顶带内', () {
      expect(isExcludedGestureStart(
          x0: 200, y0: 0, width: 914, height: 400, topPx: 0),
          isTrue);
      expect(isExcludedGestureStart(
          x0: 200, y0: 1, width: 914, height: 400, topPx: 0),
          isFalse);
    });

    test('尺寸异常（<= 0，防御）→ false（不豁免，退化旧行为）', () {
      expect(isExcludedGestureStart(x0: 0, y0: 0, width: 0, height: 100),
          isFalse);
      expect(isExcludedGestureStart(x0: 0, y0: 999, width: 100, height: -1),
          isFalse);
      expect(isExcludedGestureStart(x0: -1, y0: 999, width: 100, height: -1),
          isFalse);
    });
  });
}
