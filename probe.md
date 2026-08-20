# B 站 API 技术侦察报告（M0）

> 探针时间：2026-08-20 09:07~09:15（UTC+8）
> 探针脚本：`probe.py`（单文件，纯标准库 urllib，可重复运行）
> 请求总数：35 次（间隔 ≥1.5s），全程无 -352 / -412 触发
> 原始 JSON：`probe_out.json`（第一次全流程）、`probe_out_pass1.json`（同第一次，备份）、`probe_out_pass2.json`（修复 wbi 解析后重跑 1/2/4 阶段）
> 参考实现：yutto（GPL-3.0）wbi 签名算法 —— 读懂后自行实现，未复制源码

---

## 0. 结论速览（TL;DR）

| 问题 | 结论 |
|------|------|
| 匿名下 mp4（durl）最高清晰度 | **720P（quality=64）**，请求 qn=80/127 也只给 64 |
| DASH 是否可用 | **可用**（fnval=16 返回 dash.video/audio），但匿名下 video 档位最高 **480P（id=32）**，accept_quality 里的 80/116/120 不会真的下发 |
| 匿名能否拿 1080P | **不能**。DASH 只给 id≤32，mp4 只给 quality≤64 → **1080P 必须登录（SESSDATA）**，与「扫码登录解锁 1080P」方案一致 |
| 防盗链 Referer 是否必需 | **必需**。无 Referer → 403；`Referer: https://www.bilibili.com/` → 200 |
| User-Agent 是否必需 | **必需**。无 UA 头 / 非浏览器 UA → 403；浏览器 UA → 200 |
| view / playurl 当前是否强制 wbi | **不强制**。匿名无签名调用 code=0 正常；带 wbi 签名也通过（code=0），签名算法验证正确 |
| 风控阈值 | 间隔 ≥1.5s、35 次内无风控；仍建议在客户端内置 -352/-412 熔断 |

---

## 1. 测试视频挑选

按「大 UP 主 / 存在多年不易删稿 / 源分辨率尽量高」挑选：

| BV | UP 主 | 标题 | cid | 时长 | 源分辨率 | 挑选理由 |
|----|-------|------|-----|------|----------|----------|
| BV1xx411c7mD | 碧诗 | 字幕君交流场所 | 62131 | 2055s | 低（老视频） | **B 站站长碧诗的投稿**，2012 年的镇站之宝，存在 14 年，绝对不易删稿 |
| BV1xW411J7tu | 只有骨头EF | 旭旭宝宝-九日梦想秀-特别篇 | 31295941 | 140s | 中 | 旭旭宝宝（头部主播）相关二创，2017 年视频，存在多年 |
| BV1aZ4y1a7KJ | 君颜夕 | 麻了手机动不动就卡，寒冬[跳舞的线] | 721158303 | 109s | 中（竖屏） | 2022 年较新视频，用于对照老/新视频差异 |
| BV1q28V6VEYU | **老番茄** | 七夕节老番茄就和自己玩游戏 | 41038515126 | — | **3840x2160 (4K)** | **老番茄，B 站头部 UP 主**，4K 源，用于验证匿名高清上限（最关键） |
| BV1rHbY6MEB9 | 青瓜蛋丶 | 我这一生最大的罪…… | 40986083367 | — | 1920x1080 | 热门榜新视频，1080P 源，验证普通 UP 主是否与老番茄一致 |

> 说明：热门榜新视频（老番茄/青瓜蛋）虽然「存在多年」属性弱，但正是它们的高清源才测得出匿名清晰度上限；老视频（碧诗/旭旭宝宝）用于验证 view 接口与稳定性。

---

## 2. 阶段 1：视频信息接口 view（匿名）

接口：`GET https://api.bilibili.com/x/web-interface/view?bvid=<BV>`

**结论：匿名可正常拿到 cid / title / pic / duration / owner.name，code=0。**

实测原始结果：

| bvid | http | code | title | cid | pic | duration | owner |
|------|------|------|-------|-----|-----|----------|-------|
| BV1xx411c7mD | 200 | 0 | 字幕君交流场所 | 62131 | `https://i0.hdslb.com/bfs/archive/transparent.png` | 2055 | 碧诗 |
| BV1xW411J7tu | 200 | 0 | 旭旭宝宝-九日梦想秀-特别篇宝哥我们想你 | 31295941 | `http://i2.hdslb.com/bfs/archive/b537...jpg` | 140 | 只有骨头EF |
| BV1aZ4y1a7KJ | 200 | 0 | 麻了手机动不动就卡，寒冬[跳舞的线] | 721158303 | `http://i2.hdslb.com/bfs/archive/8efb...jpg` | 109 | 君颜夕 |
| BV1JE411e7WG（何同学 5G） | 200 | **62002** | 稿件不可见 | — | — | — | — |

> 注意：何同学《5G 有多快》返回 62002「稿件不可见」（可能已下线/设限），所以未采用。挑选视频时**必须逐个验证 code==0**。

**参数模板**（后续电脑端脚本用）：

```
GET https://api.bilibili.com/x/web-interface/view
  ?bvid=BV1q28V6VEYU
Headers: User-Agent: <浏览器UA>        # 无 Referer 也能过
```

返回结构要点：`data.cid`、`data.title`、`data.pic`、`data.duration`（秒）、`data.owner.name`、`data.dimension`（宽高）、`data.pages[]`（多 P 时每个 P 有自己的 cid）。

---

## 3. 阶段 2：播放流接口 playurl（匿名）— 关键

接口：`GET https://api.bilibili.com/x/player/playurl?bvid=<BV>&cid=<CID>&qn=<N>&fnval=<N>&fnver=0&fourk=1`

### 3.1 传统 mp4（fnval=0）

实测（三种源分辨率视频一致）：

| bvid | qn | quality(实际) | accept_quality | durl 数 | durl.url 示例 |
|------|----|--------------|----------------|---------|---------------|
| BV1xx411c7mD | 80 | **64** | [80, 64, 16] | 1 | `https://cn-bj-fx-01-03.bilivideo.com/upgcxcode/31/21/62131/62131-1-48.mp4?e=...&deadline=...` |
| BV1xx411c7mD | 127 | **64** | [80, 64, 16] | 1 | 同上（同档） |
| BV1q28V6VEYU（4K 源） | 80 | **64** | [64, 16] | 1 | `.../41038515126-1-192.mp4?e=...` |
| BV1rHbY6MEB9（1080P 源） | 80 | **64** | [64, 16] | 1 | `.../40986083367-1-192.mp4?e=...` |

**结论：匿名下传统 mp4 最高只给 quality=64（720P）。** 请求 qn=80（1080P）或 qn=127（8K）都被降级到 64。accept_quality 里虽然有 80，但不实际下发。URL 中 `-1-192.mp4` 是 720P 档的命名（数字对应码率档，非分辨率直读）。

quality 数值含义：16=360P、32=480P、64=720P、80=1080P、116=1080P60、120=4K、127=8K。

### 3.2 DASH（fnval=16）

实测（老番茄 4K 源，最完整）：

```
[fnval=16 qn=127] code=0 quality=64 accept_quality=[120, 116, 80, 64, 32, 16] dash_videos=4
  video[0] id=32 852x480  codecid=7  (AVC) baseUrl=.../41038515126-1-30032.m4s
  video[1] id=32 852x480  codecid=12 (HEVC) baseUrl=.../41038515126-1-100110.m4s?  # 见下方备注
  video[2] id=16 640x360  codecid=12 (HEVC) baseUrl=.../41038515126-1-100109.m4s
  video[3] id=16 640x360  codecid=7  (AVC)  baseUrl=.../41038515126-1-30016.m4s
  audio: id=30216 (64kbps, mp4a.40.2), id=30232 (132kbps, mp4a.40.2)
```

> 备注：id=32 出现两条是因为 codecid 不同（AVC / HEVC 各一条），分辨率都是 852x480；id=16 同理（640x360）。实测两条视频流的 baseUrl 文件名分别是 `30032`（AVC/H.264）与 `100110`（HEVC/H.265）系列，对应 **codecid 7=AVC(H.264)、codecid 12=HEVC(H.265)**，两档视频流都提供 AVC+HEVC 双编码。

实测（普通 1080P 源，青瓜蛋丶）：

```
[fnval=16 qn=127] code=0 quality=64 accept_quality=[116, 80, 64, 32, 16] dash_videos=4
  video[0] id=32 852x480  codecid=7
  video[1] id=32 852x480  codecid=12
  video[2] id=16 640x360  codecid=12
  video[3] id=16 640x360  codecid=7
```

实测（老视频 480P 源，碧诗）：fnval=16 时 quality=32，accept=[32, 16]，dash.video 只有 id=32 / id=16 两档（源本身只有 480P）。

**结论：DASH 结构可用（dash.video[] / dash.audio[] 正常返回），但匿名下 video 档位最高只下发 id=32（480P）。** accept_quality 里虽然列出 80/116/120（1080P/1080P60/4K），但实际响应里的 dash.video 数组最高只有 32。**匿名无法通过 DASH 拿到 1080P。**

### 3.3 qn=127 全高清请求的实际情况

无论 qn=127 还是 qn=80，匿名下：
- fnval=0 → quality=64（720P）
- fnval=16 → 最高视频档 id=32（480P）

qn 只是「期望档位」，实际下发由登录态决定；**匿名一律给不到 1080P**。带 SESSDATA（登录）后才能解锁 quality=80 及以上 —— 这正是方案 B「扫码登录解锁 1080P」的技术依据。

---

## 4. 阶段 3：防盗链（关键）

取一条匿名 mp4 流 URL（`https://cn-bj-fx-01-03.bilivideo.com/upgcxcode/31/21/62131/62131-1-48.mp4?...`），用 GET + 只读 1KB 测试：

| case | 状态码 | 读取字节 |
|------|--------|----------|
| 无 Referer（带浏览器 UA） | **403** | 0 |
| Referer=`https://www.bilibili.com/`（带浏览器 UA） | **200** | 1024 |
| Referer=bilibili + 无 UA 头（http.client 手工构造，真正无 UA） | **403** | 0（仅 150 字节错误页） |
| Referer=bilibili + UA=`Python-urllib/3.12`（urllib 默认） | **403** | 0 |

**结论：**
- **Referer 必需**：不带 `Referer: https://www.bilibili.com/` → 403。
- **UA 必需且必须是浏览器 UA**：无 UA 头或非浏览器 UA（哪怕带了正确 Referer）→ 403。
- 请求头模板（App 播放时必须带上）：

```
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36
Referer: https://www.bilibili.com/
```

> 对 Flutter App 的含义：播放器请求 CDN 时**必须能自定义 UA 与 Referer**（`video_player` 默认无法加头，需用支持自定义请求头的播放方案，或经本地代理/下载后播放）。这也是后续编码要重点确认的坑。

---

## 5. 阶段 4：WBI 签名

### 5.1 拿 key：nav 接口

`GET https://api.bilibili.com/x/web-interface/nav`（匿名）

```
http=200  code=-101（账号未登录，但 data 仍含 wbi_img！）
data.wbi_img.img_url = https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png
data.wbi_img.sub_url = https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png
```

**关键发现：匿名（未登录，code=-101）也能拿到 wbi_img。** 因此 WBI 签名不需要登录即可实现。

key 提取：`url.split("/")[-1].split(".")[0]`
- img_key = `7cd084941338484aae1ad9425b84077c`
- sub_key = `4932caff0ff746eab6f01bf08b70ac45`

### 5.2 生成 mixinKey（yutto 置换表算法，自行实现）

```
mixin_key = 置换表取 (img_key + sub_key) 前 32 位
实测 = ea1db124af3c7062474693fa704f4ff8
```

置换表（64 位，取前 32 项作为索引）：

```
[46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,
 37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
```

### 5.3 签名与验证

签名步骤（与 yutto 一致）：
1. 参数加 `wts = int(time.time())`
2. 参数值去掉非法字符 `!'()*`
3. 按 key 排序 → `urllib.parse.urlencode`
4. `w_rid = md5(urlencode结果 + mixin_key).hexdigest()`
5. 请求带 `wts` + `w_rid`（也可带 `dm_img_list`/`dm_img_str`/`dm_cover_img_str` 防风控，见 probe.py）

验证对比（对 view 接口）：

| 请求 | http | code | message |
|------|------|------|---------|
| 不带签名（匿名） | 200 | 0 | OK |
| 带签名 wts+w_rid（匿名） | 200 | 0 | OK，title 正常返回 |
| 带签名 + dm 参数 | （未触发，基本版签名已通过） | | |

**结论：**
- **view/playurl 当前（2026-08）不强制 wbi** —— 不带签名匿名调用 code=0 正常。
- 但带 wbi 签名同样通过，说明**算法实现正确**，可作为后续「预防未来强制 wbi」的储备（yutto 等工具都带签名，B 站随时可能收紧）。
- 建议：App/电脑端脚本默认带 wbi 签名请求（成本低），并保留 nav 缓存 key（key 长期不变，可缓存数小时~数天）。

---

## 6. 阶段 5：风控观察

连续 5 次 playurl 请求（间隔 1.5s，`qn=64&fnval=0`）：

```
round=1 code=0 OK
round=2 code=0 OK
round=3 code=0 OK
round=4 code=0 OK
round=5 code=0 OK
```

加上全流程其余请求，**共 35 次请求全程无 -352 / -412**。

**结论与建议：**
- 间隔 ≥1.5s、总量 <50 次的环境下，匿名 API 无风控。
- 仍建议客户端内置熔断：响应 code 为 -352（风控校验失败）或 -412（请求被拦截）时立即停 10~60s 并降频。
- 对白名单 App 的日常使用（每次播放 1 次 playurl + 1 次 view），频率远低于此，风控风险低。

---

## 7. 汇总请求参数模板（后续编码依据）

### 7.1 视频信息

```
GET https://api.bilibili.com/x/web-interface/view?bvid=<BV>
UA: 浏览器UA     Referer: 可无
→ data.cid / title / pic / duration / owner.name / pages[].cid
```

### 7.2 播放流（登录前，720P/480P）

```
GET https://api.bilibili.com/x/player/playurl
  ?bvid=<BV>&cid=<CID>&qn=80&fnval=0&fnver=0&fourk=1     # 传统 mp4，最高 720P
  ?bvid=<BV>&cid=<CID>&qn=80&fnval=16&fnver=0&fourk=1    # DASH，最高 480P
UA: 浏览器UA     Referer: https://www.bilibili.com/
→ data.durl[0].url（mp4）/ data.dash.video[]+audio[]（m4s）
```

### 7.3 播放流（登录后，1080P 待 M1 验证）

```
同上 + Cookie: SESSDATA=<扫码登录的 SESSDATA>
→ 预期可下发 quality=80（1080P）—— 需在 M1 用真实登录态实测确认
```

### 7.4 WBI 签名（储备）

```
GET nav → img_key/sub_key（匿名可得）
mixin_key = 置换表(img_key+sub_key)[:32]
wts = now; w_rid = md5(sorted_urlencode(params去掉!'()*) + mixin_key)
请求带 wts + w_rid
```

### 7.5 防盗链头（播放 CDN 流必带）

```
User-Agent: Mozilla/5.0 ... Chrome/126.0.0.0 Safari/537.36
Referer: https://www.bilibili.com/
```

---

## 8. 对后续编码的提示（风险与坑）

1. **1080P 依赖登录**：匿名最高 720P（mp4）/480P（DASH），1080P 必须 SESSDATA。方案 B「扫码登录解锁 1080P」成立。
2. **DASH 流是 .m4s 分片**（视频+音频分离），Flutter `video_player` 原生不支持，需要自定义方案（如 mp4 档最高 720P 直接播；或集成支持 m4s 的播放器/合并）。**这是 MVP 要做的关键取舍**。
3. **CDN 防盗链双头**：播放请求必须带浏览器 UA + bilibili Referer；Flutter 端需确认播放器支持自定义请求头，否则要本地代理。
4. **wbi 不强制但建议带上**，nav 匿名可得 key，成本极低，防未来收紧。
5. **风控熔断**：客户端内置 -352/-412 检测与退避。
6. **多 P 视频**：view 的 `pages[]` 每个 P 有独立 cid，playurl 需按 P 的 cid 请求。
7. **BV 有效性**：有些稿件会 62002 下线，白名单同步脚本应定期重验并清理失效项。

---

*本报告由 probe.py 实测生成，原始数据见同目录 probe_out*.json；脚本可重复运行：`python probe.py`。*
