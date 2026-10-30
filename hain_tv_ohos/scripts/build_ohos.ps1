#Requires -Version 5.1
# ============================================================================
# 鸿蒙（HarmonyOS NEXT）独立构建脚本（目标：HAP 安装包）
# ============================================================================
# 工程：hain_tv_ohos\ —— 仓库根下与主工程 hain_tv\ 平级的独立 Flutter 工程，
#       唯一用途是构建鸿蒙 HAP（手机版形态，播放后端 fvp-only）。
#
# 为什么必须独立：
#   鸿蒙需要**专用 Flutter SDK**（OpenHarmony 移植版 flutter_flutter，官方 Flutter
#   不含 ohos 平台支持），且需 DevEco 的 node/ohpm/hvigor 工具链与 HarmonyOS SDK。
#   同时鸿蒙专属依赖（shared_preferences 的 atomgit git 覆盖、fvp 的 ohos 平台）
#   与 Android/桌面基线互相干扰，混在主工程里会拖累两侧依赖解析。
#   故与 tvLegacy 同样处理：独立工程、独立 pubspec、独立工具链。
#
# 与主工程的两个关键差异（迁移时已落地）：
#   1) 鸿蒙工程实体目录**直接命名为 ohos\** —— flutter 工具链硬编码查找
#      <工程>\ohos，因此本工程不再需要主工程那套 mklink junction 绕行。
#   2) 播放后端 fvp-only：exo/vlc 后端与入口已摘除。
#
# 用法：
#   .\scripts\build_ohos.ps1                # 默认 --debug（测试期推荐）
#   .\scripts\build_ohos.ps1 -Release       # 出 release 包
#   .\scripts\build_ohos.ps1 -SkipPubGet    # 跳过 pub get（依赖已就绪时）
# 也可以直接双击工程根目录的 build_ohos.bat。
#
# ⚠️ 必须在 Windows 本机执行（Git Bash 或 PowerShell 均可），
#    绝不能在 WSL/Linux 下跑 —— Linux 无 DevEco 工具链。
# ============================================================================
param(
    [switch]$Release,
    [switch]$SkipPubGet
)

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
# 产物统一输出到「仓库根 dist」——本工程与主工程 hain_tv 平级，故工程目录再上一级即仓库根，
# 使 HAP 与其它平台产物（APK / zip / AppImage）归在一处，发版时一次取齐。
# 若本工程被单独复制出仓库（仓库根无 .git），则回退到工程内 dist，
# 保证本工程仍可脱离仓库独立构建。
$repoRoot = Split-Path -Parent $projectDir
if (Test-Path (Join-Path $repoRoot ".git")) {
    $distDir = Join-Path $repoRoot "dist"
} else {
    Write-Warning "未在 $repoRoot 检测到仓库根（无 .git），产物将输出到工程内: $projectDir\dist"
    $distDir = Join-Path $projectDir "dist"
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# ------------------------------------------------------------ 构建模式 ---
$buildMode = if ($Release) { '--release' } else { '--debug' }

# ------------------------------------------- 委派给 build_ohos.sh（Git Bash）---
# HAP 出包依赖 hijack/ohpm shim + DevEco 环境变量 + MSYS 下的路径处理，
# 这些逻辑已在 scripts/build_ohos.sh 中打通并固化（见该脚本头部注释）。
# 本 PowerShell 脚本只负责：定位 Git Bash、转发参数、把产物复制到仓库根 dist。
$bashExe = $null
$cmdBash = Get-Command bash -ErrorAction SilentlyContinue
if ($cmdBash) { $bashExe = $cmdBash.Source }
if (-not $bashExe) {
    foreach ($p in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe")) {
        if (Test-Path $p) { $bashExe = $p; break }
    }
}
if (-not $bashExe) {
    Write-Error "未找到 Git Bash（bash.exe）。鸿蒙构建需在 Windows Git Bash 中执行 build_ohos.sh。"
    exit 1
}

$shScript = Join-Path $projectDir 'scripts\build_ohos.sh'
if (-not (Test-Path $shScript)) {
    Write-Error "找不到构建脚本: $shScript"
    exit 1
}

# 转 POSIX 路径传给 Git Bash（Windows 反斜杠路径会被 MSYS 转义破坏）
$drive = $shScript.Substring(0, 1).ToLower()
$posixScript = '/' + $drive + $shScript.Substring(2).Replace('\', '/')

Write-Host "Flutter 工具链: 由 build_ohos.sh 内部导出（flutter_flutter ohos 分支）" -ForegroundColor Cyan
Write-Host "构建模式      : $buildMode" -ForegroundColor Cyan

# ------------------------------------------------------- 依赖缓存（工程内） ---
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
    Write-Host "`n=== build_ohos.sh $buildMode ===" -ForegroundColor Cyan
    & $bashExe -c "$posixScript $buildMode"
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Error "鸿蒙构建失败 (exit code: $exitCode)"
        exit $exitCode
    }
}
finally {
    Pop-Location
}

# ------------------------------------------------------------------ 产物 ---
# 交付规则（2026-10-29 起）：
#   · **发布版 APP 包**（.app，已签名）—— 正式发布 / 应用商店上架用；
#   · **未签名 HAP**（.hap，unsigned）—— 供侧载（如 hokit）自行签名后安装；
#   · 已签名的单应用 HAP 不再作为交付物（GitHub 线上构建同样只出 unsigned.hap）。
$sourceHap  = Join-Path $projectDir "ohos\entry\build\default\outputs\default\entry-default-unsigned.hap"
$sourceApp  = Join-Path $projectDir "ohos\build\outputs\default\ohos-default-signed.app"
$destHap    = Join-Path $distDir "heinplay-${version}-ohos-unsigned.hap"
$destApp    = Join-Path $distDir "heinplay-${version}-ohos-release.app"

if (-not (Test-Path $sourceHap)) {
    Write-Error "未找到构建产物: $sourceHap"
    exit 1
}

Copy-Item -Path $sourceHap -Destination $destHap -Force
Write-Host "`n[OK] 已生成: $destHap" -ForegroundColor Green

# release 模式下同时构建了 APP 包；debug 模式没有则跳过（不视为失败）。
if (Test-Path $sourceApp) {
    Copy-Item -Path $sourceApp -Destination $destApp -Force
    Write-Host "[OK] 已生成: $destApp" -ForegroundColor Green
} else {
    Write-Warning "未找到 APP 包产物（仅 release 模式生成）: $sourceApp"
}

Write-Host "     版本: $versionFull" -ForegroundColor Green