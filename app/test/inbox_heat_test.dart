// 信箱「热度榜」打分 / 排序 / 偏好存储的单元测试（v2.64.0+）。
//
// 钉住的都是**可观察的数值与顺序**（不靠 UI 间接推断）：
// - 打分：播放量单调、时间单调、缺字段退化、0 值、极端值、0~100 归一化；
// - 排序：默认热度降序、无数据排后且保持原序、最新模式、稳定同分、
//   插入比较器在"无数据"时退回发布时间（既有语义）；
// - 名次：队首 #1、无数据排在后面；
// - 序列化：InboxItem.view 只非空才写、旧数据缺字段 = null、负数 = null；
// - InboxSortStore：默认热度、切换落盘、重启读回、坏值回退。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/inbox_heat.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/inbox_sort_store.dart';

const int _now = 1700000000; // 固定"现在"（Unix 秒），分数完全可复现

/// 发布时间是 [hours] 小时前的条目。
InboxItem _item(
  String bvid, {
  int? view,
  double hours = 2,
  int upMid = 100,
}) =>
    InboxItem(
      upMid: upMid,
      upName: 'UP$upMid',
      upFace: '',
      bvid: bvid,
      title: '视频 $bvid',
      cover: '',
      duration: 60,
      pubDate: _now - (hours * 3600).round(),
      view: view,
    );

double _score(InboxItem it) => inboxHeatScore(
      view: it.view,
      pubDate: it.pubDate,
      nowSec: _now,
    )!;

int _display(InboxItem it) => inboxHeatDisplay(it, nowSec: _now)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InboxSortStore.instance.resetForTest();
  });
  tearDown(() => InboxSortStore.instance.resetForTest());

  // =========================================================================
  // 打分
  // =========================================================================
  group('inboxHeatScore：播放量单调', () {
    test('同发布时间：播放量高 → 分高（严格递增）', () {
      final low = _score(_item('BV1', view: 100));
      final mid = _score(_item('BV2', view: 10000));
      final high = _score(_item('BV3', view: 500000));
      expect(low, lessThan(mid));
      expect(mid, lessThan(high));
      // 都是真实可读的分（不是 0 / 不是 100）
      expect(low, greaterThan(0));
      expect(high, lessThan(100));
    });

    test('同播放量：越新分越高（时间衰减）', () {
      final fresh = _score(_item('BV1', view: 200000, hours: 1));
      final day = _score(_item('BV2', view: 200000, hours: 24));
      final week = _score(_item('BV3', view: 200000, hours: 168));
      expect(fresh, greaterThan(day));
      expect(day, greaterThan(week));
    });

    test('衰减能让"新视频"压过"一天前的爆款"（榜要换血）', () {
      final freshSmall = _score(_item('BV1', view: 120000, hours: 3));
      final dayBig = _score(_item('BV2', view: 800000, hours: 24));
      expect(freshSmall, greaterThan(dayBig),
          reason: '3 小时前 12 万播放 > 1 天前 80 万播放 —— 否则榜永远是大 UP 的旧视频');
    });
  });

  group('inboxHeatScore：缺字段 / 0 值 / 退化', () {
    test('view == null → null（未知，不是 0 分）', () {
      expect(
        inboxHeatScore(view: null, pubDate: _now - 7200, nowSec: _now),
        isNull,
      );
    });

    test('view == 0 → 0 分（真·零播放，是合法值不是"未知"）', () {
      expect(
        inboxHeatScore(view: 0, pubDate: _now - 7200, nowSec: _now),
        0.0,
      );
    });

    test('负数播放量按 0 处理（不出现负分 / NaN）', () {
      final s = inboxHeatScore(view: -99, pubDate: _now - 7200, nowSec: _now)!;
      expect(s, 0.0);
    });

    test('弹幕 / 评论传 null → 与"只用播放量"逐位相同（本批真实路径）', () {
      final onlyView = inboxHeatScore(
        view: 12345,
        pubDate: _now - 7200,
        nowSec: _now,
      );
      final withNulls = inboxHeatScore(
        view: 12345,
        danmaku: null,
        comment: null,
        pubDate: _now - 7200,
        nowSec: _now,
      );
      expect(withNulls, onlyView);
    });

    test('拿到互动数据时加权（弹幕 / 评论都能加分）', () {
      final onlyView = inboxHeatScore(
        view: 10000,
        pubDate: _now - 7200,
        nowSec: _now,
      )!;
      final withDanmaku = inboxHeatScore(
        view: 10000,
        danmaku: 100,
        pubDate: _now - 7200,
        nowSec: _now,
      )!;
      final withComment = inboxHeatScore(
        view: 10000,
        comment: 100,
        pubDate: _now - 7200,
        nowSec: _now,
      )!;
      expect(withDanmaku, greaterThan(onlyView));
      expect(withComment, greaterThan(withDanmaku),
          reason: '评论权重（50）高于弹幕（20）');
    });

    test('只有互动、没有播放量 → 仍然算得出分（不是 null）', () {
      final s = inboxHeatScore(
        view: null,
        danmaku: 100,
        pubDate: _now - 7200,
        nowSec: _now,
      );
      expect(s, isNotNull);
      expect(s!, greaterThan(0));
    });

    test('pubDate 未知（0）→ 不衰减：与"刚刚发布"同分', () {
      final unknown = inboxHeatScore(view: 1000000, pubDate: 0, nowSec: _now)!;
      final justNow = inboxHeatScore(
        view: 1000000,
        pubDate: _now,
        nowSec: _now,
      )!;
      expect(unknown, justNow);
    });

    test('发布时间在"未来"（时钟偏差）→ 按刚发布处理，不放大', () {
      final future = inboxHeatScore(
        view: 1000000,
        pubDate: _now + 86400,
        nowSec: _now,
      )!;
      final justNow = inboxHeatScore(
        view: 1000000,
        pubDate: _now,
        nowSec: _now,
      )!;
      expect(future, justNow);
    });
  });

  group('inboxHeatScore：极端值与归一化', () {
    test('超大播放量不溢出 / 不 NaN，封顶 100', () {
      for (final v in [1 << 40, 1 << 62, 1000000000000000000]) {
        final s = inboxHeatScore(view: v, pubDate: _now - 7200, nowSec: _now);
        expect(s, isNotNull);
        expect(s!.isNaN, isFalse, reason: 'view=$v 不能算出 NaN');
        expect(s.isInfinite, isFalse, reason: 'view=$v 不能算出无穷');
        expect(s, 100.0, reason: 'view=$v 远超满分线 → 封顶 100');
      }
    });

    test('所有输入都落在 0~100（含边界与多种组合）', () {
      final cases = <double>[];
      for (final v in <int?>[null, 0, 1, 1000, 100000, 1000000, 999999999]) {
        for (final h in <double>[0, 0.5, 2, 24, 720, 100000]) {
          final s = inboxHeatScore(
            view: v,
            pubDate: _now - (h * 3600).round(),
            nowSec: _now,
          );
          if (s == null) continue;
          expect(s, greaterThanOrEqualTo(0.0));
          expect(s, lessThanOrEqualTo(100.0));
          cases.add(s);
        }
      }
      expect(cases, isNotEmpty);
    });

    test('展示分是四舍五入的整数（0~100），无数据才是 null', () {
      final it = _item('BV1', view: 1000000, hours: 2);
      expect(_display(it), 85, reason: '100 万播放 / 2 小时前 = 84.95 → 85');
      expect(inboxHeatDisplay(_item('BV2'), nowSec: _now), isNull);
      expect(inboxHeatDisplay(_item('BV3', view: 0), nowSec: _now), 0);
    });

    test('真实形态的三条样例（文档里的打分示例就是这三条）', () {
      // 大 UP：80 万播放、1 天前
      expect(_display(_item('BV1', view: 800000, hours: 24)), 63);
      // 小 UP：1.2 万播放、3 小时前
      expect(_display(_item('BV2', view: 12000, hours: 3)), 51);
      // 一周前的旧视频：5 万播放
      expect(_display(_item('BV3', view: 50000, hours: 168)), 23);
    });
  });

  // =========================================================================
  // 排序
  // =========================================================================
  group('inboxSortItems', () {
    test('热度模式：热度降序；无数据排在最后且保持原序', () {
      final a = _item('BVa', view: 1000);
      final b = _item('BVb', view: 100000);
      final c = _item('BVc', view: null);
      final d = _item('BVd', view: null);
      final sorted = inboxSortItems(
        [c, a, d, b],
        mode: InboxSortMode.heat,
        nowSec: _now,
      );
      expect([for (final it in sorted) it.bvid], ['BVb', 'BVa', 'BVc', 'BVd']);
    });

    test('热度模式：同分 / 都无数据 → 稳定（保持入参顺序）', () {
      final a1 = _item('BVa1', view: 5000, hours: 2);
      final a2 = _item('BVa2', view: 5000, hours: 2);
      final b1 = _item('BVb1', view: null);
      final b2 = _item('BVb2', view: null);
      final sorted = inboxSortItems(
        [a2, b2, a1, b1],
        mode: InboxSortMode.heat,
        nowSec: _now,
      );
      expect(
        [for (final it in sorted) it.bvid],
        ['BVa2', 'BVa1', 'BVb2', 'BVb1'],
      );
    });

    test('最新模式：按发布时间倒序，与播放量无关', () {
      final old = _item('BVold', view: 9999999, hours: 48);
      final mid = _item('BVmid', view: 1, hours: 5);
      final fresh = _item('BVnew', view: null, hours: 1);
      final sorted = inboxSortItems(
        [old, fresh, mid],
        mode: InboxSortMode.latest,
        nowSec: _now,
      );
      expect(
        [for (final it in sorted) it.bvid],
        ['BVnew', 'BVmid', 'BVold'],
      );
    });

    test('排序不改长度、不改条目集合（红点口径的前提）', () {
      final items = [
        _item('BV1', view: 10),
        _item('BV2'),
        _item('BV3', view: 100000),
      ];
      for (final mode in InboxSortMode.values) {
        final sorted =
            inboxSortItems(items, mode: mode, nowSec: _now);
        expect(sorted.length, items.length);
        expect(
          {for (final it in sorted) it.bvid},
          {for (final it in items) it.bvid},
        );
      }
      // 入参一字不改（纯函数）
      expect([for (final it in items) it.bvid], ['BV1', 'BV2', 'BV3']);
    });
  });

  group('inboxCompareForInsert（页面合并新条目用）', () {
    test('两边都有热度 → 分高的在前', () {
      final hot = _item('BVhot', view: 1000000);
      final cold = _item('BVcold', view: 100);
      expect(
        inboxCompareForInsert(hot, cold,
            mode: InboxSortMode.heat, nowSec: _now),
        lessThan(0),
      );
      expect(
        inboxCompareForInsert(cold, hot,
            mode: InboxSortMode.heat, nowSec: _now),
        greaterThan(0),
      );
    });

    test('一边有分一边无分 → 有分的一律在前', () {
      final scored = _item('BV1', view: 1);
      final unknown = _item('BV2');
      expect(
        inboxCompareForInsert(scored, unknown,
            mode: InboxSortMode.heat, nowSec: _now),
        lessThan(0),
      );
      expect(
        inboxCompareForInsert(unknown, scored,
            mode: InboxSortMode.heat, nowSec: _now),
        greaterThan(0),
      );
    });

    test('两边都无分 → 退回发布时间倒序（v2.64.0 之前的既有语义）', () {
      final fresh = _item('BVnew', hours: 1);
      final old = _item('BVold', hours: 10);
      expect(
        inboxCompareForInsert(fresh, old,
            mode: InboxSortMode.heat, nowSec: _now),
        lessThan(0),
        reason: '新的插在旧的前面（老实现就是按 pubDate 落位）',
      );
    });

    test('最新模式：只按发布时间', () {
      final freshWeak = _item('BVnew', view: 1, hours: 1);
      final oldHot = _item('BVold', view: 9999999, hours: 30);
      expect(
        inboxCompareForInsert(freshWeak, oldHot,
            mode: InboxSortMode.latest, nowSec: _now),
        lessThan(0),
      );
    });
  });

  group('inboxTopHeatRank', () {
    test('热度最高的那张 = #1', () {
      final hot = _item('BVhot', view: 1000000);
      final cold = _item('BVcold', view: 100);
      final queue = [hot, cold];
      expect(inboxTopHeatRank(hot, queue, nowSec: _now), 1);
      expect(inboxTopHeatRank(cold, queue, nowSec: _now), 2);
    });

    test('无数据的那张排在所有有分条目之后', () {
      final scored1 = _item('BV1', view: 1000000);
      final scored2 = _item('BV2', view: 1000);
      final unknown = _item('BV3');
      final queue = [unknown, scored1, scored2];
      expect(inboxTopHeatRank(unknown, queue, nowSec: _now), 3);
      expect(inboxTopHeatRank(scored1, queue, nowSec: _now), 1);
    });

    test('同分并列 → 名次相同（稳住队首的语义）', () {
      final a = _item('BVa', view: 5000, hours: 2);
      final b = _item('BVb', view: 5000, hours: 2);
      expect(inboxTopHeatRank(a, [a, b], nowSec: _now), 1);
      expect(inboxTopHeatRank(b, [a, b], nowSec: _now), 1);
    });
  });

  group('inboxSortModeById', () {
    test("'latest' → 最新；其余（含 null / 空 / 坏值）→ 热度", () {
      expect(inboxSortModeById('latest'), InboxSortMode.latest);
      expect(inboxSortModeById('heat'), InboxSortMode.heat);
      expect(inboxSortModeById(null), InboxSortMode.heat);
      expect(inboxSortModeById(''), InboxSortMode.heat);
      expect(inboxSortModeById('随便写的'), InboxSortMode.heat);
    });

    test('模式短名（按钮文案）', () {
      expect(InboxSortMode.heat.label, '热度榜');
      expect(InboxSortMode.latest.label, '最新');
    });
  });

  // =========================================================================
  // InboxItem.view 序列化
  // =========================================================================
  group('InboxItem.view（v2.64.0+）', () {
    test('toJson 只在有值时写 view（旧数据写回去一个字节都不多）', () {
      final withView = _item('BV1', view: 12345).toJson();
      expect(withView['view'], 12345);
      final without = _item('BV2').toJson();
      expect(without.containsKey('view'), isFalse);
    });

    test('fromJson：缺字段 / 脏类型 / 负数 → null；0 保留为 0', () {
      Map<String, dynamic> raw(dynamic view) => {
            'up_mid': 100,
            'up_name': 'UP',
            'up_face': '',
            'bvid': 'BV1',
            'title': 't',
            'cover': '',
            'duration': 60,
            'pub_date': 1700000000,
            'view': view,
          };
      expect(InboxItem.fromJson(raw(1234)).view, 1234);
      expect(InboxItem.fromJson(raw(0)).view, 0, reason: '0 是合法值');
      expect(InboxItem.fromJson(raw(-3)).view, isNull);
      expect(InboxItem.fromJson(raw('1234')).view, isNull);
      expect(InboxItem.fromJson(raw(null)).view, isNull);
      final noKey = raw(1)..remove('view');
      expect(InboxItem.fromJson(noKey).view, isNull);
    });

    test('toJson → fromJson 往返保留播放量', () {
      final it = _item('BV1', view: 777);
      expect(InboxItem.fromJson(it.toJson()).view, 777);
    });
  });

  // =========================================================================
  // InboxSortStore
  // =========================================================================
  group('InboxSortStore', () {
    test('默认 = 热度（首次启动没有记录时就是热度榜）', () {
      expect(InboxSortStore.instance.mode, InboxSortMode.heat);
      expect(InboxSortStore.instance.modeId, 'heat');
    });

    test('select：立即通知 + 落盘', () async {
      final store = InboxSortStore.instance;
      var notified = 0;
      void onChanged() => notified++;
      store.addListener(onChanged);
      addTearDown(() => store.removeListener(onChanged));

      await store.select(InboxSortMode.latest);

      expect(store.mode, InboxSortMode.latest);
      expect(notified, greaterThanOrEqualTo(1), reason: '切换要发通知，页面才重排');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(InboxSortStore.storageKey), 'latest');
    });

    test('ensureLoaded：回读已保存的模式（= 重启保持）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(InboxSortStore.storageKey, 'latest');
      InboxSortStore.instance.resetForTest(); // 先回默认，确认是"读回来的"
      expect(InboxSortStore.instance.mode, InboxSortMode.heat);

      await InboxSortStore.instance.ensureLoaded();

      expect(InboxSortStore.instance.mode, InboxSortMode.latest);
    });

    test('未知值 / 空 → 回退热度（不抛）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(InboxSortStore.storageKey, '不认识的模式');
      await InboxSortStore.instance.ensureLoaded();
      expect(InboxSortStore.instance.mode, InboxSortMode.heat);
    });

    test('已保存的值与当前一致 → 不发通知（避免无谓重建）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(InboxSortStore.storageKey, 'heat');
      var notified = 0;
      void onChanged() => notified++;
      InboxSortStore.instance.addListener(onChanged);
      addTearDown(() => InboxSortStore.instance.removeListener(onChanged));

      await InboxSortStore.instance.ensureLoaded();

      expect(notified, 0);
    });
  });
}
