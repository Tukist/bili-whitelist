// 视频列表项显示发布时间 —— 模拟器真机取证集成测试（真实渲染，仅本机手动运行）：
//   flutter test integration_test/video_tile_pubdate_flow_test.dart -d emulator-5554
//
// 覆盖三个场景（每场景独立 testWidgets + 停留若干秒供宿主机 uiautomator dump；
// debugPrint 打 SHOW1/SHOW2/SHOW3 标记与真实渲染文本，测试 stdout 即文本取证）：
//   1. 含 pubdate 的新数据 + 无 pubdate 旧数据混排 → 合集页列表副信息行 =
//      `时长 · UP主 · yyyy-MM-dd`（无 pubdate 条目不带日期段）
//   2. 纯旧数据（pubdate null / 0）→ 副信息行保持 `时长 · UP主`，不崩
//   3. 番剧：真网络 fetchPgcSeason → videoFromPgcEpisode 构造 → 列表显示
//      pub_time 换算出的日期（2026-09 实测 pub_time 即 Unix 秒，无需毫秒换算）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/collection_page.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';

/// 与 lib 里 formatPubdate 同语义的本地日期推导（跨时区稳定）。
String fmtDate(int? sec) {
  if (sec == null || sec <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

WhitelistVideo _video(String bvid, {int? pubdate, int duration = 90}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 1,
      title: '列表项测试 $bvid',
      cover: '',
      duration: duration,
      upName: 'UP主',
      addedAt: '2026-01-01T00:00:00Z',
      pubdate: pubdate,
    );

/// pump 一个未分类 CollectionPage（白名单全量列表入口，真实渲染 VideoTile）。
Future<void> _pumpCollection(WidgetTester tester, List<WhitelistVideo> videos) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CollectionPage(
        collectionName: '',
        data: WhitelistData(
          version: 4,
          updatedAt: '2026-09-01T00:00:00Z',
          videos: videos,
        ),
        saveAndRefresh: (_) async {},
      ),
    ),
  );
  // 等首帧 + 缓存角标初始化稳定
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 停留在当前画面 [sec] 秒（供宿主机 uiautomator dump / stdout 取证）。
Future<void> _hold(WidgetTester tester, int sec) async {
  final end = DateTime.now().add(Duration(seconds: sec));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SHOW1 新数据（pubdate）显示发布时间 / 旧数据不带日期段',
      (tester) async {
    final pubdateA = 1682899200; // 2023-05-01T00:00:00Z（东八区显示 2023-05-01）
    final pubdateC = 1484067600;
    await _pumpCollection(tester, [
      _video('BV1', pubdate: pubdateA),
      _video('BV2'), // 旧数据：无 pubdate
      _video('BV3', pubdate: pubdateC),
    ]);
    final dateA = fmtDate(pubdateA);
    final dateC = fmtDate(pubdateC);
    debugPrint('[集成] SHOW1 断言前：pubdateA=$pubdateA dateA=$dateA；'
        'pubdateC=$pubdateC dateC=$dateC');
    expect(find.text('1:30 · UP主 · $dateA'), findsOneWidget,
        reason: 'A 应显示发布时间');
    expect(find.text('1:30 · UP主 · $dateC'), findsOneWidget);
    expect(find.text('1:30 · UP主'), findsOneWidget,
        reason: '旧数据 B 不带日期段');
    expect(find.text('列表项测试 BV1'), findsOneWidget);
    debugPrint('[集成] SHOW1 断言通过（日期段与非日期段文案均已真实渲染）');
    debugPrint('[集成] ===== debugDumpRenderTree 开始 =====');
    debugDumpRenderTree();
    debugPrint('[集成] ===== debugDumpRenderTree 结束 =====');
    await _hold(tester, 10);
  });

  testWidgets('SHOW2 纯旧数据（pubdate null / 0）不显示日期、不崩', (tester) async {
    await _pumpCollection(tester, [
      _video('BVold1'),
      _video('BVold2', pubdate: 0), // 脏值 0 与 null 同处理
    ]);
    debugPrint('[集成] SHOW2 断言前：两条旧数据均已 pump');
    expect(find.text('1:30 · UP主'), findsWidgets, reason: '旧数据仍显示时长·UP主');
    expect(
      find.textContaining(RegExp(r'· \d{4}-\d{2}-\d{2}')),
      findsNothing,
      reason: '无 pubdate 不显示日期段',
    );
    expect(tester.takeException(), isNull);
    debugPrint('[集成] SHOW2 断言通过（无日期段、无异常）');
    debugPrint('[集成] ===== debugDumpRenderTree 开始 =====');
    debugDumpRenderTree();
    debugPrint('[集成] ===== debugDumpRenderTree 结束 =====');
    await _hold(tester, 10);
  });

  testWidgets('SHOW3 番剧真接口 pub_time（秒）→ videoFromPgcEpisode → 显示日期',
      (tester) async {
    String pgcEvidence = '';
    try {
      final api = BiliApi();
      final season =
          await api.fetchPgcSeason(seasonId: 5797); // Hand Shakers（12 集周播）
      final eps = season.episodes.take(3).toList();
      final videos = [
        for (final ep in eps) WhitelistWriter.videoFromPgcEpisode(season, ep),
      ];
      pgcEvidence =
          'season=${season.title} eps=${eps.map((e) => e.pubTimeSec).toList()}';
      debugPrint('[集成] SHOW3 $pgcEvidence');
      await _pumpCollection(tester, videos);
      for (final v in videos) {
        final date = fmtDate(v.pubdate);
        pgcEvidence = '$pgcEvidence | ${v.bvid} pubdate=${v.pubdate} date=$date';
        expect(date.isNotEmpty, isTrue,
            reason: '番剧 pub_time 应解析出有效日期（${v.bvid}）');
        expect(find.textContaining('· $date'), findsWidgets,
            reason: '${v.bvid} 列表应显示发布时间 $date');
      }
      debugPrint('[集成] SHOW3 断言通过（番剧 pub_time 秒级 → 列表显示日期）');
      debugPrint('[集成] ===== debugDumpRenderTree 开始 =====');
      debugDumpRenderTree();
      debugPrint('[集成] ===== debugDumpRenderTree 结束 =====');
    } catch (e) {
      pgcEvidence = 'fetchPgcSeason 异常: $e';
      debugPrint('[集成] $pgcEvidence');
      rethrow;
    } finally {
      debugPrint('[集成] PGC_EVIDENCE $pgcEvidence');
    }
    await _hold(tester, 10);
  });
}
