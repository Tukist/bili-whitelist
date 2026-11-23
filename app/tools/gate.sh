#!/usr/bin/env bash
# ============================================================
# amoTV —— 本地门禁（gate）
#
# 为什么有它：每次改完代码都手动敲 analyze + 一堆测试 + 构建，
# 命令长、容易漏、失败后还得自己找是哪一批挂的。这里把三步固定下来：
#
#   1. flutter analyze            （静态检查，一条错误即失败）
#   2. flutter test <分批>        （每批 <=45 个 *_test.dart，自动跳过辅助文件）
#   3. flutter build apk --debug  （确认能打包；--no-build 可跳过）
#
# 用法：
#   bash app/tools/gate.sh                      # 全量门禁（发版前跑）
#   bash app/tools/gate.sh --quick              # 只跑 analyze（开发中随手自查）
#   bash app/tools/gate.sh --quick test/foo_test.dart test/bar_test.dart
#   bash app/tools/gate.sh --quick foo          # 简写：在 test/ 下找 *foo*_test.dart
#   bash app/tools/gate.sh --no-build           # 全量测试但不构建 APK
#
# 退出码：0 = 全部通过（最后一行 GATE OK），非 0 = 某一步失败。
#
# 说明：
#   - 纯 POSIX bash（Git Bash 可跑），不依赖 GNU 专有选项。
#   - 临时文件放 mktemp -d，退出时 trap 清理，不在仓库留垃圾。
#   - 永远不要用 `flutter test -d <设备>`：那会重装 App、清掉登录态与本地偏好。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"     # 仓库根
APP="$ROOT/app"
BATCH_SIZE=45

MODE="full"
DO_BUILD=1
QUICK_TARGETS=()

usage() {
  sed -n '8,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)
      MODE="quick"
      shift
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "!! 未知选项：$1（--help 查看用法）" >&2
      exit 2
      ;;
    *)
      QUICK_TARGETS+=("$1")
      shift
      ;;
  esac
done

TMPDIR_GATE="$(mktemp -d "${TMPDIR:-/tmp}/amotv-gate.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_GATE"; }
trap cleanup EXIT INT TERM

TOTAL_PASSED=0
TOTAL_FAILED=0
FAIL_STEP=""

say()  { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }

# 打印失败摘要：步骤名 + 日志尾部。$1=步骤描述 $2=日志文件
dump_failure() {
  local label="$1"
  local log="$2"
  echo ""
  echo "------------------------------------------------------------"
  echo "!! 失败步骤：$label"
  echo "------------------------------------------------------------"
  # 只挑有用的行：出错标记、异常、断言差异
  grep -nE "\[E\]|Some tests failed|FAILED|error •|Compilation failed|Exception|Expected:|Actual:" "$log" \
    | head -40 || true
  echo "---- 日志末尾 30 行 ----"
  tail -30 "$log" || true
  echo "------------------------------------------------------------"
}

# 从 flutter test 输出里取「通过的用例数」：形如 "00:12 +123 ~2 -0: All tests passed!"
extract_passed() {
  sed -n 's/.*+\([0-9][0-9]*\).*/\1/p' "$1" | tail -1
}

run_analyze() {
  local log="$TMPDIR_GATE/analyze.log"
  say "步骤 1/3：flutter analyze"
  local start
  start=$(date +%s)
  ( cd "$APP" && flutter analyze ) >"$log" 2>&1
  local rc=$?
  local spent=$(( $(date +%s) - start ))
  if [ $rc -ne 0 ]; then
    dump_failure "flutter analyze" "$log"
    FAIL_STEP="analyze"
    return 1
  fi
  echo "    analyze 通过（${spent}s）"
  return 0
}

run_quick_tests() {
  local log="$TMPDIR_GATE/quick.log"
  say "步骤 2/3：定向测试（${#QUICK_TARGETS[@]} 个目标）"
  ( cd "$APP" && flutter test "${QUICK_TARGETS[@]}" ) >"$log" 2>&1
  local rc=$?
  local passed
  passed=$(extract_passed "$log")
  [ -n "$passed" ] || passed=0
  if [ $rc -ne 0 ]; then
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    dump_failure "flutter test ${QUICK_TARGETS[*]}" "$log"
    FAIL_STEP="quick test"
    return 1
  fi
  TOTAL_PASSED=$((TOTAL_PASSED + passed))
  echo "    通过 $passed 个用例"
  return 0
}

run_full_tests() {
  local list="$TMPDIR_GATE/test_files.txt"
  local i=0

  : >"$list"
  for f in "$APP"/test/*_test.dart; do
    [ -f "$f" ] || continue
    # 跳过没有 main() 的辅助文件（如 live_danmaku_fakes.dart）
    if ! grep -q "void main(" "$f"; then
      warn "跳过无 main() 的辅助文件：$(basename "$f")"
      continue
    fi
    echo "$f" >>"$list"
  done

  local total_files
  total_files=$(wc -l <"$list" | tr -d ' ')
  local total_batches=$(( (total_files + BATCH_SIZE - 1) / BATCH_SIZE ))
  say "步骤 2/3：全量测试（$total_files 个文件，分 $total_batches 批，每批 ≤ $BATCH_SIZE）"

  local offset=0
  local batch=0
  while [ "$offset" -lt "$total_files" ]; do
    batch=$((batch + 1))
    local log="$TMPDIR_GATE/batch-$batch.log"
    # 取 [offset+1 .. offset+BATCH_SIZE] 行
    local end=$((offset + BATCH_SIZE))
    local files=()
    local n=0
    while IFS= read -r line; do
      n=$((n + 1))
      if [ "$n" -gt "$offset" ] && [ "$n" -le "$end" ]; then
        files+=("$line")
      fi
    done <"$list"

    local start
    start=$(date +%s)
    ( cd "$APP" && flutter test "${files[@]}" ) >"$log" 2>&1
    local rc=$?
    local spent=$(( $(date +%s) - start ))
    local passed
    passed=$(extract_passed "$log")
    [ -n "$passed" ] || passed=0

    if [ $rc -ne 0 ]; then
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      echo "    第 $batch/$total_batches 批：失败（${spent}s）" >&2
      dump_failure "全量测试 第 $batch/$total_batches 批（${files[0]} 等）" "$log"
      FAIL_STEP="test batch $batch"
      return 1
    fi

    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    echo "    第 $batch/$total_batches 批：通过 $passed 个用例（${spent}s）"
    offset=$end
  done

  echo "    全量测试合计通过 $TOTAL_PASSED 个用例"
  return 0
}

run_build() {
  local log="$TMPDIR_GATE/build.log"
  say "步骤 3/3：flutter build apk --debug"
  local start
  start=$(date +%s)
  ( cd "$APP" && flutter build apk --debug ) >"$log" 2>&1
  local rc=$?
  local spent=$(( $(date +%s) - start ))
  if [ $rc -ne 0 ]; then
    dump_failure "flutter build apk --debug" "$log"
    FAIL_STEP="build"
    return 1
  fi
  echo "    构建通过（${spent}s）"
  return 0
}

echo "============================================================"
echo " amoTV 本地门禁（gate）  模式：$MODE"
echo " 仓库：$ROOT"
echo "============================================================"

run_analyze || { echo "GATE FAILED"; exit 1; }

if [ "$MODE" = "quick" ]; then
  if [ ${#QUICK_TARGETS[@]} -gt 0 ]; then
    # 简化写法：不是已有路径时，去 test/ 下按 *<关键字>*_test.dart 找
    resolved=()
    for t in "${QUICK_TARGETS[@]}"; do
      if [ -f "$APP/$t" ]; then
        resolved+=("$t")
      elif [ -f "$APP/test/$t" ]; then
        resolved+=("test/$t")
      else
        found=0
        for f in "$APP"/test/*"$t"*_test.dart; do
          [ -f "$f" ] || continue
          resolved+=("test/$(basename "$f")")
          found=1
        done
        if [ $found -eq 0 ]; then
          warn "找不到测试文件：$t"
          FAIL_STEP="quick target"
          echo "GATE FAILED"
          exit 1
        fi
      fi
    done
    QUICK_TARGETS=("${resolved[@]}")
    run_quick_tests || { echo "GATE FAILED"; exit 1; }
  else
    echo "==> 步骤 2/3：跳过测试（--quick 未指定测试文件，只做 analyze）"
  fi
else
  run_full_tests || { echo "GATE FAILED"; exit 1; }
  if [ $DO_BUILD -eq 1 ]; then
    run_build || { echo "GATE FAILED"; exit 1; }
  else
    echo "==> 步骤 3/3：跳过 APK 构建（--no-build）"
  fi
fi

echo "============================================================"
if [ "$MODE" = "full" ]; then
  echo " 通过用例总计：$TOTAL_PASSED（失败批次：$TOTAL_FAILED）"
else
  echo " 通过用例总计：$TOTAL_PASSED"
fi
echo "GATE OK"
echo "============================================================"
exit 0
