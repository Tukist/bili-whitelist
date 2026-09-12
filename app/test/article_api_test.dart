// BiliApi 专栏接口单测（mock dio，不访问真实网络）。
//
// 覆盖：
// - fetchUserArticles 请求构造：`/x/space/article` + mid/pn/ps，**不需要 WBI
//   签名**（不请求 nav、query 里没有 w_rid/wts；匿名 buvid 指纹照常注入）
// - 解析：articles[] → ArticleSummary（cvid/title/summary/图片归一化/banner/
//   时间/字数/统计）；count + pn/ps → hasMore（count 缺失时按"装满一页"兜底）
// - fetchArticleView 请求构造：`/x/article/view` 的参数名是 **id**（不是 cv）
// - 正文解析：content（HTML 字符串）/ 标题 / 作者（名字 + mid + 头像）/ 统计
// - -509（请求过于频繁）→ 退避重试一次；两次都 -509 → 抛可读异常
// - -412 风控 / -352 限流 → 分类抛 BiliApiException；其它业务码带服务端 message
// - 脏 data（null / articles 非 List / 空 cvid / 重复 cvid）不崩；正文缺 data 抛
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';

const String _kListPath = '/x/space/article';
const String _kViewPath = '/x/article/view';

void _mockSecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => null);
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.handlers);

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

Map<String, dynamic> _spiBody(RequestOptions _) => {
      'code': 0,
      'data': {'b_3': 'buvid3test', 'b_4': 'buvid4test'},
    };

Map<String, dynamic> _listItem(
  int id, {
  String title = '专栏标题',
  String summary = '摘要',
  int publishTime = 1730000000,
  int words = 1200,
  List<String>? images,
  String? banner,
  Map<String, dynamic>? stats,
}) =>
    {
      'id': id,
      'title': title,
      'summary': summary,
      'publish_time': publishTime,
      'words': words,
      'image_urls': images ?? ['//i0.hdslb.com/bfs/article/a.jpg'],
      if (banner != null) 'banner_url': banner,
      'stats': stats ??
          {
            'view': 1234,
            'favorite': 12,
            'like': 34,
            'reply': 5,
            'share': 6,
            'coin': 7,
          },
    };

Map<String, dynamic> _listBody({
  List<Map<String, dynamic>>? articles,
  int pn = 1,
  int ps = 10,
  int? count,
  int code = 0,
  String? message,
}) =>
    {
      'code': code,
      if (message != null) 'message': message,
      'data': {
        if (articles != null) 'articles': articles,
        'pn': pn,
        'ps': ps,
        if (count != null) 'count': count,
      },
    };

Map<String, dynamic> _viewBody({
  String content = '<p>正文</p>',
  int code = 0,
  String? message,
  Map<String, dynamic>? data,
}) =>
    {
      'code': code,
      if (message != null) 'message': message,
      'data': data ??
          {
            'id': 45123193,
            'title': '专栏标题',
            'content': content,
            'publish_time': 1730000000,
            'author': {
              'mid': 946974,
              'name': '测试作者',
              'face': '//i0.hdslb.com/bfs/face/f.jpg',
            },
            'image_urls': ['//i0.hdslb.com/bfs/article/a.jpg'],
            'stats': {
              'view': 1932290,
              'favorite': 485,
              'like': 9765,
              'reply': 392,
              'share': 1,
              'coin': 70,
            },
          },
    };

BiliApi _api(_RecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockSecureStorage);

  group('fetchUserArticles', () {
    test('请求构造：不需要 WBI 签名；解析条目/图片/统计/总数', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (_) => _listBody(
              articles: [
                _listItem(
                  111,
                  banner: '//i0.hdslb.com/bfs/article/banner.jpg',
                ),
                _listItem(222, title: '第二篇', summary: '第二篇摘要'),
              ],
              count: 42,
            ),
      });
      final api = _api(adapter);

      final page = await api.fetchUserArticles(946974, pn: 1, ps: 10);

      expect(page.items.map((a) => a.cvid), [111, 222]);
      final first = page.items.first;
      expect(first.title, '专栏标题');
      expect(first.summary, '摘要');
      expect(first.publishTs, 1730000000);
      expect(first.words, 1200);
      expect(first.imageUrls, ['https://i0.hdslb.com/bfs/article/a.jpg']);
      expect(first.bannerUrl, 'https://i0.hdslb.com/bfs/article/banner.jpg');
      expect(first.coverUrl, 'https://i0.hdslb.com/bfs/article/banner.jpg');
      expect(first.view, 1234);
      expect(first.favorite, 12);
      expect(first.like, 34);
      expect(first.reply, 5);
      expect(first.share, 6);
      expect(first.coin, 7);
      // 无 banner 时封面退回正文首图
      expect(page.items[1].coverUrl, 'https://i0.hdslb.com/bfs/article/a.jpg');
      expect(page.count, 42);
      expect(page.pn, 1);
      expect(page.ps, 10);
      expect(page.hasMore, isTrue, reason: '1×10 < 42');

      final req = adapter.forPath(_kListPath).single;
      expect(req.queryParameters['mid'], '946974');
      expect(req.queryParameters['pn'], '1');
      expect(req.queryParameters['ps'], '10');
      expect(req.queryParameters['w_rid'], isNull, reason: '专栏接口不签名');
      expect(req.queryParameters['wts'], isNull);
      expect(adapter.forPath('/x/web-interface/nav'), isEmpty,
          reason: '不取 WBI key');
      final cookie = req.headers['Cookie'] as String? ?? '';
      expect(cookie, contains('buvid3=buvid3test'), reason: '匿名 buvid 指纹');
    });

    test('hasMore：count 有效按总数算；count 缺失时按「装满一页」兜底', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (req) {
          final pn = int.tryParse(req.queryParameters['pn'] as String? ?? '1')!;
          if (pn == 1) {
            // 第 1 页：10 条装满，count 缺失（B 站 0 篇时连字段都不给）
            return _listBody(
              articles: [for (var i = 1; i <= 10; i++) _listItem(i)],
              pn: 1,
            );
          }
          // 第 2 页：空 → 到底
          return _listBody(articles: const [], pn: 2);
        },
      });
      final api = _api(adapter);

      final first = await api.fetchUserArticles(1, pn: 1, ps: 10);
      expect(first.hasMore, isTrue, reason: 'count 缺失 + 装满一页 → 还有下一页');

      final second = await api.fetchUserArticles(1, pn: 2, ps: 10);
      expect(second.isEmpty, isTrue);
      expect(second.hasMore, isFalse, reason: '空页 → 到底');
    });

    test('count 已知时到底（pn×ps >= count）', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (_) =>
            _listBody(articles: [_listItem(1)], pn: 2, ps: 10, count: 11),
      });
      final page = await _api(adapter).fetchUserArticles(1, pn: 2, ps: 10);
      expect(page.hasMore, isFalse, reason: '2×10 >= 11');
    });

    test('脏 data 不崩：null / articles 非 List / 空 cvid / 重复 cvid', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (_) => {
              'code': 0,
              'data': {
                'articles': [
                  _listItem(0), // 脏：cvid 无效
                  {'title': '缺 id'},
                  _listItem(9),
                  _listItem(9), // 重复
                  'not-a-map',
                ],
                'pn': '1', // 脏类型：非 num
                'ps': null,
                'count': 'abc',
              },
            },
      });

      final page = await _api(adapter).fetchUserArticles(1);

      expect(page.items.map((a) => a.cvid), [9], reason: '脏条目丢弃、去重');
      expect(page.pn, 1, reason: '脏 pn 回退请求页码');
      expect(page.ps, 10, reason: '脏 ps 回退请求条数');
      expect(page.count, 0);
    });

    test('data 整个缺失 → 空页（不抛）', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (_) => {'code': 0},
      });
      final page = await _api(adapter).fetchUserArticles(1);
      expect(page.isEmpty, isTrue);
      expect(page.hasMore, isFalse);
    });
  });

  group('fetchArticleView', () {
    test('请求构造：参数名是 id（不是 cv）；解析正文/作者/统计', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(content: '<p>第一段</p><h2>标题</h2>'),
      });
      final api = _api(adapter);

      final detail = await api.fetchArticleView(45123193);

      expect(detail.cvid, 45123193);
      expect(detail.title, '专栏标题');
      expect(detail.contentHtml, '<p>第一段</p><h2>标题</h2>');
      expect(detail.hasContent, isTrue);
      expect(detail.authorName, '测试作者');
      expect(detail.authorMid, 946974);
      expect(detail.authorFace, 'https://i0.hdslb.com/bfs/face/f.jpg');
      expect(detail.publishTs, 1730000000);
      expect(detail.imageUrls, ['https://i0.hdslb.com/bfs/article/a.jpg']);
      expect(detail.view, 1932290);
      expect(detail.like, 9765);
      expect(detail.favorite, 485);

      final req = adapter.forPath(_kViewPath).single;
      expect(req.queryParameters['id'], '45123193');
      expect(req.queryParameters.containsKey('cv'), isFalse,
          reason: '用 cv= 会被服务端拒 -400');
      expect(adapter.forPath('/x/web-interface/nav'), isEmpty);
    });

    test('纯文本专栏（content 无标签）照常解析', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(content: '第一行\n第二行'),
      });
      final detail = await _api(adapter).fetchArticleView(1);
      expect(detail.contentHtml, '第一行\n第二行');
      expect(detail.hasContent, isTrue);
    });

    test('content 为空 / 只有空白 → hasContent=false（页面给「正文为空」）',
        () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(content: '   \n '),
      });
      final detail = await _api(adapter).fetchArticleView(1);
      expect(detail.hasContent, isFalse);
    });

    test('content 是 Quill Delta JSON 字符串 → 原样带出（判别在渲染层）',
        () async {
      const delta = '{"ops":[{"insert":"正文\\n"}]}';
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(content: delta),
      });
      final detail = await _api(adapter).fetchArticleView(1);
      expect(detail.contentHtml, delta);
      expect(detail.hasContent, isTrue);
    });

    test('content 被给成已解析的对象 → 重新编码成 JSON，正文不丢', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(data: {
          'id': 45123193,
          'title': '专栏标题',
          'content': {
            'ops': [
              {'insert': '正文\n'},
            ]
          },
        }),
      });
      final detail = await _api(adapter).fetchArticleView(1);
      expect(detail.hasContent, isTrue, reason: '对象形态不该被当成空正文');
      expect(detail.contentHtml, contains('"ops"'));
    });

    test('content 是数字之类的脏类型 → 空正文（不抛、不崩）', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(data: {
          'id': 45123193,
          'content': 42,
        }),
      });
      final detail = await _api(adapter).fetchArticleView(1);
      expect(detail.contentHtml, '');
      expect(detail.hasContent, isFalse);
    });

    test('data 缺失 → 抛 BiliApiException（带可读文案）', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => {'code': 0},
      });
      await expectLater(
        _api(adapter).fetchArticleView(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.message, 'message', contains('未返回数据'))),
      );
    });

    test('脏 data（author 非 Map / stats 缺失）不崩', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(data: {
              'id': 5,
              'content': '<p>x</p>',
              'author': 'not-a-map',
            }),
      });
      final detail = await _api(adapter).fetchArticleView(5);
      expect(detail.authorName, '');
      expect(detail.authorFace, '');
      expect(detail.authorMid, 0);
      expect(detail.view, 0);
      expect(detail.contentHtml, '<p>x</p>');
    });
  });

  group('错误分类与 -509 退避', () {
    test('-509（请求过于频繁）→ 退避重试一次后成功', () async {
      var calls = 0;
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) {
          calls++;
          return calls == 1
              ? _viewBody(code: -509, message: '请求过于频繁，请稍后再试')
              : _viewBody(content: '<p>重试成功</p>');
        },
      });

      final detail = await _api(adapter).fetchArticleView(1);

      expect(detail.contentHtml, '<p>重试成功</p>');
      expect(adapter.forPath(_kViewPath), hasLength(2), reason: '退避重试一次');
    });

    test('两次都 -509 → 抛 BiliApiException（可读文案）', () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (_) => _listBody(code: -509, message: '请求过于频繁，请稍后再试'),
      });

      await expectLater(
        _api(adapter).fetchUserArticles(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -509)
            .having((e) => e.message, 'message', contains('过于频繁'))),
      );
      expect(adapter.forPath(_kListPath), hasLength(2));
    });

    test('-412 → 风控文案；-352 → 限流文案（都不重试）', () async {
      final risk = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kListPath: (_) => _listBody(code: -412, message: '风控'),
      });
      await expectLater(
        _api(risk).fetchUserArticles(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -412)
            .having((e) => e.message, 'message', contains('风控'))),
      );
      expect(risk.forPath(_kListPath), hasLength(1));

      final limited = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(code: -352, message: '被限流'),
      });
      await expectLater(
        _api(limited).fetchArticleView(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -352)
            .having((e) => e.message, 'message', contains('限流'))),
      );
      expect(limited.forPath(_kViewPath), hasLength(1));
    });

    test('其它业务码（-400：cv= 参数名写错时服务端会回这个）→ 带服务端 message',
        () async {
      final adapter = _RecordingAdapter({
        '/x/frontend/finger/spi': _spiBody,
        _kViewPath: (_) => _viewBody(code: -400, message: '请求错误'),
      });
      await expectLater(
        _api(adapter).fetchArticleView(1),
        throwsA(isA<BiliApiException>()
            .having((e) => e.code, 'code', -400)
            .having((e) => e.message, 'message', '请求错误')),
      );
    });
  });
}
