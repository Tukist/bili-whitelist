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
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/local_book_parser.dart';
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

      // 落盘事实（schema 2：一章一个文件，不再有整本 book.txt）
      final dir = bookDir(book.id);
      expect(File('${dir.path}/manifest.json').existsSync(), isTrue);
      expect(File('${dir.path}/chapters/0.txt').existsSync(), isTrue);
      expect(File('${dir.path}/chapters/2.txt').existsSync(), isTrue);
      expect(
        File('${dir.path}/chapters/0.txt').readAsStringSync(),
        '第一章 风起\n这是第一章的正文。\n',
      );
      expect(
        File('${dir.path}/book.txt').existsSync(),
        isFalse,
        reason: 'v2 不再留整本副本（章节文件就是正文）',
      );
      expect(
        File('${dir.path}/manifest.json.tmp').existsSync(),
        isFalse,
        reason: '不能留 .tmp 残片',
      );

      final manifest = jsonDecode(
        File('${dir.path}/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['schema'], 2);
      expect(manifest['id'], book.id);
      expect(manifest['name'], '测试书');
      expect(manifest['format'], 'txt');
      expect(manifest['encoding'], 'gbk');
      expect((manifest['chapters'] as List).length, 3);
      expect((manifest['chapters'] as List).first['file'], 'chapters/0.txt');
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
      // 造一份 v1 旧布局：整本 book.txt + 带偏移的旧清单（没有 schema）
      File('${dir.path}/book.txt').writeAsStringSync(_sample);
      Directory('${dir.path}/chapters').deleteSync(recursive: true);
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
      File('${bookDir(book.id).path}/chapters/0.txt').deleteSync();
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

  // ==================== E3：schema 2 与 v1 惰性迁移 ====================

  group('schema 2：一章一个文件', () {
    test('importParsedBook 往返：章节按序落盘，元信息进清单', () async {
      final book = await store.importParsedBook(
        name: '某 EPUB.epub',
        author: '作者乙',
        format: 'epub',
        chapters: const [
          ParsedChapter(title: '第一章', text: '第一段\n第二段'),
          ParsedChapter(title: '第二章', text: '另一章正文'),
        ],
        sizeBytes: 4096,
        idSeed: 'epub|某.epub|4096|head',
      );
      expect(book, isNotNull);
      expect(book!.name, '某 EPUB', reason: '扩展名要去掉');
      expect(book.format, 'epub');
      expect(book.author, '作者乙');
      expect(book.chapterCount, 2);

      final dir = bookDir(book.id);
      expect(File('${dir.path}/chapters/0.txt').readAsStringSync(), '第一段\n第二段');
      expect(File('${dir.path}/chapters/1.txt').readAsStringSync(), '另一章正文');
      expect(await store.readChapter(book.id, 0), '第一段\n第二段');
      expect(await store.readChapter(book.id, 1), '另一章正文');
      expect(await store.readChapter(book.id, 2), isNull);

      final got = (await store.getBook(book.id))!;
      expect(got.author, '作者乙');
      expect(got.format, 'epub');
      expect(got.sizeBytes, 4096);
    });

    test('封面按字节判断后缀并落盘，coverPath 指到真实文件', () async {
      final book = await store.importParsedBook(
        name: '有封面',
        format: 'epub',
        chapters: const [ParsedChapter(title: '第一章', text: '正文')],
        coverBytes: Uint8List.fromList(const [
          0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
        ]),
        idSeed: 'epub|a|1|x',
      );
      final dir = bookDir(book!.id);
      expect(File('${dir.path}/cover.jpg').existsSync(), isTrue);
      final got = (await store.getBook(book.id))!;
      expect(got.coverFile, 'cover.jpg');
      expect(got.coverPath, isNotNull);
      expect(File(got.coverPath!).existsSync(), isTrue);
    });

    test('不是 jpg / png 的封面字节 → 不写封面（宁可不显示也不写坏文件）', () async {
      final book = await store.importParsedBook(
        name: '怪封面',
        format: 'epub',
        chapters: const [ParsedChapter(title: '第一章', text: '正文')],
        coverBytes: Uint8List.fromList(const [1, 2, 3, 4, 5, 6]),
        idSeed: 'epub|b|2|y',
      );
      final got = (await store.getBook(book!.id))!;
      expect(got.coverFile, isEmpty);
      expect(got.coverPath, isNull);
      // 顶层只有 manifest（章节在 chapters/ 子目录里），没有任何封面文件
      final top = bookDir(book.id)
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(RegExp(r'[\\/]')).last)
          .toList();
      expect(top, ['manifest.json']);
    });

    test('同一 idSeed 重复导入 → 覆盖同一本，章节文件不叠加', () async {
      Future<LocalBook?> imp(String text) => store.importParsedBook(
            name: '同一本',
            format: 'epub',
            chapters: [ParsedChapter(title: '唯一章', text: text)],
            idSeed: 'epub|same|1|z',
          );
      final a = await imp('第一版正文');
      final b = await imp('第二版正文');
      expect(b!.id, a!.id);
      expect((await store.getBooks()).length, 1);
      expect(await store.readChapter(a.id, 0), '第二版正文');
      expect(File('${bookDir(a.id).path}/chapters/1.txt').existsSync(), isFalse,
          reason: '旧版本的章节文件要清掉');
    });

    test('章文件路径含 .. → 拒绝读（防清单被手改后读别的文件）', () async {
      final book = (await store.importTxt(name: '测试书', text: _sample))!;
      final dir = bookDir(book.id);
      File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
        'schema': 2,
        'id': book.id,
        'name': '测试书',
        'chapters': [
          {'title': '偷看', 'file': '../../secret.txt'},
        ],
        'importedAt': 1,
      }));
      expect(await store.readChapter(book.id, 0), isNull);
    });
  });

  group('v1 → schema 2 惰性迁移', () {
    // 一份 v2.72.0 时代的目录：整本 book.txt + 只记偏移的旧清单
    const String v1Text = '第一章 甲\n第一章正文。\n第二章 乙\n第二章正文。\n';
    final int a = v1Text.indexOf('第一章');
    final int b = v1Text.indexOf('第二章');

    String seedV1({String id = 'aaaaaaaaaaaaaaaa'}) {
      final dir = Directory('${root.path}/reader/local/$id')
        ..createSync(recursive: true);
      File('${root.path}/reader/local/$id/book.txt').writeAsStringSync(v1Text);
      File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({
        'id': id,
        'name': '旧书',
        'format': 'txt',
        'encoding': 'gbk',
        'chapters': [
          {'title': '第一章 甲', 'start': a, 'end': b},
          {'title': '第二章 乙', 'start': b, 'end': v1Text.length},
        ],
        'sizeBytes': 777,
        'importedAt': 5,
      }));
      return id;
    }

    test('旧书能读，读完变成 v2 布局（章节文件就位、book.txt 删掉）', () async {
      final id = seedV1();
      expect(await store.readChapter(id, 0), '第一章 甲\n第一章正文。\n');
      expect(await store.readChapter(id, 1), '第二章 乙\n第二章正文。\n');

      final dir = bookDir(id);
      expect(File('${dir.path}/chapters/0.txt').existsSync(), isTrue);
      expect(File('${dir.path}/chapters/1.txt').existsSync(), isTrue);
      expect(File('${dir.path}/book.txt').existsSync(), isFalse,
          reason: '迁移成功后不该再占一份整本副本');
      final manifest = jsonDecode(
        File('${dir.path}/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['schema'], 2);
      expect((manifest['chapters'] as List).first['file'], 'chapters/0.txt');

      // 迁移只做一次：再读一遍仍然是同一份内容
      expect(await store.readChapter(id, 0), '第一章 甲\n第一章正文。\n');
    });

    test('getBooks 也会触发迁移，且字段（书名 / 编码 / 字节数）不丢', () async {
      final id = seedV1();
      final all = await store.getBooks();
      expect(all.length, 1);
      expect(all.single.id, id);
      expect(all.single.name, '旧书');
      expect(all.single.encoding, 'gbk');
      expect(all.single.sizeBytes, 777);
      expect(File('${bookDir(id).path}/chapters/0.txt').existsSync(), isTrue);
    });

    test('迁移中途失败 → 旧书**仍然能读**（不写坏清单，退回 v1 路径）', () async {
      final id = seedV1();
      // 制造失败：chapters 这个名字被一个**文件**占了，目录建不出来
      File('${bookDir(id).path}/chapters').writeAsStringSync('占位');

      final book = await store.getBook(id);
      expect(book, isNotNull, reason: '迁移失败不能让书从书架消失');
      expect(book!.chapterCount, 2);
      expect(await store.readChapter(id, 0), '第一章 甲\n第一章正文。\n');
      expect(await store.readChapter(id, 1), '第二章 乙\n第二章正文。\n');

      // 清单仍是旧格式（没被半途写坏），book.txt 也还在
      final manifest = jsonDecode(
        File('${bookDir(id).path}/manifest.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(manifest['schema'], isNull);
      expect(File('${bookDir(id).path}/book.txt').existsSync(), isTrue);
    });

    test('v1 目录里 book.txt 不在 → 迁移跳过、读取返回 null（不崩）', () async {
      final id = seedV1();
      File('${bookDir(id).path}/book.txt').deleteSync();
      final book = await store.getBook(id);
      expect(book, isNotNull);
      expect(await store.readChapter(id, 0), isNull);
      expect(Directory('${bookDir(id).path}/chapters').existsSync(), isFalse);
    });

    test('删掉旧书仍然连带清目录', () async {
      final id = seedV1();
      await store.getBook(id); // 触发迁移
      expect(await store.removeBook(id), isTrue);
      expect(bookDir(id).existsSync(), isFalse);
    });
  });
}
