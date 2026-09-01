# 更新日志（CHANGELOG）

本项目按 [SemVer](https://semver.org/) 约定：`主版本.次版本.修订号+构建号`。

`修订号` 用于 bug 修复与微调；`次版本` 用于新功能；`主版本` 用于不兼容变更。

所有版本变更按时间倒序记录；最新版本在最上方。

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