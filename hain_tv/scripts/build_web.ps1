﻿﻿﻿# 构建 Web 版本（用于本地测试）
Set-Location -Path "$PSScriptRoot\.."

flutter build web --release
if ($LASTEXITCODE -ne 0) {
    Write-Error "Web 构建失败"
    exit 1
}

Write-Host "Web 构建完成，输出目录：build/web" -ForegroundColor Green
