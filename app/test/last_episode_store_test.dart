// 「集数记忆」存储（LastEpisodeStore，v2.57.0+）单元测试。
//
// 背景（用户原话）：「很多视频有集，我需要再次进入的时候有一个集数记忆」。
// 播放进度记忆（PlaybackProgress）本来就按 (bvid, pageIndex) 分开存，所以「上次
// 看到第几秒」从来不是问题；缺的是「上次看的是哪一集」——本 store 就是那把尺子。
//
// 覆盖：
//   1. 读写：无记忆 → null；写入后读得回；同一 bvid 覆盖；不同 bvid 互不影响；
//   2. 持久化：换一个 store 实例（模拟重启）仍读得到（数据在 prefs 里，不在内存）；
//   3. 容错：整份 JSON 坏 / 元素类型脏 / 负集号 → 视为无记忆（或跳过该条），不抛；
//   4. 上限裁剪：超过 maxEntries 裁掉最久未看的（纯函数 + 真实写盘两条路）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/last_episode_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('读写', () {
    test('无记忆 → null（空存储 / 空 bvid 都是）', () async {
      expect(await LastEpisodeStore.instance.lastPageIndex('BV1none'), isNull);
      expect(await LastEpisodeStore.instance.lastPageIndex(''), isNull);
    });

    test('写入后读得回；同一 bvid 覆盖；不同 bvid 互不影响', () async {
      final store = LastEpisodeStore.instance;
      await store.saveLastPageIndex('BV1aa', 2);
      await store.saveLastPageIndex('BV1bb', 5);
      expect(await store.lastPageIndex('BV1aa'), 2);
      expect(await store.lastPageIndex('BV1bb'), 5);

      await store.saveLastPageIndex('BV1aa', 4);
      expect(await store.lastPageIndex('BV1aa'), 4, reason: '同一视频只留最新的一集');
      expect(await store.lastPageIndex('BV1bb'), 5, reason: '别的视频不受影响');
    });

    test('第 1 集（0）也照记 —— "明确第 1 集"与"没记忆"是两件事', () async {
      final store = LastEpisodeStore.instance;
      await store.saveLastPageIndex('BV1zero', 0);
      expect(await store.lastPageIndex('BV1zero'), 0);
    });

    test('负集号 / 空 bvid 的脏调用不落盘', () async {
      final store = LastEpisodeStore.instance;
      await store.saveLastPageIndex('BV1bad', -1);
      await store.saveLastPageIndex('', 3);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LastEpisodeStore.storageKey), isNull);
    });

    test('持久化：新建实例（模拟重启）读的是同一份存储', () async {
      await LastEpisodeStore.instance.saveLastPageIndex('BV1boot', 3);
      // 新实例**不带内存副本**（本类每次读盘），等价于"重启后再读"
      final reopened = LastEpisodeStore();
      expect(await reopened.lastPageIndex('BV1boot'), 3);
    });

    test('clear 清空全部记忆', () async {
      final store = LastEpisodeStore.instance;
      await store.saveLastPageIndex('BV1clr', 2);
      await store.clear();
      expect(await store.lastPageIndex('BV1clr'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LastEpisodeStore.storageKey), isNull);
    });
  });

  group('损坏容错（记忆坏了最多回第 1 集，不能崩）', () {
    test('整份 JSON 不是对象 / 解析失败 → 视为无记忆', () async {
      final store = LastEpisodeStore.instance;
      final prefs = await SharedPreferences.getInstance();
      for (final bad in ['not json', '[1,2,3]', '"str"', '{']) {
        await prefs.setString(LastEpisodeStore.storageKey, bad);
        expect(await store.lastPageIndex('BV1any'), isNull, reason: '脏值：$bad');
      }
    });

    test('单条脏元素跳过，其它条目照常可读', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        LastEpisodeStore.storageKey,
        jsonEncode({
          'BV1ok': {'pageIndex': 3, 'updatedAt': 100},
          'BV1str': {'pageIndex': 'oops', 'updatedAt': 100}, // 类型脏
          'BV1neg': {'pageIndex': -2, 'updatedAt': 100}, // 负下标
          'BV1scalar': 7, // 不是对象
          'BV1noa': 'x',
        }),
      );
      final map = LastEpisodeStore.readMap(prefs);
      expect(map.keys, ['BV1ok'], reason: '脏条目逐条跳过，不连坐整份数据');
      expect(map['BV1ok']!['pageIndex'], 3);
      expect(await LastEpisodeStore.instance.lastPageIndex('BV1ok'), 3);
    });
  });

  group('上限裁剪（防无限增长）', () {
    test('upsert 纯函数：超出 maxEntries 裁掉 updatedAt 最小的', () {
      var map = <String, Map<String, int>>{};
      for (var i = 0; i < 3; i++) {
        map = LastEpisodeStore.upsert(
          map,
          bvid: 'BV1old$i',
          pageIndex: i,
          updatedAt: 1000 + i,
          maxEntries: 3,
        );
      }
      expect(map.keys, ['BV1old0', 'BV1old1', 'BV1old2']);

      // 第 4 条进来：最旧的 BV1old0（updatedAt 1000）被裁掉
      map = LastEpisodeStore.upsert(
        map,
        bvid: 'BV1new',
        pageIndex: 7,
        updatedAt: 5000,
        maxEntries: 3,
      );
      expect(map.keys, isNot(contains('BV1old0')));
      expect(map['BV1new']!['pageIndex'], 7);
      expect(map, hasLength(3));
    });

    test('upsert 纯函数：重看一个旧 bvid 会刷新时间戳，因此不再是最旧', () {
      var map = <String, Map<String, int>>{};
      for (var i = 0; i < 3; i++) {
        map = LastEpisodeStore.upsert(
          map,
          bvid: 'BV1x$i',
          pageIndex: 0,
          updatedAt: 1000 + i,
          maxEntries: 3,
        );
      }
      // 重看最旧的 BV1x0 → 时间戳变最新
      map = LastEpisodeStore.upsert(
        map,
        bvid: 'BV1x0',
        pageIndex: 4,
        updatedAt: 9000,
        maxEntries: 3,
      );
      // 再进一个新视频 → 被裁的应是 BV1x1（1001），不是刚看过的 BV1x0
      map = LastEpisodeStore.upsert(
        map,
        bvid: 'BV1xnew',
        pageIndex: 1,
        updatedAt: 9500,
        maxEntries: 3,
      );
      expect(map.keys, isNot(contains('BV1x1')));
      expect(map['BV1x0']!['pageIndex'], 4, reason: '刚看过的不能被裁');
      expect(map, hasLength(3));
    });

    test('真实写盘：超过 maxEntries 后总量停在 maxEntries（裁最久未看的）',
        () async {
      final store = LastEpisodeStore.instance;
      final total = LastEpisodeStore.maxEntries + 5;
      for (var i = 0; i < total; i++) {
        // nowMs 显式递增：裁剪结果不依赖真实时钟
        await store.saveLastPageIndex('BV1cap$i', i, nowMs: 1000 + i);
      }
      final prefs = await SharedPreferences.getInstance();
      final map = LastEpisodeStore.readMap(prefs);
      expect(map, hasLength(LastEpisodeStore.maxEntries));
      // 最早写的那 5 条被裁掉，最新的那条还在
      expect(map.containsKey('BV1cap0'), isFalse);
      expect(map.containsKey('BV1cap4'), isFalse);
      expect(map.containsKey('BV1cap5'), isTrue);
      expect(map.containsKey('BV1cap${total - 1}'), isTrue);
      expect(await store.lastPageIndex('BV1cap${total - 1}'), total - 1);
    });
  });
}
