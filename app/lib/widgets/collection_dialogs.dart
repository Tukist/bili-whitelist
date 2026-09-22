/// 合集管理相关的公共弹层（首页 + 合集页共用，v2.30.0 嵌套语义）。
///
/// 抽成公共模块的理由：嵌套之后两个页面都要同一套「新建 / 重命名 / 删除 /
/// 移动到…」弹层，而这些弹层的**文案就是语义本身**（「移动到下面、不删源合集」
/// 与旧的「并入并删除源合集」是完全相反的两件事）。只留一处真相，才不会出现
/// 首页已经改对、合集页还写着旧文案的情况。
/// v2.38.0 加的「编辑封面与简介」同理：首页管理面板与子合集卡左滑用的是同一个
/// 对话框。
/// v2.50.0 起这个对话框还能**从相册选本机封面**（预览 + 选图 + 移除，见
/// [showEditCollectionMetaDialog]）：入口也随之补齐到「首页一级合集卡左滑」与
/// 「合集页 AppBar」，任何层级的合集都能就地改自己的封面简介（此前顶层合集在
/// 合集页里无处可改，只能在首页管理面板里绕）。
///
/// 合集名的展示统一走 [collectionDisplay]（`甲/乙` → `甲 / 乙`）：顶层合集没有
/// `/`，展示出来与原样完全一致（既有测试锚点不受影响）；子合集带全路径，
/// 才看得出自己到底在哪一层。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/whitelist_video.dart';
import '../services/image_pick_service.dart';
import '../theme/app_tokens.dart';

/// 新建合集 / 新建子合集输入框：返回用户输入的名字（null = 取消）。
///
/// [parentPath] 非空 = 在它下面建子合集（标题 / 输入框标签换成「子」的说法）。
/// 只负责收名字，校验与落库交给调用方（模型层的 [createSubCollection]）。
Future<String?> showCreateCollectionDialog(
  BuildContext context, {
  String parentPath = '',
}) async {
  final ctrl = TextEditingController();
  final isSub = normalizeCollectionPath(parentPath).isNotEmpty;
  final name = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text(isSub ? '新建子合集' : '新建合集'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: isSub ? '子合集名称' : '合集名称',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (v) => Navigator.pop(dialogCtx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, ctrl.text),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  return name;
}

/// 重命名对话框：返回新名（null = 取消）。
///
/// [path] 是完整路径，但输入框预填**最后一段**——层级由「移动到…」负责，
/// 重命名只管当前这一层的名字。标题里显示全路径，免得在深层页面里改错合集。
Future<String?> showRenameCollectionDialog(
  BuildContext context,
  String path,
) async {
  final display = collectionDisplay(path);
  final ctrl = TextEditingController(text: collectionLocalName(path));
  final newName = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text('重命名合集「$display」'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '新合集名称',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (v) => Navigator.pop(dialogCtx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, ctrl.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  return newName;
}

/// 删除确认对话框：返回 true = 用户确认（null = 取消/点外部关掉）。
///
/// 文案按嵌套语义补齐（v2.30.0）：视频数那句保持原文（既有锚点），
/// [childCount] > 0 时**追加**一句说明子合集会上提一级、不跟着删。
Future<bool?> showDeleteCollectionDialog(
  BuildContext context,
  String path,
  int count, {
  int childCount = 0,
}) {
  final display = collectionDisplay(path);
  return showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text('删除合集「$display」'),
      content: Text(
        '确定删除合集「$display」吗？\n'
        '该合集下 $count 个视频将移回未分类（视频本身不会被删除）。'
        '${childCount > 0 ? '\n它的 $childCount 个子合集会移到上一级，不会被删除。' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('删除', style: TextStyle(color: kError)),
        ),
      ],
    ),
  );
}

/// 「移动到…」的可选目标：从 [allPaths]（全量合集路径）里挑出合法目标。
///
/// 排除三类（首页管理面板与合集页共用同一套，免得两处规则漂移）：
/// - **自己**（移到自己下面没有意义，模型层也会拦）；
/// - **自己的子孙**（防环：挂进自己的子树会让路径自我包含，子孙与视频引用全部
///   错乱，而且再也移不出来）；
/// - **当前的父合集**（选它等于原地不动，列出来只会让人以为能做点什么）。
///
/// 非顶层时首项补空串 = 「移到顶层（首页）」——合集仍在，只是回到首页那一层
/// （与「未分类」不是一回事：「未分类」是给视频用的归属）。
List<String> collectionMoveTargetsFor(String source, List<String> allPaths) {
  final parent = collectionParentOf(source);
  return [
    if (collectionDepth(source) > 0) '',
    for (final p in allPaths)
      if (p != source && p != parent && !isCollectionUnder(p, source)) p,
  ];
}

/// 合集选择器里的一行：按层级缩进 + 显示全路径。
///
/// 视频「移动到合集」与合集「移动到…」两个选择器共用，保证同一份路径在
/// 两个地方长得一模一样（缩进一步 16dp；顶层不缩进）。
/// [path] 为空串 → 渲染「未分类」（视频专用；合集选择器不会传空串当普通项，
/// 「移到顶层」用 [trailing] 自带文案的那一项）。
class CollectionPathTile extends StatelessWidget {
  final String path;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? titleOverride;

  const CollectionPathTile({
    super.key,
    required this.path,
    this.onTap,
    this.trailing,
    this.titleOverride,
  });

  @override
  Widget build(BuildContext context) {
    final isUncategorized = normalizeCollectionPath(path).isEmpty;
    return ListTile(
      contentPadding: EdgeInsets.only(
        left: 16 + (isUncategorized ? 0 : collectionDepth(path) * 16),
        right: 16,
      ),
      leading: Icon(
        isUncategorized ? Icons.inbox_outlined : Icons.folder_outlined,
        size: 20,
      ),
      title: Text(
        titleOverride ??
            (isUncategorized
                ? kUncategorizedCollectionName
                : collectionDisplay(path)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// 封面 URL 的**最小规范化**：只补协议，不做任何其它改写。
///
/// 真实踩过的坑：从网页 / 图床复制来的封面地址经常是**协议相对**的
/// `//i0.hdslb.com/xx.jpg`（浏览器里显示得好好的），但 `Image.network` 拿到
/// 一个没有协议的串会直接加载失败 —— 卡片只剩占位图标，用户看着"地址明明是
/// 对的"完全不知道为什么。这里把 `//` 开头的补成 `https:`（B 站图床与绝大
/// 多数图床都是 https）。
///
/// **只做这一件事**：不校验后缀、不补 www、不动大小写、不加/去查询参数 ——
/// 任何额外改写都可能把一条本来能用的地址改坏，而在 `Image.network` 的
/// errorBuilder 面前"判错"比"照原样试一次"更糟。
String normalizeCoverUrl(String url) {
  final u = url.trim();
  return u.startsWith('//') ? 'https:$u' : u;
}

/// 编辑合集封面与简介的返回值。
///
/// - [cover]：**规范化后**的封面 URL（空串 = 没设，卡片回落首个视频封面）；
/// - [desc]：简介；
/// - [coverBytes]：这次从相册**新选**的图片字节（null = 这次没选，保持原样）；
///   [coverFileName] 是相册给的文件名（只用来取扩展名）；
/// - [removeLocalCover]：用户点了「移除本机封面」（true 时调用方删掉本机映射
///   + 文件，卡片回落 [cover]）。
///
/// 「本机封面」与 Gist 的 `cover` URL 是**两件并存的事**（本机图优先），所以
/// 它们分成两组字段返回：调用方据此决定「要不要发 PATCH」—— 只动本机图时
/// **一个字节都不该发往 Gist**。
typedef CollectionMetaInput = ({
  String cover,
  String desc,
  Uint8List? coverBytes,
  String coverFileName,
  bool removeLocalCover,
});

/// 编辑合集封面与简介：返回用户填的值（null = 取消）。
///
/// 只负责**收集输入**，落库交给调用方（模型层的 [setCollectionMeta]；本机
/// 封面的文件与映射交给 `CollectionCoverStore`）。
///
/// 封面**两种来源并存**（v2.50.0 起）：
/// - **URL**（可同步）：写进 Gist 的 `cover` 字段，换设备也在；
/// - **本机图片**（相册选图）：图片拷进 App 私有目录
///   （`<ApplicationSupport>/collection_covers/`），映射存本机
///   SharedPreferences，**绝不进 Gist**（base64 进 Gist 会让每次写操作膨胀到
///   十几 MB；本地路径换设备必失效）—— 为什么只能这样，见
///   `CollectionCoverStore` 的文件头；
/// - **优先级：本机图片 > URL**（对话框里那句小字就是告诉用户这件事）。
///
/// 几个交互约定：
/// - **留空 = 不设置**：URL 留空 → 没本机图时卡片回落「合集内第一个视频的
///   封面」；简介留空 → 卡片不占位；
/// - **用户取消选图 → 什么都不改**（点开选择器又退出来是正常操作，
///   不该弹"失败"、也不该清掉已有的本机封面）；
/// - **预览**（v2.50.0 新增，顺带解决 v2.38.0 "对话框没有预览"的已知限制）：
///   本机图 / URL / 都空 三种状态当场可见，URL 边打字边变；URL 打错时预览
///   位置直接显示"这张图加载不出来"，而不是等保存完回到列表才发现。
///
/// 对话框本体的输入框状态放在一个**私有 StatefulWidget** 里（[_CollectionMetaDialog]），
/// 而不是在这个函数里 `TextEditingController()` + 用完 `dispose()`：
/// `showDialog` 的 future 在路由**开始退场**时就完成，此时对话框里的 TextField
/// 还没被卸载 —— 那时候 dispose 控制器会踩到 Flutter 框架的
/// `_dependents.isEmpty` 断言（重建树时直接抛异常）。让 State 自己管自己，
/// 生命周期就天然对齐了。
Future<CollectionMetaInput?> showEditCollectionMetaDialog(
  BuildContext context,
  String path, {
  String cover = '',
  String desc = '',
  String localCoverPath = '',
}) =>
    showDialog<CollectionMetaInput>(
      context: context,
      builder: (_) => _CollectionMetaDialog(
        path: path,
        initialCover: cover,
        initialDesc: desc,
        initialLocalCoverPath: localCoverPath,
      ),
    );

/// 「封面与简介」对话框本体：自己持有输入控制器，随 State 一起释放。
class _CollectionMetaDialog extends StatefulWidget {
  final String path;
  final String initialCover;
  final String initialDesc;

  /// 该合集**当前**的本机封面绝对路径（空串 = 没有），只用于预览；
  /// 换新图 / 移除都由调用方在保存后传给 `CollectionCoverStore`。
  final String initialLocalCoverPath;

  const _CollectionMetaDialog({
    required this.path,
    required this.initialCover,
    required this.initialDesc,
    this.initialLocalCoverPath = '',
  });

  @override
  State<_CollectionMetaDialog> createState() => _CollectionMetaDialogState();
}

class _CollectionMetaDialogState extends State<_CollectionMetaDialog> {
  late final TextEditingController _coverCtrl =
      TextEditingController(text: widget.initialCover);
  late final TextEditingController _descCtrl =
      TextEditingController(text: widget.initialDesc);

  /// 这次从相册选到的图（null = 没选）。
  Uint8List? _pickedBytes;

  /// 选到那张图的文件名（相册给的显示名 → 只用来定扩展名）。
  String _pickedName = '';

  /// 用户在本次对话框里点了「移除本机封面」。
  bool _removedLocal = false;

  /// 选图失败时的一句中文（成功 / 取消后清空）。
  String? _pickError;

  /// 是否正在拉起选择器（防连点；按钮上显示转圈）。
  bool _picking = false;

  /// 当前是否还有本机封面（原图还在 或 这次刚选了新图）。
  bool get _hasLocalCover =>
      _pickedBytes != null ||
      (!_removedLocal && widget.initialLocalCoverPath.isNotEmpty);

  @override
  void initState() {
    super.initState();
    // URL 边打字边更新预览（不然"预览"要等保存完才准）
    _coverCtrl.addListener(_onCoverChanged);
  }

  void _onCoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _coverCtrl.removeListener(_onCoverChanged);
    _coverCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  /// 拉起系统图片选择器。
  ///
  /// 三种结果分开处理（与 `ScheduleImportService` 同一套约定）：
  /// 取消 → **什么都不做**；失败 → 一行中文提示（就在按钮下面，不弹 SnackBar
  /// —— 对话框开着的时候气泡容易被盖住）；成功 → 记住字节，预览立刻变。
  Future<void> _pickFromGallery() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _pickError = null;
    });
    final result = await const ImagePickService().pickImage();
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (result.isCancelled) return; // 取消：本机封面与 URL 都不动
      if (!result.isOk) {
        _pickError = result.error;
        return;
      }
      _pickedBytes = result.bytes;
      _pickedName = result.fileName;
      // 刚选了新图 → 之前点过的「移除」作废（用户显然又要了本机封面）
      _removedLocal = false;
    });
  }

  void _removeLocalCover() {
    setState(() {
      _pickedBytes = null;
      _removedLocal = true;
      _pickError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('封面与简介「${collectionDisplay(widget.path)}」'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _preview(theme),
            const SizedBox(height: kSpace8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _picking ? null : _pickFromGallery,
                  icon: _picking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('从相册选图'),
                ),
                const SizedBox(width: kSpace8),
                if (_hasLocalCover)
                  TextButton.icon(
                    onPressed: _removeLocalCover,
                    icon: const Icon(Icons.hide_image_outlined, size: 18),
                    label: const Text('移除本机封面'),
                  ),
              ],
            ),
            // 「本机」这件事必须写在明面上：用户会理所当然以为"我设的封面
            // 换手机也在"，而它其实只在本机（可同步的是下面那个 URL）
            Padding(
              padding: const EdgeInsets.only(top: kSpace4),
              child: Text(
                '相册选的图只存在这台设备上，不会同步到其它设备；'
                '下面的 URL 才是可同步的封面地址（两者都有时优先显示本机图片）。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_pickError != null) ...[
              const SizedBox(height: kSpace8),
              Text(
                _pickError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _coverCtrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '封面图片 URL',
                helperText: '留空 = 用合集内第一个视频的封面（本机图片优先于这个地址）',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              maxLines: 4,
              minLines: 3,
              decoration: const InputDecoration(
                labelText: '简介',
                hintText: '这个合集是干什么的（留空则不显示）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (
              // 最小规范化只在这里做一次（保存值 = 展示值，卡片那边同样兜一层）
              cover: normalizeCoverUrl(_coverCtrl.text),
              desc: _descCtrl.text,
              coverBytes: _pickedBytes,
              coverFileName: _pickedName,
              removeLocalCover: _removedLocal,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 封面预览（96×96）：本机图片 > URL > 「未设置」。
  ///
  /// 加载失败**不静默**：URL 打错 / 图床挂了都在这一小块里直说，用户当场就
  /// 知道这条地址有问题（而不是保存后回列表看见一个占位图标）。
  Widget _preview(ThemeData theme) {
    final picked = _pickedBytes;
    final url = normalizeCoverUrl(_coverCtrl.text);
    Widget child;
    if (picked != null) {
      child = Image.memory(picked, fit: BoxFit.cover);
    } else if (!_removedLocal && widget.initialLocalCoverPath.isNotEmpty) {
      child = Image.file(
        File(widget.initialLocalCoverPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _previewHint(theme, '本机图片读不出来'),
      );
    } else if (url.isNotEmpty) {
      child = Image.network(
        url,
        fit: BoxFit.cover,
        // 与卡片一致：B 站图床必须带防盗链头，否则 403
        headers: const {
          'User-Agent': kBrowserUA,
          'Referer': kBiliReferer,
        },
        errorBuilder: (_, __, ___) =>
            _previewHint(theme, '这个地址的图加载不出来'),
        loadingBuilder: (context, c, progress) =>
            progress == null ? c : _previewHint(theme, '加载中…'),
      );
    } else {
      child = _previewHint(theme, '未设置封面');
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusSm),
          child: Container(
            width: 96,
            height: 96,
            color: theme.colorScheme.secondaryContainer,
            child: child,
          ),
        ),
      ],
    );
  }

  /// 预览区的一句提示（也当加载失败的兜底）。
  Widget _previewHint(ThemeData theme, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(kSpace8),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
        ),
      );
}

/// 「移动到…」目标选择器：返回目标路径（空串 = 移到顶层；null = 取消）。
///
/// [targets] 由调用方给：**必须已经排除自己与自己的子孙**（防环，模型层
/// [moveCollectionUnder] 还会再拦一道）；空串表示「移到顶层（首页）」，作为
/// 列表**第一项**显示，用 folder_open 图标与普通目标区分。
/// 合集多时列表会超出屏幕：isScrollControlled + constraints 限高 70% 屏高 +
/// useSafeArea + Flexible+ListView 兜底滚动（与视频「移动到合集」同款）。
Future<String?> showCollectionMoveTargetSheet(
  BuildContext context, {
  required String source,
  required List<String> targets,
}) {
  final display = collectionDisplay(source);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
    ),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('移动到合集'),
            subtitle: Text(
              '把「$display」移动到…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            dense: true,
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final t in targets)
                  if (t.isEmpty)
                    ListTile(
                      leading:
                          const Icon(Icons.vertical_align_top_outlined,
                              size: 20),
                      title: const Text('移到顶层（首页）'),
                      onTap: () => Navigator.pop(sheetCtx, ''),
                    )
                  else
                    CollectionPathTile(
                      path: t,
                      onTap: () => Navigator.pop(sheetCtx, t),
                    ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// 嵌套移动确认框：返回 true = 用户确认（null = 取消/点外部关掉）。
///
/// 文案必须写清**两件事**（这正是上一版「并入」语义搞错的地方）：
/// ① 源合集**不会被删除**，它整个挪到目标下面；② 里面的视频与子合集都跟着走，
/// 之后能在目标合集里正常打开它。可逆（还能再移回来），故不写「无法撤销」。
Future<bool?> showMoveCollectionConfirmDialog(
  BuildContext context, {
  required String source,
  required String target,
  required int videoCount,
  required int childCount,
}) {
  final display = collectionDisplay(source);
  final targetText =
      target.isEmpty ? '顶层（首页）' : '「${collectionDisplay(target)}」下面';
  return showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: Text('移动合集「$display」'),
      content: Text(
        '把「$display」移动到$targetText。\n'
        '它的 $videoCount 个视频和 $childCount 个子合集都不会变，'
        '之后可以在目标合集里打开它。\n'
        '此操作会同步到 Gist（还能再移回来）。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('取消'),
        ),
        // 移动不丢数据（源合集还在，视频都还在），故用主色 FilledButton
        // 而非删除那样的破坏性红字
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('移动'),
        ),
      ],
    ),
  );
}
