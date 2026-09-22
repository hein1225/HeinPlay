@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem ================================================================
rem tvLegacy 独立构建入口（目标：Android 5.0 / API 21+）
rem ----------------------------------------------------------------
rem 使用旧版 Flutter 3.32.8：D:\heinplay-legacy\flutter
rem 该路径由 scripts\build_tvlegacy.ps1 以绝对路径调用，无需配置 PATH，
rem 也不会与本机新版 Flutter（D:\flutter / D:\haflutter）混淆。
rem PUB_CACHE 固定在工程目录内，避免复用新版工具的依赖缓存。
rem ================================================================

set "PUB_CACHE=%~dp0.pub-cache"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_tvlegacy.ps1" %*

if %errorlevel% neq 0 pause

endlocal
