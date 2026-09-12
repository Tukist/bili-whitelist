package com.biliwhitelist.bili_whitelist_app

import android.content.Context
import android.graphics.SurfaceTexture
import android.net.Uri
import android.util.Log
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.flutter.view.TextureRegistry
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * 单播放器封装：B 站 DASH 双流（video/audio 各一条 .m4s）合并播放。
 *
 * 设计保持"哑"：只响应 Dart 侧方法调用，前后台切换等生命周期由 Dart 播放页处理。
 * 防盗链（M0 实测）：流请求必须带 Referer + 浏览器 UA（双必需），流请求不带 cookie；
 * 流 URL 带 deadline/upsig 数分钟过期 → 播放时必须实时取，不可持久化缓存。
 *
 * 本地缓存播放：Dart 侧传 `file://`（或本地绝对路径）时走 [DefaultDataSource]
 * （file scheme → FileDataSource，无需防盗链头），其余逻辑（MergingMediaSource/
 * 事件/onUrlExpired）不变；本地文件不产生 HttpDataSource 错误，onUrlExpired 不误报。
 *
 * 媒体通知 / 耳机按键（v2.25.x）：本类不管通知，只把 `playWhenReady` 与 seek 事件
 * 通过 [Listener] 上报（见 [Listener.onPlayWhenReadyChanged] / [Listener.onSeeked]）；
 * 通知与会话由 [DashMediaNotification] 持有，通过 [mediaPlayer] 直接驱动播放器。
 */
private const val TAG = "DashExoPlayer"

/** 通知栏 / 耳机「快退、快进」步长（毫秒）：与 B 站媒体通知一致（15 秒）。 */
private const val kSeekIncrementMs = 15_000L

class DashExoPlayer(
    context: Context,
    private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
    userAgent: String,
    private val listener: Listener,
) {
    /** 保留 applicationContext 供本地数据源使用（构造参数只在属性初始化期可用）。 */
    private val appContext: Context = context

    /**
     * 当前视频的展示信息：写进 [MediaItem] 的 [MediaMetadata]，供**会话侧**
     * 消费者（Android Auto / 车机 / Wear 的 MediaController、`dumpsys media_session`）
     * 读到；本 App 自己那条通知的标题 / 副标题 / 封面由 [DashMediaNotification]
     * 渲染（防盗链头不同）。
     */
    data class Meta(val title: String, val artist: String, val coverUrl: String)

    /** 播放器事件回调（主线程触发），由插件层转成 EventChannel 事件推给 Dart。 */
    interface Listener {
        /**
         * 准备完成：[width]/[height] 为视频像素尺寸，[durationMs] 为总时长（未知时为 0）。
         *
         * ⚠️ **每次进 `STATE_READY` 都会回调**（不只 setDataSource 之后：seek、
         * 重新缓冲后也会），所以 [playWhenReady] 必须带上——Dart 侧据此决定界面
         * 播放态，否则「暂停态下 seek」会被误报成「正在播放」（v2.25.0-r2 修复）。
         */
        fun onPrepared(width: Int, height: Int, durationMs: Long, playWhenReady: Boolean)

        /** 播放到结尾。 */
        fun onCompleted()

        /** 不可自动恢复的播放错误：[code] 为 ExoPlayer errorCode，[msg] 为可读信息。 */
        fun onError(code: Int, msg: String)

        /** 可自动恢复的数据源错误（URL 过期 / 瞬时网络错误）：Dart 侧重取 playurl
         *  后调 prepare 续播（保留位置），避免弹错误打断观看。 */
        fun onUrlExpired()

        /**
         * `playWhenReady` 变化：用户经**通知栏按钮 / 耳机媒体键**点了播放或暂停。
         * 用 playWhenReady（用户意图）而不是 isPlaying（缓冲中会翻成 false）——
         * 否则每次缓冲抖动都会让播放页的播放/暂停图标闪一下。
         */
        fun onPlayWhenReadyChanged(playWhenReady: Boolean)

        /** 发生 seek（通知栏快退/快进 15 秒、拖动、断点恢复等）：回传新位置（毫秒）。 */
        fun onSeeked(positionMs: Long)
    }

    private val surfaceTexture: SurfaceTexture = surfaceTextureEntry.surfaceTexture().apply {
        // 默认缓冲尺寸；onVideoSizeChanged 拿到真实分辨率后再精确更新
        setDefaultBufferSize(1920, 1080)
    }
    private val surface = Surface(surfaceTexture)

    /** 共享数据源工厂：video/audio 两个 ProgressiveMediaSource 共用防盗链头。
     *
     * 超时取值（v2.17.14）：Media3 DefaultHttpDataSource 默认 connect/read 均为 8s，
     * 弱网/抖动（慢速读流、秒级断流）容易在 8s 处被误判超时 → 弹「播放失败（2001）」
     * 打断观看。调大为 connect 15s / read 20s：
     * - connect 15s：弱网建连、首字节慢时不再误判连接失败；
     * - read 20s：单次 socket 读超时——正常传输数据是连续的，超过 20s 收不到任何
     *   字节 ≈ 连接已死；宁可多等，配合原生重试/自动续播兜底，不在慢网上误弹错。
     */
    private val dataSourceFactory = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(15_000)
        .setReadTimeoutMs(20_000)
        .setDefaultRequestProperties(
            mapOf(
                "Referer" to "https://www.bilibili.com/",
                "User-Agent" to userAgent,
            )
        )

    /** 本地文件数据源：`file://` / 本地绝对路径走本地读取，不设置防盗链头。 */
    private val localDataSourceFactory = DefaultDataSource.Factory(appContext)

    /** 当前倍速（Dart 侧每次 setPlaybackSpeed 更新；prepare 兜底用，防止换源后被重置）。 */
    @Volatile
    private var speed: Float = 1f

    private val player: ExoPlayer = ExoPlayer.Builder(appContext).apply {
        // 通知栏「快退 15 秒 / 快进 15 秒」与耳机线控的 seekBack()/seekForward()
        // 都按这个步长走（默认 5s/15s 不符合 B 站习惯，这里统一 15s）
        setSeekBackIncrementMs(kSeekIncrementMs)
        setSeekForwardIncrementMs(kSeekIncrementMs)
    }.build().apply {
        setVideoSurface(surface)
        addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_READY -> emitPrepared()
                    Player.STATE_ENDED -> listener.onCompleted()
                    else -> Unit
                }
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                // 按真实视频分辨率更新纹理缓冲尺寸，保证清晰度
                if (videoSize.width > 0 && videoSize.height > 0) {
                    Log.i(TAG, "onVideoSizeChanged ${videoSize.width}x${videoSize.height}")
                    surfaceTexture.setDefaultBufferSize(videoSize.width, videoSize.height)
                }
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                listener.onPlayWhenReadyChanged(playWhenReady)
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                // 只回传 seek（通知栏快退快进 / 拖动 / 断点恢复）：其他原因（自动
                // 跳变、repeat）不是用户操作，不必让 Dart 侧刷新状态
                if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                    listener.onSeeked(newPosition.positionMs)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                if (isRecoverableSourceError(error)) {
                    // URL 过期或瞬时网络错误（超时/断连/5xx 等）：交给 Dart 侧重取
                    // playurl 续播（保留位置），不弹错误打断观看
                    listener.onUrlExpired()
                } else {
                    listener.onError(
                        error.errorCode,
                        error.message ?: error.cause?.message ?: "播放失败",
                    )
                }
            }
        })
    }

    /** 底层播放器：媒体会话（耳机媒体键）与媒体通知直接读它的播放状态。 */
    val mediaPlayer: Player get() = player

    /**
     * 组源并播放：video/audio 各建 ProgressiveMediaSource，再 MergingMediaSource 合并。
     * [audioUrl] 传空/Null 时退化为 mp4 单流（老视频降级）。[positionMs] 用于过期续播。
     *
     * 本地缓存（[isLocalUri]）走 [localDataSourceFactory]（无防盗链头）；
     * 网络流走 [dataSourceFactory]（Referer + UA）。
     *
     * [meta] 非空时写进 video 源 MediaItem 的 MediaMetadata（标题 / UP 名 / 封面
     * URL）——系统媒体控件与「媒体续播」卡片据此显示，不影响解码与播放。
     */
    fun prepare(
        videoUrl: String,
        audioUrl: String?,
        positionMs: Long,
        meta: Meta? = null,
    ) {
        val videoFactory = if (isLocalUri(videoUrl)) localDataSourceFactory else dataSourceFactory
        val videoSource = ProgressiveMediaSource.Factory(videoFactory)
            .createMediaSource(buildMediaItem(videoUrl, meta))
        val mediaSource = if (audioUrl.isNullOrEmpty()) {
            videoSource
        } else {
            val audioFactory = if (isLocalUri(audioUrl)) localDataSourceFactory else dataSourceFactory
            val audioSource = ProgressiveMediaSource.Factory(audioFactory)
                .createMediaSource(MediaItem.fromUri(audioUrl))
            MergingMediaSource(videoSource, audioSource)
        }
        // resetPosition=false：不重置位置，之后显式 seekTo（供 URL 过期续播）
        player.setMediaSource(mediaSource, /* resetPosition= */ false)
        player.seekTo(positionMs)
        player.prepare()
        player.play()
        // 兜底：换源（prepare）后按当前倍速重设，防被重置回 1x
        if (speed != 1f) player.setPlaybackSpeed(speed)
    }

    /** 组 MediaItem：带展示元信息（会话侧消费者读）；字段为空则不带，保持干净。 */
    private fun buildMediaItem(url: String, meta: Meta?): MediaItem {
        if (meta == null) return MediaItem.fromUri(url)
        val metadata = MediaMetadata.Builder()
            .setTitle(meta.title.ifEmpty { null })
            .setArtist(meta.artist.ifEmpty { null })
            .setArtworkUri(meta.coverUrl.takeIf { it.isNotEmpty() }?.let { Uri.parse(it) })
            .build()
        return MediaItem.Builder().setUri(url).setMediaMetadata(metadata).build()
    }

    /** 是否为本地文件地址：`file:` scheme，或不存在 scheme 的绝对路径。 */
    private fun isLocalUri(url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        if (url.startsWith("file:")) return true
        return !url.contains("://") && url.startsWith("/")
    }

    fun play() = player.play()

    fun pause() = player.pause()

    fun seekTo(positionMs: Long) = player.seekTo(positionMs)

    /**
     * 设置播放倍速。ExoPlayer(Media3) 合法区间约 [0.25, 4.0]（PlaybackParameters），
     * 档位上限 3.0 在内；越界 clamp 到区间边界。
     */
    fun setPlaybackSpeed(speed: Float) {
        val clamped = speed.coerceIn(0.25f, 4.0f)
        this.speed = clamped
        player.setPlaybackSpeed(clamped)
        Log.i(TAG, "setPlaybackSpeed $clamped")
    }

    fun setVolume(volume: Float) {
        player.volume = volume
    }

    fun getPosition(): Long = player.currentPosition

    /** 准备完成：回报视频宽高与总时长（ms）+ 当前播放意图，Dart 侧据此初始化进度条与播放态。 */
    private fun emitPrepared() {
        val duration = if (player.duration == C.TIME_UNSET) 0L else player.duration
        val size = player.videoSize
        // playWhenReady（用户意图）而不是 isPlaying（缓冲中会翻成 false）：
        // 暂停态下 seek 也会走到这里，带上它 Dart 才不会把界面改成「正在播放」
        listener.onPrepared(size.width, size.height, duration, player.playWhenReady)
    }

    /**
     * 可自动恢复的数据源错误判定：URL 过期或瞬时网络错误 → true（Dart 重取流续播）。
     *
     * 沿 cause 链查找两类特征：
     * 1) URL 过期/被拦：HttpDataSource 403/404/410（流地址 deadline/upsig 过期、
     *    防盗链）；429/5xx 属 CDN/网关瞬时故障，重取流（换新签名地址）同样可自愈；
     * 2) 瞬时网络错误：读/建连超时（SocketTimeoutException）、域名解析失败
     *    （UnknownHostException）、连接被重置/拒绝/断开（SocketException 及其子类
     *    ConnectException）——网络抖动多属此类。
     *    Media3 1.5.x 已移除 HttpDataSource.TimeoutException，超时以
     *    HttpDataSourceException 包装 SocketTimeoutException 呈现（本函数沿 cause
     *    链可达内层），因此按 java.net 原生异常判定，不依赖 media3 具体包装类型。
     *
     * 其余（格式损坏/解码失败/本地文件缺失等）为真失败 → 走 onError 弹错误。
     */
    private fun isRecoverableSourceError(error: PlaybackException): Boolean {
        var cause: Throwable? = error.cause ?: error
        while (cause != null) {
            if (cause is HttpDataSource.InvalidResponseCodeException) {
                val code = cause.responseCode
                if (code in setOf(403, 404, 410, 429) || code in 500..599) return true
            }
            if (cause is SocketTimeoutException || cause is UnknownHostException ||
                cause is SocketException
            ) {
                return true
            }
            cause = cause.cause
        }
        return false
    }

    fun dispose() {
        player.release()
        surface.release()
        surfaceTexture.release()
        surfaceTextureEntry.release()
    }
}
