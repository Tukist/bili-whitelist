// 播放页会员集取流回退决策单测（纯函数，无原生/网络依赖）：
// - shouldFallbackToPgc：普通 playurl 失败 → 是否回退 pgc 端点
// - pgcFallbackAction：pgc 取流结果（完整流/试看流/异常）→ 播放动作
// - pgcFallbackMessage：各动作 → 用户文案（试看/无权限不误导）
//
// 决策逻辑见 lib/pages/player_page.dart 顶部的纯函数（v2.16.4 会员番剧播放）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

void main() {
  group('shouldFallbackToPgc（普通 playurl 失败 → 回退判定）', () {
    test('有 epId + 普通接口 -404（会员集实测特征）→ 回退', () {
      const e = BiliApiException(
          code: -404, message: '啥都木有（BV1/123）', path: '/x/player/wbi/playurl');
      expect(shouldFallbackToPgc(epId: 98604, error: e), isTrue);
    });

    test('有 epId + -10403（无权限）→ 回退', () {
      const e = BiliApiException(code: -10403, message: '大会员专享');
      expect(shouldFallbackToPgc(epId: 98604, error: e), isTrue);
    });

    test('有 epId + 非权限错误（-412 风控 / -352 限流 / 62002 失效）→ 不回退', () {
      expect(
          shouldFallbackToPgc(
              epId: 98604,
              error: const BiliApiException(code: -412, message: '风控')),
          isFalse);
      expect(
          shouldFallbackToPgc(
              epId: 98604,
              error: const BiliApiException(code: -352, message: '限流')),
          isFalse);
      expect(
          shouldFallbackToPgc(
              epId: 98604,
              error: const BiliApiException(code: 62002, message: '稿件失效')),
          isFalse);
    });

    test('有 epId + 非 BiliApiException（网络错误）→ 不回退', () {
      expect(
          shouldFallbackToPgc(
              epId: 98604,
              error: StateError('网络错误')),
          isFalse);
    });

    test('无 epId（普通视频/旧番剧数据）→ 任何失败都不回退', () {
      const e = BiliApiException(code: -404, message: 'x');
      expect(shouldFallbackToPgc(epId: null, error: e), isFalse);
      expect(
          shouldFallbackToPgc(
              epId: null,
              error: const BiliApiException(code: -10403, message: 'x')),
          isFalse);
      expect(
          shouldFallbackToPgc(epId: null, error: StateError('x')),
          isFalse);
    });
  });

  group('pgcFallbackAction（pgc 取流结果 → 播放动作）', () {
    const full = PgcPlayUrlResult(
        quality: 80,
        dashVideoUrls: ['https://x/v.m4s'],
        dashAudioUrls: ['https://x/a.m4s'],
        isPreview: false);
    const trial = PgcPlayUrlResult(
        quality: 416,
        mp4Url: 'https://x/preview.mp4',
        isPreview: true);

    test('非试看完整流 → play', () {
      expect(pgcFallbackAction(result: full, error: null),
          PgcFallbackAction.play);
    });

    test('is_preview=1 试看流 → trialOnly（不播试看，防误导）', () {
      expect(pgcFallbackAction(result: trial, error: null),
          PgcFallbackAction.trialOnly);
    });

    test('取流抛异常（result 为 null）→ failed', () {
      expect(
          pgcFallbackAction(
              result: null,
              error: const BiliApiException(code: -10403, message: '大会员专享')),
          PgcFallbackAction.failed);
      expect(pgcFallbackAction(result: null, error: DioErrorStub()),
          PgcFallbackAction.failed);
    });
  });

  group('pgcFallbackMessage（用户文案不误导）', () {
    test('试看流文案：明示大会员 + 试看 + 登录指引', () {
      final msg = pgcFallbackMessage(PgcFallbackAction.trialOnly);
      expect(msg, contains('大会员'));
      expect(msg, contains('试看'));
      expect(msg, contains('登录'));
    });

    test('失败文案：大会员/付费 + 登录指引', () {
      final msg = pgcFallbackMessage(PgcFallbackAction.failed);
      expect(msg, contains('大会员'));
      expect(msg, contains('登录大会员账号后观看'));
    });

    test('play 动作无文案', () {
      expect(pgcFallbackMessage(PgcFallbackAction.play), isEmpty);
    });
  });
}

/// 模拟网络错误的轻量替身（避免直接构造真实 DioException）。
class DioErrorStub implements Exception {
  @override
  String toString() => 'DioException [connection]: Connection refused';
}
