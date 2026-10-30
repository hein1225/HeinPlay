# =============================================================================
# Install Flutter SDK 3.47.5 (stable) on the Windows build host.
#
# Downloaded from the Tencent mirror (domestic, fast). Falls back to the
# flutter-io.cn mirror and then to the official GCS bucket.
#
# Also configures the domestic pub / artifact mirrors and enables the
# Windows desktop target.
# =============================================================================

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$flutterVer   = '3.47.5'
$installRoot  = 'C:\src'
$flutterDir   = Join-Path $installRoot 'flutter'
$workDir      = 'C:\heinplay'
$zipPath      = Join-Path $workDir "flutter_windows_${flutterVer}-stable.zip"

$mirrors = @(
    "https://mirrors.cloud.tencent.com/flutter/flutter_infra_release/releases/stable/windows/flutter_windows_${flutterVer}-stable.zip",
    "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_${flutterVer}-stable.zip",
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_${flutterVer}-stable.zip"
)

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------- 0. already installed? ----------
if (Test-Path (Join-Path $flutterDir 'bin\flutter.bat')) {
    Say "flutter already installed at $flutterDir - skipping download"
    $existing = & (Join-Path $flutterDir 'bin\flutter.bat') --version --no-version-check 2>$null
    Say ("existing version: " + ($existing | Select-Object -First 1))
} else {

    # ---------- 1. download ----------
    $needDownload = $true
    if (Test-Path $zipPath) {
        $sz = (Get-Item $zipPath).Length
        Say ("existing zip found, {0} MB" -f [math]::Round($sz / 1MB, 1))
        if ($sz -lt 200MB) { Remove-Item $zipPath -Force; Say "existing zip is truncated, re-downloading" }
        else { $needDownload = $false }
    }

    if ($needDownload) {
        $ok = $false
        foreach ($m in $mirrors) {
            Say "downloading from $m"
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & curl.exe -L --fail --retry 3 --retry-delay 5 --connect-timeout 30 `
                       -o $zipPath $m
            $rc = $LASTEXITCODE
            $sw.Stop()
            if ($rc -eq 0 -and (Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 200MB) {
                Say ("download OK  {0} MB in {1}s" -f [math]::Round((Get-Item $zipPath).Length / 1MB, 1), [math]::Round($sw.Elapsed.TotalSeconds, 1))
                $ok = $true
                break
            } else {
                Say "download failed (curl rc=$rc), trying next mirror"
                if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $ok) { Say "ALL MIRRORS FAILED"; exit 2 }
    }

    # ---------- 2. extract ----------
    Say "extracting to $installRoot ..."
    if (-not (Test-Path $installRoot)) { New-Item -ItemType Directory -Force -Path $installRoot | Out-Null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $extractOk = $false
    if (Test-Path $flutterDir) { Remove-Item -Recurse -Force $flutterDir -ErrorAction SilentlyContinue }

    # tar.exe (bsdtar, built into Windows 10+) is far faster than Expand-Archive
    & tar.exe -xf $zipPath -C $installRoot 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $flutterDir 'bin\flutter.bat'))) {
        $extractOk = $true
        Say "extracted via tar.exe"
    } else {
        Say "tar.exe extraction failed, falling back to Expand-Archive (slow)"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $installRoot)
        $extractOk = Test-Path (Join-Path $flutterDir 'bin\flutter.bat')
    }
    $sw.Stop()
    Say ("extract finished in {0}s ok={1}" -f [math]::Round($sw.Elapsed.TotalSeconds, 1), $extractOk)
    if (-not $extractOk) { Say "EXTRACTION FAILED"; exit 3 }
}

# ---------- 3. environment variables (user scope) ----------
Say "configuring environment variables"
$flutterBin = Join-Path $flutterDir 'bin'

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if ($userPath -notlike "*$flutterBin*") {
    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $flutterBin } else { "$flutterBin;$userPath" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Say "user PATH updated"
} else {
    Say "user PATH already contains flutter"
}

[Environment]::SetEnvironmentVariable('PUB_HOSTED_URL', 'https://pub.flutter-io.cn', 'User')
[Environment]::SetEnvironmentVariable('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn', 'User')
Say "PUB_HOSTED_URL=https://pub.flutter-io.cn"
Say "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

# make them effective for this process too
$env:Path = "$flutterBin;$env:Path"
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

# ---------- 4. git safe.directory (flutter tool refuses otherwise) ----------
Say "marking flutter sdk as a safe git directory"
& git config --global --add safe.directory $flutterDir 2>&1 | Out-Null

# ---------- 5. enable windows desktop ----------
Say "flutter config --enable-windows-desktop"
& $flutterBin\flutter.bat config --no-analytics --enable-windows-desktop 2>&1 | ForEach-Object { Write-Host ("  " + $_) }

# ---------- 6. version ----------
Say "flutter --version"
& $flutterBin\flutter.bat --version --no-version-check 2>&1 | ForEach-Object { Write-Host ("  " + $_) }

Say "=== flutter install stage finished ==="
