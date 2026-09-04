# 更新日志（CHANGELOG）

本项目按 [SemVer](https://semver.org/) 约定：`主版本.次版本.修订号+构建号`。

`修订号` 用于 bug 修复与微调；`次版本` 用于新功能；`主版本` 用于不兼容变更。

所有版本变更按时间倒序记录；最新版本在最上方。

---

## v2.16.10 (2026-09-04)

**修复**

- **白名单 UP 主隔段时间重进 App 后被自动清空（油猴脚本丢 v4 upowners 字段）**：
  - **问题**：v2.13.0 App 新增顶层 `upowners`（UP 主白名单，数据模型升 v4），但**油猴脚本 v2.3.0 的 `parseWhitelist` / `buildWhitelistJson` 仍只认识 `version/updated_at/collections/videos`**——在电脑上用油猴加视频时 GET→PATCH 覆盖写回，把 Gist 里的 `upowners` 整个字段丢掉（与历史「合集消失」同款 bug：当时油猴旧版只认识 videos、不保留 collections）。之后手机重进 App 触发同步，拉到的是已被清空的 Gist，表现为「UP 主被自动清空」
  - **修复（油猴 v2.3.1）**：`parseWhitelist` 透传保留顶层 `upowners` 数组（读入即保留、内容不丢）；`buildWhitelistJson` 对缺失的 `upowners` 补空数组兜底（序列化不再丢键）；空结构初始化同步带 `upowners: []`
  - **App 端核对结论**：`WhitelistData` 模型 `fromJson/toJson/copyWith/normalizedForSave` 与全部写 Gist 路径（`GithubApi.saveToGist` 载荷、`WhitelistWriter.addVideo/importPgcSeason/合集移动/删除/重排`、`UpownerWriter.add/removeByMid/updateLastSeenBatch`、信箱、`SyncService.saveToCache`）均保留 `upowners`，无丢失路径——本版本补回归单测：**所有管理变换（改名/删除合集、合集重排、视频移合集/移除/拖拽重排、UP 主增删）与模型往返、保存序列化均保留 `upowners`**（`test/whitelist_order_test.dart` 新增 7 用例）
  - **数据现状**：Gist 上 `upowners` 已被上述 bug 清空且无可恢复备份（本地各备份 / git 历史均不含），**已丢失的 UP 主需在 App 搜索页重新添加一次**；修复后油猴/App 任意写入不再丢

---

## v2.16.9 (2026-09-04)

**修复**

- **播放页滑动手势主导方向判定（横屏 seek 与亮度/音量共存）**：
  - **问题**：v2.16.7 手势按"横屏只注册横向、竖屏只注册纵向"分方向注册——人无法完全垂直 / 水平滑动，**全屏横屏稍斜的上下滑会被误判成横向 seek**（调节亮度 / 音量失效），较正的上下滑又完全无响应
  - **修复（参考 B 站）**：滑动统一走单一 Pan 手势，位移累计超 12px 阈值后按**主导分量**锁定方向——水平位移主导 → 全屏横屏 seek（位移比例 = 时长比例，松手 seekTo）；垂直位移主导 → 按起点左半屏调亮度 / 右半屏调音量（**横屏竖屏都可用**）；斜向滑动按主方向归类，**锁定后本次手势不再切换**（防中途抖动）。竖屏仍只保留亮度 / 音量（水平主导忽略，无 seek 防误触）
  - **纯函数**：新增 `decideMode(dx, dy, threshold)`（|dx| ≥ |dy| → 水平、|dy| > |dx| → 垂直、均未超阈值 → 未定）+ `nextPanMode`（方向锁定），单测覆盖斜向归类 / 45° 平分 / 负方向 / 锁定后不受后续位移影响（`test/player_gesture_test.dart`，14 → 21 用例）

---

## v2.16.8 (2026-09-03)

**修复**

- **应用内更新下载修复（断点续传 + 网络异常友好提示）**：
  - **网络中断不再「整体重下」**：之前下载到一半断网，dio 抛 `unknown`（底层 IOException，message 常为 null/英文）→ 用户看到「网络异常：未知错误」，且半成品被直接删除、下次必须整体重新下载
  - **断点续传**：下载目标改为半成品 `.part` 文件（`app-update-<code>.apk.part`）——下载前若 `.part` 已存在，按其字节数带 `Range: bytes=N-` 续传（服务器回 206 追加续传、200 不支持 Range 则全量重写），下载完成才改名正式 APK；**失败 / 取消都保留 `.part`**，下次点「重试 / 立即更新」自动从断点继续
  - **错误分类友好化**：断网 / 连接被重置 / 接收中断 → 「网络中断，下载未完成，请检查网络后重试（将自动从断点继续）」；超时 / 连接失败 / HTTP 403 / 404 各有明确中文提示；未知错误兜底给「网络异常，请检查网络后重试」——**任何路径不再出现「未知错误」裸文案**
  - **自动重试**：瞬时网络错误自动重试 2 次（1s→2s 指数退避），每次重试从断点继续；HTTP 业务错误（403/404）与用户取消不重试
  - **完整性校验**：`.part` 下载完成仍对整个文件做 SHA-256 校验（`info.sha256` 存在时），失败删除文件抛「完整性校验失败」
  - **进度基数修正**：续传时进度分母优先取 APK 完整大小（`asset.size` / `Content-Range`），下载进度从上次断点累计，不跳变

**其他**

- 下载文件改名带 versionCode（`app-update-<code>.apk`），换新版本自动清理旧版本号残留半成品，避免跨版本续接拼出损坏文件

---

## v2.16.7 (2026-09-03)

**新增**

- **播放页 B 站式快捷手势**（参照 B 站手机端播放器）：
  - **双击播放 / 暂停**：画面任意处快速双击切换播放 / 暂停（与单击显隐共存——单击因等待双击窗口判定延迟 ~300ms 触发显隐；双击赢得手势时延迟的单击自动取消，不误触显隐）
  - **横屏左右滑 seek（全屏）**：全屏横屏下画面左右滑动按**位移比例**拖动进度（滑满一屏 ≈ 100% 时长），滑动中浮层实时显示「当前进度 / 总时长」（如 `12:34 / 56:78`），**松手 seekTo** 并保存进度；方向与进度条一致（右滑前进、左滑后退）
  - **竖屏半屏上下滑调亮度 / 音量**：竖屏（非全屏）左半屏纵向滑动调**应用内亮度**、右半屏调**媒体音量**——滑满一屏 ≈ 0↔100%，**调节即时生效、松手不恢复**，滑动中浮层显示图标 + 百分比
  - **手势冲突处理**：单击显隐 / 双击暂停 / 长按 2x / 横屏 seek / 竖屏亮度·音量 / 进度条拖动 / 控制层按钮——横向与纵向手势**按屏幕方向分道注册**（全屏只注册横向、竖屏只注册纵向，另一方向不存在即不会抢判定）；控制层按钮与进度条位于 Stack 上层，其区域内点击 / 拖动天然优先（按钮优先）

**原生通道（新增）**

- `bili_whitelist/media` MethodChannel（android/app/src/main/kotlin/.../MediaController.kt）：`getVolume` / `setVolume`（AudioManager STREAM_MUSIC，按档精确设置且不弹系统音量 UI）+ `getBrightness` / `setBrightness`（应用内亮度——WindowManager LayoutParams.screenBrightness 0~1，仅当前 Activity、退出播放恢复系统亮度；下限钳 5% 防全黑时浮层不可见）；Dart 侧封装 `lib/services/device_media.dart`，通道不可用 / 异常静默放弃本次手势（不打断播放）

**重构**

- 播放页手势纯逻辑抽为可单测顶层函数：`verticalSlideKind`（半屏判定）/ `slideFraction`（位移→比例，拖满一屏=±100%）/ `seekTargetMs`（seek 目标，钳制 0..时长）/ `volumeTargetLevel` / `adjustPercent` / `brightnessPercent`（亮度下限 5%），单测 `test/player_gesture_test.dart`（14 用例）

---

## v2.16.6 (2026-09-03)

**新增**

- **弹幕增强**（播放页「弹幕」，长按弹幕按钮弹出设置面板集中管理）：
  - **移动平滑**：滚动弹幕位置按帧间时间差（dt）浮点精确推进，dt 钳制上限防掉帧跳变（卡顿恢复平滑不"生硬"）；单帧发射预算限制，密集弹幕分散到后续帧逐个进入（帧率稳定）；滚动穿越时长 5s → 4s（更接近 B 站节奏）；顶部 / 底部弹幕带 0.15s 淡入 + 0.4s 淡出
  - **真碰撞分层（消除叠字）**：不再 round-robin——滚动弹幕按水平轨道分配，每条轨道记录最后一条弹幕的尾缘 / 速率，新弹幕按**追尾时间精确判定**能否同轨（O(1)，无每帧重排；同速跟车保持间距、快车只在追上时慢车已出屏才同轨），轨道打满丢弃并计数；顶部 / 底部各自纵向行堆叠（停留占行、取最上空闲行，全忙丢弃）
  - **弹幕屏蔽**：屏蔽关键词列表（substring 匹配、去空白去重、增删管理）+ 屏蔽类型开关（滚动 / 顶部 / 底部分别控制）；发射前过滤，设置变更即时清屏按当前位置重载生效
  - **透明度调节**：滑杆 20%~100% 实时预览，绘制 alpha 全局乘系数（含阴影）；与屏蔽设置一并本地持久化（shared_preferences），下次进入自动恢复
  - 弹幕活动周期日志（debugPrint：发射 / 屏蔽 / 丢弃计数 + 屏上活跃 vs 轨道数）供 logcat 实测

**重构**

- 播放页弹幕逻辑拆分：纯逻辑 `models/danmaku_lanes.dart`（滚动追尾判定 + 顶 / 底行堆叠分配器）、`models/danmaku_settings.dart`（屏蔽词 / 类型 / 透明度 + 序列化容错）、`services/danmaku_settings_store.dart`（持久化，失败静默）；渲染层 `widgets/danmaku_overlay.dart` 按设置实例变化自动重载

---

## v2.16.5 (2026-09-03)

**新增**

- **搜索支持番剧 / 电影并可导入**：「全部 B 站」搜索页新增搜索范围切换（视频 / 番剧 / 电影 / 电视剧）：
  - 番剧 / 电影走 media 搜索接口（`x/web-interface/wbi/search/type`，`search_type=media_bangumi / media_ft`，匿名 + WBI 签名即可，2026-09 curl 实测确认字段：`season_id`（整季导入钥匙，无顶层 `ep_id`）/ `title`（含高亮标签需清洗）/ `cover`（偶有 `http://` 前缀需补 https）/ `badges[]` 角标（独家、大会员）/ `styles` 风格串 / `index_show`（「全14话」或上映日期）/ `eps[0].id` 首集 ep_id）
  - 结果列表展示封面 + 类型角标 + 标题 + 角标/集数/风格副标题；右侧「导入」**整季逐集加入白名单**（与首页粘贴链接导入共用 `WhitelistWriter.importPgcSeason` + `runPgcSeasonImport`，进度逐集提示、bvid 查重自动跳过已存在集），导入后按钮变「已导入」（会话级记忆 + 白名单首集 ep_id 匹配双重判断）
  - media 结果同样支持上拉翻页（`data.numResults` 判断，与视频搜索同一套 `hasMore` 逻辑）；排序 chip 仅视频范围显示（media 接口不支持 order）
  - 电视剧（`media_tv`）/ 纪录片（`media_doc`）入口同样可切：**匿名请求实测被 B 站降级过滤（code=-1200「被降级过滤的请求」）**，错误分类提示「可能需登录」，番剧/电影不受影响

**重构**

- 番剧/电影整季导入逻辑从首页私有方法抽为共用：`WhitelistWriter.importPgcSeason`（纯逻辑：拉整季 + 逐集 addVideo，进度回调，异常汇总）+ `widgets/pgc_import_dialog.dart` 的 `runPgcSeasonImport`（UI 编排：配置门禁 + 进度对话框 + 结果反馈），首页粘贴链接导入与搜索页 media 结果导入共用同一实现与文案

---

## v2.16.4 (2026-09-03)

**新增**

- **会员番剧完整播放**：番剧/电影整季导入时每集写入 `epId`（番剧集标识，向后兼容：旧数据无该字段不受影响）。播放带 `epId` 的番剧集时，普通接口取流失败（会员集实测返回 -404）自动回退 pgc 番剧取流接口（`pgc/player/web/playurl`，登录态 SESSDATA 随请求注入）：
  - 免费集仍优先走普通接口（720P 比 pgc 端点的更清晰），行为不变
  - 会员/付费集**登录大会员账号后可完整播放**；未登录/非大会员时匿名接口只给试看流（`is_preview=1`，仅前几分钟），App **不播试看**、明确提示「该集为大会员内容，当前为试看（仅前几分钟），请登录大会员账号完整观看」并引导去登录——避免"能播但只有几分钟"的误导
  - 旧版导入的番剧数据（无 epId）保持原「该集可能为大会员/付费内容或已下架」提示

---

## v2.16.1 (2026-09-02)

**修复**

- **应用内更新在私有仓库下完全不可用**：仓库是私有的且从未创建过 GitHub Release，`releases/latest` 匿名访问永远 404。
  - `UpdateService` 新增 `tokenProvider`（主页接管理页已配置的 GitHub token）：`fetchLatest` 带 `Authorization` 头访问 Releases API。
  - 私有仓库 APK 资产下载改为两段式：先带 token + `Accept: application/octet-stream` 请求资产 API 地址，手动跟随 302 到签名 CDN 地址后再下载——鉴权头不随跳转转发（否则 S3 双重鉴权报 400）。
  - `UpdateInfo` 新增 `apkApiUrl` 字段（资产 `url`）；资产选择按设备 ABI 匹配（arm64-v8a / armeabi-v7a / x86_64 / x86），无匹配回退 arm64-v8a。
  - GitHub 401 单独提示「token 无效或已过期」。

---

## v2.16.0 (2026-09-02)

**新增**

- **观看历史**：主页左滑进入历史记录界面，AppBar 也有入口图标；播放页自动写入观看进度，历史列表可按进度续播。

---

## v2.15.1 (2026-09-01)

**新增**

- 首页支持左右滑动：第一页管理视频合集，第二页管理白名单 UP 主；可查看、进入、移除已加入的 UP 主，并可直接跳到「搜索 UP 主」。
- UP 主详情页新增「在该 UP 主的视频中搜索」输入框，只在当前白名单 UP 主投稿内过滤，保留排序与分页加载。
- `BiliApi.fetchUpownerVideos` 新增 `keyword` 参数，对接 B 站 `x/space/wbi/arc/search` 的 UP 主内稿件搜索。
- 「检查更新」遇到 GitHub Release 404 时改为提示“暂时没有可用更新 / Release 未创建 / 仓库不可访问”，不再误报“版本仓库不存在”。

---

## v2.15.0 (2026-09-01，T2+T3 合并发布)

**新增**

- **白名单 UP 主**：搜索页「搜索 UP 主」Tab（B 站全网用户搜索），结果可一键加入白名单；UP 主详情页展示头像 + 名字 + 粉丝 + 简介 + 视频列表（最新发布 / 最多播放 / 最多收藏 三种排序，分页 20 条/页）
- **信箱**：首页 AppBar 最左侧图标（带未读红点），启动 5s 后自动检查所有白名单 UP 主的新视频；下拉刷新强制重检；顶部「全部标记已读」一键清空
- **应用内版本更新**：启动 5s 后静默检查（24h 节流），有新版本且非强制时弹窗；管理面板 →「检查更新」手动触发（force=true 跳过节流）；下载完成自动触发系统安装（FileProvider 暴露 ApplicationSupport/updates）
- **强制更新字段 `min_supported_code` 预留**，首版不启用

**数据模型 / 接口**

- `whitelist.json` 顶层新增 `upowners[]` 数组（兼容 v3：缺字段视为 `[]`），写回 Gist 时统一规范化为 `version=4`
- 新接口：
  - `BiliApi.searchUpowner(keyword, page)`（`search_type=bili_user`）
  - `BiliApi.fetchUpownerVideos(mid, pn, ps, order)`（`x/space/wbi/arc/search`）
  - `BiliApi.fetchUpownerInfo(mid)`（`x/space/wbi/acc/info`）

**工具链**

- `build_release.sh` 末尾新增第 6 步：当 `GH_REPO_TOKEN` 已设置时自动创建 GitHub Release 并上传 3 ABI APK（jq 不可用时降级 python -c）

**风控降级**

- 信箱检查遇 -412 / -352 自动降级（间隔 1.5s → 3s，最多 100 个 UP 主）

---

## v2.13.0 (2026-09-01，T2 UP 主功能单独提交版本)

注：实际合并到 v2.15.0 发布，单 commit 版本号保留 v2.13.0+25。

**新增**

- 白名单 UP 主 + 信箱（同 v2.15.0 描述）

---

## v2.12.1 (2026-09-01)

- 合集管理 Bug 修复 + 搜索结果翻页 / 全集号定位优化
- 视频搜索翻页 + 排序选择器（综合 / 最多播放 / 最新发布 / 最多收藏）
- `flutter_secure_storage` vivo 等国产 ROM 兼容加固（显式 `AndroidOptions`，`encryptedSharedPreferences=false` + `resetOnError=true`）

---

## v2.12.0 (2026-08-19)

**新增**

- 合集与视频拖动排序（同步 Gist）

---

## v2.11.3 (2026-08-18)

**修复**

- 移动合集弹窗超长列表可滚动

---

## v2.11.2 (2026-08-17)

**修复**

- R8 保留 ffmpeg-kit native 方法（修复 release 版插件注册中断）

---

## v2.11.1 (2026-08-15)

**修复**

- 禁用自动备份防 Keystore 密钥失效（`secure storage` 数据不可用）

---

## v2.11.0 之前

见 git tag / commit 历史。