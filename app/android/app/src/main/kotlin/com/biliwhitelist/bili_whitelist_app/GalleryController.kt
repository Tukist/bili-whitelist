package com.biliwhitelist.bili_whitelist_app

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * 评论图片「保存到系统相册」（v2.16.19+）：
 *
 * 通道：`bili_whitelist/gallery`。Dart 侧封装见 lib/services/gallery_saver.dart。
 * 与 MediaController / ApkInstaller 同风格：非独立插件包，由 MainActivity
 * configureFlutterEngine 手动注册。
 *
 * 方法 `saveImage(bytes, fileName, mimeType)`：
 *  - Android 10+（API 29+，主流）：MediaStore.Images 插入
 *    `Pictures/BiliWhiteList` 目录（RELATIVE_PATH + IS_PENDING 两步写入），
 *    **无需任何存储权限**；
 *  - Android 8/9（API 26~28，minSdk 26 需覆盖）：老式公开目录
 *    `Pictures/BiliWhiteList` + MediaScanner 广播，需要
 *    WRITE_EXTERNAL_STORAGE（Manifest 已用 maxSdkVersion=28 声明，只在
 *    26~28 系统上出现）。未授权时弹系统授权框，结果在
 *    [onRequestPermissionsResult] 里补完保存——**一次 Dart 调用搞定**
 *    （授权框出现期间 Dart await 挂起，用户点完继续返回保存结果）。
 *
 * 返回 `{"status":"saved", "uri"/"path": ...}`；失败走 result.error
 * （code=PERMISSION_DENIED / GALLERY_FAILED，Dart 展示中文文案）。
 */
class GalleryController(private val activity: Activity) {

    // <29 授权挂起态：requestPermissions 后由 MainActivity
    // onRequestPermissionsResult 转发回来补完保存。
    private var pendingSave: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null
    private var pendingFileName = ""
    private var pendingMime = "image/jpeg"

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "saveImage" -> onSaveImage(call, result)
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("GALLERY_FAILED", e.message ?: "未知错误", null)
                }
            }
    }

    private fun onSaveImage(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        val fileName = sanitizeFileName(
            call.argument<String>("fileName") ?: "bili_comment_${System.currentTimeMillis()}.jpg"
        )
        val mime = call.argument<String>("mimeType") ?: "image/jpeg"
        if (bytes == null || bytes.isEmpty()) {
            result.error("BAD_ARG", "图片数据为空", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            result.success(saveToMediaStore(bytes, fileName, mime))
            return
        }
        // API 26~28：老式公开目录写入需 WRITE_EXTERNAL_STORAGE 运行时权限
        if (hasStoragePermission()) {
            result.success(saveLegacyPicturesDir(bytes, fileName, mime))
            return
        }
        if (pendingSave != null) {
            result.error("BUSY", "上一次保存仍在进行中，请稍候再试", null)
            return
        }
        pendingSave = result
        pendingBytes = bytes
        pendingFileName = fileName
        pendingMime = mime
        @Suppress("DEPRECATION")
        activity.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQ_STORAGE)
        // 保存结果在 onRequestPermissionsResult 里补（用户授权框期间 Dart await）
    }

    /** MainActivity.onRequestPermissionsResult 转发：授权后补完挂起的保存。 */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQ_STORAGE) return
        val result = pendingSave
        val bytes = pendingBytes
        pendingSave = null
        pendingBytes = null
        if (result == null || bytes == null) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            result.error("PERMISSION_DENIED", "存储权限被拒绝，无法保存到相册", null)
            return
        }
        try {
            result.success(saveLegacyPicturesDir(bytes, pendingFileName, pendingMime))
        } catch (e: Exception) {
            result.error("GALLERY_FAILED", e.message ?: "保存失败", null)
        }
    }

    /** API 29+：MediaStore.Images 插入（免权限），两步写入（IS_PENDING 防相册闪半成品）。 */
    private fun saveToMediaStore(bytes: ByteArray, fileName: String, mime: String): Map<String, String> {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/BiliWhiteList")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("相册写入失败（无法创建媒体条目）")
        try {
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("相册写入失败（无法打开输出流）")
            out.use { it.write(bytes) }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null) // 失败清理半成品条目
            throw e
        }
        return mapOf("status" to "saved", "uri" to uri.toString())
    }

    /** API 26~28：写公开 Pictures/BiliWhiteList 目录 + 触发媒体扫描。 */
    private fun saveLegacyPicturesDir(bytes: ByteArray, fileName: String, mime: String): Map<String, String> {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "BiliWhiteList"
        )
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建相册目录（请检查存储空间/权限）")
        }
        val file = File(dir, fileName)
        FileOutputStream(file).use { it.write(bytes) }
        MediaScannerConnection.scanFile(
            activity,
            arrayOf(file.absolutePath),
            arrayOf(mime),
            null
        )
        return mapOf("status" to "saved", "path" to file.absolutePath)
    }

    private fun hasStoragePermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    /** 文件名清洗：只留字母数字 . _ -（防路径注入/非法字符），并确保带扩展名。 */
    private fun sanitizeFileName(raw: String): String {
        var name = raw.replace(Regex("[^A-Za-z0-9._\\-]"), "_")
        if (name.isEmpty()) name = "bili_comment_${System.currentTimeMillis()}.jpg"
        val hasExt = Regex("\\.[A-Za-z0-9]{1,5}$").containsMatchIn(name)
        if (!hasExt) name += ".jpg"
        return name
    }

    companion object {
        private const val CHANNEL = "bili_whitelist/gallery"
        private const val REQ_STORAGE = 9047
    }
}
