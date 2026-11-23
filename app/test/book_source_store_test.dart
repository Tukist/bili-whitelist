// 书源存储测试（R1）。
//
// 覆盖的是「用户数据不会悄悄变形」这件事：合并 / 同名覆盖 / 启停 / 删除 /
// 脏数据容错 / 上限。写盘用的是 SharedPreferences 的 mock 实现，所以这些
// 用例也顺带验证了「存进去的 JSON 能被自己读回来」（往返）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_source_store.dart';

BookSource _src(String name, {String baseUrl = 'https://a.example', bool enabled = true}) =>
    BookSource(
      name: name,
      baseUrl: baseUrl,
      enabled: enabled,
      search: const SearchRule(url: '/s?q={{key}}', list: '.item'),
      toc: const TocRule(list: '.ch', name: '.cn', urlSel: '.cu'),
      content: const ContentRule(text: '#content'),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('空存储 → 空列表', () async {
    final store = BookSourceStore();
    expect(await store.getAll(), isEmpty);
  });

  test('upsertAll 写入后 getAll 能读回（字段不丢）', () async {
    final store = BookSourceStore();
    final ok = await store.upsertAll([
      _src('甲', baseUrl: 'https://jia.example'),
      _src('乙', baseUrl: 'https://yi.example', enabled: false),
    ]);
    expect(ok, isTrue);

    final list = await store.getAll();
    expect(list.map((s) => s.name), ['甲', '乙']);
    expect(list[0].baseUrl, 'https://jia.example');
    expect(list[1].enabled, isFalse);
    expect(list[0].search.url, '/s?q={{key}}');
    expect(list[0].toc.list, '.ch');
    expect(list[0].content.text, '#content');
  });

  test('同名（大小写不敏感）覆盖：不新增行，内容取新的', () async {
    final store = BookSourceStore();
    await store.upsertAll([_src('Foo', baseUrl: 'https://old.example')]);
    await store.upsertAll([_src('foo', baseUrl: 'https://new.example')]);

    final list = await store.getAll();
    expect(list, hasLength(1));
    expect(list.single.baseUrl, 'https://new.example');
    // 覆盖保留的是新名字（用户贴进来的那个写法）
    expect(list.single.name, 'foo');
  });

  test('新名追加到尾部（顺序稳定，不重排已有源）', () async {
    final store = BookSourceStore();
    await store.upsertAll([_src('A'), _src('B')]);
    await store.upsertAll([_src('C'), _src('a', baseUrl: 'https://a2.example')]);
    final names = (await store.getAll()).map((s) => s.name).toList();
    expect(names, ['a', 'B', 'C']);
  });

  test('setEnabled 改状态；不存在的源返回 false', () async {
    final store = BookSourceStore();
    await store.upsertAll([_src('A')]);
    expect(await store.setEnabled('A', false), isTrue);
    expect((await store.getAll()).single.enabled, isFalse);
    // 大小写不敏感
    expect(await store.setEnabled('a', true), isTrue);
    expect((await store.getAll()).single.enabled, isTrue);
    expect(await store.setEnabled('不存在', false), isFalse);
  });

  test('remove 按名字删除（幂等）；只删中的那条', () async {
    final store = BookSourceStore();
    await store.upsertAll([_src('A'), _src('B')]);
    expect(await store.remove('a'), isTrue);
    expect((await store.getAll()).map((s) => s.name), ['B']);
    // 再删一次：已经没有了，也算成功（幂等，UI 不用区分）
    expect(await store.remove('A'), isTrue);
    expect((await store.getAll()).map((s) => s.name), ['B']);
  });

  test('空输入 upsertAll 不写盘也不报错', () async {
    final store = BookSourceStore();
    expect(await store.upsertAll(const []), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(BookSourceStore.storageKey), isNull);
  });

  group('脏数据容错', () {
    test('存储里是坏 JSON → 空列表，不抛', () async {
      SharedPreferences.setMockInitialValues({
        BookSourceStore.storageKey: '{这不是 JSON',
      });
      expect(await BookSourceStore().getAll(), isEmpty);
    });

    test('存储里是对象而不是数组 → 空列表', () async {
      SharedPreferences.setMockInitialValues({
        BookSourceStore.storageKey: jsonEncode({'name': 'A'}),
      });
      expect(await BookSourceStore().getAll(), isEmpty);
    });

    test('数组里混入非对象 / 缺 name 的项 → 逐条跳过，好的留下', () async {
      SharedPreferences.setMockInitialValues({
        BookSourceStore.storageKey: jsonEncode([
          '字符串',
          42,
          {'baseUrl': 'https://noname.example'},
          {'name': '好的', 'baseUrl': 'https://ok.example'},
        ]),
      });
      final list = await BookSourceStore().getAll();
      expect(list.map((s) => s.name), ['好的']);
      expect(list.single.baseUrl, 'https://ok.example');
    });

    test('有 name 但 baseUrl 为空 → 丢弃（导入后必然搜不出东西）', () async {
      SharedPreferences.setMockInitialValues({
        BookSourceStore.storageKey: jsonEncode([
          // 手抄书源时常见的漏填：名字写了，站点根没写
          {'name': '只填了名字'},
          {'name': '空 baseUrl', 'baseUrl': ''},
          {'name': '空白 baseUrl', 'baseUrl': '   '},
          {'name': '好的', 'baseUrl': 'https://ok.example'},
        ]),
      });
      final list = await BookSourceStore().getAll();
      expect(list.map((s) => s.name), ['好的']);
      expect(list.single.baseUrl, 'https://ok.example');
    });

    test('缺省字段走模型默认值（旧版本写下的数据仍可读）', () async {
      SharedPreferences.setMockInitialValues({
        BookSourceStore.storageKey: jsonEncode([
          {'name': '老数据', 'baseUrl': 'https://old.example'},
        ]),
      });
      final list = await BookSourceStore().getAll();
      expect(list.single.enabled, isTrue);
      expect(list.single.charset, 'utf-8');
      expect(list.single.toc.maxPages, 1);
    });

    test('脏数据不会在下次写入时被打包丢掉 —— 写回后仍是合法 JSON', () async {
      SharedPreferences.setMockInitialValues({
        BookSourceStore.storageKey: jsonEncode([
          'junk',
          {'name': '好的', 'baseUrl': 'https://ok.example'},
        ]),
      });
      final store = BookSourceStore();
      await store.upsertAll([_src('新的')]);
      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(prefs.getString(BookSourceStore.storageKey)!);
      expect(decoded, isA<List<dynamic>>());
      expect((decoded as List).map((e) => (e as Map)['name']), ['好的', '新的']);
    });
  });

  group('上限', () {
    test('超过 maxSources → 整次写入被拒绝，原有数据不变', () async {
      final store = BookSourceStore();
      final initial = [
        for (var i = 0; i < BookSourceStore.maxSources; i++)
          _src('源$i', baseUrl: 'https://s$i.example'),
      ];
      expect(await store.upsertAll(initial), isTrue);
      expect(await store.getAll(), hasLength(BookSourceStore.maxSources));

      // 再加一个 → 拒绝，且不悄悄丢掉最早那个
      expect(await store.upsertAll([_src('溢出')]), isFalse);
      final after = await store.getAll();
      expect(after, hasLength(BookSourceStore.maxSources));
      expect(after.map((s) => s.name), contains('源0'));
      expect(after.map((s) => s.name), isNot(contains('溢出')));
    });

    test('同名覆盖不计入新增，满额时仍可更新已有源', () async {
      final store = BookSourceStore();
      await store.upsertAll([
        for (var i = 0; i < BookSourceStore.maxSources; i++)
          _src('源$i', baseUrl: 'https://s$i.example'),
      ]);
      expect(
        await store.upsertAll([_src('源0', baseUrl: 'https://updated.example')]),
        isTrue,
      );
      final list = await store.getAll();
      expect(list, hasLength(BookSourceStore.maxSources));
      expect(list.first.baseUrl, 'https://updated.example');
    });
  });

  group('索引链接（R1 只存不下载）', () {
    test('保存后能读回，重复保存去重', () async {
      final store = BookSourceStore();
      expect(await store.getIndexUrls(), isEmpty);
      await store.saveIndexUrls(['https://e.com/a.json', 'https://e.com/b.json']);
      await store.saveIndexUrls(['https://e.com/a.json', 'https://e.com/c.json']);
      expect(await store.getIndexUrls(), [
        'https://e.com/a.json',
        'https://e.com/b.json',
        'https://e.com/c.json',
      ]);
    });

    test('空列表不写盘', () async {
      final store = BookSourceStore();
      expect(await store.saveIndexUrls(const []), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(BookSourceStore.indexUrlsKey), isNull);
    });
  });

  test('两个实例共享同一份存储（模拟重启后重读）', () async {
    await BookSourceStore().upsertAll([_src('持久化')]);
    expect((await BookSourceStore().getAll()).single.name, '持久化');
  });
}
