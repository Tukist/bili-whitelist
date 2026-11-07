// 应用内浮动小窗的窗口状态（FloatWindowPrefs / FloatWindowStore，v2.65.0）
// 单元测试。
//
// 这批需求的核心之一：「记住窗口的大小、位置（相对页面宽高的比例）、锁定状态，
// 下次进小窗沿用；坏值回退默认」。本文件锁三件事：
//   1. 序列化往返：读写之后四个字段一个不差；
//   2. 坏值**逐字段**回退：一条里坏一个字段，不该把另外三个也丢回默认；
//   3. 持久化真的落在 shared_preferences 里（key `player:float_window`），
//      换实例（模拟重启）仍读得到；整份 JSON 坏 / 存储异常 → 默认，不抛。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/models/float_window_prefs.dart';
import 'package:bili_whitelist_app/services/float_window_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FloatWindowPrefs 默认值', () {
    test('默认：屏宽 40%、贴右贴顶、未锁定', () {
      const prefs = FloatWindowPrefs();
      expect(prefs.widthRatio, kFloatDefaultWidthRatio);
      expect(prefs.widthRatio, 0.40);
      expect(prefs.dxRatio, 1.0, reason: '默认贴右：右手拇指够得着');
      expect(prefs.dyRatio, 0.0, reason: '默认贴顶：不挡评论区首屏');
      expect(prefs.locked, isFalse);
    });

    test('copyWith 只改指定字段', () {
      const base = FloatWindowPrefs();
      final next = base.copyWith(widthRatio: 0.6, locked: true);
      expect(next.widthRatio, 0.6);
      expect(next.locked, isTrue);
      expect(next.dxRatio, base.dxRatio);
      expect(next.dyRatio, base.dyRatio);
      expect(base.widthRatio, 0.40, reason: '原实例不可变');
    });
  });

  group('序列化', () {
    test('toJson → fromJson 往返四个字段不差', () {
      const prefs =
          FloatWindowPrefs(widthRatio: 0.62, dxRatio: 0.25, dyRatio: 0.8, locked: true);
      final back = FloatWindowPrefs.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())),
      );
      expect(back, prefs);
    });

    test('不是 Map / null → 默认', () {
      expect(FloatWindowPrefs.fromJson(null), const FloatWindowPrefs());
      expect(FloatWindowPrefs.fromJson('oops'), const FloatWindowPrefs());
      expect(FloatWindowPrefs.fromJson(<Object>[]), const FloatWindowPrefs());
    });

    test('坏值逐字段回退：只坏 w，位置与锁定仍然生效', () {
      final prefs = FloatWindowPrefs.fromJson({
        'w': 0.0, // 坏：宽度比为 0 会让窗口消失
        'x': 0.3,
        'y': 0.7,
        'locked': true,
      });
      expect(prefs.widthRatio, kFloatDefaultWidthRatio, reason: '只有宽度回退默认');
      expect(prefs.dxRatio, 0.3);
      expect(prefs.dyRatio, 0.7);
      expect(prefs.locked, isTrue);
    });

    test('越界 / 非数字 / NaN / Infinity 全部回退默认', () {
      // 0 对位置比是**合法值**（贴左 / 贴顶），只有宽度比为 0 才是坏值（窗口
      // 会消失），所以位置比这一轮不测 0。
      for (final bad in <Object?>[
        1.5,
        -0.2,
        '0.5',
        null,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final prefs = FloatWindowPrefs.fromJson({'w': bad, 'x': bad, 'y': bad});
        expect(prefs.widthRatio, kFloatDefaultWidthRatio, reason: 'w=$bad');
        expect(prefs.dxRatio, kFloatDefaultDxRatio, reason: 'x=$bad');
        expect(prefs.dyRatio, kFloatDefaultDyRatio, reason: 'y=$bad');
      }
      // 宽度比 0 → 回退（低于 kFloatMinWidthRatio）；位置比 0 → 照用
      final zero = FloatWindowPrefs.fromJson({'w': 0.0, 'x': 0.0, 'y': 0.0});
      expect(zero.widthRatio, kFloatDefaultWidthRatio);
      expect(zero.dxRatio, 0.0, reason: '贴左是合法位置');
      expect(zero.dyRatio, 0.0, reason: '贴顶是合法位置');
    });

    test('locked 只认明确的 true（1 / "true" / 缺失都按未锁定）', () {
      for (final bad in <Object?>[1, 'true', null, 0, 'yes']) {
        expect(FloatWindowPrefs.fromJson({'locked': bad}).locked, isFalse,
            reason: 'locked=$bad');
      }
      expect(FloatWindowPrefs.fromJson({'locked': true}).locked, isTrue);
    });
  });

  group('FloatWindowStore 持久化', () {
    test('写入后读得回（key = player:float_window）', () async {
      const prefs =
          FloatWindowPrefs(widthRatio: 0.55, dxRatio: 0.1, dyRatio: 0.9, locked: true);
      await FloatWindowStore.instance.save(prefs);
      expect(await FloatWindowStore.instance.get(), prefs);

      final raw =
          (await SharedPreferences.getInstance()).getString('player:float_window');
      expect(raw, isNotNull, reason: '落在 shared_preferences 里，不是内存');
      expect((jsonDecode(raw!) as Map)['locked'], isTrue);
    });

    test('无记录 → 默认窗口', () async {
      expect(await FloatWindowStore.instance.get(), const FloatWindowPrefs());
    });

    test('整份 JSON 坏 → 默认，不抛', () async {
      SharedPreferences.setMockInitialValues(
        {'player:float_window': '{not json'},
      );
      expect(await FloatWindowStore.instance.get(), const FloatWindowPrefs());
    });

    test('存的是数组而不是对象 → 默认，不抛', () async {
      SharedPreferences.setMockInitialValues(
        {'player:float_window': '[1,2,3]'},
      );
      expect(await FloatWindowStore.instance.get(), const FloatWindowPrefs());
    });
  });
}
