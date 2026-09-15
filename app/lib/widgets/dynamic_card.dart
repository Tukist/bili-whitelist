/// 一条动态卡片（UP 主主页「动态」区用，v2.22.0+）。
///
/// 结构（按 [DynamicItem] 的宽松解析结果自适应）：
/// - **作者行**：头像 + 名字 + 相对时间（[fmtRelativeTime]，24h 内文案与
///   历史/评论一致）——[DynamicAuthorRow]，与动态详情页共用同一行
/// - **正文**：多行可折叠（复用 [ExpandableText]，与评论正文同一套折叠逻辑）
/// - **图文**：[DynamicImages]（1/2/3/4 图布局，4 图以上只画 4 张，第 4 张
///   压「+N」）；点图由宿主打开全屏查看页
/// - **视频投稿**：[DynamicVideo]（封面 + 标题（超 2 行可展开）+ 「视频投稿 ·
///   相对时间」，投递自身的发布日期接口不返回，用动态的 pub_ts 兜底），点击
///   由宿主取流后进播放页
/// - **转发**：正文下方挂一块「原文」引用块（[AppBlockVariant.reply]：冷底 +
///   左竖条 + 缩进，与评论区楼中楼同一套「块」语言）——**本卡只画原文的作者
///   与正文**；原文自己的图片/视频只在详情页展开（列表里展开会把卡片撑得很长，
///   而列表的价值在「扫一眼有哪些动态」）
/// - **整卡点击**（v2.31.0+）：[onTap] → 宿主推动态详情页；不传 = 与改动前
///   逐像素一致（点正文/空白没有任何反应）
///
/// [DynamicImages] / [DynamicVideo] / [DynamicAuthorRow] 是**公开**的：动态
/// 详情页要复用同一套渲染（同一份布局规格只留一处真相），所以它们不是私有的
/// `_Xxx`。
///
/// 设计语言：无阴影；1px 描边（[kRule]）；圆角 [kRadiusSm]/[kRadiusMd]；
/// 底材/描边/竖条全部走 [AppBlock] 的统一规格表（卡片外形 = comment 规格：
/// 纸底 + hairline 四边框，它就是「一大片同级重复项」的通用内容块）。
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/dynamic_item.dart';
import '../theme/app_tokens.dart';
import '../utils/relative_time.dart';
import 'app_block.dart';
import 'cover_image.dart';
import 'expandable_text.dart';

/// 图片/头像请求兜底头（与评论区同款：B 站图床带浏览器头更稳）。
const Map<String, String> _imgHeaders = {
  'User-Agent': kBrowserUA,
  'Referer': kBiliReferer,
};

class DynamicCard extends StatelessWidget {
  final DynamicItem item;

  /// 作者名兜底（动态条目里没有作者字段时用页面已知的 UP 名）。
  final String fallbackAuthorName;

  /// 作者头像兜底（同上）。
  final String fallbackAuthorFace;

  /// 点配图：`(本卡全部图片 URL, 被点的下标)` → 宿主打开全屏查看页；
  /// null = 不挂手势。
  final void Function(List<String> urls, int index)? onImageTap;

  /// 点视频投稿（封面/标题）→ 宿主 fetch view 补 cid 后进播放页；
  /// null = 不挂手势。
  final VoidCallback? onVideoTap;

  /// 点整卡（正文/空白处）→ 宿主推动态详情页（v2.31.0+）；null = 整卡不挂
  /// 手势（点正文没有任何反应，与改动前一致）。
  ///
  /// 命中优先级：配图与视频投稿块各自是**更深**的手势识别器，Flutter 的
  /// 手势竞技场里更深者胜 → 点图仍进大图、点视频卡仍进播放页，本回调只吃到
  /// 它们的**外面**那圈（正文、作者行、留白）。
  final VoidCallback? onTap;

  const DynamicCard({
    super.key,
    required this.item,
    this.fallbackAuthorName = '',
    this.fallbackAuthorFace = '',
    this.onImageTap,
    this.onVideoTap,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DynamicAuthorRow(
          name: item.authorName.isNotEmpty
              ? item.authorName
              : fallbackAuthorName,
          face: item.authorFace.isNotEmpty
              ? item.authorFace
              : fallbackAuthorFace,
          pubTs: item.pubTs,
        ),
        if (item.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ExpandableText(
              text: item.text,
              style: kTypeBody,
              // selectable=false：完整态也用 Text，**不引入选择手势抢整卡点按**
              // （v2.31.0+ 整卡可点进详情页；SelectableText 会把正文上的点击
              // 吃掉，只剩四周留白可点，那就等于「点动态没反应」）。
              // 复制退路仍在：长按整段复制由 copyTip 兜底（完整态与折叠态都包）。
              selectable: false,
              copyTip: '已复制动态内容',
            ),
          ),
        if (item.hasImages)
          Padding(
            padding: const EdgeInsets.only(top: kSpace8),
            child: DynamicImages(
              urls: item.imageUrls,
              onTap: onImageTap,
            ),
          ),
        if (item.hasVideo)
          Padding(
            padding: const EdgeInsets.only(top: kSpace8),
            child: DynamicVideo(
              cover: item.videoCover ?? '',
              title: item.videoTitle ?? '视频投稿',
              pubTs: item.pubTs,
              onTap: onVideoTap,
            ),
          ),
        if (item.isForward)
          Padding(
            padding: const EdgeInsets.only(top: kSpace8),
            child: _OriginalBlock(item: item),
          ),
      ],
    );
    final tap = onTap;
    return AppBlock(
      variant: AppBlockVariant.comment,
      margin: const EdgeInsets.only(bottom: kListGap),
      child: tap == null
          ? body
          : Semantics(
              button: true,
              label: '动态，点击查看详情',
              // 透明 Material 承载水波纹（同 DynamicVideo；AppBlock 的纸底会
              // 盖住更外层的 Material 水波纹）
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: tap,
                  // 触达整卡的触摸目标（比只有正文可点大得多）
                  child: body,
                ),
              ),
            ),
    );
  }
}

/// 动态作者行：小圆头像 + 名字 + 相对时间（时间未知时省略，不占位）。
///
/// 与动态卡同一个视觉规格；动态详情页直接复用（同一行只留一处真相）。
class DynamicAuthorRow extends StatelessWidget {
  /// 作者名；空 → 「未知作者」。
  final String name;

  /// 作者头像 URL；空 → 人形占位。
  final String face;

  /// 发布时间（Unix 秒）；≤ 0 → 不显示时间（不占位）。
  final int pubTs;

  const DynamicAuthorRow({
    super.key,
    required this.name,
    required this.face,
    required this.pubTs,
  });

  @override
  Widget build(BuildContext context) {
    final ts = pubTs;
    final time = ts > 0
        ? fmtRelativeTime(DateTime.fromMillisecondsSinceEpoch(ts * 1000))
        : '';
    return Row(
      children: [
        ClipOval(
          child: SizedBox(
            width: 28,
            height: 28,
            child: face.isEmpty
                ? _avatarPlaceholder(context)
                : Image.network(
                    face,
                    width: 28,
                    height: 28,
                    fit: BoxFit.cover,
                    headers: _imgHeaders,
                    errorBuilder: (_, __, ___) => _avatarPlaceholder(context),
                  ),
          ),
        ),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Text(
            name.isEmpty ? '未知作者' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: kTypeTitleS,
          ),
        ),
        if (time.isNotEmpty)
          Text(time, style: kTypeBodyS.copyWith(color: kInkGray50)),
      ],
    );
  }

  Widget _avatarPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: const Icon(Icons.person, size: 17, color: kInkGray30),
    );
  }
}

/// 动态配图：1/2/3 图一行铺满，4 图及以上 2×2（第 4 张压「+N」角标）。
///
/// 动态图片不带宽高比信息 → 统一近似 4:3；列数按张数定，缩略图宽度按可用
/// 宽度均分后夹在 [80, 200]（窄屏不出横向滚动、宽屏不把一张图拉得过大）。
///
/// v2.31.0+ 起**公开**：动态详情页复用同一套布局（原文的图也走它）。
class DynamicImages extends StatelessWidget {
  final List<String> urls;
  final void Function(List<String> urls, int index)? onTap;

  static const double _gap = 4;
  static const int _maxShown = 4;

  const DynamicImages({super.key, required this.urls, this.onTap});

  @override
  Widget build(BuildContext context) {
    final shown =
        urls.length > _maxShown ? urls.sublist(0, _maxShown) : urls;
    final n = shown.length;
    if (n == 0) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, cons) {
        final cols = (n == 3) ? 3 : 2;
        final raw = (cons.maxWidth - _gap * (cols - 1)) / cols;
        final w = raw.clamp(80.0, 200.0);
        final h = w * 0.72;
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (var i = 0; i < n; i++)
              _thumb(
                context,
                shown[i],
                i,
                w,
                h,
                // 只画 4 张时把「还有几张」压在第 4 张上
                more: (i == _maxShown - 1 && urls.length > _maxShown)
                    ? urls.length - _maxShown
                    : 0,
              ),
          ],
        );
      },
    );
  }

  Widget _thumb(
    BuildContext context,
    String url,
    int index,
    double w,
    double h, {
    required int more,
  }) {
    final grey = Theme.of(context).colorScheme.surfaceContainerHighest;
    final placeholder = Container(
      width: w,
      height: h,
      color: grey,
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, size: 22, color: kInkGray30),
    );
    Widget img = Image.network(
      url,
      width: w,
      height: h,
      fit: BoxFit.cover,
      headers: _imgHeaders,
      errorBuilder: (_, __, ___) => placeholder,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Container(width: w, height: h, color: grey),
    );
    if (more > 0) {
      img = Stack(
        children: [
          img,
          Positioned.fill(
            child: Container(
              color: kInkBlack.withValues(alpha: 0.45),
              alignment: Alignment.center,
              child: Text(
                '+$more',
                style: const TextStyle(
                  color: kPaper,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    }
    final tap = onTap;
    return Semantics(
      button: tap != null,
      label: '动态图片 ${index + 1}/${urls.length}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap == null ? null : () => tap(urls, index),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusSm),
          child: img,
        ),
      ),
    );
  }
}

/// 视频投稿：封面 + 标题 + 「视频投稿 · 相对时间」（1px 描边小卡；点击交给
/// 宿主进播放页）。标题超过 2 行时多出「展开/收起」入口（[ExpandableText]）。
///
/// 数据**显式传入**（v2.31.0+ 起收 `cover/title/pubTs`，原先直接吃
/// [DynamicItem]）：动态详情页要画的「转发原文里的视频」不是本条动态自己的
/// 视频字段，收显式参数两边才能共用同一个卡片；也**公开**了。
class DynamicVideo extends StatelessWidget {
  /// 封面 URL（空 → [CoverImage] 自己的占位）。
  final String cover;

  /// 标题（空 → 「视频投稿」）。
  final String title;

  /// 时间（Unix 秒，用**本条动态**的 pub_ts 兜底，见 [_labelWithTime]）；
  /// ≤ 0 → 标签只写「视频投稿」。
  final int pubTs;

  final VoidCallback? onTap;

  const DynamicVideo({
    super.key,
    required this.cover,
    required this.title,
    required this.pubTs,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusSm),
          child: CoverImage(
            cover: cover,
            width: 120,
            height: 68,
          ),
        ),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExpandableText(
                text: title.isEmpty ? '视频投稿' : title,
                // 投稿标题 2 行截断；超行才有「展开/收起」（未超行不增子树，
                // 点标题照旧传给整块 InkWell → 仍进播放页）
                style: kTypeTitleS,
                foldLines: 2,
                selectable: false,
                animated: true,
              ),
              const SizedBox(height: kSpace4),
              Row(
                children: [
                  const Icon(Icons.play_circle_outline,
                      size: 14, color: kInkGray50),
                  const SizedBox(width: 4),
                  // 「视频投稿」+ 该动态的发布时间（相对）。
                  // 投递自身的 pubdate **接口不返回**（`major.archive` 只有
                  // bvid/title/cover/desc/duration_text 等），能拿到的时间只有
                  // 动态的 `pub_ts`（B 站投稿动态由发布动作生成，两者基本同时），
                  // 所以这里用它；pub_ts ≤ 0（脏数据）→ 只显示标签。
                  Text(
                    _labelWithTime(),
                    style: kTypeBodyS.copyWith(color: kInkGray50),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    final tap = onTap;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: kRule),
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      padding: const EdgeInsets.all(kSpace8),
      child: tap == null
          ? row
          : Semantics(
              button: true,
              label: '视频投稿，点击播放',
              // 透明 Material 承载水波纹（外层 AppBlock 的纸底会盖住更外层的
              // Material 水波纹，同 _Avatar 的处理）
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: tap,
                  borderRadius: BorderRadius.circular(kRadiusSm),
                  child: row,
                ),
              ),
            ),
    );
  }

  /// 底部标签文案：`视频投稿`（+ ` · 3 天前`；pub_ts ≤ 0 = 时间未知 → 省略）。
  ///
  /// 相对时间（不是绝对日期）是有意的：这条时间的语义是「动态/投稿的发生
  /// 时间」，与本卡作者行的时间同一套语汇（[fmtRelativeTime]），投递自身的
  /// 发布日期接口取不到（见 build 内注释）。
  String _labelWithTime() {
    if (pubTs <= 0) return '视频投稿';
    final t =
        fmtRelativeTime(DateTime.fromMillisecondsSinceEpoch(pubTs * 1000));
    return '视频投稿 · $t';
  }
}

/// 转发的原文引用块（冷底 + 左竖条 + 缩进 = 评论楼中楼的「挂靠」语言）。
class _OriginalBlock extends StatelessWidget {
  final DynamicItem item;

  const _OriginalBlock({required this.item});

  @override
  Widget build(BuildContext context) {
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
              child: Text(
                text,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: kTypeBodyS,
              ),
            ),
          if (author == null && text == null)
            Text(
              '原文已被删除',
              style: kTypeBodyS.copyWith(color: kInkGray50),
            ),
        ],
      ),
    );
  }
}
