/// 日程表（v2.33.0 新增）：「像 Excel 一样的可编辑网格」纯数据模型。
///
/// 设计依据 = 用户给的原型（`超级代办 大三上.xlsx`）：**表头行 = 星期 + 日期**，
/// **每个单元格是「一段独立文本 + 一个独立底色」**。原型里同一行的格子可以是
/// 完全不相关的事（一行里依次是「门票 / 修改门票 / 尹老板」），所以这里
/// **刻意不做「一行 = 一个任务」的建模**——那就是一张手工网格，
/// 「连着几天做同一件事」靠连续几格填同样的文本/同样的底色表达。
///
/// 三个刻意的取舍（都在注释里说明"为什么"）：
/// 1. **颜色只存下标（[ScheduleCell.colorIndex]），不存 RGB 字面量**：
///    色板是 [kScheduleColors] 一处定义。存 RGB 的话，以后想调色板
///    （换一套更协调的色 / 加深浅档）就得写数据迁移，把用户表里所有旧色
///    逐个映射一遍；存下标则"改色板定义"天然生效，已存数据零迁移。
/// 2. **颜色不赋语义**：原型里用户用了 5 种底色（黄 61 格 / 灰 51 格 /
///    绿 15 格 / 红 2 格 / 蓝 1 格），但「黄 = 待办」这类语义是**用户私有的**，
///    App 里不做任何硬编码推断，只给一组色板让他自己用。
/// 3. **纯数据 + 纯逻辑（无 UI 依赖，只借用 `dart:ui` 的 [Color] 值类型）**：
///    所有增删改都是返回新实例的纯函数，便于单测直接断言"改完长什么样"。
library;

import 'package:flutter/material.dart';

/// 色板（下标从 1 开始，0 = 无色）。
///
/// 前 5 个**逐字沿用用户原型里的实际色值**（WPS/Excel 的标准色），
/// 让他在 App 里标出来的色和原来表格里的一模一样；后 2 个是顺手补的
/// 两个常用色（橙 / 紫），避免只有 5 色不够分。
///
/// **顺序即语义**：schedule cell 的 `colorIndex` 就是这个列表的 1-based 下标，
/// 所以只能往后追加、不能插队/重排（重排会改变已存数据的显示色）。
const List<Color> kScheduleColors = <Color>[
  Color(0xFFFFFF00), // 1 黄（原型：实验报告 / 门票 / 抄实验报告 …）
  Color(0xFFBFBFBF), // 2 灰（原型：量子力学 / 复习 / 物理化学 …）
  Color(0xFF92D050), // 3 绿（原型：看伊朗系列 / Rick and Morty …）
  Color(0xFFFF0000), // 4 红（原型：校党校 / 新媒面试团建）
  Color(0xFF00B0F0), // 5 蓝（原型：linux 最后一次作业）
  Color(0xFFFF9933), // 6 橙（补）
  Color(0xFFCC99FF), // 7 紫（补）
];

/// 合法颜色下标的上界（= 色板长度；0 表示无色，不占色板位）。
int get kScheduleMaxColorIndex => kScheduleColors.length;

/// 取底色：0 / 越界 → null（表示"无色"，由调用方决定画纸底还是画留白）。
///
/// 越界**不**收敛到最后一个颜色：宁可少一个底色，也不要把格子染成
/// 用户根本没选过的颜色（他改过色板、旧数据越界时这点尤其重要）。
Color? scheduleColorAt(int colorIndex) {
  if (colorIndex <= 0 || colorIndex > kScheduleColors.length) return null;
  return kScheduleColors[colorIndex - 1];
}

/// 颜色下标清洗：非 0 且非法（负数 / 越界）→ 0（无色）。
int normalizeScheduleColorIndex(int raw) =>
    (raw >= 0 && raw <= kScheduleColors.length) ? raw : 0;

/// 中文星期（[DateTime.weekday]：1 = 周一 … 7 = 周日）。
const List<String> kScheduleWeekdayNames = <String>[
  '周一', '周二', '周三', '周四', '周五', '周六', '周日',
];

/// 星期中文名（越界/异常值 → 空串，不抛）。
String scheduleWeekdayName(int weekday) =>
    (weekday >= 1 && weekday <= 7) ? kScheduleWeekdayNames[weekday - 1] : '';

/// 列头文案：`周一 9.15`（与原型 `星期一9.14` 同义，中间加一个空格便于阅读）。
String scheduleColumnLabel(DateTime date) =>
    '${scheduleWeekdayName(date.weekday)} ${date.month}.${date.day}';

/// 从列头文案里反解出「月.日」（用于「新列 = 最后一列 +1 天」）。
///
/// 认不出来（用户手改成了「国庆周」「考试周」之类）→ null，
/// 由 [nextScheduleColumnDate] 决定退路。
DateTime? parseScheduleMonthDay(String label, {int? year}) {
  final m = RegExp(r'(\d{1,2})\s*[.\-/月]\s*(\d{1,2})').firstMatch(label);
  if (m == null) return null;
  final month = int.tryParse(m.group(1)!);
  final day = int.tryParse(m.group(2)!);
  if (month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final y = year ?? DateTime.now().year;
  final d = DateTime(y, month, day);
  // 回读校验：2 月 31 日这种会被 DateTime 滚到 3 月，视为脏数据
  if (d.month != month || d.day != day) return null;
  return d;
}

/// 「新日期列」的日期：**最后一个能认出来的列头 + 1 天**。
///
/// 为什么要往回扫而不是只看最后一列：用户完全可能把某一列列头手改成
/// 「考试周」——只看最后一列就认不出来，新列会退化成"今天+1天"这种
/// 与上下文完全脱节的日期。往回扫到最近一个可解析的列头，语义上更接近
/// 用户的心智（"接着往后的那一天"）。全表都认不出来时才退到
/// [today] + 1 天。
DateTime nextScheduleColumnDate(
  List<ScheduleColumn> columns, {
  DateTime? today,
}) {
  final base = today ?? DateTime.now();
  for (final c in columns.reversed) {
    final d = parseScheduleMonthDay(c.label, year: base.year);
    if (d != null) return d.add(const Duration(days: 1));
  }
  return DateTime(base.year, base.month, base.day)
      .add(const Duration(days: 1));
}

/// 「本周一」00:00（初始表的锚点：从本周一开始排周一到周三）。
DateTime mondayOfWeek(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.subtract(Duration(days: d.weekday - 1));
}

/// 单个单元格：一段文本 + 一个底色下标。**不可变**。
@immutable
class ScheduleCell {
  /// 单元格文本（默认空）。空白一律 trim 掉（"   " 视同空）。
  final String text;

  /// 底色下标：`0` = 无色，`1..kScheduleColors.length` = [kScheduleColors] 的下标。
  final int colorIndex;

  const ScheduleCell({this.text = '', this.colorIndex = 0});

  /// 空单元格常量（无色无字）。
  static const ScheduleCell empty = ScheduleCell();

  /// 是否空（无字也无色）——空单元格不渲染，省一层 Container。
  bool get isEmpty => text.isEmpty && colorIndex == 0;

  bool get hasColor => colorIndex > 0;

  /// 底色（无色 → null）。
  Color? get color => scheduleColorAt(colorIndex);

  ScheduleCell copyWith({String? text, int? colorIndex}) => ScheduleCell(
        text: text == null ? this.text : text.trim(),
        colorIndex: normalizeScheduleColorIndex(colorIndex ?? this.colorIndex),
      );

  Map<String, dynamic> toJson() => {'t': text, 'c': colorIndex};

  /// 宽松反序列化：**任何**非法输入都退化成 [empty]，绝不抛。
  ///
  /// 容忍：整项不是 Map（旧版本残留 / 手改坏）、缺字段、类型不对
  /// （`text` 是数字、`colorIndex` 是字符串）——日程表是用户唯一一份私人
  /// 数据，读坏一个格子就整表读不出来（进而被覆盖成空表）是不可接受的。
  factory ScheduleCell.fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final t = raw['t'];
    final c = raw['c'];
    return ScheduleCell(
      text: t is String ? t.trim() : (t == null ? '' : '$t'.trim()),
      colorIndex: c is num ? normalizeScheduleColorIndex(c.toInt()) : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleCell &&
      other.text == text &&
      other.colorIndex == colorIndex;

  @override
  int get hashCode => Object.hash(text, colorIndex);

  @override
  String toString() => 'ScheduleCell("$text", c=$colorIndex)';
}

/// 一列：日期表头。[id] 稳定（改名不影响数据归属），[label] 是给人看的
/// （形如 `周一 9.15`，由日期自动生成，用户也能手改）。
@immutable
class ScheduleColumn {
  final String id;
  final String label;

  const ScheduleColumn({required this.id, required this.label});

  ScheduleColumn copyWith({String? label}) =>
      ScheduleColumn(id: id, label: label == null ? this.label : label.trim());

  Map<String, dynamic> toJson() => {'id': id, 'label': label};

  /// 宽松反序列化：id 缺失/为空 → 生成一个占位 id（后续会被
  /// [ScheduleData.fromJson] 的去重逻辑改成唯一 id，避免整列丢失）。
  factory ScheduleColumn.fromJson(Object? raw) {
    if (raw is! Map) return const ScheduleColumn(id: '', label: '');
    return ScheduleColumn(
      id: raw['id'] is String ? raw['id'] as String : '',
      label: raw['label'] is String ? (raw['label'] as String).trim() : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleColumn && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'ScheduleColumn($id, "$label")';
}

/// 一行：行头没有文案（Excel 那样的行号在 App 里意义不大），
/// [_id] 是稳定标识，[cells] 的 key = 列 id。
@immutable
class ScheduleRow {
  final String id;

  /// key = [ScheduleColumn.id]；**只存非空格子**（空了就从 map 里删掉，
  /// 表不会随时间攒出一堆 `{"":{}}` 垃圾）。
  final Map<String, ScheduleCell> cells;

  ScheduleRow({required this.id, Map<String, ScheduleCell>? cells})
      : cells = Map<String, ScheduleCell>.unmodifiable(
          _pruneEmpty(cells ?? const {}),
        );

  /// 丢掉落空的键（读旧数据 / 构造时统一走这里，保证不变量"表里的格子都非空"）。
  static Map<String, ScheduleCell> _pruneEmpty(Map<String, ScheduleCell> raw) {
    final out = <String, ScheduleCell>{};
    raw.forEach((k, v) {
      if (k.isEmpty || v.isEmpty) return;
      out[k] = v;
    });
    return out;
  }

  /// 取格子（列不存在 / 没存 → [ScheduleCell.empty]，永不 null）。
  ScheduleCell cell(String columnId) => cells[columnId] ?? ScheduleCell.empty;

  /// 写格子：传入空 [ScheduleCell] 等价于删除该格。
  ScheduleRow setCell(String columnId, ScheduleCell cell) {
    final next = Map<String, ScheduleCell>.from(cells);
    if (columnId.isEmpty || cell.isEmpty) {
      next.remove(columnId);
    } else {
      next[columnId] = cell;
    }
    return ScheduleRow(id: id, cells: next);
  }

  /// 删列时同步清掉本行里的该列数据（不留"孤儿格子"）。
  ScheduleRow removeColumn(String columnId) => setCell(columnId, ScheduleCell.empty);

  /// 该行是否全空（无任何带字或带色的格子）。
  bool get isEmpty => cells.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'cells': cells.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory ScheduleRow.fromJson(Object? raw, {Set<String>? validColumns}) {
    if (raw is! Map) return ScheduleRow(id: '');
    final rawCells = raw['cells'];
    final parsed = <String, ScheduleCell>{};
    if (rawCells is Map) {
      rawCells.forEach((k, v) {
        if (k is! String || k.isEmpty) return;
        // 指向已不存在的列的格子直接丢（删列后残留的孤儿数据）
        if (validColumns != null && !validColumns.contains(k)) return;
        final cell = ScheduleCell.fromJson(v);
        if (!cell.isEmpty) parsed[k] = cell;
      });
    }
    return ScheduleRow(
      id: raw['id'] is String ? raw['id'] as String : '',
      cells: parsed,
    );
  }

  @override
  String toString() => 'ScheduleRow($id, ${cells.length} cells)';
}

/// 整张日程表：列（日期表头）+ 行（内容）。不可变。
///
/// 所有"改"的操作都返回**新实例**：页面 setState 换掉整个 [ScheduleData]
/// 即可重绘 + 落库，不需要区分"哪个格子变了"。
@immutable
class ScheduleData {
  final List<ScheduleColumn> columns;
  final List<ScheduleRow> rows;

  ScheduleData({
    List<ScheduleColumn> columns = const [],
    List<ScheduleRow> rows = const [],
  })  : columns = List<ScheduleColumn>.unmodifiable(columns),
        rows = List<ScheduleRow>.unmodifiable(rows);

  /// 完全空表（0 列 0 行）——只在存储损坏时短暂出现，页面见到它会把
  /// [initial] 作为兜底（见 `ScheduleStore.load`）。
  factory ScheduleData.empty() => ScheduleData();

  /// 首次使用的默认表：**本周一起 3 列（周一/周二/周三）× 8 个空行**。
  ///
  /// 为什么不是给一张彻底空白的表：用户点进新页面看到"什么都没有、也不知道
  /// 该按哪儿加"，第一反应是这功能没做完。给一张能立刻下手写的表，
  /// 列/行不够再自己加。日期锚在"本周一"而不是"今天"，是为了让表头与
  /// 用户手上那张周视图的表格对得上（原型列头就是周一到周日）。
  factory ScheduleData.initial({DateTime? today, int rowCount = 8}) {
    final monday = mondayOfWeek(today ?? DateTime.now());
    final cols = <ScheduleColumn>[
      for (var i = 0; i < 3; i++)
        ScheduleColumn(
          id: 'c${i + 1}',
          label: scheduleColumnLabel(monday.add(Duration(days: i))),
        ),
    ];
    return ScheduleData(
      columns: cols,
      rows: [for (var i = 0; i < rowCount; i++) ScheduleRow(id: 'r${i + 1}')],
    );
  }

  bool get isEmpty => columns.isEmpty && rows.isEmpty;

  /// 列 id 集合（构造行时用来过滤孤儿格子 / 删列时用）。
  Set<String> get columnIds => {for (final c in columns) c.id};

  /// 行 id 集合。
  Set<String> get rowIds => {for (final r in rows) r.id};

  ScheduleColumn? column(String id) {
    for (final c in columns) {
      if (c.id == id) return c;
    }
    return null;
  }

  ScheduleRow? row(String id) {
    for (final r in rows) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// 取格子（行列不存在 → 空格子，永不 null）。
  ScheduleCell cell(String rowId, String columnId) =>
      row(rowId)?.cell(columnId) ?? ScheduleCell.empty;

  ScheduleData _withRow(ScheduleRow next) => ScheduleData(
        columns: columns,
        rows: [
          for (final r in rows) if (r.id == next.id) next else r,
        ],
      );

  /// 写一个格子（空格子 = 清除该格）。
  ScheduleData setCell(String rowId, String columnId, ScheduleCell cell) {
    final r = row(rowId);
    if (r == null || column(columnId) == null) return this;
    return _withRow(r.setCell(columnId, cell));
  }

  /// 一次性写多个格子（长按拖拽填充 / 粘贴用；坐标重复时后者覆盖前者）。
  ScheduleData setCells(Iterable<({String rowId, String columnId})> targets,
      ScheduleCell cell) {
    var out = this;
    for (final t in targets) {
      out = out.setCell(t.rowId, t.columnId, cell);
    }
    return out;
  }

  /// 加一个空行（追加到表尾）。
  ScheduleData addRow() =>
      ScheduleData(columns: columns, rows: [...rows, ScheduleRow(id: _nextId('r', rowIds))]);

  /// 删一行（id 不存在 → 原样返回）。
  ScheduleData removeRow(String rowId) => ScheduleData(
        columns: columns,
        rows: [for (final r in rows) if (r.id != rowId) r],
      );

  /// 加一个日期列：日期 = 最后一个能认出来的列头 + 1 天（见
  /// [nextScheduleColumnDate]），列头自动生成，新列在已有行里是空的。
  ScheduleData addColumn({DateTime? today}) {
    final date = nextScheduleColumnDate(columns, today: today);
    final col = ScheduleColumn(
      id: _nextId('c', columnIds),
      label: scheduleColumnLabel(date),
    );
    return ScheduleData(columns: [...columns, col], rows: rows);
  }

  /// 删一列：**连同所有行里的该列数据一起删**（不留孤儿格子）。
  ScheduleData removeColumn(String columnId) => ScheduleData(
        columns: [for (final c in columns) if (c.id != columnId) c],
        rows: [for (final r in rows) r.removeColumn(columnId)],
      );

  /// 改列头文案（用户在列头菜单里手改；空串忽略，避免出现无标题列）。
  ScheduleData renameColumn(String columnId, String label) {
    final t = label.trim();
    if (t.isEmpty) return this;
    return ScheduleData(
      columns: [
        for (final c in columns) if (c.id == columnId) c.copyWith(label: t) else c,
      ],
      rows: rows,
    );
  }

  /// 生成下一个 id：扫描同类 id 的形如 `r3` / `c12` 的数字后缀取 max+1。
  ///
  /// 为什么不存一个自增计数器：计数器要跟着数据一起持久化（多一个字段、
  /// 多一处可能被写坏的地方），而扫 id 是纯函数、删了再加也不会撞号，
  /// 单测也好断言。
  static String _nextId(String prefix, Set<String> existing) {
    var max = 0;
    for (final id in existing) {
      if (!id.startsWith(prefix)) continue;
      final n = int.tryParse(id.substring(prefix.length));
      if (n != null && n > max) max = n;
    }
    return '$prefix${max + 1}';
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'columns': [for (final c in columns) c.toJson()],
        'rows': [for (final r in rows) r.toJson()],
      };

  /// 宽松反序列化：**任何**异常输入都降级成 [ScheduleData.empty]，绝不抛。
  ///
  /// 具体容错点：
  /// - 整个 raw 不是 Map → 空表
  /// - `columns` / `rows` 不是 List → 当空
  /// - 列表里混进非 Map 的项（null / 字符串 / 数字）→ **整项跳过**，不造出
  ///   一个用户从来没有过的空列/空行
  /// - 列 id 缺失/重复 → 重新编号（id 变了没关系，行里的 key 跟着重建）
  /// - 行里指向不存在列的格子 → 丢弃（删列后的残留）
  /// - 某个格子坏掉 → 只丢那一个格子，同一行其它格子照留
  factory ScheduleData.fromJson(Object? raw) {
    if (raw is! Map) return ScheduleData.empty();

    final rawCols = raw['columns'];
    final cols = <ScheduleColumn>[];
    final usedIds = <String>{};
    if (rawCols is List) {
      for (final item in rawCols) {
        if (item is! Map) continue; // 坏项整条丢，不占用一个列位
        var c = ScheduleColumn.fromJson(item);
        // id 缺失或撞号 → 补一个唯一 id（只丢 id 不丢这一列）
        if (c.id.isEmpty || usedIds.contains(c.id)) {
          c = ScheduleColumn(id: _nextId('c', usedIds), label: c.label);
        }
        usedIds.add(c.id);
        cols.add(c);
      }
    }

    final rawRows = raw['rows'];
    final rows = <ScheduleRow>[];
    if (rawRows is List) {
      for (final item in rawRows) {
        if (item is! Map) continue;
        var r = ScheduleRow.fromJson(item, validColumns: usedIds);
        if (r.id.isEmpty || rows.any((e) => e.id == r.id)) {
          r = ScheduleRow(
            id: _nextId('r', {for (final e in rows) e.id}),
            cells: r.cells,
          );
        }
        rows.add(r);
      }
    }

    return ScheduleData(columns: cols, rows: rows);
  }

  @override
  String toString() =>
      'ScheduleData(${columns.length} 列 × ${rows.length} 行)';
}
