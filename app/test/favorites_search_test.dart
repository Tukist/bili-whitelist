// 收藏夹内搜索（v2.17.11+）测试：
// - filterFavoriteVideosByKeyword 纯函数：空白关键词原样返回 / 标题子串匹配
//   （大小写不敏感）/ UP 主名匹配 / 无匹配空列表
// - FavoriteVideosPage 搜索流程 widget 测试（BiliApi 注入路由 mock adapter）：
//   - 输入防抖 400ms：防抖窗口内不触发拉全量；到期后自动翻页拉全夹（跨页
//     匹配的条目能搜到）→ 本地过滤展示；点结果 → view 补全 → 播放回调
//   - 清空（X 按钮）→ 恢复整夹直显（全量已在内存，不再发翻页请求）
//   - 无匹配 → 「未找到匹配的视频」
//   - 拉全量中途失败（第 2 页 -412）→ snack 提示 + 退出搜索回到分页浏览
// 不访问真实网络；不构建真实 LoginPage / PlayerPage（注入 openLogin /
// openPlayer 替身）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart'
    hide FavoriteVideosPage;
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/favorite_videos_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存版 secure storage。
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
      default:
        return null;
    }
  });
}

class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 按 path 路由的 BiliApi mock adapter（记录全部请求）。
class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function(RequestOptions options)>
      handlers;
  final List<RequestOptions> requests = [];

  _RoutingAdapter(this.handlers);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final handler = handlers[options.path];
    return ResponseBody.fromString(
      jsonEncode(
        handler?.call(options) ??
            {'code': -1, 'message': 'no handler: ${options.path}'},
      ),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// nav 响应：code=0 登录态（带 wbi_img 供 view 接口的 WBI 签名）。
Map<String, dynamic> _navBody() => {
      'code': 0,
      'message': 'OK',
      'data': {
        'isLogin': true,
        'mid': 123456,
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

/// 夹内视频页响应（medias + count + has_more）。
Map<String, dynamic> _favPageBody(
  List<Map<String, dynamic>> medias, {
  required bool hasMore,
}) =>
    {
      'code': 0,
      'message': 'success',
      'data': {
        'count': medias.length,
        'has_more': hasMore,
        'medias': medias,
      },
    };

Map<String, dynamic> _favMedia(
  String bvid,
  String title, {
  String up = 'UP甲',
}) =>
    {
      'id': 1,
      'type': 2, // 视频
      'bvid': bvid,
      'cid': 1,
      'title': title,
      'cover': '',
      'upper': {'mid': 1, 'name': up},
      'duration': 300,
      'pubtime': 1589627926,
    };

/// view 接口 data（videoFromMeta 用字段）。
Map<String, dynamic> _viewData(String bvid) => {
      'bvid': bvid,
      'cid': 1001,
      'title': '详情$bvid',
      'pic': '',
      'duration': 300,
      'owner': {'mid': 1, 'name': 'UP甲'},
      'pages': [
        {'cid': 1001, 'part': 'P1', 'duration': 300},
      ],
      'pubdate': 1589627926,
      'desc': '简介$bvid',
    };

BiliApi _makeApi(_RoutingAdapter adapter) => BiliApi(
      dio: Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()))
        ..httpClientAdapter = adapter,
    );

void _seedValidSession() {
  final expireSec =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
          1000;
  _store['bili_sessdata'] = '12345,$expireSec,${'a' * 32}';
}

WhitelistVideo _shell(String bvid, String title, String upName) =>
    WhitelistVideo(
      bvid: bvid,
      cid: 0,
      title: title,
      cover: '',
      duration: 300,
      upName: upName,
      addedAt: '2026-01-01T00:00:00.000Z',
    );

/// 收藏夹 3 页（跨页搜索素材）：第 1 页 2 条 + 第 2 页 2 条 + 第 3 页 1 条。
final _page1 = [
  _favMedia('BV-s1', '【收藏】AI 绘画教程'),
  _favMedia('BV-s2', 'Python 爬虫实战', up: 'UP乙'),
];
final _page2 = [
  _favMedia('BV-s3', '收藏的混剪 MAD'),
  _favMedia('BV-s4', 'AI 修复老照片', up: 'UP乙'),
];
final _page3 = [_favMedia('BV-s5', '凉拌黄瓜做法', up: 'UP丙')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    ServiceLocator.overrideSyncService(_FakeSyncService());
  });

  group('filterFavoriteVideosByKeyword 纯函数', () {
    final videos = [
      _shell('BV-a', '【泛式】ChatGPT 动画杂谈', '泛式'),
      _shell('BV-b', 'T.E.I.O 剧情 MAD', '泛式'),
      _shell('BV-c', '某科技测评', '影视飓风'),
    ];

    test('空白关键词 → 原样返回（不过滤）', () {
      expect(filterFavoriteVideosByKeyword(videos, ''), same(videos));
      expect(filterFavoriteVideosByKeyword(videos, '   '), same(videos));
    });

    test('关键词命中标题 → 只保留匹配项', () {
      final r = filterFavoriteVideosByKeyword(videos, 'MAD');
      expect(r.map((v) => v.bvid), ['BV-b']);
    });

    test('标题匹配大小写不敏感', () {
      final r = filterFavoriteVideosByKeyword(videos, 'chatgpt');
      expect(r.map((v) => v.bvid), ['BV-a']);
    });

    test('关键词命中 UP 主名 → 匹配（不只搜标题）', () {
      final r = filterFavoriteVideosByKeyword(videos, '影视飓风');
      expect(r.map((v) => v.bvid), ['BV-c']);
    });

    test('无匹配 → 空列表', () {
      expect(
        filterFavoriteVideosByKeyword(videos, 'qwertyuiop'),
        isEmpty,
      );
    });
  });

  group('FavoriteVideosPage 夹内搜索', () {
    testWidgets('输入防抖：窗口内不拉全量；到期自动拉全夹（跨页匹配可搜到）'
        '；点结果补 cid 播放', (tester) async {
      _seedValidSession();
      final played = <WhitelistVideo>[];
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (o) {
          final pn = int.tryParse(o.queryParameters['pn'] as String? ?? '1') ??
              1;
          return switch (pn) {
            1 => _favPageBody(_page1, hasMore: true),
            2 => _favPageBody(_page2, hasMore: true),
            _ => _favPageBody(_page3, hasMore: false),
          };
        },
        '/x/web-interface/view': (o) {
          final bvid = o.queryParameters['bvid'] as String? ?? '';
          return {'code': 0, 'data': _viewData(bvid)};
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '搜索夹',
            api: _makeApi(adapter),
            openLogin: (context, {banner}) async {},
            openPlayer: (context, video) async => played.add(video),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 首屏 = 分页浏览第 1 页（未搜索不拉全量）
      expect(find.text('【收藏】AI 绘画教程'), findsOneWidget);
      expect(find.text('凉拌黄瓜做法'), findsNothing); // 第 3 页还没拉
      int resourceCalls() => adapter.requests
          .where((r) => r.path == '/x/v3/fav/resource/list')
          .length;
      expect(resourceCalls(), 1);

      // 输入关键词：防抖 400ms 内不触发拉全量
      await tester.enterText(find.byType(TextField), 'ai');
      await tester.pump(const Duration(milliseconds: 200));
      expect(resourceCalls(), 1); // 仍在防抖窗口

      // 防抖到期 → 自动翻页拉全夹（pn=1,2,3）→ 本地过滤展示
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(resourceCalls(), 4); // 首屏 1 次 + 拉全量 3 次
      // 跨页匹配：第 1 页「AI 绘画教程」+ 第 2 页「AI 修复老照片」都搜到
      expect(find.text('【收藏】AI 绘画教程'), findsOneWidget);
      expect(find.text('AI 修复老照片'), findsOneWidget);
      expect(find.text('Python 爬虫实战'), findsNothing); // 未匹配
      expect(find.text('凉拌黄瓜做法'), findsNothing);

      // 点搜索结果 → view 补全 → 播放回调（收到完整视频）
      await tester.tap(find.text('AI 修复老照片'));
      await tester.pumpAndSettle();
      expect(played, hasLength(1));
      final video = played.single;
      expect(video.bvid, 'BV-s4');
      expect(video.cid, 1001); // view 补齐
      expect(find.byType(FavoriteVideosPage), findsOneWidget);
    });

    testWidgets('清空（X 按钮）→ 整夹直显，不再发翻页请求', (tester) async {
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (o) {
          final pn = int.tryParse(o.queryParameters['pn'] as String? ?? '1') ??
              1;
          return switch (pn) {
            1 => _favPageBody(_page1, hasMore: true),
            2 => _favPageBody(_page2, hasMore: true),
            _ => _favPageBody(_page3, hasMore: false),
          };
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '搜索夹',
            api: _makeApi(adapter),
            openLogin: (context, {banner}) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 搜索「AI」→ 拉全量 3 页 → 结果 2 条
      await tester.enterText(find.byType(TextField), 'AI');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.text('AI 修复老照片'), findsOneWidget);

      // 点清空按钮 → 恢复浏览：整夹 5 条直显（数据已在内存，无需再翻页）
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      int resourceCalls() => adapter.requests
          .where((r) => r.path == '/x/v3/fav/resource/list')
          .length;
      expect(resourceCalls(), 4); // 清空后没有新增请求
      // 第 2 页条目可见；滚到底能看到第 3 页条目（未再请求也展示全量）
      expect(find.text('Python 爬虫实战'), findsOneWidget);
      expect(find.text('收藏的混剪 MAD'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('凉拌黄瓜做法'), findsOneWidget);
      expect(resourceCalls(), 4);
      // 输入框已清空（无清空按钮）
      expect(find.byIcon(Icons.clear), findsNothing);
    });

    testWidgets('无匹配 → 提示「未找到匹配的视频」', (tester) async {
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (_) =>
            _favPageBody(_page1, hasMore: false),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '搜索夹',
            api: _makeApi(adapter),
            openLogin: (context, {banner}) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '不存在的xyz');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配的视频'), findsOneWidget);
    });

    testWidgets('拉全量中途失败（第 2 页 -412）→ snack 提示 + 退出搜索回浏览',
        (tester) async {
      _seedValidSession();
      final adapter = _RoutingAdapter({
        '/x/web-interface/nav': (_) => _navBody(),
        '/x/v3/fav/resource/list': (o) {
          final pn = int.tryParse(o.queryParameters['pn'] as String? ?? '1') ??
              1;
          if (pn == 1) return _favPageBody(_page1, hasMore: true);
          return {
            'code': -412,
            'message': '收藏夹接口被风控拦截，请稍后再试',
          };
        },
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FavoriteVideosPage(
            mediaId: 111,
            folderName: '搜索夹',
            api: _makeApi(adapter),
            openLogin: (context, {banner}) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'AI');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // snack 展示
      expect(find.text('收藏夹接口被风控拦截，请稍后再试'), findsOneWidget);

      // 已退出搜索：输入框清空、回到分页浏览（第 1 页仍在）
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, isEmpty);
      expect(find.text('【收藏】AI 绘画教程'), findsOneWidget);
    });
  });
}
