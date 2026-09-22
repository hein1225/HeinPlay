@echo off
chcp 65001 >nul
setlocal

cd /d "%~dp0"

rem Convert all PowerShell scripts to UTF-8 BOM before execution.
rem This prevents Chinese characters from being parsed incorrectly in PowerShell 5.1.
set CONVERTER=%~dp0convert_to_bom.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONVERTER%" -Path "%CONVERTER%" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONVERTER%" -Path "%~dp0build_all.ps1" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONVERTER%" -Path "%~dp0hain_tv\scripts" >nul 2>&1

rem tvLegacy is a standalone project at the repo root: hain_tv_legacy\
rem (Flutter 3.32.8 / Dart 3.8.1, Android 5.0+ / API 21, fvp-only).
rem Its build scripts live outside hain_tv\scripts, so convert them separately.
rem (Runs harmlessly even if the folder is absent.)
powershell -NoProfile -ExecutionPolicy Bypass -File "%CONVERTER%" -Path "%~dp0hain_tv_legacy\scripts" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_all.ps1" %*

if %errorlevel% neq 0 pause

endlocal
