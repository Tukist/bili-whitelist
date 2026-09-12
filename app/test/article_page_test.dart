// 专栏阅读页（ArticlePage）widget 测试（注入 mock BiliApi，不访问真实网络）。
//
// 覆盖：
// - 头部：标题（列表带来的 initialTitle 先顶上）+ 作者（名字 + 相对时间）+
//   统计（阅读 / 点赞 / 收藏，万位格式化）
// - 正文：段落 / 标题 / 引用块（AppBlock reply）/ 列表 / 图片都上屏
// - 正文为空（content 只有空白）→ 一句「正文为空」（不设空态插画）
// - 首屏加载态 = AppLoadingHero；失败 = AppErrorView（带重试，重试会重新请求）
// - 点正文图片 → ImageViewerPage（图集 = 正文图片、下标正确）
// - 正文里的 cv 站内链接 → 再推一层阅读页（站内跳转）
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/api/bilibili_api.dart';
import 'package:bili_whitelist_app/config.dart';
import 'package:bili_whitelist_app/pages/article_page.dart';
import 'package:bili_whitelist_app/pages/image_viewer_page.dart';
import 'package:bili_whitelist_app/widgets/app_block.dart';
import 'package:bili_whitelist_app/widgets/app_state_view.dart';

const String _kViewPath = '/x/article/view';

void _mockSecureStorage() {
  const channel = 'plugins.it_nomads.com/flutter_secure_storage';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(channel), (call) async {
    return null;
  });
}

/// 可挂起的适配器：`gate` 未完成前不返回响应（用来钉住「加载中」那一帧）。
class _GatedAdapter implements HttpClientAdapter {
  _GatedAdapter(this.handlers);

  final Map<String, Map<String, dynamic> Function()> handlers;
  final List<RequestOptions> requests = [];
  Completer<void>? gate;

  List<RequestOptions> forPath(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final g = gate;
    if (g != null) await g.future;
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

/// 正文发布时间：相对「现在」4 小时 → 「4 小时前」。
final int _pubTs =
    DateTime.now().subtract(const Duration(hours: 4)).millisecondsSinceEpoch ~/
        1000;

Map<String, dynamic> _viewBody({
  String title = '专栏标题',
  String content = '<p>正文</p>',
  int code = 0,
  String? message,
}) =>
    {
      'code': code,
      if (message != null) 'message': message,
      'data': {
        'id': 45123193,
        'title': title,
        'content': content,
        'publish_time': _pubTs,
        'author': {'mid': 946974, 'name': '测试作者', 'face': ''},
        'image_urls': ['//i0.hdslb.com/bfs/article/a.jpg'],
        'stats': {'view': 1932290, 'like': 9765, 'favorite': 485},
      },
    };

BiliApi _api(_GatedAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: kBiliApi, headers: biliHeaders()));
  dio.httpClientAdapter = adapter;
  return BiliApi(dio: dio);
}

Future<void> _pumpPage(
  WidgetTester tester,
  BiliApi api, {
  String? initialTitle,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ArticlePage(cvid: 45123193, initialTitle: initialTitle, api: api),
  ));
  await tester.pumpAndSettle();
  _drainImageErrors(tester);
}

/// 测试环境里图床请求一律 400 → 图片加载失败是预期内的（占位兜底），取走。
void _drainImageErrors(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_mockSecureStorage);

  testWidgets('头部 + 正文：标题/作者/统计；段落/标题/引用块/列表都上屏',
      (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () => _viewBody(
            title: '专栏大标题',
            content: '<p>第一段正文</p><h2>小节标题</h2>'
                '<blockquote>被引用的话</blockquote>'
                '<ul><li>列表项一</li></ul>',
          ),
    });
    await _pumpPage(tester, _api(adapter), initialTitle: '列表带来的标题');

    // 标题：正文拉到后覆盖 initialTitle（AppBar + 页面头部都用它）
    expect(find.text('专栏大标题'), findsNWidgets(2));
    expect(find.text('列表带来的标题'), findsNothing);
    // 作者行 + 相对时间
    expect(find.text('测试作者'), findsOneWidget);
    expect(find.text('4 小时前'), findsOneWidget);
    // 统计行（万位格式化 + 等宽数字）
    expect(find.text('阅读 193.2万'), findsOneWidget);
    expect(find.text('点赞 9765'), findsOneWidget);
    expect(find.text('收藏 485'), findsOneWidget);
    // 正文
    expect(find.text('第一段正文'), findsOneWidget);
    expect(find.text('小节标题'), findsOneWidget);
    expect(find.text('被引用的话'), findsOneWidget);
    expect(find.text('列表项一'), findsOneWidget);
    final quote = tester.widget<AppBlock>(find.byType(AppBlock).first);
    expect(quote.variant, AppBlockVariant.reply, reason: '引用块走「块」的语言');
    expect(adapter.forPath(_kViewPath).single.queryParameters['id'], '45123193');
    _drainImageErrors(tester);
  });

  testWidgets('首屏加载态 = AppLoadingHero（请求未回来那一帧）', (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: _viewBody,
    });
    adapter.gate = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: ArticlePage(cvid: 45123193, api: _api(adapter)),
    ));
    await tester.pump();

    expect(find.byType(AppLoadingHero), findsOneWidget);

    adapter.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AppLoadingHero), findsNothing);
    expect(find.text('正文'), findsOneWidget);
  });

  testWidgets('正文为空（content 只有空白）→ 一句「正文为空」', (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () => _viewBody(content: '   \n '),
    });
    await _pumpPage(tester, _api(adapter));

    expect(find.text('正文为空'), findsOneWidget);
    expect(find.byType(AppErrorView), findsNothing);
    _drainImageErrors(tester);
  });

  testWidgets('正文是 Quill Delta（新版专栏）→ 图片 + 文本上屏，不出现原始 JSON',
      (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () => _viewBody(
            content: '{"ops":['
                '{"insert":"\\n","attributes":{"class":"normal-img"}},'
                '{"insert":{"native-image":{"alt":"read-normal-img",'
                '"url":"https://i0.hdslb.com/bfs/article/'
                '32f43892ae504c833bc8b7783996851f1069246841.jpg'
                '@progressive.webp","width":460,"height":215,'
                '"size":64510,"status":"loaded"}}},'
                '{"insert":"\\nRT，这个游戏是个好游戏，开放世界+黑客。"},'
                '{"insert":"UP的讲解视频","attributes":{"link":'
                '"https://www.bilibili.com/video/BV1pw411F7VA/"}},'
                '{"insert":"\\n"}]}',
          ),
    });
    await _pumpPage(tester, _api(adapter));

    // 图片渲染出来了（不是被当文本）
    expect(find.byType(Image), findsOneWidget);
    expect(
      tester.widget<Image>(find.byType(Image)).image,
      isA<NetworkImage>()
          .having((p) => p.url, 'url', contains('@progressive.webp')),
    );
    expect(
      tester
          .widgetList<AspectRatio>(find.byType(AspectRatio))
          .map((w) => w.aspectRatio),
      [460 / 215],
      reason: 'Delta 给的 width/height 用来预留高度，防加载后跳动',
    );

    // 文本是文本
    final screen = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(screen, contains('RT，这个游戏是个好游戏，开放世界+黑客。'));
    expect(screen, contains('UP的讲解视频'));

    // **界面上绝不出现原始 JSON**
    for (final leak in <String>['insert', 'ops', 'native-image', 'attributes']) {
      expect(screen.contains(leak), isFalse, reason: '泄漏了 $leak');
    }
    _drainImageErrors(tester);
  });

  testWidgets('错误态：AppErrorView + 重试再请求', (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () => _viewBody(code: -412, message: '风控'),
    });
    await _pumpPage(tester, _api(adapter));

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.textContaining('风控'), findsOneWidget);
    final before = adapter.forPath(_kViewPath).length;

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(adapter.forPath(_kViewPath).length, greaterThan(before));
    expect(find.byType(AppErrorView), findsOneWidget);
  });

  testWidgets('点正文图片 → ImageViewerPage（图集 = 正文图片，下标正确）',
      (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () => _viewBody(
            content: '<p>图文</p>'
                '<img src="//i0.hdslb.com/bfs/article/one.jpg">'
                '<img src="//i0.hdslb.com/bfs/article/two.jpg">',
          ),
    });
    await _pumpPage(tester, _api(adapter));

    // 图床在测试环境一律 400 → errorBuilder 的失败占位里带一行小字
    // （「图片加载失败」），它会并进外层 `Semantics` 的标签里，所以这里用
    // RegExp 匹配前缀（意图不变：找到"可点开大图"的那两张正文图）。
    final images = find.bySemanticsLabel(RegExp('正文图片，点击查看大图'));
    expect(images, findsNWidgets(2), reason: '两张图各挂一个点击');
    await tester.ensureVisible(images.last);
    await tester.pumpAndSettle();
    await tester.tap(images.last, warnIfMissed: false);
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    expect(find.byType(ImageViewerPage), findsOneWidget);
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.urls, [
      'https://i0.hdslb.com/bfs/article/one.jpg',
      'https://i0.hdslb.com/bfs/article/two.jpg',
    ]);
    expect(viewer.initialIndex, 1);
    _drainImageErrors(tester);
  });

  testWidgets('下拉刷新失败：正文保留 + 轻提示（不清空已读内容）', (tester) async {
    var calls = 0;
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () {
        calls++;
        return calls == 1
            ? _viewBody(content: '<p>已有正文</p>')
            : _viewBody(code: -412, message: '风控');
      },
    });
    await _pumpPage(tester, _api(adapter));
    expect(find.text('已有正文'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(adapter.forPath(_kViewPath), hasLength(2), reason: '下拉刷新重新请求');
    expect(find.text('已有正文'), findsOneWidget, reason: '刷新失败不清空正文');
    expect(find.byType(AppErrorView), findsNothing, reason: '不是整页错误态');
    expect(find.textContaining('风控'), findsOneWidget, reason: '轻提示');
    _drainImageErrors(tester);
  });

  testWidgets('正文里的 cv 站内链接 → 再推一层阅读页', (tester) async {
    final adapter = _GatedAdapter({
      '/x/frontend/finger/spi': _spiBody,
      _kViewPath: () => _viewBody(
            content: '<p>参考这篇'
                '<a href="https://www.bilibili.com/read/cv999">另一篇专栏</a>'
                '</p>',
          ),
    });
    await _pumpPage(tester, _api(adapter));

    // 直接把链接 span 的手势识别器点掉（RichText 里的 span 命中不靠 tap 坐标）
    final text = tester.widget<Text>(find.textContaining('参考这篇').first);
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    final link = spans.firstWhere((s) => s.recognizer != null);
    (link.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();
    _drainImageErrors(tester);

    expect(find.byType(ArticlePage), findsOneWidget);
    // 站内跳转真发了请求（id=999 那一篇）
    final reqs = adapter.forPath(_kViewPath);
    expect(reqs, hasLength(2));
    expect(reqs.last.queryParameters['id'], '999');
    _drainImageErrors(tester);
  });
}
