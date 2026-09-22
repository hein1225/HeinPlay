#Requires -Version 5.1
# ============================================================================
# tvLegacy 独立构建脚本（目标：Android 5.0 / API 21+）
# ============================================================================
# 工程：hain_tv_legacy\ —— 仓库根下与主工程 hain_tv\ 平级的独立 Flutter 工程，
#       唯一用途是构建 tvLegacy 包（低版本 Android 设备，如 Android 5.0/6.0 电视盒子）。
#
# 为什么必须独立：
#   本工程需要**旧版 Flutter SDK**。最后一个原生支持 API 21 的稳定版是
#   Flutter 3.32.8（Dart 3.8.1，2025-07-25）；自 3.35 起官方把 minSdk 提到 24，
#   引擎 libflutter.so 强引用 getifaddrs@LIBC_N（API 24 才有），
#   在 API 21~23 上 dlopen 即失败。主工程 hain_tv 用的是新版 SDK，
#   因此主工程不再承担 tvLegacy 构建（其 build_all.ps1 / CI / scripts 已移除本项）。
#
# 播放器：本工程为 **fvp-only**（已移除 ExoPlayer/media3 与 VLC 后端）。
#
# 旧版工具集（Flutter 3.32.8）：统一放在 D:\heinplay-legacy\ 下，与本机新版工具
# （D:\flutter、D:\haflutter）严格隔离；本脚本一律用绝对路径调用，不修改 PATH。
#
# 用法：
#   .\scripts\build_tvlegacy.ps1                          # 用默认 SDK D:\heinplay-legacy\flutter
#   .\scripts\build_tvlegacy.ps1 -FlutterSdk D:\xxx\flutter  # 指定其它旧版 SDK
#   .\scripts\build_tvlegacy.ps1 -SkipPubGet              # 跳过 pub get（依赖已就绪时）
# 也可以直接双击工程根目录的 build_tvlegacy.bat。
# ============================================================================
param(
    [string]$FlutterSdk = 'D:\heinplay-legacy\flutter',
    [switch]$SkipPubGet
)

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# 不将 stderr 输出直接视为终止错误，避免 Flutter 输出到 stderr 的提示性信息被误判为构建失败。
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
# 产物统一输出到「仓库根 dist」——本工程与主工程 hain_tv 平级，故工程目录再上一级即仓库根，
# 使 tvLegacy 与其它平台产物（APK / zip / AppImage / HAP）归在一处，发版时一次取齐。
# 若本工程被单独复制出仓库（仓库根无 .git），则回退到工程内 dist，
# 保证本工程仍可脱离仓库独立构建。
# ⚠️ 迁移红线：本工程原位于 hain_tv\tvlegacy（那时须上**两**级才到仓库根），
#    独立到仓库根后只能上**一**级。若误写成上两级，$repoRoot 会落到仓库所在的盘根
#    （如 E:\），因无 .git 而静默回退到工程内 dist → 产物不进仓库根 dist。
$repoRoot = Split-Path -Parent $projectDir
if (Test-Path (Join-Path $repoRoot ".git")) {
    $distDir = Join-Path $repoRoot "dist"
} else {
    Write-Warning "未在 $repoRoot 检测到仓库根（无 .git），产物将输出到工程内: $projectDir\dist"
    $distDir = Join-Path $projectDir "dist"
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# ---------------------------------------------------------------- SDK 检查 ---
$flutterBat = Join-Path $FlutterSdk 'bin\flutter.bat'
if (-not (Test-Path $flutterBat)) {
    Write-Error "找不到 Flutter SDK: $flutterBat`n（tvLegacy 需要 Flutter 3.32.8；默认 D:\heinplay-legacy\flutter，可用 -FlutterSdk 指定）"
    exit 1
}

$sdkVersionFile = Join-Path $FlutterSdk 'version'
if (Test-Path $sdkVersionFile) {
    $sdkVersion = (Get-Content $sdkVersionFile -Raw).Trim()
    Write-Host "Flutter SDK : $FlutterSdk  ($sdkVersion)" -ForegroundColor Cyan
    if ($sdkVersion -notmatch '^3\.32\.') {
        Write-Warning "当前 SDK 版本 $sdkVersion 不属于 3.32.x —— 该线之外的版本可能不再支持 Android 5.0(API 21)，请自行确认。"
    }
}
else {
    Write-Host "Flutter SDK : $FlutterSdk" -ForegroundColor Cyan
}

# ------------------------------------------- local.properties 的 flutter.sdk ---
# Flutter Gradle 插件会读 android/local.properties 里的 flutter.sdk 来定位引擎产物。
# 必须指向本工程使用的旧版 SDK，否则会误用主工程 SDK 的引擎（minSdk 24）而构建失败。
$localProps = Join-Path $projectDir 'android\local.properties'
if (Test-Path $localProps) {
    $content = Get-Content $localProps -Raw
    $expected = 'flutter.sdk=' + ($FlutterSdk -replace '\\', '\\')
    if ($content -notmatch [regex]::Escape($expected)) {
        $content = [regex]::Replace($content, 'flutter\.sdk=.*', $expected)
        [System.IO.File]::WriteAllText($localProps, $content)
        Write-Host "已同步 android/local.properties 的 flutter.sdk -> $expected" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------- 依赖缓存（工程内） ---
# 与主工程一致：PUB_CACHE 固定在工程目录内，避免回退 C 盘默认缓存。
$env:PUB_CACHE = (Join-Path $projectDir '.pub-cache')

# ------------------------------------------------------------ 版本号 / 构建 ---
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
    if (-not $SkipPubGet) {
        Write-Host "`n=== flutter pub get ===" -ForegroundColor Cyan
        & $flutterBat pub get
        if ($LASTEXITCODE -ne 0) {
            Write-Error "flutter pub get 失败 (exit code: $LASTEXITCODE)"
            exit $LASTEXITCODE
        }
    }

    Write-Host "`n=== flutter build apk (tvlegacy, release) ===" -ForegroundColor Cyan
    & $flutterBat build apk --target lib/main_tv.dart --flavor tvlegacy --release
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Error "flutter build apk (tvlegacy) 失败 (exit code: $exitCode)"
        exit $exitCode
    }
}
finally {
    Pop-Location
}

$sourceApk = Join-Path $projectDir "build\app\outputs\flutter-apk\app-tvlegacy-release.apk"
$destApk = Join-Path $distDir "heinplay-${version}-tvLegacy.apk"

if (-not (Test-Path $sourceApk)) {
    Write-Error "未找到构建产物: $sourceApk"
    exit 1
}

Copy-Item -Path $sourceApk -Destination $destApk -Force
Write-Host "`n[OK] 已生成: $destApk" -ForegroundColor Green
Write-Host "     版本: $versionFull" -ForegroundColor Green
