#Requires -Version 5.1
# HeinPlay 全平台构建脚本
# 功能：菜单选择 flutter doctor、依赖检查、Windows 插件检查、Android 签名完整性检查
#       构建 TV / 手机 / Windows / 全部版本，汇总结果、日志路径与产物路径

[CmdletBinding()]
param(
    [switch]$SkipDoctor,
    [switch]$SkipMobile,
    [switch]$SkipTv,
    [switch]$SkipWindows,
    [switch]$Clean
)

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$hainDir = Join-Path $rootDir 'hain_tv'
$androidDir = Join-Path $hainDir 'android'
$androidAppDir = Join-Path $androidDir 'app'
$distDir = Join-Path $hainDir 'dist'
$logsDir = Join-Path $hainDir 'logs'

function Write-Section($title) {
    Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "[OK] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Write-Err($msg) {
    Write-Host "[ERR] $msg" -ForegroundColor Red
}

function Invoke-FlutterDoctor {
    Write-Section 'Flutter Doctor'
    flutter doctor
    $ok = ($LASTEXITCODE -eq 0)
    if ($ok) { Write-Ok 'flutter doctor 未发现异常' }
    else { Write-Warn 'flutter doctor 检测到问题，请查看上方输出' }
    return $ok
}

function Invoke-FlutterPubGet {
    param([switch]$Clean)

    if ($Clean) {
        Write-Section 'Flutter 依赖检查 / flutter clean + pub get'
    }
    else {
        Write-Section 'Flutter 依赖检查 / flutter pub get'
    }

    Push-Location $hainDir
    try {
        if ($Clean) {
            flutter clean
            $cleanOk = ($LASTEXITCODE -eq 0)
            if (-not $cleanOk) { Write-Warn 'flutter clean 返回非零，继续执行 pub get' }
        }

        flutter pub get
        $ok = ($LASTEXITCODE -eq 0)
        if ($ok) { Write-Ok 'flutter pub get 成功' }
        else { Write-Err 'flutter pub get 失败' }
        return $ok
    }
    finally {
        Pop-Location
    }
}

function Test-SevenZip {
    Write-Section 'Windows 7zip 环境检查'
    $sevenZ = Get-Command 7z -ErrorAction SilentlyContinue
    if (-not $sevenZ) {
        $sevenZ = Get-Command 7za -ErrorAction SilentlyContinue
    }
    if ($sevenZ) {
        Write-Ok "已检测到 7zip: $($sevenZ.Source)"
        return $true
    }
    else {
        Write-Warn '未检测到 7zip（7z 或 7za）。Windows 原生依赖使用 .7z 压缩，建议安装 7zip 并添加到 PATH，否则将回退到 CMake tar 解压。'
        Write-Host '下载地址: https://www.7-zip.org/download.html' -ForegroundColor Yellow
        return $false
    }
}

function Test-WindowsPlugin {
    Write-Section 'Windows 插件依赖检查'
    # Windows 播放器已改为 fvp + vlc，不再依赖 shinchiro mpv-dev。
    # 仅检查构建目录是否存在；依赖由插件在构建时自行下载。
    $depsDir = Join-Path $hainDir 'build\windows\x64'
    if (Test-Path $depsDir) {
        Write-Ok "Windows 构建目录已存在: $depsDir"
        return $true
    }
    Write-Warn '未检测到 Windows 构建目录；首次构建 Windows 版时插件会自动下载所需原生依赖，请确保网络稳定。'
    return $false
}

function Repair-WindowsNativeDeps {
    $depsDir = Join-Path $hainDir 'build\windows\x64'

    $expectedHashes = @{
        'ANGLE.7z' = 'E866F13E8D552348058AFAAFE869B1ED'
    }

    if (-not (Test-Path $depsDir)) {
        New-Item -ItemType Directory -Path $depsDir -Force | Out-Null
    }

    # Windows 播放器已改为 fvp + vlc，不再依赖 shinchiro mpv-dev。
    # 清理残留的 mpv 缓存与解压目录，避免旧文件干扰新构建。
    $mpvArchives = Get-ChildItem -Path $depsDir -Filter 'mpv-dev-*.7z' -ErrorAction SilentlyContinue
    foreach ($f in $mpvArchives) {
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
    }
    $targetMpv = Join-Path $depsDir 'shinchiro-mpv-dev-x86_64.7z'
    if (Test-Path $targetMpv) {
        Remove-Item $targetMpv -Force -ErrorAction SilentlyContinue
    }
    $assetMarker = Join-Path $depsDir 'shinchiro-mpv-dev-x86_64.asset.txt'
    if (Test-Path $assetMarker) {
        Remove-Item $assetMarker -Force -ErrorAction SilentlyContinue
    }
    $libmpvSrc = Join-Path $depsDir 'libmpv'
    if (Test-Path $libmpvSrc) {
        Remove-Item $libmpvSrc -Recurse -Force -ErrorAction SilentlyContinue
    }

    $otherArchives = Get-ChildItem -Path $depsDir -Filter '*.7z' -ErrorAction SilentlyContinue
    foreach ($f in $otherArchives) {
        if ($f.Length -lt 1MB) {
            $sizeKB = [math]::Round($f.Length / 1KB, 2)
            Write-Warn "检测到疑似损坏的 Windows 原生依赖: $($f.Name) (${sizeKB} KB)，已删除，构建时将重新下载。"
            Remove-Item $f.FullName -Force
            continue
        }

        $expectedHash = $expectedHashes[$f.Name]
        if ($expectedHash) {
            $actualHash = (Get-FileHash $f.FullName -Algorithm MD5).Hash
            if ($actualHash -ne $expectedHash) {
                $sizeMB = [math]::Round($f.Length / 1MB, 2)
                Write-Warn "检测到 MD5 不匹配的 Windows 原生依赖: $($f.Name) (${sizeMB} MB)`n  实际=$actualHash`n  预期=$expectedHash，已删除，构建时将重新下载。"
                Remove-Item $f.FullName -Force
            }
        }
    }

    $localPlugins = @{
        # Windows 播放器已改为 fvp + vlc；flutter_mpv / media_kit 不再使用。
        'permission_handler_windows' = 'deps\permission_handler_windows'
    }

    $anySymlinkInvalid = $false
    foreach ($pluginName in $localPlugins.Keys) {
        $symlinkDir = Join-Path $hainDir "windows\flutter\ephemeral\.plugin_symlinks\$pluginName"
        $expectedTarget = Resolve-Path (Join-Path $hainDir $localPlugins[$pluginName]) -ErrorAction SilentlyContinue
        $symlinkValid = $false
        if (Test-Path $symlinkDir) {
            try {
                $item = Get-Item $symlinkDir -ErrorAction Stop
                if ($item.Target -and (Test-Path $item.Target)) {
                    $actualTarget = Resolve-Path $item.Target -ErrorAction SilentlyContinue
                    if ($actualTarget -and $expectedTarget -and ($actualTarget.Path -eq $expectedTarget.Path)) {
                        $symlinkValid = $true
                    }
                }
            }
            catch {
                $symlinkValid = $false
            }
        }

        if (-not $symlinkValid) {
            Write-Warn "Windows 插件 $pluginName 的 symlink 未指向本地修正依赖。"
            $anySymlinkInvalid = $true
        }
    }

    if ($anySymlinkInvalid) {
        Write-Warn '清理 ephemeral 缓存并重新执行 flutter pub get...'
        $ephemeralDir = Join-Path $hainDir 'windows\flutter\ephemeral'
        if (Test-Path $ephemeralDir) {
            Remove-Item $ephemeralDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Invoke-FlutterPubGet | Out-Null
    }
}

function Test-AndroidSigning {
    Write-Section 'Android 签名文件完整性检查'
    $allOk = $true

    function Test-OneKey($label, $propFile) {
        $propPath = Join-Path $androidDir $propFile
        if (-not (Test-Path $propPath)) {
            Write-Err "$label 签名配置文件不存在: $propPath"
            return $false
        }

        $storeFile = Get-Content $propPath | Where-Object { $_ -match '^\s*storeFile\s*=\s*(.+?)\s*$' } | ForEach-Object { $matches[1].Trim() }
        if (-not $storeFile) {
            Write-Err "$label 签名配置未找到 storeFile: $propPath"
            return $false
        }

        $storePath = Join-Path $androidAppDir $storeFile
        if (-not (Test-Path $storePath)) {
            Write-Err "$label keystore 文件不存在: $storePath（在 $propFile 中配置为 $storeFile）"
            return $false
        }

        $sizeKB = [math]::Round((Get-Item $storePath).Length / 1KB, 2)
        Write-Ok "$label 签名配置完整: $storeFile (${sizeKB} KB)"
        return $true
    }

    $script:tvKeyOk = Test-OneKey 'TV 版' 'key.properties'
    $script:mobileKeyOk = Test-OneKey '手机版' 'key-mobile.properties'

    if (-not ($tvKeyOk -and $mobileKeyOk)) {
        Write-Warn 'Android 签名文件不完整，将跳过相关 Android 构建。请按 BUILD_GUIDE.md 第 4.1 节配置签名。'
    }
    return ($tvKeyOk -and $mobileKeyOk)
}

function Get-ProjectVersion {
    $pubspecPath = Join-Path $hainDir 'pubspec.yaml'
    $pubspec = Get-Content -Path $pubspecPath -Raw
    if ($pubspec -notmatch 'version:\s*([^\s]+)') {
        throw '无法从 pubspec.yaml 读取 version'
    }
    return $Matches[1].Split('+')[0]
}

function Invoke-BuildScript($name, $scriptPath) {
    Write-Section "$name 构建"
    if (-not (Test-Path $scriptPath)) {
        Write-Err "构建脚本不存在: $scriptPath"
        return @{ Success = $false; LogPath = $null }
    }

    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $safeName = $name -replace '\s+', '_'
    $logPath = Join-Path $logsDir "build_${safeName}_${timestamp}.log"

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    Push-Location $hainDir
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::AppendAllText($logPath, "`n=== $name 构建开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`n", $utf8Bom)

        & $scriptPath 2>&1 | ForEach-Object {
            $line = $_
            Write-Host $line
            [System.IO.File]::AppendAllText($logPath, "$line`n", $utf8Bom)
        }

        $ok = ($LASTEXITCODE -eq 0)
    }
    catch {
        $errLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') EXCEPTION: $_"
        [System.IO.File]::AppendAllText($logPath, "$errLine`n", $utf8Bom)
        Write-Err "$name 构建异常: $_"
        $ok = $false
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $oldEAP
    }

    if ($ok) {
        Write-Ok "$name 构建成功"
    }
    else {
        Write-Err "$name 构建失败，日志: $logPath"
        if (Test-Path $logPath) {
            Write-Host "`n--- 最近 30 行日志 ---" -ForegroundColor Yellow
            Get-Content -Path $logPath -Tail 30 | ForEach-Object { Write-Host $_ }
            Write-Host '--- 日志结束 ---' -ForegroundColor Yellow
        }
    }
    return @{ Success = $ok; LogPath = $logPath }
}

function Invoke-SelectedBuilds {
    param(
        [switch]$SkipDoctor,
        [switch]$SkipMobile,
        [switch]$SkipTv,
        [switch]$SkipWindows,
        [switch]$Clean
    )

    Write-Host "`nHeinPlay 全平台构建脚本" -ForegroundColor Cyan
    Write-Host "项目根目录: $rootDir" -ForegroundColor Cyan
    Write-Host "Flutter 项目目录: $hainDir" -ForegroundColor Cyan
    if ($Clean) { Write-Host '本次构建将执行 flutter clean' -ForegroundColor Yellow }

    if (-not $SkipDoctor) {
        Invoke-FlutterDoctor | Out-Null
    }

    $depsOk = Invoke-FlutterPubGet -Clean:$Clean
    if (-not $depsOk) {
        Write-Err '依赖准备失败，停止构建。'
        return @{ Success = $false; Results = @() }
    }

    if (-not $SkipWindows) {
        Test-WindowsPlugin | Out-Null
    }

    if ((-not $SkipMobile) -or (-not $SkipTv)) {
        Test-AndroidSigning | Out-Null
    }

    $version = Get-ProjectVersion
    Write-Host "`n当前构建版本: $version" -ForegroundColor Cyan

    $results = @()

    if (-not $SkipMobile) {
        if ($mobileKeyOk) {
            Get-Item (Join-Path $distDir 'heinplay-*-mobile.apk') -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Warn "删除旧版手机版产物: $($_.Name)"
                Remove-Item $_.FullName -Force
            }
            $r = Invoke-BuildScript '手机版' (Join-Path $hainDir 'scripts\build_mobile.ps1')
            $results += [PSCustomObject]@{
                Platform     = '手机版'
                Status       = if ($r.Success) { '成功' } else { '失败' }
                ArtifactPath = Join-Path $distDir "heinplay-${version}-mobile.apk"
                LogPath      = $r.LogPath
            }
        }
        else {
            Write-Warn '跳过手机版构建：签名文件不完整'
            $results += [PSCustomObject]@{ Platform = '手机版'; Status = '跳过'; ArtifactPath = 'N/A'; LogPath = 'N/A' }
        }
    }

    if (-not $SkipTv) {
        if ($tvKeyOk) {
            Get-Item (Join-Path $distDir 'heinplay-*-tv.apk') -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Warn "删除旧版 TV 产物: $($_.Name)"
                Remove-Item $_.FullName -Force
            }
            $r = Invoke-BuildScript 'TV 版' (Join-Path $hainDir 'scripts\build_tv.ps1')
            $results += [PSCustomObject]@{
                Platform     = 'TV 版'
                Status       = if ($r.Success) { '成功' } else { '失败' }
                ArtifactPath = Join-Path $distDir "heinplay-${version}-tv.apk"
                LogPath      = $r.LogPath
            }
        }
        else {
            Write-Warn '跳过 TV 版构建：签名文件不完整'
            $results += [PSCustomObject]@{ Platform = 'TV 版'; Status = '跳过'; ArtifactPath = 'N/A'; LogPath = 'N/A' }
        }
    }

    if (-not $SkipWindows) {
        Get-Item (Join-Path $distDir 'heinplay-*-windows-portable.zip') -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Warn "删除旧版 Windows 产物: $($_.Name)"
            Remove-Item $_.FullName -Force
        }
        Test-SevenZip | Out-Null
        Repair-WindowsNativeDeps
        $r = Invoke-BuildScript 'Windows 版' (Join-Path $hainDir 'scripts\build_windows.ps1')
        $artifactZip = Join-Path $distDir "heinplay-${version}-windows-portable.zip"
        $artifactDir = Join-Path $distDir "heinplay-${version}-windows-portable"
        if ($r.Success -and (Test-Path $artifactZip)) {
            if (-not (Test-Path $artifactDir)) {
                New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
            }
            Write-Ok "覆盖解压 Windows 产物到 $artifactDir（保留目录内现有数据）"
            Expand-Archive -Path $artifactZip -DestinationPath $artifactDir -Force
        }
        $results += [PSCustomObject]@{
            Platform     = 'Windows 版'
            Status       = if ($r.Success) { '成功' } else { '失败' }
            ArtifactPath = $artifactZip
            LogPath      = $r.LogPath
        }
    }

    $allSuccess = $true
    if ($results) {
        Write-Section '构建结果汇总'
        $results | Format-Table -AutoSize | Out-String | Write-Host
    }

    $failed = $results | Where-Object { $_.Status -eq '失败' }
    $skipped = $results | Where-Object { $_.Status -eq '跳过' }
    $successCount = ($results | Where-Object { $_.Status -eq '成功' }).Count

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    $distUri = [System.Uri]::new((Resolve-Path $distDir).Path).AbsoluteUri
    Write-Host "产物输出目录: $distUri" -ForegroundColor Cyan

    foreach ($r in $results) {
        if ($r.Status -eq '成功' -and $r.ArtifactPath -ne 'N/A' -and (Test-Path $r.ArtifactPath)) {
            $artifactUri = [System.Uri]::new((Resolve-Path $r.ArtifactPath).Path).AbsoluteUri
            Write-Host "$($r.Platform) 产物: $artifactUri" -ForegroundColor Green
        }
    }

    if ($failed) {
        Write-Err "存在构建失败项（成功: $successCount / 总计: $($results.Count)），请查看上方汇总与日志。"
        $allSuccess = $false
    }
    elseif ($skipped) {
        Write-Warn "存在跳过的构建项（成功: $successCount / 总计: $($results.Count)）。"
        $allSuccess = $false
    }
    else {
        Write-Ok '所有构建均成功。'
    }

    return @{ Success = $allSuccess; Results = $results }
}

function Show-MainMenu {
    Clear-Host
    Write-Host "`nHeinPlay 全平台构建菜单" -ForegroundColor Cyan
    Write-Host '========================' -ForegroundColor Cyan
    Write-Host '1. 构建全部版本'
    Write-Host '2. 仅构建手机版'
    Write-Host '3. 仅构建 TV 版'
    Write-Host '4. 仅构建 Windows 版'
    Write-Host '5. 运行 flutter doctor'
    Write-Host '6. 运行 flutter pub get'
    Write-Host '7. 清理构建缓存 (flutter clean)'
    Write-Host '0. 退出'
    Write-Host ''
    Write-Host '命令行参数示例:' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -SkipWindows          跳过 Windows 构建' -ForegroundColor DarkGray
    Write-Host '  build_all.bat -Clean                构建前执行 flutter clean' -ForegroundColor DarkGray
    Write-Host ''
    return Read-Host '请输入选项编号'
}

function Read-ReturnOrExit {
    $choice = (Read-Host "`n按 Enter 返回主菜单，或输入 q 退出").Trim()
    return ($choice -notmatch '^[Qq]$')
}

function Exit-Script($code = 0) {
    [Environment]::Exit($code)
}

$nonInteractive = $SkipDoctor -or $SkipMobile -or $SkipTv -or $SkipWindows -or $Clean

if ($nonInteractive) {
    $buildResult = Invoke-SelectedBuilds -SkipDoctor:$SkipDoctor -SkipMobile:$SkipMobile -SkipTv:$SkipTv -SkipWindows:$SkipWindows -Clean:$Clean
    if ($buildResult.Success) { Exit-Script 0 } else { Exit-Script 1 }
}

do {
    $choice = Show-MainMenu
    $continueMenu = $true
    switch ($choice) {
        '1' { Invoke-SelectedBuilds | Out-Null }
        '2' { Invoke-SelectedBuilds -SkipDoctor -SkipTv -SkipWindows | Out-Null }
        '3' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipWindows | Out-Null }
        '4' { Invoke-SelectedBuilds -SkipDoctor -SkipMobile -SkipTv | Out-Null }
        '5' { Invoke-FlutterDoctor | Out-Null }
        '6' { Invoke-FlutterPubGet | Out-Null }
        '7' { Invoke-FlutterPubGet -Clean | Out-Null }
        '0' { $continueMenu = $false; Exit-Script 0 }
        default { Write-Warn "无效选项: $choice" }
    }
    if ($choice -ne '0') {
        $continueMenu = Read-ReturnOrExit
    }
} while ($continueMenu)

Exit-Script 0
