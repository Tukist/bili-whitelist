// 电脑端观看时长并入同步（v2.66.0）· 服务层测试：
// BiliHistorySyncService.sync 成功后把远程历史折算成"电脑端（估算）"秒数写进
// RemoteWatchStats；重复同步幂等；本机同日同视频不双计。
//
// 不发网络：fetchPage / whitelist / store / remoteWatch 全部注入。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/bili_history_api.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/services/remote_watch_stats.dart';

int _epoch(DateTime local) => local.millisecondsSinceEpoch ~/ 1000;

/// 一条 archive 历史项（字段名照 bilibili-API-collect 文档）。
Map<String, dynamic> _archiveItem({
  String bvid = 'BV1',
  int page = 1,
  int cid = 111,
  int progress = 42,
  int duration = 600,
  DateTime? viewAt,
}) {
  final at = viewAt ?? DateTime(2026, 9, 8, 12);
  return {
    'title': '标题',
    'cover': '',
    'history': {
      'oid': 1,
      'epid': 0,
      'bvid': bvid,
      'page': page,
      'cid': cid,
      'business': 'archive',
    },
    'author_name': 'UP',
    'view_at': _epoch(at),
    'progress': progress,
    'duration': duration,
  };
}

WhitelistVideo _video(String bvid) => WhitelistVideo(
      bvid: bvid,
      cid: 111,
      title: '标题',
      cover: '',
      duration: 600,
      upName: 'UP',
      addedAt: '2026-01-01T00:00:00.000Z',
    );

WhitelistData _wl(List<WhitelistVideo> videos) => WhitelistData(
      version: 4,
      updatedAt: '2026-01-01T00:00:00.000Z',
      videos: videos,
    );

RemoteWatchStats _pcStore() {
  final s = RemoteWatchStats();
  s.clock = () => DateTime(2026, 9, 10, 12);
  return s;
}

/// 跑一次同步（单页，无 cursor → 不翻页）。
Future<HistorySyncOutcome> _sync(
  List<Map<String, dynamic>> list, {
  required RemoteWatchStats remoteWatch,
  List<WhitelistVideo> whitelist = const [],
}) =>
    BiliHistorySyncService(
      fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async =>
          {'cursor': null, 'list': list},
      whitelist: () async => _wl(whitelist),
      store: HistoryStore.instance,
      remoteWatch: remoteWatch,
      now: () => DateTime(2026, 9, 10, 12),
    ).sync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('同步成功 → 每条历史按 clamp(progress, 0, duration) 归到本地自然日', () async {
    final pc = _pcStore();
    final outcome = await _sync(
      [
        _archiveItem(bvid: 'BV1', progress: 42, viewAt: DateTime(2026, 9, 8, 9)),
        _archiveItem(bvid: 'BV2', progress: 900, duration: 600,
            viewAt: DateTime(2026, 9, 8, 22)),
        _archiveItem(bvid: 'BV3', progress: 120,
            viewAt: DateTime(2026, 9, 9, 1)),
      ],
      remoteWatch: pc,
    );

    expect(outcome.ok, isTrue);
    expect(outcome.pcWatchSeconds, 42 + 600 + 120);
    expect(pc.days, {'2026-09-08': 642, '2026-09-09': 120});
  });

  test('同一批历史同步两次 → 电脑端秒数不变（幂等）', () async {
    final pc = _pcStore();
    final list = [
      _archiveItem(bvid: 'BV1', progress: 42),
      _archiveItem(bvid: 'BV2', progress: 100),
    ];
    final first = await _sync(list, remoteWatch: pc);
    final firstDays = Map<String, int>.from(pc.days);

    final second = await _sync(list, remoteWatch: pc);
    expect(first.pcWatchSeconds, 142);
    expect(second.pcWatchSeconds, 0, reason: '第二次全是已计过的幂等键');
    expect(pc.days, firstDays);
  });

  test('跨会话（新建 store 重读 prefs）再同步同一批 → 仍不累加', () async {
    final list = [_archiveItem(bvid: 'BV1', progress: 42)];
    await _sync(list, remoteWatch: _pcStore());

    final reopened = _pcStore();
    final outcome = await _sync(list, remoteWatch: reopened);
    expect(outcome.pcWatchSeconds, 0);
    expect(reopened.secondsOf(DateTime(2026, 9, 8)), 42);
  });

  test('本机同一天看过同一个视频 → 该条不计入电脑端（不双计）', () async {
    // 本机历史：同一天、同一 (bvid, pageIndex)。source 默认 local = 本机看过。
    await HistoryStore.instance.addOrUpdate(HistoryEntry(
      bvid: 'BV1',
      pageIndex: 0,
      cid: 111,
      title: '本机看过',
      cover: '',
      upName: 'UP',
      durationMs: 600000,
      positionMs: 42000,
      watchedAt: DateTime(2026, 9, 8, 8),
    ));

    final pc = _pcStore();
    final outcome = await _sync(
      [_archiveItem(bvid: 'BV1', progress: 42,
          viewAt: DateTime(2026, 9, 8, 20))],
      remoteWatch: pc,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.pcWatchSeconds, 0);
    expect(pc.days, isEmpty, reason: '本机已实测，回读只会计成双份');
  });

  test('本机前一天看过同一视频 → 仍然计入（只排除同日）', () async {
    await HistoryStore.instance.addOrUpdate(HistoryEntry(
      bvid: 'BV1',
      pageIndex: 0,
      cid: 111,
      title: '昨天看过',
      cover: '',
      upName: 'UP',
      durationMs: 600000,
      positionMs: 42000,
      watchedAt: DateTime(2026, 9, 7, 22),
    ));

    final pc = _pcStore();
    final outcome = await _sync(
      [_archiveItem(bvid: 'BV1', progress: 42,
          viewAt: DateTime(2026, 9, 8, 20))],
      remoteWatch: pc,
    );
    expect(outcome.pcWatchSeconds, 42);
    expect(pc.days, {'2026-09-08': 42});
  });

  test('不可估的条目（progress=0 / duration=0）不产生任何秒数', () async {
    final pc = _pcStore();
    final outcome = await _sync(
      [
        _archiveItem(bvid: 'BV1', progress: 0),
        _archiveItem(bvid: 'BV2', duration: 0),
      ],
      remoteWatch: pc,
    );
    expect(outcome.ok, isTrue);
    expect(outcome.pcWatchSeconds, 0);
    expect(pc.days, isEmpty);
  });

  test('同步失败（白名单读取失败）→ 电脑端秒数一笔不写', () async {
    final pc = _pcStore();
    final outcome = await BiliHistorySyncService(
      fetchPage: ({int? max, int? viewAt, String? business, int ps = 30}) async =>
          {'cursor': null, 'list': [_archiveItem()]},
      whitelist: () async => throw StateError('gist 挂了'),
      store: HistoryStore.instance,
      remoteWatch: pc,
      now: () => DateTime(2026, 9, 10, 12),
    ).sync();

    expect(outcome.ok, isFalse);
    expect(outcome.pcWatchSeconds, 0);
    expect(pc.days, isEmpty);
  });

  test('历史页本身不受影响：同步结果计数与既有口径一致', () async {
    final pc = _pcStore();
    final outcome = await _sync(
      [_archiveItem(bvid: 'BV1'), _archiveItem(bvid: 'BV2', cid: 0)],
      remoteWatch: pc,
      whitelist: [_video('BV1')],
    );
    expect(outcome.kept, 1);
    expect(outcome.dropped, 1);
    // summary 文案不含电脑端数字（既有断言/文案一字不变）
    expect(outcome.summary,
        '已同步 1 条 B 站历史 · 新增 1 · 跳过 1 条无法播放的');
  });
}
