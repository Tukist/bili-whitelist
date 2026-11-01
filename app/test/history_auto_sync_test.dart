// 历史页**自动同步**（v2.59.0）测试。
//
// 覆盖：
// - 进页面**自动**同步一次（不用点右上角按钮）；
// - 节流：距上次成功 9 分钟不拉、11 分钟拉（fake clock，不用等真实时间）；
// - 下拉刷新**强制**同步（绕过节流）；
// - 自动同步失败 → 只在页内留一行轻提示，**不弹** SnackBar；
// - 未登录 → 一个请求都不发 + 页内给「登录后可同步 B 站历史」；
// - 页内文案与行为一致（说清"进页面自动同步 / 下拉强制刷新"）。
//
// 断言都落在**可观测的东西**上：假 fetchPage 的调用次数、页内文案、有没有
// SnackBar —— 不去戳私有字段。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/history_page.dart';
import 'package:bili_whitelist_app/services/bili_history_api.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

/// 固定的「现在」：节流判定与写入的同步时间都用它，测试不依赖真实时钟。
final DateTime _now = DateTime(2026, 9, 8, 12);

WhitelistData _wl() => const WhitelistData(
  version: 4,
  updatedAt: '2026-01-01T00:00:00.000Z',
  videos: [],
);

/// 挂载历史页并把「进页面自动同步」那条异步链跑完。
///
/// 返回 fetchPage 的调用记录（每拉一页记一次）。
Future<List<int>> _pumpHistory(
  WidgetTester tester, {
  bool loggedIn = true,
  DateTime? lastSyncAt,
  BiliApiException? failure,
  DateTime? now,
}) async {
  final calls = <int>[];
  if (lastSyncAt != null) {
    await HistoryStore.instance.saveLastSyncAt(lastSyncAt);
  }
  final clock = now ?? _now;
  final service = BiliHistorySyncService(
    fetchPage: ({max, viewAt, business, ps = 30}) async {
      calls.add(1);
      if (failure != null) throw failure;
      return {'cursor': null, 'list': <dynamic>[]};
    },
    whitelist: () async => _wl(),
    store: HistoryStore.instance,
    now: () => clock,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HistoryPage(
          sync: service,
          loggedIn: () async => loggedIn,
          now: () => clock,
        ),
      ),
    ),
  );
  // reload → 登录判定 → 节流判定 → 同步，每一跳都是一个 await
  for (var i = 0; i < 10; i++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300)); // 万一有 SnackBar 让它入场
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('节流判定（纯函数）', () {
    test('距上次成功 9 分钟 → 不自动同步', () {
      expect(
        shouldAutoSyncHistory(
          lastSyncAt: _now.subtract(const Duration(minutes: 9)),
          lastAttemptAt: null,
          now: _now,
        ),
        isFalse,
      );
    });

    test('距上次成功 11 分钟 → 自动同步', () {
      expect(
        shouldAutoSyncHistory(
          lastSyncAt: _now.subtract(const Duration(minutes: 11)),
          lastAttemptAt: null,
          now: _now,
        ),
        isTrue,
      );
    });

    test('从没同步过 → 自动同步', () {
      expect(
        shouldAutoSyncHistory(
          lastSyncAt: null,
          lastAttemptAt: null,
          now: _now,
        ),
        isTrue,
      );
    });

    test('上次**尝试**（失败）在窗口内 → 不自动同步（防失败后死循环刷接口）', () {
      expect(
        shouldAutoSyncHistory(
          lastSyncAt: null,
          lastAttemptAt: _now.subtract(const Duration(minutes: 1)),
          now: _now,
        ),
        isFalse,
      );
    });

    test('force（下拉刷新）绕过节流，但未登录仍不发请求', () {
      final recent = _now.subtract(const Duration(minutes: 1));
      expect(
        shouldAutoSyncHistory(
          lastSyncAt: recent,
          lastAttemptAt: recent,
          now: _now,
          force: true,
        ),
        isTrue,
        reason: '用户明确要求刷新',
      );
      expect(
        shouldAutoSyncHistory(
          lastSyncAt: recent,
          lastAttemptAt: recent,
          now: _now,
          force: true,
          loggedIn: false,
        ),
        isFalse,
        reason: '未登录时下拉也不该发请求',
      );
    });
  });

  testWidgets('进页面自动同步一次（不用点按钮），且成功不弹提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = await _pumpHistory(tester, now: DateTime.now());

    expect(calls, hasLength(1), reason: '进页面就该自己同步一次');
    expect(find.text('上次同步 B 站历史：刚刚'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing, reason: '自动同步成功要安静');
    expect(find.byKey(kHistoryAutoSyncNoticeKey), findsNothing);
  });

  testWidgets('节流：距上次成功 9 分钟 → 进页面不拉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = await _pumpHistory(
      tester,
      lastSyncAt: _now.subtract(const Duration(minutes: 9)),
    );

    expect(calls, isEmpty);
  });

  testWidgets('节流：距上次成功 11 分钟 → 进页面拉一次', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = await _pumpHistory(
      tester,
      lastSyncAt: _now.subtract(const Duration(minutes: 11)),
    );

    expect(calls, hasLength(1));
  });

  testWidgets('下拉刷新 → 强制同步（节流窗口内也拉）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = await _pumpHistory(
      tester,
      lastSyncAt: _now.subtract(const Duration(minutes: 2)),
    );
    expect(calls, isEmpty, reason: '前置：进页面这次被节流挡住了');

    // 下拉（列表为空时走空态的 scrollable）→ 触发 RefreshIndicator.onRefresh
    await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
    await tester.pump(); // 松手
    await tester.pump(const Duration(seconds: 1)); // 指示器 → onRefresh
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }

    expect(calls, hasLength(1), reason: '下拉必须强制同步，不受 10 分钟节流限制');
  });

  testWidgets('自动同步失败 → 只在页内留一行轻提示，不弹错误提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = await _pumpHistory(
      tester,
      failure: const BiliApiException(code: -412, message: '请求被拦截'),
    );

    expect(calls, hasLength(1), reason: '前置：确实发了一次');
    final notice = tester.widget<Text>(find.byKey(kHistoryAutoSyncNoticeKey));
    expect(notice.data, contains('自动同步失败'));
    expect(notice.data, contains('风控'), reason: '失败原因要可读');
    expect(find.byType(SnackBar), findsNothing,
        reason: '用户没点任何东西，不该弹错误提示');
    // 失败不记"上次同步时间"
    expect(find.text('还没同步过 B 站历史'), findsOneWidget);
  });

  testWidgets('未登录 → 一个请求都不发，页内给「登录后可同步 B 站历史」',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = await _pumpHistory(tester, loggedIn: false);

    expect(calls, isEmpty, reason: '未登录时连历史 cursor 都不该拉');
    final notice = tester.widget<Text>(find.byKey(kHistoryAutoSyncNoticeKey));
    expect(notice.data, kHistoryLoginRequiredHint);
    expect(find.text('登录后可同步 B 站历史'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // 已登录/未登录都保留「上次同步」那行（用户仍能看出上次是什么时候）
    expect(find.text('还没同步过 B 站历史'), findsOneWidget);
  });

  testWidgets('页内文案说清同步怎么发生（自动 + 下拉强制），与行为一致',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpHistory(
      tester,
      lastSyncAt: _now.subtract(const Duration(minutes: 1)),
    );

    expect(find.textContaining('进页面自动同步'), findsOneWidget);
    expect(find.textContaining('下拉可强制刷新'), findsOneWidget);
    // 手动入口保留
    expect(find.byKey(kHistorySyncButtonKey), findsOneWidget);
  });
}
