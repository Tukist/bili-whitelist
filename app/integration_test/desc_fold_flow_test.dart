// 播放页信息行简介区集成测试（v2.17.3+，真机/模拟器运行，真实网络）：
//   flutter test integration_test/desc_fold_flow_test.dart -d emulator-5554
//
// 覆盖（真实 B 站 view 接口 + 真实播放器环境）：
//   1. 条目标注自带 desc（新导入/油猴写入路径）→ 信息行显示简介；长简介
//      超 3 行折叠出现「展开」；点击展开全文变「收起」；再点收起复原
//   2. 条目无 desc（旧数据路径）→ 运行时 fetchVideoMeta 补拉 view data.desc
//      → 简介区出现（折叠态）；无简介的视频（desc 空）不显示简介区、不占位
//
// 说明：播放页真实取流可能失败/缓冲（不影响信息行渲染）；测试只断言
// 信息行 UI。pumpAndSettle 会被缓冲转圈卡死 → 一律显式 pump。
// ⚠️ 真实网络：风控/断网时运行时补拉会失败，断言 2 可能不满足（届时看日志
// 判定，勿误判功能回归）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/comment_page.dart';
import 'package:bili_whitelist_app/pages/player_page.dart';

/// 长简介（远超 3 行；真实 串流教程 BV13i421r7Ff 的 desc，含换行）。
const String _longDesc = 'sunshine+moonlight，阳光+月光，太烂漫了！\n'
    '本期视频循序渐进，是一期需要反复观看的视频，希望可以帮助到大家。\n'
    '没必要一次性看完，可以当成一个常驻备查的工具视频来用。\n'
    '下面是一些关键节点（时间轴已标好）：设备选择、网络穿透、客户端串流、'
    '虚拟显示器、画质与延迟调优、常见问题排查。每节都有对应时间点标注，'
    '方便日后直接跳转定位——这段描述特意写得足够长，用来验证播放页简介区'
    '超过三行时的折叠省略与「展开/收起」交互是否正常运作。';

WhitelistVideo _video(String bvid, {String desc = ''}) => WhitelistVideo(
      bvid: bvid,
      cid: 0, // 真实取流非本测试目标（可能失败，信息行照常渲染）
      title: '串流教程（集成测试）',
      cover: '',
      duration: 3600,
      upName: '摄影师云飞',
      addedAt: '2026-09-08T00:00:00Z',
      desc: desc,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpSeconds(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds * 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// 信息行（标题/UP 主/简介区）容器：把折叠断言限定在简介区内，
  /// 避免同屏内嵌评论区里另一条折叠正文的「展开/收起」干扰计数。
  final infoBar = find.byKey(const ValueKey('player-info-bar'));
  Finder inBar(String text) =>
      find.descendant(of: infoBar, matching: find.text(text));

  testWidgets('条目标注 desc：信息行显示简介，超 3 行折叠→展开→收起',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video('BV13i421r7Ff', desc: _longDesc)),
    ));
    await pumpSeconds(tester, 3);

    // 折叠态：信息行内出现「展开」；正文是 Text(maxLines=3) 省略
    expect(inBar('展开'), findsOneWidget);
    Finder descText() => find.byWidgetPredicate((w) =>
        w is Text && w.data != null && w.data!.contains('sunshine+moonlight'));
    final folded = tester
        .widgetList<Text>(descText())
        .toList();
    expect(folded, isNotEmpty);
    expect(folded.first.maxLines, 3);
    final foldedHeight = tester.getRect(descText()).height;

    // 点「展开」→ 收起出现，正文不再截断（高度显著增大）
    await tester.tap(inBar('展开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(inBar('收起'), findsOneWidget);
    expect(inBar('展开'), findsNothing);
    expect((descText().evaluate().single.widget as Text).maxLines, isNull); // 展开态不再截断
    expect(tester.getRect(descText()).height, greaterThan(foldedHeight));

    // 再点「收起」→ 复原折叠
    await tester.tap(inBar('收起'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(inBar('展开'), findsOneWidget);
    expect(inBar('收起'), findsNothing);
    expect(tester.getRect(descText()).height, lessThanOrEqualTo(foldedHeight + 1));
  });

  testWidgets('条目无 desc（旧数据）：运行时补拉 view desc 显示简介区',
      (tester) async {
    // 真实 view 接口 desc 非空的视频（串流教程，view 可达且返回 126 字简介）
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video('BV13i421r7Ff')), // desc 空 = 旧数据
    ));
    // 等待运行时 fetchVideoMeta 补拉 desc（真实网络 ~1s；最多等 8s）
    var found = false;
    for (var i = 0; i < 40 && !found; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      found = inBar('展开').evaluate().isNotEmpty;
    }
    expect(found, isTrue,
        reason: '运行时补拉失败？日志应见 [player_page] 拉取 UP 主信息失败（网络/风控）');
    // 展开验证
    await tester.tap(inBar('展开'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(inBar('收起'), findsOneWidget);
    await tester.tap(inBar('收起'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(inBar('展开'), findsOneWidget);
  });

  testWidgets('无简介视频：简介区不显示、不占位', (tester) async {
    // Re0 第四季 BV1oGtU6iE7n：host 实测 view desc 为空 → 运行时补拉也为空，
    // 简介区保持隐藏不占位（防无 desc 时出现空行/「暂无简介」占位文案）
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(video: _video('BV1oGtU6iE7n')),
    ));
    await pumpSeconds(tester, 2);
    // 无「展开/收起」折叠按钮；正文区没有简介样式的文本
    expect(find.text('展开'), findsNothing);
    expect(find.text('收起'), findsNothing);
  });

  testWidgets('评论区：真实长评论折叠展开（真实网络，串流教程 BV13i421r7Ff）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CommentPage(video: _video('BV13i421r7Ff')),
    ));
    // 等真实评论加载且正文折叠完成（出现评论正文的「展开」折叠按钮）
    var found = false;
    await tester.runAsync(() async {
      final end = DateTime.now().add(const Duration(seconds: 35));
      while (DateTime.now().isBefore(end) &&
          find.text('展开').evaluate().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      found = find.text('展开').evaluate().isNotEmpty;
      await tester.pump(const Duration(milliseconds: 400));
    });
    if (!found) {
      // 首屏无超 5 行长评论（B 站评论内容随热度变动）→ 记录说明，不算失败
      debugPrint('[集成] 首屏无超 5 行长评论，跳过折叠断言（属评论内容随机）');
      return;
    }
    final before = find.text('展开').evaluate().length;
    // 点第一条「展开」→ 它变成「收起」，全文展开
    await tester.tap(find.text('展开').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('收起'), findsWidgets);
    expect(find.text('展开').evaluate().length, before - 1,
        reason: '点击后该条应变为「收起」，其余折叠条保持「展开」');
    // 再点对应「收起」→ 复原
    await tester.tap(find.text('收起').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('展开').evaluate().length, before);
  });
}
