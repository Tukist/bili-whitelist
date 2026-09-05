// WhitelistWriter 单元测试：
// - addVideo：查重（重复不写 Gist）/ 新增（PATCH 写 v3 规范化 JSON）
// - videoFromMeta：从 B 站 view 元数据构造 WhitelistVideo
// - 番剧（pgc）：videoFromPgcEpisode / pgcEpisodeTitle / episodeLabelOf
//   纯构造；顺序逐集 addVideo 的「查重跳过 + 落盘」导入流程
// - moveVideosToCollection / removeVideos：批量操作的纯函数（可单测）
// 不访问真实网络；ServiceLocator.syncService 换成假实现（跳过 path_provider）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';

/// 内存版 secure storage（对应原生 MethodChannel）。
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

/// 固定响应的 fake adapter：记录每次请求的 options。
class _FakeAdapter implements HttpClientAdapter {
  final int statusCode;
  final Map<String, dynamic> Function() bodyBuilder;
  final List<RequestOptions> requests = [];

  _FakeAdapter({required this.statusCode, required this.bodyBuilder});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(bodyBuilder()),
      statusCode,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

GithubApi _githubApi(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = adapter;
  return GithubApi(dio: dio);
}

/// 假同步服务：跳过 path_provider，saveToCache 空实现。
class _FakeSyncService extends WhitelistSyncService {
  @override
  Future<void> saveToCache(WhitelistData data) async {}
}

/// 初始 v3 Gist：2 个视频（BV1 未分类，BV2 在「动画」合集）。
const _v3Gist = '{"version":3,"updated_at":"2026-08-20T00:00:00Z",'
    '"collections":[{"name":"动画","created_at":"2026-08-01T00:00:00Z"}],'
    '"videos":['
    '{"bvid":"BV1","cid":1,"title":"视频一","cover":"","duration":60,'
    '"up_name":"up1","added_at":"2026-01-01T00:00:00Z","collection":""},'
    '{"bvid":"BV2","cid":2,"title":"视频二","cover":"","duration":120,'
    '"up_name":"up2","added_at":"2026-01-02T00:00:00Z","collection":"动画"}]}';

Map<String, dynamic> _gistBody() => {
      'id': 'gist1',
      'files': {
        'whitelist.json': {'content': _v3Gist},
      },
    };

/// 空白 v4 Gist 内容（番剧导入流程测试初始态）。
const _emptyGistV4 =
    '{"version":4,"updated_at":"2026-09-01T00:00:00Z",'
    '"collections":[],"upowners":[],"videos":[]}';

/// 仅含给定 bvid 的 v4 Gist 内容（预置「已在白名单」状态）。
String _v4GistWith(List<String> bvids) {
  final videos = bvids
      .map((b) => '{"bvid":"$b","cid":1,"title":"旧视频","cover":"",'
          '"duration":60,"up_name":"old","added_at":"2026-01-01T00:00:00Z",'
          '"collection":"","order":0}')
      .join(',');
  return '{"version":4,"updated_at":"2026-09-01T00:00:00Z",'
      '"collections":[],"upowners":[],"videos":[$videos]}';
}

/// 状态化 Gist adapter：GET 返回 [read] 的当前内容，PATCH 用请求体里
/// 的新内容调 [write] 更新。让「下一次 addVideo 的 GET 能看到上一次
/// PATCH 结果」，模拟真实 Gist 顺序写入。
class _MutableGistAdapter implements HttpClientAdapter {
  final String Function() read;
  final void Function(String content) write;
  final List<RequestOptions> requests = [];

  _MutableGistAdapter({required this.read, required this.write});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.method == 'PATCH') {
      final data = options.data as Map;
      final file = (data['files'] as Map)['whitelist.json'] as Map;
      final content = file['content'] as String;
      write(content);
      return ResponseBody.fromString(
        jsonEncode({
          'id': 'gist1',
          'files': {'whitelist.json': {'content': content}},
        }),
        200,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
      );
    }
    // GET /gists/:id
    return ResponseBody.fromString(
      jsonEncode({
        'id': 'gist1',
        'files': {'whitelist.json': {'content': read()}},
      }),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 按路径路由的 BiliApi fake adapter（供 importPgcSeason 测试注入
/// fetchPgcSeason 的 season 响应）。
class _BiliRoutingAdapter implements HttpClientAdapter {
  final Map<String, Map<String, dynamic> Function()> handlers;

  _BiliRoutingAdapter(this.handlers);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
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

WhitelistVideo _video(String bvid, String title, {int cid = 1}) =>
    WhitelistVideo(
      bvid: bvid,
      cid: cid,
      title: title,
      cover: '',
      duration: 60,
      upName: 'up',
      addedAt: '2026-01-01T00:00:00Z',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    ServiceLocator.overrideSyncService(_FakeSyncService());
  });

  group('addVideo（查重 + 写 Gist）', () {
    test('重复 bvid → added=false，不发起写请求', () async {
      final adapter =
          _FakeAdapter(statusCode: 200, bodyBuilder: _gistBody);
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      final writer = WhitelistWriter(github: _githubApi(adapter));

      final result = await writer.addVideo(_video('BV1', '视频一'));

      expect(result.added, isFalse);
      expect(result.message, contains('已在白名单'));
      // 只有 GET（拉取 gist），没有 PATCH
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, 'GET');
    });

    test('新增 bvid → added=true，PATCH 写 v3 规范化 JSON（含新视频）', () async {
      final adapter =
          _FakeAdapter(statusCode: 200, bodyBuilder: _gistBody);
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      final writer = WhitelistWriter(github: _githubApi(adapter));

      final result = await writer.addVideo(_video('BV3', '视频三'));

      expect(result.added, isTrue);
      expect(result.message, contains('已加入'));
      expect(result.data!.videos, hasLength(3));
      expect(result.data!.videos.last.bvid, 'BV3');
      // GET + PATCH 两次请求
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].method, 'GET');
      final patch = adapter.requests[1];
      expect(patch.method, 'PATCH');
      final content =
          ((patch.data as Map)['files'] as Map)['whitelist.json'] as Map;
      final parsed =
          jsonDecode(content['content'] as String) as Map<String, dynamic>;
      expect(parsed['version'], 4);
      expect((parsed['videos'] as List), hasLength(3));
    });
  });

  group('videoFromMeta', () {
    test('从 B 站 view 元数据构造 WhitelistVideo（含 pages/未分类/pubdate）', () {
      final meta = {
        'bvid': 'BV1xx411c7mD',
        'cid': 62131,
        'title': '测试视频',
        'pic': 'https://i0.hdslb.com/a.jpg',
        'duration': 600,
        'pubdate': 1682899200, // view data.pubdate，Unix 秒
        'owner': {'name': 'UP主'},
        'pages': [
          {'cid': 62131, 'part': 'P1', 'duration': 300},
          {'cid': 62132, 'part': 'P2', 'duration': 300},
        ],
      };
      final v = WhitelistWriter.videoFromMeta(meta,
          fallbackBvid: 'BV1xx411c7mD');
      expect(v.bvid, 'BV1xx411c7mD');
      expect(v.cid, 62131);
      expect(v.title, '测试视频');
      expect(v.cover, 'https://i0.hdslb.com/a.jpg');
      expect(v.upName, 'UP主');
      expect(v.pubdate, 1682899200); // 原值写入，无换算
      expect(v.pageCount, 2);
      expect(v.pages![1].part, 'P2');
      expect(v.isUncategorized, isTrue);
    });

    test('无 pages → 视为单 P；meta 无 pubdate → pubdate null（不写脏值）', () {
      final meta = {'bvid': 'BV1', 'cid': 1, 'title': 't'};
      final v = WhitelistWriter.videoFromMeta(meta, fallbackBvid: 'BV1');
      expect(v.pageCount, 1);
      expect(v.pages, isNull);
      expect(v.pubdate, isNull);
      expect(v.toJson().containsKey('pubdate'), isFalse);
    });

    test('meta pubdate=0/脏类型 → pubdate null（列表不显示）', () {
      final withZero = WhitelistWriter.videoFromMeta(
          {'bvid': 'BV1', 'cid': 1, 'title': 't', 'pubdate': 0},
          fallbackBvid: 'BV1');
      expect(withZero.pubdate, isNull);
      final withStr = WhitelistWriter.videoFromMeta(
          {'bvid': 'BV1', 'cid': 1, 'title': 't', 'pubdate': '1682899200'},
          fallbackBvid: 'BV1');
      expect(withStr.pubdate, isNull);
    });
  });

  group('番剧（pgc）单集 → WhitelistVideo', () {
    final season = PgcSeason.fromResult({
      'title': '小林家的龙女仆',
      'cover': 'http://i0.hdslb.com/a.png',
      'season_id': 5800,
      'episodes': [
        {
          'ep_id': 98603,
          'aid': 7961887,
          'cid': 481327329,
          'bvid': 'BV1gs411h7DE',
          'title': '1',
          'long_title': '史上最强女仆、托尔！',
          'cover': 'http://i0.hdslb.com/b.jpg',
          'badge': '',
          'duration': 1377000,
          'pub_time': 1484067600, // Unix 秒（单位与普通 view data.pubdate 一致）
        },
        {
          'ep_id': 318143,
          'aid': 1,
          'cid': 2,
          'bvid': 'BV18C4y147xR',
          'title': '14(OVA)',
          'long_title': '情人节，然后泡温泉!',
          'cover': '',
          'badge': '会员',
          'duration': 1500000,
          'pub_time': 1484672400,
        },
      ],
    });

    test('episodeLabelOf：纯数字 → 第X话；带后缀原样', () {
      expect(WhitelistWriter.episodeLabelOf('1'), '第1话');
      expect(WhitelistWriter.episodeLabelOf('14(OVA)'), '14(OVA)');
      expect(WhitelistWriter.episodeLabelOf(''), '');
      expect(WhitelistWriter.episodeLabelOf(' 2 '), '第2话');
    });

    test('pgcEpisodeTitle：剧名 + 第X话 + 副标题', () {
      expect(
        WhitelistWriter.pgcEpisodeTitle(season, season.episodes[0]),
        '小林家的龙女仆 第1话 史上最强女仆、托尔！',
      );
      // OVA：集数带后缀不套「话」
      expect(
        WhitelistWriter.pgcEpisodeTitle(season, season.episodes[1]),
        '小林家的龙女仆 14(OVA) 情人节，然后泡温泉!',
      );
    });

    test('videoFromPgcEpisode：up_name/时长秒/pages 单集/未分类', () {
      final v = WhitelistWriter.videoFromPgcEpisode(season, season.episodes[0],
          now: DateTime.utc(2026, 9, 1));
      expect(v.bvid, 'BV1gs411h7DE');
      expect(v.cid, 481327329);
      expect(v.title, '小林家的龙女仆 第1话 史上最强女仆、托尔！');
      expect(v.duration, 1377); // 毫秒已换算为秒
      expect(v.upName, '番剧/官方');
      expect(v.collection, '');
      expect(v.isUncategorized, isTrue);
      expect(v.pageCount, 1);
      expect(v.pages!.single.cid, 481327329);
      expect(v.pages!.single.part, '第1话 史上最强女仆、托尔！');
      expect(v.addedAt, '2026-09-01T00:00:00.000Z');
    });

    test('videoFromPgcEpisode：pubdate 透传 pub_time（秒，不换算）', () {
      final v = WhitelistWriter.videoFromPgcEpisode(season, season.episodes[0],
          now: DateTime.utc(2026, 9, 1));
      expect(v.pubdate, 1484067600); // PgcEpisode.pubTimeSec 原值
      // toJson 往返保留（整季导入 → 列表显示发布时间链路不丢）
      final back = WhitelistVideo.fromJson(v.toJson());
      expect(back.pubdate, 1484067600);
    });

    test('videoFromPgcEpisode：无 pub_time（0）→ pubdate null', () {
      final noTime = PgcSeason.fromResult({
        'title': '无时间番',
        'episodes': [
          {
            'ep_id': 1,
            'aid': 1,
            'cid': 11,
            'bvid': 'BVnotime',
            'title': '1',
            'long_title': '',
            'cover': '',
            'badge': '',
            'duration': 60000, // 无 pub_time 字段 → 0
          },
        ],
      });
      final v = WhitelistWriter.videoFromPgcEpisode(
          noTime, noTime.episodes[0]);
      expect(v.pubdate, isNull);
      expect(v.toJson().containsKey('pubdate'), isFalse);
    });

    test('videoFromPgcEpisode：写入 epId（免费集与会员集），toJson 往返保留', () {
      final free = WhitelistWriter.videoFromPgcEpisode(
          season, season.episodes[0],
          now: DateTime.utc(2026, 9, 1));
      expect(free.epId, 98603); // 透传 ep_id
      final vip = WhitelistWriter.videoFromPgcEpisode(season, season.episodes[1],
          now: DateTime.utc(2026, 9, 1));
      expect(vip.epId, 318143);

      // 写回 Gist 的 JSON 里带 epId，读回来仍在（整季导入 → 播放回退链路不丢）
      final back = WhitelistVideo.fromJson(free.toJson());
      expect(back.epId, 98603);
      expect(back.title, '小林家的龙女仆 第1话 史上最强女仆、托尔！');
    });
  });

  group('番剧整季顺序导入流程（逐集 addVideo：查重跳过 + 增量落盘）', () {
    /// 状态化 Gist：GET 返回 currentContent，PATCH 用 body 更新 currentContent。
    /// 模拟连续多次 addVideo 时「下一次 GET 能看到上一次 PATCH 结果」。
    Dio statefulGistDio(String initialJson) {
      var current = initialJson;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
      dio.httpClientAdapter = _MutableGistAdapter(
        read: () => current,
        write: (String c) => current = c,
      );
      return dio;
    }

    final season = PgcSeason.fromResult({
      'title': '测试番',
      'cover': '',
      'season_id': 1,
      'episodes': [
        {
          'ep_id': 1,
          'aid': 1,
          'cid': 11,
          'bvid': 'BVpgc1',
          'title': '1',
          'long_title': '第一集',
          'cover': '',
          'badge': '',
          'duration': 60000,
        },
        {
          'ep_id': 2,
          'aid': 2,
          'cid': 22,
          'bvid': 'BVpgc2',
          'title': '2',
          'long_title': '第二集',
          'cover': '',
          'badge': '会员',
          'duration': 70000,
        },
      ],
    });

    test('空白名单逐集导入 → 2 集全新增', () async {
      final dio = statefulGistDio(_emptyGistV4);
      final writer = WhitelistWriter(
        github: _githubApi(dio.httpClientAdapter),
      );
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';

      var added = 0, skipped = 0;
      for (final ep in season.episodes) {
        final r = await writer.addVideo(
            WhitelistWriter.videoFromPgcEpisode(season, ep));
        if (r.added) {
          added++;
        } else if (r.message.contains('已在白名单')) {
          skipped++;
        }
      }
      expect(added, 2);
      expect(skipped, 0);
    });

    test('白名单已有其中 1 集 → 跳过已存在、只新增 1 集（bvids 不重复）', () async {
      // 初始 Gist 已含 BVpgc1（第 1 集）
      final initial = _v4GistWith(['BVpgc1']);
      final dio = statefulGistDio(initial);
      final writer = WhitelistWriter(
        github: _githubApi(dio.httpClientAdapter),
      );
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';

      var added = 0, skipped = 0;
      for (final ep in season.episodes) {
        final r = await writer.addVideo(
            WhitelistWriter.videoFromPgcEpisode(season, ep));
        if (r.added) {
          added++;
        } else if (r.message.contains('已在白名单')) {
          skipped++;
        }
      }
      expect(added, 1);
      expect(skipped, 1);

      // 最终 Gist 数据核对：bvids 去重
      final finalData = await writer.github.fetchFromGist();
      expect(finalData!.videos, hasLength(2));
      expect(finalData.videos.map((v) => v.bvid).toSet(),
          {'BVpgc1', 'BVpgc2'});
    });
  });

  group('importPgcSeason（整季导入入口：拉整季 + 逐集 addVideo）', () {
    /// 状态化 Gist（GET 返回当前 / PATCH 更新），模拟真实顺序写入。
    Dio statefulGistDio(String initialJson) {
      var current = initialJson;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
      dio.httpClientAdapter = _MutableGistAdapter(
        read: () => current,
        write: (String c) => current = c,
      );
      return dio;
    }

    /// BiliApi 路由：spi（buvid 指纹）+ pgc season 接口。
    Dio biliDio(Map<String, dynamic> seasonResult) {
      final dio = Dio(
        BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()),
      );
      dio.httpClientAdapter = _BiliRoutingAdapter({
        '/x/frontend/finger/spi': () => {
              'code': 0,
              'data': {'b_3': 'buvid3t', 'b_4': 'buvid4t'},
            },
        '/pgc/view/web/season': () => {
              'code': 0,
              'message': '0',
              'result': seasonResult,
            },
      });
      return dio;
    }

    final seasonResult = {
      'season_id': 1,
      'title': '测试番',
      'cover': '',
      'episodes': [
        {
          'ep_id': 1,
          'aid': 1,
          'cid': 11,
          'bvid': 'BVpgc1',
          'title': '1',
          'long_title': '第一集',
          'cover': '',
          'badge': '',
          'duration': 60000,
        },
        {
          'ep_id': 2,
          'aid': 2,
          'cid': 22,
          'bvid': 'BVpgc2',
          'title': '2',
          'long_title': '第二集',
          'cover': '',
          'badge': '会员',
          'duration': 70000,
        },
      ],
    };

    test('空白名单整季导入 → added=2 skipped=0，进度回调按集上报', () async {
      final dio = statefulGistDio(_emptyGistV4);
      final writer = WhitelistWriter(
        github: _githubApi(dio.httpClientAdapter),
        api: BiliApi(dio: biliDio(seasonResult)),
      );
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';

      final progress = <String>[];
      final summary = await writer.importPgcSeason(
        seasonId: 1,
        onProgress: progress.add,
      );
      expect(summary.season.title, '测试番');
      expect(summary.added, 2);
      expect(summary.skipped, 0);
      expect(summary.interrupted, isFalse);
      // 进度文案覆盖「准备导入」+ 逐集「导入中 i/N」
      expect(progress.first, contains('准备导入「测试番」'));
      expect(progress.length, 3);
      expect(progress[1], contains('导入中 1/2'));
      expect(progress[2], contains('导入中 2/2'));
    });

    test('白名单已有其中 1 集 → added=1 skipped=1', () async {
      final dio = statefulGistDio(_v4GistWith(['BVpgc1']));
      final writer = WhitelistWriter(
        github: _githubApi(dio.httpClientAdapter),
        api: BiliApi(dio: biliDio(seasonResult)),
      );
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';

      final summary = await writer.importPgcSeason(seasonId: 1);
      expect(summary.added, 1);
      expect(summary.skipped, 1);
      expect(summary.interrupted, isFalse);
      final finalData = await writer.github.fetchFromGist();
      expect(finalData!.videos.map((v) => v.bvid).toSet(),
          {'BVpgc1', 'BVpgc2'});
    });

    test('拉整季失败（-404）→ BiliApiException 上抛，未写 Gist', () async {
      final dio = statefulGistDio(_emptyGistV4);
      final bad = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
      bad.httpClientAdapter = _BiliRoutingAdapter({
        '/x/frontend/finger/spi': () => {
              'code': 0,
              'data': {'b_3': 'b', 'b_4': 'b'},
            },
        '/pgc/view/web/season': () => {
              'code': -404,
              'message': '啥都木有',
            },
      });
      final writer = WhitelistWriter(
        github: _githubApi(dio.httpClientAdapter),
        api: BiliApi(dio: bad),
      );
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';

      await expectLater(
        writer.importPgcSeason(seasonId: 999),
        throwsA(isA<BiliApiException>()),
      );
    });
  });

  group('批量操作纯函数', () {
    final data = WhitelistData.fromJson({
      'version': 3,
      'collections': [
        {'name': '动画', 'created_at': '2026-08-01T00:00:00Z'},
        {'name': '番剧', 'created_at': '2026-08-02T00:00:00Z'},
      ],
      'videos': [
        {
          'bvid': 'BV1',
          'cid': 1,
          'title': '一',
          'up_name': 'u',
          'added_at': '2026-01-01T00:00:00Z',
          'collection': '',
        },
        {
          'bvid': 'BV2',
          'cid': 2,
          'title': '二',
          'up_name': 'u',
          'added_at': '2026-01-01T00:00:00Z',
          'collection': '动画',
        },
        {
          'bvid': 'BV3',
          'cid': 3,
          'title': '三',
          'up_name': 'u',
          'added_at': '2026-01-01T00:00:00Z',
          'collection': '番剧',
        },
      ],
    });

    test('moveVideosToCollection：只改指定 bvid，其余不动', () {
      final next = WhitelistWriter.moveVideosToCollection(data, {'BV1'}, '动画');
      String coll(String bvid) =>
          next.videos.firstWhere((v) => v.bvid == bvid).collection;
      expect(coll('BV1'), '动画'); // 被移动
      expect(coll('BV2'), '动画'); // 原样
      expect(coll('BV3'), '番剧'); // 原样
      expect(next.collections, hasLength(2)); // 合集定义不变
    });

    test('moveVideosToCollection：空串 = 移回未分类', () {
      final next = WhitelistWriter.moveVideosToCollection(data, {'BV2', 'BV3'}, '');
      String coll(String bvid) =>
          next.videos.firstWhere((v) => v.bvid == bvid).collection;
      expect(coll('BV2'), '');
      expect(coll('BV3'), '');
      expect(coll('BV1'), '');
    });

    test('moveVideosToCollection：空集合原样返回', () {
      expect(identical(WhitelistWriter.moveVideosToCollection(data, {}, '动画'), data),
          isTrue);
    });

    test('removeVideos：删除指定 bvid，保留其余', () {
      final next = WhitelistWriter.removeVideos(data, {'BV1', 'BV3'});
      expect(next.videos.map((v) => v.bvid).toList(), ['BV2']);
    });

    test('removeVideos：空集合原样返回', () {
      expect(identical(WhitelistWriter.removeVideos(data, {}), data), isTrue);
    });
  });
}
