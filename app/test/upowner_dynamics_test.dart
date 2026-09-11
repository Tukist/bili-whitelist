// UpownerPage「动态」区 widget 测试（注入 mock BiliApi，不访问真实网络）。
//
// 覆盖：
// - 懒加载：进页不请求 feed（点「动态」chip 才请求一次）
// - 列表渲染：作者行（名字 + 相对时间）、正文、配图（动态卡）、转发原文块、
//   视频投稿标题
// - 触底加载下一页：第二页请求带上第一页返回的 offset 游标；has_more=false 收尾
// - 空态 / 错误态走既有 AppStateView / AppErrorView（seed = upowner.dynamics）
// - 点配图 → ImageViewerPage；点视频投稿 → 先 fetchVideoMeta（本用例让它失败，
//   断言「有请求 + 有提示 + 不进播放页」——真机能否播放见 _openDynamicVideo 注释）
// - 切回「全部视频」→ 视频列表恢复、动态列表卸载
//
// 说明：动态卡片的视频投稿点击**不**在本文件里真进播放页（那要把原生播放器
// 通道拉进测试，收益低）；这里只钉住「请求已发出 + 失败走提示」。播放页本身
// 不校验白名单（评论区的视频链接预览就是直接 push 播放页的），见 lib 内注释。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/dynamic_item.dart';
import 'package:bili_whitelist_app/pages/image_viewer_page.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dot_illustration.dart';
import 'package:bili_whitelist_app/widgets/dynamic_card.dart';

const String _kFeedPath = '/x/polymer/web-dynamic/v1/feed/space';

/// 动态发布时间：相对「现在」3 小时 → 卡片显示「3 小时前」（跟时区无关）。
final int _pubTs =
    DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch ~/
        1000;

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
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

Map<String, dynamic> _spiBody() => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

Map<String, dynamic> _navBody() => {
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url':
              'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url':
              'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    };

Map<String, dynamic> _accInfoBody() => {
      'code': 0,
      'message': 'OK',
      'data': {'name': '测试UP主', 'face': '', 'sign': ''},
    };

Map<String, dynamic> _mainVideosBody() => {
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

Map<String, dynamic> _emptyCollectionsBody() => {
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
      '/x/frontend/finger/spi': (_) => _spiBody(),
      '/x/web-interface/nav': (_) => _navBody(),
      '/x/space/wbi/acc/info': (_) => _accInfoBody(),
      '/x/space/wbi/arc/search': (_) => _mainVideosBody(),
      '/x/polymer/web-space/seasons_series_list': (_) =>
          _emptyCollectionsBody(),
      '/x/relation/stat': (_) => {
            'code': 0,
            'message': 'OK',
            'data': {'mid': 546195, 'follower': 100},
          },
    };

// ---- 动态流 fixture --------------------------------------------------------

Map<String, dynamic> _dynItem(
  String id, {
  String type = DynamicType.draw,
  String author = '动态君',
  String text = '',
  List<String>? images,
  String? videoBvid,
  String? videoTitle,
  Map<String, dynamic>? orig,
}) =>
    {
      'id_str': id,
      'type': type,
      'modules': {
        'module_author': {
          'name': author,
          'face': '',
          'pub_ts': _pubTs,
        },
        'module_dynamic': {
          if (text.isNotEmpty) 'desc': {'text': text},
          if (images != null || videoBvid != null)
            'major': {
              if (images != null)
                'draw': {
                  'items': [
                    for (final u in images) {'src': u},
                  ],
                },
              if (videoBvid != null)
                'archive': {
                  'bvid': videoBvid,
                  'title': videoTitle ?? '',
                  'cover': '',
                },
            },
        },
      },
      if (orig != null) 'orig': orig,
    };

Map<String, dynamic> _feedBody({
  required List<Map<String, dynamic>> items,
  String offset = '',
  bool hasMore = false,
  int code = 0,
}) =>
    {
      'code': code,
      'message': code == 0 ? 'OK' : '风控',
      'data': {
        'items': items,
        'offset': offset,
        'has_more': hasMore,
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
}

/// 切到「动态」视图（点顶部 chips 里的固定项）。
Future<void> _switchToDynamics(WidgetTester tester) async {
  await tester.tap(find.text('动态'));
  await tester.pumpAndSettle();
}

/// 显式推进假时钟（含等待**纯 Timer**）。
///
/// 为什么不能只靠 `pumpAndSettle`：动态接口的两层重试（API 内空页重试
/// 500ms、页面退避 1s/2s）都是纯 `Future.delayed`，**不调度帧** ——
/// `pumpAndSettle` 只等「有帧被调度」的等待，会立刻返回，断言就会打在
/// 「还在加载」的那一帧上。
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

/// 测试环境里图床请求一律 400（flutter_test 默认 HttpClient 的固定行为）→
/// 图片加载失败是**预期内**的（渲染侧有 errorBuilder 兜底成占位）；把已上报
/// 的图片异常取走，避免它们污染用例结果。
void _drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockSecureStorage();
    // UP 主信息会话缓存跨用例隔离（静态缓存会串数据）
    UpownerPage.clearInfoCacheForTest();
  });

  testWidgets('懒加载 + 列表渲染：点「动态」才请求；作者/时间/正文/图片都出来',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (_) => _feedBody(
            items: [
              _dynItem(
                '1',
                text: '动态正文一',
                images: ['//i0.hdslb.com/a.jpg'],
              ),
            ],
          ),
    });
    await _pumpPage(tester, _fakeApi(adapter));

    // 进页只拉视频/合集/信息，不动动态接口
    expect(adapter.forPath(_kFeedPath), isEmpty, reason: '动态懒加载');
    expect(find.text('主列表视频'), findsOneWidget);
    expect(find.text('动态'), findsOneWidget, reason: 'chips 里的固定项');

    await _switchToDynamics(tester);

    expect(adapter.forPath(_kFeedPath), hasLength(1));
    final req = adapter.forPath(_kFeedPath).single;
    expect(req.queryParameters['host_mid'], '546195');
    expect(req.queryParameters.containsKey('offset'), isFalse,
        reason: '首屏不传游标');

    expect(find.byType(DynamicCard), findsOneWidget);
    expect(find.text('动态君'), findsOneWidget, reason: '作者行');
    expect(find.text('3 小时前'), findsOneWidget, reason: '相对时间');
    expect(find.text('动态正文一'), findsOneWidget);
    // 视频列表已被动态视图取代
    expect(find.text('主列表视频'), findsNothing);
    expect(find.text('最新发布'), findsNothing, reason: '排序 chips 只属视频视图');
  });

  testWidgets('触底加载下一页：带上第一页的 offset 游标；has_more=false 收尾',
      (tester) async {
    // 首屏 8 条：足够撑出滚动，拖动才能触发触底
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (req) {
        final offset = req.queryParameters['offset'];
        if (offset == null) {
          return _feedBody(
            items: [
              for (var i = 1; i <= 8; i++)
                _dynItem('$i', text: '第一页动态 $i'),
            ],
            offset: 'cursor-2',
            hasMore: true,
          );
        }
        return _feedBody(
          items: [_dynItem('9', text: '第二页动态')],
        );
      },
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);
    expect(find.byType(DynamicCard), findsWidgets);
    expect(find.text('第二页动态'), findsNothing);

    // 触底 → 拉第二页（ListView 懒加载，只断言请求与内容，不数卡片数量）
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();

    final reqs = adapter.forPath(_kFeedPath);
    expect(reqs, hasLength(2), reason: '触底翻页');
    expect(reqs[1].queryParameters['offset'], 'cursor-2',
        reason: 'offset 原样回传');

    // 再滚到新追加的那条（它在列表末尾，懒加载不保证第一屏就建出来）
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('第二页动态'), findsOneWidget);
    expect(adapter.forPath(_kFeedPath), hasLength(2),
        reason: 'has_more=false 后不再请求');
  });

  testWidgets('空态：AppStateView（seed = upowner.dynamics），文案直给',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (_) => _feedBody(items: const []),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);
    // 空页会触发 API 内的一次空页重试（500ms Timer）→ 显式推进时间再看状态
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(adapter.forPath(_kFeedPath), hasLength(2), reason: '空页重试一次');

    expect(find.text('该 UP 主暂无动态'), findsOneWidget);
    final state = tester.widget<AppStateView>(find.byType(AppStateView));
    expect(state.kind, AppStateKind.empty);
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'upowner.dynamics',
    );
  });

  testWidgets('错误态：AppErrorView（seed = upowner.dynamics）+ 重试再发请求',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      // 一直 -412：API 内重试一次 + 页面退避重试两次后落错误态
      _kFeedPath: (_) => _feedBody(items: const [], code: -412),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);
    // 页面退避重试（1s → 2s）+ 每轮两次 API 尝试 → 推进足够时间再断言错误态
    await _pumpFor(tester, const Duration(seconds: 6));

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('风控'), findsOneWidget);
    expect(
      tester.widget<DotIllustration>(find.byType(DotIllustration)).seed,
      'upowner.dynamics',
    );
    final before = adapter.forPath(_kFeedPath).length;

    await tester.tap(find.text('重试'));
    await _pumpFor(tester, const Duration(seconds: 6));

    expect(adapter.forPath(_kFeedPath).length, greaterThan(before),
        reason: '重试会重新请求');
    expect(find.byType(AppErrorView), findsOneWidget);
  });

  testWidgets('转发动态：正文 + 原文块（作者署名 + 原文正文）', (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (_) => _feedBody(
            items: [
              _dynItem(
                '1',
                type: DynamicType.forward,
                text: '转发附言',
                orig: {
                  'id_str': '2',
                  'type': DynamicType.word,
                  'modules': {
                    'module_author': {'name': '原作者', 'face': '', 'pub_ts': _pubTs},
                    'module_dynamic': {
                      'desc': {'text': '被转发的原文'},
                    },
                  },
                },
              ),
            ],
          ),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);

    expect(find.text('转发附言'), findsOneWidget);
    expect(find.text('@原作者'), findsOneWidget);
    expect(find.text('被转发的原文'), findsOneWidget);
  });

  testWidgets('视频投稿卡：标题 + 「视频投稿」标签；点击先取 view（失败走提示，'
      '不进播放页）', (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (_) => _feedBody(
            items: [
              _dynItem(
                '1',
                type: DynamicType.av,
                text: '投了个视频',
                videoBvid: 'BV1dyn4111',
                videoTitle: '动态里的视频标题',
              ),
            ],
          ),
      // 投稿视频取元数据失败（本用例只钉住「点击 → 发请求 → 提示」这条链）
      '/x/web-interface/view': (_) => {'code': -404, 'message': '啥都木有'},
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);

    expect(find.text('动态里的视频标题'), findsOneWidget);
    expect(find.text('视频投稿'), findsOneWidget);

    final card = tester.widget<DynamicCard>(find.byType(DynamicCard));
    expect(card.onVideoTap, isNotNull, reason: '视频投稿点击已接线');
    expect(card.onImageTap, isNotNull, reason: '配图点击已接线');

    await tester.tap(find.text('动态里的视频标题'));
    await tester.pumpAndSettle();

    final viewReqs = adapter.forPath('/x/web-interface/view');
    expect(viewReqs, hasLength(1));
    expect(viewReqs.single.queryParameters['bvid'], 'BV1dyn4111');
    expect(find.textContaining('获取视频信息失败'), findsOneWidget);
  });

  testWidgets('点配图 → ImageViewerPage（带本卡全部图片与下标）', (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (_) => _feedBody(
            items: [
              _dynItem(
                '1',
                text: '两张图',
                images: ['//i0.hdslb.com/1.jpg', '//i0.hdslb.com/2.jpg'],
              ),
            ],
          ),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);

    // 图片本体加载失败（测试环境无图床）→ 占位仍在，点击照常命中
    final tap = find.descendant(
      of: find.byType(DynamicCard),
      matching: find.byType(GestureDetector),
    );
    expect(tap, findsWidgets);
    await tester.tap(tap.first, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsOneWidget);
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.urls, [
      'https://i0.hdslb.com/1.jpg',
      'https://i0.hdslb.com/2.jpg',
    ]);
    // 图床在测试环境必然 400 → 图片异常（占位已兜住渲染）取走即可
    _drainImageErrors(tester);
  });

  testWidgets('切回「全部视频」：动态列表卸载、视频列表与排序 chips 恢复',
      (tester) async {
    final adapter = _RoutingAdapter({
      ..._baseHandlers(),
      _kFeedPath: (_) => _feedBody(items: [_dynItem('1', text: '动态正文一')]),
    });
    await _pumpPage(tester, _fakeApi(adapter));
    await _switchToDynamics(tester);
    expect(find.byType(DynamicCard), findsOneWidget);

    await tester.tap(find.text('全部视频'));
    await tester.pumpAndSettle();

    expect(find.byType(DynamicCard), findsNothing);
    expect(find.text('主列表视频'), findsOneWidget);
    expect(find.text('最新发布'), findsOneWidget);
    // 再切回动态：已成功加载过（_dynLoadedOnce）→ 不重复请求
    final before = adapter.forPath(_kFeedPath).length;
    await _switchToDynamics(tester);
    expect(adapter.forPath(_kFeedPath).length, before);
    expect(find.byType(DynamicCard), findsOneWidget);
  });
}
