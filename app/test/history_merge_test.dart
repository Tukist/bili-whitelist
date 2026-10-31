// 历史合并（v2.57.0+）单元测试：去重 / 进度"更近者优先" / 本机独有不丢 /
// 来源标记 / 上限裁剪 / 上次同步时间。
// - 用 SharedPreferences.setMockInitialValues 注入内存存储，不碰原生插件
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

HistoryEntry _entry(
  String bvid,
  int pageIndex,
  DateTime watchedAt, {
  String title = '标题',
  String cover = '',
  String upName = 'UP主',
  int positionMs = 30000,
  int durationMs = 120000,
  int cid = 100,
  List<PageInfo>? pages,
  int? pubdate,
  HistorySource source = HistorySource.local,
  bool inWhitelist = true,
}) =>
    HistoryEntry(
      bvid: bvid,
      pageIndex: pageIndex,
      cid: cid,
      title: title,
      cover: cover,
      upName: upName,
      durationMs: durationMs,
      positionMs: positionMs,
      watchedAt: watchedAt,
      pages: pages,
      pubdate: pubdate,
      source: source,
      inWhitelist: inWhitelist,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('远程新条目：新增并标 source=bilibili；本机记录一条都不丢', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BVlocal', 0, DateTime(2026, 9, 1, 10)));

    final r = await store.mergeRemote([
      _entry('BVremote', 0, DateTime(2026, 9, 2, 10),
          source: HistorySource.bilibili),
    ]);

    expect(r.added, 1);
    expect(r.updated, 0);
    final all = await store.getAll();
    expect(all, hasLength(2));
    expect(all.map((e) => e.bvid), ['BVremote', 'BVlocal']);
    expect(all.first.source, HistorySource.bilibili);
    expect(all.last.source, HistorySource.local, reason: '本机独有条目来源不变');
  });

  test('同 (bvid, pageIndex) 去重：远程更新而不是新插一条，来源标 both', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BV1', 0, DateTime(2026, 9, 1, 10)));

    final r = await store.mergeRemote([
      _entry('BV1', 0, DateTime(2026, 9, 1, 10),
          source: HistorySource.bilibili),
    ]);

    expect(r.added, 0);
    expect(r.updated, 1);
    final all = await store.getAll();
    expect(all, hasLength(1), reason: '同一条观看记录只留一条');
    expect(all.single.source, HistorySource.both);
  });

  test('不同分 P 是两条记录（key 含 pageIndex）', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BV1', 0, DateTime(2026, 9, 1, 10)));

    final r = await store.mergeRemote([
      _entry('BV1', 1, DateTime(2026, 9, 2, 10),
          source: HistorySource.bilibili),
    ]);

    expect(r.added, 1);
    expect((await store.getAll()).map((e) => e.key).toList(),
        ['BV1_1', 'BV1_0']);
  });

  test('进度取舍：本机看得更近 → 保留本机进度与时间', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    final localAt = DateTime(2026, 9, 3, 10);
    await store.addOrUpdate(
      _entry('BV1', 0, localAt, positionMs: 99000, source: HistorySource.local),
    );

    await store.mergeRemote([
      // 远程更早（9-1），进度更小
      _entry('BV1', 0, DateTime(2026, 9, 1, 10),
          positionMs: 5000, source: HistorySource.bilibili),
    ]);

    final e = (await store.getAll()).single;
    expect(e.positionMs, 99000, reason: '本机更近 → 用本机进度');
    expect(e.watchedAt, localAt);
    expect(e.source, HistorySource.both);
  });

  test('进度取舍：远程看得更近 → 用远程进度与远程时间', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(
      _entry('BV1', 0, DateTime(2026, 9, 1, 10), positionMs: 5000),
    );
    final remoteAt = DateTime(2026, 9, 5, 10);

    await store.mergeRemote([
      _entry('BV1', 0, remoteAt, positionMs: 66000,
          source: HistorySource.bilibili),
    ]);

    final e = (await store.getAll()).single;
    expect(e.positionMs, 66000, reason: '远程更近 → 用远程进度');
    expect(e.watchedAt, remoteAt);
  });

  test('元信息：本机那份非空就保留，本机缺的用远程补', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry(
      'BV1',
      0,
      DateTime(2026, 9, 1, 10),
      title: '本机标题',
      cover: '', // 本机缺封面
      upName: '', // 本机缺 UP 主
      durationMs: 0, // 本机缺时长
    ));

    await store.mergeRemote([
      _entry(
        'BV1',
        0,
        DateTime(2026, 9, 5, 10),
        title: '远程标题',
        cover: 'http://r/c.jpg',
        upName: '远程UP',
        durationMs: 300000,
        source: HistorySource.bilibili,
      ),
    ]);

    final e = (await store.getAll()).single;
    expect(e.title, '本机标题', reason: '本机标题非空 → 不被远程覆盖');
    expect(e.cover, 'http://r/c.jpg');
    expect(e.upName, '远程UP');
    expect(e.durationMs, 300000);
  });

  test('空远程列表：什么都不做（不写存储、不报新增）', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BVlocal', 0, DateTime(2026, 9, 1)));

    final r = await store.mergeRemote(const []);
    expect(r.added, 0);
    expect(r.updated, 0);
    expect(await store.getAll(), hasLength(1));
  });

  test('脏远程条目（空 bvid）不进表', () async {
    SharedPreferences.setMockInitialValues({});
    final r = await HistoryStore.instance.mergeRemote([
      _entry('', 0, DateTime(2026, 9, 1), source: HistorySource.bilibili),
    ]);
    expect(r.added, 0);
    expect(await HistoryStore.instance.getAll(), isEmpty);
  });

  test('合并后超过上限仍按 watchedAt 倒序裁最早（本机老记录会被裁）', () async {
    // 直接塞满 1000 条（比逐条 addOrUpdate 快得多）
    final seed = <Map<String, dynamic>>[
      for (var i = 0; i < HistoryStore.maxEntries; i++)
        _entry('BV$i', 0, DateTime(2026, 1, 1).add(Duration(minutes: i)))
            .toJson(),
    ];
    SharedPreferences.setMockInitialValues({
      'history_store:entries': jsonEncode(seed),
    });

    final r = await HistoryStore.instance.mergeRemote([
      _entry('BVnew', 0, DateTime(2026, 12, 31), source: HistorySource.bilibili),
    ]);

    expect(r.added, 1);
    final all = await HistoryStore.instance.getAll();
    expect(all, hasLength(HistoryStore.maxEntries));
    expect(all.first.bvid, 'BVnew');
    expect(all.any((e) => e.bvid == 'BVnew'), isTrue);
    // 最老的那条被裁掉
    expect(all.any((e) => e.bvid == 'BV0'), isFalse);
  });

  test('source 持久化：只有非 local 才落 "source" 字段（旧记录形态不变）',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(_entry('BVlocal', 0, DateTime(2026, 9, 1)));
    await store.mergeRemote([
      _entry('BVremote', 0, DateTime(2026, 9, 2),
          source: HistorySource.bilibili),
    ]);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('history_store:entries')!;
    expect(raw, contains('"source":"bilibili"'));
    // 本机条目不带 source 键
    final localObj = (await store.getAll())
        .singleWhere((e) => e.bvid == 'BVlocal')
        .toJson();
    expect(localObj.containsKey('source'), isFalse);
  });

  test('source 解析：旧记录（无字段）→ local；脏值 → local', () {
    expect(HistorySource.parse(null), HistorySource.local);
    expect(HistorySource.parse('nonsense'), HistorySource.local);
    expect(HistorySource.parse('bilibili'), HistorySource.bilibili);
    expect(HistorySource.parse('both'), HistorySource.both);
    expect(HistorySource.local.jsonValue, isNull);
    expect(HistorySource.bilibili.jsonValue, 'bilibili');
  });

  group('「未在白名单」标记（v2.57.0 调整）', () {
    test('远程条目不在白名单 → 合并后带标记，且落盘写 inWhitelist:false', () async {
      SharedPreferences.setMockInitialValues({});
      final r = await HistoryStore.instance.mergeRemote([
        _entry('BVout', 0, DateTime(2026, 9, 2),
            source: HistorySource.bilibili, inWhitelist: false),
      ]);

      expect(r.added, 1);
      final all = await HistoryStore.instance.getAll();
      expect(all.single.inWhitelist, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('history_store:entries'),
          contains('"inWhitelist":false'));
    });

    test('白名单内条目**不写**该字段（旧记录形态逐字不变）', () async {
      SharedPreferences.setMockInitialValues({});
      await HistoryStore.instance.mergeRemote([
        _entry('BVin', 0, DateTime(2026, 9, 2),
            source: HistorySource.bilibili, inWhitelist: true),
      ]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('history_store:entries'),
          isNot(contains('inWhitelist')));
      expect((await HistoryStore.instance.getAll()).single.inWhitelist, isTrue);
    });

    test('旧记录（没有该字段）读出来是 true（与改动前逐像素一致）', () async {
      SharedPreferences.setMockInitialValues({
        'history_store:entries': jsonEncode([
          _entry('BVold', 0, DateTime(2026, 1, 1)).toJson(),
        ]),
      });
      final e = (await HistoryStore.instance.getAll()).single;
      expect(e.inWhitelist, isTrue);
      expect(e.toJson().containsKey('inWhitelist'), isFalse);
    });

    test('合并时白名单归属以远程为准：加进白名单 → 标记消失；移出 → 出现',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = HistoryStore.instance;
      // 先用"不在白名单"的远程条目建一条带标记的记录
      await store.mergeRemote([
        _entry('BV1', 0, DateTime(2026, 9, 1),
            source: HistorySource.bilibili, inWhitelist: false),
      ]);
      expect((await store.getAll()).single.inWhitelist, isFalse);

      // 用户把它加进白名单后又同步了一次 → 远程说"在白名单"
      await store.mergeRemote([
        _entry('BV1', 0, DateTime(2026, 9, 2),
            source: HistorySource.bilibili, inWhitelist: true),
      ]);
      expect((await store.getAll()).single.inWhitelist, isTrue,
          reason: '标记要能自动消失（不以旧快照为准）');

      // 又被移出白名单 → 标记重新出现
      await store.mergeRemote([
        _entry('BV1', 0, DateTime(2026, 9, 3),
            source: HistorySource.bilibili, inWhitelist: false),
      ]);
      expect((await store.getAll()).single.inWhitelist, isFalse);
    });

    test('本机播放写历史（addOrUpdate）不抹掉「不在白名单」标记', () async {
      SharedPreferences.setMockInitialValues({});
      final store = HistoryStore.instance;
      await store.mergeRemote([
        _entry('BV1', 0, DateTime(2026, 9, 1),
            source: HistorySource.bilibili, inWhitelist: false),
      ]);

      // 播放页写历史时并不知道白名单归属（默认 true）→ 不许覆盖已有标记
      await store.addOrUpdate(
          _entry('BV1', 0, DateTime(2026, 9, 2), positionMs: 60000));

      final e = (await store.getAll()).single;
      expect(e.inWhitelist, isFalse);
      expect(e.positionMs, 60000, reason: '其它字段仍按播放结果更新');
    });
  });

  test('上次同步时间：没同步过 → null；写入后读回一致', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    expect(await store.readLastSyncAt(), isNull);

    final at = DateTime(2026, 9, 8, 12, 34, 56);
    await store.saveLastSyncAt(at);
    expect(await store.readLastSyncAt(), at);

    // 脏值 → null（不崩、界面显示"还没同步过"）
    SharedPreferences.setMockInitialValues({
      'history_store:last_sync_at': 'not-a-date',
    });
    expect(await store.readLastSyncAt(), isNull);
  });
}
