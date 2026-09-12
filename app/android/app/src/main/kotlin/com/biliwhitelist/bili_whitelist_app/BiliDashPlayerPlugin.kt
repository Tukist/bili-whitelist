package com.biliwhitelist.bili_whitelist_app

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/// 浏览器 UA：必须与 lib/config.dart 的 kBrowserUA 完全一致（防盗链双必需之一）。
private const val kBrowserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

private const val TAG = "BiliDashPlayerPlugin"

/// Android 13+ 通知运行时权限的请求码（结果不需要处理，只为不与相册的码冲突）。
private const val kReqNotification = 9048

/**
 * B 站 DASH 双流播放原生插件（MethodChannel: `bili_dash_player`）。
 *
 * - `create`：创建播放器 + TextureRegistry 纹理，返回 textureId（Dart 侧 Texture 渲染）
 * - `setDataSource(videoUrl, audioUrl, positionMs, title, artist, coverUrl)`：
 *   MergingMediaSource 组源后播放（后三个字段只写进 MediaItem 元信息，供会话侧
 *   消费者 / Android Auto 读；通知文案见 `updateNowPlaying`）
 * - `play` / `pause` / `seekTo` / `setVolume` / `setPlaybackSpeed` / `getPosition` / `dispose`
 * - `updateNowPlaying(textureId, title, artist, coverUrl, status, playing, positionMs,
 *   durationMs)`：同步媒体通知内容（v2.25.x，见 [DashMediaNotification]）
 * - `requestNotificationPermission`：Android 13+ 通知权限（v2.25.0-r2 起通知**不再**
 *   绑媒体会话 token，因此不再享受「媒体会话通知」的权限豁免，这条请求是必需的）
 * - 事件通过 EventChannel `bili_dash_player/events` 回推（载荷带 textureId 区分播放器）：
 *   onPrepared(width,height,durationMs,playWhenReady) / onCompleted /
 *   onError(code,message) / onUrlExpired / onMediaAction(action,positionMs)
 *
 * 注册方式：应用内嵌插件（写在 app 模块）不走 GeneratedPluginRegistrant，在
 * MainActivity.configureFlutterEngine 里 `plugins.add(BiliDashPlayerPlugin())` 显式注册。
 * 纹理从 FlutterPluginBinding.textureRegistry 获取（v2 embedding 官方途径，
 * 与 video_player_android 一致）；ActivityAware 用于请求通知权限（Android 13+）。
 */
class BiliDashPlayerPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private var context: android.content.Context? = null
    private var messenger: BinaryMessenger? = null
    private var textureRegistry: TextureRegistry? = null
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    /** 当前 Activity（仅用于请求通知权限；detach 时置空防泄漏）。 */
    private var activity: Activity? = null

    /** 媒体通知 + 媒体会话（懒建：第一次 updateNowPlaying 时才需要）。 */
    private var notification: DashMediaNotification? = null

    private val players = HashMap<Long, DashExoPlayer>()
    private val eventSink = QueuingEventSink()

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        textureRegistry = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "bili_dash_player").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "bili_dash_player/events").also {
            it.setStreamHandler(eventSink)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        notification?.release()
        notification = null
        for (player in players.values) player.dispose()
        players.clear()
        eventSink.clear()
        context = null
        messenger = null
        textureRegistry = null
    }

    // ---- ActivityAware：仅记录 Activity（Android 13+ 请求通知权限用） ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "create" -> result.success(createPlayer())
                "setDataSource" -> {
                    val id = call.argument<Number>("textureId")!!.toLong()
                    val videoUrl = call.argument<String>("videoUrl")!!
                    val audioUrl = call.argument<String>("audioUrl")
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    // 展示元信息（可空）：只影响 MediaItem 元数据，不影响取流/解码
                    val meta = DashExoPlayer.Meta(
                        title = call.argument<String>("title") ?: "",
                        artist = call.argument<String>("artist") ?: "",
                        coverUrl = call.argument<String>("coverUrl") ?: "",
                    )
                    player(id).prepare(videoUrl, audioUrl, positionMs, meta)
                    result.success(null)
                }
                "play" -> {
                    player(idOf(call)).play()
                    result.success(null)
                }
                "pause" -> {
                    player(idOf(call)).pause()
                    result.success(null)
                }
                "seekTo" -> {
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    player(idOf(call)).seekTo(positionMs)
                    result.success(null)
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1f
                    player(idOf(call)).setVolume(volume)
                    result.success(null)
                }
                "setPlaybackSpeed" -> {
                    val speed = call.argument<Number>("speed")?.toFloat() ?: 1f
                    player(idOf(call)).setPlaybackSpeed(speed)
                    result.success(null)
                }
                "getPosition" -> result.success(player(idOf(call)).getPosition())
                "updateNowPlaying" -> {
                    updateNowPlaying(call)
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                "dispose" -> {
                    disposePlayer(idOf(call))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("bili_dash_player", e.message ?: e.toString(), null)
        }
    }

    /**
     * 同步媒体通知内容（Dart 侧播放状态变化时调用）。
     *
     * 播放器已被释放（换页/换源竞态）时静默返回：通知只是增强，不能因此报错。
     */
    private fun updateNowPlaying(call: MethodCall) {
        val id = idOf(call)
        val player = players[id] ?: run {
            Log.d(TAG, "updateNowPlaying 忽略：播放器不存在（textureId=$id）")
            return
        }
        notifier().bind(
            id = id,
            player = player.mediaPlayer,
            title = call.argument<String>("title") ?: "",
            artist = call.argument<String>("artist") ?: "",
            coverUrl = call.argument<String>("coverUrl") ?: "",
            status = call.argument<String>("status") ?: "",
            playing = call.argument<Boolean>("playing") ?: false,
            positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L,
            durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L,
        )
    }

    /** 懒建媒体通知控制器（一个插件实例只持有一套会话 + 通知）。 */
    private fun notifier(): DashMediaNotification =
        notification ?: DashMediaNotification(
            context!!,
            kBrowserUA,
            onAction = { textureId, action, positionMs ->
                // 通知/会话上的操作 → 回推 Dart（Dart 据此对齐界面状态）
                eventSink.success(
                    mapOf(
                        "event" to "onMediaAction",
                        "textureId" to textureId,
                        "action" to action,
                        "positionMs" to positionMs,
                    )
                )
            },
        ).also { notification = it }

    /**
     * Android 13+ 的通知运行时权限。
     *
     * v2.25.0-r2 起播放通知**不再**绑媒体会话 token（见 [DashMediaNotification.bind]
     * 的说明：绑了就会被系统媒体卡片接管、四个按钮点不到），因此它不再享受
     * 「媒体会话通知豁免 POST_NOTIFICATIONS」那条规则 —— 这条请求是**必需**的，
     * 用户在系统设置里关掉本 App 通知后通知就不会显示（播放本身不受影响）。
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val act = activity ?: return
        if (act.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        try {
            act.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), kReqNotification)
        } catch (e: Exception) {
            // 权限请求失败（Activity 已在销毁等）：不影响播放，通知可能不显示
            Log.w(TAG, "请求通知权限失败：${e.message}")
        }
    }

    private fun idOf(call: MethodCall): Long =
        call.argument<Number>("textureId")!!.toLong()

    private fun player(id: Long): DashExoPlayer =
        players[id] ?: throw IllegalStateException("播放器不存在（textureId=$id）")

    private fun createPlayer(): Long {
        val registry = textureRegistry
            ?: throw IllegalStateException("插件尚未绑定 TextureRegistry")
        val entry = registry.createSurfaceTexture()
        // Dart 侧 Texture(textureId:) 必须用引擎分配的纹理 id（entry.id()），
        // 而非自增序号——否则 Texture 找不到对应纹理 → 有声音无画面（黑屏）。
        // 与 video_player_android 同源（surfaceTextureEntry.id()）。
        val id = entry.id()
        Log.i(TAG, "createPlayer: Dart textureId=$id (engine surfaceTexture)")

        players[id] = DashExoPlayer(
            context!!,
            entry,
            kBrowserUA,
            object : DashExoPlayer.Listener {
                override fun onPrepared(
                    width: Int,
                    height: Int,
                    durationMs: Long,
                    playWhenReady: Boolean,
                ) {
                    eventSink.success(
                        mapOf(
                            "event" to "onPrepared",
                            "textureId" to id,
                            "width" to width,
                            "height" to height,
                            "durationMs" to durationMs,
                            // 真实播放意图：Dart 侧据此决定界面播放态（暂停态下
                            // seek 也会走到 onPrepared，不能无条件当成「正在播放」）
                            "playWhenReady" to playWhenReady,
                        )
                    )
                }

                override fun onCompleted() {
                    eventSink.success(mapOf("event" to "onCompleted", "textureId" to id))
                }

                override fun onError(code: Int, msg: String) {
                    eventSink.success(
                        mapOf(
                            "event" to "onError",
                            "textureId" to id,
                            "code" to code,
                            "message" to msg,
                        )
                    )
                }

                override fun onUrlExpired() {
                    eventSink.success(mapOf("event" to "onUrlExpired", "textureId" to id))
                }

                override fun onPlayWhenReadyChanged(playWhenReady: Boolean) {
                    // 通知栏按钮 / 耳机媒体键触发的播放暂停 → 回推 Dart 对齐界面状态
                    eventSink.success(
                        mapOf(
                            "event" to "onMediaAction",
                            "textureId" to id,
                            "action" to if (playWhenReady) "play" else "pause",
                            "positionMs" to 0L,
                        )
                    )
                }

                override fun onSeeked(positionMs: Long) {
                    // 通知栏快退/快进 15 秒、拖动等 → 回推新位置
                    eventSink.success(
                        mapOf(
                            "event" to "onMediaAction",
                            "textureId" to id,
                            "action" to "seek",
                            "positionMs" to positionMs,
                        )
                    )
                }
            },
        )
        return id
    }

    private fun disposePlayer(id: Long) {
        // 先摘通知（通知的会话正驱动这个播放器，必须比播放器先释放）
        if (notification?.boundTextureId == id) notification?.release()
        players.remove(id)?.dispose()
    }

    /**
     * 事件队列：Dart 侧 EventChannel 订阅可能晚于原生事件（如 onPrepared），
     * 先入队，onListen 建立 sink 后统一冲刷。
     */
    private class QueuingEventSink : EventChannel.StreamHandler {
        private val queue = ArrayList<Any>()
        private var sink: EventChannel.EventSink? = null

        @Synchronized
        fun success(event: Any) {
            if (sink != null) sink!!.success(event) else queue.add(event)
        }

        @Synchronized
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            sink = events
            for (e in queue) events.success(e)
            queue.clear()
        }

        @Synchronized
        override fun onCancel(arguments: Any?) {
            sink = null
        }

        @Synchronized
        fun clear() {
            sink = null
            queue.clear()
        }
    }
}
