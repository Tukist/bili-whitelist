package com.biliwhitelist.bili_whitelist_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * PDF 页渲染（v2.74.0，本地书 PDF 支持）：把一页 PDF 渲染成 PNG 落盘，Dart 只拿路径。
 *
 * 通道：`bili_whitelist/pdf`，Dart 侧封装见 `lib/services/pdf_renderer_bridge.dart`
 * （[NativePdfRenderer]）。与 FilePickerPlugin 一样由 MainActivity
 * `configureFlutterEngine` **手动注册**（本项目的约定，不走 GeneratedPluginRegistrant）。
 *
 * ## 为什么用系统自带的 `PdfRenderer`
 * Android 从 API 21 起自带 PdfRenderer（本项目 minSdk 26），它够用：读页数、按任意
 * 缩放把一页画进 Bitmap。引 pdfium / pdfx / mupdf 任何一个都会让 APK 变大十几 MB，
 * 而这里需要的只是「把页面画成图片」——不解析文字、不做表单、不做加密。
 * 代价也要写清：**PDF 里的文字选不中**（画面已经是像素），这是渲染方案的天花板，
 * 不是 bug。
 *
 * ## 为什么位图不回传、只回文件路径
 * 一张 1080 宽的书页 ≈ 1080×1527×4 ≈ 6.6MB。走 MethodChannel 回传位图要整份拷贝
 * 进平台消息（Binder 事务上限 1MB，大块会走共享内存但依然要复制），翻十页就能
 * 把低端机打崩。所以这里统一：**渲染结果压成 PNG 写进应用目录，只回路径**，
 * 由 Dart 用 `Image.file` 交给 Flutter 的图片缓存去解码与复用（它自己有内存上限
 * 与淘汰）。封面是唯一例外（很小，见 [renderCover]）。
 *
 * ## 串行是硬约束
 * `PdfRenderer` **不能并发使用**（同一个文档同时 openPage 两个页会抛异常，多个
 * 实例并发也很容易触发 native 崩）。这里做了两层：
 * 1. 所有渲染操作丢进**单线程** `worker`（`newSingleThreadExecutor`），天然串行；
 * 2. 真正的渲染段外面再套 `synchronized(renderLock)`，防止将来有人改成多线程池。
 * 另外 `openPage` / `close`、`PdfRenderer` / `ParcelFileDescriptor` **必须成对**：
 * 文件描述符泄漏后同一本 PDF 会「后面再也打不开」，这是实测踩过的，所以全部
 * 用 `try/finally` 或 `use`，不留「正常路径才关」的写法。
 *
 * ## 缓存
 * `<filesDir>/reader/pdfcache/<cacheKey>/<页号>@<宽度>.png`。
 * cacheKey 由 Dart 传（就是本地书 id，纯 `[0-9a-z]`），**不按路径哈希**：书目录
 * 可能被挪动，而 id 是稳定的，删书时 Dart 直接用同一个 key 调 `clearCache`。
 * 同一页同一宽度命中已有文件就直接回路径（先 `inJustDecodeBounds` 读尺寸，不
 * 解码整张图）。「按上限淘汰」的策略在 Dart 侧（`lib/services/pdf_cache_policy.dart`
 * 的纯函数），原生只提供 `cacheFiles` / `deleteCacheFiles` 两个原语 —— 策略放
 * 纯函数里才测得了，放 Kotlin 里只能靠肉眼。
 *
 * ## 方法
 * - `openPdf(path)` → `{pageCount, width, height}`（首开尺寸，用于算长宽比）
 * - `renderCover(path, targetWidthPx)` → `{bytes, width, height}`（封面很小，直接回字节）
 * - `renderPage(path, index, targetWidthPx, cacheKey)` → `{path, width, height, bytes}`
 * - `clearCache(cacheKey)` → 删掉的文件数
 * - `cacheFiles()` → `[{path, bookKey, bytes, modified}]`（淘汰策略的输入）
 * - `deleteCacheFiles(paths)` → 删掉的文件数（**只允许删 pdfcache 目录内的文件**）
 *
 * 错误码（Dart 侧统一翻成中文，见 `pdf_renderer_bridge.dart`）：
 * `FILE_NOT_FOUND` / `NOT_PDF` / `ENCRYPTED` / `PAGE_OUT_OF_RANGE` / `RENDER_FAILED`。
 */
class PdfRenderPlugin(private val filesDir: File) {

    /** 渲染队列：单线程 = 串行，`PdfRenderer` 的前提。 */
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "pdf-render").apply { isDaemon = true }
    }

    /** 结果必须回主线程（MethodChannel 的约定）。 */
    private val handler = Handler(Looper.getMainLooper())

    /** 第二道串行保险（见文件头「串行是硬约束」）。 */
    private val renderLock = Any()

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openPdf" -> onWorker(result) {
                        openPdf(call.argument<String>("path") ?: "")
                    }
                    "renderCover" -> onWorker(result) {
                        renderCover(
                            call.argument<String>("path") ?: "",
                            call.argument<Int>("targetWidthPx") ?: COVER_WIDTH,
                        )
                    }
                    "renderPage" -> onWorker(result) {
                        renderPage(
                            path = call.argument<String>("path") ?: "",
                            index = call.argument<Int>("index") ?: 0,
                            targetWidthPx = call.argument<Int>("targetWidthPx") ?: DEFAULT_WIDTH,
                            cacheKey = call.argument<String>("cacheKey") ?: "",
                        )
                    }
                    "clearCache" -> onWorker(result) {
                        clearCache(call.argument<String>("cacheKey") ?: "")
                    }
                    "cacheFiles" -> onWorker(result) { cacheFiles() }
                    "deleteCacheFiles" -> onWorker(result) {
                        deleteCacheFiles(call.argument<List<String>>("paths") ?: emptyList())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 在 worker 线程跑 [block]，结果 / 异常回主线程。
     *
     * 为什么要异步：渲染一页 1080 宽的图在低端机上要 100~400ms，直接在主线程做
     * 会卡住整个 Flutter UI（滚动、点击都停）。单线程池顺带解决了串行问题。
     */
    private fun onWorker(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                handler.post { result.success(value) }
            } catch (e: PdfFailure) {
                handler.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                handler.post {
                    result.error(
                        "RENDER_FAILED",
                        "这一页渲染失败（${e.javaClass.simpleName}）",
                        null,
                    )
                }
            }
        }
    }

    // ==================== 方法实现 ====================

    private fun openPdf(path: String): Map<String, Any> = synchronized(renderLock) {
        val file = requireFile(path)
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
            val renderer = openRenderer(pfd)
            try {
                val count = renderer.pageCount
                if (count <= 0) throw PdfFailure("NOT_PDF", "这个 PDF 里没有页面")
                val page = renderer.openPage(0)
                try {
                    mapOf(
                        "pageCount" to count,
                        "width" to page.width,
                        "height" to page.height,
                    )
                } finally {
                    page.close()
                }
            } finally {
                renderer.close()
            }
        }
    }

    /**
     * 封面：第一页渲染成小图，**回字节**（不落缓存目录）。
     *
     * 为什么封面可以回字节：400 宽的 PNG 一般 30~120KB，走通道毫无压力；而写进
     * 缓存目录反而要额外考虑「导入阶段的临时 key 谁来清」。
     */
    private fun renderCover(path: String, targetWidthPx: Int): Map<String, Any> =
        synchronized(renderLock) {
            val file = requireFile(path)
            val width = targetWidthPx.coerceIn(MIN_WIDTH, MAX_WIDTH)
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
                val renderer = openRenderer(pfd)
                try {
                    val page = renderer.openPage(0)
                    try {
                        val w = width
                        val h = (page.height.toFloat() * (w.toFloat() / page.width.toFloat()))
                            .roundToInt().coerceAtLeast(1)
                        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        val out = ByteArrayOutputStream()
                        try {
                            val canvas = Canvas(bitmap)
                            // 透明底渲染出来在深色书架上是「黑页」，先铺白
                            canvas.drawColor(Color.WHITE)
                            page.render(bitmap, null, matrixFor(page, w, h), PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                        } finally {
                            bitmap.recycle()
                        }
                        return@use mapOf(
                            "bytes" to out.toByteArray(),
                            "width" to w,
                            "height" to h,
                        )
                    } finally {
                        page.close()
                    }
                } finally {
                    renderer.close()
                }
            }
        }

    private fun renderPage(
        path: String,
        index: Int,
        targetWidthPx: Int,
        cacheKey: String,
    ): Map<String, Any> = synchronized(renderLock) {
        val file = requireFile(path)
        val key = sanitizeKey(cacheKey)
        val width = targetWidthPx.coerceIn(MIN_WIDTH, MAX_WIDTH)
        val target = File(File(cacheRoot(), key), "$index@$width.png")

        // 命中缓存：只读文件头拿宽高，不解码整张图
        if (target.isFile && target.length() > 0L) {
            val bounds = decodeBounds(target)
                ?: throw PdfFailure("RENDER_FAILED", "这一页渲染失败（缓存文件已损坏）")
            return@synchronized mapOf(
                "path" to target.absolutePath,
                "width" to bounds.first,
                "height" to bounds.second,
                "bytes" to target.length(),
            )
        }

        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
            val renderer = openRenderer(pfd)
            try {
                if (index < 0 || index >= renderer.pageCount) {
                    throw PdfFailure("PAGE_OUT_OF_RANGE", "页号越界（这本 PDF 共 ${renderer.pageCount} 页）")
                }
                val page = renderer.openPage(index)
                try {
                    var w = width
                    var h = (page.height.toFloat() * (w.toFloat() / page.width.toFloat()))
                        .roundToInt().coerceAtLeast(1)
                    // 8MB 位图预算：ARGB_8888 是 4 字节/像素，超了不是「慢」而是 OOM。
                    // 做法是等比缩小宽度（不降质量：文字页降 JPEG 质量会糊成一团）。
                    while (w.toLong() * h * 4 > MAX_BITMAP_BYTES && w > MIN_WIDTH) {
                        w = (w * 9) / 10
                        h = (page.height.toFloat() * (w.toFloat() / page.width.toFloat()))
                            .roundToInt().coerceAtLeast(1)
                    }
                    if (w.toLong() * h * 4 > MAX_BITMAP_BYTES) {
                        throw PdfFailure("RENDER_FAILED", "这一页渲染失败（页面尺寸过大）")
                    }
                    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    try {
                        val canvas = Canvas(bitmap)
                        canvas.drawColor(Color.WHITE)
                        page.render(bitmap, null, matrixFor(page, w, h), PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        writePng(bitmap, target)
                    } finally {
                        bitmap.recycle()
                    }
                    return@use mapOf(
                        "path" to target.absolutePath,
                        "width" to w,
                        "height" to h,
                        "bytes" to target.length(),
                    )
                } finally {
                    page.close()
                }
            } finally {
                renderer.close()
            }
        }
    }

    private fun clearCache(cacheKey: String): Int {
        val dir = File(cacheRoot(), sanitizeKey(cacheKey))
        if (!dir.isDirectory) return 0
        val count = dir.listFiles()?.count { it.isFile } ?: 0
        dir.deleteRecursively()
        return count
    }

    private fun cacheFiles(): List<Map<String, Any>> {
        val root = cacheRoot()
        if (!root.isDirectory) return emptyList()
        val out = ArrayList<Map<String, Any>>()
        root.listFiles()?.forEach { bookDir ->
            if (!bookDir.isDirectory) return@forEach
            bookDir.listFiles()?.forEach { f ->
                if (f.isFile) {
                    out.add(
                        mapOf(
                            "path" to f.absolutePath,
                            "bookKey" to bookDir.name,
                            "bytes" to f.length(),
                            "modified" to f.lastModified(),
                        )
                    )
                }
            }
        }
        return out
    }

    /**
     * 批量删除缓存文件。
     *
     * **只删 `pdfcache/` 里的文件**：这个方法的入参来自 Dart 的策略函数，万一
     * 策略被写错（或缓存清单被伪造）传了任意路径，这里必须兜住 —— 用
     * `canonicalPath` 前缀校验，`../` 绕不出去。
     */
    private fun deleteCacheFiles(paths: List<String>): Int {
        val root = cacheRoot().canonicalFile
        var deleted = 0
        for (p in paths) {
            try {
                val f = File(p).canonicalFile
                if (!f.path.startsWith(root.path + File.separator)) continue
                if (f.isFile && f.delete()) deleted++
            } catch (_: Exception) {
                // 单个删不掉（被占用）不影响其它文件
            }
        }
        return deleted
    }

    // ==================== 内部 ====================

    private fun cacheRoot(): File = File(filesDir, CACHE_DIR)

    private fun requireFile(path: String): File {
        if (path.isBlank()) throw PdfFailure("FILE_NOT_FOUND", "文件不存在（路径是空的）")
        val f = File(path)
        if (!f.isFile) throw PdfFailure("FILE_NOT_FOUND", "文件不存在（可能已被移动或删除）")
        return f
    }

    /**
     * 打开 `PdfRenderer` 并把 native 的异常翻成用户看得懂的话。
     *
     * `SecurityException` = 有密码（Android 的 PdfRenderer 对加密文档就是这个异常，
     * 没有更细的错误码）；其它异常基本都是「不是 PDF / 文件坏了」。
     */
    private fun openRenderer(pfd: ParcelFileDescriptor): PdfRenderer = try {
        PdfRenderer(pfd)
    } catch (e: SecurityException) {
        throw PdfFailure("ENCRYPTED", "PDF 有密码保护，暂不支持")
    } catch (e: Exception) {
        throw PdfFailure("NOT_PDF", "这不是有效的 PDF 文件（可能已损坏）")
    }

    private fun matrixFor(page: PdfRenderer.Page, w: Int, h: Int): Matrix =
        Matrix().apply {
            setScale(w / page.width.toFloat(), h / page.height.toFloat())
        }

    /** 写 PNG：先 `.tmp` 再 rename（与 Dart 侧原子写同一套理由：半截图不能被当成缓存）。 */
    private fun writePng(bitmap: Bitmap, target: File) {
        val dir = target.parentFile
        if (dir != null && !dir.exists() && !dir.mkdirs()) {
            throw PdfFailure("RENDER_FAILED", "这一页渲染失败（缓存目录建不出来）")
        }
        val tmp = File(target.parentFile, target.name + ".tmp")
        try {
            FileOutputStream(tmp).use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                    throw PdfFailure("RENDER_FAILED", "这一页渲染失败（编码图片失败）")
                }
                out.flush()
            }
            if (!tmp.renameTo(target)) throw PdfFailure("RENDER_FAILED", "这一页渲染失败（写缓存失败）")
        } catch (e: Exception) {
            tmp.delete()
            throw e
        }
    }

    private fun decodeBounds(file: File): Pair<Int, Int>? {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null
        return opts.outWidth to opts.outHeight
    }

    /**
     * cacheKey 只允许文件名安全字符；不是纯 `[0-9a-z]` 就逐字替换。
     * 目的是「Dart 传什么都不会变成路径穿越」，长度也截断。
     */
    private fun sanitizeKey(raw: String): String {
        val cleaned = raw.lowercase().map { c ->
            if (c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_') c else '_'
        }.joinToString("")
        return if (cleaned.isEmpty()) "default" else cleaned.take(64)
    }

    private class PdfFailure(val code: String, message: String) : Exception(message)

    companion object {
        private const val CHANNEL = "bili_whitelist/pdf"

        /** 相对 `filesDir` 的缓存目录。 */
        private const val CACHE_DIR = "reader/pdfcache"

        /** 与 Dart 侧 `kPdfDefaultRenderWidth` 一致。 */
        private const val DEFAULT_WIDTH = 1080

        /** 与 Dart 侧 `kPdfMaxRenderWidth` 一致（再宽就纯属浪费内存）。 */
        private const val MAX_WIDTH = 2048

        /** 太窄的页面看不清，也挡一下异常入参。 */
        private const val MIN_WIDTH = 320

        /** 封面宽度（书架行 48dp×64dp，400 已经绰绰有余）。 */
        private const val COVER_WIDTH = 400

        /** 单页位图内存上限（ARGB_8888，4 字节/像素）。 */
        private const val MAX_BITMAP_BYTES = 8L * 1024 * 1024
    }
}
