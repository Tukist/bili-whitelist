// 视频卡「更多」菜单里的「加入稍后再看」（v2.58.0+）：
// - 写操作总开关**开着** → 菜单里有这一项，点了就调 add（只传 bvid）；
// - 写操作总开关**关着** → 整项不存在（不是置灰）；
// - add 失败 → 提示里带可读原因（不误报成功）。
//
// 用注入的假服务（[CollectionPage.toView]），不触网；白名单数据是本地构造的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/collection_page.dart';
import 'package:bili_whitelist_app/pages/watch_later_page.dart'
    show addToWatchLaterKey;
import 'package:bili_whitelist_app/services/bili_toview_api.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

WhitelistVideo _video(String bvid, String title) => WhitelistVideo(
      bvid: bvid,
      cid: 100,
      title: title,
      cover: '',
      duration: 90,
      upName: 'UP主',
      addedAt: '2026-08-01T00:00:00Z',
    );

WhitelistData _data(List<WhitelistVideo> videos) => WhitelistData(
      version: 4,
      updatedAt: '2026-08-20T00:00:00Z',
      videos: videos,
      collections: const [],
    );

/// 假服务：记录 add 的入参、可编排失败。
class _FakeAdd {
  _FakeAdd({this.error});

  Object? error;
  final List<({int? aid, String? bvid})> calls = [];

  late final BiliToViewService service = BiliToViewService(
    fetchList: () async => const {'count': 0, 'list': []},
    add: ({int? aid, String? bvid}) async {
      calls.add((aid: aid, bvid: bvid));
      if (error != null) throw error!;
    },
    remove: (aid) async {},
  );
}

Future<void> _pumpPage(WidgetTester tester, _FakeAdd fake) async {
  await tester.pumpWidget(MaterialApp(
    home: CollectionPage(
      collectionName: '',
      data: _data([_video('BV1moredemo', '测试视频甲')]),
      saveAndRefresh: (_) async {},
      toView: fake.service,
    ),
  ));
  await tester.pumpAndSettle();
}

/// 点开「更多」菜单（VideoTile 尾部的管理按钮）。
Future<void> _openMoreMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefsStore.instance.resetForTest(writeActionsEnabled: true, loaded: true);
  });

  testWidgets('写操作开着：菜单有「加入稍后再看」，点了以 bvid 调用 add',
      (tester) async {
    final fake = _FakeAdd();
    await _pumpPage(tester, fake);
    await _openMoreMenu(tester);

    expect(find.byKey(addToWatchLaterKey('BV1moredemo')), findsOneWidget);
    expect(find.text('加入稍后再看'), findsOneWidget);

    await tester.tap(find.text('加入稍后再看'));
    await tester.pumpAndSettle();

    expect(fake.calls, hasLength(1));
    expect(fake.calls.single.bvid, 'BV1moredemo');
    expect(fake.calls.single.aid, isNull, reason: '卡片只知道 bvid，不瞎编 aid');
    expect(find.textContaining('已加入稍后再看'), findsOneWidget);
    // 菜单已关（点了就收起，不叠在列表上）
    expect(find.text('移动到合集…'), findsNothing);
  });

  testWidgets('写操作关着：整项不存在（不是置灰）', (tester) async {
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: false, loaded: true);
    final fake = _FakeAdd();
    await _pumpPage(tester, fake);
    await _openMoreMenu(tester);

    expect(find.text('加入稍后再看'), findsNothing);
    expect(find.byKey(addToWatchLaterKey('BV1moredemo')), findsNothing);
    // 原有管理项照旧在（没被这次改动动到）
    expect(find.text('移动到合集…'), findsOneWidget);
    expect(fake.calls, isEmpty);
  });

  testWidgets('add 失败：提示带可读原因，不假装成功', (tester) async {
    final fake = _FakeAdd(
      error: const BiliApiException(
        code: 90001,
        message: '稍后再看已满（上限 100 个视频），请先移除一些',
        path: '/x/v2/history/toview/add',
      ),
    );
    await _pumpPage(tester, fake);
    await _openMoreMenu(tester);
    await tester.tap(find.text('加入稍后再看'));
    await tester.pumpAndSettle();

    expect(find.textContaining('加入稍后再看失败'), findsOneWidget);
    expect(find.textContaining('已满'), findsOneWidget);
    expect(find.textContaining('已加入稍后再看'), findsNothing);
  });
}
