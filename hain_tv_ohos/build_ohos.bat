@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem 鸿蒙（HarmonyOS NEXT）独立构建入口。
rem 工程位于仓库根 hain_tv_ohos\，与主工程 hain_tv\ 平级。
rem 必须在本机 Windows 上执行（需 DevEco 工具链），不能在 WSL/Linux 下跑。
rem 实际构建逻辑在 scripts\build_ohos.sh（经 Git Bash），本 bat 仅作双击入口。

set CONVERTER=%~dp0..\convert_to_bom.ps1
if exist "%CONVERTER%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%CONVERTER%" -Path "%~dp0scripts\build_ohos.ps1" >nul 2>&1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_ohos.ps1" %*

if %errorlevel% neq 0 pause
endlocal