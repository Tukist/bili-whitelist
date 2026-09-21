package com.biliwhitelist.bili_whitelist_app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内版本更新（M1.3）：触发系统 APK 安装流程。
 *
 * Dart 侧通过 MethodChannel `app.apk_installer` 调 `install` 方法传 APK 本地绝对路径，
 * 原生侧走 FileProvider 暴露 `content://{applicationId}.fileprovider/support/...` 给
 * 系统安装器，避免 API 24+ 直接传 file:// 抛 FileUriExposedException。
 *
 * authority 与 AndroidManifest 中 <provider> 的 `android:authorities` 严格一致
 * （`${applicationId}.fileprovider`）。
 *
 * v2.46.0 新增两个方法（「安装未知应用」权限的前置检查与引导）：
 *  - `canInstallUnknownApps() -> Boolean`：Android 8+ 的
 *    `PackageManager.canRequestPackageInstalls()`。系统设置里「安装未知应用」被关掉时，
 *    `startActivity` 会**静默失败/被系统拒绝**，报出来的错又说不清原因（历史 bug：被
 *    当成「下载失败：未知错误」甩给用户）。Dart 侧先问这个方法，未开启就直接给引导文案。
 *  - `openUnknownSourcesSettings() -> void`：跳 `ACTION_MANAGE_UNKNOWN_APP_SOURCES`
 *    （带本应用包名直达）；个别 ROM 没这个页面时退化到应用详情页。
 *
 * 另外 `install` 现在自己做一遍权限检查（兜底，防「检查与安装之间权限被撤」），
 * 以及 `INSTALL_FAILED` 的原因不再用兜底「未知错误」——异常类名比那四个字有用得多。
 */
class ApkInstaller(private val context: Context) {

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("INVALID_ARG", "path 不能为空", null)
                            return@setMethodCallHandler
                        }
                        // 兜底权限检查：未开启「安装未知应用」时直接 startActivity 必然
                        // 被系统拒绝，先报一个**能读懂**的错误码，Dart 侧据此给引导 + 跳设置。
                        if (!canInstallUnknownApps()) {
                            Log.w(TAG, "install 被拒：未开启「安装未知应用」")
                            result.error(
                                "NEED_UNKNOWN_SOURCES",
                                "未开启「安装未知应用」权限，请到系统设置里允许 amoTV 安装应用",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                Log.w(TAG, "install 失败：APK 不存在 $path")
                                result.error(
                                    "NOT_FOUND",
                                    "APK 文件不存在：$path",
                                    null,
                                )
                                return@setMethodCallHandler
                            }
                            val authority = "${context.packageName}.fileprovider"
                            val uri = FileProvider.getUriForFile(context, authority, file)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive",
                                )
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK,
                                )
                            }
                            context.startActivity(intent)
                            Log.i(TAG, "install 已交给系统安装器：${file.name}")
                            result.success(null)
                        } catch (e: Exception) {
                            // 如实透出原因：类名 + message（例：ActivityNotFoundException:
                            // No Activity found to handle Intent）。旧的 `?: "未知错误"`
                            // 让线上报错完全无法取证。
                            Log.w(TAG, "install 异常：${e.javaClass.simpleName} ${e.message}", e)
                            result.error(
                                "INSTALL_FAILED",
                                "${e.javaClass.simpleName}: ${e.message ?: "无 message"}",
                                null,
                            )
                        }
                    }
                    "canInstallUnknownApps" -> {
                        result.success(canInstallUnknownApps())
                    }
                    "openUnknownSourcesSettings" -> {
                        try {
                            context.startActivity(unknownSourcesSettingsIntent())
                            Log.i(TAG, "已跳转「安装未知应用」设置页")
                            result.success(null)
                        } catch (e: ActivityNotFoundException) {
                            // 个别 ROM 没有这个页面 → 退化到本应用详情页，用户至少能自己找。
                            try {
                                context.startActivity(appDetailsSettingsIntent())
                                Log.w(TAG, "无「安装未知应用」页面，退化到应用详情页")
                                result.success(null)
                            } catch (e2: Exception) {
                                Log.w(TAG, "跳设置页失败：${e2.javaClass.simpleName} ${e2.message}")
                                result.error(
                                    "SETTINGS_UNAVAILABLE",
                                    e2.message ?: e2.javaClass.simpleName,
                                    null,
                                )
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "跳设置页失败：${e.javaClass.simpleName} ${e.message}")
                            result.error(
                                "SETTINGS_UNAVAILABLE",
                                e.message ?: e.javaClass.simpleName,
                                null,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Android 8.0+ 的「安装未知应用」开关是否已允许本应用安装 APK。
     *
     * min_sdk=26（Android 8.0）→ 该 API 恒可用；版本判断留着只是为了让意图显式，
     * 万一将来降 min_sdk 也不会崩。查询本身抛异常（极罕见）→ 按「允许」处理：
     * 让系统安装器自己拦一下，比把用户堵在门外好，且 Dart 侧会拿到可读的拒绝原因。
     */
    private fun canInstallUnknownApps(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                context.packageManager.canRequestPackageInstalls()
            } catch (e: Exception) {
                Log.w(TAG, "查询 canRequestPackageInstalls 失败：${e.javaClass.simpleName}")
                true
            }
        } else {
            true
        }

    /** 「安装未知应用」设置页（带本应用包名直达）。applicationContext 启动 → 必须 NEW_TASK。 */
    private fun unknownSourcesSettingsIntent(): Intent =
        Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** 退路：本应用详情页（用户可以自己找「安装未知应用」）。 */
    private fun appDetailsSettingsIntent(): Intent =
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    companion object {
        private const val CHANNEL = "app.apk_installer"
        private const val TAG = "ApkInstaller"
    }
}
