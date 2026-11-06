package com.biliwhitelist.bili_whitelist_app

import android.content.Intent
import android.content.res.Configuration
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebStorage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val COOKIE_CHANNEL = "bili_whitelist/cookie"
        private const val TAG = "bili_whitelist"
    }

    // 评论图片保存相册（v2.16.19+）：授权结果（API 26~28 的
    // WRITE_EXTERNAL_STORAGE）需在此转发给 GalleryController 补完挂起保存。
    private lateinit var galleryController: GalleryController

    // 日程表导入 Excel（v2.34.0）：系统文件选择器的结果（SAF 的
    // onActivityResult）在此转发给 ScheduleImportPlugin。
    private lateinit var scheduleImport: ScheduleImportPlugin

    // 从相册选图当合集封面（v2.50.0）：同样走 SAF，结果在这里转发给
    // ImagePickPlugin（requestCode 与上面那条通道错开）。
    private lateinit var imagePick: ImagePickPlugin

    // 画中画（小窗播放，v2.63.0）：通道 + 事件由 PipPlugin 负责，
    // 生命周期回调（onPictureInPictureModeChanged / onStop）只能在这里接。
    private lateinit var pip: PipPlugin

    // 「刚退出 PiP、还没回到前台」——见 onStop 的说明。
    //
    // 只有它决定要不要发 pipDismissed：**不能**用"曾经进过小窗"来判，
    // 因为小窗还在屏幕上时（用户切到别的 App）Activity 也可能收到 onStop，
    // 那种情况必须**继续播**，不能当成"小窗被关掉"。
    private var pipExitPending = false

    // 应用内嵌插件不走 GeneratedPluginRegistrant（那是给独立插件包用的），
    // 在 configureFlutterEngine 里手动注册 B 站 DASH 播放插件。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(BiliDashPlayerPlugin())
        setupCookieChannel(flutterEngine)
        // 应用内版本更新（M1.3）：注册 APK 安装 MethodChannel
        ApkInstaller(applicationContext).register(flutterEngine)
        // 播放页 B 站式快捷手势（v2.16.7+）：音量 + 应用内亮度 MethodChannel
        MediaController(this).register(flutterEngine)
        // 评论图片保存系统相册（v2.16.19+）：MediaStore MethodChannel
        galleryController = GalleryController(this)
        galleryController.register(flutterEngine)
        // 日程表导入 Excel（v2.34.0）：系统文件选择器 MethodChannel
        scheduleImport = ScheduleImportPlugin(this)
        scheduleImport.register(flutterEngine)
        // 从相册选图（v2.50.0）：系统图片选择器 MethodChannel
        imagePick = ImagePickPlugin(this)
        imagePick.register(flutterEngine)
        // 流量计量（v2.53.0）：NetworkStatsManager + 「使用情况访问」引导。
        // 不需要持有实例（跳设置页不靠 onActivityResult 回传，Dart 侧在回到前台时
        // 自己重查权限）→ 与 ApkInstaller / MediaController 一样直接注册即走；
        // 通道 handler 闭包持有实例引用，不会被回收。
        TrafficStatsPlugin(this).register(flutterEngine)
        // 播放时保持亮屏（v2.60.0）：窗口 FLAG_KEEP_SCREEN_ON。
        // 不需要权限、也不持 WakeLock（理由见 KeepScreenOnPlugin 文件头）。
        KeepScreenOnPlugin(this).register(flutterEngine)
        // 播放页「更多 → 分享」（v2.62.0）：Intent.ACTION_SEND + createChooser。
        // 不需要权限、不联网（理由见 SharePlugin 文件头）。
        SharePlugin(this).register(flutterEngine)
        // 播放页「更多 → 小窗播放」（v2.63.0）：系统画中画 + 状态回推。
        // 不需要权限（清单里只有 supportsPictureInPicture），理由见 PipPlugin 文件头。
        pip = PipPlugin(this)
        pip.register(flutterEngine)
    }

    /**
     * 进/出系统小窗（v2.63.0）。**必须在 MainActivity 里接**：这是 Activity 的
     * 系统回调，PipPlugin 只是把它转成 EventChannel 事件。
     *
     * Dart 侧据 `inPip` 裁剪界面：true → 只留视频画面；false → 恢复顶栏/底栏/
     * 信息块/评论区。播放器本身一刻没停，所以位置天然连续。
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (!isInPictureInPictureMode) pipExitPending = true
        if (::pip.isInitialized) pip.onPipModeChanged(isInPictureInPictureMode)
    }

    /**
     * 回到前台 → 清掉「刚退出 PiP」标记：这说明用户是把小窗**点回全屏**
     * （PiP → 全屏），不是把小窗关掉。点击小窗时系统先发
     * onPictureInPictureModeChanged(false)，紧接着 onResume，走不到 [onStop]
     * 的"关闭"分支。
     */
    override fun onResume() {
        super.onResume()
        pipExitPending = false
    }

    /**
     * 小窗被关掉（用户点系统小窗上的 ✕ / 小窗任务被移除）：
     * 系统会依次给 onPictureInPictureModeChanged(false) → onStop，**不会**
     * 回到 onResume。这里据此回一个 `pipDismissed`，Dart 侧按既有「停止播放」
     * 路径收尾（停播、存进度、释放亮屏），而不是让页面停在"小窗已消失、
     * 声音还在放"的状态。
     *
     * 判据**只看 [pipExitPending]**（退出小窗且没回到前台）：不能用"正在 PiP"
     * 来判——小窗还在屏幕上时 Activity 也可能被 onStop（个别 ROM 会把 PiP
     * 收成悬浮图标），那时必须继续播，误判成"关闭"会平白打断用户。
     */
    override fun onStop() {
        val dismissed = pipExitPending
        pipExitPending = false
        if (dismissed && ::pip.isInitialized) pip.onPipDismissed()
        super.onStop()
    }

    /**
     * 系统文件选择器（SAF）的结果回传。
     *
     * **为什么是 startActivityForResult 这条路**：本项目 MainActivity 继承
     * `FlutterActivity`（= 原生 `android.app.Activity`），**不是** androidx 的
     * `ComponentActivity`，因此拿不到 `registerForActivityResult` 所需的
     * ActivityResultRegistry。onActivityResult 在 API 30+ 标了 deprecated，
     * 但对 Activity 宿主仍是官方支持且唯一可用的分发路径 —— 接受该废弃标记。
     *
     * 先调 super：FlutterActivity 会把它转发给引擎（`addActivityResultListener`
     * 注册的插件，例如权限插件），吞掉这一步会连带影响别的插件。
     */
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (::scheduleImport.isInitialized) {
            scheduleImport.onActivityResult(requestCode, resultCode, data)
        }
        if (::imagePick.isInitialized) {
            imagePick.onActivityResult(requestCode, resultCode, data)
        }
    }

    // 选文件期间 Activity 被销毁 → 收尾挂起的 Dart 调用（否则那条 await 永远不返回）
    override fun onDestroy() {
        if (::scheduleImport.isInitialized) {
            scheduleImport.onActivityDestroyed()
        }
        if (::imagePick.isInitialized) {
            imagePick.onActivityDestroyed()
        }
        super.onDestroy()
    }

    // API 26~28 保存相册的运行时授权结果 → 转发给 GalleryController
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (::galleryController.isInitialized) {
            galleryController.onRequestPermissionsResult(requestCode, grantResults)
        }
    }

    /**
     * Cookie 读取通道（M4 WebView 登录用）：
     *
     * webview_flutter 的 WebViewCookieManager 只有 set/clear，没有读接口，
     * 而 SESSDATA/bili_jct 是 HttpOnly cookie（JS 读不到），必须走原生侧。
     *
     * 方法：
     *  - getCookies(url: String) -> String  返回该 url 匹配的全部 cookie 串
     *    （形如 "SESSDATA=xxx; bili_jct=yyy; ..."），找不到返回空串
     *  - clearAll() -> void                 清空所有 WebView cookie（退出登录 /
     *    服务端判定会话已死时同步清掉 WebView 里那份残留，v2.49.1+）
     *  - clearAllData() -> void             清空 cookie + Web Storage
     *    （localStorage 等；「清除网页数据后重试」用，v2.49.1+）
     *
     * 两个 clear 都补了 `flush()`：`removeAllCookies` 的回调是异步的、且写入
     * 是延迟落盘的，不清求立即刷盘的话，进程被系统杀掉后 cookie 可能"复活"
     * （重启后又读到那份该死会话）。
     */
    private fun setupCookieChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            COOKIE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url") ?: "https://www.bilibili.com/"
                    result.success(CookieManager.getInstance().getCookie(url) ?: "")
                }
                "clearAll" -> {
                    CookieManager.getInstance().removeAllCookies(null)
                    CookieManager.getInstance().flush()
                    result.success(null)
                }
                "clearAllData" -> {
                    try {
                        CookieManager.getInstance().removeAllCookies(null)
                        CookieManager.getInstance().flush()
                    } catch (e: Exception) {
                        // cookie 清不掉不该拦住"清网页数据"整体流程
                        Log.w(TAG, "clearAllData: 清 cookie 失败 ${e.javaClass.simpleName}")
                    }
                    try {
                        // WebStorage 覆盖 localStorage / sessionStorage / WebSQL；
                        // API 19+ 可用（本项目 minSdk 26）
                        WebStorage.getInstance().deleteAllData()
                    } catch (e: Exception) {
                        Log.w(TAG, "clearAllData: 清 WebStorage 失败 ${e.javaClass.simpleName}")
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
