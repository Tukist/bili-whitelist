// 手写 xlsx 读取器单测（v2.34.0）。
//
// 夹具分两类（**都不含用户真实数据**）：
// 1. `test/fixtures/schedule_sample.xlsx` —— 用 openpyxl 生成的**合成**表格
//    （生成脚本 tools/make_xlsx_fixture.py，内容是我们瞎编的课表），
//    代表"真实写入器的产物"（openpyxl 写 inlineStr + solid 填充 + 绝对 rels 路径）；
// 2. 下面 [_xlsx] 手工拼的 zip —— 那一串"故意畸形 / 真实写入器写不出来"的形态
//    （缺 r 属性、命名空间前缀、XML 截断、theme 填充…）用代码构造最直观。
//
// ⚠️ 用户那张真实日历（`超级代办 大三上.xlsx`）**不在这里**：它是私人数据，
// 不进仓库（真机取证时才把它推到模拟器上跑一次，见交付报告）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/xlsx_reader.dart';

// ============================================================================
// 夹具构造
// ============================================================================

/// 把 [entries]（zip 内路径 → XML 文本）打成一份 xlsx 字节。
Uint8List _xlsx(Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

const String _workbook1 =
    '<workbook><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';
const String _rels1 =
    '<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
    'officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    '</Relationships>';

/// 拼一份最小可用的 xlsx；只改要测的那一处，其余给默认值。
Uint8List _xlsxWith({
  String? sheet,
  String? sharedStrings,
  String? styles,
  String? workbook,
  String? rels,
  Map<String, String> extra = const {},
}) {
  return _xlsx({
    'xl/workbook.xml': workbook ?? _workbook1,
    'xl/_rels/workbook.xml.rels': rels ?? _rels1,
    if (sharedStrings != null) 'xl/sharedStrings.xml': sharedStrings,
    if (styles != null) 'xl/styles.xml': styles,
    'xl/worksheets/sheet1.xml': sheet ?? '<worksheet><sheetData/></worksheet>',
    ...extra,
  });
}

/// 一张只有一行内容的表，用来观察单元格文本解析的结果。
String _sheetWithCells(String cellsXml, {String rowAttrs = ' r="1"'}) =>
    '<worksheet><sheetData><row$rowAttrs>$cellsXml</row></sheetData></worksheet>';

/// [`s` 样式下标 → 色板下标]：样式表里三项 fill（无色 / 黄 / 红），
/// cellXfs 故意**倒序**引用，用来证明走的是 fillId 间接层而不是 fills[s]。
const String _stylesIndirect = '<styleSheet>'
    '<fills count="3">'
    '<fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></fill>'
    '<fill><patternFill patternType="solid"><fgColor rgb="FFFF0000"/></fill>'
    '</fills>'
    '<cellXfs count="3">'
    '<xf fillId="2"/>'
    '<xf fillId="1"/>'
    '<xf fillId="0"/>'
    '</cellXfs>'
    '</styleSheet>';

/// 解析单张表（测试里最常用的入口）。
XlsxSheetData _sheet(Uint8List bytes, {String name = 'Sheet1'}) {
  final wb = readXlsx(bytes)!;
  final ref = wb.sheetRefs.firstWhere((r) => r.name == name);
  return wb.readSheet(ref)!;
}

/// 取第 [row] 行（0-based）第 [col] 列的格子。
XlsxCell _cell(XlsxSheetData sheet, int row, int col) {
  for (final r in sheet.rows) {
    if (r.index == row) {
      return r.cells[col] ?? const XlsxCell();
    }
  }
  return const XlsxCell();
}

void main() {
  group('共享字符串', () {
    test('t="s" 按下标取 sharedStrings，且富文本多个 <r> run 要拼起来 + 保留前后空格',
        () {
      final xml = _xlsxWith(
        sharedStrings: '<sst><si><t>星期日</t></si>'
            '<si><r><t>加粗</t></r><r><t>普通</t></r></si>'
            '<si><t xml:space="preserve">  前后都有空格  </t></si>'
            '</sst>',
        sheet: _sheetWithCells(
          '<c r="A1" t="s"><v>0</v></c>'
          '<c r="B1" t="s"><v>1</v></c>'
          '<c r="C1" t="s"><v>2</v></c>',
        ),
      );

      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, '星期日');
      expect(_cell(sheet, 0, 1).text, '加粗普通', reason: '多 run 富文本要拼接');
      expect(_cell(sheet, 0, 2).text, '  前后都有空格  ',
          reason: 'xml:space="preserve" 的前后空格必须原样保留');
    });

    test('共享字符串下标越界 / 不是数字 → 空文本，不抛', () {
      final xml = _xlsxWith(
        sharedStrings: '<sst><si><t>只有一个</t></si></sst>',
        sheet: _sheetWithCells(
          '<c r="A1" t="s"><v>9</v></c>'
          '<c r="B1" t="s"><v>abc</v></c>'
          '<c r="C1" t="s"><v>-1</v></c>',
        ),
      );
      final sheet = _sheet(xml);
      expect(sheet.rows, isEmpty, reason: '三个格子全是空文本 ⇒ 整行没内容');
    });

    test('缺 sharedStrings.xml 时 t="s" 单元格退化成空文本（不抛）', () {
      final xml = _xlsxWith(
        sheet: _sheetWithCells('<c r="A1" t="s"><v>0</v></c>'),
      );
      expect(readXlsx(xml)!.sharedStrings, isEmpty);
      expect(_sheet(xml).rows, isEmpty);
    });

    test('注音 <rPh> 里的 <t> 不算单元格文本', () {
      final xml = _xlsxWith(
        sharedStrings: '<sst><si><t>漢字</t><rPh sb="0" eb="2">'
            '<t>かんじ</t></rPh><phoneticPr fontId="1"/></si></sst>',
        sheet: _sheetWithCells('<c r="A1" t="s"><v>0</v></c>'),
      );
      expect(_cell(_sheet(xml), 0, 0).text, '漢字');
    });

    test('实体与 Excel 控制字符转义（&#10; / _x000D_）都还原成字符', () {
      final xml = _xlsxWith(
        sharedStrings: '<sst><si><t>第一行&#10;第二行</t></si>'
            '<si><t>回车_x000D_后面</t></si>'
            '<si><t>a&amp;b&lt;c&gt;d&quot;e&apos;f</t></si></sst>',
        sheet: _sheetWithCells(
          '<c r="A1" t="s"><v>0</v></c>'
          '<c r="B1" t="s"><v>1</v></c>'
          '<c r="C1" t="s"><v>2</v></c>',
        ),
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, '第一行\n第二行');
      expect(_cell(sheet, 0, 1).text, '回车\r后面');
      expect(_cell(sheet, 0, 2).text, 'a&b<c>d"e\'f');
    });
  });

  group('inlineStr / 公式结果 / 数字 / 布尔', () {
    test('inlineStr（<is><t>）', () {
      final xml = _xlsxWith(
        sheet: _sheetWithCells(
          '<c r="A1" t="inlineStr"><is><t>就地字符串</t></is></c>',
        ),
      );
      expect(_cell(_sheet(xml), 0, 0).text, '就地字符串');
    });

    test('t="str"（公式的字符串结果）取 <v>；WPS 的内嵌图片公式 DISPIMG 当空', () {
      final xml = _xlsxWith(
        sheet: _sheetWithCells(
          '<c r="A1" t="str"><f>CONCAT(A2,B2)</f><v>算出来的结果</v></c>'
          '<c r="B1" t="str"><f>_xlfn.DISPIMG(&quot;ID_XX&quot;,1)</f>'
          '<v>=DISPIMG(&quot;ID_XX&quot;,1)</v></c>',
        ),
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, '算出来的结果');
      expect(_cell(sheet, 0, 1).text, isEmpty,
          reason: 'WPS 单元格内嵌图片的假公式不是用户写的内容');
    });

    test('数字不带多余小数尾巴（3.0 → 3、1E3 → 1000），小数原样', () {
      final xml = _xlsxWith(
        sheet: _sheetWithCells(
          '<c r="A1"><v>3</v></c>'
          '<c r="B1"><v>3.0</v></c>'
          '<c r="C1"><v>1E3</v></c>'
          '<c r="D1"><v>3.5</v></c>'
          '<c r="E1"><v>-12.25</v></c>',
        ),
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, '3');
      expect(_cell(sheet, 0, 1).text, '3');
      expect(_cell(sheet, 0, 2).text, '1000');
      expect(_cell(sheet, 0, 3).text, '3.5');
      expect(_cell(sheet, 0, 4).text, '-12.25');
    });

    test('布尔 t="b" → TRUE / FALSE；错误值 t="e" 当空', () {
      final xml = _xlsxWith(
        sheet: _sheetWithCells(
          '<c r="A1" t="b"><v>1</v></c>'
          '<c r="B1" t="b"><v>0</v></c>'
          '<c r="C1" t="e"><v>#DIV/0!</v></c>',
        ),
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, 'TRUE');
      expect(_cell(sheet, 0, 1).text, 'FALSE');
      expect(_cell(sheet, 0, 2).text, isEmpty);
    });
  });

  group('缺省 r 属性 / 空单元格 / 纯样式', () {
    test('单元格没有 r → 按行内顺序（接在前一格列号之后）推断列号', () {
      final xml = _xlsxWith(
        sheet: '<worksheet><sheetData><row r="1">'
            '<c t="inlineStr"><is><t>A</t></is></c>'
            '<c r="C1" t="inlineStr"><is><t>C</t></is></c>'
            '<c t="inlineStr"><is><t>D</t></is></c>'
            '</row></sheetData></worksheet>',
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, 'A', reason: '第一格没 r ⇒ 列 A');
      expect(_cell(sheet, 0, 2).text, 'C');
      expect(_cell(sheet, 0, 3).text, 'D', reason: '没 r 的格子接在 C 之后 ⇒ D');
      expect(_cell(sheet, 0, 1).text, isEmpty);
    });

    test('行没有 r → 按出现顺序推断行号', () {
      final xml = _xlsxWith(
        sheet: '<worksheet><sheetData>'
            '<row><c r="A1" t="inlineStr"><is><t>第一</t></is></c></row>'
            '<row><c r="A2" t="inlineStr"><is><t>第二</t></is></c></row>'
            '</sheetData></worksheet>',
      );
      final sheet = _sheet(xml);
      expect(sheet.rows.map((r) => r.index).toList(), [0, 1]);
      expect(_cell(sheet, 1, 0).text, '第二');
    });

    test('无字无色的格子不生成；**只有底色没文本的格子要保留**；整行纯样式不产出行',
        () {
      final xml = _xlsxWith(
        styles: _stylesIndirect,
        sheet: '<worksheet><sheetData>'
            '<row r="1">'
            '<c r="A1" s="2" t="inlineStr"><is><t>有字没色</t></is></c>'
            '<c r="B1" s="1"/>' // 只有底色（黄）
            '<c r="C1" s="2"/>' // 纯样式（无色无字）→ 丢
            '</row>'
            '<row r="2"><c r="A2" s="2"/><c r="C2" s="2"/></row>'
            '</sheetData></worksheet>',
      );
      final sheet = _sheet(xml);
      expect(sheet.rows.length, 1, reason: '第 2 行全是纯样式格子 ⇒ 不产出行');
      expect(_cell(sheet, 0, 0).text, '有字没色');
      expect(_cell(sheet, 0, 0).colorIndex, 0);
      expect(_cell(sheet, 0, 1).text, isEmpty);
      expect(_cell(sheet, 0, 1).colorIndex, 1, reason: '只有底色的格子必须留下来');
      expect(_cell(sheet, 0, 2).isEmpty, isTrue);
      expect(sheet.rows.first.cells.containsKey(2), isFalse);
    });
  });

  group('命名空间前缀容错', () {
    test('<x:c> / </x:c> / x:si / x:t 一律能认', () {
      final xml = _xlsx(
        {
          'xl/workbook.xml': '<x:workbook><x:sheets>'
              '<x:sheet name="Sheet1" sheetId="1" r:id="rId1"/></x:sheets></x:workbook>',
          'xl/_rels/workbook.xml.rels':
              '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
                  '</Relationships>',
          'xl/sharedStrings.xml': '<x:sst><x:si><x:t>前缀也能读</x:t></x:si></x:sst>',
          'xl/styles.xml': '<x:styleSheet><x:fills count="2">'
              '<x:fill><x:patternFill patternType="none"/></x:fill>'
              '<x:fill><x:patternFill patternType="solid">'
              '<x:fgColor rgb="FF92D050"/></x:patternFill></x:fill>'
              '</x:fills><x:cellXfs count="2"><x:xf fillId="0"/><x:xf fillId="1"/>'
              '</x:cellXfs></x:styleSheet>',
          'xl/worksheets/sheet1.xml': '<x:worksheet><x:sheetData><x:row r="1">'
              '<x:c r="A1" t="s" s="1"><x:v>0</x:v></x:c>'
              '</x:row></x:sheetData></x:worksheet>',
        },
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, '前缀也能读');
      expect(_cell(sheet, 0, 0).colorIndex, 3, reason: '92D050 = 色板第 3 个（绿）');
    });
  });

  group('颜色映射', () {
    test('原型那 5 色精确命中对应下标', () {
      const cases = <String, int>{
        'FFFF00': 1,
        'BFBFBF': 2,
        '92D050': 3,
        'FF0000': 4,
        '00B0F0': 5,
        'FF9933': 6,
        'CC99FF': 7,
      };
      cases.forEach((hex, index) {
        expect(scheduleColorIndexForRgb(int.parse(hex, radix: 16)), index,
            reason: '#$hex 应当命中色板第 $index 个');
        // 带 alpha 的 8 位写法要丢掉前两位再比
        expect(scheduleColorIndexForRgb(int.parse('FF$hex', radix: 16)), index);
      });
    });

    test('接近色板色（逐通道差 ≤ 16）归到最近色；差得远 → 无色', () {
      // 黄 FFFF00 ± 8（每通道差 8，在容差内）
      expect(scheduleColorIndexForRgb(0xFFF808), 1);
      expect(scheduleColorIndexForRgb(0xF7F700), 1);
      // 绿 92D050 的近似（差 4 / 6 / 2）
      expect(scheduleColorIndexForRgb(0x96CA52), 3);
      // 差得远：浅橙 FFFFCC99 离橙 51、离黄 153 → 无色
      expect(scheduleColorIndexForRgb(0xFFCC99), 0);
      // 完全无关的颜色
      expect(scheduleColorIndexForRgb(0x123456), 0);
      expect(scheduleColorIndexForRgb(0xFFFFFF), 0);
      expect(scheduleColorIndexForRgb(0x000000), 0);
    });

    test('patternType 不是 solid（none / gray125）/ 只有 theme / indexed → 无色', () {
      final xml = _xlsxWith(
        styles: '<styleSheet><fills count="5">'
            '<fill><patternFill patternType="none"><fgColor rgb="FFFFFF00"/></patternFill></fill>'
            '<fill><patternFill patternType="gray125"/></fill>'
            '<fill><patternFill patternType="solid"><fgColor theme="4"/></patternFill></fill>'
            '<fill><patternFill patternType="solid"><fgColor indexed="64"/></patternFill></fill>'
            '<fill><patternFill patternType="solid"><fgColor rgb="1F4E79"/></patternFill></fill>'
            '</fills><cellXfs count="5"><xf fillId="0"/><xf fillId="1"/><xf fillId="2"/>'
            '<xf fillId="3"/><xf fillId="4"/></cellXfs></styleSheet>',
        sheet: _sheetWithCells(
          '<c r="A1" s="0" t="inlineStr"><is><t>a</t></is></c>'
          '<c r="B1" s="1" t="inlineStr"><is><t>b</t></is></c>'
          '<c r="C1" s="2" t="inlineStr"><is><t>c</t></is></c>'
          '<c r="D1" s="3" t="inlineStr"><is><t>d</t></is></c>'
          '<c r="E1" s="4" t="inlineStr"><is><t>e</t></is></c>',
        ),
      );
      final sheet = _sheet(xml);
      for (var c = 0; c < 5; c++) {
        expect(_cell(sheet, 0, c).colorIndex, 0,
            reason: '第 $c 格的底色不该被认出来（none/图案/theme/indexed/非色板色）');
      }
    });

    test('s → cellXfs[fillId] → fills 的间接层不会被写成 fills[s]', () {
      final xml = _xlsxWith(
        styles: _stylesIndirect,
        sheet: _sheetWithCells(
          '<c r="A1" s="0" t="inlineStr"><is><t>a</t></is></c>'
          '<c r="B1" s="1" t="inlineStr"><is><t>b</t></is></c>',
        ),
      );
      final sheet = _sheet(xml);
      // cellXfs[0].fillId=2 → fills[2] = 红(4)；cellXfs[1].fillId=1 → fills[1] = 黄(1)
      expect(_cell(sheet, 0, 0).colorIndex, 4);
      expect(_cell(sheet, 0, 1).colorIndex, 1);
    });

    test('样式下标越界 / 缺 styles.xml → 全部无色（不抛）', () {
      final xml = _xlsxWith(
        styles: '<styleSheet><fills count="1"><fill/></fills>'
            '<cellXfs count="1"><xf fillId="0"/></cellXfs></styleSheet>',
        sheet: _sheetWithCells(
          '<c r="A1" s="99" t="inlineStr"><is><t>a</t></is></c>',
        ),
      );
      expect(_cell(_sheet(xml), 0, 0).colorIndex, 0);
      final noStyles = _xlsxWith(
        sheet: _sheetWithCells(
          '<c r="A1" s="3" t="inlineStr"><is><t>a</t></is></c>',
        ),
      );
      expect(_cell(_sheet(noStyles), 0, 0).colorIndex, 0);
    });
  });

  group('畸形输入一律不抛', () {
    test('不是 zip（随便几个字节）→ readXlsx 返回 null', () {
      expect(readXlsx(Uint8List.fromList(utf8.encode('hello, not a zip'))), isNull);
      expect(readXlsx(Uint8List.fromList(List<int>.filled(64, 0x41))), isNull);
      expect(readXlsx(Uint8List.fromList(const <int>[])), isNull);
    });

    test('zip 合法但一个工作表都没有 → null', () {
      final xml = _xlsx({'docProps/core.xml': '<core/>'});
      expect(readXlsx(xml), isNull);
    });

    test('缺 xl/workbook.xml，但 zip 里有 worksheet → 退路仍能读到表', () {
      final xml = _xlsx({
        'xl/worksheets/sheet1.xml': _sheetWithCells(
          '<c r="A1" t="inlineStr"><is><t>退路</t></is></c>',
        ),
      });
      final wb = readXlsx(xml)!;
      expect(wb.importableSheets, hasLength(1));
      expect(_cell(wb.readSheet(wb.importableSheets.first)!, 0, 0).text, '退路');
    });

    test('XML 截断（没闭合的 row / cell）→ 已完整的部分照样解析出来', () {
      final xml = _xlsxWith(
        sheet: '<worksheet><sheetData><row r="1">'
            '<c r="A1" t="inlineStr"><is><t>完整的</t></is></c>'
            '<c r="B1" t="inlineStr"><is><t>截断的',
      );
      final sheet = _sheet(xml);
      expect(_cell(sheet, 0, 0).text, '完整的');
      // 截断那一格也尽量给出内容（有 <t> 就算），总之不能抛
      expect(() => _cell(sheet, 0, 1), returnsNormally);
    });

    test('空表（没有 row）/ 空 <v> 都不抛，且没有可导入内容', () {
      final xml = _xlsxWith(sheet: '<worksheet><sheetData/></worksheet>');
      final sheet = _sheet(xml);
      expect(sheet.rows, isEmpty);
      expect(buildScheduleFromSheet(sheet), isNull);
    });
  });

  group('工作表列表（workbook.xml + rels）', () {
    test('表名、顺序、路径（含绝对 Target）都对；隐藏表标记出来', () {
      final xml = _xlsx({
        'xl/workbook.xml': '<workbook><sheets>'
            '<sheet name="第一" sheetId="1" r:id="rId1"/>'
            '<sheet name="隐藏表" sheetId="2" state="veryHidden" r:id="rId2"/>'
            '<sheet name="WpsReserved_CellImgList" sheetId="3" r:id="rId3"/>'
            '</sheets></workbook>',
        'xl/_rels/workbook.xml.rels': '<Relationships>'
            '<Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
            '<Relationship Id="rId2" Target="/xl/worksheets/sheet9.xml"/>'
            '<Relationship Id="rId3" Target="worksheets/sheet3.xml"/>'
            '</Relationships>',
        'xl/worksheets/sheet1.xml': _sheetWithCells('<c r="A1"><v>1</v></c>'),
        'xl/worksheets/sheet9.xml': _sheetWithCells('<c r="A1"><v>2</v></c>'),
        'xl/worksheets/sheet3.xml': _sheetWithCells('<c r="A1"><v>3</v></c>'),
      });
      final wb = readXlsx(xml)!;
      expect(wb.sheetRefs.map((r) => r.name).toList(),
          ['第一', '隐藏表', 'WpsReserved_CellImgList']);
      expect(wb.sheetRefs[1].path, 'xl/worksheets/sheet9.xml',
          reason: '绝对路径 Target 要能解析成 zip 内路径');
      expect(wb.sheetRefs[1].hidden, isTrue);
      // WPS 保留表要能被过滤掉；隐藏表**保留**（让用户自己决定）
      expect(wb.importableSheets.map((r) => r.name).toList(), ['第一', '隐藏表']);
    });

    test('rels 指到不存在（或路径错的）表 → 那张表不出现在可导入列表里', () {
      final xml = _xlsx({
        'xl/workbook.xml': _workbook1,
        'xl/_rels/workbook.xml.rels': _rels1,
      });
      final wb = readXlsx(xml)!;
      expect(wb.sheetRefs, hasLength(1));
      expect(wb.importableSheets, isEmpty);
      expect(wb.readSheet(wb.sheetRefs.first), isNull);
    });
  });

  group('→ ScheduleData（含夹具文件）', () {
    test('openpyxl 生成的夹具：3 列 × 3 行、表头原样、空表头兜底、只有底色的格保留',
        () {
      final bytes = File('test/fixtures/schedule_sample.xlsx').readAsBytesSync();
      final wb = readXlsx(bytes)!;
      expect(wb.sheetRefs.map((r) => r.name).toList(),
          ['课程表', '第二张表', 'WpsReserved_CellImgList']);
      // WPS 保留表被过滤掉，剩下两张
      expect(wb.importableSheets.map((r) => r.name).toList(), ['课程表', '第二张表']);

      final sheet = wb.readSheet(wb.importableSheets.first)!;
      final preview = buildScheduleFromSheet(sheet)!;
      expect(preview.columnCount, 3);
      expect(preview.rowCount, 3);
      expect(preview.headerRowIndex, 0);
      expect(preview.coloredCells, 4);
      expect(preview.textCells, 6);
      expect(preview.truncated, isFalse);

      // 列头：原样（含「星期一9.14」），空表头兜底成「第3列」，一列都不丢
      expect(preview.data.columns.map((c) => c.label).toList(),
          ['星期日', '星期一9.14', '第3列']);
      expect(preview.data.columns.map((c) => c.id).toList(), ['c1', 'c2', 'c3']);

      // 行：3 行，id 从 r1 开始（与页面行头 1/2/3 一致）
      expect(preview.data.rows.map((r) => r.id).toList(), ['r1', 'r2', 'r3']);
      final r1 = preview.data.rows[0];
      expect(r1.cell('c1').text, '写代码');
      expect(r1.cell('c1').colorIndex, 1, reason: '黄底');
      expect(r1.cell('c2').text, '交作业');
      expect(r1.cell('c3').text, isEmpty);
      expect(r1.cell('c3').colorIndex, 4, reason: '只有红底没文本的格子要保留');

      final r2 = preview.data.rows[1];
      expect(r2.cell('c1').text, '背单词');
      expect(r2.cell('c1').colorIndex, 2, reason: '灰底');
      expect(r2.cell('c3').text, '看书');

      final r3 = preview.data.rows[2];
      expect(r3.cell('c2').text, '3', reason: '数字 3 不带小数尾巴');
      expect(r3.cell('c3').text, '跑步');
      expect(r3.cell('c3').colorIndex, 3, reason: '绿底');

      // 表头行的底色不进 App（列头只有文本），所以有色格数只数数据区
      expect(preview.data.columns, hasLength(3));
    });

    test('表头 = 第一行**有文本**的行（前导空行跳过）', () {
      final xml = _xlsxWith(
        sheet: '<worksheet><sheetData>'
            '<row r="1"><c r="A1" s="0"/></row>'
            '<row r="2"><c r="A2" s="0"/><c r="B2" s="0"/></row>'
            '<row r="3"><c r="A3" t="inlineStr"><is><t>周一</t></is></c>'
            '<c r="B3" t="inlineStr"><is><t>周二</t></is></c></row>'
            '<row r="4"><c r="A4" t="inlineStr"><is><t>写代码</t></is></c></row>'
            '</sheetData></worksheet>',
        styles: '<styleSheet><fills count="1"><fill/></fills>'
            '<cellXfs count="1"><xf fillId="0"/></cellXfs></styleSheet>',
      );
      final preview = buildScheduleFromSheet(_sheet(xml))!;
      expect(preview.headerRowIndex, 2, reason: '表头在第 3 行（0-based 2）');
      expect(preview.data.columns.map((c) => c.label).toList(), ['周一', '周二']);
      expect(preview.rowCount, 1);
      expect(preview.data.rows.single.cell('c1').text, '写代码');
    });

    test('数据行之间补空行（Excel 里隔了几行，App 里也隔几行）', () {
      final xml = _xlsxWith(
        sheet: '<worksheet><sheetData>'
            '<row r="1"><c r="A1" t="inlineStr"><is><t>周一</t></is></c></row>'
            '<row r="2"><c r="A2" t="inlineStr"><is><t>第一天</t></is></c></row>'
            '<row r="5"><c r="A5" t="inlineStr"><is><t>第四天</t></is></c></row>'
            '</sheetData></worksheet>',
      );
      final preview = buildScheduleFromSheet(_sheet(xml))!;
      expect(preview.rowCount, 4);
      expect(preview.data.rows.map((r) => r.cell('c1').text).toList(),
          ['第一天', '', '', '第四天']);
      expect(preview.data.rows[1].isEmpty, isTrue);
    });

    test('超长文本照原样存（不截断，页面自己省略显示）', () {
      final long = '很长的内容' * 40;
      final xml = _xlsxWith(
        sheet: _sheetWithCells(
          '<c r="A1" t="inlineStr"><is><t>$long</t></is></c>',
        ),
      );
      expect(_cell(_sheet(xml), 0, 0).text, long);
    });

    test('超过上限的行/列被截断，并标记 truncated', () {
      final rows = StringBuffer('<row r="1">'
          '<c r="A1" t="inlineStr"><is><t>表头</t></is></c>'
          '<c r="B1" t="inlineStr"><is><t>第二列</t></is></c></row>');
      for (var i = 0; i < kXlsxMaxRows + 20; i++) {
        rows.write('<row r="${i + 2}"><c r="A${i + 2}" t="inlineStr">'
            '<is><t>x</t></is></c></row>');
      }
      final wide = StringBuffer('<row r="1">'
          '<c r="A1" t="inlineStr"><is><t>表头</t></is></c>');
      for (var i = 0; i < kXlsxMaxColumns + 5; i++) {
        final col = _columnName(i + 2);
        wide.write('<c r="${col}1" t="inlineStr"><is><t>c$i</t></is></c>');
      }
      wide.write('</row><row r="2"><c r="A2" t="inlineStr"><is><t>x</t></is></c></row>');

      final byRow = buildScheduleFromSheet(_sheet(
        _xlsxWith(sheet: '<worksheet><sheetData>$rows</sheetData></worksheet>'),
      ))!;
      expect(byRow.rowCount, kXlsxMaxRows);
      expect(byRow.truncatedRows, isTrue);
      expect(byRow.truncatedColumns, isFalse);

      final byCol = buildScheduleFromSheet(_sheet(
        _xlsxWith(sheet: '<worksheet><sheetData>$wide</sheetData></worksheet>'),
      ))!;
      expect(byCol.columnCount, kXlsxMaxColumns);
      expect(byCol.truncatedColumns, isTrue);
      expect(byCol.truncated, isTrue);
    });

    test('整张表一个文本都没有（只有底色）→ 表头兜底、列不丢、行是空行', () {
      final xml = _xlsxWith(
        styles: _stylesIndirect,
        sheet: '<worksheet><sheetData>'
            '<row r="1"><c r="A1" s="1"/><c r="B1" s="1"/></row>'
            '<row r="2"><c r="A2" s="1"/></row>'
            '<row r="3"><c r="A3" s="1"/><c r="B3" s="1"/></row>'
            '</sheetData></worksheet>',
      );
      final preview = buildScheduleFromSheet(_sheet(xml))!;
      expect(preview.data.columns.map((c) => c.label).toList(), ['第1列', '第2列']);
      expect(preview.rowCount, 2);
      // 表头行（第 1 行）的底色不进 App，所以只数数据区的 3 格
      expect(preview.coloredCells, 3);
      expect(preview.textCells, 0);
      expect(preview.data.rows.every((r) => r.cells.values.every((c) => c.text.isEmpty)),
          isTrue);
    });
  });
}

/// 0-based 列下标 → Excel 列名（1 → A）。
String _columnName(int index) {
  var n = index + 1;
  final out = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    out.write(String.fromCharCode(0x41 + rem));
    n = (n - 1) ~/ 26;
  }
  return out.toString().split('').reversed.join();
}
