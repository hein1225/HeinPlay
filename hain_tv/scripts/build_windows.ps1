chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# 不将 stderr 输出直接视为终止错误，避免 Flutter 输出到 stderr 的提示性信息
# （如 Nuget.exe 下载提示）被误判为构建失败。
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
$distDir = Join-Path $projectDir "dist"

# PUB_CACHE 必须指向项目本地缓存（项目约定），fvp 的 mdk-sdk 已预缓存于此。
# 若构建进程未继承该环境变量，CMake 会落到全局缓存去下载坏 URL（GitHub latest 的
# mdk-sdk-windows-x64.7z 已 404），导致配置阶段直接 FATAL_ERROR。这里强制设置以保证命中缓存。
$projectPubCache = Join-Path $projectDir ".pub-cache"
$env:PUB_CACHE = $projectPubCache

# 兜底：若 fvp 的 mdk-sdk 缓存缺失（如 pub-cache 被清或 fvp 升级），自动从正确的 GitHub 发布
# 资产（v0.38.0 的 mdk-sdk-windows-x64-vs2026.7z）下载并解压到对应 fvp 版本目录，避免 fvp 去请求
# 已失效的 latest/download 链接。正常情况缓存已存在，此处不会联网。
$sevenZip = "C:\Program Files\7-Zip\7z.exe"
function Ensure-MdkSdk {
    $lockRaw = Get-Content (Join-Path $projectDir "pubspec.lock") -Raw -ErrorAction SilentlyContinue
    if ($lockRaw -notmatch '(?s)\n  fvp:.*?version: "([^"]+)"') {
        Write-Warning "无法从 pubspec.lock 解析 fvp 版本，跳过 mdk-sdk 兜底检查"
        return
    }
    $fvpVer = $Matches[1]
    $fvpWin = Join-Path $projectPubCache "hosted/pub.dev/fvp-$fvpVer/windows"
    $marker = Join-Path $fvpWin "mdk-sdk/lib/cmake/FindMDK.cmake"
    if (Test-Path $marker) {
        Write-Output "mdk-sdk 缓存已存在 (fvp $fvpVer)，跳过下载"
        return
    }
    $url = "https://github.com/wang-bin/mdk-sdk/releases/download/v0.38.0/mdk-sdk-windows-x64-vs2026.7z"
    $tmp = Join-Path $projectDir ".build_tmp"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp "mdk-sdk.7z"
    Write-Output "mdk-sdk 缓存缺失，预下载 ($url) ..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 180
    }
    catch {
        Write-Warning "mdk-sdk 预下载失败: $_（将回退 fvp 默认下载，可能失败）"
        return
    }
    if (-not (Test-Path $sevenZip)) {
        Write-Warning "未找到 7z.exe ($sevenZip)，无法解压 mdk-sdk"
        return
    }
    $extract = Join-Path $tmp "extract"
    Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
    & $sevenZip x -y $zip -o"$extract" | Out-Null
    $src = Join-Path $extract "mdk-sdk"
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $fvpWin "mdk-sdk") -Recurse -Force
        Write-Output "mdk-sdk 已缓存到 $fvpWin"
    }
    else {
        Write-Warning "解压后未找到 mdk-sdk 目录"
    }
}
Ensure-MdkSdk

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$pubspecPath = Join-Path $projectDir "pubspec.yaml"
$pubspec = Get-Content -Path $pubspecPath -Raw
if ($pubspec -notmatch 'version:\s*([^\s]+)') {
    Write-Error "无法从 pubspec.yaml 读取 version"
    exit 1
}
$versionFull = $Matches[1]
$version = $versionFull.Split('+')[0]

Push-Location $projectDir
try {
    # 预下载 nuget.exe 到 CMake 期望的位置，避免构建时因网络问题下载失败。
    $nugetDir = Join-Path $projectDir "build\windows\x64\_deps\nuget-subbuild\nuget-populate-prefix\src"
    $nugetExe = Join-Path $nugetDir "nuget.exe"
    $nugetUrl = "https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe"
    if (-not (Test-Path $nugetExe)) {
        Write-Output "预下载 nuget.exe 到 $nugetDir ..."
        New-Item -ItemType Directory -Force -Path $nugetDir | Out-Null
        try {
            Invoke-WebRequest -Uri $nugetUrl -OutFile $nugetExe -UseBasicParsing -TimeoutSec 30
            Write-Output "nuget.exe 下载完成"
        }
        catch {
            Write-Warning "nuget.exe 预下载失败: $_，构建时将尝试自动下载"
        }
    }
    else {
        Write-Output "nuget.exe 已存在，跳过下载"
    }

    flutter build windows --target lib/main_windows.dart --release
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Error "flutter build windows 失败 (exit code: $exitCode)"
        exit $exitCode
    }
}
finally {
    Pop-Location
}

$sourceDir = Join-Path $projectDir "build\windows\x64\runner\Release"
$destZip = Join-Path $distDir "heinplay-${version}-windows-portable.zip"

if (-not (Test-Path $sourceDir)) {
    Write-Error "未找到构建产物目录: $sourceDir"
    exit 1
}

# 将手动更新脚本复制到 Windows 产物根目录，随压缩包一起分发。
$manualUpdateDir = Join-Path $projectDir "..\plan\update"
$manualUpdateScripts = @(
    (Join-Path $manualUpdateDir "update_windows_manual.ps1"),
    (Join-Path $manualUpdateDir "update_windows_manual.bat")
)
foreach ($scriptPath in $manualUpdateScripts) {
    if (Test-Path $scriptPath) {
        Copy-Item -Path $scriptPath -Destination $sourceDir -Force
        Write-Output "已复制手动更新脚本: $(Split-Path $scriptPath -Leaf)"
    }
    else {
        Write-Warning "未找到手动更新脚本: $scriptPath"
    }
}

if (Test-Path $destZip) {
    Remove-Item $destZip -Force
}

Compress-Archive -Path "$sourceDir\*" -DestinationPath $destZip -Force
Write-Output "已生成: $destZip"
