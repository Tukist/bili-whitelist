package com.biliwhitelist.bili_whitelist_app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.NotificationUtil
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
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
 * 通知卡片上六个按钮的广播 action（v2.32.0）。
 *
 * 为什么不再是 media3 的 `ACTION_PLAY` 那一套：v2.32.0 起整张卡片是 App 自己
 * 手画的 RemoteViews（见文件头），按钮点击不再由 media3 的
 * `PlayerNotificationManager` 私有广播接收器处理，改由本类的 [cardReceiver]
 * 处理 —— 只用本 App 自己的 action 名，避免与 media3 的内部约定
 * （`INSTANCE_ID` extra 等）纠缠。
 */
private const val kNotifPlayPause = "com.biliwhitelist.amotv.notif.PLAY_PAUSE"
private const val kNotifRewind = "com.biliwhitelist.amotv.notif.REWIND_15"
private const val kNotifForward = "com.biliwhitelist.amotv.notif.FORWARD_15"
private const val kNotifPrevEpisode = "com.biliwhitelist.amotv.notif.PREV_EPISODE"
private const val kNotifNextEpisode = "com.biliwhitelist.amotv.notif.NEXT_EPISODE"
private const val kNotifClose = "com.biliwhitelist.amotv.notif.CLOSE"
private const val kNotifDismiss = "com.biliwhitelist.amotv.notif.DISMISSED"

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
 * B 站式**媒体通知 + 媒体会话**（v2.25.x 起，v2.32.0 换成自绘卡片）。
 *
 * 组成（全部用项目已有的 media3 体系，没有新增任何依赖）：
 * - [MediaSession]（media3-session）：包住 [DashExoPlayer.mediaPlayer]。它内部建了
 *   一个系统 `android.media.session.MediaSession`，**耳机 / 蓝牙的媒体键**
 *   （KEYCODE_MEDIA_PLAY_PAUSE 等）由系统派发到当前活跃会话 → media3 直接驱动
 *   [`Player.play()`]/[`Player.pause()`]，无需我们写 BroadcastReceiver。
 * - 会话**自定义命令**（v2.25.0-r2）：`快退 15 秒 / 快进 15 秒 / 关闭` 三个动作由
 *   [callback] 的 `onCustomCommand` 实现、经 [buildCustomLayout] 暴露给 MediaController
 *   类控制器（Android Auto / Wear / 车机的媒体浏览器、以及 `cmd media_session`
 *   这类可发送自定义命令的客户端）。见 [callback] 注释。
 * - **通知卡片**（v2.32.0）：[NotificationCompat.Builder] + `setCustomContentView` +
 *   `res/layout/notification_playback_card.xml`，**整张卡片自己画**：上行标题
 *   （`标题 · UP 名 · 状态`）、下行六个按钮（上一集 / 快退15s / 播放暂停 /
 *   快进15s / 下一集 / 关闭）。**收起态就全部可见可点，不需要点箭头展开**。
 *
 * ⚠️ 这条通知**不绑会话 token**（详见 [bind] 里的说明）：绑了就会被 Android 13+
 * 收进系统媒体卡片，而那张卡片只渲染系统自己的固定槽位（实测 Android 15 上
 * 只有一个大号播放/暂停 + 一个可拖进度条），快退/快进/上下集/关闭在它上面
 * 一个都点不到。
 *
 * 只服务**一个**播放器（[bind] 时记录 textureId）：播放页可能同时存在两个播放器
 * （评论区点链接 push 新播放页，旧页暂停让位），通知始终跟随 Dart 侧最后同步的那个。
 *
 * 状态同步方向（两个方向都要，否则会出现「通知暂停了但界面还在播」）：
 * - Dart → 原生：标题 / UP 名 / 封面 / 状态文案（[update]）；
 * - 原生 → Dart：播放暂停、seek、关闭（✕）→ 经 [onAction] 回推，见插件层事件
 *   `onMediaAction`。播放暂停**不需要**本类回推：按钮直接调 `player.play()/pause()`，
 *   [DashExoPlayer] 的 `onPlayWhenReadyChanged` 已经会把它转成 `onMediaAction`
 *   （play/pause）推给 Dart。
 *
 * ⚠️ 封面图必须带防盗链头（Referer + 浏览器 UA）：B 站图床对无 Referer/UA 的
 * 请求可能 403（与 [DashExoPlayer] 流请求同源问题），所以这里自己下载，
 * 下载完用 `RemoteViews.setImageViewBitmap` 画进卡片。
 *
 * ## 为什么放弃 MediaStyle（v2.32.0 的实测结论，反编译 media3-ui 1.5.1 交叉确认）
 *
 * 用户诉求：「通知中心现在需要点箭头展开才能看到暂停/下一集等按钮，正常状态
 * 就不要折叠」「b 站都可以」。上一轮试过「不绑 token + MediaStyle」，折叠箭头
 * 无论如何消不掉 —— 但**根因并不是 MediaStyle**，本轮探针把事实钉死了：
 *
 * 1. 收起态给自定义布局的盒子只有 **~271dp 宽 × ~48~54dp 高**
 *    （`uiautomator dump` 实测：左边 36dp 是系统的小图标徽标、右边 56dp 是展开
 *    箭头那一条，纵向按 8dp 网格量到第 6 格就没了）。所以「封面 + 标题 +
 *    六个按钮」一行放不下，必须两行；
 * 2. **展开箭头是 Android 15 通知行的固有 UI**：用 `adb shell cmd notification post`
 *    发一条最普通的通知（无自定义布局、无 style、无 bigContentView、标题 + 一行
 *    文字）实测**同样带箭头**。唯一没有箭头的是系统「媒体卡片」，而它只给一个
 *    大号播放/暂停 + 进度条，App 自己的按钮一个都不渲染。也就是说：**任何普通
 *    通知都消不掉这个箭头**，能做的是让用户在收起态就用上全部按钮、根本不需要
 *    去点它；
 * 3. 自定义布局**不设** bigContentView 时箭头照样在（探针 #1/#2/#4/#6 一致），
 *    设了也一样（探针 #5）；[NotificationCompat.DecoratedCustomViewStyle] 在
 *    收起态与不设它逐像素相同（探针 #2 vs #1），故正式实现**不用**任何 style。
 *
 * ## 自绘卡片的取舍（都记在这，改的时候别把它当 bug 修）
 *
 * - **不再有 MediaStyle 的展开大图**：卡片就 48dp，两行；点系统箭头展开后
 *   看到的还是同一张卡片（系统会把同一份 RemoteViews 拉高，多出来的地方是空的）；
 * - **标题行左右分栏**：左边标题（可伸缩、超长末尾省略）、右边 `UP 名 · 状态`
 *   （定宽上限 88dp）。48dp 里放不下「标题 + 副标题」两行文字外加一行按钮，
 *   只能把副标题挤到标题行右侧；好处是长标题下 UP 名与状态也不会整块消失
 *   （旧通知的收起行同样会截断副标题，见 v2.30.0 截图里的 `Nobody_AVIS · 正…`）；
 * - **封面缩略图 34dp**：宽 271dp 的盒子里，六个按钮要占掉大部分宽度
 *   （实测不带封面时每个按钮 ~45dp、带封面 ~36dp）。36dp 的触控宽度偏小但可用：
 *   图标 24dp + 4dp 内边距，实测六个按钮都在可视区、都能点（见交付说明的
 *   真机取证）；**不放弃封面**是因为它是用户明确列出的要保持的东西；
 * - **播放/暂停图标跟着播放器状态走**（`player.isPlaying`），不是跟着 Dart 上报
 *   的 `playing` 走：Dart 的每次 `update` 都要跨线程/跨引擎，原生自己读播放器
 *   状态永远不脏，这也是旧实现（media3 从播放器取状态）的语义；
 * - **通知的常驻（ongoing）规则照抄 media3**：反编译确认它只在
 *   `playbackState ∈ {BUFFERING, READY} && playWhenReady` 时 `setOngoing(true)`
 *   —— 播放中划不掉、暂停态可划掉；撤下通知的条件同样照抄：**IDLE 且时间线为空**
 *   （`createNotification` 返回 null 的那条分支），而不是「任何 IDLE 都撤」。
 */
class DashMediaNotification(
    private val context: Context,
    private val userAgent: String,
    private val onAction: (textureId: Long, action: String, positionMs: Long) -> Unit,
) {
    /** 通知上展示的文案（Dart 侧 [update] 写入，主线程读）。 */
    private var title = ""
    private var artist = ""
    private var status = ""
    private var coverUrl = ""

    /** 最近一次 Dart 上报的状态：仅记录，通知渲染一律以播放器自身状态为准。 */
    private var lastPlaying = false
    private var lastPositionMs = 0L
    private var lastDurationMs = 0L

    private var session: MediaSession? = null
    private var boundPlayer: Player? = null

    /** 挂在**真实播放器**上的监听器（通知的图标/常驻态靠它刷新）。 */
    private var playerListener: Player.Listener? = null

    /** 通知是否已投递（决定撤销时要不要回推 Dart「stop」）。 */
    private var posted = false

    /** action 广播接收器是否已注册（懒注册一次，与 media3 同款做法）。 */
    private var receiverRegistered = false

    /**
     * 「上一集 / 下一集」是否可用（Dart 侧推来，见 [bind] 的 [hasPrev]/[hasNext]）。
     *
     * 通知层不可能自己知道：集号与播放列表只在 Dart 侧（`PlaylistContext`）。
     * 这里存的是 **`hasPrev && hasNext`** —— 两头都到位才显示上下集按钮；
     * 单集视频、合集第一条、最后一条一律回退成既有的
     * `快退15s / 播放暂停 / 快进15s`（不放灰着的死按钮，那正是用户投诉的形态）。
     */
    private var episodeNavAvailable = false

    /**
     * 当前绑定的播放器是不是**直播**（`bind` 时由插件层从 [DashExoPlayer.isLive]
     * 传入）：直播不显示快退/快进按钮、会话命令里也摘掉 seek（见 [buildCustomLayout]
     * / [NoSeekPlayer]）。换绑到 VOD 播放器时会随之复位（[release]）。
     */
    private var liveMode = false

    /** 当前绑定的播放器 textureId（null = 没有绑定）。 */
    var boundTextureId: Long? = null
        private set

    /**
     * 拆解中标志：拆会话 / 换播放器时会撤销通知，那不是用户按了「关闭（✕）」，
     * 不能回推 Dart（否则界面会被误收成「已停止」）。
     */
    private var tearingDown = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 封面图缓存：同一 URL 只下载一次，换视频时自动失效。 */
    private var coverBitmap: Bitmap? = null
    private var coverBitmapUrl: String? = null

    /** 正在下载中的封面 URL（防止每次重画卡片都重复发起下载）。 */
    private var coverLoadingUrl: String? = null

    // -------------------------------------------------------------------------
    // 通知卡片（v2.32.0：自绘 RemoteViews）
    // -------------------------------------------------------------------------

    /**
     * 卡片按钮的点击广播接收器（懒注册，进程活着就一直有效）。
     *
     * 用**动态注册**而不是 AndroidManifest 里的静态 `<receiver>`：与 media3 的
     * `NotificationBroadcastReceiver` 同款做法，不用改清单、也不用担心
     * exported 属性；PendingIntent 里显式 `setPackage(自己)`，
     * API 33+ 注册时声明 `RECEIVER_NOT_EXPORTED`（外部应用发不进来）。
     */
    private val cardReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context, intent: Intent) {
            val player = boundPlayer
            Log.i(TAG, "通知按钮 action=${intent.action} player=${player != null}")
            if (player == null) return
            when (intent.action) {
                // 播放/暂停：直接驱动播放器，Dart 侧由 DashExoPlayer 的
                // onPlayWhenReadyChanged → onMediaAction(play/pause) 对齐界面
                kNotifPlayPause -> if (player.isPlaying) player.pause() else player.play()

                kNotifRewind -> seekBy(player, -kSeekStepMs)
                kNotifForward -> seekBy(player, kSeekStepMs)

                // 上下集：原生什么都不做，只回推 Dart（切集要换 bvid 重新取流，
                // 只有播放页做得到，见 Dart 侧 playNeighbor）
                kNotifPrevEpisode -> boundTextureId?.let { onAction(it, "prev", 0L) }
                kNotifNextEpisode -> boundTextureId?.let { onAction(it, "next", 0L) }

                kNotifClose -> closeByCard(player)

                // 用户划掉通知（仅暂停态可划）：不动播放，下次状态变化时通知会
                // 被重新投递（与 media3 的 dismissedByUser 分支一致）
                kNotifDismiss -> Log.i(TAG, "通知被用户划掉：播放不中断")
            }
        }
    }

    private fun ensureReceiverRegistered() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(kNotifPlayPause)
            addAction(kNotifRewind)
            addAction(kNotifForward)
            addAction(kNotifPrevEpisode)
            addAction(kNotifNextEpisode)
            addAction(kNotifClose)
            addAction(kNotifDismiss)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(cardReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(cardReceiver, filter)
        }
        receiverRegistered = true
    }

    /** 播放器状态监听：只负责在状态变化时重画卡片（图标 / 常驻态 / 撤销）。 */
    private fun playerEvents(): Player.Listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) = refresh()

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = refresh()

        override fun onPlaybackStateChanged(playbackState: Int) = refresh()
    }

    /**
     * 重画并投递通知（或按 media3 的规则撤下它）。
     *
     * 撤销条件 = `IDLE && 时间线为空`（反编译 media3-ui 1.5.1
     * `createNotification` 返回 null 的那条分支）：用户按 ✕ / 会话「关闭」都会
     * `stop() + clearMediaItems()`，正好落进这条；单纯 `stop()`（Dart 侧停播但
     * 媒体项还在）不撤通知，与改动前一致。
     */
    private fun refresh() {
        val player = boundPlayer ?: return
        if (player.playbackState == Player.STATE_IDLE && player.currentTimeline.isEmpty) {
            cancelNotification(pushStop = true)
            return
        }
        val notification = NotificationCompat.Builder(context, kChannelId)
            .setSmallIcon(R.drawable.ic_notif_small)
            // 标题/正文仍要设：无障碍服务、耳机/车机的朗读、以及部分第三方
            // 通知管理应用读的是这两个字段，不设它们会读到空
            .setContentTitle(title)
            .setContentText(subtitle())
            .setContentIntent(contentIntent())
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC) // 锁屏可见
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true) // 状态变化重投时不响不弹
            .setShowWhen(false)
            .setOngoing(getOngoing(player)) // 播放中划不掉（见 getOngoing 注释）
            .setDeleteIntent(broadcast(kNotifDismiss, 900))
            .setCustomContentView(buildCard(player))
            .build()
        NotificationManagerCompat.from(context).notify(kNotificationId, notification)
        posted = true
    }
    /** 撤下通知；[pushStop] = 是否按「用户按了关闭」回推 Dart（我们主动拆解时不回推）。 */
    private fun cancelNotification(pushStop: Boolean) {
        if (!posted) return
        NotificationManagerCompat.from(context).cancel(kNotificationId)
        posted = false
        if (pushStop && !tearingDown) {
            Log.i(TAG, "通知撤销 → 回推 Dart 收尾 textureId=$boundTextureId")
            boundTextureId?.let { onAction(it, "stop", 0L) }
        }
    }

    /**
     * 常驻态规则：**照抄 media3**（反编译 `getOngoing` 确认）——
     * 只有 `BUFFERING`/`READY` 且 `playWhenReady` 才常驻。
     *
     * 语义：播放中划不掉（防止误划导致「有声音没通知」）；暂停态可划掉，
     * 划掉后播放不中断、下次播放状态变化时通知会被重新投递。
     */
    private fun getOngoing(player: Player): Boolean {
        val state = player.playbackState
        return (state == Player.STATE_BUFFERING || state == Player.STATE_READY) &&
            player.playWhenReady
    }

    /** 副标题（`UP 名 · 状态`）：卡片上放在标题行右侧，这里也供 setContentText 用。 */
    private fun subtitle(): CharSequence =
        if (artist.isEmpty()) status else "$artist · $status"

    /**
     * 按需发起封面下载（同一 URL 只下一次）。
     *
     * 之所以放在 [buildCard] 里现查：换集/换视频时 [coverUrl] 立刻变，卡片重画
     * 时自然会发现「缓存里那张不是这个 URL 的」→ 重新下载，不需要额外的失效逻辑。
     */
    private fun ensureCoverLoaded() {
        val url = coverUrl
        if (url.isEmpty()) return
        if (url == coverBitmapUrl || url == coverLoadingUrl) return
        coverLoadingUrl = url
        loadCover(url)
    }

    /**
     * 画整张卡片。
     *
     * 六个按钮的**可用性**在这里决定（不用的按钮 `GONE`，不留灰按钮）：
     * - `上一集 / 下一集`：仅当 Dart 侧报的 hasPrev && hasNext（[episodeNavAvailable]）；
     * - `快退15s / 快进15s`：直播不给（[liveMode]，直播没有进度可跳）；
     * - `播放暂停`：图标按 `player.isPlaying` 取播放/暂停两张图之一；
     * - `关闭`：永远在（它是唯一能停播并撤下通知的入口）。
     */
    private fun buildCard(player: Player): RemoteViews {
        val rv = RemoteViews(context.packageName, R.layout.notification_playback_card)
        rv.setTextViewText(R.id.notif_title, title)

        // 右侧「UP 名 · 状态」：没有就不占位（把宽度还给标题 —— 单集视频的
        // «标题» 往往较长，这里空着比挤着好看）
        val meta = subtitle()
        if (meta.isEmpty()) {
            rv.setViewVisibility(R.id.notif_meta, View.GONE)
        } else {
            rv.setViewVisibility(R.id.notif_meta, View.VISIBLE)
            rv.setTextViewText(R.id.notif_meta, meta)
        }

        // 封面：下载好就用真封面，没下好留着布局里的启动图标占位
        coverBitmap?.let { rv.setImageViewBitmap(R.id.notif_cover, it) }
        ensureCoverLoaded()

        // 播放中显示「暂停」键，暂停中显示「播放」键（与 B 站一致）
        val playing = player.isPlaying
        rv.setImageViewResource(
            R.id.notif_btn_play,
            if (playing) R.drawable.ic_notif_pause else R.drawable.ic_notif_play,
        )
        rv.setContentDescription(R.id.notif_btn_play, if (playing) "暂停" else "播放")

        val seekable = !liveMode
        rv.setViewVisibility(R.id.notif_btn_rewind, if (seekable) View.VISIBLE else View.GONE)
        rv.setViewVisibility(R.id.notif_btn_forward, if (seekable) View.VISIBLE else View.GONE)
        val episodeNav = episodeNavAvailable
        rv.setViewVisibility(R.id.notif_btn_prev, if (episodeNav) View.VISIBLE else View.GONE)
        rv.setViewVisibility(R.id.notif_btn_next, if (episodeNav) View.VISIBLE else View.GONE)

        rv.setOnClickPendingIntent(R.id.notif_btn_prev, broadcast(kNotifPrevEpisode, 901))
        rv.setOnClickPendingIntent(R.id.notif_btn_rewind, broadcast(kNotifRewind, 902))
        rv.setOnClickPendingIntent(R.id.notif_btn_play, broadcast(kNotifPlayPause, 903))
        rv.setOnClickPendingIntent(R.id.notif_btn_forward, broadcast(kNotifForward, 904))
        rv.setOnClickPendingIntent(R.id.notif_btn_next, broadcast(kNotifNextEpisode, 905))
        rv.setOnClickPendingIntent(R.id.notif_btn_close, broadcast(kNotifClose, 906))
        return rv
    }

    /**
     * 按钮点击的广播 PendingIntent。
     *
     * `setPackage(自己)` + 固定 requestCode + `FLAG_IMMUTABLE`：同一 action 的
     * PendingIntent 只有一个实例（`FLAG_UPDATE_CURRENT` 保证 extra 最新），
     * 七个 action 名互不相同，不会互相覆盖。
     */
    private fun broadcast(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(action).setPackage(context.packageName)
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** 卡片「关闭」：停播 + 清媒体项（触发 [refresh] 走撤销分支并回推 Dart）。 */
    private fun closeByCard(player: Player) {
        Log.i(TAG, "通知「关闭」→ 停止播放并撤下通知 textureId=$boundTextureId")
        player.stop()
        player.clearMediaItems()
        refresh()
    }

    // -------------------------------------------------------------------------
    // 「上一集 / 下一集」
    // -------------------------------------------------------------------------
    //
    // 机制（v2.32.0 起）：卡片上的两个自定义按钮 → [cardReceiver] → 回推 Dart。
    //
    // 为什么不用会话的 `ACTION_SKIP_TO_NEXT` / `seekToNext()`（v2.30.0-r2 实测 +
    // 反编译 media3-ui 1.5.1 确认）：
    // 1. 单 MediaItem 的 ExoPlayer **没有** `COMMAND_SEEK_TO_NEXT`，任何依赖它的
    //    按钮都生成不出来；会话里也确实只多出 `ACTION_SKIP_TO_PREVIOUS`
    //    （actions=7339999，只多 16）；
    // 2. 那个 ⏮ 点下去走 `seekToPrevious()` = **回到本条开头**（实测 1396349 → 0），
    //    不是上一集。集号只存在于 Dart 侧（`_playlistIndex`）。
    //
    // 所以「上一集 / 下一集」必须由本 App 自己实现：动作定义在这里，点按回推
    // Dart（`onAction(id, "prev"/"next", 0L)` → `BiliDashPlayerPlugin` 的 eventSink
    // → 播放页 `_onMediaAction` → `playNeighbor(±1)`）。

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
     * 会话回调：把自定义命令**真正执行掉**（媒体卡片/车机只是入口，动作在这里落地）。
     *
     * - `快退 15 秒` / `快进 15 秒`：显式 `seekTo(currentPosition ∓ 15000)` 并夹到
     *   `[0, duration]`。⚠️ **不能**用 media3 的 `seekToPrevious()` —— 单集播放时
     *   它等价于「回到本条开头」（实测点卡片 ⏮ 位置直接归 0），语义不是快退 15 秒。
     *   seek 引发的 `onPositionDiscontinuity(SEEK)` 由 [DashExoPlayer] 上报 Dart，
     *   界面位置随之对齐，这里不重复回推。
     * - `关闭`：等同卡片上的 ✕（停播 + 清媒体项 + 撤下通知 + 回推 Dart）。
     *
     * `onConnect` 里把命令加进该控制器的**可用会话命令**：legacy 控制器
     * （SystemUI / 蓝牙 / 车机走的都是 legacy 通道）只有声明过才拿得到这些
     * 自定义 action，否则 `dumpsys media_session` 里 `custom actions=[]`。
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
                kActionClose -> {
                    player.stop()
                    player.clearMediaItems()
                    refresh() // → 撤销通知并回推 Dart（等同卡片 ✕）
                }

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

    /**
     * 绑定/更新通知（Dart 侧 `updateNowPlaying` 调用，主线程）。
     *
     * - [id]/[player] 与当前绑定不同 → 先释放旧的（会话 + 通知），再为新的建一套
     *   （播放页切换/换源会走到这条路径）；
     * - 同一播放器 → 只更新文案并重画卡片。
     *
     * [isLive]（v2.27.0+）= 直播：卡片上**不显示**快退/快进，会话只对外暴露
     * 「关闭」一条自定义命令，且会话看到的播放器换成 [NoSeekPlayer]（把四个 seek
     * 命令也摘掉）。否则锁屏 / 系统媒体卡片仍能拖进度条 —— 直播地址 58 分钟过期、
     * 窗口还会向前滑动，拖动没有任何正确语义。
     *
     * [hasPrev]/[hasNext]（v2.30.0-r2）= 当前视频在播放列表里**是否真的有**上/下
     * 一集（Dart 侧 `_canPlayPrev`/`_canPlayNext` 推来）。两者都为真时才显示
     * 上下集按钮；其余情况（单集视频 / 合集第一条 / 最后一条 / 直播）只显示
     * `快退15s / 播放暂停 / 快进15s`（不放灰着的死按钮）。
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
            episodeNavAvailable = hasEpisodeNav
            update(
                title, artist, coverUrl, status, playing, positionMs, durationMs,
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

        // 渠道由我们自己在投递前建（原来由 PlayerNotificationManager.Builder
        // 顺手建；API 26+ 往不存在的渠道投通知是静默丢弃，必须自己保证）
        NotificationUtil.createNotificationChannel(
            context,
            kChannelId,
            R.string.playback_notification_channel_name,
            R.string.playback_notification_channel_desc,
            NotificationUtil.IMPORTANCE_LOW,
        )
        ensureReceiverRegistered()

        // 会话包住的是「摘掉不可用命令」的包装器（见 [NoPrevNextPlayer] /
        // [NoSeekPlayer]）：单集播放时 media3 仍会声明 COMMAND_SEEK_TO_PREVIOUS
        // 可用，SystemUI 据此把卡片按钮渲染成 `Previous track` 并调
        // seekToPrevious() → 实测**跳回开头**；直播干脆连 seek 一起摘掉。
        // 播放本身与通知仍走真实播放器，只有会话看到的是这个包装器。
        val sessionPlayer =
            if (liveMode) NoSeekPlayer(player) else NoPrevNextPlayer(player)
        session = MediaSession.Builder(context, sessionPlayer)
            // 点通知回到 App（MainActivity 是 singleTop，不新建任务栈）
            .setSessionActivity(contentIntent())
            .setCallback(callback)
            .build()
            .apply {
                // 自定义按钮（快退 15s / 快进 15s / 关闭）：Android 13+ 的系统媒体
                // 卡片只按会话命令渲染，这是它们唯一能被点到的途径
                setCustomLayout(buildCustomLayout())
            }

        // 卡片刷新走**真实播放器**的事件（不是会话包装器）：包装器摘了命令但
        // 事件照样转发，这里只需要状态变化，用真实播放器最直接
        val listener = playerEvents()
        playerListener = listener
        player.addListener(listener)

        // ⚠️ v2.25.0-r2：**故意不**调 setMediaSessionToken()（v2.32.0 改成自绘卡片后
        // 这条决策不变，只是原因更清楚了）。
        //
        // 绑了会话 token 的通知会被 Android 13+ 的 SystemUI 收进「媒体卡片」
        // （MediaCarousel），按**会话的标准命令**重绘按钮 —— 实测（Android 15）
        // 卡片上只剩一个大号播放/暂停和一条可拖的进度条：App 自己配的
        // `快退15s / 播放暂停 / 快进15s / 关闭` 一个都不渲染，上下集也没有；
        // media3 1.5.1 也**不会**把 setCustomLayout 的按钮导出到 PlaybackState
        // （MediaSessionLegacyStub 里没有 addCustomAction，实测 `dumpsys
        // media_session` 恒为 `custom actions=[]`）→ 卡片上不可能有那些按钮。
        //
        // 不绑 token 后它是**普通通知**，按钮由本类自己画的卡片渲染，语义正确：
        // 快退/快进 = ±15 秒（不是「回开头」），✕ = 停播 + 撤下通知。
        //
        // 耳机 / 蓝牙媒体键不受影响：仍由上面的 [MediaSession] 接收（它是当前
        // PLAYING 的活跃会话，`dumpsys media_session` 里 Media button session 仍是它）。
        refresh()
        Log.i(
            TAG,
            "bind textureId=$id title=$title artist=$artist status=$status " +
                "playing=$playing pos=$positionMs duration=$durationMs " +
                "hasEpisodeNav=$hasEpisodeNav live=$isLive",
        )
    }

    /**
     * 只更新文案/封面并重画卡片（换集、播放暂停、听视频开关等状态变化）。
     *
     * v2.32.0 起不再需要「服务端 action 列表变了要 invalidate」那一套:
     * 卡片是每次重画时按当前状态现算的（按钮显隐、播放/暂停图标都在
     * [buildCard] 里决定），直接把最新状态写进去再 [refresh] 就够。
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
        if (hasEpisodeNav != null) episodeNavAvailable = hasEpisodeNav
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
                "hasEpisodeNav=$episodeNavAvailable",
        )
        refresh()
    }

    /** 释放会话与通知（播放器被释放 / 页面退出 / 换绑定对象时调用）。 */
    fun release() {
        tearingDown = true
        // 先摘监听器：撤销通知时不能再被播放器事件拉起来重画
        playerListener?.let { listener -> boundPlayer?.removeListener(listener) }
        playerListener = null
        cancelNotification(pushStop = false)
        session?.release()
        session = null
        boundPlayer = null
        boundTextureId = null
        liveMode = false // 下次 bind 重新判定（可能换成 VOD 播放器）
        episodeNavAvailable = false // 同上：下一次 bind 重新判定
        coverBitmap = null
        coverBitmapUrl = null
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
     * 异步下载封面，完成后重画卡片把图贴上去。
     *
     * 不缓存 URL 以外的状态：换视频时 [coverUrl] 立刻变，旧图无论如何都不会被
     * 用上（回调前再校验一次 URL）。URL 不同即重新下载，因此「快速换集」也能
     * 在最后一次 [update] 后拿到正确的封面。
     *
     * v2.32.0 之前走 media3 的 `BitmapCallback`；自绘卡片后直接 [refresh]：
     * 卡片每次重画都会读 [coverBitmap]。
     */
    private fun loadCover(url: String) {
        Thread {
            val bitmap = downloadBitmap(url)
            mainHandler.post {
                if (coverLoadingUrl == url) coverLoadingUrl = null
                if (bitmap == null || url != coverUrl) return@post // 已换视频：丢弃旧图
                coverBitmap = bitmap
                coverBitmapUrl = url
                refresh()
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
 * 只包装**给会话看**的玩家；播放行为与通知卡片仍走真实 ExoPlayer，不受包装器影响。
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
