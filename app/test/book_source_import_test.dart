// 书源导入解析测试（R1）。
//
// 被测对象是纯函数 [parseBookSourceText] / [extractFirstJsonSnippet]：不碰
// 网络、不碰 SharedPreferences，所以这里能放心把用户真实会粘进来的各种脏文本
// 都塞一遍 —— 解析器的主要价值就是「别让一段说明文字把整份书源搞挂」。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/utils/book_source_import.dart';

/// 一份最小标准书源（本模型格式）。
Map<String, dynamic> _minimal(String name, {String url = 'https://a.example'}) => {
      'name': name,
      'baseUrl': url,
      'search': {'url': '/search?q={{key}}', 'list': '.book'},
    };

/// 一份典型 legado 书源。
Map<String, dynamic> _legado(String name) => {
      'bookSourceName': name,
      'bookSourceUrl': 'https://legado.example',
      'bookSourceGroup': '精品',
      'searchUrl': '/s?q={{key}}',
      'ruleSearch': {
        'bookList': '@css:.book-item',
        'name': '@css:.title',
        'author': '@css:.author',
        'coverUrl': '@css:img@src',
        'bookUrl': '@css:a@href',
        'intro': '@css:.intro',
        'lastChapter': '@css:.last',
      },
      'ruleBookInfo': {
        'name': '@css:h1',
        'author': '@css:.author',
        'coverUrl': '@css:img@src',
        'intro': '@css:.intro',
        'kind': '@css:.kind',
        'wordCount': '@css:.words',
      },
      'ruleToc': {
        'chapterList': '@css:.chapter',
        'chapterName': '@css:a@text',
        'chapterUrl': '@css:a@href',
        'nextTocUrl': '@css:.next@href',
      },
      'ruleContent': {
        'content': '@css:#content',
        'nextContentUrl': '@css:.next@href',
      },
    };

void main() {
  group('输入形态', () {
    test('单个 JSON 对象 → 1 个书源', () {
      final r = parseBookSourceText(jsonEncode(_minimal('单个源')));
      expect(r.sources, hasLength(1));
      expect(r.sources.single.name, '单个源');
      expect(r.errors, isEmpty);
      expect(r.indexUrls, isEmpty);
    });

    test('JSON 数组 → 多个书源', () {
      final r = parseBookSourceText(
        jsonEncode([_minimal('A'), _minimal('B', url: 'https://b.example')]),
      );
      expect(r.sources.map((s) => s.name), ['A', 'B']);
      expect(r.errors, isEmpty);
    });

    test('混着说明文字：只取第一个 JSON 块，前后噪音忽略', () {
      const text = '''
导入方法：
1. 复制下面的内容
2. 打开 App → 阅读 → 书源管理 → 从剪贴板导入

{"name":"夹在中间","baseUrl":"https://mid.example","search":{"list":".b"}}

—— 以上，作者「某某」整理，转载请注明出处
''';
      final r = parseBookSourceText(text);
      expect(r.sources, hasLength(1));
      expect(r.sources.single.name, '夹在中间');
      // 尾部那些中文没有让解析失败
      expect(r.errors, isEmpty);
    });

    test('顶层是数组时，起点取 [ 而不是里面的 {', () {
      final r = parseBookSourceText(
        '前言\n[{"name":"X","baseUrl":"https://x.example"}]\n后记',
      );
      expect(r.sources.single.name, 'X');
    });

    test('空文本 → 一条人话错误，没有书源', () {
      final r = parseBookSourceText('   \n\n  ');
      expect(r.sources, isEmpty);
      expect(r.errors, isNotEmpty);
      expect(r.errors.single, contains('没有找到书源 JSON'));
    });
  });

  group('括号配对', () {
    test('字符串里带花括号/方括号不会提前收尾', () {
      // 规则里常有 `##\\{.*\\}##` 这类正则；朴素的「找第一个 }」会截断
      final json = jsonEncode({
        'name': '正则源',
        'baseUrl': 'https://r.example',
        'content': {
          'text': '#content',
          'replace': [
            {'regex': r'\{.*?\}', 'with': ''},
            {'regex': r'\[.*?\]', 'with': ''},
          ],
        },
      });
      final r = parseBookSourceText('说明文字 $json 尾巴');
      expect(r.sources, hasLength(1));
      final src = r.sources.single;
      expect(src.content.replace, hasLength(2));
      expect(src.content.replace.first.regex, r'\{.*?\}');
      expect(src.content.replace.first.withText, '');
      expect(r.errors, isEmpty);
    });

    test('转义引号不会把字符串状态搞错', () {
      final json = jsonEncode({
        'name': 'r"quo\\ted',
        'baseUrl': 'https://q.example',
      });
      final r = parseBookSourceText('$json 后面还有字');
      expect(r.sources, hasLength(1));
      expect(r.sources.single.name, 'r"quo\\ted');
    });

    test('只粘了半截（括号不闭合）→ 报「找不到 JSON」而不是崩', () {
      final r = parseBookSourceText('{"name":"半截","baseUrl":"https://x');
      expect(r.sources, isEmpty);
      expect(r.errors, isNotEmpty);
    });

    test('extractFirstJsonSnippet 返回原文片段本身', () {
      final s = extractFirstJsonSnippet('前言 {"a":{"b":1}} 后记');
      expect(s, isNotNull);
      expect(s!.text, '{"a":{"b":1}}');
    });
  });

  group('索引 URL 分离', () {
    test('只在索引链接的文本 → indexUrls 有值、errors 为空（不算格式错误）', () {
      const text = '''
https://example.com/bookSource.json
https://mirror.example.com/list.json
''';
      final r = parseBookSourceText(text);
      expect(r.sources, isEmpty);
      expect(r.errors, isEmpty, reason: '索引链接是合法输入，不该报格式错误');
      expect(r.indexUrls, [
        'https://example.com/bookSource.json',
        'https://mirror.example.com/list.json',
      ]);
    });

    test('索引链接 + JSON 混在一起：两边都拿到', () {
      final r = parseBookSourceText(
        '${jsonEncode(_minimal('混合源'))}\n'
        'https://example.com/more.json',
      );
      expect(r.sources.single.name, '混合源');
      expect(r.indexUrls, ['https://example.com/more.json']);
      expect(r.errors, isEmpty);
    });

    test('散文里提到的链接不算索引（整行才认）', () {
      final r = parseBookSourceText(
        '详见 https://example.com/bookSource.json 这个地址',
      );
      expect(r.indexUrls, isEmpty);
    });

    test('索引链接去重', () {
      final r = parseBookSourceText(
        'https://e.com/a.json\nhttps://e.com/a.json\n',
      );
      expect(r.indexUrls, hasLength(1));
    });
  });

  group('同名覆盖与坏数据', () {
    test('同名（大小写不敏感）后出现者覆盖先出现者，并记一条说明', () {
      final r = parseBookSourceText(
        jsonEncode([
          _minimal('Foo', url: 'https://old.example'),
          _minimal('foo', url: 'https://new.example'),
        ]),
      );
      expect(r.sources, hasLength(1));
      expect(r.sources.single.baseUrl, 'https://new.example');
      expect(r.errors.join(), contains('覆盖了同名书源'));
    });

    test('缺 name 的项被跳过并说明是第几项', () {
      final r = parseBookSourceText(
        jsonEncode([
          _minimal('好的'),
          {'baseUrl': 'https://noname.example'},
        ]),
      );
      expect(r.sources.map((s) => s.name), ['好的']);
      expect(r.errors.join(), contains('第 2 项'));
    });

    test('缺 baseUrl 的书源被跳过（否则后面抓取必然失败）', () {
      final r = parseBookSourceText(
        jsonEncode([
          {'name': '没有地址'},
        ]),
      );
      expect(r.sources, isEmpty);
      expect(r.errors.join(), contains('缺少站点地址'));
    });

    test('数组里混入非对象元素：跳过并说明', () {
      final r = parseBookSourceText(
        jsonEncode([_minimal('OK'), '一个字符串', 42]),
      );
      expect(r.sources, hasLength(1));
      expect(r.errors.where((e) => e.contains('不是 JSON 对象')), hasLength(2));
    });

    test('语法错误的 JSON → 人话（含「第 N 行第 M 个字符」），不含 FormatException', () {
      // 正文从第 2 行开始（第 1 行是真实原文里的说明文字，验证行号是原文行号）
      final r = parseBookSourceText('''书源如下：
{
  "name": "坏源",
  "baseUrl": "https://bad.example",
}''');
      expect(r.sources, isEmpty);
      expect(r.errors, hasLength(1));
      final msg = r.errors.single;
      expect(msg, contains('JSON 格式不正确'));
      // 具体偏移由 dart:convert 决定（它指在多余的 `}` 上），所以这里只校验
      // 「给出了原文行号 + 列号」这个格式，不押具体数字
      expect(msg, matches(RegExp(r'第 \d+ 行第 \d+ 个字符')));
      expect(msg, isNot(contains('FormatException')));
    });

    test('行号映射按原文数（前面的说明文字算行）', () {
      final snippet = extractFirstJsonSnippet('第一行\n第二行\n{"a":1}');
      expect(snippet, isNotNull);
      expect(snippet!.startLine, 3);
      // JSON 片段内部第 1 行 = 原文第 3 行
      expect(snippet.lineOf(1), 3);
    });

    test('引号没闭合/只粘半截 → 说「内容不完整」，不是「没找到 JSON」', () {
      final r = parseBookSourceText('''{
  "name": "半截",
  "baseUrl": "https://bad.example
}''');
      expect(r.sources, isEmpty);
      expect(r.errors.single, contains('JSON 内容不完整'));
      expect(r.errors.single, isNot(contains('FormatException')));
    });

    test('顶层是字符串 / 数字 → 明确指出无法识别', () {
      final r = parseBookSourceText('"just a string"');
      // 文本里没有 { 或 [ → 走「没有找到书源 JSON」
      expect(r.sources, isEmpty);
      expect(r.errors, isNotEmpty);

      final r2 = parseBookSourceText('123');
      expect(r2.sources, isEmpty);
      expect(r2.errors, isNotEmpty);
    });
  });

  group('名称清洗', () {
    test('名字里的换行 / 制表符 / 连续空白压成一个空格', () {
      final r = parseBookSourceText(jsonEncode(_minimal('缩书\n文学\t网  ')));
      expect(r.sources.single.name, '缩书 文学 网');
      // 单行：不残留任何换行或制表符
      expect(r.sources.single.name.contains('\n'), isFalse);
      expect(r.sources.single.name.contains('\t'), isFalse);
    });

    test('零宽字符（\\u200B / \\uFEFF）被删掉，不会把名字撑成两截', () {
      final r = parseBookSourceText(jsonEncode(_minimal('缩书\u200B文学\uFEFF网')));
      expect(r.sources.single.name, '缩书文学网');
    });

    test('author 同样清洗；baseUrl 只去首尾空白与零宽（不压中间）', () {
      final json = _minimal('源')..['author'] = '作者\t甲\n乙';
      json['baseUrl'] = '  https://a.example\u200B  ';
      final r = parseBookSourceText(jsonEncode(json));
      final s = r.sources.single;
      expect(s.author, '作者 甲 乙');
      expect(s.baseUrl, 'https://a.example');
    });

    test('legado 名字里的换行也被清洗（同一个模型出口）', () {
      final r = parseBookSourceText(jsonEncode(_legado('开源\n阅读 源')));
      expect(r.sources.single.name, '开源 阅读 源');
    });

    test('只有空白的名字清洗后变空 → 按缺 name 跳过并给提示', () {
      final r = parseBookSourceText(jsonEncode(_minimal(' \n\t ')));
      expect(r.sources, isEmpty);
      expect(r.errors.single, contains('缺少书源名'));
    });
  });

  group('legado 兼容', () {
    test('单个 legado 源：字段映射正确 + raw 保留', () {
      final r = parseBookSourceText(jsonEncode(_legado('开源阅读源')));
      expect(r.sources, hasLength(1));
      final s = r.sources.single;
      expect(s.name, '开源阅读源');
      expect(s.baseUrl, 'https://legado.example');
      expect(s.search.url, '/s?q={{key}}');
      expect(s.search.list, '@css:.book-item');
      expect(s.search.detailUrl, '@css:a@href');
      expect(s.detail, isNotNull);
      expect(s.detail!.name, '@css:h1');
      expect(s.detail!.category, '@css:.kind');
      expect(s.toc.list, '@css:.chapter');
      expect(s.toc.name, '@css:a@text');
      expect(s.toc.pages, '@css:.next@href');
      expect(s.content.text, '@css:#content');
      expect(s.content.nextPage, '@css:.next@href');
      // R2 跑规则要原始 JSON
      expect(s.raw, isNotNull);
      expect(s.raw!['bookSourceName'], '开源阅读源');
      // 分组的语义不是作者，不该塞进 author
      expect(s.author, isEmpty);
    });

    test('legado 数组：逐个识别（不是整份按本模型格式解析）', () {
      final r = parseBookSourceText(
        jsonEncode([_legado('L1'), _legado('L2')]),
      );
      expect(r.sources.map((s) => s.name), ['L1', 'L2']);
      expect(r.sources.every((s) => s.raw != null), isTrue);
    });

    test('legado 缺 bookSourceName → null（由解析器记错误）', () {
      final ok = BookSource.fromLegado({'bookSourceUrl': 'https://x.example'});
      expect(ok, isNull);
    });
  });

  group('往返一致性', () {
    test('标准格式：fromJson → toJson 逐键等价（含 replace 的 with）', () {
      final json = {
        'schemaVersion': 1,
        'name': '往返源',
        'version': '1.0',
        'author': '作者',
        'baseUrl': 'https://rt.example',
        'charset': 'gbk',
        'enabled': false,
        'headers': {'Referer': 'https://rt.example'},
        'requestIntervalMs': 500,
        'search': {
          'url': '/s?q={{key}}',
          'method': 'POST',
          'bodyType': 'json',
          'list': '.item',
          'name': '.n',
          'author': '.a',
          'cover': '.c',
          'intro': '.i',
          'detailUrl': '.u',
          'lastChapter': '.l',
          'body': {'k': 'v'},
        },
        'detail': {'url': '.u', 'name': '.n', 'status': '连载'},
        'toc': {
          'url': '/toc',
          'pages': '.next',
          'list': '.ch',
          'name': '.cn',
          'urlSel': '.cu',
          'volume': {'list': '.v', 'name': '.vn', 'chapters': '.vc'},
          'reversed': true,
          'maxPages': 3,
        },
        'content': {
          'url': '/c',
          'title': '.t',
          'nextPage': '.next',
          'text': '#text',
          'remove': ['.ad'],
          'replace': [
            {'regex': 'a', 'with': 'b'},
          ],
          'maxPages': 2,
          'paragraphBreak': 'p',
        },
      };
      final source = BookSource.fromJson(json);
      expect(source.toJson(), json);
    });

    test('把书源写回文本再解析，仍然是同一个源（导入 → 存 → 再导出）', () {
      final first = parseBookSourceText(jsonEncode(_legado('往返legado')));
      final exported = jsonEncode(first.sources.single.toJson());
      final second = parseBookSourceText(exported);
      expect(second.sources, hasLength(1));
      final a = first.sources.single;
      final b = second.sources.single;
      expect(b.name, a.name);
      expect(b.baseUrl, a.baseUrl);
      expect(b.search.url, a.search.url);
      expect(b.toc.list, a.toc.list);
      expect(b.content.text, a.content.text);
      expect(b.raw, a.raw);
    });

    test('缺省字段走默认值', () {
      final s = BookSource.fromJson({'name': 'n', 'baseUrl': 'https://n.example'});
      expect(s.schemaVersion, 1);
      expect(s.charset, 'utf-8');
      expect(s.enabled, isTrue);
      expect(s.headers, isEmpty);
      expect(s.requestIntervalMs, 0);
      expect(s.detail, isNull);
      expect(s.content.paragraphBreak, 'br');
      expect(s.toc.maxPages, 1);
    });
  });
}
