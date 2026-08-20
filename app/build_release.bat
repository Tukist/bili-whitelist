@echo off
rem ============================================================
rem 白名单点播 App release 构建入口（Windows）
rem 内部调用 Git Bash 脚本 build_release.sh，用法等价于：
rem   bash build_release.sh
rem ============================================================
cd /d %~dp0
"D:\Git\bin\bash.exe" build_release.sh
if errorlevel 1 (
  echo [ERROR] 构建失败，请查看上方输出。
  pause
  exit /b 1
)
pause
