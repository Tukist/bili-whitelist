import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_rule/example_sources.dart';
import '../services/book_source_store.dart';
import '../theme/app_tokens.dart';
import '../utils/book_source_import.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';

/// 书源管理页（R1 新增）：全屏路由，AppBar 标题「书源」。
///
/// ## 这一版能做什么 / 不能做什么
/// 能：**从剪贴板导入**（支持单对象 / 数组 / 混着说明文字 / legado 格式）、
/// 逐条启用开关、删除（二次确认）、长按看原始 JSON。
/// 不能：**网络下载**。所以「从链接导入」在识别到索引链接时只做
/// 「记下来并明确告知后续版本启用」—— 不做假成功（弹一句「导入成功」
/// 却什么都没发生，比明说没做完糟糕得多）。
///
/// ## 为什么删源要二次确认
/// 书源是用户从别处抄来、可能一行行手改过的数据，没有云端备份（本存储
/// 不进 Gist，理由见 [BookSourceStore] 类注释）。误删就是永久丢。
class BookSourcePage extends StatefulWidget {
  /// 测试注入：书源存储（默认用全局单例 [BookSourceStore.instance]）。
  final BookSourceStore? store;

  const BookSourcePage({super.key, this.store});

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

  /// 从链接导入：对话框里贴 URL（或直接贴 JSON）。
  ///
  /// R1 没有网络层，所以两条路只能走一条真的：
  /// - 贴进来的其实是 JSON → 当场导入（这条真能用）；
  /// - 贴进来是索引链接 → 存到 [BookSourceStore.saveIndexUrls]，并明说
  ///   「链接下载将在后续版本启用」。**不假装已导入**。
  Future<void> _importFromUrl() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _UrlImportDialog(),
    );
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) return;
    await _applyImport(parseBookSourceText(text));
  }

  /// 统一的落库 + 提示（剪贴板与链接两条路共用，保证口径一致）。
  Future<void> _applyImport(BookSourceImportResult result) async {
    if (!mounted) return;

    // 只有索引链接（没有可解析的书源）：记下来，明说本版不下载
    if (result.sources.isEmpty) {
      if (result.indexUrls.isNotEmpty) {
        await _store.saveIndexUrls(result.indexUrls);
        if (!mounted) return;
        AppSnack.show(
          context,
          '已记录 ${result.indexUrls.length} 个索引链接，'
          '链接下载将在后续版本启用',
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

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        // 示例源不占主位：导入才是这一页的主要动作，示例只是「先试一下」的
        // 顺手入口，塞进溢出菜单里不跟两个导入按钮抢视觉。
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'examples') unawaited(_addExamples());
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'examples',
                child: Text('添加示例书源'),
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

  Widget _actionBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSectionPadH, 10, kSectionPadH, 10),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _importFromClipboard,
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text('从剪贴板导入'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _importFromUrl,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('从链接导入'),
            ),
          ),
        ],
      ),
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
            '说明：链接下载将在后续版本启用，本版会先把链接记下来。',
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
