package com.biliwhitelist.bili_whitelist_app

import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val COOKIE_CHANNEL = "bili_whitelist/cookie"
    }

    // 评论图片保存相册（v2.16.19+）：授权结果（API 26~28 的
    // WRITE_EXTERNAL_STORAGE）需在此转发给 GalleryController 补完挂起保存。
    private lateinit var galleryController: GalleryController

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
     *  - clearAll() -> void                 清空所有 WebView cookie（退出登录用）
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
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
