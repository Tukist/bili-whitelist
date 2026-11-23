// 「从文件导入书源」通道协议测试（v2.70.0）：mock `bili_whitelist/files`
// MethodChannel，验证 Dart 侧真的发了 `pickTextFile`、以及原生各种返回都被翻译
// 成**能直接显示的中文 + 永不抛**。
//
// 三种结果必须分开（这是这一层存在的全部意义）：
// - 用户取消（原生回 null）→ isCancelled，页面什么都不做、不弹错误；
// - 成功 → name + content（BOM 已去掉）；
// - 失败 → error 是一句中文（FILE_TOO_LARGE / BAD_ENCODING / BUSY / NO_PICKER /
//   READ_FAILED / 通道不存在），页面对错误码零感知。
//
// 另外两条纯函数（[stripUtf8Bom] / [fileTooLargeMessage]）单独测：页面与
// 服务都靠它们，改坏了要能一眼看出来。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/file_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) respond;

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FileImportService.channel, (call) async {
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
        .setMockMethodCallHandler(FileImportService.channel, null);
  });

  test('发的是 pickTextFile；成功时带回 name / content', () async {
    respond = (_) => <Object?, Object?>{
          'name': 'sources.json',
          'content': '[{"name":"甲","baseUrl":"https://a.example"}]',
          'sizeBytes': 48,
        };

    final result = await const FileImportService().pickTextFile();

    expect(calls.map((c) => c.method).toList(), ['pickTextFile']);
    expect(result.isOk, isTrue);
    expect(result.file!.name, 'sources.json');
    expect(result.file!.content, contains('甲'));
    expect(result.file!.isBlank, isFalse);
    expect(result.error, isNull);
  });

  test('原生返回 null（用户取消选择）→ isCancelled，不是错误', () async {
    respond = (_) => null;
    final result = await const FileImportService().pickTextFile();
    expect(result.isCancelled, isTrue);
    expect(result.file, isNull);
    expect(result.error, isNull, reason: '点开选择器又退出是正常操作，不该弹错误');
  });

  test('内容带 BOM → 返回值里已经去掉（否则 jsonDecode 第一个字符就报错）', () async {
    respond = (_) => <Object?, Object?>{
          'name': 'bom.json',
          'content': '\uFEFF{"name":"甲","baseUrl":"https://a.example"}',
          'sizeBytes': 40,
        };
    final result = await const FileImportService().pickTextFile();
    expect(result.file!.content.startsWith('{'), isTrue);
    expect(result.file!.content.contains('\uFEFF'), isFalse);
  });

  test('空文件 → 成功但 isBlank（页面据此说「这个文件是空的」）', () async {
    respond = (_) => <Object?, Object?>{'name': 'empty.json', 'content': ''};
    final result = await const FileImportService().pickTextFile();
    expect(result.isOk, isTrue);
    expect(result.file!.isBlank, isTrue);
  });

  test('原生返回的数据形状不对 → 一句中文错误，不抛', () async {
    respond = (_) => '不是 Map';
    expect(
      (await const FileImportService().pickTextFile()).error,
      '选择文件失败：返回的数据不对',
    );

    respond = (_) => <Object?, Object?>{'name': 'x.json', 'content': 42};
    expect(
      (await const FileImportService().pickTextFile()).error,
      '选择文件失败：没读到文件内容',
    );
  });

  test('平台异常的错误码 → 中文文案只在这一层映射', () async {
    Future<String?> errorOf(String code, [String? message]) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FileImportService.channel, (call) async {
        throw PlatformException(code: code, message: message);
      });
      final result = await const FileImportService().pickTextFile();
      return result.error;
    }

    expect(await errorOf('FILE_TOO_LARGE', '文件太大（超过 8MB）'), contains('超过 8 MB'));
    expect(await errorOf('BAD_ENCODING', '这个文件不是 UTF-8 编码'), '这个文件不是 UTF-8 编码');
    expect(await errorOf('BAD_ENCODING'), contains('UTF-8'));
    expect(await errorOf('BUSY'), '上一次选择还没结束，稍等一下再试');
    expect(await errorOf('NO_PICKER'), '系统里没有可用的文件选择器');
    expect(await errorOf('READ_FAILED', '读取文件失败：打不开这个文件'),
        '读取文件失败：打不开这个文件');
    expect(await errorOf('READ_FAILED'), '读取文件失败');
    expect(await errorOf('WHATEVER', 'x'), '选择文件失败：x');
    // 任何一条都必须是"错误"而不是"取消"：没选成 ≠ 用户取消
    final probe = await const FileImportService().pickTextFile();
    expect(probe.isCancelled, isFalse);
  });

  test('通道不存在（非 Android / 没注册插件）→ 一句人话，不抛', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FileImportService.channel, null);
    final result = await const FileImportService().pickTextFile();
    expect(result.error, '当前版本不支持从文件导入');
    expect(result.isCancelled, isFalse, reason: '没选成 ≠ 用户取消');
  });

  test('Dart 侧也拦超限文件（原生上限被改坏时的第二道）', () async {
    respond = (_) => <Object?, Object?>{
          'name': 'huge.json',
          'content': '{}',
          'sizeBytes': maxImportFileBytes + 1,
        };
    final result = await const FileImportService().pickTextFile();
    expect(result.isOk, isFalse);
    expect(result.error, contains('超过 8 MB'));
  });

  test('stripUtf8Bom：只去开头那一个，正文里的同名字符不动', () {
    expect(stripUtf8Bom('\uFEFF{"a":1}'), '{"a":1}');
    expect(stripUtf8Bom('{"a":"\uFEFF"}'), '{"a":"\uFEFF"}');
    expect(stripUtf8Bom('纯文本'), '纯文本');
    expect(stripUtf8Bom(''), '');
  });

  test('fileTooLargeMessage：说清上限 + 该换什么文件', () {
    final message = fileTooLargeMessage();
    expect(message, contains('超过 8 MB'));
    expect(message, contains('书源'));
  });
}
