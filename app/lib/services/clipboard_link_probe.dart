/// 冷启动「读剪贴板 → 命中 B 站视频 → 交给页面开播」（v2.35.0）。
///
/// 分工（本文件不碰 UI / 不导航，便于单测）：
/// 1. 读**一次**剪贴板（[readClipboardText]，只用 `flutter/services.dart` 的
///    [Clipboard]，**不需要任何权限**）；
/// 2. 解析出视频引用（[parseClipboardLink]，纯解析；b23.tv 短链再走一次
///    重定向 [resolveClipboardShortLink]）；
/// 3. 去重（同一个链接只处理一次，见 [ClipboardLinkStore.lastHandledKey]）；
/// 4. 取一次元数据（[BiliApi.fetchVideoMeta] → [WhitelistWriter.videoFromMeta]）
///    把完整 [WhitelistVideo] 交给调用方 push 播放页。
///
/// **只播不写白名单**：与收藏夹 / 搜索 / 评论链接的点播同一原则，全程不写
/// Gist（不把"用户随手复制的链接"变成白名单里的东西）。
///
/// ### 权限与隐私事实
/// Android 10+ 只有**前台**应用能读剪贴板，冷启动读的这一刻 App 正在前台，
/// `Clipboard.getData` 不需要任何权限、也不会拉起系统提示；本流程只在首页
/// 首帧之后跑一次，**切回前台不读**（不在后台读、不监听 resume）。
///
/// ### 番剧（bangumi）链接：识别但不跳（取舍）
/// App 没有通用番剧播放入口——番剧要走"导入白名单 → 选集 / 会员集取流回退"
/// 那一整套（见 `widgets/comment_list.dart` 对番剧链接的同样取舍）。硬把
/// `ep/ss` 塞进普通播放页会得到一个打不开的空白页，比不跳更糟；启动时也
/// 不适合弹"请去搜索页导入"的提示（用户没点任何东西就被教育）。因此番剧
/// 链接按「没有视频链接」处理：什么都不做。
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../api/bilibili_api.dart';
import '../models/whitelist_video.dart';
import '../utils/clipboard_link.dart';
import '../utils/import_parser.dart';
import 'clipboard_link_store.dart';
import 'whitelist_writer.dart';

/// 冷启动读剪贴板的延迟：首页首帧之后再等这么久才读。
///
/// 900ms 的取值理由：首帧之后首页还要拉白名单 / 读登录态 / 起导航，太早 push
/// 播放页会打断这些；太长又让人觉得"怎么半天才跳"。1 秒内属于"打开就有反应"。
const Duration kClipboardOpenDelay = Duration(milliseconds: 900);

/// 冷启动剪贴板检查的结果（页面据此决定"跳 / 提示 / 什么都不做"）。
enum ClipboardOpenStatus {
  /// 命中并已取到完整视频 → 调用方应 push 播放页。
  opened,

  /// 剪贴板里没有 B 站视频链接（含番剧链接、落点非视频）→ 什么都不做。
  none,

  /// 命中的就是上次已处理过的那条 → 不重复打扰。
  duplicate,

  /// 用户在设置里关掉了这个功能 → **连剪贴板都没读**。
  disabled,

  /// 命中但没拿到视频（短链解析失败 / 取元数据失败）→ 调用方应提示一句。
  failed,
}

/// [ClipboardLinkProbe.probe] 的返回值。
class ClipboardOpenResult {
  final ClipboardOpenStatus status;

  /// [ClipboardOpenStatus.opened] 时的完整视频。
  final WhitelistVideo? video;

  /// 分享链接带的 `?p=`（分 P 下标，0 起）；无 → null。
  final int? pageIndex;

  /// 分享链接带的 `?t=`（进度毫秒）；无 → null。
  final int? positionMs;

  /// [ClipboardOpenStatus.failed] 时的可展示原因；其余为空串。
  final String message;

  /// 命中的链接原文（日志与去重用；空串 = 没命中）。
  final String link;

  const ClipboardOpenResult({
    required this.status,
    this.video,
    this.pageIndex,
    this.positionMs,
    this.message = '',
    this.link = '',
  });

  @override
  String toString() =>
      'ClipboardOpenResult(${status.name}${link.isEmpty ? '' : ' $link'})';
}

/// 读剪贴板纯文本（无内容/非文本 → null）。
///
/// Android 10+ 只允许前台应用读剪贴板——本流程是冷启动首帧之后触发的，此时
/// App 一定是前台，**没有任何权限、没有系统弹窗**。
Future<String?> readClipboardText() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  return data?.text;
}

/// 冷启动剪贴板探测：读一次 → 解析 → 去重 → 取元数据。
class ClipboardLinkProbe {
  /// 开关 + 去重记录（跨启动持久化）。
  final ClipboardLinkStore store;

  /// B 站接口（取视频元数据；测试可注入假实现）。
  final BiliApi api;

  /// 短链重定向用的 dio（测试注入假 adapter；null = 用默认浏览器 UA 的 dio）。
  final Dio? dio;

  /// 读剪贴板的方式（测试注入假内容，避免依赖真实系统剪贴板）。
  final Future<String?> Function() readClipboard;

  ClipboardLinkProbe({
    ClipboardLinkStore? store,
    BiliApi? api,
    this.dio,
    Future<String?> Function()? readClipboard,
  })  : store = store ?? ClipboardLinkStore.instance,
        api = api ?? BiliApi(),
        readClipboard = readClipboard ?? readClipboardText;

  /// 跑一次完整探测。**不抛异常**（所有失败都变成 [ClipboardOpenStatus.failed]
  /// 或 [ClipboardOpenStatus.none]，启动流程不该被它打断）。
  Future<ClipboardOpenResult> probe() async {
    // 开关：先确保读过盘（幂等），关掉时连剪贴板都不读
    await store.ensureLoaded();
    if (!store.enabled) {
      debugPrint('[clip] 剪贴板开播已关闭（设置项），跳过读取');
      return const ClipboardOpenResult(status: ClipboardOpenStatus.disabled);
    }

    String? text;
    try {
      text = await readClipboard();
    } catch (e) {
      // 系统剪贴板不可用（少数 ROM / 后台限制）：静默当"没有内容"，
      // 绝不因此打扰用户
      debugPrint('[clip] 读剪贴板失败（静默跳过）: $e');
      return const ClipboardOpenResult(status: ClipboardOpenStatus.none);
    }
    if (text == null || text.trim().isEmpty) {
      return const ClipboardOpenResult(status: ClipboardOpenStatus.none);
    }

    var hit = parseClipboardLink(text);
    if (hit == null) {
      debugPrint('[clip] 剪贴板里没有 B 站视频链接（不打扰）');
      return const ClipboardOpenResult(status: ClipboardOpenStatus.none);
    }
    if (hit.kind == ClipboardLinkKind.bangumi) {
      debugPrint('[clip] 番剧/电影链接 ${hit.pgcRef}：App 无通用番剧播放入口'
          '，启动时不跳（见 clipboard_link_probe.dart 的取舍说明）');
      return ClipboardOpenResult(status: ClipboardOpenStatus.none, link: hit.raw);
    }

    // 去重：**先查再去网络**（同一条链接第二次启动时一次请求都不发）
    if (store.lastHandledKey.isNotEmpty && store.lastHandledKey == hit.raw) {
      debugPrint('[clip] 同一条链接已处理过（${hit.raw}），不再重复跳转');
      return ClipboardOpenResult(
        status: ClipboardOpenStatus.duplicate,
        link: hit.raw,
      );
    }

    if (hit.kind == ClipboardLinkKind.b23) {
      try {
        hit = await resolveClipboardShortLink(hit, dio: dio);
      } on ImportParseException catch (e) {
        // 短链解析失败（网络/超时/重定向异常）
        debugPrint('[clip] 短链解析失败：${e.message}（只提示，不跳页）');
        return ClipboardOpenResult(
          status: ClipboardOpenStatus.failed,
          message: e.message,
          link: text.trim(),
        );
      }
      if (hit == null || hit.kind != ClipboardLinkKind.video) {
        // 落点不是普通视频（活动页/直播/番剧）
        debugPrint('[clip] 短链落点不是普通视频，不跳转');
        return ClipboardOpenResult(
          status: ClipboardOpenStatus.none,
          link: text.trim(),
        );
      }
    }

    final bvid = hit.bvid;
    if (bvid == null) {
      return ClipboardOpenResult(status: ClipboardOpenStatus.none, link: hit.raw);
    }

    try {
      final meta = await api.fetchVideoMeta(bvid);
      final video = WhitelistWriter.videoFromMeta(meta, fallbackBvid: bvid);
      // 取到视频才算"处理过"：失败（网络等）不记，下次启动还能再试一次
      await store.markHandled(hit.raw);
      debugPrint('[clip] 命中链接 → 打开播放页 bvid=$bvid title=${video.title}'
          '${hit.pageIndex != null ? ' p=${hit.pageIndex! + 1}' : ''}'
          '${hit.positionMs != null ? ' t=${hit.positionMs}ms' : ''}');
      return ClipboardOpenResult(
        status: ClipboardOpenStatus.opened,
        video: video,
        pageIndex: hit.pageIndex,
        positionMs: hit.positionMs,
        link: hit.raw,
      );
    } on BiliApiException catch (e) {
      debugPrint('[clip] 取视频元数据失败（${e.message}），只提示不跳页');
      return ClipboardOpenResult(
        status: ClipboardOpenStatus.failed,
        message: '获取视频信息失败：${e.message}',
        link: hit.raw,
      );
    } on DioException {
      debugPrint('[clip] 取视频元数据网络失败，只提示不跳页');
      return ClipboardOpenResult(
        status: ClipboardOpenStatus.failed,
        message: '网络请求失败，请检查网络后重试',
        link: hit.raw,
      );
    } catch (e) {
      debugPrint('[clip] 打开剪贴板链接意外异常：$e');
      return ClipboardOpenResult(
        status: ClipboardOpenStatus.failed,
        message: '打开剪贴板链接失败：$e',
        link: hit.raw,
      );
    }
  }
}
