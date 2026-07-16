@echo off
chcp 65001 >nul
setlocal

rem HeinPlay 全平台一键构建入口
rem 实际逻辑在 build_all.ps1 中，本批处理仅负责以 Bypass 执行策略调用 PowerShell。

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_all.ps1" %*

if %errorlevel% neq 0 pause

endlocal
