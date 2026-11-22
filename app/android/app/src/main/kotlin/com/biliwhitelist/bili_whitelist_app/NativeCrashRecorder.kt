package com.biliwhitelist.bili_whitelist_app

import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 原生崩溃落盘（v2.67.0）。
 *
 * 为什么要在原生侧再接一层：Dart 侧那四个入口（zone / FlutterError /
 * PlatformDispatcher / ErrorWidget）只能看见 **Dart 与 Flutter 框架**里的异常。
 * 播放器（ExoPlayer）、WebView、FileProvider、Keystore 这些纯 Java/Kotlin 代码
 * 抛的异常直接走 JVM 的 `Thread.setDefaultUncaughtExceptionHandler`，Dart 完全
 * 不知情 —— 用户看到的就是"闪退"，连一条日志都没有。这里补上。
 *
 * ## 约定
 *
 * - 写到 `<filesDir>/logs/native-crash-<毫秒时间戳>.txt`：与 Dart 的
 *   `getApplicationSupportDirectory()` **同一个目录**（path_provider 在 Android
 *   上返回的就是 `getFilesDir()`），所以 Dart 下次启动能直接读走、合入
 *   `diag-*.log` 后删掉（`DiagLog.mergeNativeCrashes`）。
 * - **写完一定把异常交给原 handler**（系统照常弹"应用已停止"/杀进程）：
 *   我们只负责留证据，不负责吞掉崩溃。原 handler 不存在时（部分 ROM / 测试
 *   宿主）直接 `Process.killProcess` 结束自己 —— 比"卡死在白屏"强。
 * - 写盘本身失败（目录不可写 / 磁盘满）只 `Log.w`，绝不在崩溃路径上再抛。
 * - 碎片文件最多留 10 个：崩溃循环（一启动就崩）时不能把用户存储刷满。
 */
internal object NativeCrashRecorder {

    private const val TAG = "bili_whitelist"
    private const val DIR_NAME = "logs"
    private const val PREFIX = "native-crash-"
    private const val MAX_FRAGMENTS = 10

    @Volatile
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        val logsDir = File(context.applicationContext.filesDir, DIR_NAME)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                write(logsDir, thread, error)
            } catch (e: Throwable) {
                // 崩溃路径上再抛异常会把原异常吞掉，只剩一条莫名其妙的死法
                Log.w(TAG, "原生崩溃落盘失败：${e.javaClass.simpleName} ${e.message}")
            } finally {
                // 原 handler 一定把异常抛出去（系统照常杀进程/弹「应用已停止」）；
                // `previous` 为空时上面的调用是 no-op，异常就被静默吞掉，用户看到
                // 的是"卡死"而不是崩溃 —— 这时自己结束进程，别让他干等。
                previous?.uncaughtException(thread, error)
                    ?: Process.killProcess(Process.myPid())
            }
        }
    }

    private fun write(dir: File, thread: Thread, error: Throwable) {
        if (!dir.exists()) dir.mkdirs()
        val stamp = System.currentTimeMillis()
        val text = buildString {
            appendLine("time: ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date(stamp))}")
            appendLine("thread: ${thread.name}")
            appendLine(
                "device: ${Build.MANUFACTURER} ${Build.MODEL} / " +
                    "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            )
            appendLine()
            val sw = StringWriter()
            error.printStackTrace(PrintWriter(sw))
            append(sw.toString())
        }
        File(dir, "$PREFIX$stamp.txt").writeText(text)
        prune(dir, keepName = "$PREFIX$stamp.txt")
    }

    /** 只留最近 [MAX_FRAGMENTS] 个碎片（按文件名里的时间戳排序）。 */
    private fun prune(dir: File, keepName: String) {
        val files = dir.listFiles { f ->
            f.isFile && f.name.startsWith(PREFIX) && f.name.endsWith(".txt")
        }?.sortedBy { it.name } ?: return
        if (files.size <= MAX_FRAGMENTS) return
        for (f in files.take(files.size - MAX_FRAGMENTS)) {
            if (f.name == keepName) continue
            try {
                f.delete()
            } catch (e: Exception) {
                Log.w(TAG, "清理原生崩溃碎片失败：${f.name} ${e.javaClass.simpleName}")
            }
        }
    }
}
