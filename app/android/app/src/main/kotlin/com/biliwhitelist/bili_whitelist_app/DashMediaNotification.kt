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

/**
 * 「上一集 / 下一集」（v2.30.0-r2）：**通知自己的自定义 action**，不是会话命令。
 *
 * 为什么另起一套而不是用会话的 `ACTION_SKIP_TO_NEXT` / `seekToNext()`：
 * 实测（模拟器 API 35 + 反编译 media3-ui 1.5.1 字节码确认）——
 * 1. 单 MediaItem 的 ExoPlayer **没有** `COMMAND_SEEK_TO_NEXT`，
 *    `PlayerNotificationManager.getActions()` 对每个内建 action 都做
 *    `isCommandAvailable(...)` 门禁（Next 要 COMMAND_SEEK_TO_NEXT）→
 *    内建 ACTION_NEXT **永远生成不出来**；会话里也确实只多出
 *    `ACTION_SKIP_TO_PREVIOUS`（actions=7339999，只多 16）；
 * 2. 那个 ⏮ 点下去走 `seekToPrevious()` = **回到本条开头**（实测 1396349 → 0），
 *    不是上一集。集号只存在于 Dart 侧（`_playlistIndex`）。
 *
 * 所以「上一集 / 下一集」必须由本 App 自己实现：动作定义在这里，
 * 点按经 [DashMediaNotification.customActionReceiver] 回推 Dart
 * （`onAction(id, "prev"/"next", 0L)` → `BiliDashPlayerPlugin` 的 eventSink →
 * 播放页 `_onMediaAction` → `playNeighbor(±1)`）。
 */
private const val kActionPrevEpisode = "com.biliwhitelist.amotv.action.PREV_EPISODE"
private const val kActionNextEpisode = "com.biliwhitelist.amotv.action.NEXT_EPISODE"

/**
 * 通知广播 intent 里的 instance id extra（media3 内部约定，**不能改名**）：
 * `PlayerNotificationManager$NotificationBroadcastReceiver.onReceive` 先比对它，
 * 对不上就直接 return。
 */
private const val kExtraInstanceId = "INSTANCE_ID"

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
 *   [callback] 的 `onCustomCommand` 实现、经 [buildCustomLayout] 暴露给 MediaController
 *   类控制器（Android Auto / Wear / 车机的媒体浏览器、以及 `cmd media_session`
 *   这类可发送自定义命令的客户端）。见 [callback] 注释。
 * - [PlayerNotificationManager]（media3-ui）：生成通知——左侧封面、标题、副标题
 *   （`UP 名 · 状态`）、右侧 `快退15s / 播放暂停 / 快进15s / 关闭(✕)`。通知按钮由
 *   它自己的广播接收器处理（直接调 player.seekBack()/seekForward()/play()/
 *   pause()/stop()），播放/暂停图标由**播放器状态**驱动，不会与真实状态不符。
 *   ⚠️ 直播（`bind(isLive = true)`）只留 `播放暂停 / 关闭(✕)`：直播不可 seek
 *   （见 [NoSeekPlayer]）。
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
    private var manager: EpisodeNotificationManager? = null
    private var boundPlayer: Player? = null

    /**
     * 「上一集 / 下一集」是否可用（Dart 侧推来，见 [bind] 的 [hasPrev]/[hasNext]）。
     *
     * 通知层不可能自己知道：集号与播放列表只在 Dart 侧（`PlaylistContext`）。
     * 这里存的是 **`hasPrev && hasNext`** —— 两头都到位才把收起行换成
     * 「上一集 / 暂停 / 下一集」；单集视频、合集第一条、最后一条一律回退成
     * 既有的 `快退15s / 暂停 / 快进15s`（不放灰着的死按钮，那正是用户本次
     * 投诉的形态）。
     */
    private var episodeNavAvailable = false

    /**
     * 当前绑定的播放器是不是**直播**（`bind` 时由插件层从 [DashExoPlayer.isLive]
     * 传入）：直播不挂快退/快进按钮、会话命令里也摘掉 seek（见 [buildCustomLayout]
     * / [NoSeekPlayer]）。换绑到 VOD 播放器时会随之复位（[release]）。
     */
    private var liveMode = false

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
    // 收起行：上一集 / 播放暂停 / 下一集（v2.30.0-r2）
    // -------------------------------------------------------------------------
    //
    // 机制（反编译 media3-ui 1.5.1 `PlayerNotificationManager` 字节码确认）：
    // - 通知按钮 = `getActions(player)` 返回的 action 名列表 → 逐个查
    //   `playbackActions` / `customActions` 两张表换成 NotificationCompat.Action；
    // - 收起行显示哪 3 个由 `getActionIndicesForCompactView(actions, player)` 决定
    //   （默认实现里固定 [prev-or-rewind][play/pause][next-or-ffwd]，硬上限 3 个）；
    // - 这两个方法都是 `protected` → 可以继承覆写（见 [EpisodeNotificationManager]）；
    // - 自定义 action（本类的 [customActionReceiver]）会被默认 `getActions()`
    //   追加在 stop 之前，点按经广播回到 [PlayerNotificationManager.CustomActionReceiver.onCustomAction]。
    //
    // 为什么不走 `setCustomLayout`：那一条只喂给**会话**（系统媒体卡片 / 车机），
    // 且 media3 1.5.1 不会把它导出到 legacy PlaybackState（`dumpsys media_session`
    // 里 `custom actions=[]` 恒空），通知按钮一个都不会多。

    /** 上下集两个自定义 action 的图标/点按接收器（经 [PlayerNotificationManager.Builder.setCustomActionReceiver] 注册）。 */
    private val customActionReceiver =
        object : PlayerNotificationManager.CustomActionReceiver {
            override fun createCustomActions(
                context: Context,
                instanceId: Int,
            ): Map<String, NotificationCompat.Action> = mapOf(
                kActionPrevEpisode to NotificationCompat.Action(
                    R.drawable.ic_episode_previous,
                    "上一集",
                    episodeBroadcast(context, instanceId, kActionPrevEpisode),
                ),
                kActionNextEpisode to NotificationCompat.Action(
                    R.drawable.ic_episode_next,
                    "下一集",
                    episodeBroadcast(context, instanceId, kActionNextEpisode),
                ),
            )

            /** 本轮通知里「可用的自定义 action」：只有真能切集时才声明（见 [episodeNavAvailable]）。 */
            override fun getCustomActions(player: Player): List<String> =
                if (episodeNavAvailable) {
                    listOf(kActionPrevEpisode, kActionNextEpisode)
                } else {
                    emptyList()
                }

            /**
             * 点按落地：**只回推 Dart**，原生一行播放控制都不做。
             *
             * 切集是「换一个 bvid 重新取流」——播放器会被 dispose、textureId 会变、
             * 17 项状态要复位，全部由播放页的 `playVideo()` 负责（见 Dart 侧
             * `_playNeighbor`）。原生这里碰播放器只会做出「拿单集播放器 seek 到
             * 邻居」这种做不到的事。
             */
            override fun onCustomAction(player: Player, action: String, intent: Intent) {
                val id = boundTextureId ?: return
                when (action) {
                    kActionPrevEpisode -> {
                        Log.i(TAG, "通知「上一集」→ 回推 Dart textureId=$id")
                        onAction(id, "prev", 0L)
                    }

                    kActionNextEpisode -> {
                        Log.i(TAG, "通知「下一集」→ 回推 Dart textureId=$id")
                        onAction(id, "next", 0L)
                    }
                }
            }
        }

    /**
     * 自定义 action 的广播 PendingIntent。
     *
     * 必须与 media3 内建 action 的造法**逐字段一致**（见其私有
     * `createBroadcastIntent`）：Intent action = 自定义 action 名、setPackage(自己)、
     * 带 `INSTANCE_ID` extra、requestCode = instanceId、flag 含
     * `FLAG_IMMUTABLE|FLAG_UPDATE_CURRENT` —— 广播接收器正是凭
     * action 名 + INSTANCE_ID 才能找到本 manager 并把事件交回
     * [customActionReceiver]。
     */
    private fun episodeBroadcast(
        context: Context,
        instanceId: Int,
        action: String,
    ): PendingIntent {
        val intent = Intent(action).setPackage(context.packageName)
        intent.putExtra(kExtraInstanceId, instanceId)
        return PendingIntent.getBroadcast(
            context,
            instanceId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // -------------------------------------------------------------------------
    // 会话自定义命令（快退 15s / 快进 15s / 关闭）
    // -------------------------------------------------------------------------

    /** 三个自定义命令（顺序与 [buildCustomLayout] 一致；直播只暴露最后一个）。 */
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
     *
     * 直播（[liveMode]）只给「关闭」一个：直播不可 seek，挂上快退/快进等于
     * 给锁屏/车机留了拖进度的入口（见 [NoSeekPlayer]）。
     */
    private fun buildCustomLayout(): List<CommandButton> {
        val stop = CommandButton.Builder(CommandButton.ICON_STOP)
            .setSessionCommand(customCommands[2])
            .setDisplayName("关闭")
            .setSlots(CommandButton.SLOT_OVERFLOW)
            .build()
        if (liveMode) return listOf(stop) // 直播：只有「关闭」，没有任何 seek
        return listOf(
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
            stop,
        )
    }

    /**
     * 本次会话对外开放的自定义命令：直播只有「关闭」。
     *
     * 为什么两个入口都要管（[onConnect] 与 [onCustomCommand]）：前者决定
     * legacy 控制器（SystemUI / 蓝牙 / 车机）能**看到**哪些按钮，后者决定
     * 即使有控制器缓存了旧布局、发来命令也**执行不了**。直播缺一不可。
     */
    private fun availableSessionCommands(): List<SessionCommand> =
        if (liveMode) listOf(customCommands[2]) else customCommands

    /** 直播时两个 seek 自定义命令一律拒绝执行（防御）。 */
    private fun isLiveSeekCommand(customAction: String): Boolean =
        liveMode && (customAction == kActionRewind15 || customAction == kActionForward15)

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
     * `onConnect` 里把命令加进该控制器的**可用会话命令**：legacy 控制器
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
                        .addSessionCommands(availableSessionCommands())
                        .build()
                )
                .setCustomLayout(buildCustomLayout())
                .build()

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            val player = boundPlayer ?: return notSupported()
            // 直播：即使有控制器缓存了旧布局把 seek 命令发过来，也一律拒绝
            if (isLiveSeekCommand(customCommand.customAction)) return notSupported()
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
     *
     * [isLive]（v2.27.0+）= 直播：通知上**不挂**快退/快进（通知自带按钮 + 收起态
     * 都不挂），会话只对外暴露「关闭」一条自定义命令，且会话看到的播放器换成
     * [NoSeekPlayer]（把四个 seek 命令也摘掉）。否则锁屏 / 系统媒体卡片仍能拖
     * 进度条 —— 直播地址 58 分钟过期、窗口还会向前滑动，拖动没有任何正确语义。
     *
     * [hasPrev]/[hasNext]（v2.30.0-r2）= 当前视频在播放列表里**是否真的有**上/下
     * 一集（Dart 侧 `_canPlayPrev`/`_canPlayNext` 推来）。两者都为真时才把收起行
     * 换成「上一集 / 暂停 / 下一集」；其余情况（单集视频 / 合集第一条 / 最后一条 /
     * 直播）一律沿用既有的 `快退15s / 暂停 / 快进15s`。
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
        isLive: Boolean = false,
        hasPrev: Boolean = false,
        hasNext: Boolean = false,
    ) {
        // 上下集可用性算在最前面：早返回分支（同一 textureId 只更新文案）也要
        // 拿到它 —— 「换集后通知按钮不跟着变」正是这里最容易漏的一条。
        val hasEpisodeNav = !isLive && hasPrev && hasNext
        if (boundTextureId == id && boundPlayer === player && liveMode == isLive) {
            update(
                title, artist, coverUrl, status, playing, positionMs, durationMs,
                hasEpisodeNav = hasEpisodeNav,
            )
            return
        }
        release()
        // release() 里置过 tearingDown，新绑定必须复位（下次拆解才拦得住事件）
        tearingDown = false
        liveMode = isLive
        episodeNavAvailable = hasEpisodeNav
        this.title = title
        this.artist = artist
        this.status = status
        this.coverUrl = coverUrl
        this.lastPlaying = playing
        this.lastPositionMs = positionMs
        this.lastDurationMs = durationMs
        boundTextureId = id
        boundPlayer = player

        // 会话包住的是「摘掉不可用命令」的包装器（见 [NoPrevNextPlayer] /
        // [NoSeekPlayer]）：单集播放时 media3 仍会声明 COMMAND_SEEK_TO_PREVIOUS
        // 可用，SystemUI 据此把卡片按钮渲染成 `Previous track` 并调
        // seekToPrevious() → 实测**跳回开头**；直播干脆连 seek 一起摘掉。
        // 播放本身与通知仍走真实播放器，只有会话看到的是这个包装器。
        val sessionPlayer =
            if (liveMode) NoSeekPlayer(player) else NoPrevNextPlayer(player)
        val newSession = MediaSession.Builder(context, sessionPlayer)
            // 点通知回到 App（MainActivity 是 singleTop，不新建任务栈）
            .setSessionActivity(contentIntent())
            .setCallback(callback)
            .build()
            .apply {
                // 自定义按钮（快退 15s / 快进 15s / 关闭）：Android 13+ 的系统媒体
                // 卡片只按会话命令渲染，这是它们唯一能被点到的途径
                setCustomLayout(buildCustomLayout())
            }
        // Builder 存成有类型的局部变量再 build()：setter 链返回的是父类 Builder，
        // 链式调用末尾的 build() 静态类型会是 PlayerNotificationManager（拿不到
        // 子类的 hasEpisodeNav）。先链式配好，再在子类类型的变量上调 build()。
        val notifBuilder = EpisodeNotificationManagerBuilder(
            context, kNotificationId, kChannelId,
        )
        notifBuilder
            .setChannelNameResourceId(R.string.playback_notification_channel_name)
            .setChannelDescriptionResourceId(R.string.playback_notification_channel_desc)
            // 低干扰渠道：不出声、不震动、不弹横幅（播放控制不需要打断用户）
            .setChannelImportance(NotificationUtil.IMPORTANCE_LOW)
            .setMediaDescriptionAdapter(adapter)
            .setNotificationListener(notificationListener)
            // 上一集/下一集两个自定义 action（见 [customActionReceiver]）：
            // 必须经 Builder 注册，media3 才会把它们拼进通知并在点按时回调
            .setCustomActionReceiver(customActionReceiver)
        val newManager = notifBuilder.build()
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
                // 直播：通知自带按钮也不给快退/快进（收起态同样不给）——
                // 它们走 player.seekBack()/seekForward()，直播下这两个增量
                // 根本没设（见 [DashExoPlayer.liveMode]），点了只会是空操作。
                setUseRewindAction(!liveMode) // 快退 15 秒（ExoPlayer seekBackIncrementMs）
                setUseFastForwardAction(!liveMode) // 快进 15 秒
                // 收起态（compact）也显示快退/快进，与 B 站一致：`15 ◀ ▶ 15 ▶`
                setUseRewindActionInCompactView(!liveMode)
                setUseFastForwardActionInCompactView(!liveMode)
                setUseStopAction(true) // ✕：停止播放 + 移除通知（media3 内部 player.stop()）
                setPriority(NotificationCompat.PRIORITY_LOW)
                setVisibility(NotificationCompat.VISIBILITY_PUBLIC) // 锁屏可见
            }
        session = newSession
        manager = newManager
        // 上下集可用性要在 setPlayer（起通知）**之前**写进去：createNotification
        // 一进来就调 getActions/getActionIndicesForCompactView，晚一步这一轮
        // 通知就是旧按钮（下一轮才会变）。
        newManager.hasEpisodeNav = hasEpisodeNav
        // setPlayer 会立即起通知（播放器非 IDLE 时），后续由播放器状态变化自动刷新
        newManager.setPlayer(player)
        Log.i(
            TAG,
            "bind textureId=$id title=$title artist=$artist status=$status " +
                "playing=$playing pos=$positionMs duration=$durationMs " +
                "hasEpisodeNav=$hasEpisodeNav",
        )
    }

    /**
     * 只更新文案/封面并刷新通知（换集、播放暂停、听视频开关等状态变化）。
     *
     * [hasEpisodeNav] 一并参与「要不要刷新」的判定：同一播放器（同一 textureId，
     * 即**没换集**但播放列表位置变了——例如切到合集最后一条、或从列表页另一条
     * 重新进入而被复用）时，只更新文案的老写法不会重建通知，收起行会一直停在
     * 上一轮的按钮上。这里显式把可用性写进 manager 并 invalidate：`invalidate()`
     * → `createNotification` 发现 action 列表变了 → 重建通知（收起行三格跟着换）。
     */
    fun update(
        title: String,
        artist: String,
        coverUrl: String,
        status: String,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
        hasEpisodeNav: Boolean? = null,
    ) {
        val changed = title != this.title || artist != this.artist ||
            status != this.status || coverUrl != this.coverUrl
        var navChanged = false
        if (hasEpisodeNav != null && hasEpisodeNav != episodeNavAvailable) {
            episodeNavAvailable = hasEpisodeNav
            manager?.hasEpisodeNav = hasEpisodeNav
            navChanged = true
        }
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
                "playing=$playing pos=$positionMs duration=$durationMs " +
                "hasEpisodeNav=$episodeNavAvailable navChanged=$navChanged",
        )
        if (changed || navChanged) manager?.invalidate()
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
        liveMode = false // 下次 bind 重新判定（可能换成 VOD 播放器）
        episodeNavAvailable = false // 同上：下一次 bind 重新判定
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

/**
 * 直播用的会话包装：在 [NoPrevNextPlayer] 的基础上**再摘掉所有 seek 命令**
 * （v2.27.0+）。
 *
 * 为什么还要单独摘一遍（[DashExoPlayer.liveMode] 已经在构建期不设
 * seekBack/ForwardIncrementMs）：那一手管的是「ExoPlayer 自己声明哪些命令
 * 可用」，但 `COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM` / `COMMAND_SEEK_TO_DEFAULT_POSITION`
 * 与增量无关，单集播放/直播时本来就是可用的 —— 只要它们在，
 * 锁屏与系统媒体卡片的进度条就是可拖的（拖了会真的跳位置，而直播跳位置
 * 没有任何正确语义：窗口在往前滑、地址 58 分钟过期）。
 */
private class NoSeekPlayer(player: Player) : ForwardingPlayer(player) {
    override fun getAvailableCommands(): Player.Commands =
        super.getAvailableCommands().buildUpon()
            .removeAll(
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_IN_CURRENT_WINDOW,
                Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
                Player.COMMAND_SEEK_BACK,
                Player.COMMAND_SEEK_FORWARD,
            )
            .build()

    override fun isCommandAvailable(command: Int): Boolean =
        getAvailableCommands().contains(command)
}

// -----------------------------------------------------------------------------
// 收起行「上一集 / 播放暂停 / 下一集」（v2.30.0-r2）
// -----------------------------------------------------------------------------

/**
 * 通知管理器子类：只为了覆写两个 **`protected`** 方法，把自有 action 排进
 * 收起行的三个槽位。
 *
 * 为什么必须继承（而不是像 v2.25.0 那样只调 setter）：
 * - `getActions(player)` 决定通知上有哪些按钮，且对每个**内建** action 都做
 *   `isCommandAvailable` 门禁 —— 内建 Next 需要 `COMMAND_SEEK_TO_NEXT`，
 *   而单 MediaItem 的 ExoPlayer 没有这个命令 → 内建 ⏭ **永远生成不出来**
 *   （`dumpsys media_session` 里 `actions` 只比默认多出 `SKIP_TO_PREVIOUS`，
 *   而那个键点了是 `seekToPrevious()` = 回本条开头，不是上一集）；
 * - `getActionIndicesForCompactView(actions, player)` 决定**收起行**显示哪 3 个
 *   （默认实现硬编码 [上一/快退][播放暂停][下一/快进] 三个槽位）。
 *   两者都是 protected，继承覆写是唯一不改 media3 源码的钩子。
 *
 * 两个方法的返回值都必须与 [DashMediaNotification] 的 action 名常量对得上；
 * 未启用上下集（[hasEpisodeNav] = false：单集 / 合集头尾 / 直播）时**原样返回
 * super**，通知与 v2.30.0 之前逐像素一致。
 */
private class EpisodeNotificationManager(
    context: Context,
    channelId: String,
    notificationId: Int,
    mediaDescriptionAdapter: PlayerNotificationManager.MediaDescriptionAdapter,
    notificationListener: PlayerNotificationManager.NotificationListener,
    customActionReceiver: PlayerNotificationManager.CustomActionReceiver,
    smallIconResourceId: Int,
    playActionIconResourceId: Int,
    pauseActionIconResourceId: Int,
    stopActionIconResourceId: Int,
    rewindActionIconResourceId: Int,
    fastForwardActionIconResourceId: Int,
    previousActionIconResourceId: Int,
    nextActionIconResourceId: Int,
    groupKey: String?,
) : PlayerNotificationManager(
    context,
    channelId,
    notificationId,
    mediaDescriptionAdapter,
    notificationListener,
    customActionReceiver,
    smallIconResourceId,
    playActionIconResourceId,
    pauseActionIconResourceId,
    stopActionIconResourceId,
    rewindActionIconResourceId,
    fastForwardActionIconResourceId,
    previousActionIconResourceId,
    nextActionIconResourceId,
    groupKey,
) {
    /**
     * 上下集是否都可用（Dart 侧推来，见 `DashMediaNotification.bind`）。
     * 变化后要 [invalidate] 才会重建通知。
     */
    var hasEpisodeNav: Boolean = false

    /**
     * 展开态按钮顺序：`[上一集][快退15s][播放暂停][快进15s][下一集][✕关闭]`。
     *
     * 为什么要重排（默认实现已把自定义 action 追加在 stop 之前，即
     * `[快退][暂停][快进][上一集][下一集][✕]`）：
     * Android 的**媒体大布局只有 5 个按钮位**（framework-res 的
     * `notification_template_material_big_media.xml` 里只有 action0..action4
     * 五个 include，实测展开态最多 5 个），第 6 个不会渲染 —— 平台硬上限，
     * 排不出第 6 个可见按钮。
     *
     * 5 个槽位怎么分配是取舍，本顺序的取舍理由：
     * 1. **对称性优先**：上一集 / 下一集是一对，用户看到「有上一集却没有下一集」
     *    会直接当成 bug（上一轮 `[上一集, 快退, 暂停, 快进, ✕, 下一集]` 就是这样：
     *    展开态有 ⏮ 没 ⏭）。所以第 5 个槽给**下一集**；
     * 2. **让出槽位的只能是 `✕关闭`**：它在通知之外有替代路径 —— 回 App 内暂停 /
     *    停止 / 退出播放页（实测退出播放页即停播并撤下通知），通知自身在**暂停态**
     *    也不带 `ONGOING_EVENT`（可划掉，见 [notificationListener] 的
     *    `dismissedByUser` 分支）；而上一集/下一集没有别的入口，少一个就是功能缺失。
     *    ⚠️ `✕` 仍在本列表的第 6 位（`ACTION_STOP` 照常注册、
     *    `setUseStopAction(true)` 照常生效），只是展开态渲染不出来。
     *    **没有播放列表时**（单集 / 合集头尾 / 直播，[hasEpisodeNav] = false）
     *    本方法原样返回 super，`✕` 依旧占展开态最后一个槽位照常渲染，
     *    与改动前完全一致 —— 别为了「保住 ✕」把下一集挪回第 6 位；
     * 3. **收起行不受影响**：收起行的 3 个按钮由 [getActionIndicesForCompactView]
     *    按 action 名查下标决定，与「展开态取前 5 个」的规则无关，这里只是换了两
     *    个 action 的相对位置，收起行仍是 `上一集 / 播放暂停 / 下一集`。
     */
    override fun getActions(player: Player): List<String> {
        val actions = ArrayList(super.getActions(player))
        if (!hasEpisodeNav) return actions
        // 上一集提到最前（b 站通知的语序：更靠左 = 更靠前）
        if (actions.remove(EPISODE_PREV)) actions.add(0, EPISODE_PREV)
        // 下一集插到「关闭」**之前**（即展开态第 5 个槽；关闭被挤到第 6 位）。
        // super 一定会带上 ACTION_STOP（bind 里 setUseStopAction(true)），
        // 万一没有（防御）就直接追加，至少不让「下一集」凭空消失。
        if (actions.remove(EPISODE_NEXT)) {
            val stopIndex = actions.indexOf(ACTION_STOP)
            if (stopIndex >= 0) actions.add(stopIndex, EPISODE_NEXT) else actions.add(EPISODE_NEXT)
        }
        return actions
    }

    /**
     * 收起行槽位：`[上一集][播放暂停][下一集]`（按数组顺序即左中右）。
     *
     * 索引是**按 action 名现查**的（不是写死的 0/2/5），所以 [getActions] 里
     * 「下一集 ↔ ✕关闭」换了位置后，这里自动指向新下标，无需跟着改。
     *
     * 未启用上下集 → 原样交给 super（`[快退15s][暂停][快进15s]`，与改动前一致）；
     * 启用了但某个 action 没在列表里（理论不可达）→ 同样退回 super，宁可少两个
     * 按钮也不要空槽位或崩溃。
     */
    override fun getActionIndicesForCompactView(
        actions: List<String>,
        player: Player,
    ): IntArray {
        if (!hasEpisodeNav) return super.getActionIndicesForCompactView(actions, player)
        val prev = actions.indexOf(EPISODE_PREV)
        val next = actions.indexOf(EPISODE_NEXT)
        val playPause = actions.indexOf(ACTION_PLAY).takeIf { it >= 0 }
            ?: actions.indexOf(ACTION_PAUSE)
        if (prev < 0 || next < 0 || playPause < 0) {
            return super.getActionIndicesForCompactView(actions, player)
        }
        return intArrayOf(prev, playPause, next)
    }

    private companion object {
        /** 与 [DashMediaNotification] 里的常量同值（文件内私有，见其定义）。 */
        const val EPISODE_PREV = kActionPrevEpisode
        const val EPISODE_NEXT = kActionNextEpisode
    }
}

/**
 * [PlayerNotificationManager.Builder] 子类：`build()` 是唯一能换成
 * [EpisodeNotificationManager] 的入口（通知管理器由 Builder 直接 new，没有
 * 注入点）。
 *
 * 这里逐字复刻父类 `build()` 的两件事（反编译 1.5.1 确认它只做这两件）：
 * 建通知渠道 + 用同一批字段 new 出管理器 —— 其余 setter 与默认值全部沿用父类的
 * protected 字段，所以「渠道名/图标/监听器」等行为与直接用它构建完全一致。
 */
private class EpisodeNotificationManagerBuilder(
    ctx: Context,
    notificationId: Int,
    channelId: String,
) : PlayerNotificationManager.Builder(ctx, notificationId, channelId) {

    override fun build(): EpisodeNotificationManager {
        if (channelNameResourceId != 0) {
            NotificationUtil.createNotificationChannel(
                context,
                channelId,
                channelNameResourceId,
                channelDescriptionResourceId,
                channelImportance,
            )
        }
        return EpisodeNotificationManager(
            context,
            channelId,
            notificationId,
            mediaDescriptionAdapter,
            // 这两个字段在 Builder 里可空（允许不设），构造函数要非空：
            // 没设时给个空实现（等价于 media3 自己的「不回调」语义）。
            // 本 App 的 bind() 每次都会设（通知/会话都要靠它），这里只是兜底。
            notificationListener
                ?: object : PlayerNotificationManager.NotificationListener {},
            customActionReceiver
                ?: object : PlayerNotificationManager.CustomActionReceiver {
                    override fun createCustomActions(
                        context: Context,
                        instanceId: Int,
                    ): Map<String, NotificationCompat.Action> = emptyMap()

                    override fun getCustomActions(player: Player): List<String> =
                        emptyList()

                    override fun onCustomAction(
                        player: Player,
                        action: String,
                        intent: Intent,
                    ) = Unit
                },
            smallIconResourceId,
            playActionIconResourceId,
            pauseActionIconResourceId,
            stopActionIconResourceId,
            rewindActionIconResourceId,
            fastForwardActionIconResourceId,
            previousActionIconResourceId,
            nextActionIconResourceId,
            groupKey,
        )
    }
}
