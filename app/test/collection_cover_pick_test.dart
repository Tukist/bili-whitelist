// 「从相册选图」通道协议测试（v2.50.0）：mock `bili_whitelist/pick_image`
// MethodChannel，验证 Dart 侧真的发了 `pickImage`、以及原生各种返回都被翻译成
// **能直接显示的中文 + 永不抛**。
//
// 三种结果必须分开（这是这一层存在的全部意义）：
// - 用户取消（原生回 null）→ isCancelled，页面什么都不做、不弹错误；
// - 成功 → bytes + name；
// - 失败 → error 是一句中文（FILE_TOO_LARGE / BUSY / NO_PICKER / READ_FAILED /
//   通道不存在），页面对错误码零感知。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/image_pick_service.dart';

final Uint8List _fakeImage = Uint8List.fromList(
  List<int>.generate(64, (i) => i),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) respond;

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ImagePickService.channel, (call) async {
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
        .setMockMethodCallHandler(ImagePickService.channel, null);
  });

  test('发的是 pickImage；成功时带回 bytes / name', () async {
    respond = (_) => <Object?, Object?>{
          'name': 'IMG_20240101_120000.jpg',
          'size': _fakeImage.length,
          'bytes': _fakeImage,
        };

    final pick = await const ImagePickService().pickImage();

    expect(calls.map((c) => c.method).toList(), ['pickImage']);
    expect(pick.isOk, isTrue);
    expect(pick.fileName, 'IMG_20240101_120000.jpg');
    expect(pick.bytes, _fakeImage);
    expect(pick.error, isNull);
  });

  test('原生返回 null（用户在相册里取消）→ isCancelled，不是错误', () async {
    respond = (_) => null;
    final pick = await const ImagePickService().pickImage();
    expect(pick.isCancelled, isTrue);
    expect(pick.bytes, isNull);
    expect(pick.error, isNull, reason: '取消不该报错（点开又退出是正常操作）');
  });

  test('原生返回空字节 → 一句中文错误（不是一个零字节的"成功"）', () async {
    respond = (_) => <Object?, Object?>{'name': 'a.jpg', 'bytes': Uint8List(0)};
    final pick = await const ImagePickService().pickImage();
    expect(pick.isOk, isFalse);
    expect(pick.error, '这张图是空的，读不到内容');
  });

  test('原生返回的数据形状不对 → 一句中文错误，不抛', () async {
    respond = (_) => '不是 Map';
    final pick = await const ImagePickService().pickImage();
    expect(pick.error, '选择图片失败：返回的数据不对');
  });

  test('平台异常的错误码 → 中文文案只在这一层映射', () async {
    Future<String?> errorOf(String code, [String? detail]) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ImagePickService.channel, (call) async {
        throw PlatformException(code: code, message: detail);
      });
      final pick = await const ImagePickService().pickImage();
      return pick.error;
    }

    expect(await errorOf('FILE_TOO_LARGE', '20000000'), contains('超过 10 MB 上限'));
    expect(await errorOf('FILE_TOO_LARGE', '-1'), contains('超过 10 MB 上限'));
    expect(await errorOf('BUSY'), '上一次选择还没结束，稍等一下再试');
    expect(await errorOf('NO_PICKER'), '系统里没有可用的图片选择器');
    expect(await errorOf('READ_FAILED', '打不开这张图片'), '读取图片失败：打不开这张图片');
    expect(await errorOf('READ_FAILED'), '读取图片失败');
    expect(await errorOf('WHATEVER', 'x'), '选择图片失败：x');
  });

  test('通道不存在（非 Android / 没注册插件）→ 一句人话，不抛', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ImagePickService.channel, null);
    final pick = await const ImagePickService().pickImage();
    expect(pick.error, '当前版本不支持从相册选图');
    expect(pick.isCancelled, isFalse, reason: '没选成 ≠ 用户取消');
  });

  test('Dart 侧也拦超大图（原生上限被改坏时的第二道）', () async {
    final huge = Uint8List(ImagePickService.maxImageBytes + 1);
    respond = (_) => <Object?, Object?>{'name': 'big.png', 'bytes': huge};
    final pick = await const ImagePickService().pickImage();
    expect(pick.isOk, isFalse);
    expect(pick.error, contains('超过 10 MB 上限'));
  });
}
