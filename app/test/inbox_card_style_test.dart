// 信箱卡片样式（v2.21.0+：扑克牌比例 + 多版式 + 设置页预览切换）的测试：
// - store：默认 classic / select 立即通知 + 落盘 / ensureLoaded 回读 /
//   未知 id 回退默认
// - 比例：卡片 = **扑克牌 1:1.39**（每个风格同尺寸），411×914 竖屏不出屏
// - 每个风格：封面 / 标题 / 作者 / 时长都在；长标题折 2 行、空封面都不溢出
// - 封面：5 个风格都得**完整显示 16:9**（左右不裁，区域差额用同图模糊底衬补）；
//   classic 另有「图顶对齐（上底衬 = 0）+ 下缘渐变过渡」→ 底衬与清晰图之间看不出接缝
// - 留白：editorial 信息区文案整块居中（不再是一段大空档）、minimal 缩略图 ≥ 0.85 卡宽
//   且上下留白均分
// - 设置项：「个人」页设置区有「信箱卡片样式」入口，弹层列出全部风格且**每项带
//   缩略预览**，点选 → store 变更 + 落盘 + 关弹层（按钮文案跟着变）
// - 信箱页：监听 store → 切换后卡片栈立即换版式，且**尺寸不变**（不跳动）、
//   卡片栈（下层露边）/ 底部按钮等既有锚点都还在
//
// 既有行为（右滑/左滑/弹回/撤销/点按/卡片栈露边）的回归在
// `test/inbox_swipe_test.dart`（本文件只管「版式 + 比例 + 切换」）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/pages/inbox_page.dart';
import 'package:bili_whitelist_app/services/inbox_card_style_store.dart';
import 'package:bili_whitelist_app/services/inbox_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/theme/app_tokens.dart';
import 'package:bili_whitelist_app/theme/motion_control.dart';
import 'package:bili_whitelist_app/widgets/cover_image.dart';
import 'package:bili_whitelist_app/widgets/inbox_card_styles.dart';
import 'package:bili_whitelist_app/widgets/inbox_swipe_card.dart';
import 'package:bili_whitelist_app/widgets/manage_panel.dart';

// ---------------------------------------------------------------------------
// 替身 / 工具
// ---------------------------------------------------------------------------

/// 内存版信箱服务：固定未读列表（不触网、不碰持久层）。
class _FakeInboxService extends InboxService {
  _FakeInboxService(this.items);

  final List<InboxItem> items;

  @override
  Future<List<InboxItem>> getItems() async => items;

  @override
  Future<InboxCheckResult> checkAll({bool force = false}) async =>
      InboxCheckResult(total: 0, unseen: items.length, items: items);

  @override
  Future<void> markHandled(String bvid) async {}

  @override
  Future<void> markAllRead() async {}
}

/// 内存版 secure storage（mock 原生 MethodChannel，同 manage_panel_test）。
final Map<String, String> _secure = {};

const MethodChannel _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'read':
            return _secure[args['key'] as String?];
          case 'write':
            final key = args['key'] as String?;
            if (key == null) return false;
            _secure[key] = args['value'] as String? ?? '';
            return true;
          case 'delete':
            _secure.remove(args['key'] as String?);
            return true;
          default:
            return null;
        }
      });
}

/// 固定屏幕为竖屏 411×914（真机常见规格）。
void _usePortraitPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(411, 914);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 面板测试用的大视口（400×1000 逻辑像素）：5 条风格选项不用滚动就都在屏上。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

InboxItem _item(
  int i, {
  String? title,
  String cover = '',
  int duration = 245,
  int? pubDate,
}) => InboxItem(
  upMid: i,
  upName: 'UP 主 $i',
  upFace: '',
  bvid: 'BV$i',
  title: title ?? '新视频 $i',
  cover: cover,
  duration: duration,
  // 默认 3 小时前（相对时间可断言且不受当天时间影响）
  pubDate: pubDate ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3 * 3600,
);

/// 单独渲染某一种版式（不经信箱页）：验证比例、排版、溢出。
Future<void> _pumpStyle(
  WidgetTester tester,
  InboxCardStyle style, {
  InboxItem? item,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: InboxCardStyleView(
            item: item ?? _item(1),
            style: style,
            width: 411 * 0.88,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 挂 ManagePanel（「个人」页底部的设置区共用组件）。
Future<void> _pumpPanel(WidgetTester tester) async {
  _useTallViewport(tester);
  final panel = ManagePanel(
    github: GithubApi(),
    closeBeforeNavigate: false,
    headingTitle: '设置',
    headingSubtitle: '集中设置区（测试）',
    onManageCollections: () {},
    onCheckUpdate: () {},
    onLogin: () {},
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: panel)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MotionControl.reset(); // 测试环境默认 = false（关动效 → 直接跳变）
    InboxCardStyleStore.instance.resetForTest();
    _secure.clear();
    _mockSecureStorage();
  });

  tearDown(() {
    InboxCardStyleStore.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  // -------------------------------------------------------------------------
  // store
  // -------------------------------------------------------------------------

  group('InboxCardStyleStore', () {
    test('默认 = classic（经典满幅）', () {
      expect(InboxCardStyleStore.instance.styleId, 'classic');
      expect(
        InboxCardStyleStore.instance.style.variant,
        InboxCardVariant.classic,
      );
    });

    test('select：立即通知 + 落盘', () async {
      final store = InboxCardStyleStore.instance;
      var notified = 0;
      void onChanged() => notified++;
      store.addListener(onChanged);
      addTearDown(() => store.removeListener(onChanged));

      await store.select('polaroid');

      expect(store.styleId, 'polaroid');
      expect(store.style.label, '宝丽来');
      expect(notified, greaterThanOrEqualTo(1), reason: '切换要发通知，页面才换版式');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(InboxCardStyleStore.storageKey), 'polaroid');
    });

    test('ensureLoaded：回读已保存的风格', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(InboxCardStyleStore.storageKey, 'banner');
      InboxCardStyleStore.instance.resetForTest(); // 先回默认，确认是"读回来的"
      expect(InboxCardStyleStore.instance.styleId, 'classic');

      await InboxCardStyleStore.instance.ensureLoaded();

      expect(InboxCardStyleStore.instance.styleId, 'banner');
    });

    test('未知 id / 空记录 → 回退默认 classic（不抛）', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(InboxCardStyleStore.storageKey, '不存在的风格');
      await InboxCardStyleStore.instance.ensureLoaded();
      expect(InboxCardStyleStore.instance.styleId, 'classic');

      await InboxCardStyleStore.instance.select('nope');
      expect(InboxCardStyleStore.instance.styleId, 'classic');
      expect(prefs.getString(InboxCardStyleStore.storageKey), 'classic');
    });

    test('风格表：id 唯一、默认风格在表里、逐个可查', () {
      expect(kInboxCardStyles.length, greaterThanOrEqualTo(4));
      expect(
        kInboxCardStyles.map((s) => s.id).toSet().length,
        kInboxCardStyles.length,
        reason: 'id 必须唯一（持久化按 id 回读）',
      );
      expect(kInboxCardStyles.first.id, kDefaultInboxCardStyle.id);
      for (final s in kInboxCardStyles) {
        expect(inboxCardStyleById(s.id).id, s.id);
        expect(s.label.isNotEmpty, isTrue);
        expect(s.description.isNotEmpty, isTrue);
      }
      expect(inboxCardStyleById(null).id, kDefaultInboxCardStyle.id);
    });
  });

  // -------------------------------------------------------------------------
  // 每个风格的渲染 + 比例
  // -------------------------------------------------------------------------

  group('版式渲染', () {
    for (final style in kInboxCardStyles) {
      testWidgets('${style.id}：封面/标题/作者/时长都在，卡片是扑克牌比例', (tester) async {
        _usePortraitPhone(tester);
        await _pumpStyle(tester, style);

        expect(tester.takeException(), isNull);
        // 四样信息都要在（不同版式的排版不同，故用 textContaining）
        expect(find.textContaining('新视频 1'), findsOneWidget);
        expect(find.textContaining('UP 主 1'), findsOneWidget);
        expect(
          find.textContaining('4:05'),
          findsOneWidget,
          reason: '245s → mm:ss',
        );
        expect(find.textContaining('小时前'), findsOneWidget);

        // 扑克牌比例：宽 : 高 = 1 : 1.39
        final size = tester.getSize(find.byType(InboxCardStyleView));
        expect(size.width, closeTo(411 * 0.88, 1));
        expect(size.height, closeTo(size.width * kInboxCardAspect, 1));
        expect(size.width / size.height, closeTo(1 / kInboxCardAspect, 0.005));

        // ★ #1 封面**不裁左右**：完整显示的那张图的落位框宽高比 == 原图 16:9
        //   （比例一致时 CoverImage 内置的 BoxFit.cover 等价于 contain）
        final coverSize = tester.getSize(find.byKey(kInboxCardCoverKey));
        expect(
          coverSize.width / coverSize.height,
          closeTo(kInboxCoverAspect, 0.01),
          reason: '${style.id}：封面必须完整落位在 16:9 的框里（cover 铺满窄框会切掉图上的标题）',
        );
        expect(coverSize.width, lessThanOrEqualTo(size.width + 0.5));
      });
    }

    testWidgets('所有风格：长标题折 2 行、空封面，都不溢出', (tester) async {
      _usePortraitPhone(tester);
      const long = '这是一条很长很长很长很长很长很长很长很长很长很长很长很长的标题一二三四五六七八九十';

      for (final style in kInboxCardStyles) {
        await _pumpStyle(tester, style, item: _item(1, title: long));

        final overflow = tester.takeException();
        expect(overflow, isNull, reason: '${style.id}：长标题下不应有溢出/异常');

        // 长标题折成 2 行（字阶 16 × 行高 1.3 = 20.8 → 两行约 41.6）
        final titleH = tester.getSize(find.text(long)).height;
        expect(titleH, greaterThan(16 * 1.3), reason: '${style.id}：长标题应折 2 行');
        expect(
          titleH,
          lessThanOrEqualTo(16 * 1.3 * 2 + 1),
          reason: '${style.id}：最多 2 行（不溢出）',
        );

        // 空封面：仍走共享 CoverImage（本地占位，不联网）+「暂无封面」标版
        final cover = tester.widget<CoverImage>(
          find.descendant(
            of: find.byKey(kInboxCardCoverKey),
            matching: find.byType(CoverImage),
          ),
        );
        expect(cover.cover, '');
        expect(cover.width / cover.height, closeTo(kInboxCoverAspect, 0.01),
            reason: '${style.id}：空封面占位也得是 16:9（不留裁切路径）');
        expect(find.text('暂无封面'), findsOneWidget);

        // 高度仍在扑克牌比例内（标版/长标题不会把卡片撑高）
        final size = tester.getSize(find.byType(InboxCardStyleView));
        expect(size.height, closeTo(size.width * kInboxCardAspect, 1));
      }
    });

    testWidgets('五种风格的卡面外形/排版确实不同（不是同一个版式换措辞）', (tester) async {
      _usePortraitPhone(tester);
      // 用「封面区高度」当指纹（有模糊底衬时 = 底衬那层，区域正好 16:9 时 = 图本身）：
      // classic 的封面区铺满整卡；editorial/banner 图文比例不同；polaroid 四周有相纸留白；
      // minimal 是 16:9 小图居中留白
      final regionH = <String, double>{};
      final coverW = <String, double>{};
      final cardHeights = <String, double>{};
      for (final style in kInboxCardStyles) {
        await _pumpStyle(tester, style);
        final backdrop = find.byType(ImageFiltered);
        regionH[style.id] = backdrop.evaluate().isEmpty
            ? tester.getSize(find.byKey(kInboxCardCoverKey)).height
            : tester.getSize(backdrop).height;
        coverW[style.id] = tester.getSize(find.byKey(kInboxCardCoverKey)).width;
        cardHeights[style.id] = tester
            .getSize(find.byType(InboxCardStyleView))
            .height;
      }
      expect(
        regionH['classic'],
        closeTo(cardHeights['classic']! - 2, 1),
        reason: 'classic = 全出血氛围（模糊底衬铺满整卡，只差上下各 1px 描边）',
      );
      expect(
        regionH['minimal'],
        lessThan(regionH['classic']! / 2),
        reason: 'minimal = 小图居中留白（封面区就是 16:9 那么高）',
      );
      expect(
        regionH['editorial'],
        isNot(closeTo(regionH['banner']!, 1)),
        reason: 'editorial 与 banner 的图文比例必须不同',
      );
      expect(
        regionH['polaroid'],
        lessThan(regionH['classic']!),
        reason: 'polaroid 上下都有相纸留白',
      );
      expect(
        coverW['polaroid'],
        lessThan(coverW['classic']!),
        reason: 'polaroid 的照片左右各有一圈相纸',
      );
    });

    // -----------------------------------------------------------------------
    // ★ #1 封面不裁切（设备实测：除 minimal 外都在切左右，把图上的标题切断）
    // -----------------------------------------------------------------------

    testWidgets('#1 封面：每个风格都完整显示 16:9（左右不裁），区域不够就用模糊底衬补', (tester) async {
      _usePortraitPhone(tester);
      const realCover = 'https://i0.hdslb.com/bfs/archive/cover-16x9.jpg';
      for (final style in kInboxCardStyles) {
        await _pumpStyle(tester, style, item: _item(1, cover: realCover));

        final cardSize = tester.getSize(find.byType(InboxCardStyleView));
        final sharpFinder = find.byKey(kInboxCardCoverKey);
        final sharpSize = tester.getSize(sharpFinder);
        expect(
          sharpSize.width / sharpSize.height,
          closeTo(kInboxCoverAspect, 0.01),
          reason: '${style.id}：完整图必须落在 16:9 的框里'
              '（盖进更窄的框里 BoxFit.cover 会左右各裁 20%+ → 图上的字被切断）',
        );
        // 图本身走共享 CoverImage（防盗链头只有一处实现），盒子的宽高比就是原图比例
        final img = tester.widget<CoverImage>(
          find.descendant(of: sharpFinder, matching: find.byType(CoverImage)),
        );
        expect(img.cover, realCover);
        expect(img.width / img.height, closeTo(kInboxCoverAspect, 0.01),
            reason: '${style.id}：交给 CoverImage 的盒子必须是 16:9 → cover == contain，不裁');
        expect(img.width, closeTo(sharpSize.width, 0.01));

        // 封面区比 16:9 窄的风格，必须靠**同一张图的模糊底衬**补满剩下的区域
        //（不是把图裁掉铺满）；区域本身就是 16:9 的（minimal）则不需要底衬。
        final backdrop = find.byType(ImageFiltered);
        final regionW = backdrop.evaluate().isEmpty
            ? sharpSize.width
            : tester.getSize(backdrop).width;
        final regionH = backdrop.evaluate().isEmpty
            ? sharpSize.height
            : tester.getSize(backdrop).height;
        final regionIs169 =
            (regionW / regionH - kInboxCoverAspect).abs() < 0.02;
        if (!regionIs169) {
          expect(backdrop, findsOneWidget,
              reason: '${style.id}：区域比 16:9 窄 → 必须用同图模糊底衬补边');
        }
        // 底衬（有的话）与图都在卡片内
        expect(regionW, lessThanOrEqualTo(cardSize.width + 0.5));
        expect(regionH, lessThanOrEqualTo(cardSize.height + 0.5));
      }
    });

    testWidgets('#1 classic：模糊底衬铺满整卡 + 图**顶对齐**（上底衬为 0）+ 下缘渐变过渡',
        (tester) async {
      _usePortraitPhone(tester);
      await _pumpStyle(
        tester,
        inboxCardStyleById('classic'),
        item: _item(1, cover: 'https://i0.hdslb.com/bfs/archive/cover-16x9.jpg'),
      );

      final card = tester.getRect(find.byType(InboxCardStyleView));
      final backdrop = tester.getRect(find.byType(ImageFiltered));
      expect(backdrop.height, closeTo(card.height - 2, 1),
          reason: 'classic 的「全出血」靠底衬保住（1px 描边吃掉 2dp）');
      // 图比区域矮（下方留一条气氛底），说明确实没被拉高裁切
      final sharp = tester.getRect(find.byKey(kInboxCardCoverKey));
      expect(sharp.height, lessThan(backdrop.height));
      // ★ v2.21.0-r3：原来图上下居中 → 上方一条 ~149dp（约 30% 卡高）的裸露模糊区，
      //   与清晰图之间是一条硬边（亮/杂色封面下"像糊了一层灰纱"）。改成顶对齐 →
      //   上底衬 = 0，接缝从源头消掉；多余空间全给下方（那片被黑渐变遮罩压着）。
      expect(sharp.top, closeTo(backdrop.top, 1),
          reason: '清晰图贴上缘：上底衬为 0（接缝消失）');
      expect(backdrop.bottom - sharp.bottom, closeTo(backdrop.height - sharp.height, 1),
          reason: '多余的竖向空间全给下方');
      expect(
        (backdrop.height - sharp.height) / backdrop.height,
        greaterThan(0.4),
        reason: 'classic 仍是"图完整 + 大片气氛底"的全出血氛围，没有退回 cover 裁切',
      );
      // 下缘的过渡带：ShaderMask 只作用在清晰图上 → 与其同尺寸
      final fade = find.descendant(
        of: find.byType(InboxCardStyleView),
        matching: find.byType(ShaderMask),
      );
      expect(fade, findsOneWidget,
          reason: '清晰图下缘要有渐变过渡（否则与模糊底衬之间还是一条硬边）');
      expect(tester.getSize(fade).height, closeTo(sharp.height, 1));
      expect(kInboxClassicCoverFade, inInclusiveRange(16, 24),
          reason: '16–24dp：够抹平色带断层，又不吃掉封面下缘的内容');
      expect(kInboxClassicCoverFade, lessThan(sharp.height / 3),
          reason: '过渡带不能把整张图都淡掉');
    });

    // -----------------------------------------------------------------------
    // ★ #2 editorial：信息区不再留一个大空档（原来标题贴上、时长行贴下）
    // -----------------------------------------------------------------------

    testWidgets('#2 editorial：信息区文案整块居中 → 空档收紧、上下留白均分',
        (tester) async {
      _usePortraitPhone(tester);
      await _pumpStyle(tester, inboxCardStyleById('editorial'));

      final card = tester.getRect(find.byType(InboxCardStyleView));
      final up = tester.getRect(find.text('UP 主 1'));
      final title = tester.getRect(find.text('新视频 1'));
      final meta = tester.getRect(find.text('4:05'));
      // 标题块 → 时长行之间从"撑到底的大空档"收成一个固定小间距
      //（12 间距 + 1 版线 + 8 间距 ≈ 21dp；老实现约 130dp，1 行标题时最明显）
      expect(meta.top - title.bottom, lessThan(40),
          reason: '中间那一段纯白空档要收紧（原来是 Spacer 撑到底）');
      // 信息区里：上留白 ≈ 下留白（整块文案居中）
      final infoTop = tester.getRect(find.byType(ImageFiltered)).bottom + 1; // 版线
      final infoBottom = card.bottom - 1; // 1px 描边
      final topGap = up.top - infoTop;
      final bottomGap = infoBottom - meta.bottom;
      expect((topGap - bottomGap).abs(), lessThan(10),
          reason: '上下留白均分：印刷呼吸感还在，但不再"标题贴上、时长贴下"');
      expect(topGap, greaterThan(kSpace12), reason: '顶部仍留白，不贴版线');
    });

    // -----------------------------------------------------------------------
    // ★ #4 minimal：缩略图放大（划卡时看得出是什么视频）+ 留白上下分布
    // -----------------------------------------------------------------------

    testWidgets('#4 minimal：缩略图 ≥ 卡宽 0.85、上下留白均分', (tester) async {
      _usePortraitPhone(tester);
      await _pumpStyle(tester, inboxCardStyleById('minimal'));

      final card = tester.getRect(find.byType(InboxCardStyleView));
      final cover = tester.getRect(find.byKey(kInboxCardCoverKey));
      expect(
        cover.width,
        greaterThanOrEqualTo(card.width * 0.85),
        reason: '缩略图太小 → 划卡时看不出这是什么视频（62% → 84% → 90%）',
      );
      expect(cover.width, lessThan(card.width), reason: '两侧仍留白（极简气质）');
      expect(cover.width / cover.height, closeTo(kInboxCoverAspect, 0.01));
      final title = tester.getRect(find.text('新视频 1'));
      final meta = tester.getRect(find.textContaining('UP 主 1 · 4:05'));
      // 留白上下 1:1（老实现 flex 4:5：内容偏上、下方留一大片 → 反馈"下方大片白"）
      final topGap = cover.top - card.top;
      final bottomGap = card.bottom - meta.bottom;
      expect((topGap - bottomGap).abs(), lessThan(8),
          reason: '上下留白均分 → 内容重心落在卡片正中');
      expect(topGap, greaterThan(0), reason: '上留白还在（极简气质）');
      expect(title.bottom, lessThan(card.bottom - kSpace24),
          reason: '标题下面还有留白 → 是有呼吸感的留白，不是贴底');
    });
  });

  // -------------------------------------------------------------------------
  // 设置项：预览 + 切换
  // -------------------------------------------------------------------------

  group('设置项「信箱卡片样式」', () {
    testWidgets('入口存在 → 弹层列出全部风格（每项带缩略预览）→ 点选即生效并落盘', (tester) async {
      await _pumpPanel(tester);

      // 分区标题 + 入口按钮（按钮文案跟随当前风格）
      expect(find.text('信箱卡片样式'), findsOneWidget);
      final entry = find.text('卡片样式：经典满幅');
      expect(entry, findsOneWidget);

      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      // 弹层：标题一处 + 面板一处 = 2
      expect(find.text('信箱卡片样式'), findsNWidgets(2));
      // 每项一个缩略预览（复用同一个版式渲染器）
      expect(
        find.byType(InboxCardPreview),
        findsNWidgets(kInboxCardStyles.length),
      );
      for (final style in kInboxCardStyles) {
        expect(
          find.byKey(Key('inbox-card-style-option:${style.id}')),
          findsOneWidget,
          reason: '${style.id} 选项缺失',
        );
        expect(find.text(style.label), findsOneWidget);
        expect(find.text(style.description), findsOneWidget);
      }
      // 缩略预览本身也是扑克牌比例（144:200 之类，等比缩小）
      final preview = tester.getSize(find.byType(InboxCardPreview).first);
      expect(preview.height, closeTo(preview.width * kInboxCardAspect, 1));
      expect(preview.height, greaterThanOrEqualTo(48), reason: '缩略图要有辨识度');

      // 点选 → 立即生效 + 落盘 + 关弹层
      await tester.tap(
        find.byKey(const Key('inbox-card-style-option:polaroid')),
      );
      await tester.pumpAndSettle();

      expect(InboxCardStyleStore.instance.styleId, 'polaroid');
      expect(find.byType(InboxCardPreview), findsNothing, reason: '弹层应关闭');
      expect(find.text('卡片样式：宝丽来'), findsOneWidget, reason: '入口按钮文案要跟着切换走');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(InboxCardStyleStore.storageKey), 'polaroid');
    });
  });

  // -------------------------------------------------------------------------
  // 信箱页：监听 store，切换即换版式（尺寸不变）
  // -------------------------------------------------------------------------

  group('信箱页切换风格', () {
    testWidgets('store 变化 → 卡片栈立即换版式；尺寸不变、既有锚点都在', (tester) async {
      _usePortraitPhone(tester);
      ServiceLocator.overrideInboxService(
        _FakeInboxService([_item(1), _item(2)]),
      );
      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();

      InboxCardStyle topStyle() => tester
          .widget<InboxCardStyleView>(
            find.descendant(
              of: find.byType(InboxSwipeCard).last,
              matching: find.byType(InboxCardStyleView),
            ),
          )
          .style;

      expect(topStyle().id, 'classic');
      final before = tester.getSize(find.byType(InboxSwipeCard).last);
      expect(before.height, closeTo(before.width * kInboxCardAspect, 1));

      // 模拟设置页点选（同一个单例 store）
      await InboxCardStyleStore.instance.select('minimal');
      await tester.pumpAndSettle();

      expect(topStyle().id, 'minimal', reason: '切换后卡片栈要换版式');
      final after = tester.getSize(find.byType(InboxSwipeCard).last);
      expect(after.width, closeTo(before.width, 0.01));
      expect(
        after.height,
        closeTo(before.height, 0.01),
        reason: '所有版式同尺寸 → 切换不跳动',
      );

      // 既有锚点：卡片栈（当前 + 下一张）、底部按钮、卡片不出屏
      expect(find.byType(InboxSwipeCard), findsNWidgets(2));
      expect(find.text('跳过'), findsWidgets);
      expect(find.text('加入'), findsOneWidget);
      final rect = tester.getRect(find.byType(InboxSwipeCard).last);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(914));
    });

    testWidgets('切换风格后滑动仍生效（右滑加入链路不受版式影响）', (tester) async {
      _usePortraitPhone(tester);
      final service = _FakeInboxService([_item(1), _item(2)]);
      ServiceLocator.overrideInboxService(service);
      await InboxCardStyleStore.instance.select('polaroid');
      await tester.pumpWidget(const MaterialApp(home: InboxPage()));
      await tester.pumpAndSettle();

      expect(find.byType(InboxSwipeCard), findsNWidgets(2));
      // 左滑过阈值 → 出栈进入下一张（版本无关的行为断言）
      await tester.drag(
        find.byType(InboxSwipeCard).last,
        const Offset(-300, 0),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<InboxSwipeCard>(find.byType(InboxSwipeCard))
            .last
            .item
            .bvid,
        'BV2',
      );
    });
  });
}
