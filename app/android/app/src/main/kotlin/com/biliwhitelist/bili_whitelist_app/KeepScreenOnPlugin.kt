package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 播放时保持亮屏（v2.60.0）。
 *
 * 通道：`bili_whitelist/keep_screen_on`，方法与 Dart 侧封装见
 * lib/services/keep_screen_on.dart（[KeepScreenOn]）。
 *
 * ## 为什么用 FLAG_KEEP_SCREEN_ON
 *
 * - **不需要任何权限**：窗口标志，跟着 Activity 窗口的可见性走 —— 退到后台 /
 *   页面不可见时系统自然不生效，不会出现「App 在后台还拦着息屏」；
 * - **不需要手动释放**：不像 [android.os.PowerManager.WakeLock] 那样要成对
 *   release（忘了 release 就是持续耗电的经典泄漏），窗口销毁即结束；
 * - 只在本 App 可见时生效，正是「看视频时别息屏」的语义。
 *
 * 刻意**不用** `PowerManager.WakeLock`：那要 `WAKE_LOCK` 权限（本 App 不为一个
 * 息屏策略加权限），且生命周期管理更容易出错。
 *
 * ## 线程与幂等
 *
 * 窗口标志只能在 **UI 线程**改（[Activity.runOnUiThread] 内统一执行）。重复设置
 * 同一个值本身是无害的（`addFlags` / `clearFlags` 都是位运算），这里另外记一个
 * [lastApplied] 避免重复调用系统接口，也让「同值重复设置」成为真正的空操作。
 *
 * 与 ApkInstaller / MediaController / TrafficStatsPlugin 同风格：非独立插件包，
 * 由 MainActivity.configureFlutterEngine 手动注册（理由见 ScheduleImportPlugin
 * 的文件头）。
 */
class KeepScreenOnPlugin(private val activity: Activity) {

    /** 上一次真正下发给窗口的值（null = 还没有过）；同值不再碰窗口标志。 */
    private var lastApplied: Boolean? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("on")
                        if (on == null) {
                            result.error("BAD_ARGS", "缺少 on 参数", null)
                            return@setMethodCallHandler
                        }
                        applyKeepScreenOn(on, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 下发亮屏标志（`true` = 加 FLAG_KEEP_SCREEN_ON，`false` = 清掉）。
     *
     * 一律回 `result.success`：这是**增强类**能力，原生侧失败（窗口还没建好 /
     * ROM 异常）不该让 Dart 侧抛异常打断播放 —— 最坏结果是照常息屏。
     */
    private fun applyKeepScreenOn(on: Boolean, result: MethodChannel.Result) {
        activity.runOnUiThread {
            try {
                if (lastApplied != on) {
                    val window = activity.window
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    lastApplied = on
                }
                result.success(true)
            } catch (e: Exception) {
                Log.w(TAG, "设置亮屏标志失败（on=$on）：${e.javaClass.simpleName}")
                result.success(false)
            }
        }
    }

    companion object {
        private const val CHANNEL = "bili_whitelist/keep_screen_on"
        private const val TAG = "bili_whitelist/keep_screen_on"
    }
}
