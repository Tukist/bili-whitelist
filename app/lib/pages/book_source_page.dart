import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_rule/example_sources.dart';
import '../services/book_rule/legado_compat.dart';
import '../services/book_source_health_service.dart';
import '../services/book_source_index_service.dart';
import '../services/book_source_store.dart';
import '../services/file_import_service.dart';
import '../theme/app_palette.dart';
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
/// 逐条启用开关、删除（二次确认）、清空全部、长按看原始 JSON、
/// **一键添加内置书源**、**单源 / 全量可用性检测**（F2，见
/// `book_source_health_service.dart`）。
/// 不能：在这里执行搜索/正文规则（那些在阅读侧）。
///
/// ## 为什么删源要二次确认
/// 书源是用户从别处抄来、可能一行行手改过的数据，没有云端备份（本存储
/// 不进 Gist，理由见 [BookSourceStore] 类注释）。误删就是永久丢。
class BookSourcePage extends StatefulWidget {
  /// 测试注入：书源存储（默认用全局单例 [BookSourceStore.instance]）。
  final BookSourceStore? store;

  /// 测试注入：索引下载服务（透传给选择页；默认真 Dio）。
  final BookSourceIndexService? indexService;

  /// 测试注入：规则引擎宿主（默认 [RuleEngineHolder.instance]）。
  ///
  /// 只有「检测」需要引擎（要在真实 DOM 上跑选择器）；不检测就不碰它。
  final RuleEngineHolder? holder;

  /// 测试注入：可用性检测服务（默认用 [holder] 的引擎现建一个）。
  final BookSourceHealthService? healthService;

  const BookSourcePage({
    super.key,
    this.store,
    this.indexService,
    this.holder,
    this.healthService,
  });

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  /// null = 加载中。
  List<BookSource>? _sources;

  /// 读盘失败的原因（非 null 且 [_sources] 为 null 时展示错误态）。
  String? _error;

  /// 检测结果（源名小写 → 结果）。没检测过的源不在表里。
  Map<String, SourceHealth> _health = const {};

  /// 是否已经把隐藏的 WebView 宿主挂进树（**用到才建**：见 [_ensureEngineMounted]）。
  bool _engineMounted = false;

  /// 正在检测的源名（小写）；null = 没有单源检测在跑。
  String? _probingKey;

  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;
  RuleEngineHolder get _holder => widget.holder ?? RuleEngineHolder.instance;

  /// 检测服务：**懒建**，构造时不碰引擎（读角标只需要 prefs）。
  late final BookSourceHealthService _healthService =
      widget.healthService ??
          BookSourceHealthService(engineProvider: () => _holder.engine);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadHealth());
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

  Future<void> _loadHealth() async {
    final map = await _healthService.loadAll();
    if (!mounted) return;
    setState(() => _health = map);
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

  // ==================== 内置书源 ====================

  /// 一键添加内置书源（规则见 `services/book_rule/example_sources.dart`）。
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
      AppSnack.show(context, '内置书源已存在');
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
    // 有同名源被跳过时说清楚：用户可能自己改过那条，不该以为「没导进来」
    final skipped = kExampleBookSources.length - added.length;
    AppSnack.show(
      context,
      '已添加 ${added.length} 个内置书源'
      '${skipped > 0 ? '（$skipped 个同名源已存在，没有覆盖）' : ''}',
    );
  }

  // ==================== 可用性检测（F2） ====================

  /// 检测前把隐藏的 WebView 宿主挂进树。
  ///
  /// **用到才挂**：这一页平时只是在读写书源，为了看一眼角标就建一个 WebView
  /// 太亏；而且 `flutter test` 里没有 WebView 平台实现，页面一打开就挂宿主会
  /// 让所有管理页测试直接抛。挂上之后等一帧再求值：WebView 要先完成布局，
  /// 否则 `loadHtmlString` 的回调不会来（见 DEV_CONTEXT 的「尺寸不能为 0」）。
  Future<void> _ensureEngineMounted() async {
    if (_engineMounted) return;
    setState(() => _engineMounted = true);
    await WidgetsBinding.instance.endOfFrame;
  }

  /// 检测一个源（长按菜单「检测这个源」）。
  Future<void> _probeOne(BookSource source) async {
    if (_probingKey != null) return; // 已经在测别的源，别叠着打
    setState(() => _probingKey = source.key);
    try {
      await _ensureEngineMounted();
      final health = await _healthService.probe(source);
      if (!mounted) return;
      await _loadHealth();
      if (!mounted) return;
      AppSnack.show(context, '「${source.name}」${health.describe}');
    } finally {
      if (mounted) setState(() => _probingKey = null);
    }
  }

  /// 检测全部书源（AppBar 溢出菜单，**较慢**）。
  ///
  /// 只测「启用 且 不需要 JS」的：停用的源用户已经不想用了，需要 JS 的本版
  /// 根本跑不了（发请求也只会得空结果）。跳过的数量写在进度框里，不假装
  /// 「全测完了」。
  Future<void> _probeAll() async {
    final all = _sources ?? const <BookSource>[];
    final targets = [
      for (final s in all)
        if (s.enabled && !usesJs(s)) s,
    ];
    final disabled = all.where((s) => !s.enabled).length;
    final jsOnly = all.where((s) => s.enabled && usesJs(s)).length;
    if (targets.isEmpty) {
      AppSnack.show(
        context,
        '没有可检测的源（停用 $disabled 个、需 JS $jsOnly 个，都已跳过）',
      );
      return;
    }

    final progress = ValueNotifier<(int, int)>((0, targets.length));
    var cancelled = false;
    var dialogOpen = true;
    void closeDialog() {
      if (!dialogOpen) return;
      dialogOpen = false;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在检测书源'),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: value.$2 == 0 ? null : value.$1 / value.$2,
              ),
              const SizedBox(height: kSpace12),
              Text('已检测 ${value.$1} / ${value.$2}'),
              const SizedBox(height: kSpace4),
              Text(
                '停用 $disabled 个、需 JS $jsOnly 个，不在本次检测范围',
                style: kTypeBodyS.copyWith(color: kInkGray50),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              dialogOpen = false;
              Navigator.of(ctx).pop();
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );
    // 用户也可能是按系统返回键把对话框关掉的（barrierDismissible 只挡点击）。
    // 用 future 完成来回收「对话框还开着吗」，否则后面 closeDialog() 会误把
    // 书源页自己也 pop 掉。
    dialogFuture.whenComplete(() => dialogOpen = false);

    List<SourceHealth> results;
    try {
      await _ensureEngineMounted();
      results = await _healthService.probeAll(
        targets,
        onProgress: (done, total) => progress.value = (done, total),
        isCancelled: () => cancelled,
      );
    } finally {
      closeDialog();
      progress.dispose();
    }
    if (!mounted) return;
    await _loadHealth();
    if (!mounted) return;

    final counts = <SourceHealthStatus, int>{};
    for (final h in results) {
      counts[h.status] = (counts[h.status] ?? 0) + 1;
    }
    final parts = [
      for (final status in SourceHealthStatus.values)
        if ((counts[status] ?? 0) > 0) '${status.label} ${counts[status]}',
    ];
    final tail = cancelled
        ? '（已取消，测了 ${results.length} / ${targets.length} 个）'
        : '';
    AppSnack.show(context, '检测完成：${parts.join('、')}$tail');
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
    // 书源没了，检测结果也要跟着清 —— 否则下次导入同名源时会带着一条
    // 别人的旧状态显示出来（「刚导进来就显示被拦」最容易被当成 bug）。
    await _healthService.clear();
    if (!mounted) return;
    await _loadHealth();
    if (!mounted) return;
    AppSnack.show(context, '已清空 $count 个书源');
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        // 溢出菜单：都不占主位。导入才是这一页的主要动作，这四项分别是
        // 「批量找源」「先试一下」「测一下能不能用」「推倒重来」。
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'index') unawaited(_openIndexPicker());
              if (value == 'examples') unawaited(_addExamples());
              if (value == 'probe_all') unawaited(_probeAll());
              if (value == 'clear') unawaited(_clearAll());
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'index',
                child: Text('下载索引书源…'),
              ),
              PopupMenuItem<String>(
                value: 'examples',
                child: Text('添加内置书源'),
              ),
              PopupMenuItem<String>(
                value: 'probe_all',
                child: Text('检测全部书源（较慢）'),
              ),
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('清空书源'),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _actionBar(),
              const Divider(height: 1),
              Expanded(child: _body()),
            ],
          ),
          // 隐藏的 WebView 宿主：只在开始检测后才挂（见 _ensureEngineMounted）
          if (_engineMounted)
            Positioned(left: 0, top: 0, child: _hiddenHost()),
        ],
      ),
    );
  }

  Widget _hiddenHost() => SizedBox(
        width: 1,
        height: 1,
        child: Offstage(offstage: true, child: _holder.buildHost()),
      );

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
    final probing = _probingKey == source.key;
    return ListTile(
      // 长按 = 小菜单（看原始 JSON / 检测这个源）。原来长按直接弹 JSON，
      // F2 起多了一个动作，用菜单比再塞一个图标按钮稳妥（窄屏 trailing 已满）。
      onLongPress: () => _showSourceActions(source),
      title: Row(
        children: [
          Expanded(
            child: Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                // 停用的源压暗：一眼能看出它不是搜索范围
                color: source.enabled ? null : theme.colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(width: kSpace8),
          _healthBadge(source, probing: probing),
        ],
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
          // 声明的编码：只占一行小字（「自动」也是信息 —— 说明这个源没写死，
          // 抓取时按字节自动判定）。为什么不并进上面那行：既有的行文案
          // （`v1.2` / baseUrl）是可断言的稳定契约，别为了省一行去拼字符串。
          Text(
            '编码：${source.charsetLabel}',
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

  /// 状态角标：绿「可用 N 条」/ 灰「没结果」/ 红「被拦」/ 黄「需 JS」/ 灰「未检测」。
  ///
  /// 颜色只用主题里的语义色（[kSuccess] / [kError] / [kInkGray50] / accent），
  /// 不写字面量 —— 换配色配方时角标会自己跟着变。
  Widget _healthBadge(BookSource source, {required bool probing}) {
    final palette = context.palette;
    final health = _health[source.key];
    if (probing) {
      return Text(
        '检测中…',
        style: kTypeBodyS.copyWith(color: kInkGray50, fontSize: 11),
      );
    }
    final (label, color) = switch (health?.status) {
      null => ('未检测', kInkGray50),
      SourceHealthStatus.ok => (health!.label, kSuccess),
      SourceHealthStatus.noResult => ('没结果', kInkGray70),
      SourceHealthStatus.blocked => ('被拦', kError),
      SourceHealthStatus.networkError => ('连不上', kError),
      SourceHealthStatus.unsupportedJs => ('需 JS', palette.accent),
      SourceHealthStatus.badRule => ('规则坏', palette.accent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(color: color.withValues(alpha: .45)),
        color: color.withValues(alpha: .08),
      ),
      child: Text(
        label,
        style: kTypeBodyS.copyWith(color: color, fontSize: 11),
      ),
    );
  }

  /// 长按菜单：看原始 JSON / 检测这个源。
  Future<void> _showSourceActions(BookSource source) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace12, kPagePadH, kSpace4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kTypeTitleS.copyWith(color: kInkBlack),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('查看原始 JSON'),
              onTap: () => Navigator.of(ctx).pop('raw'),
            ),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: const Text('检测这个源'),
              subtitle: const Text('真发一次搜索，看能不能搜到书'),
              onTap: () => Navigator.of(ctx).pop('probe'),
            ),
            const SizedBox(height: kSpace8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'raw') _showRaw(source);
    if (action == 'probe') await _probeOne(source);
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
