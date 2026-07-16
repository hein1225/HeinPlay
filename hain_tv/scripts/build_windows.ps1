chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# 不将 stderr 输出直接视为终止错误，避免 Flutter 输出到 stderr 的提示性信息
# （如 Nuget.exe 下载提示）被误判为构建失败。
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
$distDir = Join-Path $projectDir "dist"

# FVP 默认从 sourceforge nightly 下载 mdk-sdk，国内网络经常失败。
# 改为从 GitHub release 下载，提高 Windows 构建成功率。
$env:FVP_DEPS_URL = "https://github.com/wang-bin/mdk-sdk/releases/latest/download"

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

if (Test-Path $destZip) {
    Remove-Item $destZip -Force
}

Compress-Archive -Path "$sourceDir\*" -DestinationPath $destZip -Force
Write-Output "已生成: $destZip"
