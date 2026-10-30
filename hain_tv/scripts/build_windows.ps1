chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# 不将 stderr 输出直接视为终止错误，避免 Flutter 输出到 stderr 的提示性信息
# （如 Nuget.exe 下载提示）被误判为构建失败。
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectDir = Resolve-Path (Join-Path $scriptDir "..")
# 产物统一输出到「仓库根 dist」——所有平台的最终产物（APK / zip / AppImage / HAP）都归在一处。
# 若本工程被单独复制出仓库（父目录无 .git），则回退到工程内 dist，保证脚本仍可独立使用。
$repoRoot = Split-Path -Parent $projectDir
# 🔴 2026-10-22：兼容「仅同步 hain_tv 子树」的远程构建场景。
#    win_build_remote.sh 只把 hain_tv/ 推到 Windows 侧，$repoRoot 下没有 .git，
#    原逻辑会回退到 $projectDir\dist；但我们回收产物的脚本固定取
#    C:\heinplay\dist\*.zip，两边对不上 → 产物明明构建成功却收不回来。
#    故额外认一个显式标记：只要 $repoRoot\dist 目录已存在（由同步脚本预建），
#    就按仓库根 dist 输出。
$forceRepoDist = Test-Path (Join-Path $repoRoot "dist")
if ((Test-Path (Join-Path $repoRoot ".git")) -or $forceRepoDist) {
    $distDir = Join-Path $repoRoot "dist"
} else {
    Write-Warning "未在 $repoRoot 检测到仓库根（无 .git），产物将输出到工程内: $projectDir\dist"
    $distDir = Join-Path $projectDir "dist"
}

# PUB_CACHE 统一指向团队工具目录（唯一存放位置），工程内不再保留缓存副本。
# 🔴 2026-10-22：此前本脚本把 PUB_CACHE 指向工程内 .pub-cache，导致每个工程
#   各自下载一份（约 2.1GB），与 /opt/team/tool-deps/cache/pub-cache 完全重复。
#   现统一到 team 目录，三工程共用同一份缓存。
$teamPubCache = "/opt/team/tool-deps/cache/pub-cache"
if (Test-Path $teamPubCache) {
    $env:PUB_CACHE = $teamPubCache
} else {
    Write-Warning "未找到统一 pub 缓存 $teamPubCache，将使用 Flutter 默认位置"
}

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

# ---------------------------------------------------------------------------
# 打包：只收「程序产物」，绝不收运行期数据。
#
# 背景（2026-09-18 定位）：build\windows\x64\runner\Release\data\ 里除了
# app.so / flutter_assets / icudtl.dat 这些真正的程序产物，还可能残留运行期数据
# （shared_preferences.json、app_logs、cache 等）——只要有人在该 Release 目录里
# 直接跑过一次 hain_tv.exe 就会生成。旧实现用 Compress-Archive 整目录打包，会把这些
# 数据一并塞进分发 zip；分发端解压覆盖时（build_all.ps1 的 Expand-Archive -Force，
# 或用户手动解压）就用构建机的旧数据顶掉了用户自己的 shared_preferences.json，
# 典型症状就是「每次构建完都要重新登录」。这里改为逐文件收集并显式跳过运行期数据。
# ---------------------------------------------------------------------------
$runtimeDataExcludes = @(
    'data\shared_preferences.json',
    'data\prefs_big',
    'data\app_logs',
    'data\cache',
    'data\support',
    'data\temp',
    'data\documents',
    'data\downloads',
    'data\windows_logs',
    'update'
)

if (Test-Path $destZip) {
    Remove-Item $destZip -Force
}

# 两个程序集都必须显式加载（Windows PowerShell 5.1 实测，2026-09-19）：
#   System.IO.Compression.FileSystem → ZipFile / ZipFileExtensions
#   System.IO.Compression            → ZipArchiveMode / CompressionLevel
# 只 Add-Type 前者时，[System.IO.Compression.ZipArchiveMode] 会抛
#   Unable to find type [System.IO.Compression.ZipArchiveMode]
# 导致打包中断、整个 Windows 构建被判定失败（日志只留一行 EXCEPTION）。
# 旧实现用 Compress-Archive（cmdlet，模块内部完成，不做脚本级类型解析）不会踩到，
# 改为逐文件 ZipFile 打包后首次暴露。
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$sourceRoot = (Resolve-Path $sourceDir).Path.TrimEnd('\')
$excludedRel = New-Object System.Collections.Generic.List[string]
# 枚举参数一律用字符串字面量（'Create' / 'Optimal'）：由 PowerShell 参数绑定层
# 按方法签名反射转换，不依赖脚本对 ZipArchiveMode / CompressionLevel 的类型解析，
# 即使上面的程序集加载在某台机器上失效，打包仍能正常完成。
$zipArchive = [System.IO.Compression.ZipFile]::Open($destZip, 'Create')
try {
    foreach ($file in Get-ChildItem -Path $sourceRoot -Recurse -File -Force) {
        $rel = $file.FullName.Substring($sourceRoot.Length + 1)
        $skip = $false
        foreach ($ex in $runtimeDataExcludes) {
            if (($rel -ieq $ex) -or ($rel -ilike "$ex\*")) { $skip = $true; break }
        }
        if ($skip) {
            $excludedRel.Add($rel)
            continue
        }
        $entryName = $rel.Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zipArchive,
            $file.FullName,
            $entryName,
            'Optimal') | Out-Null
    }
}
finally {
    $zipArchive.Dispose()
}

Write-Output "已生成: $destZip"
if ($excludedRel.Count -gt 0) {
    Write-Output "已排除运行期数据 $($excludedRel.Count) 项（不进入分发包）："
    foreach ($e in $excludedRel) { Write-Output "  - $e" }
}
