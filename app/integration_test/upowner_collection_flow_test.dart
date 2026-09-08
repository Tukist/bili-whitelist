// UP 主主页「合集/列表」区集成测试（v2.17.4+，模拟器/真机运行，真实网络）：
//   flutter test integration_test/upowner_collection_flow_test.dart -d emulator-5554
//
// 覆盖（真实 B 站 seasons_series_list / seasons_archives_list 接口）：
//   1. 有合集的 UP 主（摄影师云飞 mid=17519822，实测 20 个合集）：
//      进入页面 → 出现「合集」区（区头 + 「全部视频」chip + 合集 chips）
//   2. 点第一个合集 chip → fetchSeasonArchives 拉取 → 合集视频列表出现
//      （列表行非空；搜索框/排序 chips 隐藏——合集视图独立）
//   3. 返回「全部视频」→ 主列表与排序 chips 恢复
//
// 说明：真实网络受风控影响（本机匿名 acc/info 偶发 -352 限流，合集/合集视频
// 接口实测可用）；超时等待内置打印，风控时看日志判定，勿误判回归。
// pumpAndSettle 会被网络加载/转圈卡死 → 一律显式 pump 轮询。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:bili_whitelist_app/pages/upowner_page.dart';

/// 有合集的真实 UP 主：摄影师云飞（串流教程 UP，实测 seasons=20）。
const int _mid = 17519822;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> waitFor(
    WidgetTester tester,
    Finder finder, {
    int seconds = 15,
  }) async {
    var found = false;
    for (var i = 0; i < seconds * 5 && !found; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      found = finder.evaluate().isNotEmpty;
    }
    return found;
  }

  testWidgets('有合集 UP 主：合集区出现 → 点合集看视频列表 → 返回全部视频',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: UpownerPage(mid: _mid)),
    );

    // 1) 合集区出现：区头「合集」+「全部视频」chip + ≥1 个「合集·」chips
    final section = await waitFor(tester, find.text('合集'));
    expect(section, isTrue,
        reason: '合集区未出现？日志应见 fetchUpownerCollections（网络/风控）');
    expect(find.text('全部视频'), findsOneWidget);
    expect(find.textContaining('合集·'), findsWidgets,
        reason: '应至少有一个合集 chip（名带「合集·」前缀）');
    final firstSeasonChip = find.textContaining('合集·').first;
    final chipLabel = (tester.widget<Text>(firstSeasonChip)).data!;

    // 进入合集前：主列表排序 chips（最新发布）可见
    expect(find.text('最新发布'), findsOneWidget);

    // 2) 点第一个合集 chip → 合集视频列表出现（搜索/排序隐藏，列表独立）
    await tester.tap(firstSeasonChip);
    var rows = 0;
    for (var i = 0; i < 15 * 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      rows = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .length;
      if (rows > 0) break;
    }
    debugPrint('[集成] 合集「$chipLabel」视频列表行数=$rows');
    expect(rows, greaterThan(0),
        reason: '合集视频列表为空？日志应见 fetchSeasonArchives（网络/风控）');
    // 合集视图独立：搜索框（TextField）与排序 chips 不显示
    expect(find.byType(TextField), findsNothing);
    expect(find.text('最新发布'), findsNothing);

    // 3) 点「全部视频」→ 主列表与排序 chips 恢复
    await tester.tap(find.text('全部视频'));
    final restored = await waitFor(tester, find.text('最新发布'), seconds: 8);
    expect(restored, isTrue, reason: '切回全部视频后排序 chips 未恢复');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextField), findsOneWidget);
    final mainRows = tester.widgetList<ListTile>(find.byType(ListTile)).length;
    debugPrint('[集成] 切回「全部视频」主列表行数=$mainRows');
    expect(mainRows, greaterThan(0));
  });
}
