import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/schedule.dart';
import '../services/schedule_import.dart';
import '../services/schedule_store.dart';
import '../services/xlsx_reader.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';

/// 单元格宽度（dp）。96 大致能横排下「抄实验报告」这种 5 字中文（14sp），
/// 且在 411dp 宽的机器上「行头 44 + 3 列」正好铺满首屏（见 [ScheduleData.initial]）。
const double kScheduleCellW = 96;

/// 单元格高度（dp）。
const double kScheduleCellH = 44;

/// 日期表头行高度（dp）。
const double kScheduleHeadH = 36;

/// 左侧行头列宽度（dp）：只放一个行号 + 一个菜单按钮，44 够用且不抢内容宽度。
const double kScheduleRowHeadW = 44;

/// 日程页（v2.33.0 新增）：「像 Excel 一样可编辑的网格」。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的 Scaffold**，
/// 同 [HistoryPage] / [WatchStatsPage]）；底部导航第 3 项进入。
///
/// 交互五件套（对应需求原话）：
/// 1. **点格子 → 编辑面板**（底部弹层）：改文字 / 选颜色 / 清除此格
///    （用户说的「点击日程可以标色」）；
/// 2. **长按格子 → 拖动 → 松手自动填充**：拖动时经过的格子**实时预览**
///    即将填入的内容与颜色（用户说的「长按右拖可以像 excel 一样自动填充」）；
/// 3. **加行 / 加日期列 / 删行 / 删列**（用户说的「删除添加什么的功能」，
///    删列有二次确认——它会带走一整列数据）；
/// 4. **表头行与行头列冻结**：横向滚看更多日期时日期表头跟着走，纵向滚看
///    更多行时行号跟着走，左上角小方块固定（见 [_buildGrid] 的两条
///    单向跟随滚动，注释里解释了为什么不是独立滚动）；
/// 5. **导入 Excel**（v2.34.0）：系统文件选择器挑一个 .xlsx → 解析 →
///    （多表时选一张）→ 预览确认 → **整表替换**（见 [_importExcel]）。
///
/// 数据只存本地（[ScheduleStore] → SharedPreferences），**不进 Gist**，
/// 理由写在 [ScheduleStore] 的类注释里。
class SchedulePage extends StatefulWidget {
  /// 测试注入：日程存储（默认用全局单例 [ScheduleStore.instance]）。
  final ScheduleStore? store;

  /// 测试注入：选文件服务（默认走真实的 MethodChannel）。
  /// 解析/UI 流程的测试注入一个假实现，通道协议的测试单独 mock channel。
  final ScheduleImportService? importer;

  const SchedulePage({super.key, this.store, this.importer});

  @override
  SchedulePageState createState() => SchedulePageState();
}

/// 长按拖拽填充的进行态（源格 + 当前手指所在格）。
///
/// 目标区 = 源格与当前格**张成的矩形**（Excel 的选择语义）：纯向右拖就是
/// 「这一行从源格到手指」那一段，纯向下拖就是一列，斜着拖就是一个矩形块。
/// 为什么取矩形而不是"只填手指正下方那一格"：[previewCells] 会把整块
/// 高亮出来让用户在松手前就看清楚要填哪些格，不会出现"填了没预料到的格子"。
@immutable
class _FillDrag {
  final int sourceRow;
  final int sourceCol;
  final int curRow;
  final int curCol;

  /// 会被填充的格子（**不含源格本身**）。
  ///
  /// 构造时就一次算好存成 `final`：拖拽中每帧每个格子都要问一次
  /// （8 行 × 3 列 = 24 次），当场重建这个小集合不值当；[to] 每拖出一格
  /// 就换一个新实例，缓存天然跟着刷。也因此它不能用 `const` 构造。
  final Set<({int row, int col})> previewCells;

  _FillDrag({
    required this.sourceRow,
    required this.sourceCol,
    required this.curRow,
    required this.curCol,
  }) : previewCells = _preview(sourceRow, sourceCol, curRow, curCol);

  _FillDrag to(int row, int col) => _FillDrag(
        sourceRow: sourceRow,
        sourceCol: sourceCol,
        curRow: row,
        curCol: col,
      );

  /// 源格与当前格张成的矩形（去掉源格本身）。
  static Set<({int row, int col})> _preview(
    int sr,
    int sc,
    int cr,
    int cc,
  ) {
    final out = <({int row, int col})>{};
    final r0 = math.min(sr, cr), r1 = math.max(sr, cr);
    final c0 = math.min(sc, cc), c1 = math.max(sc, cc);
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        if (r == sr && c == sc) continue;
        out.add((row: r, col: c));
      }
    }
    return out;
  }

  @override
  String toString() =>
      '_FillDrag(src=$sourceRow,$sourceCol cur=$curRow,$curCol)';
}

class SchedulePageState extends State<SchedulePage> {
  ScheduleStore get _store => widget.store ?? ScheduleStore.instance;

  ScheduleImportService get _importer =>
      widget.importer ?? const ScheduleImportService();

  ScheduleData _data = ScheduleData.empty();
  bool _loading = true;

  /// 「导入 Excel」进行中（选文件 + 解析）：按钮位置换成转圈，防重复点击。
  bool _importing = false;

  /// 网格主体（右下方那块）的纵向滚动控制器 —— **用户唯一能直接拖的纵向滚动**。
  final ScrollController _vBody = ScrollController();

  /// 网格主体横向滚动控制器 —— 同上，横向也以它为准。
  final ScrollController _hBody = ScrollController();

  /// 日期表头行的横向滚动：**只跟随 [_hBody]**（自身 physics = Never）。
  final ScrollController _hHead = ScrollController();

  /// 左侧行头列的纵向滚动：**只跟随 [_vBody]**（自身 physics = Never）。
  final ScrollController _vRowHead = ScrollController();

  /// 进行中的长按拖拽填充（null = 没有）。
  _FillDrag? _fill;

  /// 单级撤销快照：填充 / 增删之前先存一份，SnackBar 的「撤销」用它回滚。
  /// 只留一级是有意的——日程表的改动都是"刚手滑了一下"这种量级，
  /// 一级撤销覆盖 99% 的懊悔场景；做多级栈得考虑与持久化的交互，不值得。
  ScheduleData? _undoSnapshot;

  @override
  void initState() {
    super.initState();
    // 两条单向跟随：主体滚 → 表头/行头跟着跳。反向不连（跟随者
    // physics = NeverScrollableScrollPhysics，用户根本滚不动它），
    // 所以不存在"两个滚动互相推"的抖动死循环。
    _hBody.addListener(() => _follow(_hBody, _hHead));
    _vBody.addListener(() => _follow(_vBody, _vRowHead));
    unawaited(_load());
  }

  @override
  void dispose() {
    _hBody.dispose();
    _vBody.dispose();
    _hHead.dispose();
    _vRowHead.dispose();
    super.dispose();
  }

  /// 把 [from] 的偏移镜像给 [to]（越界收敛到 [to] 自己的最大值）。
  ///
  /// 用 `jumpTo` 而不是动画：跟随必须与手指**同帧**，动画会有一帧延迟，
  /// 表现为"表头比内容慢半拍"。`jumpTo` 在滚动通知回调里调用是安全的
  /// （不在 build/layout 阶段），[to] 没有 client（尚未布局 / 空表）时直接返回。
  void _follow(ScrollController from, ScrollController to) {
    if (!to.hasClients || !from.hasClients) return;
    final target = from.offset.clamp(0.0, to.position.maxScrollExtent);
    if ((to.offset - target).abs() < 0.5) return;
    to.jumpTo(target);
  }

  /// 读本地表：三种情形都由 [ScheduleStore.load] 收口——存过就用它、
  /// 首次使用铺默认表（3 列 × 8 行）并落库、存坏了给默认表但不覆盖原值。
  /// 页面这边只负责"拿到一张能用的表"，不重复做策略判断。
  Future<void> _load() async {
    final loaded = await _store.load();
    if (!mounted) return;
    setState(() {
      _data = loaded;
      _loading = false;
    });
  }

  // ==================== 增删 ====================

  /// 改表并落库（统一的写入口：setState + 存撤销快照 + 持久化）。
  Future<void> _mutate(ScheduleData next) async {
    final prev = _data;
    setState(() {
      _data = next;
      _undoSnapshot = prev;
    });
    await _store.save(next);
  }

  Future<void> _addRow() => _mutate(_data.addRow());

  /// 加日期列：日期 = 最后一个能认出来的列头 + 1 天（见 [nextScheduleColumnDate]）。
  Future<void> _addColumn() => _mutate(_data.addColumn());

  Future<void> _removeRow(ScheduleRow row) => _mutate(_data.removeRow(row.id));

  /// 删列：**二次确认**（会带走这一列的全部日程，且不可恢复）。
  Future<void> _confirmRemoveColumn(ScheduleColumn col) async {
    final hasData =
        _data.rows.any((r) => !r.cell(col.id).isEmpty);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('删除「${col.label.isEmpty ? '未命名' : col.label}」这一列？'),
        content: Text(
          hasData
              ? '这一列上的日程会一起删掉，此操作不可恢复。'
              : '这一列目前是空的，删掉后可以再「加日期列」补回来。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _mutate(_data.removeColumn(col.id));
  }

  /// 改列头文案（把「周一 9.15」改成「考试周」这种）。
  ///
  /// 这里用 [TextFormField] + `onChanged` 自己记草稿，**不新建
  /// [TextEditingController]**：对话框的 Future 在"开始关闭"时就完成了，
  /// 那时退场动画还在跑、输入框还在树上，手动 `dispose()` 控制器会撞
  /// 「A TextEditingController was used after being disposed」；
  /// 而 TextFormField 内部自带并自己释放控制器，没有这个坑。
  Future<void> _renameColumn(ScheduleColumn col) async {
    var draft = col.label;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('改列头'),
        content: TextFormField(
          initialValue: col.label,
          autofocus: true,
          onChanged: (v) => draft = v,
          decoration: const InputDecoration(hintText: '例如：周一 9.15'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    await _mutate(_data.renameColumn(col.id, name));
  }

  // ==================== 导入 Excel（v2.34.0） ====================

  /// 「导入 Excel」全流程：选文件 → 解析 → （多表时）选表 → 预览确认 → 整表替换。
  ///
  /// 几条刻意的取舍：
  /// - **解析是同步的**（不引 isolate）：手写读取器处理用户这种 500KB 的表是
  ///   几十毫秒的量级，而 isolate 会让 widget 测试没法可靠地等它（`pumpAndSettle`
  ///   不驱动真实 isolate），为几十毫秒把测试搞脆不值得。代价是这一帧要等，
  ///   所以先 `setState` 把 loading 亮出来、再 `await Future.delayed(zero)`
  ///   让那一帧真的画出去，用户至少看到"在转圈"而不是"点了没反应"。
  /// - **用户取消不提示**：点开选择器又退出来是正常操作。
  /// - **整表替换而不是合并**：导入的是用户手上那张表的全貌，合并没有可
  ///   对齐的主键（格子没有 id），只会拼出一张谁也说不清的表 → 换成
  ///   "覆盖 + 确认弹层"（弹层里写明当前表会被清空）。
  /// - **不留撤销快照**：确认弹层已经明确写了"此操作不可恢复"，
  ///   这里就不给一个藏着的一级撤销（文案与行为要一致）。
  /// - **转圈只转"重活"那一段**（选文件 + 解析）：弹层一打开就收掉。
  ///   弹层本身就是"进行中"的指示，再挂个转圈在后面既没意义，
  ///   又会让 widget 测试的 `pumpAndSettle` 永不收敛（转圈是无限动画）。
  Future<void> _importExcel() async {
    if (_importing) return;
    setState(() => _importing = true);

    final pick = await _importer.pickXlsx();
    XlsxWorkbook? workbook;
    if (pick.isOk) {
      // 让 loading 那一帧先画出来（同步解析会占住接下来这一段）
      await Future<void>.delayed(Duration.zero);
      workbook = readXlsx(pick.bytes!);
    }
    if (!mounted) return;
    setState(() => _importing = false);

    if (pick.isCancelled) return; // 用户取消：不提示、不改表
    if (!pick.isOk) {
      _toast(pick.error!);
      return;
    }
    if (workbook == null) {
      _toast('这个 .xlsx 打不开：文件可能已损坏或被截断');
      return;
    }
    final sheets = workbook.importableSheets;
    if (sheets.isEmpty) {
      _toast('这个文件里没有可导入的工作表');
      return;
    }
    var ref = sheets.first;
    if (sheets.length > 1) {
      final chosen = await _chooseSheet(sheets);
      if (chosen == null || !mounted) return; // 取消选表 = 什么都不做
      ref = chosen;
    }
    final sheet = workbook.readSheet(ref);
    final preview = sheet == null ? null : buildScheduleFromSheet(sheet);
    if (preview == null) {
      _toast('「${ref.name}」里没有可导入的内容');
      return;
    }
    final ok = await _confirmImport(preview);
    if (ok != true || !mounted) return;

    setState(() {
      _data = preview.data;
      _undoSnapshot = null; // 与"不可恢复"的文案保持一致
    });
    await _store.save(preview.data);
    _toast(
      '已导入 ${preview.columnCount} 列 × ${preview.rowCount} 行，'
      '${preview.coloredCells} 格带底色',
    );
  }

  /// 多工作表时让用户选一张（WPS 的保留表已在 [XlsxWorkbook.importableSheets]
  /// 里过滤掉了，这里只列真正能导的表）。返回 null = 用户取消。
  Future<XlsxSheetRef?> _chooseSheet(List<XlsxSheetRef> sheets) {
    return showModalBottomSheet<XlsxSheetRef>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kSectionPadH,
                  0,
                  kSectionPadH,
                  kSpace8,
                ),
                child: Text(
                  '选择要导入的工作表',
                  style: kTypeTitleM.copyWith(color: kInkBlack),
                ),
              ),
              for (var i = 0; i < sheets.length; i++)
                ListTile(
                  key: ValueKey('schedule-import-sheet-$i'),
                  leading: const Icon(Icons.table_chart_outlined, size: 20),
                  title: Text(sheets[i].name),
                  subtitle: sheets[i].hidden ? const Text('隐藏工作表') : null,
                  onTap: () => Navigator.pop(sheetCtx, sheets[i]),
                ),
              const SizedBox(height: kSpace8),
            ],
          ),
        ),
      ),
    );
  }

  /// 导入前的预览 + 覆盖确认。返回 false / null = 取消。
  Future<bool?> _confirmImport(XlsxImportPreview preview) {
    final current = _data.rows.fold<int>(0, (sum, r) => sum + r.cells.length);
    return showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('导入 Excel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '将导入 ${preview.columnCount} 列 × ${preview.rowCount} 行，'
              '其中 ${preview.coloredCells} 格有底色。',
              style: kTypeBody.copyWith(color: kInkBlack),
            ),
            const SizedBox(height: kSpace12),
            Text(
              '会替换当前日程（当前表里的 $current 个非空格子会被清空），'
              '此操作不可恢复。',
              style: kTypeBodyS.copyWith(color: kError),
            ),
            if (preview.truncated) ...[
              const SizedBox(height: kSpace8),
              Text(
                '文件超出网格上限，超出部分已截断'
                '（最多 $kXlsxMaxColumns 列 × $kXlsxMaxRows 行）。',
                style: kTypeBodyS.copyWith(color: kInkGray70),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('schedule-import-cancel'),
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('schedule-import-confirm'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('覆盖导入', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
  }

  // ==================== 点格子 → 编辑面板 ====================

  /// 按**内容坐标**定位格子：手势检测器（见 [_buildGrid]）就包在网格内容
  /// 外面，所以 `localPosition` 已经是"内容坐标系"里的点——不需要再加
  /// 滚动偏移，也不受"此刻滚到哪儿"影响（滚多远都算得对）。
  ///
  /// 拖到内容之外（手指滑出网格）时按 Excel 手感**收敛到最近一格**，
  /// 这样"往右多拖一点"不会突然什么都不填。
  ({int row, int col})? _cellAt(Offset local) {
    final rows = _data.rows.length;
    final cols = _data.columns.length;
    if (rows == 0 || cols == 0) return null;
    if (local.dx < 0 || local.dy < 0) return null;
    final col = (local.dx ~/ kScheduleCellW).clamp(0, cols - 1);
    final row = (local.dy ~/ kScheduleCellH).clamp(0, rows - 1);
    return (row: row, col: col);
  }

  void _onFillStart(LongPressStartDetails d) {
    final at = _cellAt(d.localPosition);
    if (at == null) return;
    final cell = _data.cell(_data.rows[at.row].id, _data.columns[at.col].id);
    if (cell.isEmpty) {
      // 源格既没字也没色 → 不启动。为什么不做成"用空白覆盖过去"（Excel 是那样）：
      // 这张表是用户唯一一份私人数据，长按不小心点到一个空格就把拖过的一整片
      // 抹掉，代价远大于"少一个边缘用法"。所以这里明确不填、只给一句提示。
      _toast('这个格子是空的，没有可填充的内容');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _fill = _FillDrag(
        sourceRow: at.row,
        sourceCol: at.col,
        curRow: at.row,
        curCol: at.col,
      );
    });
  }

  void _onFillMove(LongPressMoveUpdateDetails d) {
    final f = _fill;
    if (f == null) return;
    final at = _cellAt(d.localPosition);
    if (at == null) return;
    if (at.row == f.curRow && at.col == f.curCol) return;
    setState(() => _fill = f.to(at.row, at.col));
  }

  /// 松手提交：把源格的**文本 + 颜色**整份复制到目标格。
  ///
  /// 「源格只有颜色没文本」天然只填色（复制的是整份 [ScheduleCell]），
  /// 「有文本」则文本一起复制——一条规则覆盖两种情形，不需要分支。
  Future<void> _onFillEnd(LongPressEndDetails d) async {
    final f = _fill;
    if (f == null) return;
    setState(() => _fill = null);
    final targets = f.previewCells;
    if (targets.isEmpty) return; // 没拖出源格：当成长按无操作
    final source = _data.cell(
      _data.rows[f.sourceRow].id,
      _data.columns[f.sourceCol].id,
    );
    var next = _data;
    for (final t in targets) {
      next = next.setCell(
        _data.rows[t.row].id,
        _data.columns[t.col].id,
        source,
      );
    }
    final prev = _data;
    setState(() {
      _data = next;
      _undoSnapshot = prev;
    });
    await _store.save(next);
    _toast('已填充 ${targets.length} 格', undoable: true);
  }

  void _cancelFill() {
    if (_fill == null) return;
    setState(() => _fill = null);
  }

  /// 单级撤销（填充 / 增删共用）。
  Future<void> _undo() async {
    final prev = _undoSnapshot;
    if (prev == null) return;
    setState(() {
      _data = prev;
      _undoSnapshot = null;
    });
    await _store.save(prev);
  }

  /// 日程页提示条入口（统一走 [AppSnack]）。
  ///
  /// [undoable] 的「撤销」动作是**填充 / 增删的唯一挽回入口** —— 关掉提示不能
  /// 把它一起关掉，所以带 action 的提示 `AppSnack` 一律放行（见该文件顶部第 3 条）。
  void _toast(String message, {bool undoable = false}) {
    if (!mounted) return;
    AppSnack.show(
      context,
      message,
      duration: const Duration(seconds: 2),
      action: undoable
          ? SnackBarAction(label: '撤销', onPressed: () => unawaited(_undo()))
          : null,
    );
  }

  /// 点击格子 → 底部编辑面板。
  ///
  /// 面板内的写入策略（**缺省即所见**）：
  /// - 点色块 → **立即写盘**（这就是用户说的"点击日程可以标色"，两下点完）；
  /// - 文字在**关掉面板时统一提交**（回车 / 点「完成」/ 点遮罩关掉都算），
  ///   这样用户不必记得"先按保存再关"，也不会因为误触遮罩丢字。
  ///
  /// 面板本身是独立的有状态组件 [_ScheduleCellEditor]：**输入框控制器由它
  /// 自己持有并在自己的 dispose 里释放**。为什么不在这里 new 一个
  /// controller 再 `finally { dispose() }`：`showModalBottomSheet` 的 Future
  /// 在"开始关闭"时就完成了，而弹层还在播退场动画、TextField 还在树上，
  /// 这时候 dispose 控制器会直接撞上
  /// 「A TextEditingController was used after being disposed」。
  /// 页面这边只通过回调拿"当前文字"的最新值，剩下的一律不管。
  Future<void> _openEditor(int rowIdx, int colIdx) async {
    if (rowIdx >= _data.rows.length || colIdx >= _data.columns.length) return;
    final rowId = _data.rows[rowIdx].id;
    final colId = _data.columns[colIdx].id;
    final original = _data.cell(rowId, colId);
    // 面板标题在弹层打开**之前**取好：弹层 builder 每次重建都会跑，
    // 那时若数据已变（列被删）再去下标就会越界。
    final colLabel = _data.columns[colIdx].label;
    // 面板最后看到的文字 / 最后一次真的写进表的文字：
    // 关面板时只在与 [written] 不同才再写一次，避免"什么都没改却写盘一次
    // + 覆盖掉别的改动"。
    var latest = original.text;
    var written = original.text;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ScheduleCellEditor(
        headerLabel: colLabel.isEmpty ? '第 ${colIdx + 1} 列' : colLabel,
        rowNumber: rowIdx + 1,
        initial: original,
        onTextChanged: (t) => latest = t,
        // 点色块立即写盘（同时把此刻输入框里的字一起带上，
        // 免得"先打字再点色"时字要等到关面板才落库）
        onPickColor: (text, picked) {
          latest = text;
          written = text;
          unawaited(
            _mutate(
              _data.setCell(
                rowId,
                colId,
                ScheduleCell(text: text, colorIndex: picked),
              ),
            ),
          );
        },
        onClear: () {
          latest = '';
          written = '';
          unawaited(
            _mutate(_data.setCell(rowId, colId, ScheduleCell.empty)),
          );
        },
      ),
    );

    // 关面板后收尾：文字有变化就提交。
    // 颜色不在这里管——它要么在点色块时已经写过了，要么就是表里原有的值，
    // 所以用 copyWith 只改文字，把当前底色原样留住。
    if (!mounted) return;
    final text = latest.trim();
    if (text == written) return;
    await _mutate(
      _data.setCell(
        rowId,
        colId,
        _data.cell(rowId, colId).copyWith(text: text),
      ),
    );
  }

  // ==================== 行头 / 列头 菜单 ====================

  Widget _rowHeader(int rowIdx) {
    return SizedBox(
      key: ValueKey('schedule-rowhead-$rowIdx'),
      width: kScheduleRowHeadW,
      height: kScheduleCellH,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: kPaperCool,
          border: Border(
            right: BorderSide(color: kRule),
            bottom: BorderSide(color: kRule),
          ),
        ),
        child: PopupMenuButton<String>(
          tooltip: '第 ${rowIdx + 1} 行',
          padding: EdgeInsets.zero,
          onSelected: (value) {
            switch (value) {
              case 'insert':
                unawaited(_mutate(_data.addRow()));
              case 'delete':
                unawaited(_removeRow(_data.rows[rowIdx]));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'insert', child: Text('在末尾加一行')),
            PopupMenuItem(value: 'delete', child: Text('删除此行')),
          ],
          child: Center(
            child: Text(
              '${rowIdx + 1}',
              style: kTypeNum.copyWith(color: kInkGray70),
            ),
          ),
        ),
      ),
    );
  }

  Widget _columnHeader(ScheduleColumn col, int colIdx) {
    return SizedBox(
      key: ValueKey('schedule-colhead-$colIdx'),
      width: kScheduleCellW,
      height: kScheduleHeadH,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: kPaperCool,
          border: Border(
            right: BorderSide(color: kRule),
            bottom: BorderSide(color: kRule),
          ),
        ),
        child: PopupMenuButton<String>(
          tooltip: '${col.label}（列设置）',
          padding: EdgeInsets.zero,
          onSelected: (value) {
            switch (value) {
              case 'rename':
                unawaited(_renameColumn(col));
              case 'insert':
                unawaited(_addColumn());
              case 'delete':
                unawaited(_confirmRemoveColumn(col));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('改列头')),
            PopupMenuItem(value: 'insert', child: Text('在末尾加日期列')),
            PopupMenuItem(value: 'delete', child: Text('删除此列')),
          ],
          child: Center(
            child: Text(
              col.label.isEmpty ? '未命名' : col.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kTypeLabel.copyWith(color: kInkBlack),
            ),
          ),
        ),
      ),
    );
  }

  Widget _corner() {
    return Container(
      width: kScheduleRowHeadW,
      height: kScheduleHeadH,
      decoration: const BoxDecoration(
        color: kPaperCool,
        border: Border(
          right: BorderSide(color: kRule),
          bottom: BorderSide(color: kRule),
        ),
      ),
    );
  }

  // ==================== 网格 ====================

  Widget _buildGrid() {
    final cols = _data.columns;
    final rows = _data.rows;
    if (cols.isEmpty || rows.isEmpty) {
      return _buildEmptyState();
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左：左上角小方块 + 行头列（纵向跟着主体滚，横向不动 = 冻结）
        SizedBox(
          width: kScheduleRowHeadW,
          child: Column(
            children: [
              _corner(),
              Expanded(
                child: SingleChildScrollView(
                  controller: _vRowHead,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      for (var i = 0; i < rows.length; i++) _rowHeader(i),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // 右：日期表头行（横向跟着主体滚，纵向不动 = 冻结）+ 网格主体
        //
        // `stretch` 是必须的：Column 默认 `center`，而横向
        // SingleChildScrollView 在「内容比视口窄」时自身宽度会收缩到内容宽度
        // （3 列 96dp = 288dp < 视口），于是整块表被**水平居中**，左侧凭空多出
        // 一条灰带、表头底色也铺不满（真机截图肉眼可见）。stretch 让表头行与
        // 网格都撑满视口宽度，内容自然靠左对齐（Excel 就是这样）。
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: kScheduleHeadH,
                child: SingleChildScrollView(
                  controller: _hHead,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Row(
                    children: [
                      for (var i = 0; i < cols.length; i++)
                        _columnHeader(cols[i], i),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  // 纵向主导（外层）
                  controller: _vBody,
                  child: SingleChildScrollView(
                    // 横向主导（内层）：两层同在一个格子里，
                    // 横向拖给内层、纵向拖给外层，是 Flutter 的标准嵌套解法；
                    // 它也比外层的 PageView 更"深"，所以网格横向滚动不会
                    // 把主页 tab 一起滑走。
                    controller: _hBody,
                    scrollDirection: Axis.horizontal,
                    child: GestureDetector(
                      // 整块网格共用**一个**手势检测器（不是每个格子一个）：
                      // - 少几百个 recognizer，也避免格子边界处的识别抖动
                      // - "点击"与"长按"天然互斥：按住 500ms 不动 = 长按，
                      //   快速抬手 = 点击，不会出现"想编辑结果进了填充模式"
                      // - 拖动填充是一个连续手势，起点/经过/终点都由它自己算
                      // - 它就包在网格内容外面，所以 localPosition 直接是
                      //   "内容坐标"（不受此刻滚到哪儿影响）
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) {
                        final at = _cellAt(d.localPosition);
                        if (at == null) return;
                        unawaited(_openEditor(at.row, at.col));
                      },
                      onLongPressStart: _onFillStart,
                      onLongPressMoveUpdate: _onFillMove,
                      onLongPressEnd: (d) => unawaited(_onFillEnd(d)),
                      onLongPressCancel: _cancelFill,
                      child: Column(
                        children: [
                          for (var r = 0; r < rows.length; r++)
                            Row(
                              children: [
                                for (var c = 0; c < cols.length; c++) _cell(r, c),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(int rowIdx, int colIdx) {
    final row = _data.rows[rowIdx];
    final col = _data.columns[colIdx];
    final actual = row.cell(col.id);

    final f = _fill;
    final isSource =
        f != null && f.sourceRow == rowIdx && f.sourceCol == colIdx;
    // 预览格：显示"松手后会变成的样子"（源格的文本 + 颜色），
    // 并加一圈实线框，与已经写进去的格子区分开。
    final isPreview =
        f != null && f.previewCells.contains((row: rowIdx, col: colIdx));
    final ScheduleCell shown;
    if (f != null && (isSource || isPreview)) {
      // 预览格：显示"松手后会变成的样子"（源格的文本 + 颜色）
      shown = _data.cell(
        _data.rows[f.sourceRow].id,
        _data.columns[f.sourceCol].id,
      );
    } else {
      shown = actual;
    }

    final bg = shown.color ?? kPaper;
    final fg = shown.color == null
        ? kInkBlack
        : highestContrastOn(shown.color!);
    final highlighted = isSource || isPreview;

    return Container(
      key: ValueKey('schedule-cell-$rowIdx-$colIdx'),
      width: kScheduleCellW,
      height: kScheduleCellH,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: bg,
        border: highlighted
            ? Border.all(color: context.palette.inkFill, width: 2)
            : const Border(
                right: BorderSide(color: kRule),
                bottom: BorderSide(color: kRule),
              ),
      ),
      child: Text(
        shown.text,
        maxLines: 1,
        // 文本超出省略：格宽固定 96dp，长内容不省略会把网格撑歪；
        // 想读全文就点开编辑面板（输入框 3 行）。
        overflow: TextOverflow.ellipsis,
        style: kTypeBodyS.copyWith(color: fg, height: 1.15),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kSectionPadH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_off_outlined, size: 40, color: kInkGray30),
            const SizedBox(height: kSpace12),
            Text(
              _data.columns.isEmpty && _data.rows.isEmpty
                  ? '日程表是空的'
                  : '先加一列日期、加几行才能写日程',
              style: kTypeBody.copyWith(color: kInkGray70),
            ),
            const SizedBox(height: kSpace16),
            Wrap(
              spacing: kSpace8,
              children: [
                FilledButton.tonal(
                  onPressed: _addColumn,
                  child: const Text('加日期列'),
                ),
                FilledButton.tonal(
                  onPressed: _addRow,
                  child: const Text('加行'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace12, kSpace8, kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '日程',
                  style: kTypeTitleL.copyWith(color: kInkBlack),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('schedule-import'),
                // 选文件 / 解析期间按钮变转圈并失效：一次只允许一个导入流程
                onPressed: _importing ? null : () => unawaited(_importExcel()),
                icon: _importing
                    ? const SizedBox(
                        key: ValueKey('schedule-import-progress'),
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_upload_outlined, size: 18),
                label: const Text('导入 Excel'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
              TextButton.icon(
                key: const ValueKey('schedule-add-row'),
                onPressed: () => unawaited(_addRow()),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('加行'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
              TextButton.icon(
                key: const ValueKey('schedule-add-column'),
                onPressed: () => unawaited(_addColumn()),
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('加日期列'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          Text(
            '点格子改文字与底色 · 长按格子向右/下拖可整片填充',
            style: kTypeBodyS.copyWith(color: kInkGray50),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPageHeader(),
        const Divider(height: 1, thickness: 1, color: kRule),
        Expanded(
          child: _loading
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: kSpace8),
                  child: _buildGrid(),
                ),
        ),
      ],
    );
  }

  // ==================== 测试观察口 ====================

  /// 当前表（测试断言用）。
  @visibleForTesting
  ScheduleData get debugData => _data;

  /// 是否正在长按拖拽填充。
  @visibleForTesting
  bool get debugFilling => _fill != null;

  /// 当前预览会被填充的格子集合（松手前）。
  @visibleForTesting
  Set<({int row, int col})> get debugFillPreview =>
      _fill?.previewCells ?? const {};

  /// 是否还在读盘（首帧）。
  @visibleForTesting
  bool get debugLoading => _loading;

  /// 是否正在导入 Excel（选文件 / 解析）。
  @visibleForTesting
  bool get debugImporting => _importing;
}

/// 单元格编辑面板（底部弹层内容）。
///
/// 独立成有状态组件的原因只有一个：**输入框控制器必须由它自己持有并释放**。
/// 若在页面里 new + `finally dispose`，`showModalBottomSheet` 的 Future 完成时
/// 弹层还在播退场动画、TextField 还在树上，会撞
/// 「A TextEditingController was used after being disposed」。
///
/// 与宿主的约定：
/// - 每次文字变化 → [onTextChanged]（宿主只记最新值，不写盘，避免每个按键都存一次）
/// - 点色块 → [onPickColor]（宿主**立即写盘**，"点一下就把颜色标上"）
/// - 点「清除此格」→ [onClear] + 自己关掉弹层
/// - 点「完成」/ 回车 / 点遮罩 → 关掉弹层；文字由宿主在关掉之后统一提交
class _ScheduleCellEditor extends StatefulWidget {
  final String headerLabel;
  final int rowNumber;
  final ScheduleCell initial;
  final ValueChanged<String> onTextChanged;
  final void Function(String text, int colorIndex) onPickColor;
  final VoidCallback onClear;

  const _ScheduleCellEditor({
    required this.headerLabel,
    required this.rowNumber,
    required this.initial,
    required this.onTextChanged,
    required this.onPickColor,
    required this.onClear,
  });

  @override
  State<_ScheduleCellEditor> createState() => _ScheduleCellEditorState();
}

class _ScheduleCellEditorState extends State<_ScheduleCellEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial.text);
  late int _color = widget.initial.colorIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pickColor(int index) {
    setState(() => _color = index);
    widget.onPickColor(_controller.text, index);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      // 键盘弹起时把面板顶上去（否则输入框被键盘盖住）
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      // 小屏 + 键盘一起挤的时候能让面板自己滚（防 RenderFlex 溢出）
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kSectionPadH,
            0,
            kSectionPadH,
            kSpace24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.headerLabel} · 第 ${widget.rowNumber} 行',
                style: kTypeTitleM.copyWith(color: kInkBlack),
              ),
              const SizedBox(height: kSpace12),
              TextField(
                key: const ValueKey('schedule-editor-text'),
                controller: _controller,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.done,
                onChanged: widget.onTextChanged,
                onSubmitted: (v) {
                  widget.onTextChanged(v);
                  Navigator.pop(context);
                },
                decoration: const InputDecoration(
                  hintText: '写点什么，例如：实验报告',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: kSpace16),
              Text('底色', style: kTypeLabel.copyWith(color: kInkGray70)),
              const SizedBox(height: kSpace8),
              Wrap(
                spacing: kSpace8,
                runSpacing: kSpace8,
                children: [
                  // 下标 0 = 无色（不是色板里的颜色），单独一个"去掉底色"的块
                  _colorChip(palette: palette, index: 0),
                  for (var i = 1; i <= kScheduleColors.length; i++)
                    _colorChip(palette: palette, index: i),
                ],
              ),
              const SizedBox(height: kSpace16),
              Row(
                children: [
                  TextButton.icon(
                    key: const ValueKey('schedule-editor-clear'),
                    onPressed: () {
                      widget.onClear();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.backspace_outlined, size: 18),
                    label: const Text('清除此格'),
                    style: TextButton.styleFrom(foregroundColor: kError),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('schedule-editor-done'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorChip({required AppPalette palette, required int index}) {
    final color = scheduleColorAt(index);
    final selected = _color == index;
    return Tooltip(
      message: index == 0 ? '无色' : '底色 $index',
      child: InkWell(
        key: ValueKey('schedule-color-$index'),
        onTap: () => _pickColor(index),
        borderRadius: BorderRadius.circular(kRadiusMd),
        child: Container(
          width: 44,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color ?? kPaper,
            borderRadius: BorderRadius.circular(kRadiusMd),
            border: Border.all(
              color: selected ? palette.inkFill : kRuleStrong,
              width: selected ? 2 : 1,
            ),
          ),
          child: color == null
              ? const Icon(
                  Icons.format_color_reset_outlined,
                  size: 18,
                  color: kInkGray50,
                )
              : (selected
                  ? Icon(Icons.check, size: 18, color: highestContrastOn(color))
                  : null),
        ),
      ),
    );
  }
}
