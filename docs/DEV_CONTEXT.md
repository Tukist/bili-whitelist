# amoTV 开发上下文（DEV_CONTEXT）

> **给接手的人 / 子智能体**：先读这份文件，再动手。它记录的是「现在代码长什么样」，
> 不是设计愿景。改完代码如果动了模块职责、红线、存储 key，**顺手改这里**
> （这份文档随开发维护；`CHANGELOG.md` 归发布脚本，别手改）。
>
> 最近一次对齐：v2.79.0（2026-11-24，书源请求选项 POST + `{{…}}` 地址模板；同日补
> 分卷目录「字段 XPath 相对化」修复，见第 6 节坑 23；随后复核又修了 4 处回归：
> `<head>` 里的 meta 被相对化 / body 模板被 URL 编码 / headers 大小写重复 /
> 翻页失败丢第 1 页，见坑 22、23）。

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
| `selector.dart` | 选择器语法解析：`css:` / `xpath:` / `class.xxx` / **`text.xxx`（v2.78.0 起真支持）** / `@text` / `@html` / `@href` / `@src` / `@ownText` / `@textNodes` / `@all` / `@attr:` / **`@属性名`**（`@content`）/ `regex:` / `##正则##替换`（含 `###` = 只替换第一个）/ `\|\|` 回退链 / **`&&` 并列** / **`%%` 交叉合并（v2.78.0）** / **`@` 链式** / **`.N` 选索引** / **`!N` 排除索引** / `children`。JS 规则单独 `kind: js`（`<js>` / `@js:` / `{{…}}` / `@get:`），脚本正文、前置选择器与被拦 API 挂在 `jsInfo` 上 |
| `js_rule.dart` | **I3a 新增 / I3b 收紧**，静态 JS 内核（纯函数，不碰 WebView）：`classifyJsRule` 认三种写法并列出白名单外的 API、`kSupportedJavaApis`（base64 / md5 / timeFormat / htmlFormat / strToBytes / bytesToStr / log，**不含** ajax / put / get / getString）、`buildJsRunnerScript` / **`buildJsRunnerFactory`（跑一行的函数工厂）** / **`jsRuleRuntimePrelude`** / **`jsBindings`（四个服务共用的绑定拼装）**、`parseJsRunOutput`。**v2.78.0 新增三类拦路判定**：`result.select()/attr()/parentNode()` 这类 DOM 桥、`book.xxx`/`source.xxx`/`chapter.xxx` 里**没绑定**的属性（避免拼出 `xundefined` 这种静默错值）、`cookie.`/`cache.`/`eval(`；`{{…}}` 内层是**嵌套选择器规则**（`{{@@id.intro@text}}`）时 `templateIsRule`；`while(true)`/`for(;;)` 这类**可见死循环** `hasDeadLoop`（执行会把整个 WebView 卡死，只能静态拦）。`blockReason` 给审计工具分档 |
| `js_builder.dart` | 选择器 → 待求值 JS 表达式（纯函数，可单测）。v2.77.0 起 `queryAll` 自己走链式 + 索引（`applyIndex`），`firstValue` 处理 `&&` 并列；**v2.78.0**：`textFilter`（按 ownText 筛）、`%%` 按行交错（`pickNodes`）、`buildQueryFieldsMixedJs`（选择器 + **逐行**静态 JS 一次求值）、`buildExtractHtmlWithJsJs`（正文规则本身是 JS 时的「删节点 → 取值 → 跑脚本」）。**书源 JS 的 `result` 初值不转绝对**（语料里 `'https://x'+result` 的 result 是页面里的相对 href） |
| `legado_compat.dart` | legado 字段名映射 + `jsUsageOf(source, {stage})`（**v2.76.0 建，v2.78.0 分阶段**：`SourceStage.search/detail/toc/content` 各管自己那一段，JS 目录地址不再挡住搜索）；`JsUsage{executedJs, unexecutedJs, runnableJs, executedFields, blockedApis}`（`runnableJs` = 执行字段的 JS **全部**静态可跑，**v2.79.0 起地址模板里可求值的 `{{…}}` 也算可跑**）+ `kNetworkJsApis` / `jsNeedsAjax` / **`sourceCapabilityOf`（书源管理页三态角标：可搜索 / 静态 JS / 需 JS）** + `normalizeUrl`。**v2.77.0 起 `legadoSelector` 是 `parseSelector` 的薄别名** |
| `request_options.dart` | **v2.79.0（I4）新增，纯 Dart**：`parseRequestSpec` 把 legado 的「地址 + `,{…}` 请求选项」拆开（`method` / `body` / `headers` / `charset` / `webView` / `type`；坏 JSON **退回整串当地址 + warning**，不报错）；`applyUrlTemplate` / `applyUrlPlaceholders` 处理两种 `{{…}}`（白名单变量同步替换、`{{key}}` URL 编码；JS 表达式交给注入的 `UrlJsEvaluator` 在空白页求值，结果**原样拼接**）；`inspectUrlTemplate` / `urlTemplateJsProblem` 是静态判定（`document`/`window`、ajax、变量表、DOM 桥、JSONPath 一律判不可跑）；`resolveRequestField` 是四个服务共用的「字段 → 可发请求」出口；`inferContentType` 判 POST 的 content-type |
| `rule_engine.dart` | 引擎接口 + WebView 实现；**I3a 加 `evalJsRule`**（复用当前页面、`base` 前置选择器取值当 `result` 初值、`checkJsRuleAllowed` 纯函数安全门、3 秒超时 + 超时重载空白页终止脚本、执行期禁止导航）；**I3b**：`queryFieldMap` 支持**选择器 + 逐行 JS 混在一次求值**（`bindings` 为新增可选参数）、`extractHtml` 支持 JS 正文规则、`_loadPage`/`_runJsRaw` 拆开；**载页不再死等 `onPageFinished`**（v2.78.0：轮询 `document.readyState` + `amotv-load` 标记，见「已知坑 20」）。**v2.79.0（I4）**：`fetchHtml` 加 `method` / `body`（POST 真发；content-type 显式 > JSON > 表单串；GET 路径一行没改）、新增 `evalUrlTemplateJs`（**空白页**上求值地址模板的 JS）；`FakeRuleEngine` 记录 `fetchedRequests`（方法 / body / 头）。**v2.75.0 起 `fetchHtml` 的字节解码交给 `utils/text_decoding.dart`**，结果带出 `lastDecodeEncoding` / `lastDecodeWarning`。**controller 懒建**（`fetchHtml` 不需要 WebView），单测能注入假 Dio 直接验 GBK 字节；`loadHtmlString` 求值仍走同一个串行队列 |
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
| `unsupportedJs` | 缺本版没有的 JS 能力，**不发请求** | v2.78.0 语义收窄：只指「补个函数也补不出来」的（变量表 / 嵌套规则模板 / DOM 桥 / 死循环）。**纯静态 JS 的源不再判死，会真去探测** |
| `needsAjax`（v2.78.0 新增） | 需要 `java.ajax` / `Packages.` 这类**发网络请求**的 JS | `jsNeedsAjax(usage)`：`blockedApis` 命中 `kNetworkJsApis` |
| `badRule` | 规则本身跑不起来 | 地址拼不出、没配列表规则、JSONPath |

- 管理页每行两个角标：**能力档**（绿「可搜索」/ 橙「静态 JS」/ 红「需 JS（ajax）」，
  `sourceCapabilityOf` 只看**搜索**那一段）+ **检测结果**（绿「可用 N 条」/ 灰「没结果」/
  红「被拦」/ 红「连不上」/ 黄「需 JS」/ 黄「需 ajax」/ 黄「规则坏」/ 灰「未检测」），
  长按菜单「检测这个源」；AppBar 溢出菜单「检测全部书源（较慢）」只测
  `enabled && 能力档 != needsJs`（**静态 JS 的源照常检测**），并发 **2**、可取消。
- 搜索页分组标题右侧显示该源上次检测结果；某源 0 条时用一行小字区分
  「这个源没搜到」与「这个源可能已失效（上次检测：被拦）」；整页 0 条时区分
  「所有源都没搜到」与「所有源都失败」（后者把原因归类成「3 个源连不上、2 个被拦」）。
  跳过列表脚注写「已跳过 N 个需要 JS 的书源（ajax / 变量表）」，点「查看」看名单。
- 检测结果**只在本机**，不进 Gist；「清空书源」会连带清掉（免得同名源复用时
  带着旧状态）。
- 探测复用 `BookSearchService`（不复制抓取代码）；为此 `RuleEngineException`
  加了 `statusCode`、`BookSearchGroup` 加了 `httpStatus` / `errorKind` 两个
  可空字段（纯增量，既有调用点不用改）。
- `noResult` 时会**换一门语言的关键词再搜一次**（默认「历史」→ 备选 `love`）：
  否则英文站点会稳定显示「没结果」，被当成坏源。仍 0 条才判 `noResult`，
  之后才做验证页复核。

**JS 判定的真实抽样（v2.76.0，I1 批）**

工具 `app/tools/js_rule_audit.dart`（纯 `dart:` 标准库，`dart run` 直接跑）：

```bash
dart run app/tools/js_rule_audit.dart                       # 用内置 4 个公开索引
dart run app/tools/js_rule_audit.dart --json /tmp/a.json     # 额外落机读结果
dart run app/tools/js_rule_audit.dart https://x/a.json       # 只测指定索引
```

**下载到的 32MB 语料与统计产物都不入库**（`--json` 指到仓外目录）。分类口径
按「本 App 实际执行的字段」：`search.*` / `detail.*` / `toc.*` / `content.*`
里真的拿去抓页面的那些；`exploreUrl` / `loginUrl` / `checkKeyWord` / `init` /
`preUpdateJs` / `ruleExplore.*` / `ruleContent.replaceRegex` 一律算「不执行」。

2026-11-23 实跑（4 个索引：22 / 128 / 3907 / 2117 条，跨文件同名去重 1994 个，
**去重后 2483 个源**）：

| 分类 | 数量 | 占比 |
|---|---|---|
| `noJs` | 1212 | 48.8% |
| `jsInUnexecutedField`（只在发现页 / 登录页 / init / isVip 等处用 JS） | 60 | 2.4% |
| `jsTransformOnly`（执行字段有 JS，但没有网络调用） | 503 | 20.3% |
| `jsUnsupportedApi`（执行字段的 JS 用了白名单外的 `java.*`） | 70 | 2.8% |
| `jsNeedsJsonPath`（`@json:` / `$.`，本版未接） | 358 | 14.4% |
| `jsNeedsAjax`（`java.ajax` / `connect` / `post` / `Packages.` / `org.jsoup`） | 280 | 11.3% |

- **旧口径（扫整份 raw）判死 1256 个（50.6%）≈ 流传的「51% 需要 JS」**；
  新口径（只看执行字段）1196 个（48.2%）。P0 本身只救回 **60 个（2.4%）**，
  数字不大但每一个都是白丢的源。
- 门槛：`jsInUnexecutedField + jsTransformOnly = 22.7% ≥ 20%` → **P0+P1 值得做**；
  `jsNeedsAjax + jsNeedsJsonPath = 25.7% < 60%` → **P2 不是唯一有意义的路**。
- `jsTransformOnly` 里 **496 / 503 一个 `java.*` 都不调**（纯字符串变换），
  这是 P1 的主要工作面。`java.*` 频次 top：`ajax` 235 / `put` 195 / `get` 171 /
  `getString` 129 / `timeFormat` 58 / `log` 53。
- 写法占比：`<js>` 26.3%、`@js:` 28.1%、`{{…}}` 26.4%（一个源可多种）。
- 需 ajax 的 280 个里 **115 个（41.1%）同时需要 JSONPath**。
- **抽样之外还有一道门**：很多源即使不依赖 JS，规则也用了 `@tag.` / `@a.0` /
  `p.1@a.0@text` 这类本版选择器不认的写法（`class.x@tag.a@href` 很常见）。
  P0/P1 只解决 JS，不解决这些；要评估「真正可搜」的比例得再抽一次语法样本。

**选择器语法抽样与补语法（v2.77.0，I2 批）**

I1 的数字只说「多少源需要 JS」。这一批量的是**第二道门**：规则本身没坏，
但选择器写法本版解析不了，于是取不到值。工具加了 `--selectors` 模式：

```bash
# 用本地语料（反复调口径时不必每次重下 33MB；参数是 URL 也行）
dart run app/tools/js_rule_audit.dart --selectors /tmp/a.json /tmp/b.json
dart run app/tools/js_rule_audit.dart --selectors --json /tmp/out.json ...
```

这个模式**直接 import `lib/services/book_rule/selector.dart`**（纯 Dart，没有
Flutter 依赖），所以「能不能解析」问的是**真的那个解析器**，不再维护第二份判定
逻辑 —— I1 的 JS 字段表还是两处各写一份（口径同源但无法共用），而语法这块从
v2.77.0 起只有一处。

2026-11-23 实跑（同一份 2483 个去重源、27175 条非 JS 执行字段规则串）：

| 语法特征 | 出现源数 | 占比 |
|---|---|---|
| 前缀 无（纯 CSS） | 1765 | 71.1% |
| 取值 `@text` | 1620 | 65.2% |
| 取值 `@href` | 1496 | 60.2% |
| `##正则##替换` | 1488 | 59.9% |
| 索引 `.N` | 1475 | 59.4% |
| 链式（`@` ≥ 2 个） | 1454 | 58.6% |
| 取值 `@html` | 1186 | 47.8% |
| 取值 `@src` | 1105 | 44.5% |
| 取值 `@属性名`（`@content` 等） | 1044 | 42.0% |
| 前缀 `class.` | 1029 | 41.4% |
| 前缀 `tag.` | 787 | 31.7% |
| 前缀 `id.` | 673 | 27.1% |
| 组合子 `&&` | 622 | 25.1% |
| 取值 `@textNodes` | 452 | 18.2% |
| 索引 `!N` | 389 | 15.7% |
| 组合子 `\|\|` | 378 | 15.2% |
| 前缀 `//`（XPath） | 89 | 3.6% |
| 前缀 `@其它`（基本是 `@get:`） | 90 | 3.6% |
| 取值 `@ownText` | 57 | 2.3% |
| 前缀 `@css:` | 48 | 1.9% |
| 前缀 `text.` | 36 | 1.4% |
| 索引 `[N]` | 32 | 1.3% |
| 前缀 `@json:` | 27 | 1.1% |
| 取值 `@all` | 12 | 0.5% |
| 前缀 `@tag.` | 7 | 0.3% |
| 组合子 `%%` | 5 | 0.2% |

**本批实现 / 不实现的依据就是这张表**（只做高频且语义能从 legado 源码确认的）：

| 语法 | 语料 | 决定 | 依据 |
|---|---|---|---|
| `@` 链式（`p.1@a.0@text`） | 1454 源 / 58.6% | **做** | legado `getElements` 按 `@` 切段、逐段 `getElementsSingle` |
| `.N` 选索引 | 1475 源 / 59.4% | **做** | `AnalyzeByJSoup`：`split == '.'` → 选择 |
| `!N` 排除索引 | 389 源 / 15.7% | **做** | 同上：`split == '!'` → **排除**（与 `.N` 语义相反） |
| `&&` 并列 | 622 源 / 25.1% | **做** | `getStringList` 里 `results` 按顺序 `addAll`，`getString` 再 `join("\n")` |
| `@属性名`（`@content`） | 1044 源 / 42.0% | **做** | `getResultLast` 的 `else` 分支就是 `element.attr(lastRule)` |
| 段尾裸标签名（`@li` / `@a`） | 660 源 / 26.6% | **做**（当链式段） | 这些规则在 legado 里是 `attr("li")` → 恒空，当链式只会多跑通、不会弄坏 |
| `@textNodes` / `@ownText` / `@all` | 452 / 57 / 12 源 | **做** | `getResultLast` 的三个具名分支 |
| `children` | 7 源 | **做** | `ElementsSingle`：`beforeRule == "children" → temp.children()` |
| `##…##替换###` | 语料里遍地 | **做** | legado `rule.split("##")` 第 4 段 = `replaceFirst` |
| `text.xxx`（按自身文字筛） | 36 源 / 1.4% | **不做**，报 `text` | 语义确定但占比低；新增一种 kind 不值当 |
| `%%` 交叉合并 | 5 源 / 0.2% | **不做**，报 `interleave` | 只有 5 个源，交错顺序记错就是整列表错位 |
| `@get:` / `@put:` | 27 源「只差这条」 | **不做**，算「需要 JS」 | 它们读写 `java.put` 的变量表，没有 JS 就没有那张表 |
| `[N]` 索引 | 32 源 | **不做** | 语料里这 32 条全是 JSONPath `$.a[0]` 或 XPath `text()[1]`，不是 legado 的 `[N]` 索引 |

**「真正可搜」的比例（同一份语料，前后对比）**

定义：不靠 JS（执行字段没有 JS）+ 所有会执行的选择器都能解析 + 配了搜索地址与
列表规则。口径只认这三条，**不看站点当下是否可达**（那是健康检测的事）。

| | 修复前（= I1 时点口径） | v2.77.0 之后 |
|---|---|---|
| 去重源 | 2483 | 2483 |
| **可搜索** | **495（19.9%）** | **754（30.4%）** |
| 被 JS 挡 | 1176（47.4%） | 1176（47.4%） |
| 被选择器语法挡 | 302（12.2%） | **43（1.7%）** |
| 缺搜索规则 | 510（20.5%） | 510（20.5%） |

- 净增 **+259 个源（+10.4 个百分点，相对提升 52%）**。这 259 个源一个 JS 都没碰，
  纯粹是「写法认不出来」—— 这就是 I1 报告里说的「第二道门」。
- 剩下的 43 个按原因：`@get:` 31（算需要 JS）、`text.` 9、`%%` 3。
- 被选择器挡的源里，修之前「只差一条就能跑」的最高频写法是
  `[property="og:novel:category"]@content&&…`（29 源）、`@get:{n}`（27）、
  `[property=og:novel:update_time]@content&&…`（26）；修之后只剩长尾。
- `@get:` 从「语法不认识」改判「需要 JS」后，UI 上的原因终于说得对了
  （原来会显示「写法暂不支持」，用户看不出这是 JS 缺能力）。

**新语法的三条硬约定**

1. **`!N` 是排除，`.` 是选**，两者语义相反。`class.grid@tag.tr!0` 是「除第一行
   之外的所有 tr」（跳过表头），不是「取第一行」。这条是查 legado 源码定的，
   语料里 389 个源用 `!N`、1475 个源用 `.N`，猜错一个就是整列错位。
2. **最后一段永远是「取值」**：`@text` / `@html` / `@href` / `@src` / `@ownText` /
   `@textNodes` / `@all`，其余裸词是**属性名**（`@content`）。唯一例外是
   `kLegadoChainTags` 里那些结构标签（`@li` / `@a` / `@tr`…）—— 它们当链式段，
   因为在 legado 里按属性读恒为空。
3. **链上任一段不支持 → 整条不支持**。半条链跑出来的是错值，比「明确说不支持」
   更难排查。

**JS 侧怎么验的**：`flutter test` 里没有 JS 引擎，所以单测只断言脚本文本；
真正跑一遍是拿 `node` + 一个几十行的假 DOM 跑生成的脚本，验了六件事：
`tr!0` 跳过第一行、`#info → p.2` 选中第 3 个、`&&` 两属性按 `\n` 拼、
`@textNodes`、`children` 只取直接子元素、`###` 只替换第一个匹配。
这一步不进仓库（脚本在仓外临时目录），但它比文本断言可信得多。

**静态 JS 接线与 `text.` / `%%`（v2.78.0，I3b 批）**

I3a 只做了内核（判定 + 沙箱），用户可见行为没变。这一批把静态 JS 真的接进了
搜索 / 详情 / 目录 / 正文，并按 legado 源码补了 `text.xxx` 与 `%%`：

| 能力 | 口径 | 依据 |
|---|---|---|
| 静态 JS（**能跑**） | 三种写法（`<js>` / `@js:` / `{{…}}`）+ 白名单 `java.*` + 前置选择器简单 + 模板里是 JS 表达式 + 没有可见死循环 | `JsRuleInfo.runnable` |
| 静态 JS（**跑不了**） | `java.ajax` 等网络调用 / 变量表（`java.put`/`get`/`getString`）/ `result.select()` 这类 DOM 桥 / `book.`·`source.`·`chapter.` 上没绑定的属性 / `cookie.`·`cache.`·`eval(` / `{{@@a@text}}` 这种**嵌套规则模板** / `while(true)`·`for(;;)` 死循环 / 前置选择器里带 `\|\|`·`&&` | 上面几条都是真实语料里见过的形态，逐条对照过 |
| `text.xxx` | 按「**自身文字**包含 xxx」筛元素（legado `ElementsSingle` 的 `"text" -> getElementsContainingOwnText`）；needle 只取到第一个 `.`（`beforeRule.split(".")[1]`） | 语料 36 源；v2.77.0 判死 → v2.78.0 真支持 |
| `%%` | 各支结果按**行**交错，外层长度取**第一支**（后面的支多出来的行丢掉）；`%%` 与 `&&` 同时出现时按**先出现的那个**切 | `AnalyzeByJSoup.getStringList` / `getElements` 的原码；语料 5 源 |

- **一次查询只载一次页**：`queryFieldMap` 把「选择器列 + 逐行 JS 列」合成一段
  脚本（`buildQueryFieldsMixedJs`）：列表节点只查一遍，JS 字段**每个节点各跑一次**
  （`buildJsRunnerFactory` 编一次、调 N 次）。逐字段载页是 6 倍等待，逐行
  `evalJsRule` 是 N 倍往返，两条都不走。
- **`result` 初值是「页面里的原值」**：`h2@a@href@js:'https://www.x.com'+result`
  里作者期望 result 是 `/book/123/`，所以 JS 字段的 result **不做相对转绝对**
  （选择器字段照旧转）。先转绝对再拼会得到 `https://www.x.comhttps://m.x.../book/123/`
  —— 整列详情页打不开。
- **裸表达式脚本也能跑**：语料里 `'https://m.x'+result`、`result.match(...)[1]`
  这类没有赋值语句的脚本很多，`new Function` 会把它们当语句丢掉（返回 undefined）。
  工厂先用 `eval(__src)` 取**完成值**（Rhino `script.eval` 的语义），取不到再退回
  `new Function`（那条路支持顶层 `return`）。
- **绑定**（`jsBindings`，四个服务共用一份）：`result` / `baseUrl` / `key` / `page` /
  `book{name, author, origin, bookUrl}` / `source{bookSourceUrl, name, bookSourceComment, getKey()}` /
  `chapter{title}` / `title` / `java`（白名单）。
- **阶段判定**：`jsUsageOf(source, stage: …)` 只看那一段。一个源可能只有
  **目录地址**是 JS（`toc.url`），搜索完全正常 —— 用整源口径判死会白丢能搜的源。
  能力角标、健康检测、搜索页筛选都用 `SourceSearch` 那一段。

**审计重算（同一份 2483 个去重源，三组数字）**

| | I1 时点（v2.76.0） | I2 后（v2.77.0） | **I3b 后（v2.78.0）** |
|---|---|---|---|
| 可搜索 | 495（19.9%） | 754（30.4%） | **1079（43.5%）** |
| 被 JS 能力挡 | 1176（47.4%） | 1176（47.4%） | **889（35.8%）** |
| 被选择器语法挡 | 302（12.2%） | 43（1.7%） | **5（0.2%）** |
| 缺搜索规则 | 510（20.5%） | 510（20.5%） | 510（20.5%） |

- 分类表：`jsStaticRunnable` **252**（执行字段的 JS 全静态可跑，单列一档）、
  `jsTransformOnly` 从 503 降到 252（剩下的不是「纯字符串变换」：模板套规则 /
  DOM 桥 / 变量表）、`noJs` 1212、`jsInUnexecutedField` 60。
- 净增 **+325 个源（+13.1pp，相对提升 43%）**；其中 `text.`/`%%` 让「被选择器
  挡」从 43 收到 5。
- 剩余不可搜的构成（一个源可命中多个原因）：地址模板里是 JS 504、变量表 358、
  JS 与 `||`/`&&` 混写 329、列表规则本身是 JS 192、`{{…}}` 套规则 153、
  ajax 148、其它不支持接口 145、JSONPath 27。
- **审计数字的口径边界**（写清楚，免得被当成「实测能搜」）：不算站点可达性、
  不算「搜索地址带请求选项」（`,{ "method":"POST", ... }` 这种 legado 写法
  **v2.79.0 才接上**，见下一节）、也不区分「少一个字段」与「整源不可用」。

**本机实测（2026-11-24，模拟器 `bili_test`，`adb install -r`）**

- 真实语料源 **零零小说**（`https://www.00shu.la`，`jsStaticRunnable`，`coverUrl`
  是 `<js>` 算封面地址）：导入后搜「凡人」→ **100 条**，封面全部是
  `@js:` 逐行算出来的（`/files/article/image/41/41151/41151s.jpg`）。
- 自建源 `search.name = <js>while(true){}</js>` → **静态拦下**，搜索页脚注
  「已跳过 1 个需要 JS 的书源（ajax / 变量表）：死循环测试源」。为什么不是
  「跑 3 秒然后报超时」：**WebView 里的同步死循环没法被打断**（实测：引擎
  超时后 `loadHtmlString('')` 排在一个永不空闲的渲染线程后面，整个 App 的
  书源搜索全部卡死，只能重启 App）。所以死循环改成解析阶段判死。
- 自建源 `search.name = <js>var t=Date.now(); while(Date.now()-t<6000){}; …</js>`
  → 报 **「JS 规则执行超过 3 秒，已终止（脚本里可能有死循环）」**，同一次搜索里
  零零小说**照常返回 100 条** —— 证明超时之后引擎还能继续干活。
- 取证图（`docs/screenshots/v*/*.png` 默认不入库）：
  `i3b_capability_badges.png`（可搜索 / 静态 JS 三态）、
  `i3b_real_source_100.png`（真实语料 100 条 + 封面）、
  `i3b_js_timeout_and_results.png`（超时文案 + 同批其它源正常）。

**请求选项与 `{{…}}` 地址模板（v2.79.0，I4 批）**

这一批补的是「挡住搜索的两块地基」，都比 JS 能力更靠底层：

| 问题 | 语料规模 | 以前的后果 |
|---|---|---|
| `searchUrl` 是「地址 + `,{…}` 请求选项」 | 617 个源能解析出合法选项（413 POST / 204 GET），另有 99 个 `,{` 后面不是合法 JSON | 整串当 URL，拼出带花括号的**非法地址**，请求从来没正确过；其中 400 个还被算进「可搜索」 |
| 地址模板里是 JS（`{{page-1}}` / `{{book.name}}`） | 105 个源现在可静态求值（另有 431 个仍跑不了：整条 `<js>`/`@js:`、ajax、变量表、JSONPath） | 一律判「地址模板里是 JS」，整源判死 |

**请求选项字段**（`request_options.dart`，拆开规则见 `parseRequestSpec`）：

| 字段 | 语义 | 本版怎么用 |
|---|---|---|
| `method` | `GET` / `POST`（大小写不敏感） | 真发；其它方法退回 GET 并给 warning |
| `body` | 请求体模板（可含 `{{key}}` / `{{page}}` / JS 表达式） | 真发（替换后再发；`{{key}}` 保持**原文**，不做 URL 编码） |
| `headers` | 附加请求头 | 真发，**覆盖**书源级 `headers` 的同名项（按小写键去重，`Referer` / `referer` 只算一个） |
| `charset` | 请求 / 响应编码 | 只当**解码提示**（响应头仍然优先） |
| `webView` | legado 的「用 WebView 打开」 | 忽略，只记录 |
| `type` | 请求体类型（`json` …） | 忽略，只记录（content-type 按 body 形状判） |

**数字口径（唯一来源）**：本节所有「多少个源」的数字，以
`cd app && dart run tools/js_rule_audit.dart --selectors` 的**表⑨**为准
（2026-11-24 实跑：带合法选项 **617**（413 POST / 204 GET），`,{` 后不是合法
JSON **99**；合计 716 个源的 `searchUrl` 写成「地址 + 逗号花括号」，其中 617
个能真当成选项解析）。旧文档 / 注释里出现过的 **745 / 749** 是早期口径，
统一废弃，别再引用。

- **切分点是最后一个 `,{`**（中间允许空白），不是第一个：地址本身可能带逗号 /
  花括号（`/s?q=a,{"junk":1}`），逐个 `,{` 往后试、取**最后一个能整段 jsonDecode
  成对象**的那个。
- **坏 JSON 退回「整串当地址」+ warning**，不报错：很多源只是地址里恰好有 `,{`，
  或者写的是 JS 对象字面量（单引号）。`parseRequestSpec` 的 `hasOptions` 为假。
- **整条地址是 `<js>` / `@js:` 时不拆选项**：选项往往写在脚本字符串里
  （`url=baseUrl+"/s?q="+key+",{'method':'GET'}"`），拆了只会切坏脚本。
  这类源仍判「跑不了」（I4 只接 `{{…}}` 表达式模板）。

**`{{…}}` 的两种语义**（`applyUrlTemplate`）：

1. **白名单变量**（同步）：**地址里** `key` / `keyword` **URL 编码**（进 query）；
   `page` / `searchPage` / `searchKey`（页码，不编码）、`baseUrl`（站点根，不编码）；
   `tab` 仍不替换（页签语义，搜索侧明确报不支持）。老式 `%s` 只换第一个，保持
   原行为。**请求体走同一套替换但不编码**（`encodeKeyword: false`）：JSON 体
   `{"q":"{{key}}"}` 的值必须是书名本身，编码后变成 `%E6%96%97…` 是错的；而且
   编码后 body 成了纯 ASCII，引擎里「body 含中文 + 声明 GBK → 明确拒绝」那条
   守卫就永远不触发，又回到「200 但 0 条」。
2. **JS 表达式**（异步，空白页求值）：`{{page-1}}` / `{{(page-1)*15}}` /
   `{{book.name}}` / `{{baseUrl.match(/\d+/)[0]}}`。绑定只有 `baseUrl` / `key` /
   `page` / `book` / `source`（+ `sourceComment`），**没有 DOM**：
   `document` / `window` / `location` / `localStorage` 一律判不可跑并提示
   「URL 模板里的 JS 不能访问页面或网络」；`java.ajax` / `Packages` / `java.put`
   / `{{$.id}}`（JSONPath）/ 整条 `<js>` 同样不可跑。
3. 求值结果**原样拼接**（legado 也不编码；“要编码就自己在脚本里 `java.encodeURI`”）。
   `{{key}}` 这种明确的关键词变量仍然编码 —— 两条规则别混。
4. **求值为空 / 求值抛错 → 该源报「地址拼不出来」且不发请求**：半截地址
   （`https://host/`）发出去只会让用户以为「站点没这本书」。

**POST 的 content-type 判据**（`inferContentType`，在引擎里拼）：

| 情况 | content-type |
|---|---|
| 选项 / 书源 `headers` 里显式写了 `content-type`（大小写不敏感） | 用显式的 |
| body 是合法 JSON（`{…}` / `[…]`） | `application/json` |
| 其它（表单串 / 空 / 半截 JSON） | `application/x-www-form-urlencoded` |

- **GET 路径一行没改**：`body == null` 且 `method == GET` 时仍走 `dio.get`，
  请求头 / 超时 / 重定向 / UA / GBK 解码链路完全不变。
- **`charset` 只做解码提示**：优先级仍是「响应头 > 选项 charset > 书源 charset >
  自动判定」。**但 POST 的 body 编码是另一回事**：Dart 没有 GBK 编码器，
  body 里有中文且 charset 是 GBK 时**明确报不支持**（`请求体里有中文且声明为 GBK
  编码…`），不硬发 UTF-8 字节 —— 站点按 GBK 解只会回一个 200 的空结果页，
  「搜得到但 0 条」比报错难查得多。语料里 134 个 POST + gbk 源会命中这条
  （英文关键词不受影响）。

**接线范围**：搜索 `search.url`、目录 `toc.url` / `toc.pages`、正文 `content.url` /
`content.nextPage`、详情 `detail.url` 四处都走同一个 `resolveRequestField`；
`@detailUrl` / `@chapterUrl` / `@page` 这些**本模型自己的**占位符先替换，再交给
`request_options`。健康检测的「验证页复核」也改成与真实搜索同形（POST 源不再用
GET 复核，否则拿到的是另一个页面、会把「被拦」判错）。

**审计重算（同一份 2483 个去重源，四组数字）**

| | I1（v2.76.0） | I2（v2.77.0） | I3b（v2.78.0） | **I4（v2.79.0）** |
|---|---|---|---|---|
| 可搜索 | 495（19.9%） | 754（30.4%） | 1079（43.5%） | **1100（44.3%）** |
| 被 JS 能力挡 | 1176（47.4%） | 1176（47.4%） | 889（35.8%） | **868（35.0%）** |
| 被选择器语法挡 | 302（12.2%） | 43（1.7%） | 5（0.2%） | **5（0.2%）** |
| 缺搜索规则 | 510（20.5%） | 510（20.5%） | 510（20.5%） | **510（20.5%）** |

- 「可搜索」只 +21（+0.8pp），**但这不是本批的实际收益**：审计口径问的是「规则
  能不能被解释」，从来不问「请求发得对不对」。**1100 个可搜索源里有 400 个带请求
  选项（266 个是 POST）** —— 这批以前算「可搜索」却一次都没发出过正确请求，
  这一批之后才真的能搜。地址模板 JS 让「地址模板里是 JS」的源从 504 降到 431，
  其中 105 个源的模板现在可静态求值，73 个源因此摆脱这一条、21 个源整源变可搜索
  （其余被变量表 / `{{…}}` 套规则 / 列表规则 JS 继续挡住）。
- 剩余阻塞构成（一个源可命中多个原因）：地址模板里是 JS **431**、变量表 358、
  与 `\|\|`/`&&` 混写 329、列表规则本身是 JS 192、`{{…}}` 里套选择器规则 153、
  ajax 148、其它不支持接口 145、JSONPath 27。
- 统计口径的两个细节：①「431 + 105 ≠ 504」是因为判据从「整串里有 JS 痕迹」改成
  「拆选项后逐段判」（请求体里的 `{{…}}` 现在也算模板）；② 审计不算
  「POST + GBK 中文 body」这条运行时限制（见上一节），也不算站点可达性。

**本机实测（2026-11-24，模拟器 `bili_test`，`adb install -r`）**

- **真实语料里的 POST 源这批网络下一个都到不了**（先如实记下来）：`69shu`
  连接超时、`ishuquge` 301 到 `xshuquge` 且搜不到、`biquge2023` 域名已变成影视站、
  `qishuzw` 200 但页内 0 条 —— 所以**真实 POST 源未被验证**。
- 改用**宿主机自建 POST 接口**（`10.0.2.2:8899`，模拟器到宿主机回环）验证
  「POST 真的发出去且 body 正确」，两个测试源（用完已从设备上删掉、恢复到原 5 个源）：
  - `searchUrl = http://10.0.2.2:8899/search,{"method":"POST","body":"searchkey={{key}}&p={{page}}","headers":{"X-Opt":"i4"}}`
    → 搜索页 **`I4-POST 测试源 · 2 条`**；服务端日志原文
    `POST /search body=searchkey=i4&p=1 content_type=application/x-www-form-urlencoded x_opt=i4`
    （UA 是引擎的桌面 Chrome UA）—— 方法、body 模板替换、选项 headers、content-type
    四件事一次验全。
  - `searchUrl = http://10.0.2.2:8899/js?p={{page-1}}&q={{key}}`（地址模板 JS）
    → **`I4-JS模板测试源 · 1 条`**；服务端收到 `GET /js?p=0&q=i4`，
    说明 `{{page-1}}` 在第 1 页真的求值成 `0`（服务端只认 `p=0` 才返回结果）。
  - 同一次搜索里 5 个真实源照常各自报「没搜到 / 被拦 / 连不上」，互不影响。
- 取证图（`docs/screenshots/v*/*.png` 默认不入库）：
  `v2.79.0/i4_post_and_js_template_search.png`（两个测试源分组 + 共 3 条）。

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
5. **`@js` 书源：静态子集能跑，其余仍然不支持**（v2.78.0 接线后，v2.79.0 扩到地址模板）。
   `legado_compat.jsUsageOf(source, stage)` 判定，服务层按「能跑就真跑」执行。
   **能跑**：白名单内的纯字符串变换（base64 / md5 / timeFormat / htmlFormat /
   strToBytes / bytesToStr / log）+ 逐行（每个列表节点各跑一次）；**v2.79.0 起**
   地址 / 请求体里的 `{{…}}` 表达式（`{{page-1}}` / `{{book.name}}`）在空白页上求值。
   **不行**：`java.ajax` / `java.connect` / `java.post`（同步 XHR 被 CORS 拦）、
   变量表 `java.put`/`get`/`getString`、`result.select()` 这类 DOM 桥、
   `{{@@a@text}}` 这种「模板里套选择器规则」、列表规则本身是 JS、整条地址是
   `<js>` / `@js:`、`while(true)`/`for(;;)`。UI 上分别标「静态 JS」/「需 JS」/「需 ajax」。
   只在发现页 / 登录页 / init 里用 JS 的源照旧能搜（`JsUsage.unexecutedJs`）。
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
19. **选择器语法三条反直觉的点（v2.77.0，都踩过）**：
    - **`!N` 是「排除」，不是「取第 N 个」**。legado 源码里 `.` 才是选择
      （`split == '.'` → 逐个 add），`!` 是把这些下标置空再 `removeAll`。
      `class.grid@tag.tr!0` 的意思是「除第一行之外的所有 tr」，写成「取第一个」
      会让搜索列表只剩一行。
    - **最后一段 `@某词` 是取值名，不是选择器**。`@content` 是取 `content` 属性
      （`getResultLast` 的 `else` 分支 = `element.attr(name)`）。所以
      `[property=og:novel:category]@content` 能取到值，而
      `class.txt-list@li` 这种「想取 li」的写法在 legado 里其实拿不到东西
      （`attr("li")` 恒空）—— 本版把**结构标签名**当链式段处理（见
      `kLegadoChainTags`），只多跑通、不会弄坏。反过来 `title` / `style` /
      `value` 这些**不能**进那张表：它们作属性名远比作标签名常见。
    - **`##正则##替换###` 尾巴多一个 `##` 是「只替换第一个」**（legado
      `rule.split("##")` 的第 4 段 → `replaceFirst`）。按全局替换处理会把
      `#` / `##` 拼进 URL 尾巴 —— 语料里用 `###` 结尾的规则很多，而且大半是
      在改 URL。
    - 另外：`@get:{x}`（读 `java.put` 的变量）**明确不支持**，解析器报 `js`
      （算「需要 JS」）。`text.xxx` 与 `%%` **v2.78.0 起已支持**（见下一条）。
      绝不「当 CSS 硬跑」—— 那只会静默返回空值。

20. **`text.` 与 `%%` 的语义是查 legado 源码定的，别凭直觉改**（v2.78.0）：
    - `%%` 是**按行交错**：`for (i in results[0].indices) for (temp in results) if (i < temp.size) add(temp[i])`
      —— 外层长度是**第一支**，后面的支更长时多出来的行被丢掉。当成 `&&` 那样
      `addAll` 会把「目录左右两栏」排成「左栏全部、再右栏全部」，整本目录顺序全错。
    - `%%` 与 `&&` 同时出现时，legado `RuleAnalyzer.splitRule("&&","||","%%")` 取
      **先出现**的那个当分隔符（`elementsType`），本版照抄。
    - `text.xxx` 筛的是**自身文字**（jsoup `ownText`），不是子树 text；needle 只取
      第一个 `.` 之前那段（legado 是 `beforeRule.split(".")[1]`）。
    - `text.` 作为**链式段**（`class.a@text.作者`）同样生效，不再整条判死 ——
      v2.77.0 把它当「不支持」的断言已按契约变更加注释改写。

21. **WebView 载页不能死等 `onPageFinished`，JS 字段的 `result` 也不能先转绝对**（v2.78.0）：
    - **死等 `onPageFinished` 会被真实书站拖死**：它要等**全部子资源**（外链 jQuery、
      封面图、统计脚本）。实机实测：阅友小说 / 零零小说的搜索页都因此报
      「页面在 8 秒内没有加载完成」。现在的做法是轮询 `document.readyState`：
      `complete` 立刻放行；2.5 秒后是 `interactive` 也放行（我们只要 DOM）。
    - **轮询必须认「哪一页」**：`loadHtmlString` 的 Future 在平台调用返回时就完成，
      新文档还没 commit —— 直接读 `document.readyState` 可能读到**上一页**
      （尤其是超时后那张空白页）的 `complete`。所以每次载页注入
      `<meta name="amotv-load" content="<token>">`，标记对不上就继续等。
    - **JS 字段的 `result` 不做相对转绝对**：语料里 `h2@a@href@js:'https://x'+result`
      期望 result 是 `/book/123/`；先转绝对再拼会得到 `https://xhttps://m…`。
    - **同步死循环没法打断**：`while(true)` 会把渲染线程占死，超时后
      `loadHtmlString('')` 排不进去，整个 WebView（全 App 共用一个）从此不可用，
      只能重启 App。所以死循环在**解析阶段**就拦（`hasDeadLoop`），不要幻想
      「超时 + 空白页」能救回来。
    - **裸表达式脚本**（`'https://m.x'+result`、`result.match(...)[1]`）要用
      `eval` 取完成值；`new Function` 会把它们当语句丢掉、返回 undefined。

22. **legado 的「地址 + 请求选项」四条硬约定**（v2.79.0，I4 批，都踩过）：
    - **切分点是最后一个 `,{`，而且必须整段能 jsonDecode**。地址本身可能带逗号 /
      花括号；选项里也可能有 JS（`@js:url=baseUrl+"…,{'method':'GET'}"`，单引号）。
      做法是逐个 `,{` 往后试、取最后一个能解成对象的；一个都解不出就**退回整串
      当地址 + warning**（不报错）—— 语料里 99 个源就是这种情况，报错只会让人
      以为源写坏了。
    - **整条地址是 `<js>` / `@js:` 时不要拆选项**：选项在脚本字符串里，拆了就切坏
      脚本。这类源本批仍判「跑不了」（只接了 `{{…}}` 表达式模板）。
    - **POST 的 content-type 不能只看 body 开头是不是 `{`**：显式 `content-type`
      优先；body 是合法 JSON 才算 `application/json`；半截 JSON 仍是表单串。
      GET 路径必须保持原样（`dio.get`、不塞 content-type），否则老源的请求形态
      全变。
    - **GBK 的 POST body 是能力边界，不是 bug**：Dart 没有 GBK 编码器（本地 TXT 那条
      路也只有一个**解码**码表）。body 里有中文 + charset 是 GBK 时明确报不支持；
      硬发 UTF-8 字节，站点按 GBK 解只回一个 200 的空结果页 —— 「搜得到但 0 条」
      比报错难查得多。**这条守卫依赖 body 里还能看见中文**：body 模板若像 URL
      一样做 URL 编码，`斗罗` 变成 `%E6%96%97%E7%BD%97`（纯 ASCII），守卫永远不
      触发，又回到它想避免的 0 条。所以 `resolveRequestField` 对 body 传
      `encodeKeyword: false`，URL 保持编码（2026-11-24 复核修的回归）。
    - **headers 合并要按小写键**：`{...source.headers, ...选项headers}` 只认完全同名，
      `Referer` / `referer` 会**两个都进** Dio，真正发出去哪个由底层折叠决定。
      统一走 `request_options.mergeHeaders`（小写键去重、选项优先、保留选项的大小写），
      搜索 / 详情 / 目录 / 正文 / 健康检测五处共用。
    - **翻页失败不该丢已拿到的结果**：第 2 页起「地址拼不出来 / 抓取失败 / 字段解析
      失败」一律 `break` 保留前面几页，并在分组上挂 `BookSearchGroup.warning`
      （搜索页分组标题下一行小字）。只有**第 1 页**失败才是整源失败 —— 以前第 2 页
      拼不出地址会整组判 unsupported，第 1 页的条目一起消失。
    - **验证页复核要与真实搜索同形**：POST 源用 GET 复核，拿到的是另一个页面
      （有的站 GET 直接回首页），会把「被拦」判成「可用」或反过来。
    - **本地 HTTP 假接口的 baseUrl 不能与被请求 URL 同 host**：`normalizeUrl` 会把
      同站 `http` 升级成 `https`（见坑 18 最后一条）。实测时 baseUrl 写
      `https://example.com`、请求写绝对 `http://10.0.2.2:8899/...`，两者不同 host
      才不会被升级。

23. **「字段相对节点」对 XPath 曾经是假的：`//x` 要补 `.` 才相对**（v2.79.0 实机 bug）：
    - `document.evaluate(query, node, …)` 的第二个参数只是**上下文节点**；规则以 `/`
      开头时 XPath 1.0 规定从**文档根**求值，上下文节点被忽略。于是字段规则里的 `//dt`
      在**每一行**都取到文档里第一个 `dt` —— 「字段相对节点」这条契约对绝对 XPath 不成立。
    - 用户可见表现（真机《闪光的哈萨维》，57 章）：章名规则写成「卷名 + 章名」
      （`//dt[@class='vcss']/text()&&tag.a@text`），结果**每一章都变成「第一卷 琪琪 /
      第一卷 休息室 …」**——第一卷的卷名被刷到全部 57 章上。为什么中间有个空格：`&&`
      两支按 `\n` 拼，`_cleanLine` 把换行压成空格，所以看着像「卷名 空格 章名」。
    - 修法：`js_builder._specMap(v, relative: true)` 在**字段位置**（含链式段 / 回退链 /
      `&&` 与 `%%` 分支）把 `//x` 补成 `.//x`、`/x` 补成 `./x`；**列表规则不补**（它本来
      就该整页查）。带括号的整段表达式 `(//div)[1]` 不补（补了是语法错误 `.(//div)`），
      作者写括号时通常就是要「整页第一个」。单测 `book_rule_js_builder_test` 钉住四种形态。
    - **例外：容器本身是整篇文档时不补**（2026-11-24 复核补的）：详情页拿
      `@css:body` 当容器（没有列表概念），`//meta[@property="og:image"]/@content`
      这类取封面 / 作者的规则里，meta 在 `<head>`、不在 body 里 —— 补成 `.//meta`
      就永远取不到。判据在 `js_builder._fieldsAreRelative`：`body` / `html` /
      空选择器 / `self` 保持绝对，其它选择器照旧相对化。单测同时钉住
      「`@css:body` + `//meta` 仍绝对」与「列表节点里的 `//dt` 仍相对」。
    - **有意的副作用**：把绝对 XPath 写在字段位置的源，以前每行拿到同一个值（看着像能用、
      其实是错数据），现在取不到（null）。按本模块契约这是修正，不是退化。
    - **分卷的卷名与卷容器必须同源对齐**：`_loadVolumes` 以前是两次 `queryFields`（先卷名、
      再每卷 `@html`），两列只能靠下标对齐；现在合成**一次** `queryFieldMap`（`name` +
      `html` 两列出自同一批节点），对齐由构造保证、还少载一次页面。卷名取不到时用
      「第 N 卷」占位，**绝不把第一条卷名刷到所有卷上**。
    - 复现/验证方法（可重跑）：宿主机起三卷 57 章的分卷页（`dt.vcss` 卷名 + `dd > a` 章节）
      + `adb reverse tcp:8080 tcp:8080`，导一条 `toc.volume` 源与一条「平铺 + `//dt` 章名」
      源；回退修法时平铺源逐条「第一卷 XXX」，恢复后为「琪琪 / 休息室 / …」。

---

## 7. 测试与门禁

- 测试目录：`app/test/`，共 273 个 `*_test.dart`（v2.79.0 加 `request_options_test.dart`）；
  `test/live_danmaku_fakes.dart` 与 `test/mobi_test_builder.dart` 是辅助文件（没有
  `main()`；后者文件名不匹配 `*_test.dart`，门禁根本不会把它当测试文件）。
- 当前基线：**273 个文件、7 批、通过用例数见下**（v2.79.0 / I4 批实跑）：

| 项 | 结果 |
|----|------|
| `flutter analyze` | 0 issue（10–70s，冷启动更久） |
| `flutter test` 分批 | 7 批全部通过，合计 **4336** 个用例（v2.76.0 是 4153，I2 批 +32，I3a 批 +53，I3b 批 +31，I4 批 +50，v2.79.0 分卷修复 +6，2026-11-24 复核修复 +11） |
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
| v2.79.0 | **书源请求选项（POST / body / headers / charset）+ `{{…}}` 地址模板 JS（I4 批）**。这两项比 JS 能力更靠底层：`searchUrl` 写成 `"…?q={{key}},{"method":"POST","body":"…"}"`（617 源能解析出合法选项、413 个是 POST）以前被整串当 URL，拼出来的地址带花括号、从来没发出过正确请求；地址模板里是 JS（`{{page-1}}` / `{{book.name}}`）的源被整源判死。① **`request_options.dart`（纯 Dart）**：`parseRequestSpec` 按**最后一个能 jsonDecode 的 `,{`** 拆「地址 / 选项」，坏 JSON **退回整串当地址 + warning**（99 个源是这种），整条 `<js>`/`@js:` 不拆；字段 `method` / `body` / `headers` / `charset` / `webView` / `type`（后两个只记录）。② **两种 `{{…}}`**：白名单变量同步替换（`{{key}}` URL 编码、`{{page}}`/`{{baseUrl}}` 不编码、`{{tab}}` 仍不换）；JS 表达式交给引擎新增的 `evalUrlTemplateJs` 在**空白页**上求值（绑定只有 baseUrl / key / page / book / source），`document`/`window`/`location`、ajax、变量表、DOM 桥、JSONPath、整条 `<js>` 一律判不可跑并说清原因；求值结果原样拼接，**为空 / 抛错就不发请求**（不发半截地址）。③ **引擎 `fetchHtml` 加 `method` / `body`**：POST 的 content-type 判据 = 显式 header > body 是合法 JSON → `application/json` > `application/x-www-form-urlencoded`；GET 路径一行没改；`charset` 仍只做解码提示，**但 body 有中文 + GBK 时明确报不支持**（Dart 没有 GBK 编码器，硬发 UTF-8 字节只会得到 200 的空结果页）。④ **接线**：搜索 / 目录（`toc.url` + `toc.pages`）/ 正文（`content.url` + `content.nextPage`）/ 详情（`detail.url`，以前根本没执行这个字段）四处共用 `resolveRequestField`；`@detailUrl` / `@chapterUrl` / `@page` 先替换再拆选项；健康检测的验证页复核改成与真实搜索同形（POST 源不再用 GET 复核）。⑤ **判定同源**：`legado_compat.jsUsageOf` 先拆选项再判模板，`urlTemplateUsesJs` 删除（改为 `inspectUrlTemplate` + `resolveRequestField` 报具体原因）；`runnableJs` 起把「地址模板可求值」算进可跑。⑥ **审计重算**（同一份 2483 源）：可搜索 1079（43.5%）→ **1100（44.3%）**，被 JS 挡 889→868；地址模板 JS 从 504 降到 431，其中 105 个源的模板现在可求值。**「可搜索」只 +21 是因为审计口径只看「规则能不能被解释」——1100 个里 400 个带请求选项（266 个 POST），这批以前算可搜索却发不出正确请求，本批之后才真能搜**。⑦ **实机（模拟器 `bili_test`，`adb install -r`）**：真实 POST 源这批网络下一个都到不了（69shu 超时 / ishuquge 301 / biquge2023 域名已变影视站 / qishuzw 无匹配），改用宿主机自建 POST 接口：POST 源搜到 2 条、地址模板 JS 源搜到 1 条，服务端日志留下 `POST /search body=searchkey=i4&p=1 content_type=application/x-www-form-urlencoded x_opt=i4` 与 `GET /js?p=0&q=i4`。新增 56 个用例（`request_options_test` 新文件 + 引擎 POST 形态 / 搜索 POST 与模板 / 目录 / 正文），既有断言只改了一条（URL 字段 JS 从「一定不可跑」改为「表达式可跑、整条 JS 不可跑」，已按契约变更加注释）。⑧ **同版本内另修：分卷目录「每一章都带第一卷」**。字段位置的 XPath 是**绝对路径**（`//x` 从文档根求值，`document.evaluate` 传节点无效），于是章名规则`//dt[@class='vcss']/text()&&tag.a@text`（卷名 + 章名）让 57 章全变成「第一卷 XXX」；`js_builder._specMap(..., relative: true)` 在字段 / 链式段 / 回退链 / 并列分支里把`//x` 补成 `.//x`（列表规则保持整页查询，`(//div)[1]` 原样），`_loadVolumes` 把「卷名」与「每卷 innerHTML」从两次 `queryFields` 合成一次 `queryFieldMap`（同一批节点，对齐由构造保证）。实机（模拟器 `bili_test`，宿主机三卷 57 章夹具 + `adb reverse`）：回退修复时平铺源逐条「第一卷 琪琪 / 第一卷 休息室 …」（与用户截图逐字一致），恢复后为「琪琪 / 休息室 / …」；分卷源显示「3 卷 · 第一卷 11 章 / 第二卷 23 章 / 第三卷 23 章」。新增 6 个用例（`book_rule_js_builder_test` 4 / `book_detail_service_test` 2），既有分卷用例只按新的「一次查询」形态改了夹具，断言一条没放宽。 | `services/book_rule/request_options.dart`（新）、`services/book_rule/rule_engine.dart`、`services/book_rule/legado_compat.dart`、`services/book_search_service.dart`、`services/book_detail_service.dart`、`services/book_content_service.dart`、`services/book_source_health_service.dart`、`app/tools/js_rule_audit.dart`、`test/request_options_test.dart`（新）、`test/book_rule_engine_test.dart`、`test/book_search_service_test.dart`、`test/book_detail_service_test.dart`、`test/book_content_service_test.dart`、`test/legado_compat_test.dart`、`services/book_rule/js_builder.dart`、`test/book_rule_js_builder_test.dart` |
| v2.78.0 | **书源静态 JS 接线 + `text.` / `%%`（I3b 批）**。I3a 的内核（分类器 / 白名单 / 沙箱）此前只产判定、不接线，用户可见行为为零；这一批把它接进搜索 / 详情 / 目录 / 正文，并按 legado 源码补两种语法。① **一次查询只载一次页**：`queryFieldMap` 新增可选 `bindings`，选择器列与**逐行** JS 列合成一段脚本（`js_builder.buildQueryFieldsMixedJs`）—— 节点只查一遍，JS 字段**每个节点各跑一次**（`js_rule.buildJsRunnerFactory` 编一次调 N 次）；逐字段载页是 6 倍等待，逐行 `evalJsRule` 是 N 倍往返。② **两种脚本形态都能跑**：语料里大量脚本是裸表达式（`'https://m.x'+result`、`result.match(/(\d+)\/)[1]`），`new Function` 会把它们当语句丢掉（返回 undefined）→ 工厂先用 `eval(__src)` 取**完成值**（Rhino `script.eval` 语义），取不到再退回 `new Function`（那条路支持顶层 `return`）。③ **`result` 初值不转绝对**：`h2@a@href@js:'https://x'+result` 的 result 应是页面里的 `/book/123/`；先转绝对会拼出 `https://xhttps://m…`（整列详情页打不开，实测踩到）。④ **`text.` / `%%` 按 legado 源码实现**：`text` = `getElementsContainingOwnText`（ownText、needle 只取到第一个 `.`）；`%%` = **按行交错**、外层取第一支长度、后面的支多出来的行丢掉；`%%` 与 `&&` 同时出现按**先出现的**切（`elementsType`）。⑤ **收紧判定**（避免静默错值）：`result.select()/attr()/parentNode()` 这类 DOM 桥、`book.`/`source.`/`chapter.` 上**没绑定**的属性（`'x'+book.tocUrl` 会得到 `xundefined`）、`cookie.`/`cache.`/`eval(`、`{{@@a@text}}` 这种**嵌套规则模板**、**可见死循环**（`while(true)`/`for(;;)`，实测会把整个 WebView 卡死、只能重启 App）；`blockReason` 给审计工具分档。⑥ **阶段判定**：`jsUsageOf(source, stage)` 只看那一段（只有 `toc.url` 是 JS 的源不再被搜索判死）；能力档 `sourceCapabilityOf` = 可搜索 / 静态 JS / 需 JS。⑦ **健康状态**加 `needsAjax`（与「需 JS」分开：一个等版本、一个要改源），`unsupportedJs` 语义收窄成「补个函数也补不出来」；**静态 JS 的源真的去探测**，「检测全部」不再跳过它；书源页每行加能力角标，搜索页脚注改成「需要 JS 的书源（ajax / 变量表）」。⑧ **载页不再死等 `onPageFinished`**：真实书站挂外链 jQuery / 封面图，8 秒都等不到（阅友小说、零零小说实测都卡这一步）→ 改成轮询 `document.readyState`（`complete` 立刻放行，2.5 秒后 `interactive` 也放行），并用注入的 `<meta name="amotv-load" content="token">` 确认「是这一页」（`loadHtmlString` 的 Future 早于 commit，否则会读到上一页的 `complete`）。⑨ **审计重算**（同一份 2483 源）：可搜索 **754（30.4%）→ 1079（43.5%）**，被 JS 挡 1176→889，被选择器语法挡 43→**5**；分类表新增 `jsStaticRunnable` **252**、`jsTransformOnly` 503→252。剩余不可搜：地址模板是 JS 504、变量表 358、与 `\|\|`/`&&` 混写 329、列表规则是 JS 192、`{{…}}` 套规则 153、ajax 148、其它接口 145、JSONPath 27。⑩ **实机（模拟器 bili_test，`adb install -r`）**：真实语料源 **零零小说**（`jsStaticRunnable`，封面地址是 `<js>` 算的）搜「凡人」→ **100 条 + 封面**；`while(true)` 源被静态拦下（脚注点名）；`var t=Date.now(); while(Date.now()-t<6000){}` 源报「JS 规则执行超过 3 秒，已终止」而**同批的零零小说照常 100 条**。⑫ **索引选择页**同样分三档：`BookSourceIndexResult` 加 `staticJsKeys`（`staticJs` / `staticJsCount`），行角标「静态 JS」不再被「只看能直接搜索的」筛掉，汇总写「另有 N 个用静态 JS，本版能搜」。⑬ 契约变更（既有断言改写，不是删）：`text.` / `%%` 从 `unsupported` 改为可执行；`book_rule_selector_test` 的「链上任一段不支持」改用 `regex:` 空源验证同一铁律；页面 / 健康测试里「静态 JS 源被判死」的夹具换成 `java.ajax` | `services/book_rule/selector.dart`、`js_rule.dart`、`js_builder.dart`、`legado_compat.dart`、`rule_engine.dart`、`services/book_search_service.dart`、`book_detail_service.dart`、`book_content_service.dart`、`book_source_health_service.dart`、`pages/book_search_page.dart`、`pages/book_source_page.dart`、`app/tools/js_rule_audit.dart`、`test/js_rule_test.dart`、`test/book_rule_selector_test.dart`、`test/book_rule_js_builder_test.dart`、`test/legado_compat_test.dart`、`test/book_search_service_test.dart`、`test/book_detail_service_test.dart`、`test/book_content_service_test.dart`、`test/book_source_health_service_test.dart`、`test/book_search_page_test.dart`、`test/book_source_page_test.dart` |
| v2.77.0 | **书源选择器补语法（I2 批）：链式 / 索引 / `&&` 并列 / 扩展取值**。先量后做 —— `app/tools/js_rule_audit.dart` 加 `--selectors` 模式（**import 真的 `selector.dart`**，不再维护第二份判定；参数可以是 URL 也可以是本地文件），对同一份 2483 个去重源、27175 条非 JS 执行字段规则串统计出语法特征：链式 58.6%、`.N` 59.4%、`!N` 15.7%、`&&` 25.1%、`@属性名` 42.0%、`@textNodes` 18.2%、`text.` 1.4%、`%%` 0.2%。按这张表只做高频且语义能从 legado 源码确认的：① **`@` 链式**（`p.1@a.0@text` / `class.grid@tag.tr!0`）：`selector.dart` 按 `@` 切段逐段收窄（引号 / 括号 / `##` 内不切，XPath 属性轴 `/@content` 不切），`js_builder` 的 `queryAll` 递归展开；② **索引**：`.N` = **选**、`!N` = **排除**（legado `ElementsSingle` 两个分支的原义，`.0:1:2` 是索引列表，负数从末尾数），`applyIndex` 在每一段上生效；③ **`&&` 并列**：各支取一遍后按 `\n` 拼（`getStringList` 的 `addAll` + `getString` 的 `join("\n")`），`legadoSelector` 不再把 `&&` 判死；④ **取值后缀扩展**：最后一段裸词当属性名（`@content` / `@data-original`，语料 1044 源）、`@ownText` / `@textNodes` / `@all`、`children`、只有 `##正则##替换` 的规则退化成「取自身」、`##…##替换###` 按 legado 的第 4 段切「只替换第一个」；⑤ 段尾裸标签名（`@li` / `@a` / `@tr`，660 源）当**链式段**而不是属性名 —— 那些规则在 legado 里是 `attr("li")` 恒空，当链式只多跑通不会弄坏（`kLegadoChainTags` 故意不收 `title` / `style` / `value`）。**明确不做**：`text.xxx`（1.4%，报 `text`）、`%%`（0.2%，报 `interleave`）、`@get:` / `@put:`（改判「需要 JS」，原来错报「语法不认识」）。⑥ **效果**：真正可搜索的源 **495（19.9%）→ 754（30.4%）**，被选择器语法挡的源 302（12.2%）→ **43（1.7%）**；剩下 43 个里 `@get:` 31、`text.` 9、`%%` 3。⑦ 验证：新增 34 个用例（真实语料规则串做夹具，不是理想形态）；`flutter test` 没有 JS 引擎，所以另用 `node` + 几十行假 DOM 跑生成的脚本，验了「`!0` 跳过第一行 / `.2` 选中第 3 个 / `&&` 按 `\n` 拼 / `@textNodes` / `children` / `###` 只替换一次」六件事。⑧ 契约变更（一条既有断言）：`legadoSelector('… && …')` 从 `unsupported` 改为可执行（`&&` 真支持），断言改成「两支都在 `concat` 里」并补 `%%` 仍不支持的断言 | `services/book_rule/selector.dart`、`services/book_rule/js_builder.dart`、`services/book_rule/legado_compat.dart`、`app/tools/js_rule_audit.dart`、`test/book_rule_selector_test.dart`、`test/book_rule_js_builder_test.dart`、`test/legado_compat_test.dart` |
| v2.76.0 | **书源 JS 判定精确化（P0）+ 真实语料抽样审计（I1 批）**。① 新工具 `app/tools/js_rule_audit.dart`（纯 `dart:` 标准库，`dart run app/tools/js_rule_audit.dart` 直接跑，可选 `--json <仓外路径>`）：拉 4 个公开索引、按**本 App 实际执行的字段**把每个源分成 `noJs` / `jsInUnexecutedField` / `jsTransformOnly` / `jsUnsupportedApi` / `jsNeedsJsonPath` / `jsNeedsAjax`，打五张表（总量、各分类 top10、`java.*` 频次、三种 JS 写法占比、需 ajax 的源里同时需 JSONPath 的比例）。**语料与产物不入库**。② 真实数字（2483 个去重源，2026-11-23）：`noJs` 48.8%、`jsInUnexecutedField` 2.4%、`jsTransformOnly` 20.3%、`jsUnsupportedApi` 2.8%、`jsNeedsJsonPath` 14.4%、`jsNeedsAjax` 11.3%。旧口径（扫整份 raw）判死 50.6% ≈ 流传的「51%」；新口径 48.2%，P0 净救回 **60 个（2.4%）**。门槛：P0+P1 覆盖 22.7% ≥ 20% → 值得做；ajax+jsonPath 25.7% < 60% → P2 不是唯一路径。`jsTransformOnly` 里 496/503 不调任何 `java.*`。③ `legado_compat.dart` 新增 `JsUsage{executedJs, unexecutedJs, executedFields, blockedApis}` 与 `jsUsageOf(source)`：只有 `search.*` / `detail.*` / `toc.*` / `content.*` 里会执行的字段有 JS 才判死；`exploreUrl` / `loginUrl` / `checkKeyWord` / `init` / `preUpdateJs` / `ruleExplore.*` / `ruleContent.replaceRegex` 里的 JS 不算（`raw` 里已映射字段仍扫一遍并按模型字段名去重，手搓源也不漏判）。`usesJs` 变成 `jsUsageOf(...).executedJs` 的**薄视图**（签名不变，5 处调用点零改动）。④ UI 口径统一：书源管理页每行加「部分 JS（不影响搜索）」小字（这类源照常被「检测全部」探测）；索引选择页筛选文案改「只看能直接搜索的」，`BookSourceIndexResult` 加纯增量 `partialJsKeys` / `partialJs(s)` / `partialJsCount`，行角标分「需 JS」（红）与「部分 JS」（accent）；健康检测与搜索失败文案改成点名具体字段（`search.list 等需要 JS 规则…`）。⑤ 契约变更（两条既有断言）：`checkKeyWord` 里的 JS 从「判死」改为「不判死 + 记 `unexecutedJs`」；并补 `ruleSearch.bookList` 用 JS 仍判死的断言。原以为会冲突的 `detail.wordCount` 断言**保持原样**——`book_detail_service._detailFields` 确实会执行它，属于执行字段。⑥ 端到端：抽样里的 `手机小说下载网`（`ruleBookInfo.init` 里 `org.jsoup` + `java.ajax`，搜索/目录/正文全是普通 CSS）作为真实语料 fixture 进单测；真实页面 `curl` 验证 `search.php?...searchkey=凡人` 200、`.listBox ul li` 命中 100 条（书名可读）。**已知边界**：不少源在不依赖 JS 的同时还用了 `@tag.` / `@a.0` / `p.1@a.0@text` 这类本版不认的选择器写法，P0/P1 不解决这些 | `services/book_rule/legado_compat.dart`、`app/tools/js_rule_audit.dart`（新）、`services/book_source_index_service.dart`、`services/book_source_health_service.dart`、`services/book_search_service.dart`、`pages/book_source_page.dart`、`pages/book_source_picker_page.dart`、`pages/book_search_page.dart`、`test/legado_compat_test.dart`、`test/book_source_index_service_test.dart`、`test/book_source_picker_page_test.dart`、`test/book_source_page_test.dart`、`test/book_search_page_test.dart`、`docs/DEV_CONTEXT.md` |
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
