# 构建 Android TV APK
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = [System.IO.Path]::GetFullPath("$scriptDir\..")
Push-Location $projectDir

try {
    # 当 Pub Cache 与项目不在同一磁盘时，Kotlin 增量编译会报错。
    # 若检测到这种情况，将 Pub Cache 复制到项目所在磁盘。
    $pubCacheRoot = $env:PUB_CACHE
    if (-not $pubCacheRoot) {
        $pubCacheRoot = "$env:LOCALAPPDATA\Pub\Cache"
    }
    $pubCachePath = Resolve-Path $pubCacheRoot -ErrorAction SilentlyContinue

    if ($pubCachePath -and ($projectDir[0] -ne $pubCachePath.Path[0])) {
        $localPubCache = [System.IO.Path]::GetFullPath("$projectDir\.pub-cache")
        if (-not (Test-Path $localPubCache)) {
            Write-Host "Pub Cache 与项目不在同一磁盘，复制到 $localPubCache ..." -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $localPubCache -Force | Out-Null
            Copy-Item -Path "$pubCacheRoot\*" -Destination $localPubCache -Recurse -Force -ErrorAction SilentlyContinue
        }
        $env:PUB_CACHE = $localPubCache
        Write-Host "已设置 PUB_CACHE=$localPubCache" -ForegroundColor Green
    }

    # 默认构建 release APK；如需 appbundle，可改为 flutter build appbundle
    flutter build apk --release
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Android TV APK 构建失败"
        exit 1
    }

    Write-Host "Android TV APK 构建完成，输出路径：build/app/outputs/flutter-apk/app-release.apk" -ForegroundColor Green
} finally {
    Pop-Location
}
