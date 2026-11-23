// 本地书正文加载器单测（E2）。
//
// 在**临时目录**里真跑文件读写（`rootDirOverride`）：这一层的职责就是「按章
// 下标切正文」，mock 掉 IO 等于没测。覆盖四件事：
// 1. 逐章正文与章名（章名来自 manifest，正文是字符偏移切片）；
// 2. 目录拼装（`local:<id>#<index>`，本地阅读不发请求）；
// 3. 越界 → 可读异常（不是 RangeError）；
// 4. 文件缺失 / 整本被删 → 「已丢失」，阅读页据此显示错误而不是白屏。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/local_book_store.dart';
import 'package:bili_whitelist_app/services/local_chapter_loader.dart';

const String _sample = '第一章 风起\n'
    '风从海上来。\n'
    '第二章 云涌\n'
    '云在天上走。\n'
    '第三章 雨落\n'
    '雨终于落了。\n';

void main() {
  late Directory root;
  late LocalBookStore store;
  late LocalBook book;
  late LocalChapterLoader loader;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('amo_local_loader_test_');
    store = LocalBookStore()..rootDirOverride = root;
    book = (await store.importTxt(name: '风起.txt', text: _sample))!;
    loader = LocalChapterLoader(
      bookId: book.id,
      chapters: localBookToc(book),
      store: store,
    );
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶尔句柄没放开，删不掉就交给系统临时目录清理
    }
  });

  test('逐章取正文：章名来自 manifest，正文只含本章', () async {
    final first = await loader.load(0);
    expect(first.title, '第一章 风起');
    expect(first.body, contains('风从海上来。'));
    expect(first.body, isNot(contains('云在天上走')), reason: '不能切串章');

    // 本地书没有分页抓取，也没有「部分内容没取到」
    expect(first.pageCount, 1);
    expect(first.partial, isFalse);
    expect(first.warning, isNull);
    expect(first.fromCache, isFalse, reason: '本地正文不经过章节缓存');

    final second = await loader.load(1);
    expect(second.title, '第二章 云涌');
    expect(second.body, contains('云在天上走。'));

    final last = await loader.load(2);
    expect(last.title, '第三章 雨落');
    expect(last.body, contains('雨终于落了。'));
  });

  test('localBookToc：章名逐个来自 manifest，url 形如 local:<id>#<index>', () {
    expect(
      book.chapters.map((c) => c.title).toList(),
      ['第一章 风起', '第二章 云涌', '第三章 雨落'],
    );

    final toc = localBookToc(book);
    expect(toc.length, 3);
    expect(toc[1].name, '第二章 云涌');
    expect(toc[1].url, '${book.detailUrl}#1');
    expect(toc[1].url.startsWith('local:'), isTrue);
  });

  test('越界（负数 / 超出章数）→ 可读异常，不是 RangeError', () async {
    for (final index in [-1, 3, 99]) {
      await expectLater(
        loader.load(index),
        throwsA(
          isA<RuleEngineException>().having(
            (e) => e.message,
            'message',
            contains('不在目录里'),
          ),
        ),
        reason: 'index=$index',
      );
    }
  });

  test('book.txt 被外部删掉 → 「已丢失」（阅读页给错误 + 重试）', () async {
    File('${root.path}/reader/local/${book.id}/book.txt').deleteSync();

    await expectLater(
      loader.load(0),
      throwsA(
        isA<RuleEngineException>().having(
          (e) => e.message,
          'message',
          contains('已丢失'),
        ),
      ),
    );
  });

  test('整本目录被删（清数据 / 用户删目录）→ 同样给「已丢失」', () async {
    expect(await store.removeBook(book.id), isTrue);
    expect(
      Directory('${root.path}/reader/local/${book.id}').existsSync(),
      isFalse,
    );

    await expectLater(
      loader.load(1),
      throwsA(
        isA<RuleEngineException>().having(
          (e) => e.message,
          'message',
          contains('已丢失'),
        ),
      ),
    );
  });
}
