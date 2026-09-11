/// 长文本「折叠 + 原地展开/收起」（v2.17.3+，播放页简介与评论正文共用；
/// v2.23.x+ 视频卡/播放页标题也复用同一份折叠逻辑）。
///
/// 折叠判定按**行数**而非字符数：LayoutBuilder 拿到可用宽度 → TextPainter
/// 按 [foldLines] 布局 → `didExceedMaxLines` 超行即折叠。换行/宽字符/字号
/// 都按真实排版算，比「字符数阈值」准。
///
/// 两种正文形态（同一组件，避免折叠逻辑写两份）：
/// - **纯文本**（[richChildren] 为空）：完整态默认 [SelectableText]（保留
///   选择/复制能力——原评论正文无链接分支的交互）；折叠态 SelectableText
///   不支持省略号截断，用 `Text(maxLines + ellipsis)`，展开后恢复完整。
/// - **富文本**（[richChildren] 非空，如评论正文链接混排）：折叠态
///   `Text.rich(maxLines + ellipsis)`，展开/完整态 `Text.rich` 全文——链接
///   段样式与点击都由调用方在 [richChildren] 里拼好（同一棵树同时给
///   TextPainter 测量与 Text.rich 渲染：painter 只布局不命中，识别器安全）。
///
/// 取舍与辅助参数：
/// - [copyTip] 非空 → 给「不可直接选择的正文」（折叠态纯文本 / 富文本整段）
///   包长按整段复制兜底（评论正文用「已复制评论内容」）；为空则不包
///   （播放页简介用：无链接、展开后可选择，折叠态短按展开即可，无需兜底）。
/// - [selectable]=false → 纯文本完整态也用 Text（播放页简介用：完整态要套
///   [maxExpandedHeight] 内部滚动，SelectableText 的选择手势会与滚动打架）。
/// - [maxExpandedHeight] 非空 → 展开态正文封顶该高度、超高内部滚动（防超长
///   简介把播放页固定信息行撑爆布局）；「收起」按钮始终在滚动区外可见。
/// - [animated] = true → 展开/收起时正文本体走 [AnimatedSize] 高度过渡
///   （[kDurBase] + [kCurveOut]），视频卡标题这类「只多出一行」的场景用它。
///   默认 false → 既有调用方（评论正文 / 动态正文 / 播放页简介）行为不变。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';
import '../theme/motion_control.dart';

class ExpandableText extends StatefulWidget {
  /// 完整正文。纯文本形态即直接显示此文本；富文本形态它仍是原文
  /// （供长按复制与测量，渲染以 [richChildren] 为准）。
  final String text;

  /// 基准文本样式（折叠/展开同一套；颜色/字号/行高都由此传入）。
  final TextStyle? style;

  /// 折叠行数阈值：正文按可用宽度排版超过 [foldLines] 行 → 折叠可展开。
  final int foldLines;

  /// 富文本渲染用（非空且非空列表 → 富文本形态）；否则纯文本形态。
  final List<TextSpan>? richChildren;

  /// 长按整段复制的提示文案；为空则不提供长按复制兜底。
  final String? copyTip;

  /// 纯文本完整态是否用 [SelectableText]（false → Text）。
  final bool selectable;

  /// 展开态正文封顶高度（超高内部滚动）；null = 不封顶（随内容增高）。
  final double? maxExpandedHeight;

  /// 展开/收起是否走轻动效（[kDurBase] + [kCurveOut] 的高度过渡）。
  ///
  /// 只在「超行可折叠」的分支上生效；未超行时没有展开动作、也就没有动画。
  /// 关动效（[MotionControl]）时**根本不套** [AnimatedSize]——展开即瞬时到位，
  /// 一个 controller 都不建（与播放页信息块收起的做法一致）。
  final bool animated;

  const ExpandableText({
    super.key,
    required this.text,
    this.style,
    this.foldLines = 5,
    this.richChildren,
    this.copyTip,
    this.selectable = true,
    this.maxExpandedHeight,
    this.animated = false,
  }) : assert(foldLines > 0);

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  /// 是否已展开全文（仅超行时有效；滚动离开销毁重折叠，属可接受的简单方案）。
  bool _expanded = false;

  bool get _rich => (widget.richChildren?.isNotEmpty ?? false);

  /// 完整正文的 TextSpan（纯文本单段 / 富文本透传 children）。
  TextSpan _fullSpan(TextStyle? style) => _rich
      ? TextSpan(style: style, children: widget.richChildren)
      : TextSpan(text: widget.text, style: style);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final measure = TextPainter(
          text: _fullSpan(widget.style),
          maxLines: widget.foldLines,
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: cons.maxWidth);
        final overflows = measure.didExceedMaxLines;
        if (!overflows) {
          return _buildBody(context, full: true, scrollCapped: false);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _maybeAnimated(
              context,
              _buildBody(
                context,
                full: _expanded,
                scrollCapped: widget.maxExpandedHeight != null && _expanded,
              ),
            ),
            _buildToggle(context),
          ],
        );
      },
    );
  }

  /// 展开/收起的高度过渡（[ExpandableText.animated] 且动效开启时才套）。
  /// 关动效直接返回本体：瞬时到位，不建 controller。
  Widget _maybeAnimated(BuildContext context, Widget body) {
    if (!widget.animated || !MotionControl.of(context)) return body;
    return AnimatedSize(
      duration: kDurBase,
      curve: kCurveOut,
      alignment: Alignment.topCenter,
      child: body,
    );
  }

  // -------------------------------------------------------------------------
  // 正文（折叠 / 完整两态 × 纯文本 / 富文本两形态）
  // -------------------------------------------------------------------------

  Widget _buildBody(
    BuildContext context, {
    required bool full,
    required bool scrollCapped,
  }) {
    Widget body;
    if (_rich) {
      final span = _fullSpan(widget.style);
      body = full
          ? Text.rich(span)
          : Text.rich(span, maxLines: widget.foldLines, overflow: TextOverflow.ellipsis);
      // 富文本整段不可长按选择：长按整段复制兜底（与 v2.16.19 原行为一致）
      body = _wrapCopy(body);
    } else if (full) {
      final t = widget.text;
      body = widget.selectable ? SelectableText(t, style: widget.style) : Text(t, style: widget.style);
    } else {
      // 折叠态：SelectableText 不支持省略号，退化为 Text + ellipsis
      //（长按整段复制由 _wrapCopy 按 copyTip 兜底）
      body = Text(
        widget.text,
        style: widget.style,
        maxLines: widget.foldLines,
        overflow: TextOverflow.ellipsis,
      );
      body = _wrapCopy(body);
    }
    if (scrollCapped) {
      // 展开态封顶高度：超高内部滚动（收起按钮在滚动区外不受影响）
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxExpandedHeight!),
        child: SingleChildScrollView(child: body),
      );
    }
    return body;
  }

  /// 长按整段复制兜底（有 [copyTip] 才包）。
  Widget _wrapCopy(Widget child) {
    final tip = widget.copyTip;
    if (tip == null || tip.isEmpty) return child;
    return GestureDetector(
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(tip),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ));
      },
      child: child,
    );
  }

  // -------------------------------------------------------------------------
  // 展开 / 收起切换
  // -------------------------------------------------------------------------

  Widget _buildToggle(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: _expanded ? '收起全文' : '展开全文',
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.only(top: 2, right: 4),
            child: Text(
              _expanded ? '收起' : '展开',
              style: TextStyle(fontSize: 12.5, color: primary),
            ),
          ),
        ),
      ),
    );
  }
}
