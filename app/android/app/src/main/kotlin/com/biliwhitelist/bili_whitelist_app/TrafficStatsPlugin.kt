package com.biliwhitelist.bili_whitelist_app

import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.NetworkStats
import android.app.usage.NetworkStatsManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.TrafficStats
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 流量计量（v2.53.0）：读**本 App / 本机**的**移动数据**用量，并提供
 * 「使用情况访问」权限的查询与引导入口。
 *
 * 通道：`bili_whitelist/traffic_stats`。Dart 侧封装见
 * lib/services/traffic_stats_service.dart。与 ApkInstaller / ImagePickPlugin /
 * ScheduleImportPlugin / GalleryController 同风格：非独立插件包，由 MainActivity
 * configureFlutterEngine 手动注册（理由见 ScheduleImportPlugin 的文件头）。
 *
 * ## 为什么用 NetworkStatsManager 而不是 TrafficStats
 *
 * - [NetworkStatsManager] 是**按接口分**的（`TYPE_MOBILE` 单独查）→ 天然把
 *   **Wi-Fi 排除**掉，这正是"免流只跟蜂窝有关"需要的口径；还能按时间区间查
 *   （本月 / 任意区间，做快照差值）；
 * - [TrafficStats] 只能给"自开机以来"的累计值（`getMobileRxBytes` 是全机移动
 *   口径、`getUidRxBytes` 不分接口），时间窗口与"排除 Wi-Fi"都做不到 —— 它只
 *   作为**免权限的兜底对照**（[mobileSinceBoot] 那条），不作主口径。
 *
 * ## 权限（`PACKAGE_USAGE_STATS`，即"使用情况访问"）
 *
 * - 这是**特殊权限**：不是运行时弹窗的普通权限，**只能由用户在系统设置里手动
 *   开启**（`Settings.ACTION_USAGE_ACCESS_SETTINGS`，见 [openUsageAccessSettings]）。
 *   本 App 在 AndroidManifest 里声明它（声明只是"表达使用意图"，让本 App 出现在
 *   那个设置列表里；不声明就不会出现在列表里，用户根本无从开启）。
 * - **本 App 自己的**用量（`queryDetailsForUid` 且 uid = 自己）按官方文档在
 *   API 24+ 不强制该权限；**本机总量**（`querySummaryForDevice`）必须要有。
 *   所以：没开权限时我们仍尽量给"本 App 的移动流量"，只在拿不到时给引导
 *   （一句话 + 一个按钮，绝不静默失败、也不刷日志刷屏）。
 * - **不加任何其它权限**：本通道不读短信、不读电话状态（`subscriberId` 传 null =
 *   所有订阅一起算，见 [queryMobile]）。
 *
 * ## 返回结构（`queryMobile`）
 *
 * `{"appBytes": Long?, "deviceBytes": Long?}` —— 单值为 `null` 表示那一项读不到
 * （不抛错给 Dart，让界面自己决定显示"读不到"还是显示数字）。整条查询都失败
 * 才回 error（Dart 侧给一句能显示的中文）。
 */
class TrafficStatsPlugin(private val activity: Activity) {

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasUsageAccess" -> result.success(hasUsageAccess())
                    "openUsageAccessSettings" -> result.success(openUsageAccessSettings())
                    "queryMobile" -> queryMobile(call, result)
                    "mobileSinceBoot" -> result.success(mobileSinceBoot())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 当前是否已开启「使用情况访问」。
     *
     * 判据是 AppOps 的 `OPSTR_GET_USAGE_STATS`（这就是系统那个开关真正控制的
     * 东西；`checkCallingOrSelfPermission` 那种自身权限检查判不出来，
     * 因为它是 system-level 权限、第三方 App 永远不会被"授予"）。
     */
    private fun hasUsageAccess(): Boolean {
        return try {
            val appOps = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(),
                    activity.packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(),
                    activity.packageName
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            // 拿不到就当没开（界面会给引导按钮，用户自己去看一眼即可）
            Log.w(TAG, "查「使用情况访问」状态失败：${e.javaClass.simpleName}")
            false
        }
    }

    /**
     * 跳到系统「使用情况访问」设置页（本 App 那一项优先）。
     *
     * 先试**带包名**的（`ACTION_USAGE_ACCESS_SETTINGS` + `package:` data，部分
     * ROM 直接落到本 App 那一项），失败再退成**整张列表**（用户自己找本 App）。
     * 两种都打不开（极简 ROM / 被禁用）→ 返回 false，Dart 侧给一句人话
     * （不抛异常到界面）。
     */
    private fun openUsageAccessSettings(): Boolean {
        val appSpecific = Intent(
            Settings.ACTION_USAGE_ACCESS_SETTINGS,
            Uri.parse("package:${activity.packageName}")
        )
        try {
            activity.startActivity(appSpecific)
            return true
        } catch (e: ActivityNotFoundException) {
            Log.i(TAG, "没有本 App 专属的「使用情况访问」页，退回整列表：${e.javaClass.simpleName}")
        } catch (e: Exception) {
            Log.w(TAG, "打开「使用情况访问」失败：${e.javaClass.simpleName}")
        }
        return try {
            activity.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            true
        } catch (e: Exception) {
            Log.w(TAG, "连「使用情况访问」列表都打不开：${e.javaClass.simpleName}")
            false
        }
    }

    /**
     * 查 `[fromMs, toMs)` 区间内的**移动数据**用量：`appBytes` = 本 App（按 UID
     * 聚合，Wi-Fi 不计），`deviceBytes` = 本机总量（device 口径，需要权限）。
     *
     * `subscriberId` 传 **null** = 所有订阅一起算：读真实 subscriberId 需要
     * `READ_PHONE_STATE`（本 App 不加这个权限，也不该为一个展示数字去要它）。
     *
     * 两项分别 try：本 App 那项失败整条回 error；本机总量失败只回 null
     * （多因未开权限 —— 那时界面给引导，而不是报错）。
     */
    private fun queryMobile(call: MethodCall, result: MethodChannel.Result) {
        val from = call.argument<Number>("fromMs")?.toLong()
        val to = call.argument<Number>("toMs")?.toLong()
        if (from == null || to == null || to <= from) {
            result.error("BAD_ARGS", "查询区间不合法", null)
            return
        }
        val manager =
            activity.getSystemService(Context.NETWORK_STATS_SERVICE) as? NetworkStatsManager
        if (manager == null) {
            result.error("NO_SERVICE", "这台设备没有流量统计服务", null)
            return
        }
        val appBytes = try {
            appMobileBytes(manager, from, to)
        } catch (e: Exception) {
            Log.w(TAG, "读本 App 移动流量失败：${e.javaClass.simpleName}")
            result.error(
                "STATS_FAILED",
                "读不到流量统计（${e.javaClass.simpleName}）",
                null
            )
            return
        }
        val deviceBytes = try {
            val bucket =
                manager.querySummaryForDevice(ConnectivityManager.TYPE_MOBILE, null, from, to)
            bucket.rxBytes + bucket.txBytes
        } catch (e: Exception) {
            // 未开「使用情况访问」时这里必然失败（device 口径要求该权限）
            Log.i(TAG, "读本机移动流量失败（多因未开「使用情况访问」）：${e.javaClass.simpleName}")
            null
        }
        result.success(mapOf("appBytes" to appBytes, "deviceBytes" to deviceBytes))
    }

    /** 本 App 的移动流量（按 UID 聚合；`TYPE_MOBILE` 已把 Wi-Fi 排除在外）。 */
    private fun appMobileBytes(manager: NetworkStatsManager, from: Long, to: Long): Long {
        var total = 0L
        val stats = manager.queryDetailsForUid(
            ConnectivityManager.TYPE_MOBILE,
            null,
            from,
            to,
            Process.myUid()
        )
        stats.use {
            val bucket = NetworkStats.Bucket()
            while (it.hasNextBucket()) {
                it.getNextBucket(bucket)
                total += bucket.rxBytes + bucket.txBytes
            }
        }
        return total
    }

    /**
     * **免权限**的兜底对照：本机移动数据累计（自开机，`TrafficStats`）。
     *
     * 为什么留着它：没开「使用情况访问」时上面那条 device 口径读不到，用户至少
     * 还能看到一个"从开机到现在一共用了多少移动流量"的数字（界面会如实标注
     * "自开机以来"，不与"本月"混淆）。设备不支持时系统回 `UNSUPPORTED`（负数）。
     */
    private fun mobileSinceBoot(): Long =
        TrafficStats.getMobileRxBytes() + TrafficStats.getMobileTxBytes()

    companion object {
        private const val CHANNEL = "bili_whitelist/traffic_stats"
        private const val TAG = "bili_whitelist/traffic"
    }
}
