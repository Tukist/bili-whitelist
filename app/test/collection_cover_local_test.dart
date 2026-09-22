// 合集封面「本机相册选图」+ 一级合集编辑入口（v2.50.0）widget 测试。
//
// 三块必须可观测的验收点：
// 1. **用户报的 bug**：首页「合集」tab 的**一级**合集卡左滑有「封面」块，
//    点开能改（此前一级合集在合集页里没有可左滑的父卡片，只能绕到个人页 →
//    管理合集面板）；合集内页 AppBar 也能改**当前这个合集**；
// 2. **本机封面**（相册选的图）：渲染优先级 = 本机图 > Gist cover URL >
//    合集内第一个视频封面 > 占位；映射在但文件没了要回落 URL 而不是空白；
// 3. **不进 Gist**：只换本机图时**一个 PATCH 都不发**；而改 URL / 简介仍照旧
//    发一次 PATCH（既有行为一字未改）。
//
// 基建复刻 collection_meta_render_test.dart：mock secure storage + fake
// HttpClientAdapter 记录 PATCH 请求体；本机封面用临时目录作根目录
// （CollectionCoverStore.rootDirOverride），选图 mock `bili_whitelist/pick_image`
// 通道（与 schedule_import_test 同一条路子，页面不需要注入替身）。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/collection_cover_store.dart';
import 'package:bili_whitelist_app/services/image_pick_service.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/swipe_action_box.dart';

// ---------------------------------------------------------------------------
// 测试基建
// ---------------------------------------------------------------------------

/// 1×1 的合法 PNG（合成图，不涉任何用户数据）。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

late Directory _tmp;

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

/// mock 相册选图通道：[response] 就是原生侧返回的东西（null = 用户取消）。
void _mockPickChannel(Object? Function() response) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ImagePickService.channel, (call) async {
    return response();
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
}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 100,
      title: title,
      cover: cover,
      duration: 90,
      upName: 'UP主',
      addedAt: '2026-08-01T00:00:00Z',
      collection: collection,
    );

CollectionInfo _col(String name, {String cover = '', String desc = ''}) =>
    CollectionInfo(
      name: name,
      createdAt: '2026-08-01T00:00:00Z',
      cover: cover,
      desc: desc,
    );

WhitelistData _dataWith(
  List<WhitelistVideo> videos, {
  List<CollectionInfo> collections = const [],
}) =>
    WhitelistData(
      version: 4,
      updatedAt: '2026-08-20T00:00:00Z',
      videos: videos,
      collections: collections,
    );

/// 造一张「本机封面」（真写文件 + 真写 prefs）：返回写入的绝对路径。
Future<String> _seedLocalCover(String collectionPath) async {
  final store = CollectionCoverStore.instance;
  await store.ensureLoaded();
  await store.saveLocalCover(collectionPath, _png, fileName: 'seeded.png');
  return store.localCoverPath(collectionPath)!;
}

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
  await tester.pump(); // _load 完成
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

/// [finder] 子树里第一张网络图的 URL（没有 → null）。
String? _networkUrlUnder(WidgetTester tester, Finder finder) {
  final images = find.descendant(of: finder, matching: find.byType(Image));
  if (images.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(images.first).image;
  return provider is NetworkImage ? provider.url : null;
}

/// [finder] 子树里第一张**本机图片**的路径（不是本地图 → null）。
String? _filePathUnder(WidgetTester tester, Finder finder) {
  final images = find.descendant(of: finder, matching: find.byType(Image));
  if (images.evaluate().isEmpty) return null;
  final provider = tester.widget<Image>(images.first).image;
  return provider is FileImage ? provider.file.path : null;
}

/// 对话框预览区里的那张图（[AlertDialog] 子树，避开页面上的卡片封面）。
Finder get _dialogImage => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Image),
    );

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _tmp = Directory.systemTemp.createTempSync('cover_local_test');
    final store = CollectionCoverStore.instance;
    store.resetForTest();
    // 页面 `initState` 会用它加载映射（测试环境没有 path_provider）
    store.rootDirOverride = _tmp;
    _mockPickChannel(() => null); // 默认：用户取消
    SwipeActionBox.resetForTest();
  });

  tearDown(() {
    CollectionCoverStore.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ImagePickService.channel, null);
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('首页合集卡：本机封面优先级', () {
    testWidgets('本机图在 → 用它（不走 URL、也不走首个视频封面）', (tester) async {
      final localPath = await _seedLocalCover('动画');
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [
            _video('BV1', '视频A',
                collection: '动画', cover: 'https://i0.hdslb.com/video.jpg'),
          ],
          collections: [_col('动画', cover: 'https://i0.hdslb.com/gist.jpg')],
        ),
      );

      final card = _cardBlockOf(find.text('动画'));
      expect(_filePathUnder(tester, card), localPath);
      expect(_networkUrlUnder(tester, card), isNull, reason: '本机图优先，不再发请求');
      expect(
        tester.getSize(find.descendant(of: card, matching: find.byType(Image))),
        const Size(64, 64),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('映射在但文件没了 → 回落 Gist cover URL（不是空白，也不是占位）',
        (tester) async {
      final localPath = await _seedLocalCover('动画');
      File(localPath).deleteSync(); // 用户清了 App 缓存
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画', cover: 'https://i0.hdslb.com/video.jpg')],
          collections: [_col('动画', cover: 'https://i0.hdslb.com/gist.jpg')],
        ),
      );

      expect(
        _networkUrlUnder(tester, _cardBlockOf(find.text('动画'))),
        'https://i0.hdslb.com/gist.jpg',
      );
    });

    testWidgets('本机图在、Gist cover 空 → 仍用本机图（不回落首个视频封面）',
        (tester) async {
      final localPath = await _seedLocalCover('动画');
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画', cover: 'https://i0.hdslb.com/video.jpg')],
          collections: [_col('动画')],
        ),
      );

      expect(_filePathUnder(tester, _cardBlockOf(find.text('动画'))), localPath);
    });

    testWidgets('都没有 → 还是原来的占位图标（老数据零变化）', (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('空合集')],
        ),
      );

      final card = _cardBlockOf(find.text('空合集'));
      expect(_filePathUnder(tester, card), isNull);
      expect(_networkUrlUnder(tester, card), isNull);
      expect(
        find.descendant(
            of: card, matching: find.byIcon(Icons.video_library_outlined)),
        findsOneWidget,
      );
    });
  });

  group('首页一级合集卡左滑：新增「封面」块（用户报的 bug）', () {
    testWidgets('左滑露出四块：封面 / 移动 / 重命名 / 删除，每块 60dp、不撑破 360dp',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('音乐')],
        ),
      );

      expect(find.text('封面'), findsNothing, reason: '合上时不在树上');
      await _swipeCardLeft(tester, find.text('动画'));

      for (final label in ['封面', '移动', '重命名', '删除']) {
        final block = find.byKey(SwipeActionBox.actionKey(label));
        expect(block, findsOneWidget, reason: '「$label」这一块要露出来');
        final size = tester.getSize(block);
        expect(size.width, 60, reason: '四块必须收到 60dp 才放得下（与合集页子合集卡一致）');
        expect(size.width, greaterThanOrEqualTo(48), reason: '仍是合法触摸目标');
      }

      // 「别把 360dp 屏挤坏」：4 × 60 = 240dp ≤ 卡片可用宽（360 - 左右各 12）
      const cardWidth = 360.0 - 12 * 2;
      expect(60.0 * 4, lessThanOrEqualTo(cardWidth));
      final area = tester.getSize(find.byKey(SwipeActionBox.actionAreaKey));
      expect(area.width, lessThanOrEqualTo(cardWidth));
      expect(cardWidth - 60.0 * 4, greaterThanOrEqualTo(90),
          reason: '全露出后卡片本体仍留 ~96dp（封面 64 + 一截名字）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('四块顺序：封面在最左、删除在最右（与合集页子合集卡一致）',
        (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('音乐')],
        ),
      );
      await _swipeCardLeft(tester, find.text('动画'));

      double x(String label) =>
          tester.getCenter(find.byKey(SwipeActionBox.actionKey(label))).dx;
      expect(x('封面'), lessThan(x('移动')));
      expect(x('移动'), lessThan(x('重命名')));
      expect(x('重命名'), lessThan(x('删除')));
    });

    testWidgets('「未分类」不是合集 → 连「封面」块也没有', (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画')],
        ),
      );
      await _swipeCardLeft(tester, find.text('未分类'));
      for (final label in ['封面', '移动', '重命名', '删除']) {
        expect(find.text(label), findsNothing);
      }
    });

    testWidgets('点「封面」→ 打开对话框；改简介保存 → 一级合集的 PATCH 带上新值',
        (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('音乐')],
        ),
      );

      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.byKey(SwipeActionBox.actionKey('封面')));
      await tester.pumpAndSettle();

      expect(find.text('封面与简介「动画」'), findsOneWidget,
          reason: '一级合集也能就地打开这个对话框（此前只能绕管理面板）');
      await tester.enterText(
          find.widgetWithText(TextField, '简介'), '一级合集的简介');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(_savedCollectionJson(ctx.adapter, '动画'), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
        'desc': '一级合集的简介',
      });
      expect(find.text('一级合集的简介'), findsOneWidget, reason: '卡片当场多一行简介');
    });
  });

  group('合集内页 AppBar「编辑封面与简介」', () {
    testWidgets('一级合集页：改的是**当前这个合集**（顶层也能改）', (tester) async {
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('音乐')],
        ),
      );

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('编辑封面与简介'), findsOneWidget);
      await tester.tap(find.byTooltip('编辑封面与简介'));
      await tester.pumpAndSettle();

      expect(find.text('封面与简介「动画」'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, '封面图片 URL'), 'https://i0.hdslb.com/a.jpg');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(_savedCollectionJson(ctx.adapter, '动画'), {
        'name': '动画',
        'created_at': '2026-08-01T00:00:00Z',
        'cover': 'https://i0.hdslb.com/a.jpg',
      });
      expect(
        _savedCollectionJson(ctx.adapter, '音乐').containsKey('cover'),
        isFalse,
        reason: '别的合集不被波及',
      );
    });

    testWidgets('未分类页没有这个入口（未分类不是合集，没有封面可设）', (tester) async {
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '')],
          collections: [_col('动画')],
        ),
      );

      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('编辑封面与简介'), findsNothing);
      expect(find.byTooltip('新建子合集'), findsNothing);
    });
  });

  group('本机封面：对话框（预览 / 选图 / 移除）', () {
    /// 从首页一级卡左滑「封面」打开对话框。
    Future<({_FakeAdapter adapter, GithubApi github})> openDialogFromCard(
      WidgetTester tester, {
      String gistCover = '',
      bool seedLocal = false,
    }) async {
      if (seedLocal) await _seedLocalCover('动画');
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画', cover: gistCover), _col('音乐')],
        ),
      );
      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.byKey(SwipeActionBox.actionKey('封面')));
      await tester.pumpAndSettle();
      return ctx;
    }

    testWidgets('没封面时预览只给一句提示；有本机图时预览显示的是本机图',
        (tester) async {
      final ctx = await openDialogFromCard(tester);
      expect(find.text('未设置封面'), findsOneWidget);
      expect(_dialogImage, findsNothing, reason: '既没本机图也没 URL → 预览里没有图');
      // 本机可见性必须写在明面上（用户会以为"换手机也在"）
      expect(find.textContaining('只存在这台设备上'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(ctx.adapter.requests, isEmpty);
    });

    testWidgets('已有本机封面时：预览显示这张本机图，并给「移除本机封面」入口',
        (tester) async {
      final localPath = await _seedLocalCover('动画');
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画', cover: 'https://i0.hdslb.com/gist.jpg')],
        ),
      );
      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.byKey(SwipeActionBox.actionKey('封面')));
      await tester.pumpAndSettle();

      expect(find.text('未设置封面'), findsNothing);
      final preview = tester.widget<Image>(_dialogImage).image;
      expect(preview, isA<FileImage>());
      expect((preview as FileImage).file.path, localPath,
          reason: '本机图优先于 URL');
      expect(find.text('移除本机封面'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(ctx.adapter.requests, isEmpty);
    });

    testWidgets('从相册选图 → 预览换成新图 → 保存：图片落本机、**不发 PATCH**、卡片当场换图',
        (tester) async {
      _mockPickChannel(() => <Object?, Object?>{
            'name': 'IMG_9.png',
            'size': _png.length,
            'bytes': _png,
          });
      final ctx = await openDialogFromCard(
        tester,
        gistCover: 'https://i0.hdslb.com/gist.jpg',
        seedLocal: true,
      );
      final requestsBefore = ctx.adapter.requests.length;

      expect(_dialogImage, findsOneWidget);
      final oldImage = tester.widget<Image>(_dialogImage).image;
      await tester.tap(find.text('从相册选图'));
      await tester.pumpAndSettle();

      final picked = tester.widget<Image>(_dialogImage).image;
      expect(picked, isA<MemoryImage>(), reason: '预览当场换成刚选的图');
      expect(picked, isNot(oldImage));

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // 本机封面：映射 + 文件都在，且换了新的文件名（旧的删掉）
      final store = CollectionCoverStore.instance;
      final newPath = store.localCoverPath('动画');
      expect(newPath, isNotNull);
      expect(File(newPath!).existsSync(), isTrue);
      expect(File(newPath).readAsBytesSync(), _png);
      expect(store.debugMapping.keys, contains('动画'));

      expect(ctx.adapter.requests.length, requestsBefore,
          reason: '只换本机图 → 一个 PATCH 都不该发（本机封面不进 Gist）');
      // 首页卡片当场换成本机图
      expect(_filePathUnder(tester, _cardBlockOf(find.text('动画'))), newPath);
    });

    testWidgets('取消选图（原生回 null）→ 什么都不改、不报错', (tester) async {
      _mockPickChannel(() => null);
      final ctx = await openDialogFromCard(tester);
      final before = CollectionCoverStore.instance.debugMapping;
      final requestsBefore = ctx.adapter.requests.length;

      await tester.tap(find.text('从相册选图'));
      await tester.pumpAndSettle();

      expect(find.text('未设置封面'), findsOneWidget, reason: '预览没变');
      expect(CollectionCoverStore.instance.debugMapping, before);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(CollectionCoverStore.instance.localCoverPath('动画'), isNull);
      expect(ctx.adapter.requests.length, requestsBefore, reason: '什么都没改 → 0 PATCH');
    });

    testWidgets('选图失败 → 对话框里一句中文提示，不崩、不落任何东西', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ImagePickService.channel, (call) async {
        throw PlatformException(code: 'READ_FAILED', message: '打不开这张图片');
      });
      final ctx = await openDialogFromCard(tester);

      await tester.tap(find.text('从相册选图'));
      await tester.pumpAndSettle();

      expect(find.text('读取图片失败：打不开这张图片'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(CollectionCoverStore.instance.localCoverPath('动画'), isNull);
      expect(ctx.adapter.requests, isEmpty);
    });

    testWidgets('「移除本机封面」→ 预览回落 URL、文件与映射都清掉、**0 PATCH**',
        (tester) async {
      const url = 'https://i0.hdslb.com/gist.jpg';
      final localPath = await _seedLocalCover('动画');
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画', cover: url), _col('音乐')],
        ),
      );
      expect(_filePathUnder(tester, _cardBlockOf(find.text('动画'))), localPath);
      final requestsBefore = ctx.adapter.requests.length;

      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.byKey(SwipeActionBox.actionKey('封面')));
      await tester.pumpAndSettle();

      expect(find.text('移除本机封面'), findsOneWidget);
      await tester.tap(find.text('移除本机封面'));
      await tester.pumpAndSettle();

      expect(_networkUrlUnder(tester, find.byType(AlertDialog)), url,
          reason: '预览回落到 Gist cover URL');

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(CollectionCoverStore.instance.localCoverPath('动画'), isNull);
      expect(File(localPath).existsSync(), isFalse, reason: '文件也删掉（不留孤儿）');
      expect(ctx.adapter.requests.length, requestsBefore, reason: '移除本机图 ≠ 改 URL');
      expect(_networkUrlUnder(tester, _cardBlockOf(find.text('动画'))), url,
          reason: '卡片回落到 URL');
    });

    testWidgets('没有本机封面时不显示「移除本机封面」', (tester) async {
      await openDialogFromCard(tester, gistCover: 'https://i0.hdslb.com/a.jpg');
      expect(find.text('移除本机封面'), findsNothing);
    });

    testWidgets('协议相对的封面 URL（`//host/x.jpg`）保存时补 https:，卡片也按补好的加载',
        (tester) async {
      final ctx = await openDialogFromCard(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '封面图片 URL'),
        '//i0.hdslb.com/cover.jpg',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(
        _savedCollectionJson(ctx.adapter, '动画')['cover'],
        'https://i0.hdslb.com/cover.jpg',
        reason: '只补协议，不做别的改写',
      );
      expect(
        _networkUrlUnder(tester, _cardBlockOf(find.text('动画'))),
        'https://i0.hdslb.com/cover.jpg',
      );
    });
  });

  group('路径搬迁：改合集路径后本机封面不丢', () {
    testWidgets('首页左滑重命名 → 映射 key 跟着换，卡片仍用同一张本机图', (tester) async {
      final localPath = await _seedLocalCover('动画');
      final ctx = await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画')],
          collections: [_col('动画'), _col('音乐')],
        ),
      );

      await _swipeCardLeft(tester, find.text('动画'));
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '番剧');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(_savedCollectionJson(ctx.adapter, '番剧')['name'], '番剧');
      final store = CollectionCoverStore.instance;
      expect(store.localCoverPath('番剧'), localPath, reason: 'key 搬到新路径');
      expect(store.localCoverPath('动画'), isNull, reason: '旧路径不再有映射');
      expect(File(localPath).existsSync(), isTrue, reason: '文件不删（只换 key）');
      expect(_filePathUnder(tester, _cardBlockOf(find.text('番剧'))), localPath);
      expect(find.text('番剧'), findsOneWidget);
    });

    testWidgets('合集页删除子合集 → 它的本机封面（映射 + 文件）一起清掉',
        (tester) async {
      final subPath = await _seedLocalCover('动画/2024冬');
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
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(ctx.adapter.requests.last.method, 'PATCH');
      expect(CollectionCoverStore.instance.localCoverPath('动画/2024冬'), isNull);
      expect(File(subPath).existsSync(), isFalse);
      expect(find.text('2024冬'), findsNothing);
    });

    testWidgets('合集页子合集移入另一合集 → 映射跟着新路径走', (tester) async {
      final localPath = await _seedLocalCover('动画/2024冬');
      await _pumpHomeWithGithub(
        tester,
        _dataWith(
          [_video('BV1', '视频A', collection: '动画/2024冬')],
          collections: [_col('动画'), _col('动画/2024冬'), _col('音乐')],
        ),
      );

      await tester.tap(find.text('动画'));
      await tester.pumpAndSettle();
      await _swipeCardLeft(tester, find.text('2024冬'));
      await tester.tap(find.text('移动'));
      await tester.pumpAndSettle();
      // 目标选择器里点「音乐」
      await tester.tap(find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('音乐'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '移动'));
      await tester.pumpAndSettle();

      final store = CollectionCoverStore.instance;
      expect(store.localCoverPath('音乐/2024冬'), localPath);
      expect(store.localCoverPath('动画/2024冬'), isNull);
    });
  });
}
