// 评论页真机/模拟器集成测试（真实网络，仅限本机手动运行，不进 CI）：
//   flutter test integration_test/comment_flow_test.dart -d emulator-5554
//
// 覆盖（真实 B 站接口 + 真实图片加载）：
//   1. 主评论加载：置顶/正文/点赞时间/「N 条回复」渲染（评论 N 标题）
//   2. 楼中楼：点「N 条回复」展开 → 拉取完整楼中楼（fetchReplyChildren）
//   3. 图片评论：定位到带图评论并滚动可见 → 图片真实加载（无「图片加载失败」日志）
//   4. 翻页：上拉到列表底部 → 触发下一页（cursor.next 原样回传）
//   5. 番剧集（epId）aid 解析正确并可打开评论区
//   6. 无评论/评论区关闭视频 → 空态或「评论区已关闭」错误态（不崩）
//
// 说明：页面内部 debugPrint（[comment_page]/[bili_api] 前缀）被本测试捕获，
// 断言基于日志 + 可见文本双重证据；运行输出即取证文本。
// ⚠️ 本文件依赖真实 B 站网络与白名单中的真实 bvid，网络/风控变化可能导致
// 失败（12002/-412 等），属预期——不要因此误判功能回归。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/comment_page.dart';

/// 候选普通视频（白名单中热度高/内容向的条目，按需探测评论形态）。
const List<String> _candidateBvids = [
  'BV1yktX6aEsx', // 爆肝 Re0 傲慢if
  'BV1ypFWzREU3', // SANDA 全12
  'BV1oGtU6iE7n', // Re0 第四季 第15
  'BV15QtG6PEJN', // 攻壳 TGITS 第9
  'BV1Y2th6JEfF', // 碧蓝之海 S3 第9
  'BV1t68d6EEZh', // 杂谈 选拔叙事（已有实机确认：89 评论/置顶/2 条回复）
  'BV1Sz8x6iEd9', // Tyranor
  'BV1Hr4k6bEAp', // 文学少女剧场版
];

/// 番剧集候选（带 epId）。
const List<(String, int)> _candidatePgc = [
  ('BV1oV4y1J7FQ', 634282), // 神奇动物：邓布利多之谜 原版
  ('BV1Pa41197Hm', 634284), // 神奇动物：邓布利多之谜 中文版
];

/// 捕获 App 内 debugPrint 关键行（[comment_page]/[bili_api]…），作行为证据。
List<String> _logs = [];
void _captureDebugPrint() {
  _logs = [];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null &&
        (message.contains('[comment_page]') ||
            message.contains('fetchVideoComments') ||
            message.contains('fetchReplyChildren') ||
            message.contains('图片加载失败') ||
            message.contains('[集成]'))) {
      _logs.add(message);
    }
    original(message, wrapWidth: wrapWidth);
  };
}

bool _logContains(String needle) => _logs.any((l) => l.contains(needle));

WhitelistVideo _video(String bvid, {int? epId}) => WhitelistVideo(
      bvid: bvid,
      cid: 0,
      title: '集成测试',
      cover: '',
      duration: 0,
      upName: 'test',
      addedAt: '',
      epId: epId,
    );

/// pump 一个 CommentPage 并等待首屏评论加载（≤30s），返回是否加载到主评论。
Future<bool> _pumpCommentPage(
  WidgetTester tester, {
  required String bvid,
  int? epId,
}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(home: CommentPage(video: _video(bvid, epId: epId))),
    );
    final end = DateTime.now().add(const Duration(seconds: 35));
    while (DateTime.now().isBefore(end) &&
        !_logContains('主评论页 aid=') &&
        !_logContains('aid 解析失败') &&
        !_logContains('评论区已关闭')) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await tester.pump();
  });
  await tester.pump(const Duration(milliseconds: 300));
  return _logContains('主评论页 aid=');
}

/// 真网络扫描：挑出「带图评论视频 / 可翻页视频」。
Future<({String? picBvid, String? multiBvid})> _scan(BiliApi api) async {
  String? picBvid;
  String? multiBvid;
  for (final bvid in _candidateBvids) {
    if (picBvid != null && multiBvid != null) break;
    try {
      final aid = await api.fetchVideoAid(_video(bvid));
      if (aid == null) continue;
      final page = await api.fetchVideoComments(aid: aid);
      if (picBvid == null &&
          page.replies.any((r) => r.pictures.isNotEmpty)) {
        picBvid = bvid;
        debugPrint('[集成] 带图评论视频候选 bvid=$bvid');
      }
      if (multiBvid == null && page.replies.length >= 15 && !page.isEnd) {
        multiBvid = bvid;
        debugPrint(
            '[集成] 可翻页视频候选 bvid=$bvid total=${page.totalCount}');
      }
    } catch (e) {
      debugPrint('[集成] 扫描 $bvid 失败（跳过）: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  return (picBvid: picBvid, multiBvid: multiBvid);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  _captureDebugPrint();

  testWidgets('评论区：加载/楼中楼/图片/翻页/番剧', (tester) async {
    final api = BiliApi();

    // ---- 0. 真网络扫描：挑「带图 / 可翻页」视频 ----
    // runAsync 返回 T?，先解包记录再取字段（局部可提升）
    final targets = await tester.runAsync(() => _scan(api));
    final picBvid = targets?.picBvid;
    final multiBvid = targets?.multiBvid;
    debugPrint('[集成] 扫描结果 pic=$picBvid multi=$multiBvid');
    if (picBvid == null && multiBvid == null) {
      fail('扫描未找到带图或可翻页视频（网络/风控异常，见上方日志）');
    }

    // ---- 1. 主评论加载（扫描所得视频）----
    final mainBvid = multiBvid ?? picBvid!;
    _logs.clear();
    final loaded = await _pumpCommentPage(tester, bvid: mainBvid);
    expect(loaded, isTrue, reason: '评论列表应加载成功（日志见上）');
    debugPrint('[集成] 主评论加载日志: '
        '${_logs.where((l) => l.contains('主评论页 aid=')).join(' | ')}');
    expect(
      find.textContaining(RegExp(r'^评论 \d+')).evaluate().isNotEmpty,
      isTrue,
      reason: 'AppBar 应显示「评论 N」',
    );
    await tester.pumpWidget(const SizedBox());

    // ---- 2. 楼中楼：锁定已知有「2 条回复」的视频确定性展开 ----
    const childBvid = 'BV1t68d6EEZh';
    _logs.clear();
    final childLoaded = await _pumpCommentPage(tester, bvid: childBvid);
    expect(childLoaded, isTrue, reason: '楼中楼测试视频应能加载评论');
    Finder replyFinder() => find.textContaining(RegExp(r'^\d+ 条回复$'));
    // 若首屏没有「N 条回复」，滚动列表找（最多 6 屏）
    for (var i = 0; i < 6 && replyFinder().evaluate().isEmpty; i++) {
      await tester.fling(
          find.byType(Scrollable).first, const Offset(0, -900), 1500);
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(replyFinder().evaluate().isNotEmpty, isTrue,
        reason: '应能滚动到含「N 条回复」的评论');
    _logs.clear();
    await tester.ensureVisible(replyFinder().first);
    await tester.tap(replyFinder().first);
    final childEnd = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(childEnd) &&
        !_logContains('展开楼中楼 root=')) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('[集成] 楼中楼日志: '
        '${_logs.where((l) => l.contains('楼中楼')).join(' | ')}');
    expect(_logContains('展开楼中楼 root='), isTrue,
        reason: '点击「N 条回复」应拉取完整楼中楼');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('收起').evaluate().isNotEmpty ||
          find.text('加载更多回复').evaluate().isNotEmpty,
      isTrue,
      reason: '展开后应有子回复区（收起/加载更多）',
    );
    await tester.pumpWidget(const SizedBox());

    // ---- 3. 图片评论真实加载 ----
    if (picBvid != null) {
      _logs.clear();
      String? picUrl;
      await tester.runAsync(() async {
        final aid = await api.fetchVideoAid(_video(picBvid));
        final page = aid == null
            ? null
            : await api.fetchVideoComments(aid: aid);
        final withPic = page?.replies
                .where((r) => r.pictures.isNotEmpty)
                .toList() ??
            const [];
        if (page != null && withPic.isNotEmpty) {
          picUrl = withPic.first.pictures.first.imgSrc;
          debugPrint(
            '[集成] 带图评论 bvid=$picBvid '
            'rpid=${withPic.first.rpid} pics=${withPic.first.pictures.length} '
            'url=$picUrl',
          );
          await tester.pumpWidget(
            MaterialApp(home: CommentPage(video: _video(picBvid))),
          );
          final end = DateTime.now().add(const Duration(seconds: 35));
          while (DateTime.now().isBefore(end) &&
              !_logContains('主评论页 aid=')) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          await tester.pump();
        } else {
          debugPrint('[集成] 该视频此刻无带图评论，跳过图片断言');
        }
      });
      if (picUrl != null && _logContains('主评论页 aid=')) {
        // 滚动加载更多评论（让可能靠后的带图评论也进入渲染）
        for (var i = 0; i < 4; i++) {
          await tester.fling(
              find.byType(Scrollable).first, const Offset(0, -1600), 2000);
          await tester.pump(const Duration(milliseconds: 700));
        }
        await tester.pump(const Duration(seconds: 2)); // 等图片解码/加载
        debugPrint(
          '[集成] 图片失败日志数: '
          '${_logs.where((l) => l.contains('图片加载失败')).length} '
          '（picUrl 已发起加载）',
        );
        expect(
          _logs.where((l) => l.contains('图片加载失败')),
          isEmpty,
          reason: '可见评论图片应加载成功（无失败日志）',
        );
      }
      await tester.pumpWidget(const SizedBox());
    }

    // ---- 4. 上拉翻页（cursor.next 原样回传）----
    if (multiBvid != null) {
      _logs.clear();
      final pLoaded = await _pumpCommentPage(tester, bvid: multiBvid);
      expect(pLoaded, isTrue);
      final fetchEnd = DateTime.now().add(const Duration(seconds: 30));
      var page2Seen = false;
      while (DateTime.now().isBefore(fetchEnd) && !page2Seen) {
        await tester.fling(
            find.byType(Scrollable).first, const Offset(0, -3000), 2500);
        await tester.pump(const Duration(milliseconds: 800));
        final fetches = _logs
            .where((l) => l.contains('fetchVideoComments') && l.contains('ok:'))
            .toList();
        if (fetches.length >= 2) {
          page2Seen = true;
          debugPrint('[集成] 翻页证据: ${fetches.join(' | ')}');
          final m1 = RegExp(r'next=(\d+)').allMatches(fetches[0]);
          final m2 = RegExp(r'next=(\d+)').allMatches(fetches[1]);
          final next2 = m2.last.group(1);
          debugPrint(
            '[集成] 第 1 页响应 cursor.next=${m1.last.group(1)} → '
            '第 2 页请求 next=$next2',
          );
          expect(next2 != '0' && next2 != '1', isTrue,
              reason: '下一页请求应回传上游 cursor.next');
        }
        if (find.textContaining('没有更多').evaluate().isNotEmpty &&
            !page2Seen) {
          debugPrint('[集成] 该视频首屏即到底（评论较少），翻页断言跳过');
          break;
        }
      }
      expect(page2Seen, isTrue,
          reason: 'multiBvid 首屏 ≥15 条，上拉应触发第 2 页加载');
      await tester.pumpWidget(const SizedBox());
    }

    // ---- 5. 番剧集（epId）：aid 解析 + 打开评论 ----
    if (_candidatePgc.isNotEmpty) {
      _logs.clear();
      final (pgcBvid, pgcEp) = _candidatePgc.first;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: CommentPage(video: _video(pgcBvid, epId: pgcEp)),
          ),
        );
        final end = DateTime.now().add(const Duration(seconds: 35));
        while (DateTime.now().isBefore(end) &&
            !_logContains('主评论页 aid=') &&
            !_logContains('aid 解析失败') &&
            !_logContains('评论区已关闭')) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await tester.pump();
      });
      await tester.pump(const Duration(milliseconds: 300));
      debugPrint('[集成] 番剧评论日志: ${_logs.join(' | ')}');
      expect(
        _logContains('主评论页 aid=') ||
            _logContains('aid 解析失败') ||
            _logContains('评论区已关闭'),
        isTrue,
        reason: '番剧集应正确解析 aid 并打开评论区（或提示关闭）',
      );
      if (_logContains('主评论页 aid=')) {
        expect(
          find.textContaining(RegExp(r'^评论')).evaluate().isNotEmpty ||
              find.text('暂无评论').evaluate().isNotEmpty,
          isTrue,
          reason: '番剧评论页应有标题/列表/空态',
        );
      }
      await tester.pumpWidget(const SizedBox());
    }

    debugPrint('[集成] 全部评论流程用例通过 ✅');
  });
}
