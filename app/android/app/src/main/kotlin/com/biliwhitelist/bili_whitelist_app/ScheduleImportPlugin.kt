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
 * 日程表「导入 Excel」（v2.34.0）：用**系统文件选择器**（Android SAF）拿到
 * 用户挑的 .xlsx 的原始字节。
 *
 * 通道：`bili_whitelist/schedule_import`。Dart 侧封装见
 * lib/services/schedule_import.dart。与 MediaController / ApkInstaller /
 * GalleryController 同风格：非独立插件包，由 MainActivity
 * configureFlutterEngine 手动注册。
 *
 * **为什么是 ACTION_OPEN_DOCUMENT 而不是自己扫 Download 目录**：
 * Android 10+ 的分区存储下，App 拿不到 Download / Documents 的目录列表
 * （除非申请 MANAGE_EXTERNAL_STORAGE 这种高危"所有文件访问"权限，本 App
 * 不可能为了一次导入去要这个）；SAF 是系统给的合法入口——用户自己点选，
 * App 只拿到那**一个**文件的临时读权限，用户还能看到自己选的是什么。
 *
 * **为什么只能用 startActivityForResult**：
 * `registerForActivityResult` 是 androidx `ComponentActivity`（`ActivityResultRegistry`）
 * 的 API，而本项目 MainActivity 继承 `io.flutter.embedding.android.FlutterActivity`
 * —— 它继承的是 `android.app.Activity`，**不是** ComponentActivity，
 * 所以拿不到 `getActivityResultRegistry()`。
 * `startActivityForResult` / `onActivityResult` 在 API 30+ 被标了 deprecated，
 * 但对 Activity 宿主依然是唯一可用路径（Android 官方也仍然支持它跑在这套
 * 分发机制上），因此接受这个 warning。
 *
 * 方法 `pickXlsx()` → 挂起等用户选：
 *  - 用户选中 → `{"name": 文件名, "size": 字节数, "bytes": ByteArray}`
 *  - **用户取消 → `null`**（Dart 侧按"取消"处理，不弹错误）
 *  - 超过 [MAX_BYTES] → error `FILE_TOO_LARGE`（details = 字节数，拿不到就是 -1）
 *  - 读不出来 / 没有文件选择器 → error `READ_FAILED` / `NO_PICKER`
 */
class ScheduleImportPlugin(private val activity: Activity) {

    /** 挂起中的 Dart 调用（一次只允许一个）。 */
    private var pendingResult: MethodChannel.Result? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickXlsx" -> pickXlsx(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickXlsx(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "上一次选择文件还没结束", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = MIME_XLSX
            // 有些选择器（尤其国产 ROM / WPS 自带的那套）只认
            // EXTRA_MIME_TYPES、不认 Intent.type，这里把同一个 MIME 再写一遍。
            // **不放 application/octet-stream 之类的"宽口子"**：那会让用户
            // 能选中任意文件，然后只能靠解析失败来兜——不如一开始就只列表格。
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(MIME_XLSX))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingResult = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQ_PICK)
        } catch (e: Exception) {
            // 设备上没有任何能处理这个 Intent 的 Activity（极简 ROM / 被禁用）
            pendingResult = null
            result.error("NO_PICKER", e.message ?: "没有可用的文件选择器", null)
        }
    }

    /**
     * MainActivity.onActivityResult 转发。
     *
     * 返回值只是给 MainActivity 看"这次结果是不是我要的"（现在都一样处理完整链路，
     * 但保留语义便于将来加第二个选文件入口时区分）。
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
            result.success(readXlsx(uri))
        } catch (e: TooLargeException) {
            result.error("FILE_TOO_LARGE", e.sizeBytes.toString(), null)
        } catch (e: Exception) {
            result.error("READ_FAILED", e.message ?: "读取文件失败", null)
        }
        return true
    }

    /** Activity 销毁（进程退出 / 配置变更重造）时收尾，避免 Dart 侧永远挂着。 */
    fun onActivityDestroyed() {
        val result = pendingResult
        pendingResult = null
        result?.success(null)
    }

    private fun readXlsx(uri: Uri): Map<String, Any> {
        val resolver = activity.contentResolver
        var name = "日程表.xlsx"
        var size = -1L
        // 先问元数据：文件名（仅用于提示）+ 大小（**在读进内存之前**就拦掉超大文件）
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
            ?: throw IllegalStateException("打不开这个文件")
        val bytes = input.use { readCapped(it) }
        if (bytes.isEmpty()) throw IllegalStateException("这个文件是空的")
        return mapOf("name" to name, "size" to bytes.size, "bytes" to bytes)
    }

    /**
     * 读字节，**超过上限立即中断**。
     *
     * 为什么不能只看上面那个 SIZE 字段：有些 provider 返回 -1（大小未知，
     * 比如网盘 / 某些文件管理器给的虚拟文档），这时候只能边读边数；
     * 数到超限就抛，绝不把整个文件吞进内存。
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

    /** 文件超限（[sizeBytes] < 0 表示"读着读着才发现超了"，真实大小未知）。 */
    private class TooLargeException(val sizeBytes: Long) : Exception("文件超过上限")

    companion object {
        private const val CHANNEL = "bili_whitelist/schedule_import"
        private const val REQ_PICK = 9048

        /** 与 Dart 侧 ScheduleImportService.maxFileBytes 保持一致（5 MB）。 */
        private const val MAX_BYTES = 5L * 1024 * 1024

        private const val MIME_XLSX =
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }
}
