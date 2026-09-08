// UpownerPage「关注/已关注」按钮 widget 测试（v2.17.12+ 统一文案）：
// - 非白名单 UP 进页 → AppBar「关注」；点击 → UpownerWriter.add 写 Gist +
//   本地缓存 → 按钮变「已关注」+ snack「已关注：xx」
// - 白名单 UP 进页 → 「已关注」；点击 → 取消关注确认弹窗 → 确认 →
//   removeByMid 移除 → 按钮回「关注」
// - 取消关注弹窗「取消」→ 状态不变
// - 未配置 GitHub → 点关注提示配置、状态不变
// - 关注/取关后返回页面 pop(true)；未改动返回 pop(null)
// 不访问真实网络（BiliApi 用内存子类；GithubApi 用内存实现）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存 BiliApi：只覆盖 UP 详情页用到的接口，不访问真实网络。
class _MemoryBiliApi extends BiliApi {
  _MemoryBiliApi() : super(dio: Dio(BaseOptions(baseUrl: kBiliApi)));

  @override
  Future<int> fetchUpownerFollower(int mid) async => 1234;

  @override
  Future<UpownerInfo> fetchUpownerInfo(int mid) async =>
      const UpownerInfo(name: '测试UP主', face: '', sign: '测试简介');

  @override
  Future<UpownerVideosPage> fetchUpownerVideos(
    int mid, {
    int pn = 1,
    int ps = 20,
    String order = 'pubdate',
    String keyword = '',
  }) async =>
      const UpownerVideosPage(
        videos: [],
        totalCount: 0,
        hasMore: false,
      );

  @override
  Future<UpownerCollectionsResult> fetchUpownerCollections(
    int mid, {
    int pageNum = 1,
    int pageSize = 20,
  }) async =>
      const UpownerCollectionsResult(seasons: [], series: []);
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

Upowner _up() => Upowner(
      mid: 10001,
      name: '测试UP主',
      face: '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

/// 宿主：push UpownerPage 并捕获 pop 返回值。
class _Launcher extends StatelessWidget {
  final UpownerWriter writer;
  final bool isInWhitelist;
  final void Function(bool?) onResult;

  const _Launcher({
    required this.writer,
    required this.isInWhitelist,
    required this.onResult,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              final r = await Navigator.of(ctx).push<bool>(
                MaterialPageRoute(
                  builder: (_) => UpownerPage(
                    mid: 10001,
                    initial: _up(),
                    isInWhitelist: isInWhitelist,
                    api: _MemoryBiliApi(),
                    writer: writer,
                  ),
                ),
              );
              onResult(r);
            },
            child: const Text('进入UP详情'),
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

  /// 点「进入UP详情」并等待首屏加载完成。
  Future<void> openPage(WidgetTester tester) async {
    await tester.tap(find.text('进入UP详情'));
    await tester.pumpAndSettle();
  }

  testWidgets('未关注 UP：关注 → 写 Gist+本地缓存 → 按钮变「已关注」', (tester) async {
    final github = _MemoryGithubApi(); // 空白名单
    final writer = UpownerWriter(github: github);
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: _Launcher(
        writer: writer,
        isInWhitelist: false,
        onResult: (r) => result = r,
      ),
    ));
    await openPage(tester);

    expect(find.text('关注'), findsOneWidget); // AppBar 关注按钮
    expect(find.text('已关注'), findsNothing);

    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();

    // Gist 已写入 + 本地缓存已更新（mock 验证 upowners 落库）
    expect(github.saveCount, 1);
    expect(github.stored!.upowners.map((u) => u.mid), [10001]);
    expect(sync.cached.last.upowners.single.name, '测试UP主');
    // 按钮状态翻转 + snack
    expect(find.text('已关注'), findsOneWidget);
    expect(find.text('关注'), findsNothing);
    expect(find.text('已关注：测试UP主'), findsOneWidget);

    // 返回 → pop(true)，上层据其刷新白名单
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('已关注 UP：取消关注（确认）→ 移除 → 按钮回「关注」', (tester) async {
    final github = _MemoryGithubApi(
      initial: WhitelistData.empty().copyWith(upowners: [_up()]),
    );
    final writer = UpownerWriter(github: github);
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: _Launcher(
        writer: writer,
        isInWhitelist: true,
        onResult: (r) => result = r,
      ),
    ));
    await openPage(tester);

    expect(find.text('已关注'), findsOneWidget);

    await tester.tap(find.text('已关注'));
    await tester.pumpAndSettle();
    // 确认弹窗
    expect(find.textContaining('取消关注「测试UP主」'), findsOneWidget);
    await tester.tap(find.text('取消关注').last);
    await tester.pumpAndSettle();

    expect(github.stored!.upowners, isEmpty); // Gist 已移除
    expect(sync.cached.last.upowners, isEmpty);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
    expect(find.textContaining('已取消关注'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('取消关注弹窗点「取消」→ 状态与 Gist 不变', (tester) async {
    final github = _MemoryGithubApi(
      initial: WhitelistData.empty().copyWith(upowners: [_up()]),
    );
    final writer = UpownerWriter(github: github);
    await tester.pumpWidget(MaterialApp(
      home: _Launcher(
        writer: writer,
        isInWhitelist: true,
        onResult: (_) {},
      ),
    ));
    await openPage(tester);

    await tester.tap(find.text('已关注'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    expect(find.text('已关注'), findsOneWidget);
    expect(github.saveCount, 0);
    expect(github.stored!.upowners.single.mid, 10001);
  });

  testWidgets('未配置 GitHub：点关注提示配置、状态不变', (tester) async {
    final github = _MemoryGithubApi(configured: false);
    final writer = UpownerWriter(github: github);
    await tester.pumpWidget(MaterialApp(
      home: _Launcher(
        writer: writer,
        isInWhitelist: false,
        onResult: (_) {},
      ),
    ));
    await openPage(tester);

    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();

    expect(find.textContaining('GitHub token'), findsOneWidget); // snack 引导
    expect(find.text('关注'), findsOneWidget); // 仍是未关注
    expect(github.saveCount, 0);
  });

  testWidgets('未改动直接返回 → pop(null)', (tester) async {
    final github = _MemoryGithubApi();
    final writer = UpownerWriter(github: github);
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: _Launcher(
        writer: writer,
        isInWhitelist: false,
        onResult: (r) => result = r,
      ),
    ));
    await openPage(tester);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
