package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 播放页 B 站式快捷手势的媒体调节（v2.16.7+）：
 *
 *  - 音量：AudioManager STREAM_MUSIC 当前 / 最大档（getVolume），按档精确
 *    setVolume（0..max，`setStreamVolume` 不带系统音量 UI——App 自己出浮层，
 *    避免与媒体音量键 / 系统音量条互相干扰）
 *  - 亮度：**应用内亮度**——WindowManager.LayoutParams.screenBrightness
 *    （0..1，仅当前 Activity 生效，退出播放页即恢复系统亮度）；
 *    未覆盖过（-1 = BRIGHTNESS_OVERRIDE_NONE）时读系统亮度作 UI 基准。
 *    下限钳 5%：全黑时手势浮层（同一窗口）不可见会误以为失效
 *
 * 通道：`bili_whitelist/media`。Dart 侧封装见 lib/services/device_media.dart。
 * 与 ApkInstaller 同风格：非独立插件包，由 MainActivity.configureFlutterEngine
 * 手动注册。
 */
class MediaController(private val activity: Activity) {

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getVolume" -> {
                            val am = audioManager()
                            result.success(
                                mapOf(
                                    "current" to
                                        am.getStreamVolume(AudioManager.STREAM_MUSIC),
                                    "max" to
                                        am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                                ),
                            )
                        }
                        "setVolume" -> {
                            val level = call.argument<Int>("level")
                            if (level == null) {
                                result.error("BAD_ARG", "level 缺失", null)
                                return@setMethodCallHandler
                            }
                            val am = audioManager()
                            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            val clamped = level.coerceIn(0, max)
                            // flag=0：不弹系统音量 UI（手势浮层由 Flutter 侧绘制）
                            am.setStreamVolume(AudioManager.STREAM_MUSIC, clamped, 0)
                            result.success(clamped)
                        }
                        "getBrightness" -> {
                            result.success(currentBrightness().toDouble())
                        }
                        "setBrightness" -> {
                            val v = call.argument<Double>("value")
                            if (v == null) {
                                result.error("BAD_ARG", "value 缺失", null)
                                return@setMethodCallHandler
                            }
                            applyBrightness(v)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("MEDIA_FAILED", e.message ?: "未知错误", null)
                }
            }
    }

    private fun audioManager(): AudioManager =
        activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** 当前亮度（0..1）：优先读窗口覆盖值；未覆盖过则读系统亮度作基准。 */
    private fun currentBrightness(): Float {
        val cur = activity.window.attributes.screenBrightness
        if (cur >= 0f) return cur
        val sys = Settings.System.getInt(
            activity.contentResolver,
            Settings.System.SCREEN_BRIGHTNESS,
            255,
        )
        return (sys / 255f).coerceIn(MIN_BRIGHTNESS, 1f)
    }

    /** 设置当前 Activity 窗口亮度（仅本应用窗口生效，0.05..1.0）。 */
    private fun applyBrightness(v: Double) {
        val lp = activity.window.attributes
        lp.screenBrightness = v.toFloat().coerceIn(MIN_BRIGHTNESS, 1f)
        activity.window.attributes = lp
    }

    companion object {
        private const val CHANNEL = "bili_whitelist/media"
        private const val MIN_BRIGHTNESS = 0.05f
    }
}
