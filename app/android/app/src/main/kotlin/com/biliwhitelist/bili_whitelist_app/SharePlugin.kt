package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统分享面板（v2.62.0 文本；v2.67.0 加文件）。
 *
 * 通道：`bili_whitelist/share`，方法与 Dart 侧封装见
 * lib/services/share_service.dart（[ShareService]）。
 *
 * 方法：
 *  - shareText(subject: String, text: String) -> Boolean
 *    调起系统选择器；`true` = 已调起，`false` = 系统里没有任何 App 能接收
 *    `text/plain`（Dart 侧据此给一句可读提示）。
 *  - shareFile(path: String, mimeType: String, subject: String) -> Boolean
 *    v2.67.0：「个人 → 诊断日志 → 导出日志」用。把应用私有目录下的文件用
 *    `FileProvider` 换成 `content://` URI 再 `ACTION_SEND` + `EXTRA_STREAM`。
 *    不需要任何权限（`file_paths.xml` 已经把 `getFilesDir()` 根映射成
 *    `support`，日志在 `<filesDir>/logs/` 下天然在白名单里）。
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
                    "shareFile" -> {
                        val subject = call.argument<String>("subject") ?: ""
                        val mime = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("BAD_ARGS", "缺少 path 参数", null)
                            return@setMethodCallHandler
                        }
                        shareFile(path, mime, subject, result)
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

    /**
     * 分享一个应用私有目录下的文件（v2.67.0：诊断日志 zip）。
     *
     * ## 为什么要 FileProvider
     *
     * API 24+ 直接传 `file://` URI 会抛 `FileUriExposedException`；清单里已经
     * 有 `${applicationId}.fileprovider`（M1.3 给安装器用的），
     * `res/xml/file_paths.xml` 把 `getFilesDir()` 根映射成 `support`，所以
     * `<filesDir>/logs/xxx.zip` 换成 `content://<pkg>.fileprovider/support/logs/xxx.zip`
     * —— **清单与路径白名单零改动**。
     *
     * ## 国产 ROM 的权限传递
     *
     * 只有 `FLAG_GRANT_READ_URI_PERMISSION` 时，个别 ROM（把分享面板做成
     * 独立任务栈 / 二次转发的 ROM）会丢掉 grant，接收方打开时
     * `SecurityException: Permission Denial`。做法同 `ApkInstaller.kt`：
     * 把 URI 同时塞进 `clipData` —— 系统会按 clipData 里的 URI 一并授权，
     * 这是官方 issue 里给出的兼容写法，不带也不影响 AOSP。
     */
    private fun shareFile(
        path: String,
        mimeType: String,
        subject: String,
        result: MethodChannel.Result,
    ) {
        activity.runOnUiThread {
            try {
                val file = File(path)
                if (!file.exists()) {
                    Log.w(TAG, "分享失败：文件不存在 $path")
                    result.error("NOT_FOUND", "文件不存在：$path", null)
                    return@runOnUiThread
                }
                val authority = "${activity.packageName}.fileprovider"
                val uri = FileProvider.getUriForFile(activity, authority, file)
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mimeType
                    putExtra(Intent.EXTRA_STREAM, uri)
                    putExtra(Intent.EXTRA_SUBJECT, subject)
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_ACTIVITY_NEW_TASK,
                    )
                    // 包可见性（API 30+）：给国产 ROM 留的第二条授权通道
                    clipData = ClipData.newRawUri(subject.ifBlank { file.name }, uri)
                }
                val handlers = activity.packageManager
                    .queryIntentActivities(send, 0)
                if (handlers.isEmpty()) {
                    Log.w(TAG, "分享失败：没有 App 能接收 $mimeType")
                    result.success(false)
                    return@runOnUiThread
                }
                val title = subject.ifBlank { DEFAULT_CHOOSER_TITLE }
                val chooser = Intent.createChooser(send, title).apply {
                    // 读权限也挂在 chooser 上：部分 ROM 是"先起 chooser 再转发"，
                    // 只在内层 Intent 上带 grant 会被中间那一层吃掉。
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_ACTIVITY_NEW_TASK,
                    )
                }
                activity.startActivity(chooser)
                result.success(true)
            } catch (e: Exception) {
                // FileProvider 未配置 / 路径不在白名单 / ROM 拦截都会落这里
                Log.w(TAG, "分享文件失败：${e.javaClass.simpleName} ${e.message}")
                result.error(
                    "SHARE_FAILED",
                    "${e.javaClass.simpleName}: ${e.message ?: "调起分享面板失败"}",
                    null,
                )
            }
        }
    }
}
