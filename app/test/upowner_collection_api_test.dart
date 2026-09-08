// BiliApi 新增「UP 主主页合集/列表区」三个接口的单元测试（mock dio）：
// - fetchUpownerCollections：seasons_series_list 的 URL/参数构造、items_lists
//   结构解析（seasons_list / series_list → UpownerCollection：season_id/
//   series_id、name、total 数字串容错、creator='auto' → isAuto）、脏数据过滤、
//   code=-412/-352/无 data 的错误分类
// - fetchSeasonArchives：seasons_archives_list 的 URL/参数、archives[] →
//   WhitelistVideo（无 cid=0、duration 秒、pubdate）、page.total 分页、
//   空 archives、错误分类
// - fetchSeriesArchives：x/series/archives 的 URL/参数（pn/ps）、同构解析
// 不访问真实网络。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

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

BiliApi _api(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Map<String, dynamic> _spiBody() => {
  'code': 0,
  'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
};

/// 合集/列表单项：`{archives(空即可), meta}`（与真实接口同构）。
Map<String, dynamic> _collectionItem(Map<String, dynamic> meta) => {
  'archives': <Map<String, dynamic>>[],
  'meta': meta,
  'recent_aids': <int>[],
};

Map<String, dynamic> _seasonMeta({
  int seasonId = 1001,
  String name = '合集·测试合集',
  String cover = '//i0.hdslb.com/bfs/archive/s.jpg',
  String description = '合集简介',
  dynamic total = 20,
}) => {
  'season_id': seasonId,
  'name': name,
  'cover': cover,
  'description': description,
  'total': total,
};

Map<String, dynamic> _seriesMeta({
  int seriesId = 2001,
  String name = '测试列表',
  String creator = '',
  dynamic total = 6,
}) => {
  'series_id': seriesId,
  'name': name,
  'cover': 'https://i0.hdslb.com/bfs/archive/x.jpg',
  'description': '列表简介',
  'creator': creator,
  'total': total,
};

Map<String, dynamic> _seasonsSeriesListBody({
  int code = 0,
  List<Map<String, dynamic>>? seasons,
  List<Map<String, dynamic>>? series,
  int? total,
}) => {
  'code': code,
  'message': code == 0 ? 'OK' : '业务错误',
  'data': {
    'items_lists': {
      'page': {'page_num': 1, 'page_size': 20, if (total != null) 'total': total},
      'seasons_list': seasons ?? <Map<String, dynamic>>[],
      'series_list': series ?? <Map<String, dynamic>>[],
    },
  },
};

Map<String, dynamic> _archive({
  String bvid = 'BV1aa',
  String title = '合集视频',
  String pic = '//i0.hdslb.com/bfs/archive/a.jpg',
  int duration = 503,
  int pubdate = 1728792000,
}) => {
  'aid': 12345,
  'bvid': bvid,
  'title': title,
  'pic': pic,
  'duration': duration,
  'pubdate': pubdate,
  'ctime': pubdate,
};

Map<String, dynamic> _archivesListBody({
  int code = 0,
  List? archives,
  int? total,
}) => {
  'code': code,
  'message': code == 0 ? 'OK' : '业务错误',
  'data': {
    if (archives != null) 'archives': archives,
    'page': {'total': total ?? (archives?.length ?? 0)},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
  });

  group('fetchUpownerCollections', () {
    test('URL/参数：mid/page_num/page_size；无需 WBI（不发 nav）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () =>
            _seasonsSeriesListBody(),
      });
      await _api(adapter).fetchUpownerCollections(12345);
      // 只请求了 spi + seasons_series_list，没有 nav（说明未走 WBI 签名）
      expect(
        adapter.requests.map((r) => r.path),
        contains('/x/polymer/web-space/seasons_series_list'),
      );
      expect(
        adapter.requests.map((r) => r.path),
        isNot(contains('/x/web-interface/nav')),
      );
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/polymer/web-space/seasons_series_list',
      );
      expect(req.queryParameters['mid'], '12345');
      expect(req.queryParameters['page_num'], '1');
      expect(req.queryParameters['page_size'], '20');
    });

    test('解析 items_lists：seasons_list/series_list 分开返回；'
        '封面 // 补全 https:', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () =>
            _seasonsSeriesListBody(
              seasons: [
                _collectionItem(_seasonMeta(seasonId: 1001, name: '合集·A')),
                _collectionItem(_seasonMeta(seasonId: 1002, name: '合集·B')),
              ],
              series: [
                _collectionItem(
                  _seriesMeta(seriesId: 2001, name: '手作列表', creator: ''),
                ),
              ],
              total: 3,
            ),
      });
      final r = await _api(adapter).fetchUpownerCollections(1);
      expect(r.seasons, hasLength(2));
      final s = r.seasons.first;
      expect(s.kind, UpownerCollectionKind.season);
      expect(s.id, 1001);
      expect(s.name, '合集·A');
      expect(s.cover, 'https://i0.hdslb.com/bfs/archive/s.jpg');
      expect(s.description, '合集简介');
      expect(s.total, 20);
      expect(s.isAuto, isFalse);
      expect(r.series, hasLength(1));
      final s2 = r.series.single;
      expect(s2.kind, UpownerCollectionKind.series);
      expect(s2.id, 2001);
      expect(s2.name, '手作列表');
      expect(s2.creator, '');
      expect(s2.isAuto, isFalse);
    });

    test('total 是数字串（String）→ 容错解析；season_id 数字串也容错', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () =>
            _seasonsSeriesListBody(
              seasons: [
                _collectionItem(
                  _seasonMeta(seasonId: 1001, total: '37', name: '合集·数串'),
                ),
              ],
              series: [
                _collectionItem(
                  _seriesMeta(seriesId: 2001, total: '10', creator: 'auto'),
                ),
              ],
            ),
      });
      final r = await _api(adapter).fetchUpownerCollections(1);
      expect(r.seasons.single.total, 37);
      expect(r.series.single.total, 10);
      expect(r.series.single.isAuto, isTrue);
    });

    test('creator=auto 的系列 isAuto=true（页面层据此过滤直播回放）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () =>
            _seasonsSeriesListBody(
              series: [
                _collectionItem(_seriesMeta(creator: 'auto', name: '直播回放')),
                _collectionItem(_seriesMeta(creator: '', name: '自建')),
              ],
            ),
      });
      final r = await _api(adapter).fetchUpownerCollections(1);
      expect(r.series, hasLength(2));
      expect(r.series[0].isAuto, isTrue);
      expect(r.series[1].isAuto, isFalse);
    });

    test('脏条目过滤：缺 id / 空名 → 丢弃；items_lists 缺失 → 空结果', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () => {
          'code': 0,
          'message': 'OK',
          'data': {
            'items_lists': {
              'seasons_list': [
                _collectionItem({'season_id': 0, 'name': '坏id'}),
                _collectionItem({'season_id': 5, 'name': ''}),
                _collectionItem(_seasonMeta()),
              ],
            },
          },
        },
      });
      final r = await _api(adapter).fetchUpownerCollections(1);
      expect(r.seasons, hasLength(1));
      expect(r.seasons.single.id, 1001);

      final adapter2 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () => {
          'code': 0,
          'message': 'OK',
          'data': <String, dynamic>{},
        },
      });
      final empty = await _api(adapter2).fetchUpownerCollections(1);
      expect(empty.isEmpty, isTrue);
      expect(empty.seasons, isEmpty);
      expect(empty.series, isEmpty);
    });

    test('-412 → 抛风控异常；-352 → 抛限流异常', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () =>
            _seasonsSeriesListBody(code: -412),
      });
      expect(
        () => _api(adapter).fetchUpownerCollections(1),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -412)
              .having((e) => e.message, 'message', contains('风控')),
        ),
      );
      final adapter2 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () =>
            _seasonsSeriesListBody(code: -352),
      });
      expect(
        () => _api(adapter2).fetchUpownerCollections(1),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -352)
              .having((e) => e.message, 'message', contains('限流')),
        ),
      );
    });

    test('code=0 但无 data → 抛 BiliApiException（未返回数据）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_series_list': () => {
          'code': 0,
          'message': 'OK',
        },
      });
      expect(
        () => _api(adapter).fetchUpownerCollections(1),
        throwsA(
          isA<BiliApiException>().having((e) => e.code, 'code', -1),
        ),
      );
    });
  });

  group('fetchSeasonArchives', () {
    test('URL/参数：season_id/page_num/page_size', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () =>
            _archivesListBody(archives: [_archive()], total: 1),
      });
      await _api(adapter).fetchSeasonArchives(3993361, page: 2);
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/polymer/web-space/seasons_archives_list',
      );
      expect(req.queryParameters['season_id'], '3993361');
      expect(req.queryParameters['page_num'], '2');
      expect(req.queryParameters['page_size'], '20');
    });

    test('解析 archives[] → WhitelistVideo：无 cid=0、duration 秒、'
        'pubdate 记录、封面补全', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () =>
            _archivesListBody(
              archives: [
                _archive(
                  bvid: 'BV1aa',
                  title: '第一个视频',
                  pic: '//i0.hdslb.com/bfs/archive/a.jpg',
                  duration: 503,
                  pubdate: 1728792000,
                ),
                _archive(
                  bvid: 'BV1bb',
                  title: '第二个视频',
                  pic: 'https://i0.hdslb.com/bfs/archive/b.jpg',
                  duration: 0,
                  pubdate: 0,
                ),
              ],
              total: 2,
            ),
      });
      final page = await _api(adapter).fetchSeasonArchives(3993361);
      expect(page.videos, hasLength(2));
      final v = page.videos.first;
      expect(v.bvid, 'BV1aa');
      expect(v.title, '第一个视频');
      expect(v.cover, 'https://i0.hdslb.com/bfs/archive/a.jpg');
      expect(v.duration, 503);
      // 无 cid（播放页 view 补）；无 upper 名
      expect(v.cid, 0);
      expect(v.upName, '');
      expect(v.pubdate, 1728792000);
      // pubdate=0 的视频：pubdate 记 null、addedAt 用当前时间
      expect(page.videos[1].pubdate, isNull);
      expect(page.totalCount, 2);
      expect(page.hasMore, isFalse);
    });

    test('page.total > 已加载 → hasMore=true', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () =>
            _archivesListBody(
              archives: List.generate(20, (i) => _archive(bvid: 'BV$i')),
              total: 85,
            ),
      });
      final page = await _api(adapter).fetchSeasonArchives(1);
      expect(page.videos, hasLength(20));
      expect(page.hasMore, isTrue);
      expect(page.totalCount, 85);
    });

    test('空 archives / archives 缺失 → 空页（hasMore=false）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () =>
            _archivesListBody(archives: <Map<String, dynamic>>[], total: 0),
      });
      final page = await _api(adapter).fetchSeasonArchives(1);
      expect(page.videos, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('无 bvid 的脏条目被丢弃', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () =>
            _archivesListBody(archives: [
              {'aid': 1, 'title': '无bvid'},
              _archive(),
            ]),
      });
      final page = await _api(adapter).fetchSeasonArchives(1);
      expect(page.videos, hasLength(1));
    });

    test('错误分类：-412 风控 / 业务 code', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () => {
          'code': -412,
          'message': '风控校验失败',
          'data': <String, dynamic>{},
        },
      });
      expect(
        () => _api(adapter).fetchSeasonArchives(1),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -412)
              .having((e) => e.message, 'message', contains('风控')),
        ),
      );
      final adapter2 = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/polymer/web-space/seasons_archives_list': () => {
          'code': 62002,
          'message': '稿件已失效',
        },
      });
      expect(
        () => _api(adapter2).fetchSeasonArchives(1),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', 62002)
              .having((e) => e.path, 'path',
                  '/x/polymer/web-space/seasons_archives_list'),
        ),
      );
    });
  });

  group('fetchSeriesArchives', () {
    test('URL/参数：mid/series_id/pn/ps', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/series/archives': () => _archivesListBody(
          archives: [_archive()],
          total: 1,
        ),
      });
      await _api(adapter).fetchSeriesArchives(546195, 1614048, page: 3);
      final req = adapter.requests.lastWhere(
        (r) => r.path == '/x/series/archives',
      );
      expect(req.queryParameters['mid'], '546195');
      expect(req.queryParameters['series_id'], '1614048');
      expect(req.queryParameters['pn'], '3');
      expect(req.queryParameters['ps'], '20');
    });

    test('解析同 seasons_archives_list（cid=0；page.total 分页）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/series/archives': () => _archivesListBody(
          archives: [
            _archive(bvid: 'BV1aa', title: '列表视频'),
            _archive(bvid: 'BV1bb'),
          ],
          total: 2,
        ),
      });
      final page = await _api(adapter).fetchSeriesArchives(546195, 1614048);
      expect(page.videos, hasLength(2));
      expect(page.videos.first.bvid, 'BV1aa');
      expect(page.videos.first.cid, 0);
      expect(page.videos.first.duration, 503);
      expect(page.totalCount, 2);
      expect(page.hasMore, isFalse);
    });

    test('错误分类：-352 限流', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/series/archives': () => {'code': -352, 'message': '业务错误'},
      });
      expect(
        () => _api(adapter).fetchSeriesArchives(1, 2),
        throwsA(
          isA<BiliApiException>()
              .having((e) => e.code, 'code', -352)
              .having((e) => e.path, 'path', '/x/series/archives'),
        ),
      );
    });

    test('code=0 但无 data → 空页不抛错（合集可能已失效）', () async {
      final adapter = _RoutingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        '/x/series/archives': () => {'code': 0, 'message': 'OK'},
      });
      final page = await _api(adapter).fetchSeriesArchives(1, 2);
      expect(page.videos, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });
}
