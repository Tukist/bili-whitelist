/// 合集管理相关的公共弹层（首页 + 合集页共用，v2.30.0 嵌套语义）。
///
/// 抽成公共模块的理由：嵌套之后两个页面都要同一套「新建 / 重命名 / 删除 /
/// 移动到…」弹层，而这些弹层的**文案就是语义本身**（「移动到下面、不删源合集」
/// 与旧的「并入并删除源合集」是完全相反的两件事）。只留一处真相，才不会出现
/// 首页已经改对、合集页还写着旧文案的情况。
///
/// 合集名的展示统一走 [collectionDisplay]（`甲/乙` → `甲 / 乙`）：顶层合集没有
/// `/`，展示出来与原样完全一致（既有测试锚点不受影响）；子合集带全路径，
/// 才看得出自己到底在哪一层。
library;

import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
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
