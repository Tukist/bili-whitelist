// 加载文案池（lib/services/loading_copy.dart）单测：
// - 三个池的长度 / 无重复 / key 都能在 kDefaultCopies 里找到且非空
// - 挑选确定性：同 seed 同一条（不闪变、可测试）
// - 哈希分布没退化：足够多的 seed 能把整个池都走到
// - 用户覆盖优先（setOverride 后取到覆盖值）
// - 空池兜底
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/loading_copy.dart';
import 'package:bili_whitelist_app/services/ui_copy_store.dart';
import 'package:bili_whitelist_app/widgets/dot_halftone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UiCopyStore.instance.resetForTest();
    await UiCopyStore.instance.ensureLoaded();
  });

  // 覆盖表是全局单例状态，用例之间必须清干净
  tearDown(() => UiCopyStore.instance.resetForTest());

  group('池结构', () {
    test('长度 8 / 4 / 3', () {
      expect(kLoadingPoolPage.length, 8);
      expect(kLoadingPoolFooter.length, 4);
      expect(kLoadingPoolEmpty.length, 3);
    });

    test('池内无重复，且三个池两两不重叠', () {
      for (final pool in [kLoadingPoolPage, kLoadingPoolFooter, kLoadingPoolEmpty]) {
        expect(pool.toSet().length, pool.length, reason: '池内有重复 id: $pool');
      }
      final all = <String>{
        ...kLoadingPoolPage,
        ...kLoadingPoolFooter,
        ...kLoadingPoolEmpty,
      };
      expect(all.length, 15);
    });

    test('每个 key 都在 kDefaultCopies 里，且值非空', () {
      final store = UiCopyStore.instance;
      final all = <String>[
        ...kLoadingPoolPage,
        ...kLoadingPoolFooter,
        ...kLoadingPoolEmpty,
      ];
      for (final id in all) {
        expect(UiCopyStore.kDefaultCopies.containsKey(id), isTrue,
            reason: '$id 没有出厂默认值（会在界面上原样显形）');
        expect(UiCopyStore.kDefaultCopies[id], isNotEmpty, reason: '$id 是空值');
        // text() 走「覆盖 → 默认 → 原样返回 id」，无覆盖时必须等于默认值
        expect(store.text(id), UiCopyStore.kDefaultCopies[id], reason: id);
        expect(store.text(id), isNot(id), reason: '$id 回退成了 id 本身');
      }
    });

    test('池里的 15 条文案互不相同（不靠重复凑数）', () {
      final values = <String>{
        for (final id in [
          ...kLoadingPoolPage,
          ...kLoadingPoolFooter,
          ...kLoadingPoolEmpty,
        ])
          UiCopyStore.kDefaultCopies[id]!,
      };
      expect(values.length, 15);
    });
  });

  group('确定性挑选', () {
    test('同 seed 反复取都是同一条', () {
      for (var i = 0; i < 3; i++) {
        expect(loadingCopyFor(pool: kLoadingPoolPage, seed: 'playlist_page'),
            loadingCopyFor(pool: kLoadingPoolPage, seed: 'playlist_page'));
        expect(loadingCopyFor(pool: kLoadingPoolFooter, seed: 'home_more'),
            loadingCopyFor(pool: kLoadingPoolFooter, seed: 'home_more'));
      }
    });

    test('取到的条一定是池里的某一条（索引由 stableSeed 决定）', () {
      const seed = 'search_page';
      final expected = UiCopyStore.instance
          .text(kLoadingPoolPage[stableSeed(seed) % kLoadingPoolPage.length]);
      expect(loadingCopyFor(pool: kLoadingPoolPage, seed: seed), expected);
    });

    test('足够多的 seed 能走遍整个池（哈希分布没退化）', () {
      final hit = <String>{};
      for (var i = 0; i < 200; i++) {
        hit.add(loadingCopyFor(pool: kLoadingPoolPage, seed: 'page_$i'));
      }
      expect(hit.length, kLoadingPoolPage.length);
      // 命中的都是池里的默认值（没有串到别的池 / 没漏配）
      expect(
        hit,
        kLoadingPoolPage.map((id) => UiCopyStore.kDefaultCopies[id]!).toSet(),
      );
    });

    test('不同 seed 会分到不同条（不是恒定一条）', () {
      final values = <String>{
        for (var i = 0; i < 20; i++)
          loadingCopyFor(pool: kLoadingPoolFooter, seed: 'row_$i'),
      };
      expect(values.length, greaterThan(1));
    });
  });

  group('用户覆盖优先', () {
    test('setOverride 之后取到的是覆盖值', () async {
      const seed = 'favorites_page';
      final key = kLoadingPoolPage[stableSeed(seed) % kLoadingPoolPage.length];
      final before = loadingCopyFor(pool: kLoadingPoolPage, seed: seed);

      await UiCopyStore.instance.setOverride(key, '我自己写的一句');

      final after = loadingCopyFor(pool: kLoadingPoolPage, seed: seed);
      expect(after, '我自己写的一句');
      expect(after, isNot(before));
      expect(UiCopyStore.instance.hasOverride(key), isTrue);
    });

    test('覆盖清掉后回到默认', () async {
      const seed = 'history_page';
      final key = kLoadingPoolFooter[stableSeed(seed) % kLoadingPoolFooter.length];
      final original = UiCopyStore.instance.text(key);

      await UiCopyStore.instance.setOverride(key, '临时改的');
      expect(loadingCopyFor(pool: kLoadingPoolFooter, seed: seed), '临时改的');

      await UiCopyStore.instance.clearOverride(key);
      expect(loadingCopyFor(pool: kLoadingPoolFooter, seed: seed), original);
    });

    test('改 A 池的某条不影响 B 池的结果', () async {
      await UiCopyStore.instance.setOverride(kLoadingPoolEmpty.first, '空态覆盖');
      for (var i = 0; i < 20; i++) {
        final got = loadingCopyFor(pool: kLoadingPoolPage, seed: 'x_$i');
        expect(got, isNot('空态覆盖'));
      }
    });
  });

  group('兜底', () {
    test('空池返回空串（调用方据此退回无文案形态）', () {
      expect(loadingCopyFor(pool: const <String>[], seed: 'anything'), '');
    });
  });
}
