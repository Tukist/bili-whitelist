// 书源页「添加内置书源」入口测试。
//
// 入口在 AppBar 溢出菜单里（内置源只是「先试一下」的顺手动作，不占主位）。
// 这里验三件事：点一下真的落库并出现在列表、重复点只提示「已存在」、
// 用户自己改过的同名书源不会被内置源覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_source_page.dart';
import 'package:bili_whitelist_app/services/book_rule/example_sources.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

BookSource _src(String name, {String baseUrl = 'https://a.example'}) =>
    BookSource(
      name: name,
      baseUrl: baseUrl,
      search: const SearchRule(url: '/s?q={{key}}', list: '.item'),
      toc: const TocRule(list: '.ch', name: '.cn', urlSel: '.cu'),
      content: const ContentRule(text: '#content'),
    );

Future<void> _pump(WidgetTester tester, BookSourceStore store) async {
  await tester.pumpWidget(
    MaterialApp(home: BookSourcePage(store: store)),
  );
  await tester.pumpAndSettle();
}

/// 打开溢出菜单并点「添加内置书源」。
Future<void> _tapAddExamples(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text('添加内置书源'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('溢出菜单里有「添加内置书源」，点一下落库并显示该源', (tester) async {
    final store = BookSourceStore();
    await _pump(tester, store);

    expect(find.text('还没有书源'), findsOneWidget);

    await _tapAddExamples(tester);

    expect(find.textContaining('已添加 ${kExampleBookSources.length} 个内置书源'), findsOneWidget);
    for (final s in kExampleBookSources) {
      expect(find.text(s.name), findsOneWidget);
    }
    expect((await store.getAll()).length, kExampleBookSources.length);
  });

  testWidgets('再点一次只提示「已存在」，不会重复写入', (tester) async {
    final store = BookSourceStore();
    await _pump(tester, store);

    await _tapAddExamples(tester);
    await _tapAddExamples(tester);

    expect(find.text('内置书源已存在'), findsOneWidget);
    expect((await store.getAll()).length, kExampleBookSources.length);
  });

  testWidgets('用户自己改过的同名书源不会被内置源覆盖（其余内置源照常补进来）',
      (tester) async {
    final example = kExampleBookSources.first;
    final store = BookSourceStore();
    await store.upsertAll([_src(example.name, baseUrl: 'https://mine.example')]);
    await _pump(tester, store);

    await _tapAddExamples(tester);

    final all = await store.getAll();
    // 自己那条还在、规则没被冲掉
    final mine = all.firstWhere((s) => s.key == example.key);
    expect(mine.baseUrl, 'https://mine.example');
    // 其余内置源补进来了（F2 起内置源不止一条，跳过一条不等于跳过全部）
    expect(all.length, kExampleBookSources.length);
    // 提示里说明「有几个同名源没覆盖」，不假装全新增
    expect(find.textContaining('没有覆盖'), findsOneWidget);
  });
}
