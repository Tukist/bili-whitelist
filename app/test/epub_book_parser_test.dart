// EPUB 解析器单测（E3）。
//
// **夹具全部在测试里用 `archive` 现造 zip**（`ZipEncoder`），仓库里不放任何
// 二进制样本：二进制一旦入库就没人敢动，也没人看得懂它为什么坏；而现造的
// 夹具可以把「缺一章」「spine 顺序反着」「href 带 %20」这些边界写得一清二楚。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/local_book_parser.dart';

/// 把 `路径 → 内容（String 或字节）` 打成一个 zip。
List<int> _zip(Map<String, Object> files) {
  final archive = Archive();
  files.forEach((name, value) {
    final bytes = value is String ? utf8.encode(value) : value as List<int>;
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

String _container(String opfPath) => '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

/// OPF 生成器（只写解析器真正会读的那几段）。
String _opf({
  String title = '测试书',
  String creator = '作者甲',
  String language = 'zh-CN',
  required List<Map<String, String>> manifest,
  required List<String> spine,
  String? coverMetaId,
  String? spineToc,
}) {
  final items = manifest.map((m) {
    final buf = StringBuffer(
      '<item id="${m['id']}" href="${m['href']}" '
      'media-type="${m['media-type'] ?? 'application/xhtml+xml'}"',
    );
    final props = m['properties'] ?? '';
    if (props.isNotEmpty) buf.write(' properties="$props"');
    buf.write('/>');
    return buf.toString();
  }).join('\n    ');
  final refs = spine.map((id) => '<itemref idref="$id"/>').join('\n    ');
  return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:creator>$creator</dc:creator>
    <dc:language>$language</dc:language>
    <dc:identifier id="bookid">urn:uuid:test-book</dc:identifier>
    ${coverMetaId == null ? '' : '<meta name="cover" content="$coverMetaId"/>'}
  </metadata>
  <manifest>
    $items
  </manifest>
  <spine${spineToc == null ? '' : ' toc="$spineToc"'}>
    $refs
  </spine>
</package>''';
}

/// 一页 XHTML：`<head><title>` 里的文字**不该**出现在正文里（解析器要先删 head）。
String _xhtml(String body, {String title = '页标题'}) => '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>$title</title></head>
<body>$body</body>
</html>''';

String _navXhtml(Map<String, String> toc) => '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
<nav epub:type="toc" id="toc">
  <h1>目录</h1>
  <ol>
    ${toc.entries.map((e) => '<li><a href="${e.key}">${e.value}</a></li>').join('\n    ')}
  </ol>
</nav>
</body>
</html>''';

/// toc.ncx：`[标题, src]` 的扁平列表也能写成嵌套（`depth` 控制层级）。
String _ncx(List<List<String>> points) {
  final body = points
      .map((p) => '<navPoint id="np${p[0].hashCode}" playOrder="1">'
          '<navLabel><text>${p[0]}</text></navLabel>'
          '<content src="${p[1]}"/></navPoint>')
      .join('\n    ');
  return '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    $body
  </navMap>
</ncx>''';
}

const List<int> _fakeJpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46];

void main() {
  const parser = EpubBookParser();

  group('EPUB3（nav.xhtml 作目录）', () {
    List<int> build() => _zip({
          'META-INF/container.xml': _container('OEBPS/content.opf'),
          'OEBPS/content.opf': _opf(
            manifest: [
              {'id': 'ch1', 'href': 'text/ch1.xhtml'},
              {'id': 'ch2', 'href': 'text/ch2.xhtml'},
              {'id': 'nav', 'href': 'nav.xhtml', 'properties': 'nav'},
              {'id': 'cover-img', 'href': 'images/cover.jpg',
                'media-type': 'image/jpeg', 'properties': 'cover-image'},
            ],
            spine: ['ch1', 'ch2'],
            coverMetaId: 'cover-img',
          ),
          'OEBPS/nav.xhtml': _navXhtml({
            'text/ch1.xhtml': '第一章 起风',
            'text/ch2.xhtml': '第二章 落雨',
          }),
          'OEBPS/text/ch1.xhtml': _xhtml(
            '<h1>第一章 起风</h1><p>这是第一章的第一段。</p><p>这是第一章的第二段。</p>',
            title: '不该出现的页标题',
          ),
          'OEBPS/text/ch2.xhtml': _xhtml('<p>这是第二章的正文。</p>'),
          'OEBPS/images/cover.jpg': _fakeJpeg,
        });

    test('书名 / 作者 / 语言 / 正文 / 章名全部到位', () async {
      final book = await parser.parse(
        Uint8List.fromList(build()),
        fileName: '测试书.epub',
      );

      expect(book.format, 'epub');
      expect(book.title, '测试书');
      expect(book.author, '作者甲');
      expect(book.meta['language'], 'zh-CN');
      expect(book.meta['toc'], 'nav');
      expect(book.chapterCount, 2);
      expect(book.chapters[0].title, '第一章 起风');
      expect(book.chapters[1].title, '第二章 落雨');
      expect(book.warnings, isEmpty);

      // 正文：段落分成两行（block 策略），head 里的标题没漏出来
      expect(book.chapters[0].text, '第一章 起风\n这是第一章的第一段。\n这是第一章的第二段。');
      expect(book.chapters[0].text, isNot(contains('不该出现的页标题')));
      expect(book.chapters[1].text, '这是第二章的正文。');
    });

    test('封面按 manifest 的 cover-image 取原始字节（不经文本解码）', () async {
      final book = await parser.parse(
        Uint8List.fromList(build()),
        fileName: '测试书.epub',
      );
      expect(book.coverBytes, isNotNull);
      expect(book.coverBytes, _fakeJpeg);
    });

    test('idSeed 稳定：同一份字节两次解析相同，换文件名字节不同则不同', () async {
      final a = await parser.parse(
        Uint8List.fromList(build()),
        fileName: '测试书.epub',
      );
      final b = await parser.parse(
        Uint8List.fromList(build()),
        fileName: '测试书.epub',
      );
      expect(a.idSeed, b.idSeed);
      expect(a.idSeed, contains('epub|测试书.epub|'));
    });

    test('没有封面时 coverBytes 为 null（不是空数组）', () async {
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: ['ch1'],
        ),
        'ch1.xhtml': _xhtml('<p>正文</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '无封面.epub',
      );
      expect(book.coverBytes, isNull);
      expect(book.chapterCount, 1);
      // 没有目录 → 退化成「第 N 章」
      expect(book.chapters.first.title, '第 1 章');
    });
  });

  group('EPUB2（toc.ncx 作目录）', () {
    List<int> build() => _zip({
          'META-INF/container.xml': _container('OEBPS/content.opf'),
          'OEBPS/content.opf': _opf(
            manifest: [
              {'id': 'ch1', 'href': 'ch1.xhtml'},
              {'id': 'ch2', 'href': 'ch2.xhtml'},
              {'id': 'ncx', 'href': 'toc.ncx',
                'media-type': 'application/x-dtbncx+xml'},
            ],
            spine: ['ch1', 'ch2'],
            spineToc: 'ncx',
          ),
          'OEBPS/toc.ncx': _ncx([
            ['第一章 风起', 'ch1.xhtml'],
            ['第二章 云涌', 'ch2.xhtml'],
          ]),
          'OEBPS/ch1.xhtml': _xhtml('<p>第一章正文。</p>'),
          'OEBPS/ch2.xhtml': _xhtml('<p>第二章正文。</p>'),
        });

    test('navMap 的 navLabel/text 当章节名', () async {
      final book = await parser.parse(
        Uint8List.fromList(build()),
        fileName: 'epub2.epub',
      );
      expect(book.meta['toc'], 'ncx');
      expect(book.chapters.map((c) => c.title), ['第一章 风起', '第二章 云涌']);
    });

    test('嵌套 navPoint（分卷下挂章）也能按文档顺序取到标题', () async {
      // 父节点有自己的 content，子节点跟在后面；线性配对必须取「自己的」那个
      final ncx = '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
  <navMap>
    <navPoint id="vol1"><navLabel><text>第一卷</text></navLabel>
      <content src="ch1.xhtml"/>
      <navPoint id="c2"><navLabel><text>第二章 云涌</text></navLabel>
        <content src="ch2.xhtml"/></navPoint>
    </navPoint>
  </navMap>
</ncx>''';
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
            {'id': 'ch2', 'href': 'ch2.xhtml'},
            {'id': 'ncx', 'href': 'toc.ncx',
              'media-type': 'application/x-dtbncx+xml'},
          ],
          spine: ['ch1', 'ch2'],
          spineToc: 'ncx',
        ),
        'toc.ncx': ncx,
        'ch1.xhtml': _xhtml('<p>一</p>'),
        'ch2.xhtml': _xhtml('<p>二</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '嵌套.epub',
      );
      expect(book.chapters.map((c) => c.title), ['第一卷', '第二章 云涌']);
    });
  });

  group('章节顺序', () {
    test('按 spine 而不是文件名 / manifest 顺序', () async {
      // 文件名排序是 a < b < c，正文顺序却是 c → a → b
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'a', 'href': 'a.xhtml'},
            {'id': 'b', 'href': 'b.xhtml'},
            {'id': 'c', 'href': 'c.xhtml'},
            {'id': 'nav', 'href': 'nav.xhtml', 'properties': 'nav'},
          ],
          spine: ['c', 'a', 'b'],
        ),
        'nav.xhtml': _navXhtml({
          'c.xhtml': '第一章',
          'a.xhtml': '第二章',
          'b.xhtml': '第三章',
        }),
        'a.xhtml': _xhtml('<p>第二个出现的</p>'),
        'b.xhtml': _xhtml('<p>第三个出现的</p>'),
        'c.xhtml': _xhtml('<p>第一个出现的</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '乱序.epub',
      );
      expect(book.chapters.map((c) => c.title), ['第一章', '第二章', '第三章']);
      expect(book.chapters[0].text, '第一个出现的');
      expect(book.chapters[1].text, '第二个出现的');
      expect(book.chapters[2].text, '第三个出现的');
    });
  });

  group('路径解析', () {
    test('href 带 %20 与 ../ 都能命中 zip 里的真实 entry', () async {
      final bytes = _zip({
        'META-INF/container.xml': _container('OEBPS/content.opf'),
        'OEBPS/content.opf': _opf(
          manifest: [
            // 百分号编码：zip 里存的是真实的空格
            {'id': 'ch1', 'href': 'text/ch%201.xhtml'},
            {'id': 'nav', 'href': 'nav/nav.xhtml', 'properties': 'nav'},
          ],
          spine: ['ch1'],
        ),
        // nav 在子目录里，href 要 ../ 才能回到 OEBPS/text
        'OEBPS/nav/nav.xhtml': _navXhtml({
          '../text/ch%201.xhtml': '第一章 带空格的路径',
        }),
        'OEBPS/text/ch 1.xhtml': _xhtml('<p>正文找到了。</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '路径.epub',
      );
      expect(book.chapters.length, 1);
      expect(book.chapters.first.text, '正文找到了。');
      expect(book.chapters.first.title, '第一章 带空格的路径');
    });
  });

  group('容错：能救的就救', () {
    test('某章文件缺失 → 跳过并记 warning，其余章照常', () async {
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
            {'id': 'ghost', 'href': 'ghost.xhtml'}, // 文件不在包里
            {'id': 'ch2', 'href': 'ch2.xhtml'},
          ],
          spine: ['ch1', 'ghost', 'ch2'],
        ),
        'ch1.xhtml': _xhtml('<p>一</p>'),
        'ch2.xhtml': _xhtml('<p>三</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '缺章.epub',
      );
      expect(book.chapterCount, 2, reason: '缺的那章跳过，不是整本失败');
      expect(book.warnings.length, 1);
      expect(book.warnings.first, contains('ghost.xhtml'));
      expect(book.chapters.last.text, '三');
    });

    test('spine 里的 id 不在 manifest → 跳过并记 warning', () async {
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: ['ch1', 'nope'],
        ),
        'ch1.xhtml': _xhtml('<p>只有一章</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '坏 spine.epub',
      );
      expect(book.chapterCount, 1);
      expect(book.warnings.single, contains('nope'));
    });

    test('空章节（XHTML 里没正文）跳过，不产生空章', () async {
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'empty', 'href': 'empty.xhtml'},
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: ['empty', 'ch1'],
        ),
        'empty.xhtml': _xhtml('<div></div>'),
        'ch1.xhtml': _xhtml('<p>有正文</p>'),
      });
      final book = await parser.parse(
        Uint8List.fromList(bytes),
        fileName: '空章.epub',
      );
      expect(book.chapterCount, 1);
      expect(book.warnings.single, contains('没有正文'));
    });
  });

  group('容错：救不了的给一句明确的错', () {
    Future<String> failureMessage(List<int> bytes, {String name = 'x.epub'}) async {
      try {
        await parser.parse(Uint8List.fromList(bytes), fileName: name);
        fail('应该抛 LocalBookParseException');
      } on LocalBookParseException catch (e) {
        return e.message;
      }
    }

    test('坏 zip', () async {
      final msg = await failureMessage(utf8.encode('这不是一个 zip 文件'));
      expect(msg, contains('打不开'));
    });

    test('缺 META-INF/container.xml', () async {
      final msg = await failureMessage(_zip({
        'OEBPS/content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: ['ch1'],
        ),
      }));
      expect(msg, contains('container.xml'));
    });

    test('container.xml 里没有 rootfile', () async {
      final msg = await failureMessage(_zip({
        'META-INF/container.xml': '<container><rootfiles/></container>',
      }));
      expect(msg, contains('OPF'));
    });

    test('OPF 路径指向不存在的文件', () async {
      final msg = await failureMessage(_zip({
        'META-INF/container.xml': _container('OEBPS/nope.opf'),
      }));
      expect(msg, contains('找不到正文描述文件'));
      expect(msg, contains('nope.opf'));
    });

    test('spine 为空', () async {
      final msg = await failureMessage(_zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: const [],
        ),
        'ch1.xhtml': _xhtml('<p>有正文但没进 spine</p>'),
      }));
      expect(msg, contains('spine'));
    });

    test('spine 里的文件全都不存在 → 没有可读正文（带上第一条原因）', () async {
      final msg = await failureMessage(_zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: ['ch1'],
        ),
      }));
      expect(msg, contains('没有可读的正文'));
      expect(msg, contains('ch1.xhtml'));
    });
  });

  group('解压上限（防 zip bomb）', () {
    test('单章解压后超上限 → 中止并说清原因', () async {
      final big = '正' * 2000; // 6000 字节
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
          ],
          spine: ['ch1'],
        ),
        'ch1.xhtml': _xhtml('<p>$big</p>'),
      });
      // 注入小上限验证（生产值是 8MB，测试里没必要真造 8MB）
      const tiny = EpubBookParser(limits: EpubLimits(maxChapterBytes: 500));
      await expectLater(
        tiny.parse(Uint8List.fromList(bytes), fileName: '炸弹.epub'),
        throwsA(
          isA<LocalBookParseException>().having(
            (e) => e.message,
            'message',
            contains('防止压缩炸弹'),
          ),
        ),
      );
    });

    test('累计解压量超上限 → 中止（多章叠加也算）', () async {
      final bytes = _zip({
        'META-INF/container.xml': _container('content.opf'),
        'content.opf': _opf(
          manifest: [
            {'id': 'ch1', 'href': 'ch1.xhtml'},
            {'id': 'ch2', 'href': 'ch2.xhtml'},
            {'id': 'ch3', 'href': 'ch3.xhtml'},
          ],
          spine: ['ch1', 'ch2', 'ch3'],
        ),
        'ch1.xhtml': _xhtml('<p>${'甲' * 500}</p>'),
        'ch2.xhtml': _xhtml('<p>${'乙' * 500}</p>'),
        'ch3.xhtml': _xhtml('<p>${'丙' * 500}</p>'),
      });
      // OPF / container 本身也占一点，总量上限给得比单章上限小不了多少
      const tiny = EpubBookParser(
        limits: EpubLimits(maxChapterBytes: 4000, maxTotalBytes: 5000),
      );
      await expectLater(
        tiny.parse(Uint8List.fromList(bytes), fileName: '炸弹.epub'),
        throwsA(
          isA<LocalBookParseException>().having(
            (e) => e.message,
            'message',
            contains('体积过大'),
          ),
        ),
      );
    });
  });
}
