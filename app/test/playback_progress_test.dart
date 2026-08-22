// PlaybackProgress 单元测试：保存/读取/清除/多视频隔离/JSON 持久化。
// - 用 SharedPreferences.setMockInitialValues 注入内存存储，不碰原生插件
// - 「重新 load」模拟 App 重启后读取同一底层存储
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/cache/playback_progress.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('无记忆时 getProgress 返回 null', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaybackProgress.load();

    expect(store.getProgress('BV1a', 0), isNull);
  });

  test('保存/读取：save 后 get 返回相同毫秒数', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaybackProgress.load();

    await store.saveProgress('BV1a', 0, 123456);

    expect(store.getProgress('BV1a', 0), 123456);
  });

  test('覆盖保存：同 key 二次 save 以最新为准', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaybackProgress.load();

    await store.saveProgress('BV1a', 0, 1000);
    await store.saveProgress('BV1a', 0, 2000);

    expect(store.getProgress('BV1a', 0), 2000);
  });

  test('清除：clear 后 get 返回 null', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaybackProgress.load();
    await store.saveProgress('BV1a', 0, 1000);

    await store.clearProgress('BV1a', 0);

    expect(store.getProgress('BV1a', 0), isNull);
  });

  test('多视频隔离：不同 bvid / 不同 pageIndex 互不影响', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaybackProgress.load();

    await store.saveProgress('BV1a', 0, 1000);
    await store.saveProgress('BV1a', 1, 2000);
    await store.saveProgress('BV1b', 0, 3000);

    // 各自独立读取
    expect(store.getProgress('BV1a', 0), 1000);
    expect(store.getProgress('BV1a', 1), 2000);
    expect(store.getProgress('BV1b', 0), 3000);

    // 清除 BV1a 第 1 集，不影响其余
    await store.clearProgress('BV1a', 1);
    expect(store.getProgress('BV1a', 1), isNull);
    expect(store.getProgress('BV1a', 0), 1000);
    expect(store.getProgress('BV1b', 0), 3000);
  });

  test('JSON 持久化：重新 load（模拟重启）后进度仍在，且底层为 JSON', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await PlaybackProgress.load();
    await store.saveProgress('BV1a', 0, 99999);

    // 重新 load 同一底层存储（模拟 App 重启）
    final store2 = await PlaybackProgress.load();
    expect(store2.getProgress('BV1a', 0), 99999);

    // 底层存的就是 JSON 字符串
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('playback_progress:BV1a_0');
    expect(raw, isNotNull);
    expect(raw, contains('positionMs'));
    expect(raw, contains('99999'));
  });

  test('数据损坏视为无记忆（不崩溃）', () async {
    SharedPreferences.setMockInitialValues({
      'playback_progress:BV1a_0': 'not-json{{',
    });
    final store = await PlaybackProgress.load();

    expect(store.getProgress('BV1a', 0), isNull);
  });
}
