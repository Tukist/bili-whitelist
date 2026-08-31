/// 白名单数据模型（whitelist.json v1 结构；v2 起每条视频带 pages 分 P 信息；
/// v3 起支持合集：顶层 collections 列表 + 每条视频的 collection 归属）。
library;

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
  final String collection; // v3 所属合集名；空串 = 未分类
  final int order; // 合集内排序号（拖拽排序用）；旧数据缺省 0 = 按 added_at 倒序

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
        if (pages != null)
          'pages': pages!.map((p) => p.toJson()).toList(),
      };

  /// 是否未分类（v3：collection 为空串；旧 v2/v1 数据天然全部未分类）。
  bool get isUncategorized => collection.isEmpty;

  /// 复制并修改合集归属（管理操作「移动到合集」用）。
  WhitelistVideo copyWith({String? collection, int? order}) => WhitelistVideo(
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
      );

  /// 分 P 数量：pages 缺失或为空 → 单 P（1）。
  int get pageCount => (pages == null || pages!.isEmpty) ? 1 : pages!.length;

  /// 是否为多 P 视频（列表/播放页据此决定是否展示选集 UI）。
  bool get isMultiPage => pageCount > 1;
}

/// 合集信息（whitelist.json v3 的 collections 数组项）。
class CollectionInfo {
  final String name;
  final String createdAt; // ISO 8601

  const CollectionInfo({required this.name, required this.createdAt});

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

/// 重命名合集：改 collections 数组里的名字 + 同步所有 videos.collection 引用。
///
/// 与 PC 端 whitelist.py `collection rename` 语义一致：
/// - 旧名/新名去空白后校验非空
/// - 新旧名相同 → 未改动，原样返回（不抛错）
/// - 旧名不存在 / 新名与现有其他合集重名 → 抛 [CollectionException]
/// 返回新数据，原数据不可变不修改。
WhitelistData renameCollection(
  WhitelistData data,
  String oldName,
  String newName,
) {
  final old = oldName.trim();
  final neu = newName.trim();
  if (old.isEmpty) throw const CollectionException('旧合集名不能为空');
  if (neu.isEmpty) throw const CollectionException('新合集名不能为空');
  final names = data.collections.map((c) => c.name).toList();
  if (!names.contains(old)) {
    throw CollectionException(
      '合集「$old」不存在（现有合集: ${names.isEmpty ? '无' : names.join(', ')}）',
    );
  }
  if (old == neu) return data; // 新旧名相同，未改动
  if (names.contains(neu)) {
    throw CollectionException(
      '新名「$neu」已存在（重命名会合并合集，请先处理）',
    );
  }
  return data.copyWith(
    collections: [
      for (final c in data.collections)
        if (c.name == old)
          CollectionInfo(name: neu, createdAt: c.createdAt)
        else
          c,
    ],
    videos: [
      for (final v in data.videos)
        if (v.collection == old) v.copyWith(collection: neu) else v,
    ],
  );
}

/// 合集重排（主页拖拽排序用）：按 [newOrderNames] 的顺序重排 collections。
///
/// - [newOrderNames] 必须与现有合集一一对应（同集合同数量、同名字，
///   名字一致即不会混入「未分类」）；数量/名字不匹配 → 抛
///   [CollectionException]，原数据不动
/// - 只重排合集定义数组，视频归属（collection 引用）不受影响
/// - 返回新数据，原数据不可变不修改。
WhitelistData reorderCollections(WhitelistData data, List<String> newOrderNames) {
  final names = data.collections.map((c) => c.name).toList();
  final orderSet = newOrderNames.toSet();
  if (newOrderNames.length != names.length || !orderSet.containsAll(names)) {
    throw const CollectionException('合集列表不完整，重排已取消');
  }
  final byName = {for (final c in data.collections) c.name: c};
  return data.copyWith(
    collections: [for (final n in newOrderNames) byName[n]!],
  );
}

/// 删除合集：从 collections 移除定义 + 该合集下视频 collection 置空（回未分类）。
///
/// 与 PC 端 whitelist.py `collection delete` 语义一致：**不删除视频**，
/// 仅清除归属引用。合集不存在 → 抛 [CollectionException]。返回新数据。
WhitelistData deleteCollection(WhitelistData data, String name) {
  final n = name.trim();
  if (n.isEmpty) throw const CollectionException('合集名不能为空');
  final names = data.collections.map((c) => c.name).toList();
  if (!names.contains(n)) {
    throw CollectionException(
      '合集「$n」不存在（现有合集: ${names.isEmpty ? '无' : names.join(', ')}）',
    );
  }
  return data.copyWith(
    collections: [
      for (final c in data.collections)
        if (c.name != n) c,
    ],
    videos: [
      for (final v in data.videos)
        if (v.collection == n) v.copyWith(collection: '') else v,
    ],
  );
}

/// 白名单整体（v1 结构 + videos 列表；v3 增加 collections）。
class WhitelistData {
  final int version;
  final String updatedAt; // 服务端更新时间（PC 端写入）
  final List<WhitelistVideo> videos;
  final List<CollectionInfo> collections; // v3；旧数据缺省为 []

  const WhitelistData({
    required this.version,
    required this.updatedAt,
    required this.videos,
    this.collections = const [],
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
    return WhitelistData(
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt: json['updated_at'] as String? ?? '',
      videos: videos,
      collections: collections,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'updated_at': updatedAt,
        'collections': collections.map((c) => c.toJson()).toList(),
        'videos': videos.map((v) => v.toJson()).toList(),
      };

  /// 复制并替换 videos / collections（管理操作生成新数据用）。
  WhitelistData copyWith({
    int? version,
    String? updatedAt,
    List<WhitelistVideo>? videos,
    List<CollectionInfo>? collections,
  }) =>
      WhitelistData(
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        videos: videos ?? this.videos,
        collections: collections ?? this.collections,
      );

  /// 管理操作保存前规范化：version 固定 3、updated_at 刷新、collections 必出。
  /// （读入任意版本数据，写回 Gist 时统一为 v3。）
  WhitelistData normalizedForSave() => WhitelistData(
        version: 3,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        videos: videos,
        collections: collections,
      );

  /// 空白名单。
  static WhitelistData empty() =>
      const WhitelistData(version: 1, updatedAt: '', videos: []);

  /// 取某合集下的视频，按展示顺序排序：**order 升序优先**，
  /// order 相同（或旧数据全为 0）时按 added_at 倒序兜底（新加入的在前，
  /// 与 PC 端 whitelist.py 写回语义一致）。返回新列表，原数据不变。
  ///
  /// - [collection] 为 null → 全部视频；空串 '' → 未分类；否则按合集名过滤
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
