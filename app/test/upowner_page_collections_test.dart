// UpownerPage「合集·列表」区 widget 测试（注入 mock BiliApi，不访问真实网络）：
// - 有合集/列表 → 页面顶部出现「合集」区：区头 + chips（全部视频 + 各合集/
//   列表）；creator='auto' 的系统自动列表（直播回放）被过滤不展示
// - 没有合集/列表 → 整区隐藏（不出「合集」区头/全部视频 chip）
// - 点合集 chip → 下方列表切换为该合集视频（fetchSeasonArchives），
//   原「全部视频」列表卸载、搜索框/排序 chips 隐藏（搜索排序只作用于全部视频）
// - 点列表 chip → 切 x/series/archives 数据源（fetchSeriesArchives）
// - 点「全部视频」→ 切回原列表（搜索框/排序 chips 恢复）
// - 长按合集视频 → 弹「加入白名单视频 / 取消」菜单（可取消关闭）
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/upowner_page.dart';

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

class _RoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function()> handlers;

  _RoutingAdapter(this.handlers);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
      jsonEncode(handler()),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _spiBody() => {
  'code': 0,
  'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
};

Map<String, dynamic> _navBody() => {
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

Map<String, dynamic> _accInfoBody() => {
  'code': 0,
  'message': 'OK',
  'data': {'name': '测试UP主', 'face': '', 'fans': 100, 'sign': ''},
};

/// 全部视频接口（x/space/wbi/arc/search）。
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

Map<String, dynamic> _colItem(Map<String, dynamic> meta) =>
    {'archives': <Map<String, dynamic>>[], 'meta': meta, 'recent_aids': []};

Map<String, dynamic> _seasonMeta(int id, String name) => {
  'season_id': id,
  'name': name,
  'cover': '',
  'description': '合集简介',
  'total': 20,
};

Map<String, dynamic> _seriesMeta(int id, String name, String creator) => {
  'series_id': id,
  'name': name,
  'cover': '',
  'description': '',
  'creator': creator,
  'total': 6,
};

/// 合集/列表清单（默认 1 合集 + 1 自建列表 + 1 auto 直播列表）。
Map<String, dynamic> _collectionsBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'items_lists': {
      'page': {'page_num': 1, 'page_size': 20, 'total': 3},
      'seasons_list': [
        _colItem(_seasonMeta(3993361, '合集·经典领读')),
      ],
      'series_list': [
        _colItem(_seriesMeta(2001, '自建列表', '')),
        _colItem(_seriesMeta(2229877, '直播回放', 'auto')),
      ],
    },
  },
};

/// 合集视频（seasons_archives_list）。
Map<String, dynamic> _seasonVideosBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'archives': [
      {
        'aid': 1,
        'bvid': 'BV1s1',
        'title': '合集视频一号',
        'pic': '',
        'duration': 503,
        'pubdate': 1728792000,
      },
      {
        'aid': 2,
        'bvid': 'BV1s2',
        'title': '合集视频二号',
        'pic': '',
        'duration': 600,
        'pubdate': 1728792000,
      },
    ],
    'page': {'page_num': 1, 'page_size': 20, 'total': 2},
  },
};

/// 列表视频（x/series/archives）。
Map<String, dynamic> _seriesVideosBody() => {
  'code': 0,
  'message': 'OK',
  'data': {
    'archives': [
      {
        'aid': 3,
        'bvid': 'BV1s3',
        'title': '系列视频一号',
        'pic': '',
        'duration': 700,
        'pubdate': 1728792000,
      },
    ],
    'page': {'num': 1, 'size': 20, 'total': 1},
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

BiliApi _fakeApi(Map<String, Map<String, dynamic> Function()> handlers) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = _RoutingAdapter(handlers);
  return BiliApi(dio: dio);
}

/// 常规 handlers：spi/nav/acc/info + 全部视频列表。
Map<String, Map<String, dynamic> Function()> _baseHandlers() => {
  '/x/frontend/finger/spi': _spiBody,
  '/x/web-interface/nav': _navBody,
  '/x/space/wbi/acc/info': _accInfoBody,
  '/x/space/wbi/arc/search': _mainVideosBody,
};

Future<void> _pumpPage(
  WidgetTester tester,
  BiliApi api, {
  int mid = 546195,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: UpownerPage(mid: mid, api: api)),
  );
  // 等 info + 全部视频 + 合集清单全部加载完
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  testWidgets('有合集：出现「合集」区（chips 含合集/自建列表，'
      'auto 直播列表被过滤）', (tester) async {
    final api = _fakeApi({
      ..._baseHandlers(),
      '/x/polymer/web-space/seasons_series_list': _collectionsBody,
    });
    await _pumpPage(tester, api);

    // 区头「合集」
    expect(find.text('合集'), findsOneWidget);
    // chips：全部视频 + 合集（名含「合集·」前缀）+ 自建列表（带「 · 列表」后缀）
    expect(find.text('全部视频'), findsOneWidget);
    expect(find.text('合集·经典领读'), findsOneWidget);
    expect(find.text('自建列表 · 列表'), findsOneWidget);
    // auto 直播回放系列被过滤
    expect(find.text('直播回放 · 列表'), findsNothing);
    // 主列表照常显示（不受合集区影响）
    expect(find.text('主列表视频'), findsOneWidget);
  });

  testWidgets('没有合集/列表：整区隐藏（无「合集」区头、无全部视频 chip）',
      (tester) async {
    final api = _fakeApi({
      ..._baseHandlers(),
      '/x/polymer/web-space/seasons_series_list': _emptyCollectionsBody,
    });
    await _pumpPage(tester, api);

    expect(find.text('合集'), findsNothing);
    expect(find.text('全部视频'), findsNothing);
    expect(find.text('合集·经典领读'), findsNothing);
    // 主列表不受影响
    expect(find.text('主列表视频'), findsOneWidget);
  });

  testWidgets('点合集 chip → 列表切换为该合集视频（独立分页），'
      '搜索/排序隐藏；点「全部视频」切回', (tester) async {
    final api = _fakeApi({
      ..._baseHandlers(),
      '/x/polymer/web-space/seasons_series_list': _collectionsBody,
      '/x/polymer/web-space/seasons_archives_list': _seasonVideosBody,
    });
    await _pumpPage(tester, api);

    // 进入合集视图前：搜索框/排序可见
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('最新发布'), findsOneWidget);

    await tester.tap(find.text('合集·经典领读'));
    await tester.pumpAndSettle();

    // 合集视频列表出现；原全部视频列表卸载；搜索/排序隐藏
    expect(find.text('合集视频一号'), findsOneWidget);
    expect(find.text('合集视频二号'), findsOneWidget);
    expect(find.text('主列表视频'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('最新发布'), findsNothing);
    expect(find.text('最新发布'), findsNothing);
    // 区头仍在（可随时切回/换合集）
    expect(find.text('合集'), findsOneWidget);

    // 切回「全部视频」→ 原列表恢复、搜索/排序恢复
    await tester.tap(find.text('全部视频'));
    await tester.pumpAndSettle();
    expect(find.text('主列表视频'), findsOneWidget);
    expect(find.text('合集视频一号'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('最新发布'), findsOneWidget);
  });

  testWidgets('点自建列表 chip → 走 x/series/archives 数据源显示列表视频',
      (tester) async {
    final api = _fakeApi({
      ..._baseHandlers(),
      '/x/polymer/web-space/seasons_series_list': _collectionsBody,
      '/x/series/archives': _seriesVideosBody,
    });
    await _pumpPage(tester, api);

    await tester.tap(find.text('自建列表 · 列表'));
    await tester.pumpAndSettle();
    expect(find.text('系列视频一号'), findsOneWidget);
    // 期间不会误发 season 接口（走的是 series 接口）
    expect(find.text('合集视频一号'), findsNothing);
  });

  testWidgets('合集视频长按 → 弹「加入白名单视频 / 取消」菜单，可取消关闭',
      (tester) async {
    final api = _fakeApi({
      ..._baseHandlers(),
      '/x/polymer/web-space/seasons_series_list': _collectionsBody,
      '/x/polymer/web-space/seasons_archives_list': _seasonVideosBody,
    });
    await _pumpPage(tester, api);

    await tester.tap(find.text('合集·经典领读'));
    await tester.pumpAndSettle();

    // 长按合集视频 → 底部菜单
    await tester.longPress(find.text('合集视频一号'));
    await tester.pumpAndSettle();
    expect(find.text('加入白名单视频'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 点「取消」→ 菜单关闭，列表仍在
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('加入白名单视频'), findsNothing);
    expect(find.text('合集视频一号'), findsOneWidget);
  });
}
