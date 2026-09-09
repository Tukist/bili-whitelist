// 播放错误自动续播决策单测（v2.17.14+，纯函数，无原生/网络依赖）：
// - autoRecoverDelayMs：第 n 次自动续播尝试前的退避毫秒（越界=应放弃）
// - 退避表/放弃文案与决策逻辑见 lib/pages/player_page.dart 顶部的纯函数
//
// 背景：原生把「可自动恢复的数据源错误」（流 URL 过期 403/404/410/429/5xx、
// 瞬时网络错误如 2001 timeout/断连）统一发 onUrlExpired，Dart 侧重取 playurl
// 续播（保留位置）；续播失败按 1s/2s/4s 退避**有限次**，仍失败才显示错误
// （保留手动重试兜底），避免网络抖动弹「播放失败」打断观看。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/player_page.dart';

void main() {
  group('kAutoRecoverBackoffMs（退避表：1s→2s→4s，长度=最大尝试次数）', () {
    test('3 档退避且递增（网络喘息逐档放宽）', () {
      expect(kAutoRecoverBackoffMs, [1000, 2000, 4000]);
      for (var i = 1; i < kAutoRecoverBackoffMs.length; i++) {
        expect(kAutoRecoverBackoffMs[i],
            greaterThan(kAutoRecoverBackoffMs[i - 1]));
      }
    });

    test('kAutoRecoverGiveUpMessage 为可读文案（含重试提示，非空）', () {
      expect(kAutoRecoverGiveUpMessage, isNotEmpty);
      expect(kAutoRecoverGiveUpMessage, contains('重试'));
    });
  });

  group('autoRecoverDelayMs（越界即放弃自动恢复，交手动重试）', () {
    test('第 0/1/2 次尝试（0 起）分别退避 1s/2s/4s', () {
      expect(autoRecoverDelayMs(0), 1000);
      expect(autoRecoverDelayMs(1), 2000);
      expect(autoRecoverDelayMs(2), 4000);
    });

    test('第 3 次起（超上限）返回 null → 不再自动尝试', () {
      expect(autoRecoverDelayMs(3), isNull);
      expect(autoRecoverDelayMs(10), isNull);
    });

    test('负数防御返回 null（不会死循环/负延时）', () {
      expect(autoRecoverDelayMs(-1), isNull);
      expect(autoRecoverDelayMs(-100), isNull);
    });

    test('退避表与尝试上限自洽：恰好在 length-1 内可尝试，length 起放弃', () {
      // 语义：连续失败 attempt 次后仍可自动续播 ⇔ attempt < length
      for (var attempt = 0; attempt < kAutoRecoverBackoffMs.length; attempt++) {
        expect(autoRecoverDelayMs(attempt), isNotNull,
            reason: 'attempt=$attempt 应在预算内');
      }
      expect(
          autoRecoverDelayMs(kAutoRecoverBackoffMs.length), isNull,
          reason: 'attempt=${kAutoRecoverBackoffMs.length} 应已超出预算');
    });
  });
}
