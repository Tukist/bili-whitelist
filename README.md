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
- [UP 主白名单与信箱（v2.13.0+）](#up-主白名单与信箱v2130)
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
- **字幕**：播放页「字幕」入口可选主 / 副字幕轨道，**大号 + 小号双语同步显示**（时间轴同步）；支持 B 站 CC 人工字幕与**登录后的 AI 字幕**（多语言，如英 / 中 / 日）；无字幕视频有提示
- **字幕翻译**：副字幕可选「翻译（中文）」——主字幕内容经 **OpenAI 兼容翻译服务**（可配置 base_url / api_key / model，key 仅存本机）批量翻译成中文显示，带翻译进度提示；**本地缓存**（同一视频同一轨道只翻译一次，切集 / 重进命中缓存直接显示）
- **实时转写（Sherpa 流式）**：播放页「🎙 实时转写（流式）」边播边出字幕——**主字幕 = 实时原文句子、副字幕 = 逐句译文**（OpenAI 兼容翻译服务，未配置则无副字幕），**8 语模型**（中/英/日/俄/泰/越/印尼/阿拉伯）本地推理；**模型 247MB 首次下载**（GitHub releases，国内可能较慢，支持**手动放置模型文件**到指定目录跳过下载），转写中面板实时预览 + 可随时停止，完成即作为字幕显示
- **弹幕（v2.16.3+）**：播放页底部「弹幕」开关，开启即拉取当前视频弹幕并随时间叠加显示——**滚动 / 顶部 / 底部三种模式**按 B 站原始时间轴发射，保留字号档与颜色；XML 弹幕接口匿名可得，接口失败 / 视频无弹幕**静默不阻塞播放**（轻提示一次）；弹幕层仅在开关开启且有数据时构建（关闭零开销），暂停冻结、seek / 切集自动重置游标，切集自动换集弹幕、开关状态保留。**v2.16.6+ 弹幕增强**：长按「弹幕」按钮打开设置面板——**真碰撞分层**（滚动按水平轨道逐轨追尾判定，同轨不叠字；顶部 / 底部纵向行堆叠）、**屏蔽关键词**（substring 匹配）+ **屏蔽类型**（滚动 / 顶部 / 底部开关）、**透明度滑杆**（20%~100% 含阴影整体变淡）；移动按帧间 dt 浮点推进（掉帧钳制平滑）、单帧发射预算保帧率稳定，设置本地持久化。**v2.16.11+ 滚动连续性修复**：推进的每一帧都落屏（CustomPaint 挂每帧 repaint 信号 + RepaintBoundary 隔离——修复前只在发射帧重绘，弹幕按 500ms 轮询节奏"跳"动导致卡顿/不连续）；切后台/暂停恢复重置时间基准不跳变；发射改按真实时间信用预算（40 条/s），掉帧/seek 积压不扎堆补发。**v2.16.13+ 显示区域 + 设置记忆**：设置面板新增**「显示区域」滑杆**（10%~100% 步进 10，说明"弹幕只在屏幕上方 N% 高度内滚动"）——弹幕带等比压缩到屏幕上方该比例内（100% 与旧版布局一致；调 30% 弹幕不再飘到画面中下部妨碍观看，轨道数按区域高度自动缩减），区域 / 屏蔽 / 透明度任一改动即时清屏重排；**弹幕开关状态持久化**（点按即存，进播放页自动恢复上次开关——上次开着本次自动开，区域 / 透明度 / 屏蔽词全部记忆，重启 App 保持）
- **播放页 B 站式快捷手势（v2.16.7+）**：**双击**画面播放 / 暂停；滑动按**主导方向**判定（**v2.16.9+**，参考 B 站）：**水平主导 → 全屏横屏左右滑 seek**（滑动中浮层实时显示进度 `12:34 / 56:78`，松手定位）；**垂直主导 → 按起点左半屏上下滑调亮度、右半屏调音量**——**横屏竖屏都可用**（稍斜的上下滑不再被误判成 seek，调节即时生效，应用内亮度仅当前播放页、退出恢复系统亮度；带图标 + 百分比浮层）。**v2.16.12+ 调节手感修复**：完整上下滑一屏 ≈ 基准 **±30%**（灵敏度 0.3；旧版 ±100% 且基准被逐帧改写 → 动一点点就跳 0/100），小幅滑动平滑小幅变化（1/10 屏 ≈ ±3%）；调节基准在手指落下时读取一次并固定（读取成功前不调节；亮度读取失败兜底 50%，杜绝 -1 异常基准），不跳变、可平滑回退。斜向滑动按主方向归类、锁定后本次手势不再切换；竖屏水平主导忽略（无 seek 防误触）。**v2.16.14+ 底部/顶部豁免带（与系统手势解冲突）**：Pan **起点**落在屏幕**底部**（`max(屏高×8%, 48px)`，横屏屏高 ~400px 时 48px 兜底；竖屏 ≈8% 屏高）或**顶部**（固定 24px，状态栏/刘海区）豁免带内 → 本次滑动**整体忽略**（不 seek / 不调亮度音量 / 不出 hud）——横屏全屏从屏幕下方滑动**唤醒 Android 三键/手势导航不再误触发 seek**，把底部一段让给系统手势；中部 seek / 调节不受影响。豁免只作用于 Pan 滑动：tap / 双击 / 长按（底部带内单击显隐等）与 Stack 上层的控制层按钮 / 进度条照常。单击显隐控制层 / 双击暂停 / 长按 2x / 进度条拖动 / 控制层按钮等既有操作互不干扰
- **登录**：WebView 内嵌 B 站官方登录页（短信验证码），登录态自动续期
- **GitHub token 配置**：App 内填写，安全存储
- **离线缓存**：播放页一键下载到本地（单集 / 全部集），**断网可播放**已缓存视频（播放优先走本地文件）；缓存管理（查看 / 删除 / 清空 / 总大小），列表页显示「已缓存」标记
- **本地导入**：粘贴 B 站分享链接 / 文本（支持完整链接、b23.tv 短链、裸 BV 号）一键导入白名单，与电脑端油猴脚本等效
- **番剧 / 电影导入（v2.16.2+）**：粘贴番剧链接（`bangumi/play/ep<id>` 单集 / `ss<id>` 整季，或 `b23.tv/ep|ss<id>` 番剧短码）**整季逐集加入白名单**——每集一条、标题含「第 X 话 + 副标题」、标为番剧/官方；导入进度逐集提示、重复集自动跳过
- **会员番剧完整播放（v2.16.4+）**：番剧导入时每集写入 `epId`；播放番剧集时普通接口取流失败（会员集返回 -404）自动回退 pgc 番剧取流接口——免费集仍走普通接口（720P 更清晰）；会员/付费集**登录大会员账号后可完整播放**，未登录时匿名接口只给试看流（前几分钟），App **不播试看**、明确提示「该集为大会员内容…请登录大会员账号完整观看」并引导去登录（不误导）；旧版导入的番剧数据无 epId，保持原「该集可能为大会员/付费内容或已下架」提示
- **搜索番剧 / 电影（v2.16.5+）**：「全部 B 站」搜索页新增**搜索范围切换**（视频 / 番剧 / 电影 / 电视剧）：番剧/电影走 media 搜索接口（`search_type=media_bangumi / media_ft`，匿名 + WBI 签名即可），结果展示封面/标题/角标（独家、大会员等）/风格标签/「全 N 话」或上映日期，右侧「导入」**整季逐集加入白名单**——与首页粘贴链接导入共用同一实现（拉整季 → 逐集查重写入 → 进度逐集提示），导入后按钮变「已导入」；media 结果同样支持上拉翻页（排序 chip 仅视频范围显示）；电视剧（`media_tv`）入口同样可搜，但匿名搜索会被 B 站降级过滤（-1200，番剧/电影不受影响）
- **搜索 / UP 主管理**：搜索页支持「全部 B 站 / 我的白名单 / 搜索 UP 主」三类入口；结果可**一键加入白名单**但不会自动入库。首页 PageView 三页（历史记录 / 合集主页 / UP 主管理），**左滑**到「白名单 UP 主」页后可查看、进入、移除已加入 UP 主；UP 主详情页支持在该 UP 主投稿内搜索视频
- **历史记录**：播放页自动记录看过的视频（标题 / 封面 / UP 主 / 进度 / 时间，上限 200 条本地保存）；主页**右滑**（或顶部历史图标）进入历史页，按时间倒序展示，点击条目**续播**上次进度与分 P（多 P 视频精确定位到看过的哪一集）；支持单条删除与一键清空
- **多选批量管理**：长按卡片进入多选模式，勾选多条后**批量移动到合集** / **批量删除**
- **拖动排序**：主页长按合集卡片拖动重排合集顺序（「未分类」固定最后不可拖）；合集页按住视频尾部拖拽把手拖动重排视频顺序——排序结果**同步到 Gist**
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
| App | Flutter（Dart）2.6.0+11 |
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
  （油猴 v2.3.1+ 已保留顶层 `upowners`，与 App 写路径一致）
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
- **番剧 / 电影（v2.16.2+）**：导入入口先试 `parsePgcRef`（本地正则命中 `bangumi/play/ep|ss` 完整链接、裸 `ep|ss<数字>`、`b23.tv/ep|ss<数字>` 番剧短码——**番剧短码就是 ep/ss+数字，无需网络重定向**；随机 b23 短码仍走重定向，落点含 `/bangumi/play/` 才算番剧）→ 命中调 `pgc/view/web/season`（**匿名 + 完整浏览器头即可，无需 WBI**；响应包装层是 `result` 非 `data`，duration 单位**毫秒**）拿整季 → **逐集**构造 `WhitelistVideo`（标题「剧名 + 第 X 话 + 副标题」、`up_name=番剧/官方`、单集 pages）走同一 `WhitelistWriter.addVideo` 写路径（查重自动跳过已存在）；进度对话框逐集提示「导入中 i/N」，失败中断提示已导入数
- **会员/付费集**（`badge` 非空）：照常导入；普通 `playurl` 接口取流返回 **-404**（非稿件失效），播放页映射为友好提示「该集可能为大会员/付费内容或已下架」（完整会员播放需 pgc 取流端点 + 登录态，未实现）

### 10. 搜索（B 站 wbi 搜索 API + 指纹）

- 复用第 1 节的 WBI 签名：请求搜索接口同样带 `wts` + `w_rid` 签名，外加浏览器 UA / Referer 指纹与限流退避（与播放链路同一套风控应对）
- 「全部 B 站」Tab 调搜索接口按关键词查（视频标题 / UP 主），结果归一化为本地 `SearchResult` 模型展示；「我的白名单」Tab 直接对本地白名单数据按标题/UP 主做子串过滤，无需网络
- 一键加入复用第 9 节同一写路径（`WhitelistWriter`：构造 v3 数据 → Gist 实时 API 写回 → 查重合并），与手动导入/电脑端油猴脚本完全一致

### 11. 字幕（x/player/wbi/v2 + AI 字幕需登录态）

- 轨道列表走 `x/player/wbi/v2`（复用 WBI 签名 + buvid 指纹 + 登录态），解析 `data.subtitle.subtitles[]`；**AI 字幕需登录态**（未登录 / 失效返回 -101，提示重新登录）
- 字幕文件（`subtitle_url`，`//` 开头补 `https:`）下载带 Referer + UA 防盗链头，内容按 `bvid_cid_lan` 内存缓存，同一轨道不重复下载
- 播放页主 / 副字幕各选一条轨道，按播放进度（500ms 轮询）取当前句，**大号主字幕 + 小号副字幕**同步渲染；字幕 JSON 解析容错（BOM / 非法条目跳过）

### 12. 字幕翻译（OpenAI 兼容服务 + 批量 + 缓存）

- 翻译服务配置（base_url / api_key / model）存 **flutter_secure_storage**（key 前缀 `translate_`，与登录态 / GitHub 配置分开，**仅存本机**；任一项留空 = 不启用翻译）
- **批量翻译**：调 `{baseUrl}/v1/chat/completions`（POST + Bearer），每批最多 20 条字幕一次请求，超长自动分批串行（进度 notifier 驱动「翻译中 x/y」）；回复按行逐条对应，行数不足补原文、多出的截断、行首序号剥离
- **本地缓存**：译文按 `(bvid, cid, 主字幕 lan)` 落应用支持目录 JSON（`subtitle_translation_*.json`），同一视频同一轨道只翻译一次，切集 / 重进命中缓存直接显示
- 副字幕「翻译（中文）」与普通副字幕轨道**互斥**（选翻译则轨道置空）；未配置服务时点击提示去管理面板配置；401（key 无效）/ 超时 / 断网给出中文错误提示（字幕层「翻译失败」+ SnackBar 具体原因）

### 13. 实时转写（sherpa-onnx 流式 + 二次分句 + 子句批量翻译）

- **入口**：字幕设置面板「🎙 实时转写（流式）」区块（轨道列表 / 翻译下方）——未开始时显示按钮与说明（首次需下载模型 247MB）；模型下载/音频准备中显示阶段进度；转写中显示「转写中…」+ **实时文本预览（partial）** + 停止；完成后显示「✅ 实时转写完成（N 句）· 已作为字幕」；错误显示红字 + 重试
- **转写链路**：`SherpaModelManager`（GitHub releases 下载 8 语流式 zipformer tar.bz2 247MB，进度 0~1 + 失败重试 + 完整性校验）→ `SherpaAudioPreparer`（离线缓存音频优先，否则临时下载 DASH 音频流，ffmpeg 转 16kHz 单声道 wav）→ `RealtimeTranscriber`（sherpa_onnx 流式识别：按 1s 块喂 OnlineStream → 增量解码 → 实时更新 partial → 检测句尾收句 → **二次分句** + 子句批量翻译）
- **二次分句**：sherpa 端点检测不常触发，一句可能覆盖几十秒/多句话（字幕"一连好几行"）——`lib/utils/sentence_splitter.dart` 把一次端点的完整句子先按句末标点（`。．.!！?？…；;`）拆，过长的子句（>45 字符）再按逗号 / 顿号 / 空格拆；每子句时间戳按**字符数比例**分配（覆盖原句区间、单调不重叠），作为独立字幕入列
- **主字幕 = 原文、副字幕 = 译文**：转写结果作为主字幕数据源（按播放位置取当前子句），副字幕显示该子句译文（`RealtimeTranscriber.sentences[i].translation`）；**一次端点拆出的子句一次批量翻译请求**（OpenAI 兼容服务，按序回填各子句），翻译服务未配置 / 失败则无副字幕；partial 实时文本仅面板预览
- **手动放置模型（下载慢兜底）**：模型解压目录 `<应用支持目录>/sherpa/8lang/<模型名>/`，检测四件套（encoder/decoder/joiner .onnx + tokens.txt，encoder > 10MB）完整即**跳过下载直接使用**——网络下载慢（GitHub 国内仅几 KB/s）时可在 PC 下载 tar.bz2 解压后把模型目录放进该路径；面板在下载阶段提示目录路径
- **状态管理**：转写状态随切集 / 重进 / 退出播放页重置（dispose 停止）；并发控制（一次一个，进行中再次开始拒绝并提示）

### 14. 弹幕（v2.16.3+，x/v1/dm/list.so XML）

- **接口**：`https://api.bilibili.com/x/v1/dm/list.so?oid=<cid>`，匿名可得无防盗链；响应体 HTTP 层固定 `Content-Encoding: deflate`（**raw deflate** 非 zlib 包装），dio 只自动解 gzip，故按 bytes 取回手动解压（gzip / raw / zlib 兜底）；老视频弹幕被关闭（state=2）/ 空弹幕 → 无 `<d>` 节点 → 空列表
- **模型**：`lib/models/danmaku.dart`——单条 `time/mode/fontsize/color/text`（p 属性前 4 段，color 十进制 RGB 转 ARGB；mode 4=底部 5=顶部，其余按滚动）；XML 正则解析脏行容错（p 缺段 / 类型非法 / 空文本跳过）+ 实体反转义 + 按时间升序；`parseDanmakuXml` / 档位换算 `danmakuDisplayFontSize` 有单测（含 deflate 解压 mock dio）
- **渲染层**：`lib/widgets/danmaku_overlay.dart`——CustomPaint + Ticker 每帧推进，**缓存 TextPainter**（发射时排版一次，每帧只 paint）；**每帧落屏（v2.16.11 滚动连续性修复）**：painter 挂每帧递增的 repaint ValueNotifier + 外层 RepaintBoundary 隔离——推进的每一帧都真正绘制（旧版只在发射帧 setState 重绘，两批弹幕之间弹幕位置在变但画面不刷新，按父层 500ms 轮询跳跃 → 卡顿/不连续）；移动按帧间时间差 dt 浮点推进（**v2.16.11 平滑**：普通掉帧钳制 ≤50ms 上限；帧间隙 >100ms 视为长时间无帧——切后台/引擎停摆恢复 → 重置时间基准、本帧不推进，暂停恢复不跳变）；发射为"单帧预算 + 真实时间信用（40 条/s、单帧余额 4）"双限，掉帧/seek 积压不一次性扎堆补发；**真碰撞分层（v2.16.6）**：轨道分配器 `models/danmaku_lanes.dart`——弹幕区按行高切横向轨道（顶部区 3 行独立、底部区 2 行独立），滚动轨道只记最后一条的尾缘 / 速率，新弹幕按追尾时间判定（O(1)，同速跟车保持间距、快车仅在追上时前车已出屏才同轨），打满丢弃计数；顶部 / 底部行停留 3.5s 占行（0.15s 淡入 + 0.4s 淡出），全忙丢弃；滚动弹幕 ~4s 穿越全屏（右入左出）；绘制透明度（用户滑杆 20%~100%）按文本 saveLayer 乘 alpha（含阴影），默认 100% 零额外开销；播放暂停冻结、seek / 恢复进度 >3s 跳变自动清屏并把发射游标跳到新位置；帧回调用 `RenderBox.hasSize` 安全读渲染尺寸（debug 下 mount 首帧尚未 layout，直接读 context.size 会断言终止 Ticker——v2.16.11 顺带修复）；每 ~2s debugPrint 帧节奏统计（平均/峰帧间隔 + 本周期重绘请求数，logcat 可证"推进帧数 = 重绘请求数 → 每帧落屏"）
- **屏蔽与设置（v2.16.6 → v2.16.13 设置记忆）**：`models/danmaku_settings.dart`（屏蔽词 substring 匹配、屏蔽类型 bool、透明度 clamp、**开关 enabled / 显示区域 displayAreaPercent（10~100 步进 10）**、JSON 序列化容错——缺字段回默认、脏值归一化）+ `services/danmaku_settings_store.dart`（shared_preferences 单 key JSON，损坏/失败静默回默认）；发射前过滤（命中不显示、游标照常越过），设置实例变化 → 渲染层清活跃按当前位置重载（即时生效）；**显示区域（v2.16.13）**：`danmakuScrollLaneCount(带高px, 行高)` 纯函数按缩放后带高换算滚动轨道数（100% 与旧版逐像素一致；30% 滚动轨道 23→3），弹幕带顶/底锚点随百分比压缩到屏幕上方 N% 内，底锚额外钳制在区域下界内；周期 debugPrint 日志：发射 / 屏蔽 / 丢弃计数 + 屏上活跃 vs 轨道数 + **布局日志（区域 / 轨道数 / 发射 y 范围 / 限制比**，供 logcat 实测"区域 N% → 轨道 y 上限 ≈ 屏高×N/100"）
- **页面集成**：播放页底部「弹幕」按钮开关（默认关，**v2.16.13 起状态持久化**——点按即存；进页异步读持久化 enabled 初始化，上次开着 → 本次进页自动开并自动拉弹幕）→ 开：`fetchDanmaku(cid)` 拉全量（cid → 页面缓存，切集后同 cid 秒开），成功挂载渲染层；失败 / 无弹幕 → 返回空 + 轻提示「该视频暂无弹幕」，**不阻塞播放**；关：弹幕层销毁（零开销）。**长按「弹幕」= 设置面板**（屏蔽词管理 / 类型开关 / **显示区域滑杆 10%~100%** / 透明度滑杆，改动即时生效 + 自动保存，重启保持）。弹幕层位于画面之上、字幕层之下（字幕可读优先）；切集自动拉新集弹幕、开关状态保留

### 15. 应用内版本更新（GitHub Releases → 下载 → 一键安装）

- **触发时机**：
  - **启动静默检查**：App 启动 5s 后调 `UpdateService.check(force=false)`，24h 节流；失败 / 已是最新 / 节流命中 → 完全静默；发现新版本且非强制 → 弹 `UpdateDialog`
  - **手动检查**：管理面板（首页右上角⚙️）底部 → 「检查更新」按钮，调 `check(force=true)` 跳过节流；三种结果 SnackBar 提示（已是最新 vX.Y.Z / 错误 message / 弹更新弹窗）
- **私有仓库鉴权（v2.16.1+）**：仓库是私有的，Release 元数据与资产下载都需带管理页已配置的 GitHub token（`UpdateService(tokenProvider:)`；无 token 时按公开仓库匿名请求，向后兼容）。下载走两段式：带 token + `Accept: application/octet-stream` 请求资产 API 地址 → 手动跟随 302 到签名 CDN 地址后下载（鉴权头不随跳转转发，否则 S3 双重鉴权报 400）
- **下载流程**：`UpdateService.download(info)` 把 APK 下载到 `<应用支持目录>/updates/app-update-<code>.apk`
- **断点续传 + 网络异常友好提示（v2.16.8+）**：下载先写半成品 `app-update-<code>.apk.part`——存在 `.part` 时按已下载字节数带 `Range: bytes=N-` 续传（服务器 206 追加 / 200 不支持 Range 则全量重写），**下载完成才改名成正式 APK**；跳转手动跟随，保证 Range 命中签名 CDN。**失败 / 取消都保留 `.part`**，下次点「重试 / 立即更新」自动从断点继续；瞬时网络错误（断网 / 连接被重置 / 超时）自动重试 2 次（1s→2s 退避）并附「将自动从断点继续」的友好中文提示——不再出现「未知错误」裸文案（下载一半断网也不会整体重下）。可选 SHA-256 流式校验（`info.sha256 != null` 时启用，校验失败删文件抛「完整性校验失败」）
- **安装跳转**：下载完成自动调 `ApkInstallerChannel.install(path)` → 原生 `ApkInstaller.kt` 通过 `FileProvider`（authority=`${applicationId}.fileprovider`）暴露 `content://` URI 给系统安装器，触发 `Intent.ACTION_VIEW` + `application/vnd.android.package-archive`；min_sdk=26 强制走 FileProvider（避免 API 24+ `FileUriExposedException`）
- **强制更新策略**（`UpdateInfo.minSupported_code`）：当前 code 严格小于该阈值时弹窗屏蔽返回（`PopScope(canPop: false)`），只显示「立即更新」按钮；首版不启用（默认 null），保留机制备用
- **多 ABI（v2.16.1+）**：Release 同时发 arm64-v8a / armeabi-v7a / x86_64 三 ABI；`UpdateInfo` 按设备 ABI 选资产（`Abi.current()`），无匹配回退 arm64-v8a
- **Release tag 约定**：tag 必须是 `v主版本号+构建号`（如 `v2.16.1+31`）——App 从 tag 的 `+数字` 解析 versionCode 判新旧；缺构建号会退化为发布日期数字（如 260902），比任何真实 versionCode 都大，导致已装最新版仍反复弹更新
- **Android 权限**：新增 `android.permission.REQUEST_INSTALL_PACKAGES` + `<provider>` + `res/xml/file_paths.xml`，完整见 `app/android/app/src/main/AndroidManifest.xml`

---

## 目录结构

```
bili-whitelist/
├── README.md                  # 本文档
├── .gitignore                 # 敏感/隐私文件一律不入库
├── whitelist.py               # PC 端白名单管理 CLI（add/remove/list/serve/push/collection）
├── bili-whitelist.user.js     # 油猴脚本（v2.3.1，B 站视频页一键加白名单，直连 Gist）
├── start-whitelist.bat        # 一键启动本地 serve（可选）
├── sync_config.example.json   # GitHub 配置示例（token/gist_id 占位，真实配置在 sync_config.json，已 gitignore）
├── whitelist.example.json     # 白名单数据示例（v3 结构，纯假数据；真实 whitelist.json 已 gitignore）
├── probe.py / probe.md        # 技术侦察：B 站接口实测脚本与报告（2026-08）
├── probe_1080p.py / probe_1080p.md
└── app/                       # Flutter Android App
    ├── pubspec.yaml
    ├── lib/                   # Dart 源码
    │   ├── main.dart / config.dart
    │   ├── api/               # bilibili_api.dart（WBI+playurl）、github_api.dart（Gist 同步）、translate_api.dart（字幕翻译）、sherpa_model.dart（8语流式模型下载）/ sherpa_audio.dart（实时转写音频）
    │   ├── cache/             # download_manager.dart（离线缓存下载管理器，串行队列）
    │   ├── models/            # whitelist_video.dart（v3 数据模型 + 合集管理逻辑）
    │   ├── pages/             # login_page / playlist_page / player_page
    │   ├── player/            # bili_dash_player.dart（DASH 播放控制器）
    │   ├── services/          # service_locator.dart、realtime_transcriber.dart（实时转写：sherpa 流式状态机 + 逐句翻译）
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

### 如何发版（自动创建 GitHub Release）

推荐用 `release.sh`（gh CLI 已登录即可，幂等可重复执行）：

```bash
# 在 app/ 目录跑：构建 3 ABI + 创建/更新 GitHub Release + 上传 APK
cd D:/pythoncode/bili-whitelist/app
bash release.sh
```

`release.sh` 会：解析 `pubspec.yaml` 的 `version: 2.16.1+31` → 先跑 `bash build_release.sh` 产出 3 ABI，再从 `../CHANGELOG.md` 提取 `## v2.16.1` 段作 notes；tag=`v2.16.1+31`（**必须带构建号**，App 从 tag 解析 versionCode 判新旧）——tag 不存在则 `gh release create`，已存在则 `gh release upload --clobber` 补资产 + `gh release edit` 更新 notes，重复执行无副作用。

备选（不依赖 gh，用 PAT）：

```bash
# 在 app/ 目录跑，带 PAT（repo 权限）即自动创建 Release（tag=v主版本号+构建号）+ 上传 3 ABI
cd D:/pythoncode/bili-whitelist/app
GH_REPO_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx bash build_release.sh
```

`build_release.sh` 步骤：

1. 解析 `pubspec.yaml` 的 `version: 2.16.1+31` → 主版本号 `2.16.1`（文件名用）、完整版本 `2.16.1+31`（tag 用）
2. 跑 `flutter build apk --release --split-per-abi` 产出 3 ABI
3. 复制为 `app-<abi>-v2.16.1-release.apk`
4. **如果 `GH_REPO_TOKEN` 已设置**：从 `../CHANGELOG.md` 提取 `## v2.16.1` 段作为 body，调 GitHub Releases API 创建 release（tag=`v2.16.1+31`，**必须带构建号**，App 从 tag 解析 versionCode 判新旧），再循环上传 3 ABI
5. 打印 Release 链接 `https://github.com/Tukist/bili-whitelist/releases/tag/v2.16.1+31`

> 没设 `GH_REPO_TOKEN` 时只到第 3 步停下，APK 留在本地可手动拖到 web。
> `jq` 不可用会自动降级到 `python -c "import json..."`（Windows Git Bash 自带）。

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

## UP 主白名单与信箱（v2.13.0+）

> T2 里程碑：除了「把单条视频加进白名单」，现在可以**把整个 UP 主加进白名单**——一次关注，TA 的所有投稿都能自由浏览；同时启动时自动检查新视频，「信箱」里能看到 TA 发布了什么。

### 核心功能

| 功能 | 入口 | 说明 |
|------|------|------|
| **搜索 UP 主** | 搜索页「搜索 UP 主」Tab | 复用 B 站全网用户搜索（`x/web-interface/wbi/search/type`，`search_type=bili_user`），头像/名字/认证描述/粉丝数，结果可一键加入白名单 |
| **UP 主详情页** | 搜索结果点 UP 主 | 头部信息卡（头像 + 名字 + 粉丝 + 简介）+ 视频列表（最新发布 / 最多播放 / 最多收藏 三种排序，分页 20 条/页），点视频直接播放（不写 Gist） |
| **信箱** | 首页 AppBar 最左侧图标 | 启动 5s 后自动检查所有白名单 UP 主的新视频（带 30min 节流 + 1.5s 间隔），未读数 ≥ 1 时显示小红点；下拉刷新强制重检；顶部「全部标记已读」一键清空 |

### 设计取舍

- **不冗余存储 UP 主视频**：UP 主视频不写入 `videos[]` 列表（数据模型 v3 的视频列表保持精简），只在用户**显式加单条视频进白名单**时才走 `WhitelistWriter.addByBvid` 写 Gist
- **信箱增量靠 `lastSeenBvid`**：每个 UP 主记录最近一次见过的 bvid，下次检查时拿到首页 5 条最新视频，对比找到未读部分（首页已按 `pubdate` 倒序）
- **本地优先**：未读列表写 SharedPreferences（每 UP 主一份 unseen），`lastSeenBvid` 写 Gist（批量 `updateLastSeenBatch`）；检查期间断网/失败不影响下次重试
- **风控降级**：任何 UP 主遇 -412/-352 → 间隔从 1.5s 自动升级到 3s，跳过该 UP 主不抛错；最多检查 100 个 UP 主（超出按前 100）

### 数据模型 v4

`whitelist.json` v4 = v3 + 顶层 `upowners[]` 数组（兼容 v3：缺字段视为 `[]`）：

```json
{
  "version": 4,
  "updated_at": "ISO 8601 UTC",
  "collections": [...],
  "upowners": [                          // v4 新增：白名单 UP 主
    {
      "mid": 12345,                       // B 站用户 ID（主键）
      "name": "UP主昵称 · 认证描述",      // 搜索时拼接 official_verify.desc
      "face": "https://头像url",
      "fans": 9999,                       // 可选，缓存展示
      "added_at": "ISO 8601 UTC",
      "last_seen_bvid": "BV1xxx",          // 信箱增量对照
      "last_seen_at": "ISO 8601 UTC"      // 上次检查时间
    }
  ],
  "videos": [...]                         // 与 v3 完全一致
}
```

- 任何端写回 Gist 时统一规范化：`version=4`、刷新 `updated_at`、`upowners` 必出
- 字段含义见 `app/lib/models/upowner.dart` 与 `app/lib/services/inbox_service.dart`
- ⚠ **v2.16.10 修复**：油猴脚本 v2.3.0 的 parse/build 不认 `upowners`，电脑上加视频的 PATCH 覆盖写回曾把该字段清空（表现为"隔段时间重进 App UP 主没了"，与历史"合集消失"同款）——**请把油猴脚本更新到 v2.3.1**（`parseWhitelist` 透传 + `buildWhitelistJson` 兜底保留 `upowners`）；已被清空的 UP 主需重新添加一次，此后任意端写入不再丢

### 风控与限制

| 场景 | 行为 |
|------|------|
| B 站 -412 风控 | 抛 `BiliApiException`，UI 显示「搜索失败：接口被风控拦截」+ 重试按钮 |
| B 站 -352 限流 | 同上：抛 `BiliApiException`，提示稍后再试 |
| 信箱某 UP 主连续风控 | 自动降级：间隔从 1.5s 升级到 3s，跳过该 UP 主不阻塞后续 |
| 超过 100 个 UP 主 | 只检查前 100 个（按 `WhitelistData.upowners` 顺序） |
| 网络断开/异常 | 静默跳过本次检查，下次启动或用户下拉刷新重试 |

### 代码入口

- 模型：`app/lib/models/upowner.dart`（`Upowner` / `addUpowner` / `removeUpowner` / `UpownerException`）
- 写入：`app/lib/services/upowner_writer.dart`（`UpownerWriter.add` / `removeByMid` / `updateLastSeenBatch`）
- 信箱：`app/lib/services/inbox_service.dart`（`InboxService.checkAll` / `markAllRead` / `getUnseenCount` / `getItems`）
- 页面：`app/lib/pages/upowner_page.dart`（详情页）/ `app/lib/pages/inbox_page.dart`（信箱页）
- 入口：`app/lib/widgets/upowner_tile.dart`（搜索结果列表项）
- B 站接口：`app/lib/api/bilibili_api.dart` 的 `searchUpowner` / `fetchUpownerVideos` / `fetchUpownerInfo`

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
- **国产 ROM 兼容加固（v2.12.1+）**：`flutter_secure_storage` 9.x 默认走 Jetpack Security（Tink + Keystore）加密，与 vivo OriginOS、小米 MIUI、华为 EMUI 等深度定制 ROM 的 Keystore 实现不完全兼容（写入/读取会抛 `PlatformException`，表现为「登录态保存失败」「GitHub 配置保存失败」）。App 已显式切到插件自研 Keystore 加密（`encryptedSharedPreferences=false` + `resetOnError=true`，见 `app/lib/services/secure_store.dart`）。**如仍有问题请反馈设备型号 + Android 版本 + 系统 ROM 版本号**，但一般 v2.12.1+ 应可直接保存登录态与 GitHub 配置
- **应用内更新依赖管理页已配置的 GitHub token（v2.16.1+）**：版本仓库是私有的，未配置 token 时「检查更新」会提示暂时没有可用更新（404）；v2.14.0~v2.16.0 版本的 App 不带 token 检查，无法发现新版本，需手动装一次 v2.16.1+ 才能用上应用内更新

---

## 许可证

本项目**仅供个人学习使用**，未经作者许可请勿分发或商用。未套用任何标准开源许可证（代码不构成公开发布）。

---

*配套技术文档：`probe.md`（B 站接口实测报告，2026-08）、`probe_1080p.md`（1080P 播放实测）*
