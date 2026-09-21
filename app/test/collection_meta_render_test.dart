// 合集封面 / 简介（v2.38.0）UI 测试：
// - 首页合集卡：有简介 → 显示（2 行截断）；无简介 → 那一行**根本不在树上**
//   （既有文案 'N 个视频' / '含 N 个子合集' / '已看 X/Y' 逐字不变）；
//   封面优先级 = 合集自设 cover > 合集内第一个视频的封面 > 占位图标；
// - 子合集卡（合集页）：有 cover → 显示图（40×40）；无 cover → 保持原来的
//   文件夹图标（folder_outlined）；有 desc → 多一行，无 desc → 不占位；
// - 编辑入口：首页管理面板「编辑封面与简介」与子合集卡左滑「封面」都打开同一个
//   对话框；保存 → PATCH 出去的 whitelist.json 里那个合集带上 cover/desc，
//   其它合集一个字段都不多；取消 / 没改动 → 一个 PATCH 都不发；
// - 留空 = 清空（字段从 JSON 里彻底消失）。
//
// 基建复刻 collection_page_test.dart：mock secure storage + fake
// HttpClientAdapter 记录 PATCH 请求体。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/swipe_action_box.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

final Map<String, String> _store = {};

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?) ?? const {};
        switch (call.method) {
          case 'read':
            return _store[args['key'] as String?];
          case 'write':
            final key = args['key'] as String?;
            if (key == null) return false;
            _store[key] = args['value'] as String? ?? '';
            return true;
          case 'delete':
            _store.remove(args['key'] as String?);
            return true;
          case 'readAll':
            return Map<String, String>.from(_store);
          case 'deleteAll':
            _store.clear();
            return true;
          default:
            return null;
        }
      });
}

class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeSyncService extends WhitelistSyncService {
  final WhitelistData data;

  _FakeSyncService(this.data) : super(dio: Dio());

  @override
  Future<SyncResult> sync() async => SyncResult(
    data: data,
    sourceName: 'fake',
    fetchedAt: DateTime(2026, 1, 1),
    fromNetwork: false,
  );

  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

WhitelistVideo _video(
  String bvid,
  String title, {
  String collection = '',
  String cover = '',
}) => WhitelistVideo(
  bvid: bvid,
  cid: 100,
  title: title,
  cover: cover,
  duration: 90,
  upName: 'UP主',
  addedAt: '2026-08-01T00:00:00Z',
  collection: collection,
);

WhitelistData _dataWith(
  List<WhitelistVideo> videos, {
  List<CollectionInfo> collections = const [],
}) => WhitelistData(
  version: 4,
  updatedAt: '2026-08-20T00:00:00Z',
  videos: videos,
  collections: collections,
);

CollectionInfo _col(String name, {String cover = '', String desc = ''}) =>
    CollectionInfo(
      name: name,
      createdAt: '2026-08-01T00:00:00Z',
      cover: cover,
      desc: desc,
    );

Future<({_FakeAdapter adapter, GithubApi github})> _pumpHomeWithGithub(
  WidgetTester tester,
  WhitelistData data,
) async {
  _store.clear();
  _mockSecureStorage();
  _store[GithubApi.kTokenKey] = 'ghp_fake';
  _store[GithubApi.kGistIdKey] = 'gist1';
  // 注入「会话有效」的合成 SESSDATA，让首页静默启动（不弹含 WebView 的登录页）
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
  final adapter = _FakeAdapter();
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  final github = GithubApi(dio: dio);
  ServiceLocator.overrideSyncService(_FakeSyncService(data));
  await tester.pumpWidget(MaterialApp(home: PlaylistPage(github: github)));
  await tester.pump();
  await tester.pump();
  return (adapter: adapter, github: github);
}

Future<void> _swipeCardLeft(WidgetTester tester, Finder card) async {
  final gesture = await tester.startGesture(tester.getCenter(card));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.moveBy(const Offset(-160, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 包含 [inside] 文案的那张卡的块底板。
Finder _cardBlockOf(Finder inside) =>
    find.ancestor(of: inside, matching: find.byType(AppBlock)).first;

Map<String, dynamic> _savedGistJson(_FakeAdapter adapter) {
  final payload = adapter.requests.last.data as Map<String, dynamic>;
  final files = payload['files'] as Map<String, dynamic>;
  final content =
      (files['whitelist.json'] as Map<String, dynamic>)['content'] as String;
  return jsonDecode(content) as Map<String, dynamic>;
}

Map<String, dynamic> _savedCollectionJson(_FakeAdapter adapter, String name) {
  final cols = (_savedGistJson(adapter)['collections'] as List)
      .cast<Map<String, dynamic>>();
  return cols.firstWhere((c) => c['name'] == name);
}

/// [finder] 子树里第一张网络图的 URL（没有 → null）。
String? _networkUrlUnder(WidgetTester tester, Finder finder) {
  final images = find.descendant(of: finder, matching: find.byType(Image));
  if (images.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(images.first).image;
  return provider is NetworkImage ? provider.url : null;
}

/// 打开首页 → 个人页 → 管理合集面板（既有导航路径）。
Future<void> _openManageSheet(WidgetTester tester) async {
  await tester.tap(find.byTooltip('个人（观看统计 / 设置）'));
  await tester.pumpAndSettle();
  for (var i = 0; i < 10 && find.text('管理合集').evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text('管理合集'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('管理合集'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('首页合集卡：简介', () {
    testWidgets('有简介 → 显示（2 行截断）；无简介 → 那一行不在树上，既有文案逐字不变',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画', desc: '这是一句话简介'), _col('音乐')],
        ),
      );

      final descText = find.byKey(collectionDescKey('动画'));
      expect(descText, findsOneWidget);
      expect(tester.widget<Text>(descText).data, '这是一句话简介');
      expect(tester.widget<Text>(descText).maxLines, 2);

      // 无简介的卡片：那一行**不存在**（不是「渲染成空串」）
      expect(find.byKey(collectionDescKey('音乐')), findsNothing);
      expect(find.byKey(collectionDescKey('未分类')), findsNothing);
      // 既有文案锚点逐字保留（动画 1 个视频；音乐 / 未分类 各 0 个）
      expect(find.text('0 个视频'), findsNWidgets(2));
      expect(find.text('1 个视频'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('首页合集卡：封面', () {
    testWidgets('合集自设 cover → 用它（而不是合集内第一个视频的封面）',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A',
                collection: '动画', cover: 'https://i0.hdslb.com/video.jpg'),
          ],
          collections: [
            _col('动画', cover: 'https://i0.hdslb.com/collection.jpg'),
          ],
        ),
      );

      final card = _cardBlockOf(find.text('动画'));
      expect(_networkUrlUnder(tester, card),
          'https://i0.hdslb.com/collection.jpg');
      expect(
        tester.getSize(find.descendant(of: card, matching: find.byType(Image))),
        const Size(64, 64),
      );
    });

    testWidgets('合集没设 cover → 回落「合集内第一个视频的封面」（改动前的行为）',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A',
                collection: '动画', cover: 'https://i0.hdslb.com/video.jpg'),
          ],
          collections: [_col('动画')],
        ),
      );

      expect(_networkUrlUnder(tester, _cardBlockOf(find.text('动画'))),
          'https://i0.hdslb.com/video.jpg');
    });

    testWidgets('合集没设 cover 且里面没视频 → 占位图标（与改动前一致）',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          // 另一个合集里有视频：首页有数据才走「卡片列表」（全空会走空态视图）
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('空合集')],
        ),
      );

      final card = _cardBlockOf(find.text('空合集'));
      expect(_networkUrlUnder(tester, card), isNull);
      expect(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.video_library_outlined),
        ),
        findsOneWidget,
      );
    });
  });

  group('合集页子合集卡：封面 / 简介', () {
    /// 进「动画」合集页（里面有一个子合集「2024冬」）。
    Future<({_FakeAdapter adapter, GithubApi github})> openAnimePage(
      WidgetTester tester, {
      String subCover = '',
      String subDesc = '',
    }) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画/2024冬')],
          collections: [
            _col('动画'),
            _col('动画/2024冬', cover: subCover, desc: subDesc),
          ],
        ),
      );
      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();
      return ctx;
    }

    testWidgets('子合集有 cover / desc → 显示图（40×40）与简介', (tester) async {
      await openAnimePage(
        tester,
        subCover: 'https://i0.hdslb.com/sub.jpg',
        subDesc: '子合集简介',
      );

      final sub = find.byKey(const ValueKey('sub-动画/2024冬'));
      expect(sub, findsOneWidget);
      expect(_networkUrlUnder(tester, sub), 'https://i0.hdslb.com/sub.jpg');
      expect(
        tester.getSize(find.descendant(of: sub, matching: find.byType(Image))),
        const Size(40, 40),
      );
      expect(
        find.descendant(of: sub, matching: find.text('子合集简介')),
        findsOneWidget,
      );
      // 既有文案锚点逐字保留
      expect(find.text('1 个视频'), findsOneWidget);
      // 网络图在测试环境必然加载失败（无网）→ errorBuilder 兜底成文件夹图标，
      // 这正是「图挂了也不会留一块空洞」的行为，所以这里断言它**在**。
      expect(
        find.descendant(of: sub, matching: find.byIcon(Icons.folder_outlined)),
        findsOneWidget,
        reason: '加载失败时兜底文件夹图标（不能是空白）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('子合集没 cover / 没 desc → 与改动前一致（文件夹图标 + 一行统计）',
        (tester) async {
      await openAnimePage(tester);

      final sub = find.byKey(const ValueKey('sub-动画/2024冬'));
      expect(_networkUrlUnder(tester, sub), isNull);
      expect(
        find.descendant(of: sub, matching: find.byIcon(Icons.folder_outlined)),
        findsOneWidget,
      );
      // 子合集卡里没有异步统计节点 → Text 数量是确定的：局部名 + 一行统计
      expect(
        find.descendant(of: sub, matching: find.byType(Text)),
        findsNWidgets(2),
        reason: '没有第三行简介',
      );
      expect(find.text('2024冬'), findsOneWidget);
      expect(find.text('1 个视频'), findsOneWidget);
    });

    testWidgets('子合集卡左滑四块：封面 / 移动 / 重命名 / 删除，宽度 60 不撑破 360dp',
        (tester) async {
      await openAnimePage(tester);
      await _swipeCardLeft(tester, find.text('2024冬'));

      for (final label in ['封面', '移动', '重命名', '删除']) {
        final block = find.byKey(SwipeActionBox.actionKey(label));
        expect(block, findsOneWidget, reason: '「$label」这一块要露出来');
        final size = tester.getSize(block);
        expect(size.width, 60, reason: 'actionWidth 从 76 收到 60 才放得下 4 块');
        expect(size.width, greaterThanOrEqualTo(48), reason: '仍是合法触摸目标');
      }
      // 卡片可用宽 = 360 - 页内边距 12×2 - 子合集行自己再收 12×2
      const subCardWidth = 360.0 - 12 * 2 - 12 * 2;
      expect(60.0 * 4, lessThanOrEqualTo(subCardWidth));
      expect(subCardWidth - 60.0 * 4, greaterThanOrEqualTo(60),
          reason: '至少留 60dp 卡片可见');
      expect(tester.takeException(), isNull);
    });
  });

  group('编辑入口：首页管理面板', () {
    testWidgets('面板同时有四个入口；填完保存 → PATCH 带上 cover/desc，别的合集不受影响',
        (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('音乐', desc: '原有简介')],
        ),
      );

      await _openManageSheet(tester);
      // 新增入口（两行合集 → 两个），既有三个入口一个不少
      expect(find.byTooltip('编辑封面与简介'), findsNWidgets(2));
      expect(find.byTooltip('移动到其他合集'), findsNWidgets(2));
      expect(find.byTooltip('重命名'), findsNWidgets(2));
      expect(find.byTooltip('删除'), findsNWidgets(2));

      await tester.tap(find.byTooltip('编辑封面与简介').first);
      await tester.pumpAndSettle();

      expect(find.text('封面与简介「动画」'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '封面图片 URL'),
        'https://i0.hdslb.com/cover.jpg',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '简介'),
        '合集简介文案',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(_savedCollectionJson(ctx.adapter, '动画'), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
        'cover': 'https://i0.hdslb.com/cover.jpg',
        'desc': '合集简介文案',
      });
      expect(_savedCollectionJson(ctx.adapter, '音乐'), {
        'name': '音乐',
        'created_at': '2026-08-01T00:00:00Z',
        'desc': '原有简介',
      }, reason: '别的合集一个字节都不变');
      // 注：此时在「个人」页，首页的合集列表不在树上（PageView 只建当前页），
      // 「保存后卡片当场显示」由下面子合集卡那条用例断言。
    });

    testWidgets('留空保存 = 清空（字段从 JSON 里彻底消失）', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [
            _col('动画', cover: 'https://old/cover.jpg', desc: '旧简介'),
          ],
        ),
      );

      await _openManageSheet(tester);
      await tester.tap(find.byTooltip('编辑封面与简介'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '封面图片 URL'), '');
      await tester.enterText(find.widgetWithText(TextField, '简介'), '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(_savedCollectionJson(ctx.adapter, '动画'), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
      });
      expect(find.text('旧简介'), findsNothing);
    });

    testWidgets('一个字段都没改 → 不发 PATCH', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画', desc: '简介')],
        ),
      );
      await _openManageSheet(tester);
      final before = ctx.adapter.requests.length;

      await tester.tap(find.byTooltip('编辑封面与简介').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(ctx.adapter.requests.length, before, reason: '没改就不该写 Gist');
    });

    testWidgets('取消对话框 → 不发 PATCH', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画')],
        ),
      );
      await _openManageSheet(tester);
      final before = ctx.adapter.requests.length;

      await tester.tap(find.byTooltip('编辑封面与简介').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '封面图片 URL'),
        'https://x/y.jpg',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(ctx.adapter.requests.length, before);
    });
  });

  group('编辑入口：子合集卡左滑「封面」', () {
    testWidgets('点左滑「封面」→ 同一个对话框 → 保存 → PATCH 里子合集带上新值',
        (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画/2024冬')],
          collections: [_col('动画'), _col('动画/2024冬')],
        ),
      );
      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      await _swipeCardLeft(tester, find.text('2024冬'));
      await tester.tap(find.byKey(SwipeActionBox.actionKey('封面')));
      await tester.pumpAndSettle();

      expect(find.text('封面与简介「动画 / 2024冬」'), findsOneWidget,
          reason: '标题用全路径，免得在深层页面里改错合集');
      await tester.enterText(find.widgetWithText(TextField, '简介'), '冬季番合集');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(_savedCollectionJson(ctx.adapter, '动画/2024冬'), {
        'name': '动画/2024冬',
        'created_at': '2026-08-01T00:00:00Z',
        'desc': '冬季番合集',
      });
      expect(
        _savedCollectionJson(ctx.adapter, '动画').containsKey('desc'),
        isFalse,
        reason: '父合集不被波及（不做级联）',
      );
      expect(find.text('冬季番合集'), findsOneWidget, reason: '卡片当场多一行简介');
    });
  });
}
