package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * 「从相册选一张图」（v2.50.0，合集封面用）：用**系统图片选择器**（Android SAF）
 * 拿到用户挑的那张图的原始字节。
 *
 * 通道：`bili_whitelist/pick_image`。Dart 侧封装见
 * lib/services/image_pick_service.dart。与 ScheduleImportPlugin /
 * MediaController / ApkInstaller / GalleryController 同风格：非独立插件包，
 * 由 MainActivity configureFlutterEngine 手动注册（理由见
 * ScheduleImportPlugin 的文件头：本仓库不做独立插件包）。
 *
 * **为什么复用 ScheduleImportPlugin 这一套（而不是引 image_picker）**：
 * 同一件事（拉起系统选择器 → 拿一个文件的字节）已经在这条通道上跑通了；引
 * image_picker 要多一个依赖 + 它自带权限声明，而 SAF 根本不需要任何权限 ——
 * 用户自己点选，App 只拿到那**一张**图的临时读权限。
 *
 * **为什么 type 用 image 通配（MIME_IMAGE）而不是具体 MIME**：相册里的格式
 * 五花八门（jpeg / png / webp / heic），写死一种会让用户「明明能看见却选不了」；
 * image 通配已经足够窄（不会让人误选到视频或文档），且各 ROM 的相册都认它。
 * （注意：这里不能把那个通配符写成斜杠加星号 —— Kotlin 的块注释是**可嵌套**的，
 * 注释里出现斜杠星号会开出一层嵌套注释，文件末尾直接报 Unclosed comment。）
 *
 * 方法 `pickImage()` → 挂起等用户选：
 *  - 用户选中 → `{"name": 文件名, "size": 字节数, "bytes": ByteArray}`
 *  - **用户取消 → `null`**（Dart 侧按"取消"处理，不弹错误、不改任何东西）
 *  - 超过 [MAX_BYTES] → error `FILE_TOO_LARGE`（details = 字节数，拿不到就是 -1）
 *  - 读不出来 / 没有选择器 → error `READ_FAILED` / `NO_PICKER`
 */
class ImagePickPlugin(private val activity: Activity) {

    /** 挂起中的 Dart 调用（一次只允许一个）。 */
    private var pendingResult: MethodChannel.Result? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> pickImage(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickImage(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "上一次选择图片还没结束", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = MIME_IMAGE
            // 有些选择器（国产 ROM 自带相册）只认 EXTRA_MIME_TYPES，不认
            // Intent.type，这里把同一个 MIME 再写一遍。
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(MIME_IMAGE))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingResult = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQ_PICK)
        } catch (e: Exception) {
            // 设备上没有任何能处理这个 Intent 的 Activity（极简 ROM / 被禁用）
            pendingResult = null
            result.error("NO_PICKER", e.message ?: "没有可用的图片选择器", null)
        }
    }

    /**
     * MainActivity.onActivityResult 转发。
     *
     * 返回值只是给 MainActivity 看"这次结果是不是我要的"（requestCode 与
     * ScheduleImportPlugin 各自不同，两条通道互不干扰）。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PICK) return false
        val result = pendingResult ?: return true
        pendingResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消（按返回键 / 点空白）：**不是错误**，回 null 让 Dart 静默
            result.success(null)
            return true
        }
        try {
            result.success(readImage(uri))
        } catch (e: TooLargeException) {
            result.error("FILE_TOO_LARGE", e.sizeBytes.toString(), null)
        } catch (e: Exception) {
            result.error("READ_FAILED", e.message ?: "读取图片失败", null)
        }
        return true
    }

    /** Activity 销毁（进程退出 / 配置变更重造）时收尾，避免 Dart 侧永远挂着。 */
    fun onActivityDestroyed() {
        val result = pendingResult
        pendingResult = null
        result?.success(null)
    }

    private fun readImage(uri: Uri): Map<String, Any> {
        val resolver = activity.contentResolver
        var name = "封面.jpg"
        var size = -1L
        // 先问元数据：文件名（取扩展名）+ 大小（**在读进内存之前**就拦掉超大图）
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    val raw = cursor.getString(nameIndex)
                    if (!raw.isNullOrEmpty()) name = raw
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    size = cursor.getLong(sizeIndex)
                }
            }
        }
        if (size > MAX_BYTES) throw TooLargeException(size)
        val input = resolver.openInputStream(uri)
            ?: throw IllegalStateException("打不开这张图片")
        val bytes = input.use { readCapped(it) }
        if (bytes.isEmpty()) throw IllegalStateException("这张图片是空的")
        return mapOf("name" to name, "size" to bytes.size, "bytes" to bytes)
    }

    /**
     * 读字节，**超过上限立即中断**。
     *
     * 为什么不能只看上面那个 SIZE 字段：有些 provider 返回 -1（大小未知，
     * 比如网盘 / 云相册给的虚拟文档），这时候只能边读边数；数到超限就抛，
     * 绝不把整张图吞进内存。
     */
    private fun readCapped(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(buf)
            if (n <= 0) break
            total += n
            if (total > MAX_BYTES) throw TooLargeException(-1L)
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /** 图片超限（[sizeBytes] < 0 表示"读着读着才发现超了"，真实大小未知）。 */
    private class TooLargeException(val sizeBytes: Long) : Exception("图片超过上限")

    companion object {
        private const val CHANNEL = "bili_whitelist/pick_image"

        /** 与 ScheduleImportPlugin 的 9048 错开，两条通道的 result 互不串台。 */
        private const val REQ_PICK = 9049

        /** 与 Dart 侧 ImagePickService.maxImageBytes 保持一致（10 MB）。 */
        private const val MAX_BYTES = 10L * 1024 * 1024

        private const val MIME_IMAGE = "image/*"
    }
}
