package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.util.Rational
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * 画中画（小窗播放，v2.63.0）。
 *
 * 通道：`bili_whitelist/pip`（方法）+ `bili_whitelist/pip_events`（状态），
 * Dart 侧封装见 lib/services/pip_service.dart（[PipService]）。
 *
 * ## 方法
 *
 *  - `isSupported() -> Boolean`
 *    两个条件都要成立：① `SDK_INT >= 26`（`enterPictureInPictureMode` 从 O
 *    开始有）；② `packageManager.hasSystemFeature(FEATURE_PICTURE_IN_PICTURE)`
 *    —— 有些 ROM/低内存设备会声明 API 版本但**没有**这个 feature，光看版本号
 *    会把「点了没反应」当成正常路径。Dart 侧据此**隐藏入口**（不支持就不给
 *    用户看到按钮，这是本功能的降级契约）。
 *  - `enter(width: Int, height: Int) -> Boolean`
 *    调 `enterPictureInPictureMode(PictureInPictureParams)`；成功 `true`，
 *    系统拒绝（`false`）或异常 → `error(UNSUPPORTED / FAILED, 可读中文, null)`。
 *    宽高比取视频**真实**比例，并夹到 [MIN_ASPECT]~[MAX_ASPECT]（系统只接受
 *    这个区间，越界会抛 IllegalArgumentException）。
 *
 * ## 事件（EventChannel）
 *
 *  - `{"event":"pipChanged","inPip":true|false}`：进/出 PiP。
 *  - `{"event":"pipDismissed"}`：用户点了小窗上的 ✕（小窗没了）——Dart 侧按
 *    「停止播放」收尾（停播、存进度、释放亮屏）。
 *
 * ## 为什么不需要任何权限
 *
 * PiP 是系统窗口能力：`AndroidManifest.xml` 里 `MainActivity` 声明
 * `android:supportsPictureInPicture="true"` 就够了，不涉及任何 `uses-permission`
 * （本项目不为这个功能加权限，见清单注释）。
 *
 * ## 版本兼容
 *
 * minSdk = 26，所以 `PictureInPictureParams` 之类在编译期就能直接用；仍然保留
 * `SDK_INT >= O` 判断：那是**运行期**语义（机型是否真的支持），不是编译兼容。
 *
 * 与 ApkInstaller / MediaController / KeepScreenOnPlugin / SharePlugin 同风格：
 * 非独立插件包，由 MainActivity.configureFlutterEngine 手动注册；
 * `onPictureInPictureModeChanged` 的回调入口也在 MainActivity（Activity 生命周期
 * 只能在那里接），本类只负责「说给 Dart 听」。
 */
class PipPlugin(private val activity: Activity) : EventChannel.StreamHandler {

    /** 事件订阅端（Dart 侧 listen 之后才有；null = 没人听，直接丢）。 */
    private var sink: EventChannel.EventSink? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isSupported())
                    "enter" -> {
                        val width = call.argument<Int>("width") ?: 0
                        val height = call.argument<Int>("height") ?: 0
                        enter(width, height, result)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** 由 MainActivity.onPictureInPictureModeChanged 调用（主线程）。 */
    fun onPipModeChanged(inPip: Boolean) {
        try {
            sink?.success(mapOf("event" to "pipChanged", "inPip" to inPip))
        } catch (e: Exception) {
            // 通道已拆（Activity 正在销毁）：没人听了，丢事件即可
            Log.w(TAG, "推送 PiP 状态失败：${e.javaClass.simpleName}")
        }
    }

    /** 由 MainActivity.onStop 调用：小窗被系统关掉（用户点 ✕）。 */
    fun onPipDismissed() {
        try {
            sink?.success(mapOf("event" to "pipDismissed"))
        } catch (e: Exception) {
            Log.w(TAG, "推送 PiP 关闭事件失败：${e.javaClass.simpleName}")
        }
    }

    /**
     * 本机是否支持 PiP。
     *
     * 只查 feature、不查权限：PiP 不需要权限。`supportsPictureInPicture` 清单位
     * 由本 App 自己声明，所以这里查的是「系统有没有这个能力」。
     */
    private fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            activity.packageManager.hasSystemFeature(
                PackageManager.FEATURE_PICTURE_IN_PICTURE
            )
        } catch (e: Exception) {
            Log.w(TAG, "查询 PiP 支持失败：${e.javaClass.simpleName}")
            false
        }
    }

    /**
     * 进小窗。宽高比一律夹取（见 [aspectRatioOf]），异常回可读错误码：
     * - `UNSUPPORTED`：本机不支持（或 Activity 已不在可进小窗的状态）；
     * - `FAILED`：系统抛异常（典型：Activity 正在销毁 / ROM 拒绝）。
     *
     * 必须回 `result`：Dart 侧在等这一次调用决定是否给用户提示。
     */
    private fun enter(width: Int, height: Int, result: MethodChannel.Result) {
        if (!isSupported()) {
            result.error("UNSUPPORTED", "当前设备不支持小窗播放", null)
            return
        }
        activity.runOnUiThread {
            try {
                // PictureInPictureParams.Builder 是 API 26 的类，minSdk = 26 → 可直接用；
                // 运行时是否真的能进由 isSupported() 与系统返回值共同决定。
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(aspectRatioOf(width, height))
                    .build()
                val ok = activity.enterPictureInPictureMode(params)
                if (!ok) {
                    Log.w(TAG, "enterPictureInPictureMode 返回 false（宽高 ${width}x$height）")
                }
                result.success(ok)
            } catch (e: Exception) {
                // 典型：Activity 正在 finishing / ROM 禁用 PiP / 已经在小窗里
                Log.w(TAG, "进小窗失败：${e.javaClass.simpleName} ${e.message}")
                result.error("FAILED", "进入小窗失败：${e.message ?: e.javaClass.simpleName}", null)
            }
        }
    }

    companion object {
        private const val CHANNEL = "bili_whitelist/pip"
        private const val EVENT_CHANNEL = "bili_whitelist/pip_events"
        private const val TAG = "bili_whitelist/pip"

        /** 系统接受的最窄比例（`PictureInPictureParams` 的合法区间下界）。 */
        private const val MIN_ASPECT = 0.5
        private const val MAX_ASPECT = 2.33

        /**
         * 由像素尺寸算出可交给系统的 [Rational]：夹到 [MIN_ASPECT]~[MAX_ASPECT]。
         *
         * 用法与 Dart 侧 `pipEnterSize` 同一契约（Dart 已经夹过一遍，这里是
         * 二次防御：通道也允许被别处直接调用）。宽高非法（≤0）→ 退 16:9，
         * 绝不把 0 塞进 Rational（构造器会抛 IllegalArgumentException）。
         */
        private fun aspectRatioOf(width: Int, height: Int): Rational {
            val w = if (width > 0) width else 16
            val h = if (height > 0) height else 9
            val raw = w.toDouble() / h.toDouble()
            val clamped = raw.coerceIn(MIN_ASPECT, MAX_ASPECT)
            // 千分位精度足够表达任何视频比例（16:9 = 1.778，21:9 = 2.333），
            // 又不会因为浮点抖动让 Rational 的分子分母爆掉。
            return Rational((clamped * 1000).roundToInt(), 1000)
        }
    }
}
