// 历史同步 → **本机进度记忆**（v2.59.0，跨端续播的 B1 部分）。
//
// 背景：v2.57.0 的历史同步把远程 `progress` 写进了 `HistoryEntry.positionMs`，
// 但播放页恢复进度读的是 `PlaybackProgress`（键 `<bvid>_<pageIndex>`）——
// 两边没接上，于是"PC 看到 10:00，手机还是从头播"。
//
// 这里钉住规则：
// - 远程**更近**（view_at 晚于本机 watchedAt）→ 写进本机进度记忆；
// - 本机**更近** → 不被覆盖（本机刚看到 20:00，PC 上是昨天的 5:00）；
// - 时间戳相同 → 取进度更靠后的那条；完全相同则不写；
// - 分 P 各自独立（写第 2 P 不动第 1 P）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/cache/playback_progress.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/bili_history_api.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

const String _kBvid = 'BV1MULTIP2';
const int _kCidP1 = 111;
const int _kCidP2 = 222;

WhitelistVideo _multiPageVideo() => const WhitelistVideo(
  bvid: _kBvid,
  cid: _kCidP1,
  title: '两集的视频',
  cover: '',
  duration: 900,
  upName: 'UP主',
  addedAt: '2026-01-01T00:00:00.000Z',
  pages: [
    PageInfo(cid: _kCidP1, part: '第 1 集', duration: 600),
    PageInfo(cid: _kCidP2, part: '第 2 集', duration: 300),
  ],
);

WhitelistData _wl() =>
    WhitelistData(version: 4, updatedAt: '2026-01-01T00:00:00.000Z', videos: [
      _multiPageVideo(),
    ]);

/// 一条远程历史（`view_at` 秒级时间戳，`progress` 秒）。
Map<String, dynamic> _remoteItem({
  required int cid,
  required int page,
  required int progressSec,
  required DateTime viewAt,
}) => {
  'title': '远程标题',
  'cover': '',
  'history': {
    'oid': 80433022,
    'epid': 0,
    'bvid': _kBvid,
    'page': page,
    'cid': cid,
    'business': 'archive',
  },
  'author_name': 'UP主',
  'view_at': viewAt.millisecondsSinceEpoch ~/ 1000,
  'progress': progressSec,
  'duration': 600,
};

Future<HistorySyncOutcome> _sync(List<Map<String, dynamic>> items) {
  final service = BiliHistorySyncService(
    fetchPage: ({max, viewAt, business, ps = 30}) async => {
      'cursor': null,
      'list': items,
    },
    whitelist: () async => _wl(),
    store: HistoryStore.instance,
    now: () => DateTime(2026, 9, 8, 12),
  );
  return service.sync();
}

/// 本机历史条目（模拟"本机也看过这一集"）。
HistoryEntry _localEntry({
  required int pageIndex,
  required int cid,
  required int positionMs,
  required DateTime watchedAt,
}) => HistoryEntry(
  bvid: _kBvid,
  pageIndex: pageIndex,
  cid: cid,
  title: '本机标题',
  cover: '',
  upName: 'UP主',
  durationMs: 600000,
  positionMs: positionMs,
  watchedAt: watchedAt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final localNewest = DateTime(2026, 9, 8, 11, 0);
  final pcOlder = DateTime(2026, 9, 7, 5, 0);

  test('远程更近 → 远程进度写进本机进度记忆（续播才跨端生效）', () async {
    SharedPreferences.setMockInitialValues({});
    // 本机看过第 1 集，但在 1 小时前
    await HistoryStore.instance.addOrUpdate(
      _localEntry(
        pageIndex: 0,
        cid: _kCidP1,
        positionMs: 10000,
        watchedAt: localNewest,
      ),
    );

    final outcome = await _sync([
      _remoteItem(
        cid: _kCidP1,
        page: 1,
        progressSec: 120,
        // 比本机更近（PC 上刚看）
        viewAt: localNewest.add(const Duration(minutes: 30)),
      ),
    ]);

    expect(outcome.ok, isTrue);
    expect(outcome.adoptedProgress, 1);
    final progress = await PlaybackProgress.load();
    expect(progress.getProgress(_kBvid, 0), 120000,
        reason: '远程 progress(秒) × 1000 写进本机进度记忆');
  });

  test('本机更近 → **不覆盖**本机进度（本机 20:00 vs PC 昨天的 5:00）', () async {
    SharedPreferences.setMockInitialValues({});
    // 本机刚看到 20:00
    await HistoryStore.instance.addOrUpdate(
      _localEntry(
        pageIndex: 0,
        cid: _kCidP1,
        positionMs: 1200000,
        watchedAt: localNewest,
      ),
    );
    final progressBefore = await PlaybackProgress.load();
    await progressBefore.saveProgress(_kBvid, 0, 1200000);

    final outcome = await _sync([
      _remoteItem(
        cid: _kCidP1,
        page: 1,
        progressSec: 300, // PC 上昨天的 5:00
        viewAt: pcOlder,
      ),
    ]);

    expect(outcome.ok, isTrue);
    expect(outcome.adoptedProgress, 0);
    final progress = await PlaybackProgress.load();
    expect(progress.getProgress(_kBvid, 0), 1200000,
        reason: '本机更近的一次绝不能被远程按回去');
  });

  test('本机从没记录过这一集 → 直接用远程进度', () async {
    SharedPreferences.setMockInitialValues({});

    final outcome = await _sync([
      _remoteItem(cid: _kCidP2, page: 2, progressSec: 42, viewAt: pcOlder),
    ]);

    expect(outcome.ok, isTrue);
    expect(outcome.adoptedProgress, 1);
    final progress = await PlaybackProgress.load();
    expect(progress.getProgress(_kBvid, 1), 42000, reason: '第 2 集（pageIndex=1）');
    expect(progress.getProgress(_kBvid, 0), isNull, reason: '第 1 集不受影响');
  });

  test('本机更近但回拖过（进度更小）→ 仍以**时间**为准，不写远程', () async {
    SharedPreferences.setMockInitialValues({});
    await HistoryStore.instance.addOrUpdate(
      _localEntry(
        pageIndex: 0,
        cid: _kCidP1,
        positionMs: 30000, // 往回到 0:30
        watchedAt: localNewest,
      ),
    );

    final outcome = await _sync([
      _remoteItem(cid: _kCidP1, page: 1, progressSec: 500, viewAt: pcOlder),
    ]);

    expect(outcome.adoptedProgress, 0,
        reason: '看得更近不代表进度更大（可能往回拖），时间才是判据');
    final progress = await PlaybackProgress.load();
    expect(progress.getProgress(_kBvid, 0), isNull);
  });

  test('时间戳完全相同：进度更靠后的那条胜出', () async {
    SharedPreferences.setMockInitialValues({});
    final sameMoment = DateTime(2026, 9, 8, 10, 0);
    await HistoryStore.instance.addOrUpdate(
      _localEntry(
        pageIndex: 0,
        cid: _kCidP1,
        positionMs: 60000,
        watchedAt: sameMoment,
      ),
    );

    final outcome = await _sync([
      // view_at 只有秒精度 → 与本机 watchedAt 落在同一秒
      _remoteItem(cid: _kCidP1, page: 1, progressSec: 180, viewAt: sameMoment),
    ]);

    expect(outcome.adoptedProgress, 1);
    final progress = await PlaybackProgress.load();
    expect(progress.getProgress(_kBvid, 0), 180000);
  });

  test('分 P 各自独立：第 2 集远程更新，不动第 1 集的本机进度', () async {
    SharedPreferences.setMockInitialValues({});
    await HistoryStore.instance.addOrUpdate(
      _localEntry(
        pageIndex: 0,
        cid: _kCidP1,
        positionMs: 45000,
        watchedAt: localNewest,
      ),
    );
    await HistoryStore.instance.addOrUpdate(
      _localEntry(
        pageIndex: 1,
        cid: _kCidP2,
        positionMs: 5000,
        watchedAt: pcOlder,
      ),
    );
    final progress = await PlaybackProgress.load();
    await progress.saveProgress(_kBvid, 0, 45000);
    await progress.saveProgress(_kBvid, 1, 5000);

    final outcome = await _sync([
      // 第 1 集：远程更旧 → 不动
      _remoteItem(cid: _kCidP1, page: 1, progressSec: 100, viewAt: pcOlder),
      // 第 2 集：远程更新 → 写
      _remoteItem(
        cid: _kCidP2,
        page: 2,
        progressSec: 200,
        viewAt: localNewest.add(const Duration(minutes: 5)),
      ),
    ]);

    expect(outcome.adoptedProgress, 1);
    final after = await PlaybackProgress.load();
    expect(after.getProgress(_kBvid, 0), 45000, reason: '第 1 集保持本机的');
    expect(after.getProgress(_kBvid, 1), 200000, reason: '第 2 集用远程的');
  });

  test('远程没有进度（progress=0）→ 不写（写了也只是"从头播"）', () async {
    SharedPreferences.setMockInitialValues({});

    final outcome = await _sync([
      _remoteItem(cid: _kCidP1, page: 1, progressSec: 0, viewAt: pcOlder),
    ]);

    expect(outcome.adoptedProgress, 0);
    final progress = await PlaybackProgress.load();
    expect(progress.getProgress(_kBvid, 0), isNull);
  });

  group('shouldAdoptRemoteProgress（纯函数）', () {
    HistoryEntry entry(int positionMs, DateTime watchedAt) => HistoryEntry(
      bvid: 'BVx',
      pageIndex: 0,
      cid: 1,
      title: 't',
      cover: '',
      upName: 'u',
      durationMs: 1000,
      positionMs: positionMs,
      watchedAt: watchedAt,
    );

    test('本机无记录 → 采纳', () {
      expect(
        shouldAdoptRemoteProgress(
          local: null,
          remote: entry(1000, DateTime(2026, 1, 1)),
        ),
        isTrue,
      );
    });

    test('远程更新 → 采纳', () {
      expect(
        shouldAdoptRemoteProgress(
          local: entry(1, DateTime(2026, 1, 1)),
          remote: entry(2, DateTime(2026, 1, 2)),
        ),
        isTrue,
      );
    });

    test('远程更旧 → 不采纳', () {
      expect(
        shouldAdoptRemoteProgress(
          local: entry(1, DateTime(2026, 1, 2)),
          remote: entry(2, DateTime(2026, 1, 1)),
        ),
        isFalse,
      );
    });

    test('同时间戳：远程进度更大才采纳（相等不写）', () {
      final at = DateTime(2026, 1, 1);
      expect(
        shouldAdoptRemoteProgress(
          local: entry(1000, at),
          remote: entry(2000, at),
        ),
        isTrue,
      );
      expect(
        shouldAdoptRemoteProgress(
          local: entry(2000, at),
          remote: entry(2000, at),
        ),
        isFalse,
      );
      expect(
        shouldAdoptRemoteProgress(
          local: entry(2000, at),
          remote: entry(1000, at),
        ),
        isFalse,
      );
    });
  });
}
