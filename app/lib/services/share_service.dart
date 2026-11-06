import 'package:flutter/services.dart';

/// 系统分享的通道名（原生侧 `SharePlugin.kt`）。
const String kShareChannel = 'bili_whitelist/share';

/// 分享结果：成功调起系统面板 / 失败（带一句可读原因）。
///
/// 与 `GallerySaver` 的 `GallerySaveResult` 同一套约定：**不抛异常**，调用点
/// 只判 [ok]，失败时把 [message] 原样提示给用户。
class ShareResult {
  /// 是否成功调起系统分享面板。
  final bool ok;

  /// 给用户看的一句话（成功时为空串；失败时必有内容）。
  final String message;

  const ShareResult({required this.ok, required this.message});

  const ShareResult.ok()
      : ok = true,
        message = '';
}

/// 系统分享面板的通道封装（v2.62.0）。
///
/// 对应原生 `SharePlugin.kt`：`Intent.ACTION_SEND` + `type=text/plain` +
/// `FLAG_ACTIVITY_NEW_TASK` + `Intent.createChooser`。**不需要任何权限**，
/// 也不联网 —— 分享只是把一段文本交给别的 App（所以未登录 / 离线都能分享）。
///
/// ## 失败约定
///
/// 三条失败路径都给**可读中文**，绝不抛到界面：
/// - 原生回 `false`（系统里没有任何 App 能收 `text/plain`）；
/// - 原生抛 `PlatformException`（调起过程中 Activity 异常）；
/// - 通道不存在（`MissingPluginException`：非 Android 平台 / 旧包）。
///
/// 返回 [ShareResult]，由调用点决定怎么提示（播放页是一条 SnackBar）。
class ShareService {
  static const MethodChannel _channel = MethodChannel(kShareChannel);

  /// 分享一段纯文本。[subject] 是 `EXTRA_SUBJECT`（邮件标题 / 选择器标题），
  /// [text] 是正文（标题 + 链接）。
  static Future<ShareResult> shareText({
    required String subject,
    required String text,
  }) async {
    if (text.trim().isEmpty) {
      return const ShareResult(ok: false, message: '没有可分享的内容');
    }
    try {
      final ok = await _channel
          .invokeMethod<bool>('shareText', {'subject': subject, 'text': text});
      if (ok == true) return const ShareResult.ok();
      return const ShareResult(
        ok: false,
        message: '分享失败：系统里没有能接收文字的 App',
      );
    } on PlatformException catch (e) {
      return ShareResult(
        ok: false,
        message: '分享失败：${e.message ?? e.code}',
      );
    } on MissingPluginException {
      return const ShareResult(ok: false, message: '当前环境不支持系统分享');
    } catch (e) {
      return ShareResult(ok: false, message: '分享失败：$e');
    }
  }
}
