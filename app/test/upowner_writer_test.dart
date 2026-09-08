// UpownerWriter 单元测试（v2.17.12+ 补充）：
// - add：关注文案（已关注/已在白名单无需重复关注）；写入 Gist + 本地缓存
// - removeByMid：取消关注文案；成功移除/不在白名单
// - addBatch：批量加入（一次写盘）；入参去重（内部重复/无效条目）；已在
//   白名单跳过计数 skipped；全部已存在 → 不发写请求；未配置 → ok=false
// - 本地缓存验证：saveToCache 收到最新白名单（含新关注 UP）
// 不访问真实网络（GithubApi 用内存实现；ServiceLocator 换假同步服务）。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/upowner.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/upowner_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存版 GithubApi：不访问网络，hasConfig/fetch/save 都在内存完成。
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

/// 假同步服务：跳过 path_provider，saveToCache 记录每次写入。
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
      face: '//i0.hdslb.com/bfs/face/$mid.jpg',
      fans: 1000,
      addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingSyncService sync;

  setUp(() {
    sync = _RecordingSyncService();
    ServiceLocator.overrideSyncService(sync);
  });

  group('UpownerWriter.add', () {
    test('新增关注：写 Gist + 本地缓存，文案「已关注」', () async {
      final github = _MemoryGithubApi();
      final writer = UpownerWriter(github: github);
      final r = await writer.add(_up(1, '张三'));

      expect(r.ok, isTrue);
      expect(r.message, '已关注：张三');
      expect(github.stored!.upowners.map((u) => u.mid), [1]);
      expect(github.saveCount, 1);
      expect(sync.cached.single.upowners.single.mid, 1); // 本地缓存已写入
    });

    test('重复关注：ok=false 带最新白名单，不写盘', () async {
      final github = _MemoryGithubApi(
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);
      final r = await writer.add(_up(1, '张三'));

      expect(r.ok, isFalse);
      expect(r.message, contains('无需重复关注'));
      expect(github.saveCount, 0);
    });

    test('未配置 → ok=false 引导配置，不发请求', () async {
      final github = _MemoryGithubApi(configured: false);
      final writer = UpownerWriter(github: github);
      final r = await writer.add(_up(1, '张三'));

      expect(r.ok, isFalse);
      expect(r.message, contains('GitHub token'));
      expect(github.saveCount, 0);
    });
  });

  group('UpownerWriter.removeByMid', () {
    test('取消关注：移除并写盘，文案「已取消关注」', () async {
      final github = _MemoryGithubApi(
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);
      final r = await writer.removeByMid(1);

      expect(r.ok, isTrue);
      expect(r.message, contains('已取消关注'));
      expect(github.stored!.upowners, isEmpty);
      expect(sync.cached.last.upowners, isEmpty);
    });

    test('不在白名单：ok=false，不写盘', () async {
      final github = _MemoryGithubApi(
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);
      final r = await writer.removeByMid(999);

      expect(r.ok, isFalse);
      expect(r.message, contains('未关注'));
      expect(github.saveCount, 0);
    });
  });

  group('UpownerWriter.addBatch', () {
    test('批量关注：一次写盘，added/skipped 正确，本地缓存含新关注', () async {
      // 白名单里已有 mid=1
      final github = _MemoryGithubApi(
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);

      // 选 3 位：1（已在）2/3（新增），外加重复选 2 一次、无效 mid=0
      final r = await writer.addBatch([
        _up(1, '张三'),
        _up(2, '李四'),
        _up(3, '王五'),
        _up(2, '李四'),
        _up(0, '无效'),
      ]);

      expect(r.ok, isTrue);
      expect(r.added, 2);
      expect(r.skipped, 1); // 已在白名单的 1 位（内部重复不再计入）
      expect(github.saveCount, 1, reason: '批量应只写一次 Gist');
      expect(github.stored!.upowners.map((u) => u.mid), [1, 2, 3]);
      expect(sync.cached.last.upowners.map((u) => u.mid), [1, 2, 3]);
    });

    test('全部已在白名单：不写盘，ok=true/added=0', () async {
      final github = _MemoryGithubApi(
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);
      final r = await writer.addBatch([_up(1, '张三')]);

      expect(r.ok, isTrue);
      expect(r.added, 0);
      expect(r.skipped, 1);
      expect(github.saveCount, 0);
    });

    test('入参为空/全无效：直接返回不写盘', () async {
      final github = _MemoryGithubApi(
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);
      final r = await writer.addBatch(const []);

      expect(r.ok, isTrue);
      expect(r.added, 0);
      expect(github.saveCount, 0);
    });

    test('未配置 → ok=false 引导配置，不发请求', () async {
      final github = _MemoryGithubApi(
        configured: false,
        initial: WhitelistData.empty().copyWith(upowners: [_up(1, '张三')]),
      );
      final writer = UpownerWriter(github: github);
      final r = await writer.addBatch([_up(2, '李四')]);

      expect(r.ok, isFalse);
      expect(r.message, contains('GitHub token'));
      expect(github.saveCount, 0);
    });
  });
}
