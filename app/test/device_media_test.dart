// device_media.dart 基准读取兜底单测（v2.16.12+）：
// - normalizeBrightnessPercent：原生亮度原始值 → 有效 0..100 百分比——
//   null / NaN / Infinity / 越界（含 -1 = 窗口未设置 BRIGHTNESS_OVERRIDE_NONE
//   被原生透传的异常值）一律兜底到 fallbackPercent（默认 50%），有效值
//   0..1 → 0..100 并钳制。播放页手势把返回值当调节基准，基准必须可靠，
//   否则换算出的目标会错（「动一点就跳 0/100」的根因之一）。
//
// 注：getBrightnessPercent 只是 getBrightness 的薄封装（原生异常 → raw null
// → 走同一个纯函数兜底），纯函数覆盖了全部兜底分支，无需 mock MethodChannel。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/device_media.dart';

void main() {
  group('normalizeBrightnessPercent（亮度原始值 → 有效 0..100）', () {
    test('null（通道失败 / 原生异常）→ 兜底 50%（默认）', () {
      expect(DeviceMedia.normalizeBrightnessPercent(null), 50);
    });

    test('自定义兜底值生效', () {
      expect(DeviceMedia.normalizeBrightnessPercent(null,
          fallbackPercent: 40), 40);
    });

    test('-1 / 未设置（BRIGHTNESS_OVERRIDE_NONE 透传）→ 兜底（不再换算成 -100%）', () {
      // v2.16.12 前若原生把窗口未设置的 -1 原样返回，-1×100 → clamp 到 0，
      // 手势基准 = 0 → 滑动方向一错就跳 0/100
      expect(DeviceMedia.normalizeBrightnessPercent(-1), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(-1.0), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(-0.5), 50);
    });

    test('非有限值（NaN / ±Infinity）→ 兜底', () {
      expect(DeviceMedia.normalizeBrightnessPercent(double.nan), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(double.infinity), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(
          double.negativeInfinity), 50);
    });

    test('越界（>1，如旧原生按 0..255 返回）→ 兜底', () {
      expect(DeviceMedia.normalizeBrightnessPercent(255), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(1.5), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(2), 50);
    });

    test('非数字类型 → 兜底', () {
      expect(DeviceMedia.normalizeBrightnessPercent('0.5' as Object), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(false as Object), 50);
    });

    test('有效 0..1 → 0..100（含边界），钳制 0..100', () {
      expect(DeviceMedia.normalizeBrightnessPercent(0), 0);
      expect(DeviceMedia.normalizeBrightnessPercent(0.05), 5);
      expect(DeviceMedia.normalizeBrightnessPercent(0.4), 40);
      expect(DeviceMedia.normalizeBrightnessPercent(0.5), 50);
      expect(DeviceMedia.normalizeBrightnessPercent(1), 100);
    });
  });
}
