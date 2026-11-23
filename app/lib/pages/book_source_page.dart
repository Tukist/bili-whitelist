import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_rule/example_sources.dart';
import '../services/book_source_index_service.dart';
import '../services/book_source_store.dart';
import '../services/file_import_service.dart';
import '../theme/app_tokens.dart';
import '../utils/book_source_import.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import 'book_source_picker_page.dart';

/// 书源管理页（R1 新增）：全屏路由，AppBar 标题「书源」。
///
/// ## 这一版能做什么 / 不能做什么
/// 能：**从剪贴板 / 本地文件 / 链接导入**（支持单对象 / 数组 / 混着说明文字 /
/// legado 格式；三条入口共用同一个 `parseBookSourceText`）、
/// **从索引链接批量下载后挑选导入**（R3，见 `book_source_picker_page.dart`）、
/// 逐条启用开关、删除（二次确认）、清空全部、长按看原始 JSON。
/// 不能：**执行书源规则**（搜索/详情/目录/正文在 R2/R3 的阅读侧，本页只管
/// 书源的进与出）。
///
/// ## 为什么删源要二次确认
/// 书源是用户从别处抄来、可能一行行手改过的数据，没有云端备份（本存储
/// 不进 Gist，理由见 [BookSourceStore] 类注释）。误删就是永久丢。
class BookSourcePage extends StatefulWidget {
  /// 测试注入：书源存储（默认用全局单例 [BookSourceStore.instance]）。
  final BookSourceStore? store;

  /// 测试注入：索引下载服务（透传给选择页；默认真 Dio）。
  final BookSourceIndexService? indexService;

  const BookSourcePage({super.key, this.store, this.indexService});

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  /// null = 加载中。
  List<BookSource>? _sources;

  /// 读盘失败的原因（非 null 且 [_sources] 为 null 时展示错误态）。
  String? _error;

  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await _store.getAll();
      if (!mounted) return;
      setState(() => _sources = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取书源失败：$e');
    }
  }

  // ==================== 导入 ====================

  /// 从剪贴板导入：读文本 → 纯函数解析 → 合并入库 → 一条提示说清结果。
  Future<void> _importFromClipboard() async {
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (e) {
      // 剪贴板读取在部分平台会抛（无剪贴板服务 / 权限）
      if (!mounted) return;
      AppSnack.show(context, '读取剪贴板失败：$e', kind: SnackKind.error);
      return;
    }
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      AppSnack.show(context, '剪贴板是空的，先复制书源 JSON');
      return;
    }
    await _applyImport(parseBookSourceText(text));
  }

  /// 从本地文件导入（v2.70.0）：系统文件选择器挑 .json / .txt。
  ///
  /// 解析走的是**同一个** [parseBookSourceText]（剪贴板 / 链接 / 文件三条路
  /// 共用一套口径，绝不写第二套解析器 —— 否则三种入口对同一个文件会给出不同
  /// 结果，用户根本没法自查）。
  Future<void> _importFromFile() async {
    final result = await const FileImportService().pickTextFile();
    if (!mounted) return;
    // 取消（按返回键 / 点空白）不是错误：什么都不做，也不改任何东西
    if (result.isCancelled) return;
    final error = result.error;
    if (error != null) {
      AppSnack.show(context, error, kind: SnackKind.error);
      return;
    }
    final file = result.file!;
    if (file.isBlank) {
      AppSnack.show(
        context,
        '「${file.name}」是空的，没有可导入的内容',
        kind: SnackKind.error,
      );
      return;
    }
    await _applyImport(parseBookSourceText(file.content), fileName: file.name);
  }

  /// 从链接导入：对话框里贴 URL（或直接贴 JSON）。
  ///
  /// 两条路都真的能用：
  /// - 贴进来的其实是 JSON → 当场导入；
  /// - 贴进来是索引链接（每行一个 .json）→ 存到
  ///   [BookSourceStore.saveIndexUrls]，并告诉用户去哪儿下载
  ///   （右上角「下载索引书源」，见 `book_source_picker_page.dart`）。
  Future<void> _importFromUrl() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _UrlImportDialog(),
    );
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) return;
    await _applyImport(parseBookSourceText(text));
  }

  /// 统一的落库 + 提示（剪贴板 / 文件 / 链接三条路共用，保证口径一致）。
  ///
  /// [fileName] 非空 = 来自本地文件：提示里带上文件名，并额外说明「跳过几个」
  /// —— 用户看着一份文件导入，最想知道的正是「这份文件里几个能用」。
  Future<void> _applyImport(
    BookSourceImportResult result, {
    String? fileName,
  }) async {
    if (!mounted) return;

    // 只有索引链接（没有可解析的书源）：记下来，并指路去下载
    if (result.sources.isEmpty) {
      if (result.indexUrls.isNotEmpty) {
        await _store.saveIndexUrls(result.indexUrls);
        if (!mounted) return;
        AppSnack.show(
          context,
          '已记录 ${result.indexUrls.length} 个索引链接，'
          '可在右上角「下载索引书源」里下载',
        );
        return;
      }
      // 什么都没有：把解析器给的人话原因念给用户
      final reason = result.errors.isEmpty ? '没有识别到书源 JSON' : result.errors.first;
      AppSnack.show(context, reason, kind: SnackKind.error);
      return;
    }

    final ok = await _store.upsertAll(result.sources);
    if (!mounted) return;
    if (!ok) {
      AppSnack.show(
        context,
        '导入失败：书源总数超过 ${BookSourceStore.maxSources} 个上限（先删掉一些再导）',
        kind: SnackKind.error,
      );
      return;
    }
    // 顺手把可能夹带的索引链接存起来（一个粘贴里既有直接书源又有索引链接的情况）
    if (result.indexUrls.isNotEmpty) {
      await _store.saveIndexUrls(result.indexUrls);
    }
    await _load();
    if (!mounted) return;
    final extra = result.errors.isEmpty ? '' : '（${result.errors.first}）';
    final urlNote =
        result.indexUrls.isEmpty ? '' : '；${result.indexUrls.length} 个索引链接已记录';
    if (fileName != null) {
      // 文件导入的说法更具体：几个能用 / 几个被跳过（跳过的原因给第一条，
      // 全列出来会是一屏长度的 SnackBar，用户也读不完）
      final skipped = result.errors.length;
      AppSnack.show(
        context,
        '已从「$fileName」导入 ${result.sources.length} 个书源'
        '${skipped == 0 ? '' : '（跳过 $skipped 个：${result.errors.first}）'}$urlNote',
      );
      return;
    }
    AppSnack.show(
      context,
      '已导入 ${result.sources.length} 个书源$extra$urlNote',
    );
  }

  // ==================== 行内动作 ====================

  Future<void> _toggle(BookSource source, bool enabled) async {
    // 先改本地副本让开关立刻响应（prefs 写入很快，但等待会闪一下）
    setState(() {
      _sources = [
        for (final s in _sources ?? const <BookSource>[])
          if (s.key == source.key) s.copyWith(enabled: enabled) else s,
      ];
    });
    final ok = await _store.setEnabled(source.name, enabled);
    if (!mounted) return;
    if (!ok) {
      // 写盘失败 → 回滚 UI，别让开关显示一个没生效的值
      await _load();
      if (!mounted) return;
      AppSnack.show(context, '保存失败，开关已还原', kind: SnackKind.error);
    }
  }

  Future<void> _remove(BookSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源'),
        content: Text('确定删除「${source.name}」吗？删除后只能重新导入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _store.remove(source.name);
    if (!mounted) return;
    if (!ok) {
      AppSnack.show(context, '删除失败，书源仍在', kind: SnackKind.error);
      return;
    }
    await _load();
    if (!mounted) return;
    AppSnack.show(context, '已删除「${source.name}」');
  }

  /// 长按看原始 JSON（只读弹层）。
  ///
  /// 展示的是**存进本机的完整结构**（含 legado 的 [BookSource.raw]），
  /// 用户能自己确认「导进来的字段有没有丢」，也是往别处迁移时的导出源。
  void _showRaw(BookSource source) {
    final pretty = const JsonEncoder.withIndent('  ').convert(source.toJson());
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(source.name),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              pretty,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ==================== 内置示例书源 ====================

  /// 一键添加内置示例书源（规则见 `services/book_rule/example_sources.dart`）。
  ///
  /// 只写**还不在列表里**的那几条：`upsertAll` 是同名覆盖，直接整批塞进去会
  /// 把用户改过的同源规则冲掉。同名判定与存储一致（[BookSource.key]，大小写
  /// 不敏感）。一条都没新增时明说「已存在」，不做假成功。
  Future<void> _addExamples() async {
    final current = await _store.getAll();
    if (!mounted) return;
    final existing = {for (final s in current) s.key};
    final added = [
      for (final s in kExampleBookSources)
        if (!existing.contains(s.key)) s,
    ];
    if (added.isEmpty) {
      AppSnack.show(context, '示例书源已存在');
      return;
    }
    final ok = await _store.upsertAll(added);
    if (!mounted) return;
    if (!ok) {
      AppSnack.show(
        context,
        '添加失败：书源总数超过 ${BookSourceStore.maxSources} 个上限（先删掉一些再加）',
        kind: SnackKind.error,
      );
      return;
    }
    await _load();
    if (!mounted) return;
    AppSnack.show(context, '已添加 ${added.length} 个示例书源');
  }

  // ==================== 索引下载 / 清空（R3） ====================

  /// 打开「下载索引书源」选择页（挑完导入后由它 pop 回导入条数）。
  ///
  /// 为什么不在本页原地做全套：索引里常有 6000 个源，需要搜索/筛选/勾选/
  /// 额度提示一整套 UI，塞进这一页会把「导入入口 + 列表」挤没。选择页全屏，
  /// 这里只负责刷新列表 + 一句「已导入 N 个」。
  Future<void> _openIndexPicker() async {
    final imported = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => BookSourcePickerPage(
          store: _store,
          service: widget.indexService,
        ),
      ),
    );
    if (!mounted) return;
    if (imported == null || imported <= 0) return;
    await _load();
    if (!mounted) return;
    AppSnack.show(context, '已导入 $imported 个书源');
  }

  /// 清空全部书源（**必须二次确认**：本地没有备份，删了只能重新导）。
  Future<void> _clearAll() async {
    final count = _sources?.length ?? 0;
    if (count == 0) {
      AppSnack.show(context, '当前没有书源');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空书源'),
        content: Text('确定删除全部 $count 个书源吗？删除后只能重新导入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _store.clear();
    if (!mounted) return;
    if (!ok) {
      AppSnack.show(context, '清空失败，书源仍在', kind: SnackKind.error);
      return;
    }
    await _load();
    if (!mounted) return;
    AppSnack.show(context, '已清空 $count 个书源');
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        // 溢出菜单：都不占主位。导入才是这一页的主要动作，这三项分别是
        // 「批量找源」「先试一下」「推倒重来」。
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'index') unawaited(_openIndexPicker());
              if (value == 'examples') unawaited(_addExamples());
              if (value == 'clear') unawaited(_clearAll());
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'index',
                child: Text('下载索引书源…'),
              ),
              PopupMenuItem<String>(
                value: 'examples',
                child: Text('添加示例书源'),
              ),
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空书源'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _actionBar(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 三个导入入口：剪贴板 / 本地文件 / 链接。
  ///
  /// ## 为什么是「纯文字 + Wrap」而不是三个带图标的 Row
  /// 360dp 窄屏减去左右各 [kSectionPadH] 的边距只剩 312dp 左右；带图标的
  /// `OutlinedButton.icon` 每个要 120dp 上下（图标 18 + 间距 8 + 6 个汉字 84
  /// + 内边距），三个一行必然溢出成黄黑条。纯文字按钮每个 ~90~100dp，三个
  /// 正好放得下；`Wrap` 是给「用户把系统字号调大」留的兜底 —— 那时宁可换行，
  /// 也不要文字被截断或压成 `…`。
  Widget _actionBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSectionPadH, 10, kSectionPadH, 10),
      child: Wrap(
        spacing: kSpace8,
        runSpacing: kSpace8,
        children: [
          _importButton('从剪贴板导入', _importFromClipboard),
          _importButton('从文件导入', _importFromFile),
          _importButton('从链接导入', _importFromUrl),
        ],
      ),
    );
  }

  Widget _importButton(String label, Future<void> Function() onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        // 触摸目标高度仍按 40 + 系统的 tapTargetSize 撑到 48dp；
        // 左右内边距压到 8 是「三个按钮挤进 312dp」的唯一来源：
        // 「从剪贴板导入」84dp 文字 + 16dp 内边距 = 100dp，三个加两处间距 ≈ 297dp。
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label, maxLines: 1, softWrap: false),
    );
  }

  Widget _body() {
    if (_error != null) {
      return AppErrorView(
        message: _error,
        onRetry: _load,
        illustrationSeed: 'booksource',
        scrollable: true,
      );
    }
    final sources = _sources;
    if (sources == null) {
      return const AppStateView(
        kind: AppStateKind.loading,
        title: '正在读取书源…',
        illustrationSeed: 'booksource',
      );
    }
    if (sources.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '还没有书源',
        subtitle: '粘贴 legado 格式的书源 JSON 导入',
        illustrationSeed: 'booksource',
      );
    }
    return ListView.separated(
      itemCount: sources.length,
      // 这一页没有底部导航栏，body 直接顶到屏幕最底：edge-to-edge 下最后一行
      // 会压在系统导航栏下面，而且**滚到底也露不出来**（滚动范围已到尽头）。
      // 补上导航栏高度，最后一行才真的看得见。
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom,
      ),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _sourceTile(sources[i]),
    );
  }

  Widget _sourceTile(BookSource source) {
    final theme = Theme.of(context);
    return ListTile(
      // 长按 = 看原始 JSON（导出 / 核对字段都靠它）
      onLongPress: () => _showRaw(source),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          // 停用的源压暗：一眼能看出它不是搜索范围
          color: source.enabled ? null : theme.colorScheme.outline,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            source.baseUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (source.version.isNotEmpty)
            Text(
              'v${source.version}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: source.enabled,
            onChanged: (v) => _toggle(source, v),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => _remove(source),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

/// 「从链接导入」对话框（独立 StatefulWidget 的原因：TextField 的
/// [TextEditingController] 必须活得跟对话框一样久 —— 在 `showDialog` 的
/// `await` 之后立刻 dispose，退场动画那一帧还会重建 TextField，直接抛
/// 「A TextEditingController was used after being disposed」。让对话框自己
/// 持有并在 [dispose] 里释放，生命周期就对齐了）。
class _UrlImportDialog extends StatefulWidget {
  const _UrlImportDialog();

  @override
  State<_UrlImportDialog> createState() => _UrlImportDialogState();
}

class _UrlImportDialogState extends State<_UrlImportDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('从链接导入'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('粘贴书源 JSON 地址，或直接把 JSON 内容贴进来。'),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'https://example.com/bookSource.json',
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '说明：也可以每行贴一个 .json 索引地址，先记下来，'
            '再到右上角「下载索引书源」里下载挑选。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('导入'),
        ),
      ],
    );
  }
}
