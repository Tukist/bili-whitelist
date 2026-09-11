# 更新日志（CHANGELOG）

本项目按 [SemVer](https://semver.org/) 约定：`主版本.次版本.修订号+构建号`。

`修订号` 用于 bug 修复与微调；`次版本` 用于新功能；`主版本` 用于不兼容变更。

所有版本变更按时间倒序记录；最新版本在最上方。

---

## v2.20.0 (2026-09-11)

**信箱重做成 Tinder 式左右滑卡片（右滑加入 / 左滑跳过 / 撤销）；修掉用户反馈的「信箱时不时清空」真实缺陷（检测与已读确认彻底解耦、队列只增不减）；空态细线插画改动态「随机游走线」；设置页补上「界面文案」编辑入口；播放页手势横滑复用「拖动进度条」的呈现（进度条浮出 + 缩略图预览气泡）**

- **信箱改造成卡片栈（新 `app/lib/widgets/inbox_swipe_card.dart`、`app/lib/services/inbox_handled_store.dart` + 重写 `app/lib/pages/inbox_page.dart`）**：信箱页由列表改为 **Tinder 式卡片栈**——卡片含**封面大图（16:9）+ 标题（≤2 行）+ UP 头像与名字 + 时长 + 相对时间**；下层卡片以「**底边对齐**」方式露一条边（与两张卡的高度差无关，修掉「下一张更矮时被完全盖住」）；**点按卡片仍可进播放页**（与滑动不冲突）
- **滑动手势**：拖动时卡片跟手并**轻微旋转（最多 ±12°）**；**右滑 = 加入白名单**（like，显示「加入」浮层标记）、**左滑 = 跳过**（skip，显示「跳过」标记）；位移未过阈值（**屏宽 30% 或速度 700px/s**）→ **弹回**；底部另提供与滑动等价的「**跳过 / 加入**」按钮（触摸目标 **≥48dp**）；支持**撤销上一张**；`MotionControl` 关动效时**不创建 controller**（测试环境不产生无限动画）
- **修掉「信箱时不时清空」缺陷（用户反馈，已定性为真实缺陷）**：**根因**——`checkAll` 在**发现新视频的当场就把已读基线 `last_seen_bvid` 推到最新**，于是下一次检查必然「没有新视频」并顺手删掉该 UP 的未读缓存、红点归 0；而**打开信箱页本身就是一次强制检查** → 用户一打开内容就被吃掉。**修法**：把「检测」与「已读确认」彻底解耦——`checkAll` 只做「拉取 → 算候选 → **合并**进队列（不覆盖、不推进基线）」；**只有卡片操作（右滑 / 左滑 / 按钮）才消费**（`markHandled`）；基线只在「**首次见到某 UP**」或「**该 UP 队列被清空**」时推进，且**基线写盘成功后**才清「已处理」记录
- **队列语义**：**持久化**（杀进程重开仍在）、**只增不减**、**检查失败不丢**——整体失败回退上次缓存 + `failed` 标记；**单个 UP 失败则该 UP 队列一个字节不动**；「已处理」bvid 持久化到 `inbox:handled_bvids`，`checkAll` 算未读时排除
- **信箱可用性修复（设备实测发现的）**：① **检查期间不再阻塞交互**——白名单约 100 个 UP 时 `checkAll` 要跑约 2.5 分钟，原先点卡片静默无反应、按钮全灰 → 改为**不参与交互门禁**（只显示一行「检查中…」提示）；并处理并发：检查回来**只追加不重排**（卡片栈不回到第一张），服务层写盘前按「此刻」的已处理记录**重算**，避免把刚划走的条目写回未读；② **空态保留撤销入口**（原先滑掉最后一张后底部栏整体消失，撤不回来）；③ 「下一张露一角」改为**底边对齐**；④ **用户划完队列后显示空态而非加载态**（原先会先闪「正在加载…」数分钟）；⑤ 预览取帧对「接近总时长」**回退 1.5s**（避开片尾黑格）
- **手势横滑复用「拖动进度条」的呈现（`app/lib/pages/player_page.dart`）**：手势左右滑动调进度时，进度条**浮出来且手柄跟随**（控制层收起时只浮出进度条行，**不改用户的显隐偏好**）；同时显示**预览气泡（缩略图 + 时间）**，位置按位置比例映射到轨道，**松手气泡消失**；预览管线可用时**不再叠居中 seek 时间浮层**（竖屏空间不够会重叠）；**亮度 / 音量的浮层完全未变**
- **空态细线插画改成动态「随机游走线」（重写 `app/lib/widgets/dot_illustration.dart`）**：从静态图案改为**带限布朗曲线**（1/f² 频谱的随机相位正弦叠加）——3 条 1px 细线随时间缓慢漂移 + 变形，沿线**左浓右淡**，点缀色小点骑在线上；**同 seed 同路径**（谐波初相由 seed 播种，一次性生成）；空间 / 时间相位都是**整圈** → **循环无突变**；`MotionControl` 关闭时走**静态一帧、零 ticker**；**调用方零改动**
- **设置页补上「界面文案」编辑入口（`app/lib/widgets/manage_panel.dart`）**：此前 `UiCopyStore` 的数据层与各处接线都做了（47 条出厂文案），**但设置页的编辑入口一直没落地** → 现在补上：`ManagePanel` 新增「界面文案」分区 → 弹层按场景分组（**17 组**）列出全部 **47 条**，可逐条改写、单条恢复默认、全部恢复默认（二次确认）；**改一个字符即全局生效**，写入 `shared_preferences`；空 / 纯空白输入 = 清除该条覆盖、用回默认；`kDefaultCopies` 出厂值未被改动
- **文案调整**：「UP 主」页入口文案 `导入我关注的 UP` → **`导入我的 UP`**（连同导入页标题、登录门禁与登录报错共 **4 处**用户可见文案）
- 测试：`flutter analyze` **0 issue**；全量 `flutter test` **1339 例全绿**（本轮由 1176 例增至 1339 例）；其中关键用例做了**变异验证**（如把「队列合并」改回「覆盖」→ 5 例立刻变红；把「不推进基线」改回旧行为 → 回归用例变红），证明断言有效
- 验证：**模拟器（AVD `bili_test` / Android 15）实测**——右侧滑动与底部按钮均能跳过、标记浮现、弹回、撤销、空态、点卡进播放页；**反复进出信箱 + 杀进程重开，条目仍在**（「时不时清空」缺陷不复现）；且在**真实 412 风控导致绝大多数 UP 拉取失败**的场景下，**本地队列一条未丢**；空态插画确认为动态（间隔抓帧有像素差异、不同页面 seed 不同）；横滑出现进度条 + 缩略图预览气泡。已知环境限制：该 AVD 为 SwiftShader 软件渲染（约 4.6fps），**动效顺滑度无法在模拟器判断**，需真机；另：把 Android 三个动画缩放置 0 会让 App 装饰动画静止（`MotionControl` 会读 `MediaQuery.disableAnimations`），**验证动效前须确认三个 scale 为 1**

---

## v2.19.0 (2026-09-11)

**交互三补：合集卡左滑露出「重命名 / 删除」操作块（跨卡联动 + 与长按拖拽排序共存）、竖屏横滑也能调进度、拖动进度条显示「视频帧缩略图 + 时间」预览气泡**

- **合集卡左滑操作块（新 `app/lib/widgets/swipe_action_box.dart` + `app/lib/pages/playlist_page.dart`）**：首页「合集」页的真实合集卡支持**左滑**，右侧露出「**重命名**」「**删除**」两个操作块，点击复用既有的对话框 + 写 Gist 流程（不新增第二套逻辑）；组件为通用「左滑露出操作块」——**吸附**（松手过半则定格露出，未过半自动收回）、**手势结束收回**、**触摸目标 ≥48dp**（达标 Material 最小点击区）、`MotionControl` 关动效时**零 controller**（测试环境不产生无限动画）
- **跨卡联动（模块级静态引用，对宿主零侵入）**：同屏只允许一张卡露出——滑开新卡会**自动收回上一张**；按下别处 / 列表滚动同样收回。宿主页面无需持有任何状态或注册回调
- **圆角与裁切**：卡片右圆角缺口用「**只裁右外缘 + 同色补角垫片**」补齐（含**像素级测试**），露出区与卡片本体视觉连续
- **与长按拖拽排序共存（`ReorderableDelayedDragStartListener`）**：延时拖拽是**长按 500ms** 触发，横滑位移**超过 18px slop 时 Flutter 的延时识别器会自认输** → 左滑与拖拽**不冲突**（有 Flutter 源码依据 + 回归用例）；顺带修正了 `DragStartBehavior.start` 会吞掉**越过 slop 的位移**、导致单步大幅滑动失效的问题
- **禁用范围**：「未分类」卡与「收藏夹」卡**不启用**左滑（无重命名 / 删除语义）
- **竖屏也能左右滑动调进度（`app/lib/pages/player_page.dart`）**：修前非全屏水平滑动 seek 被三处硬编码 `if (_fullscreen)`（`player_page.dart:2157` / `:2173` / `:2194`）**整条掐断**（连时间 HUD 都不弹）→ 用户反馈「竖屏无法左右滑调进度」；修后三处改为统一纯函数判定 **`canGestureSeek({listenMode, durationMs})`**（听视频模式与时长未知时不 seek），竖屏 / 横屏置顶 / 全屏走**同一条路径**。非全屏**关闭底部 48px 手势豁免带**（它压在 231dp 视频区的中部，白吃 **21% 起手区**）；**全屏行为一字未动**（此前用户专门要求过的「底部豁免」修复被保住在测试里）；与亮度 / 音量的**方向判定未放宽**（避免另一个方向的破坏）
- **拖动进度条显示缩略图预览（新 `app/lib/models/video_shot.dart`、`app/lib/services/video_shot_service.dart`、`app/lib/api/bilibili_api.dart` 的 `fetchVideoShot`）**：拖动进度条时上方出现预览气泡 = **视频帧缩略图 + 时间**；数据来源是 B 站官方「进度预览图（雪碧图）」接口 `x/player/videoshot`（**免 wbi 签名、免登录**），返回 **10×10 雪碧图** + 每帧秒数（粒度约 5–8s）；`VideoShotInfo` 内含**时间 → 缩略图二分的纯函数**
- **内存红线**：雪碧图原图 4800×2700 全尺寸解码约 **52MB/张** → 实现为**按需只下当前那张 + `instantiateImageCodec(targetWidth:)` 降采样**（实测解码后 ≈**5.5MB/张**）+ **LRU 容量 2**（淘汰时 `dispose`）+ **in-flight 去重**
- **预取**：进入播放页 / 恢复进度 / seek 落点后，后台预取当前位置所在的**那张雪碧图** → 首次拖动即可见
- **失败静默降级**：接口 / 网络 / 解码任何失败 → **只显示时间气泡**（不阻塞拖动、不弹错）
- **「首次拖动看不到缩略图」修复**：原实现按「每请求递增的序号」丢弃迟到结果，而拖动全程常落在**同一张雪碧图**内、整图下载要 1.5–2.5s → 结果**全被判迟到丢弃**。改为**按雪碧图号落地**（同图迟到的结果**仍有效**，且用当前位置**重算裁剪矩形**）、**跨图才丢弃**（防显示错误区段 + 防画已释放的图）
- **气泡尺寸**：竖屏 120×67.5、全屏 180×101.25（**不拉伸变形**，均为 16:9）
- 其余：上一轮还顺带修了「合集管理」与卡片**共用同一份重命名 / 删除对话框**（抽成顶层函数，**文案逐字保留**）
- 测试：`flutter analyze` **0 issue**；全量 `flutter test` **1245 例全绿**（本轮由 1176 例增至 1245 例）；其中关键用例做了**变异验证**（如把「按雪碧图号落地」改回「按请求序号」，新用例**立刻变红**），证明断言有效
- 验证：debug APK 装机模拟器（AVD `bili_test` / Android 15）实测——① **竖屏横滑出现 seek 时间浮层**且松手后进度改变，竖屏纵滑仍是亮度 / 音量；② **拖动进度条实拍到「缩略图 + 时间气泡」**；③ **冷启动后首次拖动 3 秒内即出缩略图**（证明预取命中）；④ 合集卡**左滑露出两块**、点「重命名」弹出对话框（未真改）、**跨卡联动收回**、「未分类」卡**左滑无反应**、**已滑开的卡长按拖拽仍可用**（拖起有浮层与投影，拖回原位**零像素差异**）。已知环境限制：该 AVD 是 SwiftShader 软件渲染（约 4.6fps），**动效顺滑度在模拟器上无法判断**，需真机

---

## v2.18.0 (2026-09-10)

**视觉体系级重构 + 动效系统建设：token 化设计地基（克莱因蓝 + 暖白底材、全面去阴影改描边）、块化设计语言（AppBlock 6 变体）、交错入场 + 封面飞入、风衣男剪影加载动画；首页改 Material 3 底部导航四页签，App 与项目更名 amoTV**

- **视觉地基与配色系统（新 `app/lib/theme/app_tokens.dart`、`app/lib/theme/app_theme.dart`）**：新建 token 体系（颜色 / 字阶 / 间距 / 圆角 / 动效）与主题工厂 `buildAppTheme`，**全库 197 处硬编码颜色统一收敛到 token**（不再散落魔法色值）；主色由 B 站蓝 `#00A1D6` 换成**克莱因蓝 `#002FA7`**，底材改**暖白 `#FAFAF7`**，**取消一切阴影**——层级改由 **1px 描边 + 底材差**表达；新增 `app/lib/theme/ink_recipes.dart`（**10 套双墨配色**，取自 mono-color-skill 的双色表）+ `app/lib/theme/app_palette.dart`（`AppPalette extends ThemeExtension`，内置 **WCAG 对比度护栏**：`inkFill` / `inkText` / `inkDeco` 分档，浅墨配方自动压深到 4.5:1 / 3:1）+ `app/lib/services/theme_store.dart`（本地持久化）；**设置面板新增「配色主题」选择器**（10 套，点击即生效、杀 App 重进保持）
- **品牌与导航结构（`app/lib/pages/playlist_page.dart` 等）**：App 与项目更名为 **amoTV**（Android 显示名、AppBar 标题、README、油猴脚本 `@name`；`applicationId` 与 Dart 包名按工程判断**未改**，以免用户数据丢失）；首页导航从「AppBar 图标 + PageView 横滑」改为 **Material 3 底部导航 4 项**——合集 / UP 主 / 历史 / **个人**（原「统计」+「设置」合并为「个人」，统计在上、设置在下）；「新建合集」从设置区移到合集页（顶部常驻按钮 + 空态行动按钮）；修复导航栏 1px 顶线被 `NavigationBar` 不透明背景盖掉，AppBar 与卡片补描边
- **块化设计语言（新 `app/lib/widgets/app_block.dart`）**：`AppBlock` 提供 6 个变体（`videoInfo` / `comment` / `reply` / `videoCard` / `collectionCard` / `setting`），靠「底材差 + 描边重量 + 左侧竖条 + 圆角」四轴表达层级；评论块 / 回复块（缩进 + 左侧竖条 + 下沉底色）/ 视频卡 / 历史卡 / 播放页信息块 / 合集卡全部块化；播放页信息块带左侧短竖条（主墨图形档）
- **动效系统（新 `app/lib/theme/app_motion.dart`、`app/lib/theme/motion_control.dart`、`app/lib/widgets/staggered_entrance.dart`）**：入场节奏 token 化；全局动效开关 **在测试环境自动关闭**（避免无限动画卡住 `pumpAndSettle`）；**交错入场**——首屏 36ms/条、240ms 单条、最长 528ms 封顶，翻页追加 20ms / 180ms / 300ms，配 `EntranceLedger` 记账（滚出滚回不重播），应用于评论、历史、收藏夹、夹内视频、搜索结果（视频 / 番剧 / UP 主）、信箱、UP 主页、关注导入；**页面转场升级为三段式**（淡入 + 3% 上滑 + 下层压暗），**播放页走快速淡入无位移**（配合封面飞入）；新增 `app/lib/widgets/cover_hero.dart` + 播放页封面占位层——**点卡片时封面飞入播放页**（原生纹理无法 Hero，故为「封面 → 占位 → 淡出露画面」的假转场，含 1200ms 兜底超时）；播放页信息块**延迟补场**（120ms 后 320ms 内淡入 + 96%→100% 微放大），与封面飞行时间重叠
- **加载动画与加载文案（新 `app/lib/widgets/smoke_silhouette.dart`、`app/lib/widgets/animated_copy_line.dart`）**：**通用风衣男抽烟剪影**（不指向任何具体角色，规避版权），剪影用主墨图形档、烟用点缀墨，3 条非等分相位烟缕为确定性动画（3200ms 周期）；`AnimatedCopyLine` 逐字淡入 + 上浮 4px；新增 `AppLoadingHero`（剪影 + 主文案 + 逐字副文案），各页整页加载与分页 footer 换用；新增 **15 条可编辑加载文案**（`loading.line.*` / `footer.loading.*` / `loading.empty.*`），走既有 `UiCopyStore` 机制，用户可在设置里改写
- **其它视觉与交互收口**：空态 / 错误态统一到 `AppStateView` / `AppErrorView` + `DotIllustration` 细线插画（每页不同 seed），删掉 5 个重复的私有状态组件；合集卡成为视觉主角——**「N 天前更新 / 加入」角标**（点缀墨）+ **底部 3px 观看进度条** + 「已看 X/Y」；新增 `app/lib/widgets/add_success_button.dart`（「加入白名单」三态按钮 + **波纹扩散 + 描边生长对勾**确认动效）；播放页进度条从系统 `Slider` 改为自绘细轨（2px + 暗垫，亮 / 暗画面双向可见），底部按钮开启态加「纸白短线」（颜色不是唯一信息载体）；`HistoryStore.maxEntries` **200 → 1000**
- 修复 6 处模拟器实测发现的缺陷：导航描边不渲染、播放页标签截断、进度条亮底不可见、未读角标不随配色、返回键与横幅重叠、浅墨下热力图对比度不足；修复 2 个集成测试既有失败（comment_flow 日志白名单漏 `[comment_list]` 前缀；landscape_pin 依赖宿主机手工旋转 → 改为测试自触发）
- 测试：`flutter analyze` **0 issue**；全量 `flutter test` **1149 例全绿**（本轮由 866 例增至 1149 例，新增覆盖 token / 双墨配色与 WCAG 护栏、块组件 6 变体、交错入场与 `EntranceLedger` 记账、动效开关的测试环境自动关闭、加载文案可编辑等）；集成测试 **11 例全绿**（含横屏置顶模式流程）
- 验证：debug APK 装机模拟器（AVD `bili_test` / Android 15）实测取证——底部导航四页签切换与描边渲染、10 套配色切换即时生效且杀进程重进保持、块化观感（底材差 / 描边 / 左侧竖条层级可辨）、列表交错入场逐条浮现、剪影加载动画 + 逐字文案、点卡片封面飞入播放页（占位淡出露画面）、「加入白名单」确认动效（波纹扩散 + 对勾生长）

---

## v2.17.17 (2026-09-09)

**横屏置顶模式：退出全屏不再强制转竖屏——设备横放停在横屏「顶部置顶视频 + 下方评论区」；布局横竖屏自适应**

- **方向策略（`app/lib/pages/player_page.dart` `_toggleFullscreen` / PopScope）**：全屏（横屏）播放中点「退出全屏」或返回（顶栏箭头 / 系统返回键）→ **不再强制转竖屏**——方向放开为「竖屏 + 双向横屏」三向（`kPlayerPageFreeOrientations`：portraitUp + landscapeLeft/Right，不含 portraitDown 防倒持误入）：设备当前横放即**停在横屏「置顶+评论」模式**，设备竖放仍竖屏置顶+评论（兼容 v2.17.0 行为），之后旋转设备可在横/竖两态自由切换。**全屏中返回 = 先退出全屏**（回当前方向置顶+评论，页面不离开，再返回才离开播放页，`_handleBack` + `PopScope(canPop: !_fullscreen)`）；离开播放页 dispose 仍恢复系统竖屏 + edgeToEdge（`_restoreSystemUi` 现状保留）
- **非全屏布局横竖屏自适应（同一 Column 两分支）**：竖屏封顶比例不变（屏高 60%）；**横屏**（宽>高，屏高低）→ 视频区高度封顶改为屏高 **55%**（`kLandscapeVideoHeightRatio`，16:9 视频按屏宽换算理想高度≈整屏高，必须封顶留出下方内容；盒内画面仍按 AspectRatio 居中 + 黑边补齐），视频信息行**横屏自动紧凑**（标题 1 行 / 简介折叠少行，`_buildVideoInfoBar` 按方向取 maxLines/foldLines），简介「展开」封顶高度横屏收紧（48–80，`_descMaxExpandedHeight`），剩余高度全部留给**内嵌评论区**（Expanded 哪怕矮也可滚）；手势层/字幕/听视频占位/控制层仍只绑定视频区矩形（横屏非全屏同样生效，`_gestureAreaSize`/字幕 bottom/中央簇紧凑判定改为复用同一方向感知的视频区高度 `_embeddedVideoHeight`）
- 测试：新增 `test/player_landscape_pin_test.dart` widget 测试（platform 通道捕获 `SystemChrome.setPreferredOrientations` 实参：进全屏=[landscapeL/R] 锁横屏、退出/返回退全屏=放开三向、dispose=[portraitUp] 恢复——**方向策略核心证据**；另断言竖屏 400x800 与横屏 800x400 两态视频区封顶高度/信息行紧贴/评论区可见不越屏/全屏无下方内容区）；新增 `integration_test/landscape_pin_flow_test.dart` 真机验收（真实播放器 + 宿主机 adb 旋转打点：竖屏置顶→进全屏→横屏退出**停留横屏置顶+评论**（几何/评论区可滚/开弹幕不崩）→转竖屏回归→返回先退全屏）；`flutter analyze` 0 issue、全量 `flutter test` 通过（866 例）
- 验证：debug APK 装机模拟器（Android 15 API35，真实白名单视频匿名播放「Yazi 文件管理器」BV1yRkCYVEUT，onPrepared 852x480 + 进度保存/观看计时日志确认真实播放）——**集成测试 `integration_test/landscape_pin_flow_test.dart` 全流程取证（[集成] 几何数值）**：① 竖屏进入播放 屏=411x914，视频区 **411x231@顶 0**（宽高比封顶）、信息行顶=231、评论区 411x480 底 890≤914（竖屏置顶+评论）；② 进全屏 → 屏 914x411、视频区 **914x411 占满整屏**、信息行/评论区=0（全屏无下方内容区）；③ **横屏退出全屏 → 停留横屏置顶+评论（核心验收）**：屏仍 914x411（未强制转竖屏），视频区 **914x226@顶0 = 屏高 55% 封顶**、信息行顶=226、评论区 862x22 可见不越屏且 **上拉滚动 300px 生效（评论区可滚）**、全程 0 RenderFlex 溢出异常；④ 转回竖屏 → 回归 视频区 411x231@顶0 + 评论区 480（竖放兼容 v2.17.0）；⑤ 全屏点返回箭头 = 先退出全屏（页面不离开），再返回才离开播放页（dispose 恢复方向）。弹幕冒烟：横屏/竖屏置顶下开弹幕真实拉取 **121 条**、游标对齐/布局正常、开关关闭不崩；观看计时 +10s 累计正常。方向策略 API 侧证据在 widget 测试（platform 通道捕获 setPreferredOrientations 实参）

---

## v2.17.16 (2026-09-09)

**搜索页「搜索历史记录」+ 观看热力图配色改「相对制」（不再固定时间分档）**

- **搜索历史（本地，`app/lib/services/search_history_store.dart` + `search_page.dart`）**：三个搜索 Tab 共用一份本地关键词历史（shared_preferences 单 key JSON 数组，不入 Gist 不跨设备）——**去重置顶**（新搜置顶、重复关键词剔除旧位置移到顶部）、**上限 20 条**自动裁剪最旧、支持单删与一键清空；存储损坏（解析失败 / 非列表 / 脏元素）一律容错为干净数据，不崩溃不影响搜索（含损坏后 add 自愈，见单测）。**搜索页 UI**：进入搜索页输入框为空时（「全部 B 站 / 搜索 UP 主」Tab）显示「搜索历史」面板——标题行（历史图标 + 清空入口）+ 历史词列表（每行点 = **直接填入输入框并立即搜索**、行尾 X 或长按 = 删除单条）；切到「我的白名单」Tab 面板自动隐藏不挡本地列表（空历史也不显示）。**记录时机**：键盘搜索键 / 点搜索按钮 / 点历史词 → 记入历史（防抖自动搜索、切范围/排序自动重查**不记录**，避免把打字联想中间词刷进历史）；切 Tab / 切类型不影响历史。测试：store 单测（去重置顶 / 重复上移 / 上限裁剪 / 空词忽略 / removeAt / clear / 持久化模拟重启 / 损坏容错自愈 / dedupeFront 纯函数）+ 搜索页 widget 冒烟（空历史隐藏 / 历史词渲染 / 输入时隐藏清空恢复 / 点历史填入并搜索 / 键盘提交记录 / 单删 / 清空 / 白名单 Tab 不挡）
- **观看热力图配色改「相对制」（`watch_stats.dart` + `watch_stats_page.dart`）**：删除固定分钟分档（原 `watchLevel` 0..5 / `kHeatLevelColors` / `heatColorForLevel` 及其单测），改为窗口（近 53 周）内**最长单日观看秒为基准**的连续渐变——纯函数 `WatchStats.relativeIntensity(daySec, maxSec)` = `clamp(daySec/maxSec, 0, 1)`（max<=0 或无观看防除零返回 0；超长截断 1）+ `heatColorForIntensity(intensity)`（≤0 = 无观看浅近白底 #EBEEF5；≥1 = 最长那天**克莱因蓝 #002FA7**；0<强度<1 = 浅蓝起点 #D5E5FF → 克莱因蓝连续插值）；`HeatCell` 不再固化 level（渲染时按 `maxDaySecondsOfGrid(grid)` 实时算强度）——**数据只集中一天也能最深**（不再像固定分档那样日均 5 分钟永远浅色），任一天观看都能在窗口内找到相对深浅；图例改「无观看灰格 + 浅蓝→克莱因蓝渐变条」，说明文案点明「相对色阶：最深=近53周内单日最长观看，其余按当天/最长比例变浅」（原「档位：<5 分/…」固定文案移除）。测试：`relativeIntensity`（0/半量/1/超长截断/max≤0 防御/单日即最长=1）+ `heatColorForIntensity`（两端 + 0.5 连续插值 + 单调）+ `maxDaySecondsOfGrid`（取窗口最长 / 全 0 防御）
- 测试：新增 `search_history_store_test.dart`、`search_history_page_test.dart`（假同步服务 + 假 B 站 API 注入，不发真实网络），更新 `watch_stats_test.dart` / `watch_stats_page_test.dart` 配色与网格用例；`flutter analyze` 0 issue、全量 `flutter test` 通过（865 例）
- 验证：debug APK 装机模拟器——**① 搜索历史**：搜索页输入搜一次 → 清空输入框 → 「搜索历史」面板出现该词（uiautomator dump 见「搜索历史 / 关键词」文本）→ 点历史词触发搜索（输入框自动填入、日志出现搜索请求）→ 单删（行尾 X）/ 清空可用；**② 热力相对配色**：颜色为逐格渲染语义无法截屏取证——由「相对强度/配色纯函数单测 + 网格布局 dump（最长日格子 Semantics 文案）+ 最长日=最深语义」覆盖验证边界

---

## v2.17.15 (2026-09-09)

**根治播放中「间歇 2001/Source error」的必现路径——流 URL deadline 实测 2h + 主动预取到期前平滑换源**

- **deadline 实测（v2.17.15 前置侦察，`deadline_probe.py` 临时脚本，测完即删不入库）**：真实白名单视频匿名取流（WBI playurl，普通 + 番剧共 4 条视频 × DASH video/audio/mp4 durl），解析流 URL query 的 `deadline` 参数——**全部稳定 7200s = 整整 2 小时**（单位是 Unix **秒** ~1.7e9，2026-09 实测），且带防盗链头实测 HTTP 206 可取流。**结论：普通视频（<2h）播放中不会因 URL 到期中断，v2.17.14 观察到的「间歇 2001」主因是网络/CDN 瞬时错误（已由 v2.17.14 自动续播覆盖）**；但「超长视频（>2h）一次看完 / 长时间暂停后续播」仍会**用尽** URL 剩余有效期 → 到期后读流必失败——这是被动的 onUrlExpired「失败才恢复」无法消除的必然中断，本次根治
- **主动预取 + 平滑换源（Dart `app/lib/pages/player_page.dart`，v2.17.15）**：播放中每 10s（20 × 500ms tick）解析当前**网络流** URL 的 `deadline`（`streamDeadlineMs`/`streamDeadlineRemainMs`/`shouldPrefetchSource` 纯函数，单位秒/毫秒按量级自动归一）→ 判定「URL 剩余有效期不足以播完剩余内容 + 60s 提前量」→ **到期前主动重取 playurl（同集同清晰度）→ setDataSource(新 URL, 当前位置) 平滑换源**（复用续播路径，但 URL 尚有效时主动做，播放几乎无感）；换源成功记录新 deadline 继续周期判定。普通视频差量恒定 ≫ 提前量 → 判定不通过即零开销返回，**不发任何多余请求**
- **防冲突（与 v2.17.14 机制协同）**：预取进行中（`_prefetching`）与被动自动续播（`_autoRecovering`）**互斥**（入口互查对方）；`_initSession` 播放器重建代次校验（重进/手动重试/切集/换源时安全退出，防向新播放器重复 setDataSource）；用户 seek 拖动中不触发；换源节流 ≥90s（成功/失败都占位，防网络异常时请求风暴）；**换源失败静默不弹错**（URL 尚有效则下轮再试；预取期间原生若因 URL 真过期发 onUrlExpired 被让路 → 预取失败路径自动回退 `_onAutoRecover` 被动续播兜底）
- **deadline 缺失回退**：本地缓存播放 / URL 无 deadline 参数 → 不预取（本地文件不取网络流；无签名 URL 无过期概念），保持 v2.17.14 被动恢复
- 测试：新增 `player_prefetch_test.dart` 17 例（deadline 秒/毫秒/缺失/非法/相对串解析、剩余毫秒计算含过期、换源决策含边界/过期/缺失/时长未知/自定义提前量、常量自洽）；`flutter analyze` 0 issue、全量 `flutter test` 通过
- 验证：debug APK 装机模拟器——**① 换源执行路径**：临时把记录 deadline 压到「剩余 120s」（纯验证手法，验证后还原源码）→ 播放 ~10s 后日志出现「主动预取换源：URL 剩余≈…s」→ 重取 playurl → setDataSource → 再次 onPrepared 续播，播放未中断未弹错；**② 正常路径回归**：还原后普通视频（真实白名单视频）播放无任何预取日志（差量 ≫ 提前量，零请求零干扰）；真 deadline（2h）到期现场无法短时复现，由决策单测 + 换源执行路径日志 + 代码审查覆盖，边界见正文

---

## v2.17.14 (2026-09-09)

**播放中断自愈：网络抖动/读流超时（「播放失败（2001）：Source error」）不再打断观看——自动重取流续播 + 数据源超时调大**

- **根因**：原生 `DashExoPlayer` 只把 HTTP 403/404/410（流 URL 过期）归为 `onUrlExpired` 自动恢复；**读流超时（Media3 errorCode 2001 = `ERROR_CODE_TIMEOUT`）/ 瞬时网络 IO 错误（断连/解析失败）全走 `onError` → Dart 弹「播放失败（2001）：Source error」打断观看，需手动重试**。叠加 `DefaultHttpDataSource` 默认 connect/read 超时都只有 **8s**——弱网/抖动（慢速读流、秒级断流）很容易在 8s 处被误判超时
- **错误分类扩展（原生 `app/android/.../DashExoPlayer.kt`，v2.17.14）**：`onPlayerError` 的分类改为 `isRecoverableSourceError`——**URL 过期**（HTTP 403/404/410，另把 429/5xx 这类 CDN/网关瞬时故障一并纳入——重取流换新签名地址即可自愈）∪ **瞬时网络错误**（读/建连超时 `SocketTimeoutException`、域名解析失败 `UnknownHostException`、连接被重置/拒绝/断开 `SocketException` 等）→ 统一走 `onUrlExpired` 让 Dart **重取 playurl + setDataSource 续播（保留位置）**，不再弹错误；只有真失败（格式损坏/解码失败/本地文件缺失等）才走 `onError`。判定按 java.net 原生异常沿 cause 链查找，不依赖 media3 包装类型（1.5.x 已移除 `HttpDataSource.TimeoutException`，超时由 `HttpDataSourceException` 包 `SocketTimeoutException` 呈现，链式可达）
- **数据源超时调大（原生）**：connect **8s → 15s**（弱网建连/首字节慢不再误判）、read **8s → 20s**（单次 socket 读超时：正常传输数据连续，>20s 收不到任何字节 ≈ 连接已死；宁可多等配合自动续播兜底，不在慢网上误弹错）
- **Dart 自动续播（`app/lib/pages/player_page.dart`）**：`onUrlExpired` 事件语义扩展为「可自动恢复的数据源错误」，续播失败按退避 **1s→2s→4s 自动重试最多 3 次**（`kAutoRecoverBackoffMs`/`autoRecoverDelayMs` 纯函数）——**每段播放独立预算**：新流成功 READY / 手动重试 / 换源 / 重进清零，播放中多次零星网络抖动各自都有完整重试次数；防重入（`_autoRecovering`）+ 播放器重建代次校验（`_initSession`，防 await 间隙向新播放器重复 setDataSource）。**仍失败才显示「播放中断（网络或视频流异常），请重试」+ 重试按钮（手动兜底保留）**——2001 弹错打断观看成为极少情况
- 测试：新增 `player_auto_recover_test.dart` 7 例（退避表 1s→2s→4s 且递增、放弃文案非空、`autoRecoverDelayMs` 第 0/1/2 次分别 1000/2000/4000、第 3 次起超限返回 null、负数防御、预算与上限自洽）；原生错误分类无可复用 Kotlin 单测设施（`android/app/src` 无 test 源集），由 Dart 决策纯函数 + 代码审查 + 构建覆盖；`flutter analyze` 0 issue、全量 `flutter test` 通过（820 例）
- 验证：debug APK 装机模拟器（Pixel 9 API 35，软件渲染）实测——**① 正常播放回归**：真实白名单视频（火柴人 VS 我的世界，BV163426vE3s）起流 → `onPrepared 852x480 duration=740s`、进度持续前进并 10s 定时落盘（`保存进度 …9682 ms`），无回归；**② 自动恢复现场复现**：播放中一次真实 connect 失败（DefaultHttpDataSource 建连异常）→ 原生按新分类发 `onUrlExpired`（**未走 onError**）→ Dart 日志「自动续播第 1 次，退避 1000ms」→ 重取 playurl（dashV=4/dashA=3）→ setDataSource → `onVideoSizeChanged`/继续出帧——全程无「播放失败」弹错，旧代码此路径会直接弹错打断；**③ 手动重试兜底**：wifi+蜂窝数据全断后进入播放 → 取流失败显示错误视图（重试/返回按钮）→ 恢复网络点「重试」→ 再次 `onPrepared` 正常播放。**2001 读超时主动复现边界**：模拟器网络快，Progressive 源近整段 m4s 提前缓冲 + 蜂窝兜底链路，长时间断网不触发读超时——超时分类由真实 connect 失败现场（同一条 isRecoverableSourceError 链）+ 单测 + 代码审查覆盖；弱网真机上的实测反馈待后续版本收集

---

## v2.17.13 (2026-09-09)

**启动自动同步关注 → 白名单（增量静默）：每次进 App 自动把新关注的 UP 加进白名单；关注导入链路加固（"导入后白名单没几个"的解析容错修复）**

- **启动自动同步服务（新 `app/lib/services/followings_auto_sync.dart`，v2.17.13）**：首页 initState 后延迟 ~4s **静默执行一次**（登录成功返回后也顺手触发一次）——三关前置门禁（**未登录 / 未配 GitHub token+gist / 距上次成功同步 < 10 分钟** → 直接跳过，不发任何请求）→ 翻页拉 B 站关注（`fetchFollowingsOfMine`，20 条/页、**最多 10 页 = 前 200**，与手动导入页上限一致）→ 对不在白名单的关注批量 `UpownerWriter.addBatch` 增量加入（一次拉 Gist → 查重合并 → 一次写盘，复用导入链路）→ 有新加入自动刷新白名单列表（UP 管理页/信箱立即可见）
- **节流与提前停止（取舍）**：成功完成一次同步（含"没有新关注"）才记录时间戳，10 分钟内重复启动不重复拉取（防频繁重启骚扰 B 站接口）；翻页遇到**连续一整页（20 条）关注都已在白名单** → 提前停止（新关注总排在关注列表前面，后面的老关注基本已同步过——首次同步白名单接近空不命中该条件，自动拉满前 200 建库）；中途某页失败（网络/风控）用已拉到部分先增量同步；**失败一律不记时间戳 → 下次启动自动重试**
- **只增不删 + 手动移除跳过名单**：自动同步**只加不删**——B 站取关的 UP 不移出白名单（白名单是用户自管的集合，取关 ≠ 想删白名单）。反向保护：用户**手动从白名单移除**的 UP（UP 管理页移除 / UP 详情页「取消关注」两处）记入本地跳过名单（`SharedPreferences`），即便该 UP 在 B 站仍被关注，自动同步**不会把它悄悄加回**（手动优先于自动跟随）；重新手动加入后正常，之后再次移除会重新记录
- **静默原则**：成功/失败/跳过都**不弹窗不打扰**，只打 `[followings-sync]` debug 日志；任何异常兜底收敛为结果返回，不向上抛
- **「导入后白名单只几个/为空」排查修复（v2.17.13）**：代码审查确认 v2.17.12 链路（分页 `pn*ps<total` + 上限 200、addBatch 查重合并、Gist/缓存双写、UP 管理页全量 ListView 显示）逻辑自洽、单测覆盖；发现一个真实解析容错缺口——`fetchFollowingsOfMine` 单项解析的 `mid` **只接受 `num`**，若 B 站某时期把 mid 返回为**数字串**（B 站多接口已字符串化 id），整批关注会被当"缺 mid 脏条目"丢弃 → 表现为导入后白名单几乎没 UP。**修复：mid 解析 num/数字串兼容**（非法串按 0 由上层过滤），补单测。其余可疑点（登录账号与预期不符、真实关注确实少、Gist 读取回退）无法在无真实登录态下复现，需真机确认（见下）
- 测试：新增 `followings_auto_sync_test.dart` 18 例——纯决策 plan（未登录/未配置/10 分钟内节流带剩余时间/超窗与从未同步就绪）、纯查重 filterNewFollowings（白名单/跳过名单/无效/内部重复）、服务 syncOnce（未登录不发请求 / 未配置不发请求 / 首次 45 关注 3 页全量加入且只写一次 Gist+缓存并记时间戳 / 增量只加新 5 且整页已知提前停（2 页）/ 无新增不写盘仍记时间戳 / 二次启动节流不发请求 / 跳过名单不加回 / 中途页失败用已拉部分 / 拉白名单失败跳过）+ rememberManualRemoval 幂等；followings 接口补 mid 数字串解析用例；`flutter analyze` 0 issue、全量 `flutter test` 通过（813 例）
- 验证：debug APK 装机模拟器——未登录/未配置启动**静默跳过**（logcat 仅 `[followings-sync]` 跳过日志、无关注/白名单网络请求）；已配置 + 注入登录态后的真实同步链路（真实关注拉取/增量入白名单）需**真机登录**验证（模拟器无法收短信）

---

## v2.17.12 (2026-09-09)

**关注 UP 体系：App 内统一「关注 = 加入白名单 UP 主」+「导入我关注的 UP」批量加入（B 站关注列表 → 白名单，一个方向）**

- **B 站「我关注的 UP」接口（`app/lib/api/bilibili_api.dart` 新增 `fetchFollowingsOfMine`，v2.17.12）**：`x/relation/followings?vmid=<自己的 mid>`（需登录：无 SESSDATA 抛 -101「请先登录」；有 SESSDATA 但失效 → nav 拿 mid 抛 -101「登录已失效」）——mid 走 `_ensureMyMid`（nav 会话缓存，同收藏夹导入）；`pn/ps` 分页，解析 `data.list[]{mid/uname/face}` 转 [Upowner]（face `//` 补 https:；缺 mid 脏条目过滤；total 数字串兼容，负数/缺失按 0）；错误分类 -101/-412/-352/其他业务码 → [BiliApiException]、网络 [DioException] 上抛。**字段验证说明**：2026-09 实测本机匿名请求该接口一律返回 -101「账号未登录」（关注列表现在属个人账号数据，无法匿名看结构）——字段形态按 bilibili-API-collect 文档口径 + 防御解析实现；登录态真实列表需真机验证（模拟器无法收短信登录码）
- **「导入我关注的 UP」入口（新 `app/lib/pages/followings_import_page.dart`，UP 主管理页顶部第二按钮）**：首页 UP 主管理页（主页左滑第 2 页）标题下方新增「导入我关注的 UP」按钮（与「搜索 UP 主」并排）——点击走 [runFollowingsImportFlow]：**配置门禁**（未配 GitHub token/gist_id 先提示，不发请求）→ **登录门禁**（无 SESSDATA 提示「关注列表属于个人账号数据」并引导登录，登录成功继续/保持匿名中止）→ **勾选页**：页头「B 站关注共 N 位 · 已加载 M」（关注很多只拉**前 200 位**，超出提示「其余请分批搜索加入」——取舍：避免为全量关注反复请求触发风控）、列表行 = 勾选框 + 名字 + mid（已在白名单的关注项直接标「已关注」灰色不可选）、底部「全选/取消全选」+「加入白名单（已选 K）」、「加载更多」翻页（20 条/页，翻完提示已加载全部/已达上限）
- **批量加入只写一次盘（`UpownerWriter.addBatch` 新增）**：一次拉 Gist → 入参去重（内部重复/无效 mid 剔除）→ mid 查重（已在白名单跳过，计入 skipped）→ 合并 **一次 saveToGist → 一次写本地缓存**（非逐条 add 的 N 次拉/写）；全部已存在不发写请求；结果 [UpownerBatchResult]（ok/data/added/skipped），UI 汇总「已添加 X，跳过 Y（已在白名单）」；写入成功返回上一页自动刷新管理列表（pop(true) → onDone → 首页 `_load`）
- **App 内关注/取关（`app/lib/pages/upowner_page.dart` 顶部按钮统一文案）**：UP 详情页 AppBar 从「仅白名单时移除图标」改为**常驻「关注 / 已关注」文字按钮**（未关注：FilledButton.tonal「关注」→ `UpownerWriter.add` 加入白名单，成功变「已关注」+ snack「已关注：xx」；已关注：点按弹确认「取消关注 = 从白名单移除该 UP 主，不影响已加入视频，可随时重新关注」→ `removeByMid` 移除变回「关注」，留在本页可再关注）——**播放页 UP 入口 / 评论 UP 链接 / 搜索 UP 结果 / 白名单管理页**等一切进 UP 详情页的途径都可用；页面内改过关注状态后返回 pop(true)（PopScope 带返回值），上层刷新白名单快照（搜索页回跳刷新「关注」按钮与白名单 Tab）。搜索 UP 结果按钮文案由「加入/已加入」统一为**「关注 / 已关注」**（UpownerTile）；管理页副标题同步说明「关注 UP 主 = 加入白名单」
- **真实写入边界**：关注/取关/批量导入都要写 Gist——模拟器上未配置真实 GitHub token/gist_id，点击均走「请先到右上角管理入口配置…」门禁提示不落盘（配置后真机即可用）；**upowners 落库（Gist 内容 + 本地缓存）由 widget 测试用内存 GistApi + 记录型假同步服务验证**
- **反向同步取舍**：App 内关注/取关**只写白名单 Gist，不回写 B 站关注关系**（`x/relation/modify` 是官方账号操作、需 csrf 且属敏感动作，第三方客户端不代写）——「导入我关注的 UP」也只做 B 站 → 白名单单方向；若日后要双端一致需另行评估官方 OAuth/接口策略
- 测试：`fetchFollowingsOfMine` 单测 9 例（登录门禁不发请求 / nav mid 缓存与 vmid/pn/ps 参数 / face 补 https + total 字符串 + 脏条目过滤 / hasMore total 在场与兜底两分支 / list 缺失空页 / -101/-412/-352/其他业务码 / nav -101 / 网络 DioException）+ `UpownerWriter.add/addBatch/removeByMid` 单测 9 例（关注与取关文案、批量一次写盘、内部去重、已在跳过计数、全跳过不写盘、未配置门禁）+ UP 详情页关注按钮 widget 测试 5 例（关注写 Gist+缓存变已关注 / 取消关注确认移除回未关注 / 弹窗取消不变 / 未配置提示 / 返回 pop 结果）+ 导入流程 widget 测试 4 例（配置门禁 / 登录门禁中止 / 全选批量加入汇总与 Gist+缓存 / 翻页加载更多）；`flutter analyze` 0 issue、全量 `flutter test` 通过（797 例）
- 验证：debug APK 装机模拟器 uiautomator dump——UP 管理页出现「导入我关注的 UP」按钮、点击提示配置门禁；搜索 UP 结果行「关注」按钮、非白名单 UP 详情页顶部「关注」按钮可见可点（无配置不落盘、状态不变）；真实关注列表导入（登录态）需真机验证

---

## v2.17.11 (2026-09-09)

**收藏夹内搜索：夹内视频页加搜索框，输入自动拉全夹后本地按标题 / UP 主过滤（收藏夹直看补齐「找得到」短板）**

- **夹内搜索框（`app/lib/pages/favorite_videos_page.dart`，v2.17.7 收藏夹浏览第三层内）**：AppBar 下新增搜索框（放大镜图标 + hint「在收藏夹中搜索」+ 右侧清空按钮，输入防抖 400ms）——夹内条目来自 `fetchFavoriteVideos` 分页，B 站侧接口**没有夹内关键词搜索**，故采用 **「输入 → 自动翻页拉全夹（fetchFavoriteVideos 翻到 hasMore=false，按 bvid 去重）→ 本地过滤」** 路线：拉取期间列表区显示进度（转圈 + 「正在读取收藏夹全部视频（第 N 页）…」）；拉完按关键词本地过滤（新纯函数 `filterFavoriteVideosByKeyword`：**标题或 UP 主名**包含关键词、忽略大小写，对齐白名单 Tab 搜索语义）即时展示匹配列表，**跨页条目也能搜到**；点结果照常补 cid 播放（同浏览）
- **清空恢复分页浏览（取舍）**：点清空按钮 / 删光关键词 → 退出搜索恢复原分页浏览——**若已拉过全量，把整夹一次并入列表直显**（数据已在内存，不再需要上拉翻页，见底部「没有更多了」）；未拉过全量则保留原分页状态（滚到底继续从服务端拉）。搜索缓存留在内存：再次输入同一收藏夹关键词**直接本地过滤、不重复拉取**
- **交互细节**：输入防抖只管「何时开始拉全量」——本地过滤零成本、已缓存时逐字即时过滤，不会因边输入边拉触发重复翻页；搜索中**下拉刷新 = 重拉全量再过滤**（分页浏览时下拉刷新仍为清空重拉第一页，同时作废搜索缓存）；防抖窗口内 / 拉取中重复输入只更新过滤词，不重复发起；翻页循环带代际号，清空 / 刷新 / 页面销毁即放弃在途请求（不把过期结果串入新状态）；**无匹配提示「未找到匹配的视频」**；**夹内 >500 条（服务端 totalCount）搜索前 snack 提示「拉全量可能稍慢」仍继续**（取舍：夹内搜索必须见过全部条目才能保证匹配不漏，一般收藏夹数量可控；超大夹可接受进度等待或用清空中断）
- **失败兜底**：拉全量中途失败（风控 -412 / 网络 / 登录失效 -101）→ snack 区分提示并**退出搜索回到分页浏览**（已加载的浏览列表保留，不弹整页错误）；空夹 / 未登录 / 首屏错误等整页状态沿用原视图（无内容可搜，不显示搜索框）
- 测试：过滤纯函数 5 例（空白原样 / 标题子串 / 大小写不敏感 / UP 主名匹配 / 无匹配空列表）+ 夹内搜索流程 widget 测试 4 例（防抖窗口内不拉全量、到期自动拉全夹跨页匹配、点结果补 cid 播放回调；清空后整夹直显且无新增请求；无匹配提示；拉全量中途 -412 snack + 退出回浏览）；`flutter analyze` 0 issue、全量 `flutter test` 通过（770 例）
- 验证：debug APK 装机模拟器 uiautomator dump——夹内页搜索框出现、输入关键词自动拉全夹过滤（仅匹配项在列表）、清空恢复整夹浏览、点结果进入播放页

---

## v2.17.10 (2026-09-09)

**观看统计页重做：GitHub 官方样式克莱因蓝热力单张大图 + 总览移到热力下方 + 点日期格进当天观看历史 + 设置区内联页底（与首页齿轮共用组件）**

- **热力图重做（仿 GitHub 官方 contribution 常见样式）**：近 53 周**单张大图**（今天在最右列）、**圆角小方块**格子（圆角 3px、格间距 2px）、主色 **克莱因蓝 #002FA7 + 白**——无观看 = 浅近白底 `#EBEEF5`，有观看按分钟数 5 档蓝阶（<5 分 `#C7D8FF` → 5-15 `#7FA6FF` → 15-30 `#3D6EFF` → 30-60 `#1546C8` → ≥60 分克莱因蓝 `#002FA7`）；配色抽成常量 + 纯函数 `heatColorForLevel`（供渲染与单测共用）；保留月份标签 + 少→多图例；手机窄屏横向滑动看更早的周并**默认锚定到最近端（今天可见）**，平板等宽屏整图直接放下不滚动；今天的格子加克莱因蓝描边
- **总览统计移到热力下方**（原 2×2 总览卡在热力上）：观看热力 → 观看总览（今日 / 本周 / 累计 / 最长连续天 + 副信息「N 天有观看记录 · 平均每天 X 分钟」）→ 设置区，同一滚动页
- **点日期格进入当天观看历史（新 `app/lib/pages/daily_history_page.dart`）**：点任意日期格 → push 该日历史页，列出**那一天**的观看记录（按本地日期过滤 [HistoryStore]，复用抽取出的公共条目组件 [HistoryTile]），点击条目**续播**（同历史记录页模式：构造视频推播放页、进度自动恢复）；当天无记录显示空态「该日无观看记录」；格子带无障碍语义标签（日期 + 观看时长，读屏/自动化可用）
- **设置区内联统计页底部**：首页齿轮的管理面板内容抽取为公共组件 **`lib/widgets/manage_panel.dart` 的 [ManagePanel]**（B 站账号 / GitHub 配置 / 新建合集 / 合集管理 / 离线缓存 / 翻译服务 / 版本更新分区原样保留）——**首页齿轮弹层与统计页底部内联共用同一组件**（弹层模式点「登录 / 检查更新」先关面板再动作，`closeBeforeNavigate` 区分；统计页内联以「设置」为题嵌入滚动页底，登录入口在统计页也可直达）
- 历史记录条目组件抽为公共 [HistoryTile]（`lib/widgets/history_tile.dart`）：历史页与该日历史页共用，样式与交互不变（封面/标题/进度/相对时间、点击续播；删除入口仅历史页传 [onRemove] 时显示）
- 测试：统计页配色/顺序/点日进历史/设置区内联 widget 测试、该日历史页过滤纯函数 + 页面（只列当天/空态/点击跳播放页）、ManagePanel 抽取后渲染/保存配置/内联不 pop 测试（16 新增）；`flutter analyze` 0 issue、全量 `flutter test` 通过（761 例）
- 验证：debug APK 装机模拟器 uiautomator dump——统计页单张大图（月份标签/图例/今天格语义）、总览在热力下方（y 坐标序）、点有观看的日格 → 该日历史页列出当天条目、滚动到底设置区（「设置」+ GitHub 配置等分区）、首页齿轮弹层回归（「管理」面板各分区）

---

## v2.17.9 (2026-09-09)

**观看统计页：真实观看时长按天本地记录 + GitHub 风格蓝色热力图 + 总览（防沉迷数据可视化）**

- **真实观看时长记录（新 `app/lib/services/watch_stats.dart`）**：播放页按 **真实播放秒数** 累计——每 500ms tick 取一次位置，仅当 **playing 且位置增量 `0 < Δ ≤ 5s`**（连续前进）才累计：暂停 / 缓冲停住（Δ=0）、快退（负）、快进 3 秒 / 拖动 seek / 断点恢复 / 评论 ?t 定位（Δ 超阈值，且 seek 后重置累计基线防小跳误计）都不算观看；**听视频（纯音频）模式照常计入**（播放器位置照常前进）；屏幕熄灭后 Dart tick 被系统挂起 → 期间不计（取舍：以「位置真实前进」为口径，不做壁钟累计）。累计走内存，攒够 ~10s 或退出播放页时批量写 shared_preferences（不每 tick 写盘）；按**本地日期** `yyyy-MM-dd` 一天一值（跨日看自动落新一天），**保留近 400 天自动裁剪**，数据损坏 / 脏键容错视为空不崩溃。数据**仅本地、不入 Gist、不跨设备**（观看统计属个人隐私，与白名单云端同步体系隔离）
- **播放页接入**：`_tick` 增量累计 + seek 出口（快进/快退/进度条/横屏拖动/链接定位）与 `onPrepared`（新流）统一重置基线；dispose 兜底落盘
- **观看统计页（新 `app/lib/pages/watch_stats_page.dart`，主页 PageView 第 4 页 / index3）**：主页左滑两页到（主页 → UP 主管理 → 统计），顶栏新增 **「观看统计」图标直达**（animateToPage，tooltip），底部提示语更新为「左右滑动：历史 / 合集 / UP 主 / 统计」。页面布局：
  - **总览卡 2×2**：今日观看 / 本周观看（周一起算）/ 累计观看 / **最长连续观看天数**（streak），下方副信息「N 天有观看记录 · 平均每天 X 分钟」
  - **GitHub 风格热力图（蓝色主色）**：近 **53 周**网格（行 = 周一..周日、列 = 周，**今天在最右列**，未来格子留空）；格子按当天观看分钟分 5 档**蓝阶**（0=浅灰无观看，<5 分浅蓝 `#D5E5FF` → ≥60 分深蓝 `#0B5FFF`）；**点/长按格子**在底部详情条显示「yyyy-MM-dd · 观看 xx 分钟」；**月份标签**（列上方 x 月）+ **少→多图例**（档位说明）；热力可**横向滑动**看更早的周（左侧周几栏固定）；无数据显示空态「开始观看后这里会生成你的观看热力」
  - 统计页与播放页共用 [WatchStats] 单例；切到统计页时重读（同历史页约定）
- 测试：WatchStats 单测 21 例（累计纯函数排除跳变 / watchLevel 蓝阶分级 / 跨日 clock 注入 / streak / 400 天裁剪 / 损坏容错 / 持久化），统计页纯函数单测（53 周网格行列与今天落位、level 换算、月份标签、时长文案）+ 页面冒烟（空态 / 有数据渲染热力卡）；`flutter analyze` 0 error、全量 `flutter test` 通过（744 例）
- 验证：debug APK 装机模拟器真实播放约 60s（非 seek）→ 退出后统计页今日时长 ≈60s、热力今天格上色（日志 + UI dump 取证）

---

## v2.17.8 (2026-09-08)

**UP 主页接口修复：粉丝数读不到 + 进 UP 主页频繁「网络请求失败」（B 站 space wbi 接口风控与字段变化的兼容修复）**

- **粉丝数读取修复（根因）**：UP 主详情接口 `x/space/wbi/acc/info` 的 `data` **不含 `fans` 字段**（2026-09 匿名/登录态双实测确认：成功响应仅 name/face/sign/level 等，无 fans、无 card）——旧解析 `data['fans']` 恒为 null，粉丝数永远显示「—」。粉丝数改用 **`x/relation/stat?vmid=`（`data.follower`）**（B 站网页 UP 主页同源）：新增 `fetchUpownerFollower`（匿名实测稳定、错误分类与既有接口一致），页面层粉丝数独立于资料拉取——资料接口被风控时粉丝数照常显示
- **自动重试（吸收「重试几次后正常」）**：`acc/info`、`arc/search` 等 space wbi 接口对匿名/高频请求有**间歇风控**（-352/-412，实测等待 1~3s 后重试即恢复）——UP 主页进入时并发 3 个请求无任何重试，接口偶发被拦即整页「网络请求失败」。页面层新增**失败自动重试（退避 1s → 2s，最多 3 次尝试）**：`_loadInfo`（资料 + 粉丝数各带重试）、视频列表（指数退避，重试期间保持转圈不落错误态）→ 仍失败才显示既有整页错误 + 「重试」按钮兜底；重试不并发重复（`_loadingInfo`/`_loadingMore` 守卫 + 列表代际号 `_listGen` 防过期结果串入）、页面销毁即放弃、不无限循环
- **信息会话级缓存**：UP 主资料 + 粉丝数成功结果按 mid 会话级缓存（静态 `_upInfoCache`），**重进同一位 UP 主主页直接显示、不再请求** space wbi 接口（少请求即少触发风控）；缓存恰好缺粉丝数（上次 stat 失败）时补拉一次 stat
- **降级不阻塞**：资料接口（acc/info）匿名被 -352 拦截 → 自动重试后静默降级——粉丝数（stat 成功）照常显示、名字/头像回退 initial（搜索结果预填）或**视频列表作者名兜底**（标题/头像不全空），不弹整页错误
- **列表总数解析修正**：`arc/search` 的总数实测在 `data.page.count`（`list.count` 不存在）——旧解析恒 null、hasMore 只能「装满 20 就下一页」，**末尾必多打一次空页**（多余的风控触发面）；改为 page.count 优先、list.count 兜底，UP 主视频恰 20 条时不再多发空请求
- 错误分类保留：-412（风控）/ -352（限流）提示「请稍后再试」，网络失败提示检查网络

## v2.17.7 (2026-09-08)

**收藏夹浏览入口：首页「收藏夹」卡 → 我的收藏夹列表 → 夹内视频直接点播（白名单外可播，无需先导入）**

v2.17.5 打通了「收藏夹 → 白名单」的**导入**方向；本版补上**浏览**方向——不导入、不改白名单，登录后把收藏夹当「一个虚拟合集」直接看：首页合集区顶部新增固定的「收藏夹」卡（第一层）→ 我的 B 站收藏夹列表（第二层）→ 点某收藏夹看它的视频列表并可**直接播放**（第三层）。与白名单/UP 主页/搜索同一套「白名单外可播」模式：不写 Gist、不自动入库。

- **首页固定「收藏夹」卡（`app/lib/pages/playlist_page.dart`）**：合集区顶部（缓存栏下方）常驻一张入口卡，样式同合集卡但视觉可区分（folder_special 图标 + tertiary 渐变 + 副标「我的 B 站收藏」）；**不随合集列表滚动、空名单/未同步时也显示**。点击 → 登录门禁：收藏夹属个人账号数据——无 SESSDATA 先 snack 提示并引导登录（复用首页登录入口，登录成功才进总览）；会话已失效则由总览页内 -101 引导重登兜底
- **收藏夹总览页（新 `app/lib/pages/favorites_page.dart`，第二层）**：AppBar「收藏夹」；列表 = `fetchMyFavorites`（封面 / 名称 / 「N 个视频」，样式同导入弹层）；下拉刷新；错误可重试（风控 -412 / 其他 / 网络区分提示）；空态「还没有收藏夹」；未登录 / 登录已失效（-101）→ 整页「去登录」引导（登录成功自动重载）
- **夹内视频页（新 `app/lib/pages/favorite_videos_page.dart`，第三层）**：`fetchFavoriteVideos` 分页列表（上拉加载更多，hasMore 权威；行复用 [VideoTile]：封面 / 标题 / 时长 / UP 主 / 发布时间）；**点视频直接播放**——夹内条目无 cid → 先 `fetchVideoMeta` 补全（cid/pages/desc/owner，多 P 视频选集能力随之生效）→ 构造完整 WhitelistVideo → push 播放页；进度/历史等播放页常规能力正常，**不入白名单**；失效条目（view 62002）snack 提示并跳过不打断浏览；下拉刷新；空态/错误/登录失效（-101）均有整页状态与重试/去登录
- **取舍说明**：
  - **「收藏的合集」暂不展示**：收藏夹 `resource/list` 里的非视频条目（type≠2：音频/专栏/合集/剧集等）沿 API 层过滤被跳过，夹内视频照常显示；若某收藏夹全是这类收藏，视频页会显示空态并注明「非视频内容本版暂不展示」。接入「B 站合集收藏」浏览需另一套资源语义（resource/list 的 id_type 区分或独立合集收藏接口），留后续
  - **夹内视频仅观看、无「加入白名单」长按**：批量加入已有 v2.17.5 收藏夹导入、单条加入可用导入/搜索入口，本页保持纯浏览（防沉迷原则不变）
- 验证：新页面/首页入口 widget 测试覆盖（收藏夹卡存在与点击、未登录引导、总览与视频页数据渲染、点视频→补 meta→播放回调、62002 跳过）；`flutter analyze` 0 error、全量 `flutter test` 通过；debug APK 装机模拟器实测首页卡与未登录引导（模拟器无法收短信验证码，登录态真实链路需真机验证）

---

## v2.17.6 (2026-09-08)

**评论视频链接带进度跳转：正文贴 `?p=` / `?t=` 分享链接可跳到指定分 P 与进度**

B 站评论**没有专用的「跳转进度」标签**（web 评论仅纯文本链接），评论里想指到「某视频某分 P 的某个时刻」时，惯例是贴一条带 `?p=`/`?t=` 的完整分享链接（web 播放器直接支持这两种参数）。本版让 App 端评论链接同样认这两种参数：点击后**先跳对应分 P、再定位到指定进度**（覆盖该集的记忆进度——「链接定位」语义优先于「历史续播」）。

- **链接解析（`app/lib/utils/comment_links.dart`）**：新增纯函数 `parseVideoLinkPosition(url)`——解析完整视频 URL 的 `?p=<分P号 1起>` 与 `?t=<秒>`，输出 `pageIndex`（0 起）/ `positionMs`（毫秒）；`CommentLink` 新增这两个字段（video/b23 分类携带，裸 BV / 无参数链接 = null 维持旧行为）。**`t` 支持格式**：纯数字秒（整数 / 小数，如 `129`、`129.0`）与带单位 `Xs` / `XmYs`（如 `30s`、`2m5s`=125s，分/秒均可小数）——`mm:ss` 冒号与 `XhYmZs` 等其余格式**不支持**（保守按无 t 处理，避免错误定位）。`p`/`t` 越界不在解析层钳制（解析时不知道实际 pages），由播放端按实际集数/时长兜底。b23 短链：点击 resolveShortLink 后按**最终落点 URL** 再分类，天然拿到落点的 `p`/`t`。单测覆盖全部格式与非法/越界边界
- **播放页初始定位（`app/lib/pages/player_page.dart`）**：`PlayerPage` 新增可选 `initialPositionMs`——>0 时首次 onPrepared **直接 seek 到该位置并覆盖该集记忆进度**（不弹「已从上次…继续」）；null/<=0 保持原记忆进度恢复。内部引入一次性 `_pendingSeekMs`（用掉即清）：同视频跳分 P（`_switchToPage` 增可选 `seekMs`）、播放器未就绪时的入队定位都走它，切集/内部换源会显式清除防过期定位串台
- **评论点击分发（`app/lib/widgets/comment_list.dart` / `app/lib/pages/comment_page.dart`）**：`onOpenVideo`/`onNavigateToVideo` 回调新增 `pageIndex`/`positionMs` 命名参数（typedef `OpenCommentVideo`）；`_previewVideo` 把链接携带的 p/t 一路透传（b23 落点同）。分发语义（`openVideoInNewPlayer`）：
  - **带 p/t** = 明确的「跳到该视频该分P该时间」：**同 bvid → 本页内跳**（目标集=当前集 → 直接 seek t；其他分 P 且本页 pages 覆盖 → `_switchToPage` 切集 + 定位；pages 覆盖不了 → 兜底叠新页）；**异 bvid → 叠新播放页**并传 `initialPageIndex`+`initialPositionMs`（新页首次定位覆盖其记忆进度）
  - **无参数**：完全维持 v2.17.1 行为（同 bvid 正播第 1 集跳过、其余 push 新页从开头播）
  - **取舍**：同 bvid 带参用「本页内跳」而非叠新页——返回键语义仍是「回上一个视频」、省一个播放器实例（防双音轨机制只对叠页需要），且与选集 UI 的原地切集体验一致；无回调兜底 push 同样透传定位参数
- 验证：解析与分发逻辑由单测/行为测试覆盖（定位 seek 目标在 widget 测试中通过
  播放器通道日志断言：initialPositionMs → `seekTo 120000`、同 bvid 切分P →
  `seekTo 30000`、同集带 t → `seekTo 45000`，均覆盖对应集记忆进度）；debug
  APK 装机模拟器冷启动回归：进程正常、无崩溃/无 Dart 异常（真实评论里带
  `?p/?t` 链接样本难找，见 README 已知限制说明，点击链路由同一套分发代码承担）

---

## v2.17.5 (2026-09-08)

**B 站收藏夹 → 白名单互通（导入方向 MVP）：登录后把自己的收藏夹一键批量导入白名单**

「收藏夹与白名单互通」的导入方向打通——在 App 里登录 B 站账号后，可读取自己创建的收藏夹列表（默认夹/自建夹），选一个收藏夹把里面的视频**一键批量加入白名单**（查重跳过已在白名单的、失效稿件自动跳过）。反向（白名单新增自动收藏回 B 站）与双向自动同步超出本批次，见「取舍说明」。

- **API 层（`app/lib/api/bilibili_api.dart`）**：新增两个**需登录**的封装（登录态 Cookie 注入；接口均不需要 WBI 签名）：
  - `fetchMyFavorites()`：登录门禁（无 SESSDATA → 抛 -101「请先登录」）→ nav 接口拿自己的 mid（`data.mid`，会话内缓存）→ `x/v3/fav/folder/created/list-all?up_mid=<mid>&pn=1&ps=20` → 收藏夹列表（mediaId/title/mediaCount/cover，`media_id` 缺失时兜底 `id`、封面补 https、脏条目过滤）。**attr 位义未实测，不做过滤**（私密/默认夹等都返回，权限由 B 站接口控制）
  - `fetchFavoriteVideos(mediaId, {pn, ps})`：`x/v3/fav/resource/list?media_id=&pn=&ps=&platform=web` → 单页视频列表（bvid/title/cover/duration/pubdate/upName 雏形）+ totalCount + hasMore；type≠2（音频/专栏/剧集）与无 bvid 脏条目过滤
  - 错误分类与既有接口一致：-101（区分「请先登录」/「登录已失效」）/ -412 风控「请稍后再试」/ 其他业务码带接口 message / 网络 DioException 原样上抛
- **导入逻辑（`app/lib/services/whitelist_writer.dart`）**：`importFavoriteFolder(mediaId, folderTitle, {onProgress})` → 结果汇总 {total/added/skipped/failed/interrupted}：
  - 开头**一次**拉当前白名单 bvid 集合（失败不阻塞，addVideo 内部查重兜底）→ 翻页拉收藏夹全部视频（has_more 服务端给，防御上限 200 页）
  - 逐条：**bvid 查重跳过**（不发 view 请求）→ `fetchVideoMeta` view 复检补全 meta（cid/pages/desc/pubdate 等）→ 构造完整 WhitelistVideo → [addVideo] 写 Gist（再查重兜底 + 写本地缓存）
  - **失效条目**：view 复检失败 code 62002「稿件已失效」/ -404 已删除 → 计 failed 跳过、**不中断**其余导入；拉列表阶段失败（BiliApiException/DioException）在写任何东西前上抛
  - 逐条写盘失败不抛：中断并汇总（interrupted + interruptReason），已写条数见 added
- **UI（`app/lib/widgets/favorites_import_dialog.dart` + 首页）**：首页右上角「导入」对话框内新增「**从 B 站收藏夹批量导入**」入口（放导入入口而非管理面板——新增白名单语义与粘贴导入一致，管理面板保持「管理只允许合集/配置」的防沉迷边界）：
  - 流程：配置门禁（GitHub token/gist）→ **登录门禁**（无 SESSDATA → 提示「收藏夹导入需要登录 B 站账号」+ 引导进登录页；登录成功继续、保持匿名中止）→ 收藏夹列表弹层（loading / 失败重试 / 空态 / 列表展示封面+名称+数量）→ 选夹确认（提示夹内 N 个视频，说明自动跳过已在白名单/失效）→ 进度对话框「导入中 i/N」逐条写入 → 结果汇总 snack「已导入 X，跳过 Y（已在白名单），失败 Z」→ 刷新列表
- **取舍说明**：
  - **仅导入方向**：本批次做「收藏夹 → 白名单」批量导入（用户主动、确认式，符合防沉迷「新增须主动决策」原则）；反向（白名单新增自动收藏回 B 站）与双向自动同步是另一个方向（涉及 B 站写接口 + 双向状态一致性），不在本批次，后续可按需做
  - **单夹选择**：一次导入一个收藏夹（列表弹层选择后确认）；多收藏夹批量勾选导入留待后续（导入循环与进度已支持任意条数，扩展成本低）
  - **attr 不做过滤**：收藏夹 attr 位义未实测，全部原样列出由用户自己选（私密夹 B 站侧会校验登录态）
  - **失效条目不重试**：view 复检 62002/-404 计失败跳过；已失效内容 B 站收藏夹接口本身也不再返回
- **测试**：`test/favorites_api_test.dart`（登录门禁 / nav mid 解析与缓存 / list-all 参数与解析（media_id 兜底 id）/ resource/list 分页参数与解析 / -101 两种文案 / -412 / 其他业务码 / 网络）+ `test/favorites_import_test.dart`（导入核心逻辑：查重跳过省 view 请求、62002 失败不中断、拉列表失败未写 Gist、空夹；UI：未登录提示 + 引导、空夹弹层空态、首页入口存在与未登录引导）

## v2.17.4 (2026-09-08)

**UP 主主页「合集/列表」区（仿 B 站 UP 主页：展示该 UP 主的合集与列表，点合集看其视频，可播放/加入白名单）**

承接 v2.17.2（播放页 UP 主入口）。进入 UP 主详情页后，顶部新增「合集」区——列出该 UP 主的合集（season）与列表（series），点合集在其内浏览视频（点击播放 / 长按加入白名单），补充了 UP 主页的合集维度（此前只能看「全部视频」投稿流）：

- **API 层（`app/lib/api/bilibili_api.dart`）**：新增三个**匿名可用、无需 WBI 签名**的封装（带完整浏览器头 + buvid 指纹，与评论区接口同策略；登录态存在时照常注入 SESSDATA）：
  - `fetchUpownerCollections(mid)`（`x/polymer/web-space/seasons_series_list`）→ `UpownerCollectionsResult{seasons[], series[]}`，每项 `UpownerCollection{kind(season/series), id(season_id/series_id), name, cover, description, total, creator}`；`items_lists` 缺失 → 空结果（该 UP 主无合集非错误）；id/total 数字串（String）容错；脏条目（id≤0/空名）过滤；`creator='auto'` 的系列以 `isAuto` 标记（由页面层决定取舍，API 原样返回两类）
  - `fetchSeasonArchives(seasonId, {page})`（`x/polymer/web-space/seasons_archives_list`）→ `UpownerVideosPage`：`data.archives[]` **无 cid / 无 upper 名**（有 aid/bvid/title/pic/duration(秒)/pubdate），解析为 cid=0 的 WhitelistVideo（播放时 view 补齐）+ pubdate 记录，`page.total` 分页判断
  - `fetchSeriesArchives(mid, seriesId, {page})`（`x/series/archives`，参数 pn/ps）→ 同结构（`page{num,size,total}` 与 season 的 `page{page_num,page_size,total}` 字段不同，统一只取 total）
  - 错误分类与既有接口一致：-412 风控 / -352 限流 / 其他业务码带接口 message / 网络 DioException 原样上抛；code=0 无 data → 合集/系列视频接口按空页处理、合集清单接口抛「未返回数据」
- **页面（`app/lib/pages/upowner_page.dart`）**：顶部「合集」区（**只在拿到 ≥1 个合集/列表时显示**，无合集整区隐藏不占位、加载失败静默隐藏不影响主列表）——区头「合集」+ 横向 chips 行：第一个「全部视频」（默认，即原主列表），其后各合集/列表（season 名带「合集·」前缀、series 名带「 · 列表」后缀，均与 B 站展示一致）；点合集 chip → 下方视频列表**切换为该合集视频视图**（fetchSeasonArchives / fetchSeriesArchives 按类型自动选接口、独立分页滚动到底加载 20 条/页），此时**搜索框与排序 chips 隐藏**（搜索/排序仍只作用于「全部视频」原列表——合集视频按合集自身顺序展示）；点「全部视频」chip 切回原列表（搜索/排序恢复）。两个视图共用行组件与交互（点击 → 缺 cid 走现有 `fetchVideoMeta` view 补齐再进播放页；长按 → 「加入白名单视频 / 取消」）；切换视图自动滚回顶部；请求进行中切走 → 过期结果丢弃不污染新视图；按 bvid 去重防接口重复条目；滚动监听按当前视图分发翻页
- **取舍说明**：
  - **series `creator='auto'`（直播回放等系统自动生成列表）过滤不显示**：页面层把 `isAuto` 系列从「合集」区剔除（`fetchUpownerCollections` 原样返回、不丢数据）——与 B 站网页端 UP 主页一致：这类列表是系统按直播回放/视频自动归集的、非 UP 主动整理内容，放进来会污染该区（老番茄等 UP 的 auto 系列动辄十几个）；想看直播回放可回 B 站看
  - **合集/列表视频项无 cid / 无 upper 名** → 列表项 cid=0、upName 空串：点击播放复用现有「view 接口实时补 cid」流程（与 UP 主全部视频、信箱同款，实机验证取流日志带真实 cid）；UP 主页列表行本就不展示 upName，加入白名单走 view 补齐真实元数据
  - 合集/列表清单一次取一页（page_size=20，UP 主页一般 < 20 个；极端超 20 只显示第一页，注释已说明）
- **测试**：`UpownerPage` 增可选 `api` 注入参数（widget 测试注入 mock BiliApi）；新增 `app/test/upowner_collection_api_test.dart`（**17 个单测**：三个接口的 URL/参数构造、seasons_series_list `items_lists` 结构解析（seasons/series 分开）、meta 字段解析与 total/id 数字串容错、creator=auto → isAuto、脏条目过滤、空 items_lists、-412/-352/无 data 错误分类、seasons/series 视频 archives 解析（cid=0/duration 秒/pubdate/封面补全）与 page.total 分页、空页/脏 bvid 丢弃）；新增 `app/test/upowner_page_collections_test.dart`（**5 个 widget 测试**：有合集显示「合集」区 + chips（auto 系列被过滤）/ 无合集整区隐藏 / 点合集 chip 切换列表（搜索排序隐藏）+ 点「全部视频」切回恢复 / 点自建列表走 x/series/archives / 合集视频长按弹「加入白名单视频」菜单可取消关闭）
- **验证**：`flutter analyze` 0 issue；全量单测 **656 通过**（634 → 新增 22：API 17 + widget 5）；模拟器实测（真实网络 + 真实 App，匿名 720P）：首页合集卡「コデ」→ 串流教程视频（摄影师云飞）→ 播放页点 UP 主 → 进 UP 主页——**合集区出现**（uiautomator dump 文本证据：区头「合集」+「全部视频」chip +「合集·摄影师云飞的手机、平板测评」+「合集·智能手表」chips）；点合集 chip → logcat `fetchSeasonArchives season_id=754991`、下方列表切换为该合集视频（dump：搜索框/排序 chips 隐藏、9 个视频行）；点合集视频 → 进播放页 logcat `取流 bvid=BV11tbT6MEWv cid=41673623143`（合集接口视频无 cid，**真实 cid 由 view 补齐**）+ 720P DASH 取流成功 + 播放进度正常保存；返回后合集视图状态保留；集成测试 `integration_test/upowner_collection_flow_test.dart`（`flutter test integration_test/... -d emulator-5554`）真实网络通过：合集区出现 → 点「合集·摄影师云飞的手机、平板测评」→ 9 个视频行 → 点「全部视频」切回主列表（搜索/排序恢复）

---

## v2.17.3 (2026-09-08)

**视频简介（desc）：导入存储 + 播放页信息行显示 + 简介/评论过长折叠展开**

承接 v2.17.2（UP 主入口）。本版把「视频简介」接入全链路——白名单数据模型加 `desc` 字段并随导入写入（普通视频导入 + 油猴脚本），播放页竖屏信息行在标题/UP 主下方显示简介（过长折叠），评论区正文过长也折叠（评论/简介长文都支持「展开 / 收起」）：

- **数据模型 `WhitelistVideo.desc`（`app/lib/models/whitelist_video.dart`）**：新字段 `desc`（String，默认空串），视频级（多 P 视频简介不分 P、各分 P 共享）；`fromJson` 缺失/脏类型 → 空串不崩，`toJson` 非空才输出（无简介/旧数据不回写多余字段，与 epId/pubdate 约定一致），`copyWith` 沿用原值（合集移动/重排不丢简介）。兼容旧数据：无 desc 条目照常解析
- **导入路径写入 desc**：
  - **普通视频**（`app/lib/services/whitelist_writer.dart` `videoFromMeta`）：写 view 接口 `data.desc`（含 `\n` 换行原样；非 String 脏类型 toString 容错、缺失 → 空串）
  - **番剧/电影**（`videoFromPgcEpisode`）：**简介留空**（取舍说明见代码注释）——pgc 简介是**季级**字段（整季一段简介，不是每集一段），而番剧导入是**逐集**写 WhitelistVideo（一集一条），按季复制会污染每集且季简介更新要批量改；播放页简介区在 desc 为空时不显示也不占位，观感无缺口。「季级简介」留待后续（季导入入口把 season 简介存合集级/单独字段再按 seasonId 取）
  - **油猴脚本**（`bili-whitelist.user.js` v2.3.2 → **v2.3.3**）：`fetchVideoInfo` 两路（页面 `__INITIAL_STATE__.videoData.desc` / view API `data.desc`）都写 desc；parse/build 依旧整条透传/整对象序列化——新条目含 desc 随合并写回不丢、旧条目原样保留（遵循历史「upowners/collections 丢失」防丢字段教训，视频条目不做字段级重建）。node 逻辑自测：videoData 分支（零请求）/view API 分支写 desc、旧条目透传均通过
- **播放页信息行简介区（`app/lib/pages/player_page.dart` `_buildVideoInfoBar`）**：标题/UP 主行下方显示简介（小字灰色、紧凑）。数据优先 `WhitelistVideo.desc`；为空（旧数据/评论链接现构视频）→ **运行时补拉**：搭 UP 主元数据那次 `fetchVideoMeta` 的顺风车取 view `data.desc`（零额外请求；纯函数 `viewDescOf` 解析；结果按 bvid 会话内缓存 `_viewDescCache`，换源复位、按 bvid 对账防串台）。desc 为空（无简介/番剧季级取舍/拉取失败）→ **不显示简介区、不占位**。长简介超 3 行折叠省略 + 「展开」点击看全文、「收起」复原；展开态封顶高度内可滚动（防超长简介把固定信息行撑爆布局，`_descMaxExpandedHeight` 按屏高/视频区高动态取值）
- **折叠组件 `ExpandableText`（新 `app/lib/widgets/expandable_text.dart`，播放页简介与评论正文共用一份折叠逻辑）**：按**行数**折叠（LayoutBuilder 拿可用宽 → TextPainter 按 foldLines 布局 → didExceedMaxLines 超行即折叠，换行/宽字符/字号按真实排版算，比字符数阈值准）。纯文本形态（完整态 SelectableText 保选择复制；折叠态 Text+ellipsis）与富文本形态（链接混排，折叠/展开 Text.rich，识别器复用安全）都支持；`copyTip` 长按整段复制兜底、`maxExpandedHeight` 展开封顶内部滚动可配
- **评论区正文折叠（`app/lib/widgets/comment_list.dart`）**：`_LinkifiedBody` 改走 `ExpandableText`——评论正文超 5 行折叠 + 「展开」，点击展开全文 + 「收起」复原；纯文本短评保持原 SelectableText 选择/复制交互；**与链接渲染共存**：正文含链接时折叠态 Text.rich 截断、展开恢复完整链接混排（链接可点、URL 尾随标点裁剪语义不变），折叠态/富文本整段长按复制兜底保留。展开状态按条存在组件 State 内：同屏父级重建不丢；滚出 ListView 视口销毁后重折叠（简单方案，注释说明）
- **验证**：`flutter analyze` 0 issue；全量单测 **634 通过**（620 → 新增 14：模型 desc 序列化/脏类型/往返/copyWith 5、`videoFromMeta` 写 desc/脏类型容错 + `videoFromPgcEpisode` desc 留空 3、`viewDescOf` 2、`ExpandableText` 折叠展开 widget 测试 4——纯文本短文不折叠/长文展开收起/富文本链接混排折叠/封顶滚动）；模拟器实测（匿名 720P）：旧数据（无 desc）播放正常、信息行无简介区不占位（dump 证据）；真实 view 接口拉取正常（logcat `UP 主信息 mid=…`）；简介折叠交互由 `flutter test integration_test/desc_fold_flow_test.dart -d emulator-5554` 在模拟器真实运行验证（条目标注 desc → 折叠「展开」→ 全文「收起」→ 复原；旧数据无 desc → 运行时补拉显示简介区；无简介视频不占位）
- 说明：本机模拟器匿名登录态下 Gist 写入/大会员取流受环境限制，导入写 Gist 链路未在模拟器端到端复测（由单测 + 油猴 node 自测覆盖写入 JSON 含 desc 与透传），播放页简介显示链路已用「运行时补拉」等价路径实机验证（同一 `ExpandableText` 与简介区代码路径）

---

## v2.17.2 (2026-09-07)

**播放页 UP 主入口（阶段 C 收尾：竖屏信息行 UP 主区仿 B 站——头像 + 名字进 UP 主页）**

播放页竖屏大重构三阶段收官（A 竖屏布局 → B 跳转导航 → C UP 主入口）。本版把 v2.17.0 信息行里 UP 主名文本占位升级为可点的 UP 主入口，**不扩大 WhitelistVideo 模型**（白名单数据 / 导入 / 油猴链路零改动），mid/头像运行时补齐：

- **UP 主区（`app/lib/pages/player_page.dart` + 新组件 `app/lib/widgets/upowner_badge.dart`）**：普通视频信息行显示**圆形头像（32px，UA/Referer 防盗链头 + 失败/空 → 首字圆形占位）+ UP 主名**（可点、紧凑不喧宾夺主）。mid/face/真名由运行时 `fetchVideoMeta(bvid)` 取 view 接口 `data.owner{mid,name,face}` 补齐（纯函数 `parseViewOwner` 解析，防御脏数据；结果按 bvid **会话内缓存** `_upMetaCache`，多播放页/多 P 切集不重复请求；换源 `playVideo` 后复位重拉、按 bvid 对账防串台）；真名拉取成功后覆盖 up_name 展示
- **点击分发**：有 mid → 进 `UpownerPage(mid, initial: Upowner(预填头像名))`——**push 前自动暂停本页并保存进度**（复用阶段 B 的让路机制），从 UP 主页返回时 `didPopNext` 恢复续播，且从 UP 主页再点开视频不会双音轨；mid 未取到/失败 → 名字照常显示、点击 SnackBar「无法获取 UP 主信息」，不进页
- **番剧 / 电影（带 epId）取舍（弱化）**：pgc 内容挂靠官方/搬运号，无 UP 主页点播价值且易误导——**不拉 owner、信息行显示剧集标签**（导入的 up_name，空则「剧集」）、**不可点**；旧版导入的无 epId 番剧数据无法区分，走普通视频路径（行为按 view owner 实测，属已知边界，注释已说明）
- **验证**：`flutter analyze` 0 issue；全量单测 **620 通过**（609 + 新增 11：`UpownerBadge` 渲染/占位/点击分发/纯展示 5 个 widget 测试 + `parseViewOwner` 解析 6 个单测）；模拟器实测（匿名 720P）：播普通视频 → 信息行 UP 主区拉取成功（logcat `UP 主信息 mid=… name=摄影师云飞`）、点击进 UP 主页 mid/名字一致（头部预填即时显示，acc/info 匿名被 -412 限流属环境条件）、返回续播恢复；番剧集（epId）→ 不拉取 owner、信息行剧集标签、点击无跳转（按设计）

---

## v2.17.1 (2026-09-07)

**评论视频链接跳转可返回（阶段 B：push 新播放页 + 暂停旧页 + 返回续播）**

承接 v2.17.0（阶段 A：竖屏视频置顶 + 内嵌评论）。本版把「评论区点视频链接」从 **v2.16.23+ 的当前播放页换源（playVideo）** 改为 **push 新播放页**——跳转后可返回，返回时回到上一个视频继续播放（无双音轨）：

- **路由可见性**（`app/lib/main.dart` + `app/lib/pages/player_page.dart`）：`main.dart` 挂全局 `RouteObserver<ModalRoute<void>>`（`routeObserver`，导出）；`PlayerPage` 实现 `RouteAware`——`didChangeDependencies` 订阅 / `dispose` 退订，`didPopNext`（本页重新成为顶层）恢复续播；push 新 `PlayerPage` 的路由统一带 `RouteSettings(name: 'player')`（`kPlayerRouteName`），播放页内评论跳转 / comment_list 兜底 / 历史、收件箱、UP 主页、搜索、合集各入口全部统一
  - **机制取舍**（实现说明）：本 Flutter 版本 `RouteAware.didPushNext()` **无参**（RouteObserver 只通知被盖住的页、不传上方新路由），无法按「路由名 == player」在 didPushNext 里过滤——若无差别暂停，打开全屏独立评论页（边看边评）会被误停。因此**暂停改在 push 新播放页的调用点显式执行**（`_pauseBeforePushingNewPlayer`：pause + 保存进度 + 置标记），**恢复续播走 didPushNext 的对称事件 didPopNext**；didPushNext 不覆盖（忽略）
- **评论链接跳转语义**（player_page / comment_page / comment_list）：内嵌评论 onOpenVideo 与独立评论页 C 内链接统一 → **push 新播放页**。全屏独立评论页 C 打开时播放页**不暂停**（边看边评）；C 内点链接 → **C 先 pop 自己**（让旧播放页重新成为顶层，否则 P2 叠在 C 上旧页收不到任何通知）→ 播放页 push 前显式暂停旧页 → 叠 P2。C 均带回调；无回调兜底仍 push 新播放页（路由名 player，双音轨取舍见 comment_page 注释——当前 C 唯一入口是播放页、必传回调）。同 bvid 且在播第 0 集点本视频自身链接 → 不暂停不叠页
- **playVideo 换源保留**：`playVideo` 方法语义不变（当前页停旧播新），保留给多 P 切集 / 内部换源场景，不再由评论触发；同 bvid 判定等行为不回退
- **验证**：`flutter analyze` 0 issue；全量单测 **609 通过**（606 + 新增 3：P 叠 P2 暂停/P2 返回恢复、打开独立评论页不暂停（边看边评）、同 bvid 不叠页；既有 playVideo 换源 / CommentPage 回调 / 兜底测试适配新语义）；模拟器实测：播 A（取流成功/内嵌评论加载）、全屏打开独立评论页期间 A **持续播放不暂停**（保存进度持续推进、无暂停日志）、返回后仍续播（无 didPopNext 误触发）；「评论链接 → P2 → 返回续播」完整链路由 widget 测试覆盖（本机白名单视频评论均不含视频链接，无法在真机有机触发评论链接跳转——如实说明）
- 阶段 C（竖屏信息行 UP 主头像/主页入口等）按计划留待后续版本，本版未做

---

## v2.17.0 (2026-09-07)

**新功能：播放页竖屏布局重构（视频置顶 + 内嵌评论区）**

此前播放页**竖屏也是全屏黑底**：视频按宽高比垂直居中、上下大黑边，评论区需点「评论」进独立页。本次按 B 站观看页习惯重构竖屏（非全屏）形态：

- **竖屏布局（`app/lib/pages/player_page.dart`）**：
  - 页面改为：**上部视频区**（按视频宽高比铺满可用宽、顶部置顶；超高视频如 9:16 封顶屏高 60%，盒内画面居中 + 黑边补齐，给下方内容留位）+ **视频信息行**（标题/分 P、UP 主名文本占位——阶段 C 再加 UP 头像与主页入口、时长）+ **内嵌评论区**（滚动）
  - 画面/听视频占位/弹幕/字幕/手势/控制层**全部绑定在视频区矩形内**（不再整屏黑底、不再覆盖下方评论区）；字幕改为相对视频区底部定位（控制层显隐时 92/16），音量/亮度滑动换算与豁免带判定改用视频区尺寸
  - 听视频占位界面压缩适配矮视频盒（可滚动防溢出）；竖屏视频区过矮（超宽视频 <230px）时收起中央播放簇，双击播放/暂停仍可用
  - **横屏全屏保持原布局**（整屏播放、无评论区）；切换全屏布局联动正确
- **评论按钮**（控制层）：竖屏点击 → 平滑滚动定位到下方内嵌评论区（锚定列表顶「评论 N」区头）；横屏全屏点击 → 打开原独立评论页（返回后仍全屏续播）
- **内嵌评论区**（`app/lib/widgets/comment_list.dart` 新增，从 comment_page 抽取）：置顶/主评论分页上拉加载/楼中楼展开翻页/图片点击全屏查看保存/正文链接（视频/UP/番剧提示/外链）全部与独立评论页对齐；按「bvid + 当前分 P」换 key，**换集/换源自动重拉评论**；评论内点视频链接 → 本页实例换源（防双音轨，评论区随 key 刷新）
- `app/lib/pages/comment_page.dart` 改为薄壳（仅 Scaffold + AppBar 标题），列表逻辑统一走公共 `CommentListView`，两处不再双份维护
- **验证**：`flutter analyze` 0 error；全量单测 606 通过（含既有评论链接换源/倍速/历史/首页用例适配）；模拟器实测竖屏播放（视频顶部、评论区下方滚动）、全屏切换、评论按钮定位、换集评论刷新、字幕/弹幕在视频区内显示
- 阶段 B（评论链接跳转导航/返回续播）、阶段 C（UP 主入口）按计划留待后续版本，本版未做

---

## v2.16.24 (2026-09-07)

**修复**

- **修复"播放中关闭弹幕再打开 → 大量补发视频开头弹幕、时间轴错乱"**（用户报告：播到中段（如 3 分钟处）关弹幕再开，弹幕从视频开头密集涌出）：
  - **根因**（`app/lib/widgets/danmaku_overlay.dart` `_DanmakuOverlayState`）：弹幕层只在「开关开 && 有数据」时构建——**关弹幕 → overlay 卸载销毁 State；再开 → 全新 State**，`initState` 把发射游标无条件置 0；而发射循环对 `timeSec <= 当前播放位置` 的弹幕逐条发射 → 重开时游标从 0 起，把 **0 ~ 当前播放位置**整段弹幕按信用速率持续补发（开头弹幕成串涌出、时间轴全乱）。同理，「切集恢复进度 / 弹幕拉取完成晚于播放推进」时 overlay 直接挂载在中段也会补发
  - **修复**：发射游标的初始 / 每次复位统一改为**对齐当前播放位置**（新增纯函数 `danmakuCursorAt(list, posSec)`：在按 timeSec 升序的列表里二分找「首个 timeSec ≥ 当前播放秒」的下标）——弹幕层挂载 / 开关重开（initState）、切集换数据、设置变更清屏重载、seek / 恢复进度 >3s 跳变（didUpdateWidget）四条路径统一走该对齐；**严格已播过的弹幕（timeSec < 当前时刻）一律不再发射**，位置 0 时等价于从头开始（0 秒弹幕不误跳过，与发射口 `timeSec <= posSec` 自洽）
  - **顺带修复（同游标逻辑）**：seek **后退**时旧代码游标只前进（停留原前沿）→ 后退后到原前沿之间**长时间无弹幕**；现按新位置重算 → 后退越过的时间窗**重新发射**（与 B 站一致）
  - **单测**（`app/test/danmaku_features_test.dart`）：纯函数对齐语义（位置 0 / 中段 / 恰等于当前时刻保留 / 越末尾 / 空表 / seek 后退重算）；widget 测试「中段（3 分钟处）挂载：30 条开头弹幕一条不补发，播放位置越过 181s 只发后续那一条」（复现用户场景）；既有「positionMs 静态 2000 挂载即全量发射」类用例改「0 挂载 → 小步推到 2000」（对齐后语义一致）
  - **模拟器实测（logcat 文本取证，不读媒体）**：装 debug 包匿名播放白名单视频——开启弹幕时若 overlay 挂载在中段（播到 ~17s 才开/弹幕拉取晚于播放推进）见 `[danmaku] 游标对齐 pos=17123ms → cursor=1/17（跳过已播弹幕，不补发）`；完整复现「播到中段关弹幕再开」：45.4s 关（cursor=2/12）→ 播放推进 ~10s → 56s 重开 → logcat 见缓存命中 + `[danmaku] 游标对齐 pos=55897ms → cursor=2/12（跳过已播弹幕，不补发）`——游标保持推进后的位置不归 0，重开后按自然节奏发射后续弹幕，全程无开头补发、无二次清屏（对照修复前：重开即游标归 0，0~当前位置整段弹幕按 40 条/s 持续涌出）
- **「相同弹幕为什么乘几（×N）」结论：不是功能也不是 bug，App 无任何合并/计数显示代码**：
  - **代码证据**：全库 grep（× / merge / duplicate / mergeSimilar / count 等）确认弹幕渲染层（`danmaku_overlay.dart` `_spawn` 原样绘制 `d.text`）、数据模型（`danmaku.dart` 解析单条）、开关逻辑均无「合并相似弹幕显示 ×N」功能；git 历史五版弹幕迭代（v2.16.3/6/11/13/19）也从未加过
  - **数据证据**（2026-09-07 实测真实弹幕 XML）：B 站 `x/v1/dm/list.so` 对重复文案**逐条下发、不加计数、文本中不含 × 字符**（抽样 3600 条/视频：含 × 文本 0 条；同文案最多 2273 / 1554 / 814 条，且集中在同秒/邻近秒）——App 把 B 站下发的逐条原样渲染 → 同一文案短时间内**成串飞过**，观感上像「×N」
  - **处置**：保持现状不改代码（重复文案是 B 站数据本来的样子，逐条渲染符合「还原弹幕时间轴」语义）；「像 B 站官方播放器那样把同屏相似弹幕合并成一条 + ×N 角标」属于**新功能**（需要去重折叠 + 角标绘制），不在本次 bug 修复范围——是否要做请用户拍板（见 README 弹幕段说明）

---

## v2.16.23 (2026-09-07)

**修复**

- **修复"播放页打开评论区 → 点评论里的视频链接 → 跳转预览播放新视频时，旧视频音频仍继续播放"（双音轨）**：
  - **现象**：播放页 P 播视频 A → 点底部「评论」push 评论区 C（P 正常继续播，边看边评的预期行为）→ C 里点视频链接 → 旧实现 push 第二个播放页 P2（叠在 C 上）→ 栈 [P, C, P2]——**P 的播放器未释放**，P2 播视频 B 时 P 的 A 音频仍在响 = 双音轨
  - **根因**（`app/lib/pages/comment_page.dart` `_previewVideo`）：评论正文视频链接（v2.16.19+ 可点）走「fetchVideoMeta → push 新 PlayerPage」——新播放页叠加在旧播放页之上，旧页的播放器/定时器/事件订阅从未 dispose → 两个 Media3 实例同时出声
  - **修复（点评论视频链接 = 切到该视频看：停旧播新，不叠页）**：
    - `app/lib/pages/player_page.dart`：新增可复用换源方法 `playVideo(WhitelistVideo)`——**在当前播放页实例停旧播新**：先保存旧视频进度/写历史（`_saveExitProgress`，自 `dispose` 提取共用）→ dispose 旧播放器并完整清理关联状态（tick/浮层定时器、事件订阅、实时转写、字幕轨道与文本、弹幕渲染数据、进度/错误/缓冲/手势 hud 状态等）→ 更新当前视频状态 `_video`（页面内全部 `widget.video` 引用改走 `_video`，保证标题/取流/弹幕/下载/历史/评论入口一致切到新视频）→ **复用首次加载流程 `_init` 重新取流**（本地缓存优先、bvid/epId 取流分支、记忆进度恢复）→ 弹幕开关仍开则自动拉新视频弹幕。不重建页面、不新增 Navigator 页
    - `app/lib/pages/comment_page.dart`：构造新增可选参数 `onOpenVideoPreview`（播放页打开评论区时传入）——点视频链接 → **回调播放页换源 + pop 评论页**回播放页即见新视频；无回调（评论页独立打开）→ 保持 push 新 PlayerPage 兜底
    - **取舍（不回归）**：UP 主页链接仍 push UpownerPage、外链仍走 url_launcher 系统浏览器——此时旧视频继续播是「边浏览边听」的可接受行为（不产生双音轨），维持现状
  - **单测**（`app/test/comment_video_link_test.dart` 新增，mock 原生播放器通道/HTTP 路由，全离线）：
    - `PlayerPage.playVideo` 换源：旧播放器 dispose、只新建 1 个播放器（无双播放器）、页面不叠加（标题切到新视频）；同 bvid 点击跳过不重载
    - `CommentPage` 有回调：点评论视频链接 → 回调拿目标视频 + pop 评论页；无回调 → 兜底 push 新 PlayerPage
  - **模拟器实测（logcat / uiautomator dump 文本取证，不读媒体）**：播 A → 开评论 → 点评论里视频链接 → 回播放页播 B：logcat 见新 bvid 取流 + `onPrepared`、旧播放器 `dispose` 日志（单播放器生命周期），全程无双音轨；UP/外链入口不回归

---

## v2.16.22 (2026-09-07)

**修复**

- **修复 vivo 真机"播放有声音没画面（一直黑屏）"**（用户 vivo V2364A 真机反馈；模拟器 AOSP 正常、无法复现）：
  - **现象**：点视频播放**有声音、无任何提示、一直黑屏**；同一 App 模拟器播放正常，用户真机历史"手动登录后有画面"，最新版本仍黑
  - **根因**（`app/android/.../BiliDashPlayerPlugin.kt` `createPlayer`）：原生插件把**自增序号**（`nextTextureId++`，从 1 起）当作纹理 id 返回给 Dart；而 Dart 侧 `Texture(textureId:)` 必须使用 Flutter 引擎在 `TextureRegistry.createSurfaceTexture()` 时**分配的纹理 id**（`SurfaceTextureEntry.id()`）。两者错位时，Flutter 引擎纹理注册表里查不到 Dart 传入的 id → `Texture` widget 无对应纹理可渲染 → 视频帧解码后只输出到 SurfaceTexture、**不上屏**；音频轨独立播放不受影响 → **黑屏但有声音**。模拟器恰好 id 巧合对齐未触发；vivo 真机引擎纹理分配起点/时序与自增序号错开 → 必现
  - **修复**：`createPlayer` 改为取 `registry.createSurfaceTexture()` 返回的 `entry.id()` 作为纹理 id（与官方 `video_player_android` 同源实现一致），并加 `Log.i` 便于真机取证
  - **真机验证（系统层文本证据，logcat 全量抓取）**：真机已装 v2.16.22（含修复）播放白名单视频——audio_flinger **持续 1 active track**（uid 10406 = App，音频真实输出）、播放页时间轴持续推进（30s 内 57:58→58:55）、**全程无播放错误**（Media3 无 error → 音视频轨解码正常，排除编码不兼容假说）；修复链路与官方实现一致（纹理 id 对齐 → 帧上屏）。⚠ 像素画面最终目视确认由用户在真机复核（本机约束禁读媒体/截图，无法自动化判色）
  - ⚠ 排查记录：vivo 设备 logcat 中 App 进程日志（含原生 `Log.i`）与媒体解码器日志（ACodec/Codec2）均不可见（平台裁剪），改用 audio_flinger / 播放页 UI 时间轴等系统层证据定位与验证

---

## v2.16.21 (2026-09-05)

**新增 / 改进（"进去即登录 + 1080P"链路做扎实——自动续期 + 失效自动重登 + 匿名明确提示）**

- **自动续期分档提前（`app/lib/api/bilibili_api.dart` `planSessionStart` +
  `app/lib/pages/playlist_page.dart` `_handleSessionOnStart`）**：续期触发阈值按
  refresh_token 有无分档——
  - **有 refresh_token → 距过期 < 15 天即静默续期**（SESSDATA 约 30 天有效，续期成功
    即把新 SESSDATA/新 refresh_token 入库 → 会话始终活跃在新窗口内，**登录一次长期
    不掉线**；约半月一次续期调用，频率远低于 B 站续期接口风控阈值——权衡后不做
    「每次启动都续期」）
  - 无 refresh_token（登录时未抓到刷新口令）→ 续期必失败，阈值保持 7 天（避免白跑
    失败请求）；已过期一律先试续期、失败再引导重登
- **续期结果分类处理（`refreshSession` 返回 `SessionRenewResult`）**：
  - `networkError`（网络/超时）→ 保留现会话、**下次启动再试**，彻底不打扰
  - `missingCredentials` / `tokenInvalid`（refresh_token 失效，-101 等）→ 会话**已过期**
    → 清失效凭据 + 自动引导重新登录；**未过期** → 保留现会话（SESSDATA 仍有效、
    1080P 继续——不打断可用会话强弹登录页；播放遇 -101 / 管理面板与播放页临近过期
    横幅会在会话真正失效前引导）
  - 响应解析兜底：新会话**同时兼容 Set-Cookie 与响应体 `data.sessdata`/`data.bili_jct`
    两种下发**（不同时期接口实现都覆盖），拿不到新会话绝不覆盖旧凭据
- **关闭登录页 = 明确匿名（不默认静默降级）**：
  - **首页**（`playlist_page.dart`）：无有效 SESSDATA 时 AppBar 下方显示提示条
    「未登录仅 720P，去登录解锁 1080P（登录一次，之后每次进入自动恢复）」，点按直达
    登录页；登录成功/关闭后即时刷新（无需重启）
  - **播放页**（`player_page.dart`）：匿名观看时顶部横幅「未登录仅 720P，去登录解锁
    1080P（登录一次长期保持）」，点按去登录；**登录成功才重取流解锁 1080P，未登录
    返回不打断当前播放**（`_goLogin` 按登录结果决策，失败态保留「去登录」按钮）
  - 登录成功保存后首页/播放提示即消失；登录态下播放取流自动 `qn=80`（1080P）
- **单测**（`app/test/auto_login_test.dart` 更新 + 新增 `app/test/session_renew_test.dart`
  / `app/test/playurl_auth_test.dart`）：
  - `planSessionStart` 双档阈值映射（有 token 15 天 / 无 token 7 天，含边界与已过期）
  - `refreshSession` 分类：缺凭据（不发网络请求）/ Set-Cookie 续期成功入库 /
    响应体兜底续期成功 / refresh_token 失效（-101）不动 storage / code=0 拿不到新会话
    不覆盖旧凭据 / 网络异常不动 storage
  - `fetchPlayUrl` **登录态注入断言**：有效 SESSDATA → 取流请求 Cookie 带 SESSDATA +
    buvid 指纹 + `qn=80`（1080P 链路）；匿名 → 不带 SESSDATA 仍可播；残留过期
    SESSDATA → 不注入 + 清除（v2.16.20 修复路径回归）
  - Widget：关闭登录页后首页显示「未登录仅 720P」提示条、点按再次请求登录；有
    refresh_token 提前续期窗口内续期网络失败 → 保留、不请求登录
- **模拟器实测（logcat + uiautomator dump 文本取证，不读媒体）**：
  - 无会话冷启动 → `[session] 启动检查：无 SESSDATA → 自动进入登录页` +
    `[session] 打开登录页（自动引导）`，dump 见登录页（banner 全文 + 短信登录
    手机号/验证码）；back 返回 → 首页 dump 含「未登录仅 720P…」提示条
  - 匿名播放：点合集视频 → `[bili_api] fetchPlayUrl qn=80 fnval=16 ok: quality=64
    (720P) dashV=4` + `[player] onPrepared 852x480` + 进度推进（无 BiliDashError）；
    播放页 dump 含匿名横幅文案
  - 注入合成有效会话（+30 天）冷启动 → `[session] 启动检查：会话有效（≥续期阈值），
    静默恢复`，无登录页弹出
  - 注入将过期会话（+10 天 + refresh_token）冷启动 → 进入提前续期窗口、真实发出
    续期请求 → 接口失败记录（模拟器网络层 badResponse；业务码 -101 判定留给真机）→
    `[session] 续期失败（networkError，未过期）→ 保留现会话`，不弹登录页、流程不崩
- ⚠ 验证局限：**真实登录（短信收码）→ 服务端真给 1080P 的端到端无法在模拟器完成**
  （无法收码、合成 SESSDATA 服务端不认）——App 可控链路（有效 SESSDATA 注入 +
  qn=80 请求）由单测 + 逻辑保证，请真机登录后复核 quality=80 下发

---

## v2.16.20 (2026-09-05)

**修复**

- **修复"未登录状态下点视频播放没画面（登录后正常）"回归**（用户 vivo 真机反馈）：
  - **现象**：v2.16.18 自动登录（启动自动处理登录态 + 移除首页登录按钮）后，未登录/会话过期的用户在首页点视频播放没画面；登录后（新会话）播放正常
  - **根因**（诊断）：v2.16.18 的启动自动登录在**会话已过期且续期失败**时会引导进入登录页，但用户跳过登录页（不登录）后，**secure storage 里残留的过期 SESSDATA 并未被清除**——旧实现（含 v2.16.18 前手动登录时代）认为"有会话就注入"。残留过期 SESSDATA 会在播放取流时经 `_injectAuth` 注入请求，B 站对**真实过期 cookie** 的 playurl 返回 **-101（登录已失效）**（注：伪造/无效 cookie 会被服务端当匿名处理给 720P，与真实过期会话行为不同）→ 播放页报"登录已失效"、无画面；重新登录（新有效 SESSDATA）后正常。模拟器（storage 空=真纯匿名）无法复现——匿名播放本就正常（`fetchPlayUrl quality=64` 720P → onPrepared），与真机"残留过期会话"状态差异即在此
  - **修复**（`app/lib/api/bilibili_api.dart` `_injectAuth` + `app/lib/pages/playlist_page.dart` `_handleSessionOnStart`）：
    - `_injectAuth`：读到的 SESSDATA 若本地解析**已过期**（`sessdataExpireAt`）→ **不注入**该失效会话（回退纯匿名请求，匿名 720P 实测正常），并顺带 `clearSession()` 清除失效凭据——播放取流不再被残留过期会话拖垮，未登录也能正常匿名播放
    - `_handleSessionOnStart`：会话已过期且续期失败 → 引导登录页前**先 `clearSession()` 清掉失效会话**（用户跳过登录页后处于真未登录态，后续播放走匿名正常，不再残留死 cookie）
  - **单测**：`pgc_playurl_api_test.dart` 新增"残留已过期 SESSDATA → 不注入（回退匿名）+ 清除失效凭据"（与 `fetchPlayUrl` 共用同一 `_injectAuth`，覆盖取流共用路径）；`auto_login_test.dart` 过期续期失败用例补断言"失效会话被清除"
  - **模拟器回归（logcat 文本取证，不读媒体）**：无 SESSDATA 冷启动 → `[session] 启动检查：无 SESSDATA → 自动进入登录页`（自动登录仍按预期触发一次）→ 返回首页正常 → 点视频 → `[bili_api] fetchPlayUrl ... ok: quality=64 dashV=4` + `[player] onPrepared` + 进度持续推进（无 BiliDashError）；评论/弹幕入口匿名抽查正常（fetchVideoComments ok / fetchDanmaku 206 条渲染无异常）
  - ⚠ 验证局限：真实"签名有效但已过期"的 SESSDATA 需真机真实账号复现（无法离线构造、不回显真实凭据），修复使残留过期会话不再被注入（本地即可判定过期并清除），真机请升级后复核

---

## v2.16.19 (2026-09-05)

**新增 / 改进**

- **评论区图片全屏查看 + 保存到相册**（`app/lib/pages/image_viewer_page.dart` 新增 + `app/lib/pages/comment_page.dart` 缩略图接入）：
  - 点评论图片（根评论 / 楼中楼子回复都有）→ 黑底全屏查看页：**PageView 多图左右滑动 + 顶部页码（`x/N`）/ 关闭**、每图 **InteractiveViewer 双指缩放 1~4x + 双击 1x↔2.5x**（以屏幕中心为锚点）；**1x 时禁平移**（横向滑动交给 PageView 翻页）、放大后优先平移看图——缩放与翻页手势不打架；图片加载失败灰底占位不白屏
  - **保存到相册**：底部「保存到相册」按钮 → Dart 带 UA/Referer 下载当前图字节（`lib/services/gallery_saver.dart`，dio，gif 存原始字节相册里可动）→ 原生 `GalleryController.kt`（MethodChannel `bili_whitelist/gallery`，与 MediaController/ApkInstaller 同风格手动注册）：
    - **通道选择：原生小通道（免第三方依赖）**——评估两条路（image_gallery_saver/gal pub 包 vs 原生 MediaStore），原生 ~30 行内搞定且不留弃维护包 → 选原生
    - **API 29+（主流，本项目 Android 10+ 目标）**：`MediaStore.Images` 插 `Pictures/BiliWhiteList`（RELATIVE_PATH + IS_PENDING 两步写，失败清理半成品条目）→ **零存储权限**
    - **API 26~28**（minSdk=26 需覆盖）：老式 `getExternalStoragePublicDirectory(Pictures)/BiliWhiteList` + MediaScanner 广播；需要 `WRITE_EXTERNAL_STORAGE`（Manifest 已加 `maxSdkVersion=28` 限定，Android 10+ 永不出现该权限）——未授权时原生 `requestPermissions` 自动弹系统授权框，结果经 `MainActivity.onRequestPermissionsResult` 转发给 GalleryController **补完挂起的保存**（Dart 一次调用即可，授权框期间 await 挂起）；拒绝 → SnackBar「未授予存储权限…」
  - 保存成功/失败中文 SnackBar（下载失败 / 权限拒绝 / 相册写入失败分文案）
- **评论正文链接识别与站内跳转**（`app/lib/utils/comment_links.dart` 新增纯函数 + `comment_page.dart` 渲染/分发接入）：
  - **拆分**：正文按链接拆「纯文本段/链接段」交替（`splitCommentLinks`）——覆盖完整视频链接（`www./m.`、带 `?p=` 查询）、**裸 BV**（`BV`+10 位，正文独立出现）、b23 短链（带协议头/裸 `b23.tv/xx`）、UP 空间（`space.bilibili.com/<uid>` 与 `/space/<uid>`，含无协议头）、番剧（`bangumi/play/ep|ss`，容忍大写）、通用 http(s)；**URL 在中文/全角标点处截断 + 尾随标点裁剪**（`链接。` / `链接，谢谢` 不吞标点）、换行正文不丢字、多个链接顺序拆分
  - **渲染**：有链接 → RichText 链接段**主色 + 下划线**可点（`TapGestureRecognizer`），纯文本段原样；**无链接评论保持 SelectableText**（选择/复制能力不变）；有链接的评论长按整段复制兜底（RichText 不可选）
  - **点击分发**：`video`（完整链接/裸 BV）→ `fetchVideoMeta` → `WhitelistWriter.videoFromMeta` → `PlayerPage` **站内预览播放（只播放不加入白名单）**；`b23` → `resolveShortLink`（复用 `utils/import_parser.dart`）重定向解析落点后按落点再分发（视频→预览 / 番剧→提示 / UP→主页 / 其他→浏览器；落点仍为短链防死循环直接浏览器）；`up` → `UpownerPage(mid)`；`other` → **url_launcher**（`^6.3.0`，新依赖）系统浏览器 `LaunchMode.externalApplication`（校验 scheme 只放 http/https，失败 SnackBar）
  - **番剧链接取舍（bangumi）**：App 无通用番剧/电影播放入口（番剧需导入白名单走选集 + 会员集 pgc 回退），评论内点击**不硬塞播放**，SnackBar 提示「番剧/电影链接：请在搜索页切换『番剧/电影』搜索后导入观看」——先做视频/UP/通用三类站内动作
- **弹幕顶/底与滚动分区重叠调整（上一任务遗留改动随本版一并发布）**（`app/lib/widgets/danmaku_overlay.dart` + `app/test/danmaku_features_test.dart`，顺带更新 `app/lib/models/danmaku_lanes.dart` 注释）：
  - **问题**：v2.16.13 显示区域把弹幕带等比压缩后，轨道数换算仍扣除顶部 3 行 / 底部 2 行固定行——区域 30% 时 8 行只剩 **3 条滚动轨**，小显示区域弹幕量被顶/底固定行**过度挤压**（滚动轨堵、弹幕密时丢弃多）
  - **调整**：顶锚以下**不再为顶/底弹幕分区避让**——**滚动轨道占满整条可用带**（`danmakuScrollLaneCount` 改为 `floor(带高/行高)` 钳 `1..60`，不再减顶/底固定行：100% 屏 756px → 28 条（旧 23）、30% 226.8px → 8 条（旧 3））；顶部弹幕从带顶向下堆叠（行 i y = 顶锚 + i×行高，新纯函数 `danmakuTopTextY`）、底部弹幕从带底向上堆叠（行 i y = 底缘 − i×行高 − 文本高，`danmakuBottomTextY`），与滚动轨道**纵坐标可重叠**；各自**内部**仍互不叠（滚动按轨道追尾碰撞、顶/底行分别堆叠、行满丢弃），所有弹幕 y 不越显示区域（底缘额外钳制在区域下界内，极小区域自动上提）
  - **单测**（`danmaku_features_test.dart` 弹幕组重构）：轨道换算 100%→28 / 30%→8 / 带高不足行高保底 1 / 超大屏封顶 60；顶/底行 y 换算（行 0 贴带顶 / 贴底缘、与滚动轨道同 y = 可重叠基础）；区域 30% 三类弹幕共存 widget 测试（y 不越区域）；`danmaku_lanes.dart` 仅注释对齐（底部行 0 = 贴底缘最底行，取行先取最底行向上堆叠）
- **发布元信息**：`pubspec.yaml` version 2.16.18+48 → **2.16.19+49**；依赖新增 `url_launcher ^6.3.0`

---

## v2.16.18 (2026-09-05)

**新增 / 改进**

- **自动登录（启动自动处理登录态 + 移除首页登录按钮）**——解决用户反馈「每次进 App 都要点首页"登录（解锁 1080P）"按钮」：
  - **根因**（诊断）：① 首页 AppBar 登录按钮是**无条件常驻渲染**（tooltip/图标固定为"登录（解锁 1080P）"，无任何登录态分支）——已登录用户每次进入仍看到"要登录"，反复误点/困惑；② **无 SESSDATA（首次/彻底过期）时没有任何自动登录路径**——旧 `_maybeRefreshSession` 只覆盖"已有 SESSDATA 且将过期→续期"，无会话直接静默跳过，用户只能手动点按钮；续期逻辑本身已挂 initState 且不依赖按钮（此项非问题）
  - **启动自动登录**（`app/lib/pages/playlist_page.dart` `_handleSessionOnStart`，首页 initState 触发，不依赖任何按钮）：读 secure storage——**SESSDATA 有效（距过期 ≥ 7 天）→ 静默恢复**，不弹任何界面；**距过期 < 7 天（含已过期）→ refresh_token 静默续期**（成功即静默；续期失败且**已过期**→ 自动引导重新登录；未过期 → 保留现会话不打扰）；**无 SESSDATA（首次使用/登出）→ 自动进入登录页引导一次**（防循环：本次进程只引导一次）。存储读取异常（插件缺失/Keystore 故障）静默跳过，不误导登录
  - **决策映射抽为纯函数**（`app/lib/api/bilibili_api.dart` `planSessionStart` + `SessionStartAction` 枚举）：`null → autoLogin / <7天 → refresh / ≥7天 → silent`，可单测
  - **移除首页 AppBar 登录按钮**（原 tooltip"登录（解锁 1080P）"IconButton 删除）；**次级"账号/重新登录"入口**移到**管理面板**（右上角齿轮 → 新增「B 站账号」区块：状态读实时——已连接/会话过期/未登录文案 + 「登录 / 重新登录」按钮，关闭面板后推登录页）
  - **自动引导登录页带提示条**（`app/lib/pages/login_page.dart` 新增可选 `banner`，自动路径传 `kAutoLoginBanner`：说明"登录后自动保存：下次进入自动恢复，无需再次登录；不登录也能看（最高 720P）"）；手动入口（管理面板）不显示提示条
  - 测试注入接缝：`PlaylistPage.openLogin`（测试替身记录"请求登录"而不推含 WebView 的真实 LoginPage——后者构造在测试环境 assert 平台未注册）
  - **单测**（新 `app/test/auto_login_test.dart`，11 用例）：`planSessionStart` 映射（null→autoLogin / ≥7天与恰好 7 天→silent / <7天与已过期→refresh）；widget（mock secure storage 通道 + 注入登录导航替身）——无会话冷启动**自动请求登录一次且带 banner**、多次 pump 不重复触发、有会话（≥7 天）**静默零请求**、<7 天缺 refresh 凭据续期失败未过期**保留不请求**、已过期缺凭据→**自动请求重登**、管理面板已连接「重新登录」/ 未连接「登录」入口与状态文案、首页无"登录（解锁 1080P）"tooltip。旧 `collection_page_test.dart` 拖动用例注入合成有效会话（测拖动与登录无关，无会话会触发自动登录页而 WebView 测试环境不可构建）
  - **模拟器实测（logcat + uiautomator 文本取证，不读媒体）**：无会话冷启动 → `[session] 启动检查：无 SESSDATA → 自动进入登录页` + `[session] 打开登录页（自动引导）`，uiautomator dump 见登录页（content-desc「登录」+ Back + banner 全文 + WebView 加载）；back 回首页无循环；注入合成会话（+30 天，仅结构合法的假凭据，非真实账号）冷启动 → `[session] 启动检查：会话有效（≥7天），静默恢复`、**无**登录页弹出，首页 dump 正常合集卡片；打开管理面板 → dump 含「B 站账号 / 已登录：B 站账号已连接（1080P 已解锁）/ 重新登录」
  - ⚠ **播放取流 1080P 档位说明**：App 取流注入 SESSDATA 逻辑未改动（既有实现 + 既有单测覆盖），合成会话服务端不认、无法在自动化中复现真实 1080P 档位；真实账号 1080P 请在真机登录后复核

## v2.16.17 (2026-09-05)

**修复**

- **横屏全屏从物理屏幕底部滑动仍误触发 seek（v2.16.14 豁免带未覆盖横屏物理底部）**：
  - **问题（用户实测反馈）**：v2.16.14 豁免带只查 Pan 起点的 y0 上下（底部/顶部带），但**横屏全屏旋转后物理屏幕底边（系统导航区）对应 Flutter 逻辑坐标的左/右边缘**（landscapeLeft / landscapeRight 分别是逻辑左或右边缘）——用户从物理底部上滑在逻辑上呈「起点贴逻辑左/右边缘、y0 在屏中部」的**横向滑动**（被判定 horizontal seek），不落任何 y 豁免带 → 豁免失效、仍被当 seek
  - **修复（`app/lib/pages/player_page.dart`）**：豁免带扩展为**四边**——`isExcludedGestureStart` 改为 `{x0, y0, width, height, topPx, bottomFactor, bottomMinPx, leftPx, rightPx}`（纯函数可单测）：**横屏左右边缘豁免带取与底部同宽**（`max(短边 ×8%, 48px)`，覆盖 3-button / 手势导航条物理高度换算 + 手指容差；**两侧都留**——物理底边随旋转方向映到左或右任一边，见类顶坐标说明注释）；竖屏左右 16px 窄带防误触；上下豁免参数与 v2.16.14 一致
  - **按下点判定（实测发现，v2.16.17 关键）**：豁免判定从 `onPanStart` 坐标改为 **`onPanDown` 按下点坐标**——`onPanStart.localPosition` 是手势**赢得竞技场那一刻**的位置（已滑过 touch slop、且边缘滑动常被系统手势区延迟释放，模拟器实测右缘起点内移可达 ~100px：胜出点 x0=811、距右缘 103px），按它判边缘带会漏判；`onPanDown` 在手指落屏第一时间回调、即真实触摸起点（实测贴边起点 x0=4 / 910 精确命中）
  - **实测（模拟器 logcat，横屏全屏 ROTATION_90、逻辑屏 914x411）**：左缘滑动按下点 x0=4、右缘 x0=910（y0=206 屏中部）→ 豁免日志命中、**无 seek / 无 hud**；显示空间底边条带按下点 y0=408 → y 底部带豁免命中、无 seek（系统手势区吞掉的场合 App 无触摸，也不会误 seek）；屏幕中部横滑 → 正常 `seekTo`（比例 -0.34 实测）。**竖屏回归**：底部带按下点 y0=869 → 豁免；中部纵向亮度（左半 50%→52%）/ 音量（右半 12/15→13/15）正常；中部横向滑动忽略（无 seek）；双击播放/暂停、单击显隐控制层、长按 2x 均正常
  - **单测**：`test/player_gesture_test.dart` 豁免组扩展为 12 用例——横屏 y0 屏中部 + x0 贴左/右缘 → true（v2.16.17 核心回归）/ 左右带外（x0 > 48 距缘）→ false（中部 seek 不被豁免）/ 竖屏默认左右窄带边界 / 左右带可调窄关闭 / 底部顶部带内边界 / 尺寸异常防御

---

## v2.16.16 (2026-09-05)

**新增**

- **视频列表项显示发布时间（`pubdate` 字段 + 各导入路径写入 + 列表展示）**：
  - **数据模型**（`app/lib/models/whitelist_video.dart`）：`WhitelistVideo` 新增可选 `pubdate`（发布时间，Unix 秒；视频级附加字段，向后兼容不升顶层 version——旧读者忽略该键、新读者缺省 null = 未知）；fromJson `is num` 防御（脏类型 → null 不崩）、toJson 非空才输出（旧数据不回写多余字段）、copyWith 沿用；新增 `formatPubdate()`（Unix 秒 → `yyyy-MM-dd`；null / 0 → 空串，供列表项拼接）
  - **普通视频导入**（`app/lib/services/whitelist_writer.dart` `videoFromMeta`）：写入 view 接口 `data.pubdate`（**秒**，实测单位与语义同搜索结果的 pubdate）；0 / 缺失 / 脏类型 → null（不写脏值）。`addByBvid`（首页粘贴链接导入 / 搜索页「加入」）自动带上
  - **番剧 / 电影导入**（`PgcEpisode` + `videoFromPgcEpisode`）：`app/lib/api/bilibili_api.dart` 的 `PgcEpisode` 新增 `pubTimeSec`——**2026-09 实测 `pgc/view/web/season` 的 `episodes[].pub_time` 是 Unix 秒整数**（与普通 view `data.pubdate` 同单位、逐集各不相同：Hand Shakers 每集差一周；**不需要毫秒换算**，区别于同条目里的 `duration` 毫秒），0 = 接口未给；`videoFromPgcEpisode` 透传为 `pubdate`（>0 才写）→ `importPgcSeason` 整季导入的每集自动带发布时间
  - **列表展示**（`app/lib/widgets/video_tile.dart`）：副信息行 `时长 · UP主` → 有 `pubdate` 时拼 ` · 2023-05-01`；**null / 0 不拼该段**（旧数据展示与旧版逐字符一致、不破坏布局）。合集页 / 未分类白名单列表等 `VideoTile` 使用方自动生效；历史页 / 搜索结果等数据源本无 `pubdate`，自然不显示（无异常）
  - **油猴脚本 v2.3.2**（`bili-whitelist.user.js`）：`fetchVideoInfo` 两路（页面 `__INITIAL_STATE__.videoData.pubdate` 优先 / view API `data.pubdate` 回退）为**新条目**带 `pubdate`（`toPubdate` 只收正数，0 / 缺失不写脏值）；`parseWhitelist` 条目整体透传 + `buildWhitelistJson` 整对象序列化 → 读到的**旧条目含 `pubdate` 原样保留**、合并写回不丢（遵循历史「upowners / collections 丢失」教训：新增字段不做字段级重建）
  - **单测**：`whitelist_video_v3_test.dart` 新增 pubdate 组（解析 / 序列化 / null 缺省 / 脏类型 / 往返 / copyWith / `formatPubdate`）；`whitelist_writer_test.dart`（videoFromMeta 带 pubdate / 缺失与 0 与脏类型 → null、videoFromPgcEpisode 透传 pub_time 秒 + 无 pub_time → null、toJson 往返）；`pgc_api_test.dart`（episodes[].pub_time 秒级解析断言）；新 `video_tile_test.dart` widget 测试（有 pubdate → `1:30 · UP主 · 2023-05-01`；null / 0 → 旧文案无日期段、不崩）
  - **实测（模拟器）**：以含 `pubdate` / 旧数据 / 真实番剧（`fetchPgcSeason` 真接口）三组数据驱动真实列表渲染，dump / logcat 文本取证显示日期、旧数据不显示且无异常

---

## v2.16.15 (2026-09-05)

**新增**

- **播放页评论区查看（只读，视频 / 番剧通用）**：
  - **入口**（`app/lib/pages/player_page.dart`）：播放页底部功能行新增「评论」按钮（弹幕与下载之间）→ 打开评论区
  - **接口**（`app/lib/api/bilibili_api.dart` + 新模型 `app/lib/models/comment.dart`）：主评论 `x/v2/reply/main`（**匿名可用**，带完整头 + buvid 指纹 / 登录态 Cookie，**无需 WBI**）——`fetchVideoComments({aid, mode=3, next})` 翻页**回传上一响应 `cursor.next` 原样**（不手写 +1），`data.replies[]` 解析（每条内嵌至多 3 条楼中楼预览）+ `top_replies` 置顶 + `cursor{next,is_end,all_count}`；楼中楼 `x/v2/reply/reply`——`fetchReplyChildren({aid, root, pn, ps})`，`hasMore = pn×ps < page.count`（空页不再多拉）。**oid 防御**：`replies[]` 中 `oid != aid` 的脏条目丢弃；错误分类：12002=评论区已关闭、-412 风控、-352 限流、网络 DioException（UI 各自提示 / 重试）
  - **aid 解析**：普通视频与番剧集统一按 aid 取评论——`resolveAidForVideo`（纯函数，meta 带 aid 直接用）+ `BiliApi.fetchVideoAid`（无 meta 时调 view 接口取 `data.aid`，番剧 ep 的 aid 与 `PgcEpisode.aid` 一致；失败提示重试）
  - **正文清洗**：`content.message` 的 `<br />` → 换行、HTML 实体 / 数字实体解码、残留标签剥除；图片 `content.pictures[]`（`img_src` http→https，`i*.hdslb.com` 无需 Referer，加载仍带浏览器头兜底；按原图宽高比占位；`play_gif_thumbnail` 标「动图」角标）
  - **评论页**（新 `app/lib/pages/comment_page.dart`）：AppBar「评论 N」（N=评论总数）或「评论」；列表项 = 圆头像 + 用户名 + 等级角标（Lv 色块）+ 正文（可复制 SelectableText）+ 图片（多图按宽高比、失败灰底占位）+ 点赞 + 相对时间 + 「N 条回复」；**楼中楼预览**（收起态缩进小字显示内嵌预览）→ 点「N 条回复」展开拉完整楼中楼（pn 递增翻页、hasMore「加载更多回复」、可收起）；**上拉加载下一页主评论**（滚动近底部触发，cursor.next 回传；到底显示「没有更多了」）；置顶评论顶部展示 + 「置顶」角标；空态「暂无评论」/ 12002「评论区已关闭」/ 错误态带重试；只读不写操作，长内容不截断（整页可滚动）
  - **单测**：`app/test/comment_model_test.dart`（消息清洗 / 图片 / 预览浅解析防嵌套 / resolveAidForVideo）+ `app/test/comment_api_test.dart`（请求参数 aid/mode/next 与 root/pn、解析、空态 null/[]、oid 不一致丢弃、cursor.next 透传、12002/-412/-352 / 网络、hasMore 换算、fetchVideoAid 三态）
  - **设备实测**（模拟器，`app/integration_test/comment_flow_test.dart` 真网络集成测试 + uiautomator/logcat 文本取证）：播放页「评论」→ 评论区加载（「评论 89」+ 置顶 + 用户名/Lv/点赞/时间节点齐全）；点「2 条回复」→ 楼中楼 `fetchReplyChildren` 展开成功；多页视频上拉翻页（第 2 页请求带上游 cursor.next）；带图评论图片真实加载（无「图片加载失败」）；番剧集（epId）aid 解析正确打开评论；无评论 / 关闭视频显示空态或关闭提示

---

## v2.16.14 (2026-09-05)

**修复**

- **横屏全屏滑动手势与系统手势冲突（从屏幕下方滑动唤醒导航误触发 seek）**：
  - **问题（用户实测反馈）**：横屏全屏（immersiveSticky 沉浸模式）时想从屏幕**底部**向上滑动唤醒 Android 三键导航 / 手势导航，App 手势层与系统手势区同时收到触摸——旧版单一 Pan 覆盖整屏，从屏幕下方发起的滑动被当成左右滑 **seek**（进度被拖走、时间浮层乱跳）；系统导航条在几何屏幕底部，这一带本就不该属于播放手势
  - **修复（`app/lib/pages/player_page.dart`）**：新增**手势起点豁免带**（v2.16.14+）——Pan **起点 y0** 落在屏幕**底部豁免带**（`max(屏高 × 8%, 48px)`，横屏屏高 ~400px 时取 48px 兜底宽于 8% 的 32px；竖屏 ~8% 屏高更宽）或**顶部豁免带**（固定 24px，横屏刘海 / 状态栏下拉区）内 → 本次 Pan **整体忽略**（不 seek、不调亮度/音量、不出 hud），把这段屏幕让给系统手势；屏幕中部滑动（seek / 亮度音量）完全不受影响。竖屏/横屏统一适用——竖屏从底部启动的纵向调节本就会被系统「上滑唤导航」抢占，豁免更安全
  - **豁免只作用于 Pan 滑动**：tap / 双击 / 长按不走 Pan 竞技场（tap 无位移不触发 Pan），底部带内单击显隐控制层照常；控制层按钮 / 进度条在 Stack 上层本就独立
  - **纯函数 + 单测**：`isExcludedGestureStart({y0, height, bottomFactor, bottomMinPx, topPx})`（纯函数，便于脱离 Widget 测判定）+ `test/player_gesture_test.dart` 新增 8 用例（底部带内含边界 / 带外 / 顶部带内含边界 / 中部净区 / 矮屏 minPx 兜底 / 纯比例模式 / 顶部可关 / 高度异常防御）
  - **实测（模拟器 logcat）**：横屏全屏底部区域横向滑动 → 无 seek / 无 hud 日志（豁免生效）；屏幕中部横向滑动 → 正常 `seekTo`；竖屏底部区域滑动 → 无亮度/音量调节日志、中部正常

---

## v2.16.13 (2026-09-05)

**新增**

- **弹幕显示区域设置 + 弹幕设置记忆（开关/区域/透明度全持久化，重启保持）**：
  - **问题（实测）**：v2.16.12 及更早弹幕在全屏弹幕带（屏高约 12%~82%）内自由滚动，观感上会飘到画面中下部**妨碍观看内容**；且弹幕开关状态只在内存——切出播放页/杀进程重启后回到默认关，用户每次看弹幕都要重新点开，区域/透明度等设置在面板内已自动保存但开关这一高频设置反而没记忆
  - **显示区域（`app/lib/widgets/danmaku_overlay.dart` + `danmaku_settings_sheet.dart`）**：设置面板新增「显示区域」滑杆（**10%~100%，10 步进**，说明"弹幕只在屏幕上方 N% 高度内滚动"）——弹幕带顶/底锚点随百分比等比压缩到屏幕上方该比例内，滚动轨道数按缩放后带高换算（新增纯函数 `danmakuScrollLaneCount(带高px, 行高)`：区域 100% 与旧版逐像素一致；30% 时滚动轨道 23 → 3 条，发射 y 上限 ≈ 屏高×30%）；底部锚点额外钳制在区域下界内（极小区域底部弹幕不越界）；区域/屏蔽/透明度任一设置变化仍走既有「新实例 → 清屏按当前位置重载」，区域调小即时清屏重排
  - **设置记忆（`app/lib/models/danmaku_settings.dart` + `player_page.dart`）**：设置模型新增 `enabled`（开关，默认关）与 `displayAreaPercent`（区域，默认 100）并随既有单 key JSON 一并持久化（旧数据缺字段回默认，兼容）；播放页「弹幕」按钮**点按取反即写入持久化**；进播放页异步读持久化 `enabled` 初始化开关——上次开着 → 本次进页**自动开并自动拉弹幕**（切集沿用既有「开关保持 + 自动换集弹幕」逻辑），重启 App 后开关/区域/透明度全部保持
  - **单测**（`app/test/danmaku_features_test.dart`）：settings JSON roundtrip / 旧数据缺字段回默认 / 区域脏值归一化（越界与非 10 步进收敛）；`danmakuScrollLaneCount` 换算（100% 与旧版一致、30% 显著减少、极小区域保底 1 轨、超大屏封顶）；store roundtrip 含新字段

---

## v2.16.12 (2026-09-05)

**修复**

- **播放页亮度/音量滑动手感（灵敏度过高 + 基准不可靠）**：
  - **问题（实测）**：v2.16.7~11 纵向调节换算「滑满一屏 = ±100%」，且手势过程中**把每次的目标值写回基准、下一帧再叠加上去**（`_adjustBase` 被逐帧改写）——换算双重叠加 + 满行程 100% 映射，手指动一点点亮度/音量就冲到 0 或 100；亮度基准依赖原生 `getBrightness` 读窗口亮度，原生把「窗口未覆盖（-1 = `BRIGHTNESS_OVERRIDE_NONE`）」换算成系统亮度兜底前若把 -1 原样透传，Dart 侧 -1×100 → clamp 到 0 → 基准错误导致跳变
  - **修复（`app/lib/pages/player_page.dart` + `app/lib/services/device_media.dart`）**：
    - **灵敏度 0.3**：`adjustPercent` / `volumeTargetLevel` 统一乘灵敏度 `kAdjustSensitivity = 0.3`——**完整上下滑一屏 ≈ 基准 ±30%**（旧版 ±100%），小幅滑动平滑小幅变化（滑 1/10 屏 ≈ ±3%；音量档位离散，小幅滑动按档取整静默），不再一碰就跳 0/100；clamp 不变（亮度 5..100、音量 0..100）
    - **基准在锁定后固定**：手势开始时异步读取一次原生基准（取到前不调节），之后目标始终 =「固定基准 + 累计比例 × 灵敏度」——消除逐帧改写基准的双重叠加，滑动可平滑回退、不越界；读取失败亮度兜底 50%（`getBrightnessPercent` 内置），音量（无有效档位）放弃本次手势、不硬设 0
    - **基准读取兜底（Dart 侧，可单测）**：`normalizeBrightnessPercent` 纯函数——原生亮度原始值 null / NaN / Infinity / 越界（含 -1 未设置被透传）一律回退有效默认（50%），有效 0..1 → 0..100 并钳制；`DeviceMedia.getBrightnessPercent` 保证**永远返回有效 0..100 值**（不抛异常、不返回 -1/异常基准）
  - **单测**：`app/test/device_media_test.dart` 新增 8 用例（-1/未设兜底、null/NaN/越界兜底、有效值换算）；`app/test/player_gesture_test.dart` 换算断言按灵敏度 0.3 更新（满屏 ±30%、1/10 屏 ±3%、音量满屏 +0.3×max 档、clamp 边界、负方向、亮度下限 5%）

---

## v2.16.11 (2026-09-04)

**修复**

- **弹幕滚动不连续（卡顿/跳跃/时快时慢）**：
  - **根因（实证）**：v2.16.6 弹幕位置推进与画面重绘解耦——Ticker 每帧在数据层面推进弹幕 x，但 **CustomPaint 只在"发射帧"（`changed → setState`）才真正重绘**。两批弹幕之间（可达父层 500ms 播放位置轮询间隔）弹幕位置在变、画面却不刷新，等下一次 setState 才一次性画出来 → 弹幕以 ~500ms 步长"瞬移"，表现为滚动不连续 / 跳跃 / 时快时慢（推进 60fps × 绘制 ~2-8fps）
  - **修复（`lib/widgets/danmaku_overlay.dart`）**：
    - **每帧落屏**：CustomPainter 挂到 `ValueNotifier` repaint 信号上，Ticker 每帧推进后 `value++` → 只 markNeedsPaint 本层（外层 `RepaintBoundary` 隔离，不 rebuild、不波及播放页整树）——推进的每一帧都真正画出来，滚动回到 60fps 连续
    - **时间基准（暂停/恢复/切后台不跳）**：帧间隙 > 100ms（切后台/引擎停摆/大卡顿恢复）→ 重置时间基准、本帧不推进（弹幕原地继续，不做大步补偿）；播放暂停期间基准每帧照常更新 → 恢复瞬间 dt 不跳变
    - **发射时间预算**：发射从"每帧条数上限"改为按**真实流逝时间累计信用**（40 条/s 封顶、单帧余额 4），seek/卡顿积压的密集弹幕不再一次性扎堆补发，按信用摊到后续帧逐个进入
    - 纯函数 `danmakuSmoothDt` / `danmakuCreditAfter` 可单测；TextPainter 缓存维持（发射时 layout 一次、每帧只 paint，无每帧重排）
  - **顺带健壮性修复（debug 构建下弹幕层 ticker 死亡）**：Ticker 帧回调发生在每帧 layout 之前，mount 后**首帧**回调时 render object 尚未 layout——原实现直接读 `context.size` 会触发 Flutter debug 断言（"has not been through layout"）并抛异常终止 Ticker 调度（此后弹幕完全不推进）。改为 `RenderBox.hasSize` 安全读取（`_currentSize`），layout 完成前该帧跳过布局/发射、下一帧补上，不抛异常。release 下原代码因断言关闭未暴露，但 debug（flutter run/调试）下弹幕层会静默失效
  - **单测**：`test/danmaku_features_test.dart` 新增 4 用例（dt 平滑/信用纯逻辑、逐帧推进 + 大间隙重置不跳变、暂停冻结 + 恢复平滑）

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