// HistoryStore 单元测试：add/覆盖去重/倒序/上限裁剪/remove/clear/损坏容错。
// - 用 SharedPreferences.setMockInitialValues 注入内存存储，不碰原生插件
// - 「重新 getAll」模拟 App 重启后读取同一底层存储
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/history_store.dart';

HistoryEntry _entry(
  String bvid,
  int pageIndex,
  DateTime watchedAt, {
  String title = '标题',
  int positionMs = 30000,
  int durationMs = 120000,
  int cid = 100,
  List<PageInfo>? pages,
}) => HistoryEntry(
  bvid: bvid,
  pageIndex: pageIndex,
  cid: cid,
  title: title,
  cover: '',
  upName: 'UP主',
  durationMs: durationMs,
  positionMs: positionMs,
  watchedAt: watchedAt,
  pages: pages,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('空历史：getAll 返回空列表', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await HistoryStore.instance.getAll(), isEmpty);
  });

  test('add 后按 watchedAt 倒序返回', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    final t1 = DateTime(2026, 9, 1, 10);
    final t2 = DateTime(2026, 9, 2, 10); // 更新

    await store.addOrUpdate(_entry('BV1a', 0, t1));
    await store.addOrUpdate(_entry('BV2b', 0, t2));

    final list = await store.getAll();
    expect(list.map((e) => e.bvid).toList(), ['BV2b', 'BV1a']);
  });

  test('覆盖去重：同 bvid_pageIndex 更新而不新增，位置/时间取最新', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;

    await store.addOrUpdate(
      _entry('BV1a', 0, DateTime(2026, 9, 1, 10), positionMs: 1000),
    );
    await store.addOrUpdate(
      _entry('BV1a', 0, DateTime(2026, 9, 2, 10), positionMs: 90000),
    );
    // 不同 pageIndex 算不同条目
    await store.addOrUpdate(_entry('BV1a', 1, DateTime(2026, 9, 3, 10)));

    final list = await store.getAll();
    expect(list, hasLength(2));
    final hit = list.singleWhere((e) => e.bvid == 'BV1a' && e.pageIndex == 0);
    expect(hit.positionMs, 90000);
    expect(hit.watchedAt, DateTime(2026, 9, 2, 10));
    // 更新后时间最晚 → 排最前
    expect(list.first.key, 'BV1a_1');
  });

  test('上限裁剪：超过 maxEntries 保留最新 maxEntries 条', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    final n = HistoryStore.maxEntries + 5;

    for (var i = 0; i < n; i++) {
      await store.addOrUpdate(
        _entry('BV$i', 0, DateTime(2026, 9, 1).add(Duration(minutes: i))),
      );
    }

    final list = await store.getAll();
    expect(list, hasLength(HistoryStore.maxEntries));
    // 裁剪掉最早 5 条（BV0..BV4），保留 BV5..BV{n-1}，且最新 BV{n-1} 在最前
    expect(list.first.bvid, 'BV${n - 1}');
    expect(list.any((e) => e.bvid == 'BV0'), isFalse);
    expect(list.any((e) => e.bvid == 'BV4'), isFalse);
    expect(list.any((e) => e.bvid == 'BV5'), isTrue);
  });

  test('remove：只删指定 bvid_pageIndex，其余保留', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;

    await store.addOrUpdate(_entry('BV1a', 0, DateTime(2026, 9, 1)));
    await store.addOrUpdate(_entry('BV1a', 1, DateTime(2026, 9, 2)));
    await store.addOrUpdate(_entry('BV2b', 0, DateTime(2026, 9, 3)));

    await store.remove('BV1a', 0);

    final list = await store.getAll();
    expect(list.map((e) => e.key).toList(), ['BV2b_0', 'BV1a_1']);
  });

  test('clear：清空全部历史', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;

    await store.addOrUpdate(_entry('BV1a', 0, DateTime(2026, 9, 1)));
    await store.addOrUpdate(_entry('BV2b', 0, DateTime(2026, 9, 2)));
    expect(await store.getAll(), hasLength(2));

    await store.clear();

    expect(await store.getAll(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('history_store:entries'), isNull);
  });

  test('JSON 持久化：重新 getAll（模拟重启）后记录仍在，底层为 JSON 列表', () async {
    SharedPreferences.setMockInitialValues({});
    final store = HistoryStore.instance;
    await store.addOrUpdate(
      _entry(
        'BV1a',
        2,
        DateTime(2026, 9, 1, 12),
        pages: const [
          PageInfo(cid: 100, part: 'P1', duration: 60),
          PageInfo(cid: 101, part: 'P2', duration: 120),
        ],
      ),
    );

    final list = await store.getAll();
    expect(list, hasLength(1));
    expect(list.first.bvid, 'BV1a');
    expect(list.first.pageIndex, 2);
    expect(list.first.pages, isNotNull);
    expect(list.first.pages!.length, 2);
    expect(list.first.pages!.last.part, 'P2');

    // 底层存的就是 JSON 字符串（含分 P 序列化）
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('history_store:entries');
    expect(raw, isNotNull);
    expect(raw, contains('watchedAt'));
    expect(raw, contains('pages'));
  });

  test('数据损坏视为空历史（不崩溃）', () async {
    SharedPreferences.setMockInitialValues({
      'history_store:entries': 'not-json{{',
    });
    expect(await HistoryStore.instance.getAll(), isEmpty);
  });

  test('脏条目（空 bvid / 非 Map 元素）跳过，不崩溃', () async {
    SharedPreferences.setMockInitialValues({
      'history_store:entries':
          '[{"bvid":"","pageIndex":0},{"bvid":"BV1a","pageIndex":0,"watchedAt":"2026-09-01T10:00:00.000"},42]',
    });
    final list = await HistoryStore.instance.getAll();
    expect(list, hasLength(1));
    expect(list.first.bvid, 'BV1a');
  });

  test('损坏后 addOrUpdate 可自愈：重写后正常读取', () async {
    SharedPreferences.setMockInitialValues({
      'history_store:entries': 'garbage{{',
    });
    final store = HistoryStore.instance;

    await store.addOrUpdate(_entry('BV1a', 0, DateTime(2026, 9, 1)));

    final list = await store.getAll();
    expect(list, hasLength(1));
    expect(list.first.bvid, 'BV1a');
  });
}
