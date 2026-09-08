// 「导入我关注的 UP」流程 widget 测试（v2.17.12+）：
// - runFollowingsImportFlow 门禁：未配置 → 提示配置（不发登录/不发请求）；
//   未登录 → 提示 + 引导登录；openLogin 仍失败 → 中止
// - 勾选页：列表展示/总数提示/全选 → 批量加入白名单（查重跳过）→
//   「已添加 X，跳过 Y」汇总；Gist + 本地缓存写入；返回后 onDone 刷新
// - 翻页：加载更多追加下一页；翻完显示「已加载全部关注」
// 不访问真实网络（BiliApi/GithubApi 均为内存实现）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/followings_import_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存 BiliApi：关注列表 45 位（page1: 1..20 / page2: 21..40 / page3: 41..45）；
/// readSessdata 可切换登录态。
class _MemoryBiliApi extends BiliApi {
  bool loggedIn;

  _MemoryBiliApi({this.loggedIn = true})
    : super(dio: Dio(BaseOptions(baseUrl: kBiliApi)));

  @override
  Future<String?> readSessdata() async => loggedIn ? 'sessdata-ok' : null;

  @override
  Future<FollowingsPage> fetchFollowingsOfMine({
    int pn = 1,
    int ps = 20,
  }) async {
    const total = 45;
    final list = <Upowner>[
      for (var i = (pn - 1) * ps + 1; i <= pn * ps && i <= total; i++)
        Upowner(
          mid: i,
          name: '关注UP$i',
          face: '',
          addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
    ];
    return FollowingsPage(
      upowners: list,
      totalCount: total,
      hasMore: pn * ps < total,
    );
  }
}

/// 内存 GithubApi：记录 Gist 内容与写次数。
class _MemoryGithubApi extends GithubApi {
  WhitelistData? stored;
  int saveCount = 0;
  bool configured;

  _MemoryGithubApi({WhitelistData? initial, this.configured = true})
    : stored = initial;

  @override
  Future<bool> hasConfig() async => configured;

  @override
  Future<WhitelistData?> fetchFromGist() async => stored;

  @override
  Future<bool> saveToGist(WhitelistData wl) async {
    stored = wl;
    saveCount++;
    return true;
  }
}

class _RecordingSyncService extends WhitelistSyncService {
  final List<WhitelistData> cached = [];

  @override
  Future<void> saveToCache(WhitelistData data) async {
    cached.add(data);
  }
}

Upowner _up(int mid, String name) => Upowner(
      mid: mid,
      name: name,
      face: '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

/// 宿主：按钮拉起 runFollowingsImportFlow，记录 onDone/openLogin 调用。
class _Host extends StatelessWidget {
  final UpownerWriter writer;
  final Future<bool> Function() openLogin;
  final Future<void> Function() onDone;
  final String configHint;

  const _Host({
    required this.writer,
    required this.openLogin,
    required this.onDone,
    required this.configHint,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => runFollowingsImportFlow(
              context: ctx,
              writer: writer,
              configHint: configHint,
              openLogin: openLogin,
              onDone: onDone,
            ),
            child: const Text('开始导入'),
          ),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingSyncService sync;

  setUp(() {
    sync = _RecordingSyncService();
    ServiceLocator.overrideSyncService(sync);
  });

  Future<void> tapStart(WidgetTester tester) async {
    await tester.tap(find.text('开始导入'));
    await tester.pumpAndSettle();
  }

  testWidgets('配置门禁：未配置 → snack 提示，不引导登录、不推页面', (tester) async {
    var loginCalled = false;
    final writer = UpownerWriter(
      github: _MemoryGithubApi(configured: false),
      api: _MemoryBiliApi(loggedIn: false),
    );
    await tester.pumpWidget(MaterialApp(
      home: _Host(
        writer: writer,
        openLogin: () async {
          loginCalled = true;
          return false;
        },
        onDone: () async {},
        configHint: '请先配置 GitHub token 与 Gist ID',
      ),
    ));
    await tapStart(tester);

    expect(find.text('请先配置 GitHub token 与 Gist ID'), findsOneWidget);
    expect(loginCalled, isFalse);
    expect(find.byType(FollowingsImportPage), findsNothing);
  });

  testWidgets('登录门禁：未登录 → 提示 + 引导登录；仍失败则中止', (tester) async {
    var loginCalled = 0;
    final writer = UpownerWriter(
      github: _MemoryGithubApi(),
      api: _MemoryBiliApi(loggedIn: false),
    );
    await tester.pumpWidget(MaterialApp(
      home: _Host(
        writer: writer,
        openLogin: () async {
          loginCalled++;
          return false; // 用户没登录就返回
        },
        onDone: () async {},
        configHint: '请先配置',
      ),
    ));
    await tapStart(tester);

    expect(find.textContaining('需要登录 B 站账号'), findsOneWidget);
    expect(loginCalled, 1);
    expect(find.byType(FollowingsImportPage), findsNothing);
  });

  testWidgets('全选 → 批量加入：已添加/跳过汇总 + Gist/缓存写入 + onDone', (tester) async {
    // 白名单已有 mid=3 → 选中集合自动排除该位（skipped=1）
    final github = _MemoryGithubApi(
      initial: WhitelistData.empty().copyWith(upowners: [_up(3, '关注UP3')]),
    );
    final writer = UpownerWriter(
      github: github,
      api: _MemoryBiliApi(loggedIn: true),
    );
    var onDoneCount = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Host(
        writer: writer,
        openLogin: () async => true,
        onDone: () async { onDoneCount++; },
        configHint: '请先配置',
      ),
    ));
    await tapStart(tester);

    // 页面出现：总数提示 + 已关注标（mid=3 行不可勾选）
    expect(find.textContaining('B 站关注共 45 位'), findsOneWidget);
    expect(find.text('关注UP3'), findsOneWidget);

    // 全选：可勾选 19 位（20 - 1 已关注）
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('加入白名单（19）'), findsOneWidget);

    await tester.tap(find.text('加入白名单（19）'));
    await tester.pumpAndSettle();

    // 汇总提示 + Gist 落库（1..20 已关注；mid3 进页即标「已关注」未参与勾选）
    expect(find.text('已添加 19 个'), findsOneWidget);
    expect(github.saveCount, 1, reason: '批量只写一次 Gist');
    expect(github.stored!.upowners.map((u) => u.mid).toSet(),
        Set.from(List.generate(20, (i) => i + 1)));
    expect(sync.cached.last.upowners.length, 20);

    // 返回 → pop(true) → onDone（上层刷新白名单）
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(onDoneCount, 1);
  });

  testWidgets('翻页加载更多：追加下一页，翻完显示「已加载全部关注」', (tester) async {
    final writer = UpownerWriter(
      github: _MemoryGithubApi(),
      api: _MemoryBiliApi(loggedIn: true),
    );
    await tester.pumpWidget(MaterialApp(
      home: _Host(
        writer: writer,
        openLogin: () async => true,
        onDone: () async {},
        configHint: '请先配置',
      ),
    ));
    await tapStart(tester);

    expect(find.textContaining('已加载 20'), findsOneWidget);

    // 翻第 2 页
    await tester.scrollUntilVisible(find.textContaining('加载更多'), 300);
    await tester.tap(find.textContaining('加载更多').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('已加载 40'), findsOneWidget);

    // 翻第 3 页（到 45，已无更多）
    await tester.scrollUntilVisible(find.textContaining('加载更多'), 300);
    await tester.tap(find.textContaining('加载更多').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('已加载全部关注'), 300);
    expect(find.textContaining('已加载 45'), findsOneWidget);
    expect(find.textContaining('加载更多'), findsNothing);
  });
}
