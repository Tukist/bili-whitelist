// 稍后再看页（v2.58.0+）· 列表渲染 / 空态 / 失败态 / 移除（成功就地摘掉、
// 失败保留且给可读原因）/ 点播带分 P 下标 / 写操作总开关关着时只读。
//
// 全部用注入的假服务（[BiliToViewService] 的三个闭包），**不触网**；
// 播放入口也注入替身（不推含原生播放器的 PlayerPage）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/watch_later_page.dart';
import 'package:bili_whitelist_app/services/bili_toview_api.dart';
import 'package:bili_whitelist_app/services/ui_prefs_store.dart';

/// 一条列表数据（封面留空 → 走占位图，测试里不会发图片请求）。
Map<String, dynamic> _item({
  int aid = 1,
  String bvid = 'BV1aa411c7dd',
  int cid = 111,
  int page = 1,
  int videos = 1,
  String title = '标题甲',
  String up = 'UP甲',
  int duration = 600,
  int progress = 42,
  int addAt = 1700000000,
}) =>
    {
      'aid': aid,
      'bvid': bvid,
      'cid': cid,
      'videos': videos,
      'title': title,
      'pic': '',
      'duration': duration,
      'progress': progress,
      'add_at': addAt,
      'owner': {'mid': 9, 'name': up},
      'page': {'cid': cid, 'page': page},
    };

/// 假服务：记录调用次数、可编排每次结果。
class _FakeToView {
  _FakeToView({
    List<Map<String, dynamic>>? items,
    this.listError,
    this.removeError,
  }) : data = {'count': items?.length ?? 0, 'list': items ?? const []};

  Map<String, dynamic> data;
  Object? listError;
  Object? removeError;

  int fetchCount = 0;
  final List<int> removedAids = [];

  late final BiliToViewService service = BiliToViewService(
    fetchList: () async {
      fetchCount++;
      if (listError != null) throw listError!;
      return data;
    },
    add: ({int? aid, String? bvid}) async {},
    remove: (aid) async {
      if (removeError != null) throw removeError!;
      removedAids.add(aid);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _FakeToView fake, {
  OpenToViewPlayer? openPlayer,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: WatchLaterPage(service: fake.service, openPlayer: openPlayer),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 默认：写操作开（移除按钮出现）；单测里再按需关掉
    UiPrefsStore.instance.resetForTest(writeActionsEnabled: true, loaded: true);
  });

  testWidgets('列表渲染：标题 / 上次看到位置 / UP 主 / 加入时间 / 头部条数',
      (tester) async {
    final fake = _FakeToView(items: [
      _item(aid: 1, title: '三体解说', up: '刘慈欣', progress: 42, duration: 600),
      _item(aid: 2, bvid: 'BV1bb', title: '第二个', progress: 0, duration: 300),
    ]);
    await _pump(tester, fake);

    expect(find.text('稍后再看'), findsOneWidget);
    expect(find.text('三体解说'), findsOneWidget);
    expect(find.text('第二个'), findsOneWidget);
    expect(find.text('上次看到 0:42 / 10:00'), findsOneWidget);
    expect(find.text('还没看过'), findsOneWidget,
        reason: '进度 0 不该显示 0:00 / 0:00');
    expect(find.textContaining('刘慈欣'), findsOneWidget);
    expect(find.textContaining('加入 '), findsNWidgets(2));
    expect(find.textContaining('B 站账号里的稍后再看'), findsOneWidget);
    expect(find.textContaining('共 2 条'), findsOneWidget);
    expect(fake.fetchCount, 1);
  });

  testWidgets('空态：给可读的一句（含"怎么加进来"）', (tester) async {
    final fake = _FakeToView(items: []);
    await _pump(tester, fake);
    expect(find.text('稍后再看是空的'), findsOneWidget);
    expect(find.textContaining('加入稍后再看'), findsOneWidget);
  });

  testWidgets('失败态：未登录给出可读原因 + 重试可恢复', (tester) async {
    final fake = _FakeToView(
      listError: const BiliApiException(
        code: -101,
        message: '账号未登录',
        path: '/x/v2/history/toview',
      ),
    );
    await _pump(tester, fake);
    expect(find.textContaining('未登录或登录已失效'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 点重试 → 这次成功 → 列表出现（失败态不残留）
    fake.listError = null;
    fake.data = {
      'count': 1,
      'list': [_item(aid: 5, title: '重试后拿到的')],
    };
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试后拿到的'), findsOneWidget);
    expect(fake.fetchCount, 2);
  });

  testWidgets('风控 / 网络都翻成人话（不是裸 code）', (tester) async {
    final fake = _FakeToView(
      listError: const BiliApiException(
        code: -412,
        message: '请求被拦截',
        path: '/x/v2/history/toview',
      ),
    );
    await _pump(tester, fake);
    expect(find.textContaining('风控'), findsOneWidget);
  });

  testWidgets('移除成功：确认后该行就地消失，**不重拉全量**', (tester) async {
    final fake = _FakeToView(items: [
      _item(aid: 11, title: '留下来'),
      _item(aid: 22, bvid: 'BV1cc', title: '要删的'),
    ]);
    await _pump(tester, fake);
    expect(find.text('要删的'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('watch-later-remove-22')));
    await tester.pumpAndSettle();
    // 二次确认（与历史记录删除同一套习惯）
    expect(find.text('从稍后再看移除？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();

    expect(fake.removedAids, [22], reason: '删的是被点的那一条的 aid');
    expect(find.text('要删的'), findsNothing);
    expect(find.text('留下来'), findsOneWidget);
    expect(fake.fetchCount, 1, reason: '就地摘掉那一行，不重拉全量');
    expect(find.textContaining('共 1 条'), findsOneWidget);
    expect(find.textContaining('已从稍后再看移除'), findsOneWidget);
  });

  testWidgets('取消确认：什么都不删', (tester) async {
    final fake = _FakeToView(items: [_item(aid: 11, title: '别删我')]);
    await _pump(tester, fake);

    await tester.tap(find.byKey(const ValueKey('watch-later-remove-11')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(fake.removedAids, isEmpty);
    expect(find.text('别删我'), findsOneWidget);
  });

  testWidgets('移除失败：那一行留着 + 给可读原因（不假装成功）', (tester) async {
    final fake = _FakeToView(
      items: [_item(aid: 33, title: '删不掉的')],
      removeError: const BiliApiException(
        code: -412,
        message: '操作被风控拦截',
        path: '/x/v2/history/toview/del',
      ),
    );
    await _pump(tester, fake);

    await tester.tap(find.byKey(const ValueKey('watch-later-remove-33')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '移除'));
    await tester.pumpAndSettle();

    expect(find.text('删不掉的'), findsOneWidget, reason: '失败不能把行摘掉');
    expect(find.textContaining('移除失败'), findsOneWidget);
    expect(find.textContaining('风控'), findsOneWidget);
  });

  testWidgets('点行：交给播放入口，带 bvid 与分 P 下标（page=3 → 2）',
      (tester) async {
    final fake = _FakeToView(items: [
      _item(aid: 7, bvid: 'BV1tap', page: 3, videos: 5, title: '第三集'),
    ]);
    WhitelistVideo? got;
    int? gotPage;
    await _pump(
      tester,
      fake,
      openPlayer: (context, video, pageIndex) async {
        got = video;
        gotPage = pageIndex;
      },
    );

    await tester.tap(find.text('第三集'));
    await tester.pumpAndSettle();
    expect(got, isNotNull);
    expect(got!.bvid, 'BV1tap');
    expect(got!.cid, 111);
    expect(gotPage, 2, reason: 'page 是 1 基 → 0 起下标 2');
  });

  testWidgets('写操作总开关关着：没有移除入口，并说明"只能查看"', (tester) async {
    UiPrefsStore.instance
        .resetForTest(writeActionsEnabled: false, loaded: true);
    final fake = _FakeToView(items: [_item(aid: 44, title: '只读的')]);
    await _pump(tester, fake);

    expect(find.text('只读的'), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-later-remove-44')), findsNothing);
    expect(find.textContaining('写操作已关闭'), findsOneWidget);
  });

  testWidgets('写操作总开关开着：移除入口在', (tester) async {
    final fake = _FakeToView(items: [_item(aid: 44, title: '可写的')]);
    await _pump(tester, fake);
    expect(find.byKey(const ValueKey('watch-later-remove-44')), findsOneWidget);
    expect(find.textContaining('写操作已关闭'), findsNothing);
  });

  testWidgets('服务端说 count 比拿到的多：头部照实说"只拿到 N 条"',
      (tester) async {
    final fake = _FakeToView(items: [_item(aid: 1), _item(aid: 2, bvid: 'BV1x')]);
    fake.data = {
      'count': 100,
      'list': [_item(aid: 1), _item(aid: 2, bvid: 'BV1x')],
    };
    await _pump(tester, fake);
    expect(find.textContaining('共 100 条'), findsOneWidget);
    expect(find.textContaining('只拿到 2 条'), findsOneWidget);
  });
}
