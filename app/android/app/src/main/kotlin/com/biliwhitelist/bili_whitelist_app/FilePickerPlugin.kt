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
 * 「从手机里挑一个文本文件」（v2.70.0，书源导入用）：用**系统文件选择器**
 * （Android SAF）拿到用户挑的 .json / .txt 的**文本内容**。
 *
 * 通道：`bili_whitelist/files`，方法与 Dart 侧封装见
 * lib/services/file_import_service.dart（[FileImportService]）。
 * 与 ScheduleImportPlugin / ImagePickPlugin / MediaController 同风格：非独立
 * 插件包，由 MainActivity.configureFlutterEngine 手动注册。
 *
 * **为什么不引 file_picker / file_selector**：同一件事（拉起系统选择器 → 拿一个
 * 文件的字节）已经在这个仓库里跑通两条通道了（Excel 导入、封面选图）；再引依赖
 * 只会多一个包 + 它自带的权限声明，而 SAF 根本不需要任何权限 —— 用户自己点选，
 * App 只拿到那**一个**文件的临时读权限（清单里绝不要为此加
 * READ_EXTERNAL_STORAGE，那是 Android 10+ 分区存储下已经没用的老路子）。
 *
 * **为什么读成 String 再回传，而不是回字节让 Dart 解**：书源 JSON 是纯文本，
 * 解码 + 去 BOM 这两步放在原生只做一次，Dart 侧拿到的就是可以直接丢进
 * `parseBookSourceText` 的字符串（几 MB 的 Uint8List 过一次通道再转 String
 * 只是白搬一遍）。
 *
 * 方法 `pickTextFile()` → 挂起等用户选：
 *  - 用户选中 → `{"name": 文件名, "content": UTF-8 文本, "sizeBytes": 字节数}`
 *  - **用户取消 → `null`**（Dart 侧按"取消"处理，不弹错误）
 *  - 超过 [MAX_BYTES] → error `FILE_TOO_LARGE`（message = 中文文案，details = 字节数）
 *  - 不是 UTF-8（典型：记事本存成 GBK）→ error `BAD_ENCODING`
 *  - 读不出来 / 没有文件选择器 → error `READ_FAILED` / `NO_PICKER`
 */
class FilePickerPlugin(private val activity: Activity) {

    /** 挂起中的 Dart 调用（一次只允许一个）。 */
    private var pendingResult: MethodChannel.Result? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickTextFile" -> pickTextFile(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickTextFile(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "上一次选择文件还没结束", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // type 必须是通配：有的 ROM 自带文件管理器拿具体 MIME 过滤过严，
            // 结果用户「明明看见那个 .json 却选不中」。真正收窄靠下面的
            // EXTRA_MIME_TYPES（各 ROM 的选择器至少认其中一个）。
            type = MIME_ANY
            // application/octet-stream 要留着：部分文件管理器 / 网盘 provider
            // 给 .json 报的类型就是它，不放进来 .json 会变灰不可选。
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(MIME_JSON, MIME_TEXT, MIME_BINARY))
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
     * 返回值只表示"这次结果是不是我要的"（requestCode 与 ScheduleImportPlugin
     * 的 9048、ImagePickPlugin 的 9049 各自错开，三条通道互不串台）。
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
            result.success(readText(uri))
        } catch (e: TooLargeException) {
            result.error("FILE_TOO_LARGE", "文件太大（超过 8MB）", e.sizeBytes.toString())
        } catch (e: BadEncodingException) {
            result.error("BAD_ENCODING", e.message, null)
        } catch (e: Exception) {
            result.error("READ_FAILED", "读取文件失败：${e.message ?: "未知原因"}", null)
        }
        return true
    }

    /** Activity 销毁（进程退出 / 配置变更重造）时收尾，避免 Dart 侧永远挂着。 */
    fun onActivityDestroyed() {
        val result = pendingResult
        pendingResult = null
        result?.success(null)
    }

    private fun readText(uri: Uri): Map<String, Any> {
        val resolver = activity.contentResolver
        var name = "书源.json"
        var size = -1L
        // 先问元数据：文件名（只用于提示）+ 大小（**在读进内存之前**就拦掉超大文件）
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

        // 按 UTF-8 解；带 BOM 时去掉（BOM 留着会让 JSON 解析器把第一个字符
        // 当成非法内容，报一句莫名其妙的「格式不正确」）。
        var content = String(bytes, Charsets.UTF_8)
        if (content.startsWith(BOM)) content = content.substring(1)
        // U+FFFD 是 UTF-8 解码失败的替换字符：命中了说明这个文件根本不是
        // UTF-8（国内用户最常见的 GBK）。这时候把乱码丢给 JSON 解析器，用户
        // 只会看到「格式不正确」，不如直接说清该怎么救。
        if (content.contains(REPLACEMENT)) throw BadEncodingException()
        return mapOf("name" to name, "content" to content, "sizeBytes" to bytes.size)
    }

    /**
     * 读字节，**超过上限立即中断**。
     *
     * 为什么不能只看上面那个 SIZE 字段：有些 provider 返回 -1（大小未知，
     * 比如网盘 / 某些文件管理器给的虚拟文档），这时候只能边读边数；数到超限
     * 就抛，绝不把整个文件吞进内存。
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

    /** 不是 UTF-8（解出来满地替换字符）。消息直接给用户看。 */
    private class BadEncodingException :
        Exception("这个文件不是 UTF-8 编码（多半是 GBK），请另存为 UTF-8 后再导入")

    companion object {
        private const val CHANNEL = "bili_whitelist/files"

        /** 与 ScheduleImportPlugin 的 9048、ImagePickPlugin 的 9049 错开。 */
        private const val REQ_PICK = 9050

        /** 与 Dart 侧 FileImportService.maxFileBytes 保持一致（8 MB）。 */
        private const val MAX_BYTES = 8L * 1024 * 1024

        private const val MIME_ANY = "*/*"
        private const val MIME_JSON = "application/json"
        private const val MIME_TEXT = "text/plain"
        private const val MIME_BINARY = "application/octet-stream"

        private const val BOM = '\uFEFF'
        private const val REPLACEMENT = '\uFFFD'
    }
}
