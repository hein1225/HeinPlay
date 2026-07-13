$ErrorActionPreference = "Stop"

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
    flutter build apk --target lib/main_mobile.dart --flavor mobile --release
    if ($LASTEXITCODE -ne 0) {
        Write-Error "flutter build apk (mobile) 失败"
        exit 1
    }
} finally {
    Pop-Location
}

$sourceApk = Join-Path $projectDir "build\app\outputs\flutter-apk\app-mobile-release.apk"
$destApk = Join-Path $distDir "heinplay-${version}-mobile.apk"

if (-not (Test-Path $sourceApk)) {
    Write-Error "未找到构建产物: $sourceApk"
    exit 1
}

Copy-Item -Path $sourceApk -Destination $destApk -Force
Write-Output "已生成: $destApk"
