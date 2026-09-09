// SearchHistoryStore（搜索历史）单元测试。
// - shared_preferences.setMockInitialValues 注入内存存储，不碰原生插件
// - 去重置顶 / 重复去重 / 上限裁剪 / 持久化 / 单删 / 清空 / 损坏容错
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/search_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯函数 dedupeFront（去重置顶 + 上限裁剪）', () {
    test('新词置顶；空词忽略原样返回', () {
      expect(
        SearchHistoryStore.dedupeFront(['旧1', '旧2'], '新词'),
        ['新词', '旧1', '旧2'],
      );
      expect(SearchHistoryStore.dedupeFront(['旧1'], '  '), ['旧1']);
      expect(SearchHistoryStore.dedupeFront(['旧1'], ''), ['旧1']);
    });

    test('重复词去重并移到顶部（不产生两份）', () {
      expect(
        SearchHistoryStore.dedupeFront(['a', 'b', 'c'], 'b'),
        ['b', 'a', 'c'],
      );
      expect(
        SearchHistoryStore.dedupeFront(['a'], 'a'),
        ['a'],
      );
    });

    test('关键词首尾空格裁剪后再置顶', () {
      expect(
        SearchHistoryStore.dedupeFront(['bili'], '  bili  '),
        ['bili'],
      );
      expect(
        SearchHistoryStore.dedupeFront(['旧'], '  新  '),
        ['新', '旧'],
      );
    });

    test('超出 maxEntries 裁剪最旧（列表尾）', () {
      // base 为 [词0..词19]，词19 在列表尾 = 最旧；加 1 条超限裁 1 条
      final base = List.generate(20, (i) => '词$i');
      final next = SearchHistoryStore.dedupeFront(base, '新词');
      expect(next.length, SearchHistoryStore.maxEntries);
      expect(next.first, '新词');
      // 尾部最旧被裁掉（词19），其余顺序保持（词0..词18 + 新词）
      expect(next.contains('词19'), isFalse);
      expect(next.contains('词0'), isTrue);
      expect(next, contains('词18'));
    });
  });

  group('add（去重置顶 + 持久化）', () {
    test('依次 add：新词置顶，列表新 → 旧', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear(); // 单例跨测试可能残留，先清
      await s.add('第一');
      await s.add('第二');
      await s.add('第三');
      expect(await s.getAll(), ['第三', '第二', '第一']);
    });

    test('重复词 add：去重并移到顶部', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear();
      await s.add('a');
      await s.add('b');
      await s.add('a');
      expect(await s.getAll(), ['a', 'b']);
    });

    test('空词 / 纯空格 add 忽略', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear();
      await s.add('词');
      await s.add('');
      await s.add('   ');
      expect(await s.getAll(), ['词']);
    });

    test('超过上限：新词置顶并裁剪最旧（20 条上限）', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear();
      for (var i = 0; i < 25; i++) {
        await s.add('关键词$i');
      }
      final all = await s.getAll();
      expect(all.length, SearchHistoryStore.maxEntries);
      expect(all.first, '关键词24'); // 最新置顶
      expect(all.contains('关键词0'), isFalse); // 最旧被裁
      expect(all.contains('关键词4'), isFalse);
    });

    test('持久化：新实例（模拟重启）读到同一份数据', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear();
      await s.add('重启前搜的词');

      final fresh = SearchHistoryStore(); // 新实例 = 新进程
      expect(await fresh.getAll(), ['重启前搜的词']);
    });
  });

  group('removeAt / clear', () {
    test('removeAt 删指定下标，其余顺序保持；越界忽略', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear();
      await s.add('a');
      await s.add('b');
      await s.add('c'); // 现在 [c, b, a]
      await s.removeAt(1); // 删 b
      expect(await s.getAll(), ['c', 'a']);
      await s.removeAt(0); // 删 c
      expect(await s.getAll(), ['a']);
      await s.removeAt(99); // 越界忽略
      await s.removeAt(-1);
      expect(await s.getAll(), ['a']);
    });

    test('clear 清空全部', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SearchHistoryStore.instance;
      await s.clear();
      await s.add('a');
      await s.add('b');
      await s.clear();
      expect(await s.getAll(), isEmpty);
    });
  });

  group('损坏容错', () {
    test('存储内容损坏（非 JSON / 非列表）→ 视为空历史，add 后自愈', () async {
      SharedPreferences.setMockInitialValues({
        SearchHistoryStore.storageKey: 'garbage{{',
      });
      final s = SearchHistoryStore.instance;
      expect(await s.getAll(), isEmpty);

      await s.add('自愈词');
      expect(await s.getAll(), ['自愈词']);

      SharedPreferences.setMockInitialValues({
        SearchHistoryStore.storageKey: '{"a":1}', // 合法 JSON 但不是 List
      });
      final s2 = SearchHistoryStore.instance;
      expect(await s2.getAll(), isEmpty);
    });

    test('脏元素（数字/布尔/null/空串/带空格词）读取时清洗', () async {
      SharedPreferences.setMockInitialValues({
        SearchHistoryStore.storageKey:
            '["好词", 123, true, null, "", "  空串净化 "]',
      });
      final s = SearchHistoryStore.instance;
      final all = await s.getAll();
      expect(all, ['好词', '空串净化']);
    });
  });
}
