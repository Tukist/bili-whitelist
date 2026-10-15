// 「自动来源」接进既有差值算法（v2.54.0）。
//
// 用户要求：把掌厅自动读到的「通用流量已用」作为**自动来源**喂给既有的差值算法
// （两个快照相减 + 与本 App 移动流量相减 = 疑似免流），并且**保留手动录入兜底**，
// 界面上要能看出这次数字是自动读到的还是手填的。
//
// 这一层测存储与算法：来源字段的落盘/兼容、自动快照的防抖、混着手动快照也能算、
// 以及**读不到时不拿 0 冒充**。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/traffic_snapshot_store.dart';

CarrierSnapshot _snap({
  required DateTime at,
  required double gb,
  int appBytes = -1,
  SnapshotSource source = SnapshotSource.manual,
}) =>
    CarrierSnapshot(
      at: at,
      carrierGb: gb,
      appMobileBytes: appBytes,
      source: source,
    );

void main() {
  group('① 来源字段：默认手动、落盘、老数据兼容', () {
    test('不传 source → 手动（v2.53.0 的调用点都不用改）', () {
      final s = CarrierSnapshot(at: DateTime(2026, 10, 14), carrierGb: 10);
      expect(s.source, SnapshotSource.manual);
      expect(s.isAuto, isFalse);
    });

    test('自动来源能落盘、读回来还是自动', () {
      final list = [
        _snap(at: DateTime(2026, 10, 14, 10), gb: 10.00, appBytes: 100),
        _snap(
          at: DateTime(2026, 10, 14, 11),
          gb: 10.35,
          appBytes: 500,
          source: SnapshotSource.cmcc,
        ),
      ];
      final round = TrafficSnapshotStore.decodeSnapshots(
          TrafficSnapshotStore.encodeSnapshots(list));
      expect(round.length, 2);
      expect(round[0].source, SnapshotSource.manual);
      expect(round[1].source, SnapshotSource.cmcc);
      expect(round[1].isAuto, isTrue);
      expect(round[1].carrierGb, 10.35);
      expect(round[1].appMobileBytes, 500);
    });

    test('老数据没有 src 字段 → 按手动算（v2.54.0 之前全是手填的）', () {
      final legacy = TrafficSnapshotStore.decodeSnapshots(
          '[{"at":1893456000000,"carrierGb":3.5,"appBytes":7}]');
      expect(legacy.single.source, SnapshotSource.manual);
      expect(legacy.single.isAuto, isFalse);
    });

    test('src 写错 / 不认识 → 退回手动（不猜成自动）', () {
      final bad = TrafficSnapshotStore.decodeSnapshots(
          '[{"at":1893456000000,"carrierGb":3.5,"src":"whatever"}]');
      expect(bad.single.source, SnapshotSource.manual);
    });

    test('toString 里带来源（排查日志时一眼看出这条是谁记的）', () {
      final s = _snap(
        at: DateTime(2026, 10, 14),
        gb: 1,
        source: SnapshotSource.cmcc,
      );
      expect(s.toString(), contains('cmcc'));
    });
  });

  group('② 自动快照防抖：不许把用户的手动快照挤出名额', () {
    final now = DateTime(2026, 10, 14, 12);

    test('没有历史 / 上一条是手填 → 该记', () {
      expect(mayRecordAutoSnapshot(latest: null, now: now), isTrue);
      expect(
        mayRecordAutoSnapshot(
          latest: _snap(at: now.subtract(const Duration(seconds: 5)), gb: 1),
          now: now,
        ),
        isTrue,
        reason: '手动快照不参与防抖（用户点了就是要记）',
      );
    });

    test('上一条是刚记的自动快照 → 不记（连点两下刷新不该堆两条）', () {
      expect(
        mayRecordAutoSnapshot(
          latest: _snap(
            at: now.subtract(const Duration(minutes: 1)),
            gb: 1,
            source: SnapshotSource.cmcc,
          ),
          now: now,
        ),
        isFalse,
      );
      expect(
        mayRecordAutoSnapshot(
          latest: _snap(
            at: now.subtract(const Duration(minutes: 5)),
            gb: 1,
            source: SnapshotSource.cmcc,
          ),
          now: now,
        ),
        isTrue,
        reason: '间隔够了就正常记',
      );
    });

    test('时钟偏差（上一条时间在未来）也不重复记', () {
      expect(
        mayRecordAutoSnapshot(
          latest: _snap(
            at: now.add(const Duration(minutes: 2)),
            gb: 1,
            source: SnapshotSource.cmcc,
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('阈值默认 5 分钟（与"绝不短于 5 分钟轮询"同一档）', () {
      expect(kAutoSnapshotMinGap, const Duration(minutes: 5));
    });
  });

  group('③ 自动来源进差值算法（含手填的混着算）', () {
    test('手填 + 自动 → 照常算出疑似免流', () {
      final manual = _snap(
        at: DateTime(2026, 10, 14, 10),
        gb: 10.00,
        appBytes: 104857600, // 100 MB
      );
      final auto = _snap(
        at: DateTime(2026, 10, 14, 10, 10),
        gb: 10.35,
        appBytes: 104857600 + 419430400, // +400 MB
        source: SnapshotSource.cmcc,
      );
      final d = diffSnapshots(manual, auto);
      expect(d.carrierDeltaGb, closeTo(0.35, 1e-9));
      expect(d.appDeltaBytes, 419430400);
      expect(d.suspectFreeGb!, closeTo(0.040625, 1e-9));
      expect(d.plausible, isTrue);
      expect(d.newer.isAuto, isTrue, reason: '界面据此标"自动读到"');
      expect(d.older.isAuto, isFalse);
      expect(d.span, const Duration(minutes: 10));
    });

    test('两条都是自动 → 一样算（全是自动来源也能用）', () {
      final a = _snap(
        at: DateTime(2026, 10, 14, 10),
        gb: 1.00,
        appBytes: 104857600,
        source: SnapshotSource.cmcc,
      );
      final b = _snap(
        at: DateTime(2026, 10, 14, 11),
        gb: 1.20,
        appBytes: 104857600 * 2,
        source: SnapshotSource.cmcc,
      );
      final d = diffSnapshots(a, b);
      expect(d.carrierDeltaGb, closeTo(0.2, 1e-9));
      expect(d.appDeltaBytes, 104857600);
      expect(d.plausible, isTrue);
    });

    test('自动那条读不到系统口径（appBytes = -1）→ 如实算不出，不拿 0 冒充', () {
      final manual = _snap(
        at: DateTime(2026, 10, 14, 10),
        gb: 10.00,
        appBytes: 104857600,
      );
      final auto = _snap(
        at: DateTime(2026, 10, 14, 11),
        gb: 10.35,
        appBytes: -1, // 没开「使用情况访问」时就是这个值
        source: SnapshotSource.cmcc,
      );
      expect(auto.hasAppReading, isFalse);
      final d = diffSnapshots(manual, auto);
      expect(d.appDeltaBytes, isNull, reason: '读不到就是 null，不是 0');
      expect(d.suspectFreeGb, isNull);
      expect(d.plausible, isFalse);
    });

    test('自动读数本身是 0（新月还没用）→ 照实为 0，不与"读不到"混为一谈', () {
      final a = _snap(
        at: DateTime(2026, 10, 14, 10),
        gb: 0.0,
        appBytes: 1000,
        source: SnapshotSource.cmcc,
      );
      final b = _snap(
        at: DateTime(2026, 10, 14, 11),
        gb: 0.05,
        appBytes: 1000 + 104857600,
        source: SnapshotSource.cmcc,
      );
      final d = diffSnapshots(a, b);
      expect(d.carrierDeltaGb, closeTo(0.05, 1e-9));
      // 100 MB = 0.09765625 GB；疑似免流 = 0.09765625 − 0.05
      expect(d.suspectFreeGb!, closeTo(0.04765625, 1e-9));
    });
  });

  group('④ 落盘顺序与名额（自动快照不能改变既有行为）', () {
    test('混着记满 8 条：只丢最旧的，顺序不变', () {
      final list = [
        for (var i = 0; i < 9; i++)
          _snap(
            at: DateTime(2026, 10, 14, i),
            gb: i.toDouble(),
            source: i.isEven ? SnapshotSource.cmcc : SnapshotSource.manual,
          ),
      ];
      final encoded = TrafficSnapshotStore.encodeSnapshots(list);
      final decoded = TrafficSnapshotStore.decodeSnapshots(encoded);
      expect(decoded.length, 9, reason: '编解码本身不裁条数（裁剪在 add 里做）');
      expect(decoded.first.carrierGb, 0);
      expect(decoded.last.carrierGb, 8);
      expect(TrafficSnapshotStore.maxSnapshots, 8);
    });
  });
}
