# =============================================================================
# Remote build driver for the HeinPlay Windows target.
#
# Runs on 192.168.8.10 (HEINCI-SERVER). Prepares the toolchain environment,
# resolves pub dependencies, precaches the Windows engine artifacts and then
# delegates the actual build + packaging to scripts/build_windows.ps1.
#
# 🔴 2026-10-22：所有依赖已迁到 D 盘（容器 C 盘只留 Junction 壳）：
#   Flutter SDK  : D:\src\flutter
#   project      : D:\build\hain_tv
#   VS BuildTools: D:\VSBuildTools（C 盘原路径是 Junction，路径不变可用）
# =============================================================================

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$proj      = 'D:\build\hain_tv'
$flutterBin = 'D:\src\flutter\bin'
$vsBase    = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------- 1. environment ----------
$vsCMake = Join-Path $vsBase 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
$vsNinja = Join-Path $vsBase 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
$env:Path = "$flutterBin;$vsCMake;$vsNinja;$env:Path"

$env:PUB_HOSTED_URL          = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_CACHE              = Join-Path $proj '.pub-cache'

Say "flutter  : $(& (Join-Path $flutterBin 'flutter.bat') --version --no-version-check 2>$null | Select-Object -First 1)"
Say "PUB_HOSTED_URL          = $env:PUB_HOSTED_URL"
Say "FLUTTER_STORAGE_BASE_URL = $env:FLUTTER_STORAGE_BASE_URL"
Say "PUB_CACHE               = $env:PUB_CACHE"

Set-Location $proj

# ---------- 2. pub get ----------
Say "flutter pub get ..."
& (Join-Path $flutterBin 'flutter.bat') pub get
if ($LASTEXITCODE -ne 0) {
    Say "pub get FAILED (exit $LASTEXITCODE) - trying again with the official pub host"
    $env:PUB_HOSTED_URL = 'https://pub.dev'
    & (Join-Path $flutterBin 'flutter.bat') pub get
    if ($LASTEXITCODE -ne 0) { Say "pub get FAILED again - aborting"; exit 1 }
}

# ---------- 3. precache windows engine artifacts ----------
Say "flutter precache --windows ..."
& (Join-Path $flutterBin 'flutter.bat') precache --windows --no-android --no-ios --no-web --no-linux --no-macos
if ($LASTEXITCODE -ne 0) { Say "precache returned $LASTEXITCODE (non-fatal, continuing)" }

# ---------- 4. build + package ----------
Say "running scripts/build_windows.ps1 ..."
& (Join-Path $proj 'scripts\build_windows.ps1')
$buildExit = $LASTEXITCODE
Say "build_windows.ps1 exit code = $buildExit"

# ---------- 5. report ----------
$dist = 'D:\build\dist'
Say "dist contents:"
if (Test-Path $dist) {
    Get-ChildItem $dist -File | ForEach-Object {
        Write-Host ("  {0}   {1} MB   {2}" -f $_.Name, [math]::Round($_.Length / 1MB, 2), $_.LastWriteTime)
    }
} else {
    Write-Host "  (no dist dir)"
}

$rel = Join-Path $proj 'build\windows\x64\runner\Release'
if (Test-Path $rel) {
    Say "release dir contents:"
    Get-ChildItem $rel -File | ForEach-Object {
        Write-Host ("  {0}   {1} MB" -f $_.Name, [math]::Round($_.Length / 1MB, 2))
    }
    $dll = Join-Path $rel 'libmpv-2.dll'
    if (Test-Path $dll) {
        Say ("libmpv-2.dll deployed OK ({0} MB)" -f [math]::Round((Get-Item $dll).Length / 1MB, 1))
    } else {
        Say "*** libmpv-2.dll NOT found in release dir ***"
    }
} else {
    Say "*** release dir missing: $rel ***"
}

Say "=== build stage finished (exit=$buildExit) ==="
exit $buildExit
