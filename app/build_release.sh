#!/usr/bin/env bash
# ============================================================
# 白名单点播 App —— release 构建脚本（Git Bash 兼容，可重复执行）
#
# 用法：
#   bash build_release.sh          # 命令行直接跑
#   或双击 build_release.bat       # Windows 入口（内部调用本脚本）
#
# 功能：
#   - 自动解析 pubspec.yaml 的 version（如 2.0.0+1）
#   - 设置国内镜像 + JDK 环境变量，flutter build apk --release --split-per-abi
#   - 产物复制为带版本号文件名：app-<abi>-v<主版本号>-release.apk
#   - 打印产物清单 + 时间戳；重复执行只覆盖同名文件，无副作用
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
MAJOR_VER="${FULL_VER%%+*}"   # 2.0.0+1 -> 2.0.0（文件名只用主版本号）
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
ls -lh "$OUT_DIR"/app-*-v"$MAJOR_VER"-release.apk
echo "==> 完成：交付件已带版本号 v$MAJOR_VER"
