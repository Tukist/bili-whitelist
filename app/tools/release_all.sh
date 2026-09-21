#!/usr/bin/env bash
# ============================================================
# amoTV —— 一键发布（v2.38.0 起的主流程）
#
# 为什么有这个脚本：旧流程「版本自增 → 写 CHANGELOG → 各种人工核查 →
# commit/push → 构建 3 ABI → 上传 → 校验」耗时且每次都要人（或 AI）重复
# 判断同样的事。这里把机械步骤固定下来，人只需要提供版本号与 CHANGELOG 正文。
#
# 用法：
#   bash app/tools/release_all.sh <版本> --notes <正文文件> [选项]
#
#   <版本>          主版本号，如 2.38.0（构建号 +N 由脚本自增）
#   --notes <file>  CHANGELOG 段正文（markdown，**不要**写 `## v…` 标题与结尾 `---`，
#                   脚本会补）。同时它会被用作 GitHub Release 的说明。
#   --subject "…"   单行 commit 标题；省略则取正文首个非空行
#   --all-abis      仍构建 3 个 ABI（默认只打 arm64-v8a）
#   --with-screenshots  把 docs/screenshots 下的取证图也提交（默认不入库，本地留档）
#   --no-push       只本地提交，不 push、不打 release
#   --dry-run       只打印计划 + 跑安全扫描，不改任何文件、不碰索引
#
# 默认行为（与旧流程的两处差异，均为用户确认过的取舍）：
#   1. 只打 arm64-v8a —— 用户手机是 arm64；模拟器调试用 debug 包。
#      构建 + 上传体积约为原来的 1/3。
#   2. 功能取证图默认不入库 —— 仓库不再随每个版本膨胀十几 MB。
#      要入库：加 --with-screenshots，或事后 `git add -f <文件>`。
#
# 提交前安全扫描（命中即中止，不提交、不打 tag）：
#   - 路径黑名单：_work/ _backup/ *_backup/ sync_config.json whitelist.json
#     cookie*.txt key.properties *.keystore .env *.log
#   - 内容扫描：真实 Gist ID（从 lib/config.dart 读出来）出现在别处、
#     真实 GitHub token（从本地 sync_config.json 读出来）出现在别处、
#     ghp_/github_pat_/SESSDATA= 形态的明文
#   - 手机号形态只告警不拦（测试夹具里可能有假的）
#
# 旧的全量路径没动：bash app/release.sh（3 ABI + 幂等补资产），手动用。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"      # 仓库根
cd "$ROOT"

OWNER="Tukist"
REPO="bili-whitelist"
GH_REPO="$OWNER/$REPO"
PUBSPEC="app/pubspec.yaml"
CHANGELOG="CHANGELOG.md"

die() { echo "!! $*" >&2; exit 1; }
say() { echo "==> $*"; }

# ---------------- 参数解析 ----------------
VER=""
NOTES=""
SUBJECT=""
ALL_ABIS=0
WITH_SHOTS=0
NO_PUSH=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="${2:-}"; shift 2 ;;
    --subject) SUBJECT="${2:-}"; shift 2 ;;
    --all-abis) ALL_ABIS=1; shift ;;
    --with-screenshots) WITH_SHOTS=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) die "未知参数：$1（-h 看用法）" ;;
    *) [ -z "$VER" ] || die "多余的参数：$1"; VER="$1"; shift ;;
  esac
done

[ -n "$VER" ] || die "缺少版本号。用法：bash app/tools/release_all.sh 2.38.0 --notes <文件>"
echo "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || die "版本号格式应为 X.Y.Z（如 2.38.0），收到：$VER"
[ -n "$NOTES" ] || die "缺少 --notes <正文文件>"
[ -f "$NOTES" ] || die "正文文件不存在：$NOTES"
[ -s "$NOTES" ] || die "正文文件是空的：$NOTES"

# ---------------- 版本自增 ----------------
OLD_LINE="$(grep -E '^version:' "$PUBSPEC" || true)"
[ -n "$OLD_LINE" ] || die "$PUBSPEC 里找不到 version:"
OLD_FULL="$(echo "$OLD_LINE" | sed -E 's/^version:[[:space:]]*([^#[:space:]]+).*/\1/')"
OLD_MAJOR="${OLD_FULL%%+*}"
OLD_CODE="${OLD_FULL##*+}"
case "$OLD_CODE" in ''|*[!0-9]*) die "旧构建号解析失败：$OLD_FULL" ;; esac
NEW_CODE=$((OLD_CODE + 1))
NEW_FULL="$VER+$NEW_CODE"
TAG="v$NEW_FULL"
DATE="$(date +%Y-%m-%d)"

say "版本：$OLD_FULL → $NEW_FULL（tag $TAG）"

# 正文首个非空行 → 默认 commit 标题（去掉 markdown 强调符并截断，避免把长摘要原样塞进标题）
if [ -z "$SUBJECT" ]; then
  SUBJECT="$(grep -m1 -vE '^[[:space:]]*$' "$NOTES" \
    | sed -E 's/^[#>*[:space:]]+//; s/\*+//g' | cut -c1-80)"
fi
MSG="feat: $SUBJECT；v$VER"

# ---------------- 变更概况 ----------------
CHANGED="$(git status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
say "工作区待提交条目：$CHANGED"
if [ "$CHANGED" = "0" ]; then
  echo "    （没有改动可提交；如果你只想重新打 tag，请直接用 app/release.sh）"
fi

# ---------------- 安全扫描 ----------------
# 真实凭据：Gist ID 从 lib/config.dart 读（那里是有意保留的唯一一处），
# token 从本地 sync_config.json 读（gitignored）。
GIST_ID="$(grep -oE '[0-9a-f]{32}' app/lib/config.dart 2>/dev/null | head -1 || true)"
TOKEN="$(grep -oE 'gh[a-z]*_[A-Za-z0-9_]{20,}' sync_config.json 2>/dev/null | head -1 || true)"

DENY_PATH='(^|/)(_work|_backup)/|_backup/|(^|/)sync_config\.json$|(^|/)whitelist\.json$|(^|/)cookie[^/]*\.txt$|(^|/)key\.properties$|\.keystore$|(^|/)\.env|\.log$'

if [ "$DRY" = "1" ]; then
  STAGED_LIST="$(git status --porcelain --untracked-files=all | sed -E 's/^.. //')"
else
  git add -A
  [ "$WITH_SHOTS" = "1" ] || git reset -q -- docs/screenshots 2>/dev/null || true
  STAGED_LIST="$(git diff --cached --name-only)"
fi

say "将提交：$(printf '%s\n' "$STAGED_LIST" | grep -c . ) 个文件"

# 1) 路径黑名单
BAD_PATHS="$(printf '%s\n' "$STAGED_LIST" | grep -Ei "$DENY_PATH" || true)"
if [ -n "$BAD_PATHS" ]; then
  echo "!! 命中禁止入库的路径：" >&2
  printf '    %s\n' $BAD_PATHS >&2
  [ "$DRY" = "1" ] || die "已中止（索引未清空，请自行 git reset 后处理）"
  die "dry-run：请先处理上面这些文件"
fi

# 2) 内容扫描（只扫文本文件）
scan_hits=""
scan_phone=""
if [ "$DRY" = "1" ]; then
  CAND="$(printf '%s\n' "$STAGED_LIST" | grep -vEi '\.(png|jpe?g|gif|webp|apk|aab|jar|zip|ttf|otf|so|aar|bin|keystore)$' || true)"
else
  CAND="$(git diff --cached --numstat | awk '$1!="-" && $2!="-" {print $3}' || true)"
fi

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # 真实 Gist ID / token 出现在 config.dart / sync_config.json 之外 → 拦
  if [ -n "$GIST_ID" ] && [ "$f" != "app/lib/config.dart" ]; then
    if grep -qF "$GIST_ID" "$f" 2>/dev/null; then
      scan_hits="$scan_hits\n  [$f] 含真实 Gist ID"
    fi
  fi
  if [ -n "$TOKEN" ] && [ "$f" != "sync_config.json" ]; then
    if grep -qF "$TOKEN" "$f" 2>/dev/null; then
      scan_hits="$scan_hits\n  [$f] 含真实 GitHub token"
    fi
  fi
  if grep -qE 'gh[a-z]*_[A-Za-z0-9_]{20,}|SESSDATA=[A-Za-z0-9%_.,*-]{20,}|bili_jct=[0-9a-f]{20,}' "$f" 2>/dev/null; then
    scan_hits="$scan_hits\n  [$f] 疑似明文凭据（ghp_ / SESSDATA= / bili_jct=）"
  fi
  if grep -qE '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)' "$f" 2>/dev/null; then
    scan_phone="$scan_phone\n  [$f]"
  fi
done <<< "$CAND"

if [ -n "$scan_phone" ]; then
  echo "⚠️  以下文件含「手机号形态」的数字（可能是测试夹具，请自行确认）：" >&2
  printf "$scan_phone\n" >&2
fi

if [ -n "$scan_hits" ]; then
  echo "!! 内容扫描命中（已中止）：" >&2
  printf "$scan_hits\n" >&2
  die "请先处理这些内容再发布"
fi

say "安全扫描通过"

if [ "$DRY" = "1" ]; then
  echo ""
  echo "---- dry-run 计划 ----"
  echo "  版本：$OLD_FULL → $NEW_FULL"
  echo "  tag ：$TAG"
  echo "  commit subject：$SUBJECT"
  echo "  ABI ：$([ "$ALL_ABIS" = "1" ] && echo '3 个（arm64 + v7a + x86_64）' || echo '仅 arm64-v8a')"
  echo "  取证图：$([ "$WITH_SHOTS" = "1" ] && echo '入库' || echo '不入库（本地留档）')"
  echo "  push/release：$([ "$NO_PUSH" = "1" ] && echo '跳过' || echo '会执行')"
  echo "----------------------"
  exit 0
fi

# ---------------- 写版本号 + CHANGELOG ----------------
sed -i "s/^version:.*/version: $NEW_FULL/" "$PUBSPEC"
say "已写 $PUBSPEC → version: $NEW_FULL"

TMP_SECTION="$(mktemp)"
{
  echo "## v$VER ($DATE)"
  echo ""
  cat "$NOTES"
  echo ""
  echo "---"
  echo ""
} > "$TMP_SECTION"

if grep -qE "^## v$VER([^0-9.]|$)" "$CHANGELOG"; then
  say "CHANGELOG 已有 v$VER 段 → 跳过插入"
else
  awk -v ins="$TMP_SECTION" '
    !done && /^## v/ {
      while ((getline line < ins) > 0) print line
      close(ins)
      done = 1
    }
    { print }
  ' "$CHANGELOG" > "$CHANGELOG.new"
  mv "$CHANGELOG.new" "$CHANGELOG"
  say "已插入 CHANGELOG v$VER 段"
fi

NOTES_FILE="$(mktemp)"
awk -v ver="$VER" '
  /^## / { if (found) exit; if (index($0, "v"ver) > 0) found = 1 }
  found { print }
' "$CHANGELOG" > "$NOTES_FILE"
[ -s "$NOTES_FILE" ] || die "CHANGELOG 段提取为空，别慌：请检查 $PUBSPEC/$CHANGELOG 后手动 git checkout 回滚"

git add -A
[ "$WITH_SHOTS" = "1" ] || git reset -q -- docs/screenshots 2>/dev/null || true

# ---------------- commit + push ----------------
MSG_FILE="$(mktemp)"
printf '%s\n' "$MSG" > "$MSG_FILE"
git commit -q -F "$MSG_FILE" || die "commit 失败"
COMMIT="$(git rev-parse --short HEAD)"
say "已提交：$COMMIT"

if [ "$NO_PUSH" = "1" ]; then
  say "--no-push：跳过 push 与 release"
  exit 0
fi

git push -q origin main
say "已推送 origin/main"

# ---------------- 构建 ----------------
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
export JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"
FLUTTER_BIN="/c/flutter/bin/flutter"
[ -x "$FLUTTER_BIN" ] || FLUTTER_BIN="flutter"

cd app
if [ "$ALL_ABIS" = "1" ]; then
  say "构建 release APK（3 ABI，--split-per-abi）…"
  "$FLUTTER_BIN" build apk --release --split-per-abi
  ABIS="arm64-v8a armeabi-v7a x86_64"
else
  say "构建 release APK（仅 arm64-v8a）…"
  "$FLUTTER_BIN" build apk --release --target-platform android-arm64 --split-per-abi
  ABIS="arm64-v8a"
fi

OUT_DIR="build/app/outputs/flutter-apk"
APKS=()
for abi in $ABIS; do
  SRC="$OUT_DIR/app-$abi-release.apk"
  DST="$OUT_DIR/app-$abi-v$VER-release.apk"
  [ -f "$SRC" ] || die "缺少产物：$SRC"
  cp -f "$SRC" "$DST"
  APKS+=("$DST")
  echo "    -> $(basename "$DST") $(ls -lh "$DST" | awk '{print $5}')"
done

# ---------------- 上传 release ----------------
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  say "Release $TAG 已存在 → 补资产 + 更新说明"
  gh release upload "$TAG" "${APKS[@]}" --repo "$GH_REPO" --clobber
  gh release edit "$TAG" --repo "$GH_REPO" --notes-file "$NOTES_FILE"
else
  say "创建 Release $TAG …"
  gh release create "$TAG" "${APKS[@]}" --repo "$GH_REPO" \
    --title "$TAG" --notes-file "$NOTES_FILE"
fi

# ---------------- 校验 ----------------
say "校验产物"
gh release view "$TAG" --repo "$GH_REPO" \
  --json tagName,isDraft,isPrerelease,url,assets \
  -q '"  tag=\(.tagName)  draft=\(.isDraft)  prerelease=\(.isPrerelease)\n  \(.url)\n" + (.assets[] | "  \(.name)  \(.size) B  \(.state)")'

cd "$ROOT"
echo ""
say "发布完成：$(date '+%Y-%m-%d %H:%M:%S')  commit=$COMMIT  tag=$TAG"
if [ "$WITH_SHOTS" != "1" ]; then
  LEFT="$(git status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
  echo "    取证图未入库（本地留档）；工作区剩余条目：$LEFT"
fi
