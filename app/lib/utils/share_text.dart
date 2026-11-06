/// 视频分享链接与分享文案（v2.62.0）。
///
/// 播放页「更多 → 分享」调起系统分享面板时用的就是这个：**纯函数**，不碰
/// 通道、不碰网络 —— 分享只是把一段文本交给别的 App，未登录 / 离线都能用。
///
/// 为什么单独抽文件：链接拼装是唯一有分支（分 P / 进度）的一步，抽成纯函数
/// 才能逐条钉住「单 P 不带 ?p=」「多 P 的 p 是 1 起」「进度不到 10s 不附 t」
/// 这些语义；widget 层只负责把结果递给原生通道。
///
/// 链接形态与 B 站站内一致：`https://www.bilibili.com/video/BVxxx?p=2&t=42`
/// （`p` 分 P 从 1 起，`t` 是秒）。站内链接的解析侧（评论链接 / 剪贴板识别）
/// 认的就是这两个参数，所以分享出去再点回来能直接落到同一集的同一位置。
library;

/// 分享链接（纯函数）。
///
/// - [page]：分 P 序号，**1 起**；null = 不写 `?p=`。调用方只在多 P 视频上给
///   值——单 P 视频带上 `?p=1` 只是噪音，且站外 App 里那一串参数看着像跟踪码。
/// - [positionSeconds]：当前播放位置的秒数；null = 不写 `t=`。
///
/// 参数顺序固定 `p` 在前、`t` 在后（与 B 站分享链接一致），这样同一集同一
/// 位置的链接永远逐字节相同，便于排查与断言。
String buildVideoShareUrl({
  required String bvid,
  int? page,
  int? positionSeconds,
}) {
  final query = <String>[
    if (page != null && page > 0) 'p=$page',
    if (positionSeconds != null && positionSeconds > 0) 't=$positionSeconds',
  ];
  final base = 'https://www.bilibili.com/video/$bvid';
  return query.isEmpty ? base : '$base?${query.join('&')}';
}

/// 分享文案：第一行标题、第二行链接（纯函数）。
///
/// 为什么不写成一行「【标题】 链接」：微信/QQ/邮件收到的都是一段纯文本，
/// 标题独占一行更像「转发一条内容」，也不会因为标题太长把链接挤到词中间
/// 被自动断行器切开（链接被切开就点不动了）。
String buildVideoShareText({required String title, required String url}) {
  final t = title.trim();
  return t.isEmpty ? url : '$t\n$url';
}
