// 书架 / 进度 / 设置存储测试（R3）。
//
// 重点验三件事：
// 1. 增删改查与「唯一键 = 归一化 detailUrl」（尾斜杠差异不能变成两本书）；
// 2. 进度只保留最近 100 本（按 updatedAt），超限时丢最旧的；
// 3. 脏数据（非 JSON / 非对象 / 缺字段 / 越界数值）一律不崩、走默认值。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/bookshelf_store.dart';

ShelfBook _book(String name, String url, {int chapterCount = 10}) => ShelfBook(
      name: name,
      author: '作者',
      cover: 'https://x.example/c.jpg',
      sourceName: '源A',
      detailUrl: url,
      lastChapterName: '第$chapterCount章',
      addedAt: 1,
      chapterCount: chapterCount,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('书架', () {
    test('新书在前；同一本书（尾斜杠不同）覆盖而不是新增', () async {
      final store = BookshelfStore();
      expect(await store.saveBook(_book('甲', 'https://x.example/book/1')), isTrue);
      expect(
        await store.saveBook(_book('乙', 'https://x.example/book/2/')),
        isTrue,
      );

      var books = await store.getBooks();
      expect(books.map((b) => b.name).toList(), ['乙', '甲']);

      // 同一地址（带尾斜杠）→ 覆盖，保持原位置
      expect(
        await store.saveBook(_book('甲改名', 'https://x.example/book/1/')),
        isTrue,
      );
      books = await store.getBooks();
      expect(books.length, 2);
      expect(books[1].name, '甲改名');
    });

    test('唯一键归一化：尾斜杠与 &amp; 不影响判重', () {
      expect(
        bookKeyFor('https://x.example/book/1/'),
        bookKeyFor('https://x.example/book/1'),
      );
      expect(
        bookKeyFor('https://x.example/b?a=1&amp;b=2'),
        bookKeyFor('https://x.example/b?a=1&b=2'),
      );
    });

    test('删除幂等；不存在也算成功', () async {
      final store = BookshelfStore();
      await store.saveBook(_book('甲', 'https://x.example/book/1'));
      expect(await store.removeBook('https://x.example/book/1'), isTrue);
      expect(await store.getBooks(), isEmpty);
      expect(await store.removeBook('https://x.example/book/1'), isTrue);
    });

    test('超过 500 本拒绝写入（不静默丢书）', () async {
      final existing = [
        for (var i = 0; i < BookshelfStore.maxBooks; i++)
          {
            'name': '书$i',
            'detailUrl': 'https://x.example/book/$i',
          },
      ];
      SharedPreferences.setMockInitialValues({
        BookshelfStore.booksKey: jsonEncode(existing),
      });
      final store = BookshelfStore();
      expect(
        await store.saveBook(_book('第 501 本', 'https://x.example/book/501')),
        isFalse,
      );
      expect((await store.getBooks()).length, BookshelfStore.maxBooks);
    });

    test('脏数据：非 JSON / 非对象 / 缺书名的记录全部跳过', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfStore.booksKey:
            '[1, "x", {"name": "有名字没地址"}, {"detailUrl": "https://x/1"}]',
      });
      final store = BookshelfStore();
      expect(await store.getBooks(), isEmpty);

      // 完全不是 JSON 也不崩
      SharedPreferences.setMockInitialValues({
        BookshelfStore.booksKey: 'not-json',
      });
      expect(await store.getBooks(), isEmpty);
    });
  });

  group('进度', () {
    test('读写单本进度', () async {
      final store = BookshelfStore();
      expect(await store.getProgress('https://x.example/book/1'), isNull);

      expect(
        await store.saveProgress(
          'https://x.example/book/1/',
          const ReadingProgress(
            chapterIndex: 3,
            chapterName: '第4章',
            chapterUrl: 'https://x.example/4',
            scrollOffset: 128.5,
            updatedAt: 100,
          ),
        ),
        isTrue,
      );

      final p = await store.getProgress('https://x.example/book/1');
      expect(p, isNotNull);
      expect(p!.chapterIndex, 3);
      expect(p.chapterName, '第4章');
      expect(p.scrollOffset, 128.5);
    });

    test('只保留最近 100 本（按 updatedAt 丢最旧的）', () async {
      // 预置 100 本，updatedAt = 1..100
      final seeded = <String, dynamic>{
        for (var i = 0; i < 100; i++)
          'https://x.example/book/$i': {
            'chapterIndex': i,
            'chapterName': '第${i + 1}章',
            'updatedAt': i + 1,
          },
      };
      SharedPreferences.setMockInitialValues({
        BookshelfStore.progressKey: jsonEncode(seeded),
      });
      final store = BookshelfStore();

      // 新增一本 updatedAt = 999 → 应该挤掉 updatedAt 最小的那本（i=0）
      await store.saveProgress(
        'https://x.example/book/new',
        const ReadingProgress(
          chapterIndex: 0,
          chapterName: '新书第一章',
          updatedAt: 999,
        ),
      );

      expect(await store.getProgress('https://x.example/book/new'), isNotNull);
      expect(await store.getProgress('https://x.example/book/0'), isNull);
      expect(await store.getProgress('https://x.example/book/1'), isNotNull);

      // 总数仍不超过上限
      final prefs = await SharedPreferences.getInstance();
      final map = jsonDecode(prefs.getString(BookshelfStore.progressKey)!) as Map;
      expect(map.length, BookshelfStore.maxProgress);
    });

    test('updatedAt 为 0 时自动补当前时间（避免被当成最旧裁掉）', () async {
      final store = BookshelfStore();
      await store.saveProgress(
        'https://x.example/book/1',
        const ReadingProgress(chapterIndex: 1),
      );
      final p = await store.getProgress('https://x.example/book/1');
      expect(p!.updatedAt, greaterThan(0));
    });
  });

  group('设置', () {
    test('默认值 → 写读往返', () async {
      final store = BookshelfStore();
      final defaults = await store.getSettings();
      expect(defaults.fontSize, 18);
      expect(defaults.lineHeight, 1.8);
      expect(defaults.theme, 'auto');

      expect(
        await store.saveSettings(
          const ReaderSettings(fontSize: 22, lineHeight: 2.0, theme: 'dark'),
        ),
        isTrue,
      );
      final loaded = await store.getSettings();
      expect(loaded.fontSize, 22);
      expect(loaded.lineHeight, 2.0);
      expect(loaded.theme, 'dark');
    });

    test('越界 / 未知主题被夹取或回默认，不崩', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfStore.settingsKey:
            jsonEncode({'fontSize': 999, 'lineHeight': -1, 'theme': 'rainbow'}),
      });
      final s = await BookshelfStore().getSettings();
      expect(s.fontSize, 32); // clamp 上限
      expect(s.lineHeight, 1.2); // clamp 下限
      expect(s.theme, 'auto'); // 未知主题回默认
    });

    test('设置不是 JSON → 返回默认值', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfStore.settingsKey: '{{',
      });
      final s = await BookshelfStore().getSettings();
      expect(s.fontSize, ReaderSettings.defaults.fontSize);
      expect(s.theme, 'auto');
    });

    // ==================== v2.72.0 翻页方式 ====================

    test('pageMode 默认 scroll；写 paged 能读回', () async {
      final store = BookshelfStore();
      expect((await store.getSettings()).pageMode, 'scroll');
      expect(ReaderSettings.defaults.isPaged, isFalse);

      expect(
        await store.saveSettings(const ReaderSettings(pageMode: 'paged')),
        isTrue,
      );
      final loaded = await store.getSettings();
      expect(loaded.pageMode, 'paged');
      expect(loaded.isPaged, isTrue);

      // 切回滚动也要能存住
      await store.saveSettings(loaded.copyWith(pageMode: 'scroll'));
      expect((await store.getSettings()).pageMode, 'scroll');
    });

    test('旧数据没有 pageMode（v2.71 及更早）→ 回落 scroll', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfStore.settingsKey: jsonEncode({
          'fontSize': 20,
          'lineHeight': 1.6,
          'theme': 'paper',
        }),
      });
      final s = await BookshelfStore().getSettings();
      expect(s.pageMode, 'scroll');
      // 其它字段不能被连带改坏
      expect(s.fontSize, 20);
      expect(s.theme, 'paper');
    });

    test('pageMode 非法值：读时回落 scroll，写时归一成 scroll', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfStore.settingsKey: jsonEncode({'pageMode': 'flip'}),
      });
      expect((await BookshelfStore().getSettings()).pageMode, 'scroll');

      // 写侧也不许把脏值落盘（读侧回落是兜底，不是纵容）
      final store = BookshelfStore();
      await store.saveSettings(const ReaderSettings(pageMode: 'flip'));
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString(BookshelfStore.settingsKey)!) as Map;
      expect(raw['pageMode'], 'scroll');
    });
  });

  group('进度：分页模式的 pageIndex（v2.72.0）', () {
    test('pageIndex 写读往返；默认 0', () async {
      final store = BookshelfStore();
      const progress = ReadingProgress(chapterIndex: 2, pageIndex: 7);
      expect(progress.pageIndex, 7);
      expect(await store.saveProgress('https://x.example/book/1', progress), isTrue);

      final loaded = await store.getProgress('https://x.example/book/1');
      expect(loaded!.pageIndex, 7);
      // 旧字段语义不变：没给就不存滚动位置
      expect(loaded.scrollOffset, 0);
    });

    test('旧数据没有 pageIndex / 负数 → 0', () async {
      SharedPreferences.setMockInitialValues({
        BookshelfStore.progressKey: jsonEncode({
          'https://x.example/book/1': {
            'chapterIndex': 3,
            'scrollOffset': 512.5,
            'updatedAt': 1,
          },
          'https://x.example/book/2': {
            'chapterIndex': 0,
            'pageIndex': -9,
          },
        }),
      });
      final store = BookshelfStore();
      final a = await store.getProgress('https://x.example/book/1');
      expect(a!.pageIndex, 0);
      expect(a.scrollOffset, 512.5); // 滚动模式的老字段照旧
      final b = await store.getProgress('https://x.example/book/2');
      expect(b!.pageIndex, 0);
    });
  });
}
