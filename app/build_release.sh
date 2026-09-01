#!/usr/bin/env bash
# ============================================================
# 白名单点播 App —— release 构建脚本（Git Bash 兼容，可重复执行）
#
# 用法：
#   bash build_release.sh                                  # 仅本地构建
#   GH_REPO_TOKEN=<ghp_xxx> bash build_release.sh         # 构建 + 创建 GitHub Release
#
# 功能：
#   - 自动解析 pubspec.yaml 的 version（如 2.14.0+26）
#   - 设置国内镜像 + JDK 环境变量，flutter build apk --release --split-per-abi
#   - 产物复制为带版本号文件名：app-<abi>-v<主版本号>-release.apk
#   - 打印产物清单 + 时间戳；重复执行只覆盖同名文件，无副作用
#   - 若设置了 GH_REPO_TOKEN，则创建 GitHub Release（tag=v主版本号）+ 上传 3 ABI
#     changelog 从 ../CHANGELOG.md 第一个 v主版本号 段提取
# ============================================================
set -euo pipefail

# 脚本所在目录（保证从任意 cwd 调用都正确）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "==> 工作目录: $SCRIPT_DIR"

# ---------- 1. 解析 pubspec.yaml 版本号 ----------
FULL_VER="$(grep -E '^version:' pubspec.yaml \
  | sed -E 's/^version:[[:space:]]*([^#[:space:]]+).*/\1/' \
  | tr -d '[:space:]' || true)"
if [ -z "$FULL_VER" ]; then
  echo "!! 无法从 pubspec.yaml 解析 version，退出" >&2
  exit 1
fi
MAJOR_VER="${FULL_VER%%+*}"   # 2.14.0+26 -> 2.14.0（文件名只用主版本号）
echo "==> 版本: $FULL_VER（产物文件名使用 $MAJOR_VER）"

# ---------- 2. 环境变量：国内镜像 + JDK ----------
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
export JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"

FLUTTER_BIN="/c/flutter/bin/flutter"
if [ ! -x "$FLUTTER_BIN" ]; then
  FLUTTER_BIN="flutter"   # PATH 中已有 flutter 时兜底
fi
echo "==> flutter: $FLUTTER_BIN"

# ---------- 3. 构建 ----------
echo "==> 开始构建 release APK（--split-per-abi）..."
"$FLUTTER_BIN" build apk --release --split-per-abi

# ---------- 4. 产物复制为带版本号文件名 ----------
OUT_DIR="build/app/outputs/flutter-apk"
echo "==> 复制带版本号产物到 $OUT_DIR/"
for abi in arm64-v8a armeabi-v7a x86_64; do
  SRC="$OUT_DIR/app-$abi-release.apk"
  DST="$OUT_DIR/app-$abi-v$MAJOR_VER-release.apk"
  if [ -f "$SRC" ]; then
    cp -f "$SRC" "$DST"
    echo "    -> $DST"
  else
    echo "!! 缺少产物: $SRC" >&2
  fi
done

# ---------- 5. 产物清单 + 时间戳 ----------
echo ""
echo "==> 构建完成：$(date '+%Y-%m-%d %H:%M:%S')"
echo "==> 带版本号产物清单："
ls -lh "$OUT_DIR"/app-*-v"$MAJOR_VER"-release.apk || echo "!! 无产物"
echo "==> 完成：交付件已带版本号 v$MAJOR_VER"

# ---------- 6. （可选）创建 GitHub Release + 上传 APK ----------
# 仅当用户显式设置 GH_REPO_TOKEN（推荐 PAT：repo 权限）时才执行。
# 没设就跳过，APK 留在本地，用户手动拖到 web。
if [ -n "${GH_REPO_TOKEN:-}" ]; then
  echo ""
  echo "==> 第 6 步：创建 GitHub Release（v$MAJOR_VER）..."

  OWNER="Tukist"
  REPO="bili-whitelist"
  TAG="v$MAJOR_VER"

  # 6.1 读 CHANGELOG.md 里 v$MAJOR_VER 那一段（首个 ## v开头 段）
  CHANGELOG_PATH="$(cd .. && pwd)/CHANGELOG.md"
  CHANGELOG=""
  if [ -f "$CHANGELOG_PATH" ]; then
    # awk 段：抓 ## v$MAJOR_VER 行起，到下一个 ## 之前
    CHANGELOG=$(awk -v ver="$MAJOR_VER" '
      /^## / {
        if (found && /^## /) exit
        if (index($0, "v"ver) > 0) { found = 1 }
      }
      found { print }
    ' "$CHANGELOG_PATH")
    if [ -z "$CHANGELOG" ]; then
      echo "!! CHANGELOG 未找到 v$MAJOR_VER 段，使用空 body"
      CHANGELOG="Release v$MAJOR_VER"
    fi
  else
    echo "!! CHANGELOG.md 不存在（$CHANGELOG_PATH），使用空 body"
    CHANGELOG="Release v$MAJOR_VER"
  fi

  # 6.2 构造 JSON payload（jq 优先，python 兜底）
  make_json() {
    local tag="$1" body="$2"
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg t "$tag" --arg b "$body" \
        '{tag_name:$t,name:$t,body:$b,draft:false,prerelease:false}'
    else
      # python3 兜底（Windows Git Bash 自带）
      python -c "
import json, sys
print(json.dumps({'tag_name': sys.argv[1], 'name': sys.argv[1], 'body': sys.argv[2], 'draft': False, 'prerelease': False}, ensure_ascii=False))
" "$tag" "$body"
    fi
  }

  echo "==> 创建 Release $TAG ..."
  REL_JSON=$(curl -fsSL -X POST \
    -H "Authorization: Bearer $GH_REPO_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$(make_json "$TAG" "$CHANGELOG")" \
    "https://api.github.com/repos/$OWNER/$REPO/releases" \
  ) || {
    echo "!! Release 创建失败（HTTP 调用错误），跳过上传" >&2
    REL_JSON=""
  }

  if [ -n "$REL_JSON" ]; then
    REL_ID=$(echo "$REL_JSON" | jq -r '.id // empty' 2>/dev/null \
      || python -c "import json,sys; print(json.loads(sys.stdin.read()).get('id',''))" <<<"$REL_JSON")
    UPLOAD_URL=$(echo "$REL_JSON" | jq -r '.upload_url // empty' 2>/dev/null \
      | sed 's/{?name,label}//' \
      || python -c "import json,sys; print(json.loads(sys.stdin.read()).get('upload_url','').replace('{?name,label}',''))" <<<"$REL_JSON")

    if [ -n "${REL_ID:-}" ] && [ -n "${UPLOAD_URL:-}" ]; then
      echo "==> Release 创建成功（id=$REL_ID），上传 3 ABI APK ..."
      for abi in arm64-v8a armeabi-v7a x86_64; do
        APK="$OUT_DIR/app-$abi-v$MAJOR_VER-release.apk"
        [ -f "$APK" ] || { echo "!! 跳过（不存在）：$APK"; continue; }
        echo "    -> 上传 $(basename $APK) ..."
        curl -fsSL -X POST \
          -H "Authorization: Bearer $GH_REPO_TOKEN" \
          -H "Content-Type: application/vnd.android.package-archive" \
          --data-binary "@$APK" \
          "$UPLOAD_URL?name=$(basename $APK)" \
          && echo "        上传成功" \
          || echo "        !! 上传失败（不影响本地产物）" >&2
      done
      echo "==> Release 链接：https://github.com/$OWNER/$REPO/releases/tag/$TAG"
    else
      echo "!! Release 创建返回异常（缺 id/upload_url）：$REL_JSON" >&2
    fi
  fi
else
  echo ""
  echo "[跳过发布] 未设置 GH_REPO_TOKEN；本地 APK 已就绪。"
  echo "          要自动发版，请设：GH_REPO_TOKEN=<ghp_xxx> bash build_release.sh"
fi
