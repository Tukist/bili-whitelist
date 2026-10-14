// 「最近一次取流」存储（v2.53.0，个人页「取流状态」的数据源）测试。
//
// 这一半是"运行时才知道的事实"：接口来源 / 清晰度 / 带没带登录 Cookie / 时刻。
// 用户要的是"一眼看出现在走的是哪条路"，所以这份记录必须**落盘**（重启后仍能
// 看到上次结果），并且读盘失败要按"没有记录"降级（不崩、不影响启动）。
//
// 覆盖：
//   1. 枚举与存储字符串的映射（含不认识的值 → 没有记录）；
//   2. record → 内存立即生效 + 落盘；冷启动能读回；
//   3. 读盘异常/缺字段 → 当作没有记录（[StreamStatusStore.hasRecord] 为假）；
//   4. resetForTest 清干净（单例跨用例不串味）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/stream_status_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    StreamStatusStore.instance.resetForTest();
  });

  tearDown(() => StreamStatusStore.instance.resetForTest());

  group('① StreamSource 与存储字符串', () {
    test('storageValue 稳定（改枚举名不该让旧记录读不出来）', () {
      expect(StreamSource.web.storageValue, 'web');
      expect(StreamSource.app.storageValue, 'app');
    });

    test('fromStorage：认识的两个值 + 其余（含 null / 乱码）一律 null', () {
      expect(StreamSource.fromStorage('web'), StreamSource.web);
      expect(StreamSource.fromStorage('app'), StreamSource.app);
      expect(StreamSource.fromStorage(null), isNull);
      expect(StreamSource.fromStorage(''), isNull);
      expect(StreamSource.fromStorage('APP'), isNull, reason: '大小写敏感：不猜');
      expect(StreamSource.fromStorage('别的值'), isNull);
    });
  });

  group('② record：立即生效 + 落盘 + 冷启动读回', () {
    test('record 后内存立刻是新的，且四个 key 都写进 prefs', () async {
      final at = DateTime(2026, 10, 14, 18, 30);
      await StreamStatusStore.instance.record(
        source: StreamSource.app,
        quality: 32,
        hadLoginCookie: true,
        at: at,
      );
      final s = StreamStatusStore.instance;
      expect(s.source, StreamSource.app);
      expect(s.quality, 32);
      expect(s.hadLoginCookie, isTrue);
      expect(s.at, at);
      expect(s.hasRecord, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StreamStatusStore.sourceKey), 'app');
      expect(prefs.getInt(StreamStatusStore.qualityKey), 32);
      expect(prefs.getBool(StreamStatusStore.cookieKey), isTrue);
      expect(prefs.getInt(StreamStatusStore.atKey), at.millisecondsSinceEpoch);
    });

    test('record 会发通知（个人页那行说明要跟着变）', () async {
      var notified = 0;
      void listener() => notified++;
      StreamStatusStore.instance.addListener(listener);
      addTearDown(() => StreamStatusStore.instance.removeListener(listener));
      await StreamStatusStore.instance.record(
        source: StreamSource.web,
        quality: 80,
        hadLoginCookie: false,
      );
      expect(notified, 1);
    });

    test('冷启动（load=false → ensureLoaded）读回上次结果', () async {
      await StreamStatusStore.instance.record(
        source: StreamSource.web,
        quality: 80,
        hadLoginCookie: true,
        at: DateTime(2026, 10, 14, 9, 5),
      );
      // 模拟重启：内存清空、盘上还在
      StreamStatusStore.instance.resetForTest(loaded: false);
      expect(StreamStatusStore.instance.hasRecord, isFalse,
          reason: '重置后是"没有记录"（证明下面读到的是盘上的）');

      await StreamStatusStore.instance.ensureLoaded();
      final s = StreamStatusStore.instance;
      expect(s.source, StreamSource.web);
      expect(s.quality, 80);
      expect(s.hadLoginCookie, isTrue);
      expect(s.at, DateTime(2026, 10, 14, 9, 5));
    });

    test('ensureLoaded 幂等：重复调用不再读盘（不会把内存里的新值冲掉）', () async {
      StreamStatusStore.instance.resetForTest(loaded: true);
      await StreamStatusStore.instance.record(
        source: StreamSource.app,
        quality: 64,
        hadLoginCookie: false,
      );
      await StreamStatusStore.instance.ensureLoaded();
      expect(StreamStatusStore.instance.source, StreamSource.app);
      expect(StreamStatusStore.instance.quality, 64);
    });
  });

  group('③ 盘上数据不完整/坏掉：当作"没有记录"，不抛', () {
    test('只写了来源没写时刻 → hasRecord 为假', () async {
      SharedPreferences.setMockInitialValues({
        StreamStatusStore.sourceKey: 'app',
        StreamStatusStore.qualityKey: 32,
      });
      await StreamStatusStore.instance.ensureLoaded();
      expect(StreamStatusStore.instance.hasRecord, isFalse);
      expect(StreamStatusStore.instance.source, StreamSource.app,
          reason: '残缺数据也照读，只是 hasRecord 判不出来');
    });

    test('时刻为 0 / 负 → 当作没有时刻', () async {
      SharedPreferences.setMockInitialValues({
        StreamStatusStore.sourceKey: 'web',
        StreamStatusStore.atKey: 0,
      });
      await StreamStatusStore.instance.ensureLoaded();
      expect(StreamStatusStore.instance.at, isNull);
      expect(StreamStatusStore.instance.hasRecord, isFalse);
    });

    test('来源是乱七八糟的字符串 → 当作没有来源', () async {
      SharedPreferences.setMockInitialValues({
        StreamStatusStore.sourceKey: 'pc',
        StreamStatusStore.atKey: 1893456000000,
      });
      await StreamStatusStore.instance.ensureLoaded();
      expect(StreamStatusStore.instance.source, isNull);
      expect(StreamStatusStore.instance.hasRecord, isFalse);
    });

    test('空盘 → 默认值（没有记录、清晰度 0、未带 cookie）', () async {
      await StreamStatusStore.instance.ensureLoaded();
      final s = StreamStatusStore.instance;
      expect(s.hasRecord, isFalse);
      expect(s.quality, 0);
      expect(s.hadLoginCookie, isFalse);
      expect(s.at, isNull);
    });
  });
}
