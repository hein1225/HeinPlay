chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# 不将 stderr 输出直接视为终止错误，避免 Flutter 输出到 stderr 的提示性信息被误判为构建失败。
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
$distDir = Join-Path $projectDir "dist"

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
    flutter build apk --target lib/main_tv.dart --flavor tv --release
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Error "flutter build apk (tv) 失败 (exit code: $exitCode)"
        exit $exitCode
    }
}
finally {
    Pop-Location
}

$sourceApk = Join-Path $projectDir "build\app\outputs\flutter-apk\app-tv-release.apk"
$destApk = Join-Path $distDir "heinplay-${version}-tv.apk"

if (-not (Test-Path $sourceApk)) {
    Write-Error "未找到构建产物: $sourceApk"
    exit 1
}

Copy-Item -Path $sourceApk -Destination $destApk -Force
Write-Output "已生成: $destApk"
