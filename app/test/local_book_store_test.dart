// 本地书存储单测（E1）。
//
// 全部在**临时目录**里真跑文件读写（`rootDirOverride` 注入）：这一层的 bug
// 基本都是文件系统语义（原子写、清单与正文成对、目录名与 id 一致），
// mock 掉 IO 等于没测。
//
// 另外单独覆盖「测试宿主不碰 path_provider」：不注入目录时 import → null、
// getBooks → 空，而不是挂住或抛异常（见 DEV_CONTEXT 第 6.2 条）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/local_book_store.dart';

const String _sample = '第一章 风起\n'
    '这是第一章的正文。\n'
    '第二章 云涌\n'
    '这是第二章的正文。\n'
    '第三章 雨落\n'
    '这是第三章的正文。\n';

void main() {
  late Directory root;
  late LocalBookStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('amo_local_book_test_');
    store = LocalBookStore();
    store.rootDirOverride = root;
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶尔句柄没放开，删不掉就交给系统临时目录清理
    }
  });

  Directory bookDir(String id) => Directory('${root.path}/reader/local/$id');

  group('导入与读取', () {
    test('importTxt 落盘：正文 + 清单 + 章节偏移都对', () async {
      final book = await store.importTxt(
        name: '测试书.txt',
        text: _sample,
        encoding: 'gbk',
        sizeBytes: 123,
      );
      expect(book, isNotNull);
      expect(book!.name, '测试书', reason: '扩展名要去掉');
      expect(book.format, 'txt');
      expect(book.encoding, 'gbk');
      expect(book.sizeBytes, 123);
      expect(book.chapterCount, 3);
      expect(book.chapters.map((c) => c.title), ['第一章 风起', '第二章 云涌', '第三章 雨落']);

      // 落盘事实
      final dir = bookDir(book.id);
      expect(File('${dir.path}/book.txt').existsSync(), isTrue);
      expect(File('${dir.path}/manifest.json').existsSync(), isTrue);
      expect(File('${dir.path}/book.txt').readAsStringSync(), _sample);
      expect(File('${dir.path}/book.txt.tmp').existsSync(), isFalse, reason: '不能留 .tmp 残片');

      final manifest = jsonDecode(
        File('${dir.path}/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['id'], book.id);
      expect(manifest['name'], '测试书');
      expect(manifest['format'], 'txt');
      expect(manifest['encoding'], 'gbk');
      expect((manifest['chapters'] as List).length, 3);
      expect(manifest['importedAt'], greaterThan(0));
    });

    test('readChapter 逐章内容正确（含章标题行）', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample))!;
      expect(await store.readChapter(book.id, 0), '第一章 风起\n这是第一章的正文。\n');
      expect(await store.readChapter(book.id, 1), '第二章 云涌\n这是第二章的正文。\n');
      expect(await store.readChapter(book.id, 2), '第三章 雨落\n这是第三章的正文。\n');
    });

    test('readChapter 越界 / 不存在的书 → null（不抛）', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample))!;
      expect(await store.readChapter(book.id, 3), isNull);
      expect(await store.readChapter(book.id, -1), isNull);
      expect(await store.readChapter('nope', 0), isNull);
      expect(await store.readChapter('', 0), isNull);
    });

    test('getBook / getBooks 往返，字段一致', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample, author: '某某'))!;
      final got = await store.getBook(book.id);
      expect(got, isNotNull);
      expect(got!.name, '测试书');
      expect(got.author, '某某');
      expect(got.chapterCount, 3);
      expect(got.detailUrl, 'local:${book.id}');

      final all = await store.getBooks();
      expect(all.length, 1);
      expect(all.single.id, book.id);
    });

    test('空文本 / 空白文本 / 空书名 → null（不落盘）', () async {
      expect(await store.importTxt(name: 'x', text: ''), isNull);
      expect(await store.importTxt(name: 'x', text: '   \n\n'), isNull);
      expect(await store.importTxt(name: '   ', text: _sample), isNull);
      expect(await store.getBooks(), isEmpty);
    });
  });

  group('幂等与去重', () {
    test('同名同内容重复导入 → 同一个 id，书架不会多出一本', () async {
      final a = (await store.importTxt(name: '书.txt', text: _sample))!;
      final b = (await store.importTxt(name: '书.txt', text: _sample))!;
      expect(b.id, a.id);
      expect((await store.getBooks()).length, 1);
    });

    test('同名但内容不同 → 两个 id，两本', () async {
      final a = (await store.importTxt(name: '书.txt', text: _sample))!;
      final b = (await store.importTxt(
        name: '书.txt',
        text: '第一章 另一个故事\n完全不同的正文内容，长度也不一样。\n',
      ))!;
      expect(b.id, isNot(a.id));
      expect((await store.getBooks()).length, 2);
    });

    test('id 只含 [0-9a-f]，定长 16 位（目录名安全）', () async {
      final book = (await store.importTxt(name: '带 空格/斜杠 的书名?.txt', text: _sample))!;
      expect(book.id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(bookDir(book.id).existsSync(), isTrue);
    });

    test('localBookIdFor 稳定：同输入同输出', () {
      expect(localBookIdFor('书', _sample), localBookIdFor('书', _sample));
      expect(localBookIdFor('书', _sample), isNot(localBookIdFor('书2', _sample)));
    });
  });

  group('删除与统计', () {
    test('removeBook 删目录，幂等', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample))!;
      expect(await store.removeBook(book.id), isTrue);
      expect(bookDir(book.id).existsSync(), isFalse);
      expect(await store.getBooks(), isEmpty);
      // 再删一次也成功（幂等）
      expect(await store.removeBook(book.id), isTrue);
      expect(await store.removeBook(''), isFalse);
    });

    test('stats 报本数 + 字节数（以清单为准）', () async {
      await store.importTxt(name: 'a', text: _sample, sizeBytes: 1000);
      await store.importTxt(
        name: 'b',
        text: '第一章 x\n另一本书的正文。\n',
        sizeBytes: 2000,
      );
      final stats = await store.stats();
      expect(stats.books, 2);
      expect(stats.bytes, 3000);
      expect(stats.label, contains('2 本'));
    });

    test('clearAll 清空', () async {
      await store.importTxt(name: '测试书', text: _sample);
      await store.clearAll();
      expect(await store.getBooks(), isEmpty);
      expect(Directory('${root.path}/reader/local').existsSync(), isFalse);
    });
  });

  group('坏数据兜底', () {
    test('坏 manifest 的目录被跳过，不影响其它书', () async {
      final good = (await store.importTxt(name: '好', text: _sample))!;
      final badDir = Directory('${root.path}/reader/local/badbadbadbadbad');
      badDir.createSync(recursive: true);
      File('${badDir.path}/manifest.json').writeAsStringSync('{不是 JSON');
      File('${badDir.path}/book.txt').writeAsStringSync('x');

      final all = await store.getBooks();
      expect(all.map((b) => b.id), [good.id]);
      expect(await store.getBook('badbadbadbadbad'), isNull);
    });

    test('清单里没有章节 → 当作坏数据跳过', () async {
      final dir = Directory('${root.path}/reader/local/0000000000000000');
      dir.createSync(recursive: true);
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode({'id': '0000000000000000', 'name': '空书', 'chapters': []}),
      );
      expect(await store.getBooks(), isEmpty);
    });

    test('偏移被改坏（end 超长 / start > end）不崩、不读错', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample))!;
      final dir = bookDir(book.id);
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'id': book.id,
          'name': '测试书',
          'chapters': [
            {'title': '甲', 'start': 0, 'end': 999999},
            {'title': '乙', 'start': 50, 'end': 10},
          ],
          'importedAt': 1,
        }),
      );
      final reread = await store.getBook(book.id);
      // end <= start 的坏章在解析时就被丢掉
      expect(reread!.chapterCount, 1);
      final body = await store.readChapter(book.id, 0);
      expect(body, _sample, reason: 'end 超长要夹到全文长度，不是抛异常');
    });

    test('正文文件被外部删掉 → readChapter null', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample))!;
      File('${bookDir(book.id).path}/book.txt').deleteSync();
      expect(await store.readChapter(book.id, 0), isNull);
    });
  });

  group('与书架的键约定', () {
    test('local:<id> 是伪 URL：normalizeUrl 不改写，可直接当书架键', () {
      const url = 'local:0123456789abcdef';
      expect(isLocalBookUrl(url), isTrue);
      expect(localBookIdFromUrl(url), '0123456789abcdef');
      expect(bookKeyFor(url), url, reason: '书架唯一键会原样保留 local: 前缀');
      expect(isLocalBookUrl('https://x.example/book/1'), isFalse);
      expect(localBookIdFromUrl('https://x.example/book/1'), isNull);
      expect(localBookIdFromUrl('local:'), isNull);
      expect(localBookDetailUrl('abc'), 'local:abc');
    });
  });

  group('测试宿主（不注入目录）', () {
    test('不碰 path_provider：import → null、getBooks → 空（不挂住）', () async {
      final naked = LocalBookStore();
      expect(LocalBookStore.isTestHost, isTrue, reason: 'flutter test 会设 FLUTTER_TEST');
      expect(await naked.importTxt(name: 'x', text: _sample), isNull);
      expect(await naked.getBooks(), isEmpty);
      expect(await naked.getBook('x'), isNull);
      expect(await naked.stats(), isA<LocalBookStats>());
      expect(await naked.readChapter('x', 0), isNull);
      expect(await naked.removeBook('x'), isFalse);
    });
  });
}
