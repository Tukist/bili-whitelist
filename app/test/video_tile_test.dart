// VideoTile 副信息行测试：时长 · UP主（· 发布时间）（· N 播放，v2.37.0）。
// - 新数据（pubdate 非空）→ 副信息行含 `· yyyy-MM-dd`
// - 旧数据（pubdate null / 0）→ 副信息行与旧版逐字符一致（不含日期段），
//   不崩、不破坏布局（标题/时长照常渲染）
// - 播放量（view 非空才显示；null → 与改动前逐字符一致）
// - 块化（P0 批次 B）：外形给 ListTile 自己（圆角 + 强描边 + 纸底），
//   **容器类型不变**（`find.byType(VideoTile)` 照旧命中）；封面外层包
//   CoverHero（空 bvid → 零 Hero 节点），多选模式整块关掉 Hero。
// 纯 widget 测试，无网络（cover 空串 → CoverImage 走本地占位）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/cover_hero.dart';
import 'package:bili_whitelist_app/widgets/cover_image.dart';
import 'package:bili_whitelist_app/widgets/video_tile.dart';

/// 与模型 formatPubdate 同语义的本地日期推导（跨时区机器测试稳定）。
String _dateText(int sec) {
  final dt = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

WhitelistVideo _video({
  int? pubdate,
  String bvid = 'BV1',
  String title = '测试视频标题',
  List<PageInfo>? pages,
  int? view,
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 1,
      title: title,
      cover: '',
      duration: 90, // 1:30
      upName: 'UP主',
      addedAt: '2026-01-01T00:00:00Z',
      pubdate: pubdate,
      pages: pages,
      view: view,
    );

/// 超长标题：测试字体下（每字符宽 = fontSize = 14）必然超过 2 行。
final String _longTitle = '超长标题' * 30;

Widget _wrap(Widget tile) => MaterialApp(
      home: Scaffold(
        body: ListView(children: [tile]),
      ),
    );

void main() {
  testWidgets('pubdate 非空 → 副信息行 = 时长 · UP主 · yyyy-MM-dd', (tester) async {
    final pubdate = 1682899200; // 2023-05-01T00:00:00Z
    await tester.pumpWidget(_wrap(VideoTile(video: _video(pubdate: pubdate))));
    expect(
      find.text('1:30 · UP主 · ${_dateText(pubdate)}'),
      findsOneWidget,
    );
  });

  testWidgets('pubdate null（旧数据）→ 副信息行 = 时长 · UP主，无日期段', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(video: _video())));
    expect(find.text('1:30 · UP主'), findsOneWidget);
    expect(find.textContaining(RegExp(r'· \d{4}-\d{2}-\d{2}')), findsNothing);
    // 标题照常渲染（旧数据不破坏布局）
    expect(find.text('测试视频标题'), findsOneWidget);
  });

  testWidgets('pubdate 0（脏值）→ 与 null 同处理，不显示日期', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(video: _video(pubdate: 0))));
    expect(find.text('1:30 · UP主'), findsOneWidget);
    expect(find.textContaining(RegExp(r'· \d{4}-\d{2}-\d{2}')), findsNothing);
  });

  // 播放量（v2.37.0，用户需求「视频卡片加播放量」）。方案是「只对能拿到的
  // 几处显示」：白名单里**老视频多数没有 view**（导入时拿不到）→ 卡片与改动
  // 前逐字符一致，这是已知表现、不是 bug。
  group('播放量（v2.37.0）', () {
    testWidgets('view 非空 → 副信息行末尾多一段「N 播放」', (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(video: _video(view: 12345))));
      expect(find.text('1:30 · UP主 · 1.2万 播放'), findsOneWidget);
    });

    testWidgets('view null（旧数据 / 拿不到）→ 与改动前**逐字符一致**', (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(video: _video())));
      expect(find.text('1:30 · UP主'), findsOneWidget);
      expect(find.textContaining('播放'), findsNothing);
    });

    testWidgets('view = 0 → 显示「0 播放」（真·零播放，不是「未知」）',
        (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(video: _video(view: 0))));
      expect(find.text('1:30 · UP主 · 0 播放'), findsOneWidget);
    });

    testWidgets('view + pubdate 都在 → 顺序 = 时长 · UP主 · 日期 · N 播放（播放量最后）',
        (tester) async {
      final pubdate = 1682899200;
      await tester.pumpWidget(
          _wrap(VideoTile(video: _video(pubdate: pubdate, view: 999))));
      expect(find.text('1:30 · UP主 · ${_dateText(pubdate)} · 999 播放'),
          findsOneWidget);
    });

    testWidgets('万/亿口径与专栏页 fmtArticleCount 一致', (tester) async {
      final cases = {
        999: '999 播放',
        10000: '1万 播放',
        12345: '1.2万 播放',
        123456789: '1.2亿 播放',
      };
      for (final e in cases.entries) {
        await tester.pumpWidget(_wrap(VideoTile(video: _video(view: e.key))));
        expect(find.text('1:30 · UP主 · ${e.value}'), findsOneWidget);
      }
    });

    testWidgets('纯函数 fmtVideoSubtitle：四种组合逐一钉住', (tester) async {
      expect(
        fmtVideoSubtitle(duration: '1:30', upName: 'UP主'),
        '1:30 · UP主',
      );
      expect(
        fmtVideoSubtitle(duration: '1:30', upName: 'UP主', view: 42),
        '1:30 · UP主 · 42 播放',
      );
      expect(
        fmtVideoSubtitle(
            duration: '1:30', upName: 'UP主', pubdateText: '2023-05-01'),
        '1:30 · UP主 · 2023-05-01',
      );
      expect(
        fmtVideoSubtitle(
            duration: '1:30', upName: 'UP主', pubdateText: '2023-05-01', view: 42),
        '1:30 · UP主 · 2023-05-01 · 42 播放',
      );
    });
  });

  testWidgets('块化：容器类型不变，外形落在 ListTile 自己身上', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(video: _video())));

    // 容器类型不变（页面测试按类型抓取 VideoTile / ListTile）
    expect(find.byType(VideoTile), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    final shape = tile.shape! as RoundedRectangleBorder;
    expect(shape.side.color, kRuleStrong, reason: '1px 强描边');
    expect(shape.side.width, 1);
    expect(shape.borderRadius, BorderRadius.circular(kRadiusMd));
    expect(tile.tileColor, kPaper, reason: '纸底');
    expect(tile.contentPadding,
        const EdgeInsets.fromLTRB(kSpace8, kSpace4, kSpace8, kSpace4));
    // 触摸目标：两行 tile 高度 ≥ 48dp
    expect(tester.getSize(find.byType(ListTile)).height,
        greaterThanOrEqualTo(48.0));
    // 空 cover 走本地占位，不触网、不崩
    expect(find.byType(CoverImage), findsOneWidget);
    expect(find.text('测试视频标题'), findsOneWidget);
  });

  testWidgets('封面 Hero：bvid 非空包 Hero；bvid 空 → 零 Hero 节点', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(video: _video(bvid: 'BV1HERO0001'))));
    expect(find.byType(Hero), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CoverHero),
        matching: find.byType(CoverImage),
      ),
      findsOneWidget,
    );

    // bvid 为空 → coverHeroTag 返回 null → CoverHero 直接给 child（无 Hero）
    await tester.pumpWidget(_wrap(VideoTile(video: _video(bvid: ''))));
    expect(find.byType(CoverHero), findsOneWidget);
    expect(find.byType(Hero), findsNothing);
  });

  testWidgets('多选模式：整块 HeroMode 关掉（不飞残影封面）', (tester) async {
    await tester.pumpWidget(_wrap(VideoTile(
      video: _video(),
      selectMode: true,
      selected: false,
    )));
    expect(tester.widget<HeroMode>(find.byType(HeroMode)).enabled, isFalse);
    // 多选态结构照旧：勾选框在
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
  });

  group('已缓存角标（v2.29.0：区分仅音频缓存）', () {
    testWidgets('未缓存 → 不显示角标', (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(video: _video())));
      expect(find.text('已缓存'), findsNothing);
      expect(find.text('已缓存音频'), findsNothing);
    });

    testWidgets('整段缓存 → 「已缓存」', (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(
        video: _video(),
        cachedCount: 1,
      )));
      expect(find.text('已缓存'), findsOneWidget);
      expect(find.text('已缓存音频'), findsNothing);
    });

    testWidgets('全是仅音频缓存 → 「已缓存音频」（点进去没画面，先说清楚）',
        (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(
        video: _video(),
        cachedCount: 1,
        cachedAudioOnly: true,
      )));
      expect(find.text('已缓存音频'), findsOneWidget);
      expect(find.text('已缓存'), findsNothing);
    });

    testWidgets('多 P 部分缓存 → 计数与「音频」前缀都带上', (tester) async {
      final multi = _video(
        pages: const [
          PageInfo(cid: 1, part: 'p1', duration: 60),
          PageInfo(cid: 2, part: 'p2', duration: 60),
          PageInfo(cid: 3, part: 'p3', duration: 60),
        ],
      );
      await tester.pumpWidget(_wrap(VideoTile(
        video: multi,
        cachedCount: 1,
        cachedAudioOnly: true,
      )));
      expect(find.text('已缓存音频 1/3'), findsOneWidget);

      await tester.pumpWidget(_wrap(VideoTile(
        video: multi,
        cachedCount: 2,
      )));
      expect(find.text('已缓存 2/3'), findsOneWidget);
    });
  });

  group('标题过长 → 展开/收起', () {
    testWidgets('短标题：不出现「展开」入口（点标题照旧进播放页）', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_wrap(VideoTile(
        video: _video(),
        onTap: () => tapped++,
      )));

      expect(find.text('展开'), findsNothing);
      expect(find.text('收起'), findsNothing);
      // 标题仍是普通 Text（未超行 → ExpandableText 只渲染正文，不套任何手势）
      expect(find.text('测试视频标题'), findsOneWidget);

      await tester.tap(find.text('测试视频标题'));
      await tester.pump();
      expect(tapped, 1, reason: '短标题点按穿透给整卡 → 进播放页');
    });

    testWidgets('长标题：出现「展开」；点开展开全文 + 「收起」；再点收起复原',
        (tester) async {
      await tester.pumpWidget(_wrap(VideoTile(video: _video(title: _longTitle))));

      // 折叠态：2 行截断 + 「展开」
      expect(find.text('展开'), findsOneWidget);
      final folded = tester.widget<Text>(find.text(_longTitle));
      expect(folded.maxLines, 2);
      expect(folded.overflow, TextOverflow.ellipsis);

      // 展开 → 全文（无 maxLines）+「收起」
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, isNull);

      // 收起 → 复原
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, 2);
    });

    testWidgets('展开态点标题正文 → 不抢整卡点击（仍进播放页）', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_wrap(VideoTile(
        video: _video(title: _longTitle),
        onTap: () => tapped++,
      )));

      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text(_longTitle)).maxLines, isNull);

      // 点展开后的正文（不是「收起」按钮）→ 整卡 onTap 照旧触发
      await tester.tap(find.text(_longTitle));
      await tester.pump();
      expect(tapped, 1, reason: '展开态标题正文不挂手势，点击穿透给 ListTile');
    });

    testWidgets('动效开关：MotionControl 关 → 不套 AnimatedSize；开 → 套上',
        (tester) async {
      // 默认（flutter test）= 关：展开瞬时到位，一个 controller 都不建
      MotionControl.reset();
      await tester.pumpWidget(_wrap(VideoTile(video: _video(title: _longTitle))));
      expect(find.byType(AnimatedSize), findsNothing);

      MotionControl.enabled = true;
      await tester.pumpWidget(_wrap(VideoTile(video: _video(title: _longTitle))));
      expect(find.byType(AnimatedSize), findsOneWidget,
          reason: '开动效 → 展开/收起走 AnimatedSize 高度过渡');
      addTearDown(MotionControl.reset);
    });
  });
}
