// 日程表模型 + 存储单测（v2.33.0）。
//
// 三条主线：
// 1. **往返一致**：toJson → jsonEncode → jsonDecode → fromJson 后逐格相等；
// 2. **脏数据安全降级**：这是重点——日程是用户唯一一份私人数据，任何
//    畸形输入都必须退化成"能用的空表/空格"，绝不能抛（抛了会连累整个
//    App 启动，因为日程页是主页 PageView 的一页）；
// 3. **纯函数**：色板下标、列头日期、新列日期推导，全部可脱离 UI 断言。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/schedule.dart';
import 'package:bili_whitelist_app/services/schedule_store.dart';

/// 造一张小表：2 列 × 2 行，其中两格有内容（列 id 用固定的 c1/c2）。
ScheduleData _sample() {
  final base = ScheduleData(
    columns: const [
      ScheduleColumn(id: 'c1', label: '周一 9.14'),
      ScheduleColumn(id: 'c2', label: '周二 9.15'),
    ],
    rows: [ScheduleRow(id: 'r1'), ScheduleRow(id: 'r2')],
  );
  return base
      .setCell('r1', 'c1', const ScheduleCell(text: '实验报告', colorIndex: 1))
      .setCell('r1', 'c2', const ScheduleCell(text: '门票', colorIndex: 3))
      .setCell('r2', 'c1', const ScheduleCell(text: '量子力学', colorIndex: 2));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('色板与颜色下标', () {
    test('0 = 无色；1..N 依次对应色板，且前 5 个逐字沿用原型色值', () {
      expect(scheduleColorAt(0), isNull);
      expect(scheduleColorAt(-1), isNull);
      expect(scheduleColorAt(kScheduleColors.length + 1), isNull);
      // 原型里用户实际用过的 5 种底色（黄 / 灰 / 绿 / 红 / 蓝）
      expect(scheduleColorAt(1)!.toARGB32(), 0xFFFFFF00);
      expect(scheduleColorAt(2)!.toARGB32(), 0xFFBFBFBF);
      expect(scheduleColorAt(3)!.toARGB32(), 0xFF92D050);
      expect(scheduleColorAt(4)!.toARGB32(), 0xFFFF0000);
      expect(scheduleColorAt(5)!.toARGB32(), 0xFF00B0F0);
    });

    test('下标清洗：越界 / 负数 → 0（无色），不收敛到最后一个颜色', () {
      expect(normalizeScheduleColorIndex(0), 0);
      expect(normalizeScheduleColorIndex(3), 3);
      expect(normalizeScheduleColorIndex(kScheduleColors.length),
          kScheduleColors.length);
      // 越界不是"夹到最大值"：宁可少一个底色，也不能把格子染成
      // 用户根本没选过的颜色
      expect(normalizeScheduleColorIndex(kScheduleColors.length + 1), 0);
      expect(normalizeScheduleColorIndex(-5), 0);
    });
  });

  group('列头日期', () {
    test('scheduleColumnLabel = 「周X M.D」', () {
      // 2026-09-14 是周一（已用系统 date 核对）
      expect(scheduleColumnLabel(DateTime(2026, 9, 14)), '周一 9.14');
      expect(scheduleColumnLabel(DateTime(2026, 9, 20)), '周日 9.20');
    });

    test('parseScheduleMonthDay 认得出来各种写法', () {
      expect(parseScheduleMonthDay('周一 9.15', year: 2026),
          DateTime(2026, 9, 15));
      expect(parseScheduleMonthDay('周一9.15', year: 2026),
          DateTime(2026, 9, 15));
      expect(parseScheduleMonthDay('9月15日', year: 2026), DateTime(2026, 9, 15));
      expect(parseScheduleMonthDay('9-15', year: 2026), DateTime(2026, 9, 15));
      // 认不出来 / 非法日期 → null（不抛）
      expect(parseScheduleMonthDay('考试周', year: 2026), isNull);
      expect(parseScheduleMonthDay('', year: 2026), isNull);
      expect(parseScheduleMonthDay('2月31日', year: 2026), isNull);
      expect(parseScheduleMonthDay('13月1日', year: 2026), isNull);
    });

    test('「星期X」写法也认得（导入 Excel 后列头就是这种，v2.34.0）', () {
      // 用户原型文件（超级代办 大三上.xlsx）的表头是「星期一9.14」这种写法：
      // 「星期」而不是「周」。日期解析本来就只看「数字.数字」那一段，
      // 所以这里靠用例把这条口径钉住——导入后「加日期列」能接着往后排。
      expect(parseScheduleMonthDay('星期一9.14', year: 2026),
          DateTime(2026, 9, 14));
      expect(parseScheduleMonthDay('星期一 9.14', year: 2026),
          DateTime(2026, 9, 14));
      expect(parseScheduleMonthDay('星期日9.20', year: 2026),
          DateTime(2026, 9, 20));
      // 只有星期、没有日期 → 认不出来（导入进来的「星期二」这种列头）
      expect(parseScheduleMonthDay('星期二', year: 2026), isNull);
      // 空表头导入后的兜底文案也不该被误认成日期
      expect(parseScheduleMonthDay('第23列', year: 2026), isNull);
    });

    test('导入后的列头里往回扫：星期一9.14 → 9.15', () {
      const cols = [
        ScheduleColumn(id: 'c1', label: '星期日'),
        ScheduleColumn(id: 'c2', label: '星期一9.14'),
        // 空列头导入后的兜底 label，认不出来 → 继续往回扫
        ScheduleColumn(id: 'c3', label: '第3列'),
      ];
      expect(nextScheduleColumnDate(cols, today: DateTime(2026, 9, 17)),
          DateTime(2026, 9, 15));
    });

    test('nextScheduleColumnDate = 最后一个**能认出来**的列头 + 1 天', () {
      const cols = [
        ScheduleColumn(id: 'c1', label: '周一 9.14'),
        // 用户手改成"考试周"——只看最后一列就认不出来，所以要往回扫
        ScheduleColumn(id: 'c2', label: '考试周'),
      ];
      expect(nextScheduleColumnDate(cols, today: DateTime(2026, 9, 17)),
          DateTime(2026, 9, 15));
    });

    test('全表列头都认不出来 → 退化成「今天 + 1 天」', () {
      const cols = [ScheduleColumn(id: 'c1', label: '考试周')];
      expect(nextScheduleColumnDate(cols, today: DateTime(2026, 9, 17, 23)),
          DateTime(2026, 9, 18));
      // 空表同理
      expect(nextScheduleColumnDate(const [], today: DateTime(2026, 9, 17)),
          DateTime(2026, 9, 18));
    });

    test('mondayOfWeek：周一自身不变，周日回退 6 天', () {
      expect(mondayOfWeek(DateTime(2026, 9, 14)), DateTime(2026, 9, 14));
      expect(mondayOfWeek(DateTime(2026, 9, 17, 15, 30)), DateTime(2026, 9, 14));
      expect(mondayOfWeek(DateTime(2026, 9, 20)), DateTime(2026, 9, 14));
    });
  });

  group('默认表', () {
    test('首次使用 = 本周一起 3 列 × 8 个空行', () {
      final d = ScheduleData.initial(today: DateTime(2026, 9, 17));
      expect(d.columns.length, 3);
      expect(d.rows.length, 8);
      expect(d.columns.map((c) => c.label).toList(),
          ['周一 9.14', '周二 9.15', '周三 9.16']);
      expect(d.rows.every((r) => r.isEmpty), isTrue);
      // 列/行 id 唯一且稳定可预测（测试与撤销都依赖这点）
      expect(d.columns.map((c) => c.id).toList(), ['c1', 'c2', 'c3']);
      expect(d.rows.map((r) => r.id).toList(),
          ['r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8']);
    });

    test('周日打开也是本周一开头（不会算成下周）', () {
      final d = ScheduleData.initial(today: DateTime(2026, 9, 20, 9));
      expect(d.columns.first.label, '周一 9.14');
    });
  });

  group('格子增改删（纯函数）', () {
    test('写/读/清一格；空格子不进 map（不留垃圾键）', () {
      var d = ScheduleData.initial(today: DateTime(2026, 9, 17));
      expect(d.cell('r1', 'c1'), ScheduleCell.empty);

      d = d.setCell('r1', 'c1', const ScheduleCell(text: '实验报告', colorIndex: 1));
      expect(d.cell('r1', 'c1').text, '实验报告');
      expect(d.cell('r1', 'c1').colorIndex, 1);

      // 只改颜色：文本保留
      d = d.setCell('r1', 'c1', d.cell('r1', 'c1').copyWith(colorIndex: 4));
      expect(d.cell('r1', 'c1').text, '实验报告');
      expect(d.cell('r1', 'c1').colorIndex, 4);

      // 清空 = 从 map 里摘掉
      d = d.setCell('r1', 'c1', ScheduleCell.empty);
      expect(d.cell('r1', 'c1'), ScheduleCell.empty);
      expect(d.row('r1')!.cells.containsKey('c1'), isFalse);
    });

    test('写不存在的行 / 列 → 原样返回（不凭空造格子）', () {
      final d = ScheduleData.initial(today: DateTime(2026, 9, 17));
      final next = d.setCell('r99', 'c1', const ScheduleCell(text: 'x'));
      expect(identical(next, d), isTrue);
      final next2 = d.setCell('r1', 'c99', const ScheduleCell(text: 'x'));
      expect(identical(next2, d), isTrue);
    });

    test('批量填充一次写多格', () {
      var d = ScheduleData.initial(today: DateTime(2026, 9, 17));
      d = d.setCells(
        [
          (rowId: 'r1', columnId: 'c1'),
          (rowId: 'r1', columnId: 'c2'),
          (rowId: 'r2', columnId: 'c3'),
        ],
        const ScheduleCell(text: '抄实验报告', colorIndex: 2),
      );
      expect(d.cell('r1', 'c1').text, '抄实验报告');
      expect(d.cell('r1', 'c2').colorIndex, 2);
      expect(d.cell('r2', 'c3').text, '抄实验报告');
      expect(d.cell('r2', 'c1'), ScheduleCell.empty);
    });

    test('加行 / 加列：id 递增不撞号，内容不动', () {
      var d = ScheduleData.initial(today: DateTime(2026, 9, 17))
          .removeRow('r2'); // 掏一个洞，验证新行不会复用 id
      d = d.addRow();
      expect(d.rows.length, 8);
      expect(d.rows.last.id, 'r9');
      expect(d.rows.last.isEmpty, isTrue);

      d = d.setCell('r1', 'c1', const ScheduleCell(text: 'x'));
      d = d.addColumn(today: DateTime(2026, 9, 17));
      expect(d.columns.length, 4);
      // 新列日期 = 最后一列（周三 9.16）+ 1 天
      expect(d.columns.last.label, '周四 9.17');
      expect(d.cell('r1', 'c1').text, 'x', reason: '加列不该动已有内容');
      expect(d.cell('r1', d.columns.last.id), ScheduleCell.empty);
    });

    test('删行：只少那一行；删列：该列数据一起没（不留孤儿格子）', () {
      var d = _sample();
      d = d.removeRow('r1');
      expect(d.rows.map((r) => r.id).toList(), ['r2']);
      expect(d.cell('r1', 'c1'), ScheduleCell.empty);

      d = _sample();
      d = d.removeColumn('c1');
      expect(d.columns.map((c) => c.id).toList(), ['c2']);
      // 该列在所有行里的数据都不再出现
      expect(d.cell('r1', 'c1'), ScheduleCell.empty);
      expect(d.cell('r2', 'c1'), ScheduleCell.empty);
      expect(d.rows.every((r) => !r.cells.containsKey('c1')), isTrue);
      // 其它列不受影响
      expect(d.cell('r1', 'c2').text, '门票');
    });

    test('改列头：空串忽略（不产生无标题列）', () {
      var d = _sample();
      d = d.renameColumn('c1', '  考试周  ');
      expect(d.column('c1')!.label, '考试周');
      expect(d.renameColumn('c1', '   ').column('c1')!.label, '考试周');
    });
  });

  group('JSON 往返', () {
    test('toJson → jsonDecode → fromJson 后逐格一致', () {
      final d = _sample();
      final back = ScheduleData.fromJson(
        jsonDecodeRoundTrip(d),
      );
      expect(back.columns, d.columns);
      expect(back.rows.length, d.rows.length);
      for (final r in d.rows) {
        for (final c in d.columns) {
          expect(back.cell(r.id, c.id), d.cell(r.id, c.id),
              reason: '${r.id}/${c.id} 往返后应相等');
        }
      }
    });
  });

  group('脏数据安全降级（全部不许抛）', () {
    test('整份不是 Map → 空表', () {
      for (final raw in [null, 42, 'x', <int>[1, 2]]) {
        final d = ScheduleData.fromJson(raw);
        expect(d.isEmpty, isTrue, reason: '$raw 应降级成空表');
      }
    });

    test('columns / rows 不是 List → 当空', () {
      final d = ScheduleData.fromJson({
        'columns': 'oops',
        'rows': {'not': 'a list'},
      });
      expect(d.isEmpty, isTrue);
    });

    test('缺字段 / 列表里混进非 Map → 跳过坏的，留住好的', () {
      final d = ScheduleData.fromJson({
        'columns': [
          null,
          'nope',
          {'id': 'c1', 'label': '周一 9.14'},
          {'id': 'c2'},
        ],
        'rows': [
          null,
          {'id': 'r1', 'cells': null},
          {
            'id': 'r2',
            'cells': {'c1': {'t': '门票', 'c': 3}},
          },
        ],
      });
      expect(d.columns.map((c) => c.id).toList(), ['c1', 'c2']);
      expect(d.column('c1')!.label, '周一 9.14');
      expect(d.column('c2')!.label, '');
      expect(d.rows.map((r) => r.id).toList(), ['r1', 'r2']);
      expect(d.cell('r2', 'c1').text, '门票');
      expect(d.cell('r2', 'c1').colorIndex, 3);
    });

    test('列 id 缺失 / 撞号 → 重新编号，但**不丢这一列**', () {
      final d = ScheduleData.fromJson({
        'columns': [
          {'label': '周一 9.14'},
          {'id': 'c1', 'label': '周二 9.15'},
          {'id': 'c1', 'label': '周三 9.16'},
        ],
        'rows': [],
      });
      expect(d.columns.length, 3);
      expect(d.columns.map((c) => c.id).toSet().length, 3,
          reason: 'id 必须唯一');
      expect(d.columns.map((c) => c.label).toList(),
          ['周一 9.14', '周二 9.15', '周三 9.16']);
    });

    test('格子类型不对 → 只坏那一个格子，同行其它格子照留', () {
      final d = ScheduleData.fromJson({
        'columns': [
          {'id': 'c1', 'label': 'a'},
          {'id': 'c2', 'label': 'b'},
          {'id': 'c3', 'label': 'c'},
        ],
        'rows': [
          {
            'id': 'r1',
            'cells': {
              'c1': 'i-am-a-string', // 不是 Map
              'c2': {'t': '好格子', 'c': 'bad'}, // c 类型不对
              'c3': {'t': 123, 'c': 9}, // t 是数字、c 越界
            },
          },
        ],
      });
      expect(d.cell('r1', 'c1'), ScheduleCell.empty);
      expect(d.cell('r1', 'c2').text, '好格子');
      expect(d.cell('r1', 'c2').colorIndex, 0, reason: 'c 非数字 → 无色');
      expect(d.cell('r1', 'c3').text, '123', reason: '非字符串文本宽容成字符串');
      expect(d.cell('r1', 'c3').colorIndex, 0, reason: '越界色号 → 无色');
    });

    test('行里指向不存在列的格子 → 丢弃（删列后的残留）', () {
      final d = ScheduleData.fromJson({
        'columns': [
          {'id': 'c1', 'label': 'a'},
        ],
        'rows': [
          {
            'id': 'r1',
            'cells': {
              'c1': {'t': '留着', 'c': 1},
              'ghost': {'t': '孤儿', 'c': 1},
            },
          },
        ],
      });
      expect(d.cell('r1', 'c1').text, '留着');
      expect(d.row('r1')!.cells.containsKey('ghost'), isFalse);
    });

    test('行 id 缺失 / 撞号 → 重新编号', () {
      final d = ScheduleData.fromJson({
        'columns': [
          {'id': 'c1', 'label': 'a'},
        ],
        'rows': [
          {'id': 'r1'},
          {},
          {'id': 'r1'},
        ],
      });
      expect(d.rows.length, 3);
      expect(d.rows.map((r) => r.id).toSet().length, 3);
    });
  });

  group('ScheduleStore（只走 SharedPreferences，不进 Gist）', () {
    test('本机没存过 → 铺默认表（3 列 × 8 行）并落库', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ScheduleStore();
      final d = await store.load();
      expect(d.columns.length, 3);
      expect(d.rows.length, 8);
      expect(d.columns.first.label, startsWith('周一'));
      // 已落库：换个实例读同一份存储，拿到的是同一张表（不是新造的）
      final again = await StoreReader().read();
      expect(again, isNotNull, reason: '首次铺的默认表应当已经写进存储');
      expect(again!['columns'], hasLength(3));
      expect(again['rows'], hasLength(8));
    });

    test('save → 新建 store 读回（模拟重启）', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ScheduleStore();
      await store.save(_sample());
      // 换一个实例读同一份存储 = 重启后重读
      final back = await ScheduleStore().load();
      expect(back.columns.map((c) => c.label).toList(), ['周一 9.14', '周二 9.15']);
      expect(back.cell('r1', 'c1').text, '实验报告');
      expect(back.cell('r1', 'c2').colorIndex, 3);
      expect(back.cell('r2', 'c1').text, '量子力学');
      expect(back.rows[0].id, 'r1', reason: '行 id 也要一起回来（撤销/定位靠它）');
    });

    test('用户自己删空的表会原样返回（不会被当成"没存过"再铺默认表）', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ScheduleStore();
      await store.save(ScheduleData.empty());
      final back = await store.load();
      expect(back.isEmpty, isTrue);
    });

    test('清空后 load 会重新铺默认表', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ScheduleStore();
      await store.save(_sample());
      await store.clear();
      final back = await store.load();
      expect(back.columns.length, 3);
      expect(back.rows.length, 8);
    });

    test('存的 JSON 截断 → 给默认表，且**不覆盖**盘上的坏值', () async {
      const broken = '{"v":1,"columns":[{"id":"c1"';
      SharedPreferences.setMockInitialValues({ScheduleStore.storageKey: broken});
      final back = await ScheduleStore().load();
      expect(back.columns.length, 3);
      expect(back.rows.length, 8);
      // 坏值还在盘上（万一用户手改坏了还有机会捞回来）
      expect(await StoreReader().raw(), broken);
    });

    test('存的值是合法 JSON 但结构全错 → 空表（坏值也不被覆盖）', () async {
      const broken = '"just a string"';
      SharedPreferences.setMockInitialValues({ScheduleStore.storageKey: broken});
      final back = await ScheduleStore().load();
      expect(back.isEmpty, isTrue);
      expect(await StoreReader().raw(), broken);
    });

    test('存储通道异常 → load 给默认表、save/clear 静默，全程不抛', () async {
      // 注入一个必定抛的 SharedPreferences 提供者：不注入就没法让真实的
      // getInstance() 抛，这条容错分支会永远没被实测过
      Future<SharedPreferences> boom() async => throw StateError('no plugin');
      final store = ScheduleStore(prefs: boom);
      final d = await store.load();
      expect(d.columns.length, 3, reason: '读失败要降级成一张能用的默认表');
      expect(d.rows.length, 8);
      await store.save(_sample()); // 不该抛
      await store.clear(); // 不该抛
    });
  });
}

/// `ScheduleData → jsonEncode → jsonDecode`（走真实字符串，不偷懒直接传 Map）。
Object? jsonDecodeRoundTrip(ScheduleData d) =>
    jsonDecode(jsonEncode(d.toJson()));

/// 先写后读的辅助：直接读底层存储里的原始字符串 / 解析结果，
/// 用来断言"盘上到底存了什么"（与 store 的行为解耦）。
class StoreReader {
  Future<String?> raw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(ScheduleStore.storageKey);
  }

  Future<Map<String, dynamic>?> read() async {
    final s = await raw();
    if (s == null) return null;
    return jsonDecode(s) as Map<String, dynamic>;
  }
}
