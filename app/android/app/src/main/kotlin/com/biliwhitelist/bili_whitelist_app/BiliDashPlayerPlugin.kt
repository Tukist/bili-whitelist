package com.biliwhitelist.bili_whitelist_app

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

/**
 * B 站 DASH 双流播放原生插件（MethodChannel: `bili_dash_player`）。
 *
 * - `create`：创建播放器 + TextureRegistry 纹理，返回 textureId（Dart 侧 Texture 渲染）
 * - `setDataSource(videoUrl, audioUrl, positionMs)`：MergingMediaSource 组源后播放
 * - `play` / `pause` / `seekTo` / `setVolume` / `setPlaybackSpeed` / `getPosition` / `dispose`
 * - 事件通过 EventChannel `bili_dash_player/events` 回推（载荷带 textureId 区分播放器）：
 *   onPrepared(width,height,durationMs) / onCompleted / onError(code,message) / onUrlExpired
 *
 * 注册方式：应用内嵌插件（写在 app 模块）不走 GeneratedPluginRegistrant，在
 * MainActivity.configureFlutterEngine 里 `plugins.add(BiliDashPlayerPlugin())` 显式注册。
 * 纹理从 FlutterPluginBinding.textureRegistry 获取（v2 embedding 官方途径，
 * 与 video_player_android 一致）；ActivityAware 仅满足接口要求，暂不依赖 Activity。
 */
class BiliDashPlayerPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private var context: android.content.Context? = null
    private var messenger: BinaryMessenger? = null
    private var textureRegistry: TextureRegistry? = null
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    private val players = HashMap<Long, DashExoPlayer>()
    private val eventSink = QueuingEventSink()
    private var nextTextureId = 1L

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
        for (player in players.values) player.dispose()
        players.clear()
        eventSink.clear()
        context = null
        messenger = null
        textureRegistry = null
    }

    // ---- ActivityAware：满足接口要求（v2 embedding 下纹理直接从 FlutterPluginBinding 获取，与
    // video_player_android 一致，无需 Activity；此处仅记录/清理，供未来扩展使用） ----

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = Unit

    override fun onDetachedFromActivity() = Unit

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = Unit

    override fun onDetachedFromActivityForConfigChanges() = Unit

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "create" -> result.success(createPlayer())
                "setDataSource" -> {
                    val id = call.argument<Number>("textureId")!!.toLong()
                    val videoUrl = call.argument<String>("videoUrl")!!
                    val audioUrl = call.argument<String>("audioUrl")
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    player(id).prepare(videoUrl, audioUrl, positionMs)
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

    private fun idOf(call: MethodCall): Long =
        call.argument<Number>("textureId")!!.toLong()

    private fun player(id: Long): DashExoPlayer =
        players[id] ?: throw IllegalStateException("播放器不存在（textureId=$id）")

    private fun createPlayer(): Long {
        val id = nextTextureId++
        val registry = textureRegistry
            ?: throw IllegalStateException("插件尚未绑定 TextureRegistry")
        val entry = registry.createSurfaceTexture()

        players[id] = DashExoPlayer(
            context!!,
            entry,
            kBrowserUA,
            object : DashExoPlayer.Listener {
                override fun onPrepared(width: Int, height: Int, durationMs: Long) {
                    eventSink.success(
                        mapOf(
                            "event" to "onPrepared",
                            "textureId" to id,
                            "width" to width,
                            "height" to height,
                            "durationMs" to durationMs,
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
            },
        )
        return id
    }

    private fun disposePlayer(id: Long) {
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
