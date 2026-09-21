package com.biliwhitelist.bili_whitelist_app

import androidx.media3.common.PlaybackException
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `DashExoPlayer.isRecoverableSourceError` 的分类单测（纯 JVM，不需要设备）。
 *
 * 为什么值得测：这个函数决定一次播放错误是「原生发 onUrlExpired → Dart 换源续播」
 * 还是「发 onError → 弹『播放失败（2001）』打断观看」——用户反复抱怨的间歇性
 * 2001 正是漏在这里（2001 是 media3 的 IO 兜底桶，只按 cause 类型判会漏掉
 * EOFException / SSLException / 通用 IOException）。
 *
 * ⚠️ Dart 侧另有一份**等价的错误码镜像判定**
 * （`lib/pages/player_page.dart` 的 `kRecoverableNativeErrorCodes`，用于 Dart
 * 兜底），改这里的判定时两边一起改（对应 Dart 用例在
 * `test/player_stream_line_test.dart` 的「镜像判定」组）。
 *
 * 注意：不构造 `PlaybackException`（它的构造器内部要
 * `Clock.DEFAULT.elapsedRealtime()` → Android 的 `SystemClock`，纯 JVM 下会抛
 * 「not mocked」），所以被测函数的入参刻意是 `(errorCode, cause)`。
 */
class RecoverableSourceErrorTest {

    // ---------------------------------------------------------------------
    // ① 错误码：IO 兜底桶（本次修复新增的可恢复判据）
    // ---------------------------------------------------------------------

    @Test
    fun `2001 网络连接失败_读流被判定断开_可恢复`() {
        // media3 1.5.1：HttpDataSourceException.createForIOException 把「其余一切
        // IOException」都归一成 2001（EOFException = 流被对端掐断，实测弱网常见）
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                EOFException("unexpected end of stream"),
            )
        )
    }

    @Test
    fun `2001 且 cause 是白名单外的 IOException_同样可恢复`() {
        // 修复前：只看 cause 类型 → SSLException / 通用 IOException 全被漏掉，
        // 于是原样弹「播放失败（2001）」
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                SSLException("connection reset by peer"),
            )
        )
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                IOException("unexpected"),
            )
        )
    }

    @Test
    fun `2001 且没有 cause_按错误码即可恢复`() {
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                null,
            )
        )
    }

    @Test
    fun `2002 连接超时_可恢复`() {
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
                SocketTimeoutException("read timed out"),
            )
        )
    }

    @Test
    fun `2000 IO_UNSPECIFIED_不可恢复_（HTTP 路径上它会被改写成 2001，真留 2000 的多是本地文件）`() {
        assertFalse(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                IOException("unspecified"),
            )
        )
    }

    @Test
    fun `2005 文件不存在_不可恢复（本地缓存文件缺失，重试无意义）`() {
        assertFalse(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
                IOException("no such file"),
            )
        )
    }

    @Test
    fun `解析类错误_不可恢复（重取流也救不了坏流）`() {
        assertFalse(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
                IOException("malformed"),
            )
        )
    }

    @Test
    fun `解码类错误_不可恢复`() {
        assertFalse(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
                IOException("decoder"),
            )
        )
    }

    // ---------------------------------------------------------------------
    // ② cause 链：原有白名单（本次改动必须保留，不许削弱）
    // ---------------------------------------------------------------------

    @Test
    fun `cause 链上的读超时_可恢复（沿 cause 链可达内层）`() {
        val wrapped = IOException("read failed", SocketTimeoutException("timeout"))
        assertTrue(isRecoverableSourceError(PlaybackException.ERROR_CODE_UNSPECIFIED, wrapped))
    }

    @Test
    fun `域名解析失败_可恢复`() {
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_UNSPECIFIED,
                UnknownHostException("upos-sz-mirrorhw.bilivideo.com"),
            )
        )
    }

    @Test
    fun `连接被重置_拒绝_可恢复（SocketException 及其子类 ConnectException）`() {
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_UNSPECIFIED,
                SocketException("Connection reset by peer"),
            )
        )
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_UNSPECIFIED,
                ConnectException("Connection refused"),
            )
        )
    }

    // `HttpDataSource.InvalidResponseCodeException` 在纯 JVM 单测里造不出来
    // （构造参数要 DataSpec，而 DataSpec 对 android.net.Uri 做了 checkNotNull，
    // JVM 单测里 Uri 恒为 null）→ 状态码**策略**单独抽成纯函数
    // [isRecoverableHttpStatus] 在这里测，类型分派那行是一眼可读的 `is` 判断。
    @Test
    fun `流地址过期_403_404_410_429_可恢复（重取流换新签名地址）`() {
        for (code in intArrayOf(403, 404, 410, 429)) {
            assertTrue("HTTP $code 应可恢复", isRecoverableHttpStatus(code))
        }
    }

    @Test
    fun `CDN_网关瞬时故障_5xx_可恢复`() {
        for (code in intArrayOf(500, 502, 503, 599)) {
            assertTrue("HTTP $code 应可恢复", isRecoverableHttpStatus(code))
        }
    }

    @Test
    fun `HTTP_4xx_非过期类（400_401_402_418）_不可恢复`() {
        for (code in intArrayOf(400, 401, 402, 418)) {
            assertFalse("HTTP $code 不该被当成可恢复", isRecoverableHttpStatus(code))
        }
    }

    @Test
    fun `两条判据彼此独立_任一命中即可恢复_都不命中才不恢复`() {
        // 只有状态码命中（错误码不认识）
        assertTrue(isRecoverableHttpStatus(410))
        // 只有错误码命中（cause 为 null、也不属 java.net 白名单）
        assertTrue(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
                null,
            )
        )
        // 两条都不命中 → 不恢复
        assertFalse(isRecoverableHttpStatus(418))
        assertFalse(
            isRecoverableSourceError(PlaybackException.ERROR_CODE_UNSPECIFIED, null)
        )
    }

    @Test
    fun `cause 链为空且错误码不认识_不可恢复（保持原判定不放宽）`() {
        assertFalse(isRecoverableSourceError(PlaybackException.ERROR_CODE_UNSPECIFIED, null))
        assertFalse(
            isRecoverableSourceError(
                PlaybackException.ERROR_CODE_TIMEOUT,
                InterruptedIOException("interrupted"),
            )
        )
    }
}
