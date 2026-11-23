// 内置示例书源测试。
//
// 这一条源是「用户第一次点开就能用」的东西，坏掉的表现是「搜不到书」——
// 用户根本分不清是站点问题还是规则问题。所以这里钉三件事：
// 1. 字段齐全、规则**能被解析器执行**（不需要 JS、不是 JSONPath）；
// 2. 存进 SharedPreferences 再读回来，一个字段都不少；
// 3. 重复添加是幂等的（`upsertAll` 不该越加越多）。
//
// 选择器本身是否命中真实站点，只能在模拟器上端到端验（`flutter test` 没有
// WebView）；这里保证的是「规则可执行」这一层。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_rule/example_sources.dart';
import 'package:bili_whitelist_app/services/book_rule/legado_compat.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

/// 一条源里所有**写了**的选择器字段（漏一个就可能少抓一列）。
///
/// 空串不算「漏」：书源模型里空规则 = 「这一列不抓」（维基文库的搜索页没有
/// 作者与封面，那里就是空串）。所以这里滤掉空值，只要求**声明过的**规则可执行。
Map<String, String> _selectorFields(BookSource s) {
  final detail = s.detail;
  final all = <String, String>{
    'search.list': s.search.list,
    'search.name': s.search.name,
    'search.author': s.search.author,
    'search.cover': s.search.cover,
    'search.detailUrl': s.search.detailUrl,
    if (detail != null) ...{
      if (detail.name != null) 'detail.name': detail.name!,
      if (detail.author != null) 'detail.author': detail.author!,
      if (detail.cover != null) 'detail.cover': detail.cover!,
      if (detail.intro != null) 'detail.intro': detail.intro!,
      if (detail.wordCount != null) 'detail.wordCount': detail.wordCount!,
      if (detail.category != null) 'detail.category': detail.category!,
    },
    'toc.list': s.toc.list,
    'toc.name': s.toc.name,
    'toc.urlSel': s.toc.urlSel,
    'content.text': s.content.text,
  };
  return {
    for (final entry in all.entries)
      if (entry.value.trim().isNotEmpty) entry.key: entry.value,
  };
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('至少有一条示例源，且必备字段齐全', () {
    expect(kExampleBookSources, isNotEmpty);
    for (final s in kExampleBookSources) {
      expect(s.schemaVersion, 1);
      expect(s.name.trim(), isNotEmpty);
      expect(s.baseUrl, startsWith('https://'));
      expect(s.charset, 'utf-8');
      expect(s.enabled, isTrue);
      expect(s.search.url, contains('{{key}}'));
      expect(s.toc.url ?? '', contains('@detailUrl'));
    }
  });

  test('内置源至少两条，且名字唯一（大小写不敏感）', () {
    // 「一批」的下限：中文一条 + 英文一条，用户不管看哪边都能马上读上。
    expect(kExampleBookSources.length, greaterThanOrEqualTo(2));
    final keys = [for (final s in kExampleBookSources) s.key];
    expect(keys.toSet().length, keys.length, reason: '同名源会互相覆盖');
    // 中文站与英文站各至少一条（用户主要看经典文学，中文是刚需）
    expect(
      kExampleBookSources.any((s) => s.baseUrl.contains('wikisource')),
      isTrue,
    );
    expect(
      kExampleBookSources.any((s) => s.baseUrl.contains('standardebooks')),
      isTrue,
    );
  });

  test('示例源的每条选择器都可执行（不需要 JS、不是空规则）', () {
    for (final source in kExampleBookSources) {
      expect(usesJs(source), isFalse, reason: '${source.name} 不该依赖 JS 规则');
      final fields = _selectorFields(source);
      for (final entry in fields.entries) {
        final value = legadoSelector(entry.value);
        expect(
          value.isRunnable,
          isTrue,
          reason: '${source.name} 的 ${entry.key} 不可执行：${value.toString()}',
        );
        expect(value.kind, isNot(SelectorKind.jsonPath));
      }
      // 正文清洗规则（去掉章首标题块）也必须是可执行的 CSS，写错了不会报错、
      // 只会让章号/标题留在正文第一行 —— 真机上就是「I」单独占一行那种样子。
      expect(source.content.remove, isNotEmpty);
      for (final raw in source.content.remove) {
        final value = legadoSelector(raw);
        expect(
          value.isRunnable,
          isTrue,
          reason: '${source.name} 的正文清洗规则不可执行：$raw',
        );
        expect(value.kind, SelectorKind.css);
      }
      // 正文分段策略只认这三种；写错会让段落还原静默走 default 分支
      expect(
        source.content.paragraphBreak,
        anyOf('br', 'block', 'none'),
      );
    }
  });

  test('示例源能把标题 / 作者 / 封面分开抓（规则不互相串）', () {
    // 书架里的「有封面」是加分项，不是硬要求：维基文库的搜索页没有封面列，
    // 那条源就明说「这一列不抓」（空规则）。所以有封面规则的源必须取 `src`，
    // 但至少要有一条内置源带封面 —— 否则说明封面规则被整体改坏了。
    var withCover = 0;
    for (final source in kExampleBookSources) {
      final name = legadoSelector(source.search.name);
      final author = legadoSelector(source.search.author);
      final cover = legadoSelector(source.search.cover);
      expect(name.query, isNot(author.query));
      if (source.search.cover.trim().isNotEmpty) {
        withCover++;
        expect(cover.getter, 'src', reason: '${source.name} 的封面规则要取 src');
      }
      expect(legadoSelector(source.search.detailUrl).getter, 'href');
      expect(legadoSelector(source.toc.urlSel).getter, 'href');
    }
    expect(withCover, greaterThan(0));
  });

  test('示例源存进 BookSourceStore 后能原样读回（字段不丢）', () async {
    final store = BookSourceStore();
    expect(await store.upsertAll(kExampleBookSources), isTrue);

    final back = await store.getAll();
    expect(back.length, kExampleBookSources.length);
    final expected = [
      for (final s in kExampleBookSources) jsonEncode(s.toJson()),
    ];
    final actual = [for (final s in back) jsonEncode(s.toJson())];
    expect(actual, expected);
  });

  test('upsertAll 对示例源是幂等的（重复添加不会变两条）', () async {
    final store = BookSourceStore();
    await store.upsertAll(kExampleBookSources);
    final first = await store.getAll();

    await store.upsertAll(kExampleBookSources);
    final second = await store.getAll();

    expect(second.length, first.length);
    expect(
      [for (final s in second) s.name],
      [for (final s in first) s.name],
    );
  });

  test('BookSource.fromJson(toJson) 对示例源是往返稳定的', () {
    for (final source in kExampleBookSources) {
      final round = BookSource.fromJson(source.toJson());
      expect(jsonEncode(round.toJson()), jsonEncode(source.toJson()));
    }
  });
}
