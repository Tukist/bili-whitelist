/// 动态详情页（v2.31.0+）。
///
/// 入口：UP 主主页「动态」区点某条动态卡（[DynamicCard.onTap]）→ 本页；
/// 从列表点进来时把**已经拿到的那条**（`initial`）一起带进来，所以首帧就有
/// 正文/作者/图片，不会先闪一下转圈（`fetchDynamicDetail` 只是后台补互动数据
/// 与转发原文的图片/视频，失败静默——见下）。
///
/// 结构（自上而下）：
/// - **作者行**：头像 + 名字 + 相对时间（[DynamicAuthorRow]，与动态卡同一行）
/// - **正文全文**：**不折叠**（详情页就是来看全文的；列表里才是折叠的）
/// - **图片**：[DynamicImages]（与动态卡同一套 1/2/3/4 图布局）→ 点开
///   [ImageViewerPage]
/// - **视频投稿**：[DynamicVideo] → fetch view 补 cid → 进播放页
/// - **转发原文**：引用块（[AppBlockVariant.reply]）+ 原文自己的图片/视频
/// - **互动数据**：点赞 / 评论 / 转发（[fmtArticleCount] 万/亿格式化）——
///   **只读展示**，本页不做点赞/转发/回复等任何写操作
/// - **评论区**：上面这一整块作为 [CommentListView] 的 `header`（列表第 0 项），
///   与专栏阅读页（[ArticlePage]）**同一个骨架**：正文与评论**共用一个
///   ListView**，整页一起滚、一起下拉刷新。
///   ⚠️ **不要**改成「外层 ListView + 内层 shrinkWrap 评论区」：内层配
///   `NeverScrollableScrollPhysics` 后**自己根本不滚**，触底翻页彻底失效
///   （见 `comment_list.dart` 的 `header` 说明）。
///   评论归属：**优先用条目自己的 `basic.{comment_type, comment_id_str}`**
///   （与专栏的 `type=12` 同一套 reply 接口）。2026-09 匿名实测：相册型动态的
///   `basic` 是 `{comment_type: 11, comment_id_str: "326122895"}`，用它取评论
///   `code=0`；而「想当然」的 `type=17 + oid=<dyn id>` 三个组合全是
///   `-404 啥都木有`（见 [DynamicItem.commentType]）。响应里没有 `basic` 时
///   才回退默认口径 `type=17 + oid=<动态 id>`（[kDynamicCommentType]）；
///   动态 id 是 19 位雪花数，[CommentListView.oid] 是 `int?`，所以要 `int.parse`。
///
/// 状态：
/// - 有 `initial`（从列表点进来）→ **首帧就渲染**，详情接口在后台跑；失败只
///   留一条 debugPrint，页面照常可读（正文/图片本来就在手上）
/// - 没有 `initial`（深链/直达）→ [AppLoadingHero]（整页等待）→ 失败
///   [AppErrorView]（带重试）
/// - 加载完可下拉刷新（[RefreshIndicator]，刷的是**详情**；评论区自己有触底
///   翻页与重试）
///
/// 设计语言：无阴影；颜色只用 token / `context.palette.*`；块间距 [kSpace12]。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../models/dynamic_item.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_block.dart';
import '../widgets/app_state_view.dart';
import '../widgets/comment_list.dart';
import '../widgets/dynamic_card.dart';
import 'article_page.dart' show fmtArticleCount;
import 'image_viewer_page.dart';
import 'player_page.dart';

/// 评论归属的**默认类型**（没有任何服务端线索时才用）：动态评论 `type=17`。
///
/// ⚠️ 这只是**回退值**：2026-09 匿名实测（见 [DynamicItem.commentType]）表明
/// `type=17 + oid=<dyn id>` 对相册型动态会 `-404 啥都木有`——真正的归属写在条目
/// 自己的 `basic.{comment_type, comment_id_str}` 里（相册型是 `11` + **rid**）。
/// 所以页面优先用 [DynamicItem.commentType] / [DynamicItem.commentId]，本常量
/// 只在响应里没有 `basic` 时才生效。
const int kDynamicCommentType = 17;

class DynamicDetailPage extends StatefulWidget {
  /// 动态 id（[DynamicItem.id]，即 `id_str`，19 位数字串）。
  final String id;

  /// 从列表点进来时已经拿到的那条动态（首帧直接渲染它，不先转圈）。
  final DynamicItem? initial;

  /// 注入 B 站 API（widget 测试用 mock；缺省走真实实现）。
  final BiliApi? api;

  const DynamicDetailPage({
    super.key,
    required this.id,
    this.initial,
    this.api,
  });

  @override
  State<DynamicDetailPage> createState() => _DynamicDetailPageState();
}

class _DynamicDetailPageState extends State<DynamicDetailPage> {
  late final BiliApi _api = widget.api ?? BiliApi();

  /// 当前要渲染的动态：初始 = 列表带来的那条（可能为 null）。
  late DynamicItem? _item = widget.initial;

  /// 详情接口是否在跑（有 `initial` 时它只驱动「后台补全」，页面上不显示
  /// 任何等待态——见 [._load] 的注释）。
  bool _loading = false;

  /// 首屏错误文案（只有「一条都没有」时才会上屏）。
  String? _error;

  /// 正在 fetch view 补 cid（防重复点视频卡）。
  bool _openingVideo = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉详情。
  ///
  /// 失败语义分两种（这是本页最要紧的取舍）：
  /// - **已经有内容**（`initial` 带来的）→ 静默：正文/图片已经在屏幕上，一次
  ///   后台补全失败不该把可读的页面换成错误页，也不该弹「加载失败」打断阅读；
  /// - **一条都没有** → 落在 [AppErrorView]，带重试。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final detail = await _api.fetchDynamicDetail(widget.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (detail != null) {
        // 详情到货：整条替换（拿列表那条时还没有 module_stat / 原文媒体）
        _item = detail;
        _error = null;
      } else if (_item == null) {
        _error = '动态详情加载失败';
      }
    });
    debugPrint(detail == null
        ? '[dynamic_detail] id=${widget.id} 详情未拿到（已有内容=${_item != null}）'
        : '[dynamic_detail] id=${widget.id} 详情到货（赞${detail.stat.like} '
            '评${detail.stat.comment} 图${detail.imageUrls.length}）');
  }

  /// 评论归属 id：优先用条目自己的 `basic.comment_id_str`（服务端权威值，
  /// 相册型动态它是 **rid** 而不是 dyn id）；没有才回退 dyn id 本身。
  ///
  /// 空/脏 id → null（见 build：此时不挂评论区）。
  int? get _commentOid {
    final fromBasic = int.tryParse(_item?.commentId ?? '');
    if (fromBasic != null && fromBasic > 0) return fromBasic;
    final raw = widget.id.trim();
    if (raw.isEmpty) return null;
    final parsed = int.tryParse(raw);
    return (parsed == null || parsed <= 0) ? null : parsed;
  }

  /// 评论归属类型：优先用条目自己的 `basic.comment_type`，缺失才回退 17。
  ///
  /// [CommentListView.commentType] 的注释警告过：传错**不报错**，会静默拿到
  /// 另一类内容（或像实测那样直接 `-404 啥都木有` 被当空页）。
  int _commentTypeOf(DynamicItem item) =>
      item.commentType > 0 ? item.commentType : kDynamicCommentType;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('动态'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final item = _item;
    if (item == null) {
      if (_loading) return const AppLoadingHero(seed: 'dynamic.detail');
      return AppErrorView(
        message: _error,
        onRetry: _load,
        illustrationSeed: 'dynamic.detail',
      );
    }
    final oid = _commentOid;
    if (oid == null) {
      // 脏 id（非数字串）→ 没有可用的评论归属：只渲染正文，不假装有评论区
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: kPagePadH),
        children: [_buildHeader(item)],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      // 正文（[_buildHeader]）作为列表第 0 项 → 正文与评论同一个滚动体。
      // 不传 onOpenVideo：本页没有播放页宿主，评论里的视频链接由列表兜底
      // push 新 PlayerPage（与专栏阅读页同一取舍）。
      child: CommentListView(
        api: _api, // 复用本页会话（buvid/Cookie），测试也继续走同一个 mock
        oid: oid, // 评论归属 id（优先 basic.comment_id_str，见 [_commentOid]）
        commentType: _commentTypeOf(item), // 优先 basic.comment_type（见该字段注释）
        identityKey: 'dyn${widget.id}', // 入场代次身份串（同 id 恒同）
        footerSeed: 'dyn${widget.id}#footer',
        // 「评论 N」区头：先用详情里的互动数据顶着，真值到货后覆盖
        initialTotal: item.stat.comment,
        showCountHeader: true,
        header: _buildHeader(item),
        // 宿主是 RefreshIndicator：内容不足一屏时也要能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
      ),
    );
  }

  /// 正文整块（作者行 + 全文 + 图片 + 视频 + 转发原文 + 互动数据）：作为评论
  /// 列表的第 0 项传入 —— 这一块永远可见，评论的加载/错误/空态只出现在它
  /// 下方。
  Widget _buildHeader(DynamicItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: kSpace16),
        DynamicAuthorRow(
          name: item.authorName,
          face: item.authorFace,
          pubTs: item.pubTs,
        ),
        if (item.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: kSpace12),
            child: Text(
              // 详情页展示全文：**不折叠**（列表卡里才用 ExpandableText 折叠）
              item.text,
              style: kTypeBody.copyWith(color: kInkBlack),
            ),
          ),
        if (item.hasImages)
          Padding(
            padding: const EdgeInsets.only(top: kSpace12),
            child: DynamicImages(
              urls: item.imageUrls,
              onTap: _openImages,
            ),
          ),
        if (item.hasVideo)
          Padding(
            padding: const EdgeInsets.only(top: kSpace12),
            child: DynamicVideo(
              cover: item.videoCover ?? '',
              title: item.videoTitle ?? '视频投稿',
              pubTs: item.pubTs,
              onTap: () => _openDynamicVideo(
                bvid: item.videoBvid ?? '',
                title: item.videoTitle ?? '',
                cover: item.videoCover ?? '',
              ),
            ),
          ),
        if (item.isForward)
          Padding(
            padding: const EdgeInsets.only(top: kSpace12),
            child: _buildOriginalBlock(item),
          ),
        if (!item.stat.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: kSpace12),
            child: _buildStatRow(item.stat),
          ),
        // 正文与评论区之间的呼吸（紧跟其后就是「评论 N」区头）
        const SizedBox(height: kSpace24),
      ],
    );
  }

  /// 转发原文块：作者 + 全文 + **原文自己的图片/视频**。
  ///
  /// 列表卡（`dynamic_card.dart` 的 `_OriginalBlock`）刻意只画作者 + 正文
  /// ——列表要的是「扫一眼有几条动态」，把原文的图铺开会把卡片撑得很长；详情
  /// 页是「把这一条看完整」，原文的图文/视频投稿正是要看的东西。所以这里比
  /// 卡片多两块，但图片/视频仍走同一套 [DynamicImages] / [DynamicVideo]。
  Widget _buildOriginalBlock(DynamicItem item) {
    final author = item.origAuthor;
    final text = item.origText;
    return AppBlock(
      variant: AppBlockVariant.reply,
      margin: const EdgeInsets.only(left: kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (author != null)
            Text(
              '@$author',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kTypeBodyS.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          if (text != null)
            Padding(
              padding: EdgeInsets.only(top: author != null ? kSpace4 : 0),
              child: Text(text, style: kTypeBodyS),
            ),
          if (item.origHasImages)
            Padding(
              padding: const EdgeInsets.only(top: kSpace8),
              child: DynamicImages(
                urls: item.origImageUrls,
                onTap: _openImages,
              ),
            ),
          if (item.origHasVideo)
            Padding(
              padding: const EdgeInsets.only(top: kSpace8),
              child: DynamicVideo(
                cover: item.origVideoCover ?? '',
                title: item.origVideoTitle ?? '视频投稿',
                pubTs: item.pubTs,
                onTap: () => _openDynamicVideo(
                  bvid: item.origVideoBvid ?? '',
                  title: item.origVideoTitle ?? '',
                  cover: item.origVideoCover ?? '',
                ),
              ),
            ),
          if (author == null && text == null &&
              !item.origHasImages && !item.origHasVideo)
            Text(
              '原文已被删除',
              style: kTypeBodyS.copyWith(color: kInkGray50),
            ),
        ],
      ),
    );
  }

  /// 互动数据行：点赞 / 评论 / 转发（[kTypeNum] 等宽数字，数字不跳动）。
  ///
  /// **只读**：本页没有任何点赞/转发/写评论的入口（全 App 的评论区与动态区
  /// 都不做写操作），这三个数只是「这条动态的热度」。三个数都是 0（含接口
  /// 没给 module_stat）→ 整个调用点不渲染，不放一排「点赞 0」。
  Widget _buildStatRow(DynamicStat stat) {
    final parts = <({String label, int value})>[
      (label: '点赞', value: stat.like),
      (label: '评论', value: stat.comment),
      (label: '转发', value: stat.forward),
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

  /// 配图 → 全屏查看（与评论图、列表里的动态图共用同一个查看页）。
  ///
  /// 图集就是传进来的这一组：正文图与**转发原文**的图各成一组（原文的图不该
  /// 混进本条动态的图集里，两个来源在界面上也是分开的两块）。
  void _openImages(List<String> urls, int index) {
    if (urls.isEmpty) return;
    debugPrint('[dynamic_detail] 打开图片 ${index + 1}/${urls.length}');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(urls: urls, initialIndex: index),
    ));
  }

  /// 点视频投稿 → 构造 [WhitelistVideo]（cid 未知填 0）→ fetch view 补 cid →
  /// push [PlayerPage]。
  ///
  /// 与 UP 主页 [_openDynamicVideo] 同一语义（两处都保留各自的局部实现：那边
  /// 挂在页面 State 上带 `_fetchingMeta` 与 `_info`，抽出来反而要给它塞一堆
  /// 参数；这里只有一条链路，代价是十来行）：
  /// - 动态投稿**不受白名单限制**（播放页本身不校验白名单，评论区的视频链接
  ///   预览就是这么直接播的）；代价是不会自动进白名单（要收藏可在「全部视频」
  ///   里长按加入）；
  /// - 路由名用 [kPlayerRouteName]：这里推的**就是**播放页（route 名决定
  ///   `app_theme` 的转场），与白名单无关。
  Future<void> _openDynamicVideo({
    required String bvid,
    required String title,
    required String cover,
  }) async {
    if (bvid.isEmpty) return;
    if (_openingVideo) return;
    setState(() => _openingVideo = true);
    try {
      final meta = await _api.fetchVideoMeta(bvid);
      final fixed = WhitelistWriter.videoFromMeta(meta, fallbackBvid: bvid);
      if (!mounted) return;
      setState(() => _openingVideo = false);
      await Navigator.of(context).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(video: fixed),
      ));
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _openingVideo = false);
      _snack('获取视频信息失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      setState(() => _openingVideo = false);
      _snack('网络请求失败，请重试');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
