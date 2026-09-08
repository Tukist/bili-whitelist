// 收藏夹导入流程单元测试（v2.17.5+）：
// - WhitelistWriter.importFavoriteFolder：翻页拉视频 → 逐条「查重跳过 →
//   view 补 meta → 写盘」；失效（62002）计失败跳过不中断；拉列表阶段失败
//   上抛（未写 Gist）；进度回调覆盖「读取收藏夹/导入中 i/N」
// - runFavoritesImportFlow（UI 编排）：未登录 → 提示 + 引导登录（不发请求）；
//   已登录但收藏夹为空 → 空态提示
// 不访问真实网络（BiliApi/GithubApi 均注入 mock adapter）。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/api/github_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/models/whitelist_video.dart';
import 'package:bili_whitelist_app/pages/playlist_page.dart';
import 'package:bili_whitelist_app/services/service_locator.dart';
import 'package:bili_whitelist_app/services/whitelist_writer.dart';
import 'package:bili_whitelist_app/sync/whitelist_source.dart';
import 'package:bili_whitelist_app/widgets/favorites_import_dialog.dart';

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

/// 状态化 Gist adapter（GET 当前 / PATCH 更新），模拟真实顺序写入。
class _MutableGistAdapter implements HttpClientAdapter {
  final String Function() read;
  final void Function(String content) write;

  _MutableGistAdapter({required this.read, required this.write});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
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

/// BiliApi 路由：按 path + queryParameters 分发（view 按 bvid 返回不同 meta）。
class _BiliRouter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options)? onRequest;
  final List<RequestOptions> requests = [];

  _BiliRouter({this.onRequest});

  Map<String, dynamic> _base(RequestOptions o) {
    // spi 指纹
    if (o.path == '/x/frontend/finger/spi') {
      return {
        'code': 0,
        'data': {'b_3': 'b3t', 'b_4': 'b4t'},
      };
    }
    // nav：wbi keys（fetchVideoMeta 用）
    if (o.path == '/x/web-interface/nav') {
      return {
        'code': 0,
        'data': {
          'isLogin': true,
          'mid': 123456,
          'wbi_img': {
            // 32 位十六进制 key（置换表 mixinKey 需 img+sub ≥64 字符）
            'img_url':
                'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
            'sub_url':
                'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
          },
        },
      };
    }
    return onRequest?.call(o) ??
        {
          'code': -1,
          'message': 'no route: ${o.path}',
        };
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(_base(options)),
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _gistDio(String Function() read, void Function(String) write) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.github.com'));
  dio.httpClientAdapter = _MutableGistAdapter(read: read, write: write);
  return dio;
}

/// 空白 v4 Gist。
const _emptyGistV4 =
    '{"version":4,"updated_at":"2026-09-01T00:00:00Z",'
    '"collections":[],"upowners":[],"videos":[]}';

String _gistWith(List<String> bvids) {
  final videos = bvids
      .map((b) => '{"bvid":"$b","cid":1,"title":"旧视频","cover":"",'
          '"duration":60,"up_name":"old","added_at":"2026-01-01T00:00:00Z",'
          '"collection":"","order":0}')
      .join(',');
  return '{"version":4,"updated_at":"2026-09-01T00:00:00Z",'
      '"collections":[],"upowners":[],"videos":[$videos]}';
}

/// view 接口的 data 对象（videoFromMeta 用字段）。
Map<String, dynamic> _viewData(String bvid, String title) => {
      'bvid': bvid,
      'cid': 1001,
      'title': title,
      'pic': 'http://i0.hdslb.com/bfs/archive/$bvid.jpg',
      'duration': 300,
      'owner': {'mid': 7, 'name': 'UP甲'},
      'pages': [
        {'cid': 1001, 'part': 'P1', 'duration': 300},
      ],
      'pubdate': 1589627926,
      'desc': '简介$bvid',
    };

/// 收藏夹视频页响应（单页，has_more=false）。
Map<String, dynamic> _favPage(List<Map<String, dynamic>> medias) => {
      'code': 0,
      'message': 'success',
      'data': {
        'count': medias.length,
        'has_more': false,
        'medias': medias,
      },
    };

Map<String, dynamic> _favMedia(String bvid, String title) => {
      'id': 1,
      'type': 2,
      'bvid': bvid,
      'cid': 1,
      'title': title,
      'cover': '',
      'upper': {'mid': 7, 'name': 'UP甲'},
      'duration': 300,
      'pubtime': 1589627926,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _store.clear();
    _mockSecureStorage();
    ServiceLocator.overrideSyncService(_FakeSyncService());
  });

  WhitelistWriter makeWriter({
    required _BiliRouter bili,
    required String Function() read,
    required void Function(String) write,
  }) {
    final ghDio = _gistDio(read, write);
    return WhitelistWriter(
      github: GithubApi(dio: ghDio),
      api: BiliApi(
        dio: Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()))
          ..httpClientAdapter = bili,
      ),
    );
  }

  group('importFavoriteFolder（收藏夹批量导入核心逻辑）', () {
    test('新增 2 + 白名单已有 1 → added=2 skipped=1，进度逐条上报',
        () async {
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      var current = _gistWith(['BV-skip']); // BV-skip 已在白名单
      final bili = _BiliRouter(onRequest: (o) {
        if (o.path == '/x/v3/fav/resource/list') {
          return _favPage([
            _favMedia('BV-skip', '已在白名单的视频'),
            _favMedia('BV-new1', '新视频一'),
            _favMedia('BV-new2', '新视频二'),
          ]);
        }
        if (o.path == '/x/web-interface/view') {
          final bvid = o.queryParameters['bvid'] as String? ?? '';
          return {
            'code': 0,
            'data': _viewData(bvid, '标题$bvid'),
          };
        }
        return {'code': -1, 'message': 'no route'};
      });
      final writer = makeWriter(
        bili: bili,
        read: () => current,
        write: (c) => current = c,
      );

      final progress = <String>[];
      final summary = await writer.importFavoriteFolder(
        mediaId: 2670055339,
        folderTitle: '测试收藏夹',
        onProgress: progress.add,
      );

      expect(summary.total, 3);
      expect(summary.added, 2);
      expect(summary.skipped, 1); // BV-skip 查重跳过
      expect(summary.failed, 0);
      expect(summary.interrupted, isFalse);

      // 进度：读取 + 逐条导入中 i/N（用收藏夹雏形标题，view 补全前上报）
      expect(progress.first, contains('正在读取收藏夹「测试收藏夹」'));
      expect(progress[1], contains('导入中 1/3：已在白名单的视频'));
      expect(progress[3], contains('导入中 3/3：新视频二'));

      // view 复检只打给不在白名单的视频（BV-skip 不发请求）
      final viewReqs = bili.requests
          .where((r) => r.path == '/x/web-interface/view')
          .toList();
      expect(viewReqs.map((r) => r.queryParameters['bvid']).toSet(),
          {'BV-new1', 'BV-new2'});

      final finalData = await writer.github.fetchFromGist();
      expect(finalData!.videos.map((v) => v.bvid).toSet(),
          {'BV-skip', 'BV-new1', 'BV-new2'});
      final imported = finalData.videos.firstWhere((v) => v.bvid == 'BV-new1');
      expect(imported.title, '标题BV-new1'); // view meta 覆盖收藏夹雏形
      expect(imported.cid, 1001);
      expect(imported.desc, '简介BV-new1');
    });

    test('失效条目（view code=62002）→ failed 计数跳过，不中断其余导入',
        () async {
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      var current = _emptyGistV4;
      final bili = _BiliRouter(onRequest: (o) {
        if (o.path == '/x/v3/fav/resource/list') {
          return _favPage([
            _favMedia('BV-dead', '已失效视频'),
            _favMedia('BV-ok', '正常视频'),
          ]);
        }
        if (o.path == '/x/web-interface/view') {
          final bvid = o.queryParameters['bvid'] as String? ?? '';
          if (bvid == 'BV-dead') {
            return {
              'code': 62002,
              'message': '稿件已失效',
            };
          }
          return {'code': 0, 'data': _viewData(bvid, '标题$bvid')};
        }
        return {'code': -1, 'message': 'no route'};
      });
      final writer = makeWriter(
        bili: bili,
        read: () => current,
        write: (c) => current = c,
      );

      final summary = await writer.importFavoriteFolder(
        mediaId: 2670055339,
        folderTitle: '测试收藏夹',
      );
      expect(summary.total, 2);
      expect(summary.added, 1);
      expect(summary.failed, 1); // BV-dead
      expect(summary.skipped, 0);
      expect(summary.interrupted, isFalse);
      final finalData = await writer.github.fetchFromGist();
      expect(finalData!.videos.map((v) => v.bvid).toList(), ['BV-ok']);
    });

    test('拉列表阶段失败（-412）→ BiliApiException 上抛，未写 Gist', () async {
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      var current = _emptyGistV4;
      final bili = _BiliRouter(onRequest: (o) {
        if (o.path == '/x/v3/fav/resource/list') {
          return {
            'code': -412,
            'message': '请求被拦截',
          };
        }
        return {'code': -1, 'message': 'no route'};
      });
      final writer = makeWriter(
        bili: bili,
        read: () => current,
        write: (c) => current = c,
      );

      await expectLater(
        writer.importFavoriteFolder(mediaId: 1, folderTitle: '夹'),
        throwsA(isA<BiliApiException>().having((e) => e.code, 'code', -412)),
      );
      // 未写任何东西（仍是初始空 v4）
      final after = await writer.github.fetchFromGist();
      expect(after?.videos, isEmpty);
      expect(after?.collections, isEmpty);
    });

    test('收藏夹为空 → total=0 空汇总（不抛、不写）', () async {
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      var current = _emptyGistV4;
      final bili = _BiliRouter(onRequest: (o) {
        if (o.path == '/x/v3/fav/resource/list') {
          return _favPage([]);
        }
        return {'code': -1, 'message': 'no route'};
      });
      final writer = makeWriter(
        bili: bili,
        read: () => current,
        write: (c) => current = c,
      );
      final summary = await writer.importFavoriteFolder(
        mediaId: 1,
        folderTitle: '空夹',
      );
      expect(summary.total, 0);
      expect(summary.added, 0);
      expect(summary.interrupted, isFalse);
    });
  });

  group('runFavoritesImportFlow（UI 门禁与反馈）', () {
    testWidgets('未登录（无 SESSDATA）→ 提示需登录并引导登录，不发收藏夹请求',
        (tester) async {
      // 配置好 GitHub（通过存储键）；B 站 SESSDATA 为空 → 未登录
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      var openedLogin = 0;
      final bili = _BiliRouter(); // 若走到网络请求会 404 → 不应发生
      final ghDio = _gistDio(() => _emptyGistV4, (_) {});
      final writer = WhitelistWriter(
        github: GithubApi(dio: ghDio),
        api: BiliApi(
          dio: Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()))
            ..httpClientAdapter = bili,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => runFavoritesImportFlow(
                    context: context,
                    writer: writer,
                    configHint: '请先配置 GitHub',
                    openLogin: () async {
                      openedLogin++;
                      return false; // 用户保持匿名
                    },
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump();

      // 提示需登录 + 引导登录被调用一次；不发收藏夹网络请求
      expect(find.text('收藏夹导入需要登录 B 站账号（收藏夹属于个人账号数据）'),
          findsOneWidget);
      expect(openedLogin, 1);
      expect(bili.requests, isEmpty);
    });

    testWidgets('已登录但收藏夹为空 → 弹层显示空态文案', (tester) async {
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      _store['bili_sessdata'] = 'sess_test'; // 已登录
      final bili = _BiliRouter(onRequest: (o) {
        if (o.path == '/x/v3/fav/folder/created/list-all') {
          return {
            'code': 0,
            'message': 'success',
            'data': {'list': []},
          };
        }
        return {'code': -1, 'message': 'no route'};
      });
      final ghDio = _gistDio(() => _emptyGistV4, (_) {});
      final writer = WhitelistWriter(
        github: GithubApi(dio: ghDio),
        api: BiliApi(
          dio: Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()))
            ..httpClientAdapter = bili,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => runFavoritesImportFlow(
                    context: context,
                    writer: writer,
                    configHint: '请先配置 GitHub',
                    openLogin: () async => true,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // 收藏夹空态（未误入错误/未发资源请求）
      expect(find.textContaining('没有收藏夹'), findsOneWidget);
      expect(
        bili.requests
            .where((r) => r.path == '/x/v3/fav/resource/list'),
        isEmpty,
      );
    });
  });

  group('首页入口（导入对话框内「从 B 站收藏夹批量导入」按钮）', () {
    testWidgets('未登录：入口存在；点按 → 弹「需登录」提示并引导登录',
        (tester) async {
      _store[GithubApi.kTokenKey] = 'ghp_fake';
      _store[GithubApi.kGistIdKey] = 'gist1';
      // 不注入 SESSDATA → 未登录

      // 记录「请求打开登录页」的替身（同 auto_login_test._LoginSpy）
      var loginCalls = 0;
      Future<void> openLoginSpy(BuildContext context, {String? banner}) async {
        loginCalls++;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: PlaylistPage(openLogin: openLoginSpy),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 1) 打开导入对话框 → 入口按钮存在
      await tester.tap(find.byTooltip('导入视频'));
      await tester.pump();
      await tester.pump();
      expect(find.text('从 B 站收藏夹批量导入'), findsOneWidget);
      expect(find.textContaining('把整个收藏夹'), findsOneWidget);

      // 2) 点按入口 → 关闭粘贴对话框；未登录 → snack 提示 + 引导登录
      await tester.tap(find.text('从 B 站收藏夹批量导入'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(loginCalls, greaterThan(0));
      expect(find.text('收藏夹导入需要登录 B 站账号（收藏夹属于个人账号数据）'),
          findsOneWidget);
    });
  });
}
