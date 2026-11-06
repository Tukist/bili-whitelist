package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 系统分享面板（v2.62.0）。
 *
 * 通道：`bili_whitelist/share`，方法与 Dart 侧封装见
 * lib/services/share_service.dart（[ShareService]）。
 *
 * 方法：
 *  - shareText(subject: String, text: String) -> Boolean
 *    调起系统选择器；`true` = 已调起，`false` = 系统里没有任何 App 能接收
 *    `text/plain`（Dart 侧据此给一句可读提示）。
 *
 * ## 为什么是 ACTION_SEND + createChooser
 *
 * - **不需要任何权限**：分享是系统级 Intent，本 App 既不读也不写别人的数据；
 * - `FLAG_ACTIVITY_NEW_TASK`：本是 Activity 上下文能直接 startActivity，但
 *   chooser 在部分 ROM（把分享面板做成独立任务栈的国产 ROM）下不带这个标志会
 *   抛 `AndroidRuntimeException: Calling startActivity() from outside of an
 *   Activity context requires the FLAG_ACTIVITY_NEW_TASK flag`，带上无害；
 * - `createChooser`：不指定包名的 ACTION_SEND 会被系统直接派给"默认应用"，
 *   用户看不到面板；套 chooser 才是「让用户自己挑发给谁」。chooser 的 title
 *   用视频标题（[Intent.EXTRA_SUBJECT]），没有标题时退回「分享」。
 *
 * ## 「没有 App 能收」为什么要先查一次
 *
 * `createChooser` **总是**能起来（系统会显示一个空面板/提示），所以
 * `startActivity` 不会抛 `ActivityNotFoundException` —— 不查的话「分享失败」
 * 这条分支永远不会触发，用户只会看到一个空面板。`queryIntentActivities` 在
 * API 30+ 受包可见性限制，因此 AndroidManifest 里补了一条
 * `<queries><intent android:action="android.intent.action.SEND">`
 * （见清单注释），否则这里永远查到空列表、把正常设备误判成"没有 App"。
 *
 * 与 ApkInstaller / MediaController / KeepScreenOnPlugin 同风格：非独立插件包，
 * 由 MainActivity.configureFlutterEngine 手动注册。
 */
class SharePlugin(private val activity: Activity) {

    companion object {
        private const val CHANNEL = "bili_whitelist/share"
        private const val TAG = "bili_whitelist"

        /** 选择器标题的兜底文案（视频标题为空时用）。 */
        private const val DEFAULT_CHOOSER_TITLE = "分享"
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareText" -> {
                        val subject = call.argument<String>("subject") ?: ""
                        val text = call.argument<String>("text")
                        if (text.isNullOrBlank()) {
                            result.error("BAD_ARGS", "缺少 text 参数", null)
                            return@setMethodCallHandler
                        }
                        shareText(subject, text, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 在 UI 线程调起系统分享面板（Intent 的解析与 startActivity 都必须在
     * Activity 所在线程；Dart 侧调用线程不保证）。
     *
     * 结果三态：`true` 已调起 / `false` 没有可接收的 App / error 调起失败
     * ——Dart 侧三种都转成一句话，不抛到界面。
     */
    private fun shareText(subject: String, text: String, result: MethodChannel.Result) {
        activity.runOnUiThread {
            try {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, subject)
                    putExtra(Intent.EXTRA_TEXT, text)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val handlers = activity.packageManager
                    .queryIntentActivities(send, 0)
                if (handlers.isEmpty()) {
                    Log.w(TAG, "分享失败：没有 App 能接收 text/plain")
                    result.success(false)
                    return@runOnUiThread
                }
                val title = subject.ifBlank { DEFAULT_CHOOSER_TITLE }
                val chooser = Intent.createChooser(send, title).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                activity.startActivity(chooser)
                result.success(true)
            } catch (e: Exception) {
                // 典型：Activity 已在销毁（用户恰在此刻返回）、ROM 禁止跨应用
                // 调起。都属于"分享没成功"，给 Dart 侧一句可读原因即可。
                Log.w(TAG, "分享失败：${e.javaClass.simpleName} ${e.message}")
                result.error("SHARE_FAILED", e.message ?: "调起分享面板失败", null)
            }
        }
    }
}
