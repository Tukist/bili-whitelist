// 日程页交互测试（v2.33.0）。
//
// 本轮核心用例 = **长按拖拽自动填充**（用户原话「长按右拖可以像 excel 一样
// 自动填充」）：按住某格 → 向右拖 → **松手前**断言预览集合 → 松手后断言
// 那几格的文本+颜色与源格一致、并且已经落库。四个方向（右/下/左上）都覆盖。
//
// 其余覆盖：点格子编辑（改文字 / 选色 / 清除）、加行加列删行删列（含删列
// 二次确认）、持久化、表头/行头冻结跟随、长按与点击不打架。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/schedule.dart';
import 'package:bili_whitelist_app/pages/schedule_page.dart';
import 'package:bili_whitelist_app/services/schedule_store.dart';

/// 单元格 key（与页面里的 `ValueKey('schedule-cell-$r-$c')` 对齐）。
Finder _cell(int r, int c) => find.byKey(ValueKey('schedule-cell-$r-$c'));

Finder _chip(int i) => find.byKey(ValueKey('schedule-color-$i'));

/// pump 日程页（外面套一层 Scaffold：本页自身不带 Scaffold，SnackBar /
/// 底部弹层需要一个宿主，与真机上的实际宿主 PlaylistPage 一致）。
Future<SchedulePageState> _pumpPage(
  WidgetTester tester, {
  ScheduleStore? store,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SchedulePage(store: store ?? ScheduleStore())),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<SchedulePageState>(find.byType(SchedulePage));
}

/// 长按 [from] 不放（走完 500ms 长按阈值，返回仍按着的指针）。
Future<TestGesture> _holdLongPress(WidgetTester tester, Finder from) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 60));
  return gesture;
}

/// 「长按 from → 拖到 to → 松手」一条龙。
Future<void> _dragFill(
  WidgetTester tester,
  Finder from,
  Finder to, {
  Future<void> Function()? onArrived,
}) async {
  final gesture = await _holdLongPress(tester, from);
  await gesture.moveTo(tester.getCenter(to));
  await tester.pump();
  if (onArrived != null) await onArrived();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 直接往表里塞内容（避开 UI，作为其它断言的起点）。
Future<ScheduleData> _seed(
  ScheduleStore store, {
  DateTime? today,
}) async {
  final data = ScheduleData.initial(today: today ?? DateTime(2026, 9, 17));
  await store.save(data);
  return data;
}

Future<void> _tapFirstCellAndFill(
  WidgetTester tester, {
  required int row,
  required int col,
  required String text,
  required int color,
}) async {
  await tester.tap(_cell(row, col));
  await tester.pumpAndSettle();
  if (text.isNotEmpty) {
    await tester.enterText(
      find.byKey(const ValueKey('schedule-editor-text')),
      text,
    );
  }
  await tester.tap(_chip(color));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('schedule-editor-done')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('初始态', () {
    testWidgets('首次进入 = 3 列 × 8 行，列头是「周X M.D」，行头 1..8',
        (tester) async {
      final state = await _pumpPage(tester);
      expect(state.debugData.columns.length, 3);
      expect(state.debugData.rows.length, 8);
      expect(state.debugLoading, isFalse);

      // 3 个列头都在（文案由日期生成，只断言"周X "前缀 + 有 M.D 数字）
      for (final c in state.debugData.columns) {
        expect(find.text(c.label), findsOneWidget);
        expect(c.label, matches(RegExp(r'^周[一二三四五六日] \d{1,2}\.\d{1,2}$')));
      }
      // 8 个行头
      for (var i = 0; i < 8; i++) {
        expect(find.byKey(ValueKey('schedule-rowhead-$i')), findsOneWidget);
      }
      // 24 个格子
      expect(find.byKey(const ValueKey('schedule-cell-0-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-cell-7-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-cell-8-0')), findsNothing);
      // 首次铺的表已经落库
      final raw = jsonOf(await ScheduleStore().load());
      expect(raw['columns'], hasLength(3));
      expect(raw['rows'], hasLength(8));
    });

    testWidgets('内容比视口窄时表格靠左对齐（表头/网格与行头列严丝合缝，不留灰带）',
        (tester) async {
      await _pumpPage(tester);
      // 3 列 × 96dp = 288dp < 800dp 视口宽——正是"内容比视口窄"的情形
      // （Column 默认 center 会把它整体居中，左侧凭空一条灰带）
      final rowHeadRight =
          tester.getTopRight(find.byKey(const ValueKey('schedule-rowhead-0'))).dx;
      // 第 0 列紧贴行头列右侧，之后每列依次右移一个格宽（96dp）
      for (var c = 0; c < 3; c++) {
        expect(
          tester.getTopLeft(find.byKey(ValueKey('schedule-colhead-$c'))).dx,
          closeTo(rowHeadRight + c * kScheduleCellW, 0.5),
          reason: '第 $c 列列头位置不对（表头底色应当从行头列右侧起铺）',
        );
        expect(
          tester.getTopLeft(_cell(0, c)).dx,
          closeTo(rowHeadRight + c * kScheduleCellW, 0.5),
          reason: '第 0 行第 $c 列的格子应与列头左对齐',
        );
      }
      // 行头列本身在视口最左（x = 0）
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('schedule-rowhead-0'))).dx,
        closeTo(0, 0.5),
      );
    });

    testWidgets('已存过的表原样上屏（不会被默认表盖掉）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r2',
        'c3',
        const ScheduleCell(text: '尹老板', colorIndex: 3),
      );
      await store.save(data);

      final state = await _pumpPage(tester, store: store);
      expect(state.debugData.cell('r2', 'c3').text, '尹老板');
      expect(find.text('尹老板'), findsOneWidget);
    });
  });

  group('点格子 → 编辑面板', () {
    testWidgets('点格子弹出面板（标题含列头与行号）', (tester) async {
      await _pumpPage(tester);
      await tester.tap(_cell(0, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining('第 1 行'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-editor-text')), findsOneWidget);
      for (var i = 0; i <= kScheduleColors.length; i++) {
        expect(_chip(i), findsOneWidget, reason: '色板第 $i 个块应在');
      }
    });

    testWidgets('改文字 + 选色 → 上屏并落库', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final state = await _pumpPage(tester, store: store);

      await _tapFirstCellAndFill(
        tester,
        row: 0,
        col: 1,
        text: '门票',
        color: 1,
      );

      expect(state.debugData.cell('r1', 'c2').text, '门票');
      expect(state.debugData.cell('r1', 'c2').colorIndex, 1);
      expect(find.text('门票'), findsOneWidget);

      // 落库：换个实例读同一份存储
      final back = await ScheduleStore().load();
      expect(back.cell('r1', 'c2').text, '门票');
      expect(back.cell('r1', 'c2').colorIndex, 1);
    });

    testWidgets('先选色再打字也能一起落库（关面板时提交文字）', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(_cell(1, 0));
      await tester.pumpAndSettle();
      await tester.tap(_chip(2));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('schedule-editor-text')),
        '量子力学',
      );
      await tester.tap(find.byKey(const ValueKey('schedule-editor-done')));
      await tester.pumpAndSettle();

      expect(state.debugData.cell('r2', 'c1').text, '量子力学');
      expect(state.debugData.cell('r2', 'c1').colorIndex, 2);
      final back = await ScheduleStore().load();
      expect(back.cell('r2', 'c1').text, '量子力学');
      expect(back.cell('r2', 'c1').colorIndex, 2);
    });

    testWidgets('选「无色」把底色去掉，文字保留', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell('r1', 'c1', const ScheduleCell(text: 'x', colorIndex: 4));
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(_cell(0, 0));
      await tester.pumpAndSettle();
      await tester.tap(_chip(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-editor-done')));
      await tester.pumpAndSettle();

      expect(state.debugData.cell('r1', 'c1').colorIndex, 0);
      expect(state.debugData.cell('r1', 'c1').text, 'x');
    });

    testWidgets('「清除此格」把文字与底色一起清掉并落库', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell('r1', 'c1', const ScheduleCell(text: 'x', colorIndex: 4));
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(_cell(0, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-editor-clear')));
      await tester.pumpAndSettle();

      expect(state.debugData.cell('r1', 'c1'), ScheduleCell.empty);
      expect(state.debugFilling, isFalse);
      final back = await ScheduleStore().load();
      expect(back.cell('r1', 'c1'), ScheduleCell.empty);
    });
  });

  group('★ 长按拖拽自动填充', () {
    testWidgets('长按某格向右拖 2 格 → 中途有预览 → 松手后 3 格同字同色 + 落库',
        (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: '实验报告', colorIndex: 1),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(
        tester,
        _cell(0, 0),
        _cell(0, 2),
        onArrived: () async {
          // 松手**前**：预览集合 = 拖过的后两格（不含源格）
          expect(state.debugFilling, isTrue, reason: '应处于填充模式');
          expect(state.debugFillPreview, {
            (row: 0, col: 1),
            (row: 0, col: 2),
          });
          // 中间那张格子此时就该显示"将要填进去的文字"
          expect(find.text('实验报告'), findsNWidgets(3));
        },
      );

      expect(state.debugFilling, isFalse, reason: '松手后退出填充模式');
      for (var c = 0; c < 3; c++) {
        expect(state.debugData.cell('r1', 'c${c + 1}').text, '实验报告',
            reason: '第 $c 列应被填充');
        expect(state.debugData.cell('r1', 'c${c + 1}').colorIndex, 1);
      }
      // 同一行的第 2 行不受影响
      expect(state.debugData.cell('r2', 'c1'), ScheduleCell.empty);

      // 落库
      final back = await ScheduleStore().load();
      expect(back.cell('r1', 'c2').text, '实验报告');
      expect(back.cell('r1', 'c3').colorIndex, 1);
      // 提示 + 撤销
      expect(find.textContaining('已填充 2 格'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
    });

    testWidgets('源格只有颜色没文本 → 只填色，不写入文字', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell('r1', 'c1', const ScheduleCell(colorIndex: 5));
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(tester, _cell(0, 0), _cell(0, 1));

      expect(state.debugData.cell('r1', 'c2').colorIndex, 5);
      expect(state.debugData.cell('r1', 'c2').text, isEmpty);
    });

    testWidgets('向下拖：一列 N 格全填上（文本 + 颜色）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c2',
        const ScheduleCell(text: '复习', colorIndex: 2),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(tester, _cell(0, 1), _cell(3, 1));

      for (var r = 0; r < 4; r++) {
        expect(state.debugData.cell('r${r + 1}', 'c2').text, '复习');
        expect(state.debugData.cell('r${r + 1}', 'c2').colorIndex, 2);
      }
      // 同列第 5 行没被碰
      expect(state.debugData.cell('r5', 'c2'), ScheduleCell.empty);
    });

    testWidgets('向左拖：源格右侧的格子不动，左边两格被填', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r2',
        'c3',
        const ScheduleCell(text: 'linux', colorIndex: 5),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(tester, _cell(1, 2), _cell(1, 0));

      expect(state.debugData.cell('r2', 'c1').text, 'linux');
      expect(state.debugData.cell('r2', 'c2').text, 'linux');
      expect(state.debugData.cell('r2', 'c3').text, 'linux');
    });

    testWidgets('斜着拖 = 矩形块全部填上（与 Excel 选择语义一致）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: 'A', colorIndex: 1),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(tester, _cell(0, 0), _cell(2, 1));

      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 2; c++) {
          expect(state.debugData.cell('r${r + 1}', 'c${c + 1}').text, 'A',
              reason: 'r${r + 1}c${c + 1} 应在矩形内');
        }
      }
      expect(state.debugData.cell('r3', 'c3'), ScheduleCell.empty);
      expect(state.debugData.cell('r4', 'c1'), ScheduleCell.empty);
    });

    testWidgets('长按空格子不进入填充模式，只给一句提示', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(tester, _cell(0, 0), _cell(0, 2));

      expect(state.debugFilling, isFalse);
      expect(find.textContaining('这个格子是空的'), findsOneWidget);
      for (var c = 0; c < 3; c++) {
        expect(state.debugData.cell('r1', 'c${c + 1}'), ScheduleCell.empty);
      }
    });

    testWidgets('长按原地松手（没拖出源格）＝无操作，不弹提示也不改表',
        (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: 'A', colorIndex: 1),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      final g = await _holdLongPress(tester, _cell(0, 0));
      expect(state.debugFilling, isTrue, reason: '按下 500ms 就进填充模式了');
      await g.up();
      await tester.pumpAndSettle();

      expect(state.debugFilling, isFalse);
      expect(find.textContaining('已填充'), findsNothing);
      expect(state.debugData.cell('r1', 'c1').text, 'A');
      expect(state.debugData.cell('r1', 'c2'), ScheduleCell.empty);
    });

    testWidgets('填充可撤销（SnackBar「撤销」→ 回到填充前）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: 'A', colorIndex: 1),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await _dragFill(tester, _cell(0, 0), _cell(0, 2));
      expect(state.debugData.cell('r1', 'c2').text, 'A');

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();

      expect(state.debugData.cell('r1', 'c2'), ScheduleCell.empty);
      expect(state.debugData.cell('r1', 'c1').text, 'A', reason: '源格保留');
      // 撤销也落库
      final back = await ScheduleStore().load();
      expect(back.cell('r1', 'c2'), ScheduleCell.empty);
    });

    testWidgets('长按不会误触发"点击编辑"（两者互斥）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: 'A', colorIndex: 1),
      );
      await store.save(data);
      await _pumpPage(tester, store: store);

      // 长按（原地）→ 不该弹编辑面板
      final g = await _holdLongPress(tester, _cell(0, 0));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-editor-text')), findsNothing);

      // 普通点击 → 该弹
      await tester.tap(_cell(0, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-editor-text')), findsOneWidget);
    });
  });

  group('加行 / 加列 / 删行 / 删列', () {
    testWidgets('「加行」追加一个空行（数量与内容都对）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: '门票', colorIndex: 1),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('schedule-add-row')));
      await tester.pumpAndSettle();

      expect(state.debugData.rows.length, 9);
      expect(state.debugData.rows.last.isEmpty, isTrue);
      expect(state.debugData.cell('r1', 'c1').text, '门票');
      expect(find.byKey(const ValueKey('schedule-rowhead-8')), findsOneWidget);
      expect((await ScheduleStore().load()).rows.length, 9);
    });

    testWidgets('「加日期列」列头 = 最后一列日期 +1 天，已有内容不动',
        (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell(
        'r1',
        'c1',
        const ScheduleCell(text: '门票', colorIndex: 1),
      );
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      final lastLabel = state.debugData.columns.last.label;
      await tester.tap(find.byKey(const ValueKey('schedule-add-column')));
      await tester.pumpAndSettle();

      expect(state.debugData.columns.length, 4);
      expect(state.debugData.columns.last.label, '周四 9.17',
          reason: '最后一列是周三 9.16，+1 天 = 周四 9.17（与 $lastLabel 对照）');
      expect(state.debugData.cell('r1', 'c1').text, '门票');
      expect(find.text('周四 9.17'), findsOneWidget);
    });

    testWidgets('连加两列：日期连续递增，id 不撞', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('schedule-add-column')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-add-column')));
      await tester.pumpAndSettle();

      expect(state.debugData.columns.length, 5);
      expect(state.debugData.columns.map((c) => c.label).toList().sublist(3),
          ['周四 9.17', '周五 9.18']);
      expect(state.debugData.columns.map((c) => c.id).toSet().length, 5);
      // 每一行都给新列留了空格（不是渲染不出来）
      expect(state.debugData.rows.every((r) => r.isEmpty), isTrue);
    });

    testWidgets('行头菜单 → 删除此行：少一行，该行内容也没了', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data
          .setCell('r2', 'c1', const ScheduleCell(text: '被删的行', colorIndex: 1))
          .setCell('r3', 'c1', const ScheduleCell(text: '留着的行', colorIndex: 2));
      await store.save(data);
      final state = await _pumpPage(tester, store: store);
      expect(find.text('被删的行'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('schedule-rowhead-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除此行'));
      await tester.pumpAndSettle();

      expect(state.debugData.rows.length, 7);
      expect(state.debugData.row('r2'), isNull);
      expect(find.text('被删的行'), findsNothing);
      expect(find.text('留着的行'), findsOneWidget, reason: '别的行不受影响');
    });

    testWidgets('列头菜单 → 删除此列：有二次确认，确认后该列数据不再出现',
        (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data
          .setCell('r1', 'c1', const ScheduleCell(text: '门票', colorIndex: 1))
          .setCell('r1', 'c2', const ScheduleCell(text: '修改门票', colorIndex: 1));
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('schedule-colhead-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除此列'));
      await tester.pumpAndSettle();

      // 二次确认
      expect(find.textContaining('这一列？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(state.debugData.columns.length, 2);
      expect(state.debugData.column('c1'), isNull);
      expect(state.debugData.cell('r1', 'c1'), ScheduleCell.empty);
      expect(find.text('门票'), findsNothing);
      expect(find.text('修改门票'), findsOneWidget);
      final back = await ScheduleStore().load();
      expect(back.rows.every((r) => !r.cells.containsKey('c1')), isTrue);
    });

    testWidgets('删列对话框点「取消」→ 一列都不少', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell('r1', 'c1', const ScheduleCell(text: '门票', colorIndex: 1));
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('schedule-colhead-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除此列'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(state.debugData.columns.length, 3);
      expect(state.debugData.cell('r1', 'c1').text, '门票');
    });

    testWidgets('列头菜单 → 改列头（把日期改成「考试周」）', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final state = await _pumpPage(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('schedule-colhead-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('改列头'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '考试周');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(state.debugData.columns[1].label, '考试周');
      expect(find.text('考试周'), findsOneWidget);
    });

    testWidgets('把所有行删光 → 给可用的空态（还能加回来）', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData(columns: const [
        ScheduleColumn(id: 'c1', label: '周一 9.14'),
      ]);
      await store.save(data);
      final state = await _pumpPage(tester, store: store);

      expect(find.textContaining('先加一列日期、加几行'), findsOneWidget);
      // 用 key 点顶部那颗「加行」（空态里还有一颗同名按钮，靠 key 区分）
      await tester.tap(find.byKey(const ValueKey('schedule-add-row')));
      await tester.pumpAndSettle();
      expect(state.debugData.rows.length, 1);
      expect(find.byKey(const ValueKey('schedule-cell-0-0')), findsOneWidget);
      data = state.debugData;
      expect(data.columns.length, 1);
    });
  });

  group('持久化', () {
    testWidgets('改完 → 重建页面（模拟重启）内容还在', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      await _pumpPage(tester, store: store);
      await _tapFirstCellAndFill(
        tester,
        row: 2,
        col: 0,
        text: '校党校',
        color: 4,
      );

      // 重新 pump 一个全新页面（同一个存储）
      final state = await _pumpPage(tester, store: ScheduleStore());
      expect(state.debugData.cell('r3', 'c1').text, '校党校');
      expect(state.debugData.cell('r3', 'c1').colorIndex, 4);
      expect(find.text('校党校'), findsOneWidget);
    });
  });

  group('冻结表头 / 行头的滚动跟随', () {
    testWidgets('横向滚网格 → 日期表头跟着滚、左侧行头不动', (tester) async {
      // 默认测试视口 800×600：内容要**真的**超出视口才滚得动。
      // 不调 tester.view.physicalSize（改视口尺寸会触发 _MediaQueryFromView
      // 的框架断言），改成把表造大：14 列 = 1344dp > 视口宽。
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      for (var i = 0; i < 11; i++) {
        data = data.addColumn(today: DateTime(2026, 9, 17));
      }
      await store.save(data);
      await _pumpPage(tester, store: store);
      expect(data.columns.length, 14);

      final headBefore = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-colhead-0')),
      );
      final rowHeadBefore = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-rowhead-0')),
      );

      await tester.drag(_cell(0, 0), const Offset(-200, 0));
      await tester.pumpAndSettle();

      final headAfter = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-colhead-0')),
      );
      final rowHeadAfter = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-rowhead-0')),
      );
      expect(headAfter.dx, lessThan(headBefore.dx - 100),
          reason: '日期表头必须跟着横向滚动');
      expect(rowHeadAfter.dx, closeTo(rowHeadBefore.dx, 0.5),
          reason: '左侧行头列横向冻结');
      expect(headAfter.dy, closeTo(headBefore.dy, 0.5),
          reason: '日期表头纵向冻结');
    });

    testWidgets('纵向滚网格 → 左侧行头跟着滚、日期表头不动', (tester) async {
      // 同上：不缩视口，改成把行数堆到 24 行（1056dp > 视口高）
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      for (var i = 0; i < 16; i++) {
        data = data.addRow();
      }
      await store.save(data);
      await _pumpPage(tester, store: store);
      expect(data.rows.length, 24);

      final rowHeadBefore = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-rowhead-0')),
      );
      final headBefore = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-colhead-0')),
      );

      await tester.drag(_cell(0, 0), const Offset(0, -200));
      await tester.pumpAndSettle();

      final rowHeadAfter = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-rowhead-0')),
      );
      final headAfter = tester.getTopLeft(
        find.byKey(const ValueKey('schedule-colhead-0')),
      );
      expect(rowHeadAfter.dy, lessThan(rowHeadBefore.dy - 100),
          reason: '左侧行头必须跟着纵向滚动');
      expect(headAfter.dy, closeTo(headBefore.dy, 0.5),
          reason: '日期表头行纵向冻结');
      expect(rowHeadAfter.dx, closeTo(rowHeadBefore.dx, 0.5),
          reason: '行头列横向冻结');
    });
  });
}

/// `ScheduleData → 便于断言的 Map`（测试内部只用来看结构，不参与序列化契约）。
Map<String, Object?> jsonOf(ScheduleData d) => d.toJson();
