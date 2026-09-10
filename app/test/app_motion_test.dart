// 入场节奏结构参数（lib/theme/app_motion.dart）单测：
// - 关键数值逐个锚定（曲线控制点 / 时长 / 步进 / 封顶 / 位移）
// - 「首屏最坏总时长」「追加最坏总时长」用代码算出来，将来有人乱改数字会红
// - 与 app_tokens 的分工：入场必须比「按下」这类交互反馈慢（否则手感变钝）
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/theme/app_motion.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';

void main() {
  group('曲线', () {
    test('烟缕上升：控制点锚定（起步快、中段慢、末端停滞）', () {
      expect(kCurveSmokeRise.a, 0.25);
      expect(kCurveSmokeRise.b, 0.10);
      expect(kCurveSmokeRise.c, 0.60);
      expect(kCurveSmokeRise.d, 1.00);
    });

    test('烟缕上升：端点归位、早段跑在直线前面、末端斜率为 0', () {
      expect(kCurveSmokeRise.transform(0.0), 0.0);
      expect(kCurveSmokeRise.transform(1.0), 1.0);
      // 末段 d=1 且 c<1 → 终点切线斜率 (1-d)/(1-c) = 0（"末端几乎停滞"）
      expect((1 - kCurveSmokeRise.d) / (1 - kCurveSmokeRise.c), 0.0);
      // 中点已走过约 62%：中途就开始被拖住，不是匀速
      expect(kCurveSmokeRise.transform(0.5), greaterThan(0.55));
      expect(kCurveSmokeRise.transform(0.5), lessThan(1.0));
    });
  });

  group('列表项入场（首屏）', () {
    test('数值锚定', () {
      expect(kDurEntrance, const Duration(milliseconds: 240));
      expect(kStaggerStep, const Duration(milliseconds: 36));
      expect(kStaggerMaxIndex, 8);
      expect(kEntranceRisePx, 12.0);
    });

    test('最坏总时长 = step × maxIndex + dur = 528ms', () {
      final worst = kStaggerStep * kStaggerMaxIndex + kDurEntrance;
      expect(worst, const Duration(milliseconds: 528));
      // 逐项复核，避免上面两个常量同时被改后仍"凑巧"相等
      expect(kStaggerStep * kStaggerMaxIndex, const Duration(milliseconds: 288));
      expect(worst.inMilliseconds, 528);
    });

    test('首条无延迟；步进短于单条时长（相邻条目重叠入场，不排队）', () {
      expect(kStaggerStep * 0, Duration.zero);
      expect(kStaggerStep, lessThan(kDurEntrance));
    });
  });

  group('列表项入场（翻页追加）', () {
    test('数值锚定', () {
      expect(kDurEntranceAppend, const Duration(milliseconds: 180));
      expect(kStaggerStepAppend, const Duration(milliseconds: 20));
      expect(kStaggerMaxIndexAppend, 6);
    });

    test('最坏总时长 = step × maxIndex + dur = 300ms', () {
      final worst = kStaggerStepAppend * kStaggerMaxIndexAppend + kDurEntranceAppend;
      expect(worst, const Duration(milliseconds: 300));
      expect(kStaggerStepAppend * kStaggerMaxIndexAppend,
          const Duration(milliseconds: 120));
    });

    test('追加比首屏更快更密（用户已在看内容，不再重演一遍）', () {
      expect(kDurEntranceAppend, lessThan(kDurEntrance));
      expect(kStaggerStepAppend, lessThan(kStaggerStep));
      expect(kStaggerMaxIndexAppend, lessThan(kStaggerMaxIndex));
    });
  });

  group('播放页信息块补场', () {
    test('数值锚定：Hero 先落地，信息块延迟 120ms 补上', () {
      expect(kInfoBlockDelay, const Duration(milliseconds: 120));
      expect(kInfoBlockDur, const Duration(milliseconds: 320));
      expect(kInfoBlockScaleFrom, 0.96);
      expect(kInfoBlockScaleFrom, lessThan(1.0));
      expect(kInfoBlockScaleFrom, greaterThan(0.9)); // 微缩放，不是"弹入"
    });
  });

  group('封面 Hero', () {
    test('数值锚定：飞行 340ms、落地后列表侧淡出 220ms', () {
      expect(kHeroFlightDur, const Duration(milliseconds: 340));
      expect(kCoverFadeOutDur, const Duration(milliseconds: 220));
      expect(kCoverFadeOutDur, lessThan(kHeroFlightDur));
    });
  });

  group('加载动画与逐字文案', () {
    test('数值锚定', () {
      expect(kSmokeCycle, const Duration(milliseconds: 3200));
      expect(kCopyCharStep, const Duration(milliseconds: 24));
      expect(kCopyCharDur, const Duration(milliseconds: 200));
      expect(kCopyCharRisePx, 4.0);
      expect(kCopyCharStepDense, const Duration(milliseconds: 12));
    });

    test('降级档更密：单字步进减半，整句不拖成长镜头', () {
      expect(kCopyCharStepDense, lessThan(kCopyCharStep));
      expect(kCopyCharStepDense * 2, kCopyCharStep);
      expect(kCopyCharRisePx, lessThan(kEntranceRisePx));
    });
  });

  group('与交互反馈节奏的分工（app_tokens）', () {
    test('入场比按下慢，但不至于慢到像卡住', () {
      expect(kDurEntrance, greaterThan(kDurBase)); // 240 > 200
      expect(kDurEntranceAppend, greaterThan(kDurQuick)); // 180 > 120
      expect(kDurEntrance, lessThan(kDurSlow * 2)); // 240 < 640
    });
  });
}
