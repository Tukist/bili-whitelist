// UpownerPage「专栏」区 widget 测试（注入 mock BiliApi，不访问真实网络）。
//
// 覆盖：
// - 懒加载：进页不请求 `x/space/article`（点「专栏」chip 才请求一次）
// - 列表渲染：banner/封面 + 标题 + 摘要 + 统计（阅读/点赞）+ 相对时间
// - 触底加载下一页：第二页请求带 pn=2；空页收尾（hasMore=false 后不再请求）
// - 点击专栏卡 → ArticlePage（阅读页），并带上列表里的标题
// - 空态 / 错误态走既有 AppStateView / AppErrorView（seed = upowner.articles）
// - 三个内容源互斥：切「动态」/「全部视频」时专栏列表卸载；已加载过不重复请求
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/article_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';

const String _kListPath = '/x/space/article';
const String _kViewPath = '/x/article/view';

/// 专栏发布时间：相对「现在」5 小时 → 卡片显示「5 小时前」（与时区无关）。
final int _pubTs =
    DateTime.now().subtract(const Duration(hours: 5)).millisecondsSinceEpoch ~/
        1000;

void _mockSecureStorage() {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    return null;
  });
}

class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final handler = handlers[options.path];
    if (handler == null) {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'no handler: ${options.path}'}),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(handler(options)),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// ---- 基础 handler（UP 信息 / 全部视频 / 合集清单 / 粉丝数）-------------------

Map<String, dynamic> _spiBody(RequestOptions _) => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

/// 匿名 nav：code=-101 但照给 wbi_img（与线上一致；UP 视频列表要签名）。
Map<String, dynamic> _navBody(RequestOptions _) => {
      'code': -101,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

Map<String, dynamic> _accInfoBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {'name': '测试UP主', 'face': '', 'sign': ''},
    };

Map<String, dynamic> _mainVideosBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'list': {
          'count': 1,
          'vlist': [
            {
              'bvid': 'BV1main',
              'title': '主列表视频',
              'length': '4:45',
              'author': '测试UP主',
              'pic': '',
              'created': 1700000000,
            },
          ],
        },
      },
    };

Map<String, dynamic> _emptyCollectionsBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'items_lists': {
          'page': {'page_num': 1, 'page_size': 20, 'total': 0},
          'seasons_list': <Map<String, dynamic>>[],
          'series_list': <Map<String, dynamic>>[],
        },
      },
    };

Map<String, Map<String, dynamic> Function(RequestOptions)> _baseHandlers() => {
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/acc/info': _accInfoBody,
      '/x/space/wbi/arc/search': _mainVideosBody,
      '/x/polymer/web-space/seasons_series_list': _emptyCollectionsBody,
      '/x/relation/stat': (_) => {
            'code': 0,
            'message': 'OK',
            'data': {'mid': 546195, 'follower': 100},
          },
    };

// ---- 专栏 fixture ----------------------------------------------------------

Map<String, dynamic> _articleItem(
  int id, {
  String title = '专栏标题',
  String summary = '这是摘要',
  String? banner,
  List<String>? images,
}) =>
    {
      'id': id,
      'title': title,
      'summary': summary,
      'publish_time': _pubTs,
      'words': 800,
      if (banner != null) 'banner_url': banner,
      'image_urls': images ?? <String>[],
      'stats': {'view': 12345, 'like': 678, 'favorite': 9},
    };

Map<String, dynamic> _listBody({
  required List<Map<String, dynamic>> articles,
  int pn = 1,
  int ps = 10,
  int? count,
  int code = 0,
}) =>
    {
      'code': code,
      'message': code == 0 ? 'OK' : '风控',
      'data': {
        'articles': articles,
        'pn': pn,
        'ps': ps,
        if (count != null) 'count': count,
      },
    };

Map<String, dynamic> _viewBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'id': 111,
        'title': '专栏正文标题',
        'content': '<p>正文第一段</p><h2>正文小标题</h2>',
        'publish_time': _pubTs,
        'author': {'mid': 546195, 'name': '测试UP主', 'face': ''},
        'stats': {'view': 1, 'like': 2, 'favorite': 3},
      },
    };

BiliApi _fakeApi(_RoutingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Future<void> _pumpPage(WidgetTester tester, BiliApi api) async {
  await tester.pumpWidget(MaterialApp(home: UpownerPage(mid: 546195, api: api)));
  await tester.pumpAndSettle();
  _drainImageErrors(tester);
}

/// 切到「专栏」视图（点顶部 chips 里的固定项）。
Future<void> _switchToArticles(WidgetTester tester) async {
  await tester.tap(find.text('专栏'));
  await tester.pumpAndSettle();
  _drainImageErrors(tester);
}

/// 显式推进假时钟（含页面退避重试用的**纯 Timer**：pumpAndSettle 只等调度
/// 了帧的等待，纯 `Future.delayed` 它看不见）。
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

/// 测试环境里图床请求一律 400 → 图片加载失败是预期内的（有占位兜底），
/// 把已上报的异常取走，别污染用例结果。
void _drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockSecureStorage();
    UpownerPage.clearInfoCacheForTest();
  });

  testWidgets('懒加载 + 列表渲染：点「专栏」才请求；封面/标题/摘要/统计/时间都在',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kListPath: (_) => _listBody(
            articles: [
              _articleItem(
                111,
                title: '第一篇专栏',
                summary: '第一篇摘要',
                banner: '//i0.hdslb.com/bfs/article/banner.jpg',
              ),
            ],
          ),
    });
    await _pumpPage(tester, _fakeApi(adapter));

    expect(adapter.forPath(_kListPath), isEmpty, reason: '专栏懒加载');
    expect(find.text('主列表视频'), findsOneWidget);
    expect(find.text('专栏'), findsOneWidget, reason: 'chips 里的固定项');

    await _switchToArticles(tester);

    final reqs = adapter.forPath(_kListPath);
    expect(reqs, hasLength(1));
    expect(reqs.single.queryParameters['mid'], '546195');
    expect(reqs.single.queryParameters['pn'], '1');
    expect(reqs.single.queryParameters['ps'], '10');

    expect(find.text('第一篇专栏'), findsOneWidget);
    expect(find.text('第一篇摘要'), findsOneWidget);
    expect(find.text('阅读 1.2万'), findsOneWidget, reason: '12345 → 1.2万');
    expect(find.text('点赞 678'), findsOneWidget);
    expect(find.text('5 小时前'), findsOneWidget, reason: '相对时间');
    // 视频视图已被专栏取代（搜索/排序只属视频视图）
    expect(find.text('主列表视频'), findsNothing);
    expect(find.text('最新发布'), findsNothing);
    _drainImageErrors(tester);
  });

  testWidgets('触底加载下一页：第二页带 pn=2；到底后不再请求', (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kListPath: (req) {
        final pn = int.parse(req.queryParameters['pn'] as String);
        if (pn == 1) {
          // 首屏 10 条（够撑出滚动）+ count 说明还有下一页
          return _listBody(
            articles: [
              for (var i = 1; i <= 10; i++) _articleItem(i, title: '第一页专栏 $i'),
            ],
            pn: 1,
            count: 12,
          );
        }
        return _listBody(
          articles: [_articleItem(99, title: '第二页专栏')],
          pn: 2,
          count: 12,
        );
      },
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToArticles(tester);
    expect(find.text('第二页专栏'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();

    final reqs = adapter.forPath(_kListPath);
    expect(reqs, hasLength(2), reason: '触底翻页');
    expect(reqs[1].queryParameters['pn'], '2');

    // 再滚到新追加的那条（懒加载不保证第一屏就建出来）
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('第二页专栏'), findsOneWidget);
    expect(adapter.forPath(_kListPath), hasLength(2),
        reason: '2×10 >= 12 后不再请求');
    _drainImageErrors(tester);
  });

  testWidgets('点专栏卡 → ArticlePage（阅读页）', (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kListPath: (_) => _listBody(
            articles: [_articleItem(111, title: '可点的专栏')],
          ),
      _kViewPath: _viewBody,
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToArticles(tester);

    await tester.tap(find.text('可点的专栏'));
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    expect(find.byType(ArticlePage), findsOneWidget);
    expect(adapter.forPath(_kViewPath).single.queryParameters['id'], '111');
    expect(find.text('正文第一段'), findsOneWidget, reason: '阅读页渲染了正文');
    _drainImageErrors(tester);
  });

  testWidgets('空态：AppStateView（seed = upowner.articles），文案直给',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kListPath: (_) => _listBody(articles: const []),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToArticles(tester);

    expect(find.text('该 UP 主暂无专栏'), findsOneWidget);
    final state = tester.widget<AppStateView>(find.byType(AppStateView));
    expect(state.kind, AppStateKind.empty);
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'upowner.articles',
    );
  });

  testWidgets('错误态：AppErrorView（seed = upowner.articles）+ 重试再发请求',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      // 一直 -412：页面退避重试（1s → 2s）后落错误态
      _kListPath: (_) => _listBody(articles: const [], code: -412),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToArticles(tester);
    await _pumpFor(tester, const Duration(seconds: 6));

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('风控'), findsOneWidget);
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'upowner.articles',
    );
    final before = adapter.forPath(_kListPath).length;

    await tester.tap(find.text('重试'));
    await _pumpFor(tester, const Duration(seconds: 6));

    expect(adapter.forPath(_kListPath).length, greaterThan(before),
        reason: '重试会重新请求');
    expect(find.byType(AppErrorView), findsOneWidget);
  });

  testWidgets('三个内容源互斥：切「动态」/「全部视频」时专栏列表卸载，'
      '再切回不重复请求', (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kListPath: (_) => _listBody(articles: [_articleItem(111)]),
      _kViewPath: _viewBody,
      '/x/polymer/web-dynamic/v1/feed/space': (_) => {
            'code': 0,
            'message': 'OK',
            'data': {
              'items': <Map<String, dynamic>>[],
              'offset': '',
              'has_more': false,
            },
          },
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToArticles(tester);
    expect(find.text('专栏标题'), findsOneWidget);

    // 切「动态」→ 专栏列表卸载
    await tester.tap(find.text('动态'));
    await tester.pumpAndSettle();
    expect(find.text('专栏标题'), findsNothing);

    // 切回「全部视频」→ 视频列表恢复
    await tester.tap(find.text('全部视频'));
    await tester.pumpAndSettle();
    expect(find.text('主列表视频'), findsOneWidget);
    expect(find.text('最新发布'), findsOneWidget);

    // 再切回「专栏」：已成功加载过 → 不重复请求
    final before = adapter.forPath(_kListPath).length;
    await _switchToArticles(tester);
    expect(adapter.forPath(_kListPath).length, before);
    expect(find.text('专栏标题'), findsOneWidget);
  });
}
