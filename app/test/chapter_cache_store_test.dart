// 章节离线缓存存储测试（C 批）。
//
// 全部在**临时目录**里真跑文件读写（`rootDirOverride` 注入）：这一层的 bug
// 基本都是文件系统语义（原子写、清单累加、删目录），mock 掉 IO 就等于没测。
//
// 重点覆盖四类容易悄悄坏掉的点：
// 1. 往返：写进去的正文能原样读回来，清单字段（url/bytes/totalChapters）对；
// 2. 目录安全：URL 不当目录名，且同一 URL 永远同一个目录、不同 URL 不撞车；
// 3. 上限：**明确拒绝并带原因**（不是静默丢最旧的）；
// 4. 兜底：坏清单、`.tmp` 残留、url 不一致都不许崩、不许读错章。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/chapter_cache_store.dart';

ChapterCacheEntry _entry(String body, {String name = '第1章', String url = ''}) =>
    ChapterCacheEntry(name: name, url: url, body: body);

void main() {
  late Directory root;
  late ChapterCacheStore store;

  const bookKey = 'https://x.example/book/1';
  const chapterUrl = 'https://x.example/book/1/0';

  setUp(() {
    root = Directory.systemTemp.createTempSync('amo_cache_test_');
    store = ChapterCacheStore();
    store.rootDirOverride = root;
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶尔有句柄没放开，删不掉就留给系统临时目录清理
    }
  });

  Directory bookDir(String key) =>
      Directory('${root.path}/reader/cache/${cacheDirNameFor(key)}');

  group('写读往返', () {
    test('save → read 原样返回，清单字段齐全', () async {
      final saved = await store.saveChapter(
        bookKey,
        0,
        _entry('第一段\n第二段', name: '第1章', url: chapterUrl),
        bookName: '测试书',
        sourceName: '源A',
        detailUrl: bookKey,
        totalChapters: 3,
      );
      expect(saved.ok, isTrue);

      expect(
        await store.readChapter(bookKey, 0, chapterUrl: chapterUrl),
        '第一段\n第二段',
      );

      final manifest = await store.readManifest(bookKey);
      expect(manifest, isNotNull);
      expect(manifest!.bookName, '测试书');
      expect(manifest.sourceName, '源A');
      expect(manifest.totalChapters, 3);
      expect(manifest.cached[0]!.name, '第1章');
      expect(manifest.cached[0]!.url, chapterUrl);
      expect(manifest.cached[0]!.bytes, greaterThan(0));
      expect(manifest.updatedAt, greaterThan(0));
    });

    test('清单累加：两章 → 两章都被记住，总大小是两章之和', () async {
      await store.saveChapter(bookKey, 0, _entry('aaaa', url: '$chapterUrl/a'));
      await store.saveChapter(
        bookKey,
        1,
        _entry('bbbbbb', url: '$chapterUrl/b'),
        totalChapters: 2,
      );

      final stats = await store.stats(bookKey);
      expect(stats.cachedChapters, 2);
      expect(stats.totalChapters, 2);
      expect(stats.bytes, utf8.encode('aaaa').length + utf8.encode('bbbbbb').length);
      expect(stats.label, '已缓存 2/2 章');
    });

    test('同下标重写：覆盖内容，不重复计数、大小按新内容算', () async {
      await store.saveChapter(bookKey, 0, _entry('短', url: chapterUrl));
      await store.saveChapter(bookKey, 0, _entry('长一些的正文', url: chapterUrl));

      expect(await store.readChapter(bookKey, 0, chapterUrl: chapterUrl), '长一些的正文');
      final stats = await store.stats(bookKey);
      expect(stats.cachedChapters, 1);
      expect(stats.bytes, utf8.encode('长一些的正文').length);
    });
  });

  group('目录安全化', () {
    test('目录名是定长十六进制，不含 URL 里的任何字符', () {
      final name = cacheDirNameFor(bookKey);
      expect(name.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(name), isTrue);
      expect(name.contains('https'), isFalse);
      expect(cacheDirNameFor(bookKey), name, reason: '同一 URL 必须稳定');
      expect(cacheDirNameFor('https://x.example/book/2'), isNot(name));
      expect(cacheDirNameFor('  '), '', reason: '空键不产生目录名');
    });

    test('脏字符 / 超长 URL 也能落盘（不会被当成路径）', () async {
      const weird = 'https://x.example/书?p=1&q=2*<>|:"\\/../../etc/passwd';
      final saved = await store.saveChapter(weird, 0, _entry('正文'));
      expect(saved.ok, isTrue);
      // 真的只落在缓存根目录下面，没有跑出去
      expect(bookDir(weird).path.startsWith('${root.path}/reader/cache/'), isTrue);
      expect(await store.readChapter(weird, 0), '正文');
    });
  });

  group('章节地址校验', () {
    test('url 一致 → 命中；url 不一致 → 当未命中（规则改版后不许读错章）', () async {
      await store.saveChapter(
        bookKey,
        0,
        _entry('旧的第十二章', url: 'https://x.example/old/12'),
      );

      expect(
        await store.readChapter(bookKey, 0, chapterUrl: 'https://x.example/new/12'),
        isNull,
      );
      expect(
        await store.readChapter(bookKey, 0, chapterUrl: 'https://x.example/old/12'),
        '旧的第十二章',
      );
    });

    test('清单里没记 url（老数据）→ 带 url 读取时算未命中', () async {
      await store.saveChapter(bookKey, 0, _entry('正文'));
      expect(await store.readChapter(bookKey, 0, chapterUrl: chapterUrl), isNull);
      // 不传 url 时仍可读（批量缓存自己知道下标）
      expect(await store.readChapter(bookKey, 0), '正文');
    });

    test('没有清单但文件在 → 未命中（清单是唯一真相）', () async {
      await store.saveChapter(bookKey, 0, _entry('正文'));
      File('${bookDir(bookKey).path}/manifest.json').deleteSync();
      expect(await store.readChapter(bookKey, 0), isNull);
      expect((await store.stats(bookKey)).cachedChapters, 0);
    });
  });

  group('原子写', () {
    test('写完不残留 .tmp', () async {
      await store.saveChapter(bookKey, 0, _entry('正文'));
      final names = bookDir(bookKey)
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .toList();
      expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
      expect(names, containsAll(<String>['0.txt', 'manifest.json']));
    });

    test('上一次留下的 .tmp 会被覆盖掉，不会污染正文', () async {
      final dir = bookDir(bookKey);
      dir.createSync(recursive: true);
      File('${dir.path}/0.txt.tmp').writeAsStringSync('半截内容');
      await store.saveChapter(bookKey, 0, _entry('完整正文'));

      expect(await store.readChapter(bookKey, 0), '完整正文');
      expect(File('${dir.path}/0.txt.tmp').existsSync(), isFalse);
    });
  });

  group('上限', () {
    test('单本章数到顶 → 拒绝并给出章数原因', () async {
      final limited = ChapterCacheStore(maxBookChapters: 2);
      limited.rootDirOverride = root;

      expect((await limited.saveChapter(bookKey, 0, _entry('a'))).ok, isTrue);
      expect((await limited.saveChapter(bookKey, 1, _entry('b'))).ok, isTrue);
      final third = await limited.saveChapter(bookKey, 2, _entry('c'));
      expect(third.ok, isFalse);
      expect(third.failure, CacheSaveFailure.quota);
      expect(third.message, contains('上限'));
      // 已缓存的两章不受影响（拒绝新章，不是悄悄淘汰旧章）
      expect(await limited.readChapter(bookKey, 0), 'a');
      expect((await limited.stats(bookKey)).cachedChapters, 2);
    });

    test('单本字节到顶 → 拒绝并给出大小原因', () async {
      final limited = ChapterCacheStore(maxBookBytes: 8);
      limited.rootDirOverride = root;

      expect((await limited.saveChapter(bookKey, 0, _entry('123456'))).ok, isTrue);
      final second = await limited.saveChapter(bookKey, 1, _entry('123456'));
      expect(second.ok, isFalse);
      expect(second.failure, CacheSaveFailure.quota);
      expect(second.message, contains('MB'));
    });

    test('缓存总量到顶 → 拒绝并提示去清理', () async {
      final limited = ChapterCacheStore(maxTotalBytes: 10);
      limited.rootDirOverride = root;

      expect((await limited.saveChapter('book-a', 0, _entry('1234567'))).ok, isTrue);
      final second = await limited.saveChapter('book-b', 0, _entry('1234567'));
      expect(second.ok, isFalse);
      expect(second.failure, CacheSaveFailure.quota);
      expect(second.message, contains('清理'));
    });

    test('空 bookKey / 负下标 → 明确拒绝（不静默）', () async {
      final empty = await store.saveChapter('  ', 0, _entry('x'));
      expect(empty.ok, isFalse);
      expect(empty.failure, CacheSaveFailure.emptyBookKey);
      expect(empty.message, isNotNull);

      final negative = await store.saveChapter(bookKey, -1, _entry('x'));
      expect(negative.ok, isFalse);
      expect(negative.failure, CacheSaveFailure.invalidIndex);
    });
  });

  group('清理', () {
    test('removeBook 只删这一本，别的书还在', () async {
      await store.saveChapter('book-a', 0, _entry('a'));
      await store.saveChapter('book-b', 0, _entry('b'));

      await store.removeBook('book-a');
      expect((await store.stats('book-a')).cachedChapters, 0);
      expect(bookDir('book-a').existsSync(), isFalse);
      expect((await store.stats('book-b')).cachedChapters, 1);

      // 幂等
      await store.removeBook('book-a');
    });

    test('clearAll 清空整个缓存目录，之后还能继续用', () async {
      await store.saveChapter('book-a', 0, _entry('a'));
      await store.clearAll();
      expect(Directory('${root.path}/reader/cache').existsSync(), isFalse);

      expect((await store.saveChapter('book-a', 0, _entry('a2'))).ok, isTrue);
      expect(await store.readChapter('book-a', 0), 'a2');
    });
  });

  group('坏数据兜底', () {
    test('manifest 是坏 JSON → 不崩，读/统计按空处理，写入能重建', () async {
      final dir = bookDir(bookKey);
      dir.createSync(recursive: true);
      File('${dir.path}/manifest.json').writeAsStringSync('{这不是 json');

      expect(await store.readManifest(bookKey), isNull);
      expect((await store.stats(bookKey)).cachedChapters, 0);
      expect(await store.readChapter(bookKey, 0), isNull);

      expect((await store.saveChapter(bookKey, 0, _entry('新正文'))).ok, isTrue);
      expect(await store.readChapter(bookKey, 0), '新正文');
      expect((await store.stats(bookKey)).cachedChapters, 1);
    });

    test('清单里坏条目逐条跳过，好条目保留', () async {
      final dir = bookDir(bookKey);
      dir.createSync(recursive: true);
      File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
        'bookName': '书',
        'totalChapters': 5,
        'cached': {
          '0': {'name': '好', 'url': '', 'bytes': 10, 'savedAt': 1},
          'x': {'name': '坏下标'},
          '1': '不是对象',
        },
      }));

      final manifest = await store.readManifest(bookKey);
      expect(manifest, isNotNull);
      expect(manifest!.cached.keys, [0]);
      expect(manifest.totalChapters, 5);
    });
  });
}
