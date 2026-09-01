# 更新日志（CHANGELOG）

本项目按 [SemVer](https://semver.org/) 约定：`主版本.次版本.修订号+构建号`。

`修订号` 用于 bug 修复与微调；`次版本` 用于新功能；`主版本` 用于不兼容变更。

---

## v2.13.0（2026-09-01，T2 UP 主功能）

**新增**
- **白名单 UP 主**：搜索页「搜索 UP 主」Tab（B 站全网用户搜索），结果可一键加入白名单；UP 主详情页展示头像 + 名字 + 粉丝 + 简介 + 视频列表（最新发布 / 最多播放 / 最多收藏 三种排序，分页 20 条/页）
- **信箱**：首页 AppBar 最左侧图标（带未读红点），启动 5s 后自动检查所有白名单 UP 主的新视频；下拉刷新强制重检；顶部「全部标记已读」一键清空
- **数据模型 v4**：`whitelist.json` 顶层新增 `upowners[]` 数组（兼容 v3：缺字段视为 `[]`），写回 Gist 时统一规范化为 `version=4`
- **新接口**：
  - `BiliApi.searchUpowner(keyword, page)`（`search_type=bili_user`）
  - `BiliApi.fetchUpownerVideos(mid, pn, ps, order)`（`x/space/wbi/arc/search`）
  - `BiliApi.fetchUpownerInfo(mid)`（`x/space/wbi/acc/info`）
- **风控降级**：信箱检查遇 -412/-352 自动降级（间隔 1.5s → 3s，最多 100 个 UP 主）

**优化**
- 「我的白名单」Tab 搜索框提示区分 Tab 文案（视频 / UP 主）

---

## v2.12.1（2026-08-20）

**修复 / 改进**
- 视频搜索翻页 + 排序选择器（综合 / 最多播放 / 最新发布 / 最多收藏）
- `flutter_secure_storage` vivo 等国产 ROM 兼容加固（显式 `AndroidOptions`，`encryptedSharedPreferences=false` + `resetOnError=true`）

---

## v2.12.0（2026-08-19）

**新增**
- 合集与视频拖动排序（同步 Gist）

---

## v2.11.3（2026-08-18）

**修复**
- 移动合集弹窗超长列表可滚动

---

## v2.11.2（2026-08-17）

**修复**
- R8 保留 ffmpeg-kit native 方法（修复 release 版插件注册中断）

---

## v2.11.1（2026-08-15）

**修复**
- 禁用自动备份防 Keystore 密钥失效（`secure storage` 数据不可用）

---

## v2.11.0 之前

见 git tag / commit 历史。