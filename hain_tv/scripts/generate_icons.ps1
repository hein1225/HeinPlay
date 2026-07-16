﻿# 生成全平台图标与启动图
# 需要先确保网络可用，以便 flutter pub get 能拉取 flutter_launcher_icons
Set-Location -Path "$PSScriptRoot\.."

flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Error "flutter pub get 失败，无法继续生成图标"
    exit 1
}

# 生成 TV / Web / Windows / macOS 默认图标
flutter pub run flutter_launcher_icons:main
if ($LASTEXITCODE -ne 0) {
    Write-Error "默认图标生成失败"
    exit 1
}

# 生成手机版 Flavor 图标（使用 plan/mo_ico.png）
flutter pub run flutter_launcher_icons:main -f flutter_launcher_icons-mobile.yaml
if ($LASTEXITCODE -ne 0) {
    Write-Error "手机版图标生成失败"
    exit 1
}

Write-Host "图标生成完成" -ForegroundColor Green
