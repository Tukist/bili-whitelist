@echo off
rem ============================================================
rem  Bili Whitelist Server 一键启动
rem  启动后保持窗口打开，日志直接显示在窗口里（Ctrl+C 停止）
rem  先试 conda base 的 python.exe（绝对路径最稳），
rem  不存在则回退到 PATH 里的 python
rem ============================================================
title Bili Whitelist Server
cd /d D:\pythoncode\bili-whitelist

set "PY=D:\anaconda3\python.exe"
if exist "%PY%" (
    "%PY%" whitelist.py serve --port 8124
) else (
    python whitelist.py serve --port 8124
)

echo.
echo 服务已退出，按任意键关闭窗口...
pause >nul
