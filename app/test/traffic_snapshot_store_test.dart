// 运营商口径快照存储 + 差值算法（v2.53.0）测试。
//
// 这一半是"只能手动录入"的替代方案：运营商侧的通用流量用量/免流额度没有任何
// 公开接口可读（三大运营商都是封闭的自家 App 接口），所以流程是
// 「看视频前后各抄一次运营商 App 的数 → 两条快照相减 → 与 App 移动流量增量相减
// 得到**疑似**免流量」。相减这件事必须**算得对**，且"算不出"要如实表达
// （不许拿 0 冒充）。
//
// 覆盖：
//   1. 输入解析容错（`12.34` / `12.34GB` / 全角 / 千分位 / 空值 / 非法）；
//   2. diffSnapshots：正常、缺系统读数、系统读数倒退、运营商数值倒退；
//   3. 存储：追加、上限裁剪、删除最新一条、清空、落盘往返、坏 JSON 跳过；
//   4. 展示格式化（GB 两位小数、带符号、时长）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/traffic_snapshot_store.dart';

CarrierSnapshot _snap({
  required DateTime at,
  required double gb,
  int appBytes = -1,
}) =>
    CarrierSnapshot(at: at, carrierGb: gb, appMobileBytes: appBytes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TrafficSnapshotStore.instance.resetForTest();
  });

  tearDown(() => TrafficSnapshotStore.instance.resetForTest());

  group('① 输入解析容错（用户是从运营商 App 手抄数字）', () {
    test('裸数字与常见单位写法都能认', () {
      expect(tryParseCarrierGb('12.34'), 12.34);
      expect(tryParseCarrierGb('12.34GB'), 12.34);
      expect(tryParseCarrierGb('12.34 gb'), 12.34);
      expect(tryParseCarrierGb('12.34G'), 12.34);
      expect(tryParseCarrierGb(' 12.34  '), 12.34);
      expect(tryParseCarrierGb('1234'), 1234.0);
      expect(tryParseCarrierGb('0'), 0.0);
    });

    test('全角字符与千分位', () {
      expect(tryParseCarrierGb('１２．３４'), 12.34);
      expect(tryParseCarrierGb('1,234.5'), 1234.5);
      expect(tryParseCarrierGb('1,234GB'), 1234.0);
      // 只有逗号没有点号：按小数点处理（12,34 = 12.34）
      expect(tryParseCarrierGb('12,34'), 12.34);
    });

    test('空值 / 非法 / 明显打错 → null（界面给友好提示，不记垃圾快照）', () {
      expect(tryParseCarrierGb(''), isNull);
      expect(tryParseCarrierGb('   '), isNull);
      expect(tryParseCarrierGb('abc'), isNull);
      expect(tryParseCarrierGb('GB'), isNull);
      expect(tryParseCarrierGb('-1'), isNull);
      expect(tryParseCarrierGb('12.34TB'), isNull, reason: '不认的尾巴不能当数字解析成功');
      expect(tryParseCarrierGb('99999999'), isNull, reason: '超大数明显是打错了');
      expect(tryParseCarrierGb('NaN'), isNull);
      expect(tryParseCarrierGb('Infinity'), isNull);
    });
  });

  group('② 相减：增量与"疑似免流"', () {
    final t0 = DateTime(2026, 10, 14, 12, 0);
    final t1 = DateTime(2026, 10, 14, 12, 10);

    test('正常一例：本 App 涨 400MB、运营商通用只涨 0.35GB → 差值 ≈ 0.04GB', () {
      final older = _snap(at: t0, gb: 10.00, appBytes: 104857600); // 100 MB
      final newer = _snap(at: t1, gb: 10.35, appBytes: 524288000); // 500 MB
      final d = diffSnapshots(older, newer);
      expect(d.carrierDeltaGb, closeTo(0.35, 1e-9));
      expect(d.appDeltaBytes, 419430400); // 400 MB
      expect(d.suspectFreeGb, isNotNull);
      expect(d.suspectFreeGb!, closeTo(0.040625, 1e-9));
      expect(d.plausible, isTrue);
      expect(d.span, const Duration(minutes: 10));
    });

    test('运营商涨得比本 App 用得多（别的 App 也在用）→ 差值为负，仍如实给出', () {
      final older = _snap(at: t0, gb: 10.00, appBytes: 0);
      final newer = _snap(at: t1, gb: 10.50, appBytes: 104857600); // 只用了 100MB
      final d = diffSnapshots(older, newer);
      expect(d.appDeltaBytes, 104857600);
      expect(d.suspectFreeGb!, lessThan(0));
    });

    test('系统读数缺一次 → appDelta/suspect 都是 null（不许拿 0 冒充）', () {
      final older = _snap(at: t0, gb: 10.00); // appBytes 缺省 -1
      final newer = _snap(at: t1, gb: 10.35, appBytes: 524288000);
      final d = diffSnapshots(older, newer);
      expect(d.appDeltaBytes, isNull);
      expect(d.suspectFreeGb, isNull);
      expect(d.plausible, isFalse, reason: '算不出就说算不出，界面显示"算不出"');
    });

    test('系统读数倒退（换月/统计被清）→ 也算不出', () {
      final older = _snap(at: t0, gb: 10.00, appBytes: 524288000);
      final newer = _snap(at: t1, gb: 10.35, appBytes: 104857600);
      final d = diffSnapshots(older, newer);
      expect(d.appDeltaBytes, isNull);
      expect(d.plausible, isFalse);
    });

    test('运营商数值倒退（换月重置 / 抄错）→ 差值照算但标不可信', () {
      final older = _snap(at: t0, gb: 10.00, appBytes: 104857600);
      final newer = _snap(at: t1, gb: 1.00, appBytes: 524288000);
      final d = diffSnapshots(older, newer);
      expect(d.carrierDeltaGb, lessThan(0));
      expect(d.plausible, isFalse);
    });

    test('传反了（新的在前）→ 内部按时间排序，不报错也不出负数时长', () {
      final d = diffSnapshots(
        _snap(at: t1, gb: 10.35, appBytes: 524288000),
        _snap(at: t0, gb: 10.00, appBytes: 104857600),
      );
      expect(d.older.at, t0);
      expect(d.newer.at, t1);
      expect(d.carrierDeltaGb, closeTo(0.35, 1e-9));
      expect(d.span, const Duration(minutes: 10));
    });
  });

  group('③ 存储：落盘往返、上限、删除', () {
    test('add 追加（旧→新）并落盘；冷启动读回', () async {
      final t0 = DateTime(2026, 10, 14, 12, 0);
      await TrafficSnapshotStore.instance
          .add(_snap(at: t0, gb: 10.00, appBytes: 100));
      await TrafficSnapshotStore.instance
          .add(_snap(at: t0.add(const Duration(minutes: 5)), gb: 10.35, appBytes: 200));
      expect(TrafficSnapshotStore.instance.snapshots.length, 2);
      expect(TrafficSnapshotStore.instance.latest!.carrierGb, 10.35);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TrafficSnapshotStore.snapshotsKey), isNotNull);

      // 模拟重启
      TrafficSnapshotStore.instance.resetForTest(loaded: false);
      await TrafficSnapshotStore.instance.ensureLoaded();
      expect(TrafficSnapshotStore.instance.snapshots.length, 2);
      expect(TrafficSnapshotStore.instance.snapshots.first.carrierGb, 10.00);
      expect(TrafficSnapshotStore.instance.snapshots.last.appMobileBytes, 200);
    });

    test('add 会发通知（快照卡片要立刻出现）', () async {
      var notified = 0;
      void listener() => notified++;
      TrafficSnapshotStore.instance.addListener(listener);
      addTearDown(() => TrafficSnapshotStore.instance.removeListener(listener));
      await TrafficSnapshotStore.instance
          .add(_snap(at: DateTime(2026, 10, 14), gb: 1));
      expect(notified, 1);
    });

    test('超过上限丢最旧的（只留最近 maxSnapshots 条）', () async {
      for (var i = 0; i < TrafficSnapshotStore.maxSnapshots + 3; i++) {
        await TrafficSnapshotStore.instance.add(_snap(
            at: DateTime(2026, 10, 1).add(Duration(hours: i)), gb: i.toDouble()));
      }
      final list = TrafficSnapshotStore.instance.snapshots;
      expect(list.length, TrafficSnapshotStore.maxSnapshots);
      expect(list.first.carrierGb, 3.0, reason: '最旧的 0/1/2 被丢掉了');
      expect(list.last.carrierGb,
          (TrafficSnapshotStore.maxSnapshots + 2).toDouble());
    });

    test('removeLatest（"删掉最新一条"）与 clear', () async {
      await TrafficSnapshotStore.instance
          .add(_snap(at: DateTime(2026, 10, 14, 12), gb: 10));
      await TrafficSnapshotStore.instance
          .add(_snap(at: DateTime(2026, 10, 14, 13), gb: 11));
      await TrafficSnapshotStore.instance.removeLatest();
      expect(TrafficSnapshotStore.instance.snapshots.length, 1);
      expect(TrafficSnapshotStore.instance.latest!.carrierGb, 10);

      await TrafficSnapshotStore.instance.clear();
      expect(TrafficSnapshotStore.instance.snapshots, isEmpty);
      expect(TrafficSnapshotStore.instance.latest, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(TrafficSnapshotStore.snapshotsKey), isNull,
          reason: '清空要把 key 一起删掉，不留空数组');
    });

    test('空表上 removeLatest 是空操作（不抛）', () async {
      await TrafficSnapshotStore.instance.removeLatest();
      expect(TrafficSnapshotStore.instance.snapshots, isEmpty);
    });

    test('坏数据：整体不是数组 / 条目缺字段 / 类型错 → 跳掉，不抛', () async {
      expect(TrafficSnapshotStore.decodeSnapshots(null), isEmpty);
      expect(TrafficSnapshotStore.decodeSnapshots(''), isEmpty);
      expect(TrafficSnapshotStore.decodeSnapshots('不是 json'), isEmpty);
      expect(TrafficSnapshotStore.decodeSnapshots('{"a":1}'), isEmpty);
      final decoded = TrafficSnapshotStore.decodeSnapshots(
          '[{"at":"x","carrierGb":1},{"carrierGb":2},'
          '{"at":1893456000000,"carrierGb":3.5,"appBytes":7},{"at":1}]');
      expect(decoded.length, 1, reason: '只有第 3 条结构完整');
      expect(decoded.single.carrierGb, 3.5);
      expect(decoded.single.appMobileBytes, 7);
    });

    test('编码/解码往返一致（旧 → 新顺序不变）', () {
      final list = [
        _snap(at: DateTime(2026, 10, 14, 12), gb: 10.00, appBytes: 100),
        _snap(at: DateTime(2026, 10, 14, 13), gb: 10.35),
      ];
      final round = TrafficSnapshotStore.decodeSnapshots(
          TrafficSnapshotStore.encodeSnapshots(list));
      expect(round.length, 2);
      expect(round.first.carrierGb, 10.00);
      expect(round.first.appMobileBytes, 100);
      expect(round.last.hasAppReading, isFalse);
    });
  });
}
