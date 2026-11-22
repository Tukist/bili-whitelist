// 电脑端（估算）观看时长（v2.66.0）单元测试：
// 估算式 / 本地自然日归日 / 排除本机同日同视频 / 幂等（同批 & 跨会话）/
// 幂等键容量裁剪 / 与本机实测合并 / 损坏容错。
//
// 约定：
// - 秒级时间戳一律由**本地** DateTime 换算（`millisecondsSinceEpoch ~/ 1000`），
//   这样"跨零点"断言的语义就是"本机时区的自然日"。
// - shared_preferences 用 mock（不碰原生插件）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/bili_history_api.dart';
import 'package:bili_whitelist_app/services/history_store.dart';
import 'package:bili_whitelist_app/services/remote_watch_stats.dart';
import 'package:bili_whitelist_app/services/watch_stats.dart';

int _epoch(DateTime local) => local.millisecondsSinceEpoch ~/ 1000;

RemoteHistoryItem _item({
  String bvid = 'BV1',
  int page = 1,
  int cid = 111,
  int progress = 42,
  int duration = 600,
  DateTime? viewAt,
  String business = 'archive',
}) {
  final at = viewAt ?? DateTime(2026, 9, 8, 12);
  return RemoteHistoryItem(
    bvid: bvid,
    oid: 1,
    epId: 0,
    cid: cid,
    page: page,
    business: business,
    title: '标题',
    cover: '',
    upName: 'UP',
    durationSec: duration,
    progressSec: progress,
    viewAtSec: _epoch(at),
  );
}

WhitelistVideo _video(
  String bvid, {
  int cid = 111,
  List<PageInfo>? pages,
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: cid,
      title: '标题',
      cover: '',
      duration: 600,
      upName: 'UP',
      addedAt: '2026-01-01T00:00:00.000Z',
      pages: pages,
    );

HistoryEntry _entry(
  String bvid,
  DateTime watchedAt, {
  int pageIndex = 0,
  HistorySource source = HistorySource.local,
}) =>
    HistoryEntry(
      bvid: bvid,
      pageIndex: pageIndex,
      cid: 111,
      title: '标题',
      cover: '',
      upName: 'UP',
      durationMs: 600000,
      positionMs: 42000,
      watchedAt: watchedAt,
      source: source,
    );

RemoteWatchSample _sample(
  String bvid,
  DateTime local,
  int seconds, {
  int pageIndex = 0,
}) =>
    RemoteWatchSample(
      bvid: bvid,
      pageIndex: pageIndex,
      viewAtSec: _epoch(local),
      seconds: seconds,
    );

/// 存储实例（时钟固定在 2026-09-10）：天数表裁剪依赖"今天"，固定时钟让
/// 断言不受运行机器当前日期影响。
RemoteWatchStats _fixedClockStore() {
  final s = RemoteWatchStats();
  s.clock = () => DateTime(2026, 9, 10, 12);
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('estimateRemoteWatchSeconds（clamp(progress, 0, duration)）', () {
    test('正常：progress 小于总时长 → 取 progress', () {
      expect(
        estimateRemoteWatchSeconds(progressSec: 42, durationSec: 600),
        42,
      );
    });

    test('progress > duration（脏数据/越界）→ 取 duration（不虚高到超出总长）', () {
      expect(
        estimateRemoteWatchSeconds(progressSec: 900, durationSec: 600),
        600,
      );
    });

    test('progress <= 0 / duration <= 0 / 负数 → 0（不编数）', () {
      expect(estimateRemoteWatchSeconds(progressSec: 0, durationSec: 600), 0);
      expect(estimateRemoteWatchSeconds(progressSec: 42, durationSec: 0), 0);
      expect(estimateRemoteWatchSeconds(progressSec: -5, durationSec: 600), 0);
      expect(estimateRemoteWatchSeconds(progressSec: 42, durationSec: -1), 0);
    });
  });

  group('归日（本机时区自然日）', () {
    test('23:59:59 与次日 00:00:01 归到不同日期', () {
      final a = _sample('BV1', DateTime(2026, 9, 8, 23, 59, 59), 60);
      final b = _sample('BV1', DateTime(2026, 9, 9, 0, 0, 1), 60);
      expect(a.dayKey, '2026-09-08');
      expect(b.dayKey, '2026-09-09');
    });

    test('同一天多条累加到同一个日期键（store 层）', () async {
      final store = _fixedClockStore();
      await store.recordAll([
        _sample('BV1', DateTime(2026, 9, 8, 9), 120),
        _sample('BV2', DateTime(2026, 9, 8, 22), 300),
      ]);
      expect(store.days, {'2026-09-08': 420});
      expect(store.totalSeconds, 420);
    });

    test('幂等键 = bvid|pageIndex|viewAt', () {
      final s = _sample('BVabc', DateTime(2026, 9, 8, 9), 10, pageIndex: 2);
      expect(
        s.idempotencyKey,
        'BVabc|2|${_epoch(DateTime(2026, 9, 8, 9))}',
      );
    });
  });

  group('buildRemoteWatchSamples（估算 + 排除本机同日同视频）', () {
    test('进度/时长不可估的条目跳过（不编数）', () {
      final out = buildRemoteWatchSamples(
        items: [
          _item(bvid: 'BVa', progress: 0),
          _item(bvid: 'BVb', duration: 0),
          _item(bvid: 'BVc', progress: 42),
        ],
        whitelistByBvid: const {},
        localHistory: const [],
      );
      expect(out.map((s) => s.bvid), ['BVc']);
      expect(out.single.seconds, 42);
    });

    test('progress > duration → 计入 duration', () {
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', progress: 900, duration: 600)],
        whitelistByBvid: const {},
        localHistory: const [],
      );
      expect(out.single.seconds, 600);
    });

    test('本机同日同视频（source=local）→ 跳过（不双计）', () {
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', page: 1, viewAt: DateTime(2026, 9, 8, 20))],
        whitelistByBvid: const {},
        localHistory: [_entry('BV1', DateTime(2026, 9, 8, 8))],
      );
      expect(out, isEmpty, reason: '本机已经实测过这一集，远程回读只会双计');
    });

    test('本机同日同视频（source=both，两边都看过）→ 同样跳过', () {
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', viewAt: DateTime(2026, 9, 8, 20))],
        whitelistByBvid: const {},
        localHistory: [
          _entry('BV1', DateTime(2026, 9, 8, 8), source: HistorySource.both),
        ],
      );
      expect(out, isEmpty);
    });

    test('本机**跨日**看过同视频 → 仍然计入（只排除同日）', () {
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', viewAt: DateTime(2026, 9, 9, 10))],
        whitelistByBvid: const {},
        localHistory: [_entry('BV1', DateTime(2026, 9, 8, 9))],
      );
      expect(out, hasLength(1), reason: '昨天手机上看的，不算今天电脑端的重复');
      expect(out.single.dayKey, '2026-09-09');
    });

    test('本机同日但**另一个分 P** → 仍然计入', () {
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', page: 2, viewAt: DateTime(2026, 9, 8, 10))],
        whitelistByBvid: const {},
        localHistory: [_entry('BV1', DateTime(2026, 9, 8, 9), pageIndex: 0)],
      );
      expect(out, hasLength(1));
      expect(out.single.pageIndex, 1);
    });

    test('本机记录来源是纯 bilibili（上一次同步写进来的）→ 不算"本机看过"', () {
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', viewAt: DateTime(2026, 9, 8, 10))],
        whitelistByBvid: const {},
        localHistory: [
          _entry('BV1', DateTime(2026, 9, 8, 9),
              source: HistorySource.bilibili),
        ],
      );
      expect(out, hasLength(1),
          reason: '否则第一次同步写进历史后，第二次同步就会把自己排除掉');
    });

    test('白名单分 P 列表存在时按 cid 定 pageIndex（与历史条目同口径）', () {
      final video = _video('BV1', pages: const [
        PageInfo(cid: 10, part: 'P1', duration: 60),
        PageInfo(cid: 20, part: 'P2', duration: 70),
      ]);
      final out = buildRemoteWatchSamples(
        items: [_item(bvid: 'BV1', cid: 20, page: 1)],
        whitelistByBvid: {'BV1': video},
        localHistory: const [],
      );
      expect(out.single.pageIndex, 1);
    });

    test('脏条目（非 archive / 空 bvid / view_at=0）跳过', () {
      final out = buildRemoteWatchSamples(
        items: [
          _item(bvid: '', progress: 10),
          _item(bvid: 'BVpgc', business: 'pgc'),
          _item(bvid: 'BVbad', viewAt: DateTime.fromMillisecondsSinceEpoch(0)),
        ],
        whitelistByBvid: const {},
        localHistory: const [],
      );
      expect(out, isEmpty);
    });
  });

  group('RemoteWatchStats 幂等（重复同步不累加）', () {
    test('同一批样本写入两次 → 秒数不变', () async {
      final store = _fixedClockStore();
      final batch = [
        _sample('BV1', DateTime(2026, 9, 8, 9), 120),
        _sample('BV2', DateTime(2026, 9, 8, 21), 60),
      ];
      final first = await store.recordAll(batch);
      final second = await store.recordAll(batch);
      expect(first, 180);
      expect(second, 0, reason: '第二次全是重复键');
      expect(store.days, {'2026-09-08': 180});
    });

    test('跨会话（新建实例重读 prefs）同样幂等', () async {
      final batch = [_sample('BV1', DateTime(2026, 9, 8, 9), 120)];
      await _fixedClockStore().recordAll(batch);
      final fresh = _fixedClockStore();
      final added = await fresh.recordAll(batch);
      expect(added, 0);
      expect(fresh.secondsOf(DateTime(2026, 9, 8)), 120);
    });

    test('只新增真正新的条目（同批里旧的跳过、新的计入）', () async {
      final store = _fixedClockStore();
      await store.recordAll([_sample('BV1', DateTime(2026, 9, 8, 9), 120)]);
      final added = await store.recordAll([
        _sample('BV1', DateTime(2026, 9, 8, 9), 120),
        _sample('BV2', DateTime(2026, 9, 9, 9), 300),
      ]);
      expect(added, 300);
      expect(store.days, {'2026-09-08': 120, '2026-09-09': 300});
    });

    test('空样本 / 全重复 → 不写盘也不报错', () async {
      final store = _fixedClockStore();
      expect(await store.recordAll(const []), 0);
      expect(store.days, isEmpty);
    });
  });

  group('幂等键容量上限（防无限增长）', () {
    test('trimSeenKeys：去重 + 只保留最近 maxKeys 个（顺序即新→旧）', () {
      final keys = List.generate(10, (i) => 'k$i');
      final out = trimSeenKeys(keys, maxKeys: 4);
      expect(out, ['k0', 'k1', 'k2', 'k3'], reason: '保留前 4 个（最新的）');
      expect(trimSeenKeys(['a', 'a', 'b'], maxKeys: 5), ['a', 'b']);
      expect(trimSeenKeys([' ', ''], maxKeys: 5), isEmpty);
    });

    test('写满上限后键集被裁到 maxSeenKeys，已保留的键仍然幂等', () async {
      final base = DateTime(2026, 1, 1, 0, 30);
      final samples = [
        for (var i = 0; i < RemoteWatchStats.maxSeenKeys + 5; i++)
          _sample('BV$i', base.add(Duration(minutes: i)), 1),
      ];
      final store = _fixedClockStore();
      await store.recordAll(samples);
      expect(store.seenKeys.length, RemoteWatchStats.maxSeenKeys);
      final keptSeconds = store.totalSeconds;

      // 已保留（列表前部）的键：再写一次不累加
      final again = await store.recordAll([samples.first]);
      expect(again, 0);
      expect(store.totalSeconds, keptSeconds);

      // 被裁掉的是列表尾部（真实同步按"新 → 旧"喂入，尾部就是最旧的）：
      // 这些键再被同步到会重新计入一次（可接受的取舍，见类注释）
      final evicted = await store.recordAll([samples.last]);
      expect(evicted, 1);
    });

    test('重读 prefs 后键集仍按上限裁剪（不会因为旧数据变大）', () async {
      final prefs = await SharedPreferences.getInstance();
      final keys = [
        for (var i = 0; i < RemoteWatchStats.maxSeenKeys + 3; i++) '"k$i"'
      ].join(',');
      await prefs.setString(
        RemoteWatchStats.storageKey,
        '{"days":{},"seen":[$keys]}',
      );
      final store = _fixedClockStore();
      await store.ensureLoaded();
      expect(store.seenKeys.length, RemoteWatchStats.maxSeenKeys);
      expect(store.seenKeys.first, 'k0');
    });
  });

  group('损坏容错与裁剪（不崩溃、不编数）', () {
    test('天数字段脏类型 / 非法日期键 / 非正数 → 跳过；seen 非数组 → 空', () async {
      SharedPreferences.setMockInitialValues({
        RemoteWatchStats.storageKey: '{"days": '
            '{"2026-09-08": 120, "2026-09-07": "x", "bad-key": 60, '
            '"2026-09-06": -5, "2026-02-30": 30}, '
            '"seen": {"not": "a list"}}',
      });
      final store = _fixedClockStore();
      await store.ensureLoaded();
      expect(store.days, {'2026-09-08': 120});
      expect(store.seenKeys, isEmpty);
    });

    test('天数表非 JSON / 完全损坏 → 视为空（不抛）', () async {
      SharedPreferences.setMockInitialValues({
        RemoteWatchStats.storageKey: 'not-json',
      });
      final store = _fixedClockStore();
      await store.ensureLoaded();
      expect(store.days, isEmpty);
      expect(store.totalSeconds, 0);
    });

    test('早于保留窗口（400 天前）的日期读出即裁剪；未来日期丢弃', () {
      final now = DateTime(2026, 9, 8);
      final out = pruneDays(
        {
          '2025-01-01': 100, // 太旧
          '2026-09-08': 50,
          '2026-09-09': 60, // 未来
          'bad': 10,
        },
        now: now,
      );
      expect(out, {'2026-09-08': 50});
    });

    test('pruneDays 保留窗口边界（maxDays - 1 天前仍保留）', () {
      final now = DateTime(2026, 9, 8);
      final edge = DateTime(2026, 9, 8).subtract(const Duration(days: 3));
      final out = pruneDays(
        {WatchStats.dateKey(edge): 5, '2026-09-08': 7},
        maxDays: 4,
        now: now,
      );
      expect(out, hasLength(2));
    });
  });

  group('mergeDailySeconds（热力图总值 = 本机 + 电脑端）', () {
    test('同一天相加、只有电脑端的那天也在表里', () {
      final merged = mergeDailySeconds(
        {'2026-09-08': 600},
        {'2026-09-08': 300, '2026-09-01': 900},
      );
      expect(merged, {'2026-09-08': 900, '2026-09-01': 900});
    });

    test('本机独有的天保留；非正数一律不出现', () {
      final merged = mergeDailySeconds(
        {'2026-09-08': 600, '2026-09-07': 0},
        {'2026-09-06': -10},
      );
      expect(merged, {'2026-09-08': 600});
    });

    test('两张表都空 → 空表', () {
      expect(mergeDailySeconds(const {}, const {}), isEmpty);
    });

    test('不修改入参（纯函数）', () {
      final local = {'2026-09-08': 10};
      final remote = {'2026-09-08': 5};
      mergeDailySeconds(local, remote);
      expect(local, {'2026-09-08': 10});
      expect(remote, {'2026-09-08': 5});
    });
  });
}
