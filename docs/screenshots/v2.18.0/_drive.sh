#!/usr/bin/env bash
# 模拟器取证辅助脚本（tester 一次性工具，不属于 App 代码）
export MSYS_NO_PATHCONV=1
ADB="C:/Users/HP/AppData/Local/Android/Sdk/platform-tools/adb"
PKG="com.biliwhitelist.bili_whitelist_app"

case "$1" in
  shot)   # shot <本地文件>
    "$ADB" exec-out screencap -p > "$2" ;;
  rec)    # rec <设备文件名> <秒数> [尺寸]
    # 1080x2400 编码器不支持（err=-38），720x1600 与屏幕同比例（0.45）
    "$ADB" shell screenrecord --time-limit "$3" --size "${4:-720x1600}" \
      --bit-rate 6000000 "/sdcard/$2" ;;
  pull)   # pull <设备文件名> <本地文件>
    "$ADB" pull "/sdcard/$2" "$3" ;;
  tap)    "$ADB" shell input tap "$2" "$3" ;;
  swipe)  "$ADB" shell input swipe "$2" "$3" "$4" "$5" "${6:-300}" ;;
  key)    "$ADB" shell input keyevent "$2" ;;
  start)  "$ADB" shell am start -n "$PKG/.MainActivity" ;;
  stop)   "$ADB" shell am force-stop "$PKG" ;;
  *) echo "usage: shot|rec|pull|tap|swipe|key|start|stop" ;;
esac
