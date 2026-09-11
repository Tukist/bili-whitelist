// 搜索页两张「视频卡」的发布日期与长标题展开测试：
// - 视频搜索结果（B 站 Tab）：副信息行 = `播放量 播放 · yyyy-MM-dd`
//   （pubDate ≤ 0 = 接口没给 → 只留播放量，不留悬空分隔符）
// - 「我的白名单」Tab：副信息行 = `时长 · UP主 · yyyy-MM-dd`
//   （pubdate 为空 → 无日期段，与 VideoTile 的旧数据形态一致）
// - 长标题（超 2 行）→ 出现「展开」入口；短标题 → 无入口（点按照旧进播放）
//
// 注入假 BiliApi / 假同步服务（不触网络与原生插件）；封面全空串 →
// CoverImage 走本地占位。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/search_result.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/search_page.dart';
import 'package:bili_whitelist_app/services/search_history_store.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 与模型 formatPubdate 同语义的本地日期推导（跨时区机器测试稳定）。
String _dateText(int sec) {
  final dt = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

const int _kPubdate = 1682899200; // 2023-05-01T00:00:00Z

/// 超长标题：测试字体下（每字符宽 = fontSize = 14）远超 2 行。
final String _longTitle = '很长的视频标题' * 30;

/// 假 B 站接口：视频搜索结果固定两条（一条带发布日期、一条脏数据 pubDate=0）。
class _FakeApi extends BiliApi {
  _FakeApi({this.longTitle = false});

  /// true → 结果标题换成超长标题（验证「展开」入口）。
  final bool longTitle;

  @override
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async =>
      SearchPageResult(
        results: [
          SearchResult(
            bvid: 'BV1a',
            title: longTitle ? _longTitle : '搜索结果视频',
            cover: '',
            author: '结果UP主',
            durationSec: 285, // 4:45
            playCount: 12345,
            pubDate: _kPubdate,
          ),
          const SearchResult(
            bvid: 'BV2b',
            title: '没有发布日期的结果',
            cover: '',
            author: '结果UP主',
            durationSec: 60,
            playCount: 7,
            pubDate: 0, // 脏数据：接口没给
          ),
        ],
        totalCount: 2,
        hasMore: false,
      );

  @override
  Future<MediaSearchPageResult> searchMedia(
    String keyword, {
    required String searchType,
    int page = 1,
  }) async =>
      const MediaSearchPageResult(results: [], totalCount: 0, hasMore: false);

  @override
  Future<SearchUpownerResult> searchUpowner(
    String keyword, {
    int page = 1,
  }) async =>
      const SearchUpownerResult(upowners: [], totalCount: 0, hasMore: false);
}

/// 假同步服务：白名单里两条视频（一条带 pubdate、一条旧数据）。
class _FakeSyncService extends WhitelistSyncService {
  _FakeSyncService({this.longTitle = false}) : super();

  final bool longTitle;

  @override
  Future<SyncResult> sync() async => SyncResult(
        data: WhitelistData(
          version: WhitelistData.currentVersion,
          updatedAt: '2026-09-09T00:00:00Z',
          videos: [
            WhitelistVideo(
              bvid: 'BV1a',
              cid: 1,
              title: longTitle ? _longTitle : '白名单视频',
              cover: '',
              duration: 90, // 1:30
              upName: 'UP主',
              addedAt: '2026-08-01T00:00:00Z',
              pubdate: _kPubdate,
            ),
            const WhitelistVideo(
              bvid: 'BV2b',
              cid: 2,
              title: '白名单旧数据',
              cover: '',
              duration: 60, // 1:00
              upName: 'UP主',
              addedAt: '2026-08-02T00:00:00Z',
            ),
          ],
        ),
        sourceName: 'fake',
        fetchedAt: DateTime(2026, 9, 9),
        fromNetwork: false,
      );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

Future<void> _pump(
  WidgetTester tester, {
  bool longTitle = false,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: SearchPage(
      syncService: _FakeSyncService(longTitle: longTitle),
      historyStore: SearchHistoryStore(),
      api: _FakeApi(longTitle: longTitle),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('视频搜索结果卡：发布日期', () {
    testWidgets('副信息行 = 播放量 播放 · yyyy-MM-dd；pubDate=0 → 只留播放量',
        (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField).first, '测试');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700)); // 防抖到期 → 搜索
      await tester.pumpAndSettle();

      expect(find.text('1.2万 播放 · ${_dateText(_kPubdate)}'), findsOneWidget);
      expect(find.text('7 播放'), findsOneWidget,
          reason: '没日期时不出现悬空的「 · 」');
    });
  });

  group('「我的白名单」Tab：发布日期', () {
    testWidgets('副信息行 = 时长 · UP主 · yyyy-MM-dd；无 pubdate → 无日期段',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('我的白名单'));
      await tester.pumpAndSettle();

      expect(find.text('1:30 · UP主 · ${_dateText(_kPubdate)}'), findsOneWidget);
      expect(find.text('1:00 · UP主'), findsOneWidget,
          reason: '旧数据（pubdate 为空）与 VideoTile 的旧数据形态一致');
    });
  });

  group('长标题 → 展开入口', () {
    testWidgets('视频搜索结果：短标题没有「展开」入口', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField).first, '测试');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(find.text('搜索结果视频'), findsOneWidget);
      expect(find.text('展开'), findsNothing);
    });

    testWidgets('视频搜索结果：长标题 → 「展开」→ 全文 + 「收起」', (tester) async {
      await _pump(tester, longTitle: true);
      await tester.enterText(find.byType(TextField).first, '测试');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(find.text('展开'), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, 2);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, isNull);
    });

    testWidgets('白名单 Tab：短标题没有「展开」入口', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('我的白名单'));
      await tester.pumpAndSettle();

      expect(find.text('白名单视频'), findsOneWidget);
      expect(find.text('展开'), findsNothing);
    });

    testWidgets('白名单 Tab：长标题 → 「展开」→ 全文 + 「收起」', (tester) async {
      await _pump(tester, longTitle: true);
      await tester.tap(find.text('我的白名单'));
      await tester.pumpAndSettle();

      expect(find.text('展开'), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, 2);
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, isNull);
    });
  });
}
