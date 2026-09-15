/// 白名单数据模型（whitelist.json v1 结构；v2 起每条视频带 pages 分 P 信息；
/// v3 起支持合集：顶层 collections 列表 + 每条视频的 collection 归属；
/// v4 起支持 UP 主：顶层 upowners 列表，UP 主视频不在 videos[] 冗余存）。
/// v2.16.4 起番剧/电影导入的视频带可选 `epId`（视频级附加字段，向后兼容，
/// 不升顶层 version——旧读者忽略该键，新读者缺省 null = 普通视频）。
/// v2.16.16 起普通视频/番剧导入的视频带可选 `pubdate`（发布时间，Unix 秒，
/// 同为视频级附加字段向后兼容：旧读者忽略，新读者缺省 null = 未知）。
/// v2.17.3 起视频带可选 `desc`（简介，多 P 视频简介是视频级不分 P；含 \n
/// 换行原样保留；旧数据缺省空串 = 无简介）。普通视频导入写 view 接口
/// data.desc；番剧导入逐集写、简介是季级（见 whitelist_writer 取舍说明），
/// 本批次番剧简介留空。
/// v2.30.0 起合集支持**多层嵌套**：`collections[].name` 与 `videos[].collection`
/// 存的都是**路径**（`动画/2024冬`），合集可移动到另一个合集下面（源合集不被
/// 删除，视频与子孙结构一起跟着走）。为什么用路径而不是 `parent` 字段、
/// 为什么级联要有防环，见 [kCollectionSep] 的说明。旧数据不带 `/` = 顶层合集，
/// 结构不变，**零迁移**。
library;

import 'upowner.dart';

/// 视频分 P 信息（whitelist.json v2 的 pages 数组项）。
class PageInfo {
  final int cid;
  final String part; // 分 P 标题
  final int duration; // 秒

  const PageInfo({
    required this.cid,
    required this.part,
    required this.duration,
  });

  factory PageInfo.fromJson(Map<String, dynamic> json) {
    return PageInfo(
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      part: json['part'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'part': part,
        'duration': duration,
      };
}

/// 单条白名单视频。
class WhitelistVideo {
  final String bvid;
  final int cid;
  final String title;
  final String cover;
  final int duration; // 秒
  final String upName;
  final String addedAt; // ISO 8601
  final List<PageInfo>? pages; // v2 分 P 列表；缺失/为空 → 视为单 P
  final String collection; // v3 所属合集**路径**（v2.30.0 起可含 '/'）；空串 = 未分类
  final int order; // 合集内排序号（拖拽排序用）；旧数据缺省 0 = 按 added_at 倒序
  final int? epId; // 番剧/电影集 ep_id（v2.16.4+ 番剧导入写入；普通视频/旧数据 = null）
  final int? pubdate; // 发布时间（Unix 秒；v2.16.16+ 导入写入；旧数据/未知 = null）
  final String desc; // 简介（v2.17.3+ 普通视频导入写入 view data.desc，含 \n；旧数据/番剧 = ''）

  const WhitelistVideo({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.cover,
    required this.duration,
    required this.upName,
    required this.addedAt,
    this.pages,
    this.collection = '',
    this.order = 0,
    this.epId,
    this.pubdate,
    this.desc = '',
  });

  factory WhitelistVideo.fromJson(Map<String, dynamic> json) {
    return WhitelistVideo(
      bvid: json['bvid'] as String? ?? '',
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      upName: json['up_name'] as String? ?? '',
      addedAt: json['added_at'] as String? ?? '',
      pages: (json['pages'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(PageInfo.fromJson)
          .toList(),
      collection: json['collection'] as String? ?? '',
      // 脏数据（非数字，如字符串）时按缺省 0 处理，不抛类型转换错误
      order: json['order'] is num ? (json['order'] as num).toInt() : 0,
      // 旧数据无 epId / 脏类型 → null（不崩；播放回退逻辑按 null 视为普通视频）
      epId: json['epId'] is num ? (json['epId'] as num).toInt() : null,
      // 旧数据无 pubdate / 脏类型 → null（UI 不显示发布时间）
      pubdate: json['pubdate'] is num ? (json['pubdate'] as num).toInt() : null,
      // 旧数据无 desc / 脏类型（非 String）→ 空串（信息行不显示简介，不崩）
      desc: json['desc'] is String ? json['desc'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'cid': cid,
        'title': title,
        'cover': cover,
        'duration': duration,
        'up_name': upName,
        'added_at': addedAt,
        'collection': collection,
        'order': order,
        // epId 非空才输出（普通视频/旧数据不回写多余字段）
        if (epId != null) 'epId': epId,
        // pubdate 非空才输出（旧数据/未知不回写多余字段）
        if (pubdate != null) 'pubdate': pubdate,
        // desc 非空才输出（无简介/旧数据不回写多余字段，保持数据干净）
        if (desc.isNotEmpty) 'desc': desc,
        if (pages != null)
          'pages': pages!.map((p) => p.toJson()).toList(),
      };

  /// 是否未分类（v3：collection 为空串；旧 v2/v1 数据天然全部未分类）。
  bool get isUncategorized => collection.isEmpty;

  /// 复制并修改合集归属（管理操作「移动到合集」用）。
  ///
  /// epId/pubdate/desc 不被本方法修改：未传时沿用原值（合集移动/重排不丢
  /// 番剧集标识、发布时间与简介）。
  WhitelistVideo copyWith(
          {String? collection, int? order, int? epId, int? pubdate, String? desc}) =>
      WhitelistVideo(
        bvid: bvid,
        cid: cid,
        title: title,
        cover: cover,
        duration: duration,
        upName: upName,
        addedAt: addedAt,
        pages: pages,
        collection: collection ?? this.collection,
        order: order ?? this.order,
        epId: epId ?? this.epId,
        pubdate: pubdate ?? this.pubdate,
        desc: desc ?? this.desc,
      );

  /// 分 P 数量：pages 缺失或为空 → 单 P（1）。
  int get pageCount => (pages == null || pages!.isEmpty) ? 1 : pages!.length;

  /// 是否为多 P 视频（列表/播放页据此决定是否展示选集 UI）。
  bool get isMultiPage => pageCount > 1;
}

/// 发布时间格式化：Unix 秒 → `yyyy-MM-dd`；null / ≤0（脏值）→ 空串。
///
/// 旧数据无 pubdate（或解析出 0）返回空串 → UI 不显示发布时间，
/// 且不破坏原有布局（展示行只拼接非空段）。
String formatPubdate(int? unixSec) {
  if (unixSec == null || unixSec <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

/// 合集信息（whitelist.json v3 的 collections 数组项）。
///
/// v2.30.0 起 [name] 是**路径**（如 `动画/2024冬`）而不是单段名字，
/// 详见 [kCollectionSep]。
class CollectionInfo {
  final String name;
  final String createdAt; // ISO 8601

  const CollectionInfo({required this.name, required this.createdAt});

  /// 父路径（顶层 → 空串）。层级由 [name] 自身表达，不另存 parent 字段。
  String get parentPath => collectionParentOf(name);

  /// 在父页面里显示的**局部名**（路径最后一段）。
  String get localName => collectionLocalName(name);

  /// 层级：顶层 = 0，每深一层 +1。
  int get depth => collectionDepth(name);

  factory CollectionInfo.fromJson(Map<String, dynamic> json) {
    return CollectionInfo(
      name: json['name'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'created_at': createdAt,
      };
}

/// 合集管理错误（rename/delete 校验失败）：message 可直接展示给用户。
class CollectionException implements Exception {
  final String message;

  const CollectionException(this.message);

  @override
  String toString() => 'CollectionException: $message';
}

/// 「未分类」的合集名：**不是**路径段，不能被新建 / 重命名成它，也不能被移动
/// （它的身份是空串 `''`，见 [WhitelistVideo.isUncategorized]）。
///
/// 定义在模型层（而不是页面层）是因为校验要在这里做；页面层的
/// `kUncategorizedLabel` 直接引用本常量，保证两处永远同一个字符串。
const String kUncategorizedCollectionName = '未分类';

/// 合集层级分隔符：**合集的身份 = 路径字符串**（v2.30.0 起支持多层嵌套）。
///
/// [CollectionInfo.name] 与 [WhitelistVideo.collection] 存的都是**完整路径**
/// （如 `动画/2024冬`），视频用路径引用合集。
///
/// 为什么用路径而不是给 [CollectionInfo] 加一个 `parent` 字段（别改回去）：
/// 视频是用**名字**引用合集的（[WhitelistVideo.collection] 只是一个字符串），
/// 若改成存 `parent`，**不同父合集下的同名子合集**（例如「动画」与「音乐」
/// 下各有一个「教程」）就会产生歧义 ——「查找名为 教程 的合集」会命中两个，
/// 视频到底属于哪一个就说不清了。路径天然唯一；顺带**旧数据零迁移**：不带
/// `/` 的名字本来就是顶层合集，PC 端 `whitelist.py` 把路径当普通名字照旧可读。
///
/// 配套约定（本文件所有合集函数共同遵守）：
/// - 合集名**不允许包含** `/`（[validateCollectionName] 拦下并给出可读提示）；
/// - 空串 = 未分类，不是路径段，不能被移动/嵌套/当作路径的一段；
/// - 改名或换层级都必须**级联**改子孙路径与它们的视频引用，否则子孙会变成
///   悬空路径（父路径不存在 → 视频谁也找不到，等于数据丢失）。
const String kCollectionSep = '/';

/// 路径规范化：整体去空白 + 逐段去空白 + 丢掉空段。
///
/// 写进数据的路径一定已经过这里（新建/重命名/移动都走一遍），所以这里再兜
/// 一次是给脏数据留余量（手改 Gist 写出 `甲//乙`、` 甲 / 乙 ` 之类不会让
/// 层级判断错位）。`甲/` 与 `甲` 归一后相同 → 顶层与「尾巴多个斜杠」等价。
String normalizeCollectionPath(String path) => path
    .split(kCollectionSep)
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .join(kCollectionSep);

/// 父路径：`甲/乙/丙` → `甲/乙`；顶层 `甲` → 空串 `''`。
String collectionParentOf(String path) {
  final p = normalizeCollectionPath(path);
  final i = p.lastIndexOf(kCollectionSep);
  return i < 0 ? '' : p.substring(0, i);
}

/// 路径最后一段（在父页面里显示的局部名）：`甲/乙` → `乙`；`甲` → `甲`。
String collectionLocalName(String path) {
  final p = normalizeCollectionPath(path);
  final i = p.lastIndexOf(kCollectionSep);
  return i < 0 ? p : p.substring(i + 1);
}

/// 层级深度：顶层 = 0，每深一层 +1（`甲/乙/丙` → 2）。
int collectionDepth(String path) {
  final p = normalizeCollectionPath(path);
  if (p.isEmpty) return 0;
  return kCollectionSep.allMatches(p).length;
}

/// 所有祖先路径，从最外层到直接父级：`甲/乙/丙` → `[甲, 甲/乙]`（面包屑用）。
/// 顶层 → 空列表。
List<String> collectionAncestors(String path) {
  final parts = normalizeCollectionPath(path).split(kCollectionSep);
  final out = <String>[];
  for (var i = 1; i < parts.length; i++) {
    out.add(parts.take(i).join(kCollectionSep));
  }
  return out;
}

/// [path] 是否在 [ancestor] **之下**（严格子孙，不含自己）。
///
/// [ancestor] 为空串（未分类 / 顶层容器）时恒 false：「未分类」没有子孙。
bool isCollectionUnder(String path, String ancestor) {
  final p = normalizeCollectionPath(path);
  final a = normalizeCollectionPath(ancestor);
  if (a.isEmpty || p == a) return false;
  return p.startsWith('$a$kCollectionSep');
}

/// 数据里所有在 [path] 之下的子孙路径（按 collections 数组顺序）。防环与
/// 「移动时排除自己的子树」都靠它。
List<String> collectionDescendants(WhitelistData data, String path) {
  final p = normalizeCollectionPath(path);
  return [
    for (final c in data.collections)
      if (isCollectionUnder(c.name, p)) c.name,
  ];
}

/// 数据里的**直属子合集**（按 collections 数组顺序 = 显示顺序）。
///
/// 只取直接子级：父页面列出的是「我的子合集」，孙合集在子合集自己的页面里
/// 展示（与文件系统的目录树同一套直觉）。
List<CollectionInfo> collectionChildrenOf(WhitelistData data, String path) {
  final p = normalizeCollectionPath(path);
  return [
    for (final c in data.collections)
      if (collectionParentOf(c.name) == p) c,
  ];
}

/// 展示用路径：`甲/乙/丙` → `甲 / 乙 / 丙`（斜杠两侧留白，长路径才读得出层级）。
String collectionDisplay(String path) =>
    normalizeCollectionPath(path).split(kCollectionSep).join(' / ');

/// 校验一个**单段**合集名（新建 / 重命名 / 建子合集都过这里）。
///
/// 抛 [CollectionException]（message 可直接展示）：
/// - 去空白后为空；
/// - 含 `/`（`/` 是层级分隔符，名字里出现只会让路径含义混乱）；
/// - 等于「未分类」（它由空串表达，不能被当作真实合集）。
void validateCollectionName(String name) {
  final n = name.trim();
  if (n.isEmpty) throw const CollectionException('合集名不能为空');
  if (n.contains(kCollectionSep)) {
    throw const CollectionException(
      '合集名不能包含「$kCollectionSep」（「$kCollectionSep」用来表示合集层级，'
      '例如「动画${kCollectionSep}2024冬」是「动画」下面的子合集）',
    );
  }
  if (n == kUncategorizedCollectionName) {
    throw const CollectionException('合集名不能为「$kUncategorizedCollectionName」');
  }
}

/// 把 [path] 的 `[from]` 前缀换成 `[to]`（[path] == [from] 时也返回 [to]）；
/// 不在 [from] 之下 → 原样返回。
///
/// 重命名 / 移动 / 删除合集时的**级联**都靠它：子孙路径与它们的视频引用必须
/// 跟着前缀一起走，否则子孙会挂在一条不存在的父路径下（数据静默丢失）。
/// [to] 为空串 = 收到顶层。
String _rebasePath(String path, String from, String to) {
  if (from.isEmpty) return path; // 空前缀不是任何合集的祖先
  if (path == from) return to;
  if (!path.startsWith('$from$kCollectionSep')) return path;
  final tail = path.substring(from.length + 1); // 越过前缀与那一个分隔符
  return to.isEmpty ? tail : '$to$kCollectionSep$tail';
}

/// 报错文案里的「现有合集」提示（无合集时说「无」）。
String _existingHint(List<String> names) =>
    names.isEmpty ? '无' : names.join(', ');

/// 新建合集 / 新建**子合集**（[parentPath] 非空时挂到它下面）。
///
/// - [name] 是单段名字，会经 [validateCollectionName] 校验；
/// - [parentPath] 非空时必须已存在（父合集不能凭空出现）；
/// - 同一层级下已有同名 → 抛 [CollectionException]（不同层级允许同名，
///   因为路径不同就是两个合集）；
/// - 返回新数据，原数据不可变不修改。
///
/// 路径拼接集中在这里：页面层不自己拼字符串，免得漏了规范化或漏了校验。
WhitelistData createSubCollection(
  WhitelistData data,
  String parentPath,
  String name,
) {
  validateCollectionName(name);
  final parent = normalizeCollectionPath(parentPath);
  final names = [for (final c in data.collections) c.name];
  if (parent.isNotEmpty && !names.contains(parent)) {
    throw CollectionException(
      '父合集「$parent」不存在（现有合集: ${_existingHint(names)}）',
    );
  }
  final full =
      parent.isEmpty ? name.trim() : '$parent$kCollectionSep${name.trim()}';
  if (names.contains(full)) {
    throw CollectionException('合集「$full」已存在');
  }
  return data.copyWith(
    collections: [
      ...data.collections,
      CollectionInfo(
        name: full,
        createdAt: DateTime.now().toIso8601String(),
      ),
    ],
  );
}

/// 重命名合集：[newName] 是**单段新名**，只替换 [oldName] 路径的**最后一段**，
/// 层级不变；**级联**改子孙路径与所有相关视频的 `collection` 引用。
///
/// 与 PC 端 whitelist.py `collection rename` 语义一致（顶层合集上完全等同）：
/// - 旧名/新名去空白后校验非空，新名还过 [validateCollectionName]；
/// - 新旧路径相同 → 未改动，原样返回（不抛错）；
/// - 旧名不存在 → 抛 [CollectionException]；
/// - **同一层级**下已有同名 → 抛 [CollectionException]（不会合并，请先处理；
///   不同层级可以同名——路径不同就是两个合集）。
///
/// 返回新数据，原数据不可变不修改。
WhitelistData renameCollection(
  WhitelistData data,
  String oldName,
  String newName,
) {
  final old = normalizeCollectionPath(oldName);
  final neu = newName.trim();
  if (old.isEmpty) throw const CollectionException('旧合集名不能为空');
  if (neu.isEmpty) throw const CollectionException('新合集名不能为空');
  validateCollectionName(neu);
  final names = data.collections.map((c) => c.name).toList();
  if (!names.contains(old)) {
    throw CollectionException(
      '合集「$old」不存在（现有合集: ${_existingHint(names)}）',
    );
  }
  final parent = collectionParentOf(old);
  final newPath = parent.isEmpty ? neu : '$parent$kCollectionSep$neu';
  if (newPath == old) return data; // 同名（含只差空白）→ 未改动
  if (names.contains(newPath)) {
    throw CollectionException(
      '同级下已有合集「$newPath」（重命名不会合并合集，请先改名或删除）',
    );
  }
  return data.copyWith(
    // 级联：自己 + 所有子孙的路径前缀一起换（子孙层级关系原样保留）
    collections: [
      for (final c in data.collections)
        if (c.name == old || isCollectionUnder(c.name, old))
          CollectionInfo(
            name: _rebasePath(c.name, old, newPath),
            createdAt: c.createdAt,
          )
        else
          c,
    ],
    videos: [
      for (final v in data.videos)
        if (v.collection == old || isCollectionUnder(v.collection, old))
          v.copyWith(collection: _rebasePath(v.collection, old, newPath))
        else
          v,
    ],
  );
}

/// 合集重排（首页 / 合集页拖拽排序用）：按 [newOrderNames] 的顺序重排
/// collections 数组。
///
/// **只做同级重排**：[newOrderNames] 必须是现有合集名单的一个**排列**
/// （同数量、同名字，一一对应）——名字就是身份（路径），名字不变则每个合集的
/// 层级、子孙、视频归属都不可能被本函数改动（要换层级请用 [moveCollectionUnder]）。
/// 数量/名字对不上（含传一份改过路径的名字想借重排偷换层级）→ 抛
/// [CollectionException]，原数据不动。
///
/// 数组顺序的含义：每层的子合集在**各自页面**里的显示顺序（首页看顶层、
/// 合集页看自己的子合集）；跨层的相对次序不影响渲染，各页只过滤自己那一层。
/// 返回新数据，原数据不可变不修改。
WhitelistData reorderCollections(WhitelistData data, List<String> newOrderNames) {
  final names = data.collections.map((c) => c.name).toList();
  final wanted = [for (final n in newOrderNames) normalizeCollectionPath(n)];
  if (wanted.length != names.length || !wanted.toSet().containsAll(names)) {
    throw const CollectionException('合集列表不完整，重排已取消');
  }
  final byName = {for (final c in data.collections) c.name: c};
  return data.copyWith(
    collections: [for (final n in wanted) byName[n]!],
  );
}

/// 删除合集：从 collections 移除该定义 + 它的**直属视频** collection 置空
/// （回未分类）。
///
/// 与 PC 端 whitelist.py `collection delete` 语义一致：**不删除视频**。
/// 嵌套语义（v2.30.0 起）：
/// - **直属子合集上提一级**（路径前缀收窄一段，挂到被删合集的父级下）——
///   删「甲/乙」时「甲/乙/丙」变成「甲/丙」，子孙层级关系整体上提；
/// - **不连带删除子孙**：子孙合集定义与它们里面的视频都保留（只改路径前缀，
///   视频的 collection 同步改成新路径，不然它们会指向一条不存在的合集）；
/// - 被删合集自己的直属视频落回未分类（空串）。
///
/// 合集不存在 / 名字为空 → 抛 [CollectionException]。返回新数据。
WhitelistData deleteCollection(WhitelistData data, String name) {
  final n = normalizeCollectionPath(name);
  if (n.isEmpty) throw const CollectionException('合集名不能为空');
  final names = data.collections.map((c) => c.name).toList();
  if (!names.contains(n)) {
    throw CollectionException(
      '合集「$n」不存在（现有合集: ${_existingHint(names)}）',
    );
  }
  final parent = collectionParentOf(n);
  return data.copyWith(
    collections: [
      for (final c in data.collections)
        if (c.name != n)
          // 子孙合集上提一级（_rebasePath 把前缀 n 换成父路径）
          isCollectionUnder(c.name, n)
              ? CollectionInfo(
                  name: _rebasePath(c.name, n, parent),
                  createdAt: c.createdAt,
                )
              : c,
    ],
    videos: [
      for (final v in data.videos)
        if (v.collection == n)
          // 被删合集的直属视频 → 未分类（既有规矩，视频不删）
          v.copyWith(collection: '')
        else if (isCollectionUnder(v.collection, n))
          // 子孙合集的视频 → 跟着收窄后的路径走（不是落回未分类）
          v.copyWith(collection: _rebasePath(v.collection, n, parent))
        else
          v,
    ],
  );
}

/// 把一个合集**嵌套**到另一个合集下面（「移动到…」）：[source] 成为 [target]
/// 的子合集。
///
/// **源合集不会被删除**，它自己、它的视频、它的子孙结构全都保留 —— 只把路径
/// 前缀从 [source] 换成 `[target]/<source 的局部名>`，并**级联**改子孙路径与
/// 所有相关视频的 `collection`（不级联就会留下一堆指向不存在合集的引用）。
/// 移动后能正常在目标合集里打开源合集，且可以一层层继续嵌套下去。
///
/// [target] 允许为空串 = **移回顶层**（这不是「未分类」：合集仍在，只是回到
/// 首页那一层；「未分类」是给视频用的，合集不能变成未分类）。
///
/// 边界：
/// - [source] 不存在 / 为空 → 抛 [CollectionException]；
/// - **防环**：[target] 是自己或自己的子孙 → 抛 [CollectionException]
///   （否则会把合集挂进自己的子树里，路径自我包含 → 子孙与视频引用全部错乱，
///   并且再也移不出来）；
/// - [target] 非空但不存在 → 抛 [CollectionException]（不许凭空造父合集）；
/// - 目标下已有**同名**子合集 → 抛 [CollectionException]（不做自动改名）；
/// - 本来就在该层级（路径不变）→ 未改动，原样返回。
///
/// **位置上的一点约定**：合集在 `collections` 数组里的位置保持不动（只换路径
/// 前缀），所以它出现在新父合集子列表里的相对位置由原数组顺序决定；想让它排在
/// 最后，用 [reorderCollections]（同级重排）拖一下即可。这样实现最简单，也不会
/// 因为移动而默默打乱其他合集的显示顺序。
///
/// 返回新数据，原数据不可变不修改。
WhitelistData moveCollectionUnder(
  WhitelistData data,
  String source,
  String target,
) {
  final src = normalizeCollectionPath(source);
  final dst = normalizeCollectionPath(target);
  if (src.isEmpty) throw const CollectionException('源合集名不能为空');
  final names = data.collections.map((c) => c.name).toList();
  if (!names.contains(src)) {
    throw CollectionException(
      '合集「$src」不存在（现有合集: ${_existingHint(names)}）',
    );
  }
  if (dst == src || isCollectionUnder(dst, src)) {
    throw CollectionException(
      '不能把「$src」移到它自己或它的子合集「$dst」下面（合集不能嵌套进自己）',
    );
  }
  if (dst.isNotEmpty && !names.contains(dst)) {
    throw CollectionException(
      '目标合集「$dst」不存在（现有合集: ${_existingHint(names)}）',
    );
  }
  final local = collectionLocalName(src);
  final newPath = dst.isEmpty ? local : '$dst$kCollectionSep$local';
  if (newPath == src) return data; // 已经在该层级 → 未改动
  if (names.contains(newPath)) {
    throw CollectionException(
      '目标下已有同名合集「$newPath」（不会自动改名，请先重命名其一）',
    );
  }
  return data.copyWith(
    collections: [
      for (final c in data.collections)
        if (c.name == src || isCollectionUnder(c.name, src))
          CollectionInfo(
            name: _rebasePath(c.name, src, newPath),
            createdAt: c.createdAt,
          )
        else
          c,
    ],
    videos: [
      for (final v in data.videos)
        if (v.collection == src || isCollectionUnder(v.collection, src))
          // 视频 order 不动：移动不改变合集内部的展示顺序
          v.copyWith(collection: _rebasePath(v.collection, src, newPath))
        else
          v,
    ],
  );
}

/// 白名单整体（v1 结构 + videos 列表；v3 增加 collections；v4 增加 upowners）。
class WhitelistData {
  final int version;
  final String updatedAt; // 服务端更新时间（PC 端写入）
  final List<WhitelistVideo> videos;
  final List<CollectionInfo> collections; // v3；旧数据缺省为 []
  final List<Upowner> upowners; // v4；旧数据缺省为 []

  /// 当前存储版本号（写回 Gist 时统一规范化到此版本）。
  static const int currentVersion = 4;

  const WhitelistData({
    required this.version,
    required this.updatedAt,
    required this.videos,
    this.collections = const [],
    this.upowners = const [],
  });

  factory WhitelistData.fromJson(Map<String, dynamic> json) {
    final rawVideos = json['videos'];
    final videos = rawVideos is List
        ? rawVideos
            .whereType<Map<String, dynamic>>()
            .map(WhitelistVideo.fromJson)
            .toList()
        : <WhitelistVideo>[];
    final rawCollections = json['collections'];
    final collections = rawCollections is List
        ? rawCollections
            .whereType<Map<String, dynamic>>()
            .map(CollectionInfo.fromJson)
            .toList()
        : <CollectionInfo>[];
    final rawUpowners = json['upowners'];
    final upowners = rawUpowners is List
        ? rawUpowners
            .whereType<Map<String, dynamic>>()
            .map(Upowner.fromJson)
            .toList()
        : <Upowner>[];
    return WhitelistData(
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt: json['updated_at'] as String? ?? '',
      videos: videos,
      collections: collections,
      upowners: upowners,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'updated_at': updatedAt,
        'collections': collections.map((c) => c.toJson()).toList(),
        'upowners': upowners.map((u) => u.toJson()).toList(),
        'videos': videos.map((v) => v.toJson()).toList(),
      };

  /// 复制并替换 videos / collections / upowners（管理操作生成新数据用）。
  WhitelistData copyWith({
    int? version,
    String? updatedAt,
    List<WhitelistVideo>? videos,
    List<CollectionInfo>? collections,
    List<Upowner>? upowners,
  }) =>
      WhitelistData(
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        videos: videos ?? this.videos,
        collections: collections ?? this.collections,
        upowners: upowners ?? this.upowners,
      );

  /// 管理操作保存前规范化：version 固定 4、updated_at 刷新、collections 必出、
  /// upowners 必出。（读入任意版本数据，写回 Gist 时统一为 v4。）
  WhitelistData normalizedForSave() => WhitelistData(
        version: currentVersion,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        videos: videos,
        collections: collections,
        upowners: upowners,
      );

  /// 空白名单。
  static WhitelistData empty() => const WhitelistData(
        version: currentVersion,
        updatedAt: '',
        videos: [],
      );

  /// 取某合集下的视频，按展示顺序排序：**order 升序优先**，
  /// order 相同（或旧数据全为 0）时按 added_at 倒序兜底（新加入的在前，
  /// 与 PC 端 whitelist.py 写回语义一致）。返回新列表，原数据不变。
  ///
  /// - [collection] 为 null → 全部视频；空串 '' → 未分类；否则按**完整路径**
  ///   **精确匹配** [WhitelistVideo.collection]
  ///
  /// **精确匹配 = 父合集不混入子孙的视频**（v2.30.0 嵌套语义的硬约定）：
  /// 父合集页面只列自己的**直属视频**，子合集的视频在子合集页面里看。
  /// 混在一起会有两个真实问题：① 各合集的 `order` 都是自己那套 `0..n-1`，
  /// 跨合集必然撞号，排序结果由 added_at 兜底决定（用户拖过的顺序白拖）；
  /// ② 视频卡片点进去之后「属于哪个合集」与当前页面标题对不上（在「动画」
  /// 页里点开一条其实属于「动画/2024冬」的视频，返回/移动的语义全乱）。
  List<WhitelistVideo> sortedVideos([String? collection]) {
    final matched = collection == null
        ? videos
        : videos.where((v) =>
            collection.isEmpty ? v.isUncategorized : v.collection == collection);
    final list = matched.toList()
      ..sort((a, b) {
        final byOrder = a.order.compareTo(b.order);
        if (byOrder != 0) return byOrder;
        return _compareAddedAtDesc(a.addedAt, b.addedAt);
      });
    return list;
  }

  /// added_at 倒序比较：ISO 8601 字符串优先转 DateTime 比较（兼容不同时区
  /// 写法）；解析失败（空串/脏数据）视为最旧，排到最后。
  static int _compareAddedAtDesc(String a, String b) {
    final ta = DateTime.tryParse(a);
    final tb = DateTime.tryParse(b);
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return tb.compareTo(ta);
  }
}
