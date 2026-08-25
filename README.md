# B站白名单点播（bili-whitelist）

**防短视频成瘾的内容白名单系统**：在电脑上自由浏览 B 站并标记你想看的视频，手机 App 只能点播这些白名单视频——刷手机时只有你事先选好的内容，没有信息流、没有推荐；唯一加内容的途径是在 App 内**手动粘贴 B 站分享链接**导入（有意识导入已知想看的视频）。

```
[PC]  浏览器自由浏览 → 一键"加入白名单"（油猴脚本直连 Gist）
[App] 手机上只能播放白名单里的视频 → 刷不到新内容 → 防沉迷的硬约束
```

---

## 目录

- [开发理念](#开发理念)
- [功能特性](#功能特性)
- [界面截图](#界面截图)
- [技术栈](#技术栈)
- [架构与数据流](#架构与数据流)
- [核心实现方法](#核心实现方法)
- [目录结构](#目录结构)
- [使用方法](#使用方法)
- [构建与测试](#构建与测试)
- [数据模型 v3](#数据模型-v3)
- [安全与合规声明](#安全与合规声明)
- [已知限制](#已知限制)
- [许可证](#许可证)

---

## 开发理念

本项目围绕三条原则设计，先决策、后娱乐，把"防沉迷"做成系统约束而不是意志力博弈：

- **先决策，后娱乐（核心哲学）**：内容消费前必须先经过一个"决策环节"——在电脑上挑选、标记想看的内容；手机端只负责执行娱乐（播放白名单），不承担决策。你在电脑上有意识地选择，在手机上无意识地观看。
- **手机端仅白名单 + 主动导入**：App 只能看白名单，加内容的途径只有两条——**手动粘贴 B 站分享链接**或**主动搜索后逐条确认加入白名单**（搜索结果不会自动进列表，必须手动确认才入库）。没有推荐流、热榜、信息流入口，也不依赖 B 站收藏体系，**"随手刷到一个新视频"在物理上不可能发生**——这是防沉迷的硬约束，不是靠自觉。
- **数据独立于 B 站**：白名单是自持的 JSON（存在 GitHub Gist），不依赖 B 站的收藏体系。B 站接口怎么变，最多影响"播放"这一环，**伤不到"白名单数据"**——换播放方案即可，数据永远在你自己手里。

---

## 功能特性

### PC 端（Python CLI + 油猴脚本）

| 模块 | 说明 |
|------|------|
| `whitelist.py` CLI | 白名单管理：`add`（加视频）/ `remove`（删）/ `list`（列表）/ `serve`（本地 HTTP 服务，App 拉取）/ `push`（同步 Gist）/ `collection`（合集管理） |
| 油猴脚本 | B 站视频页双击按钮 → 配置 `github_token` + `gist_id`；单击 → 一键加入白名单。**直连 GitHub Gist，零本地服务** |
| `start-whitelist.bat` | 一键启动本地 `serve`（可选，供 App 备用拉取通道） |

### 同步（GitHub Gist）

- 白名单以 `whitelist.json`（数据模型 **v3**）存于 GitHub Gist，支持多 P（分 P 选集）与合集
- PC / App 双端都通过 Gist 读写，实时 API 优先（规避 CDN 缓存）

### App 端（Flutter Android）

- 白名单列表展示（封面 / 标题 / UP 主 / 时长）
- **合集管理**：Tab 分类、新建 / 重命名 / 删除 / 移动视频到合集
- **多 P 选集**：播放页切换分 P
- **DASH 1080P 播放**：video + audio 双流合并播放；流 URL 过期自动续播
- **倍速九档**：0.5x – 3x，长按 2x 快捷
- **听视频模式**：纯音频播放（关屏可听）
- **登录**：WebView 内嵌 B 站官方登录页（短信验证码），登录态自动续期
- **GitHub token 配置**：App 内填写，安全存储
- **离线缓存**：播放页一键下载到本地（单集 / 全部集），**断网可播放**已缓存视频（播放优先走本地文件）；缓存管理（查看 / 删除 / 清空 / 总大小），列表页显示「已缓存」标记
- **本地导入**：粘贴 B 站分享链接 / 文本（支持完整链接、b23.tv 短链、裸 BV 号）一键导入白名单，与电脑端油猴脚本等效
- **搜索**：两 Tab ——「全部 B 站」调 B 站 wbi 搜索接口（标题 / UP 主），结果可**一键加入白名单**；「我的白名单」本地过滤已有内容。搜索结果不自动入库，逐条确认后才加入
- **多选批量管理**：长按卡片进入多选模式，勾选多条后**批量移动到合集** / **批量删除**
- 版本号显示（列表页底部）

---

## 界面截图

> 截图来自 Android 模拟器（1080x2400），数据源为 GitHub Gist 白名单（5 个视频）。

**图 1：白名单列表页** —— 顶部 Tab 按合集分组（全部 / 各合集 / 未分类），中部为视频卡片（封面、标题、UP 主、时长），底部"管理合集"入口与版本号。

![](docs/screenshots/app_list.png)

**图 2：合集管理面板** —— 新建 / 重命名 / 删除合集（删除只把视频移回未分类，不删视频）。

![](docs/screenshots/app_collections.png)

**图 3：播放页** —— DASH 双流播放 + 控制层（选集 / 倍速 / 听视频 / 进度条）。视频画面在模拟器截图中显示为黑，是模拟器 SurfaceView 截图限制，实机播放正常。

![](docs/screenshots/app_player.png)

**图 4：倍速弹窗** —— 0.5x – 3x 共九档倍速。

![](docs/screenshots/app_speed.png)

> 油猴脚本效果：PC 端 B 站视频页标题右侧的"⭐ 加入白名单"按钮（单击加白 / 双击配置）为 Tampermonkey 扩展注入，本机未安装 Tampermonkey，未能生成对应截图，用法见[使用方法](#使用方法)。

---

## 技术栈

| 端 | 技术 |
|----|------|
| PC 脚本 | Python 3（标准库 + requests，仅 `push` 用到） |
| 油猴脚本 | Tampermonkey，`GM_xmlhttpRequest` 直连 Gist API |
| 同步 | GitHub Gist API（`api.github.com`，实时读写） |
| App | Flutter（Dart）2.3.0+6 |
| App 网络 | dio（全局头 / Cookie 注入） |
| App 播放 | 原生 Kotlin 插件：AndroidX Media3（ExoPlayer）`MergingMediaSource` 合并 DASH 双流 |
| App 登录 | webview_flutter（内嵌 B 站官方登录页） |
| App 安全存储 | flutter_secure_storage（SESSDATA / token） |
| App 其他 | crypto（WBI 签名 md5）、package_info_plus（版本号）、path_provider、shared_preferences |

---

## 架构与数据流

```
                    ┌────────────────────────────────────────────┐
                    │              GitHub Gist                   │
                    │      whitelist.json（数据模型 v3）           │
                    └────────────────────────────────────────────┘
                       ▲ GET / PATCH（api.github.com 实时 API）
                       │
        ┌──────────────┴───────────────┐
        │                              │
[电脑] B站视频页                   [手机] App
   │   油猴脚本                        │  刷新 ← GET Gist
   │   "加入白名单"                    │   白名单列表（封面/多P/合集）
   │   PATCH Gist                      │   ↓ 点击播放
   │                                  │   播放页：playurl 实时取流
   └── 管理操作（合集/删除/移动）       │   → DASH(video+audio .m4s) 合并播放
        PATCH Gist → 刷新              │   → 流过期 → onUrlExpired 自动重取续播
```

- **写路径**：PC 油猴脚本（或 App 的管理操作）→ PATCH Gist → 数据持久化
- **读路径**：App 刷新 → GET Gist（实时 API）→ 白名单列表 → 播放页实时调 `playurl` 接口取流
- **播放数据流**：App 拿到 playurl 的 DASH 双流 URL → 原生 ExoPlayer `MergingMediaSource` 合成播放

---

## 核心实现方法

### 1. WBI 签名（B 站接口访问凭证）

B 站部分接口（如 `playurl`）要求 WBI 签名：

- 匿名请求 `nav` 接口拿到 `wbi_img`（`img_url` / `sub_url`），从 URL 文件名提取两个 key
- `mixinKey` = 按 64 项置换表 `_mixinKeyEncTab` 从 `img_key + sub_key` 拼接串中取前 32 位
- 签名过程：参数字典附加 `wts` 时间戳 → 去除参数值非法字符 `!'()*` → 按 key 排序 → urlencode → `md5(编码串 + mixinKey)` → 得到 `w_rid`
- 签名随请求参数一起发送；key 会过期，App 里自动重取

（算法由本项目从 `probe.md` 实测数据逐行实现，未复制任何 GPL 源码；`wbi/wbi_signer.dart` 附实测 golden 值。）

### 2. B 站 API 风控应对

- 请求带完整浏览器头（UA / Referer / Origin 等），模拟真实客户端
- 2026-08 起 B 站对匿名接口有额外限制（实测记录在 `probe.md`）——项目按实测结论调整请求策略
- **限速与指数退避**：请求失败按退避策略重试，避免触发风控封禁

### 3. 播放链路（DASH 双流 + 防盗链 + 续播）

- `playurl` 接口返回 DASH 格式：video（`.m4s`）与 audio（`.m4s`）两条独立流
- App 用原生 Kotlin 插件：AndroidX Media3（ExoPlayer）`MergingMediaSource` 将两路合并成一路播放
- **防盗链**：B 站要求请求带 `Referer: https://www.bilibili.com` + 浏览器 UA，**两者缺一不可**，否则 403
- **流 URL 数分钟过期**：插件检测到流失效（`onUrlExpired` 事件）→ Dart 层重新请求 `playurl` → `seekTo` 当前位置续播，用户无感

### 4. 登录（WebView 短信 + 自动续期）

- WebView 内嵌 B 站**官方登录页**，短信验证码登录（绕开扫码对 B 站 App 的依赖）
- 登录成功后从 Cookie 提取 `SESSDATA` / `bili_jct`，并保存 `refresh_token`
- `SESSDATA` 有效期内直接复用；过期时用 `refresh_token` 自动换新，无需重新登录

### 5. 多 P 视频

- `pages` 字段存全部分 P（`cid` / `part` / `duration`）
- App 播放页识别多 P 视频，展示选集 UI，切换分 P 时重取对应 cid 的流

### 6. 合集（数据模型 v3）

- 顶层 `collections` 数组定义合集（`name` + `created_at`），每条视频用 `collection` 字段引用
- **引用一致性**：重命名合集 = 改 `collections` 里的名字 + 同步所有 `videos.collection` 引用；删除合集 = 移除定义 + 该合集下视频 `collection` 置空（回到未分类），**不删视频**
- PC 端 `whitelist.py collection rename/delete` 与 App 端语义完全一致

### 7. Gist CDN 缓存规避

- 公开 Gist 的 raw 链接有 CDN 缓存，刚写入立刻读取可能拿到旧数据
- 管理操作与刷新**优先走 `api.github.com` 实时 API**（GET/PATCH），绕开 CDN

### 8. 离线缓存（流数据下载 + 本地播放）

- 下载走实时 `playurl` 取流（DASH video+audio 双流，无 DASH 降级 mp4 单流），**仅带 Referer + 浏览器 UA、不带 cookie** 下载（与在线播放同一套防盗链策略）
- 媒体文件存应用文档目录 `video_cache/`，元数据 `cache_index.json`；下载用 `.part` 半成品 + 成功后 rename，失败自动清理并重试一次
- **串行下载队列**：同时只允许一个下载、任务间留间隔（B 站对高频请求风控，串行更稳），多 P「全部集」逐集入队顺序下载
- **播放优先本地**：已缓存的集直接播本地文件（无网络、无流 URL 过期问题），未缓存的走在线取流
- 缓存管理：单集删除 / 一键清空 / 总大小统计（UI 层确认后删除）；列表页封面角标显示「已缓存」标记（多 P 部分缓存显示 `已缓存 n/m`）

### 9. 本地导入（分享链接解析）

- 解析顺序：文本里的**裸 BV 号**（含完整链接内嵌 BV，无需网络）→ `bilibili.com/video/BV..` 完整链接（兜底）→ **b23.tv 短链**（请求跟随 301/302 重定向，从最终 URL 提取 BV；带浏览器 UA + Referer 防反爬）
- 多链接文本只取第一个；解析失败 / 短链重定向失败均给出中文提示
- 导入流程：解析 BV → 调 B 站接口取视频元数据（标题/UP 主/封面）→ 拉取当前 Gist 按 bvid 查重 → 合并写回并刷新（与电脑端油猴脚本同一写路径）

### 10. 搜索（B 站 wbi 搜索 API + 指纹）

- 复用第 1 节的 WBI 签名：请求搜索接口同样带 `wts` + `w_rid` 签名，外加浏览器 UA / Referer 指纹与限流退避（与播放链路同一套风控应对）
- 「全部 B 站」Tab 调搜索接口按关键词查（视频标题 / UP 主），结果归一化为本地 `SearchResult` 模型展示；「我的白名单」Tab 直接对本地白名单数据按标题/UP 主做子串过滤，无需网络
- 一键加入复用第 9 节同一写路径（`WhitelistWriter`：构造 v3 数据 → Gist 实时 API 写回 → 查重合并），与手动导入/电脑端油猴脚本完全一致

---

## 目录结构

```
bili-whitelist/
├── README.md                  # 本文档
├── .gitignore                 # 敏感/隐私文件一律不入库
├── whitelist.py               # PC 端白名单管理 CLI（add/remove/list/serve/push/collection）
├── bili-whitelist.user.js     # 油猴脚本（v2.3.0，B 站视频页一键加白名单，直连 Gist）
├── start-whitelist.bat        # 一键启动本地 serve（可选）
├── sync_config.example.json   # GitHub 配置示例（token/gist_id 占位，真实配置在 sync_config.json，已 gitignore）
├── whitelist.example.json     # 白名单数据示例（v3 结构，纯假数据；真实 whitelist.json 已 gitignore）
├── probe.py / probe.md        # 技术侦察：B 站接口实测脚本与报告（2026-08）
├── probe_1080p.py / probe_1080p.md
└── app/                       # Flutter Android App
    ├── pubspec.yaml
    ├── lib/                   # Dart 源码
    │   ├── main.dart / config.dart
    │   ├── api/               # bilibili_api.dart（WBI+playurl）、github_api.dart（Gist 同步）
    │   ├── cache/             # download_manager.dart（离线缓存下载管理器，串行队列）
    │   ├── models/            # whitelist_video.dart（v3 数据模型 + 合集管理逻辑）
    │   ├── pages/             # login_page / playlist_page / player_page
    │   ├── player/            # bili_dash_player.dart（DASH 播放控制器）
    │   ├── services/          # service_locator.dart
    │   ├── sync/              # whitelist_source.dart（白名单数据源）
    │   ├── utils/             # import_parser.dart（本地导入解析：完整链接/短链/BV）
    │   └── wbi/               # wbi_signer.dart（WBI 签名器）
    ├── android/               # 原生层（Kotlin 插件：ExoPlayer DASH 播放）
    ├── test/                  # 单元测试（WBI 签名/数据模型/合集管理/同步等）
    ├── build_release.sh / build_release.bat   # release 构建入口
    └── tools/                 # 辅助工具
```

---

## 使用方法

### 1. 油猴脚本（PC 加白名单）

1. 安装 Tampermonkey 浏览器扩展
2. 新建脚本，粘贴 `bili-whitelist.user.js` 内容保存
3. 打开任意 B 站视频页，**双击**脚本按钮 → 弹窗配置 `github_token`（GitHub PAT）与 `gist_id`（你的白名单 Gist）
4. 之后**单击**按钮即可把当前视频加入白名单（直连 Gist，无需本地服务）

### 2. App（手机点播）

1. 构建：`app/build_release.bat`（或 `bash app/build_release.sh`），产物在 `build/app/outputs/flutter-apk/`
2. 安装 APK 到手机
3. 打开 App → 设置里填写 GitHub token 与 gist_id（与油猴脚本同一份配置）
4. **登录**：WebView 短信验证码登录 B 站（登录态自动续期）
5. 刷新白名单 → 开始点播

### 3. PC CLI（可选）

```bash
python whitelist.py list                                        # 查看白名单
python whitelist.py add BV1xxxx [BV2yyyy ...]                   # 加视频
python whitelist.py add BV1xxxx --p 2 --collection 动画         # 指定分P + 合集
python whitelist.py remove BV1xxxx                              # 删视频
python whitelist.py collection list|add <名>|rename <旧> <新>|delete <名>   # 合集管理
python whitelist.py push                                        # 手动同步 Gist（需 sync_config.json）
python whitelist.py serve --port 8124                           # 本地 HTTP 服务（可选）
```

---

## 构建与测试

```bash
# App（推荐直接跑脚本，自动处理国内镜像 + JDK 环境）
bash app/build_release.sh          # 或双击 app/build_release.bat
# 等价命令：
cd app && flutter build apk --release --split-per-abi

# App 单元测试
cd app && flutter test

# 静态分析
cd app && flutter analyze

# PC 端（标准库为主，直接运行）
python whitelist.py list
```

> App 构建需要 Android SDK + JDK（构建脚本已设置国内 pub 镜像 `pub.flutter-io.cn`）。

---

## 数据模型 v3

`whitelist.json`（存于 Gist）结构：

```json
{
  "version": 3,
  "updated_at": "ISO 8601 UTC",
  "collections": [                       // v3 新增：合集定义
    { "name": "动画", "created_at": "ISO 时间" }
  ],
  "videos": [
    {
      "bvid": "BV1xxxx",
      "cid": 123456,
      "title": "视频标题",
      "cover": "https://封面图url",
      "duration": 600,                   // 秒
      "up_name": "UP主",
      "added_at": "ISO 8601 UTC",
      "collection": "动画",               // 所属合集名；空串 = 未分类
      "pages": [                          // v2 起：分 P 列表（多 P 视频）
        { "cid": 123456, "part": "P1 标题", "duration": 300 }
      ]
    }
  ]
}
```

- 老版本数据（v1/v2）读取兼容：缺 `pages` 视为单 P，缺 `collection` 视为未分类
- 任何端写回 Gist 时统一规范化：`version=3`、刷新 `updated_at`、`collections` 必出
- 字段含义见 `app/lib/models/whitelist_video.dart` 与 `whitelist.py` 头部注释

---

## 安全与合规声明

> ⚠️ **仅供个人学习使用，请勿公开分发或商用。**

- 项目使用 **B 站非官方接口**（WBI 签名、`playurl` 取流等），未获得 B 站官方授权
- **2026 年 B 站已对类似项目采取法律行动**（如 bilibili-API-collect 项目永久关停），请知晓风险、低调使用
- 敏感文件**绝不入库**（`.gitignore` 已强制排除）：
  - `sync_config.json`（GitHub token）
  - `cookie.txt`（B 站完整登录 cookie）
  - `whitelist.json`（真实白名单数据，仓库只提供 `whitelist.example.json` 假数据示例）
  - `*.keystore` / `key.properties`（App 签名密钥）

---

## 已知限制

- **依赖 `api.github.com` 可达性**：国内网络访问 GitHub API 可能不稳定，刷新/同步可能间歇失败（可重试）
- **Gist 公开 raw 有 CDN 缓存**：App 已用实时 API 规避，但极端情况仍可能读到旧数据
- **B 站接口可能随时变化**：WBI 签名、playurl 风控策略都在演进，接口变更时需跟随 `probe.md` 的实测方法重新适配
- App 仅支持 Android（iOS 未做）；播放依赖 B 站接口返回的 DASH 流可用性

---

## 许可证

本项目**仅供个人学习使用**，未经作者许可请勿分发或商用。未套用任何标准开源许可证（代码不构成公开发布）。

---

*配套技术文档：`probe.md`（B 站接口实测报告，2026-08）、`probe_1080p.md`（1080P 播放实测）*
