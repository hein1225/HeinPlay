#Requires -Version 5.1
# HeinPlay 全平台构建脚本
# 功能：菜单选择 flutter doctor、依赖检查、Windows 插件检查、Android 签名完整性检查
#       构建 TV / 手机 / Windows / 全部版本，汇总结果、日志路径与产物路径

[CmdletBinding()]
param(
    [switch]$SkipDoctor,
    [switch]$SkipMobile,
    [switch]$SkipTv,
    [switch]$SkipWindows
)

# 全局编码设置为 UTF-8，确保中文输出和日志不乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'

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
    Write-Section 'Flutter 依赖检查 / flutter pub get'
    Push-Location $hainDir
    try {
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
    $mpvFiles = Get-ChildItem -Path (Join-Path $hainDir 'build\windows\x64') -Filter 'mpv-dev-*.7z' -ErrorAction SilentlyContinue | Sort-Object Length -Descending
    if ($mpvFiles) {
        $f = $mpvFiles | Select-Object -First 1
        $sizeMB = [math]::Round($f.Length / 1MB, 2)
        if ($f.Length -gt 10MB) {
            Write-Ok "Windows 原生依赖已下载: $($f.Name) (${sizeMB} MB)"
            return $true
        }
        else {
            Write-Warn "Windows 原生依赖文件可能损坏: $($f.FullName) (${sizeMB} MB)，建议删除后重新构建"
            return $false
        }
    }
    else {
        Write-Warn '未检测到 Windows 原生依赖（mpv-dev-*.7z）；首次构建 Windows 版时会自动下载，请确保网络稳定。'
        return $false
    }
}

function Repair-WindowsNativeDeps {
    # 清理可能损坏或版本错误的 Windows 原生依赖缓存
    $depsDir = Join-Path $hainDir 'build\windows\x64'

    # flutter_mpv_libs_windows_video 依赖包的已知正确 MD5（与本地修正后的 CMakeLists.txt 一致）
    $expectedHashes = @{
        'ANGLE.7z'                                = 'E866F13E8D552348058AFAAFE869B1ED'
        'mpv-dev-x86_64-20241021-git-0f78584.7z'  = '6ECF18E85B093C3F7EDB16F3EE6603F3'
        'mpv-dev-aarch64-20241021-git-0f78584.7z' = '5B507A35DB13EEE6CB7EB21E8BE7C83D'
    }

    if (Test-Path $depsDir) {
        # 删除任何非当前期望版本的 mpv-dev 压缩包，避免旧版 shinchiro 等构建残留
        $mpvArchives = Get-ChildItem -Path $depsDir -Filter 'mpv-dev-*.7z' -ErrorAction SilentlyContinue
        foreach ($f in $mpvArchives) {
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
            else {
                $sizeMB = [math]::Round($f.Length / 1MB, 2)
                Write-Warn "检测到非预期版本的 Windows mpv-dev 依赖: $($f.Name) (${sizeMB} MB)，已删除，构建时将重新下载当前匹配版本。"
                Remove-Item $f.FullName -Force
            }
        }

        # 同时清理 ANGLE 等其他 .7z 的损坏/不匹配缓存
        $otherArchives = Get-ChildItem -Path $depsDir -Filter '*.7z' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'mpv-dev-*.7z' }
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

        # 删除已解压的旧版 libmpv 目录，强制 CMake 使用新下载的压缩包重新解压
        $libmpvSrc = Join-Path $depsDir 'libmpv'
        if (Test-Path $libmpvSrc) {
            Write-Warn "清理已解压的 libmpv 目录，确保使用新版 mpv-dev 重新解压..."
            Remove-Item $libmpvSrc -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 确保 Windows 插件 symlink 指向本地修正后的依赖包
    $localPlugins = @{
        'flutter_mpv_libs_windows_video' = 'deps\flutter_mpv_libs_windows_video'
        'flutter_mpv_video'              = 'deps\flutter_mpv_video'
        'permission_handler_windows'     = 'deps\permission_handler_windows'
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

        # build.gradle.kts 中 file(it) 以 android/app 为基准解析相对路径
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
        throw "无法从 pubspec.yaml 读取 version"
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

    # 统一控制台与 PowerShell 输出编码为 UTF-8，避免子进程中文输出被解码为 GBK 导致日志乱码
    $oldOutputEncoding = [Console]::OutputEncoding
    $oldInputEncoding = [Console]::InputEncoding
    $oldOutputEncodingVar = $OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    Push-Location $hainDir
    try {
        # 以 UTF-8（带 BOM）写入日志，避免 Windows 记事本/默认编辑器打开时中文乱码
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        # 首次写入若文件不存在，AppendAllText 会自动写入 BOM
        [System.IO.File]::AppendAllText($logPath, "`n=== $name 构建开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`n", $utf8Bom)

        # 实时显示输出并逐行追加到日志，避免内容截断
        & $scriptPath 2>&1 | ForEach-Object {
            $line = $_
            Write-Host $line
            [System.IO.File]::AppendAllText($logPath, "$line`n", $utf8Bom)
        }

        # PowerShell 管道会保留子进程（子脚本 exit N）的 $LASTEXITCODE
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
        [Console]::OutputEncoding = $oldOutputEncoding
        [Console]::InputEncoding = $oldInputEncoding
        $OutputEncoding = $oldOutputEncodingVar
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
        [switch]$SkipWindows
    )

    Write-Host "`nHeinPlay 全平台构建脚本" -ForegroundColor Cyan
    Write-Host "项目根目录: $rootDir" -ForegroundColor Cyan
    Write-Host "Flutter 项目目录: $hainDir" -ForegroundColor Cyan

    # 1. flutter doctor
    if (-not $SkipDoctor) {
        Invoke-FlutterDoctor | Out-Null
    }

    # 2. flutter pub get
    $depsOk = Invoke-FlutterPubGet
    if (-not $depsOk) {
        Write-Err '依赖准备失败，停止构建。'
        return @{ Success = $false; Results = @() }
    }

    # 3. Windows 插件检查（仅提示，不阻断）
    if (-not $SkipWindows) {
        Test-WindowsPlugin | Out-Null
    }

    # 4. Android 签名检查
    if ((-not $SkipMobile) -or (-not $SkipTv)) {
        Test-AndroidSigning | Out-Null
    }

    # 5. 读取版本号
    $version = Get-ProjectVersion
    Write-Host "`n当前构建版本: $version" -ForegroundColor Cyan

    # 6. 依次构建
    $results = @()

    if (-not $SkipMobile) {
        if ($mobileKeyOk) {
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
        Test-SevenZip | Out-Null
        Repair-WindowsNativeDeps
        $r = Invoke-BuildScript 'Windows 版' (Join-Path $hainDir 'scripts\build_windows.ps1')
        $results += [PSCustomObject]@{
            Platform     = 'Windows 版'
            Status       = if ($r.Success) { '成功' } else { '失败' }
            ArtifactPath = Join-Path $distDir "heinplay-${version}-windows-portable.zip"
            LogPath      = $r.LogPath
        }
    }

    # 7. 汇总
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

    # 输出每个成功产物的可点击链接，便于直接打开 apk/zip/exe
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
    Write-Host '0. 退出'
    Write-Host ''
    return Read-Host '请输入选项编号'
}

function Read-ReturnOrExit {
    $choice = (Read-Host "`n按 Enter 返回主菜单，或输入 q 退出").Trim()
    return ($choice -notmatch '^[Qq]$')
}

function Exit-Script($code = 0) {
    # 构建子进程（flutter/gradle/dart 等）可能仍在后台运行句柄；
    # 正常 exit 会等待它们并导致窗口卡住，因此强制结束当前 PowerShell 进程。
    [Environment]::Exit($code)
}

# ==================== 主流程 ====================

# 如果通过参数调用（如 -SkipWindows），保持原有非交互式行为
$nonInteractive = $SkipDoctor -or $SkipMobile -or $SkipTv -or $SkipWindows

if ($nonInteractive) {
    $buildResult = Invoke-SelectedBuilds -SkipDoctor:$SkipDoctor -SkipMobile:$SkipMobile -SkipTv:$SkipTv -SkipWindows:$SkipWindows
    if ($buildResult.Success) { Exit-Script 0 } else { Exit-Script 1 }
}

# 交互式菜单模式
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
        '0' { $continueMenu = $false; Exit-Script 0 }
        default { Write-Warn "无效选项: $choice" }
    }
    if ($choice -ne '0') {
        $continueMenu = Read-ReturnOrExit
    }
} while ($continueMenu)

Exit-Script 0
