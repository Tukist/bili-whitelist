// 日程「导入 Excel」测试（v2.34.0）：分两层。
//
// 1. **通道协议层**（`选文件通道`）：mock MethodChannel，验证 Dart 侧真的发了
//    `pickXlsx`、以及原生各种返回（null = 取消 / FILE_TOO_LARGE / 非 zip 字节）
//    都被翻译成"能直接显示的中文 + 不抛"。
// 2. **页面流程层**（`导入流程`）：注入一个假的选文件服务（不碰通道），验证
//    「多表选一张 → 预览确认 → 整表替换 + 落库 + 提示」以及**取消 / 失败时
//    表一个格子都不许动**。
//
// 夹具是 openpyxl 生成的合成表（tools/make_xlsx_fixture.py），
// 里面**没有**任何用户真实日程。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/schedule.dart';
import 'package:bili_whitelist_app/pages/schedule_page.dart';
import 'package:bili_whitelist_app/services/schedule_import.dart';
import 'package:bili_whitelist_app/services/schedule_store.dart';

/// 合成夹具（3 列 × 3 行内容、4 个有色格、一个空列头、两张可导入表 + 一张 WPS 保留表）。
Uint8List _fixtureBytes() =>
    File('test/fixtures/schedule_sample.xlsx').readAsBytesSync();

/// 手工拼一个只有一张真表 + 一张 WpsReserved 保留表的最小 xlsx。
Uint8List _singleSheetWithWpsReserved() {
  Uint8List zip(Map<String, String> entries) {
    final archive = Archive();
    entries.forEach((name, content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  return zip({
    'xl/workbook.xml': '<workbook><sheets>'
        '<sheet name="Sheet1" sheetId="1" r:id="rId1"/>'
        '<sheet name="WpsReserved_CellImgList" sheetId="2" state="veryHidden" r:id="rId2"/>'
        '</sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<Relationships>'
        '<Relationship Id="rId1" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Target="worksheets/sheet2.xml"/>'
        '</Relationships>',
    'xl/worksheets/sheet1.xml': '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="inlineStr"><is><t>周一 9.15</t></is></c>'
        '<c r="B1" t="inlineStr"><is><t>周二 9.16</t></is></c></row>'
        '<row r="2"><c r="A2" t="inlineStr"><is><t>写代码</t></is></c></row>'
        '</sheetData></worksheet>',
    'xl/worksheets/sheet2.xml': '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="inlineStr"><is><t>wps 内部</t></is></c></row>'
        '</sheetData></worksheet>',
  });
}

/// 假选文件服务：直接给一份预先定好的结果（不碰 MethodChannel）。
class _FakeImporter extends ScheduleImportService {
  _FakeImporter(this.result);

  /// 挂起用的（null = 立刻返回 [result]）。
  Completer<ScheduleImportPick>? gate;

  ScheduleImportPick result;
  int calls = 0;

  @override
  Future<ScheduleImportPick> pickXlsx() async {
    calls++;
    if (gate != null) return gate!.future;
    return result;
  }
}

Future<SchedulePageState> _pumpPage(
  WidgetTester tester, {
  required ScheduleStore store,
  ScheduleImportService? importer,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SchedulePage(store: store, importer: importer)),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<SchedulePageState>(find.byType(SchedulePage));
}

Future<ScheduleData> _seed(ScheduleStore store) async {
  final data = ScheduleData.initial(today: DateTime(2026, 9, 17));
  await store.save(data);
  return data;
}

Finder get _importButton => find.byKey(const ValueKey('schedule-import'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('选文件通道协议（mock MethodChannel）', () {
    late List<MethodCall> calls;
    late Object? Function(MethodCall call) respond;

    void mockChannel() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ScheduleImportService.channel, (call) async {
        calls.add(call);
        return respond(call);
      });
    }

    setUp(() {
      calls = <MethodCall>[];
      respond = (_) => null;
      mockChannel();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ScheduleImportService.channel, null);
    });

    test('发的是 pickXlsx，成功时带回 bytes / name', () async {
      final bytes = _fixtureBytes();
      respond = (_) => <Object?, Object?>{
            'name': 'schedule_sample.xlsx',
            'size': bytes.length,
            'bytes': bytes,
          };
      final pick = await const ScheduleImportService().pickXlsx();
      expect(calls.map((c) => c.method).toList(), ['pickXlsx']);
      expect(pick.isOk, isTrue);
      expect(pick.fileName, 'schedule_sample.xlsx');
      expect(pick.bytes, bytes);
    });

    test('原生返回 null（用户在系统选择器里取消）→ isCancelled，不是错误', () async {
      respond = (_) => null;
      final pick = await const ScheduleImportService().pickXlsx();
      expect(pick.isCancelled, isTrue);
      expect(pick.error, isNull);
    });

    test('FILE_TOO_LARGE（带 sizes）→ 中文提示里带实际上限', () async {
      respond = (_) => throw PlatformException(
            code: 'FILE_TOO_LARGE',
            message: '${9 * 1024 * 1024}',
          );
      final pick = await const ScheduleImportService().pickXlsx();
      expect(pick.error, contains('9.0 MB'));
      expect(pick.error, contains('5 MB'));
    });

    test('FILE_TOO_LARGE（size 未知 = -1）→ 也给一句明确的提示', () async {
      respond = (_) => throw PlatformException(code: 'FILE_TOO_LARGE', message: '-1');
      final pick = await const ScheduleImportService().pickXlsx();
      expect(pick.error, contains('5 MB'));
    });

    test('非 zip 的字节（把 txt 改成 .xlsx）→ 明确说"不是 xlsx"', () async {
      respond = (_) => <Object?, Object?>{
            'name': '假的.xlsx',
            'bytes': Uint8List.fromList(utf8.encode('这其实是一个文本文件')),
          };
      final pick = await const ScheduleImportService().pickXlsx();
      expect(pick.isOk, isFalse);
      expect(pick.error, contains('.xlsx'));
    });

    test('空字节 / 超 5MB 的字节 → 各自一句提示（Dart 侧二次拦截）', () async {
      respond = (_) => <Object?, Object?>{'name': 'a.xlsx', 'bytes': Uint8List(0)};
      expect((await const ScheduleImportService().pickXlsx()).error, contains('空'));

      final huge = Uint8List(ScheduleImportService.maxFileBytes + 1);
      huge[0] = 0x50;
      huge[1] = 0x4B;
      huge[2] = 0x03;
      huge[3] = 0x04;
      respond = (_) => <Object?, Object?>{'name': 'huge.xlsx', 'bytes': huge};
      final pick = await const ScheduleImportService().pickXlsx();
      expect(pick.error, contains('5 MB'));
    });

    test('READ_FAILED / BUSY / 通道不存在 → 都不抛，各给一句人话', () async {
      respond = (_) => throw PlatformException(code: 'READ_FAILED', message: '打不开');
      expect((await const ScheduleImportService().pickXlsx()).error, contains('打不开'));

      respond = (_) => throw PlatformException(code: 'BUSY');
      expect((await const ScheduleImportService().pickXlsx()).error, contains('稍等'));

      // 撤掉 mock：在测试环境里就是"没有这个原生插件"
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ScheduleImportService.channel, null);
      final pick = await const ScheduleImportService().pickXlsx();
      expect(pick.error, contains('不支持'));
    });
  });

  group('导入流程（页面）', () {
    testWidgets('点「导入 Excel」→ 走选文件；用户取消 → 不提示、表一个格子不动',
        (tester) async {
      final store = ScheduleStore();
      final before = await _seed(store);
      final importer = _FakeImporter(const ScheduleImportPick.cancelled());
      final state = await _pumpPage(tester, store: store, importer: importer);

      expect(_importButton, findsOneWidget);
      await tester.tap(_importButton);
      await tester.pumpAndSettle();

      expect(importer.calls, 1);
      expect(state.debugData.toJson(), before.toJson(), reason: '表不该有任何变化');
      expect(find.textContaining('失败'), findsNothing);
      expect(find.textContaining('打不开'), findsNothing);
      expect((await ScheduleStore().load()).toJson(), before.toJson());
    });

    testWidgets('选文件期间按钮变转圈（loading 态），结束后恢复', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final importer = _FakeImporter(const ScheduleImportPick.cancelled())
        ..gate = Completer<ScheduleImportPick>();
      await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pump();

      expect(find.byKey(const ValueKey('schedule-import-progress')), findsOneWidget);
      expect(
        tester.state<SchedulePageState>(find.byType(SchedulePage)).debugImporting,
        isTrue,
      );

      importer.gate!.complete(const ScheduleImportPick.cancelled());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-import-progress')), findsNothing);
    });

    testWidgets('多工作表 → 弹出选表弹层（WPS 保留表已被过滤）', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final importer = _FakeImporter(
        ScheduleImportPick(bytes: _fixtureBytes(), fileName: 'schedule_sample.xlsx'),
      );
      await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();

      expect(find.text('选择要导入的工作表'), findsOneWidget);
      expect(find.text('课程表'), findsOneWidget);
      expect(find.text('第二张表'), findsOneWidget);
      expect(find.text('WpsReserved_CellImgList'), findsNothing,
          reason: 'WPS 保留表不该出现在选表弹层里');

      // 选第二张表 → 预览里的数字要对得上（1 列 × 0 行；B1 是它唯一的内容）
      await tester.tap(find.byKey(const ValueKey('schedule-import-sheet-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('将导入 2 列 × 0 行'), findsOneWidget);
    });

    testWidgets('预览弹层写清「几列几行、几格有底色」「会替换当前日程」；取消 → 表不变',
        (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data
          .setCell('r1', 'c1', const ScheduleCell(text: '旧内容A', colorIndex: 1))
          .setCell('r2', 'c2', const ScheduleCell(text: '旧内容B', colorIndex: 2));
      await store.save(data);
      final importer = _FakeImporter(
        ScheduleImportPick(bytes: _fixtureBytes(), fileName: 'sample.xlsx'),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-import-sheet-0')));
      await tester.pumpAndSettle();

      expect(find.textContaining('将导入 3 列 × 3 行'), findsOneWidget);
      expect(find.textContaining('4 格有底色'), findsOneWidget);
      expect(find.textContaining('会替换当前日程'), findsOneWidget);
      expect(find.textContaining('2 个非空格子会被清空'), findsOneWidget);
      expect(find.textContaining('此操作不可恢复'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('schedule-import-cancel')));
      await tester.pumpAndSettle();

      expect(state.debugData.cell('r1', 'c1').text, '旧内容A');
      expect(state.debugData.cell('r2', 'c2').text, '旧内容B');
      expect(state.debugData.columns.length, 3);
      expect((await ScheduleStore().load()).cell('r1', 'c1').text, '旧内容A');
    });

    testWidgets('确认「覆盖导入」→ 整表换成文件内容 + 落库 + 成功提示', (tester) async {
      final store = ScheduleStore();
      var data = ScheduleData.initial(today: DateTime(2026, 9, 17));
      data = data.setCell('r1', 'c1', const ScheduleCell(text: '旧内容', colorIndex: 1));
      await store.save(data);
      final importer = _FakeImporter(
        ScheduleImportPick(bytes: _fixtureBytes(), fileName: 'sample.xlsx'),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-import-sheet-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-import-confirm')));
      await tester.pumpAndSettle();

      // 表被替换：列头 = 文件里那行（含「第N列」兜底），行 = 文件的数据行
      expect(state.debugData.columns.map((c) => c.label).toList(),
          ['星期日', '星期一9.14', '第3列']);
      expect(state.debugData.rows.length, 3);
      expect(state.debugData.rows[0].id, 'r1');
      expect(state.debugData.cell('r1', 'c1').text, '写代码');
      expect(state.debugData.cell('r1', 'c1').colorIndex, 1);
      expect(state.debugData.cell('r1', 'c3').colorIndex, 4);
      expect(state.debugData.cell('r1', 'c3').text, isEmpty);
      expect(state.debugData.cell('r2', 'c3').text, '看书');
      expect(state.debugData.cell('r3', 'c2').text, '3');
      expect(find.text('旧内容'), findsNothing);

      // 上屏：列头看得见
      expect(find.text('星期一9.14'), findsOneWidget);

      // 落库
      final back = await ScheduleStore().load();
      expect(back.columns.map((c) => c.label).toList(),
          ['星期日', '星期一9.14', '第3列']);
      expect(back.cell('r1', 'c1').text, '写代码');
      expect(back.cell('r1', 'c1').colorIndex, 1);

      // 成功提示带格数
      expect(find.textContaining('已导入 3 列 × 3 行'), findsOneWidget);
      expect(find.textContaining('4 格带底色'), findsWidgets);
    });

    testWidgets('文件里只有一张真表 + 一张 WPS 保留表 → 不弹选表，直接进预览',
        (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final importer = _FakeImporter(
        ScheduleImportPick(bytes: _singleSheetWithWpsReserved(), fileName: 'x.xlsx'),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();

      expect(find.text('选择要导入的工作表'), findsNothing);
      expect(find.textContaining('将导入 2 列 × 1 行'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('schedule-import-confirm')));
      await tester.pumpAndSettle();
      expect(state.debugData.columns.map((c) => c.label).toList(),
          ['周一 9.15', '周二 9.16']);
      expect(state.debugData.cell('r1', 'c1').text, '写代码');
    });

    testWidgets('文件坏了（解析失败）→ 明确提示，表与存储都不动', (tester) async {
      final store = ScheduleStore();
      final before = await _seed(store);
      final importer = _FakeImporter(
        ScheduleImportPick(
          // 过了 zip 校验但内容不是 xlsx（原生那边只保证"是个 zip"）
          bytes: Uint8List.fromList(
            utf8.encode('PK\u0003\u0004 not really a zip at all'),
          ),
          fileName: 'broken.xlsx',
        ),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('打不开'), findsOneWidget);
      expect(state.debugData.toJson(), before.toJson());
      expect((await ScheduleStore().load()).toJson(), before.toJson());
    });

    testWidgets('文件里没有可导入的表 → 明确提示，表不动', (tester) async {
      final store = ScheduleStore();
      final before = await _seed(store);
      final bytes = Uint8List.fromList(ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile('docProps/core.xml', 8, utf8.encode('<core/>'))))!);
      final importer = _FakeImporter(
        ScheduleImportPick(bytes: bytes, fileName: 'only-core.xlsx'),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('打不开'), findsOneWidget);
      expect(state.debugData.toJson(), before.toJson());
    });

    testWidgets('选文件失败（超 5MB 等错误文案）→ 原样提示，表不动', (tester) async {
      final store = ScheduleStore();
      final before = await _seed(store);
      final importer = _FakeImporter(
        const ScheduleImportPick(error: '这个文件 8.0 MB，超过 5 MB 上限，导入会占用太多内存'),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('超过 5 MB 上限'), findsOneWidget);
      expect(state.debugData.toJson(), before.toJson());
      expect(state.debugImporting, isFalse);
    });

    testWidgets('导入后「加日期列」接着文件里的日期（星期一9.14 → 9.15）', (tester) async {
      final store = ScheduleStore();
      await _seed(store);
      final importer = _FakeImporter(
        ScheduleImportPick(bytes: _fixtureBytes(), fileName: 'sample.xlsx'),
      );
      final state = await _pumpPage(tester, store: store, importer: importer);

      await tester.tap(_importButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-import-sheet-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('schedule-import-confirm')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('schedule-add-column')));
      await tester.pumpAndSettle();

      // 最后一列列头认不出来（第3列）→ 往回扫到「星期一9.14」→ +1 天
      expect(state.debugData.columns.last.label, '周二 9.15');
    });
  });
}
