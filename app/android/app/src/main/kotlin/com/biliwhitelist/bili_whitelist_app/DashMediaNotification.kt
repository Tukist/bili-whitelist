package com.biliwhitelist.bili_whitelist_app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.NotificationUtil
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.ui.PlayerNotificationManager
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.net.HttpURLConnection
import java.net.URL

private const val TAG = "DashMediaNotification"

/**
 * 会话自定义命令：系统媒体卡片 / 锁屏 / 耳机上的「快退 15 秒 / 快进 15 秒 / 关闭」。
 *
 * 为什么必须是自定义命令而不是通知自带的 MediaStyle action：Android 13+ 起
 * 系统**不再渲染 App 写进通知的媒体按钮**（实测 `dumpsys notification` 里
 * 通知带着 4 个 action，但 `uiautomator dump` 的媒体卡片上只有 `Previous track`
 * 与 `Play` 两个节点），卡片只按**会话**的可用命令 / 自定义布局渲染。
 */
private const val kActionRewind15 = "com.biliwhitelist.amotv.action.REWIND_15"
private const val kActionForward15 = "com.biliwhitelist.amotv.action.FORWARD_15"
private const val kActionClose = "com.biliwhitelist.amotv.action.CLOSE"

/** 快退 / 快进步长（毫秒）：与 [DashExoPlayer] 的 seekBack/ForwardIncrementMs 一致。 */
private const val kSeekStepMs = 15_000L

/** 通知渠道 id（Android 8+ 在系统通知设置里按渠道展示）。 */
private const val kChannelId = "amo_tv_playback"

/** 通知 id：同一时刻只存在一条播放通知（换通知 = 同 id 覆盖）。 */
private const val kNotificationId = 0x4D5001

/** 封面图下载超时（毫秒）：图挂了不能拖住通知。 */
private const val kCoverConnectTimeoutMs = 10_000
private const val kCoverReadTimeoutMs = 15_000

/**
 * B 站式**媒体通知 + 媒体会话**（v2.25.x，用户需求：「和 B 站一样的通知，
 * 可以用耳机控制暂停继续」）。
 *
 * 组成（全部用项目已有的 media3 体系，只多引入同版本 media3-session / media3-ui）：
 * - [MediaSession]（media3-session）：包住 [DashExoPlayer.mediaPlayer]。它内部建了
 *   一个系统 `android.media.session.MediaSession`，**耳机 / 蓝牙的媒体键**
 *   （KEYCODE_MEDIA_PLAY_PAUSE 等）由系统派发到当前活跃会话 → media3 直接驱动
 *   [`Player.play()`]/[`Player.pause()`]，无需我们写 BroadcastReceiver。
 * - 会话**自定义命令**（v2.25.0-r2）：`快退 15 秒 / 快进 15 秒 / 关闭` 三个动作由
 *   [callback] 的 `onCustomCommand` 实现、经 [customLayout] 暴露给 MediaController
 *   类控制器（Android Auto / Wear / 车机的媒体浏览器、以及 `cmd media_session`
 *   这类可发送自定义命令的客户端）。见 [callback] 注释。
 * - [PlayerNotificationManager]（media3-ui）：生成通知——左侧封面、标题、副标题
 *   （`UP 名 · 状态`）、右侧 `快退15s / 播放暂停 / 快进15s / 关闭(✕)`。通知按钮由
 *   它自己的广播接收器处理（直接调 player.seekBack()/seekForward()/play()/
 *   pause()/stop()），播放/暂停图标由**播放器状态**驱动，不会与真实状态不符。
 *   ⚠️ 这条通知**不绑会话 token**（详见 [bind] 里的说明）：绑了就会被 Android 13+
 *   收进系统媒体卡片，而那张卡片只渲染系统自己的固定槽位（prev/play-pause/next），
 *   快退/快进/关闭在它上面永远点不到。
 *
 * 只服务**一个**播放器（[bind] 时记录 textureId）：播放页可能同时存在两个播放器
 * （评论区点链接 push 新播放页，旧页暂停让位），通知始终跟随 Dart 侧最后同步的那个。
 *
 * 状态同步方向（两个方向都要，否则会出现「通知暂停了但界面还在播」）：
 * - Dart → 原生：标题 / UP 名 / 封面 / 状态文案（[update]）；
 * - 原生 → Dart：播放暂停、seek、关闭（✕）→ 经 [onAction] 回推，见插件层事件
 *   `onMediaAction`。
 *
 * ⚠️ 封面图必须带防盗链头（Referer + 浏览器 UA）：B 站图床对无 Referer/UA 的
 * 请求可能 403（与 [DashExoPlayer] 流请求同源问题），所以这里自己下载而不用
 * media3 的 [PlayerNotificationManager.MediaDescriptionAdapter] 默认实现
 * （默认实现只认 MediaItem 的 artworkData，且不会带这些头）。
 */
class DashMediaNotification(
    private val context: Context,
    private val userAgent: String,
    private val onAction: (textureId: Long, action: String, positionMs: Long) -> Unit,
) {
    /** 通知上展示的文案（Dart 侧 [update] 写入，通知适配器在主线程读）。 */
    private var title = ""
    private var artist = ""
    private var status = ""
    private var coverUrl = ""

    /** 最近一次 Dart 上报的状态：仅记录，通知渲染一律以播放器自身状态为准。 */
    private var lastPlaying = false
    private var lastPositionMs = 0L
    private var lastDurationMs = 0L

    private var session: MediaSession? = null
    private var manager: PlayerNotificationManager? = null
    private var boundPlayer: Player? = null

    /** 当前绑定的播放器 textureId（null = 没有绑定）。 */
    var boundTextureId: Long? = null
        private set

    /**
     * 拆解中标志：拆会话 / 换播放器时会引发 [PlayerNotificationManager] 取消通知，
     * 那不是用户按了「关闭（✕）」，不能回推 Dart（否则界面会被误收成「已停止」）。
     */
    private var tearingDown = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 封面图缓存：同一 URL 只下载一次，换视频时自动失效。 */
    private var coverBitmap: Bitmap? = null
    private var coverBitmapUrl: String? = null

    // -------------------------------------------------------------------------
    // 会话自定义命令（快退 15s / 快进 15s / 关闭）
    // -------------------------------------------------------------------------

    /** 三个自定义命令（顺序与 [customLayout] 一致）。 */
    private val customCommands = listOf(
        SessionCommand(kActionRewind15, Bundle.EMPTY),
        SessionCommand(kActionForward15, Bundle.EMPTY),
        SessionCommand(kActionClose, Bundle.EMPTY),
    )

    /**
     * 暴露给系统媒体卡片 / 锁屏 / 车载 / 手表的自定义按钮。
     *
     * 槽位（[CommandButton.setSlots]）是 media3 给「带屏控制器」（Android Auto、
     * Wear OS）排布用的；SystemUI 的媒体卡片只按命令可用性渲染，两者都覆盖到。
     */
    private val customLayout = listOf(
        CommandButton.Builder(CommandButton.ICON_SKIP_BACK_15)
            .setSessionCommand(customCommands[0])
            .setDisplayName("快退 15 秒")
            .setSlots(CommandButton.SLOT_BACK)
            .build(),
        CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_15)
            .setSessionCommand(customCommands[1])
            .setDisplayName("快进 15 秒")
            .setSlots(CommandButton.SLOT_FORWARD)
            .build(),
        CommandButton.Builder(CommandButton.ICON_STOP)
            .setSessionCommand(customCommands[2])
            .setDisplayName("关闭")
            .setSlots(CommandButton.SLOT_OVERFLOW)
            .build(),
    )

    /**
     * 会话回调：把自定义命令**真正执行掉**（通知只是入口，动作在这里落地）。
     *
     * - `快退 15 秒` / `快进 15 秒`：显式 `seekTo(currentPosition ∓ 15000)` 并夹到
     *   `[0, duration]`。⚠️ **不能**用 media3 的 `seekToPrevious()` —— 单集播放时
     *   它等价于「回到本条开头」（实测点卡片 ⏮ 位置直接归 0），语义不是快退 15 秒。
     *   seek 引发的 `onPositionDiscontinuity(SEEK)` 由 [DashExoPlayer] 上报 Dart，
     *   界面位置随之对齐，这里不重复回推。
     * - `关闭`：等同通知上的 ✕（停播 + 清媒体项 + 撤下通知 + 回推 Dart）。
     *
     * `onConnect` 里把三个命令加进该控制器的**可用会话命令**：legacy 控制器
     * （SystemUI / 蓝牙 / 车机走的都是 legacy 通道）只有声明过才拿得到这些
     * 自定义 action，否则 `dumpsys media_session` 里 `custom actions=[]`、卡片上
     * 也就没有按钮可点。
     */
    private val callback = object : MediaSession.Callback {
        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult =
            MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(
                    MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                        .addSessionCommands(customCommands)
                        .build()
                )
                .setCustomLayout(customLayout)
                .build()

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            val player = boundPlayer ?: return notSupported()
            when (customCommand.customAction) {
                kActionRewind15 -> seekBy(player, -kSeekStepMs)
                kActionForward15 -> seekBy(player, kSeekStepMs)
                kActionClose -> closeBySession(player)
                else -> return notSupported()
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }
    }

    private fun notSupported(): ListenableFuture<SessionResult> =
        Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED))

    /**
     * 快退 / 快进 [deltaMs] 毫秒（负数 = 快退），夹到 `[0, duration]`。
     *
     * 见 [callback] 注释：这是「快退 15 秒」的正确实现（不是 `seekToPrevious`）。
     */
    private fun seekBy(player: Player, deltaMs: Long) {
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }
        val target = (player.currentPosition + deltaMs).coerceAtLeast(0L)
        val clamped = duration?.let { target.coerceAtMost(it) } ?: target
        Log.i(TAG, "seekBy ${deltaMs}ms：${player.currentPosition} → $clamped")
        player.seekTo(clamped)
    }

    /** 「关闭」：停播 + 清媒体项 + 撤下通知，并回推 Dart 收尾（等同通知上的 ✕）。 */
    private fun closeBySession(player: Player) {
        val id = boundTextureId
        Log.i(TAG, "会话「关闭」→ 停止播放并撤下通知 textureId=$id")
        player.stop()
        player.clearMediaItems()
        // setPlayer(null) 撤下通知；它同时触发 onNotificationCancelled 回推一次
        // "stop"（Dart 侧 _onStoppedByNotification 幂等，重复无副作用）
        manager?.setPlayer(null)
        if (id != null) onAction(id, "stop", 0L)
    }

    /**
     * 绑定/更新通知（Dart 侧 `updateNowPlaying` 调用，主线程）。
     *
     * - [id]/[player] 与当前绑定不同 → 先释放旧的（会话 + 通知），再为新的建一套
     *   （播放页切换/换源会走到这条路径）；
     * - 同一播放器 → 只更新文案并刷新通知。
     */
    fun bind(
        id: Long,
        player: Player,
        title: String,
        artist: String,
        coverUrl: String,
        status: String,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
    ) {
        if (boundTextureId == id && boundPlayer === player) {
            update(title, artist, coverUrl, status, playing, positionMs, durationMs)
            return
        }
        release()
        // release() 里置过 tearingDown，新绑定必须复位（下次拆解才拦得住事件）
        tearingDown = false
        this.title = title
        this.artist = artist
        this.status = status
        this.coverUrl = coverUrl
        this.lastPlaying = playing
        this.lastPositionMs = positionMs
        this.lastDurationMs = durationMs
        boundTextureId = id
        boundPlayer = player

        // 会话包住的是「摘掉上下集命令」的包装器（见 [NoPrevNextPlayer]）：单集
        // 播放时 media3 仍会声明 COMMAND_SEEK_TO_PREVIOUS 可用，SystemUI 据此把
        // 卡片按钮渲染成 `Previous track` 并调 seekToPrevious() → 实测**跳回开头**。
        // 播放本身与通知仍走真实播放器，只有会话看到的是这个包装器。
        val newSession = MediaSession.Builder(context, NoPrevNextPlayer(player))
            // 点通知回到 App（MainActivity 是 singleTop，不新建任务栈）
            .setSessionActivity(contentIntent())
            .setCallback(callback)
            .build()
            .apply {
                // 自定义按钮（快退 15s / 快进 15s / 关闭）：Android 13+ 的系统媒体
                // 卡片只按会话命令渲染，这是它们唯一能被点到的途径
                setCustomLayout(customLayout)
            }
        val newManager = PlayerNotificationManager.Builder(
            context, kNotificationId, kChannelId,
        )
            .setChannelNameResourceId(R.string.playback_notification_channel_name)
            .setChannelDescriptionResourceId(R.string.playback_notification_channel_desc)
            // 低干扰渠道：不出声、不震动、不弹横幅（播放控制不需要打断用户）
            .setChannelImportance(NotificationUtil.IMPORTANCE_LOW)
            .setMediaDescriptionAdapter(adapter)
            .setNotificationListener(notificationListener)
            .build()
            // ⚠️ v2.25.0-r2：**故意不**调 setMediaSessionToken()。
            //
            // 绑了会话 token 的通知会被 Android 13+ 的 SystemUI 收进「媒体卡片」
            // （MediaCarousel），按**会话的标准命令**重绘按钮 —— 实测卡片上只剩
            // ⏯（系统对单集视频还会把 ⏮ 映射成 seekToPrevious = 回开头），App 自己
            // 配的 `快退15s / 播放暂停 / 快进15s / 关闭(✕)` 一个都不渲染；media3
            // 1.5.1 也**不会**把 setCustomLayout 的按钮导出到 PlaybackState
            // （MediaSessionLegacyStub 里没有 addCustomAction，实测 `dumpsys
            // media_session` 恒为 `custom actions=[]`）→ 卡片上不可能有快退/快进/关闭。
            //
            // 不绑 token 后它是**普通通知**（media3 的 MediaStyle 对 null token 有显式
            // 判空，见 PlayerNotificationManager$MediaStyle），四个 action 由本 App
            // 的通知自己渲染，语义正确：Rewind/Fast forward 走 player.seekBack()/
            // seekForward()（= ExoPlayer 的 15s 步长，不是「回开头」），✕ 走 stop()。
            //
            // 耳机 / 蓝牙媒体键不受影响：仍由上面的 [MediaSession] 接收（它是当前
            // PLAYING 的活跃会话，`dumpsys media_session` 里 Media button session 仍是它）。
            .apply {
                setUsePreviousAction(false) // 本 App 无播放列表，不出现上一/下一曲
                setUseNextAction(false)
                setUseRewindAction(true) // 快退 15 秒（ExoPlayer seekBackIncrementMs）
                setUseFastForwardAction(true) // 快进 15 秒
                // 收起态（compact）也显示快退/快进，与 B 站一致：`15 ◀ ▶ 15 ▶`
                setUseRewindActionInCompactView(true)
                setUseFastForwardActionInCompactView(true)
                setUseStopAction(true) // ✕：停止播放 + 移除通知（media3 内部 player.stop()）
                setPriority(NotificationCompat.PRIORITY_LOW)
                setVisibility(NotificationCompat.VISIBILITY_PUBLIC) // 锁屏可见
            }
        session = newSession
        manager = newManager
        // setPlayer 会立即起通知（播放器非 IDLE 时），后续由播放器状态变化自动刷新
        newManager.setPlayer(player)
        Log.i(
            TAG,
            "bind textureId=$id title=$title artist=$artist status=$status " +
                "playing=$playing pos=$positionMs duration=$durationMs",
        )
    }

    /** 只更新文案/封面并刷新通知（换集、播放暂停、听视频开关等状态变化）。 */
    fun update(
        title: String,
        artist: String,
        coverUrl: String,
        status: String,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
    ) {
        val changed = title != this.title || artist != this.artist ||
            status != this.status || coverUrl != this.coverUrl
        this.title = title
        this.artist = artist
        this.status = status
        this.coverUrl = coverUrl
        this.lastPlaying = playing
        this.lastPositionMs = positionMs
        this.lastDurationMs = durationMs
        Log.d(
            TAG,
            "update textureId=$boundTextureId title=$title status=$status " +
                "playing=$playing pos=$positionMs duration=$durationMs",
        )
        if (changed) manager?.invalidate()
    }

    /** 释放会话与通知（播放器被释放 / 页面退出 / 换绑定对象时调用）。 */
    fun release() {
        tearingDown = true
        // setPlayer(null) 会取消通知（media3 文档要求：释放播放器前必须先摘掉）
        manager?.setPlayer(null)
        manager = null
        session?.release()
        session = null
        boundPlayer = null
        boundTextureId = null
        coverBitmap = null
        coverBitmapUrl = null
    }

    // -------------------------------------------------------------------------
    // 通知内容适配器
    // -------------------------------------------------------------------------

    private val adapter = object : PlayerNotificationManager.MediaDescriptionAdapter {
        override fun getCurrentContentTitle(player: Player): CharSequence = title

        override fun createCurrentContentIntent(player: Player): PendingIntent =
            contentIntent()

        /** 副标题：`UP 名 · 状态`（如 `阵左阵左 · 后台听视频省流量`，与 B 站一致）。 */
        override fun getCurrentContentText(player: Player): CharSequence =
            if (artist.isEmpty()) status else "$artist · $status"

        override fun getCurrentLargeIcon(
            player: Player,
            callback: PlayerNotificationManager.BitmapCallback,
        ): Bitmap? {
            val url = coverUrl
            if (url.isEmpty()) return null
            if (coverBitmapUrl == url) return coverBitmap // 已下载：同步给出
            // 未下载：先返回 null（通知用应用图标占位），下载完成后回调刷新
            loadCover(url, callback)
            return null
        }
    }

    private val notificationListener = object : PlayerNotificationManager.NotificationListener {
        override fun onNotificationCancelled(notificationId: Int, dismissedByUser: Boolean) {
            if (tearingDown) return // 我们自己拆的（换绑定/释放播放器）
            if (dismissedByUser) {
                // 用户把通知划掉（仅暂停态可划）：不动播放，通知会在下次播放
                // 状态变化时由 media3 自动恢复
                Log.i(TAG, "通知被用户划掉：播放不中断")
                return
            }
            // 通知自行取消 + 非用户划掉 = 用户按了「关闭（✕）」：media3 的
            // ACTION_STOP 会调 player.stop()（播放器转 IDLE → 同一条播放器状态
            // 变化路径取消通知）→ 回推 Dart 收尾
            Log.i(TAG, "通知「关闭（✕）」→ 回推 Dart 收尾 textureId=$boundTextureId")
            boundTextureId?.let { onAction(it, "stop", 0L) }
        }
    }

    /** 通知点击 → 回到 App 播放页（MainActivity singleTop，不新起任务栈）。 */
    private fun contentIntent(): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    // -------------------------------------------------------------------------
    // 封面图（带防盗链头，异步下载）
    // -------------------------------------------------------------------------

    /**
     * 异步下载封面并回填通知。
     *
     * 不缓存 URL 以外的状态：换视频时 [coverUrl] 立刻变，旧图无论如何都不会被
     * 用上（回调前再校验一次 URL）。URL 不同即重新下载，因此「快速换集」也能
     * 在最后一次 [update] 后拿到正确的封面。
     */
    private fun loadCover(url: String, callback: PlayerNotificationManager.BitmapCallback) {
        Thread {
            val bitmap = downloadBitmap(url)
            mainHandler.post {
                if (bitmap == null || url != coverUrl) return@post // 已换视频：丢弃旧图
                coverBitmap = bitmap
                coverBitmapUrl = url
                callback.onBitmap(bitmap)
            }
        }.start()
    }

    /** 下载封面：带 Referer + 浏览器 UA（与播放流同一套防盗链要求）。 */
    private fun downloadBitmap(url: String): Bitmap? {
        // 明文 HTTP 会被 App 的 cleartext 策略直接拒绝（实测
        // `Cleartext HTTP traffic to i2.hdslb.com not permitted`，部分视频的
        // cover 字段就是 http://）→ 统一升到 https（B 站图床同域支持）。
        val secureUrl = if (url.startsWith("http://")) "https://${url.substring(7)}" else url
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(secureUrl).openConnection() as HttpURLConnection).apply {
                connectTimeout = kCoverConnectTimeoutMs
                readTimeout = kCoverReadTimeoutMs
                instanceFollowRedirects = true
                setRequestProperty("Referer", "https://www.bilibili.com/")
                setRequestProperty("User-Agent", userAgent)
            }
            conn.connect()
            if (conn.responseCode != HttpURLConnection.HTTP_OK) {
                Log.w(TAG, "封面下载失败：HTTP ${conn.responseCode} $secureUrl")
                null
            } else {
                conn.inputStream.use { BitmapFactory.decodeStream(it) }
            }
        } catch (e: Exception) {
            // 封面只是增强：失败就继续用应用图标，不抛给调用方
            Log.w(TAG, "封面下载异常：${e.message} $secureUrl")
            null
        } finally {
            conn?.disconnect()
        }
    }
}

/**
 * 会话用播放器包装：从可用命令里摘掉「上一集 / 下一集」（v2.25.0-r2）。
 *
 * 单集播放没有上下集，但 media3 的 ExoPlayer 只要设了 `seekBackIncrementMs`
 * 就会把 `COMMAND_SEEK_TO_PREVIOUS` 声明为可用，SystemUI 的媒体卡片据此把按钮
 * 渲染成 `Previous track`（`uiautomator dump` 实测），点了走
 * `seekToPrevious()` —— 而 ExoPlayer 单集时的实现是**回到本条开头**，
 * 不是用户要的「快退 15 秒」（实测：位置从 30s 归 0）。
 *
 * 摘掉这四个命令后，卡片只能按 `ACTION_REWIND` / `ACTION_FAST_FORWARD`
 * 渲染「快退 / 快进」，语义与 [DashExoPlayer] 的 15 秒步长一致。
 *
 * 只包装**给会话看**的玩家；通知（[PlayerNotificationManager]）与播放行为仍走
 * 真实 ExoPlayer，不受包装器影响。
 */
private class NoPrevNextPlayer(player: Player) : ForwardingPlayer(player) {
    override fun getAvailableCommands(): Player.Commands =
        super.getAvailableCommands().buildUpon()
            .removeAll(
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            )
            .build()

    /** [ForwardingPlayer] 的默认实现会把 [isCommandAvailable] 直接转发给原播放器，
     *  这里必须一并按「摘过命令」的集合回答，否则会话仍认为上下集可用。 */
    override fun isCommandAvailable(command: Int): Boolean =
        getAvailableCommands().contains(command)
}
