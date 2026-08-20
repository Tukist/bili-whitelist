package com.biliwhitelist.bili_whitelist_app

import android.content.Context
import android.graphics.SurfaceTexture
import android.util.Log
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import io.flutter.view.TextureRegistry

/**
 * 单播放器封装：B 站 DASH 双流（video/audio 各一条 .m4s）合并播放。
 *
 * 设计保持"哑"：只响应 Dart 侧方法调用，前后台切换等生命周期由 Dart 播放页处理。
 * 防盗链（M0 实测）：流请求必须带 Referer + 浏览器 UA（双必需），流请求不带 cookie；
 * 流 URL 带 deadline/upsig 数分钟过期 → 播放时必须实时取，不可持久化缓存。
 */
private const val TAG = "DashExoPlayer"

class DashExoPlayer(
    context: Context,
    private val surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry,
    userAgent: String,
    private val listener: Listener,
) {
    /** 播放器事件回调（主线程触发），由插件层转成 EventChannel 事件推给 Dart。 */
    interface Listener {
        /** 准备完成：[width]/[height] 为视频像素尺寸，[durationMs] 为总时长（未知时为 0）。 */
        fun onPrepared(width: Int, height: Int, durationMs: Long)

        /** 播放到结尾。 */
        fun onCompleted()

        /** 非 URL 过期的播放错误：[code] 为 ExoPlayer errorCode，[msg] 为可读信息。 */
        fun onError(code: Int, msg: String)

        /** 流 URL 过期（403/404/410 等）：Dart 侧重取 playurl 后调 prepare 续播。 */
        fun onUrlExpired()
    }

    private val surfaceTexture: SurfaceTexture = surfaceTextureEntry.surfaceTexture().apply {
        // 默认缓冲尺寸；onVideoSizeChanged 拿到真实分辨率后再精确更新
        setDefaultBufferSize(1920, 1080)
    }
    private val surface = Surface(surfaceTexture)

    /** 共享数据源工厂：video/audio 两个 ProgressiveMediaSource 共用防盗链头。 */
    private val dataSourceFactory = DefaultHttpDataSource.Factory()
        .setAllowCrossProtocolRedirects(true)
        .setDefaultRequestProperties(
            mapOf(
                "Referer" to "https://www.bilibili.com/",
                "User-Agent" to userAgent,
            )
        )

    /** 当前倍速（Dart 侧每次 setPlaybackSpeed 更新；prepare 兜底用，防止换源后被重置）。 */
    @Volatile
    private var speed: Float = 1f

    private val player: ExoPlayer = ExoPlayer.Builder(context).build().apply {
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

            override fun onPlayerError(error: PlaybackException) {
                if (isUrlExpiredError(error)) {
                    // URL 过期（403/404/410）：Dart 侧重取 playurl 后调 prepare 续播
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

    /**
     * 组源并播放：video/audio 各建 ProgressiveMediaSource，再 MergingMediaSource 合并。
     * [audioUrl] 传空/Null 时退化为 mp4 单流（老视频降级）。[positionMs] 用于过期续播。
     */
    fun prepare(videoUrl: String, audioUrl: String?, positionMs: Long) {
        val videoSource = ProgressiveMediaSource.Factory(dataSourceFactory)
            .createMediaSource(MediaItem.fromUri(videoUrl))
        val mediaSource = if (audioUrl.isNullOrEmpty()) {
            videoSource
        } else {
            val audioSource = ProgressiveMediaSource.Factory(dataSourceFactory)
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

    /** 准备完成：回报视频宽高与总时长（ms），Dart 侧据此初始化进度条。 */
    private fun emitPrepared() {
        val duration = if (player.duration == C.TIME_UNSET) 0L else player.duration
        val size = player.videoSize
        listener.onPrepared(size.width, size.height, duration)
    }

    /** URL 过期特征：错误根因链里出现 HttpDataSource 403/404/410。 */
    private fun isUrlExpiredError(error: PlaybackException): Boolean {
        var cause: Throwable? = error.cause ?: error
        while (cause != null) {
            if (cause is HttpDataSource.InvalidResponseCodeException &&
                cause.responseCode in setOf(403, 404, 410)
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
