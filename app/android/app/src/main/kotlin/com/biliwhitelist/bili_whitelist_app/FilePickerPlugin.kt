package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.TimeUnit

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
 *
 * ## 方法 `pickBookFile()`（E1：导入本地书）
 * 同一套系统选择器，但**不把内容塞进通道**：本地书的上限是 100MB，而书源导入
 * 那条路（读成 String 回传）在 8MB 以内才安全 —— 平台消息要整份拷贝一次，
 * 大文件先 OOM 再谈"能不能传过去"。这里改成：
 *  1. `contentResolver.openInputStream` **流式**拷到
 *     `<filesDir>/reader/incoming/<uuid>.<ext>`（64KB 缓冲，内存占用恒定）；
 *  2. 边拷边数，超过 [MAX_BOOK_BYTES]（100MB）立刻中断并删掉半截文件；
 *  3. 回 `{"name", "path", "sizeBytes", "ext"}`，Dart 侧自己决定读多少。
 *
 * 为什么拷进 App 私有目录而不是回 `content://` URI：SAF 给的临时读权限只在
 * 当前进程、当前生命周期内有效；Dart 侧要「先落盘再解析」时如果中间Activity
 * 重建 / 进程被回收，URI 就失效了。拷一份私有副本是唯一稳的做法（用完 Dart
 * 侧会删，见 `local_book_import_service.dart`）。
 */
class FilePickerPlugin(private val activity: Activity) {

    /** 挂起中的 Dart 调用（一次只允许一个）。 */
    private var pendingResult: MethodChannel.Result? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickTextFile" -> pickTextFile(result)
                    "pickBookFile" -> pickBookFile(result)
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
     * 导入本地书：选文件 → **流式拷进私有目录** → 回路径（见文件头）。
     *
     * MIME 收窄到 txt / epub / pdf / octet-stream：不限定的话某些 ROM 的选择器会把
     * 「文档」以外的类型全隐藏，用户找不到自己的书；收得太窄又会把网盘
     * provider 报成 octet-stream 的 txt 变灰，所以这几个都留着。
     *
     * **PDF（v2.74.0）**：`application/pdf` 必须显式列进来 —— 部分 ROM 的
     * DocumentsUI 会按 EXTRA_MIME_TYPES 严格过滤，只写 `text/plain` +
     * `application/epub+zip` 时 .pdf 是灰的、点不动。通配的 `type` 只是兜底，
     * 真正决定哪些能点的是这一行。
     */
    private fun pickBookFile(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("BUSY", "上一次选择文件还没结束", null)
            return
        }
        cleanupIncoming()
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = MIME_ANY
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(MIME_TEXT, MIME_EPUB, MIME_PDF, MIME_BINARY)
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingResult = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQ_PICK_BOOK)
        } catch (e: Exception) {
            pendingResult = null
            result.error("NO_PICKER", e.message ?: "没有可用的文件选择器", null)
        }
    }

    /**
     * MainActivity.onActivityResult 转发。
     *
     * 返回值只表示"这次结果是不是我要的"（requestCode 与 ScheduleImportPlugin
     * 的 9048、ImagePickPlugin 的 9049 各自错开；本插件的两个方法自己也错开
     * 9050 / 9051，互不串台）。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val isBook = requestCode == REQ_PICK_BOOK
        if (requestCode != REQ_PICK && !isBook) return false
        val result = pendingResult ?: return true
        pendingResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消（按返回键 / 点空白）：**不是错误**，回 null 让 Dart 静默
            result.success(null)
            return true
        }
        try {
            result.success(if (isBook) copyToIncoming(uri) else readText(uri))
        } catch (e: TooLargeException) {
            result.error(
                "FILE_TOO_LARGE",
                if (isBook) "文件太大（超过 100MB）" else "文件太大（超过 8MB）",
                e.sizeBytes.toString()
            )
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

    /**
     * 本地书：把选中文件**流式**拷到 `<filesDir>/reader/incoming/`，回路径。
     *
     * 内存占用只有 64KB 缓冲，与文件大小无关 —— 这是与 `readText`（整份读进
     * 内存）最大的区别，也是 100MB 上限能成立的前提。
     *
     * 中途任何失败（超限 / 读盘错误 / 空文件）都**先删掉半截文件再抛**：
     * 留着半本书的残片，用户下次导入同名文件时排查起来会疯。
     */
    private fun copyToIncoming(uri: Uri): Map<String, Any> {
        val resolver = activity.contentResolver
        var name = "本地书.txt"
        var declaredSize = -1L
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    val raw = cursor.getString(nameIndex)
                    if (!raw.isNullOrEmpty()) name = raw
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    declaredSize = cursor.getLong(sizeIndex)
                }
            }
        }
        // 元数据给了大小就**在拷贝之前**拦掉，省一次 100MB 的无效读写
        if (declaredSize > MAX_BOOK_BYTES) throw TooLargeException(declaredSize)

        val dir = File(activity.filesDir, INCOMING_DIR)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IOException("无法创建导入缓存目录")
        }
        val ext = extensionOf(name, resolver.getType(uri))
        val target = File(dir, "${UUID.randomUUID()}.$ext")
        var total = 0L
        try {
            val input = resolver.openInputStream(uri)
                ?: throw IllegalStateException("打不开这个文件")
            input.use { ins ->
                FileOutputStream(target).use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = ins.read(buf)
                        if (n <= 0) break
                        total += n
                        if (total > MAX_BOOK_BYTES) throw TooLargeException(-1L)
                        out.write(buf, 0, n)
                    }
                    out.flush()
                }
            }
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        if (total == 0L) {
            target.delete()
            throw IllegalStateException("这个文件是空的")
        }
        return mapOf(
            "name" to name,
            "path" to target.absolutePath,
            "sizeBytes" to total,
            "ext" to ext
        )
    }

    /**
     * 清掉超过 24 小时的导入缓存。
     *
     * 正常路径下 Dart 读完就删，但「App 在导入途中被系统杀掉 / 用户直接强退」
     * 会留下整本书的副本。每次选书前顺手清一遍，代价是一次目录遍历。
     */
    private fun cleanupIncoming() {
        try {
            val dir = File(activity.filesDir, INCOMING_DIR)
            if (!dir.isDirectory) return
            val cutoff = System.currentTimeMillis() - TimeUnit.HOURS.toMillis(24)
            dir.listFiles()?.forEach { f ->
                if (f.isFile && f.lastModified() < cutoff) f.delete()
            }
        } catch (_: Exception) {
            // 清不掉不影响导入，交给系统清理
        }
    }

    /**
     * 取扩展名（小写、不含点）：优先用文件名，其次按 MIME 猜，最后 `bin`。
     *
     * 为什么要 ext：Dart 侧用它区分 txt / epub（E3 的 EPUB 解析要按格式分流），
     * 拼在临时文件名里也方便 `run-as` 排查「到底拷进来了什么」。
     */
    private fun extensionOf(name: String, mime: String?): String {
        val dot = name.lastIndexOf('.')
        if (dot >= 0 && dot < name.length - 1) {
            val raw = name.substring(dot + 1).lowercase()
            if (raw.length in 1..5 && raw.all { it.isLetterOrDigit() }) return raw
        }
        return when (mime?.lowercase()) {
            "text/plain" -> "txt"
            "application/epub+zip" -> "epub"
            // 有的 provider 报 application/pdf，有的报 octet-stream；文件名没扩展名
            // 时只能靠 MIME，至少让 .pdf 能落到 pdf 分支（v2.74.0）
            "application/pdf" -> "pdf"
            else -> "bin"
        }
    }

    /** 不是 UTF-8（解出来满地替换字符）。消息直接给用户看。 */
    private class BadEncodingException :
        Exception("这个文件不是 UTF-8 编码（多半是 GBK），请另存为 UTF-8 后再导入")

    companion object {
        private const val CHANNEL = "bili_whitelist/files"

        /** 与 ScheduleImportPlugin 的 9048、ImagePickPlugin 的 9049 错开。 */
        private const val REQ_PICK = 9050

        /** 本地书选文件：与上面 9050 再错开一位，两条路互不串台。 */
        private const val REQ_PICK_BOOK = 9051

        /** 与 Dart 侧 FileImportService.maxFileBytes 保持一致（8 MB）。 */
        private const val MAX_BYTES = 8L * 1024 * 1024

        /** 本地书上限（与 Dart 侧 LocalBookImportService.maxPickedBookBytes 一致）。 */
        private const val MAX_BOOK_BYTES = 100L * 1024 * 1024

        /** 导入缓存目录（相对 `filesDir`）。 */
        private const val INCOMING_DIR = "reader/incoming"

        private const val MIME_ANY = "*/*"
        private const val MIME_JSON = "application/json"
        private const val MIME_TEXT = "text/plain"
        private const val MIME_EPUB = "application/epub+zip"
        private const val MIME_PDF = "application/pdf"
        private const val MIME_BINARY = "application/octet-stream"

        private const val BOM = '\uFEFF'
        private const val REPLACEMENT = '\uFFFD'
    }
}
