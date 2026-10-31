// 历史页「同步 B 站历史」（v2.57.0+，读方向）UI 测试：
// 来源标记 / 「未在白名单」标记 / 上次同步时间 / 成功与失败的提示 /
// 同步中不可重复点 / 历史条目 → 可播放条目。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/history_page.dart';
import 'package:bili_whitelist_app/services/bili_history_api.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/widgets/history_tile.dart';

HistoryEntry _entry(
  String bvid,
  DateTime watchedAt, {
  String title = '标题',
  HistorySource source = HistorySource.local,
  bool inWhitelist = true,
  int positionMs = 30000,
  int durationMs = 120000,
}) =>
    HistoryEntry(
      bvid: bvid,
      pageIndex: 0,
      cid: 111,
      title: title,
      cover: '',
      upName: 'UP主',
      durationMs: durationMs,
      positionMs: positionMs,
      watchedAt: watchedAt,
      source: source,
      inWhitelist: inWhitelist,
    );

WhitelistVideo _video(String bvid, {String title = '白名单视频'}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 111,
      title: title,
      cover: '',
      duration: 600,
      upName: 'UP主',
      addedAt: '2026-01-01T00:00:00.000Z',
    );

WhitelistData _wl(List<WhitelistVideo> videos) => WhitelistData(
      version: 4,
      updatedAt: '2026-01-01T00:00:00.000Z',
      videos: videos,
    );

Map<String, dynamic> _remoteItem(String bvid, {int progress = 42}) => {
      'title': '远程标题',
      'cover': '',
      'history': {
        'oid': 80433022,
        'epid': 0,
        'bvid': bvid,
        'page': 1,
        'cid': 111,
        'business': 'archive',
      },
      'author_name': 'UP主',
      'view_at': 1700000000,
      'progress': progress,
      'duration': 600,
    };

/// 真服务（注入假 fetchPage / 假白名单）：不走网络也能测 UI 的两条路径。
BiliHistorySyncService _service({
  required Future<Map<String, dynamic>> Function({
    int? max,
    int? viewAt,
    String? business,
    int ps,
  }) fetchPage,
  List<WhitelistVideo>? whitelist,
  DateTime? now,
}) =>
    BiliHistorySyncService(
      fetchPage: fetchPage,
      whitelist: () async => _wl(whitelist ?? [_video('BVremote')]),
      store: HistoryStore.instance,
      now: () => now ?? DateTime(2026, 9, 8, 12),
    );

Future<void> _pump(WidgetTester tester, BiliHistorySyncService service) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: HistoryPage(sync: service))),
  );
  await tester.pump(); // reload() 完成
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('来源标记：本机不显示；「只来自 B 站」「两边都有」各一行',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(
        _entry('BVlocal', DateTime.now().subtract(const Duration(minutes: 10)),
            title: '本机看的'));
    await store.addOrUpdate(
        _entry('BVremote', DateTime.now().subtract(const Duration(minutes: 20)),
            title: '只在 B 站看过', source: HistorySource.bilibili));
    await store.addOrUpdate(
        _entry('BVboth', DateTime.now().subtract(const Duration(minutes: 30)),
            title: '两边都看过', source: HistorySource.both));

    await _pump(tester, _service(fetchPage: ({max, viewAt, business, ps = 30}) async => {'cursor': null, 'list': []}));

    expect(find.text('本机看的'), findsOneWidget);
    expect(find.text('来自 B 站'), findsOneWidget);
    expect(find.text('来自 B 站 · 本机也看过'), findsOneWidget);
    // 三条里只有两条带来源标记（本机那条不显示任何额外字样）
    expect(find.textContaining('来自 B 站'), findsNWidgets(2));
  });

  testWidgets('上次同步时间：没同步过 → 显示「还没同步过 B 站历史」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pump(
        tester,
        _service(
            fetchPage: ({max, viewAt, business, ps = 30}) async =>
                {'cursor': null, 'list': []}));
    expect(find.text('还没同步过 B 站历史'), findsOneWidget);
  });

  testWidgets('上次同步时间：同步过 → 显示相对时间', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await HistoryStore.instance.saveLastSyncAt(DateTime.now());
    await _pump(
        tester,
        _service(
            fetchPage: ({max, viewAt, business, ps = 30}) async =>
                {'cursor': null, 'list': []}));
    expect(find.text('上次同步 B 站历史：刚刚'), findsOneWidget);
  });

  testWidgets('点「同步 B 站历史」→ 白名单内外都并入 + 非白名单标「未在白名单」'
      '+ 成功提示 + 时间更新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final syncAt = DateTime.now();
    final service = _service(
      now: syncAt,
      whitelist: [_video('BVremote', title: '白名单视频')],
      fetchPage: ({max, viewAt, business, ps = 30}) async => {
        'cursor': null,
        'list': [
          _remoteItem('BVremote'),
          // 不在白名单的普通投稿（v2.57.0 调整：**也必须保留**）
          _remoteItem('BVnotWhitelisted'),
        ],
      },
    );
    await _pump(tester, service);

    expect(find.text('还没同步过 B 站历史'), findsOneWidget);
    await tester.tap(find.byKey(kHistorySyncButtonKey));
    await tester.pump(); // 同步（假 fetch 立即完成）
    await tester.pump(); // reload + setState
    await tester.pump(const Duration(milliseconds: 300)); // SnackBar 入场

    // 两条都进来：白名单那条用白名单的标题，非白名单那条用远程标题
    expect(find.text('白名单视频'), findsOneWidget);
    expect(find.text('远程标题'), findsOneWidget);
    final all = await HistoryStore.instance.getAll();
    expect(all.map((e) => e.bvid), containsAll(['BVremote', 'BVnotWhitelisted']));
    final inWl = all.singleWhere((e) => e.bvid == 'BVremote');
    final out = all.singleWhere((e) => e.bvid == 'BVnotWhitelisted');
    expect(inWl.source, HistorySource.bilibili);
    expect(inWl.positionMs, 42000);
    expect(inWl.inWhitelist, isTrue);
    expect(out.inWhitelist, isFalse, reason: '同步时不在白名单 → 要能标出来');
    expect(out.cid, 111, reason: '远程 cid 拿来直接能播');

    // 来源标记（两条都来自 B 站）+ 非白名单标记（只有一条）
    expect(find.text('来自 B 站'), findsNWidgets(2));
    expect(find.text('未在白名单'), findsOneWidget);
    expect(find.text('上次同步 B 站历史：刚刚'), findsOneWidget);
    expect(
      find.text('已同步 2 条 B 站历史 · 新增 2 · 其中 1 条不在白名单'),
      findsOneWidget,
    );

    // 「未在白名单」只是标记：条目仍然可点（不置灰、onTap 仍在）
    final tiles = tester
        .widgetList<ListTile>(find.descendant(
          of: find.byType(HistoryTile),
          matching: find.byType(ListTile),
        ))
        .toList();
    expect(tiles, hasLength(2));
    expect(tiles.every((t) => t.onTap != null), isTrue,
        reason: '非白名单条目也要能点开播');
  });

  testWidgets('白名单条目没有「未在白名单」标记', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await HistoryStore.instance.addOrUpdate(_entry(
        'BVin', DateTime.now(), title: '白名单里的', inWhitelist: true));
    await HistoryStore.instance.addOrUpdate(_entry(
        'BVout', DateTime.now(), title: '白名单外的', inWhitelist: false));

    await _pump(
        tester,
        _service(
            fetchPage: ({max, viewAt, business, ps = 30}) async =>
                {'cursor': null, 'list': []}));

    expect(find.text('白名单里的'), findsOneWidget);
    expect(find.text('白名单外的'), findsOneWidget);
    // 只有一条带标记
    expect(find.text('未在白名单'), findsOneWidget);
  });

  test('历史条目 → 可播放的 WhitelistVideo（非白名单条目也能播）', () {
    final e = HistoryEntry(
      bvid: 'BVoutside',
      pageIndex: 1,
      cid: 424242,
      title: '别人的投稿',
      cover: 'http://r/c.jpg',
      upName: '某UP',
      durationMs: 700000,
      positionMs: 42000,
      watchedAt: DateTime(2026, 9, 8),
      inWhitelist: false,
    );
    final v = videoFromHistoryEntry(e);
    expect(v.bvid, 'BVoutside');
    expect(v.cid, 424242, reason: '取流只认 cid');
    expect(v.title, '别人的投稿');
    expect(v.cover, 'http://r/c.jpg');
    expect(v.upName, '某UP');
    expect(v.duration, 700, reason: '毫秒 → 秒');
    expect(v.pages, isNull);
  });

  testWidgets('同步失败 → 错误提示给可读原因（不静默），列表保持原样',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await HistoryStore.instance.addOrUpdate(
        _entry('BVlocal', DateTime.now().subtract(const Duration(minutes: 5)),
            title: '本机看的'));
    final service = _service(
      fetchPage: ({max, viewAt, business, ps = 30}) async =>
          throw const BiliApiException(
            code: -101,
            message: '登录已失效，请重新登录 B 站账号',
          ),
    );
    await _pump(tester, service);

    await tester.tap(find.byKey(kHistorySyncButtonKey));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('同步 B 站历史失败：未登录或登录已失效，请先登录 B 站账号'),
      findsOneWidget,
    );
    // 失败不动本机历史，也没记"上次同步时间"
    expect(find.text('本机看的'), findsOneWidget);
    expect(find.text('还没同步过 B 站历史'), findsOneWidget);
  });

  testWidgets('同步中按钮置灰：连点只发一次请求', (tester) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final gate = Completer<void>();
    final service = _service(
      fetchPage: ({max, viewAt, business, ps = 30}) async {
        calls++;
        await gate.future;
        return {'cursor': null, 'list': []};
      },
    );
    await _pump(tester, service);

    await tester.tap(find.byKey(kHistorySyncButtonKey));
    await tester.pump();
    // 同步进行中：按钮 onPressed 为 null（置灰）+ 图标换成转圈
    final iconButton = tester.widget<IconButton>(find.byKey(kHistorySyncButtonKey));
    expect(iconButton.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byKey(kHistorySyncButtonKey), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1, reason: '同步中再点不许发第二次');

    gate.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
  });
}
