import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_source_index_service.dart';
import '../services/book_source_store.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';

/// 索引书源选择页（R3 新增）：把「4 行 .json 地址」变成「挑几个导进去」。
///
/// ## 为什么是全屏页而不是对话框
/// 索引里通常有 3000~6000 个源，要搜索、要筛选、要勾选、要显示「已选 N /
/// 可导入剩余 M」。对话框（最大 ~560dp 高）放这套东西会觉得处处顶着边；
/// 全屏页还能用 `ListView.builder` 只建可见行，6000 条也不掉帧。
///
/// ## 上限为什么必须显式写出来
/// [BookSourceStore.maxSources] 是 200，而且**超限是整次写入被拒绝**（不是
/// 悄悄截断）。用户从 6000 个里勾了 300 个，点「导入」只换来一句「导入失败」
/// 会很莫名其妙 —— 所以底部实时显示「已选 N / 可导入剩余 M」，选超了就把
/// 导入按钮禁掉并直说上限是 200。
///
/// ## 性能上的三条硬规矩
/// 1. 列表一律 `ListView.builder`（6000 条全建 = 必卡）；
/// 2. 过滤结果 [_visible] 在筛选条件变化时**算一次**，不在 `build` 里现算；
/// 3. 全选/清空只改 [_selected] 这个 `Set<String>` + 一次 `setState`，
///    绝不逐条 setState。
class BookSourcePickerPage extends StatefulWidget {
  /// 测试注入：书源存储（默认全局单例）。
  final BookSourceStore? store;

  /// 测试注入：索引下载服务（默认真 Dio）。
  final BookSourceIndexService? service;

  const BookSourcePickerPage({super.key, this.store, this.service});

  @override
  State<BookSourcePickerPage> createState() => _BookSourcePickerPageState();
}

class _BookSourcePickerPageState extends State<BookSourcePickerPage> {
  /// 索引链接输入框（默认填 `reader:index_urls` 里已存的那几行）。
  final TextEditingController _urlController = TextEditingController();

  /// 搜索关键词（每敲一个字重算一次 [_visible]；6000 条 contains 是毫秒级）。
  String _query = '';

  /// 只看能直接搜索的源（执行字段里没有 JS）。
  bool _onlySearchable = false;

  /// 只看当前还没导入的源。
  ///
  /// 默认开：重复导入同一个源只是原地覆盖（白费勾选），先藏起已有的更省事。
  /// 附带好处是「已选 N」在默认路径上就等于「真正会新增的数」，底部那句
  /// 「已选 N / 可导入剩余 M」不会自相矛盾。
  bool _onlyNew = true;

  /// 已下载到的全部源（下载前为空）。
  List<BookSource> _sources = const [];

  /// 过滤后的可见源（筛选条件变化时重算，见 [_recompute]）。
  List<BookSource> _visible = const [];

  /// 需要 JS 的源的 key（下载时算好，过滤时只做 Set 查找）。
  ///
  /// 口径 = **执行字段**里有 JS（真跑不了）；只在发现页 / 登录页用了 JS 的
  /// 源在 [_partialJsKeys] 里，它们能直接搜。
  Set<String> _jsKeys = const {};

  /// 只有部分字段用 JS 的源 key（能搜，只标角标）。
  Set<String> _partialJsKeys = const {};

  /// 执行字段里是**静态 JS**（纯字符串变换）的源 key（v2.78.0：能搜）。
  Set<String> _staticJsKeys = const {};

  /// 当前已导入的源 key（「只看没导入的」与剩余额度都靠它）。
  Set<String> _existingKeys = const {};

  /// 勾选中的 key。
  final Set<String> _selected = <String>{};

  /// 下载进度（[BookSourceIndexResult] 的进度回调）。
  int _done = 0;
  int _total = 0;
  bool _downloading = false;

  /// 下载失败的异常文案（服务本身不抛，这里只是兜底）。
  String? _error;

  /// 最近一次下载的结果（汇总行 + 逐条失败原因）。
  BookSourceIndexResult? _result;

  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;
  BookSourceIndexService get _service =>
      widget.service ?? (_defaultService ??= BookSourceIndexService());

  /// 默认服务懒建（测试注入了 fake 时不碰它，省一个 Dio 实例）。
  BookSourceIndexService? _defaultService;

  /// 上限内还能再放几个（已导入的可能已经满额 → 夹到 0）。
  int get _remaining => (BookSourceStore.maxSources - _existingKeys.length)
      .clamp(0, BookSourceStore.maxSources);

  /// 勾选里**会真正新增**的个数。
  ///
  /// 同名覆盖不占新名额（`upsertAll` 是合并），所以额度只看这部分：
  /// 勾了一个已导入的源再勾 200 个新的，也不该被拦住。
  int get _newSelectedCount {
    var count = 0;
    for (final key in _selected) {
      if (!_existingKeys.contains(key)) count++;
    }
    return count;
  }

  bool get _overLimit => _newSelectedCount > _remaining;

  /// 导入进行中（防止连点两次 → pop 两次）。
  bool _importing = false;

  bool get _canImport =>
      !_downloading && !_importing && _selected.isNotEmpty && !_overLimit;

  @override
  void initState() {
    super.initState();
    unawaited(_loadExisting());
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// 读「已导入的源」与「上次存下的索引链接」。
  Future<void> _loadExisting() async {
    var existing = <String>{};
    var urls = <String>[];
    try {
      existing = {for (final s in await _store.getAll()) s.key};
      urls = await _store.getIndexUrls();
    } catch (_) {
      // 读存储失败不该让选择页打不开：退化成「没有已导入的源 + 空链接表」
    }
    if (!mounted) return;
    setState(() {
      _existingKeys = existing;
      if (_urlController.text.trim().isEmpty && urls.isNotEmpty) {
        _urlController.text = urls.join('\n');
      }
      _recompute();
    });
  }

  // ==================== 过滤 / 选择（纯本地，不碰网络） ====================

  /// 重算 [_visible]：**只算，不 setState**（调用方自己决定何时重建）。
  void _recompute() {
    final query = _query.trim().toLowerCase();
    final out = <BookSource>[];
    for (final source in _sources) {
      // 「能直接搜索」= 执行字段里没有 JS；只在发现页 / 登录页用了 JS 的源
      // 照样能搜，所以留在这里（角标另行标注）
      if (_onlySearchable && _jsKeys.contains(source.key)) continue;
      if (_onlyNew && _existingKeys.contains(source.key)) continue;
      if (query.isNotEmpty &&
          !source.name.toLowerCase().contains(query) &&
          !source.baseUrl.toLowerCase().contains(query)) {
        continue;
      }
      out.add(source);
    }
    _visible = out;
  }

  void _refilter() {
    _recompute();
    if (mounted) setState(() {});
  }

  void _toggle(BookSource source, bool on) {
    // 单条勾选：只改集合 + 一次 setState（6000 行里也只重建可见的那几行）
    setState(() {
      if (on) {
        _selected.add(source.key);
      } else {
        _selected.remove(source.key);
      }
    });
  }

  /// 全选**当前可见**的（不是全库 6000 条）：用户先筛出想要的，再一键全勾。
  void _selectAllVisible() {
    setState(() {
      for (final source in _visible) {
        _selected.add(source.key);
      }
    });
  }

  void _clearSelection() {
    setState(_selected.clear);
  }

  // ==================== 下载 ====================

  /// 解析链接输入框：一行一个，去空行、去重，只认 http(s)。
  List<String> _parseUrls(String text) {
    final out = <String>[];
    final seen = <String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!(trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
        continue;
      }
      if (seen.add(trimmed)) out.add(trimmed);
    }
    return out;
  }

  Future<void> _download() async {
    final urls = _parseUrls(_urlController.text);
    if (urls.isEmpty) {
      AppSnack.show(context, '先填至少一个 .json 索引链接（每行一个）');
      return;
    }
    // 写回 store（整份替换）：用户把某行删掉就是不想再下它
    await _store.saveIndexUrls(urls, replace: true);
    if (!mounted) return;
    setState(() {
      _downloading = true;
      _done = 0;
      _total = urls.length;
      _error = null;
    });
    try {
      final result = await _service.fetchIndexes(
        urls: urls,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _result = result;
        _sources = result.sources;
        _jsKeys = {...result.jsKeys};
        _partialJsKeys = {...result.partialJsKeys};
        _staticJsKeys = {...result.staticJsKeys};
        // 换了新的一批源，之前的勾选就作废（key 可能对不上新列表）
        _selected.clear();
        _recompute();
      });
    } catch (e) {
      // 服务承诺不抛，这里只是最后一道：别让页面白屏
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '下载失败：$e';
      });
    }
  }

  // ==================== 导入 ====================

  Future<void> _import() async {
    if (!_canImport) return;
    // 按列表顺序取，保证导入顺序 = 用户在索引里看到的顺序
    final chosen = [
      for (final source in _sources)
        if (_selected.contains(source.key)) source,
    ];
    if (chosen.isEmpty) return;
    setState(() => _importing = true);
    final ok = await _store.upsertAll(chosen);
    if (!mounted) return;
    if (!ok) {
      setState(() => _importing = false);
      AppSnack.show(
        context,
        '导入失败：书源总数超过 ${BookSourceStore.maxSources} 个上限（先删掉一些再导）',
        kind: SnackKind.error,
      );
      return;
    }
    // 把条数交给上一页：由它刷新列表并弹「已导入 N 个」（这一页马上要被
    // 弹掉，在这里弹 SnackBar 会跟着页面一起消失）
    Navigator.of(context).pop(chosen.length);
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('下载索引书源')),
      body: Column(
        children: [
          _linkSection(),
          const Divider(height: 1),
          if (_sources.isNotEmpty) _filterSection(),
          Expanded(child: _listArea()),
          if (_sources.isNotEmpty) _bottomBar(),
        ],
      ),
    );
  }

  /// 顶部：链接输入框 + 下载按钮 + 进度 + 汇总。
  Widget _linkSection() {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, 10, kPagePadH, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  minLines: 1,
                  maxLines: 3,
                  style: kTypeBodyS.copyWith(color: kInkBlack),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '索引链接（每行一个 .json）',
                    hintText: 'https://example.com/sources.json',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: kSpace8),
              FilledButton(
                onPressed: _downloading ? null : _download,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.inkFill,
                  foregroundColor: palette.onInk,
                  minimumSize: const Size(0, 48),
                ),
                child: const Text('下载'),
              ),
            ],
          ),
          if (_downloading) ...[
            const SizedBox(height: kSpace8),
            LinearProgressIndicator(
              value: _total == 0 ? null : _done / _total,
              backgroundColor: kPaperCool,
              color: palette.inkFill,
            ),
            const SizedBox(height: kSpace4),
            Text(
              // 进度回调给的是「已完成数」，正在下的是下一个
              '正在下载 ${_total <= 0 ? 1 : (_done + 1).clamp(1, _total)}/$_total…',
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ],
          if (!_downloading && _result != null) ...[
            const SizedBox(height: kSpace8),
            Text(
              _result!.summary,
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
            // 失败 / 跳过逐条列原因：一行里塞 4 个链接的失败原因读不完
            for (final outcome in _result!.problems)
              Padding(
                padding: const EdgeInsets.only(top: kSpace2),
                child: Text(
                  '· ${_shortUrl(outcome.url)}：${outcome.message}',
                  style: kTypeBodyS.copyWith(
                    color: outcome.isFailed ? kError : kInkGray50,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 搜索 + 筛选 + 全选/清空。
  ///
  /// 筛选开关用 `Wrap`：360dp 窄屏 + 用户把系统字号调大时，宁可换行，
  /// 也不要文字被压成 `…`。
  ///
  /// 「全选 / 清空」不放在那个 `Wrap` 里 —— 它会跟着筛选开关一起排，
  /// 411dp 下总宽 379 装不下三样东西，「清空」被甩到下一行孤立成一行灰字。
  /// 现在给它们单独一行靠右排：两个按钮合计约 100dp，360/411 都稳定单行。
  Widget _filterSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, 8, kPagePadH, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            onChanged: (value) {
              _query = value;
              _refilter();
            },
            style: kTypeBodyS.copyWith(color: kInkBlack),
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: '搜索书名 / 站点地址',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: kSpace4),
          Wrap(
            spacing: kSpace12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _FilterCheck(
                // 文案跟着语义改（I1）：筛选的是「执行字段里没有 JS」的源，
                // 「不需要 JS」会让用户以为连发现页的 JS 都算在内
                label: '只看能直接搜索的',
                value: _onlySearchable,
                onChanged: (v) {
                  setState(() {
                    _onlySearchable = v;
                    _recompute();
                  });
                },
              ),
              _FilterCheck(
                label: '只看当前没导入的',
                value: _onlyNew,
                onChanged: (v) {
                  setState(() {
                    _onlyNew = v;
                    _recompute();
                  });
                },
              ),
            ],
          ),
          Row(
            // 靠右，跟「导入」按钮同侧；两个按钮自己缩到最小（字号 kTypeBodyS
            // + 横向 8 的内边距），一行放得下且不靠图标 —— 用户要靠文字认功能。
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _visible.isEmpty ? null : _selectAllVisible,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                  textStyle: kTypeBodyS,
                ),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: _selected.isEmpty ? null : _clearSelection,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                  textStyle: kTypeBodyS,
                ),
                child: const Text('清空'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _listArea() {
    if (_error != null) {
      return AppErrorView(
        message: _error,
        onRetry: _download,
        illustrationSeed: 'booksource',
      );
    }
    if (_downloading && _sources.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.loading,
        title: '正在下载索引…',
        illustrationSeed: 'booksource',
      );
    }
    if (_sources.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '还没有下载索引',
        subtitle: '确认上面的索引链接，然后点「下载」',
        illustrationSeed: 'booksource',
      );
    }
    if (_visible.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '没有符合条件的书源',
        subtitle: '换个关键词，或取消筛选条件',
        illustrationSeed: 'booksource',
      );
    }
    // 6000+ 条一律懒建（`ListView.builder` 只构建可见的十来行）
    return ListView.builder(
      itemCount: _visible.length,
      itemBuilder: (context, index) => _row(_visible[index]),
    );
  }

  /// 右侧角标：需 JS（红）/ 静态 JS（accent）/ 部分 JS（accent）/ 已导入（灰）。
  ///
  /// 四档分开是 v2.78.0 的重点：`需 JS` 是**本版跑不了**，`静态 JS` 与
  /// `部分 JS` 都是**能搜**（一个脚本能跑、一个脚本在不执行的字段里）。
  /// 合成一句会让人白跳过一堆其实好用的源。
  Widget? _jsBadge({
    required bool needsJs,
    required bool staticJs,
    required bool partialJs,
    required bool imported,
  }) {
    final (label, color) = needsJs
        ? ('需 JS', kError)
        : staticJs
            ? ('静态 JS', context.palette.accent)
            : partialJs
                ? ('部分 JS', context.palette.accent)
                : imported
                    ? ('已导入', kInkGray50)
                    : ('', kInkGray50);
    if (label.isEmpty) return null;
    return Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: kTypeBodyS.copyWith(color: color),
    );
  }

  Widget _row(BookSource source) {
    final needsJs = _jsKeys.contains(source.key);
    final staticJs = !needsJs && _staticJsKeys.contains(source.key);
    final partialJs =
        !needsJs && !staticJs && _partialJsKeys.contains(source.key);
    final imported = _existingKeys.contains(source.key);
    // 名字/地址在模型层已按单行清洗过（BookSource.fromJson），这里的
    // `maxLines + ellipsis + softWrap: false` 是第二道护栏：万一某条数据
    // 绕过模型（或将来有人手搓 BookSource），也不会画出两行叠字。
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: _selected.contains(source.key),
      onChanged: (value) => _toggle(source, value ?? false),
      title: Text(
        source.name,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: kTypeBody.copyWith(color: kInkBlack),
      ),
      subtitle: Text(
        source.baseUrl,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: kTypeBodyS.copyWith(color: kInkGray50),
      ),
      // 角标让「为什么这个源被藏起来了 / 为什么导进去也搜不到」一眼可查。
      // 两个角标必须分开：`需 JS` 是执行字段里有 JS（导入也搜不到），
      // `部分 JS` 只是发现页 / 登录页那些本版没有的能力，**能搜**。
      secondary: _jsBadge(
        needsJs: needsJs,
        staticJs: staticJs,
        partialJs: partialJs,
        imported: imported,
      ),
    );
  }

  /// 底部：额度 + 导入按钮。
  ///
  /// 这里自己吃 `viewPadding.bottom`：它是整页最后一个元素，不加就会在
  /// edge-to-edge 下被系统导航栏压住（列表在它上面，所以列表不必再让位）。
  Widget _bottomBar() {
    final palette = context.palette;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        color: kPaperRaised,
        border: Border(top: BorderSide(color: kRule)),
      ),
      padding: EdgeInsets.fromLTRB(
        kPagePadH,
        kSpace8,
        kPagePadH,
        kSpace8 + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_overLimit)
            Padding(
              padding: const EdgeInsets.only(bottom: kSpace4),
              child: Text(
                '书源上限 ${BookSourceStore.maxSources} 个，请少选一些或先删掉旧的',
                style: kTypeBodyS.copyWith(color: kError),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '已选 ${_selected.length} / 可导入剩余 $_remaining',
                  style: kTypeBodyS.copyWith(color: kInkGray70),
                ),
              ),
              FilledButton(
                onPressed: _canImport ? _import : null,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.inkFill,
                  foregroundColor: palette.onInk,
                  minimumSize: const Size(88, 44),
                ),
                child: const Text('导入'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 汇总行里的链接只留最后一段路径（完整 URL 太长，一屏放不下）。
  String _shortUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return url;
    return uri.pathSegments.last;
  }
}

/// 一个「勾选框 + 文字」的筛选开关（整行可点，不必瞄准那个小方块）。
class _FilterCheck extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _FilterCheck({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(kRadiusSm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          Text(label, style: kTypeBodyS.copyWith(color: kInkBlack)),
        ],
      ),
    );
  }
}
