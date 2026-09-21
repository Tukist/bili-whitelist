// 番剧「同一部」分集识别与组内排序（v2.37.0，用户需求：同一部番剧的上下集
// 不能跨番）。
//
// 覆盖（纯 Dart，无 widget、无网络）：
//   - seasonGroupKeyOf：键 = `第N话` 之前的季名前缀；epId == null → null
//     （普通视频不属于任何番组）；标题里没有 `第N话` → null（不猜）；
//     前缀为空 → null；
//   - seasonEpisodeIndexOf：`第12话` → 12、`第5.5话` → 5.5、
//     `14(OVA)` / 无 `第N话` → null（安全回退，不抛）；
//   - sortedSeasonEpisodes：**43 集倒序输入 → 组内正序**；跨番不串；
//     多部番 + 普通视频混排时只取当前那部；OVA（无 `第N话`）借同列表里的
//     季名归位，无集号的按 pubdate 升序 → 再 addedAt 升序（有集号的在前）；
//   - **回归保护**：current 不是番剧集（epId == null）时**原样返回入参列表**
//     （同一份实例，顺序一字不改）→ collection_page 拿到的就是改动前那份；
//   - **边界**：番剧集但认不出同部 → 只给自己一条（宁可没上下集也不跨番）；
//   - **已知表现**：同一部番的两季若季名（前缀）完全相同会被并成一组；
//     季名不同的（第一季/第二季）严格分开。
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';

/// 番剧集：标题结构 = 季名 + ' ' + 集数标签（与 whitelist_writer 的
/// pgcEpisodeTitle 同构）。
WhitelistVideo _ep(
  String season,
  String label, {
  int? epId,
  int? pubdate,
  String addedAt = '2026-01-01T00:00:00Z',
  String? titleOverride,
}) =>
    WhitelistVideo(
      bvid: 'BV_${season}_$label',
      cid: 1,
      title: titleOverride ?? '$season $label',
      cover: '',
      duration: 100,
      upName: '番剧/官方',
      addedAt: addedAt,
      epId: epId,
      pubdate: pubdate,
      // 整季导入：collection 空（未分类）、order 恒 0
    );

/// 普通视频（无 epId）。
WhitelistVideo _plain(String title, {String addedAt = '2026-01-01T00:00:00Z'}) =>
    WhitelistVideo(
      bvid: 'BV_plain_$title',
      cid: 1,
      title: title,
      cover: '',
      duration: 100,
      upName: '某UP主',
      addedAt: addedAt,
    );

String _t(WhitelistVideo v) => v.title;

List<String> _titles(List<WhitelistVideo> vs) => vs.map(_t).toList();

/// 43 集整季导入的**合集展示序**：order 全 0 → 按 added_at 倒序 →
/// 「第43话 → 第1话」（就是用户看到的那一块）。
List<WhitelistVideo> _gundam43Descending() => [
      for (var n = 43; n >= 1; n--)
        _ep(
          '机动战士高达',
          '第$n话',
          epId: 900000 + n,
          // added_at 逐集递增（导入时刻）；倒序展示时第43话在最前
          addedAt: '2026-08-01T00:00:${n.toString().padLeft(2, '0')}Z',
        ),
    ];

void main() {
  group('seasonGroupKeyOf：键 = 季名前缀', () {
    test('epId 非空 + 标题含 `第N话` → 键 = `第N话` 之前的整段（trim）', () {
      expect(
        seasonGroupKeyOf(_ep('是，大臣 第一季', '第3话', epId: 1)),
        '是，大臣 第一季',
      );
      expect(
        seasonGroupKeyOf(
            _ep('小林家的龙女仆', '第1话', epId: 2, titleOverride: '小林家的龙女仆 第1话 史上最强女仆、托尔！')),
        '小林家的龙女仆',
        reason: '副标题不影响键（键只取 `第N话` 之前的部分）',
      );
    });

    test('epId == null（普通视频/旧数据）→ null：不属于任何番组', () {
      expect(seasonGroupKeyOf(_plain('普通视频 第3话')), isNull,
          reason: '标题像番剧也不猜——必须 epId 非空才算番剧集');
    });

    test('标题里没有 `第N话`（如 14(OVA)）→ null，不猜', () {
      expect(seasonGroupKeyOf(_ep('某番', '14(OVA)', epId: 5)), isNull);
      expect(
        seasonGroupKeyOf(_ep('某番', '', epId: 5, titleOverride: '某番 正片')),
        isNull,
      );
    });

    test('前缀为空（标题自己就叫 `第1话`）→ null，不猜', () {
      expect(seasonGroupKeyOf(_ep('', '第1话', epId: 7)), isNull);
    });
  });

  group('seasonEpisodeIndexOf：集号解析与安全回退', () {
    test('`第1话` / `第12话` → 1 / 12', () {
      expect(seasonEpisodeIndexOf(_ep('某番', '第1话', epId: 1)), 1);
      expect(seasonEpisodeIndexOf(_ep('某番', '第12话', epId: 1)), 12);
    });

    test('`第5.5话`（接口原样给的小数标签）→ 5.5', () {
      expect(seasonEpisodeIndexOf(_ep('某番', '第5.5话', epId: 1)), 5.5);
    });

    test('`14(OVA)` / 无 `第N话` / 普通视频 → null（回退，不抛）', () {
      expect(seasonEpisodeIndexOf(_ep('某番', '14(OVA)', epId: 1)), isNull);
      expect(
        seasonEpisodeIndexOf(
            _ep('某番', '', epId: 1, titleOverride: '某番 正片')),
        isNull,
      );
      expect(seasonEpisodeIndexOf(_plain('普通视频')), isNull);
    });
  });

  group('sortedSeasonEpisodes：只取同部、组内正序', () {
    test('43 集**倒序**输入 → 组内**正序**（第1话…第43话）', () {
      final list = _gundam43Descending();
      final group = sortedSeasonEpisodes(list, list[20]); // 中间某一集（第23话）
      expect(group, hasLength(43));
      expect(_titles(group).first, '机动战士高达 第1话');
      expect(_titles(group).last, '机动战士高达 第43话');
      expect(
        _titles(group),
        [for (var n = 1; n <= 43; n++) '机动战士高达 第$n话'],
        reason: '组内按集号升序（不是 added_at 倒序，也不是 order）',
      );
    });

    test('**走到末集时它是组内最后一条**（末集「下一集」天然禁用，跨不出去）', () {
      final list = _gundam43Descending();
      final group = sortedSeasonEpisodes(list, list[0]); // 第43话
      expect(_titles(group).last, '机动战士高达 第43话');
      expect(group.indexOf(list[0]), group.length - 1,
          reason: '末集必须是组内最后一条 → 播放页 _canPlayNext == false');
    });

    test('跨番不串：两部番 + 普通视频混在一起 → 只取当前那部', () {
      final a1 = _ep('高达', '第1话', epId: 11, addedAt: '2026-08-01T00:00:01Z');
      final a2 = _ep('高达', '第2话', epId: 12, addedAt: '2026-08-01T00:00:02Z');
      final b1 = _ep('芙莉莲', '第1话', epId: 21, addedAt: '2026-08-01T00:00:03Z');
      final b2 = _ep('芙莉莲', '第2话', epId: 22, addedAt: '2026-08-01T00:00:04Z');
      final p1 = _plain('某杂谈', addedAt: '2026-08-01T00:00:05Z');
      // 合集展示序故意交错（added_at 倒序 → p1, 芙2, 芙1, 高2, 高1）
      final list = [p1, b2, b1, a2, a1];

      final g = sortedSeasonEpisodes(list, a1);
      expect(_titles(g), ['高达 第1话', '高达 第2话']);
      expect(_titles(g), isNot(contains('芙莉莲 第1话')));
      expect(_titles(g), isNot(contains('某杂谈')));

      final f = sortedSeasonEpisodes(list, b2);
      expect(_titles(f), ['芙莉莲 第1话', '芙莉莲 第2话']);

      // 普通视频：**原样返回入参列表**（与改动前逐字符一致）
      final plain = sortedSeasonEpisodes(list, p1);
      expect(identical(plain, list), isTrue,
          reason: 'epId == null → 必须把原列表原封不动交下去');
      expect(_titles(plain), _titles(list));
    });

    test('同前缀（同季名）的两季会被并成一组——**已知表现**，钉住语义', () {
      final s1 = _ep('某番', '第1话', epId: 1, addedAt: '2026-08-01T00:00:01Z');
      final s1b = _ep('某番', '第2话', epId: 2, addedAt: '2026-08-01T00:00:02Z');
      final s2 = _ep('某番', '第1话', epId: 3, addedAt: '2026-08-02T00:00:01Z');
      final list = [s1, s1b, s2];
      final g = sortedSeasonEpisodes(list, s1);
      expect(g, hasLength(3),
          reason: '季名（前缀）相同 → 并成一组（本批取舍：不为此加 seasonId 字段）');
      // 两季的第 1 话集号相同 → 回退到 pubdate / added_at 升序（稳定、不抛）
      expect(g.map((v) => v.addedAt).toList(),
          [s1.addedAt, s2.addedAt, s1b.addedAt]);
    });

    test('季名不同的两季（`XX 第一季` / `XX 第二季`）严格分开，不并组', () {
      final s1 = _ep('某番 第一季', '第1话', epId: 1, addedAt: '2026-08-01T00:00:01Z');
      final s1b = _ep('某番 第一季', '第2话', epId: 2, addedAt: '2026-08-01T00:00:02Z');
      final s2 = _ep('某番 第二季', '第1话', epId: 3, addedAt: '2026-08-02T00:00:01Z');
      final g = sortedSeasonEpisodes([s1, s1b, s2], s1);
      expect(_titles(g), ['某番 第一季 第1话', '某番 第一季 第2话'],
          reason: '前缀严格相等才同组 → 第二季不会被并进来');
    });

    test('OVA（无 `第N话`）借同列表里的季名归位：有集号的在前，OVA 按 pubdate 升序',
        () {
      final e1 = _ep('某番', '第1话', epId: 1, pubdate: 100);
      final e2 = _ep('某番', '第2话', epId: 2, pubdate: 200);
      final ova1 = _ep('某番', '14(OVA)', epId: 3, pubdate: 500);
      final ova2 = _ep('某番', '15(OVA)', epId: 4, pubdate: 300);
      final list = [ova2, e2, ova1, e1]; // 乱序输入

      final g = sortedSeasonEpisodes(list, e1);
      expect(_titles(g), [
        '某番 第1话',
        '某番 第2话',
        '某番 15(OVA)', // 无集号 → pubdate 300（升序）
        '某番 14(OVA)', // 无集号 → pubdate 500
      ]);
      // 从 OVA 自己点进来，也归到同一部（借 e1/e2 的季名）
      expect(_titles(sortedSeasonEpisodes(list, ova1)), _titles(g));
    });

    test('无集号且 pubdate 缺失 → 回退 added_at 升序（不抛、稳定）', () {
      final e1 = _ep('某番', '第1话', epId: 1, addedAt: '2026-08-01T00:00:01Z');
      final ovaA = _ep('某番', '14(OVA)', epId: 2,
          addedAt: '2026-08-01T00:00:03Z');
      final ovaB = _ep('某番', '15(OVA)', epId: 3,
          addedAt: '2026-08-01T00:00:02Z');
      final list = [ovaA, ovaB, e1];
      final g = sortedSeasonEpisodes(list, ovaA);
      expect(_titles(g), ['某番 第1话', '某番 15(OVA)', '某番 14(OVA)'],
          reason: 'pubdate 都没有 → added_at 升序（早导入的在前）');
    });

    test('脏 pubdate（0 / null）不参与排序歧义：视为最旧', () {
      final e1 = _ep('某番', '第1话', epId: 1, pubdate: 0);
      final e2 = _ep('某番', '第2话', epId: 2, pubdate: 200);
      final g = sortedSeasonEpisodes([e2, e1], e1);
      expect(_titles(g), ['某番 第1话', '某番 第2话'], reason: '集号优先，与 pubdate 无关');
    });

    test('返回新列表、不改入参顺序（列表页的展示序不受影响）', () {
      final list = _gundam43Descending();
      final before = _titles(list);
      final g = sortedSeasonEpisodes(list, list[10]);
      expect(_titles(list), before, reason: '入参列表顺序一字不能改');
      expect(identical(g, list), isFalse, reason: '番剧集返回的是重排后的新列表');
    });

    test('只有一集的一部番 → 组内就它自己（播放页不出现死按钮）', () {
      final only = _ep('某番', '第1话', epId: 1);
      final other = _ep('别番', '第1话', epId: 2);
      final g = sortedSeasonEpisodes([only, other], only);
      expect(g, hasLength(1));
      expect(g.single.title, '某番 第1话');
    });

    test('current 认不出同部（OVA 且列表里没有可借的季名）→ 只给自己一条（不跨番）', () {
      // 标题里没有 `第N话`，列表里这些集的季名（机动战士高达）也匹配不上
      // `某番 14(OVA)` → 认不出同部。它是**番剧集**，把「下一集」指向合集里
      // 的下一条（别的番）正是用户报的毛病 → 宁可只给自己（长度 1 →
      // 播放页整行不构建），也不跨番。
      final list = _gundam43Descending();
      final ova = _ep('某番', '14(OVA)', epId: 999);
      final withOva = [...list, ova];
      final g = sortedSeasonEpisodes(withOva, ova);
      expect(g, hasLength(1));
      expect(g.single.title, '某番 14(OVA)');
      expect(identical(g, withOva), isFalse);
    });
  });
}
