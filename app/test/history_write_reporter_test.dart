// 观看进度上报器（v2.57.0+，写方向）单元测试：开关关着零请求 / 节流 /
// 强制上报 / 失败退避 / 连续失败停手 / 未登录与风控立刻停手。
//
// v2.57.0 调整后开关**默认开**，但本文件所有用例都显式给 `enabled`
// 赋值：这里测的是"给定开关取值时上报器的行为"，与出厂默认值解耦；
// 默认值本身在 `history_write_prefs_test.dart` 里断言。
//
// 用假时钟 + 假 sender：把"什么时候该发、失败之后还敢不敢发"钉死在断言上，
// 不依赖任何网络或播放器。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/services/bili_history_reporter.dart';

/// 假 sender：记录每次调用的参数；可按需抛指定异常。
class _FakeSender {
  final List<({int aid, int cid, int progress})> calls = [];

  /// 依次弹出的错误（空了就成功）。
  final List<Object> errors = [];

  Future<void> send({
    required int aid,
    required int cid,
    required int progress,
  }) async {
    calls.add((aid: aid, cid: cid, progress: progress));
    if (errors.isNotEmpty) throw errors.removeAt(0);
  }
}

void main() {
  /// 可控时钟：`clock.advance()` 往前走。
  late DateTime now;
  late _FakeSender sender;
  late bool enabled;

  BiliHistoryReporter build({
    Duration minInterval = const Duration(seconds: 60),
    int maxConsecutiveFailures = 3,
  }) =>
      BiliHistoryReporter(
        send: sender.send,
        enabled: () => enabled,
        now: () => now,
        minInterval: minInterval,
        maxConsecutiveFailures: maxConsecutiveFailures,
      );

  setUp(() {
    now = DateTime(2026, 9, 1, 12);
    sender = _FakeSender();
    enabled = false;
  });

  test('开关关着 → 一次都不发（返回 disabled）', () async {
    final r = build();
    final res = await r.report(aid: 1, cid: 2, progress: 30);
    expect(res, HistoryReportResult.disabled);
    expect(sender.calls, isEmpty, reason: '关着时一个请求都不许发');
    expect(r.attempts, 0);

    // 播放中反复调用也一样（10s 一次 × 6 次 = 一分钟）
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(seconds: 10));
      await r.report(aid: 1, cid: 2, progress: 30 + i);
    }
    expect(sender.calls, isEmpty);
  });

  test('开着：首次立刻发；60s 内节流；到点再发（节流真的是按间隔算）', () async {
    enabled = true;
    final r = build();

    expect(await r.report(aid: 1, cid: 2, progress: 10),
        HistoryReportResult.sent);
    expect(sender.calls, hasLength(1));
    expect(sender.calls.single,
        (aid: 1, cid: 2, progress: 10));

    now = now.add(const Duration(seconds: 59));
    expect(await r.report(aid: 1, cid: 2, progress: 69),
        HistoryReportResult.throttled);
    expect(sender.calls, hasLength(1), reason: '59s 时还不该发');

    now = now.add(const Duration(seconds: 1)); // 满 60s
    expect(await r.report(aid: 1, cid: 2, progress: 70),
        HistoryReportResult.sent);
    expect(sender.calls, hasLength(2));
  });

  test('force（暂停/退出）绕过节流，但仍受开关约束', () async {
    enabled = true;
    final r = build();
    await r.report(aid: 1, cid: 2, progress: 10);
    now = now.add(const Duration(seconds: 5));

    expect(await r.report(aid: 1, cid: 2, progress: 15, force: true),
        HistoryReportResult.sent);
    expect(sender.calls, hasLength(2), reason: '暂停时那次必须发出去');

    enabled = false;
    expect(await r.report(aid: 1, cid: 2, progress: 150, force: true),
        HistoryReportResult.disabled);
    expect(sender.calls, hasLength(2), reason: '关掉之后连 force 也不许发');
  });

  test('aid/cid 无效 → invalid，不发请求', () async {
    enabled = true;
    final r = build();
    expect(await r.report(aid: 0, cid: 2, progress: 1),
        HistoryReportResult.invalid);
    expect(await r.report(aid: 1, cid: 0, progress: 1),
        HistoryReportResult.invalid);
    expect(sender.calls, isEmpty);
  });

  test('负数进度夹到 0 再发（不把脏值发出去）', () async {
    enabled = true;
    final r = build();
    await r.report(aid: 1, cid: 2, progress: -8);
    expect(sender.calls.single.progress, 0);
  });

  test('失败 → 退避 60s：窗口内不发，到点重试；成功后清退避', () async {
    enabled = true;
    sender.errors.add(DioLikeException());
    final r = build();

    expect(await r.report(aid: 1, cid: 2, progress: 10),
        HistoryReportResult.failed);
    expect(r.failures, 1);
    expect(r.nextAllowedAt, now.add(const Duration(seconds: 60)));

    now = now.add(const Duration(seconds: 30));
    expect(await r.report(aid: 1, cid: 2, progress: 40, force: true),
        HistoryReportResult.backoff, reason: '退避窗口内连 force 也不发');
    expect(sender.calls, hasLength(1));

    now = now.add(const Duration(seconds: 31)); // 过了退避窗口
    expect(await r.report(aid: 1, cid: 2, progress: 71),
        HistoryReportResult.sent);
    expect(sender.calls, hasLength(2));
    expect(r.nextAllowedAt, isNull, reason: '成功后退避清空');
    expect(r.successes, 1);
  });

  test('连续失败 3 次 → 本次会话停手，之后一次都不发', () async {
    enabled = true;
    sender.errors.addAll([DioLikeException(), DioLikeException(), DioLikeException()]);
    final r = build(maxConsecutiveFailures: 3);

    expect(await r.report(aid: 1, cid: 2, progress: 1),
        HistoryReportResult.failed);
    now = now.add(const Duration(seconds: 61));
    expect(await r.report(aid: 1, cid: 2, progress: 61),
        HistoryReportResult.failed);
    now = now.add(const Duration(seconds: 121));
    expect(await r.report(aid: 1, cid: 2, progress: 182),
        HistoryReportResult.failedStopped);
    expect(r.stoppedForSession, isTrue);
    expect(sender.calls, hasLength(3));

    // 之后无论怎么推进时间、怎么 force 都不再发
    now = now.add(const Duration(hours: 1));
    expect(await r.report(aid: 1, cid: 2, progress: 300, force: true),
        HistoryReportResult.stopped);
    expect(sender.calls, hasLength(3), reason: '停手之后不许再刷接口');
  });

  test('未登录（-101）→ 第一次失败就停手（继续发只会反复失败）', () async {
    enabled = true;
    sender.errors.add(
      const BiliApiException(code: -101, message: '请先登录 B 站账号'),
    );
    final r = build();

    expect(await r.report(aid: 1, cid: 2, progress: 1),
        HistoryReportResult.failedStopped);
    expect(r.stoppedForSession, isTrue);

    now = now.add(const Duration(minutes: 5));
    expect(await r.report(aid: 1, cid: 2, progress: 300),
        HistoryReportResult.stopped);
    expect(sender.calls, hasLength(1));
  });

  test('风控（-412）→ 同样立刻停手（别往风控里钻）', () async {
    enabled = true;
    sender.errors.add(
      const BiliApiException(code: -412, message: '请求被拦截'),
    );
    final r = build();
    expect(await r.report(aid: 1, cid: 2, progress: 1),
        HistoryReportResult.failedStopped);
    expect(r.stoppedForSession, isTrue);
    expect(sender.calls, hasLength(1));
  });

  test('失败静默：report 永不抛（调用方可以放心 unawaited）', () async {
    enabled = true;
    sender.errors.add(StateError('boom'));
    final r = build();
    // 不抛就通过（有任何异常这个 await 会炸测试）
    final res = await r.report(aid: 1, cid: 2, progress: 1);
    expect(res, HistoryReportResult.failed);
  });

  test('上一次还在飞时不叠请求（busy）', () async {    enabled = true;
    var release = Completer<void>();
    final inflight = <({int aid, int cid, int progress})>[];
    final r = BiliHistoryReporter(
      send: ({required int aid, required int cid, required int progress}) async {
        inflight.add((aid: aid, cid: cid, progress: progress));
        await release.future;
      },
      enabled: () => true,
      now: () => now,
    );

    final first = r.report(aid: 1, cid: 2, progress: 10);
    // 让 send 进入 await
    await Future<void>.delayed(Duration.zero);
    expect(await r.report(aid: 1, cid: 2, progress: 11, force: true),
        HistoryReportResult.busy);
    release.complete();
    expect(await first, HistoryReportResult.sent);
    expect(inflight, hasLength(1));
  });

  group('shouldReportHistory（播放页的前置判定）', () {
    test('开关关着 → false（这一步挡在"取 aid"之前，所以零请求）', () {
      expect(
        shouldReportHistory(
            enabled: false,
            loggedIn: true,
            isPgc: false,
            cid: 111,
            positionMs: 30000),
        isFalse,
      );
    });

    test('未登录 → false（本地 `bili_jct` 检查，连取 aid 的 view 都不发）', () {
      expect(
        shouldReportHistory(
            enabled: true,
            loggedIn: false,
            isPgc: false,
            cid: 111,
            positionMs: 30000),
        isFalse,
      );
    });

    test('开着 + 已登录 + 普通视频 + 有效 cid/位置 → true', () {
      expect(
        shouldReportHistory(
            enabled: true,
            loggedIn: true,
            isPgc: false,
            cid: 111,
            positionMs: 30000),
        isTrue,
      );
    });

    test('番剧集（pgc）/ cid 无效 / 位置为 0 → false', () {
      expect(
        shouldReportHistory(
            enabled: true,
            loggedIn: true,
            isPgc: true,
            cid: 111,
            positionMs: 30000),
        isFalse,
      );
      expect(
        shouldReportHistory(
            enabled: true,
            loggedIn: true,
            isPgc: false,
            cid: 0,
            positionMs: 30000),
        isFalse,
      );
      expect(
        shouldReportHistory(
            enabled: true,
            loggedIn: true,
            isPgc: false,
            cid: 111,
            positionMs: 0),
        isFalse,
      );
    });
  });
}

/// 模拟网络层失败（不是 BiliApiException → 按普通失败退避，不停手）。
class DioLikeException implements Exception {
  @override
  String toString() => 'DioLikeException(connectionError)';
}
