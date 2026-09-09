// 启动自动同步（v2.17.13+）单元测试：
// - 纯决策 planFollowingsAutoSync：未登录/未配置/节流/就绪
// - 纯查重 filterNewFollowings：白名单跳过/跳过名单跳过/无效条目/内部重复
// - 服务 syncOnce（内存 BiliApi + 内存 GithubApi + 假缓存服务）：
//   · 未登录/未配置 → 直接跳过，0 网络请求
//   · 首次同步：45 关注 → 全量加入（3 页）；addBatch 只写一次 Gist
//   · 增量：白名单已有旧 40 → 只加新 5；连续整页已知 → 提前停止翻页
//   · 无新增：已全量同步 → 不写 Gist；且记录成功时间
//   · 二次启动：节流（10 分钟内）→ 不重复拉取
//   · 跳过名单：手动移除过的关注不再自动加回
//   · 中途某页失败：已拉到部分仍增量加入
// - rememberManualRemoval：幂等记录 + 自动同步生效
// 不访问真实网络。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/followings_auto_sync.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存 BiliApi：关注按时间倒序（mids = total..1，最近关注在最前）；
/// 可切登录态 / 让指定页抛网络错误。
class _MemoryBiliApi extends BiliApi {
  bool loggedIn;
  final int total;
  final int failPage; // >0 时该页抛连接错误
  int fetchCount = 0;

  _MemoryBiliApi({
    this.loggedIn = true,
    this.total = 45,
    this.failPage = 0,
  }) : super(dio: Dio(BaseOptions(baseUrl: kBiliApi)));

  @override
  Future<String?> readSessdata() async => loggedIn ? 'sess-ok' : null;

  @override
  Future<FollowingsPage> fetchFollowingsOfMine({
    int pn = 1,
    int ps = 20,
  }) async {
    fetchCount++;
    if (pn == failPage) {
      throw DioException.connectionError(
        requestOptions: RequestOptions(path: '/x/relation/followings'),
        reason: 'mock network down',
      );
    }
    final high = total - (pn - 1) * ps;
    final low = (high - ps + 1) < 1 ? 1 : high - ps + 1;
    final mids = [for (var m = high; m >= low; m--) m];
    return FollowingsPage(
      upowners: [
        for (final m in mids)
          Upowner(
            mid: m,
            name: '关注UP$m',
            face: '',
            addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
      ],
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

/// 假同步服务：addBatch 内部写缓存时记录（跳过真实文件 IO）。
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

/// 白名单含 mid 1..count 的旧关注。
WhitelistData _whitelistWith(int count) => WhitelistData.empty().copyWith(
      upowners: [
        for (var m = 1; m <= count; m++) _up(m, '关注UP$m'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingSyncService sync;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sync = _RecordingSyncService();
    ServiceLocator.overrideSyncService(sync);
  });

  group('planFollowingsAutoSync（纯决策）', () {
    final now = DateTime(2026, 9, 9, 12, 0, 0);

    test('未登录 → notLoggedIn（无论是否配置）', () {
      expect(
        planFollowingsAutoSync(
          loggedIn: false,
          configured: true,
          lastSyncAt: null,
          now: now,
        ).decision,
        FollowingsSyncDecision.notLoggedIn,
      );
    });

    test('已登录但未配置 → notConfigured', () {
      expect(
        planFollowingsAutoSync(
          loggedIn: true,
          configured: false,
          lastSyncAt: null,
          now: now,
        ).decision,
        FollowingsSyncDecision.notConfigured,
      );
    });

    test('10 分钟内同步过 → throttled（带剩余时间）', () {
      final r = planFollowingsAutoSync(
        loggedIn: true,
        configured: true,
        lastSyncAt: now.subtract(const Duration(minutes: 2)),
        now: now,
      );
      expect(r.decision, FollowingsSyncDecision.throttled);
      expect(r.throttleRemaining, const Duration(minutes: 8));
    });

    test('超过 10 分钟 / 从未同步过 → 就绪 sync', () {
      final over = planFollowingsAutoSync(
        loggedIn: true,
        configured: true,
        lastSyncAt: now.subtract(const Duration(minutes: 11)),
        now: now,
      );
      expect(over.decision, FollowingsSyncDecision.sync);

      final never = planFollowingsAutoSync(
        loggedIn: true,
        configured: true,
        lastSyncAt: null,
        now: now,
      );
      expect(never.decision, FollowingsSyncDecision.sync);
    });
  });

  group('filterNewFollowings（纯增量查重）', () {
    test('新关注保留；白名单/跳过名单/无效/重复排除', () {
      final follows = [
        _up(101, '新关注'),
        _up(1, '已在白名单'),
        _up(2, '跳过名单里的'),
        _up(0, 'mid0无效'),
        _up(102, '  '), // 空名无效
        _up(101, '内部重复'),
        _up(103, '正常'),
      ];
      final out = filterNewFollowings(follows, {1, 2, 99});
      expect(out.map((u) => u.mid), [101, 103]);
    });
  });

  group('FollowingsAutoSyncService.syncOnce', () {
    test('未登录 → 跳过，不发任何请求', () async {
      final api = _MemoryBiliApi(loggedIn: false);
      final writer = UpownerWriter(
        github: _MemoryGithubApi(configured: true),
        api: api,
      );
      final svc = FollowingsAutoSyncService(writer: writer);
      final r = await svc.syncOnce();
      expect(r.decision, FollowingsSyncDecision.notLoggedIn);
      expect(api.fetchCount, 0);
    });

    test('未配置 GitHub → 跳过，不发任何请求', () async {
      final api = _MemoryBiliApi(loggedIn: true);
      final writer = UpownerWriter(
        github: _MemoryGithubApi(configured: false),
        api: api,
      );
      final svc = FollowingsAutoSyncService(writer: writer);
      final r = await svc.syncOnce();
      expect(r.decision, FollowingsSyncDecision.notConfigured);
      expect(api.fetchCount, 0);
    });

    test('首次同步：45 关注全量加入（3 页），addBatch 只写一次 Gist+缓存', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      final github = _MemoryGithubApi(initial: WhitelistData.empty());
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();

      expect(r.decision, FollowingsSyncDecision.sync);
      expect(r.added, 45);
      expect(r.followsScanned, 45);
      expect(api.fetchCount, 3);
      expect(github.saveCount, 1, reason: '批量只写一次 Gist');
      expect(github.stored!.upowners.length, 45);
      expect(sync.cached.last.upowners.length, 45);
      // 成功时间已记录（后续启动进入节流）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kFollowingsSyncLastAtKey), isNotNull);
    });

    test('增量：白名单已有旧 40，只加新 5；整页已知后提前停（不翻满 3 页）',
        () async {
      // 关注顺序：最近关注在最前（mids 45..1）；白名单 = 旧 40（1..40）
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      final github = _MemoryGithubApi(initial: _whitelistWith(40));
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();

      expect(r.added, 5, reason: '新关注的 41..45');
      // 第 1 页（45..26）有新关注 → 继续；第 2 页（25..6）全已知 → 提前停
      expect(api.fetchCount, 2, reason: '整页已知提前停止翻页');
      expect(github.saveCount, 1);
      final storedMids = github.stored!.upowners.map((u) => u.mid).toSet();
      expect(storedMids.length, 45, reason: '旧 40 + 新 5');
      expect(storedMids.containsAll(List.generate(45, (i) => i + 1)), isTrue);
    });

    test('无新增（全量已同步）：不写 Gist，但仍记录成功时间', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      final github = _MemoryGithubApi(initial: _whitelistWith(45));
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();

      expect(r.added, 0);
      expect(api.fetchCount, 1, reason: '首页全已知 → 1 页即停');
      expect(github.saveCount, 0, reason: '无需写盘');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kFollowingsSyncLastAtKey), isNotNull);
    });

    test('二次启动节流：10 分钟内不重复拉取、不重复写', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      final github = _MemoryGithubApi(initial: WhitelistData.empty());
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final first = await svc.syncOnce();
      expect(first.added, 45);
      expect(api.fetchCount, 3);

      final second = await svc.syncOnce();
      expect(second.decision, FollowingsSyncDecision.throttled);
      expect(api.fetchCount, 3, reason: '节流中不发任何请求');
      expect(github.saveCount, 1);
    });

    test('跳过名单：手动移除过的关注（仍在 B 站关注）不再自动加回', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      final github = _MemoryGithubApi(initial: WhitelistData.empty());
      final writer = UpownerWriter(github: github, api: api);
      // 预置跳过名单：44、45（用户手动移除过）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          kFollowingsSyncSkippedKey, ['44', '45']);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();

      expect(r.added, 43, reason: '45 关注 - 2 跳过名单');
      final storedMids = github.stored!.upowners.map((u) => u.mid).toSet();
      expect(storedMids.contains(44), isFalse);
      expect(storedMids.contains(45), isFalse);
      expect(storedMids.length, 43);
    });

    test('中途某页失败：已拉到部分仍增量加入（不整体放弃）', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45, failPage: 2);
      final github = _MemoryGithubApi(initial: WhitelistData.empty());
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();

      expect(r.added, 20, reason: '第 2 页失败，用第 1 页的 20 条');
      expect(github.stored!.upowners.length, 20);
    });

    test('首页即失败（网络/风控）→ 不记成功时间戳，下次启动可重试', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45, failPage: 1);
      final github = _MemoryGithubApi(initial: WhitelistData.empty());
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();
      expect(r.added, 0);
      expect(github.saveCount, 0);
      // 关键：首页失败 ≠ 成功的空同步 → 不应写入节流时间戳
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kFollowingsSyncLastAtKey), isNull,
          reason: '失败不节流：下次启动自动重试');

      // 第二次（模拟网络恢复）应能正常同步
      final api2 = _MemoryBiliApi(loggedIn: true, total: 45);
      final writer2 = UpownerWriter(
          github: _MemoryGithubApi(initial: WhitelistData.empty()),
          api: api2);
      final r2 = await FollowingsAutoSyncService(writer: writer2).syncOnce();
      expect(r2.added, 45);
    });

    test('拉白名单失败（Gist 异常）→ 本次跳过，不写 Gist', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      // fetchFromGist 抛异常（token 无效等）
      final githubBroken = _BrokenFetchGithub();
      final writer = UpownerWriter(github: githubBroken, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      final r = await svc.syncOnce();
      expect(r.added, 0);
      expect(api.fetchCount, 0, reason: '未拿到白名单前不翻页');
    });
  });

  group('rememberManualRemoval', () {
    test('幂等记录；之后同步不再加回该 mid', () async {
      final api = _MemoryBiliApi(loggedIn: true, total: 45);
      final github = _MemoryGithubApi(initial: WhitelistData.empty());
      final writer = UpownerWriter(github: github, api: api);
      final svc = FollowingsAutoSyncService(writer: writer);

      await svc.rememberManualRemoval(5);
      await svc.rememberManualRemoval(5); // 重复记录 → 幂等
      await svc.rememberManualRemoval(6);

      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(kFollowingsSyncSkippedKey);
      expect(list, isNotNull);
      expect(list!.where((s) => s == '5').length, 1);

      final r = await svc.syncOnce();
      expect(r.added, 43, reason: '45 - 5 - 6');
      expect(github.stored!.upowners.any((u) => u.mid == 5), isFalse);
      expect(github.stored!.upowners.any((u) => u.mid == 6), isFalse);
    });
  });
}

/// fetchFromGist 抛异常的 GithubApi（模拟 token 失效/网络）。
class _BrokenFetchGithub extends GithubApi {
  @override
  Future<bool> hasConfig() async => true;

  @override
  Future<WhitelistData?> fetchFromGist() async {
    throw DioException.connectionError(
      requestOptions: RequestOptions(path: '/gist/fetch'),
      reason: 'gist down',
    );
  }
}
