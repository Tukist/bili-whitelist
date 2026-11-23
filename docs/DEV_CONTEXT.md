# amoTV 开发上下文（DEV_CONTEXT）

> **给接手的人 / 子智能体**：先读这份文件，再动手。它记录的是「现在代码长什么样」，
> 不是设计愿景。改完代码如果动了模块职责、红线、存储 key，**顺手改这里**
> （这份文档随开发维护；`CHANGELOG.md` 归发布脚本，别手改）。
>
> 最近一次对齐：v2.70.0（2026-11-23）。

---

## 1. 项目是什么

一个「反短视频成瘾」的 B 站点播方案：只看白名单里的视频，没有推荐流（App 内的推荐页是
按自己的观看历史算的，不走 B 站首页算法）。三个部分：

| 部分 | 位置 | 作用 |
|------|------|------|
| Flutter App「amoTV」 | `app/` | 安卓端。5 个页签：合集 / 推荐 / 阅读 / 历史 / 个人 |
| PC 端 Python CLI | `whitelist.py` | 维护 `whitelist.json`：add / remove / list / serve / push |
| 油猴脚本 | `amotv.user.js` | 在 B 站网页上「一键加白」，POST 给本地 `whitelist.py serve` |

**同步方式**：`whitelist.json` 放在 GitHub Gist，App 通过 `api/github_api.dart` 读写
（token + gist_id 存 secure storage）。App 侧数据源抽象在 `sync/whitelist_source.dart`
（Gist 实时 API → Gist raw → LAN → 本地文件 → 缓存，逐级回退）。

数据格式：`whitelist.json` 当前 v4（`models/whitelist_video.dart` 顶部注释写了 v1→v4 的演进：
v2 分 P、v3 合集、v4 UP 主）。书源（阅读模块）**不进 Gist**，只在本机。

---

## 2. 快速上手

```bash
cd D:/pythoncode/bili-whitelist

# 开发中自查（analyze + 你改到的测试文件）
bash app/tools/gate.sh --quick test/history_store_test.dart
bash app/tools/gate.sh --quick history          # 简写：test/ 下找 *history*_test.dart
bash app/tools/gate.sh --quick                  # 只有 analyze

# 发版前全量门禁：analyze + 252 个测试文件分 6 批 + build apk --debug
bash app/tools/gate.sh
bash app/tools/gate.sh --no-build               # 不构建 APK

# 单跑一个测试（不经过门禁）
cd app && flutter test test/history_store_test.dart

# 发布（版本自增 → CHANGELOG → 安全扫描 → commit/push → 构建 → 上传 → 校验）
bash app/tools/release_all.sh 2.71.0 --notes C:/Users/HP/.kimi-tmp/v2710.md
```

- 门禁脚本：`app/tools/gate.sh`（见第 7 节）
- 发布脚本：`app/tools/release_all.sh`（文件头有全部开关：`--all-abis` / `--with-screenshots` / `--no-push` / `--dry-run`）
- **绝对不要**跑 `flutter test -d <设备>` / integration_test：会重装 App、清掉 B 站登录态与
  GitHub 配置（`flutter_secure_storage`）以及本地偏好。

---

## 3. 模块地图（`app/lib/`）

### 3.1 `api/` —— 网络接口层

| 文件 | 职责 |
|------|------|
| `api/bilibili_api.dart` | **红线文件**。全部 B 站 REST 接口：view / 搜索 / playurl / 评论 / 动态 / 专栏 / 字幕 / 收藏 / 历史 / 稍后再看 / 关注 / 直播等；全局请求头、Cookie、WBI 签名调用也在这里 |
| `api/github_api.dart` | Gist 配置（`github_token` / `gist_id`，secure storage）+ 只读写 `whitelist.json` |
| `api/playview_api.dart` | App gRPC `PlayView` 取流（「免流兼容」开关打开时走这条，配 `kBiliAppUA`） |
| `api/live_danmaku_client.dart` | 直播弹幕 WebSocket：认证 / 心跳 / 断线重连 |
| `api/translate_api.dart` | 翻译接口与配置（`translate_base_url` / `translate_api_key` / `translate_model`） |
| `api/sherpa_audio.dart`、`api/sherpa_model.dart` | 实时转写：音频预处理、模型下载/解压 |
| `wbi/wbi_signer.dart` | WBI 签名（img_key/sub_key → mixinKey → w_rid），纯函数 |

### 3.2 `models/` —— 数据模型（关键几个）

| 文件 | 职责 |
|------|------|
| `models/whitelist_video.dart` | 白名单 v4 结构：`WhitelistData` / `WhitelistVideo` / `CollectionInfo` / `PageInfo`，含 v1→v4 兼容解析 |
| `models/book_source.dart` | legado 书源模型：search / detail / toc / content 四段规则 + 原始 JSON |
| `models/search_result.dart` | B 站搜索单条结果（只用于展示与「加入白名单」，不参与同步） |
| `models/schedule.dart` | 日程（`ScheduleData`，本机 `schedule:data_v1`） |
| `models/playlist_context.dart` | 播放页的「当前播放上下文」（来自哪个合集 / 分 P 序号等） |
| `models/danmaku.dart`、`danmaku_lanes.dart`、`danmaku_settings.dart` | 弹幕数据、轨道排版、显示设置 |
| `models/comment.dart`、`dynamic_item.dart`、`article.dart`、`subtitle.dart`、`upowner.dart`、`live_*.dart`、`video_shot.dart`、`update_info.dart`、`float_window_prefs.dart` | 各自模块的数据结构 |

### 3.3 `pages/` —— 页面

页面不是「一页一文件」那么干净：`playlist_page.dart` 是首页壳（PageView + 底部导航 +
个人页），几个大页面单文件几千行。

| 功能组 | 文件 |
|--------|------|
| 首页壳 / 合集 | `playlist_page.dart`（**5 页签顺序的唯一定义处**：`kTabCollections`=0 / `kTabRecommend`=1 / `kTabReading`=2 / `kTabHistory`=3 / `kTabPersonal`=4；个人页 = `WatchStatsPage` 的统计 + 设置区）、`collection_page.dart`（多层合集导航） |
| 播放 / 播放器 | `player_page.dart`（核心，约 1.2 万行：手势、倍速、弹幕、评论、取流、小窗、上报）、`live_player_page.dart`、`player/bili_dash_player.dart`（原生 DASH 播放器的 Dart 封装） |
| 搜索 | `search_page.dart`（视频 / 番剧 / 专栏等 Tab）、`watch_later_page.dart`、`favorites_page.dart` + `favorite_videos_page.dart`（收藏夹三级浏览）、`followings_import_page.dart` |
| UP 主 | `upowner_page.dart`（详情 / 合集 / 动态 / 专栏）、`followings_import_page.dart` |
| 信箱 | `inbox_page.dart`（白名单 UP 的新视频，卡片堆 + 热度榜） |
| 历史 / 统计 | `history_page.dart`、`daily_history_page.dart`、`watch_stats_page.dart`（**同时是个人页**：热力图 + 设置区） |
| 阅读（书源） | `reading_page.dart`（阅读页签）、`book_search_page.dart`、`book_detail_page.dart`、`book_reader_page.dart`、`book_source_page.dart`、`book_source_picker_page.dart` |
| 日程 | `schedule_screen.dart`（全屏页，入口在个人 → 设置 → 日程）、`schedule_page.dart`（日程本体） |
| 杂项 | `comment_page.dart`、`article_page.dart`、`dynamic_detail_page.dart`、`image_viewer_page.dart`、`offline_page.dart`、`update_dialog.dart`、`login_page.dart`（**红线**）、`cmcc_page.dart`（移动掌厅流量抓取） |

### 3.4 `services/` —— 业务服务（按用途分组）

| 分组 | 文件 |
|------|------|
| 白名单写入 | `whitelist_writer.dart`（构造 + 查重 + 写 Gist + 写本地缓存）、`whitelist_write_queue.dart`（**乐观写入**：本地立刻生效、远端排队）、`upowner_writer.dart`、`followings_auto_sync.dart`、`service_locator.dart` |
| 历史 / 统计 | `history_store.dart`、`watch_stats.dart`、`bili_history_api.dart`、`bili_history_reporter.dart`、`remote_watch_stats.dart`、`heat_curve.dart`（弹幕密度曲线） |
| 信箱 | `inbox_service.dart`、`inbox_heat.dart`、`inbox_handled_store.dart`、`inbox_sort_store.dart`、`inbox_card_style_store.dart` |
| 搜索 / 推荐 | `search_history_store.dart`、`recommend_service.dart`（兴趣标签 + 推荐池 + 30 分钟 TTL） |
| 播放辅助 | `stream_status_store.dart`、`video_shot_service.dart`（进度条预览雪碧图）、`last_episode_store.dart`、`danmaku_settings_store.dart`、`float_window_store.dart`、`keep_screen_on.dart`、`pip_service.dart`、`live_danmaku_service.dart`、`realtime_transcriber.dart`、`device_media.dart` |
| 阅读 / 书源 | `book_source_store.dart`（上限 200 个源）、`book_source_index_service.dart`、`book_search_service.dart`、`book_detail_service.dart`、`book_content_service.dart`、`bookshelf_store.dart`、`chapter_cache_store.dart`、`file_import_service.dart` |
| 存储 / 偏好 | `secure_store.dart`（flutter_secure_storage 统一封装）、`ui_prefs_store.dart`、`ui_copy_store.dart`、`theme_store.dart`、`collection_cover_store.dart`、`traffic_snapshot_store.dart`、`cmcc_session_store.dart` |
| 基础设施 | `diag_log.dart`（环形日志落盘 + 导出）、`crash_guard.dart`、`loading_copy.dart`、`update_service.dart` + `update_storage.dart` + `apk_installer.dart`、`share_service.dart`、`xlsx_reader.dart`、`gallery_saver.dart`、`image_pick_service.dart`、`schedule_import.dart`、`traffic_stats_service.dart`、`cmcc_*.dart`（掌厅抓取：AES / 驱动 / 注入脚本 / 解析 / 轮询 / 会话） |

### 3.5 `services/book_rule/` —— 书源规则引擎

| 文件 | 职责 |
|------|------|
| `selector.dart` | 选择器语法解析：`css:` / `xpath:` / `class.xxx` / `@text` / `@html` / `@href` / `@src` / `@attr:` / `regex:` / `##正则##替换` / `||` 回退链 |
| `js_builder.dart` | 选择器 → 待求值 JS 表达式（纯函数，可单测） |
| `legado_compat.dart` | legado 字段名映射 + `isJsSource`（`<js>` / `@js:` / 非占位符 `{{…}}`） |
| `rule_engine.dart` | 引擎接口 + WebView 实现；`_unwrapJsValue` 负责剥 `runJavaScriptReturningResult` 的多层返回值 |
| `engine_holder.dart` | 全 App 唯一引擎单例（一个实例一个 WebView 页面），求值必须串行 |
| `example_sources.dart` | 内置「标准电子书（示例）」书源 |

### 3.6 `widgets/` —— 通用组件

| 文件 | 职责 |
|------|------|
| `app_state_view.dart` | `AppStateView`（空/加载/错误三态）、`AppErrorView`、`AppLoadingHero`。**宿主有 `RefreshIndicator` 时 `scrollable: true`** |
| `cover_image.dart` | 封面图（**必须带防盗链 Referer + 浏览器 UA**），加载/失败占位 |
| `expandable_text.dart` | 按**行数**折叠的长文本（简介、评论、标题共用） |
| `video_tile.dart` | 视频列表项（封面 + 标题 + 时长 + UP + 发布时间 + 播放量 + 角标） |
| `app_block.dart`、`app_snack.dart`、`add_success_button.dart` | 块化容器、提示条、加入成功按钮 |
| `staggered_entrance.dart`、`dot_halftone.dart`、`dot_illustration.dart`、`smoke_silhouette.dart` | 装饰动效（测试环境由 `MotionControl` 自动关掉） |
| `collection_dialogs.dart`、`manage_panel.dart`、`collection_*` | 合集选择 / 管理面板 / 移动与排序 |
| `inbox_card_stack.dart`、`inbox_swipe_card.dart`、`inbox_card_styles.dart` | 信箱卡片堆与滑动手势 |
| `player` 相关 | `danmaku_overlay.dart`、`danmaku_settings_sheet.dart`、`floating_player_window.dart`、`stream_status_view.dart`、`heat_curve_bar.dart`、`swipe_action_box.dart` |
| 其他 | `history_tile.dart`、`upowner_tile.dart`、`upowner_badge.dart`、`season_tile.dart`、`stale_sync_banner.dart`、`traffic_panel.dart`、`charging_badge.dart`、`comment_list.dart`、`cover_hero.dart` |

### 3.7 `theme/` —— 设计 token 与配色

| 文件 | 职责 |
|------|------|
| `app_tokens.dart` | 间距 / 圆角 / 字号 / 动效节奏。**页面不写间距与圆角字面量** |
| `app_palette.dart` | `AppPalette` + `context.palette` 扩展。**页面不写颜色字面量** |
| `ink_recipes.dart` | 双墨配色配方表（用户可选的几套墨色） |
| `app_theme.dart` | `ThemeData` 组装与页面转场 |
| `app_motion.dart` | 内容入场动效参数（与 `app_tokens` 的交互反馈节奏分开） |
| `motion_control.dart` | 装饰性动画全局开关；**`flutter test` 下自动 false**，否则 `pumpAndSettle` 会挂死 |
| `route_names.dart` | `kPlayerRouteName = 'player'` 等；**值不可改**（`RouteObserver` 靠字符串对齐） |
| `theme_rebuild.dart` | 切换明暗后把已挂载元素全标脏（底材是模块级 getter，不是 InheritedWidget） |

### 3.8 `sync/`、`cache/`、`utils/`

- `sync/whitelist_source.dart`：`GistSource` → `LanSource` → `LocalFileSource` → `CacheSource` 回退链
- `sync/whitelist_freshness.dart`：数据新鲜度门禁（v2.43.0）
- `cache/download_manager.dart`：离线缓存下载 / 索引 / 占用统计；`cache/playback_progress.dart`：按 `(bvid,page)` 存播放位置
- `utils/`：`bili_html.dart`、`import_parser.dart`（BV 号解析）、`book_source_import.dart`、`log_redact.dart`（日志脱敏）、`share_text.dart`、`relative_time.dart`、`sentence_splitter.dart`、`comment_links.dart`、`clipboard_link.dart`

### 3.9 原生（Android）

`app/android/app/src/main/kotlin/com/biliwhitelist/bili_whitelist_app/`

`MainActivity.kt` **手动注册**本项目自带的原生插件（依赖包仍由 `GeneratedPluginRegistrant` 注册），加播放插件：

| 文件 | 职责 |
|------|------|
| `MainActivity.kt` | `configureFlutterEngine` 里逐个注册下面的插件；PIP 的 `onPictureInPictureModeChanged` 必须在这里接 |
| `BiliDashPlayerPlugin.kt` / `DashExoPlayer.kt` / `MediaController.kt` / `DashMediaNotification.kt` | DASH 双流（video/audio 各一条 m4s）播放、倍速/字幕轨、音量与亮度、媒体通知卡片 |
| `ApkInstaller.kt` | 应用内更新：触发系统 APK 安装 |
| `GalleryController.kt` / `ImagePickPlugin.kt` / `FilePickerPlugin.kt` / `ScheduleImportPlugin.kt` | 系统相册保存、相册选图、SAF 选文本文件（v2.70 书源导入）、SAF 选 Excel |
| `TrafficStatsPlugin.kt` | `NetworkStatsManager` 移动数据统计 + 使用情况访问引导 |
| `KeepScreenOnPlugin.kt` | `FLAG_KEEP_SCREEN_ON`（不用 WakeLock） |
| `SharePlugin.kt` | 系统分享面板（文本 + 文件） |
| `PipPlugin.kt` | 系统画中画 + 进出小窗事件回推 |
| `DiagInfoPlugin.kt` | 机型 / Android 版本（导出日志的 `meta.txt`） |
| `NativeCrashRecorder.kt` | JVM 未捕获异常落盘，下次启动合入 diag 日志 |

---

## 4. 红线 / 不变量

违反这几条会直接坏功能，不是风格问题。

1. **`api/bilibili_api.dart` 的请求头、图片头、弹幕 WS、`login_page.dart` 不改**。
   可以新增方法，但不要动既有头的组合（B 站防盗链与风控实测过：非浏览器 UA / 缺 Referer
   一律 403 或 -412）。
2. **这几个文件由发布脚本 / 既有流程维护，手改会打架**：
   `CHANGELOG.md`、`app/pubspec.yaml` 的 `version:`（构建号由 `release_all.sh` 自增）、
   `app/tools/` 下的发布脚本、`amotv.user.js`、`whitelist.py`。
   要改代码逻辑请先确认不是发布脚本生成的段落。
3. **不随意新增 Dart 依赖**。当前策略：优先用已有的 `webview_flutter` / `dio` /
   `shared_preferences` / `path_provider` / `flutter_secure_storage` / `video_player`。
   新增依赖要说明体积、维护状态、能否用现有能力替代。
4. **页面颜色一律 `context.palette`，间距 / 圆角 / 动效用 `app_tokens.dart`**。
   页面里不写 `Colors.xxx` / `Color(0x...)` 字面量（没有 lint 强制，靠 review 与本约束）。
5. **空 / 加载 / 错误态用 `AppStateView` / `AppErrorView`**；外层有 `RefreshIndicator`
   时必须 `scrollable: true`，否则下拉手势收不到。
6. **Android 15 edge-to-edge**：底部 / 顶部容器要「背景铺满 + 内容按
   `MediaQuery.viewPadding` 内缩」，不能只包 `SafeArea`（会把背景一起缩短，系统栏位置
   露出硬边）。用 `viewPadding` 不用 `padding`（键盘弹出时 `padding` 归零）。
7. **既有测试断言不许删或放宽**。只有明确的设计契约变更才能改，并在提交信息里写清原因。

---

## 5. 本地存储 key 一览

`shared_preferences`（非敏感）。key 都是从代码里 grep 出来的原样字符串。

| key | 内容 | 上限 / 裁剪 |
|-----|------|-------------|
| `history_store:entries` | 观看历史整表（一条 JSON） | `maxEntries = 1000`，按 watchedAt 倒序裁最早 |
| `history_store:last_sync_at` | 上次与 B 站历史同步时间 | — |
| `watch_stats:days` | 每日观看秒数 | `maxDays = 400` 天；单次 tick 上限 5000ms |
| `playback_progress:<bvid>_<page>` | 该分 P 的播放位置（毫秒） | 每个 (bvid,page) 独立 key |
| `last_episode:map` | 「上次看到第几 P」整表 | `maxEntries = 200`，按 `updatedAt` 裁最久未看 |
| `search_history:keywords` | 搜索关键词列表 | `maxEntries = 20` |
| `recommend:tag_cache` | bvid → 标签缓存（含 `__order` 写入顺序） | `kMaxTagCacheEntries = 800`，最久未写入淘汰 |
| `recommend:last_fetch_at` | 上次算推荐的时间 | 只做诊断 / 跨进程节流；内存 TTL 30 分钟单独判定 |
| `inbox:upowner:<mid>:unseen` | 每个 UP 主的未读视频 | 每 UP 只留最新 5 条（`inbox_service` 内部） |
| `inbox:meta:total_unseen` / `last_check_at` / `checked_mids` / `rotate_cursor` / `known_mids` | 信箱扫描元数据 | — |
| `inbox:handled_bvids` | 已滑过的 bvid | `maxEntries = 500` |
| `reader:sources` | 书源列表（单 key 整份 JSON，**不进 Gist**） | 上限 200 个源 |
| `reader:index_urls` | 索引下载地址（每行一个 .json） | — |
| `reader:books` | 书架 | `maxBooks = 500` |
| `reader:progress` | 阅读进度 | `maxProgress = 100` |
| `reader:settings` | 阅读设置（字号 / 行高 / 底色） | — |
| `schedule:data_v1` | 日程整表 | — |
| `ui:theme_id` / `ui:theme_mode` | 配色配方 id / 明暗模式 | 只存 id，色值在 `ink_recipes.dart` |
| `ui:inbox_card_style_id` / `ui:inbox_sort_mode` | 信箱卡片样式 / 排序偏好 | 只存 id |
| `ui:show_tips` / `ui:write_actions` / `ui:history_write` / `ui:stream_compat` / `ui:keep_screen_on` | 各类开关 | — |
| `ui:fav_folder_id` / `ui:preferred_quality` | 默认收藏夹、默认清晰度 | — |
| `ui:clipboard_open_enabled` / `ui:clipboard_open_last_url` | 冷启动读剪贴板开关 / 上次处理的链接 | — |
| `ui_copy:overrides` | 用户改过的空态/错误态文案 | 只存被改过的条目 |
| `stream:last_source` / `last_quality` / `last_cookie` / `last_at` | 最近一次取流的实测事实 | — |
| `player:float_window` | 应用内小窗状态 | — |
| `danmaku:settings` | 弹幕显示设置 | — |
| `traffic:carrier_snapshots` | 运营商流量快照（算差值） | `maxSnapshots = 8`，只留最近几条 |
| `pc_watch_stats:state` | PC 端观看时长估算 | — |
| `collection_covers` | 合集路径 → 本机封面文件名映射 | — |
| `cmcc:session` | 掌厅抓取的非敏感状态（登录态 / 尾号 / 读数） | 手机号全号不进这里 |
| `update:last_check_at` | 上次检查更新（24h 节流） | — |

`flutter_secure_storage`（敏感，**别往 prefs 搬**）：
`bili_sessdata` / `bili_jct` / `bili_refresh_token`（登录态）、`github_token` / `gist_id`、
`translate_api_key`、`cmcc_phone`。

本地文件 / 其他：离线缓存走 `path_provider`（`DownloadManager`），诊断日志 `logs/diag-YYYYMMDD.log`
（512KB × 4 轮转，目录上限 5MB），章节正文缓存、合集自定义封面等也在应用支持目录。

---

## 6. 已知坑（踩过的，别再踩）

1. **`runJavaScriptReturningResult` 返回值层数随平台变**（Android 两层 / iOS 一层）。
   必须按类型循环剥，设上限（`rule_engine.dart` 的 `_unwrapJsValue(maxLayers: 4)`）；
   正文以 `<` 开头时**不能**当 JSON 解，直接放行。v2.69.0 的「正文显示成 JSON 转义串」就是只剥一层。
2. **`flutter test` 宿主没有 `path_provider` 实现，通道会永不返回**。
   任何碰 `getApplicationSupportDirectory()` 的代码必须有超时或测试早退
   （范例：`diag_log.dart` 的 2s `.timeout(...)`、`chapter_cache_store.dart` 的 `rootTimeout`
   与 `rootDirOverride`）。写新的落盘逻辑时先想「测试环境怎么走」。
3. **推荐页 TTL 30 分钟内直接返回内存结果**，所以「刚看完的视频要等 TTL 过期才消失」，
   这是设计行为。`force`（下拉刷新 / 换一批）才绕过。
4. **书源规则引擎一个实例一个 WebView 页面，求值必须串行**。宿主用
   `Offstage(offstage: true)` 包在 `SizedBox(width: 1, height: 1)` 里——尺寸不能为 0，
   否则 WebView 不布局、JS 不执行（见 `book_search_page.dart` 的 `_hiddenHost`）。
5. **`@js` 书源不支持**：legado 的 `java.ajax` 是同步调用，浏览器里同步 XHR 被 CORS 拦。
   `legado_compat.isJsSource` 会判定并在 UI 标「需要 JS 规则，暂不支持」。
6. **发布脚本的 `git push` 可能被本机代理吞掉**（脚本用 `if` 兜住，仍然 exit 0）。
   发布后必须手工核验：`git ls-remote` 看远端 commit，`gh release view <tag>` 看 asset
   `state=uploaded`。
7. **测试环境下装饰动画默认关闭**（`MotionControl`）。要测动画本身得显式
   `MotionControl.enabled = true`，用完 `reset()`；否则 `pumpAndSettle` 超时。
8. **不要用 `adb shell input` 做不可逆操作**（滑删 / 拖拽），坐标会随列表滚动漂移。
   模拟器上覆盖安装用 `adb install -r`，绝不 `uninstall`——登录态在 secure storage 里。

---

## 7. 测试与门禁

- 测试目录：`app/test/`，共 252 个 `*_test.dart`；`test/live_danmaku_fakes.dart` 是辅助文件
  （没有 `main()`），门禁会自动跳过。
- 当前基线：**252 个文件、6 批、通过用例数见下**（v2.70.0 实跑）：

| 项 | 结果 |
|----|------|
| `flutter analyze` | 0 issue（约 30s） |
| `flutter test` 分批 | 6 批全部通过，合计 **3816** 个用例 |
| `flutter build apk --debug` | 通过 |

- 分层策略：
  - **开发中**：`bash app/tools/gate.sh --quick test/你改的_test.dart`（analyze + 目标文件）
  - **提交前 / 发版前**：`bash app/tools/gate.sh`（全量 + 构建）
- `gate.sh` 的行为：每批 ≤45 个测试文件；失败立刻退出并打印「哪一步 / 哪一批 / 出错行 +
  日志末尾 30 行」；最后一行 `GATE OK` 或 `GATE FAILED`；临时文件在 `mktemp -d` 里，
  `trap` 清理。
- **永远不要**：`flutter test -d <设备>`、在模拟器上跑 `integration_test`（会重装清数据）。

---

## 8. 版本变更记录（最近 4 个版本）

| 版本 | 主题 | 关键文件 |
|------|------|----------|
| v2.70.0 | 阅读模块收尾：底栏 edge-to-edge 修复（`viewPadding` 内缩，不是只包 SafeArea）；书源从本地文件导入（SAF，8MB 上限，BOM 处理）；书源索引下载 + 选择页（2486 个去重源，上限 200，标出 `@js` 不支持）；书源名清洗；「清空书源」 | `reading_page` / `book_detail_page` / `book_search_page` / `book_source_page` / `book_source_picker_page`、`file_import_service`、`book_source_index_service`、`FilePickerPlugin.kt` |
| v2.69.0 | 底栏「日程」换成「阅读」（书源驱动阅读器）；多源搜索（并发 4、单源 20s）、分组/合并视图；详情目录、正文阅读、书架；规则四段 + 选择器语法；示例书源；修 `runJavaScriptReturningResult` 多层剥壳 | `models/book_source`、`services/book_rule/*`、`book_*_service`、`book_*_page`、`bookshelf_store`、`chapter_cache_store`、`playlist_page`（页签下标） |
| v2.68.0 | 底栏「UP 主」换成「推荐」：从最近 20 个看过的视频拉标签，14 天半衰 × 完播率打分，取前 5 标签；热力球（黄金角螺旋）；交叉区；推荐池 60 条，已看剔除；30 分钟 TTL；UP 主管理迁到个人 → 设置 | `recommend_service`、`recommend_page`、`playlist_page`、`watch_stats_page` |
| v2.67.0 | 诊断基础设施：`debugPrint` 接管 + 环形落盘（512KB×4，目录 5MB，攒批 64 条/2s，去重）；崩溃四入口；原生崩溃碎片；一键导出 zip；落盘前脱敏（SESSDATA / token / 手机号 / 搜索词） | `diag_log`、`crash_guard`、`main.dart`、`NativeCrashRecorder.kt`、`DiagInfoPlugin.kt` |

更早的版本看 `CHANGELOG.md`（只读，不要手改）。

---

## 9. 给子智能体的工作流

1. **先读这份文件**（尤其第 3 节模块地图、第 4 节红线、第 6 节已知坑），不要一上来全库 grep。
2. 按模块地图**只读相关文件**；需要确认事实时用 `grep -n` 定位，不要重复调研已写在这里的事实。
3. 小步改，改完先跑 `bash app/tools/gate.sh --quick test/相关_test.dart`。
4. 涉及多个模块 / 发版前，跑 `bash app/tools/gate.sh`（全量，本机实测约 9 分钟）。
5. 交付时说明：改了哪些文件、为什么、跑了什么命令、结果如何。**没跑过的检查不要写成跑过。**
6. 如果发现这份文档与代码不一致（路径、常量、key 变了），**顺手改正文档**；如果只是
   新增模块，补一行到模块地图。
