// 流 URL deadline 解析 + 主动预取换源决策单测（v2.17.15+，纯函数，无原生/
// 网络依赖）：
// - streamDeadlineMs：流 URL query 里 deadline 参数 → 归一为 Unix 毫秒
//   （实测单位为 Unix 秒 ~1.7e9；兼容毫秒 ~1.7e12）；缺/非法 → null
// - streamDeadlineRemainMs：距到期剩余毫秒（已过期 ≤0；无 deadline → null）
// - shouldPrefetchSource：URL 剩余有效期不足以播完剩余内容 + 提前量 → 提前换源
// - kPrefetchLeadMs / kPrefetchMinIntervalMs：提前量/节流间隔常量
//
// 背景：B 站流 URL 带 deadline 签名（2026-09 实测有效期固定 2h=7200s），
// 普通视频播放中不会到期，但超长视频 / 长时间暂停后续播仍会用完剩余有效期
// → 读到过期 URL 必失败；本决策在到期前主动换新 URL，见 lib/pages/player_page.dart
// 顶部「流 URL deadline 解析 + 主动预取换源决策」注释。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/player_page.dart';

void main() {
  group('streamDeadlineMs（流 URL deadline 参数 → epoch 毫秒）', () {
    test('deadline 单位是 Unix 秒（实测 ~1.7e9）→ 归一为毫秒', () {
      // 2026-09 实测值（epoch 秒）
      const url =
          'https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/03/83/1.m4s'
          '?e=ig8euxZM2rNc&deadline=1788939546&upsig=abc&type=mp4';
      expect(streamDeadlineMs(url), 1788939546000);
    });

    test('deadline 已是毫秒（~1.7e12，兼容旧/其他渠道）→ 原样返回', () {
      const url = 'https://x.bilivideo.com/1.m4s?deadline=1788939546000';
      expect(streamDeadlineMs(url), 1788939546000);
    });

    test('无 deadline 参数 → null（不预取，回退被动恢复）', () {
      const url = 'https://x.bilivideo.com/1.m4s?e=abc&upsig=def';
      expect(streamDeadlineMs(url), isNull);
    });

    test('deadline 非数字 → null', () {
      const url = 'https://x.bilivideo.com/1.m4s?deadline=not-a-number';
      expect(streamDeadlineMs(url), isNull);
    });

    test('URL 非法（宿主格式错误，Uri.tryParse 失败）→ null', () {
      // 注意：Dart Uri 对 query 里的非法百分号（如 %zz）宽容不抛错，能真正
      // 让 tryParse 返回 null 的是宿主格式错误（未闭合的 [ ）
      expect(streamDeadlineMs('http://[::1'), isNull);
    });

    test('无 scheme 的相对串（tryParse 成功但无 deadline 参数）→ null', () {
      expect(streamDeadlineMs('not a url at all'), isNull);
    });
  });

  group('streamDeadlineRemainMs（距到期剩余毫秒）', () {
    test('无 deadline → null', () {
      expect(streamDeadlineRemainMs(null, nowMs: 0), isNull);
    });

    test('未到期 → 正剩余', () {
      expect(streamDeadlineRemainMs(1000, nowMs: 200), 800);
    });

    test('已到期（now 晚于 deadline）→ ≤0', () {
      expect(streamDeadlineRemainMs(1000, nowMs: 1000), 0);
      expect(streamDeadlineRemainMs(1000, nowMs: 2500), lessThan(0));
    });
  });

  group('shouldPrefetchSource（URL 剩余不够播完剩余内容 + 提前量 → 换源）', () {
    // 提前量默认 kPrefetchLeadMs=60s。语义：deadlineRemain - videoRemain < lead。
    test('普通视频（deadline 2h ≫ 剩余内容）→ 不换源（主因非 URL 过期）', () {
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 7200000, videoRemainMs: 600000),
        isFalse,
        reason: '2h 内播完 10min 绰绰有余',
      );
    });

    test('刚好差一个提前量（diff == lead）→ 不换源（严格 <）', () {
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 100000, videoRemainMs: 40000),
        isFalse,
        reason: '剩余 40s、URL 还有 100s：差 60s == lead，够用不换',
      );
    });

    test('差不足提前量（diff < lead）→ 换源', () {
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 100000, videoRemainMs: 41000),
        isTrue,
        reason: '剩余 41s、URL 100s：差 59s < 60s，需提前换',
      );
    });

    test('URL 已过期（deadlineRemain ≤0）且还有内容 → 立即换源', () {
      expect(
        shouldPrefetchSource(deadlineRemainMs: -5000, videoRemainMs: 120000),
        isTrue,
      );
      expect(
        shouldPrefetchSource(deadlineRemainMs: 0, videoRemainMs: 1000),
        isTrue,
      );
    });

    test('deadline 缺失 → 不换源（回退被动恢复）', () {
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: null, videoRemainMs: 3600000),
        isFalse,
      );
    });

    test('剩余时长未知/已播完（videoRemain ≤ 0）→ 不换源', () {
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 1000, videoRemainMs: 0),
        isFalse,
      );
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 1000, videoRemainMs: -5),
        isFalse,
      );
    });

    test('自定义提前量生效（如验证时临时调小）', () {
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 100000, videoRemainMs: 60000, leadMs: 30000),
        isFalse,
        reason: '差 40s ≥ 自定义 lead 30s，够用不换',
      );
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 100000, videoRemainMs: 60000, leadMs: 60000),
        isTrue,
        reason: '差 40s < 默认 lead 60s，需换（与默认行为一致）',
      );
      expect(
        shouldPrefetchSource(
            deadlineRemainMs: 100000, videoRemainMs: 60000, leadMs: 90000),
        isTrue,
      );
    });
  });

  group('预取常量自洽（kPrefetchLeadMs / kPrefetchMinIntervalMs）', () {
    test('提前量 60s、节流间隔大于提前量（失败不风暴）', () {
      expect(kPrefetchLeadMs, 60000);
      expect(kPrefetchMinIntervalMs, greaterThan(kPrefetchLeadMs));
    });
  });
}
