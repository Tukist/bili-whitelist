# Changelog

所有版本变更按时间倒序记录；最新版本在最上方。

## v2.14.0 (2026-09-01)

- **新增**：应用内版本更新（GitHub Releases 检查 → 下载 → 一键安装）
  - 启动 5s 后静默检查（24h 节流），有新版本且非强制时弹窗
  - 管理面板 → 「检查更新」手动触发（force=true 跳过节流）
  - 更新弹窗展示 changelog + 进度条 + 取消 / 重试
  - 下载完成自动触发系统安装（FileProvider 暴露 ApplicationSupport/updates）
- **新增**：强制更新字段 `min_supported_code` 预留，首版不启用
- **MVP 简化**：当前只发 arm64-v8a APK；armeabi-v7a / x86_64 后续补
- 工具链：`build_release.sh` 末尾新增第 6 步，当 `GH_REPO_TOKEN` 已设置时自动创建
  GitHub Release 并上传 3 ABI APK（jq 不可用时降级 python -c）

## v2.12.1 (2026-09-01)

- 合集管理 Bug 修复 + 搜索结果翻页 / 全集号定位优化
- 详见 commit 1aebfc5 历史
