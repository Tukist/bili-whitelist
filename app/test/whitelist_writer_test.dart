// WhitelistWriter 单元测试：
// - addVideo：查重（重复不写 Gist）/ 新增（PATCH 写 v3 规范化 JSON）
// - videoFromMeta：从 B 站 view 元数据构造 WhitelistVideo
// - moveVideosToCollection / removeVideos：批量操作的纯函数（可单测）
// 不访问真实网络；ServiceLocator.syncService 换成假实现（跳过 path_provider）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/github_api.dart';
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
      expect(parsed['version'], 3);
      expect((parsed['videos'] as List), hasLength(3));
    });
  });

  group('videoFromMeta', () {
    test('从 B 站 view 元数据构造 WhitelistVideo（含 pages/未分类）', () {
      final meta = {
        'bvid': 'BV1xx411c7mD',
        'cid': 62131,
        'title': '测试视频',
        'pic': 'https://i0.hdslb.com/a.jpg',
        'duration': 600,
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
      expect(v.pageCount, 2);
      expect(v.pages![1].part, 'P2');
      expect(v.isUncategorized, isTrue);
    });

    test('无 pages → 视为单 P', () {
      final meta = {'bvid': 'BV1', 'cid': 1, 'title': 't'};
      final v = WhitelistWriter.videoFromMeta(meta, fallbackBvid: 'BV1');
      expect(v.pageCount, 1);
      expect(v.pages, isNull);
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
