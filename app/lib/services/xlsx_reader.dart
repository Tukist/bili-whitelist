/// 手写最小 xlsx（Excel 2007+ / WPS 表格）读取器（v2.34.0）。
///
/// **为什么不引 `excel` / `spreadsheet_decoder` / `xml` 这类包**：
/// xlsx 本身就是「一个 zip + 几个 XML」，而本项目**已经有** `archive`
/// （原用途：解 sherpa 模型的 tar.bz2），解 zip 这一步不用新依赖；
/// 我们真正需要的 XML 只有 4 个 entry 里的几个标签（sharedStrings / styles /
/// workbook / sheetN），为这点需求引一个包会把整条依赖链（以及它的升级、
/// 与 Flutter 版本的兼容）绑进来，而它替我们省的代码量不到 300 行。
/// 所以这里手写：**用「按标签名扫一遍」的极简扫描器**，不做完整 DOM 解析。
///
/// **容错口径（第一优先级）**：用户可能从任何地方拿到 xlsx（WPS 导出的、
/// 别人发的、被网盘截断的），这个读取器**任何输入都不抛**——
/// 坏 zip / 缺 entry / XML 截断 / 命名空间前缀异常 → 返回 null 或空结果，
/// 由调用方（日程页）给一句人话提示。抛异常会让「导入」这条链路从"提示一下"
/// 变成"崩一下就白点"。
///
/// 支持的单元格形态（每条都有单测）：
/// 1. `t="s"` 共享字符串（含富文本多 `<r>` run 拼接、`xml:space="preserve"`）；
/// 2. `t="inlineStr"`（`<is><t>`）；
/// 3. `t="str"`（公式的字符串结果）与数字 / 布尔（`t="b"`）；
/// 4. 单元格 `r="A1"` 缺省时按「行内出现顺序 + 前一格的列号」推断；
/// 5. 无文本无底色的格子不生成、**只有底色没文本的格子保留**；
/// 6. 命名空间前缀（`<x:c>` / `</x:c>` / `x:si`）一律容忍；
/// 7. 畸形输入（见上）。
///
/// 颜色：只认 `fgColor` 的 **`rgb` 字面量**，且必须满足 `patternType="solid"`；
/// `theme` / `indexed` 色**不猜**（本 App 的色板就 7 个色，主题色/索引色要靠
/// theme1.xml 的色轮 + tint 才能还原，猜错比"无色"更烦人）→ 当无色。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../models/schedule.dart';

/// 颜色容差：**每个通道**的最大允许差值。
///
/// 为什么是"逐通道 ≤16"而不是"欧氏距离 ≤ 某值"：色板里的 5 个原型色
/// （FFFF00 / BFBFBF / 92D050 / FF0000 / 00B0F0）两两之间的**最小**通道差
/// 是 0x6D = 109（黄 vs 绿的红通道），所以 16 这个阈值离"误判成另一个色板色"
/// 还有 6 倍余量；它同时能把 Excel 里常见的"近似色"挡在外面——
/// 例如用户那个文件里的 `FFFFCC99`（浅橙）离色板橙 FF9933 的绿通道差 0x33 = 51，
/// 离色板黄 FFFF00 的蓝通道差 0x99 = 153 → 都判**无色**。
/// 换句话说：**越远越倾向无色**，宁可少一个底色，也不把用户没选过的颜色染上去
/// （同 [scheduleColorAt] 越界不收敛的取舍）。
const int kXlsxColorChannelTolerance = 16;

/// 导入行数上限（含表头行之后的数据行）。
///
/// 日程网格是「一次性把每个格子都 build 出来」的（没有懒加载/虚拟化），
/// 一份 5000 行的表会直接造出十万级的 Widget 把 App 卡死。用户这张表是
/// 49 行，500 留了十倍余量；超出的部分截断，并在预览弹层里写明「已截断」。
const int kXlsxMaxRows = 500;

/// 导入列数上限。理由同上（用户这张表 23 列）。
const int kXlsxMaxColumns = 64;

// ============================================================================
// 数据结构
// ============================================================================

/// 工作表引用（暴露给 UI 让用户选表）。
@immutable
class XlsxSheetRef {
  final String name;

  /// zip 内路径，形如 `xl/worksheets/sheet1.xml`。
  final String path;

  /// 工作簿里标了 `state="hidden" / veryHidden`（隐藏表）。
  final bool hidden;

  const XlsxSheetRef({
    required this.name,
    required this.path,
    this.hidden = false,
  });

  /// WPS 的保留表（`WpsReserved_CellImgList` 等）：用来存"单元格内嵌图片"
  /// 这类 WPS 私有数据的**实现细节表**，不是用户的内容表。
  /// 按名字前缀过滤——这是 WPS 自己定的命名约定，不是通用规则。
  bool get isWpsReserved => name.startsWith('WpsReserved');

  @override
  String toString() => 'XlsxSheetRef("$name", $path${hidden ? ', hidden' : ''})';
}

/// 一个格子（已解析成文本 + 色板下标）。
@immutable
class XlsxCell {
  final String text;

  /// 已映射到 [kScheduleColors] 的下标；0 = 无色。
  final int colorIndex;

  const XlsxCell({this.text = '', this.colorIndex = 0});

  /// 无字也无色 —— 这种格子不进 [XlsxRow.cells]（省内存，也让"整行空"可判定）。
  bool get isEmpty => text.isEmpty && colorIndex == 0;

  @override
  String toString() => 'XlsxCell("$text", c=$colorIndex)';
}

/// 一行（只含**有内容**的格子，key = 0-based 列下标）。
@immutable
class XlsxRow {
  /// 0-based 行下标（来自 `<row r="N">`，缺省时按出现顺序推断）。
  final int index;

  final Map<int, XlsxCell> cells;

  const XlsxRow({required this.index, required this.cells});

  String textAt(int column) => cells[column]?.text ?? '';

  int colorAt(int column) => cells[column]?.colorIndex ?? 0;

  bool get isEmpty => cells.isEmpty;

  @override
  String toString() => 'XlsxRow($index, ${cells.length} cells)';
}

/// 一张解析完的工作表。
@immutable
class XlsxSheetData {
  final XlsxSheetRef ref;

  /// 只含"有内容"的行，按行下标升序；行与行之间**可能是跳号的**
  /// （中间整行空的行不会出现在这里，由 [buildScheduleFromSheet] 补空行）。
  final List<XlsxRow> rows;

  const XlsxSheetData({required this.ref, required this.rows});

  /// 全表最大列下标（0-based）；-1 = 一个格子都没有。
  int get maxColumn {
    var max = -1;
    for (final r in rows) {
      for (final c in r.cells.keys) {
        if (c > max) max = c;
      }
    }
    return max;
  }

  @override
  String toString() => 'XlsxSheetData("${ref.name}", ${rows.length} rows)';
}

/// 解析出的工作簿（只留了导入用得上的那几样）。
class XlsxWorkbook {
  final List<XlsxSheetRef> sheetRefs;
  final List<String> sharedStrings;

  /// `cellXfs` 下标 → 色板下标（0 = 无色）。单元格的 `s` 属性就是这个下标。
  final List<int> styleColors;

  /// zip 里的 XML 原文（只缓存上面那几个 entry）。
  final Map<String, String> _xml;

  XlsxWorkbook({
    required this.sheetRefs,
    required this.sharedStrings,
    required this.styleColors,
    required Map<String, String> xml,
  }) : _xml = xml;

  /// 可导入的表：**在 zip 里真的能读到 + 不是 WPS 保留表**。
  ///
  /// 隐藏表**不**在这里过滤：`state="hidden"` 是用户的显示设置，
  /// 表里可能仍然是他要的内容，让他在选表弹层里自己看到并决定。
  List<XlsxSheetRef> get importableSheets => [
        for (final r in sheetRefs)
          if (_xml.containsKey(r.path) && !r.isWpsReserved) r,
      ];

  /// 解析某张表；路径在 zip 里不存在 / XML 读不出来 → null。
  XlsxSheetData? readSheet(XlsxSheetRef ref) {
    final xml = _xml[ref.path];
    if (xml == null) return null;
    return parseWorksheet(
      ref,
      xml,
      sharedStrings: sharedStrings,
      styleColors: styleColors,
    );
  }
}

/// 导入预览：转换结果 + 给用户看的统计（列/行/有底色的格数）。
@immutable
class XlsxImportPreview {
  final ScheduleData data;

  /// 列数 / 数据行数（不含表头行）。
  final int columnCount;
  final int rowCount;

  /// 数据区里有底色的格数（表头行的底色不进 App：列头只有文本）。
  final int coloredCells;

  /// 数据区里有文本的格数。
  final int textCells;

  /// 是否因为超过 [kXlsxMaxRows] / [kXlsxMaxColumns] 被截断。
  final bool truncatedRows;
  final bool truncatedColumns;

  /// 表头在文件里的 0-based 行下标（诊断/测试用）。
  final int headerRowIndex;

  const XlsxImportPreview({
    required this.data,
    required this.columnCount,
    required this.rowCount,
    required this.coloredCells,
    required this.textCells,
    required this.headerRowIndex,
    this.truncatedRows = false,
    this.truncatedColumns = false,
  });

  bool get truncated => truncatedRows || truncatedColumns;
}

// ============================================================================
// 顶层入口
// ============================================================================

/// 读一个 xlsx 文件。**任何输入都不抛**：不是 zip / 缺 xl/workbook.xml 且
/// 又找不到任何 sheet → null。
///
/// 只解压 5 个 entry（workbook / rels / sharedStrings / styles /
/// worksheets/*.xml），**不碰** media/ 里的图片与 drawings/
/// （用户那张表里有 500KB 的图片，全解出来纯属浪费内存）。
XlsxWorkbook? readXlsx(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return null; // 不是 zip（或截断 / 加密）：调用方给"不是有效的 xlsx"提示
  }

  final xml = <String, String>{};
  // 读不到的 entry 单独记一份：`xml` 里只放**真的读到了**的内容，
  // 否则 `importableSheets` 会以为"空字符串"也是一张能读的表。
  final missing = <String>{};
  String? read(String name) {
    final cached = xml[name];
    if (cached != null) return cached;
    if (missing.contains(name)) return null;
    String? text;
    try {
      final f = archive.findFile(name);
      if (f != null && f.isFile) {
        text = utf8.decode(f.content as List<int>, allowMalformed: true);
      }
    } catch (_) {
      text = null;
    }
    if (text == null) {
      missing.add(name);
      return null;
    }
    xml[name] = text;
    return text;
  }

  final workbookXml = read('xl/workbook.xml');
  final relsXml = read('xl/_rels/workbook.xml.rels') ?? '';

  var refs = parseSheetRefs(workbookXml ?? '', relsXml);
  if (refs.isEmpty) {
    // workbook.xml 缺失/损坏 → 退化成"把 zip 里所有 worksheets 按名字排一下"。
    // 这条退路比直接报"解析失败"友好得多：表就在那儿，只是入口文件坏了。
    refs = _sheetRefsFromZipEntries(archive);
  }
  if (refs.isEmpty) return null;

  // 把每张表的 XML 也读进来（读不到的会被 importableSheets 过滤掉）
  for (final r in refs) {
    read(r.path);
  }

  final stylesXml = read('xl/styles.xml') ?? '';
  return XlsxWorkbook(
    sheetRefs: refs,
    sharedStrings: parseSharedStrings(read('xl/sharedStrings.xml') ?? ''),
    styleColors: parseStyleColors(stylesXml),
    xml: xml,
  );
}

// ============================================================================
// workbook.xml + rels
// ============================================================================

/// 从 `xl/workbook.xml` 读表名/顺序 + 从 rels 解出它的 xml 路径。
///
/// `r:id="rId1"` → rels 里 `Id="rId1"` 的 `Target="worksheets/sheet1.xml"`，
/// 相对 `xl/` 解析（也有写入器给绝对路径 `/xl/worksheets/...`，一并兼容）。
List<XlsxSheetRef> parseSheetRefs(String workbookXml, String relsXml) {
  final targets = <String, String>{};
  for (final rel in _elements(relsXml, 'Relationship')) {
    final id = _attr(rel.start, 'Id');
    final target = _attr(rel.start, 'Target');
    if (id == null || target == null || target.isEmpty) continue;
    targets[id] = _resolveTarget(target);
  }

  final out = <XlsxSheetRef>[];
  for (final sheet in _elements(workbookXml, 'sheet')) {
    final name = _attr(sheet.start, 'name') ?? '';
    if (name.isEmpty) continue;
    // r:id 要连前缀一起找（只找 "id" 会撞上 "sheetId"）
    final rid = _attr(sheet.start, 'r:id') ?? _attr(sheet.start, 'id') ?? '';
    final path = targets[rid] ?? 'xl/worksheets/sheet${out.length + 1}.xml';
    final state = _attr(sheet.start, 'state') ?? '';
    out.add(XlsxSheetRef(
      name: name,
      path: path,
      hidden: state == 'hidden' || state == 'veryHidden',
    ));
  }
  return out;
}

String _resolveTarget(String target) {
  final t = target.replaceAll('\\', '/');
  if (t.startsWith('/')) return t.substring(1);
  return 'xl/$t';
}

/// workbook.xml 缺失时的退路：zip 里所有 `xl/worksheets/*.xml`，
/// 按名字里的数字自然序（sheet2 在 sheet10 前面）。
List<XlsxSheetRef> _sheetRefsFromZipEntries(Archive archive) {
  final names = <String>[];
  for (final f in archive) {
    if (!f.isFile) continue;
    final n = f.name.replaceAll('\\', '/');
    if (n.startsWith('xl/worksheets/') && n.endsWith('.xml')) names.add(n);
  }
  names.sort((a, b) {
    final na = _trailingNumber(a), nb = _trailingNumber(b);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    return a.compareTo(b);
  });
  return [
    for (var i = 0; i < names.length; i++)
      XlsxSheetRef(name: 'Sheet${i + 1}', path: names[i]),
  ];
}

int? _trailingNumber(String path) {
  final m = RegExp(r'(\d+)\.xml$').firstMatch(path);
  return m == null ? null : int.tryParse(m.group(1)!);
}

// ============================================================================
// sharedStrings.xml
// ============================================================================

/// 共享字符串表：`<si>` 按顺序就是 `t="s"` 单元格 `<v>` 的下标。
///
/// 一个 `<si>` 里可能有多个 `<r>` run（富文本：一段加粗 + 一段普通），
/// 每段里各有一个 `<t>`，**要拼起来**才是完整文本；
/// `xml:space="preserve"` 的前后空格必须保留（所以这里一律不 trim，
/// 是否"空"由调用方按 trim 后的结果判断）。
List<String> parseSharedStrings(String xml) {
  final out = <String>[];
  for (final si in _elements(xml, 'si')) {
    out.add(_richText(si.inner));
  }
  return out;
}

/// 取 `<si>` / `<is>` 里的纯文本：拼所有 `<t>`，忽略 `<rPh>`（注音）。
String _richText(String inner) {
  var s = inner;
  // `<si>` 的子元素顺序是 t / r / rPh(注音) / phoneticPr，注音里也有 <t>，
  // 但它不是单元格文本 → 从第一个 <rPh 起整段丢掉（前缀化写法 <x:rPh 同理）。
  final cut = s.indexOf('<rPh');
  if (cut >= 0) {
    s = s.substring(0, cut);
  } else {
    final cutNs = RegExp(r'<[\w.-]+:rPh').firstMatch(s);
    if (cutNs != null) s = s.substring(0, cutNs.start);
  }
  final b = StringBuffer();
  for (final t in _elements(s, 't')) {
    b.write(_decodeXmlText(t.inner));
  }
  return b.toString();
}

// ============================================================================
// styles.xml
// ============================================================================

/// `cellXfs` 下标 → 色板下标（0 = 无色）。
///
/// 中间隔着两层（这是 xlsx 最容易读错的地方）：
/// 单元格 `s="7"` → `cellXfs[7]` 的 `fillId="4"` → `fills[4]` 的
/// `patternFill/fgColor`。**不是** `fills[s]`。
List<int> parseStyleColors(String stylesXml) {
  final fills = _parseFills(stylesXml);
  if (fills.isEmpty) return const [];

  final block = _firstElement(stylesXml, 'cellXfs');
  if (block == null) return const [];
  final out = <int>[];
  for (final xf in _elements(block.inner, 'xf')) {
    final fillId = int.tryParse(_attr(xf.start, 'fillId') ?? '') ?? 0;
    out.add(fillId >= 0 && fillId < fills.length ? fills[fillId] : 0);
  }
  return out;
}

/// `fills` 每一项 → 色板下标。只有 `patternType="solid"` + `fgColor/@rgb` 才算有色。
List<int> _parseFills(String stylesXml) {
  final block = _firstElement(stylesXml, 'fills');
  if (block == null) return const [];
  final out = <int>[];
  for (final fill in _elements(block.inner, 'fill')) {
    out.add(_fillColorIndex(fill.inner));
  }
  return out;
}

int _fillColorIndex(String fillInner) {
  final pf = _firstElement(fillInner, 'patternFill');
  if (pf == null) return 0;
  final patternType = _attr(pf.start, 'patternType') ?? 'none';
  // `none`（无色）/ `gray125`（网格底纹）/ 各种图案填充 → 一律当无色：
  // 图案填充在 App 里没有对应表现，硬当成实色会失真。
  if (patternType != 'solid') return 0;
  final fg = _firstElement(pf.inner, 'fgColor');
  if (fg == null) return 0;
  final rgb = _attr(fg.start, 'rgb');
  if (rgb == null) return 0; // theme / indexed → 不猜（见文件头注释）
  final value = _parseRgbHex(rgb);
  if (value == null) return 0;
  return scheduleColorIndexForRgb(value);
}

/// `FFFF0000` / `FF0000` → 0xFF0000（丢掉 alpha 通道）。
int? _parseRgbHex(String raw) {
  var s = raw.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 8) s = s.substring(2);
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  return v;
}

/// 把 xlsx 的 RGB 映射到 [kScheduleColors] 的下标；判不准 → 0（无色）。
///
/// 规则：先找**逐通道差都 ≤ [kXlsxColorChannelTolerance]** 的最近色；
/// 找不到就无色。用户原型里那 5 个色是**精确相等**（差 0），必中。
int scheduleColorIndexForRgb(int rgb) {
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  var best = 0;
  var bestDistance = -1;
  for (var i = 0; i < kScheduleColors.length; i++) {
    final c = kScheduleColors[i];
    // 色板是 Color（通道 0..1 的 double），xlsx 那边是 0..255 的整数，
    // 统一到 0..255 再比（与 `c.red/green/blue` 的旧写法等价，那两个成员已废弃）。
    final dr = (_channel8(c.r) - r).abs();
    final dg = (_channel8(c.g) - g).abs();
    final db = (_channel8(c.b) - b).abs();
    if (dr > kXlsxColorChannelTolerance ||
        dg > kXlsxColorChannelTolerance ||
        db > kXlsxColorChannelTolerance) {
      continue;
    }
    final d = dr * dr + dg * dg + db * db;
    if (bestDistance < 0 || d < bestDistance) {
      bestDistance = d;
      best = i + 1;
    }
  }
  return best;
}

/// `Color` 的 0..1 通道 → 0..255 整数。
int _channel8(double channel) => (channel * 255.0).round().clamp(0, 255);

// ============================================================================
// worksheets/sheetN.xml
// ============================================================================

/// 解析一张工作表 → [XlsxSheetData]。**任何畸形输入都不抛**。
XlsxSheetData parseWorksheet(
  XlsxSheetRef ref,
  String xml, {
  required List<String> sharedStrings,
  required List<int> styleColors,
}) {
  final rows = <XlsxRow>[];
  var inferredRow = 0;
  for (final row in _elements(xml, 'row')) {
    final r = int.tryParse(_attr(row.start, 'r') ?? '');
    final index = (r != null && r > 0) ? r - 1 : inferredRow;
    inferredRow = index + 1;

    final cells = <int, XlsxCell>{};
    var previousColumn = -1;
    for (final c in _elements(row.inner, 'c')) {
      final cellRef = _attr(c.start, 'r');
      var column = cellRef == null ? previousColumn + 1 : _columnFromRef(cellRef);
      if (column < 0) column = previousColumn + 1; // r 写了但列号不认识
      previousColumn = column;

      final s = int.tryParse(_attr(c.start, 's') ?? '');
      final colorIndex =
          (s != null && s >= 0 && s < styleColors.length) ? styleColors[s] : 0;
      final text = _cellText(
        type: _attr(c.start, 't') ?? '',
        body: c.inner,
        sharedStrings: sharedStrings,
      );
      final cell = XlsxCell(text: text, colorIndex: colorIndex);
      // 空单元格 / 纯样式的格子（无字无色）不进结果；只有底色没文本的**保留**
      if (!cell.isEmpty) cells[column] = cell;
    }
    if (cells.isEmpty) continue; // 整行没内容：不产出行，行号仍然由 r 决定
    rows.add(XlsxRow(index: index, cells: cells));
  }
  rows.sort((a, b) => a.index.compareTo(b.index));
  return XlsxSheetData(ref: ref, rows: rows);
}

/// 单元格文本。按 `t` 分流（缺省 = 数字）。
String _cellText({
  required String type,
  required String body,
  required List<String> sharedStrings,
}) {
  switch (type) {
    case 's': // 共享字符串：<v> 是下标
      final i = int.tryParse(_firstText(body, 'v'));
      if (i == null || i < 0 || i >= sharedStrings.length) return '';
      return sharedStrings[i];
    case 'inlineStr': // 就地字符串：<is><t>…</t></is>
      final inline = _firstElement(body, 'is');
      return inline == null ? '' : _richText(inline.inner);
    case 'str': // 公式的字符串结果：<v> 就是文本
      final v = _firstElement(body, 'v');
      final text = v == null ? '' : _decodeXmlText(v.inner);
      // WPS 的「单元格内嵌图片」是个假公式 DISPIMG("ID_xxx",1)：
      // 图片我们导不进来（也不打算导），把这段公式文本当内容导进去只是噪音，
      // 所以整段丢掉——格子若还有底色，那个底色照样保留。
      if (text.startsWith('=DISPIMG(') || text.startsWith('DISPIMG(')) {
        return '';
      }
      return text;
    case 'b': // 布尔
      final v = _firstText(body, 'v').trim();
      if (v == '1' || v.toLowerCase() == 'true') return 'TRUE';
      if (v == '0' || v.toLowerCase() == 'false') return 'FALSE';
      return '';
    case 'e': // 错误值（#DIV/0! 之类）：不是用户写的内容
      return '';
    default: // 数字（也可能是写入器乱写的字符串）
      return _formatNumber(_firstText(body, 'v'));
  }
}

/// 数字 → 文本：整数值去掉小数尾巴（`3` 而不是 `3.0`），其它保持原样。
String _formatNumber(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  final d = double.tryParse(t);
  if (d == null || !d.isFinite) return t; // 不是数字就原样当文本
  if (d == d.roundToDouble() && d.abs() < 1e15) {
    return d.round().toString();
  }
  return t;
}

/// `AB12` → 26（0-based 列下标）；没有字母前缀 → -1。
int _columnFromRef(String ref) {
  var n = 0;
  var hasLetter = false;
  for (var i = 0; i < ref.length; i++) {
    final c = ref.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      n = n * 26 + (c - 0x40);
      hasLetter = true;
    } else if (c >= 0x61 && c <= 0x7A) {
      n = n * 26 + (c - 0x60);
      hasLetter = true;
    } else if (c == 0x20) {
      continue; // 容忍 "A 1" 这种带空格的脏写法
    } else {
      break;
    }
  }
  return hasLetter ? n - 1 : -1;
}

// ============================================================================
// → ScheduleData
// ============================================================================

/// 把一张表转成 App 的 [ScheduleData]，并算出给用户看的统计。
///
/// 规则（都与"用户在 Excel 里看到的样子"对齐）：
/// - **表头行** = 第一行**有文本**的行（前导空行会被跳过）；表头文本原样做
///   [ScheduleColumn.label]，**空表头给 `第N列` 兜底且不丢列**；
/// - **数据行** = 表头行之后的每一行，**按行号补空行**（Excel 里两段内容之间
///   隔了 10 个空行，App 里也隔 10 个空行，不把内容挤到一起）；
/// - 行 id 从 `r1` 开始（与页面行头显示的 1、2、3…一致），列 id 从 `c1` 开始；
/// - 单元格文本照原样存（超出格宽由页面自己省略显示）；
/// - 超过 [kXlsxMaxRows] / [kXlsxMaxColumns] 的部分截断，
///   截断标记回传给 UI 显示。
XlsxImportPreview? buildScheduleFromSheet(XlsxSheetData sheet) {
  if (sheet.rows.isEmpty) return null;

  // 表头行：第一行"有文本"的；整张表一个文本都没有（只有底色）→ 退回第一行
  XlsxRow? header;
  for (final r in sheet.rows) {
    if (r.cells.values.any((c) => c.text.isNotEmpty)) {
      header = r;
      break;
    }
  }
  header ??= sheet.rows.first;

  final rawColumns = sheet.maxColumn + 1;
  if (rawColumns <= 0) return null;
  final columnCount = math.min(rawColumns, kXlsxMaxColumns);
  final truncatedColumns = rawColumns > kXlsxMaxColumns;

  final dataRows = [
    for (final r in sheet.rows) if (r.index > header.index) r,
  ];
  final rawRowCount = dataRows.isEmpty
      ? 0
      // 按行号补空行：最后一行内容之前的空行都算进行数里
      : dataRows.last.index - header.index;
  final rowCount = math.min(rawRowCount, kXlsxMaxRows);
  final truncatedRows = rawRowCount > kXlsxMaxRows;

  final columns = <ScheduleColumn>[
    for (var c = 0; c < columnCount; c++)
      ScheduleColumn(
        id: 'c${c + 1}',
        label: _columnLabel(header, c),
      ),
  ];

  final byIndex = <int, XlsxRow>{for (final r in dataRows) r.index: r};
  var colored = 0;
  var texted = 0;
  final rows = <ScheduleRow>[];
  for (var i = 0; i < rowCount; i++) {
    final src = byIndex[header.index + 1 + i];
    final cells = <String, ScheduleCell>{};
    if (src != null) {
      for (var c = 0; c < columnCount; c++) {
        final cell = src.cells[c];
        if (cell == null || cell.isEmpty) continue;
        final text = cell.text.trim();
        if (text.isEmpty && cell.colorIndex == 0) continue;
        if (cell.colorIndex > 0) colored++;
        if (text.isNotEmpty) texted++;
        cells['c${c + 1}'] = ScheduleCell(
          text: text,
          colorIndex: cell.colorIndex,
        );
      }
    }
    rows.add(ScheduleRow(id: 'r${i + 1}', cells: cells));
  }

  return XlsxImportPreview(
    data: ScheduleData(columns: columns, rows: rows),
    columnCount: columnCount,
    rowCount: rowCount,
    coloredCells: colored,
    textCells: texted,
    headerRowIndex: header.index,
    truncatedRows: truncatedRows,
    truncatedColumns: truncatedColumns,
  );
}

String _columnLabel(XlsxRow header, int column) {
  final text = header.textAt(column).trim();
  if (text.isNotEmpty) return text;
  return '第${column + 1}列';
}

// ============================================================================
// 极简 XML 扫描器
//
// **为什么不用正则一把梭**：`<c ...>` 的属性里可能带 `>`（引号内），
// 而"取到配对结束标签"这件事用正则要写得很丑。这里用「按 `<` 逐个推进」的
// 手写扫描，一遍过、无回溯，也能顺手处理命名空间前缀与引号内的 `>`。
// 前提假设：**这些标签在 xlsx 里都不会自嵌套**（`<si>`/`<c>`/`<row>`/`<t>`/
// `<fill>`/`<xf>` 都不嵌套同名），所以"第一个同名结束标签"就是配对的那个。
// ============================================================================

/// 一个元素的「开始标签原文」+「内层内容」。
@immutable
class _Element {
  final String start;
  final String inner;
  const _Element(this.start, this.inner);
}

/// 取 [tag] 的所有元素（按出现顺序）。容错：XML 截断时最后一个元素照样返回。
Iterable<_Element> _elements(String xml, String tag) sync* {
  if (xml.isEmpty) return;
  var pos = 0;
  while (pos < xml.length) {
    final start = _findTag(xml, tag, pos, closing: false);
    if (start < 0) return;
    final gt = _tagEnd(xml, start);
    if (gt < 0) return; // 开始标签都没闭合：放弃（不是抛）
    final startTag = xml.substring(start, gt + 1);
    if (xml.codeUnitAt(gt - 1) == 0x2F /* '/' */ ) {
      yield _Element(startTag, '');
      pos = gt + 1;
      continue;
    }
    final closeStart = _findTag(xml, tag, gt + 1, closing: true);
    if (closeStart < 0) {
      // 缺结束标签（截断）：把剩下的都当内容，别丢数据
      yield _Element(startTag, xml.substring(gt + 1));
      return;
    }
    final closeEnd = xml.indexOf('>', closeStart);
    yield _Element(startTag, xml.substring(gt + 1, closeStart));
    pos = closeEnd < 0 ? xml.length : closeEnd + 1;
  }
}

/// 第一个同名元素；没有 → null。
_Element? _firstElement(String xml, String tag) {
  for (final e in _elements(xml, tag)) {
    return e;
  }
  return null;
}

/// 第一个同名元素的**内层文本**（无元素 → 空串）。用于 `<v>1</v>`。
String _firstText(String xml, String tag) {
  final e = _firstElement(xml, tag);
  return e == null ? '' : e.inner;
}

/// 从 [from] 起找名为 [tag] 的开始/结束标签，返回其 `<` 下标；-1 = 没有。
///
/// 名字允许带命名空间前缀（`x:c` / `x14:dataValidation`）——只要冒号后缀等于
/// [tag] 就算命中（有些写入器真的会加前缀，比如 `<x:worksheet>`）。
int _findTag(String xml, String tag, int from, {required bool closing}) {
  var i = xml.indexOf('<', from);
  while (i >= 0 && i + 1 < xml.length) {
    final next = xml.codeUnitAt(i + 1);
    if (closing) {
      if (next == 0x2F /* '/' */ ) {
        final name = _readName(xml, i + 2);
        if (name == tag || name.endsWith(':$tag')) return i;
      }
    } else if (next != 0x2F && next != 0x21 /* ! */ && next != 0x3F /* ? */ ) {
      final name = _readName(xml, i + 1);
      if (name == tag || name.endsWith(':$tag')) return i;
    }
    i = xml.indexOf('<', i + 1);
  }
  return -1;
}

/// 读一个 XML 名字（含前缀），到空白 / `/` / `>` 为止。
String _readName(String xml, int start) {
  var e = start;
  while (e < xml.length) {
    final c = xml.codeUnitAt(e);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) break;
    if (c == 0x2F || c == 0x3E) break;
    e++;
  }
  return xml.substring(start, e);
}

/// 开始标签的 `>` 下标（**跳过引号内的 `>`**）。
int _tagEnd(String xml, int start) {
  var quote = 0;
  for (var i = start; i < xml.length; i++) {
    final c = xml.codeUnitAt(i);
    if (quote != 0) {
      if (c == quote) quote = 0;
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      quote = c;
    } else if (c == 0x3E /* '>' */ ) {
      return i;
    }
  }
  return -1;
}

/// 取开始标签里的属性值（只认双引号/单引号包裹的写法，xlsx 都是这样）。
///
/// 名字必须**独占**：前一个字符是空白、后一个字符是 `=`。否则 `_attr(tag, 's')`
/// 会在 `<c t="s" s="3">` 里先撞上属性值里面的那个 `s`。
String? _attr(String startTag, String name) {
  var from = 0;
  while (true) {
    final at = startTag.indexOf(name, from);
    if (at < 0) return null;
    final prev = at == 0 ? 0x20 : startTag.codeUnitAt(at - 1);
    final boundary = prev == 0x20 || prev == 0x09 || prev == 0x0A || prev == 0x0D;
    var p = at + name.length;
    while (p < startTag.length &&
        (startTag.codeUnitAt(p) == 0x20 || startTag.codeUnitAt(p) == 0x09)) {
      p++;
    }
    if (boundary && p < startTag.length && startTag.codeUnitAt(p) == 0x3D) {
      var v = p + 1;
      while (v < startTag.length &&
          (startTag.codeUnitAt(v) == 0x20 || startTag.codeUnitAt(v) == 0x09)) {
        v++;
      }
      if (v < startTag.length) {
        final q = startTag.codeUnitAt(v);
        if (q == 0x22 || q == 0x27) {
          final end = startTag.indexOf(String.fromCharCode(q), v + 1);
          if (end < 0) return null;
          return startTag.substring(v + 1, end);
        }
      }
      return null;
    }
    from = at + 1;
  }
}

/// XML 文本解码：实体（`&amp;` `&#10;` `&#x1F600;`）+ Excel 的控制字符转义
/// （`_x000D_` 这种，WPS/Excel 把 CR 之类写成这个，不解就会在格子里看到
/// 一串 `_x000D_` 字面量）。
String _decodeXmlText(String raw) {
  var s = raw;
  if (s.contains('&')) {
    s = s.replaceAllMapped(RegExp(r'&(#[xX]?[0-9A-Fa-f]+|\w+);'), (m) {
      final body = m.group(1)!;
      if (body.startsWith('#')) {
        final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final code = int.tryParse(hex ? body.substring(2) : body.substring(1),
            radix: hex ? 16 : 10);
        if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
        return String.fromCharCode(code);
      }
      switch (body) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        default:
          return m.group(0)!; // 不认识的实体原样留着（总比吞掉好）
      }
    });
  }
  if (s.contains('_x')) {
    s = s.replaceAllMapped(
      RegExp(r'_x([0-9A-Fa-f]{4})_'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
  }
  return s;
}
