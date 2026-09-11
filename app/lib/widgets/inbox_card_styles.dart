/// 信箱卡片的**版式（风格）**：比例 + 风格表 + 五种渲染。
///
/// ## 比例（扑克牌）
/// 卡片宽 : 高 = **1 : [kInboxCardAspect]**（扑克牌 63:88 ≈ 1:1.397，取 1.39）。
/// 宽度由宿主按屏宽算（`min(屏宽 × 0.88, 420)`），高度 = 宽 × 1.39。
/// 411×914 竖屏下：卡宽 361.7 → 卡高 502.7，加底部按钮栏 76 后仍远小于
/// 一屏可用高度（914 − 状态栏 − AppBar 56）→ 不出屏（见 `inbox_page.dart`）。
///
/// ## 风格表 = 唯一真相源
/// [kInboxCardStyles] 列全部风格；持久化只存 [InboxCardStyle.id]
/// （见 `services/inbox_card_style_store.dart`），所以**调排版不必迁移已存数据**。
///
/// ### 新增一个风格要动哪几处
/// 1. [InboxCardVariant] 加一个枚举值；
/// 2. [kInboxCardStyles] 加一条（id / 中文名 / 一句话说明 / variant）；
/// 3. 本文件底部写一个 `_XxxLayout`（内容只用 `_Facts` + [_CoverRegion] 拼）；
/// 4. [InboxCardStyleView.build] 的 `switch` 加一条分支（**穷尽**，漏了编译不过）；
/// 5. `test/inbox_card_style_test.dart` 的 `kInboxCardStyles` 遍历用例会自动覆盖
///    新风格的「能渲染 / 比例 / 长标题 / 空封面 / 封面不裁」——补一条风格特有的
///    排版断言即可。
/// 设置页（`manage_panel.dart` 的「信箱卡片样式」）与缩略预览都读同一张表，
/// **不用改**。
///
/// ## 设计约束（与全 App 一致）
/// - **无阴影**：层级只用底材差 / 1px 描边 / 墨条表达（与 `app_block.dart` 同语言）；
/// - 颜色一律 `context.palette.*` 或 `app_tokens.dart` 常量，不写字面量；
/// - 实心底只用**已过对比度护栏**的档位（[AppPalette.inkFill] + [AppPalette.onInk]、
///   [kInkGray70] + [kPaper]）；
/// - 封面走 [_CoverRegion]：**16:9 的图完整显示、不裁左右、不拉伸**，区域比
///   16:9 多出来的部分用同图模糊底衬（详见该类的说明）。禁止直接拿 [CoverImage]
///   铺一个非 16:9 的区域 —— 那正是「缩略图上的标题被切断」的成因；
/// - 空封面（`cover.isEmpty`）由 [_Cover] 叠一层「暂无封面」标版，
///   在铺满/裁切场景下也不至于是一块纯色。
///
/// ## 参考到的成熟手法（翻译成本项目语言）
/// - **floor fade / scrim**（CSS-Tricks *Design Considerations: Text on Images*、
///   Prototypr *Techniques to Display Text over Background Images*：黑 → 透明的
///   渐变遮罩，40% 左右不透明度、覆盖约一半高度）→ `classic` 的底部渐变；
///   Tinder 那套彩色渐变/投影不采纳（与单墨印刷美学相冲），只借「暗底压字」；
/// - **图与信息分区（header / body / footer）**（Eleken *17 Card UI Design
///   Examples*：把卡面切成清晰的区块、用留白建立层级）→ `editorial` / `banner`；
/// - **字阶层级：标题必须明显大于说明，一卡一个主行动**
///   （Stan Vision *UI Card Design: Best Practices*）→ 各风格标题统一
///   [kTypeTitleM]，元信息一律降到 [kTypeBodyS] / [kTypeNum]；
/// - **framed image（把图装进色块/相框）**（Smashing Magazine *Designing
///   Accessible Text Over Images*）→ `polaroid` 的 1px 相纸内框 + 大留白下边；
/// - **角标/贴纸位置**（NativeScript *Tinder-style Cards* 的叠加 sticker、
///   draggable 卡片上的角标）→ 时长角标固定右上（`classic`）/ 信息条右侧（`banner`）；
/// - **图片主导 + 元信息降级**（Mobbin card glossary、Mockplus *Card UI Design*
///   的「图像 → 标题 → 价格/元信息」层级）→ 五种风格都保留封面主导地位；
/// - 不采纳：投影（本设计语言无阴影）、彩色渐变底、圆角 ≥ 12（只用
///   [kRadiusXs]/[kRadiusSm]/[kRadiusMd]）。
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../services/inbox_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../utils/relative_time.dart';
import 'cover_image.dart';
import 'video_tile.dart' show fmtDuration;

/// 扑克牌比例：高 = 宽 × 该值（63:88 = 1.3968，取 1.39）。
const double kInboxCardAspect = 1.39;

/// 按卡片宽度算高度（唯一入口：宿主与各种版式都用它，保证比例一致）。
double inboxCardHeight(double width) => width * kInboxCardAspect;

/// 封面的天然比例：B 站视频缩略图是 **16:9**（且标题常烧在图上、贴左右两缘）。
const double kInboxCoverAspect = 16 / 9;

/// 卡片里**完整显示的那张 16:9 封面**的 key。
///
/// 测试用它断言「这张图的渲染框宽高比 == 16:9」—— 比例一致时 `CoverImage`
/// 内置的 `BoxFit.cover` 等价于 `contain`，**不可能裁掉左右两缘的文字**。
const Key kInboxCardCoverKey = Key('inbox-card-cover');

/// 版式变体：一个变体 = 一个渲染分支。
enum InboxCardVariant {
  /// 全出血氛围（16:9 图完整**贴上缘** + 同图模糊底衬，下缘抹开）+ 底部渐变
  /// 遮罩，文字压在图上
  classic,

  /// 编辑排版：封面上、纸面下，UP 主小标 + 墨条标题 + 底部信息行
  editorial,

  /// 宝丽来：纸框留白 + 相纸内框 + 居中题注
  polaroid,

  /// 沉浸横幅：封面铺满上半，底部纸白信息条
  banner,

  /// 极简留白：接近满宽的封面居中 + 大字标题
  minimal,
}

/// 一种卡片版式。
@immutable
class InboxCardStyle {
  const InboxCardStyle({
    required this.id,
    required this.label,
    required this.description,
    required this.variant,
  });

  /// 稳定 id（shared_preferences 里存的就是它）。
  final String id;

  /// 中文名（设置页按钮 / 选项标题）。
  final String label;

  /// 一句话说明（设置页选项副标题）。
  final String description;

  /// 渲染分支。
  final InboxCardVariant variant;
}

/// 默认版式（读不到记录 / id 不认识 → 回退到它）。
const InboxCardStyle kDefaultInboxCardStyle = InboxCardStyle(
  id: 'classic',
  label: '经典满幅',
  description: '封面铺满整张，标题压在下缘渐变上（最接近 Tinder）',
  variant: InboxCardVariant.classic,
);

/// 全部风格（**唯一真相源**：设置页选项、缩略预览、持久化回读都读它）。
const List<InboxCardStyle> kInboxCardStyles = [
  kDefaultInboxCardStyle,
  InboxCardStyle(
    id: 'editorial',
    label: '编辑排版',
    description: '封面上、纸面下：UP 主小标 + 墨条标题 + 底部信息行',
    variant: InboxCardVariant.editorial,
  ),
  InboxCardStyle(
    id: 'polaroid',
    label: '宝丽来',
    description: '纸框留白，像刚冲印出来的照片，题注居中在下方白边上',
    variant: InboxCardVariant.polaroid,
  ),
  InboxCardStyle(
    id: 'banner',
    label: '沉浸横幅',
    description: '封面铺满上半，底部一条纸白信息条（墨色时长标签）',
    variant: InboxCardVariant.banner,
  ),
  InboxCardStyle(
    id: 'minimal',
    label: '极简留白',
    description: '接近满宽的封面居中、大字标题，四周留白',
    variant: InboxCardVariant.minimal,
  ),
];

/// id → 风格；null / 空串 / 不认识 → [kDefaultInboxCardStyle]（不抛）。
InboxCardStyle inboxCardStyleById(String? id) {
  for (final s in kInboxCardStyles) {
    if (s.id == id) return s;
  }
  return kDefaultInboxCardStyle;
}

/// 按 [style] 渲染一张卡片的**全部内容**（含卡面外形与尺寸）。
///
/// 宿主 [InboxSwipeCard] 只负责套尺寸 + 叠手势浮层（见 `inbox_swipe_card.dart`）。
class InboxCardStyleView extends StatelessWidget {
  const InboxCardStyleView({
    super.key,
    required this.item,
    required this.style,
    required this.width,
  });

  /// 条目数据。
  final InboxItem item;

  /// 版式（见 [kInboxCardStyles]）。
  final InboxCardStyle style;

  /// 卡片宽度（高度 = 宽 × [kInboxCardAspect]）。
  final double width;

  /// 卡片高度（扑克牌比例）。
  double get height => inboxCardHeight(width);

  @override
  Widget build(BuildContext context) {
    final facts = _Facts(item);
    switch (style.variant) {
      case InboxCardVariant.classic:
        return _ClassicLayout(facts: facts, width: width, height: height);
      case InboxCardVariant.editorial:
        return _EditorialLayout(facts: facts, width: width, height: height);
      case InboxCardVariant.polaroid:
        return _PolaroidLayout(facts: facts, width: width, height: height);
      case InboxCardVariant.banner:
        return _BannerLayout(facts: facts, width: width, height: height);
      case InboxCardVariant.minimal:
        return _MinimalLayout(facts: facts, width: width, height: height);
    }
  }
}

// ==================== 共享文案 ====================

/// 卡片要显示的四样东西（各版式只取用，不各自判空）。
class _Facts {
  _Facts(this.item);

  final InboxItem item;

  String get cover => item.cover;

  /// 标题（空标题回退 bvid，与旧实现一致）。
  String get title => item.title.isEmpty ? item.bvid : item.title;

  /// UP 主名（空名回退「未知 UP 主」）。
  String get upName => item.upName.isEmpty ? '未知 UP 主' : item.upName;

  String get upFace => item.upFace;

  /// 时长（≤0 显示 `--:--`）。
  String get duration =>
      item.duration > 0 ? fmtDuration(item.duration) : '--:--';

  /// 相对时间；pubDate ≤ 0（脏数据）→ 空串（不显示这一段）。
  String get pub {
    if (item.pubDate <= 0) return '';
    return fmtRelativeTime(
      DateTime.fromMillisecondsSinceEpoch(item.pubDate * 1000),
    );
  }
}

// ==================== 共享零件 ====================

/// 封面（按调用方给的盒子填充 + 空封面标版）。
///
/// ⚠️ 各版式**不要直接**用它铺一个非 16:9 的区域（那会左右裁掉缩略图上的字），
/// 走 [_CoverRegion]。
class _Cover extends StatelessWidget {
  const _Cover({
    super.key,
    required this.facts,
    required this.width,
    required this.height,
  });

  final _Facts facts;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final image = CoverImage(cover: facts.cover, width: width, height: height);
    if (facts.cover.isNotEmpty) return image;
    // 空封面：CoverImage 的兜底是「纯色块 + 20px 小图标」，铺满整卡时太空 →
    // 叠一层标版（大图标 + 一行小字），保持印刷感、也不至于看不出是封面位。
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, size: 36, color: kInkGray30),
              const SizedBox(height: kSpace8),
              Text('暂无封面', style: kTypeLabel.copyWith(color: kInkGray70)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 封面区（[width]×[height]）里**完整**放进一张 16:9 的封面 —— 不裁左右、不拉伸。
///
/// ## 为什么必须这样（设备实测的缺陷）
/// 卡片是 1:1.39 的竖版，而封面区在多数版式里比 16:9「窄」（editorial 的
/// 361×290 ≈ 1.25:1、banner 361×371 ≈ 0.98:1）。直接把图铺满时 `BoxFit.cover`
/// 会按高度撑满 → **左右各裁 20%+**。B 站缩略图把标题烧在图上且常贴左右两缘，
/// 于是文字被切断（"…决定/…的人工智能"直接断字）。
///
/// ## 做法
/// 按 **contain 语义**算图的实际落位（宽高都按 16:9 定死：
/// `fitW = min(区域宽, 区域高 × 16/9)`）→ 图完整；区域多出来的部分用
/// **同一张封面放大 + 高斯模糊**铺底（现代 App 常见做法：图完整、四周有气氛底，
/// 也不会出现两条死板的纯色带）。
///
/// 区域本身正好是 16:9 时（`minimal`）图正好铺满，不建那层底衬。
/// 为什么不让每个风格都直接把封面区做成 16:9：卡片总高固定（扑克牌比例），
/// 16:9 的封面只占卡高的 ~41%，信息区会被撑到 ~300dp 而内容只有 ~110dp →
/// 变成大片死白（正是 `minimal` 被吐槽的那个毛病）。保住各风格的图文比例、
/// 只把「裁」换成「完整显示 + 底衬」，既有观感与信息密度都不动。
///
/// ## 接缝（v2.21.0-r3 修）
/// 底衬与清晰图之间本来是**硬边**：亮 / 杂色封面下肉眼可见（设备实测原话
/// "像糊了一层灰纱，接缝处能看出色带断层"）。其中 `classic` **上方那条**最刺眼
/// —— 它四周没有任何遮挡，还占掉约 30% 卡高。两条对策（都只 `classic` 用）：
/// - [alignTop]：图顶对齐 → **上底衬 = 0**，多余的竖向空间全给下方；下方本来就有
///   黑渐变遮罩盖着，那里就算有边也看不出（`editorial` 的底衬只占 9% 却被评
///   "最协调"，也印证了"底衬越窄越不露馅"）；
/// - [fadeBottom]：清晰图下缘做一段「实心 → 透明」的过渡，把剩下的那条边抹开。
/// 不采纳"再叠一层卡底色把底衬压灰"：那等于真的加一层灰纱，与"看不出接缝"相冲。
class _CoverRegion extends StatelessWidget {
  const _CoverRegion({
    required this.facts,
    required this.width,
    required this.height,
    this.alignTop = false,
    this.fadeBottom = 0,
  });

  final _Facts facts;

  /// 封面区的标称尺寸（兜底：约束无界时用它；正常路径取 [LayoutBuilder] 的实参）。
  final double width;
  final double height;

  /// 清晰图**顶对齐**（`classic`）：图贴上缘、上底衬 = 0，多余空间全给下方。
  final bool alignTop;

  /// 清晰图**下缘**的过渡带高度（dp，0 = 不淡化，见类的「接缝」一节）。
  ///
  /// 只淡下缘、不淡上缘：顶对齐时上缘贴卡片顶部，一淡就会露出一条模糊带。
  final double fadeBottom;

  /// 底衬的模糊半径（dp）：够模糊（只剩颜色气氛、看不出细节）又不至于发灰。
  static const double _blurSigma = 18;

  @override
  Widget build(BuildContext context) {
    // ★ 必须用**实际**可用尺寸算（`LayoutBuilder` 的 maxWidth/maxHeight）：
    //   调用方给的 [width]/[height] 外面常套着 1px 描边/相纸内框，真到手的盒子
    //   会小 2dp。拿标称值算出的 16:9 盒子会被父约束**压扁**（宽被截、高不变）
    //   → 比例就不再是 16:9，`cover` 又会在左右各裁一点点。
    return LayoutBuilder(
      builder: (context, constraints) {
        final availW =
            constraints.maxWidth.isFinite ? constraints.maxWidth : width;
        final availH =
            constraints.maxHeight.isFinite ? constraints.maxHeight : height;
        // 16:9 完整图的落位尺寸（contain 语义）：宽放得下就按宽，否则按高
        final fitW = math.min(availW, availH * kInboxCoverAspect);
        final fitH = fitW / kInboxCoverAspect;
        final sharp = SizedBox(
          width: fitW,
          height: fitH,
          child: _Cover(
            facts: facts,
            key: kInboxCardCoverKey,
            width: fitW,
            height: fitH,
          ),
        );
        // 区域本身就是 16:9 → 图正好铺满（cover == contain），底衬看不见，不建
        final fills = (fitW - availW).abs() < 0.5 && (fitH - availH).abs() < 0.5;
        if (fills) return sharp;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 底衬：同一张封面铺满整个区域 + 高斯模糊。
            // 复用 CoverImage → 防盗链头 / 加载失败占位 / 空封面占位都只有一处实现。
            ClipRect(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: _blurSigma,
                  sigmaY: _blurSigma,
                  tileMode: TileMode.clamp,
                ),
                child: CoverImage(
                  cover: facts.cover,
                  width: availW,
                  height: availH,
                ),
              ),
            ),
            Align(
              alignment: alignTop ? Alignment.topCenter : Alignment.center,
              child: _withBottomFade(sharp),
            ),
          ],
        );
      },
    );
  }

  /// 清晰图下缘「实心 → 透明」的过渡（[fadeBottom] dp；0 → 原样返回）。
  ///
  /// 用 [ShaderMask] + [BlendMode.dstIn]：遮罩只取 alpha、不参与上色 → 图本身的
  /// 颜色一个像素都不动，只是下缘逐渐让位给底衬，硬边变成一段渐变。
  Widget _withBottomFade(Widget child) {
    if (fadeBottom <= 0) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        // 过渡带占图片高度的比例（封顶 1/3，免得整张图都被淡没）
        final f = (fadeBottom / rect.height).clamp(0.0, 1 / 3);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // 颜色不上屏（只取 alpha），仍用 token 保持「不写字面量」
          colors: [kPaper, kPaper, kPaper.withValues(alpha: 0)],
          stops: [0, 1 - f, 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

/// UP 主圆形头像：空 face / 加载失败 / 加载中 → 人形占位。
class _Face extends StatelessWidget {
  const _Face({required this.face, this.size = 20});

  final String face;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      color: kPaperCool,
      child: Icon(Icons.person, size: size * 0.65, color: kInkGray70),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: face.isEmpty
            ? placeholder
            : Image.network(
                face,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
              ),
      ),
    );
  }
}

/// UP 主行：头像 + 名字（名字过长省略）。
class _UpRow extends StatelessWidget {
  const _UpRow({required this.facts, required this.style, this.faceSize = 20});

  final _Facts facts;
  final TextStyle style;
  final double faceSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Face(face: facts.upFace, size: faceSize),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Text(
            facts.upName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// 时长角标：实心 [AppPalette.inkFill] + [AppPalette.onInk]（已过对比度护栏）。
class _DurationChip extends StatelessWidget {
  const _DurationChip({required this.text, this.dense = false});

  final String text;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? kSpace8 : 10,
        vertical: dense ? kSpace2 : kSpace4,
      ),
      decoration: BoxDecoration(
        color: palette.inkFill,
        borderRadius: BorderRadius.circular(kRadiusXs),
      ),
      child: Text(
        text,
        style: kTypeNum.copyWith(color: palette.onInk, letterSpacing: 0.5),
      ),
    );
  }
}

/// 标题（统一字阶：各风格只差颜色/对齐；一律 2 行 + 省略号，不溢出）。
class _Title extends StatelessWidget {
  const _Title({required this.text, required this.style, this.textAlign});

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: style,
    );
  }
}

// ==================== classic：全出血 + 渐变遮罩 ====================

/// 底部渐变遮罩占卡片高度的比例。
///
/// 文字块（2 行标题 + 作者行 + 时间行 + 内边距 ≈ 130dp）只落在底部 ~28%，
/// 该区间遮罩不透明度 ≥ 0.6（保守估计遮罩 0.6 压在纯白封面上 → 纸白文字
/// 仍有 ≈ 5.6:1，过 WCAG AA 正文 4.5:1）；遮罩往上迅速淡出，不糊封面。
const double _kClassicScrimH = 0.62;

/// `classic` 清晰图**下缘**的过渡带高度（dp）。
///
/// 顶对齐之后，清晰图下缘与模糊底衬之间还剩一条硬边（位置约在卡高 40% 处，
/// 那里遮罩才刚起头、几乎没把它盖住）→ 用这段渐变把边抹开（见 [_CoverRegion]
/// 的「接缝」一节）。20dp ≈ 清晰图高度的 10%：够抹平色带断层，又不至于把封面
/// 下缘的烧字吃掉一块。
const double kInboxClassicCoverFade = 20;

class _ClassicLayout extends StatelessWidget {
  const _ClassicLayout({
    required this.facts,
    required this.width,
    required this.height,
  });

  final _Facts facts;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: kPaper,
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(color: kRuleStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 全出血氛围：16:9 的图**完整**显示、**顶对齐**，下方由同一张图的模糊
            // 底衬铺满（「图完整 + 有气氛底」；直接 cover 铺满会把图上左右两缘的
            // 字裁掉）。顶对齐 = 上底衬 0：原来居中的图上方有 ~30% 卡高的裸露模糊
            // 区，与清晰图之间一条硬边（设备实测"像糊了一层灰纱"）；现在多余空间全
            // 给下方 —— 下方本来就被渐变遮罩压暗，剩下那条边再用 [kInboxClassicCoverFade]
            // 抹成渐变。
            _CoverRegion(
              facts: facts,
              width: width,
              height: height,
              alignTop: true,
              fadeBottom: kInboxClassicCoverFade,
            ),
            // floor fade：黑 → 透明（只在底部）
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: width,
                height: height * _kClassicScrimH,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        kInkBlack.withValues(alpha: 0),
                        kInkBlack.withValues(alpha: 0.30),
                        kInkBlack.withValues(alpha: 0.68),
                        kInkBlack.withValues(alpha: 0.95),
                      ],
                      stops: const [0, 0.40, 0.65, 1],
                    ),
                  ),
                ),
              ),
            ),
            // 右上角时长角标（实心底，不受封面明暗影响）
            Positioned(
              top: kSpace12,
              right: kSpace12,
              child: _DurationChip(text: facts.duration),
            ),
            // 下缘文字块：标题 → 作者 → 时间（自下而上压住遮罩最浓处）
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Padding(
                padding: const EdgeInsets.all(kSpace16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Title(
                      text: facts.title,
                      style: kTypeTitleM.copyWith(
                        color: kPaper,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: kSpace8),
                    _UpRow(
                      facts: facts,
                      style: kTypeBodyS.copyWith(color: kPaper),
                    ),
                    if (facts.pub.isNotEmpty) ...[
                      const SizedBox(height: kSpace8),
                      Text(
                        facts.pub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kTypeBodyS.copyWith(color: kPaper),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== editorial：编辑排版（印刷感） ====================

/// 纸面信息区占卡片高度的比例（其余是封面）。
const double _kEditorialInfoRatio = 0.42;

/// 信息区高度的下限 / 上限（dp）。
///
/// 信息区里是**固定 dp 的文字块**（UP 主小标 + 2 行标题 + 信息行 + 内边距
/// ≈ 113dp）：纯按比例算时卡片一窄（设置页缩略预览只有
/// [kInboxCardPreviewRenderW] = 240 宽）就不够高 → 溢出。上下限把
/// 「窄卡」与「超大卡」两种极端都挡住（比例在常规手机上仍然生效）。
const double _kEditorialInfoMinH = 122;
const double _kEditorialInfoMaxH = 240;

class _EditorialLayout extends StatelessWidget {
  const _EditorialLayout({
    required this.facts,
    required this.width,
    required this.height,
  });

  final _Facts facts;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final infoH = (height * _kEditorialInfoRatio)
        .clamp(_kEditorialInfoMinH, _kEditorialInfoMaxH);
    // 1px 版线归给封面一侧（Column 里它是一条独立子项）
    final coverH = height - 1 - infoH;
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: kPaper,
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(color: kRuleStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: width,
              height: coverH,
              // 16:9 的图完整落在这个区块里，多出来的高度用同图模糊底衬
              child: _CoverRegion(facts: facts, width: width, height: coverH),
            ),
            // 图 / 文的 hairline 分界（印刷的「版线」）
            Container(height: 1, color: kRule),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  kSpace16,
                  kSpace12,
                  kSpace16,
                  kSpace12,
                ),
                child: Column(
                  // 印前留白均分：整块文案在上下的空白里居中。老实现拿 Spacer 把信息行
                  // 顶到底 → 标题贴上、时长/时间行贴下，中间一段 ~110dp 纯白（1 行标题
                  // 时尤其像"这页没排满"）。居中后仍留呼吸感，但不再有明显空档。
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 编前小标：UP 主（小字 + 放宽字距）
                    Row(
                      children: [
                        _Face(face: facts.upFace, size: 16),
                        const SizedBox(width: kSpace8),
                        Expanded(
                          child: Text(
                            facts.upName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: kTypeLabel.copyWith(color: kInkGray70),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: kSpace8),
                    // 标题：左侧一道短墨条（复用块化语言）
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _InkBar(),
                        const SizedBox(width: kSpace8),
                        Expanded(
                          child: _Title(
                            text: facts.title,
                            style: kTypeTitleM.copyWith(
                              color: kInkBlack,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // 标题块 →「版线 + 信息行」之间只留一个固定小间距（原来是 Spacer
                    // 一路撑到底，剩下一段大空档）
                    const SizedBox(height: kSpace12),
                    Container(height: 1, color: kRule),
                    const SizedBox(height: kSpace8),
                    Row(
                      children: [
                        const Icon(Icons.schedule, size: 14, color: kInkGray70),
                        const SizedBox(width: kSpace4),
                        Text(
                          facts.duration,
                          style: kTypeNum.copyWith(color: kInkGray70),
                        ),
                        if (facts.pub.isNotEmpty) ...[
                          const Spacer(),
                          Flexible(
                            child: Text(
                              facts.pub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: kTypeBodyS.copyWith(color: kInkGray70),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标题左侧的短墨条（3×20，[AppPalette.inkDeco]：与纸底 ≥ 3:1，浅墨配方自动压深）。
class _InkBar extends StatelessWidget {
  const _InkBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 20,
      margin: const EdgeInsets.only(top: kSpace2),
      decoration: BoxDecoration(
        color: context.palette.inkDeco,
        // 贴左边缘那侧必须是直角（与 app_block 的左侧竖条同规则）
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(1.5),
        ),
      ),
    );
  }
}

// ==================== polaroid：宝丽来相框 ====================

/// 下方留白（题注）区占卡片高度的比例 —— 其余是相纸上的照片。
/// 宝丽来的签名特征就是「照片上方窄、下方白边宽」。
const double _kPolaroidCaptionRatio = 0.27;

/// 留白区高度的下限 / 上限（dp）：同 editorial，题注块是固定 dp
/// （2 行标题 + 作者行 + 时间行 + 内边距 ≈ 113dp），窄卡下纯比例会溢出。
const double _kPolaroidCaptionMinH = 118;
const double _kPolaroidCaptionMaxH = 160;

class _PolaroidLayout extends StatelessWidget {
  const _PolaroidLayout({
    required this.facts,
    required this.width,
    required this.height,
  });

  final _Facts facts;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    const margin = 14.0;
    final photoW = width - margin * 2;
    final captionH = (height * _kPolaroidCaptionRatio)
        .clamp(_kPolaroidCaptionMinH, _kPolaroidCaptionMaxH);
    final photoH = height - margin - captionH;
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: kPaper,
          // 相纸是直角（只用最小的 2dp，区别于其它风格的卡片圆角）
          borderRadius: BorderRadius.circular(kRadiusXs),
          border: Border.all(color: kRuleStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(margin, margin, margin, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 冲印照片 + 一圈相纸内框（16:9 的图完整落进来，不裁左右）
              Container(
                height: photoH,
                decoration: BoxDecoration(border: Border.all(color: kRule)),
                child: _CoverRegion(facts: facts, width: photoW, height: photoH),
              ),
              // 下方宽白边：题注居中（像手写在相纸上的字）
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: kSpace8,
                      vertical: kSpace12,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Title(
                          text: facts.title,
                          style: kTypeTitleM.copyWith(
                            color: kInkBlack,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: kSpace8),
                        // 题注行要**整体居中**（不能用 _UpRow：它是撑满宽度的
                        // 行，头像会贴到左边缘）→ 用 mainAxisSize.min 的自适应行
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Face(face: facts.upFace, size: 16),
                            const SizedBox(width: kSpace8),
                            Flexible(
                              child: Text(
                                facts.upName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: kTypeBodyS.copyWith(color: kInkGray70),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: kSpace8),
                        Text(
                          facts.pub.isEmpty
                              ? facts.duration
                              : '${facts.duration} · ${facts.pub}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kTypeNum.copyWith(color: kInkGray70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== banner：沉浸图 + 纸白信息条 ====================

/// 底部信息条高度占卡片高度的比例。
const double _kBannerStripRatio = 0.26;

/// 信息条高度的下限 / 上限（dp）：条里是固定 dp 的文字块
/// （2 行标题 + 作者行 + 时长标签 ≈ 105dp），窄卡下纯比例会溢出。
const double _kBannerStripMinH = 112;
const double _kBannerStripMaxH = 148;

class _BannerLayout extends StatelessWidget {
  const _BannerLayout({
    required this.facts,
    required this.width,
    required this.height,
  });

  final _Facts facts;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final stripH = (height * _kBannerStripRatio)
        .clamp(_kBannerStripMinH, _kBannerStripMaxH);
    // 信息条上沿的 1px 实线归给信息条一侧
    final coverH = height - 1 - stripH;
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: kPaper,
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(color: kRuleStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: width,
              height: coverH,
              // 16:9 的图完整落在这个区块里，多出来的高度用同图模糊底衬
              child: _CoverRegion(facts: facts, width: width, height: coverH),
            ),
            // 信息条上沿的实线（把「图」与「条」明确切开）
            Container(height: 1, color: kRuleStrong),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  kSpace12,
                  kSpace12,
                  kSpace12,
                  kSpace12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Title(
                      text: facts.title,
                      style: kTypeTitleM.copyWith(
                        color: kInkBlack,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: _UpRow(
                            facts: facts,
                            faceSize: 18,
                            style: kTypeBodyS.copyWith(color: kInkGray70),
                          ),
                        ),
                        const SizedBox(width: kSpace8),
                        _DurationChip(text: facts.duration, dense: true),
                      ],
                    ),
                    if (facts.pub.isNotEmpty) ...[
                      const SizedBox(height: kSpace4),
                      Text(
                        facts.pub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kTypeBodyS.copyWith(color: kInkGray70),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== minimal：极简留白 ====================

/// 封面宽度占卡片宽度的比例（放大到接近满宽：小图看不出是什么视频，
/// 划卡时认不出来；仍比卡片窄一圈，保住「极简 + 两侧留白」的气质）。
///
/// 0.84 → 0.90（v2.21.0-r3）：0.84 在 361.7dp 的卡上只有 303.8dp 宽、171dp 高，
/// 配 1:1.39 的卡高（502.7dp）仍是"图小、四周太空"。16:9 的图高度受宽度支配，
/// 就算铺满卡宽也只有卡高 ~40% —— 所以只能"图尽量占满宽 + 把留白摆匀"，
/// 不可能填满（填满就是退回裁切，会切掉图上的烧字）。
const double _kMinimalCoverW = 0.90;

class _MinimalLayout extends StatelessWidget {
  const _MinimalLayout({
    required this.facts,
    required this.width,
    required this.height,
  });

  final _Facts facts;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final coverW = width * _kMinimalCoverW;
    // 封面保持 16:9（视频的天然形状），高度受宽度支配 → 不拉伸
    final coverH = coverW / kInboxCoverAspect;
    return SizedBox(
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: kPaper,
          borderRadius: BorderRadius.circular(kRadiusMd),
          // 极简：只留一根 hairline，不抢封面
          border: Border.all(color: kRule),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // 上下留白 1:1 均分：图 + 标题 + 元信息整块**垂直居中**，重心落在卡片
            // 正中。老实现是 flex 4:5（内容偏上、下方留白更大）→ 设备反馈仍是
            // "封面小、下方大片白"，那条偏大的下留白就是偏心感的来源。
            const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(kRadiusSm),
              child: SizedBox(
                width: coverW,
                height: coverH,
                child: _CoverRegion(facts: facts, width: coverW, height: coverH),
              ),
            ),
            const SizedBox(height: kSpace24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSpace24),
              child: _Title(
                text: facts.title,
                style: kTypeTitleM.copyWith(
                  color: kInkBlack,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: kSpace12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSpace24),
              child: Text(
                facts.pub.isEmpty
                    ? '${facts.upName} · ${facts.duration}'
                    : '${facts.upName} · ${facts.duration} · ${facts.pub}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: kTypeBodyS.copyWith(color: kInkGray70),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

// ==================== 设置页缩略预览 ====================

/// 预览用的示例条目：封面 / 头像留空 → 走本地占位（缩略图**不联网**），
/// 发布时间取固定时间戳（久远 → 显示绝对日期，不随当天时间漂移）。
const InboxItem kInboxCardPreviewItem = InboxItem(
  upMid: 0,
  upName: '白名单 UP 主',
  upFace: '',
  bvid: 'BV1xx411c7mD',
  title: '示例视频标题',
  cover: '',
  duration: 245,
  pubDate: 1700000000,
);

/// 预览渲染时用的「真实卡片宽度」：先按这个宽度用**同一套版式**渲染，
/// 再用 [FittedBox] 等比缩到目标宽 → 字阶、内边距、留白比例都与真机一致。
const double kInboxCardPreviewRenderW = 240;

/// 设置页里的**缩略预览卡**（宽 [width]、高按扑克牌比例）。
///
/// 复用同一个渲染器 [InboxCardStyleView]（不是另画一套简图）→
/// 预览与真机必然一致；缩放靠 [FittedBox]（比例本来就一致，等比缩放即可）。
class InboxCardPreview extends StatelessWidget {
  const InboxCardPreview({
    super.key,
    required this.style,
    this.width = 72,
    this.item = kInboxCardPreviewItem,
  });

  /// 要预览的版式。
  final InboxCardStyle style;

  /// 缩略卡宽度（高度 = 宽 × [kInboxCardAspect]）。
  final double width;

  /// 示例数据（默认 [kInboxCardPreviewItem]）。
  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: width,
        height: inboxCardHeight(width),
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: kInboxCardPreviewRenderW,
            height: inboxCardHeight(kInboxCardPreviewRenderW),
            child: InboxCardStyleView(
              item: item,
              style: style,
              width: kInboxCardPreviewRenderW,
            ),
          ),
        ),
      ),
    );
  }
}
