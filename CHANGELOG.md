# 更新日志（CHANGELOG）

本项目按 [SemVer](https://semver.org/) 约定：`主版本.次版本.修订号+构建号`。

`修订号` 用于 bug 修复与微调；`次版本` 用于新功能；`主版本` 用于不兼容变更。

所有版本变更按时间倒序记录；最新版本在最上方。

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