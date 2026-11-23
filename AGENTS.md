# AGENTS.md — amoTV（bili-whitelist）

B 站白名单点播安卓 App（Flutter，`app/`）+ PC 端管理 CLI（`whitelist.py`）+ 油猴脚本
（`amotv.user.js`），白名单数据经 GitHub Gist 同步。

## 第一件事：读 `docs/DEV_CONTEXT.md`

里面有模块地图（哪个文件干什么）、红线、存储 key、已知坑、门禁与发布流程。
**先读它，再按模块地图只读相关文件**；不要全库 grepping 重复调研。

## 最容易被违反的三条

1. **红线文件不改**：`app/lib/api/bilibili_api.dart` 的请求头 / 图片头 / 弹幕 WS、
   `app/lib/pages/login_page.dart`（允许新增方法，不许动既有头与登录页逻辑）。
2. **不新增 Dart 依赖**：优先用已有的 `dio` / `shared_preferences` / `path_provider` /
   `webview_flutter` / `flutter_secure_storage`；确需新增先说明理由。
3. **既有测试断言不许删或放宽**，除非是明确的设计契约变更并在提交信息里写清原因。

另外：`CHANGELOG.md`、`app/pubspec.yaml` 的版本号、`app/tools/` 发布脚本、
`amotv.user.js`、`whitelist.py` 由发布流程维护，别手改。

## 改完先跑门禁

```bash
bash app/tools/gate.sh --quick test/你改的_test.dart   # 开发中
bash app/tools/gate.sh                                 # 提交/发版前全量
```

不要跑 `flutter test -d <设备>` 或 integration_test：会重装 App、清掉登录态与本地数据。

## 发布前必读

发布用 `bash app/tools/release_all.sh <版本> --notes <正文文件>`。脚本里的 `git push`
可能被本机代理吞掉而仍返回 0，**发布后必须手工核验**：`git ls-remote` 看远端 commit、
`gh release view <tag>` 看 asset 的 `state=uploaded`。
