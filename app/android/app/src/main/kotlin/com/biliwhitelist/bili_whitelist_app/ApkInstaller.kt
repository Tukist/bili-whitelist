package com.biliwhitelist.bili_whitelist_app

import android.content.Context
import android.content.Intent
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
                        try {
                            val file = File(path)
                            if (!file.exists()) {
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
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message ?: "未知错误", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        private const val CHANNEL = "app.apk_installer"
    }
}
