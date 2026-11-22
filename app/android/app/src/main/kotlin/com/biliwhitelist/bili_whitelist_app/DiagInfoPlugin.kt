package com.biliwhitelist.bili_whitelist_app

import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 诊断信息通道（v2.67.0）。
 *
 * 通道：`bili_whitelist/diag`，只有 `deviceInfo` 一个方法。导出诊断包的
 * `meta.txt` 需要"机型 + Android 版本"，而 Dart 侧的 `Platform
 * .operatingSystemVersion` 在 Android 上给的是引擎拼的版本串，**没有机型**；
 * 又不值得为两个字段引一个 device_info 包（项目纪律：不加依赖）。
 *
 * 返回 `Map`：`manufacturer` / `model` / `release` / `sdkInt`。
 * 不需要任何权限，全是 `android.os.Build` 的公开静态字段。
 */
class DiagInfoPlugin {

    companion object {
        private const val CHANNEL = "bili_whitelist/diag"
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> result.success(
                        mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "release" to Build.VERSION.RELEASE,
                            "sdkInt" to Build.VERSION.SDK_INT,
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
