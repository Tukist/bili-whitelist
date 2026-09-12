// UpownerPage 内容区「左右滑动切分区」widget 测试（注入 mock BiliApi，不访问真实网络）。
//
// 覆盖（分区 = 顶部 chips 行的一项；内容区是 PageView，一页 = 一个分区）：
// - 左滑 / 右滑切到相邻分区，顶部 chips 选中态**同步**（滑动 → 高亮跟着走）
// - 点 chips 切换仍然生效（既有入口不丢），且落到同一页
// - 纵向拖动只滚列表、**不**切分区（横竖手势不串味）
// - 边界：第一个分区继续右滑、最后一个分区继续左滑都不出界（不崩、不空白）
// - 滑走再滑回：已加载的数据**不重复请求**、滚动位置保留（不回顶）
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';
import 'package:bili_whitelist_app/widgets/dynamic_card.dart';

const String _kFeedPath = '/x/polymer/web-dynamic/v1/feed/space';
const String _kArticlePath = '/x/space/article';
const String _kSeasonArchivesPath =
    '/x/polymer/web-space/seasons_archives_list';
const String _kSeriesArchivesPath = '/x/series/archives';

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
}

/// 记录每个 path 的请求次数（用来钉「切回不重复请求」）。
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function(RequestOptions)> handlers;
  final List<RequestOptions> requests = [];

  /// 置上后所有请求都卡在这里（用来测「响应慢 → 整页等待」这类时序）。
  Completer<void>? gate;

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  int count(String path) => forPath(path).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final gate = this.gate;
    if (gate != null) await gate.future;
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

/// 全部视频（`count` 与条数一致 → hasMore=false，滚动不会误触翻页）。
Map<String, dynamic> _mainVideosBody(int n) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'list': {
          'vlist': [
            for (var i = 1; i <= n; i++)
              {
                'bvid': 'BV1main$i',
                'title': '主列表视频 $i',
                'length': '4:45',
                'author': '测试UP主',
                'pic': '',
                'created': 1700000000,
              },
          ],
        },
        'page': {'pn': 1, 'ps': 20, 'count': n},
      },
    };

Map<String, dynamic> _statBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {'mid': 546195, 'follower': 100},
    };

/// 合集清单：一个合集 + 一个自建列表（分区分页 = 3 + 2）。
Map<String, dynamic> _collectionsBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'items_lists': {
          'page': {'page_num': 1, 'page_size': 20, 'total': 2},
          'seasons_list': [
            {
              'archives': <Map<String, dynamic>>[],
              'meta': {
                'season_id': 3993361,
                'name': '合集·经典领读',
                'cover': '',
                'description': '',
                'total': 1,
              },
              'recent_aids': <int>[],
            },
          ],
          'series_list': [
            {
              'archives': <Map<String, dynamic>>[],
              'meta': {
                'series_id': 2001,
                'name': '自建列表',
                'cover': '',
                'description': '',
                'creator': '',
                'total': 1,
              },
              'recent_aids': <int>[],
            },
          ],
        },
      },
    };

/// 合集视频（seasons_archives_list）；[n] 条（第 1 条标题固定，便于既有断言）。
Map<String, dynamic> _seasonVideosBody(int n) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'archives': [
          for (var i = 1; i <= n; i++)
            {
              'aid': i,
              'bvid': 'BV1s$i',
              'title': i == 1 ? '合集视频一号' : '合集视频 $i',
              'pic': '',
              'duration': 503,
              'pubdate': 1728792000,
            },
        ],
        'page': {'page_num': 1, 'page_size': 20, 'total': n},
      },
    };

/// 自建列表视频（x/series/archives）；[n] 条。
Map<String, dynamic> _seriesVideosBody(int n) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'archives': [
          for (var i = 1; i <= n; i++)
            {
              'aid': 100 + i,
              'bvid': 'BV1t$i',
              'title': i == 1 ? '系列视频一号' : '系列视频 $i',
              'pic': '',
              'duration': 700,
              'pubdate': 1728792000,
            },
        ],
        'page': {'num': 1, 'size': 20, 'total': n},
      },
    };

/// 动态流：n 条纯文字动态（够撑出滚动，用于纵滑/滚动位置断言）。
Map<String, dynamic> _feedBody(int n) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'items': [
          for (var i = 1; i <= n; i++)
            {
              'id_str': '$i',
              'type': 'DYNAMIC_TYPE_WORD',
              'modules': {
                'module_author': {
                  'name': '动态君',
                  'face': '',
                  'pub_ts': 1700000000,
                },
                'module_dynamic': {
                  'desc': {'text': '动态正文 $i'},
                },
              },
            },
        ],
        'offset': '',
        'has_more': false,
      },
    };

Map<String, dynamic> _articlesBody(RequestOptions _) => {
      'code': 0,
      'message': 'OK',
      'data': {
        'articles': [
          {
            'id': 111,
            'title': '第一篇专栏',
            'summary': '第一篇摘要',
            'publish_time': 1700000000,
            'words': 800,
            'image_urls': <String>[],
            'stats': {'view': 1, 'like': 2, 'favorite': 3},
          },
        ],
        'pn': 1,
        'ps': 10,
        'count': 1,
      },
    };

BiliApi _fakeApi(_CountingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

/// 默认 handlers（各分区条数可调）。
_CountingAdapter _adapter({
  int videos = 1,
  int dynamics = 1,
  int seasonVideos = 1,
  int seriesVideos = 1,
}) =>
    _CountingAdapter({
      '/x/frontend/finger/spi': _spiBody,
      '/x/web-interface/nav': _navBody,
      '/x/space/wbi/acc/info': _accInfoBody,
      '/x/relation/stat': _statBody,
      '/x/space/wbi/arc/search': (_) => _mainVideosBody(videos),
      '/x/polymer/web-space/seasons_series_list': _collectionsBody,
      _kSeasonArchivesPath: (_) => _seasonVideosBody(seasonVideos),
      _kSeriesArchivesPath: (_) => _seriesVideosBody(seriesVideos),
      _kFeedPath: (_) => _feedBody(dynamics),
      _kArticlePath: _articlesBody,
    });

Future<void> _pumpPage(WidgetTester tester, _CountingAdapter adapter) async {
  await tester.pumpWidget(
    MaterialApp(home: UpownerPage(mid: 546195, api: _fakeApi(adapter))),
  );
  await tester.pumpAndSettle();
}

/// chips 里的某个 chip 是否选中（选中态由当前分区派生 —— 滑动也要跟着变）。
bool _chipSelected(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

/// 在内容区左右滑一页（拖动距离 > 半屏 → PageView 落到相邻页）。
///
/// 从 [PageView] 中心起手：横滑归 PageView、纵滑归页内列表，正是要验的场景。
Future<void> _swipePage(WidgetTester tester, {required bool left}) async {
  await tester.drag(find.byType(PageView), Offset(left ? -500 : 500, 0));
  await tester.pumpAndSettle();
}

/// 当前页内列表的滚动位置（列表用 [ScrollController]，可直接读 offset）。
double _listOffset(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!.offset;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _mockSecureStorage();
    // UP 主信息会话缓存跨用例隔离（静态缓存会串数据）
    UpownerPage.clearInfoCacheForTest();
  });

  testWidgets('左滑 → 下一分区（动态）：内容切换 + chips 选中态同步', (tester) async {
    final adapter = _adapter();
    await _pumpPage(tester, adapter);

    expect(find.text('主列表视频 1'), findsOneWidget);
    expect(_chipSelected(tester, '全部视频'), isTrue);
    expect(adapter.count(_kFeedPath), 0, reason: '动态懒加载：没滑过去不请求');

    await _swipePage(tester, left: true);

    // 内容换成动态流；视频列表卸载；chips 高亮跟着滑动走
    expect(find.byType(DynamicCard), findsWidgets);
    expect(find.text('动态正文 1'), findsOneWidget);
    expect(find.text('主列表视频 1'), findsNothing);
    expect(_chipSelected(tester, '动态'), isTrue);
    expect(_chipSelected(tester, '全部视频'), isFalse);
    // 搜索/排序属「全部视频」分区
    expect(find.text('最新发布'), findsNothing);
    // 滑到才请求（且只请求一次）
    expect(adapter.count(_kFeedPath), 1);
  });

  testWidgets('右滑 → 回到上一分区（全部视频）：内容与 chips 都回来，且不重拉', (tester) async {
    final adapter = _adapter();
    await _pumpPage(tester, adapter);

    await _swipePage(tester, left: true);
    expect(_chipSelected(tester, '动态'), isTrue);

    await _swipePage(tester, left: false);

    expect(find.text('主列表视频 1'), findsOneWidget);
    expect(find.byType(DynamicCard), findsNothing);
    expect(_chipSelected(tester, '全部视频'), isTrue);
    expect(_chipSelected(tester, '动态'), isFalse);
    expect(find.text('最新发布'), findsOneWidget);
    // 切回视频分区不重新请求列表（数据还在 State 里）
    expect(adapter.count('/x/space/wbi/arc/search'), 1);
    // 再滑回动态也不重拉（已成功加载过）
    await _swipePage(tester, left: true);
    expect(adapter.count(_kFeedPath), 1);
  });

  testWidgets('点 chips 切换照旧生效：点「专栏」→ 落到专栏分区并高亮', (tester) async {
    final adapter = _adapter();
    await _pumpPage(tester, adapter);

    await tester.tap(find.text('专栏'));
    await tester.pumpAndSettle();

    expect(find.text('第一篇专栏'), findsOneWidget);
    expect(find.text('主列表视频 1'), findsNothing);
    expect(_chipSelected(tester, '专栏'), isTrue);
    expect(adapter.count(_kArticlePath), 1);

    // 点回「全部视频」也是同一套（动画切页 + 高亮同步）
    await tester.tap(find.text('全部视频'));
    await tester.pumpAndSettle();
    expect(find.text('主列表视频 1'), findsOneWidget);
    expect(_chipSelected(tester, '全部视频'), isTrue);
    expect(adapter.count(_kArticlePath), 1, reason: '切回不重复请求');
  });

  testWidgets('点合集 chip → 合集分区（独立数据源）', (tester) async {
    final adapter = _adapter();
    await _pumpPage(tester, adapter);

    await tester.tap(find.text('合集·经典领读'));
    await tester.pumpAndSettle();

    expect(find.text('合集视频一号'), findsOneWidget);
    expect(_chipSelected(tester, '合集·经典领读'), isTrue);
    expect(adapter.count(_kSeasonArchivesPath), 1);

    // 点回「全部视频」再点回合集：合集数据不重拉（每个合集自己的视图状态）
    await tester.tap(find.text('全部视频'));
    await tester.pumpAndSettle();
    expect(find.text('主列表视频 1'), findsOneWidget);

    await tester.tap(find.text('合集·经典领读'));
    await tester.pumpAndSettle();
    expect(find.text('合集视频一号'), findsOneWidget);
    expect(adapter.count(_kSeasonArchivesPath), 1);
  });

  testWidgets('两个合集 = 两个分区：内容与滚动位置各自保留，互不重拉', (tester) async {
    final adapter = _adapter(seasonVideos: 20, seriesVideos: 20);
    await _pumpPage(tester, adapter);

    // 分区页序 = chips 顺序：0 全部视频 / 1 动态 / 2 专栏 / 3 合集 / 4 列表
    await tester.tap(find.text('合集·经典领读'));
    await tester.pumpAndSettle();
    expect(find.text('合集视频一号'), findsOneWidget);
    expect(_chipSelected(tester, '合集·经典领读'), isTrue);

    // 合集分区滚一段
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final seasonOffset = _listOffset(tester);
    expect(seasonOffset, greaterThan(0));

    // 左滑 → 下一个分区 = 自建列表；它是**另一个**数据源，从自己的位置（顶部）开始
    await _swipePage(tester, left: true);
    expect(find.text('系列视频一号'), findsOneWidget);
    expect(_chipSelected(tester, '自建列表 · 列表'), isTrue);
    expect(_listOffset(tester), 0);
    expect(adapter.count(_kSeriesArchivesPath), 1);

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    final seriesOffset = _listOffset(tester);
    expect(seriesOffset, greaterThan(0));

    // 右滑回合集：内容/位置都在，且不重拉（season 接口仍只请求过一次）
    await _swipePage(tester, left: false);
    expect(find.textContaining('合集视频'), findsWidgets);
    expect(_chipSelected(tester, '合集·经典领读'), isTrue);
    expect(_listOffset(tester), seasonOffset);
    expect(adapter.count(_kSeasonArchivesPath), 1);

    // 再滑回列表：位置同样保留
    await _swipePage(tester, left: true);
    expect(find.textContaining('系列视频'), findsWidgets);
    expect(_listOffset(tester), seriesOffset);
    expect(adapter.count(_kSeriesArchivesPath), 1);
  });

  testWidgets('纵向拖动只滚列表，不切分区（横向手势不串味）', (tester) async {
    final adapter = _adapter(videos: 20);
    await _pumpPage(tester, adapter);
    expect(_listOffset(tester), 0);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    // 列表滚了（offset > 0），但分区没变
    expect(_listOffset(tester), greaterThan(0));
    expect(_chipSelected(tester, '全部视频'), isTrue);
    expect(_chipSelected(tester, '动态'), isFalse);
    // 还在视频分区：屏幕上是视频行（第一条已滚出视口，所以只断言「有视频行」）
    expect(find.textContaining('主列表视频'), findsWidgets, reason: '还在视频分区');
    expect(find.byType(DynamicCard), findsNothing);
    expect(adapter.count(_kFeedPath), 0, reason: '没滑到动态分区，不请求动态');
  });

  testWidgets('搜索重载（响应慢 → 整页等待顶掉列表）：回来时从顶部开始', (tester) async {
    final adapter = _adapter(videos: 20);
    await _pumpPage(tester, adapter);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_listOffset(tester), greaterThan(0));

    // 搜索 = 换了一批数据；这里让第二次请求卡住 → 列表被整页等待顶掉
    // （Element 真的回收了），再回来时必须从顶部开始、不是沿用旧位置
    adapter.gate = Completer<void>();
    await tester.enterText(find.byType(TextField), '视频 1');
    await tester.pump(const Duration(milliseconds: 600)); // 防抖 500ms
    await tester.pump();
    expect(find.byType(AppLoadingHero), findsOneWidget);

    adapter.gate!.complete();
    await tester.pumpAndSettle();

    expect(_listOffset(tester), 0, reason: '换了一批数据 → 从顶部看');
    // 关键词 '视频 1' 命中的是视频行标题（输入框里的是关键词本身，不与之重复）
    expect(find.text('主列表视频 1'), findsOneWidget);
    expect(adapter.count('/x/space/wbi/arc/search'), 2, reason: '搜索重拉第一页');
  });

  testWidgets('滑走再滑回：数据不重拉 + 滚动位置保留（不回顶）', (tester) async {
    final adapter = _adapter(videos: 20, dynamics: 8);
    await _pumpPage(tester, adapter);

    // 视频列表先滚下去一段
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final beforeOffset = _listOffset(tester);
    expect(beforeOffset, greaterThan(0));

    // 滑到动态（也滚一段）→ 滑回视频分区
    await _swipePage(tester, left: true);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    final dynOffset = _listOffset(tester);
    expect(dynOffset, greaterThan(0));

    await _swipePage(tester, left: false);
    expect(_listOffset(tester), beforeOffset,
        reason: '滑回视频分区：滚动位置保留（PageStorage 恢复），不回顶');
    expect(adapter.count('/x/space/wbi/arc/search'), 1, reason: '不重拉视频列表');

    await _swipePage(tester, left: true);
    expect(_listOffset(tester), dynOffset,
        reason: '滑回动态分区：滚动位置同样保留');
    expect(adapter.count(_kFeedPath), 1, reason: '不重拉动态');
  });

  testWidgets('边界：第一个分区继续右滑不出界（不崩、不空白）', (tester) async {
    final adapter = _adapter();
    await _pumpPage(tester, adapter);

    await _swipePage(tester, left: false);
    await _swipePage(tester, left: false);

    expect(_chipSelected(tester, '全部视频'), isTrue);
    expect(find.text('主列表视频 1'), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('边界：最后一个分区（合集）继续左滑不出界', (tester) async {
    final adapter = _adapter();
    await _pumpPage(tester, adapter);

    // 合集在最后一个分区（chips 顺序 = 页序）
    await tester.tap(find.text('自建列表 · 列表'));
    await tester.pumpAndSettle();
    expect(find.text('系列视频一号'), findsOneWidget);
    expect(_chipSelected(tester, '自建列表 · 列表'), isTrue);

    await _swipePage(tester, left: true);
    await _swipePage(tester, left: true);

    expect(_chipSelected(tester, '自建列表 · 列表'), isTrue);
    expect(find.text('系列视频一号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
