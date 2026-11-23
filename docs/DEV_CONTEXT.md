# amoTV 开发上下文（DEV_CONTEXT）

> **给接手的人 / 子智能体**：先读这份文件，再动手。它记录的是「现在代码长什么样」，
> 不是设计愿景。改完代码如果动了模块职责、红线、存储 key，**顺手改这里**
> （这份文档随开发维护；`CHANGELOG.md` 归发布脚本，别手改）。
>
> 最近一次对齐：v2.75.0（2026-11-23，网络书源 GBK 解码）。

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

# 发版前全量门禁：analyze + 271 个测试文件分 7 批 + build apk --debug
bash app/tools/gate.sh
bash app/tools/gate.sh --no-build               # 不构建 APK

# 单跑一个测试（不经过门禁）
cd app && flutter test test/history_store_test.dart

# 发布（版本自增 → CHANGELOG → 安全扫描 → commit → push commit → 打 tag 并 push
#       → 构建 → gh release create → 自检远端 main/tag/asset）
bash app/tools/release_all.sh 2.71.0 --notes C:/Users/HP/.kimi-tmp/v2710.md
```

- 门禁脚本：`app/tools/gate.sh`（见第 7 节）
- 发布脚本：`app/tools/release_all.sh`（文件头有全部开关：`--all-abis` / `--with-screenshots` / `--no-push` / `--dry-run`）
- **push 走 SSH over 443**（`AMOTV_PUSH_REMOTE` 可覆盖，默认
  `ssh://git@ssh.github.com:443/Tukist/bili-whitelist.git`，不读 `git remote get-url origin`）；
  push 失败**立刻中止**并打印手工补救命令（不会继续跑到「发布完成」）；脚本末尾**自检**
  远端 `main`/tag 是否等于本地 HEAD、Release asset 是否 `state=uploaded` 且大小一致，不符即非零退出。
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
| 阅读（书源 / 本地书） | `reading_page.dart`（阅读页签；v2.72.0 起顶部还有「导入本地书」，本地书点进直接读）、`book_search_page.dart`、`book_detail_page.dart`（**只服务网络书**：本地书不会出现在搜索里，书架点本地书也不经详情页）、`book_reader_page.dart`（网络书与本地书共用：正文来源走 `ChapterContentLoader`；**三种呈现**：滚动 `SingleChildScrollView`+`SelectableText` / 左右翻页 `PageView`+`book_paginator` / **图片页** `Image.file`（PDF，v2.73.0，强制逐页滚动、按钮叫「上一页 / 下一页」））、`book_source_page.dart`、`book_source_picker_page.dart` |
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
| 阅读 / 书源 | `book_source_store.dart`（上限 200 个源）、`book_source_health_service.dart`（**v2.73.0 新建**：书源可用性检测 —— `probe` 对一个源**真搜一次**并归类成 `ok` / `noResult` / `blocked` / `networkError` / `unsupportedJs` / `badRule`，`probeAll` 并发 2 + 可取消 + 进度回调，结果存 `reader:source_health`；抓取逻辑**全部复用** `BookSearchService`，本文件只做编排与归类；`classifyGroup` / `summarizeSearchFailures` 是纯函数）、`book_source_index_service.dart`、`book_search_service.dart`、`book_detail_service.dart`、`book_content_service.dart`（`restoreParagraphs` 是正文清洗的**唯一**实现，EPUB 也复用它；v2.73.0 `BookContentResult` 加 `imagePath`，非空 = 图片页）、`bookshelf_store.dart`（书架 / 进度 / 阅读设置，`reader:*` 三个 key 都在这里）、`chapter_cache_store.dart`、`file_import_service.dart`、`book_paginator.dart`（**v2.72.0**：左右翻页的分页纯函数 `paginateText` + `pageText/pageStart/pageEnd`，不碰 Widget 树，可单测）、`chapter_content_loader.dart`（**v2.72.0**：`ChapterContentLoader.load(int)` 抽象 + `NetworkChapterLoader`，阅读页正文来源的唯一入口）、`local_chapter_loader.dart`（**v2.72.0**：`LocalChapterLoader` 读本地文件、`localBookToc` 把 manifest 拼成 `TocChapter`，不发网络；v2.73.0 起 PDF 书走 `pageImagePath` 返回图片页）、`local_book_parser.dart`（**v2.73.0**：`LocalBookParser` 抽象 + `TxtBookParser` / `EpubBookParser` + `LocalBookParsers.dispatcher`，统一产出 `ParsedLocalBook`；EPUB 用**手写极简 XML 扫描**，理由见文件头；加 `PdfBookParser`（实现 `FileBasedLocalBookParser`，只读页数、每页一章 `imagePage: true`）+ `ParsedChapter.imagePage` / `ParsedLocalBook.sourcePath` / `pageWidth` / `pageHeight`；**v2.74.0 加 `MobiBookParser`**：PalmDB → PalmDOC LZ77 → UTF-8/cp1252 → HTML，按 `<mbp:pagebreak>` + `<h1>`–`<h3>` 启发式分章，退化到 `splitTxtChapters`；HUFF/CDIC 与 AZW3/KF8 明确拒绝）、`pdf_renderer_bridge.dart`（**v2.73.0**：`PdfRendererBridge` 抽象 + `NativePdfRenderer` 包 `bili_whitelist/pdf` 通道，错误码→中文只在这里做；测试注入假实现）、`pdf_cache_policy.dart`（**v2.73.0**：纯函数 `planPdfCacheEviction`，300MB / 每本 500 页，按 mtime 最旧先删，`keepPath` 永不被删）、`local_book_store.dart`（**v2.72.0 新建 / v2.73.0 升 schema 2 + 支持 PDF**：本地书落盘 `<support>/reader/local/<id>/manifest.json` + `chapters/N.txt` + 可选封面 + `book.pdf`，含 v1 惰性迁移；`local:<id>` 伪 URL 是全项目识别本地书的唯一键；`pageImagePath(id,index)` 惰性渲染 + 缓存淘汰）、`local_book_import_service.dart`（**v2.72.0 新建 / v2.73.0 按格式分派 + 文件路径分派（PDF）**：选文件 → 读字节（PDF 直接给路径）→ dispatcher 解析 → 落盘 → 上书架的编排，错误文案只在这里） |
| 存储 / 偏好 | `secure_store.dart`（flutter_secure_storage 统一封装）、`ui_prefs_store.dart`、`ui_copy_store.dart`、`theme_store.dart`、`collection_cover_store.dart`、`traffic_snapshot_store.dart`、`cmcc_session_store.dart` |
| 基础设施 | `diag_log.dart`（环形日志落盘 + 导出）、`crash_guard.dart`、`loading_copy.dart`、`update_service.dart` + `update_storage.dart` + `apk_installer.dart`、`share_service.dart`、`xlsx_reader.dart`、`gallery_saver.dart`、`image_pick_service.dart`、`schedule_import.dart`、`traffic_stats_service.dart`、`cmcc_*.dart`（掌厅抓取：AES / 驱动 / 注入脚本 / 解析 / 轮询 / 会话） |

### 3.5 `services/book_rule/` —— 书源规则引擎

| 文件 | 职责 |
|------|------|
| `selector.dart` | 选择器语法解析：`css:` / `xpath:` / `class.xxx` / `@text` / `@html` / `@href` / `@src` / `@attr:` / `regex:` / `##正则##替换` / `||` 回退链 |
| `js_builder.dart` | 选择器 → 待求值 JS 表达式（纯函数，可单测） |
| `legado_compat.dart` | legado 字段名映射 + `isJsSource`（`<js>` / `@js:` / 非占位符 `{{…}}`） |
| `rule_engine.dart` | 引擎接口 + WebView 实现；`_unwrapJsValue` 负责剥 `runJavaScriptReturningResult` 的多层返回值；**v2.75.0 起 `fetchHtml` 的字节解码交给 `utils/text_decoding.dart`**（响应头 charset > 书源声明 > 自动判定），结果带出 `lastDecodeEncoding`（实际编码）与 `lastDecodeWarning`（人话告警）；`parseHeaderCharset` / `decodeWarningFor` / `decodeNoteFor` 是这段判定的纯函数入口。**controller 懒建**（`fetchHtml` 不需要 WebView），所以单测能注入假 Dio 直接验 GBK 字节；`loadHtmlString` 求值仍走同一个串行队列 |
| `engine_holder.dart` | 全 App 唯一引擎单例（一个实例一个 WebView 页面），求值必须串行 |
| `example_sources.dart` | **内置书源清单**（常量名仍是 `kExampleBookSources`）：维基文库（中文经典）+ 标准电子书（英文经典）。每条的搜索 / 详情 / 目录 / 正文选择器都是**先 curl 真页、再写规则**（证据写在文件头注释里）；改动前必须重新抓页面 |

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
- `utils/` 里的**纯函数**（v2.72.0，本地书导入）：
  - `text_decoding.dart`：`decodeBytes` / `decodeTextBytes` / `looksLikeGbk` / `looksLikeUtf8` /
    `isGbkCharset` / `replacementRatio`。**本地书导入与网络书源抓取共用同一套**
    （v2.75.0 起网络链路也走它，不再各写一份）。判定顺序 BOM → UTF-16（提示 /
    嗅探）→ **严格 UTF-8** → UTF-8 只坏 ≤1% 字节 → GBK → 兜底（UTF-8 宽松 vs
    GBK 取坏字符少的那个；提示是 gbk 时优先给 GBK）。
    严格 UTF-8 排在「声明 gbk」之前是关键：中文站大量声明 gbk 实际吐 UTF-8。
    GBK 解码用 `Uint16List` + `String.fromCharCodes`，5MB 文本不到 1 秒。
  - `gbk_table.dart`：**生成物，勿手改**（`app/tools/gen_gbk_table.py` 生成，
    `python tools/gen_gbk_table.py --check` 可校验是否最新）。24066 = 126×191 项，
    索引 `(lead-0x81)*191 + (trail-0x40)`，未映射位置是 U+FFFD。
  - `txt_chapter_splitter.dart`：`splitTxtChapters` / `isChapterTitleLine`。
    逐行认「第X章/回/节/卷/集」「楔子/序章/…/番外」「Chapter N」「CHAPTER 罗马数字」
    （行首允许空白，行 ≤ 40 字）；一个标题都没有时按 3000 字分块（「第 N 节」）；
    返回的偏移**连续覆盖全文、没有空段**，超过 5000 章就合并相邻章。
  - `mobi_reader.dart`（**v2.74.0 新建**，纯 Dart、不依赖 Flutter）：MOBI/AZW 的
    字节级工具 —— `PdbFile.parse`（PalmDB 头 + 记录表，任何越界都抛可读异常）、
    `parseMobiHeader`（PalmDOC 头 + MOBI 头：压缩/正文长度/记录数/编码/版本）、
    `palmdocDecompress`（LZ77，截断 / 回溯距离 0 或越界 / 解出超长都抛异常）、
    `trimTrailingEntries`（记录尾部附加数据，反向变长整数）、
    `exthValue`（作者 100 / 书名 503，坏了返回 null 而不是让整本失败）、
    `decodeCp1252`（0x80–0x9F 单独一张 32 项表，**不能拿 latin1 顶替**）。

### 3.9 原生（Android）

`app/android/app/src/main/kotlin/com/biliwhitelist/bili_whitelist_app/`

`MainActivity.kt` **手动注册**本项目自带的原生插件（依赖包仍由 `GeneratedPluginRegistrant` 注册），加播放插件：

| 文件 | 职责 |
|------|------|
| `MainActivity.kt` | `configureFlutterEngine` 里逐个注册下面的插件；PIP 的 `onPictureInPictureModeChanged` 必须在这里接 |
| `BiliDashPlayerPlugin.kt` / `DashExoPlayer.kt` / `MediaController.kt` / `DashMediaNotification.kt` | DASH 双流（video/audio 各一条 m4s）播放、倍速/字幕轨、音量与亮度、媒体通知卡片 |
| `ApkInstaller.kt` | 应用内更新：触发系统 APK 安装 |
| `GalleryController.kt` / `ImagePickPlugin.kt` / `FilePickerPlugin.kt` / `ScheduleImportPlugin.kt` | 系统相册保存、相册选图、SAF 选文件（`pickTextFile` 读成 UTF-8 字符串回传，8MB，v2.70 书源导入；`pickBookFile` **流式拷到 `<filesDir>/reader/incoming/` 只回路径**，100MB，v2.72 本地书导入，v2.73.0 的 MIME 加 `application/pdf`，v2.74.0 再加 `application/x-mobipocket-ebook` 与 `application/vnd.amazon.ebook`（MIME→扩展名兜底认 `mobi` / `azw3`），requestCode 9050/9051）、SAF 选 Excel |
| `PdfRenderPlugin.kt` | **v2.73.0**：系统 `PdfRenderer` 把 PDF 一页渲染成 PNG 落盘（`<filesDir>/reader/pdfcache/<书id>/<页号>@<宽>.png`），通道 `bili_whitelist/pdf`；`openPdf` / `renderCover` / `renderPage` / `clearCache` / `cacheFiles` / `deleteCacheFiles`。**单线程串行**（PdfRenderer 不能并发）+ `openPage/close` 成对；位图不回传只回路径 |
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
| `reader:source_health` | 书源可用性检测结果：`{源名小写: {status, at, count, message, keyword}}`（**不进 Gist**） | `kSourceHealthMaxEntries = 200`，按 `at` 裁最旧 |
| `reader:index_urls` | 索引下载地址（每行一个 .json） | — |
| `reader:books` | 书架 | `maxBooks = 500` |
| `reader:progress` | 阅读进度（`chapterIndex` / `chapterName` / `chapterUrl` / `scrollOffset`（滚动模式）/ `pageIndex`（分页模式，v2.72.0）/ `updatedAt`） | `maxProgress = 100` |
| `reader:settings` | 阅读设置：`fontSize`（12–32，默认 18）/ `lineHeight`（1.2–2.6，默认 1.8）/ `theme`（`auto`/`paper`/`dark`，默认 `auto`）/ `pageMode`（`scroll` 默认 / `paged`，v2.72.0；非法值与缺失一律回落 `scroll`） | — |
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

### 书源（网络书）：内置清单与可用性检测（v2.73.0）

**内置书源**（`services/book_rule/example_sources.dart` 的 `kExampleBookSources`，
书源管理页右上角「添加内置书源」一键导入；**同名源不覆盖**，只补缺的那几条）：

| 源 | 站点 | 搜索 | 目录 | 正文 |
|---|---|---|---|---|
| 维基文库（中文经典） | `zh.wikisource.org` | `/w/index.php?search={{key}}&ns0=1&fulltext=1`；`ul.mw-search-results > li.mw-search-result`，书名/链接用 `div.mw-search-result-heading a:not([title*="/"])` 排掉章节子页面 | 目录就在图书页：`ul li a[title*="/"]`（子页面链接的 title 一定含 `/`） | `div.mw-content-ltr.mw-parser-output`（**不能只写 `.mw-parser-output`**，页顶指示器 div 也用这个 class），删 `.ws-header` / `.ws-footer` / `sup.reference` / `ol.references` / `div.licenseContainer` / `div.licensetpl` |
| 标准电子书（示例） | `standardebooks.org` | `/ebooks?query={{key}}`；`ol.ebooks-list > li` | 详情页地址 + `/text` 的 `nav#toc a[href*="chapter"]` | `main section`，删章首 `hgroup` / `h2` |

**评估过但没收录**：Project Gutenberg（实测整站 503 维护页）、ctext.org
（Cloudflare Turnstile 验证页）、en.wikisource（版本页没有子页面目录，英文已有
Standard Ebooks 覆盖）。盗版 / 聚合爬站一律不接。

**本机实测记录（2026-11-23，模拟器 bili_test）**：标准电子书能搜、能读（`alice`
→ 12 条 → 详情 → 正文，检测显示「可用 12 条」）；**维基文库在这台机器的网络上
不可用** —— `nslookup zh.wikisource.org` 被解析到 `205.164.50.x`（校园网 DNS 劫持，
`en.wikisource.org` / `wikisource.org` 同样），TLS 是中间人证书，App 侧报
`HandshakeException`，检测结果「连不上」。这不是源写错了（`curl -k` 能拿到真实
页面），换网络（手机流量 / 代理）就会好 —— 排查时先分清「站点挂了」与「本机网络拦了」。

**检测状态**（`BookSourceHealthService`，结果存 `reader:source_health`）：

| 状态 | 含义 | 判据 |
|---|---|---|
| `ok` | 可用，`count` = 命中条数 | 分组 ok |
| `noResult` | 通了但 0 条 | 分组 noResult（或 `empty` 类错误） |
| `blocked` | 被拦 | 401/403/407/412/429/451，或 HTTP 200 的验证页（Cloudflare / Turnstile 特征串；`noResult` 时**多抓一次**复核） |
| `networkError` | 连不上 | 超时 / DNS / 连接失败 / 其它 5xx |
| `unsupportedJs` | 需 JS，本版跑不了 | `usesJs` 判定，**不发请求** |
| `badRule` | 规则本身跑不起来 | 地址拼不出、没配列表规则、JSONPath、`&&` 组合 |

- 管理页每行有角标（绿「可用 N 条」/ 灰「没结果」/ 红「被拦」/ 红「连不上」/
  黄「需 JS」/ 黄「规则坏」/ 灰「未检测」），长按菜单「检测这个源」；AppBar
  溢出菜单「检测全部书源（较慢）」只测 `enabled && !usesJs`（其余在进度框里
  说明跳过了几个），并发 **2**、可取消。
- 搜索页分组标题右侧显示该源上次检测结果；某源 0 条时用一行小字区分
  「这个源没搜到」与「这个源可能已失效（上次检测：被拦）」；整页 0 条时区分
  「所有源都没搜到」与「所有源都失败」（后者把原因归类成「3 个源连不上、2 个被拦」）。
- 检测结果**只在本机**，不进 Gist；「清空书源」会连带清掉（免得同名源复用时
  带着旧状态）。
- 探测复用 `BookSearchService`（不复制抓取代码）；为此 `RuleEngineException`
  加了 `statusCode`、`BookSearchGroup` 加了 `httpStatus` / `errorKind` 两个
  可空字段（纯增量，既有调用点不用改）。
- `noResult` 时会**换一门语言的关键词再搜一次**（默认「历史」→ 备选 `love`）：
  否则英文站点会稳定显示「没结果」，被当成坏源。仍 0 条才判 `noResult`，
  之后才做验证页复核。

**网络抓取的编码判定（v2.75.0）**

网络书一直是「搜得到、点进去满屏 `��`」：`fetchHtml` 拿 `ResponseType.bytes` 后
一律 `utf8.decode(allowMalformed: true)`，而中文书站大量是 GBK。现在字节交给
`utils/text_decoding.dart`（与本地 TXT 导入同一套，**没有第二份判定**）：

| 顺序 | 判据 | 说明 |
|---|---|---|
| 1 | BOM / UTF-16 | `EF BB BF`、`FF FE`、`FE FF`；无 BOM 的 UTF-16 靠零字节分布嗅探 |
| 2 | **严格 UTF-8** | `allowMalformed: false` 解得通就是 UTF-8 —— **排在「声明 gbk」之前** |
| 3 | UTF-8 只坏 ≤1% 字节 | 按字节截断的页面仍算 UTF-8，不整页转 GBK |
| 4 | GBK 码表 | 到这一步只剩 GBK 一种可能；提示只在「两边都解不通」的兜底里起作用（是 gbk 就优先给 GBK） |
| 5 | 兜底 | 两边都是 U+FFFD 时取坏字符少的 |

- **hint 优先级：HTTP 响应头的 `charset` > 书源的 `charset` 字段 > 自动判定**。
  响应头是站点在这次响应里自己说的，比书源作者手抄的声明更贴近事实。
- **为什么很多源声明是错的**：站点改版只改输出没改 `<meta>` / `content-type`，
  「声明 gbk 实际 utf-8」比反过来更常见。所以声明只当提示，不当命令；声明写错
  （任一边）时自动判定会纠正，纠正完**不报警**（结果是好的）。
- **告警只有两句**（`decodeWarningFor`，文案是常量 `kDecodeGbkGuessWarning` /
  `kDecodeGarbledWarning`）：「这个书源疑似 GBK，已按 GBK 解码」（站点没声明、
  我们猜对了，是**好消息**）与「解码后仍有乱码，正文可能不完整」（解完还剩一堆
  U+FFFD，多半是繁中 / 日文等本版没接的编码）。站点自己声明了 GBK 不提示 ——
  声明对了是正常情况。
- **带出去的三个事实**：引擎上的 `lastDecodeEncoding` / `lastDecodeWarning`，
  以及 `BookSearchGroup.decodeNote`（`decodeNoteFor` 压成「编码：GBK」/
  「解码有乱码」/「编码：GBK（仍有乱码）」；**「疑似 GBK」不算乱码**）。
  两个引擎字段都只记**最近一次**抓取，所以多页抓取必须**每页抓完当场收下**
  （正文 / 目录服务都是这么做的，后一页成功不会盖掉前一页的告警）。
- UI：搜索页**分组标题下**一行小字（每源一次，不逐条）；详情页复用
  `BookDetailResult.warning`；阅读页在正文末尾（滚动模式一段小字、分页模式并进
  最后一页）；书源管理页每行一行「编码：GBK / 编码：自动」。
- `charsetLabelOf`：`gbk` / `gb2312` / `gb18030` / `cp936` → 显示 `GBK`；
  **`utf-8` 与没写都显示「自动」**（模型默认值就是 utf-8，无法区分「显式写了
  utf-8」与「没写」，而两者在判定上行为完全一样）；其它名字原样大写。
- legado（开源阅读）的书源**没有 charset 字段**（它自己按 BOM / 字节分布嗅探），
  所以 `fromLegado` 里的 `bookSourceCharset` 读取只是兼容少数第三方导出，
  正常 legado 源一律自动判定。

**本机实测（2026-11-23，模拟器 `bili_test`，debug 包 `adb install -r`）**：宿主机起
一个只吐 GBK 字节、`Content-Type: text/html`（**不带 charset**）的本地页面
（`10.0.2.2:8899`，脚本 `C:/Users/HP/.kimi-tmp/gbk_test_server.py`，不入库），
书源声明 `utf-8`、搜索地址走绝对 `http://`（`normalizeUrl` 会把「与 baseUrl 同站
的 http」升级成 https，所以把 baseUrl 写成 `http://x.invalid` 绕开这一步）。
搜索 → 分组标题「GbkLocal · 2 条」+ 一行「编码：GBK」+ 书名 **斗罗大陆 / 吞噬星空**
正常显示（以前这里是一屏 `��`）。取证图 `docs/screenshots/v2.75.0/h_gbk_search_emulator.png`
与书源页的「编码：自动」`h_source_charset_label.png`（`.gitignore` 里
`docs/screenshots/v*/*.png` 默认不入库）。

**本地书（v2.72.0 导入与阅读；v2.73.0 起 parser 分派 + schema 2 + EPUB + PDF；
v2.74.0 加 MOBI）**：
`<ApplicationSupport>/reader/local/<bookId>/` 下 `manifest.json` +
`chapters/<index>.txt`（一章一个 UTF-8 文本文件）+ 可选 `cover.jpg|png`
+ PDF 专有的 `book.pdf`（原文件，渲染时要它）。
- **解析层按格式分派**（`services/local_book_parser.dart`）：一个格式一个
  `LocalBookParser`（当前 `TxtBookParser` / `EpubBookParser` / `PdfBookParser` /
  `MobiBookParser`），
  统一产出 `ParsedLocalBook{title, author, format, chapters[{title,text,imagePage}],
  coverBytes, idSeed, warnings, meta, sourcePath, pageWidth, pageHeight}`。
  需要**原文件路径**的格式（PDF）实现能力接口 `FileBasedLocalBookParser`
  （`parseFile(path)`），导入服务用 `is FileBasedLocalBookParser` 分流，
  TXT / EPUB / MOBI 照旧走 `parse(bytes)`。加 AZW3 / UMD 只需新增实现 + 在
  `LocalBookParsers.parsers` 挂一行，存储 / 书架 / 阅读 / 删除全都不用动。
  分派认的扩展名：`txt` / `epub` / `pdf` / `mobi` / `azw` / `prc`；**`azw3` 故意不认**
  （KF8 正文布局不同，分派层直接给「在 Calibre 里转 EPUB」的提示）。
- **schema 2 存储**：manifest 记 `{schema:2, id, name, author, format,
  chapters:[{title,file} | {title,image:true}], coverFile?, sourceFile?,
  pageWidth?, pageHeight?, sizeBytes, importedAt, encoding}`。
  章节各自一个文件（不再「一份全文 + 字符偏移」）：EPUB 本来就是一章一个
  XHTML，且独立文件没有偏移错位这种耦合，坏一章只坏一章。PDF 的章节是
  **图片页**（`image: true`，没有 `.txt`），原文件另存 `book.pdf`。
- **v1 惰性迁移**：读到 `schema` 缺失或 != 2 的旧 manifest（`book.txt` +
  `start/end`）时就地切开写 `chapters/`，**最后**才写新 manifest；
  任一步失败就原样返回 v1 书（继续读 `book.txt`）—— 迁移失败绝不能让
  用户已导入的书变成打不开。迁移成功后删掉 `book.txt`。
- **书 id**：`localBookIdFor(书名, idSeed)`（64 位哈希的 16 位小写十六进制）。
  TXT 的 idSeed 是全文（与 v2.72.0 **完全一致**，老书重复导入仍命中同一个
  目录）；EPUB 是 `epub|<文件名>|<zip 字节数>|<首 2KB>`（压缩包不适合按解压
  后的正文算指纹）；PDF 是 `pdf|<文件名>|<字节数>`；MOBI 是
  `mobi|<文件名>|<字节数>|<首 2KB>`（与 EPUB 同口径：压缩过的容器不适合按解压
  后的正文算指纹）。**不含导入时间** →
  同一份内容重复导入是覆盖，不是多一本。
- 正文上限：单本按**章节文本累计字符数** ≤ `LocalBookStore.maxTextChars`
  （20M 字）；TXT 原始文件 ≤ 32MB；EPUB 原始文件 ≤ 100MB 且解压后单章
  ≤ 8MB / 全本 ≤ 200MB（`EpubLimits`，防 zip bomb）；PDF 原始文件 ≤ 100MB
  且**页数 ≤ 3000**（`PdfBookParser.defaultMaxPages`）；MOBI 原始文件 ≤ 100MB
  且**解压后正文 ≤ 64MB**（`MobiBookParser.defaultMaxTextBytes`，在拼接阶段就
  停住，不先把几百 MB 拼进内存）。
- 书架里的本地书用伪 URL **`local:<bookId>`** 当唯一键（`normalizeUrl` 不动
  非 http(s) 地址，所以它原样进 `reader:books`）。全项目靠 `isLocalBookUrl()` /
  `localBookIdFromUrl()` 区分本地书与网络书；**改前缀等于让用户已导入的书
  全部从书架消失**。书架行显示「本地」+ 格式角标（`TXT` / `EPUB` / `PDF` / `MOBI`），
  有封面显示 `Image.file`（失败回退占位）。书名取**文件名去扩展名**（后缀名单只在
  `titleFromFileName` 一处维护）；解析器给出的 `ParsedLocalBook.title`（EPUB 的
  dc:title、MOBI 的 EXTH/full name）目前**不参与落盘命名**，只做诊断。
- 原生选文件的临时副本在 `<filesDir>/reader/incoming/<uuid>.<ext>`，Dart 读完即删，
  超过 24 小时的残留会在下次选书时清掉。
- **阅读链路（E2，v2.72.0）**：`book_reader_page.dart` 里抽了 `ChapterContentLoader`
  （`services/chapter_content_loader.dart`）——`load(int chapterIndex)` 一个方法：
  - `NetworkChapterLoader`：原样包 `BookContentService.loadContent`（含离线缓存），
    行为与改动前一致；不传 loader 时阅读页自己构造它，**既有调用点一个字都不用改**。
  - `LocalChapterLoader`（`services/local_chapter_loader.dart`）：读
    `LocalBookStore.readChapter(id, index)`，章名取 manifest，`pageCount: 1`、
    `partial: false`、`warning: null`，**不发网络请求**；越界 / 文件缺失折成
    `RuleEngineException`（「不在目录里」/「本地书籍文件已丢失」）。
  - 阅读页新增可选参数 `localBookId` / `loader` / `localStore`，`source` 改为可空
    （本地书没有书源）。本地书模式：不建 WebView 引擎、不查 `ChapterCacheStore`、
    不显示缓存入口，其余（目录 / 进度 / 翻页方式 / 字号 / 主题）与网络书完全一致。
- **书架分流**：`reading_page._openBook` 先看 `localBookIdFromUrl`，为真走
  `_openLocalBook`：`getBook(id)` 取 manifest → `localBookToc(book)` 拼 `TocChapter`
  （`url = local:<id>#<index>`，不用于请求）→ push 阅读页（带 `initialIndex` =
  `reader:progress` 的 `chapterIndex`，页内位置由阅读页按 offset / pageIndex 还原）。
  `getBook` 为空时弹「本地书籍文件已丢失」+「从书架移除」，不白屏。
  同一份 `reload()` 还会把本地 manifest 收进 `_localBooksById`，供书架行显示
  格式角标与封面（`ShelfBook` **故意**不加格式字段，那是本地书专属概念）。
- **删除连带清理**：长按书架行 → 二次确认（本地书文案明确「文件与章节缓存一起删」）→
  `LocalBookStore.removeBook(id)` → `ChapterCacheStore.removeBook(bookKeyFor(detailUrl))`
  → `BookshelfStore.removeBook`。**先删文件**：文件删不掉就不动书架并提示，避免
  「书不见了、几百 MB 还占着」。
- **导入提示**：`已导入《书名》（EPUB，共 N 章）`；EPUB 有章文件缺失时追加
  「另有 N 章文件缺失已跳过」（`LocalBookImportResult.skippedChapters`）。
- **PDF（v2.73.0）：下拉式漫画，一页一张图**
  - **渲染方式**：Android 自带的 `android.graphics.pdf.PdfRenderer`（API 21+，
    项目 minSdk 26），一页渲染成 PNG。**不引 pdfium / pdfx / mupdf**（体积十几 MB，
    而这里只需要「把页面画成图」）。阅读页纵向滚动，图片按可用宽铺满
    （`BoxFit.fitWidth`），页比屏幕长时继续往下拖。
  - **为什么不解析文本**：PDF 的文字是内容流里的绘制指令，要还原阅读顺序需要
    字体表 + 编码映射 + 位置启发式，纯 Dart 做不到；扫描版 PDF（漫画 / 老书）
    根本没有文字层；而用户对 PDF 的期待本来就是「看得见的排版」。
    代价明确：**PDF 里的文字选不中**（画面是像素），这是渲染路线的天花板。
  - **目录与进度**：`chapters` 就是页，标题「第 N 页」，`LocalChapter.image = true`
    （**没有** `chapters/N.txt`）；`reader:progress` 的 `chapterIndex` 即页号。
    书架格式角标自动显示 `PDF`（`format.toUpperCase()`），封面是第一页 400 宽
    的渲染图（`cover.png`）。
  - **原文件必须留在书目录**：`<support>/reader/local/<id>/book.pdf`（manifest
    的 `sourceFile`），导入时从原生临时副本拷进来（`LocalBook.importParsedBook`
    的 `sourcePath`）；manifest 另记首页尺寸 `pageWidth` / `pageHeight` 供占位。
  - **惰性渲染 + 磁盘缓存**：不预渲染全书，读到哪页渲染哪页。缓存不在书目录，
    而在 `<filesDir>/reader/pdfcache/<书id>/<页号>@<宽>.png`（`cacheKey` = 书 id，
    删书时同一个 key 清干净）。宽度固定 **1080**（同页同宽直接命中缓存；不按屏幕
    宽算是因为旋转屏幕会让缓存翻倍），上限 2048；单页位图超 **8MB** 时自动缩窄。
    **上限 300MB / 每本 500 页**，按文件 mtime 最旧先删，**当前正在看的那页
    永不删**（`planPdfCacheEviction` 纯函数，2 分钟节流一次，见
    `services/pdf_cache_policy.dart`）。
  - **上限与错误**：PDF 原始文件 ≤ 100MB、页数 ≤ 3000（超了拒绝并说明）；密码
    保护的 PDF 明确报「PDF 有密码保护，暂不支持」（原生 `SecurityException`）。
  - **分页模式不适用**：`pageMode == 'paged'` 时 PDF 仍按逐页滚动渲染，并提示
    「PDF 只能逐页浏览」；开关不藏（与网络书一致），点了给说明但不改设置。
  - **删书连带清理**：`LocalBookStore.removeBook` 先删书目录，再按 id 清
    `pdfcache/<id>/`（缓存可以重建，不该跟着书目录一起被当成「书」）。
    **覆盖导入同一本 PDF 时也清一次**（书 id 相同 → 缓存 key 相同，不清会沿用
    上一版页面的截图）。
- **MOBI（v2.74.0）：手写 PalmDB + PalmDOC，不引依赖**
  - **容器**：PalmDB（PDB）—— 78 字节头（`type`/`creator` = `BOOK`/`MOBI`）+ 记录表
    （每项 8 字节：offset u32 / attributes u8 / uniqueID u24）+ 2 字节 padding。
    记录**没有长度字段**，每条的范围是「本条 offset → 下一条 offset（末条到文件尾）」，
    所以任何越界都只能报「不是有效的 MOBI 文件」，不能顺着坏偏移读下去
    （`utils/mobi_reader.dart` 的 `PdbFile.parse`）。
  - **record 0**：16 字节 PalmDOC 头（compression / textLength / recordCount /
    recordSize / encryption）+ MOBI 头（`textEncoding` / `fileVersion` / EXTH flags /
    `extraDataFlags`）+ 可选 EXTH + 完整书名。正文在 record 1..recordCount。
  - **压缩**：只支持 `1`（不压缩）与 `2`（PalmDOC LZ77：`0x01–0x08` 字面量组、
    `0x80–0xBF`「空格 + 字符」、`0xC0–0xFF` 短回溯，距离 11 位 / 长度 3–10）。
    **`17480`（HUFF/CDIC）明确报不支持**并提示用 Calibre 转 EPUB —— 那是在 PalmDOC
    之上再套霍夫曼 + CDIC 字典，纯 Dart 实现代价（且容易解错）与收益不成比例。
  - **截断与附加数据**：按 `textLength` 截断（最后一条记录可能带 padding）；记录
    尾部若有 trailing entry（由 MOBI 头的 `extraDataFlags` 置位数决定，长度是写在
    末尾的反向变长整数），**必须先剥掉再解压**，否则正文尾会多出几个字节的垃圾。
  - **编码**：`textEncoding` 1252 → cp1252（0x80–0x9F 单独一张表，**不能拿 latin1
    顶替**，否则弯引号 / 破折号 / 省略号会变成控制字符）；65001 → UTF-8，解出
    大量 U+FFFD 时回退 cp1252 并记 warning。
  - **章节标题是启发式（没解析 NCX）**：按 `<mbp:pagebreak>` 切段，每段第一个
    `<h1>`–`<h3>`（或 `class` 含 `chapter`/`ctitle`/`title` 的 `<p>`）当章名；
    有 ≥ 2 个段带标题才用这套，否则把整本当纯文本交给 `splitTxtChapters`
    （它自己还会退到 3000 字分块）。Mobipocket 的目录在 INDX 记录里（索引压缩 +
    二进制偏移），本批不做，理由写在 `MobiBookParser` 的类注释。
  - **AZW3 / KF8 明确拒绝**：`fileVersion >= 8`，或记录里出现 `BOUNDARY` / `FDST`
    （双格式 AZW 的 KF8 部分）→ 抛「暂不支持 AZW3/KF8，请在 Calibre 里转成 EPUB
    再导入」。**不要尝试半解析**：KF8 的正文布局与 MOBI 6 不同，半解析只会得到
    「能打开但全是乱码」的书。`dispatcher` 也不认 `azw3` 扩展名，文案同上。
  - **作者 / 书名**：作者取 EXTH 100；书名优先级 EXTH 503 > record 0 的 full name >
    PalmDB 的 32 字节数据库名 > 文件名。EXTH 解析失败只让作者空着，**不让整本书
    导入失败**。注意书架上的书名仍按「文件名去扩展名」（见上文书架那一条）。
  - **本机实测（2026-11-23，模拟器 `bili_test`）**：用 Python 按 PalmDB / PalmDOC
    语法现造的 3 章中文 MOBI（`compression=2`，905 字节，脚本
    `C:/Users/HP/.kimi-tmp/gen_mobi.py`，不入库）经 SAF 导入 → 书架出现「MOBI」角标
    → 阅读页正文中文正常、目录三章（起风 / 落雨 / 转晴）全对；`run-as` 看到的
    `manifest.json` 是 `format:"mobi"`、`author` 来自 EXTH，`chapters/0..2.txt`
    与原文逐字一致。DocumentsUI 里 `.mobi` 可直接选中（MIME 白名单生效）。

---

## 6. 已知坑（踩过的，别再踩）

1. **`runJavaScriptReturningResult` 返回值层数随平台变**（Android 两层 / iOS 一层）。
   必须按类型循环剥，设上限（`rule_engine.dart` 的 `_unwrapJsValue(maxLayers: 4)`）；
   正文以 `<` 开头时**不能**当 JSON 解，直接放行。v2.69.0 的「正文显示成 JSON 转义串」就是只剥一层。
2. **`flutter test` 宿主没有 `path_provider` 实现，通道会永不返回**。
   任何碰 `getApplicationSupportDirectory()` 的代码必须有超时或测试早退
   （范例：`diag_log.dart` 的 2s `.timeout(...)`、`chapter_cache_store.dart` 的 `rootTimeout`
   与 `rootDirOverride`、v2.72.0 的 `local_book_store.dart`（同款 `rootTimeout` +
   `isTestHost` 早退 + `rootDirOverride`））。写新的落盘逻辑时先想「测试环境怎么走」。
3. **推荐页 TTL 30 分钟内直接返回内存结果**，所以「刚看完的视频要等 TTL 过期才消失」，
   这是设计行为。`force`（下拉刷新 / 换一批）才绕过。
4. **书源规则引擎一个实例一个 WebView 页面，求值必须串行**。宿主用
   `Offstage(offstage: true)` 包在 `SizedBox(width: 1, height: 1)` 里——尺寸不能为 0，
   否则 WebView 不布局、JS 不执行（见 `book_search_page.dart` 的 `_hiddenHost`）。
5. **`@js` 书源不支持**：legado 的 `java.ajax` 是同步调用，浏览器里同步 XHR 被 CORS 拦。
   `legado_compat.isJsSource` 会判定并在 UI 标「需要 JS 规则，暂不支持」。
6. **发布脚本的 push 必须走 SSH over 443**（v2.74.0 起）：https remote 会走本机 Clash
   代理 `127.0.0.1:7897`，代理没起时 push 直接连不上。脚本现在 push 用
   `AMOTV_PUSH_REMOTE`（默认 `ssh://git@ssh.github.com:443/Tukist/bili-whitelist.git`），
   **失败即停**并打印手工补救命令（旧的「`if` 兜住、仍然跑到发布完成」已删除）；
   末尾自检 `git ls-remote` 的 main/tag 与 `gh release view --json assets`，不符即非零退出。
   看到「发布中止：推送失败」就是真的没发出去，按提示补推即可，别当成功。
7. **测试环境下装饰动画默认关闭**（`MotionControl`）。要测动画本身得显式
   `MotionControl.enabled = true`，用完 `reset()`；否则 `pumpAndSettle` 超时。
8. **不要用 `adb shell input` 做不可逆操作**（滑删 / 拖拽），坐标会随列表滚动漂移。
   模拟器上覆盖安装用 `adb install -r`，绝不 `uninstall`——登录态在 secure storage 里。
9. **分页（`book_paginator.dart`）的四条红线**（v2.72.0，踩过就整页错位）：
   - **测量用的 style 必须和 `Text` 真实渲染的 style 逐字段一致**，这是本批最贵的坑：
     `Text` 默认会把 `DefaultTextStyle`（主题 bodyMedium）合并进来，带上
     `letterSpacing: 0.3` / `fontFamily: Roboto` / `leadingDistribution: even`。
     只拿「字号 + 行高」的裸 `TextStyle` 去 `TextPainter` 量，字宽/行高都对不上，
     实机表现是**页尾多折一行、被裁掉半行字**（字宽偏窄）或**一页只塞 14 行、
     底下留一大片空白**（行高偏大）。做法：`book_reader_page` 里用
     `TextStyle(inherit: false, fontSize, height, color, letterSpacing: base.letterSpacing,
     wordSpacing: base.wordSpacing)` 把样式写全，**字体留空**（显式写 `Roboto`
     在某些 ROM 上会落到另一套字体，行高字宽全变），同一个 style 对象同时喂
     `paginateText` 和 `Text`。
   - `TextScaler` 也要同口径（`MediaQuery.textScalerOf(context)`）；系统字号放到 1.3×
     而测量按 1.0 算，同样会溢出一行。
   - 宽 / 高 ≤ 0、或可用高度不足一行时**必须**整章一页：二分里没有「一个字符都
     放不下」的解，不兜底就是死循环（真机上出现在旋转中途、可用高被算成 0 的那一帧）。
   - `PageView` 的 item 下标**不是**页号：前后各有一张「哨兵页」（滑过去 = 切章），
     `PageController(initialPage:)` 要传 `页号 + lead`，否则进章先停在哨兵上。
   - 分页模式的页面几何**固定**（不随控制层显隐内缩），因为高度变一点就要重新分页，
     用户点一下屏幕就会看到文字换页。
10. **widget 测试里不要 `await` 真文件 IO**（v2.72.0 踩到并挂死）。
    `testWidgets` 跑在 FakeAsync 区里，dart:io 的 Future 不会自己推进，`await` 会一直挂着
    （表现是整个测试进程不出结果）。凡是页面里会碰 `LocalBookStore` / `ChapterCacheStore`
    的用例，要么注入**内存假库**（`test/reading_page_local_import_test.dart` 的
    `_FakeLocalStore`），要么把「真目录删没删」这类断言放进纯 `test()` 里用真 store 跑。
11. **EPUB 的章节顺序看 `spine`，不要按文件名 / manifest 顺序排**（v2.73.0）。
    `manifest` 只是「包里有哪些文件」，顺序任意（实际文件里常按写入顺序甚至名字排序）；
    **`spine` 里的 itemref 顺序才是作者声明的阅读顺序**。序章叫 `x9.xhtml`、第一章叫
    `a1.xhtml` 的书写处都是，按文件名排会把整本读乱。同理：章节**标题**要去
    `nav.xhtml`（EPUB3）或 `toc.ncx`（EPUB2）里按 href 找，找不到才退化成「第 N 章」。
12. **不要 `import 'package:xml/xml.dart'`**（v2.73.0）。`xml` 在本项目只是
    **间接依赖**（`pubspec.lock` 里 `dependency: transitive`），直接 import 会触发
    `depend_on_referenced_packages`，而 `flutter analyze` 默认 `--fatal-infos` 是开的
    → 门禁直接红；而 `pubspec.yaml` 归发布流程管（红线 2），不能随手加一行。
    需要解析 XML 时沿用 `xlsx_reader.dart` / `local_book_parser.dart` 的做法：
    **按标签名扫一遍的极简扫描器**，任何畸形输入都不抛到上层。
13. **`PdfRenderer` 不能并发用，`openPage/close` 必须成对**（v2.73.0）。
    同一个文档同时 `openPage` 两个页会抛异常，多个实例并发也容易在 native 崩溃。
    `PdfRenderPlugin` 的做法是「单线程 executor + `synchronized(renderLock)`」两层；
    `PdfRenderer` / `ParcelFileDescriptor` / `Page` 全部 `use` 或 `try-finally`。
    **文件描述符泄漏的后果是「这本 PDF 后面再也打不开」**（实测），
    所以别写「正常路径才 close」那种代码。
14. **PDF 选不中文字是设计边界**（v2.73.0）。正文是渲染出来的位图，没有文本层；
    滚动模式下的 `SelectableText` 只服务 TXT / EPUB。要在 PDF 上复制文字只能
    换「抽文本」的方案，而那需要引 pdfium / mupdf（硬约束不许），别在 issue 里
    当成 bug 修。
15. **PDF 的 `parse(bytes)` 在测试宿主上会早退**（v2.73.0）。它要把字节落成临时
    文件才能交给 `PdfRenderer`，而 `flutter test` 没有 `path_provider` 实现 ——
    解析器用 `FLUTTER_TEST` 早退（同 `LocalBookStore.isTestHost`）。所以 PDF 的
    单测一律走 `parseFile()` + 假 `PdfRendererBridge`，别在 widget 测试里等真文件。
16. **内置书源的选择器会随站点改版失效 —— 改之前必须 `curl` 真实页面**
    （v2.73.0）。`example_sources.dart` 里每条规则旁边都写了「这条对应页面里的
    什么结构」，改规则时按同一套位置重新抓一遍、用 `python + bs4` 点数命中条数，
    不要凭印象改。踩过的具体坑：
    - 维基文库搜索 URL **必须带 `fulltext=1`**：不带时关键词恰好等于某个页面
      标题，MediaWiki 会 302 直接跳到那个页面，我们拿到的是图书页而不是结果
      列表 —— 表现是「搜得到却显示 0 条」。
    - 正文容器 **不能只写 `.mw-parser-output`**：页顶还有一个只带这个 class 的
      指示器 div，`querySelector` 先命中它，正文取出来是空的。要写
      `div.mw-content-ltr.mw-parser-output`。
    - 本机 `curl`（schannel）抓 `zh.wikisource.org` 会报
      `SEC_UNTRUSTED_ROOT`，只能 `-k`；部分书名（如「史記」）会被中间设备
      直接 403。抓页失败先分清「站点挂了」和「本机网络拦了」，别急着改规则。
17. **MOBI 没解析 NCX，章节标题是启发式**（v2.74.0）。目录在本批是「`<mbp:pagebreak>`
    \+ 每段第一个 `<hN>`」猜出来的，不是原书 INDX 记录里的真目录 —— 所以
    「章名和原书不完全一致」「某些书按段切得太碎」都是已知行为，不是 bug。
    要改准只能实现 INDX 解析（索引压缩 + 二进制偏移），代价很高；改启发式之前
    先用真书（`docs` 里没有样本，自己用 `gen_mobi.py` 那套语法造）跑一遍。
    同一批里还踩过/要记住两条 MOBI 细节：
    - **记录尾部 trailing entry 必须先剥再解压**（`extraDataFlags` 的置位数就是
      条数，长度是末尾的反向变长整数）。不剥就是「前几章正常、最后几个字是乱码」，
      极难查。
    - **cp1252 不能用 latin1 解**：0x80–0x9F 是弯引号 / 破折号 / 省略号 / €，
      latin1 会解成 C1 控制字符，正文看上去像坏了，其实只是编码表错了。
18. **网络书源的编码判定：严格 UTF-8 必须排在「声明 gbk」之前**（v2.75.0）。
    书源的 `charset` 字段与站点的 `<meta>` / `content-type` 都**只是提示**，
    抄错的比例很高（改版只改输出不改声明）。踩过的具体形态：
    - **声明 gbk、实际 utf-8**：按提示硬解 GBK 会得到一整页生僻字，而且
      `replacementRatio` 很低（GBK 码表几乎能解一切双字节），错误**不会**被
      「乱码比例」兜住 —— 只能靠「严格 UTF-8 能不能解通」挡住。反过来的
      （声明 utf-8 实际 GBK）由严格解码必然失败接住。
    - **响应头 charset 优先于书源声明**：`content-type: text/html; charset=gbk`
      是站点这次响应自己说的，比书源作者写的准。两条提示都错时自动判定纠正。
    - **引擎上的 `lastDecodeWarning` / `lastDecodeEncoding` 只记最近一次抓取**：
      多页抓取（正文分页、目录分页）必须**每页抓完就当场收下**，否则后一页成功
      就把前一页的告警盖掉了（`book_content_service` / `book_detail_service`
      都按这个写法）。别在循环外面读一次就当整章的结果。
    - **`WebViewController` 在 `flutter test` 里构造即抛**，所以 v2.75.0 把引擎的
      controller 改成**懒建**（`fetchHtml` 只走 Dio）。想在单测里验编码，构造
      `WebViewRuleEngine(dio: Dio()..httpClientAdapter = 假适配器)` 就行，
      不要为了测一行字节去开 WebView。
    - GBK 字节**只能写字面量**（`[0xC4,0xE3,0xBA,0xC3]`）：Dart 没有 GBK 编码器，
      「源码写中文再 encode」这条路本身就不存在。
    - **「疑似 GBK」不能在 UI 上显示成「仍有乱码」**：自动纠正成功是好消息，
      两条告警必须分开压成小字（`kDecodeGbkGuessWarning` → 「编码：GBK」，
      `kDecodeGarbledWarning` → 「编码：GBK（仍有乱码）」）。2026-11-23 实机第一次
      就是把两句合成一句，GBK 页面明明正常显示、小字却写着「仍有乱码」。
    - **`normalizeUrl` 会把同站的 `http` 升级成 `https`**（去重与重定向口径需要），
      所以拿本地 HTTP 服务做实测时 baseUrl 不能与被请求 URL 同 host，否则请求被
      改成 https 直接 `HandshakeException`。

---

## 7. 测试与门禁

- 测试目录：`app/test/`，共 271 个 `*_test.dart`；`test/live_danmaku_fakes.dart` 与
  `test/mobi_test_builder.dart` 是辅助文件（没有 `main()`；后者文件名不匹配
  `*_test.dart`，门禁根本不会把它当测试文件）。
- 当前基线：**271 个文件、7 批、通过用例数见下**（v2.75.0 实跑）：

| 项 | 结果 |
|----|------|
| `flutter analyze` | 0 issue（10–70s，冷启动更久） |
| `flutter test` 分批 | 7 批全部通过，合计 **4144** 个用例 |
| `flutter build apk --debug` | 通过 |

- 分层策略：
  - **开发中**：`bash app/tools/gate.sh --quick test/你改的_test.dart`（analyze + 目标文件）
  - **提交前 / 发版前**：`bash app/tools/gate.sh`（全量 + 构建）
- `gate.sh` 的行为：每批 ≤45 个测试文件；失败立刻退出并打印「哪一步 / 哪一批 / 出错行 +
  日志末尾 30 行」；最后一行 `GATE OK` 或 `GATE FAILED`；临时文件在 `mktemp -d` 里，
  `trap` 清理。
- **永远不要**：`flutter test -d <设备>`、在模拟器上跑 `integration_test`（会重装清数据）。

---

## 8. 版本变更记录（最近几个版本）

| 版本 | 主题 | 关键文件 |
|------|------|----------|
| v2.75.0 | **网络书源接 GBK 解码 + 自动判定**（H 批）。① `WebViewRuleEngine.fetchHtml` 不再 `utf8.decode(allowMalformed: true)` 一把梭，字节交给 `utils/text_decoding.dart` 的 `decodeTextBytes`（与本地 TXT 导入**同一套判定**，不写第二份）：BOM → UTF-16 → **严格 UTF-8** → UTF-8 只坏 ≤1% 字节 → GBK（先信提示、再自动）→ 兜底；关键改动是**严格 UTF-8 排在「声明 gbk」之前**（站点改版只改输出不改声明，「声明 gbk 实际 utf-8」比反过来常见，硬解 GBK 得到的是「能解但全是生僻字」——乱码比例兜不住这种错）。hint 优先级 **HTTP 响应头 charset > 书源 `charset` 字段**（响应头是站点这次响应自己说的），`parseHeaderCharset` 解析 `content-type` 的 `charset=`（引号 / 大小写 / 多余参数都容忍）。② 判定事实带出两个字段：`lastDecodeEncoding`（实际编码）与 `lastDecodeWarning`（两句人话：「这个书源疑似 GBK，已按 GBK 解码」/「解码后仍有乱码，正文可能不完整」；站点自己声明了 GBK 不提示）；两者都只记**最近一次**抓取，所以正文 / 目录服务改成**每页抓完当场收下**（后一页成功不会盖掉前一页的告警；正文服务还顺手去掉了循环外那次重复收集）。③ UI：`BookSearchGroup` 加纯增量字段 `decodeNote`（`decodeNoteFor` 压成「编码：GBK」/「解码有乱码」/「编码：GBK（仍有乱码）」，正常 UTF-8 为 null），搜索页只在**分组标题下**显示一行小字；阅读页滚动模式在正文末尾加一段小字、分页模式并进最后一页（原来只显示 `partial`，`warning` 根本没渲染）；详情页复用既有 `warning` 链路。④ 书源管理页每行加一行「编码：GBK / 编码：自动」（`charsetLabelOf`：GBK 家族别名统一显示 GBK，utf-8 与没写都显示「自动」——模型默认值就是 utf-8，两者在判定上行为一致）；`fromLegado` 加注释说明 legado 的 BookSource 没有 charset 字段（它自己嗅探），正常 legado 源一律自动判定，读 `bookSourceCharset` 只为兼容少数第三方导出。⑤ 可测性：`WebViewController` 在 `flutter test` 里构造即抛，所以引擎的 controller 改成**懒建**（`fetchHtml` 只走 Dio），单测能注入假 Dio 适配器直接断言「GBK 字节 → 正确中文」。⑥ 实机（模拟器 `bili_test`，2026-11-23，`adb install -r`）：宿主机起一个只吐 GBK 字节、不带 charset 的页面 → 搜索得到 2 条中文书名（斗罗大陆 / 吞噬星空），分组标题下显示「编码：GBK」；实机上发现「疑似 GBK」被压成「仍有乱码」，于是把两句告警抽成 `kDecodeGbkGuessWarning` / `kDecodeGarbledWarning` 常量分开处理。新增 21 个用例（`text_decoding` 5 / `book_rule_engine` 9 / `book_search_service` 4 / `book_search_page` 1 / `book_source_page` 1 / `book_source_import` 1），既有断言一条没删没放宽 | `services/book_rule/rule_engine.dart`、`utils/text_decoding.dart`、`services/book_search_service.dart`、`services/book_content_service.dart`、`services/book_detail_service.dart`、`models/book_source.dart`、`pages/book_search_page.dart`、`pages/book_source_page.dart`、`pages/book_reader_page.dart`、`test/book_rule_engine_test`、`test/text_decoding_test`、`test/book_search_service_test`、`test/book_search_page_test`、`test/book_source_page_test`、`test/book_source_import_test` |
| v2.74.0 | 一次发版覆盖三批：**PDF 本地书**（F1）、**MOBI 本地书**（G，本条）与 EPUB / 解析器分派那批的收尾。**MOBI**：① `utils/mobi_reader.dart`（纯 Dart，无 Flutter 依赖）：`PdbFile.parse`（78 字节头 + 记录表，记录无长度字段 → 任何偏移越界都抛可读异常）、`parseMobiHeader`（compression / textLength / recordCount / recordSize / encryption / textEncoding / fileVersion / extraDataFlags / full name）、`palmdocDecompress`（LZ77：`0x01–0x08` 字面量组、`0x80–0xBF` 空格 + 字符对、`0xC0–0xFF` 11 位距离 + 3–10 长度；截断 / 回溯距离 0 或越界 / 解出超长都抛异常，不会死循环）、`trimTrailingEntries`（记录尾部附加数据，条数 = `extraDataFlags` 置位数、长度 = 末尾反向变长整数）、`exthValue`（100 作者 / 503 书名，坏了返回 null）、`decodeCp1252`（0x80–0x9F 单独一张 32 项表，**不用 latin1**）。② `MobiBookParser`：支持 compression 1 / 2；**17480（HUFF/CDIC）明确拒绝**并提示用 Calibre 转 EPUB；按 `textLength` 截断、逐条剥 trailing entry 再解压；UTF-8 解出大量 U+FFFD 回退 cp1252 并记 warning；正文复用 `restoreParagraphs(html,'block')`（先删 `<head>`，与 EPUB 同一套清洗）；章节按 `<mbp:pagebreak>` 切段 + 每段首个 `<h1>`–`<h3>`（或 class 含 `chapter`/`ctitle`/`title` 的 `<p>`）启发式命名，≥2 段带标题才用这套，否则退 `splitTxtChapters`，再不行按 3000 字分块；书名 EXTH 503 > full name > PalmDB 名 > 文件名，作者 EXTH 100；**AZW3/KF8 明确拒绝**（`fileVersion >= 8`，或记录里出现 `BOUNDARY` / `FDST`）——不半解析，避免「能打开但全是乱码」；原文件 ≤ 100MB、解压后正文 ≤ 64MB。③ 接入：`dispatcher` 认 `mobi` / `azw` / `prc`（`azw3` 故意不认，`unsupportedMessage` 直接给「在 Calibre 里转成 EPUB 再导入」）；`FilePickerPlugin` 的 `EXTRA_MIME_TYPES` 加 `application/x-mobipocket-ebook` / `application/vnd.amazon.ebook`，MIME→扩展名兜底认 `mobi` / `azw3`；书架角标与导入提示复用 `format.toUpperCase()`（自动出现「MOBI」「共 N 章」）；`_cleanName` 改为复用 `titleFromFileName`（原来另抄了一份 txt/epub/pdf 后缀名单，导致书架出现「mobi_g_test.mobi」）。④ 测试：`test/mobi_reader_test.dart`（PDB 边界 / PalmDOC roundtrip + 畸形输入 / cp1252 / EXTH / trailing entry / KF8）、`test/mobi_book_parser_test.dart`（3 章中文书、无标题退化、cp1252、HUFF / DRM / KF8、损坏文件）、`test/mobi_test_builder.dart`（现造夹具，**不往仓库放二进制样本**），本地书导入链路另加 MOBI 两条（落盘 format/书名/目录 + 重复导入幂等）。**已知限制**：没解析 NCX，章节标题是启发式 | `utils/mobi_reader.dart`（新）、`services/local_book_parser.dart`（`MobiBookParser`）、`services/local_book_store.dart`（`_cleanName` 复用后缀表）、`services/local_book_import_service.dart`、`pages/reading_page.dart`（提示文案）、`android/.../FilePickerPlugin.kt`、`test/mobi_reader_test.dart`（新）、`test/mobi_book_parser_test.dart`（新）、`test/mobi_test_builder.dart`（新，辅助文件）、`test/local_book_parser_test.dart`、`test/book_local_import_test.dart` |
| v2.73.0 | 一次发版覆盖三批：**EPUB + PDF 本地书** 与 **内置精选书源 + 可用性检测**。① **解析器按格式分派**：新抽象 `LocalBookParser`（`format` / `canParse` / `parse`）+ `TxtBookParser` / `EpubBookParser` / `PdfBookParser` + `LocalBookParsers.dispatcher`，统一产出 `ParsedLocalBook{title, author, format, chapters[{title,text,imagePage}], coverBytes, idSeed, warnings, meta, sourcePath, pageWidth, pageHeight}`；需要**原文件路径**的格式（PDF）实现能力接口 `FileBasedLocalBookParser.parseFile`，导入服务用 `is` 分流，TXT / EPUB 照旧 `parse(bytes)`；加 MOBI / AZW3 / UMD 只需新增实现并在 `parsers` 挂一行。② **EPUB**：`archive` 解 zip → `META-INF/container.xml` → OPF 的 `dc:title` / `dc:creator` / manifest / **spine 顺序**（章节顺序只看 spine，不看文件名）→ 标题取 EPUB3 `nav.xhtml`、退 EPUB2 `toc.ncx`、再退「第 N 章」→ 每章 XHTML 复用 `restoreParagraphs(html,'block')`（先删 `<head>`）→ 封面取 `<meta name="cover">` 或 `properties="cover-image"`；路径按 OPF / nav 各自目录解析（`%20` 解码、`..` 归一、大小写兜底）；**手写极简 XML 扫描器**（`xml` 只是间接依赖，直接 import 会红门禁）；防 zip bomb 按 entry 声明的 size 记账（单章 8MB / 全本 200MB，`EpubLimits` 可注入），解压后再校验一次。③ **存储 schema 2**：`manifest.json` + `chapters/N.txt`（一章一文件）+ 可选 `cover.jpg|png`，`LocalChapter` 从 `{start,end}` 变 `{file}`；**v1 惰性迁移**（读到旧 manifest 时按偏移切开写新章文件、**最后**才写新清单，任一步失败原样退回 v1 可读路径，成功后删 `book.txt`）；书 id 仍 `localBookIdFor(书名, idSeed)` —— TXT 的 seed 是全文（与 v2.72.0 逐字节一致），EPUB 是「文件名 + zip 字节数 + 首 2KB」，PDF 是「文件名 + 字节数」。④ **PDF（下拉式漫画）**：新 `PdfRenderPlugin.kt`（通道 `bili_whitelist/pdf`，`MainActivity` 手动注册）用系统 `PdfRenderer` 把一页渲染成 PNG 写进 `<filesDir>/reader/pdfcache/<书id>/<页号>@<宽>.png`，**只回路径**；单线程 executor + `synchronized` 串行，`PdfRenderer` / `ParcelFileDescriptor` / `Page` 全部成对关闭；`PdfBookParser` **不解析文字**，`chapters` = 每页一条 `{title: 第 N 页, imagePage: true}`（没有 `chapters/N.txt`），封面取第一页 400 宽，页数 ≤ 3000、原文件 ≤ 100MB，原文件另存 `book.pdf`（manifest 的 `sourceFile`）；`BookContentResult.imagePath` 非空即图片页 → `Image.file` 铺满可用宽、纵向可滚、失败可重试，按钮换「上一页 / 下一页」+「第 N / M 页」，`pageMode == paged` 强制逐页滚动并提示「PDF 只能逐页浏览」；`planPdfCacheEviction` 纯函数（300MB / 每本 500 页，mtime 最旧先删，`keepPath` 即当前页永不删，2 分钟节流）；删书按同一 cacheKey 清 `pdfcache/<id>/`，覆盖导入也清一次；`FilePickerPlugin` 的 MIME 加 `application/pdf`，导入提示「（PDF，共 N 页）」、书架角标 `PDF`。⑤ **内置书源**：`example_sources.dart`（常量名仍是 `kExampleBookSources`）从 1 条变 2 条 —— 新增 **维基文库（中文经典）**（搜索 `/w/index.php?search={{key}}&ns0=1&fulltext=1` + `ul.mw-search-results > li`，书名/链接用 `div.mw-search-result-heading a:not([title*="/"])` 排掉章节子页面；目录直接取图书页 `ul li a[title*="/"]`；正文 `div.mw-content-ltr.mw-parser-output` + 6 条清洗规则），**标准电子书**保留并复核；每条选择器都 `curl` 真页点数（维基：搜索 20 条 / 三國演義目录 123 条 / 正文 1 容器；SE：搜索 12 条 / 目录 12 章 / 正文 1 个 section），评估后排除 Gutenberg（503）/ ctext（Cloudflare）/ en.wikisource（版本页无目录）；管理页文案改「添加内置书源」，同名源不覆盖。⑥ **可用性检测**：`book_source_health_service.dart` 的 `probe` 复用 `BookSearchService` **真搜一次** → `ok` / `noResult` / `blocked`（401/403/407/412/429/451 或 HTTP 200 验证页，`noResult` 时**多抓一次**复核）/ `networkError` / `unsupportedJs`（`usesJs` 判定，不发请求）/ `badRule`；`probeAll` 并发 2、可取消、带进度；结果单 key `reader:source_health` 存 200 条（按 `at` 裁最旧，坏数据回空表，**不进 Gist**）；纯函数 `classifyGroup` / `summarizeSearchFailures`；管理页每行状态角标 + 长按「检测这个源」、AppBar「检测全部书源（较慢）」只测 `enabled && !usesJs`，清空书源连带清检测结果；搜索页分组标题显示上次检测结果、0 条时区分「没搜到」与「可能已失效（上次检测：被拦）」、整页 0 条给归类汇总；增量字段 `RuleEngineException.statusCode`、`BookSearchGroup.httpStatus` / `errorKind`（既有调用点零改动） | `services/local_book_parser`（新）、`services/local_book_store`（升 schema 2 + v1 惰性迁移 + PDF）、`services/local_book_import_service`、`services/local_chapter_loader`、`services/chapter_content_loader`、`services/book_content_service`、`services/pdf_renderer_bridge`（新）、`services/pdf_cache_policy`（新）、`services/book_source_health_service`（新）、`services/book_rule/example_sources`、`services/book_search_service`、`services/book_rule/rule_engine`、`pages/book_reader_page`、`pages/reading_page`、`pages/book_source_page`、`pages/book_search_page`、`android/.../PdfRenderPlugin.kt`（新）、`MainActivity.kt`、`FilePickerPlugin.kt`、`test/txt_book_parser_test`（新）、`test/epub_book_parser_test`（新）、`test/local_book_parser_test`（新）、`test/local_book_store_test`、`test/book_local_import_test`、`test/reading_page_local_import_test`、`test/pdf_book_parser_test`（新）、`test/pdf_cache_policy_test`（新）、`test/pdf_local_book_test`（新）、`test/pdf_book_import_test`（新）、`test/book_source_health_service_test`（新）、`test/example_book_source_test`、`test/book_source_page_test`、`test/book_search_page_test`、`docs/DEV_CONTEXT.md` |
| v2.72.0 | 一次发版覆盖三批：左右翻页 + 本地 TXT 导入 + 本地书阅读与删除。① **左右翻页**：`reader:settings` 加 `pageMode`（`scroll` 默认 / `paged`），正文按可用宽高用 `TextPainter` 二分切页、`PageView` 承载，前后哨兵页实现「末页再滑 = 下一章 / 首页前滑 = 上一章」，页码 `3 / 12`；分页模式不可选中（横滑与选字抢手势，取舍写进注释）；`ReadingProgress.pageIndex` 存页内位置，字号变化按比例落回相近页；顶栏加「翻页方式」切换并落盘。② **本地 TXT 导入**：纯 Dart GBK 解码（码表由 Python 生成）+ 自动编码判定（BOM / UTF-16 嗅探 / 严格 UTF-8 / GBK）、中文网文章节切分（第X章·回·节·卷·集 / 楔子番外 / Chapter N；无标题按 3000 字分「第 N 节」）、本地书落盘 `reader/local/<id>/`（正文一份 + 章节偏移）+ 书架伪 URL `local:<id>`、原生 `pickBookFile`（流式拷到私有目录，100MB，requestCode 9051）、阅读页「导入本地书」（Wrap 防溢出、导入中禁用）。③ **本地书阅读与删除**：阅读页抽 `ChapterContentLoader`（网络 / 本地两种实现），本地书与网络书共用同一页（不建 WebView 引擎、不查章节缓存、不请求网络、不显示缓存入口），`source` 改为可空但既有调用点零改动；书架点本地书按 `getBook(id).chapters` 拼目录直接进阅读页并按 `reader:progress` 续读，文件丢失弹「本地书籍文件已丢失」+「从书架移除」；长按删除连带清 `reader/local/<id>/` + 章节缓存 + 书架项（先删文件，删不掉不动书架）；书架行加「本地」角标 | `services/book_paginator`（新）、`services/chapter_content_loader`（新）、`services/local_chapter_loader`（新）、`services/local_book_store`（新）、`services/local_book_import_service`（新）、`utils/text_decoding`（新）、`utils/gbk_table`（生成物）、`utils/txt_chapter_splitter`（新）、`app/tools/gen_gbk_table.py`（新）、`book_reader_page`、`reading_page`、`bookshelf_store`、`FilePickerPlugin.kt`、`test/book_paginator_test`（新）、`test/local_chapter_loader_test`（新）、`test/book_reader_page_local_test`（新）、`test/reading_page_local_import_test`（新）、`test/book_reader_page_test`、`test/bookshelf_store_test` |
| v2.71.0 | 离线缓存（章节级 / 原子写 / 双校验）+ 阅读进度条 + 4 处实机修复；首版工程文档与本机门禁脚本 | `book_content_service`、`chapter_cache_store`、`book_reader_page`、`app/tools/gate.sh`、`AGENTS.md`、`docs/DEV_CONTEXT.md` |
| v2.70.0 | 阅读模块收尾：底栏 edge-to-edge 修复（`viewPadding` 内缩，不是只包 SafeArea）；书源从本地文件导入（SAF，8MB 上限，BOM 处理）；书源索引下载 + 选择页（2486 个去重源，上限 200，标出 `@js` 不支持）；书源名清洗；「清空书源」 | `reading_page` / `book_detail_page` / `book_search_page` / `book_source_page` / `book_source_picker_page`、`file_import_service`、`book_source_index_service`、`FilePickerPlugin.kt` |
| v2.69.0 | 底栏「日程」换成「阅读」（书源驱动阅读器）；多源搜索（并发 4、单源 20s）、分组/合并视图；详情目录、正文阅读、书架；规则四段 + 选择器语法；示例书源；修 `runJavaScriptReturningResult` 多层剥壳 | `models/book_source`、`services/book_rule/*`、`book_*_service`、`book_*_page`、`bookshelf_store`、`chapter_cache_store`、`playlist_page`（页签下标） |
| v2.68.0 | 底栏「UP 主」换成「推荐」：从最近 20 个看过的视频拉标签，14 天半衰 × 完播率打分，取前 5 标签；热力球（黄金角螺旋）；交叉区；推荐池 60 条，已看剔除；30 分钟 TTL；UP 主管理迁到个人 → 设置 | `recommend_service`、`recommend_page`、`playlist_page`、`watch_stats_page` |

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
