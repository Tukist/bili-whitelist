#!/usr/bin/env bash
# ============================================================
# 白名单点播 App —— 一键发布脚本（幂等，可重复执行）
#
# 前置：gh CLI 已登录（Tukist/bili-whitelist，repo 权限）
# 用法：
#   bash release.sh        # 构建 3 ABI + 创建/更新 GitHub Release + 上传 APK
#
# 逻辑：
#   1. 复用 build_release.sh（环境变量 + flutter build apk --release
#      --split-per-abi + 产物改名 app-<abi>-v<主版本>-release.apk）
#   2. 从 pubspec.yaml 读 version（如 2.16.1+31）→ tag=v2.16.1+31
#      （tag 必须带 +构建号：App 的 UpdateInfo 从 tag 的 +数字 解析
#      versionCode 判新旧；缺构建号会退化为发布日期数字导致反复弹更新）
#   3. changelog：从 ../CHANGELOG.md 提取 `## v<主版本>` 段（无则兜底标题）
#   4. gh release 幂等：
#      - tag 不存在 → gh release create（上传 3 ABI APK）
#      - tag 已存在 → gh release upload --clobber 补资产 + gh release edit 更新 notes
#   5. 打印 Release URL
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OWNER="Tukist"
REPO="bili-whitelist"

# ---------- 1. 解析 pubspec.yaml 版本号 ----------
FULL_VER="$(grep -E '^version:' pubspec.yaml \
  | sed -E 's/^version:[[:space:]]*([^#[:space:]]+).*/\1/' \
  | tr -d '[:space:]' || true)"
if [ -z "$FULL_VER" ]; then
  echo "!! 无法从 pubspec.yaml 解析 version，退出" >&2
  exit 1
fi
MAJOR_VER="${FULL_VER%%+*}"   # 2.16.1+31 -> 2.16.1（文件名/CHANGELOG 段用）
TAG="v$FULL_VER"              # v2.16.1+31（App 从 tag 解析 versionCode）
echo "==> 版本: $FULL_VER → tag: $TAG"

# ---------- 2. 构建 3 ABI（复用 build_release.sh；不设 GH_REPO_TOKEN 防重复发布）----------
echo "==> 构建 3 ABI release（bash build_release.sh）..."
bash build_release.sh

# ---------- 3. 收集带版本号产物 ----------
OUT_DIR="build/app/outputs/flutter-apk"
APKS=()
for abi in arm64-v8a armeabi-v7a x86_64; do
  APK="$OUT_DIR/app-$abi-v$MAJOR_VER-release.apk"
  if [ -f "$APK" ]; then
    APKS+=("$APK")
  else
    echo "!! 缺少产物: $APK" >&2
    exit 1
  fi
done
echo "==> 待上传产物："
printf '    %s\n' "${APKS[@]}"

# ---------- 4. changelog：../CHANGELOG.md 的 `## v主版本` 段 ----------
CHANGELOG_PATH="$(cd .. && pwd)/CHANGELOG.md"
NOTES="$(mktemp)"   # notes 走文件（--notes-file 避免 Git Bash → gh.exe 中文参数编码问题）
trap 'rm -f "$NOTES"' EXIT
if [ -f "$CHANGELOG_PATH" ]; then
  # awk 段提取：从 `## v<ver>` 行起，到下一个 `##` 之前
  awk -v ver="$MAJOR_VER" '
    /^## / {
      if (found && /^## /) exit
      if (index($0, "v"ver) > 0) { found = 1 }
    }
    found { print }
  ' "$CHANGELOG_PATH" > "$NOTES" || true
fi
if [ ! -s "$NOTES" ]; then
  echo "Release v$MAJOR_VER" > "$NOTES"
  echo "!! CHANGELOG 未找到 v$MAJOR_VER 段，使用兜底 body" >&2
fi

# ---------- 5. gh release 幂等：tag 不存在 create，存在则补资产+更新 notes ----------
GH_REPO="$OWNER/$REPO"
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  echo "==> Release $TAG 已存在 → 幂等补资产（--clobber）+ 更新 notes..."
  gh release upload "$TAG" "${APKS[@]}" --repo "$GH_REPO" --clobber
  gh release edit "$TAG" --repo "$GH_REPO" --notes-file "$NOTES"
else
  echo "==> 创建 Release $TAG ..."
  gh release create "$TAG" "${APKS[@]}" --repo "$GH_REPO" \
    --title "$TAG" --notes-file "$NOTES"
fi

# ---------- 6. 打印 Release URL ----------
URL="$(gh release view "$TAG" --repo "$GH_REPO" --json url -q '.url')"
echo ""
echo "==> 发布完成：$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> Release URL: $URL"
