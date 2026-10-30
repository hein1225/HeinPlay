# =============================================================================
# Install the HeinPlay Windows build on this machine.
#
# Usage (on the target Windows PC):
#   powershell -NoProfile -ExecutionPolicy Bypass -File win_install_heinplay.ps1 -ZipPath "D:\heinplay-1.4.1-windows-portable.zip" -InstallDir "D:\HeinPlay"
#
# The script:
#   1. verifies the archive contains the expected payload
#   2. stops a running hain_tv.exe
#   3. extracts over the install dir (keeping user data)
#   4. clears the native log so the next run starts from a clean slate
# =============================================================================

param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\HeinPlay"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if (-not (Test-Path $ZipPath)) { throw "zip not found: $ZipPath" }
Say "zip      : $ZipPath  ($([math]::Round((Get-Item $ZipPath).Length/1MB,1)) MB)"
Say "install  : $InstallDir"

# ---- 1. payload sanity check ----
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
try {
    $names = $zip.Entries | ForEach-Object { $_.FullName }
    $hasExe  = $names | Where-Object { $_ -match '(^|/)hain_tv\.exe$' }
    $hasDll  = $names | Where-Object { $_ -match '(^|/)flutter_windows\.dll$' }
    $hasMpv  = $names | Where-Object { $_ -match '(^|/)libmpv-2\.dll$' }
    $hasData = $names | Where-Object { $_ -match '(^|/)data/flutter_assets/' }
    Say ("entries: {0}  hain_tv.exe={1} flutter_windows.dll={2} libmpv-2.dll={3} flutter_assets={4}" -f `
         $names.Count, [bool]$hasExe, [bool]$hasDll, [bool]$hasMpv, [bool]$hasData)
    if (-not $hasExe)  { throw "archive has no hain_tv.exe - wrong package?" }
    if (-not $hasDll)  { throw "archive has no flutter_windows.dll - broken build?" }
    if (-not $hasMpv)  { Write-Warning "archive has NO libmpv-2.dll - the mpv backend will not load!" }
    if (-not $hasData) { throw "archive has no data/flutter_assets - broken build?" }
} finally {
    $zip.Dispose()
}

# ---- 2. stop the running app ----
$running = Get-Process -Name 'hain_tv' -ErrorAction SilentlyContinue
if ($running) {
    Say "stopping running hain_tv.exe (pid $($running.Id -join ','))"
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
} else {
    Say "hain_tv.exe not running"
}

# ---- 3. extract ----
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Say "extracting ..."
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Say "extracted"

# ---- 4. clear native log ----
$logDir = Join-Path $env:LOCALAPPDATA 'HeinPlay\logs'
$logFile = Join-Path $logDir 'hein_native.log'
if (Test-Path $logFile) {
    Remove-Item $logFile -Force
    Say "cleared $logFile"
} else {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Say "log dir ready: $logDir"
}

$exe = Join-Path $InstallDir 'hain_tv.exe'
if (Test-Path $exe) {
    Say "installed: $exe"
    Say "run it with:  start `"$exe`""
} else {
    throw "hain_tv.exe not found after extraction"
}

Say "=== install finished ==="
