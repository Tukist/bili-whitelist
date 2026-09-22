/// 专栏阅读页（v2.23.0+；v2.26.0+ 加评论区）。
///
/// 入口：UP 主主页「专栏」区（[UpownerPage]）点某条专栏 → 本页；
/// 另外动态里引用专栏、专栏正文里的 `cv*` 站内链接也推本页。
///
/// 结构（自上而下）：
/// - **标题**（[kTypeTitleL]）
/// - **作者行**：小圆头像 + 名字 + 相对时间（[fmtRelativeTime]）——点作者进
///   UP 主页（[UpownerPage]；作者 mid 未知时不挂手势）
/// - **统计行**：阅读 / 点赞 / 收藏（[kTypeNum]，图标省掉——mono-color 里
///   数字自己会说话，也少三个触摸目标）
/// - **正文**：[BiliHtmlView] 渲染（`content` 有两种格式：**老专栏是 HTML
///   源码**，**新版编辑器产出的专栏是 Quill Delta JSON**——判别与降级规则见
///   `lib/utils/bili_html.dart`）；正文为空 → 一句「正文为空」
/// - **评论区**（v2.26.0+）：上面这一整块作为 [CommentListView] 的 `header`
///   （列表第 0 项），正文之下就是「评论 N」区头 + 评论列表 —— 正文与评论
///   **共用一个 ListView**，所以整页一起滚、一起下拉刷新。
///   ⚠️ **不要**改成「外层 ListView + 内层 shrinkWrap 评论区」：内层配
///   `NeverScrollableScrollPhysics` 后**自己根本不滚**，触底翻页彻底失效
///   （见 `comment_list.dart` 的 `header` 说明）。
///   评论归属：`type=12` + `oid=<cvid>`（专栏评论与视频评论字段同构）；
///   点评论里的视频链接 → 无宿主回调 → 列表兜底 push 新 PlayerPage
///   （专栏页没有播放页宿主，这正是想要的语义）。
///
/// 与列表的分工：正文按 `content` 渲染；`image_urls[]` 只在**正文里一张图都
/// 没有**时用来补一个图集（正文有图就不补，否则同一张图会重复出现一遍）。
/// 图片点击走 [ImageViewerPage]，图集 = 正文里按文档顺序收集的图片
/// （与 `BiliHtmlView.onImageTap` 的下标一一对应）。
///
/// 状态：首屏拉正文 = [AppLoadingHero]（整页等待）；失败 = [AppErrorView]
/// （带重试）；加载完可下拉刷新（[RefreshIndicator]，刷的是**正文**；评论区
/// 自己有触底翻页与重试）。
///
/// 设计语言：无阴影；颜色只用 token / `context.palette.*`；块间距 [kSpace12]。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/bilibili_api.dart';
import '../config.dart';
import '../models/article.dart';
import '../theme/app_tokens.dart';
import '../utils/bili_html.dart';
import '../utils/comment_links.dart';
import '../utils/relative_time.dart';
import '../widgets/app_state_view.dart';
import '../widgets/comment_list.dart';
import 'image_viewer_page.dart';
import 'upowner_page.dart';

/// 数字格式化（阅读/点赞/收藏）：`12345` → `1.2万`；`123456789` → `1.2亿`
/// （尾数整则不带小数）。与搜索页的播放量格式一致。
String fmtArticleCount(int count) {
  if (count >= 100000000) return '${_trimDot(count / 100000000)}亿';
  if (count >= 10000) return '${_trimDot(count / 10000)}万';
  return '$count';
}

String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 专栏正文里的站内专栏链接（`bilibili.com/read/cv12345` / `read/cv12345`）。
final RegExp _kArticleLinkRe =
    RegExp(r'(?:bilibili\.com/)?read/cv(\d+)', caseSensitive: false);

class ArticlePage extends StatefulWidget {
  /// 专栏号（cvid）。
  final int cvid;

  /// 标题兜底（从列表点进来时先用它显示，首屏不闪「专栏」）。
  final String? initialTitle;

  /// 注入 B 站 API（widget 测试用 mock；缺省走真实实现）。
  final BiliApi? api;

  const ArticlePage({
    super.key,
    required this.cvid,
    this.initialTitle,
    this.api,
  });

  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  late final BiliApi _api = widget.api ?? BiliApi();

  ArticleDetail? _detail;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉正文。失败分类与页面其它处一致：业务码用接口 message，网络失败给
  /// 统一文案（`-509 请求过于频繁` 已由 API 层退避重试过一轮）。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _api.fetchArticleView(widget.cvid);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      debugPrint('[article] 专栏 cv${detail.cvid} 加载完成：'
          '标题="${detail.title}" 正文 ${detail.contentHtml.length} 字符');
    } on BiliApiException catch (e) {
      _onLoadError(e.message);
    } on DioException {
      _onLoadError('网络请求失败，请检查网络后重试');
    }
  }

  /// 加载失败：首屏 → 整页错误态（[AppErrorView] + 重试）；下拉刷新（已有
  /// 内容）→ 只轻提示，正文不清空（读到的内容不该因为一次刷新失败就没了）。
  void _onLoadError(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
    if (_detail != null) _snack(message);
  }

  String get _title {
    final fromDetail = _detail?.title ?? '';
    if (fromDetail.trim().isNotEmpty) return fromDetail;
    final initial = widget.initialTitle ?? '';
    if (initial.trim().isNotEmpty) return initial;
    return '专栏';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (detail == null) {
      if (_loading) return const AppLoadingHero(seed: 'article');
      return AppErrorView(
        message: _error,
        onRetry: _load,
        illustrationSeed: 'article',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      // 正文（[_buildArticleHeader]）作为列表第 0 项 → 正文与评论同一个滚动体。
      // 不传 onOpenVideo：本页没有播放页宿主，评论里的视频链接由列表兜底
      // push 新 PlayerPage（正是想要的语义）。
      child: CommentListView(
        api: _api, // 复用本页会话（buvid/Cookie），测试也继续走同一个 mock
        oid: detail.cvid, // 专栏评论：oid = cvid
        commentType: 12, // type 12 = 专栏（1 = 视频）
        identityKey: 'cv${detail.cvid}', // 入场代次身份串（同 cvid 恒同）
        footerSeed: 'cv${detail.cvid}#footer',
        // 「评论 N」区头：先用正文统计里的评论数顶着，首屏到货后覆盖
        initialTotal: detail.reply,
        showCountHeader: true,
        header: _buildArticleHeader(detail),
        // 宿主是 RefreshIndicator：内容不足一屏时也要能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
      ),
    );
  }

  /// 正文整块（标题 + 作者行 + 统计行 + 分隔线 + 正文）：作为评论列表的
  /// 第 0 项传入 —— 这一块永远可见，评论的加载/错误/空态只出现在它下方。
  ///
  /// 顶部留白 [kSpace16] 与左右留白由这里/列表内边距给（列表的水平内边距
  /// 仍是 [kPagePadH]，与本页原布局一致）。
  Widget _buildArticleHeader(ArticleDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: kSpace16),
        Text(_title, style: kTypeTitleL.copyWith(color: kInkBlack)),
        const SizedBox(height: kSpace12),
        _buildAuthorRow(detail),
        const SizedBox(height: kSpace8),
        _buildStatsRow(detail),
        const SizedBox(height: kSpace16),
        const Divider(height: 1, thickness: 1, color: kRule),
        const SizedBox(height: kSpace16),
        _buildContent(detail),
        // 正文与评论区之间的呼吸（紧跟其后就是「评论 N」区头）
        const SizedBox(height: kSpace24),
      ],
    );
  }

  /// 作者行：头像 + 名字 + 相对时间；有 mid 时可点进 UP 主页。
  Widget _buildAuthorRow(ArticleDetail detail) {
    final name = detail.authorName.trim();
    final ts = detail.publishTs;
    final time = ts > 0
        ? fmtRelativeTime(DateTime.fromMillisecondsSinceEpoch(ts * 1000))
        : '';
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: 28,
              height: 28,
              child: detail.authorFace.isEmpty
                  ? _avatarPlaceholder()
                  : Image.network(
                      detail.authorFace,
                      width: 28,
                      height: 28,
                      fit: BoxFit.cover,
                      headers: const {
                        'User-Agent': kBrowserUA,
                        'Referer': kBiliReferer,
                      },
                      errorBuilder: (_, __, ___) => _avatarPlaceholder(),
                    ),
            ),
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Text(
              name.isEmpty ? '未知作者' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kTypeTitleS.copyWith(color: kInkBlack),
            ),
          ),
          if (time.isNotEmpty)
            Text(time, style: kTypeBodyS.copyWith(color: kInkGray50)),
        ],
      ),
    );
    if (detail.authorMid <= 0) return row;
    // 触摸目标 ≥ 48dp（28 头像 + 上下 10 = 48）
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: _openAuthor,
        child: Semantics(
          button: true,
          label: '查看作者主页',
          child: row,
        ),
      ),
    );
  }

  Widget _avatarPlaceholder() => Container(
        color: kPaperCool,
        alignment: Alignment.center,
        child: const Icon(Icons.person, size: 17, color: kInkGray30),
      );

  /// 统计行：阅读 / 点赞 / 收藏（[kTypeNum] 等宽数字，数字不跳动）。
  Widget _buildStatsRow(ArticleDetail detail) {
    final parts = <({String label, int value})>[
      (label: '阅读', value: detail.view),
      (label: '点赞', value: detail.like),
      (label: '收藏', value: detail.favorite),
    ];
    return Row(
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSpace8),
              child: Text('·', style: kTypeNum.copyWith(color: kInkGray30)),
            ),
          Text(
            '${parts[i].label} ${fmtArticleCount(parts[i].value)}',
            style: kTypeNum.copyWith(color: kInkGray70),
          ),
        ],
      ],
    );
  }

  /// 正文：按 `content` 渲染（空 → 一句「正文为空」）。
  Widget _buildContent(ArticleDetail detail) {
    if (!detail.hasContent) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: kSpace24),
        child: Text(
          '正文为空',
          style: kTypeBody.copyWith(color: kInkGray50),
        ),
      );
    }
    // 正文（自己解析：图集兜底要先知道"正文里有没有图"）
    final nodes =
        parseArticleContent(detail.contentHtml, source: 'cv${detail.cvid}');
    // 正文里**一张图都没有**、而接口另外给了配图列表 → 在正文后补一个图集。
    // 这是 `ArticleDetail.imageUrls` 注释里承诺过的"宿主兜底"（正文有图时
    // **不补**，否则同一张图会重复出现一遍）。合成一组 `<img>` 节点再交给
    // 同一个 [BiliHtmlView] 渲染，图片的加载态/失败态/去后缀重试/点击开大图
    // 全部复用正文那一条路，不另写一套。
    final gallery = collectBiliHtmlImageUrls(nodes).isEmpty
        ? _galleryNodes(detail.imageUrls)
        : const <HtmlNode>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BiliHtmlView(
          nodes: nodes,
          onImageTap: _openImages,
          onLinkTap: _onLinkTap,
        ),
        if (gallery.isNotEmpty)
          BiliHtmlView(
            nodes: gallery,
            onImageTap: _openImages,
            onLinkTap: _onLinkTap,
          ),
      ],
    );
  }

  /// 正文无图时的配图兜底节点：一句说明 + 一串 `<img>`。
  ///
  /// 加那句说明是刻意的——图出现在正文之后而正文里没提过它们，不解释一句
  /// 会被当成"排版错乱"；说明里也如实讲了这些不是从正文里读出来的。
  List<HtmlNode> _galleryNodes(List<String> urls) {
    if (urls.isEmpty) return const [];
    return <HtmlNode>[
      HtmlElement('p', children: [
        const HtmlText('正文中没有图片，以下是本专栏的配图。'),
      ]),
      for (final u in urls) HtmlElement('img', attrs: {'src': u}),
    ];
  }

  /// 正文配图 → 全屏查看（与评论图、动态图共用同一个查看页）。
  void _openImages(List<String> urls, int index) {
    if (urls.isEmpty) return;
    debugPrint('[article] 打开正文图片 ${index + 1}/${urls.length}');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(urls: urls, initialIndex: index),
    ));
  }

  /// 正文链接：**能站内跳就站内跳**（同为专栏的 `cv*` → 再推一层阅读页；
  /// UP 主页 → [UpownerPage]），其余交系统浏览器（url_launcher）。
  Future<void> _onLinkTap(String url) async {
    final cvid = _articleCvidOf(url);
    if (cvid != null && cvid != widget.cvid) {
      debugPrint('[article] 站内跳转专栏 cv$cvid（来自 $url）');
      await Navigator.of(context).push(MaterialPageRoute<void>(
        // 同一个 [_api] 传下去：复用 buvid 指纹/会话 Cookie，测试也能继续 mock
        builder: (_) => ArticlePage(cvid: cvid, api: _api),
      ));
      return;
    }
    final link = classifyUrl(url);
    if (link != null && link.kind == CommentLinkKind.up && link.upMid != null) {
      final mid = link.upMid!;
      debugPrint('[article] 站内跳转 UP 主页 mid=$mid（来自 $url）');
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => UpownerPage(mid: mid),
      ));
      return;
    }
    await _openExternal(url);
  }

  /// 站内专栏链接 → cvid（识别不出 → null）。
  int? _articleCvidOf(String url) {
    final m = _kArticleLinkRe.firstMatch(url);
    if (m == null) return null;
    final cvid = int.tryParse(m.group(1)!);
    return (cvid == null || cvid <= 0) ? null : cvid;
  }

  /// 其他链接：系统浏览器打开（url_launcher，外部应用模式）。
  Future<void> _openExternal(String url) async {
    var raw = url.trim();
    if (raw.isEmpty) return;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      // 站内相对链接（B 站专栏里偶见）补上域名再打开
      raw = 'https://www.bilibili.com/${raw.startsWith('/') ? '' : '/'}$raw';
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      _snack('无法打开该链接');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _snack('打开链接失败（未找到可用浏览器）');
    } catch (_) {
      _snack('打开链接失败');
    }
  }

  /// 点作者行 → UP 主页（站内，不写白名单）。
  void _openAuthor() {
    final mid = _detail?.authorMid ?? 0;
    if (mid <= 0) return;
    debugPrint('[article] 打开作者主页 mid=$mid');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => UpownerPage(mid: mid),
    ));
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
